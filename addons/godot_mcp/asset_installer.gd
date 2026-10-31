@tool
extends RefCounted

## One install_asset run (D62-D68): read an Asset Library record by id, download its archive over
## hand-checked hops, verify it, extract its addons/ subtree to a stage under .godot/ (which the editor
## never scans), and swap each addon into res://addons/ with a backup. Plugins are never enabled here.
## The caller scans afterwards. Every outcome removes the download and the stage.

const Request := preload("request.gd")
const ToolError := preload("tool_error.gd")
const ZipIndex := preload("zip_index.gd")

const API_BASE := "https://godotengine.org/asset-library/api"
## Test seam (D63): replaces API_BASE and adds its one origin to the hosts; plain http only to 127.0.0.1.
const API_ENV := "GODOT_MCP_ASSET_LIBRARY_URL"
const API_HOSTS: Array[String] = ["godotengine.org"]
const DOWNLOAD_HOSTS: Array[String] = [
	"github.com", "codeload.github.com", "release-assets.githubusercontent.com",
	"objects.githubusercontent.com", "gitlab.com",
]
const MAX_REDIRECTS := 5
const MAX_API_BYTES := 1024 * 1024
const MAX_DOWNLOAD_BYTES := 64 * 1024 * 1024
const KEEP_BACKUPS := 5
const STATE_DIR := "res://.godot/godot_mcp"
const ADDONS_DIR := "res://addons"
const PROTECTED_ADDON := "godot_mcp"
const NATIVE_EXTENSIONS: Array[String] = ["gdextension", "gdnlib", "so", "dll", "dylib", "a", "wasm"]
const MAX_NATIVE_LISTED := 10
const YIELD_BYTES := 8 * 1024 * 1024
const REDIRECT_CODES: Array[int] = [301, 302, 303, 307, 308]

# scheme://host[:port]/path with nothing that Godot's own URL parser would read differently: no
# userinfo, no IPv6 literal, and no space, backslash or control character anywhere.
static var _URL := RegEx.create_from_string("^([A-Za-z][A-Za-z0-9+.-]*)://([A-Za-z0-9.-]+)(?::([0-9]{1,5}))?((?:/[\\x21-\\x5b\\x5d-\\x7e]*)?)\\z")
static var _SHARED_LIBRARY := RegEx.create_from_string("\\.so(\\.[0-9]+)*\\z")
static var _HEX64 := RegEx.create_from_string("^[0-9A-Fa-f]{64}\\z")

var _request: Request
# Time.get_ticks_msec() past which a download stops.
var _deadline := 0
var _api_base := API_BASE
# scheme://host:port of the test seam, or "".
var _test_origin := ""
var _http: HTTPRequest
var _download := ""
var _stage := ""
var _warnings: Array[String] = []


func _init(request: Request, deadline: int) -> void:
	_request = request
	_deadline = deadline


static func is_sha256(text: String) -> bool:
	return _HEX64.search(text) != null


## The install result without the scan fields, or a tool failure. arguments as install_asset's schema.
func install(arguments: Dictionary) -> Dictionary:
	var result := await _install(arguments)
	_cleanup()
	return result


func _install(arguments: Dictionary) -> Dictionary:
	var settings := EditorInterface.get_editor_settings()
	# A21: 0 is Offline, 1 Online.
	if int(settings.get_setting("network/connection/network_mode")) == 0:
		return ToolError.fail("NETWORK_OFFLINE", "The editor is in offline mode (Editor Settings > Network > Connection > Network Mode)")
	var seam := OS.get_environment(API_ENV)
	if seam != "":
		var problem := _set_test_origin(seam)
		if not problem.is_empty():
			return problem
	var asset_id := int(arguments["assetId"])
	var api_url := "%s/asset/%d" % [_api_base, asset_id]
	var fetched := await _fetch(api_url, API_HOSTS, MAX_API_BYTES, "")
	if fetched.has("error"):
		return fetched
	var record := _record(fetched["body"], asset_id)
	if record.has("error"):
		return record
	var current: String = record["version_string"]
	if arguments.has("version") and arguments["version"] != current:
		return ToolError.fail("VERSION_MISMATCH", "Asset %d is at version %s; only the current version can be installed" % [asset_id, current])
	var dirs := _state_dirs()
	if dirs.has("error"):
		return dirs
	var token := Crypto.new().generate_random_bytes(8).hex_encode()
	_download = ProjectSettings.globalize_path("%s/downloads/%s.zip" % [STATE_DIR, token])
	var downloaded := await _fetch(record["download_url"], DOWNLOAD_HOSTS, MAX_DOWNLOAD_BYTES, _download)
	if downloaded.has("error"):
		return downloaded
	var file := FileAccess.open(_download, FileAccess.READ)
	if file == null:
		return ToolError.fail("DOWNLOAD_FAILED", "The download left no file (%s)" % error_string(FileAccess.get_open_error()))
	var bytes := file.get_length()
	var sha256 := _sha256(file)
	file.close()
	if arguments.has("sha256") and String(arguments["sha256"]).to_lower() != sha256:
		return ToolError.fail("HASH_MISMATCH", "The download's SHA-256 is %s, not the sha256 given" % sha256)
	var listed_hash: String = record["download_hash"]
	if is_sha256(listed_hash):
		if listed_hash.to_lower() != sha256:
			return ToolError.fail("HASH_MISMATCH", "The download's SHA-256 is %s, not the record's download_hash %s" % [sha256, listed_hash])
	elif listed_hash != "":
		_warnings.append("The record's download_hash is not a SHA-256 hex digest, so it was not compared")
	var plan := _plan(arguments)
	if plan.has("error"):
		return plan
	_stage = "%s/staging/%s" % [STATE_DIR, token]
	var staged := await _extract(plan)
	if staged.has("error"):
		return staged
	if _request.cancelled:
		return ToolError.fail("CANCELLED", "The request was cancelled; nothing was installed")
	# Again, with no await before the swap: the project may have changed while the stage was written.
	var targets := _check_targets(plan["addons"].keys(), arguments.get("overwrite", false))
	if targets.has("error"):
		return targets
	var swapped := _swap(plan["addons"])
	if swapped.has("error"):
		return swapped
	_prune_backups()
	var names: Array = plan["addons"].keys()
	names.sort()
	return {
		"assetId": asset_id,
		"title": record["title"],
		"versionString": current,
		"godotVersion": record["godot_version"],
		"license": record["cost"],
		"downloadUrl": record["download_url"],
		"finalUrl": downloaded["url"],
		"sha256": sha256,
		"bytes": bytes,
		"addons": names,
		"plugins": plan["plugins"],
		"files": plan["files"],
		"needsDotnetBuild": plan["needsDotnetBuild"],
		"backups": swapped["backups"],
		"warnings": _warnings,
	}


func _set_test_origin(seam: String) -> Dictionary:
	var parts := _URL.search(seam)
	if parts == null:
		return ToolError.fail("UNTRUSTED_SOURCE", "%s is not a plain http(s) URL" % API_ENV)
	var scheme := parts.get_string(1).to_lower()
	var host := parts.get_string(2).to_lower()
	if scheme != "https" and not (scheme == "http" and host == "127.0.0.1"):
		return ToolError.fail("UNTRUSTED_SOURCE", "%s must be https, or http to 127.0.0.1" % API_ENV)
	_test_origin = _origin(parts)
	_api_base = seam.trim_suffix("/")
	return {}


# scheme://host:port with the port always written, for comparing origins.
static func _origin(parts: RegExMatch) -> String:
	var scheme := parts.get_string(1).to_lower()
	var port := parts.get_string(3)
	if port == "":
		port = "443" if scheme == "https" else "80"
	return "%s://%s:%d" % [scheme, parts.get_string(2).to_lower(), int(port)]


# {} when `url` may be fetched: https on port 443 to one of `hosts`, matched exactly, or the test seam's origin (D63).
func _check_url(url: String, hosts: Array[String]) -> Dictionary:
	var parts := _URL.search(url)
	if parts == null:
		return ToolError.fail("UNTRUSTED_SOURCE", "Refused %s: not a plain http(s) URL without credentials" % url.c_escape().left(300))
	if _test_origin != "" and _origin(parts) == _test_origin:
		return {}
	var host := parts.get_string(2).to_lower()
	if parts.get_string(1).to_lower() != "https" or _origin(parts) != "https://%s:443" % host:
		return ToolError.fail("UNTRUSTED_SOURCE", "Refused %s: only https on port 443 is allowed" % url.left(300))
	if host not in hosts:
		return ToolError.fail("UNTRUSTED_SOURCE", "Refused %s: %s is not an allowed host (%s)" % [url.left(300), host, ", ".join(hosts)])
	return {}


# GETs `url`, following at most MAX_REDIRECTS redirects by hand and checking every hop before it
# connects. Saves the body to `file` when given. Returns {url (the last hop), body} or a tool failure.
func _fetch(url: String, hosts: Array[String], limit: int, file: String) -> Dictionary:
	for _hop in MAX_REDIRECTS + 1:
		var problem := _check_url(url, hosts)
		if not problem.is_empty():
			return problem
		var remaining := _deadline - Time.get_ticks_msec()
		if remaining <= 0:
			return ToolError.fail("DOWNLOAD_FAILED", "Timed out before fetching %s" % url)
		_http = HTTPRequest.new()
		# HTTPRequest would follow a redirect to any host, so a 3xx ends the request here (A22).
		_http.max_redirects = 0
		_http.body_size_limit = limit
		_http.accept_gzip = false
		_http.download_file = file
		_http.timeout = remaining / 1000.0
		var settings := EditorInterface.get_editor_settings()
		var proxy_host := String(settings.get_setting("network/http_proxy/host"))
		if proxy_host != "":
			var proxy_port := int(settings.get_setting("network/http_proxy/port"))
			_http.set_http_proxy(proxy_host, proxy_port)
			_http.set_https_proxy(proxy_host, proxy_port)
		EditorInterface.get_base_control().add_child(_http)
		var outcome := []
		_http.request_completed.connect(func(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
			outcome.append_array([result, code, headers, body]))
		var err := _http.request(url)
		if err != OK:
			_free_http()
			return ToolError.fail("DOWNLOAD_FAILED", "Cannot request %s (%s)" % [url, error_string(err)])
		# Polled, not awaited, so a cancel or the deadline can stop it.
		while outcome.is_empty():
			if not await _request.next_frame():
				_free_http()
				return ToolError.fail("CANCELLED", "The request was cancelled; nothing was installed")
			if outcome.is_empty() and Time.get_ticks_msec() >= _deadline:
				_free_http()
				return ToolError.fail("DOWNLOAD_FAILED", "Timed out fetching %s" % url)
		_free_http()
		var result: int = outcome[0]
		var code: int = outcome[1]
		if result == HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
			return ToolError.fail("TOO_LARGE", "%s is over %d bytes" % [url, limit])
		if code in REDIRECT_CODES and (result == HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED or result == HTTPRequest.RESULT_SUCCESS):
			var location := _header(outcome[2], "location")
			if location == "":
				return ToolError.fail("DOWNLOAD_FAILED", "%s redirected without a Location" % url)
			url = _resolve(url, location)
			continue
		if result != HTTPRequest.RESULT_SUCCESS:
			return ToolError.fail("DOWNLOAD_FAILED", "Fetching %s failed (HTTPRequest result %d)" % [url, result])
		if code != 200:
			return ToolError.fail("DOWNLOAD_FAILED", "%s answered HTTP %d" % [url, code])
		return {"url": url, "body": outcome[3]}
	return ToolError.fail("DOWNLOAD_FAILED", "More than %d redirects" % MAX_REDIRECTS)


# Cancels and frees the running request; a cancelled download_file is removed by HTTPRequest.
func _free_http() -> void:
	if _http == null:
		return
	_http.cancel_request()
	_http.queue_free()
	_http = null


static func _header(headers: PackedStringArray, wanted: String) -> String:
	for line in headers:
		var colon := line.find(":")
		if colon > 0 and line.left(colon).strip_edges().to_lower() == wanted:
			return line.substr(colon + 1).strip_edges()
	return ""


# An absolute Location as given; a path-absolute one on the current origin. Anything else is returned
# as is and fails the hop check.
static func _resolve(current: String, location: String) -> String:
	if not location.begins_with("/") or location.begins_with("//"):
		return location
	var parts := _URL.search(current)
	return "%s://%s%s%s" % [parts.get_string(1), parts.get_string(2), ":" + parts.get_string(3) if parts.get_string(3) != "" else "", location]


# The record's fields, checked (D62, D63), or a tool failure.
func _record(body: PackedByteArray, asset_id: int) -> Dictionary:
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK or not json.data is Dictionary:
		return ToolError.fail("DOWNLOAD_FAILED", "The Asset Library's answer for asset %d is not a JSON object" % asset_id)
	var data: Dictionary = json.data
	var record := {}
	for key in ["type", "title", "version_string", "godot_version", "cost", "download_url", "download_hash"]:
		var value: Variant = data.get(key, "")
		record[key] = value if value is String else ""
	if record["type"] != "addon":
		return ToolError.fail("INCOMPATIBLE_ASSET", "Asset %d is of type %s; only addons can be installed" % [asset_id, record["type"]])
	var engine := Engine.get_version_info()
	var version: PackedStringArray = String(record["godot_version"]).split(".")
	if not version[0].is_valid_int() or int(version[0]) != engine["major"]:
		return ToolError.fail("INCOMPATIBLE_ASSET", "Asset %d is for Godot %s; this editor is %d.%d" % [asset_id, record["godot_version"], engine["major"], engine["minor"]])
	if version.size() > 1 and version[1].is_valid_int() and int(version[1]) > engine["minor"]:
		_warnings.append("The asset is for Godot %s, newer than this editor's %d.%d" % [record["godot_version"], engine["major"], engine["minor"]])
	if record["download_url"] == "":
		return ToolError.fail("DOWNLOAD_FAILED", "The record of asset %d has no download_url" % asset_id)
	return record


# The state folders under .godot/godot_mcp, checked to be real folders, not links, before and after
# they are made.
func _state_dirs() -> Dictionary:
	var paths: Array[String] = ["res://.godot", STATE_DIR, STATE_DIR + "/downloads", STATE_DIR + "/staging", STATE_DIR + "/backups"]
	for path in paths:
		if _is_link(path):
			return ToolError.fail("WRITE_FAILED", "%s is a symbolic link" % path)
	for path in paths.slice(2):
		var err := DirAccess.make_dir_recursive_absolute(path)
		if err != OK:
			return ToolError.fail("WRITE_FAILED", "Cannot make %s (%s)" % [path, error_string(err)])
		if _is_link(path):
			return ToolError.fail("WRITE_FAILED", "%s is a symbolic link" % path)
	return {}


static func _sha256(file: FileAccess) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	while file.get_position() < file.get_length():
		context.update(file.get_buffer(1024 * 1024))
	return context.finish().hex_encode()


# What the archive installs (D65-D68): {addons: {name: [entries, each with `inner`]}, plugins, files,
# needsDotnetBuild}, or a tool failure. Nothing is written yet.
func _plan(arguments: Dictionary) -> Dictionary:
	var index := ZipIndex.parse(_download)
	if index.has("error"):
		return index
	var entries: Array[Dictionary] = index["entries"]
	var names := PackedStringArray()
	for entry in entries:
		names.append(entry["name"])
	var zip := ZIPReader.new()
	var err := zip.open(_download)
	if err != OK:
		return ToolError.fail("ZIP_UNSAFE", "The archive is refused: ZIPReader cannot open it (%s)" % error_string(err))
	var listed := zip.get_files()
	zip.close()
	# Both parsers must agree on what is in the archive.
	if listed != names:
		return ToolError.fail("ZIP_UNSAFE", "The archive is refused: its central directory reads differently to ZIPReader")
	var base := _addons_base(names)
	if base == "":
		return ToolError.fail("INCOMPATIBLE_ASSET", "The archive has no addons/ folder at its root or under its one top folder")
	var addons := {}
	var plugins: Array[String] = []
	var native: Array[String] = []
	var needs_dotnet := false
	var files := 0
	var skipped := 0
	for entry in entries:
		var name: String = entry["path"]
		if not name.begins_with(base):
			continue
		var relative := name.substr(base.length())
		var addon := relative.get_slice("/", 0)
		if not relative.contains("/") and not entry["dir"]:
			skipped += 1
			continue
		if addon.to_lower() == PROTECTED_ADDON:
			return ToolError.fail("PROTECTED_PATH", "The archive holds addons/%s, which install_asset never replaces" % addon)
		var inner := relative.substr(addon.length() + 1)
		var item := entry.duplicate()
		item["inner"] = inner
		addons.get_or_add(addon, []).append(item)
		var lower := relative.to_lower()
		if _is_native(lower) and native.size() < MAX_NATIVE_LISTED:
			native.append("addons/" + relative)
		if entry["dir"]:
			continue
		files += 1
		if lower.get_extension() == "cs":
			needs_dotnet = true
		if relative.get_file() == "plugin.cfg":
			plugins.append(relative.get_base_dir())
	if skipped > 0:
		_warnings.append("%d file(s) directly in addons/ belong to no addon folder and were not installed" % skipped)
	if addons.is_empty():
		return ToolError.fail("INCOMPATIBLE_ASSET", "The archive's addons/ folder holds no addon folder")
	# Refused even with allowNativeCode: the scan that loads a new .gdextension (even one whose library
	# is missing) makes the editor reload every GDScript, which cancels this handler mid-await, so the call
	# never answers and the job slot stays taken until the editor restarts (verified on 4.7.2).
	if not native.is_empty():
		return ToolError.fail("NATIVE_CODE", "The archive holds native code: %s. install_asset does not install native code, even with allowNativeCode: the editor loads it at its next scan, and that load reloads every editor script, which would cancel this call. Install it by hand in the editor" % ", ".join(native))
	var targets := _check_targets(addons.keys(), arguments.get("overwrite", false))
	if targets.has("error"):
		return targets
	plugins.sort()
	return {"addons": addons, "plugins": plugins, "files": files, "needsDotnetBuild": needs_dotnet}


# "addons/" when the archive has it at its root, "<top>/addons/" when every entry is under one top
# folder that has it, else "".
static func _addons_base(names: PackedStringArray) -> String:
	if names.is_empty():
		return ""
	for name in names:
		if name.begins_with("addons/"):
			return "addons/"
	var top := names[0].get_slice("/", 0) + "/"
	var found := false
	for name in names:
		if not name.begins_with(top):
			return ""
		found = found or name.begins_with(top + "addons/")
	return top + "addons/" if found else ""


static func _is_native(lower: String) -> bool:
	if lower.trim_suffix("/").get_extension() in NATIVE_EXTENSIONS or _SHARED_LIBRARY.search(lower.trim_suffix("/")) != null:
		return true
	for segment in lower.split("/"):
		if segment.ends_with(".framework") or segment.ends_with(".xcframework"):
			return true
	return false


# {} when every addon may be written: res://addons and each target are not links, and an existing
# target is only replaced with `overwrite` and no plugin under it enabled (D68).
func _check_targets(names: Array, overwrite: bool) -> Dictionary:
	if _is_link(ADDONS_DIR):
		return ToolError.fail("INVALID_PATH", "%s is a symbolic link" % ADDONS_DIR)
	var enabled: PackedStringArray = ProjectSettings.get_setting("editor_plugins/enabled", PackedStringArray())
	for name: String in names:
		var target := ADDONS_DIR.path_join(name)
		if _is_link(target):
			return ToolError.fail("INVALID_PATH", "%s is a symbolic link" % target)
		if not _exists(target):
			continue
		if not overwrite:
			return ToolError.fail("FILE_EXISTS", "%s exists; pass overwrite: true to replace it (the old folder is kept as a backup)" % target)
		var prefix := (target + "/").to_lower()
		for path in enabled:
			if path.to_lower().begins_with(prefix) and EditorInterface.is_plugin_enabled(path):
				return ToolError.fail("PLUGIN_ENABLED", "%s is enabled; call disable_plugin before replacing %s" % [path, target])
	return {}


# Writes each addon's files into the stage, checking each against the index. {} or a tool failure.
func _extract(plan: Dictionary) -> Dictionary:
	var zip := ZIPReader.new()
	var err := zip.open(_download)
	if err != OK:
		return ToolError.fail("ZIP_UNSAFE", "The archive is refused: ZIPReader cannot open it (%s)" % error_string(err))
	var result := {}
	var since_yield := 0
	for addon: String in plan["addons"]:
		for entry: Dictionary in plan["addons"][addon]:
			var dest := _stage.path_join(addon).path_join(entry["inner"]) if entry["inner"] != "" else _stage.path_join(addon)
			var dir := dest if entry["dir"] else dest.get_base_dir()
			err = DirAccess.make_dir_recursive_absolute(dir)
			if err != OK:
				result = ToolError.fail("WRITE_FAILED", "Cannot make the stage folder %s (%s)" % [dir, error_string(err)])
				break
			if entry["dir"]:
				continue
			var data := zip.read_file(entry["name"], true)
			if data.size() != entry["size"]:
				result = ToolError.fail("ZIP_UNSAFE", "The archive is refused: %s holds %d bytes, not the %d its index declares" % [String(entry["name"]).c_escape(), data.size(), entry["size"]])
				break
			var file := FileAccess.open(dest, FileAccess.WRITE)
			if file == null:
				result = ToolError.fail("WRITE_FAILED", "Cannot write %s (%s)" % [dest, error_string(FileAccess.get_open_error())])
				break
			file.store_buffer(data)
			err = file.get_error()
			file.close()
			if err != OK:
				result = ToolError.fail("WRITE_FAILED", "Cannot write %s (%s)" % [dest, error_string(err)])
				break
			since_yield += data.size()
			if since_yield >= YIELD_BYTES:
				since_yield = 0
				if not await _request.next_frame():
					result = ToolError.fail("CANCELLED", "The request was cancelled; nothing was installed")
					break
		if not result.is_empty():
			break
	zip.close()
	return result


# Moves each old addon to a backup and each staged one into place, with no await in between, so a
# cancel never lands mid-swap. On a failure every completed step is undone. {backups} or a tool failure.
func _swap(addons: Dictionary) -> Dictionary:
	var err := DirAccess.make_dir_recursive_absolute(ADDONS_DIR)
	if err != OK:
		return ToolError.fail("WRITE_FAILED", "Cannot make %s (%s)" % [ADDONS_DIR, error_string(err)])
	var stamp := int(Time.get_unix_time_from_system() * 1000)
	# [target, backup or ""] for each finished addon.
	var done: Array[Array] = []
	var backups: Array[String] = []
	for name: String in addons:
		var target := ADDONS_DIR.path_join(name)
		var backup := ""
		if _exists(target):
			backup = "%s/backups/%s-%d" % [STATE_DIR, name, stamp]
			err = DirAccess.rename_absolute(target, backup)
			if err != OK:
				_undo(done)
				return ToolError.fail("WRITE_FAILED", "Cannot move %s to %s (%s); nothing was changed" % [target, backup, error_string(err)])
		err = DirAccess.rename_absolute(_stage.path_join(name), target)
		if err != OK:
			if backup != "":
				DirAccess.rename_absolute(backup, target)
			_undo(done)
			return ToolError.fail("WRITE_FAILED", "Cannot move the staged %s into %s (%s); nothing was changed" % [name, target, error_string(err)])
		done.append([target, backup])
		if backup != "":
			backups.append(backup)
	return {"backups": backups}


# Puts back what _swap moved, newest first: the new addon returns to the stage, the backup to its place.
func _undo(done: Array[Array]) -> void:
	for i in range(done.size() - 1, -1, -1):
		var target: String = done[i][0]
		var backup: String = done[i][1]
		var err := DirAccess.rename_absolute(target, _stage.path_join(target.get_file()))
		if err != OK:
			push_error("godot_mcp: install_asset could not undo %s (%s)" % [target, error_string(err)])
			continue
		if backup != "":
			err = DirAccess.rename_absolute(backup, target)
			if err != OK:
				push_error("godot_mcp: install_asset could not restore %s from %s (%s)" % [target, backup, error_string(err)])


# Keeps the newest KEEP_BACKUPS backups, judged by the time in their names.
func _prune_backups() -> void:
	var root := STATE_DIR + "/backups"
	var access := DirAccess.open(root)
	if access == null:
		return
	access.include_hidden = true
	var stamped: Array[Array] = []
	for name in access.get_directories():
		var stamp := name.get_slice("-", name.get_slice_count("-") - 1)
		if stamp.is_valid_int():
			stamped.append([int(stamp), name])
	stamped.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	for old in stamped.slice(KEEP_BACKUPS):
		_remove_tree(root.path_join(old[1]))


func _cleanup() -> void:
	_free_http()
	if _download != "" and FileAccess.file_exists(_download):
		DirAccess.remove_absolute(_download)
	if _stage != "":
		_remove_tree(_stage)


# Deletes `path` and what it holds without following links. Only ever under STATE_DIR.
static func _remove_tree(path: String) -> void:
	if not path.begins_with(STATE_DIR + "/"):
		push_error("godot_mcp: refusing to remove %s outside %s" % [path, STATE_DIR])
		return
	if _is_link(path) or not DirAccess.dir_exists_absolute(path):
		if _exists(path) or _is_link(path):
			DirAccess.remove_absolute(path)
		return
	var access := DirAccess.open(path)
	if access == null:
		return
	access.include_hidden = true
	for name in access.get_files():
		DirAccess.remove_absolute(path.path_join(name))
	for name in access.get_directories():
		_remove_tree(path.path_join(name))
	DirAccess.remove_absolute(path)


static func _is_link(path: String) -> bool:
	var access := DirAccess.open(path.get_base_dir())
	return access != null and access.is_link(ProjectSettings.globalize_path(path))


static func _exists(path: String) -> bool:
	return DirAccess.dir_exists_absolute(path) or FileAccess.file_exists(path)
