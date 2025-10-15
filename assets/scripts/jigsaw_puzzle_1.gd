extends Node2D

# this is the main scene where the game actually occurs for the players to play

var is_muted
var mute_button: Button
var unmute_button: Button
var offline_button: Button
var complete = false;
@onready var back_button = $UI_Button/Back
@onready var loading = $LoadingScreen

# --- Network-related variables ---
var selected_puzzle_dir = ""
var selected_puzzle_name = ""

# --- UI Element Variables ---
var floating_status_box: PanelContainer
var online_status_label: Label

# --- Network Data ---
var connected_players = [] # Array to store connected player names (excluding self)

# --- Constants for Styling ---
const BOX_BACKGROUND_COLOR = Color(0.15, 0.15, 0.2, 0.85) # Dark semi-transparent
const BOX_BORDER_COLOR = Color(0.4, 0.4, 0.45, 0.9)
const BOX_FONT_COLOR = Color(0.95, 0.95, 0.95)

# Called when the node enters the scene tree for the first time.
func _ready():
	loading.show()

	name = "JigsawPuzzleNode"
	selected_puzzle_dir = PuzzleVar.choice["base_file_path"] + "_" + str(PuzzleVar.choice["size"])
	PuzzleVar.selected_puzzle_dir = selected_puzzle_dir
	selected_puzzle_name = PuzzleVar.choice["base_name"] + str(PuzzleVar.choice["size"])
	is_muted = false
	
	if NetworkManager.is_online:
		# Connect to network signals
		NetworkManager.player_joined.connect(_on_player_joined)
		NetworkManager.player_left.connect(_on_player_left)
		#back_button.pressed.connect(_on_back_pressed)
		# Create online status label
		create_floating_player_display()
	
	# load up reference image
	var ref_image = PuzzleVar.choice["file_path"]
	# Load the image
	$Image.texture = load(ref_image)
	
	PuzzleVar.background_clicked = false
	PuzzleVar.piece_clicked = false

	# preload the scenes
	var sprite_scene = preload("res://assets/scenes/Piece_2d.tscn")
	
	parse_pieces_json()
	parse_adjacent_json()
	
	z_index = 0
	
	# create puzzle pieces and place in scene
	PuzzleVar.load_and_or_add_puzzle_random_loc(self, sprite_scene, selected_puzzle_dir, true)

	if FireAuth.is_online and !NetworkManager.is_server:
		# client is connected to firebase
		var puzzle_name_with_size = PuzzleVar.choice["base_name"] + "_" + str(PuzzleVar.choice["size"])
		await load_firebase_state(puzzle_name_with_size)
		
	#if not is_online_mode and FireAuth.offlineMode == 0:
		#FireAuth.add_active_puzzle(selected_puzzle_name, PuzzleVar.global_num_pieces)
		#FireAuth.add_favorite_puzzle(selected_puzzle_name)
	
	# Connect the back button signal
	#var back_button = $UI_Button/Back
	#back_button.connect("pressed", Callable(self, "_on_back_button_pressed"))
	loading.hide()
	
	if NetworkManager.is_online:
		update_online_status_label()

# Load state from Firebase (for offline mode)
func load_firebase_state(p_name):
	print("LOADING STATE")
	var saved_piece_data: Array
	if(NetworkManager.is_online):
		print("FB: Update")
		update_online_status_label("Syncing puzzle state...")
		saved_piece_data = await FireAuth.get_puzzle_state_server()
		print("FB: SYNC")
		
	else: 
		await FireAuth.update_active_puzzle(p_name)
		saved_piece_data = await FireAuth.get_puzzle_state(p_name)
	var notComplete	 = 0
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
	complete = false

#-----------------------------------------------------------------------------
# UI CREATION AND MANAGEMENT
#-----------------------------------------------------------------------------

func create_floating_player_display():
	# Create PanelContainer (the floating box itself)
	floating_status_box = PanelContainer.new()
	floating_status_box.name = "FloatingPlayerDisplayBox"
	
	# Style the PanelContainer
	var style_box = StyleBoxFlat.new()
	style_box.bg_color = BOX_BACKGROUND_COLOR
	style_box.border_width_left = 2
	style_box.border_width_top = 2
	style_box.border_width_right = 2
	style_box.border_width_bottom = 2
	style_box.border_color = BOX_BORDER_COLOR
	style_box.corner_radius_top_left = 6
	style_box.corner_radius_top_right = 6
	style_box.corner_radius_bottom_left = 6
	style_box.corner_radius_bottom_right = 6
	# These margins provide padding INSIDE the box, around the label
	style_box.content_margin_left = 10
	style_box.content_margin_top = 8
	style_box.content_margin_right = 10
	style_box.content_margin_bottom = 8
	floating_status_box.add_theme_stylebox_override("panel", style_box)

	# Position the floating box (e.g., top-right)
	floating_status_box.anchor_left = 1.0 # Anchor to the right
	floating_status_box.anchor_top = 1.0  # Anchor to the bottom
	floating_status_box.anchor_right = 1.0
	floating_status_box.anchor_bottom = 1.0 # Anchor to the bottom
	floating_status_box.offset_left = -270 # Offset from right edge (box width + margin)
	floating_status_box.offset_top = -80     # Margin from bottom
	floating_status_box.offset_right = -20  # Margin from right edge
	floating_status_box.offset_bottom = -20  # Margin from bottom
	# Let height be determined by content, or set offset_bottom for fixed height
	floating_status_box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	floating_status_box.grow_vertical = Control.GROW_DIRECTION_END
	
	floating_status_box.custom_minimum_size = Vector2(250, 0) # Min width 250, height auto
	
	#add_child(floating_status_box)
	var ui_layer = $UI_Button
	ui_layer.add_child(floating_status_box)

	# Create and add the online status label directly to the PanelContainer
	_create_online_status_label_in_box(floating_status_box)


func _create_online_status_label_in_box(parent_node: PanelContainer): # Parent is now the PanelContainer
	online_status_label = Label.new()
	online_status_label.name = "OnlineStatusLabel"
	online_status_label.add_theme_font_size_override("font_size", 20)
	online_status_label.add_theme_color_override("font_color", BOX_FONT_COLOR)
	online_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD # Allow text to wrap if it's too long
	
	# The PanelContainer will handle its child's size based on content and padding.
	# For a Label to fill the width of the PanelContainer (respecting content margins):
	online_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	online_status_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER # Or SIZE_EXPAND_FILL if you want it to take vertical space
	
	parent_node.add_child(online_status_label)
	# update_online_status_label() will be called from _ready or when players change


func update_online_status_label(custom_text=""):
	if not is_instance_valid(online_status_label):
		printerr("Online status label is not valid!") # Use printerr for errors
		return

	if custom_text != "":
		online_status_label.text = custom_text
		return

	var local_player_display_name = "You" # Default name for the local player
	# You can enhance this if you have a stored player name:
	# if MyGameGlobals.has("player_name") and MyGameGlobals.player_name != "":
	# local_player_display_name = MyGameGlobals.player_name
	
	var displayed_players = [local_player_display_name] # Start with self
	displayed_players.append_array(connected_players) # Add other known players

	var player_count = displayed_players.size()
	var status_text = "Active Players (%s): " % player_count
	status_text += ", ".join(displayed_players)
	
	online_status_label.text = status_text


# Network event handlers
func _on_player_joined(_client_id, client_name):
	if not client_name in connected_players:
		connected_players.append(client_name)
	update_online_status_label()

func _on_player_left(_client_id, client_name):
	connected_players.erase(client_name)
	update_online_status_label()

## Create and update the online status label
#func create_online_status_label():
	#online_status_label = Label.new()
	#online_status_label.text = "Online Mode"
	#online_status_label.add_theme_font_size_override("font_size", 20)
	#online_status_label.add_theme_color_override("font_color", Color(0, 1, 0))
	#online_status_label.position = Vector2(20, 20)
	#add_child(online_status_label)
	#
	#update_online_status_label()

#func update_online_status_label(custom_text = ""):
	#if not online_status_label:
		#return
		#
	#if custom_text != "":
		#online_status_label.text = custom_text
		#return
		#
	#var player_count = connected_players.size() + 1  # +1 for self
	#online_status_label.text = "Online Mode - " + str(player_count) + " player"
	#if player_count != 1:
		#online_status_label.text += "s"
	#
	#if connected_players.size() > 0:
		#online_status_label.text += ": " + ", ".join(connected_players)

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
			if event.keycode == KEY_P && Input.is_key_pressed(KEY_SHIFT):
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
		get_tree().quit(-1)
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
	else:
		print("INVALID DATA")
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
	# Load the font file 
	var font = load("res://assets/fonts/KiriFont.ttf") as FontFile
	
	var canvas_layer = CanvasLayer.new()
	canvas_layer.layer = 100
	
	var label = Label.new()
	label.text = "You've Finished the Puzzle!"
	
	# Label size settings
	label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", 60)  
	label.add_theme_color_override("font_color", Color(0, 204, 0))

	# Align label to center
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	label.custom_minimum_size = get_viewport().size
	
	# Position label to correct location
	label.position = Vector2(get_viewport().size) / 2 + Vector2(-1000, -700) 

	canvas_layer.add_child(label)
	get_tree().current_scene.add_child(canvas_layer)
	
	#-------------------------BUTTON LOGIC-----------------------#
	var button = $MainMenu
	button.visible = false # we dont want this @TODO remove this 
	# Change the font size
	button.add_theme_font_override("font", font)
	button.add_theme_font_size_override("font_size", 120)
	# Change the text color to white
	var font_color = Color(1, 1, 1)  # RGB (1, 1, 1) = white
	button.add_theme_color_override("font_color", font_color)
	button.connect("pressed", Callable(self, "on_main_menu_button_pressed")) 
	
	# If in online mode, leave the puzzle on the server
	if NetworkManager.is_online:
		if(FireAuth.is_online):
			print("Puzzle complete, deleting state")
			FireAuth.write_complete_server()
		NetworkManager.leave_puzzle()
		
	elif !NetworkManager.is_online and FireAuth.is_online:
		FireAuth.write_complete(PuzzleVar.choice["base_name"] + "_" + str(PuzzleVar.choice["size"]))
	
	complete = true
		
# Handles leaving the puzzle scene, saving state, and disconnecting if online client
func _on_back_pressed() -> void:
	loading.show()
	# 1. Save puzzle state BEFORE clearing any data or freeing nodes
	if !complete and FireAuth.is_online:
		if NetworkManager.is_online:
			#await FireAuth.write_puzzle_state_server(PuzzleVar.lobby_number)
			pass
		else:
			await FireAuth.write_puzzle_state(
				PuzzleVar.ordered_pieces_array,
				PuzzleVar.choice["base_name"] + "_" + str(PuzzleVar.choice["size"]),
				PuzzleVar.global_num_pieces
			)


	# 2. Handle multiplayer disconnection if this is an online client
	if NetworkManager.is_online and not NetworkManager.is_server:
		print("Client leaving online session. Closing connection...")

		# Access the MultiplayerAPI instance
		if multiplayer:
			NetworkManager.leave_puzzle()
		else:
			printerr("ERROR: NetworkManager.multiplayer is not available to close connection.")

	## 3. Clean up local scene resources
	#print("Cleaning up puzzle scene resources...")
#
	## Free all puzzle pieces currently in the scene
	#for piece in get_tree().get_nodes_in_group("puzzle_pieces"):
		#piece.queue_free()
#
	## Clear global puzzle variables to reset state for the next puzzle
	#PuzzleVar.ordered_pieces_array.clear()
	#PuzzleVar.global_coordinates_list.clear()
	#PuzzleVar.adjacent_pieces_list.clear()
	#PuzzleVar.global_num_pieces = 0
	#PuzzleVar.choice = {}
	#print("Puzzle resources cleared.")

	# 4. Change back to the puzzle selection scene
	print("Returning to puzzle selection screen.")
	loading.hide()
	get_tree().change_scene_to_file("res://assets/scenes/new_menu.tscn")
