extends Control

var progress_arr = []
var overlay
var status_label: Label = null

func _ready():
	#await Firebase.Auth.remove_auth()
	create_overlay()
	# Prevents pieces from being loaded multiple times
	if(PuzzleVar.open_first_time):
		print("Adding Puzzles")
		load(PuzzleVar.path)
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

func _process(_delta):
	pass

# Helper to show status messages consistently
func _show_status_message(text: String, name: String = "StatusLabel"):
	_remove_status_message() # Remove previous message
	status_label = Label.new()
	status_label.name = name
	status_label.text = text
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	status_label.size = Vector2(400, 100) # Adjust size
	status_label.position = get_viewport_rect().size / 2.0 - status_label.size / 2.0
	add_child(status_label)

# Helper to remove status messages
func _remove_status_message():
	if is_instance_valid(status_label):
		status_label.queue_free()
		status_label = null

# Helper Function to create overlay
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

## Button Handelers

func _on_start_random_pressed():
	$AudioStreamPlayer.play()
	NetworkManager.set_offline_mode()
	PuzzleVar.choice = PuzzleVar.get_random_puzzles()
	# load the texture and get the size of the puzzle image so that the game
	get_tree().change_scene_to_file("res://assets/scenes/jigsaw_puzzle_1.tscn")

func _on_logged_in() -> void:
	pass

func _on_select_puzzle_pressed():
	$AudioStreamPlayer.play()
	NetworkManager.set_offline_mode()

	get_tree().change_scene_to_file("res://assets/scenes/select_puzzle.tscn")

func _on_play_online_pressed():
	$AudioStreamPlayer.play()
	
	# Check if we have network connectivity
	if not FireAuth.is_online:
		printerr("MainMenu: Cannot play online, FireAuth reports offline.")
		var popup = AcceptDialog.new()
		popup.title = "Offline"
		popup.dialog_text = "Cannot play online.\nPlease check your internet connection and login status."
		add_child(popup)
		popup.popup_centered()
		return
	
	# Attempt to connect to the hard-coded server
	print("Attempting to connect to server...")
	if NetworkManager.join_server():
		# Show connecting message
		_show_status_message("Connecting to server...", "ConnectingLabel")
		print("MainMenu: Connection initiated. Waiting for callbacks...")
	else:
		print("MainMenu: NetworkManager.join_server() returned false.")
		_show_status_message("Failed to initiate connection.\nAre you already online?")

## Network signal handlers

func _on_client_connected():
	print("MainMenu: _on_client_connected signal received.")
	# Connection is live, now wait for server to send puzzle info
	_show_status_message("Connected!\nWaiting for puzzle info...", "WaitingLabel")

# *** NEW Handler for when puzzle info arrives ***
func _on_puzzle_info_received(puzzle_id: String):
	print("MainMenu: _on_puzzle_info_received signal received with ID: ", puzzle_id)
	_remove_status_message() # Remove "Waiting..." message

	PuzzleVar.choice = puzzle_id
	
	print("MainMenu: Puzzle choice set from server. Changing scene...")
	get_tree().change_scene_to_file("res://assets/scenes/jigsaw_puzzle_1.tscn")

func _on_connection_failed():
	# Remove status message if it exists
	_remove_status_message()
	var error_popup = AcceptDialog.new()
	error_popup.title = "Connection Error"
	error_popup.dialog_text = "Failed to connect to the server.\nPlease check the server status and your connection."
	add_child(error_popup)
	error_popup.popup_centered()

func _on_quit_pressed():
	# quit the game
	#$AudioStreamPlayer.play() # doesn't work, quits too fast
	get_tree().quit() # closes the scene tree to leave the game

## Firebase Signal Handeler

func _on_login() -> void:
	if is_instance_valid(overlay):
		overlay.visible = false

# this is used to check for events such as a key press
func _input(event):
	if event is InputEventKey and event.pressed and event.echo == false:
		if event.keycode == 68: # if key that is pressed is d
				# toggle debug mode
				PuzzleVar.debug = !PuzzleVar.debug
				if PuzzleVar.debug:
					$Label.show()
				else:
					$Label.hide()
				print("debug mode is: "+str(PuzzleVar.debug))
