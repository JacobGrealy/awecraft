# AC-0191: a range target - a hitable StaticBody cube that both the sword
# (aim_mob -> hurt) and the bow hitscan (the same Game.entities scan) can
# land on. Distinct from a mob: no AI, no drops - it just counts hits and
# takes damage so the range arm can assert on it.
class_name RangeTarget
extends StaticBody3D

var dist := 10          # meters from the spawn line (10 / 25 / 50)
var hp := 10.0
var hits := 0
var _mesh: MeshInstance3D = null


func _init() -> void:
	var body := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.0, 2.0, 1.0)
	body.shape = box
	add_child(body)
	_mesh = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.0, 2.0, 1.0)
	_mesh.mesh = bm
	_mesh.material_override = StandardMaterial3D.new()
	_mesh.material_override.albedo_color = Color(0.85, 0.25, 0.25)
	add_child(_mesh)


# the aim_mob / bow-hitscan contract: a world-space center + hurt()
func center() -> Vector3:
	return position  # the box spans position.y-1..position.y+1 (y=1 -> 0..2)


func hurt(d: float, _from: Vector3) -> void:
	hp -= float(d)
	hits += 1
	if _mesh != null:
		_mesh.material_override.albedo_color = Color(0.4, 0.2, 0.2) if hp <= 0.0 else Color(0.85, 0.25, 0.25)


# the range arm's identity probe (dynamic call, no typed parse needed)
func range_target_dist() -> int:
	return dist
