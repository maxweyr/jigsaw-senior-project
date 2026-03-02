extends Node2D

# Behavioral invariants (non-negotiable):
# 1) Authority ownership: puzzle scene UI/state reflects authoritative multiplayer updates when
#    online, while offline sessions treat local scene state as authority.
# 2) RPC direction: this scene consumes NetworkManager events/signals and does not bypass manager
#    routing with direct peer-to-peer mutation RPCs.
# 3) Lock semantics: piece-level lock ownership is enforced by Piece_2d/NetworkManager; this
#    scene must not override lock decisions when presenting or updating gameplay state.
# 4) Scene-change triggers: win/menu transitions are initiated by explicit lifecycle events
#    (completion, back flow, disconnect/kick handling) rather than implicit UI redraws.
# 5) Auth fallback behavior: Firebase load/save paths are conditional; missing auth/network must
#    degrade to playable local state instead of blocking scene initialization.

# this is the main scene where the game actually occurs for the players to play

var is_muted
var mute_button: Button
var unmute_button: Button
var offline_button: Button
var complete = false;
var completed_on_join = false;
var save_popup: PopupPanel
@onready var help_popup: PopupMenu = $CanvasLayer/Control/HelpPopup
@onready var back_button = $UI_Button/Back
@onready var loading = $LoadingScreen
@onready var zoom_box: Control = $UI_Button/ZoomBox

signal main_menu

# --- Network-related variables ---
var selected_puzzle_dir = ""
var selected_puzzle_name = ""

# --- UI Element Variables ---
var piece_count_label: Label
var floating_status_box: PanelContainer
var online_status_label: Label
var chat_panel: PanelContainer
var chat_content_container: VBoxContainer
var chat_messages_label: RichTextLabel
var chat_input: LineEdit
var chat_send_button: Button
var chat_toggle_button: Button
var chat_input_row: HBoxContainer
var chat_minimized := false
var chat_expanded_height := 200.0
var chat_bottom_offset := -85.0
var spawned_piece_count := 0
var all_pieces_ready := false
const PIECE_SCENE_PATH = "res://assets/scenes/Piece_2d.tscn"
var spawn_watchdog_running := false
var block_loading_until_state_sync: bool = false
var initial_state_sync_complete: bool = true
var groups_root: Node2D = null
var group_nodes: Dictionary = {}

# --- Network Data	---
var connected_players = [] # Array to store connected player names (excluding self)

# --- Constants for Styling ---
const BOX_BACKGROUND_COLOR = Color(0.15, 0.15, 0.2, 0.85) # Dark semi-transparent
const BOX_BORDER_COLOR = Color(0.4, 0.4, 0.45, 0.9)
const BOX_FONT_COLOR = Color(0.95, 0.95, 0.95)

func _vector2_from_variant(value: Variant, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	if value is Vector2:
		return value
	if value is Dictionary and value.has("x") and value.has("y"):
		return Vector2(float(value["x"]), float(value["y"]))
	return fallback

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

func _ensure_groups_root() -> void:
	if groups_root != null and is_instance_valid(groups_root):
		return
	var existing = get_node_or_null("GroupsRoot")
	if existing and is_instance_valid(existing):
		groups_root = existing
		return
	groups_root = Node2D.new()
	groups_root.name = "GroupsRoot"
	add_child(groups_root)

func _ensure_group_node(group_id: int, anchor_pos: Vector2 = Vector2.ZERO) -> Node2D:
	_ensure_groups_root()
	if group_nodes.has(group_id):
		var node = group_nodes[group_id]
		if node != null and is_instance_valid(node):
			return node
		group_nodes.erase(group_id)
	var node := Node2D.new()
	node.name = "Group_" + str(group_id)
	node.global_position = anchor_pos
	groups_root.add_child(node)
	group_nodes[group_id] = node
	return node

func _attach_piece_to_group(piece: Node2D, group_id: int, keep_world: bool = true, anchor_pos: Vector2 = Vector2.ZERO) -> void:
	if piece == null or not is_instance_valid(piece):
		return
	var target_group := _ensure_group_node(group_id, anchor_pos)
	var current_parent = piece.get_parent()
	if current_parent == target_group:
		return
	var old_global := piece.global_position
	if current_parent != null:
		current_parent.remove_child(piece)
	target_group.add_child(piece)
	if keep_world:
		piece.global_position = old_global

func _delete_empty_group_nodes(valid_group_ids: Dictionary = {}) -> void:
	var stale_group_ids: Array = []
	for raw_gid in group_nodes.keys():
		var gid := int(raw_gid)
		var node = group_nodes[raw_gid]
		if node == null or not is_instance_valid(node):
			stale_group_ids.append(gid)
			continue
		if not valid_group_ids.is_empty() and not valid_group_ids.has(gid):
			node.queue_free()
			stale_group_ids.append(gid)
			continue
		if node.get_child_count() == 0:
			node.queue_free()
			stale_group_ids.append(gid)
	for raw_gid in stale_group_ids:
		group_nodes.erase(int(raw_gid))

func _bring_group_to_front(group_id: int) -> void:
	if not group_nodes.has(group_id):
		return
	var node = group_nodes[group_id]
	if node == null or not is_instance_valid(node):
		return
	if groups_root == null or not is_instance_valid(groups_root):
		return
	groups_root.move_child(node, groups_root.get_child_count() - 1)

func _move_group_local(group_id: int, distance: Vector2) -> void:
	var node := _ensure_group_node(group_id, _get_group_anchor_position(group_id))
	node.global_position += distance

func _set_group_modulate(group_id: int, color: Color) -> void:
	if not group_nodes.has(group_id):
		return
	var node = group_nodes[group_id]
	if node == null or not is_instance_valid(node):
		return
	for child in node.get_children():
		if child and is_instance_valid(child) and child is CanvasItem:
			child.modulate = color

func _get_group_anchor_position(group_id: int) -> Vector2:
	if group_nodes.has(group_id):
		var node = group_nodes[group_id]
		if node != null and is_instance_valid(node):
			return node.global_position
	for piece in PuzzleVar.ordered_pieces_array:
		if piece == null or not is_instance_valid(piece):
			continue
		if int(piece.group_number) == group_id:
			return piece.global_position
	return Vector2.ZERO

func _apply_group_commit_local(_commit_id: int, changed_pieces: Array, changed_groups: Array, _released_group_id: int) -> void:
	_ensure_groups_root()
	var group_anchor_map: Dictionary = {}
	var valid_group_ids: Dictionary = {}
	var touched_group_ids: Dictionary = {}
	for raw_piece in changed_pieces:
		if not (raw_piece is Dictionary):
			continue
		var pentry: Dictionary = raw_piece
		var touched_gid := int(pentry.get("group", -1))
		if touched_gid >= 0:
			touched_group_ids[touched_gid] = true
	for raw_group in changed_groups:
		if not (raw_group is Dictionary):
			continue
		var gdata: Dictionary = raw_group
		var gid := int(gdata.get("group_id", -1))
		if gid < 0:
			continue
		var anchor := _vector2_from_variant(gdata.get("anchor_pos", Vector2.ZERO), Vector2.ZERO)
		group_anchor_map[gid] = anchor
		valid_group_ids[gid] = true
		var group_node = _ensure_group_node(gid, anchor)
		if touched_group_ids.has(gid) or group_node.get_child_count() == 0:
			group_node.global_position = anchor

	for raw_piece in changed_pieces:
		if not (raw_piece is Dictionary):
			continue
		var pdata: Dictionary = raw_piece
		var pid := int(pdata.get("id", -1))
		if pid < 0:
			continue
		var piece = _get_live_ordered_piece(pid)
		if piece == null:
			continue
		var gid := int(pdata.get("group", piece.group_number))
		var pos := _vector2_from_variant(pdata.get("position", piece.global_position), piece.global_position)
		piece.group_number = gid
		piece.global_position = pos
		var anchor := _vector2_from_variant(group_anchor_map.get(gid, pos), pos)
		_attach_piece_to_group(piece, gid, true, anchor)

	_delete_empty_group_nodes(valid_group_ids)
	call_deferred("update_piece_count_display")

# Called when the node enters the scene tree for the first time.
func _ready():
	# Render the loading screen immediately
	loading.show()
	await get_tree().process_frame 
	
	save_popup = get_node_or_null("SavePopup")
	if save_popup:
		save_popup.hide()
		
	if is_instance_valid(help_popup):
		help_popup.hide()
		
	name = "JigsawPuzzleNode"
	_ensure_groups_root()
	selected_puzzle_dir = PuzzleVar.choice["base_file_path"] + "_" + str(PuzzleVar.choice["size"])
	PuzzleVar.selected_puzzle_dir = selected_puzzle_dir
	selected_puzzle_name = PuzzleVar.choice["base_name"] + str(PuzzleVar.choice["size"])
	is_muted = false
	
	if NetworkManager.is_online:
		NetworkManager.player_joined.connect(_on_player_joined)
		NetworkManager.player_left.connect(_on_player_left)
		NetworkManager.chat_message_received.connect(append_chat_message)
		if not NetworkManager.group_commit_applied.is_connected(_on_network_group_commit_applied):
			NetworkManager.group_commit_applied.connect(_on_network_group_commit_applied)
		if not NetworkManager.group_snap_feedback.is_connected(_on_network_group_snap_feedback):
			NetworkManager.group_snap_feedback.connect(_on_network_group_snap_feedback)
		create_floating_player_display()
		create_chat_window()
	
	# load up reference image
	var ref_image = PuzzleVar.choice["file_path"]
	# Load the image
	$Image.texture = load(ref_image)
	
	PuzzleVar.background_clicked = false
	PuzzleVar.piece_clicked = false

	# preload the scenes
	var sprite_scene = preload(PIECE_SCENE_PATH)
	
	parse_pieces_json()
	parse_adjacent_json()
	PuzzleVar.ordered_pieces_array.resize(PuzzleVar.global_num_pieces)
	spawned_piece_count = 0
	all_pieces_ready = false
	block_loading_until_state_sync = NetworkManager.is_online and not NetworkManager.is_server
	initial_state_sync_complete = not block_loading_until_state_sync
	var spawner = $PieceSpawner
	if spawner:
		spawner.spawn_function = Callable(self, "_spawn_piece_from_data")
	if NetworkManager.is_online and not NetworkManager.is_server:
		NetworkManager.call_deferred("_try_apply_pending_lobby_snapshot", PuzzleVar.lobby_number)
		NetworkManager.rpc_id(1, "client_scene_ready", PuzzleVar.lobby_number)
	
	z_index = 0
	
	# create puzzle pieces and place in scene
	if not NetworkManager.is_online:
		PuzzleVar.load_and_or_add_puzzle_random_loc(self, sprite_scene, selected_puzzle_dir, true)
		
		await get_tree().process_frame
		_center_camera_on_pieces()
		$Camera2D.zoom = Vector2(0.8, 0.8)

		# create piece count display
		create_piece_count_display()

		if FireAuth.is_online and !NetworkManager.is_server:
			# client is connected to firebase
			var puzzle_name_with_size = PuzzleVar.choice["base_name"] + "_" + str(PuzzleVar.choice["size"])
			await load_firebase_state(puzzle_name_with_size)
		all_pieces_ready = true
		
	#if not is_online_mode and FireAuth.offlineMode == 0:
		#FireAuth.add_active_puzzle(selected_puzzle_name, PuzzleVar.global_num_pieces)
		#FireAuth.add_favorite_puzzle(selected_puzzle_name)
	
	# Connect the back button signal
	#var back_button = $UI_Button/Back
	#back_button.connect("pressed", Callable(self, "_on_back_button_pressed"))
	main_menu.connect(show_win_screen)

	if not NetworkManager.is_online:
		_hide_loading_if_ready()
	
	if NetworkManager.is_online:
		update_online_status_label()
		NetworkManager.lobby_state_applied.connect(_on_lobby_state_applied)
		_start_spawn_watchdog()

func _hide_loading_if_ready() -> void:
	if block_loading_until_state_sync and not initial_state_sync_complete:
		return
	loading.hide()

func _mark_initial_state_sync_complete() -> void:
	if initial_state_sync_complete:
		return
	initial_state_sync_complete = true
	block_loading_until_state_sync = false
	update_online_status_label()
	_hide_loading_if_ready()

# Load state from Firebase 
func load_firebase_state(p_name):
	print("LOADING STATE")
	var saved_piece_data: Array
	if(NetworkManager.is_online):
		print("FB: Update")
		update_online_status_label("Syncing puzzle state...")
		saved_piece_data = await FireAuth.get_puzzle_state_server()
		print("FB: SYNC")
		FireAuth.mp_update_active_puzzle(p_name)
		
	else: 
		await FireAuth.update_active_puzzle(p_name)
		saved_piece_data = await FireAuth.get_puzzle_state(p_name)
	if saved_piece_data.is_empty():
		complete = false
		if NetworkManager.is_online:
			_mark_initial_state_sync_complete()
		return
	if NetworkManager.is_online:
		_apply_completion_from_state(saved_piece_data)
		NetworkManager.rpc_id(1, "apply_lobby_state", PuzzleVar.lobby_number, saved_piece_data)
		return

	# Always apply saved positions (including fully-completed puzzles).
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

	complete = unique_group_ids.size() <= 1
	if(complete):
		print("Puzzle was already complete on join.")
		completed_on_join = true
	update_piece_count_display()

func _apply_completion_from_state(saved_piece_data: Array) -> void:
	var unique_group_ids = []
	for data in saved_piece_data:
		if data["GroupID"] not in unique_group_ids:
			unique_group_ids.append(data["GroupID"])
	complete = unique_group_ids.size() <= 1
	if complete:
		print("Puzzle was already complete on join.")
		completed_on_join = true

func _spawn_piece_from_data(data: Variant) -> Node:
	var piece_scene = preload(PIECE_SCENE_PATH)
	var piece = piece_scene.instantiate()
	if piece and piece.has_method("init_from_spawn"):
		piece.init_from_spawn(data)
	return piece

func _piece_has_texture(piece: Node) -> bool:
	if piece == null or not is_instance_valid(piece):
		return false
	var sprite: Sprite2D = piece.get_node_or_null("Sprite2D")
	return sprite != null and sprite.texture != null

func _ensure_piece_texture(piece: Node, puzzle_dir: String, piece_id: int) -> bool:
	if piece == null or not is_instance_valid(piece):
		return false
	var sprite: Sprite2D = piece.get_node_or_null("Sprite2D")
	if sprite == null:
		return false
	if sprite.texture != null:
		return true
	var normalized_dir := str(puzzle_dir).strip_edges()
	if normalized_dir == "":
		return false
	var texture_path := normalized_dir + "/pieces/raster/" + str(piece_id) + ".png"
	var tex: Texture2D = load(texture_path)
	if tex == null:
		printerr("Jigsaw: Failed to hydrate texture id=", piece_id, " path=", texture_path)
		return false
	sprite.texture = tex
	piece.piece_height = tex.get_height()
	piece.piece_width = tex.get_width()
	var collision_box: CollisionShape2D = piece.get_node_or_null("Sprite2D/Area2D/CollisionShape2D")
	if collision_box and collision_box.shape is RectangleShape2D:
		var rect_shape := collision_box.shape as RectangleShape2D
		rect_shape.extents = Vector2(tex.get_width() / 2, tex.get_height() / 2)
	return true

func _apply_network_snapshot(_puzzle_dir: String, snapshot: Array) -> void:
	if snapshot.is_empty():
		return
	print("Jigsaw: Applying snapshot pieces=", snapshot.size(), " puzzle_dir=", _puzzle_dir)
	_ensure_groups_root()
	var piece_scene = preload(PIECE_SCENE_PATH)
	var max_id := -1
	var valid_group_ids: Dictionary = {}
	var group_anchor_map: Dictionary = {}
	for entry in snapshot:
		if not (entry is Dictionary):
			continue
		var pid := int(entry.get("id", -1))
		if pid < 0:
			continue
		var gid := int(entry.get("group_id", entry.get("group", pid)))
		var pos := _vector2_from_variant(entry.get("position", Vector2.ZERO), Vector2.ZERO)
		var anchor := _vector2_from_variant(entry.get("anchor_pos", pos), pos)
		group_anchor_map[gid] = anchor
		valid_group_ids[gid] = true
		_ensure_group_node(gid, anchor).global_position = anchor
		if pid > max_id:
			max_id = pid
		if PuzzleVar.ordered_pieces_array.size() <= pid:
			PuzzleVar.ordered_pieces_array.resize(pid + 1)
		var entry_puzzle_dir := str(entry.get("puzzle_dir", _puzzle_dir)).strip_edges()
		var existing = PuzzleVar.ordered_pieces_array[pid]
		if existing == null or not is_instance_valid(existing):
			var piece = piece_scene.instantiate()
			if piece and piece.has_method("init_from_spawn"):
				piece.init_from_spawn(entry)
			piece.group_number = gid
			piece.global_position = pos
			_ensure_piece_texture(piece, entry_puzzle_dir, pid)
			piece.set_meta("snapshot_fallback", true)
			add_child(piece)
			PuzzleVar.ordered_pieces_array[pid] = piece
			_attach_piece_to_group(piece, gid, true, anchor)
		else:
			existing.group_number = gid
			existing.global_position = pos
			_ensure_piece_texture(existing, entry_puzzle_dir, pid)
			_attach_piece_to_group(existing, gid, true, anchor)
	if max_id >= 0 and PuzzleVar.global_num_pieces < max_id + 1:
		PuzzleVar.global_num_pieces = max_id + 1
	_delete_empty_group_nodes(valid_group_ids)
	_refresh_spawned_piece_state()
	print("Jigsaw: Snapshot apply complete spawned=", spawned_piece_count, " total=", PuzzleVar.global_num_pieces)
	if spawned_piece_count > 0:
		var sample_piece: Node = null
		if PuzzleVar.ordered_pieces_array.size() > 0:
			sample_piece = PuzzleVar.ordered_pieces_array[0]
		var sample_pos: Vector2 = Vector2.ZERO
		var sample_tex_ok: bool = false
		if sample_piece != null and is_instance_valid(sample_piece):
			sample_pos = sample_piece.global_position
			var sample_sprite: Sprite2D = sample_piece.get_node_or_null("Sprite2D")
			if sample_sprite and sample_sprite.texture != null:
				sample_tex_ok = true
		print(
			"Jigsaw: Snapshot debug cam=", $Camera2D.global_position,
			" sample_pos=", sample_pos,
			" sample_tex_ok=", sample_tex_ok
		)
	if spawned_piece_count > 0:
		_hide_loading_if_ready()
	if not all_pieces_ready and spawned_piece_count >= PuzzleVar.global_num_pieces and PuzzleVar.global_num_pieces > 0:
		await _on_all_pieces_spawned()

func _piece_spawned(node: Node) -> void:
	if node == null:
		return
	_ensure_groups_root()
	var piece = node
	if not piece.is_in_group("puzzle_pieces"):
		piece.add_to_group("puzzle_pieces")
	if piece.ID < 0:
		return
	var piece_texture_ok := _piece_has_texture(piece)
	if not piece_texture_ok:
		piece_texture_ok = _ensure_piece_texture(piece, str(PuzzleVar.selected_puzzle_dir), piece.ID)
	if PuzzleVar.ordered_pieces_array.size() <= piece.ID:
		PuzzleVar.ordered_pieces_array.resize(piece.ID + 1)
	var existing = PuzzleVar.ordered_pieces_array[piece.ID]
	if existing != null and is_instance_valid(existing) and existing != piece:
		var existing_is_fallback := bool(existing.get_meta("snapshot_fallback", false))
		var existing_texture_ok := _piece_has_texture(existing)
		if existing_is_fallback:
			if existing_texture_ok and not piece_texture_ok:
				# Keep textured snapshot fallback if replicated spawn arrived without texture data.
				piece.queue_free()
				return
			existing.queue_free()
			PuzzleVar.ordered_pieces_array[piece.ID] = piece
		else:
			piece.queue_free()
			return
	else:
		PuzzleVar.ordered_pieces_array[piece.ID] = piece
	piece.set_meta("snapshot_fallback", false)
	_attach_piece_to_group(piece, int(piece.group_number), true, piece.global_position)
	_refresh_spawned_piece_state()
	if not all_pieces_ready and spawned_piece_count >= PuzzleVar.global_num_pieces:
		await _on_all_pieces_spawned()

func _on_all_pieces_spawned() -> void:
	all_pieces_ready = true
	spawn_watchdog_running = false
	_center_camera_on_pieces()
	$Camera2D.zoom = Vector2(0.8, 0.8)
	create_piece_count_display()
	if NetworkManager.is_online and not NetworkManager.is_server:
		if FireAuth.is_online:
			var puzzle_name_with_size = PuzzleVar.choice["base_name"] + "_" + str(PuzzleVar.choice["size"])
			load_firebase_state(puzzle_name_with_size)
		else:
			_mark_initial_state_sync_complete()
	else:
		_hide_loading_if_ready()

func _on_lobby_state_applied(_lobby_number: int) -> void:
	if NetworkManager.is_online and not NetworkManager.is_server:
		_mark_initial_state_sync_complete()
	call_deferred("update_piece_count_display")
	update_online_status_label()

func _refresh_spawned_piece_state() -> void:
	var pieces = get_tree().get_nodes_in_group("puzzle_pieces")
	if PuzzleVar.global_num_pieces <= 0:
		var max_id := -1
		for p in pieces:
			if p == null:
				continue
			if p.ID > max_id:
				max_id = p.ID
		if max_id >= 0:
			PuzzleVar.global_num_pieces = max_id + 1
	if PuzzleVar.global_num_pieces <= 0:
		spawned_piece_count = 0
		return
	if PuzzleVar.ordered_pieces_array.size() < PuzzleVar.global_num_pieces:
		PuzzleVar.ordered_pieces_array.resize(PuzzleVar.global_num_pieces)
	var found := 0
	for p in pieces:
		if p == null:
			continue
		if p.ID >= 0 and p.ID < PuzzleVar.global_num_pieces:
			PuzzleVar.ordered_pieces_array[p.ID] = p
			found += 1
	spawned_piece_count = found

func _start_spawn_watchdog() -> void:
	if spawn_watchdog_running:
		return
	spawn_watchdog_running = true
	_watch_for_spawn_completion()

func _watch_for_spawn_completion() -> void:
	var waited_sec := 0.0
	var reannounce_sec := 0.0
	var debug_tick_sec := 0.0
	var unblocked_loading := false
	var showed_partial_ready := false
	while spawn_watchdog_running and not all_pieces_ready:
		_refresh_spawned_piece_state()
		if spawned_piece_count > 0 and not showed_partial_ready:
			showed_partial_ready = true
			_hide_loading_if_ready()
			update_online_status_label("Loading pieces: " + str(spawned_piece_count) + "/" + str(PuzzleVar.global_num_pieces))
		if spawned_piece_count >= PuzzleVar.global_num_pieces and PuzzleVar.global_num_pieces > 0:
			await _on_all_pieces_spawned()
			return
		if NetworkManager.is_online and not NetworkManager.is_server:
			reannounce_sec += 0.1
			if reannounce_sec >= 1.0:
				reannounce_sec = 0.0
				NetworkManager.rpc_id(1, "client_scene_ready", PuzzleVar.lobby_number)
		debug_tick_sec += 0.1
		if debug_tick_sec >= 5.0:
			debug_tick_sec = 0.0
			print(
				"Spawn watchdog: waited=", waited_sec,
				"s global_num_pieces=", PuzzleVar.global_num_pieces,
				" spawned_piece_count=", spawned_piece_count
			)
		waited_sec += 0.1
		if waited_sec >= 20.0 and not unblocked_loading:
			unblocked_loading = true
			_hide_loading_if_ready()
			update_online_status_label("Connected. Waiting for puzzle pieces...")
			printerr("Timeout while waiting for piece spawns. Continuing to retry.")
		await get_tree().create_timer(0.1).timeout

#-----------------------------------------------------------------------------
# UI CREATION AND MANAGEMENT
#-----------------------------------------------------------------------------

#var _digit_width := 40
var _font_size := 80

var _total_label: Label
var _slash_label: Label
var _cur_count_label: Label

func create_piece_count_display():
	var font = load("res://assets/fonts/Montserrat-Bold.ttf") as FontFile

	# --- Total Piece Count label ---
	_total_label = Label.new()
	_total_label.name = "PieceCountTotal"
	_total_label.add_theme_font_override("font", font)
	_total_label.add_theme_font_size_override("font_size", _font_size)
	_total_label.add_theme_color_override("font_color", Color("#c95b0c"))
	_total_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT

	_total_label.anchor_left = 1.0
	_total_label.anchor_right = 1.0
	_total_label.anchor_top = 0.0
	_total_label.anchor_bottom = 0.0

	_total_label.offset_top = 40
	_total_label.offset_right = -20
	_total_label.offset_left = _total_label.offset_right - 260
	$UI_Button.add_child(_total_label)

	# --- Slash label ---
	_slash_label = Label.new()
	_slash_label.name = "SlashLabel"
	_slash_label.text = "/"
	_slash_label.add_theme_font_override("font", font)
	_slash_label.add_theme_font_size_override("font_size", _font_size)
	_slash_label.add_theme_color_override("font_color", Color("#c95b0c"))
	_slash_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_slash_label.anchor_left = 1.0
	_slash_label.anchor_right = 1.0
	_slash_label.anchor_top = 0.0
	_slash_label.anchor_bottom = 0.0

	_slash_label.offset_top = 40
	_slash_label.offset_right = _total_label.offset_left - 5
	_slash_label.offset_left = _slash_label.offset_right - 70
	$UI_Button.add_child(_slash_label)

	# --- Current Count label ---
	_cur_count_label = Label.new()
	_cur_count_label.name = "CurrentPieceCount"
	_cur_count_label.add_theme_font_override("font", font)
	_cur_count_label.add_theme_font_size_override("font_size", _font_size)
	_cur_count_label.add_theme_color_override("font_color", Color("#c95b0c"))
	_cur_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	_cur_count_label.anchor_left = 1.0
	_cur_count_label.anchor_right = 1.0
	_cur_count_label.anchor_top = 0.0
	_cur_count_label.anchor_bottom = 0.0

	_cur_count_label.offset_top = 40
	_cur_count_label.offset_right = _slash_label.offset_left - 5
	_cur_count_label.offset_left = _cur_count_label.offset_right - 260
	$UI_Button.add_child(_cur_count_label)

	update_piece_count_display()


func _has_all_live_pieces_for_counter() -> bool:
	if PuzzleVar.ordered_pieces_array.size() < PuzzleVar.global_num_pieces:
		return false
	for x in range(PuzzleVar.global_num_pieces):
		var piece = PuzzleVar.ordered_pieces_array[x]
		if piece == null or not is_instance_valid(piece):
			PuzzleVar.ordered_pieces_array[x] = null
			return false
		if piece.group_number == null:
			return false
	return true

func update_piece_count_display():
	if not is_instance_valid(_cur_count_label) or not is_instance_valid(_total_label):
		return
	if PuzzleVar.global_num_pieces <= 0:
		_cur_count_label.text = "0"
		_total_label.text = "0"
		return
	if not _has_all_live_pieces_for_counter():
		_refresh_spawned_piece_state()
		if not _has_all_live_pieces_for_counter():
			_cur_count_label.text = "0"
			_total_label.text = str(PuzzleVar.global_num_pieces)
			return

	# Count groups to avoid showing N/N when two large groups remain.
	var group_sizes := {}
	for x in range(PuzzleVar.global_num_pieces):
		var piece = PuzzleVar.ordered_pieces_array[x]
		if piece == null or not is_instance_valid(piece):
			continue
		var group_id = piece.group_number
		if not group_sizes.has(group_id):
			group_sizes[group_id] = 1
		else:
			group_sizes[group_id] += 1

	var groups = group_sizes.size()
	var completed = 0
	if groups == 1:
		completed = PuzzleVar.global_num_pieces
		show_win_screen()
	elif groups == PuzzleVar.global_num_pieces:
		completed = 0
	else:
		completed = PuzzleVar.global_num_pieces - groups + 1

	# No layout adjustments needed anymore
	_cur_count_label.text = str(completed)
	_total_label.text = str(PuzzleVar.global_num_pieces)


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
	floating_status_box.offset_left = -320 # Offset from right edge (box width + margin)
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

func create_chat_window():
	chat_panel = PanelContainer.new()
	chat_panel.name = "ChatWindow"

	var style_box = StyleBoxFlat.new()
	style_box.bg_color = BOX_BACKGROUND_COLOR
	style_box.border_color = BOX_BORDER_COLOR
	style_box.border_width_left = 2
	style_box.border_width_top = 2
	style_box.border_width_right = 2
	style_box.border_width_bottom = 2
	style_box.corner_radius_top_left = 6
	style_box.corner_radius_top_right = 6
	style_box.corner_radius_bottom_left = 6
	style_box.corner_radius_bottom_right = 6
	style_box.content_margin_left = 10
	style_box.content_margin_top = 8
	style_box.content_margin_right = 10
	style_box.content_margin_bottom = 8
	chat_panel.add_theme_stylebox_override("panel", style_box)

	chat_panel.anchor_left = 1.0
	chat_panel.anchor_top = 1.0
	chat_panel.anchor_right = 1.0
	chat_panel.anchor_bottom = 1.0
	chat_panel.offset_left = -270
	chat_panel.offset_right = -20
	chat_panel.offset_bottom = chat_bottom_offset
	chat_expanded_height = 280.0
	chat_panel.offset_top = chat_bottom_offset - chat_expanded_height
	chat_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	chat_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	chat_panel.custom_minimum_size = Vector2(300, chat_expanded_height)

	var ui_layer = $UI_Button
	ui_layer.add_child(chat_panel)

	var layout = VBoxContainer.new()
	layout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.custom_minimum_size = Vector2(0, 0)
	layout.add_theme_constant_override("separation", 6)
	chat_panel.add_child(layout)

	var header_row = HBoxContainer.new()
	header_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_theme_constant_override("separation", 6)
	layout.add_child(header_row)

	var title_label = Label.new()
	title_label.text = "Chat"
	title_label.add_theme_font_size_override("font_size", 18)
	title_label.add_theme_color_override("font_color", BOX_FONT_COLOR)
	title_label.add_theme_font_size_override("font_size", 22)
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(title_label)

	chat_toggle_button = Button.new()
	chat_toggle_button.text = "Minimize"
	chat_toggle_button.add_theme_font_size_override("font_size", 22)
	chat_toggle_button.focus_mode = Control.FOCUS_NONE
	chat_toggle_button.pressed.connect(_on_chat_toggle_button_pressed)
	header_row.add_child(chat_toggle_button)

	chat_content_container = VBoxContainer.new()
	chat_content_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chat_content_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	chat_content_container.add_theme_constant_override("separation", 6)
	layout.add_child(chat_content_container)

	chat_messages_label = RichTextLabel.new()
	chat_messages_label.name = "ChatMessages"
	chat_messages_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chat_messages_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	chat_messages_label.custom_minimum_size = Vector2(0, 140)
	chat_messages_label.scroll_active = true
	chat_messages_label.scroll_following = true
	chat_messages_label.bbcode_enabled = false
	chat_messages_label.add_theme_color_override("default_color", BOX_FONT_COLOR)
	chat_messages_label.add_theme_font_size_override("normal_font_size", 24)  
	chat_messages_label.text = ""
	chat_content_container.add_child(chat_messages_label)

	chat_input_row = HBoxContainer.new()
	chat_input_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chat_content_container.add_child(chat_input_row)

	var input_row = HBoxContainer.new()
	input_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.add_child(input_row)

	chat_input = LineEdit.new()
	chat_input.name = "ChatInput"
	chat_input.placeholder_text = "Type a message..."
	chat_input.add_theme_font_size_override("font_size", 22)
	chat_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chat_input.text_submitted.connect(_on_chat_text_submitted)
	chat_input_row.add_child(chat_input)

	chat_send_button = Button.new()
	chat_send_button.name = "ChatSendButton"
	chat_send_button.text = "Send"
	chat_send_button.add_theme_font_size_override("font_size", 22)
	chat_send_button.pressed.connect(_on_chat_send_button_pressed)
	chat_input_row.add_child(chat_send_button)

func _on_chat_send_button_pressed():
	if not is_instance_valid(chat_input):
		return
	var text := chat_input.text.strip_edges()
	if text == "":
		return
	append_chat_message("You", text)
	NetworkManager.send_chat_message(text)
	chat_input.clear()

func _on_chat_text_submitted(text: String):
	chat_input.text = text
	_on_chat_send_button_pressed()

func append_chat_message(sender: String, message: String):
	if not is_instance_valid(chat_messages_label):
		return
	chat_messages_label.append_text("[%s] %s\n" % [sender, message])
	chat_messages_label.scroll_to_line(chat_messages_label.get_line_count())

func _on_chat_toggle_button_pressed():
	chat_minimized = !chat_minimized
	if not is_instance_valid(chat_panel):
		return

	chat_content_container.visible = not chat_minimized
	chat_toggle_button.text = "Expand" if chat_minimized else "Minimize"

	var new_height := 48.0 if chat_minimized else chat_expanded_height
	chat_panel.offset_top = chat_bottom_offset - new_height
	chat_panel.custom_minimum_size = Vector2(chat_panel.custom_minimum_size.x, new_height)

# Network event handlers
func _on_player_joined(_client_id, client_name):
	update_online_status_label()

func _on_player_left(_client_id, client_name):
	update_online_status_label()

func _on_network_group_commit_applied(commit_id: int, changed_pieces: Array, changed_groups: Array, released_group_id: int) -> void:
	_apply_group_commit_local(commit_id, changed_pieces, changed_groups, released_group_id)

func _on_network_group_snap_feedback(points: Array) -> void:
	_show_group_snap_feedback(points)

func _cleanup_snap_feedback_popup(popup: Node) -> void:
	await get_tree().create_timer(0.45).timeout
	if popup != null and is_instance_valid(popup):
		popup.queue_free()

func _show_group_snap_feedback(points: Array) -> void:
	if points.is_empty():
		return
	var check_texture: Texture2D = preload("res://assets/images/checkmark2.0.png")
	if check_texture == null:
		return
	var spawned_count: int = 0
	for raw_point in points:
		var point: Vector2 = _vector2_from_variant(raw_point, Vector2.ZERO)
		var popup := Sprite2D.new()
		popup.texture = check_texture
		popup.position = point
		popup.scale = Vector2(1.25, 1.25)
		popup.visible = true
		popup.z_index = 10
		add_child(popup)
		spawned_count += 1
		_cleanup_snap_feedback_popup(popup)
	if spawned_count > 0:
		play_snap_sound()
	
func update_online_status_label(custom_text=""):
	connected_players.clear()
	for id in NetworkManager.connected_players.keys():
		if id != multiplayer.get_unique_id():
			connected_players.append(NetworkManager.connected_players[id])

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


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta):
	pass

# Handle esc
func _input(event):
	var chat_has_focus := is_instance_valid(chat_input) and chat_input.has_focus()
	if chat_has_focus and event is InputEventKey:
		if event.is_pressed() and event.echo == false and event.keycode == KEY_ESCAPE:
			get_tree().quit()
		return

	if is_instance_valid(chat_panel) and event is InputEventMouseButton and event.pressed:
		var chat_rect := chat_panel.get_global_rect()
		if chat_rect.has_point(event.position):
			return
	
	# --- Block background toggle when clicking on the zoom buttons area ---
	if is_instance_valid(zoom_box) and event is InputEventMouseButton and event.pressed:
		var zoom_rect := zoom_box.get_global_rect()
		zoom_rect = zoom_rect.grow(20) # extra padding so clicks near the buttons also don't toggle
		if zoom_rect.has_point(event.position):
			return

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
			if event.keycode == KEY_P and event.shift_pressed:
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
		

func _unhandled_input(event):
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			PuzzleVar.background_clicked = not PuzzleVar.background_clicked
		
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
		var midpoint = Vector2((node_bounding_box[2] + node_bounding_box[0]) / 2, (node_bounding_box[3] + node_bounding_box[1]) / 2)
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
	var cell_piece = null
	for candidate in PuzzleVar.ordered_pieces_array:
		if candidate != null and is_instance_valid(candidate):
			cell_piece = candidate
			break
	if cell_piece == null:
		return
	var cell_width: float = float(cell_piece.piece_width)
	var cell_height: float = float(cell_piece.piece_height)

	var arranged_positions: Array = []
	for row in range(grid.size()):
		for col in range(grid[row].size()):
			var piece_id: int = int(grid[row][col])
			var new_position: Vector2 = Vector2(col * cell_width * 1.05, row * cell_height * 1.05)
			arranged_positions.append({
				"id": piece_id,
				"position": new_position
			})

	if NetworkManager.is_online and NetworkManager.use_group_parent_sync and not NetworkManager.use_legacy_piece_flow:
		if arranged_positions.is_empty():
			return
		NetworkManager.rpc_id(1, "request_grid_arrange_v2", int(PuzzleVar.lobby_number), arranged_positions)
		return
	
	# Loop through the grid and arrange pieces
	for raw_entry in arranged_positions:
		if not (raw_entry is Dictionary):
			continue
		var entry: Dictionary = raw_entry
		var piece_id: int = int(entry.get("id", -1))
		if piece_id < 0 or piece_id >= PuzzleVar.ordered_pieces_array.size():
			continue
		var piece = PuzzleVar.ordered_pieces_array[piece_id]
		if piece == null or not is_instance_valid(piece):
			continue
		var new_position: Vector2 = _vector2_from_variant(entry.get("position", piece.global_position), piece.global_position)
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
	complete = true
	#-------------------------LABEL LOGIC------------------------#
	# Load the font file 
	var font = load("res://assets/fonts/KiriFont.ttf") as FontFile
	
	var overlay := Control.new()
	overlay.name = "WinOverlay"
	overlay.set_as_top_level(true) 
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	var label := Label.new()
	
	label.add_theme_font_override("font", font) 
	label.add_theme_font_size_override("font_size", 60) 
	label.add_theme_color_override("font_color", Color(0, 204, 0))
	
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dy := -200
	label.offset_top += dy
	label.offset_bottom += dy
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.text = "You Have Finished the Puzzle!"
	overlay.add_child(label)
	
	var ui := get_tree().current_scene.get_node_or_null("UI")
	if ui == null:
		ui = CanvasLayer.new()
		ui.name = "UI"
		ui.layer = 0
		ui.follow_viewport_enabled = false
		get_tree().current_scene.add_child(ui)
	ui.add_child(overlay)
	
	# wait for user to leave the puzzle
	await main_menu
	overlay.queue_free()

func _center_camera_on_pieces() -> void:
	var cam := $Camera2D
	if cam == null:
		return

	var pieces: Array = PuzzleVar.ordered_pieces_array
	if pieces.is_empty():
		return

	var sum := Vector2.ZERO
	var count := 0

	for p in pieces:
		if is_instance_valid(p):
			sum += p.global_position
			count += 1

	if count == 0:
		return

	cam.global_position = sum / count

func _disconnect_online_client_if_needed() -> void:
	if NetworkManager.is_online and not NetworkManager.is_server:
		print("Client leaving online session. Closing connection...")
		if multiplayer:
			NetworkManager.leave_puzzle()
		else:
			printerr("ERROR: NetworkManager.multiplayer is not available to close connection.")

func _return_to_main_menu_with_loading(delay_seconds: float = 2.0) -> void:
	loading.show()
	print("Returning to puzzle selection screen.")
	await get_tree().create_timer(delay_seconds).timeout
	loading.hide()
	get_tree().change_scene_to_file("res://assets/scenes/new_menu.tscn")
		
# Handles leaving the puzzle scene, saving state, and disconnecting if online client
func _on_back_pressed() -> void:
	
	# 1. Save puzzle state BEFORE clearing any data or freeing nodes
	if !complete and FireAuth.is_online:
		if NetworkManager.is_online:
			#await FireAuth.write_puzzle_state_server(PuzzleVar.lobby_number)
			if NetworkManager.connected_players.is_empty():
				save_popup.popup_centered()
				return
			pass
		else:
			await FireAuth.write_puzzle_state(
				PuzzleVar.ordered_pieces_array,
				PuzzleVar.choice["base_name"] + "_" + str(PuzzleVar.choice["size"]),
				PuzzleVar.global_num_pieces
			)
			
				
	elif complete and FireAuth.is_online:
		print("Puzzle is complete. Checking if we need to delete saved state...")
		
		if NetworkManager.is_online:
			if NetworkManager.connected_players.is_empty() and not completed_on_join:
				print("Puzzle complete, deleting state")
				FireAuth.write_complete_server()
				FireAuth.mp_delete_state()
			elif completed_on_join and NetworkManager.connected_players.is_empty():
				print("Puzzle was already complete on join. Skipping deletion of saved state.")
				FireAuth.mp_delete_active_puzzle()
				FireAuth.mp_delete_state()
			elif completed_on_join:
				print("Other players still connected. Not deleting saved state.")
				FireAuth.mp_delete_active_puzzle()
			else:
				FireAuth.write_complete_server()
		else:
			print("Puzzle complete, deleting state")
			FireAuth.write_complete(PuzzleVar.choice["base_name"] + "_" + str(PuzzleVar.choice["size"]))

	_disconnect_online_client_if_needed()
	await _return_to_main_menu_with_loading()


func _on_no_pressed() -> void:
	save_popup.hide()
	loading.show()
	print("Deleting current puzzle state...")
	if FireAuth.is_online:
		await FireAuth.mp_delete_state()
	else:
		print("Skipping Firebase cleanup because auth is offline.")
	_disconnect_online_client_if_needed()
	await _return_to_main_menu_with_loading()
	
	
func _on_yes_pressed() -> void:
	save_popup.hide()
	loading.show()	
	# 1. Save puzzle state BEFORE clearing any data or freeing nodes
	if !complete and FireAuth.is_online:
		if NetworkManager.is_online:
			pass
		else:
			await FireAuth.write_puzzle_state(
				PuzzleVar.ordered_pieces_array,
				PuzzleVar.choice["base_name"] + "_" + str(PuzzleVar.choice["size"]),
				PuzzleVar.global_num_pieces
			)
			
	elif complete and FireAuth.is_online:
		if NetworkManager.is_online and NetworkManager.connected_players.is_empty():
			print("Puzzle complete, deleting state")
			FireAuth.write_complete_server()
		else:
			print("Puzzle complete, deleting state")
			FireAuth.write_complete(PuzzleVar.choice["base_name"] + "_" + str(PuzzleVar.choice["size"]))
	
	_disconnect_online_client_if_needed()
	await _return_to_main_menu_with_loading()


func _on_help_button_pressed() -> void:
	#help_popup.position = get_viewport().get_mouse_position()
	help_popup.popup_centered()
	

func _on_close_button_pressed() -> void:
	help_popup.hide()
