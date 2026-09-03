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
			if c == null or c.data.is_empty():
				c = null
			var i0 := ix + iz * w
			var open := true
			if c != null:
				# AC-0203: neighbor column materialized flat (multi-chunk box
				# kernel — rare probe path, not the hot lane).
				var nd: PackedByteArray = c.flat_data()
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
					var b := 0  # AC-0119: missing/empty column = air (web world.block :882)
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
	# AC-0129: box exactly one chunk -> the pull kernel (self-light with fresh
	# neighbor strips); the multi-chunk margin box keeps the old contained
	# two-flood path unchanged (no caller passes it in practice).
	if w == 16 and d == 16 and mn.y == 0 and h == Data.HEIGHT and mn.x % 16 == 0 and mn.z % 16 == 0:
		var c = world.chunks.get(world._key(mn.x / 16, mn.z / 16))
		if c != null and not c.data.is_empty():
			var s = world._strips_for(mn.x / 16, mn.z / 16)
			return compute_light_flat_chunk_pull(c.data, mn.x / 16, mn.z / 16, h, s["eff"], s["blk"], s["blk_b"])
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
			if c == null or c.data.is_empty():
				c = null
			var i0 := ix + iz * w
			var open := true
			if c != null:
				# AC-0203: neighbor column materialized flat (multi-chunk box
				# kernel — rare probe path, not the hot lane).
				var nd: PackedByteArray = c.flat_data()
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
					var b := 0  # AC-0119: missing/empty column = air (web world.block :882)
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


# AC-0077: AC-0107's single-chunk contained kernel (the exact
# STANDALONE_MARGIN=0 specialization of compute_light_flat — the box
# build_mesh passes): every column maps to the same chunk, so the sky-scan
# reads ONLY the passed chunk data. _tables() is warmed on the main thread
# (world._ready), so a worker call never touches Data. Buffers (ids/sky/blk,
# sized 16x16*h with sky/blk zeroed by the caller) are reused across calls;
# a fresh eff (16x16*h) is returned per call.
static func _chunk_light_into(data, cx: int, cz: int, h: int, ids: PackedByteArray, sky: PackedByteArray, blk: PackedByteArray) -> PackedByteArray:
	# AC-0203: data is the 24-slab array; reads go through per-slab flat
	# views (scan order and open-flag semantics unchanged).
	var mn := Vector3i(cx * 16, 0, cz * 16)
	var mx := Vector3i(cx * 16 + 15, h - 1, cz * 16 + 15)
	var w := 16
	var d := 16
	var H: int = h
	var sz := w * d
	var dviews: Array = []
	for s in data:
		dviews.append(ChunkIO._slab_flat(s))
	var has_glow := false
	for ix in range(w):
		for iz in range(d):
			var i0 := ix + iz * w
			var open := true
			for si in range((H - 1) >> 4, -1, -1):
				var lo := si * 16
				var c_hi: int = mini(16, H - lo)
				var dv: PackedByteArray = dviews[si]
				var hasv: bool = dv.size() > 0
				var cy := c_hi - 1
				while cy >= 0:
					var y: int = lo + cy
					var b: int = 0
					if hasv:
						b = int(dv[(cy << 8) | (iz << 4) | ix])
					if y > mx.y:
						if open and _att[b] == 0:
							open = false
						cy -= 1
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
					cy -= 1
	_flood_flat(sky, ids, w, h, d)
	if has_glow:
		_flood_flat(blk, ids, w, h, d)
	var eff := PackedByteArray()
	eff.resize(sz * h)
	for i in range(eff.size()):
		var s := sky[i]
		var b2 := blk[i]
		eff[i] = s if s >= b2 else b2
	return eff


static func compute_light_flat_chunk(data, cx: int, cz: int, h: int) -> Dictionary:
	_tables()
	var sz := 16 * 16
	var ids := PackedByteArray()
	ids.resize(sz * h)
	var sky := PackedByteArray()
	sky.resize(sz * h)
	var blk := PackedByteArray()
	blk.resize(sz * h)
	var eff := _chunk_light_into(data, cx, cz, h, ids, sky, blk)
	return {"mn": Vector3i(cx * 16, 0, cz * 16), "w": 16, "d": 16, "arr": eff}


# AC-0129: single-chunk light with cross-boundary block-light PULL (Minecraft
# semantics, user-directed — the web's own floodLight never lights a dark
# chunk, index.html:974; deviation (iii)). Column scan IDENTICAL to
# _chunk_light_into; ONE combined flood (eff = max(sky, blk) seeds —
# max-distributivity keeps the local closure byte-identical to the contained
# two-flood kernel) + ONE blk-only UN-gated injection from the neighbor blk
# strips, re-flood if any cell was raised. blk_strips = 4 side strips
# [E,W,N,S], 2 cols x 16 x h, idx = c*(16*h) + y*16 + t (c=0 the cell directly
# across the boundary; t = our z for E/W, our x for S/N); empty/short strip =
# that side stays as its own flood left it. eff_strips rides along for the
# caller's 20x20 bake box (unused here).
static func compute_light_flat_chunk_pull(data, cx: int, cz: int, h: int, eff_strips: Array, blk_strips: Array, blk_strips_b: Array, top := -1, dviews: Variant = null) -> Dictionary:
	# AC-0197: rows above the column's top (max non-air y) are ALL air — open
	# sky, so eff == 15 there and nothing below can raise them above 15. The
	# scan/floods run only on rows 0..top (block glow bleeds 14 up from a
	# source, so the blk/mask pass runs to top+14); eff rows above top are
	# filled 15 directly (byte-identical to the full scan).
	# AC-0203: data is the 24-slab array; the column scan (still per-column,
	# still top-down, open carried across slab boundaries) reads per-slab
	# flat views — byte-identical to the flat kernel. dviews (optional) is a
	# pre-materialized view set (build_accs shares one set with its face
	# loop); null = materialize from data.
	if dviews == null:
		dviews = []
		for s in data:
			dviews.append(ChunkIO._slab_flat(s))
	var sz := 16 * 16
	var hact := h
	var hblk := h
	if top >= 0:
		hact = top + 1
		hblk = mini(h, top + 15)
	var ids := PackedByteArray()
	ids.resize(sz * h)
	var sky := PackedByteArray()
	sky.resize(sz * h)
	var blk := PackedByteArray()
	blk.resize(sz * h)
	var has_glow := false
	var s_top: int = maxi(0, (hact - 1) >> 4)
	for ix in range(16):
		for iz in range(16):
			var i0 := ix + iz * 16
			var open := true
			for si in range(s_top, -1, -1):
				var lo := si * 16
				var c_hi: int = mini(16, hact - lo)
				if c_hi <= 0:
					continue
				var dv: PackedByteArray = dviews[si]
				var hasv: bool = dv.size() > 0
				var cy := c_hi - 1
				while cy >= 0:
					var y: int = lo + cy
					var b: int = 0
					if hasv:
						b = int(dv[(cy << 8) | (iz << 4) | ix])
					var i := y * sz + i0
					ids[i] = b
					if open and _att[b] > 0:
						sky[i] = SKY_FULL
					var lv := _glow[b]
					if lv > 0:
						blk[i] = lv
						has_glow = true
					if open and _att[b] == 0:
						open = false
					cy -= 1
	var eff := PackedByteArray()
	eff.resize(sz * h)
	for y in range(hact, h):
		var row := y * sz
		for x in range(sz):
			eff[row + x] = SKY_FULL
	for i in range(sz * hact):
		var s := sky[i]
		var b2 := blk[i]
		eff[i] = s if s >= b2 else b2
	_flood_flat(eff, ids, 16, h, 16, hact)
	if _chunk_blk_inject(eff, ids, h, blk_strips, hact):
		_flood_flat(eff, ids, 16, h, 16, hact)
	# AC-0128 RUN 3: block-light VISITED mask (mask=1 iff the blk flood
	# reached the cell — own glow sources + neighbor blk-strip injection,
	# EXACTLY the seeds the eff got). Replaces the per-bake Chebyshev-14
	# distance transform in chunk.gd: exact (no over-bright mouths — a
	# walled-off source does not visit; cross-boundary sources DO visit via
	# the strips — the dark-side miss is gone) and far cheaper (one seeded
	# scan + small BFS vs 6 full-array sweeps). Transient: rides the light
	# dict for the bake + bounded eff cache, freed after; materialized only
	# when something actually lit (else a zero-filled buffer, C-level fill).
	# The mask flood seeds on the BLOCK-ONLY strip companion (no sky floor):
	# visited => block-derived. The eff strip above carries the sky floor
	# (AC-0129) so the same values would over-mark sky-carry cells.
	# AC-0197: the own-glow flood is truncated (glow sources sit at y <= top,
	# attenuation >= 1/step, so blk is 0 above top+14 — the flood cannot reach
	# further). The IMPORTED light (neighbor strip) may carry block light above
	# our top (a tall neighbor's torch), so the inject/re-flood/mask stay full
	# height — the mask is byte-identical to the pre-AC-0197 kernel.
	var blk_inj := false
	if has_glow:
		_flood_flat(blk, ids, 16, h, 16, hblk)
	blk_inj = _chunk_blk_inject(blk, ids, h, blk_strips_b)
	if blk_inj:
		_flood_flat(blk, ids, 16, h, 16)
	var mask := PackedByteArray()
	mask.resize(sz * h)
	var ring := PackedInt32Array()
	if has_glow or blk_inj:
		for i in range(sz * h):
			mask[i] = 1 if blk[i] > 0 else 0
		# AC-0128 RUN 3: the SPARSE boundary block-light RING - only the LIT
		# boundary cells, 4 sides x 16*h. The TRUE flooded block light at our
		# own boundary columns (own sources + cross-boundary, transitive),
		# persisted per chunk (a few hundred bytes for a lava chunk, 0 for a
		# sky-only chunk - memory fence r50). AC-0134: the face mask
		# (_compute_face_blk) supersedes this ring as the live carrier; the
		# ring is retained (write-only) for provenance.
		# AC-0091 re-derived pack (the old (side<<16)|(yy<<8)|level collided:
		# yy = y*16+t reaches 6143 = 13 bits at H=384, overlapping the side
		# field): (side << 17) | (yy << 4) | level — level 4 bits (0-15),
		# yy 13 bits (0-8191, h up to 512), side 2 bits (0-3); 19 bits total.
		for y in range(h):
			var row := y << 8
			for t in range(16):
				var yy := y * 16 + t
				var lv0: int = blk[row | (t << 4) | 15]
				if lv0 > 0:
					ring.append((0 << 17) | (yy << 4) | lv0)
				var lv1: int = blk[row | (t << 4)]
				if lv1 > 0:
					ring.append((1 << 17) | (yy << 4) | lv1)
				var lv2: int = blk[row | (15 << 4) | t]
				if lv2 > 0:
					ring.append((2 << 17) | (yy << 4) | lv2)
				var lv3: int = blk[row | t]
				if lv3 > 0:
					ring.append((3 << 17) | (yy << 4) | lv3)
	return {"mn": Vector3i(cx * 16, 0, cz * 16), "w": 16, "d": 16, "arr": eff, "blk_src": has_glow, "mask": mask, "ring": ring}


# AC-0129: the one boundary injection (per side [E,W,N,S]). UN-gated:
# cand = strip[c0] - att[own boundary cell]; raise when cand > eff. The
# eff>0 gate is deliberately ABSENT (RUN 1.1 correction — it would exclude
# the 13-next-to-0 case); sky-leak prevention lives in the strip content
# (blk is 0 under open sky / behind sky), not in a gate.
static func _chunk_blk_inject(eff: PackedByteArray, ids: PackedByteArray, h: int, blk_strips: Array, hgate := -1) -> bool:
	if blk_strips.size() < 4:
		return false
	var changed := false
	var hrow := h if hgate < 0 else hgate
	for si in range(4):
		var strip: PackedByteArray = blk_strips[si]
		# AC-0091: side strip = 2 cols x 16 x h (was hard-coded 2560 = H=80).
		if strip == null or strip.size() != 2 * 16 * h:
			continue
		for y in range(hrow):
			var row := y * 256
			var srow := y * 16
			for t in range(16):
				var B: int
				match si:
					0:
						B = row + t * 16 + 15
					1:
						B = row + t * 16
					2:
						B = row + 15 * 16 + t
					_:
						B = row + t
				if _att[ids[B]] > 0:
					var cand: int = strip[srow + t] - _att[ids[B]]
					if cand > eff[B]:
						eff[B] = cand
						changed = true
	return changed


# AC-0077: batched per-chunk contained light — one call for N fresh data
# copies, per-chunk eff byte-identical to compute_light_flat_chunk (same
# kernel, same box, same data; the contained flood reads nothing outside its
# 16x16xh box, so margin 0 is exact and no union flood is possible). ids/sky/
# blk are preallocated once and reused; eff is fresh per item.
# budget_us: stop after the first chunk once the elapsed compute time passes
# it (the caller keeps the remaining items for a later drain call — they are
# still in its want set). 0 = no budget.
static func compute_light_flat_batch(items: Array, budget_us: int = 0) -> Array:
	_tables()
	var out: Array = []
	if items.is_empty():
		return out
	var sz := 16 * 16
	var ids := PackedByteArray()
	ids.resize(sz * Data.HEIGHT)
	var sky := PackedByteArray()
	sky.resize(sz * Data.HEIGHT)
	var blk := PackedByteArray()
	blk.resize(sz * Data.HEIGHT)
	var st0 := Time.get_ticks_usec()
	for it in items:
		if budget_us > 0 and not out.is_empty() and Time.get_ticks_usec() - st0 > budget_us:
			break
		var data = it["data"]
		var h := Data.HEIGHT
		sky.fill(0)
		blk.fill(0)
		var eff := _chunk_light_into(data, int(it["cx"]), int(it["cz"]), h, ids, sky, blk)
		out.append({"mn": Vector3i(int(it["cx"]) * 16, 0, int(it["cz"]) * 16), "w": 16, "d": 16, "arr": eff})
	return out


static func _flood_flat(src: PackedByteArray, ids: PackedByteArray, w: int, h: int, d: int, hact := -1) -> void:
	# AC-0197: hact = active row count (rows 0..hact-1). Cells at or above
	# hact are never seeded nor stepped into (their values are final by the
	# caller's proof: eff rows above top are 15; block glow cannot reach
	# above top+14). Omitted (default) = full height, byte-identical to before.
	var sz := w * d
	var rows := h if hact < 0 else mini(hact, h)
	var size := sz * rows
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
		if not spr and yy + 1 < rows:
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
			if yy + 1 < rows:
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


