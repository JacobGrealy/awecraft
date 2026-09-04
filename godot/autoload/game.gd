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


var mode := "menu"
var dimension := "overworld"
var world_seed := 1
# AC-0143 M5: home planet radius (R) - the save planets[0].R, clamped to
# [2000, 8000] on load; reset in new_world(). Used from AC-0144+.
var planet_R := 4000.0
var time_of_day := 0.3
var world = null
var player = null
var drops = null
var entities = null
var hotbar = null


func new_world(seed) -> void:
	world_seed = seed
	planet_R = 4000.0
	mode = "play"


func pause() -> void:
	if mode == "play":
		mode = "pause"
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func resume() -> void:
	if mode == "pause":
		mode = "play"


func start() -> void:
	mode = "play"
	if player != null:
		player.start()


func message(t) -> void:
	print("MSG ", t)
