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
var data := PackedByteArray()
var fl := PackedByteArray()
var mesh_built := false
var collision_enabled := true
var col_dirty := true
var last_eff: Dictionary = {}
# AC-0080 two-stage hysteresis: candidate = at Chebyshev r+1 with expensive
# parts killed (mesh/collision), data+edits kept; cand_since = count of
# recenter events spent at >= r+2 (free at >= 2).
var candidate := false
var cand_since := 0

var mesh_instance: MeshInstance3D = null
var fluid_instance: MeshInstance3D = null
var flora_instance: MeshInstance3D = null
var collision_body: StaticBody3D = null


class Acc:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var u := PackedVector2Array()
	var i := PackedInt32Array()
	var q := 0


func get_local(lx: int, y: int, lz: int) -> int:
	return data[(y << 8) | (lz << 4) | lx]


func set_local(lx: int, y: int, lz: int, id: int) -> void:
	data[(y << 8) | (lz << 4) | lx] = id


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


func _light_color(shade: float, face_color: Color, has_tex: bool) -> Color:
	if has_tex:
		return Color(shade, shade, shade, 1.0)
	return face_color * shade


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


func _fluid_hgt(lx: int, y: int, lz: int, snap: PackedByteArray, snap_fl: PackedByteArray) -> float:
	var rowl := (lz + 1) * SNAP_W + (lx + 1)
	var lvl: int = snap_fl[y * SNAP_ROW + rowl]
	if lvl <= 0:
		return -1.0
	return float(lvl) / 8.0


func _qgrow(acc: Acc, nq: int) -> void:
	var v4 := nq * 4
	acc.v.resize(v4)
	acc.n.resize(v4)
	acc.c.resize(v4)
	acc.u.resize(v4)
	acc.i.resize(nq * 6)


func _qwrite(acc: Acc, k: int, c: Color, n: Vector3i, uvs: PackedVector2Array, fcv: Array, lx: int, y: int, lz: int, py0: float, py1: float, py2: float, py3: float) -> void:
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


func _emit_faces(recs: Array, acc: Acc, lmn: Vector3i, larr: PackedByteArray, lw: int, ld: int, has_tex: bool, xtab: PackedByteArray, fn: Array, fsh: PackedFloat32Array, fcv: Array, ct: PackedColorArray, cs: PackedColorArray, cb: PackedColorArray) -> void:
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
		var shade: float = float(fsh[fi]) * _face_light(id, wx0 + lx, y, wz0 + lz, n, lmn, larr, lw, ld)
		var c: Color = _light_color(shade, face_color, has_tex)
		if has_tex:
			c = c * Data.block_tint(id, face_name)
		var uvs := _uvc(uvc, rc, id, fi, face_name, fn, fcv)
		var cva = fcv[fi]
		_qwrite(acc, acc.q, c, n, uvs, cva, lx, y, lz, float(cva[0].y), float(cva[1].y), float(cva[2].y), float(cva[3].y))
		acc.q += 1


func _emit_xquad(recs: Array, acc: Acc, lmn: Vector3i, larr: PackedByteArray, lw: int, ld: int, has_tex: bool, ct: PackedColorArray) -> void:
	var rc := {}
	var uvc := {}
	var wx0 := cx * SIZE
	var wz0 := cz * SIZE
	for r in recs:
		var lx: int = r[0]
		var y: int = r[1]
		var lz: int = r[2]
		var id: int = r[3]
		var s := clampf(float(_effl(lmn, larr, lw, ld, wx0 + lx, y, wz0 + lz)) / 15.0, MIN_AMB, 1.0) * 0.9
		var c: Color
		if has_tex:
			c = Color(s, s, s, 1.0) * Data.block_tint(id, "top")
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
		_qwrite(acc, acc.q, c, Vector3i(0, 0, 1), uvs[0], XQ_A, lx, y, lz, 0.0, 0.0, 1.0, 1.0)
		acc.q += 1
		_qwrite(acc, acc.q, c, Vector3i(1, 0, 0), uvs[1], XQ_B, lx, y, lz, 0.0, 0.0, 1.0, 1.0)
		acc.q += 1


func _emit_fluid(recs: Array, acc: Acc, snap: PackedByteArray, snap_fl: PackedByteArray, has_tex: bool, fn: Array, fcv: Array, ct: PackedColorArray, cs: PackedColorArray, cb: PackedColorArray) -> void:
	var rc := {}
	var uvc := {}
	for r in recs:
		var lx: int = r[0]
		var y: int = r[1]
		var lz: int = r[2]
		var id: int = r[3]
		var hgt: float = r[4]
		var rowl := (lz + 1) * SNAP_W + (lx + 1)
		var tint_t := Data.block_tint(id, "top")
		var tint_s := Data.block_tint(id, "side")
		var tint_b := Data.block_tint(id, "bottom")
		var above := 0
		if y + 1 < Data.HEIGHT:
			above = snap[(y + 1) * SNAP_ROW + rowl]
		if above != id:
			var top_h := minf(hgt, 0.875 if id == 5 else 0.95)
			_qwrite(acc, acc.q, Color(0.95, 0.95, 0.95, 1.0) * tint_t if has_tex else ct[id] * 0.95, Vector3i(0, 1, 0), _uvc(uvc, rc, id, 2, "top", fn, fcv), fcv[2], lx, y, lz, top_h, top_h, top_h, top_h)
			acc.q += 1
		for fi in [0, 1, 4, 5]:
			var n: Vector3i = fn[fi]
			var nb: int = snap[y * SNAP_ROW + rowl + n.z * SNAP_W + n.x]
			var hn := 0.0
			if nb == id:
				hn = float(snap_fl[y * SNAP_ROW + rowl + n.z * SNAP_W + n.x]) / 8.0
			if hn >= hgt:
				continue
			var cva = fcv[fi]
			_qwrite(acc, acc.q, Color(0.85, 0.85, 0.85, 1.0) * tint_s if has_tex else cs[id] * 0.85, n, _uvc(uvc, rc, id, fi, "side", fn, fcv), cva, lx, y, lz, hgt if cva[0].y == 1.0 else hn, hgt if cva[1].y == 1.0 else hn, hgt if cva[2].y == 1.0 else hn, hgt if cva[3].y == 1.0 else hn)
			acc.q += 1
		var below := 0
		if y > 0:
			below = snap[(y - 1) * SNAP_ROW + rowl]
		if y > 0 and below != id:
			_qwrite(acc, acc.q, Color(0.6, 0.6, 0.6, 1.0) * tint_b if has_tex else cb[id] * 0.6, Vector3i(0, -1, 0), _uvc(uvc, rc, id, 3, "bottom", fn, fcv), fcv[3], lx, y, lz, 0.0, 0.0, 0.0, 0.0)
			acc.q += 1


func _band(delta: int) -> Array:
	if delta == -1:
		return [[0, 15]]
	if delta == 1:
		return [[17, 0]]
	var out: Array = []
	for v in range(16):
		out.append([v + 1, v])
	return out


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
			if nc == null:
				get_world_block.call(nxc * SIZE + 8, 4, nzc * SIZE + 8)
				nc = world.chunks.get(nkey)
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
						if nc != null:
							dv = int(nc.data[drow + gi])
							fv = int(nc.fl[drow + gi])
							if fv == 0 and (dv == 5 or dv == 24):
								fv = 8
						else:
							dv = int(get_world_block.call(nxc * SIZE + gi, y, nzc * SIZE + int(e[1])))
							fv = 0
						snap[sxy] = dv
						snap_fl[sxy] = fv


func _opaque_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	if Data.atlas_tex != null:
		m.albedo_texture = Data.atlas_tex
		m.albedo_color = Color.WHITE
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	m.roughness = 0.95
	return m


func _cutout_material() -> StandardMaterial3D:
	var m := _opaque_material()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	m.alpha_scissor_threshold = 0.5
	return m


func _flower_material() -> StandardMaterial3D:
	var m := _cutout_material()
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


func _fluid_material() -> StandardMaterial3D:
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
	var a: Array = []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = arr.v
	a[Mesh.ARRAY_NORMAL] = arr.n
	a[Mesh.ARRAY_TEX_UV] = arr.u
	a[Mesh.ARRAY_COLOR] = arr.c
	a[Mesh.ARRAY_INDEX] = arr.i
	return a


func build_mesh(get_world_block: Callable, eff: Dictionary = {}) -> void:
	if mesh_instance:
		mesh_instance.queue_free()
		mesh_instance = null
	if fluid_instance:
		fluid_instance.queue_free()
		fluid_instance = null
	if flora_instance:
		flora_instance.queue_free()
		flora_instance = null
	var wx0 := cx * SIZE
	var wz0 := cz * SIZE
	var light: Dictionary = eff
	if light.is_empty():
		light = Lighting.compute_light_flat({
			"min": Vector3i(wx0 - STANDALONE_MARGIN, 0, wz0 - STANDALONE_MARGIN),
			"max": Vector3i(wx0 + SIZE - 1 + STANDALONE_MARGIN, Data.HEIGHT - 1, wz0 + SIZE - 1 + STANDALONE_MARGIN),
		}, Game.world)
	last_eff = light
	var lmn: Vector3i = light["mn"]
	var larr: PackedByteArray = light["arr"]
	var lw := int(light["w"])
	var ld := int(light["d"])
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
	var nfw := 0
	var nfl := 0
	var d: PackedByteArray = data
	for y in range(Data.HEIGHT):
		var dy := y << 8
		for lz in range(SIZE):
			var drow := dy + (lz << 4)
			for lx in range(SIZE):
				var id := d[drow + lx]
				if id == 0:
					continue
				if id == 5 or id == 24:
					var hgt: float = _fluid_hgt(lx, y, lz, snap, snap_fl)
					if hgt > 0.0:
						var fcnt := _fluid_quad_count(lx, y, lz, id, hgt, snap, snap_fl)
						if id == 5:
							nfw += fcnt
							rf_w.append([lx, y, lz, id, hgt])
						else:
							nfl += fcnt
							rf_l.append([lx, y, lz, id, hgt])
					continue
				if oktab[id] == 0:
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
	var ao := Acc.new()
	_qgrow(ao, ro.size())
	_emit_faces(ro, ao, lmn, larr, lw, ld, has_tex, xtab, fn, fsh, fcv, ct, cs, cb)
	var ac := Acc.new()
	_qgrow(ac, rc_o.size())
	_emit_faces(rc_o, ac, lmn, larr, lw, ld, has_tex, xtab, fn, fsh, fcv, ct, cs, cb)
	var af_w := Acc.new()
	_qgrow(af_w, nfw)
	_emit_fluid(rf_w, af_w, snap, snap_fl, has_tex, fn, fcv, ct, cs, cb)
	var af_l := Acc.new()
	_qgrow(af_l, nfl)
	_emit_fluid(rf_l, af_l, snap, snap_fl, has_tex, fn, fcv, ct, cs, cb)
	var ak := Acc.new()
	_qgrow(ak, rk.size())
	_emit_faces(rk, ak, lmn, larr, lw, ld, has_tex, xtab, fn, fsh, fcv, ct, cs, cb)
	var ax := Acc.new()
	_qgrow(ax, rq.size() * 2)
	_emit_xquad(rq, ax, lmn, larr, lw, ld, has_tex, ct)
	var mesh := ArrayMesh.new()
	if ao.q > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _surface(ao))
		mesh.surface_set_material(0, _opaque_material())
	if mesh.get_surface_count() > 0:
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		add_child(mi)
		mesh_instance = mi
	if ac.q > 0 or af_w.q > 0 or af_l.q > 0:
		if ac.q > 0:
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _surface(ac))
			mesh.surface_set_material(mesh.get_surface_count() - 1, _fluid_material())
		if af_w.q > 0:
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _surface(af_w))
			mesh.surface_set_material(mesh.get_surface_count() - 1, _fluid_anim_material(5))
		if af_l.q > 0:
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _surface(af_l))
			mesh.surface_set_material(mesh.get_surface_count() - 1, _fluid_anim_material(24))
		var fi := MeshInstance3D.new()
		fi.mesh = mesh
		add_child(fi)
		fluid_instance = fi
	if ak.q > 0 or ax.q > 0:
		var fm := ArrayMesh.new()
		if ak.q > 0:
			fm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _surface(ak))
			fm.surface_set_material(0, _cutout_material())
		if ax.q > 0:
			fm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _surface(ax))
			fm.surface_set_material(fm.get_surface_count() - 1, _flower_material())
		var fi2 := MeshInstance3D.new()
		fi2.mesh = fm
		add_child(fi2)
		flora_instance = fi2
	mesh_built = true
	if collision_enabled and col_dirty:
		if collision_body:
			collision_body.queue_free()
			collision_body = null
		_build_collision()
	col_dirty = false


func _build_collision() -> void:
	if mesh_instance == null or mesh_instance.mesh == null:
		return
	var mesh: ArrayMesh = mesh_instance.mesh
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
	collision_body = body