# PlanetGrid — AC-0433 P2a: the dormant canonical grid/conversion API.
#
# Pure, face-independent address/placement API on top of the shipped SphereMath
# chart mapping (preloaded BY PATH as SM — no dependency on class-cache or
# autoload ordering; the shipped SphereMath functions are called, never
# transcribed). Design: docs/ac0433-unified-model.html §1/§3.
#
# Grid rule (§1): H = face_width(R)/2, N = 16*ceil(H/16). Short chart axis =
# N cells, long axis = 2N. Faces 4-7 use (Nu,Nv) = (2N,N); all other faces
# (N,2N), per the coordinate spans in SphereMath.uv_to_world.
#
# Placement rule (§2): shared-vertex radial embedding — the canonical integer
# cube-lattice vertex Q (one identity per physical vertex, identical on every
# incident chart) is evaluated once, on the owning chart:
#   owner = SM.face_for_dir(Vector3(Q)) (the shipped tie order on the raw Q),
#   (u,v) = the chart inverse (sphere_math.gd world_to_face formulas) on C = Q/N,
#   n = normalize(SM.uv_to_world(owner, u, v, R)),
#   P(h) = (R + h) * n - (0, R, 0)        (global frame = planet frame + (0,-R,0))
# so two incident charts of one boundary vertex agree by construction at every
# equal height (the seam proof, docs/ac0433-unified-model.html §2).
#
# DORMANT (P2a): no production callers, no runtime key replacement, no save
# format — the intra-planet address_key here is NOT an activated save key.
# Neighbour traversal, key storage and live migration are later bounded units.
# No mutable state: every method is stateless and allocates only for its query.

class_name PlanetGrid
extends RefCounted

const SM := preload("res://core/sphere_math.gd")
const CHUNK_WIDTH: int = 16

const INVALID_POINT := Vector3(INF, INF, INF)


# Grid dimensions (Nu, Nv) in cells for one chart, or Vector2i.ZERO for an
# invalid face (not 0..11) or a non-finite / non-positive radius.
static func grid_shape(face: int, R: float) -> Vector2i:
	if not _valid_face(face) or not _valid_R(R):
		return Vector2i.ZERO
	var n: int = 16 * int(ceil(SM.face_width(R) / 2.0 / 16.0))
	if face >= 4 and face <= 7:
		return Vector2i(2 * n, n)
	return Vector2i(n, 2 * n)


# Canonical integer cube-lattice vertex Q of chart vertex (i, j): the exact
# integer formulas of the chart grid (not float-position rounding), identical
# on chart joins, cube edges and corners. Closed vertex domain 0 <= i <= Nu,
# 0 <= j <= Nv; invalid face/radius/indices return Vector3i.ZERO (impossible
# for a valid surface vertex — the lattice never lands at the cube centre).
static func vertex_key(face: int, i: int, j: int, R: float) -> Vector3i:
	var sh: Vector2i = grid_shape(face, R)
	if sh == Vector2i.ZERO:
		return Vector3i.ZERO
	if i < 0 or i > sh.x or j < 0 or j > sh.y:
		return Vector3i.ZERO
	var n: int = sh.y if (face >= 4 and face <= 7) else sh.x
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


# Global-frame position of a chart vertex at radial height h above the surface
# (h in metres; R + h must stay positive). Every incident chart uses the same
# canonical evaluation, so one (key, h) yields bit-identical coordinates on
# every chart that contains the vertex. Invalid input returns the
# (INF, INF, INF) sentinel.
static func vertex_to_world(face: int, i: int, j: int, h: float, R: float) -> Vector3:
	var q: Vector3i = vertex_key(face, i, j, R)
	if q == Vector3i.ZERO or not is_finite(h) or R + h <= 0.0:
		return INVALID_POINT
	var sh: Vector2i = grid_shape(face, R)
	var n: int = sh.y if (face >= 4 and face <= 7) else sh.x
	return _canonical_point(q, n, R, h)


# Global-frame position of a point inside cell (i, j, k) at local fractional
# offset (fraction_i, fraction_height, fraction_j) — one-metre radial heights,
# h = k + local.y (k may be negative, there is no artificial legacy height
# limit). Cell domain is half-open: 0 <= i < Nu, 0 <= j < Nv; every local
# component must be finite and in [0, 1]. When gx = i + local.x and
# gz = j + local.z are BOTH exact integers the shared cell corner is evaluated
# through vertex_to_world, so corners of adjacent cells agree bitwise;
# otherwise the direct chart mapping is used. Chart-index order — no mirror /
# local-X reversal (the mesher winding adapter is a later stage). Invalid
# input returns the (INF, INF, INF) sentinel.
static func cell_to_world(face: int, i: int, j: int, k: int, local: Vector3, R: float) -> Vector3:
	var sh: Vector2i = grid_shape(face, R)
	if sh == Vector2i.ZERO or not _valid_local(local):
		return INVALID_POINT
	if i < 0 or i >= sh.x or j < 0 or j >= sh.y:
		return INVALID_POINT
	var h: float = float(k) + local.y
	if R + h <= 0.0:
		return INVALID_POINT
	var gx: float = float(i) + local.x
	var gz: float = float(j) + local.z
	if gx == floorf(gx) and gz == floorf(gz):
		return vertex_to_world(face, int(gx), int(gz), h, R)
	var n: Vector3 = SM.uv_to_world(face, gx / float(sh.x), gz / float(sh.y), R).normalized()
	return (R + h) * n - Vector3(0.0, R, 0.0)


# Inverse of the cell/vertex embedding for a global-frame position. Adds the
# origin shift (0, R, 0) to get the planet-centred point, h = length - R,
# ownership = the shipped SM.world_to_face tie order, then u*Nu / v*Nv floored
# for cell ownership (clamped for roundoff; at the owned upper boundary
# i = Nu-1, local.x = 1 is intentional, not a wrap). k = floor(h) (negative
# below the surface). Returns {valid: false} for non-finite input, an
# invalid radius, or a planet-centred length <= 1e-6; otherwise
# {valid: true, face, i, j, k, local: Vector3}.
static func world_to_cell(pos: Vector3, R: float) -> Dictionary:
	if not is_finite(pos.x) or not is_finite(pos.y) or not is_finite(pos.z) \
			or not _valid_R(R):
		return {"valid": false}
	var pc: Vector3 = pos + Vector3(0.0, R, 0.0)
	if pc.length() <= 1e-6:
		return {"valid": false}
	var h: float = pc.length() - R
	var wf: Dictionary = SM.world_to_face(pc, R)
	var face: int = int(wf["face"])
	var sh: Vector2i = grid_shape(face, R)
	if sh == Vector2i.ZERO:
		return {"valid": false}
	var u: float = clampf(float(wf["u"]), 0.0, 1.0)
	var v: float = clampf(float(wf["v"]), 0.0, 1.0)
	var gx: float = u * float(sh.x)
	var gz: float = v * float(sh.y)
	var i: int = clampi(int(floorf(gx)), 0, sh.x - 1)
	var j: int = clampi(int(floorf(gz)), 0, sh.y - 1)
	var k: int = int(floorf(h))
	var local: Vector3 = Vector3(gx - float(i), h - float(k), gz - float(j))
	return {"valid": true, "face": face, "i": i, "j": j, "k": k, "local": local}


# Intra-planet cell identity "%d:%d:%d:%d" (face, i, j, k) for valid cell
# indices and radius; "" otherwise. This DEFINES cell identity for the
# canonical grid only — it is NOT an activated save format and does not
# replace the runtime keys (planet ID, storage and chunk-key versioning are
# later persistence stages).
static func address_key(face: int, i: int, j: int, k: int, R: float) -> String:
	var sh: Vector2i = grid_shape(face, R)
	if sh == Vector2i.ZERO or i < 0 or i >= sh.x or j < 0 or j >= sh.y:
		return ""
	return "%d:%d:%d:%d" % [face, i, j, k]


# Canonical cube-lattice cell identity of chart cell (i, j): every chart cell
# covers exactly one unit square of the cube lattice (each face maps its cell
# index to a lattice corner by an integer offset only), so one face-independent
# (plane, sign, a, b) addresses every cell on every chart, at one size.
# plane = the even face id of the cube plane (0, 2, 4, 6, 8, 10); sign = +1
# for an even face, -1 for an odd one; a, b = the in-plane lattice cell
# indices, always in [-N, N). Half-open cell domain from grid_shape; invalid
# face/radius/indices return {ok: false}.
static func cell_lattice(face: int, i: int, j: int, R: float) -> Dictionary:
	var sh: Vector2i = grid_shape(face, R)
	if sh == Vector2i.ZERO:
		return {"ok": false}
	if i < 0 or i >= sh.x or j < 0 or j >= sh.y:
		return {"ok": false}
	var n: int = sh.y if (face >= 4 and face <= 7) else sh.x
	var a: int
	var b: int
	match face:
		0, 2, 8, 10:
			a = i
			b = j - n
		1, 3, 9, 11:
			a = i - n
			b = j - n
		4, 6:
			a = i - n
			b = j
		5, 7:
			a = i - n
			b = j - n
		_:
			return {"ok": false}
	var plane: int = face - face % 2
	var sgn: int = 1 if face % 2 == 0 else -1
	return {"ok": true, "plane": plane, "sign": sgn, "a": a, "b": b}


# Exact inverse of cell_lattice: the chart cell covering the unit square with
# in-plane lattice indices (a, b) on cube plane `plane`. Valid domain: plane
# in {0, 2, 4, 6, 8, 10}, sign +1/-1, a and b in [-N, N); anything else
# returns {ok: false}.
static func cell_owner(plane: int, sign: int, a: int, b: int, R: float) -> Dictionary:
	var sh: Vector2i = grid_shape(0, R)
	if sh == Vector2i.ZERO:
		return {"ok": false}
	var n: int = sh.x
	if plane < 0 or plane > 10 or plane % 2 != 0:
		return {"ok": false}
	if sign != 1 and sign != -1:
		return {"ok": false}
	if a < -n or a >= n or b < -n or b >= n:
		return {"ok": false}
	var face: int = plane + (0 if sign > 0 else 1)
	if plane == 4 or plane == 6:
		return {"ok": true, "face": face, "i": a + n, "j": b + (n if sign < 0 else 0)}
	return {"ok": true, "face": face, "i": a + (n if sign < 0 else 0), "j": b + n}


# --- internals (stateless; the canonical vertex evaluation is the single
#     floating computation behind every shared-vertex placement) ---

static func _valid_face(face: int) -> bool:
	return face >= 0 and face <= 11


static func _valid_R(R: float) -> bool:
	return is_finite(R) and R > 0.0


static func _valid_local(local: Vector3) -> bool:
	return is_finite(local.x) and local.x >= 0.0 and local.x <= 1.0 \
			and is_finite(local.y) and local.y >= 0.0 and local.y <= 1.0 \
			and is_finite(local.z) and local.z >= 0.0 and local.z <= 1.0


static func _canonical_point(q: Vector3i, n: int, R: float, h: float) -> Vector3:
	# Owning chart = the shipped face_for_dir tie order on the RAW integer Q,
	# then the chart inverse formulas (sphere_math.gd:129-144) on C = Q/N.
	# Deliberately NOT SM.world_to_face(Q): Q is unwarped cube-lattice
	# coordinates, and the inverse on C reproduces the shipped (u,v) exactly.
	var nf: float = float(n)
	var cx: float = float(q.x) / nf
	var cy: float = float(q.y) / nf
	var cz: float = float(q.z) / nf
	var owner: int = SM.face_for_dir(Vector3(float(q.x), float(q.y), float(q.z)))
	var u: float
	var v: float
	match owner:
		0, 2, 8, 10: u = cx
		1, 3, 9, 11: u = cx + 1.0
		_: u = (cy + 1.0) * 0.5
	match owner:
		0, 1, 2, 3: v = (cz + 1.0) * 0.5
		4, 6: v = cz
		5, 7: v = cz + 1.0
		_: v = (cy + 1.0) * 0.5
	var n_dir: Vector3 = SM.uv_to_world(owner, u, v, R).normalized()
	return (R + h) * n_dir - Vector3(0.0, R, 0.0)
