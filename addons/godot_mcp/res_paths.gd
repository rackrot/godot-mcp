@tool
extends RefCounted

## Validates caller-supplied res:// paths (D38). Strict, because Godot normalizes a path (backslash
## becomes a separator) after any check on the raw text, so only an already-normal path is accepted.

const ToolError := preload("tool_error.gd")

const MAX_PATH_CHARS := 4096
# This addon's folder. Tools refuse to write into it (PROTECTED_PATH); compare lowercased.
const PROTECTED_DIR := "res://addons/godot_mcp/"


# The .csproj file names in the project root.
static func root_csprojs() -> PackedStringArray:
	var found := PackedStringArray()
	for file in DirAccess.get_files_at("res://"):
		if file.get_extension() == "csproj":
			found.append(file)
	return found


# Returns {} when `path` names an existing file with one of `extensions` (lowercase, no dot),
# otherwise a tool failure. Rejects `..`, backslashes, colons, control characters, anything under
# res://.godot/ (any case), and link components.
static func check_file(path: String, extensions: Array[String]) -> Dictionary:
	var problem := _check_syntax(path, extensions)
	if not problem.is_empty():
		return problem
	if not FileAccess.file_exists(path):
		return ToolError.fail("FILE_NOT_FOUND", "No such file: " + path)
	return {}


# The same rules for a file about to be created: it must not exist, and its directory must.
static func check_new_file(path: String, extensions: Array[String]) -> Dictionary:
	var problem := _check_syntax(path, extensions)
	if not problem.is_empty():
		return problem
	if FileAccess.file_exists(path):
		return ToolError.fail("FILE_EXISTS", "Already exists: " + path)
	if not DirAccess.dir_exists_absolute(path.get_base_dir()):
		return ToolError.fail("DIR_NOT_FOUND", "No such directory: " + path.get_base_dir())
	return {}


static func _check_syntax(path: String, extensions: Array[String]) -> Dictionary:
	if path.length() > MAX_PATH_CHARS:
		return ToolError.fail("INVALID_PATH", "path is longer than %d characters" % MAX_PATH_CHARS)
	if not path.begins_with("res://"):
		return ToolError.fail("INVALID_PATH", "path must start with res://")
	var rest := path.trim_prefix("res://")
	if rest.contains("\\") or rest.contains(":"):
		return ToolError.fail("INVALID_PATH", "path must not contain backslashes or colons")
	for i in rest.length():
		if rest.unicode_at(i) < 32:
			return ToolError.fail("INVALID_PATH", "path must not contain control characters")
	if path.simplify_path() != path:
		return ToolError.fail("INVALID_PATH", "path must be normalized: no empty, . or .. segments, no trailing slash")
	var parts := rest.split("/")
	# simplify_path keeps a leading .. (nothing above the root to cancel it), so check segments too.
	if ".." in parts:
		return ToolError.fail("INVALID_PATH", "path must not contain .. segments")
	if parts[0].to_lower() == ".godot":
		return ToolError.fail("INVALID_PATH", "path must not be under res://.godot/")
	if path.get_extension().to_lower() not in extensions:
		return ToolError.fail("INVALID_PATH", "path must end in one of: " + ", ".join(extensions))
	var access := DirAccess.open("res://")
	var current := ProjectSettings.globalize_path("res://").rstrip("/")
	for part in parts:
		current = current.path_join(part)
		if access.is_link(current):
			return ToolError.fail("INVALID_PATH", "path must not pass through a symbolic link: " + part)
		if not access.file_exists(current) and not access.dir_exists(current):
			break
	# A <path>.remap file makes the editor load another file's content under this path (verified in
	# slice 3), so a save would overwrite the original with it.
	if FileAccess.file_exists(path + ".remap"):
		return ToolError.fail("INVALID_PATH", "path has a .remap file, which redirects loading")
	return {}
