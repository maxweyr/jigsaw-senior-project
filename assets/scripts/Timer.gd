extends Node
#
## Called when the node enters the scene tree for the first time.
func _ready():
	update_user_playing_time()
	
## runs periodically to update user playing time
func update_user_playing_time() -> void:
	while true:
		await get_tree().create_timer(60.0).timeout
		if not NetworkManager.is_server and FireAuth.offlineMode == 0:
			FireAuth.write_total_playing_time()
			FireAuth.write_puzzle_time_spent(PuzzleVar.choice["base_name"] + "_" + str(PuzzleVar.choice["size"]))

	#
