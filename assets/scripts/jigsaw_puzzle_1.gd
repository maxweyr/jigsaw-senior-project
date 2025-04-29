extends Node2D

# this is the main scene where the game actually occurs for the players to play

var is_muted
var mute_button: Button
var unmute_button: Button
var offline_button: Button
var online_status_label: Label

# Network-related variables
var connected_players = []
var selected_puzzle_dir = {}
var selected_puzzle_name = ""

# Called when the node enters the scene tree for the first time.
func _ready():
	name = "JigsawPuzzleNode"
	selected_puzzle_dir = PuzzleVar.choice["base_file_path"] + "_" + str(PuzzleVar.choice["size"])
	selected_puzzle_name = PuzzleVar.choice["base_name"] + str(PuzzleVar.choice["size"])
	is_muted = false
	
	if NetworkManager.is_online:
		# Connect to network signals
		NetworkManager.player_joined.connect(_on_player_joined)
		NetworkManager.player_left.connect(_on_player_left)
		
		# Create online status label
		create_online_status_label()
	
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
	
	# Iterate through and create puzzle pieces
	for x in range(PuzzleVar.global_num_pieces):
		# Create a new sprite for each cell
		var piece = sprite_scene.instantiate()
			
		# add the piece to the group puzzle_pieces so that connection logic can work
		piece.add_to_group("puzzle_pieces")
		PuzzleVar.ordered_pieces_array.append(piece)
		
		#sets the texture of the sprite to the image
		var sprite = piece.get_node("Sprite2D")
		
		# Set the texture rect for the sprite
		var piece_image_path = selected_puzzle_dir + "/pieces/raster/" + str(x) + ".png" 
		#print(piece_image_path)
		piece.ID = x # set the piece ID here
		piece.z_index = 2
		sprite.texture = load(piece_image_path) # load the image
		
		# set the height and width for each piece
		piece.piece_height = sprite.texture.get_height()
		piece.piece_width = sprite.texture.get_width()
		
		#set the collision box for the sprite
		var collision_box = piece.get_node("Sprite2D/Area2D/CollisionShape2D")

		#set the collision box to the bounding box of the sprite
		collision_box.shape.extents = Vector2(sprite.texture.get_width() / 2, sprite.texture.get_height() / 2)
	
		var spawnarea = get_viewport_rect()

		piece.position = Vector2(randi_range(50,spawnarea.size.x),randi_range(50,spawnarea.size.y))
		
		# Add the sprite to the Grid node	
		#get_parent().call_deferred("add_child", piece)
		add_child(piece)
	
	# Handle saved piece data for offline or online mode
	if NetworkManager.is_online and NetworkManager.current_puzzle_id:
		# If in online mode, request the current state from the server
		update_online_status_label("Syncing puzzle state...")
		
	elif !NetworkManager.is_online and FireAuth.is_online:
		# client is connected to firebase
		var puzzle_name_with_size = PuzzleVar.choice["base_name"] + "_" + str(PuzzleVar.choice["size"])
		print("updating active puzzle: ", puzzle_name_with_size)
		FireAuth.update_active_puzzle(puzzle_name_with_size)
		#load_firebase_state()
		
	#if not is_online_mode and FireAuth.offlineMode == 0:
		#FireAuth.add_active_puzzle(selected_puzzle_name, PuzzleVar.global_num_pieces)
		#FireAuth.add_favorite_puzzle(selected_puzzle_name)
	
	# Connect the back button signal
	var back_button = $UI_Button/Back
	back_button.connect("pressed", Callable(self, "_on_back_button_pressed"))

# Load state from Firebase (for offline mode)
func load_firebase_state():
	var saved_piece_data: Array = await FireAuth.get_puzzle_loc(selected_puzzle_name)
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
	else:
		FireAuth.write_temp_to_location(selected_puzzle_name)

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
		get_tree().quit(-1)
	var json = file.get_as_text()
	file.close()

	# Parse the JSON data
	var json_parser = JSON.new()
	var data = json_parser.parse(json)
	
	if data == OK: # if the data is valid, go ahead and parse
		var temp_id = 0
		var num_pieces = json_parser.data.size()
		print("Number of pieces" + str(num_pieces))
		
		for n in num_pieces: # for each piece, add it to the global coordinates list
			PuzzleVar.global_coordinates_list[str(n)] =  json_parser.data[str(n)]
	else:
		print("INVALID DATA")
	print("GCL: ", PuzzleVar.global_coordinates_list)
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
			var temp_id = 0
			var num_pieces = json_parser.data.size()
			PuzzleVar.global_num_pieces = num_pieces
			print("Number of pieces" + str(num_pieces))
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


func _on_back_pressed() -> void:
	for piece in get_tree().get_nodes_in_group("puzzle_pieces"):
		piece.queue_free()

	PuzzleVar.ordered_pieces_array.clear()
	PuzzleVar.global_coordinates_list.clear()
	PuzzleVar.adjacent_pieces_list.clear()
	PuzzleVar.global_num_pieces = 0
	
	#FireAuth.save_puzzle_loc(PuzzleVar.ordered_pieces_array, selected_puzzle_name, PuzzleVar.global_num_pieces)
	get_tree().change_scene_to_file("res://assets/scenes/select_puzzle.tscn")
