extends Node

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
