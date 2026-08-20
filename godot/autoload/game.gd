extends Node

var mode := "menu"
var dimension := "overworld"
var world_seed := 1
var time_of_day := 0.3
var world = null
var player = null
var drops = null
var entities = null
var hotbar = null


func new_world(seed) -> void:
	world_seed = seed
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
