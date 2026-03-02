extends Node2D

# Behavioral invariants (non-negotiable):
# 1) Authority ownership: in online mode, this node only mutates networked group state after
#    server approval; local-only authority is allowed solely in offline mode.
# 2) RPC direction: lock/merge/move intents flow client->server via NetworkManager.rpc_id(1,...),
#    and remote state application happens only from server-broadcast signals/RPC callbacks.
# 3) Lock semantics: selecting/dragging in online mode requires a granted group lock; without
#    lock ownership, this node must not emit movement/merge updates.
# 4) Scene-change triggers: this piece script must not initiate scene transitions; it delegates
#    game flow changes to higher-level managers/scenes.
# 5) Auth fallback behavior: persistence sync calls are best-effort and gated by auth/network
#    status; gameplay interaction remains functional when auth is unavailable.

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
var lock_pending = false
var has_lock = false
var pending_select = false
var pending_merge_source_id = -1
var pending_merge_target_id = -1
var pending_merge_stamp = 0
var last_lock_refresh_sec = 0.0
const LOCK_REFRESH_INTERVAL_SEC = 3.0
var lobby_number: int = -1
var drag_sequence: int = 0

func _is_group_parent_online_flow() -> bool:
	return NetworkManager.is_online and NetworkManager.use_group_parent_sync and not NetworkManager.use_legacy_piece_flow

func _get_main_scene():
	return get_node_or_null("/root/JigsawPuzzleNode")

func _get_active_piece_object() -> Variant:
	var active_piece: Variant = PuzzleVar.active_piece
	if typeof(active_piece) == TYPE_OBJECT and active_piece != null:
		return active_piece
	return null

func _get_live_ordered_piece(piece_id: int):
	if piece_id < 0:
		return null
	if piece_id >= PuzzleVar.ordered_pieces_array.size():
		return null
	var piece = PuzzleVar.ordered_pieces_array[piece_id]
	if piece == null or not is_instance_valid(piece):
		PuzzleVar.ordered_pieces_array[piece_id] = null
		return null
	return piece

func init_from_spawn(data: Dictionary) -> void:
	if data.has("id"):
		ID = int(data["id"])
	if data.has("lobby"):
		lobby_number = int(data["lobby"])
	if data.has("group"):
		group_number = int(data["group"])
	if data.has("position"):
		position = data["position"]
	if group_number == null:
		group_number = ID
	add_to_group("puzzle_pieces")
	z_index = 2
	visible = true
	var sprite = get_node_or_null("Sprite2D")
	var puzzle_dir := str(data.get("puzzle_dir", ""))
	if sprite and puzzle_dir != "":
		sprite.visible = true
		var piece_image_path = puzzle_dir + "/pieces/raster/" + str(ID) + ".png"
		var tex = load(piece_image_path)
		if tex != null:
			sprite.texture = tex
			piece_height = sprite.texture.get_height()
			piece_width = sprite.texture.get_width()
			var collision_box = get_node_or_null("Sprite2D/Area2D/CollisionShape2D")
			if collision_box and collision_box.shape:
				collision_box.shape.extents = Vector2(piece_width / 2, piece_height / 2)
		else:
			printerr(
				"Piece_2d: Failed to load texture for piece ", ID,
				" at ", piece_image_path,
				" is_server=", NetworkManager.is_server
			)
	if NetworkManager.is_server and NetworkManager.is_online:
		_configure_visibility()

func _configure_visibility() -> void:
	var sync = get_node_or_null("PieceSynchronizer")
	if sync == null:
		return
	sync.public_visibility = false
	sync.update_visibility()

func _is_visible_to_peer(peer_id: int) -> bool:
	if not NetworkManager.is_server:
		return true
	if peer_id == 1:
		return true
	var lobby = NetworkManager.client_lobby.get(peer_id, null)
	if lobby == null:
		return false
	return int(lobby) == lobby_number

func _ready():
	PuzzleVar.active_piece = 0 # 0 is false, any other number is true
	if group_number == null:
		group_number = ID # group number initially set to piece ID
	prev_position = position # this is to calculate velocity
	if NetworkManager.is_server:
		return
	neighbor_list = PuzzleVar.adjacent_pieces_list[str(ID)] # set the list of adjacent pieces
	snap_threshold = ((piece_height + piece_width) / 2) * .4 # set the snap threshold to a fraction of the piece size
	
	# connect piece connection signal
	if not NetworkManager.pieces_connected.is_connected(_on_network_pieces_connected):
		NetworkManager.pieces_connected.connect(_on_network_pieces_connected)
	if not NetworkManager.pieces_moved.is_connected(_on_network_pieces_moved):
		NetworkManager.pieces_moved.connect(_on_network_pieces_moved)
	if not NetworkManager.lock_granted.is_connected(_on_lock_granted):
		NetworkManager.lock_granted.connect(_on_lock_granted)
	if not NetworkManager.lock_denied.is_connected(_on_lock_denied):
		NetworkManager.lock_denied.connect(_on_lock_denied)
	if not NetworkManager.group_lock_granted_v2.is_connected(_on_group_lock_granted_v2):
		NetworkManager.group_lock_granted_v2.connect(_on_group_lock_granted_v2)
	if not NetworkManager.group_lock_denied_v2.is_connected(_on_group_lock_denied_v2):
		NetworkManager.group_lock_denied_v2.connect(_on_group_lock_denied_v2)

# Called every frame where 'delta' is the elapsed time since the previous frame
func _process(delta):
	velocity = (position - prev_position) / delta # velocity is calculated here
	prev_position = position
	if NetworkManager.is_online and selected and has_lock:
		var now_sec = float(Time.get_ticks_msec()) / 1000.0
		if now_sec - last_lock_refresh_sec >= LOCK_REFRESH_INTERVAL_SEC:
			last_lock_refresh_sec = now_sec
			if _is_group_parent_online_flow():
				NetworkManager.rpc_id(1, "refresh_group_lock_v2", int(group_number))
			else:
				NetworkManager.rpc_id(1, "refresh_group_lock", ID, group_number)

# this is the actual logic to move a piece when you select it
func move(distance: Vector2):
	if _is_group_parent_online_flow():
		var main_scene = _get_main_scene()
		if main_scene and main_scene.has_method("_move_group_local"):
			main_scene._move_group_local(int(group_number), distance)
		return
	var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces")
	
	# for all the pieces in the same group, move them together
	for node in all_pieces:
		if node == null or not is_instance_valid(node):
			continue
		if node.group_number == group_number:
			node.global_position += distance

func _select_piece():
	if selected:
		return
	if _is_group_parent_online_flow():
		var main_scene = _get_main_scene()
		if main_scene and main_scene.has_method("_bring_group_to_front"):
			main_scene._bring_group_to_front(int(group_number))
	else:
		var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces")
		for piece in all_pieces:
			if piece == null or not is_instance_valid(piece):
				continue
			if piece.group_number == group_number:
				piece.bring_to_front()
	PuzzleVar.active_piece = self
	selected = true
	PuzzleVar.draw_green_check = false
	apply_transparency()

func _request_lock():
	if lock_pending or has_lock:
		return
	lock_pending = true
	pending_select = true
	if NetworkManager.is_online:
		if _is_group_parent_online_flow():
			NetworkManager.rpc_id(1, "request_group_lock_v2", int(group_number))
		else:
			NetworkManager.rpc_id(1, "request_group_lock", ID, group_number)

func _release_lock():
	if not has_lock:
		return
	if NetworkManager.is_online:
		if _is_group_parent_online_flow():
			NetworkManager.rpc_id(1, "release_group_lock_v2", int(group_number))
		else:
			NetworkManager.rpc_id(1, "release_group_lock", ID, group_number)
	has_lock = false
	last_lock_refresh_sec = 0.0

func _finish_group_drag_commit() -> void:
	if not _is_group_parent_online_flow():
		return
	if not selected:
		return
	if not has_lock:
		selected = false
		PuzzleVar.active_piece = 0
		remove_transparency()
		return
	selected = false
	PuzzleVar.active_piece = 0
	remove_transparency()
	var anchor_pos := global_position
	var main_scene = _get_main_scene()
	if main_scene and main_scene.has_method("_get_group_anchor_position"):
		anchor_pos = main_scene._get_group_anchor_position(int(group_number))
	drag_sequence += 1
	NetworkManager.rpc_id(1, "commit_group_drop", int(group_number), anchor_pos, drag_sequence)
	has_lock = false
	lock_pending = false
	pending_select = false
	last_lock_refresh_sec = 0.0
	get_viewport().set_input_as_handled()
	if FireAuth.is_online and not NetworkManager.is_server and NetworkManager.is_online:
		FireAuth.write_puzzle_state_server(PuzzleVar.lobby_number)

func _set_pending_merge(source_id: int, target_id: int):
	pending_merge_source_id = source_id
	pending_merge_target_id = target_id
	pending_merge_stamp += 1
	_clear_pending_merge_after_delay(pending_merge_stamp)

func _clear_pending_merge_after_delay(stamp: int) -> void:
	await get_tree().create_timer(1.0).timeout
	if pending_merge_stamp == stamp:
		pending_merge_source_id = -1
		pending_merge_target_id = -1

func _on_lock_granted(piece_id: int, group_id: int):
	if piece_id != ID:
		return
	lock_pending = false
	var active_piece_obj: Variant = _get_active_piece_object()
	var active_is_other: bool = active_piece_obj != null and active_piece_obj != self
	if not pending_select or active_is_other:
		pending_select = false
		if NetworkManager.is_online:
			NetworkManager.rpc_id(1, "release_group_lock", ID, group_id)
		return
	pending_select = false
	has_lock = true
	last_lock_refresh_sec = float(Time.get_ticks_msec()) / 1000.0
	_select_piece()

func _on_lock_denied(piece_id: int, _group_id: int, _owner_id: int):
	if piece_id != ID:
		return
	lock_pending = false
	pending_select = false
	var active_piece_obj: Variant = _get_active_piece_object()
	if selected and active_piece_obj != null and active_piece_obj == self:
		selected = false
		PuzzleVar.active_piece = 0
		remove_transparency()

func _on_group_lock_granted_v2(group_id: int) -> void:
	if not _is_group_parent_online_flow():
		return
	if int(group_number) != int(group_id):
		return
	var active_piece_obj: Variant = _get_active_piece_object()
	if pending_select and active_piece_obj != null and active_piece_obj != self:
		pending_select = false
		lock_pending = false
		NetworkManager.rpc_id(1, "release_group_lock_v2", int(group_id))
		return
	lock_pending = false
	if not pending_select:
		return
	pending_select = false
	has_lock = true
	last_lock_refresh_sec = float(Time.get_ticks_msec()) / 1000.0
	_select_piece()

func _on_group_lock_denied_v2(group_id: int, owner_id: int) -> void:
	if not _is_group_parent_online_flow():
		return
	if int(group_number) != int(group_id):
		return
	var active_piece_obj: Variant = _get_active_piece_object()
	var active_is_self: bool = active_piece_obj != null and active_piece_obj == self
	if not pending_select and not selected and not active_is_self:
		return
	lock_pending = false
	pending_select = false
	if selected and active_is_self:
		selected = false
		PuzzleVar.active_piece = 0
		remove_transparency()
	var main_scene = _get_main_scene()
	if main_scene and main_scene.has_method("update_online_status_label"):
		main_scene.update_online_status_label("Group is busy (locked by peer " + str(owner_id) + ")")
		await get_tree().create_timer(1.2).timeout
		if main_scene and is_instance_valid(main_scene) and main_scene.has_method("update_online_status_label"):
			main_scene.update_online_status_label()

func _get_lock_owner_for_piece(piece_id: int, group_id_hint: int) -> int:
	if not NetworkManager.is_online:
		return -1
	NetworkManager.rpc_id(1, "request_lock_status", piece_id, group_id_hint)
	while true:
		var data = await NetworkManager.lock_status
		if data.size() >= 3 and int(data[0]) == piece_id:
			return int(data[2])
	return -1

#this is called whenever an event occurs within the area of the piece
#	Example events include a key press within the area of the piece or
#	a piece being clicked or even mouse movement
func _on_area_2d_input_event(_viewport, event, _shape_idx):
	# check if the event is a mouse button and see if it is pressed
	if event is InputEventMouseButton and event.pressed:
		# check if it was the left button pressed
		if event.button_index == MOUSE_BUTTON_LEFT:
			if _is_group_parent_online_flow():
				if not PuzzleVar.active_piece:
					if selected == false:
						_request_lock()
				else:
					var active_piece_obj: Variant = _get_active_piece_object()
					if active_piece_obj != null and is_instance_valid(active_piece_obj) and active_piece_obj != self:
						var active_group_id: int = int(active_piece_obj.get("group_number"))
						if active_group_id == int(group_number):
							active_piece_obj.call("_finish_group_drag_commit")
							PuzzleVar.background_clicked = false
							PuzzleVar.piece_clicked = true
							return
					if not has_lock:
						PuzzleVar.background_clicked = false
						PuzzleVar.piece_clicked = true
						return
					if selected == true:
						_finish_group_drag_commit()
				PuzzleVar.background_clicked = false
				PuzzleVar.piece_clicked = true
				return

			# if no other puzzle piece is currently active
			if not PuzzleVar.active_piece:
				# if this piece is currently not selected
				if selected == false:
					if NetworkManager.is_online:
						_request_lock()
					else:
						_select_piece()
					
			# if a piece is already selected
			else:
				if NetworkManager.is_online and not has_lock:
					PuzzleVar.background_clicked = false
					PuzzleVar.piece_clicked = true
					return
				if selected == true:
					# deselect the current piece
					selected = false
					# clear active piece reference
					PuzzleVar.active_piece = 0
			
				# get all nodes from puzzle pieces
				var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces")
				var piece_positions = []
				
				for node in all_pieces: 
					if node == null or not is_instance_valid(node):
						continue
					if node.group_number == group_number:
						var n_list = node.neighbor_list
						#run through each of the pieces that should be adjacent to the selected piece
						for adjacent_piece in n_list:
							var adjacent_piece_id = int(adjacent_piece)
							var adjacent_node = _get_live_ordered_piece(adjacent_piece_id)
							if adjacent_node == null:
								continue
							await check_connections(adjacent_piece_id)
						piece_positions.append({
							"id": node.ID,
							"position": node.global_position
						})
				
				if PuzzleVar.draw_green_check == true: # a puzzle snap occurred
					# Local snap sound and visual already handled in snap_and_connect
					PuzzleVar.draw_green_check = false
				else:
					if NetworkManager.is_online and has_lock:
						# REMOVED lobby_number (server routes by lobby)
						NetworkManager.rpc_id(1, "_receive_piece_move", group_number, piece_positions)  # send to server 

				if FireAuth.is_online and not NetworkManager.is_server and NetworkManager.is_online:
					FireAuth.write_puzzle_state_server(PuzzleVar.lobby_number)
				
				# count the number of pieces not yet placed		
				var placed = 0
				for x in range(PuzzleVar.global_num_pieces):
					if x >= PuzzleVar.ordered_pieces_array.size():
						continue
					var piece_ref = PuzzleVar.ordered_pieces_array[x]
					if piece_ref == null or not is_instance_valid(piece_ref):
						continue
					if piece_ref.group_number == piece_ref.ID:
						placed += 1
						
				print("remaining: " + str(placed-1))
				#do not trigger any more events after putting the piece down
				get_viewport().set_input_as_handled()
				
				# Set to original color from gray/transparent movement
				remove_transparency()
				_release_lock()
				
			PuzzleVar.background_clicked = false
			PuzzleVar.piece_clicked = true
			

# this is where the actual movement of the puzzle piece is handled
# when the mouse moves
func _input(event):
	if event is InputEventMouseMotion and selected == true:
		if NetworkManager.is_online and not has_lock:
			return
		apply_transparency()
		
		var distance = get_global_mouse_position() - global_position
		move(distance)


# this is a function to snap pieces to other pieces
func snap_and_connect(adjacent_piece_id: int, loadFlag = 0, is_network = false):
	if _is_group_parent_online_flow():
		return
	var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces") # group is all the pieces
	var prev_group_number
	
	var new_group_number = group_number
	
	# Get the global position of the current node
	var current_global_pos = self.get_global_position() # coordinates centered on the piece
	var current_ref_coord = PuzzleVar.global_coordinates_list[str(ID)]
	
	# get the global position of the adjacent node
	var adjacent_node = _get_live_ordered_piece(adjacent_piece_id)
	if adjacent_node == null:
		return
	var adjacent_global_pos = adjacent_node.get_global_position() # coordinates centered on the piece
	var source_group_id = group_number
	var target_group_id = adjacent_node.group_number
	
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
	
	# Create reference to main scene for both snap sound and counter update
	var main_scene = get_node("/root/JigsawPuzzleNode")

	if PuzzleVar.draw_green_check == false and loadFlag == 0 and not is_network:
		# Calculate the midpoint between the two connecting sides
		if not NetworkManager.is_online:
			var green_check_midpoint = (current_global_pos + adjacent_global_pos) / 2
			# Pass the midpoint to show_image_on_snap() so the green checkmark appears
			show_image_on_snap(green_check_midpoint)
			if main_scene:
				main_scene.play_snap_sound()
		PuzzleVar.draw_green_check = true
	
	# here is the code to decide which group to move
	# this code will have it so that the smaller group will always
	# move to the larger group to snap and connect
	var countprev = 0
	var countcurr = 0
	
	for node in all_pieces:
		if node == null or not is_instance_valid(node):
			continue
		if node.group_number == group_number:
			countcurr += 1
		elif node.group_number == prev_group_number:
			countprev += 1
			
	if countcurr < countprev: # move the small group to attach to larger group
		new_group_number = prev_group_number
		prev_group_number = group_number
		dist *= -1
	
	if NetworkManager.is_online and not is_network and has_lock:
		# Server-authoritative merge: send proposed positions, apply on server approval.
		var piece_positions = []
		for node in all_pieces:
			if node == null or not is_instance_valid(node):
				continue
			if node.group_number == new_group_number:
				piece_positions.append({
					"id": node.ID,
					"position": node.global_position
				})
			elif node.group_number == prev_group_number:
				piece_positions.append({
					"id": node.ID,
					"position": node.global_position + dist
				})
		_set_pending_merge(ID, adjacent_piece_id)
		NetworkManager.rpc_id(1, "sync_connected_pieces", ID, adjacent_piece_id, source_group_id, target_group_id, new_group_number, piece_positions)
		FireAuth.write_puzzle_state_server(PuzzleVar.lobby_number)
		return
	else:
		# The function below is called to physically move the piece and join it to the 
		# appropriate group
		move_pieces_to_connect(dist, prev_group_number, new_group_number)

		# Update the piece count display
		if main_scene and main_scene.has_method("update_piece_count_display"):
			main_scene.update_piece_count_display()
	
	var finished = true
	
	for node in all_pieces:
		if node == null or not is_instance_valid(node):
			continue
		if node.group_number != group_number:
			finished = false
			break
	
# This is the function that actually moves the piece (in the current group)
# to connect it
func move_pieces_to_connect(distance: Vector2, prev_group_number: int, new_group_number: int):
	var group = get_tree().get_nodes_in_group("puzzle_pieces")
	for node in group:
		if node == null or not is_instance_valid(node):
			continue
		if node.group_number == prev_group_number:
			node.set_global_position(node.get_global_position() + distance)
			node.group_number = new_group_number
			PuzzleVar.snap_found = true

func check_connections(adjacent_piece_ID: int) -> bool:
	if _is_group_parent_online_flow():
		return false
	var snap_found = false
	
	if velocity != Vector2(0,0):
		await get_tree().create_timer(.05).timeout
		
	var current_ref_bounding_box = PuzzleVar.global_coordinates_list[str(ID)]
	var current_ref_midpoint = Vector2((current_ref_bounding_box[2] + current_ref_bounding_box[0]) / 2, 
	(current_ref_bounding_box[3] + current_ref_bounding_box[1]) / 2)
	
	var current_global_position = self.global_position
	var adjusted_current_left_x = current_global_position[0] - (piece_width/2)
	var adjusted_current_left_y = current_global_position[1] - (piece_height/2)
	var adjusted_current_upper_left = Vector2(adjusted_current_left_x, adjusted_current_left_y)
	
	var adjacent_ref_bounding_box = PuzzleVar.global_coordinates_list[str(adjacent_piece_ID)]
	var adjacent_ref_midpoint = Vector2((adjacent_ref_bounding_box[2] + adjacent_ref_bounding_box[0]) / 2, 
	(adjacent_ref_bounding_box[3] + adjacent_ref_bounding_box[1]) / 2)
	
	var adjacent_node = _get_live_ordered_piece(adjacent_piece_ID)
	if adjacent_node == null:
		return false
	var adjacent_global_position = adjacent_node.global_position
	var adjusted_adjacent_left_x = adjacent_global_position[0] - (adjacent_node.piece_width/2)
	var adjusted_adjacent_left_y = adjacent_global_position[1] - (adjacent_node.piece_height/2)
	var adjusted_adjacent_upper_left = Vector2(adjusted_adjacent_left_x, adjusted_adjacent_left_y)

	if NetworkManager.is_online and has_lock:
		var owner_id = await _get_lock_owner_for_piece(adjacent_piece_ID, adjacent_node.group_number)
		if owner_id != -1 and owner_id != multiplayer.get_unique_id():
			return false
	
	var slope = (adjacent_ref_midpoint[1] - current_ref_midpoint[1]) / (adjacent_ref_midpoint[0] - current_ref_midpoint[0])
	
	var current_relative_position = current_global_position - adjacent_global_position
	
	var current_ref_upper_left = Vector2(current_ref_bounding_box[0], current_ref_bounding_box[1])
	var adjacent_ref_upper_left = Vector2(adjacent_ref_bounding_box[0], adjacent_ref_bounding_box[1])
	var ref_relative_position = current_ref_upper_left - adjacent_ref_upper_left
	
	var snap_distance = calc_distance(ref_relative_position, adjusted_current_upper_left-adjusted_adjacent_upper_left)
	
	if slope < 2 and slope > -2:
		if current_ref_midpoint[0] > adjacent_ref_midpoint[0]:
			if (snap_distance < snap_threshold) and (adjacent_node.group_number != group_number):
				print("right to left snap:" + str(ID) + "-->" + str(adjacent_piece_ID))
				snap_and_connect(adjacent_piece_ID)
				snap_found = true
		else:
			if (snap_distance < snap_threshold) and (adjacent_node.group_number != group_number):
				print("left to right snap:" + str(ID) + "-->" + str(adjacent_piece_ID))
				snap_and_connect(adjacent_piece_ID)
				snap_found = true
	else:
		if current_ref_midpoint[1] > adjacent_ref_midpoint[1]:
			if (snap_distance < snap_threshold) and (adjacent_node.group_number != group_number):
				print("bottom to top snap: " + str(ID) + "-->" + str(adjacent_piece_ID))
				snap_and_connect(adjacent_piece_ID)
				snap_found = true
		else:
			if (snap_distance < snap_threshold) and (adjacent_node.group_number != group_number):
				print("top to bottom snap: " + str(ID) + "-->" + str(adjacent_piece_ID))
				snap_and_connect(adjacent_piece_ID)
				snap_found = true
				
	if snap_found == true:
		return true
			
	return false


func bring_to_front():
	var parent = get_parent()
	parent.remove_child(self)
	parent.add_child(self)

func calc_distance(a: Vector2, b: Vector2) -> float:
	return ((b.y-a.y)**2 + (b.x-a.x)**2)**0.5
	
func show_image_on_snap(pos: Vector2):
	var popup = Sprite2D.new()
	popup.texture = preload("res://assets/images/checkmark2.0.png")
	popup.position = get_viewport().get_visible_rect().size / 2
	popup.position = pos
	popup.scale = Vector2(1.5, 1.5) 
	popup.visible = true
	get_tree().current_scene.add_child(popup)  
	popup.z_index = 10
	await get_tree().create_timer(.5).timeout
	popup.queue_free()

func apply_transparency():
	if _is_group_parent_online_flow():
		var main_scene = _get_main_scene()
		if main_scene and main_scene.has_method("_set_group_modulate"):
			main_scene._set_group_modulate(int(group_number), Color(0.7, 0.7, 0.7, 0.5))
			return
	var group = get_tree().get_nodes_in_group("puzzle_pieces")
	for nodes in group:
		if nodes == null or not is_instance_valid(nodes):
			continue
		if nodes.group_number == group_number:
			nodes.modulate = Color(0.7, 0.7, 0.7, 0.5)

func remove_transparency():
	if _is_group_parent_online_flow():
		var main_scene = _get_main_scene()
		if main_scene and main_scene.has_method("_set_group_modulate"):
			main_scene._set_group_modulate(int(group_number), Color(1, 1, 1, 1))
			return
	var group = get_tree().get_nodes_in_group("puzzle_pieces")
	for nodes in group:
		if nodes == null or not is_instance_valid(nodes):
			continue
		if nodes.group_number == group_number:
			nodes.modulate = Color(1, 1, 1, 1)

func move_to_position(target_position: Vector2):
	global_position = target_position

# Handles network connection for moved pieces
func _on_network_pieces_moved(_piece_positions):
	if _is_group_parent_online_flow():
		return
	#print("SIGNAL::_on_network_pieces_moved")
	# (No lobby check needed; server routes by lobby)
	for piece_info in _piece_positions:
		var piece_id = piece_info.id
		var updated_position = piece_info.position
		if piece_id < PuzzleVar.ordered_pieces_array.size():
			var piece = _get_live_ordered_piece(piece_id)
			if piece == null:
				continue
			piece.position = updated_position
			PuzzleVar.ordered_pieces_array[piece_id] = piece


func _on_network_pieces_connected(_source_piece_id, _connected_piece_id, new_group_number, piece_positions):
	if _is_group_parent_online_flow():
		return
	#print("SIGNAL::_on_network_pieces_connected")
	# (No lobby check needed; server routes by lobby)
	# Always apply authoritative server merge payload locally.
	for piece_info in piece_positions:
		var updated_piece_id = piece_info.id
		var piece_position = piece_info.position
		
		if updated_piece_id < PuzzleVar.ordered_pieces_array.size():
			var piece = _get_live_ordered_piece(updated_piece_id)
			if piece == null:
				continue
			piece.group_number = new_group_number
			piece.position = piece_position
			PuzzleVar.ordered_pieces_array[updated_piece_id] = piece
	#FireAuth.write_puzzle_state_server(PuzzleVar.lobby_number)

	if pending_merge_source_id == _source_piece_id and pending_merge_target_id == _connected_piece_id:
		var source_piece = _get_live_ordered_piece(_source_piece_id)
		var target_piece = _get_live_ordered_piece(_connected_piece_id)
		if source_piece and target_piece:
			var mid = (source_piece.global_position + target_piece.global_position) / 2
			show_image_on_snap(mid)
			var main_scene = get_node("/root/JigsawPuzzleNode")
			if main_scene:
				main_scene.play_snap_sound()
		pending_merge_source_id = -1
		pending_merge_target_id = -1

	# Update the piece counter for network connections
	var main_scene = get_node("/root/JigsawPuzzleNode")
	if main_scene and main_scene.has_method("update_piece_count_display"):
		main_scene.update_piece_count_display()
