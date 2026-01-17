extends Camera2D

# -------- Zoom settings --------
var zoom_speed: float = 1.5 
var zoom_min: float = 0.2
var zoom_max: float = 2.0
var zoom_factor: float = 0.9

# -------- Panning state --------
var is_panning: bool = false
var last_mouse_position: Vector2 = Vector2.ZERO

# -------- Camera movement bounds --------
var camera_bounds: Rect2 = Rect2(Vector2(-3700, -2700), Vector2(6000, 4100))

# -------- Reference / preview image --------
var reference_image_path: String = PuzzleVar.choice["file_path"]
var reference_texture: Texture2D = load(reference_image_path)
var preview_image: TextureRect    # the small finished-puzzle preview


func _ready() -> void:
	make_current()
	limit_smoothed = true

	# ---- Create a small preview image in a CanvasLayer ----
	var canvas_layer := CanvasLayer.new()
	add_child(canvas_layer)

	preview_image = TextureRect.new()
	preview_image.texture = reference_texture
	preview_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT

	# Target size for the preview
	var texture_size: Vector2 = reference_texture.get_size()
	var target_size: Vector2 = Vector2(400.0, 400.0)
	var scale_x: float = target_size.x / texture_size.x
	var scale_y: float = target_size.y / texture_size.y
	var uniform_scale: float = min(scale_x, scale_y)

	preview_image.scale = Vector2(uniform_scale, uniform_scale)

	# Put it in the top-left corner with a little margin
	preview_image.position = Vector2(20.0, 20.0)

	canvas_layer.add_child(preview_image)


func _process(delta: float) -> void:
	# Smooth zoom towards zoom_factor
	var target_zoom: Vector2 = Vector2(zoom_factor, zoom_factor)
	zoom = zoom.lerp(target_zoom, zoom_speed * delta)

	# Clamp zoom
	zoom.x = clamp(zoom.x, zoom_min, zoom_max)
	zoom.y = clamp(zoom.y, zoom_min, zoom_max)


func _input(event: InputEvent) -> void:
	# ---------- Mouse wheel zoom (all platforms) ----------
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton

		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			# zoom in -> smaller zoom_factor
			zoom_factor *= 0.96
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			# zoom out -> larger zoom_factor
			zoom_factor *= 1.04

		zoom_factor = clamp(zoom_factor, zoom_min, zoom_max)

	# ---------- Trackpad pinch zoom (Magnify gesture) ----------
	if event is InputEventMagnifyGesture:
		var mg := event as InputEventMagnifyGesture
		var sensitivity: float = 0.2
		var f: float = mg.factor

		# On mac: your current behavior is correct:
		#   f > 1 → fingers apart (pinch OUT) → zoom IN
		#   f < 1 → fingers together (pinch IN) → zoom OUT
		#
		# On some non-Mac laptops the factor behaves opposite,
		# so we invert the mapping there.

		if OS.get_name() == "macOS":
			if f > 1.0:
				# zoom in → make zoom_factor smaller
				var amount_in: float = (f - 1.0) * sensitivity
				zoom_factor *= (1.0 - amount_in)
			elif f < 1.0:
				# zoom out → make zoom_factor bigger
				var amount_out: float = (1.0 - f) * sensitivity
				zoom_factor *= (1.0 + amount_out)
		else:
			# Invert logic for non-macOS so the *physical gesture*
			# still feels the same:
			# pinch OUT (f > 1) → zoom IN
			# pinch IN  (f < 1) → zoom OUT
			if f > 1.0:
				# treat this as zoom IN → make zoom_factor smaller
				var amount_in2: float = (f - 1.0) * sensitivity
				zoom_factor *= (1.0 - amount_in2)
			elif f < 1.0:
				# treat this as zoom OUT → make zoom_factor bigger
				var amount_out2: float = (1.0 - f) * sensitivity
				zoom_factor *= (1.0 + amount_out2)

		zoom_factor = clamp(zoom_factor, zoom_min, zoom_max)

	# ---------- Panning when background is clicked ----------
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion

		if PuzzleVar.background_clicked:
			var mouse_delta: Vector2 = mm.position - last_mouse_position
			position -= mouse_delta / zoom

			# Clamp to camera bounds
			position.x = clamp(
				position.x,
				camera_bounds.position.x,
				camera_bounds.position.x + camera_bounds.size.x
			)
			position.y = clamp(
				position.y,
				camera_bounds.position.y,
				camera_bounds.position.y + camera_bounds.size.y
			)

		last_mouse_position = mm.position


# =========================================================
# Public helpers for UI buttons (called by ui_button.gd)
# =========================================================

func zoom_in() -> void:
	# Smaller zoom_factor = closer / zoom in
	zoom_factor = max(zoom_min, zoom_factor * 0.9)


func zoom_out() -> void:
	# Larger zoom_factor = farther / zoom out
	zoom_factor = min(zoom_max, zoom_factor * 1.1)


func set_preview_visible(visible: bool) -> void:
	if preview_image != null and is_instance_valid(preview_image):
		preview_image.visible = visible
