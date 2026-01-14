extends Control

var progress_arr = []
var overlay
@onready var nickname_label: Label = $VBoxContainer/NicknameLabel
var rename_popup: PopupPanel
var nickname_line_edit: LineEdit
var joining_online := false
const STATUS_FONT = preload("res://assets/fonts/KiriFont.ttf")
const STATUS_TEXT_COLOR = Color(0.941176, 0.67451, 0.0431373, 1)

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
		else:
			print("An error occured trying to access the path")
		PuzzleVar.open_first_time = false
	
	# Connect to network signals
	if NetworkManager:
		NetworkManager.client_connected.connect(_on_client_connected)
		NetworkManager.connection_failed.connect(_on_connection_failed)
	if FireAuth:
		FireAuth.logged_in.connect(_on_login)
		FireAuth.login_failed.connect(_on_login)
	_refresh_nickname_display()

	if PuzzleVar.auto_rejoin_online:
		PuzzleVar.auto_rejoin_online = false
		await _auto_rejoin_after_kick()

func _process(_delta):
	pass

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

func _on_logged_in() -> void:
	pass

func _on_select_puzzle_pressed():
	$AudioStreamPlayer.play() # doesn't work, switches scenes too fast
	# switches to a new scene that will ask you to
	# actually select what image you want to solve

	get_tree().change_scene_to_file("res://assets/scenes/select_puzzle.tscn")

func _on_play_online_pressed():
	if joining_online:
		return
	$AudioStreamPlayer.play()
	if !FireAuth.is_online:
		var popup = AcceptDialog.new()
		popup.title = "Offline Mode"
		popup.dialog_text = "Cannot play online while in offline mode. Please check your internet connection."
		add_child(popup)
		popup.popup_centered()
		joining_online = false
		return

	joining_online = true
	PuzzleVar.choice = {}
	PuzzleVar.is_online_selector = false

	var lobby_choice := await FireAuth.get_lobby_choice(PuzzleVar.lobby_number)
	if not lobby_choice.is_empty():
		PuzzleVar.choice = lobby_choice
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

func _on_connection_failed():
	_clear_status_label("ConnectingLabel")
	joining_online = false
	
	print("Connection to server failed")
	
	# Show error message
	var error_popup = AcceptDialog.new()
	error_popup.title = "Connection Error"
	error_popup.dialog_text = "Connection to server failed."
	add_child(error_popup)
	error_popup.popup_centered()

func _join_online_with_choice():
	if PuzzleVar.choice.is_empty():
		joining_online = false
		_show_simple_popup("No Puzzle Selected", "Please wait for a puzzle selection before joining.")
		return
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
		joining_online = false
		_show_simple_popup("Lobby Waiting", "No puzzle selected yet. Please try again in a moment.")
		return
	PuzzleVar.choice = choice
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
	PuzzleVar.choice = choice
	_join_online_with_choice()

func _on_quit_pressed():
	# quit the game
	if(OS.get_name() == "Linux"):
		print("shutting down")
		OS.execute("shutdown", ["h", "now"])
	else:
		get_tree().quit()
		print("Quitting game")
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

func _show_simple_popup(title: String, message: String):
	var popup = AcceptDialog.new()
	popup.title = title
	popup.dialog_text = message
	add_child(popup)
	popup.popup_centered()
