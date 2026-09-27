class_name AweNoise


static func _i32(v: int) -> int:
	var r := v & 0xFFFFFFFF
	if r >= 0x80000000:
		r -= 0x100000000
	return r


static func _imul(a: int, b: int) -> int:
	return _i32(a * b)


static func _usl(v: int, n: int) -> int:
	return (v & 0xFFFFFFFF) >> n


static func hash2i(x: int, z: int, s: int) -> float:
	var h := (s ^ (x * 374761393) ^ (z * 668265263)) & 0xFFFFFFFF
	h = (h ^ (h >> 13)) * 1274126177
	h &= 0xFFFFFFFF
	h ^= h >> 16
	return float(h & 0xFFFFFFFF) / 4294967296.0


static func hash3i(x: int, y: int, z: int, s: int) -> float:
	var h := (s ^ (x * 374761393) ^ (y * 2246822519) ^ (z * 668265263)) & 0xFFFFFFFF
	h = (h ^ (h >> 13)) * 1274126177
	h &= 0xFFFFFFFF
	h ^= h >> 16
	return float(h & 0xFFFFFFFF) / 4294967296.0


static func _fade(t: float) -> float:
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)


static func vnoise2(x: float, z: float, s: int) -> float:
	var xi := int(floorf(x))
	var zi := int(floorf(z))
	var u := _fade(x - float(xi))
	var v := _fade(z - float(zi))
	var aa := hash2i(xi, zi, s)
	var ab := hash2i(xi + 1, zi, s)
	var ba := hash2i(xi, zi + 1, s)
	var bb := hash2i(xi + 1, zi + 1, s)
	return lerpf(lerpf(aa, ab, u), lerpf(ba, bb, u), v)


static func vnoise3(x: float, y: float, z: float, s: int) -> float:
	var xi := int(floorf(x))
	var yi := int(floorf(y))
	var zi := int(floorf(z))
	var u := _fade(x - float(xi))
	var v := _fade(y - float(yi))
	var w := _fade(z - float(zi))
	var x00 := lerpf(hash3i(xi, yi, zi, s), hash3i(xi + 1, yi, zi, s), u)
	var x10 := lerpf(hash3i(xi, yi + 1, zi, s), hash3i(xi + 1, yi + 1, zi, s), u)
	var x01 := lerpf(hash3i(xi, yi, zi + 1, s), hash3i(xi + 1, yi, zi + 1, s), u)
	var x11 := lerpf(hash3i(xi, yi + 1, zi + 1, s), hash3i(xi + 1, yi + 1, zi + 1, s), u)
	return lerpf(lerpf(x00, x10, v), lerpf(x01, x11, v), w)


static func fbm2(x: float, z: float, s: int, oct := 4) -> float:
	var a := 0.0
	var amp := 1.0
	var f := 1.0
	var tot := 0.0
	for i in oct:
		a += vnoise2(x * f, z * f, s + i * 101) * amp
		tot += amp
		amp *= 0.5
		f *= 2.0
	return a / tot


static func fbm3(x: float, y: float, z: float, s: int, oct := 3) -> float:
	var a := 0.0
	var amp := 1.0
	var f := 1.0
	var tot := 0.0
	for i in oct:
		a += vnoise3(x * f, y * f, z * f, s + i * 101) * amp
		tot += amp
		amp *= 0.5
		f *= 2.0
	return a / tot


# AC-0347 P1: the vanilla NormalNoise octave machine — a CUSTOM amplitude
# list + a firstOctave FREQUENCY OFFSET, normalized by sum(|a_i|). Same
# machine as fbm3 (per-octave seed s + i * 101), but the fixed 0.5 gain is
# replaced by the amplitude list and the frequencies start at 2^firstOctave
# (vanilla's cave entries use a NEGATIVE firstOctave: the base octave
# samples at 2^-8). Vanilla uses Perlin gradients; ours uses this lane's
# vnoise3 kernel — the octave machine is what the vanilla constants need.
# BIT-EXACT contract: the C++ mirror (gen.cpp vn3) is op-order identical in
# f64 (the frequency is an exact power of two — built by halving/doubling,
# no pow; zero-amplitude octaves are skipped, their contribution is exactly
# +0.0 either way; gen.cpp is -ffp-contract=off). genprobe lockstep.
static func vn3(x: float, y: float, z: float, s: int, first_oct: int, amps: Array) -> float:
	var a := 0.0
	var tot := 0.0
	var f := 1.0
	var fo := first_oct
	if fo < 0:
		for k in -fo:
			f *= 0.5
	else:
		for k in fo:
			f *= 2.0
	for i in amps.size():
		var amp := float(amps[i])
		if amp != 0.0:
			a += amp * vnoise3(x * f, y * f, z * f, s + i * 101)
		if amp < 0.0:
			tot += -amp
		else:
			tot += amp
		f *= 2.0
	return a / tot


# AC-0367 piece A: the vanilla tunnel-noise families (spaghetti_2d /
# spaghetti_3d+selector / spaghetti_roughness / noodle) — the EXACT mirror
# of the C++ dense sources (gdext/src/gen.cpp AC-0367 section): same f64
# op order, same constants, same seed slots (+337..+350). The spec is the
# 1.21.4 caves/*.json density functions + the decompiled weird_scaled_sampler
# (d * |noise(pos/d)| with the two rarity mappers). The noise value is the
# centered 2*(vn3-0.5) per the project convention. genprobe lockstep; the
# independent python port is tasks/AC-0367/ac0367_tunnel_check.py. Nothing in
# the generation path reads these yet (piece B wires them into dens_at).
static func _spag_rarity_type1(v: float) -> float:
	if v < -0.5:
		return 0.75
	if v < 0.0:
		return 1.0
	if v < 0.5:
		return 1.5
	return 2.0


static func _spag_rarity_type2(v: float) -> float:
	if v < -0.75:
		return 0.5
	if v < -0.5:
		return 0.75
	if v < 0.5:
		return 1.0
	if v < 0.75:
		return 2.0
	return 3.0


static func spag2d(x: float, y: float, z: float, s: int) -> float:
	var m := vn3(x * 2.0, y * 1.0, z * 2.0, s + 338, -11, [1.0])
	var mm := 2.0 * (m - 0.5)
	var d := _spag_rarity_type2(mm)
	var wn := vn3(x / d, y / d, z / d, s + 337, -7, [1.0])
	var wv := d * absf(2.0 * (wn - 0.5))
	var nt := vn3(x * 2.0, y * 1.0, z * 2.0, s + 339, -11, [1.0])
	var tm := -0.95 + (-0.35000000000000003 * (2.0 * (nt - 0.5)))
	var el := vn3(x * 1.0, y * 0.0, z * 1.0, s + 340, -8, [1.0])
	var ev := 2.0 * (el - 0.5)
	var tg := (y - 0.0) / (384.0 - 0.0)
	if tg < 0.0:
		tg = 0.0
	if tg > 1.0:
		tg = 1.0
	var g := 8.0 + (-40.0 - 8.0) * tg
	var e := (0.0 + 8.0 * ev) + g
	e = absf(e)
	var c := e + tm
	var cc := c * c * c
	var a := wv + (0.083 * tm)
	var r := a if a > cc else cc
	if r < -1.0:
		r = -1.0
	if r > 1.0:
		r = 1.0
	return r


static func spag3d(x: float, y: float, z: float, s: int) -> float:
	var r := vn3(x * 2.0, y * 1.0, z * 2.0, s + 341, -11, [1.0])
	var rr := 2.0 * (r - 0.5)
	var d1 := _spag_rarity_type1(rr)
	var n1 := vn3(x / d1, y / d1, z / d1, s + 342, -7, [1.0])
	var w1 := d1 * absf(2.0 * (n1 - 0.5))
	var d2 := _spag_rarity_type1(rr)
	var n2 := vn3(x / d2, y / d2, z / d2, s + 343, -7, [1.0])
	var w2 := d2 * absf(2.0 * (n2 - 0.5))
	var nt := vn3(x * 1.0, y * 1.0, z * 1.0, s + 344, -8, [1.0])
	# 0.011499999999999996 (the 1.21.4 constant) as the EXACT division
	# mantissa / 2^59 — the GDScript float-literal parser cannot round
	# that decimal (4 ulp low for every decimal string in the double's
	# rounding basin, verified in-task), so all three lanes spell the
	# constant identically (see the AC-0367 BIT-EXACT NOTE in gen.cpp).
	# Both literals are exact f64 (K < 2^53; 2^59 is a power of two) and
	# the quotient is itself representable — IEEE division returns it
	# exactly, so c2 is bit-identical in all lanes.
	var c2 := -6629298651489368.0 / 576460752303423488.0
	var th := -0.0765 + (c2 * (2.0 * (nt - 0.5)))
	var a := (w1 if w1 > w2 else w2) + th
	if a < -1.0:
		a = -1.0
	if a > 1.0:
		a = 1.0
	return a


static func spagrough(x: float, y: float, z: float, s: int) -> float:
	var rm := vn3(x * 1.0, y * 1.0, z * 1.0, s + 346, -8, [1.0])
	var rs := vn3(x * 1.0, y * 1.0, z * 1.0, s + 345, -5, [1.0])
	var a := -0.05 + (-0.05 * (2.0 * (rm - 0.5)))
	var b := -0.4 + absf(2.0 * (rs - 0.5))
	return a * b


static func noodle(x: float, y: float, z: float, s: int) -> float:
	var inb := (y >= 4.0) and (y < 385.0)
	var nv := -1.0
	if inb:
		nv = 2.0 * (vn3(x * 1.0, y * 1.0, z * 1.0, s + 347, -8, [1.0]) - 0.5)
	if nv >= -1000000.0 and nv < 0.0:
		return 64.0
	var nt := vn3(x * 1.0, y * 1.0, z * 1.0, s + 348, -8, [1.0])
	var ra := vn3(x * 2.6666666666666665, y * 2.6666666666666665, z * 2.6666666666666665, s + 349, -7, [1.0])
	var rb := vn3(x * 2.6666666666666665, y * 2.6666666666666665, z * 2.6666666666666665, s + 350, -7, [1.0])
	var ot := 0.0
	if inb:
		ot = -0.07500000000000001 + (-0.025 * (2.0 * (nt - 0.5)))
	var va := 0.0
	var vb := 0.0
	if inb:
		va = absf(2.0 * (ra - 0.5))
		vb = absf(2.0 * (rb - 0.5))
	return ot + (1.5 * (va if va > vb else vb))
