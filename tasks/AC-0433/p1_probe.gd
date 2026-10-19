extends SceneTree
# AC-0433 P1 — standalone validation of the coordinator's unified model
# (docs/ac0433-unified-model.html — the coordinator's CHOSE design; this
# script validates it and makes no design decisions of its own).
#
#   Grid under test (plan §3.1): the uniform nominal-metre grid
#       H = face_width(R)/2, N = 16*ceil(H/16), short chart axis N cells,
#       long axis 2N; faces 4-7 (Nu,Nv) = (2N,N), all others (N,2N).
#       R = 4000 is the stated fixture, not a production constant.
#   Placement under test (plan §3.2/§3.3): shared-vertex radial embedding
#       P(h) = (R+h)*n - (0,R,0) on the canonical integer cube vertex Q,
#       n = normalize(SphereMath.uv_to_world(owning face, chart-inverse u,v)),
#       owning face = the shipped face_for_dir tie order on the RAW Q,
#       then the chart inverse formulas (sphere_math.gd:129-144) on C = Q/N.
#       Deliberately NOT world_to_face(Q) (Q is unwarped cube coordinates).
#
# Every mapping call goes through the shipped SphereMath (called, never
# transcribed); the control-site selection is copied from harness.gd's
# _ac0433probe_test (lines ~36232-36386). No autoloads, no production
# references, deterministic. Output: one RESULT JSON line; exit 0 iff every
# plan tolerance holds, else exit 1 + HONEST DEVIATION lines.

const R_FIXTURE: float = 4000.0
const HEIGHTS: Array = [0.0, 140.0, 168.0]
const TOL_M: float = 0.001  # plan §3: world-space tolerance (mm), not weakened

var _N: int = 0
var _fails: Array = []

func _initialize() -> void:
	call_deferred("_run_and_quit")

func _run_and_quit() -> void:
	quit(_run())

# ---------------------------------------------------------------- helpers

func _shape(face: int) -> Vector2i:
	# plan §3.1: faces 4-7 use (Nu,Nv) = (2N,N); all other faces (N,2N).
	if face >= 4 and face <= 7:
		return Vector2i(2 * _N, _N)
	return Vector2i(_N, 2 * _N)

# plan §3.2: integer cube-lattice triple Q of the chart vertex (i, j).
func _vertex_q(face: int, i: int, j: int) -> Vector3i:
	var n := _N
	match face:
		0: return Vector3i(i, n, j - n)
		1: return Vector3i(i - n, n, j - n)
		2: return Vector3i(i, -n, j - n)
		3: return Vector3i(i - n, -n, j - n)
		4: return Vector3i(n, i - n, j)
		5: return Vector3i(n, i - n, j - n)
		6: return Vector3i(-n, i - n, j)
		7: return Vector3i(-n, i - n, j - n)
		8: return Vector3i(i, j - n, n)
		9: return Vector3i(i - n, j - n, n)
		10: return Vector3i(i, j - n, -n)
		_: return Vector3i(i - n, j - n, -n)

func _canon_uv(q: Vector3i) -> Dictionary:
	# owning face = the shipped face_for_dir tie order on the RAW integer Q;
	# then the chart inverse formulas (sphere_math.gd:129-144) on C = Q/N.
	var nx: float = float(_N)
	var cx: float = float(q.x) / nx
	var cy: float = float(q.y) / nx
	var cz: float = float(q.z) / nx
	var face: int = SphereMath.face_for_dir(Vector3(float(q.x), float(q.y), float(q.z)))
	var u: float
	var v: float
	match face:
		0, 2, 8, 10: u = cx
		1, 3, 9, 11: u = cx + 1.0
		_: u = (cy + 1.0) * 0.5
	match face:
		0, 1, 2, 3: v = (cz + 1.0) * 0.5
		4, 6: v = cz
		5, 7: v = cz + 1.0
		_: v = (cy + 1.0) * 0.5
	return {"face": face, "u": u, "v": v}

func _canon_dir(q: Vector3i) -> Vector3:
	var r: Dictionary = _canon_uv(q)
	return SphereMath.uv_to_world(int(r["face"]), float(r["u"]), float(r["v"]), R_FIXTURE).normalized()

func _direct_dir(face: int, i: int, j: int) -> Vector3:
	var sh: Vector2i = _shape(face)
	return SphereMath.uv_to_world(face, float(i) / float(sh.x), float(j) / float(sh.y), R_FIXTURE).normalized()

func _world_point(n: Vector3, h: float) -> Vector3:
	return (R_FIXTURE + h) * n - Vector3(0.0, R_FIXTURE, 0.0)

func _check(name: String, value: float, expect: float, tol: float) -> void:
	if absf(value - expect) > tol:
		_fails.append("%s: measured %s, expected %s +/- %s"
				% [name, _r6(value), _r6(expect), _r6(tol)])

func _r6(x: float) -> String:
	return "%.6f" % x

func _neighbours(f: int, i: int, j: int) -> Array:
	var sh: Vector2i = _shape(f)
	var res: Array = []
	if i + 1 < sh.x: res.append([f, i + 1, j])
	if i - 1 >= 0: res.append([f, i - 1, j])
	if j + 1 < sh.y: res.append([f, i, j + 1])
	if j - 1 >= 0: res.append([f, i, j - 1])
	return res

# Every chart whose vertex grid contains Q (chart closures include the
# shared midlines; a cube corner lands on exactly 3 charts).
func _incident_charts(q: Vector3i) -> Array:
	var res: Array = []
	var n_ := float(_N)
	var cx := float(q.x)
	var cy := float(q.y)
	var cz := float(q.z)
	if cy == n_:
		if cx >= 0.0: res.append([0, int(cx), int(cz + n_)])
		if cx <= 0.0: res.append([1, int(cx + n_), int(cz + n_)])
	if cy == -n_:
		if cx >= 0.0: res.append([2, int(cx), int(cz + n_)])
		if cx <= 0.0: res.append([3, int(cx + n_), int(cz + n_)])
	if cx == n_:
		if cz >= 0.0: res.append([4, int(cy + n_), int(cz)])
		if cz <= 0.0: res.append([5, int(cy + n_), int(cz + n_)])
	if cx == -n_:
		if cz >= 0.0: res.append([6, int(cy + n_), int(cz)])
		if cz <= 0.0: res.append([7, int(cy + n_), int(cz + n_)])
	if cz == n_:
		if cx >= 0.0: res.append([8, int(cx), int(cy + n_)])
		if cx <= 0.0: res.append([9, int(cx + n_), int(cy + n_)])
	if cz == -n_:
		if cx >= 0.0: res.append([10, int(cx), int(cy + n_)])
		if cx <= 0.0: res.append([11, int(cx + n_), int(cy + n_)])
	if res.is_empty():
		_fails.append("boundary Q %s matched no chart" % str(q))
	return res

# The arm's control decomposition (harness.gd _ac0433_decomp, line 36232):
# base split ds0 at local height 0 + the lean coefficient (the radial-
# direction difference, per metre of height).
func _decomp(tf: Transform3D, lf: Vector3, th: Transform3D, lh: Vector3) -> Dictionary:
	var nf: Vector3 = tf.basis.y
	var nh: Vector3 = th.basis.y
	return {"ds0": (tf * lf - th * lh).length(), "lean": (nf - nh).length()}

func _edge_extremes(pts: Array, ex: Dictionary) -> void:
	for i in range(1, pts.size()):
		var e1: float = (pts[i] - pts[i - 1]).length()
		ex["min"] = minf(float(ex["min"]), e1)
		ex["max"] = maxf(float(ex["max"]), e1)
		ex["n"] = int(ex["n"]) + 1
		if i >= 16:
			var e16: float = (pts[i] - pts[i - 16]).length()
			ex["min16"] = minf(float(ex["min16"]), e16)
			ex["max16"] = maxf(float(ex["max16"]), e16)

# ---------------------------------------------------------------- the run

func _run() -> int:
	var t0: int = Time.get_ticks_msec()
	var R: float = R_FIXTURE
	var out: Dictionary = {"ok": false}

	# --- §3.1 the grid under test (formulas/predictions) ---
	var half_w: float = SphereMath.face_width(R) * 0.5  # H = pi*R/4
	_N = 16 * int(ceil(half_w / 16.0))
	var full: int = 2 * _N
	var n_short_chunks: int = _N / 16
	var n_long_chunks: int = full / 16
	var slots: int = 12 * n_short_chunks * n_long_chunks
	var midline_step: float = half_w / float(_N)
	out["R"] = R
	out["H_half_face_width_m"] = roundf(half_w * 10000.0) / 10000.0
	out["N"] = _N
	out["N_expected"] = 3152
	out["full_axis_cells"] = full
	out["chunk_slots_per_half_chart"] = [n_short_chunks, n_long_chunks]
	out["slot_count_total"] = slots
	out["midline_step_nominal_m"] = roundf(midline_step * 1e6) / 1e6
	if _N != 3152:
		_fails.append("N = %d != predicted 3152 (H = %s)" % [_N, _r6(half_w)])
	print("P1 grid: H=%s N=%d full=%d slots=%d midline_step_nominal=%s"
			% [_r6(half_w), _N, full, slots, _r6(midline_step)])

	# --- §3.3 every chart boundary: cube-edge sampling, shared-vertex
	#     groups, one-cell neighbours ---
	var dc: Dictionary = {"max_err": 0.0, "site": ""}
	var bmax := 0.0
	var bmax_site := ""
	var n_incident := 0
	var n_pairs := 0
	var n_edge_samples := 0
	var edge_min := INF
	var edge_max := 0.0
	var seen: Dictionary = {}
	for free_axis in range(3):
		for s1 in [-1, 1]:
			for s2 in [-1, 1]:
				for k in range(33):
					# the containing cube edge (2N lattice steps) sampled at
					# t = k/32: offset k*(2N/32) = k*(N/16) — integral.
					var free_v: int = -_N + k * (_N / 16)
					var q: Vector3i
					if free_axis == 0:
						q = Vector3i(free_v, s1 * _N, s2 * _N)
					elif free_axis == 1:
						q = Vector3i(s1 * _N, free_v, s2 * _N)
					else:
						q = Vector3i(s1 * _N, s2 * _N, free_v)
					var key: String = "%d:%d:%d" % [q.x, q.y, q.z]
					if seen.has(key):
						continue
					seen[key] = true
					var charts: Array = _incident_charts(q)
					var n_canon: Vector3 = _canon_dir(q)
					for h in HEIGHTS:
						var row: Array = [_world_point(n_canon, h)]
						for ch in charts:
							var nd: Vector3 = _direct_dir(int(ch[0]), int(ch[1]), int(ch[2]))
							row.append(_world_point(nd, h))
							n_incident += 1
							var err: float = (row[0] - row[row.size() - 1]).length()
							if err > float(dc["max_err"]):
								dc["max_err"] = err
								dc["site"] = "%s f%d h%d" % [key, int(ch[0]), int(h)]
						for a in range(1, row.size()):
							for b2 in range(a + 1, row.size()):
								n_pairs += 1
								var gap: float = (row[a] - row[b2]).length()
								if gap > bmax:
									bmax = gap
									bmax_site = "%s h=%d" % [key, int(h)]
					# one-cell neighbours (where useful: edge lengths + the
					# direct-vs-canonical check just off the boundary)
					for ch in charts:
						var f: int = int(ch[0])
						var ii: int = int(ch[1])
						var jj: int = int(ch[2])
						var pv: Vector3 = _world_point(_direct_dir(f, ii, jj), 0.0)
						for nb in _neighbours(f, ii, jj):
							var p1: Vector3 = _world_point(_direct_dir(int(nb[0]), int(nb[1]), int(nb[2])), 0.0)
							var el: float = (pv - p1).length()
							edge_min = minf(edge_min, el)
							edge_max = maxf(edge_max, el)
							n_edge_samples += 1
							_eval_vertex(int(nb[0]), int(nb[1]), int(nb[2]), dc)
	out["boundary"] = {
		"n_cube_edges": 12,
		"n_unique_vertices": seen.size(),
		"n_chart_incidents": n_incident,
		"n_pairs_compared": n_pairs,
		"max_shared_gap_m": roundf(bmax * 1e6) / 1e6,
		"max_shared_gap_site": bmax_site,
		"one_cell_edge_m": [roundf(edge_min * 1e6) / 1e6, roundf(edge_max * 1e6) / 1e6, n_edge_samples],
	}
	print("P1 boundary: %d unique Q groups, %d incidents, %d pairs, max_shared_gap=%s @ %s, 1cell edges [%s, %s] n=%d"
			% [seen.size(), n_incident, n_pairs, _r6(bmax), bmax_site, _r6(edge_min), _r6(edge_max), n_edge_samples])

	# --- §3.3 interior chunk edges: chunk (1,1) and adjacent, every face ---
	var n_interior := 0
	for f in range(12):
		for i in [16, 32, 48]:
			for j in [16, 32, 48]:
				_eval_vertex(f, i, j, dc)
				n_interior += 1
	out["interior_chunk_edges"] = {"n_points": n_interior, "vertices_per_face": "i,j in {16,32,48} (chunk 1,1 + adjacent)"}

	# --- §3.1 measured edge lengths: the midline sample grid, h = 0 ---
	var ex: Dictionary = {"min": INF, "max": 0.0, "min16": INF, "max16": 0.0, "n": 0}
	for f in range(12):
		var short_pts: Array = []
		if f < 4 or f >= 8:  # u is the short axis: i runs 0..N, midline j = N
			for i in range(_N + 1):
				short_pts.append(_world_point(_direct_dir(f, i, _N), 0.0))
		else:                # v is the short axis: j runs 0..N, midline i = N
			for j in range(_N + 1):
				short_pts.append(_world_point(_direct_dir(f, _N, j), 0.0))
		_edge_extremes(short_pts, ex)
		var long_pts: Array = []
		if f < 4 or f >= 8:  # v is the long axis: j runs 0..2N, midline i = N/2
			for j in range(2 * _N + 1):
				long_pts.append(_world_point(_direct_dir(f, _N / 2, j), 0.0))
		else:                # u is the long axis: i runs 0..2N, midline j = N/2
			for i in range(2 * _N + 1):
				long_pts.append(_world_point(_direct_dir(f, i, _N / 2), 0.0))
		_edge_extremes(long_pts, ex)
	out["edge_lengths_m"] = {
		"midline_1cell": [roundf(float(ex["min"]) * 1e6) / 1e6, roundf(float(ex["max"]) * 1e6) / 1e6, int(ex["n"])],
		"midline_16cell": [roundf(float(ex["min16"]) * 1e6) / 1e6, roundf(float(ex["max16"]) * 1e6) / 1e6],
	}
	print("P1 midline edges: 1cell [%s, %s] n=%d, 16cell [%s, %s] (nominal %s)"
			% [_r6(float(ex["min"])), _r6(float(ex["max"])), int(ex["n"]),
			   _r6(float(ex["min16"])), _r6(float(ex["max16"])), _r6(midline_step)])

	# --- §3.2 direct chart samples vs the canonical direction ---
	out["direct_vs_canonical_m"] = roundf(float(dc["max_err"]) * 1e6) / 1e6
	out["direct_vs_canonical_site"] = dc["site"]
	print("P1 direct-vs-canonical: max %s @ %s" % [_r6(float(dc["max_err"])), dc["site"]])

	# --- §3.4 the shipped inverse, interior round trips ---
	var inv_max := 0.0
	var inv_max_site := ""
	var inv_h_max := 0.0
	var n_inv := 0
	var face_consistent := true
	var face_bad := ""
	for f in range(12):
		var sh: Vector2i = _shape(f)
		for fu in [0.125, 0.375, 0.625, 0.875]:
			for fv in [0.125, 0.375, 0.625, 0.875]:
				var ic: int = int(fu * float(sh.x))  # exact: sh.x is a multiple of 8
				var jc: int = int(fv * float(sh.y))
				var u: float = (float(ic) + 0.5) / float(sh.x)
				var v: float = (float(jc) + 0.5) / float(sh.y)
				var n: Vector3 = SphereMath.uv_to_world(f, u, v, R_FIXTURE).normalized()
				for h in HEIGHTS:
					var pp: Vector3 = (R_FIXTURE + h) * n  # planet-centred
					var r2: Dictionary = SphereMath.world_to_face(pp, R_FIXTURE)
					var f2: int = int(r2["face"])
					n_inv += 1
					if f2 != f:
						face_consistent = false
						face_bad = "f%d cell(%d,%d) h=%d -> face %d" % [f, ic, jc, int(h), f2]
					var h2: float = pp.length() - R
					inv_h_max = maxf(inv_h_max, absf(h2 - h))
					var sh2: Vector2i = _shape(f2)
					# the returned u/v multiplied by the returned face's shape
					var ic2: float = float(r2["u"]) * float(sh2.x)
					var jc2: float = float(r2["v"]) * float(sh2.y)
					var n2: Vector3 = SphereMath.uv_to_world(f2, float(r2["u"]), float(r2["v"]), R_FIXTURE).normalized()
					var err: float = ((R_FIXTURE + h) * (n - n2)).length()
					if err > inv_max:
						inv_max = err
						inv_max_site = "f%d cell(%d,%d)->f%d cell(%.3f,%.3f) h=%d" % [f, ic, jc, f2, ic2, jc2, int(h)]
	out["inverse"] = {
		"n_points": n_inv,
		"max_round_trip_m": roundf(inv_max * 1e6) / 1e6,
		"max_round_trip_site": inv_max_site,
		"max_h_err_m": roundf(inv_h_max * 1e6) / 1e6,
		"owning_face_consistent": face_consistent,
		"owning_face_bad": face_bad,
	}
	print("P1 inverse: %d points, max round-trip %s @ %s, max h err %s, face-consistent %s"
			% [n_inv, _r6(inv_max), inv_max_site, _r6(inv_h_max), "true" if face_consistent else "false"])

	# --- §3.5 the negative control (must FIRE) ---
	var i_neg: int = _N / 2  # face 0, the v=0 boundary, t = 0.5
	var p_ok: Vector3 = _world_point(_direct_dir(0, i_neg, 0), 168.0)
	var p_sh: Vector3 = _world_point(_direct_dir(0, i_neg + 1, 0), 168.0)
	var neg_gap: float = (p_ok - p_sh).length()
	var neg_detected: bool = neg_gap > TOL_M
	out["negative"] = {
		"site": "f0 (i=%d, j=0) h=168 vs the one-cell-shifted endpoint (i=%d, j=0)" % [i_neg, i_neg + 1],
		"gap_m": roundf(neg_gap * 1e6) / 1e6,
		"detected": neg_detected,
	}
	print("P1 negative: gap %s, detected %s" % [_r6(neg_gap), "true" if neg_detected else "false"])

	# --- §3.6 the old controls (site selection copied from the arm) ---
	var home_ctl: Array = []
	var home_ds0_max := 0.0
	var home_lean_max := 0.0
	var home00: Dictionary = {}
	for seam in [[0, 0], [195, 0], [195, 512], [100, 100]]:
		var c: int = int(seam[0])
		var zz: int = int(seam[1])
		var ta: Transform3D = SphereMath.column_transform(c, zz, R_FIXTURE)
		var tb: Transform3D = SphereMath.column_transform(c + 1, zz, R_FIXTURE)
		var d: Dictionary = _decomp(ta, Vector3(16.0, 0.0, 8.0), tb, Vector3(0.0, 0.0, 8.0))
		var entry: Dictionary = {
			"site": "%d|%d,%d" % [c, c + 1, zz],
			"ds0_m": roundf(d["ds0"] * 1000.0) / 1000.0,
			"lean_per_m": roundf(d["lean"] * 1e6) / 1e6,
		}
		home_ctl.append(entry)
		home_ds0_max = maxf(home_ds0_max, d["ds0"])
		home_lean_max = maxf(home_lean_max, d["lean"])
		if c == 0 and zz == 0:
			home00 = entry
	var ff_u: Array = []
	var ff_v: Array = []
	var fu_max := 0.0
	var fv_max := 0.0
	# The arm documents the axis roles: "98 m in u on the x faces, 49 m in v;
	# the roles swap on the z faces". The plan's face/face expectations are
	# the two footprint classes: long (98 m, expected 0.02454/m) and short
	# (49 m, expected 0.01227/m) — not the raw u/v label maxima.
	var long_max := 0.0
	var short_max := 0.0
	for f2 in [4, 5, 6, 8, 10]:
		var mirrored: bool = SphereMath.face_mirror_x(f2)
		var x_face: bool = f2 <= 7
		for b in [63, 32]:
			var t31: Transform3D = SphereMath.face_chunk_transform(f2, 31, b, R_FIXTURE)
			var t32: Transform3D = SphereMath.face_chunk_transform(f2, 32, b, R_FIXTURE)
			var la: Vector3 = Vector3(0.0, 0.0, 8.0) if mirrored else Vector3(16.0, 0.0, 8.0)
			var lb: Vector3 = Vector3(16.0, 0.0, 8.0) if mirrored else Vector3(0.0, 0.0, 8.0)
			var du: Dictionary = _decomp(t31, la, t32, lb)
			ff_u.append({"site": "f%d u31|32 b%d" % [f2, b],
					"ds0_m": roundf(du["ds0"] * 1000.0) / 1000.0,
					"lean_per_m": roundf(du["lean"] * 1e6) / 1e6})
			fu_max = maxf(fu_max, du["lean"])
			if x_face:
				long_max = maxf(long_max, du["lean"])
			else:
				short_max = maxf(short_max, du["lean"])
			var tbm: Transform3D = SphereMath.face_chunk_transform(f2, 31, b - 1, R_FIXTURE)
			var dv: Dictionary = _decomp(tbm, Vector3(8.0, 0.0, 16.0), t31, Vector3(8.0, 0.0, 0.0))
			ff_v.append({"site": "f%d v31,b%d|b%d" % [f2, b - 1, b],
					"ds0_m": roundf(dv["ds0"] * 1000.0) / 1000.0,
					"lean_per_m": roundf(dv["lean"] * 1e6) / 1e6})
			fv_max = maxf(fv_max, dv["lean"])
			if x_face:
				short_max = maxf(short_max, dv["lean"])
			else:
				long_max = maxf(long_max, dv["lean"])
	# home/face at the arm's corner site f4 iv1000 (section A, x face)
	var iu2 := 1023
	var iv2 := 1000
	var ccx2: int = iu2 >> 4
	var tf: Transform3D = SphereMath.face_chunk_transform(4, ccx2, iv2 >> 4, R_FIXTURE)
	var fh: Vector3 = SphereMath.face_cell_band(4, iu2, iv2, R_FIXTURE)
	var lxf: float = float(SphereMath.face_local_x(4, 1023, 63)) + 0.5
	var lzf: float = float(iv2 & 15) + 0.5
	var hcx: int = int(floorf(fh.x / 16.0))
	var hcz: int = int(floorf(fh.y / 16.0))
	var th: Transform3D = SphereMath.column_transform(hcx, hcz, R_FIXTURE)
	var lh: Vector3 = Vector3(fh.x - float(hcx) * 16.0, 0.0, fh.y - float(hcz) * 16.0)
	var dhf: Dictionary = _decomp(tf, Vector3(lxf, 0.0, lzf), th, lh)
	out["old_controls"] = {
		"home_home": home_ctl,
		"home_home_00": home00,
		"home_home_ds0_max_m": roundf(home_ds0_max * 1000.0) / 1000.0,
		"home_home_lean_max_per_m": roundf(home_lean_max * 1e6) / 1e6,
		"faceface_u": ff_u,
		"faceface_v": ff_v,
		"faceface_u_lean_max_per_m": roundf(fu_max * 1e6) / 1e6,
		"faceface_v_lean_max_per_m": roundf(fv_max * 1e6) / 1e6,
		"faceface_long_class_lean_max_per_m": roundf(long_max * 1e6) / 1e6,
		"faceface_short_class_lean_max_per_m": roundf(short_max * 1e6) / 1e6,
		"home_face_f4_iv1000": {
			"ds0_m": roundf(dhf["ds0"] * 1000.0) / 1000.0,
			"lean_per_m": roundf(dhf["lean"] * 1e6) / 1e6,
			"home_chunk": [hcx, hcz],
			"fx_m": roundf(fh.x * 1000.0) / 1000.0,
			"fz_m": roundf(fh.y * 1000.0) / 1000.0,
		},
	}
	print("P1 old controls: home00 ds0=%s lean=%s | home max ds0=%s lean=%s | ff label max u=%s v=%s, class max long(98m)=%s short(49m)=%s | home/face f4 iv1000 ds0=%s"
			% [_r6(home00["ds0_m"]), _r6(home00["lean_per_m"]), _r6(home_ds0_max), _r6(home_lean_max),
			   _r6(fu_max), _r6(fv_max), _r6(long_max), _r6(short_max), _r6(dhf["ds0"])])

	# --- §3.7 the verdicts (plan tolerances, not weakened) ---
	if not face_consistent:
		_fails.append("inverse owning-face mismatch at " + face_bad)
	if not neg_detected:
		_fails.append("negative control did NOT fire: gap %s m <= %s m" % [_r6(neg_gap), _r6(TOL_M)])
	_check("max shared boundary gap", bmax, 0.0, TOL_M)
	_check("max direct-vs-canonical", float(dc["max_err"]), 0.0, TOL_M)
	_check("max inverse round trip", inv_max, 0.0, TOL_M)
	_check("home/home ds0 (site 0|1,0)", home00["ds0_m"], 0.002, 0.01)
	_check("home/home lean (site 0|1,0)", home00["lean_per_m"], 0.004, 0.00005)
	_check("face/face long-class (98 m) lean max", long_max, 0.02454, 0.00005)
	_check("face/face short-class (49 m) lean max", short_max, 0.01227, 0.00005)
	_check("home/face f4 iv1000 ds0", dhf["ds0"], 3.732, 0.01)

	out["heights_m"] = [0, 140, 168]
	out["tolerance_m"] = TOL_M
	out["fails"] = _fails.duplicate()
	out["ok"] = _fails.is_empty()
	out["ms"] = Time.get_ticks_msec() - t0
	for s in _fails:
		print("HONEST DEVIATION: " + s)
	print("RESULT " + JSON.stringify(out))
	return 0 if _fails.is_empty() else 1

func _eval_vertex(f: int, i: int, j: int, dc: Dictionary) -> void:
	# direct chart direction at (f, i, j) vs the canonical direction of the
	# same integer vertex, at every height (recorded in dc).
	var sh: Vector2i = _shape(f)
	var q: Vector3i = _vertex_q(f, i, j)
	var nd: Vector3 = SphereMath.uv_to_world(f, float(i) / float(sh.x), float(j) / float(sh.y), R_FIXTURE).normalized()
	var nc: Vector3 = _canon_dir(q)
	for h in HEIGHTS:
		var err: float = ((R_FIXTURE + h) * (nd - nc)).length()
		if err > float(dc["max_err"]):
			dc["max_err"] = err
			dc["site"] = "f%d (%d,%d) h%d" % [f, i, j, int(h)]
