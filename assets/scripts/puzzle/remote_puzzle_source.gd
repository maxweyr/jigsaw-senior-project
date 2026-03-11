extends "res://assets/scripts/puzzle/puzzle_source.gd"

func resolve_choice(entry: Dictionary, selected_size: int, downloader: Node) -> Dictionary:
	if downloader == null:
		return {}
	var result = await downloader.download_puzzle(entry, selected_size)
	if not bool(result.get("ok", false)):
		return {}
	var local_root := str(result.get("local_root", ""))
	if local_root == "":
		return {}
	var ref_candidates = [
		local_root.path_join("reference.jpg"),
		local_root.path_join("images/full.jpg"),
		local_root.path_join("thumb.jpg"),
	]
	var ref_image := ""
	for c in ref_candidates:
		if FileAccess.file_exists(c):
			ref_image = c
			break
	if ref_image == "":
		ref_image = local_root.path_join("thumb.jpg")

	return {
		"base_name": str(entry.get("id", "remote_puzzle")),
		"base_file_path": local_root,
		"file_path": ref_image,
		"size": selected_size,
		"source": "remote",
		"resolved_dir": local_root,
		"asset_version": int(entry.get("asset_version", 1)),
		"cache_id": str(result.get("cache_id", ""))
	}
