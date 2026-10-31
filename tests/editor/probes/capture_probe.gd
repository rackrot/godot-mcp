extends SceneTree

## Checks capture_store.gd (D59, D60) and capture_debugger.gd's reply claim (D58) outside the editor.
## PNGs the probe writes into OS.get_temp_dir() stand in for a game's screenshots. Prints one
## "PROBE {json}" line per check and exits 0 when all pass.

const CaptureDebugger := preload("res://addons/godot_mcp/capture_debugger.gd")
const CaptureStore := preload("res://addons/godot_mcp/capture_store.gd")

var _failed := false
var _serial := 0
# Temp-folder entries the probe made, removed at the end.
var _made: Array[String] = []


func _initialize() -> void:
	_copy()
	_rotation()
	_refusals()
	_custom_target()
	_scaled_inline()
	_jpeg_inline()
	_pixel_cap()
	_byte_cap()
	_claims()
	# Last: it leaves the captures folder a link.
	_linked_folder()
	for path in _made:
		DirAccess.remove_absolute(path)
	quit(1 if _failed else 0)


# The scenarios.


func _copy() -> void:
	var source := _screenshot(_solid(4, 3))
	var result := CaptureStore.save(source, "", true)
	if result.has("error"):
		return _check("a valid reply is copied to the captures folder", false, JSON.stringify(result))
	var path: String = result["path"]
	var copied := FileAccess.get_file_as_bytes(path)
	_check("a valid reply is copied to the captures folder", path.begins_with(CaptureStore.CAPTURE_DIR + "/capture-") and result["absolutePath"] == ProjectSettings.globalize_path(path) and result["bytes"] == copied.size() and copied.size() > 0 and result["width"] == 4 and result["height"] == 3, JSON.stringify(result))
	_check("the game's temp file is removed after the copy", not FileAccess.file_exists(source), source)
	var block: Dictionary = result["_content"][0]
	_check("the inline block is the PNG", block["type"] == "image" and block["mimeType"] == "image/png" and _decode(block).get_size() == Vector2i(4, 3), block["mimeType"])


# D60: the newest 20 captures this addon named are kept, by stamp and by their actual file names;
# other files in the folder are left alone.
func _rotation() -> void:
	var dir := CaptureStore.CAPTURE_DIR
	_clear(dir)
	for stamp in range(1, 21):
		_write(dir.path_join("capture-%03d.png" % stamp), PackedByteArray([1]))
	_write(dir.path_join("other.png"), PackedByteArray([1]))
	var result := CaptureStore.save(_screenshot(_solid(2, 2)), "", false)
	var files := DirAccess.get_files_at(dir)
	var ok: bool = not result.has("error") and files.size() == 21 and "capture-001.png" not in files and "capture-002.png" in files and "other.png" in files and result["path"].get_file() in files
	_check("a 21st capture deletes the oldest", ok, str(files))
	# Stamps ahead of the clock make the new capture the oldest; it must survive.
	_clear(dir)
	var future := 99999999999999
	for i in 20:
		_write(dir.path_join("capture-%d.png" % (future + i)), PackedByteArray([1]))
	result = CaptureStore.save(_screenshot(_solid(2, 2)), "", false)
	files = DirAccess.get_files_at(dir)
	ok = not result.has("error") and files.size() == 20 and result["path"].get_file() in files and "capture-%d.png" % future not in files
	_check("rotation never deletes the capture just written", ok, str(files))


# D59: each bad reply path gives CAPTURE_FAILED and leaves the file where it is.
func _refusals() -> void:
	var temp := OS.get_temp_dir()
	var png := _solid(2, 2).save_png_to_buffer()
	var outside := ProjectSettings.globalize_path("res://scr-1.png")
	_write(outside, png)
	_refused("a path outside the temp folder", outside)
	var wrong := _temp_name("shot-%d.png")
	_write(wrong, png)
	_refused("a wrong name", wrong)
	var letters := _temp_name("scr-%da.png")
	_write(letters, png)
	_refused("a name with a non-digit", letters)
	var real := _screenshot(_solid(2, 2))
	_refused("a path with a .. segment", temp.path_join("..").path_join(temp.get_file()).path_join(real.get_file()))
	var link := _temp_name("scr-%d.png")
	DirAccess.open(temp).create_link(outside, link)
	_refused("a symbolic link", link)
	var text := _temp_name("scr-%d.png")
	_write(text, "not a png".to_utf8_buffer())
	_refused("a non-PNG file", text)
	var folder := _temp_name("scr-%d.png")
	DirAccess.make_dir_absolute(folder)
	_refused("a directory", folder)
	var result := CaptureStore.save(7, "", false)
	_check("a reply without a path is refused", result.get("error", {}).get("code") == "CAPTURE_FAILED", JSON.stringify(result))
	_check("a refused link's target is untouched", FileAccess.file_exists(outside) and FileAccess.file_exists(real), outside)
	DirAccess.remove_absolute(outside)


func _custom_target() -> void:
	var source := _screenshot(_solid(3, 3))
	var result := CaptureStore.save(source, "res://shot.png", false)
	_check("a custom path is written, with no inline block when inline is false", result.get("path") == "res://shot.png" and FileAccess.file_exists("res://shot.png") and not result.has("_content") and not FileAccess.file_exists(source), JSON.stringify(result))
	result = CaptureStore.save(_screenshot(_solid(3, 3)), "res://shot.png", false)
	_check("a custom path that appeared meanwhile is FILE_EXISTS", result.get("error", {}).get("code") == "FILE_EXISTS", JSON.stringify(result))


func _scaled_inline() -> void:
	var result := CaptureStore.save(_screenshot(_solid(4000, 3000)), "", true)
	var image := _decode(result["_content"][0]) if result.has("_content") else Image.new()
	_check("a 4000x3000 capture is inlined at most 1568 px on the long side", result.get("width") == 4000 and result.get("height") == 3000 and image.get_size() == Vector2i(1568, 1176), str(image.get_size()))


func _jpeg_inline() -> void:
	var noise := Image.create_from_data(1568, 1176, false, Image.FORMAT_RGB8, Crypto.new().generate_random_bytes(1568 * 1176 * 3))
	var png_bytes := noise.save_png_to_buffer().size()
	var result := CaptureStore.save(_screenshot(noise), "", true)
	var block: Dictionary = result["_content"][0] if result.has("_content") else {}
	_check("a capture whose PNG is over 2 MB is inlined as JPEG", png_bytes > CaptureStore.INLINE_MAX_PNG_BYTES and block.get("mimeType") == "image/jpeg", "png %d bytes, %s" % [png_bytes, block.get("mimeType")])


# A small PNG whose header declares a huge frame is refused before it is decoded.
func _pixel_cap() -> void:
	var big := Image.create_empty(9000, 8000, false, Image.FORMAT_L8)
	var source := _screenshot(big)
	var result := CaptureStore.save(source, "", false)
	_check("a PNG over the pixel cap is CAPTURE_FAILED and left alone", result.get("error", {}).get("code") == "CAPTURE_FAILED" and FileAccess.file_exists(source), JSON.stringify(result))


func _byte_cap() -> void:
	var source := _temp_name("scr-%d.png")
	var file := FileAccess.open(source, FileAccess.WRITE)
	file.store_buffer(_solid(2, 2).save_png_to_buffer())
	file.resize(CaptureStore.MAX_BYTES + 1)
	file.close()
	var result := CaptureStore.save(source, "", false)
	_check("a file over 64 MB is CAPTURE_FAILED and left alone", result.get("error", {}).get("code") == "CAPTURE_FAILED" and FileAccess.file_exists(source), JSON.stringify(result))


# The captures folder as a link to another folder: the save is refused and nothing lands there.
func _linked_folder() -> void:
	var dir := CaptureStore.CAPTURE_DIR
	_clear(dir)
	DirAccess.remove_absolute(dir)
	var elsewhere := _temp_name("captures-%d")
	DirAccess.make_dir_absolute(elsewhere)
	DirAccess.open("res://").create_link(elsewhere, ProjectSettings.globalize_path(dir))
	var source := _screenshot(_solid(2, 2))
	var result := CaptureStore.save(source, "", false)
	var linked := DirAccess.open("res://").is_link(ProjectSettings.globalize_path(dir))
	_check("a linked captures folder is refused and nothing is written there", linked and result.get("error", {}).get("code") == "WRITE_FAILED" and DirAccess.get_files_at(elsewhere).is_empty() and FileAccess.file_exists(source), JSON.stringify(result))


# D58: only replies to this plugin's own requests are claimed. Every game_view message reaches it.
func _claims() -> void:
	var first := CaptureDebugger.FIRST_ID
	var next := first + 3
	var reply := "game_view:get_screenshot"
	_check("a reply with an id below 2^40 is not claimed", not CaptureDebugger.claims(reply, [5, 1, 1, "/tmp/scr-1.png"], next), "")
	_check("a reply with an id not yet issued is not claimed", not CaptureDebugger.claims(reply, [next, 1, 1, "/tmp/scr-1.png"], next), "")
	_check("other game_view messages are not claimed", not CaptureDebugger.claims("game_view:window_size", [Vector2i(64, 64)], next) and not CaptureDebugger.claims(reply, [Vector2i(1, 1), 1, 1, ""], next) and not CaptureDebugger.claims(reply, [first], next), "")
	_check("a reply to an issued id is claimed", CaptureDebugger.claims(reply, [first + 2, 1, 1, "/tmp/scr-1.png"], next), "")


# Helpers.


func _refused(name: String, source: String) -> void:
	var exists := FileAccess.file_exists(source) or DirAccess.dir_exists_absolute(source)
	var result := CaptureStore.save(source, "", false)
	var still := FileAccess.file_exists(source) or DirAccess.dir_exists_absolute(source)
	_check("%s is CAPTURE_FAILED and left alone" % name, exists and still and result.get("error", {}).get("code") == "CAPTURE_FAILED", JSON.stringify(result))


func _clear(dir: String) -> void:
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))


func _solid(width: int, height: int) -> Image:
	var image := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.2, 0.4, 0.8))
	return image


# Writes `image` where a game would: <temp>/scr-<digits>.png.
func _screenshot(image: Image) -> String:
	var path := _temp_name("scr-%d.png")
	image.save_png(path)
	return path


# A new path in the temp folder from `pattern`, which holds one %d.
func _temp_name(pattern: String) -> String:
	_serial += 1
	var path := OS.get_temp_dir().path_join(pattern % (OS.get_process_id() * 1000 + _serial))
	_made.append(path)
	return path


func _write(path: String, bytes: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()


func _decode(block: Dictionary) -> Image:
	var image := Image.new()
	var bytes := Marshalls.base64_to_raw(block["data"])
	if block["mimeType"] == "image/png":
		image.load_png_from_buffer(bytes)
	else:
		image.load_jpg_from_buffer(bytes)
	return image


func _check(name: String, ok: bool, detail := "") -> void:
	_failed = _failed or not ok
	print("PROBE ", JSON.stringify({"name": name, "ok": ok, "detail": detail}))
