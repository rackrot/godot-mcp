@tool
extends RefCounted

## import_assets, run_headless, build_dotnet and install_asset (D44, D46, D69). One job at a time per
## editor: while one runs, the next gets PROJECT_BUSY at once. run_headless and build_dotnet hand the
## FIFO back once validated, since they touch only their own child process (D37), and install_asset
## does too, since it is almost all network I/O; import_assets keeps the FIFO, since it drives the
## editor's own importer. build_dotnet is always listed. Without exactly one root csproj
## (D15) its call fails with FILE_NOT_FOUND or AMBIGUOUS_MATCH, so a csproj added mid-session needs no restart.

const AssetInstaller := preload("../asset_installer.gd")
const JobRunner := preload("../job_runner.gd")
const LogBuffer := preload("../log_buffer.gd")
const OutputParser := preload("../output_parser.gd")
const Request := preload("../request.gd")
const ResPaths := preload("../res_paths.gd")
const ToolError := preload("../tool_error.gd")

# The transport's budget is the job's timeout plus this (D37).
const BUDGET_SLACK_MS := 10000
const SCAN_RETRIES := 5
const MAX_USER_ARGS := 64
const MAX_USER_ARG_CHARS := 1024

# A build configuration name. It can't start with `-`, so it never reads as a dotnet switch.
static var _CONFIGURATION := RegEx.create_from_string("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}\\z")

enum Wait { DONE, TIMED_OUT, CANCELLED }

# Held here because handler Callables don't keep it alive.
var _log: LogBuffer
var _runner := JobRunner.new()
var _busy := false
# The running install_asset's request, cancelled when the plugin unloads.
var _install_request: Request


func _init(log: LogBuffer) -> void:
	_log = log


func tools() -> Array[Dictionary]:
	var definitions: Array[Dictionary] = [
		{
			"name": "import_assets",
			"description": "Make the editor import new or changed asset files (images, models, audio) now, by rescanning the project, and report the errors and warnings it logged. Call this after adding or changing assets, before run_headless or play_scene. `timedOut` is true when the import was still running at the deadline; it carries on in the editor, as it does when the request is cancelled. `truncated` is true when the editor log or the diagnostics limit dropped entries (the counts stay exact). Other editor tools queue behind it and fail after 30 s. Only one job runs at a time (PROJECT_BUSY).",
			"inputSchema": {
				"type": "object",
				"properties": {"timeoutSec": {"type": "integer", "minimum": 1, "maximum": 540, "description": "Default 120."}},
				"additionalProperties": false,
			},
			"handler": import_assets,
		},
		{
			"name": "run_headless",
			"description": "Run the project in a separate headless Godot process and return its captured output and parsed errors. Give `scene` (a .tscn or .scn) or `script` (a .gd run with -s, normally extending SceneTree), or neither for the main scene. Godot exits 0 after script errors, so check `ok`. `frames` quits after that many frames; without it the run lasts until the game quits or `timeoutSec`, when the process group is killed (`timedOut`, exitCode null). A game killed by signal N reports exitCode N, which Godot cannot tell from exit(N). A game that reads stdin waits for the timeout. The run uses the files on disk, so save first: `unsavedScenes` lists what the editor holds unsaved. It waits for a running import first. This runs the project's code (autoloads, scene and script code). Only one job runs at a time (PROJECT_BUSY); other tools except play_scene keep working meanwhile.",
			"inputSchema": {
				"type": "object",
				"properties": {
					"scene": {"type": "string", "description": "res:// path of a .tscn or .scn. Excludes `script`."},
					"script": {"type": "string", "description": "res:// path of a .gd. Excludes `scene`."},
					"frames": {"type": "integer", "minimum": 1, "description": "Quit after this many frames."},
					"userArgs": {"type": "array", "items": {"type": "string"}, "description": "Passed to the game after `--`; at most 64, each at most 1,024 characters."},
					"timeoutSec": {"type": "integer", "minimum": 1, "maximum": 540, "description": "Default 60."},
				},
				"additionalProperties": false,
			},
			"handler": run_headless,
		},
		{
			"name": "build_dotnet",
			"description": "Build the project's C# code with `dotnet build` of the one csproj in the project root, in a separate process, and return the parsed MSBuild errors and warnings. The root must hold exactly one csproj; none gives FILE_NOT_FOUND and several give AMBIGUOUS_MATCH. Paths under the project come back as res:// paths. `ok` is false after any error or a timeout. `outputTail` holds the end of the raw output, for failures with no diagnostic (a missing SDK, a NuGet restore without network). A build that exits nonzero without printing an error gets a BUILD_FAILED diagnostic. On a timeout the process group is killed (`timedOut`, exitCode null). Only the default Debug configuration refreshes the assembly that the editor and run_headless load; any other configuration only checks that the code compiles. The first build may need network access to restore NuGet packages. This runs the project's build code (MSBuild targets, analyzers, source generators). Only one job runs at a time (PROJECT_BUSY); other tools except play_scene keep working meanwhile.",
			"inputSchema": {
				"type": "object",
				"properties": {
					"configuration": {"type": "string", "description": "Default Debug, the only one the editor and run_headless use. Another name (letters, digits, `_`, `.` and `-`, at most 64, not starting with `-`) only checks that the code compiles."},
					"timeoutSec": {"type": "integer", "minimum": 1, "maximum": 540, "description": "Default 300."},
				},
				"additionalProperties": false,
			},
			"handler": build_dotnet,
		},
		{
			"name": "install_asset",
			"description": "Download an addon from the Godot Asset Library by its numeric id, install the archive's addons/ folders into res://addons/, and rescan. Only the record's current version is offered: `version` pins it, and `sha256` pins the download (the result always reports its SHA-256). Downloads only over https from GitHub and GitLab, checking every redirect. Files outside addons/ (project.godot, override.cfg, demos) are never written. Native code (GDExtension, shared libraries) is refused with NATIVE_CODE unless `allowNativeCode`; such an install skips its scan, since loading native code reloads every editor script, so restart the editor next. The archive's .import files are never written. An existing addon folder gives FILE_EXISTS unless `overwrite`, which keeps the old folder as a backup and refuses while a plugin in it is enabled. Plugins are not enabled: call enable_plugin. The addon is remote code (see Code runs in the editor in the skill). Only one job runs at a time (PROJECT_BUSY); other tools except play_scene keep working meanwhile.",
			"inputSchema": {
				"type": "object",
				"properties": {
					"assetId": {"type": "integer", "minimum": 1, "maximum": 2147483647, "description": "The asset's id, the number in its godotengine.org/asset-library/asset/<id> page."},
					"version": {"type": "string", "description": "Must equal the asset's current version_string, else VERSION_MISMATCH."},
					"sha256": {"type": "string", "description": "64 hex digits the download must hash to, else HASH_MISMATCH."},
					"overwrite": {"type": "boolean", "description": "Replace existing addon folders, keeping each old one as a backup. Default false."},
					"allowNativeCode": {"type": "boolean", "description": "Install GDExtensions and native libraries. The install then skips its scan, and the editor loads them at its next scan; restart the editor next. Default false."},
					"timeoutSec": {"type": "integer", "minimum": 1, "maximum": 540, "description": "Default 120."},
				},
				"required": ["assetId"],
				"additionalProperties": false,
			},
			"handler": install_asset,
		},
	]
	return definitions


## True while a job runs, for get_project_info.
func job_active() -> bool:
	return _busy


## Kills the running job's child and stops a running install; called when the plugin unloads.
func shutdown() -> void:
	_runner.kill()
	if _install_request != null:
		_install_request.cancelled = true


func import_assets(arguments: Dictionary, request: Request) -> Variant:
	if _busy:
		return _busy_error()
	var timeout_ms := int(arguments.get("timeoutSec", 120)) * 1000
	_busy = true
	request.extend_budget(timeout_ms + BUDGET_SLACK_MS)
	var result: Variant = await _import(timeout_ms, request)
	_busy = false
	return result


func run_headless(arguments: Dictionary, request: Request) -> Variant:
	var launch := _launch_args(arguments)
	if launch.has("error"):
		return launch
	if _busy:
		return _busy_error()
	var timeout_ms := int(arguments.get("timeoutSec", 60)) * 1000
	_busy = true
	request.extend_budget(timeout_ms + BUDGET_SLACK_MS, true)
	var result: Variant = await _run(launch["args"], timeout_ms, request)
	_busy = false
	return result


func build_dotnet(arguments: Dictionary, request: Request) -> Variant:
	var configuration: String = arguments.get("configuration", "Debug")
	if _CONFIGURATION.search(configuration) == null:
		return ToolError.fail("INVALID_ARGUMENT", "configuration must be 1-64 letters, digits, `_`, `.` or `-`, and not start with `-`")
	# The csproj may have come or gone since the editor started.
	var csprojs := ResPaths.root_csprojs()
	if csprojs.is_empty():
		return ToolError.fail("FILE_NOT_FOUND", "There is no .csproj in the project root")
	if csprojs.size() > 1:
		return ToolError.fail("AMBIGUOUS_MATCH", "The project root holds %d .csproj files (%s); build_dotnet needs exactly one" % [csprojs.size(), ", ".join(csprojs)])
	if _busy:
		return _busy_error()
	var root := ProjectSettings.globalize_path("res://").rstrip("/")
	# An absolute csproj path can't read as a switch. env -C gives the child its cwd and variables without changing the editor's own.
	var command := PackedStringArray([
		"/usr/bin/env", "-C", root,
		"DOTNET_NOLOGO=1", "DOTNET_CLI_TELEMETRY_OPTOUT=1", "MSBUILDDISABLENODEREUSE=1",
		"dotnet", "build", root.path_join(csprojs[0]),
		"-c", configuration, "-nologo", "-v:q", "-tl:off", "-clp:NoSummary", "-nodeReuse:false", "-p:UseSharedCompilation=false",
	])
	var timeout_ms := int(arguments.get("timeoutSec", 300)) * 1000
	_busy = true
	request.extend_budget(timeout_ms + BUDGET_SLACK_MS, true)
	var result: Variant = await _runner.build(command, root, timeout_ms, request)
	_busy = false
	return result


func install_asset(arguments: Dictionary, request: Request) -> Variant:
	if arguments.has("sha256") and not AssetInstaller.is_sha256(arguments["sha256"]):
		return ToolError.fail("INVALID_ARGUMENT", "sha256 must be 64 hex digits")
	if _busy:
		return _busy_error()
	var timeout_ms := int(arguments.get("timeoutSec", 120)) * 1000
	_busy = true
	_install_request = request
	request.extend_budget(timeout_ms + BUDGET_SLACK_MS, true)
	var started := Time.get_ticks_msec()
	# A local, so the installer outlives its awaits.
	var installer := AssetInstaller.new(request, started + timeout_ms)
	var result: Dictionary = await installer.install(arguments)
	if not result.has("error"):
		result = await _after_install(result, started, timeout_ms, request)
	_install_request = null
	_busy = false
	return result


# Scans the installed files in, as import_assets does, and adds what the scan logged. Not after native
# code: the scan that loads a new GDExtension reloads every editor script, which cancels this handler and
# every other suspended one, so the call would never answer and the job slot would stay taken (4.7.2).
func _after_install(result: Dictionary, started: int, timeout_ms: int, request: Request) -> Dictionary:
	if result["nativeCode"]:
		result["warnings"].append("Not scanned, because the archive holds native code. Restart the editor next: the next filesystem scan (import_assets, another install_asset, a focus change in a windowed editor, or a restart) loads it and reloads every editor script. A call or job running then never answers, and the job slot (every job, plus play_scene) stays taken until the editor restarts")
		result.merge({"diagnostics": [], "errorCount": 0, "warningCount": 0, "truncated": false, "ok": true})
		return result
	var cursor := _log.seq()
	var before := _log.totals()
	var waited := await _scan(started, timeout_ms, request)
	if waited == Wait.CANCELLED:
		return ToolError.fail("CANCELLED", "The request was cancelled after %s was installed; the editor's scan carries on" % ", ".join(PackedStringArray(result["addons"])))
	var report := _scan_report(cursor, before)
	if waited == Wait.TIMED_OUT:
		result["warnings"].append("The editor was still scanning the new files at the deadline; it carries on")
	result.merge(report)
	result["ok"] = waited == Wait.DONE and report["errorCount"] == 0
	return result


# {args} or a tool failure. User arguments follow `--`, so the engine never reads them as its own flags.
func _launch_args(arguments: Dictionary) -> Dictionary:
	if arguments.has("scene") and arguments.has("script"):
		return ToolError.fail("INVALID_ARGUMENT", "scene and script are mutually exclusive")
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://").rstrip("/")])
	if arguments.has("scene"):
		var scene: String = arguments["scene"]
		var problem := ResPaths.check_file(scene, ["tscn", "scn"])
		if not problem.is_empty():
			return problem
		args.append(scene)
	if arguments.has("script"):
		var script: String = arguments["script"]
		var problem := ResPaths.check_file(script, ["gd"])
		if not problem.is_empty():
			return problem
		args.append_array(["-s", script])
	if arguments.has("frames"):
		args.append_array(["--quit-after", str(int(arguments["frames"]))])
	var user_args: Array = arguments.get("userArgs", [])
	if user_args.size() > MAX_USER_ARGS:
		return ToolError.fail("INVALID_ARGUMENT", "userArgs has more than %d entries" % MAX_USER_ARGS)
	for user_arg: String in user_args:
		if user_arg.length() > MAX_USER_ARG_CHARS:
			return ToolError.fail("INVALID_ARGUMENT", "A userArgs entry is longer than %d characters" % MAX_USER_ARG_CHARS)
	if not user_args.is_empty():
		args.append("--")
		args.append_array(PackedStringArray(user_args))
	return {"args": args}


func _run(args: PackedStringArray, timeout_ms: int, request: Request) -> Variant:
	var started := Time.get_ticks_msec()
	var files := EditorInterface.get_resource_filesystem()
	var waited := await _wait(func() -> bool: return not _filesystem_busy(files), started, timeout_ms, request)
	if waited == Wait.TIMED_OUT:
		return ToolError.fail("IMPORT_IN_PROGRESS", "The editor was still importing after %d s; retry, or call import_assets" % (timeout_ms / 1000))
	if waited == Wait.CANCELLED:
		return ToolError.fail("CANCELLED", "The request was cancelled")
	var unsaved := Array(EditorInterface.get_unsaved_scenes())
	var result := await _runner.run(args, timeout_ms - (Time.get_ticks_msec() - started), request)
	if not result.has("error"):
		result["unsavedScenes"] = unsaved
	return result


func _import(timeout_ms: int, request: Request) -> Variant:
	var started := Time.get_ticks_msec()
	var cursor := _log.seq()
	var before := _log.totals()
	var waited := await _scan(started, timeout_ms, request)
	# A cancelled import stops waiting; the scan itself carries on in the editor.
	if waited == Wait.CANCELLED:
		return ToolError.fail("CANCELLED", "The request was cancelled; the editor's scan carries on")
	var report := _scan_report(cursor, before)
	report.merge({
		"ok": waited == Wait.DONE and report["errorCount"] == 0,
		"durationMs": Time.get_ticks_msec() - started,
		"timedOut": waited == Wait.TIMED_OUT,
	})
	return report


# Rescans the project and waits until the editor has applied the scan and reimported what it found,
# for import_assets and install_asset (D69). is_scanning() turns false when the scan thread ends, before
# the editor has applied the results and reimported the changed files (A14, refined), so the import is
# done at the next filesystem_changed.
func _scan(started: int, timeout_ms: int, request: Request) -> Wait:
	var files := EditorInterface.get_resource_filesystem()
	# scan() does nothing while a scan is running, and that scan may predate the new files, so let a
	# running one finish first.
	var waited := await _wait(func() -> bool: return not _filesystem_busy(files), started, timeout_ms, request)
	if waited != Wait.DONE:
		return waited
	var changed := [false]
	var on_changed := func() -> void: changed[0] = true
	files.filesystem_changed.connect(on_changed)
	# scan() also does nothing while the previous scan's thread is still being collected, and that
	# scan's own filesystem_changed must not count, so judge each call only by its own effect.
	var retries := 0
	while true:
		changed[0] = false
		files.scan()
		if changed[0] or _filesystem_busy(files) or retries >= SCAN_RETRIES:
			break
		retries += 1
		if not await request.next_frame():
			waited = Wait.CANCELLED
			break
	if waited == Wait.DONE:
		waited = await _wait(func() -> bool: return changed[0] and not _filesystem_busy(files), started, timeout_ms, request)
	files.filesystem_changed.disconnect(on_changed)
	return waited


# {diagnostics, errorCount, warningCount, truncated} for the errors and warnings logged since `cursor`
# (from _log.seq()), with `before` from _log.totals() taken at the same time.
func _scan_report(cursor: int, before: Dictionary) -> Dictionary:
	var diagnostics: Array[Dictionary] = []
	var chars := 0
	# The counts come from the log's running totals, which its ring can't forget; the entries may be fewer.
	var after := _log.totals()
	var truncated := _log.evicted_since(cursor)
	for entry in _log.errors_since(cursor, true):
		var message := String(entry["message"]).left(OutputParser.MAX_LINE_CHARS)
		chars += message.length() + String(entry.get("file", "")).length()
		if diagnostics.size() >= OutputParser.MAX_DIAGNOSTICS or chars > OutputParser.MAX_DIAGNOSTIC_CHARS:
			truncated = true
			break
		var is_error: bool = entry["level"] == "error"
		var item := {"severity": entry["level"], "kind": "ERROR" if is_error else "WARNING", "message": message}
		if entry.get("file", "") != "":
			item["file"] = entry["file"]
			item["line"] = entry["line"]
		diagnostics.append(item)
	return {
		"diagnostics": diagnostics,
		"errorCount": after["errors"] - before["errors"],
		"warningCount": after["warnings"] - before["warnings"],
		"truncated": truncated,
	}


# is_scanning() is false while the editor still reimports what the scan found (is_importing).
static func _filesystem_busy(files: EditorFileSystem) -> bool:
	return files.is_scanning() or files.is_importing()


# Waits frame by frame until `done` returns true, `timeout_ms` after `started`, or the request is cancelled.
func _wait(done: Callable, started: int, timeout_ms: int, request: Request) -> Wait:
	while not done.call():
		if Time.get_ticks_msec() - started >= timeout_ms:
			return Wait.TIMED_OUT
		if not await request.next_frame():
			return Wait.CANCELLED
	return Wait.DONE


func _busy_error() -> Dictionary:
	return ToolError.fail("PROJECT_BUSY", "Another job (run_headless, import_assets, build_dotnet or install_asset) is running; retry when get_project_info reports jobActive false")
