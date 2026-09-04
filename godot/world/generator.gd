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

const TREE_D_FOREST := 0.14
const TREE_D_PLAIN := 0.02
const TREE_D_MAX := 0.14

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
