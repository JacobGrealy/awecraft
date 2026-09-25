extends Node

# AC-0208: the C++ extension (gdext — AweCraft.dll / libchunkio.so) is
# REQUIRED. Every hot path (gen/light/mesh/strips/codec) is C++-only now;
# there is no GDScript fallback. If the extension failed to load, the game
# refuses to start (fail fast — the user must know the .dll is missing).
var cpp_ext_ok := true
var cpp_ext_missing: Array = []


func _ready() -> void:
	for cls in ["ChunkIOPalette", "AweGen", "AweLighting", "AweMesh", "AweStrips"]:
		if not ClassDB.class_exists(cls):
			cpp_ext_missing.append(cls)
	if not cpp_ext_missing.is_empty():
		cpp_ext_ok = false
		var msg := "C++ extension (gdext) not loaded — missing: " + ", ".join(cpp_ext_missing)
		push_error("AWECRAFT: " + msg)
		print("==============================================================")
		print("AWECRAFT CANNOT START — the C++ extension is NOT loaded.")
		print("Missing classes: " + ", ".join(cpp_ext_missing))
		print("The game REQUIRES the C++ extension (no GDScript fallback —")
		print("AC-0208 removed every fallback path). On Windows the .dll ships")
		print("with the game (AweCraft.dll next to AweCraft.exe, built by")
		print("build_windows.sh); on the dev box it is godot/bin/libchunkio.so")
		print("(rebuild with the gdext SConstruct / build_windows.sh).")
		print("==============================================================")
		get_tree().quit()
	_register_pad_nav()


# AC-0268: the analog stick drives the native GUI navigation (ui_left /
# ui_right / ui_up / ui_down). Godot's built-in default ui_* actions carry
# the D-pad but not the stick - the Bedrock controller navigates menus
# with the stick - so the stick events are registered here (the InputMap
# is runtime-mutable; project.godot stays clean). In gameplay no control
# has focus, so the extra action state is inert.
var _pad_nav_added := false
func _register_pad_nav() -> void:
	if _pad_nav_added:
		return
	_pad_nav_added = true
	var nav := {
		"ui_left": [0, -1.0], "ui_right": [0, 1.0],
		"ui_up": [1, -1.0], "ui_down": [1, 1.0],
	}
	for act in nav:
		var ev := InputEventJoypadMotion.new()
		ev.device = 0
		ev.axis = int(nav[act][0])
		ev.axis_value = float(nav[act][1])
		if not InputMap.action_get_events(act).has(ev):
			InputMap.action_add_event(act, ev)

var mode := "menu"
var dimension := "overworld"
var world_seed := 1
# AC-0143 M5: home planet radius (R) - the save planets[0].R, clamped to
# [2000, 8000] on load; reset in new_world(). Used from AC-0144+.
# AC-0306 grid lock: the flat grid derives from R, not a separate knob -
# one cube face is SphereMath.face_width(R) = pi*R/2 columns wide (4W = 2*pi*R
# = one flat metre per metre of arc; W = 6283 at the shipped R = 4000).
var planet_R := 4000.0
var time_of_day := 0.3
var world = null
var player = null
var drops = null
var entities = null
var hotbar = null
# AC-0121: in-game debug console - console_open gates player input while the
# overlay is up; console = the main scene's CanvasLayer (null in the menu).
var console_open := false
var console = null


func new_world(seed) -> void:
	world_seed = seed
	planet_R = 4000.0
	mode = "play"


# AC-0272: cursor-mode mirror. The engine setter is a NO-OP under
# --headless (DisplayServerHeadless), so the harness gate asserts on this
# field; on a real display it mirrors Input.mouse_mode. Every cursor-mode
# transition in the game goes through set_cursor() so the mirror can't go
# stale (the menu/console/player all used to write the engine directly).
var cursor_state := int(Input.MOUSE_MODE_VISIBLE)

func set_cursor(m: int) -> void:
	cursor_state = m
	Input.mouse_mode = m


func pause() -> void:
	if mode == "play":
		mode = "pause"
		set_cursor(Input.MOUSE_MODE_VISIBLE)


func resume() -> void:
	if mode == "pause":
		mode = "play"


func start() -> void:
	mode = "play"
	if player != null:
		player.start()


func message(t) -> void:
	print("MSG ", t)
