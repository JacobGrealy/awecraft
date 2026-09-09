# AC-0191: the isolated combat/movement range - a flat greybox arena with
# 10/25/50 m targets, a water pit and a lava trench, and NO ChunkWorld /
# worldgen. It implements the minimal world interface player.gd pokes at
# (get_block for the fluid cells, spawn_point, recenter no-op, the
# set/spawn no-ops) so the REAL player code runs unmodified: swim /
# drown / lava damage / aim / swing all come from player.gd itself.
#
# Layout (floor top at y=0, so the ground surface is the y=0 plane):
#   * floor = four slabs around a 12x12 pit at x in [-6,6), z in [-36,-24)
#     (pit bottom top at y=-3, water cells y=-3..-1 fill it to the floor)
#   * a 4-wide lava lane at x in [-2,2), z in [10,50) (trench bottom top
#     at y=-2, lava cells y=-2)
#   * targets on the +z spawn line at z=10/25/50, y 0..2 (eye-level cubes)
#   * four boundary walls at x/z = +/-60
class_name RangeWorld
extends Node3D

var is_range := true
var fluid_sim_enabled := false   # the harness sets this on every world
var collision_enabled := true
var render_radius := 4          # main._update_fog reads it per frame

# player.gd probes the eye light per frame (the range has no light grid)
func light_at(_x: float, _y: float, _z: float) -> Dictionary:
	return {"sky": 15, "block": 0, "eff": 15}

const PIT_X0 := -6
const PIT_X1 := 6
const PIT_Z0 := -36
const PIT_Z1 := -24
const PIT_DEPTH := 3             # pit bottom top at y=-3
const LAVA_X0 := -2
const LAVA_X1 := 2
const LAVA_Z0 := 10
const LAVA_Z1 := 50
const LAVA_DEPTH := 2            # trench bottom top at y=-2

var _targets: Array = []
var _fluid_cells := {}


func _ready() -> void:
	Game.world = self
	_build_fluid_cells()
	_build_floor()
	_build_fluid_visuals()
	_build_targets()
	_build_walls()


func _build_fluid_cells() -> void:
	for x in range(PIT_X0, PIT_X1):
		for z in range(PIT_Z0, PIT_Z1):
			for y in range(-PIT_DEPTH, 0):
				_fluid_cells["%d:%d:%d" % [x, y, z]] = 5
	for x in range(LAVA_X0, LAVA_X1):
		for z in range(LAVA_Z0, LAVA_Z1):
			_fluid_cells["%d:%d:%d" % [x, -LAVA_DEPTH, z]] = 24


# the player's only voxel query - water (5) in the pit, lava (24) in the
# trench, air everywhere else (mining/building are therefore inert)
func get_block(x: int, y: int, z: int) -> int:
	var b = _fluid_cells.get("%d:%d:%d" % [int(x), int(y), int(z)], 0)
	return int(b)


func spawn_point() -> Vector3:
	return Vector3(0.5, 0.5, -2.0)


# the player's _recenter fires on every chunk crossing - a no-op here
func recenter(_x: float, _z: float, _force: bool = false, _wy: float = -1.0) -> void:
	pass


func set_block(_x: int, _y: int, _z: int, _id: int) -> void:
	pass


func set_fluid(_x: int, _y: int, _z: int, _id: int, _level: int, _force: bool = false) -> void:
	pass


func spawn_drop(_id: int, _pos: Vector3) -> void:
	pass


# start_range calls this after _create_game_nodes (Game.entities does not
# exist yet during _ready) - the targets must sit in Game.entities for
# the sword's aim_mob and the bow hitscan to scan them
func attach_entities(e: Node) -> void:
	if e == null:
		return
	for t in _targets:
		if is_instance_valid(t) and t.get_parent() != e:
			if t.get_parent() != null:
				t.get_parent().remove_child(t)
			e.add_child(t)


func _slab(cx: float, cy: float, cz: float, sx: float, sy: float, sz: float, color: Color) -> void:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(sx, sy, sz)
	shape.shape = box
	body.add_child(shape)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(sx, sy, sz)
	mi.mesh = bm
	mi.material_override = StandardMaterial3D.new()
	mi.material_override.albedo_color = color
	body.add_child(mi)
	body.position = Vector3(cx, cy, cz)
	add_child(body)


func _box_mi(cx: float, cy: float, cz: float, sx: float, sy: float, sz: float, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(sx, sy, sz)
	mi.mesh = bm
	mi.material_override = StandardMaterial3D.new()
	mi.material_override.albedo_color = color
	mi.position = Vector3(cx, cy, cz)
	add_child(mi)


func _build_floor() -> void:
	var grey := Color(0.42, 0.45, 0.5)
	# z -60..-36 (north of the pit)
	_slab(0.0, -0.5, -48.0, 120.0, 1.0, 24.0, grey)
	# z -24..10 (south of the pit, north of the lane)
	_slab(0.0, -0.5, -7.0, 120.0, 1.0, 34.0, grey)
	# z 50..60 (south of the lane)
	_slab(0.0, -0.5, 55.0, 120.0, 1.0, 10.0, grey)
	# x -60..-6 and 6..60 across the pit band (z -36..-24)
	_slab(-33.0, -0.5, -30.0, 54.0, 1.0, 12.0, grey)
	_slab(33.0, -0.5, -30.0, 54.0, 1.0, 12.0, grey)
	# x -60..-2 and 2..60 across the lane band (z 10..50)
	_slab(-31.0, -0.5, 30.0, 58.0, 1.0, 40.0, grey)
	_slab(31.0, -0.5, 30.0, 58.0, 1.0, 40.0, grey)
	# pit bottom (top at y=-3) and trench bottom (top at y=-2)
	_slab(0.0, -4.5, -30.0, 12.0, 3.0, 12.0, Color(0.3, 0.32, 0.35))
	_slab(0.0, -3.5, 30.0, 4.0, 3.0, 40.0, Color(0.3, 0.28, 0.28))


func _build_fluid_visuals() -> void:
	_box_mi(0.0, -1.5, -30.0, 12.0, 3.0, 12.0, Color(0.15, 0.4, 0.8, 0.55))
	_box_mi(0.0, -2.5, 30.0, 4.0, 1.0, 40.0, Color(0.95, 0.45, 0.1, 0.9))


func _build_targets() -> void:
	for d in [10, 25, 50]:
		var t := RangeTarget.new()
		t.name = "Target%d" % d
		t.dist = d
		t.position = Vector3(0.5, 1.0, float(d))
		_targets.append(t)
		add_child(t)


func _build_walls() -> void:
	var wc := Color(0.25, 0.27, 0.32)
	_slab(0.0, 2.0, -60.0, 120.0, 4.0, 1.0, wc)
	_slab(0.0, 2.0, 60.0, 120.0, 4.0, 1.0, wc)
	_slab(-60.0, 2.0, 0.0, 1.0, 4.0, 120.0, wc)
	_slab(60.0, 2.0, 0.0, 1.0, 4.0, 120.0, wc)
