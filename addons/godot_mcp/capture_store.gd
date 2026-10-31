@tool
extends RefCounted

## Takes the PNG a game wrote for scene:rq_screenshot into the project (D59, D60). The path comes from
## the game's reply, so from project code: it is checked before anything is read or copied.

const ResPaths := preload("res_paths.gd")
const ToolError := preload("tool_error.gd")

const CAPTURE_DIR := "res://.godot/godot_mcp/captures"
const KEEP := 20
const MAX_BYTES := 64 * 1024 * 1024
const INLINE_MAX_SIDE := 1568
const INLINE_MAX_PNG_BYTES := 2 * 1024 * 1024
const JPEG_QUALITY := 0.85
const PROTECTED_DIR := "res://addons/godot_mcp/"

static var _PNG_SIGNATURE := PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
static var _SCREENSHOT := RegEx.create_from_string("^scr-[0-9]+\\.png\\z")
static var _OWN := RegEx.create_from_string("^capture-([0-9]+)\\.png\\z")


# {} when `path` may receive a capture, otherwise a tool failure.
static func check_target(path: String) -> Dictionary:
	if path.to_lower().begins_with(PROTECTED_DIR):
		return ToolError.fail("PROTECTED_PATH", "Captures cannot be written under %s" % PROTECTED_DIR)
	return ResPaths.check_new_file(path, ["png"])


# Copies the game's screenshot at `source` to `target`, or to a new file in CAPTURE_DIR when `target`
# is empty, then removes `source`. Returns {path, absolutePath, width, height, bytes}, plus `_content`
# holding one image block when `inline`, or a tool failure that leaves `source` alone.
static func save(source: Variant, target: String, inline: bool) -> Dictionary:
	var read := _read_screenshot(source)
	if read.has("error"):
		return read
	var bytes: PackedByteArray = read["bytes"]
	var image := Image.new()
	if image.load_png_from_buffer(bytes) != OK:
		return _failed("%s is not a readable PNG" % source)
	var path := target
	if path == "":
		path = _new_capture_path()
		if path == "":
			return ToolError.fail("WRITE_FAILED", "Cannot create %s, or it passes through a symbolic link" % CAPTURE_DIR)
	else:
		# Checked again: the file may have appeared while the game was answering.
		var problem := check_target(path)
		if not problem.is_empty():
			return problem
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return ToolError.fail("WRITE_FAILED", "Cannot write %s (%s)" % [path, error_string(FileAccess.get_open_error())])
	file.store_buffer(bytes)
	var err := file.get_error()
	file.close()
	if err != OK:
		return ToolError.fail("WRITE_FAILED", "Cannot write %s (%s)" % [path, error_string(err)])
	err = DirAccess.remove_absolute(source)
	if err != OK:
		push_warning("godot_mcp: cannot remove the game's screenshot %s (%s)" % [source, error_string(err)])
	if target == "":
		_rotate()
	var result := {
		"path": path,
		"absolutePath": ProjectSettings.globalize_path(path),
		"width": image.get_width(),
		"height": image.get_height(),
		"bytes": bytes.size(),
	}
	if inline:
		result["_content"] = [_inline_block(image)]
	return result


# D59: a regular file directly in the editor's temp folder, named scr-<digits>.png, not a link, at most
# MAX_BYTES, starting with the PNG signature. Returns {bytes} or a tool failure.
static func _read_screenshot(source: Variant) -> Dictionary:
	if not source is String:
		return _failed("The game's reply has no file path")
	var temp := OS.get_temp_dir()
	var name: String = source.get_file()
	if _SCREENSHOT.search(name) == null or source != temp.path_join(name):
		return _failed("%s is not a screenshot file in the editor's temp folder %s; the game may run on another machine or in a sandbox" % [source, temp])
	var dir := DirAccess.open(temp)
	if dir == null:
		return _failed("Cannot open the temp folder %s (%s)" % [temp, error_string(DirAccess.get_open_error())])
	if dir.is_link(source):
		return _failed("%s is a symbolic link" % source)
	# False for a directory, a FIFO or a device as well as a missing file.
	if not FileAccess.file_exists(source):
		return _failed("%s is not a regular file" % source)
	var file := FileAccess.open(source, FileAccess.READ)
	if file == null:
		return _failed("Cannot read %s (%s)" % [source, error_string(FileAccess.get_open_error())])
	var size := file.get_length()
	if size > MAX_BYTES:
		return _failed("%s is larger than %d bytes" % [source, MAX_BYTES])
	var bytes := file.get_buffer(size)
	if bytes.size() != size or bytes.slice(0, _PNG_SIGNATURE.size()) != _PNG_SIGNATURE:
		return _failed("%s is not a PNG file" % source)
	return {"bytes": bytes}


# A new res:// path in CAPTURE_DIR, or "" when the folder can't be made or a part of it is a link.
static func _new_capture_path() -> String:
	var access := DirAccess.open("res://")
	if access == null:
		return ""
	for dir: String in ["res://.godot", "res://.godot/godot_mcp", CAPTURE_DIR]:
		if access.is_link(ProjectSettings.globalize_path(dir)):
			return ""
	if DirAccess.make_dir_recursive_absolute(CAPTURE_DIR) != OK:
		return ""
	var stamp := int(Time.get_unix_time_from_system() * 1000.0)
	while FileAccess.file_exists("%s/capture-%d.png" % [CAPTURE_DIR, stamp]):
		stamp += 1
	return "%s/capture-%d.png" % [CAPTURE_DIR, stamp]


# Keeps the newest KEEP captures this addon named in CAPTURE_DIR and deletes the rest.
static func _rotate() -> void:
	var stamps: Array[int] = []
	for file in DirAccess.get_files_at(CAPTURE_DIR):
		var found := _OWN.search(file)
		if found != null:
			stamps.append(found.get_string(1).to_int())
	stamps.sort()
	for stamp in stamps.slice(0, maxi(stamps.size() - KEEP, 0)):
		var path := "%s/capture-%d.png" % [CAPTURE_DIR, stamp]
		var err := DirAccess.remove_absolute(path)
		if err != OK:
			push_warning("godot_mcp: cannot remove the old capture %s (%s)" % [path, error_string(err)])


# One MCP image block: the frame scaled to INLINE_MAX_SIDE on its long side, as PNG, or as JPEG when
# the PNG is over INLINE_MAX_PNG_BYTES.
static func _inline_block(image: Image) -> Dictionary:
	var scaled := image
	var long_side := maxi(image.get_width(), image.get_height())
	if long_side > INLINE_MAX_SIDE:
		scaled = image.duplicate()
		var scale := float(INLINE_MAX_SIDE) / long_side
		scaled.resize(maxi(roundi(image.get_width() * scale), 1), maxi(roundi(image.get_height() * scale), 1), Image.INTERPOLATE_LANCZOS)
	var encoded := scaled.save_png_to_buffer()
	var mime := "image/png"
	if encoded.size() > INLINE_MAX_PNG_BYTES:
		encoded = scaled.save_jpg_to_buffer(JPEG_QUALITY)
		mime = "image/jpeg"
	return {"type": "image", "data": Marshalls.raw_to_base64(encoded), "mimeType": mime}


static func _failed(message: String) -> Dictionary:
	return ToolError.fail("CAPTURE_FAILED", message)
