@tool
extends RefCounted

const LogBuffer := preload("../log_buffer.gd")
const Request := preload("../request.gd")
const ResPaths := preload("../res_paths.gd")
const ToolError := preload("../tool_error.gd")

# Script reads and writes are capped at 1 MB (the request body cap).
const MAX_SCRIPT_BYTES := 1024 * 1024
# oldText is matched on the main thread, so it is bounded.
const MAX_OLD_TEXT_BYTES := 64 * 1024
const BOM := [0xEF, 0xBB, 0xBF]
# Not a security boundary (D33): the bearer token is the only one, and one edit_script call with a
# @tool script already runs code, since the diagnostics load runs its static initializers. This stops
# accidental edits of the server's own files, and validating them, which reloads the Script whose
# functions are on the stack and crashes the editor.

static var _IDENTIFIER := RegEx.create_from_string("^[A-Za-z_][A-Za-z0-9_]*\\z")

# Held here because handler Callables don't keep it alive.
var _log: LogBuffer


func _init(log: LogBuffer) -> void:
	_log = log


func tools() -> Array[Dictionary]:
	return [
		{
			"name": "read_script",
			"description": "Read a .gd or .cs file as UTF-8 text. `unsavedInEditor` is true when the script editor holds unsaved changes to it, which this content does not include. Files over 1 MB give TOO_LARGE.",
			"inputSchema": {
				"type": "object",
				"properties": {"path": {"type": "string", "description": "res:// path ending in .gd or .cs."}},
				"required": ["path"],
				"additionalProperties": false,
			},
			"annotations": {"readOnlyHint": true},
			"handler": read_script,
		},
		{
			"name": "create_script",
			"description": "Create a .gd or .cs file and return its diagnostics. A .gd file is an optional `class_name` line, an `extends` line and `content` as the body; a syntax error is still written and reported. A .cs file is `using Godot;`, an optional file-scoped `namespace`, and `public partial class <file name> : <extends>` with `content` as the class body; it returns no diagnostics, since build_dotnet finds C# errors, and it needs a build (build_dotnet) before update_property `script` accepts it. Refuses an existing path (FILE_EXISTS), a missing directory and anything under addons/godot_mcp/. For @tool or other leading annotations, create the file and then replace it with edit_script `content`. Attach it with update_property `script`.",
			"inputSchema": {
				"type": "object",
				"properties": {
					"path": {"type": "string", "description": "res:// path ending in .gd or .cs. A .cs file name must be an identifier, because the class takes it."},
					"extends": {"type": "string", "description": "A built-in class such as Node2D. A .gd script may also name a global class_name. For .cs, the C# spelling, which is not always the engine's: GodotObject, GpuParticles2D. It is not checked until build_dotnet."},
					"className": {"type": "string", "description": "Optional class_name. .gd only (INVALID_ARGUMENT for .cs)."},
					"namespace": {"type": "string", "description": "Optional namespace such as Game.Actors. .cs only (INVALID_ARGUMENT for .gd)."},
					"content": {"type": "string", "description": "Script body placed after the extends line, or inside the C# class braces, where each non-empty line is indented four spaces (lines inside multi-line string literals too). Max 1 MB."},
				},
				"required": ["path", "extends"],
				"additionalProperties": false,
			},
			"handler": create_script,
		},
		{
			"name": "edit_script",
			"description": "Change a .gd or .cs file, then return its diagnostics (none for .cs, whose errors come from build_dotnet; a changed .cs script also needs a build before update_property `script` accepts it). Give `oldText` and `newText` to replace one exact occurrence (NO_MATCH when absent, AMBIGUOUS_MATCH when repeated; line endings must match the file), or `content` to replace the whole file. Refuses a script with unsaved changes in the script editor (UNSAVED_EDITOR_BUFFER) and anything under addons/godot_mcp/. A syntax error is still written and reported. Open script editor tabs reload.",
			"inputSchema": {
				"type": "object",
				"properties": {
					"path": {"type": "string", "description": "res:// path ending in .gd or .cs."},
					"oldText": {"type": "string", "description": "Non-empty text (max 64 KB) that occurs exactly once."},
					"newText": {"type": "string", "description": "Its replacement."},
					"content": {"type": "string", "description": "The new full file. Max 1 MB."},
				},
				"required": ["path"],
				"additionalProperties": false,
			},
			"handler": edit_script,
		},
		{
			"name": "validate_script",
			"description": "Reload a .gd file from disk and report its first parse or compile error (GDScript stops at the first) as diagnostics {message, line}; `lineUnknown` replaces `line` when the engine gave none. GDScript warnings are not reported. This runs the static initializers of a @tool script, and reloads the script in place for everything that uses it. It checks the file on disk, not unsaved editor changes. Refuses anything under addons/godot_mcp/ (PROTECTED_PATH).",
			"inputSchema": {
				"type": "object",
				"properties": {"path": {"type": "string", "description": "res:// path ending in .gd."}},
				"required": ["path"],
				"additionalProperties": false,
			},
			"handler": validate_script,
		},
	]


func read_script(arguments: Dictionary, _request: Request) -> Variant:
	var path: String = arguments["path"]
	var problem := ResPaths.check_file(path, ["gd", "cs"])
	if not problem.is_empty():
		return problem
	var read := _read(path)
	if read.has("error"):
		return read
	return {"content": read["text"], "unsavedInEditor": _unsaved_in_editor(path)}


func create_script(arguments: Dictionary, _request: Request) -> Variant:
	var path: String = arguments["path"]
	var problem := _protected(path)
	if problem.is_empty():
		problem = ResPaths.check_new_file(path, ["gd", "cs"])
	if not problem.is_empty():
		return problem
	var base: String = arguments["extends"]
	if _is_csharp(path):
		return _create_csharp(path, base, arguments)
	if arguments.has("namespace"):
		return ToolError.fail("INVALID_ARGUMENT", "namespace applies only to .cs scripts")
	if _IDENTIFIER.search(base) == null or not (ClassDB.class_exists(base) or _is_global_class(base)):
		return ToolError.fail("INVALID_VALUE", "extends must name a built-in class or a global class_name: " + base)
	var text := ""
	if arguments.has("className"):
		var class_label: String = arguments["className"]
		if _IDENTIFIER.search(class_label) == null:
			return ToolError.fail("INVALID_VALUE", "className must be an identifier: letters, digits and _, not starting with a digit")
		text += "class_name %s\n" % class_label
	text += "extends %s\n" % base
	var body: String = arguments.get("content", "")
	if body != "":
		text += "\n" + body
	return _write_and_diagnose(path, text, false, null)


# The class is named after the file, as Godot requires. The base is written as given and left to the
# compiler: Godot's C# bindings rename classes (GpuParticles2D, GodotObject), and porting that is not worth it.
func _create_csharp(path: String, base: String, arguments: Dictionary) -> Variant:
	if arguments.has("className"):
		return ToolError.fail("INVALID_ARGUMENT", "className does not apply to .cs scripts; the class is named after the file")
	var class_label := path.get_file().get_basename()
	if _IDENTIFIER.search(class_label) == null:
		return ToolError.fail("INVALID_PATH", "A .cs file name must be an identifier, because the class takes it: " + class_label)
	for segment in base.split(".", true):
		if _IDENTIFIER.search(segment) == null:
			return ToolError.fail("INVALID_VALUE", "extends must be a C# type name: identifiers joined by dots: " + base)
	if Engine.has_singleton(base):
		return ToolError.fail("INVALID_VALUE", "%s is a static class in C#, so it cannot be a base" % base)
	var text := "using Godot;\n\n"
	if arguments.has("namespace"):
		var namespace_name: String = arguments["namespace"]
		for segment in namespace_name.split(".", true):
			if _IDENTIFIER.search(segment) == null:
				return ToolError.fail("INVALID_VALUE", "namespace must be identifiers joined by dots: " + namespace_name)
		text += "namespace %s;\n\n" % namespace_name
	text += "public partial class %s : %s\n{\n" % [class_label, base]
	var body: String = arguments.get("content", "")
	if body != "":
		# One level of four spaces per non-empty line, so multi-line string literals shift too.
		for line in body.trim_suffix("\n").split("\n"):
			text += ("    " + line if line.strip_edges() != "" else "") + "\n"
	text += "}\n"
	return _write_and_diagnose(path, text, false, null)


func edit_script(arguments: Dictionary, _request: Request) -> Variant:
	var path: String = arguments["path"]
	var whole := arguments.has("content")
	var replacing := arguments.has("oldText") or arguments.has("newText")
	if whole == replacing or (replacing and not (arguments.has("oldText") and arguments.has("newText"))):
		return ToolError.fail("INVALID_ARGUMENT", "give either content, or both oldText and newText")
	var problem := _protected(path)
	if problem.is_empty():
		problem = ResPaths.check_file(path, ["gd", "cs"])
	if not problem.is_empty():
		return problem
	if _unsaved_in_editor(path):
		return ToolError.fail("UNSAVED_EDITOR_BUFFER", "%s has unsaved changes in the script editor; save or revert them there first" % path)
	if FileAccess.get_unix_permissions(path) & FileAccess.UNIX_WRITE_OWNER == 0:
		return ToolError.fail("WRITE_FAILED", "%s is read-only" % path)
	var read := _read(path)
	if read.has("error"):
		return read
	var text: String = arguments["content"] if whole else read["text"]
	if not whole:
		var old: String = arguments["oldText"]
		if old == "":
			return ToolError.fail("INVALID_ARGUMENT", "oldText must not be empty")
		if old.to_utf8_buffer().size() > MAX_OLD_TEXT_BYTES:
			return ToolError.fail("TOO_LARGE", "oldText is larger than %d bytes" % MAX_OLD_TEXT_BYTES)
		var first := text.find(old)
		if first == -1:
			return ToolError.fail("NO_MATCH", "oldText does not occur in " + path)
		if text.find(old, first + 1) != -1:
			return ToolError.fail("AMBIGUOUS_MATCH", "oldText occurs more than once in %s; include more surrounding text" % path)
		text = text.substr(0, first) + String(arguments["newText"]) + text.substr(first + old.length())
	return _write_and_diagnose(path, text, read["bom"], read["bytes"])


func validate_script(arguments: Dictionary, _request: Request) -> Variant:
	var path: String = arguments["path"]
	var problem := _protected(path)
	if problem.is_empty():
		problem = ResPaths.check_file(path, ["gd"])
	if not problem.is_empty():
		return problem
	var diagnostics := _diagnose(path)
	return {"ok": diagnostics.is_empty(), "diagnostics": diagnostics}


# Create and edit write the file, tell the editor, and report what loading it logs. `original` is the
# file's previous bytes for an edit (null for a create); a failed write restores them, since the
# editor's save renames its temp file into place on close even when a write failed.
func _write_and_diagnose(path: String, text: String, bom: bool, original: Variant) -> Variant:
	var bytes := PackedByteArray(BOM) if bom else PackedByteArray()
	bytes.append_array(text.to_utf8_buffer())
	if bytes.size() > MAX_SCRIPT_BYTES:
		return ToolError.fail("TOO_LARGE", "The script would exceed %d bytes" % MAX_SCRIPT_BYTES)
	var err := _store(path, bytes)
	if err != OK:
		var outcome := ""
		if original != null:
			outcome = "; the original content was written back" if _store(path, original) == OK else "; restoring the original content also failed, so check the file"
		else:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
			outcome = "; the partial file was removed"
		return ToolError.fail("WRITE_FAILED", "Could not write %s (%s)%s" % [path, error_string(err), outcome])
	EditorInterface.get_resource_filesystem().update_file(path)
	EditorInterface.get_script_editor().reload_open_files()
	if _is_csharp(path):
		# The build compiles C#; loading the script would report nothing.
		return {"path": path, "diagnostics": [], "note": "C# diagnostics come from build_dotnet"}
	return {"path": path, "diagnostics": _diagnose(path)}


func _store(path: String, bytes: PackedByteArray) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	var stored := file.store_buffer(bytes)
	var err := file.get_error()
	file.close()
	if err != OK:
		return err
	if not stored:
		return ERR_FILE_CANT_WRITE
	# Godot buffers small writes until close, and close ignores a failed flush, so verify what landed.
	return OK if FileAccess.get_file_as_bytes(path) == bytes else ERR_FILE_CORRUPT


# Loads the file with CACHE_MODE_IGNORE, which also reloads an already loaded Script in place, and
# returns the first error it logged for the file (A7: the engine logs the parse or compile error with
# the script path and line). GDScript warnings go only to the debugger, so none appear. The load runs
# the static initializers of a @tool script, so this runs script code (D33).
func _diagnose(path: String) -> Array[Dictionary]:
	var cursor := _log.seq()
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var out: Array[Dictionary] = []
	for entry in _log.errors_since(cursor):
		if entry.get("file") != path:
			continue
		var item := {"message": entry["message"]}
		if entry["line"] > 0:
			item["line"] = entry["line"]
		else:
			item["lineUnknown"] = true
		out.append(item)
	if _log.evicted_since(cursor):
		out.append({"message": "The editor log overflowed while the script loaded, so its errors may be missing; see get_editor_log", "lineUnknown": true})
	if loaded == null and out.is_empty():
		out.append({"message": "The script failed to load; see get_editor_log", "lineUnknown": true})
	return out


# {text} or a tool failure. The file must be UTF-8 that survives a round trip, so an edit never alters bytes it didn't touch.
func _read(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ToolError.fail("READ_FAILED", "Could not open %s (%s)" % [path, error_string(FileAccess.get_open_error())])
	if file.get_length() > MAX_SCRIPT_BYTES:
		return ToolError.fail("TOO_LARGE", "%s is larger than %d bytes" % [path, MAX_SCRIPT_BYTES])
	var bytes := file.get_buffer(file.get_length())
	file.close()
	# A leading BOM is not part of the text; edit_script writes it back.
	var bom := bytes.slice(0, 3) == PackedByteArray(BOM)
	var body := bytes.slice(3) if bom else bytes
	var text := body.get_string_from_utf8()
	if text.to_utf8_buffer() != body:
		return ToolError.fail("NOT_UTF8", "%s is not valid UTF-8 text" % path)
	return {"text": text, "bom": bom, "bytes": bytes}


func _protected(path: String) -> Dictionary:
	if path.to_lower().begins_with(ResPaths.PROTECTED_DIR):
		return ToolError.fail("PROTECTED_PATH", "Scripts under %s cannot be written or validated through this tool" % ResPaths.PROTECTED_DIR)
	return {}


func _unsaved_in_editor(path: String) -> bool:
	return path in EditorInterface.get_script_editor().get_unsaved_files()


func _is_csharp(path: String) -> bool:
	return path.get_extension().to_lower() == "cs"


func _is_global_class(name: String) -> bool:
	for entry in ProjectSettings.get_global_class_list():
		if entry["class"] == name:
			return true
	return false
