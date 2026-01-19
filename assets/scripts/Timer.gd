extends Node
#
## Called when the node enters the scene tree for the first time.
func _ready():
	update_user_playing_time()
	
## runs periodically to update user playing time
func update_user_playing_time() -> void:
	while true:
		await get_tree().create_timer(60.0).timeout

		if not NetworkManager.is_server and FireAuth.is_online:
			if get_tree().current_scene.name == "JigsawPuzzleNode": 
				# Only updates when in the puzzle scene (actually playing a puzzle vs in menu)
				FireAuth.write_total_playing_time()
				if not NetworkManager.is_online:
					FireAuth.write_puzzle_time_spent(PuzzleVar.choice["base_name"] + "_" + str(PuzzleVar.choice["size"]))
				elif NetworkManager.is_online: # update the total multiplayer time in the user document
					FireAuth.write_mult_playing_time()
					FireAuth.mp_write_puzzle_time_spent(PuzzleVar.choice["base_name"] + "_" + str(PuzzleVar.choice["size"]))
