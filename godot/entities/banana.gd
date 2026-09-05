extends RigidBody3D
# AC-0040 bouncy-banana: a fallen banana is a real RigidBody3D — it drops
# from the tree when the player is within 10 blocks (world.gd _banana_tick
# plucks the hanging B_BANANA cell), BOUNCES (PhysicsMaterial.bounce = 0.45
# restitution against the chunk StaticBody3D colliders) until it comes to
# rest (sleeping / ~zero linear_velocity), then the interact pickup (the
# same drop-magnet channel as entities/drop.gd) pulls it in when the player
# is near -> item 126 (eat = health + stamina + gorilla SFX via
# Audio.play("gorilla"), the AC-0039 sound lane).
# Godot 4.7 physics API: linear_velocity (not velocity), is_sleeping(),
# restitution via PhysicsMaterial.bounce on the BODY's
# physics_material_override (CollisionShape3D has no material property in
# this build).
const ITEM_ID := 126
const SETTLE_V := 0.25
const MAGNET_R := 2.5
const PICKUP_R := 1.1
const LIFE := 120.0

var settled := false
var _age := 0.0
var _mesh: MeshInstance3D = null


func _ready() -> void:
	linear_damp = 0.1
	angular_damp = 2.0
	# a small kick so a pluck off a canopy never dead-drops straight down
	linear_velocity = Vector3((randf() - 0.5) * 2.0, 0.0, (randf() - 0.5) * 2.0)
	_mesh = MeshInstance3D.new()
	_mesh.mesh = HeldMeshes.cross_mesh(28)
	_mesh.material_override = HeldMeshes.cross_material()
	_mesh.scale = Vector3(0.4, 0.4, 0.4)
	add_child(_mesh)
	var pm := PhysicsMaterial.new()
	pm.bounce = 0.45
	physics_material_override = pm
	var col := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = 0.28
	col.shape = sh
	add_child(col)


func _process(dt: float) -> void:
	if Game.mode != "play":
		return
	var p = Game.player
	if p == null:
		return
	_age += dt
	if _age > LIFE:
		queue_free()
		return
	if not settled:
		# Bounce until rest: the RigidBody3D settles against the chunk
		# StaticBody3D colliders; sleeping (or ~zero velocity) = at rest.
		var vlen := get_linear_velocity().length()
		if is_sleeping() or vlen < SETTLE_V:
			settled = true
	if settled:
		# The interact pickup — same magnet channel as entities/drop.gd.
		var chest := Vector3(p.position.x, p.position.y + 1.0, p.position.z)
		var dist := position.distance_to(chest)
		if dist < MAGNET_R:
			position = position.lerp(chest, minf(1.0, dt * 5.0))
			if dist < PICKUP_R:
				if p.inv_add(ITEM_ID, 1):
					Audio.play("pickup")
					queue_free()
					return
	_mesh.position = Vector3(0.0, 0.1 + sin(_age * 3.0) * 0.04, 0.0)
	_mesh.rotation.y += dt * 2.0
