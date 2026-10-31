@tool
extends RefCounted

## Input events for add_input_action (D55): the JSON event shape to InputEvent objects, back again, and an
## exact comparison. Godot's own key parser silently drops an unknown modifier word, so the modifiers are
## split off and checked here, and only the last part reaches OS.find_keycode_from_string. It builds
## InputEvents directly because ValueDecoder refuses Objects by design (D35).

const ToolError := preload("tool_error.gd")

const MAX_EVENTS := 32
const MAX_JOYPAD_BUTTON := 127
const MODIFIERS: Array[String] = ["ctrl", "shift", "alt", "meta", "cmdorctrl"]
const MOUSE_BUTTONS := {
	"left": MOUSE_BUTTON_LEFT,
	"right": MOUSE_BUTTON_RIGHT,
	"middle": MOUSE_BUTTON_MIDDLE,
	"wheelUp": MOUSE_BUTTON_WHEEL_UP,
	"wheelDown": MOUSE_BUTTON_WHEEL_DOWN,
	"wheelLeft": MOUSE_BUTTON_WHEEL_LEFT,
	"wheelRight": MOUSE_BUTTON_WHEEL_RIGHT,
	"extra1": MOUSE_BUTTON_XBUTTON1,
	"extra2": MOUSE_BUTTON_XBUTTON2,
}
const FIELDS := {
	"key": ["type", "key", "modifiers", "physical", "device"],
	"mouseButton": ["type", "button", "modifiers", "device"],
	"joypadButton": ["type", "button", "device"],
}
# JSON numbers arrive as floats; device and button ids are small whole numbers.
const MAX_ID := 2147483647.0


# Returns {events: Array of InputEvent}, or a tool failure naming the offending events[i].
static func parse(raw_events: Array) -> Dictionary:
	var events := []
	for i in raw_events.size():
		var built := _parse_one(raw_events[i], "events[%d]" % i)
		if built.has("error"):
			return built
		events.append(built["event"])
	return {"events": events}


static func _parse_one(raw: Variant, label: String) -> Dictionary:
	if raw is String:
		var parts: PackedStringArray = raw.split("+")
		var modifiers := _modifiers(Array(parts.slice(0, parts.size() - 1)), label)
		if modifiers.has("error"):
			return modifiers
		return _key(parts[parts.size() - 1], modifiers["set"], true, -1, label)
	if not raw is Dictionary:
		return _invalid(label, "must be a key string such as \"Ctrl+P\" or an object with a type")
	var type: Variant = raw.get("type")
	if not type is String or not FIELDS.has(type):
		return _invalid(label, "type must be key, mouseButton or joypadButton")
	for field: Variant in raw:
		if field not in FIELDS[type]:
			return _invalid(label, "has the field %s, which a %s event does not take" % [str(field).left(40), type])
	var device := -1
	if raw.has("device"):
		if not _is_whole(raw["device"]) or raw["device"] < -1:
			return _invalid(label, "device must be a whole number, -1 for all devices")
		device = int(raw["device"])
	if type == "joypadButton":
		return _joypad_button(raw.get("button"), device, label)
	var modifiers := _modifiers(raw.get("modifiers", []), label)
	if modifiers.has("error"):
		return modifiers
	if type == "mouseButton":
		return _mouse_button(raw.get("button"), modifiers["set"], device, label)
	var physical: Variant = raw.get("physical", true)
	if not physical is bool:
		return _invalid(label, "physical must be a boolean")
	var key: Variant = raw.get("key")
	if not key is String:
		return _invalid(label, "key must be a key name such as \"P\" or \"F1\"")
	return _key(key, modifiers["set"], physical, device, label)


# Lowercased modifier names as a set, or a failure for an unknown name, a repeat, or a non-array.
static func _modifiers(names: Variant, label: String) -> Dictionary:
	if not names is Array:
		return _invalid(label, "modifiers must be an array")
	var set := {}
	for name: Variant in names:
		var lower := String(name).to_lower() if name is String else ""
		if lower not in MODIFIERS:
			return _invalid(label, "has the modifier %s; use Ctrl, Shift, Alt, Meta or CmdOrCtrl" % str(name).left(40))
		if set.has(lower):
			return _invalid(label, "names the modifier %s twice" % lower)
		set[lower] = true
	return {"set": set}


static func _key(name: String, modifiers: Dictionary, physical: bool, device: int, label: String) -> Dictionary:
	var code := OS.find_keycode_from_string(name)
	# A "+" would let Godot's parser read modifiers out of the key name and drop the ones it does not know.
	if name.contains("+") or code == KEY_NONE or code & KEY_MODIFIER_MASK != 0:
		return _invalid(label, "has the key name %s, which Godot does not know" % name.left(40))
	var event := InputEventKey.new()
	if physical:
		event.physical_keycode = code as Key
	else:
		event.keycode = code as Key
	_set_modifiers(event, modifiers)
	event.device = device
	return {"event": event}


static func _mouse_button(button: Variant, modifiers: Dictionary, device: int, label: String) -> Dictionary:
	if not MOUSE_BUTTONS.has(button):
		return _invalid(label, "button must be one of: " + ", ".join(MOUSE_BUTTONS.keys()))
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTONS[button]
	_set_modifiers(event, modifiers)
	event.device = device
	return {"event": event}


static func _joypad_button(button: Variant, device: int, label: String) -> Dictionary:
	if not _is_whole(button) or button < 0 or button > MAX_JOYPAD_BUTTON:
		return _invalid(label, "button must be a whole number from 0 to %d" % MAX_JOYPAD_BUTTON)
	var event := InputEventJoypadButton.new()
	event.button_index = int(button) as JoyButton
	event.device = device
	return {"event": event}


static func _set_modifiers(event: InputEventWithModifiers, modifiers: Dictionary) -> void:
	event.ctrl_pressed = modifiers.has("ctrl")
	event.shift_pressed = modifiers.has("shift")
	event.alt_pressed = modifiers.has("alt")
	event.meta_pressed = modifiers.has("meta")
	if modifiers.has("cmdorctrl"):
		event.command_or_control_autoremap = true


static func _is_whole(value: Variant) -> bool:
	return value is int or (value is float and is_finite(value) and value == floorf(value) and absf(value) < MAX_ID)


static func _invalid(label: String, problem: String) -> Dictionary:
	return ToolError.fail("INVALID_VALUE", "%s %s" % [label, problem])


# The event in the input shape. One the shape cannot express comes back as {type: "other", text}.
static func encode(event: Variant) -> Dictionary:
	var shape := {}
	if event is InputEventKey:
		var physical: bool = event.physical_keycode != KEY_NONE
		var code: int = event.physical_keycode if physical else event.keycode
		# Both codes set, or a key label, is more than the shape says.
		if code != KEY_NONE and not (physical and event.keycode != KEY_NONE) and event.key_label == KEY_NONE and code & KEY_MODIFIER_MASK == 0:
			shape = {"type": "key", "key": OS.get_keycode_string(code), "modifiers": _modifier_names(event), "physical": physical}
	elif event is InputEventMouseButton:
		var name: Variant = MOUSE_BUTTONS.find_key(event.button_index)
		if name != null:
			shape = {"type": "mouseButton", "button": name, "modifiers": _modifier_names(event)}
	elif event is InputEventJoypadButton:
		if event.button_index >= 0 and event.button_index <= MAX_JOYPAD_BUTTON:
			shape = {"type": "joypadButton", "button": int(event.button_index)}
	if shape.is_empty():
		return {"type": "other", "text": var_to_str(event)}
	shape["device"] = event.device
	return shape


static func _modifier_names(event: InputEventWithModifiers) -> Array[String]:
	var names: Array[String] = []
	# CmdOrCtrl sets the platform's own modifier too; naming both would say the same thing twice.
	var remapped := "Meta" if OS.has_feature("macos") else "Ctrl"
	for pair in [["Ctrl", event.ctrl_pressed], ["Shift", event.shift_pressed], ["Alt", event.alt_pressed], ["Meta", event.meta_pressed]]:
		if pair[1] and not (event.command_or_control_autoremap and pair[0] == remapped):
			names.append(pair[0])
	if event.command_or_control_autoremap:
		names.append("CmdOrCtrl")
	return names


# Whether two events are the same binding: the class and every field the input shape sets (D56).
# InputEvent.is_match is not used, because whether it compares device is unverified.
static func same(a: Variant, b: Variant) -> bool:
	if not (a is InputEvent and b is InputEvent) or a.get_class() != b.get_class() or a.device != b.device:
		return false
	if a is InputEventKey:
		return a.keycode == b.keycode and a.physical_keycode == b.physical_keycode and a.key_label == b.key_label and _same_modifiers(a, b)
	if a is InputEventMouseButton:
		return a.button_index == b.button_index and _same_modifiers(a, b)
	if a is InputEventJoypadButton:
		return a.button_index == b.button_index
	return false


static func _same_modifiers(a: InputEventWithModifiers, b: InputEventWithModifiers) -> bool:
	return a.ctrl_pressed == b.ctrl_pressed and a.shift_pressed == b.shift_pressed and a.alt_pressed == b.alt_pressed and a.meta_pressed == b.meta_pressed and a.command_or_control_autoremap == b.command_or_control_autoremap
