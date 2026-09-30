# AC-0310 P2 - the satellite body tier (whole-planet view above the
# atmosphere). Draws the planet as one closed body: the 12-face
# great-circle chart (core/sphere_math.gd) at radius R + SEA, textured
# with the per-face 1024^2 satellite textures. Per-fragment existence
# and haze live in core/satellite_body.gdshader (the no-pop contract);
# this node owns the geometry, the textures and the thresholds.
#
# TEXTURE SOURCE - one of, in order:
#  (1) the user:// cache, keyed (planet_id, R, seed) - the runtime bake
#      below, or a previous run's;
#  (2) the shipped res:// assets for the canonical seed 44 (the piece-1
#      bake, tasks/AC-0310/);
#  (3) the runtime bake: far column payloads ([H u16x256][biome x256]
#      [top x256] per chunk - the same call the demotion path makes)
#      for all 196,196 chunks (home pair cx,cz in [-197,196]^2, then
#      faces 2-11 as 64x64 at (face*64+ccx, face*64+ccz) with
#      seed^(face*1000003) - the piece-1 keying, machine-diffed in
#      piece 1), colour-baked with the piece-1 recipe (fcc top colour
#      x fixed-sun lambert, stored sRGB). The bake is frame-sliced on
#      the main thread (BAKE_BUDGET_MS per frame) so the game stays
#      responsive; the per-frame stall is measured, not asserted
#      (bake_stats). Off-thread generation is OWED (needs a TG-pool
#      task) - see tasks/AC-0310/AC-0310-results.html.
class_name SatelliteBody
extends Node3D

const NPIX := 1024
const MESH_RES := 48  # per-face grid subdivisions (49x49 vertices)
const HOME_HALF := 197  # home chunks per axis: cx, cz in [-197, 196]
const HOME_N := HOME_HALF * 2  # 394
const HOME_CHUNKS := HOME_N * HOME_N  # 155,236
const FACE_GRID := 64  # faces 2-11: face chunks per axis
const FACE_CHUNKS := FACE_GRID * FACE_GRID  # 4,096
const BAKE_BUDGET_MS := 6.0  # main-thread slice budget per frame
const CANONICAL_SEED := 44  # the shipped res:// textures are this seed's bake

enum Phase { NONE, PAYLOAD, FACE, LOAD, LOADED, FAILED }

# fcc top-face colours (linear) - the far tier's exact per-block values
# (world.gd _lod_fcc_get: the atlas tile sRGB average with the data.gd
# web tints, srgb_to_linear), measured by the piece-1 probe
# (tasks/AC-0310/ac0310_fcc_probe.json). The bake uses THESE, not the
# data.gd flat palette (finding 2 of piece 1: the flat palette reads
# visibly brighter/greener than the band the far tier actually draws).
const FCC := {
	1: Vector3(0.0372655354440212, 0.138167947530746, 0.0145237101241946),  # grass
	4: Vector3(0.710151135921478, 0.624966502189636, 0.36659699678421),  # sand
	5: Vector3(0.0148077942430973, 0.0683721303939819, 0.363273352384567),  # water
	12: Vector3(0.944649755954742, 0.992749691009521, 0.992749691009521),  # snow-grass
	32: Vector3(0.0766324177384377, 0.0766324177384377, 0.0817681550979614),  # deepslate
}

# The piece-1 bake sun (the (u, radial, v) frame), L = normalize(0.4,1,0.2).
const LX := 0.4 / sqrt(1.2)
const LY := 1.0 / sqrt(1.2)
const LZ := 0.2 / sqrt(1.2)

var phase: int = Phase.NONE
var configured := false
var planet_id := 0
var seed := 0
var R := 0.0  # the reference radius (Game.planet_R)
var SEA := 126
var HMAX := 384

var pay := PackedByteArray()  # 196,196 x 1024-byte far payloads
var pay_next := 0
var pay_total := 0

var color_face := 0  # the face in the FACE/LOAD phases
var color_row := 0
var _h2 := PackedInt32Array()  # faces 2-11: the 1024^2 H grid (lazy 16-row blocks)
var _t2 := PackedByteArray()  # faces 2-11: the 1024^2 top grid
var _bld_row := 0  # next 16-row H2 block to build (faces 2-11)
var _out := PackedByteArray()  # the current face's RGB output (per-face allocation)
var _ch_cx := -999  # home pair: the cached chunk
var _ch_cz := -999
var _h16 := PackedInt32Array()
var _t16 := PackedByteArray()
var _gx16 := PackedFloat32Array()
var _gz16 := PackedFloat32Array()

var textures: Array = []  # 12 ImageTexture (appended in load order 0..11)
var face_nodes: Array = []  # 12 MeshInstance3D
var shader_mats: Array = []  # 12 ShaderMaterial
var _shader: Shader = null
var _load_src := ""  # "cache" | "res" - where the LOAD phase reads

var bake_active := false
var bake_stats: Dictionary = {}
var _bake_wall_t0 := 0
var _gen_ms := 0.0
var _color_ms := 0.0
var _png_ms := 0.0
var _load_ms := 0.0
var _step_max_ms := 0.0
var _step_sum_ms := 0.0
var _frame_max_ms := 0.0
var _frame_sum_ms := 0.0
var _frame_n := 0
var _last_bake_tick := 0
var guard: Array = []  # 12 per-face guard dictionaries (load order)
var _first_col: PackedByteArray = PackedByteArray()

# the per-frame state the probe arm reads (the shader-side values,
# mirrored - headless has no GPU, the arm checks the contract numerically)
var last_h_band := -1.0
var last_h_first := 0.0
var last_h_full := 0.0
var last_fog_far := 0.0
var last_render_edge := 0.0
var _cam: Node = null


func _ready() -> void:
	_shader = load("res://core/satellite_body.gdshader")


func configure(pid: int, p_seed: int, p_R: float, p_hmax: int, p_sea: int) -> void:
	if configured:
		return
	configured = true
	planet_id = pid
	seed = p_seed
	R = p_R
	HMAX = p_hmax
	SEA = p_sea
	pay_total = HOME_CHUNKS + 10 * FACE_CHUNKS
	position = Vector3(0.0, -R, 0.0)  # the planet-frame centre in the global frame
	if _all_exist(_cache_dir_paths()):
		_load_src = "cache"
		_phase_load("cache", _cache_dir())
	elif seed == CANONICAL_SEED and _all_exist(_res_paths()):
		_load_src = "res"
		_phase_load("res", "res://assets/satellite/")
	else:
		_start_bake()


func _cache_dir() -> String:
	return "user://satellite/p%d_r%d_s%d" % [planet_id, int(R), seed]


func _res_path(f: int) -> String:
	return "res://assets/satellite/satellite_face%02d.png" % f


func _cache_path(f: int) -> String:
	return _cache_dir() + "/satellite_face%02d.png" % f


func _cache_dir_paths() -> Array:
	var out: Array = []
	for f in 12:
		out.append(_cache_path(f))
	return out


func _res_paths() -> Array:
	var out: Array = []
	for f in 12:
		out.append(_res_path(f))
	return out


func _all_exist(paths: Array) -> bool:
	for pth in paths:
		if not FileAccess.file_exists(pth):
			return false
	return true


func _phase_load(src: String, where: String) -> void:
	_load_src = src
	phase = Phase.LOAD
	color_face = 0
	bake_active = true
	bake_stats = {"mode": src, "cache": where}
	_bake_wall_t0 = Time.get_ticks_msec()
	_last_bake_tick = 0


func _start_bake() -> void:
	phase = Phase.PAYLOAD
	bake_active = true
	bake_stats = {"mode": "baked", "cache": _cache_dir()}
	pay = PackedByteArray()  # appended record-by-record (no pre-alloc)
	pay_next = 0
	color_face = 0
	guard.clear()
	textures.clear()
	_bake_wall_t0 = Time.get_ticks_msec()
	_last_bake_tick = 0
	DirAccess.make_dir_recursive_absolute(_cache_dir())


# The per-frame driver (world._process). State is read back through the
# public fields.
func process_frame(ppos: Vector3, day_t: float, render_radius: int, fog_pct: float) -> void:
	if bake_active:
		var s0 := Time.get_ticks_usec()
		_step_bake()
		var sms := float(Time.get_ticks_usec() - s0) / 1000.0
		_step_sum_ms += sms
		if sms > _step_max_ms:
			_step_max_ms = sms
	if phase == Phase.LOADED:
		_tick_view(ppos, day_t, render_radius, fog_pct)


func _tick_view(ppos: Vector3, day_t: float, render_radius: int, fog_pct: float) -> void:
	var h_band: float = (ppos + Vector3(0.0, R, 0.0)).length() - R
	var RB: float = R + float(SEA)
	var ff: float = DayNight.fog_far(render_radius, fog_pct)
	var edge: float = (float(render_radius) + 1.0) * 16.0
	# Derived thresholds (no constants - spec precision (a)):
	#  h_first: the rim's tangent distance d_t(h) = sqrt((R+h)^2 - RB^2)
	#           crosses fog_far - the rim emerges as it passes the fog wall.
	#  h_full:  the nadir (distance h - SEA) clears the render edge - the
	#           near region is fully established.
	var h_first: float = sqrt(RB * RB + ff * ff) - R
	var h_full: float = float(SEA) + edge
	last_h_band = h_band
	last_h_first = h_first
	last_h_full = h_full
	last_fog_far = ff
	last_render_edge = edge
	var vis := h_band > h_first
	if visible != vis:
		visible = vis
	if vis:
		for m in shader_mats:
			m.set_shader_parameter("u_fog_far", ff)
			m.set_shader_parameter("u_render_edge", edge)
			m.set_shader_parameter("u_clear_dist", 4.0 * edge)
			m.set_shader_parameter("u_air", DayNight.sky_display(day_t))
			m.set_shader_parameter("u_day", 0.18 + 0.82 * DayNight.day(day_t))
		# The camera far plane (default 4000) would clip the body's far
		# limb (h + 2*RB out): extend it while the body is visible,
		# restore it when hidden.
		if _cam == null or not is_instance_valid(_cam):
			var pl = Game.player
			_cam = pl.get_node_or_null("Camera3D") if pl != null else null
		if _cam != null:
			var want: float = h_band + 2.0 * RB + 200.0
			if absf(float(_cam.far) - want) > 1.0:
				_cam.far = want
	elif _cam != null and is_instance_valid(_cam) and absf(float(_cam.far) - 4000.0) > 1.0:
		_cam.far = 4000.0  # the engine default, restored


# The shader-side per-fragment opacity, mirrored for the probe arm
# (headless has no GPU; the arm checks the contract numerically).
func opacity_at(d: float) -> float:
	return smoothstep(last_fog_far, last_render_edge, d)


# The bake state machine - one budgeted slice per frame.
func _step_bake() -> void:
	var t0 := Time.get_ticks_usec()
	if phase == Phase.PAYLOAD:
		var g: Variant = WorldGen.gen_cpp()
		if g == null:
			_fail("no AweGen (WorldGen.gen_cpp() null)")
			return
		while pay_next < pay_total:
			var rec: PackedByteArray = _gen_one(g, pay_next)
			if rec.size() != 1024:
				_fail("generate_far payload %d bytes at record %d" % [rec.size(), pay_next])
				return
			pay.append_array(rec)  # records land in generation order
			pay_next += 1
			if (Time.get_ticks_usec() - t0) / 1000.0 >= BAKE_BUDGET_MS:
				_gen_ms += float(Time.get_ticks_usec() - t0) / 1000.0
				return
		_gen_ms += float(Time.get_ticks_usec() - t0) / 1000.0
		phase = Phase.FACE
		color_face = 0
		_start_face()
	elif phase == Phase.FACE:
		_step_face(t0)
	elif phase == Phase.LOAD:
		var lf: int = color_face
		if lf >= 12:
			return
		var t0l := Time.get_ticks_usec()
		var pth: String = _cache_path(lf) if _load_src == "cache" else _res_path(lf)
		var img: Image = _load_png(pth)
		if img == null:
			_fail("cannot read %s" % pth)
			return
		var gd := _guard_check(img)
		guard.append(gd)
		if not gd["ok"]:
			_fail("variance guard failed on face %d: %s" % [lf, str(gd)])
			return
		textures.append(ImageTexture.create_from_image(img))
		color_face += 1
		_load_ms += float(Time.get_ticks_usec() - t0l) / 1000.0
		if color_face >= 12:
			_build_meshes()
			_finish_bake()


func _gen_one(g: Variant, idx: int) -> PackedByteArray:
	# The piece-1 keying: home first (the plain seed), then faces 2-11
	# at (face*64+ccx, face*64+ccz) with seed^(face*1000003).
	if idx < HOME_CHUNKS:
		var cx: int = idx % HOME_N - HOME_HALF
		var cz: int = idx / HOME_N - HOME_HALF
		return g.generate_far(cx, cz, seed, HMAX, SEA)
	var kf: int = idx - HOME_CHUNKS
	var f: int = 2 + kf / FACE_CHUNKS
	var kk: int = kf % FACE_CHUNKS
	var ccx: int = kk % FACE_GRID
	var ccz: int = kk / FACE_GRID
	return g.generate_far(f * FACE_GRID + ccx, f * FACE_GRID + ccz, seed ^ (f * 1000003), HMAX, SEA)


func _record_offset(f: int, ccx: int, ccz: int) -> int:
	return (HOME_CHUNKS + (f - 2) * FACE_CHUNKS + ccz * FACE_GRID + ccx) * 1024


func _home_rec_offset(cx: int, cz: int) -> int:
	return ((cz + HOME_HALF) * HOME_N + (cx + HOME_HALF)) * 1024


func _start_face() -> void:
	color_row = 0
	_out = PackedByteArray()
	_out.resize(NPIX * NPIX * 3)
	if color_face > 1:
		_h2 = PackedInt32Array()
		_h2.resize(NPIX * NPIX)
		_t2 = PackedByteArray()
		_t2.resize(NPIX * NPIX)
		_bld_row = 0
	else:
		_ch_cx = -999
		_ch_cz = -999


func _home_chunk_load(cx: int, cz: int) -> void:
	_ch_cx = cx
	_ch_cz = cz
	var o := _home_rec_offset(cx, cz)
	_h16 = PackedInt32Array()
	_h16.resize(256)
	_t16 = PackedByteArray()
	_t16.resize(256)
	for slot in 256:
		_h16[slot] = int(pay[o + 2 * slot]) | (int(pay[o + 2 * slot + 1]) << 8)
		_t16[slot] = int(pay[o + 768 + slot])
	# clamped central differences (the piece-1 home recipe: the gradient
	# is computed PER CHUNK - clamped at the chunk edges), 1 m spacing.
	_gx16 = PackedFloat32Array()
	_gx16.resize(256)
	_gz16 = PackedFloat32Array()
	_gz16.resize(256)
	for lz in 16:
		for lx in 16:
			var s := lz * 16 + lx
			_gx16[s] = float(_h16[lz * 16 + mini(lx + 1, 15)] - _h16[lz * 16 + maxi(lx - 1, 0)]) / 2.0
			_gz16[s] = float(_h16[mini(lz + 1, 15) * 16 + lx] - _h16[maxi(lz - 1, 0) * 16 + lx]) / 2.0


func _face_build_block(b: int) -> void:
	# One 16-row H2/T2 block (rows 16b..16b+15) from the payload. The
	# mirror class stores cell (iu, iv) in local slot (15 - (iu&15), iv&15)
	# (SphereMath.face_mirror_x, machine-diffed in piece 1).
	var f: int = color_face
	var mirrored: bool = SphereMath.face_mirror_x(f)
	for lz in 16:
		var iv: int = b * 16 + lz
		for ccx in FACE_GRID:
			var o := _record_offset(f, ccx, b)
			for lx in 16:
				var slot := lz * 16 + lx
				var iu: int = ccx * 16 + (15 - lx if mirrored else lx)
				var pidx: int = iv * NPIX + iu
				_h2[pidx] = int(pay[o + 2 * slot]) | (int(pay[o + 2 * slot + 1]) << 8)
				_t2[pidx] = int(pay[o + 768 + slot])


func _step_face(t0: int) -> void:
	var f: int = color_face
	var s_cell: float = SphereMath.face_cell_size(R)
	var du_m: float
	var dv_m: float
	if f >= 4 and f <= 7:
		du_m = s_cell
		dv_m = s_cell * 0.5
	else:
		du_m = s_cell * 0.5
		dv_m = s_cell
	var hw: float = SphereMath.face_width(R) * 0.5
	var t_start := t0
	while color_row < NPIX:
		var j: int = color_row
		if f > 1:
			# build every H2 block row j can touch (rows j-1..j+1 span at
			# most blocks (j-1)/16..(j+1)/16; blocks are built in order)
			var need_hi: int = mini(FACE_GRID - 1, (j + 1) / 16)
			while _bld_row <= need_hi:
				_face_build_block(_bld_row)
				_bld_row += 1
				if (Time.get_ticks_usec() - t0) / 1000.0 >= BAKE_BUDGET_MS:
					_color_ms += float(Time.get_ticks_usec() - t_start) / 1000.0
					return
		var cz := 0
		var lz := 0
		if f <= 1:
			var z: int = int(floorf(hw * (2.0 * (float(j) + 0.5) / NPIX - 1.0)))
			cz = int(floorf(float(z) / 16.0))
			lz = int(z - cz * 16.0)
		for i in NPIX:
			var hv: int
			var tv: int
			var gx: float
			var gz: float
			if f <= 1:
				var x: int = int(floorf(hw * ((float(i) + 0.5) / NPIX if f == 0 else (float(i) + 0.5) / NPIX - 1.0)))
				var cx: int = int(floorf(float(x) / 16.0))
				var lx: int = int(x - cx * 16.0)
				if cx != _ch_cx or cz != _ch_cz:
					_home_chunk_load(cx, cz)
				var slot: int = lz * 16 + lx
				hv = _h16[slot]
				tv = int(_t16[slot])
				gx = _gx16[slot]
				gz = _gz16[slot]
			else:
				var pidx: int = j * NPIX + i
				hv = _h2[pidx]
				tv = int(_t2[pidx])
				gx = (float(_h2[j * NPIX + mini(i + 1, NPIX - 1)]) - float(_h2[j * NPIX + maxi(i - 1, 0)])) / (2.0 * du_m)
				gz = (float(_h2[mini(j + 1, NPIX - 1) * NPIX + i]) - float(_h2[maxi(j - 1, 0) * NPIX + i])) / (2.0 * dv_m)
			_pixel((j * NPIX + i) * 3, hv, tv, gx, gz)
		color_row += 1
		if (Time.get_ticks_usec() - t0) / 1000.0 >= BAKE_BUDGET_MS:
			_color_ms += float(Time.get_ticks_usec() - t_start) / 1000.0
			return
	# face complete - the PNG (one per face; the deflate is a ~tens-of-ms
	# spike, measured in the frame stats - it is part of the honest stall)
	var t_png := Time.get_ticks_usec()
	var img := Image.create_from_data(NPIX, NPIX, false, Image.FORMAT_RGB8, _out)
	img.save_png(_cache_path(f))
	_png_ms += float(Time.get_ticks_usec() - t_png) / 1000.0
	_out = PackedByteArray()
	color_face += 1
	if color_face >= 12:
		# the cache is fresh - load it back (the guard runs on the bytes
		# actually written, like the piece-1 on-disk guard)
		phase = Phase.LOAD
		color_face = 0
		_load_src = "cache"
	else:
		_start_face()


func _pixel(o: int, hv: int, tv: int, gx: float, gz: float) -> void:
	var ocean: bool = hv < SEA
	var col: Vector3
	if ocean:
		col = FCC[5]
	else:
		match tv:
			1:
				col = FCC[1]
			4:
				col = FCC[4]
			12:
				col = FCC[12]
			32:
				col = FCC[32]
			_:
				col = FCC[5]  # the piece-1 default (an unknown top reads as water)
	var b: float = 0.45 + 0.55 * clampf((-LX * gx + LY - LZ * gz) / sqrt(gx * gx + gz * gz + 1.0), 0.0, 1.0)
	if ocean:
		b = 1.0
	_out[o] = _byte(_l2s(col.x * b))
	_out[o + 1] = _byte(_l2s(col.y * b))
	_out[o + 2] = _byte(_l2s(col.z * b))


# sRGB companding (the standard piecewise; the inverse of the srgb_to_linear
# the fcc probe applied) - the piece-1 formula, byte-for-byte.
func _l2s(v: float) -> float:
	if v <= 0.0031308:
		return v * 12.92
	return 1.055 * pow(v, 1.0 / 2.4) - 0.045


# np.round is round-half-to-even; match it so the bake reproduces the
# shipped seed-44 PNG where the float paths agree.
func _byte(v: float) -> int:
	var x := v * 255.0
	var fl := int(floorf(x))
	var fr := x - float(fl)
	var r: int
	if fr > 0.5:
		r = fl + 1
	elif fr < 0.5:
		r = fl
	else:
		r = fl + 1 if fl % 2 == 1 else fl
	return clampi(r, 0, 255)


func _load_png(pth: String) -> Image:
	var f := FileAccess.open(pth, FileAccess.READ)
	if f == null:
		return null
	var b := f.get_buffer(f.get_length())
	f.close()
	var img := Image.new()
	if img.load_png_from_buffer(b) != OK:
		return null
	return img


# The runtime twin of the piece-1 on-disk variance guard (the smear
# repair): the loaded image must vary along BOTH axes. Lighter sample
# than the bake's (16 lines x 16 px, floor 4 distinct / 8 spread) - the
# bake-side guard is the strong one; this is the in-game tripwire that
# keeps a broken texture out of the tree (a failed guard hides the body
# rather than drawing garbage).
func _guard_check(img: Image) -> Dictionary:
	var rows := 1
	var cols := 1
	var minc := [255, 255, 255]
	var maxc := [0, 0, 0]
	var first_line: PackedByteArray = PackedByteArray()
	for k in 16:
		var j := k * 64
		var line := PackedByteArray()
		for i in 16:
			var px := img.get_pixel(i * 64, j)
			line.append(px.r8)
			line.append(px.g8)
			line.append(px.b8)
			minc[0] = mini(minc[0], px.r8)
			minc[1] = mini(minc[1], px.g8)
			minc[2] = mini(minc[2], px.b8)
			maxc[0] = maxi(maxc[0], px.r8)
			maxc[1] = maxi(maxc[1], px.g8)
			maxc[2] = maxi(maxc[2], px.b8)
		if first_line.is_empty():
			first_line = line
		elif line != first_line:
			rows += 1
	_first_col = PackedByteArray()
	for k in 16:
		var i := k * 64
		var col := PackedByteArray()
		for j in 16:
			var px := img.get_pixel(i, j * 64)
			col.append(px.r8)
			col.append(px.g8)
			col.append(px.b8)
		if k == 0:
			_first_col = col
		elif col != _first_col:
			cols += 1
	var spread: int = mini(mini(maxc[0] - minc[0], maxc[1] - minc[1]), maxc[2] - minc[2])
	return {
		"rows": rows,
		"cols": cols,
		"spread": spread,
		"ok": rows >= 4 and cols >= 4 and spread >= 8,
	}


func _build_meshes() -> void:
	var RB: float = R + float(SEA)
	_free_render()
	for f in 12:
		var mesh := ArrayMesh.new()
		var verts := PackedVector3Array()
		var uvs := PackedVector2Array()
		var nrm := PackedVector3Array()
		var idx := PackedInt32Array()
		for j in MESH_RES + 1:
			for i in MESH_RES + 1:
				var u: float = float(i) / float(MESH_RES)
				var v: float = float(j) / float(MESH_RES)
				var p: Vector3 = SphereMath.uv_to_world(f, u, v, RB)
				verts.append(p)  # body origin = the sphere centre: local == radial
				uvs.append(Vector2(u, v))
				nrm.append(p / RB)
		# winding per face: the chart axes differ per face; pick the
		# order whose corner normal points outward (cull_back then keeps
		# exactly the front hemisphere from outside - one front patch per
		# view ray, no self-ordering problem).
		var p00: Vector3 = SphereMath.uv_to_world(f, 0.0, 0.0, RB)
		var p10: Vector3 = SphereMath.uv_to_world(f, 1.0, 0.0, RB)
		var p01: Vector3 = SphereMath.uv_to_world(f, 0.0, 1.0, RB)
		var outward: bool = (p01 - p00).cross(p10 - p00).dot(p00) >= 0.0
		for j in MESH_RES:
			for i in MESH_RES:
				var a: int = j * (MESH_RES + 1) + i
				var b: int = a + 1
				var c: int = a + (MESH_RES + 1)
				var d: int = c + 1
				if outward:
					idx.append_array([a, c, b, b, c, d])
				else:
					idx.append_array([a, b, c, b, d, c])
		var arrs: Array = []
		arrs.resize(Mesh.ARRAY_MAX)
		arrs[Mesh.ARRAY_VERTEX] = verts
		arrs[Mesh.ARRAY_TEX_UV] = uvs
		arrs[Mesh.ARRAY_NORMAL] = nrm
		arrs[Mesh.ARRAY_INDEX] = idx
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrs)
		# 4.7 ArrayMesh does NOT compute the AABB from
		# add_surface_from_arrays (it stays zero) and a degenerate AABB
		# flakily culls the MeshInstance3D (the AC-0235 star fix,
		# main.gd) - the body is a 12 km sphere at up to 12 km view
		# distance: a zero AABB would cull it. Set the enclosing cube.
		mesh.set_custom_aabb(AABB(Vector3(-RB, -RB, -RB), Vector3(RB * 2.0, RB * 2.0, RB * 2.0)))
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		var sm := ShaderMaterial.new()
		sm.shader = _shader
		sm.set_shader_parameter("tex", textures[f])
		mi.material_override = sm
		mi.cast_shadow = 0  # the body casts no shadow (no world light path)
		add_child(mi)
		face_nodes.append(mi)
		shader_mats.append(sm)
	visible = false  # the first tick sets it (no un-uniformed flash)


func _free_render() -> void:
	for mi in face_nodes:
		if is_instance_valid(mi):
			mi.queue_free()
	face_nodes.clear()
	shader_mats.clear()


func _finish_bake() -> void:
	if not bake_active:
		return
	bake_active = false
	phase = Phase.LOADED
	var wall: int = Time.get_ticks_msec() - _bake_wall_t0
	bake_stats = {
		"mode": bake_stats.get("mode", "baked"),
		"cache": bake_stats.get("cache", ""),
		"wall_ms": wall,
		"gen_ms": int(_gen_ms),
		"color_ms": int(_color_ms),
		"png_ms": int(_png_ms),
		"load_ms": int(_load_ms),
		"frames": _frame_n,
		"step_ms_max": roundf(_step_max_ms * 100.0) / 100.0,
		"step_ms_mean": roundf(_step_sum_ms / maxf(float(_frame_n), 1.0) * 100.0) / 100.0,
		"frame_ms_max": roundf(_frame_max_ms * 100.0) / 100.0,
		"frame_ms_mean": roundf(_frame_sum_ms / maxf(float(_frame_n), 1.0) * 100.0) / 100.0,
		"chunks": pay_total,
		"guard": guard.duplicate(),
	}
	print("SATELLITE bake done: %s" % str(bake_stats))


func _fail(why: String) -> void:
	bake_active = false
	phase = Phase.FAILED
	visible = false
	bake_stats = {"mode": "failed", "why": why, "guard": guard.duplicate()}
	print("SATELLITE bake FAILED: %s" % why)


func force_rebake() -> void:
	# The arm's reproducibility check: wipe the cache, free the render,
	# and run the whole pipeline again from the payloads.
	var d := DirAccess.open(_cache_dir())
	if d != null:
		for f in 12:
			DirAccess.remove_absolute(_cache_path(f))
	_free_render()
	textures.clear()
	guard.clear()
	_start_bake()


func _process(_delta: float) -> void:
	# the FULL frame delta while the bake runs (the hitch that matters -
	# the slice's own cost is _step_*; the frame delta includes the
	# streaming work that shares the main thread).
	if bake_active:
		var now := Time.get_ticks_msec()
		if _last_bake_tick > 0:
			var dms := float(now - _last_bake_tick)
			_frame_sum_ms += dms
			_frame_n += 1
			if dms > _frame_max_ms:
				_frame_max_ms = dms
		_last_bake_tick = now
