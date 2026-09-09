# AC-0172: minimal STORE-only zip (no compression). This 4.7 build has
# no ZipPack/ZipReader, and shelling out to a zip CLI is not portable to
# the Windows exe. Store method 0 is a fully valid zip; the screenshot is
# already compressed and the text files are small, so no deflate is
# needed. Also carries a minimal reader (list + get_entry) so the
# harness can verify what a report wrote.
class_name ZipMini


static func make_zip(entries: Array, dest: String) -> bool:
	# entries = [ [zip_entry_name: String, data: PackedByteArray], ... ]
	var local := PackedByteArray()
	var central := PackedByteArray()
	for e in entries:
		var name: String = str(e[0])
		var data: PackedByteArray = e[1]
		var crc := _crc32(data)
		var name_b := name.to_utf8_buffer()
		var off := local.size()
		var h := PackedByteArray()
		h.append_array(_u32(0x04034B50))
		h.append_array(_u16(20))  # version made by / needed
		h.append_array(_u16(0))   # flags
		h.append_array(_u16(0))   # method = store
		h.append_array(_u16(0))   # mod time
		h.append_array(_u16(0))   # mod date
		h.append_array(_u32(crc))
		h.append_array(_u32(data.size()))
		h.append_array(_u32(data.size()))
		h.append_array(_u16(name_b.size()))
		h.append_array(_u16(0))   # extra len
		h.append_array(name_b)
		local.append_array(h)
		local.append_array(data)
		var c := PackedByteArray()
		c.append_array(_u32(0x02014B50))
		c.append_array(_u16(20))
		c.append_array(_u16(20))
		c.append_array(_u16(0))
		c.append_array(_u16(0))
		c.append_array(_u16(0))
		c.append_array(_u16(0))
		c.append_array(_u32(crc))
		c.append_array(_u32(data.size()))
		c.append_array(_u32(data.size()))
		c.append_array(_u16(name_b.size()))
		c.append_array(_u16(0))  # extra len
		c.append_array(_u16(0))  # comment len
		c.append_array(_u16(0))  # disk number start
		c.append_array(_u16(0))  # internal attrs
		c.append_array(_u32(0))  # external attrs
		c.append_array(_u32(off))
		# NOTE: the central header has NO compression-method field (the
		# local header does) - the fixed part is 46 bytes, name at 46.
		c.append_array(name_b)
		central.append_array(c)
	var eocd := PackedByteArray()
	eocd.append_array(_u32(0x06054B50))
	eocd.append_array(_u16(0))
	eocd.append_array(_u16(0))
	eocd.append_array(_u16(entries.size()))
	eocd.append_array(_u16(entries.size()))
	eocd.append_array(_u32(central.size()))
	eocd.append_array(_u32(local.size()))
	eocd.append_array(_u16(0))
	var out := PackedByteArray()
	out.append_array(local)
	out.append_array(central)
	out.append_array(eocd)
	var f := FileAccess.open(dest, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(out)
	f.close()
	return true


# -> {entry_name: {"offset": int, "size": int}} ({} on a bad zip)
static func list(data: PackedByteArray) -> Dictionary:
	var i := data.size() - 22
	while i >= 0:
		if _u32at(data, i) == 0x06054B50:
			break
		i -= 1
	if i < 0:
		return {}
	# EOCD: sig(0) disk(4) cdisk(6) count(8) count(10) csize(12) coff(16)
	var count := _u16at(data, i + 10)
	var p := _u32at(data, i + 16)
	var res := {}
	for k in count:
		if _u32at(data, p) != 0x02014B50:
			return {}
		var nlen := _u16at(data, p + 28)
		var elen := _u16at(data, p + 30)
		var clen := _u16at(data, p + 32)
		var name := data.slice(p + 46, p + 46 + nlen).get_string_from_utf8()
		res[name] = {"offset": _u32at(data, p + 42), "size": _u32at(data, p + 24)}
		p += 46 + nlen + elen + clen
	return res


static func get_entry(data: PackedByteArray, name: String) -> PackedByteArray:
	var entries := list(data)
	if not entries.has(name):
		return PackedByteArray()
	var off: int = entries[name]["offset"]
	if off + 30 > data.size() or _u32at(data, off) != 0x04034B50:
		return PackedByteArray()
	var nlen := _u16at(data, off + 26)
	var elen := _u16at(data, off + 28)
	var start := off + 30 + nlen + elen
	var size := _u32at(data, off + 18)
	if start + size > data.size():
		return PackedByteArray()
	return data.slice(start, start + size)


static func _crc32(data: PackedByteArray) -> int:
	var table: Array = []
	for n in 256:
		var c := n
		for _k in 8:
			c = (c >> 1) ^ 0xEDB88320 if (c & 1) != 0 else c >> 1
		table.append(c)
	var crc := 0xFFFFFFFF
	for b in data:
		crc = (crc >> 8) ^ table[(crc ^ b) & 0xFF]
	return crc ^ 0xFFFFFFFF


static func _u16(v: int) -> PackedByteArray:
	return PackedByteArray([v & 0xFF, (v >> 8) & 0xFF])


static func _u32(v: int) -> PackedByteArray:
	return PackedByteArray([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF])


static func _u16at(d: PackedByteArray, i: int) -> int:
	return d[i] | (d[i + 1] << 8)


static func _u32at(d: PackedByteArray, i: int) -> int:
	return d[i] | (d[i + 1] << 8) | (d[i + 2] << 16) | (d[i + 3] << 24)
