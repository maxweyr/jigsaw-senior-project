extends Control

const PuzzleCatalogService = preload("res://assets/scripts/puzzle/puzzle_catalog_service.gd")
const PuzzleAssetCache = preload("res://assets/scripts/puzzle/puzzle_asset_cache.gd")
const PuzzleDownloader = preload("res://assets/scripts/puzzle/puzzle_downloader.gd")
const LocalPuzzleSource = preload("res://assets/scripts/puzzle/local_puzzle_source.gd")
const RemotePuzzleSource = preload("res://assets/scripts/puzzle/remote_puzzle_source.gd")

var page_num = 1
var total_pages
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

var all_puzzles: Array = []
var selected_entry: Dictionary = {}
var selected_size := 100
var size_selector: OptionButton

var _catalog := PuzzleCatalogService.new()
var _cache := PuzzleAssetCache.new()
var _downloader: Node
var _local_source := LocalPuzzleSource.new()
var _remote_source := RemotePuzzleSource.new()

func _ready():
	print("SELECT_PUZZLE")
	if get_tree():
		get_tree().set_auto_accept_quit(false)
	if NetworkManager:
		NetworkManager.client_connected.connect(_on_online_client_connected)
		NetworkManager.connection_failed.connect(_on_online_connection_failed)

	_downloader = PuzzleDownloader.new()
	add_child(_downloader)

	for child in grid.get_children():
		var button := child as BaseButton
		if is_instance_valid(button):
			button.text = ""
			button.pressed.connect(button_pressed.bind(button))

	_ensure_size_selector()
	await _load_catalog()
	await get_tree().process_frame
	populate_grid_2()

func _exit_tree():
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
	pageind.text = page_string % [page_num, total_pages]

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

func _load_catalog() -> void:
	all_puzzles.clear()
	for local in PuzzleVar.get_avail_puzzles():
		all_puzzles.append({
			"id": str(local["base_name"]),
			"title": str(local["base_name"]),
			"thumb_local_path": str(local["file_path"]),
			"size_options": [10, 100, 500],
			"source": "local",
			"local_data": local.duplicate(true)
		})

	var remote = await _catalog.fetch_enabled_puzzles()
	for r in remote:
		all_puzzles.append(r)

	var num_buttons = grid.get_child_count()
	var nb = float(max(num_buttons, 1))
	total_pages = int(ceil(float(all_puzzles.size()) / nb))
	if total_pages <= 0:
		total_pages = 1
	left_button.disabled = true
	right_button.disabled = total_pages == 1

func button_pressed(button):
	var button_index := grid.get_children().find(button)
	if button_index == -1:
		return
	var global_index := (page_num - 1) * grid.get_child_count() + button_index
	if global_index < 0 or global_index >= all_puzzles.size():
		return

	selected_entry = all_puzzles[global_index]
	var tex := await _get_thumbnail_texture(selected_entry)
	thumbnail.texture = tex
	_update_size_selector(selected_entry.get("size_options", [100]))
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
		var tex_node = button.get_child(0)
		if puzzle_index >= all_puzzles.size():
			if tex_node and tex_node is TextureRect:
				tex_node.texture = null
			button.disabled = true
			continue
		button.disabled = false
		if tex_node and tex_node is TextureRect:
			var entry: Dictionary = all_puzzles[puzzle_index]
			tex_node.texture = await _get_thumbnail_texture(entry)
			tex_node.size = button.size

func _on_start_puzzle_pressed() -> void:
	if selected_entry.is_empty():
		_show_simple_popup("No Puzzle Selected", "Please select a puzzle first.")
		return
	loading.show()
	await get_tree().process_frame

	var choice: Dictionary = {}
	if str(selected_entry.get("source", "local")) == "remote":
		choice = await _remote_source.resolve_choice(selected_entry, selected_size, _downloader)
		if choice.is_empty():
			loading.hide()
			_show_simple_popup("Download Error", "Unable to download puzzle assets. Please try again.")
			return
	else:
		choice = _local_source.resolve_choice(selected_entry, selected_size, _downloader)

	PuzzleVar.choice = choice

	if PuzzleVar.is_online_selector:
		await FireAuth.set_lobby_puzzle_choice(PuzzleVar.choice, PuzzleVar.lobby_number)
		PuzzleVar.is_online_selector = false
		if NetworkManager.join_server():
			return
		loading.hide()
		_show_simple_popup("Connection Error", "Failed to connect to server.")
		return
	get_tree().change_scene_to_file("res://assets/scenes/jigsaw_puzzle_1.tscn")

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
	loading.hide()
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

func _ensure_size_selector() -> void:
	size_selector = panel.get_node_or_null("VBoxContainer/SizeSelector")
	if size_selector == null:
		size_selector = OptionButton.new()
		size_selector.name = "SizeSelector"
		size_selector.custom_minimum_size = Vector2(0, 72)
		size_selector.item_selected.connect(_on_size_selected)
		$Panel/VBoxContainer.add_child(size_selector)
		$Panel/VBoxContainer.move_child(size_selector, 1)

func _update_size_selector(sizes: Array) -> void:
	size_selector.clear()
	var safe_sizes: Array = []
	for s in sizes:
		var v := int(s)
		if v > 0:
			safe_sizes.append(v)
	if safe_sizes.is_empty():
		safe_sizes = [100]
	for s in safe_sizes:
		size_selector.add_item("~%d pieces" % s, s)
	selected_size = int(safe_sizes[0])
	size_label.text = str(selected_size)

func _on_size_selected(index: int) -> void:
	selected_size = size_selector.get_item_id(index)
	size_label.text = str(selected_size)

func _get_thumbnail_texture(entry: Dictionary) -> Texture2D:
	if str(entry.get("source", "local")) == "local":
		return load(str(entry.get("thumb_local_path", "")))

	var puzzle_id := str(entry.get("id", ""))
	var version := int(entry.get("asset_version", 1))
	var thumb_cache := _cache.get_version_dir(puzzle_id, version).path_join("thumb.jpg")
	if FileAccess.file_exists(thumb_cache):
		return ImageTexture.create_from_image(Image.load_from_file(thumb_cache))

	var thumb_path := str(entry.get("thumb_path", ""))
	if thumb_path == "":
		return null
	var task = await Firebase.Storage.ref(thumb_path).get_data()
	if task == null or int(task.result) != OK:
		return null
	if int(task.response_code) < 200 or int(task.response_code) >= 300:
		return null
	_cache.write_bytes(thumb_cache, task.data)
	return ImageTexture.create_from_image(Image.load_from_file(thumb_cache))

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
