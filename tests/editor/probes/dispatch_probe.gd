extends SceneTree

## Drives the addon's HttpServer and McpServer in-process, with the budget and write deadline patched
## down to 600 ms, so the timing behavior in dispatch.test.ts runs in seconds. Prints one
## "PROBE {json}" line per check and exits 0 when all pass.

const ADDON := "res://addons/godot_mcp/"
const LogBuffer := preload("res://addons/godot_mcp/log_buffer.gd")
const McpServer := preload("res://addons/godot_mcp/mcp_server.gd")
const ValueCodec := preload("res://addons/godot_mcp/value_codec.gd")
const Request := preload("res://addons/godot_mcp/request.gd")
const BUDGET_MS := 600

var _http: RefCounted
var _port := 0
var _events: Array[String] = []
var _clients: Array[Dictionary] = []
var _failed := false


func _initialize() -> void:
	_main()


func _main() -> void:
	var tcp := TCPServer.new()
	if tcp.listen(0, "127.0.0.1") != OK:
		_check("listen", false, "cannot listen")
		return _finish()
	_port = tcp.get_local_port()
	var script := _patched("http_server.gd", {
		"EXECUTION_MS := 30000": "EXECUTION_MS := %d" % BUDGET_MS,
		"WRITE_MS := 10000": "WRITE_MS := %d" % BUDGET_MS,
		'preload("request.gd")': 'preload("%srequest.gd")' % ADDON,
	})
	if script == null:
		return _finish()
	_http = script.new(tcp, _port, "tok", _handle)

	await _empty_results()
	await _content_blocks()
	_control_characters()
	_codec_references()
	_log_buffer()
	await _reply_shapes()
	await _timed_out_handler_is_cancelled()
	await _client_leaving_cancels()
	await _write_deadline()
	await _queued_deadline()
	_finish()


func _finish() -> void:
	quit(1 if _failed else 0)


# The scenarios.


# An empty Dictionary is a result; null, an Array and a script error are not (D36).
func _empty_results() -> void:
	var fake := Fake.new()
	var mcp := McpServer.new("t", [fake])
	for tool_name: String in ["empty", "nothing", "array", "broken"]:
		var body := JSON.stringify({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool_name}}).to_utf8_buffer()
		var reply: Array = await mcp.handle(body, {}, Request.new())
		var result: Dictionary = JSON.parse_string(reply[1])["result"]
		if tool_name == "empty":
			_check("empty result is a success", result["isError"] == false and result["structuredContent"] == {}, reply[1])
		else:
			_check("%s result is INTERNAL" % tool_name, result["isError"] == true and result["structuredContent"]["error"]["code"] == "INTERNAL", reply[1])


# D61: `_content` image blocks follow the text block and appear nowhere else; any other block is INTERNAL.
func _content_blocks() -> void:
	var mcp := McpServer.new("t", [Fake.new()])
	var reply: Dictionary = await _call(mcp, "image")
	var result: Dictionary = reply["result"]
	var content: Array = result["content"]
	var text: Dictionary = JSON.parse_string(content[0]["text"])
	_check("an image block follows the text block", content.size() == 2 and content[0]["type"] == "text" and content[1] == Fake.IMAGE and result["isError"] == false, JSON.stringify(reply))
	_check("_content is not in structuredContent or the text", result["structuredContent"] == {"a": 1.0} and text == {"a": 1.0}, JSON.stringify(reply))
	for tool_name: String in ["textblock", "badmime", "notarray", "extrakey", "nonstring"]:
		reply = await _call(mcp, tool_name)
		result = reply["result"]
		_check("a %s _content is INTERNAL" % tool_name, result["isError"] == true and result["structuredContent"]["error"]["code"] == "INTERNAL" and result["content"].size() == 1, JSON.stringify(reply))


func _call(mcp: McpServer, tool_name: String) -> Dictionary:
	var body := JSON.stringify({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool_name}}).to_utf8_buffer()
	var reply: Array = await mcp.handle(body, {}, Request.new())
	return JSON.parse_string(reply[1])


# Replies stay valid JSON with control characters in strings. The raw reply goes to dispatch.test.ts,
# which parses it with a strict parser.
func _control_characters() -> void:
	var mcp := McpServer.new("t", [Fake.new()])
	var body := JSON.stringify({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "control"}}).to_utf8_buffer()
	var reply: Array = await mcp.handle(body, {}, Request.new())
	_check("control characters reply", true, reply[1])


# Objects inside a container are references, never dumped.
func _codec_references() -> void:
	var out := ValueCodec.encode([RefCounted.new(), {"k": Resource.new(), "n": 1}])
	var value: Array = out["value"]
	_check("objects in containers are references", out["type"] == "Array" and value[0] == {"type": "Object", "value": null, "class": "RefCounted"} and value[1]["k"]["class"] == "Resource" and value[1]["n"] == 1, JSON.stringify(out))


func _log_buffer() -> void:
	var buffer := LogBuffer.new()
	buffer._log_message("out\n", false)
	buffer._log_message("err\n", true)
	var read := buffer.read(0, "info", 10)
	_check("printerr is logged as error", read["entries"][0]["level"] == "info" and read["entries"][1]["level"] == "error", JSON.stringify(read))
	var stale := buffer.read(99, "info", 10)
	_check("a cursor ahead of the log resets", stale["reset"] == true and stale["entries"].size() == 2 and stale["nextSince"] == 2 and read["reset"] == false, JSON.stringify(stale))


# A handler whose reply is not [int, String] gets 500, not a hang or a script crash.
func _reply_shapes() -> void:
	for body in ["null", "short", "badtype"]:
		var client := _client(body)
		await _until(func() -> bool: return client["done"], 2000)
		_check("reply shape %s gets 500" % body, client["status"] == 500 and client["body"].contains("Internal error"), str(client["status"]))


# D37: after the budget expires the handler must see the cancel and return before the next one starts.
func _timed_out_handler_is_cancelled() -> void:
	_events.clear()
	var a := _client("A")
	await _wait(300)
	var b := _client("B")
	await _until(func() -> bool: return a["done"] and b["done"], 3000)
	_check("timed-out handler gets 500", a["status"] == 500, str(a["status"]))
	_check("the next request is served", b["status"] == 200 and b["body"] == "b", "%s %s" % [b["status"], b["body"]])
	_check("handlers never overlap", _events == ["A start", "A abort", "B start"], str(_events))


# A client that disconnects mid-request cancels its handler at once, well inside the budget.
func _client_leaving_cancels() -> void:
	_events.clear()
	var a := _client("A")
	await _until(func() -> bool: return _events.has("A start"), 2000)
	var left := Time.get_ticks_msec()
	a["tcp"].disconnect_from_host()
	await _until(func() -> bool: return _events.has("A abort"), 3000)
	var elapsed: int = Time.get_ticks_msec() - left
	_check("a departing client cancels its handler", _events == ["A start", "A abort"] and elapsed < BUDGET_MS - 100, "%s after %d ms" % [_events, elapsed])
	await _until(func() -> bool: return _http._peers.is_empty(), 2000)


# D27: a client that stops reading is closed at the write deadline and does not block a second client.
func _write_deadline() -> void:
	var stalled := _client("huge", false)
	await _until(func() -> bool: return stalled["sent_at"] > 0, 2000)
	await _wait(200)
	var started := Time.get_ticks_msec()
	var ping := _client("ping")
	await _until(func() -> bool: return ping["done"], 2000)
	_check("a second client is served during the stall", ping["status"] == 200 and Time.get_ticks_msec() - started < 1000, str(ping["status"]))
	await _until(func() -> bool: return _http._peers.is_empty(), 3000)
	var elapsed: int = Time.get_ticks_msec() - stalled["sent_at"]
	_check("the stalled peer is closed at the write deadline", _http._peers.is_empty() and elapsed >= BUDGET_MS - 50, "closed after %d ms" % elapsed)


# The budget also bounds a request that never gets to start. H ignores the cancel and holds the FIFO for good,
# so this runs last.
func _queued_deadline() -> void:
	_events.clear()
	var h := _client("H")
	await _wait(100)
	var q := _client("B")
	await _until(func() -> bool: return h["done"] and q["done"], 3000)
	_check("a queued request gets 500 at the deadline", q["status"] == 500 and q["body"].contains("execution budget"), "%s %s" % [q["status"], q["body"]])
	_check("the queued request never started", _events == ["H start"], str(_events))


# Fixtures.


# What the patched HttpServer calls for each request; the body picks the behavior.
func _handle(body: PackedByteArray, _headers: Dictionary, request: Request) -> Variant:
	var name := body.get_string_from_utf8()
	_events.append(name + " start")
	match name:
		"A":
			while await request.next_frame():
				pass
			_events.append("A abort")
			return [200, "late"]
		"H":
			while true:
				await process_frame
		"B":
			return [200, "b"]
		"ping":
			return [200, "pong"]
		"null":
			return null
		"short":
			return [200]
		"badtype":
			return [200, 5]
		"huge":
			return [200, "x".repeat(48 * 1024 * 1024)]
	return [200, name]


class Fake:
	extends RefCounted

	const IMAGE := {"type": "image", "data": "iVBORw0KGgo=", "mimeType": "image/png"}

	func tools() -> Array[Dictionary]:
		var schema := {"type": "object", "properties": {}}
		return [
			{"name": "empty", "inputSchema": schema, "handler": empty},
			{"name": "nothing", "inputSchema": schema, "handler": nothing},
			{"name": "array", "inputSchema": schema, "handler": array},
			{"name": "broken", "inputSchema": schema, "handler": broken},
			{"name": "control", "inputSchema": schema, "handler": control},
			{"name": "image", "inputSchema": schema, "handler": func(_a: Dictionary, _r: Request) -> Variant: return {"a": 1, "_content": [IMAGE]}},
			{"name": "textblock", "inputSchema": schema, "handler": func(_a: Dictionary, _r: Request) -> Variant: return {"_content": [{"type": "text", "text": "x"}]}},
			{"name": "badmime", "inputSchema": schema, "handler": func(_a: Dictionary, _r: Request) -> Variant: return {"_content": [{"type": "image", "data": "x", "mimeType": "image/gif"}]}},
			{"name": "notarray", "inputSchema": schema, "handler": func(_a: Dictionary, _r: Request) -> Variant: return {"_content": IMAGE}},
			{"name": "extrakey", "inputSchema": schema, "handler": func(_a: Dictionary, _r: Request) -> Variant: return {"_content": [{"type": "image", "data": "x", "mimeType": "image/png", "annotations": {}}]}},
			{"name": "nonstring", "inputSchema": schema, "handler": func(_a: Dictionary, _r: Request) -> Variant: return {"_content": [{"type": "image", "data": 5, "mimeType": "image/png"}]}},
		]

	# U+0001, U+000B and U+001B, a literal backslash then v, and a literal double backslash then v.
	func control(_arguments: Dictionary, _request: Request) -> Variant:
		return {"s": "\u0001\u000b\u001b" + "\\v" + "\\\\v"}

	func empty(_arguments: Dictionary, _request: Request) -> Variant:
		return {}

	func nothing(_arguments: Dictionary, _request: Request) -> Variant:
		return null

	func array(_arguments: Dictionary, _request: Request) -> Variant:
		return [1]

	func broken(_arguments: Dictionary, _request: Request) -> Variant:
		var nothing = null
		return nothing.no_such_method()


# Helpers.


func _patched(file: String, edits: Dictionary) -> GDScript:
	var source := FileAccess.get_file_as_string(ADDON + file)
	for old: String in edits:
		if not source.contains(old):
			_check("patch " + file, false, "no match for: " + old)
			return null
		source = source.replace(old, edits[old])
	var script := GDScript.new()
	script.source_code = source
	if script.reload() != OK:
		_check("patch " + file, false, "does not compile")
		return null
	return script


# Starts a request to the server and returns its state, which _pump fills in each frame.
func _client(body: String, reads := true) -> Dictionary:
	var tcp := StreamPeerTCP.new()
	tcp.connect_to_host("127.0.0.1", _port)
	var payload := body.to_utf8_buffer()
	var head := "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nAuthorization: Bearer tok\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % [_port, payload.size()]
	var client := {"tcp": tcp, "request": head.to_utf8_buffer() + payload, "reads": reads, "sent_at": 0, "buf": PackedByteArray(), "done": false, "status": 0, "body": ""}
	_clients.append(client)
	return client


func _pump() -> void:
	_http.poll()
	for client in _clients:
		var tcp: StreamPeerTCP = client["tcp"]
		tcp.poll()
		if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			continue
		if client["sent_at"] == 0:
			tcp.put_data(client["request"])
			client["sent_at"] = Time.get_ticks_msec()
		if not client["reads"] or client["done"]:
			continue
		var available := tcp.get_available_bytes()
		if available > 0:
			client["buf"].append_array(tcp.get_data(available)[1])
		var text: String = client["buf"].get_string_from_utf8()
		var end := text.find("\r\n\r\n")
		if end == -1:
			continue
		var length := 0
		for line in text.left(end).split("\r\n"):
			if line.to_lower().begins_with("content-length:"):
				length = line.get_slice(":", 1).strip_edges().to_int()
		if client["buf"].size() >= end + 4 + length:
			client["status"] = text.get_slice(" ", 1).to_int()
			client["body"] = text.substr(end + 4)
			client["done"] = true


func _until(condition: Callable, timeout_ms: int) -> void:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while not condition.call() and Time.get_ticks_msec() < deadline:
		_pump()
		await process_frame
	_pump()


func _wait(ms: int) -> void:
	var deadline := Time.get_ticks_msec() + ms
	await _until(func() -> bool: return Time.get_ticks_msec() >= deadline, ms + 100)


func _check(name: String, ok: bool, detail := "") -> void:
	_failed = _failed or not ok
	print("PROBE ", JSON.stringify({"name": name, "ok": ok, "detail": detail}))
