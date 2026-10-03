# AC-0088: the controls-remap core (pure logic - no node dependencies).
#
# The runtime home of every action's bindings is the engine InputMap.
# `project.godot`'s [input] section is the DEFAULTS; this class owns the
# custom layer on top of it: a flat token list persisted as the
# "controls" settings key (settings.gd), merged over the defaults at
# boot (Settings._ready -> Settings.apply_controls), and the conflict
# detector shared by the Controls tab (ui/menu.gd) and the `controls`
# arm (scenes/harness.gd) - one code path, UI and arm agree.
#
# TOKEN GRAMMAR - one "action:cls:idx" string per (action, binding)
# pair, storable in the settings cfg (user://awecraft.cfg):
#   key:<physical_keycode>    a keyboard key (the physical-layout code)
#   mouse:<button_index>      a mouse button / wheel step (1-7)
#   pad:<button_index>        a controller BUTTON (0-21; the analog
#                             sticks and triggers are MOTION events and
#                             are PROTECTED - never remappable, so a
#                             move_* action always keeps its stick)
# A stored list never stores the protected events: an action's motion
# bindings ride along with the defaults, untouched.
#
# MERGE RULE (the safe-fallback core): for each managed action the
# result = the action's default events MINUS every default binding
# whose CLASS has at least one saved token for that action, PLUS the
# saved tokens' events (last wins per class). An action with NO saved
# tokens keeps its FULL default set, so a missing entry can never
# empty an action - a corrupt or partial saved map can only lose
# customisations, never reach into a default. The belt-and-braces net
# (an action whose merged list would be empty gets its full default
# set back) is asserted by the `controls` arm, not assumed.
#
# REBIND SEMANTICS (replace, not add - ONE decision, UI + arm agree):
# a captured input REPLACES the action's current binding of the
# captured CLASS (the first one, when an action holds several of a
# class) and is ADDED when the action has no binding of that class
# yet. Other classes (and all protected motion events) are untouched:
# "rebind jump's key to X" leaves the pad-A binding; "give fly a pad
# button" adds the class. The UI capture only offers the classes the
# action actually uses (its default classes), so "as the action
# allows" is enforced, not assumed.
class_name ControlsMap
extends RefCounted

# The managed actions, grouped the way the Controls tab lists them.
# Built-in ui_* actions are deliberately NOT managed: AC-0087 left them
# to the engine defaults (native GUI focus navigation), and they fire
# in the GUI stage only - remapping them here could quietly break menu
# navigation without any game-side signal.
const MANAGED_GROUPS := [
	["Movement", ["move_forward", "move_back", "move_left", "move_right", "jump", "sprint", "pad_sprint"]],
	["Combat & Items", ["attack", "use", "inventory", "pad_inventory", "pad_craft", "pad_hotbar_prev", "pad_hotbar_next"]],
	["Menu & UI", ["ui_pause", "pad_pause", "pad_accept", "pad_cancel"]],
	["Developer", ["fly", "time", "debug"]],
]

# Engine built-in prefix - conflicts against these are REPORTED but not
# blocking (they fire in the GUI stage only; the default map already
# co-mingles Space on jump and on ui_accept).
const BUILTIN_PREFIX := "ui_"

# Modifier-only keys can never be a binding (a bare Shift does nothing
# in the game's unhandled/poll stages; it is a state, not a press).
const MODIFIER_KEYS := [
	KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META, KEY_CAPSLOCK, KEY_NUMLOCK, KEY_SCROLLLOCK,
]

const MOUSE_NAMES := {
	1: "Left Mouse", 2: "Right Mouse", 3: "Middle Mouse",
	4: "Mouse Wheel Up", 5: "Mouse Wheel Down",
	6: "Mouse XButton1", 7: "Mouse XButton2",
}

# Godot 4.7 joypad button layout (SDL; verified by AC-0087 against the
# binary - the enums are NOT exposed as GDScript constants in 4.7).
const PAD_NAMES := {
	0: "A", 1: "B", 2: "X", 3: "Y", 4: "Misc", 5: "Guide", 6: "Start",
	7: "L3", 8: "R3", 9: "LB", 10: "RB", 11: "Dpad Up", 12: "Dpad Down",
	13: "Dpad Left", 14: "Dpad Right", 15: "Misc 1", 16: "Misc 2",
	17: "Misc 3", 18: "Misc 4", 19: "Misc 5", 20: "Misc 6", 21: "Misc 7",
}

# The letter keycodes ARE the ASCII codes, so the label is a plain
# index into the alphabet (no runtime character APIs needed).
const ALPHABET := "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

const KEY_NAMES := {
	KEY_SPACE: "Space", KEY_ENTER: "Enter", KEY_ESCAPE: "Escape", KEY_TAB: "Tab",
	KEY_BACKSPACE: "Backspace", KEY_DELETE: "Delete", KEY_INSERT: "Insert",
	KEY_HOME: "Home", KEY_END: "End", KEY_PAGEUP: "PgUp", KEY_PAGEDOWN: "PgDn",
	KEY_LEFT: "Left", KEY_UP: "Up", KEY_RIGHT: "Right", KEY_DOWN: "Down",
	KEY_SHIFT: "Shift", KEY_CTRL: "Ctrl", KEY_ALT: "Alt", KEY_META: "Meta",
	KEY_F1: "F1", KEY_F2: "F2", KEY_F3: "F3", KEY_F4: "F4", KEY_F5: "F5",
	KEY_F6: "F6", KEY_F7: "F7", KEY_F8: "F8", KEY_F9: "F9", KEY_F10: "F10",
	KEY_F11: "F11", KEY_F12: "F12",
}

# action -> {tokens: [remappable default tokens], protected: [motion events]}
var defaults: Dictionary = {}
var captured := false


static func action_list() -> Array:
	var out: Array = []
	for g in MANAGED_GROUPS:
		for a in g[1]:
			out.append(a)
	return out


static func is_managed(a: String) -> bool:
	for g in MANAGED_GROUPS:
		if g[1].has(a):
			return true
	return false


static func action_label(a: String) -> String:
	match a:
		"move_forward": return "Move Forward"
		"move_back": return "Move Back"
		"move_left": return "Move Left"
		"move_right": return "Move Right"
		"jump": return "Jump"
		"sprint": return "Sprint (keyboard)"
		"attack": return "Attack / mine"
		"use": return "Use / place"
		"inventory": return "Inventory (keyboard)"
		"pad_inventory": return "Inventory (controller)"
		"pad_craft": return "Craft (controller)"
		"pad_hotbar_prev": return "Hotbar previous"
		"pad_hotbar_next": return "Hotbar next"
		"ui_pause": return "Pause (keyboard)"
		"pad_pause": return "Pause (controller)"
		"pad_accept": return "Confirm (controller)"
		"pad_cancel": return "Cancel (controller)"
		"fly": return "Toggle fly (dev)"
		"time": return "Cycle time (dev)"
		"debug": return "Debug label (dev)"
	return a


# ---------------------------------------------------------------- tokens

static func token_class(tok: String) -> String:
	var p: Array = tok.split(":")
	if p.size() != 2:
		return ""
	var c: String = p[0]
	if c != "key" and c != "mouse" and c != "pad":
		return ""
	return c


static func token_index(tok: String) -> int:
	var p: Array = tok.split(":")
	if p.size() != 2 or not p[1].is_valid_int():
		return -1
	return p[1].to_int()


static func make_token(cls: String, idx: int) -> String:
	return "%s:%d" % [cls, idx]


# A valid REMAPPABLE token: right class, an index in that class's
# range, and (for keys) not a modifier-only code.
static func valid_token(tok: String) -> bool:
	var c := token_class(tok)
	var i := token_index(tok)
	if c == "" or i < 0:
		return false
	match c:
		"key":
			# ASCII (1..255) or the special-key block (Escape 4194305
			# through the KEY_BUTTON range). Anything else is a corrupt
			# token - it could never match a real press, so it would be
			# a DEAD binding (an action "bound" to a ghost key).
			return (i >= 1 and i <= 255 or i >= 4194305 and i <= 4194402) \
				and not MODIFIER_KEYS.has(i)
		"mouse":
			return i >= 1 and i <= 7
		"pad":
			return i >= 0 and i <= 21
	return false


# The canonical identity of a REMAPPABLE event (motion events / unknown
# classes -> EMPTY ARRAY; 4.7 refuses to assign null to a typed Array,
# so [] is the "no identity" sentinel everywhere). Keys compare by
# physical code (falling back to keycode, for the built-in ui_*
# defaults which bind by keycode), mouse by button, pad by button.
static func event_identity(ev) -> Array:
	if ev is InputEventKey:
		var k: InputEventKey = ev
		var kc := int(k.physical_keycode)
		if kc == 0:
			kc = int(k.keycode)
		if kc == 0:
			return []
		return ["key", kc]
	if ev is InputEventMouseButton:
		var mb: InputEventMouseButton = ev
		return ["mouse", int(mb.button_index)]
	if ev is InputEventJoypadButton:
		var jb: InputEventJoypadButton = ev
		return ["pad", int(jb.button_index)]
	return []


# The class ("key"/"mouse"/"pad"/"motion") of any event, "" if none.
static func event_class(ev) -> String:
	if ev is InputEventKey:
		return "key"
	if ev is InputEventMouseButton:
		return "mouse"
	if ev is InputEventJoypadButton:
		return "pad"
	if ev is InputEventJoypadMotion:
		return "motion"
	return ""


# A pressed, non-modifier-state remappable event -> its token ("" if
# not one). Release events and motion events are "".
# PURE mapping: the token of any event, pressed or released. Stored
# [input] events are the pressed=false form (the InputMap matches both
# edges), so the token CANNOT key off .pressed - callers of the
# live-capture path filter release events themselves.
static func event_to_token(ev) -> String:
	var idt: Array = event_identity(ev)
	if idt.is_empty():
		return ""
	return make_token(idt[0], int(idt[1]))


# token -> a fresh event the InputMap accepts (physical key with
# keycode 0, pressed; mouse button pressed; pad button pressed - the
# same shape the project.godot defaults use).
static func token_to_event(tok: String) -> InputEvent:
	var c := token_class(tok)
	var i := token_index(tok)
	if c == "" or i < 0:
		return null
	match c:
		"key":
			var k := InputEventKey.new()
			k.physical_keycode = i
			k.pressed = true
			return k
		"mouse":
			var m := InputEventMouseButton.new()
			m.button_index = i
			m.pressed = true
			return m
		"pad":
			var p := InputEventJoypadButton.new()
			p.button_index = i
			p.pressed = true
			return p
	return null


# The display label for a token (the rebind button text).
static func label_for_token(tok: String) -> String:
	var c := token_class(tok)
	var i := token_index(tok)
	match c:
		"key":
			if KEY_NAMES.has(i):
				return KEY_NAMES[i]
			if i >= KEY_A and i <= KEY_Z:
				return ALPHABET[i - KEY_A]  # the letter keycodes ARE the ASCII codes
			if i >= KEY_0 and i <= KEY_9:
				return str(i - KEY_0)
			return "Key %d" % i
		"mouse":
			return String(MOUSE_NAMES.get(i, "Mouse %d" % i))
		"pad":
			return String(PAD_NAMES.get(i, "Pad %d" % i))
	return tok


# ------------------------------------------------------------ defaults

# Capture the project.godot defaults (the InputMap as loaded, BEFORE
# any custom layer is applied). Called once from Settings._ready.
func capture_defaults() -> void:
	defaults = {}
	for a in action_list():
		var toks: Array = []
		var prot: Array = []
		for ev in InputMap.action_get_events(a):
			var t := event_to_token(ev)
			if t != "":
				toks.append(t)
			elif event_class(ev) == "motion":
				prot.append(ev.duplicate())
			# any other class (there is none in practice) is dropped
			# from the merge - the defaults it carried are gone anyway,
			# and nothing in the managed set uses it.
		defaults[a] = {"tokens": toks, "protected": prot}
	captured = true


# The classes a managed action uses by default (the capture offers
# exactly these; "motion" is protected and never offered).
func default_classes(a: String) -> Array:
	var out: Array = []
	var d: Dictionary = defaults.get(a, {})
	for t in d.get("tokens", []):
		var c := token_class(t)
		if c != "" and not out.has(c):
			out.append(c)
	for ev in d.get("protected", []):
		var c := event_class(ev)
		if c != "" and not out.has(c):
			out.append(c)
	return out


# The first default (or saved) binding of a class on an action - the
# rebind button's "current" value.
func current_binding(a: String, cls: String) -> String:
	var saved: Array = []
	for s in Settings.values.get("controls", []):
		if entry_action(s) == a and token_class(entry_token(s)) == cls:
			saved.append(entry_token(s))
	if not saved.is_empty():
		return saved[saved.size() - 1]
	var d: Dictionary = defaults.get(a, {})
	for t in d.get("tokens", []):
		if token_class(t) == cls:
			return t
	return ""


# ------------------------------------------------------------ merging

# "action:cls:idx" -> the action part ("" if malformed).
static func entry_action(entry: String) -> String:
	var p: Array = entry.split(":")
	if p.size() != 3:
		return ""
	return p[0]


# "action:cls:idx" -> the "cls:idx" token part ("" if malformed).
static func entry_token(entry: String) -> String:
	var p: Array = entry.split(":")
	if p.size() != 3:
		return ""
	return p[1] + ":" + p[2]


# Validate a stored controls value (any Variant from the cfg) into a
# clean token list: non-string entries drop, unknown actions drop,
# malformed tokens drop, a class an action does not use drops, and the
# LAST entry per (action, class) wins (the UI stores at most one per
# class; a hand-edited duplicate is resolved deterministically).
# Nothing here can empty an action - it only filters the CUSTOM layer.
func sanitize_array(v) -> Array:
	var out: Array = []
	var seen := {}
	if typeof(v) != TYPE_ARRAY:
		return out
	for e in v:
		if typeof(e) != TYPE_STRING:
			continue
		var a := entry_action(e)
		var t := entry_token(e)
		if not is_managed(a) or not valid_token(t):
			continue
		if not default_classes(a).has(token_class(t)):
			continue
		var k := a + "/" + token_class(t)
		if seen.has(k):
			out.erase(seen[k])
		seen[k] = out.size()
		out.append(e)
	return out


# The merge (see the rule at the top of this file). `saved` is UNTYPED
# on purpose: the corrupt-map tests feed it hostile values (a String,
# a number, an array of non-strings) and sanitize_array is what keeps
# them out. Returns action -> Array of events for every managed action.
func merge(saved) -> Dictionary:
	var per: Dictionary = {}
	for s in sanitize_array(saved):
		var a := entry_action(s)
		var t := entry_token(s)
		var cls := token_class(t)
		if not per.has(a):
			per[a] = {}
		var per_a: Dictionary = per[a]
		if not per_a.has(cls):
			per_a[cls] = []
		per_a[cls].append(t)
	var out: Dictionary = {}
	for a in action_list():
		var d: Dictionary = defaults.get(a, {"tokens": [], "protected": []})
		var evs: Array = []
		for ev in d.get("protected", []):
			evs.append(ev)
		var saved_here: Dictionary = per.get(a, {})
		var replaced: Array = saved_here.keys()
		for t in d.get("tokens", []):
			if replaced.has(token_class(t)):
				continue  # a saved token of this class replaces all defaults of it
			evs.append(token_to_event(t))
		for c in replaced:
			var list: Array = saved_here[c]
			evs.append(token_to_event(list[list.size() - 1]))
		if evs.is_empty():
			# the belt-and-braces net: an emptied action gets its full
			# default set back (the UI can never produce this - it
			# replaces, never clears - but a hostile cfg must not be
			# able to unbind an action).
			for t in d.get("tokens", []):
				evs.append(token_to_event(t))
			for ev in d.get("protected", []):
				if not evs.has(ev):
					evs.append(ev)
		out[a] = evs
	return out


# Apply a merged map to the live InputMap (erase + re-add per action;
# the action entry and its deadzone survive action_erase_events).
func apply_map(map: Dictionary) -> void:
	for a in action_list():
		if not InputMap.has_action(a):
			InputMap.add_action(a, 0.5)
		InputMap.action_erase_events(a)
		for ev in map.get(a, []):
			InputMap.action_add_event(a, ev)


# ------------------------------------------------------------- queries

# Does an action's CURRENT InputMap events carry (cls, idx)?
func class_has(a: String, cls: String, idx: int) -> bool:
	if not InputMap.has_action(a):
		return false
	for ev in InputMap.action_get_events(a):
		var idt: Array = event_identity(ev)
		if idt.size() == 2 and idt[0] == cls and int(idt[1]) == idx:
			return true
	return false


# Does a MERGED event list (the arm's offline check) carry (cls, idx)?
func list_has(evs: Array, cls: String, idx: int) -> bool:
	for ev in evs:
		var idt: Array = event_identity(ev)
		if idt.size() == 2 and idt[0] == cls and int(idt[1]) == idx:
			return true
	return false


# Every managed action holds at least one event in the given map.
# THE completeness invariant - the arm asserts it on every case, and
# asserts it FAILS on a deliberately emptied map (the instrument must
# be able to go red).
func map_complete(map: Dictionary) -> bool:
	for a in action_list():
		if not map.has(a) or (map[a] as Array).is_empty():
			return false
	return true


# The conflict detector: every OTHER action currently carrying an
# event with the same identity as tok. Builtin ui_* conflicts are
# flagged, not blocking (see rebind_action in settings.gd).
func conflicts_for(tok: String, self_action: String) -> Array:
	var want: Array = event_identity(token_to_event(tok))
	if want.is_empty():
		return []
	var out: Array = []
	for a in InputMap.get_actions():
		if a == self_action:
			continue
		for ev in InputMap.action_get_events(a):
			var idt: Array = event_identity(ev)
			# A stored event carrying a MODIFIER (the Ctrl+X built-ins)
			# never collides with a plain-key binding: the token grammar
			# has no modifier state, so a captured key is always a plain
			# press, and plain-X does not fire Ctrl+X.
			if idt.size() == 2 and idt == want and not event_has_mods(ev):
				out.append({"action": a, "builtin": a.begins_with(BUILTIN_PREFIX)})
				break
	return out


# Does the stored event require any modifier to fire?
static func event_has_mods(ev) -> bool:
	if ev is InputEventKey:
		var k: InputEventKey = ev
		return bool(k.ctrl_pressed) or bool(k.alt_pressed) or bool(k.meta_pressed) or bool(k.shift_pressed)
	if ev is InputEventMouseButton:
		var m: InputEventMouseButton = ev
		return bool(m.ctrl_pressed) or bool(m.alt_pressed) or bool(m.meta_pressed) or bool(m.shift_pressed)
	return false


# A deterministic per-action sorted token list (motion events as
# "motion:<axis>:<sign>") - the byte-identity anchor for the
# reset-all assertion.
func serialize() -> Dictionary:
	var out: Dictionary = {}
	for a in action_list():
		var toks: Array = []
		if InputMap.has_action(a):
			for ev in InputMap.action_get_events(a):
				if ev is InputEventJoypadMotion:
					var m: InputEventJoypadMotion = ev
					toks.append("motion:%d:%d" % [int(m.axis), 1 if m.axis_value >= 0.0 else -1])
				else:
					var t := event_to_token(ev)
					if t != "":
						toks.append(t)
		toks.sort()
		out[a] = toks
	return out


func serialize_map(map: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for a in action_list():
		var toks: Array = []
		for ev in map.get(a, []):
			if ev is InputEventJoypadMotion:
				var m: InputEventJoypadMotion = ev
				toks.append("motion:%d:%d" % [int(m.axis), 1 if m.axis_value >= 0.0 else -1])
			else:
				var t := event_to_token(ev)
				if t != "":
					toks.append(t)
		toks.sort()
		out[a] = toks
	return out
