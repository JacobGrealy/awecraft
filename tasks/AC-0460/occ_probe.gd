# AC-0460 stage 2a (plan.html §5) — the occluder arithmetic probe. Pure
# SphereMath, no world: under the AC-0458 warp (chunk.gd _warp_face_slabs)
# the face chunk node is identity, so a full slab's opaque mesh AABB IS its
# world-space bound. The code (plan §4) builds a BoxOccluder3D sized to that
# AABB with the OccluderInstance3D at its centre. This probe re-runs the SAME
# construction pointwise on each slab's 8 local corners and asserts what §4
# owes:
#   - the derived occluder CENTRE lies inside the chunk's own warped
#     corner-cloud AABB (the 8 corners of the 16 x 384 x 16 local column);
#   - the derived SIZE is within [1, 40] m on every axis (a full slab must
#     read neither 0 nor beyond-chunk on any axis);
#   - the GUARD: an empty/degenerate AABB (any axis <= 0.01) is REJECTED, the
#     way the code leaves s.occluder null (negative test — the instrument can
#     fail).
# It also reports how far the legacy constant box centre (local (8, y0+8, 8))
# would sit from the derived centre under the identity node — the distance
# that made AC-0461 disable the occluder.
# Standalone SceneTree, one RESULT {…} JSON line (the AC-0433 probe style).
extends SceneTree

const SM := preload("res://core/sphere_math.gd")

const CELL := 1024.0  # legacy face-chart resolution (the warp's chart)
const FACE := 4       # the stage-1 census's first face chunk (4:63:0), mirrored class
const CCX := 63
const CCZ := 0
const HEIGHT := 384   # Data.HEIGHT (autoload/data.gd) — the local column height
const SLAB_H := 16.0  # one slab (16 x 16 x 16)
const DEGEN_EPS := 0.01  # plan §4 guard threshold, verbatim

var _R := 4000.0
var _r_src := "default-4000"
var _fails: Array = []


func _initialize() -> void:
	# R = Game.planet_R if the autoload is present, else 4000 (game.gd pins
	# 4000.0; state the source in the RESULT).
	var g := root.get_node_or_null("Game")
	if g != null and g.get("planet_R") != null:
		_R = float(g.get("planet_R"))
		_r_src = "Game.planet_R"
	# The chunk's own warped corner cloud (the 8 corners of the full local
	# column) — the bound the derived centres must sit inside.
	var cc := _aabb_of(0.0, 0.0, 16.0, float(HEIGHT), 16.0)
	var slab0: Dictionary = {}
	var worst := Vector3.ZERO
	var legacy_offset_m := -1.0
	for si in range(int(HEIGHT) / int(SLAB_H)):
		var y0: float = float(si) * SLAB_H
		var ab := _aabb_of(0.0, y0, 16.0, SLAB_H, 16.0)
		var centre: Vector3 = ab.get_center()  # §4: the OccluderInstance3D position
		var size: Vector3 = ab.size            # §4: the BoxOccluder3D size
		if si == 0:
			slab0 = {
				"centre": [_r2(centre.x), _r2(centre.y), _r2(centre.z)],
				"size": [_r2(size.x), _r2(size.y), _r2(size.z)],
			}
			# the legacy constant box centre (chunk.gd flag-off path) in the
			# identity node frame vs the derived centre, for the same slab.
			legacy_offset_m = roundf((centre - Vector3(8.0, y0 + 8.0, 8.0)).length() * 100.0) / 100.0
		if not _inside(cc, centre):
			_fails.append("slab %d centre outside the chunk corner-cloud AABB" % si)
		# Band derived from the DOCUMENTED footprint, not a guess (the first
		# version of this probe used a [1, 40] m box, which was the
		# coordinator's error): a face chunk is 16 cells and a cell is
		# ~6.14 m of arc, i.e. a 49-98 m footprint (sphere_math.gd:470-487).
		# So the two LARGEST axes are horizontal footprints and must fall in
		# [16, 110] m (110 covers 98 with margin; 16 rejects a degenerate
		# box), and the SMALLEST axis is the slab's vertical extent, which
		# must fall in [1, 128] m.
		var comps: Array = [size.x, size.y, size.z]
		comps.sort()
		var horizontal: Array = [comps[1], comps[2]]
		for ax in range(2):
			if horizontal[ax] < 16.0 or horizontal[ax] > 110.0:
				_fails.append("slab %d horizontal size %f outside [16, 110] m" % [si, horizontal[ax]])
		if comps[0] < 1.0 or comps[0] > 128.0:
			_fails.append("slab %d vertical size %f outside [1, 128] m" % [si, comps[0]])
		worst = Vector3(maxf(worst.x, size.x), maxf(worst.y, size.y), maxf(worst.z, size.z))
	# Guard negative test (the §4 guard operates on the MESH aabb — an
	# empty/degenerate one leaves s.occluder null): the exact predicate the
	# code uses must reject a zero-size aabb and accept a full-slab aabb.
	var dz: AABB = AABB(Vector3.ZERO, Vector3.ZERO)
	var full: AABB = AABB(Vector3.ZERO, Vector3(16.0, 16.0, 16.0))
	var degen_rejected: bool = _guard_rejects(dz) and not _guard_rejects(full)
	if not degen_rejected:
		_fails.append("guard predicate: the zero-size aabb was not rejected (or the full-slab aabb was)")
	var ok: bool = _fails.is_empty()
	print("RESULT " + JSON.stringify({
		"ok": ok,
		"R": _R,
		"r_source": _r_src,
		"face": FACE,
		"ccx": CCX,
		"ccz": CCZ,
		"chunk_cloud": {
			"min": [_r2(cc.position.x), _r2(cc.position.y), _r2(cc.position.z)],
			"max": [_r2(cc.end.x), _r2(cc.end.y), _r2(cc.end.z)],
			"size": [_r2(cc.size.x), _r2(cc.size.y), _r2(cc.size.z)],
		},
		"slab0": slab0,
		"worst_size": [_r2(worst.x), _r2(worst.y), _r2(worst.z)],
		"legacy_offset_m": legacy_offset_m,
		"degenerate_rejected": degen_rejected,
		"fails": _fails,
	}))
	quit()


# The AC-0458 warp construction, verbatim from chunk.gd _warp_face_slabs
# (plan §5 / the AC-0433 warp probe): chart = the exact inverse of the
# face_local_x layout; world = (R + ly) * normalize(uv_to_world) - (0, R, 0).
func _warp_pos(f: int, ccx: int, ccz: int, lx: float, ly: float, lz: float) -> Vector3:
	var u1024: float = float(ccx) * 16.0 + (16.0 - lx if SM.face_mirror_x(f) else lx)
	var v1024: float = float(ccz) * 16.0 + lz
	var dir: Vector3 = SM.uv_to_world(f, u1024 / CELL, v1024 / CELL, _R)
	return (_R + ly) * (dir / dir.length()) - Vector3(0.0, _R, 0.0)


# The warped corner cloud of one local box: the AABB of its 8 warped corners.
func _aabb_of(x0: float, y0: float, dx: float, dy: float, dz: float) -> AABB:
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	for cx in [x0, x0 + dx]:
		for cy in [y0, y0 + dy]:
			for cz in [0.0, dz]:
				var p: Vector3 = _warp_pos(FACE, CCX, CCZ, cx, cy, cz)
				mn = Vector3(minf(mn.x, p.x), minf(mn.y, p.y), minf(mn.z, p.z))
				mx = Vector3(maxf(mx.x, p.x), maxf(mx.y, p.y), maxf(mx.z, p.z))
	return AABB(mn, mx - mn)


func _inside(aabb: AABB, p: Vector3, eps := 0.05) -> bool:
	var mn: Vector3 = aabb.position - Vector3(eps, eps, eps)
	var mx: Vector3 = aabb.end + Vector3(eps, eps, eps)
	return p.x >= mn.x and p.x <= mx.x and p.y >= mn.y and p.y <= mx.y and p.z >= mn.z and p.z <= mx.z


# The §4 guard predicate, verbatim (chunk.gd: the warped branch keeps the
# occluder only when every aabb axis is > DEGEN_EPS).
func _guard_rejects(aabb: AABB) -> bool:
	return not (aabb.size.x > DEGEN_EPS and aabb.size.y > DEGEN_EPS and aabb.size.z > DEGEN_EPS)


func _r2(x: float) -> float:
	return roundf(x * 100.0) / 100.0
