@tool
extends RefCounted

## JSON-RPC and MCP for the 2025-11-25 era, served statelessly with JSON responses only (D25, D36).

const Request := preload("request.gd")
const Schema := preload("schema.gd")

const SUPPORTED_VERSIONS: Array[String] = ["2025-11-25", "2025-06-18", "2025-03-26"]
const MAX_RESPONSE_BYTES := 4 * 1024 * 1024
const MAX_ID_CHARS := 256
const RECENT_MS := 60000
const MAX_RECENT_IDS := 10000
# Control characters JSON.stringify leaves raw; \b \t \n \f \r (and \v, see _stringify) it escapes.
static var _CONTROL := RegEx.create_from_string("[\\x01-\\x07\\x0e-\\x1f]")
static var _VT_ESCAPE := RegEx.create_from_string("(?<!\\\\)((?:\\\\\\\\)*)\\\\v")

# At most 2,000 characters (D39); the conformance test checks it.
const INSTRUCTIONS := "This server is the open Godot editor for one project, so it answers only while the editor runs. Call get_project_info first. Node edits stay in the editor until save_scene succeeds. run_headless reads files on disk, so save first. After adding or changing assets, call import_assets. Only one job (run_headless, import_assets, build_dotnet or install_asset) runs at a time; check jobActive. A failed call returns error.code, such as PROJECT_BUSY or NO_SCENE. Math values are Godot literals such as \"Vector2(1, 2)\". The godot-mcp skill has the full guide: value syntax, error codes, limits and troubleshooting."

var _version: String
# Each provider has tools() -> Array[Dictionary]; held here because handler Callables don't keep it alive.
var _providers: Array
# name -> {definition: Dictionary, handler: Callable}
var _tools := {}
# JSON-RPC id -> the Requests in flight under it, from the moment each is queued.
var _in_flight := {}
# JSON-RPC id -> when a request under it last finished, oldest first.
var _recent := {}


func _init(version: String, providers: Array) -> void:
	_version = version
	_providers = providers
	for provider: Object in providers:
		_register(provider.tools())


func _register(tools: Array[Dictionary]) -> void:
	for tool in tools:
		var definition := tool.duplicate()
		definition.erase("handler")
		_tools[tool["name"]] = {"definition": definition, "handler": tool["handler"]}


# Answers one POST body. Returns [http_status, body]. A coroutine when a tool handler awaits.
func handle(body: PackedByteArray, headers: Dictionary, request: Request) -> Array:
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		return [400, _error(null, -32700, "Parse error: " + json.get_error_message())]
	if json.data is Array:
		return [400, _error(null, -32600, "Batch requests are not supported")]
	if not json.data is Dictionary:
		return [400, _error(null, -32600, "Invalid Request: expected an object")]
	var message: Dictionary = json.data
	var id: Variant = message.get("id")
	if message.has("id") and not (id is String or id is float):
		return [400, _error(null, -32600, "Invalid Request: id must be a string or a number")]
	if id is String and id.length() > MAX_ID_CHARS:
		return [400, _error(null, -32600, "Invalid Request: id is longer than %d characters" % MAX_ID_CHARS)]
	id = _wire_id(id)
	if not message.get("jsonrpc") is String or message["jsonrpc"] != "2.0":
		return [400, _error(id, -32600, "Invalid Request: jsonrpc must be \"2.0\"")]
	var requested: String = headers.get("mcp-protocol-version", "")
	if requested != "" and requested not in SUPPORTED_VERSIONS:
		var data := {"supported": SUPPORTED_VERSIONS, "requested": requested}
		return [400, _error(id, -32600, "Unsupported MCP-Protocol-Version: " + requested, data)]
	if not message.has("method"):
		if message.has("id") and (message.has("result") or message.has("error")):
			return [202, ""]
		return [400, _error(id, -32600, "Invalid Request: no method")]
	if not message["method"] is String:
		return [400, _error(id, -32600, "Invalid Request: method must be a string")]
	if not message.has("id"):
		return [202, ""]
	var params: Variant = message.get("params", {})
	if not params is Dictionary:
		return [200, _error(id, -32602, "params must be an object")]
	var outcome: Dictionary = await _dispatch(message["method"], params, request)
	if outcome.has("error"):
		return [200, _error(id, outcome["error"]["code"], outcome["error"]["message"])]
	if not outcome.has("result"):
		# A script error during dispatch returns an empty Dictionary.
		return [200, _error(id, -32603, "Internal error")]
	var text := _stringify({"jsonrpc": "2.0", "id": id, "result": outcome["result"]})
	if text.to_utf8_buffer().size() > MAX_RESPONSE_BYTES:
		return [200, _error(id, -32603, "Response exceeds %d bytes" % MAX_RESPONSE_BYTES)]
	return [200, text]


# Called by the transport as soon as a body is complete, before the request waits in the FIFO. Records
# a request's id so a cancel can find it, and applies notifications/cancelled at once: it touches no
# editor state, so it must not wait behind the request it targets.
func ingress(body: PackedByteArray, request: Request) -> void:
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK or not json.data is Dictionary:
		return
	var message: Dictionary = json.data
	if not message.get("method") is String:
		return
	var id: Variant = message.get("id")
	if id is float or (id is String and id.length() <= MAX_ID_CHARS):
		request.rpc_id = _wire_id(id)
		_in_flight.get_or_add(request.rpc_id, []).append(request)
	elif message["method"] == "notifications/cancelled" and message.get("params") is Dictionary:
		_cancel_in_flight(message["params"].get("requestId"))


# Called when a request leaves the transport (answered or dropped). Its id stays suspect for a while.
func done(request: Request) -> void:
	var id: Variant = request.rpc_id
	if id == null:
		return
	request.rpc_id = null
	var peers: Array = _in_flight.get(id, [])
	peers.erase(request)
	if peers.is_empty():
		_in_flight.erase(id)
	_recent.erase(id)
	_recent[id] = Time.get_ticks_msec()
	if _recent.size() > MAX_RECENT_IDS:
		_recent.erase(_recent.keys()[0])


# notifications/cancelled: a client that gives up on a request sends this on a new connection, since
# the server keeps no session. Ids are only unique per client, so the cancel is ambiguous, and applied
# to nothing, when several requests are in flight under the id or one finished under it within
# RECENT_MS (a stale cancel must not hit another client's new request). Any token holder can cancel
# any request (D33).
func _cancel_in_flight(request_id: Variant) -> void:
	var id: Variant = _wire_id(request_id)
	var peers: Array = _in_flight.get(id, [])
	var finished: int = _recent.get(id, -RECENT_MS)
	if peers.size() == 1 and Time.get_ticks_msec() - finished >= RECENT_MS:
		peers[0].cancelled = true


# JSON numbers parse as floats; whole ids become ints, so a reply carries "id":1, not 1.0.
static func _wire_id(id: Variant) -> Variant:
	if id is float and absf(id) <= 9007199254740991.0 and id == floorf(id):
		return int(id)
	return id


# Returns {result} or {error: {code, message}}.
func _dispatch(method: String, params: Dictionary, request: Request) -> Dictionary:
	match method:
		"initialize":
			var requested: Variant = params.get("protocolVersion")
			return {"result": {
				"protocolVersion": requested if requested in SUPPORTED_VERSIONS else SUPPORTED_VERSIONS[0],
				"capabilities": {"tools": {"listChanged": false}},
				"serverInfo": {"name": "godot-mcp", "version": _version},
				"instructions": INSTRUCTIONS,
			}}
		"ping":
			return {"result": {}}
		"tools/list":
			var definitions := []
			for name: String in _tools:
				definitions.append(_tools[name]["definition"])
			return {"result": {"tools": definitions}}
		"tools/call":
			return await _call_tool(params, request)
	return {"error": {"code": -32601, "message": "Method not found: " + method}}


# A tool returns its structured result, or {error: {code, message}} for a tool failure (D36).
func _call_tool(params: Dictionary, request: Request) -> Dictionary:
	var name: Variant = params.get("name")
	if not name is String:
		return {"error": {"code": -32602, "message": "params.name must be a string"}}
	if not _tools.has(name):
		return {"error": {"code": -32602, "message": "Unknown tool: %s" % [name]}}
	var arguments: Variant = params.get("arguments", {})
	var tool: Dictionary = _tools[name]
	var problem := Schema.validate(arguments, tool["definition"]["inputSchema"])
	if problem != "":
		return {"error": {"code": -32602, "message": "Invalid arguments for %s: %s" % [name, problem]}}
	var structured: Variant = await tool["handler"].call(arguments, request)
	# A handler that hits a script error returns null (handlers return Variant, so no typed default
	# stands in); that is a tool failure, never a success. An empty Dictionary is a legitimate result.
	if not structured is Dictionary:
		structured = {"error": {"code": "INTERNAL", "message": "Tool %s failed with a script error" % name}}
	# D61: a handler may add content blocks under the reserved key `_content`; only images are accepted.
	var blocks: Variant = structured.get("_content", [])
	structured.erase("_content")
	if not _image_blocks(blocks):
		blocks = []
		structured = {"error": {"code": "INTERNAL", "message": "Tool %s returned a content block that is not an image" % name}}
	var content := [{"type": "text", "text": _stringify(structured)}]
	content.append_array(blocks)
	return {"result": {
		"content": content,
		"structuredContent": structured,
		"isError": structured.has("error"),
	}}


static func _image_blocks(blocks: Variant) -> bool:
	if not blocks is Array:
		return false
	for block: Variant in blocks:
		if not block is Dictionary or block.size() != 3 or not block.get("data") is String:
			return false
		# `in` compares without the error `!=` raises between a String and another type.
		if block.get("type") not in ["image"] or block.get("mimeType") not in ["image/png", "image/jpeg"]:
			return false
	return true


static func _error(id: Variant, code: int, message: String, data: Variant = null) -> String:
	var error := {"code": code, "message": message}
	if data != null:
		error["data"] = data
	return _stringify({"jsonrpc": "2.0", "id": id, "error": error})


# JSON.stringify writes U+000B as the invalid escape \v and leaves other control characters raw
# inside strings (the editor log carries ANSI escapes). Rewrite both as \u00XX.
static func _stringify(value: Variant) -> String:
	var text := JSON.stringify(value)
	# Only a \v preceded by an even run of backslashes is an escape; "\\v" is a backslash and a v.
	if text.contains("\\v"):
		text = _VT_ESCAPE.sub(text, "$1\\u000b", true)
	if _CONTROL.search(text) != null:
		for code in range(1, 32):
			text = text.replace(char(code), "\\u%04x" % code)
	return text
