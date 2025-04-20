extends Node

# headless_server.gd - Main script for headless server instance
# This should be attached to a Node in a simple scene that will be the main scene for the server export

func _ready():
	print("Headless jigsaw puzzle server starting...")
	
	# Initialize NetworkManager
	var network_manager = get_node_or_null("/root/NetworkManager")
	if not network_manager:
		network_manager = load("res://assets/scripts/NetworkManager.gd").new()
		network_manager.name = "NetworkManager"
		add_child(network_manager)
	
	# We don't need to manually start the server here because NetworkManager will detect
	# the --server flag or server feature and auto-start in headless mode

func _process(delta):
	# This keeps the server running
	pass
