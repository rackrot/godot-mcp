@tool
extends RefCounted

## Reads a zip archive's central directory and checks every entry before anything is extracted (D64,
## D65). ZIPReader.read_file allocates an entry's declared size and has no size or attribute query, so
## the sizes, names and modes are read here, from the bytes, and the archive is refused on any doubt.

const ToolError := preload("tool_error.gd")

const MAX_ENTRIES := 20000
const MAX_FILE_BYTES := 64 * 1024 * 1024
const MAX_TOTAL_BYTES := 256 * 1024 * 1024
# A file whose declared size is over MAX_RATIO times its compressed size, and over RATIO_FLOOR, is refused.
const MAX_RATIO := 100
const RATIO_FLOOR := 1024 * 1024
const MAX_DIRECTORY_BYTES := 16 * 1024 * 1024
const MAX_NAME_BYTES := 4096

const EOCD_SIGNATURE := 0x06054b50
const EOCD_BYTES := 22
const ZIP64_LOCATOR_SIGNATURE := 0x07064b50
const ENTRY_SIGNATURE := 0x02014b50
const ENTRY_BYTES := 46
# minizip looks this far back from the end for the end record and for a zip64 locator.
const MAX_COMMENT_BYTES := 0xffff
const ZIP64_EXTRA := 0x0001
const FLAG_ENCRYPTED := 0x0001
const FLAG_STRONG_ENCRYPTION := 0x0040
const FLAG_MASKED_DIRECTORY := 0x2000
const METHOD_STORED := 0
const METHOD_DEFLATED := 8
const MODE_TYPE := 0xf000
const MODE_FILE := 0x8000
const MODE_DIRECTORY := 0x4000
const MODE_LINK := 0xa000


# {entries: [{name, path, dir, size}]} in central-directory order, or a ZIP_UNSAFE failure. `name` is
# the entry's name as stored; `path` is the same without a directory's trailing slash.
static func parse(file_path: String) -> Dictionary:
	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		return ToolError.fail("WRITE_FAILED", "Cannot read the download (%s)" % error_string(FileAccess.get_open_error()))
	var length := file.get_length()
	var tail_start := maxi(0, length - (EOCD_BYTES + MAX_COMMENT_BYTES + 20))
	file.seek(tail_start)
	var tail := file.get_buffer(length - tail_start)
	# The last end record, as minizip finds it; its comment must end the file exactly.
	var eocd := -1
	for i in range(tail.size() - EOCD_BYTES, -1, -1):
		if tail.decode_u32(i) == EOCD_SIGNATURE:
			eocd = i
			break
	if eocd == -1:
		return _unsafe("it has no end-of-central-directory record")
	if eocd + EOCD_BYTES + tail.decode_u16(eocd + 20) != tail.size():
		return _unsafe("its end record's comment does not end the file")
	# minizip switches to zip64 when it finds a locator anywhere in this window, and would then read a
	# central directory other than this one.
	for i in tail.size() - 3:
		if tail.decode_u32(i) == ZIP64_LOCATOR_SIGNATURE:
			return _unsafe("it has a zip64 record")
	var disk := tail.decode_u16(eocd + 4)
	var directory_disk := tail.decode_u16(eocd + 6)
	var disk_entries := tail.decode_u16(eocd + 8)
	var count := tail.decode_u16(eocd + 10)
	var directory_size := tail.decode_u32(eocd + 12)
	var directory_offset := tail.decode_u32(eocd + 16)
	if count == 0xffff or directory_size == 0xffffffff or directory_offset == 0xffffffff:
		return _unsafe("it is a zip64 archive")
	if disk != 0 or directory_disk != 0 or disk_entries != count:
		return _unsafe("it spans several disks")
	if count > MAX_ENTRIES:
		return _unsafe("it has %d entries; the limit is %d" % [count, MAX_ENTRIES])
	if directory_size > MAX_DIRECTORY_BYTES:
		return _unsafe("its central directory is over %d bytes" % MAX_DIRECTORY_BYTES)
	# Exactly adjacent, so minizip sees no bytes before the archive and reads this same directory.
	if directory_offset + directory_size != tail_start + eocd:
		return _unsafe("its central directory is not where the end record says")
	file.seek(directory_offset)
	var directory := file.get_buffer(directory_size)
	if directory.size() != directory_size:
		return _unsafe("its central directory is truncated")
	return _read_entries(directory, count, directory_offset)


static func _read_entries(directory: PackedByteArray, count: int, directory_offset: int) -> Dictionary:
	var entries: Array[Dictionary] = []
	var total := 0
	var at := 0
	for index in count:
		if at + ENTRY_BYTES > directory.size() or directory.decode_u32(at) != ENTRY_SIGNATURE:
			return _unsafe("entry %d is not a central directory record" % index)
		var flags := directory.decode_u16(at + 8)
		var method := directory.decode_u16(at + 10)
		var compressed := directory.decode_u32(at + 20)
		var size := directory.decode_u32(at + 24)
		var name_length := directory.decode_u16(at + 28)
		var extra_length := directory.decode_u16(at + 30)
		var comment_length := directory.decode_u16(at + 32)
		var start_disk := directory.decode_u16(at + 34)
		var attributes := directory.decode_u32(at + 38)
		var local_offset := directory.decode_u32(at + 42)
		var next := at + ENTRY_BYTES + name_length + extra_length + comment_length
		if next > directory.size():
			return _unsafe("entry %d runs past the central directory" % index)
		var raw := directory.slice(at + ENTRY_BYTES, at + ENTRY_BYTES + name_length)
		var extra := directory.slice(at + ENTRY_BYTES + name_length, at + ENTRY_BYTES + name_length + extra_length)
		at = next
		if name_length == 0 or name_length > MAX_NAME_BYTES or not _is_utf8(raw):
			return _unsafe("entry %d has an empty, overlong or non-UTF-8 name" % index)
		var name := raw.get_string_from_utf8()
		var label := "entry %d (%s)" % [index, name.c_escape()]
		if flags & (FLAG_ENCRYPTED | FLAG_STRONG_ENCRYPTION | FLAG_MASKED_DIRECTORY):
			return _unsafe("%s is encrypted" % label)
		if method != METHOD_STORED and method != METHOD_DEFLATED:
			return _unsafe("%s uses compression method %d; only stored and deflate are read" % [label, method])
		if compressed == 0xffffffff or size == 0xffffffff or local_offset == 0xffffffff or _has_zip64_extra(extra):
			return _unsafe("%s is a zip64 entry" % label)
		if start_disk != 0 or local_offset >= directory_offset:
			return _unsafe("%s points outside the archive" % label)
		var mode_type := (attributes >> 16) & MODE_TYPE
		if mode_type == MODE_LINK:
			return _unsafe("%s is a symbolic link" % label)
		var is_dir := name.ends_with("/")
		if mode_type != 0 and mode_type != (MODE_DIRECTORY if is_dir else MODE_FILE):
			return _unsafe("%s is not a regular file or directory" % label)
		var problem := _name_problem(name)
		if problem != "":
			return _unsafe("%s %s" % [label, problem])
		if is_dir and (size != 0 or compressed != 0):
			return _unsafe("%s is a directory with content" % label)
		if method == METHOD_STORED and compressed != size:
			return _unsafe("%s is stored with two different sizes" % label)
		if size > MAX_FILE_BYTES:
			return _unsafe("%s declares %d bytes; the limit is %d per file" % [label, size, MAX_FILE_BYTES])
		if size > RATIO_FLOOR and size > compressed * MAX_RATIO:
			return _unsafe("%s declares %d bytes from %d compressed, over %d times" % [label, size, compressed, MAX_RATIO])
		total += size
		if total > MAX_TOTAL_BYTES:
			return _unsafe("its entries declare over %d bytes in all" % MAX_TOTAL_BYTES)
		entries.append({"name": name, "path": name.trim_suffix("/") if is_dir else name, "dir": is_dir, "size": size})
	if at != directory.size():
		return _unsafe("its central directory holds more than the %d entries its end record counts" % count)
	var collision := _collision(entries)
	if collision != "":
		return _unsafe(collision)
	return {"entries": entries}


# "" when `name` is a relative path of non-empty segments other than . and .., free of backslashes,
# colons and control characters. A directory's single trailing slash is allowed.
static func _name_problem(name: String) -> String:
	if name.begins_with("/"):
		return "is an absolute path"
	for i in name.length():
		var code := name.unicode_at(i)
		if code < 32 or code == 127 or code == 0x5c or code == 0x3a:
			return "has a backslash, colon or control character"
	for segment in name.trim_suffix("/").split("/"):
		if segment == "" or segment == "." or segment == "..":
			return "has an empty, . or .. segment"
	return ""


# A message when two entries, or an entry and a folder another entry implies, have names equal after
# lowercasing (or the same name) but are not the same folder, so a case-insensitive disk would merge them.
static func _collision(entries: Array[Dictionary]) -> String:
	# lowercased path -> [path as written, whether it is a folder]
	var seen := {}
	var names := {}
	for entry in entries:
		if names.has(entry["name"]):
			return "the entry %s appears twice" % String(entry["name"]).c_escape()
		names[entry["name"]] = true
		var parts: PackedStringArray = String(entry["path"]).split("/")
		for depth in parts.size():
			var path := "/".join(parts.slice(0, depth + 1))
			var is_dir: bool = depth < parts.size() - 1 or entry["dir"]
			var key := path.to_lower()
			if not seen.has(key):
				seen[key] = [path, is_dir]
				continue
			if seen[key][0] != path or not (seen[key][1] and is_dir):
				return "the entries %s and %s collide" % [String(seen[key][0]).c_escape(), path.c_escape()]
	return ""


static func _has_zip64_extra(extra: PackedByteArray) -> bool:
	var at := 0
	while at + 4 <= extra.size():
		if extra.decode_u16(at) == ZIP64_EXTRA:
			return true
		at += 4 + extra.decode_u16(at + 2)
	return false


# Strict UTF-8: no overlong forms, surrogates, code points past U+10FFFF or truncated sequences.
# Checked by hand because get_string_from_utf8 logs an engine error for bad bytes.
static func _is_utf8(bytes: PackedByteArray) -> bool:
	var i := 0
	while i < bytes.size():
		var lead := bytes[i]
		var extra := 0
		var lowest := 0
		if lead < 0x80:
			i += 1
			continue
		elif lead >= 0xc2 and lead <= 0xdf:
			extra = 1
			lowest = 0x80
		elif lead >= 0xe0 and lead <= 0xef:
			extra = 2
			lowest = 0x800
		elif lead >= 0xf0 and lead <= 0xf4:
			extra = 3
			lowest = 0x10000
		else:
			return false
		if i + extra >= bytes.size():
			return false
		var code := lead & (0x3f >> extra)
		for k in range(1, extra + 1):
			var next := bytes[i + k]
			if next & 0xc0 != 0x80:
				return false
			code = (code << 6) | (next & 0x3f)
		if code < lowest or code > 0x10ffff or (code >= 0xd800 and code <= 0xdfff):
			return false
		i += extra + 1
	return true


static func _unsafe(reason: String) -> Dictionary:
	return ToolError.fail("ZIP_UNSAFE", "The archive is refused: " + reason)
