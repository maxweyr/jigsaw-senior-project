extends Control


func _on_select_10_pressed() -> void:
	$AudioStreamPlayer.play()
	PuzzleVar.choice = PuzzleVar.get_random_puzzles_w_size(10)
	# load the texture and get the size of the puzzle image
	get_tree().change_scene_to_file("res://assets/scenes/jigsaw_puzzle_1.tscn")


func _on_select_100_pressed() -> void:
	$AudioStreamPlayer.play()
	PuzzleVar.choice = PuzzleVar.get_random_puzzles_w_size(100)
	# load the texture and get the size of the puzzle image
	get_tree().change_scene_to_file("res://assets/scenes/jigsaw_puzzle_1.tscn")


func _on_select_1000_pressed() -> void:
	$AudioStreamPlayer.play()
	PuzzleVar.choice = PuzzleVar.get_random_puzzles_w_size(1000)
	# load the texture and get the size of the puzzle image
	get_tree().change_scene_to_file("res://assets/scenes/jigsaw_puzzle_1.tscn")


func _on_suprise_me_pressed() -> void:
	$AudioStreamPlayer.play()
	PuzzleVar.choice = PuzzleVar.get_random_puzzles()
	# load the texture and get the size of the puzzle image
	get_tree().change_scene_to_file("res://assets/scenes/jigsaw_puzzle_1.tscn")


func _on_back_pressed() -> void:
	$AudioStreamPlayer.play()
	get_tree().change_scene_to_file("res://assets/scenes/new_menu.tscn")
