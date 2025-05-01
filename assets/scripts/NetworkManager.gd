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
signal pieces_connected(piece_positions)
signal pieces_moved(piece_id, piece_group_id, piece_positions)
signal puzzle_info_received(puzzle_id: String)

# Variables
var DEFAULT_PORT = 8080
var SERVER_IP = "127.0.0.1"
var is_online: bool = false # True ONLY for active ENet connection to AWS server
var is_server: bool = false # True ONLY for the dedicated AWS instance
var peer: MultiplayerPeer = null # Can hold ENetMultiplayerPeer or OfflineMultiplayerPeer
var current_puzzle_id = null
var connected_players = {}
var should_load_game = false
var ready_to_load = false
const MAX_PLAYERS = 8

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
		# is_online will be set true inside start_server()
		start_server() # Start the ENet server immediately
	
	# TODO CHANGE THIS TO NUMBER OF LOBBIES 
	# TODO OR MAYBE ONE FIREBASE CALL TO CHECK ALL 3 LOBBIES?
	PuzzleVar.choice = { 
				"file_name": "china.jpg",
				 "file_path": "res://assets/puzzles/jigsawpuzzleimages/china.jpg",
				 "base_name": "china", "base_file_path": "res://assets/puzzles/jigsawpuzzleimages/china",
				 "size": 1000 }
				# Check if lobby has a valid state
	var spirit_scene = preload("res://assets/scenes/Piece_2d.tscn")
	var selected_puzzle_dir = PuzzleVar.choice["base_file_path"] + "_" + str(PuzzleVar.choice["size"])
	var res = await FireAuth.check_lobby_puzzle_state_server(1)
	#print("SERVER CHECK STATE: ", res)
	if(res == false):
		# ensure that the puzzle piece get random locations in PuzzleVar
		PuzzleVar.load_and_or_add_puzzle_random_loc(null, spirit_scene, selected_puzzle_dir, false)
		# load these into state
		print("writing")
		await FireAuth.write_puzzle_state_server(1)
		print("done")
		
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

# Start a server with a default puzzle
func start_server():
	print("NetworkManager starting headless server at ", str(SERVER_IP), " and port ", DEFAULT_PORT)
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
		return false # Indicate failure
	
	multiplayer.multiplayer_peer = enet_peer
	peer = enet_peer
	current_puzzle_id = puzzle_id # Set the initial puzzle
	is_online = false
	is_server = true # Already true
	print("NetworkManager Dedicated Server Started...")
	return true

# Connect to a server
func join_server() -> bool:
	if is_online or is_server: return false # Prevent server or already-online client
	
	print("NetworkManager attempting to connect to server at ", SERVER_IP)
	
	var enet_peer = ENetMultiplayerPeer.new()
	var error = enet_peer.create_client(SERVER_IP, DEFAULT_PORT)
	
	if error != OK:
		print("WARNING: NetworkManager failed to connect to server: ", error)
		multiplayer.multiplayer_peer = null
		peer = null
		connection_failed.emit() # Emit failure signal
		return false # Indicate failure
	
	multiplayer.multiplayer_peer = enet_peer
	peer = enet_peer # Store the ENet peer
	# current_puzzle_id will be set via RPC (_send_puzzle_info)
	is_online = true
	is_server = false
	print("NetworkManager (Client): Connection initiated...")
	return true

# Disconnect from the current session
func disconnect_from_server():
	if is_server: return # Dedicated server doesn't disconnect this way

	print("NetworkManager (Client): Disconnecting...")
	if peer != null and peer is ENetMultiplayerPeer:
		if peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
			peer.close()

	# Reset state and explicitly go back to offline mode
	print("NetworkManager (Client): Disconnected. Switched to Offline Mode.")
	is_online = false

# Leave the current puzzle
func leave_puzzle():
	if is_server: return
	if is_online: disconnect_from_server()

##=============
## RPC Methods
##=============

@rpc("any_peer", "call_remote", "reliable")
func register_player(player_name: String):
	var id = multiplayer.get_remote_sender_id()
	connected_players[id] = player_name
	if is_server: # Broadcast to all clients that a new player joined
		rpc("_update_player_list", connected_players)
	print("Player registered: ", player_name, " (", id, ")")
	player_joined.emit(id, player_name)

@rpc("any_peer", "call_remote", "reliable")
func _receive_piece_connection(piece_id: int, connected_piece_id: int, new_group_number: int, piece_positions: Array):
	if not is_online: return # don't sync if not MP game
	print("RPC::_receive_piece_connection")
	pieces_connected.emit(piece_id, connected_piece_id, new_group_number, piece_positions)

@rpc("any_peer", "call_remote", "reliable")
func _receive_piece_move(piece_positions: Array):
	if not is_online: return
	print("RPC::_receive_piece_move")
	pieces_moved.emit(piece_positions)

@rpc("authority", "call_remote", "reliable")
func _update_player_list(players: Dictionary):
	connected_players = players
	for id in players: # Notify about each player
		if id != multiplayer.get_unique_id():  # Not self
			player_joined.emit(id, players[id])

@rpc("authority", "call_remote", "unreliable_ordered")
func _send_puzzle_info(puzzle_id: String):
	current_puzzle_id = puzzle_id
	print("NetworkManager (Client): Received puzzle ID '", puzzle_id, "'")
	puzzle_info_received.emit(puzzle_id) # Emit signal for main_menu

##==============================
## Multiplayer Callback Methods
##==============================

func _on_peer_connected(id):
	print("NetworkManager: Peer connected: ", id)
	if is_server: # If we're the ONLINE server
		if current_puzzle_id:
			print("NetworkManager (Server): Sending puzzle info '", current_puzzle_id, "' to peer ", id)
			rpc_id(id, "_send_puzzle_info", current_puzzle_id)
		else:
			printerr("ERROR::NetworkManager (Server): Cannot send puzzle info, current_puzzle_id is null!")

func _on_peer_disconnected(id):
	print("NetworkManager: Peer disconnected: ", id)
	# saving state
	FireAuth.write_puzzle_state_server(PuzzleVar.lobby_number)
	if connected_players.has(id):
		var player_name = connected_players[id]
		connected_players.erase(id)
		player_left.emit(id, player_name) # Emit signal
		if is_server: # If we are the online server
			rpc("_update_player_list", connected_players)
	if not is_server: is_online = false

func _on_connected_to_server():
	if not is_server: return # Should only happen when joining online
	print("NetworkManager: Successfully connected to server (callback)")
	# is_online should already be true from join_server initiation
	client_connected.emit() # Signal UI etc
	
	# Register player with the server
	var player_name = "Player"
	if FireAuth.is_online and FireAuth.get_box_id() != "":
		print("NetworkManager: Registering player '", FireAuth.get_box_id(), "' with server.")
		rpc_id(1, "register_player", FireAuth.get_box_id())
	else:
		print("ERROR::NetworkManager: Unable to register player, FireAuth is offline or box ID invalid")

func _on_connection_failed():
	print("WARNING::NetworkManager: Connection failed")
	disconnect_from_server()

func _on_server_disconnected():
	print("NetworkManager: Server disconnected (callback)")
	disconnect_from_server()
