extends Control

@onready var camera = $"../Camera2D"

func _on_ZoomInButton_pressed():
	camera.zoom_in()

func _on_ZoomOutButton_pressed():
	camera.zoom_out()
