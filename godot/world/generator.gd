class_name WorldGen

const B_GRASS := 1
const B_DIRT := 2
const B_STONE := 3
const B_SAND := 4
const B_WATER := 5
const B_LOG := 6
const B_LEAVES := 7
const B_BEDROCK := 11
const B_SNOW_GRASS := 12
const B_COAL_ORE := 14
const B_IRON_ORE := 15
const B_DIAMOND_ORE := 16
const B_ROSE := 18
const B_DANDELION := 19
const B_LAVA := 24
const B_OBSIDIAN := 25
# AC-0040: the hanging banana fruit (block 28 — pre-wired as a light-passing
# cross block in lighting.gd + a reserved atlas tile in blocks_atlas.json).
const B_BANANA := 28

const TREE_D_FOREST := 0.14
const TREE_D_PLAIN := 0.02
const TREE_D_MAX := 0.14
# AC-0040: banana-tree density — MUCH lower than the forest tree pass
# (0.025 << 0.14): a rare shore edge, not a biome forest.
const TREE_D_BANANA := 0.025
# AC-0040: dedicated hash salt for the banana roll (independent of the C++
# tree pass's seed+55 gate and the seed+66 trunk-height roll it reuses).
const BANANA_SALT := 919
# AC-0040: sea level = Data.SEA (126, AC-0091) — hard-mirrored here like the
# B_* ids above (generator consts must not reference the Data autoload).
const B_SEA := 126

const SPAWN_X := 8
const SPAWN_Z := 8
# AC-0091: SPAWN_H 34 -> 136 = int(2.6 * 34 + 48) under the remap below
# (spawn pad sits at MC Y=72, in the grassland band MC 62-100).
const SPAWN_H := 136
# AC-0091: terrain ceiling. The remapped formula peaks ~346 before clamping;
# clamp at 300 (MC Y=236) so mountains top out well below the sky limit 319.
const TERRAIN_H_MAX := 300


# AC-0188: C++ generation (gdext/src/gen.cpp — the coarse 4x8x4 3D density,
# the AC-0198 approach ported natively on the AC-0165 pipeline). Same
# AweNoise hash/fade/lerp (bit-for-byte — AWECRAFT_LOGIC=genprobe), a NEW
# terrain (the AC-0188 genhash baseline — accepted). AC-0208: the C++
# extension is REQUIRED — the AWECRAFT_GENCPP kill switch and the GDScript
# generate_args fallback were removed; AweGen is the only gen path
# (Game._ready fails fast if the library is missing).
static var _gen_cpp: Variant = null
static var _gen_cpp_done := false

static func gen_cpp() -> Variant:
	if not _gen_cpp_done:
		_gen_cpp_done = true
		if ClassDB.class_exists("AweGen"):
			_gen_cpp = ClassDB.instantiate("AweGen")
		else:
			push_error("AWECRAFT: AweGen C++ class not registered — the gdext library is missing (AC-0208: the C++ extension is REQUIRED, no GDScript gen fallback).")
	return _gen_cpp


# AC-0091 exact remap (documented in tasks/AC-0091/spec.html + results.html):
#   old (H=80):  y = 22 + c*14 + h*20; if r>0.62: y += (r-0.62)*150; clamp [3,74]
#   new (H=384): y = 105.2 + c*36.4 + h*52.0; if r>0.62: y += (r-0.62)*390; clamp [3,300]
# i.e. y_new = int(2.6 * y_old_raw + 48) — the same affine applied to the raw
# (pre-clamp) formula, so every noise sample keeps its relative rank: ocean
# (y_old < 30) maps EXACTLY to y_new < 126 = Data.SEA. Grassland (old 22-56)
# -> new 105-193 (MC 41-129, core band MC 62-100); mountains (r-boost) reach
# new ~300 (MC ~236, the "200+" band). Same fbm calls, same thresholds.
static func terrain_height(x: int, z: int, seed: int) -> int:
	var c := AweNoise.fbm2(float(x) / 220.0, float(z) / 220.0, seed, 3)
	var h := AweNoise.fbm2(float(x) / 70.0 + 333.0, float(z) / 70.0 + 333.0, seed + 7, 4)
	var r := AweNoise.fbm2(float(x) / 300.0 + 500.0, float(z) / 300.0 + 500.0, seed + 13, 3)
	var y := 105.2 + c * 36.4 + h * 52.0
	if r > 0.62:
		y += (r - 0.62) * 390.0
	var d := Vector2(float(x) - float(SPAWN_X), float(z) - float(SPAWN_Z)).length()
	if d <= 6.0:
		y = float(SPAWN_H)
	elif d <= 10.0:
		var w := 1.0 - smoothstep(6.0, 10.0, d)
		y = y * (1.0 - w) + float(SPAWN_H) * w
	return clampi(int(floorf(y)), 3, TERRAIN_H_MAX)


static func biome_at(x: int, z: int, seed: int) -> String:
	var t := AweNoise.fbm2(float(x) / 260.0 + 900.0, float(z) / 260.0 + 900.0, seed + 21, 3) * 2.0 - 1.0
	var m := AweNoise.fbm2(float(x) / 260.0 + 1700.0, float(z) / 260.0 + 1700.0, seed + 33, 3) * 2.0 - 1.0
	if t < -0.25:
		return "snow"
	if t > 0.35 and m < 0.1:
		return "desert"
	if m > 0.25:
		return "forest"
	return "plains"


# The harness flora reference (main.gd _trees_ref_flora) places trees by
# hand — the cell write helper stays (AC-0208: the GDScript gen body that
# used this was removed, but the probe arm is still a direct caller).
static func _putc(data: PackedByteArray, wx: int, wy: int, wz: int, bid: int, bx: int, bz: int, hmax: int) -> void:
	var lx := wx - bx
	var lz := wz - bz
	if lx < 0 or lx > 15 or lz < 0 or lz > 15 or wy < 1 or wy >= hmax:
		return
	var i := (wy << 8) | (lz << 4) | lx
	if data[i] == 0:
		data[i] = bid


static func generate(cx: int, cz: int, seed: int) -> PackedByteArray:
	# AC-0091: height/sea come from Data (was hard-coded 80/30).
	return generate_args(cx, cz, seed, Data.HEIGHT, Data.SEA)

static func generate_args(cx: int, cz: int, seed: int, hmax: int, sea: int) -> PackedByteArray:
	# AC-0188: C++ path (coarse 3D density) — every GDScript caller (genhash,
	# spawn sync column, face gen, probes) runs the C++ terrain; workers use
	# gen_cpp().generate_resl directly (slab form). AC-0208: C++-ONLY — the
	# GDScript fallback body (and its _ytable/_fbm3col/_vnoise3col/SOLID_IDS
	# helper cluster) was REMOVED; AweGen.generate_flat is the only terrain
	# generator (the C++ extension is required). _putc survives for the
	# harness flora reference (main.gd _trees_ref_flora).
	return gen_cpp().generate_flat(cx, cz, seed, hmax, sea)


static func _fbm2chunk(bx: int, sx: float, ox: float, bz: int, sz: float, oz: float, s: int, oct: int, acc: PackedFloat64Array) -> void:
	var u := PackedFloat64Array()
	u.resize(16)
	var v := PackedFloat64Array()
	v.resize(16)
	var xi := PackedInt32Array()
	xi.resize(16)
	var zi := PackedInt32Array()
	zi.resize(16)
	var grid := PackedFloat64Array()
	grid.resize(20)
	var amp := 1.0
	var f := 1.0
	var tot := 0.0
	var oi := 0
	while oi < oct:
		var ss := s + oi * 101
		var ximin := 1073741824
		var ximax := -1073741824
		var l2 := 0
		while l2 < 16:
			var xf := (float(bx + l2) / sx + ox) * f
			var xi2 := int(floorf(xf))
			if xi2 < ximin:
				ximin = xi2
			if xi2 > ximax:
				ximax = xi2
			xi[l2] = xi2
			u[l2] = AweNoise._fade(xf - float(xi2))
			l2 += 1
		var zimin := 1073741824
		var zimax := -1073741824
		l2 = 0
		while l2 < 16:
			var zf := (float(bz + l2) / sz + oz) * f
			var zi2 := int(floorf(zf))
			if zi2 < zimin:
				zimin = zi2
			if zi2 > zimax:
				zimax = zi2
			zi[l2] = zi2
			v[l2] = AweNoise._fade(zf - float(zi2))
			l2 += 1
		var gx := ximax - ximin + 2
		var gz := zimax - zimin + 2
		var ga := 0
		while ga < gx:
			var gb := 0
			while gb < gz:
				grid[ga + gb * gx] = AweNoise.hash2i(ximin + ga, zimin + gb, ss)
				gb += 1
			ga += 1
		var lz2 := 0
		while lz2 < 16:
			var vz := zi[lz2] - zimin
			var lv := v[lz2]
			var lx2 := 0
			while lx2 < 16:
				var vx := xi[lx2] - ximin
				var uu := u[lx2]
				var g0 := grid[vx + vz * gx]
				var g1 := grid[vx + 1 + vz * gx]
				var g2 := grid[vx + (vz + 1) * gx]
				var g3 := grid[vx + 1 + (vz + 1) * gx]
				var pv := lerpf(g0, g1, uu)
				var qw := lerpf(g2, g3, uu)
				acc[lz2 * 16 + lx2] += lerpf(pv, qw, lv) * amp
				lx2 += 1
			lz2 += 1
		tot += amp
		amp *= 0.5
		f *= 2.0
		oi += 1
	var j := 0
	while j < 256:
		acc[j] = acc[j] / tot
		j += 1

# AC-0143 M4: per-face column generation (non-home faces only — face 0
# always uses generate(); home-face byte-identity). 2D per-face noise
# (P1a; 3D sphere noise = later upgrade): reuses the home-column pipeline
# (generate_args) with a per-face salt seed ^ (face*1000003) and a
# face-disjoint 2D domain (offset face*64 chunks = 1024 face cells).
# No cross-face continuity in P1a (face-border terrain seams acceptable,
# documented). Deterministic per (face, cx, cz, seed).
static func generate_face(face: int, cx: int, cz: int, seed: int) -> PackedByteArray:
	var fsalt: int = seed ^ (face * 1000003)
	return generate_args(face * 64 + cx, face * 64 + cz, fsalt, Data.HEIGHT, Data.SEA)


# ---------------------------------------------------------------------------
# AC-0040 bouncy-banana — the GDScript banana-tree pass (generator.gd).
#
# Spawns banana trees ONLY at the dirt<->sand transition surrounding water
# (the shore dirt edge), never in inland forest/jungle:
#   * base column top is B_DIRT/B_GRASS at y in [SEA+1, SEA+4] (the first
#     land columns inland from the beach — beach tops at SEA..SEA+1 are
#     sand by the gen's beach rule, so they can never be a base);
#   * a B_SAND cell in the shore band [SEA-8, SEA+4] within Chebyshev 3
#     (xz, in-chunk);
#   * water (a water column — its topmost cell is B_WATER at SEA) within
#     Chebyshev 4 (xz, in-chunk);
#   * the base column's biome is NOT "forest" (same biome_at the C++ tree
#     pass uses — "not forest/jungle");
#   * deterministic low-density roll: hash2i(wx, wz, seed+919) < 0.025.
# Tree shape = the C++ tree pass's exact shape (trunk B_LOG 4-6 tall,
# B_LEAVES canopy, same seed+66 height roll) + 2 hanging B_BANANA fruit
# cells in the canopy (written into empty cells only).
#
# The pass is a POST-PROCESS on generated chunk data — WorldGen.generate()
# itself is untouched, so the genhash arm (AC-0215 NEW baseline) and every
# probe that calls generate() directly are byte-unaffected. Callers:
# world.gd's five world-building landing sites (the real world only).
# In-chunk-only neighbor checks: a shore crossing a chunk border may miss a
# base in the two edge columns (documented density artifact, correctness
# preserved — every planted tree has in-chunk shore evidence).
# ---------------------------------------------------------------------------

const BANANA_BASE_LO := B_SEA + 1  # 127 — first non-beach top (beach = sand)
const BANANA_BASE_HI := B_SEA + 4  # 130 — the transition band above the beach
const BANANA_SAND_R := 3           # sand within 3 (Chebyshev xz)
const BANANA_SAND_YLO := B_SEA - 8  # 118 — shore band lower
const BANANA_SAND_YHI := B_SEA + 4  # 130 — shore band upper
const BANANA_WATER_R := 4          # water within 4 (Chebyshev xz)


static func _banana_col_scan(data: PackedByteArray, hmax: int) -> Array:
	# Per-column shore summary over the flat column ((y<<8)|(lz<<4)|lx):
	# [surf[256] topmost non-air y (>= 126 always — land tops >= 127, water
	# columns cap at SEA=126), sid[256] that cell id, sand[256] topmost
	# B_SAND y in the shore band or -1]. Scans y from hmax-1 down to
	# BANANA_SAND_YLO (nothing below the band can feed the checks).
	var surf := PackedInt32Array()
	surf.resize(256)
	surf.fill(-1)
	var sid := PackedInt32Array()
	sid.resize(256)
	var sand := PackedInt32Array()
	sand.resize(256)
	sand.fill(-1)
	var y := hmax - 1
	while y >= BANANA_SAND_YLO:
		var row := y << 8
		var i := 0
		while i < 256:
			var v: int = data[row + i]
			if v != 0:
				if surf[i] < 0:
					surf[i] = y
					sid[i] = v
				if v == B_SAND and y <= BANANA_SAND_YHI and sand[i] < 0:
					sand[i] = y
			i += 1
		y -= 1
	return [surf, sid, sand]


# The flat-column pass. Mutates data in place (writes only into empty
# cells). Returns {"trees": n, "fruits": [[lx, y, lz], ...]} — the planted
# trees' count and their hanging fruit cells (chunk-local) so the caller
# (world.gd) can register them for the fall/pickup system.
static func apply_banana_trees(data: PackedByteArray, cx: int, cz: int, seed: int, hmax: int) -> Dictionary:
	var scan: Array = _banana_col_scan(data, hmax)
	var surf: PackedInt32Array = scan[0]
	var sid: PackedInt32Array = scan[1]
	var sand: PackedInt32Array = scan[2]
	var trees := 0
	var fruits: Array = []
	var lx := 0
	while lx < 16:
		var lz := 0
		while lz < 16:
			var i := (lz << 4) | lx
			var h := int(surf[i])
			var b := int(sid[i])
			if (b != B_DIRT and b != B_GRASS) or h < BANANA_BASE_LO or h > BANANA_BASE_HI:
				lz += 1
				continue
			var wx: int = cx * 16 + lx
			var wz: int = cz * 16 + lz
			if biome_at(wx, wz, seed) == "forest":
				lz += 1
				continue
			if AweNoise.hash2i(wx, wz, seed + BANANA_SALT) >= TREE_D_BANANA:
				lz += 1
				continue
			# Shore evidence, in-chunk: sand within 3 (shore band), water
			# column within 4.
			var sand_near := false
			var dx := -BANANA_SAND_R
			while dx <= BANANA_SAND_R and not sand_near:
				var dz := -BANANA_SAND_R
				while dz <= BANANA_SAND_R and not sand_near:
					var nx: int = lx + dx
					var nz: int = lz + dz
					if nx >= 0 and nx < 16 and nz >= 0 and nz < 16:
						if int(sand[(nz << 4) | nx]) >= 0:
							sand_near = true
					dz += 1
				dx += 1
			if not sand_near:
				lz += 1
				continue
			var water_near := false
			dx = -BANANA_WATER_R
			while dx <= BANANA_WATER_R and not water_near:
				var dz2 := -BANANA_WATER_R
				while dz2 <= BANANA_WATER_R and not water_near:
					var nx2: int = lx + dx
					var nz2: int = lz + dz2
					if nx2 >= 0 and nx2 < 16 and nz2 >= 0 and nz2 < 16:
						if int(sid[(nz2 << 4) | nx2]) == B_WATER:
							water_near = true
					dz2 += 1
				dx += 1
			if not water_near:
				lz += 1
				continue
			# Plant — the C++ tree pass's exact shape (same trunk-height
			# roll, seed+66) + 2 hanging bananas in the canopy. The fruit
			# cells are written FIRST (they are still air — the rad-2 canopy
			# would otherwise fill them with leaves); the trunk/canopy loops
			# below skip non-zero cells, so the bananas stay hanging where
			# leaves would be (MC-apples-in-oak pattern).
			var tth := 4 + int(AweNoise.hash2i(wx, wz, seed + 66) * 3.0)
			var fy: int = h + tth
			var f1x: int = lx + 1
			var f1z: int = lz
			var f2x: int = lx
			var f2z: int = lz + 1
			if f1x < 16 and fy >= 1 and fy < hmax and data[(fy << 8) | (f1z << 4) | f1x] == 0:
				data[(fy << 8) | (f1z << 4) | f1x] = B_BANANA
				fruits.append([f1x, fy, f1z])
			if f2z < 16 and fy >= 1 and fy < hmax and data[(fy << 8) | (f2z << 4) | f2x] == 0:
				data[(fy << 8) | (f2z << 4) | f2x] = B_BANANA
				fruits.append([f2x, fy, f2z])
			var dy := 1
			while dy <= tth:
				var wy := h + dy
				if wy >= 1 and wy < hmax and data[(wy << 8) | i] == 0:
					data[(wy << 8) | i] = B_LOG
				dy += 1
			var ly := tth - 1
			while ly <= tth + 2:
				var rad: int = 1 if ly >= tth + 1 else 2
				var cx2 := -rad
				while cx2 <= rad:
					var cz2 := -rad
					while cz2 <= rad:
						var sk := false
						if rad == 2 and absi(cx2) == 2 and absi(cz2) == 2:
							sk = true
						if ly == tth + 2 and absi(cx2) == 1 and absi(cz2) == 1:
							sk = true
						if not sk:
							var ax: int = lx + cx2
							var az: int = lz + cz2
							var wy2: int = h + ly
							if ax >= 0 and ax < 16 and az >= 0 and az < 16 and wy2 >= 1 and wy2 < hmax:
								var j := (wy2 << 8) | (az << 4) | ax
								if data[j] == 0:
									data[j] = B_LEAVES
						cz2 += 1
					cx2 += 1
				ly += 1
			trees += 1
			lz += 1
		lx += 1
	return {"trees": trees, "fruits": fruits}


# The slab-form pass (the worker-palettized generate_resl path). Cheap
# prefilter (any B_SAND in the data slabs? — no sand = no shore = skip the
# full 98 KB expand); on a hit: expand, run the flat pass, re-palettize
# only if a tree actually planted. Returns the same dict as
# apply_banana_trees; resl[0] is replaced in place when modified.
static func apply_banana_resl(resl: Array, cx: int, cz: int, seed: int, hmax: int) -> Dictionary:
	var none := {"trees": 0, "fruits": []}
	if resl == null or int(resl.size()) < 1 or not (resl[0] is Array):
		return none
	var slabs: Array = resl[0]
	var has_sand := false
	for s in slabs:
		if s == null:
			continue
		var n: int = int(s["n"])
		if n == 1:
			if int(s["p"][0]) == B_SAND:
				has_sand = true
				break
		var p: PackedByteArray = s["p"] if n >= 2 else s["i"]
		if p != null and p.has(B_SAND):
			has_sand = true
			break
	if not has_sand:
		return none
	var flat: PackedByteArray = ChunkIO._slabs_flat(slabs)
	var r: Dictionary = apply_banana_trees(flat, cx, cz, seed, hmax)
	if int(r["trees"]) > 0:
		resl[0] = ChunkIO.palettize_flat(flat, slabs.size())
	return r
