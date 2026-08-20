extends Node3D

var id := 0
var settled := false
var _vel := Vector3.ZERO
var _grounded := false
var _age := 0.0
var _mesh: MeshInstance3D = null


func _ready() -> void:
	_vel = Vector3((randf() - 0.5) * 3.0, 3.0 + randf() * 2.0, (randf() - 0.5) * 3.0)
	var color := Color(0.6, 0.6, 0.6)
	var info = Data.block(id)
	if info != null:
		color = info.color.side
	var bm := BoxMesh.new()
	bm.size = Vector3(0.3, 0.3, 0.3)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	_mesh = MeshInstance3D.new()
	_mesh.mesh = bm
	_mesh.material_override = mat
	add_child(_mesh)
	var area := Area3D.new()
	var col := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = 1.1
	col.shape = sh
	area.add_child(col)
	add_child(area)


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
	if not _grounded:
		_vel.y -= 26.0 * dt * 0.5
		position += _vel * dt
	if Game.world != null:
		var cell := Vector3i(int(floorf(position.x)), int(floorf(position.y)), int(floorf(position.z)))
		var b: int = Game.world.get_block(cell.x, cell.y, cell.z)
		var info = Data.block(b)
		if info != null and info.solid:
			position.y = float(cell.y) + 1.0 + 0.16
			if absf(_vel.y) > 2.5:
				_vel.y *= -0.3
				_vel.x *= 0.7
				_vel.z *= 0.7
				_grounded = false
			else:
				_vel = Vector3.ZERO
				_grounded = true
		elif _grounded:
			var under: int = Game.world.get_block(int(floorf(position.x)), int(floorf(position.y - 0.2)), int(floorf(position.z)))
			var under_info = Data.block(under)
			if under_info == null or not under_info.solid:
				_grounded = false
	settled = _grounded
	var chest := Vector3(p.position.x, p.position.y + 1.0, p.position.z)
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
	_mesh.position = Vector3(0.0, 0.16 + sin(_age * 3.0) * 0.06, 0.0)
	_mesh.rotation.y += dt * 2.0
