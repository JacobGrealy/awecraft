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
		# AC-0039: the whoosh on fire (non-positional bed; the arrow's
		# radial gravity above already follows the sphere frame).
		Audio.play("arrow")


func _process(dt: float) -> void:
	t += dt
	if t > LIFETIME:
		queue_free()
		return
	# AC-0145 P3: the light gravity is toward the planet centre (the exact
	# radial), not world -Y; flat mode: -Y as before.
	var aup := Vector3.UP
	if Game.world != null and Game.planet_R > 0.0:
		aup = (position + Vector3(0.0, Game.planet_R, 0.0)).normalized()
	vel -= aup * (GRAV * dt)
	position += vel * dt
	var w = Game.world
	if w != null:
		# a solid cell ends the flight (the first block it reaches).
		# AC-0145 P3: the read runs in the SIM frame — home: the world->flat
		# conversion (the pre-P3 code passed the GLOBAL position straight to
		# the flat grid, a frame mix that read the wrong column ~d²/2R from
		# home); face: the anchor's cell frame.
		var solid := false
		if Game.planet_R <= 0.0:
			solid = w.get_block(int(floorf(position.x)), int(floorf(position.y)), int(floorf(position.z))) != 0
		else:
			var a: Dictionary = w.player_anchor(position)
			var face: int = int(a.get("face", 0))
			if face <= 1:
				var f: Vector3 = w.flat_of_world_pos(position)
				solid = w.get_block(int(floorf(f.x)), int(floorf(f.y)), int(floorf(f.z))) != 0
			else:
				var pv: Vector3 = position - a["origin"]
				var pc: Vector3 = Vector3(pv.dot(a["basis"].x) / a["scale"].x, pv.dot(a["basis"].y), pv.dot(a["basis"].z) / a["scale"].y)
				solid = w.get_block_key(face, int(floorf(pc.x)), int(floorf(pc.y)), int(floorf(pc.z))) != 0
		if solid:
			# AC-0038: the arrow burst (debris flies back off the impact).
			if Game.particles != null:
				Game.particles.burst_arrow(position, vel)
			Audio.play("arrow")  # AC-0039: the landing thud (thwip tail)
			queue_free()
			return
	var p = Game.player
	if p != null and not p.dead:
		# AC-0145 P3: the chest is along the player's LOCAL up (the
		# continuous basis), not world +Y.
		if position.distance_to(p.position + p.basis.y * 1.0) < 0.9:
			Audio.play("hit")  # AC-0039: the body impact (hurt plays below)
			p.damage_player(dmg, "arrow")
			# AC-0038: the same burst on a body hit.
			if Game.particles != null:
				Game.particles.burst_arrow(position, vel)
			queue_free()
