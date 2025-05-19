extends Node2D

# these are global variables

class_name PuzzleData

var open_first_time = true

var row = 2
var col = 2

var size = 0

# I coopted active_piece into a boolean value for Piece_2d in order to isolate
# the pieces so that you couldn't hold two at a time if there was overlap
var active_piece= -1

# choice corresponds to the index of a piece in the list images
var choice = {}

var path = "res://assets/puzzles/jigsawpuzzleimages" # path for the images
var default_path = "res://assets/puzzles/jigsawpuzzleimages/dog.jpg"
var images = [] # this will be loaded up in the new menu scene
const PuzzleImageData = preload("res://puzzle_image_list.gd")

# these are the actual size of the puzzle piece, I am putting them in here so
# that piece_2d can access them and use them for sizing upon instantiation
#var pieceWidth
#var pieceHeight
var number_correct = 0 # this is the number of pieces that have been placed

# boolean value to trigger debug mode
var debug = false

var selected_puzzle_dir
var sprite_scene
var global_coordinates_list = {} # a dictionary of global coordinates for each piece
var adjacent_pieces_list = {} #a dictionary of adjacent pieces for each piece
var image_file_names = {} #a dictionary containing a mapping of selection numbers to image names
var global_num_pieces = 0 #the number of pieces in the current puzzle
var ordered_pieces_array = [] # an ordered array (by ID) of all the pieces
var draw_green_check = false

var snap_found = false
var piece_clicked = false
var background_clicked = false

# New variables for online mode
var is_online_mode = false
var lobby_number = 1

func get_random_puzzles_w_size(size):
	randomize() # initialize a random seed for the random number generator
	# choose a random image from the list PuzzleVar.images
	var local_puzzle_list = PuzzleVar.get_avail_puzzles()
	var selected = local_puzzle_list[randi_range(0,local_puzzle_list.size()-1)]
	# choose a random size for the puzzle ranging from 2x2 to 10x10
	selected["size"] = size
	return selected

func get_random_puzzles():
	randomize() # initialize a random seed for the random number generator
	# choose a random image from the list PuzzleVar.images
	var local_puzzle_list = PuzzleVar.get_avail_puzzles()
	var selected = local_puzzle_list[randi_range(0,local_puzzle_list.size()-1)]
	# choose a random size for the puzzle ranging from 2x2 to 10x10
	var sizes = [10, 100, 1000]
	var random_size = sizes[randi_range(0, 2)]
	
	print("Selected type: ", typeof(selected)) # Should be TYPE_DICTIONARY == 19
	print("Selected value: ", selected)

	
	selected["size"] = random_size
	return selected
	
func get_online_choice():
	'''
		Checks database for if the lobby has a choice already,
		if it doesnt, it will create a new random choice
		
		returns {} to be used for choice
	'''
	# First, check if database has choice saved
	var choice = await FireAuth.check_lobby_choice(PuzzleVar.lobby_number)
	if(choice):
		return choice
	else:
		return get_random_puzzles_w_size(100)
		
func load_and_or_add_puzzle_random_loc(parent_node: Node, sprite_scene: PackedScene, selected_puzzle_dir: String, add: bool) -> void:
	PuzzleVar.ordered_pieces_array.clear()
	#var placed_pieces: Array = [] #Array of placed pieces for overlap detection
	#var max_attempts = 1000  # Avoid infinite loops during overlap detection
	
	randomize()
	
	for x in range(PuzzleVar.global_num_pieces):
		var piece = sprite_scene.instantiate()
		piece.add_to_group("puzzle_pieces")

		var sprite = piece.get_node("Sprite2D")
		var piece_image_path = selected_puzzle_dir + "/pieces/raster/" + str(x) + ".png"
		piece.ID = x
		piece.z_index = 2
		sprite.texture = load(piece_image_path)

		piece.piece_height = sprite.texture.get_height()
		piece.piece_width = sprite.texture.get_width()

		var collision_box = piece.get_node("Sprite2D/Area2D/CollisionShape2D")
		collision_box.shape.extents = Vector2(sprite.texture.get_width() / 2, sprite.texture.get_height() / 2)

		var spawnarea = parent_node.get_viewport_rect()
		var max_x = spawnarea.size.x - piece.piece_width
		var max_y = spawnarea.size.y - piece.piece_height

		piece.position = Vector2(randi_range(0, int(max_x)),randi_range(0, int(max_y)))
		#piece.position = Vector2(randi_range(1, spawnarea.size.x), randi_range(1, spawnarea.size.y))
		#PuzzleVar.ordered_pieces_array.append(piece)
		#var piece_size = Vector2(sprite.texture.get_width(), sprite.texture.get_height())
		#var position_found = false
		#var attempts = 0
		
		#while not position_found and attempts < max_attempts:
			#var candidate_pos = Vector2(
				#randi_range(50, int(spawnarea.size.x - piece_size.x)),
				#randi_range(50, int(spawnarea.size.y - piece_size.y))
			#)
			#var new_rect = Rect2(candidate_pos, piece_size)
			#
			#var overlaps = false
			#for existing_rect in placed_pieces:
				#if new_rect.intersects(existing_rect):
					#overlaps = true
					#break
			#
			#if not overlaps:
				#position_found = true
				#piece.position = candidate_pos
				#placed_pieces.append(new_rect)
				#
		#if not position_found:
			#print("Could not find non-overlapping position for piece ", x)
			#
		PuzzleVar.ordered_pieces_array.append(piece)
		if add:
			parent_node.call_deferred("add_child", piece)

func get_avail_puzzles():
	var ret_arr = []
	for puzzle in PuzzleImageData.PUZZLE_DATA:
		var size10 = puzzle.base_file_path + "_10"
		var size100 = puzzle.base_file_path + "_100"
		var size1000 = puzzle.base_file_path + "_1000"
		if DirAccess.dir_exists_absolute(size10) and DirAccess.dir_exists_absolute(size100) and DirAccess.dir_exists_absolute(size1000):
			ret_arr.append(puzzle.duplicate())
	print(ret_arr)
	return ret_arr
