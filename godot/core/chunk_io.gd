class_name ChunkIO
extends RefCounted
# AC-0155: full-column save codec (Bedrock LevelDB / Java region style).
# One 16xHx16 column = 24 subchunks of palette + bitpack, plus the fl level
# array, zlib-deflate compressed, versioned, seed/height stamped, MD5 checked.
# Pure static: no node deps, worker-safe, no Data/Game access (height is
# derived from the array size and passed in).

const VERSION := 4
const V3_VERSION := 3  # AC-0197 sparse slabs (decodable, never written)
const V2_VERSION := 2  # AC-0156 dense+light (decodable, never written)
const LEGACY_VERSION := 1
# Godot 4.7 has no GDScript-visible CompressionMode global; int 0 =
# CompressionMode.COMPRESSION_SPEED (zlib-deflate, fastest level).
const MODE := 0
const S := 16
const S3 := 4096
# AC-0208: the v4 paletted slab DECODE is C++-only (gdext/src/chunk_io.cpp —
# ChunkIOPalette.decode_slabs, byte-identical to the removed GDScript
# _decode_slabs_v4, verified by the chunkiocpp arm). The game requires the
# extension (Game._ready fails fast if it is missing); io_cpp() never returns
# a silent null. cpp_slab_decodes counts runtime C++ slab decodes (the
# nofallback arm asserts it after a disk round-trip).
static var _io_cpp: Variant = null
static var _io_cpp_done := false
static var cpp_slab_decodes := 0
# AC-0214: runtime C++ slab-op counters. slab_cpp_sets counts the C++
# single-cell writes (chunk.gd _slab_write -> ChunkIOPalette.slab_set — the
# per-block edit op); the nofallback arm asserts it advances (the torch
# placement proves the C++ write lane ran). slab_gd_write_calls is the
# no-fallback sentinel: the GDScript _slab_write_gd body (chunk.gd) survives
# only as the slabops A/B reference — any game-side call trips it.
static var slab_cpp_sets := 0
static var slab_gd_write_calls := 0

static func io_cpp() -> Variant:
	if not _io_cpp_done:
		_io_cpp_done = true
		if ClassDB.class_exists("ChunkIOPalette"):
			_io_cpp = ClassDB.instantiate("ChunkIOPalette")
		else:
			push_error("AWECRAFT: ChunkIOPalette C++ class not registered — the gdext library is missing (AC-0208: the C++ extension is REQUIRED, no GDScript decode fallback).")
	return _io_cpp
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
	# AC-0203: v4 = sparse + PER-SLAB PALETTE (n, bits, palette, packed;
	# n==1 omits the packed, n==0 = raw 8-bit slab for >16 unique ids);
	# v1/v2 keep the dense _encode_array layout (back-compat).
	if ver == VERSION:
		var de := _encode_array_v4(data, sub, top)
		blob.append_array(_u32(de.size()))
		blob.append_array(de)
		var fe := _encode_array_v4(fl, sub, top)
		blob.append_array(_u32(fe.size()))
		blob.append_array(fe)
	elif ver == V3_VERSION:
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
	if ver != LEGACY_VERSION and ver != V2_VERSION and ver != V3_VERSION and ver != VERSION:
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
	var dr = _decode_array_v4(blob, de_at, sub) if ver == VERSION else (_decode_array_sparse(blob, de_at, sub) if ver == V3_VERSION else _decode_array(blob, de_at, sub))
	var fr = _decode_array_v4(blob, fe_at, sub) if ver == VERSION else (_decode_array_sparse(blob, fe_at, sub) if ver == V3_VERSION else _decode_array(blob, fe_at, sub))
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
	if ver == VERSION:
		# AC-0203 recenter fix: the v4 disk handoff lands the slab array
		# directly (the wire form IS the slab form) — the main thread skips
		# the flat expansion + re-palettize (~35 ms/col). The flat arrays
		# stay in res for the v1-v3 path, the chunkio arm, and probes.
		# AC-0208: the slab decode is the C++ ChunkIOPalette (the GDScript
		# _decode_slabs_v4 was removed — no fallback).
		var ds: Dictionary = io_cpp().decode_slabs(blob, de_at, sub)
		var fs: Dictionary = io_cpp().decode_slabs(blob, fe_at, sub)
		cpp_slab_decodes += 2
		if int(ds["off"]) != fe_sz_at or int(fs["off"]) != fe_at + fe_size:
			return fail
		res["d_slabs"] = ds["slabs"]
		res["f_slabs"] = fs["slabs"]
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

# AC-0203: v4 sparse paletted slabs. Same presence table as v3 (u8 count +
# u16 ascending slab idx) with a per-slab payload: [n, bits, palette(n),
# packed]. n==1 = uniform (bits 0, no packed — the 512 B zero-pack of v3 is
# gone); n==2..16 = paletted (bits = _slab_bits_for(n), packed = bits*4096
# bits MSB-first over palette INDICES); n==0 = raw 8-bit slab (bits 8, 4096
# raw bytes — the >16-unique-ids fallback, lossless by construction).
# Absent slabs are zero-filled by the decoder, so v4 round-trips to the
# exact dense array (lossless).
static func _encode_array_v4(arr: PackedByteArray, sub: int, top: int) -> PackedByteArray:
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
			if lut[v] < 0:
				lut[v] = order.size()
				order.append(v)
			i += 1
		order.sort()
		var n: int = order.size()
		if n <= 16:
			var remap := []
			remap.resize(n)
			var j := 0
			while j < n:
				remap[lut[order[j]]] = j
				j += 1
			for i2 in range(256):
				lut[i2] = -1
			j = 0
			while j < n:
				lut[order[j]] = j
				j += 1
			i = 0
			while i < S3:
				vals[i] = lut[arr[base + i]]
				i += 1
			out.append(n)
			if n == 1:
				out.append(0)
				out.append(order[0])
			else:
				var bits := _slab_bits_for(n)
				out.append(bits)
				for v in order:
					out.append(v)
				out.append_array(_bitpack(vals, bits))
		else:
			out.append(0)
			out.append(8)
			out.append_array(arr.slice(base, base + S3))
	return out


static func _decode_array_v4(blob: PackedByteArray, off: int, sub: int) -> Dictionary:
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
		var base := si2 * S3
		if n == 0:
			if bits != 8 or o + S3 > blob.size():
				return {"arr": faild, "off": 0}
			var raw := blob.slice(o, o + S3)
			var j := 0
			while j < S3:
				out[base + j] = raw[j]
				j += 1
			o += S3
		elif n == 1:
			if bits != 0 or o + 1 > blob.size():
				return {"arr": faild, "off": 0}
			var fillv: int = blob[o]
			o += 1
			var j := 0
			while j < S3:
				out[base + j] = fillv
				j += 1
		else:
			if n > 16 or bits != _slab_bits_for(n) or o + n > blob.size():
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
			var packed := blob.slice(o, o + nbytes)
			var idx := _bitunpack(packed, bits, S3)
			j = 0
			while j < S3:
				out[base + j] = order[int(idx[j])]
				j += 1
			o += nbytes
		i += 1
	return {"arr": out, "off": o}

# AC-0208: the GDScript v4 slab decode (_decode_slabs_v4 + _slab_nz +
# _popcount1/2) was REMOVED — the runtime slab decode is the C++
# ChunkIOPalette.decode_slabs (see io_cpp() above), byte-identical (the
# chunkiocpp arm compares the C++ decode against the runtime decode_column
# handoff).

# AC-0203: in-memory slab representation (the runtime twin of the v4 wire
# form). A slab is null (all air) or a Dictionary {n, b, p, i, nz}:
#   n==1  uniform  — p[0] is the value, i empty, b 0
#   n>=2  paletted — p holds n ids, i holds b*4096 bits (MSB-first) of
#          palette INDICES, b = _slab_bits_for(n)
#   n==0  raw      — i holds the 4096 cell values directly, b 8
# nz = count of non-zero cells (top scans, null-ification, sparse fluid).
# Pure static + worker-safe (no Data/Game) — the same code the codec uses.

static func _slab_bits_for(n: int) -> int:
	var b := 0
	while (1 << b) < n:
		b += 1
	return b


static func _slab_getbits(i: PackedByteArray, bits: int, pos: int) -> int:
	var bo: int = (pos * bits) >> 3
	var sh: int = (pos * bits) & 7
	var w: int = int(i[bo]) << 8
	if bo + 1 < i.size():
		w |= int(i[bo + 1])
	return (w >> (16 - sh - bits)) & ((1 << bits) - 1)


static func _slab_setbits(i: PackedByteArray, bits: int, pos: int, val: int) -> void:
	var bo: int = (pos * bits) >> 3
	var sh: int = (pos * bits) & 7
	var w: int = int(i[bo]) << 8
	if bo + 1 < i.size():
		w |= int(i[bo + 1])
	var mask: int = (1 << bits) - 1
	var sb: int = 16 - sh - bits
	w = (w & ~(mask << sb)) | (val << sb)
	i[bo] = (w >> 8) & 255
	if bo + 1 < i.size():
		i[bo + 1] = w & 255


static func _slab_cell(s: Dictionary, pos: int) -> int:
	var n: int = int(s["n"])
	if n == 1:
		return int(s["p"][0])
	if n == 0:
		return int(s["i"][pos])
	return int(s["p"][_slab_getbits(s["i"], int(s["b"]), pos)])


static func _slab_unpack(i: PackedByteArray, bits: int, p: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(S3)
	if bits == 1:
		var j := 0
		for k in range(i.size()):
			var b: int = i[k]
			for r in range(8):
				out[j] = p[(b >> (7 - r)) & 1]
				j += 1
	elif bits == 2:
		var j := 0
		for k in range(i.size()):
			var b: int = i[k]
			for r in range(4):
				out[j] = p[(b >> (6 - r * 2)) & 3]
				j += 1
	elif bits == 3:
		var j := 0
		var k := 0
		var nb: int = i.size()
		while j < S3:
			var w: int = int(i[k]) << 16
			if k + 1 < nb:
				w |= int(i[k + 1]) << 8
			if k + 2 < nb:
				w |= int(i[k + 2])
			for r in range(8):
				out[j] = p[(w >> (21 - r * 3)) & 7]
				j += 1
			k += 3
	elif bits == 4:
		var j := 0
		for k in range(i.size()):
			var b: int = i[k]
			out[j] = p[(b >> 4) & 15]
			out[j + 1] = p[b & 15]
			j += 2
	else:
		var j := 0
		while j < S3:
			out[j] = p[_slab_getbits(i, bits, j)]
			j += 1
	return out


# AC-0203 recenter fix: an all-null slab array of nsl slabs (the gen
# landing's fl half — gen produces no fluid). Replaces a 98 KB zero-fill +
# palettize scan on the worker.
static func empty_slabs(nsl: int) -> Array:
	var out: Array = []
	var i := 0
	while i < nsl:
		out.append(null)
		i += 1
	return out


static func _slab_flat(s) -> PackedByteArray:
	if s == null:
		return PackedByteArray()
	var n: int = int(s["n"])
	if n == 1:
		var out := PackedByteArray()
		out.resize(S3)
		out.fill(int(s["p"][0]))
		return out
	if n == 0:
		return (s["i"] as PackedByteArray).duplicate()
	return _slab_unpack(s["i"], int(s["b"]), s["p"])


static func _slabs_flat(slabs: Array) -> PackedByteArray:
	# Always returns the FULL column (slabs.size()*S3 bytes). A null slab
	# contributes its 4096 zero cells (NOT an empty buffer — a mid-column
	# null must keep its position, so the flat layout stays index-identical
	# to the legacy (y<<8)|(lz<<4)|lx column for probes / save handoff).
	var out := PackedByteArray()
	var zeros := PackedByteArray()
	zeros.resize(S3)
	for s in slabs:
		if s == null:
			out.append_array(zeros)
		else:
			out.append_array(_slab_flat(s))
	return out


static func _slabs_deepcopy(slabs: Array) -> Array:
	var out: Array = []
	for s in slabs:
		if s == null:
			out.append(null)
			continue
		out.append({
			"n": int(s["n"]),
			"b": int(s["b"]),
			"p": (s["p"] as PackedByteArray).duplicate(),
			"i": (s["i"] as PackedByteArray).duplicate(),
			"nz": int(s["nz"]),
		})
	return out


static func palettize_flat(arr: PackedByteArray, nsl: int) -> Array:
	# AC-0203 recenter fix: LUT-based (no per-cell Dictionary hashing) +
	# batch pack (no per-cell _slab_setbits call) — the main-thread landing
	# path (every gen/disk column) was 35 ms/col on this measure; this form
	# is a tight read loop + one _bitpack pass per slab.
	var out: Array = []
	var n := arr.size() / S3
	var seen := []
	seen.resize(256)
	var order := []
	var remap := []
	remap.resize(256)
	var vals := PackedByteArray()
	vals.resize(S3)
	var si := 0
	while si < n:
		var base := si * S3
		var i := 0
		while i < 256:
			seen[i] = -1
			i += 1
		order.clear()
		var nz := 0
		i = 0
		while i < S3:
			var v: int = arr[base + i]
			if seen[v] < 0:
				seen[v] = order.size()
				order.append(v)
			if v != 0:
				nz += 1
			i += 1
		var nn: int = order.size()
		if nz == 0:
			out.append(null)
		elif nn == 1:
			var k: int = int(order[0])
			out.append({"n": 1, "b": 0, "p": PackedByteArray([k]), "i": PackedByteArray(), "nz": nz})
		elif nn <= 16:
			var p := PackedByteArray()
			for u in order:
				p.append(int(u))
			p.sort()
			var pn: int = p.size()
			var j := 0
			while j < pn:
				remap[int(p[j])] = j
				j += 1
			i = 0
			while i < S3:
				vals[i] = remap[arr[base + i]]
				i += 1
			out.append({"n": pn, "b": _slab_bits_for(pn), "p": p, "i": _bitpack(vals, _slab_bits_for(pn)), "nz": nz})
		else:
			out.append({"n": 0, "b": 8, "p": PackedByteArray(), "i": arr.slice(base, base + S3), "nz": nz})
		si += 1
	while out.size() < nsl:
		out.append(null)
	return out

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
