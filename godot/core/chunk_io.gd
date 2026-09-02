class_name ChunkIO
extends RefCounted
# AC-0155: full-column save codec (Bedrock LevelDB / Java region style).
# One 16xHx16 column = 24 subchunks of palette + bitpack, plus the fl level
# array, zlib-deflate compressed, versioned, seed/height stamped, MD5 checked.
# Pure static: no node deps, worker-safe, no Data/Game access (height is
# derived from the array size and passed in).

const VERSION := 3
const V2_VERSION := 2  # AC-0156 dense+light (decodable, never written)
const LEGACY_VERSION := 1
# Godot 4.7 has no GDScript-visible CompressionMode global; int 0 =
# CompressionMode.COMPRESSION_SPEED (zlib-deflate, fastest level).
const MODE := 0
const S := 16
const S3 := 4096
const M0 := 65
const M1 := 87
const M2 := 67
const M3 := 67
const NIB_PER_SECTION := S3 / 2

static func dir_for(slot: int) -> String:
	return "user://chunkdir_%d" % int(slot)

static func path_for(slot: int, face: int, cx: int, cz: int) -> String:
	return "%s/%d_%d_%d.bin" % [dir_for(int(slot)), int(face), int(cx), int(cz)]

static func ensure_dir(slot: int) -> void:
	var abs := ProjectSettings.globalize_path(dir_for(int(slot)))
	if not DirAccess.dir_exists_absolute(abs):
		DirAccess.make_dir_recursive_absolute(abs)

static func clear_dir(slot: int) -> void:
	var d := dir_for(int(slot))
	var abs := ProjectSettings.globalize_path(d)
	if not DirAccess.dir_exists_absolute(abs):
		return
	var da := DirAccess.open(abs)
	if da == null:
		return
	da.list_dir_begin()
	var fn := da.get_next()
	while fn != "":
		if not da.current_is_dir():
			DirAccess.remove_absolute(abs.path_join(fn))
		fn = da.get_next()
	da.list_dir_end()
	DirAccess.remove_absolute(abs)

static func encode_column(data: PackedByteArray, fl: PackedByteArray, seed: int, height: int, light: Dictionary = {}, top := -1) -> PackedByteArray:
	var sub := int(data.size()) / S3
	# AC-0197: the v3 sparse slab layout. Slabs above top are all-air (the
	# caller's column top); absent slabs are omitted entirely (~40% of the
	# block/fl section at H=384). top < 0 = unknown -> scan the data.
	if top < 0:
		top = _column_top(data, sub)
	var blob := _encode_head(VERSION, data, fl, seed, height, sub, top)
	var li := _encode_light(light, sub)
	blob.append_array(_u32(li.size()))
	blob.append_array(li)
	return _encode_tail(blob)

static func encode_column_legacy(data: PackedByteArray, fl: PackedByteArray, seed: int, height: int) -> PackedByteArray:
	var sub := int(data.size()) / S3
	var blob := _encode_head(LEGACY_VERSION, data, fl, seed, height, sub, -1)
	return _encode_tail(blob)

static func _encode_head(ver: int, data: PackedByteArray, fl: PackedByteArray, seed: int, height: int, sub: int, top: int) -> PackedByteArray:
	var blob := PackedByteArray()
	blob.append(M0)
	blob.append(M1)
	blob.append(M2)
	blob.append(M3)
	blob.append(ver)
	blob.append_array(_u32(seed))
	blob.append_array(_u16(height))
	blob.append_array(_u16(sub))
	# AC-0197: v3 = sparse slab sections (offset table of non-null slabs);
	# v1/v2 keep the dense _encode_array layout (back-compat).
	if ver == VERSION:
		var de := _encode_array_sparse(data, sub, top)
		blob.append_array(_u32(de.size()))
		blob.append_array(de)
		var fe := _encode_array_sparse(fl, sub, top)
		blob.append_array(_u32(fe.size()))
		blob.append_array(fe)
	else:
		var de := _encode_array(data, sub)
		blob.append_array(_u32(de.size()))
		blob.append_array(de)
		var fe := _encode_array(fl, sub)
		blob.append_array(_u32(fe.size()))
		blob.append_array(fe)
	return blob

static func _encode_tail(blob: PackedByteArray) -> PackedByteArray:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_MD5)
	h.update(blob)
	blob.append_array(h.finish())
	var comp := blob.compress(MODE)
	var out := PackedByteArray()
	out.append_array(_u32(blob.size()))
	out.append_array(comp)
	return out

static func _encode_light(light: Dictionary, sub: int) -> PackedByteArray:
	var out := PackedByteArray()
	var arr: PackedByteArray = light.get("arr", PackedByteArray())
	var mask: PackedByteArray = light.get("mask", PackedByteArray())
	var want := sub * S3
	if arr.size() != want or mask.size() != want:
		out.append(0)
		return out
	out.append(1)
	out.append(1 if bool(light.get("blk_src", false)) else 0)
	var nib := _nibble_pack(arr)
	out.append_array(_u32(nib.size()))
	out.append_array(nib)
	var mib := _nibble_pack(mask)
	out.append_array(_u32(mib.size()))
	out.append_array(mib)
	return out

static func decode_column(file_bytes: PackedByteArray, seed: int, height: int) -> Dictionary:
	var fail := {}
	if file_bytes.size() < 8:
		return fail
	var usize := _u32r(file_bytes, 0)
	if usize <= 0 or usize > 1048576:
		return fail
	var comp := file_bytes.slice(4)
	if comp.is_empty():
		return fail
	var blob := comp.decompress(usize, MODE)
	if blob.size() != usize:
		return fail
	if blob.size() < 17:
		return fail
	if blob[0] != M0 or blob[1] != M1 or blob[2] != M2 or blob[3] != M3:
		return fail
	var ver := int(blob[4])
	if ver != LEGACY_VERSION and ver != V2_VERSION and ver != VERSION:
		return fail
	if _u32r(blob, 5) != int(seed):
		return fail
	var h := _u16r(blob, 9)
	if h != int(height):
		return fail
	var sub := _u16r(blob, 11)
	if sub != h / S:
		return fail
	var de_size := _u32r(blob, 13)
	var de_at := 17
	var fe_sz_at := de_at + de_size
	if fe_sz_at + 4 > blob.size():
		return fail
	var fe_size := _u32r(blob, fe_sz_at)
	var fe_at := fe_sz_at + 4
	var light: Dictionary = {}
	var md5_at := 0
	if ver == LEGACY_VERSION:
		md5_at = fe_at + fe_size
		if md5_at + 16 != blob.size():
			return fail
	else:
		if fe_at + fe_size + 4 + 16 > blob.size():
			return fail
		var li_size := _u32r(blob, fe_at + fe_size)
		if fe_at + fe_size + 4 + li_size + 16 != blob.size():
			return fail
		var li := blob.slice(fe_at + fe_size + 4, fe_at + fe_size + 4 + li_size)
		light = _decode_light(li, sub)
		md5_at = fe_at + fe_size + 4 + li_size
	var dr = _decode_array_sparse(blob, de_at, sub) if ver == VERSION else _decode_array(blob, de_at, sub)
	var fr = _decode_array_sparse(blob, fe_at, sub) if ver == VERSION else _decode_array(blob, fe_at, sub)
	if int(dr["off"]) != fe_sz_at:
		return fail
	if int(fr["off"]) != fe_at + fe_size:
		return fail
	var h2 := HashingContext.new()
	h2.start(HashingContext.HASH_MD5)
	h2.update(blob.slice(0, md5_at))
	if h2.finish() != blob.slice(md5_at, md5_at + 16):
		return fail
	if int(dr["arr"].size()) != int(height) * S * S:
		return fail
	var res := {"data": dr["arr"], "fl": fr["arr"]}
	if not light.is_empty():
		res["light"] = light
	return res

static func _decode_light(li: PackedByteArray, sub: int) -> Dictionary:
	var fail := {}
	var want := sub * S3
	var nib_size := NIB_PER_SECTION * sub
	if li.size() < 2:
		return fail
	if li[0] != 1:
		return fail
	var blk_src := li[1] != 0
	var o := 2
	if o + 4 + nib_size + 4 + nib_size != li.size():
		return fail
	if _u32r(li, o) != nib_size:
		return fail
	o += 4
	var arr := _nibble_unpack(li.slice(o, o + nib_size), want)
	o += nib_size
	if _u32r(li, o) != nib_size:
		return fail
	o += 4
	var mask := _nibble_unpack(li.slice(o, o + nib_size), want)
	if o + nib_size != li.size():
		return fail
	return {"arr": arr, "mask": mask, "blk_src": blk_src}

static func _encode_array(arr: PackedByteArray, sub: int) -> PackedByteArray:
	var out := PackedByteArray()
	var lut := []
	lut.resize(256)
	var order := []
	var vals := PackedByteArray()
	vals.resize(S3)
	for s in range(sub):
		for i in range(256):
			lut[i] = -1
		order.clear()
		var base := s * S3
		var i := 0
		while i < S3:
			var v: int = arr[base + i]
			var idx: int = lut[v]
			if idx < 0:
				idx = order.size()
				lut[v] = idx
				order.append(v)
			vals[i] = idx
			i += 1
		var n: int = order.size()
		var bits := _bits_for(n)
		out.append(n)
		out.append(bits)
		for v in order:
			out.append(v)
		if n == 1:
			# Uniform subchunk: every index is 0, so the bitpack is all-zero
			# bytes. Skip the 4096-iteration packer (air/stone/bedrock bulk).
			var z := PackedByteArray()
			z.resize((S3 * bits + 7) / 8)
			out.append_array(z)
		else:
			out.append_array(_bitpack(vals, bits))
	return out

static func _decode_array(blob: PackedByteArray, off: int, sub: int) -> Dictionary:
	var out := PackedByteArray()
	out.resize(sub * S3)
	var o := off
	for s in range(sub):
		var n := blob[o]
		o += 1
		var bits := blob[o]
		o += 1
		var order := []
		var i := 0
		while i < n:
			order.append(blob[o])
			o += 1
			i += 1
		var nbytes := (S3 * bits + 7) / 8
		var base := s * S3
		if n == 1:
			var fillv: int = order[0]
			i = 0
			while i < S3:
				out[base + i] = fillv
				i += 1
		else:
			var packed := blob.slice(o, o + nbytes)
			var idx := _bitunpack(packed, bits, S3)
			i = 0
			while i < S3:
				out[base + i] = order[int(idx[i])]
				i += 1
		o += nbytes
	return {"arr": out, "off": o}

# AC-0197: max y holding any non-zero byte (the column top), -1 if all
# air. Scans top-down with a row early-out; O(256 * empty-rows).
static func _column_top(data: PackedByteArray, sub: int) -> int:
	var t := -1
	var y := sub * S - 1
	while y >= 0:
		var row := y << 8
		var i := 0
		while i < S * S:
			if data[row + i] != 0:
				t = y
				break
			i += 1
		if t >= 0:
			break
		y -= 1
	return t

# AC-0197: sparse slab layout. u8 present-count + present u16 slab indices
# (ascending) + the standard self-delimiting per-slab payloads (n, bits,
# order, bitpack) in the same order. Absent slabs (all-air — always true
# above top, scanned otherwise) are omitted; the decoder zero-fills them,
# so a v3 blob round-trips to the exact dense array (lossless).
static func _encode_array_sparse(arr: PackedByteArray, sub: int, top: int) -> PackedByteArray:
	var out := PackedByteArray()
	var lut := []
	lut.resize(256)
	var order := []
	var vals := PackedByteArray()
	vals.resize(S3)
	var idxs: Array = []
	var s := 0
	while s < sub:
		var present_s := true
		if top >= 0 and s > top / S:
			present_s = false
		else:
			var base0 := s * S3
			var i := 0
			while i < S3:
				if arr[base0 + i] != 0:
					break
				i += 1
			if i >= S3:
				present_s = false
		if present_s:
			idxs.append(s)
		s += 1
	out.append(idxs.size())
	for si in idxs:
		out.append_array(_u16(int(si)))
	for si2 in idxs:
		for i in range(256):
			lut[i] = -1
		order.clear()
		var base := int(si2) * S3
		var i := 0
		while i < S3:
			var v: int = arr[base + i]
			var idx: int = lut[v]
			if idx < 0:
				idx = order.size()
				lut[v] = idx
				order.append(v)
			vals[i] = idx
			i += 1
		var n: int = order.size()
		var bits := _bits_for(n)
		out.append(n)
		out.append(bits)
		for v in order:
			out.append(v)
		if n == 1:
			var z := PackedByteArray()
			z.resize((S3 * bits + 7) / 8)
			out.append_array(z)
		else:
			out.append_array(_bitpack(vals, bits))
	return out

# AC-0197: inverse of _encode_array_sparse. Fail-closed: any structural
# violation (count, index range/duplication, palette/bit consistency,
# truncated payload) returns an empty arr at off 0 -> the caller rejects.
static func _decode_array_sparse(blob: PackedByteArray, off: int, sub: int) -> Dictionary:
	var faild := PackedByteArray()
	var out := PackedByteArray()
	out.resize(sub * S3)
	var o := off
	if o >= blob.size():
		return {"arr": faild, "off": 0}
	var np := blob[o]
	o += 1
	if np > sub:
		return {"arr": faild, "off": 0}
	var idxs: Array = []
	var i := 0
	while i < np:
		if o + 1 >= blob.size():
			return {"arr": faild, "off": 0}
		var si := _u16r(blob, o)
		o += 2
		if si < 0 or si >= sub or idxs.has(si):
			return {"arr": faild, "off": 0}
		idxs.append(si)
		i += 1
	i = 0
	while i < np:
		var si2 := int(idxs[i])
		if o + 1 >= blob.size():
			return {"arr": faild, "off": 0}
		var n := blob[o]
		o += 1
		var bits := blob[o]
		o += 1
		if n <= 0 or n > 256 or bits < 1 or bits > 8 or (1 << bits) < n:
			return {"arr": faild, "off": 0}
		if o + n > blob.size():
			return {"arr": faild, "off": 0}
		var order := []
		var j := 0
		while j < n:
			order.append(blob[o])
			o += 1
			j += 1
		var nbytes := (S3 * bits + 7) / 8
		if o + nbytes > blob.size():
			return {"arr": faild, "off": 0}
		var base := si2 * S3
		if n == 1:
			var fillv: int = order[0]
			j = 0
			while j < S3:
				out[base + j] = fillv
				j += 1
		else:
			var packed := blob.slice(o, o + nbytes)
			var idx := _bitunpack(packed, bits, S3)
			j = 0
			while j < S3:
				out[base + j] = order[int(idx[j])]
				j += 1
		o += nbytes
		i += 1
	return {"arr": out, "off": o}

static func _bits_for(n: int) -> int:
	var b := 1
	while (1 << b) < n:
		b += 1
	return b

static func _bitpack(vals: PackedByteArray, bits: int) -> PackedByteArray:
	var n: int = vals.size()
	var out := PackedByteArray()
	out.resize((n * bits + 7) / 8)
	var cur := 0
	var bitpos := 0
	var bytepos := 0
	var i := 0
	while i < n:
		cur = (cur << bits) | int(vals[i])
		bitpos += bits
		while bitpos >= 8:
			bitpos -= 8
			out[bytepos] = (cur >> bitpos) & 255
			bytepos += 1
			cur &= (1 << bitpos) - 1
		i += 1
	if bitpos > 0:
		out[bytepos] = cur & ((1 << bitpos) - 1)
	return out

static func _bitunpack(packed: PackedByteArray, bits: int, n: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(n)
	var cur := 0
	var bitpos := 0
	var bytepos := 0
	var mask := (1 << bits) - 1
	var i := 0
	while i < n:
		while bitpos < bits:
			cur = (cur << 8) | int(packed[bytepos])
			bytepos += 1
			bitpos += 8
		out[i] = (cur >> (bitpos - bits)) & mask
		bitpos -= bits
		cur &= (1 << bitpos) - 1
		i += 1
	return out

static func _u32(v: int) -> PackedByteArray:
	return PackedByteArray([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255])

static func _u16(v: int) -> PackedByteArray:
	return PackedByteArray([v & 255, (v >> 8) & 255])

static func _u32r(b: PackedByteArray, o: int) -> int:
	return int(b[o]) | (int(b[o + 1]) << 8) | (int(b[o + 2]) << 16) | (int(b[o + 3]) << 24)

static func _u16r(b: PackedByteArray, o: int) -> int:
	return int(b[o]) | (int(b[o + 1]) << 8)

static func _nibble_pack(vals: PackedByteArray) -> PackedByteArray:
	var n: int = vals.size()
	var out := PackedByteArray()
	out.resize(n / 2)
	var i := 0
	while i + 1 < n:
		out[i >> 1] = (int(vals[i]) & 15) | ((int(vals[i + 1]) & 15) << 4)
		i += 2
	if (n & 1) == 1:
		out[(n - 1) >> 1] = int(vals[n - 1]) & 15
	return out

static func _nibble_unpack(nib: PackedByteArray, n: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(n)
	var i := 0
	while i + 1 < n:
		var b: int = nib[i >> 1]
		out[i] = b & 15
		out[i + 1] = (b >> 4) & 15
		i += 2
	if (n & 1) == 1:
		out[n - 1] = int(nib[(n - 1) >> 1]) & 15
	return out
