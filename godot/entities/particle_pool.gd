class_name ParticlePool
extends Node3D
# AC-0038: the pooled particle system — break debris, hit sparks, arrow
# burst, pickup puff. ONE fixed ring of CAP slots behind ONE
# MultiMesh (this engine build has no InstancedMesh3D class): allocated
# once in _ready, NEVER during play, reused round-robin so a burst can
# never grow the pool (over-cap = drop the OLDEST live slot, which the
# ring guarantees is the one being overwritten). Gravity is RADIAL (the
# AC-0145 P3 pattern, arrow.gd:37):
# up = normalize(pos + (0, planet_R, 0)) captured at emission; flat mode
# (no world) falls back to world +Y. Quads are unshaded instance-coloured
# billboards — no new light/sun convention is introduced (if lit debris
# is ever wanted the hook is DayNight.sun_direction, the standing one).
#
# Allocation contract: _allocs counts every allocation this object makes.
# After _ready returns it must never rise again (the gameplay path is
# value-types + pre-allocated packed arrays + engine setters). The
# census_* API is TEST-ONLY (the AWECRAFT_LOGIC=pcensus arm) and does
# allocate — it is never called from the game path.

const CAP := 200
const GRAV := 9.8

const KIND_BREAK := 0
const KIND_HIT := 1
const KIND_ARROW := 2
const KIND_PICKUP := 3

var _mm: MultiMesh = null
var _rng := RandomNumberGenerator.new()
var _allocs := 0
var _allocs_at_ready := 0
var _enabled := true

# slot state (pre-allocated, fixed length CAP)
var _pos: PackedVector3Array = []
var _vel: PackedVector3Array = []
var _up: PackedVector3Array = []
var _age: PackedFloat32Array = []
var _life: PackedFloat32Array = []
var _size: PackedFloat32Array = []
var _c0: PackedVector3Array = []  # census-only: the emit position
var _rr := 0
var _any_alive := false
const _HIDE := Transform3D(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)

# counters (read by the census + the debug overlay if ever wanted)
var emitted := 0
var evicted := 0
var _step_sum_us := 0
var _step_frames := 0

# census (test-only)
var _census_on := false
var _census_recs: Array = []


static func radial_up(pos: Vector3) -> Vector3:
	# AC-0145 P3 pattern (arrow.gd / drop.gd / mob.gd): up = the exact
	# radial toward the planet centre C = (0, -planet_R, 0); flat mode:
	# world +Y.
	if Game.world != null and Game.planet_R > 0.0:
		return (pos + Vector3(0.0, Game.planet_R, 0.0)).normalized()
	return Vector3.UP


func _ready() -> void:
	_allocs += 1  # the pool node itself (allocated by main.gd)
	_pos.resize(CAP)
	_vel.resize(CAP)
	_up.resize(CAP)
	_age.resize(CAP)
	_life.resize(CAP)
	_size.resize(CAP)
	_c0.resize(CAP)
	var pm := PlaneMesh.new()
	_allocs += 1
	pm.size = Vector2(1.0, 1.0)
	var mat := StandardMaterial3D.new()
	_allocs += 1
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	pm.material = mat  # the mesh carries the material (MultiMesh has no
	                   # material property in this engine build — the
	                   # arrow.gd BoxMesh pattern)
	_mm = MultiMesh.new()
	_allocs += 1
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.mesh = pm
	_mm.use_colors = true  # per-instance colour (set_instance_color) —
	                       # must precede instance_count in this build
	_mm.instance_count = CAP
	var mmi := MultiMeshInstance3D.new()
	_allocs += 1
	mmi.name = "PoolInstances"
	mmi.multimesh = _mm
	add_child(mmi)
	var hide := Transform3D(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
	for i in CAP:
		_mm.set_instance_transform(i, hide)
	_rng.randomize()
	_allocs_at_ready = _allocs


func _process(dt: float) -> void:
	if not _enabled or not _any_alive:
		return
	var t0 := Time.get_ticks_usec()
	dt = minf(dt, 0.05)
	# one shared billboard basis for the whole frame (the camera's, or the
	# radial-up fallback when headless has no camera in the tree).
	var basis := _view_basis()
	var any := false
	for i in CAP:
		if _age[i] >= _life[i]:
			continue  # dead slot (age == life marks death)
		_vel[i] = _vel[i] - _up[i] * (GRAV * dt)
		_pos[i] = _pos[i] + _vel[i] * dt
		_age[i] += dt
		if _age[i] >= _life[i]:
			# death: park at zero scale (one-time write)
			_mm.set_instance_transform(i, _HIDE)
			if _census_on:
				_census_recs.append([_c0[i], _pos[i], _up[i], _life[i]])
			continue
		any = true
		var s: float = _size[i] * (1.0 - 0.6 * (_age[i] / _life[i]))
		_mm.set_instance_transform(i, Transform3D(basis.scaled(Vector3(s, s, s)), _pos[i]))
	_any_alive = any
	_step_sum_us += Time.get_ticks_usec() - t0
	_step_frames += 1


func _view_basis() -> Basis:
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		var cb: Basis = cam.global_basis
		return Basis(cb.x, cb.y, -cb.z)
	# headless / menu fallback: an upright basis at the pool origin
	var up := radial_up(global_position)
	var ref := Vector3(0.0, 0.0, 1.0)
	if absf(up.dot(ref)) > 0.9:
		ref = Vector3(1.0, 0.0, 0.0)
	var x := ref.cross(up).normalized()
	var z := up.cross(x)
	return Basis(x, up, z)


# ---------------------------------------------------------------- emission

const _CFG_BREAK := {"n": 12, "lmin": 0.5, "lmax": 0.8, "smin": 1.5, "smax": 3.5, "zmin": 0.10, "zmax": 0.20, "bias": 0.15, "ub": 1.2}
const _CFG_HIT := {"n": 8, "lmin": 0.25, "lmax": 0.40, "smin": 4.0, "smax": 7.0, "zmin": 0.05, "zmax": 0.09, "bias": 0.55, "ub": 1.5}
const _CFG_ARROW := {"n": 10, "lmin": 0.3, "lmax": 0.5, "smin": 1.0, "smax": 3.0, "zmin": 0.06, "zmax": 0.10, "bias": 0.70, "ub": 0.8}
const _CFG_PICK := {"n": 8, "lmin": 0.45, "lmax": 0.65, "smin": 0.4, "smax": 0.9, "zmin": 0.12, "zmax": 0.24, "bias": 0.25, "ub": 1.0}


# The generic workhorse. n particles from pos with the given per-kind cfg
# ({n, lmin, lmax, smin, smax, zmin, zmax, bias, ub}), a base colour and an
# optional preferred direction (dir bias 0 = fully isotropic). jitter: per
# particle tint variation (block-colour debris). NO per-call allocation:
# cfg is the shared const dictionary, colour/direction are value types.
func emit_cfg(pos: Vector3, cfg: Dictionary, col: Color, dir := Vector3.ZERO, jitter := false) -> void:
	var up := radial_up(pos)
	var has_dir := dir.length_squared() > 0.0001
	var d := dir
	if has_dir:
		d = d.normalized()
	for _k in int(cfg["n"]):
		var rv := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0))
		var rl := rv.length()
		if rl > 0.001:
			rv = rv / rl
		var dd := rv
		if has_dir:
			dd = (d * float(cfg["bias"]) + rv * (1.0 - float(cfg["bias"]))).normalized()
		var vel := dd * _rng.randf_range(float(cfg["smin"]), float(cfg["smax"]))
		vel += up * (_rng.randf_range(0.7, 1.3) * float(cfg["ub"]))
		var c := col
		if jitter:
			# block-colour debris gets a per-particle tint jitter
			c = col.lightened(_rng.randf_range(-0.08, 0.10))
		_alloc_slot(pos, vel, up, _rng.randf_range(float(cfg["lmin"]), float(cfg["lmax"])), _rng.randf_range(float(cfg["zmin"]), float(cfg["zmax"])), c)


func burst_break(pos: Vector3, col: Color) -> void:
	emit_cfg(pos, _CFG_BREAK, col, Vector3.ZERO, true)


func burst_hit(pos: Vector3, from := Vector3.ZERO) -> void:
	var dir := Vector3.ZERO
	if from.length_squared() > 0.0001:
		dir = pos - from
	emit_cfg(pos, _CFG_HIT, Color(1.0, 0.78, 0.35), dir)


func burst_arrow(pos: Vector3, dir: Vector3) -> void:
	emit_cfg(pos, _CFG_ARROW, Color(0.85, 0.80, 0.70), -dir)


func burst_pickup(pos: Vector3) -> void:
	emit_cfg(pos, _CFG_PICK, Color(0.92, 0.95, 1.0), radial_up(pos))


# test-only (AWECRAFT_LOGIC=pcensus): n particles with FIXED life and speed,
# velocity strictly TANGENTIAL to the surface at pos (zero radial component)
# — the controlled radial-fall probe. Same seed at two faces gives identical
# per-particle radial dynamics (r = g-integration of the same dt stream)
# while the world-space displacement differs.
func emit_probe(pos: Vector3, n: int, life: float, speed: float) -> void:
	var up := radial_up(pos)
	for _i in n:
		var rv := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0))
		var vt := rv - up * rv.dot(up)
		var vl := vt.length()
		if vl < 0.001:
			var ref := Vector3(1.0, 0.0, 0.0)
			vt = ref - up * ref.dot(up)
			vl = vt.length()
		_alloc_slot(pos, (vt / vl) * speed, up, life, 0.1, Color.WHITE)


func _alloc_slot(pos: Vector3, vel: Vector3, up: Vector3, life: float, size: float, col: Color) -> void:
	# round-robin: the slot being overwritten is the oldest live one (the
	# ring always advances, so every other live slot was written later).
	_rr = (_rr + 1) % CAP
	var i := _rr
	if _age[i] < _life[i]:
		evicted += 1  # drop the oldest
	_pos[i] = pos
	_vel[i] = vel
	_up[i] = up
	_age[i] = 0.0
	_life[i] = life
	_size[i] = size
	_c0[i] = pos
	_mm.set_instance_color(i, col)
	_mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(size, size, size)), pos))
	emitted += 1
	_any_alive = true


# ---------------------------------------------------------------- state

func live() -> int:
	var n := 0
	for i in CAP:
		if _age[i] < _life[i]:
			n += 1
	return n


func set_enabled(v: bool) -> void:
	_enabled = v


func reset_counters() -> void:
	emitted = 0
	evicted = 0


func allocs() -> int:
	return _allocs


func allocs_at_ready() -> int:
	return _allocs_at_ready


func step_ms_avg() -> float:
	if _step_frames == 0:
		return 0.0
	return float(_step_sum_us) / float(_step_frames) / 1000.0


func step_reset() -> void:
	_step_sum_us = 0
	_step_frames = 0


# ------------------------------------------------- census (test-only API)

func census_begin() -> void:
	_census_on = true
	_census_recs = []


func census_end() -> Array:
	# one record per particle that DIED (not per emission): [c0, c1, up, life]
	_census_on = false
	return _census_recs


func seed_census(s: int) -> void:
	_rng.seed = s
