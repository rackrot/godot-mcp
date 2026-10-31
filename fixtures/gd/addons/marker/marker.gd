@tool
extends EditorPlugin


func _enter_tree() -> void:
	_mark("enter")


func _exit_tree() -> void:
	_mark("exit")


func _mark(state: String) -> void:
	var file := FileAccess.open("res://marker_state.txt", FileAccess.WRITE)
	file.store_string(state)
	file.close()
