# AC-0433 P2b-1 — standalone probe: canonical cell identity + exact inverse.
# T1: cell_lattice -> cell_owner returns the identical (face, i, j) and back
#     the identical (plane, sign, a, b); no two cells share an identity
#     (plan §3.3). T2: the four cell corners rebuilt from the identity match
#     vertex_key exactly, with Q10-Q00 and Q01-Q00 single unit axis steps.
#     Negative control: b + 1 on one fixed cell must break T2, so a green run
#     cannot be vacuous. One RESULT line; any failed expectation exits 1.
# Run (repo root, no other godot process running):
#   HOME=/tmp/dsh_home ~/tools/godot/godot --headless --path godot \
#     --script tasks/AC-0433/p2b_probe.gd
extends SceneTree

const R: float = 4000.0 # live planet radius (P1: N = 3152, full axis 6304)
const GRID = preload("res://core/planet_grid.gd")

func _initialize() -> void:
	var rt: int = 0
	var coll: int = 0
	var cm: int = 0
	var cells: int = 0
	var neg: bool = false
	var seen: Dictionary = {}
	for face in range(12):
		var sh: Vector2i = GRID.grid_shape(face, R)
		var isamps: Array = _samples(sh.x)
		var jsamps: Array = _samples(sh.y)
		for i in isamps:
			for j in jsamps:
				cells += 1
				var idl: Dictionary = GRID.cell_lattice(face, i, j, R)
				if not idl.get("ok", false):
					rt += 1
					continue
				var ow: Dictionary = GRID.cell_owner(idl.plane, idl.sign, idl.a, idl.b, R)
				if not ow.get("ok", false) or ow.face != face or ow.i != i or ow.j != j:
					rt += 1
				var back: Dictionary = {}
				if ow.get("ok", false):
					back = GRID.cell_lattice(ow.face, ow.i, ow.j, R)
				var back_same: bool = back.get("ok", false) and back.plane == idl.plane \
						and back.sign == idl.sign and back.a == idl.a and back.b == idl.b
				if not back_same:
					rt += 1
				var key: String = "%d:%d:%d:%d" % [idl.plane, idl.sign, idl.a, idl.b]
				if seen.has(key):
					coll += 1
				seen[key] = true
				var q00: Vector3i = GRID.vertex_key(face, i, j, R)
				var q10: Vector3i = GRID.vertex_key(face, i + 1, j, R)
				var q01: Vector3i = GRID.vertex_key(face, i, j + 1, R)
				var q11: Vector3i = GRID.vertex_key(face, i + 1, j + 1, R)
				var r00: Vector3i = _corner(idl.plane, idl.a, idl.b)
				var r10: Vector3i = _corner(idl.plane, idl.a + 1, idl.b)
				var r01: Vector3i = _corner(idl.plane, idl.a, idl.b + 1)
				var r11: Vector3i = _corner(idl.plane, idl.a + 1, idl.b + 1)
				if r00 != q00 or r10 != q10 or r01 != q01 or r11 != q11:
					cm += 1
				if not _unit_step(q10 - q00) or not _unit_step(q01 - q00):
					cm += 1
	# Negative control (plan §3.3): corrupt one identity (b + 1, fixed cell
	# face 2 / i 1 / j 1); T2's corner equality must then fail on it.
	var nid: Dictionary = GRID.cell_lattice(2, 1, 1, R)
	var nq: Vector3i = GRID.vertex_key(2, 1, 1, R)
	neg = bool(nid.get("ok", false)) and _corner(nid.plane, nid.a, nid.b + 1) != nq
	var fails: int = rt + coll + cm + (0 if neg else 1)
	var ok: bool = fails == 0
	print("RESULT " + JSON.stringify({
			"ok": ok, "cells": cells, "round_trip_mismatches": rt,
			"identity_collisions": coll, "corner_mismatches": cm,
			"negative_detected": neg, "fails": fails}))
	quit(0 if ok else 1)

# Sample set of plan §3.3: {0, 1, 15, half, nu-2, nu-1}, clamped to the
# face's half-open cell domain and de-duplicated.
func _samples(nu: int) -> Array:
	var out: Array = []
	for v in [0, 1, 15, nu / 2, nu - 2, nu - 1]:
		var c: int = clampi(v, 0, nu - 1)
		if not out.has(c):
			out.append(c)
	return out

# T2 plane table (plan §3.3): the plane's normal axis carries the plane's own
# sign times N (0 = +Y, 2 = -Y, 4 = +X, 6 = -X, 8 = +Z, 10 = -Z); the two
# in-plane axes carry a, b in the order vertex_key fixes.
func _corner(plane: int, a: int, b: int) -> Vector3i:
	var n: int = GRID.grid_shape(0, R).x
	match plane:
		0: return Vector3i(a, n, b)
		2: return Vector3i(a, -n, b)
		4: return Vector3i(n, a, b)
		6: return Vector3i(-n, a, b)
		8: return Vector3i(a, b, n)
		_: return Vector3i(a, b, -n)

func _unit_step(d: Vector3i) -> bool:
	return abs(d.x) + abs(d.y) + abs(d.z) == 1
