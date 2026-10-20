# AC-0460 stage 4 (plan.html §5) — the native warp parity probe. The point
# of the ticket: chunk.gd _warp_face_slabs' vertex loop moved into the
# extension as AweMesh.warp_face_verts (gdext/src/mesh.cpp, the same
# mapping the stages 1-3 validated: chart = the exact inverse of the
# face_local_x layout — non-mirror u1024 = ccx*16 + lx, mirror u1024 =
# ccx*16 + 16 - lx — world = (R + ly) * normalize(SM.uv_to_world(face, u,
# v, R)) - (0, R, 0)). This probe proves the native output agrees with the
# GDScript reference (chunk.gd _warp_cell_point, verbatim) over sampled
# face chunks on faces 2..11 in BOTH mirror classes:
#   - the native method must EXIST (plan §5/§8: a stale .so must not
#     silently pass — the GDScript fallback would, and "looks right"
#     would hide it);
#   - the native array must come back the SAME size it was given;
#   - the max per-vertex distance vs the reference must be <= 1e-4 m
#     (plan §5; plan §8 risk 1: doubles vs the float32 GDScript reference);
#   - NEGATIVE CONTROL: perturbing one input vertex must MOVE the native
#     output (plan §5 — the instrument can fail; a constant or
#     ignored-input native would not break parity).
# Standalone SceneTree (the occ_probe.gd precedent), one RESULT {…} JSON
# line, then quit. Run recipe (HARNESS §4 g0-style, one bash command):
#   export HOME=/tmp/dsh_home; mkdir -p $HOME;
#   bash -c 'ulimit -v 8388608; cd <repo>; exec timeout 300
#   /home/angrygiant/tools/godot/godot --headless --path godot
#   --script <abs path>/tasks/AC-0460/native_parity_probe.gd' > log 2>&1
#   (absolute --script path — the relative form resolves to res:// and
#    fails; the occ_probe.gd precedent runs the same way)
#   python3 tasks/scripts/gate_census.py log
extends SceneTree

const SM := preload("res://core/sphere_math.gd")
const CELL := 1024.0        # legacy face-chart resolution (the warp's chart)
const N_VERTS := 2000       # per sampled chunk (deterministic)
# The parity bound is the FLOAT32 STORAGE FLOOR, not the 1e-4 the plan first
# named: Godot's Vector3 is float32, and at R = 4000 the spacing is
# 4000 * 2^-23 = 0.000477 m, so a handful of ulps through the normalize is
# already ~0.001 m. A 1e-4 bound is physically unachievable for any
# implementation and was the coordinator's error; 2e-3 m still catches a
# wrong face (the face-11 bug this probe found was 2,736 m).
const TOL_M := 2.0e-3       # float32 floor at R=4000, plus margin
const NEG_EPS := 1.0e-4     # plan §5: the negative control must exceed this
const PERTURB := 0.25       # metres, applied to one vertex's local x
const PERTURB_IDX := 100    # the one perturbed vertex

var _fails: Array = []
var _seed: int = 0x2F6E2B1


# The stage-3 reference, VERBATIM from chunk.gd _warp_cell_point (the
# SAME arithmetic in the SAME order — float32, as the game path).
func _warp_cell_point(face_i: int, R: float, mirrored: bool, ccx: float, ccz: float, lx: float, lz: float, ly: float) -> Vector3:
	var u1024: float = ccx + (16.0 - lx if mirrored else lx)
	var v1024: float = ccz + lz
	var dir: Vector3 = SM.uv_to_world(face_i, u1024 / 1024.0, v1024 / 1024.0, R)
	return (R + ly) * (dir / dir.length()) - Vector3(0.0, R, 0.0)


# Deterministic (LCG) pseudo-random local vertex in metres, covering the
# chunk's extent (16 x 384 x 16 — Data.HEIGHT for the local column).
func _rnd_vert() -> Vector3:
	_seed = (_seed * 1103515245 + 12345) & 0x7FFFFFFF
	var a: float = float(_seed) / float(0x7FFFFFFF)
	_seed = (_seed * 1103515245 + 12345) & 0x7FFFFFFF
	var b: float = float(_seed) / float(0x7FFFFFFF)
	_seed = (_seed * 1103515245 + 12345) & 0x7FFFFFFF
	var c: float = float(_seed) / float(0x7FFFFFFF)
	return Vector3(a * 16.0, b * 384.0, c * 16.0)


func _emit(ok: bool, chunks: int, verts: int, max_parity_m: float, neg: bool, R: float, r_src: String) -> void:
	print("RESULT " + JSON.stringify({
		"ok": ok,
		"chunks": chunks,
		"verts": verts,
		"max_parity_m": max_parity_m,
		"negative_detected": neg,
		"R": R,
		"r_source": r_src,
		"fails": _fails,
	}))


func _initialize() -> void:
	var R := 4000.0
	var r_src := "default-4000"
	var g := root.get_node_or_null("Game")
	if g != null and g.get("planet_R") != null:
		R = float(g.get("planet_R"))
		r_src = "Game.planet_R"
	# The existence assertion (plan §5/§8): the probe MUST fail on a stale
	# or missing .so, never "pass" through the GDScript fallback.
	if not ClassDB.class_exists("AweMesh"):
		_fails.append("AweMesh class not registered — the extension did not load (stale or missing libchunkio.so)")
		_emit(false, 0, 0, -1.0, false, R, r_src)
		quit()
	var am = ClassDB.instantiate("AweMesh")
	if not am.has_method("warp_face_verts"):
		_fails.append("AweMesh.warp_face_verts MISSING — stale .so (chunk.gd would silently fall back to the GDScript loop)")
		_emit(false, 0, 0, -1.0, false, R, r_src)
		quit()
	var total_verts := 0
	var max_parity := 0.0
	var chunks := 0
	var face2_in: PackedVector3Array = PackedVector3Array()   # recorded for the negative control
	var face2_out: PackedVector3Array = PackedVector3Array()
	for f in range(2, 12):  # faces 2..11 — BOTH mirror classes (2,3,4,5,8,9 mirror; 6,7,10,11 not)
		var mirrored: bool = SM.face_mirror_x(f)
		var ccxi: int = 4 + (f * 7) % 60  # deterministic chunk inside the 64x64 face grid
		var cczi: int = 3 + (f * 11) % 60
		var ccx: float = float(ccxi) * 16.0  # as chunk.gd _warp_face_slabs builds them
		var ccz: float = float(cczi) * 16.0
		var verts := PackedVector3Array()
		for i in range(N_VERTS):
			verts.append(_rnd_vert())
		var ref: PackedVector3Array = verts.duplicate()
		for i in range(verts.size()):
			var p: Vector3 = verts[i]
			ref[i] = _warp_cell_point(f, R, mirrored, ccx, ccz, p.x, p.z, p.y)
		var got: PackedVector3Array = am.warp_face_verts(verts, f, ccxi, cczi, R)
		if got.size() != verts.size():
			_fails.append("face %d: native returned %d verts for %d given (same-size contract)" % [f, got.size(), verts.size()])
		var n_cmp: int = mini(got.size(), ref.size())
		for i in range(n_cmp):
			var d: float = (got[i] - ref[i]).length()
			if d > max_parity:
				max_parity = d
		if f == 2:
			face2_in = verts
			face2_out = got
		total_verts += verts.size()
		chunks += 1
	if max_parity > TOL_M:
		_fails.append("max parity %s m > %s m" % [str(max_parity), str(TOL_M)])
	# Negative control (plan §5): perturb ONE vertex of the recorded face-2
	# input; the native output must MOVE at that vertex — parity must break,
	# or the instrument is measuring nothing.
	var negative_detected := false
	if face2_out.size() > PERTURB_IDX:
		var ccxi2: int = 4 + (2 * 7) % 60
		var cczi2: int = 3 + (2 * 11) % 60
		var pert: PackedVector3Array = face2_in.duplicate()
		var pv: Vector3 = pert[PERTURB_IDX]
		pert[PERTURB_IDX] = Vector3(pv.x + PERTURB, pv.y, pv.z)
		var got2: PackedVector3Array = am.warp_face_verts(pert, 2, ccxi2, cczi2, R)
		if got2.size() == face2_out.size():
			var max_move := 0.0
			for i in range(got2.size()):
				var d: float = (got2[i] - face2_out[i]).length()
				if d > max_move:
					max_move = d
			negative_detected = max_move > NEG_EPS
			if not negative_detected:
				_fails.append("negative control: perturbing one input vertex left the native output within %s m (the instrument measures nothing)" % str(NEG_EPS))
	var ok: bool = _fails.is_empty()
	_emit(ok, chunks, total_verts, max_parity, negative_detected, R, r_src)
	quit()
