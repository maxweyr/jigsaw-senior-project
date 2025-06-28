extends Control

var progress_arr = []
var overlay

func _ready():
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
	$AudioStreamPlayer.play()
	PuzzleVar.choice = await PuzzleVar.get_online_choice()
	print("ONLINE CHOICE = ", PuzzleVar.choice)
	# Check if we have network connectivity
	if !FireAuth.is_online:
		# Show a message about being offline
		var popup = AcceptDialog.new()
		popup.title = "Offline Mode"
		popup.dialog_text = "Cannot play online while in offline mode. Please check your internet connection."
		add_child(popup)
		popup.popup_centered()
		return
	
	## Update Firebase mode
	#if FireAuth.is_online:
		#FireAuth.addUserMode("Multiplayer")
	
	# Attempt to connect to the hard-coded server
	print("Attempting to connect to server...")
	if NetworkManager.join_server():
		# Show simple connecting message
		var connecting_label = Label.new()
		connecting_label.name = "ConnectingLabel"
		connecting_label.text = "Connecting to server..."
		connecting_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		connecting_label.position = Vector2(get_viewport_rect().size.x / 2 - 100, get_viewport_rect().size.y / 2)
		add_child(connecting_label)
		await FireAuth.update_my_player_entry(1)
	else:
		print("Failed to initiate connection")
		# Show error message
		var error_popup = AcceptDialog.new()
		error_popup.title = "Connection Error"
		error_popup.dialog_text = "Failed to connect to server."
		add_child(error_popup)
		error_popup.popup_centered()

# Network signal handlers
func _on_client_connected():
	print("Connected to server successfully")
	
	# Remove connecting label if it exists
	var connecting_label = get_node_or_null("ConnectingLabel")
	if connecting_label:
		connecting_label.queue_free()
	
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
	# Remove connecting label if it exists
	var connecting_label = get_node_or_null("ConnectingLabel")
	if connecting_label:
		connecting_label.queue_free()
	
	print("Connection to server failed")
	
	# Show error message
	var error_popup = AcceptDialog.new()
	error_popup.title = "Connection Error"
	error_popup.dialog_text = "Connection to server failed."
	add_child(error_popup)
	error_popup.popup_centered()

func _on_quit_pressed():
	# quit the game
	if(OS.get_name() == "Linux"):
		print("shutting down")
		OS.execute("shutdown", ["h", "now"])
	else:
		print("ERROR: Attempted System Shutdown, not on linux! Try 'Esc'")

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
	if event.is_action_pressed("ui_cancel"):
		get_tree().quit()

func _on_login() -> void:
	overlay.visible = false # Hide the overlay after login completes
