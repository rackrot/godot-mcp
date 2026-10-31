@tool
extends RefCounted

const DotnetProject := preload("../dotnet_project.gd")
const Request := preload("../request.gd")
const ToolError := preload("../tool_error.gd")
const ResPaths := preload("../res_paths.gd")
const ValueCodec := preload("../value_codec.gd")
const ValueDecoder := preload("../value_decoder.gd")

const PLUGIN_DEPTH := 3
const MAX_PLUGINS := 200
const PROTECTED_PREFIXES: Array[String] = ["editor/", "editor_plugins/", "godot_mcp/"]

static var TARGET_FRAMEWORK := RegEx.create_from_string("^net(\\d+)\\.\\d+\\z")
static var NAME_PATTERN := RegEx.create_from_string("^[A-Za-z0-9_]+(?:/[A-Za-z0-9_]+)+\\z")

var _addon_version: String
# func() -> bool: whether a job (run_headless, import_assets) is running.
var _job_active: Callable
# func(overwrite: bool) -> Dictionary: Setup.install, shared with the Project > Tools menu.
var _install_skill: Callable


func _init(addon_version: String, job_active: Callable, install_skill: Callable) -> void:
	_addon_version = addon_version
	_job_active = job_active
	_install_skill = install_skill


func tools() -> Array[Dictionary]:
	return [
		{
			"name": "get_project_info",
			"description": "Read the project's name, main scene, features and autoloads, the Godot version and binary, the root csproj (`dotnet`), the plugins under res://addons/ (`plugins`: name, enabled, version), and the editor's open, unsaved, edited and playing scenes. Call this first.",
			"inputSchema": {"type": "object", "properties": {}, "additionalProperties": false},
			"annotations": {"readOnlyHint": true},
			"handler": get_project_info,
		},
		{
			"name": "create_dotnet_project",
			"description": "Create the root .csproj and the .sln for a Godot .NET project, as the editor's Create C# solution does: Godot.NET.Sdk matching this editor, net8.0 (or `targetFramework`), `EnableDynamicLoading`, and Debug, ExportDebug and ExportRelease solution configs. Names follow `dotnet/project/assembly_name` (else the project name) and `dotnet/project/solution_directory`. Refuses when the root already holds a .csproj or the .sln exists (FILE_EXISTS), and in an editor without .NET support (DOTNET_UNAVAILABLE). Build it with build_dotnet.",
			"inputSchema": {
				"type": "object",
				"properties": {"targetFramework": {"type": "string", "description": "A target framework moniker, net8.0 or later such as net9.0 or net10.0. Default net8.0."}},
				"additionalProperties": false,
			},
			"handler": create_dotnet_project,
		},
		{
			"name": "get_project_settings",
			"description": "Read project settings as {type, value}, defaults included, sorted by name. `truncated` is true when more than `limit` settings match.",
			"inputSchema": {
				"type": "object",
				"properties": {
					"prefix": {"type": "string", "description": "Only settings whose name starts with this, e.g. \"physics/2d/\"."},
					"limit": {"type": "integer", "minimum": 1, "maximum": 5000, "description": "Default 500."},
				},
				"additionalProperties": false,
			},
			"annotations": {"readOnlyHint": true},
			"handler": get_project_settings,
		},
		{
			"name": "set_project_setting",
			"description": "Set one project setting and write project.godot, e.g. application/run/main_scene or an autoload. The value is parsed by the setting's declared type, as in update_property; a new setting takes bool, number, string, array or object. Settings under `editor/`, `editor_plugins/` (use enable_plugin and disable_plugin) and `godot_mcp/` are refused. `application/run/main_scene` and `autoload/*` must name an existing scene or script by res:// path or uid:// (a uid is resolved and its path checked), and a string value must not contain control characters. Some settings, autoloads included, apply only after the editor restarts.",
			"inputSchema": {
				"type": "object",
				"properties": {
					"name": {"type": "string", "description": "Setting path such as \"display/window/size/viewport_width\"."},
					"value": {"description": "The new value."},
				},
				"required": ["name", "value"],
				"additionalProperties": false,
			},
			"handler": set_project_setting,
		},
		{
			"name": "install_agent_skill",
			"description": "Write the godot-mcp agent skill to <project>/.claude/skills/godot-mcp/SKILL.md and return the ready .mcp.json entry for this server, with the url, the headersHelper that reads the token, and the timeout. changed is false when the skill already matches the addon's copy. Refuses a symbolic link in those paths, and a SKILL.md without the godot_mcp marker unless overwrite is true. Never writes .mcp.json.",
			"inputSchema": {
				"type": "object",
				"properties": {
					"overwrite": {"type": "boolean", "description": "Replace a SKILL.md that has no godot_mcp marker. Default false."},
				},
				"additionalProperties": false,
			},
			"handler": install_agent_skill,
		},
	]


# Handlers return Variant, not Dictionary: a script error in a typed function yields an empty
# Dictionary, which the server could not tell from a legitimately empty result.
func get_project_info(_arguments: Dictionary, _request: Request) -> Variant:
	var autoloads := {}
	for property in ProjectSettings.get_property_list():
		var key: String = property["name"]
		if key.begins_with("autoload/"):
			autoloads[key.trim_prefix("autoload/")] = ProjectSettings.get_setting(key)
	var main_scene: String = ProjectSettings.get_setting("application/run/main_scene", "")
	var edited := EditorInterface.get_edited_scene_root()
	var playing := EditorInterface.get_playing_scene()
	# build_dotnet builds the one root csproj; this shows which one, or why build_dotnet would fail.
	var csprojs := ResPaths.root_csprojs()
	var dotnet: Variant = null
	if csprojs.size() == 1:
		dotnet = {"csproj": "res://" + csprojs[0]}
	elif csprojs.size() > 1:
		dotnet = {"csproj": null, "count": csprojs.size()}
	return {
		"name": ProjectSettings.get_setting("application/config/name", ""),
		"godotVersion": Engine.get_version_info()["string"],
		"godotPath": OS.get_executable_path(),
		"addonVersion": _addon_version,
		"mainScene": main_scene if main_scene != "" else null,
		"features": Array(ProjectSettings.get_setting("application/config/features", PackedStringArray())),
		"autoloads": autoloads,
		"plugins": _plugins(),
		"dotnet": dotnet,
		"editedScene": edited.scene_file_path if edited != null else null,
		"openScenes": Array(EditorInterface.get_open_scenes()),
		"unsavedScenes": Array(EditorInterface.get_unsaved_scenes()),
		"playingScene": playing if playing != "" else null,
		"scanning": EditorInterface.get_resource_filesystem().is_scanning() or EditorInterface.get_resource_filesystem().is_importing(),
		"jobActive": _job_active.call(),
	}


# D53: every plugin.cfg under res://addons/, at most PLUGIN_DEPTH folders deep, sorted, at most MAX_PLUGINS.
func _plugins() -> Array[Dictionary]:
	var names: Array[String] = []
	_find_plugins("", 1, names)
	names.sort()
	var out: Array[Dictionary] = []
	for name in names.slice(0, MAX_PLUGINS):
		var path := "res://addons/%s/plugin.cfg" % name
		var cfg := ConfigFile.new()
		var version: Variant = null
		if cfg.load(path) == OK and cfg.has_section_key("plugin", "version"):
			version = str(cfg.get_value("plugin", "version"))
		out.append({"name": name, "enabled": EditorInterface.is_plugin_enabled(path), "version": version})
	return out


# Appends the folder names (relative to res://addons/) that hold a plugin.cfg; does not follow links.
func _find_plugins(relative: String, depth: int, names: Array[String]) -> void:
	var dir := "res://addons".path_join(relative)
	var access := DirAccess.open(dir)
	if access == null:
		return
	for folder in access.get_directories():
		if access.is_link(ProjectSettings.globalize_path(dir).path_join(folder)):
			continue
		var name := relative.path_join(folder)
		if FileAccess.file_exists("res://addons/%s/plugin.cfg" % name):
			names.append(name)
		elif depth < PLUGIN_DEPTH:
			_find_plugins(name, depth + 1, names)


func create_dotnet_project(arguments: Dictionary, _request: Request) -> Variant:
	if not ClassDB.class_exists("CSharpScript"):
		return ToolError.fail("DOTNET_UNAVAILABLE", "This editor build has no .NET support, so it could not build or load a C# project")
	var framework: String = arguments.get("targetFramework", "net8.0")
	var framework_match := TARGET_FRAMEWORK.search(framework)
	if framework_match == null or int(framework_match.get_string(1)) < 8:
		return ToolError.fail("INVALID_VALUE", "targetFramework must look like net8.0, and be net8.0 or later")
	var existing := ResPaths.root_csprojs()
	if not existing.is_empty():
		return ToolError.fail("FILE_EXISTS", "The project root already holds " + existing[0])
	var name := DotnetProject.assembly_name()
	var sln_dir := DotnetProject.solution_dir()
	if sln_dir.is_empty():
		return ToolError.fail("INVALID_VALUE", "dotnet/project/solution_directory must be inside the project")
	if name.contains("\""):
		return ToolError.fail("INVALID_VALUE", "The assembly name must not contain a double quote: " + name)
	var csproj := "res://%s.csproj" % name
	if csproj.get_base_dir() != "res://":
		return ToolError.fail("INVALID_VALUE", "The assembly name must not contain a /, since the csproj belongs in the project root: " + name)
	var sln := "%s%s.sln" % [sln_dir, name]
	var problem := ResPaths.check_new_file(csproj, ["csproj"])
	if problem.is_empty():
		problem = ResPaths.check_new_file(sln, ["sln"])
	if not problem.is_empty():
		return problem
	# The csproj sits in the root, so the sln reaches it by climbing out of its own folder.
	var up := "" if sln_dir == "res://" else "../".repeat(sln_dir.trim_prefix("res://").trim_suffix("/").count("/") + 1)
	var csproj_bytes := DotnetProject.csproj_text(name, framework).to_utf8_buffer()
	# Godot writes the sln as UTF-8 with a BOM and the csproj without one.
	var sln_bytes := PackedByteArray([0xEF, 0xBB, 0xBF])
	sln_bytes.append_array(DotnetProject.sln_text(name, DotnetProject.new_guid(), up + name + ".csproj").to_utf8_buffer())
	var err := _write(csproj, csproj_bytes)
	if err == OK:
		err = _write(sln, sln_bytes)
		if err != OK:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(csproj))
	if err != OK:
		return ToolError.fail("WRITE_FAILED", "Could not write the .NET project files (%s); partial files were removed" % error_string(err))
	var files := EditorInterface.get_resource_filesystem()
	files.update_file(csproj)
	files.update_file(sln)
	return {"csproj": csproj, "solution": sln, "assemblyName": name, "sdk": DotnetProject.sdk_version()}


func get_project_settings(arguments: Dictionary, _request: Request) -> Variant:
	var prefix: String = arguments.get("prefix", "")
	var limit := int(arguments.get("limit", 500))
	var names: Array[String] = []
	for property in ProjectSettings.get_property_list():
		var name: String = property["name"]
		if name.contains("/") and name.begins_with(prefix):
			names.append(name)
	names.sort()
	var settings := {}
	for name in names.slice(0, limit):
		settings[name] = ValueCodec.encode(ProjectSettings.get_setting(name))
	return {"settings": settings, "truncated": names.size() > limit}


func install_agent_skill(arguments: Dictionary, _request: Request) -> Variant:
	return _install_skill.call(arguments.get("overwrite", false))


func set_project_setting(arguments: Dictionary, _request: Request) -> Variant:
	var name: String = arguments["name"]
	if NAME_PATTERN.search(name) == null:
		return ToolError.fail("INVALID_NAME", "name must be segments of letters, digits and _ joined by /, such as application/run/main_scene")
	var lower := name.to_lower()
	# editor/ holds the play-mode command line (main_run_args), which can write outside the project.
	for prefix in PROTECTED_PREFIXES:
		if lower.begins_with(prefix):
			if prefix == "editor_plugins/":
				return ToolError.fail("PROTECTED_SETTING", name + " cannot be changed through this tool; use enable_plugin or disable_plugin")
			return ToolError.fail("PROTECTED_SETTING", name + " cannot be changed through this tool")
	var raw: Variant = arguments["value"]
	var problem := _path_problem(name, raw)
	if not problem.is_empty():
		return problem
	if _has_control_character(raw):
		return ToolError.fail("INVALID_VALUE", "value must not contain control characters")
	var info := {"name": name, "type": _json_type(raw)}
	var known := ProjectSettings.has_setting(name)
	if known:
		for property in ProjectSettings.get_property_list():
			if property["name"] == name:
				info = property
				break
	var decoded := ValueDecoder.decode(raw, info)
	if decoded.has("error"):
		return decoded
	var previous: Variant = ProjectSettings.get_setting(name) if known else null
	ProjectSettings.set_setting(name, decoded["value"])
	var err := ProjectSettings.save()
	if err != OK:
		ProjectSettings.set_setting(name, previous)
		return ToolError.fail("SAVE_FAILED", "Could not write project.godot (%s)" % error_string(err))
	return {
		"name": name,
		"previous": ValueCodec.encode(previous) if known else null,
		"value": ValueCodec.encode(ProjectSettings.get_setting(name)),
	}


# The declared type of a setting that does not exist yet: whatever the JSON value is.
func _json_type(raw: Variant) -> int:
	if raw is float:
		return TYPE_INT if raw == floorf(raw) and absf(raw) < ValueDecoder.MAX_SAFE_INT else TYPE_FLOAT
	return typeof(raw)


# Settings that name a scene or script run it when the game starts, so their paths get the usual checks.
func _path_problem(name: String, raw: Variant) -> Dictionary:
	if not raw is String:
		return {}
	if name == "application/run/main_scene" and raw != "":
		return _checked_target(raw, ["tscn", "scn"])
	if name.begins_with("autoload/"):
		return _checked_target(raw.trim_prefix("*"), ["tscn", "scn", "gd", "cs"])
	return {}


# The editor stores these as res:// paths or uid:// references; a uid is resolved and its path checked.
func _checked_target(target: String, extensions: Array[String]) -> Dictionary:
	if target.begins_with("uid://"):
		var id := ResourceUID.text_to_id(target)
		if id == ResourceUID.INVALID_ID or not ResourceUID.has_id(id):
			return ToolError.fail("INVALID_VALUE", "No resource has the id " + target.left(80))
		target = ResourceUID.get_id_path(id)
	return ResPaths.check_file(target, extensions)


func _write(path: String, bytes: PackedByteArray) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(bytes)
	var err := file.get_error()
	file.close()
	# Godot buffers small writes until close, and close ignores a failed flush, so verify what landed.
	if err == OK and FileAccess.get_file_as_bytes(path) != bytes:
		err = ERR_FILE_CORRUPT
	if err != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	return err


func _has_control_character(value: Variant) -> bool:
	if value is String:
		for i in value.length():
			if value.unicode_at(i) < 32:
				return true
	elif value is Array:
		return value.any(_has_control_character)
	elif value is Dictionary:
		for key: Variant in value:
			if _has_control_character(key) or _has_control_character(value[key]):
				return true
	return false
