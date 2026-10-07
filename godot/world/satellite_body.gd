# MESH GRID (AC-0384 r3) - MESH_STEP is the displacement grid, in metres,
# per face (the 16 m column scale at the shipped R = 4000). The shipped
# default never changes; AWECRAFT_SAT_MESH_STEP overrides it for render
# runs (clamped 4..256) so a software-renderer box can settle a frame
# CARRYING the body: the r2 renders timed out at 1500 s on the settled
# 1.7 M-vertex frame (HARNESS.md §2 documents the class), and a render
# that never settles the body cannot show the seam this ticket is about.
# At 64 the vertex count drops ~16x and the displaced surface keeps its
# shape (the displacement is metres-scale; the extra facet pooling is a
# few metres, inside the 70 m dissolve window).
#
# AC-0310 P2 - the satellite body tier (whole-planet view above the
# atmosphere). Draws the planet as one closed body: the 12-face
# great-circle chart (core/sphere_math.gd), textured with the per-face
# 1024^2 satellite textures. Per-fragment existence and haze live in
# core/satellite_body.gdshader (the no-pop contract); this node owns
# the geometry, the textures and the thresholds.
#
# SURFACE (AC-0384 round 2) - the body IS the terrain's far LOD: each
# mesh vertex sits at R + H(u, v), H the baked terrain height (the same
# field the far tiers draw), on a per-face 16 m grid (the column scale).
# The pre-round-2 constant R + SEA sphere put the surface H - SEA metres
# BELOW the ground wherever terrain rises above sea level (13.4 m at
# the seed-44 spawn - a detached pale arc + a ~1.9 deg sky gap at the
# 400 m horizon; the user's "much smaller sphere … nowhere near the
# actual play area"). The height channel travels with the texture: the
# face PNGs are RGBA8 with A = round(H * 255 / HMAX), so the cache and
# res paths rebuild the same displaced mesh without the full payload
# (a legacy image without an alpha channel falls back to the constant
# R + SEA sphere, with a loud SATDIAG line - never silent). The
# h_first/h_full thresholds stay derived from R + SEA (the per-fragment
# op is the real controller; the rim shift from the displacement is a
# few metres on a 70 m fade window).
#
# TEXTURE SOURCE - one of, in order:
#  (1) the user:// cache, keyed (planet_id, R, seed) - the runtime bake
#      below, or a previous run's;
#  (2) the shipped res:// assets for the canonical seed 44 (the piece-1
#      bake, tasks/AC-0310/);
#  (3) the runtime bake: far column payloads ([H u16x256][biome x256]
#      [top x256] per chunk - the same call the demotion path makes)
#      for all 196,196 chunks (home pair cx,cz in [-197,196]^2, then
#      faces 2-11 as 64x64 at (face*64+ccx, face*64+ccz) - the piece-1
#      keying minus the per-face seed salt, dropped at AC-0311 piece 3:
#      the sphere-domain field is one pure f(world, seed), so the bake
#      and the streamed face chunks read the same terrain; the (face, R)
#      thread reaches the C++ (d, delta) domain on both lanes), colour-
#      baked with the piece-1 recipe (fcc top colour x fixed-sun
#      lambert, stored sRGB).
#
# BAKE MODE (AC-0382 a) - OFF-THREAD. The whole bake pipeline (generate_
# far x 196,196, the piece-1 colour, the 12 PNG writes - the ~tens-of-ms
# deflate spike lives here now - the read-back + variance guard, and the
# 12 face geometries) runs on ONE WorkerThreadPool slot, not sliced on
# the main thread (the pre-AC-0382 6 ms/frame slice measured step max
# 171 ms @R50 / 288.75 ms @r4 - the PNG-deflate frame - against a full
# frame max 229/293 ms; tasks/AC-0382/AC-0382-results.html has the
# before/after pair). generate_far is a pure const C++ call the
# thread-gen pool already runs from worker threads (world.gd
# _threadgen_worker; the AC-0263 prewarm note owns the singleton race),
# so no new C++ task type was owed - the pool-thread twin of the old
# slice is the same call, un-sliced. The main thread only polls
# (bake_done) and then does the thin GPU-side consumption (one face's
# ImageTexture + mesh node per frame). The single-writer discipline:
# before bake_done only the worker touches pay/_out/_h2/_t2/guard/_geom/
# _worker_images; the main thread reads them only after.
#
# SHADING (AC-0382 b) - the moving sun. The bake carries the piece-1
# fixed-sun lambert in the pixels; the shader re-weights it by the
# radial ratio dot(u_sun, NORMAL)/L_RADIAL so the terminator tracks the
# world's actual sun (the DayNight.sun_direction convention, the same
# functions the flat world's DirectionalLight3D uses). No re-bake per
# sun position, no new texture channel - the ratio is exact for the
# dominant (radial) lambert term, which is constant for every fragment
# (L_RADIAL = 1/sqrt(1.2)); the per-texel slope modulation stays baked
# (the minor term, frozen at the piece-1 sun). See the shader.
class_name SatelliteBody
extends Node3D

const NPIX := 1024
# AC-0384 r2: the body mesh grid step (metres) - the far tier's column
# scale (CHUNK = 16 m). The body is the terrain's far LOD: one vertex per
# 16 m of H, so the mesh carries the same height detail the far terrain
# shows (the 28,812-vertex 49x49 grid was smooth sea level; this is the
# ~1.7 M-vertex terrain surface at R = 4000, ~466 k at R = 2000).
const MESH_STEP := 16.0
# AC-0384 r3: the LIVE grid step - MESH_STEP by default (byte-identical
# behaviour), AWECRAFT_SAT_MESH_STEP overrides it (clamped 4..256) so a
# software-renderer box can settle a frame carrying the body (see the
# MESH GRID note above). Read once in _ready, before any geometry is
# built (the bake worker and the load path both read this var, never the
# const). It changes the MESH ONLY: the cache key, the textures and the
# H grid are step-independent (the geometry is rebuilt from the grid).
var mesh_step := MESH_STEP


func _mesh_grid(f: int) -> Vector2i:
	# (u subdivisions, v subdivisions) of the displaced grid for face f.
	# The home pair is the half-width face: u spans W/2 (196 steps at
	# R = 4000), v spans W (393). Faces 2-11 span W x W (393 x 393).
	var W: float = SphereMath.face_width(R)
	if f <= 1:
		return Vector2i(int(roundf(W / 2.0 / mesh_step)), int(roundf(W / mesh_step)))
	return Vector2i(int(roundf(W / mesh_step)), int(roundf(W / mesh_step)))
const HOME_HALF := 197  # home chunks per axis: cx, cz in [-197, 196]
const HOME_N := HOME_HALF * 2  # 394
const HOME_CHUNKS := HOME_N * HOME_N  # 155,236
const FACE_GRID := 64  # faces 2-11: face chunks per axis
const FACE_CHUNKS := FACE_GRID * FACE_GRID  # 4,096
const CANONICAL_SEED := 44  # the shipped res:// textures are this seed's bake
# AC-0382: the bake no longer slices the main thread (it runs on a pool
# thread); the 6 ms budget is the pre-AC-0382 constant, kept for the
# AC-0310 results cross-reference.

enum Phase { NONE, PAYLOAD, FACE, LOAD, LOADED, FAILED, WORK }  # PAYLOAD/FACE: pre-AC-0382 slice phases (kept for old-log phase values)

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

var pay := PackedByteArray()  # 196,196 x 1024-byte far payloads (worker-owned until bake_done)
var pay_total := 0

var color_face := 0  # LOAD phase (cache/res): the face index
var color_row := 0  # the row machine's position (faces 0..11)
var bake_consume := 0  # WORK-phase consumption: the next face (main thread)
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
# AC-0384: which predicate CHOSE _load_src, recorded so a run that silently
# fell through to baking is VISIBLE in the arm's RESULT (the editor-true /
# export-false decision is invisible to a bare "did it bake" check).
var _src_predicate := ""  # "FileAccess.user" | "ResourceLoader.res" | "bake.*"
var _res_load_via := ""  # how the res faces loaded: "import" | "raw-fallback" | ...
var _bake_reason := ""  # why a bake ran (loud, never silent)

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
# AC-0382: the off-thread bake state. The worker is the single writer of
# every field below until bake_done (main-thread reads only after).
var bake_done := false
var bake_result: Dictionary = {}
var bake_worker_ms := 0
var _worker_images: Array = []  # 12 decoded Images (the read-back the guard ran on)
var _geom: Array = []  # 12 precomputed face geometries {v,u,n,i}
var _hgrid := PackedInt32Array()  # AC-0384 r2: the current face's 1024^2 height grid (_step_face fills it; _geom_for_face + the PNG alpha consume it)
var _hgrid_load: Array = []  # AC-0384 r2: face -> height grid derived from the PNG alpha (load path); an empty entry = a legacy image -> constant R + SEA

# the per-frame state the probe arm reads (the shader-side values,
# mirrored - headless has no GPU, the arm checks the contract numerically)
var last_h_band := -1.0
var last_h_first := 0.0
var last_h_full := 0.0
var last_fog_far := 0.0
var last_render_edge := 0.0
var _cam: Node = null

# AC-0384 DIAGNOSTIC (user request, 2026-10-02: "is there any logging you
# could add to help you figure out why it's not working on my pc?"). The
# user runs an exported Windows build and cannot debug; one still screenshot
# already failed twice to separate "the body drawing too pale" from "the
# AC-0385 cloud shell seen from above", so this reports THE FACTS from
# inside the running game: one greppable line per event, prefix SATDIAG,
# to stdout AND appended to user://satdiag.txt (the windowed-build
# fallback). Pure observation: it reads state and never writes render
# state. The single behaviour branch is the user-facing A/B toggle
# (_body_off, default off) - with the diagnostic silent (AWECRAFT_SATDIAG=0)
# and the toggle untouched, the output is byte-identical.
# Env (all optional):
#   AWECRAFT_SATDIAG=0      silence all diagnostic output (default: on)
#   AWECRAFT_SAT_BODY=0     start with the body HIDDEN (A/B test: if the
#                           pale surface disappears it is the body, if it
#                           stays it is the cloud shell)
#   AWECRAFT_SATDIAG_PERIOD=<s>  state-report period (default 2.0 s -
#                           keep it a few seconds, never per-frame)
#   AWECRAFT_SATDIAG_ALT=<m>     report THIS altitude instead of the
#                           player's (tests the reporting pipeline without
#                           flying; the line is labelled alt_src=env)
#   AWECRAFT_SATDIAG_BAND="lo,hi"  the reported band (default "500,2000")
# In-game: F7 toggles the body off/on (the A/B key).
var _satdiag := true
var _body_off := false
var _satdiag_file: FileAccess = null
var _last_ppos := Vector3.ZERO
var _satdiag_acc := -1.0
var _satdiag_period := 2.0
var _satdiag_alt_override := -1.0
var _satdiag_band_lo := 500.0
var _satdiag_band_hi := 2000.0
var _satdiag_in_band := false
var _satdiag_band_init := false
# AC-0384 (the file the USER can actually find): on top of the stdout +
# user://satdiag.txt copies above, the same report is REWRITTEN (never
# appended, so it stays small enough to email) into two obvious places -
# the user's Desktop and the folder the game runs from (where they
# unzipped it: next to the .pck and the dlls) - named
# AweCraft-satdiag.txt, with a plain-words summary at the top. A missing
# or read-only location is noted once and skipped; it must never crash
# or spam. With AWECRAFT_SATDIAG=0 none of this runs at all.
const _SATDIAG_REPORT_NAME := "AweCraft-satdiag.txt"
const _SATDIAG_HISTORY_CAP := 80
var _satdiag_report_paths: Array = []
var _satdiag_target_state: Dictionary = {}  # path -> "ok" | "failed" (last write)
var _satdiag_warned: Dictionary = {}  # path -> true (the failure was noted once)
var _satdiag_history: Array[String] = []  # recent SATDIAG lines (the report's detail tail)
var _satdiag_last_alt := 0.0
var _satdiag_last_alt_src := "none"
var _satdiag_last_op := -1.0


func _ready() -> void:
	_shader = load("res://core/satellite_body.gdshader")
	# AC-0384 r3: the mesh-grid step override (default = MESH_STEP, no
	# behaviour change). Read here so both geometry lanes (the bake
	# worker, the load path) see the same value before the first grid.
	var mst: String = OS.get_environment("AWECRAFT_SAT_MESH_STEP")
	if mst != "" and mst.to_float() >= 4.0:
		mesh_step = clampf(mst.to_float(), 4.0, 256.0)
	# AC-0384 diagnostic: read the env knobs once, open the fallback log
	# file (the windowed build may not keep a console), print the banner
	# with the user's trigger instructions.
	var sd: String = OS.get_environment("AWECRAFT_SATDIAG").to_lower()
	_satdiag = sd != "0" and sd != "off"
	_body_off = ["0", "off", "hidden"].has(OS.get_environment("AWECRAFT_SAT_BODY").to_lower())
	if _satdiag:
		var per: String = OS.get_environment("AWECRAFT_SATDIAG_PERIOD")
		if per != "" and per.to_float() > 0.0:
			_satdiag_period = per.to_float()
		var aov: String = OS.get_environment("AWECRAFT_SATDIAG_ALT")
		if aov != "":
			_satdiag_alt_override = aov.to_float()
		var band: String = OS.get_environment("AWECRAFT_SATDIAG_BAND")
		if band != "" and band.contains(","):
			var lo := band.split(",")[0].to_float()
			var hi := band.split(",")[1].to_float()
			if lo < hi:
				_satdiag_band_lo = lo
				_satdiag_band_hi = hi
		_satdiag_file = FileAccess.open("user://satdiag.txt", FileAccess.READ_WRITE)
		if _satdiag_file != null:
			_satdiag_file.seek_end(0)
		_satdiag_report_paths = _satdiag_report_paths_build()
		_satline("diag: on (silence: AWECRAFT_SATDIAG=0) | body A/B: press F7 in-game, or start with AWECRAFT_SAT_BODY=0 to hide it | body_off=%s period=%.1fs band=[%.0f,%.0f] | send back the file: %s" % [str(_body_off), _satdiag_period, _satdiag_band_lo, _satdiag_band_hi, _satdiag_report_summary()])


func _reset_counters() -> void:
	# AC-0382: explicit reset - the pre-AC-0382 code never zeroed the
	# accumulators between a startup load and force_rebake's bake, so the
	# rebake's frames/step/frame stats inherited the startup's (a latent
	# measurement bug the AC-0310 res-then-rebake runs happened not to
	# expose: the res load contributed 0 to gen/color/png).
	_gen_ms = 0.0
	_color_ms = 0.0
	_png_ms = 0.0
	_load_ms = 0.0
	_step_max_ms = 0.0
	_step_sum_ms = 0.0
	_frame_max_ms = 0.0
	_frame_sum_ms = 0.0
	_frame_n = 0
	_last_bake_tick = 0


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
	if _cache_paths_exist():
		# (1) user:// runtime cache: raw files the engine wrote ->
		#     FileAccess.file_exists is the right (and only) predicate.
		_load_src = "cache"
		_src_predicate = "FileAccess.user"
		_phase_load("cache", _cache_dir())
	elif seed == CANONICAL_SEED and _res_paths_exist():
		# (2) the shipped res:// textures are IMPORTED resources. The export
		#     PCK ships the imported .ctex, NOT the raw .png, so
		#     FileAccess.file_exists is FALSE in an export (the AC-0384 white
		#     planet) while ResourceLoader.exists - which consults the import
		#     system - is TRUE in an export (proven by the packed-build probe).
		_load_src = "res"
		_src_predicate = "ResourceLoader.res"
		_phase_load("res", "res://assets/satellite/")
	else:
		# (3) bake - LOUD. Expected for a non-canonical seed, but for the
		#     canonical seed it means the shipped textures were NOT loadable
		#     via the import system - the export signature. Say which, never
		#     fall through with no signal (the pre-AC-0384 bug).
		if seed == CANONICAL_SEED:
			_bake_reason = "canonical seed %d, shipped res:// textures not loadable via ResourceLoader" % seed
			_src_predicate = "bake.res-missing"
			push_warning("SATELLITE: %s - baking instead (the export must pack assets/satellite/ as imported textures)." % _bake_reason)
		else:
			_bake_reason = "non-canonical seed %d (no shipped textures)" % seed
			_src_predicate = "bake.no-shipped"
			_start_bake()
	# AC-0384 diagnostic: the load/bake decision, loud at decision time
	# (a silent fall-through to baking is the failure class this exists
	# to make visible).
	_satline("configure: planet_id=%d seed=%d R=%.0f SEA=%d hmax=%d src=%s predicate=%s reason=%s" % [planet_id, seed, R, SEA, HMAX, _load_src if _load_src != "" else "baked", _src_predicate, _bake_reason if _bake_reason != "" else "-"])


func _cache_dir() -> String:
	# AC-0384 r2: the _h token = the height-channel era. Pre-r2 caches
	# (RGB8, no height) are a DIFFERENT format: silently loading them
	# would render the constant sea-level sphere with the r2 UI - a
	# one-time re-bake is the honest path (loud in the configure line).
	return "user://satellite/p%d_r%d_s%d_h" % [planet_id, int(R), seed]


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


# AC-0384: the existence predicate is DOMAIN-DEPENDENT.
#  - user:// (the runtime bake cache): raw files the engine wrote ->
#    FileAccess.file_exists is the right (and only) predicate.
#  - res:// (the shipped textures): IMPORTED resources -> the PCK ships the
#    imported .ctex, not the raw .png, so FileAccess.file_exists is FALSE in
#    an export (the AC-0384 white planet). ResourceLoader.exists consults the
#    import system and is TRUE in an export (packed-build probe: 12/12).
func _cache_paths_exist() -> bool:
	for pth in _cache_dir_paths():
		if not FileAccess.file_exists(pth):
			return false
	return true


func _res_paths_exist() -> bool:
	for pth in _res_paths():
		if not ResourceLoader.exists(pth):
			return false
	return true


func _phase_load(src: String, where: String) -> void:
	_load_src = src
	phase = Phase.LOAD
	color_face = 0
	bake_active = true
	bake_stats = {"mode": src, "cache": where}
	_bake_wall_t0 = Time.get_ticks_msec()
	_reset_counters()


func _start_bake() -> void:
	phase = Phase.WORK
	bake_active = true
	bake_stats = {"mode": "baked", "cache": _cache_dir()}
	pay = PackedByteArray()
	guard.clear()
	textures.clear()
	_worker_images = []
	_geom = []
	_hgrid_load = []  # AC-0384 r2: a bake supersedes any partial load's grids
	color_face = 0
	bake_consume = 0
	bake_done = false
	bake_result = {}
	bake_worker_ms = 0
	_bake_wall_t0 = Time.get_ticks_msec()
	_reset_counters()
	DirAccess.make_dir_recursive_absolute(_cache_dir())
	# The C++ generator reference is fetched on the MAIN thread (the
	# AC-0263 prewarm already closed the lazy-singleton race at
	# world._ready; passing the reference keeps the pool thread from
	# being a first caller anyway) and handed to the worker as an arg.
	var g: Variant = WorldGen.gen_cpp()
	# .bind (the project convention - world.gd _tm_worker_run.bind(skey)):
	# the 4.7 add_task takes no args array.
	Engine.get_singleton("WorkerThreadPool").add_task(_bake_worker.bind(g), false)


# The per-frame driver (world._process). State is read back through the
# public fields.
func process_frame(ppos: Vector3, day_t: float, render_radius: int, fog_pct: float) -> void:
	if bake_active:
		var s0 := Time.get_ticks_usec()
		_bake_main_step()
		var sms := float(Time.get_ticks_usec() - s0) / 1000.0
		_step_sum_ms += sms
		if sms > _step_max_ms:
			_step_max_ms = sms
	if phase == Phase.LOADED:
		_tick_view(ppos, day_t, render_radius, fog_pct)


# The main-thread half of the bake (AC-0382). Two shapes:
#  - LOAD phase (cache/res mode): UNCHANGED from AC-0310 - one face per
#    frame (PNG load + guard + ImageTexture), all 12 meshes in the final
#    frame;
#  - WORK phase (bake mode): while the pool worker owns the pipeline
#    this is a poll (the main-thread stall of the bake is whatever
#    streaming owes on the same frame - measured as the frame delta, the
#    failure mode). On bake_done: the thin GPU-side consumption - one
#    face per frame (its ImageTexture from the worker-decoded image, its
#    mesh node from the worker-computed geometry).
func _bake_main_step() -> void:
	if phase == Phase.LOAD:
		var lf: int = color_face
		if lf >= 12:
			return
		var t0l := Time.get_ticks_usec()
		var img: Image
		if _load_src == "cache":
			# user:// runtime file - a raw FileAccess read is correct.
			img = _load_png(_cache_path(lf))
		else:
			# res:// shipped texture - the IMPORT SYSTEM (AC-0384). The raw
			# .png is not in the PCK, so FileAccess cannot read it; only
			# ResourceLoader.load (which consults the import system) works in
			# an export. The old _load_png(res path) is dead there.
			var r := _load_res_face(lf)
			img = r["img"]
			_res_load_via = r["via"]
		if img == null:
			_fail("cannot load %s (res:// faces come from the import system - the "
				+ "export ships the imported texture, not the raw png; via=%s)" % [_res_path(lf), _res_load_via])
			return
		var gd := _guard_check(img)
		guard.append(gd)
		if not gd["ok"]:
			_fail("variance guard failed on face %d: %s" % [lf, str(gd)])
			return
		textures.append(ImageTexture.create_from_image(img))
		# AC-0384 r2: the height channel (the PNG's alpha) - the grid the
		# displaced mesh is built from. An image without an alpha channel
		# (the legacy pre-r2 shipped/cache set) gets an empty grid:
		# _geom_for_face falls back to the constant R + SEA sphere, loud.
		# The pipeline's alpha formats: a PNG (cache or imported) with an
		# alpha channel decodes to FORMAT_RGBA8. (get_format() - this
		# build exposes the Image format via the method, not a property.)
		if img.get_format() == Image.FORMAT_RGBA8:
			var d8: PackedByteArray = img.get_data()
			var hg := PackedInt32Array()
			hg.resize(NPIX * NPIX)
			for k in NPIX * NPIX:
				hg[k] = int(roundf(float(d8[k * 4 + 3]) * float(HMAX) / 255.0))
			_hgrid_load.append(hg)
		else:
			_hgrid_load.append(PackedInt32Array())
			_satline("LOAD face %d: image has no height channel (legacy RGB) - "
				+ "constant R+SEA sphere for that face; a re-bake restores the terrain surface" % lf)
		color_face += 1
		_load_ms += float(Time.get_ticks_usec() - t0l) / 1000.0
		if color_face >= 12:
			_build_meshes()
			_finish_bake()
		return
	if not bake_done:
		return
	if not bake_result.get("ok", false):
		_fail(str(bake_result.get("why", "worker failed")))
		return
	if bake_consume == 0:
		visible = false  # no un-uniformed flash (the first _tick_view sets it)
	var lf: int = bake_consume
	if lf < 12:
		textures.append(ImageTexture.create_from_image(_worker_images[lf]))
		_build_face(lf)
		bake_consume += 1
	if bake_consume >= 12:
		visible = false
		_finish_bake()


func _tick_view(ppos: Vector3, day_t: float, render_radius: int, fog_pct: float) -> void:
	_last_ppos = ppos  # AC-0384 diagnostic: cached for the _process report
	var h_band: float = (ppos + Vector3(0.0, R, 0.0)).length() - R
	var RB: float = R + float(SEA)
	var ff: float = DayNight.fog_far(render_radius, fog_pct)
	var edge: float = (float(render_radius) + 1.0) * 16.0
	# Derived thresholds (no constants - spec precision (a)):
	#  h_first: the rim's tangent distance d_t(h) = sqrt((R+h)^2 - RB^2)
	#           crosses fog_far - the rim emerges as it passes the fog wall.
	#  h_full:  the nadir (distance h - SEA) clears the render edge - the
	#           near region is fully established.
	# AC-0382 (c) - RECORDED, DO NOT IMPLEMENT: an explicit "sub-pixel
	# disc cull at altitude" is a visual NO-OP. Above the fade band,
	# every drawn-disc fragment farther than fog_far from the player is
	# 100% depth-fogged - it renders EXACTLY the air colour (the same
	# value the body's near-edge haze blends to, AC-0310-results §3).
	# Culling it changes no pixels, only fill/vertex cost. Do not "fix"
	# the disc's altitude draw as a visual change; if it is ever
	# optimized, it is a draw-cost optimization and must be measured as
	# one (AC-0310-results §8, this ticket's results page §4).
	var h_first: float = sqrt(RB * RB + ff * ff) - R
	var h_full: float = float(SEA) + edge
	last_h_band = h_band
	last_h_first = h_first
	last_h_full = h_full
	last_fog_far = ff
	last_render_edge = edge
	# AC-0384 diagnostic: the A/B toggle (F7 / AWECRAFT_SAT_BODY) forces
	# the body off so the user can tell body from cloud shell. Default
	# (_body_off = false) is exactly the original expression.
	var vis := h_band > h_first and not _body_off
	if visible != vis:
		visible = vis
	if vis:
		# AC-0382 (b): the moving sun - the DayNight convention (the same
		# functions the flat world's DirectionalLight3D + ambient use,
		# main.gd): u_day = floor+gain level, u_day_gain = the per-
		# fragment sun term's weight (0 at night - the flat 0.18 floor,
		# exactly the pre-AC-0382 night), u_sun = direction TO the sun
		# (the light travels along sun_direction, so to-sun is its
		# negation). The shader re-weights the baked fixed-sun lambert by
		# the radial ratio - the terminator now tracks the world's sun.
		var day := DayNight.day(day_t)
		# AC-0384 r8: the air colour is now the SINGLE-SOURCE sky-model
		# value (Aero.fog_display - the sky pass's exact horizon output)
		# instead of DayNight.sky_display, so the dome's haz, the env fog
		# (main.gd), and the sky's horizon are one colour by
		# construction. NOT space-adjusted: the AC-0386 contract is that
		# the space gradient touches the background only (the ground seen
		# from orbit is depth-fog only, no double darkening).
		var u_air := Aero.fog_display(day_t)
		for m in shader_mats:
			m.set_shader_parameter("u_fog_far", ff)
			m.set_shader_parameter("u_render_edge", edge)
			# AC-0390: the old u_clear_dist (4*edge) uniform is gone -
			# the shader's edge-continuity term is now the complement of
			# the existence ramp, windowed by (u_fog_far, u_render_edge)
			# exactly like the world's own fog.
			m.set_shader_parameter("u_air", u_air)
			m.set_shader_parameter("u_day", 0.18 + 0.82 * day)
			m.set_shader_parameter("u_day_gain", 0.82 * day)
			m.set_shader_parameter("u_sun", -DayNight.sun_direction(day_t))
		# The camera far plane (default 4000) would clip the body's far
		# limb (h + 2*RB out): extend it while the body is visible,
		# restore it when hidden. AC-0384 r2: RB is now the displaced
		# surface's max radius (R + HMAX) - the old R + SEA would clip
		# the far limb by up to 2*(HMAX - SEA) on a mountain planet.
		if _cam == null or not is_instance_valid(_cam):
			var pl = Game.player
			_cam = pl.get_node_or_null("Camera3D") if pl != null else null
		if _cam != null:
			var want: float = h_band + 2.0 * (R + float(HMAX)) + 200.0
			if absf(float(_cam.far) - want) > 1.0:
				_cam.far = want
	elif _cam != null and is_instance_valid(_cam) and absf(float(_cam.far) - 4000.0) > 1.0:
		_cam.far = 4000.0  # the engine default, restored


# The shader-side per-fragment opacity, mirrored for the probe arm
# (headless has no GPU; the arm checks the contract numerically).
func opacity_at(d: float) -> float:
	return smoothstep(last_fog_far, last_render_edge, d)


# AC-0382: the off-thread bake (one WorkerThreadPool slot, LOW priority
# so the streaming HIGH tasks are never starved). The pipeline:
#  1. generate_far x 196,196 -> pay (the pure const C++ call the
#     thread-gen pool already runs from worker threads - the same
#     precedent as world.gd _threadgen_worker; no new C++ task type
#     owed, the GDScript pool-thread twin suffices);
#  2. the piece-1 colour per face (the un-sliced twin of the old main-
#     thread slice: same _step_face row machine, budget = INF), each
#     face's PNG written as it completes (the ~tens-of-ms deflate spike
#     lands on the pool thread, not the main one);
#  3. the read-back + the variance guard on the bytes actually written;
#  4. the 12 face geometries (pure SphereMath, thread-safe).
# Single writer until bake_done (see the class header).
func _bake_worker(g: Variant) -> void:
	var err := ""
	var ship_msg := ""  # AC-0384 r2: the AWECRAFT_SATELLITE_SHIP report
	var w0 := Time.get_ticks_msec()
	if g == null:
		err = "no AweGen (WorldGen.gen_cpp() null)"
	if err == "":
		var t0 := Time.get_ticks_msec()
		for i in pay_total:
			var rec: PackedByteArray = _gen_one(g, i)
			if rec.size() != 1024:
				err = "generate_far payload %d bytes at record %d" % [rec.size(), i]
				break
			pay.append_array(rec)  # records land in generation order
		_gen_ms = float(Time.get_ticks_msec() - t0)  # ms (the fields are ms)
	if err == "" and pay.size() != pay_total * 1024:
		err = "payload %d bytes (want %d)" % [pay.size(), pay_total * 1024]
	if err == "":
		var t_face := Time.get_ticks_msec()
		for f in 12:
			color_face = f
			_start_face()
			while not _step_face(Time.get_ticks_usec(), 1e9):
				pass
			# AC-0384 r2: the geometry is built RIGHT AFTER the colour -
			# the face's H grid (_hgrid) is live; one code path for bake
			# and load (the pre-r2 second geometry loop ran after pay
			# was freed and built the constant-radius sphere).
			# AC-0384 r3: _geom_for_face self-appends to _geom when it
			# builds (the f == _geom.size() append at its tail) - the
			# pre-r3 _geom.append(...) HERE was a second append: after
			# face 0 the cache size overshot the face index, so every
			# later face hit the "return _geom[f]" early-out with face 0's
			# geometry (the cache grew to 13, all g0, and the bake path's
			# 11 non-home faces drew the home patch). Call it bare.
			_geom_for_face(f, _hgrid)
		# colour time = the face-pipeline wall minus the PNG writes (the
		# old main-thread slice's field semantics: colour and png separate;
		# _step_face accrues the png time into _png_ms inside the face).
		_color_ms = float(Time.get_ticks_msec() - t_face) - _png_ms
		pay = PackedByteArray()  # 201 MB no longer needed (the faces are coloured + on disk)
		# AC-0384 r2 (harness-only): ship the freshly baked faces to a
		# repo asset dir (the re-ship with the height channel). Env
		# AWECRAFT_SATELLITE_SHIP=<abs dir>; unset = no-op (the
		# canonical bake path). Reported via bake_result (worker thread:
		# _satline is main-thread only).
		var ship_dir := OS.get_environment("AWECRAFT_SATELLITE_SHIP")
		if ship_dir != "":
			for f in 12:
				var rf := FileAccess.open(_cache_path(f), FileAccess.READ)
				if rf == null:
					err = "ship: cannot read %s" % _cache_path(f)
					break
				var wb := rf.get_buffer(rf.get_length())
				rf.close()
				var wf := FileAccess.open(ship_dir + "/satellite_face%02d.png" % f, FileAccess.WRITE)
				if wf == null:
					err = "ship: cannot write %s" % (ship_dir + "/satellite_face%02d.png" % f)
					break
				wf.store_buffer(wb)
				wf.close()
			ship_msg = "shipped 12 height-channel faces to %s" % ship_dir if err == "" else err
	if err == "":
		var t2 := Time.get_ticks_msec()
		for f in 12:
			var img: Image = _load_png(_cache_path(f))
			if img == null:
				err = "cannot read %s" % _cache_path(f)
				break
			var gd := _guard_check(img)
			guard.append(gd)
			if not gd["ok"]:
				err = "variance guard failed on face %d: %s" % [f, str(gd)]
				break
			_worker_images.append(img)
		_load_ms = float(Time.get_ticks_msec() - t2)  # ms
	# (AC-0384 r2: the per-face geometry is built in the colour loop
	# above, while each face's H grid is live - no separate pass.)
	bake_result = {"ok": err == "", "why": err, "ship": ship_msg}
	bake_worker_ms = int(Time.get_ticks_msec() - w0)
	bake_done = true


# AC-0311 piece 3 (the same flat-frame class the port retired from
# generation): the piece-1 keying's per-face seed salt
# (seed^(face*1000003)) is DROPPED — in the sphere domain the field
# is ONE pure f(world, seed), so the bake and the streamed face
# chunks read the SAME terrain (a salted face would have been a
# different world from the live one). The (face, R) thread reaches
# the C++ (d, δ) domain on both lanes (R explicit — the bake is per
# (planet_id, R, seed), and the 4000 default is only the home planet).
func _gen_one(g: Variant, idx: int) -> PackedByteArray:
	if idx < HOME_CHUNKS:
		var cx: int = idx % HOME_N - HOME_HALF
		var cz: int = idx / HOME_N - HOME_HALF
		return g.generate_far(cx, cz, seed, HMAX, SEA, 0, R)
	var kf: int = idx - HOME_CHUNKS
	var f: int = 2 + kf / FACE_CHUNKS
	var kk: int = kf % FACE_CHUNKS
	var ccx: int = kk % FACE_GRID
	var ccz: int = kk / FACE_GRID
	return g.generate_far(f * FACE_GRID + ccx, f * FACE_GRID + ccz, seed, HMAX, SEA, f, R)


func _record_offset(f: int, ccx: int, ccz: int) -> int:
	return (HOME_CHUNKS + (f - 2) * FACE_CHUNKS + ccz * FACE_GRID + ccx) * 1024


func _home_rec_offset(cx: int, cz: int) -> int:
	return ((cz + HOME_HALF) * HOME_N + (cx + HOME_HALF)) * 1024


func _start_face() -> void:
	color_row = 0
	_out = PackedByteArray()
	_out.resize(NPIX * NPIX * 3)
	_hgrid = PackedInt32Array()
	_hgrid.resize(NPIX * NPIX)
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


# The row machine for the current face (color_face / color_row state).
# AC-0382: the pre-AC-0310 main-thread 6 ms slice is gone - the caller
# is the pool worker (budget_ms = 1e9, runs the face to completion).
# Returns false when the budget is spent (face incomplete - resume on
# the next call), true when the face's rows are done AND its PNG is
# written (the deflate spike is part of the face, measured in _png_ms).
func _step_face(t0: int, budget_ms: float) -> bool:
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
	while color_row < NPIX:
		var j: int = color_row
		if f > 1:
			# build every H2 block row j can touch (rows j-1..j+1 span at
			# most blocks (j-1)/16..(j+1)/16; blocks are built in order)
			var need_hi: int = mini(FACE_GRID - 1, (j + 1) / 16)
			while _bld_row <= need_hi:
				_face_build_block(_bld_row)
				_bld_row += 1
				if (Time.get_ticks_usec() - t0) / 1000.0 >= budget_ms:
					return false
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
			_hgrid[j * NPIX + i] = hv  # AC-0384 r2: the height channel (the geometry + PNG alpha source)
			_pixel((j * NPIX + i) * 3, hv, tv, gx, gz)
		color_row += 1
		if (Time.get_ticks_usec() - t0) / 1000.0 >= budget_ms:
			return false
	# face complete - the PNG (the deflate spike lands on the calling
	# thread - the pool worker since AC-0382). AC-0384 r2: RGBA8 - the
	# alpha channel carries the height (A = round(H * 255 / HMAX)) so
	# the cache/res paths rebuild the displaced mesh without the
	# payload. The RGB bytes are exactly the _pixel output (untouched:
	# the colour stays canonical across the re-ship).
	var t_png := Time.get_ticks_usec()
	var out4 := PackedByteArray()
	out4.resize(NPIX * NPIX * 4)
	for k in NPIX * NPIX:
		out4[k * 4] = _out[k * 3]
		out4[k * 4 + 1] = _out[k * 3 + 1]
		out4[k * 4 + 2] = _out[k * 3 + 2]
		out4[k * 4 + 3] = clampi(int(roundf(float(_hgrid[k]) * 255.0 / float(HMAX))), 0, 255)
	var img := Image.create_from_data(NPIX, NPIX, false, Image.FORMAT_RGBA8, out4)
	img.save_png(_cache_path(f))
	_png_ms += float(Time.get_ticks_usec() - t_png) / 1000.0
	_out = PackedByteArray()
	color_face += 1
	return true


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


# AC-0384: load one shipped res:// face via the IMPORT SYSTEM. The export PCK
# contains the imported .ctex, not the raw .png, so FileAccess cannot read it
# - ResourceLoader.load is the only path that works in an export. Returns
# {"img": Image, "via": String}. img is null only in a headless SOURCE-TREE
# run where the import texture has no CPU Image to decode to (no GPU); then
# it falls back to the raw file, which exists ONLY in the source tree (never
# in an export) - that keeps the pixel guard runnable in the headless arm.
# In an export the import path always yields the Image (packed probe: 1024^2).
func _load_res_face(f: int) -> Dictionary:
	var pth := _res_path(f)
	var tex := ResourceLoader.load(pth)
	if tex == null:
		return {"img": null, "via": "load-failed"}
	var img: Image = null
	if tex is Texture2D:
		img = tex.get_image()
	if img != null:
		return {"img": img, "via": "import"}
	img = _load_png(pth)
	if img != null:
		return {"img": img, "via": "raw-fallback"}
	return {"img": null, "via": "import-no-image"}


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


# The face geometry (pure SphereMath - thread-safe; the worker
# precomputes all 12 before bake_done, the cache/res path computes
# them on the main thread in _build_face). Cached in _geom.
func _geom_for_face(f: int, hgrid: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	if _geom.size() > f:
		return _geom[f]
	# AC-0384 r2: the displaced surface - one vertex per MESH_STEP (16 m)
	# of the H field, each at R + H(u, v) (the terrain's far LOD). The
	# pre-r2 constant R + SEA sea-level shell is the fallback when the
	# face's image carries no height channel (legacy set).
	var nu_nv: Vector2i = _mesh_grid(f)
	var nu: int = nu_nv.x
	var nv: int = nu_nv.y
	var has_h: bool = hgrid.size() == NPIX * NPIX
	var RB: float = R + float(SEA)  # the winding-test radius (any radial scale works)
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var nrm := PackedVector3Array()
	var idx := PackedInt32Array()
	for j in nv + 1:
		for i in nu + 1:
			var u: float = float(i) / float(nu)
			var v: float = float(j) / float(nv)
			var rr: float = RB
			if has_h:
				rr = R + _hgrid_sample(hgrid, u, v)
			var p: Vector3 = SphereMath.uv_to_world(f, u, v, rr)
			verts.append(p)  # body origin = the sphere centre: local == radial
			uvs.append(Vector2(u, v))
			nrm.append(p / rr)
	# winding per face: the chart axes differ per face; pick the
	# order whose corner normal points outward (cull_back then keeps
	# exactly the front hemisphere from outside - one front patch per
	# view ray, no self-ordering problem).
	var p00: Vector3 = SphereMath.uv_to_world(f, 0.0, 0.0, RB)
	var p10: Vector3 = SphereMath.uv_to_world(f, 1.0, 0.0, RB)
	var p01: Vector3 = SphereMath.uv_to_world(f, 0.0, 1.0, RB)
	var outward: bool = (p01 - p00).cross(p10 - p00).dot(p00) >= 0.0
	for j in nv:
		for i in nu:
			var a: int = j * (nu + 1) + i
			var b: int = a + 1
			var c: int = a + (nu + 1)
			var d: int = c + 1
			if outward:
				idx.append_array([a, c, b, b, c, d])
			else:
				idx.append_array([a, b, c, b, d, c])
	var ge := {"v": verts, "u": uvs, "n": nrm, "i": idx}
	if f == _geom.size():
		_geom.append(ge)
	return ge


func _hgrid_sample(hgrid: PackedInt32Array, u: float, v: float) -> float:
	# Bilinear over the 1024^2 per-texel H grid. Texel centres sit at
	# (k + 0.5) / NPIX in (u, v) - the same lattice the PNG texels and
	# _step_face's H reads use (home pair: the 1 m cells, faces 2-11:
	# the 6.135 m lattice) - so a mesh vertex lands on the H the
	# terrain's far tier shows there, up to the 16 m grid's pooling.
	var fx: float = clampf(u * float(NPIX) - 0.5, 0.0, float(NPIX) - 1.0)
	var fy: float = clampf(v * float(NPIX) - 0.5, 0.0, float(NPIX) - 1.0)
	var x0: int = int(fx)
	var y0: int = int(fy)
	var x1: int = mini(x0 + 1, NPIX - 1)
	var y1: int = mini(y0 + 1, NPIX - 1)
	var tx: float = fx - float(x0)
	var ty: float = fy - float(y0)
	var h00: float = float(hgrid[y0 * NPIX + x0])
	var h10: float = float(hgrid[y0 * NPIX + x1])
	var h01: float = float(hgrid[y1 * NPIX + x0])
	var h11: float = float(hgrid[y1 * NPIX + x1])
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), ty)


func _build_face(f: int) -> void:
	# One face: the mesh node + material (the thin main-thread work; the
	# geometry arrays come from _geom_for_face - worker-precomputed in
	# bake mode, computed here in the cache/res mode).
	# AC-0384 r2: the load path feeds the height grid derived from the
	# PNG alpha (bake mode: the worker pre-built the displaced geometry,
	# the _geom cache in _geom_for_face hits). RBx = the displaced
	# surface's maximum radius (R + HMAX) for the enclosing cube.
	var RBx: float = R + float(HMAX)
	var ge: Dictionary = _geom_for_face(f, _hgrid_load[f] if f < _hgrid_load.size() else PackedInt32Array())
	var mesh := ArrayMesh.new()
	# 4.7 ArrayMesh does NOT compute the AABB from
	# add_surface_from_arrays (it stays zero) and a degenerate AABB
	# flakily culls the MeshInstance3D (the AC-0235 star fix,
	# main.gd) - the body is a 12 km sphere at up to 12 km view
	# distance: a zero AABB would cull it. Set the enclosing cube.
	var arrs: Array = []
	arrs.resize(Mesh.ARRAY_MAX)
	arrs[Mesh.ARRAY_VERTEX] = ge["v"]
	arrs[Mesh.ARRAY_TEX_UV] = ge["u"]
	arrs[Mesh.ARRAY_NORMAL] = ge["n"]
	arrs[Mesh.ARRAY_INDEX] = ge["i"]
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrs)
	mesh.set_custom_aabb(AABB(Vector3(-RBx, -RBx, -RBx), Vector3(RBx * 2.0, RBx * 2.0, RBx * 2.0)))
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


func _build_meshes() -> void:
	# The cache/res path (unchanged from AC-0310: all 12 in the final
	# LOAD frame).
	_free_render()
	for f in 12:
		_build_face(f)
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
		# AC-0384: the recorded decision - which predicate chose the source and
		# how the res faces loaded, so a silent fall-through is visible.
		"src_predicate": _src_predicate,
		"res_load_via": _res_load_via,
		"bake_reason": _bake_reason,
		"wall_ms": wall,
		"worker": _worker_images.size() > 0,
		"worker_ms": bake_worker_ms,
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
		# AC-0384 r2: the AWECRAFT_SATELLITE_SHIP report (empty = unset).
		"ship": str(bake_result.get("ship", "")),
	}
	if str(bake_result.get("ship", "")) != "":
		_satline("SHIP: %s" % str(bake_result.get("ship", "")))
	print("SATELLITE bake done: %s" % str(bake_stats))
	_satline_config()  # AC-0384 diagnostic: the configured-state burst
	_satdiag_write_report()  # AC-0384: the findable file, at configure time


func _fail(why: String) -> void:
	bake_active = false
	phase = Phase.FAILED
	visible = false
	# AC-0384: record the decision even on failure - a res face that failed to
	# load is exactly the export condition, and it must be VISIBLE, not a bare
	# "bake failed".
	bake_stats = {
		"mode": "failed", "why": why, "guard": guard.duplicate(),
		"src_predicate": _src_predicate, "res_load_via": _res_load_via,
		"bake_reason": _bake_reason,
	}
	print("SATELLITE bake FAILED (predicate=%s via=%s): %s" % [_src_predicate, _res_load_via, why])
	_satline("config: phase=FAILED reason=%s predicate=%s via=%s" % [why, _src_predicate, _res_load_via])
	_satline_config()  # AC-0384 diagnostic: the partial state, still useful
	_satdiag_write_report()  # AC-0384: the findable file, at configure time


func force_rebake() -> void:
	# The arm's reproducibility check: wipe the cache, free the render,
	# and run the whole pipeline again from the payloads.
	if bake_active:
		push_error("SatelliteBody.force_rebake: a bake is already running")
		return
	var d := DirAccess.open(_cache_dir())
	if d != null:
		for f in 12:
			DirAccess.remove_absolute(_cache_path(f))
	_free_render()
	textures.clear()
	guard.clear()
	_start_bake()


func _process(_delta: float) -> void:
	# AC-0384 diagnostic: one bounded state report every couple of
	# seconds (AWECRAFT_SATDIAG_PERIOD; the default is 2 s - never
	# per-frame), plus a line on every band crossing.
	if _satdiag:
		_satdiag_acc += _delta
		if _satdiag_acc >= _satdiag_period:
			_satdiag_acc = 0.0
			_satdiag_tick()
	# the FULL frame delta while the bake runs (the hitch that matters -
	# the main-thread slice cost is _step_*; the frame delta includes the
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


# ---- AC-0384 diagnostic (see the _satdiag header block) ----

func _satline(line: String) -> void:
	# An empty line means a report builder aborted mid-way - never emit
	# a bare prefix (it reads as a hung report, not as a failure).
	if not _satdiag or line.strip_edges().is_empty():
		return
	var full := "SATDIAG " + line
	print(full)
	# The report's detail tail (a bounded ring - the file is REWRITTEN,
	# so this, not append growth, is what caps the file's size).
	_satdiag_history.append(full)
	if _satdiag_history.size() > _SATDIAG_HISTORY_CAP:
		_satdiag_history.remove_at(0)
	# Fallback (the windowed build may not keep a console): the same
	# line appended to a file, opened once in _ready (no truncate).
	if _satdiag_file != null and _satdiag_file.is_open():
		_satdiag_file.store_string(full + "\n")


func _satdiag_tick() -> void:
	var alt := 0.0
	var alt_src := "none"
	if _satdiag_alt_override >= 0.0:
		alt = _satdiag_alt_override
		alt_src = "env"
	elif configured:
		alt = (_last_ppos + Vector3(0.0, R, 0.0)).length() - R
		alt_src = "player"
	# Stashed for the plain-words summary (the report rewritten each tick).
	_satdiag_last_alt = alt
	_satdiag_last_alt_src = alt_src
	var s := smoothstep(_satdiag_band_lo, _satdiag_band_hi, alt)
	var in_band := configured and alt >= _satdiag_band_lo and alt <= _satdiag_band_hi
	# Band crossings - the transitions the user is looking at.
	if _satdiag_band_init and in_band != _satdiag_in_band:
		_satline("band: %s alt=%.1f S=%.3f band=[%.0f,%.0f]" % ["ENTERED" if in_band else "EXITED", alt, s, _satdiag_band_lo, _satdiag_band_hi])
	_satdiag_in_band = in_band
	_satdiag_band_init = true
	# The nadir opacity (the per-fragment opacity the user is seeing):
	# the player's distance to the closest body point, through the
	# mirrored smoothstep the shader computes (the AC-0384 fix).
	var op := -1.0
	if configured and phase == Phase.LOADED and last_fog_far > 0.0:
		var dc := (_last_ppos - Vector3(0.0, -R, 0.0)).length()
		op = opacity_at(maxf(dc - (R + float(SEA)), 0.0))
	_satdiag_last_op = op
	_satline("state: t=%.1f configured=%d phase=%s alt=%.1f(%s) S=%.3f h_first=%.1f h_full=%.1f op_nadir=%.3f fog_far=%.1f render_edge=%.1f body_off=%s vis=%s in_tree=%s pos=(%.0f,%.0f,%.0f) scale=%.3f" % [
		float(Time.get_ticks_msec()) / 1000.0, int(configured), Phase.keys()[phase], alt, alt_src, s,
		last_h_first, last_h_full, op, last_fog_far, last_render_edge,
		str(_body_off), str(visible), str(is_inside_tree()), position.x, position.y, position.z, scale.x])
	_satline(_satdiag_clouds())
	# AC-0384: the findable file refreshes on every tick (the slow timer)
	# and thus on every band crossing (detected above) - the user can fly
	# up, look at the planet, and then email a file describing exactly
	# what they were just looking at.
	_satdiag_write_report()


func _satdiag_clouds() -> String:
	# The cloud shell (AC-0385) - the other half of the body-vs-clouds
	# disambiguation: its altitude, coverage uniform and visibility.
	# Matched by the material's SHADER PATH, not the node name: Godot
	# auto-renames duplicate siblings on add_child, so in the live tree
	# only the first layer keeps the name "CloudLayer" (the rest become
	# @MeshInstance3D@N).
	var rt := get_tree()
	if rt == null or rt.root == null:
		return "clouds: no-tree"
	var found: Array = []
	var q: Array = [rt.root]
	while q.size() > 0:
		var nd: Node = q.pop_back()
		for ch in nd.get_children():
			if ch is MeshInstance3D:
				# `as` (not a typed assignment): other meshes in the tree
				# (the player model) carry a StandardMaterial3D override,
				# and a typed assign on the mismatch would throw.
				var m := ch.material_override as ShaderMaterial
				if m != null and m.shader != null and m.shader.resource_path.ends_with("cloud_layer.gdshader"):
					found.append(ch)
			q.append(ch)
	if found.is_empty():
		return "clouds: none (the AC-0385 shell is not in the tree)"
	found.sort_custom(func(a, b): return a.scale.x > b.scale.x)  # highest shell first
	var parts: Array = []
	for n in found.size():
		var mi: MeshInstance3D = found[n]
		var rsh: float = mi.scale.x
		var m: ShaderMaterial = mi.material_override
		var cov := -1.0
		var tint := "none"
		if m != null and m.shader != null:
			# AC-0401: get_shader_parameter returns null for a parameter
			# that was never set - the shaderforce probe is exactly such
			# a material (its pbox MeshInstance3D wears the cloud shader
			# with NO pushes, and this dump walks the WHOLE tree), and a
			# float(null) is a SCRIPT ERROR that fails the census on the
			# very run the probe exists to measure. -1.0 marks "no value"
			# in the line instead of throwing.
			var cv = m.get_shader_parameter("u_coverage")
			cov = float(cv) if cv is float else -1.0
			tint = str(m.get_shader_parameter("u_cloud_tint"))
		parts.append("c%d{vis=%s r=%.0f h=%.0f cov=%.3f shader=true tint=%s}" % [n, str(mi.visible), rsh, rsh - float(R), cov, tint])
	return "clouds: n=%d %s" % [found.size(), " ".join(parts)]


# ---- AC-0384: the findable file (Desktop + game folder, rewritten) ----

func _satdiag_report_paths_build() -> Array:
	# The two places a NON-DEVELOPER can actually find a file: the
	# Desktop, and the folder the game runs from (where they unzipped
	# it - next to the .pck and the dlls). An empty base dir is dropped
	# (never a broken path); an unwritable target is caught per-write
	# and noted ONCE.
	var out: Array = []
	var dsk := OS.get_system_dir(OS.SYSTEM_DIR_DESKTOP)
	if dsk != "":
		out.append(dsk.path_join(_SATDIAG_REPORT_NAME))
	var exedir := OS.get_executable_path().get_base_dir()
	if exedir != "":
		var p := exedir.path_join(_SATDIAG_REPORT_NAME)
		if not out.has(p):
			out.append(p)
	return out


func _satdiag_report_summary() -> String:
	if _satdiag_report_paths.is_empty():
		return "NONE AVAILABLE (the user://satdiag.txt copy is kept)"
	var parts: Array = []
	for p in _satdiag_report_paths:
		parts.append(p)
	return " | ".join(parts)


func _satdiag_write_report() -> void:
	if not _satdiag:
		return
	var text := _satdiag_report_text()
	for p in _satdiag_report_paths:
		_satdiag_target_write(p, text)


func _satdiag_target_write(path: String, text: String) -> void:
	# A full REWRITE, never an append: the file stays small enough to
	# email no matter how long the game runs. A failure (read-only
	# folder, missing directory) is noted ONCE and carried on - it must
	# never crash or spam.
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_satdiag_target_note(path)
		return
	f.store_string(text)
	var err := f.get_error()
	f.close()
	if err != OK:
		_satdiag_target_note(path)
	else:
		_satdiag_target_state[path] = "ok"


func _satdiag_target_note(path: String) -> void:
	_satdiag_target_state[path] = "failed"
	if not _satdiag_warned.has(path):
		_satdiag_warned[path] = true
		print("SATDIAG file: could not write %s - skipped, the report goes to the other locations (noted once)" % path)


func _satdiag_report_text() -> String:
	var out: Array = []
	out.append("AweCraft satellite diagnostic report")
	out.append("Generated: " + Time.get_datetime_string_from_system())
	out.append("This file is rewritten automatically while the game runs. Please send this whole file back.")
	out.append("")
	out.append("WHAT THE GAME SEES RIGHT NOW (plain words - the technical lines are below)")
	out.append("--------------------------------------------------------------------------------")
	for l in _satdiag_summary_lines():
		out.append(l)
	out.append("")
	out.append("This report is saved at:")
	if _satdiag_report_paths.is_empty():
		out.append("  (no Desktop or game-folder location available on this computer)")
	for p in _satdiag_report_paths:
		var st: String = str(_satdiag_target_state.get(p, ""))
		var note := ""
		if st == "ok":
			note = "  [written]"
		elif st == "failed":
			note = "  [NOT WRITABLE - skipped]"
		out.append("  - " + p + note)
	out.append("  - the game's private folder: %ssatdiag.txt (an append-only log, kept if it already exists)" % ProjectSettings.globalize_path("user://"))
	out.append("")
	out.append("RECENT EVENTS (newest last; refreshed on load, on each band crossing, and every couple of seconds)")
	out.append("--------------------------------------------------------------------------------")
	for l in _satdiag_history:
		out.append(l)
	return "\n".join(out) + "\n"


func _satdiag_summary_lines() -> Array:
	var lines: Array = []
	# 1. The body: visible? at what altitude?
	var state := ""
	if not configured:
		state = "NOT SET UP YET (the game is still starting)"
	elif phase == Phase.FAILED:
		state = "FAILED TO LOAD - nothing can be drawn"
	elif visible:
		state = "VISIBLE"
	elif _body_off:
		state = "HIDDEN BY THE F7 TOGGLE (press F7 to show it again)"
	elif phase != Phase.LOADED:
		state = "NOT FINISHED LOADING (phase: %s)" % Phase.keys()[phase]
	else:
		state = "HIDDEN BECAUSE YOU ARE BELOW ITS ALTITUDE BAND (it only appears high up)"
	lines.append("The big planet ball (\"the body\") is currently: %s - your altitude is %.1f metres above sea level (source: %s)" % [state, _satdiag_last_alt, _satdiag_last_alt_src])
	# 2. The 12 surface pictures.
	var tn := 0
	var tnull := 0
	for t in textures:
		if t != null and t is Texture2D:
			tn += 1
		else:
			tnull += 1
	var src := _load_src if _load_src != "" else "baked"
	var src_word: String = {
		"res": "the game's own files (shipped with the game)",
		"cache": "a saved copy on this computer",
	}.get(src, "generated by the game at startup")
	if tn == 12:
		lines.append("The 12 surface pictures: ALL 12 loaded, from %s" % src_word)
	else:
		lines.append("The 12 surface pictures: only %d of 12 loaded (from %s), %d MISSING" % [tn, src_word, tnull])
	# 3. The shader.
	if _shader == null:
		lines.append("The colour shader: MISSING")
	elif _shader.code.is_empty():
		lines.append("The colour shader: PRESENT BUT EMPTY (no code inside)")
	else:
		lines.append("The colour shader: present with its full code (%d characters)" % _shader.code.length())
	# 4. The mesh.
	var verts := 0
	for mi in face_nodes:
		if mi == null or not is_instance_valid(mi):
			continue
		var mesh: ArrayMesh = mi.mesh
		if mesh != null and mesh.get_surface_count() > 0:
			var arrs: Array = mesh.surface_get_arrays(0)
			if arrs.size() > 0:
				verts += int(arrs[Mesh.ARRAY_VERTEX].size())
	if verts > 0:
		lines.append("The surface mesh: %d vertices (healthy)" % verts)
	else:
		lines.append("The surface mesh: EMPTY (0 vertices - there is nothing to draw)")
	# 5. Opacity + the distance settings.
	if _satdiag_last_op >= 0.0:
		lines.append("How solid the ball looks right now (0 = invisible, 1 = fully solid): %.3f" % _satdiag_last_op)
		lines.append("The two distance settings in use: the fog reaches to %.0f metres; the fade edge is at %.0f metres" % [last_fog_far, last_render_edge])
	else:
		lines.append("How solid the ball looks right now: not measured yet (it appears within a couple of seconds of starting)")
	# 6. The cloud shells.
	lines.append(_satdiag_cloud_summary())
	# Problems - in plain words. Only asserted when a verdict is honest
	# (a mid-bake partial state is not a problem yet).
	if _shader == null or _shader.code.is_empty():
		lines.append("PROBLEM: the body's shader is missing or empty - without it the ball renders pure WHITE")
	if (phase == Phase.LOADED or phase == Phase.FAILED) and tn < 12:
		lines.append("PROBLEM: %d of the 12 surface pictures did not load - the ball will look wrong or white" % tnull)
	if phase == Phase.LOADED and verts == 0:
		lines.append("PROBLEM: the mesh has no vertices, so the body cannot be drawn")
	if phase == Phase.FAILED:
		lines.append("PROBLEM: the body failed to load - see the events below for the reason")
	return lines


func _satdiag_cloud_summary() -> String:
	# Plain-words twin of _satdiag_clouds(): counted the same way (by
	# shader path, not node name), reduced to "how many, how many visible".
	var rt := get_tree()
	if rt == null or rt.root == null:
		return "The cloud shells: not in the scene yet"
	var n := 0
	var vis := 0
	var q: Array = [rt.root]
	while q.size() > 0:
		var nd: Node = q.pop_back()
		for ch in nd.get_children():
			if ch is MeshInstance3D:
				var m := ch.material_override as ShaderMaterial
				if m != null and m.shader != null and m.shader.resource_path.ends_with("cloud_layer.gdshader"):
					n += 1
					if ch.visible:
						vis += 1
			q.append(ch)
	if n == 0:
		return "The cloud shells: none in the scene"
	return "The cloud shells: %d in the scene, of which %d visible" % [n, vis]


func _satline_config() -> void:
	if not _satdiag:
		return
	# All 12 textures: non-null + sizes (a null texture is the
	# white/garbage class that is invisible to every gate we own).
	var tn := 0
	var tsizes := ""
	for t in textures:
		if t != null and t is Texture2D:
			tn += 1
			tsizes += "%dx%d " % [int(t.get_width()), int(t.get_height())]
		else:
			tsizes += "NULL "
	# The SHADER: a ShaderMaterial with a null shader renders pure white
	# (invisible to every gate we own), so report it explicitly: the
	# resource path and the code non-empty. (A 4.x Shader exposes no
	# compile state from GDScript; a compile FAILURE the engine itself
	# prints to the console as a SHADER ERROR / "failed to compile" line,
	# which the user will see next to these - check for it.)
	var sh := "NULL-SHADER"
	if _shader != null:
		sh = "path=%s code_nonempty=%s code_bytes=%d" % [
			_shader.resource_path if _shader.resource_path != "" else "<inline>",
			str(_shader.code.length() > 0), _shader.code.length()]
	var msh := 0
	for m in shader_mats:
		if m != null and m.shader != null:
			msh += 1
	# The MESH: vertex count + AABB (an empty/degenerate mesh draws
	# nothing or garbage; the AC-0235 note owns the hand-set AABB).
	# Two AABBs: the CUSTOM one (the enclosing ±(R+SEA) cube _build_face
	# sets - the value the culler uses) and the GEOMETRY one of face 0
	# (a zero/absurd geometry AABB is the "Godot refused the mesh"
	# signature; note 4.7's Mesh.get_aabb() reports the geometry AABB,
	# not the custom one).
	var verts := 0
	var aabb_geom := "none"
	for mi in face_nodes:
		if mi == null or not is_instance_valid(mi):
			continue
		var mesh: ArrayMesh = mi.mesh
		if mesh != null and mesh.get_surface_count() > 0:
			var arrs: Array = mesh.surface_get_arrays(0)
			if arrs.size() > 0:
				# PackedVector3Array: .size() is the vertex count already.
				verts += int(arrs[Mesh.ARRAY_VERTEX].size())
			if aabb_geom == "none":
				var ab: AABB = mesh.get_aabb()
				aabb_geom = "min=(%.0f,%.0f,%.0f) size=(%.0f,%.0f,%.0f)" % [ab.position.x, ab.position.y, ab.position.z, ab.size.x, ab.size.y, ab.size.z]
	var RB: float = R + float(SEA)
	var aabb_custom := "min=(%.0f,%.0f,%.0f) size=(%.0f,%.0f,%.0f)" % [-RB, -RB, -RB, RB * 2.0, RB * 2.0, RB * 2.0]
	_satline("config: phase=%s src=%s via=%s reason=%s textures=%d/12 [%s]" % [
		Phase.keys()[phase], _load_src if _load_src != "" else "baked", _res_load_via if _res_load_via != "" else "-", _bake_reason if _bake_reason != "" else "-", tn, tsizes.strip_edges()])
	_satline("config: shader=%s mats_with_shader=%d/12" % [sh, msh])
	_satline("config: mesh faces=%d verts=%d aabb_custom=%s aabb_geom=%s node_vis=%s pos=(%.0f,%.0f,%.0f) scale=(%.2f,%.2f,%.2f) body_off=%s" % [
		face_nodes.size(), verts, aabb_custom, aabb_geom, str(visible), position.x, position.y, position.z, scale.x, scale.y, scale.z, str(_body_off)])


func _unhandled_input(event: InputEvent) -> void:
	# AC-0384 diagnostic: the A/B key. F7 hides the body so the user can
	# see whether the pale surface is the body (disappears) or the cloud
	# shell (stays). _tick_view reconciles `visible` on the next frame.
	var k := event as InputEventKey
	if k != null and k.pressed and not k.echo and k.keycode == KEY_F7:
		_body_off = not _body_off
		visible = (not _body_off) and (last_h_band > last_h_first)
		_satline("toggle: F7 body_off=%s visible=%s" % [str(_body_off), str(visible)])
