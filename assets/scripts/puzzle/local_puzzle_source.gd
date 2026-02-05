extends "res://assets/scripts/puzzle/puzzle_source.gd"

func resolve_choice(entry: Dictionary, selected_size: int, _downloader: Node) -> Dictionary:
	var local = entry.get("local_data", {}).duplicate(true)
	local["size"] = selected_size
	local["source"] = "local"
	return local
