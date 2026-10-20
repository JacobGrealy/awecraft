# AC-0433 P2c-2 probe - chunk_key / chunk_from_key: T1 round trip, T2
# uniqueness + stability, T3 the strict reject table, T4 near-miss control.
# Standalone SceneTree; one RESULT line; exit 1 on any failure.
# Run (repo root, one godot at a time):
#   pgrep -af '[g]odot'; export HOME=/tmp/dsh_home; mkdir -p $HOME; \
#   ulimit -v 8388608; timeout 120 /home/angrygiant/tools/godot/godot \
#   --headless --path godot --script <abs>/tasks/AC-0433/p2c2_probe.gd
extends SceneTree

const GRID := preload("res://core/planet_grid.gd")
const R: float = 4072.0
const R_FRESH: float = 4072.0

func _init() -> void:
	var keys := 0
	var rt_failures := 0
	var duplicates := 0
	var stable := true
	var reject_cases := 0
	var reject_failures := 0
	var near := false
	var seen := {}
	var last_key := ""
	var last_chunk: Array = [-1, -1, -1]
	for f in 12:
		var sh: Vector2i = GRID.grid_shape(int(f), R)
		if sh == Vector2i.ZERO:
			rt_failures += 1
			continue
		var nx: int = sh.x / GRID.CHUNK_WIDTH
		var nz: int = sh.y / GRID.CHUNK_WIDTH
		var xs: Array = [0, 1, nx - 1]
		var zs: Array = [0, 1, nz - 1]
		for cx in xs:
			for cz in zs:
				var fi: int = int(f)
				var cx_i: int = int(cx)
				var cz_i: int = int(cz)
				var k: String = GRID.chunk_key(fi, cx_i, cz_i, R)
				keys += 1
				last_key = k
				last_chunk = [fi, cx_i, cz_i]
				if seen.has(k):
					duplicates += 1
				seen[k] = true
				if GRID.chunk_key(fi, cx_i, cz_i, R) != k:
					stable = false
				if GRID.chunk_key(fi, cx_i, cz_i, R_FRESH) != k:
					stable = false
				var p: Dictionary = GRID.chunk_from_key(k, R)
				if not p.get("ok", false) or int(p["face"]) != fi \
						or int(p["cx"]) != cx_i or int(p["cz"]) != cz_i:
					rt_failures += 1
	var rejects: Array = ["", "1", "1:2", "1:2:3:4", "a:b:c", "1::3", ":2:3",
			"1:2:", " 1:2:3", "1 :2:3", "+1:2:3", "-1:2:3", "1.0:2:3",
			"01:2:3", "1:02:3", "1:2:03", "12:0:0", "1:-2:3", "1:2:999999",
			"0x1:2:3"]
	for bad in rejects:
		reject_cases += 1
		if GRID.chunk_from_key(bad, R).get("ok", false):
			reject_failures += 1
	# T4: delete one character of one valid key; it must NOT still parse to
	# the same chunk (a reject or a different chunk both count).
	var nm: String = last_key.left(last_key.length() - 1)
	var q: Dictionary = GRID.chunk_from_key(nm, R)
	if not q.get("ok", false):
		near = true
	else:
		near = int(q["face"]) != int(last_chunk[0]) \
				or int(q["cx"]) != int(last_chunk[1]) \
				or int(q["cz"]) != int(last_chunk[2])
	var fails: int = rt_failures + duplicates + reject_failures
	if not stable:
		fails += 1
	if not near:
		fails += 1
	print("RESULT ok=%s keys=%d round_trip_failures=%d duplicates=%d stable=%s reject_cases=%d reject_failures=%d near_miss_detected=%s fails=%d"
			% [str(fails == 0), keys, rt_failures, duplicates, str(stable),
			reject_cases, reject_failures, str(near), fails])
	quit(0 if fails == 0 else 1)
