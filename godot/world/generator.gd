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
const SPAWN_H := 34


static func terrain_height(x: int, z: int, seed: int) -> int:
	var c := AweNoise.fbm2(float(x) / 220.0, float(z) / 220.0, seed, 3)
	var h := AweNoise.fbm2(float(x) / 70.0 + 333.0, float(z) / 70.0 + 333.0, seed + 7, 4)
	var r := AweNoise.fbm2(float(x) / 300.0 + 500.0, float(z) / 300.0 + 500.0, seed + 13, 3)
	var y := 22.0 + c * 14.0 + h * 20.0
	if r > 0.62:
		y += (r - 0.62) * 150.0
	var d := Vector2(float(x) - float(SPAWN_X), float(z) - float(SPAWN_Z)).length()
	if d <= 6.0:
		y = float(SPAWN_H)
	elif d <= 10.0:
		var w := 1.0 - smoothstep(6.0, 10.0, d)
		y = y * (1.0 - w) + float(SPAWN_H) * w
	return clampi(int(floorf(y)), 3, 74)


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


static func tree_at(x: int, z: int, seed: int) -> int:
	var hv := AweNoise.hash2i(x, z, seed + 55)
	if hv >= TREE_D_MAX:
		return -1
	var h := terrain_height(x, z, seed)
	if h <= Data.SEA + 1:
		return -1
	var d := 0.0
	var bm := biome_at(x, z, seed)
	if bm == "forest":
		d = TREE_D_FOREST
	elif bm == "plains" or bm == "snow":
		d = TREE_D_PLAIN
	if hv >= d:
		return -1
	return h


static func _putc(data: PackedByteArray, wx: int, wy: int, wz: int, bid: int, bx: int, bz: int, hmax: int) -> void:
	var lx := wx - bx
	var lz := wz - bz
	if lx < 0 or lx > 15 or lz < 0 or lz > 15 or wy < 1 or wy >= hmax:
		return
	var i := (wy << 8) | (lz << 4) | lx
	if data[i] == 0:
		data[i] = bid


static func generate(cx: int, cz: int, seed: int) -> PackedByteArray:
	var hmax := Data.HEIGHT
	var sea := Data.SEA
	var prof := OS.get_environment("AWECRAFT_GENPROFILE") == "1"
	var t0 := Time.get_ticks_usec()
	var bx := cx * 16
	var bz := cz * 16
	var acc_c := PackedFloat64Array()
	acc_c.resize(256)
	var acc_h := PackedFloat64Array()
	acc_h.resize(256)
	var acc_r := PackedFloat64Array()
	acc_r.resize(256)
	var acc_t := PackedFloat64Array()
	acc_t.resize(256)
	var acc_m := PackedFloat64Array()
	acc_m.resize(256)
	_fbm2chunk(bx, 220.0, 0.0, bz, 220.0, 0.0, seed, 3, acc_c)
	_fbm2chunk(bx, 70.0, 333.0, bz, 70.0, 333.0, seed + 7, 4, acc_h)
	_fbm2chunk(bx, 300.0, 500.0, bz, 300.0, 500.0, seed + 13, 3, acc_r)
	_fbm2chunk(bx, 260.0, 900.0, bz, 260.0, 900.0, seed + 21, 3, acc_t)
	_fbm2chunk(bx, 260.0, 1700.0, bz, 260.0, 1700.0, seed + 33, 3, acc_m)
	var heights := PackedInt32Array()
	heights.resize(256)
	var bcode := PackedInt32Array()
	bcode.resize(256)
	var lz := 0
	var lx := 0
	while lz < 16:
		lx = 0
		while lx < 16:
			var idx := lz * 16 + lx
			var x := bx + lx
			var z := bz + lz
			var cf := acc_c[idx]
			var hf := acc_h[idx]
			var rf := acc_r[idx]
			var y := 22.0 + cf * 14.0 + hf * 20.0
			if rf > 0.62:
				y += (rf - 0.62) * 150.0
			if absi(x - SPAWN_X) <= 10 and absi(z - SPAWN_Z) <= 10:
				var dx := float(x) - float(SPAWN_X)
				var dz := float(z) - float(SPAWN_Z)
				var d := sqrt(dx * dx + dz * dz)
				if d <= 6.0:
					y = float(SPAWN_H)
				elif d <= 10.0:
					var w := 1.0 - smoothstep(6.0, 10.0, d)
					y = y * (1.0 - w) + float(SPAWN_H) * w
			heights[idx] = clampi(int(floorf(y)), 3, 74)
			var tv := acc_t[idx] * 2.0 - 1.0
			var mv := acc_m[idx] * 2.0 - 1.0
			var bc := 3
			if tv < -0.25:
				bc = 0
			elif tv > 0.35 and mv < 0.1:
				bc = 1
			elif mv > 0.25:
				bc = 2
			bcode[idx] = bc
			lx += 1
		lz += 1
	var t1 := Time.get_ticks_usec()
	var data := PackedByteArray()
	data.resize(256 * hmax)
	var n1 := PackedFloat64Array()
	n1.resize(96)
	var n2 := PackedFloat64Array()
	n2.resize(96)
	var n3 := PackedFloat64Array()
	n3.resize(96)
	var nc1 := PackedFloat64Array()
	nc1.resize(96)
	var nc2 := PackedFloat64Array()
	nc2.resize(96)
	var p0a := PackedFloat64Array()
	p0a.resize(48)
	var p0c := PackedFloat64Array()
	p0c.resize(48)
	var p1a := PackedFloat64Array()
	p1a.resize(48)
	var p1c := PackedFloat64Array()
	p1c.resize(48)
	var t71 := _ytable(7.0, 1.0, 0.0)
	var t71y: PackedInt32Array = t71[0]
	var t71v: PackedFloat64Array = t71[1]
	var t72 := _ytable(7.0, 2.0, 0.0)
	var t72y: PackedInt32Array = t72[0]
	var t72v: PackedFloat64Array = t72[1]
	var t91 := _ytable(9.0, 1.0, 0.0)
	var t91y: PackedInt32Array = t91[0]
	var t91v: PackedFloat64Array = t91[1]
	var t92 := _ytable(9.0, 2.0, 0.0)
	var t92y: PackedInt32Array = t92[0]
	var t92v: PackedFloat64Array = t92[1]
	var t61 := _ytable(6.0, 1.0, 0.0)
	var t61y: PackedInt32Array = t61[0]
	var t61v: PackedFloat64Array = t61[1]
	var t62 := _ytable(6.0, 2.0, 0.0)
	var t62y: PackedInt32Array = t62[0]
	var t62v: PackedFloat64Array = t62[1]
	var t101 := _ytable(10.0, 1.0, 0.0)
	var t101y: PackedInt32Array = t101[0]
	var t101v: PackedFloat64Array = t101[1]
	var t99 := _ytable(9.0, 1.0, 900.0)
	var t99y: PackedInt32Array = t99[0]
	var t99v: PackedFloat64Array = t99[1]
	lz = 0
	while lz < 16:
		lx = 0
		while lx < 16:
			var idx := lz * 16 + lx
			var x := bx + lx
			var z := bz + lz
			var h := heights[idx]
			var bm := bcode[idx]
			var cbase := (lz << 4) | lx
			var yend := h - 4
			if yend > 0:
				_fbm3col(float(x) / 7.0, float(z) / 7.0, seed + 77, 1, yend, t71y, t71v, t72y, t72v, p0a, p0c, p1a, p1c, n1)
				_fbm3col(float(x) / 9.0 + 900.0, float(z) / 9.0 + 900.0, seed + 88, 1, yend, t91y, t91v, t92y, t92v, p0a, p0c, p1a, p1c, n2)
				_fbm3col(float(x) / 6.0 + 1700.0, float(z) / 6.0 + 1700.0, seed + 99, 1, yend, t61y, t61v, t62y, t62v, p0a, p0c, p1a, p1c, n3)
			data[cbase] = B_BEDROCK
			var ys := 1
			while ys <= yend:
				if ys < 16 and n1[ys] > 0.78:
					data[(ys << 8) | cbase] = B_DIAMOND_ORE
				elif ys < 42 and n2[ys] > 0.8:
					data[(ys << 8) | cbase] = B_IRON_ORE
				elif ys < 60 and n3[ys] > 0.82:
					data[(ys << 8) | cbase] = B_COAL_ORE
				elif ys < 10 and AweNoise.hash3i(x, ys, z, seed + 333) < 0.02:
					data[(ys << 8) | cbase] = B_OBSIDIAN
				else:
					data[(ys << 8) | cbase] = B_STONE
				ys += 1
			var yd := h - 3
			if yd < 1:
				yd = 1
			while yd < h:
				data[(yd << 8) | cbase] = B_SAND if bm == 1 else B_DIRT
				yd += 1
			var bs := B_GRASS
			if bm == 1:
				bs = B_SAND
			elif bm == 0:
				bs = B_SNOW_GRASS
			data[(h << 8) | cbase] = bs
			if h <= sea + 1 and bm != 1:
				data[(h << 8) | cbase] = B_SAND
			if h < sea:
				var yw := h + 1
				while yw <= sea:
					data[(yw << 8) | cbase] = B_WATER
					yw += 1
			lx += 1
		lz += 1
	var t2 := Time.get_ticks_usec()
	lz = 0
	while lz < 16:
		lx = 0
		while lx < 16:
			var idx := lz * 16 + lx
			var h := heights[idx]
			if h >= 5:
				var x := bx + lx
				var z := bz + lz
				var cbase := (lz << 4) | lx
				_vnoise3col(float(x) / 16.0, float(z) / 16.0, seed + 301, t101y, t101v, 5, h, p0a, p0c, nc1)
				_vnoise3col(float(x) / 11.0 + 500.0, float(z) / 11.0 + 600.0, seed + 302, t99y, t99v, 5, h, p0a, p0c, nc2)
				var yc := 5
				while yc <= h:
					var ci := (yc << 8) | cbase
					var cbk := data[ci]
					if cbk != 0 and cbk != B_WATER and cbk != B_BEDROCK:
						if nc1[yc] > 0.58 and nc2[yc] > 0.56:
							data[ci] = B_LAVA if yc < 8 else 0
					yc += 1
			lx += 1
		lz += 1
	var t3 := Time.get_ticks_usec()
	var gdbg := OS.get_environment("AWECRAFT_GENDBG") == "1"
	if gdbg:
		print("GENDBG cave_done ", cx, " ", cz, " ms=", (t3 - t0) / 1000.0)
	var tz := bz - 2
	while tz < bz + 18:
		var tx := bx - 2
		while tx < bx + 18:
			var hcol := tree_at(tx, tz, seed)
			if hcol >= 0:
				var glx := tx - bx
				var glz := tz - bz
				var skip := false
				if glx >= 0 and glx < 16 and glz >= 0 and glz < 16:
					var gb: int = data[(hcol << 8) | (glz << 4) | glx]
					if gb == 0 or gb == B_WATER or gb == B_LAVA:
						skip = true
					else:
						var gi = Data.block(gb)
						if gi == null or not bool(gi.solid):
							skip = true
				if not skip:
					var tth := 4 + int(AweNoise.hash2i(tx, tz, seed + 66) * 3.0)
					var dy := 1
					while dy <= tth:
						_putc(data, tx, hcol + dy, tz, B_LOG, bx, bz, hmax)
						dy += 1
					var ly := tth - 1
					while ly <= tth + 2:
						var rad := 1 if ly >= tth + 1 else 2
						var dx := -rad
						while dx <= rad:
							var dz := -rad
							while dz <= rad:
								var sk := false
								if rad == 2 and absi(dx) == 2 and absi(dz) == 2:
									sk = true
								if ly == tth + 2 and absi(dx) == 1 and absi(dz) == 1:
									sk = true
								if not sk:
											_putc(data, tx + dx, hcol + ly, tz + dz, B_LEAVES, bx, bz, hmax)
								dz += 1
							dx += 1
						ly += 1
			tx += 1
		tz += 1
	if gdbg:
		print("GENDBG trees_done ", cx, " ", cz, " ms=", (Time.get_ticks_msec() * 1000 - t0) / 1000.0)
	lz = 0
	while lz < 16:
		lx = 0
		while lx < 16:
			var fx := bx + lx
			var fz := bz + lz
			var fh := heights[lz * 16 + lx]
			if fh > sea and fh < hmax - 2:
				var idxf := (fh << 8) | (lz << 4) | lx
				if data[idxf] == B_GRASS and AweNoise.hash2i(fx, fz, seed + 777) < 0.02:
					data[idxf + 256] = B_ROSE if AweNoise.hash2i(fx, fz, seed + 778) < 0.5 else B_DANDELION
			lx += 1
		lz += 1
	var t4 := Time.get_ticks_usec()
	if gdbg:
		print("GENDBG flora_done ", cx, " ", cz, " ms=", (t4 - t0) / 1000.0)
	if prof:
		print("GENPROFILE phase=heights ms=", (t1 - t0) / 1000.0)
		print("GENPROFILE phase=fill ms=", (t2 - t1) / 1000.0)
		print("GENPROFILE phase=cave ms=", (t3 - t2) / 1000.0)
		print("GENPROFILE phase=flora ms=", (t4 - t3) / 1000.0)
	return data


static func _ytable(s: float, f: float, oy: float) -> Array:
	var yi := PackedInt32Array()
	yi.resize(96)
	var vv := PackedFloat64Array()
	vv.resize(96)
	var y := 0
	while y < 96:
		var yf := float(y) / s * f + oy
		var i := int(floorf(yf))
		yi[y] = i
		vv[y] = AweNoise._fade(yf - float(i))
		y += 1
	return [yi, vv]


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


static func _fbm3col(x0: float, z0: float, s: int, ylo: int, yhi: int, ay: PackedInt32Array, av: PackedFloat64Array, by: PackedInt32Array, bv: PackedFloat64Array, p0a: PackedFloat64Array, p0c: PackedFloat64Array, p1a: PackedFloat64Array, p1c: PackedFloat64Array, out: PackedFloat64Array) -> void:
	var xif := int(floorf(x0))
	var u := AweNoise._fade(x0 - float(xif))
	var zif := int(floorf(z0))
	var w := AweNoise._fade(z0 - float(zif))
	var ylo0: int = ay[ylo]
	var yhi0: int = ay[yhi]
	var k := 0
	while k < yhi0 - ylo0 + 2:
		var ri := ylo0 + k
		var h0 := AweNoise.hash3i(xif, ri, zif, s)
		var h1 := AweNoise.hash3i(xif + 1, ri, zif, s)
		var h2 := AweNoise.hash3i(xif, ri, zif + 1, s)
		var h3 := AweNoise.hash3i(xif + 1, ri, zif + 1, s)
		p0a[k] = lerpf(h0, h1, u)
		p0c[k] = lerpf(h2, h3, u)
		k += 1
	var x02 := x0 * 2.0
	var z02 := z0 * 2.0
	var xif2 := int(floorf(x02))
	var u2 := AweNoise._fade(x02 - float(xif2))
	var zif2 := int(floorf(z02))
	var w2 := AweNoise._fade(z02 - float(zif2))
	var ylo1: int = by[ylo]
	var yhi1: int = by[yhi]
	k = 0
	while k < yhi1 - ylo1 + 2:
		var ri := ylo1 + k
		var h0 := AweNoise.hash3i(xif2, ri, zif2, s + 101)
		var h1 := AweNoise.hash3i(xif2 + 1, ri, zif2, s + 101)
		var h2 := AweNoise.hash3i(xif2, ri, zif2 + 1, s + 101)
		var h3 := AweNoise.hash3i(xif2 + 1, ri, zif2 + 1, s + 101)
		p1a[k] = lerpf(h0, h1, u2)
		p1c[k] = lerpf(h2, h3, u2)
		k += 1
	var y := ylo
	while y <= yhi:
		var i0: int = ay[y] - ylo0
		var i1: int = by[y] - ylo1
		var v0: float = av[y]
		var v1: float = bv[y]
		var r0 := lerpf(lerpf(p0a[i0], p0a[i0 + 1], v0), lerpf(p0c[i0], p0c[i0 + 1], v0), w)
		var r1 := lerpf(lerpf(p1a[i1], p1a[i1 + 1], v1), lerpf(p1c[i1], p1c[i1 + 1], v1), w2)
		var a := 0.0
		a += r0
		a += r1 * 0.5
		out[y] = a / 1.5
		y += 1


static func _vnoise3col(x0: float, z0: float, s: int, ty: PackedInt32Array, tv: PackedFloat64Array, ylo: int, yhi: int, p0a: PackedFloat64Array, p0c: PackedFloat64Array, out: PackedFloat64Array) -> void:
	var xif := int(floorf(x0))
	var u := AweNoise._fade(x0 - float(xif))
	var zif := int(floorf(z0))
	var w := AweNoise._fade(z0 - float(zif))
	var ylo0: int = ty[ylo]
	var yhi0: int = ty[yhi]
	var k := 0
	while k < yhi0 - ylo0 + 2:
		var ri := ylo0 + k
		var h0 := AweNoise.hash3i(xif, ri, zif, s)
		var h1 := AweNoise.hash3i(xif + 1, ri, zif, s)
		var h2 := AweNoise.hash3i(xif, ri, zif + 1, s)
		var h3 := AweNoise.hash3i(xif + 1, ri, zif + 1, s)
		p0a[k] = lerpf(h0, h1, u)
		p0c[k] = lerpf(h2, h3, u)
		k += 1
	var y := ylo
	while y <= yhi:
		var i0: int = ty[y] - ylo0
		var v0: float = tv[y]
		out[y] = lerpf(lerpf(p0a[i0], p0a[i0 + 1], v0), lerpf(p0c[i0], p0c[i0 + 1], v0), w)
		y += 1
