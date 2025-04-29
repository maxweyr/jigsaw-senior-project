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
var default_path = "res://assets/puzzles/jigsawpuzzleimages/dog.png"
var images = [] # this will be loaded up in the new menu scene

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

func get_random_puzzles_1000():
	randomize() # initialize a random seed for the random number generator
	# choose a random image from the list PuzzleVar.images
	var local_puzzle_list = PuzzleVar.get_avail_puzzles()
	var selected = local_puzzle_list[randi_range(0,local_puzzle_list.size()-1)]
	# choose a random size for the puzzle ranging from 2x2 to 10x10
	selected["size"] = 1000
	return selected

func get_random_puzzles():
	randomize() # initialize a random seed for the random number generator
	# choose a random image from the list PuzzleVar.images
	var local_puzzle_list = PuzzleVar.get_avail_puzzles()
	var selected = local_puzzle_list[randi_range(0,local_puzzle_list.size()-1)]
	# choose a random size for the puzzle ranging from 2x2 to 10x10
	var sizes = [10, 100, 1000]
	var random_size = sizes[randi_range(0, 2)]
	selected["size"] = random_size
	return selected
	
	
func load_and_or_add_puzzle_random_loc(parent_node: Node, sprite_scene: PackedScene, selected_puzzle_dir: String, add: bool) -> void:
	PuzzleVar.ordered_pieces_array.clear()
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
		piece.position = Vector2(randi_range(50, spawnarea.size.x), randi_range(50, spawnarea.size.y))
		PuzzleVar.ordered_pieces_array.append(piece)
		if(add):
			parent_node.call_deferred("add_child", piece) 

	
func get_avail_puzzles():
	# Your existing function is fine
	var ret_arr = []
	var dir = DirAccess.open(PuzzleVar.path)
	if not dir:
		get_tree().quit(-1)
	dir.list_dir_begin()
	# get first file_name
	var file_name = dir.get_next()
	while file_name != "":
		# only add to ret_arr if valid path
		if not dir.current_is_dir() and (file_name.ends_with(".png") or file_name.ends_with(".jpg")):
			# in fact, we only want to say avail if the puzzle dirs exist for all 3 puzzle sizes
			# ie puzzle_name_[10, 100, 1000]
			var file_path = PuzzleVar.path + '/' + file_name
			var size10 = file_path.get_basename() + "_10"
			var size100 = file_path.get_basename() + "_100"
			var size1000 = file_path.get_basename() + "_1000"
			if !(DirAccess.dir_exists_absolute(size10) and DirAccess.dir_exists_absolute(size100) and DirAccess.dir_exists_absolute(size1000)):
				file_name = dir.get_next()
				continue
			ret_arr.append(
				{
					"file_name": file_name,
					"file_path": file_path,
					"base_name": file_name.get_basename(),
					"base_file_path": file_path.get_basename()
				}
			)
		file_name = dir.get_next()
	return ret_arr
