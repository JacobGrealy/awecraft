class_name Arrow
extends Node3D
# AC-0037: the game's first projectile - a skeleton's arrow. Simple
# kinematics (velocity + light gravity, like an MC arrow's arc), an 8 s
# lifetime, it stops on a solid block cell, and it hits the player on
# proximity. The skeleton's volley target is the player's chest, so the
# weak gravity lands it in the body at the 10 m stand-off band.

var vel := Vector3.ZERO
var dmg := 2.0
var t := 0.0

const LIFETIME := 8.0
const GRAV := 2.0


func _ready() -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.06, 0.06, 0.55)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.3, 0.16)
	bm.material = mat
	mi.mesh = bm
	add_child(mi)
	if vel.length() > 0.001:
		look_at(global_position + vel, Vector3.UP)


func _process(dt: float) -> void:
	t += dt
	if t > LIFETIME:
		queue_free()
		return
	vel.y -= GRAV * dt
	position += vel * dt
	var w = Game.world
	if w != null:
		# a solid cell ends the flight (the first block it reaches)
		if w.get_block(int(floorf(position.x)), int(floorf(position.y)), int(floorf(position.z))) != 0:
			queue_free()
			return
	var p = Game.player
	if p != null and not p.dead:
		if position.distance_to(p.position + Vector3(0.0, 1.0, 0.0)) < 0.9:
			p.damage_player(dmg, "arrow")
			queue_free()
