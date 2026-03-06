@tool
extends EditorPlugin

var _added_firebase_autoload := false

func _enter_tree() -> void:
    # The project already declares Firebase in [autoload] in project.godot.
    # Only add/remove it here if the plugin actually created it.
    if not ProjectSettings.has_setting("autoload/Firebase"):
        add_autoload_singleton("Firebase", "res://addons/godot-firebase/firebase/firebase.tscn")
        _added_firebase_autoload = true

func _exit_tree() -> void:
    if _added_firebase_autoload:
        remove_autoload_singleton("Firebase")
