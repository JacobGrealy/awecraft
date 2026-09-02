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
var data := PackedByteArray()
var fl := PackedByteArray()
var mesh_built := false
var mesh_gen := 0
var collision_enabled := true
var col_immediate := true
var last_collision_build_ms := 0
var last_eff: Dictionary = {}
var last_blk_ring: PackedInt32Array = PackedInt32Array()
# AC-0129: bumped when last_eff's byte array changes (world._eff_landed);
# neighbors' eff-cache entries carry our gen at their dispatch (ngen) and
# invalidate when it moves — the pull strips derive from our last_eff.
var eff_gen := 0
var data_gen := 0
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
var alt_data := PackedByteArray()
var alt_fl := PackedByteArray()
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
	return data[(y << 8) | (lz << 4) | lx]


func set_local(lx: int, y: int, lz: int, id: int) -> void:
	data[(y << 8) | (lz << 4) | lx] = id
	data_gen += 1


func init_fl() -> void:
	# Natural water generates as a stationary source: fl stays 0 (fluid_level() maps
	# 0 -> 8 for display and sim), so the natural ocean never falls or churns.
	# Player/bucket water arrives later with an explicit fl (8) and flows.
	fl.resize(data.size())


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


func _faces(recs: Array, xtab: PackedByteArray, stab: PackedByteArray, fn: Array, lx: int, y: int, lz: int, id: int, snap: PackedByteArray) -> void:
	var sxi := (lz + 1) * SNAP_W + (lx + 1)
	for fi in range(6):
		var n: Vector3i = fn[fi]
		var ny := y + n.y
		var nb: int
		if ny < 0 or ny >= Data.HEIGHT:
			nb = 0
		else:
			nb = snap[ny * SNAP_ROW + sxi + n.z * SNAP_W + n.x]
		if nb == id:
			continue
		if stab[nb] > 0:
			continue
		var fni := 0
		if fi == 2:
			fni = 1
		elif fi == 3:
			fni = 2
		recs.append([lx, y, lz, fi, id, fni])


func _fluid_quad_count(lx: int, y: int, lz: int, id: int, hgt: float, snap: PackedByteArray, snap_fl: PackedByteArray) -> int:
	var rowl := (lz + 1) * SNAP_W + (lx + 1)
	var cnt := 0
	var above := 0
	if y + 1 < Data.HEIGHT:
		above = snap[(y + 1) * SNAP_ROW + rowl]
	if above != id:
		cnt += 1
	for fi in [0, 1, 4, 5]:
		var f: Dictionary = VoxelMath.FACES[fi]
		var n: Vector3i = f.n
		var nb: int = snap[y * SNAP_ROW + rowl + n.z * SNAP_W + n.x]
		var hn := 0.0
		if nb == id:
			hn = float(snap_fl[y * SNAP_ROW + rowl + n.z * SNAP_W + n.x]) / 8.0
		if hn < hgt:
			cnt += 1
	var below := 0
	if y > 0:
		below = snap[(y - 1) * SNAP_ROW + rowl]
	if y > 0 and below != id:
		cnt += 1
	return cnt


static func _fluid_hgt(lx: int, y: int, lz: int, snap: PackedByteArray, snap_fl: PackedByteArray) -> float:
	var rowl := (lz + 1) * SNAP_W + (lx + 1)
	var lvl: int = snap_fl[y * SNAP_ROW + rowl]
	if lvl <= 0:
		return -1.0
	return float(lvl) / 8.0


# AC-0107: acc is untyped on purpose — sync callers pass Acc, worker callers
# pass fresh plain dicts with the same keys (no GDScript objects in threads).
static func _qgrow(acc, nq: int) -> void:
	var v4 := nq * 4
	acc.v.resize(v4)
	acc.n.resize(v4)
	acc.c.resize(v4)
	acc.u.resize(v4)
	acc.i.resize(nq * 6)


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


func _emit_faces(recs: Array, accs: Array, lmn: Vector3i, larr: PackedByteArray, lw: int, ld: int, has_tex: bool, xtab: PackedByteArray, fn: Array, fsh: PackedFloat32Array, fcv: Array, ct: PackedColorArray, cs: PackedColorArray, cb: PackedColorArray, bmask: PackedByteArray) -> void:
	var rc := {}
	var uvc := {}
	var wx0 := cx * SIZE
	var wz0 := cz * SIZE
	for r in recs:
		var lx: int = r[0]
		var y: int = r[1]
		var lz: int = r[2]
		var fi: int = r[3]
		var id: int = r[4]
		var fni: int = r[5]
		var n: Vector3i = fn[fi]
		var face_color: Color
		var face_name := "side"
		if fni == 1:
			face_color = ct[id]
			face_name = "top"
		elif fni == 2:
			face_color = cb[id]
			face_name = "bottom"
		else:
			face_color = cs[id]
		if xtab[id] > 0:
			face_name = "side"
		# AC-0128: s = the light scalar (merge key shade = fsh * s stays
		# byte-identical); mask = own-chunk block-light evidence. The block
		# tints no longer ride the vertex color — they are baked into the
		# atlas pixels (data.gd _bake_atlas_tints).
		var s: float = _face_light(id, wx0 + lx, y, wz0 + lz, n, lmn, larr, lw, ld)
		var mask: int = _face_mask(id, wx0 + lx, y, wz0 + lz, n, lmn, Data.HEIGHT, bmask)
		var c: Color = _light_color(s, float(fsh[fi]), mask, face_color, has_tex)
		var uvs := _uvc(uvc, rc, id, fi, face_name, fn, fcv)
		var cva = fcv[fi]
		var sa = accs[y / 16]
		_qwrite(sa, sa.q, c, n, uvs, cva, lx, y, lz, float(cva[0].y), float(cva[1].y), float(cva[2].y), float(cva[3].y))
		sa.q += 1


static func _merge_strip(rects: Dictionary, id: int, fni: int) -> Vector2i:
	var face_name := "side"
	if fni == 1:
		face_name = "top"
	elif fni == 2:
		face_name = "bottom"
	var sr = rects.get("%d_%s" % [id, face_name])
	if sr == null:
		return Vector2i(-1, -1)
	return sr


# AC-0128: c0 payload = [id, fni, shade(=fsh*s merge key), s, mask, u0, v0, plane].
func _qwrite_merged(acc: Acc, fi: int, n: Vector3i, cva: Array, c0: Array, W: int, H: int, has_tex: bool, ct: PackedColorArray, cs: PackedColorArray, cb: PackedColorArray, fsh: PackedFloat32Array, sr: Vector2i, ms_h: float) -> void:
	var id: int = c0[0]
	var fni: int = c0[1]
	var shade: float = c0[2]
	var s: float = c0[3]
	var mask: int = c0[4]
	var u0: int = c0[5]
	var v0: int = c0[6]
	var plane: int = c0[7]
	var face_name := "side"
	var face_color: Color
	if fni == 1:
		face_color = ct[id]
		face_name = "top"
	elif fni == 2:
		face_color = cb[id]
		face_name = "bottom"
	else:
		face_color = cs[id]
	# AC-0128: repacked vColor (s, fsh, mask) — tints live in the atlas now.
	# (fsh is indexed by fi; fni collapses top/bottom/side for face_color only.)
	var c: Color = _light_color(s, float(fsh[fi]), mask, face_color, has_tex)
	var tl: Vector2i = Data.block_rect(id, face_name)
	var b := acc.q * 4
	var ib := acc.q * 6
	for j in range(4):
		var cv: Vector3 = cva[j]
		var px: float
		var py: float
		var pz: float
		var uu: float
		var vv: float
		if fi == 2:
			px = float(u0) + cv.x * float(W)
			py = float(plane) + 1.0
			pz = float(v0) + cv.z * float(H)
			uu = 0.5 + cv.x * float(W) * 31.0
			vv = 0.5 + cv.z * float(H) * 31.0
		elif fi == 3:
			px = float(u0) + cv.x * float(W)
			py = float(plane)
			pz = float(v0) + cv.z * float(H)
			uu = 0.5 + cv.x * float(W) * 31.0
			vv = 0.5 + cv.z * float(H) * 31.0
		elif fi == 0:
			px = float(plane)
			py = float(v0) + cv.y * float(H)
			pz = float(u0) + cv.z * float(W)
			uu = 0.5 + cv.z * float(W) * 31.0
			vv = 0.5 + (1.0 - cv.y) * float(H) * 31.0
		elif fi == 1:
			px = float(plane) + 1.0
			py = float(v0) + cv.y * float(H)
			pz = float(u0) + cv.z * float(W)
			uu = 0.5 + cv.z * float(W) * 31.0
			vv = 0.5 + (1.0 - cv.y) * float(H) * 31.0
		elif fi == 4:
			px = float(u0) + cv.x * float(W)
			py = float(v0) + cv.y * float(H)
			pz = float(plane)
			uu = 0.5 + cv.x * float(W) * 31.0
			vv = 0.5 + (1.0 - cv.y) * float(H) * 31.0
		else:
			px = float(u0) + cv.x * float(W)
			py = float(v0) + cv.y * float(H)
			pz = float(plane) + 1.0
			uu = 0.5 + cv.x * float(W) * 31.0
			vv = 0.5 + (1.0 - cv.y) * float(H) * 31.0
		acc.v[b + j] = Vector3(px, py, pz)
		acc.n[b + j] = Vector3(n)
		acc.c[b + j] = c
		if sr != Vector2i(-1, -1):
			acc.u[b + j] = (Vector2(sr) + Vector2(uu, vv)) / Vector2(Data.ATLAS_PX, ms_h)
		elif tl.x < 0:
			acc.u[b + j] = Vector2.ZERO
		else:
			var cu: float
			var cvv: float
			if fi == 2 or fi == 3:
				cu = cv.x
				cvv = cv.z
			elif fi == 0 or fi == 1:
				cu = cv.z
				cvv = 1.0 - cv.y
			else:
				cu = cv.x
				cvv = 1.0 - cv.y
			acc.u[b + j] = (Vector2(tl) + Vector2(0.5 + cu * 31.0, 0.5 + cvv * 31.0)) / Vector2(Data.ATLAS_PX, ms_h)
	acc.i[ib] = b
	acc.i[ib + 1] = b + 2
	acc.i[ib + 2] = b + 1
	acc.i[ib + 3] = b
	acc.i[ib + 4] = b + 3
	acc.i[ib + 5] = b + 2
	acc.q += 1


func _emit_ro_merged(recs: Array, accs: Array, lmn: Vector3i, larr: PackedByteArray, lw: int, ld: int, has_tex: bool, fn: Array, fsh: PackedFloat32Array, fcv: Array, ct: PackedColorArray, cs: PackedColorArray, cb: PackedColorArray, ms: Dictionary, bmask: PackedByteArray) -> void:
	var rects: Dictionary = ms.rects
	var ms_h: float = float(ms.get("h", Data.ATLAS_PX))
	var wx0 := cx * SIZE
	var wz0 := cz * SIZE
	var hgt := Data.HEIGHT
	# grid layout per face: [id, fni, shade, s, mask, u0, v0, plane] with
	# key = plane * (vmax * 16) + v0 * 16 + u0 (arithmetic — bit packing collides for y >= 16).
	# AC-0128: the merge key stays [id, fni, shade] (byte-identical MINFO); s and
	# the own-chunk block-light mask ride along for the repacked vColor.
	# fi0/1: plane = lx, v0 = y,  u0 = lz (strip runs along z).
	# fi2/3: plane = y,  v0 = lz, u0 = lx (strip runs along x; 3D so columns with
	#      multiple exposed top/bottom faces at different y all survive).
	# fi4/5: plane = lz, v0 = y,  u0 = lx (strip runs along x).
	var grids: Array = []
	for f in range(6):
		var g: Array = []
		g.resize(16 * hgt * 16)
		grids.append(g)
	for r in recs:
		var lx: int = r[0]
		var y: int = r[1]
		var lz: int = r[2]
		var fi: int = r[3]
		var id: int = r[4]
		var fni: int = r[5]
		var n: Vector3i = fn[fi]
		var sl: float = _face_light(id, wx0 + lx, y, wz0 + lz, n, lmn, larr, lw, ld)
		var mask: int = _face_mask(id, wx0 + lx, y, wz0 + lz, n, lmn, hgt, bmask)
		var shade: float = float(fsh[fi]) * sl
		if fi == 2 or fi == 3:
			grids[fi][y * 256 + lz * 16 + lx] = [id, fni, shade, sl, mask, lx, lz, y]
		elif fi == 0 or fi == 1:
			grids[fi][lx * (hgt * 16) + y * 16 + lz] = [id, fni, shade, sl, mask, lz, y, lx]
		else:
			grids[fi][lz * (hgt * 16) + y * 16 + lx] = [id, fni, shade, sl, mask, lx, y, lz]
	for fi in range(6):
		var n: Vector3i = fn[fi]
		var cva: Array = fcv[fi]
		var g: Array = grids[fi]
		var horiz := fi == 2 or fi == 3
		var pmax: int = hgt if horiz else 16
		var vmax: int = 16 if horiz else hgt
		var pstride: int = vmax * 16
		for plane in range(pmax):
			var pi := plane * pstride
			for v0 in range(vmax):
				var vi := pi + v0 * 16
				for u0 in range(16):
					var c0 = g[vi | u0]
					if c0 == null:
						continue
					var w := 1
					while u0 + w < 16:
						var cn = g[vi | (u0 + w)]
						if cn == null or cn[0] != c0[0] or cn[1] != c0[1] or cn[2] != c0[2]:
							break
						w += 1
						g[vi | (u0 + w - 1)] = null
					# bounded 2D growth: extend down (v-axis) up to H=4 while the
					# full width matches on every row (atlas strips tile 4 rows).
					var h := 1
					while h < 4 and v0 + h < vmax:
						var vmatch := true
						for u in range(u0, u0 + w):
							var cc = g[vi + h * 16 + u]
							if cc == null or cc[0] != c0[0] or cc[1] != c0[1] or cc[2] != c0[2]:
								vmatch = false
								break
						if not vmatch:
							break
						for u in range(u0, u0 + w):
							g[vi + h * 16 + u] = null
						h += 1
					g[vi | u0] = null
					# AC-0128: the y coordinate moved from c0[4]/c0[5] to c0[6]/c0[7].
					var si: int = (int(c0[6]) if (fi == 0 or fi == 1 or fi == 4 or fi == 5) else int(c0[7])) / 16
					_qwrite_merged(accs[si], fi, n, cva, c0, w, h, has_tex, ct, cs, cb, fsh, _merge_strip(rects, int(c0[0]), int(c0[1])), ms_h)


func _emit_xquad(recs: Array, accs: Array, lmn: Vector3i, larr: PackedByteArray, lw: int, ld: int, has_tex: bool, ct: PackedColorArray, bmask: PackedByteArray) -> void:
	var rc := {}
	var uvc := {}
	var wx0 := cx * SIZE
	var wz0 := cz * SIZE
	for r in recs:
		var lx: int = r[0]
		var y: int = r[1]
		var lz: int = r[2]
		var id: int = r[3]
		# AC-0128: s = light scalar (the 0.9 face shade moves to the b channel
		# of the repack); mask = own-cell evidence (cross blocks sample only
		# their own cell for light, like _face_light id==22).
		var s: float = clampf(float(_effl(lmn, larr, lw, ld, wx0 + lx, y, wz0 + lz)) / 15.0, MIN_AMB, 1.0)
		var mask: int = _mask_sample(wx0 + lx, y, wz0 + lz, lmn, Data.HEIGHT, bmask)
		var c: Color
		if has_tex:
			c = _light_color(s, 0.9, mask, Color.WHITE, true)
		else:
			c = ct[id] * 0.9
		var ukey := id * 8 + 2
		var uvs = uvc.get(ukey)
		if uvs == null:
			var tl := _face_rect(rc, id, 2, "top")
			var u0 := PackedVector2Array()
			var u1 := PackedVector2Array()
			for i in range(4):
				u0.append(_corner_uv(XQ_A[i], Vector3i(0, 0, 1), tl))
				u1.append(_corner_uv(XQ_B[i], Vector3i(1, 0, 0), tl))
			uvs = [u0, u1]
			uvc[ukey] = uvs
		var sa = accs[y / 16]
		_qwrite(sa, sa.q, c, Vector3i(0, 0, 1), uvs[0], XQ_A, lx, y, lz, 0.0, 0.0, 1.0, 1.0)
		sa.q += 1
		_qwrite(sa, sa.q, c, Vector3i(1, 0, 0), uvs[1], XQ_B, lx, y, lz, 0.0, 0.0, 1.0, 1.0)
		sa.q += 1



func _emit_fluid(recs: Array, accs: Array, snap: PackedByteArray, snap_fl: PackedByteArray, has_tex: bool, fn: Array, fcv: Array, ct: PackedColorArray, cs: PackedColorArray, cb: PackedColorArray) -> void:
	var rc := {}
	var uvc := {}
	for r in recs:
		var lx: int = r[0]
		var y: int = r[1]
		var lz: int = r[2]
		var id: int = r[3]
		var hgt: float = r[4]
		var sa = accs[y / 16]
		var rowl := (lz + 1) * SNAP_W + (lx + 1)
		# AC-0128: fluid surface quads keep the legacy gray vColor (no eff
		# bake — pre-existing gap, plan §7 out of scope) but the block tints
		# are dropped: they are baked into the atlas pixels now.
		var above := 0
		if y + 1 < Data.HEIGHT:
			above = snap[(y + 1) * SNAP_ROW + rowl]
		if above != id:
			var top_h := minf(hgt, 0.875 if id == 5 else 0.95)
			_qwrite(sa, sa.q, Color(0.95, 0.95, 0.95, 1.0) if has_tex else ct[id] * 0.95, Vector3i(0, 1, 0), _uvc(uvc, rc, id, 2, "top", fn, fcv), fcv[2], lx, y, lz, top_h, top_h, top_h, top_h)
			sa.q += 1
		for fi in [0, 1, 4, 5]:
			var n: Vector3i = fn[fi]
			var nb: int = snap[y * SNAP_ROW + rowl + n.z * SNAP_W + n.x]
			var hn := 0.0
			if nb == id:
				hn = float(snap_fl[y * SNAP_ROW + rowl + n.z * SNAP_W + n.x]) / 8.0
			if hn >= hgt:
				continue
			var cva = fcv[fi]
			_qwrite(sa, sa.q, Color(0.85, 0.85, 0.85, 1.0) if has_tex else cs[id] * 0.85, n, _uvc(uvc, rc, id, fi, "side", fn, fcv), cva, lx, y, lz, hgt if cva[0].y == 1.0 else hn, hgt if cva[1].y == 1.0 else hn, hgt if cva[2].y == 1.0 else hn, hgt if cva[3].y == 1.0 else hn)
			sa.q += 1
		var below := 0
		if y > 0:
			below = snap[(y - 1) * SNAP_ROW + rowl]
		if y > 0 and below != id:
			_qwrite(sa, sa.q, Color(0.6, 0.6, 0.6, 1.0) if has_tex else cb[id] * 0.6, Vector3i(0, -1, 0), _uvc(uvc, rc, id, 3, "bottom", fn, fcv), fcv[3], lx, y, lz, 0.0, 0.0, 0.0, 0.0)
			sa.q += 1


static func _band(delta: int) -> Array:
	if delta == -1:
		return [[0, 15]]
	if delta == 1:
		return [[17, 0]]
	var out: Array = []
	for v in range(16):
		out.append([v + 1, v])
	return out


# ---------------------------------------------------------------------------
# AC-0107 (threaded mesh+light, desktop Phase 3): pure-static worker mirrors.
# These run on WorkerThreadPool threads over FRESH data copies + the immutable
# main-thread ctx snapshot (make_ctx) — NO Data/Game/node access anywhere
# below. The sync build_mesh/_build_snap/_emit_* path above stays untouched
# (the sync path — spawn chunk, missing neighbor, cap-drop — keeps byte-identical behavior and output).
# ---------------------------------------------------------------------------

static func _s_effl(lmn: Vector3i, larr: PackedByteArray, lw: int, ld: int, x: int, y: int, z: int, h: int) -> int:
	if y < 0:
		return 0
	if y >= h:
		return 15
	var ix := x - lmn.x
	var iz := z - lmn.z
	if ix < 0 or iz < 0 or ix >= lw or iz >= ld:
		return 15
	return larr[(y - lmn.y) * lw * ld + iz * lw + ix]


static func _s_face_light(id: int, wx: int, y: int, wz: int, n: Vector3i, lmn: Vector3i, larr: PackedByteArray, lw: int, ld: int, h: int) -> float:
	var v := 0
	if id == 22:
		v = _s_effl(lmn, larr, lw, ld, wx, y, wz, h)
	else:
		var nx := wx + n.x
		var ny := y + n.y
		var nz := wz + n.z
		v = _s_effl(lmn, larr, lw, ld, nx, ny, nz, h)
		if v < 15 and id != 5 and id != 24:
			if n.x == 0:
				v = maxi(v, _s_effl(lmn, larr, lw, ld, nx + 1, ny, nz, h))
				if v < 15:
					v = maxi(v, _s_effl(lmn, larr, lw, ld, nx - 1, ny, nz, h))
			if v < 15 and n.y == 0:
				v = maxi(v, _s_effl(lmn, larr, lw, ld, nx, ny + 1, nz, h))
				if v < 15:
					v = maxi(v, _s_effl(lmn, larr, lw, ld, nx, ny - 1, nz, h))
			if v < 15 and n.z == 0:
				v = maxi(v, _s_effl(lmn, larr, lw, ld, nx, ny, nz + 1, h))
				if v < 15:
					v = maxi(v, _s_effl(lmn, larr, lw, ld, nx, ny, nz - 1, h))
	return clampf(float(v) / 15.0, MIN_AMB, 1.0)


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


static func _s_is_interior(lx: int, y: int, lz: int, snap: PackedByteArray, stab: PackedByteArray, h: int) -> bool:
	if y == 0 or y == h - 1:
		return false
	var mid := (lz + 1) * SNAP_W + (lx + 1)
	var row := y * SNAP_ROW + mid
	var rowd := (y - 1) * SNAP_ROW + mid
	var rowu := (y + 1) * SNAP_ROW + mid
	return stab[snap[row - 1]] > 0 and stab[snap[row + 1]] > 0 \
		and stab[snap[row - SNAP_W]] > 0 and stab[snap[row + SNAP_W]] > 0 \
		and stab[snap[rowu]] > 0 and stab[snap[rowd]] > 0


static func _s_faces(recs: Array, xtab: PackedByteArray, stab: PackedByteArray, fn: Array, lx: int, y: int, lz: int, id: int, snap: PackedByteArray, h: int) -> void:
	var sxi := (lz + 1) * SNAP_W + (lx + 1)
	for fi in range(6):
		var n: Vector3i = fn[fi]
		var ny := y + n.y
		var nb: int
		if ny < 0 or ny >= h:
			nb = 0
		else:
			nb = snap[ny * SNAP_ROW + sxi + n.z * SNAP_W + n.x]
		if nb == id:
			continue
		if stab[nb] > 0:
			continue
		var fni := 0
		if fi == 2:
			fni = 1
		elif fi == 3:
			fni = 2
		recs.append([lx, y, lz, fi, id, fni])


static func _s_fluid_quad_count(lx: int, y: int, lz: int, id: int, hgt: float, snap: PackedByteArray, snap_fl: PackedByteArray, h: int, fn: Array) -> int:
	var rowl := (lz + 1) * SNAP_W + (lx + 1)
	var cnt := 0
	var above := 0
	if y + 1 < h:
		above = snap[(y + 1) * SNAP_ROW + rowl]
	if above != id:
		cnt += 1
	for fi in [0, 1, 4, 5]:
		var n: Vector3i = fn[fi]
		var nb: int = snap[y * SNAP_ROW + rowl + n.z * SNAP_W + n.x]
		var hn := 0.0
		if nb == id:
			hn = float(snap_fl[y * SNAP_ROW + rowl + n.z * SNAP_W + n.x]) / 8.0
		if hn < hgt:
			cnt += 1
	var below := 0
	if y > 0:
		below = snap[(y - 1) * SNAP_ROW + rowl]
	if y > 0 and below != id:
		cnt += 1
	return cnt


static func _s_emit_faces(recs: Array, accs: Array, lmn: Vector3i, larr: PackedByteArray, lw: int, ld: int, cx: int, cz: int, has_tex: bool, xtab: PackedByteArray, ctx: Dictionary, bmask: PackedByteArray) -> void:
	var fn: Array = ctx["fn"]
	var fsh: PackedFloat32Array = ctx["fsh"]
	var fcv: Array = ctx["fcv"]
	var ct: PackedColorArray = ctx["ct"]
	var cs: PackedColorArray = ctx["cs"]
	var cb: PackedColorArray = ctx["cb"]
	var brect: Dictionary = ctx["brect"]
	var atlas_px: float = float(ctx["atlas_px"])
	var ppb: float = 31.0 / float(ctx.get("uv_scale", 1))
	var h: int = int(ctx["h"])
	var uvc := {}
	var wx0 := cx * SIZE
	var wz0 := cz * SIZE
	for r in recs:
		var lx: int = r[0]
		var y: int = r[1]
		var lz: int = r[2]
		var fi: int = r[3]
		var id: int = r[4]
		var fni: int = r[5]
		var n: Vector3i = fn[fi]
		var face_color: Color
		var face_name := "side"
		var tint: Color = ctx["tint_side"][id]
		if fni == 1:
			face_color = ct[id]
			face_name = "top"
			tint = ctx["tint_top"][id]
		elif fni == 2:
			face_color = cb[id]
			face_name = "bottom"
			tint = ctx["tint_bottom"][id]
		else:
			face_color = cs[id]
		if xtab[id] > 0:
			face_name = "side"
			tint = ctx["tint_side"][id]
		# AC-0128: s + own-chunk mask (tints are baked into the atlas; the
		# ctx tint arrays are white with the atlas, so the multiply below is
		# a no-op in the lit path).
		var sl: float = _s_face_light(id, wx0 + lx, y, wz0 + lz, n, lmn, larr, lw, ld, h)
		var mask: int = _face_mask(id, wx0 + lx, y, wz0 + lz, n, lmn, h, bmask)
		var c: Color = _light_color(sl, float(fsh[fi]), mask, face_color, has_tex)
		if has_tex:
			c = c * tint
		var uvs := _s_uvc(uvc, brect, id, fi, face_name, fn, fcv, atlas_px, ppb)
		var cva = fcv[fi]
		var sa = accs[y / 16]
		_qwrite(sa, sa.q, c, n, uvs, cva, lx, y, lz, float(cva[0].y), float(cva[1].y), float(cva[2].y), float(cva[3].y))
		sa.q += 1


# AC-0128: c0 payload = [id, fni, shade(=fsh*s merge key), s, mask, u0, v0, plane].
static func _s_qwrite_merged(acc, fi: int, n: Vector3i, cva: Array, c0: Array, W: int, H: int, has_tex: bool, ctx: Dictionary, sr: Vector2i, ms_h: float) -> void:
	var id: int = c0[0]
	var fni: int = c0[1]
	var shade: float = c0[2]
	var s: float = c0[3]
	var mask: int = c0[4]
	var u0: int = c0[5]
	var v0: int = c0[6]
	var plane: int = c0[7]
	var face_name := "side"
	var face_color: Color
	var tint: Color = ctx["tint_side"][id]
	if fni == 1:
		face_color = ctx["ct"][id]
		face_name = "top"
		tint = ctx["tint_top"][id]
	elif fni == 2:
		face_color = ctx["cb"][id]
		face_name = "bottom"
		tint = ctx["tint_bottom"][id]
	else:
		face_color = ctx["cs"][id]
	# AC-0128: repacked vColor (s, fsh[fi], mask); ctx tints are white with
	# the atlas, so the multiply below stays a no-op in the lit path.
	var c: Color = _light_color(s, float(ctx["fsh"][fi]), mask, face_color, has_tex)
	if has_tex:
		c = c * tint
	var tl: Vector2i = ctx["brect"].get("%d_%s" % [id, face_name], Vector2i(-1, -1))
	var atlas_px: float = float(ctx["atlas_px"])
	var ppb: float = 31.0 / float(ctx.get("uv_scale", 1))
	var b: int = int(acc.q) * 4
	var ib: int = int(acc.q) * 6
	for j in range(4):
		var cv: Vector3 = cva[j]
		var px: float
		var py: float
		var pz: float
		var uu: float
		var vv: float
		if fi == 2:
			px = float(u0) + cv.x * float(W)
			py = float(plane) + 1.0
			pz = float(v0) + cv.z * float(H)
			uu = 0.5 + cv.x * float(W) * ppb
			vv = 0.5 + cv.z * float(H) * ppb
		elif fi == 3:
			px = float(u0) + cv.x * float(W)
			py = float(plane)
			pz = float(v0) + cv.z * float(H)
			uu = 0.5 + cv.x * float(W) * ppb
			vv = 0.5 + cv.z * float(H) * ppb
		elif fi == 0:
			px = float(plane)
			py = float(v0) + cv.y * float(H)
			pz = float(u0) + cv.z * float(W)
			uu = 0.5 + cv.z * float(W) * ppb
			vv = 0.5 + (1.0 - cv.y) * float(H) * ppb
		elif fi == 1:
			px = float(plane) + 1.0
			py = float(v0) + cv.y * float(H)
			pz = float(u0) + cv.z * float(W)
			uu = 0.5 + cv.z * float(W) * ppb
			vv = 0.5 + (1.0 - cv.y) * float(H) * ppb
		elif fi == 4:
			px = float(u0) + cv.x * float(W)
			py = float(v0) + cv.y * float(H)
			pz = float(plane)
			uu = 0.5 + cv.x * float(W) * ppb
			vv = 0.5 + (1.0 - cv.y) * float(H) * ppb
		else:
			px = float(u0) + cv.x * float(W)
			py = float(v0) + cv.y * float(H)
			pz = float(plane) + 1.0
			uu = 0.5 + cv.x * float(W) * ppb
			vv = 0.5 + (1.0 - cv.y) * float(H) * ppb
		acc.v[b + j] = Vector3(px, py, pz)
		acc.n[b + j] = Vector3(n)
		acc.c[b + j] = c
		if sr != Vector2i(-1, -1):
			acc.u[b + j] = (Vector2(sr) + Vector2(uu, vv)) / Vector2(atlas_px, ms_h)
		elif tl.x < 0:
			acc.u[b + j] = Vector2.ZERO
		else:
			var cu: float
			var cvv: float
			if fi == 2 or fi == 3:
				cu = cv.x
				cvv = cv.z
			elif fi == 0 or fi == 1:
				cu = cv.z
				cvv = 1.0 - cv.y
			else:
				cu = cv.x
				cvv = 1.0 - cv.y
			acc.u[b + j] = (Vector2(tl) + Vector2(0.5 + cu * ppb, 0.5 + cvv * ppb)) / Vector2(atlas_px, ms_h)
	acc.i[ib] = b
	acc.i[ib + 1] = b + 2
	acc.i[ib + 2] = b + 1
	acc.i[ib + 3] = b
	acc.i[ib + 4] = b + 3
	acc.i[ib + 5] = b + 2
	acc.q += 1


static func _s_emit_ro_merged(recs: Array, accs: Array, lmn: Vector3i, larr: PackedByteArray, lw: int, ld: int, cx: int, cz: int, has_tex: bool, ctx: Dictionary, ms: Dictionary, bmask: PackedByteArray) -> void:
	var rects: Dictionary = ms.rects
	var ms_h: float = float(ms.get("h", float(ctx["atlas_px"])))
	var wx0 := cx * SIZE
	var wz0 := cz * SIZE
	var hgt: int = int(ctx["h"])
	var fn: Array = ctx["fn"]
	var fsh: PackedFloat32Array = ctx["fsh"]
	var fcv: Array = ctx["fcv"]
	# grid layout per face: [id, fni, shade, u0, v0, plane] with
	# key = plane * (vmax * 16) + v0 * 16 + u0 (arithmetic — bit packing collides for y >= 16).
	# fi0/1: plane = lx, v0 = y,  u0 = lz (strip runs along z).
	# fi2/3: plane = y,  v0 = lz, u0 = lx (strip runs along x; 3D so columns with
	#      multiple exposed top/bottom faces at different y all survive).
	# fi4/5: plane = lz, v0 = y,  u0 = lx (strip runs along x).
	var grids: Array = []
	for f in range(6):
		var g: Array = []
		g.resize(16 * hgt * 16)
		grids.append(g)
	for r in recs:
		var lx: int = r[0]
		var y: int = r[1]
		var lz: int = r[2]
		var fi: int = r[3]
		var id: int = r[4]
		var fni: int = r[5]
		var n: Vector3i = fn[fi]
		# AC-0128: merge key stays [id, fni, shade]; s + own-chunk mask ride along.
		var sl: float = _s_face_light(id, wx0 + lx, y, wz0 + lz, n, lmn, larr, lw, ld, hgt)
		var mask: int = _face_mask(id, wx0 + lx, y, wz0 + lz, n, lmn, hgt, bmask)
		var shade: float = float(fsh[fi]) * sl
		if fi == 2 or fi == 3:
			grids[fi][y * 256 + lz * 16 + lx] = [id, fni, shade, sl, mask, lx, lz, y]
		elif fi == 0 or fi == 1:
			grids[fi][lx * (hgt * 16) + y * 16 + lz] = [id, fni, shade, sl, mask, lz, y, lx]
		else:
			grids[fi][lz * (hgt * 16) + y * 16 + lx] = [id, fni, shade, sl, mask, lx, y, lz]
	for fi in range(6):
		var n: Vector3i = fn[fi]
		var cva: Array = fcv[fi]
		var g: Array = grids[fi]
		var horiz := fi == 2 or fi == 3
		var pmax: int = hgt if horiz else 16
		var vmax: int = 16 if horiz else hgt
		var pstride: int = vmax * 16
		for plane in range(pmax):
			var pi := plane * pstride
			for v0 in range(vmax):
				var vi := pi + v0 * 16
				for u0 in range(16):
					var c0 = g[vi | u0]
					if c0 == null:
						continue
					var w := 1
					while u0 + w < 16:
						var cn = g[vi | (u0 + w)]
						if cn == null or cn[0] != c0[0] or cn[1] != c0[1] or cn[2] != c0[2]:
							break
						w += 1
						g[vi | (u0 + w - 1)] = null
					# bounded 2D growth: extend down (v-axis) up to H=4 while the
					# full width matches on every row (atlas strips tile 4 rows).
					var h := 1
					while h < 4 and v0 + h < vmax:
						var vmatch := true
						for u in range(u0, u0 + w):
							var cc = g[vi + h * 16 + u]
							if cc == null or cc[0] != c0[0] or cc[1] != c0[1] or cc[2] != c0[2]:
								vmatch = false
								break
						if not vmatch:
							break
						for u in range(u0, u0 + w):
							g[vi + h * 16 + u] = null
						h += 1
					g[vi | u0] = null
					# AC-0128: the y coordinate moved from c0[4]/c0[5] to c0[6]/c0[7].
					var si: int = (int(c0[6]) if (fi == 0 or fi == 1 or fi == 4 or fi == 5) else int(c0[7])) / 16
					_s_qwrite_merged(accs[si], fi, n, cva, c0, w, h, has_tex, ctx, _merge_strip(rects, int(c0[0]), int(c0[1])), ms_h)


static func _s_emit_xquad(recs: Array, accs: Array, lmn: Vector3i, larr: PackedByteArray, lw: int, ld: int, cx: int, cz: int, has_tex: bool, ctx: Dictionary, bmask: PackedByteArray) -> void:
	var brect: Dictionary = ctx["brect"]
	var atlas_px: float = float(ctx["atlas_px"])
	var h: int = int(ctx["h"])
	var uvc := {}
	var wx0 := cx * SIZE
	var wz0 := cz * SIZE
	for r in recs:
		var lx: int = r[0]
		var y: int = r[1]
		var lz: int = r[2]
		var id: int = r[3]
		# AC-0128: s = light scalar (0.9 face shade -> b channel); mask =
		# own-cell evidence; ctx tints are white with the atlas.
		var s: float = clampf(float(_s_effl(lmn, larr, lw, ld, wx0 + lx, y, wz0 + lz, h)) / 15.0, MIN_AMB, 1.0)
		var mask: int = _mask_sample(wx0 + lx, y, wz0 + lz, lmn, h, bmask)
		var c: Color
		if has_tex:
			c = _light_color(s, 0.9, mask, Color.WHITE, true) * ctx["tint_top"][id]
		else:
			c = ctx["ct"][id] * 0.9
		var ukey := id * 8 + 2
		var uvs = uvc.get(ukey)
		if uvs == null:
			var tl: Vector2i = brect.get("%d_top" % id, Vector2i(-1, -1))
			var u0 := PackedVector2Array()
			var u1 := PackedVector2Array()
			for i in range(4):
				u0.append(_s_corner_uv(XQ_A[i], Vector3i(0, 0, 1), tl, atlas_px))
				u1.append(_s_corner_uv(XQ_B[i], Vector3i(1, 0, 0), tl, atlas_px))
			uvs = [u0, u1]
			uvc[ukey] = uvs
		var sa = accs[y / 16]
		_qwrite(sa, sa.q, c, Vector3i(0, 0, 1), uvs[0], XQ_A, lx, y, lz, 0.0, 0.0, 1.0, 1.0)
		sa.q += 1
		_qwrite(sa, sa.q, c, Vector3i(1, 0, 0), uvs[1], XQ_B, lx, y, lz, 0.0, 0.0, 1.0, 1.0)
		sa.q += 1


static func _s_emit_fluid(recs: Array, accs: Array, snap: PackedByteArray, snap_fl: PackedByteArray, has_tex: bool, ctx: Dictionary, h: int) -> void:
	var brect: Dictionary = ctx["brect"]
	var atlas_px: float = float(ctx["atlas_px"])
	var fn: Array = ctx["fn"]
	var fcv: Array = ctx["fcv"]
	var uvc := {}
	for r in recs:
		var lx: int = r[0]
		var y: int = r[1]
		var lz: int = r[2]
		var id: int = r[3]
		var hgt: float = r[4]
		var ppb: float = 31.0 / float(ctx.get("uv_scale", 1))
		var sa = accs[y / 16]
		var rowl := (lz + 1) * SNAP_W + (lx + 1)
		var tint_t: Color = ctx["tint_top"][id]
		var tint_s: Color = ctx["tint_side"][id]
		var tint_b: Color = ctx["tint_bottom"][id]
		var above := 0
		if y + 1 < h:
			above = snap[(y + 1) * SNAP_ROW + rowl]
		if above != id:
			var top_h := minf(hgt, 0.875 if id == 5 else 0.95)
			_qwrite(sa, sa.q, Color(0.95, 0.95, 0.95, 1.0) * tint_t if has_tex else ctx["ct"][id] * 0.95, Vector3i(0, 1, 0), _s_uvc(uvc, brect, id, 2, "top", fn, fcv, atlas_px, ppb), fcv[2], lx, y, lz, top_h, top_h, top_h, top_h)
			sa.q += 1
		for fi in [0, 1, 4, 5]:
			var n: Vector3i = fn[fi]
			var nb: int = snap[y * SNAP_ROW + rowl + n.z * SNAP_W + n.x]
			var hn := 0.0
			if nb == id:
				hn = float(snap_fl[y * SNAP_ROW + rowl + n.z * SNAP_W + n.x]) / 8.0
			if hn >= hgt:
				continue
			var cva = fcv[fi]
			_qwrite(sa, sa.q, Color(0.85, 0.85, 0.85, 1.0) * tint_s if has_tex else ctx["cs"][id] * 0.85, n, _s_uvc(uvc, brect, id, fi, "side", fn, fcv, atlas_px, ppb), cva, lx, y, lz, hgt if cva[0].y == 1.0 else hn, hgt if cva[1].y == 1.0 else hn, hgt if cva[2].y == 1.0 else hn, hgt if cva[3].y == 1.0 else hn)
			sa.q += 1
		var below := 0
		if y > 0:
			below = snap[(y - 1) * SNAP_ROW + rowl]
		if y > 0 and below != id:
			_qwrite(sa, sa.q, Color(0.6, 0.6, 0.6, 1.0) * tint_b if has_tex else ctx["cb"][id] * 0.6, Vector3i(0, -1, 0), _s_uvc(uvc, brect, id, 3, "bottom", fn, fcv, atlas_px, ppb), fcv[3], lx, y, lz, 0.0, 0.0, 0.0, 0.0)
			sa.q += 1


static func _build_snap_data(snap: PackedByteArray, snap_fl: PackedByteArray, data: PackedByteArray, fl: PackedByteArray, cx: int, cz: int, nbs: Dictionary, h: int, y_lo := 0, y_hi := -1, d_off := 0) -> void:
	# Static mirror of _build_snap: the 8 neighbor copies are ALWAYS present in
	# nbs (dispatch rule: a missing neighbor takes the sync path instead), so
	# the Game.world / on-demand-generation fallback of _build_snap is absent.
	# y_lo/y_hi scope the row fill (slab-scoped edit builds); rows outside the
	# range stay zero (never sampled by scoped face/interior checks).
	if y_hi < 0:
		y_hi = h - 1
	var d: PackedByteArray = data
	var fd: PackedByteArray = fl
	for y in range(y_lo, y_hi + 1):
		var si := y * SNAP_ROW
		var di := (y - d_off) << 8
		for lz in range(SIZE):
			var szi := si + (lz + 1) * SNAP_W
			var drow := di + (lz << 4)
			for lx in range(SIZE):
				var dv: int = d[drow + lx]
				snap[szi + lx + 1] = dv
				var fv: int = fd[drow + lx]
				if fv == 0 and (dv == 5 or dv == 24):
					fv = 8
				snap_fl[szi + lx + 1] = fv
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			if (dx == 0) == (dz == 0):
				continue
			var nb: Dictionary = nbs["%d,%d" % [dx, dz]]
			var nd: PackedByteArray = nb["d"]
			var nfd: PackedByteArray = nb["f"]
			var xb := _band(dx)
			var zb := _band(dz)
			for y in range(y_lo, y_hi + 1):
				var si := y * SNAP_ROW
				var di := (y - d_off) << 8
				for e in zb:
					var szi := si + int(e[0]) * SNAP_W
					var drow := di + (int(e[1]) << 4)
					for g in xb:
						var sxy := szi + int(g[0])
						var gi: int = int(g[1])
						var dv: int = int(nd[drow + gi])
						var fv: int = int(nfd[drow + gi])
						if fv == 0 and (dv == 5 or dv == 24):
							fv = 8
						snap[sxy] = dv
						snap_fl[sxy] = fv


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


# Worker pipeline: light -> snap -> emit. Pure-static; every input is a fresh
# copy handed over by the main thread. Returns fresh per-surface arrays
# (plain dicts, no Acc objects — the main thread wraps them in Acc in
# apply_accs) plus the light dict actually used (-> last_eff on apply).
static func build_accs(data: PackedByteArray, fl: PackedByteArray, cx: int, cz: int, nbs: Dictionary, ctx: Dictionary, ms: Dictionary, eff: Dictionary, si0 := 0, si1 := -1, d_off := 0) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var ph_light := 0
	var ph_box := 0
	var ph_snap := 0
	var ph_faces := 0
	var h: int = int(ctx["h"])
	si0 = clampi(si0, 0, slab_n() - 1)
	if si1 < 0:
		si1 = slab_n() - 1
	si1 = clampi(maxi(si1, si0), si0, slab_n() - 1)
	var y_lo := si0 * 16
	var y_hi := mini(h, (si1 + 1) * 16)
	# AC-0129: strips ride in on the ctx (main-thread copies, freed with it);
	# empty eff -> self-light through the PULL kernel (neighbor block light
	# crosses the boundary), cached eff -> validated upstream by ngen.
	var eff_strips: Array = ctx.get("eff_strips", [])
	var blk_strips: Array = ctx.get("blk_strips", [])
	var blk_strips_b: Array = ctx.get("blk_strips_b", [])
	var light: Dictionary = eff
	if light.is_empty() or light.get("mask", null) == null:
		var tl := Time.get_ticks_msec()
		light = Lighting.compute_light_flat_chunk_pull(data, cx, cz, h, eff_strips, blk_strips, blk_strips_b)
		ph_light = Time.get_ticks_msec() - tl
	var tb := Time.get_ticks_msec()
	var bb := _bake_box(light, eff_strips, h, maxi(0, y_lo - 2), mini(h - 1, y_hi + 1))
	var snap := PackedByteArray()
	snap.resize(SNAP_ROW * h)
	var snap_fl := PackedByteArray()
	snap_fl.resize(SNAP_ROW * h)
	_build_snap_data(snap, snap_fl, data, fl, cx, cz, nbs, h, maxi(0, y_lo - 2), mini(h - 1, y_hi + 1), d_off)
	ph_box = Time.get_ticks_msec() - tb
	var snap_done := Time.get_ticks_msec()
	var has_tex: bool = bool(ctx["has_tex"])
	var oktab: PackedByteArray = ctx["oktab"]
	var xtab: PackedByteArray = ctx["xtab"]
	var stab: PackedByteArray = ctx["stab"]
	var ktab: PackedByteArray = ctx["ktab"]
	var ttab: PackedByteArray = ctx["ttab"]
	var fn: Array = ctx["fn"]
	var fsh: PackedFloat32Array = ctx["fsh"]
	var fcv: Array = ctx["fcv"]
	# AC-0152 band 1 (coarse LOD): face detection stays full-res (seam-exact,
	# no height cut); the 2x UV scale (ctx uv_scale) gives the 32-block
	# texture period. Cutout (leaves) falls back to the opaque path and
	# flora/cross quads are omitted.
	var coarse: bool = bool(ctx.get("coarse", false))
	var ro: Array = []
	var rc_o: Array = []
	var rk: Array = []
	var rq: Array = []
	var rf_w: Array = []
	var rf_l: Array = []
	# AC-0091: per-slab counters sized by the runtime slab count (24 @ H=384;
	# was hard-coded 5 for H=80).
	var c_af_w := _zeros(slab_n())
	var c_af_l := _zeros(slab_n())
	var c_ns := _zeros(slab_n())
	var d: PackedByteArray = data
	var scoped := (si1 - si0 + 1) < slab_n()
	var sgrid := PackedByteArray()
	var ymask := PackedInt32Array()
	if scoped:
		# AC-0187: solid-grid + per-column boundary-row bitmask pre-pass. The
		# interior test below becomes one bitmask read per solid cell instead
		# of six snap+stab reads (a buried slab is ~95% interior cells).
		var GW := 18
		var yb0 := maxi(0, y_lo - 1)
		var yb1 := mini(h - 1, y_hi)
		sgrid.resize((yb1 - yb0 + 1) * GW * GW)
		for y in range(yb0, yb1 + 1):
			var grow := (y - yb0) * GW * GW
			var dyg := (y - d_off) << 8
			for lz in range(-1, 17):
				var base := grow + (lz + 1) * GW
				for lx in range(-1, 17):
					var id2: int
					if y >= y_lo and y < y_hi and lx >= 0 and lz >= 0:
						id2 = d[dyg + (lz << 4) + lx]
					else:
						id2 = snap[y * SNAP_ROW + (lz + 1) * 18 + (lx + 1)]
					if stab[id2] > 0:
						sgrid[base + lx + 1] = 1
		ymask.resize(256)
		for lz in range(16):
			for lx in range(16):
				var m := 0
				var gi0 := (y_lo - yb0) * GW * GW + (lz + 1) * GW + (lx + 1)
				for r in range(y_hi - y_lo):
					var gi := gi0 + r * GW * GW
					var bnd := 0
					if (r == 0 and y_lo == 0) or sgrid[gi - GW * GW] == 0:
						bnd = 1
					elif (r == y_hi - y_lo - 1 and y_hi >= h) or sgrid[gi + GW * GW] == 0:
						bnd = 1
					elif sgrid[gi - 1] == 0:
						bnd = 1
					elif sgrid[gi + 1] == 0:
						bnd = 1
					elif sgrid[gi - GW] == 0:
						bnd = 1
					elif sgrid[gi + GW] == 0:
						bnd = 1
					if bnd:
						m |= 1 << r
				ymask[(lz << 4) | lx] = m
	var tf := Time.get_ticks_msec()
	for y in range(y_lo, y_hi):
		var dy := (y - d_off) << 8
		var si := y >> 4
		for lz in range(SIZE):
			var drow := dy + (lz << 4)
			for lx in range(SIZE):
				var id := d[drow + lx]
				if stab[id] == 0:
					c_ns[si] += 1
				if id == 0:
					continue
				if id == 5 or id == 24:
					var hgt: float = _fluid_hgt(lx, y, lz, snap, snap_fl)
					if hgt > 0.0:
						var fcnt := _s_fluid_quad_count(lx, y, lz, id, hgt, snap, snap_fl, h, fn)
						if id == 5:
							c_af_w[si] += fcnt
							rf_w.append([lx, y, lz, id, hgt])
						else:
							c_af_l[si] += fcnt
							rf_l.append([lx, y, lz, id, hgt])
					continue
				if oktab[id] == 0:
					continue
				if stab[id] > 0:
					var skip := false
					if scoped:
						skip = (ymask[(lz << 4) | lx] & (1 << (y - y_lo))) == 0
					else:
						skip = _s_is_interior(lx, y, lz, snap, stab, h)
					if skip:
						continue
				if xtab[id] > 0:
					if not coarse and ttab[id] > 0:
						_s_faces(rc_o, xtab, stab, fn, lx, y, lz, id, snap, h)
					elif not coarse:
						rq.append([lx, y, lz, id])
				elif ktab[id] > 0:
					if coarse:
						_s_faces(ro, xtab, stab, fn, lx, y, lz, id, snap, h)
					else:
						_s_faces(rk, xtab, stab, fn, lx, y, lz, id, snap, h)
				else:
					_s_faces(ro, xtab, stab, fn, lx, y, lz, id, snap, h)
	ph_faces = Time.get_ticks_msec() - tf
	var s_ao: Array = []
	var s_ac: Array = []
	var s_af_w: Array = []
	var s_af_l: Array = []
	var s_ak: Array = []
	var s_ax: Array = []
	var c_ac := _zeros(slab_n())  # AC-0091: runtime slab count (was 5)
	var c_ak := _zeros(slab_n())
	var c_ax := _zeros(slab_n())
	for r in rc_o:
		c_ac[int(r[1]) / 16] += 1
	for r in rk:
		c_ak[int(r[1]) / 16] += 1
	for r in rq:
		c_ax[int(r[1]) / 16] += 2
	for si in range(slab_n()):  # AC-0091: runtime slab count (was 5)
		if scoped and (si < si0 or si > si1):
			s_ao.append(null)
			s_ac.append(null)
			s_af_w.append(null)
			s_af_l.append(null)
			s_ak.append(null)
			s_ax.append(null)
			continue
		s_ao.append(_new_acc())
		s_ac.append(_new_acc())
		s_af_w.append(_new_acc())
		s_af_l.append(_new_acc())
		s_ak.append(_new_acc())
		s_ax.append(_new_acc())
		_qgrow(s_ao[si], maxi(ro.size(), 1))
		_qgrow(s_ac[si], c_ac[si])
		_qgrow(s_af_w[si], c_af_w[si])
		_qgrow(s_af_l[si], c_af_l[si])
		_qgrow(s_ak[si], c_ak[si])
		_qgrow(s_ax[si], c_ax[si])
	# ms carries duplicated rects + h (main-thread merge-atlas cache); an empty
	# rects dict means "plain atlas" — mirrors build_mesh's ms.tex != null gate.
	# AC-0128 RUN 3: the block-light flood mask rides the light dict (pull
	# kernel / eff cache) - transient, never per-chunk state.
	var bmask: PackedByteArray = light["mask"]
	var te := Time.get_ticks_msec()
	var phet: Array = []
	# AC-0187: scoped (edit) builds emit per-face quads (plain path) — the
	# merge-atlas path costs 5-15x per quad and its merged runs span cells
	# the fast build cannot validate; the wave's full build restores the
	# merged mesh within 1-3 frames. Geometry is identical either way.
	if not ms.rects.is_empty() and ro.size() > 0 and not scoped:
		_s_emit_ro_merged(ro, s_ao, bb["mn"], bb["arr"], 20, 20, cx, cz, has_tex, ctx, ms, bmask)
	else:
		_s_emit_faces(ro, s_ao, bb["mn"], bb["arr"], 20, 20, cx, cz, has_tex, xtab, ctx, bmask)
	phet.append(Time.get_ticks_msec() - te)
	te = Time.get_ticks_msec()
	_s_emit_faces(rc_o, s_ac, bb["mn"], bb["arr"], 20, 20, cx, cz, has_tex, xtab, ctx, bmask)
	phet.append(Time.get_ticks_msec() - te)
	te = Time.get_ticks_msec()
	_s_emit_fluid(rf_w, s_af_w, snap, snap_fl, has_tex, ctx, h)
	phet.append(Time.get_ticks_msec() - te)
	te = Time.get_ticks_msec()
	_s_emit_fluid(rf_l, s_af_l, snap, snap_fl, has_tex, ctx, h)
	phet.append(Time.get_ticks_msec() - te)
	te = Time.get_ticks_msec()
	_s_emit_faces(rk, s_ak, bb["mn"], bb["arr"], 20, 20, cx, cz, has_tex, xtab, ctx, bmask)
	phet.append(Time.get_ticks_msec() - te)
	te = Time.get_ticks_msec()
	_s_emit_xquad(rq, s_ax, bb["mn"], bb["arr"], 20, 20, cx, cz, has_tex, ctx, bmask)
	phet.append(Time.get_ticks_msec() - te)
	var ph_emit: int = phet[0] + phet[1] + phet[2] + phet[3] + phet[4] + phet[5]
	var slabs_out: Array = []
	for si in range(si0, si1 + 1):
		slabs_out.append([s_ao[si], s_ac[si], s_af_w[si], s_af_l[si], s_ak[si], s_ax[si], c_ns[si] == 0])
	return {
		"slabs": slabs_out,
		"light": light,
		"wms": Time.get_ticks_msec() - t0,
		"si0": si0,
		"si1": si1,
		"nq": ro.size() + rc_o.size() + rk.size() + rq.size() + rf_w.size() + rf_l.size(),
		"ns": [ro.size(), rc_o.size(), rk.size(), rq.size(), rf_w.size(), rf_l.size()],
		"phet": phet,
		"ph": [ph_light, ph_box, ph_emit, ph_faces],
	}


# AC-0129: 20x20 bake box for face-light sampling — the core 16x16 at box
# offset (2,2) + a 2-cell margin per side from the neighbor EFF strips (web
# lightAt :963-970: the real neighbor light; a missing strip here keeps the
# margin cells at 0 = dark, NOT 15 = full bright, the (b) mechanism). Strip
# order [E,W,N,S, SE,SW,NE,NW]; SIDE idx = c*(16*h) + y*16 + t (c=0 the cell
# directly across, t = our z for E/W, our x for S/N); CORNER idx =
# (a*2+b)*h + y (a = x-depth, b = z-depth, 0 = closest). Light only scales
# vertex shade (geometry is snap-only) -> MINFO counts unaffected.
static func _bake_box(light: Dictionary, eff_strips: Array, h: int, y_lo := 0, y_hi := -1) -> Dictionary:
	var w := 20
	var arr := PackedByteArray()
	arr.resize(w * w * h)
	var bmn := Vector3i(-2, 0, -2)
	if y_hi < 0:
		y_hi = h - 1
	if light.is_empty():
		return {"mn": bmn, "w": w, "d": w, "arr": arr}
	var mn: Vector3i = light["mn"]
	var arrc: PackedByteArray = light["arr"]
	var lwc := int(light["w"])
	var ldc := int(light["d"])
	bmn = Vector3i(mn.x - 2, 0, mn.z - 2)
	for y in range(y_lo, y_hi + 1):
		var src_row := y * lwc * ldc
		var dst_row := y * w * w
		for bz in range(2, 18):
			var dst_z := dst_row + bz * w
			var src_z := src_row + (bz - 2) * lwc
			for bx in range(2, 18):
				arr[dst_z + bx] = arrc[src_z + (bx - 2)]
	if eff_strips.size() >= 8:
		# AC-0091: side strips are 2 cols x 16 x h, corners 4 x h (was
		# hard-coded 2560/320 for H=80).
		var c1 := 16 * h
		var fsize := 2 * 16 * h
		var csize := 4 * h
		var E: PackedByteArray = eff_strips[0]
		if E.size() == fsize:
			for y in range(y_lo, y_hi + 1):
				var row := y * w * w
				var srow := y * 16
				for t in range(16):
					arr[row + (2 + t) * w + 18] = E[srow + t]
					arr[row + (2 + t) * w + 19] = E[c1 + srow + t]
		var W: PackedByteArray = eff_strips[1]
		if W.size() == fsize:
			for y in range(y_lo, y_hi + 1):
				var row := y * w * w
				var srow := y * 16
				for t in range(16):
					arr[row + (2 + t) * w + 1] = W[srow + t]
					arr[row + (2 + t) * w + 0] = W[c1 + srow + t]
		var S: PackedByteArray = eff_strips[2]
		if S.size() == fsize:
			for y in range(y_lo, y_hi + 1):
				var row := y * w * w
				var srow := y * 16
				for t in range(16):
					arr[row + 18 * w + (2 + t)] = S[srow + t]
					arr[row + 19 * w + (2 + t)] = S[c1 + srow + t]
		var N: PackedByteArray = eff_strips[3]
		if N.size() == fsize:
			for y in range(y_lo, y_hi + 1):
				var row := y * w * w
				var srow := y * 16
				for t in range(16):
					arr[row + 1 * w + (2 + t)] = N[srow + t]
					arr[row + 0 * w + (2 + t)] = N[c1 + srow + t]
		var SE: PackedByteArray = eff_strips[4]
		if SE.size() == csize:
			for a in range(2):
				for b in range(2):
					for y in range(y_lo, y_hi + 1):
						arr[(18 + b) * w + (18 + a)] = SE[(a * 2 + b) * h + y]
		var SW: PackedByteArray = eff_strips[5]
		if SW.size() == csize:
			for a in range(2):
				for b in range(2):
					for y in range(y_lo, y_hi + 1):
						arr[(18 + b) * w + (1 - a)] = SW[(a * 2 + b) * h + y]
		var NE: PackedByteArray = eff_strips[6]
		if NE.size() == csize:
			for a in range(2):
				for b in range(2):
					for y in range(y_lo, y_hi + 1):
						arr[(1 - b) * w + (18 + a)] = NE[(a * 2 + b) * h + y]
		var NW: PackedByteArray = eff_strips[7]
		if NW.size() == csize:
			for a in range(2):
				for b in range(2):
					for y in range(y_lo, y_hi + 1):
						arr[(1 - b) * w + (1 - a)] = NW[(a * 2 + b) * h + y]
	return {"mn": bmn, "w": w, "d": w, "arr": arr}


static func _new_acc() -> Dictionary:
	return {
		"v": PackedVector3Array(),
		"n": PackedVector3Array(),
		"c": PackedColorArray(),
		"u": PackedVector2Array(),
		"i": PackedInt32Array(),
		"q": 0,
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
	if alt_data != data or alt_fl != fl:
		return false
	return true


func clear_lod_cache() -> void:
	alt_lod = -1
	alt_slabs = []
	alt_data = PackedByteArray()
	alt_fl = PackedByteArray()
	alt_atlas = null


func store_lod_cache(cap: Array, kind: int, in_ring: bool) -> void:
	lod_pending = false
	lod_builds += 1
	if not in_ring or cap.size() != slabs.size():
		clear_lod_cache()
		return
	alt_slabs = cap
	alt_lod = kind
	alt_data = data.duplicate()
	alt_fl = fl.duplicate()
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
		alt_data = data.duplicate()
		alt_fl = fl.duplicate()
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


func _build_snap(snap: PackedByteArray, snap_fl: PackedByteArray, get_world_block: Callable) -> void:
	var world: Node3D = Game.world
	var h := Data.HEIGHT
	if world == null:
		for y in range(h):
			for lz in range(SIZE):
				for lx in range(SIZE):
					snap[y * SNAP_ROW + (lz + 1) * SNAP_W + lx + 1] = int(get_world_block.call(cx * SIZE + lx, y, cz * SIZE + lz))
					snap_fl[y * SNAP_ROW + (lz + 1) * SNAP_W + lx + 1] = 0
		return
	var d: PackedByteArray = data
	var fd: PackedByteArray = fl
	for y in range(h):
		var si := y * SNAP_ROW
		var di := y << 8
		for lz in range(SIZE):
			var szi := si + (lz + 1) * SNAP_W
			var drow := di + (lz << 4)
			for lx in range(SIZE):
				var dv: int = d[drow + lx]
				snap[szi + lx + 1] = dv
				var fv := fd[drow + lx]
				if fv == 0 and (dv == 5 or dv == 24):
					fv = 8
				snap_fl[szi + lx + 1] = fv
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			if (dx == 0) == (dz == 0):
				continue
			var nxc := cx + dx
			var nzc := cz + dz
			var nkey := "%d,%d" % [nxc, nzc]
			var nc = world.chunks.get(nkey)
			# AC-0119: no read-path probe (it sync-generated up to 4 chunks per
			# build). Missing/empty diagonal = the normal frontier case.
			var ncready: bool = nc != null and nc.data.size() > 0
			var xb := _band(dx)
			var zb := _band(dz)
			for y in range(h):
				var si := y * SNAP_ROW
				var di := y << 8
				for e in zb:
					var szi := si + int(e[0]) * SNAP_W
					var drow := di + (int(e[1]) << 4)
					for g in xb:
						var sxy := szi + int(g[0])
						var gi: int = int(g[1])
						var dv: int
						var fv: int
						if ncready:
							dv = int(nc.data[drow + gi])
							fv = int(nc.fl[drow + gi])
							if fv == 0 and (dv == 5 or dv == 24):
								fv = 8
						else:
							dv = 0  # AC-0119: missing/empty diagonal = air (web world.block :882)
							fv = 0
						snap[sxy] = dv
						snap_fl[sxy] = fv


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
	var wx0 := cx * SIZE
	var wz0 := cz * SIZE
	var light: Dictionary = eff
	# AC-0129: the 20x20 bake box margins need the neighbor eff strips; the
	# self-light compute_light_flat pulls through the same ones internally.
	var st = Game.world._strips_for(cx, cz)
	if light.is_empty() or light.get("mask", null) == null:
		light = Lighting.compute_light_flat_chunk_pull(data, cx, cz, Data.HEIGHT, st["eff"], st["blk"], st["blk_b"])
	last_eff = _eff_store(light)
	last_blk_ring = light.get("ring", PackedInt32Array())
	var bb := _bake_box(light, st["eff"], Data.HEIGHT)
	var snap := PackedByteArray()
	snap.resize(SNAP_ROW * Data.HEIGHT)
	var snap_fl := PackedByteArray()
	snap_fl.resize(SNAP_ROW * Data.HEIGHT)
	_build_snap(snap, snap_fl, get_world_block)
	var has_tex := Data.atlas_tex != null
	var oktab := PackedByteArray()
	var xtab := PackedByteArray()
	var stab := PackedByteArray()
	var ktab := PackedByteArray()
	var ttab := PackedByteArray()
	var ct := PackedColorArray()
	var cs := PackedColorArray()
	var cb := PackedColorArray()
	oktab.resize(256)
	xtab.resize(256)
	stab.resize(256)
	ktab.resize(256)
	ttab.resize(256)
	ct.resize(256)
	cs.resize(256)
	cb.resize(256)
	var fn: Array = []
	var fsh := PackedFloat32Array()
	var fcv: Array = []
	for fi in range(6):
		var fd: Dictionary = VoxelMath.FACES[fi]
		fn.append(fd.n)
		fsh.append(float(fd.sh))
		fcv.append(fd.c)
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
	var ro: Array = []
	var rc_o: Array = []
	var rk: Array = []
	var rq: Array = []
	var rf_w: Array = []
	var rf_l: Array = []
	# AC-0091: per-slab counters sized by the runtime slab count (24 @ H=384).
	var c_af_w := _zeros(slab_n())
	var c_af_l := _zeros(slab_n())
	var c_ns := _zeros(slab_n())
	var d: PackedByteArray = data
	for y in range(Data.HEIGHT):
		var dy := y << 8
		for lz in range(SIZE):
			var drow := dy + (lz << 4)
			for lx in range(SIZE):
				var id := d[drow + lx]
				if stab[id] == 0:
					c_ns[y / 16] += 1
				if id == 0:
					continue
				if id == 5 or id == 24:
					var hgt: float = _fluid_hgt(lx, y, lz, snap, snap_fl)
					if hgt > 0.0:
						var fcnt := _fluid_quad_count(lx, y, lz, id, hgt, snap, snap_fl)
						if id == 5:
							c_af_w[y / 16] += fcnt
							rf_w.append([lx, y, lz, id, hgt])
						else:
							c_af_l[y / 16] += fcnt
							rf_l.append([lx, y, lz, id, hgt])
					continue
				if oktab[id] == 0:
					continue
				if stab[id] > 0 and _s_is_interior(lx, y, lz, snap, stab, Data.HEIGHT):
					continue
				if xtab[id] > 0:
					if ttab[id] > 0:
						_faces(rc_o, xtab, stab, fn, lx, y, lz, id, snap)
					else:
						rq.append([lx, y, lz, id])
				elif ktab[id] > 0:
					_faces(rk, xtab, stab, fn, lx, y, lz, id, snap)
				else:
					_faces(ro, xtab, stab, fn, lx, y, lz, id, snap)
	var s_ao: Array = []
	var s_ac: Array = []
	var s_af_w: Array = []
	var s_af_l: Array = []
	var s_ak: Array = []
	var s_ax: Array = []
	var c_ac := _zeros(slab_n())  # AC-0091: runtime slab count (was 5)
	var c_ak := _zeros(slab_n())
	var c_ax := _zeros(slab_n())
	for r in rc_o:
		c_ac[r[1] / 16] += 1
	for r in rk:
		c_ak[r[1] / 16] += 1
	for r in rq:
		c_ax[r[1] / 16] += 2
	for si in range(slab_n()):  # AC-0091: runtime slab count (was 5)
		s_ao.append(Acc.new())
		s_ac.append(Acc.new())
		s_af_w.append(Acc.new())
		s_af_l.append(Acc.new())
		s_ak.append(Acc.new())
		s_ax.append(Acc.new())
		_qgrow(s_ao[si], maxi(ro.size(), 1))
		_qgrow(s_ac[si], c_ac[si])
		_qgrow(s_af_w[si], c_af_w[si])
		_qgrow(s_af_l[si], c_af_l[si])
		_qgrow(s_ak[si], c_ak[si])
		_qgrow(s_ax[si], c_ax[si])
	var ms := _merge_atlas()
	if OS.get_environment("AWECRAFT_MERGE") == "0":
		ms = {"tex": null, "rects": {}}
	# AC-0128 RUN 3: the block-light flood mask rides the light dict -
	# transient, never per-chunk state.
	var bmask: PackedByteArray = light["mask"]
	if ms.tex != null and ro.size() > 0:
		_emit_ro_merged(ro, s_ao, bb["mn"], bb["arr"], 20, 20, has_tex, fn, fsh, fcv, ct, cs, cb, ms, bmask)
	else:
		_emit_faces(ro, s_ao, bb["mn"], bb["arr"], 20, 20, has_tex, xtab, fn, fsh, fcv, ct, cs, cb, bmask)
	_emit_faces(rc_o, s_ac, bb["mn"], bb["arr"], 20, 20, has_tex, xtab, fn, fsh, fcv, ct, cs, cb, bmask)
	_emit_fluid(rf_w, s_af_w, snap, snap_fl, has_tex, fn, fcv, ct, cs, cb)
	_emit_fluid(rf_l, s_af_l, snap, snap_fl, has_tex, fn, fcv, ct, cs, cb)
	_emit_faces(rk, s_ak, bb["mn"], bb["arr"], 20, 20, has_tex, xtab, fn, fsh, fcv, ct, cs, cb, bmask)
	_emit_xquad(rq, s_ax, bb["mn"], bb["arr"], 20, 20, has_tex, ct, bmask)
	for si in range(slab_n()):  # AC-0091: runtime slab count (was 5)
		_assemble_slab(slabs[si], s_ao[si], s_ac[si], s_af_w[si], s_af_l[si], s_ak[si], s_ax[si], ms, c_ns[si] == 0)
	mesh_built = true
	mesh_gen += 1
	_post_build_collision()


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
	for si in range(slab_n()):  # AC-0091: runtime slab count (was 5)
		var row: Array = res.slabs[si]
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