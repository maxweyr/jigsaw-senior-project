extends Control

# this menu is used to select which puzzle the player wants to play

# these are variables for changing PageIndicator which is used
# to display the current page you are on
# ex:
#	PageIndicator will display:
#	1 out of 2
#	if you are on the first page out of
#	two pages total

var page_num = 1
# total_pages gets calculated in ready and is based off the amount
# of images in the image list
var total_pages # gets calculated in ready, is based off the amount of images
var page_string = "%d out of %d"
@onready var pageind = $PageIndicator # actual reference for PageIndicator
# buttons reference:
@onready var go_back_menu = $GoBackToMenu
@onready var left_button = $"HBoxContainer/left button"
@onready var right_button = $"HBoxContainer/right button"
@onready var size_label = $Panel/VBoxContainer/Thumbnail/size_label
@onready var hbox = $"HBoxContainer"
@onready var panel = $"Panel"
@onready var thumbnail = $Panel/VBoxContainer/Thumbnail
@onready var loading = $LoadingScreen

# grid reference:
#have an array of images to pull from that will correspond to an integer returned by the buttons
#for each page take the integer and add a multiple of 9
@onready var grid = $"HBoxContainer/GridContainer"

var list = []

var local_puzzle_list = []

# Called when the node enters the scene tree for the first time.
func _ready():
	# this code will iterate through the children of the grid which are buttons
	# and will link them so that they all carry out the same function
	# that function being button_pressed
	print("SELECT_PUZZLE")
	# populate local_puzzle_list with puzzles and size
	local_puzzle_list = PuzzleVar.get_avail_puzzles()
	print(local_puzzle_list)
	for i in grid.get_children():
		var button := i as BaseButton
		if is_instance_valid(button):
			button.text = "" # set all buttons to have no text for formatting
			# actual code connecting the button_pressed function to
			# the buttons in the grid
			button.pressed.connect(button_pressed.bind(button))
	#
	# this code gets the number of total pages
	var num_buttons = grid.get_child_count()
	#var imgsize = float(PuzzleVar.images.size())
	var imgsize = local_puzzle_list.size() * 3.0 # assume each image in path will get 3 sizes (10, 100, 1000
	var nb = float(num_buttons)
	total_pages = ceil(imgsize/nb) # round up always to get total_pages
	# disable the buttons logic that controls switching pages depending on
	# how many pages there are
	left_button.disabled = true 
	if total_pages == 1:
		right_button.disabled = true
	# the await is required so that the pages have time to load in
	await get_tree().process_frame
	# populates the buttons in the grid with actual images so that you can
	# preview which puzzle you want to select
	self.populate_grid_2()

		
	
# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta):
	# this code updates the display so that you know which page you are on
	pageind.text = page_string %[page_num,total_pages]

func _on_left_button_pressed():
	$AudioStreamPlayer.play()
	
	# decrements the current page you are on
	if page_num > 1:
		page_num -= 1
	
	# disables left button if you switch to page 1 and enables the right button
	if page_num == 1:
		left_button.disabled = true
		right_button.disabled = false
	
	# repopulates the grid with a new selection of images
	self.populate_grid_2()

func _on_right_button_pressed():
	$AudioStreamPlayer.play()
	
	# adds 1 to the current page you are on
	if page_num < total_pages:
		page_num += 1
	
	# if reach the last page, disables the right button and enables the left button
	if page_num == total_pages:
		right_button.disabled = true
		left_button.disabled = false
	
	# if it is some page in between 1 and the total number of pages
	# then have both buttons be enabled
	else:
		right_button.disabled = false
		left_button.disabled = false
	
	# repopulates the grid with a new selection of images
	self.populate_grid_2()

# this function selects the image that is previewed on the button for the puzzle
func button_pressed(button):
	#need to take val into account
	#do stuff to pick image
	
	#$AudioStreamPlayer.play() #this doesn't currently work because it switches scenes too quickly
	# index is initially set as the page number subtracted by 1 and then
	# multiplied by the number of buttons which is 9
	# ex:
	#	if you select something from page 2, you will currently
	#	have an index of 9
	var index = (page_num-1) * grid.get_child_count()
	# how this works is by taking the name of the button and taking the
	# number from the last character as per naming convention: gridx
	# ex:
	#	if you select the image in the button that is labeled grid1 then it
	#	takes the 1 at the end and adds it to the index to get the actual index
	#	of the image as it would be in the list PuzzleVar.images
	
	# ex for total thing:
	#	if you select an image on page 2 and pick grid1, then the actual index
	#	of the image is 10 and that will be put into PuzzleVar.choice so that
	#	the appropriate image can be loaded in
	
	var button_name = String(button.name)
	var chosen = index + int(button_name[-1])
	var row_selected = ceil((chosen % 9)/ 3)
	var sizes = [10, 100, 1000]
	var size_selected = sizes[chosen % 3]
			
	#print(row_selected, " from page ", page_num)
	# now we need to select the row corresponding to the page num
	var start_image = (page_num - 1) * 3
	var end_image = min(local_puzzle_list.size() * 3, start_image + 3)
	var puzzles_on_page = local_puzzle_list.slice(start_image, end_image)
	if !(row_selected < puzzles_on_page.size()):
		return
	#print(puzzles_on_page[row_selected]["base_name"])
	# if the selection is valid, proceed to the puzzle size selection menu
	puzzles_on_page[row_selected]["size"] = size_selected
	PuzzleVar.choice = puzzles_on_page[row_selected]
	
	# Show Continue panel
	hbox.hide()
	pageind.hide()
	thumbnail.texture = load(puzzles_on_page[row_selected]["file_path"])
	size_label.text = str(size_selected)
	panel.show()
	

func populate_grid_2():
	var buttons = grid.get_children()
	var columns = grid.columns
	var rows = buttons.size() / columns
	var base_index = (page_num - 1) * rows

	for row in range(rows):
		var img_index = base_index + row
		if img_index >= local_puzzle_list.size():
			# Clear all buttons in this row
			for col in range(columns):
				var button = buttons[row * columns + col]
				var tex_node = button.get_child(0)
				if tex_node and tex_node is TextureRect:
					tex_node.texture = null
			continue

		var file_path = local_puzzle_list[img_index]["file_path"]
		var res = load(file_path)

		for col in range(columns):
			var button = buttons[row * columns + col]
			if is_instance_valid(button):
				var tex_node = button.get_child(0)
				if tex_node and tex_node is TextureRect:
					tex_node.texture = res
					tex_node.size = button.size

				## Optional: show different progress info per size
				#if FireAuth.offlineMode == 0:
					#var global_index = img_index * columns + col
					#print(GlobalProgress.progress_arr)
					#add_custom_label(button, GlobalProgress.progress_arr[global_index])
				#else:
					#add_custom_label(button, 0)

			
			
# this function is what populates the grid with images so that you can
# preview which image you want to select
func populate_grid():
	# function starts by calculating the index of the image to start with
	# when populating the grid with 9 images
	var index = (page_num-1) * grid.get_child_count()
	# iterates through each child (button) of the grid and sets the buttons
	# texture to the appropriate image
	
	for i in grid.get_children():
		var button := i as BaseButton
		if is_instance_valid(button):
			if index < PuzzleVar.images.size():
				var file_path = PuzzleVar.path+"/"+PuzzleVar.images[index]
				var res = load(file_path)
				print("file_path: ", file_path, " loaded")
				button.get_child(0).texture = res
				button.get_child(0).size = button.size
				if FireAuth.offlineMode == 0:
					print(GlobalProgress.progress_arr)
					#add_custom_label(button, GlobalProgress.progress_arr[index])
				else:
					add_custom_label(button, 0)
				
			else:
				button.get_child(0).texture = null
			# iterates the index to get the next image after the image is
			# loaded in
			index += 1
			
			
func add_custom_label(button, percentage):
	# Create a Panel (Colored Background)
	var new_panel = Panel.new()
	new_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	new_panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# Flat style
	new_panel.add_theme_stylebox_override("panel", StyleBoxFlat.new())
	# Customize the Panel's appearance
	
	
	var stylebox = new_panel.get_theme_stylebox("panel").duplicate()
	stylebox.bg_color = Color(0, 0, 0, 0.7)# Black with 70% opacity
	new_panel.add_theme_stylebox_override("panel", stylebox)

	# Set panel size and anchors (positioning)
	new_panel.anchor_left = 0.0
	new_panel.anchor_right = 1.0
	# Keeps it at the bottom of the button
	new_panel.anchor_top = 0.8
	new_panel.anchor_bottom = 1.0

	# Create Label (Text)
	var label = Label.new()
	label.text = "Progress: " + str(percentage) + "% completed" # Customize text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	# Adjust text size
	label.add_theme_font_size_override("font_size", 30)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	# Add Panel and Label to the Button
	# Add the background first
	button.add_child(panel)
	# Add the text label on top of the background
	button.add_child(label)

	# Ensure Label is inside the Panel
	label.anchor_left = 0.0
	label.anchor_right = 1.0
	label.anchor_top = 0.8
	label.anchor_bottom = 1.0


func _on_start_puzzle_pressed() -> void:
	loading.show()  # show loading screen immediately
	await get_tree().process_frame  # pause
	get_tree().change_scene_to_file("res://assets/scenes/jigsaw_puzzle_1.tscn")


func _on_go_back_pressed() -> void:
	panel.hide()
	pageind.show()
	hbox.show()


func _on_go_back_to_menu_pressed() -> void:
	get_tree().change_scene_to_file("res://assets/scenes/new_menu.tscn")
