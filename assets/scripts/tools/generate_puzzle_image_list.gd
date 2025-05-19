@tool
extends EditorScript

const PUZZLE_DIR := "res://assets/puzzles/jigsawpuzzleimages"
const OUTPUT_SCRIPT := "res://puzzle_image_list.gd"

func _run():
	var dir := DirAccess.open(PUZZLE_DIR)
	if not dir:
		push_error("Failed to open puzzle directory: %s" % PUZZLE_DIR)
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()
	var image_entries := []

	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".jpg"):
			var base_path = "%s/%s" % [PUZZLE_DIR, file_name]
			var size10 = base_path.get_basename() + "_10"
			var size100 = base_path.get_basename() + "_100"
			var size1000 = base_path.get_basename() + "_1000"

			# Make sure all folders exist in the editor, since this only runs in the editor
			if DirAccess.dir_exists_absolute(size10) and DirAccess.dir_exists_absolute(size100) and DirAccess.dir_exists_absolute(size1000):
				image_entries.append({
					"file_name": file_name,
					"file_path": base_path,
					"base_name": file_name.get_basename(),
					"base_file_path": base_path.get_basename()
				})
		file_name = dir.get_next()
	dir.list_dir_end()

	if image_entries.is_empty():
		push_error("No valid puzzle entries found.")
		return

	# Write to script
	var output := "# This file is auto-generated. Do not edit manually.\n"
	output += "const PUZZLE_DATA = [\n"
	for entry in image_entries:
		output += "    {\n"
		output += "        \"file_name\": \"%s\",\n" % entry["file_name"]
		output += "        \"file_path\": \"%s\",\n" % entry["file_path"]
		output += "        \"base_name\": \"%s\",\n" % entry["base_name"]
		output += "        \"base_file_path\": \"%s\"\n" % entry["base_file_path"]
		output += "    },\n"
	output += "]\n"

	var file := FileAccess.open(OUTPUT_SCRIPT, FileAccess.WRITE)
	if file:
		file.store_string(output)
		file.close()
		print("Puzzle image list generated with %d entries." % image_entries.size())
	else:
		push_error("Could not write to %s" % OUTPUT_SCRIPT)
