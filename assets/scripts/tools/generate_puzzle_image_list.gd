@tool
extends EditorScript

const PUZZLE_DIR := "res://assets/puzzles/jigsawpuzzleimages"
const OUTPUT_SCRIPT := "res://puzzle_image_list.gd"

# Only these sizes will be required
const REQUIRED_SIZES := [10, 100, 500]

func _run():
	var dir := DirAccess.open(PUZZLE_DIR)
	if not dir:
		push_error("Failed to open puzzle directory: %s" % PUZZLE_DIR)
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()
	var image_entries := []

	while file_name != "":
		# only consider top-level jpg files (ignore directories)
		if not dir.current_is_dir() and file_name.to_lower().ends_with(".jpg"):
			var base_path = "%s/%s" % [PUZZLE_DIR, file_name]
			var base_name = file_name.get_basename()

			# Check that all required size folders exist
			var all_sizes_exist := true
			for s in REQUIRED_SIZES:
				var size_folder := "%s/%s_%d" % [PUZZLE_DIR, base_name, s]
				if not DirAccess.dir_exists_absolute(size_folder):
					all_sizes_exist = false
					break

			if all_sizes_exist:
				image_entries.append({
					"file_name": file_name,
					"file_path": base_path,
					"base_name": base_name,
					"base_file_path": "%s/%s" % [PUZZLE_DIR, base_name]
				})
		file_name = dir.get_next()
	dir.list_dir_end()

	if image_entries.is_empty():
		push_error("No valid puzzle entries found.")
		return

	# Write output file
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
		print("Puzzle image list generated with %d entries (10, 100, 500)." % image_entries.size())
	else:
		push_error("Could not write to %s" % OUTPUT_SCRIPT)
