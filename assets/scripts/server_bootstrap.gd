extends Node

func _ready() -> void:
	var args := OS.get_cmdline_args()
	var is_dedicated := OS.has_feature("server") or "--server" in args \
		or OS.has_feature("headless") or "--headless" in args

	if is_dedicated:
		print("ServerBootstrap: Dedicated server bootstrap active.")
		return

	# Safety fallback if this scene is run without server/headless features.
	get_tree().change_scene_to_file("res://assets/scenes/login.tscn")
