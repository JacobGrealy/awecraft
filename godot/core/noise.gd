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
