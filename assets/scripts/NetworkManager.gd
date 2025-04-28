extends Node

# NetworkManager.gd - Handles all multiplayer functionality

# Signals
signal server_started
signal client_connected
signal connection_failed
signal player_joined(client_id, client_name)
signal player_left(client_id, client_name)
signal pieces_connected(piece_id, connected_piece_id, new_group_number, piece_positions)

## Constants
var DEFAULT_PORT = 8080
const MAX_PLAYERS = 8
var SERVER_IP = "127.0.0.1"  



# Network status
var is_online = false
var is_server = false
var current_puzzle_id = null
var peer = null
var connected_players = {}
var headless = false  # Flag for headless server mode
var should_load_game = false
var ready_to_load = false

func _ready():
	var env = ConfigFile.new()
	var err = env.load("res://env.cfg")
	if err != OK:
		print("could not read env file\n",err)
	else: 
		DEFAULT_PORT = env.get_value("server", "PORT", 8080)
		SERVER_IP = str(env.get_value("server", "SERVER_IP", "127.0.0.1"))
	# Make NetworkManager persist across scenes
	process_mode = Node.PROCESS_MODE_ALWAYS
	
	# Connect to multiplayer signals
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	
	# Check for command line arguments to start headless server
	if OS.has_feature("server") or "--server" in OS.get_cmdline_args():
		print("Starting in headless server mode")
		headless = true
		start_headless_server()

func _process(delta):
	# Check if we should load the game
	if should_load_game and ready_to_load:
		var scene_path = "res://assets/scenes/jigsaw_puzzle_1.tscn"
		print("Loading game scene from NetworkManager process loop")
		
		# Get the main scene tree
		var tree = Engine.get_main_loop()
		if tree:
			# Reset flags
			should_load_game = false
			ready_to_load = false
			
			# Change the scene
			tree.change_scene_to_file(scene_path)
		else:
			print("ERROR: Still unable to get scene tree!")

# Start a headless server with a default puzzle
func start_headless_server():
	print("Starting headless server at ", str(SERVER_IP), " and port ", DEFAULT_PORT)
	
	# For headless server, just pick a default puzzle ID (can be changed via args later)
	var puzzle_id = PuzzleVar.default_path 
	if OS.get_cmdline_args().size() > 1:
		var args = OS.get_cmdline_args()
		for i in range(args.size()):
			if args[i] == "--puzzle" and i + 1 < args.size():
				puzzle_id = args[i + 1]
	
	if start_server(puzzle_id):
		print("Headless server started successfully with puzzle ID: ", puzzle_id)
	else:
		print("Failed to start headless server")
		OS.crash("Failed to start server")

# Start a server for a specific puzzle
func start_server(puzzle_id: String) -> bool:
	if is_online:
		return false  # Already in a network session
	
	peer = ENetMultiplayerPeer.new()
	var error = peer.create_server(DEFAULT_PORT, MAX_PLAYERS)
	
	if error != OK:
		print("Failed to start server: ", error)
		return false
	
	multiplayer.multiplayer_peer = peer
	is_online = true
	is_server = true
	current_puzzle_id = puzzle_id
	
	print("Server started for puzzle: ", puzzle_id)
	server_started.emit()
	return true

# Connect to a server
func join_server(puzzle_id: String = PuzzleVar.default_path) -> bool:
	if is_online:
		return false  # Already in a network session
	
	print("Attempting to connect to server at ", SERVER_IP)
	
	peer = ENetMultiplayerPeer.new()
	var error = peer.create_client(SERVER_IP, DEFAULT_PORT)
	
	if error != OK:
		print("Failed to connect to server: ", error)
		connection_failed.emit()
		return false
	
	multiplayer.multiplayer_peer = peer
	is_online = true
	is_server = false
	current_puzzle_id = puzzle_id
	
	print("Connecting to server at ", SERVER_IP, " for puzzle: ", puzzle_id)
	return true

# Disconnect from the current session
func disconnect_from_server():
	if peer != null:
		peer.close()
	
	multiplayer.multiplayer_peer = null
	is_online = false
	is_server = false
	current_puzzle_id = null
	connected_players.clear()
	
	print("Disconnected from network session")

# Leave the current puzzle
func leave_puzzle():
	if not is_online:
		return
	
	# If server, shut down completely
	if is_server and not headless:
		disconnect_from_server()
	else:
		# If client, just disconnect
		disconnect_from_server()

# Send piece connection info to all clients
func sync_connected_pieces(piece_id: int, connected_piece_id: int, new_group_number: int, piece_positions: Array):
	if not is_online:
		return
	
	rpc("_receive_piece_connection", piece_id, connected_piece_id, new_group_number, piece_positions)

# RPC functions
@rpc("any_peer", "call_remote", "reliable")
func _receive_piece_connection(piece_id: int, connected_piece_id: int, new_group_number: int, piece_positions: Array):
	pieces_connected.emit(piece_id, connected_piece_id, new_group_number, piece_positions)

@rpc("any_peer", "call_remote", "reliable")
func register_player(player_name: String):
	var id = multiplayer.get_remote_sender_id()
	connected_players[id] = player_name
	
	if is_server:
		# Broadcast to all clients that a new player joined
		rpc("_update_player_list", connected_players)
	
	print("Player registered: ", player_name, " (", id, ")")
	player_joined.emit(id, player_name)

@rpc("authority", "call_remote", "reliable")
func _update_player_list(players: Dictionary):
	connected_players = players
	
	# Notify about each player
	for id in players:
		if id != multiplayer.get_unique_id():  # Not self
			player_joined.emit(id, players[id])

# Send the current puzzle ID to the joining client
@rpc("authority", "call_remote", "reliable")
func _send_puzzle_info(puzzle_id: String):
	current_puzzle_id = puzzle_id
	print("Received puzzle ID from server: ", puzzle_id)

# Multiplayer callback functions
func _on_peer_connected(id):
	print("Peer connected: ", id)
	
	# If we're the server, send puzzle info to the new client
	if is_server:
		rpc_id(id, "_send_puzzle_info", current_puzzle_id)

func _on_peer_disconnected(id):
	print("Peer disconnected: ", id)
	
	if connected_players.has(id):
		var player_name = connected_players[id]
		connected_players.erase(id)
		
		if is_server:
			# Update all clients about the player leaving
			rpc("_update_player_list", connected_players)
		
		player_left.emit(id, player_name)

func _on_connected_to_server():
	print("Successfully connected to server")
	client_connected.emit()
	# Register ourselves with the server
	var player_name = "Player"
	if FireAuth and FireAuth.get_user_id() != "":
		player_name = "Player_" + FireAuth.get_user_id().substr(0, 5)
	
	rpc_id(1, "register_player", player_name)

func _on_connection_failed():
	print("Connection failed")
	connection_failed.emit()
	disconnect_from_server()

func _on_server_disconnected():
	print("Server disconnected")
	disconnect_from_server()
