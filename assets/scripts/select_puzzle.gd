extends Control

const PuzzleDownloader = preload("res://assets/scripts/puzzle/puzzle_downloader.gd")
const LocalPuzzleSource = preload("res://assets/scripts/puzzle/local_puzzle_source.gd")
const RemotePuzzleSource = preload("res://assets/scripts/puzzle/remote_puzzle_source.gd")
const PuzzleAssetCache = preload("res://assets/scripts/puzzle/puzzle_asset_cache.gd")
const STRICT_SIZES := [10, 100, 500]

var page_num: int = 1
var total_pages: int = 1
var page_string = "%d out of %d"

@onready var pageind = $PageIndicator
@onready var left_button = $"HBoxContainer/left button"
@onready var right_button = $"HBoxContainer/right button"
@onready var size_label = $Panel/VBoxContainer/Thumbnail/size_label
@onready var hbox = $"HBoxContainer"
@onready var panel = $"Panel"
@onready var thumbnail = $Panel/VBoxContainer/Thumbnail
@onready var loading = $LoadingScreen
@onready var grid = $"HBoxContainer/GridContainer"

var all_tiles: Array = []
var selected_entry: Dictionary = {}
var selected_size := 100

var _downloader: Node
var _local_source := LocalPuzzleSource.new()
var _remote_source := RemotePuzzleSource.new()
var _asset_cache := PuzzleAssetCache.new()

func _ready():
	print("SELECT_PUZZLE")
	if get_tree():
		get_tree().set_auto_accept_quit(false)
	if NetworkManager:
		NetworkManager.client_connected.connect(_on_online_client_connected)
		NetworkManager.connection_failed.connect(_on_online_connection_failed)

	_downloader = PuzzleDownloader.new()
	add_child(_downloader)
	if _downloader.progress_changed.is_connected(_on_puzzle_download_progress) == false:
		_downloader.progress_changed.connect(_on_puzzle_download_progress)
	if _downloader.phase_changed.is_connected(_on_puzzle_download_phase) == false:
		_downloader.phase_changed.connect(_on_puzzle_download_phase)
	if _downloader.failed.is_connected(_on_puzzle_download_failed) == false:
		_downloader.failed.connect(_on_puzzle_download_failed)

	for child in grid.get_children():
		var button := child as BaseButton
		if is_instance_valid(button):
			button.text = ""
			button.pressed.connect(button_pressed.bind(button))

	_bind_catalog_cache()
	_load_catalog_from_cache()
	await get_tree().process_frame
	populate_grid_2()

func _exit_tree():
	_unbind_catalog_cache()
	if get_tree():
		get_tree().set_auto_accept_quit(true)

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if PuzzleVar.is_online_selector:
			await _release_online_selector_lock()
		get_tree().quit()

func _release_online_selector_lock():
	if not PuzzleVar.is_online_selector:
		return
	await FireAuth.release_lobby_selector(PuzzleVar.lobby_number)
	PuzzleVar.is_online_selector = false

func _process(_delta):
	pageind.text = page_string % [page_num, max(total_pages, 1)]

func _on_left_button_pressed():
	$AudioStreamPlayer.play()
	if page_num > 1:
		page_num -= 1
	left_button.disabled = (page_num == 1)
	right_button.disabled = false
	populate_grid_2()

func _on_right_button_pressed():
	$AudioStreamPlayer.play()
	if page_num < total_pages:
		page_num += 1
	if page_num == total_pages:
		right_button.disabled = true
		left_button.disabled = false
	else:
		right_button.disabled = false
		left_button.disabled = false
	populate_grid_2()

func _load_catalog_from_cache() -> void:
	var base_entries: Array = []
	var had_live_remote_entries := false
	if PuzzleCatalogCache:
		var remote_entries := PuzzleCatalogCache.get_ready_snapshot()
		had_live_remote_entries = remote_entries.size() > 0
		for remote in remote_entries:
			if _supports_strict_sizes(remote):
				base_entries.append(remote)
	base_entries = _dedupe_entries_by_id(base_entries)
	if base_entries.is_empty() and not had_live_remote_entries:
		base_entries = _discover_cached_remote_entries()
	base_entries.sort_custom(_compare_entries_by_title)
	all_tiles.clear()
	for entry_raw in base_entries:
		if not (entry_raw is Dictionary):
			continue
		var entry: Dictionary = (entry_raw as Dictionary).duplicate(true)
		var source := str(entry.get("source", "remote"))
		for size in STRICT_SIZES:
			if source == "remote" and not _entry_has_size(entry, size):
				continue
			all_tiles.append({
				"entry": entry,
				"selected_size": size,
				"source": source
			})
	_recompute_pagination()

func _bind_catalog_cache() -> void:
	if not PuzzleCatalogCache:
		return
	if not PuzzleCatalogCache.preload_ready.is_connected(_on_catalog_cache_ready):
		PuzzleCatalogCache.preload_ready.connect(_on_catalog_cache_ready)

func _unbind_catalog_cache() -> void:
	if not PuzzleCatalogCache:
		return
	if PuzzleCatalogCache.preload_ready.is_connected(_on_catalog_cache_ready):
		PuzzleCatalogCache.preload_ready.disconnect(_on_catalog_cache_ready)

func _on_catalog_cache_ready() -> void:
	_load_catalog_from_cache()
	populate_grid_2()

func _recompute_pagination() -> void:
	var num_buttons = grid.get_child_count()
	var nb = float(max(num_buttons, 1))
	total_pages = int(ceil(float(all_tiles.size()) / nb))
	if total_pages <= 0:
		total_pages = 1
	left_button.disabled = true
	right_button.disabled = total_pages == 1

func button_pressed(button):
	var button_index := grid.get_children().find(button)
	if button_index == -1:
		return
	var global_index: int= (page_num - 1) * grid.get_child_count() + button_index
	if global_index < 0 or global_index >= all_tiles.size():
		return

	var tile: Dictionary = all_tiles[global_index]
	selected_entry = tile.get("entry", {})
	if selected_entry.is_empty():
		return
	var tex := _get_cached_thumbnail_texture(selected_entry)
	thumbnail.texture = tex
	selected_size = int(tile.get("selected_size", 100))
	size_label.text = str(selected_size)

	hbox.hide()
	pageind.hide()
	panel.show()

func populate_grid_2():
	var buttons = grid.get_children()
	var base_index = (page_num - 1) * buttons.size()
	for idx in range(buttons.size()):
		var button = buttons[idx]
		var puzzle_index = base_index + idx
		var tex_node := button.get_node_or_null("TextureRect") as TextureRect
		var size_badge := button.get_node_or_null("SizeBadge") as PanelContainer
		var size_label_node := button.get_node_or_null("SizeBadge/SizeText") as Label
		if puzzle_index >= all_tiles.size():
			if tex_node != null:
				tex_node.texture = null
				tex_node.remove_meta("puzzle_id")
			if size_badge != null:
				size_badge.visible = false
			if size_label_node != null:
				size_label_node.text = ""
			button.disabled = true
			continue
		button.disabled = false
		if tex_node != null:
			var tile: Dictionary = all_tiles[puzzle_index]
			var entry: Dictionary = tile.get("entry", {})
			var tile_size := int(tile.get("selected_size", 100))
			var entry_id := str(entry.get("id", ""))
			tex_node.set_meta("puzzle_id", "%s:%d" % [entry_id, tile_size])
			tex_node.texture = _get_cached_thumbnail_texture(entry)
			tex_node.size = button.size
			if size_badge != null:
				size_badge.visible = true
			if size_label_node != null:
				size_label_node.text = str(tile_size)

func _on_start_puzzle_pressed() -> void:
	if selected_entry.is_empty():
		_show_simple_popup("No Puzzle Selected", "Please select a puzzle first.")
		return
	_show_download_progress("Preparing puzzle...", 0, 1)
	await get_tree().process_frame

	if PuzzleVar.is_online_selector:
		var lobby_choice := _build_lobby_choice_payload(selected_entry, selected_size, {})
		if lobby_choice.is_empty():
			_hide_download_progress()
			_show_simple_popup("Puzzle Unavailable", "Unable to publish selected puzzle for multiplayer.")
			return
		await FireAuth.set_lobby_puzzle_choice(lobby_choice, PuzzleVar.lobby_number)
		PuzzleVar.is_online_selector = false
		PuzzleVar.auto_rejoin_online = true
		_hide_download_progress()
		get_tree().change_scene_to_file("res://assets/scenes/new_menu.tscn")
		return

	var choice: Dictionary = {}
	if str(selected_entry.get("source", "local")) == "remote":
		_show_download_progress("Downloading puzzle assets...", 0, 1)
		choice = await _remote_source.resolve_choice(selected_entry, selected_size, _downloader)
		if choice.is_empty():
			_hide_download_progress()
			_show_simple_popup("Download Error", "Unable to download puzzle assets. Please try again.")
			return
	else:
		choice = _local_source.resolve_choice(selected_entry, selected_size, _downloader)

	PuzzleVar.choice = choice
	_hide_download_progress()
	get_tree().change_scene_to_file("res://assets/scenes/jigsaw_puzzle_1.tscn")

func _build_lobby_choice_payload(entry: Dictionary, selected_size_value: int, resolved_choice: Dictionary) -> Dictionary:
	if str(entry.get("source", "local")) != "remote":
		return resolved_choice

	return {
		"id": str(entry.get("id", resolved_choice.get("base_name", "remote_puzzle"))),
		"title": str(entry.get("title", entry.get("id", "remote_puzzle"))),
		"source": "remote",
		"size": selected_size_value,
		"asset_version": int(entry.get("asset_version", resolved_choice.get("asset_version", 1)))
	}

func _on_online_client_connected():
	print("Connected to server from select_puzzle")
	await FireAuth.update_my_player_entry(PuzzleVar.lobby_number)
	if NetworkManager:
		NetworkManager.should_load_game = true
		var timer = Timer.new()
		add_child(timer)
		timer.wait_time = 0.5
		timer.one_shot = true
		timer.timeout.connect(func():
			NetworkManager.ready_to_load = true
			NetworkManager.kick_other_clients_in_lobby()
		)
		timer.start()

func _on_online_connection_failed():
	_hide_download_progress()
	_show_simple_popup("Connection Error", "Failed to connect to server.")

func _on_go_back_pressed() -> void:
	panel.hide()
	pageind.show()
	hbox.show()

func _on_go_back_to_menu_pressed() -> void:
	if PuzzleVar.is_online_selector:
		loading.show()
		await _release_online_selector_lock()
	get_tree().change_scene_to_file("res://assets/scenes/new_menu.tscn")

func _compare_entries_by_title(a: Variant, b: Variant) -> bool:
	var ad: Dictionary = a if a is Dictionary else {}
	var bd: Dictionary = b if b is Dictionary else {}
	var atitle := str(ad.get("title", ad.get("id", ""))).to_lower()
	var btitle := str(bd.get("title", bd.get("id", ""))).to_lower()
	if atitle == btitle:
		var aid := str(ad.get("id", "")).to_lower()
		var bid := str(bd.get("id", "")).to_lower()
		return aid < bid
	return atitle < btitle

func _supports_strict_sizes(entry: Dictionary) -> bool:
	for size in STRICT_SIZES:
		if not _entry_has_size(entry, size):
			return false
	return true

func _dedupe_entries_by_id(entries: Array) -> Array:
	var by_id: Dictionary = {}
	for item in entries:
		if not (item is Dictionary):
			continue
		var entry: Dictionary = item
		var puzzle_id := str(entry.get("id", "")).strip_edges()
		if puzzle_id == "":
			continue
		var id_key := puzzle_id.to_lower()
		if not by_id.has(id_key):
			by_id[id_key] = entry
	var deduped: Array = []
	for key in by_id.keys():
		deduped.append(by_id[key])
	return deduped

func _discover_cached_remote_entries() -> Array:
	var discovered: Array = []
	var by_base: Dictionary = {}
	for cache_id in _list_dir_names(PuzzleAssetCache.PUZZLE_ROOT):
		var parsed := _parse_cache_id(cache_id)
		var base_id := str(parsed.get("base_id", ""))
		var size := int(parsed.get("size", 0))
		if base_id == "" or not STRICT_SIZES.has(size):
			continue
		var version := _latest_valid_cached_version(cache_id)
		if version <= 0:
			continue
		var root := _asset_cache.get_version_dir(cache_id, version)
		if not _has_required_cached_files(root):
			continue
		if not by_base.has(base_id):
			by_base[base_id] = {}
		var size_map: Dictionary = by_base[base_id]
		size_map[size] = {"cache_id": cache_id, "version": version}
		by_base[base_id] = size_map

	for base_id in by_base.keys():
		var size_map: Dictionary = by_base[base_id]
		var has_all := true
		for size in STRICT_SIZES:
			if not size_map.has(size):
				has_all = false
				break
		if not has_all:
			continue
		var version := int((size_map[STRICT_SIZES[0]] as Dictionary).get("version", 0))
		var version_match := true
		for size in STRICT_SIZES:
			var current := int((size_map[size] as Dictionary).get("version", 0))
			if current != version:
				version_match = false
				break
		if not version_match:
			continue

		var bundle_paths: Dictionary = {}
		for size in STRICT_SIZES:
			bundle_paths[str(size)] = "cached://%s/v%d/%d.zip" % [str(base_id), version, size]

		var thumb_texture := _load_cached_thumbnail_texture(str(base_id), version)
		var entry := {
			"id": str(base_id),
			"title": str(base_id),
			"source": "remote",
			"asset_version": version,
			"size_options": STRICT_SIZES.duplicate(),
			"bundle_paths": bundle_paths,
			"bundle_bytes": {},
			"bundle_sha256": {}
		}
		if thumb_texture != null:
			entry["thumb_texture"] = thumb_texture
		discovered.append(entry)
	return discovered

func _list_dir_names(root_path: String) -> Array:
	var names: Array = []
	var da := DirAccess.open(root_path)
	if da == null:
		return names
	da.list_dir_begin()
	var name := da.get_next()
	while name != "":
		if name != "." and name != ".." and da.current_is_dir():
			names.append(name)
		name = da.get_next()
	da.list_dir_end()
	return names

func _parse_cache_id(cache_id: String) -> Dictionary:
	for size in STRICT_SIZES:
		var suffix := "_%d" % size
		if cache_id.ends_with(suffix):
			return {
				"base_id": cache_id.substr(0, cache_id.length() - suffix.length()),
				"size": size
			}
	return {"base_id": "", "size": 0}

func _latest_valid_cached_version(cache_id: String) -> int:
	var best := 0
	var dir_path := PuzzleAssetCache.PUZZLE_ROOT.path_join(cache_id)
	for child in _list_dir_names(dir_path):
		if not child.begins_with("v"):
			continue
		var parsed := int(child.substr(1))
		if parsed <= 0:
			continue
		if not _asset_cache.is_cached_and_valid(cache_id, parsed):
			continue
		if parsed > best:
			best = parsed
	return best

func _has_required_cached_files(root: String) -> bool:
	if not FileAccess.file_exists(root.path_join("pieces/pieces.json")):
		return false
	if not FileAccess.file_exists(root.path_join("adjacent.json")):
		return false
	var raster_dir := root.path_join("pieces/raster")
	var raster_abs := ProjectSettings.globalize_path(raster_dir)
	if not DirAccess.dir_exists_absolute(raster_abs):
		return false
	var da := DirAccess.open(raster_dir)
	if da == null:
		return false
	var found_png := false
	da.list_dir_begin()
	var name := da.get_next()
	while name != "":
		if not da.current_is_dir() and name.to_lower().ends_with(".png"):
			found_png = true
			break
		name = da.get_next()
	da.list_dir_end()
	return found_png

func _load_cached_thumbnail_texture(base_id: String, asset_version: int) -> Texture2D:
	for size in STRICT_SIZES:
		var cache_id := "%s_%d" % [base_id, size]
		var thumb_path := _asset_cache.get_version_dir(cache_id, asset_version).path_join("thumb.jpg")
		if not FileAccess.file_exists(thumb_path):
			continue
		var image := Image.load_from_file(thumb_path)
		if image == null or image.is_empty():
			continue
		var tex := ImageTexture.create_from_image(image)
		if tex != null:
			return tex
	return null

func _entry_has_size(entry: Dictionary, size: int) -> bool:
	var source := str(entry.get("source", "local"))
	if source == "local":
		return true

	var size_options = entry.get("size_options", [])
	if size_options is Array:
		for item in size_options:
			if int(item) == size:
				return true

	var bundle_paths = entry.get("bundle_paths", {})
	if not (bundle_paths is Dictionary):
		return false
	var dict_map: Dictionary = bundle_paths
	if dict_map.has(str(size)) or dict_map.has(size) or dict_map.has("%d.zip" % size):
		return true
	for key in dict_map.keys():
		var parsed := int(str(key).trim_suffix(".zip"))
		if parsed == size:
			return true
	return false

func _get_cached_thumbnail_texture(entry: Dictionary) -> Texture2D:
	if str(entry.get("source", "local")) == "local":
		return load(str(entry.get("thumb_local_path", "")))
	if PuzzleCatalogCache:
		return PuzzleCatalogCache.get_thumbnail_texture(entry)
	if entry.has("thumb_texture") and entry["thumb_texture"] is Texture2D:
		return entry["thumb_texture"]
	return null

func _show_simple_popup(title: String, message: String, size: Vector2i = Vector2i(620, 260)) -> AcceptDialog:
	var popup := AcceptDialog.new()
	popup.title = title
	popup.dialog_text = message
	add_child(popup)
	popup.get_label().add_theme_font_size_override("font_size", 42)
	popup.get_ok_button().add_theme_font_size_override("font_size", 28)
	popup.add_theme_font_size_override("title_font_size", 28)
	var lbl := popup.get_label()
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	popup.reset_size()
	popup.size = size
	popup.call_deferred("popup_centered")
	return popup

func _show_download_progress(_message: String, _downloaded_files: int, _total_files: int) -> void:
	loading.show()

func _hide_download_progress() -> void:
	loading.hide()

func _on_puzzle_download_progress(_puzzle_id: String, downloaded_files: int, total_files: int) -> void:
	_show_download_progress("", downloaded_files, total_files)

func _on_puzzle_download_phase(_puzzle_id: String, _message: String, downloaded_files: int, total_files: int) -> void:
	_show_download_progress("", downloaded_files, total_files)

func _on_puzzle_download_failed(_puzzle_id: String, _message: String) -> void:
	_hide_download_progress()
