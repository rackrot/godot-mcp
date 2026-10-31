extends SceneTree


# Prints one JSON line per action named in the user args (after `--`): what this game process sees in
# its InputMap, which is loaded from project.godot at start. "matches" is whether a synthetic Ctrl+P on
# device 0 triggers the action.
func _init() -> void:
	for action in OS.get_cmdline_user_args():
		print("ACTION:", JSON.stringify(_describe(action)))
	quit()


func _describe(action: String) -> Dictionary:
	if not InputMap.has_action(action):
		return {"action": action, "exists": false}
	var events := []
	for event in InputMap.action_get_events(action):
		var seen := {"class": event.get_class(), "device": event.device}
		if event is InputEventWithModifiers:
			seen["ctrl"] = event.ctrl_pressed
			seen["shift"] = event.shift_pressed
			seen["alt"] = event.alt_pressed
			seen["meta"] = event.meta_pressed
			seen["autoremap"] = event.command_or_control_autoremap
		if event is InputEventKey:
			seen["physicalKeycode"] = event.physical_keycode
			seen["keycode"] = event.keycode
		if event is InputEventMouseButton or event is InputEventJoypadButton:
			seen["buttonIndex"] = event.button_index
		events.append(seen)
	var press := InputEventKey.new()
	press.physical_keycode = KEY_P
	press.ctrl_pressed = true
	press.device = 0
	press.pressed = true
	return {
		"action": action,
		"exists": true,
		"deadzone": InputMap.action_get_deadzone(action),
		"events": events,
		"matches": InputMap.event_is_action(press, action),
	}
