extends TextureRect

@export var rotation_speed_degrees_per_second: float = 100.0 

func _ready():
	pivot_offset = size * 0.5

func _process(delta: float) -> void:
	rotation += deg_to_rad(rotation_speed_degrees_per_second * delta)
