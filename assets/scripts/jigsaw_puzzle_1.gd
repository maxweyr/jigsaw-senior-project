extends Node2D

##=========================
## Puzzle Scene Controller
##=========================

var is_muted
var mute_button: Button
var unmute_button: Button
var offline_button: Button
var online_status_label: Label
var connected_players = []
var selected_puzzle_dir = ""
var selected_puzzle_name = ""
var piece_scene = preload("res://assets/scenes/Piece_2d.tscn")

@onready var back_button = $UI_Button/Back
@onready var loading = $LoadingScreen
@onready var piece_spawner = $PieceSpawner

# Called when the node enters the scene tree for the first time.
func _ready():
	loading.show()
	name = "JigsawPuzzleNode"
	
	# error check puzzle var choice
	if PuzzleVar.choice == null or PuzzleVar.choice.is_empty():
		printerr("JigsawPuzzleNode: PuzzleVar.choice is not set! Returning to menu.")
		get_tree().change_scene_to_file("res://assets/scenes/new_menu.tscn")
		return # Stop if no puzzle selected
	
	# set puzzle specific info
	selected_puzzle_dir = PuzzleVar.choice["base_file_path"] + "_" + str(PuzzleVar.choice["size"])
	PuzzleVar.selected_puzzle_dir = selected_puzzle_dir
	selected_puzzle_name = PuzzleVar.choice["base_name"] + str(PuzzleVar.choice["size"])
	is_muted = false
	
	# connecting signals
	if NetworkManager.is_online: # show online UI elements if actually online
		create_online_status_label()
		if NetworkManager.player_joined.is_connected(_on_player_joined) == false:
			NetworkManager.player_joined.connect(_on_player_joined)
		if NetworkManager.player_left.is_connected(_on_player_left) == false:
			NetworkManager.player_left.connect(_on_player_left)
	
	# back button is connected only once
	if back_button and not back_button.pressed.is_connected(_on_back_pressed):
		back_button.pressed.connect(_on_back_pressed)
	
	# load up reference image
	var ref_image = PuzzleVar.choice["file_path"]
	if FileAccess.file_exists(ref_image):
		$Image.texture = load(ref_image) # Load the image
	else:
		printerr("WARNING::JigsawPuzzle1: Could not find reference image for: ", ref_image)
	
	# reset puzzle var state
	PuzzleVar.background_clicked = false
	PuzzleVar.piece_clicked = false
	PuzzleVar.ordered_pieces_array.clear() # clear before spawning/parsing
	
	# parse puzzle pieces
	if not parse_pieces_json():
		printerr("ERROR::JigsawPuzzle1: Failed to parse pieces.json for %s" % selected_puzzle_dir)
		loading.hide(); get_tree().change_scene_to_file("res://assets/scenes/new_menu.tscn");
		return
	if not parse_adjacent_json():
		printerr("ERROR::JigsawPuzzle1: Failed to parse adjacent.json for %s" % selected_puzzle_dir)
		loading.hide(); get_tree().change_scene_to_file("res://assets/scenes/new_menu.tscn");
		return
	
	# resize array
	PuzzleVar.ordered_pieces_array.resize(PuzzleVar.global_num_pieces)
	
	# conditional spawning
	if NetworkManager.is_server:
		print("JigsawPuzzle1 (Server %d): Spawning pieces via MultiplayerSpawner..." % multiplayer.get_unique_id())
		spawn_pieces_online_server()
		# server loads initial state after spawning if applicable
		if FireAuth.is_online:
			print("JigsawPuzzleNode (Server %d): Loading initial state from Firebase..." % multiplayer.get_unique_id())
			await load_and_apply_saved_state_server()
	
	elif NetworkManager.is_offline_authority:
		print("JigsawPuzzleNode (Offline %d): Spawning pieces locally..." % multiplayer.get_unique_id())
		spawn_pieces_offline_local()
		# offline client attempts to load state after spawning if applicable
		if FireAuth.is_online:
			print("JigsawPuzzleNode (Offline %d): Loading saved state from Firebase..." % multiplayer.get_unique_id())
			await load_and_apply_saved_state_offline()
	
	# else: online client, no need to handle anything here
	
	loading.hide()
	
	#z_index = 0
	#
	## create puzzle pieces and place in scene
	#PuzzleVar.load_and_or_add_puzzle_random_loc(self, sprite_scene, selected_puzzle_dir, true)
#
	#if FireAuth.is_online:
		## client is connected to firebase
		#var puzzle_name_with_size = PuzzleVar.choice["base_name"] + "_" + str(PuzzleVar.choice["size"])
		#await load_firebase_state(puzzle_name_with_size)
		#
	##if not is_online_mode and FireAuth.offlineMode == 0:
		##FireAuth.add_active_puzzle(selected_puzzle_name, PuzzleVar.global_num_pieces)
		##FireAuth.add_favorite_puzzle(selected_puzzle_name)

##===========================
## Spawning Helper Functions
##===========================

func spawn_pieces_online_server() -> void:
	if not NetworkManager.is_server: return
	var spawn_area = get_viewport_rect()
	for i in range(PuzzleVar.global_num_pieces):
		var initial_data = {
			"id": i,
			"piece_image_path": selected_puzzle_dir + "/pieces/raster/" + str(i) + ".png",
			"initial_group": i, # pieces start in their own group
			# server determines initial random position for all clients
			"initial_position": Vector2(randi_range(50, int(spawn_area.size.x - 50)), randi_range(50, int(spawn_area.size.y - 50)))
		}
		piece_spawner.spawn(initial_data) # use the spawner

func spawn_pieces_offline_local():
	if not NetworkManager.is_offline_authority: return
	var spawn_area = get_viewport_rect()
	for i in range(PuzzleVar.global_num_pieces):
		var piece = piece_scene.instantiate()
		add_child(piece)
		
		var initial_data = {
			"id": i,
			"piece_image_path": selected_puzzle_dir + "/pieces/raster/" + str(i) + ".png",
			"initial_group": i, # pieces start in their own group
			# server determines initial random position for all clients
			"initial_position": Vector2(randi_range(50, int(spawn_area.size.x - 50)), randi_range(50, int(spawn_area.size.y - 50)))
		}
	
		if piece.has_method("_initialize"):
			piece._initialize(initial_data)
		else:
			printerr("Piece scene is missing _initialize function!")
		
		# add to group and array for local tracking
		if i >= 0 and i < PuzzleVar.ordered_pieces_array.size():
			PuzzleVar.ordered_pieces_array[i] = piece
		else:
			printerr("Offline spawn ID %d out of bounds for ordered_pieces_array (size %d)" % [i, PuzzleVar.ordered_pieces_array.size()])

##=========================
## State Loading Functions
##=========================

# server loads authoritative state from Firebase
func load_and_apply_saved_state_server():
	if NetworkManager.is_server: return
	
	print("SERVER: Loading Initial Puzzle State From Firebase...")
	var saved_piece_data: Array = await FireAuth.get_puzzle_state_server()
	if saved_piece_data == null or saved_piece_data.is_empty():
		print("SERVER: No saved state found or error loading for puzzle '%s'." % selected_puzzle_name)
		return
	
	print("SERVER: Applying loaded state to authoritative pieces...")
	var applied_count = 0
	await get_tree().process_frame
	
	for data in saved_piece_data:
		if not typeof(data) == TYPE_DICTIONARY or not data.has_all(["ID", "CenterLocation", "GroupID"]):
			printerr("SERVER: Invalid data format in saved state: ", data)
			continue
		
		var idx = data["ID"]
		if not typeof(idx) == TYPE_INT or idx < 0 or idx >= PuzzleVar.ordered_pieces_array.size():
			printerr("SERVER: Saved state ID '%s' invalid or out of bounds." % str(idx))
			continue
		
		# get pieces from the array populated by _piece_spawned
		var piece = PuzzleVar.ordered_pieces_array[idx]
		if not is_instance_valid(piece):
			printerr("SERVER: Piece node for ID %d not valid when applying state." % idx)
			continue
		
		# apply state directly => replicated by synchronizer
		var center_location = data["CenterLocation"]
		if typeof(center_location) == TYPE_DICTIONARY and center_location.has_all(["x", "y"]):
			piece.position = Vector2(center_location["x"], center_location["y"])
		else:
			printerr("SERVER: Invalid CenterLocation format for piece %d: %s" % [idx, str(center_location)])
		
		if typeof(data["GroupID"]) == TYPE_INT:
			piece.group_number = data["GroupID"]
		else:
			printerr("SERVER: Invalid GroupID format for piece %d: %s" % [idx, str(data["GroupID"])])
		
		applied_count += 1
	
	print("SERVER: Applied state to %d pieces." % applied_count)

# Offline client loads its personal saved state from Firebase
func load_and_apply_saved_state_offline():
	if not NetworkManager.is_offline_authority: return
	var puzzle_name_with_size = PuzzleVar.choice["base_name"] + "_" + str(PuzzleVar.choice["size"])
	
	print("OFFLINE: Loading saved puzzle state '%s' from Firebase..." % puzzle_name_with_size)
	await FireAuth.update_active_puzzle(puzzle_name_with_size)
	var saved_piece_data: Array = await FireAuth.get_puzzle_state(puzzle_name_with_size)
	
	if saved_piece_data == null or saved_piece_data.is_empty():
		print("OFFLINE: No saved state found or error loading for puzzle '%s'." % selected_puzzle_name)
		return
	
	print("OFFLINE: Applying loaded state to local pieces...")
	var applied_count = 0
	for data in saved_piece_data:
		if not typeof(data) == TYPE_DICTIONARY or not data.has_all(["ID", "CenterLocation", "GroupID"]):
			printerr("OFFLINE: Invalid data format in saved state: ", data)
			continue
		
		var idx = data["ID"]
		if not typeof(idx) == TYPE_INT or idx < 0 or idx >= PuzzleVar.ordered_pieces_array.size():
			printerr("OFFLINE: Saved state ID '%s' invalid or out of bounds." % str(idx))
			continue
		
		# get pieces from the array populated by _piece_spawned
		var piece = PuzzleVar.ordered_pieces_array[idx]
		if not is_instance_valid(piece):
			printerr("OFFLINE: Piece node for ID %d not valid when applying state." % idx)
			continue
		
		# apply state directly to local pieces
		var center_location = data["CenterLocation"]
		if typeof(center_location) == TYPE_DICTIONARY and center_location.has_all(["x", "y"]):
			piece.position = Vector2(center_location["x"], center_location["y"])
		else:
			printerr("OFFLINE: Invalid CenterLocation format for piece %d: %s" % [idx, str(center_location)])
		
		if typeof(data["GroupID"]) == TYPE_INT:
			piece.group_number = data["GroupID"]
		else:
			printerr("OFFLINE: Invalid GroupID format for piece %d: %s" % [idx, str(data["GroupID"])])
		
		applied_count += 1
	
	print("OFFLINE: Applied state to %d pieces." % applied_count)

# Load state from Firebase (for offline mode)
func load_firebase_state(p_name):
	print("LOADING STATE")
	var saved_piece_data: Array
	if(NetworkManager.is_online):
		print("SERVER: SYNC P LOC")
		update_online_status_label("Syncing puzzle state...")
		saved_piece_data = await FireAuth.get_puzzle_state_server()
		print("SERVER: SYNC P LOC")
		
	else: 
		await FireAuth.update_active_puzzle(p_name)
		saved_piece_data = await FireAuth.get_puzzle_state(p_name)
	var notComplete = 0
	var groupArray = []
	for idx in range(len(saved_piece_data)):
		var data = saved_piece_data[idx]
		var groupId = data["GroupID"]
		if groupId not in groupArray:
			groupArray.append(groupId)
	
		if len(groupArray) > 1:
			notComplete = 1
			break
		
	if(notComplete):
		# Adjust pieces to their saved positions and assign groups
		for idx in range(len(saved_piece_data)):
			var data = saved_piece_data[idx]
			var piece = PuzzleVar.ordered_pieces_array[idx]

			# Set the position from the saved data
			var center_location = data["CenterLocation"]
			piece.position = Vector2(center_location["x"], center_location["y"])

			# Assign the group number
			piece.group_number = data["GroupID"]

		# Collect all unique group IDs from the saved data
		var unique_group_ids = []
		for data in saved_piece_data:
			if data["GroupID"] not in unique_group_ids:
				unique_group_ids.append(data["GroupID"])

		# Re-group all pieces based on their group number
		for group_id in unique_group_ids:
			var group_pieces = []
			for piece in PuzzleVar.ordered_pieces_array:
				if piece.group_number == group_id:
					group_pieces.append(piece)

			if group_pieces.size() > 1:
				# Snap and connect all pieces in this group
				var reference_piece = group_pieces[0]
				for other_piece in group_pieces.slice(1, group_pieces.size()):
					reference_piece.snap_and_connect(other_piece.ID, 1)

# Network event handlers
func _on_player_joined(_client_id, client_name):
	connected_players.append(client_name)
	update_online_status_label()

func _on_player_left(_client_id, client_name):
	connected_players.erase(client_name)
	update_online_status_label()

# Create and update the online status label
func create_online_status_label():
	online_status_label = Label.new()
	online_status_label.text = "Online Mode"
	online_status_label.add_theme_font_size_override("font_size", 20)
	online_status_label.add_theme_color_override("font_color", Color(0, 1, 0))
	online_status_label.position = Vector2(20, 20)
	add_child(online_status_label)
	
	update_online_status_label()

func update_online_status_label(custom_text = ""):
	if not online_status_label:
		return
		
	if custom_text != "":
		online_status_label.text = custom_text
		return
		
	var player_count = connected_players.size() + 1  # +1 for self
	online_status_label.text = "Online Mode - " + str(player_count) + " player"
	if player_count != 1:
		online_status_label.text += "s"
	
	if connected_players.size() > 0:
		online_status_label.text += ": " + ", ".join(connected_players)

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta):
	pass

# Handle esc
func _input(event):
	# Check if the event is a key press event
	if event is InputEventKey and event.is_pressed() and event.echo == false:
		# Check if the pressed key is the Escape key
		if event.keycode == KEY_ESCAPE:
			# Exit the game
			get_tree().quit()
			
		if event.keycode == 76: #if key press is l
			print("load pieces")
			pass # load the puzzle pieces here from the database
			
	if event is InputEventKey:
		if event.is_pressed():
			if event.keycode == KEY_P:
				# Arrange grid
				arrange_grid()
			elif event.keycode == KEY_M:
				if is_muted == false:
					on_mute_button_press()
					is_muted = true
				else:
					on_unmute_button_press()
					is_muted = false
			#elif event.keycode == KEY_MINUS: # lower volume
				#adjust_volume(-4)
			#elif event.keycode == KEY_EQUAL: # raise volume
				#adjust_volume(4)
				
	if PuzzleVar.snap_found == true:
		print("snap found")
		PuzzleVar.snap_found = false
		
	if event is InputEventMouseButton and event.pressed:
		if PuzzleVar.background_clicked == false:
			PuzzleVar.background_clicked = true
		else:
			PuzzleVar.background_clicked = false
		
# This function parses pieces.json which contains the bounding boxes around each piece.  The
# bounding box coordinates are given as pixel coordinates in the global image.
func parse_pieces_json():
	print("Calling parse_pieces_json")
	
	var json_path_new = selected_puzzle_dir + "/pieces/pieces.json"
	
	print(json_path_new)
	# Load the JSON file for the pieces.json
	var file = FileAccess.open(json_path_new, FileAccess.READ)

	if !file:
		print("ERROR LOADING FILE")
		return false
	var json = file.get_as_text()
	file.close()

	# Parse the JSON data
	var json_parser = JSON.new()
	var data = json_parser.parse(json)
	
	if data == OK: # if the data is valid, go ahead and parse
		var num_pieces = json_parser.data.size()
		print("Number of pieces " + str(num_pieces))
		
		for n in num_pieces: # for each piece, add it to the global coordinates list
			PuzzleVar.global_coordinates_list[str(n)] =  json_parser.data[str(n)]
		return true
	else:
		print("INVALID DATA")
		return false
	#print("GCL: ", PuzzleVar.global_coordinates_list)
# This function parses adjacent.json which contains information about which pieces are 
# adjacent to a given piece
func parse_adjacent_json():
	print("Calling parse_adjacent_json")
	
	# Load the JSON file for the pieces.json
	var json_path = selected_puzzle_dir + "/adjacent.json"
	var file = FileAccess.open(json_path, FileAccess.READ)

	if file: #if the file was opened successfully
		var json = file.get_as_text()
		file.close()

		# Parse the JSON data
		var json_parser = JSON.new()
		var data = json_parser.parse(json)
		print("starting reading adjacent.json")
		if data == OK:
			var num_pieces = json_parser.data.size()
			PuzzleVar.global_num_pieces = num_pieces
			print("Number of pieces " + str(num_pieces))
			for n in num_pieces: # for each piece, add the adjacent pieces to the list
				PuzzleVar.adjacent_pieces_list[str(n)] =  json_parser.data[str(n)]
		return true
	else:
		return false


# The purpose of this function is to build a grid of the puzzle piece numbers
func build_grid(): 
	var grid = {}
	var midpoints = []
	var temp_grid = []
	var final_grid = []

	#create an entry for each puzzle piece
	for x in range(PuzzleVar.global_num_pieces):
		grid[x] = [x]
		
	# compute the midpoint of all pieces
	for x in range(PuzzleVar.global_num_pieces):
		#compute the midpont of each piece
		var node_bounding_box = PuzzleVar.global_coordinates_list[str(x)]
		var midpoint = Vector2((node_bounding_box[2]+node_bounding_box[0])/2, (node_bounding_box[3]+node_bounding_box[1])/2)
		midpoints.append(midpoint) # append the midpoint of each piece

	var row_join_counter = 1
	while row_join_counter != 0:
		row_join_counter = 0
		
		for x in range(PuzzleVar.global_num_pieces): # run through all the piece groups
			var cur_pieces_list = grid[x]
			
			if cur_pieces_list.size() > 0:
				var adjacent_list = PuzzleVar.adjacent_pieces_list[str(cur_pieces_list[-1])] #get the adjacent list of the rightmost piece

				var current_midpoint = midpoints[int(cur_pieces_list[-1])] # get the midpoint of the rightmost piece
				
				for a in adjacent_list:
					#compute the difference in midpoint
					var angle = current_midpoint.angle_to_point(midpoints[int(a)])
					
					#get adjacent bounding box
					var node_bounding_box = PuzzleVar.global_coordinates_list[str(cur_pieces_list[-1])]
					
					if midpoints[int(a)][0] > node_bounding_box[2]: # adjacent piece is to the right
						if grid[int(a)].size() > 0:
							var temp_list = cur_pieces_list
							temp_list += grid[int(a)]
							grid[x] = temp_list
							grid[int(a)] = [] # remove entries from this piece
							row_join_counter += 1
			
	# add the rows to a temporary grid
	for x in range(PuzzleVar.global_num_pieces):
		if (grid[x]).size() > 0:
			temp_grid.append(grid[x])
			
	#find the top row
	for row_num in range(temp_grid.size()):
		var first_element = (temp_grid[row_num])[0] # get the first element of the row
		if (PuzzleVar.global_coordinates_list[str(first_element)])[1] == 0: # get y-coordinate of first element
			final_grid.append(temp_grid[row_num]) # add the row to the final grid
			temp_grid.remove_at(row_num) # remove the row from the temporary grid
			break
			
	#sort the rows
	var row_y_values = []
	var unsorted_rows = {}
	
	# build an array of Y-values of the bounding boxes of the first element and
	# build a corresponding dictionary 
	for row_num in range(temp_grid.size()):
		var first_element = (temp_grid[row_num])[0] # get the first element of the row
		var y_value = (PuzzleVar.global_coordinates_list[str(first_element)])[1] # get the upper left Y coordinate
		row_y_values.append(y_value)
		unsorted_rows[y_value] = temp_grid[row_num]
			
	row_y_values.sort() # sort the y-values
	for x in range(row_y_values.size()):
		var row = unsorted_rows[row_y_values[x]]
		final_grid.append(row) # add the rows in sorted order
	
	# print the final grid
	for x in range(final_grid.size()):
		print(final_grid[x])
	return final_grid

# Arrange puzzle pieces based on the 2D grid returned by build_grid
func arrange_grid():
	# Get the 2D grid from build_grid
	var grid = build_grid()
	var cell_piece = PuzzleVar.ordered_pieces_array[0]
	var cell_width = cell_piece.piece_width
	var cell_height = cell_piece.piece_height
	
	# Loop through the grid and arrange pieces
	for row in range(grid.size()):
		for col in range(grid[row].size()):
			var piece_id = grid[row][col]
			var piece = PuzzleVar.ordered_pieces_array[piece_id]
			
			# Compute new position based on the grid cell
			var new_position = Vector2(col * cell_width * 1.05, row * cell_height * 1.05)
			piece.move_to_position(new_position)
			
func play_snap_sound():
	var snap_sound = preload("res://assets/sounds/ding.mp3")
	var audio_player = AudioStreamPlayer.new()
	audio_player.stream = snap_sound
	add_child(audio_player)
	audio_player.play()
	# Manually queue_free after sound finishes
	await audio_player.finished
	audio_player.queue_free()
	
func on_mute_button_press():
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), true)  # Mute the audio
		
func on_unmute_button_press():
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), false)  # Mute the audio

#Logic for showing the winning labels and buttons
func show_win_screen():
	#-------------------------LABEL LOGIC------------------------#
	var label = Label.new()
	
	# Set the text for the Label
	label.text = "You've Finished the Puzzle!"
	
	# Set the font size as well as the color
	label.add_theme_font_size_override("font_size", 200)
	label.add_theme_color_override("font_color", Color(0, 204, 0))
	
	# Load the font file 
	var font = load("res://assets/fonts/KiriFont.ttf") as FontFile
	label.add_theme_font_override("font", font)
	
	# Change label poistion and add the label to the current scene
	label.position = Vector2(-1000, -700)
	get_tree().current_scene.add_child(label)

	#-------------------------BUTTON LOGIC-----------------------#
	var button = $MainMenu
	button.visible = true
	# Change the font size
	button.add_theme_font_override("font", font)
	button.add_theme_font_size_override("font_size", 120)
	# Change the text color to white
	var font_color = Color(1, 1, 1)  # RGB (1, 1, 1) = white
	button.add_theme_color_override("font_color", font_color)
	button.connect("pressed", Callable(self, "on_main_menu_button_pressed")) 
	
	# If in online mode, leave the puzzle on the server
	if NetworkManager.is_online:
		NetworkManager.leave_puzzle()
	elif !NetworkManager.is_online and FireAuth.is_online:
		FireAuth.remove_current_user_from_activePuzzle(selected_puzzle_name)

# Handles leaving the puzzle scene, saving state, and disconnecting if online client
func _on_back_pressed() -> void:
	loading.show()
	# 1. Save puzzle state if needed
	#    Saving might be relevant even if NetworkManager.is_online is true,
	#    if we use Firebase alongside the server for persistence
	if FireAuth.is_online and !NetworkManager.is_online: # Check if Firebase is initialized/logged in
		print("Saving puzzle state to Firebase before leaving...")
		await FireAuth.write_puzzle_state(
			PuzzleVar.ordered_pieces_array,
			PuzzleVar.choice["base_name"] + "_" + str(PuzzleVar.choice["size"]),
			PuzzleVar.global_num_pieces
		)
		
		# Jumpstart
		#await FireAuth.write_puzzle_state_server(1)

	# 2. Handle multiplayer disconnection if this is an online client
	if NetworkManager.is_online and not NetworkManager.is_server:
		print("Client leaving online session. Closing connection...")

		# Access the MultiplayerAPI instance
		if multiplayer:
			NetworkManager.leave_puzzle()
		else:
			printerr("ERROR: NetworkManager.multiplayer is not available to close connection.")

	# 3. Clean up local scene resources
	print("Cleaning up puzzle scene resources...")

	# Free all puzzle pieces currently in the scene
	for piece in get_tree().get_nodes_in_group("puzzle_pieces"):
		piece.queue_free()

	# Clear global puzzle variables to reset state for the next puzzle
	PuzzleVar.ordered_pieces_array.clear()
	PuzzleVar.global_coordinates_list.clear()
	PuzzleVar.adjacent_pieces_list.clear()
	PuzzleVar.global_num_pieces = 0
	print("Puzzle resources cleared.")

	# 4. Change back to the puzzle selection scene
	print("Returning to puzzle selection screen.")
	loading.hide()
	get_tree().change_scene_to_file("res://assets/scenes/new_menu.tscn")


func _piece_spawned(piece_node: Node, data: Variant) -> void:
	if not is_instance_valid(piece_node):
		printerr("Received spawn callback for invalid node instance.")
		return
	if not piece_node is Piece_2d:
		printerr("Spawned node is not a Piece_2d type.")
		return

	# check data is a dictionary
	if not typeof(data) == TYPE_DICTIONARY:
		printerr("Spawn data is not a dictionary.")
		return

	print("Peer %d: Initializing spawned piece ID %d" % [multiplayer.get_unique_id(), data.get("id", -1)])
	if piece_node.has_method("_initialize"):
		piece_node._initialize(data) # Call initialization function on the piece
	else:
		printerr("Piece scene is missing _initialize function!")
	
	# add to group and tracking array (needed on clients too for local access)
	piece_node.add_to_group("puzzle_pieces")
	var piece_id = data.get("id", -1)
	if piece_id >= 0 and piece_id < PuzzleVar.ordered_pieces_array.size():
		PuzzleVar.ordered_pieces_array[piece_id] = piece_node
	else:
		printerr("Spawned piece ID %d out of bounds for ordered_pieces_array (size %d)" % [piece_id, PuzzleVar.ordered_pieces_array.size()])
