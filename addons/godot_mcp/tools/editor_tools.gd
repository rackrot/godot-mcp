@tool
extends RefCounted

const LogBuffer := preload("../log_buffer.gd")
const Request := preload("../request.gd")
const ResPaths := preload("../res_paths.gd")
const SceneAccess := preload("../scene_access.gd")
const ToolError := preload("../tool_error.gd")

# How long play_scene and stop_scene wait for the editor to start or stop the game.
const WAIT_MS := 10000

# Held here because handler Callables don't keep it alive.
var _log: LogBuffer
# func() -> bool: whether a job (run_headless, import_assets, build_dotnet) is running.
var _job_active: Callable
# This addon's own plugin.cfg: disabling it would free the plugin whose handler is on the stack (D51).
var _own_cfg: String


func _init(log: LogBuffer, job_active: Callable, own_cfg: String) -> void:
	_log = log
	_job_active = job_active
	_own_cfg = own_cfg


func tools() -> Array[Dictionary]:
	return [
		{
			"name": "get_editor_log",
			"description": "Read the editor's log (errors, warnings and printed output) since the plugin loaded. Pass the previous call's nextSince as `since` to read only newer entries. `dropped` counts entries the 1,000-entry ring lost before you read them; `reset` is true when `since` was ahead of the log (the plugin reloaded) and the read started over.",
			"inputSchema": {
				"type": "object",
				"properties": {
					"since": {"type": "integer", "minimum": 0, "description": "Cursor; default 0 reads from the oldest entry."},
					"level": {"type": "string", "enum": ["info", "warning", "error"], "description": "Lowest level to return; default info."},
					"limit": {"type": "integer", "minimum": 1, "maximum": 1000, "description": "Default 200."},
				},
				"additionalProperties": false,
			},
			"annotations": {"readOnlyHint": true},
			"handler": get_editor_log,
		},
		{
			"name": "play_scene",
			"description": "Run a scene in the editor's own play mode, as a human would with F5/F6/F7. The editor saves its modified scenes first (its run setting). The game's output is not captured; use run_headless for that. Returns once the game has started.",
			"inputSchema": {
				"type": "object",
				"properties": {
					"mode": {"type": "string", "enum": ["main", "current", "custom"], "description": "main runs the project's main scene, current the edited scene, custom the scene at `path`."},
					"path": {"type": "string", "description": "res:// path of the scene; required for custom."},
				},
				"required": ["mode"],
				"additionalProperties": false,
			},
			"handler": play_scene,
		},
		{
			"name": "stop_scene",
			"description": "Stop the scene started by play_scene, or one a person started in the editor. `stopped` is false when nothing was playing.",
			"inputSchema": {"type": "object", "properties": {}, "additionalProperties": false},
			"handler": stop_scene,
		},
		{
			"name": "enable_plugin",
			"description": "Enable an editor plugin under res://addons/ in the open editor, without a restart, and write project.godot. Runs the plugin's _enter_tree and _enable_plugin (see Code runs in the editor). `changed` is false when it was already enabled. A plugin with a C# script needs build_dotnet first. get_project_info lists the plugins.",
			"inputSchema": {
				"type": "object",
				"properties": {"name": {"type": "string", "minLength": 1, "description": "The plugin's folder under res://addons/, such as marker or vendor/foo."}},
				"required": ["name"],
				"additionalProperties": false,
			},
			"handler": enable_plugin,
		},
		{
			"name": "disable_plugin",
			"description": "Disable an editor plugin under res://addons/ in the open editor and write project.godot. Runs the plugin's _disable_plugin and _exit_tree. `changed` is false when it was already disabled. The godot_mcp addon itself is refused.",
			"inputSchema": {
				"type": "object",
				"properties": {"name": {"type": "string", "minLength": 1, "description": "The plugin's folder under res://addons/, such as marker or vendor/foo."}},
				"required": ["name"],
				"additionalProperties": false,
			},
			"handler": disable_plugin,
		},
	]


func get_editor_log(arguments: Dictionary, _request: Request) -> Variant:
	return _log.read(int(arguments.get("since", 0)), arguments.get("level", "info"), int(arguments.get("limit", 200)))


func play_scene(arguments: Dictionary, request: Request) -> Variant:
	# Playing makes the editor run its own MSBuild, which would compete with a build_dotnet job.
	if _job_active.call():
		return ToolError.fail("PROJECT_BUSY", "A job (run_headless, import_assets or build_dotnet) is running; retry when get_project_info reports jobActive false")
	var mode: String = arguments["mode"]
	# Running makes the editor save every modified scene, bypassing save_scene's checks.
	for unsaved in EditorInterface.get_unsaved_scenes():
		# The editor skips a scene with no file yet, so it cannot be auto-saved to a bad path.
		if unsaved == "":
			continue
		var unsafe := SceneAccess.save_problem(unsaved)
		if not unsafe.is_empty():
			return ToolError.fail("UNSAFE_AUTOSAVE", "Running would auto-save %s, which cannot be saved safely: %s" % [unsaved, unsafe["error"]["message"]])
	if mode == "custom":
		if not arguments.has("path"):
			return ToolError.fail("INVALID_ARGUMENT", "mode custom needs path")
		var path: String = arguments["path"]
		var problem := ResPaths.check_file(path, ["tscn", "scn"])
		if not problem.is_empty():
			return problem
		EditorInterface.play_custom_scene(path)
	elif arguments.has("path"):
		return ToolError.fail("INVALID_ARGUMENT", "path is only for mode custom")
	elif mode == "current":
		if EditorInterface.get_edited_scene_root() == null:
			return SceneAccess.no_scene()
		EditorInterface.play_current_scene()
	else:
		EditorInterface.play_main_scene()
	if not await _wait_until(request, true):
		return ToolError.fail("PLAY_FAILED", "The game did not start within %d ms; see get_editor_log" % WAIT_MS)
	return {"playingScene": EditorInterface.get_playing_scene()}


func stop_scene(_arguments: Dictionary, request: Request) -> Variant:
	var was_playing := EditorInterface.is_playing_scene()
	EditorInterface.stop_playing_scene()
	if not await _wait_until(request, false):
		return ToolError.fail("STOP_FAILED", "The game did not stop within %d ms; see get_editor_log" % WAIT_MS)
	return {"stopped": was_playing}


func enable_plugin(arguments: Dictionary, _request: Request) -> Variant:
	return _set_plugin(arguments["name"], true)


func disable_plugin(arguments: Dictionary, _request: Request) -> Variant:
	return _set_plugin(arguments["name"], false)


# D51. The editor reports a failed toggle only through a dialog, so this checks the state afterwards.
func _set_plugin(name: String, enabled: bool) -> Variant:
	# Pass the checked full path to the setter, never `name`: it takes any res:// string verbatim.
	var path := "res://addons/%s/plugin.cfg" % name
	# Before check_file, so a case variant that doesn't exist on a case-sensitive disk is still refused.
	if path.to_lower() == _own_cfg.to_lower():
		return ToolError.fail("PROTECTED_PATH", "The godot_mcp addon cannot be enabled or disabled through this tool: disabling it would free the plugin that is answering")
	var problem := ResPaths.check_file(path, ["cfg"])
	if not problem.is_empty():
		return problem
	var script_path := ""
	if enabled:
		var cfg := ConfigFile.new()
		var load_err := cfg.load(path)
		if load_err != OK:
			return ToolError.fail("PLUGIN_FAILED", "Cannot parse %s (%s)" % [path, error_string(load_err)])
		script_path = str(cfg.get_value("plugin", "script", ""))
		if script_path == "":
			return ToolError.fail("PLUGIN_FAILED", "%s has no plugin/script key" % path)
	if EditorInterface.is_plugin_enabled(path) == enabled:
		return {"name": name, "path": path, "enabled": enabled, "changed": false}
	var cursor := _log.seq()
	EditorInterface.set_plugin_enabled(path, enabled)
	if EditorInterface.is_plugin_enabled(path) != enabled:
		var lines: Array[String] = []
		for entry in _log.errors_since(cursor):
			lines.append("%s:%d %s" % [entry.get("file", ""), entry.get("line", 0), entry["message"]])
		var message := "The editor did not %s %s." % ["enable" if enabled else "disable", path]
		if not lines.is_empty():
			message += " Errors: " + "; ".join(lines.slice(0, 10))
		if script_path.get_extension().to_lower() == "cs":
			message += " The plugin script is C#; run build_dotnet first."
		return ToolError.fail("PLUGIN_FAILED", message)
	# The editor saves editor_plugins/enabled on a timer; write it now so it is on disk when this returns.
	var err := ProjectSettings.save()
	if err != OK:
		return ToolError.fail("SAVE_FAILED", "The plugin is %s in the editor, but project.godot could not be saved (%s)" % ["enabled" if enabled else "disabled", error_string(err)])
	return {"name": name, "path": path, "enabled": enabled, "changed": true}


# Waits for is_playing_scene() to become `playing`. False on timeout or cancellation.
func _wait_until(request: Request, playing: bool) -> bool:
	var deadline := Time.get_ticks_msec() + WAIT_MS
	while EditorInterface.is_playing_scene() != playing:
		if Time.get_ticks_msec() >= deadline or not await request.next_frame():
			return false
	return true
