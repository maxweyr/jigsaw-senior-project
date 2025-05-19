extends Node2D

##===============================================
## Piece_2d handles each individual puzzle piece
##===============================================

var neighbor_list = {} # This is the list of neighboring IDs for a piece.
var snap_threshold # distance that pieces will snap together within
var ID: int # the actual ID of the current puzzle piece
var selected = false # true if piece is selected and used for movement, false if piece set down
var group_number # sorts pieces into groups so they move in tandem,  Initially, each piece has its own group number
var piece_height # height of the puzzle piece
var piece_width # width of the puzzle piece
var prev_position = Vector2() # helper for calculating velocity
var velocity = Vector2() # actual velocity

func _ready():
	PuzzleVar.active_piece = 0 # 0 is false, any other number is true
	group_number = ID # group number initially set to piece ID
	prev_position = position # this is to calculate velocity
	neighbor_list = PuzzleVar.adjacent_pieces_list[str(ID)] # set the list of adjacent pieces
	snap_threshold = ((piece_height + piece_width) / 2) * .4 # set the snap threshold to a fraction of the piece size
	
	# connect piece connection signal
	if not NetworkManager.pieces_connected.is_connected(_on_network_pieces_connected):
		NetworkManager.pieces_connected.connect(_on_network_pieces_connected)
	if not NetworkManager.pieces_moved.is_connected(_on_network_pieces_moved):
		NetworkManager.pieces_moved.connect(_on_network_pieces_moved)

# Called every frame where 'delta' is the elapsed time since the previous frame
func _process(delta):
	velocity = (position - prev_position) / delta # velocity is calculated here
	prev_position = position

# this is the actual logic to move a piece when you select it
func move(distance: Vector2):
	var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces")
	
	# for all the pieces in the same group, move them together
	for node in all_pieces:
		if node.group_number == group_number:
			node.global_position += distance

#this is called whenever an event occurs within the area of the piece
#	Example events include a key press within the area of the piece or
#	a piece being clicked or even mouse movement
func _on_area_2d_input_event(_viewport, event, _shape_idx):
	# check if the event is a mouse button and see if it is pressed
	if event is InputEventMouseButton and event.pressed:
		# check if it was the left button pressed
		if event.button_index == MOUSE_BUTTON_LEFT:
			# if no other puzzle piece is currently active
			if not PuzzleVar.active_piece:
				# if this piece is currently not selected
				if selected == false:
					# get all nodes from puzzle pieces
					var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces")
					
					# grab all pieces in the same group number
					for piece in all_pieces:
						if piece.group_number == group_number:
							piece.bring_to_front()
					# set this piece as the active puzzle piece
					PuzzleVar.active_piece = self
					# mark as selected
					selected = true
					
					PuzzleVar.draw_green_check = false

					apply_transparency()
					
			# if a piece is already selected
			else:
				if selected == true:
					# deselect the current piece
					selected = false
					# clear active piece reference
					PuzzleVar.active_piece = 0
			
				# get all nodes from puzzle pieces
				var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces")
				var num = group_number
				var connection_found = false
				var piece_positions = []
				
				for node in all_pieces: 
					if node.group_number == group_number:
						var n_list = node.neighbor_list
						#run through each of the pieces that should be adjacent to the selected piece
						for adjacent_piece in n_list:
							var adjacent_node = PuzzleVar.ordered_pieces_array[int(adjacent_piece)]
							await check_connections(adjacent_node.ID)
							piece_positions.append({
								"id": node.ID,
								"position": node.global_position
							})
				
				if PuzzleVar.draw_green_check == true: # a puzzle snap occurred
					# Local snap sound and visual already handled in snap_and_connect
					PuzzleVar.draw_green_check = false
				else:
					if NetworkManager.is_online:
						NetworkManager.rpc("_receive_piece_move", piece_positions)
				
				if FireAuth.is_online and not NetworkManager.is_server and NetworkManager.is_online:
					FireAuth.write_puzzle_state_server(PuzzleVar.lobby_number)
				
				# count the number of pieces not yet placed		
				var placed = 0
				for x in range(PuzzleVar.global_num_pieces):
					if PuzzleVar.ordered_pieces_array[x].group_number == PuzzleVar.ordered_pieces_array[x].ID:
						placed += 1
						
				print("remaining: " + str(placed-1))
				#do not trigger any more events after putting the piece down
				get_viewport().set_input_as_handled()
				
				# Set to original color from gray/transparent movement
				remove_transparency()
				
			PuzzleVar.background_clicked = false
			PuzzleVar.piece_clicked = true
			

# this is where the actual movement of the puzzle piece is handled
# when the mouse moves
func _input(event):
	if event is InputEventMouseMotion and selected == true:
		apply_transparency()
		
		var distance = get_global_mouse_position() - global_position
		move(distance)


# this is a function to snap pieces to other pieces
func snap_and_connect(adjacent_piece_id: int, loadFlag = 0, is_network = false):
	var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces") # group is all the pieces
	var prev_group_number
	
	var new_group_number = group_number
	
	# Get the global position of the current node
	var current_global_pos = self.get_global_position() # coordinates centered on the piece
	var current_ref_coord = PuzzleVar.global_coordinates_list[str(ID)]
	
	# get the global position of the adjacent node
	var adjacent_node = PuzzleVar.ordered_pieces_array[adjacent_piece_id]
	var adjacent_global_pos = adjacent_node.get_global_position() # coordinates centered on the piece
	
	var adjacent_ref_coord = PuzzleVar.global_coordinates_list[str(adjacent_piece_id)]
	
	prev_group_number = adjacent_node.group_number
	
	#calculate the amount to move the current piece to snap
	var ref_upper_left_diff = Vector2(current_ref_coord[0]-adjacent_ref_coord[0], current_ref_coord[1]-adjacent_ref_coord[1])
	
	# compute the upper left position of the current piece
	var adjusted_current_left_x = current_global_pos[0] - (piece_width/2)
	var adjusted_current_left_y = current_global_pos[1] - (piece_height/2)
	var adjusted_current_upper_left = Vector2(adjusted_current_left_x, adjusted_current_left_y)
	
	#compute the upper left position of the adjacent piece
	var adjusted_adjacent_left_x = adjacent_global_pos[0] - (adjacent_node.piece_width/2)
	var adjusted_adjacent_left_y = adjacent_global_pos[1] - (adjacent_node.piece_height/2)
	var adjusted_adjacent_upper_left = Vector2(adjusted_adjacent_left_x, adjusted_adjacent_left_y)
	
	var current_left_diff = Vector2(adjusted_current_upper_left - adjusted_adjacent_upper_left)
	var dist = current_left_diff - ref_upper_left_diff
	
	if PuzzleVar.draw_green_check == false and loadFlag == 0 and not is_network:
		# Calculate the midpoint between the two connecting sides
		var green_check_midpoint = (current_global_pos + adjacent_global_pos) / 2
		# Pass the midpoint to show_image_on_snap() so the green checkmark appears
		show_image_on_snap(green_check_midpoint)
		var main_scene = get_node("/root/JigsawPuzzleNode")
		main_scene.play_snap_sound()

		PuzzleVar.draw_green_check = true
	
	# here is the code to decide which group to move
	# this code will have it so that the smaller group will always
	# move to the larger group to snap and connect
	var countprev = 0
	var countcurr = 0
	
	for node in all_pieces:
		if node.group_number == group_number:
			countcurr += 1
		elif node.group_number == prev_group_number:
			countprev += 1
			
	if countcurr < countprev: # move the small group to attach to larger group
		new_group_number = prev_group_number
		prev_group_number = group_number
		dist *= -1
	
	# The function below is called to physically move the piece and join it to the 
	# appropriate group
	move_pieces_to_connect(dist, prev_group_number, new_group_number)
	
	var finished = true
	
	for node in all_pieces:
		if node.group_number != group_number:
			finished = false
			break
	
	# If we successfully connected the pieces and we're not in a network operation,
	# notify other clients if we're in online mode
	if not is_network and NetworkManager.is_online:
		# Collect positions of all pieces with the new group number
		var piece_positions = []
		for node in all_pieces:
			if node.group_number == new_group_number:
				piece_positions.append({
					"id": node.ID,
					"position": node.global_position
				})
		
		# Send the connection info to the server to be broadcast to other clients
		if NetworkManager.is_online:
			NetworkManager.rpc("_receive_piece_connection", ID, adjacent_piece_id, new_group_number, piece_positions)
		if FireAuth.is_online and not NetworkManager.is_server and NetworkManager.is_online:
					FireAuth.write_puzzle_state_server(PuzzleVar.lobby_number)
	
	if (finished):
		var main_scene = get_node("/root/JigsawPuzzleNode")
		main_scene.show_win_screen()
		
		# If we're in online mode, notify the server we completed the puzzle
		if NetworkManager.is_online:
			NetworkManager.leave_puzzle()


# This is the function that actually moves the piece (in the current group)
# to connect it
func move_pieces_to_connect(distance: Vector2, prev_group_number: int, new_group_number: int):
	var group = get_tree().get_nodes_in_group("puzzle_pieces")
	for node in group:
		if node.group_number == prev_group_number:
			# this is where the piece is actually moved so
			# that it looks like it is connecting, this is also where
			# the proper group number is associated with the piece so that it
			# moves in tandem with the other joined pieces
			node.set_global_position(node.get_global_position() + distance)
			node.group_number = new_group_number
			PuzzleVar.snap_found = true

func check_connections(adjacent_piece_ID: int) -> bool:
	var snap_found = false
	
	# this if statement below is so that the piece stops moving so that the
	# position remains constant when it checks for an available connection
	if velocity != Vector2(0,0):
		await get_tree().create_timer(.05).timeout
		
	#get reference bounding box for current piece (in coordinate from the image)
	var current_ref_bounding_box = PuzzleVar.global_coordinates_list[str(ID)]
	var current_ref_midpoint = Vector2((current_ref_bounding_box[2] + current_ref_bounding_box[0]) / 2, 
	(current_ref_bounding_box[3] + current_ref_bounding_box[1]) / 2)
	
	#compute dynamic positions
	var current_global_position = self.global_position # this is centered on the piece
	var adjusted_current_left_x = current_global_position[0] - (piece_width/2) # adjust to upper left corner
	var adjusted_current_left_y = current_global_position[1] - (piece_height/2) # adjust to upper left corner
	var adjusted_current_upper_left = Vector2(adjusted_current_left_x, adjusted_current_left_y)
	
	#get reference bounding box for adjacent piece (in coordinates from the image)
	var adjacent_ref_bounding_box = PuzzleVar.global_coordinates_list[str(adjacent_piece_ID)]
	var adjacent_ref_midpoint = Vector2((adjacent_ref_bounding_box[2] + adjacent_ref_bounding_box[0]) / 2, 
	(adjacent_ref_bounding_box[3] + adjacent_ref_bounding_box[1]) / 2)
	
	#compute dynamic positions for adjacent piece
	var adjacent_node = PuzzleVar.ordered_pieces_array[adjacent_piece_ID]
	var adjacent_global_position = adjacent_node.global_position # these coordinates are centered on the piece
	var adjusted_adjacent_left_x = adjacent_global_position[0] - (adjacent_node.piece_width/2) # adjust to the upper left corner
	var adjusted_adjacent_left_y = adjacent_global_position[1] - (adjacent_node.piece_height/2) # adjust to the upper left corner
	var adjusted_adjacent_upper_left = Vector2(adjusted_adjacent_left_x, adjusted_adjacent_left_y)
	
	#compute slope of midpoints - the slope of the midpoints is used to determine the direction of
	#snapping to the adjacent piece (right,left,top,bottom) 
	var slope = (adjacent_ref_midpoint[1] - current_ref_midpoint[1]) / (adjacent_ref_midpoint[0] - current_ref_midpoint[0])
	
	#compute the relative position difference (of the center points) 
	# between the current piece and adjacent
	var current_relative_position = current_global_position - adjacent_global_position
	
	#compute the relative position difference between the matching pieces in the reference image
	var current_ref_upper_left = Vector2(current_ref_bounding_box[0], current_ref_bounding_box[1])
	var adjacent_ref_upper_left = Vector2(adjacent_ref_bounding_box[0], adjacent_ref_bounding_box[1])
	var ref_relative_position = current_ref_upper_left - adjacent_ref_upper_left
	
	#compute the difference in the relative position between reference and actual bounding boxes
	#This snap distance is how much the piece needs to be moved to be in the correct location
	var snap_distance = calc_distance(ref_relative_position, adjusted_current_upper_left-adjusted_adjacent_upper_left)
	
	# The following if-statement checks for snapping in 4 directions
	if slope < 2 and slope > -2: #if the midpoints are on the same Y value
		if current_ref_midpoint[0] > adjacent_ref_midpoint[0]: #if the current piece is to the right
			if (snap_distance < snap_threshold) and (adjacent_node.group_number != group_number):  #pieces are close, so connect
				print("right to left snap:" + str(ID) + "-->" + str(adjacent_piece_ID))
				snap_and_connect(adjacent_piece_ID)
				snap_found = true
		else: #if the current piece is to the left
			if (snap_distance < snap_threshold) and (adjacent_node.group_number != group_number):
				print("left to right snap:" + str(ID) + "-->" + str(adjacent_piece_ID))
				snap_and_connect(adjacent_piece_ID)
				snap_found = true
	else: #if the midpoints are on the same X value
		if current_ref_midpoint[1] > adjacent_ref_midpoint[1]: #if the current piece is below
			if (snap_distance < snap_threshold) and (adjacent_node.group_number != group_number):
				print("bottom to top snap: " + str(ID) + "-->" + str(adjacent_piece_ID))
				snap_and_connect(adjacent_piece_ID)
				snap_found = true
		else: #if the current piece is above
			if (snap_distance < snap_threshold) and (adjacent_node.group_number != group_number):
				print("top to bottom snap: " + str(ID) + "-->" + str(adjacent_piece_ID))
				snap_and_connect(adjacent_piece_ID)
				snap_found = true
				
	if snap_found == true:
		return true
			
	return false


# this is the function that brings the piece to the front of the screen
func bring_to_front():
	var parent = get_parent()
	# removes the piece from the screen
	parent.remove_child(self) # Remove the piece from its parent
	# adds the piece back to the screen so that it looks like it is on top
	parent.add_child(self)

# this function calculates the distance between two points and returns the
# distance as a scalar value
func calc_distance(a: Vector2, b: Vector2) -> float:
	return ((b.y-a.y)**2 + (b.x-a.x)**2)**0.5
	
func show_image_on_snap(pos: Vector2):
	var popup = Sprite2D.new()
	# Load texture
	popup.texture = preload("res://assets/images/checkmark2.0.png")
	
	# Center the sprite in the viewport
	popup.position = get_viewport().get_visible_rect().size / 2
	# Using midpoint between connecting nodes
	popup.position = pos
	
	# Make the sprite larger
	popup.scale = Vector2(1.5, 1.5) 
	# Ensure visibility
	popup.visible = true
	# This adds it to the main scene
	get_tree().current_scene.add_child(popup)  
	# Make image be at the top
	popup.z_index = 10
	# Optional: Make the image disappear after a while
	# Show image for 2 seconds
	await get_tree().create_timer(.5).timeout
	popup.queue_free()

# This function is called to apply the transparency effect
func apply_transparency():
	var group = get_tree().get_nodes_in_group("puzzle_pieces")
	for nodes in group:
		if nodes.group_number == group_number:
			nodes.modulate = Color(0.7, 0.7, 0.7, 0.5)

# This function is called to remove the transparency effect
func remove_transparency():
	var group = get_tree().get_nodes_in_group("puzzle_pieces")
	for nodes in group:
		if nodes.group_number == group_number:
			nodes.modulate = Color(1, 1, 1, 1)

# Function to smoothly move a piece to the new position
func move_to_position(target_position: Vector2):
	position = target_position

# Handles network connction for moed pieces
func _on_network_pieces_moved(_piece_positions):
	#print("SIGNAL::_on_network_pieces_moved")
	# update all piece according to the received positions
	for piece_info in _piece_positions:
		var piece_id = piece_info.id
		var updated_position = piece_info.position
		if piece_id < PuzzleVar.ordered_pieces_array.size():
			var piece = PuzzleVar.ordered_pieces_array[piece_id]
			#print("New position: ", updated_position)
			piece.position = updated_position
			PuzzleVar.ordered_pieces_array[piece_id] = piece


# This function handles network updates for connected pieces
func _on_network_pieces_connected(_source_piece_id, _connected_piece_id, new_group_number, piece_positions):
	#print("SIGNAL::_on_network_pieces_connected")
	# Update all pieces according to the received positions
	for piece_info in piece_positions:
		var updated_piece_id = piece_info.id
		var piece_position = piece_info.position
		
		if updated_piece_id < PuzzleVar.ordered_pieces_array.size():
			var piece = PuzzleVar.ordered_pieces_array[updated_piece_id]
			#print("New group number: ", new_group_number)
			#print("New position: ", piece_position)
			piece.group_number = new_group_number
			piece.position = piece_position
			PuzzleVar.ordered_pieces_array[updated_piece_id] = piece
	#FireAuth.write_puzzle_state_server(PuzzleVar.lobby_number)
