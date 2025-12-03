extends CanvasLayer

@onready var camera: Camera2D = $"../Camera2D"

# Track whether preview image is shown
var image_shown := true


# -------------------------
# ZOOM BUTTONS
# -------------------------
func _on_ZoomInButton_pressed() -> void:
	if camera:
		camera.zoom_in()


func _on_ZoomOutButton_pressed() -> void:
	if camera:
		camera.zoom_out()


# -------------------------
# HIDE / SHOW PREVIEW IMAGE BUTTON
# -------------------------
func _on_HideImageButton_pressed() -> void:
	image_shown = !image_shown   # flip true/false

	if camera:
		camera.set_preview_visible(image_shown)
