extends Node

signal progress_changed(puzzle_id: String, downloaded_files: int, total_files: int)
signal failed(puzzle_id: String, message: String)
signal completed(puzzle_id: String, local_root: String)

const PuzzleAssetCache = preload("res://assets/scripts/puzzle/puzzle_asset_cache.gd")

var _cancelled := false
var _cache := PuzzleAssetCache.new()

func cancel() -> void:
	_cancelled = true

func reset_cancel() -> void:
	_cancelled = false

func download_puzzle(puzzle_info: Dictionary) -> Dictionary:
	reset_cancel()
	var puzzle_id := str(puzzle_info.get("id", ""))
	var asset_version := int(puzzle_info.get("asset_version", 1))
	if puzzle_id == "":
		return {"ok": false, "error": "Invalid puzzle id"}
	if _cache.is_cached_and_valid(puzzle_id, asset_version):
		return {"ok": true, "local_root": _cache.get_version_dir(puzzle_id, asset_version), "cached": true}

	var manifest_path := str(puzzle_info.get("manifest_path", ""))
	if manifest_path == "":
		return {"ok": false, "error": "Missing manifest path"}

	var manifest_ref = Firebase.Storage.ref(manifest_path)
	var manifest_task = await manifest_ref.get_data()
	if not _is_storage_success(manifest_task):
		return {"ok": false, "error": "Failed to download manifest"}

	var parser := JSON.new()
	if parser.parse(manifest_task.data.get_string_from_utf8()) != OK or not parser.data is Dictionary:
		return {"ok": false, "error": "Manifest parse error"}
	var manifest: Dictionary = parser.data

	if int(manifest.get("asset_version", asset_version)) != asset_version:
		asset_version = int(manifest.get("asset_version", asset_version))
		puzzle_info["asset_version"] = asset_version

	var temp_root := _cache.get_temp_dir(puzzle_id, asset_version)
	_cache.clear_dir(temp_root)
	_cache.ensure_dir(temp_root)

	var files: Array = manifest.get("files", [])
	var total_files := files.size()
	var downloaded := 0

	for item in files:
		if _cancelled:
			return {"ok": false, "error": "Download cancelled"}
		if not item is Dictionary:
			continue
		var storage_path := str(item.get("storage_path", ""))
		var rel_path := str(item.get("path", ""))
		if storage_path == "" or rel_path == "":
			return {"ok": false, "error": "Invalid manifest file entry"}

		var ok := await _download_file_with_retry(storage_path, temp_root.path_join(rel_path), item)
		if not ok:
			failed.emit(puzzle_id, "Failed to download %s" % storage_path)
			return {"ok": false, "error": "Failed file download"}
		downloaded += 1
		progress_changed.emit(puzzle_id, downloaded, total_files)
		await get_tree().process_frame

	_cache.save_manifest(temp_root, manifest)
	if not _cache.validate_manifest_root(temp_root, manifest):
		return {"ok": false, "error": "Integrity verification failed"}
	if not _cache.commit_temp_to_version(puzzle_id, asset_version):
		return {"ok": false, "error": "Failed to commit puzzle cache"}

	var local_root := _cache.get_version_dir(puzzle_id, asset_version)
	completed.emit(puzzle_id, local_root)
	return {"ok": true, "local_root": local_root, "cached": false}

func _download_file_with_retry(storage_path: String, local_path: String, manifest_item: Dictionary) -> bool:
	for attempt in range(3):
		if _cancelled:
			return false
		var ref = Firebase.Storage.ref(storage_path)
		var task = await ref.get_data()
		if not _is_storage_success(task):
			await get_tree().create_timer(0.4 * float(attempt + 1)).timeout
			continue
		if not _cache.write_bytes(local_path, task.data):
			await get_tree().create_timer(0.2).timeout
			continue
		if manifest_item.has("bytes") and int(manifest_item["bytes"]) > 0:
			var f := FileAccess.open(local_path, FileAccess.READ)
			if f == null:
				continue
			var length := f.get_length()
			f.close()
			if length != int(manifest_item["bytes"]):
				continue
		if manifest_item.has("sha256") and str(manifest_item["sha256"]) != "":
			var actual := _cache.compute_sha256(local_path)
			if actual.to_lower() != str(manifest_item["sha256"]).to_lower():
				continue
		return true
	return false

func _is_storage_success(task) -> bool:
	if task == null:
		return false
	return int(task.result) == OK and int(task.response_code) >= 200 and int(task.response_code) < 300
