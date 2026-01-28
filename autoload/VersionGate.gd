extends Node


# Firestore location
const CONFIG_COLLECTION := "config"
const CONFIG_DOC := "version_gate"

# Local build version
var local_version: String


# Entry point (runs at app start)
func _ready() -> void:
	local_version = ProjectSettings.get_setting("application/config/version")
	print("VersionGate: Local version =", local_version)

	await _wait_for_firebase_auth()
	await _check_version_gate()


# Ensure Firebase Auth is ready
func _wait_for_firebase_auth() -> void:
	if not Firebase.Auth.needs_login():
		return

	print("VersionGate: Waiting for Firebase auth...")
	while Firebase.Auth.needs_login():
		await get_tree().process_frame


# Fetch version rules from Firestore
func _check_version_gate() -> void:
	var config_collection: FirestoreCollection = Firebase.Firestore.collection(CONFIG_COLLECTION)
	var doc = await config_collection.get_doc(CONFIG_DOC)

	if not doc:
		print("VersionGate: No config found, allowing execution")
		return

	# ---- blocked_versions ----
	var blocked_versions: Array[String] = []
	var raw_blocked = doc.get_value("blocked_versions")

	print("VersionGate: raw_blocked =", raw_blocked)

	if raw_blocked is Dictionary and raw_blocked.has("values"):
		for entry in raw_blocked["values"]:
			if entry.has("stringValue"):
				blocked_versions.append(entry["stringValue"])

	# ---- minimum_allowed ----
	var minimum_allowed := "0.0.0"
	var raw_min = doc.get_value("minimum_allowed")
	if raw_min is String and raw_min != "":
		minimum_allowed = raw_min

	print("VersionGate: blocked =", blocked_versions)
	print("VersionGate: minimum =", minimum_allowed)

	if should_block(local_version, blocked_versions, minimum_allowed):
		block_and_exit()


# Decision logic
func should_block(version: String, blocked_versions: Array, minimum_allowed: String) -> bool:
	if version in blocked_versions:
		print("VersionGate: Version explicitly blocked")
		return true

	if is_version_less(version, minimum_allowed):
		print("VersionGate: Version below minimum")
		return true

	return false



# Semantic version compare
func is_version_less(a: String, b: String) -> bool:
	var A = a.split(".")
	var B = b.split(".")

	for i in range(max(A.size(), B.size())):
		var ai = int(A[i]) if i < A.size() else 0
		var bi = int(B[i]) if i < B.size() else 0

		if ai < bi:
			return true
		if ai > bi:
			return false

	return false


# Block screen
func block_and_exit() -> void:
	print("VersionGate: Blocking execution")
	get_tree().change_scene_to_file(
		"res://assets/scenes/version_blocked.tscn"
	)
