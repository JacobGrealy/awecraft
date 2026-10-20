# AC-0433 P2b-3 — standalone probe: the 90-degree cube-edge fold (plan §3.4).
# T1: total adjacency - every sampled cell's four neighbours return ok:true
# (zero sentinels on valid input). T2: every neighbour, fold or not, shares
# exactly the two expected corner vertex_keys for that dir (dir 1 the i+1
# edge, dir 0 the i edge, dir 3 the j+1 edge, dir 2 the j edge, chart-local).
# T3: fold census - T2 pairs whose result is on a different plane than the
# source; require > 100 (coordinator measured 216), each with its corners.
# T4: invalid inputs return ok:false. Negative control: one real fold with
# its carried coordinate shifted by 1 must fail the shared-corner test.
# One RESULT line; any failed expectation exits 1.
# Run (repo root, no other godot process running):
#   HOME=/tmp/dsh_home ~/tools/godot/godot --headless --path godot \
#     --script tasks/AC-0433/p2b3_probe.gd
extends SceneTree

const R: float = 4000.0 # live planet radius (P1: N = 3152, full axis 6304)
const GRID = preload("res://core/planet_grid.gd")

func _initialize() -> void:
	var checks: int = 0
	var sent: int = 0
	var pairs: int = 0
	var mis: int = 0
	var folds: int = 0
	var fmis: int = 0
	var inv_cases: int = 0
	var inv_fail: int = 0
	var cells: Array = []
	for face in range(12):
		var sh: Vector2i = GRID.grid_shape(face, R)
		for i in _samples(sh.x):
			for j in _samples(sh.y):
				cells.append([face, i, j])
	var neg_src: Array = []
	var neg_dir: int = -1
	for c in cells:
		var face: int = c[0]
		var i: int = c[1]
		var j: int = c[2]
		var idl: Dictionary = GRID.cell_lattice(face, i, j, R)
		for dir in range(4):
			checks += 1
			var r: Dictionary = GRID.cell_neighbour(face, i, j, dir, R)
			if not r.get("ok", false):
				sent += 1
				continue
			pairs += 1
			var shared: Array = _shared(face, i, j, r.face, r.i, r.j, R)
			var bad: bool = shared.size() != 2 \
					or not _same_set(shared, _expect_shared(face, i, j, dir, R))
			if bad:
				mis += 1
			var fr: Dictionary = GRID.cell_lattice(r.face, r.i, r.j, R)
			if fr.plane != idl.plane:
				folds += 1
				if bad:
					fmis += 1
				if neg_src.is_empty():
					neg_src = [face, i, j]
					neg_dir = dir
	var neg: bool = false
	if folds > 0 and not neg_src.is_empty():
		var r: Dictionary = GRID.cell_neighbour(neg_src[0], neg_src[1], neg_src[2], neg_dir, R)
		# The carried coordinate is the unstepped lattice axis: an a-step
		# (dir 0/1) carries b (the far cell's j), a b-step carries a (its i).
		var ni: int = r.i + (1 if neg_dir >= 2 else 0)
		var nj: int = r.j + (1 if neg_dir < 2 else 0)
		var shared: Array = _shared(neg_src[0], neg_src[1], neg_src[2], r.face, ni, nj, R)
		neg = shared.size() != 2 \
				or not _same_set(shared, _expect_shared(neg_src[0], neg_src[1], neg_src[2], neg_dir, R))
	var sh0: Vector2i = GRID.grid_shape(0, R)
	var inv: Array = [
		[-1, 1, 1, 1, R], [12, 1, 1, 1, R],
		[0, 1, 1, 1, 0.0], [0, 1, 1, 1, -1.0], [0, 1, 1, 1, INF],
		[0, -1, 1, 1, R], [0, sh0.x, 1, 1, R], [0, 1, -1, 1, R], [0, 1, sh0.y, 1, R],
		[0, 1, 1, -1, R], [0, 1, 1, 4, R],
	]
	for t in inv:
		inv_cases += 1
		if GRID.cell_neighbour(t[0], t[1], t[2], t[3], t[4]).get("ok", false):
			inv_fail += 1
	var fails: int = sent + mis + fmis + inv_fail \
			+ (0 if folds > 100 else 1) + (0 if neg else 1)
	var ok: bool = fails == 0
	print("RESULT " + JSON.stringify({
			"ok": ok, "checks": checks, "sentinel_count": sent, "pairs": pairs,
			"folds": folds, "shared_mismatches": mis,
			"fold_shared_mismatches": fmis, "invalid_cases": inv_cases,
			"invalid_failures": inv_fail, "negative_detected": neg, "fails": fails}))
	quit(0 if ok else 1)

# Sample set of plan §3.4: {0, 1, 15, half, nu-2, nu-1}, clamped to the
# face's half-open cell domain and de-duplicated (same set as P2b-1/P2b-2).
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

# The two lattice corners the dir must share (plan §3.4 T2), stated on the
# ORIGINAL face: vertex_key is canonical, so a fold's corners agree with it
# on the cube edge.
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
