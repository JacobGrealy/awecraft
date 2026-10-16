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
# AC-0417: h_first stays derived from R + SEA (the fog window - it gates
# the body's visibility, and re-deriving it against the atmosphere
# height A would pop the rim in above the space transition: deviation
# D1, AC-0417-results.html); h_full is the atmosphere height A
# (Aero.atmosphere_height) so "the planet is fully established" lands
# with "the sky is space" (diagnostic - the per-fragment op is the real
# controller; the rim shift from the displacement is a few metres on a
# 70 m fade window).
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
# BAKE MODE (AC-0382 a) - OFF-THREAD, (AC-0414) MULTITHREADED. The whole
# bake pipeline (generate_far x 196,196, the piece-1 colour, the 12 PNG
# writes - the ~tens-of-ms deflate spike lives here - the read-back +
# variance guard, and the 12 face geometries) runs off the main thread.
# AC-0414 (Settings "sat_preload", default ON): the pipeline is SHARDED
# across the pool - 98 payload shards (196,196 = 98 x 2,002 records,
# exact) streamed at the core-count width as HIGH-priority tasks, then
# 12 per-face tasks (colour + PNG + read-back + guard + geometry), HIGH
# under the loading-window hold (the pre-AC-0414 single LOW task was the
# defect: the low lane runs on ONE thread - world.gd:6216 measured - and
# starved behind streaming, so the planet appeared minutes after the
# player arrived, when at all). After the hold's bounded release the
# remaining work enqueues LOW (world.gd sets bake_yield) until the
# player lands, so the sim-band diamond build (HIGH) does not queue
# behind the bake - the player lands at the budget + at most one shard
# slice; it goes HIGH again (capped) after landing. The
# single-
# writer discipline survives: each worker writes only its own shard
# buffer / its own face-index slot / its own PNG file (all in the bound
# state - AC-0418); the MAIN thread is the only writer of the node's
# guard/_worker_images/_geom (it merges the shards once, assembles the
# face results in face order once, and sets bake_done), then does the
# thin GPU-side consumption (one face's ImageTexture + mesh node per
# frame). The switch OFF keeps the pre-AC-0414 single-task path (now
# the same detached static, low priority, un-sliced - see the
# AC-0418 note below). generate_far is a pure const C++ call the
# thread-gen pool already runs from worker threads (world.gd
# _threadgen_worker; the AC-0263 prewarm note owns the singleton race),
# so no new C++ task type was owed - the shards call the same function.
# AC-0418: the worker side is DETACHED from the node - every task is a
# STATIC function of the plain script world/satellite_bake_worker.gd
# (SatelliteBakeWorker), and its only inputs are the bound per-bake state
# Dictionary (_bake_state), the AweGen C++ handle (alive for the
# process), class statics and engine singletons. A Callable to a static
# holds no object, and the state is kept alive by the task's own bound
# argument, so at process exit the node may be freed under the workers
# while nothing in their frame is freed with it: the mid-bake exit UAF
# (reproduced this ticket - 6/6 pre-detach stage-1 exits showed the
# signature, 2 segfaults + 4 VM-level Bad-address; 2/2 as-shipped face-
# stage exits segfaulted in _pixel_mt, the AC-0414 crash) is closed.
# SatelliteBody._mt_exit_aborted (the AC-0414 mitigation) is read FIRST
# in every task and stays the exit stand-down.
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

var pay_total := 0

var color_face := 0  # LOAD phase (cache/res): the face index
var bake_consume := 0  # WORK-phase consumption: the next face (main thread)
# AC-0418: the row-machine fields (the per-face H grids, the chunk cache,
# the RGB output) are gone from the instance - they live in the per-face
# state Dictionaries the worker tasks own (SatelliteBakeWorker), and the
# merged payload lives in the bake state (_bake_st). The worker-side work
# is a static function of that plain script: the node is out of every
# worker's frame (the mid-bake exit UAF close).

var textures: Array = []  # 12 ImageTexture (appended in load order 0..11)
var face_nodes: Array = []  # 12 MeshInstance3D
var shader_mats: Array = []  # 12 ShaderMaterial
var _shader: Shader = null
# AC-0421: boot-time env reads for the body's A/B (read once, cached; the
# values cannot change mid-run). _relief_env: -1 unset (use the live
# Settings "relief_shading"), 0 = the pre-AC-0421 flat path, 1 = the relief.
# _spec_env: -1.0 unset (shipped 0.0 — the satellite LOD is not reflective),
# 0.5 = the pre-AC-0421 glossy state (A/B only).
var _relief_env: int = -1
var _spec_env: float = -1.0
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
# AC-0382: the off-thread bake state. The worker is the single writer of
# every field below until bake_done (main-thread reads only after).
var bake_done := false
var bake_result: Dictionary = {}
var bake_worker_ms := 0
var _worker_images: Array = []  # 12 decoded Images (the read-back the guard ran on)
var _geom: Array = []  # 12 precomputed face geometries {v,u,n,i}
var _hgrid_load: Array = []  # AC-0384 r2: face -> height grid derived from the PNG alpha (load path); an empty entry = a legacy image -> constant R + SEA
# AC-0414: the multithreaded bake state (Settings "sat_preload" ON).
# BAKE_SHARDS x BAKE_SHARD_LEN == pay_total EXACTLY (196,196 =
# 2^2 x 7^3 x 11 x 13 = 98 x 2,002), so every shard buffer is the same
# size and the merge is one deterministic concat in shard order. 98 (not
# the 14 that first shipped): a shard's worker slice is ~7.7 s on this
# box / ~0.2 s on desktop-class hardware, so when the 42 s hold budget
# expires the in-flight shards finish within ONE slice and the ground
# build (HIGH) takes the pool - the bounded release the ticket names:
# the player lands at budget + at most one shard slice (the pre-yield
# 14 x 14,014 design measured a 109 s release here instead, because the
# 14 up-front HIGH shards held the pool to the payload's 160 s wall).
# The shards are STREAMED: the pool-width first batch enqueues at start,
# the poller enqueues the rest as slots open, at the yield-aware
# priority (HIGH under the hold, LOW after the late release until the
# player lands). _mt_shard_inflight_cap is set from the real core count
# at bake start (full utilisation on any machine).
const BAKE_SHARDS := 98
const BAKE_SHARD_LEN := 2002
var bake_mt := false  # this bake used the sharded path (bake_stats field)
var tail_inflight_cap := 12  # world.gd sets 4 after the hold releases late (streaming keeps its workers)
# AC-0414: world.gd sets this true when the hold releases LATE and false
# when the loading window closes (the player has landed). While true, the
# bake's remaining work enqueues at LOW priority - the sim-band diamond
# build (HIGH) takes the pool so the player's ground lands at the budget
# instead of behind the bake, while the bake's LOW work still makes
# progress in the gaps. After landing the tail goes HIGH again (capped at
# 4, so the steady streaming trickle keeps 2+ threads). The yield is what
# keeps the loud release line honest: it says the player is released at
# the budget, and the ground build no longer queues behind the bake.
var bake_yield := false
# AC-0414: a file-scope (not instance) exit flag. The bake workers run on
# pool threads with the node's script instance in their call stacks; if
# the process exits while a worker is mid-slice the instance is freed
# under them and any member read (even of bake_abort) is a
# use-after-free (measured: a segfault in _pixel_mt when a probe quit
# mid-bake). The static is readable WITHOUT touching the instance, so
# every abort check below reads it FIRST (short-circuit): at process
# exit _exit_tree flips it and each worker stands down at the next
# record / slice boundary with no further instance access. AC-0418
# detached the workers (SatelliteBakeWorker statics + the bound state
# Dict) so the epilogue no longer touches the node either; the flag
# stays as the exit stand-down (it is exercised on both bake paths).
static var _mt_exit_aborted := false
var _mt_stage := 0  # 0 idle, 1 shards in flight, 2 faces in flight
var _mt_shard_ids: Array = []  # enqueued shard tids (grows as the poller streams them)
var _mt_shard_next := 0  # the next shard index to stream (the poller owns it)
var _mt_shard_inflight_cap := 6  # set from OS.get_processor_count() at bake start
var _mt_face_ids: Array = []  # 12 (assigned at enqueue - the poller may trickle)
var _mt_face_enq: Array = []  # 12 (enqueued yet)
var _mt_gen_wall_ms := 0.0  # enqueue -> all shards complete (wall)
# AC-0418: the worker-visible bake state - a plain RefCounted Dictionary
# the node fills before enqueue and passes to the worker tasks as a BOUND
# ARGUMENT (the per-shard / per-face channels, the merged payload, the
# AweGen handle, the abort + done flags). The worker callables are STATIC
# functions of SatelliteBakeWorker (a plain script, alive for the
# process): they hold no node reference, and the state is kept alive by
# the tasks' own bound arguments, so it outlives the node's teardown.
# The mid-bake exit UAF close: at process exit the node is freed, this
# state is not, and every worker frame holds only this state, the C++
# handle, class statics and engine singletons. Main thread: single
# writer before enqueue; a worker channel is final once the pool says
# its task is complete.
var _bake_st: Dictionary = {}

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


# AC-0414: the node may be freed while bake workers are still on it (the
# process exits mid-bake - the bake now legitimately runs for minutes on
# slow hardware, so the user closing the game mid-bake is a live path).
# Flipping the file-scope flag here makes each worker stand down at its
# next record / slice boundary WITHOUT touching the (freed) instance;
# see _mt_exit_aborted. This is a mitigation (the in-flight slice still
# finishes); a full close needs the workers detached from the node.
func _exit_tree() -> void:
	_mt_exit_aborted = true


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
			# AC-0414: bake-before-load (Settings "sat_preload", default ON -
			# the user asked; the env override AWECRAFT_SATPRELOAD=0|1 is
			# preloaded in world.gd _ready, the AWECRAFT_RAMPS pattern). ON =
			# the sharded HIGH-priority pipeline - world.gd's loading-window
			# hold gates the release on this bake finishing. OFF = the
			# pre-AC-0414 single-task LOW-priority bake (AC-0418: the same
			# detached static as the ON path - SatelliteBakeWorker.
			# single_task - un-sliced, low priority; the world is released
			# first, the body may appear late).
			if bool(Settings.values.get("sat_preload", true)):
				_start_bake_mt()
			else:
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


# AC-0418: the worker-visible bake state - the single builder for both
# paths (ON: the sharded pipeline; OFF: the single task). The node is
# the single writer before enqueue; afterwards the worker tasks own
# their channels (the main thread reads a channel only once the pool
# says its task is complete - is_task_completed is the synchronisation)
# and the main thread writes only "abort" (the probe arm's clean-quit
# handle). The consts travel by VALUE (their single home stays this
# script); the values are the configure() values, fixed for the bake.
# The C++ generator reference is fetched on the MAIN thread (the
# AC-0263 prewarm note owns the lazy-singleton race) and rides in it.
func _bake_state() -> Dictionary:
	var st: Dictionary = {}
	st["g"] = WorldGen.gen_cpp()
	st["R"] = R
	st["SEA"] = SEA
	st["HMAX"] = HMAX
	st["seed"] = seed
	st["mesh_step"] = mesh_step
	st["pay_total"] = pay_total
	st["cache_dir"] = _cache_dir()
	st["npix"] = NPIX
	st["face_grid"] = FACE_GRID
	st["home_n"] = HOME_N
	st["home_half"] = HOME_HALF
	st["home_chunks"] = HOME_CHUNKS
	st["face_chunks"] = FACE_CHUNKS
	st["shard_len"] = BAKE_SHARD_LEN
	st["fcc"] = FCC
	st["lx"] = LX
	st["ly"] = LY
	st["lz"] = LZ
	st["pay"] = PackedByteArray()
	st["abort"] = false
	st["done"] = false
	st["result"] = {}
	st["gen_ms"] = 0.0
	st["color_ms"] = 0.0
	st["png_ms"] = 0.0
	st["load_ms"] = 0.0
	st["worker_ms"] = 0
	return st


func _start_bake() -> void:
	phase = Phase.WORK
	bake_active = true
	bake_stats = {"mode": "baked", "cache": _cache_dir()}
	# AC-0418: the worker-side work is the detached static (the node is
	# out of the worker's frame); the whole pipeline input travels in
	# the bound state.
	_bake_st = _bake_state()
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
	# .bind (the project convention - world.gd _tm_worker_run.bind(skey)):
	# the 4.7 add_task takes no args array. The static holds no object;
	# the state outlives the node (the AC-0418 UAF close).
	Engine.get_singleton("WorkerThreadPool").add_task(SatelliteBakeWorker.single_task.bind(_bake_st, _bake_st["g"]), false)


# AC-0414: the multithreaded bake start (Settings "sat_preload" ON). The
# sharded twin of _start_bake: 28 payload shards (each worker writes ONLY
# its own buffer - the single-writer discipline) STREAMED at the pool
# width (the poller in _bake_main_step_mt enqueues the next shard as
# slots open, at the yield-aware priority), then 12 per-face tasks
# (colour + PNG + read-back + guard + geometry - the row machine,
# arithmetic untouched, with its per-face state in a task-owned
# Dictionary). The main thread (via _bake_main_step_mt) is the only
# writer of the node's guard/_worker_images/_geom: it merges the shards once,
# assembles the face results in face order once, and sets bake_done.
func _start_bake_mt() -> void:
	phase = Phase.WORK
	bake_active = true
	bake_mt = true
	bake_stats = {"mode": "baked", "cache": _cache_dir()}
	# AC-0418: the worker-side work is the detached static (the node is
	# out of every worker's frame); the per-shard / per-face channels
	# ride in the bound state.
	_bake_st = _bake_state()
	var st: Dictionary = _bake_st
	st["shard_bufs"] = []
	st["shard_err"] = []
	st["shard_ms"] = []
	st["face_img"] = []
	st["face_guard"] = []
	st["face_geom"] = []
	st["face_err"] = []
	st["face_ms"] = []
	st["face_png_ms"] = []
	st["face_load_ms"] = []
	guard.clear()
	textures.clear()
	_worker_images = []
	_geom = []
	_hgrid_load = []
	color_face = 0
	bake_consume = 0
	bake_done = false
	bake_result = {}
	bake_worker_ms = 0
	# the static is per-SCRIPT (it survives the node): a re-created body in
	# the same process (world restart / a radius-change window) must not
	# inherit the previous instance's exit flag.
	_mt_exit_aborted = false
	_mt_stage = 1
	_mt_shard_ids = []
	_mt_shard_next = 0
	_mt_shard_inflight_cap = clampi(OS.get_processor_count(), 1, BAKE_SHARDS)
	_mt_face_ids = []
	_mt_face_enq = []
	_mt_gen_wall_ms = 0.0
	_bake_wall_t0 = Time.get_ticks_msec()
	_reset_counters()
	DirAccess.make_dir_recursive_absolute(_cache_dir())
	var pool = Engine.get_singleton("WorkerThreadPool")
	for s in BAKE_SHARDS:
		st["shard_bufs"].append(PackedByteArray())
		st["shard_err"].append("")
		st["shard_ms"].append(0.0)
	# The first batch fills the pool at HIGH (the pre-AC-0414 low lane ran
	# on ONE thread - world.gd:6216 measured - and starved behind
	# streaming); the REST stream through the poller as slots open, at
	# the yield-aware priority (HIGH under the hold, LOW after the late
	# release until the player lands - the bounded-release fix).
	for s in _mt_shard_inflight_cap:
		_mt_shard_ids.append(pool.add_task(SatelliteBakeWorker.shard_task.bind(st, st["g"], s), true))
		_mt_shard_next = _mt_shard_inflight_cap
	for f in 12:
		_mt_face_ids.append(-1)
		_mt_face_enq.append(false)
		st["face_img"].append(null)
		st["face_guard"].append(null)
		st["face_geom"].append(null)
		st["face_err"].append("")
		st["face_ms"].append(0.0)
		st["face_png_ms"].append(0.0)
		st["face_load_ms"].append(0.0)
	_satline("bake: multithreaded start (seed %d) - %d shards x %d records + 12 faces, HIGH priority (the pre-AC-0414 single LOW task ran on one thread - world.gd:6216)" % [seed, BAKE_SHARDS, BAKE_SHARD_LEN])


# AC-0418: _mt_shard_task moved to SatelliteBakeWorker.shard_task (the
# detached worker - same body, the state in a bound argument).


# AC-0414: the main-thread half of the sharded bake (the single writer).
# Stage 1: poll the shards; when all are done, verify and merge them
# into pay (one pre-sized concat in shard order - byte-identical to the
# single worker's append order; the ~201 MB copy is the only added
# main-thread cost, visible in step_ms_max), then open stage 2.
# Stage 2: poll the 12 face tasks, enqueue more up to tail_inflight_cap
# (12 while the loading-window hold is active; 4 after it releases late,
# so streaming keeps its workers - world.gd pushes the cap), and when
# all 12 are done assemble guard/_worker_images/_geom in face order
# (the shared consume loop then runs unchanged) and set bake_done.
func _bake_main_step_mt() -> void:
	var pool = Engine.get_singleton("WorkerThreadPool")
	var st: Dictionary = _bake_st
	if _mt_stage == 1:
		var enq := _mt_shard_next
		var completed := 0
		for s in enq:
			if pool.is_task_completed(_mt_shard_ids[s]):
				completed += 1
		var inflight := enq - completed
		# Stream the next shards as slots open (pool-width in flight).
		# The priority follows bake_yield: HIGH under the hold (the bake
		# owns the cores), LOW after the late release until the player
		# lands (the diamond build is HIGH and must not queue behind the
		# bake's remaining payload - the bounded release, the yield).
		while _mt_shard_next < BAKE_SHARDS and inflight < _mt_shard_inflight_cap:
			# AC-0418: the detached static, the state as the bound arg.
			_mt_shard_ids.append(pool.add_task(SatelliteBakeWorker.shard_task.bind(st, st["g"], _mt_shard_next), not bake_yield))
			_mt_shard_next += 1
			inflight += 1
		if _mt_shard_next < BAKE_SHARDS or completed < BAKE_SHARDS:
			return
		var err := ""
		for s in BAKE_SHARDS:
			if st["shard_err"][s] != "":
				err = "shard %d: %s" % [s, st["shard_err"][s]]
				break
			if st["shard_bufs"][s].size() != BAKE_SHARD_LEN * 1024:
				err = "shard %d payload %d bytes (want %d)" % [s, st["shard_bufs"][s].size(), BAKE_SHARD_LEN * 1024]
				break
		if err != "":
			_fail(err)
			return
		# Godot 4.7.1's PackedByteArray has no replace() — the merge is
		# the deterministic append_array concat in shard order (one
		# reallocation pass; the only added main-thread cost, visible in
		# step_ms_max). The merged payload lands in the state (the face
		# tasks' read-only input - AC-0418).
		st["pay"] = PackedByteArray()
		for s in BAKE_SHARDS:
			st["pay"].append_array(st["shard_bufs"][s])
		if st["pay"].size() != pay_total * 1024:
			_fail("merged payload %d bytes (want %d)" % [st["pay"].size(), pay_total * 1024])
			return
		st["shard_bufs"] = []  # release the per-shard copies
		_gen_ms = 0.0
		for s in BAKE_SHARDS:
			_gen_ms += float(st["shard_ms"][s])
		_mt_gen_wall_ms = float(Time.get_ticks_msec() - _bake_wall_t0)
		_satline("bake: payload done - %d records merged (%.0f ms shard worker-time, %.0f ms wall)" % [pay_total, _gen_ms, _mt_gen_wall_ms])
		_mt_stage = 2
		return
	if _mt_stage == 2:
		var inflight := 0
		var completed := 0
		for i in 12:
			if _mt_face_enq[i]:
				if pool.is_task_completed(_mt_face_ids[i]):
					completed += 1
				else:
					inflight += 1
		var enq_n := 0
		for i in 12:
			if _mt_face_enq[i]:
				continue
			if inflight >= tail_inflight_cap:
				break
			_mt_face_enq[i] = true
			# Yield-aware, like the shards: LOW while the player is still
			# waiting on the ground (bake_yield), HIGH once they have
			# landed (the cap then keeps streaming its 2+ threads).
			# AC-0418: the detached static, the state as the bound arg.
			_mt_face_ids[i] = pool.add_task(SatelliteBakeWorker.face_task.bind(st, i), not bake_yield)
			inflight += 1
			enq_n += 1
		if enq_n > 0:
			_satline("bake: face task(s) enqueued (now in flight %d, cap %d, %s)" % [inflight, tail_inflight_cap, "yielding" if bake_yield else "high"])
		if completed < 12:
			return
		# All 12 faces done - assemble in face order (single writer).
		var ferr := ""
		for i in 12:
			if st["face_err"][i] != "":
				ferr = st["face_err"][i]
				break
		if ferr != "":
			_fail(ferr)
			return
		var ship_msg := SatelliteBakeWorker.ship_faces(st)  # the AWECRAFT_SATELLITE_SHIP report (harness-only env)
		for i in 12:
			guard.append(st["face_guard"][i])
			_worker_images.append(st["face_img"][i])
			_geom.append(st["face_geom"][i])
			_color_ms += float(st["face_ms"][i]) - float(st["face_png_ms"][i])
			_png_ms += float(st["face_png_ms"][i])
			_load_ms += float(st["face_load_ms"][i])
			color_face += 1
		st["pay"] = PackedByteArray()  # 201 MB no longer needed (the faces are coloured + on disk)
		bake_worker_ms = int(Time.get_ticks_msec() - _bake_wall_t0)
		bake_result = {"ok": true, "why": "", "ship": ship_msg}
		bake_done = true
		_satline("bake: all 12 faces done - the consumption takes over (one face per frame)")



# The per-frame driver (world._process). State is read back through the
# public fields.
func process_frame(ppos: Vector3, day_t: float, render_radius: int, fog_pct: float) -> void:
	if bake_active:
		var s0 := Time.get_ticks_usec()
		if phase == Phase.WORK and not bake_done:
			if bake_mt:
				_bake_main_step_mt()  # AC-0414: the sharded poll/merge/assemble
			else:
				_bake_main_step_single()  # AC-0418: poll the single detached task
		else:
			# Once the assembly set bake_done (or past WORK), the shared
			# consume loop in _bake_main_step takes over (one face per
			# frame until _finish_bake).
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
			# AC-0418: the load is the shared worker-side static (the
			# node's _load_png twin moved with the worker).
			img = SatelliteBakeWorker.load_png(_cache_path(lf))
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
		var gd := SatelliteBakeWorker.guard_check(img)  # AC-0418: the shared worker-side static
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


# AC-0418: the OFF path's poll/collect. The single detached task
# (SatelliteBakeWorker.single_task) owns the pipeline in _bake_st and
# sets st["done"] LAST (its writes are final once the pool says the
# task is complete - this collect is the single writer of the instance
# fields, the same ordering the old single-writer contract had:
# bake_done set last). The old _bake_worker wrote the instance directly
# from the pool thread; now the pool thread never touches the node.
func _bake_main_step_single() -> void:
	var st: Dictionary = _bake_st
	if not bool(st.get("done", false)):
		return
	for gd in st.get("guard", []):
		guard.append(gd)
	for img in st.get("worker_images", []):
		_worker_images.append(img)
	for ge in st.get("geom", []):
		_geom.append(ge)
	_gen_ms = float(st.get("gen_ms", 0.0))
	_color_ms = float(st.get("color_ms", 0.0))
	_png_ms = float(st.get("png_ms", 0.0))
	_load_ms = float(st.get("load_ms", 0.0))
	bake_worker_ms = int(st.get("worker_ms", 0))
	bake_result = st.get("result", {})
	bake_done = true


func _tick_view(ppos: Vector3, day_t: float, render_radius: int, fog_pct: float) -> void:
	_last_ppos = ppos  # AC-0384 diagnostic: cached for the _process report
	var h_band: float = (ppos + Vector3(0.0, R, 0.0)).length() - R
	var RB: float = R + float(SEA)
	var ff: float = DayNight.fog_far(render_radius, fog_pct)
	var edge: float = (float(render_radius) + 1.0) * 16.0
	# Derived thresholds (no constants - spec precision (a)):
	#  h_first: the rim's tangent distance d_t(h) = sqrt((R+h)^2 - RB^2)
	#           crosses fog_far - the rim emerges as it passes the fog wall.
	#           AC-0417 keeps this FOG-DERIVED (deviation D1, stated in
	#           tasks/AC-0417/AC-0417-results.html): re-deriving it against
	#           the atmosphere height A (sqrt((R+A)^2 + fog_far^2) - R =
	#           ~1211 m at R24) would put the rim's first appearance ABOVE
	#           the atmosphere top (A = 1200) - a full-opacity rim popping
	#           in past the space transition. h_first gates the body's
	#           visibility (L2388), so it stays on the fog window.
	#  h_full:  AC-0417 - the atmosphere height A (Aero.atmosphere_height,
	#           the ONE home for "the sky is space", env AWECRAFT_ATMO):
	#           "the planet is fully established" and "the sky is space"
	#           land at the SAME altitude (pre-AC-0417: SEA + render_edge
	#           = 526 m vs the AC-0402 sky window's 3200 m end - ~700 m
	#           apart from A). DIAGNOSTIC ONLY (reported by _satline; the
	#           per-fragment op is the real controller - the fog wall
	#           stays render-distance-coupled, the AC-0415 contract).
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
	# AC-0417: h_full re-derived against the atmosphere height A (see the
	# threshold comment above - "fully established" lands with "space").
	var h_full: float = Aero.atmosphere_height()
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
		# AC-0421: the height-based relief switch. Read the boot env once,
		# then the live Settings value (toggling in the menu re-pushes next
		# frame — the cloud_deck/limb_space live-read pattern). u_relief 0.0
		# short-circuits the shader's modulation (the pre-AC-0421 flat path,
		# byte-identical); 1.0 is the conservative baked-lit relief.
		if _relief_env < 0:
			var _re := OS.get_environment("AWECRAFT_RELIEF")
			_relief_env = 0 if _re == "0" else (1 if _re == "1" else -2)
		var relief_on: bool
		if _relief_env == 0:
			relief_on = false
		elif _relief_env == 1:
			relief_on = true
		else:
			relief_on = bool(Settings.values.get("relief_shading", true))
		var u_relief: float = 1.0 if relief_on else 0.0
		# AC-0421: the specular amount. Shipped 0.0 (the satellite LOD must
		# not be reflective — the user's phrase is the spec); AWECRAFT_SPEC=0.5
		# restores the pre-AC-0421 glossy state for the A/B only.
		if _spec_env < 0.0:
			_spec_env = 0.5 if OS.get_environment("AWECRAFT_SPEC") == "0.5" else 0.0
		var u_spec: float = _spec_env
		# AC-0436: the moon (Settings "moonlight", default ON — the boot env
		# AWECRAFT_MOON preloads the Settings value in world.gd, so the live
		# read below already carries it; the relief_shading pattern).
		# u_moon = MOON_L * BODY_MOON_SCALE * night * switch (0.0 at day/OFF
		# -> the shader's + 0.0 term is bit-identical); u_moon_dir =
		# direction TO the moon = DayNight.sun_direction (the sun's
		# antipode — the same vector the u_sun push negates).
		# BODY_MOON_SCALE: this body is a LIT material — its ALBEDO is
		# multiplied by the engine ambient (AMBIENT_TINT ×
		# ambient_energy 0.25 ≈ 0.20 at night, main.gd) ON TOP of the
		# shader's own 0.18 night floor (a triple product the unshaded
		# chunks don't have), so the one-source MOON_L (0.25, tuned for
		# the unshaded consumers) would leave the moonlit hemisphere
		# sub-threshold (measured against the ACES pipeline: ~1/255).
		# 8× lifts the moonlit grass to ~50/255 (vs 3.0/255 pre-AC-0436,
		# measured) while the antipode stays dark — the moonlit
		# hemisphere reads as a world.
		const BODY_MOON_SCALE := 8.0
		var moon_on := bool(Settings.values.get("moonlight", true))
		var u_moon: float = DayNight.MOON_L * BODY_MOON_SCALE * (1.0 - day) if moon_on else 0.0
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
			# AC-0436: the moon (see the block above).
			m.set_shader_parameter("u_moon", u_moon)
			m.set_shader_parameter("u_moon_dir", DayNight.sun_direction(day_t))
			# AC-0421: the relief + the specular (both A/B-able; the relief
			# is the look switch, the specular is the reflectivity defect fix).
			m.set_shader_parameter("u_relief", u_relief)
			m.set_shader_parameter("u_spec", u_spec)
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
	# AC-0418: the raw read is the shared worker-side static.
	img = SatelliteBakeWorker.load_png(pth)
	if img != null:
		return {"img": img, "via": "raw-fallback"}
	return {"img": null, "via": "import-no-image"}




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
	# AC-0418: the build is the SINGLE worker-side implementation (pure
	# SphereMath - SatelliteBakeWorker.geom_for_face_local; the full
	# AC-0411 winding note lives there). The cache (self-append in
	# face order, main-thread only) is unchanged.
	var stg := {"R": R, "SEA": SEA, "mesh_step": mesh_step, "npix": NPIX}
	var ge := SatelliteBakeWorker.geom_for_face_local(stg, f, hgrid)
	if f == _geom.size():
		_geom.append(ge)
	return ge


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
	# AC-0411: the AC-0242 sRGB round-trip (the baked face bytes are
	# sRGB-companded but the upload is a linear-format texture; the
	# shader pre-decodes the terrain term so the Forward+ output encode
	# round-trips the bake - the daylit disc's pale wash). The renderer
	# method is constant per run: build-time push, the house pattern
	# (main.gd pushes the same value to the other sRGB-domain materials
	# at build time).
	sm.set_shader_parameter("u_srgb_pre", Aero.srgb_pre())
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
		# AC-0414: which bake path ran (true = the sharded HIGH-priority
		# pipeline; false = the pre-AC-0414 single LOW task), and the
		# per-stage walls of the sharded path (the single-task path
		# leaves the arrays empty).
		"mt": bake_mt,
		"shards": BAKE_SHARDS if bake_mt else 0,
		"gen_wall_ms": int(_mt_gen_wall_ms) if bake_mt else 0,
		"face_wall_ms": int(_bake_st.get("face_ms", []).max()) if bake_mt and _bake_st.get("face_ms", []).size() == 12 else 0,
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


# AC-0414: the loading screen's progress line (world.gd pushes it while
# the bake-before-load hold is active). Main-thread only.
func bake_progress_line() -> String:
	if phase != Phase.WORK:
		return "done"
	if not bake_mt:
		return "baking (single thread - the pre-AC-0414 path)"
	var pool = Engine.get_singleton("WorkerThreadPool")
	if _mt_stage == 1:
		var n := 0
		for tid in _mt_shard_ids:
			if pool.is_task_completed(tid):
				n += 1
		return "payload %d/%d shards (%d of %d records)" % [n, BAKE_SHARDS, n * BAKE_SHARD_LEN, pay_total]
	if _mt_stage == 2:
		# AC-0418: the face channels live in the bake state.
		var c := 0
		for i in 12:
			if _bake_st["face_img"][i] != null or _bake_st["face_err"][i] != "":
				c += 1
		return "face %d/12" % c
	return "starting"


# AC-0414: the probe arm's clean-quit handle (harness only - the game
# never aborts: the bake either finishes or the world is gone with it).
# The in-flight tasks observe bake_abort between records / face slices
# and wind down within a bounded time, so the process can quit without
# racing the worker (the pre-AC-0414 shutdown race the satellite arm
# documents: an abandoned worker surfaces spurious CowData lines).
func abort_bake() -> void:
	# AC-0418: the flag lives in the bake state (the worker reads it from
	# there - no instance access in the worker frame).
	_bake_st["abort"] = true


# AC-0414: true when every enqueued sharded task has settled (the probe
# arm's clean-quit precondition - no worker may still be running when
# the process exits, or it races the shutdown into spurious lines).
func mt_settled() -> bool:
	if not bake_mt:
		return bake_done
	var pool = Engine.get_singleton("WorkerThreadPool")
	for tid in _mt_shard_ids:
		if not pool.is_task_completed(tid):
			return false
	for i in 12:
		if _mt_face_enq[i] and not pool.is_task_completed(_mt_face_ids[i]):
			return false
	return true


func _fail(why: String) -> void:
	bake_active = false
	phase = Phase.FAILED
	visible = false
	# The bake is OVER (with a failure) - the consume step has nothing to
	# consume. The pre-AC-0414 single-task path set this on its abort
	# wind-down (the probe arms bound-wait on it); the sharded path's
	# _fail sites (shard merge error, face error) must agree, or a
	# probe that aborts mid-bake waits its full frame cap for a flag
	# that never comes (measured: a 100 s wasted wait on this box).
	bake_done = true
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
	# AC-0414: the rebake rides the switch too - the arm's
	# AWECRAFT_SATELLITE_REBAKE=1 pixel compare must prove the path the
	# GAME will use (ON: the sharded pipeline vs the shipped PNGs; OFF:
	# the old single-task path, byte-identical as before).
	if bool(Settings.values.get("sat_preload", true)):
		_start_bake_mt()
	else:
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
