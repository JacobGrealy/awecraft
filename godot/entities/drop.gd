extends Node3D

var id := 0
var settled := false
var _vel := Vector3.ZERO
var _grounded := false
var _age := 0.0
var _mesh: MeshInstance3D = null
var _pivot: Node3D = null


func _ready() -> void:
	_vel = Vector3((randf() - 0.5) * 3.0, 3.0 + randf() * 2.0, (randf() - 0.5) * 3.0)
	_mesh = MeshInstance3D.new()
	var info = Data.block(id)
	var is_cross := info != null and bool(info.get("cross", false)) and not bool(info.get("thin", false))
	if is_cross:
		_mesh.mesh = HeldMeshes.cross_mesh(id)
		_mesh.material_override = HeldMeshes.cross_material()
	else:
		_mesh.mesh = HeldMeshes.box_mesh(id)
		_mesh.material_override = HeldMeshes.box_material()
	_mesh.scale = Vector3(0.3, 0.3, 0.3)
	# AC-0093: the box/cross geometry is built in [0,1]^3 (centred at (0.5,0.5,0.5)
	# in mesh-local space), so a local Y-spin of the MESH orbits the geometry in a
	# circle of radius 0.3*sqrt(0.5) ~= 0.212 instead of spinning it in place. The
	# rotation was never the bug - the PIVOT was: the mesh origin is the box's
	# corner, not its centre. Spin about the box centre: reparent the mesh under a
	# pivot whose origin is the box centre (the mesh offset (-0.15,-0.15,-0.15)
	# recentres the [0,1]^3 geometry on it) and rotate the PIVOT, not the mesh. The
	# drop node position is untouched (fall/settle + the magnet read it) and the box
	# fills the exact same region as before - only the orbit is gone.
	_mesh.position = Vector3(-0.15, -0.15, -0.15)
	_pivot = Node3D.new()
	_pivot.add_child(_mesh)
	add_child(_pivot)
	var area := Area3D.new()
	var col := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = 1.1
	col.shape = sh
	area.add_child(col)
	add_child(area)


# AC-0145 P3: the drop's SIM-frame ground read — home pair: the flat net via
# the world->flat conversion (the pre-P3 code passed the GLOBAL position
# straight to the flat grid: the frames agree only near the home centre, so
# a drop ~d from home read the wrong column and grounded at d²/2R above the
# real surface); face: the anchor's cell frame (the same axes/scale the
# player's sim reads use). Returns the frame id + the drop's in-frame coords.
func _ground_frame(pos: Vector3, w) -> Dictionary:
	var R: float = Game.planet_R
	if R <= 0.0:
		return {"face": 0, "bid": w.get_block(int(floorf(pos.x)), int(floorf(pos.y)), int(floorf(pos.z))), "x": pos.x, "y": pos.y, "z": pos.z, "anchor": null}
	var a: Dictionary = w.player_anchor(pos)
	var face: int = int(a.get("face", 0))
	if face <= 1:
		var f: Vector3 = w.flat_of_world_pos(pos)
		return {"face": 0, "bid": w.get_block(int(floorf(f.x)), int(floorf(f.y)), int(floorf(f.z))), "x": f.x, "y": f.y, "z": f.z, "anchor": a}
	var p2: Vector3 = pos - a["origin"]
	var bx: Vector3 = a["basis"].x
	var bn: Vector3 = a["basis"].y
	var bz: Vector3 = a["basis"].z
	var sc2: Vector2 = a["scale"]
	var pc: Vector3 = Vector3(p2.dot(bx) / sc2.x, p2.dot(bn), p2.dot(bz) / sc2.y)
	return {"face": face, "bid": w.get_block_key(face, int(floorf(pc.x)), int(floorf(pc.y)), int(floorf(pc.z))), "x": pc.x, "y": pc.y, "z": pc.z, "anchor": a}


# AC-0145 P3: a sim-frame point back to the GLOBAL frame (the inverse of
# _ground_frame's conversion — world_pos_of_flat on home, the anchor chunk
# transform on a face; the flat-mode passthrough stays the identity).
func _frame_to_world(fr: Dictionary, x: float, y: float, z: float, w) -> Vector3:
	var a: Dictionary = fr["anchor"]
	if a == null:
		return Vector3(x, y, z)
	if int(fr["face"]) <= 1:
		return w.world_pos_of_flat(x, y, z)
	return a["origin"] + a["basis"].x * x + a["basis"].y * y + a["basis"].z * z


func _process(dt: float) -> void:
	if Game.mode != "play":
		return
	var p = Game.player
	if p == null:
		return
	_age += dt
	if _age > 120.0:
		queue_free()
		return
	# AC-0145 P3: the fall is toward the planet centre (up = the EXACT
	# radial), not world -Y — on the home pair the two agree near the spawn
	# and diverge as the surface tilts. Flat mode (no world / R <= 0): -Y,
	# as before.
	var w = Game.world
	var up := Vector3.UP
	if w != null and Game.planet_R > 0.0:
		up = (position + Vector3(0.0, Game.planet_R, 0.0)).normalized()
	if not _grounded:
		_vel -= up * (26.0 * 0.5) * dt
		position += _vel * dt
	if w != null:
		var fr := _ground_frame(position, w)
		var info = Data.block(int(fr["bid"]))
		if info != null and info.solid:
			# snap the feet to the top of the solid along the SIM frame
			# (flat y on home; the face y axis — unscaled metres — on a face)
			var top_y: float = float(int(floorf(float(fr["y"])))) + 1.0 + 0.16
			position = _frame_to_world(fr, float(fr["x"]), top_y, float(fr["z"]), w)
			# the bounce: the RADIAL component reflects (restitution 0.3),
			# the tangent component damps (the old -Y y/x/z split, radialized)
			var vr := _vel.dot(up)
			var vt: Vector3 = _vel - up * vr
			if absf(vr) > 2.5:
				_vel = up * (-vr * 0.3) + vt * 0.7
				_grounded = false
			else:
				_vel = Vector3.ZERO
				_grounded = true
		elif _grounded:
			# the walked-off-the-edge check, 0.2 m below the feet along -up
			var ufr := _ground_frame(position - up * 0.2, w)
			var under_info = Data.block(int(ufr["bid"]))
			if under_info == null or not under_info.solid:
				_grounded = false
	settled = _grounded
	# the magnet: the chest is along the player's LOCAL up (the continuous
	# basis), not world +Y (AC-0145 P3).
	var chest: Vector3 = p.position + p.basis.y * 1.0
	var dist := position.distance_to(chest)
	if dist < 2.5:
		position = position.lerp(chest, minf(1.0, dt * 5.0))
		_vel = Vector3.ZERO
		_grounded = false
		if dist < 1.1:
			if p.inv_add(id, 1):
				Audio.play("pickup")
				queue_free()
				return
	# AC-0093: spin the pivot (the box's centre), not the mesh - the mesh offset
	# recentres the geometry on the pivot, so this is a true in-place spin. The bob
	# (0.31 = 0.16 hover + 0.15 half-block centre) and the rate (2.0 rad/s) are
	# unchanged; the pickup magnet + fall/settle still move the drop node only.
	_pivot.position = Vector3(0.15, 0.31 + sin(_age * 3.0) * 0.06, 0.15)
	_pivot.rotation.y += dt * 2.0
