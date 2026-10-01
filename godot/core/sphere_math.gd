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

# AC-0362: the seam grout (see the column_transform section header) — the
# centre-anchored in-plane overlap of the placed facet. 8*SEAM_FILL = 0.8 mm
# of extra footprint per side closes every across-seam slit (design worst
# 53 um; rendered float32 worst 502 um) with a >= 1.07 mm rendered margin.
const SEAM_FILL := 1.0e-4

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
#   origin = P - 8(1+S)x - 8(1+S)z  (S = SEAM_FILL, the AC-0362 grout; the
#             flat corner; the facet centre (8,0,8) still sits at P)
# A's east edge line and B's west edge line (B = A's east neighbour) both
# lie on the two tangent planes' intersection line (the folded-net shared
# edge): they coincide to the irreducible residual — a sphere is not
# developable (AC-0042's grout territory; verified by the AC-0307 probe).
#
# AC-0362 SEAM GROUT — centre-anchored in-plane overlap. Measured
# 2026-09-27 (.scratch/ac0362_true.py, the exact across-seam footprint gap
# of the placed sheets): the folded-net residual sits almost entirely in the
# along-seam/radial directions (the V-crack class, AC-0311); the ACROSS-seam
# footprint residual is 1,284 of the 308,112 home-pair seams open by up to
# 53 um at design precision, and 1,403 seams up to 502 um once the float32
# stored Transform3D rounding is emulated. A ray from above threads the
# ground iff the two footprints' across-seam ranges do not overlap, so the
# grout is a pure in-plane overlap: the basis scales by (1 + SEAM_FILL) in
# the x/z columns and the origin follows, i.e. every footprint extends
# 8*SEAM_FILL past its flat edge (0.8 mm) and every seam gains 16*SEAM_FILL
# = 1.6 mm of double coverage — the rendered worst case becomes a 1.07 mm
# overlap, so all 308,112 seams are opaque with margin. NO TILT: tilting the
# facet would close nothing (the open component is in-plane) and would move
# the terrain. Cost: +0.8 mm per footprint side, <= ~1.2 mm column height
# change, zero new geometry; the local 16x16 range, meshing, greedy
# thresholds, light grid and collision stay flat-local (the flat-local
# invariant holds — only the node transform changed).
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
	# AC-0362 seam grout (section header): the centre-anchored in-plane
	# overlap. The facet stays flat; the basis stays orthogonal (the x/z
	# columns share the scale s); local (8,0,8) still maps to P - (0,R,0).
	var s: float = 1.0 + SEAM_FILL
	var origin: Vector3 = P - 8.0 * s * x - 8.0 * s * z - Vector3(0.0, R, 0.0)
	return Transform3D(Basis(x * s, n, z * s), origin)

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

# --- AC-0309: cross-face movement (P4 of AC-0144) ---
# The home pair (faces 0,1) keeps its exact AC-0306/AC-0307 geometry and
# keying; the helpers below extend the net to faces 2-11 so a player can
# cross a home edge onto the neighbouring face's grid. Faces 2-11 are
# 1024-cell grids (one local unit of a face chunk = one cell = W/1024 m);
# the height stays 1 m.

# AC-0309: one face cell in flat metres (W/1024 = 6.135 m at R = 4000).
static func face_cell_size(R: float) -> float:
	return face_width(R) / float(CELLS_PER_FACE)

# AC-0309: the (u, v) cell widths in flat metres — ANISOTROPIC. The u
# axis spans the full cube-face width W (1024 cells -> S per cell) and
# the v axis spans the half-face W/2 (1024 cells -> S/2 per cell) on the
# x faces (4-7, v along a home edge); the z faces (8-11) swap the roles
# (u = the half axis, v = the full axis). A face chunk's 16x16 local
# grid is therefore S x S/2 metres in-plane on the x faces (S/2 x S on
# the z faces).
static func face_cell_scale(face: int, R: float) -> Vector2:
	var s: float = face_cell_size(R)
	if face >= 4 and face <= 7:
		return Vector2(s, s * 0.5)
	return Vector2(s * 0.5, s)

# AC-0309: the folded net has two chart orientation classes. For these
# faces the (u,v) chart is LEFT-handed relative to the outward radial, so
# a right-handed local frame (+X = n x +Z, +Z = face +v, +Y = radial) runs
# its +X AGAINST the face's u. The chunk data of a mirror face therefore
# stores cell (iu, iv) in local slot (15 - (iu - ccx*16), iv - ccz*16) —
# a DATA-LAYOUT convention (face_local_x), while every face_chunk_transform
# stays a proper right-handed rigid transform (the mesh materials are
# CULL_BACK: a mirrored node basis would cull the terrain).
static func face_mirror_x(face: int) -> bool:
	return (face >= 2 and face <= 5) or (face >= 8 and face <= 9)

# AC-0309: face cell iu -> its chunk-local x slot within chunk ccx
# (the mirror class runs local +X against the face's u; see above).
static func face_local_x(face: int, iu: int, ccx: int) -> int:
	var k: int = iu - ccx * 16
	return 15 - k if face_mirror_x(face) else k

# AC-0309: the face-chart direction at (u0, v0) toward (u0 + d.u, v0 + d.v):
# the chord of the two neighbour sphere points, perpendicularized against
# the centre radial (the column_transform uE/uW construction, in the face
# frame; the clamped one-sided chord at a face border is the same class of
# approximation as that fallback).
static func _face_chart_dir(face: int, u0: float, v0: float, d: Vector2, R: float) -> Vector3:
	var pa: Vector3 = uv_to_world(face, clampf(u0 + float(d.x), 0.0, 1.0), clampf(v0 + float(d.y), 0.0, 1.0), R)
	var pb: Vector3 = uv_to_world(face, clampf(u0 - float(d.x), 0.0, 1.0), clampf(v0 - float(d.y), 0.0, 1.0), R)
	var nc: Vector3 = pa.normalized()
	var t: Vector3 = (pa - pb) - nc * (pa - pb).dot(nc)
	return t.normalized() if t.length() > 1e-9 else Vector3.ZERO

# AC-0309: the placement of face chunk (ccx, ccz) of a NON-HOME face
# (2-11), GLOBAL (home) frame (planet frame shifted by (0, -R, 0)).
# A per-chunk least-squares AFFINE fit of the 256 cell centres to their
# chart positions (uv_to_world): local (lx, lz) -> world, one local unit
# = one cell (face_cell_scale — anisotropic), local +Y = the radial at
# the chunk centre (the height stays 1 m). The chart is not
# affine-developable, so no facet/rigid construction can place every cell
# close over the full 49-98 m chunk: the tangent-plane-at-centre form
# left far-edge cells 3-4 m off the chart and — worse — adjacent chunks'
# shared edges up to 98-189 m apart on the mirror class. The LSQ affine
# keeps every cell within ~0.4 m of its chart position and adjacent
# shared edges within ~0.8 m (the walkable class on the 1 m face step).
# The mirror class enters through the data layout only (face_local_x):
# the fit follows the layout, so the home-edge row sits on the chart
# seam line, which IS the home edge line (the gapless invariant) — the
# home seam closure falls out of the fit; no special edge transform.
# Right-handed on both chart classes (det > 0 measured on all 8 faces);
# the CULL_BACK materials see no mirror.
static var _fit_inv: Array = []  # cached inverse of the 3x3 normal matrix
	# of the 16x16 local grid — the local positions are identical for
	# every chunk, so it is built once (Cramer's-rule cofactors / det)
static func _fit_build_gram() -> void:
	var a := 0.0; var b := 0.0; var c := 0.0
	var d := 0.0; var e := 0.0; var f := 0.0
	var o := 0.0
	for lx in range(16):
		for lz in range(16):
			var x: float = float(lx) + 0.5
			var y: float = float(lz) + 0.5
			a += x * x; b += x * y; c += x
			d += y * y; e += y; o += 1.0
	var det: float = a * (d * o - e * e) - b * (b * o - c * e) + c * (b * e - d * c)
	_fit_inv = [
		(d * o - e * e) / det, (c * e - b * o) / det, (b * e - d * c) / det,
		(c * e - b * o) / det, (a * o - c * c) / det, (b * c - a * e) / det,
		(b * e - d * c) / det, (b * c - a * e) / det, (a * d - b * b) / det,
	]

static func face_chunk_transform(face: int, ccx: int, ccz: int, R: float) -> Transform3D:
	if _fit_inv.is_empty():
		_fit_build_gram()
	var inv: Array = _fit_inv
	var mirrored: bool = face_mirror_x(face)
	var u0: float = (float(ccx) * 16.0 + 8.0) / float(CELLS_PER_FACE)
	var v0: float = (float(ccz) * 16.0 + 8.0) / float(CELLS_PER_FACE)
	var n: Vector3 = uv_to_world(face, u0, v0, R) / R
	# s[world_coord][0..2] = (sum lx*w, sum lz*w, sum w) over the 256
	# cell centres in the HOME frame (uv_to_world minus (0, R, 0)) — the
	# normal-equation RHS row (the Gram matrix's [2][2] stays the count)
	var s: Array = [
		[0.0, 0.0, 0.0],
		[0.0, 0.0, 0.0],
		[0.0, 0.0, 0.0],
	]
	for lx in range(16):
		var iu: int = ccx * 16 + (15 - lx if mirrored else lx)
		var x: float = float(lx) + 0.5
		for lz in range(16):
			var iv: int = ccz * 16 + lz
			var w: Vector3 = uv_to_world(face, (float(iu) + 0.5) / float(CELLS_PER_FACE), (float(iv) + 0.5) / float(CELLS_PER_FACE), R) - Vector3(0.0, R, 0.0)
			var y: float = float(lz) + 0.5
			s[0][0] += x * w.x; s[0][1] += y * w.x; s[0][2] += w.x
			s[1][0] += x * w.y; s[1][1] += y * w.y; s[1][2] += w.y
			s[2][0] += x * w.z; s[2][1] += y * w.z; s[2][2] += w.z
	# co[world_coord] = [coef_lx, coef_lz, const] (inv * the moment row)
	var co: Array = []
	for ci in range(3):
		co.append([
			inv[0] * s[ci][0] + inv[1] * s[ci][1] + inv[2] * s[ci][2],
			inv[3] * s[ci][0] + inv[4] * s[ci][1] + inv[5] * s[ci][2],
			inv[6] * s[ci][0] + inv[7] * s[ci][1] + inv[8] * s[ci][2],
		])
	return Transform3D(
		Basis(
			Vector3(co[0][0], co[1][0], co[2][0]),
			n,
			Vector3(co[0][1], co[1][1], co[2][1]),
		),
		Vector3(co[0][2], co[1][2], co[2][2]),
	)

# AC-0309: the EXTENDED home flat (x, z) of a planet-frame sphere point
# whose direction has y > 0 (near/above the home-pair hemisphere): the home
# chart run past its edges — the per-coordinate pre-warp has no
# singularity in the home-patch neighbourhood, so sphere points just across
# a home edge map to flat coords just past ±hw (the exact inverse of the
# midline arc law x = hw*u: d.x/d.y = tan(pi*x/(4*hw))). Returns (INF, INF)
# for d.y <= 0 (far from the home patch — the ratio would resolve onto the
# wrong edge).
static func home_flat_ext(p: Vector3, R: float) -> Vector2:
	var d: Vector3 = p.normalized()
	if d.y <= 0.0:
		return Vector2(INF, INF)
	var hw: float = face_width(R) * 0.5
	var k: float = hw * 4.0 / PI
	return Vector2(k * atan(d.x / d.y), k * atan(d.z / d.y))

# AC-0309 (retitled at AC-0311 piece 3): the HOME-EXTENDED FLAT position
# of a face cell: the cell centre's (fx, fz) on the home chart run past
# its edges, plus d_edge, its distance in metres to the nearest home-
# shared cube edge — INF for cells that do not border the home pair (the
# -Y faces, and +X/-X/+Z/-Z cells on the far hemisphere, d.y <= 0).
# Consumers: world.gd's C3 cross-face ring resamples the LIVE home column
# at (fx, fz) (meshing the boundary never merges across the seam — it
# reads the neighbour's data at the shared edge), and the D5 face-chunk
# streaming window distances the chunk's corner cells to the player's
# flat position through (fx, fz); the is_inf(z) form is the "does not
# border the home patch" sentinel. The d_edge VALUE served the C1 blend
# band's weight (1 - d_edge/BAND) — deleted with the band at AC-0311
# piece 3 (the (d, δ) field is continuous across the edge on its own);
# the finite d_edge read is now unused, the INF sentinel is not.
static func face_cell_band(face: int, ccx: int, ccz: int, R: float) -> Vector3:
	if face < 4:
		return Vector3(INF, INF, INF)
	var u: float = (float(ccx) + 0.5) / float(CELLS_PER_FACE)
	var v: float = (float(ccz) + 0.5) / float(CELLS_PER_FACE)
	var P: Vector3 = uv_to_world(face, u, v, R)
	var f: Vector2 = home_flat_ext(P, R)
	if is_inf(f.x):
		return Vector3(INF, INF, INF)
	var hw: float = face_width(R) * 0.5
	var de: float
	if face == 4 or face == 5:      # +X: the home edge is flat x = +hw
		de = f.x - hw
	elif face == 6 or face == 7:    # -X: the home edge is flat x = -hw
		de = -hw - f.x
	elif face == 8 or face == 9:    # +Z: the home edge is flat z = +hw
		de = f.y - hw
	else:                           # -Z: the home edge is flat z = -hw
		de = -hw - f.y
	return Vector3(f.x, f.y, de)
