class_name Lighting
extends RefCounted

const SKY_FULL := 15

const DIRS := [
	Vector3i(1, 0, 0),
	Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0),
	Vector3i(0, -1, 0),
	Vector3i(0, 0, 1),
	Vector3i(0, 0, -1),
]

static var _cross: PackedByteArray = PackedByteArray()
static var _glow: PackedByteArray = PackedByteArray()
static var _att: PackedByteArray = PackedByteArray()


static func passes_light(b: int) -> bool:
	# ported from web blocksLight(): air, water, lava, torch, portal always pass;
	# otherwise only cross (non-solid) blocks pass
	if b == 0 or b == 5 or b == 24 or b == 22 or b == 28:
		return true
	var info = Data.block(b)
	return info != null and bool(info.get("cross", false))


static func _tables() -> void:
	if _cross.size() > 0:
		return
	_cross.resize(48)
	_glow.resize(48)
	_att.resize(48)
	_att[0] = 1
	_att[22] = 1
	_att[28] = 1
	for b in Data.blocks:
		var i := int(b)
		if i >= 48:
			continue
		var info = Data.block(b)
		if info == null:
			continue
		_cross[i] = 1 if bool(info.get("cross", false)) else 0
		_glow[i] = int(info.get("light", 0))
		if i == 0 or i == 22 or i == 28 or bool(info.get("cross", false)):
			_att[i] = 3 if i == 5 or i == 24 else 1


static func light_of(b: int) -> int:
	var info = Data.block(b)
	if info == null:
		return 0
	return int(info.get("light", 0))


static func compute_light(box: Dictionary, world) -> Dictionary:
	return compute_light_split(box, world).eff


static func compute_light_split(box: Dictionary, world) -> Dictionary:
	_tables()
	var mn: Vector3i = box.min
	var mx: Vector3i = box.max
	var w := mx.x - mn.x + 1
	var d := mx.z - mn.z + 1
	var h := mx.y - mn.y + 1
	var sz := w * d
	var H: int = Data.HEIGHT
	var ids := PackedByteArray()
	ids.resize(sz * h)
	var sky := PackedByteArray()
	sky.resize(sz * h)
	var blk := PackedByteArray()
	blk.resize(sz * h)
	for ix in range(w):
		var wx: int = mn.x + ix
		var cxv := int(floorf(float(wx) / 16.0))
		var lx := wx - cxv * 16
		for iz in range(d):
			var wz: int = mn.z + iz
			var czv := int(floorf(float(wz) / 16.0))
			var lz := wz - czv * 16
			var c = world.chunks.get(world._key(cxv, czv))
			if c == null:
				world.get_block(wx, 0, wz)
				c = world.chunks.get(world._key(cxv, czv))
			var i0 := ix + iz * w
			var open := true
			if c != null:
				var nd: PackedByteArray = c.data
				for y in range(H - 1, mn.y - 1, -1):
					var b: int = nd[(y << 8) | (lz << 4) | lx]
					if y > mx.y:
						if open and _att[b] == 0:
							open = false
						continue
					var i := (y - mn.y) * sz + i0
					ids[i] = b
					if open and _att[b] > 0:
						sky[i] = SKY_FULL
					var lv: int = _glow[b]
					if lv > 0:
						blk[i] = lv
					if open and _att[b] == 0:
						open = false
			else:
				for y in range(H - 1, mn.y - 1, -1):
					var b := int(world.get_block(wx, y, wz))
					if y > mx.y:
						if open and _att[b] == 0:
							open = false
						continue
					var i := (y - mn.y) * sz + i0
					ids[i] = b
					if open and _att[b] > 0:
						sky[i] = SKY_FULL
					var lv: int = _glow[b]
					if lv > 0:
						blk[i] = lv
					if open and _att[b] == 0:
						open = false
	_flood_flat(sky, ids, w, h, d)
	_flood_flat(blk, ids, w, h, d)
	var sky_d: Dictionary = {}
	var blk_d: Dictionary = {}
	var eff: Dictionary = {}
	for iy in range(h):
		for iz in range(d):
			for ix in range(w):
				var i := iy * sz + iz * w + ix
				var s: int = sky[i]
				var b2: int = blk[i]
				var e := s if s >= b2 else b2
				var cell := Vector3i(mn.x + ix, mn.y + iy, mn.z + iz)
				if s > 0:
					sky_d[cell] = s
				if b2 > 0:
					blk_d[cell] = b2
				if e > 0:
					eff[cell] = e
	return {"sky": sky_d, "block": blk_d, "eff": eff}


static func compute_light_flat(box: Dictionary, world) -> Dictionary:
	_tables()
	var mn: Vector3i = box.min
	var mx: Vector3i = box.max
	var w := mx.x - mn.x + 1
	var d := mx.z - mn.z + 1
	var h := mx.y - mn.y + 1
	var sz := w * d
	var H: int = Data.HEIGHT
	var ids := PackedByteArray()
	ids.resize(sz * h)
	var sky := PackedByteArray()
	sky.resize(sz * h)
	var blk := PackedByteArray()
	blk.resize(sz * h)
	var has_glow := false
	for ix in range(w):
		var wx: int = mn.x + ix
		var cxv := int(floorf(float(wx) / 16.0))
		var lx := wx - cxv * 16
		for iz in range(d):
			var wz: int = mn.z + iz
			var czv := int(floorf(float(wz) / 16.0))
			var lz := wz - czv * 16
			var c = world.chunks.get(world._key(cxv, czv))
			if c == null:
				world.get_block(wx, 0, wz)
				c = world.chunks.get(world._key(cxv, czv))
			var i0 := ix + iz * w
			var open := true
			if c != null:
				var nd: PackedByteArray = c.data
				for y in range(H - 1, mn.y - 1, -1):
					var b: int = nd[(y << 8) | (lz << 4) | lx]
					if y > mx.y:
						if open and _att[b] == 0:
							open = false
						continue
					var i := (y - mn.y) * sz + i0
					ids[i] = b
					if open and _att[b] > 0:
						sky[i] = SKY_FULL
					var lv := _glow[b]
					if lv > 0:
						blk[i] = lv
						has_glow = true
					if open and _att[b] == 0:
						open = false
			else:
				for y in range(H - 1, mn.y - 1, -1):
					var b := int(world.get_block(wx, y, wz))
					if y > mx.y:
						if open and _att[b] == 0:
							open = false
						continue
					var i := (y - mn.y) * sz + i0
					ids[i] = b
					if open and _att[b] > 0:
						sky[i] = SKY_FULL
					var lv := _glow[b]
					if lv > 0:
						blk[i] = lv
						has_glow = true
					if open and _att[b] == 0:
						open = false
	_flood_flat(sky, ids, w, h, d)
	if has_glow:
		_flood_flat(blk, ids, w, h, d)
	var eff := PackedByteArray()
	eff.resize(sz * h)
	for i in range(eff.size()):
		var s := sky[i]
		var b2 := blk[i]
		eff[i] = s if s >= b2 else b2
	return {"mn": mn, "w": w, "d": d, "arr": eff}


# AC-0107: single-chunk, data-only light for worker threads — the exact
# STANDALONE_MARGIN=0 specialization of compute_light_flat (the box build_mesh
# passes): every column maps to the same chunk, so the world dereference +
# get_block fallbacks are provably no-ops and the sky-scan reads ONLY the
# passed chunk data. _tables() is warmed on the main thread (world._ready),
# so a worker call never touches Data. Returns the same shape as
# compute_light_flat (mn is the chunk's world-space min — the eff dict lands
# in chunk.last_eff and must index world coordinates on later remeshes).
static func compute_light_flat_chunk(data: PackedByteArray, cx: int, cz: int, h: int) -> Dictionary:
	_tables()
	var mn := Vector3i(cx * 16, 0, cz * 16)
	var mx := Vector3i(cx * 16 + 15, h - 1, cz * 16 + 15)
	var w := 16
	var d := 16
	var H: int = h
	var sz := w * d
	var ids := PackedByteArray()
	ids.resize(sz * h)
	var sky := PackedByteArray()
	sky.resize(sz * h)
	var blk := PackedByteArray()
	blk.resize(sz * h)
	var has_glow := false
	for ix in range(w):
		for iz in range(d):
			var i0 := ix + iz * w
			var open := true
			for y in range(H - 1, mn.y - 1, -1):
				var b: int = data[(y << 8) | (iz << 4) | ix]
				if y > mx.y:
					if open and _att[b] == 0:
						open = false
					continue
				var i := (y - mn.y) * sz + i0
				ids[i] = b
				if open and _att[b] > 0:
					sky[i] = SKY_FULL
				var lv := _glow[b]
				if lv > 0:
					blk[i] = lv
					has_glow = true
				if open and _att[b] == 0:
					open = false
	_flood_flat(sky, ids, w, h, d)
	if has_glow:
		_flood_flat(blk, ids, w, h, d)
	var eff := PackedByteArray()
	eff.resize(sz * h)
	for i in range(eff.size()):
		var s := sky[i]
		var b2 := blk[i]
		eff[i] = s if s >= b2 else b2
	return {"mn": mn, "w": w, "d": d, "arr": eff}


static func _flood_flat(src: PackedByteArray, ids: PackedByteArray, w: int, h: int, d: int) -> void:
	var sz := w * d
	var size := ids.size()
	var patt := PackedByteArray()
	patt.resize(size)
	for i in range(size):
		patt[i] = _att[ids[i]]
	var buckets: Array = []
	for i in range(16):
		buckets.append([])
	for i in range(size):
		var lv := src[i]
		if lv <= 1:
			continue
		var yy := i / sz
		var rem := i - yy * sz
		var zz := rem / w
		var xx := rem - zz * w
		var spr := false
		if xx + 1 < w:
			var n := i + 1
			if patt[n] > 0 and src[n] < lv:
				spr = true
		if not spr and xx > 0:
			var n := i - 1
			if patt[n] > 0 and src[n] < lv:
				spr = true
		if not spr and yy + 1 < h:
			var n := i + sz
			if patt[n] > 0 and src[n] < lv:
				spr = true
		if not spr and yy > 0:
			var n := i - sz
			if patt[n] > 0 and src[n] < lv:
				spr = true
		if not spr and zz + 1 < d:
			var n := i + w
			if patt[n] > 0 and src[n] < lv:
				spr = true
		if not spr and zz > 0:
			var n := i - w
			if patt[n] > 0 and src[n] < lv:
				spr = true
		if spr:
			buckets[lv].append(i)
	for lv in range(SKY_FULL, 1, -1):
		var q: Array = buckets[lv]
		var qi := 0
		while qi < q.size():
			var i: int = q[qi]
			qi += 1
			var yy := i / sz
			var rem := i - yy * sz
			var zz := rem / w
			var xx := rem - zz * w
			if xx + 1 < w:
				var n := i + 1
				var t := patt[n]
				if t > 0:
					var nl := lv - t
					if nl > 0 and nl > src[n]:
						src[n] = nl
						buckets[nl].append(n)
			if xx > 0:
				var n := i - 1
				var t := patt[n]
				if t > 0:
					var nl := lv - t
					if nl > 0 and nl > src[n]:
						src[n] = nl
						buckets[nl].append(n)
			if yy + 1 < h:
				var n := i + sz
				var t := patt[n]
				if t > 0:
					var nl := lv - t
					if nl > 0 and nl > src[n]:
						src[n] = nl
						buckets[nl].append(n)
			if yy > 0:
				var n := i - sz
				var t := patt[n]
				if t > 0:
					var nl := lv - t
					if nl > 0 and nl > src[n]:
						src[n] = nl
						buckets[nl].append(n)
			if zz + 1 < d:
				var n := i + w
				var t := patt[n]
				if t > 0:
					var nl := lv - t
					if nl > 0 and nl > src[n]:
						src[n] = nl
						buckets[nl].append(n)
			if zz > 0:
				var n := i - w
				var t := patt[n]
				if t > 0:
					var nl := lv - t
					if nl > 0 and nl > src[n]:
						src[n] = nl
						buckets[nl].append(n)


