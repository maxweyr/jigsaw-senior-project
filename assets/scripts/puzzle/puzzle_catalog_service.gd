extends RefCounted

const FirestoreQuery = preload("res://addons/godot-firebase/firestore/firestore_query.gd")

func fetch_enabled_puzzles() -> Array:
	var results: Array = []
	if not Firebase or not Firebase.Firestore:
		return results

	var query := FirestoreQuery.new()
	query.from("puzzles", false)
	query.where("enabled", FirestoreQuery.OPERATOR.EQUAL, true)
	query.order_by("updated_at", FirestoreQuery.DIRECTION.DESCENDING)
	var docs = await Firebase.Firestore.query(query)
	if docs == null:
		return results

	for doc in docs:
		if doc == null:
			continue
		var puzzle_id := str(doc.doc_name)
		if doc.get_value("id") != null and str(doc.get_value("id")) != "":
			puzzle_id = str(doc.get_value("id"))

		var bundle_paths = doc.get_value("bundle_paths")
		if not (bundle_paths is Dictionary):
			bundle_paths = {}
		if bundle_paths.is_empty():
			continue
		var bundle_bytes = doc.get_value("bundle_bytes")
		if not (bundle_bytes is Dictionary):
			bundle_bytes = {}
		var bundle_sha256 = doc.get_value("bundle_sha256")
		if not (bundle_sha256 is Dictionary):
			bundle_sha256 = {}
		var size_options := _parse_size_options(doc.get_value("size_options"), bundle_paths)

		results.append({
			"id": puzzle_id,
			"title": str(doc.get_value("title") if doc.get_value("title") != null else puzzle_id),
			"difficulty": doc.get_value("difficulty"),
			"thumb_path": str(doc.get_value("thumb_path") if doc.get_value("thumb_path") != null else ""),
			"asset_version": int(doc.get_value("asset_version") if doc.get_value("asset_version") != null else 1),
			"updated_at": doc.get_value("updated_at"),
			"size_options": size_options,
			"bundle_paths": bundle_paths,
			"bundle_bytes": bundle_bytes,
			"bundle_sha256": bundle_sha256,
			"source": "remote"
		})
	return results

func _parse_size_options(raw_sizes, bundle_paths: Dictionary) -> Array:
	var unique: Dictionary = {}
	if raw_sizes is Array:
		for item in raw_sizes:
			var parsed := int(item)
			if parsed > 0:
				unique[parsed] = true
	if unique.is_empty():
		for key in bundle_paths.keys():
			var parsed := int(str(key).trim_suffix(".zip"))
			if parsed > 0:
				unique[parsed] = true
	var size_options: Array = []
	for key in unique.keys():
		size_options.append(int(key))
	size_options.sort()
	if size_options.is_empty():
		size_options = [100, 500, 1000]
	return size_options
