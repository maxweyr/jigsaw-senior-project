extends RefCounted

const PUZZLE_ROOT := "user://puzzles"

func get_version_dir(puzzle_id: String, asset_version: int) -> String:
	return "%s/%s/v%d" % [PUZZLE_ROOT, puzzle_id, asset_version]

func get_temp_dir(puzzle_id: String, asset_version: int) -> String:
	return "%s/%s/_tmp_v%d" % [PUZZLE_ROOT, puzzle_id, asset_version]

func ensure_dir(path: String) -> bool:
	var absolute := ProjectSettings.globalize_path(path)
	DirAccess.make_dir_recursive_absolute(absolute)
	return DirAccess.dir_exists_absolute(absolute)

func clear_dir(path: String) -> void:
	var absolute := ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(absolute):
		return
	var da := DirAccess.open(absolute)
	if da == null:
		return
	da.list_dir_begin()
	var name := da.get_next()
	while name != "":
		if name != "." and name != "..":
			var sub = absolute.path_join(name)
			if da.current_is_dir():
				clear_dir(path.path_join(name))
				DirAccess.remove_absolute(sub)
			else:
				DirAccess.remove_absolute(sub)
		name = da.get_next()
	da.list_dir_end()

func write_bytes(path: String, data: PackedByteArray) -> bool:
	ensure_dir(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(data)
	f.close()
	return true

func file_exists(path: String) -> bool:
	return FileAccess.file_exists(path)

func compute_sha256(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	while f.get_position() < f.get_length():
		var chunk := f.get_buffer(1024 * 128)
		hash.update(chunk)
	f.close()
	return hash.finish().hex_encode()

func validate_manifest_root(local_root: String, manifest: Dictionary) -> bool:
	if not manifest.has("files"):
		return false
	for item in manifest["files"]:
		if not item is Dictionary:
			return false
		var rel_path := str(item.get("path", ""))
		if rel_path == "":
			return false
		var full_path := local_root.path_join(rel_path)
		if not FileAccess.file_exists(full_path):
			return false
		if item.has("bytes") and int(item["bytes"]) > 0:
			var rf := FileAccess.open(full_path, FileAccess.READ)
			if rf == null:
				return false
			var size := rf.get_length()
			rf.close()
			if size != int(item["bytes"]):
				return false
		if item.has("sha256") and str(item["sha256"]) != "":
			var actual := compute_sha256(full_path)
			if actual.to_lower() != str(item["sha256"]).to_lower():
				return false
	return true

func save_manifest(local_root: String, manifest: Dictionary) -> void:
	var path := local_root.path_join("manifest.json")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(manifest, "\t"))
		f.close()

func load_manifest(local_root: String) -> Dictionary:
	var path := local_root.path_join("manifest.json")
	if not FileAccess.file_exists(path):
		return {}
	var txt := FileAccess.get_file_as_string(path)
	var jp := JSON.new()
	if jp.parse(txt) != OK or not jp.data is Dictionary:
		return {}
	return jp.data

func is_cached_and_valid(puzzle_id: String, asset_version: int) -> bool:
	var root := get_version_dir(puzzle_id, asset_version)
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(root)):
		return false
	var manifest := load_manifest(root)
	if manifest.is_empty():
		return false
	return validate_manifest_root(root, manifest)

func commit_temp_to_version(puzzle_id: String, asset_version: int) -> bool:
	var temp := get_temp_dir(puzzle_id, asset_version)
	var final := get_version_dir(puzzle_id, asset_version)
	clear_dir(final)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(final))
	var err := DirAccess.rename_absolute(ProjectSettings.globalize_path(temp), ProjectSettings.globalize_path(final))
	if err != OK:
		return false
	return true
