# SphereMath — AweCraft planet sphere math (AC-0143 P1a). Pure static; no nodes.
# 12 faces = 6 axes x 2 sectors; face index = axis*2 + sector.
#   axes: 0=+Y, 1=-Y, 2=+X, 3=-X, 4=+Z, 5=-Z
#   FACE 0 = home face = current flat world (u->+x, v->+z, planet top).
# Each face (u,v) in [0,1]^2 maps AFFINELY to a rectangle on the unit cube;
# uv_to_world = normalize(cube_pt) * R ("pre-warp" = the cube step).
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

static func face_for_dir(d: Vector3) -> int:
	# 12-way: dominant axis (tie -> sign order), then sector.
	var n: float = maxf(absf(d.x), absf(d.y), absf(d.z))
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
	return c.normalized() * R

static func world_to_face(pos: Vector3, R: float) -> Dictionary:
	# Invert the affine cube map: C = d rescaled so the dominant component is
	# exactly +-1 (the cube-face plane); (u,v) = C's coords in the face frame.
	var len: float = pos.length()
	if len <= 0.0:
		return { "face": 0, "u": 0.5, "v": 0.5 }
	var d: Vector3 = pos / len
	var face: int = face_for_dir(d)
	var axis: int = face / 2
	var px: float
	var py: float
	var pz: float
	match axis:
		0, 1: # Y faces: C = (d.x/d.y, +-1, d.z/d.y)
			px = d.x / d.y
			py = 1.0 if axis == 0 else -1.0
			pz = d.z / d.y
		2, 3: # X faces: C = (+-1, d.y/d.x, d.z/d.x)
			px = 1.0 if axis == 2 else -1.0
			py = d.y / d.x
			pz = d.z / d.x
		_: # Z faces: C = (d.x/d.z, d.y/d.z, +-1)
			px = d.x / d.z
			py = d.y / d.z
			pz = 1.0 if axis == 4 else -1.0
	var u: float
	var v: float
	match face:
		0, 2, 8, 10:
			u = px
		1, 3, 9, 11:
			u = px + 1.0
		4, 5, 6, 7:
			u = (py + 1.0) * 0.5
	match face:
		0, 1, 2, 3:
			v = (pz + 1.0) * 0.5
		4, 6:
			v = pz
		5, 7:
			v = pz + 1.0
		8, 9, 10, 11:
			v = (py + 1.0) * 0.5
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
