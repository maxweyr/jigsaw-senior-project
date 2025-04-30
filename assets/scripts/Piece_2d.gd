class_name Piece_2d
extends Node2D

##===============================================
## Piece_2d handles each individual puzzle piece
## Uses MultiplayerSynchronizer for pos/group
## Input sends RPCs to authority (Server=1)
## Server logic runs locally via self-RPC when offline
##===============================================

var neighbor_list = {} # List of neighboring IDs
var snap_threshold = 50.0 # Default, calculated in _initialize
var ID: int = -1 # Piece ID, set in _initialize
var group_number: int = -1 # Synced by MultiplayerSynchronizer, set in _initialize
var is_held_by_peer: int = 0 # Peer ID holding the piece group, 0 if not held
var selected_locally = false # True if this client initiated the current grab request
var is_mouse_over = false # Track if mouse is over this piece locally
var piece_height = 0.0 # height of the puzzle piece
var piece_width = 0.0 # width of the puzzle piece
var z_index_base = 2 # base z index value
var z_index_held = 100 # z index value for a held piece

@onready var sprite: Sprite2D = $Sprite2D
@onready var area_2d: Area2D = $Sprite2D/Area2D
@onready var collision_shape: CollisionShape2D = $Sprite2D/Area2D/CollisionShape2D
@onready var synchronizer: MultiplayerSynchronizer = $PieceSynchronizer

## Initialize
func _initialize(data: Dictionary):
	# validate essential data
	if not data.has_all(["id", "piece_image_path", "initial_group", "initial_position"]):
		printerr("Piece_2d _initialize missing essential data: ", data)
		queue_free() # remove invalid piece
		return
	
	ID = data["id"]
	name = "Piece_" + str(ID)
	group_number = data["initial_group"] # set initial group (synced)
	
	# load texture and set dimension
	var texture = load(data["piece_image_path"])
	if texture:
		sprite.texture = texture
		piece_height = float(texture.get_height())
		piece_width = float(texture.get_width())
		if collision_shape and collision_shape.shape:
			collision_shape.shape.size = Vector2(piece_width, piece_height)
		else:
			printerr("Piece %d: Collision shape node/resource missing or invalid." % ID)
		snap_threshold = ((piece_height + piece_width) / 2.0) * 0.3 ## Adjust multiplier? Needs tuning
	else:
		printerr("Piece %d: Failed to load texture '%s'" % [ID, data["piece_image_path"]])
	
	# set initial position (authority only)
	if NetworkManager.is_offline_authority:
		position = data["initial_position"]
	
	if is_instance_valid(synchronizer):
		synchronizer.set_multiplayer_authority(1)
	else:
		printerr("Piece %d: MultiplayerSynchronizer node not found!" % ID)
	
	# setup neighbors
	if PuzzleVar.adjacent_pieces_list.has(str(ID)):
		neighbor_list = PuzzleVar.adjacent_pieces_list[str(ID)]
	else:
		printerr("Piece %d: Adjacent piece list not found in PuzzleVar." % ID)
	
	z_index = z_index_base
	print("Piece %d initialized on Peer %d. Group: %d. Pos: %s" % [ID, multiplayer.get_unique_id(), group_number, str(position)])

## Input Handling (Client-Side: Sends requests to Server/Self)
func _on_area_2d_input_event(_viewport, event: InputEvent, _shape_idx):
	var local_peer_id = multiplayer.get_unique_id()
	
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			# request grab
			print("Peer %d: Requesting grab piece %d" % [local_peer_id, ID])
			rpc_id(1, "server_request_grab", ID, local_peer_id)
			selected_locally = true # assume success for local feedback
			_bring_group_to_front_locally()
			apply_transparency_locally()
		else:
			# request drop
			if selected_locally: # only drop if we thought we had it
				print("Peer %d: Requesting drop piece %d at %s" % [local_peer_id, ID, str(global_position)])
				rpc_id(1, "server_request_drop", ID, local_peer_id, global_position)
				selected_locally = false
				remove_transparency_locally()
		
		get_viewport().set_input_as_handled()

# Input processing for dragging (Client-Side)
# IMPORTANT: Implement throttling for server_request_move RPC!
var _move_rpc_timer = 0.0
var MOVE_RPC_INTERVAL = 0.1 # Send updates 10 times per second

func _process(delta):
	# Handle Dragging & Throttled Move RPC
	if selected_locally:
		var mouse_pos = get_global_mouse_position()
		# Calculate delta needed to move piece center to mouse pos
		var target_delta = mouse_pos - global_position
		
		print("Moving pieces locally")
		# Move locally for responsiveness
		_move_piece_group_locally(target_delta)

		# Throttled RPC send
		_move_rpc_timer += delta
		if _move_rpc_timer >= MOVE_RPC_INTERVAL:
			_move_rpc_timer = 0.0
			# Send the TARGET global position for this specific piece
			# Server will calculate group move based on this piece's target
			print("Sending move RPC for %d to %s" % [ID, str(mouse_pos)]) # Debug throttling
			rpc_id(1, "server_request_move", ID, mouse_pos)

## RPC Functions (Executed on Authority = Peer 1: Server or Offline Self)

@rpc("authority", "call_local")
func server_request_grab(piece_id: int, requesting_peer_id: int):
	if piece_id != ID: return

	# Check if this piece (or its group) is already held
	var current_holder = _get_group_holder(group_number)
	if current_holder == 0: # Group is available
		_set_group_holder(group_number, requesting_peer_id)
		print("Server/Authority: Granted grab for group %d (piece %d) to peer %d" % [group_number, ID, requesting_peer_id])
		# Bring group to front on authority (visual change synced if z_index synced)
		_bring_group_to_front_server()
	else:
		print("Server/Authority: Denied grab for group %d (piece %d) - already held by peer %d" % [group_number, ID, current_holder])

@rpc("authority", "call_local", "unreliable") # movement can be unreliable for performance
func server_request_move(piece_id: int, target_global_position_for_piece: Vector2):
	if piece_id != ID: return
	var sender_id = multiplayer.get_remote_sender_id()
	
	# If offline authority, treat the sender (which is 0 for self-RPCs) as Peer 1
	var effective_sender_id
	if sender_id != 0:
		effective_sender_id = sender_id
	else:
		effective_sender_id = 1
	
	# Get the actual holder of the entire group this piece belongs to
	var group_holder_id = _get_group_holder(group_number)
	
	print(effective_sender_id)
	print(group_holder_id)
	if group_holder_id == effective_sender_id:
		# Calculate movement needed for the *entire group* based on the target pos for the one piece
		print("moving!!!")
		var group_delta = target_global_position_for_piece - global_position
		_move_piece_group_server(group_delta) # Move the group authoritatively
	# else: Ignore move request from non-holder

@rpc("authority", "call_local")
func server_request_drop(piece_id: int, requesting_peer_id: int, final_global_position_for_piece: Vector2):
	if piece_id != ID: return

	# Check if the dropper is the one holding the group
	var current_holder = _get_group_holder(group_number)
	if current_holder == requesting_peer_id or (NetworkManager.is_offline_authority and requesting_peer_id == 1):
		# print("Server/Authority: Received drop request for piece %d from peer %d" % [ID, requesting_peer_id])
		# Apply final position update authoritatively
		var group_delta = final_global_position_for_piece - global_position
		_move_piece_group_server(group_delta)

		# Release the hold on the group
		_set_group_holder(group_number, 0)
		print("Server/Authority: Released group %d (piece %d) by peer %d" % [group_number, ID, requesting_peer_id])

		# Restore Z-index authoritatively
		_restore_group_z_index_server()

		# Check for connections authoritatively
		call_deferred("check_connections_server")
	else:
		print("Server/Authority: Invalid drop request for piece %d from peer %d - group held by %d" % [ID, requesting_peer_id, current_holder])

## Server-Side / Authoritative Logic Helper Functions6

# Gets the peer ID holding any piece within a given group
func _get_group_holder(grp_num: int) -> int:
	var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces")
	for node in all_pieces:
		if node is Piece_2d and node.group_number == grp_num:
			# If any piece in the group is held, the whole group is held
			if node.is_held_by_peer != 0:
				return node.is_held_by_peer
	return 0 # Not held

# Sets the peer ID holding ALL pieces within a given group
func _set_group_holder(grp_num: int, holder_peer_id: int):
	var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces")
	print(">>> Setting holder for Group %d to Peer %d. Found %d total pieces." % [grp_num, holder_peer_id, all_pieces.size()]) # DEBUG
	var updated_count = 0
	for node in all_pieces:
		if node is Piece_2d and node.group_number == grp_num:
			# Print BEFORE changing
			print("    Piece %d (Group %d): Old holder %d -> New holder %d" % [node.ID, node.group_number, node.is_held_by_peer, holder_peer_id]) # DEBUG
			node.is_held_by_peer = holder_peer_id
			updated_count += 1
	print("<<< Updated holder for %d pieces in Group %d to Peer %d" % [updated_count, grp_num, holder_peer_id]) # DEBUG

# Authoritative move - modifies position (synced automatically)
func _move_piece_group_server(distance: Vector2):
	var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces")
	for node in all_pieces:
		if node is Piece_2d and node.group_number == self.group_number:
			node.position += distance # Modify position directly on authority

# Authoritative z-index change (ONLY works if z_index is added to synchronizer)
func _bring_group_to_front_server():
	var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces")
	for node in all_pieces:
		if node is Piece_2d and node.group_number == self.group_number:
			node.z_index = z_index_held # This change won't sync unless z_index is added!

func _restore_group_z_index_server():
	var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces")
	for node in all_pieces:
		if node is Piece_2d and node.group_number == self.group_number:
			node.z_index = z_index_base # This change won't sync unless z_index is added!

# Authoritative connection check
func check_connections_server():
	if _get_group_holder(group_number) != 0: return # Don't check if still held

	var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces")
	var connection_made = false

	# Check neighbours of ALL pieces in the dropped group
	var pieces_in_group = []
	for p in all_pieces:
		if p is Piece_2d and p.group_number == self.group_number:
			pieces_in_group.append(p)
	
	for piece_in_group in pieces_in_group:
		for adjacent_id_str in piece_in_group.neighbor_list:
			var adjacent_id = int(adjacent_id_str)
			if adjacent_id < 0 or adjacent_id >= PuzzleVar.ordered_pieces_array.size(): continue

			var adjacent_node = PuzzleVar.ordered_pieces_array[adjacent_id]
			if not is_instance_valid(adjacent_node): continue
			if adjacent_node.group_number == piece_in_group.group_number: continue # Skip already connected

			# Check distance (or precise snap alignment)
			var snap_dist_vector = piece_in_group.calculate_precise_snap_vector(adjacent_node)
			
			if not snap_dist_vector.is_finite():
				print("Server/Authority: Skipping check between %d and %d due to invalid snap vector." % [piece_in_group.ID, adjacent_id])
				continue # Skip to the next neighbor
			
			var snap_distance = snap_dist_vector.length() # Use precise distance

			if snap_distance < snap_threshold:
				print("Server/Authority: Snap detected between %d and %d" % [piece_in_group.ID, adjacent_id])
				# Pass the node that initiated the check and the target node
				snap_and_connect_server(piece_in_group, adjacent_node, snap_dist_vector)
				connection_made = true
				# Important: Stop checking for *this specific piece* once a connection is made
				# to avoid potential multi-snap issues in one frame? Or maybe allow it?
	if connection_made:
		# Optionally trigger snap effect on clients via RPC
		# Send effect position based on the initial piece dropped maybe?
		rpc("play_snap_effect_client", global_position)

# Authoritative snap - modifies position and group_number (synced automatically)
func snap_and_connect_server(connecting_piece: Piece_2d, adjacent_node: Piece_2d, snap_vector: Vector2):
	# Server authoritative snap logic
	var prev_group_number = adjacent_node.group_number
	var current_group_number = connecting_piece.group_number # Group being dropped/checked
	var new_group_number = current_group_number # Default to keeping current group num

	# Decide which group moves based on size
	var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces")
	var count_curr = 0
	var count_prev = 0
	for node in all_pieces:
		if node is Piece_2d:
			if node.group_number == current_group_number:
				count_curr += 1
			elif node.group_number == prev_group_number:
				count_prev += 1
	
	var group_to_move: int
	var movement_vector: Vector2
	if count_curr <= count_prev: # Move current group (connecting_piece's group)
		group_to_move = current_group_number
		new_group_number = prev_group_number # Adopt the larger group number
		movement_vector = snap_vector # Move by the calculated snap vector
	else: # Move adjacent group (adjacent_node's group)
		group_to_move = prev_group_number
		new_group_number = current_group_number # Adopt the larger group number (which is current)
		movement_vector = -snap_vector # Move the other group in the opposite direction
	
	# Apply movement and group change on SERVER
	# The synchronizer will replicate these state changes
	print("Server/Authority: Snapping group %d to group %d. New group: %d. Moving vector: %s" % [group_to_move, new_group_number, new_group_number, str(movement_vector)])
	for node in all_pieces:
		if node is Piece_2d and node.group_number == group_to_move:
			node.position += movement_vector # Apply snap movement
			node.group_number = new_group_number # Update group number
	
	# Check for win condition on SERVER
	call_deferred("check_win_condition_server")

# Authoritative win check
func check_win_condition_server():
	var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces")
	if all_pieces.is_empty(): return # No pieces

	var first_group_num = -1
	if all_pieces[0] is Piece_2d:
		first_group_num = all_pieces[0].group_number
	else: return # First node isn't a piece?
	
	var puzzle_complete = true
	for i in range(1, all_pieces.size()):
		var node = all_pieces[i]
		if node is Piece_2d:
			if node.group_number != first_group_num:
				puzzle_complete = false
				break
		else: # Found a non-piece node in the group? Problem!
			puzzle_complete = false
			printerr("Non-Piece_2d node found in puzzle_pieces group!")
			break
	
	if puzzle_complete:
		print("Server/Authority: Puzzle Complete!")
		# Notify all clients about completion
		rpc("client_show_win_screen")
		# Server might also want to stop interactions, save final state, etc

# Authoritative calculation of the exact snap vector needed
func calculate_precise_snap_vector(adjacent_node: Piece_2d) -> Vector2:
	# precise vector calculation based on reference coords
	if not PuzzleVar.global_coordinates_list.has(str(ID)) or \
	   not PuzzleVar.global_coordinates_list.has(str(adjacent_node.ID)):
		printerr("Piece %d or %d: Missing coordinate data." % [ID, adjacent_node.ID])
		return Vector2.INF # Return invalid vector on error
	
	var current_ref_coord = PuzzleVar.global_coordinates_list[str(ID)]
	var adjacent_ref_coord = PuzzleVar.global_coordinates_list[str(adjacent_node.ID)]

	# Current piece upper-left (calculated from center)
	var adjusted_current_upper_left = global_position - Vector2(piece_width / 2.0, piece_height / 2.0)
	# Adjacent piece upper-left (calculated from center)
	var adjusted_adjacent_upper_left = adjacent_node.global_position - Vector2(adjacent_node.piece_width / 2.0, adjacent_node.piece_height / 2.0)

	# Reference difference between upper-left corners
	var ref_upper_left_diff = Vector2(current_ref_coord[0] - adjacent_ref_coord[0], current_ref_coord[1] - adjacent_ref_coord[1])
	# Actual difference between current upper-left corners
	var current_left_diff = adjusted_current_upper_left - adjusted_adjacent_upper_left

	# The vector needed to move the current piece to align perfectly with adjacent
	var snap_vector = ref_upper_left_diff - current_left_diff
	return snap_vector

## Client-Side Visual Feedback Helper Functions
# These run instantly on the client for better perceived responsiveness.
# The server state will eventually override via synchronizer if needed.

func _move_piece_group_locally(distance: Vector2):
	var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces")
	for node in all_pieces:
		if node is Piece_2d and node.group_number == self.group_number:
			node.global_position += distance

func _bring_group_to_front_locally():
	var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces")
	for node in all_pieces:
		if node is Piece_2d and node.group_number == self.group_number:
			node.z_index = z_index_held

func apply_transparency_locally():
	var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces")
	for node in all_pieces:
		if node is Piece_2d and node.group_number == self.group_number:
			node.modulate = Color(0.7, 0.7, 0.7, 0.5)

func remove_transparency_locally():
	var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces")
	for node in all_pieces:
		if node is Piece_2d and node.group_number == self.group_number:
			node.modulate = Color(1, 1, 1, 1)
			node.z_index = z_index_base

## RPC called ON CLIENTS by the Server

@rpc("any_peer", "call_local")
func play_snap_effect_client(effect_position: Vector2):
	# Called by the server on all clients to trigger local effects
	# Make sure not to call if this *is* the authority (offline mode)
	if multiplayer.is_server() and NetworkManager.is_offline_authority: return

	print("Client %d: Playing snap effect" % multiplayer.get_unique_id())
	var main_scene = get_tree().root.get_node_or_null("JigsawPuzzleNode")
	if main_scene and main_scene.has_method("play_snap_sound"):
		main_scene.play_snap_sound()
	if main_scene and main_scene.has_method("show_image_on_snap"):
		main_scene.show_image_on_snap(effect_position)

@rpc("any_peer", "call_local")
func client_show_win_screen():
	if multiplayer.is_server() and NetworkManager.is_offline_authority: return

	print("Client %d: Received win screen command" % multiplayer.get_unique_id())
	var main_scene = get_tree().root.get_node_or_null("JigsawPuzzleNode")
	if main_scene and main_scene.has_method("show_win_screen"):
		main_scene.show_win_screen()

	#PuzzleVar.active_piece = 0 # 0 is false, any other number is true
	#group_number = ID # group number initially set to piece ID
	#prev_position = position # this is to calculate velocity
	#neighbor_list = PuzzleVar.adjacent_pieces_list[str(ID)] # set the list of adjacent pieces
	#snap_threshold = ((piece_height + piece_width) / 2) * .4 # set the snap threshold to a fraction of the piece size
	#_init_networking()
#
## Called every frame where 'delta' is the elapsed time since the previous frame
#func _process(delta):
	#velocity = (position - prev_position) / delta # velocity is calculated here
	#prev_position = position

# determines multiplayer status and if syncing is applicable
#func _init_networking() -> void:
	#if NetworkManager.is_online:
		#sync = true

# this is the actual logic to move a piece when you select it
#func move(distance: Vector2):
	#var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces")
	#
	## for all the pieces in the same group, move them together
	#for node in all_pieces:
		#if node.group_number == group_number:
			#node.global_position += distance
#
##this is called whenever an event occurs within the area of the piece
##	Example events include a key press within the area of the piece or
##	a piece being clicked or even mouse movement
#func _on_area_2d_input_event(_viewport, event, _shape_idx):
	## check if the event is a mouse button and see if it is pressed
	#if event is InputEventMouseButton and event.pressed:
		## check if it was the left button pressed
		#if event.button_index == MOUSE_BUTTON_LEFT:
			## if no other puzzle piece is currently active
			#if not PuzzleVar.active_piece:
				## if this piece is currently not selected
				#if selected == false:
					## get all nodes from puzzle pieces
					#var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces")
					#
					## grab all pieces in the same group number
					#for piece in all_pieces:
						#if piece.group_number == group_number:
							#piece.bring_to_front()
					## set this piece as the active puzzle piece
					#PuzzleVar.active_piece = self
					## mark as selected
					#selected = true
					#
					#PuzzleVar.draw_green_check = false
#
					#apply_transparency()
					#
			## if a piece is already selected
			#else:
				#if selected == true:
					## deselect the current piece
					#selected = false
					## clear active piece reference
					#PuzzleVar.active_piece = 0
			#
				## get all nodes from puzzle pieces
				#var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces")
				#var num = group_number
				#var connection_found = false
			#
				#for node in all_pieces: 
					#if node.group_number == group_number:
						#var n_list = node.neighbor_list
						##run through each of the pieces that should be adjacent to the selected piece
						#for adjacent_piece in n_list:
							#var adjacent_node = PuzzleVar.ordered_pieces_array[int(adjacent_piece)]
							#await check_connections(adjacent_node.ID)
							#
				#if PuzzleVar.draw_green_check == true: # a puzzle snap occurred
					## Local snap sound and visual already handled in snap_and_connect
					#PuzzleVar.draw_green_check = false
				#
				## count the number of pieces not yet placed		
				#var placed = 0
				#for x in range(PuzzleVar.global_num_pieces):
					#if PuzzleVar.ordered_pieces_array[x].group_number == PuzzleVar.ordered_pieces_array[x].ID:
						#placed += 1
						#
				#print("remaining: " + str(placed-1))
				##do not trigger any more events after putting the piece down
				#get_viewport().set_input_as_handled()
				#
				## Set to original color from gray/transparent movement
				#remove_transparency()
				#
			#PuzzleVar.background_clicked = false
			#PuzzleVar.piece_clicked = true

# this is where the actual movement of the puzzle piece is handled
# when the mouse moves
#func _input(event):
	#if event is InputEventMouseMotion and selected_locally == true:
		#apply_transparency()
		#
		#var distance = get_global_mouse_position() - global_position
		#move(distance)


# this is a function to snap pieces to other pieces
#func snap_and_connect(adjacent_piece_id: int, loadFlag = 0, is_network = false):
	#var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces") # group is all the pieces
	#var prev_group_number
	#
	#var new_group_number = group_number
	#
	## Get the global position of the current node
	#var current_global_pos = self.get_global_position() # coordinates centered on the piece
	#var current_ref_coord = PuzzleVar.global_coordinates_list[str(ID)]
	#
	## get the global position of the adjacent node
	#var adjacent_node = PuzzleVar.ordered_pieces_array[adjacent_piece_id]
	#var adjacent_global_pos = adjacent_node.get_global_position() # coordinates centered on the piece
	#
	#var adjacent_ref_coord = PuzzleVar.global_coordinates_list[str(adjacent_piece_id)]
	#
	#prev_group_number = adjacent_node.group_number
	#
	##calculate the amount to move the current piece to snap
	#var ref_upper_left_diff = Vector2(current_ref_coord[0]-adjacent_ref_coord[0], current_ref_coord[1]-adjacent_ref_coord[1])
	#
	## compute the upper left position of the current piece
	#var adjusted_current_left_x = current_global_pos[0] - (piece_width/2)
	#var adjusted_current_left_y = current_global_pos[1] - (piece_height/2)
	#var adjusted_current_upper_left = Vector2(adjusted_current_left_x, adjusted_current_left_y)
	#
	##compute the upper left position of the adjacent piece
	#var adjusted_adjacent_left_x = adjacent_global_pos[0] - (adjacent_node.piece_width/2)
	#var adjusted_adjacent_left_y = adjacent_global_pos[1] - (adjacent_node.piece_height/2)
	#var adjusted_adjacent_upper_left = Vector2(adjusted_adjacent_left_x, adjusted_adjacent_left_y)
	#
	#var current_left_diff = Vector2(adjusted_current_upper_left - adjusted_adjacent_upper_left)
	#var dist = current_left_diff - ref_upper_left_diff
	#
	#if PuzzleVar.draw_green_check == false and loadFlag == 0 and not is_network:
		## Calculate the midpoint between the two connecting sides
		#var green_check_midpoint = (current_global_pos + adjacent_global_pos) / 2
		## Pass the midpoint to show_image_on_snap() so the green checkmark appears
		#show_image_on_snap(green_check_midpoint)
		#var main_scene = get_node("/root/JigsawPuzzleNode")
		#main_scene.play_snap_sound()
#
		#PuzzleVar.draw_green_check = true
	#
	## here is the code to decide which group to move
	## this code will have it so that the smaller group will always
	## move to the larger group to snap and connect
	#var countprev = 0
	#var countcurr = 0
	#
	#for node in all_pieces:
		#if node.group_number == group_number:
			#countcurr += 1
		#elif node.group_number == prev_group_number:
			#countprev += 1
			#
	#if countcurr < countprev: # move the small group to attach to larger group
		#new_group_number = prev_group_number
		#prev_group_number = group_number
		#dist *= -1
	#
	## The function below is called to physically move the piece and join it to the 
	## appropriate group
	#move_pieces_to_connect(dist, prev_group_number, new_group_number)
	#
	#var finished = true
	#
	#for node in all_pieces:
		#if node.group_number != group_number:
			#finished = false
			#break
	#
	## If we successfully connected the pieces and we're not in a network operation,
	## notify other clients if we're in online mode
	#if not is_network and NetworkManager.is_online:
		## Collect positions of all pieces with the new group number
		#var piece_positions = []
		#for node in all_pieces:
			#if node.group_number == new_group_number:
				#piece_positions.append({
					#"id": node.ID,
					#"position": node.global_position
				#})
		#
		## Send the connection info to the server to be broadcast to other clients
		#NetworkManager.sync_connected_pieces(ID, adjacent_piece_id, new_group_number, piece_positions)
	#
	#if (finished):
		#var main_scene = get_node("/root/JigsawPuzzleNode")
		#main_scene.show_win_screen()
		#
		## If we're in online mode, notify the server we completed the puzzle
		#if NetworkManager.is_online:
			#NetworkManager.leave_puzzle()


# This is the function that actually moves the piece (in the current group)
# to connect it
#func move_pieces_to_connect(distance: Vector2, prev_group_number: int, new_group_number: int):
	#var group = get_tree().get_nodes_in_group("puzzle_pieces")
	#for node in group:
		#if node.group_number == prev_group_number:
			## this is where the piece is actually moved so
			## that it looks like it is connecting, this is also where
			## the proper group number is associated with the piece so that it
			## moves in tandem with the other joined pieces
			#node.set_global_position(node.get_global_position() + distance)
			#node.group_number = new_group_number
			#PuzzleVar.snap_found = true
#
#func check_connections(adjacent_piece_ID: int) -> bool:
	#var snap_found = false
	
	## this if statement below is so that the piece stops moving so that the
	## position remains constant when it checks for an available connection
	#if velocity != Vector2(0,0):
		#await get_tree().create_timer(.05).timeout
		#
	##get reference bounding box for current piece (in coordinate from the image)
	#var current_ref_bounding_box = PuzzleVar.global_coordinates_list[str(ID)]
	#var current_ref_midpoint = Vector2((current_ref_bounding_box[2] + current_ref_bounding_box[0]) / 2, 
	#(current_ref_bounding_box[3] + current_ref_bounding_box[1]) / 2)
	#
	##compute dynamic positions
	#var current_global_position = self.global_position # this is centered on the piece
	#var adjusted_current_left_x = current_global_position[0] - (piece_width/2) # adjust to upper left corner
	#var adjusted_current_left_y = current_global_position[1] - (piece_height/2) # adjust to upper left corner
	#var adjusted_current_upper_left = Vector2(adjusted_current_left_x, adjusted_current_left_y)
	#
	##get reference bounding box for adjacent piece (in coordinates from the image)
	#var adjacent_ref_bounding_box = PuzzleVar.global_coordinates_list[str(adjacent_piece_ID)]
	#var adjacent_ref_midpoint = Vector2((adjacent_ref_bounding_box[2] + adjacent_ref_bounding_box[0]) / 2, 
	#(adjacent_ref_bounding_box[3] + adjacent_ref_bounding_box[1]) / 2)
	#
	##compute dynamic positions for adjacent piece
	#var adjacent_node = PuzzleVar.ordered_pieces_array[adjacent_piece_ID]
	#var adjacent_global_position = adjacent_node.global_position # these coordinates are centered on the piece
	#var adjusted_adjacent_left_x = adjacent_global_position[0] - (adjacent_node.piece_width/2) # adjust to the upper left corner
	#var adjusted_adjacent_left_y = adjacent_global_position[1] - (adjacent_node.piece_height/2) # adjust to the upper left corner
	#var adjusted_adjacent_upper_left = Vector2(adjusted_adjacent_left_x, adjusted_adjacent_left_y)
	#
	##compute slope of midpoints - the slope of the midpoints is used to determine the direction of
	##snapping to the adjacent piece (right,left,top,bottom) 
	#var slope = (adjacent_ref_midpoint[1] - current_ref_midpoint[1]) / (adjacent_ref_midpoint[0] - current_ref_midpoint[0])
	#
	##compute the relative position difference (of the center points) 
	## between the current piece and adjacent
	#var current_relative_position = current_global_position - adjacent_global_position
	#
	##compute the relative position difference between the matching pieces in the reference image
	#var current_ref_upper_left = Vector2(current_ref_bounding_box[0], current_ref_bounding_box[1])
	#var adjacent_ref_upper_left = Vector2(adjacent_ref_bounding_box[0], adjacent_ref_bounding_box[1])
	#var ref_relative_position = current_ref_upper_left - adjacent_ref_upper_left
	#
	##compute the difference in the relative position between reference and actual bounding boxes
	##This snap distance is how much the piece needs to be moved to be in the correct location
	#var snap_distance = calc_distance(ref_relative_position, adjusted_current_upper_left-adjusted_adjacent_upper_left)
	#
	## The following if-statement checks for snapping in 4 directions
	#if slope < 2 and slope > -2: #if the midpoints are on the same Y value
		#if current_ref_midpoint[0] > adjacent_ref_midpoint[0]: #if the current piece is to the right
			#if (snap_distance < snap_threshold) and (adjacent_node.group_number != group_number):  #pieces are close, so connect
				#print("right to left snap:" + str(ID) + "-->" + str(adjacent_piece_ID))
				#snap_and_connect(adjacent_piece_ID)
				#snap_found = true
		#else: #if the current piece is to the left
			#if (snap_distance < snap_threshold) and (adjacent_node.group_number != group_number):
				#print("left to right snap:" + str(ID) + "-->" + str(adjacent_piece_ID))
				#snap_and_connect(adjacent_piece_ID)
				#snap_found = true
	#else: #if the midpoints are on the same X value
		#if current_ref_midpoint[1] > adjacent_ref_midpoint[1]: #if the current piece is below
			#if (snap_distance < snap_threshold) and (adjacent_node.group_number != group_number):
				#print("bottom to top snap: " + str(ID) + "-->" + str(adjacent_piece_ID))
				#snap_and_connect(adjacent_piece_ID)
				#snap_found = true
		#else: #if the current piece is above
			#if (snap_distance < snap_threshold) and (adjacent_node.group_number != group_number):
				#print("top to bottom snap: " + str(ID) + "-->" + str(adjacent_piece_ID))
				#snap_and_connect(adjacent_piece_ID)
				#snap_found = true
				#
	#if snap_found == true:
		#return true
			#
	#return false


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

# This function handles network updates for connected pieces
#func _on_network_pieces_connected(_source_piece_id, _connected_piece_id, new_group_number, piece_positions):
	## Update all pieces according to the received positions
	#for piece_info in piece_positions:
		#var updated_piece_id = piece_info.id
		#var piece_position = piece_info.position
		#
		#if updated_piece_id < PuzzleVar.ordered_pieces_array.size():
			#var piece = PuzzleVar.ordered_pieces_array[updated_piece_id]
			#
			## Update group number and position
			#piece.group_number = new_group_number
			#piece.position = piece_position
