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

# --- server-side lobby maps (server only) ---
var client_lobby: Dictionary = {}        # { peer_id: lobby_number }
var lobby_players: Dictionary = {}       # { lobby_number: { peer_id: player_name } }
var lobby_puzzle: Dictionary = {}        # { lobby_number: puzzle_id }  # optional; falls back to current_puzzle_id
var lobby_group_locks: Dictionary = {}   # { lobby_number: { group_id: { owner, expires_at } } }
var lobby_piece_groups: Dictionary = {}  # { lobby_number: { piece_id: group_id } }

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

func _resolve_group_id(lobby_number: int, piece_id: int, group_id_hint: int) -> int:
	var piece_map = _get_lobby_piece_map(lobby_number)
	if piece_map.has(piece_id):
		return int(piece_map[piece_id])
	var resolved = group_id_hint if group_id_hint >= 0 else piece_id
	piece_map[piece_id] = resolved
	return int(resolved)

func _sync_piece_groups_from_positions(lobby_number: int, group_id: int, piece_positions: Array) -> void:
	var piece_map = _get_lobby_piece_map(lobby_number)
	for info in piece_positions:
		var pid = info.get("id", null)
		if pid == null:
			continue
		piece_map[int(pid)] = group_id

func _get_lock_owner(lobby_number: int, group_id: int) -> int:
	var locks = _get_lobby_lock_map(lobby_number)
	if not locks.has(group_id):
		return -1
	var lock = locks[group_id]
	var now = _now_sec()
	if float(lock.get("expires_at", 0.0)) <= now:
		locks.erase(group_id)
		return -1
	return int(lock.get("owner", -1))

func _try_acquire_lock(lobby_number: int, group_id: int, peer_id: int) -> bool:
	var owner = _get_lock_owner(lobby_number, group_id)
	if owner != -1 and owner != peer_id:
		return false
	var locks = _get_lobby_lock_map(lobby_number)
	locks[group_id] = {"owner": peer_id, "expires_at": _now_sec() + LOCK_TTL_SEC}
	return true

func _refresh_lock(lobby_number: int, group_id: int, peer_id: int) -> void:
	var locks = _get_lobby_lock_map(lobby_number)
	if locks.has(group_id) and int(locks[group_id].get("owner", -1)) == peer_id:
		locks[group_id].expires_at = _now_sec() + LOCK_TTL_SEC

func _release_lock(lobby_number: int, group_id: int, peer_id: int) -> void:
	var locks = _get_lobby_lock_map(lobby_number)
	if locks.has(group_id) and int(locks[group_id].get("owner", -1)) == peer_id:
		locks.erase(group_id)

func _release_peer_locks(peer_id: int) -> void:
	var lobby = client_lobby.get(peer_id, null)
	if lobby == null:
		return
	var locks = _get_lobby_lock_map(int(lobby))
	var to_remove: Array = []
	for group_id in locks.keys():
		if int(locks[group_id].get("owner", -1)) == peer_id:
			to_remove.append(group_id)
	for group_id in to_remove:
		locks.erase(group_id)

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
func hello(player_name: String, lobby_number: int):
	if not is_server:
		return
	var id: int = multiplayer.get_remote_sender_id()
	client_lobby[id] = lobby_number

	if not lobby_players.has(lobby_number):
		lobby_players[lobby_number] = {}
	lobby_players[lobby_number][id] = player_name

	connected_players[id] = player_name

	var puzzle_id: String = lobby_puzzle.get(lobby_number, current_puzzle_id)
	if puzzle_id != null:
		rpc_id(id, "_send_puzzle_info", puzzle_id)

	for pid in lobby_players[lobby_number].keys():
		rpc_id(pid, "_update_player_list", lobby_players[lobby_number])

	player_joined.emit(id, player_name)

# Client -> server: request lock on a group (by piece id + hint)
@rpc("any_peer", "call_remote", "reliable")
func request_group_lock(piece_id: int, group_id_hint: int = -1):
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
		_sync_piece_groups_from_positions(lobby, final_group, piece_positions)
		if final_group == resolved_source:
			_refresh_lock(lobby, final_group, from_id)
			_release_lock(lobby, resolved_target, from_id)
		else:
			_release_lock(lobby, resolved_source, from_id)
			_try_acquire_lock(lobby, final_group, from_id)
		for pid in lobby_players.get(lobby, {}).keys():
			rpc_id(pid, "_receive_piece_connection", piece_id, connected_piece_id, final_group, piece_positions)
	else:
		# clients call this on the server; server re-broadcasts
		pass

# Server -> clients: apply remote connection
@rpc("authority", "call_remote", "reliable")
func _receive_piece_connection(piece_id: int, connected_piece_id: int, new_group_number: int, piece_positions: Array):
	if not is_online: return
	print("RPC::_receive_piece_connection")
	pieces_connected.emit(piece_id, connected_piece_id, new_group_number, piece_positions)

# Client -> server -> clients: moved pieces (scoped to lobby)
@rpc("any_peer", "call_remote", "reliable")
func _receive_piece_move(group_id: int, piece_positions: Array):
	if not is_online: return
	if is_server:
		var from_id: int = multiplayer.get_remote_sender_id()
		if not client_lobby.has(from_id): return
		var lobby: int = int(client_lobby[from_id])
		var resolved_group := group_id
		if resolved_group < 0 and piece_positions.size() > 0:
			var first_id = piece_positions[0].get("id", -1)
			if first_id >= 0:
				resolved_group = _resolve_group_id(lobby, int(first_id), -1)
		if resolved_group < 0:
			return
		var owner := _get_lock_owner(lobby, resolved_group)
		if owner != from_id:
			return
		_sync_piece_groups_from_positions(lobby, resolved_group, piece_positions)
		_refresh_lock(lobby, resolved_group, from_id)
		for pid in lobby_players.get(lobby, {}).keys():
			if pid != from_id:
				rpc_id(pid, "_receive_piece_move_client", piece_positions)
	else:
		# clients shouldn't call this locally
		pass

# Server -> clients: apply moved pieces
@rpc("authority", "call_remote", "reliable")
func _receive_piece_move_client(piece_positions: Array):
	if not is_online: return
	pieces_moved.emit(piece_positions)

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
	var lobby = client_lobby.get(sender_id, null)
	if lobby == null:
		return
	var peers: Array = lobby_players.get(lobby, {}).keys()
	for pid in peers:
		if pid == sender_id:
			continue
		rpc_id(pid, "_kick_for_new_puzzle")
		if multiplayer.multiplayer_peer:
			multiplayer.multiplayer_peer.disconnect_peer(pid)

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
	if is_server: # If we're the ONLINE server
		if current_puzzle_id:
			print("NetworkManager (Server): Sending puzzle info '", current_puzzle_id, "' to peer ", id)
			rpc_id(id, "_send_puzzle_info", current_puzzle_id)
		else:
			printerr("ERROR::NetworkManager (Server): Cannot send puzzle info, current_puzzle_id is null!")

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
		connected_players.erase(id)
		_release_peer_locks(id)
		client_lobby.erase(id)
		player_left.emit(id, player_name)

func _on_connected_to_server():
	if not is_online: return # Should only happen when joining online
	print("NetworkManager: Successfully connected to server (callback)")
	# is_online should already be true from join_server initiation
	client_connected.emit() # Signal UI etc
	
	if FireAuth.is_online and FireAuth.get_nickname() != "":
		print("NetworkManager: Sending hello for '", FireAuth.get_nickname(), "'")
		rpc_id(1, "hello", FireAuth.get_nickname(), PuzzleVar.lobby_number)
	else:
		print("ERROR::NetworkManager: Unable to register player, FireAuth is offline or box ID invalid")

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
