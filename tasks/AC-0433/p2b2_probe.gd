# AC-0433 P2b-2 — standalone probe: in-plane cell adjacency through the
# identity (plan §3.3). T1: every sampled cell's four neighbours share
# exactly the two expected corner vertex_keys, and the opposite dir returns
# the original cell. T2: the twelve named sector-seam checks land on the
# paired chart with the along-seam coordinate carried. T3: the cube-edge
# sentinel fires exactly where an independent lattice prediction says
# (fold_probes = misprediction count, fold_wrong_ok = ok where fold expected).
# T4: invalid inputs return ok:false with a reason. cell_lattice's sign
# always agrees with the derived-owner range rule. Negative control: one
# valid T1 pair with the neighbour's j shifted by 1 must fail the
# shared-corner test. One RESULT line; any failed expectation exits 1.
# Run (repo root, no other godot process running):
#   HOME=/tmp/dsh_home ~/tools/godot/godot --headless --path godot \
#     --script tasks/AC-0433/p2b2_probe.gd
extends SceneTree

const R: float = 4000.0 # live planet radius (P1: N = 3152, full axis 6304)
const GRID = preload("res://core/planet_grid.gd")

func _initialize() -> void:
	var n: int = GRID.grid_shape(0, R).x
	var sign_bad: int = 0
	var pairs: int = 0
	var mis: int = 0
	var fold_bad: int = 0
	var fold_ok: int = 0
	var sec_fail: int = 0
	var inv_cases: int = 0
	var inv_fail: int = 0
	var cells: Array = []
	for face in range(12):
		var sh: Vector2i = GRID.grid_shape(face, R)
		for i in _samples(sh.x):
			for j in _samples(sh.y):
				cells.append([face, i, j])
				var idl: Dictionary = GRID.cell_lattice(face, i, j, R)
				if not idl.get("ok", false):
					sign_bad += 1
					continue
				var x: int = idl.b if (idl.plane == 4 or idl.plane == 6) else idl.a
				if idl.sign != (1 if x >= 0 else -1):
					sign_bad += 1
	for c in cells:
		for dir in range(4):
			var face: int = c[0]
			var i: int = c[1]
			var j: int = c[2]
			var idl: Dictionary = GRID.cell_lattice(face, i, j, R)
			var a: int = idl.a
			var b: int = idl.b
			match dir:
				0: a -= 1
				1: a += 1
				2: b -= 1
				_: b += 1
			var expect_fold: bool = a < -n or a >= n or b < -n or b >= n
			var r: Dictionary = GRID.cell_neighbour(face, i, j, dir, R)
			if expect_fold:
				if r.get("ok", false):
					fold_ok += 1
					fold_bad += 1
				elif str(r.get("reason", "")) != "cube_edge":
					fold_bad += 1
			elif not r.get("ok", false):
				fold_bad += 1
			else:
				pairs += 1
				var shared: Array = _shared(face, i, j, r.face, r.i, r.j, R)
				if shared.size() != 2 or not _same_set(shared, _expect_shared(face, i, j, dir, R)) \
						or not _back(r, face, i, j, dir, R):
					mis += 1
	var seams: Array = []
	for p in [0, 2, 8, 10]:
		seams.append([p, 0, 7, 0, p + 1, n - 1, 7])
		seams.append([p + 1, n - 1, 7, 1, p, 0, 7])
	for p in [4, 6]:
		seams.append([p, 7, 0, 2, p + 1, 7, n - 1])
		seams.append([p + 1, 7, n - 1, 3, p, 7, 0])
	var sec_checks: int = seams.size()
	for s in seams:
		var r: Dictionary = GRID.cell_neighbour(s[0], s[1], s[2], s[3], R)
		if not (r.get("ok", false) and r.face == s[4] and r.i == s[5] and r.j == s[6]):
			sec_fail += 1
	var sh0: Vector2i = GRID.grid_shape(0, R)
	var inv: Array = [
		[-1, 1, 1, 1, R], [12, 1, 1, 1, R],
		[0, 1, 1, 1, 0.0], [0, 1, 1, 1, -1.0], [0, 1, 1, 1, INF],
		[0, -1, 1, 1, R], [0, sh0.x, 1, 1, R], [0, 1, -1, 1, R], [0, 1, sh0.y, 1, R],
		[0, 1, 1, -1, R], [0, 1, 1, 4, R],
	]
	for t in inv:
		inv_cases += 1
		var r: Dictionary = GRID.cell_neighbour(t[0], t[1], t[2], t[3], t[4])
		if r.get("ok", false) or str(r.get("reason", "")) == "":
			inv_fail += 1
	# Negative control (plan §3.3): one valid T1 pair (face 0, i 1, j 1,
	# dir 1); shift the neighbour's j by 1 and the shared-corner test must
	# then fail on it.
	var r0: Dictionary = GRID.cell_neighbour(0, 1, 1, 1, R)
	var neg: bool = false
	if r0.get("ok", false):
		var shared: Array = _shared(0, 1, 1, r0.face, r0.i, r0.j + 1, R)
		neg = shared.size() != 2 or not _same_set(shared, _expect_shared(0, 1, 1, 1, R))
	var fails: int = sign_bad + mis + fold_bad + sec_fail + inv_fail + (0 if neg else 1)
	var ok: bool = fails == 0
	print("RESULT " + JSON.stringify({
			"ok": ok, "sign_disagreements": sign_bad, "adjacency_pairs": pairs,
			"adjacency_mismatches": mis, "sector_checks": sec_checks,
			"sector_failures": sec_fail, "fold_probes": fold_bad,
			"fold_wrong_ok": fold_ok, "invalid_cases": inv_cases,
			"invalid_failures": inv_fail, "negative_detected": neg, "fails": fails}))
	quit(0 if ok else 1)

# Sample set of plan §3.3: {0, 1, 15, half, nu-2, nu-1}, clamped to the
# face's half-open cell domain and de-duplicated (same as P2b-1).
func _samples(nu: int) -> Array:
	var out: Array = []
	for v in [0, 1, 15, nu / 2, nu - 2, nu - 1]:
		var c: int = clampi(v, 0, nu - 1)
		if not out.has(c):
			out.append(c)
	return out

func _corners(face: int, i: int, j: int, R: float) -> Dictionary:
	var d: Dictionary = {}
	for di in [0, 1]:
		for dj in [0, 1]:
			d[GRID.vertex_key(face, i + di, j + dj, R)] = true
	return d

func _shared(face: int, i: int, j: int, nf: int, ni: int, nj: int, R: float) -> Array:
	var a: Dictionary = _corners(face, i, j, R)
	var b: Dictionary = _corners(nf, ni, nj, R)
	var out: Array = []
	for k in a:
		if b.has(k):
			out.append(k)
	return out

# The two lattice corners the dir must share (plan §3.3 T1), stated on the
# ORIGINAL face: vertex_key is canonical, so a sector neighbour's corners
# agree with it on the seam.
func _expect_shared(face: int, i: int, j: int, dir: int, R: float) -> Array:
	match dir:
		0: return [GRID.vertex_key(face, i, j, R), GRID.vertex_key(face, i, j + 1, R)]
		1: return [GRID.vertex_key(face, i + 1, j, R), GRID.vertex_key(face, i + 1, j + 1, R)]
		2: return [GRID.vertex_key(face, i, j, R), GRID.vertex_key(face, i + 1, j, R)]
		_: return [GRID.vertex_key(face, i, j + 1, R), GRID.vertex_key(face, i + 1, j + 1, R)]

func _same_set(a: Array, b: Array) -> bool:
	for x in a:
		if not b.has(x):
			return false
	return a.size() == b.size()

func _back(r: Dictionary, face: int, i: int, j: int, dir: int, R: float) -> bool:
	var rr: Dictionary = GRID.cell_neighbour(r.face, r.i, r.j, dir ^ 1, R)
	return rr.get("ok", false) and rr.face == face and rr.i == i and rr.j == j
