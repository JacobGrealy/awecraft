# AC-0461 (plan.html §3.3) — the warp-space probe. Pure SphereMath, no world:
# it reproduces the AC-0458 warp construction (chunk.gd _warp_face_slabs) for
# face chunks on faces 2..11 (both mirror classes) over each chunk's 16x16 cell
# corner lattice and asserts the space the corners land in:
#   A1  h=0 corners sit on the sphere shell: |P + (0,R,0)| - R within 1e-3 m
#       (a legacy-framed vertex sits metres from the origin and fails by km);
#   A2  each side of a shared chunk edge evaluates the SAME world corner from
#       its OWN locals (max gap 0 — the AC-0458 result, re-asserted here);
#   A3  no warped corner is a local-frame leftover: nothing with |y| < 1 AND
#       |x|, |z| < 40 on chunks whose canonical position is far from the origin.
# Negative control: one chunk is evaluated with the LEGACY per-chunk LSQ
# transform instead of the warp and A1 must fail on it (negative_detected).
# Standalone SceneTree, one RESULT {…} JSON line (the AC-0433 probe style).
extends SceneTree

const SM := preload("res://core/sphere_math.gd")

const CELL := 1024.0  # legacy face-chart resolution
const FACES := [2, 3, 4, 5, 6, 7, 8, 9, 10, 11]  # both orientation classes
# Chunks per face: the two A2 pair blocks plus a mid-face and a corner chunk,
# so A1/A3 cover both mirror classes, all four chart quadrants and the seam
# rows. 6 chunks x 17 x 17 corners per face.
const CHUNKS := [[0, 2], [1, 2], [3, 5], [4, 5], [32, 32], [63, 63]]
# A2: adjacent pairs (A = (ccx, ccz), B = (ccx+1, ccz)) of the same blocks.
const PAIRS := [[0, 2], [3, 5]]
const NEG_FACE := 2  # the chunk whose warp is skipped for the negative control
const NEG_CHUNK := [0, 2]

var _R := 4000.0
var _r_src := "default-4000"
var _fails: Array = []
var _corners := 0
var _max_shell := 0.0  # A1
var _max_gap := 0.0  # A2
var _suspects := 0  # A3
var _neg_shell := 0.0  # A1 metric on the legacy-transformed chunk


func _initialize() -> void:
	# R = Game.planet_R if the autoload is present without the game tree,
	# else 4000 (game.gd pins 4000.0; state the source in the RESULT).
	var g := root.get_node_or_null("Game")
	if g != null and g.get("planet_R") != null:
		_R = float(g.get("planet_R"))
		_r_src = "Game.planet_R"
	for f in FACES:
		for c in CHUNKS:
			_chunk(int(f), int(c[0]), int(c[1]))
		for pr in PAIRS:
			_pair(int(f), int(pr[0]), int(pr[1]))
	# Negative control (plan §3.3): skip the warp for ONE chunk — use the
	# legacy per-chunk LSQ transform product — and confirm A1 fails on it.
	for lx in range(17):
		for lz in range(17):
			var p: Vector3 = _legacy_pos(NEG_FACE, NEG_CHUNK[0], NEG_CHUNK[1], float(lx), 0.0, float(lz))
			var e: float = absf((p + Vector3(0.0, _R, 0.0)).length() - _R)
			if e > _neg_shell:
				_neg_shell = e
	var ok := _fails.is_empty() and _max_shell <= 0.001 and _max_gap == 0.0 \
			and _suspects == 0 and _neg_shell > 0.001
	print("RESULT " + JSON.stringify({
		"ok": ok,
		"R": _R,
		"r_source": _r_src,
		"chunks": FACES.size() * CHUNKS.size(),
		"corners": _corners,
		"max_shell_error_m": _r6(_max_shell),
		"max_paired_gap_m": _r6(_max_gap),
		"local_frame_suspects": _suspects,
		"negative_detected": _neg_shell > 0.001,
		"negative_shell_error_m": _r6(_neg_shell),
		"fails": _fails,
	}))
	quit()


# One chunk: its 16x16 cell corner lattice (17x17 corners) at h=0 through the
# warp construction; A1 on every corner, A3 on every corner.
func _chunk(f: int, ccx: int, ccz: int) -> void:
	for lx in range(17):
		for lz in range(17):
			var p: Vector3 = _warp_pos(f, ccx, ccz, float(lx), 0.0, float(lz))
			_corners += 1
			if not is_finite(p.length()):
				_fails.append("warp corner not finite: face %d ccx %d ccz %d lx %d lz %d" % [f, ccx, ccz, lx, lz])
				continue
			var e: float = absf((p + Vector3(0.0, _R, 0.0)).length() - _R)  # A1
			if e > _max_shell:
				_max_shell = e
			if absf(p.y) < 1.0 and absf(p.x) < 40.0 and absf(p.z) < 40.0:  # A3
				_suspects += 1
	if _max_shell > 0.001:
		_fails.append("A1 shell error %.6f m > 1e-3 (face %d ccx %d ccz %d)" % [_max_shell, f, ccx, ccz])


# One adjacent pair: the shared edge's 17 corners at h=0, each side's OWN
# locals. The seam's local x per class follows the face_local_x data layout
# (mirror: A's seam edge is its lx=0 column, B's is lx=16; non-mirror the
# reverse) — the exact AC-0458 pair construction, re-asserted as A2.
func _pair(f: int, ccx: int, ccz: int) -> void:
	var mirr: bool = SM.face_mirror_x(f)
	var lax: float = 0.0 if mirr else 16.0
	var bax: float = 16.0 if mirr else 0.0
	for lz in range(17):
		var g: float = (_warp_pos(f, ccx, ccz, lax, 0.0, float(lz)) - _warp_pos(f, ccx + 1, ccz, bax, 0.0, float(lz))).length()
		if not is_finite(g):
			_fails.append("paired gap not finite: face %d ccx %d ccz %d lz %d" % [f, ccx, ccz, lz])
			continue
		if g > _max_gap:
			_max_gap = g
	if _max_gap > 0.0:
		_fails.append("A2 paired gap %.6f m != 0 (face %d ccx %d ccz %d)" % [_max_gap, f, ccx, ccz])


# The AC-0458 warp construction, verbatim from chunk.gd _warp_face_slabs:
# chart = the exact inverse of the face_local_x layout; world =
# (R + ly) * normalize(uv_to_world) - (0, R, 0).
func _warp_pos(f: int, ccx: int, ccz: int, lx: float, ly: float, lz: float) -> Vector3:
	var u1024: float = float(ccx) * 16.0 + (16.0 - lx if SM.face_mirror_x(f) else lx)
	var v1024: float = float(ccz) * 16.0 + lz
	var dir: Vector3 = SM.uv_to_world(f, u1024 / CELL, v1024 / CELL, _R)
	return (_R + ly) * (dir / dir.length()) - Vector3(0.0, _R, 0.0)


# The shipped LEGACY placement (the negative control): each chunk's own
# per-chunk LSQ affine fit applied to its own local coordinates.
func _legacy_pos(f: int, ccx: int, ccz: int, lx: float, ly: float, lz: float) -> Vector3:
	return SM.face_chunk_transform(f, ccx, ccz, _R) * Vector3(lx, ly, lz)


func _r6(x: float) -> float:
	return round(x * 1.0e6) / 1.0e6
