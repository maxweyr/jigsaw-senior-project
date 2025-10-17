extends Camera2D

var zoom_speed = 8.0
var zoom_min = 0.2
var zoom_max = 2.0
var zoom_factor = 1.0

var is_panning = false
var last_mouse_position = Vector2()

# Camera movement bounds
var camera_bounds = Rect2(Vector2(-3700, -2700), Vector2(6000, 4100))

# Reference image path and texture loading
var reference_image_path = PuzzleVar.choice["file_path"]
var reference_texture = load(reference_image_path)

func _ready():
	make_current()
	limit_smoothed = true

	var canvas_layer = CanvasLayer.new()
	add_child(canvas_layer)

	var reference_image = TextureRect.new()
	reference_image.texture = load(reference_image_path)
	reference_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT

	var texture_size = reference_image.texture.get_size()
	var target_size = Vector2(400, 400)
	var scale_x = target_size.x / texture_size.x
	var scale_y = target_size.y / texture_size.y
	var uniform_scale = min(scale_x, scale_y)
	reference_image.set_scale(Vector2(uniform_scale, uniform_scale))
	canvas_layer.add_child(reference_image)


func _process(delta):
	var target_zoom = Vector2(zoom_factor, zoom_factor)
	zoom = zoom.lerp(target_zoom, zoom_speed * delta)
	zoom.x = clamp(zoom.x, zoom_min, zoom_max)
	zoom.y = clamp(zoom.y, zoom_min, zoom_max)
	#print("Current zoom:", zoom, "Target:", zoom_factor)


func _input(event):
	# --- Mouse wheel zoom ---
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom_factor *= 0.9  # Zoom in
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom_factor *= 1.1  # Zoom out
		zoom_factor = clamp(zoom_factor, zoom_min, zoom_max)
		print("Zoom factor (wheel):", zoom_factor)

	# --- Trackpad pinch zoom (macOS) ---
	if event is InputEventMagnifyGesture:
		var sensitivity := 0.4  # tweak for smoother/faster feel
		var delta: float = (event.factor - 1.0) * sensitivity
		zoom_factor *= 1.0 + delta
		zoom_factor = clamp(zoom_factor, zoom_min, zoom_max)
		print("Zoom factor (trackpad):", zoom_factor, " event.factor:", event.factor, " delta:", delta)

	# --- Panning when background clicked ---
	if event is InputEventMouseMotion:
		if PuzzleVar.background_clicked == true:
			var mouse_delta = event.position - last_mouse_position
			position -= mouse_delta / zoom
			position.x = clamp(position.x, camera_bounds.position.x, camera_bounds.position.x + camera_bounds.size.x)
			position.y = clamp(position.y, camera_bounds.position.y, camera_bounds.position.y + camera_bounds.size.y)
		last_mouse_position = event.position
