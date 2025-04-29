extends Node

# Firebase Data Model Below
# https://lucid.app/lucidchart/af25e9e6-c77e-4969-81fa-34510e32dcd6/edit?viewport_loc=-1197%2C-1440%2C3604%2C2292%2C0_0&invitationId=inv_20e62aec-9604-4bed-b2af-4882babbe404

signal logged_in
signal signup_succeeded
signal login_failed

var user_id = ""
var currentPuzzle = ""
var is_online: bool = false

const USER_COLLECTION: String = "sp_users"
const USER_SUBCOLLECTIONS = ["active_puzzles", "completed_puzzles", "favorite_puzzles"]

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
	Firebase.Auth.signup_succeeded.connect(_on_signup_succeeded)
	Firebase.Auth.login_failed.connect(_on_login_failed)

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
	await check_auth_file() # Wait for the check to complete
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

# get current user id
func get_user_id() -> String:
	return Firebase.Auth.get_user_id()
	
func get_box_id() -> String:
	var env = ConfigFile.new()
	var err = env.load("res://.env")
	if err != OK:
		print("Could not read envfile")
		get_tree().quit(-1)
	var res = env.get_value("credentials", "USER", "not found")
	if(res == "not found"):
		print("env user not found")
		get_tree().quit(-1)
	return res

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


func write_puzzle_time_spent(puzzle_name):
	''' Senior Project
	Updates the amount spent on a specific puzzle
	'''
	var users: FirestoreCollection = Firebase.Firestore.collection("sp_users")
	var active_puzzles: FirestoreCollection = Firebase.Firestore.collection("sp_users/" + get_box_id() + "/active_puzzles")
	var current_puzzle = await active_puzzles.get_doc(puzzle_name)
	if not current_puzzle:
		print("ERROR: ACCESSING WRONG PUZZLE")
		get_tree().quit(-1)
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

func write_puzzle_state_server():
	''' Senior Project
	Writes State and Choice to DB for user's selected lobbby
	'''
	if(!NetworkManager.is_server):
		return
	var lobby_puzzle: FirestoreCollection = Firebase.Firestore.collection("sp_servers/lobby" + str(PuzzleVar.lobby_number))
	var state = await lobby_puzzle.get_doc("state")
	if not state:
		print("ERROR: Server State Not Found in Lobby", PuzzleVar.lobby_number)
		get_tree().quit(-1)
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
	state.add_or_update_field("progress", int(percentage_done))
	await lobby_puzzle.update(state)

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
	if(!NetworkManager.is_server):
		return
	var lobby_puzzle: FirestoreCollection = Firebase.Firestore.collection("sp_server/lobby" + PuzzleVar.lobby_number)
	var state = await lobby_puzzle.get_doc("state")
	# set puzzle choice
	var choice = state.get_value("puzzle_choice")
	if !choice:
		print("ERROR: Lobby", PuzzleVar.lobby_number, " has no puzzle choice")
		get_tree().quit(-1)
	# get location
	var loc = state.get_value("piece_locations")
	if(!loc):
		return []
	return parse_firestore_puzzle_data(loc)

#func get_progress() -> void:
	#var progressCollection: FirestoreCollection = await Firebase.Firestore.collection("progress")
	#var userProgressDoc = await progressCollection.get_doc(FireAuth.get_user_id())
	#for i in range(0,12):
		#var PUZZLE_NAME = puzzleNames[i][0]
		#var puzzle_data = userProgressDoc.document.get(str(PUZZLE_NAME + "progress"))
		#if puzzle_data and puzzle_data is Dictionary:
			#if "doubleValue" in puzzle_data:
				#GlobalProgress.progress_arr.append(int(puzzle_data["doubleValue"]))
			#elif "integerValue" in puzzle_data:
				#GlobalProgress.progress_arr.append(int(puzzle_data["integerValue"]))
	#
	#return
	#
