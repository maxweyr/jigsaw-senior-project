extends Control

# User login scene script, checks for saved username and handles login process

@onready var loading = $LoadingScreen

func _ready():
	loading.show()
	var file_path = "user://user_data.txt" 
	var file = FileAccess.open(file_path, FileAccess.READ) 
	if file != null and file.get_length() > 0:
		var username = file.get_line()
		var user_exist = await FireAuth.handle_username_login(username)
		if(user_exist == false):
			loading.hide()
			show_popup("Login Failed", "Email does not exist. \nPlease try again.")
			%UsernameLineEdit.text = ""
			%NicknameLineEdit.text = ""
			return
		else: 
			# Proceed to next scene based on whether nickname is set
			await FireAuth.get_user_lobby(username)
			var nickname = file.get_line()
			if nickname == "":
				file.close()
				loading.hide()
				return
			file.close()
			FireAuth.write_last_login_time()
			get_tree().change_scene_to_file("res://assets/scenes/new_menu.tscn")
			loading.hide()
	else:
		loading.hide()

func _on_login_button_pressed():
	var username = %UsernameLineEdit.text
	if username.strip_edges() == "":
		# Show an error message if the username is empty
		show_popup("Invalid Email", "Please enter a valid email.")
		%UsernameLineEdit.text = ""
		%NicknameLineEdit.text = ""
		return
	var user_exist = await FireAuth.handle_username_login(username)
	if(user_exist == false):
		show_popup("Login Failed", "Email does not exist.\nPlease try again.")
		%UsernameLineEdit.text = ""
		%NicknameLineEdit.text = ""
		return
	else: 
		# Save username to a file
		var file_path = "user://user_data.txt" 
		var file = FileAccess.open(file_path, FileAccess.WRITE) 
		file.store_line(username)
		file.close()
		await FireAuth.get_user_lobby(username)
		FireAuth.box_id = username
		
		FireAuth.write_last_login_time() 
	var nickname = %NicknameLineEdit.text
	if nickname.strip_edges() == "":
		# Show an error message if the nickname is empty
		show_popup("Invalid Nickname", "Please enter a valid nickname.")
		%UsernameLineEdit.text = ""
		%NicknameLineEdit.text = ""
		return
	else:
		# Save nickname to file
		var file_path = "user://user_data.txt" 
		var file = FileAccess.open(file_path, FileAccess.READ_WRITE) 
		if file:
			file.seek_end()
			file.store_line(nickname)
			file.close()
			
			FireAuth.nickname = nickname
			print("Nickname saved: ", FireAuth.nickname)
			# Proceed to the next scene
			get_tree().change_scene_to_file("res://assets/scenes/new_menu.tscn")
		else:
			print("Failed to open file for writing.")

func show_popup(title: String, message: String, size: Vector2i = Vector2i(520, 260), parent: Node = self) -> AcceptDialog:
	var popup := AcceptDialog.new()
	popup.title = title
	popup.dialog_text = message
	parent.add_child(popup)
	
	# font sizing
	popup.get_label().add_theme_font_size_override("font_size", 42)
	popup.get_ok_button().add_theme_font_size_override("font_size", 28)
	popup.add_theme_font_size_override("title_font_size", 28)
	popup.add_theme_color_override("title_color", Color.RED)
	
	# text centering
	var lbl := popup.get_label()
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	# resize popup
	popup.reset_size()               
	popup.size = size                
	popup.popup_centered()          
	
	return popup
