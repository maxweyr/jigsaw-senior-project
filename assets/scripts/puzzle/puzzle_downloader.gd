extends Node

signal progress_changed(puzzle_id: String, downloaded_files: int, total_files: int)
signal phase_changed(puzzle_id: String, message: String, downloaded_files: int, total_files: int)
signal failed(puzzle_id: String, message: String)
signal completed(puzzle_id: String, local_root: String)

const PuzzleAssetCache = preload("res://assets/scripts/puzzle/puzzle_asset_cache.gd")

const _BUNDLE_PHASE_TOTAL := 3

var _cancelled := false
var _cache := PuzzleAssetCache.new()

func cancel() -> void:
	_cancelled = true

func reset_cancel() -> void:
	_cancelled = false

func download_puzzle(puzzle_info: Dictionary, selected_size: int = 0) -> Dictionary:
	reset_cancel()
	var puzzle_id := str(puzzle_info.get("id", ""))
	var asset_version := int(puzzle_info.get("asset_version", 1))
	var resolved_size := _resolve_selected_size_for_download(puzzle_info, selected_size)
	if puzzle_id == "":
		return {"ok": false, "error": "Invalid puzzle id"}

	var cache_id := _resolve_cache_id(puzzle_id, resolved_size, puzzle_info.get("bundle_paths", {}))
	if _cache.is_cached_and_valid(cache_id, asset_version):
		return {
			"ok": true,
			"local_root": _cache.get_version_dir(cache_id, asset_version),
			"cached": true,
			"cache_id": cache_id
		}

	var bundle_path := _resolve_bundle_path(puzzle_info, resolved_size)
	if bundle_path == "":
		return {"ok": false, "error": "Missing bundle path for selected size"}
	return await _download_bundle(cache_id, puzzle_id, asset_version, resolved_size, bundle_path, puzzle_info)

func _download_bundle(cache_id: String, puzzle_id: String, asset_version: int, selected_size: int, bundle_path: String, puzzle_info: Dictionary) -> Dictionary:
	var temp_root := _cache.get_temp_dir(cache_id, asset_version)
	var stage_root := temp_root + "_bundle_stage"
	_cache.clear_dir(stage_root)
	_cache.ensure_dir(stage_root)

	var bundle_local := stage_root.path_join("bundle.zip")
	var bundle_bytes_expected := _dict_int_for_size(puzzle_info.get("bundle_bytes", {}), selected_size)
	var bundle_sha_expected := _dict_string_for_size(puzzle_info.get("bundle_sha256", {}), selected_size)

	_emit_phase(puzzle_id, "Downloading bundle...", 0, _BUNDLE_PHASE_TOTAL)
	var downloaded := await _download_blob_with_retry(bundle_path, bundle_local, bundle_bytes_expected, bundle_sha_expected)
	if not downloaded:
		failed.emit(puzzle_id, "Failed to download bundle")
		return {"ok": false, "error": "Failed to download bundle", "path": bundle_path}

	_emit_phase(puzzle_id, "Extracting puzzle...", 1, _BUNDLE_PHASE_TOTAL)
	var extract_root := stage_root.path_join("extract")
	_cache.clear_dir(extract_root)
	_cache.ensure_dir(extract_root)
	if not _extract_zip_into_dir(bundle_local, extract_root):
		failed.emit(puzzle_id, "Failed to extract bundle")
		return {"ok": false, "error": "Bundle extract failed", "path": bundle_path}

	var payload_root := stage_root.path_join("payload")
	_cache.clear_dir(payload_root)
	_cache.ensure_dir(payload_root)
	if not _promote_extracted_root(extract_root, payload_root):
		failed.emit(puzzle_id, "Bundle missing required files")
		return {"ok": false, "error": "Bundle missing required files"}

	_emit_phase(puzzle_id, "Verifying files...", 2, _BUNDLE_PHASE_TOTAL)
	var validation_error := _validate_bundle_payload(payload_root)
	if validation_error != "":
		failed.emit(puzzle_id, validation_error)
		return {"ok": false, "error": validation_error}

	var manifest := _build_manifest_for_root(payload_root, puzzle_id, selected_size, asset_version)
	if manifest.is_empty():
		failed.emit(puzzle_id, "Failed to build local bundle manifest")
		return {"ok": false, "error": "Failed to build local bundle manifest"}

	_cache.clear_dir(temp_root)
	_cache.ensure_dir(temp_root)
	if not _copy_tree(payload_root, temp_root):
		failed.emit(puzzle_id, "Failed to finalize extracted puzzle files")
		return {"ok": false, "error": "Failed to finalize extracted puzzle files"}
	_cache.save_manifest(temp_root, manifest)

	if not _cache.validate_manifest_root(temp_root, manifest):
		failed.emit(puzzle_id, "Integrity verification failed")
		return {"ok": false, "error": "Integrity verification failed"}
	if not _cache.commit_temp_to_version(cache_id, asset_version):
		failed.emit(puzzle_id, "Failed to commit puzzle cache")
		return {"ok": false, "error": "Failed to commit puzzle cache"}

	_emit_phase(puzzle_id, "Finalizing...", _BUNDLE_PHASE_TOTAL, _BUNDLE_PHASE_TOTAL)
	var local_root := _cache.get_version_dir(cache_id, asset_version)
	completed.emit(puzzle_id, local_root)
	return {"ok": true, "local_root": local_root, "cached": false, "cache_id": cache_id}

func _download_blob_with_retry(storage_path: String, local_path: String, expected_bytes: int, expected_sha256: String) -> bool:
	for attempt in range(3):
		if _cancelled:
			return false
		var ref = Firebase.Storage.ref(storage_path)
		var task = await ref.get_data()
		if not _is_storage_success(task):
			await get_tree().create_timer(0.4 * float(attempt + 1)).timeout
			continue
		var data_bytes := _extract_storage_bytes(task)
		if data_bytes.is_empty():
			await get_tree().create_timer(0.2).timeout
			continue
		if not _cache.write_bytes(local_path, data_bytes):
			await get_tree().create_timer(0.2).timeout
			continue
		if expected_bytes > 0:
			var f := FileAccess.open(local_path, FileAccess.READ)
			if f == null:
				continue
			var actual_size := f.get_length()
			f.close()
			if actual_size != expected_bytes:
				continue
		if expected_sha256 != "":
			var actual_sha := _cache.compute_sha256(local_path)
			if actual_sha.to_lower() != expected_sha256.to_lower():
				continue
		return true
	return false

func _extract_zip_into_dir(zip_path: String, dest_root: String) -> bool:
	var zip_reader := ZIPReader.new()
	var open_err := zip_reader.open(zip_path)
	if open_err != OK:
		return false
	var files := zip_reader.get_files()
	for entry in files:
		var rel_path := str(entry).replace("\\", "/")
		if rel_path == "" or rel_path.ends_with("/"):
			continue
		if not _is_safe_zip_path(rel_path):
			zip_reader.close()
			return false
		var file_data := zip_reader.read_file(rel_path)
		if not _cache.write_bytes(dest_root.path_join(rel_path), file_data):
			zip_reader.close()
			return false
	zip_reader.close()
	return true

func _is_safe_zip_path(rel_path: String) -> bool:
	if rel_path.begins_with("/") or rel_path.begins_with("\\"):
		return false
	for part in rel_path.split("/"):
		if part == "..":
			return false
	return true

func _promote_extracted_root(extract_root: String, payload_root: String) -> bool:
	var candidates: Array = [extract_root]
	var da := DirAccess.open(extract_root)
	if da != null:
		da.list_dir_begin()
		var name := da.get_next()
		while name != "":
			if name != "." and name != ".." and da.current_is_dir():
				candidates.append(extract_root.path_join(name))
			name = da.get_next()
		da.list_dir_end()
	for candidate in candidates:
		if _validate_bundle_payload(str(candidate)) != "":
			continue
		return _copy_tree(str(candidate), payload_root)
	return false

func _validate_bundle_payload(root: String) -> String:
	if not FileAccess.file_exists(root.path_join("pieces/pieces.json")):
		return "Missing pieces/pieces.json in bundle"
	if not FileAccess.file_exists(root.path_join("adjacent.json")):
		return "Missing adjacent.json in bundle"
	var raster_dir := root.path_join("pieces/raster")
	var raster_abs := ProjectSettings.globalize_path(raster_dir)
	if not DirAccess.dir_exists_absolute(raster_abs):
		return "Missing pieces/raster in bundle"
	var da := DirAccess.open(raster_dir)
	if da == null:
		return "Missing pieces/raster in bundle"
	var found_png := false
	da.list_dir_begin()
	var name := da.get_next()
	while name != "":
		if not da.current_is_dir() and name.to_lower().ends_with(".png"):
			found_png = true
			break
		name = da.get_next()
	da.list_dir_end()
	if not found_png:
		return "No PNG files in pieces/raster"
	return ""

func _build_manifest_for_root(root: String, puzzle_id: String, selected_size: int, asset_version: int) -> Dictionary:
	var rel_files: Array = []
	_collect_relative_files(root, root, rel_files)
	rel_files.sort()
	var files: Array = []
	for rel_path_raw in rel_files:
		var rel_path := str(rel_path_raw).replace("\\", "/")
		if rel_path == "manifest.json":
			continue
		var full_path := root.path_join(rel_path)
		var rf := FileAccess.open(full_path, FileAccess.READ)
		if rf == null:
			return {}
		var size_bytes := rf.get_length()
		rf.close()
		files.append({
			"path": rel_path,
			"bytes": size_bytes,
			"sha256": _cache.compute_sha256(full_path)
		})
	return {
		"puzzle_id": puzzle_id,
		"size": selected_size,
		"asset_version": asset_version,
		"files": files
	}

func _collect_relative_files(current_dir: String, root_dir: String, out: Array) -> void:
	var da := DirAccess.open(current_dir)
	if da == null:
		return
	da.list_dir_begin()
	var name := da.get_next()
	while name != "":
		if name != "." and name != "..":
			var child := current_dir.path_join(name)
			if da.current_is_dir():
				_collect_relative_files(child, root_dir, out)
			else:
				var rel := child
				var prefix := root_dir
				if not prefix.ends_with("/"):
					prefix += "/"
				if rel.begins_with(prefix):
					rel = rel.substr(prefix.length())
				out.append(rel)
		name = da.get_next()
	da.list_dir_end()

func _copy_tree(source_dir: String, target_dir: String) -> bool:
	_cache.ensure_dir(target_dir)
	var da := DirAccess.open(source_dir)
	if da == null:
		return false
	da.list_dir_begin()
	var name := da.get_next()
	while name != "":
		if name != "." and name != "..":
			var src := source_dir.path_join(name)
			var dst := target_dir.path_join(name)
			if da.current_is_dir():
				if not _copy_tree(src, dst):
					da.list_dir_end()
					return false
			else:
				var data := FileAccess.get_file_as_bytes(src)
				if not _cache.write_bytes(dst, data):
					da.list_dir_end()
					return false
		name = da.get_next()
	da.list_dir_end()
	return true

func _resolve_selected_size_for_download(puzzle_info: Dictionary, selected_size: int) -> int:
	if selected_size > 0:
		return selected_size
	var sizes = puzzle_info.get("size_options", [])
	if sizes is Array:
		for item in sizes:
			var parsed := int(item)
			if parsed > 0:
				return parsed
	return 100

func _resolve_cache_id(puzzle_id: String, selected_size: int, raw_bundle_paths) -> String:
	if not (raw_bundle_paths is Dictionary):
		return puzzle_id
	var bundle_paths: Dictionary = raw_bundle_paths
	if bundle_paths.is_empty():
		return puzzle_id
	if selected_size <= 0:
		return puzzle_id
	var suffix := "_%d" % selected_size
	if puzzle_id.ends_with(suffix):
		return puzzle_id
	return "%s%s" % [puzzle_id, suffix]

func _resolve_bundle_path(puzzle_info: Dictionary, selected_size: int) -> String:
	var bundle_paths = puzzle_info.get("bundle_paths", {})
	return _dict_string_for_size(bundle_paths, selected_size)

func _dict_string_for_size(raw_map, selected_size: int) -> String:
	if not (raw_map is Dictionary):
		return ""
	var dict_map: Dictionary = raw_map
	if dict_map.has(str(selected_size)):
		return str(dict_map[str(selected_size)])
	if dict_map.has(selected_size):
		return str(dict_map[selected_size])
	var with_zip := "%d.zip" % selected_size
	if dict_map.has(with_zip):
		return str(dict_map[with_zip])
	for key in dict_map.keys():
		var parsed := int(str(key).trim_suffix(".zip"))
		if parsed == selected_size:
			return str(dict_map[key])
	return ""

func _dict_int_for_size(raw_map, selected_size: int) -> int:
	var value := _dict_string_for_size(raw_map, selected_size)
	if value == "":
		return 0
	return int(value)

func _emit_phase(puzzle_id: String, message: String, downloaded: int, total: int) -> void:
	phase_changed.emit(puzzle_id, message, downloaded, total)
	progress_changed.emit(puzzle_id, downloaded, max(total, 1))

func _is_storage_success(task) -> bool:
	if task == null:
		return false
	if task is PackedByteArray:
		return true
	if task is Dictionary:
		if task.has("result"):
			return int(task.get("result", ERR_CANT_CONNECT)) == OK and int(task.get("response_code", 0)) >= 200 and int(task.get("response_code", 0)) < 300
		return task.get("data", null) is PackedByteArray
	if task is Object:
		var result = task.get("result")
		if result == null:
			return task.get("data") is PackedByteArray
		var response_code := int(task.get("response_code"))
		return int(result) == OK and response_code >= 200 and response_code < 300
	return false

func _extract_storage_bytes(task) -> PackedByteArray:
	if task is PackedByteArray:
		return task
	if task is Dictionary:
		var data = task.get("data", null)
		if data is PackedByteArray:
			return data
		return PackedByteArray()
	if task is Object:
		var data = task.get("data")
		if data is PackedByteArray:
			return data
	return PackedByteArray()
