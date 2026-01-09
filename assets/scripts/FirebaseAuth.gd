extends Node

# Firebase Data Model Below
# https://lucid.app/lucidchart/af25e9e6-c77e-4969-81fa-34510e32dcd6/edit?viewport_loc=-1197%2C-1440%2C3604%2C2292%2C0_0&invitationId=inv_20e62aec-9604-4bed-b2af-4882babbe404

signal logged_in
signal signup_succeeded
signal login_failed

var user_id = ""
var currentPuzzle = ""
var is_online: bool = false
var box_id: String
var nickname: String

const USER_COLLECTION: String = "sp_users"
const USER_SUBCOLLECTIONS = ["active_puzzles", "completed_puzzles"]

const SERVER_COLLECTION: String = "sp_servers"

var puzzleNames = {
	0: ["china10", 12],
	1: ["china100", 108],
	2: ["china1000", 1014],
	3: ["dog10", 12],
	4: ["dog100", 117],
	5: ["dog1000", 1014],
	6: ["elephant10", 15],
	7: ["elephant100", 112],
	8: ["elephant1000",836],
	9: ["peacock10", 12],
	10: ["peacock100", 117],
	11: ["peacock1000", 1014],
	12: ["chameleon10", 10],
	13: ["chameleon100", 100],
	14: ["chameleon1000", 100],
	15: ["hippo10", 10],
	16: ["hippo100", 100],
	17: ["hippo1000", 1000],
	18: ["mountain10", 10],
	19: ["mountain100", 100],
	20: ["mountain1000", 1000],
	21: ["nyc10", 10],
	22: ["nyc100", 100],
	23: ["nyc1000", 1000],
	24: ["rhino10", 10],
	25: ["rhino100", 100],
	26: ["rhino1000", 1000],
	27: ["seattle10", 10],
	28: ["seattle100", 100],
	29: ["seattle1000", 1000],
	30: ["taxi10", 10],
	31: ["taxi100", 100],
	32: ["taxi1000", 1000],
	33: ["tree10", 10],
	34: ["tree100", 100],
	35: ["tree1000", 1000],
};

# called when the node enters the scene tree for the first time
func _ready() -> void:
	box_id = _parse_user_arg()
	print("FirebaseAuth: Box ID set to ", box_id)
	nickname = _parse_nickname()
	print("FirebaseAuth: Nickname set to ", nickname)
	Firebase.Auth.signup_succeeded.connect(_on_signup_succeeded)
	Firebase.Auth.login_failed.connect(_on_login_failed)

func _parse_user_arg() -> String:
	# check for saved username file
	var file_path = "user://user_data.txt" # Use "user://" for user-specific data, or "res://" for project resources
	var file = FileAccess.open(file_path, FileAccess.READ) # Open in read mode
	if file != null and file.get_length() > 0:
		var username := file.get_line().strip_edges()
		file.close()
		return username
		
	# if no saved file, set default username
	return "default_user"

func _parse_nickname() -> String:
	# check for saved nickname file
	var file_path = "user://user_data.txt" # Use "user://" for user-specific data, or "res://" for project resources
	var file = FileAccess.open(file_path, FileAccess.READ) # Open in read mode
	if file != null and file.get_length() > 0:
		file.get_line() # skip first line
		var username := file.get_line().strip_edges()
		if username == "":
			username = "default_nickname"
		file.close()
		return username
		
	# if no saved file, set default nickname
	return "default_user"

# attempt anonymous login
func attempt_anonymous_login() -> void:
	await Firebase.Auth.login_anonymous()

# check if there's an existing auth session
func check_auth_file() -> void:
	await Firebase.Auth.check_auth_file()
	FireAuth.write_last_login_time()

# check if login is needed
func needs_login() -> bool:
	return Firebase.Auth.needs_login()

# Handles the login process: checks existing session, loads file, or attempts anonymous login.
# Returns true if a valid session exists after the process, false otherwise.
func handle_login() -> bool:
	print("FirebaseAuth: Handling login...")
	# 1. Check if already logged in (SDK might have a valid session)
	if not Firebase.Auth.needs_login():
		print("FirebaseAuth: Already logged in (session valid).")
		is_online = true
		write_last_login_time()
		return true
	# 2. Try loading from the auth file
	print("FirebaseAuth: No active session, checking auth file...")
	await check_auth_file() # Wait for the check to completed
	# Check again: Did loading the file log us in?
	if not Firebase.Auth.needs_login():
		print("FirebaseAuth: Login successful via auth file.")
		is_online = true
		write_last_login_time() # Record login time on success
		return true
	# 3. If still needing login, attempt anonymous login
	print("FirebaseAuth: No valid auth file found or needed login. Attempting anonymous login...")
	await attempt_anonymous_login()
	# 4. Check final login status
	# After attempt_anonymous_login, the SDK's state (checked by needs_login())
	# should be updated based on the success/failure signals it received internally.
	# We might need a brief yield or rely on the check after await.
	# await get_tree().create_timer(0.1).timeout # Optional small delay if needed for signals
	if not needs_login():
		print("FirebaseAuth: Anonymous login successful.")
		is_online = true
		write_last_login_time() # Record login time on success
		return true
	else:
		# This means anonymous login likely failed. The _on_login_failed signal handler below logs details.
		print("FirebaseAuth: Anonymous login failed or still requires login.")
		is_online = false
		return false

# handle username login for lobby number
func handle_username_login(username: String) -> bool:
	print("FirebaseAuth: Handling username...")
	var user = await get_user_doc(username)
	return user != null
	
# get the users assigned lobby from firebase
func get_user_lobby(username: String) -> void:
	var user_lobbies: FirestoreCollection = Firebase.Firestore.collection(USER_COLLECTION)
	var lobby = await user_lobbies.get_doc(username)
	var num
	if lobby != null:
		num = (lobby.get_value("lobby"))
	else:
		num = 0
		print("ERROR: lobby number returned null")
	if num != null:
		num = int(num)
	if num:
		PuzzleVar.lobby_number = num
		print("ASSIGNED LOBBY_NUMBER: ", PuzzleVar.lobby_number)
	else:
		PuzzleVar.lobby_number = 0
		print("No lobby assigned in firebase. Set lobby to 0")

# get current user id
func get_user_id() -> String:
	return Firebase.Auth.get_user_id()

func get_box_id() -> String:
	return box_id

func get_nickname() -> String:
	return nickname

#func get_box_id() -> String:
	#var env = ConfigFile.new()
	#var err = env.load("res://.env")
	#if err != OK:
		#print("Could not read envfile")
		#get_tree().quit(-1)
	#var res = env.get_value("credentials", "USER", "not found")
	#if(res == "not found"):
		#print("env user not found")
		#get_tree().quit(-1)
	#return res

func get_current_puzzle() -> String:
	return str(currentPuzzle)
	
# get current user puzzle list
func get_user_puzzle_list(id: String) -> FirestoreDocument:
	var collection: FirestoreCollection = Firebase.Firestore.collection("users")
	return (await collection.get_doc(id))
# handle successful anonymous login

func _on_signup_succeeded(auth_info: Dictionary) -> void:
	user_id = auth_info.get("localid") # extract the user id
	# save auth information locally
	Firebase.Auth.save_auth(auth_info)
	print("Anon Login Success: ", user_id)
	logged_in.emit()

##==============================
## Quick Get/Set Helper Methods
##==============================

func parse_firestore_puzzle_data(raw_array: Dictionary) -> Array:
	''' Senior project
	Used to convert ArrayObject back into an Array
	'''
	var result = []
	if not raw_array.has("values"):
		return result  # Empty array
	
	for entry in raw_array["values"]:
		if not entry.has("mapValue"):
			continue
		
		var fields = entry["mapValue"]["fields"]
		
		var id = int(fields["ID"]["integerValue"])
		var group_id = int(fields["GroupID"]["integerValue"])
		
		var center_location_fields = fields["CenterLocation"]["mapValue"]["fields"]
		var center_x = float(center_location_fields["x"]["doubleValue"])
		var center_y = float(center_location_fields["y"]["doubleValue"])
		
		result.append({
			"ID": id,
			"GroupID": group_id,
			"CenterLocation": {
				"x": center_x,
				"y": center_y
			}
		})
	return result


# returns the collection "sp_users"
func get_user_collection() -> FirestoreCollection:
	return Firebase.Firestore.collection(USER_COLLECTION)

# updates a specific user within "sp_users"
func update_user(doc: FirestoreDocument) -> void:
	await Firebase.Firestore.collection(USER_COLLECTION).update(doc)

# creates an intial user document with appropriate fiels and subcollections for play
func create_initial_user(id: String) -> FirestoreDocument:
	print("WARNING: FireAuth could not find a document in firebase for: ", id, "\nCreating initial document...")
	var init_doc = {
		"last_login": String(Time.get_datetime_string_from_system(true, true)),
		"total_playing_time": int(0)
	}
	var temp_doc = {"initialized": true}
	
	var users = get_user_collection()
	var user = await users.add(id, init_doc)
	
	for collection_name in USER_SUBCOLLECTIONS:
		var collection = Firebase.Firestore.collection("sp_users/" + id + "/" + collection_name)
		await collection.add("temp", temp_doc)
	return user

# returns the user document, and creates the initial document and fiels if not found
func get_user_doc(id: String) -> FirestoreDocument:
	var users = get_user_collection()
	var user = await users.get_doc(id)
	if !user: # if first encounter w/ this user => add them to collection w/ basic field info
		user = await create_initial_user(id)
	return user

##==============================
## Firebase Interaction Methods
##==============================

# writes the last login time to firebase 'last_login' field for the user
func write_last_login_time():
	if(NetworkManager.is_server):
		return
	var users: FirestoreCollection = Firebase.Firestore.collection("sp_users")
	var user = await users.get_doc(get_box_id())
	# this is first time we  find user, so if it doesnt exist lets add them to collection
	if !user:
		print("ADDING USER TO FB DB: ", get_box_id())
		await users.add(get_box_id(), {"last_login": Time.get_datetime_string_from_system()})
	else:
		user.add_or_update_field("last_login", Time.get_datetime_string_from_system())
		users.update(user)

func _on_login_failed(code, message):
	login_failed.emit()
	print("Login failed with code: ", code, " message: ", message)

# increments a users total_playing_time field by 1 (int)
func write_total_playing_time() -> void:
	''' Senior Project
	Updates the amount of time the player has been playing
	Note: this only counts up if the player is in a puzzle
	'''
	var users: FirestoreCollection = Firebase.Firestore.collection("sp_users")
	var user = await users.get_doc(get_box_id())
	var current_user_time = user.get_value("total_playing_time")
	if(!current_user_time):
		user.set("total_playing_time", 1)
		users.update(user)
		return
	var newTime = int(current_user_time) + 1
	print("UPDATING TOTAL PLAYTIME TO ", newTime)
	user.add_or_update_field("total_playing_time", newTime)
	await users.update(user)

# increments a users multiplayer playing time field by 1 (int)
func write_mult_playing_time() -> void:
	''' Senior Project
	Updates the amount of time the player has been playing
	Note: this only counts up if the player is in a puzzle
	'''
	var users: FirestoreCollection = Firebase.Firestore.collection("sp_users")
	var user = await users.get_doc(get_box_id())
	var current_user_time = user.get_value("mult_playing_time")
	if(!current_user_time):
		user.set("mult_playing_time", 1)
		users.update(user)
		return
	var newTime = int(current_user_time) + 1
	print("UPDATING MULTIPLAYER PLAYTIME TO ", newTime)
	user.add_or_update_field("mult_playing_time", newTime)
	await users.update(user)

# Call this whenever you (re)join the lobby
func update_my_player_entry(lobby_num: int) -> void:
	if NetworkManager.is_server: return # SAFETY CHECK (Only run on clients)

	var lobby_puzzle: FirestoreCollection = Firebase.Firestore.collection("sp_servers/lobbies/lobby" + str(lobby_num))
	var players = await lobby_puzzle.get_doc("players")
	
	if !players:
		print("ADDING PLAYERS TO SERVER FB DB: ", "players")
		await lobby_puzzle.add("players", {get_box_id(): Time.get_datetime_string_from_system()})
	else:
		players.add_or_update_field(get_box_id(), Time.get_datetime_string_from_system())
		lobby_puzzle.update(players)

func write_puzzle_time_spent(puzzle_name):
	''' Senior Project
	Updates the amount spent on a specific puzzle
	'''
	var users: FirestoreCollection = Firebase.Firestore.collection("sp_users")
	var active_puzzles: FirestoreCollection = Firebase.Firestore.collection("sp_users/" + get_box_id() + "/active_puzzles")
	var current_puzzle = await active_puzzles.get_doc(puzzle_name)
	if not current_puzzle:
		print("WARN: Active puzzle missing when updating time_spent; likely completed.")
		return
	else:
		var time = current_puzzle.get_value("time_spent")
		if(!time):
			current_puzzle.set("time_spent", 1)
		else:
			current_puzzle.add_or_update_field("time_spent", int(time) + 1)
		await active_puzzles.update(current_puzzle)

func write_completed_puzzle(puzzle_name):
	''' Senior project
	Gets the user's info about puzzle and stores it in completed puzzles DB
	'''
	pass

#func add_user_completed_puzzles(completedPuzzle: Dictionary) -> void:
	#var userCollection: FirestoreCollection = Firebase.Firestore.collection("users")
	#var userDoc = await userCollection.get_doc(FireAuth.get_user_id())
	#var userCompletedPuzzleField = userDoc.document.get("completedPuzzles")
	#var completedPuzzlesList = []
	#
	#for puzzle in userCompletedPuzzleField["arrayValue"]["values"]:
		#if "mapValue" in puzzle:
			#var puzzleData = puzzle["mapValue"]["fields"]
			#completedPuzzlesList.append({
				#"puzzleId": puzzleData["puzzleId"]["stringValue"],
				#"timeStarted": puzzleData["timeStarted"]["stringValue"],
				#"timeFinished": puzzleData["timeFinished"]["stringValue"]
				#})
	#
	#completedPuzzlesList.append({
			#"puzzleId": completedPuzzle["puzzleId"]["stringValue"],
			#"timeStarted": completedPuzzle["timeStarted"]["stringValue"],
			#"timeFinished": Time.get_datetime_string_from_system()
			#})
	#userDoc.add_or_update_field("completedPuzzles", completedPuzzlesList)
	#userCollection.update(userDoc)


func update_active_puzzle(puzzle_name):
	''' Senior Project
	On non-multiplayer puzzle select, adds active_puzzle
	'''
	var users: FirestoreCollection = Firebase.Firestore.collection("sp_users")
	var active_puzzles: FirestoreCollection = Firebase.Firestore.collection("sp_users/" + get_box_id() + "/active_puzzles")
	var current_puzzle = await active_puzzles.get_doc(puzzle_name)
	
	if not current_puzzle:
		await active_puzzles.add(puzzle_name, {
			"start_time": Time.get_datetime_string_from_system(),
			"last_opened": Time.get_datetime_string_from_system(),
			"time_spent": 0,
		})
	else:
		current_puzzle.add_or_update_field("last_opened", Time.get_datetime_string_from_system())
		await active_puzzles.update(current_puzzle)	

func write_puzzle_state(state_arr, puzzle_name, size):
	var active_puzzles: FirestoreCollection = Firebase.Firestore.collection("sp_users/" + get_box_id() + "/active_puzzles")
	var current_puzzle = await active_puzzles.get_doc(puzzle_name)
	if not current_puzzle:
		print("ERROR: ACCESSING WRONG PUZZLE")
		get_tree().quit(-1)
		return
	var puzzle_data = []
	var group_ids = {}
	for p in state_arr:
		puzzle_data.append({
			"ID": p.ID,
			"GroupID": p.group_number,
			"CenterLocation": {
				"x": p.global_position.x,
				"y": p.global_position.y
			}
		})
		group_ids[p.group_number] = true
	var percentage_done = float(size - group_ids.size()) / float(size - 1) * 100.0
	#print("groups ", group_ids, " ", group_ids.size(), " ", percentage_done)
	# update current_puzzle
	current_puzzle.add_or_update_field("piece_locations", puzzle_data)
	current_puzzle.add_or_update_field("progress", int(percentage_done))
	await active_puzzles.update(current_puzzle)

func check_lobby_choice(lobby_num):
	''' Senior Project
	Checks the lobby number for a valid choice
	
	returns {} if no choice or state
	'''
	var lobby_puzzle: FirestoreCollection = Firebase.Firestore.collection("sp_servers/lobbies/lobby" + str(lobby_num))
	var state = await lobby_puzzle.get_doc("state")
	if not state:
		print("FB: Checked lobby", lobby_num, " for state but did not find one (looking for choice)")
		return {}
	var choice = state.get_value("puzzle_choice")
	if(!choice):
		return {}
	return choice

func check_lobby_puzzle_state_server(lobby_num):
	''' Senior Project
	Checks the lobby number for a valid position array
	'''
	var lobby_puzzle: FirestoreCollection = Firebase.Firestore.collection("sp_servers/lobbies/lobby" + str(lobby_num))
	var state = await lobby_puzzle.get_doc("state")
	if not state:
		print("FB: Server State Not Found in Lobby", PuzzleVar.lobby_number)
		return []
	var pos = state.get_value("piece_locations")
	if(!pos):
		return false
	return true

func write_puzzle_state_server(lobby_num):
	''' Senior Project
	Writes State and Choice to DB for user's selected lobbby
	'''
	if(NetworkManager.is_server):
		return
	var lobby_puzzle: FirestoreCollection = Firebase.Firestore.collection("sp_servers/lobbies/lobby" + str(lobby_num))
	var state = await lobby_puzzle.get_doc("state")
	if not state:
		print("ERROR: Server State Not Found in Lobby", lobby_num)
		get_tree().quit(-1)
		return
	if(PuzzleVar.ordered_pieces_array.is_empty()):
		print("Trying to update puzzle state to empty????")
		return
	var puzzle_data = []
	var group_ids = {}
	for p in PuzzleVar.ordered_pieces_array:
		puzzle_data.append({
			"ID": p.ID,
			"GroupID": p.group_number,
			"CenterLocation": {
				"x": p.global_position.x,
				"y": p.global_position.y
			}
		})
		group_ids[p.group_number] = true
	var size = PuzzleVar.global_num_pieces
	var percentage_done = float(size - group_ids.size()) / float(size - 1) * 100.0
	#print("groups ", group_ids, " ", group_ids.size(), " ", percentage_done)
	# update current_puzzle
	state.add_or_update_field("puzzle_choice", PuzzleVar.choice)
	state.add_or_update_field("piece_locations", puzzle_data)
	state.add_or_update_field("piece_locations2", puzzle_data)
	state.add_or_update_field("progress", int(percentage_done))
	await lobby_puzzle.update(state)
	print("updated state on server")

func get_puzzle_state(puzzle_name):
	''' Senior Project
	Returns the puzzle state for the user
	'''
	var active_puzzles: FirestoreCollection = Firebase.Firestore.collection("sp_users/" + get_box_id() + "/active_puzzles")
	var current_puzzle = await active_puzzles.get_doc(puzzle_name)
	var res = current_puzzle.get_value("piece_locations")
	if(!res):
		return []
	return parse_firestore_puzzle_data(res)

func get_puzzle_state_server():
	''' Senior Project
	Returns the puzzle state for the user's selected lobby
	'''
	
	var lobby_puzzle: FirestoreCollection = Firebase.Firestore.collection("sp_servers/lobbies/lobby" + str(PuzzleVar.lobby_number))
	#print(lobby_puzzle)
	var state = await lobby_puzzle.get_doc("state")
	if(!state):
		print("FB Could not find state for lobby", PuzzleVar.lobby_number)
		lobby_puzzle.add("state", {"progress": 0})
		return []

	# set puzzle choice
	var choice = state.get_value("puzzle_choice")
	if choice == null:
		print("ERROR: Lobby", PuzzleVar.lobby_number, " has no puzzle choice")
		return []
	# get location
	var loc = state.get_value("piece_locations2")
	if loc == null:
		print("FB: LOC FIELD MISSING")
		return []
	if loc is Array and loc.size() == 0:
		print("FB: LOC IS EMPTY ARRAY")
		return []
	print("FB COMPLETE: ", loc)
	return parse_firestore_puzzle_data(loc)


func write_complete(puzzle_name):
	''' Senior Project
	Writes the current puzzle to completion with stats about players progress
	ie how long it took them. 
	'''
	var active_puzzles: FirestoreCollection = Firebase.Firestore.collection("sp_users/" + get_box_id() + "/active_puzzles")
	var completed_puzzles: FirestoreCollection = Firebase.Firestore.collection("sp_users/" + get_box_id() + "/completed_puzzles")
	var current_puzzle = await active_puzzles.get_doc(puzzle_name)
	if(!current_puzzle):
		print("ERROR: could not send puzzle to complete bc it does not exist in active puzzles")
		return 
	var st = current_puzzle.get_value("start_time")
	var ts = current_puzzle.get_value("time_spent")
	# save stats
	await completed_puzzles.add(Time.get_datetime_string_from_system(), {
		"puzzle_name" : puzzle_name,
		"start_time" : st,
		"time_spent" : ts, 
	})
	# now delete from active 
	await active_puzzles.delete(current_puzzle)


func write_complete_server():
	''' Senior Project
	
	For Multiplayer, we simply remove all of the fields in state,
	on next time joining multiplayer, a new puzzle will be loaded in
	'''
	var lobby_puzzle: FirestoreCollection = Firebase.Firestore.collection("sp_servers/lobbies/lobby" + str(PuzzleVar.lobby_number))
	var state = await lobby_puzzle.get_doc("state")
	state.add_or_update_field("piece_locations2", [])
	state.add_or_update_field("progress", 0)
	state.add_or_update_field("puzzle_choice", {})
	await lobby_puzzle.update(state)
