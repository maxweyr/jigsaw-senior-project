extends Control

const PuzzleDownloader = preload("res://assets/scripts/puzzle/puzzle_downloader.gd")
const RemotePuzzleSource = preload("res://assets/scripts/puzzle/remote_puzzle_source.gd")
const PuzzleAssetCache = preload("res://assets/scripts/puzzle/puzzle_asset_cache.gd")

var progress_arr = []
var overlay
@onready var nickname_label: Label = $VBoxContainer/NicknameLabel
@onready var single_player_button: Button = $"VBoxContainer/select puzzle"
@onready var play_online_button: Button = $VBoxContainer/PlayOnline
var rename_popup: PopupPanel
var nickname_line_edit: LineEdit
var joining_online := false
const STATUS_FONT = preload("res://assets/fonts/KiriFont.ttf")
const STATUS_TEXT_COLOR = Color(0.941176, 0.67451, 0.0431373, 1)
const PREPARING_PREFIX := "Preparing puzzles"
const DEFAULT_REMOTE_SIZE := 100
var _join_downloader: Node
var _remote_source := RemotePuzzleSource.new()
var _asset_cache := PuzzleAssetCache.new()
var _last_remote_resolve_error := ""
var _connect_scene_change_queued := false

func _ready():
	rename_popup = get_node_or_null("RenamePopup")
	if rename_popup:
		nickname_line_edit = rename_popup.get_node_or_null("VBoxContainer/NicknameLineEdit")
		rename_popup.hide()
	#await Firebase.Auth.remove_auth()
	create_overlay()
	# Prevents pieces from being loaded multiple times
	if(PuzzleVar.open_first_time):
		print("Adding Puzzles")
		#load(PuzzleVar.path)
		var dir = DirAccess.open(PuzzleVar.path)
		if dir:
			dir.list_dir_begin()
			var file_name = dir.get_next()
			# the below code is to parse through the image folder in order to put
			# the appropriate image files into the list for reference for the puzzle
			while file_name != "":
				if !file_name.begins_with(".") and file_name.ends_with(".import"):
					# apend the image into the image list
					PuzzleVar.images.append(file_name.replace(".import",""))
				file_name = dir.get_next()
			PuzzleVar.images.sort()
		PuzzleVar.open_first_time = false
	
	# Connect to network signals
	if NetworkManager:
		NetworkManager.client_connected.connect(_on_client_connected)
		NetworkManager.connection_failed.connect(_on_connection_failed)
	_join_downloader = PuzzleDownloader.new()
	add_child(_join_downloader)
	if FireAuth:
		FireAuth.logged_in.connect(_on_login)
		FireAuth.login_failed.connect(_on_login)
	_refresh_nickname_display()
	_wire_catalog_cache()
	_start_catalog_preload()

	if PuzzleVar.auto_rejoin_online:
		PuzzleVar.auto_rejoin_online = false
		await _auto_rejoin_after_kick()

func create_overlay():
	overlay = ColorRect.new()
	overlay.name = "LoginOverlay"
	overlay.color = Color(0, 0, 0, 0.5)  # semi-transparent black
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP  # blocks clicks
	overlay.size = get_viewport_rect().size
	overlay.anchor_right = 1
	overlay.anchor_bottom = 1
	overlay.visible = false
	if PuzzleVar.open_first_time:
		overlay.visible = true
	add_child(overlay)

func _on_start_random_pressed():
	$AudioStreamPlayer.play()
	#PuzzleVar.choice = PuzzleVar.get_random_puzzles()
	# load the texture and get the size of the puzzle image so that the game
	get_tree().change_scene_to_file("res://assets/scenes/random_menu.tscn")

func _on_select_puzzle_pressed():
	if single_player_button and single_player_button.disabled:
		var state := "idle"
		if PuzzleCatalogCache:
			state = str(PuzzleCatalogCache.get_progress().get("state", "idle"))
		if state == "failed":
			_show_simple_popup("Preparing Puzzles", "Unable to prepare remote puzzles. Retrying now.")
			_start_catalog_preload(true)
		return
	$AudioStreamPlayer.play() # doesn't work, switches scenes too fast
	# switches to a new scene that will ask you to
	# actually select what image you want to solve

	get_tree().change_scene_to_file("res://assets/scenes/select_puzzle.tscn")

func _on_play_online_pressed():
	if joining_online:
		return
	if _is_catalog_loading():
		return
	$AudioStreamPlayer.play()
	if !FireAuth.is_online:
		_show_simple_popup("Offline Mode", "Cannot play online while in offline mode. Please check your internet connection.")
		joining_online = false
		return

	joining_online = true
	PuzzleVar.choice = {}
	PuzzleVar.is_online_selector = false

	var lobby_choice := await FireAuth.get_lobby_choice(PuzzleVar.lobby_number)
	if not lobby_choice.is_empty():
		PuzzleVar.choice = await _resolve_choice_for_online_join(lobby_choice)
		if PuzzleVar.choice.is_empty():
			joining_online = false
			_show_simple_popup("Puzzle Unavailable", _consume_remote_resolve_error("Unable to prepare selected puzzle assets for this client."))
			return
		_join_online_with_choice()
		return

	var claimed := await FireAuth.try_claim_lobby_selector(PuzzleVar.lobby_number)
	if claimed:
		PuzzleVar.is_online_selector = true
		joining_online = false
		get_tree().change_scene_to_file("res://assets/scenes/select_puzzle.tscn")
		return

	await _wait_for_lobby_choice_and_join()

# Network signal handlers
func _on_client_connected():
	if _connect_scene_change_queued:
		return
	_connect_scene_change_queued = true
	print("Connected to server successfully")
	_clear_status_label("ConnectingLabel")
	await FireAuth.update_my_player_entry(PuzzleVar.lobby_number)
	
	# Update the puzzle choice to match server's choice
	if NetworkManager:
		print("Setting flags for scene change")
		NetworkManager.should_load_game = true
		
		# Use a timer to set the ready flag
		var timer = Timer.new()
		add_child(timer)
		timer.wait_time = 0.5
		timer.one_shot = true
		timer.timeout.connect(func(): 
			NetworkManager.ready_to_load = true
			print("Ready to load flag set to true")
		)
		timer.start()
	else:
		print("ERROR: network_manager is null!")
		_connect_scene_change_queued = false

func _on_connection_failed():
	_clear_status_label("ConnectingLabel")
	joining_online = false
	_connect_scene_change_queued = false
	
	print("Connection to server failed")
	
	# Show error message
	_show_simple_popup("Connection Error", "Connection to server failed.")

func _join_online_with_choice():
	if PuzzleVar.choice.is_empty():
		joining_online = false
		_show_simple_popup("No Puzzle Selected", "Please wait for a puzzle selection before joining.")
		return
	_connect_scene_change_queued = false
	_show_status_label("Connecting to server...", "ConnectingLabel")
	print("Attempting to connect to server...")
	if NetworkManager.join_server():
		return
	_clear_status_label("ConnectingLabel")
	joining_online = false
	_show_simple_popup("Connection Error", "Failed to connect to server.")

func _wait_for_lobby_choice_and_join():
	_show_status_label("Waiting for lobby host to pick a puzzle...", "ConnectingLabel")
	var attempts := 0
	var choice: Dictionary = {}
	while choice.is_empty() and attempts < 20:
		await get_tree().create_timer(1.0).timeout
		choice = await FireAuth.get_lobby_choice(PuzzleVar.lobby_number)
		attempts += 1
	_clear_status_label("ConnectingLabel")
	if choice.is_empty():
		await FireAuth.release_lobby_selector(PuzzleVar.lobby_number)
		var claimed := await FireAuth.try_claim_lobby_selector(PuzzleVar.lobby_number)
		if claimed:
			joining_online = false
			PuzzleVar.is_online_selector = true
			get_tree().change_scene_to_file("res://assets/scenes/select_puzzle.tscn")
			return
		joining_online = false
		_show_simple_popup("Lobby Waiting", "No puzzle selected yet. Please try again in a moment.")
		return
	PuzzleVar.choice = await _resolve_choice_for_online_join(choice)
	if PuzzleVar.choice.is_empty():
		joining_online = false
		_show_simple_popup("Puzzle Unavailable", _consume_remote_resolve_error("Unable to prepare selected puzzle assets for this client."))
		return
	_join_online_with_choice()

func _auto_rejoin_after_kick():
	joining_online = true
	_show_status_label("Rejoining lobby with new puzzle...", "ConnectingLabel")
	var choice := await FireAuth.get_lobby_choice(PuzzleVar.lobby_number)
	if choice.is_empty():
		joining_online = false
		_clear_status_label("ConnectingLabel")
		_show_simple_popup("Reconnect", "Host selected a new puzzle. Please press Play Online to rejoin.")
		return
	PuzzleVar.choice = await _resolve_choice_for_online_join(choice)
	if PuzzleVar.choice.is_empty():
		joining_online = false
		_clear_status_label("ConnectingLabel")
		_show_simple_popup("Reconnect", _consume_remote_resolve_error("Host selected a puzzle that could not be prepared locally."))
		return
	_join_online_with_choice()

func _resolve_choice_for_online_join(raw_choice: Dictionary) -> Dictionary:
	_last_remote_resolve_error = ""
	if raw_choice.is_empty():
		return {}
	if str(raw_choice.get("source", "local")) != "remote":
		return raw_choice
	var normalized := _normalize_remote_choice(raw_choice)
	if normalized.is_empty():
		_last_remote_resolve_error = "Puzzle metadata unavailable: missing puzzle identifier."
		return {}
	if _has_local_remote_assets(normalized):
		return _build_local_remote_choice(normalized)

	var canonical := _resolve_remote_choice_from_catalog(normalized)
	if canonical.is_empty():
		return {}

	var selected_size := _resolve_choice_size(canonical)
	var resolved := await _remote_source.resolve_choice(canonical, selected_size, _join_downloader)
	return resolved

func _normalize_remote_choice(raw_choice: Dictionary) -> Dictionary:
	var normalized := raw_choice.duplicate(true)
	normalized["source"] = "remote"
	normalized["id"] = str(normalized.get("id", raw_choice.get("base_name", "")))
	if normalized["id"] == "":
		return {}
	normalized["asset_version"] = int(raw_choice.get("asset_version", normalized.get("asset_version", 1)))
	if int(normalized.get("asset_version", 0)) <= 0:
		return {}
	normalized["size"] = _resolve_choice_size(normalized)
	if normalized.has("title") == false:
		normalized["title"] = str(raw_choice.get("title", normalized["id"]))
	return normalized

func _resolve_remote_choice_from_catalog(choice: Dictionary) -> Dictionary:
	var puzzle_id := str(choice.get("id", ""))
	if puzzle_id == "":
		_last_remote_resolve_error = "Puzzle metadata unavailable: missing puzzle identifier."
		return {}
	var entry := _find_catalog_entry_by_id(puzzle_id)
	if entry.is_empty():
		_last_remote_resolve_error = "Puzzle metadata unavailable for \"%s\". Please retry once catalog sync completes." % puzzle_id
		return {}

	var selected_size := _resolve_choice_size(choice)
	var size_options = entry.get("size_options", [])
	if size_options is Array and not size_options.is_empty():
		var matched := false
		for opt in size_options:
			if int(opt) == selected_size:
				matched = true
				break
		if not matched:
			selected_size = int(size_options[0])
			if selected_size <= 0:
				selected_size = DEFAULT_REMOTE_SIZE

	var requested_version := int(choice.get("asset_version", 1))
	var catalog_version := int(entry.get("asset_version", requested_version))
	if requested_version > 0 and catalog_version != requested_version:
		_last_remote_resolve_error = "Puzzle version mismatch for \"%s\" (host v%d, catalog v%d)." % [puzzle_id, requested_version, catalog_version]
		return {}
	var bundle_paths = entry.get("bundle_paths", {})
	var bundle_path := _dict_string_for_size(bundle_paths, selected_size)
	if not _is_shareable_bundle_path(bundle_path):
		_last_remote_resolve_error = "Puzzle bundle metadata for \"%s\" is incomplete. Please retry." % puzzle_id
		return {}

	return {
		"id": puzzle_id,
		"title": str(entry.get("title", choice.get("title", puzzle_id))),
		"source": "remote",
		"size": selected_size,
		"asset_version": catalog_version,
		"thumb_path": str(entry.get("thumb_path", "")),
		"bundle_paths": bundle_paths,
		"bundle_bytes": entry.get("bundle_bytes", {}),
		"bundle_sha256": entry.get("bundle_sha256", {}),
		"size_options": size_options if size_options is Array else [selected_size]
	}

func _find_catalog_entry_by_id(puzzle_id: String) -> Dictionary:
	if not PuzzleCatalogCache:
		return {}
	for entry_raw in PuzzleCatalogCache.get_ready_snapshot():
		if not (entry_raw is Dictionary):
			continue
		var entry: Dictionary = entry_raw
		if str(entry.get("id", "")) != puzzle_id:
			continue
		return entry.duplicate(true)
	return {}

func _has_local_remote_assets(choice: Dictionary) -> bool:
	if str(choice.get("source", "local")) != "remote":
		return false
	var resolved_dir := str(choice.get("resolved_dir", ""))
	if resolved_dir != "" and FileAccess.file_exists(resolved_dir.path_join("pieces/pieces.json")):
		return true
	var puzzle_id := str(choice.get("id", choice.get("base_name", "")))
	if puzzle_id == "":
		return false
	var size := _resolve_choice_size(choice)
	var cache_id := _resolve_remote_cache_id(puzzle_id, size, choice.get("bundle_paths", {}))
	var version := int(choice.get("asset_version", 1))
	return _asset_cache.is_cached_and_valid(cache_id, version)

func _build_local_remote_choice(choice: Dictionary) -> Dictionary:
	var local_root := str(choice.get("resolved_dir", ""))
	var size := _resolve_choice_size(choice)
	if local_root == "":
		var puzzle_id := str(choice.get("id", choice.get("base_name", "")))
		var cache_id := _resolve_remote_cache_id(puzzle_id, size, choice.get("bundle_paths", {}))
		var version := int(choice.get("asset_version", 1))
		local_root = _asset_cache.get_version_dir(cache_id, version)
	var ref_candidates = [
		local_root.path_join("reference.jpg"),
		local_root.path_join("images/full.jpg"),
		local_root.path_join("thumb.jpg"),
	]
	var ref_image := ""
	for path in ref_candidates:
		if FileAccess.file_exists(path):
			ref_image = path
			break
	if ref_image == "":
		ref_image = local_root.path_join("thumb.jpg")
	return {
		"base_name": str(choice.get("id", choice.get("base_name", "remote_puzzle"))),
		"base_file_path": local_root,
		"file_path": ref_image,
		"size": size,
		"source": "remote",
		"resolved_dir": local_root,
		"asset_version": int(choice.get("asset_version", 1))
	}

func _resolve_remote_cache_id(puzzle_id: String, selected_size: int, _raw_bundle_paths) -> String:
	if selected_size <= 0:
		return puzzle_id
	var suffix := "_%d" % selected_size
	if puzzle_id.ends_with(suffix):
		return puzzle_id
	return "%s%s" % [puzzle_id, suffix]

func _resolve_choice_size(choice: Dictionary) -> int:
	var explicit := int(choice.get("size", 0))
	if explicit > 0:
		return explicit
	var options = choice.get("size_options", [])
	if options is Array and not options.is_empty():
		var fallback := int(options[0])
		if fallback > 0:
			return fallback
	return DEFAULT_REMOTE_SIZE

func _is_shareable_bundle_path(bundle_path: String) -> bool:
	if bundle_path == "":
		return false
	return not bundle_path.begins_with("cached://")

func _dict_string_for_size(raw_map, selected_size: int) -> String:
	if not (raw_map is Dictionary):
		return ""
	var dict_map: Dictionary = raw_map
	if dict_map.has(str(selected_size)):
		return str(dict_map[str(selected_size)])
	if dict_map.has(selected_size):
		return str(dict_map[selected_size])
	var with_zip := "%d.zip" % selected_size
	if dict_map.has(with_zip):
		return str(dict_map[with_zip])
	for key in dict_map.keys():
		var parsed := int(str(key).trim_suffix(".zip"))
		if parsed == selected_size:
			return str(dict_map[key])
	return ""

func _consume_remote_resolve_error(default_message: String) -> String:
	var msg := _last_remote_resolve_error
	_last_remote_resolve_error = ""
	if msg == "":
		return default_message
	return msg

func _on_quit_pressed():
	# Quit the game (desktop-safe). Avoid OS shutdown commands, which typically fail without
	# elevated privileges and will not close the game process on Linux.
	print("Quitting game")
	get_tree().quit()
# commented out for now, type d for any reason will crash the game
# this is used to check for events such as a key press
func _input(event):
	# if event is InputEventKey and event.pressed and event.echo == false:
	# 	if event.keycode == 68: # if key that is pressed is d
	# 			# toggle debug mode
	# 			PuzzleVar.debug = !PuzzleVar.debug
	# 			if PuzzleVar.debug:
	# 				$Label.show()
	# 			else:
	# 				$Label.hide()
	# 			print("debug mode is: "+str(PuzzleVar.debug))
	if event.is_action_pressed("ui_cancel"):
		get_tree().quit()

func _on_login() -> void:
	overlay.visible = false # Hide the overlay after login completes
	_start_catalog_preload()

func _wire_catalog_cache() -> void:
	if not PuzzleCatalogCache:
		if single_player_button:
			single_player_button.disabled = false
		return
	if not PuzzleCatalogCache.preload_started.is_connected(_on_catalog_preload_started):
		PuzzleCatalogCache.preload_started.connect(_on_catalog_preload_started)
	if not PuzzleCatalogCache.preload_progress.is_connected(_on_catalog_preload_progress):
		PuzzleCatalogCache.preload_progress.connect(_on_catalog_preload_progress)
	if not PuzzleCatalogCache.preload_ready.is_connected(_on_catalog_preload_ready):
		PuzzleCatalogCache.preload_ready.connect(_on_catalog_preload_ready)
	if not PuzzleCatalogCache.preload_failed.is_connected(_on_catalog_preload_failed):
		PuzzleCatalogCache.preload_failed.connect(_on_catalog_preload_failed)
	_apply_catalog_cache_state()

func _apply_catalog_cache_state() -> void:
	if not PuzzleCatalogCache:
		return
	var progress := PuzzleCatalogCache.get_progress()
	var state := str(progress.get("state", "idle"))
	if state == "ready":
		_set_single_player_ready()
		return
	if state == "loading":
		var done := int(progress.get("done", 0))
		var total := int(progress.get("total", 0))
		var text := PREPARING_PREFIX
		if total > 0:
			text = "%s (%d/%d)" % [PREPARING_PREFIX, done, total]
		_set_single_player_loading(text)
		return
	if state == "failed":
		_set_single_player_ready()
		return
	_set_single_player_loading(PREPARING_PREFIX)

func _start_catalog_preload(force := false) -> void:
	if not PuzzleCatalogCache:
		return
	PuzzleCatalogCache.start_preload(force)
	_apply_catalog_cache_state()

func _on_catalog_preload_started() -> void:
	_set_single_player_loading(PREPARING_PREFIX)

func _on_catalog_preload_progress(done: int, total: int) -> void:
	var text := PREPARING_PREFIX
	if total > 0:
		text = "%s (%d/%d)" % [PREPARING_PREFIX, done, total]
	_set_single_player_loading(text)

func _on_catalog_preload_ready() -> void:
	_set_single_player_ready()

func _on_catalog_preload_failed(_reason: String) -> void:
	_set_single_player_ready()

func _set_single_player_loading(text: String) -> void:
	if not single_player_button:
		return
	single_player_button.disabled = true
	single_player_button.text = text
	_set_online_loading(text)

func _set_single_player_ready() -> void:
	if not single_player_button:
		return
	single_player_button.disabled = false
	single_player_button.text = "Single Player"
	_set_online_ready()

func _set_online_loading(text: String) -> void:
	if not play_online_button:
		return
	play_online_button.disabled = true
	play_online_button.text = text

func _set_online_ready() -> void:
	if not play_online_button:
		return
	play_online_button.disabled = false
	play_online_button.text = "Play Online"

func _is_catalog_loading() -> bool:
	if not PuzzleCatalogCache:
		return false
	var state := str(PuzzleCatalogCache.get_progress().get("state", "idle"))
	return state == "loading"

func _refresh_nickname_display():
	if nickname_label:
		nickname_label.text = "Welcome, %s !" % FireAuth.get_nickname()

func _on_change_nickname_pressed():
	if not rename_popup or not nickname_line_edit:
		return
	nickname_line_edit.text = FireAuth.get_nickname()
	nickname_line_edit.grab_focus()
	nickname_line_edit.caret_column = nickname_line_edit.text.length()
	rename_popup.popup_centered()

func _on_nickname_line_edit_text_submitted(_text):
	_on_rename_save_pressed()

func _on_rename_save_pressed():
	if not nickname_line_edit:
		return
	var new_nickname := nickname_line_edit.text.strip_edges()
	if new_nickname == "":
		_show_simple_popup("Invalid Nickname", "Please enter a valid nickname.")
		return

	_save_nickname(new_nickname)
	FireAuth.nickname = new_nickname
	_refresh_nickname_display()
	_show_simple_popup("Nickname Updated", "Your nickname is now \"%s\"." % new_nickname)
	rename_popup.hide()

func _on_rename_cancel_pressed():
	rename_popup.hide()

func _save_nickname(new_nickname: String):
	var file_path = "user://user_data.txt"
	var username := FireAuth.get_box_id()

	var existing_file = FileAccess.open(file_path, FileAccess.READ)
	if existing_file and existing_file.get_length() > 0:
		var first_line = existing_file.get_line().strip_edges()
		if first_line != "":
			username = first_line
		existing_file.close()

	var file = FileAccess.open(file_path, FileAccess.WRITE)
	if file:
		file.store_line(username)
		file.store_line(new_nickname)
		file.close()
	else:
		printerr("Failed to save nickname to ", file_path)

func _on_sign_out_pressed() -> void:
	var file_path = "user://user_data.txt" 
	var file = FileAccess.open(file_path, FileAccess.WRITE)
	if file:
		file.close()
	else:
		printerr("Failed to clear user data in ", file_path)
	get_tree().change_scene_to_file("res://assets/scenes/login.tscn")	# Go back to login screen
	# _on_quit_pressed() # Quit the game to ensure all data is cleared

func _show_status_label(text: String, node_name: String = "ConnectingLabel"):
	var container = get_node_or_null(node_name)
	var label: Label = null
	if container == null:
		container = PanelContainer.new()
		container.name = node_name
		container.custom_minimum_size = Vector2(720, 120)
		container.anchor_left = 0.5
		container.anchor_top = 0.5
		container.anchor_right = 0.5
		container.anchor_bottom = 0.5
		container.offset_left = -345
		container.offset_top = -60
		container.offset_right = 380
		container.offset_bottom = 60
		add_child(container)

		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.07, 0.07, 0.08, 0.92)
		style.border_width_left = 1
		style.border_width_top = 1
		style.border_width_right = 1
		style.border_width_bottom = 1
		style.border_color = Color(0.44, 0.39, 0.37, 1)
		style.corner_radius_top_left = 8
		style.corner_radius_top_right = 8
		style.corner_radius_bottom_right = 8
		style.corner_radius_bottom_left = 8
		container.add_theme_stylebox_override("panel", style)

		label = Label.new()
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.size_flags_vertical = Control.SIZE_EXPAND_FILL
		container.add_child(label)
	else:
		label = container.get_child(0) as Label
	if label and text == "Waiting for lobby host to pick a puzzle...":
		label.add_theme_font_override("font", STATUS_FONT)
		label.add_theme_font_size_override("font_size", 42)
		label.add_theme_color_override("font_color", STATUS_TEXT_COLOR)
	if label:
		label.text = text

func _clear_status_label(node_name: String = "ConnectingLabel"):
	var label = get_node_or_null(node_name)
	if label:
		label.queue_free()

func _show_simple_popup(title: String, message: String, size: Vector2i = Vector2i(620, 260)) -> AcceptDialog:
	var popup := AcceptDialog.new()
	popup.title = title
	popup.dialog_text = message
	add_child(popup)
	
	# font sizing
	popup.get_label().add_theme_font_size_override("font_size", 42)
	popup.get_ok_button().add_theme_font_size_override("font_size", 28)
	popup.add_theme_font_size_override("title_font_size", 28)
	
	# text centering
	var lbl := popup.get_label()
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	# resize popup
	popup.reset_size()
	popup.size = size
	popup.call_deferred("popup_centered")
	
	return popup
