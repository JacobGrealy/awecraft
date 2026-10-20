# AC-0458 (plan.html §3.4) — the warp seam probe. Pure SphereMath, no world:
# under the AC-0458 warp construction (chunk.gd _warp_face_slabs), the 17
# shared-edge vertices of two adjacent face chunks must evaluate to the SAME
# chart point from each side's OWN local coordinates — max gap exactly 0 —
# while the legacy per-chunk LSQ fit (SM.face_chunk_transform) leaves the
# measured 1-2 m seam gap (what the warp replaces).
# Standalone SceneTree, one RESULT {…} JSON line (the AC-0433 probe style).
extends SceneTree

const SM := preload("res://core/sphere_math.gd")

const CELL := 1024.0  # legacy face-chart resolution
const FACES := [2, 3, 4, 5, 6, 7, 8, 9, 10, 11]  # both orientation classes
# (ccx, ccz) of the LEFT chunk of each adjacent pair — a small grid per face.
const PAIRS := [[0, 2], [3, 5]]

var _R := 4000.0
var _r_src := "default-4000"
var _fails: Array = []
var _pairs := 0
var _warp_max := 0.0
var _legacy_max := 0.0
var _neg_gap := 0.0


func _initialize() -> void:
	# R = Game.planet_R if the autoload is present without the game tree,
	# else 4000 (game.gd pins 4000.0; state the source in the RESULT).
	var g := root.get_node_or_null("Game")
	if g != null and g.get("planet_R") != null:
		_R = float(g.get("planet_R"))
		_r_src = "Game.planet_R"
	for f in FACES:
		for pr in PAIRS:
			_pairs += 1
			_pair(int(f), int(pr[0]), int(pr[1]))
	var ok := _fails.is_empty() and _warp_max == 0.0 and _legacy_max > 0.1 and _neg_gap > 0.0
	print("RESULT " + JSON.stringify({
		"ok": ok,
		"R": _R,
		"r_source": _r_src,
		"pairs": _pairs,
		"warp_max_gap_m": _r6(_warp_max),
		"legacy_max_gap_m": _r6(_legacy_max),
		"negative_detected": _neg_gap > 0.0,
		"negative_gap_m": _r6(_neg_gap),
		"fails": _fails,
	}))
	quit()


# One adjacent pair (A = (ccx, ccz), B = (ccx+1, ccz)): the shared edge's 17
# vertices at h = 0. The seam's local x per class follows the face_local_x
# data layout (mirror: A's seam edge is its lx=0 column, B's is lx=16;
# non-mirror: A's lx=16, B's lx=0).
func _pair(f: int, ccx: int, ccz: int) -> void:
	var mirr: bool = SM.face_mirror_x(f)
	var lax: float = 0.0 if mirr else 16.0
	var bax: float = 16.0 if mirr else 0.0
	for lz in range(17):
		var z: float = float(lz)
		var gw: float = (_warp_pos(f, ccx, ccz, lax, 0.0, z) - _warp_pos(f, ccx + 1, ccz, bax, 0.0, z)).length()
		if gw > _warp_max:
			_warp_max = gw
		if not is_finite(gw):
			_fails.append("warp gap not finite: face %d ccx %d ccz %d lz %d" % [f, ccx, ccz, lz])
		var gl: float = (_legacy_pos(f, ccx, ccz, lax, 0.0, z) - _legacy_pos(f, ccx + 1, ccz, bax, 0.0, z)).length()
		if gl > _legacy_max:
			_legacy_max = gl
	# negative control (the FIRST pair only): perturb B's v by one chart
	# cell (one local cell along z) — the gap must become non-zero.
	if _pairs == 1:
		_neg_gap = (_warp_pos(f, ccx, ccz, lax, 0.0, 8.0) - _warp_pos(f, ccx + 1, ccz, bax, 0.0, 9.0)).length()


# The AC-0458 warp construction, verbatim from chunk.gd _warp_face_slabs
# (plan §3.2): chart = the exact inverse of the face_local_x layout;
# world = (R + ly) * normalize(uv_to_world) - (0, R, 0).
func _warp_pos(f: int, ccx: int, ccz: int, lx: float, ly: float, lz: float) -> Vector3:
	var u1024: float = float(ccx) * 16.0 + (16.0 - lx if SM.face_mirror_x(f) else lx)
	var v1024: float = float(ccz) * 16.0 + lz
	var dir: Vector3 = SM.uv_to_world(f, u1024 / CELL, v1024 / CELL, _R)
	return (_R + ly) * (dir / dir.length()) - Vector3(0.0, _R, 0.0)


# The shipped LEGACY placement (plan §3.4 contrast): each chunk's own
# per-chunk LSQ affine fit applied to its own local coordinates.
func _legacy_pos(f: int, ccx: int, ccz: int, lx: float, ly: float, lz: float) -> Vector3:
	return SM.face_chunk_transform(f, ccx, ccz, _R) * Vector3(lx, ly, lz)


func _r6(x: float) -> float:
	return round(x * 1.0e6) / 1.0e6
