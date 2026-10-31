@tool
extends EditorPlugin

const CaptureDebugger := preload("capture_debugger.gd")
const HttpServer := preload("http_server.gd")
const LogBuffer := preload("log_buffer.gd")
const McpServer := preload("mcp_server.gd")
const EditorTools := preload("tools/editor_tools.gd")
const JobTools := preload("tools/job_tools.gd")
const NodeTools := preload("tools/node_tools.gd")
const ProjectTools := preload("tools/project_tools.gd")
const SceneTools := preload("tools/scene_tools.gd")
const ScriptTools := preload("tools/script_tools.gd")
const Setup := preload("setup.gd")
const TreeTools := preload("tools/tree_tools.gd")

const PORT_SETTING := "godot_mcp/server/port"
const PORT_FIRST := 6550
const PORT_LAST := 6649
const STATE_DIR := "res://.godot/godot_mcp"
const MENU_ITEM := "MCP: install agent skill / show config"

var _capture: CaptureDebugger
var _http: HttpServer
var _mcp: McpServer
var _log: LogBuffer
var _jobs: JobTools
var _setup: Setup


func _enter_tree() -> void:
	add_tool_menu_item(MENU_ITEM, _on_setup_menu)
	_setup = Setup.new(0)
	_log = LogBuffer.new()
	OS.add_logger(_log)
	var tcp := TCPServer.new()
	var port := _listen(tcp)
	if port == 0:
		return
	var dir := ProjectSettings.globalize_path(STATE_DIR)
	var token := Crypto.new().generate_random_bytes(32).hex_encode()
	for file: Array in [[".gitignore", "*\n"], ["headers.json", JSON.stringify({"Authorization": "Bearer " + token})]]:
		var err := _publish(dir, file[0], file[1])
		if err != OK:
			tcp.stop()
			push_error("godot_mcp: cannot write %s (%s); the MCP server is not running." % [dir.path_join(file[0]), error_string(err)])
			return
	var version := _addon_version()
	# Only a server that is serving reports its port, so the menu and the tool stay NOT_LISTENING until now.
	_setup = Setup.new(port)
	# Callables don't keep RefCounted targets alive, so the plugin holds the MCP server.
	_jobs = JobTools.new(_log)
	_capture = CaptureDebugger.new()
	add_debugger_plugin(_capture)
	_mcp = McpServer.new(version, [ProjectTools.new(version, _jobs.job_active, _setup.install), SceneTools.new(_log), NodeTools.new(), ScriptTools.new(_log), TreeTools.new(), EditorTools.new(_log, _jobs.job_active, _cfg_path(), _capture), _jobs])
	_http = HttpServer.new(tcp, port, token, _mcp.handle, _mcp.ingress, _mcp.done)
	print("godot_mcp: serving http://127.0.0.1:%d/mcp" % port)


func _exit_tree() -> void:
	remove_tool_menu_item(MENU_ITEM)
	_setup = null
	if _jobs != null:
		_jobs.shutdown()
		_jobs = null
	if _capture != null:
		remove_debugger_plugin(_capture)
		_capture = null
	if _log != null:
		OS.remove_logger(_log)
		_log = null
	if _http != null:
		_http.stop()
		_http = null
		_mcp = null


func _on_setup_menu() -> void:
	_setup.show_dialog(EditorInterface.get_base_control())


func _process(_delta: float) -> void:
	if _http != null:
		_http.poll()


# Listens on the project's fixed port (D30), choosing and saving one on first load. Returns 0 on failure.
func _listen(tcp: TCPServer) -> int:
	if ProjectSettings.has_setting(PORT_SETTING):
		var port: Variant = ProjectSettings.get_setting(PORT_SETTING)
		if typeof(port) != TYPE_INT or port < 1 or port > 65535:
			push_error("godot_mcp: %s must be a port number; the MCP server is not running." % PORT_SETTING)
			return 0
		var err := tcp.listen(port, "127.0.0.1")
		if err != OK:
			push_error("godot_mcp: cannot listen on 127.0.0.1:%d (%s); the MCP server is not running." % [port, error_string(err)])
			return 0
		return port
	for port in range(PORT_FIRST, PORT_LAST + 1):
		if tcp.listen(port, "127.0.0.1") != OK:
			continue
		ProjectSettings.set_setting(PORT_SETTING, port)
		var err := ProjectSettings.save()
		if err != OK:
			tcp.stop()
			push_error("godot_mcp: cannot save %s (%s); the MCP server is not running." % [PORT_SETTING, error_string(err)])
			return 0
		return port
	push_error("godot_mcp: no free port in %d-%d; set %s. The MCP server is not running." % [PORT_FIRST, PORT_LAST, PORT_SETTING])
	return 0


# Writes dir/name owner-only and atomically (D29): refuses links, chmods the .tmp before any content, then renames.
static func _publish(dir: String, name: String, text: String) -> Error:
	var err := DirAccess.make_dir_recursive_absolute(dir)
	if err != OK:
		return err
	var access := DirAccess.open(dir)
	if access == null:
		return DirAccess.get_open_error()
	var path := dir.path_join(name)
	var tmp := path + ".tmp"
	for candidate: String in [dir.get_base_dir(), dir, path, tmp]:
		if access.is_link(candidate):
			return ERR_FILE_CANT_WRITE
	# Owner-only directory, so nobody else can open a file in it during the window before its chmod.
	err = FileAccess.set_unix_permissions(dir, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER | FileAccess.UNIX_EXECUTE_OWNER)
	if err != OK:
		return err
	if FileAccess.file_exists(tmp):
		err = DirAccess.remove_absolute(tmp)
		if err != OK:
			return err
	# The editor's safe save makes WRITE go through its own temp file and rename, which would replace
	# the chmodded inode. So create the file empty, chmod it, then fill it through READ_WRITE.
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.close()
	err = FileAccess.set_unix_permissions(tmp, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	if err == OK:
		file = FileAccess.open(tmp, FileAccess.READ_WRITE)
		if file == null:
			err = FileAccess.get_open_error()
		else:
			file.store_string(text)
			err = file.get_error()
			file.close()
	if err != OK:
		DirAccess.remove_absolute(tmp)
		return err
	return DirAccess.rename_absolute(tmp, path)


func _cfg_path() -> String:
	return (get_script() as Script).resource_path.get_base_dir().path_join("plugin.cfg")


func _addon_version() -> String:
	var cfg := ConfigFile.new()
	var path := _cfg_path()
	var err := cfg.load(path)
	if err != OK:
		push_error("godot_mcp: cannot read %s (%s)." % [path, error_string(err)])
	return cfg.get_value("plugin", "version", "unknown")
