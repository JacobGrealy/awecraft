class_name HeldMeshes

const XQ_A := [Vector3(0, 0, 0.5), Vector3(1, 0, 0.5), Vector3(1, 1, 0.5), Vector3(0, 1, 0.5)]
const XQ_B := [Vector3(0.5, 0, 0), Vector3(0.5, 0, 1), Vector3(0.5, 1, 1), Vector3(0.5, 1, 0)]
const FACE_NAMES := ["side", "side", "top", "bottom", "side", "side"]

static var _box_cache := {}
static var _cross_cache := {}
static var _box_mat: Material = null
static var _cross_mat: Material = null
static var _box_atlas: Texture2D = null
static var _cross_atlas: Texture2D = null


static func corner_uv(cv: Vector3, n: Vector3i, tl: Vector2i) -> Vector2:
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


static func box_mesh(id: int) -> Mesh:
	var has_tex := Data.atlas_tex != null
	var c = _box_cache.get(id)
	if c != null and bool(c["tex"]) == has_tex:
		return c["mesh"]
	var m := _build_box(id, has_tex)
	_box_cache[id] = {"mesh": m, "tex": has_tex}
	return m


static func cross_mesh(id: int) -> Mesh:
	var has_tex := Data.atlas_tex != null
	var c = _cross_cache.get(id)
	if c != null and bool(c["tex"]) == has_tex:
		return c["mesh"]
	var m := _build_cross(id, has_tex)
	_cross_cache[id] = {"mesh": m, "tex": has_tex}
	return m


static func box_material() -> Material:
	if _box_mat == null or _box_atlas != Data.atlas_tex:
		_box_atlas = Data.atlas_tex
		_box_mat = _base_mat()
	return _box_mat


static func cross_material() -> Material:
	if _cross_mat == null or _cross_atlas != Data.atlas_tex:
		_cross_atlas = Data.atlas_tex
		_cross_mat = _base_mat()
		var m: StandardMaterial3D = _cross_mat
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		m.alpha_scissor_threshold = 0.5
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _cross_mat


static func _base_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	m.vertex_color_use_as_albedo = true
	if Data.atlas_tex != null:
		m.albedo_texture = Data.atlas_tex
		m.albedo_color = Color.WHITE
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	m.roughness = 0.95
	return m


static func _build_box(id: int, has_tex: bool) -> ArrayMesh:
	var binfo = Data.block(id)
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var u := PackedVector2Array()
	var idx := PackedInt32Array()
	for fi in 6:
		var f: Dictionary = VoxelMath.FACES[fi]
		var fn: Vector3i = f.n
		var face_name := String(FACE_NAMES[fi])
		var tl := Data.block_rect(id, face_name)
		var shade := float(f.sh)
		var col: Color
		if has_tex:
			# AC-0128: the block tints are baked into the atlas pixels now —
			# the vertex color carries shade only (no double tint).
			col = Color(shade, shade, shade, 1.0)
		else:
			var fc: Color
			if face_name == "top":
				fc = binfo["color"]["top"]
			elif face_name == "bottom":
				fc = binfo["color"]["bottom"]
			else:
				fc = binfo["color"]["side"]
			col = fc * shade
		var base := v.size()
		for cv in f.c:
			v.append(Vector3(cv))
			n.append(Vector3(fn))
			c.append(col)
			u.append(corner_uv(Vector3(cv), fn, tl))
		idx.append_array([base, base + 2, base + 1, base, base + 3, base + 2])
	return _to_mesh(v, n, c, u, idx)


static func _build_cross(id: int, has_tex: bool) -> ArrayMesh:
	var binfo = Data.block(id)
	var tl := Data.block_rect(id, "top")
	var col: Color
	if has_tex:
		# AC-0128: tint baked into the atlas — shade only (no double tint).
		col = Color(0.9, 0.9, 0.9, 1.0)
	else:
		col = binfo["color"]["top"] * 0.9
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var u := PackedVector2Array()
	var idx := PackedInt32Array()
	var quads: Array = [[XQ_A, Vector3i(0, 0, 1)], [XQ_B, Vector3i(1, 0, 0)]]
	for q in quads:
		var verts: Array = q[0]
		var fn: Vector3i = q[1]
		var base := v.size()
		for cv in verts:
			v.append(Vector3(cv))
			n.append(Vector3(fn))
			c.append(col)
			u.append(corner_uv(Vector3(cv), fn, tl))
		idx.append_array([base, base + 2, base + 1, base, base + 3, base + 2])
	return _to_mesh(v, n, c, u, idx)


static func _to_mesh(v: PackedVector3Array, n: PackedVector3Array, c: PackedColorArray, u: PackedVector2Array, idx: PackedInt32Array) -> ArrayMesh:
	var arrs: Array = []
	arrs.resize(Mesh.ARRAY_MAX)
	arrs[Mesh.ARRAY_VERTEX] = v
	arrs[Mesh.ARRAY_NORMAL] = n
	arrs[Mesh.ARRAY_COLOR] = c
	arrs[Mesh.ARRAY_TEX_UV] = u
	arrs[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrs)
	return m
