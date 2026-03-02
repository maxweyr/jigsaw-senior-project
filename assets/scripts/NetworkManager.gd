extends Node

##===============================================
## NetworkManager Handles Network & Server State
##===============================================

# Signals
signal server_started
signal client_connected
signal client_disconnected
signal connection_failed
signal player_joined(client_id, client_name)
signal player_left(client_id, client_name)
signal pieces_connected(piece_id, connected_piece_id, new_group_number, piece_positions)
signal pieces_moved(piece_positions)
signal puzzle_info_received(puzzle_id: String)
signal chat_message_received(sender_name: String, message: String)
signal lock_granted(piece_id: int, group_id: int)
signal lock_denied(piece_id: int, group_id: int, owner_id: int)
signal lock_status(piece_id: int, group_id: int, owner_id: int)
signal lobby_state_applied(lobby_number: int)
signal group_lock_granted_v2(group_id: int)
signal group_lock_denied_v2(group_id: int, owner_id: int)
signal group_commit_applied(commit_id: int, changed_pieces: Array, changed_groups: Array, released_group_id: int)
signal group_snap_feedback(points: Array)

# Variables
var DEFAULT_PORT = 8080
var SERVER_IP = "127.0.0.1"
var is_online: bool = false # True ONLY for active ENet connection to AWS server
var is_server: bool = false # True ONLY for the dedicated AWS instance
var is_offline_authority: bool = false # True ONLY when playing offline (using OfflineMultiplayerPeer)
var peer: MultiplayerPeer = null # Can hold ENetMultiplayerPeer or OfflineMultiplayerPeer
var current_puzzle_id: String = ""
var connected_players = {}
var should_load_game = false
var ready_to_load = false
var kicked_for_new_puzzle: bool = false
const MAX_PLAYERS = 8
const LOCK_TTL_SEC = 10.0
const SNAP_CONSISTENCY_EPS_PX: float = 6.0
const SNAP_FEEDBACK_DEDUPE_PX: float = 8.0
const PIECE_SCENE_PATH = "res://assets/scenes/Piece_2d.tscn"
const DEFAULT_SPAWN_AREA = Vector2(1920, 1080)
const SPAWN_MARGIN = 50.0
const SPAWNER_READY_RETRY_MAX = 40
const SPAWNER_READY_RETRY_SEC = 0.05
# For puzzle state authority, use server RPC flow by default.
# MultiplayerSynchronizer is kept for visibility routing/spawn plumbing only.
var use_multiplayer_sync := false
var use_group_parent_sync := true
var use_legacy_piece_flow := false

# --- server-side lobby maps (server only) ---
var client_lobby: Dictionary = {}        # { peer_id: lobby_number }
var lobby_players: Dictionary = {}       # { lobby_number: { peer_id: player_name } }
var lobby_puzzle: Dictionary = {}        # { lobby_number: puzzle_id }  # optional; falls back to current_puzzle_id
var lobby_group_locks: Dictionary = {}   # { lobby_number: { group_id: { owner, expires_at } } }
var lobby_piece_groups: Dictionary = {}  # { lobby_number: { piece_id: group_id } }
var lobby_piece_nodes: Dictionary = {}   # { lobby_number: { piece_id: Node } }
var lobby_state_loaded: Dictionary = {}  # { lobby_number: bool }
var lobby_groups: Dictionary = {}        # { lobby_number: { group_id: GroupStateDict } }
var lobby_topology: Dictionary = {}      # { lobby_number: { adjacency_map, reference_coords, piece_centers, piece_sizes, puzzle_dir } }
var lobby_commit_seq: Dictionary = {}    # { lobby_number: int }
var server_piece_spawner: MultiplayerSpawner = null
var peer_spawn_sync_done: Dictionary = {} # { peer_id: "lobby|puzzle_dir" }
var pending_lobby_snapshots: Dictionary = {} # client-side: { lobby_number: { puzzle_dir, snapshot } }

func _bind_multiplayer_to_root() -> void:
	var tree = get_tree()
	if tree == null:
		return
	var root = tree.root
	if root == null:
		return
	# Ensure every node path (including /root/JigsawPuzzleNode/PieceSpawner) uses a root API with this peer.
	var root_api := tree.get_multiplayer()
	if root_api != null:
		root_api.multiplayer_peer = multiplayer.multiplayer_peer
		tree.set_multiplayer(root_api, root.get_path())

func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	# load env file for server info
	var env = ConfigFile.new()
	var err = env.load("res://.env")
	if err != OK:
		print("could not read env file: ",err)
	else:
		DEFAULT_PORT = env.get_value("server", "PORT", 8080)
		SERVER_IP = str(env.get_value("server", "SERVER_IP", "127.0.0.1"))
	# Prioritize Dedicated Server Check
	if OS.has_feature("server") or "--server" in OS.get_cmdline_args() \
	or OS.has_feature("headless") or "--headless" in OS.get_cmdline_args():
		print("NetworkManager: Starting as Dedicated Server...")
		is_server = true # This is an actual server
		print("NetworkManager: Dedicated Server Mode Enabled.")
		# is_online will be set true inside start_server()
		start_server() # Start the ENet server immediately
		_init_server_spawner_host()
	else:
		# If not a dedicated server, start in offline mode by default
		set_offline_mode() # Setup OfflineMultiplayerPeer
	
	# Connect to multiplayer signals
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	
	# Authentication can happen regardless of peer type initially
	# It sets FireAuth.is_online (internet status)
	await check_internet_and_authenticate()

func _process(_delta):
	# Check if we should load the game
	if should_load_game and ready_to_load:
		var scene_path = "res://assets/scenes/jigsaw_puzzle_1.tscn"
		print("NetworkManager loading game scene inside process loop")
		# Get the main scene tree
		var tree = Engine.get_main_loop()
		if tree:
			# Reset flags
			should_load_game = false
			ready_to_load = false
			# Change the scene
			tree.change_scene_to_file(scene_path)
		else:
			print("ERROR: NetworkManager unable to get scene tree")

# Check for an internet connection, then authenticates the firebase user (sets Firebase is_online status)
func check_internet_and_authenticate():
	# Create an HTTP request node and connect its completion signal
	var http_request = HTTPRequest.new()
	GlobalProgress.add_child(http_request)
	# Connect the request_completed signal properly
	http_request.request_completed.connect(_on_request_completed)
	# Perform a GET request to a reliable URL
	var error = http_request.request("https://www.google.com/")
	if error != OK:
		print("WARNING: NetworkManager failed to send HTTP request:", error)
		is_online = false
		FireAuth.is_online = false

func _on_request_completed(_result, response_code, _headers, _body):
	if response_code == 200:
		print("NetworkManager has internet connection available")
		var login_success := await FireAuth.handle_login()
		if !login_success:
			FireAuth.is_online = false
		FireAuth.is_online = true
	else:
		print("WARNING: NetworkManager has no internet connection or bad response, code:", response_code)
		is_online = false
		FireAuth.is_online = false

# Method to explicitly set offline mode
func set_offline_mode():
	print("NetworkManager: Setting up for Offline Play.")
	if not multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_bind_multiplayer_to_root()
	peer = multiplayer.multiplayer_peer # Store reference
	is_online = false
	is_server = false # Client instance is never the "server"
	is_offline_authority = true # It IS the authority locally for offline play
	kicked_for_new_puzzle = false
	should_load_game = false
	ready_to_load = false
	current_puzzle_id = ""
	connected_players.clear()

# Start a server with a default puzzle
func start_server():
	print("NetworkManager starting headless server for ", str(SERVER_IP), " and port ", DEFAULT_PORT)
	# For server, just pick a default puzzle ID (can be changed via args later)
	var puzzle_id = PuzzleVar.default_path 
	if OS.get_cmdline_args().size() > 1:
		var args = OS.get_cmdline_args()
		for i in range(args.size()):
			if args[i] == "--puzzle" and i + 1 < args.size():
				puzzle_id = args[i + 1]
	
	if is_online:
		print("ERROR: NetworkManager already in a network session, cannot start server")
		return false # Indicate failure
	
	var enet_peer = ENetMultiplayerPeer.new()
	var error = enet_peer.create_server(DEFAULT_PORT, MAX_PLAYERS)
	
	if error != OK:
		print("ERROR: NetworkManager could not create server: ", error)
		multiplayer.multiplayer_peer = null # Ensure no peer
		peer = null
		set_offline_mode() # Fallback to offline state
		return false # Indicate failure
	
	multiplayer.multiplayer_peer = enet_peer
	_bind_multiplayer_to_root()
	peer = enet_peer
	current_puzzle_id = puzzle_id # Set the initial puzzle
	is_online = true
	is_server = true # Already true
	is_offline_authority = false
	print("NetworkManager Dedicated Server Started...")
	return true

# Connect to a server
func join_server() -> bool:
	if is_online or is_server: return false # Prevent server or already-online client
	
	print("NetworkManager attempting to connect to server at ", SERVER_IP)
	
	var enet_peer = ENetMultiplayerPeer.new()
	var error = enet_peer.create_client(SERVER_IP, int(DEFAULT_PORT))
	
	if error != OK:
		print("WARNING: NetworkManager failed to connect to server: ", error)
		multiplayer.multiplayer_peer = null
		peer = null
		set_offline_mode() # Fallback to offline state
		connection_failed.emit() # Emit failure signal
		return false # Indicate failure
	
	multiplayer.multiplayer_peer = enet_peer
	_bind_multiplayer_to_root()
	peer = enet_peer # Store the ENet peer
	# current_puzzle_id will be set via RPC (_send_puzzle_info)
	is_online = true
	is_server = false
	is_offline_authority = false
	print("NetworkManager (Client): Connection initiated...")
	return true

func send_chat_message(message: String):
	if not is_online:
		return
	# Client only: send chat message to server	
	rpc_id(1, "_receive_chat_message", FireAuth.get_nickname(), message)

func kick_other_clients_in_lobby():
	if not is_online or is_server:
		return
	rpc_id(1, "request_kick_lobby_clients")

# Disconnect from the current session
func disconnect_from_server():
	if is_server: return # Dedicated server doesn't disconnect this way
	if not is_online: return # Already offline
	
	print("NetworkManager (Client): Disconnecting...")
	if peer != null and peer is ENetMultiplayerPeer:
		if peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
			peer.close()
	
	# Reset state and explicitly go back to offline mode
	set_offline_mode()
	print("NetworkManager (Client): Disconnected. Switched to Offline Mode.")

# Leave the current puzzle
func leave_puzzle():
	if is_server: # no need to for the server to leave its only puzzle
		return
	if is_online:
		disconnect_from_server()

func _now_sec() -> float:
	return float(Time.get_ticks_msec()) / 1000.0

func _get_lobby_lock_map(lobby_number: int) -> Dictionary:
	if not lobby_group_locks.has(lobby_number):
		lobby_group_locks[lobby_number] = {}
	return lobby_group_locks[lobby_number]

func _get_lobby_piece_map(lobby_number: int) -> Dictionary:
	if not lobby_piece_groups.has(lobby_number):
		lobby_piece_groups[lobby_number] = {}
	return lobby_piece_groups[lobby_number]

func _get_lobby_piece_nodes(lobby_number: int) -> Dictionary:
	if not lobby_piece_nodes.has(lobby_number):
		lobby_piece_nodes[lobby_number] = {}
	return lobby_piece_nodes[lobby_number]

func _get_lobby_groups(lobby_number: int) -> Dictionary:
	if not lobby_groups.has(lobby_number):
		lobby_groups[lobby_number] = {}
	return lobby_groups[lobby_number]

func _vector2_from_variant(value: Variant, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	if value is Vector2:
		return value
	if value is Dictionary and value.has("x") and value.has("y"):
		return Vector2(float(value["x"]), float(value["y"]))
	return fallback

func _register_piece_node(lobby_number: int, piece_id: int, node: Node) -> void:
	var pieces = _get_lobby_piece_nodes(lobby_number)
	pieces[piece_id] = node

func _count_live_lobby_piece_nodes(lobby_number: int) -> int:
	if not lobby_piece_nodes.has(lobby_number):
		return 0
	var pieces: Dictionary = lobby_piece_nodes[lobby_number]
	var stale_ids: Array = []
	var live_count := 0
	for key in pieces.keys():
		var node = pieces[key]
		if node == null or not is_instance_valid(node):
			stale_ids.append(key)
			continue
		live_count += 1
	for key in stale_ids:
		pieces.erase(key)
	return live_count

func _get_piece_node(lobby_number: int, piece_id: int) -> Node:
	if not lobby_piece_nodes.has(lobby_number):
		return null
	return lobby_piece_nodes[lobby_number].get(piece_id, null)

func _clear_lobby_pieces(lobby_number: int) -> void:
	if lobby_piece_nodes.has(lobby_number):
		for node in lobby_piece_nodes[lobby_number].values():
			if is_instance_valid(node):
				node.queue_free()
		lobby_piece_nodes.erase(lobby_number)
	lobby_state_loaded.erase(lobby_number)
	lobby_groups.erase(lobby_number)
	lobby_commit_seq.erase(lobby_number)

func _serialize_group_state(group_state: Dictionary) -> Dictionary:
	return {
		"group_id": int(group_state.get("group_id", -1)),
		"piece_ids": Array(group_state.get("piece_ids", [])).duplicate(true),
		"anchor_piece_id": int(group_state.get("anchor_piece_id", -1)),
		"anchor_pos": _vector2_from_variant(group_state.get("anchor_pos", Vector2.ZERO)),
		"perimeter_piece_ids": Array(group_state.get("perimeter_piece_ids", [])).duplicate(true),
		"rev": int(group_state.get("rev", 0))
	}

func _serialize_all_lobby_groups(lobby_number: int) -> Array:
	var result: Array = []
	var groups: Dictionary = _get_lobby_groups(lobby_number)
	var group_ids: Array = groups.keys()
	group_ids.sort()
	for gid_value in group_ids:
		var gid := int(gid_value)
		var state: Dictionary = groups.get(gid, {})
		if state.is_empty():
			continue
		result.append(_serialize_group_state(state))
	return result

func _next_lobby_commit_id(lobby_number: int) -> int:
	var next_id := int(lobby_commit_seq.get(lobby_number, 0)) + 1
	lobby_commit_seq[lobby_number] = next_id
	return next_id

func _get_group_piece_ids(lobby_number: int, group_id: int) -> Array:
	var groups: Dictionary = _get_lobby_groups(lobby_number)
	if not groups.has(group_id):
		return []
	return Array(groups[group_id].get("piece_ids", [])).duplicate(true)

func _ensure_lobby_topology(lobby_number: int, puzzle_dir: String) -> bool:
	var normalized_dir := str(puzzle_dir).strip_edges()
	if normalized_dir == "":
		return false
	if lobby_topology.has(lobby_number):
		var cached: Dictionary = lobby_topology[lobby_number]
		if str(cached.get("puzzle_dir", "")).strip_edges() == normalized_dir:
			return true

	var adjacent_path := normalized_dir + "/adjacent.json"
	var pieces_path := normalized_dir + "/pieces/pieces.json"
	var adjacent_file := FileAccess.open(adjacent_path, FileAccess.READ)
	if adjacent_file == null:
		print("ERROR: Server could not open adjacent.json at ", adjacent_path)
		return false
	var adjacent_text := adjacent_file.get_as_text()
	adjacent_file.close()
	var adjacent_parser := JSON.new()
	if adjacent_parser.parse(adjacent_text) != OK:
		print("ERROR: Server failed to parse adjacent.json for ", normalized_dir)
		return false

	var pieces_file := FileAccess.open(pieces_path, FileAccess.READ)
	if pieces_file == null:
		print("ERROR: Server could not open pieces.json at ", pieces_path)
		return false
	var pieces_text := pieces_file.get_as_text()
	pieces_file.close()
	var pieces_parser := JSON.new()
	if pieces_parser.parse(pieces_text) != OK:
		print("ERROR: Server failed to parse pieces.json for ", normalized_dir)
		return false

	var adjacency_map: Dictionary = {}
	var adjacent_data: Variant = adjacent_parser.data
	if adjacent_data is Dictionary:
		for raw_key in adjacent_data.keys():
			var pid := int(raw_key)
			var neighbor_list: Array = []
			var raw_neighbors: Variant = adjacent_data[raw_key]
			if raw_neighbors is Array:
				for raw_neighbor in raw_neighbors:
					neighbor_list.append(int(raw_neighbor))
			adjacency_map[pid] = neighbor_list
	elif adjacent_data is Array:
		for idx in range(adjacent_data.size()):
			var raw_neighbors_arr: Variant = adjacent_data[idx]
			var neighbors_for_idx: Array = []
			if raw_neighbors_arr is Array:
				for raw_neighbor in raw_neighbors_arr:
					neighbors_for_idx.append(int(raw_neighbor))
			adjacency_map[idx] = neighbors_for_idx
	else:
		return false

	var reference_coords: Dictionary = {}
	var reference_centers: Dictionary = {}
	var piece_sizes: Dictionary = {}
	var pieces_data: Variant = pieces_parser.data
	if pieces_data is Dictionary:
		for raw_key in pieces_data.keys():
			var pid := int(raw_key)
			var coords: Variant = pieces_data[raw_key]
			if not (coords is Array) or coords.size() < 4:
				continue
			var arr_coords: Array = Array(coords).duplicate(true)
			var x0 := float(arr_coords[0])
			var y0 := float(arr_coords[1])
			var x1 := float(arr_coords[2])
			var y1 := float(arr_coords[3])
			reference_coords[pid] = arr_coords
			reference_centers[pid] = Vector2((x0 + x1) * 0.5, (y0 + y1) * 0.5)
			piece_sizes[pid] = Vector2(abs(x1 - x0), abs(y1 - y0))
	elif pieces_data is Array:
		for idx in range(pieces_data.size()):
			var coords_from_array: Variant = pieces_data[idx]
			if not (coords_from_array is Array) or coords_from_array.size() < 4:
				continue
			var arr_coords_from_array: Array = Array(coords_from_array).duplicate(true)
			var x0a := float(arr_coords_from_array[0])
			var y0a := float(arr_coords_from_array[1])
			var x1a := float(arr_coords_from_array[2])
			var y1a := float(arr_coords_from_array[3])
			reference_coords[idx] = arr_coords_from_array
			reference_centers[idx] = Vector2((x0a + x1a) * 0.5, (y0a + y1a) * 0.5)
			piece_sizes[idx] = Vector2(abs(x1a - x0a), abs(y1a - y0a))
	else:
		return false

	lobby_topology[lobby_number] = {
		"puzzle_dir": normalized_dir,
		"adjacency_map": adjacency_map,
		"reference_coords": reference_coords,
		"reference_centers": reference_centers,
		"piece_sizes": piece_sizes
	}
	return true

func _load_piece_count(puzzle_dir: String) -> int:
	var resolved := _resolve_puzzle_dir(puzzle_dir)
	if resolved == "":
		return 0
	var adjacent_path := resolved + "/adjacent.json"
	var file = FileAccess.open(adjacent_path, FileAccess.READ)
	if file == null:
		print("ERROR: Server could not open adjacent.json at ", adjacent_path)
		return 0
	var text := file.get_as_text()
	file.close()
	var parser = JSON.new()
	if parser.parse(text) != OK:
		print("ERROR: Server failed to parse adjacent.json for ", resolved)
		return 0
	if parser.data is Dictionary:
		return parser.data.size()
	if parser.data is Array:
		return parser.data.size()
	return 0

func _group_snap_threshold_for_pair(topology: Dictionary, piece_a: int, piece_b: int) -> float:
	var piece_sizes: Dictionary = topology.get("piece_sizes", {})
	var default_size := Vector2(100.0, 100.0)
	var size_a := _vector2_from_variant(piece_sizes.get(piece_a, default_size), default_size)
	var size_b := _vector2_from_variant(piece_sizes.get(piece_b, default_size), default_size)
	var min_dim: float = float(min(min(size_a.x, size_a.y), min(size_b.x, size_b.y)))
	return max(8.0, min_dim * 0.24)

func _is_valid_server_snap_pair(lobby_number: int, piece_a: int, piece_b: int) -> bool:
	if not lobby_topology.has(lobby_number):
		return false
	var topology: Dictionary = lobby_topology[lobby_number]
	var centers: Dictionary = topology.get("reference_centers", {})
	if not centers.has(piece_a) or not centers.has(piece_b):
		return false
	var node_a: Node2D = _get_piece_node(lobby_number, piece_a) as Node2D
	var node_b: Node2D = _get_piece_node(lobby_number, piece_b) as Node2D
	if node_a == null or not is_instance_valid(node_a):
		return false
	if node_b == null or not is_instance_valid(node_b):
		return false
	var ref_a: Vector2 = _vector2_from_variant(centers[piece_a], Vector2.ZERO)
	var ref_b: Vector2 = _vector2_from_variant(centers[piece_b], Vector2.ZERO)
	var expected_delta: Vector2 = ref_a - ref_b
	var world_delta: Vector2 = node_a.global_position - node_b.global_position
	var snap_distance: float = (world_delta - expected_delta).length()
	return snap_distance <= _group_snap_threshold_for_pair(topology, piece_a, piece_b)

func _compute_perimeter_for_group(lobby_number: int, group_id: int, piece_ids: Array, piece_map: Dictionary) -> Array:
	if not lobby_topology.has(lobby_number):
		return piece_ids.duplicate(true)
	var topology: Dictionary = lobby_topology[lobby_number]
	var adjacency_map: Dictionary = topology.get("adjacency_map", {})
	var perimeter: Array = []
	for raw_piece_id in piece_ids:
		var piece_id := int(raw_piece_id)
		var neighbors: Array = Array(adjacency_map.get(piece_id, []))
		var is_perimeter := false
		for raw_neighbor in neighbors:
			var neighbor_id := int(raw_neighbor)
			var neighbor_group := int(piece_map.get(neighbor_id, neighbor_id))
			if neighbor_group != group_id:
				is_perimeter = true
				break
		if is_perimeter:
			perimeter.append(piece_id)
	perimeter.sort()
	return perimeter

func _rebuild_lobby_groups_from_piece_map(lobby_number: int) -> void:
	var piece_nodes: Dictionary = _get_lobby_piece_nodes(lobby_number)
	var piece_map: Dictionary = _get_lobby_piece_map(lobby_number)
	var previous_groups: Dictionary = lobby_groups.get(lobby_number, {})
	var groups: Dictionary = {}
	var piece_ids: Array = piece_nodes.keys()
	piece_ids.sort()
	for raw_pid in piece_ids:
		var pid := int(raw_pid)
		var node = piece_nodes[raw_pid]
		if node == null or not is_instance_valid(node):
			continue
		var gid := int(piece_map.get(pid, int(node.group_number)))
		piece_map[pid] = gid
		node.group_number = gid
		if not groups.has(gid):
			var prev_state: Dictionary = previous_groups.get(gid, {})
			groups[gid] = {
				"group_id": gid,
				"piece_ids": [],
				"anchor_piece_id": int(prev_state.get("anchor_piece_id", gid)),
				"anchor_pos": node.global_position,
				"perimeter_piece_ids": [],
				"lock_owner": -1,
				"lock_expires_at": 0.0,
				"rev": int(prev_state.get("rev", 0)),
				"last_drag_seq": int(prev_state.get("last_drag_seq", -1))
			}
		var state: Dictionary = groups[gid]
		var state_piece_ids: Array = state.get("piece_ids", [])
		state_piece_ids.append(pid)
		state["piece_ids"] = state_piece_ids
		groups[gid] = state

	for raw_gid in groups.keys():
		var gid := int(raw_gid)
		var state: Dictionary = groups[gid]
		var state_piece_ids: Array = Array(state.get("piece_ids", []))
		state_piece_ids.sort()
		state["piece_ids"] = state_piece_ids
		var anchor_piece_id := int(state.get("anchor_piece_id", gid))
		if state_piece_ids.has(anchor_piece_id):
			state["anchor_piece_id"] = anchor_piece_id
		else:
			state["anchor_piece_id"] = int(state_piece_ids[0]) if state_piece_ids.size() > 0 else gid
		var anchor_node = _get_piece_node(lobby_number, int(state["anchor_piece_id"]))
		if anchor_node and is_instance_valid(anchor_node):
			state["anchor_pos"] = anchor_node.global_position
		state["perimeter_piece_ids"] = _compute_perimeter_for_group(lobby_number, gid, state_piece_ids, piece_map)
		groups[gid] = state

	var locks: Dictionary = _get_lobby_lock_map(lobby_number)
	for raw_gid in groups.keys():
		var gid := int(raw_gid)
		var state: Dictionary = groups[gid]
		var owner := _get_lock_owner(lobby_number, gid)
		state["lock_owner"] = owner
		if owner != -1 and locks.has(gid):
			state["lock_expires_at"] = float(locks[gid].get("expires_at", 0.0))
		else:
			state["lock_expires_at"] = 0.0
		state["rev"] = int(state.get("rev", 0)) + 1
		groups[gid] = state
	lobby_groups[lobby_number] = groups

func _build_lobby_spawn_snapshot(lobby_number: int, puzzle_dir: String) -> Array:
	var snapshot: Array = []
	if not lobby_piece_nodes.has(lobby_number):
		return snapshot
	var pieces: Dictionary = lobby_piece_nodes[lobby_number]
	var groups: Dictionary = _get_lobby_groups(lobby_number)
	var ids: Array = pieces.keys()
	ids.sort()
	for key in ids:
		var pid := int(key)
		var node = pieces[key]
		if node == null or not is_instance_valid(node):
			continue
		var gid := int(node.group_number)
		var group_state: Dictionary = groups.get(gid, {})
		var anchor_pos := _vector2_from_variant(group_state.get("anchor_pos", node.position), node.position)
		snapshot.append({
			"id": pid,
			"lobby": lobby_number,
			"puzzle_dir": puzzle_dir,
			"position": node.position,
			"group": gid,
			"group_id": gid,
			"anchor_pos": anchor_pos,
			"anchor_piece_id": int(group_state.get("anchor_piece_id", pid))
		})
	return snapshot

func _send_lobby_snapshot_to_peer(peer_id: int, lobby_number: int, puzzle_dir: String) -> void:
	if not is_server:
		return
	var snapshot := _build_lobby_spawn_snapshot(lobby_number, puzzle_dir)
	print(
		"NetworkManager: Sending lobby snapshot to peer ", peer_id,
		" lobby=", lobby_number,
		" pieces=", snapshot.size()
	)
	rpc_id(peer_id, "_receive_lobby_snapshot", lobby_number, puzzle_dir, snapshot)

func _bootstrap_peer_lobby_state(peer_id: int, lobby_number: int, puzzle_dir: String) -> void:
	if not is_server:
		return
	if peer_id <= 0:
		return
	var normalized_dir := str(puzzle_dir).strip_edges()
	if normalized_dir == "":
		return
	await _ensure_lobby_pieces_spawned(lobby_number, normalized_dir)
	_update_visibility_for_peer(peer_id)
	_send_lobby_snapshot_to_peer(peer_id, lobby_number, normalized_dir)

func _queue_lobby_snapshot(lobby_number: int, puzzle_dir: String, snapshot: Array) -> void:
	pending_lobby_snapshots[lobby_number] = {
		"puzzle_dir": puzzle_dir,
		"snapshot": snapshot.duplicate(true)
	}

func _try_apply_pending_lobby_snapshot(lobby_number: int = -1) -> void:
	if is_server:
		return
	if pending_lobby_snapshots.is_empty():
		return
	var tree = get_tree()
	if tree == null:
		return
	var scene = tree.current_scene
	if scene == null or not scene.has_method("_apply_network_snapshot"):
		return
	var target_lobby := int(lobby_number)
	if target_lobby >= 0:
		if not pending_lobby_snapshots.has(target_lobby):
			return
		var single_entry: Dictionary = pending_lobby_snapshots[target_lobby]
		pending_lobby_snapshots.erase(target_lobby)
		scene.call_deferred(
			"_apply_network_snapshot",
			str(single_entry.get("puzzle_dir", "")),
			Array(single_entry.get("snapshot", []))
		)
		return
	var lobby_keys: Array = pending_lobby_snapshots.keys()
	for key in lobby_keys:
		var k := int(key)
		var entry: Dictionary = pending_lobby_snapshots[k]
		pending_lobby_snapshots.erase(k)
		scene.call_deferred(
			"_apply_network_snapshot",
			str(entry.get("puzzle_dir", "")),
			Array(entry.get("snapshot", []))
		)

func _respawn_lobby_pieces(lobby_number: int, puzzle_dir: String) -> void:
	if not is_server:
		return
	_init_server_spawner_host()
	if server_piece_spawner == null:
		return
	var snapshot := _build_lobby_spawn_snapshot(lobby_number, puzzle_dir)
	if snapshot.is_empty():
		return
	print("NetworkManager: Replaying ", snapshot.size(), " piece spawns for lobby ", lobby_number)
	_clear_lobby_pieces(lobby_number)
	await get_tree().process_frame
	var piece_map = _get_lobby_piece_map(lobby_number)
	for data in snapshot:
		var node = server_piece_spawner.spawn(data)
		if node:
			node.set_multiplayer_authority(1)
			var pid := int(data.get("id", -1))
			if pid >= 0:
				_register_piece_node(lobby_number, pid, node)
				piece_map[pid] = int(data.get("group", pid))
	_rebuild_lobby_groups_from_piece_map(lobby_number)
	_update_visibility_for_lobby(lobby_number)
	print("NetworkManager: Replay complete for lobby ", lobby_number)

func _resolve_puzzle_dir(puzzle_dir: String) -> String:
	var candidate := str(puzzle_dir).strip_edges()
	if candidate == "":
		return ""
	if FileAccess.file_exists(candidate + "/adjacent.json"):
		return candidate

	var normalized := candidate
	var exts = [".jpg", ".jpeg", ".png", ".webp"]
	for ext in exts:
		normalized = normalized.replace(ext + "_", "_")
		if normalized.ends_with(ext):
			normalized = normalized.left(normalized.length() - ext.length())

	var attempts: Array[String] = []
	attempts.append(normalized)

	var base := normalized
	var size_token := ""
	var last_sep := normalized.rfind("_")
	if last_sep != -1:
		var tail := normalized.substr(last_sep + 1, normalized.length() - last_sep - 1)
		if tail.is_valid_int():
			base = normalized.substr(0, last_sep)
			size_token = tail

	if size_token == "":
		attempts.append(base + "_500")
		attempts.append(base + "_100")
		attempts.append(base + "_10")
	else:
		for fallback_size in ["500", "100", "10"]:
			attempts.append(base + "_" + fallback_size)

	for dir_try in attempts:
		if FileAccess.file_exists(dir_try + "/adjacent.json"):
			if dir_try != candidate:
				print("NetworkManager: Resolved puzzle dir '", candidate, "' -> '", dir_try, "'")
			return dir_try
	return ""

func _init_server_spawner_host() -> void:
	if not is_server:
		return
	var tree = get_tree()
	if tree == null:
		return
	var root = tree.root
	if root == null:
		return
	_bind_multiplayer_to_root()
	var puzzle_root = root.get_node_or_null("JigsawPuzzleNode")
	if puzzle_root == null:
		puzzle_root = Node2D.new()
		puzzle_root.name = "JigsawPuzzleNode"
		root.add_child(puzzle_root)
	var server_id := 1
	puzzle_root.set_multiplayer_authority(server_id, true)
	var spawner = puzzle_root.get_node_or_null("PieceSpawner")
	if spawner == null:
		spawner = MultiplayerSpawner.new()
		spawner.name = "PieceSpawner"
		spawner.spawn_path = NodePath("..")
		puzzle_root.add_child(spawner)
	else:
		spawner.spawn_path = NodePath("..")
	spawner.set_multiplayer_authority(server_id, true)
	spawner.spawn_function = Callable(self, "_spawn_piece_from_data")
	server_piece_spawner = spawner

func _spawner_can_spawn() -> bool:
	if server_piece_spawner == null:
		return false
	if not server_piece_spawner.is_inside_tree():
		return false
	var spawner_api := server_piece_spawner.get_multiplayer()
	if spawner_api == null:
		return false
	if not spawner_api.has_multiplayer_peer():
		return false
	return server_piece_spawner.is_multiplayer_authority()

func _spawn_piece_from_data(data: Variant) -> Node:
	var piece_scene = preload(PIECE_SCENE_PATH)
	var piece = piece_scene.instantiate()
	if piece and piece.has_method("init_from_spawn"):
		piece.init_from_spawn(data)
	return piece

func _ensure_lobby_pieces_spawned(lobby_number: int, puzzle_dir: String, retry_count: int = 0) -> void:
	if not is_server:
		return
	if puzzle_dir == "":
		print("ERROR: _ensure_lobby_pieces_spawned called with empty puzzle_dir for lobby ", lobby_number)
		return
	var resolved_puzzle_dir := _resolve_puzzle_dir(puzzle_dir)
	if resolved_puzzle_dir == "":
		print("ERROR: Could not resolve puzzle dir for lobby ", lobby_number, ": ", puzzle_dir)
		return
	if resolved_puzzle_dir != puzzle_dir:
		lobby_puzzle[lobby_number] = resolved_puzzle_dir
	if not _ensure_lobby_topology(lobby_number, resolved_puzzle_dir):
		print("ERROR: Could not load topology for lobby ", lobby_number, " dir=", resolved_puzzle_dir)
		return
	_init_server_spawner_host()
	if server_piece_spawner == null:
		print("ERROR: server_piece_spawner is null for lobby ", lobby_number)
		return
	if not _spawner_can_spawn():
		if retry_count >= SPAWNER_READY_RETRY_MAX:
			var spawner_api := server_piece_spawner.get_multiplayer()
			var has_peer := spawner_api != null and spawner_api.has_multiplayer_peer()
			var auth_id := server_piece_spawner.get_multiplayer_authority()
			var local_id := spawner_api.get_unique_id() if spawner_api != null else -1
			print(
				"ERROR: PieceSpawner never became ready/authoritative for lobby ", lobby_number,
				" | inside_tree=", server_piece_spawner.is_inside_tree(),
				" has_peer=", has_peer,
				" auth_id=", auth_id,
				" local_id=", local_id
			)
			return
		await get_tree().create_timer(SPAWNER_READY_RETRY_SEC).timeout
		await _ensure_lobby_pieces_spawned(lobby_number, resolved_puzzle_dir, retry_count + 1)
		return
	var piece_count = _load_piece_count(resolved_puzzle_dir)
	if piece_count <= 0:
		print("ERROR: piece_count <= 0 for lobby ", lobby_number, " dir=", resolved_puzzle_dir)
		return
	var live_existing_nodes := _count_live_lobby_piece_nodes(lobby_number)
	var piece_map: Dictionary = _get_lobby_piece_map(lobby_number)
	if live_existing_nodes == piece_count:
		if piece_map.size() != piece_count:
			for raw_pid in _get_lobby_piece_nodes(lobby_number).keys():
				var pid := int(raw_pid)
				var node = _get_lobby_piece_nodes(lobby_number).get(raw_pid, null)
				if node != null and is_instance_valid(node):
					piece_map[pid] = int(node.group_number)
		_rebuild_lobby_groups_from_piece_map(lobby_number)
		return
	if live_existing_nodes > 0:
		print(
			"WARNING: Lobby ", lobby_number,
			" has partial piece set (live=", live_existing_nodes,
			" expected=", piece_count,
			"). Rebuilding spawn set."
		)
		_clear_lobby_pieces(lobby_number)
		await get_tree().process_frame
	print("NetworkManager: Spawning ", piece_count, " pieces for lobby ", lobby_number, " dir=", resolved_puzzle_dir)
	var rng = RandomNumberGenerator.new()
	rng.randomize()
	for piece_id in range(piece_count):
		var pos = Vector2(
			rng.randf_range(SPAWN_MARGIN, DEFAULT_SPAWN_AREA.x - SPAWN_MARGIN),
			rng.randf_range(SPAWN_MARGIN, DEFAULT_SPAWN_AREA.y - SPAWN_MARGIN)
		)
		var data = {
			"id": piece_id,
			"lobby": lobby_number,
			"puzzle_dir": resolved_puzzle_dir,
			"position": pos,
			"group": piece_id
		}
		var node = server_piece_spawner.spawn(data)
		if node:
			node.set_multiplayer_authority(1)
			_register_piece_node(lobby_number, piece_id, node)
			piece_map[piece_id] = piece_id
		else:
			print("ERROR: MultiplayerSpawner.spawn returned null for piece ", piece_id, " lobby ", lobby_number)
	_rebuild_lobby_groups_from_piece_map(lobby_number)
	_update_visibility_for_lobby(lobby_number)
	print("NetworkManager: Spawn complete for lobby ", lobby_number, ", nodes=", lobby_piece_nodes.get(lobby_number, {}).size())

func _update_visibility_for_peer(peer_id: int) -> void:
	if not is_server:
		return
	if not client_lobby.has(peer_id):
		return
	var target_lobby: int = int(client_lobby[peer_id])
	var total := 0
	var visible := 0
	for lobby_key in lobby_piece_nodes.keys():
		var lobby_number := int(lobby_key)
		var lobby_pieces: Dictionary = lobby_piece_nodes.get(lobby_number, {})
		var should_be_visible := lobby_number == target_lobby
		for node in lobby_pieces.values():
			if node == null or not is_instance_valid(node):
				continue
			var sync = node.get_node_or_null("PieceSynchronizer")
			if sync == null:
				continue
			total += 1
			if should_be_visible:
				# Force a visibility edge for late joiners so spawns are replayed.
				sync.set_visibility_for(peer_id, false)
				sync.update_visibility(peer_id)
				sync.set_visibility_for(peer_id, true)
				sync.update_visibility(peer_id)
			else:
				sync.set_visibility_for(peer_id, false)
				sync.update_visibility(peer_id)
			if should_be_visible:
				visible += 1
	print(
		"NetworkManager: visibility update peer=", peer_id,
		" lobby=", target_lobby,
		" visible_nodes=", visible,
		" total_nodes=", total
	)

func _update_visibility_for_lobby(lobby_number: int) -> void:
	if not is_server:
		return
	var players = lobby_players.get(lobby_number, {})
	for peer_id in players.keys():
		_update_visibility_for_peer(int(peer_id))

func _resolve_group_id(lobby_number: int, piece_id: int, group_id_hint: int) -> int:
	var piece_map = _get_lobby_piece_map(lobby_number)
	if piece_map.has(piece_id):
		return int(piece_map[piece_id])
	var resolved = group_id_hint if group_id_hint >= 0 else piece_id
	piece_map[piece_id] = resolved
	return int(resolved)

func _sync_piece_groups_from_positions(lobby_number: int, group_id: int, piece_positions: Array) -> void:
	var piece_map = _get_lobby_piece_map(lobby_number)
	var piece_nodes = _get_lobby_piece_nodes(lobby_number)
	for info in piece_positions:
		var pid = info.get("id", null)
		if pid == null:
			continue
		var piece_id := int(pid)
		piece_map[piece_id] = group_id
		var node = piece_nodes.get(piece_id, null)
		if node and is_instance_valid(node):
			node.group_number = group_id

func _dedupe_piece_positions(piece_positions: Array) -> Array:
	var by_id: Dictionary = {}
	for info in piece_positions:
		if not (info is Dictionary):
			continue
		var pid := int(info.get("id", -1))
		if pid < 0:
			continue
		by_id[pid] = info
	var ids: Array = by_id.keys()
	ids.sort()
	var deduped: Array = []
	for pid in ids:
		deduped.append(by_id[pid])
	return deduped

func _get_lock_owner(lobby_number: int, group_id: int) -> int:
	var locks = _get_lobby_lock_map(lobby_number)
	if not locks.has(group_id):
		return -1
	var lock = locks[group_id]
	var now = _now_sec()
	if float(lock.get("expires_at", 0.0)) <= now:
		locks.erase(group_id)
		var groups = _get_lobby_groups(lobby_number)
		if groups.has(group_id):
			var state: Dictionary = groups[group_id]
			state["lock_owner"] = -1
			state["lock_expires_at"] = 0.0
			groups[group_id] = state
		return -1
	return int(lock.get("owner", -1))

func _try_acquire_lock(lobby_number: int, group_id: int, peer_id: int) -> bool:
	var owner = _get_lock_owner(lobby_number, group_id)
	if owner != -1 and owner != peer_id:
		return false
	var locks = _get_lobby_lock_map(lobby_number)
	var expires_at := _now_sec() + LOCK_TTL_SEC
	locks[group_id] = {"owner": peer_id, "expires_at": expires_at}
	var groups = _get_lobby_groups(lobby_number)
	if groups.has(group_id):
		var state: Dictionary = groups[group_id]
		state["lock_owner"] = peer_id
		state["lock_expires_at"] = expires_at
		groups[group_id] = state
	return true

func _refresh_lock(lobby_number: int, group_id: int, peer_id: int) -> void:
	var locks = _get_lobby_lock_map(lobby_number)
	if locks.has(group_id) and int(locks[group_id].get("owner", -1)) == peer_id:
		var expires_at := _now_sec() + LOCK_TTL_SEC
		locks[group_id].expires_at = expires_at
		var groups = _get_lobby_groups(lobby_number)
		if groups.has(group_id):
			var state: Dictionary = groups[group_id]
			state["lock_owner"] = peer_id
			state["lock_expires_at"] = expires_at
			groups[group_id] = state

func _release_lock(lobby_number: int, group_id: int, peer_id: int) -> void:
	var locks = _get_lobby_lock_map(lobby_number)
	if locks.has(group_id) and int(locks[group_id].get("owner", -1)) == peer_id:
		locks.erase(group_id)
		var groups = _get_lobby_groups(lobby_number)
		if groups.has(group_id):
			var state: Dictionary = groups[group_id]
			state["lock_owner"] = -1
			state["lock_expires_at"] = 0.0
			groups[group_id] = state

func _release_peer_locks(peer_id: int) -> void:
	var lobby = client_lobby.get(peer_id, null)
	if lobby == null:
		return
	var locks = _get_lobby_lock_map(int(lobby))
	var groups = _get_lobby_groups(int(lobby))
	var to_remove: Array = []
	for group_id in locks.keys():
		if int(locks[group_id].get("owner", -1)) == peer_id:
			to_remove.append(group_id)
	for group_id in to_remove:
		locks.erase(group_id)
		var gid := int(group_id)
		if groups.has(gid):
			var state: Dictionary = groups[gid]
			state["lock_owner"] = -1
			state["lock_expires_at"] = 0.0
			groups[gid] = state

func _reset_lobby_state(lobby_number: int) -> void:
	# Clear per-lobby lock + piece-group tracking when a new puzzle starts.
	if lobby_group_locks.has(lobby_number):
		lobby_group_locks[lobby_number] = {}
	if lobby_piece_groups.has(lobby_number):
		lobby_piece_groups[lobby_number] = {}
	if lobby_groups.has(lobby_number):
		lobby_groups.erase(lobby_number)
	if lobby_commit_seq.has(lobby_number):
		lobby_commit_seq.erase(lobby_number)
	if lobby_topology.has(lobby_number):
		lobby_topology.erase(lobby_number)
	if lobby_players.has(lobby_number):
		for pid in lobby_players[lobby_number].keys():
			peer_spawn_sync_done.erase(int(pid))
	if is_server:
		_clear_lobby_pieces(lobby_number)

func _force_release_lock(lobby_number: int, group_id: int) -> void:
	var locks: Dictionary = _get_lobby_lock_map(lobby_number)
	if locks.has(group_id):
		locks.erase(group_id)
	var groups: Dictionary = _get_lobby_groups(lobby_number)
	if groups.has(group_id):
		var state: Dictionary = groups[group_id]
		state["lock_owner"] = -1
		state["lock_expires_at"] = 0.0
		groups[group_id] = state

func _select_merge_target_group(lobby_number: int, merge_group_ids: Array) -> int:
	var groups: Dictionary = _get_lobby_groups(lobby_number)
	var best_group := -1
	var best_size := -1
	for raw_gid in merge_group_ids:
		var gid := int(raw_gid)
		var group_size := 0
		if groups.has(gid):
			group_size = Array(groups[gid].get("piece_ids", [])).size()
		if group_size > best_size:
			best_group = gid
			best_size = group_size
		elif group_size == best_size and (best_group == -1 or gid < best_group):
			best_group = gid
	return best_group

func _collect_snap_candidates(lobby_number: int, moved_group_id: int, requesting_peer_id: int) -> Array:
	var candidates: Array = []
	if not lobby_topology.has(lobby_number):
		return candidates
	var groups: Dictionary = _get_lobby_groups(lobby_number)
	if not groups.has(moved_group_id):
		return candidates
	var topology: Dictionary = lobby_topology[lobby_number]
	var adjacency_map: Dictionary = topology.get("adjacency_map", {})
	var centers: Dictionary = topology.get("reference_centers", {})
	var piece_map: Dictionary = _get_lobby_piece_map(lobby_number)
	var moved_state: Dictionary = groups[moved_group_id]
	var perimeter_piece_ids: Array = Array(moved_state.get("perimeter_piece_ids", []))
	if perimeter_piece_ids.is_empty():
		perimeter_piece_ids = Array(moved_state.get("piece_ids", []))

	for raw_moved_pid in perimeter_piece_ids:
		var moved_piece_id: int = int(raw_moved_pid)
		var moved_node: Node2D = _get_piece_node(lobby_number, moved_piece_id) as Node2D
		if moved_node == null or not is_instance_valid(moved_node):
			continue
		if not centers.has(moved_piece_id):
			continue
		var neighbors: Array = Array(adjacency_map.get(moved_piece_id, []))
		for raw_neighbor in neighbors:
			var neighbor_piece_id: int = int(raw_neighbor)
			if not centers.has(neighbor_piece_id):
				continue
			var neighbor_group_id: int = int(piece_map.get(neighbor_piece_id, neighbor_piece_id))
			if neighbor_group_id == moved_group_id:
				continue
			if not groups.has(neighbor_group_id):
				continue
			var neighbor_owner: int = _get_lock_owner(lobby_number, neighbor_group_id)
			if neighbor_owner != -1 and neighbor_owner != requesting_peer_id:
				continue
			var neighbor_node: Node2D = _get_piece_node(lobby_number, neighbor_piece_id) as Node2D
			if neighbor_node == null or not is_instance_valid(neighbor_node):
				continue
			var ref_moved: Vector2 = _vector2_from_variant(centers[moved_piece_id], Vector2.ZERO)
			var ref_neighbor: Vector2 = _vector2_from_variant(centers[neighbor_piece_id], Vector2.ZERO)
			var expected_delta: Vector2 = ref_moved - ref_neighbor
			var current_delta: Vector2 = moved_node.global_position - neighbor_node.global_position
			var snap_delta: Vector2 = expected_delta - current_delta
			var error: float = snap_delta.length()
			var threshold: float = _group_snap_threshold_for_pair(topology, moved_piece_id, neighbor_piece_id)
			if error > threshold:
				continue
			var midpoint: Vector2 = (moved_node.global_position + neighbor_node.global_position) * 0.5
			candidates.append({
				"moved_piece_id": moved_piece_id,
				"neighbor_piece_id": neighbor_piece_id,
				"neighbor_group_id": neighbor_group_id,
				"snap_delta": snap_delta,
				"error": error,
				"midpoint": midpoint
			})
	return candidates

func _pick_best_snap_candidate(candidates: Array) -> Dictionary:
	var best_candidate: Dictionary = {}
	var best_error: float = INF
	var best_neighbor_group_id: int = 2147483647
	var best_neighbor_piece_id: int = 2147483647
	for raw_candidate in candidates:
		if not (raw_candidate is Dictionary):
			continue
		var candidate: Dictionary = raw_candidate
		var error: float = float(candidate.get("error", INF))
		var neighbor_group_id: int = int(candidate.get("neighbor_group_id", 2147483647))
		var neighbor_piece_id: int = int(candidate.get("neighbor_piece_id", 2147483647))
		if error < best_error:
			best_candidate = candidate
			best_error = error
			best_neighbor_group_id = neighbor_group_id
			best_neighbor_piece_id = neighbor_piece_id
			continue
		if error == best_error:
			if neighbor_group_id < best_neighbor_group_id:
				best_candidate = candidate
				best_neighbor_group_id = neighbor_group_id
				best_neighbor_piece_id = neighbor_piece_id
				continue
			if neighbor_group_id == best_neighbor_group_id and neighbor_piece_id < best_neighbor_piece_id:
				best_candidate = candidate
				best_neighbor_piece_id = neighbor_piece_id
	return best_candidate

func _apply_group_translation(lobby_number: int, group_id: int, delta: Vector2) -> void:
	if delta == Vector2.ZERO:
		return
	var groups: Dictionary = _get_lobby_groups(lobby_number)
	if not groups.has(group_id):
		return
	var group_state: Dictionary = groups[group_id]
	var piece_ids: Array = Array(group_state.get("piece_ids", []))
	for raw_pid in piece_ids:
		var piece_id: int = int(raw_pid)
		var node: Node2D = _get_piece_node(lobby_number, piece_id) as Node2D
		if node == null or not is_instance_valid(node):
			continue
		node.global_position += delta
	var anchor_pos: Vector2 = _vector2_from_variant(group_state.get("anchor_pos", Vector2.ZERO), Vector2.ZERO)
	group_state["anchor_pos"] = anchor_pos + delta
	groups[group_id] = group_state

func _collect_consistent_merge_groups(candidates: Array, chosen_delta: Vector2, moved_group_id: int) -> Dictionary:
	var merge_groups: Dictionary = {moved_group_id: true}
	for raw_candidate in candidates:
		if not (raw_candidate is Dictionary):
			continue
		var candidate: Dictionary = raw_candidate
		var neighbor_group_id: int = int(candidate.get("neighbor_group_id", -1))
		if neighbor_group_id < 0:
			continue
		var candidate_delta: Vector2 = _vector2_from_variant(candidate.get("snap_delta", Vector2.ZERO), Vector2.ZERO)
		if candidate_delta.distance_to(chosen_delta) <= SNAP_CONSISTENCY_EPS_PX:
			merge_groups[neighbor_group_id] = true
	return merge_groups

func _dedupe_feedback_points(points: Array) -> Array:
	var deduped: Array = []
	for raw_point in points:
		var point: Vector2 = _vector2_from_variant(raw_point, Vector2.ZERO)
		var keep_point: bool = true
		for existing in deduped:
			var existing_point: Vector2 = _vector2_from_variant(existing, Vector2.ZERO)
			if point.distance_to(existing_point) <= SNAP_FEEDBACK_DEDUPE_PX:
				keep_point = false
				break
		if keep_point:
			deduped.append(point)
	return deduped

func _build_changed_pieces_payload(lobby_number: int, changed_piece_ids: Array) -> Array:
	var payload: Array = []
	var unique_ids: Dictionary = {}
	for raw_pid in changed_piece_ids:
		unique_ids[int(raw_pid)] = true
	var sorted_ids: Array = unique_ids.keys()
	sorted_ids.sort()
	var piece_map: Dictionary = _get_lobby_piece_map(lobby_number)
	for raw_pid in sorted_ids:
		var pid := int(raw_pid)
		var node: Node2D = _get_piece_node(lobby_number, pid) as Node2D
		if node == null or not is_instance_valid(node):
			continue
		payload.append({
			"id": pid,
			"position": node.global_position,
			"group": int(piece_map.get(pid, int(node.group_number)))
		})
	return payload

func _server_apply_group_drop_commit(lobby_number: int, peer_id: int, group_id: int, anchor_pos: Vector2, drag_seq: int) -> Dictionary:
	var groups: Dictionary = _get_lobby_groups(lobby_number)
	var piece_map: Dictionary = _get_lobby_piece_map(lobby_number)
	if not groups.has(group_id):
		return {}
	var moved_state: Dictionary = groups[group_id]
	var owner := _get_lock_owner(lobby_number, group_id)
	if owner != peer_id:
		return {}
	var last_drag_seq := int(moved_state.get("last_drag_seq", -1))
	if drag_seq < last_drag_seq:
		return {}
	moved_state["last_drag_seq"] = drag_seq
	groups[group_id] = moved_state

	var changed_piece_ids: Array = Array(moved_state.get("piece_ids", [])).duplicate(true)
	var anchor_piece_id := int(moved_state.get("anchor_piece_id", group_id))
	var anchor_node: Node2D = _get_piece_node(lobby_number, anchor_piece_id) as Node2D
	if anchor_node == null or not is_instance_valid(anchor_node):
		return {}
	var drag_delta: Vector2 = anchor_pos - anchor_node.global_position
	_apply_group_translation(lobby_number, group_id, drag_delta)

	var merge_group_ids: Array = [group_id]
	var best_feedback_point: Vector2 = Vector2.ZERO
	var has_best_feedback_point: bool = false
	var pre_candidates: Array = _collect_snap_candidates(lobby_number, group_id, peer_id)
	if not pre_candidates.is_empty():
		var best_candidate: Dictionary = _pick_best_snap_candidate(pre_candidates)
		if not best_candidate.is_empty():
			var chosen_delta: Vector2 = _vector2_from_variant(best_candidate.get("snap_delta", Vector2.ZERO), Vector2.ZERO)
			var consistent_pre_groups: Dictionary = _collect_consistent_merge_groups(pre_candidates, chosen_delta, group_id)
			_apply_group_translation(lobby_number, group_id, chosen_delta)
			var post_candidates: Array = _collect_snap_candidates(lobby_number, group_id, peer_id)
			var revalidated_groups: Dictionary = {group_id: true}
			var fallback_feedback_point: Vector2 = Vector2.ZERO
			var has_fallback_feedback_point: bool = false
			for raw_candidate in post_candidates:
				if not (raw_candidate is Dictionary):
					continue
				var candidate: Dictionary = raw_candidate
				var neighbor_group_id: int = int(candidate.get("neighbor_group_id", -1))
				if neighbor_group_id < 0:
					continue
				if not consistent_pre_groups.has(neighbor_group_id):
					continue
				revalidated_groups[neighbor_group_id] = true
				if not has_fallback_feedback_point:
					fallback_feedback_point = _vector2_from_variant(candidate.get("midpoint", Vector2.ZERO), Vector2.ZERO)
					has_fallback_feedback_point = true
			merge_group_ids = revalidated_groups.keys()
			merge_group_ids.sort()
			if has_fallback_feedback_point:
				best_feedback_point = fallback_feedback_point
				has_best_feedback_point = true

	if merge_group_ids.is_empty():
		merge_group_ids = [group_id]

	var safe_merge_group_ids: Array = []
	for raw_gid in merge_group_ids:
		var gid: int = int(raw_gid)
		if gid == group_id:
			safe_merge_group_ids.append(gid)
			continue
		var merge_owner: int = _get_lock_owner(lobby_number, gid)
		if merge_owner == -1 or merge_owner == peer_id:
			safe_merge_group_ids.append(gid)
	if not safe_merge_group_ids.has(group_id):
		safe_merge_group_ids.append(group_id)
	safe_merge_group_ids.sort()
	merge_group_ids = safe_merge_group_ids

	var released_group_id := group_id
	if merge_group_ids.size() > 1:
		var target_group_id := _select_merge_target_group(lobby_number, merge_group_ids)
		if target_group_id < 0:
			return {}
		for raw_gid in merge_group_ids:
			var gid := int(raw_gid)
			if not groups.has(gid):
				continue
			var state: Dictionary = groups[gid]
			for raw_pid in Array(state.get("piece_ids", [])):
				var pid := int(raw_pid)
				piece_map[pid] = target_group_id
				var node: Node2D = _get_piece_node(lobby_number, pid) as Node2D
				if node and is_instance_valid(node):
					node.group_number = target_group_id
				changed_piece_ids.append(pid)
			if gid != target_group_id:
				_force_release_lock(lobby_number, gid)
	else:
		# No merge happened; keep authoritative mapping but still include moved pieces.
		for raw_pid in Array(moved_state.get("piece_ids", [])):
			var pid := int(raw_pid)
			piece_map[pid] = group_id

	_rebuild_lobby_groups_from_piece_map(lobby_number)
	_force_release_lock(lobby_number, released_group_id)

	var feedback_points: Array = []
	if merge_group_ids.size() > 1 and has_best_feedback_point:
		feedback_points = [best_feedback_point]

	return {
		"changed_pieces": _build_changed_pieces_payload(lobby_number, changed_piece_ids),
		"changed_groups": _serialize_all_lobby_groups(lobby_number),
		"released_group_id": released_group_id,
		"snap_feedback_points": feedback_points
	}

##=============
## RPC Methods
##=============
@rpc("any_peer", "call_remote", "reliable")
func _receive_chat_message(sender_name: String, message: String):
	if not is_online: return
	if is_server:
		# Re-broadcast to all clients except sender
		var from_id: int = multiplayer.get_remote_sender_id()
		var lobby = client_lobby.get(from_id)
		for pid in lobby_players.get(lobby, {}).keys():
			if pid != from_id:
				rpc_id(pid, "_receive_chat_message", sender_name, message)
	else: 
		chat_message_received.emit(sender_name, message)

# One-time handshake: client tells server name and lobby ONCE
@rpc("any_peer", "call_remote", "reliable")
func hello(player_name: String, lobby_number: int, puzzle_id_from_client: String):
	if not is_server:
		return
	var id: int = multiplayer.get_remote_sender_id()
	client_lobby[id] = lobby_number

	var incoming_puzzle_id := str(puzzle_id_from_client).strip_edges()
	var prev_puzzle_id := str(lobby_puzzle.get(lobby_number, "")).strip_edges()
	var lobby_peers: Dictionary = lobby_players.get(lobby_number, {})
	var lobby_has_players: bool = not lobby_peers.is_empty()
	if prev_puzzle_id == "":
		if incoming_puzzle_id != "":
			lobby_puzzle[lobby_number] = incoming_puzzle_id
			prev_puzzle_id = incoming_puzzle_id
	elif incoming_puzzle_id != "" and incoming_puzzle_id != prev_puzzle_id:
		# Keep lobby puzzle authoritative while players are already in the lobby.
		if lobby_has_players:
			print(
				"NetworkManager: Ignoring mismatched client puzzle for lobby ",
				lobby_number,
				" peer=", id,
				" incoming=", incoming_puzzle_id,
				" existing=", prev_puzzle_id
			)
		else:
			lobby_puzzle[lobby_number] = incoming_puzzle_id
			_reset_lobby_state(lobby_number)
			prev_puzzle_id = incoming_puzzle_id

	if not lobby_players.has(lobby_number):
		lobby_players[lobby_number] = {}
	lobby_players[lobby_number][id] = player_name

	connected_players[id] = player_name

	var puzzle_id := str(lobby_puzzle.get(lobby_number, current_puzzle_id)).strip_edges()
	if puzzle_id != "":
		rpc_id(id, "_send_puzzle_info", puzzle_id)
	# Do not spawn in hello; the client may still be in menu and miss spawns.
	_update_visibility_for_peer(id)
	# Ensure first joiner always gets a lobby snapshot even if scene-ready timing races.
	call_deferred("_bootstrap_peer_lobby_state", id, lobby_number, puzzle_id)

	for pid in lobby_players[lobby_number].keys():
		rpc_id(pid, "_update_player_list", lobby_players[lobby_number])

	player_joined.emit(id, player_name)

@rpc("any_peer", "call_remote", "reliable")
func client_scene_ready(lobby_number: int):
	if not is_server:
		return
	var from_id: int = multiplayer.get_remote_sender_id()
	if not client_lobby.has(from_id):
		if lobby_number < 0:
			return
		client_lobby[from_id] = lobby_number
	var resolved_lobby: int = int(client_lobby[from_id])
	var puzzle_value = lobby_puzzle.get(resolved_lobby, current_puzzle_id)
	if puzzle_value == null:
		return
	var puzzle_id := str(puzzle_value)
	if puzzle_id == "":
		print("ERROR: client_scene_ready has empty puzzle_id for peer ", from_id, " lobby ", resolved_lobby)
		return
	var sync_key := str(resolved_lobby) + "|" + puzzle_id
	if peer_spawn_sync_done.get(from_id, "") == sync_key:
		await _ensure_lobby_pieces_spawned(resolved_lobby, puzzle_id)
		_update_visibility_for_peer(from_id)
		# Re-send snapshot for idempotent healing if the previous delivery was missed.
		_send_lobby_snapshot_to_peer(from_id, resolved_lobby, puzzle_id)
		return
	print("NetworkManager: client_scene_ready peer=", from_id, " lobby=", resolved_lobby, " puzzle=", puzzle_id)
	await _ensure_lobby_pieces_spawned(resolved_lobby, puzzle_id)
	peer_spawn_sync_done[from_id] = sync_key
	_update_visibility_for_peer(from_id)
	_send_lobby_snapshot_to_peer(from_id, resolved_lobby, puzzle_id)

@rpc("authority", "call_remote", "reliable")
func _receive_lobby_snapshot(lobby_number: int, puzzle_dir: String, snapshot: Array):
	if is_server:
		return
	var local_lobby := -1
	if PuzzleVar.lobby_number != null:
		local_lobby = int(PuzzleVar.lobby_number)
	if local_lobby >= 0 and local_lobby != int(lobby_number):
		return
	print(
		"NetworkManager (Client): Received lobby snapshot lobby=", lobby_number,
		" pieces=", snapshot.size()
	)
	_queue_lobby_snapshot(int(lobby_number), puzzle_dir, snapshot)
	var tree = get_tree()
	if tree == null:
		return
	var scene = tree.current_scene
	if scene and scene.has_method("_apply_network_snapshot"):
		scene.call_deferred("_apply_network_snapshot", puzzle_dir, snapshot)
		pending_lobby_snapshots.erase(int(lobby_number))
	else:
		call_deferred("_try_apply_pending_lobby_snapshot", int(lobby_number))

@rpc("any_peer", "call_remote", "reliable")
func request_group_lock_v2(group_id: int):
	if not is_server or not use_group_parent_sync:
		return
	var from_id: int = multiplayer.get_remote_sender_id()
	if not client_lobby.has(from_id):
		return
	var lobby: int = int(client_lobby[from_id])
	var resolved_group_id := int(group_id)
	var groups: Dictionary = _get_lobby_groups(lobby)
	if not groups.has(resolved_group_id):
		var piece_map: Dictionary = _get_lobby_piece_map(lobby)
		if piece_map.has(resolved_group_id):
			resolved_group_id = int(piece_map[resolved_group_id])
	if not groups.has(resolved_group_id):
		rpc_id(from_id, "_group_lock_denied_v2", resolved_group_id, -1)
		return
	if not _try_acquire_lock(lobby, resolved_group_id, from_id):
		var owner := _get_lock_owner(lobby, resolved_group_id)
		rpc_id(from_id, "_group_lock_denied_v2", resolved_group_id, owner)
		return
	rpc_id(from_id, "_group_lock_granted_v2", resolved_group_id)

@rpc("any_peer", "call_remote", "reliable")
func release_group_lock_v2(group_id: int):
	if not is_server or not use_group_parent_sync:
		return
	var from_id: int = multiplayer.get_remote_sender_id()
	if not client_lobby.has(from_id):
		return
	var lobby: int = int(client_lobby[from_id])
	var resolved_group_id := int(group_id)
	var groups: Dictionary = _get_lobby_groups(lobby)
	if not groups.has(resolved_group_id):
		var piece_map: Dictionary = _get_lobby_piece_map(lobby)
		if piece_map.has(resolved_group_id):
			resolved_group_id = int(piece_map[resolved_group_id])
	_release_lock(lobby, resolved_group_id, from_id)

@rpc("any_peer", "call_remote", "reliable")
func refresh_group_lock_v2(group_id: int):
	if not is_server or not use_group_parent_sync:
		return
	var from_id: int = multiplayer.get_remote_sender_id()
	if not client_lobby.has(from_id):
		return
	var lobby: int = int(client_lobby[from_id])
	var resolved_group_id := int(group_id)
	var groups: Dictionary = _get_lobby_groups(lobby)
	if not groups.has(resolved_group_id):
		var piece_map: Dictionary = _get_lobby_piece_map(lobby)
		if piece_map.has(resolved_group_id):
			resolved_group_id = int(piece_map[resolved_group_id])
	_refresh_lock(lobby, resolved_group_id, from_id)

@rpc("any_peer", "call_remote", "reliable")
func commit_group_drop(group_id: int, anchor_pos: Vector2, drag_seq: int):
	if not is_server or not use_group_parent_sync:
		return
	var from_id: int = multiplayer.get_remote_sender_id()
	if not client_lobby.has(from_id):
		return
	var lobby: int = int(client_lobby[from_id])
	var resolved_group_id := int(group_id)
	var groups: Dictionary = _get_lobby_groups(lobby)
	if not groups.has(resolved_group_id):
		var piece_map: Dictionary = _get_lobby_piece_map(lobby)
		if piece_map.has(resolved_group_id):
			resolved_group_id = int(piece_map[resolved_group_id])
	if not groups.has(resolved_group_id):
		rpc_id(from_id, "_group_lock_denied_v2", resolved_group_id, -1)
		return
	var lock_owner := _get_lock_owner(lobby, resolved_group_id)
	if lock_owner != from_id:
		rpc_id(from_id, "_group_lock_denied_v2", resolved_group_id, lock_owner)
		return
	var commit_payload: Dictionary = _server_apply_group_drop_commit(
		lobby,
		from_id,
		resolved_group_id,
		anchor_pos,
		int(drag_seq)
	)
	if commit_payload.is_empty():
		if lock_owner == from_id:
			_force_release_lock(lobby, resolved_group_id)
		rpc_id(from_id, "_group_lock_denied_v2", resolved_group_id, lock_owner)
		return
	var commit_id := _next_lobby_commit_id(lobby)
	var changed_pieces: Array = Array(commit_payload.get("changed_pieces", []))
	var changed_groups: Array = Array(commit_payload.get("changed_groups", []))
	var released_group_id := int(commit_payload.get("released_group_id", resolved_group_id))
	var snap_feedback_points: Array = Array(commit_payload.get("snap_feedback_points", []))
	for pid in lobby_players.get(lobby, {}).keys():
		rpc_id(int(pid), "_apply_group_commit", commit_id, changed_pieces, changed_groups, released_group_id)
	if not snap_feedback_points.is_empty():
		rpc_id(from_id, "_group_snap_feedback", snap_feedback_points)

@rpc("any_peer", "call_remote", "reliable")
func request_grid_arrange_v2(lobby_number: int, arranged_positions: Array):
	if not is_server or not use_group_parent_sync or use_legacy_piece_flow:
		return
	var from_id: int = multiplayer.get_remote_sender_id()
	var resolved_lobby: int = int(lobby_number)
	if from_id > 0:
		if not client_lobby.has(from_id):
			return
		resolved_lobby = int(client_lobby[from_id])
	if resolved_lobby < 0:
		return
	var piece_map: Dictionary = _get_lobby_piece_map(resolved_lobby)
	var changed_piece_ids: Array = []
	for raw_entry in arranged_positions:
		if not (raw_entry is Dictionary):
			continue
		var entry: Dictionary = raw_entry
		var piece_id: int = int(entry.get("id", -1))
		if piece_id < 0:
			continue
		var node: Node2D = _get_piece_node(resolved_lobby, piece_id) as Node2D
		if node == null or not is_instance_valid(node):
			continue
		var next_pos: Vector2 = _vector2_from_variant(entry.get("position", node.global_position), node.global_position)
		node.global_position = next_pos
		if piece_map.has(piece_id):
			node.group_number = int(piece_map[piece_id])
		changed_piece_ids.append(piece_id)
	if changed_piece_ids.is_empty():
		return
	var lock_map: Dictionary = _get_lobby_lock_map(resolved_lobby)
	lock_map.clear()
	_rebuild_lobby_groups_from_piece_map(resolved_lobby)
	var commit_id: int = _next_lobby_commit_id(resolved_lobby)
	var changed_pieces: Array = _build_changed_pieces_payload(resolved_lobby, changed_piece_ids)
	var changed_groups: Array = _serialize_all_lobby_groups(resolved_lobby)
	for raw_pid in lobby_players.get(resolved_lobby, {}).keys():
		var peer_id: int = int(raw_pid)
		rpc_id(peer_id, "_apply_group_commit", commit_id, changed_pieces, changed_groups, -1)

@rpc("authority", "call_remote", "reliable")
func _group_lock_granted_v2(group_id: int):
	if is_server:
		return
	group_lock_granted_v2.emit(group_id)

@rpc("authority", "call_remote", "reliable")
func _group_lock_denied_v2(group_id: int, owner_id: int):
	if is_server:
		return
	group_lock_denied_v2.emit(group_id, owner_id)

@rpc("authority", "call_remote", "reliable")
func _apply_group_commit(commit_id: int, changed_pieces: Array, changed_groups: Array, released_group_id: int):
	if is_server:
		return
	group_commit_applied.emit(commit_id, changed_pieces, changed_groups, released_group_id)

@rpc("authority", "call_remote", "reliable")
func _group_snap_feedback(points: Array):
	if is_server:
		return
	group_snap_feedback.emit(points)

# Client -> server: request lock on a group (by piece id + hint)
@rpc("any_peer", "call_remote", "reliable")
func request_group_lock(piece_id: int, group_id_hint: int = -1):
	if use_group_parent_sync and not use_legacy_piece_flow:
		return
	if not is_server:
		return
	var from_id: int = multiplayer.get_remote_sender_id()
	if not client_lobby.has(from_id):
		return
	var lobby: int = int(client_lobby[from_id])
	var group_id := _resolve_group_id(lobby, piece_id, group_id_hint)
	if _try_acquire_lock(lobby, group_id, from_id):
		rpc_id(from_id, "_lock_granted", piece_id, group_id)
	else:
		var owner := _get_lock_owner(lobby, group_id)
		rpc_id(from_id, "_lock_denied", piece_id, group_id, owner)

# Client -> server: release lock on a group (by piece id + hint)
@rpc("any_peer", "call_remote", "reliable")
func release_group_lock(piece_id: int, group_id_hint: int = -1):
	if use_group_parent_sync and not use_legacy_piece_flow:
		return
	if not is_server:
		return
	var from_id: int = multiplayer.get_remote_sender_id()
	if not client_lobby.has(from_id):
		return
	var lobby: int = int(client_lobby[from_id])
	var group_id := _resolve_group_id(lobby, piece_id, group_id_hint)
	_release_lock(lobby, group_id, from_id)

# Client -> server: refresh an existing lock (keepalive)
@rpc("any_peer", "call_remote", "reliable")
func refresh_group_lock(piece_id: int, group_id_hint: int = -1):
	if use_group_parent_sync and not use_legacy_piece_flow:
		return
	if not is_server:
		return
	var from_id: int = multiplayer.get_remote_sender_id()
	if not client_lobby.has(from_id):
		return
	var lobby: int = int(client_lobby[from_id])
	var group_id := _resolve_group_id(lobby, piece_id, group_id_hint)
	_refresh_lock(lobby, group_id, from_id)

# Client -> server: query lock owner for a piece/group
@rpc("any_peer", "call_remote", "reliable")
func request_lock_status(piece_id: int, group_id_hint: int = -1):
	if use_group_parent_sync and not use_legacy_piece_flow:
		return
	if not is_server:
		return
	var from_id: int = multiplayer.get_remote_sender_id()
	if not client_lobby.has(from_id):
		return
	var lobby: int = int(client_lobby[from_id])
	var group_id := _resolve_group_id(lobby, piece_id, group_id_hint)
	var owner := _get_lock_owner(lobby, group_id)
	rpc_id(from_id, "_lock_status", piece_id, group_id, owner)

# Server -> client: lock granted
@rpc("authority", "call_remote", "reliable")
func _lock_granted(piece_id: int, group_id: int):
	if is_server:
		return
	lock_granted.emit(piece_id, group_id)

# Server -> client: lock denied
@rpc("authority", "call_remote", "reliable")
func _lock_denied(piece_id: int, group_id: int, owner_id: int):
	if is_server:
		return
	lock_denied.emit(piece_id, group_id, owner_id)

# Server -> client: lock status response
@rpc("authority", "call_remote", "reliable")
func _lock_status(piece_id: int, group_id: int, owner_id: int):
	if is_server:
		return
	lock_status.emit(piece_id, group_id, owner_id)

# Send piece connection info FROM client -> server -> other clients (scoped to lobby)
@rpc("any_peer", "call_remote", "reliable")
func sync_connected_pieces(piece_id: int, connected_piece_id: int, source_group_id: int, target_group_id: int, new_group_number: int, piece_positions: Array):
	if use_group_parent_sync and not use_legacy_piece_flow:
		return
	if not is_online: return
	if is_server:
		var from_id: int = multiplayer.get_remote_sender_id()
		if not client_lobby.has(from_id):
			return
		var lobby: int = int(client_lobby[from_id])
		var resolved_source := _resolve_group_id(lobby, piece_id, source_group_id)
		var resolved_target := _resolve_group_id(lobby, connected_piece_id, target_group_id)
		if resolved_source == resolved_target:
			return
		var owner := _get_lock_owner(lobby, resolved_source)
		if owner != from_id:
			return
		var target_owner := _get_lock_owner(lobby, resolved_target)
		if target_owner != -1 and target_owner != from_id:
			return
		var final_group := new_group_number
		if final_group != resolved_source and final_group != resolved_target:
			final_group = resolved_source
		var normalized_positions := _dedupe_piece_positions(piece_positions)
		if normalized_positions.is_empty():
			return
		_sync_piece_groups_from_positions(lobby, final_group, normalized_positions)
		if final_group == resolved_source:
			_refresh_lock(lobby, final_group, from_id)
			_release_lock(lobby, resolved_target, from_id)
		else:
			_release_lock(lobby, resolved_source, from_id)
			_try_acquire_lock(lobby, final_group, from_id)
		var pieces = lobby_piece_nodes.get(lobby, {})
		for info in normalized_positions:
			var pid = int(info.get("id", -1))
			if pid < 0:
				continue
			var node = pieces.get(pid, null)
			if node:
				node.group_number = final_group
				if info.has("position"):
					node.position = info.get("position", node.position)
		for pid in lobby_players.get(lobby, {}).keys():
			rpc_id(pid, "_receive_piece_connection", piece_id, connected_piece_id, final_group, normalized_positions)
	else:
		# clients call this on the server; server re-broadcasts
		pass

# Server -> clients: apply remote connection
@rpc("authority", "call_remote", "reliable")
func _receive_piece_connection(piece_id: int, connected_piece_id: int, new_group_number: int, piece_positions: Array):
	if use_group_parent_sync and not use_legacy_piece_flow:
		return
	if not is_online: return
	print("RPC::_receive_piece_connection")
	pieces_connected.emit(piece_id, connected_piece_id, new_group_number, piece_positions)

# Client -> server -> clients: moved pieces (scoped to lobby)
@rpc("any_peer", "call_remote", "reliable")
func _receive_piece_move(group_id: int, piece_positions: Array):
	if use_group_parent_sync and not use_legacy_piece_flow:
		return
	if not is_online: return
	if is_server:
		var from_id: int = multiplayer.get_remote_sender_id()
		if not client_lobby.has(from_id): return
		var lobby: int = int(client_lobby[from_id])
		var normalized_positions := _dedupe_piece_positions(piece_positions)
		if normalized_positions.is_empty():
			return
		var resolved_group := group_id
		if resolved_group < 0 and normalized_positions.size() > 0:
			var first_id = normalized_positions[0].get("id", -1)
			if first_id >= 0:
				resolved_group = _resolve_group_id(lobby, int(first_id), -1)
		if resolved_group < 0:
			return
		var owner := _get_lock_owner(lobby, resolved_group)
		if owner != from_id:
			return
		_sync_piece_groups_from_positions(lobby, resolved_group, normalized_positions)
		_refresh_lock(lobby, resolved_group, from_id)
		var pieces = lobby_piece_nodes.get(lobby, {})
		for info in normalized_positions:
			var pid = int(info.get("id", -1))
			if pid < 0:
				continue
			var node = pieces.get(pid, null)
			if node and info.has("position"):
				node.position = info.get("position", node.position)
		for pid in lobby_players.get(lobby, {}).keys():
			if pid != from_id:
				rpc_id(pid, "_receive_piece_move_client", normalized_positions)
	else:
		# clients shouldn't call this locally
		pass

# Server -> clients: apply moved pieces
@rpc("authority", "call_remote", "reliable")
func _receive_piece_move_client(piece_positions: Array):
	if use_group_parent_sync and not use_legacy_piece_flow:
		return
	if not is_online: return
	pieces_moved.emit(piece_positions)

@rpc("any_peer", "call_remote", "reliable")
func apply_lobby_state(lobby_number: int, state: Array):
	if not is_server:
		return
	var requester_id: int = multiplayer.get_remote_sender_id()
	var puzzle_dir: String = lobby_puzzle.get(lobby_number, "")
	if puzzle_dir == "":
		return
	await _ensure_lobby_pieces_spawned(lobby_number, puzzle_dir)
	puzzle_dir = str(lobby_puzzle.get(lobby_number, puzzle_dir))
	_ensure_lobby_topology(lobby_number, puzzle_dir)
	if lobby_state_loaded.get(lobby_number, false):
		# Lobby state already applied on server: still ACK requester and send current snapshot.
		if requester_id > 0:
			_send_lobby_snapshot_to_peer(requester_id, lobby_number, puzzle_dir)
			rpc_id(requester_id, "_lobby_state_applied", lobby_number)
		return
	var pieces = lobby_piece_nodes.get(lobby_number, {})
	var piece_map = _get_lobby_piece_map(lobby_number)
	for entry in state:
		if not (entry is Dictionary):
			continue
		var pid = int(entry.get("ID", -1))
		if pid < 0:
			continue
		var group_id = int(entry.get("GroupID", pid))
		piece_map[pid] = group_id
		var node = pieces.get(pid, null)
		if node:
			node.group_number = group_id
			var center = entry.get("CenterLocation", {})
			if center is Dictionary and center.has("x") and center.has("y"):
				node.position = Vector2(float(center["x"]), float(center["y"]))
	_rebuild_lobby_groups_from_piece_map(lobby_number)
	lobby_state_loaded[lobby_number] = true
	for pid in lobby_players.get(lobby_number, {}).keys():
		var peer_id := int(pid)
		_send_lobby_snapshot_to_peer(peer_id, lobby_number, puzzle_dir)
		rpc_id(peer_id, "_lobby_state_applied", lobby_number)

@rpc("authority", "call_remote", "reliable")
func _lobby_state_applied(lobby_number: int):
	if is_server:
		return
	lobby_state_applied.emit(lobby_number)

@rpc("authority", "call_remote", "reliable")
func _update_player_list(players: Dictionary):
	players.erase(multiplayer.get_unique_id()) # Remove self from list
	connected_players = players
	print("NetworkManager: Updated player list: ", connected_players)
	player_joined.emit(-1, "") # Dummy emit to signal update

@rpc("authority", "call_remote", "unreliable_ordered")
func _send_puzzle_info(puzzle_id: String):
	current_puzzle_id = puzzle_id
	print("NetworkManager (Client): Received puzzle ID '", puzzle_id, "'")
	puzzle_info_received.emit(puzzle_id) # Emit signal for main_menu

@rpc("any_peer", "call_remote", "reliable")
func request_kick_lobby_clients():
	if not is_server:
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	var lobby_value = client_lobby.get(sender_id, null)
	if lobby_value == null:
		return
	var lobby: int = int(lobby_value)
	var peers: Array = lobby_players.get(lobby, {}).keys()
	var has_other_peers: bool = false
	for pid in peers:
		if int(pid) != sender_id:
			has_other_peers = true
			break
	if not has_other_peers:
		# Nothing to kick; avoid resetting pieces for a solo host join.
		return
	_reset_lobby_state(lobby)
	for pid in peers:
		var peer_id := int(pid)
		if peer_id == sender_id:
			continue
		rpc_id(peer_id, "_kick_for_new_puzzle")
		if multiplayer.multiplayer_peer:
			multiplayer.multiplayer_peer.disconnect_peer(peer_id)
	# Re-sync the sender immediately after reset so they do not sit on a blank board.
	var puzzle_dir := str(lobby_puzzle.get(lobby, current_puzzle_id)).strip_edges()
	if puzzle_dir != "":
		await _ensure_lobby_pieces_spawned(lobby, puzzle_dir)
		_update_visibility_for_peer(sender_id)
		_send_lobby_snapshot_to_peer(sender_id, lobby, puzzle_dir)

@rpc("authority", "call_remote", "reliable")
func _kick_for_new_puzzle():
	if is_server:
		return
	kicked_for_new_puzzle = true
	PuzzleVar.auto_rejoin_online = true

##==============================
## Multiplayer Callback Methods
##==============================

func _on_peer_connected(id):
	if not is_online: return # Ignore if not in an online session
	print("NetworkManager: Peer connected: ", id)
	if is_server:
		# Wait for hello() so puzzle_id is resolved per lobby instead of global fallback.
		pass

func _on_peer_disconnected(id):
	if not is_online: return # Ignore if not in an online session
	print("NetworkManager: Peer disconnected: ", id)
	if is_server:
		var lobby: int = int(client_lobby[id]) if client_lobby.has(id) else -1
		var player_name := ""
		if lobby != -1 and lobby_players.has(lobby) and lobby_players[lobby].has(id):
			player_name = str(lobby_players[lobby][id])
			lobby_players[lobby].erase(id)
			# update that lobby’s player list
			var peers: Array = lobby_players[lobby].keys() if lobby_players.has(lobby) else Array()
			for pid in peers:
				rpc_id(pid, "_update_player_list", lobby_players[lobby])
			if lobby_players[lobby].is_empty():
				_reset_lobby_state(lobby)
		connected_players.erase(id)
		_release_peer_locks(id)
		client_lobby.erase(id)
		peer_spawn_sync_done.erase(id)
		player_left.emit(id, player_name)

func _on_connected_to_server():
	if not is_online: return # Should only happen when joining online
	print("NetworkManager: Successfully connected to server (callback)")
	# is_online should already be true from join_server initiation
	client_connected.emit() # Signal UI etc

	var nickname := ""
	if FireAuth:
		nickname = str(FireAuth.get_nickname()).strip_edges()
	if nickname == "":
		nickname = "Player_" + str(multiplayer.get_unique_id())

	var puzzle_id := ""
	if PuzzleVar.choice is Dictionary and PuzzleVar.choice.has("base_file_path") and PuzzleVar.choice.has("size"):
		puzzle_id = str(PuzzleVar.choice["base_file_path"]) + "_" + str(PuzzleVar.choice["size"])
	elif PuzzleVar.selected_puzzle_dir != null and str(PuzzleVar.selected_puzzle_dir) != "":
		puzzle_id = str(PuzzleVar.selected_puzzle_dir)
	elif current_puzzle_id != "":
		puzzle_id = current_puzzle_id

	print("NetworkManager: Sending hello for '", nickname, "' lobby=", PuzzleVar.lobby_number, " puzzle='", puzzle_id, "'")
	rpc_id(1, "hello", nickname, PuzzleVar.lobby_number, puzzle_id)

func _on_connection_failed():
	print("WARNING::NetworkManager: Connection failed")
	disconnect_from_server()

func _on_server_disconnected():
	print("NetworkManager: Server disconnected (callback)")
	var was_kicked := kicked_for_new_puzzle
	kicked_for_new_puzzle = false
	disconnect_from_server()
	if was_kicked and not is_server:
		print("NetworkManager: Returning to menu to rejoin with new puzzle")
		if PuzzleVar:
			PuzzleVar.is_online_selector = false
			PuzzleVar.auto_rejoin_online = true
		var tree = get_tree()
		if tree and tree.current_scene:
			var target_path = "res://assets/scenes/new_menu.tscn"
			if tree.current_scene.scene_file_path != target_path:
				tree.change_scene_to_file(target_path)
