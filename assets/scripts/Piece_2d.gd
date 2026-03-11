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
var last_lock_refresh_sec = 0.0
const LOCK_REFRESH_INTERVAL_SEC = 1.5
var lobby_number: int = -1
var drag_sequence: int = 0
var awaiting_drop_commit_ack: bool = false
var drop_commit_watch_token: int = 0
var pending_drop_group_id: int = -1
var drag_start_anchor_pos: Vector2 = Vector2.ZERO
var has_drag_start_anchor: bool = false
var requested_lock_group_id: int = -1
var locked_group_id: int = -1

func _is_group_parent_online_flow() -> bool:
	return NetworkManager.is_online

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

func _get_current_group_id() -> int:
	if group_number == null:
		return int(ID)
	return int(group_number)

func _get_interaction_group_id() -> int:
	if locked_group_id >= 0:
		return locked_group_id
	if pending_drop_group_id >= 0:
		return pending_drop_group_id
	if requested_lock_group_id >= 0:
		return requested_lock_group_id
	return _get_current_group_id()

func _matches_pending_group(group_id: int) -> bool:
	if requested_lock_group_id >= 0 and requested_lock_group_id == group_id:
		return true
	if locked_group_id >= 0 and locked_group_id == group_id:
		return true
	if pending_drop_group_id >= 0 and pending_drop_group_id == group_id:
		return true
	return _get_current_group_id() == group_id

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
	if not NetworkManager.group_lock_granted.is_connected(_on_group_lock_granted):
		NetworkManager.group_lock_granted.connect(_on_group_lock_granted)
	if not NetworkManager.group_lock_denied.is_connected(_on_group_lock_denied):
		NetworkManager.group_lock_denied.connect(_on_group_lock_denied)
	if not NetworkManager.group_drop_denied.is_connected(_on_group_drop_denied):
		NetworkManager.group_drop_denied.connect(_on_group_drop_denied)
	if not NetworkManager.group_commit_applied.is_connected(_on_group_commit_ack_probe):
		NetworkManager.group_commit_applied.connect(_on_group_commit_ack_probe)

# Called every frame where 'delta' is the elapsed time since the previous frame
func _process(delta):
	velocity = (position - prev_position) / delta # velocity is calculated here
	prev_position = position
	if NetworkManager.is_online and selected and has_lock:
		var now_sec = float(Time.get_ticks_msec()) / 1000.0
		if now_sec - last_lock_refresh_sec >= LOCK_REFRESH_INTERVAL_SEC:
			last_lock_refresh_sec = now_sec
			var active_group_id: int = _get_interaction_group_id()
			if active_group_id >= 0:
				NetworkManager.rpc_id(1, "refresh_group_lock", active_group_id)
	if _is_group_parent_online_flow() and selected and has_lock and PuzzleVar.background_clicked:
		PuzzleVar.background_clicked = false
		_finish_group_drag_commit()

# this is the actual logic to move a piece when you select it
func move(distance: Vector2):
	if _is_group_parent_online_flow():
		var main_scene = _get_main_scene()
		if main_scene and main_scene.has_method("_move_group_local"):
			main_scene._move_group_local(_get_interaction_group_id(), distance)
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
			main_scene._bring_group_to_front(_get_interaction_group_id())
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
	requested_lock_group_id = _get_current_group_id()
	if NetworkManager.is_online:
		NetworkManager.rpc_id(1, "request_group_lock", requested_lock_group_id)

func _release_lock():
	if not has_lock:
		return
	if NetworkManager.is_online:
		NetworkManager.rpc_id(1, "release_group_lock", _get_interaction_group_id())
	has_lock = false
	last_lock_refresh_sec = 0.0
	locked_group_id = -1
	requested_lock_group_id = -1

func _finish_group_drag_commit() -> void:
	if not _is_group_parent_online_flow():
		return
	if not selected:
		return
	if not has_lock:
		pending_drop_group_id = -1
		has_drag_start_anchor = false
		selected = false
		PuzzleVar.active_piece = 0
		remove_transparency()
		return
	selected = false
	PuzzleVar.active_piece = 0
	remove_transparency()
	var anchor_pos := global_position
	var active_group_id: int = _get_interaction_group_id()
	var main_scene = _get_main_scene()
	if main_scene and main_scene.has_method("_get_group_anchor_position"):
		anchor_pos = main_scene._get_group_anchor_position(active_group_id)
	var commit_seq: int = 0
	if main_scene and main_scene.has_method("_next_group_drag_sequence"):
		commit_seq = int(main_scene._next_group_drag_sequence(active_group_id))
		drag_sequence = commit_seq
	else:
		drag_sequence += 1
		commit_seq = drag_sequence
	pending_drop_group_id = active_group_id
	# Refresh lock right before commit to minimize expiry race on long/laggy drags.
	NetworkManager.rpc_id(1, "refresh_group_lock", active_group_id)
	NetworkManager.rpc_id(1, "commit_group_drop", active_group_id, anchor_pos, commit_seq)
	awaiting_drop_commit_ack = true
	drop_commit_watch_token += 1
	_watch_drop_commit_ack(drop_commit_watch_token)
	has_lock = false
	lock_pending = false
	pending_select = false
	last_lock_refresh_sec = 0.0
	locked_group_id = -1
	requested_lock_group_id = -1
	get_viewport().set_input_as_handled()
	if FireAuth.is_online and not NetworkManager.is_server and NetworkManager.is_online:
		FireAuth.write_puzzle_state_server(PuzzleVar.lobby_number)

func _restore_group_to_drag_start_anchor() -> void:
	if not _is_group_parent_online_flow():
		return
	if not has_drag_start_anchor:
		return
	var main_scene = _get_main_scene()
	if main_scene == null:
		return
	if not main_scene.has_method("_get_group_anchor_position"):
		return
	if not main_scene.has_method("_move_group_local"):
		return
	var current_anchor: Vector2 = main_scene._get_group_anchor_position(_get_interaction_group_id())
	var rollback_delta: Vector2 = drag_start_anchor_pos - current_anchor
	if rollback_delta != Vector2.ZERO:
		main_scene._move_group_local(_get_interaction_group_id(), rollback_delta)

func _on_group_lock_granted(group_id: int) -> void:
	if not _is_group_parent_online_flow():
		return
	if not pending_select:
		return
	if not _matches_pending_group(int(group_id)):
		return
	var active_piece_obj: Variant = _get_active_piece_object()
	if pending_select and active_piece_obj != null and active_piece_obj != self:
		pending_select = false
		lock_pending = false
		requested_lock_group_id = -1
		NetworkManager.rpc_id(1, "release_group_lock", int(group_id))
		return
	lock_pending = false
	pending_select = false
	has_lock = true
	locked_group_id = int(group_id)
	requested_lock_group_id = -1
	last_lock_refresh_sec = float(Time.get_ticks_msec()) / 1000.0
	var main_scene = _get_main_scene()
	if main_scene and main_scene.has_method("_get_group_anchor_position"):
		drag_start_anchor_pos = main_scene._get_group_anchor_position(_get_interaction_group_id())
	else:
		drag_start_anchor_pos = global_position
	has_drag_start_anchor = true
	_select_piece()

func _on_group_lock_denied(group_id: int, owner_id: int) -> void:
	if not _is_group_parent_online_flow():
		return
	var denied_group_id: int = int(group_id)
	var active_piece_obj: Variant = _get_active_piece_object()
	var active_is_self: bool = active_piece_obj != null and active_piece_obj == self
	var denied_visual_group_id: int = _get_interaction_group_id()
	var main_scene = _get_main_scene()
	var pending_request_denied: bool = pending_select and _matches_pending_group(denied_group_id)
	var active_drag_denied: bool = (
		(locked_group_id >= 0 and locked_group_id == denied_group_id) or
		(awaiting_drop_commit_ack and pending_drop_group_id == denied_group_id)
	)
	if not pending_request_denied and not active_drag_denied:
		return
	lock_pending = false
	pending_select = false
	requested_lock_group_id = -1
	if active_drag_denied:
		has_lock = false
		last_lock_refresh_sec = 0.0
		locked_group_id = -1
		awaiting_drop_commit_ack = false
		pending_drop_group_id = -1
		has_drag_start_anchor = false
	if selected and active_is_self:
		selected = false
		PuzzleVar.active_piece = 0
		if main_scene and main_scene.has_method("_set_group_modulate"):
			main_scene._set_group_modulate(denied_visual_group_id, Color(1, 1, 1, 1))
		else:
			remove_transparency()
	if main_scene and main_scene.has_method("update_online_status_label"):
		main_scene.update_online_status_label("Group is busy (locked by peer " + str(owner_id) + ")")
		await get_tree().create_timer(1.2).timeout
		if main_scene and is_instance_valid(main_scene) and main_scene.has_method("update_online_status_label"):
			main_scene.update_online_status_label()

func _on_group_drop_denied(group_id: int, reason_code: int) -> void:
	if not _is_group_parent_online_flow():
		return
	var denied_group_id: int = int(group_id)
	if int(pending_drop_group_id) != denied_group_id:
		return
	if not awaiting_drop_commit_ack:
		return
	print(
		"Piece_2d: commit denied awaiting_heal piece=", ID,
		" group=", denied_group_id,
		" reason=", int(reason_code)
	)
	awaiting_drop_commit_ack = false
	pending_drop_group_id = -1
	lock_pending = false
	pending_select = false
	has_lock = false
	last_lock_refresh_sec = 0.0
	requested_lock_group_id = -1
	locked_group_id = -1
	has_drag_start_anchor = false
	var active_piece_obj: Variant = _get_active_piece_object()
	if selected and active_piece_obj != null and active_piece_obj == self:
		selected = false
		PuzzleVar.active_piece = 0
		remove_transparency()

func _watch_drop_commit_ack(token: int) -> void:
	await get_tree().create_timer(2.5).timeout
	if token != drop_commit_watch_token:
		return
	if not awaiting_drop_commit_ack:
		return
	print(
		"Piece_2d: commit ack timeout piece=", ID,
		" group=", pending_drop_group_id
	)
	awaiting_drop_commit_ack = false
	pending_drop_group_id = -1
	requested_lock_group_id = -1
	locked_group_id = -1
	has_drag_start_anchor = false
	# Avoid aggressive full-snapshot heals here; they can cause visible teleports during normal play.

func _on_group_commit_ack_probe(_commit_id: int, changed_pieces: Array, _changed_groups: Array, _released_group_id: int) -> void:
	if not _is_group_parent_online_flow():
		return
	if not awaiting_drop_commit_ack:
		return
	if int(_released_group_id) == int(pending_drop_group_id) and pending_drop_group_id >= 0:
		awaiting_drop_commit_ack = false
		pending_drop_group_id = -1
		requested_lock_group_id = -1
		locked_group_id = -1
		has_drag_start_anchor = false
		return
	for raw_piece in changed_pieces:
		if not (raw_piece is Dictionary):
			continue
		var piece_data: Dictionary = raw_piece
		if int(piece_data.get("id", -1)) == int(ID):
			awaiting_drop_commit_ack = false
			pending_drop_group_id = -1
			requested_lock_group_id = -1
			locked_group_id = -1
			has_drag_start_anchor = false
			return

#this is called whenever an event occurs within the area of the piece
#	Example events include a key press within the area of the piece or
#	a piece being clicked or even mouse movement
func _on_area_2d_input_event(_viewport, event, _shape_idx):
	# check if the event is a mouse button and see if it is pressed
	if event is InputEventMouseButton and event.pressed:
		# check if it was the left button pressed
		if event.button_index == MOUSE_BUTTON_LEFT:
			if _is_group_parent_online_flow():
				var active_piece_obj: Variant = _get_active_piece_object()
				if active_piece_obj != null and is_instance_valid(active_piece_obj):
					if active_piece_obj != self:
						if active_piece_obj.has_method("_finish_group_drag_commit"):
							active_piece_obj.call("_finish_group_drag_commit")
						PuzzleVar.background_clicked = false
						PuzzleVar.piece_clicked = true
						return
					if selected == true:
						_finish_group_drag_commit()
						PuzzleVar.background_clicked = false
						PuzzleVar.piece_clicked = true
						return
				if selected == false:
					_request_lock()
				PuzzleVar.background_clicked = false
				PuzzleVar.piece_clicked = true
				return

			# if no other puzzle piece is currently active
			if not PuzzleVar.active_piece:
				# if this piece is currently not selected
				if selected == false:
					_select_piece()
					
			# if a piece is already selected
			else:
				if selected == true:
					# deselect the current piece
					selected = false
					# clear active piece reference
					PuzzleVar.active_piece = 0
			
				# get all nodes from puzzle pieces
				var all_pieces = get_tree().get_nodes_in_group("puzzle_pieces")
				
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
				
				if PuzzleVar.draw_green_check == true: # a puzzle snap occurred
					# Local snap sound and visual already handled in snap_and_connect
					PuzzleVar.draw_green_check = false
				
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
			main_scene._set_group_modulate(_get_interaction_group_id(), Color(0.7, 0.7, 0.7, 0.5))
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
			main_scene._set_group_modulate(_get_interaction_group_id(), Color(1, 1, 1, 1))
			return
	var group = get_tree().get_nodes_in_group("puzzle_pieces")
	for nodes in group:
		if nodes == null or not is_instance_valid(nodes):
			continue
		if nodes.group_number == group_number:
			nodes.modulate = Color(1, 1, 1, 1)

func move_to_position(target_position: Vector2):
	global_position = target_position

