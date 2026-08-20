extends Node

var volume := 100.0


func _ready() -> void:
	apply()


func set_volume(v) -> void:
	volume = clampf(float(v), 0.0, 100.0)
	apply()


func apply() -> void:
	var idx := AudioServer.get_bus_index("Master")
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, linear_to_db(volume / 100.0))


func play(_name) -> void:
	pass
