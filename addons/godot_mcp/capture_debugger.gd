@tool
extends EditorDebuggerPlugin

## Asks a running game for a screenshot with the engine's own scene:rq_screenshot message and claims
## the game_view:get_screenshot replies to its own requests (D58). The built-in Game view numbers its
## requests from 0 and gets every other reply.

const FIRST_ID := 1 << 40
const REPLY := "game_view:get_screenshot"

var _next_id := FIRST_ID
# Request id -> the reply's data [id, width, height, path], or null while waiting.
var _pending := {}


func _has_capture(capture: String) -> bool:
	return capture == "game_view"


func _capture(message: String, data: Array, _session_id: int) -> bool:
	if not claims(message, data, _next_id):
		return false
	# A reply to a request the handler gave up on is claimed and dropped.
	if _pending.has(data[0]):
		_pending[data[0]] = data
	return true


# Whether `message` is a screenshot reply to an id this plugin issued (FIRST_ID up to `next_id`).
# Every game_view message reaches _capture, and their data has other shapes (window_size holds a Vector2i).
static func claims(message: String, data: Array, next_id: int) -> bool:
	if message != REPLY or data.size() != 4 or not data[0] is int:
		return false
	return data[0] >= FIRST_ID and data[0] < next_id


# The first active debugger session, or null.
func active_session() -> EditorDebuggerSession:
	for session: EditorDebuggerSession in get_sessions():
		if session.is_active():
			return session
	return null


# Sends a screenshot request to the first active session. Returns its id, or -1 when none is active.
func request() -> int:
	var session := active_session()
	if session == null:
		return -1
	var id := _next_id
	_next_id += 1
	_pending[id] = null
	session.send_message("scene:rq_screenshot", [id])
	return id


# The reply's data [id, width, height, path] once it has arrived, else null.
func reply(id: int) -> Variant:
	return _pending.get(id)


func forget(id: int) -> void:
	_pending.erase(id)
