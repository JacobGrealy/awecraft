# AC-0433 P2c-1 probe: chunk addressing + chunk-level adjacency (plan §3.3).
# Standalone: godot --headless --path godot --script tasks/AC-0433/p2c1_probe.gd
# One RESULT line; exit 1 on any failure.
extends SceneTree

const GRID := preload("res://core/planet_grid.gd")
const R: float = 4000.0
const BAD: Vector2i = Vector2i(-1, -1)

var neg_face: int = -1
var neg_cx: int = -1
var neg_cz: int = -1
var neg_dir: int = -1
var neg_o: Vector2i = Vector2i(-1, -1)
var neg_far: int = -1


func _init() -> void:
	var exactness_failures: int = 0
	var chunks_checked: int = 0
	var crossing_cells: int = 0
	var straddle_failures: int = 0
	var pairs: int = 0
	var reciprocal: int = 0
	var invalid_cases: int = 0
	var invalid_failures: int = 0
	var negative_detected: bool = false
	var neg_found: bool = false
	var sh0: Vector2i = GRID.grid_shape(0, R)
	# T1: grid_shape divisible by 16 both axes; chunk round-trip on sampled chunks.
	for face in 12:
		var sh: Vector2i = GRID.grid_shape(face, R)
		if sh == Vector2i.ZERO or sh.x % GRID.CHUNK_WIDTH != 0 or sh.y % GRID.CHUNK_WIDTH != 0:
			exactness_failures += 1
			continue
		var lastx: int = sh.x / GRID.CHUNK_WIDTH - 1
		var lasty: int = sh.y / GRID.CHUNK_WIDTH - 1
		for x in [0, 1, lastx - 1, lastx]:
			for y in [0, 1, lasty - 1, lasty]:
				if x < 0 or x > lastx or y < 0 or y > lasty:
					continue
				var o2: Vector2i = GRID.chunk_cell_origin(face, x, y, R)
				var back: Vector2i = GRID.chunk_of(face, o2.x, o2.y, R)
				chunks_checked += 1
				if back != Vector2i(x, y):
					exactness_failures += 1
	# T2: every sampled chunk x dir - all 16 crossing cells land in the returned chunk.
	for face in 12:
		var sh: Vector2i = GRID.grid_shape(face, R)
		var lastx: int = sh.x / GRID.CHUNK_WIDTH - 1
		var lasty: int = sh.y / GRID.CHUNK_WIDTH - 1
		for x in [0, 1, lastx - 1, lastx]:
			for y in [0, 1, lasty - 1, lasty]:
				if x < 0 or x > lastx or y < 0 or y > lasty:
					continue
				var o2: Vector2i = GRID.chunk_cell_origin(face, x, y, R)
				for dir in 4:
					var nb: Dictionary = GRID.chunk_neighbour(face, x, y, dir, R)
					chunks_checked += 1
					if not nb.get("ok", false):
						straddle_failures += 1
						continue
					pairs += 1
					var want: Vector2i = Vector2i(int(nb["cx"]), int(nb["cz"]))
					neg_face = int(nb["face"])
					for k in GRID.CHUNK_WIDTH:
						var i: int
						var j: int
						if dir == 0 or dir == 1:
							i = o2.x + (GRID.CHUNK_WIDTH - 1 if dir == 1 else 0)
							j = o2.y + k
						else:
							i = o2.x + k
							j = o2.y + (GRID.CHUNK_WIDTH - 1 if dir == 3 else 0)
						var cnb: Dictionary = GRID.cell_neighbour(face, i, j, dir, R)
						var c: Vector2i = BAD
						if cnb.get("ok", false):
							c = GRID.chunk_of(int(cnb["face"]), int(cnb["i"]), int(cnb["j"]), R)
						crossing_cells += 1
						if c == BAD or c != want or int(cnb.get("face", -1)) != int(nb["face"]):
							straddle_failures += 1
						if not neg_found:
							neg_found = true
							neg_face = face
							neg_far = int(nb["face"])
							neg_cx = x
							neg_cz = y
							neg_dir = dir
							neg_o = o2
					# T3: reciprocity - SOME dir on the far chunk returns the source (search all four).
					var hit: bool = false
					for d2 in 4:
						var rb: Dictionary = GRID.chunk_neighbour(int(nb["face"]), int(nb["cx"]), int(nb["cz"]), d2, R)
						if rb.get("ok", false) and int(rb["face"]) == face \
								and int(rb["cx"]) == x and int(rb["cz"]) == y:
							hit = true
					if hit:
						reciprocal += 1
	# Negative control: same crossing cells, target shifted by cz+1 -> check must fail.
	if neg_found:
		var bad_target: Vector2i = Vector2i(neg_cx, neg_cz + 1)
		var m: int = 0
		for k in GRID.CHUNK_WIDTH:
			var i: int
			var j: int
			if neg_dir == 0 or neg_dir == 1:
				i = neg_o.x + (GRID.CHUNK_WIDTH - 1 if neg_dir == 1 else 0)
				j = neg_o.y + k
			else:
				i = neg_o.x + k
				j = neg_o.y + (GRID.CHUNK_WIDTH - 1 if neg_dir == 3 else 0)
			var cnb: Dictionary = GRID.cell_neighbour(neg_face, i, j, neg_dir, R)
			var c: Vector2i = BAD
			if cnb.get("ok", false):
				c = GRID.chunk_of(int(cnb["face"]), int(cnb["i"]), int(cnb["j"]), R)
			if c != bad_target or int(cnb.get("face", -1)) != neg_far:
				m += 1
		negative_detected = m > 0
	# T4: documented sentinels, no SCRIPT ERROR.
	var f: int = 0
	var cx: int = 0
	var cz: int = 0
	invalid_cases += 1
	if GRID.chunk_of(-1, 0, 0, R) != BAD: invalid_failures += 1
	invalid_cases += 1
	if GRID.chunk_of(12, 0, 0, R) != BAD: invalid_failures += 1
	invalid_cases += 1
	if GRID.chunk_of(f, 0, 0, 0.0) != BAD: invalid_failures += 1
	invalid_cases += 1
	if GRID.chunk_of(f, 0, 0, -1.0) != BAD: invalid_failures += 1
	invalid_cases += 1
	if GRID.chunk_of(f, 0, 0, INF) != BAD: invalid_failures += 1
	invalid_cases += 1
	if GRID.chunk_cell_origin(-1, cx, cz, R) != BAD: invalid_failures += 1
	invalid_cases += 1
	if GRID.chunk_cell_origin(12, cx, cz, R) != BAD: invalid_failures += 1
	invalid_cases += 1
	if GRID.chunk_cell_origin(f, cx, cz, 0.0) != BAD: invalid_failures += 1
	invalid_cases += 1
	if GRID.chunk_cell_origin(f, cx, cz, -1.0) != BAD: invalid_failures += 1
	invalid_cases += 1
	if GRID.chunk_cell_origin(f, cx, cz, INF) != BAD: invalid_failures += 1
	invalid_cases += 1
	if GRID.chunk_cell_origin(f, -1, cz, R) != BAD: invalid_failures += 1
	invalid_cases += 1
	if GRID.chunk_cell_origin(f, cx, -1, R) != BAD: invalid_failures += 1
	var maxx: int = sh0.x / GRID.CHUNK_WIDTH
	var maxy: int = sh0.y / GRID.CHUNK_WIDTH
	invalid_cases += 1
	if GRID.chunk_cell_origin(f, maxx, cz, R) != BAD: invalid_failures += 1
	invalid_cases += 1
	if GRID.chunk_cell_origin(f, cx, maxy, R) != BAD: invalid_failures += 1
	invalid_cases += 1
	var nd: Dictionary = GRID.chunk_neighbour(f, cx, cz, -1, R)
	if nd.get("ok", false) or nd.size() != 1: invalid_failures += 1
	invalid_cases += 1
	nd = GRID.chunk_neighbour(f, cx, cz, 4, R)
	if nd.get("ok", false) or nd.size() != 1: invalid_failures += 1
	invalid_cases += 1
	nd = GRID.chunk_neighbour(-1, cx, cz, 0, R)
	if nd.get("ok", false) or nd.size() != 1: invalid_failures += 1
	invalid_cases += 1
	nd = GRID.chunk_neighbour(12, cx, cz, 0, R)
	if nd.get("ok", false) or nd.size() != 1: invalid_failures += 1
	invalid_cases += 1
	nd = GRID.chunk_neighbour(f, cx, cz, 0, 0.0)
	if nd.get("ok", false) or nd.size() != 1: invalid_failures += 1
	invalid_cases += 1
	nd = GRID.chunk_neighbour(f, cx, cz, 0, INF)
	if nd.get("ok", false) or nd.size() != 1: invalid_failures += 1
	invalid_cases += 1
	nd = GRID.chunk_neighbour(f, maxx, cz, 0, R)
	if nd.get("ok", false) or nd.size() != 1: invalid_failures += 1
	var fails: int = 0
	if exactness_failures > 0: fails += 1
	if straddle_failures > 0: fails += 1
	if reciprocal != pairs: fails += 1
	if invalid_failures > 0: fails += 1
	if not negative_detected: fails += 1
	var ok: bool = fails == 0
	var res: Dictionary = {
		"ok": ok, "faces": 12, "exactness_failures": exactness_failures,
		"chunks_checked": chunks_checked, "crossing_cells": crossing_cells,
		"straddle_failures": straddle_failures, "pairs": pairs,
		"reciprocal": reciprocal, "invalid_cases": invalid_cases,
		"invalid_failures": invalid_failures, "negative_detected": negative_detected,
		"fails": fails,
	}
	print("RESULT " + JSON.stringify(res))
	quit(1 if fails > 0 else 0)
