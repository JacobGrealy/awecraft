# SphereMath — AweCraft planet sphere math (AC-0143 P1a; grid lock AC-0306). Pure static; no nodes.
# 12 faces = 6 axes x 2 sectors; face index = axis*2 + sector.
#   axes: 0=+Y, 1=-Y, 2=+X, 3=-X, 4=+Z, 5=-Z
#   FACE 0 = home face = current flat world (u->+x, v->+z, planet top).
# Each face (u,v) in [0,1]^2 maps AFFINELY to a rectangle on the unit cube;
# uv_to_world = normalize(prewarp(cube_pt)) * R ("pre-warp" = the cube step
# plus the AC-0306 spacing warp, below).
#
# AC-0306 GRID LOCK — one flat metre is one metre of arc:
#   one lap of the flat world (4 cube faces of W columns) = 2*pi*R
#   => W/R = pi/2, i.e. face_width(R) = pi*R/2 = 6283 at the shipped R = 4000.
# The flat home patch (faces 0+1, one cube face) is therefore W x W m (3141 per
# half), NOT 2R x 2R as the pre-AC-0306 keying cx = R*u implied (ratio 2.000
# => 0.72 m of arc per block — the planet was a subtly shrunken Minecraft).
# The pre-warp makes the flat-to-arc map equal-spaced: a cube coordinate c
# (in [-1,1], the flat distance from the face midline scaled by the half-face)
# becomes tan(c*pi/4), so the on-sphere arc along either face midline is
# exactly R*atan(tan(c*pi/4)) = c*(pi*R/4) = c*(W/2) — 1 column = 1 m = 1 m of
# arc, EXACT on the midlines. The warp is per-coordinate (a pointwise function
# of each cube coordinate): it is the ONLY warp shape that keeps the gapless
# invariant, because both faces on a shared edge evaluate the same raw cube
# arithmetic and must stay bitwise-identical after the warp. tan(pi/4) = 1 and
# tan(0) = 0, so the cube edges and the face midlines are fixed points of the
# warp and every shared edge still matches. Residual (irreducible cube-sphere
# spread, measured 2026-09-25): 1.00 m on the midlines, ~0.93 m averaged over
# a face, ~0.86 m pole-to-corner (the 0.71 m floor sits on the one-column edge
# row adjacent to a midline — where the flat net wraps the cube edge). A sphere
# is not developable, so no single fixed grid can give 1 m at every radius:
# per planet W = 1.5708*R.
# Cube maps C(face, u, v):
#   0: (u, 1, 2v-1)      1: (u-1, 1, 2v-1)     [+Y halves, split on X]
#   2: (u, -1, 2v-1)     3: (u-1, -1, 2v-1)    [-Y halves]
#   4: (1, 2u-1, v)      5: (1, 2u-1, v-1)     [+X halves, split on Z]
#   6: (-1, 2u-1, v)     7: (-1, 2u-1, v-1)    [-X halves]
#   8: (u, 2v-1, 1)      9: (u-1, 2v-1, 1)     [+Z halves, split on X]
#   10: (u, 2v-1, -1)    11: (u-1, 2v-1, -1)   [-Z halves]
# Gapless invariant: on every shared edge both faces evaluate the SAME
# arithmetic (same literals / same 2t-1 forms on equal t) => bitwise-identical
# pre-normalize cube vector. "Sector edge resolution mismatch" is handled
# cell-wise in neighbor_key (2:1 cell ratio across cube edges, 1:1 midlines).
# Tie-breaks (face_for_dir AND world_to_face): dominant axis = largest
# |component|; among equal-magnitude candidates the sign order
# +X, -X, +Y, -Y, +Z, -Z wins (corner (1,1,1) -> +X).
# Sector: +/-Y faces split on X (x>=0 -> even), +/-X on Z (z>=0 -> even),
# +/-Z on X (x>=0 -> even).
# Verified at runtime by the AWECRAFT_LOGIC=sphere probe (later run).

class_name SphereMath

const CELLS_PER_FACE := 1024

# AC-0306: the flat width (m = columns) of ONE cube face at radius R. The grid
# lock: 4 face-widths = the sphere circumference 2*pi*R => W = pi*R/2 (the
# per-planet rule W = 1.5708*R). At the shipped R = 4000: W = 6283 (3141 per
# home half). See the file header.
static func face_width(R: float) -> float:
	return PI * R * 0.5

# AC-0306: the per-coordinate pre-warp. c in [-1,1] (one cube coord) ->
# tan(c*pi/4). Fixes -1/0/1 (edges + midline centre), makes the midline arc
# R*atan(tan(c*pi/4)) = c*(pi*R/4) = c*(W/2) exactly — 1 m of arc per flat m.
static func _prewarp(c: float) -> float:
	return tan(c * PI * 0.25)

static func _prewarp_inv(c: float) -> float:
	# Exact inverse of _prewarp on [-1,1]: (4/pi)*atan(c).
	return atan(c) * 4.0 / PI

static func face_for_dir(d: Vector3) -> int:
	# 12-way: dominant axis (tie -> sign order), then sector.
	var n: float = maxf(maxf(absf(d.x), absf(d.y)), absf(d.z))
	if n <= 0.0:
		return 0
	var x: float = d.x / n
	var y: float = d.y / n
	var z: float = d.z / n
	# /n makes the winning component exactly +-1.0; first hit in the
	# tie order +X, -X, +Y, -Y, +Z, -Z wins.
	var axis: int = 2 if x == 1.0 else 3 if x == -1.0 else 0 if y == 1.0 else 1 if y == -1.0 else 4 if z == 1.0 else 5
	# sector: even = the ">=0" half of the split coord (Z for X-faces, X otherwise).
	var sp: float = z if axis == 2 or axis == 3 else x
	return axis * 2 + (1 if sp < 0.0 else 0)

static func uv_to_world(face: int, u: float, v: float, R: float) -> Vector3:
	# Cube maps from the header table (face index = axis*2 + sector).
	var c: Vector3
	match face:
		0: c = Vector3(u, 1.0, 2.0 * v - 1.0)
		1: c = Vector3(u - 1.0, 1.0, 2.0 * v - 1.0)
		2: c = Vector3(u, -1.0, 2.0 * v - 1.0)
		3: c = Vector3(u - 1.0, -1.0, 2.0 * v - 1.0)
		4: c = Vector3(1.0, 2.0 * u - 1.0, v)
		5: c = Vector3(1.0, 2.0 * u - 1.0, v - 1.0)
		6: c = Vector3(-1.0, 2.0 * u - 1.0, v)
		7: c = Vector3(-1.0, 2.0 * u - 1.0, v - 1.0)
		8: c = Vector3(u, 2.0 * v - 1.0, 1.0)
		9: c = Vector3(u - 1.0, 2.0 * v - 1.0, 1.0)
		10: c = Vector3(u, 2.0 * v - 1.0, -1.0)
		_: c = Vector3(u - 1.0, 2.0 * v - 1.0, -1.0)
	# AC-0306: the per-coordinate pre-warp (see the file header). Pointwise in
	# each cube coord, so the gapless edge arithmetic is preserved.
	return Vector3(_prewarp(c.x), _prewarp(c.y), _prewarp(c.z)).normalized() * R

static func world_to_face(pos: Vector3, R: float) -> Dictionary:
	# Invert the affine cube map: C = d rescaled so the dominant component
	# is exactly +-1 by |dom| (dividing by the signed dominant would flip
	# the sign of the other components on negative-axis faces); (u,v) =
	# C's coords in the face frame.
	var len: float = pos.length()
	if len <= 0.0:
		return { "face": 0, "u": 0.5, "v": 0.5 }
	var d: Vector3 = pos / len
	var face: int = face_for_dir(d)
	var dom: float = maxf(maxf(absf(d.x), absf(d.y)), absf(d.z))
	var C: Vector3 = d / dom
	# AC-0306: un-warp C back to the raw (affine) cube frame — C carries the
	# pre-warped coordinates the forward map normalized.
	var Cx: float = _prewarp_inv(C.x)
	var Cy: float = _prewarp_inv(C.y)
	var Cz: float = _prewarp_inv(C.z)
	var u: float
	var v: float
	match face:
		0, 2, 8, 10:
			u = Cx
		1, 3, 9, 11:
			u = Cx + 1.0
		4, 5, 6, 7:
			u = (Cy + 1.0) * 0.5
	match face:
		0, 1, 2, 3:
			v = (Cz + 1.0) * 0.5
		4, 6:
			v = Cz
		5, 7:
			v = Cz + 1.0
		8, 9, 10, 11:
			v = (Cy + 1.0) * 0.5
	return { "face": face, "u": u, "v": v }

# Neighbor edge table (P1a). _EDGES[face][edge], edge 0=u=1, 1=u=0, 2=v=1,
# 3=v=0. Each edge = list of segments [tlo, thi, B, edgeB, a, b]: for t in
# [tlo, thi) the crossing lands on face B's edge edgeB at coordinate
# s = a + b*t along that edge (t = the cell-center coordinate along the
# source edge, in [0,1]). Landed cell = B's edge-adjacent cell
# floor(s*CELLS_PER_FACE) (2:1 segments = "sector edge resolution mismatch"
# across cube edges; round-trip within +/-1 cell; midlines are exact 1:1).
const _EDGES: Array = [
	[ # face 0 (home, +Y even)
		[[0.0, 0.5, 5, 0, 0.0, 2.0], [0.5, 1.0, 4, 0, -1.0, 2.0]],
		[[0.0, 1.0, 1, 0, 0.0, 1.0]],
		[[0.0, 1.0, 8, 2, 0.0, 1.0]],
		[[0.0, 1.0, 10, 2, 0.0, 1.0]],
	],
	[ # face 1 (+Y odd)
		[[0.0, 1.0, 0, 1, 0.0, 1.0]],
		[[0.0, 0.5, 7, 0, 0.0, 2.0], [0.5, 1.0, 6, 0, -1.0, 2.0]],
		[[0.0, 1.0, 9, 2, 0.0, 1.0]],
		[[0.0, 1.0, 11, 2, 0.0, 1.0]],
	],
	[ # face 2 (-Y even)
		[[0.0, 0.5, 5, 1, 0.0, 2.0], [0.5, 1.0, 4, 1, -1.0, 2.0]],
		[[0.0, 1.0, 3, 0, 0.0, 1.0]],
		[[0.0, 1.0, 8, 3, 0.0, 1.0]],
		[[0.0, 1.0, 10, 3, 0.0, 1.0]],
	],
	[ # face 3 (-Y odd)
		[[0.0, 1.0, 2, 1, 0.0, 1.0]],
		[[0.0, 0.5, 7, 1, 0.0, 2.0], [0.5, 1.0, 6, 1, -1.0, 2.0]],
		[[0.0, 1.0, 9, 3, 0.0, 1.0]],
		[[0.0, 1.0, 11, 3, 0.0, 1.0]],
	],
	[ # face 4 (+X even)
		[[0.0, 1.0, 0, 0, 0.5, 0.5]],
		[[0.0, 1.0, 2, 0, 0.5, 0.5]],
		[[0.0, 1.0, 8, 0, 0.0, 1.0]],
		[[0.0, 1.0, 5, 2, 0.0, 1.0]],
	],
	[ # face 5 (+X odd)
		[[0.0, 1.0, 0, 0, 0.0, 0.5]],
		[[0.0, 1.0, 2, 0, 0.0, 0.5]],
		[[0.0, 1.0, 4, 3, 0.0, 1.0]],
		[[0.0, 1.0, 10, 0, 0.0, 1.0]],
	],
	[ # face 6 (-X even)
		[[0.0, 1.0, 1, 1, 0.5, 0.5]],
		[[0.0, 1.0, 3, 1, 0.5, 0.5]],
		[[0.0, 1.0, 9, 1, 0.0, 1.0]],
		[[0.0, 1.0, 7, 2, 0.0, 1.0]],
	],
	[ # face 7 (-X odd)
		[[0.0, 1.0, 1, 1, 0.0, 0.5]],
		[[0.0, 1.0, 3, 1, 0.0, 0.5]],
		[[0.0, 1.0, 6, 3, 0.0, 1.0]],
		[[0.0, 1.0, 11, 1, 0.0, 1.0]],
	],

	[ # face 8 (+Z even)
		[[0.0, 1.0, 4, 2, 0.0, 1.0]],
		[[0.0, 1.0, 9, 0, 0.0, 1.0]],
		[[0.0, 1.0, 0, 2, 0.0, 1.0]],
		[[0.0, 1.0, 2, 2, 0.0, 1.0]],
	],
	[ # face 9 (+Z odd)
		[[0.0, 1.0, 8, 1, 0.0, 1.0]],
		[[0.0, 1.0, 6, 2, 0.0, 1.0]],
		[[0.0, 1.0, 1, 2, 0.0, 1.0]],
		[[0.0, 1.0, 3, 2, 0.0, 1.0]],
	],
	[ # face 10 (-Z even)
		[[0.0, 1.0, 5, 3, 0.0, 1.0]],
		[[0.0, 1.0, 11, 0, 0.0, 1.0]],
		[[0.0, 1.0, 0, 3, 0.0, 1.0]],
		[[0.0, 1.0, 2, 3, 0.0, 1.0]],
	],
	[ # face 11 (-Z odd)
		[[0.0, 1.0, 10, 1, 0.0, 1.0]],
		[[0.0, 1.0, 7, 3, 0.0, 1.0]],
		[[0.0, 1.0, 1, 3, 0.0, 1.0]],
		[[0.0, 1.0, 3, 3, 0.0, 1.0]],
	],
]

static func neighbor_key(face: int, cx: int, cz: int, dir: Vector2i) -> Dictionary:
	# One cell step in dir (Vector2i, single axis) from (cx, cz). Interior ->
	# same face. Edge -> _EDGES table: deterministic; 2:1 cell ratio across
	# cube edges (documented "sector edge resolution mismatch"); corner cells
	# resolved by the face_for_dir tie order.
	var u1: float = (cx + 0.5) / float(CELLS_PER_FACE) + float(dir.x) / float(CELLS_PER_FACE)
	var v1: float = (cz + 0.5) / float(CELLS_PER_FACE) + float(dir.y) / float(CELLS_PER_FACE)
	if u1 > 0.0 and u1 < 1.0 and v1 > 0.0 and v1 < 1.0:
		return { "face": face, "cx": cx + dir.x, "cz": cz + dir.y }
	var e: int
	if dir.x > 0:
		e = 0
	elif dir.x < 0:
		e = 1
	elif dir.y > 0:
		e = 2
	else:
		e = 3
	var t: float = (cz + 0.5) / float(CELLS_PER_FACE) if e < 2 else (cx + 0.5) / float(CELLS_PER_FACE)
	var segs: Array = _EDGES[face][e]
	var seg: Array = segs[segs.size() - 1]
	for s_ in segs:
		if t < float(s_[1]):
			seg = s_
			break
	var s: float = float(seg[4]) + float(seg[5]) * t
	var along: int = clampi(int(floor(s * float(CELLS_PER_FACE))), 0, CELLS_PER_FACE - 1)
	var cxB: int
	var czB: int
	if int(seg[3]) < 2:
		cxB = CELLS_PER_FACE - 1 if int(seg[3]) == 0 else 0
		czB = along
	else:
		cxB = along
		czB = CELLS_PER_FACE - 1 if int(seg[3]) == 2 else 0
	return { "face": int(seg[2]), "cx": cxB, "cz": czB }

# --- AC-0307: rigid per-column placement (P2 of AC-0144) ---
# The home pair (faces 0,1 = the flat world) is bent onto the planet by ONE
# RIGID transform per 16x16 chunk column: chunk geometry stays in flat local
# space (meshing, greedy thresholds, light grid, collision all unchanged);
# the column node's transform carries the curvature. The ground is a
# gapless polyhedron of 16 m tangent facets (adjacent facets differ by
# ~16/R = 0.23 deg at R = 4000), so physics and visuals coincide.
#
# Column c with flat corner (16cx, 16cz), centre C = (16cx+8, 16cz+8):
#   P     = home_point(C)        (|P| = R, planet frame below)
#   n     = P / R                (LOCAL +Y = the radial at the column's own
#                                 centre — the facet is the tangent plane at P)
#   uE/uW = the two x-neighbours' shared-edge directions: the intersection
#           direction of this facet's tangent plane with the neighbour's
#           (sign kept in the flat +z sense against the centre chord z0)
#   z     = normalize(uE + uW)   (one-sided -> the single one; none -> z0)
#   x     = n cross z
#   origin = P - 8x - 8z         (the flat corner; the facet centre sits at P)
# A's east edge line and B's west edge line (B = A's east neighbour) both
# lie on the two tangent planes' intersection line (the folded-net shared
# edge): they coincide to the irreducible mm-cm residual — a sphere is not
# developable (AC-0042's grout territory; verified by the AC-0307 probe).
#
# FRAMES: the planet frame has origin = the planet centre and the home face
# on +Y, so the flat origin (the home-patch centre) sits at (0, R, 0). The
# GLOBAL frame is the planet frame shifted by (0, -R, 0): the flat origin
# stays at the global origin, spawn and every global-space consumer keep
# working near the spawn (flat coords agree with global there to mm).
static func home_uv(x: float, z: float, R: float) -> Dictionary:
	# Flat (x,z) on the home pair -> (face, u, v) for uv_to_world.
	# Face 0: x = (pi*R/4)*u (x in [0, hw]); face 1: x = (pi*R/4)*(u-1);
	# z = (pi*R/4)*(2v-1). Same half-face width as World.key_for_sphere_pos.
	var hw: float = face_width(R) * 0.5
	if x < 0.0:
		return { "face": 1, "u": x / hw + 1.0, "v": (z / hw + 1.0) * 0.5 }
	return { "face": 0, "u": x / hw, "v": (z / hw + 1.0) * 0.5 }

static func home_point(x: float, z: float, R: float) -> Vector3:
	# Flat (x,z) -> the planet-frame sphere point (|P| = R). The cube map
	# extends continuously past the face edges (the per-coordinate pre-warp
	# has no pole inside the neighbourhood of the home patch), so centre-of-
	# column queries on the last columns past the patch boundary stay valid.
	var r: Dictionary = home_uv(x, z, R)
	return uv_to_world(int(r["face"]), float(r["u"]), float(r["v"]), R)

static func column_transform(cx: int, cz: int, R: float) -> Transform3D:
	# The rigid placement of chunk column (cx, cz) of the home pair, in the
	# GLOBAL frame (planet frame shifted by (0, -R, 0)). Construction: the
	# section header above.
	var cxx: float = float(cx) * 16.0 + 8.0
	var czz: float = float(cz) * 16.0 + 8.0
	var P: Vector3 = home_point(cxx, czz, R)
	var n: Vector3 = P / R
	var z0: Vector3 = (home_point(cxx, czz + 8.0, R) - home_point(cxx, czz - 8.0, R)).normalized()
	var uE: Vector3 = (home_point(cxx + 16.0, czz, R) / R).cross(n).normalized()
	if uE.dot(z0) < 0.0:
		uE = -uE
	var uW: Vector3 = (home_point(cxx - 16.0, czz, R) / R).cross(n).normalized()
	if uW.dot(z0) < 0.0:
		uW = -uW
	var z: Vector3
	if not uE.is_zero_approx() and not uW.is_zero_approx():
		z = (uE + uW).normalized()
	elif not uE.is_zero_approx():
		z = uE
	elif not uW.is_zero_approx():
		z = uW
	else:
		z = z0
	var x: Vector3 = n.cross(z).normalized()
	var origin: Vector3 = P - 8.0 * x - 8.0 * z - Vector3(0.0, R, 0.0)
	return Transform3D(Basis(x, n, z), origin)

static func flat_to_world(x: float, y: float, z: float, R: float) -> Vector3:
	# Flat (block) coords (x, height, z) -> global world position: the point
	# in its column's placed facet frame (exact at facet precision).
	var cx := int(floorf(x / 16.0))
	var cz := int(floorf(z / 16.0))
	return column_transform(cx, cz, R) * Vector3(x - float(cx) * 16.0, y, z - float(cz) * 16.0)

static func world_to_flat(p: Vector3, R: float) -> Vector3:
	# Global world position -> flat (block) coords (x, height above the
	# local facet, z). The exact inverse of flat_to_world: the planet-frame
	# direction inverts through the shared world_to_face map for a first
	# guess (the direction of the ray from the planet centre is biased
	# toward the column centre by in_plane * h/(R+h) for a point at height
	# h), then a 3x3 scan snaps to the column whose placed flat frame
	# actually contains the point — the local coordinates ARE the flat
	# coords (the height is above the local facet plane, not the radial).
	# Off-home-pair directions (cross-face travel is AC-0309) clamp to the
	# home-patch boundary (the nearest point of the +Y cube face) —
	# deterministic.
	var pp: Vector3 = p + Vector3(0.0, R, 0.0)
	var dir: Vector3 = pp.normalized()
	var m: float = maxf(absf(dir.x), absf(dir.z))
	if m >= absf(dir.y) or dir.y <= 0.0:
		dir = Vector3(dir.x, (m * 1.0001) if m > 0.0 else 1.0, dir.z)
	var r: Dictionary = world_to_face(dir, R)
	var face: int = int(r["face"])
	var hw: float = face_width(R) * 0.5
	var fx: float = (float(r["u"]) - (0.0 if face == 0 else 1.0)) * hw
	var fz: float = hw * (2.0 * float(r["v"]) - 1.0)
	var cx0 := int(floorf(fx / 16.0))
	var cz0 := int(floorf(fz / 16.0))
	var best: Vector3 = Vector3(fx, pp.length() - R, fz)
	var best_over := 1e18
	var best_h := 1e18
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var t: Transform3D = column_transform(cx0 + dx, cz0 + dz, R)
			var loc: Vector3 = t.affine_inverse() * p
			# in-plane overshoot of the column footprint (0 = the point
			# projects inside); the facets OVERLAP across their shared edge
			# by the folded-net residual (mm near the spawn, up to ~2 m in
			# the spacing-stretch region of the patch corner), so several
			# columns can contain the projection — the second key picks the
			# facet the point actually lies ON (the smallest |loc.y|).
			var over: float = maxf(0.0, -loc.x) + maxf(0.0, loc.x - 16.0) \
					+ maxf(0.0, -loc.z) + maxf(0.0, loc.z - 16.0)
			var h: float = absf(loc.y)
			if over < best_over or (over == best_over and h < best_h):
				best_over = over
				best_h = h
				best = Vector3(float(cx0 + dx) * 16.0 + loc.x, loc.y, float(cz0 + dz) * 16.0 + loc.z)
	return best
