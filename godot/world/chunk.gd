extends Node3D

const SIZE := 16
const STANDALONE_MARGIN := 0
const MIN_AMB := 0.08
const SNAP_W := 18
const SNAP_ROW := 324
const XQ_A := [Vector3(0, 0, 0.5), Vector3(1, 0, 0.5), Vector3(1, 1, 0.5), Vector3(0, 1, 0.5)]
const XQ_B := [Vector3(0.5, 0, 0), Vector3(0.5, 0, 1), Vector3(0.5, 1, 1), Vector3(0.5, 1, 0)]

var cx := 0
var cz := 0
var face := 0
# AC-0203: per-slab palette representation (MC 1.18 style). 24 slabs of
# 16x16x16; each is null (all air) or a ChunkIO slab dict {n,b,p,i,nz}:
# n==1 uniform, n==2..16 paletted (packed bit indices), n==0 raw 8-bit
# (>16 unique ids, lossless). The flat (y<<8)|(lz<<4)|lx view is provided
# by get_local/get_at/fl_at/flat_data (lazy expansion — probes/saves only).
var data: Array = []
var fl: Array = []
var mesh_built := false
var mesh_gen := 0
var collision_enabled := true
var col_immediate := true
var last_collision_build_ms := 0
var last_eff: Dictionary = {}
var saved_light: Dictionary = {}
var light_recomputes := 0
var last_blk_ring: PackedInt32Array = PackedInt32Array()
# AC-0129: bumped when last_eff's byte array changes (world._eff_landed);
# neighbors' eff-cache entries carry our gen at their dispatch (ngen) and
# invalidate when it moves — the pull strips derive from our last_eff.
var eff_gen := 0
var data_gen := 0
# AC-0203: bumped by every fl mutation (set_fl_at / data_landed / clear_data)
# — the fl half of the stamp used by cache/dispatch invalidation.
var fl_gen := 0
# AC-0197: max y holding any non-air block in this column (-1 = no data yet).
# Every row above top is air BY DEFINITION, so slabs > top/16 are empty:
# build_accs stops at top/16, the pull kernel fills eff=15 above top and
# skips the flood there, and the codec omits the null slabs. set_local only
# RAISES it (mining the top settles back down on the next update_top);
# gen/load/edit finalization rescan.
var top := -1


func update_top() -> void:
	if data.is_empty():
		top = -1
		return
	var t := -1
	var si := data.size() - 1
	while si >= 0:
		var s = data[si]
		if s != null:
			var flat := ChunkIO._slab_flat(s)
			var cy := 15
			while cy >= 0:
				var row := cy << 8
				var anyv := false
				var i := 0
				while i < 256:
					if flat[row + i] != 0:
						anyv = true
						break
					i += 1
				if anyv:
					t = si * 16 + cy
					break
				cy -= 1
			break
		si -= 1
	top = t
# AC-0080 two-stage hysteresis: candidate = at Chebyshev r+1 with expensive
# parts killed (mesh/collision), data+edits kept; cand_since = count of
# recenter events spent at >= r+2 (free at >= 2).
var candidate := false
var cand_since := 0
# AC-0152: 0 = full 16x16x16 (ticks + collide), 1 = full mesh, no
# tick/collide (same builder path as band 0), 2 = coarse 32-scale merged
# (uv_scale 2 — the rest of the render circle), 3 = collar/ring data-only
# (never meshed). AC-0160: the band-2 heightmap impostor was removed
# (user decision 2026-08-30) — band 2 uses the normal build path.
# AC-0181: band 1/2 fidelity swapped — 0-12 full, 13+ coarse uniform.
var band := 0
var lod_pending := false
var alt_lod := -1
var alt_slabs: Array = []
# AC-0203: stamp [data_gen, fl_gen] captured at store/swap time replaces the
# alt_data/alt_fl full-column duplicates (192 KB per cached chunk).
var alt_stamp: Array = []
var alt_atlas: Texture2D = null
var lod_builds := 0
var lod_swaps := 0
var lod_swaps_instant := 0
var lod_last_swap_ms := 0.0
# AC-0108: vertical 16x16x16 slabs, each owning its own mesh/fluid/flora
# instances + collision body; data/fl stay column-wide. AC-0091: the slab
# COUNT is (Data.HEIGHT + 15) / 16 = 24 at H=384 (was 5 at H=80) — computed
# at runtime (a const can't reference the Data autoload); see slab_n().
static var _slab_n := 0
static func slab_n() -> int:
	if _slab_n == 0:
		_slab_n = (Data.HEIGHT + 15) / 16
	return _slab_n
# AC-0091: zero-filled length-n array (GDScript has no [0] * n repetition).
static func _zeros(n: int) -> Array:
	var out: Array = []
	for i in range(n):
		out.append(0)
	return out
# AC-0190: C++ meshing (gdext/src/mesh.cpp — AweMesh.build_accs, the
# LOSSLESS port of the GDScript build_accs pipeline: slab decode (the
# AC-0203 paletted slabs are unpacked in C++, int-lookup fast), bake box,
# snap, ro scan, greedy merged emit). Workers pass the slab arrays + nbs +
# ctx + ms + eff as value copies (no Data/Game deref on the worker).
# AC-0208: the C++ extension is REQUIRED — the AWECRAFT_MESHCPP kill switch
# and the GDScript build_accs fallback were removed; AweMesh is the only
# mesh path (Game._ready fails fast if the library is missing).
static var _mesh_cpp: Variant = null
static var _mesh_cpp_done := false

static func mesh_cpp() -> Variant:
	if not _mesh_cpp_done:
		_mesh_cpp_done = true
		if ClassDB.class_exists("AweMesh"):
			_mesh_cpp = ClassDB.instantiate("AweMesh")
		else:
			push_error("AWECRAFT: AweMesh C++ class not registered — the gdext library is missing (AC-0208: the C++ extension is REQUIRED, no GDScript mesh fallback).")
	return _mesh_cpp

var slabs: Array = []
var perf_slab_body_builds := PackedInt32Array()
var perf_slab_body_ms := PackedFloat32Array()


class Acc:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var u := PackedVector2Array()
	var i := PackedInt32Array()
	var q := 0


class Slab:
	var y0 := 0
	var built := false
	var mesh_instance: MeshInstance3D = null
	var fluid_instance: MeshInstance3D = null
	var flora_instance: MeshInstance3D = null
	var collision_body: StaticBody3D = null
	var occluder: OccluderInstance3D = null
	var col_dirty := false
	var sidx := PackedInt32Array()
	var fsidx := PackedInt32Array()


static var _ms_key
static var _ms_tex: ImageTexture = null
static var _ms_rects := {}
static var _mat_atlas: Texture2D = null   # Data.atlas_tex identity at last build
static var _mat_ms: Texture2D = null      # merged-atlas texture identity at last build
static var _mat_cache: Dictionary = {}    # kind -> Material (opaque/cutout/flower/fluid)
static var _mat_alloc_count := 0          # G3 build-path counter (total since boot)
static var _occl_ok: int = -1             # -1 unknown, 0 disabled (headless), 1 enabled
static func _occl_enabled() -> bool:
	if _occl_ok < 0:
		_occl_ok = 1 if DisplayServer.get_name() != "headless" else 0
	return _occl_ok == 1

# AC-0128: u_day = DayNight.day(Game.time_of_day), pushed every frame by
# main.gd _update_sky (web parity: the per-frame day uniform, index.html
# :3222). Shared by all cached ShaderMaterials — one set_shader_parameter
# per kind per frame.
static var _day_factor := 1.0
static var _lit_atlas_key: Texture2D = null
static var _lit_atlas: Texture2D = null


static func set_day_factor(d: float) -> void:
	_day_factor = d
	for k in _mat_cache:
		var m = _mat_cache[k]
		if m is ShaderMaterial:
			m.set_shader_parameter("u_day", d)


# AC-0128: the lit (unshaded) materials sample the atlas through RUNTIME
# ImageTextures — Godot 4.7.1 has no per-texture runtime filter override
# (set_filter does not exist; only BaseMaterial3D.texture_filter + the import
# settings), and a shader uniform sampler uses the texture's own filter.
# Runtime ImageTextures default to NEAREST (the Texture2D class default), so
# every lit kind gets the crisp look the current StandardMaterials forced via
# TEXTURE_FILTER_NEAREST. cutout/flower/fluid share ONE runtime copy of
# Data.atlas_tex so the shared imported texture's own filter is left alone
# (the fluid_anim water/lava materials keep today's look).
static func _lit_atlas_tex() -> Texture2D:
	if _lit_atlas_key != Data.atlas_tex:
		_lit_atlas_key = Data.atlas_tex
		_lit_atlas = null
		var at: Texture2D = Data.atlas_tex
		if at != null:
			var img: Image = at.get_image()
			if img != null:
				var c: Image = img.duplicate()
				_lit_atlas = ImageTexture.create_from_image(c)
	return _lit_atlas


static func _lit_material(kind: String, ms_tex: Texture2D) -> Material:
	var path := ""
	var tex: Texture2D = null
	match kind:
		"opaque":
			path = "res://world/chunk_lit_opaque.gdshader"
			# ms_tex is a runtime ImageTexture (NEAREST default); the fallback
			# rides the shared runtime copy for the same reason.
			tex = ms_tex if ms_tex != null else _lit_atlas_tex()
		"cutout":
			path = "res://world/chunk_lit_cutout.gdshader"
			tex = _lit_atlas_tex()
		"flower":
			path = "res://world/chunk_lit_flower.gdshader"
			tex = _lit_atlas_tex()
		_:
			path = "res://world/chunk_lit_fluid.gdshader"
			tex = _lit_atlas_tex()
	if tex == null:
		return null
	var sh: Shader = load(path)
	if sh == null:
		return null
	var sm := ShaderMaterial.new()
	sm.shader = sh
	sm.set_shader_parameter("u_day", _day_factor)
	sm.set_shader_parameter("tex", tex)
	return sm


# AC-0120: shared material cache — static like _merge_atlas (main-thread-only in
# practice: build_mesh sync + apply_accs handoff both run on the main thread).
# Lazy per-kind creation; identity-key invalidation on (Data.atlas_tex, ms_tex)
# for the opaque kind (its texture IS the key) so a texture-pack swap or an
# AWECRAFT_MERGE=0 run clears the set once; <=4 live entries, kind-only keys.
# AC-0128: with the atlas loaded the four kinds become unlit ShaderMaterials
# (the web :746 day/night formula); without it the legacy lit materials stay
# (byte-identical no-atlas behavior).
static func _get_mat(kind: String, ms_tex: Texture2D = null) -> Material:
	if _mat_atlas != Data.atlas_tex or (kind == "opaque" and _mat_ms != ms_tex):
		_mat_cache.clear()                 # texture swap / merge rebuild -> fresh set
		_mat_atlas = Data.atlas_tex
		_mat_ms = ms_tex
	if _mat_cache.has(kind):
		return _mat_cache[kind]
	var m: Material
	if Data.atlas_tex != null:
		m = _lit_material(kind, ms_tex)
	if m == null:
		match kind:
			"opaque": m = _opaque_material(ms_tex)
			"cutout": m = _cutout_material()
			"flower": m = _flower_material()
			_: m = _fluid_material()
	_mat_cache[kind] = m
	_mat_alloc_count += 1
	return m


# AC-0107: static (touches only the _ms_* statics + Data) so the main thread
# can pre-build the atlas cache before the first mesh dispatch.
static func _merge_atlas() -> Dictionary:
	if _ms_key == Data.atlas_tex:
		return {"tex": _ms_tex, "rects": _ms_rects, "h": float(_ms_tex.get_image().get_height())}
	_ms_key = Data.atlas_tex
	_ms_tex = null
	_ms_rects = {}
	var at = Data.atlas_tex
	if at == null:
		return {"tex": null, "rects": {}}
	var img: Image = at.get_image()
	if img == null:
		return {"tex": null, "rects": {}}
	var maxy := 0
	for k in Data.atlas_rects:
		var e = Data.atlas_rects[k]
		if e == null:
			continue
		for f in e:
			var r = e[f]
			if r is Array and r.size() == 4:
				maxy = maxi(maxy, int(r[1]) + int(r[3]))
	var pairs: Array = []
	for id in range(1, 256):
		var b = Data.block(id)
		if b == null:
			continue
		if not bool(b.solid) or bool(b.cross) or bool(b.get("cutout", false)):
			continue
		for face in ["top", "side", "bottom"]:
			var rc: Vector2i = Data.block_rect(id, face)
			if rc.x < 0:
				continue
			pairs.append([id, face, rc])
	var uniq: Array = []
	var seen := {}
	for p in pairs:
		if not seen.has(p[2]):
			seen[p[2]] = true
			uniq.append(p[2])
	var base := (maxy + 8) / 32 * 32 + 32
	# each strip occupies 4 tile-rows (128px) so merged quads of height H<=4
	# can tile vertically along the strip as well (2D greedy). The canvas is
	# grown downward (never resized in place) below the original tiles.
	var rowh := 128
	var total_h: int = base + (uniq.size() / 2 + 1) * rowh
	if total_h > 4096:
		return {"tex": null, "rects": {}}
	var iw: int = img.get_width()
	var img2: Image = Image.create_empty(iw, maxi(total_h, img.get_height()), false, Image.FORMAT_RGBA8)
	img2.blit_rect(img, Rect2i(0, 0, iw, img.get_height()), Vector2i.ZERO)
	var i := 0
	for rc in uniq:
		var sx := (i % 2) * 512
		var sy := base + (i / 2) * rowh
		for row in range(4):
			for rep in range(16):
				img2.blit_rect(img2, Rect2i(rc.x, rc.y, 32, 32), Vector2i(sx + rep * 32, sy + row * 32))
		seen[rc] = Vector2i(sx, sy)
		i += 1
	for p in pairs:
		_ms_rects["%d_%s" % [int(p[0]), p[1]]] = seen[p[2]]
	_ms_tex = ImageTexture.create_from_image(img2)
	return {"tex": _ms_tex, "rects": _ms_rects, "h": float(img2.get_height())}


func get_local(lx: int, y: int, lz: int) -> int:
	var s = data[y >> 4]
	if s == null:
		return 0
	return ChunkIO._slab_cell(s, ((y & 15) << 8) | (lz << 4) | lx)


func set_local(lx: int, y: int, lz: int, id: int) -> void:
	_slab_write(data, y, lz, lx, id)
	data_gen += 1
	if id != 0 and y > top:
		top = y


func get_at(fi: int) -> int:
	return get_local(fi & 15, fi >> 8, (fi >> 4) & 15)


func fl_at(fi: int) -> int:
	var y: int = fi >> 8
	var s = fl[y >> 4]
	if s == null:
		return 0
	return ChunkIO._slab_cell(s, ((y & 15) << 8) | (fi & 255))


func set_fl_at(fi: int, lvl: int) -> void:
	var y: int = fi >> 8
	_slab_write(fl, y, (fi >> 4) & 15, fi & 15, lvl)
	fl_gen += 1


func get_fl(lx: int, y: int, lz: int) -> int:
	return fl_at((y << 8) | (lz << 4) | lx)


func set_fl(lx: int, y: int, lz: int, lvl: int) -> void:
	set_fl_at((y << 8) | (lz << 4) | lx, lvl)


func stamp() -> Array:
	return [data_gen, fl_gen]


# AC-0203: lazy flat expansion — the only way back to the legacy
# (y<<8)|(lz<<4)|lx view (probes, save handoff, legacy kernels). Not on the
# R50 steady-state hot path (worker builds run on slab views).
func flat_data() -> PackedByteArray:
	return ChunkIO._slabs_flat(data)


func flat_fl() -> PackedByteArray:
	return ChunkIO._slabs_flat(fl)


func row_bytes(y: int) -> PackedByteArray:
	return _slabs_row(data, y)


func fl_row_bytes(y: int) -> PackedByteArray:
	return _slabs_row(fl, y)


static func _slabs_row(slabs: Array, y: int) -> PackedByteArray:
	var s = slabs[y >> 4]
	var out := PackedByteArray()
	out.resize(256)
	if s != null:
		var flat := ChunkIO._slab_flat(s)
		var base := (y & 15) << 8
		for i in range(256):
			out[i] = flat[base + i]
	return out


# AC-0203: the single flat->paletted conversion point. Every data landing
# (gen, threadgen/burst handoff, disk load, io-read handoff, face gen,
# battery clear) goes through here. Natural water note (ex-init_fl): fl
# arrives zero (or as the on-disk fl column); fluid_level() maps 0 -> 8 for
# display and sim, so the natural ocean never falls or churns.
func data_landed(d: PackedByteArray, f: PackedByteArray) -> void:
	data = ChunkIO.palettize_flat(d, slab_n())
	if f.is_empty():
		var zf := PackedByteArray()
		zf.resize(d.size())
		fl = ChunkIO.palettize_flat(zf, slab_n())
	else:
		fl = ChunkIO.palettize_flat(f, slab_n())
	data_gen += 1
	fl_gen += 1
	update_top()


# AC-0203 recenter fix: v4 disk-landing path — the decoder already produced
# the slab array (the wire form is the slab form), so this is a reference
# handoff: no flat expansion, no re-palettize on the main thread.
func slabs_landed(ds: Array, fs: Array) -> void:
	if ds.size() != slab_n() or fs.size() != slab_n():
		data = ChunkIO.palettize_flat(ChunkIO._slabs_flat(ds), slab_n())
		fl = ChunkIO.palettize_flat(ChunkIO._slabs_flat(fs), slab_n())
	else:
		data = ds
		fl = fs
	data_gen += 1
	fl_gen += 1
	update_top()


func clear_data() -> void:
	var ns: Array = []
	for i in range(slab_n()):
		ns.append(null)
	data = ns
	var nf: Array = []
	for i in range(slab_n()):
		nf.append(null)
	fl = nf
	top = -1
	data_gen += 1
	fl_gen += 1


# AC-0203: slab write with palette growth. The slab invariant holds on
# return: null = all air; otherwise nz>0, n<=16 (or raw n==0 when the
# palette overflows), i consistent with b, nz = non-zero cell count.
static func _slab_write(slabs: Array, y: int, lz: int, lx: int, val: int) -> void:
	var si := y >> 4
	var pos := ((y & 15) << 8) | (lz << 4) | lx
	var s = slabs[si]
	if s == null:
		if val == 0:
			return
		var p := PackedByteArray()
		p.append(0)
		p.append(val)
		var idx := PackedByteArray()
		idx.resize(512)
		ChunkIO._slab_setbits(idx, 1, pos, 1)
		slabs[si] = {"n": 2, "b": 1, "p": p, "i": idx, "nz": 1}
		return
	var cur: int = ChunkIO._slab_cell(s, pos)
	if cur == val:
		return
	var n: int = int(s["n"])
	if n == 0:
		var ri: PackedByteArray = s["i"]
		ri[pos] = val
		var rz: int = int(s["nz"])
		if cur != 0:
			rz -= 1
		if val != 0:
			rz += 1
		if rz == 0:
			slabs[si] = null
		else:
			s["nz"] = rz
		return
	var p2: PackedByteArray = s["p"]
	var pi := -1
	var k := 0
	while k < n:
		if int(p2[k]) == val:
			pi = k
			break
		k += 1
	if pi < 0:
		if n == 1:
			var v0: int = int(p2[0])
			var np := PackedByteArray()
			np.append(v0)
			np.append(val)
			var idx2 := PackedByteArray()
			idx2.resize(512)
			ChunkIO._slab_setbits(idx2, 1, pos, 1)
			var nz2: int = 0
			if v0 != 0:
				nz2 = 4095
			if val != 0:
				nz2 += 1
			if nz2 == 0:
				slabs[si] = null
			else:
				slabs[si] = {"n": 2, "b": 1, "p": np, "i": idx2, "nz": nz2}
			return
		if n >= 16:
			var raw := ChunkIO._slab_flat(s)
			raw[pos] = val
			var nz3 := 0
			var i := 0
			while i < 4096:
				if raw[i] != 0:
					nz3 += 1
				i += 1
			if nz3 == 0:
				slabs[si] = null
			else:
				slabs[si] = {"n": 0, "b": 8, "p": PackedByteArray(), "i": raw, "nz": nz3}
			return
		p2.append(val)
		pi = n
		var nn: int = n + 1
		var nb: int = ChunkIO._slab_bits_for(nn)
		var ob: int = int(s["b"])
		if nb > ob:
			var inv := {}
			var kk := 0
			while kk < n:
				inv[p2[kk]] = kk
				kk += 1
			var flatv := ChunkIO._slab_flat(s)
			var nidx := PackedByteArray()
			nidx.resize((4096 * nb + 7) / 8)
			var pos2 := 0
			while pos2 < 4096:
				ChunkIO._slab_setbits(nidx, nb, pos2, int(inv[flatv[pos2]]))
				pos2 += 1
			s["i"] = nidx
		s["b"] = nb
		s["n"] = nn
		s["p"] = p2
	var nz4: int = int(s["nz"])
	if cur != 0:
		nz4 -= 1
	if val != 0:
		nz4 += 1
	ChunkIO._slab_setbits(s["i"], int(s["b"]), pos, pi)
	s["nz"] = nz4
	if nz4 == 0:
		slabs[si] = null


func _effl(lmn: Vector3i, larr: PackedByteArray, lw: int, ld: int, x: int, y: int, z: int) -> int:
	if y < 0:
		return 0
	if y >= Data.HEIGHT:
		return 15
	var ix := x - lmn.x
	var iz := z - lmn.z
	if ix < 0 or iz < 0 or ix >= lw or iz >= ld:
		return 15
	return larr[(y - lmn.y) * lw * ld + iz * lw + ix]


func _face_light(id: int, wx: int, y: int, wz: int, n: Vector3i, lmn: Vector3i, larr: PackedByteArray, lw: int, ld: int) -> float:
	var v := 0
	if id == 22:
		v = _effl(lmn, larr, lw, ld, wx, y, wz)
	else:
		var nx := wx + n.x
		var ny := y + n.y
		var nz := wz + n.z
		v = _effl(lmn, larr, lw, ld, nx, ny, nz)
		if id != 5 and id != 24:
			if n.x == 0:
				v = maxi(v, _effl(lmn, larr, lw, ld, nx + 1, ny, nz))
				v = maxi(v, _effl(lmn, larr, lw, ld, nx - 1, ny, nz))
			if n.y == 0:
				v = maxi(v, _effl(lmn, larr, lw, ld, nx, ny + 1, nz))
				v = maxi(v, _effl(lmn, larr, lw, ld, nx, ny - 1, nz))
			if n.z == 0:
				v = maxi(v, _effl(lmn, larr, lw, ld, nx, ny, nz + 1))
				v = maxi(v, _effl(lmn, larr, lw, ld, nx, ny, nz - 1))
	return clampf(float(v) / 15.0, MIN_AMB, 1.0)


func _corner_uv(cv: Vector3, n: Vector3i, tl: Vector2i) -> Vector2:
	if tl.x < 0:
		return Vector2.ZERO
	var u: float
	var v: float
	if n.y != 0:
		u = float(cv.x)
		v = float(cv.z)
	elif n.x != 0:
		u = float(cv.z)
		v = 1.0 - float(cv.y)
	else:
		u = float(cv.x)
		v = 1.0 - float(cv.y)
	return (Vector2(tl) + Vector2(0.5 + u * 31.0, 0.5 + v * 31.0)) / Data.ATLAS_PX


# AC-0128: vColor repack channel layout.
# has_tex: r = sky channel (light scalar s), g = block-light channel (s when
# the face has block-light source evidence within Chebyshev 14 in own-chunk
# data, else 0), b = face shade — the unlit shader computes the L formula
# L = 0.20 + 0.80*max(u_day*r, g) (AC-0128 structure, const+gain = 1.0,
# user-directed 0.20 floor, AC-0135 Run-2). Without the atlas the legacy
# behavior stays: face_color * shade (shade = fsh * s).
static func _light_color(s: float, fsh: float, mask: int, face_color: Color, has_tex: bool) -> Color:
	if has_tex:
		if mask > 0:
			return Color(0.0, s, fsh, 1.0)
		return Color(s, 0.0, fsh, 1.0)
	return face_color * (fsh * s)


# AC-0128 RUN 3: mask evidence for ONE light sample cell - 1 iff the cell is
# VISITED by the block-light flood (own glow sources + neighbor blk-strip
# injection - the same seeds the light eff got, computed once in the pull
# kernel, lighting.gd; layout (y<<8)|(lz<<4)|lx, 16x16xh). visited iff lit,
# so no eff check is needed; a visited cell's eff is always > 0 in the same
# light dict. Cells outside the own chunk (bake-box margin) have no mask
# evidence -> 0 (the face follows the day cycle, the web dark-side case).
# An empty/short buffer (a light dict without a mask) reads 0 everywhere.
static func _mask_sample(wx: int, y: int, wz: int, lmn: Vector3i, h: int, bmask: PackedByteArray) -> int:
	if bmask.size() != 256 * h:
		return 0
	var lx := (wx - lmn.x) - 2
	var lz := (wz - lmn.z) - 2
	if y < 0 or y >= h or lx < 0 or lx >= 16 or lz < 0 or lz >= 16:
		return 0
	return bmask[(y << 8) | (lz << 4) | lx]


# AC-0128: per-face mask - 1 iff ANY of the face's light sample cells (the
# SAME 5 cells _face_light reads: opposite + 4 axis probes; id 22 = own cell
# only) is block-light flood-visited. Pinned faces keep their g channel
# (bright at night); sky-only faces ride r = s through the day cycle.
static func _face_mask(id: int, wx: int, y: int, wz: int, n: Vector3i, lmn: Vector3i, h: int, bmask: PackedByteArray) -> int:
	if id == 22:
		return _mask_sample(wx, y, wz, lmn, h, bmask)
	var nx := wx + n.x
	var ny := y + n.y
	var nz := wz + n.z
	var m := _mask_sample(nx, ny, nz, lmn, h, bmask)
	if id != 5 and id != 24 and m == 0:
		if n.x == 0:
			m = _mask_sample(nx + 1, ny, nz, lmn, h, bmask)
			if m == 0:
				m = _mask_sample(nx - 1, ny, nz, lmn, h, bmask)
		if m == 0 and n.y == 0:
			m = _mask_sample(nx, ny + 1, nz, lmn, h, bmask)
			if m == 0:
				m = _mask_sample(nx, ny - 1, nz, lmn, h, bmask)
		if m == 0 and n.z == 0:
			m = _mask_sample(nx, ny, nz + 1, lmn, h, bmask)
			if m == 0:
				m = _mask_sample(nx, ny - 1, nz, lmn, h, bmask)
	return m


func _face_rect(rc: Dictionary, id: int, fi: int, face_name: String) -> Vector2i:
	var key := id * 8 + fi
	var tl = rc.get(key)
	if tl == null:
		tl = Data.block_rect(id, face_name)
		rc[key] = tl
	return tl


func _face_uvs(n: Vector3i, cva: Array, tl: Vector2i) -> PackedVector2Array:
	var out := PackedVector2Array()
	for cv in cva:
		out.append(_corner_uv(cv, n, tl))
	return out


func _uvc(uvc: Dictionary, rc: Dictionary, id: int, fi: int, face_name: String, fn: Array, fcv: Array) -> PackedVector2Array:
	var key := id * 8 + fi
	var uvs = uvc.get(key)
	if uvs == null:
		var tl := _face_rect(rc, id, fi, face_name)
		uvs = _face_uvs(fn[fi], fcv[fi], tl)
		uvc[key] = uvs
	return uvs






static func _qwrite(acc, k: int, c: Color, n: Vector3i, uvs: PackedVector2Array, fcv: Array, lx: int, y: int, lz: int, py0: float, py1: float, py2: float, py3: float) -> void:
	var b := k * 4
	var cv0: Vector3 = fcv[0]
	var cv1: Vector3 = fcv[1]
	var cv2: Vector3 = fcv[2]
	var cv3: Vector3 = fcv[3]
	acc.v[b] = Vector3(float(lx) + cv0.x, float(y) + py0, float(lz) + cv0.z)
	acc.v[b + 1] = Vector3(float(lx) + cv1.x, float(y) + py1, float(lz) + cv1.z)
	acc.v[b + 2] = Vector3(float(lx) + cv2.x, float(y) + py2, float(lz) + cv2.z)
	acc.v[b + 3] = Vector3(float(lx) + cv3.x, float(y) + py3, float(lz) + cv3.z)
	for j in range(4):
		acc.n[b + j] = Vector3(n)
		acc.u[b + j] = uvs[j]
		acc.c[b + j] = c
	var ib := k * 6
	acc.i[ib] = b
	acc.i[ib + 1] = b + 2
	acc.i[ib + 2] = b + 1
	acc.i[ib + 3] = b
	acc.i[ib + 4] = b + 3
	acc.i[ib + 5] = b + 2












static func _s_corner_uv(cv: Vector3, n: Vector3i, tl: Vector2i, atlas_px: float, ppb: float = 31.0) -> Vector2:
	if tl.x < 0:
		return Vector2.ZERO
	var u: float
	var v: float
	if n.y != 0:
		u = float(cv.x)
		v = float(cv.z)
	elif n.x != 0:
		u = float(cv.z)
		v = 1.0 - float(cv.y)
	else:
		u = float(cv.x)
		v = 1.0 - float(cv.y)
	return (Vector2(tl) + Vector2(0.5 + u * ppb, 0.5 + v * ppb)) / atlas_px


static func _s_face_uvs(n: Vector3i, cva: Array, tl: Vector2i, atlas_px: float, ppb: float = 31.0) -> PackedVector2Array:
	var out := PackedVector2Array()
	for cv in cva:
		out.append(_s_corner_uv(cv, n, tl, atlas_px, ppb))
	return out


static func _s_uvc(uvc: Dictionary, brect: Dictionary, id: int, fi: int, face_name: String, fn: Array, fcv: Array, atlas_px: float, ppb: float = 31.0) -> PackedVector2Array:
	var key := int(ppb) * 256 * 8 + id * 8 + fi
	var uvs = uvc.get(key)
	if uvs == null:
		var tl: Vector2i = brect.get("%d_%s" % [id, face_name], Vector2i(-1, -1))
		uvs = _s_face_uvs(fn[fi], fcv[fi], tl, atlas_px, ppb)
		uvc[key] = uvs
	return uvs











# Main-thread table snapshot consumed by the worker pipeline. Rebuilt on
# refresh_textures (texture swap is the only table-changing event).
static func make_ctx() -> Dictionary:
	var h: int = Data.HEIGHT
	var oktab := PackedByteArray(); oktab.resize(256)
	var xtab := PackedByteArray(); xtab.resize(256)
	var stab := PackedByteArray(); stab.resize(256)
	var ktab := PackedByteArray(); ktab.resize(256)
	var ttab := PackedByteArray(); ttab.resize(256)
	var ct := PackedColorArray(); ct.resize(256)
	var cs := PackedColorArray(); cs.resize(256)
	var cb := PackedColorArray(); cb.resize(256)
	for bi in range(256):
		var binf = Data.block(bi)
		if binf == null:
			continue
		oktab[bi] = 1
		if bool(binf.cross):
			xtab[bi] = 1
		elif bool(binf.solid):
			stab[bi] = 1
		if bool(binf.get("cutout", false)):
			ktab[bi] = 1
		if bool(binf.get("thin", false)):
			ttab[bi] = 1
		var bcol: Dictionary = binf.color
		ct[bi] = bcol.top
		cs[bi] = bcol.side
		cb[bi] = bcol.bottom
	var tint_top := PackedColorArray(); tint_top.resize(256)
	var tint_side := PackedColorArray(); tint_side.resize(256)
	var tint_bottom := PackedColorArray(); tint_bottom.resize(256)
	# AC-0128: with the atlas loaded the block tints are baked into the atlas
	# pixels (data.gd _bake_atlas_tints) — the vertex-color tints go WHITE so
	# every emit-site multiply becomes a no-op (the no-atlas path keeps the
	# legacy tint-free face colors, exactly as before).
	var _tint_white := Data.atlas_tex != null
	for bi in range(256):
		if _tint_white:
			tint_top[bi] = Color.WHITE
			tint_side[bi] = Color.WHITE
			tint_bottom[bi] = Color.WHITE
		else:
			tint_top[bi] = Data.block_tint(bi, "top")
			tint_side[bi] = Data.block_tint(bi, "side")
			tint_bottom[bi] = Data.block_tint(bi, "bottom")
	# Precomputed per-face rects, keyed "%d_%s" like the merge-atlas cache.
	# The sync path's _face_rect fallback resolves the same (id, face_name)
	# pairs, so values are identical.
	var brect := {}
	for bi in range(256):
		for face_name in ["side", "top", "bottom"]:
			brect["%d_%s" % [bi, face_name]] = Data.block_rect(bi, face_name)
	var fn: Array = []
	var fsh := PackedFloat32Array()
	var fcv: Array = []
	for fi in range(6):
		var fd: Dictionary = VoxelMath.FACES[fi]
		fn.append(fd.n)
		fsh.append(float(fd.sh))
		fcv.append(fd.c)
	return {
		"h": h,
		"atlas_px": Data.ATLAS_PX,
		"has_tex": Data.atlas_tex != null,
		"oktab": oktab, "xtab": xtab, "stab": stab, "ktab": ktab, "ttab": ttab,
		"ct": ct, "cs": cs, "cb": cb,
		"tint_top": tint_top, "tint_side": tint_side, "tint_bottom": tint_bottom,
		"brect": brect,
		"fn": fn, "fsh": fsh, "fcv": fcv,
	}





func init_slabs() -> void:
	if not slabs.is_empty():
		return
	var sn: int = slab_n()  # AC-0091: runtime slab count (24 at H=384)
	if perf_slab_body_builds.size() != sn:
		perf_slab_body_builds.resize(sn)
		perf_slab_body_ms.resize(sn)
	for i in range(sn):
		var s := Slab.new()
		s.y0 = i * 16
		s.col_dirty = true
		slabs.append(s)


func slab_for_y(y: int) -> Slab:
	if slabs.is_empty():
		init_slabs()
	return slabs[clampi(y / 16, 0, slab_n() - 1)]  # AC-0091: runtime slab count


func mark_edit_slabs(y: int) -> void:
	if slabs.is_empty():
		init_slabs()
	# Greedy merged quads extend DOWN (v-axis) up to 3 rows from their anchor
	# row, so an edit at row y can reshape quads anchored at v0 in [y-3, y];
	# mark the full closure, not just the touched slab.
	for si in range(maxi(0, (y - 3) / 16), mini(slab_n() - 1, (y + 1) / 16) + 1):
		slabs[si].col_dirty = true


func mark_all_slabs_dirty() -> void:
	if slabs.is_empty():
		init_slabs()
	for s in slabs:
		s.col_dirty = true


func any_col_dirty() -> bool:
	for s in slabs:
		if s.col_dirty:
			return true
	return false


func has_any_slab_body() -> bool:
	for s in slabs:
		if s.collision_body != null:
			return true
	return false


func has_all_slab_bodies() -> bool:
	for s in slabs:
		if s.collision_body == null:
			return false
	return true


func first_opaque_mesh() -> ArrayMesh:
	for s in slabs:
		if s.mesh_instance != null and s.mesh_instance.mesh != null:
			return s.mesh_instance.mesh
	return null


func build_dirty_slab_bodies() -> void:
	last_collision_build_ms = 0
	if not collision_enabled:
		return
	for s in slabs:
		if s.col_dirty and s.collision_body == null:
			_build_slab_collision(s)
			if s.collision_body != null or s.mesh_instance == null or s.mesh_instance.mesh == null:
				s.col_dirty = false


func drop_slab_bodies() -> void:
	for s in slabs:
		if s.collision_body != null:
			s.collision_body.queue_free()
			s.collision_body = null
		s.col_dirty = true


func capture_lod() -> Array:
	var out: Array = []
	for s in slabs:
		var row: Array = [null, null, null]
		if s.mesh_instance != null:
			row[0] = s.mesh_instance.mesh
		if s.fluid_instance != null:
			row[1] = s.fluid_instance.mesh
		if s.flora_instance != null:
			row[2] = s.flora_instance.mesh
		out.append(row)
	return out


func lod_cache_valid(kind: int) -> bool:
	if alt_lod != kind or alt_slabs.is_empty():
		return false
	if alt_atlas != Data.atlas_tex:
		return false
	if alt_stamp != stamp():
		return false
	return true


func clear_lod_cache() -> void:
	alt_lod = -1
	alt_slabs = []
	alt_stamp = []
	alt_atlas = null


func store_lod_cache(cap: Array, kind: int, in_ring: bool) -> void:
	lod_pending = false
	lod_builds += 1
	if not in_ring or cap.size() != slabs.size():
		clear_lod_cache()
		return
	alt_slabs = cap
	alt_lod = kind
	alt_stamp = stamp()
	alt_atlas = Data.atlas_tex


func _set_slab_lod(s: Slab, row: Array) -> void:
	if row[0] != null:
		if s.mesh_instance == null:
			var mi := MeshInstance3D.new()
			mi.mesh = row[0]
			add_child(mi)
			s.mesh_instance = mi
		else:
			s.mesh_instance.mesh = row[0]
	elif s.mesh_instance != null:
		s.mesh_instance.queue_free()
		s.mesh_instance = null
	if row[1] != null:
		if s.fluid_instance == null:
			var fi := MeshInstance3D.new()
			fi.mesh = row[1]
			add_child(fi)
			s.fluid_instance = fi
		else:
			s.fluid_instance.mesh = row[1]
	elif s.fluid_instance != null:
		s.fluid_instance.queue_free()
		s.fluid_instance = null
	if row[2] != null:
		if s.flora_instance == null:
			var fa := MeshInstance3D.new()
			fa.mesh = row[2]
			add_child(fa)
			s.flora_instance = fa
		else:
			s.flora_instance.mesh = row[2]
	elif s.flora_instance != null:
		s.flora_instance.queue_free()
		s.flora_instance = null


func swap_to_cached(in_ring: bool) -> void:
	var t0 := Time.get_ticks_usec()
	var demote: Array = []
	for s in slabs:
		var row: Array = [null, null, null]
		if s.mesh_instance != null:
			row[0] = s.mesh_instance.mesh
		if s.fluid_instance != null:
			row[1] = s.fluid_instance.mesh
		if s.flora_instance != null:
			row[2] = s.flora_instance.mesh
		demote.append(row)
	for si in range(slabs.size()):
		_set_slab_lod(slabs[si], alt_slabs[si])
	if in_ring:
		alt_slabs = demote
		alt_lod = 1 - alt_lod
		alt_stamp = stamp()
		alt_atlas = Data.atlas_tex
	else:
		clear_lod_cache()
	mesh_built = true
	lod_swaps += 1
	lod_swaps_instant += 1
	lod_last_swap_ms = (Time.get_ticks_usec() - t0) / 1000.0


func _assemble_slab(s: Slab, ao: Acc, ac: Acc, af_w: Acc, af_l: Acc, ak: Acc, ax: Acc, ms, full_solid: bool) -> void:
	var sidx := PackedInt32Array([-1, -1, -1, -1])
	var mesh := ArrayMesh.new()
	if ao.q > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _surface(ao))
		mesh.surface_set_material(0, _get_mat("opaque", ms.tex))
		sidx[0] = 0
	if mesh.get_surface_count() > 0:
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		add_child(mi)
		s.mesh_instance = mi
	if ac.q > 0 or af_w.q > 0 or af_l.q > 0:
		if ac.q > 0:
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _surface(ac))
			mesh.surface_set_material(mesh.get_surface_count() - 1, _get_mat("fluid"))
			sidx[1] = mesh.get_surface_count() - 1
		if af_w.q > 0:
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _surface(af_w))
			mesh.surface_set_material(mesh.get_surface_count() - 1, _fluid_anim_material(5))
			sidx[2] = mesh.get_surface_count() - 1
		if af_l.q > 0:
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _surface(af_l))
			mesh.surface_set_material(mesh.get_surface_count() - 1, _fluid_anim_material(24))
			sidx[3] = mesh.get_surface_count() - 1
		var fi := MeshInstance3D.new()
		fi.mesh = mesh
		add_child(fi)
		s.fluid_instance = fi
	if ak.q > 0 or ax.q > 0:
		var fsidx := PackedInt32Array([-1, -1])
		var fm := ArrayMesh.new()
		if ak.q > 0:
			fm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _surface(ak))
			fm.surface_set_material(0, _get_mat("cutout"))
			fsidx[0] = 0
		if ax.q > 0:
			fm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _surface(ax))
			fm.surface_set_material(fm.get_surface_count() - 1, _get_mat("flower"))
			fsidx[1] = fm.get_surface_count() - 1
		var fi2 := MeshInstance3D.new()
		fi2.mesh = fm
		add_child(fi2)
		s.flora_instance = fi2
		s.fsidx = fsidx
	if full_solid and _occl_enabled():
		var oc := OccluderInstance3D.new()
		var box := BoxOccluder3D.new()
		box.size = Vector3(15.0, 15.0, 15.0)
		oc.occluder = box
		oc.position = Vector3(8.0, float(s.y0) + 8.0, 8.0)
		add_child(oc)
		s.occluder = oc
	s.sidx = sidx
	s.built = true


func _post_build_collision() -> void:
	last_collision_build_ms = 0
	if not collision_enabled:
		return
	for s in slabs:
		if not s.col_dirty:
			continue
		if col_immediate:
			if s.collision_body != null:
				s.collision_body.queue_free()
				s.collision_body = null
			_build_slab_collision(s)
			s.col_dirty = false
		elif s.collision_body != null:
			s.collision_body.queue_free()
			s.collision_body = null
		elif s.mesh_instance == null or s.mesh_instance.mesh == null:
			s.col_dirty = false



static func _opaque_material(at: Texture2D = null) -> StandardMaterial3D:  # AC-0120: static (pure — only StandardMaterial3D + Data)
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	if at != null:
		m.albedo_texture = at
		m.albedo_color = Color.WHITE
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	elif Data.atlas_tex != null:
		m.albedo_texture = Data.atlas_tex
		m.albedo_color = Color.WHITE
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	m.roughness = 0.95
	return m


static func _cutout_material() -> StandardMaterial3D:  # AC-0120: static (pure)
	var m := _opaque_material()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	m.alpha_scissor_threshold = 0.5
	return m


static func _flower_material() -> StandardMaterial3D:  # AC-0120: static (pure)
	var m := _cutout_material()
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


static func _fluid_material() -> StandardMaterial3D:  # AC-0120: static (pure)
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(1, 1, 1, 0.62)
	m.roughness = 0.15
	if Data.atlas_tex != null:
		m.albedo_texture = Data.atlas_tex
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	return m


func _fluid_anim_material(id: int) -> Material:
	var m = Data.fluid_anim_mats.get(id)
	if m != null:
		return m
	return _fluid_material()


func _surface(arr: Acc) -> Array:
	arr.v.resize(arr.q * 4)
	arr.n.resize(arr.q * 4)
	arr.c.resize(arr.q * 4)
	arr.u.resize(arr.q * 4)
	arr.i.resize(arr.q * 6)
	var a: Array = []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = arr.v
	a[Mesh.ARRAY_NORMAL] = arr.n
	a[Mesh.ARRAY_TEX_UV] = arr.u
	a[Mesh.ARRAY_COLOR] = arr.c
	a[Mesh.ARRAY_INDEX] = arr.i
	return a


func build_mesh(get_world_block: Callable, eff: Dictionary = {}) -> void:
	# AC-0211: the sync lane runs the SAME C++ pipeline as the workers
	# (light -> compact nbs rings -> AweMesh.build_accs -> apply_accs);
	# inputs are read live (this is the MAIN thread and the C++ call is
	# synchronous — no value copies needed); a missing/empty neighbor reads
	# as air. AC-0208: C++-ONLY — the AWECRAFT_MESHCPP kill switch, the
	# GDScript flat-view/snap/scan/emit tail, the static GDScript build_accs
	# and _build_snap were removed (the C++ extension is required). An empty
	# data column (degenerate pre-data dispatch) = clear + built flag, no
	# geometry.
	for s in slabs:
		if s.mesh_instance != null:
			s.mesh_instance.queue_free()
			s.mesh_instance = null
		if s.fluid_instance != null:
			s.fluid_instance.queue_free()
			s.fluid_instance = null
		if s.flora_instance != null:
			s.flora_instance.queue_free()
			s.flora_instance = null
		if s.occluder != null:
			s.occluder.queue_free()
			s.occluder = null
	if data.is_empty():
		mesh_built = true
		mesh_gen += 1
		_post_build_collision()
		return
	var mc: Variant = mesh_cpp()
	var st = Game.world._strips_for(cx, cz)
	var light: Dictionary = eff
	if light.is_empty() or light.get("mask", null) == null:
		light = Lighting.compute_light_flat_chunk_pull(data, cx, cz, Data.HEIGHT, st["eff"], st["blk"], st["blk_b"])
		light_recomputes += 1
	var nbs: Dictionary = {}
	for s2 in [[-1, 0], [1, 0], [0, -1], [0, 1]]:
		var nc = Game.world.chunks.get(Game.world._key(cx + int(s2[0]), cz + int(s2[1])))
		if nc != null and nc.data.size() > 0:
			nbs["%d,%d" % [int(s2[0]), int(s2[1])]] = mc.snap_rings(nc.data, nc.fl, int(s2[0]), int(s2[1]))
	var ctx_w: Dictionary = make_ctx()
	ctx_w["eff_strips"] = st["eff"]
	ctx_w["blk_strips"] = st["blk"]
	ctx_w["blk_strips_b"] = st["blk_b"]
	ctx_w["top"] = int(top)
	if int(band) == 2:
		ctx_w["coarse"] = true
		ctx_w["uv_scale"] = 2
	var ms_full: Dictionary
	if OS.get_environment("AWECRAFT_MERGE") == "0":
		ms_full = {"tex": null, "rects": {}}
	else:
		ms_full = _merge_atlas()
	var ms_w: Dictionary
	if not ms_full.rects.is_empty():
		ms_w = {"rects": ms_full.rects.duplicate(), "h": float(ms_full.get("h", 0.0))}
	else:
		ms_w = {"rects": {}}
	var res: Dictionary = mc.build_accs(data, fl, cx, cz, nbs, ctx_w, ms_w, light, 0, -1, 0, Lighting._att, Lighting._glow)
	apply_accs(res, ms_full)


# AC-0128 RUN 3: the chunk keeps only the eff bytes (+blk_src) in last_eff -
# the 16KB block-light mask rides the light dict for the bake + the bounded
# eff cache (world.gd, EFF_CACHE_CAP) and is never pinned per-chunk (memory
# fence r50).
static func _eff_store(light: Dictionary) -> Dictionary:
	var t := {"mn": light["mn"], "w": light["w"], "d": light["d"], "arr": light["arr"]}
	if light.has("blk_src"):
		t["blk_src"] = light["blk_src"]
	return t


# AC-0107: main-thread assembly for the worker-built surface buffers — the
# build_mesh apply block (free old instances, ArrayMesh + materials, add
# instances, collision, flags) unchanged in effect; res comes from
# build_accs (worker) instead of the inline pipeline, ms is the current
# merge-atlas dict (tex consumed here only — workers never see the Texture2D).
func apply_accs(res: Dictionary, ms: Dictionary) -> void:
	for s in slabs:
		if s.mesh_instance != null:
			s.mesh_instance.queue_free()
			s.mesh_instance = null
		if s.fluid_instance != null:
			s.fluid_instance.queue_free()
			s.fluid_instance = null
		if s.flora_instance != null:
			s.flora_instance.queue_free()
			s.flora_instance = null
		if s.occluder != null:
			s.occluder.queue_free()
			s.occluder = null
	last_eff = _eff_store(res.light)
	last_blk_ring = res.light.get("ring", PackedInt32Array())
	if bool(res.get("light_recomputed", false)):
		light_recomputes += 1
	# AC-0197: res.slabs is PARTIAL (si0..si1 only). A full build now stops
	# at the top slab, so slabs above si1 were freed in the loop above and
	# stay empty (air) — exactly what the null rows carried before.
	var fsi0 := int(res.get("si0", 0))
	var fsi1 := int(res.get("si1", slab_n() - 1))
	for si in range(fsi0, fsi1 + 1):
		var row: Array = res.slabs[si - fsi0]
		_assemble_slab(slabs[si], _acc_from_dict(row[0]), _acc_from_dict(row[1]), _acc_from_dict(row[2]), _acc_from_dict(row[3]), _acc_from_dict(row[4]), _acc_from_dict(row[5]), ms, bool(row[6]))
	mesh_built = true
	mesh_gen += 1
	_post_build_collision()


func apply_edit_accs(res: Dictionary, ms: Dictionary) -> void:
	var pms := {"tex": null, "rects": {}, "h": 0.0}
	var si0 := int(res.get("si0", 0))
	var si1 := int(res.get("si1", slab_n() - 1))
	for si in range(si0, si1 + 1):
		var s = slabs[si]
		if s.mesh_instance != null:
			s.mesh_instance.queue_free()
			s.mesh_instance = null
		if s.fluid_instance != null:
			s.fluid_instance.queue_free()
			s.fluid_instance = null
		if s.flora_instance != null:
			s.flora_instance.queue_free()
			s.flora_instance = null
		if s.occluder != null:
			s.occluder.queue_free()
			s.occluder = null
	last_eff = _eff_store(res.light)
	last_blk_ring = res.light.get("ring", PackedInt32Array())
	if bool(res.get("light_recomputed", false)):
		light_recomputes += 1
	for i in range(si1 - si0 + 1):
		var row: Array = res.slabs[i]
		_assemble_slab(slabs[si0 + i], _acc_from_dict(row[0]), _acc_from_dict(row[1]), _acc_from_dict(row[2]), _acc_from_dict(row[3]), _acc_from_dict(row[4]), _acc_from_dict(row[5]), pms, bool(row[6]))
	mesh_built = true
	mesh_gen += 1
	_post_build_collision()


func _acc_from_dict(d: Dictionary) -> Acc:
	var a := Acc.new()
	a.v = d.v
	a.n = d.n
	a.c = d.c
	a.u = d.u
	a.i = d.i
	a.q = int(d.q)
	return a


func _build_slab_collision(s: Slab) -> void:
	var tb := Time.get_ticks_msec()
	if s.mesh_instance == null or s.mesh_instance.mesh == null:
		return
	var mesh: ArrayMesh = s.mesh_instance.mesh
	if mesh.get_surface_count() < 1:
		return
	var arrs := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrs[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrs[Mesh.ARRAY_INDEX]
	var faces := PackedVector3Array()
	faces.resize(idx.size())
	for i in range(idx.size()):
		faces[i] = verts[idx[i]]
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	add_child(body)
	s.collision_body = body
	last_collision_build_ms += Time.get_ticks_msec() - tb
	var si := 0
	while si < slabs.size() and slabs[si] != s:
		si += 1
	if si < slabs.size():
		perf_slab_body_builds[si] += 1
		perf_slab_body_ms[si] += float(Time.get_ticks_msec() - tb)