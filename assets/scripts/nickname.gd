extends Control


func _on_continue_button_pressed() -> void:
	var nickname = %NicknameLineEdit.text
	if nickname.strip_edges() == "":
		# Show an error message if the nickname is empty
		var popup = AcceptDialog.new()
		popup.title = "Invalid Nickname"
		popup.dialog_text = "Please enter a valid nickname."
		add_child(popup)
		popup.popup_centered()
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
