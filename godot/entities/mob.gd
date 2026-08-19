class_name Mob
extends Node3D

var key: String = ""
var hp := 0.0
var tamed := false
var vel := Vector3.ZERO
var flee_t := 0.0
var last_hit := -1.0

var _h := 1.0


func _ready() -> void:
	var t = Data.mobs.get(key)
	if t != null:
		hp = float(t["hp"])
		_h = float(t["h"])


func center() -> Vector3:
	return position + Vector3(0.0, _h * 0.55, 0.0)


func hurt(n: float, from: Vector3) -> void:
	hp -= n
	last_hit = Time.get_ticks_msec()
	var dx := position.x - from.x
	var dz := position.z - from.z
	var d := sqrt(dx * dx + dz * dz)
	if d <= 0.0001:
		d = 1.0
	vel = Vector3(dx / d * 5.0, 3.0, dz / d * 5.0)


func try_kill() -> bool:
	if hp > 0.0:
		return false
	var t = Data.mobs.get(key)
	if t != null and not tamed and Game.world != null:
		var drops: Array = t.get("drops", [])
		var at := position + Vector3(0.5, 0.5, 0.5)
		for d in drops:
			if randf() < float(d["ch"]):
				Game.world.spawn_drop(int(d["id"]), at)
	queue_free()
	return true
