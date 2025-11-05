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
			var popup = AcceptDialog.new()
			popup.title = "Login Failed"
			popup.dialog_text = "Username does not exist. Please try again."
			add_child(popup)
			popup.popup_centered()
			return
		else: 
			# Proceed to next scene based on whether nickname is set
			await FireAuth.get_user_lobby(username)
			var nickname = file.get_line()
			if nickname == "":
				file.close()
				get_tree().change_scene_to_file("res://assets/scenes/nickname.tscn")
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
		var popup = AcceptDialog.new()
		popup.title = "Invalid Username"
		popup.dialog_text = "Please enter a valid username."
		add_child(popup)
		popup.popup_centered()
		return
	var user_exist = await FireAuth.handle_username_login(username)
	if(user_exist == false):
		var popup = AcceptDialog.new()
		popup.title = "Login Failed"
		popup.dialog_text = "Username does not exist. Please try again."
		add_child(popup)
		popup.popup_centered()
		return
	else: 
		# Save username to a file
		var file_path = "user://user_data.txt" 
		var file = FileAccess.open(file_path, FileAccess.WRITE) 
		file.store_line(username)
		file.close()
		await FireAuth.get_user_lobby(username)
		
		FireAuth.write_last_login_time() 
		get_tree().change_scene_to_file("res://assets/scenes/nickname.tscn")
	
