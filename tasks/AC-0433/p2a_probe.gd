extends SceneTree
# AC-0433 P2a — standalone test of the dormant PlanetGrid canonical API
# (godot/core/planet_grid.gd, plan.html §3). No production callers exist;
# this probe is the API's only consumer. The production SphereMath is
# preloaded BY PATH as GRID.SM inside the API; this probe additionally calls
# the shipped SphereMath autoload DIRECTLY as the independent reference
# mapping (the same separation P1 used: API points vs direct chart mapping).
#
# Tests (plan §3, specified not designed):
#   1. grid: R=4000 N=3152 + per-face dims + 931416 slots; radius fixtures
#      R=1000/8000 short counts 800/6288, axes divisible by 16, long=2*short.
#   2. boundary groups: exact P1 cube-edge sampling (t=k/32) + P1
#      _incident_charts: identical vertex_key and bit-identical world point
#      on every incident chart at h=0/140/168; API vs independent direct SM
#      chart mapping <= 0.001 m. Sector-midline samples: each axis pair's
#      even chart at short index 0 and odd chart at short index N, long
#      fraction k/8 (k=1..7); incident keys/points compared.
#   3. adjacent cells (i=15 vs 16, j=15 vs 16) + corner local-1 vs next
#      local-0, every face at h=140: exact same key and position.
#   4. inverse: 12 faces x 4x4 interior fractions x h=0.25/140.25/168.25
#      (576 cases, cell-centre local (0.5,0.25,0.5)) + negative k=-1 with
#      local.y=0.25: forward->inverse->forward <= 0.002 m, owning face/i/j/k
#      consistent away from boundaries.
#   5. negative control: one-cell-shifted f0 mid-edge boundary vertex at
#      h=168 must differ > 0.001 m; identity control: same i/j/k on face 0
#      vs face 2 has distinct address_key. Invalid inputs (face -1/12,
#      R=0/negative/INF, vertex indices outside the closed domain, cell
#      indices outside the half-open domain, local outside [0,1]/NaN, planet
#      centre inverse) must return the documented sentinels without SCRIPT
#      ERROR.
#
# Output: one RESULT JSON line; exit 0 iff every plan check holds, else
# exit 1 + HONEST DEVIATION lines. Deterministic; no autoloads of the game,
# no production references beyond SphereMath (called, never transcribed).

const GRID := preload("res://core/planet_grid.gd")

const R_FIXTURE: float = 4000.0
const HEIGHTS: Array = [0.0, 140.0, 168.0]
const FRACTIONS: Array = [0.125, 0.375, 0.625, 0.875]
const INV_HEIGHTS: Array = [0.25, 140.25, 168.25]
const TOL_DIRECT_M: float = 0.001  # plan §3: API vs direct chart mapping
const TOL_INV_M: float = 0.002     # plan §3: forward->inverse->forward (float32)
const NEG_TOL_M: float = 0.001     # plan §3: negative control must exceed

var _N: int = 0
var _fails: Array = []
var _api_cases: int = 0
var _shared_key_mismatches: int = 0
var _shared_position_max: float = 0.0
var _direct_error_max: float = 0.0
var _direct_error_site: String = ""
var _inverse_cases: int = 0
var _inverse_error_max: float = 0.0
var _inverse_error_site: String = ""
var _ownership_mismatches: int = 0
var _ownership_bad: String = ""
var _invalid_cases: int = 0
var _invalid_failures: int = 0


func _initialize() -> void:
	call_deferred("_run_and_quit")


func _run_and_quit() -> void:
	quit(_run())


# ------------------------------------------------------- P1 reference helpers
# Copied verbatim from tasks/AC-0433/p1_probe.gd (the read-only tested
# formulas/fixtures): the chart shape, the integer cube vertex Q, and the
# incident-chart grouping. These select and group test sites; they are NOT
# the API under test — every judgement below goes through GRID.

func _shape(face: int) -> Vector2i:
	if face >= 4 and face <= 7:
		return Vector2i(2 * _N, _N)
	return Vector2i(_N, 2 * _N)


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
	return res


func _r6(x: float) -> String:
	return "%.6f" % x


func _direct_point(face: int, i: int, j: int, h: float) -> Vector3:
	# The independent reference: the shipped chart mapping called directly,
	# exactly as P1's _world_point(_direct_dir(...), h).
	var sh: Vector2i = _shape(face)
	var n: Vector3 = SphereMath.uv_to_world(face, float(i) / float(sh.x), float(j) / float(sh.y), R_FIXTURE).normalized()
	return (R_FIXTURE + h) * n - Vector3(0.0, R_FIXTURE, 0.0)


func _check_group(label: String, charts: Array) -> void:
	# One shared-vertex group (the P1 construction): the vertex_key is
	# identical (and equal to the group's integer Q) on every incident chart,
	# the canonical world point is bit-identical at each height, and the API
	# point is within 0.001 m of the independent direct chart mapping.
	var q: Vector3i = _vertex_q(int(charts[0][0]), int(charts[0][1]), int(charts[0][2]))
	for h in HEIGHTS:
		var ref: Vector3 = Vector3.ZERO
		var has_ref: bool = false
		for ch in charts:
			var f: int = int(ch[0])
			var ii: int = int(ch[1])
			var jj: int = int(ch[2])
			var key: Vector3i = GRID.vertex_key(f, ii, jj, R_FIXTURE)
			if key != q:
				_shared_key_mismatches += 1
				_fails.append("%s: vertex_key %s != Q %s on chart %s" % [label, str(key), str(q), str(ch)])
			var p: Vector3 = GRID.vertex_to_world(f, ii, jj, h, R_FIXTURE)
			if p.x == INF:
				_fails.append("%s: vertex_to_world returned the INF sentinel on %s" % [label, str(ch)])
				continue
			_api_cases += 1
			if not has_ref:
				ref = p
				has_ref = true
			var gap: float = (ref - p).length()
			if gap > _shared_position_max:
				_shared_position_max = gap
				_fails.append("%s: shared-vertex gap %s m at h=%s between charts" % [label, _r6(gap), str(h)])
			var pd: Vector3 = _direct_point(f, ii, jj, h)
			var err: float = (p - pd).length()
			if err > _direct_error_max:
				_direct_error_max = err
				_direct_error_site = "%s f%d (%d,%d) h=%s" % [label, f, ii, jj, str(h)]


# ---------------------------------------------------------------- the run

func _run() -> int:
	var t0: int = Time.get_ticks_msec()
	var R: float = R_FIXTURE
	var out: Dictionary = {"ok": false}

	# --- 1. the grid rule (plan §3 test 1) ---
	var short_counts: Array = []
	for RR in [1000.0, 4000.0, 8000.0]:
		var sh0: Vector2i = GRID.grid_shape(0, RR)
		if sh0 == Vector2i.ZERO:
			_fails.append("grid_shape(0, %s) returned ZERO" % str(RR))
			short_counts.append(0)
			continue
		var n_short: int = sh0.x
		var n_long: int = sh0.y
		short_counts.append(n_short)
		if n_short % 16 != 0 or n_long % 16 != 0:
			_fails.append("R=%s: axes not divisible by 16: %s" % [str(RR), str(sh0)])
		if n_long != 2 * n_short:
			_fails.append("R=%s: long axis %d != 2*short %d" % [str(RR), n_long, n_short])
		var sh4: Vector2i = GRID.grid_shape(4, RR)
		if sh4 != Vector2i(2 * n_short, n_short):
			_fails.append("R=%s: face-4 shape %s != (2N,N)" % [str(RR), str(sh4)])
		for f in [1, 2, 3, 5, 6, 7, 8, 9, 10, 11]:
			# faces 4-7 are all the (2N,N) class; every other face is (N,2N)
			var expect: Vector2i = Vector2i(2 * n_short, n_short) if (f >= 4 and f <= 7) else Vector2i(n_short, 2 * n_short)
			if GRID.grid_shape(f, RR) != expect:
				_fails.append("R=%s: face-%d shape %s != %s" % [str(RR), f, str(GRID.grid_shape(f, RR)), str(expect)])
	_N = short_counts[1]
	var n_chunks_short: int = _N / 16
	var n_chunks_long: int = (2 * _N) / 16
	var slots: int = 12 * n_chunks_short * n_chunks_long
	out["grid"] = {
		"R": R,
		"N": _N,
		"N_expected": 3152,
		"radius_short_counts": short_counts,
		"radius_short_counts_expected": [800, 3152, 6288],
		"full_axis_cells": 2 * _N,
		"chunk_slots_per_half_chart": [n_chunks_short, n_chunks_long],
		"slot_count_total": slots,
		"slot_count_total_expected": 931416,
	}
	if _N != 3152:
		_fails.append("R=4000: N = %d != 3152" % _N)
	if short_counts != [800, 3152, 6288]:
		_fails.append("radius short counts %s != [800, 3152, 6288]" % str(short_counts))
	if slots != 931416:
		_fails.append("chunk slots %d != 931416" % slots)
	print("P2a grid: short counts %s (expected [800, 3152, 6288]), N=%d, full=%d, slots=%d (expected 931416)"
			% [str(short_counts), _N, 2 * _N, slots])

	# --- 2a. cube-edge boundary groups (P1 t=k/32 construction) ---
	var n_groups: int = 0
	var seen: Dictionary = {}
	for free_axis in range(3):
		for s1 in [-1, 1]:
			for s2 in [-1, 1]:
				for k in range(33):
					var free_v: int = -_N + k * (_N / 16)
					var q: Vector3i
					if free_axis == 0:
						q = Vector3i(free_v, s1 * _N, s2 * _N)
					elif free_axis == 1:
						q = Vector3i(s1 * _N, free_v, s2 * _N)
					else:
						q = Vector3i(s1 * _N, s2 * _N, free_v)
					if seen.has(str(q)):
						continue
					seen[str(q)] = true
					n_groups += 1
					var charts: Array = _incident_charts(q)
					if charts.is_empty():
						_fails.append("edge vertex %s matched no chart" % str(q))
						continue
					_check_group("edge %s" % str(q), charts)
	print("P2a edge groups: %d unique Q vertices, %d chart incidents (h=0/140/168 each)"
			% [n_groups, _api_cases])

	# --- 2b. sector-midline samples: each axis pair, even chart at short
	#     index 0 and odd chart at short index N, long fraction k/8 ---
	var n_midline: int = 0
	for k in range(1, 8):
		var long_idx: int = (2 * _N) * k / 8  # Nk/4 — integral (N divisible by 16)
		for pair in [[0, 1], [2, 3], [4, 5], [6, 7], [8, 9], [10, 11]]:
			var fe: int = int(pair[0])
			var fo: int = int(pair[1])
			var even: Array
			var odd: Array
			if fe >= 4 and fe <= 7:  # v is the short axis
				even = [fe, long_idx, 0]
				odd = [fo, long_idx, _N]
			else:                    # u is the short axis
				even = [fe, 0, long_idx]
				odd = [fo, _N, long_idx]
			for vert in [even, odd]:
				n_midline += 1
				var q: Vector3i = _vertex_q(int(vert[0]), int(vert[1]), int(vert[2]))
				var charts: Array = _incident_charts(q)
				if charts.is_empty():
					_fails.append("midline vertex %s (pair %s) matched no chart" % [str(q), str(pair)])
					continue
				_check_group("midline %s" % str(q), charts)
	print("P2a midline samples: %d vertices (6 axis pairs x 2 charts x k=1..7)" % n_midline)

	# --- 3. adjacent cells + corner local-1 vs next local-0, every face h=140 ---
	var n_adj: int = 0
	for f in range(12):
		var a: Vector3 = GRID.cell_to_world(f, 15, 20, 140, Vector3(1.0, 0.0, 0.5), R)
		var b: Vector3 = GRID.cell_to_world(f, 16, 20, 140, Vector3(0.0, 0.0, 0.5), R)
		var c: Vector3 = GRID.cell_to_world(f, 20, 15, 140, Vector3(0.5, 0.0, 1.0), R)
		var d: Vector3 = GRID.cell_to_world(f, 20, 16, 140, Vector3(0.5, 0.0, 0.0), R)
		var e: Vector3 = GRID.cell_to_world(f, 15, 15, 140, Vector3(1.0, 0.0, 1.0), R)
		var g: Vector3 = GRID.cell_to_world(f, 16, 16, 140, Vector3(0.0, 0.0, 0.0), R)
		_api_cases += 6
		n_adj += 1
		if a.x == INF or b.x == INF or c.x == INF or d.x == INF or e.x == INF or g.x == INF:
			_fails.append("f%d: cell_to_world returned the INF sentinel on an adjacent/corner site" % f)
			continue
		var gap_ab: float = (a - b).length()
		var gap_cd: float = (c - d).length()
		var gap_eg: float = (e - g).length()
		if gap_ab > 0.0 or gap_cd > 0.0 or gap_eg > 0.0:
			_fails.append("f%d: adjacent/corner mismatch: u %s m, v %s m, corner %s m"
					% [f, _r6(gap_ab), _r6(gap_cd), _r6(gap_eg)])
		var q_corner: Vector3i = GRID.vertex_key(f, 16, 16, R)
		if q_corner == Vector3i.ZERO:
			_fails.append("f%d: corner vertex_key(16,16) is ZERO" % f)
		var p_corner: Vector3 = GRID.vertex_to_world(f, 16, 16, 140.0, R)
		if (p_corner - g).length() > 0.0:
			_fails.append("f%d: corner cell point differs from its vertex_key evaluation by %s m"
					% [f, _r6((p_corner - g).length())])
	print("P2a adjacent cells: %d faces, u/v/corner boundaries exact (same key + position) at h=140" % n_adj)

	# --- 4. inverse round trips (12 faces x 4x4 fractions x 3 heights) ---
	var n_inv_main: int = 0
	for f in range(12):
		var sh: Vector2i = _shape(f)
		for fu in FRACTIONS:
			for fv in FRACTIONS:
				var ic: int = int(float(fu) * float(sh.x))  # exact: sh.x is a multiple of 8
				var jc: int = int(float(fv) * float(sh.y))
				var local: Vector3 = Vector3(0.5, 0.25, 0.5)
				for h in INV_HEIGHTS:
					var k: int = int(floorf(h))
					_round_trip(f, ic, jc, k, local)
					n_inv_main += 1
	# negative k = -1 (h = -0.75) with local.y = 0.25, all faces x 4x4
	var n_inv_neg: int = 0
	for f in range(12):
		var sh: Vector2i = _shape(f)
		for fu in FRACTIONS:
			for fv in FRACTIONS:
				var ic: int = int(float(fu) * float(sh.x))
				var jc: int = int(float(fv) * float(sh.y))
				_round_trip(f, ic, jc, -1, Vector3(0.5, 0.25, 0.5))
				n_inv_neg += 1
	print("P2a inverse: %d main + %d negative-k = %d round trips, max %s m @ %s"
			% [n_inv_main, n_inv_neg, _inverse_cases, _r6(_inverse_error_max), _inverse_error_site])
	out["inverse_cases_note"] = "576 main (12x4x4x3, h=0.25/140.25/168.25) + 192 negative-k (k=-1, local.y=0.25)"

	# --- 5. negative control (must FIRE) + identity control ---
	var i_neg: int = _N / 2  # face 0, the v=0 boundary mid-edge, h = 168
	var p_ok: Vector3 = GRID.vertex_to_world(0, i_neg, 0, 168.0, R)
	var p_sh: Vector3 = GRID.vertex_to_world(0, i_neg + 1, 0, 168.0, R)
	var neg_gap: float = (p_ok - p_sh).length()
	var neg_detected: bool = neg_gap > NEG_TOL_M
	if not neg_detected:
		_fails.append("negative control did NOT fire: gap %s m <= %s m" % [_r6(neg_gap), _r6(NEG_TOL_M)])
	out["negative"] = {
		"site": "f0 vertex (i=%d, j=0) h=168 vs the one-cell-shifted (i=%d, j=0)" % [i_neg, i_neg + 1],
		"gap_m": roundf(neg_gap * 1e6) / 1e6,
		"detected": neg_detected,
	}
	print("P2a negative control: gap %s m, detected %s" % [_r6(neg_gap), "true" if neg_detected else "false"])

	var ka: String = GRID.address_key(0, 100, 100, 0, R)
	var kb: String = GRID.address_key(2, 100, 100, 0, R)
	if ka == "" or kb == "" or ka == kb:
		_fails.append("identity control: address_key f0 '%s' vs f2 '%s' must be distinct and non-empty" % [ka, kb])
	print("P2a identity control: f0 '%s' != f2 '%s'" % [ka, kb])

	# --- 5b. invalid inputs must hit the documented sentinels, no SCRIPT ERROR ---
	var l_half: Vector3 = Vector3(0.5, 0.5, 0.5)
	var zero_shape: Array = [
		["grid_shape face -1", GRID.grid_shape(-1, R)],
		["grid_shape face 12", GRID.grid_shape(12, R)],
		["grid_shape R=0", GRID.grid_shape(0, 0.0)],
		["grid_shape R<0", GRID.grid_shape(0, -R)],
		["grid_shape R=INF", GRID.grid_shape(0, INF)],
	]
	for row in zero_shape:
		_invalid_cases += 1
		if row[1] != Vector2i.ZERO:
			_invalid_failures += 1
			_fails.append("%s: expected Vector2i.ZERO, got %s" % [row[0], str(row[1])])
	var zero_key: Array = [
		["vertex_key i=-1", GRID.vertex_key(0, -1, 0, R)],
		["vertex_key i=N+1", GRID.vertex_key(0, _N + 1, 0, R)],
		["vertex_key j=2N+1", GRID.vertex_key(0, _N, 2 * _N + 1, R)],
		["vertex_key f4 i=2N+1", GRID.vertex_key(4, 2 * _N + 1, 0, R)],
		["vertex_key f4 j=N+1", GRID.vertex_key(4, 0, _N + 1, R)],
		["vertex_key R=0", GRID.vertex_key(0, 0, 0, 0.0)],
	]
	for row in zero_key:
		_invalid_cases += 1
		if row[1] != Vector3i.ZERO:
			_invalid_failures += 1
			_fails.append("%s: expected Vector3i.ZERO, got %s" % [row[0], str(row[1])])
	var inf_point: Array = [
		["cell i=-1", GRID.cell_to_world(0, -1, 0, 0, l_half, R)],
		["cell i=Nu", GRID.cell_to_world(0, _N, 0, 0, l_half, R)],
		["cell j=Nv", GRID.cell_to_world(0, 0, 2 * _N, 0, l_half, R)],
		["cell face -1", GRID.cell_to_world(-1, 0, 0, 0, l_half, R)],
		["cell R=0", GRID.cell_to_world(0, 0, 0, 0, l_half, 0.0)],
		["cell local.x>1", GRID.cell_to_world(0, 0, 0, 0, Vector3(1.0 + 1e-7, 0.5, 0.5), R)],
		["cell local.y<0", GRID.cell_to_world(0, 0, 0, 0, Vector3(0.5, -1e-7, 0.5), R)],
		["cell local.x=NaN", GRID.cell_to_world(0, 0, 0, 0, Vector3(NAN, 0.5, 0.5), R)],
		["cell local.z=NaN", GRID.cell_to_world(0, 0, 0, 0, Vector3(0.5, 0.5, NAN), R)],
		["vertex h with R+h<=0", GRID.vertex_to_world(0, 0, 0, -R - 0.1, R)],
		["vertex h=INF", GRID.vertex_to_world(0, 0, 0, INF, R)],
		["vertex R<0", GRID.vertex_to_world(0, 0, 0, 0.0, -R)],
	]
	for row in inf_point:
		_invalid_cases += 1
		var p: Vector3 = row[1]
		if not (p.x == INF and p.y == INF and p.z == INF):
			_invalid_failures += 1
			_fails.append("%s: expected the (INF,INF,INF) sentinel, got %s" % [row[0], str(p)])
	var inv_bad: Array = [
		["world_to_cell planet centre", GRID.world_to_cell(Vector3(0.0, -R, 0.0), R)],
		["world_to_cell NaN", GRID.world_to_cell(Vector3(NAN, 0.0, 0.0), R)],
		["world_to_cell R=0", GRID.world_to_cell(Vector3(1.0, 0.0, 0.0), 0.0)],
	]
	for row in inv_bad:
		_invalid_cases += 1
		if row[1].get("valid", true) != false:
			_invalid_failures += 1
			_fails.append("%s: expected valid=false, got %s" % [row[0], str(row[1])])
	var ak_bad: Array = [
		["address_key face -1", GRID.address_key(-1, 0, 0, 0, R)],
		["address_key i=Nu", GRID.address_key(0, _N, 0, 0, R)],
		["address_key j=Nv", GRID.address_key(0, 0, 2 * _N, 0, R)],
		["address_key R=INF", GRID.address_key(0, 0, 0, 0, INF)],
	]
	for row in ak_bad:
		_invalid_cases += 1
		if row[1] != "":
			_invalid_failures += 1
			_fails.append("%s: expected \"\", got '%s'" % [row[0], str(row[1])])
	print("P2a invalid inputs: %d cases, %d failures (sentinels as documented)"
			% [_invalid_cases, _invalid_failures])

	# --- verdict (plan tolerances, not weakened) ---
	if _shared_key_mismatches != 0:
		_fails.append("shared vertex_key mismatches: %d" % _shared_key_mismatches)
	if _shared_position_max > 0.0:
		_fails.append("shared vertex position max gap %s m != 0" % _r6(_shared_position_max))
	if _direct_error_max > TOL_DIRECT_M:
		_fails.append("API vs direct chart mapping max %s m > %s m @ %s"
				% [_r6(_direct_error_max), _r6(TOL_DIRECT_M), _direct_error_site])
	if _ownership_mismatches != 0:
		_fails.append("inverse ownership mismatches: %d (first: %s)" % [_ownership_mismatches, _ownership_bad])
	if _inverse_error_max > TOL_INV_M:
		_fails.append("inverse round trip max %s m > %s m @ %s"
				% [_r6(_inverse_error_max), _r6(TOL_INV_M), _inverse_error_site])
	if _invalid_failures != 0:
		_fails.append("invalid-input sentinel failures: %d" % _invalid_failures)
	if not neg_detected:
		_fails.append("negative_detected must be true")

	out["api_cases"] = _api_cases
	out["shared_key_mismatches"] = _shared_key_mismatches
	out["shared_position_max_m"] = roundf(_shared_position_max * 1e6) / 1e6
	out["direct_error_max_m"] = roundf(_direct_error_max * 1e6) / 1e6
	out["direct_error_site"] = _direct_error_site
	out["n_edge_groups"] = n_groups
	out["n_midline_samples"] = n_midline
	out["inverse_cases"] = _inverse_cases
	out["inverse_error_max_m"] = roundf(_inverse_error_max * 1e6) / 1e6
	out["inverse_error_site"] = _inverse_error_site
	out["ownership_mismatches"] = _ownership_mismatches
	out["invalid_cases"] = _invalid_cases
	out["invalid_failures"] = _invalid_failures
	out["negative_detected"] = neg_detected
	out["radius_short_counts"] = short_counts
	out["heights_m"] = [0, 140, 168]
	out["tolerance_direct_m"] = TOL_DIRECT_M
	out["tolerance_inverse_m"] = TOL_INV_M
	out["fails"] = _fails.duplicate()
	out["ok"] = _fails.is_empty()
	out["ms"] = Time.get_ticks_msec() - t0
	for s in _fails:
		print("HONEST DEVIATION: " + s)
	print("RESULT " + JSON.stringify(out))
	return 0 if _fails.is_empty() else 1


func _round_trip(f: int, ic: int, jc: int, k: int, local: Vector3) -> void:
	# forward cell_to_world -> world_to_cell -> forward cell_to_world:
	# max displacement <= 0.002 m and owning face/i/j/k consistent.
	var p: Vector3 = GRID.cell_to_world(f, ic, jc, k, local, R_FIXTURE)
	if p.x == INF:
		_fails.append("f%d cell(%d,%d) k=%d: cell_to_world returned the INF sentinel" % [f, ic, jc, k])
		return
	var c: Dictionary = GRID.world_to_cell(p, R_FIXTURE)
	_inverse_cases += 1
	if c.get("valid", false) != true:
		_ownership_mismatches += 1
		_ownership_bad = "f%d cell(%d,%d) k=%d -> invalid" % [f, ic, jc, k]
		_fails.append(_ownership_bad)
		return
	var f2: int = int(c["face"])
	var i2: int = int(c["i"])
	var j2: int = int(c["j"])
	var k2: int = int(c["k"])
	if f2 != f or i2 != ic or j2 != jc or k2 != k:
		_ownership_mismatches += 1
		_ownership_bad = "f%d cell(%d,%d) k=%d -> f%d cell(%d,%d) k=%d" % [f, ic, jc, k, f2, i2, j2, k2]
		_fails.append("inverse ownership mismatch: " + _ownership_bad)
	var p2: Vector3 = GRID.cell_to_world(f2, i2, j2, k2, Vector3(c["local"]), R_FIXTURE)
	var err: float = (p - p2).length()
	if err > _inverse_error_max:
		_inverse_error_max = err
		_inverse_error_site = "f%d cell(%d,%d) k=%d -> f%d cell(%d,%d) k=%d" % [f, ic, jc, k, f2, i2, j2, k2]
