extends Node

signal preload_started()
signal preload_progress(done: int, total: int)
signal preload_ready()
signal preload_failed(reason: String)

const PuzzleCatalogService = preload("res://assets/scripts/puzzle/puzzle_catalog_service.gd")
const PuzzleAssetCache = preload("res://assets/scripts/puzzle/puzzle_asset_cache.gd")

const PRELOAD_TIMEOUT_SEC := 12.0

var _catalog := PuzzleCatalogService.new()
var _cache := PuzzleAssetCache.new()

var _state := "idle"
var _failure_reason := ""
var _progress_done := 0
var _progress_total := 0

var _entries: Array = []
var _textures_by_key: Dictionary = {}

var _run_id := 0
var _metadata_migrated := false
func start_preload(force := false) -> void:
	if not _metadata_migrated:
		_cache.migrate_all_cached_metadata()
		_metadata_migrated = true
	if _state == "loading":
		return
	if _state == "ready" and not force:
		return
	_run_id += 1
	_state = "loading"
	_failure_reason = ""
	_progress_done = 0
	_progress_total = 0
	emit_signal("preload_started")
	_start_preload_async.call_deferred(_run_id)

func is_ready() -> bool:
	return _state == "ready"

func get_ready_snapshot() -> Array:
	var snapshot: Array = []
	if _state != "ready":
		return snapshot
	for entry in _entries:
		if not (entry is Dictionary):
			continue
		var copy: Dictionary = (entry as Dictionary).duplicate(true)
		var key := _entry_cache_key(copy)
		if _textures_by_key.has(key):
			copy["thumb_texture"] = _textures_by_key[key]
		snapshot.append(copy)
	return snapshot

func get_thumbnail_texture(entry: Dictionary) -> Texture2D:
	if entry.has("thumb_texture") and entry["thumb_texture"] is Texture2D:
		return entry["thumb_texture"]
	var key := _entry_cache_key(entry)
	if _textures_by_key.has(key):
		return _textures_by_key[key]
	return null

func get_failure_reason() -> String:
	return _failure_reason

func get_progress() -> Dictionary:
	return {
		"done": _progress_done,
		"total": _progress_total,
		"state": _state
	}

func _start_preload_async(run_id: int) -> void:
	var timed_out := false
	var timer := get_tree().create_timer(PRELOAD_TIMEOUT_SEC)
	timer.timeout.connect(func():
		if run_id != _run_id:
			return
		timed_out = true
	)

	var remote_entries := await _catalog.fetch_enabled_puzzles()
	if run_id != _run_id:
		return

	_entries = []
	_textures_by_key.clear()
	for item in remote_entries:
		if item is Dictionary:
			_entries.append(item.duplicate(true))

	_progress_total = _entries.size()
	_progress_done = 0
	emit_signal("preload_progress", _progress_done, _progress_total)

	if _entries.is_empty():
		_state = "ready"
		emit_signal("preload_ready")
		return

	var ready_entries: Array = []
	for entry in _entries:
		if run_id != _run_id:
			return
		if timed_out:
			_failure_reason = "Thumbnail preload timed out; using available remote puzzles."
			break
		var ok := await _ensure_thumbnail_for_entry(entry)
		if run_id != _run_id:
			return
		if ok:
			ready_entries.append(entry)
		_progress_done += 1
		emit_signal("preload_progress", _progress_done, _progress_total)

	_entries = ready_entries

	_state = "ready"
	emit_signal("preload_ready")

func _ensure_thumbnail_for_entry(entry: Dictionary) -> bool:
	var puzzle_id := str(entry.get("id", ""))
	if puzzle_id == "":
		return false
	var version := int(entry.get("asset_version", 1))
	var cache_key := _entry_cache_key(entry)
	var thumb_cache := _cache.get_version_dir(puzzle_id, version).path_join("thumb.jpg")

	if not FileAccess.file_exists(thumb_cache):
		var thumb_path := str(entry.get("thumb_path", ""))
		if thumb_path == "":
			return false
		var task = await Firebase.Storage.ref(thumb_path).get_data()
		if not _is_storage_success(task):
			return false
		if not _cache.write_bytes(thumb_cache, _extract_storage_bytes(task)):
			return false

	var image := Image.load_from_file(thumb_cache)
	if image == null or image.is_empty():
		return false
	var texture := ImageTexture.create_from_image(image)
	if texture == null:
		return false

	_textures_by_key[cache_key] = texture
	entry["thumb_texture"] = texture
	return true

func _entry_cache_key(entry: Dictionary) -> String:
	var puzzle_id := str(entry.get("id", ""))
	var version := int(entry.get("asset_version", 1))
	return "remote:%s:v%d" % [puzzle_id, version]

func _is_storage_success(task) -> bool:
	if task == null:
		return false
	if task is PackedByteArray:
		return true
	if task is Dictionary:
		if task.has("result"):
			return int(task.get("result", ERR_CANT_CONNECT)) == OK and int(task.get("response_code", 0)) >= 200 and int(task.get("response_code", 0)) < 300
		return task.get("data", null) is PackedByteArray
	if task is Object:
		var result = task.get("result")
		if result == null:
			return task.get("data") is PackedByteArray
		var response_code := int(task.get("response_code"))
		return int(result) == OK and response_code >= 200 and response_code < 300
	return false

func _extract_storage_bytes(task) -> PackedByteArray:
	if task is PackedByteArray:
		return task
	if task is Dictionary:
		var data = task.get("data", null)
		if data is PackedByteArray:
			return data
		return PackedByteArray()
	if task is Object:
		var data = task.get("data")
		if data is PackedByteArray:
			return data
	return PackedByteArray()
