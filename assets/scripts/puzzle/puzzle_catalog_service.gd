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
		var size_options: Array = []
		var raw_sizes = doc.get_value("size_options")
		if raw_sizes is Array:
			for item in raw_sizes:
				var parsed = int(item)
				if parsed > 0:
					size_options.append(parsed)
		if size_options.is_empty():
			size_options = [100, 500, 1000]
		results.append({
			"id": puzzle_id,
			"title": str(doc.get_value("title") if doc.get_value("title") != null else puzzle_id),
			"difficulty": doc.get_value("difficulty"),
			"thumb_path": str(doc.get_value("thumb_path") if doc.get_value("thumb_path") != null else ""),
			"manifest_path": str(doc.get_value("manifest_path") if doc.get_value("manifest_path") != null else ""),
			"asset_version": int(doc.get_value("asset_version") if doc.get_value("asset_version") != null else 1),
			"updated_at": doc.get_value("updated_at"),
			"size_options": size_options,
			"source": "remote"
		})
	return results
