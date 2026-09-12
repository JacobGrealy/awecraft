extends Node3D

const ChunkScript = preload("res://world/chunk.gd")
const DropScript = preload("res://entities/drop.gd")
const BananaScript = preload("res://entities/banana.gd")  # AC-0040 bouncy-banana
const ChunkIO = preload("res://core/chunk_io.gd")  # AC-0155
const LoadingScreen = preload("res://ui/loading_screen.gd")  # AC-0178

const LIGHT_NEIGHBOR := 1
const FLUSH_FRAME_BUDGET_MS := 40
const FLUSH_MAX_PER_FRAME := 2
# AC-0126: the edit (post-break) flush staggers remeshes 1/frame on the
# AC-0107 worker path; FLUSH_MAX_PER_FRAME stays for _drain_tex_refresh.
const EDIT_FLUSH_MAX_PER_FRAME := 1
# AC-0178: loading-screen bypass caps (active ONLY while loading_active):
# the drain's per-frame unit/time budgets, the in-flight pool caps, and the
# flush remesh caps. Steady state keeps every legacy constant.
const LOAD_DRAIN_UNITS := 1000000
# Per-frame drain time budget while loading: bounded so the frame yields and
# the polls (the handoffs) keep running — an unbounded block starved the
# worker pools between dispatch waves (measured: 2.6 s frames, ~80% pool idle).
const LOAD_DRAIN_BUDGET_MS := 300
# TG in-flight cap while loading (low-priority share = 3 of 6 pool threads;
# 24 deep = ~8 waves of queue, the pool never sees an empty queue).
const LOAD_TG_CAP := 24
# TM in-flight cap while loading: 64 = ~11 waves of 6-thread work — the pool
# stays saturated across the main thread's poll/dispatch cadence.
const LOAD_TM_CAP := 64
# AC-0178: TM handoff batch cap per frame while loading. Each handoff's
# _eff_landed face-block refresh is ~70 ms avg (0.4-1.0 s tail on the first
# landing wave); a full batch blocked the main thread 1-2.5 s and let the
# pool queue drain to idle between dispatch waves (~40% pool idle measured).
# 6/frame keeps the frame bounded; the inflight gate oscillates at the
# handoff rate so the pool queue stays deep.
const LOAD_TM_HANDOFF := 6
# AC-0219: global per-frame cap on steady-state STREAMING mesh handoffs —
# the drain hands off at most this many non-edit meshes per process frame,
# for every move size and band (not just the small-move trickle). The
# ahead-band fill spreads over frames instead of bursting every ready mesh
# into one frame (each landing = apply_accs + collision + the _eff_landed
# face-block refresh on the main thread — a burst tanks the frame). The
# loading window keeps its own LOAD_TM_HANDOFF pace; edit-lane (epool)
# handoffs keep landing as before (a user edit must not sit behind the
# streaming cap).
# AC-0224: tuned 1 -> 3 (a small burst per frame, Minecraft-style "a few
# per tick with a frame budget", not a hard 1): 1/frame is too slow for
# 4x-50x flight — a recenter's ahead ring (up to ~30 ready meshes) took a
# full second of frames to land at 1/frame, so the ahead band filled well
# behind the player. At 3/frame the same ring lands in ~10 frames and the
# forward edge shows while still moving. The frame stays bounded: 3
# landings (each apply_accs + collision + scoped face-block refresh) is a
# fraction of the 64-mesh recenter burst this cap exists to break up. The
# burst is the tuning knob — AC-0225: it is now the Settings
# "chunks_per_frame" value (the Options "Chunk meshes per frame" slider,
# 1..100) and the drain cap reads it every process frame; AWECRAFT_TM_HO
# preloads that same setting at boot (clamped 1..100, no save) so the
# harness can A/B it.
const STREAM_TM_HANDOFF_PER_FRAME := 3
# AC-0229: dynamic per-frame streaming budget — the AC-0225 slider value is
# the BASE burst; the effective cap is base x speed_factor x radius_factor,
# clamped to the slider range (1-100). Higher when moving fast or at a
# large render, lower when still:
#  - speed_factor: the player's horizontal speed (m/s) vs the WALK
#    reference (player.gd WALK = 4.3). Still (< 0.5 m/s) -> 0.5; walking
#    (4.3) -> 1.0 (the AC-0225 behavior is a no-op at the reference
#    point, so the standing R16-walking p95 gate is untouched); 50x
#    flight (215 m/s) saturates the 12.0 max.
#  - radius_factor: the ahead ring widens ~linearly with R (~14 new
#    chunks per chunk moved at R16, ~32 at R50). R/16 clamped to
#    [1.0, 2.0] — R16 and below keep 1.0 (every r4 harness arm is
#    unchanged), R32+ saturates at 2.0.
#  Combined reference points (base = 3 default): R16 still -> 2, R16 walk
#  -> 3 (AC-0225), R16 50x fly -> 36, R50 still -> 3 (the AC-0224/0227
#  R50-drain profile is untouched), R50 walk -> 6, R50 50x fly -> 72.
const DYN_SPEED_WALK := 4.3
const DYN_SPEED_FACTOR_STILL := 0.5
const DYN_SPEED_FACTOR_MAX := 12.0
const DYN_RADIUS_REF := 16
const DYN_RADIUS_FACTOR_MAX := 2.0
const LOAD_POOL_CAP := 24
# AC-0178: flush/tex remesh caps while loading — 6 (was 16): each dispatch
# is ~45 ms of main-thread strip work, 16/frame = 0.7 s of one frame.
const LOAD_FLUSH_MAX_PER_FRAME := 6
const LOAD_SAVE_PER_FRAME := 16
# AC-0158: Bedrock Realms simulation clock — 20 Hz game tick (0.05 s).
# Replaces the 5 Hz fluid Timer: fluids run inside the game tick, and the
# random-tick pass (1 per 16x16x16 subchunk) keys off the tick index.
const TICK_INTERVAL := 0.05
const TICK_MAX_CATCHUP := 4
const SUBCHUNKS_PER_COLUMN := 24  # Data.HEIGHT 384 / 16
# AC-0158: Bedrock region/rate contracts for the 20 Hz model (the redstone
# and mob-spawn FEATURE work is deferred — predicates + rate constants only,
# see tasks/AC-0158 results). Redstone dust delay = 1 tick. Mob-spawn
# region = circle 24-44 (unit per caller, squared-distance test) ∪ the
# (n-1) diamond of the Simulate radius (band0_r).
const REDSTONE_DUST_DELAY_TICKS := 1
const MOB_SPAWN_CIRCLE_MIN := 24
const MOB_SPAWN_CIRCLE_MAX := 44
const FLUID_DIRS := [
	[1, 0],
	[-1, 0],
	[0, 1],
	[0, -1],
]

const BUILD_FAST_US := 15000
const DRAIN_FRAME_BUDGET_US := 30000
const DRAIN_MS_DEFAULT := 30
const REC_SLICE_BUDGET_MS := 8
const REC_UNITS_PER_FRAME := 2048
# AC-0231 fps-tuning: the steady-state DRAIN UNIT pace (one unit = one gen
# enqueue or one mesh dispatch) is WALL-CLOCK — the chunk generation/build
# pace is identical at 30 fps and 60 fps (the player must never out-fly
# generation by having a low frame rate; a slow machine lowers render
# distance). At 60 fps these reproduce the old per-frame budgets exactly
# (fast = 2 units/frame = 1 per 8.3 ms, slow = 1/frame = 1 per 16.7 ms);
# at 30 fps the accumulator grows 2x/frame and the per-frame cap carries
# the same wall-clock rate. Startup (12/frame) and the loading window keep
# their own per-frame budgets (one-shot spawn contract / AC-0178 pacing).
const DRAIN_UNIT_PACE_MS := 8.0        # fast: last dispatch < BUILD_FAST_US (125/s wall clock)
const DRAIN_UNIT_PACE_SLOW_MS := 16.0  # slow: expensive dispatch (old 1/frame governor, 62.5/s)
const DRAIN_UNITS_FRAME_CAP := 4       # per-frame unit cap (hitch spike guard; at 30 fps the
                                       # acc banks 2x/frame and needs 4/frame to hold the pace)
                                       # AC-0237 phase 2: retune TESTED (cap 6) and REVERTED -
                                       # owed stragglers returned (owed_n 0 -> 4) with no fill
                                       # gain (build_ms -1.4 percent, p95 flat); see TASKS AC-0237
                                       # comment id 3.
const DRAIN_DT_CLAMP_MS := 100.0       # clamp the wall-clock frame sample (pause/hitch)
const DRAIN_WIN_PACE_MS := 250.0       # window grows one bucket per 250 ms (was 15 frames
                                       # at the 60 fps reference = the same wall-clock rate)
# AC-0109 margin (manual lane only, AC-0212). Meters — a slab is hidden only
# once fully past the frustum expanded by this margin, so show/hide transitions
# happen off-screen (no pop-in).
# AC-0212: the manual per-frame pass is now OFF by default — the engine's
# automatic per-instance frustum culling of every MeshInstance3D (render server,
# zero script cost, exact AABB-vs-frustum, no margin) is the default cull. A
# slab instance crossing the frustum boundary enters/leaves exactly at the view
# edge — that is normal rendering, not a pop-in (the spin probe's
# transitions==0 gate measures on-screen flicker, which stays 0: each chunk's
# visible arc at r4 is ~90° ≫ the 8-step (24°) flicker window). The manual
# pass (this margin, slab-granular) is kept intact behind the toggle for A/B:
#   AWECRAFT_FRUSTUM=manual|1|on  -> the AC-0109 per-frame pass (legacy default)
#   AWECRAFT_FRUSTUM=engine|0|off|"" -> engine cull (NEW DEFAULT)
#   legacy AWECRAFT_FRUSTUM_CULL=0 still disables the manual pass when
#   AWECRAFT_FRUSTUM is unset; AWECRAFT_ONLY (probe-only visibility filter)
#   always wins (the manual pass defers, as at AC-0109).
const FRUSTUM_CULL_MARGIN := 32.0
# AC-0231: the AC-0181 LOD_HYS_* hysteresis constants are GONE with band 2
# (the coarse 32-scale LOD) — every meshed band is full-fidelity; the far
# LOD is the separate low-res placeholder (no per-chunk LOD state at all).

# AC-0143 M3 keying: the chunks dict is (face, cx, cz)-qualified.
#   faces 0,1 (+Y halves, home pair) = the flat home world: key "%d,%d",
#     1m columns; streaming/recenter byte-identical to pre-M3. Sphere
#     mapping covers |x|,|z| <= R (face 0 = x >= 0, face 1 = x < 0).
#   faces 2-11 = sparse on-demand data chunks: key "%d:%d:%d" (face,cx,cz)
#     over the 1024-cell SphereMath grid (chunk = 16x16 cells); data level
#     only in P1a (no meshing/lighting, AC-0144+).
# Position->key single resolver: key_for_sphere_pos() (world_to_face).
# P1a: flat get/set_block stay the home pair (player on the flat home face).
var render_radius := 4
var fluid_tick_radius := 14
# AC-0152 Bedrock Realms bands: band 0 = taxicab diamond <= band0_r (full
# 16x16x16, TICKS, collision), band 1 = taxicab <= band1_r (FULL 16x16x16
# mesh, no tick, no collision — same builder path as band 0), band 3 =
# collar (diamond band1+1 outside the circle) ∪ circle ring (points outside
# the circle touching it within 8-neighbors): data-only, never meshed.
# Harness-overridable: AWECRAFT_BAND0/BAND1. AC-0160: the band-2 heightmap
# impostor was removed (user decision); AC-0181: band 2 became the coarse
# 32-scale LOD; AC-0231: band 2 (coarse/uv_scale) is GONE — every meshed
# band is full-fidelity and the far LOD is the separate per-slab low-res
# placeholder (see the AC-0231 block below: per-slab fog boxes on landing
# + the per-slab 4x4x4 textured low with repeating UVs).
var band0_r := 4
# AC-0263: the HIGH band's outer edge (taxi chunks) — where the MED LOD
# begins. HIGH = [0, medium_start_r) builds full-res per-slab (the tier-0
# ball's columns first, in the dedicated section); the avg-LOD wave owns
# [medium_start_r, render_radius). This is the world-gen boundary that
# band0_r used to be: band0_r (the sim distance) no longer controls world
# generation — it only gates mob/fluid simulation (collision band 0, the
# data tier-1 priority square, mob spawn). Settings "medium_start"
# (must be > sim distance); harness override AWECRAFT_MEDIUM_START.
var medium_start_r := 8
var band1_r := 96
var collision_enabled := true
var chunks := {}
var chunk_keys := {}
var edits := {}
var light_dirty := {}
var light_pending: Array = []
var light_pending_set := {}
var flush_active := false
var perf_flush_frames := 0
var perf_max_frame_ms := 0
var perf_single_build_ms := 0
# AC-0126 edit-path counters (probe-first: pure counters, wired in the
# batched edit flush; zero behavior change until the flush change lands).
var perf_edit_dispatches := 0
var perf_edit_defers := 0
var perf_edit_syncs := 0
var perf_edit_light_passes := 0
# AC-0233: the dirtyQueue — edited chunks append (with the dirty slab
# closure) and drain FIRST, 1 per process frame, ahead of the streaming
# queue work, so edits show immediately. Each entry = {"key", "si0", "si1"}.
var dirty_queue: Array = []
var dirty_set := {}
# AC-0187: last full light dict (mask included) per edited chunk, stashed
# from the eff cache BEFORE set_block's eviction. A stale-but-current light
# lets the scoped worker build skip the whole-chunk light recompute; the
# stored-form equality check at dispatch drops the entry when the chunk was
# re-lit since the edit (the light wave already remeshed it).
var _edit_stale_eff := {}
var perf_edit_front_scoped := 0
var perf_edit_front_full := 0
# AC-0187: count of scoped edit builds dispatched but not yet handed off.
# While > 0 the main thread YIELDS its heavy streaming work (far-queue
# drain, light flush, tex refresh, non-edit handoffs) so the edit handoff
# lands on a short frame instead of waiting behind a 300 ms drain burst.
var edit_inflight_count := 0
# AC-0187 probe hook: the handoff stamps the first mesh landing of the
# probe's chunk after an edit (edit -> hole-visible wall time). Empty key =
# probe idle; the check is one string compare per handoff.
var _editprobe_key := ""
var _editprobe_t0_usec := 0
var _editprobe_ms := -1.0
var _editprobe_wms := 0
var _editprobe_kind := ""
var _editprobe_drop := 0
# AC-0040 bouncy-banana: the hanging B_BANANA fruit cells awaiting the
# 10-block fall roll. Key "x,y,z" (flat world cell) -> [cx, cz] (the owning
# flat chunk, for eviction cleanup). Face-planet chunks (AC-0143) get the
# banana trees visually but never register fruit (the player can't reach
# them). The roll plucks a fruit (set_block 0) and spawns a RigidBody3D
# (BananaScript) that bounces until rest, then the drop-magnet interact
# pickup delivers item 126 (eat = health + stamina + gorilla SFX).
var _banana_fruits := {}
var _banana_roll_t := 0.0
var _banana_plucked := 0
var _banana_spawned := 0
var _editprobe_dnbs := 0
var _editprobe_dstrips := 0
var _editprobe_ph := []
var _editprobe_dq := 0
var _editprobe_nq := 0
var _editprobe_prime := false
var _editprobe_handoff_at := 0
var _editprobe_submit_at := 0
var _editprobe_done_ms := 0
var _editprobe_prime_flag := false
var _editprobe_ns := []
var _editprobe_phet := []
var perf_build_units := 0
var perf_drain_frames := 0
var perf_max_drain_ms := 0
var perf_gen_ms := 0
var perf_build_ms := 0
var perf_read_sync_gen := 0
var perf_read_sync_gen_ms := 0.0
var perf_create_sync_gen := 0
# AC-0216: chunks enqueued to threadgen with the offscreen-interior lazy
# skip flag (the C++ side counts the columns actually skipped via
# AweGen.skip_cols_total).
var perf_gen_skip_enq := 0
# AC-0218: neighbor-dirty diagnostics (pure counters; the R16 arm reports
# per-phase deltas — "dirty count" evidence for the border-compare change).
# ld_marks = cells newly marked light_dirty by _mark_light_around (the 3x3
# edit ring); e2_marks = built-neighbor re-enqueues by _eff_landed (the
# data-landed E2 wave); e2_first_marks/e2_first_skips = the first-landing
# (old_eff empty) border-compare verdicts; retrigger = light_pending adds by
# the _tm_retrigger drop path; e2_side_* = the per-side frame-gate verdicts
# (steady-state landings).
var perf_lightdirty_marks := 0
var perf_e2_marks := 0
var perf_e2_first_marks := 0
var perf_e2_first_skips := 0
var perf_lightpend_retrigger := 0
var perf_e2_side_changed := 0
var perf_e2_side_unchanged := 0
# AC-0155: full-chunk persistence — origin + counters for the chunkio probe.
var disk_reads := 0
var disk_read_ms := 0.0
var gen_count := 0
var gen_ms_total := 0.0
var chunk_origin := {}
var _save_queue: Array = []
var _gen_last_disk := false
# AC-0208: no-fallback evidence (the C++ series is the ONLY path now).
# The C++ counters must grow in any real world; the GDScript sentinels
# (gd_*) count calls into the pure GDScript kernels that SURVIVE solely as
# the harness A/B-probe references (stripsprobe/pullprobe) — the game must
# never touch them (the nofallback arm asserts they stay 0).
var mesh_cpp_builds := 0
var gen_cpp_works := 0
var strips_cpp_calls := 0
var gd_strips_calls := 0
# AC-0164: threaded column I/O on the threadgen pool (the per-tid slot +
# stale-drop handoff pattern, _tg_slots/_tm_slots). The main thread only
# enqueues (evict save, data-landing read) and polls (io_poll); encode,
# decode, and FileAccess all run inside the worker. Pending keys are
# checked at every data-landing site so a load in flight is never
# re-enqueued for generation and never built early.
var io_pool = null
var _io_read_inflight: Array = []
var _io_read_keys: Dictionary = {}
var _io_write_inflight: Array = []
var _io_write_keys: Dictionary = {}
var _io_slots: Dictionary = {}
var _io_enq := 0
var _io_dedup := 0
var _io_wdedup := 0
var _io_drops := 0
var _io_fails := 0
var _io_write_n := 0
var _io_main_read_ms := 0.0
var _io_main_write_ms := 0.0
# AC-0175: region compaction state. _io_compacting maps region path ->
# start ms; saves for a compacting region re-queue until the worker's tmp
# file is renamed into place (one main-thread rename per compaction).
var _io_compacting: Dictionary = {}
var _io_compact_inflight: Array = []
var _io_compact_n := 0
var fluid_tick_samples: Array = []
var fluid_dirty := {}
var fluid_sim_enabled := true
# AC-0158: 20 Hz game-tick state (see TICK_INTERVAL above). tick_index is
# the deterministic seed for the random-tick sequence (world seed + index).
var game_tick_enabled := true
var tick_index := 0
var _tick_acc := 0.0
var game_tick_samples: Array = []
var fluid_tick_count := 0
var random_tick_total := 0
var random_tick_map := {}
var random_tick_log := false
var random_tick_seq: Array = []
var _rt_c1 := 0
var _rt_c2 := 0
var _rt_c3 := 0
var band_buckets: Array = []
var dq_b := 0
var dq_i := 0
var mq_b := 0
var mq_i := 0
var queue_size := 0
var queued_keys := {}
# AC-0222: queued BUILD entries (data_only=false), kept in lockstep with
# band_buckets at every mutation site (_enqueue_build, _remove_entry,
# _drop_queued, _convert_data_to_build, _strip_candidate_builds; recomputed
# at the recenter merge finalization). The depth cap check is O(1) against
# this; a verifying scan resets any drift (see _cap_queue_depth).
var _build_q_n := 0
# AC-0160: key -> band-bucket index for O(1) removal in _remove_entry (the old
# full-queue scan ran once per consumed mesh unit and dominated the drain at
# r50). Rebuilt on recenter; kept in lockstep at every mutation site.
var _qb := {}
# AC-0160: windowed drain. _drain_win_b = max bucket index the drain's pool
# scans admit (spawn-fast = b1_eff+2, grows one bucket per DRAIN_WIN_PACE_MS
# in the trickle); _drain_win_b < 0 = unset.
var _drain_win_b := -1
var _drain_win_acc := 0  # AC-0231 fps-tuning: WALL-CLOCK ms since last growth
# AC-0231 fps-tuning: the drain's wall-clock pacing state (see the
# DRAIN_UNIT_PACE_MS const) — the chunk build pace is frame-rate independent.
var _drain_last_t := 0       # wall ms of the previous drain frame (dt sample)
var _drain_acc_ms := 0.0     # unit-pace accumulator (wall ms banked)
# AC-0217 + AC-0233/AC-0250: the pool/score debounce. The drain's scored
# picks (build / forward-lead / data) re-ran _collect_pool (up to
# PICK_POOL_CAP entries) + scoring every frame even when the player stands
# still and the world is idle. A pick is a pure function of (queue
# membership + eligibility, maxb, _spawn_fast, the recenter center, the
# sim radius, the in-flight depths) — AC-0233/AC-0250: the 3-tier order
# depends only on the column + sim radius (the look no longer matters at
# all), so px/pz left the key and moving or turning within a column no
# longer rescans. _pool_ver bumps at every mutation of that state (every
# band_buckets mutation site — the same lockstep list as the AC-0222
# _build_q_n counter — plus the data-landing choke points); when the
# quantized key and the version are unchanged, the last pool/score result is
# served and the rescan + rescore is skipped entirely. A column cross, a
# sim-radius change, or a pool change changes the key -> a fresh scan
# (the debounced rewrite of the waiting parts). The candidate re-validation
# on a hit is the safety net: a stale cached candidate re-scans instead of
# being served.
var _pool_ver := 0
var perf_pool_hits := 0
var perf_pool_misses := 0
var _pool_b: Array = []    # [key, e, c, s, pe] last build-pass pick
var _pool_fb: Array = []   # [key, e, c, s, pe] last forward-lead pick
var _pool_data: Array = [] # [key, e, null, s, pe] last data-pass pick

# AC-0233: the amortized queue-rewrite slice — entries re-stamped per drain
# step (a full R50 7845-entry queue re-stamps in ~4 frames; R16 in one).
const RESCORE_PER_FRAME := 2048
# AC-0233: the debounced-recenter coverage limit (L1 chunks from the walked
# center). A debounced recenter stands only while the standing rebuild
# (in-flight or last-finished) still covers the new center. Past this the
# walked circle is mostly behind the player: its entries evict (farthest
# first) and the new circle ahead has no queue entries at all — the drain
# starves once the pre-warmed line is exhausted (R16 50x flight: 36 chunks
# in 2 s, the spawn walk at column 0 covers nothing at column 36). Past the
# limit the recenter escalates to a full rebuild (one R16 walk is a single
# 8 ms frame; even a chained walk every few chunks is a small fraction of
# the frame budget).
const REBUILD_COVER_L1 := 4
var _rescore_ver := 0
var _rescore_due := false
var perf_rescore_events := 0
var perf_rescore_stamps := 0
var perf_rescore_ms := 0.0

func _pool_touch() -> void:
	_pool_ver += 1

func _pool_key(maxb: int) -> String:
	# AC-0233/AC-0250: the tiered pick is a pure function of (pool state +
	# drain window + spawn-fast + recenter center + sim radius) — the look
	# no longer affects the order at all (AC-0250 removed the look bias),
	# so moving OR turning within a column does not change the tier order
	# and px/pz left the key. A key hit means no rescan: the waiting parts
	# are rewritten only on a column cross (pcx/pcz), a sim-radius change,
	# or a pool change.
	return "%d_%d_%d_%d_%d_%d" % [
		_pool_ver,
		maxb, 1 if _spawn_fast else 0,
		last_pcx, last_pcz,
		band0_r,  # AC-0239: the sim radius is the tier-1 boundary
	]

# AC-0233 3-tier priority of a waiting entry (dx,dz = offset from the
# player's column); AC-0239: tier 1 is the SIMULATION RADIUS (Chebyshev
# <= band0_r = the sim_dist slider, the same square the collision band 0
# and the fluid sim use) instead of the 8 ring-1 neighbors - the whole
# surround fills before the far field, so a sideways walk never shows
# load-in next to the player; AC-0250 removed the look-direction bias:
# 0 = under (built first), 1 = sim radius, 2 = everything else (ordered
# by taxi distance, look-independent).
func _tier_of(dx: int, dz: int) -> int:
	if dx == 0 and dz == 0:
		return 0
	if maxi(absi(dx), absi(dz)) <= band0_r:
		return 1
	return 2

# AC-0257: the PLAYER SLAB (slab units of the player's world Y) — the layer
# rank's origin. recenter carries the Y across slab crossings; between
# crossings the slab is constant.
var last_wy := 0.0

func _player_slab() -> int:
	return int(floorf(last_wy / 16.0))

# AC-0257: the Y-LAYER rank of slab si — the bake order around the player's
# slab: rank 0 = the player's slab, then y-1, y+1, y-2, y+2, ... (the
# layers nearest the player's altitude build before the deep ones).
func _layer_rank_of(si: int) -> int:
	var d := si - _player_slab()
	if d == 0:
		return 0
	if d < 0:
		return -2 * d - 1
	return 2 * d

# AC-0257: the column's BEST pending slab — the pending slab with the
# smallest LAYER rank (nearest the player's Y); -1 = nothing pending.
# Rank-ordered probe (0, -1, +1, -2, +2, ...) so the first pending hit is
# the answer; bounded by the slab count, allocation-free (the pick runs
# it per candidate per scan).
func _entry_best_pending(c: Node3D) -> int:
	if c == null or c.data.is_empty():
		return -1
	var pys := _player_slab()
	var sn: int = c.data.size()
	var tier := _lod_tier_of(int(c.cx) - last_pcx, int(c.cz) - last_pcz)
	for r in range(sn * 2):
		var dy: int
		if r == 0:
			dy = 0
		elif r % 2 == 1:
			dy = -(r + 1) / 2
		else:
			dy = r / 2
		var si := pys + dy
		if si < 0 or si >= sn or c.data[si] == null:
			continue
		if c.has_low_si(si):
			# a LOW slab is pending only when stale (edited after the low,
			# or built at a different band tier).
			if c.low_stamps.get(si, []) == c.stamp() and c.low_tiers.get(si, -1) == tier:
				continue
		elif FOG_WAVE_ON:
			# fog on: pending = fogged and not terminal-marked.
			if not c.has_fog_si(si) or int(c.low_failed.get(si, -1)) == int(c.data_gen):
				continue
		elif int(c.low_failed.get(si, -1)) == int(c.data_gen):
			continue  # terminal-fog mark (sampled all-air at this data_gen)
		return si
	return -1

# AC-0262: single-slab pendingness (the probe's inner check for ONE si) —
# factored out so the probe cache can re-validate a cached si cheaply
# (~5 dict lookups) instead of re-running the 32-probe sweep.
func _low_slab_pending_at(c: Node3D, si: int, tier: int) -> bool:
	if si < 0 or si >= c.data.size() or c.data[si] == null:
		return false
	if c.has_low_si(si):
		# a LOW slab is pending only when stale (edited after the low,
		# or built at a different band tier).
		return not (c.low_stamps.get(si, []) == c.stamp() and c.low_tiers.get(si, -1) == tier)
	elif FOG_WAVE_ON:
		# fog on: pending = fogged and not terminal-marked.
		return c.has_fog_si(si) and int(c.low_failed.get(si, -1)) != int(c.data_gen)
	else:
		# terminal-fog mark (sampled all-air at this data_gen).
		return int(c.low_failed.get(si, -1)) != int(c.data_gen)

# AC-0262: per-chunk cache of the _entry_best_pending result (the wprof
# storm hunt: the 32-probe sweep is ~13 us/visit and dominated the slab
# wave's per-pick scan — 126-213 ms/frame of LOW_PICK at R30). The result
# only changes when one of the four fingerprint parts changes (slab data
# via [data_gen, fl_gen], the player's Y slab the probe is relative to,
# the live band tier) or the cached slab itself completes — so a hit is
# 4 int compares + one cheap single-slab re-check, and a -1 verdict stays
# valid until the fingerprint moves (completions remove pendingness, they
# never add a closer pending slab; only a data landing adds slabs, and
# that bumps data_gen). Low/fog state changes that do NOT bump the
# fingerprint (an attach, a drop, an air mark, a fog flip) must erase the
# entry — every such site calls _low_probe_invalidate.
var _low_probe_cache: Dictionary = {}

func _low_probe_invalidate(c: Node3D) -> void:
	_low_probe_cache.erase(_key(int(c.cx), int(c.cz)))

func _entry_best_pending_cached(c: Node3D) -> int:
	var key := _key(int(c.cx), int(c.cz))
	var f: Array = [int(c.data_gen), int(c.fl_gen), _player_slab(),
		_lod_tier_of(int(c.cx) - last_pcx, int(c.cz) - last_pcz)]
	var ck = _low_probe_cache.get(key, null)
	if ck != null:
		var cf: Array = ck["f"]
		if cf[0] == f[0] and cf[1] == f[1] and cf[2] == f[2] and cf[3] == f[3]:
			var si0: int = int(ck["si"])
			if si0 < 0:
				return -1
			if _low_slab_pending_at(c, si0, int(f[3])):
				return si0  # still pending -> still the best (see above)
		_low_probe_cache.erase(key)
	if _low_probe_cache.size() > 8000:
		_low_probe_cache.clear()  # eviction safety (bounded working set)
	var si := _entry_best_pending(c)
	_low_probe_cache[key] = {"si": si, "f": f}
	return si

# AC-0263: the per-slab HIGH pending probe — the full-res build lane's
# "what does this column still owe". A slab is pending-high while it
# holds data (data[si] != null — ungenerated null slabs are not work yet),
# it sits at or below the top slab (above the top is all air and never
# meshed), and its completion stamp does not match the current data_gen
# (a data landing — gen or edit — re-pends the slab). Same fan walk as
# the low probe: the player's Y slab first, then down/up — the (layer,
# taxi) bake order's layer. -1 = the column owes nothing (high-complete;
# an all-air column's probe is -1 too, so mesh_built can flip).
func _hslab_best_pending(c: Node3D) -> int:
	if c == null or c.data.is_empty() or int(c.top) < 0:
		return -1
	var pys := _player_slab()
	var lim: int = mini(int(c.top) >> 4, c.data.size() - 1)
	for r in range(c.data.size() * 2):
		var dy: int
		if r == 0:
			dy = 0
		elif r % 2 == 1:
			dy = -(r + 1) / 2
		else:
			dy = r / 2
		var si := pys + dy
		if si < 0 or si > lim:
			continue
		if c.data[si] == null:
			continue
		if int(c.high_stamps.get(si, -1)) == int(c.data_gen):
			continue  # done at this data
		return si
	return -1

# AC-0262/AC-0263: the high probe's per-chunk cache — the same fingerprint
# shape as the low probe's ([data_gen, fl_gen, player-Y slab, live tier]);
# a hit is 4 int compares + one single-slab stamp re-check. A cached si
# stays valid until it LANDS (re-check fails -> rescan finds the next) or
# the fingerprint moves (a data landing bumps data_gen); a cached -1
# stays valid until the fingerprint moves (completions remove pendingness,
# they never add a closer pending slab). Landing sites call
# _hslab_probe_invalidate defensively (the re-check already covers them).
var _hslab_probe_cache: Dictionary = {}

func _hslab_probe_invalidate(c: Node3D) -> void:
	_hslab_probe_cache.erase(_key(int(c.cx), int(c.cz)))

func _hslab_best_pending_cached(c: Node3D) -> int:
	var key := _key(int(c.cx), int(c.cz))
	var f: Array = [int(c.data_gen), int(c.fl_gen), _player_slab(),
		_lod_tier_of(int(c.cx) - last_pcx, int(c.cz) - last_pcz)]
	var ck = _hslab_probe_cache.get(key, null)
	if ck != null:
		var cf: Array = ck["f"]
		if cf[0] == f[0] and cf[1] == f[1] and cf[2] == f[2] and cf[3] == f[3]:
			var si0: int = int(ck["si"])
			if si0 < 0:
				return -1
			if si0 < c.data.size() and c.data[si0] != null \
					and int(c.high_stamps.get(si0, -1)) != int(c.data_gen):
				return si0  # still pending -> still the best (see above)
		_hslab_probe_cache.erase(key)
	if _hslab_probe_cache.size() > 8000:
		_hslab_probe_cache.clear()  # eviction safety (bounded working set)
	var si := _hslab_best_pending(c)
	_hslab_probe_cache[key] = {"si": si, "f": f}
	return si

# AC-0263: the TIER-0 SECTION gate — true when every tier-0 column (the
# Chebyshev ball around the player column) owes no high slab: the section
# is complete and the wave (med/low) may start. A no-DATA tier-0 column
# is NOT drained — its build starts the moment its data lands, and the
# section (not the wave) owns it (the wave waits the ~500 ms the data
# lane needs; the startup burst makes this a no-op at spawn). The ball is
# tiny (tier0_radius 0 = 1 column, the max 8 = 289) and the per-chunk
# probe cache keeps the live walk near-free.
func _tier0_section_drained() -> bool:
	for dx in range(-tier0_r, tier0_r + 1):
		for dz in range(-tier0_r, tier0_r + 1):
			var c = chunks.get(_key(last_pcx + dx, last_pcz + dz))
			if c == null or c.data.is_empty():
				return false
			if _hslab_best_pending_cached(c) >= 0:
				return false
	return true

# AC-0257: the (layer, taxi) BAKE SCORE — the order the drain picks and
# the low lanes walk: the Y-layer of the entry's best pending slab first
# (a no-data/gen entry is layer 0 — the player's slab is the first the
# column owes), taxi (|dx|+|dz|) within the layer. The live layer is
# derived from the chunk's pending state per pick (a completed slab moves
# the best slab outward; there is no stamp to go stale).
func _grid_score(e: Dictionary) -> float:
	var dx := int(e["cx"]) - last_pcx
	var dz := int(e["cz"]) - last_pcz
	var layer := 0
	var c = chunks.get(e["key"])
	# AC-0263: the pending probe is per-lane — the HIGH band (the per-slab
	# full-res builds: taxi < medium_start_r, plus the tier-0 ball, which
	# outruns the edge in its corners) probes the HIGH completion stamps;
	# the wave band [medium_start_r, render_radius) probes the low/fog
	# state (the AC-0262 cached probe).
	var in_high := c != null and (absi(dx) + absi(dz) < medium_start_r or _is_tier0_col(dx, dz))
	if c != null and not c.data.is_empty():
		var si: int = _hslab_best_pending_cached(c) if in_high else _entry_best_pending_cached(c)
		if si >= 0:
			layer = _layer_rank_of(si)
	var s := float(layer) * 10000.0 + float(absi(dx) + absi(dz))
	# AC-0263: the TIER-0 SECTION — the ball's slabs build in their own
	# phase (fanned from the player's Y), fully complete, before ANY ring
	# slab (high or wave) starts: the prefix puts every tier-0 slab below
	# every non-tier-0 slab at equal (layer, taxi).
	if _is_tier0_col(dx, dz):
		s -= 1e10
	return s

# AC-0257: the AC-0233 _tier_score ((sim-tier, taxi) pick order) is gone —
# replaced by _grid_score (the (layer, taxi) bake order). _tier_of / the
# tier stamps survive: the tier-2 high order gate (build handoff) and the
# low task's dispatch-tier check still classify by sim tier.

# AC-0233: stamp a waiting entry with its current tier + taxi rank (the
# stored tier order the AC-0231 low-LOD scan walks; the live pick computes
# the tier itself, so a stale stamp can only lag, never mislead).
func _tier_stamp(e: Dictionary) -> void:
	var dx := int(e["cx"]) - last_pcx
	var dz := int(e["cz"]) - last_pcz
	e["tier"] = _tier_of(dx, dz)
	e["rank"] = absi(dx) + absi(dz)
	e["_rv"] = _rescore_ver

# AC-0233/AC-0250: rewrite all waiting parts — the queue is speculative
# and rewritable; a recenter column cross or a sim-radius change kicks the
# pass (amortized, RESCORE_PER_FRAME stamps per drain step). The
# rewrite only re-stamps queued entries — it NEVER touches the ThreadGen
# pool4 / ThreadMesh pool6 in-flight work.
# AC-0239: the sim radius (band0_r) is part of the tier order - a slider
# move re-stamps the queue (Settings.apply_sim_distance / apply_world
# call this; mirrors the apply_render_distance kick path).
func note_sim_distance() -> void:
	_rescore_kick()

# AC-0263: the "mid LOD distance" (Settings "medium_start") changed — the
# HIGH band's outer edge moved. Entries crossing the edge change their
# band tier, so re-stamp the queue's stamps and invalidate the wave's
# cached none-verdicts (the live tier is recomputed at probe time, so the
# boundary itself needs no stamp — the kick covers the ordering).
func note_medium_start() -> void:
	medium_start_r = maxi(0, int(Settings.values.get("medium_start", 8)))
	_low_none_key = ""
	_low_slab_none_key = ""
	_low_inr_invalidate()
	_rescore_kick()

func _rescore_kick() -> void:
	_rescore_ver += 1
	_rescore_due = true
	perf_rescore_events += 1

func _rescore_step() -> void:
	var _wpt := Time.get_ticks_usec()  # AC-0251 RESCORE sub-stage
	if not _rescore_due:
		_wprof_add(WP_RESCORE, Time.get_ticks_usec() - _wpt)
		return
	var t0 := Time.get_ticks_usec()
	var n := 0
	for b in range(band_buckets.size()):
		var arr: Array = band_buckets[b]
		for i in range(arr.size()):
			var e: Dictionary = arr[i]
			if int(e.get("_rv", 0)) == _rescore_ver:
				continue
			_tier_stamp(e)
			n += 1
			if n >= RESCORE_PER_FRAME:
				perf_rescore_stamps += n
				perf_rescore_ms += (Time.get_ticks_usec() - t0) / 1000.0
				_wprof_add(WP_RESCORE, Time.get_ticks_usec() - _wpt)
				return
	perf_rescore_stamps += n
	_rescore_due = false
	perf_rescore_ms += (Time.get_ticks_usec() - t0) / 1000.0
	_wprof_add(WP_RESCORE, Time.get_ticks_usec() - _wpt)

# --- AC-0231 rewrite (fix3): the far-LOD low-res placeholder (the AC-0233
# consumer). A SEPARATE lane: it never touches the ThreadGen pool4 /
# ThreadMesh pool6.
# GLOBAL WAVES — all fog -> all low -> all high, ACROSS ALL COLUMNS (the
# per-column sequential fill — column 1 fully fog->low->high, then column
# 2 — is gone):
# WAVE 1 — FOG (data landing, _low_fog_for): every candidate far column
# with no mesh gets ONE pre-baked 16x16x16 fog-tinted box INSTANCE per
# NON-AIR slab at the slab's Y (the slab BOTTOM: si*16, so the box spans
# si*16..si*16+16) — the sparse null check on c.data (null = air) — on
# EVERY data landing (sync gen / burst / threadgen handoff / disk load /
# materialize). So every column with data is fogged IMMEDIATELY, before
# any low of it exists: all fog first, across all columns. SEPARATE
# instances (a shared MultiMesh over the ONE pre-baked box — NOT merged
# into one column mesh), extremely cheap (just instancing the same
# pre-baked mesh). Tier 0 (the column under the player) skips the wave
# straight to high, so you never fall through.
# WAVE 2 — LOW (per-frame _low_step): TWO WALL-CLOCK paced lanes (the
# same build pace at 30-60 fps): (2a) the in-r pre-low — INSIDE-circle
# pending chunks fully lowered in the AC-0233 (tier, taxi) order, the
# same order the high builds land, so the low frontier leads the high
# frontier; (2b) the far global SLAB wave — OUTSIDE the circle, the
# SMALLEST slab index FIRST across all columns (all si=0 slabs first,
# then all si=1, ... — ties by rank), never one whole column before the
# next. Each pending slab gets its band-tier AVERAGE-COLOR placeholder
# (AC-0252: MED 8x8x8 inside the low-start boundary, LOW 4x4x4 outside
# it) — and the grid sample + emit of it run on the TM WORKER POOL (the
# C++ low_emit_avg on a value-copied slab column: ZERO generation on the
# main thread). The main thread only dispatches (a ~20 KB slab copy +
# task enqueue) and, when the result lands, does the scene-tree attach +
# the per-slab bookkeeping (the _low_handoff); a slab whose DATA is null
# has nothing to emit — its air bookkeeping runs inline (_low_air_slab).
# The TEXTURED 4x4x4 emit (64 coarse cells of 4x4x4 blocks, the 2D
# greedy merge of same-type neighbors) stays in the tree, DORMANT with
# the band split (the A/B reference). TEXTURE MAPPING (fix3): blocks
# WITH a merged-atlas strip (solid, non-cutout) use REPEATING UVs — 31px
# per world block, the texture repeats 4x across each 4-block quad (the
# qwrite_merged convention — NOT stretched, and the 512x128 strip always
# covers the span); blocks WITHOUT a strip (non-solid/cross/cutout: water,
# leaves, flowers, torch, lava, banana) sample exactly ONE 32px tile (31px
# span) from the original atlas rect — the high mesh's plain-branch
# convention (mesh.cpp) — because a repeating span from a plain rect walks
# 3+ tiles past the block's own tile into its atlas neighbors (the "wrong
# texture mapping" the user saw on the far leaves). The low REPLACES the
# fog per slab at its Y (the fog instance for that slab is freed, the low
# replaces it).
# WAVE 3 — HIGH (AC-0233 tiers): dirty edited first (1/frame), then
# streaming (rewriting on debounced move) in tier order 0 (under you,
# already high) -> sim radius (by taxi distance) -> the rest (by taxi
# distance); separate tiered picks for gen vs mesh. For each non-air slab
# that has low/fog, the full high at 16x16x16 full greedy (ThreadGen pool
# 4 / ThreadMesh pool 6) REPLACES low and fog per slab at its Y when
# ready; the idle catch-up below dispatches low-holding columns as the
# heavy pipeline drains.
# KEEP RULES: never downgrade built high at its Y to low (keep high until
# freed per cand_since >= 2 after queue work); low and fog only for
# never-built slabs. low_downgrade_n must stay 0.
const LOW_GRID := 4          # coarse cells per axis (4x4x4 = 64 cells/slab)
const LOW_CELL_BLOCKS := 4   # world blocks per coarse cell (4*4 = 16 = 1 slab)
# AC-0252: the MED tier — 8x8x8 samples per 16x16x16 slab; each sample is a
# 2x2x2 = 8 real-block volume (the user's "each cube is 4 of the actual
# cubes" reads as 2 blocks per axis = 8 cells — see the AC-0252 report).
# Both avg tiers read the FULL sample volume (the whole 4096-block slab) —
# a sample is AIR when MORE THAN HALF its volume is air (>=5 of 8 for med,
# >=33 of 64 for low) and its per-face color = the average of the cached
# per-block-face colors over its NON-AIR blocks (vertex colors, no UVs).
const MED_GRID := 8
const MED_CELL_BLOCKS := 2
# the textured-low pass builds ONE candidate per frame (the rescan after
# a build is the cost; 1/frame keeps ahead of the data landings, which
# arrive at the TG rate — the far fill is data-limited, not build-limited).
# AC-0231 fix3: the WAVE 2 global slab wave paces — a few slabs per frame
# (the user-approved "one low per frame, or a few"). One slab build is ~0.3-
# 0.7 ms main-thread (3 C++ row_bytes + the 4x4x4 greedy emit); 4/frame is
# ~1-3 ms — half of what the old per-COLUMN build (all 8 slabs in one
# frame, ~2-4 ms) cost, so the far fill keeps its pace while the ordering
# goes global.
# AC-0231 fps-tuning: ALL low-path pacing is WALL-CLOCK (not per-frame) —
# "frame" is the render/main-loop frame (there is no separate logic tick),
# and the game must build at the same wall-clock pace at 30 fps as at
# 60 fps (a slow machine lowers render distance; it must never be able to
# out-fly the build pipeline by having a low frame rate).
const LOW_WAVE_PACE_MS := 3.5      # one far slab per 3.5 ms wall clock (~36 chunks/s,
                                   # just above the ~33/s TG data-landing rate)
const LOW_WAVE_FRAME_CAP := 8      # per-frame catch-up cap (8 x 0.7 ms = 5.6 ms max work;
                                   # a stall never turns into a frame-killing catch-up)
const LOW_UPGRADE_PER_FRAME := 1   # per-frame idle low->high dispatch (dispatch is cheap;
                                   # the work runs on the TM workers)
const LOW_IDLE_GRACE_FRAMES := 10  # consecutive no-work drain frames before upgrades
const LOW_SCAN_CAP := 2048         # hard entry-visit cap for the low pick scan
# AC-0231 in-r pre-low: the INSIDE-circle low lane (separate from the far
# global slab wave). The tier-ordered pick (the AC-0233 (tier, taxi)
# lexicographic score — the SAME order the TM high dispatch uses) fully
# lowers one pending in-r chunk at a time. The budget is a FRACTION of the
# measured frame wall time (clamped): a low build costs ~0.3-0.7 ms
# main-thread per slab, so the pass lowers 1-2+ chunks per frame —
# ~60-120+ low chunks/s wall clock vs the ~30 high-completions/s of the
# 6-thread TM pool (100-300 ms each). The low frontier therefore stays
# AHEAD of the high frontier in the same order at ANY frame rate (the
# whole point: low is what renders fast enough to lead — the in-r visible
# sequence is low-res textured -> high-res, never empty -> high). Tier 0
# (under the player) is high only. The far wave (smallest si) owns
# everything OUTSIDE the circle; the two lanes are disjoint.
const LOW_INR_BUDGET_FRAC := 0.35  # share of the frame wall time the in-r pass may spend
const LOW_INR_BUDGET_MIN_MS := 2.0
const LOW_INR_BUDGET_MAX_MS := 8.0
# AC-0231 high/low order gate: while ANY in-r chunk still has a pending
# low (fog not yet lowered / a stale low to rebuild), the tier >= 2 HIGH
# dispatch is HELD (the drain's build pass and the WAVE 3 catch-up both
# check the _low_inr_drained flag) — only the tier 0 + 1 chunks (under the
# player + the sim radius) keep building high. The freed budget is
# REDIRECTED to the in-r low pass (the BUSY budget below: the gate is not
# "high waits" — it is "that time goes to the low, so the low goes
# faster"). The flag flips to drained only after the pending set stayed
# empty for LOW_INR_STABLE_MS wall clock (no flap between data landings —
# under continuous streaming the gate stays closed: the low covers the
# circle, and the tier >= 2 high fills in after the player stops).
const LOW_INR_BUSY_FRAC := 0.5     # budget share while the gate is closed (low is the frontier)
const LOW_INR_BUSY_MAX_MS := 12.0
const LOW_INR_STABLE_MS := 200.0   # continuous-drain window before the gate opens
const LOW_INR_SCAN_CAP := 16384    # the in-r scan visits up to this many entries (r50's
const LOW_TASK_CAP := 64           # AC-0236 part 2 / AC-0250: max in-flight low EMIT
                                   # tasks (64 x ~20 KB slab copies = ~1.3 MB; a
                                   # saturated pool leaves the slab PENDING — the
                                   # in-r pass or the far wave re-picks it next frame;
                                   # AC-0250 removed the sync main-thread fallback)
const LOW_POLL_BUDGET_MS := 4.0    # AC-0236 part 2: the per-frame wall-clock cap on
                                   # low HANDOFFS (the attach cost, ~0.2 ms each)
                                   # whole circle+ring fits; a capped scan leaves the
                                   # gate CLOSED rather than proving drained)
# AC-0261: the med/low band split. The visible LOD zones (taxi): HIGH
# [0, band0_r) (the build lane), MED (8x8x8) [band0_r, low_start_r), LOW
# (4x4x4) [low_start_r, render_radius); nothing renders past the (taxi)
# render distance. low_start_r = the effective boundary (recomputed by
# apply_low_start; clamped to [band0_r, render_radius] — between the
# simulation distance and the render distance).
var low_start_r := 27
var _low_fog_mat: StandardMaterial3D = null
var _low_fog_mesh: ArrayMesh = null  # pre-baked 16x16x16 box (shared by every MultiMesh)
var _low_fog_color := Color(0.55, 0.68, 0.85)
var _low_tl: Dictionary = {}      # id*256+fi -> Vector2 (the tile top-left in the ms canvas)
var _drain_units_last := 0        # units the last _drain_build_queue dispatched (the idle gate)
var _low_none_key := ""           # (pool_ver, pcx, pcz) of the last no-candidate scan
var _low_idle_frames := 0         # consecutive heavy-pipeline-idle frames
var low_fog_boxes_n := 0          # fog box slab instances currently live
var low_fog_chunks_n := 0         # chunks currently holding >= 1 fog slab (live)
var low_built_n := 0              # per-slab textured-low builds (cumulative)
var low_rebuilds_n := 0           # per-slab stale (edited) low rebuilds
var low_upgrades_n := 0           # high landings that replaced a placeholder (the catch-up)
var low_downgrade_n := 0          # MUST stay 0 (keep-high — high never downgrades to low)
# AC-0231 order-gate evidence: perf_high_gate_holds_n = tier >= 2 high
# dispatches HELD by the gate (it was doing its job); perf_high_before_low_n
# = tier >= 2 HIGH HANDOFFS that LANDED while in-r lows were still pending
# (gate leakage — only tasks already in flight at the moment the gate
# re-closed can land this way; the dispatch itself is gated).
var perf_high_gate_holds_n := 0
var perf_high_before_low_n := 0
var perf_high_before_low_firstbuild_n := 0
var perf_gate_reclose_n := 0
# the max slab-local textured-low AABB height ever built (<= 16 by
# construction: each low mesh is ONE slab, slab-local 0..16).
var low_max_h := 0.0
# AC-0236 part 2: the low-lane threading (the EMIT rides the TM pool via
# the C++ AweMesh.low_emit; the node attach stays on the main thread).
# low_enqueue_n = slabs dispatched to a worker; low_emit_cpp = C++ emits
# completed on the pool; low_handoff_n = main-thread attaches;
# low_drop_stale_n = dropped results (data changed mid-flight / chunk
# gone — the slab is still PENDING in the chunk state, so the in-r pass
# or the far wave re-picks it next frame — no re-queue logic needed);
# low_sync_fallbacks_n = ALWAYS 0 since AC-0250 (the main-thread sync
# fallback is gone — a saturated pool leaves the slab PENDING instead);
# the variable survives as a regression gate: any increment is a bug.
var low_enqueue_n := 0
var low_emit_cpp := 0
var low_handoff_n := 0
var low_drop_stale_n := 0
var low_sync_fallbacks_n := 0
# AC-0257 (stale-LOD cache-and-keep, absorbs AC-0256):
# low_skip_stale_n = PRE-START early-outs (the wanted tier moved while the
# task was queued — the worker never started the emit); low_cache_kept_n =
# finished meshes stored in the per-slab cache at a tier-mismatch handoff
# (the slab stays pending against the live tier; the visible mesh keeps
# showing); low_cache_hit_n = flip-back attaches served from the cache
# (no worker round-trip).
var low_skip_stale_n := 0
var low_cache_kept_n := 0
var low_cache_hit_n := 0
# the in-flight low tasks (polled by _low_poll — SEPARATE from
# threadmesh_inflight: the high lane keeps its own stream_ho_cap pace and
# the low lane attaches every frame, one attach is ~0.2 ms).
var _low_tasks: Array = []
var _low_task_keys := {}  # "cx,cz:si" -> true (the dispatch dedupe)
var _low_ms_snap: Dictionary = {}
var _low_ms_snap_dirty := true

# =====================================================================
# AC-0257: the AC-0234 vertical window (black caps, kept masks, the
# owed-superset rebuilds, the scoped re-entry regens) is GONE — every
# slab in the horizontal radius is wanted at its band LOD; the layered
# bake (P3) only orders them. The (off) fog wave stays behind its flag.
# =====================================================================
const FOG_WAVE_ON := false

# AC-0231 rewrite: the pre-baked 16x16x16 fog box — ONE shared ArrayMesh
# (24 verts, 6 faces, CCW outwards — the same quad-winding the chunk meshes
# use), instanced per non-air slab by each far chunk's MultiMesh.
func _low_fog_bake() -> void:
	_low_fog_mat = StandardMaterial3D.new()
	_low_fog_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_low_fog_mat.cull_mode = BaseMaterial3D.CULL_BACK
	_low_fog_mat.albedo_color = _low_fog_color
	var faces: Array = [
		[Vector3(0, 0, 0), Vector3(0, 0, 16), Vector3(0, 16, 16), Vector3(0, 16, 0)],
		[Vector3(16, 0, 16), Vector3(16, 0, 0), Vector3(16, 16, 0), Vector3(16, 16, 16)],
		[Vector3(0, 16, 16), Vector3(16, 16, 16), Vector3(16, 16, 0), Vector3(0, 16, 0)],
		[Vector3(0, 0, 0), Vector3(16, 0, 0), Vector3(16, 0, 16), Vector3(0, 0, 16)],
		[Vector3(0, 0, 16), Vector3(16, 0, 16), Vector3(16, 16, 16), Vector3(0, 16, 16)],
		[Vector3(0, 0, 0), Vector3(0, 16, 0), Vector3(16, 16, 0), Vector3(16, 0, 0)],
	]
	var av := PackedVector3Array()
	for f in faces:
		for v in f:
			av.append(v)
	var ai := PackedInt32Array()
	for j in range(0, 24, 4):
		ai.append(j)
		ai.append(j + 2)
		ai.append(j + 1)
		ai.append(j)
		ai.append(j + 3)
		ai.append(j + 2)
	_low_fog_mesh = ArrayMesh.new()
	_low_fog_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _low_surface(av, ai))
	# AC-0234 (user 2026-09-07): the CAPS reuse the FOG material + box mesh
	# directly (the solid-black cap material is gone) — a capped slab reads
	# as a fog box at every distance, void-fill, no lighting.

# ============================================================================
# AC-0247: slab pools (per World) — the mesh-instance / MultiMesh / column
# / slab-buffer recycling. Memory-lifetime change ONLY: attach order,
# transforms, meshes, materials, visibility, sorting, stamps, and the
# streaming in/out timing are identical; the per-slab create/free churn
# (the waves sweeping out) is replaced by checkout/checkin.
# AC-0248: prewarmed to the STREAMING DEMAND, not a fixed small count —
# _pool_prewarm at ready (the default render radius) + _pool_top_up on the
# recenter that follows any render-radius change (the spawn recenter, the
# Options slider, the harness arms). Sizing = ~2 recenter RINGS of columns
# at the current render radius (the AC-0239 ring system: one ring = the
# columns that ENTER the circle when the center moves one chunk = 2R,
# _pool_ring_cols) + their slab demand in the MI pool (slabs-per-column x
# columns) + their fog+cap MM pairs. Memory-warming ONLY: nothing visible
# differs; grow-on-demand stays the safety net past the prewarm.
# ============================================================================
const POOL_PREWARM_RINGS := 2   # AC-0248: ~1-2 rings of columns (the ticket)
const POOL_MM_PER_COL := 2      # AC-0248: fog + cap (one MultiMesh each per column)
# AC-0248: the floor sizes — a tiny-radius run (or a radius whose ring
# target is smaller) still keeps the AC-0247 warm minimum.
const POOL_MI_MIN := 32
const POOL_MM_MIN := 8
const POOL_COL_MIN := 16

var _mi_pool: Array = []     # pooled MeshInstance3D (high + low slab instances)
var _mm_pool: Array = []     # pooled [MultiMeshInstance3D, MultiMesh] (fog + cap)
var _col_pool: Array = []    # pooled column nodes (detached, fresh state)
# AC-0248: the POOL GROW COUNTERS — on-demand (fresh-allocation) checkouts,
# i.e. the checkouts the prewarm did not cover. This is the ticket's
# evidence: with the prewarm in place a sustained fly-forward shows ~0
# grows after the initial burst (steady state recycles — the r+2 evict
# check-in feeds the ring check-out); pre-AC-0248 the first burst grew
# everything.
var perf_pool_mi_grows_n := 0
var perf_pool_mm_grows_n := 0
var perf_pool_col_grows_n := 0
# AC-0248: the one-time prewarm cost (ready + every top-up, ms).
var perf_pool_prewarm_ms := 0.0
# AC-0248: the cached targets + the radius they were computed for — the
# recenter top-up check is three int compares in the steady state.
var _pool_target_r := -1
var _pool_target_mi := 0
var _pool_target_mm := 0
var _pool_target_col := 0

# AC-0247 slab-buffer note: the 4096-cell slab cell buffers (the "i"/"p"
# PackedByteArrays) are KEPT ON ALLOC. The dispatch value-copies
# (mc.slab_copy at the TM/edit/low sites) allocate them INSIDE the C++
# slab_copy (no C++ changes allowed), the slab materialization
# (slab_set / palettize_flat) and the gen handoff (generate_resl) are
# C++-side too, and the only GDScript alternative — a per-byte copy into
# pooled buffers — measured 98 us/4096 B (a ~230 us/col copy) vs the
# C++ slab_copy's ~9 us/col: a net CPU regression that fights the
# "main stays smooth" goal. The lifetime WAS proven (the dispatch entry
# is the last consumer; a return-at-handoff is race-free) — this is a
# perf-driven keep-on-alloc, see the AC-0247 report.


# AC-0248: the columns that ENTER the render circle when the center moves
# one chunk (the recenter RING of the AC-0239 ring system): the lattice
# points inside the shifted circle (dx-1, dz) that the old circle did not
# hold. Closed-form-exact by count (no fudge factor): exactly 2R — the
# leading edge of the circle (8 at R4, 32 at R16, 100 at R50; circle_count
# itself is ~797 at R16 / ~7845 at R50).
func _pool_ring_cols(r: int) -> int:
	var n := 0
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			var nx := dx - 1
			if nx * nx + dz * dz > r * r:
				continue
			if dx * dx + dz * dz > r * r:
				n += 1
	return n


# AC-0248: the MI instances one column of the home world carries in
# steady state — the slabs that hold a MeshInstance3D: everything BELOW
# the sea ((SEA+15)/16 = 8 slabs at SEA 126) + the surface slab (+1) +
# the fluid/flora headroom (+1). The vertical window (AC-0234) keeps
# [pys-4, top] UNION the tower's 3x3 terrain span; at the sea-level
# surface band only the terrain slabs at/below the player carry a high or
# low instance (the kept slabs above it are air). ~10 at the current
# Data.SEA — the "actual slabs/column" of the streaming ring.
func _pool_mi_per_col() -> int:
	return (Data.SEA + 15) / 16 + 2


# AC-0248: the (mi, mm, col) pool targets for a render radius — POOL_
# PREWARM_RINGS recenter rings of columns + their slab demand (MI) +
# their fog+cap MM pairs, floored by the AC-0247 minimums.
func _pool_targets_for(r: int) -> Array:
	var cols := maxi(POOL_PREWARM_RINGS * _pool_ring_cols(r), POOL_COL_MIN)
	return [
		maxi(cols * _pool_mi_per_col(), POOL_MI_MIN),
		maxi(cols * POOL_MM_PER_COL, POOL_MM_MIN),
		cols,
	]


# AC-0248: grow the pools (NEVER shrink — the pools may already be past
# the target from streaming growth) up to the target for the CURRENT
# render radius. Called from _pool_prewarm (ready) and from recenter
# (the radius may have moved: the spawn recenter, the Options slider,
# the harness arms — all of them change render_radius and recenter).
func _pool_top_up() -> void:
	if _pool_target_r != render_radius:
		var t := _pool_targets_for(render_radius)
		_pool_target_mi = int(t[0])
		_pool_target_mm = int(t[1])
		_pool_target_col = int(t[2])
		_pool_target_r = render_radius
	if _mi_pool.size() >= _pool_target_mi and _mm_pool.size() >= _pool_target_mm \
			and _col_pool.size() >= _pool_target_col:
		return
	var t0 := Time.get_ticks_usec()
	while _mi_pool.size() < _pool_target_mi:
		_mi_pool.append(MeshInstance3D.new())
	while _mm_pool.size() < _pool_target_mm:
		var mm := MultiMesh.new()
		mm.mesh = _low_fog_mesh
		mm.transform_format = MultiMesh.TRANSFORM_3D
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = _low_fog_mat
		_mm_pool.append([mmi, mm])
	while _col_pool.size() < _pool_target_col:
		_col_pool.append(ChunkScript.new())
	perf_pool_prewarm_ms += (Time.get_ticks_usec() - t0) / 1000.0
	# AC-0248: env-gated verification hook (AWECRAFT_POOL_DEBUG=1) — the
	# one-time prewarm cost at any radius (the r16 arm reports the R16
	# number in its RESULT; this prints the live one for interactive /
	# R50 runs).
	if OS.get_environment("AWECRAFT_POOL_DEBUG") == "1":
		print("POOLTOPUP r=%d mi=%d mm=%d col=%d total_ms=%.1f" % [render_radius, _mi_pool.size(), _mm_pool.size(), _col_pool.size(), perf_pool_prewarm_ms])


# AC-0247 (the small fixed prewarm) -> AC-0248 (ring-sized): prewarm on
# World ready — the world starts at the default render radius and the
# first recenter tops up to the live radius (a new-world boot applies
# Settings.render_dist AFTER ready, then the spawn recenter runs).
func _pool_prewarm() -> void:
	_pool_top_up()


func pool_sizes() -> Dictionary:
	# AC-0248: the harness-readable pool depths (the "pool sizes at end"
	# of the r16 arm's pool evidence).
	return {"mi": _mi_pool.size(), "mm": _mm_pool.size(), "col": _col_pool.size()}


func _mi_checkout() -> MeshInstance3D:
	var mi: MeshInstance3D = null
	while not _mi_pool.is_empty():
		var m = _mi_pool.pop_back()
		if is_instance_valid(m):
			mi = m
			break
	if mi == null:
		mi = MeshInstance3D.new()
		perf_pool_mi_grows_n += 1  # AC-0248: on-demand growth past the prewarm
	# Reset to the fresh-instance defaults; the per-use values (mesh,
	# position, material_override, cast_shadow) are set by the caller right
	# after, exactly as on a fresh node. A pooled instance may carry a
	# previous life's fluid cast_shadow=0 / material_override / slab Y.
	mi.mesh = null
	mi.material_override = null
	mi.cast_shadow = 1
	mi.visible = true
	mi.transform = Transform3D.IDENTITY
	return mi


func _mi_checkin(mi: MeshInstance3D) -> void:
	if mi == null or not is_instance_valid(mi):
		return
	# Drop the mesh REFERENCE only — the per-slab ArrayMesh data frees by
	# refcount (mesh-DATA pooling is out of scope for AC-0247; it would
	# need the C++ emit side). The shared pre-baked fog box never rides a
	# MeshInstance3D (fog/cap are MultiMesh entries), so nothing shared
	# can be freed by this.
	mi.mesh = null
	if mi.get_parent() != null:
		mi.get_parent().remove_child(mi)
	_mi_pool.append(mi)


func _mm_checkout() -> Array:
	# [MultiMeshInstance3D, MultiMesh] — the fog/cap placeholder holder
	# (ONE per chunk; the MultiMesh holds the per-slab box instances).
	while not _mm_pool.is_empty():
		var pair = _mm_pool.pop_back()
		if is_instance_valid(pair[0]):
			var mmi: MultiMeshInstance3D = pair[0]
			var mm: MultiMesh = pair[1]
			mmi.visible = true
			mmi.transform = Transform3D.IDENTITY
			mmi.material_override = _low_fog_mat  # fog AND cap wear it
			mm.mesh = _low_fog_mesh  # shared pre-baked box — never freed
			mm.instance_count = 0
			return pair
	var mm := MultiMesh.new()
	mm.mesh = _low_fog_mesh
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = _low_fog_mat
	perf_pool_mm_grows_n += 1  # AC-0248: on-demand growth past the prewarm
	return [mmi, mm]


func _mm_checkin(mmi: Node3D) -> void:
	if mmi == null or not is_instance_valid(mmi):
		return
	var mm: MultiMesh = mmi.multimesh
	if mm != null:
		# Zero the live instances; the pooled MultiMesh keeps its
		# capacity buffer (the per-instance realloc that pooling removes).
		# The shared mesh reference stays put (never freed).
		mm.instance_count = 0
	if mmi.get_parent() != null:
		mmi.get_parent().remove_child(mmi)
	_mm_pool.append([mmi, mm])


func _column_checkout() -> Node3D:
	# The pooled column arrives in fresh state (_pool_reset ran at
	# checkin). The caller sets the identity (cx/cz/face/position + the
	# "cx,cz" key + band/collision_enabled + init_slabs + the col_gen
	# bump) exactly as on a fresh ChunkScript.new(). The instance_id is
	# fixed per object — the logical identity a task must validate against
	# is col_gen (bumped by every checkout).
	while not _col_pool.is_empty():
		var c = _col_pool.pop_back()
		if is_instance_valid(c):
			return c
	var c := ChunkScript.new()
	perf_pool_col_grows_n += 1  # AC-0248: on-demand growth past the prewarm
	return c


func _col_checkin(c: Node3D) -> void:
	# The streaming-out (r+2) / face-FIFO free path. The placeholders
	# (fog/low/cap) were already returned to the MultiMesh pool by
	# _lod_free_all before this runs; here the remaining child kinds are
	# handled: the HIGH slab MeshInstance3Ds (mesh/fluid/flora) go to the
	# MeshInstance3D pool, the out-of-scope nodes (the StaticBody3D
	# collision bodies + the OccluderInstance3D) keep the legacy free.
	# Walking the children (not just the Slab refs) also sweeps any
	# untracked instance left by the build_mesh data-empty degenerate
	# path (it nulls the Slab refs without freeing the nodes — a
	# pre-existing quirk the pool must not carry into its next life).
	for ch in c.get_children():
		if ch is MeshInstance3D:
			_mi_checkin(ch)
		elif ch is StaticBody3D:
			ch.queue_free()
		elif ch is OccluderInstance3D:
			ch.queue_free()
	if c.get_parent() != null:
		c.get_parent().remove_child(c)
	c._pool_reset()
	_col_pool.append(c)


# AC-0247: the pool teardown (world._exit_tree, LAST — the exit drain may
# have checked instances back in via handoffs). Pooled nodes are detached
# orphans by the pool invariant (checkin removes them from the tree
# first), so immediate free() is safe and the prewarm entries do not
# leak at exit. The MM pool's MultiMesh entries are refcounted — dropping
# the MMI releases them.
func _pool_free_all() -> void:
	for mi in _mi_pool:
		if mi != null and is_instance_valid(mi):
			mi.free()
	_mi_pool = []
	for pair in _mm_pool:
		var mmi = pair[0]
		if mmi != null and is_instance_valid(mmi):
			mmi.free()
	_mm_pool = []
	for c in _col_pool:
		if c != null and is_instance_valid(c):
			c.free()
	_col_pool = []


# AC-0231 rewrite: FOG WAVE — the immediate placeholder for a far column
# that just landed data. ONE pre-baked 16x16x16 fog box INSTANCE per
# NON-AIR slab (the sparse null check: c.data[si] == null = air), at the
# slab's Y (slab bottom si*16) — SEPARATE instances (a shared MultiMesh
# over the ONE pre-baked box, NOT merged into one column mesh); extremely
# cheap. Runs on every data landing for a queued column with no mesh,
# before low starts. TIER 0 (the column under the player) skips the wave
# straight to high — never fall through. CANDIDATES (the r+1 far band)
# are the wave's primary target — the c.candidate flag must NOT exclude
# a column from fog/low (AC-0231 fix: the far band was empty-then-high).
# A slab already low/high never re-fogs.
func _low_fog_for(c: Node3D) -> void:
	# AC-0257: the vwin window is gone (no caps, no culled slabs) — every
	# slab is wanted; on data landing the only possible placeholder is the
	# (off) fog wave, and the in-r gate invalidation is the real work.
	if int(c.face) > 1 or bool(c.mesh_built) or bool(c.low_built):
		return
	if c.data.is_empty():
		return
	var dx := int(c.cx) - last_pcx
	var dz := int(c.cz) - last_pcz
	if _is_tier0_col(dx, dz):
		return  # AC-0257: the tier-0 set goes straight to high — never a placeholder
	# AC-0261: the in-r order-gate invalidation below is a no-op (the
	# AC-0231 in-r placeholder lane is dead — _low_inr_invalidate keeps
	# the gate open unconditionally); the taxi test stays for parity.
	if absi(dx) + absi(dz) <= render_radius:
		_low_inr_invalidate()
	if int(c.face) > 1 or bool(c.mesh_built) or bool(c.low_built):
		return
	for si in range(c.data.size()):
		var si2 := int(si)
		if c.data[si2] == null or c.has_low_si(si2):
			continue
		if FOG_WAVE_ON and not c.has_fog_si(si2):
			_fog_ensure_slab(c, si2)

# AC-0231 rewrite: add slab si to the fog set (the shared MultiMesh
# instance is created on first use). The live fog count is per SLAB
# INSTANCE (low_fog_boxes_n) + per chunk (low_fog_chunks_n).
func _fog_ensure_slab(c: Node3D, si: int) -> void:
	var _wpt := Time.get_ticks_usec()  # AC-0251 MESHATTACH sub-stage (per-chunk fog node attach)
	if c.has_fog_si(si):
		_wprof_add(WP_MESHATTACH, Time.get_ticks_usec() - _wpt)
		return
	var had: bool = c.fog_slabs.size() > 0
	var i := 0
	while i < c.fog_slabs.size() and int(c.fog_slabs[i]) < si:
		i += 1
	c.fog_slabs.insert(i, si)
	c.fog_mask |= (1 << si)  # AC-0237 1a: mirror mask sync
	_low_probe_invalidate(c)  # AC-0262: fog state feeds the probe (FOG_WAVE_ON)
	if c.fog_instance == null:
		# AC-0247: the shared MultiMesh holder comes from the pool
		# (this build: the property is "multimesh" — no underscore; the
		# _mm_checkout reset sets mesh/material/transform/visibility).
		var pair := _mm_checkout()
		c.add_child(pair[0])
		c.fog_instance = pair[0]
	_fog_sync(c)
	low_fog_boxes_n += 1
	if not had:
		low_fog_chunks_n += 1
	_wprof_add(WP_MESHATTACH, Time.get_ticks_usec() - _wpt)

# AC-0231 rewrite: drop the fog instance for slab si (a low or the high
# replaces it at its Y).
func _fog_drop_slab(c: Node3D, si: int) -> void:
	var i: int = c.fog_slabs.find(si)
	if i < 0:
		return
	c.fog_slabs.remove_at(i)
	c.fog_mask &= ~(1 << si)  # AC-0237 1a: mirror mask sync
	_low_probe_invalidate(c)  # AC-0262: fog state feeds the probe (FOG_WAVE_ON)
	low_fog_boxes_n -= 1
	if c.fog_slabs.is_empty():
		_mm_checkin(c.fog_instance)  # AC-0247: pool (the shared box mesh is never freed)
		c.fog_instance = null
		low_fog_chunks_n -= 1
	else:
		_fog_sync(c)

# AC-0231 rewrite: rewrite the MultiMesh from fog_slabs — instance i is
# the pre-baked box at (0, si*16, 0) (the slab's Y, slab bottom).
func _fog_sync(c: Node3D) -> void:
	var mm: MultiMesh = c.fog_instance.multimesh
	mm.instance_count = c.fog_slabs.size()
	for i in range(c.fog_slabs.size()):
		mm.set_instance_transform(i, Transform3D(Basis(), Vector3(0.0, float(int(c.fog_slabs[i]) * 16), 0.0)))

# AC-0231: the placeholder surface arrays in the Mesh.ARRAY_*-indexed
# Array form add_surface_from_arrays wants (the chunk _surface shape).
func _low_surface(v: PackedVector3Array, i: PackedInt32Array, n: PackedVector3Array = PackedVector3Array(), c: PackedColorArray = PackedColorArray(), u: PackedVector2Array = PackedVector2Array()) -> Array:
	var a: Array = []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = v
	a[Mesh.ARRAY_INDEX] = i
	if n.size() > 0:
		a[Mesh.ARRAY_NORMAL] = n
	if c.size() > 0:
		a[Mesh.ARRAY_COLOR] = c
	if u.size() > 0:
		a[Mesh.ARRAY_TEX_UV] = u
	return a

# =====================================================================
# AC-0252 — the med/low AVERAGE-COLOR tiers (8x8x8 med / 4x4x4 low)
# =====================================================================
# Both tiers read the FULL volume of every sample (the whole 16x16x16 slab:
# 16 row_bytes rows, 4096 ids) instead of the old one-point-per-cell sample.
# A sample is AIR when MORE THAN HALF its volume is air (>=5 of 8 for med,
# >=33 of 64 for low); its per-face color = the average of the CACHED
# per-block-face average colors over the sample's NON-AIR blocks. The emit
# is the same 6-face outermost-shell scan + greedy merge as the textured
# low, but the merge key is the QUANTIZED FACE COLOR + the outermost plane
# (a color has no block id) and the vertex color IS that face color
# (no UVs — the noise shader, res://core/lod_avg.gdshader, breaks up the
# flat faces). C++ twin: gdext/src/mesh.cpp low_emit_avg (the TM pool
# path — the ONLY emit the game runs). TEST-ONLY (AC-0252 offload): this
# GDScript twin is referenced ONLY by the harness (the meshprobe A/B
# equivalence check + the ladder air-rule arm) — the game path (world.gd
# runtime / chunk.gd) never calls it: the main-thread lanes do dispatch
# + the _low_handoff attach/bookkeeping, never the grid sample or emit.

var _lod_fcc: PackedFloat32Array = PackedFloat32Array()  # 256 ids x 6 dirs x 3 (linear)
var _lod_fcc_dirty := true
var lod_fcc_build_ms := 0.0   # the one-time face-color cache build cost (AC-0252 report)
var lod_fcc_tiles := 0        # (id, dir) tiles averaged (evidence)
var lod_fcc_rebuilds := 0     # AC-0261: every rebuild (a zero-atlas first
                              # build is sticky — this must stay 1)
var _lod_avg_material: ShaderMaterial = null
var _lod_day_last := Color(-1.0, -1.0, -1.0)  # AC-0252: the "day" uniform's last value (skip the per-frame set when unchanged)

# AC-0252: the (block id x 6 face direction) AVERAGE COLOR cache — built
# ONCE per atlas on the main thread (the atlas swap marks it dirty; the
# C++ workers get a value copy in the dispatch entry, the same immutable-
# snapshot pattern as _low_ms_snap_get). Direction map = the mesh face
# table: 0/1/4/5 (±X/±Z) -> the "side" rect, 2 (+Y) -> "top", 3 (-Y) ->
# "bottom". Colors are AVERAGED in sRGB (the stored pixel space — the
# perceptually-right "average texture color") and converted to LINEAR
# once (the vertex color is consumed linear by the spatial shader).
func _lod_fcc_get() -> PackedFloat32Array:
	# AC-0261 follow-up: the ALL-ZERO first build (a call before the atlas
	# image is ready) must not stick — retry once the atlas appears. The
	# tiles counter is cumulative, so this clause can only ever fire for
	# the very first (tile-less) build; a successful build makes it a
	# permanent no-op.
	if _lod_fcc_dirty or _lod_fcc.is_empty() \
			or (lod_fcc_tiles == 0 and Data.atlas_tex != null and not Data.atlas_rects.is_empty()):
		_lod_fcc_dirty = false
		lod_fcc_rebuilds += 1
		print("FCCREBUILD n=%d tex=%s rects=%d tiles_so_far=%d" % [
			lod_fcc_rebuilds, str(Data.atlas_tex != null), Data.atlas_rects.size(), lod_fcc_tiles])
		var a := PackedFloat32Array()
		a.resize(256 * 18)
		var img: Image = null
		if Data.atlas_tex != null:
			img = Data.atlas_tex.get_image()
		if img != null and not Data.atlas_rects.is_empty():
			var t0 := Time.get_ticks_usec()
			var nw := int(img.get_width())
			var nh := int(img.get_height())
			for bk in Data.atlas_rects:
				var id := int(bk)
				if id < 0 or id > 255:
					continue
				var faces: Dictionary = Data.atlas_rects[bk]
				for d in range(6):
					var fname := "side"
					if d == 2:
						fname = "top"
					elif d == 3:
						fname = "bottom"
					var fr = faces.get(fname, null)
					if not (fr is Array) or (fr as Array).size() < 4:
						continue
					var frr: Array = fr
					var x0 := int(frr[0])
					var y0 := int(frr[1])
					var w := int(frr[2])
					var h := int(frr[3])
					if w <= 0 or h <= 0:
						continue
					var sr := 0.0
					var sg := 0.0
					var sb := 0.0
					var np := 0
					for py in range(h):
						var y := y0 + py
						if y < 0 or y >= nh:
							continue
						for px in range(w):
							var x := x0 + px
							if x < 0 or x >= nw:
								continue
							var pc: Color = img.get_pixel(x, y)
							sr += pc.r
							sg += pc.g
							sb += pc.b
							np += 1
					if np > 0:
						var lc := Color(sr / float(np), sg / float(np), sb / float(np)).srgb_to_linear()
						a[id * 18 + d * 3 + 0] = lc.r
						a[id * 18 + d * 3 + 1] = lc.g
						a[id * 18 + d * 3 + 2] = lc.b
						lod_fcc_tiles += 1
			lod_fcc_build_ms = (Time.get_ticks_usec() - t0) / 1000.0
		_lod_fcc = a
	return _lod_fcc

# AC-0252: the med/low avg-color instance material — the NOISE SHADER
# (static per-fragment hash of the fragment world position, ~6% amplitude,
# stable under camera motion — no flicker). ONLY the med/low avg-color
# instances wear it; the high path / fog / cap materials are untouched.
# The "day" uniform tracks the same sky_display color the fog box uses
# (the placeholders darkened at night before AC-0252 — the avg LODs keep
# that; it defaults to white so a fresh material is never black).
func _lod_avg_mat() -> ShaderMaterial:
	if _lod_avg_material == null:
		var sh := load("res://core/lod_avg.gdshader")
		_lod_avg_material = ShaderMaterial.new()
		_lod_avg_material.shader = sh
		_lod_avg_material.set_shader_parameter("day", Color(1.0, 1.0, 1.0))
	return _lod_avg_material

# AC-0261 (AC-0263): the LOD zone of a chunk at (dx, dz) from the player
# column, taxi metric (the render edge is taxi too — "render distance is
# the max value for everything that is rendered"): 0 = HIGH band
# [0, medium_start_r) — the build lane owns it (pending renders NOTHING,
# no placeholder of any kind); 1 = MED (8x8x8) [medium_start_r,
# low_start_r); 2 = LOW (4x4x4) [low_start_r, render_radius); 3 =
# DATA-ONLY [render_radius, ring edge) — nothing renders past the render
# distance. AC-0263: the high band's edge is the "mid LOD distance"
# (medium_start_r) — band0_r (the sim distance) no longer controls world
# generation (mobs/fluids only).
func _lod_tier_of(dx: int, dz: int) -> int:
	var taxi := absi(dx) + absi(dz)
	if taxi < medium_start_r:
		return 0
	if taxi < low_start_r:
		return 1
	if taxi < render_radius:
		return 2
	return 3

# AC-0257: the TIER-0 SET — the Chebyshev ball around the player column
# (Settings "tier0_radius") that goes STRAIGHT TO HIGH: no fog, no low,
# the build lane is the only path. radius 0 = the player's own column
# (the old dx==0 && dz==0 checks).
var tier0_r := 0

func _is_tier0_col(dx: int, dz: int) -> bool:
	return maxi(absi(dx), absi(dz)) <= tier0_r

# AC-0257: the tier-0 radius slider changed (Settings.apply_tier0_radius) —
# ENTERING columns lose their placeholders (the next fog/pick pass skips
# them; the build lane upgrades them straight to high) and EXITING columns
# keep their high (keep-high — nothing is ever downgraded). Invalidate the
# cached pick verdicts + the in-r drain proof (both taken under the old
# set) and re-stamp the queue.
func note_tier0_radius() -> void:
	tier0_r = clampi(int(Settings.values.get("tier0_radius", 0)), 0, int(Settings.TIER0_RADIUS_MAX))
	_low_none_key = ""
	_low_slab_none_key = ""
	_low_inr_invalidate()
	_rescore_kick()

# AC-0261: the user setting (Settings "low_start", taxi chunks) takes
# effect. The med/low split lives INSIDE the render distance: MED (8x8x8)
# owns [medium_start_r, low_start_r), LOW (4x4x4) owns [low_start_r,
# render_radius); the high band [0, medium_start_r) is full-fidelity per-
# slab (the build lane) and nothing renders past the render distance.
# The effective boundary is clamped to [medium_start_r, render_radius]
# (AC-0263: the floor moved from the sim distance to the mid LOD
# distance, which the settings clamp keeps above the sim distance). A boundary move re-stales every
# live low slab whose tier changed (the pending walks compare c.low_tiers
# against the LIVE tier), so invalidate the cached none-verdicts and
# re-stamp the queue.
func apply_low_start() -> void:
	var lo := medium_start_r
	var hi := render_radius
	if lo > hi:
		lo = hi
	# AC-0261: an out-of-band value re-defaults to the MIDPOINT (the
	# settings clamp's rule, mirrored here — an edge clamp would silently
	# cancel the LOW band when the value sits past render, e.g. a harness
	# that sets render_radius directly without the settings clamp chain).
	var ls := int(Settings.values.get("low_start", int((lo + hi) / 2)))
	if ls < lo or ls > hi:
		ls = int((lo + hi) / 2)
	low_start_r = ls
	_low_none_key = ""
	_low_slab_none_key = ""
	_low_inr_invalidate()
	_rescore_kick()

# AC-0252: the core average-color grid over 16 full 256-byte slab ROWS
# (rows[local_y], local_y 0..15 — the chunk slab at si, edited data).
# G = 8 (med, 2x2x2 samples) or 4 (low, 4x4x4 samples). Returns
# {solid: PackedByteArray(G^3), cols: PackedFloat32Array(G^3 x 18)} — a
# sample is solid iff NOT more than half its (16/G)^3 volume is air; its
# 18 floats = the 6 face-direction average colors (linear, see _lod_fcc_get).
# The per-block accumulation order (py, pz, px loops) is the C++ twin's
# float32 op order (mesh.cpp low_emit_avg — the equivalence contract).
# AC-0258: the clutter blocks (the C++ awecommon::is_clutter_block twin —
# rose 18, dandelion 19): the tiny cross-quad flora. At the average-color
# LOD tiers they count as AIR (the speckle color is excluded from the avg;
# an all-clutter sample emits nothing). The live path is the C++
# low_emit_avg (the "nc" slab field); this GD twin (harness-only — the
# ladder arm's air-rule evidence) mirrors the same rule.
func _clutter_block(bid: int) -> bool:
	return bid == 18 or bid == 19

func _avg_grid_from_rows(rows: Array, G: int) -> Dictionary:
	var solid := PackedByteArray()
	solid.resize(G * G * G)
	var cols := PackedFloat32Array()
	cols.resize(G * G * G * 18)
	var cell := int(16.0 / float(G))
	var tot := cell * cell * cell
	var fcc := _lod_fcc_get()
	for cy in range(G):
		for cz in range(G):
			for cx in range(G):
				var air := 0
				var acc := PackedFloat32Array()
				acc.resize(18)
				var cnt := 0
				for py in range(cell):
					var row: PackedByteArray = rows[cy * cell + py]
					var zr := (cz * cell) * 16
					var xo := cx * cell
					for pz in range(cell):
						var base: int = zr + pz * 16 + xo
						for px in range(cell):
							var bid: int = row[base + px]
							# AC-0258: clutter counts as air at the avg tiers.
							if bid == 0 or _clutter_block(bid):
								air += 1
								continue
							cnt += 1
							var fo: int = bid * 18
							for d in range(18):
								acc[d] += fcc[fo + d]
				var idx := cy * G * G + cz * G + cx
				if air * 2 > tot or cnt == 0:
					solid[idx] = 0
				else:
					solid[idx] = 1
					var inv := 1.0 / float(cnt)
					var co: int = idx * 18
					for d in range(18):
						cols[co + d] = acc[d] * inv
	return {"solid": solid, "cols": cols}

# AC-0252: the per-slab average-color grid (the chunk read wrapper: 16
# row_bytes rows of the edited slab; null slab = the all-air grid).
func _avg_slab_grid(c: Node3D, si: int, G: int) -> Dictionary:
	if c.data.is_empty() or si < 0 or si >= c.data.size() or c.data[si] == null:
		# null slab = the all-air grid (a zero-filled row set).
		var zr := PackedByteArray()
		zr.resize(256)
		var rows: Array = []
		rows.resize(16)
		for y in range(16):
			rows[y] = zr
		return _avg_grid_from_rows(rows, G)
	var rows: Array = []
	rows.resize(16)
	var y0 := si * 16
	for y in range(16):
		rows[y] = c.row_bytes(y0 + y)
	return _avg_grid_from_rows(rows, G)

# AC-0252: all-air test for an average-color grid's solid mask.
func _avg_grid_empty(solid: PackedByteArray) -> bool:
	for i in range(solid.size()):
		if int(solid[i]) != 0:
			return false
	return true

# AC-0252: the solidity-neighbor of coarse cell cc along the face normal —
# inside the grid -> the grid; across the slab above/below -> the NEIGHBOR
# SLAB's solid mask (a solid neighbor culls — the avg tiers have no block
# id, so "same id" collapses to "solid"); off the column -> air (0).
func _avg_neighbor_solid(g: Dictionary, grids: Array, si: int, cc: Array, n: Vector3i, nax: int, G: int) -> int:
	var ix := int(cc[0])
	var iy := int(cc[1])
	var iz := int(cc[2])
	var s: PackedByteArray = g["solid"]
	if nax == 0:
		var nx := ix + n.x
		if nx < 0 or nx >= G:
			return 0
		return int(s[nx + iz * G + iy * G * G])
	if nax == 2:
		var nz := iz + n.z
		if nz < 0 or nz >= G:
			return 0
		return int(s[ix + nz * G + iy * G * G])
	var ny := iy + n.y
	if ny < 0 or ny >= G:
		var gsi := si + n.y
		if gsi < 0 or gsi >= grids.size():
			return 0
		var ng = grids[gsi]
		if ng == null:
			return 0
		var ng2: PackedByteArray = ng["solid"]
		var gyb := 0 if n.y > 0 else G - 1
		return int(ng2[ix + iz * G + gyb * G * G])
	return int(s[ix + iz * G + ny * G * G])

# AC-0252: the GD TWIN of the C++ low_emit_avg (the worker-side emit the
# TM pool runs for BOTH the in-r lane and the far wave — TEST-ONLY now:
# the game lanes dispatch the C++ emit and never call this twin; it serves
# the harness equivalence check only; same float32 op order).
# g = {solid, cols} for the target slab; grids = the column array (si-1/
# si/si+1 filled, the slab-boundary culling reads their solid masks);
# G = MED_GRID (8) or LOW_GRID (4). Returns null when nothing emits (every
# sample air / every exposed face cullled), else the vertex-color ArrayMesh
# (NO UVs — the noise shader material owns the surface). Vertices are
# SLAB-LOCAL 0..16 (the instance sits at (0, si*16, 0), like the low).
func _avg_emit_slab(g: Dictionary, grids: Array, si: int, G: int) -> ArrayMesh:
	var s: PackedByteArray = g["solid"]
	var cols: PackedFloat32Array = g["cols"]
	var cell := float(16.0) / float(G)
	var av := PackedVector3Array()
	var an := PackedVector3Array()
	var ac := PackedColorArray()
	var ai := PackedInt32Array()
	# per face: the (u, v) axes (0=x, 1=y, 2=z) — the mesh.cpp convention:
	# fi0/1 (±X): u=z, v=y; fi2/3 (±Y): u=x, v=z; fi4/5 (±Z): u=x, v=y.
	var u_ax: Array = [2, 2, 0, 0, 0, 0]
	var v_ax: Array = [1, 1, 2, 2, 1, 1]
	for fi in range(6):
		var n: Vector3i = VoxelMath.FACES[fi].n
		var nax := 0
		if n.x != 0:
			nax = 0
		elif n.y != 0:
			nax = 1
		else:
			nax = 2
		var ua := int(u_ax[fi])
		var va := int(v_ax[fi])
		var ns: int = n.x if nax == 0 else (n.y if nax == 1 else n.z)
		# the face-eligibility map m[pv][pu] = the merge key (the
		# QUANTIZED face color x16 + the outermost plane k+1) or -1. The
		# scan walks the normal axis FROM THE VIEWING SIDE INWARD and keeps
		# the FIRST solid sample whose neighbor (the grid, the slab
		# above/below via the solid masks, or air off the column) is AIR —
		# the outermost shell; sandwiched samples never emit. The quantized
		# color (31 levels/channel) is the merge key's identity (there is
		# no block id to merge on): same color + same plane merges.
		var m: Array = []
		var kmap: Array = []
		for pv in range(G):
			var mrow: Array = []
			var krow: Array = []
			for pu in range(G):
				var cc := [0, 0, 0]
				cc[ua] = pu
				cc[va] = pv
				var keyv := -1
				var kk := 0
				var k: int = G - 1 if ns > 0 else 0
				while kk < G:
					cc[nax] = k
					var idx: int = int(cc[0]) + int(cc[2]) * G + int(cc[1]) * G * G
					if int(s[idx]) != 0:
						if _avg_neighbor_solid(g, grids, si, cc, n, nax, G) == 0:
							var cr: float = cols[idx * 18 + fi * 3 + 0]
							var cg: float = cols[idx * 18 + fi * 3 + 1]
							var cb: float = cols[idx * 18 + fi * 3 + 2]
							var q := int(cr * 31.0) * 1024 + int(cg * 31.0) * 32 + int(cb * 31.0)
							keyv = q * 16 + (k + 1)
						break
					k += -1 if ns > 0 else 1
					kk += 1
				mrow.append(keyv)
				krow.append(k)
			m.append(mrow)
			kmap.append(krow)
		# the greedy merge over the plane: W along u, H along v (same key
		# in the strip below — the v-merge is legal: the quad is one color,
		# coplanar, the merged cells are adjacent).
		for pv in range(G):
			var pu := 0
			while pu < G:
				var key2: int = int(m[pv][pu])
				if key2 < 0:
					pu += 1
					continue
				var W := 1
				while pu + W < G and int(m[pv][pu + W]) == key2:
					W += 1
				var H := 1
				while pv + H < G:
					var okh := true
					for u2 in range(W):
						if int(m[pv + H][pu + u2]) != key2:
							okh = false
							break
					if not okh:
						break
					H += 1
				# the emitting cell of the quad origin + its slab-local
				# world origin (a grid cell is (16/G) blocks).
				var cc0 := [0, 0, 0]
				cc0[ua] = pu
				cc0[va] = pv
				cc0[nax] = int(kmap[pv][pu])
				var wx := float(cc0[0]) * cell
				var wy := float(cc0[1]) * cell
				var wz := float(cc0[2]) * cell
				if nax == 0:
					wx += cell if n.x > 0 else 0.0
				elif nax == 1:
					wy += cell if n.y > 0 else 0.0
				else:
					wz += cell if n.z > 0 else 0.0
				# the quad color = the ORIGIN cell's face color (every
				# merged cell shares the quantized key — the sub-quantized
				# difference is invisible and keeps the twins byte-stable).
				var oidx: int = int(cc0[0]) + int(cc0[2]) * G + int(cc0[1]) * G * G
				var qcr: float = cols[oidx * 18 + fi * 3 + 0]
				var qcg: float = cols[oidx * 18 + fi * 3 + 1]
				var qcb: float = cols[oidx * 18 + fi * 3 + 2]
				# AC-0252: av is a PackedVector3Array, so av.size() is the
				# VERTEX count already (the C++ twin's flat-float av needs the
				# /3; this twin must not). The quad's first vertex index.
				var cb0 := av.size()
				var corners: Array = VoxelMath.FACES[fi].c
				for j in range(4):
					var cvx: float = float((corners[j] as Vector3).x)
					var cvy: float = float((corners[j] as Vector3).y)
					var cvz: float = float((corners[j] as Vector3).z)
					var px := wx
					var py := wy
					var pz := wz
					if fi == 0 or fi == 1:  # u = z (W cells), v = y (H cells)
						py = wy + cvy * float(H) * cell
						pz = wz + cvz * float(W) * cell
					elif fi == 2 or fi == 3:  # u = x (W cells), v = z (H cells)
						px = wx + cvx * float(W) * cell
						pz = wz + cvz * float(H) * cell
					else:  # fi 4/5: u = x (W cells), v = y (H cells)
						px = wx + cvx * float(W) * cell
						py = wy + cvy * float(H) * cell
					av.append(Vector3(px, py, pz))
					an.append(n)
					ac.append(Color(qcr, qcg, qcb, 1.0))
				ai.append(cb0)
				ai.append(cb0 + 2)
				ai.append(cb0 + 1)
				ai.append(cb0)
				ai.append(cb0 + 3)
				ai.append(cb0 + 2)
				for v2 in range(pv, pv + H):
					for u2 in range(pu, pu + W):
						m[v2][u2] = -1
				pu += W
	if av.is_empty():
		return null
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _low_surface(av, ai, an, ac))
	return mesh

# AC-0231 rewrite: per-slab 4x4x4 sampling of the (EDITED) slab data — the
# low grid (64 cells of 4x4x4 blocks, layout x + z*4 + y*16). ONE sample per
# coarse cell, at the center of its 4x4x4 block span (local
# (4sx+2, 4sy+2, 4sz+2)): 4 C++ row calls (the mid row of each 4-block y
# band — row_bytes = the C++ slab_row over the EDITED data, so player edits
# show). A cell that samples air stays 0 — the emitter skips it (a sparse
# tree slab stays small quads with shape, not one 16x16x16 giant block).
# A null slab (any non-air check: data[si] == null) yields an all-air grid.
func _low_slab_grid(c: Node3D, si: int) -> PackedByteArray:
	var g := PackedByteArray()
	g.resize(LOW_GRID * LOW_GRID * LOW_GRID)
	if c.data.is_empty() or si < 0 or si >= c.data.size() or c.data[si] == null:
		return g
	var y0 := si * 16
	for sy in range(LOW_GRID):
		var row: PackedByteArray = c.row_bytes(y0 + sy * LOW_CELL_BLOCKS + 2)
		var gyb := sy * (LOW_GRID * LOW_GRID)
		for sz in range(LOW_GRID):
			var zr := (sz * LOW_CELL_BLOCKS + 2) * 16
			for sx in range(LOW_GRID):
				g[gyb + sz * LOW_GRID + sx] = row[zr + sx * LOW_CELL_BLOCKS + 2]
	return g

# AC-0231 rewrite: all-air test for a low grid (every cell sampled air).
func _low_grid_empty(g: PackedByteArray) -> bool:
	for i in range(g.size()):
		if int(g[i]) != 0:
			return false
	return true

# AC-0231 rewrite: the block-neighbor of coarse cell cc along the face
# normal n — inside the grid -> the grid; at the slab above/below -> the
# NEIGHBOR SLAB's grid (the coarse cell across the boundary, so a
# same-type slab boundary culls; null slab = air); off the column on x/z
# -> air (the neighbor column is unknown to this lane — the face shows;
# the neighbor's own edge face only shows when THIS cell is air, so the
# two never fight visibly).
func _low_neighbor_id(g: PackedByteArray, grids: Array, si: int, cc: Array, n: Vector3i, nax: int) -> int:
	var ix := int(cc[0])
	var iy := int(cc[1])
	var iz := int(cc[2])
	if nax == 0:
		var nx := ix + n.x
		if nx < 0 or nx >= LOW_GRID:
			return 0
		return int(g[nx + iz * LOW_GRID + iy * LOW_GRID * LOW_GRID])
	if nax == 2:
		var nz := iz + n.z
		if nz < 0 or nz >= LOW_GRID:
			return 0
		return int(g[ix + nz * LOW_GRID + iy * LOW_GRID * LOW_GRID])
	# nax == 1 (y) — the slab boundary:
	var ny := iy + n.y
	if ny < 0 or ny >= LOW_GRID:
		var gsi := si + n.y  # n.y = +1 (the slab above) or -1 (below)
		if gsi < 0 or gsi >= grids.size():
			return 0
		if grids[gsi] == null:
			return 0
		var ng: PackedByteArray = grids[gsi]
		var gyb := 0 if n.y > 0 else LOW_GRID - 1
		return int(ng[ix + iz * LOW_GRID + gyb * LOW_GRID * LOW_GRID])
	return int(g[ix + iz * LOW_GRID + ny * LOW_GRID * LOW_GRID])

# AC-0231 fix3: the tile top-left + whether it is a MERGED-ATLAS STRIP —
# returns [Vector2, bool]. Strips (512px wide = 16 tile repeats, 128px =
# 4 rows) carry the REPEATING-UV span: 31px per world block across the
# quad (up to 16x4 blocks — still inside the strip; the qwrite_merged
# convention: the texture repeats 4x across each 4-block quad, NOT
# stretched). Blocks without a strip (non-solid / cross / cutout: water,
# leaves, flowers, torch, lava, banana) fall back to the ORIGINAL 32x32
# atlas rect (the merged canvas carries the original atlas at (0,0)) — and
# the emitter must sample exactly ONE tile (a 31px span) from it, exactly
# like the high mesh (mesh.cpp's plain branch): a repeating span from a
# plain rect walks 3+ tiles past the block's own tile into its atlas
# neighbors (the "wrong texture mapping" the user reported on the far
# leaves/water).
func _low_tile_base(id: int, fi: int) -> Array:
	var k := id * 256 + fi
	var v = _low_tl.get(k)
	if v != null:
		return v
	var face := "side"
	if fi == 2:
		face = "top"
	elif fi == 3:
		face = "bottom"
	var r: Array = [Vector2(-1.0, -1.0), false]
	var rects: Dictionary = _tm_ms_full.get("rects", {})
	if not rects.is_empty():
		var sr: Vector2i = rects.get("%d_%s" % [id, face], Vector2i(-1, -1))
		if sr.x >= 0:
			r = [Vector2(float(sr.x), float(sr.y)), true]
	if (r[0] as Vector2).x < 0.0:
		var tl: Vector2i = Data.block_rect(id, face)
		if tl.x >= 0:
			r = [Vector2(float(tl.x), float(tl.y)), false]
	_low_tl[k] = r
	return r

# AC-0231 rewrite (fix3): greedy meshing on the per-slab 4x4x4 grid — one
# face where the neighbor is a DIFFERENT id (air = 0; off the column reads
# as air; the slab above/below read through `grids`, so a same-type slab
# boundary culls), 2D-merged per face plane (the chunk.gd / mesh.cpp
# greedy pattern, at 4x4x4 resolution). The corner order + UV mapping
# mirror the high mesh exactly: STRIP quads (the block has a merged-atlas
# strip) use REPEATING UVs — 31px per BLOCK (the texture repeats 4 times
# across each 4-block quad, NOT stretched over the quad); PLAIN-rect
# quads (no strip: water/leaves/flowers/torch/lava/banana) sample exactly
# ONE 32px tile (a 31px span for any quad size — mesh.cpp's plain branch),
# because a repeating span from a plain rect would walk into the block's
# atlas neighbors. Vertices are SLAB-LOCAL (0..16); the instance sits at
# (0, si*16, 0). The vertex color is the opaque shader's repack: r = sky
# s (1.0 flat — a far filler), g = block light (0), b = the per-face
# shade.
func _low_emit_slab(g: PackedByteArray, grids: Array, si: int) -> ArrayMesh:
	var hms := float(_tm_ms_full.get("h", Data.ATLAS_PX))
	var av := PackedVector3Array()
	var an := PackedVector3Array()
	var ac := PackedColorArray()
	var au := PackedVector2Array()
	var ai := PackedInt32Array()
	var G := LOW_GRID
	var cell := float(LOW_CELL_BLOCKS)
	# per face: the (u, v) axes (0=x, 1=y, 2=z) — the mesh.cpp convention:
	# fi0/1 (±X): u=z, v=y; fi2/3 (±Y): u=x, v=z; fi4/5 (±Z): u=x, v=y.
	var u_ax: Array = [2, 2, 0, 0, 0, 0]
	var v_ax: Array = [1, 1, 2, 2, 1, 1]
	for fi in range(6):
		var n: Vector3i = VoxelMath.FACES[fi].n
		var nax := 0
		if n.x != 0:
			nax = 0
		elif n.y != 0:
			nax = 1
		else:
			nax = 2
		var ua := int(u_ax[fi])
		var va := int(v_ax[fi])
		var ns: int = n.x if nax == 0 else (n.y if nax == 1 else n.z)
		# the face-eligibility map m[pv][pu]: the id (or -1) of the
		# OUTERMOST exposed cell of the (pu, pv) line + kmap[pv][pu] = its
		# k. The scan walks the normal axis FROM THE VIEWING SIDE (the side
		# the face normal points at) INWARD and keeps the FIRST solid cell:
		# its face is exposed to the neighbor (air, a different id, or the
		# slab above/below via grids). Sandwiched interior faces are
		# occluded by the outer cells and never emit.
		var m: Array = []
		var kmap: Array = []
		for pv in range(G):
			var mrow: Array = []
			var krow: Array = []
			for pu in range(G):
				var cc := [0, 0, 0]
				cc[ua] = pu
				cc[va] = pv
				var idv := -1
				var kk := 0
				var k: int = G - 1 if ns > 0 else 0
				while kk < G:
					cc[nax] = k
					var idx: int = int(cc[0]) + int(cc[2]) * G + int(cc[1]) * G * G
					var idc: int = int(g[idx])
					if idc != 0:
						if _low_neighbor_id(g, grids, si, cc, n, nax) != idc:
							idv = idc
						break
					k += -1 if ns > 0 else 1
					kk += 1
				# the merge key = id*16 + (k+1): the greedy merge only
				# combines cells with the SAME id AND the SAME outermost
				# plane k (mesh.cpp emit_ro_merged iterates per plane —
				# merging across planes drew one flat quad over a stepped
				# shell and turned hollow slabs into 16^3 boxes).
				mrow.append(idv * 16 + (k + 1) if idv >= 0 else -1)
				krow.append(k)
			m.append(mrow)
			kmap.append(krow)
		# the greedy merge over the plane: W along u (same key), H along v
		# capped at ONE coarse cell (4 blocks) — the merged-atlas strip is
		# 4 rows (128px), so a v span above 4 blocks (2+ cells) would
		# sample outside the strip; the high mesh caps its v span at 4
		# blocks exactly (mesh.cpp: `while (h < 4 && ...)`).
		for pv in range(G):
			var pu := 0
			while pu < G:
				var key2: int = int(m[pv][pu])
				if key2 < 0:
					pu += 1
					continue
				var idv2: int = key2 / 16
				var W := 1
				while pu + W < G and int(m[pv][pu + W]) == key2:
					W += 1
				var H := 1
				# the emitting cell of the quad origin + its slab-local
				# world origin (a grid cell is LOW_CELL_BLOCKS blocks).
				var cc0 := [0, 0, 0]
				cc0[ua] = pu
				cc0[va] = pv
				cc0[nax] = int(kmap[pv][pu])
				var wx := float(cc0[0]) * cell
				var wy := float(cc0[1]) * cell
				var wz := float(cc0[2]) * cell
				# the face sits on the +n side of the cell (plane offset):
				if nax == 0:
					wx += cell if n.x > 0 else 0.0
				elif nax == 1:
					wy += cell if n.y > 0 else 0.0
				else:
					wz += cell if n.z > 0 else 0.0
				# the tile top-left + the strip/plain flag (see
				# _low_tile_base); the UV span per face axis, in canvas px:
				# STRIP quads tile 31px per WORLD BLOCK (the qwrite_merged
				# convention — the texture repeats 4 times across each
				# 4-block quad, NOT stretched); PLAIN-rect quads sample
				# exactly ONE 32px tile — a 31px span for any quad size
				# (mesh.cpp's plain branch).
				var tb := _low_tile_base(idv2, fi)
				var base_v: Vector2 = tb[0]
				var has_tl := base_v.x >= 0.0
				var su := float(W) * cell * 31.0 if bool(tb[1]) else 31.0
				var sv := float(H) * cell * 31.0 if bool(tb[1]) else 31.0
				var sh := float(VoxelMath.FACES[fi].sh)
				var cb := av.size()
				var corners: Array = VoxelMath.FACES[fi].c
				for j in range(4):
					var cvx: float = float((corners[j] as Vector3).x)
					var cvy: float = float((corners[j] as Vector3).y)
					var cvz: float = float((corners[j] as Vector3).z)
					var px := wx
					var py := wy
					var pz := wz
					var uu: float
					var vv: float
					if fi == 0 or fi == 1:  # u = z (W cells), v = y (H cells)
						py = wy + cvy * float(H) * cell
						pz = wz + cvz * float(W) * cell
						uu = 0.5 + cvz * su
						vv = 0.5 + (1.0 - cvy) * sv
					elif fi == 2 or fi == 3:  # u = x (W cells), v = z (H cells)
						px = wx + cvx * float(W) * cell
						pz = wz + cvz * float(H) * cell
						uu = 0.5 + cvx * su
						vv = 0.5 + cvz * sv
					else:  # fi 4/5: u = x (W cells), v = y (H cells)
						px = wx + cvx * float(W) * cell
						py = wy + cvy * float(H) * cell
						uu = 0.5 + cvx * su
						vv = 0.5 + (1.0 - cvy) * sv
					av.append(Vector3(px, py, pz))
					an.append(n)
					ac.append(Color(1.0, 0.0, sh, 1.0))
					if has_tl:
						au.append(Vector2((base_v.x + uu) / Data.ATLAS_PX, (base_v.y + vv) / hms))
					else:
						au.append(Vector2.ZERO)
				ai.append(cb)
				ai.append(cb + 2)
				ai.append(cb + 1)
				ai.append(cb)
				ai.append(cb + 3)
				ai.append(cb + 2)
				for v2 in range(pv, pv + H):
					for u2 in range(pu, pu + W):
						m[v2][u2] = -1
				pu += W
	if av.is_empty():
		return null
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _low_surface(av, ai, an, ac, au))
	return mesh

# AC-0231 fix3: build the per-slab lows for a chunk — the FULL COLUMN
# pass (harness-only drive — the R16 air-chunk test uses it; the live
# WAVE 2 lanes dispatch slab-by-slab themselves): every PENDING slab
# (the fogged-not-low slabs + — when the chunk is stale, edited after the
# low — every low slab to rebuild from the edited data), ascending si.
# The per-slab core is _low_build_slab — the worker dispatch + the
# null-slab air bookkeeping (NO main-thread generation). A slab's low
# REPLACES its fog at the slab's Y.
func _low_build(c: Node3D) -> void:
	if _low_fog_mesh == null:
		return
	var t0 := Time.get_ticks_usec()
	var rebuild := bool(c.low_built)
	if not rebuild and c.fog_slabs.is_empty():
		return
	var targets: Array = _low_pending_sis(c)
	if targets.is_empty():
		return
	for si in targets:
		_low_build_slab(c, int(si))
	if timing:
		print("LOWBUILD %d,%d slabs=%d ms=%.1f" % [int(c.cx), int(c.cz), targets.size(), (Time.get_ticks_usec() - t0) / 1000.0])

# AC-0231 fix3: every PENDING slab of a chunk, ascending si — a fogged
# slab not yet lowed, or (when the chunk is stale: edited after the low)
# a low slab to rebuild. fog_slabs / low_slabs are si-sorted and DISJOINT
# (a slab is either fogged or lowed, never both — placement swaps one for
# the other), so the merged walk yields the union in order.
# AC-0257: the cap set and the kept mask are gone (vwin removal) — the
# walk merges the fog + low sets in si order; every slab is wanted.
# fog_slabs / low_slabs are si-sorted and pairwise DISJOINT (a slab holds
# at most one placeholder).
func _low_pending_sis(c: Node3D) -> Array:
	var out: Array = []
	var tier := _lod_tier_of(int(c.cx) - last_pcx, int(c.cz) - last_pcz)  # AC-0252: the live band tier
	var f := 0
	var l := 0
	while f < c.fog_slabs.size() or l < c.low_slabs.size():
		var fs := int(c.fog_slabs[f]) if f < c.fog_slabs.size() else 1 << 30
		var ls := int(c.low_slabs[l]) if l < c.low_slabs.size() else 1 << 30
		var si: int
		var is_ph := false  # true = FOG (the placeholder set)
		if fs <= ls:
			si = fs
			f += 1
			is_ph = true
		else:
			si = ls
			l += 1
		if is_ph:
			# FOG (in si order): pending while the data is fresh (a
			# terminal mark — the slab SAMPLED all-air at this data_gen —
			# skips it until the data changes).
			if int(c.low_failed.get(si, -1)) != int(c.data_gen):
				out.append(si)
		elif c.low_stamps.get(si, []) != c.stamp() \
				or c.low_tiers.get(si, -1) != tier:
			# a LOW slab older than the chunk stamp (edited after the low)
			# or built at a DIFFERENT band tier (AC-0252: the low-start
			# boundary moved since the build — re-lower at the live tier)
			# — PER-SLAB staleness: the finished slabs of a partially-
			# lowered chunk stay fresh while its other slabs are fogged.
			out.append(si)
	if not FOG_WAVE_ON:
		# AC-0240: the fog set was the entry ticket into this walk - a kept
		# slab got its fog on landing, the fog made it pending, the low swapped
		# it. With the fog wave off a kept data slab that holds NO placeholder
		# and no low is the pending source directly (bounded 24-slab scan; the
		# flag-on path above is untouched).
		for si in range(c.data.size()):
			var si2 := int(si)
			if c.data[si2] != null and not c.has_low_si(si2) \
					and int(c.low_failed.get(si2, -1)) != int(c.data_gen):
				out.append(si2)
		out.sort()
	return out

# AC-0257: the old _low_pending_si (the min-si first-pending probe) is
# gone — the WAVE 2 / in-r picks now use _entry_best_pending (the LAYER-
# best pending slab — the bake order, see its comment).

# AC-0231 fix3: true when ANY low slab of the chunk is stale (built before
# the current chunk stamp). The WAVE 3 upgrade pick uses it — a chunk is
# upgrade-ready only when every one of its low slabs reflects the current
# data (a per-slab stamp means a partially-lowered chunk is "stale" only
# for the slabs that actually owe a rebuild).
func _low_any_stale(c: Node3D) -> bool:
	if not bool(c.low_built):
		return false
	var tier := _lod_tier_of(int(c.cx) - last_pcx, int(c.cz) - last_pcz)  # AC-0252: the live band tier
	for si in c.low_slabs:
		if c.low_stamps.get(int(si), []) != c.stamp() \
				or c.low_tiers.get(int(si), -1) != tier:
			return true
	return false

# AC-0231 fix3 / AC-0252 (+ worker offload): the WAVE 2 per-slab entry —
# ZERO slab generation on the main thread. The band-tier AVERAGE-COLOR
# grid sample + emit (MED 8x8x8 inside the configurable low-start
# distance, LOW 4x4x4 outside it — _lod_tier_of) run on the TM WORKER
# POOL (the C++ low_emit_avg, the _low_dispatch_slab path); the attach +
# every bit of the per-slab bookkeeping (the fog swap, the cap swap, the
# per-slab stamp WITH THE TIER, the all-air terminal mark, the counters)
# land in the _low_handoff on the main thread — the scene-tree work that
# has to stay there. The TEXTURED 4x4x4 emit (_low_emit_slab) stays in
# the tree, dormant. The ONLY thing that runs inline is a slab whose DATA
# IS NULL (the dispatch's -1 verdict — an empty column slab has no grid
# to sample and no emit to run): the air bookkeeping via _low_air_slab
# (a slab whose data went NULL shows nothing — its stale fog + any low
# are dropped). A slab that has blocks but SAMPLES all-air is a real
# emit (a worker task): its fog restore + the terminal low_failed mark
# land in the _low_handoff.
func _low_build_slab(c: Node3D, si: int) -> void:
	if c.data.is_empty() or si < 0 or si >= c.data.size():
		return
	if c.data[si] == null:
		_low_air_slab(c, si)
		return
	# Verdicts: 1 = a worker owns the grid sample + emit (the
	# _low_handoff attaches it when it lands), 0 = a task is already in
	# flight for this (key, si) (dedupe — nothing to do), 2 = the pool
	# queue is saturated (the slab stays PENDING — the lane re-picks it
	# next frame). No main-thread generation on any of them.
	_low_dispatch_slab(c, si)

# AC-0252 offload: the NULL-SLAB bookkeeping — the dispatch's -1 verdict
# (an empty column slab: no grid to sample, no emit to run — there is
# nothing to dispatch). This is the air half of what the old sync
# _low_build_slab did for a null slab, WITHOUT the (wasted) grid sample
# of the slab's neighbors: drop the low if it holds one, erase its
# per-slab stamp, and — with no data — drop its fog + cap. A slab whose
# window culled it never touches its placeholders (the cap holds — the
# same keep rule the sync build had at the top of the function).
func _low_air_slab(c: Node3D, si: int) -> void:
	if si < 0 or si >= c.data.size() or c.data[si] != null:
		return
	_low_drop_slab(c, si)
	c.low_stamps.erase(si)  # not low anymore (no data — air)
	_fog_drop_slab(c, si)

# AC-0257 (stale-LOD, absorbs AC-0256): the FLIP-BACK attach — the slab
# holds a cached emit at its LIVE tier (emitted earlier, displaced when
# the boundary moved): rebuild the ArrayMesh from the cached arrays +
# attach (the _low_handoff's non-empty branch, minus the emit). Runs on
# the main thread (the _low_dispatch_slab flip-back fast path — a scene-
# tree attach, ~0.2 ms). The caller verified the tier + the unchanged
# data (dgen/fgen); the cache entry is consumed.
func _low_attach_cached(c: Node3D, si: int, cached: Dictionary) -> void:
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _low_surface(cached["v"], cached["i"], cached["n"], cached["c"]))
	low_max_h = maxf(low_max_h, float(cached.get("mh", 0.0)))
	_low_place_slab(c, si, mesh)
	_fog_drop_slab(c, si)
	c.low_built = true
	c.low_failed.erase(si)
	c.low_stamps[si] = c.stamp()
	c.low_tiers[si] = int(cached["tier"])
	c.low_cache.erase(si)
	low_cache_hit_n += 1
	low_handoff_n += 1

# AC-0236 part 2: the merge-atlas SNAPSHOT for the low emit workers (the
# C++ low_emit tile tables: the STRIP rects from _tm_ms_full.rects + the
# PLAIN original-atlas rects = Data.atlas_rects — the _low_tile_base
# Data.block_rect branch — + the canvas size). Built once per atlas
# (rebuild marked dirty where _tm_ms_full reassigns); the workers read it
# read-only (it is replaced wholesale, never mutated in place).
func _low_ms_snap_get() -> Dictionary:
	if _low_ms_snap_dirty or _low_ms_snap.is_empty():
		_low_ms_snap_dirty = false
		if _tm_ms_full.rects.is_empty():
			_low_ms_snap = {"rects": {}, "h": float(Data.ATLAS_PX)}
		else:
			_low_ms_snap = {
				"rects": _tm_ms_full.rects.duplicate(),
				"plain": Data.atlas_rects,
				"h": float(_tm_ms_full.get("h", 0.0)),
				"atlas_px": float(Data.ATLAS_PX),
			}
	return _low_ms_snap

# AC-0236 part 2 / AC-0250 / AC-0252: dispatch ONE slab's low EMIT to the
# TM pool (the C++ AweMesh.low_emit_avg on a value-copied slab column —
# the AC-0082 handoff pattern). The entry carries the dispatch-time BAND
# TIER (the C++ emit's grid: 8 = MED, 4 = LOW) + the face-color cache
# (value copy — the immutable snapshot, replaced wholesale per atlas).
# Returns 1 = a worker owns it (the _low_handoff attaches), 0 = a task is
# ALREADY in flight for this (key, si) (dedupe — the caller does nothing),
# 2 = the pool queue hit LOW_TASK_CAP (capped — a no-op: the slab stays
# PENDING and the in-r pass or the far wave re-picks it next frame;
# AC-0250 removed the main-thread sync fallback), -1 = the slab is null
# (no emit possible — the caller does the air bookkeeping via
# _low_air_slab; the grid sample + emit of every other slab run on the
# workers, never the main thread).
func _low_dispatch_slab(c: Node3D, si: int) -> int:
	if threadmesh_pool == null or si < 0 or si >= c.data.size() or c.data[si] == null:
		return -1
	if _low_tasks.size() >= LOW_TASK_CAP:
		return 2
	var key := _key(int(c.cx), int(c.cz))
	var lkey: String = key + ":" + str(si)
	if _low_task_keys.has(lkey):
		return 0
	var mc: Variant = ChunkScript.mesh_cpp()
	# AC-0252: the band tier at dispatch (the handoff DROPS the result when
	# the live tier moved since — the slab re-picks at the new tier).
	var tier := _lod_tier_of(int(c.cx) - last_pcx, int(c.cz) - last_pcz)
	# AC-0257 (stale-LOD, absorbs AC-0256): the FLIP-BACK fast path — the
	# slab holds a CACHED emit built at the LIVE tier (emitted earlier,
	# displaced when the boundary moved): attach it directly (no worker
	# round-trip). The cache is only honored against UNCHANGED data (a
	# data edit bumps dgen/fgen — the entry is dropped and the emit
	# re-runs).
	var cache: Dictionary = c.low_cache.get(si, {})
	if not cache.is_empty():
		if int(cache.get("tier", -1)) == tier \
				and int(cache.get("dgen", -1)) == int(c.data_gen) \
				and int(cache.get("fgen", -1)) == int(c.fl_gen):
			_low_attach_cached(c, si, cache)
			return 1
		c.low_cache.erase(si)  # stale data — the cached emit is unusable
	var entry := {
		"low": true, "key": key, "cx": int(c.cx), "cz": int(c.cz),
		"inst": c.get_instance_id(), "colgen": int(c.col_gen), "si": si,
		"tier": tier,  # AC-0252: 1 = MED (grid 8), 2 = LOW (grid 4)
		"slabs": mc.slab_copy(c.data),  # the full column (~20 KB; the C++ emit reads si-1/si/si+1)
		# AC-0247: the slab BUFFER of this value copy stays on C++ alloc —
		# slab_copy allocates the "i"/"p" buffers internally (no C++
		# changes allowed), and a GDScript pooled copy measured ~230 us/col
		# (per-byte loop, 98 us/4096 B) vs the C++ copy's ~9 us/col — a
		# net CPU regression that would fight the "main stays smooth" goal.
		# Lifetime was proven (the entry is the last consumer — the poll
		# returns the buffers at handoff); the keep-on-alloc is perf-driven.
		"ms": _low_ms_snap_get(),
		"fcc": _lod_fcc_get(),  # AC-0252: the face-color cache (256x18 floats)
		"stamp": c.stamp(),
		"t_submit": Time.get_ticks_usec(),
	}
	var skey := _tm_next_slot
	_tm_next_slot += 1
	# the same shared 6-thread pool the high builds ride (HIGH priority,
	# like the high dispatch). While the AC-0231 order gate is CLOSED the
	# pool is idle — exactly the window the low lane needs workers; when
	# it opens the low lane has essentially drained (it outruns arrival).
	var tid = threadmesh_pool.add_task(_tm_worker_run.bind(skey), true)
	entry["tid"] = tid
	entry["skey"] = skey
	_tm_slots_mutex.lock()
	_tm_slots[skey] = entry
	_tm_slots_mutex.unlock()
	_low_tasks.append(entry)
	_low_task_keys[lkey] = true
	low_enqueue_n += 1
	return 1

# AC-0236 part 2: the MAIN-THREAD attach of a completed low emit — the
# bookkeeping half of _low_build_slab (the worker did the grid sample +
# greedy mesh in C++): fog swap, per-slab stamp, the all-air terminal
# mark. A dropped result (null / stale data / chunk gone) needs no
# re-queue: the slab is still PENDING in the chunk state (fog_slabs /
# low_stamps), so the in-r pass or the far wave re-picks it next frame.
func _low_handoff(e: Dictionary, res) -> void:
	var key: String = e["key"]
	var si := int(e["si"])
	_low_task_keys.erase(key + ":" + str(si))
	var c = chunks.get(key)
	# AC-0247: + col_gen — a pooled column REUSE keeps its instance_id, so
	# the inst check alone cannot see a freed-and-respawned column.
	if c == null or int(c.get_instance_id()) != int(e["inst"]) or int(c.col_gen) != int(e.get("colgen", -1)):
		low_drop_stale_n += 1
		return
	if res == null or int(c.data_gen) != int(e["stamp"][0]) or int(c.fl_gen) != int(e["stamp"][1]):
		low_drop_stale_n += 1
		return
	if si < 0 or si >= c.data.size():
		low_drop_stale_n += 1
		return
	# AC-0257 (stale-LOD, absorbs AC-0256): the low-start boundary moved
	# while the task was in flight — the mesh was emitted at the DISPATCH
	# tier. CACHE AND KEEP: the finished mesh goes to the per-slab cache
	# (flip-back to that tier is an attach, no re-emit); the currently
	# VISIBLE mesh stays showing (the last tier-matching one — no holes);
	# the slab stays PENDING against its live tier (low_tiers differs —
	# the lane re-picks and re-lowers it at the live tier next frame).
	# An all-air result at a stale tier says nothing about the live tier
	# (the air rule is per grid resolution) — it is not terminal-marked.
	if _lod_tier_of(int(c.cx) - last_pcx, int(c.cz) - last_pcz) != int(e.get("tier", 1)):
		low_drop_stale_n += 1
		if not bool(res.get("empty", false)):
			c.low_cache[si] = {
				"tier": int(e.get("tier", 1)),
				"dgen": int(c.data_gen),
				"fgen": int(c.fl_gen),
				"v": res["v"], "i": res["i"], "n": res["n"], "c": res["c"],
				"mh": float(res.get("mh", 0.0)),
			}
			low_cache_kept_n += 1
		return
	# AC-0257: a PRE-START early-out (the tier moved while the task was
	# queued — the worker never emitted): nothing to attach or cache; the
	# slab stays PENDING against its live tier.
	if bool(res.get("skipped", false)):
		low_drop_stale_n += 1
		return
	var was_low: bool = c.has_low_si(si)
	if bool(res.get("empty", false)):
		# all-air at the sample points (the _low_build_slab mesh == null
		# bookkeeping — the fog is the honest placeholder, marked
		# TERMINAL so the picks advance past it until the data changes).
		_low_drop_slab(c, si)
		c.low_stamps.erase(si)
		if c.data[si] == null:
			_fog_drop_slab(c, si)
		else:
			# AC-0240: flag-gated (the terminal mark stays - wave advance).
			if FOG_WAVE_ON and not c.has_fog_si(si):
				_fog_ensure_slab(c, si)
			c.low_failed[si] = c.data_gen
			_low_probe_invalidate(c)  # AC-0262: terminal mark -> not pending
	else:
		# AC-0252: the avg-color surface (vertex color, NO UVs — the noise
		# shader material owns the surface; the textured low's "u" array is
		# gone from the active path).
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _low_surface(res["v"], res["i"], res["n"], res["c"]))
		low_max_h = maxf(low_max_h, float(res.get("mh", 0.0)))
		_low_place_slab(c, si, mesh)
		if _low_first_attach_frame < 0:
			_low_first_attach_frame = Time.get_ticks_msec()  # AC-0263: section-first evidence
		_fog_drop_slab(c, si)
		c.low_built = true
		c.low_failed.erase(si)
		_low_probe_invalidate(c)  # AC-0262: the un-mark re-pends the slab
		# PER-SLAB stamp (the _low_build_slab comment: a chunk-level stamp
		# would keep the other fogged slabs' finished neighbors stale and
		# the wave would re-pick the built slabs forever).
		c.low_stamps[si] = c.stamp()
		c.low_tiers[si] = int(e.get("tier", 1))  # AC-0252: the band tier stamp
		# AC-0257: the attached tier is VISIBLE now — a cache entry at the
		# same tier is redundant (the cache holds the non-visible tier).
		if int(c.low_cache.get(si, {}).get("tier", -1)) == int(e.get("tier", 1)):
			c.low_cache.erase(si)
		if was_low:
			low_rebuilds_n += 1
		else:
			low_built_n += 1
	low_handoff_n += 1

# AC-0236 part 2: attach the COMPLETED low tasks (wall-clock capped — an
# attach is a node create + fog swap, ~0.2 ms). Runs every frame from
# _low_step so a ready placeholder lands without waiting for a high
# handoff (the high lane keeps its own stream_ho_cap pace in
# threadmesh_poll). The cap clamps to the frame wall time (the in-r step
# pattern: at 600 fps a flat 4 ms cap would eat the whole 1.67 ms step).
func _low_poll(dt_ms: float) -> void:
	if _low_tasks.is_empty():
		return
	var budget_ms := minf(LOW_POLL_BUDGET_MS, maxf(dt_ms * 0.25, 1.0))
	var t0 := Time.get_ticks_usec()
	var i := 0
	while i < _low_tasks.size():
		var e: Dictionary = _low_tasks[i]
		var tidv = e.get("tid", null)
		if tidv == null:
			# AC-0203 torn-read guard (the worker is mid-write on this
			# Dictionary) — skip this frame; the next poll sees a
			# consistent dict.
			i += 1
			continue
		if not threadmesh_pool.is_task_completed(int(tidv)):
			i += 1
			continue
		_low_tasks.remove_at(i)
		var skey = int(e.get("skey", -1))
		if skey >= 0:
			_tm_slots_mutex.lock()
			_tm_slots.erase(skey)
			_tm_slots_mutex.unlock()
		threadmesh_handoff(e, e.get("result", null))
		if (Time.get_ticks_usec() - t0) / 1000.0 >= LOW_POLL_BUDGET_MS:
			return

# AC-0231 rewrite: drop the low for ONE slab (the slab kept/restore its
# fog, or became air).
func _low_drop_slab(c: Node3D, si: int) -> void:
	var i: int = c.low_slabs.find(si)
	if i < 0:
		return
	var mi: MeshInstance3D = c.low_instances[i]
	if mi != null:
		_mi_checkin(mi)  # AC-0247: pool (the per-slab ArrayMesh data frees by refcount)
	c.low_slabs.remove_at(i)
	c.low_instances.remove_at(i)
	c.low_mask &= ~(1 << si)  # AC-0237 1a: mirror mask sync
	if c.low_slabs.is_empty():
		c.low_built = false
		c.low_stamps = {}
	_low_probe_invalidate(c)  # AC-0262: a drop re-pends the slab

# AC-0231 rewrite: place/replace the per-slab low instance (slab-local
# 0..16 geometry at (0, si*16, 0), sorted by slab index).
func _low_place_slab(c: Node3D, si: int, mesh: ArrayMesh) -> void:
	var _wpt := Time.get_ticks_usec()  # AC-0251 MESHATTACH sub-stage
	var i := 0
	while i < c.low_slabs.size() and int(c.low_slabs[i]) < si:
		i += 1
	var mi := _mi_checkout()  # AC-0247: pool (per-slab ArrayMesh from the C++ low_emit handoff)
	mi.mesh = mesh
	# AC-0252: the placeholder slabs are AVERAGE-COLOR (vertex color, no
	# UVs) — they wear the noise shader material, not the textured-low
	# opaque material (the textured emit is dormant with the band split).
	mi.material_override = _lod_avg_mat()
	mi.position = Vector3(0.0, float(si * 16), 0.0)
	c.add_child(mi)
	if i < c.low_slabs.size() and int(c.low_slabs[i]) == si:
		var old: MeshInstance3D = c.low_instances[i]
		if old != null:
			_mi_checkin(old)  # AC-0247: pool (the replacement attach above is identical)
		c.low_instances[i] = mi
	else:
		c.low_slabs.insert(i, si)
		c.low_instances.insert(i, mi)
		c.low_mask |= (1 << si)  # AC-0237 1a: mirror mask sync
	_low_probe_invalidate(c)  # AC-0262: an attach completes the slab
	_wprof_add(WP_MESHATTACH, Time.get_ticks_usec() - _wpt)

# AC-0231 fix3: the atlas TEXTURE SWAP re-merges the strip table
# (_tm_ms_full) — the merged-atlas strip POSITIONS move (a different
# unique-rect set re-packs the 512x128 rows), so every EXISTING low mesh
# keeps the OLD strip UVs and samples the wrong texture on the new canvas
# (the "wrong texture mapping" the user reported at distance). The HIGH
# meshes recover through the tex_refresh drain (every chunk re-pushed),
# the fog box is a flat color (no UVs), but the lows are main-thread
# MeshInstance3Ds that only the slab wave (re)builds — so on a swap, drop
# every low and restore its fog; the WAVE 2 slab wave re-lowers all of
# them against the new table within a few hundred frames.
func _low_reset_all() -> void:
	# the tile-base cache (_low_tile_base) is keyed by (id, fi) only —
	# after a table re-merge the cached origins are the OLD strip
	# positions, so the cache must go with the tables.
	_low_tl.clear()
	_low_probe_cache.clear()  # AC-0262: every slab re-pends on a re-lower
	# AC-0252: the face-color cache averages the NEW atlas pixels — the
	# cached colors are the OLD pack's averages until rebuilt.
	_lod_fcc_dirty = true
	for key in chunks:
		var c: Node3D = chunks[key]
		if int(c.face) > 1 or c.low_slabs.is_empty():
			continue
		for si in c.low_slabs.duplicate():
			var si2 := int(si)
			_low_drop_slab(c, si2)
			if not c.data.is_empty() and si2 < c.data.size() and c.data[si2] != null:
				_fog_ensure_slab(c, si2)
		# c.low_stamps was already cleared by the last _low_drop_slab (the
		# empty-low reset); c.low_failed stays — its marks are keyed by
		# data_gen, which the atlas swap does NOT change (the terminal-fog
		# verdicts survive: re-picking them would just re-fail the sample).
	_low_slab_none_key = ""
	_low_none_key = ""

# AC-0231 rewrite: the high REPLACES the per-slab placeholders — free the
# fog MultiMesh + every per-slab low. as_upgrade counts a
# placeholder->high replacement (the catch-up evidence); the evict path
# frees without counting. Keep-high from here on: a meshed chunk is never
# downgraded to low (low_downgrade_n stays 0 — the low path only serves
# never-built slabs).
func _lod_free_all(c: Node3D, as_upgrade: bool) -> void:
	if as_upgrade and (bool(c.low_built) or c.has_fog()):
		low_upgrades_n += 1
	if c.has_fog():
		low_fog_boxes_n -= int(c.fog_slabs.size())
		low_fog_chunks_n -= 1
	c.drop_low()
	_low_probe_invalidate(c)  # AC-0262: drop_low re-pends the slabs

# AC-0231 fix3 / AC-0250: the WAVE 3 idle-catch-up pick — scan the waiting
# streaming queue (band_buckets, in rank order) for the first LOW-HOLDING
# entry with no high. Order: tier 1 (sim radius, nearest first — the
# rank-ordered scan finds it) first, then the rest (tier 2) by the AC-0233
# e["rank"] taxi stamp (look-independent). TIER 0 (under the player) is
# never a candidate — it goes straight to high (fall/step-through never).
# (The WAVE 2 low pick is now slab-level and global — _low_scan_slabs.) The
# no-candidate verdict is cached against (pool_ver, pcx, pcz): a candidate
# can only APPEAR on a pool-state change (data landing / handoff /
# recenter — all _pool_touch) or a dirty edit (_dirty_add invalidates the
# key), so a matching key means a fresh scan finds nothing.
func _low_pick(want_low: bool) -> Dictionary:
	var nk := "%d|%d,%d|%d" % [_pool_ver, last_pcx, last_pcz, 1 if want_low else 0]
	if nk == _low_none_key:
		return {}
	# AC-0257: the bake order — the AC-0233 (sim-tier, taxi) f1/f2 pick is
	# replaced by the (layer, taxi) grid score: the entry whose BEST PENDING
	# SLAB is nearest the player's Y wins, taxi breaking layer ties.
	var best: Dictionary = {}
	var best_s := 1e30
	var capped := false
	var stop := false  # the scan-cap early exit (beats the outer loop too)
	var visited := 0
	for b in range(band_buckets.size()):
		if stop:
			break
		var arr: Array = band_buckets[b]
		for i in range(arr.size()):
			if stop:
				break
			visited += 1
			if visited > LOW_SCAN_CAP:
				capped = true
				stop = true
				break
			var e: Dictionary = arr[i]
			var dx := int(e["cx"]) - last_pcx
			var dz := int(e["cz"]) - last_pcz
			# AC-0257: the tier-0 set (Chebyshev ball around the player
			# column) must NEVER be a placeholder (high only — fall /
			# step-through under the player).
			if _is_tier0_col(dx, dz):
				continue
			# AC-0261: only HIGH-band columns are upgrade candidates — the
			# catch-up's whole job is a low-holding column ENTERING the high
			# band (the player approached it). The visible band [band0_r,
			# render_radius) keeps its avg LOD as the final LOD.
			if absi(dx) + absi(dz) >= medium_start_r:
				continue
			var c = chunks.get(e["key"])
			if c == null or c.data.is_empty() or bool(c.mesh_built):
				continue
			# PER-SLAB staleness (AC-0231 fix3): the WAVE 2 pick dispatches
			# only for chunks whose LOW slabs are ALL fresh.
			var stale := _low_any_stale(c)
			if want_low:
				# AC-0261: the stale-low gate is gone — every candidate is
				# a HIGH-band column (the band gate above) whose low was
				# built at a FARTHER tier (that is why it is stale at the
				# live tier 0). The high build REPLACES every placeholder
				# (the handoff frees them) and reads the current data, so
				# the low's tier stamp is irrelevant.
				if not bool(c.low_built):
					continue
				# the idle upgrade must not force a sync fallback — a
				# missing neighbor would stall the main thread 300-1200 ms;
				# such a chunk keeps its low (far filler) until ready.
				if not _low_upgrade_ready(int(e["cx"]), int(e["cz"])):
					continue
			else:
				if bool(c.low_built) and not stale:
					continue
				if not c.has_fog() and not bool(c.low_built):
					continue  # nothing fogged to replace
			var s := _grid_score(e)
			if s < best_s:
				best_s = s
				best = e
	# cache the "none" verdict only for a FULL scan (a capped scan may have
	# left a candidate past the cap).
	if best.is_empty() and not capped:
		_low_none_key = nk
	else:
		_low_none_key = ""
	return best

# AC-0231: the heavy pipeline is caught up — the drain dispatched nothing
# this frame, the TG pool drained, no recenter in flight, past the grace.
func _low_idle() -> bool:
	var idle := _drain_units_last == 0 and threadgen_inflight.is_empty() \
			and not loading_active and not _spawn_fast and not _rec_pending
	if idle:
		_low_idle_frames += 1
	else:
		_low_idle_frames = 0
	return _low_idle_frames >= LOW_IDLE_GRACE_FRAMES

# AC-0231 rewrite: the legacy SYNC build fallbacks (data-empty,
# missing-neighbor, cap-drop with defer_on_cap=false, create_chunk
# mesh_now) establish a high mesh WITHOUT the worker handoff — the
# per-slab placeholders must be dropped here or the fog/low renders on
# top of the fresh high.
func _low_drop_sync(c: Node3D) -> void:
	_lod_free_all(c, true)

# AC-0231: idle-upgrade dispatchability — all 8 neighbors hold data. A
# missing neighbor would force the sync fallback (a 300-1200 ms MAIN-thread
# build, exactly what AC-0160 eliminated); a far chunk whose neighbor is
# outside the streaming set never becomes ready, so it stays a low — the
# intended far filler (the "rest" the catch-up upgrades once the region is
# fully data-complete).
func _low_upgrade_ready(cx: int, cz: int) -> bool:
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			if dx == 0 and dz == 0:
				continue
			var nc = chunks.get(_key(cx + dx, cz + dz))
			if nc == null or nc.data.is_empty():
				return false
	return true

# AC-0231 fix3: the WAVE 2 pick — the pending slab with the SMALLEST si
# across ALL columns (pending = a fogged slab not yet lowed, or a low slab
# to rebuild on a stale chunk); ties break by scan order (band_buckets is
# rank-ordered — the AC-0233 e["rank"] taxi stamp, bucketed by distance).
# The wave therefore sweeps the WHOLE region bottom-up, every column at
# once — all si=0 slabs first, then all si=1, ... — NEVER one whole column
# before the next (the per-column sequential fill the user rejected). Tier
# 0 (under the player) is never a placeholder. The no-candidate verdict is
# cached against (pool_ver, pcx, pcz): a pending slab can only APPEAR on a
# pool-state change (data landing / handoff / recenter — all _pool_touch)
# or a dirty edit (_dirty_add invalidates the key), and it LEAVES the
# pending set only on our own build (which clears the key). Returns
# {key, cx, cz, si} ({} = none).
var _low_slab_none_key := ""  # the WAVE 2 none-verdict cache (pool_ver, pcx, pcz)
var _slab_wave_last_t := 0    # AC-0231 fps-tuning: wall usec of the previous low frame
var _slab_wave_acc_ms := 0.0  # the far slab wave's wall-clock accumulator
# AC-0231 order gate: true = a full scan + the LOW_INR_STABLE_MS stability
# window proved no in-r pending chunk (the tier >= 2 high dispatch may run).
# Closed by _low_inr_invalidate() (in-r data landing / in-r edit / recenter /
# pause exit) — see the const block.
var _low_inr_drained := false
var _low_inr_drain_since := 0  # wall ms the drain was first observed (0 = unknown)

# AC-0262: ONE candidate scan per frame, batched for the wave loop (was:
# up to LOW_WAVE_FRAME_CAP full O(band) scans per frame — 8 x ~2000 visits
# x ~13 us = the 126-213 ms/frame LOW_PICK of the R30 standing storm, the
# whole LOW stage; wprof baseline .scratch/wprof_ac0262_r30.log).
#
# The bake order is unchanged — (layer rank, taxi): the pending slab
# nearest the player's Y builds first, taxi breaking layer ties (k =
# rank*10000 + taxi, taxi < 10000 always, so the order is lexicographic).
# The scan walks the band buckets in ASCENDING taxi (bucket index = taxi,
# see _enqueue_build), so within a layer rank the first seen candidate is
# that rank's best (smallest taxi). It collects, per rank, the first
# candidates in taxi order (each list capped at n — a rank's (n+1)th
# candidate can never make the best n) and stops early when the frame's
# needs are met: n rank-0 candidates (rank 0 is the best CLASS — nothing
# smaller exists, so unscanned entries cannot displace any of them). Any
# other stop condition would be unsafe — an unscanned rank-0 (or a
# smaller-rank) candidate can always exist past the scan point — so the
# mid-storm case (the band at a uniform depth > 0, no rank-0 pending)
# takes the full capped scan, made cheap by _entry_best_pending_cached
# (~2 us/visit instead of ~13 us).
func _low_scan_slabs(n: int) -> Array:
	var nk := "%d|%d,%d|slab" % [_pool_ver, last_pcx, last_pcz]
	if nk == _low_slab_none_key:
		return []
	var per_rank: Dictionary = {}  # rank -> Array of candidates (taxi order)
	var capped := false
	var visited := 0
	for b in range(band_buckets.size()):
		var arr: Array = band_buckets[b]
		for i in range(arr.size()):
			visited += 1
			if visited > LOW_SCAN_CAP:
				capped = true
				break
			var e: Dictionary = arr[i]
			var dx := int(e["cx"]) - last_pcx
			var dz := int(e["cz"]) - last_pcz
			if _is_tier0_col(dx, dz):
				continue  # AC-0257: the tier-0 set is high only (never a placeholder)
			# AC-0261: the wave covers the visible band [band0_r, render_radius)
			# — the high band below it is the build lane's (pending renders
			# nothing), and past the (taxi) render distance nothing renders.
			var taxi := absi(dx) + absi(dz)
			if taxi < medium_start_r or taxi >= render_radius:
				continue
			var c = chunks.get(e["key"])
			if c == null or c.data.is_empty() or bool(c.mesh_built):
				continue
			var si := _entry_best_pending_cached(c)  # AC-0262: probe cache
			if si < 0:
				continue
			var lr := _layer_rank_of(si)
			if not per_rank.has(lr):
				per_rank[lr] = []
			var list: Array = per_rank[lr]
			if list.size() < n:
				list.append({"key": e["key"], "cx": e["cx"], "cz": e["cz"], "si": si})
			# AC-0262 early stop: the frame is satisfied by rank 0 alone —
			# rank 0 has k = taxi and every other rank has k >= 10000 > any
			# rank-0 k, so n rank-0 candidates in taxi order ARE the global
			# best n and the rest of the band cannot displace them. (The
			# outer loop re-checks after this inner break and stops.)
			if lr == 0 and per_rank[0].size() >= n:
				break
		if capped:
			break
		var r0 = per_rank.get(0, null)
		if r0 != null and r0.size() >= n:
			break
	# assemble in k order: rank 0 (taxi order), then ranks ascending
	var out: Array = []
	if per_rank.has(0):
		for cand in per_rank[0]:
			out.append(cand)
			if out.size() >= n:
				break
	if out.size() < n:
		var ranks := per_rank.keys()
		ranks.sort()
		for r in ranks:
			if r == 0:
				continue
			for cand in per_rank[r]:
				out.append(cand)
				if out.size() >= n:
					break
			if out.size() >= n:
				break
	# cache the "none" verdict only for a FULL scan (a capped scan may have
	# left a candidate past the cap).
	if out.is_empty() and not capped:
		_low_slab_none_key = nk
	else:
		_low_slab_none_key = ""
	return out

# AC-0261: the in-r pre-low lane is DEAD (the per-column MED placeholder
# pass) — pending slabs in the high band render NOTHING and the visible
# band [band0_r, render_radius) is lowered per slab by the disc-ordered
# wave. The order gate can never close again.
func _low_inr_invalidate() -> void:
	_low_inr_drained = true
	_low_inr_drain_since = 0

# AC-0231 in-r pre-low pick: the lowest-scoring INSIDE-circle pending chunk
# (data + no mesh + at least one pending slab, tier 0 or higher). Score =
# the AC-0233 (tier, taxi) lexicographic — the SAME order the TM high
# dispatch uses, so the low frontier leads the high frontier in the same
# order. Tier 0 (under the player) is high only. While the order gate is
# open (_low_inr_drained) this is a single bool read; a pending chunk can
# only APPEAR on an in-r data landing / in-r edit / recenter (all call
# _low_inr_invalidate), and it LEAVES the pending set only on our own build.
# The drained verdict requires a FULL scan plus LOW_INR_STABLE_MS of
# continuous drain (a capped scan proves nothing — the gate stays closed).
func _low_inr_pick() -> Dictionary:
	if _low_inr_drained:
		return {}
	var best: Dictionary = {}
	var best_s := 1e30
	var visited := 0
	var r2 := render_radius * render_radius
	for b in range(band_buckets.size()):
		var arr: Array = band_buckets[b]
		for i in range(arr.size()):
			visited += 1
			if visited > LOW_INR_SCAN_CAP:
				return {}  # capped — do NOT prove drained
			var e: Dictionary = arr[i]
			var dx := int(e["cx"]) - last_pcx
			var dz := int(e["cz"]) - last_pcz
			if dx * dx + dz * dz > r2:
				continue  # in-r lane: circle only (the far slab wave owns the outside)
			if _is_tier0_col(dx, dz):
				continue  # AC-0257: the tier-0 set is high only (never a placeholder)
			var c = chunks.get(e["key"])
			if c == null or c.data.is_empty() or bool(c.mesh_built):
				continue
			if int(c.face) > 1 or not (c.has_fog() or bool(c.low_built)):
				continue
			if _entry_best_pending_cached(c) < 0:  # AC-0262: probe cache
				continue  # no pending slab (all terminal-fog / fresh lows)
			var s := _grid_score(e)  # AC-0257: the bake order (layer, taxi)
			if s < best_s:
				best_s = s
				best = e
	if best.is_empty():
		var now := Time.get_ticks_msec()
		if _low_inr_drain_since == 0:
			_low_inr_drain_since = now
			return {}  # start the stability window
		if now - _low_inr_drain_since >= int(LOW_INR_STABLE_MS):
			_low_inr_drained = true  # the gate opens
		return {}
	_low_inr_drain_since = 0  # pending found — the stability window restarts
	return best

# AC-0231 in-r pre-low step: within the frame budget (a FRACTION of the
# measured frame wall time, clamped — fps-independent), fully lower the
# pending slabs of the lowest-tier-score in-r chunks (fog -> low per slab),
# one chunk at a time, in the same order the high builds land. While the
# order gate is closed (in-r low pending), the BUSY budget applies — the
# tier >= 2 high dispatch is held, and its frame share goes to the low. A
# partial chunk resumes next frame (its slabs stay pending).
func _low_inr_step(dt_ms: float) -> void:
	# AC-0261: dead lane — no more per-column MED placeholders (pending
	# slabs render nothing inside the high band; the slab wave owns the
	# visible band per slab). The gate stays open.
	_low_inr_drained = true

# AC-0231 fix3: the per-frame far-LOD lane (a separate lane — never the
# TG/TM pools). The three waves are GLOBAL across all columns (never
# per-column sequential): WAVE 1 fog = on EVERY data landing (all
# non-air slabs of that column, before any low of it exists); WAVE 2 low
# = here — TWO lanes, both WALL-CLOCK paced (fps-independent, see the
# const block): (2a) the in-r pre-low — INSIDE-circle pending chunks
# fully lowered in the AC-0233 (tier, taxi) order (the same order the
# high builds land, so the low frontier leads the high frontier), and
# (2b) the far global slab wave — OUTSIDE the circle, the smallest slab
# index first across all columns; WAVE 3 high = the AC-0233 tiers + the
# idle catch-up below (low-holding columns dispatched to the TM path as
# the heavy pipeline drains).
func _low_step() -> void:
	if _shutting_down or _low_fog_mesh == null:
		return
	# AC-0231 fps-tuning: the frame's WALL-CLOCK duration (clamped) — the
	# pacing basis for both low lanes (identical build pace at 30-60 fps).
	var now_t := Time.get_ticks_usec()
	var dt_ms := 16.67
	if _slab_wave_last_t > 0:
		dt_ms = minf((now_t - float(_slab_wave_last_t)) / 1000.0, 100.0)
	_slab_wave_last_t = now_t
	# the fog color tracks the sky (the same color env.fog_light_color gets).
	_low_fog_mat.albedo_color = DayNight.sky_display(Game.time_of_day)
	# AC-0252 (the AC-0261 follow-up): the med/low avg-color LODs track the
	# sky's BRIGHTNESS — a GRAY derived from the sky color's average — not
	# the sky's hue. AC-0252 originally passed the sky color itself; the
	# midday sky-blue (0.53,0.81,0.92) multiplied into every albedo pulled
	# bright warm surfaces toward cyan (midday sand -> mint green). The
	# night darkening is preserved (night sky avg ~= 0.07, same as before).
	# The sky color changes slowly, so the per-frame set is skipped when
	# unchanged (set_shader_parameter touches the material — keep it out of
	# the hot main-thread LOW stage).
	if _lod_avg_material != null:
		var sdc := _low_fog_mat.albedo_color
		var dl := (sdc.r + sdc.g + sdc.b) / 3.0
		var day_c := Color(dl, dl, dl)
		if not _lod_day_last.is_equal_approx(day_c):
			_lod_day_last = day_c
			_lod_avg_material.set_shader_parameter("day", day_c)
	if loading_active or _spawn_fast:
		# AC-0231 order gate: the in-r pass was paused — on resume the
		# drained verdict is stale (fog may have landed meanwhile).
		_low_inr_invalidate()
		return
	if _low_idle():
		# WAVE 3 catch-up: dispatch the best low-holding entry to high
		# through the normal TM path (nearest sim-radius entry first, then
		# the rest by taxi) — one dispatch/frame. (NOT a return: WAVE 2
		# below must drain to completion even while the heavy pipeline is
		# idle — an atlas swap's re-lower must not wait for the player to
		# move, and the wave model is all-fog -> all-low -> all-high.)
		for _u in range(LOW_UPGRADE_PER_FRAME):
			var e: Dictionary = _low_pick(true)
			if e.is_empty():
				break
			var c = chunks.get(e["key"])
			if c == null or not bool(c.low_built):
				# the low vanished (a handoff raced us) — the none-key is
				# stale; force a rescan next frame.
				_low_none_key = ""
				continue
			var dxu := int(e["cx"]) - last_pcx
			var dzu := int(e["cz"]) - last_pcz
			if _tier_of(dxu, dzu) >= 2 and not _low_inr_drained:
				break  # AC-0231 order gate: the far high waits for the in-r lows
			# AC-0263: the upgrade is PER-SLAB — dispatch the column's best
			# pending high slab (the entry stays queued for the rest; the
			# full-column dispatch is gone).
			var sih := _hslab_best_pending_cached(c)
			if sih < 0:
				# high-complete (a landing raced the pick) — the candidate
				# is stale; force a rescan next frame.
				_low_none_key = ""
				continue
			if _build_unit_hslab(c, int(e["cx"]), int(e["cz"]), sih):
				break  # deferred (the TM pool is full) — retry next frame
	# AC-0236 part 2: attach the completed low emits FIRST (a ready
	# placeholder lands this frame — the emit started the moment the data
	# landed, not when the main-thread pass got to it), then dispatch.
	# AC-0262: sub-stage brackets — the LOW stage is split for the perf
	# hunt: POLL (the attach poll, incl. mesh create), INR (dead since
	# AC-0261 — stays bracketed to confirm zero), WAVE (the dispatch loop,
	# residual = dispatch+air), PICK (the candidate scan per dispatch).
	var _wpt2 := Time.get_ticks_usec()
	_low_poll(dt_ms)
	_wprof_add(WP_LOW_POLL, Time.get_ticks_usec() - _wpt2)
	_wpt2 = Time.get_ticks_usec()
	# WAVE 2a: the in-r pre-low — tier-ordered, budget = a fraction of the
	# frame wall time (LOW_INR_BUDGET_FRAC, clamped).
	_low_inr_step(dt_ms)
	_wprof_add(WP_LOW_INR, Time.get_ticks_usec() - _wpt2)
	_wpt2 = Time.get_ticks_usec()
	# WAVE 2b: the global slab wave — the visible band [band0_r,
	# render_radius) (AC-0261: the high band below it is build-lane only,
	# nothing renders past the taxi render edge), wall-clock paced
	# (LOW_WAVE_PACE_MS per slab), the (layer, taxi) disc order across all
	# columns (the per-column sequential fill is gone: every column's
	# player-Y slab lands before any column's next layer). The acc is
	# clamped to one frame cap's worth (a stall never catches up in a
	# burst). No-candidate verdicts are cached (zero cost between
	# landings/edits — a drained wave is a couple of dict ops).
	_slab_wave_acc_ms = minf(_slab_wave_acc_ms + dt_ms, float(LOW_WAVE_FRAME_CAP) * LOW_WAVE_PACE_MS)
	# AC-0262: ONE batched scan per frame (was: up to LOW_WAVE_FRAME_CAP
	# full O(band) scans — the R30 storm's 126-213 ms/frame LOW_PICK),
	# then dispatch the k-ordered candidates the pace allows.
	var _wpt3 := Time.get_ticks_usec()  # AC-0262: the batched scan
	# AC-0263: the TIER-0 SECTION is its own phase — the wave (med/low)
	# does not START until the section's high builds are complete (the
	# section builds through the drain, which the score prefix keeps ahead
	# of the rings). ONE-SHOT: once the wave has landed its first attach,
	# the gate stays open — a recenter's new tier-0 column then builds
	# through the drain without stalling the wave (a re-gate at every
	# crossing would hitch it). The check rides the per-chunk probe cache
	# (the ball is 1 column by default; max 289).
	var wave_cands: Array = []
	if _wave_gate_open or _tier0_section_drained():
		_wave_gate_open = true
		wave_cands = _low_scan_slabs(LOW_WAVE_FRAME_CAP)
	_wprof_add(WP_LOW_PICK, Time.get_ticks_usec() - _wpt3)
	var _wpt4 := Time.get_ticks_usec()  # AC-0262: dispatch-only (disjoint)
	var wave_n := 0
	for e2 in wave_cands:
		if _slab_wave_acc_ms < LOW_WAVE_PACE_MS:
			break
		var c2 = chunks.get(e2["key"])
		if c2 == null or c2.data.is_empty() or bool(c2.mesh_built):
			# the candidate went stale (a handoff/recenter raced) —
			# rescan next frame.
			_low_slab_none_key = ""
			break
		# AC-0236 part 2 / AC-0250 / AC-0252 offload: the grid sample +
		# emit ride the TM pool (ZERO generation on the main thread); the
		# -1 verdict (null slab only) takes the air bookkeeping via
		# _low_air_slab (scene/state work — no sampling, no emit); the 0
		# dedupe verdict and the 2 saturated verdict just consume the pace
		# tick — the slab stays PENDING, the in-flight result attaches via
		# _low_poll, and the wave re-scans when it lands / next frame.
		if _low_dispatch_slab(c2, int(e2["si"])) < 0:
			_low_air_slab(c2, int(e2["si"]))
		_low_slab_none_key = ""  # a slab left the pending set — rescan
		_slab_wave_acc_ms -= LOW_WAVE_PACE_MS
		wave_n += 1
	_wprof_add(WP_LOW_WAVE, Time.get_ticks_usec() - _wpt4)  # AC-0262

# AC-0109 cull-pass scratch (world-level only — no per-chunk state, no
# per-frame allocations growing with chunk count; all fixed-size, filled
# once per camera-transform change).
# AC-0212: cull_mode = the active frustum-cull source. "engine" (DEFAULT) —
# rely on the render server's automatic per-MeshInstance3D frustum cull
# (no GDScript pass at all). "manual" — the AC-0109 per-frame pass below
# (kept for A/B + fallback; set via AWECRAFT_FRUSTUM, see the margin const).
var cull_mode := "engine"
# AC-0109/AC-0212 probe counters (harness-readable, updated by whichever
# lane is active). Engine mode: both stay 0 (the pass never runs — that IS
# the counter reading: no manual cull work). Manual mode: passes = full
# re-evaluations (camera-transform-change frames), flips = per-instance
# visible state changes written.
var perf_cull_passes := 0
var perf_cull_flips := 0
var _cull_enabled := false
var _cull_cam_xform := Transform3D()
var _cull_planes: Array = []
var _cull_col_span := PackedFloat32Array()
var _cull_slab_span := PackedFloat32Array()
var _cull_ny := PackedFloat32Array()
var _cull_dc := PackedFloat32Array()
var _cull_cen := Vector3()
var drain_budget_ms := DRAIN_MS_DEFAULT
# AC-0213: small-move (recenter) pacing state.
var _sm_move_until := 0        # drain budget drops to 1 unit/frame until this ms
var _last_recenter_ms := 0     # wall ms of the last recenter() entry
var _last_recenter_pcx := 0    # center of the last recenter (debounce delta)
var _last_recenter_pcz := 0
const SMALL_MOVE_BUDGET_MS := 1500
const AHEAD_RING_DEBOUNCE_MS := 1000
var _rec_pending := false
var _rec_pcx := 0
var _rec_pcz := 0
# AC-0233: the center of the in-flight (or last-finished) rebuild — the
# debounced-recenter coverage anchor (REBUILD_COVER_L1).
var _rec_center_pcx := 0
var _rec_center_pcz := 0
# AC-0233: outrun escalation parked while a walk is in flight (see
# recenter) — re-checked when the in-flight walk finalizes.
var _rec_escalate_pcx := -9999
var _rec_escalate_pcz := -9999
var _rec_phase := 0            # 0 WANT, 1 STUB, 2 MERGE_OLD, 3 MERGE_WANT, 4 MERGE_RING
var _rec_cursor := 0           # position in the current phase's domain
var _rec_i := 0
var _rec_want: Dictionary = {}
var _rec_want_keys: Array = []
var _rec_new_buckets: Array = []
var _rec_slice_total_ms := 0.0
var _rec_slice_max_ms := 0.0
var _rec_slice_frames := 0
var _rec_new_n := 0
var gen_budget_ms := -1
var last_build_us := 0
var last_pcx := 0
var last_pcz := 0
var timing := false
# AC-0217: pick-order trace (env AWECRAFT_PICKLOG=1) — one line per consumed
# drain pick (build / forward-lead / data) for the before/after pick-order A/B.
var _picklog := false
var _recprobe := false
var _rp_free_ms := 0.0
var _rp_stub_ms := 0.0
var _rp_stub_n := 0
var _rp_walk_ms := 0.0
var _rp_insert_ms := 0.0
var _rp_dequeue_ms := 0.0
var _rp_deq_n := 0
var _rp_drain_stub_ms := 0.0
var _rp_drain_stub_n := 0
var fluid_sleep := true
var tick_time := false
var _fluid_write := false
var _fluid_stable := 0
var _fluid_sig := ""
var _fluidprobe := false
var _frameprobe := false
var _fp_writes := 0
var fluid_wet := {}
var tex_refresh: Array = []
var threadgen := false
var threadgen_max := 3
var threadgen_pool = null
var threadgen_inflight: Array = []
var _tg_slots = {}
# AC-0197: slots dicts are read from pool worker threads (the
# AC-0152/AC-0178 spin-waits) while the main thread sets/erases
# them; a Godot Dictionary has no internal locking — the 22-min
# R50 perf soak segfaulted (signal 11) in _tm_worker_run's slot
# get. A mutex around every access; neutral otherwise.
var _tg_slots_mutex := Mutex.new()
var _tg_inflight_keys: Dictionary = {}
var _tg_debug := false
var _tg_enq := 0
var _tg_dedup := 0
var _tg_capdrop := 0
var _tg_handoff := 0
var _tg_stale := 0
var _tg_datadrop := 0
# AC-0107 threaded mesh+light (desktop): shared WorkerThreadPool, dedup by
# chunk key, in-flight cap, stale drop (node gone / data+fl changed).
var threadmesh := false
var threadmesh_max := 3
var threadmesh_pool = null
var threadmesh_inflight: Array = []


# AC-0257: (re)compute the in-flight worker caps. The caps scale to ALL
# available cores and never past them (oversubscription makes each task
# slower, which is exactly the stale-work risk the ticket calls out).
# Precedence per lane: Developer setting (>0) > env override > auto (the
# core count split 40/60 gen/mesh, min 1 each). The caps are software
# limits on the shared engine pool - note_worker_threads re-applies them
# LIVE from the Developer submenu (no restart). Supersedes the AC-0079 /
# AC-0160 fixed 4/6 caps.
func _apply_worker_thread_caps() -> void:
	var cores := maxi(1, OS.get_processor_count())
	var gen_auto := clampi(int(roundf(float(cores) * 0.4)), 1, maxi(1, cores - 1))
	var mesh_auto := cores - gen_auto
	var g := int(Settings.values.get("worker_gen_threads", 0))
	if g <= 0:
		var nenv := OS.get_environment("AWECRAFT_THREADGEN_N")
		g = maxi(1, nenv.to_int()) if nenv != "" else gen_auto
	threadgen_max = clampi(g, 1, 16)
	var m := int(Settings.values.get("worker_mesh_threads", 0))
	if m <= 0:
		var menv := OS.get_environment("AWECRAFT_THREADMESH_N")
		m = maxi(1, menv.to_int()) if menv != "" else mesh_auto
	threadmesh_max = clampi(m, 1, 16)


# AC-0257: the Developer submenu changed the worker-thread caps.
func note_worker_threads() -> void:
	_apply_worker_thread_caps()
# AC-0178: loading-screen state. loading_bypass comes from AWECRAFT_LOADBYPASS
# (headless A/B override: "0" = never enter the loading window, i.e. the
# legacy spread drain). While loading_active the drain/flush/save/I/O caps
# below are raised; stop_loading() restores the normal caps byte-for-byte.
var loading_bypass := true
var loading_active := false
# AC-0178: set in _exit_tree before the poll drain — a TG null-result retry
# must NOT re-enqueue at shutdown (the slot maps are cleared right after the
# drain; a retry task would spin its slot-spin, drop a null result, and
# re-enqueue forever past the drain cap).
var _shutting_down := false
var _load_done_once := false
var _loading_target := 0
var _loading_radius := 0
var _loading_screen = null
var _tg_max_norm := 3
var _tm_max_norm := 3
var _tm_slots = {}
var _tm_slots_mutex := Mutex.new()  # AC-0197: see _tg_slots_mutex
var _tm_inflight_keys: Dictionary = {}
var _tm_next_slot := 0
var threadmesh_edit_pool = null
var _tm_ctx: Dictionary = {}
var _tm_ms_full: Dictionary = {"tex": null, "rects": {}}
# AC-0160: atlas identity _tm_ctx was built against (null until the first
# build); _process re-points the ctx when it moves (post-bake/swap staleness
# blackened every worker-built mesh emitted from it).
var _tm_ctx_atlas: Texture2D = null
var _tm_debug := false
# AC-0160 run 2: 5x5 startup burst state. elems = [[cx, cz, had_data], ...]
# (index = group-task element id); slots = per-element result storage
# (worker i writes ONLY slots[i] — the AC-0082 own-slot handoff pattern).
var _startup_gen_elems: Array = []
var _startup_gen_slots: Array = []
# AC-0160 run 2: in-flight burst group task ids. A recenter whose burst is
# still running must NOT reset _startup_gen_elems/_startup_gen_slots: the
# in-flight workers index those arrays (a reset races them — measured in
# the boundary gate: "Invalid assignment of index '22'" crashes + a stale
# worker could write chunk A's terrain into chunk B's slot). The guard
# keeps the array stable until the group completes (see recenter()).
var _startup_gen_group_tids: Array = []
# AC-0160 run 2: the SPAWN fast path is one-shot. It gates the aggressive
# parts (data pass off, recenter-slice pause) so the burst + 3x3 build run
# unopposed at world start. It must NOT key on _startup_pending() (3x3
# around the center not built): that flag is true for the ENTIRE walking
# session (every recenter's forward 3x3 is unbuilt), which permanently
# disabled the data pass + queue rebuild and emptied the world ahead of the
# player (boundary gate regression: built_final=0, resident_final=0, 35 s
# drain stall). Cleared on the first frame the spawn 3x3 is built.
var _spawn_fast := true
# AC-0160 run 2: count of real burst gens not yet applied (main-thread
# bookkeeping; the apply pass decrements exactly once per slot). > 0 while
# the 5x5 is in flight — the drain holds all startup builds until it hits 0.
var _startup_gen_pending_n := 0
# AC-0263: burst wall-clock start (the dead-slot self-heal window).
var _startup_gen_started_ms := 0
var _tm_enq := 0
var _tm_dedup := 0
var _tm_capdrop := 0
var _tm_stale := 0
var _tm_datadrop := 0
var _tm_handoff := 0
# AC-0263: the per-slab lane's evidence counters (the r16 arm reads them).
# _tm_hslab_n = per-slab full-res landings; _tm_full_firstbuild_n = the
# legacy full-column path's FIRST builds (a chunk meshed for the first
# time by apply_accs — re-meshes by the light/fluid/tex lanes don't
# count). In the per-slab world the high band is hslab-built, so the
# full first-builds should stay near zero (a light-flush race at boot is
# the only expected source).
var _tm_hslab_n := 0
var _tm_full_firstbuild_n := 0
# AC-0263: the section-first order contract evidence (wall ms): the
# INITIAL tier-0 section's high completion (first tier-0 column to
# complete high after boot — a moving recenter's new section column does
# NOT reset it), and the FIRST textured-low attach (the wave's first
# landing). The contract: low_first >= section_done (the wave waits for
# the tier-0 section to drain — a ONE-SHOT gate: once the wave has
# started, a recenter's new tier-0 column builds through the drain
# without stalling the wave, or every chunk crossing would hitch it).
var _hslab_section_done_frame := -1
var _low_first_attach_frame := -1
var _wave_gate_open := false
# AC-0219: per-frame streaming handoff counter. threadmesh_poll can run up
# to twice per process frame (_physics_process_impl + _process, plus the
# recenter call), so the cap is keyed on the process frame, not the call.
var _stream_ho_frame := -1
var _stream_ho_n := 0
# AC-0224: the effective per-frame streaming handoff burst (the const
# default; AC-0225: refreshed every process frame in threadmesh_poll from
# the Settings "chunks_per_frame" value — the Options slider; _ready
# preloads that setting from AWECRAFT_TM_HO when set for the harness).
var stream_ho_cap := STREAM_TM_HANDOFF_PER_FRAME
# AC-0229: dynamic-budget state — the player's smoothed horizontal speed
# (m/s) + the previous position sample. Sampled once per process frame in
# the threadmesh_poll per-frame branch (the _stream_ho_frame guard), from
# the player's POSITION delta — not player.velocity, which is input-driven
# (lerped toward the held keys) and stays ~0 while a harness fly phase
# teleports player.position directly. _dyn_have_prev false = no sample yet
# (player absent) -> speed 0 = the still factor.
var _dyn_speed := 0.0
var _dyn_prev_pos := Vector2.ZERO
var _dyn_prev_t := 0
var _dyn_have_prev := false
var perf_build_worker_ms := 0
var perf_build_worker_ms_list: Array = []  # AC-0197: per-build worker ms (p50/p95 gate)
var col_stage_enabled := true
var _col_pending: Array = []
var _col_pending_set: Dictionary = {}
var perf_collision_ms := 0
var perf_collision_n := 0
var perf_collision_max_ms := 0
var perf_staged_drained := 0
var perf_staged_dropped := 0
var _eff_cache: Dictionary = {}
var _eff_cache_order: Array = []
const EFF_CACHE_CAP := 128
var _bl_want: Dictionary = {}
var perf_light_self_computes := 0
var perf_light_batch_calls := 0
var perf_light_batch_chunks := 0
var perf_light_cache_hits := 0
var light_saved_restores := 0
const PICK_POOL_CAP := 512
# AC-0079 v3 pick-order probe: a bounded log of every mesh-build DISPATCH
# (any _mesh_dispatch that actually dispatches — sync fallbacks included,
# dedup re-picks excluded). The boundary harness reads it to count, per
# crossing, how many of the FIRST 10 dispatches are forward (dx > 0) chunks.
var build_dispatch_total := 0
var build_dispatch_log: Array = []
const BUILD_DISPATCH_LOG_CAP := 16384

func _bd_log(cx: int, cz: int) -> void:
	build_dispatch_total += 1
	build_dispatch_log.append(Vector2i(cx, cz))
	if build_dispatch_log.size() > BUILD_DISPATCH_LOG_CAP:
		build_dispatch_log.pop_front()

func _ready() -> void:
	timing = OS.get_environment("AWECRAFT_TIMING") == "1"
	_picklog = OS.get_environment("AWECRAFT_PICKLOG") == "1"  # AC-0217
	_wprof_init()  # AC-0251: pre-allocate the per-stage pipeline timing ring
	# AC-0252: seed the med/low band boundary from the user setting (the
	# later Settings.apply_world re-applies it against the live radii).
	apply_low_start()
	# AC-0257: seed the tier-0 set from the user setting.
	note_tier0_radius()
	# AC-0257: the in-flight caps scale to all available cores, never past
	# (see _apply_worker_thread_caps).
	_apply_worker_thread_caps()
	# AC-0263: PRE-SEED the C++ singletons on the MAIN thread, before any
	# pool task runs. Both are lazy-instantiated (the done-flag is set
	# BEFORE the instance assignment), so parallel first-time worker calls
	# race: a loser reads a nil and its task dies. Pre-AC-0263 the
	# recenter's main-thread sync gen happened to call gen_cpp first
	# (hiding it); AC-0263 dropped the sync gen, the burst workers became
	# the first callers, and the race killed burst elements (the dead
	# slot then held the startup build-hold forever — a spawn deadlock).
	WorldGen.gen_cpp()
	ChunkScript.mesh_cpp()
	threadgen_pool = Engine.get_singleton("WorkerThreadPool")
	threadgen = true
	io_pool = threadgen_pool  # AC-0164: column I/O shares the threadgen pool
	_tg_debug = OS.get_environment("AWECRAFT_TGDEBUG") == "1"
	print("THREADGEN on threadgen=true cap=%d" % threadgen_max)
	threadmesh_pool = Engine.get_singleton("WorkerThreadPool")
	# AC-0187: dedicated lane for the block-edit fast remesh. The shared
	# engine pool runs the far-queue builds (HIGH) and the data pass (LOW,
	# 3-thread share) — an edit task queued there waits behind full builds
	# (measured 460 ms at R50 streaming). A private single thread makes the
	# edit build start the moment it is dispatched.
	threadmesh_edit_pool = EditPool.new()
	threadmesh_edit_pool.start()
	# Pre-warm everything the worker path touches so a worker thread
	# never dereferences Data/Game: tables, block-table snapshot, and the
	# merge atlas (static cache keyed by atlas identity).
	Lighting._tables()
	_tm_ctx = ChunkScript.make_ctx()
	_tm_ms_full = ChunkScript._merge_atlas()
	_low_ms_snap_dirty = true  # AC-0236 part 2: the low emit snapshot is stale (new atlas)
	_tm_ctx_atlas = Data.atlas_tex  # AC-0160: stamp for the _process staleness guard
	_low_fog_bake()  # AC-0231: the far-LOD fog-box template + material
	_pool_prewarm()  # AC-0247/AC-0248: the ring-sized pool prewarm (the recenter that follows a radius change tops up — _pool_top_up)
	threadmesh = true
	_tm_debug = OS.get_environment("AWECRAFT_TMDEBUG") == "1"
	print("THREADMESH on threadmesh=true pool=%d" % threadmesh_max)
	_recprobe = OS.get_environment("AWECRAFT_RECPROBE") == "1"
	var dr := OS.get_environment("AWECRAFT_DRAIN_MS")
	if dr != "" and dr.to_int() > 0:
		drain_budget_ms = dr.to_int()
	# AC-0224/AC-0225: tuning knob for the streaming handoff burst (default
	# STREAM_TM_HANDOFF_PER_FRAME = 3) — the AWECRAFT_TM_HO env preloads the
	# same Settings "chunks_per_frame" value the Options slider drives
	# (clamped 1..100; written to Settings.values WITHOUT save so the
	# harness never clobbers the user's cfg; the drain cap reads the
	# setting every process frame in threadmesh_poll).
	var hoe := OS.get_environment("AWECRAFT_TM_HO")
	if hoe != "":
		Settings.values["chunks_per_frame"] = clampi(
			hoe.to_int(), Settings.CHUNKS_PER_FRAME_MIN, Settings.CHUNKS_PER_FRAME_MAX)
	# AC-0152: harness band overrides (default 4/8 per Bedrock Realms).
	var b0e := OS.get_environment("AWECRAFT_BAND0")
	if b0e != "":
		band0_r = maxi(0, b0e.to_int())
		_rescore_kick()  # AC-0239: band0_r is the tier-1 boundary
	# AC-0263: the mid-LOD boundary (the HIGH band's outer edge) — the
	# world-gen boundary that band0_r used to be (band0_r is the sim
	# distance now; mobs/fluids only).
	var mse := OS.get_environment("AWECRAFT_MEDIUM_START")
	if mse != "":
		medium_start_r = maxi(0, mse.to_int())
		_rescore_kick()
	var b1e := OS.get_environment("AWECRAFT_BAND1")
	if b1e != "":
		band1_r = maxi(0, b1e.to_int())
	col_stage_enabled = OS.get_environment("AWECRAFT_COLSTAGE") != "0"
	var gb := OS.get_environment("AWECRAFT_GEN_BUDGET")
	if gb != "" and gb.to_int() >= 0:
		gen_budget_ms = gb.to_int()
	fluid_sleep = OS.get_environment("AWECRAFT_FLUID_SLEEP") != "0"
	# AC-0109 kill switch; AC-0212: ENGINE CULL IS THE NEW DEFAULT.
	# AWECRAFT_FRUSTUM (new, authoritative when set): manual|1|on -> the
	# AC-0109 per-frame pass; engine|0|off (or empty string) -> engine cull.
	# When unset, the legacy AWECRAFT_FRUSTUM_CULL=0 still disables the manual
	# pass (any other legacy value = explicit manual opt-in). AWECRAFT_ONLY
	# set = probe-only visibility filter (main.gd) must stay authoritative, so
	# the manual pass defers either way.
	var fr := OS.get_environment("AWECRAFT_FRUSTUM")
	var fc := OS.get_environment("AWECRAFT_FRUSTUM_CULL")
	var manual_want: bool
	if fr != "":
		# New toggle is authoritative: only an EXPLICIT manual value enables
		# the pass — anything else (engine/0/off/unknown) = engine cull.
		manual_want = fr == "manual" or fr == "1" or fr == "on"
	elif fc != "":
		# Legacy AC-0109 switch, only when explicitly set (=0 disables,
		# any other value = explicit manual opt-in).
		manual_want = fc != "0"
	else:
		# Both unset = the AC-0212 default: ENGINE CULL.
		manual_want = false
	_cull_enabled = manual_want and OS.get_environment("AWECRAFT_ONLY") == ""
	cull_mode = "manual" if _cull_enabled else "engine"
	tick_time = OS.get_environment("AWECRAFT_TICKTIME") == "1"
	_fluidprobe = OS.get_environment("AWECRAFT_FLUIDPROBE") == "1"
	_frameprobe = OS.get_environment("AWECRAFT_FRAMEPROBE") == "1"
	_cblog = OS.get_environment("AWECRAFT_CBLOG") == "1"
	_nofree = OS.get_environment("AWECRAFT_NOFREE") == "1"
	# AC-0178: loading-screen wiring. Bypass override for the headless A/B
	# probe (default ON); remember the normal pool caps; build the UI node
	# (hidden; harmless headless — never awaited).
	loading_bypass = OS.get_environment("AWECRAFT_LOADBYPASS") != "0"
	_tg_max_norm = threadgen_max
	_tm_max_norm = threadmesh_max
	_loading_screen = LoadingScreen.new()
	_loading_screen.name = "LoadingScreen"
	add_child(_loading_screen)
	Game.world = self
	# AC-0158: splitmix64 constants — built from 32-bit halves (GDScript has
	# no hex literal > 2^63-1); int arithmetic wraps mod 2^64.
	_rt_c1 = (0x9E3779B9 << 32) | 0x7F4A7C15
	_rt_c2 = (0xBF58476D << 32) | 0x1CE4E5B9
	_rt_c3 = (0x94D049BB << 32) | 0x133111EB

func _exit_tree() -> void:
	threadgen = false
	threadmesh = false
	# AC-0107 (G5 flake fix): drain in-flight worker tasks BEFORE the engine
	# unloads scripts. A worker still executing a GDScript static call during
	# cleanup deadlocks (observed: post-RESULT exit hang, ~40% of ON-arm runs,
	# OFF arm clean). Bounded wait — if the pool ever wedges, continue the
	# shutdown after the cap instead of hanging the exit.
	# AC-0178: the wait is now a POLL DRAIN, not an is_task_completed poll:
	# (1) the old loop checked TM task ids against THREADGEN_POOL (wrong pool:
	# "Invalid Task ID" at every exit, the 1000 ms cap always consumed);
	# (2) at the loading window's depths (64 TM + 24 TG) the 1000 ms cap is
	# far too short — a 64-deep queue needs ~4-10 s to drain, and any task
	# still QUEUED when this node frees starts its worker AFTER the free:
	# the worker's bound Callable then hits the dangling ObjectID (segfault
	# at shutdown — measured once: EXIT=139 at the 45-min cap with 58 TM in
	# flight). Draining via the real polls hands each task off on the live
	# node and empties the pool queue before the free; the 20 s cap covers
	# 64 x 1.0 s outlier builds / 6 threads + the TG share with margin.
	_shutting_down = true
	if threadgen_pool != null:
		var waited := 0
		while waited < 20000 and (not threadgen_inflight.is_empty() or not threadmesh_inflight.is_empty() or not _io_read_inflight.is_empty() or not _io_write_inflight.is_empty() or not _io_compact_inflight.is_empty()):  # AC-0175: compaction settles too
			threadgen_poll()
			threadmesh_poll()
			io_poll()
			OS.delay_msec(1)
			waited += 1
	# AC-0178: consume the 5x5 burst GROUP tasks. Godot frees a group's Group
	# object only via wait_for_group_task_completion — the burst is otherwise
	# never consumed (the drain holds builds until the burst lands, nothing
	# waits on the group) and it leaks at exit: "Pages in use exist at exit
	# in PagedAllocator: N16WorkerThreadPool5GroupE". A still-running burst
	# finishes its remaining elements first (bounded: 24 x ~165 ms / 3-wide
	# ~= 1.3 s worst case) — the pool is torn down right after, so the wait
	# can't hang the exit any longer than the burst itself.
	if threadgen_pool != null and not _startup_gen_group_tids.is_empty():
		for _t in _startup_gen_group_tids:
			threadgen_pool.wait_for_group_task_completion(int(_t))
		_startup_gen_group_tids.clear()
	threadgen_inflight.clear()
	threadmesh_inflight.clear()
	_tg_slots_mutex.lock()
	_tg_slots.clear()
	_tg_slots_mutex.unlock()
	_tm_slots_mutex.lock()
	_tm_slots.clear()
	_tm_slots_mutex.unlock()
	# AC-0236 part 2: the low-lane in-flight queue (its tasks ride the same
	# _tm_slots the clear above just wiped).
	_low_tasks.clear()
	_low_task_keys = {}
	_io_read_inflight.clear()  # AC-0164
	_io_write_inflight.clear()
	_io_slots.clear()
	# AC-0187: the edit lane is this node's own thread (not the engine
	# singleton); its queue is drained above, so stop it at exit.
	if threadmesh_edit_pool != null:
		threadmesh_edit_pool.stop()
		threadmesh_edit_pool = null
	# AC-0247: the pool teardown — LAST (the drain above may have checked
	# instances back into the pools via handoffs). The pooled nodes are
	# detached orphans (the pool's invariant: checkin removes them from
	# the tree first), so immediate free() is safe and the prewarm entries
	# do not leak at exit. The MultiMesh pool's MultiMesh entries are
	# refcounted — dropping the MMI releases them.
	_pool_free_all()

# AC-0158: fixed-step 20 Hz game tick on the real frame delta (Bedrock
# Realms simulation clock; replaces the 5 Hz fluid Timer). A stalled frame
# drops its backlog (max TICK_MAX_CATCHUP catch-up ticks) instead of
# death-spiraling. tick_index is the deterministic random-tick seed.
func _game_tick_accumulate(delta: float) -> void:
	if not game_tick_enabled:
		return
	if Game.mode != "play" and Game.mode != "pause":
		return
	_tick_acc += delta
	var n := 0
	while _tick_acc >= TICK_INTERVAL and n < TICK_MAX_CATCHUP:
		_tick_acc -= TICK_INTERVAL
		n += 1
		_game_tick()
	if n == TICK_MAX_CATCHUP:
		_tick_acc = 0.0

func _game_tick() -> void:
	var t0 := Time.get_ticks_usec()
	tick_index += 1
	_random_tick_pass(tick_index)
	if fluid_sim_enabled:
		tick_fluids()
	game_tick_samples.append((Time.get_ticks_usec() - t0) / 1000.0)

# AC-0109: per-frame frustum cull. Column AABB early-out both directions,
# then per-slab (16x16x16) exact test when the column straddles a plane.
# Visible state is written only on change (instance.visible is the last
# state — no per-chunk bookkeeping). Rebuilt instances (mesh null) are
# no-ops; a freshly assembled instance defaults visible=true until the
# next camera-change pass re-tests it (transient, off-screen). AC-0168
# candidates keep their mesh and their visible state — candidacy never
# hides an instance (the fog does).
func invalidate_cull_cache() -> void:
	# Force the cull pass to re-evaluate on the next camera read (probe hook).
	_cull_cam_xform = Transform3D(Basis.IDENTITY, Vector3(1e9, 1e9, 1e9))

func _frustum_cull_pass() -> void:
	if not _cull_enabled:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var xf := cam.global_transform
	if xf == _cull_cam_xform:
		return
	_cull_cam_xform = xf
	perf_cull_passes += 1  # AC-0212 probe counter: a real re-evaluation
	_cull_frustum_planes(cam)
	var m := FRUSTUM_CULL_MARGIN
	var planes: Array = _cull_planes
	for key in chunks:
		var c: Node3D = chunks[key]
		if c == null:
			continue
		var ox := float(int(c.cx)) * 16.0
		var oz := float(int(c.cz)) * 16.0
		# AC-0091: column center = world mid-height (H/2 = 192), was 40.0 at H=80.
		_cull_cen = Vector3(ox + 8.0, float(Data.HEIGHT) * 0.5, oz + 8.0)
		var culled := false
		var all_in := true
		for i in 6:
			var d: float = planes[i].distance_to(_cull_cen)
			_cull_dc[i] = d
			if d + _cull_col_span[i] < -m:
				culled = true
			elif d - _cull_col_span[i] < -m:
				all_in = false
		if culled:
			for s in c.slabs:
				_cull_set_vis(s, false)
			continue
		if all_in:
			for s in c.slabs:
				_cull_set_vis(s, true)
			continue
		for s in c.slabs:
			# slab center y = y0+8, column center y = H/2 -> dy = y0+8-H/2
			# (AC-0091: was y0-32 at H=80).
			var dy := float(s.y0) + 8.0 - float(Data.HEIGHT) * 0.5
			var vis := true
			for i in 6:
				if _cull_dc[i] + dy * _cull_ny[i] + _cull_slab_span[i] < -m:
					vis = false
					break
			_cull_set_vis(s, vis)

func _cull_frustum_planes(cam: Camera3D) -> void:
	if _cull_planes.size() != 6:
		_cull_planes = [
			Plane(Vector3(0, 0, -1), Vector3.ZERO),
			Plane(Vector3(0, 0, 1), Vector3.ZERO),
			Plane(Vector3(-1, 0, 0), Vector3.ZERO),
			Plane(Vector3(1, 0, 0), Vector3.ZERO),
			Plane(Vector3(0, 1, 0), Vector3.ZERO),
			Plane(Vector3(0, -1, 0), Vector3.ZERO),
		]
		_cull_col_span = PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
		_cull_slab_span = PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
		_cull_ny = PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
		_cull_dc = PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	var B := cam.global_transform.basis
	var O := cam.global_transform.origin
	var sz := get_viewport().get_visible_rect().size
	var aspect := float(sz.x) / maxf(float(sz.y), 1.0)
	var tv := tan(deg_to_rad(float(cam.fov)) * 0.5)
	var th := tv * aspect
	var nr := maxf(float(cam.near), 0.01)
	var fr := maxf(float(cam.far), nr + 1.0)
	# camera-local corners (x right, y up, -z forward), world space
	var cn0 := O + B * Vector3(-th * nr, -tv * nr, -nr)
	var cn1 := O + B * Vector3(th * nr, -tv * nr, -nr)
	var cn2 := O + B * Vector3(-th * nr, tv * nr, -nr)
	var cn3 := O + B * Vector3(th * nr, tv * nr, -nr)
	var cf0 := O + B * Vector3(-th * fr, -tv * fr, -fr)
	var cf1 := O + B * Vector3(th * fr, -tv * fr, -fr)
	var cf2 := O + B * Vector3(-th * fr, tv * fr, -fr)
	var cf3 := O + B * Vector3(th * fr, tv * fr, -fr)
	var cen := O + B * Vector3(0.0, 0.0, -fr * 0.5)
	_cull_planes[0] = _cull_plane(cn0, cn1, cn3, cen)
	_cull_planes[1] = _cull_plane(cf0, cf1, cf3, cen)
	_cull_planes[2] = _cull_plane(cn0, cn2, cf2, cen)
	_cull_planes[3] = _cull_plane(cn1, cn3, cf3, cen)
	_cull_planes[4] = _cull_plane(cn2, cn3, cf2, cen)
	_cull_planes[5] = _cull_plane(cn0, cn1, cf1, cen)
	for i in 6:
		var n: Vector3 = _cull_planes[i].normal
		_cull_ny[i] = n.y
		# AC-0091: column half-span = H/2 (was 40.0 at H=80).
		_cull_col_span[i] = 8.0 * absf(n.x) + float(Data.HEIGHT) * 0.5 * absf(n.y) + 8.0 * absf(n.z)
		_cull_slab_span[i] = 8.0 * absf(n.x) + 8.0 * absf(n.y) + 8.0 * absf(n.z)

func _cull_plane(a: Vector3, b: Vector3, c: Vector3, cen: Vector3) -> Plane:
	var n: Vector3 = (b - a).cross(c - a)
	if n.length_squared() < 0.00000001:
		return Plane(Vector3(0, 0, -1), a)
	n = n.normalized()
	if n.dot(cen - a) < 0.0:
		n = -n
	return Plane(n, a)

func _cull_set_vis(s, vis: bool) -> void:
	var mi: MeshInstance3D = s.mesh_instance
	if mi != null and mi.visible != vis:
		mi.visible = vis
		perf_cull_flips += 1  # AC-0212 probe counter
	var fi: MeshInstance3D = s.fluid_instance
	if fi != null and fi.visible != vis:
		fi.visible = vis
		perf_cull_flips += 1
	var fa: MeshInstance3D = s.flora_instance
	if fa != null and fa.visible != vis:
		fa.visible = vis
		perf_cull_flips += 1

var _prof_ring: Array = []


func _physics_process(_d: float) -> void:
	if _cblog:
		print("CBW in t=%d" % Time.get_ticks_msec())
	_physics_process_impl(_d)
	if _cblog:
		print("CBW out t=%d" % Time.get_ticks_msec())


var _cblog := false
var _nofree := false
var _tg_concur := 0
var _tg_concur_peak := 0
var _tm_concur := 0
var _tm_concur_peak := 0


func _physics_process_impl(_d: float) -> void:
	if not threadmesh_inflight.is_empty():
		threadmesh_poll()
	_overlay_tick(_d)


# AC-0174: dev overlay gizmos - three independent Options toggles
# (overlay_band / overlay_light / overlay_collision), each drawing into
# its own ImmediateMesh. Rebuilds are throttled to chunk-movement + a
# 0.5 s timer; when every toggle is off the meshes are freed entirely,
# so the idle cost is three bool reads and an array compare.
var _overlay_node: Node3D = null
var _overlay_band_mi: MeshInstance3D = null
var _overlay_light_mi: MeshInstance3D = null
var _overlay_col_mi: MeshInstance3D = null
var _overlay_state: Array = [false, false, false]
var _overlay_chunk := Vector2i(-9999, -9999)
var _overlay_acc := 0.0


func _overlay_tick(d: float) -> void:
	var s0 := bool(Settings.values.get("overlay_band", false))
	var s1 := bool(Settings.values.get("overlay_light", false))
	var s2 := bool(Settings.values.get("overlay_collision", false))
	var st: Array = [s0, s1, s2]
	if st != _overlay_state:
		_overlay_state = st
		_overlay_ensure_node()
		_overlay_set_mesh(_overlay_band_mi, s0)
		_overlay_set_mesh(_overlay_light_mi, s1)
		_overlay_set_mesh(_overlay_col_mi, s2)
		_overlay_chunk = Vector2i(-9999, -9999)
		return
	if not (s0 or s1 or s2) or Game.player == null:
		return
	_overlay_acc += d
	var p: Vector3 = Game.player.position
	var c := Vector2i(int(floor(p.x / 16.0)), int(floor(p.z / 16.0)))
	if c != _overlay_chunk or _overlay_acc >= 0.5:
		_overlay_acc = 0.0
		_overlay_chunk = c
		_overlay_rebuild(s0, s1, s2)


func _overlay_ensure_node() -> void:
	if _overlay_node != null:
		return
	_overlay_node = Node3D.new()
	_overlay_node.name = "OverlayGizmos"
	add_child(_overlay_node)
	for nm in ["OverlayBand", "OverlayLight", "OverlayCollision"]:
		var mi := MeshInstance3D.new()
		mi.name = nm
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_overlay_node.add_child(mi)
	_overlay_band_mi = _overlay_node.get_node("OverlayBand")
	_overlay_light_mi = _overlay_node.get_node("OverlayLight")
	_overlay_col_mi = _overlay_node.get_node("OverlayCollision")


# 4.7: meshes are RefCounted - drop the reference, never .free().
func _overlay_set_mesh(mi: MeshInstance3D, on: bool) -> void:
	if mi == null:
		return
	if not on and mi.mesh != null:
		mi.mesh = null


func _overlay_rebuild(s0: bool, s1: bool, s2: bool) -> void:
	if s0:
		_overlay_draw_band(_overlay_band_mi)
	if s1:
		_overlay_draw_light(_overlay_light_mi)
	if s2:
		_overlay_draw_collision(_overlay_col_mi)


# 4.7: no ImmediateMesh.clear() - each rebuild allocates a fresh mesh.
func _overlay_draw_band(mi: MeshInstance3D) -> void:
	var m := ImmediateMesh.new()
	var p: Vector3 = Game.player.position
	var y := floorf(p.y) + 0.05
	var cx := int(floor(p.x / 16.0)) * 16
	var cz := int(floor(p.z / 16.0)) * 16
	var rr := render_radius * 16
	var sr := int(Settings.values.get("sim_dist", 4)) * 16
	m.surface_begin(Mesh.PRIMITIVE_LINES)
	# AC-0261: the render/sim regions are TAXI diamonds (|dx|+|dz| <= r),
	# not axis-aligned squares.
	_overlay_diamond(m, float(cx), y, float(cz), float(sr), Color(1.0, 0.6, 0.1, 0.9))
	_overlay_diamond(m, float(cx), y, float(cz), float(rr), Color(0.2, 1.0, 0.3, 0.9))
	m.surface_end()
	mi.mesh = m


# AC-0261: a taxi-diamond outline (its vertices sit on the X/Z axes).
func _overlay_diamond(m: ImmediateMesh, cx: float, y: float, cz: float, r: float, col: Color) -> void:
	var v := [
		Vector3(cx, y, cz - r), Vector3(cx + r, y, cz),
		Vector3(cx, y, cz + r), Vector3(cx - r, y, cz)]
	m.surface_set_color(col)
	for i in 4:
		m.surface_add_vertex(v[i])
		m.surface_add_vertex(v[(i + 1) % 4])


func _overlay_draw_light(mi: MeshInstance3D) -> void:
	var m := ImmediateMesh.new()
	var p: Vector3 = Game.player.position
	var c := Vector3i(int(floor(p.x)), int(floor(p.y)), int(floor(p.z)))
	var r := 12
	var mn := Vector3i(c.x - r, maxi(c.y - r, 0), c.z - r)
	var mx := Vector3i(c.x + r, c.y + r, c.z + r)
	var res: Dictionary = Lighting.compute_light_split(
		{"min": mn, "max": mx}, self, _lightflat)
	var eff: Dictionary = res.eff
	m.surface_begin(Mesh.PRIMITIVE_LINES)
	for bc in eff:
		var lvl: int = eff[bc]
		if lvl <= 0:
			continue
		# skip half the blocks - the overlay is a rough map, not exact
		if (bc.x + bc.y + bc.z) % 2 != 0:
			continue
		var t := float(lvl) / 15.0
		m.surface_set_color(Color(0.8, 0.1, 0.05).lerp(Color(1.0, 0.95, 0.3), t))
		m.surface_add_vertex(Vector3(float(bc.x) + 0.02, float(bc.y), float(bc.z) + 0.02))
		m.surface_add_vertex(Vector3(float(bc.x) + 0.02, float(bc.y) + 0.15 + t * 1.2, float(bc.z) + 0.02))
	m.surface_end()
	mi.mesh = m


func _overlay_draw_collision(mi: MeshInstance3D) -> void:
	var m := ImmediateMesh.new()
	var p: Vector3 = Game.player.position
	var pc := Vector2i(int(floor(p.x / 16.0)), int(floor(p.z / 16.0)))
	m.surface_begin(Mesh.PRIMITIVE_LINES)
	m.surface_set_color(Color(1.0, 0.15, 0.15, 0.9))
	for key in chunks:
		var ch: Node3D = chunks[key]
		var cc := Vector2i(int(ch.position.x / 16.0), int(ch.position.z / 16.0))
		if absi(cc.x - pc.x) > 1 or absi(cc.y - pc.y) > 1:
			continue
		for s in ch.slabs:
			if s.collision_body == null:
				continue
			for col in s.collision_body.get_children():
				if not (col is CollisionShape3D) or col.shape == null:
					continue
				_overlay_aabb_lines(m, col.global_transform * _overlay_shape_aabb(col.shape))
	m.surface_end()
	mi.mesh = m


# 4.7: ConcavePolygonShape3D has no get_aabb() (and this build's AABB
# has no absorb/expand) - fold the faces by hand.
func _overlay_shape_aabb(shape: Shape3D) -> AABB:
	if shape is ConcavePolygonShape3D:
		var mn := Vector3(INF, INF, INF)
		var mx := Vector3(-INF, -INF, -INF)
		for v in (shape as ConcavePolygonShape3D).get_faces():
			mn = mn.min(v)
			mx = mx.max(v)
		if mn.x > mx.x:
			return AABB()
		return AABB(mn, mx - mn)
	return shape.get_aabb()


func _overlay_aabb_lines(m: ImmediateMesh, ab: AABB) -> void:
	var c := [
		Vector3(ab.position.x, ab.position.y, ab.position.z),
		Vector3(ab.end.x, ab.position.y, ab.position.z),
		Vector3(ab.end.x, ab.position.y, ab.end.z),
		Vector3(ab.position.x, ab.position.y, ab.end.z),
		Vector3(ab.position.x, ab.end.y, ab.position.z),
		Vector3(ab.end.x, ab.end.y, ab.position.z),
		Vector3(ab.end.x, ab.end.y, ab.end.z),
		Vector3(ab.position.x, ab.end.y, ab.end.z)]
	var e := [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7],
		[7, 4], [0, 4], [1, 5], [2, 6], [3, 7]]
	for i in e:
		m.surface_add_vertex(c[i[0]])
		m.surface_add_vertex(c[i[1]])


# --- AC-0251: per-stage ms attribution of the world pipeline (instrument-ONLY) ---
# The user flies 4x and fps tanks to ~20; AC-0250 removed the priority cone
# and the low-LOD sync fallback, so the remaining main-thread load lives
# elsewhere in this pipeline. This block times the per-frame stages so the
# cost is readable live (the AC-0244 console overlay) and headless
# (AWECRAFT_LOGIC=wprof). MAIN-THREAD-ONLY and PRE-ALLOCATED: a ring of
# WP_RING per-frame rows (one int slot per stage, in usec), zeroed in place
# each frame — NO per-frame allocation, NO new locks, NO string formatting
# on the hot path (the read side refreshes only when `profiler` is read,
# and the stat dicts are mutated in place, never rebuilt). It measures; it
# changes NO scheduling, pacing, ordering, or allocation behavior (the
# schedule-transparency proof: the r16 arm's gates must hold unchanged).
#
# TOP-LEVEL partition (DISJOINT; the five stages below + MISC reconcile
# against the frame total measured around World._process itself):
#   DRAIN    = _drain_build_queue (the drain pass + the dispatch/attach work
#              it does this frame — the 30-50 ms class per-dispatch strip/
#              nbs work)
#   LOW      = _low_step (the _low_poll attaches + the in-r lane + the far
#              slab wave — the dispatch + handoff attach + bookkeeping
#              only; since the AC-0252 offload the grid sample + emit run
#              on the TM workers, never here)
#   HANDOFF  = threadgen_poll + threadmesh_poll (the worker-result handoff /
#              attach passes: the TM _tm_slots attach + the TG handoff)
#   IO       = io_poll (the _io_write_commit region blob commits + the
#              disk-read apply handoffs)
#   RECENTER = _recenter_slice (the recenter/rebuild queue walk(s))
#   MISC     = frame total - the five above (everything else in
#              World._process: the 20 Hz tick, the save-queue drain, the
#              loading/banana ticks, the atlas-identity sync, the cull pass,
#              the light_pending flush dispatch loop, the fluid dispatches,
#              the tex refresh, the idle early-return frames)
#
# SUB-STAGES (SUBSETS — they accumulate where the work happens, which can be
# several top stages and even outside _process (the _physics_process poll,
# the recenter() inline polls, the sync flush dispatches); attribution
# detail, never part of the partition reconciliation):
#   FACELIGHT  = _eff_landed (the face-block light cascade: the face-cache
#                refresh + the E2 neighbor re-enqueue — the ~1.2 s-class
#                main-thread face-cache refresh on handoff; ISOLATED because
#                it is separable from the rest of the handoff)
#   RESCORE    = _rescore_step (runs only via the drain — a DRAIN subset)
#   MESHATTACH = the per-slab / per-chunk MeshInstance3D create + set_mesh +
#                add_child attach work (chunk.gd _assemble_slab — the
#                apply_accs / apply_edit_accs / sync build_mesh paths — plus
#                the low-slab, fog, and cap placeholder attaches; the
#                AC-0247 suspect; ISOLATED at the node-assembly unit)
#
# Occupancy (in-flight task counts, refreshed on read): threadgen_inflight,
# threadmesh_inflight, _low_tasks.
const WP_DRAIN := 0
const WP_LOW := 1
const WP_HANDOFF := 2
const WP_FACELIGHT := 3
const WP_IO := 4
const WP_RECENTER := 5
const WP_RESCORE := 6
const WP_MESHATTACH := 7
const WP_MISC := 8
const WP_FRAME := 9
# AC-0262: the LOW stage's sub-parts (sub-stages — they sum to <= LOW,
# never into the 5-stage partition): the low-lane attach poll, the (now
# dead) in-r wave, the global slab-wave dispatch loop, and the per-slab
# candidate scan inside it.
const WP_LOW_POLL := 10
const WP_LOW_INR := 11
const WP_LOW_WAVE := 12
const WP_LOW_PICK := 13
const WP_STAGES := 14
const WP_RING := 180

var _wp_rows: Array = []    # WP_RING rows, each an Array of WP_STAGES ints (usec)
var _wp_head := 0
var _wp_filled := 0
var _wp_cur: Array = []    # the accumulating row (a reference into _wp_rows)
var _wp_in := false          # true only DURING World._process (sub-stage gate)
var _wp_dirty := true
var _wp_neg_max := 0         # max usec by which the stage sum EXCEEDED the
                             # frame total in a committed row (0 = the
                             # brackets never overlap / over-count)
var _wp_live: Dictionary = {}  # the stable profiler dict (mutated in place)
var _wp_stat: Array = []       # per-stage stat dicts (the _wp_live values)
var _wp_names: Array = []
var _wp_scratch: PackedInt32Array = PackedInt32Array()

var profiler: Dictionary:
	get:
		_wprof_refresh()
		return _wp_live

func _wprof_init() -> void:
	_wp_rows.clear()
	for i in range(WP_RING):
		var r: Array = []
		for j in range(WP_STAGES):
			r.append(0)
		_wp_rows.append(r)
	_wp_head = 0
	_wp_filled = 0
	_wp_cur = []
	_wp_in = false
	_wp_dirty = true
	_wp_neg_max = 0
	_wp_stat.clear()
	for j in range(WP_STAGES):
		var d: Dictionary = {}
		d["p50"] = 0.0
		d["p95"] = 0.0
		d["max"] = 0.0
		d["avg"] = 0.0
		d["frames"] = 0
		_wp_stat.append(d)
	_wp_names = ["DRAIN", "LOW", "HANDOFF", "FACELIGHT", "IO", "RECENTER", "RESCORE", "MESHATTACH", "MISC", "frame",
		"LOW_POLL", "LOW_INR", "LOW_WAVE", "LOW_PICK"]
	_wp_live = {}
	for j in range(WP_STAGES):
		_wp_live[_wp_names[j]] = _wp_stat[j]
	_wp_live["partition"] = ["DRAIN", "LOW", "HANDOFF", "IO", "RECENTER", "MISC"]
	_wp_live["substages"] = ["FACELIGHT", "RESCORE", "MESHATTACH", "LOW_POLL", "LOW_INR", "LOW_WAVE", "LOW_PICK"]
	_wp_live["occupancy"] = {"tg": 0, "tm": 0, "low": 0}
	_wp_live["misc_neg_max_us"] = 0
	_wp_scratch.resize(WP_RING)

# Begin the current frame's row (zeroed in place — no allocation).
func _wprof_begin_frame() -> void:
	if _wp_rows.is_empty():
		_wprof_init()
	_wp_cur = _wp_rows[_wp_head]
	for j in range(WP_STAGES):
		_wp_cur[j] = 0
	_wp_in = true

# Accumulate `us` usec into the current frame's stage. No-op outside
# World._process (the _physics_process / recenter() polls are outside the
# measured frame window — the top-level brackets only ever run in _process,
# so the partition stays exact).
func _wprof_add(stage: int, us: int) -> void:
	if _wp_in and us > 0:
		_wp_cur[stage] += us

# chunk.gd convenience (avoids a dynamic constant lookup across scripts).
func _wprof_meshattach(us: int) -> void:
	_wprof_add(WP_MESHATTACH, us)

# Commit the frame row: MISC = frame total - the five disjoint top stages
# (exact by construction; a negative MISC would mean the stage brackets
# overlap or exceed the frame — tracked in _wp_neg_max).
func _wprof_end_frame(f0_usec: int) -> void:
	if not _wp_in:
		return
	_wp_in = false
	var f1 := Time.get_ticks_usec()
	var part := int(_wp_cur[WP_DRAIN]) + int(_wp_cur[WP_LOW]) + int(_wp_cur[WP_HANDOFF]) \
			+ int(_wp_cur[WP_IO]) + int(_wp_cur[WP_RECENTER])
	var misc := f1 - f0_usec - part
	if misc < 0:
		_wp_neg_max = maxi(_wp_neg_max, -misc)
	_wp_cur[WP_MISC] = maxi(0, misc)
	_wp_cur[WP_FRAME] = f1 - f0_usec
	_wp_dirty = true
	_wp_head = (_wp_head + 1) % WP_RING
	_wp_filled = mini(_wp_filled + 1, WP_RING)

# Recompute the rolling-window stats (p50/p95/max/avg ms at 1 decimal +
# active-frame count per stage, over the last WP_RING frames). Runs only on
# read — the hot path never formats or allocates for it.
func _wprof_refresh() -> void:
	if _wp_rows.is_empty() or not _wp_dirty:
		return
	var n := _wp_filled
	for j in range(WP_STAGES):
		_wp_scratch.resize(n)  # the window grows across refreshes — size first
		var total := 0
		var active := 0
		for i in range(n):
			var v := int(_wp_rows[(_wp_head - n + i + WP_RING) % WP_RING][j])
			_wp_scratch[i] = v
			total += v
			if v > 0:
				active += 1
		var st: Dictionary = _wp_stat[j]
		if n == 0:
			st["p50"] = 0.0
			st["p95"] = 0.0
			st["max"] = 0.0
			st["avg"] = 0.0
			st["frames"] = 0
		else:
			_wp_scratch.sort()
			st["p50"] = roundf(float(_wp_scratch[int(ceilf(0.5 * float(n))) - 1]) / 100.0) / 10.0
			st["p95"] = roundf(float(_wp_scratch[int(ceilf(0.95 * float(n))) - 1]) / 100.0) / 10.0
			st["max"] = roundf(float(_wp_scratch[n - 1]) / 100.0) / 10.0
			st["avg"] = roundf(float(total) / float(n) / 100.0) / 10.0
			st["frames"] = active
	var occ: Dictionary = _wp_live["occupancy"]
	occ["tg"] = threadgen_inflight.size()
	occ["tm"] = threadmesh_inflight.size()
	occ["low"] = _low_tasks.size()
	_wp_live["misc_neg_max_us"] = _wp_neg_max
	_wp_dirty = false

# The unrounded partition reconciliation over the current window:
# |sum(top-stage avg) + misc avg - frame avg| / frame avg (raw usec — the
# 1-decimal display rounding is not what the wprof arm gates on).
func _wprof_recon_raw_pct() -> float:
	if _wp_filled == 0:
		return 0.0
	var n := _wp_filled
	var s_part := 0
	var s_frame := 0
	for i in range(n):
		var r: Array = _wp_rows[(_wp_head - n + i + WP_RING) % WP_RING]
		s_part += int(r[WP_DRAIN]) + int(r[WP_LOW]) + int(r[WP_HANDOFF]) \
				+ int(r[WP_IO]) + int(r[WP_RECENTER]) + int(r[WP_MISC])
		s_frame += int(r[WP_FRAME])
	if s_frame <= 0:
		return 0.0
	var avg_part := float(s_part) / float(n)
	var avg_frame := float(s_frame) / float(n)
	return absf(avg_part - avg_frame) / maxf(avg_frame, 1.0) * 100.0

func _process(_delta: float) -> void:
	var pf0 := Time.get_ticks_usec()
	_wprof_begin_frame()  # AC-0251: the frame sample commits at _wprof_end_frame(pf0)
	_game_tick_accumulate(_delta)  # AC-0158: 20 Hz game tick (simulation clock)
	_drain_save_queue()  # AC-0155: amortized full-column writes (1-2/frame)
	# AC-0178: BEFORE the idle early-return — the completion state IS the
	# all-idle state, so the check must not sit behind that return.
	_loading_tick()
	# AC-0040 bouncy-banana: the 10-block fall roll (before the idle return).
	_banana_tick(_delta)
	# AC-0160: keep the worker ctx in sync with the atlas identity. If Data
	# bakes/loads the atlas after World._ready captured the ctx (or a
	# texture-pack swap re-bakes it), the stale ctx (has_tex=false,
	# brect=-1) blackens every worker-built mesh emitted from it; rebuild
	# here — _get_mat self-invalidates by the same atlas identity, so
	# materials re-point on the next dispatch.
	var _at: Texture2D = Data.atlas_tex
	if _at != _tm_ctx_atlas:
		_tm_ctx = ChunkScript.make_ctx()
		_tm_ctx_atlas = _at
		_tm_ms_full = ChunkScript._merge_atlas()
		_low_ms_snap_dirty = true  # AC-0236 part 2: the low emit snapshot is stale (new atlas)
		_low_reset_all()  # AC-0231 fix3: re-lower the lows against the new table
	# AC-0212: engine mode = no manual pass at all (the render server culls
	# each MeshInstance3D automatically); one bool check per frame.
	if _cull_enabled:
		_frustum_cull_pass()
	# AC-0233: settle rebuild — placed BEFORE the idle early-return (qs == 0
	# is exactly the stale state: the circle territory has no entries at
	# all, so every bookkeeping list is empty and the drain never runs).
	# The debounce chain fires only on a new recenter, so a fast-then-stop
	# flight (R16 50x: 215 m/s, the ~2.5 s walk cannot keep up, the player
	# outruns it by ~30 chunks) parks the standing queue up to 5+ chunks
	# behind the resting center and nothing ever fixes it. Once the
	# recenter stream is quiet (no recenter for AHEAD_RING_DEBOUNCE_MS)
	# and the walk center is not the resting center, run one final rebuild
	# at the resting center: the circle re-queues, the tiered feed refills
	# it (under first, then the sim radius, then the rest by taxi), and
	# the render circle fills in around the stopped player. Walking is
	# unaffected: each walk anchors the center
	# to the player (cover 0), so the settle never fires.
	if not _rec_pending and not _spawn_fast and _last_recenter_ms > 0 \
			and Time.get_ticks_msec() - _last_recenter_ms > AHEAD_RING_DEBOUNCE_MS \
			and (absi(last_pcx - _rec_center_pcx) + absi(last_pcz - _rec_center_pcz)) > 0:
		_rec_start_walk(last_pcx, last_pcz)
	# AC-0257 (instance cap): drain the DEFERRED column frees (the recenter
	# free batch is capped at stream_ho_cap/frame — the same per-frame
	# instance-work cap as the attach burst; a recenter over a full circle
	# used to detach the whole rim in one frame).
	_drain_deferred_free()
	# threadmesh_inflight keeps this running while mesh tasks are in flight
	# even when every bookkeeping list is drained (else the poll never runs).
	if light_dirty.is_empty() and fluid_dirty.is_empty() and queue_size == 0 and light_pending.is_empty() and tex_refresh.is_empty() and threadmesh_inflight.is_empty() and _io_read_inflight.is_empty() and _io_write_inflight.is_empty() and _io_compact_inflight.is_empty() and not _rec_pending and _bl_want.is_empty() and _col_pending.is_empty() and dirty_queue.is_empty() and _deferred_free.is_empty():
		_wprof_end_frame(pf0)  # AC-0251: idle frame (all stages 0, MISC = total)
		return
	var was_active := flush_active
	var added := false
	for key in light_dirty:
		var c = chunks.get(key)
		if c != null and c.mesh_built and not light_pending_set.has(key):
			light_pending.append(key)
			light_pending_set[key] = true
			added = true
	light_dirty = {}
	if added and not was_active:
		flush_active = true
		perf_flush_frames = 0
		perf_max_frame_ms = 0
		perf_single_build_ms = 0
	var fluid_list: Array[Node3D] = []
	for key in fluid_dirty:
		var c = chunks.get(key)
		if c != null and c.mesh_built and not light_pending_set.has(key):
			fluid_list.append(c)
	fluid_dirty = {}
	if not dirty_queue.is_empty():
		_dirty_drain()  # AC-0233: dirtyQueue drains first (1/frame), before the streaming work
	var pf1 := Time.get_ticks_usec()
	var fp0 := pf1
	if not light_pending.is_empty() and not _startup_pending() and edit_inflight_count == 0 \
		and threadmesh_inflight.size() < threadmesh_max:
		# AC-0219 pool-full guard: the 1/frame streaming handoff cap keeps
		# the TM pool saturated during remesh waves (dispatches land as fast
		# as slots free). While the pool is full, EVERY dispatch attempt in
		# the section below would cap-drop + re-queue — 10-20 wasted entry
		# builds (~2-5 ms each of nbs-ring/slab/strip work) per frame, a
		# frame-time drain the pre-cap handoff bursts never produced (the
		# pool emptied between bursts, so the spin was short). Yield the
		# frame instead: entries stay queued (key-deduped, nothing lost) and
		# the wave resumes the frame a slot frees. The rare sync-fallback
		# dispatches (data-empty / missing-neighbor) defer at most one frame.
		# AC-0126: edit (post-break) flush — staggered 1 remesh/frame on the
		# AC-0107 worker path. eff = {} -> the worker self-lights its contained
		# kernel (byte-identical to the sync margin-0 path). defer_on_cap=true
		# -> a TM2 cap drop REQUEUES the chunk instead of sync build_mesh (the
		# old 50-120 ms edge-break spike). The spawn/missing-diagonal sync
		# contract paths inside _mesh_dispatch stay sync (unchanged).
		# AC-0160 run 2: while the spawn 3x3 is still pending, the re-light
		# flush YIELDS the 2 mesh-worker slots to the first builds — the E2
		# wave ping-pongs between the landing spawn chunks (each landing
		# re-enqueues its built neighbors) and held ~1 of the 2 slots,
		# pushing spawn3x3 past the 2 s gate. Nothing is dropped: entries
		# wait in light_pending (key-deduped) and drain at 1/frame after
		# startup; final light values are unchanged, only the remesh timing.
		var t0 := Time.get_ticks_msec()
		var built := 0
		var spun := 0
		var max_spin := light_pending.size()
		# AC-0178: loading window — no FLUSH_FRAME_BUDGET_MS / 1-per-frame cap.
		var flush_cap := LOAD_FLUSH_MAX_PER_FRAME if loading_active else EDIT_FLUSH_MAX_PER_FRAME
		while built < flush_cap and not light_pending.is_empty():
			if built > 0 and not loading_active and Time.get_ticks_msec() - t0 > FLUSH_FRAME_BUDGET_MS:
				break
			var key2: String = light_pending.pop_front()
			light_pending_set.erase(key2)
			var c2 = chunks.get(key2)
			if c2 == null or not c2.mesh_built:
				continue
			if not _build_ready(int(c2.cx), int(c2.cz)):
				light_pending.append(key2)
				light_pending_set[key2] = true
				spun += 1
				if spun >= max_spin:
					break
				continue
			var tb := Time.get_ticks_msec()
			var covered := _mesh_dispatch(c2, int(c2.cx), int(c2.cz), {}, true, true)
			var dt := Time.get_ticks_msec() - tb
			if dt > perf_single_build_ms:
				perf_single_build_ms = dt
			if not covered:
				# Cap-drop defer or in-flight dedup: re-queue (back of the line,
				# chunk-key deduped) — never a sync build_mesh.
				light_pending.append(key2)
				light_pending_set[key2] = true
				spun += 1
				if spun >= max_spin:
					break
				continue
			built += 1
		if built > 0:
			perf_flush_frames += 1
			var ft := Time.get_ticks_msec() - t0
			if ft > perf_max_frame_ms:
				perf_max_frame_ms = ft
		if timing and not light_pending.is_empty():
			print("LIGHTPEND pend=%d built=%d spun=%d ft=%.0f t=%d" % [light_pending.size(), built, spun, Time.get_ticks_msec() - t0, Time.get_ticks_msec()])
	# AC-0187: the clear must run even when the section is skipped (a burst
	# can drain to empty at section start); a stale-true flush_active
	# suppresses the perf-counter reset of the next burst.
	if light_pending.is_empty():
		flush_active = false
	var fp1 := Time.get_ticks_usec()
	for c in fluid_list:
		var cc: Node3D = c
		if _build_ready(int(cc.cx), int(cc.cz)):
			_mesh_dispatch(cc, int(cc.cx), int(cc.cz), cc.last_eff, false)
		else:
			fluid_dirty[_key(int(cc.cx), int(cc.cz))] = true
	var fp2 := Time.get_ticks_usec()
	var _wpt := Time.get_ticks_usec()  # AC-0251 HANDOFF stage bracket
	threadgen_poll()
	var fp3 := Time.get_ticks_usec()
	threadmesh_poll()
	_wprof_add(WP_HANDOFF, Time.get_ticks_usec() - _wpt)
	_wpt = Time.get_ticks_usec()  # AC-0251 IO stage bracket
	io_poll()  # AC-0164: land finished column I/O tasks
	_wprof_add(WP_IO, Time.get_ticks_usec() - _wpt)
	var fp4 := Time.get_ticks_usec()
	_wpt = Time.get_ticks_usec()  # AC-0251 RECENTER stage bracket
	_recenter_slice()
	_wprof_add(WP_RECENTER, Time.get_ticks_usec() - _wpt)
	var fp5 := Time.get_ticks_usec()
	_wpt = Time.get_ticks_usec()  # AC-0251 DRAIN stage bracket
	_drain_build_queue()
	_wprof_add(WP_DRAIN, Time.get_ticks_usec() - _wpt)
	var fp6 := Time.get_ticks_usec()
	_wpt = Time.get_ticks_usec()  # AC-0251 LOW stage bracket
	_low_step()  # AC-0231: the far-LOD low path (a separate lane)
	_wprof_add(WP_LOW, Time.get_ticks_usec() - _wpt)
	_drain_tex_refresh()
	var pf2 := Time.get_ticks_usec()
	_wprof_end_frame(pf0)  # AC-0251: commit the frame sample (MISC = the remainder)
	if _frameprobe and (pf2 - pf0) > 50000:
		print("FSEC total=%.0f book=%.0f light=%.0f fluid=%.0f tgpoll=%.0f tmpoll=%.0f rec=%.0f build=%.0f tex=%.0f t=%d" % [
			(float(pf2 - pf0) / 1000.0), (float(pf1 - pf0) / 1000.0), (float(fp1 - fp0) / 1000.0), (float(fp2 - fp1) / 1000.0),
			(float(fp3 - fp2) / 1000.0), (float(fp4 - fp3) / 1000.0), (float(fp5 - fp4) / 1000.0), (float(fp6 - fp5) / 1000.0), (float(pf2 - fp6) / 1000.0), Time.get_ticks_msec()])
	_prof_ring.append([float(pf1 - pf0) / 1000.0, float(pf2 - pf1) / 1000.0,
		threadmesh_inflight.size(), queue_size, light_pending.size()])
	if _prof_ring.size() > 120:
		_prof_ring.pop_front()

func refresh_textures() -> void:
	tex_refresh = chunks.keys().duplicate()
	# Texture swap is the only table-changing event: rebuild the worker ctx
	# and the merge-atlas cache on the main thread. In-flight tasks keep their
	# own copies and land with the old atlas; the tex_refresh drain re-pushes
	# deduped keys so every chunk is rebuilt once with the new tables.
	if threadmesh:
		_tm_ctx = ChunkScript.make_ctx()
		_tm_ms_full = ChunkScript._merge_atlas()
		_low_ms_snap_dirty = true  # AC-0236 part 2: the low emit snapshot is stale (new atlas)
		_tm_ctx_atlas = Data.atlas_tex  # AC-0160: re-stamp (the _process guard would catch it, but stamp now)
		_low_reset_all()  # AC-0231 fix3: re-lower the lows against the new table

func _drain_tex_refresh() -> void:
	if tex_refresh.is_empty() or edit_inflight_count > 0:
		return
	var t0 := Time.get_ticks_msec()
	var done := 0
	# AC-0178: loading window — raise the cap + drop the 40 ms budget.
	var tex_cap := LOAD_FLUSH_MAX_PER_FRAME if loading_active else FLUSH_MAX_PER_FRAME
	while done < tex_cap and not tex_refresh.is_empty():
		if done > 0 and not loading_active and Time.get_ticks_msec() - t0 > FLUSH_FRAME_BUDGET_MS:
			break
		var key = tex_refresh.pop_back()
		var c: Node3D = chunks.get(key)
		if c == null or not c.mesh_built:
			continue
		if not _build_ready(int(c.cx), int(c.cz)):
			tex_refresh.push_back(key)
			continue
		# false = a task for this chunk is still in flight (dispatch dedup):
		# re-queue so the chunk is rebuilt once that task has landed.
		if not _mesh_dispatch(c, int(c.cx), int(c.cz), c.last_eff, false):
			tex_refresh.push_back(key)
		done += 1

# --- AC-0178: loading window (first spawn / render-distance change) --------

# Entry. No-op when AWECRAFT_LOADBYPASS=0 (the legacy spread drain). Raises
# the in-flight caps + drain budgets (each site checks loading_active) and
# shows the screen. Target = the HIGH band's column count (AC-0261: the
# only region that gets a full mesh — the visible band is slab-wave
# owned, band 3 is data-only).
func start_loading(title: String) -> void:
	if not loading_bypass:
		return
	loading_active = true
	_loading_target = _high_band_count()
	_loading_radius = render_radius
	# AC-0178: saturate the 6-thread pool — TG keeps its low-priority 3-thread
	# share (gen feeds the mesh builds, which take the 6 high-priority
	# threads); the in-flight DEPTHS are the saturation (the pool queue must
	# never go empty while loading).
	threadgen_max = LOAD_TG_CAP
	threadmesh_max = LOAD_TM_CAP
	if _loading_screen != null:
		_loading_screen.show_loading(_loading_target, title)

# Exit. Restores every cap the entry raised — steady state is byte-for-byte
# the legacy throttles.
func stop_loading() -> void:
	if not loading_active:
		return
	loading_active = false
	_load_done_once = true
	threadgen_max = _tg_max_norm
	threadmesh_max = _tm_max_norm
	if _loading_screen != null:
		_loading_screen.hide_screen()

# AC-0178: called from Settings.apply_render_distance (the Options path).
# Re-enters the loading window on a real radius change after the first load
# completed. New-world boot + later Options changes only: the continue and
# harness flows never run start_game, so _load_done_once stays false and this
# is a no-op there.
func note_render_distance(prev: int) -> void:
	if _load_done_once and int(prev) != render_radius:
		start_loading("Loading render distance %d" % render_radius)

func circle_count() -> int:
	var n := 0
	for dx in range(-render_radius, render_radius + 1):
		for dz in range(-render_radius, render_radius + 1):
			if in_render_circle(dx, dz):
				n += 1
	return n

# AC-0261 (AC-0263): the loading target is the HIGH band (taxi <
# medium_start_r) — the only region that ever gets a full mesh. The
# visible band [medium_start_r, render_radius) fills in via the
# disc-ordered slab wave while the player plays (the normal streaming
# experience); waiting for it would stall the load on work the streaming
# loop already owns.
func _high_band_count() -> int:
	var n := 0
	for dx in range(-medium_start_r, medium_start_r):
		for dz in range(-medium_start_r, medium_start_r):
			if absi(dx) + absi(dz) < medium_start_r:
				n += 1
	return n


func _high_band_meshed() -> int:
	var n := 0
	for dx in range(-medium_start_r, medium_start_r):
		for dz in range(-medium_start_r, medium_start_r):
			if absi(dx) + absi(dz) >= medium_start_r:
				continue
			var c = chunks.get(_key(last_pcx + dx, last_pcz + dz))
			if c != null and c.mesh_built:
				n += 1
	return n


# AC-0261: true when no slab of the visible band [band0_r, render_radius)
# is still owed to the slab wave (every data slab holds its low or is
# all-air). The drain-wait predicate (loading arms / harness).
func band_drained() -> bool:
	for key in chunks:
		var c: Node3D = chunks[key]
		var taxi := absi(int(c.cx) - last_pcx) + absi(int(c.cz) - last_pcz)
		if taxi < medium_start_r or taxi >= render_radius:
			continue
		if c.data.is_empty() or bool(c.mesh_built):
			continue
		if _entry_best_pending_cached(c) >= 0:  # AC-0262: probe cache
			return false
	return true

# Per-frame: refresh the UI from the real provenance counters, then test the
# completion predicate — high band fully meshed and both worker pools drained.
func _loading_tick() -> void:
	if not loading_active:
		return
	# A radius change mid-load (Options over a paused load) re-anchors the
	# target instead of stalling on the stale one.
	if render_radius != _loading_radius:
		_loading_radius = render_radius
		_loading_target = _high_band_count()
	var m := _high_band_meshed()
	if _loading_screen != null:
		_loading_screen.update_progress(m, _loading_target, disk_reads, gen_count)
	if m >= _loading_target and threadmesh_inflight.is_empty() and threadgen_inflight.is_empty():
		stop_loading()

func _convert_data_to_build(key: String) -> void:
	for b in range(band_buckets.size()):
		var arr: Array = band_buckets[b]
		for i in range(arr.size()):
			if arr[i]["key"] == key:
				arr[i]["data_only"] = false
				queued_keys[key] = "build"
				_build_q_n += 1  # AC-0222: the entry is a build entry now
				_pool_touch()  # AC-0217: the entry moved data-pool -> build-pool
				if b < mq_b or (b == mq_b and i < mq_i):
					mq_b = b
					mq_i = i
				return

# AC-0152: effective band radii (render-radius-clamped; at R < band1_r the
# diamond is the outer set and there is no band-2 ring).
func b0_eff() -> int:
	return mini(band0_r, mini(band1_r, render_radius))


func b1_eff() -> int:
	return mini(band1_r, render_radius)


# AC-0261: the render region is a TAXI square (|dx|+|dz| <= R) — "render
# distance is the max value for everything that is rendered" (the user
# specified the taxi metric for the edge, same family as the sim band).
func in_render_circle(dx: int, dz: int) -> bool:
	return absi(dx) + absi(dz) <= render_radius


# AC-0152 ring (AC-0261: around the taxi square): outside the render
# region but touching it within the 8-neighborhood. Edge chunks build
# against their 4-axis neighbors, which sit OUTSIDE the region at large R
# — without this ring their data never arrives and boundary chunks strand
# the queue. Data-only, band 3, never meshed.
# The min taxi distance over the 8-neighborhood is the SUM of the per-axis
# mins (axis |a| drops to |a|-1) — L1 separates per axis, closed form, no
# loop: the ring walk runs this per box cell.
func in_circle_ring(dx: int, dz: int) -> bool:
	if in_render_circle(dx, dz):
		return false
	var ax := absi(dx)
	var az := absi(dz)
	var gx := ax - 1 if ax > 0 else 0
	var gz := az - 1 if az > 0 else 0
	return gx + gz <= render_radius


func in_stream_set(dx: int, dz: int) -> bool:
	# taxisquare(R) ∪ diamond(b1_eff + 1) ∪ taxi ring: the extra sets are
	# band 3 (data-only) — the collar covers band 0/1 edge neighbors at
	# small R, the ring covers band 2 edge neighbors at large R.
	return in_render_circle(dx, dz) or absi(dx) + absi(dz) <= b1_eff() + 1 or in_circle_ring(dx, dz)


# 0 = full (tick+collide), 1 = full mesh (no tick/collide), 3 = collar ∪
# circle ring data-only. -1 = outside the stream set. AC-0152: band 2 (the
# coarse LOD) was everything inside the circle outside the diamond;
# AC-0231: band 2 is GONE — everything inside the circle is band 0/1
# (full fidelity); the far LOD is the separate per-slab low-res
# placeholder (the band-3 data feeds it: one fog box per non-air slab on
# landing + the per-slab 4x4x4 textured low with repeating UVs).
func band_of(dx: int, dz: int) -> int:
	var taxi := absi(dx) + absi(dz)
	if in_render_circle(dx, dz):
		if taxi <= b0_eff():
			return 0
		return 1
	if taxi <= b1_eff() + 1:
		return 3  # collar: diamond ring outside the circle (small R only)
	if in_circle_ring(dx, dz):
		return 3  # circle ring: data-only band for band-2 edge builds
	return -1


func _bucket_count() -> int:
	return maxi(2 * render_radius + 3, 2 * (b1_eff() + 1) + 2)


func _enqueue_build(cx: int, cz: int) -> void:
	var key := _key(cx, cz)
	var c = chunks.get(key)
	# AC-0257: a meshed column is skipped (keep-high — a built range is
	# sticky; the vwin fall-through / window-re-entry re-queues are gone).
	if c != null and c.mesh_built:
		return
	var old = queued_keys.get(key)
	if old == "build":
		return
	if old == "data":
		_convert_data_to_build(key)
		return
	if band_buckets.is_empty():
		for i in range(_bucket_count()):
			band_buckets.append([])
	var b := mini(absi(cx - last_pcx) + absi(cz - last_pcz), band_buckets.size() - 1)
	# AC-0222: push the NEWEST ahead entry to the FRONT of its band bucket
	# (old: appended to the end, so the drain's per-bucket scan worked
	# through the older entries first). _collect_pool walks each bucket in
	# index order, so the just-queued ahead chunk is now the first-scanned
	# entry of its band: it wins the within-band order and the
	# PICK_POOL_CAP tie-break against the older entries that were already
	# sitting in the band (chunks appear ahead while the player is still
	# moving instead of after the older entries drain).
	var entry := {"key": key, "cx": cx, "cz": cz, "data_only": false}
	_tier_stamp(entry)  # AC-0233: the new waiting part carries its tier
	band_buckets[b].push_front(entry)
	_qb[key] = b  # AC-0160
	queued_keys[key] = "build"
	queue_size += 1
	_build_q_n += 1
	_cap_queue_depth()  # AC-0222: keep the build depth at the circle cap
	_pool_touch()  # AC-0217: a new pool candidate entered the queue
	if b < dq_b:
		dq_b = b
		dq_i = 0
	if b < mq_b:
		mq_b = b
		mq_i = 0

func _build_ready(cx: int, cz: int) -> bool:
	var c = chunks.get(_key(cx, cz))
	if c != null:
		# AC-0152: band 3 (collar ∪ circle ring) never meshes at all — its
		# data is what the set's edge chunks build against. Band 2 needs its
		# 4-axis neighbors like band 0/1 (it is a normal full mesh now; the
		# impostor's self-only readiness is gone with the impostor).
		if int(c.band) == 3:
			return false
	# AC-0160 run 2 (the actual drain fix): ALL 8 neighbors must hold data
	# for EVERY dispatch — startup AND trickle. The gate was startup-only:
	# after the 3x3 landed, a trickle build with a still-generating diagonal
	# fell into the missing-neighbor sync fallback (one 300-500 ms
	# main-thread build per frame, ~0.08 units/frame). The circle-ring band-3
	# data exists exactly to feed the diagonals at the circle edge (a
	# circle chunk's 8-neighborhood is always circle ∪ ring — closed form
	# in_circle_ring), so the 8-neighbor gate is reachable for every
	# meshable chunk at any radius; nothing strands on it.
	for n in [[1, 1], [1, -1], [-1, 1], [-1, -1], [1, 0], [-1, 0], [0, 1], [0, -1]]:
		var nc = chunks.get(_key(cx + int(n[0]), cz + int(n[1])))
		if nc == null or nc.data.is_empty():
			return false
	return true

func _startup_pending() -> bool:
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var c = chunks.get(_key(last_pcx + dx, last_pcz + dz))
			if c == null or not c.mesh_built:
				return true
	return false

func _gen_unit(c: Node3D, cx: int, cz: int) -> int:
	var tg := Time.get_ticks_msec()
	_gen_last_disk = false
	if c.data.is_empty():
		# AC-0263: the (0,0) sync disk-read exemption is GONE — the spawn
		# column takes the same disk-first OFF-MAIN-THREAD path as every
		# other column (the startup burst carries the spawn anti-fall).
		if _io_read_enqueue(cx, cz, _key(cx, cz), true):
			# AC-0164: disk-first off the main thread — file read + decode
			# on a worker; the data lands in _io_read_handoff (edits
			# applied there, provenance marked when it LANDS).
			return 0
	# AC-0152 (AC-0263): sync gen is GONE entirely — every column (the
	# spawn chunk included) threadgens through the identical handoff
	# (data/init_fl/edits, stale-drop, dedup). AC-0082's spawn contract is
	# now the startup burst (recenter's 5x5 group task, which AC-0263
	# extended to carry the center). The sync tail below survives only for
	# the threadgen-less fallback (threadgen false = the pre-pool dev path
	# that no shipped build uses).
	if threadgen:
		threadgen_enqueue(cx, cz, _key(cx, cz), c.get_instance_id(), false, int(c.col_gen))
		if timing:
			print("GENCHUNK %d,%d gen_ms=0 thread=1 t=%d" % [cx, cz, Time.get_ticks_msec()])
		return 0
	# AC-0040: the banana-tree pass (shore dirt edge only) runs on the
	# world-building landings — WorldGen.generate itself stays untouched
	# (the genhash arm hashes it directly; the AC-0215 baseline holds).
	var gdata: PackedByteArray = WorldGen.generate(cx, cz, Game.world_seed)
	var gres: Dictionary = WorldGen.apply_banana_trees(gdata, cx, cz, Game.world_seed, Data.HEIGHT)
	c.data_landed(gdata, PackedByteArray())
	_pool_touch()  # AC-0217: sync data landed on a queued entry
	_banana_register(cx, cz, gres["fruits"])
	gen_count += 1
	_low_fog_for(c)  # AC-0231: the immediate fog-box first pass (far only)
	_apply_edits_to_chunk(c)
	var dg := Time.get_ticks_msec() - tg
	if timing:
		print("GENCHUNK %d,%d gen_ms=%d t=%d" % [cx, cz, dg, Time.get_ticks_msec()])
	perf_gen_ms += dg
	gen_ms_total += dg
	chunk_origin[_key(cx, cz)] = "gen"
	return dg

# AC-0216: the lazy-skip decision at generation time (MAIN THREAD only —
# the worker has no camera). OFFSCREEN INTERIOR = band > 1 (the band-3
# data-only collar/ring — outside the render circle, never meshed until
# the player approaches) AND the whole column AABB is offscreen (fully
# past the camera frustum expanded by FRUSTUM_CULL_MARGIN — the exact
# "culled" test of the AC-0109 manual cull pass). When set, the C++ gen
# skips the 150-pt density evaluation for the chunk (lazy: solid fill to
# the heightmap surface, no caves — no hidden caves built); visible bands
# 0/1 always keep the full AC-0215 density field (caves exact where the
# player can see them).
func _gen_skip_flag(cx: int, cz: int) -> int:
	var b := band_of(cx - last_pcx, cz - last_pcz)
	if b <= 1:
		return 0
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		# No live camera (the headless build phase before the player
		# spawns): a throwaway camera at the recenter point facing -Z
		# (default forward), eye at the heightmap surface + 2 —
		# representative of a player standing at spawn. The skip decision
		# only — never rendered, never added to the tree.
		var vc := Camera3D.new()
		vc.fov = 75.0
		var hgt: int = WorldGen.terrain_height(last_pcx * 16 + 8, last_pcz * 16 + 8, Game.world_seed)
		vc.global_transform = Transform3D(Basis.IDENTITY, Vector3(float(last_pcx) * 16.0 + 8.0, float(hgt) + 2.0, float(last_pcz) * 16.0 + 8.0))
		cam = vc
	_cull_frustum_planes(cam)
	_cull_cen = Vector3(float(cx) * 16.0 + 8.0, float(Data.HEIGHT) * 0.5, float(cz) * 16.0 + 8.0)
	for i in 6:
		var d: float = _cull_planes[i].distance_to(_cull_cen)
		# Offscreen only if the WHOLE column is past the expanded plane.
		if d + _cull_col_span[i] < -FRUSTUM_CULL_MARGIN:
			return 1
	return 0


func threadgen_enqueue(cx: int, cz: int, key: String, inst: int, regen: bool = false, colgen: int = -1) -> void:
	if _tg_inflight_keys.has(key):
		_tg_dedup += 1
		return
	if threadgen_inflight.size() >= threadgen_max:
		_tg_capdrop += 1
		if _tg_debug:
			print("TGEN CAPDROP %d,%d inflight=%d" % [cx, cz, threadgen_inflight.size()])
		return
	var skipf := 0 if regen else _gen_skip_flag(cx, cz)  # AC-0216 (0 = full density)
	if skipf:
		perf_gen_skip_enq += 1
	# AC-0257: the vwin window is gone — generation is ALWAYS the full
	# column (the empty keep mask; bit-exact, gen is a pure f(world
	# coords, seed)).
	var entry := {"key": key, "cx": cx, "cz": cz, "inst": inst, "colgen": colgen, "args": [cx, cz, Game.world_seed, Data.HEIGHT, Data.SEA, skipf, PackedByteArray()], "tenq": Time.get_ticks_msec(), "regen": regen}
	# AC-0203 recenter fix: the data pass now runs HIGH priority.
	# AC-0160 pinned it LOW to "pace at 3-wide" (the belief that 4.x low
	# priority = half the threads, 3 of 6). Godot 4.7.1's WorkerThreadPool
	# runs LOW-priority add_task work on ONE thread (measured here: 36 x
	# 145 ms tasks, high = 5.97 eff threads, low = 1.00; raw Threads = 5.96).
	# That one-thread lane (shared with the low-priority IO reads/writes)
	# throttled the gen feed to ~4/s while the 6-thread mesh pool idled at
	# 28%, starving the forward builds — the 4x recenter regression.
	# High priority shares all 6 threads with the (also high) mesh builds;
	# walking demand is ~1.5 threads total (3-inflight gen cap + builds),
	# far under 6, so neither starves. IO tasks stay LOW (small, disk).
	var tid = threadgen_pool.add_task(_threadgen_worker, true)
	entry["tid"] = tid
	_tg_slots_mutex.lock()
	_tg_slots[tid] = entry
	_tg_slots_mutex.unlock()
	threadgen_inflight.append(entry)
	_tg_inflight_keys[key] = true
	_tg_enq += 1
	if _tg_debug:
		print("TGEN ENQ %d,%d inflight=%d" % [cx, cz, threadgen_inflight.size()])

func _threadgen_worker() -> void:
	var tid = threadgen_pool.get_caller_task_id()
	_tg_slots_mutex.lock()
	var entry = _tg_slots.get(tid)
	_tg_slots_mutex.unlock()
	# AC-0178: the slot is set a couple of statements AFTER add_task returns;
	# a worker preempting in that window used to see no slot and return with
	# NO result -> null handoff (AC-0137-class SCRIPT ERROR + a stranded
	# column; 4 hits in the 30-min pre-fix probe). Spin until the slot
	# appears; giving up still lands in the threadgen_poll re-enqueue below.
	var ns := 0
	while entry == null and ns < 2000:
		OS.delay_msec(1)
		_tg_slots_mutex.lock()
		entry = _tg_slots.get(tid)
		_tg_slots_mutex.unlock()
		ns += 1
	if entry == null:
		if timing:
			print("TGSPIN_GIVEUP tid=%d" % tid)  # AC-0178 diag (timing-gated)
		return
	var a: Array = entry["args"]
	var wt := Time.get_ticks_msec()
	if timing:
		_tg_concur += 1
		if _tg_concur > _tg_concur_peak:
			_tg_concur_peak = _tg_concur
	# AC-0203 recenter fix: worker-side palettize (same as the burst worker)
	# — the drain's main-thread handoff is a reference slab landing.
	# AC-0188: C++ generation (coarse 3D density) — the worker gets the
	# palettized slabs straight from C++. AC-0208: C++-ONLY — the AWECRAFT_
	# GENCPP kill switch and the GDScript generate_args fallback were
	# removed (the C++ extension is required).
	var g: Variant = WorldGen.gen_cpp()
	# AC-0216: a[5] = the offscreen-interior lazy-skip flag (0 = full
	# density, computed on the main thread at enqueue time).
	# AC-0237: a[6] = the window keep mask (empty = the full column —
	# the pre-AC-0237 call, bit-identical).
	var keep: PackedByteArray = a[6] if int(a.size()) > 6 else PackedByteArray()
	var resl: Array = g.generate_resl(int(a[0]), int(a[1]), int(a[2]), int(a[3]), int(a[4]), int(a[5]), keep)
	gen_cpp_works += 1
	if timing:
		print("TGENW %d,%d wms=%d spin=%d cc=%d wait=%d skip=%d t=%d" % [int(a[0]), int(a[1]), Time.get_ticks_msec() - wt, ns, _tg_concur, wt - int(entry.get("tenq", wt)), int(a[5]), Time.get_ticks_msec()])
		_tg_concur -= 1
	entry["result"] = resl

func _startup_gen_worker(i: int) -> void:
	# AC-0160 run 2: one group element = one 5x5 chunk gen. Writes ONLY its
	# own slot (AC-0082 handoff pattern); the main thread applies it. The
	# recenter side keeps the elems/slots arrays stable while a burst is in
	# flight (_startup_gen_group_tids guard), so i is always a valid slot
	# index — the bounds check is a belt against a pool regression.
	if i >= _startup_gen_elems.size() or i >= _startup_gen_slots.size():
		return
	var e: Array = _startup_gen_elems[i]
	if bool(e[3]):
		return
	var wbt := Time.get_ticks_usec()
	# AC-0203 recenter fix: palettize on the worker — the main-thread burst
	# handoff becomes a reference slab landing (the flat column never hits
	# the main thread).
	# AC-0188: C++ generation (same path as threadgen). AC-0208: C++-ONLY —
	# the GDScript generate_args fallback was removed (the C++ extension is
	# required).
	var g: Variant = WorldGen.gen_cpp()
	# AC-0216: e[7] = the offscreen-interior lazy-skip flag (0 = full
	# density, computed on the main thread at burst-build time).
	var resl: Array = g.generate_resl(int(e[1]), int(e[2]), int(e[4]), int(e[5]), int(e[6]), int(e[7]))
	gen_cpp_works += 1
	_startup_gen_slots[i] = resl
	if timing:
		print("GENBURSTW %d,%d wms=%d t=%d" % [int(e[1]), int(e[2]), (Time.get_ticks_usec() - wbt) / 1000, Time.get_ticks_msec()])

func _startup_gen_apply() -> void:
	# AC-0160 run 2: main-thread handoff for the burst results — the exact
	# threadgen_handoff shape (data + init_fl + edits). Applies every ready
	# slot each frame; the burst slots land spread over ~1.2 s, so the
	# per-frame cost tracks the burst's own rate. Duplicates (a drain TG
	# enqueue raced the group) are dropped on c.data already set. The slot
	# array is stable while the burst is in flight (the recenter
	# _startup_gen_group_tids guard), so a slot's elems[i] is always the
	# chunk the worker generated.
	if _startup_gen_slots.is_empty():
		return
	# AC-0263: DEAD-SLOT SELF-HEAL — a burst element whose worker died
	# (a worker exception: the gen_cpp lazy-init race pre-fix, anything
	# else) never lands, and its pending_n count then holds the startup
	# build-hold FOREVER (the drain can't run the data pass that would
	# regenerate the chunk — a spawn deadlock, measured at r16: 0/25
	# high band for 14 min on 2 dead elements). The burst's worst case is
	# ~1.3 s (24 x ~165 ms / 3-wide); long past that, every still-dead
	# slot is resolved: the pending count drops, the hold lifts, and the
	# chunk's data lane (threadgen — fully queue-driven since AC-0263)
	# regenerates it.
	if _startup_gen_started_ms > 0 \
			and _startup_gen_pending_n > 0 \
			and Time.get_ticks_msec() - _startup_gen_started_ms > 5000:
		for i in _startup_gen_slots.size():
			if _startup_gen_pending_n <= 0:
				break
			# had_data elements were never counted (the worker no-ops
			# them by design) — their null slots are not dead.
			if i >= _startup_gen_elems.size() or bool(_startup_gen_elems[i][3]):
				continue
			var dd = _startup_gen_slots[i]
			if dd == null or not (dd is Array):
				_startup_gen_slots[i] = null
				_startup_gen_pending_n = maxi(0, _startup_gen_pending_n - 1)
				# Feed the dead chunk's data NOW (the data pass itself is
				# gated behind _spawn_fast, which stays set until the 3x3
				# is meshed — which needs THIS data; a second deadlock).
				# _gen_unit is the full lane (disk-first read, else
				# threadgen) minus the caller's pacing.
				var he: Array = _startup_gen_elems[i]
				var hc = chunks.get(_key(int(he[1]), int(he[2])))
				if hc != null and hc.data.is_empty():
					_gen_unit(hc, int(he[1]), int(he[2]))
	for i in _startup_gen_slots.size():
		var d = _startup_gen_slots[i]
		if d == null or not (d is Array) or int(d.size()) != 2:
			continue
		_startup_gen_slots[i] = null
		_startup_gen_pending_n = maxi(0, _startup_gen_pending_n - 1)
		var e: Array = _startup_gen_elems[i]
		var c = chunks.get(_key(int(e[1]), int(e[2])))
		if c == null or not c.data.is_empty():
			continue
		# AC-0203 recenter fix: worker-palettized slabs — reference landing.
		# AC-0040: the banana-tree pass (e = [_, cx, cz, _, seed, h, sea, skip]).
		var gres: Dictionary = WorldGen.apply_banana_resl(d, int(e[1]), int(e[2]), int(e[4]), Data.HEIGHT)
		c.slabs_landed(d[0], d[1])
		_pool_touch()  # AC-0217: burst data landed on a queued entry
		_banana_register(int(e[1]), int(e[2]), gres["fruits"])
		gen_count += 1
		chunk_origin[_key(int(e[1]), int(e[2]))] = "gen"  # AC-0155
		_low_fog_for(c)  # AC-0231: the immediate fog-box first pass (far only)
		_apply_edits_to_chunk(c)
		if timing:
			print("GENHAND %d,%d t=%d" % [int(e[1]), int(e[2]), Time.get_ticks_msec()])

func threadgen_poll() -> void:
	if threadgen_inflight.is_empty():
		return
	var i := 0
	while i < threadgen_inflight.size():
		var e: Dictionary = threadgen_inflight[i]
		var tid = int(e["tid"])
		if threadgen_pool.is_task_completed(tid):
			threadgen_inflight.remove_at(i)
			_tg_inflight_keys.erase(e["key"])
			_tg_slots_mutex.lock()
			_tg_slots.erase(tid)
			_tg_slots_mutex.unlock()
			var res = e.get("result", null)
			if res == null or not (res is Array) or int(res.size()) != 2:
				# AC-0178: the worker finished without a result (slot-spin
				# gave up) — re-enqueue the gen instead of a null handoff
				# (SCRIPT ERROR + stranded column). Dedup-safe: the key was
				# just erased above, the chunk is still data-empty. At
				# SHUTDOWN the world is being freed — drop instead of
				# re-enqueue (see _shutting_down). AC-0203 recenter fix: the
				# result is now a [data_slabs, fl_slabs] pair (worker-palettized).
				if _shutting_down:
					continue
				if _tg_debug:
					print("TGEN RETRY %d,%d (no result)" % [int(e["cx"]), int(e["cz"])])
				# AC-0247: the retry captures the live chunk's col_gen (the
				# chunk may have been evicted+respawned since the dispatch —
				# a pooled reuse keeps the instance_id, so col_gen is the
				# identity token the handoff validates).
				var rc: Node3D = chunks.get(e["key"])
				threadgen_enqueue(int(e["cx"]), int(e["cz"]), e["key"], int(e["inst"]), false, int(rc.col_gen) if rc != null else -1)
				continue
			threadgen_handoff(e, res)
			continue
		i += 1

func threadgen_handoff(e: Dictionary, resl: Array) -> void:
	# AC-0203 recenter fix: resl = [data_slabs, fl_slabs] (worker-palettized
	# — the flat column never lands on the main thread).
	if resl == null or int(resl.size()) != 2 or not (resl[0] is Array):
		return
	var key: String = e["key"]
	var c = chunks.get(key)
	if c == null:
		_tg_stale += 1
		if _tg_debug:
			print("TGEN STALE %d,%d (chunk gone)" % [int(e["cx"]), int(e["cz"])])
		return
	var expected_inst: int = int(e["inst"])
	# AC-0247: + col_gen — a pooled column REUSE keeps its instance_id, so
	# the inst check alone cannot see a freed-and-respawned column.
	if expected_inst >= 0 and (int(c.get_instance_id()) != expected_inst or int(c.col_gen) != int(e.get("colgen", -1))):
		_tg_stale += 1
		if _tg_debug:
			print("TGEN STALE %d,%d (inst mismatch %d != %d)" % [int(e["cx"]), int(e["cz"]), expected_inst, int(c.get_instance_id())])
		return
	# AC-0237: a[6] = the keep mask the gen ran with (empty = the full
	# column). A NON-EMPTY mask landing on a chunk that ALREADY has data
	# is a scoped RE-ENTRY REGEN — merge its slabs (only the slabs that
	# actually generated replace; the null sections keep the existing
	# data); any other double-landing is a stale drop.
	var ekeep: PackedByteArray = e["args"][6] if int(e["args"].size()) > 6 else PackedByteArray()
	# A REGEN entry landing on a chunk that already has data merges (a
	# full tier-0 regen with an empty keep mask merges too — the
	# determinism guarantee makes every regenerated slab identical).
	var is_regen: bool = bool(e.get("regen", false)) and c.data.size() != 0
	if c.data.size() != 0 and not is_regen:
		_tg_datadrop += 1
		if _tg_debug:
			print("TGEN DATADROP %d,%d (data already set)" % [int(e["cx"]), int(e["cz"])])
		return
	# AC-0040: the banana-tree pass on the worker-palettized slabs (cheap
	# sand prefilter; the full 98 KB expand happens only for shore chunks).
	var tcx: int = int(e["cx"])
	var tcz: int = int(e["cz"])
	var tseed: int = int(e["args"][2])
	var gres: Dictionary = WorldGen.apply_banana_resl(resl, tcx, tcz, tseed, Data.HEIGHT)
	if is_regen:
		var ds: Array = resl[0]
		for si in range(c.data.size()):
			if si < int(ds.size()) and ds[si] is Dictionary:
				c.data[si] = ds[si]
		c.update_top()  # the merged column's highest non-air (idempotent for a below-span regen)
		c.data_gen += 1  # the stamp/staleness token (an in-flight build on the pre-regen snapshot goes stale)
	else:
		c.slabs_landed(resl[0], resl[1])
	# AC-0237: stamp the generated state (the re-entry check + the
	# snap_rings genkeep read it).
	var gm := 0xFFFFFF
	if not ekeep.is_empty():
		gm = c.gen_mask if is_regen else 0
		for si2 in range(ekeep.size()):
			if int(ekeep[si2]) != 0:
				gm |= (1 << si2)
	c.gen_keep = ekeep
	c.gen_mask = gm
	_banana_register(tcx, tcz, gres["fruits"])
	gen_count += 1
	chunk_origin[e["key"]] = "gen"  # AC-0155
	_apply_edits_to_chunk(c)
	_tg_handoff += 1
	_pool_touch()  # AC-0217: queued entry's data landed (pool membership flipped)
	_low_fog_for(c)  # AC-0231: the immediate fog-box first pass (far only)
	if timing or _tg_debug:
		print("GENHAND %d,%d t=%d" % [int(e["cx"]), int(e["cz"]), Time.get_ticks_msec()])


# --- AC-0107 threaded mesh+light (desktop) -------------------------------

func _tm_worker_run(skey: int) -> void:
	# Worker body: pure-static pipeline (ChunkScript.build_accs) on fresh
	# copies. Reads only its own entry (written before add_task) and writes
	# entry["result"] — the AC-0082 handoff pattern, proven in this codebase.
	# skey is a globally unique slot id (one counter across BOTH pools) —
	# pool-local task ids would collide between the shared pool and the
	# dedicated edit pool.
	# AC-0152: the dispatcher sets _tm_slots[skey] a couple of statements
	# AFTER add_task returns; an idle worker thread can preempt the main
	# thread in that window and see no slot yet. The slot always appears
	# (it is set before the main thread can yield to the pool again and only
	# erased at completion, i.e. after this worker returns), so spin briefly
	# instead of dropping the task. Giving up still lands in the handoff
	# datadrop + retrigger path, which re-queues (the _remove_entry
	# queued_keys fix makes that re-queue effective).
	_tm_slots_mutex.lock()
	var entry = _tm_slots.get(skey)
	_tm_slots_mutex.unlock()
	var ns := 0
	while entry == null and ns < 200:
		OS.delay_msec(1)
		_tm_slots_mutex.lock()
		entry = _tm_slots.get(skey)
		_tm_slots_mutex.unlock()
		ns += 1
	if entry == null:
		return
	entry["t_run"] = Time.get_ticks_usec()
	if bool(entry.get("low", false)):
		# AC-0257 (stale-LOD, absorbs AC-0256): the PRE-START early-out —
		# the wanted band tier moved while the task sat in the queue:
		# skip the emit entirely (the slab stays PENDING against its live
		# tier and the lane re-picks it there). The live-tier read is a
		# pair of ints (last_pcx/last_pcz) + the boundary int — the
		# handoff's main-thread check is the arbiter (a stale read here
		# costs at most one wasted emit).
		var live_tier := _lod_tier_of(int(entry["cx"]) - last_pcx, int(entry["cz"]) - last_pcz)
		if live_tier != int(entry.get("tier", 1)):
			entry["result"] = {"skipped": true}
			low_skip_stale_n += 1
			return
		# AC-0236 part 2 / AC-0252: the low-lane emit — the C++
		# AweMesh.low_emit_avg on the value-copied slab column (the
		# band-tier AVERAGE-COLOR grid: 8 = MED 8x8x8 / 4 = LOW 4x4x4, the
		# full-volume air rule + the per-face average color from the fcc
		# cache; reads only this entry). The node attach stays on the main
		# thread (the _low_handoff branch in threadmesh_handoff — Godot
		# SceneTree). The TEXTURED low_emit (the dormant 4x4x4 path) keeps
		# its binding but is no longer called by the lanes.
		var mcl: Variant = ChunkScript.mesh_cpp()
		var grid := 8 if int(entry.get("tier", 1)) == 1 else 4
		entry["result"] = mcl.low_emit_avg(entry["slabs"], int(entry["si"]), grid, entry["fcc"])
		low_emit_cpp += 1
		return
	# AC-0152/AC-0160: all bands (0/1/2) flow through the normal build_accs
	# path — band 2 lost its one-quad impostor (removed per user decision)
	# and is a full mesh now, so every entry carries nbs/eff like 0/1.
	# AC-0187: edit entries carry si0/si1 (slab-scoped fast remesh); the
	# defaults rebuild every slab exactly as before.
	if timing:
		_tm_concur += 1
		if _tm_concur > _tm_concur_peak:
			_tm_concur_peak = _tm_concur
	# AC-0190: C++ meshing (gdext/src/mesh.cpp — AweMesh.build_accs, the
	# LOSSLESS port of the GDScript build_accs pipeline: slab decode
	# (paletted slabs unpacked in C++), bake box, snap, ro scan, greedy
	# merged emit). The worker passes the same value-copy inputs
	# (data/fl/nbs/ctx/ms/eff) + the pre-warmed _att/_glow tables (the C++
	# path self-lights an empty eff through the SAME C++ pull kernel —
	# awelight::pull). AC-0208: C++-ONLY — the AWECRAFT_MESHCPP kill switch
	# and the GDScript build_accs fallback were removed (the C++ extension
	# is required).
	var mc: Variant = ChunkScript.mesh_cpp()
	# AC-0234: entry["mask"] = the vertical-window keep mask at dispatch
	# (24 bytes; EMPTY = tier 0 / full build — byte-identical to the
	# pre-AC-0234 call). Masked slabs are skipped like all-air slabs; the
	# black cap renders them on the main thread.
	var res: Dictionary = mc.build_accs(entry["data"], entry["fl"], int(entry["cx"]), int(entry["cz"]), entry["nbs"], entry["ctx"], entry["ms"], entry["eff"], int(entry.get("si0", 0)), int(entry.get("si1", -1)), int(entry.get("d_off", 0)), Lighting._att, Lighting._glow, entry.get("mask", PackedByteArray()))
	mesh_cpp_builds += 1
	if timing:
		_tm_concur -= 1
	if bool(entry.get("epool", false)):
		# AC-0187: the edit lane has no engine task id — completion rides a
		# per-entry flag written under the pool's guard mutex (the barrier
		# the shared pool's is_task_completed provides for its tasks).
		if threadmesh_edit_pool != null:
			threadmesh_edit_pool.mark_done(entry, res)
		else:
			entry["result"] = res
	else:
		entry["result"] = res

# AC-0229: the speed factor — 0.5 while still (< 0.5 m/s), 1.0 at the
# WALK reference (4.3 m/s, the AC-0225 no-op point), saturating at 12.0
# (50x flight = 215 m/s is far past the knee).
func _dyn_speed_factor() -> float:
	if _dyn_speed < 0.5:
		return DYN_SPEED_FACTOR_STILL
	return clampf(_dyn_speed / DYN_SPEED_WALK, DYN_SPEED_FACTOR_STILL, DYN_SPEED_FACTOR_MAX)


# AC-0229: the radius factor — R/16 clamped to [1.0, 2.0] (the ahead-ring
# width ratio, R50/R16 ~ 32/14). r4 harness arms and R16 keep 1.0.
func _dyn_radius_factor() -> float:
	return clampf(float(render_radius) / float(DYN_RADIUS_REF), 1.0, DYN_RADIUS_FACTOR_MAX)


# AC-0229: the dynamic-budget decomposition (harness evidence — the r16
# and perf arms report it; base = the slider value in force, cap = the
# effective per-frame burst the threadmesh_poll gate uses).
func stream_ho_dyn() -> Dictionary:
	var base := clampi(
		int(Settings.values.get("chunks_per_frame", STREAM_TM_HANDOFF_PER_FRAME)),
		Settings.CHUNKS_PER_FRAME_MIN, Settings.CHUNKS_PER_FRAME_MAX)
	return {
		"base": base,
		"speed_mps": roundf(_dyn_speed * 10.0) / 10.0,
		"speed_factor": roundf(_dyn_speed_factor() * 1000.0) / 1000.0,
		"radius": int(render_radius),
		"radius_factor": roundf(_dyn_radius_factor() * 1000.0) / 1000.0,
		"cap": int(stream_ho_cap),
	}


func threadmesh_poll() -> void:
	if threadmesh_inflight.is_empty():
		return
	# AC-0178: loading window — pace the handoff batch. Each handoff's
	# _eff_landed face-block refresh costs ~70 ms avg (0.4-1.0 s tail on the
	# first landing wave), so a full batch (up to LOAD_TM_CAP deep) blocks
	# the main thread 1-2.5 s — long enough to let the pool's queue drain to
	# idle between dispatch waves (measured ~40% pool idle). Capping the
	# batch to LOAD_TM_HANDOFF/frame keeps the frame bounded; the inflight
	# gate oscillates at the handoff rate so the pool queue stays deep
	# (~LOAD_TM_CAP - lag - running) and the workers never starve.
	# AC-0219: global per-frame streaming handoff cap (steady state) — at
	# most stream_ho_cap non-edit meshes land per process frame (the
	# AC-0224 burst, default STREAM_TM_HANDOFF_PER_FRAME = 3; tunable via
	# AWECRAFT_TM_HO), for ALL move sizes and bands (not just the small-
	# move trickle). A recenter's ahead-band fill used to land every ready
	# mesh at once (up to the hb_max 64) in one frame: each landing is
	# apply_accs + collision + the _eff_landed face-block refresh on the
	# main thread, so the burst tanked the frame. Capped, the ahead band
	# fills over a few frames instead (AC-0224: a small burst per frame —
	# "a few per tick" like Minecraft, not a hard 1 — so a recenter's ahead
	# ring lands in ~1/3 the frames): unlanded entries simply stay in
	# threadmesh_inflight (nothing is dropped or re-queued — the dispatch
	# gate already blocks re-dispatch on in-flight keys) and land next
	# frame; no pop-in (a mesh appears the frame its build is ready, just
	# a small burst at a time). The loading window keeps its own
	# LOAD_TM_HANDOFF pace and the shutdown poll-drain must run UNCAPPED or
	# it stalls against the frozen process-frame counter (the 20 s exit cap
	# would then force-clear in-flight tasks — the AC-0178 shutdown
	# segfault class). Edit-lane (epool) handoffs are exempt: a user edit
	# must not sit behind the streaming cap (the edit lane is
	# dispatch-staggered).
	var hb_max := LOAD_TM_HANDOFF if loading_active else 64
	var streaming := not loading_active and not _shutting_down
	if streaming:
		var pf := Engine.get_process_frames()
		if pf != _stream_ho_frame:
			_stream_ho_frame = pf
			_stream_ho_n = 0
			# AC-0225: the slider value (1-100) is the BASE burst — read it
			# each process frame so a mid-session slider change lands the
			# next frame (the AWECRAFT_TM_HO env preloads this same setting
			# at boot). AC-0229: scale the base by the player's speed and
			# the render radius (see the DYN_* constants) — higher when
			# moving fast or at a large render, lower when still. The
			# effective cap stays inside the slider range, so the slider
			# still bounds the burst from above.
			var base := clampi(
				int(Settings.values.get("chunks_per_frame", STREAM_TM_HANDOFF_PER_FRAME)),
				Settings.CHUNKS_PER_FRAME_MIN, Settings.CHUNKS_PER_FRAME_MAX)
			var dp = Game.player  # untyped: Game.player has no declared type
			if dp != null:
				var pnow := Vector2(float(dp.position.x), float(dp.position.z))
				if _dyn_have_prev:
					var dtm := (float(Time.get_ticks_usec()) - float(_dyn_prev_t)) / 1000000.0
					if dtm > 0.0:
						var inst := pnow.distance_to(_dyn_prev_pos) / dtm
						# Smoothed: a 0.3 lerp converges in ~10 frames
						# (200 ms at 60 fps) and returns the cap to the
						# still level ~250 ms after the player stops.
						_dyn_speed = lerpf(_dyn_speed, inst, 0.3)
				_dyn_prev_pos = pnow
				_dyn_prev_t = Time.get_ticks_usec()
				_dyn_have_prev = true
			else:
				# No player (build phase, the perf R50 arm, menu) = the
				# still behavior.
				_dyn_have_prev = false
				_dyn_speed = 0.0
			stream_ho_cap = clampi(
				roundi(float(base) * _dyn_speed_factor() * _dyn_radius_factor()),
				Settings.CHUNKS_PER_FRAME_MIN, Settings.CHUNKS_PER_FRAME_MAX)
	var hb_t0 := Time.get_ticks_usec() if timing else 0
	var hb_n := 0
	var found := true
	while found and hb_n < hb_max:
		found = false
		for j in range(threadmesh_inflight.size()):
			var ee: Dictionary = threadmesh_inflight[j]
			if not ee.has("key") or not ee.has("skey"):
				# AC-0203: torn-read guard (see loop 2 below) — the entry's
				# dict is being written on the pool thread; skip this frame.
				continue
			if bool(ee.get("epool", false)) and bool(ee.get("done", false)):
				var eskey = int(ee.get("skey", -1))
				threadmesh_inflight.remove_at(j)
				_tm_inflight_keys.erase(ee["key"])
				if eskey >= 0:
					_tm_slots_mutex.lock()
					_tm_slots.erase(eskey)
					_tm_slots_mutex.unlock()
				_editprobe_prime_flag = true
				threadmesh_handoff(ee, ee.get("result", null))
				hb_n += 1
				found = true
				break
	var i := 0
	while i < threadmesh_inflight.size() and hb_n < hb_max and edit_inflight_count == 0:
		var e: Dictionary = threadmesh_inflight[i]
		if not e.has("key") or not e.has("tid"):
			# AC-0203: torn-read guard. The pool worker writes
			# entry["t_run"]/["result"] on its thread while this poll reads
			# the SAME Dictionary every frame (the AC-0082 handoff pattern —
			# the worker write shape is pre-existing, unchanged by this
			# task); GDScript Dictionaries are not thread-safe, so a key
			# lookup can transiently fail (observed: the entry briefly reads
			# as an empty dict). Skip this entry for this frame — the next
			# poll sees a consistent dict and hands off normally. A torn
			# handoff read degrades to null result = datadrop + retrigger
			# (safe re-queue), never a corrupted apply.
			i += 1
			continue
		# AC-0219/AC-0224: steady state — once this frame's streaming burst
		# (stream_ho_cap, default 3) is used, stop scanning: the unlanded
		# entries wait in threadmesh_inflight for the next frame (nothing
		# is dropped or re-queued; the dispatch gate already blocks
		# re-dispatch on in-flight keys). Edit-lane (epool) entries are
		# EXEMPT — a user edit must not sit behind the streaming cap (they
		# are rare: loop 1 above already takes every completed epool entry).
		if streaming and not bool(e.get("epool", false)) and _stream_ho_n >= stream_ho_cap:
			break
		var tidv = e.get("tid", null)
		if tidv == null:
			# AC-0203/AC-0224: torn read that slipped PAST the has() guard
			# above — the pool worker is mid-write on this Dictionary (the
			# AC-0082 handoff pattern; Dictionaries are not thread-safe),
			# so the has/read pair can transiently disagree. A direct
			# e["tid"] access would then raise a SCRIPT ERROR and abort the
			# whole poll for the frame (observed once at the AC-0224 3-burst
			# rate, which triples the per-frame dict reads vs the 1-cap).
			# Skip this entry for this frame — it stays in
			# threadmesh_inflight and the next poll sees a consistent dict
			# (the AC-0203 skip path, made exception-free).
			i += 1
			continue
		var tid = int(tidv)
		var skey = int(e.get("skey", -1))
		var completed := false
		if bool(e.get("epool", false)):
			completed = bool(e.get("done", false))
		else:
			completed = threadmesh_pool.is_task_completed(tid)
		if completed:
			threadmesh_inflight.remove_at(i)
			_tm_inflight_keys.erase(e["key"])
			if skey >= 0:
				_tm_slots_mutex.lock()
				_tm_slots.erase(skey)
				_tm_slots_mutex.unlock()
			_editprobe_prime_flag = false
			threadmesh_handoff(e, e.get("result", null))
			hb_n += 1
			if streaming and not bool(e.get("epool", false)):
				_stream_ho_n += 1
			continue
		i += 1
	if timing and hb_n > 0:
		print("TMPOLL n=%d ms=%.1f t=%d" % [hb_n, (Time.get_ticks_usec() - hb_t0) / 1000.0, Time.get_ticks_msec()])  # AC-0178 diag (timing-gated)

func _tm_retrigger(key: String, c: Node3D, e: Dictionary) -> void:
	# A dropped result can't be applied: rebuild from current state.
	# Meshed chunks re-enter the light-flush queue (fresh bulk eff);
	# not-yet-meshed chunks re-enter the build band queue.
	if bool(c.mesh_built):
		if not light_pending_set.has(key):
			light_pending.append(key)
			light_pending_set[key] = true
			perf_lightpend_retrigger += 1  # AC-0218: drop retrigger adds
		flush_active = true
	else:
		_enqueue_build(int(e["cx"]), int(e["cz"]))

func threadmesh_handoff(e: Dictionary, res) -> void:
	var key: String = e["key"]
	if bool(e.get("low", false)):
		# AC-0236 part 2: the low-lane attach (its own bookkeeping — the
		# high stale/band/drop machinery does not apply to placeholders).
		_low_handoff(e, res)
		return
	if bool(e.get("edit", false)):
		edit_inflight_count = maxi(0, edit_inflight_count - 1)
	var c = chunks.get(key)
	if c == null:
		_tm_stale += 1
		if _tm_debug:
			print("TMESH STALE %d,%d (chunk gone)" % [int(e["cx"]), int(e["cz"])])
		return
	# AC-0247: + col_gen — a pooled column REUSE keeps its instance_id, so
	# the inst check alone cannot see a freed-and-respawned column.
	if int(c.get_instance_id()) != int(e["inst"]) or int(c.col_gen) != int(e.get("colgen", -1)):
		_tm_stale += 1
		if _tm_debug:
			print("TMESH STALE %d,%d (inst mismatch)" % [int(e["cx"]), int(e["cz"])])
		return
	if res == null:
		_tm_datadrop += 1
		if _tm_debug:
			print("TMESH DATADROP %d,%d (no result)" % [int(e["cx"]), int(e["cz"])])
		_tm_retrigger(key, c, e)
		return
	var stale := false
	if bool(e.get("scoped_snap", false)):
		# AC-0187: edit entries carry row-scoped snapshots (d_off..d_hi); a
		# change outside the scoped rows cannot affect the applied slabs
		# (geometry outside is untouched, light is frozen by design).
		# AC-0203: rows compared value-wise (256 B windows) — same coverage
		# as the old flat slice, extracted from the slab store.
		# AC-0211: the row windows are decoded in C++ (rows_eq — no 4096
		# flat materialization per row). AC-0208: C++-ONLY — the GDScript
		# row-loop fallback (mc2==null) was removed.
		var dlo := int(e["d_off"])
		var dhin := int(e["d_hi"])
		var mc2: Variant = ChunkScript.mesh_cpp()
		stale = not (mc2.rows_eq(c.data, e["data"], dlo, dhin) and mc2.rows_eq(c.fl, e["fl"], dlo, dhin))
	else:
		stale = int(c.data_gen) != int(e["stamp"][0]) or int(c.fl_gen) != int(e["stamp"][1])
	if stale:
		_tm_datadrop += 1
		if key == _editprobe_key:
			_editprobe_drop += 1
		if _tm_debug:
			print("TMESH DATADROP %d,%d (data/fl changed mid-build)" % [int(e["cx"]), int(e["cz"])])
		_tm_retrigger(key, c, e)
		return
	# AC-0152: the band can change mid-flight (recenter on player movement)
	# — a stale-band result is dropped and the chunk re-queues fresh.
	if int(e.get("band", int(c.band))) != int(c.band):
		_tm_datadrop += 1
		if _tm_debug:
			print("TMESH BANDBREAK %d,%d (band %d != %d)" % [int(e["cx"]), int(e["cz"]), int(e.get("band", -1)), int(c.band)])
		_tm_retrigger(key, c, e)
		return
	# AC-0234: the TIER can change mid-flight too — a window-masked build
	# (a non-empty mask) landing on a column that is NOW the player's own
	# would leave its deep slabs unbuilt under the player's feet: drop and
	# re-queue the FULL build (the fall-through contract re-dispatches it
	# with an empty mask).
	if int(e.get("mask", PackedByteArray()).size()) > 0 \
			and _tier_of(int(e["cx"]) - last_pcx, int(e["cz"]) - last_pcz) == 0:
		_tm_datadrop += 1
		if _tm_debug:
			print("TMESH VWINBREAK %d,%d (window build -> tier 0)" % [int(e["cx"]), int(e["cz"])])
		_tm_retrigger(key, c, e)
		return
	if not _editprobe_key.is_empty() and key == _editprobe_key:
		_editprobe_kind = "edit" if bool(e.get("edit", false)) else "wave"
		if _editprobe_t0_usec > 0:
			_editprobe_ms = float(Time.get_ticks_usec() - _editprobe_t0_usec) / 1000.0
			_editprobe_t0_usec = 0
			_editprobe_wms = int(res.get("wms", 0))
			_editprobe_ph = res.get("ph", [])
			_editprobe_dq = int(int(e.get("t_run", 0)) - int(e.get("t_submit", 0)))
			_editprobe_nq = int(res.get("nq", 0))
			_editprobe_prime = _editprobe_prime_flag
			_editprobe_handoff_at = Time.get_ticks_usec()
			_editprobe_submit_at = int(e.get("t_submit", 0))
			_editprobe_done_ms = int((int(e.get("t_done", 0)) - int(e.get("t_submit", 0))) / 1000.0)
			_editprobe_ns = res.get("ns", [])
			_editprobe_phet = res.get("phet", [])
			_editprobe_prime_flag = false
	if bool(e.get("hslab", false)):
		# AC-0263: a per-slab FULL-RES landing (the tier-0 section / the
		# high-band rings). The scoped stale check (rows_eq on the
		# dispatch window) and the band check above already ran. Scoped
		# retain-swap attach (the edit lane's machinery, mark_complete=false
		# — a slab landing does NOT complete the column), the slab's
		# placeholder (fog/low) drops, the completion stamp lands (empty
		# all-air builds stamped too — done, not pending), and the probe
		# flips mesh_built when the column owes nothing.
		var si_h: int = int(e["si0"])
		var ta_h := Time.get_ticks_msec()
		var old_eff_h = c.last_eff
		c.apply_edit_accs(res, _tm_ms_full, false)
		c.high_stamps[si_h] = int(c.data_gen)
		_low_drop_slab(c, si_h)
		_fog_drop_slab(c, si_h)
		_hslab_probe_invalidate(c)
		if not bool(c.mesh_built) and _hslab_best_pending(c) < 0:
			c.mesh_built = true
			# high-complete: the column's placeholders are all gone now
			# (each landing dropped its own) — nothing to free in bulk.
		c.saved_light = {}
		perf_build_ms += Time.get_ticks_msec() - ta_h
		perf_build_worker_ms += int(res.get("wms", 0))
		perf_build_worker_ms_list.append(int(res.get("wms", 0)))
		_count_collision_build(c)
		_stage_check(c, key)
		_eff_landed(c, old_eff_h, res.get("light", {}))
		if bool(e.get("eff_trust", false)):
			_eff_cache_put(key, c, res.get("light", {}), e.get("ngen", null))
		_tm_handoff += 1
		_tm_hslab_n += 1  # AC-0263: the per-slab lane's landing count
		# AC-0263: section evidence — the INITIAL section's completion (the
		# first tier-0 column to finish high; a later recenter's new
		# section column does not move the milestone).
		if _hslab_section_done_frame < 0 \
				and _is_tier0_col(int(e["cx"]) - last_pcx, int(e["cz"]) - last_pcz):
			_hslab_section_done_frame = Time.get_ticks_msec()
		# AC-0263: NO _drop_queued — the entry STAYS queued (the column's
		# remaining slabs are still pending) and is re-picked next frame;
		# the pick removes it the frame the probe finds nothing left.
		if timing or _tm_debug:
			print("BUILDCHUNK_H %d,%d slab=%d build_ms=%d t=%d" % [int(e["cx"]), int(e["cz"]), si_h, int(res.get("wms", 0)), Time.get_ticks_msec()])
		return
	if bool(e.get("edit", false)):
		var ta2 := Time.get_ticks_msec()
		var old_eff2 = c.last_eff
		c.apply_edit_accs(res, _tm_ms_full)
		# AC-0263: an edit's scoped remesh is a HIGH landing — stamp the
		# covered slabs done at the NEW data_gen (the edit window includes
		# the boundary slabs, so the probe won't re-owe them).
		for si_e in range(int(res.get("si0", 0)), int(res.get("si1", 0)) + 1):
			c.high_stamps[si_e] = int(c.data_gen)
		c.saved_light = {}
		perf_build_ms += Time.get_ticks_msec() - ta2
		perf_build_worker_ms += int(res.get("wms", 0))
		perf_build_worker_ms_list.append(int(res.get("wms", 0)))
		_count_collision_build(c)
		_stage_check(c, key)
		_eff_landed(c, old_eff2, res.get("light", {}))
		if bool(e.get("eff_trust", false)):
			_eff_cache_put(key, c, res.get("light", {}), e.get("ngen", null))
		_tm_handoff += 1
		_drop_queued(key)
		if timing or _tm_debug:
			print("BUILDCHUNK_E %d,%d build_ms=%d t=%d" % [int(e["cx"]), int(e["cz"]), int(res.get("wms", 0)), Time.get_ticks_msec()])
		return
	# AC-0231 order-gate evidence: a tier >= 2 high landing while in-r lows
	# are still pending = gate leakage. Measured with the DISPATCH-time tier
	# (the gate's decision point — the live tier re-scores the chunk against
	# the player's NEW position and would count every legitimate tier 0/1
	# dispatch that outran the player, e.g. fly50). Only tasks already in
	# flight at the moment the gate re-closed can land this way — the
	# dispatch itself is gated, so this must stay near 0.
	if int(e.get("tier", -1)) >= 2 and not _low_inr_drained:
		perf_high_before_low_n += 1
		if not bool(c.mesh_built):
			# a FIRST high build (new coverage) while in-r low pending —
			# the in-flight straggler class (dispatched in a legitimate
			# open window, landed after a re-close). Re-meshes (the chunk
			# already showed high) don't breach the ordering contract.
			perf_high_before_low_firstbuild_n += 1
	var ta := Time.get_ticks_msec()
	var old_eff = c.last_eff
	if not bool(c.mesh_built):
		_tm_full_firstbuild_n += 1  # AC-0263: first-build evidence
	c.apply_accs(res, _tm_ms_full)
	# AC-0263: a full-column landing stamps every slab at/below the top
	# done (the per-slab probe's completion record for the legacy path).
	for si_f in range(mini(int(c.top) >> 4, int(c.data.size() - 1)) + 1):
		c.high_stamps[si_f] = int(c.data_gen)
	_hslab_probe_invalidate(c)
	c.saved_light = {}
	# AC-0231 rewrite: the high REPLACES the per-slab placeholders (the
	# fog boxes + the 4x4x4 textured lows) at every slab's Y. Keep-high
	# from here on — a meshed chunk is never downgraded to low
	# (low_downgrade_n stays 0; the low path only serves never-built
	# slabs).
	_lod_free_all(c, true)
	# AC-0257: the vwin window stamps/sync/owed re-queue are gone — the
	# build covers every slab (the empty mask) and nothing is culled.
	perf_build_ms += Time.get_ticks_msec() - ta
	perf_build_worker_ms += int(res.get("wms", 0))
	perf_build_worker_ms_list.append(int(res.get("wms", 0)))
	var tb := Time.get_ticks_msec() if timing else 0  # AC-0178 diag (timing-gated)
	_count_collision_build(c)
	var tc := Time.get_ticks_msec() if timing else 0
	_stage_check(c, key)
	var td := Time.get_ticks_msec() if timing else 0
	_eff_landed(c, old_eff, res.get("light", {}))
	if timing:
		print("TMH_PART %d,%d apply=%d col=%d stage=%d eff=%d t=%d" % [int(e["cx"]), int(e["cz"]), tb - ta, tc - tb, td - tc, Time.get_ticks_msec() - td, Time.get_ticks_msec()])  # AC-0178 diag (timing-gated)
	if bool(e.get("eff_trust", true)):
		_eff_cache_put(key, c, res.get("light", {}), e.get("ngen", null))
	_tm_handoff += 1
	# AC-0160: a meshed chunk must never keep a queued entry (the pools skip
	# mesh_built entries forever). The pre-warm queue runs in parallel with
	# the recenter slice, so an entry consumed before the merge swap can be
	# re-added by the WANT rebuild and strand the drain — drop it here.
	_drop_queued(key)
	if timing or _tm_debug:
		print("BUILDCHUNK_T %d,%d build_ms=%d t=%d" % [int(e["cx"]), int(e["cz"]), int(res.get("wms", 0)), Time.get_ticks_msec()])

func _drop_queued(key: String) -> void:
	# AC-0160: O(bucket) removal by key (the _qb fast path of _remove_entry
	# without the entry dict). No-op when the key is not queued.
	var b0: int = int(_qb.get(key, -1))
	if b0 < 0 or b0 >= band_buckets.size():
		return
	var arr0: Array = band_buckets[b0]
	for i in range(arr0.size()):
		if arr0[i]["key"] == key:
			if not bool(arr0[i].get("data_only", false)):
				_build_q_n -= 1  # AC-0222
			arr0.remove_at(i)
			_qb.erase(key)
			queued_keys.erase(key)
			queue_size -= 1
			_pool_touch()  # AC-0217: a pool candidate left the queue
			return

func _eff_stored_eq(a: Dictionary, b: Dictionary) -> bool:
	if int(a.get("w", -1)) != int(b.get("w", -1)):
		return false
	if int(a.get("d", -1)) != int(b.get("d", -1)):
		return false
	if a.get("mn", null) != b.get("mn", null):
		return false
	var aa: PackedByteArray = a.get("arr", PackedByteArray())
	var bb: PackedByteArray = b.get("arr", PackedByteArray())
	if aa.size() != bb.size():
		return false
	if aa != bb:
		return false
	if a.get("blk_src", -1) != b.get("blk_src", -1):
		return false
	return true


# AC-0233: dirtyQueue append — set_block pushes the edited chunk (key + dirty
# slab closure). NO immediate dispatch: the chunk waits for the FIRST drain
# (1 per process frame, ahead of the streaming queue) so edits show
# immediately without racing the set_block caller.
func _dirty_add(key: String, y: int) -> void:
	var si0 := maxi(0, (y - 3) / 16)
	var si1 := mini(ChunkScript.slab_n() - 1, (y + 1) / 16)
	for e in dirty_queue:
		if e["key"] == key:
			e["si0"] = mini(int(e["si0"]), si0)
			e["si1"] = maxi(int(e["si1"]), si1)
			return
	dirty_queue.append({"key": key, "si0": si0, "si1": si1})
	dirty_set[key] = true
	# AC-0231: an edit stamps the chunk — a far textured low for it may now be
	# stale (the low rebuilds from the edited data on the next low scan).
	# Invalidate the cached no-candidate verdict (edits don't bump _pool_ver).
	# AC-0231 fix3: the WAVE 2 slab-wave verdict too (the edit may have made
	# a slab stale — or mined a fogged slab out, dropping it from pending).
	# AC-0231: the order gate (the edit may have made an in-r low stale —
	# or mined a fogged in-r slab out; far edits don't touch the gate).
	_low_none_key = ""
	_low_slab_none_key = ""
	var cc = chunks.get(key)
	if cc != null:
		var ddx := int(cc.cx) - last_pcx
		var ddz := int(cc.cz) - last_pcz
		if absi(ddx) + absi(ddz) <= render_radius:  # AC-0261: taxi edge (the gate is a no-op)
			_low_inr_invalidate()


# AC-0199: _dirty_add + jump the entry to the FRONT of the dirty queue.
# A boundary edit (local x/z in [0,1] or [14,15]) changes the NEIGHBOR's
# 18-wide snap ring (SNAP_W = 16 + 1 per side): the neighbor's face
# toward this column is stale until it re-meshes, and the light wave
# that would cover it paces at ~500 ms - the see-through hole. The
# extend of AC-0187's front priority: the neighbor dispatches next
# frame, ahead of every queued streaming entry. Its build reads the
# edited chunk's snap_rings from DATA (already updated by set_block),
# so it is correct independent of the edited chunk's mesh handoff.
func _dirty_front(key: String, y: int) -> void:
	_dirty_add(key, y)
	for i in range(dirty_queue.size()):
		if dirty_queue[i]["key"] == key:
			if i > 0:
				var e = dirty_queue[i]
				dirty_queue.remove_at(i)
				dirty_queue.push_front(e)
			return


func _dirty_entry(key: String):
	for e in dirty_queue:
		if e["key"] == key:
			return e
	return null


func _dirty_drop(key: String) -> void:
	for i in range(dirty_queue.size()):
		if dirty_queue[i]["key"] == key:
			dirty_queue.remove_at(i)
			dirty_set.erase(key)
			return


func _dirty_dispatch(key: String) -> void:
	var e: Dictionary = _dirty_entry(key)
	if e == null:
		return
	var c = chunks.get(key)
	if c == null or not bool(c.mesh_built):
		_dirty_drop(key)
		return
	if not _build_ready(int(c.cx), int(c.cz)):
		return
	if _tm_inflight_keys.has(key):
		return
	if _edit_stale_eff.size() > 32:
		_edit_stale_eff.clear()
	var cached = _edit_stale_eff.get(key)
	if cached == null:
		if not _mesh_dispatch(c, int(c.cx), int(c.cz), {}, true, true):
			return
		perf_edit_front_full += 1
		_dirty_drop(key)
		return
	if not _eff_stored_eq(cached.eff, c.last_eff):
		_dirty_drop(key)
		return
	if not _mesh_dispatch_edit(c, int(c.cx), int(c.cz), int(e["si0"]), int(e["si1"]), cached.eff):
		return
	perf_edit_front_scoped += 1
	_dirty_drop(key)


# AC-0233: the dirtyQueue drains FIRST — 1 remesh per process frame, ahead of
# the light_pending flush and the streaming drain, so an edit never waits
# behind the speculative streaming queue.
func _dirty_drain() -> void:
	if _shutting_down or dirty_queue.is_empty():
		return
	var key: String = dirty_queue[0]["key"]
	var c = chunks.get(key)
	if c == null or not bool(c.mesh_built):
		_dirty_drop(key)
		return
	_dirty_dispatch(key)


func _mesh_dispatch_edit(c: Node3D, cx: int, cz: int, si0: int, si1: int, fast_eff: Dictionary) -> bool:
	var key := _key(cx, cz)
	c.col_immediate = _col_immediate_for(cx, cz)
	if c.data.is_empty():
		return false
	if _tm_inflight_keys.has(key):
		_tm_dedup += 1
		return false
	if threadmesh_inflight.size() >= threadmesh_max:
		_tm_capdrop += 1
		if _tm_debug:
			print("TMESH EDITCAPDROP %d,%d inflight=%d" % [cx, cz, threadmesh_inflight.size()])
		return false
	var y_lo := si0 * 16
	var y_hi := mini(Data.HEIGHT, (si1 + 1) * 16)
	var d_lo := maxi(0, y_lo - 2)
	var d_hi := mini(Data.HEIGHT - 1, y_hi + 1)
	var tn0 := Time.get_ticks_usec()
	# AC-0203: scoped entries carry FULL slab copies (~20 KB/col, not 192 KB
	# flat) — the worker reads only rows si0..si1, and the handoff stale
	# check value-compares the same rows it extracted at dispatch.
	# AC-0211: the nbs snapshot is the C++ compact ring (256 B/slab) — the
	# scoped stale check below uses rows_eq on the SAME paletted shape.
	# AC-0208: C++-ONLY — the GDScript deep-copy nbs (the mc==null fallback)
	# was removed.
	var nbs: Dictionary = {}
	var mc: Variant = ChunkScript.mesh_cpp()
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			if (dx == 0) == (dz == 0):
				continue
			var nc = chunks.get(_key(cx + dx, cz + dz))
			if nc == null or nc.data.is_empty():
				return false
			nbs["%d,%d" % [dx, dz]] = mc.snap_rings(nc.data, nc.fl, dx, dz, nc.gen_keep)  # AC-0237: ungenerated slabs read as solid
	var tn1 := Time.get_ticks_usec()
	var ms_w: Dictionary
	if not _tm_ms_full.rects.is_empty():
		ms_w = {"rects": _tm_ms_full.rects.duplicate(), "h": float(_tm_ms_full.get("h", 0.0))}
	else:
		ms_w = {"rects": {}}
	var strips = _strips_for_scoped(cx, cz, y_lo, y_hi)
	var tn2 := Time.get_ticks_usec()
	_editprobe_dnbs = int(tn1 - tn0)
	_editprobe_dstrips = int(tn2 - tn1)
	var ctx_w: Dictionary = _tm_ctx.duplicate()
	ctx_w["eff_strips"] = strips["eff"]
	ctx_w["blk_strips"] = strips["blk"]
	ctx_w["blk_strips_b"] = strips["blk_b"]
	# AC-0231: the band-2 coarse ctx (coarse/uv_scale) is gone — full fidelity.
	# AC-0211: own-column value-copy via C++ (AC-0208: the only lane).
	# AC-0247: the slab BUFFERS of these copies stay on C++ alloc — slab_copy
	# allocates the "i"/"p" buffers internally (no C++ changes allowed) and
	# a GDScript pooled copy measured ~230 us/col (per-byte loop, 98
	# us/4096 B) vs the C++ copy's ~9 us/col — a net CPU regression. The
	# lifetime was proven (entry = last consumer, return-at-handoff); the
	# keep-on-alloc is perf-driven (see the report).
	var entry := {
		"key": key, "cx": cx, "cz": cz, "inst": c.get_instance_id(), "colgen": int(c.col_gen),
		"data": mc.slab_copy(c.data),  # AC-0208: C++-only value copy (the GDScript _slabs_deepcopy fallback is gone)
		"fl": mc.slab_copy(c.fl),
		"stamp": c.stamp(),
		"band": int(c.band),
		"nbs": nbs, "eff": fast_eff, "eff_trust": false,
		"ctx": ctx_w, "ms": ms_w, "ngen": _ngens_for(cx, cz),
		"edit": true, "si0": si0, "si1": si1,
		"scoped_snap": true, "d_off": d_lo, "d_hi": d_hi,
		"t_submit": Time.get_ticks_usec(),
	}
	var skey := _tm_next_slot
	_tm_next_slot += 1
	var tid := -1
	if threadmesh_edit_pool != null:
		threadmesh_edit_pool.submit(_tm_worker_run.bind(skey))
	entry["tid"] = tid
	entry["skey"] = skey
	entry["epool"] = true
	_tm_slots_mutex.lock()
	_tm_slots[skey] = entry
	_tm_slots_mutex.unlock()
	_tm_inflight_keys[key] = tid
	threadmesh_inflight.append(entry)
	edit_inflight_count += 1
	_tm_enq += 1
	_bd_log(cx, cz)
	if _tm_debug:
		print("TMESH EDIT %d,%d slabs=%d-%d inflight=%d" % [cx, cz, si0, si1, threadmesh_inflight.size()])
	return true

func _mesh_dispatch(c: Node3D, cx: int, cz: int, eff: Dictionary, eff_trust := true, defer_on_cap := false) -> bool:
	if not timing:
		return _mesh_dispatch_impl(c, cx, cz, eff, eff_trust, defer_on_cap)
	var _t0 := Time.get_ticks_usec()
	var _r: bool = _mesh_dispatch_impl(c, cx, cz, eff, eff_trust, defer_on_cap)
	print("DISPATCHMS %d,%d ms=%.1f t=%d" % [cx, cz, (Time.get_ticks_usec() - _t0) / 1000.0, Time.get_ticks_msec()])
	return _r


func _mesh_dispatch_impl(c: Node3D, cx: int, cz: int, eff: Dictionary, eff_trust := true, defer_on_cap := false) -> bool:
	# true = covered (sync-built now, or an in-flight task will apply);
	# false = deduped behind an in-flight task (caller may want to retry).
	# Sync fallbacks (spawn chunk, no own data, missing neighbor, cap-drop)
	# run the legacy build_mesh path unchanged. eff_trust marks effs whose
	# light values came from the contained per-chunk kernel (cache/empty);
	# bulk flush effs are untrusted and must not enter the eff cache.
	# AC-0126: defer_on_cap=true (the edit flush) turns the cap-drop sync
	# fallback into a re-queue (return false) — the spike remover. All
	# other call sites keep the default (false = legacy sync).
	c.col_immediate = _col_immediate_for(cx, cz)
	var key := _key(cx, cz)
	# AC-0152/AC-0160 (AC-0263): band 2 has no special path anymore — the
	# impostor dispatch was removed; it builds a full mesh through the same
	# nbs/eff/worker pipeline as band 0/1. AC-0263: the SYNC FALLBACKS ARE
	# GONE (fully queue-driven — no main-thread builds ever): no-data,
	# missing-neighbor and cap-drop all DEFER (return false); the callers
	# keep the queue entry and retry when the data/neighbors land or a
	# worker slot frees. (The spawn contract that motivated the legacy
	# fallbacks is now the startup burst, which AC-0263 extended to carry
	# the center column.)
	if c.data.is_empty():
		perf_edit_syncs += 1
		return false  # AC-0263: the data lane owns it (the sync gen is gone)
	var nbs: Dictionary = {}
	var mc: Variant = ChunkScript.mesh_cpp()
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			if (dx == 0) == (dz == 0):
				continue
			var nc = chunks.get(_key(cx + dx, cz + dz))
			if nc == null or nc.data.is_empty():
				# AC-0160 (AC-0263): a missing neighbor DEFERS (the caller's
				# retry re-queues; threadgen delivers the missing data within
				# ~500 ms). The legacy sync fallback (100-500 ms of main-
				# thread build) is GONE — there is no on-demand sync gen for
				# workers to fall back on, so the defer is the only path.
				perf_edit_syncs += 1
				return false
			# AC-0211: C++ compact snap ring (256 B/slab, the boundary
			# slice only) — replaces the per-neighbor _slabs_deepcopy of
			# all 24 slabs; the C++ build_accs consumes it directly and
			# the worker never sees live neighbor state (the ring is a
			# main-thread value snapshot). AC-0208: C++-ONLY — the GDScript
			# deep-copy nbs (the mc==null fallback) was removed.
			nbs["%d,%d" % [dx, dz]] = mc.snap_rings(nc.data, nc.fl, dx, dz, nc.gen_keep)  # AC-0237: ungenerated slabs read as solid
	if _tm_inflight_keys.has(key):
		_tm_dedup += 1
		if _tm_debug:
			print("TMESH DEDUP %d,%d" % [cx, cz])
		return false
	# AC-0160 run 2: the spawn frame dispatches all nine 3x3 builds in one
	# drain frame. The default cap (6) would defer-on-cap three of them;
	# their retry lands on the frame of the FIRST landing — whose handoff
	# face-cache refresh blocks the main thread ~2.5 s (the region cascade
	# runs on fresh d=2 data) — pushing the 3x3 back to ~4.5 s. A 9-wide
	# cap during startup only: the 6-thread pool queues the last three
	# high-priority tasks and runs them as the first round finishes (no
	# main-thread involvement). Post-startup the cap is threadmesh_max.
	var tm_cap := threadmesh_max
	if _startup_pending() and tm_cap < 9:
		tm_cap = 9
	tm_cap = maxi(1, tm_cap - (2 if not dirty_queue.is_empty() else 1))
	if threadmesh_inflight.size() >= tm_cap:
		_tm_capdrop += 1
		if _tm_debug:
			print("TMESH CAPDROP %d,%d inflight=%d" % [cx, cz, threadmesh_inflight.size()])
		# AC-0263: the cap-drop sync fallback is GONE — a full pool DEFERS
		# (return false); the caller keeps the queue entry and retries when
		# a worker slot frees. (defer_on_cap's legacy sync branch never ran
		# any more than the others: all call sites now defer.)
		perf_edit_defers += 1
		return false
	var ms_w: Dictionary
	if not _tm_ms_full.rects.is_empty():
		ms_w = {"rects": _tm_ms_full.rects.duplicate(), "h": float(_tm_ms_full.get("h", 0.0))}
	else:
		ms_w = {"rects": {}}
	# AC-0129: fresh strip copies ride on the entry (the worker self-lights
	# through the pull kernel / bakes its 20x20 box from them); ngen = the
	# 4 neighbor eff_gens at THIS dispatch (the cache-entry validation key).
	var strips = _strips_for(cx, cz)
	var ctx_w: Dictionary = _tm_ctx.duplicate()
	ctx_w["eff_strips"] = strips["eff"]
	ctx_w["blk_strips"] = strips["blk"]
	ctx_w["blk_strips_b"] = strips["blk_b"]
	ctx_w["top"] = int(c.top)  # AC-0197: full builds stop at the top slab
	# AC-0231: the band-2 coarse ctx (coarse/uv_scale) is gone — every meshed
	# band builds full fidelity (the far LOD is the separate low placeholder).
	# AC-0211: the own-column value-copy goes through C++ (AC-0208: the
	# only lane — the worker + the handoff stale check consume the same
	# paletted shape). AC-0247: the slab BUFFERS stay on C++ alloc (slab_copy
	# is C++; a GDScript pooled copy measured ~230 us/col vs ~9 us/col —
	# perf-driven keep-on-alloc; lifetime was proven, see the report).
	var entry := {
		"key": key, "cx": cx, "cz": cz, "inst": c.get_instance_id(), "colgen": int(c.col_gen),
		"data": mc.slab_copy(c.data),  # AC-0208: C++-only value copy (the GDScript _slabs_deepcopy fallback is gone)
		"fl": mc.slab_copy(c.fl),
		"stamp": c.stamp(),
		"band": int(c.band),
		"nbs": nbs, "eff": eff, "eff_trust": eff_trust,
		"ctx": ctx_w, "ms": ms_w, "ngen": _ngens_for(cx, cz),
		# AC-0233: the dispatch wall time (the edit-lane entry carried it;
		# the wave lane now does too) — the handoff's queue/worker split
		# diagnostics read it, and the R16 edit probe uses it to verify a
		# handoff's task was submitted AFTER the probe's set_block (a
		# pre-edit in-flight handoff does not carry the edit).
		"t_submit": Time.get_ticks_usec(),
		# AC-0231 order gate: the tier at DISPATCH (the gate's decision
		# point) — the handoff's leak counter must use THIS, not the live
		# tier: by the time the task lands the player has moved (fly50 =
		# 215 m/s; a dispatch-time ring-1 chunk is ring 3-5 at landing) and
		# a legitimate tier 0/1 dispatch would read as a "leak".
		"tier": _tier_of(cx - last_pcx, cz - last_pcz),
	}
	# AC-0160 run 2: HIGH priority. The pool is the same 6-thread
	# WorkerThreadPool the data pass shares. (AC-0203: the data pass is now
	# high too — 4.7.1's low lane is 1 thread, not the 3-of-6 this comment
	# assumed; with both high the pool shares all 6 threads and the ~1.5
	# threads of walking demand leave headroom for both.)
	# High priority admits build tasks to the run queue unconditionally, so
	# the 2 build slots run at ~7/s alongside the data pass.
	var skey := _tm_next_slot
	_tm_next_slot += 1
	var tid = threadmesh_pool.add_task(_tm_worker_run.bind(skey), true)
	entry["tid"] = tid
	entry["skey"] = skey
	_tm_slots_mutex.lock()
	_tm_slots[skey] = entry
	_tm_slots_mutex.unlock()
	_tm_inflight_keys[key] = tid
	threadmesh_inflight.append(entry)
	_tm_enq += 1
	if defer_on_cap:
		perf_edit_dispatches += 1
		if eff.is_empty():
			perf_edit_light_passes += 1
	_bd_log(cx, cz)
	if _tm_debug:
		print("TMESH ENQ %d,%d inflight=%d" % [cx, cz, threadmesh_inflight.size()])
	return true

# AC-0263: the per-slab HIGH dispatch — the full-res build of ONE slab
# (si0=si1=si) through the normal worker pool. Same inputs as the edit
# lane's scoped entry (the C++ compact nbs ring + the own-column value
# copy + the row-scoped stale window around the slab); the worker's
# build_accs already scopes on si0/si1 (the edit lane proved the path —
# no C++ change). The sync fallbacks are GONE (fully queue-driven): a
# no-data column or a missing neighbor DEFERS (return false) — the data
# lane delivers the work and the queue re-picks (the entry stays queued;
# the in-flight dedup paces one slab in flight per column). true = a
# worker task owns the slab; false = deferred (the caller keeps the entry
# and ends the frame, as with a cap drop).
func _mesh_dispatch_hslab(c: Node3D, cx: int, cz: int, si: int, eff: Dictionary) -> bool:
	var key := _key(cx, cz)
	c.col_immediate = _col_immediate_for(cx, cz)
	if c.data.is_empty():
		return false  # AC-0263: the data lane owns it (the sync gen is gone)
	if _tm_inflight_keys.has(key):
		_tm_dedup += 1
		return false
	var tm_cap := threadmesh_max
	if _startup_pending() and tm_cap < 9:
		tm_cap = 9
	tm_cap = maxi(1, tm_cap - (2 if not dirty_queue.is_empty() else 1))
	if threadmesh_inflight.size() >= tm_cap:
		_tm_capdrop += 1
		if _tm_debug:
			print("TMESH HSLABCAPDROP %d,%d slab=%d inflight=%d" % [cx, cz, si, threadmesh_inflight.size()])
		return false
	var nbs: Dictionary = {}
	var mc: Variant = ChunkScript.mesh_cpp()
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			if (dx == 0) == (dz == 0):
				continue
			var nc = chunks.get(_key(cx + dx, cz + dz))
			if nc == null or nc.data.is_empty():
				return false  # AC-0263: defer — the neighbor lands, the entry retries
			nbs["%d,%d" % [dx, dz]] = mc.snap_rings(nc.data, nc.fl, dx, dz, nc.gen_keep)  # AC-0237: ungenerated slabs read as solid
	var y_lo := si * 16
	var y_hi := (si + 1) * 16 - 1
	var d_lo := maxi(0, y_lo - 1)
	var d_hi := mini(Data.HEIGHT - 1, y_hi + 1)
	var ms_w: Dictionary
	if not _tm_ms_full.rects.is_empty():
		ms_w = {"rects": _tm_ms_full.rects.duplicate(), "h": float(_tm_ms_full.get("h", 0.0))}
	else:
		ms_w = {"rects": {}}
	var strips = _strips_for_scoped(cx, cz, y_lo, y_hi)
	var ctx_w: Dictionary = _tm_ctx.duplicate()
	ctx_w["eff_strips"] = strips["eff"]
	ctx_w["blk_strips"] = strips["blk"]
	ctx_w["blk_strips_b"] = strips["blk_b"]
	var entry := {
		"key": key, "cx": cx, "cz": cz, "inst": c.get_instance_id(), "colgen": int(c.col_gen),
		"data": mc.slab_copy(c.data),  # AC-0208: C++-only value copy (the worker + the handoff stale check share the shape)
		"fl": mc.slab_copy(c.fl),
		"stamp": c.stamp(),
		"band": int(c.band),
		"nbs": nbs, "eff": eff, "eff_trust": true,
		"ctx": ctx_w, "ms": ms_w, "ngen": _ngens_for(cx, cz),
		"tier": _tier_of(cx - last_pcx, cz - last_pcz),
		"hslab": true, "si0": si, "si1": si,
		"scoped_snap": true, "d_off": d_lo, "d_hi": d_hi,
		"t_submit": Time.get_ticks_usec(),
	}
	var skey := _tm_next_slot
	_tm_next_slot += 1
	var tid = threadmesh_pool.add_task(_tm_worker_run.bind(skey), true)
	entry["tid"] = tid
	entry["skey"] = skey
	_tm_slots_mutex.lock()
	_tm_slots[skey] = entry
	_tm_slots_mutex.unlock()
	_tm_inflight_keys[key] = tid
	threadmesh_inflight.append(entry)
	_tm_enq += 1
	_bd_log(cx, cz)
	if _tm_debug:
		print("TMESH HSLAB %d,%d slab=%d inflight=%d" % [cx, cz, si, threadmesh_inflight.size()])
	return true

func _build_unit(c: Node3D, cx: int, cz: int) -> bool:
	# Returns true when DEFERRED (worker slots full / task already in flight
	# for this key — the caller keeps the queue entry and ends the frame);
	# false when covered (sync-built now, or a worker task owns it).
	var tb := Time.get_ticks_msec()
	# AC-0107: threaded dispatch when eligible; sync fallbacks inside keep the
	# legacy path. dt is the MAIN-thread cost (dispatch/apply), the worker-side
	# total is reported via perf_build_worker_ms / BUILDCHUNK_T.
	# AC-0079 v3 C2 (the AC-0077 follow-up): contained light is OFF the main
	# thread — cached eff when it matches the chunk data (the cache is now fed
	# by worker handoffs via _eff_cache_put), otherwise an empty eff and the
	# worker self-lights its own fresh copy through the byte-identical
	# contained kernel (ChunkScript.build_accs / Lighting.compute_light_flat_chunk).
	var eff := _eff_for(c, cx, cz)
	if eff.is_empty() and not c.saved_light.is_empty():
		eff = c.saved_light
		light_saved_restores += 1
	if eff.is_empty():
		perf_light_self_computes += 1
	# AC-0160 run 2: the drain dispatch is defer-on-cap. The cap-drop SYNC
	# fallback was the real spawn serializer (NOT the missing-neighbor branch
	# the 8-neighbor gate already covered): while the 2 TM slots were busy
	# (E2 re-lights included) every drain dispatch sync-built 270-1235 ms on
	# the main thread — 1 unit/frame, 14.6 s for the 3x3. defer_on_cap turns
	# the cap drop into a defer (true return -> the caller keeps the entry);
	# the 8-neighbor _build_ready gate makes the missing-neighbor sync branch
	# unreachable from the drain; the (0,0) spawn-chunk sync contract stays
	# inside _mesh_dispatch unchanged. (The AC-0152 "sync = third build
	# worker" measurement predates the gate: it traded main-thread frames for
	# throughput; the AC-0160 gate requires frames ~40 ms, so the workers are
	# the only build path.)
	var covered := _mesh_dispatch(c, cx, cz, eff, true, true)
	var dt := Time.get_ticks_msec() - tb
	last_build_us = dt * 1000
	if timing:
		if covered:
			print("BUILDCHUNK %d,%d gen_ms=0 build_ms=%d t=%d" % [cx, cz, dt, Time.get_ticks_msec()])
		else:
			print("BUILDDEFER %d,%d t=%d" % [cx, cz, Time.get_ticks_msec()])
	perf_build_ms += dt
	return not covered

# AC-0263: the per-slab high variant of _build_unit — dispatches ONE slab
# (the (layer, taxi) rings' build unit) through the worker pool. Same
# contained-light handling as _build_unit (cached eff when it matches,
# otherwise the worker self-lights through the byte-identical contained
# kernel); returns true when DEFERRED (data/neighbor missing, in-flight
# dedup, or the TM cap — the caller keeps the queue entry and ends the
# frame), false when a worker task owns the slab.
func _build_unit_hslab(c: Node3D, cx: int, cz: int, si: int) -> bool:
	var tb := Time.get_ticks_msec()
	var eff := _eff_for(c, cx, cz)
	if eff.is_empty() and not c.saved_light.is_empty():
		eff = c.saved_light
		light_saved_restores += 1
	var covered := _mesh_dispatch_hslab(c, cx, cz, si, eff)
	var dt := Time.get_ticks_msec() - tb
	last_build_us = dt * 1000
	if timing:
		if covered:
			print("BUILDCHUNK_H %d,%d slab=%d build_ms=%d t=%d" % [cx, cz, si, dt, Time.get_ticks_msec()])
		else:
			print("BUILDDEFER_H %d,%d slab=%d t=%d" % [cx, cz, si, Time.get_ticks_msec()])
	perf_build_ms += dt
	return not covered

# AC-0233/AC-0250: _entry_score (the continuous d + look-ahead score) is
# replaced by the 3-tier priority (_tier_of/_tier_score) — under (0), the
# sim radius (1), the rest by taxi distance (2, look-independent).

func _collect_pool(build: bool, include_fb := false, maxb := -1, high_only := false) -> Array:
	# AC-0079 round 3: the pick is score-driven (spec: generate the LOWEST score
	# among no-data entries), so the pool must not be clipped by the sticky FIFO
	# cursors — a stale dq_b/mq_b (entries consumed out of band order, cursor
	# parked past the last band) would empty the pool and starve the drain
	# forever. Cursors are bookkeeping only (cursor-advance on consume, exact
	# queue_size); the pool scans every band with the same cap as before.
	# AC-0079 v3 C1: include_fb additionally admits the forward lead column's
	# data_only entries (cx == last_pcx + r, |cz - last_pcz| <= r) — the drain's
	# second pass can pre-build a ready lead chunk before the general scored
	# sweep reaches it. Bounded: the band is exactly 2r+1 entries. Admitted
	# entries carry no data guarantee; the drain applies the full gate
	# (data + mesh_built + _build_ready) to every candidate.
	var out: Array = []
	# AC-0160: maxb caps the scan at bucket index maxb (the drain window);
	# -1 = unbounded (legacy behavior for out-of-drain callers).
	var last_b := band_buckets.size() - 1
	if maxb >= 0:
		last_b = mini(maxb, last_b)
	for b in range(last_b + 1):
		var arr: Array = band_buckets[b]
		for i in range(arr.size()):
			if out.size() >= PICK_POOL_CAP:
				return out
			var e: Dictionary = arr[i]
			var c = chunks.get(e["key"])
			if build:
				if bool(e["data_only"]):
					if include_fb and int(e["cx"]) == last_pcx + render_radius \
							and absi(int(e["cz"]) - last_pcz) <= render_radius:
						out.append(e)
					continue
				# AC-0257: keep-high — a meshed column is skipped.
				if c == null or c.data.is_empty() or c.mesh_built:
					continue
				if high_only:
					# AC-0262: the visible band's build entries are the slab
					# wave's work list, not the drain's. The per-pick high
					# gate below the caller would null the top pick every
					# frame (the wave keeps up — its entries always out-score
					# the high band's deep slabs on the (layer, taxi) order),
					# and the deep-slab high band (a high layer rank) starved
					# behind them forever: a recentered center chunk with
					# deep pending slabs stayed unmeshed indefinitely
					# (measured: r16 settle frozen on 6 slabs of the new
					# taxi-0 chunk while the drain dispatched 0 units).
					# Pre-filter the drain's pool to the high band only.
					var dxh := int(e["cx"]) - last_pcx
					var dzh := int(e["cz"]) - last_pcz
					if absi(dxh) + absi(dzh) >= medium_start_r and not _is_tier0_col(dxh, dzh):
						continue
				out.append(e)
			else:
				if c == null or not c.data.is_empty():
					continue
				out.append(e)
	return out

# --- AC-0217: the cached scored picks (the pool/score debounce) ------------
# _pick_build_cached: the MESH candidate pick (the ThreadMesh pool6 feed):
# pool scan + re-validate + _build_ready (gen + light flat ready — the
# 8-neighbor gate) + the AC-0233/AC-0250 3-tier score, cached against the
# AC-0217 key (AC-0233/AC-0250: column + sim radius only — the tier order
# is invariant to in-column moves and to turns). On a hit the cached
# candidate is re-validated (c == null
# / data / mesh_built / _build_ready); a stale candidate re-scans instead of
# being served. A cached EMPTY pick is trusted: a membership or readiness
# change always bumps _pool_ver, so a matching key means a fresh scan would
# find nothing either.
func _pick_build_cached(maxb: int, include_fb: bool, high_only := false) -> Dictionary:
	# AC-0262: high_only gets a suffixed key — the filter changes the pool
	# contents for the same (pool state, window, center) tuple, and the
	# drain's steady pass (high_only) must not serve a load-phase verdict
	# (unfiltered) or vice versa.
	var ck := _pool_key(maxb) + ("_h" if high_only else "")
	var slot: Array = _pool_b if not include_fb else _pool_fb
	if slot.size() == 5 and slot[0] == ck:
		var e: Dictionary = slot[1]
		if e.is_empty():
			perf_pool_hits += 1
			return {"e": e, "c": null, "s": slot[3], "pool_empty": slot[4]}
		var c = chunks.get(e["key"])
		if c != null and not c.data.is_empty() \
				and not c.mesh_built \
				and _build_ready(int(e["cx"]), int(e["cz"])):
			perf_pool_hits += 1
			return {"e": e, "c": c, "s": slot[3], "pool_empty": slot[4]}
	perf_pool_misses += 1
	var bp: Array = _collect_pool(true, include_fb, maxb, high_only)
	var best_e: Dictionary = {}
	var best_c: Node3D = null
	var best_s := 1e30
	for e in bp:
		var c = chunks.get(e["key"])
		# AC-0257: keep-high — a meshed column is skipped.
		if c == null or c.data.is_empty() or c.mesh_built:
			continue
		if not _build_ready(int(e["cx"]), int(e["cz"])):
			continue
		var s := _grid_score(e)  # AC-0257: the bake order (layer, taxi)
		if s < best_s:
			best_s = s
			best_e = e
			best_c = c
	slot.resize(5)
	slot[0] = ck
	slot[1] = best_e
	slot[2] = best_c
	slot[3] = best_s
	slot[4] = bp.is_empty()
	return {"e": best_e, "c": best_c, "s": best_s, "pool_empty": bp.is_empty()}

# _pick_data_cached: the GEN candidate pick (the ThreadGen pool4 feed):
# no-data pool scan + the in-flight dedup gates + the AC-0233/AC-0250
# 3-tier score.
# SEPARATE tiered pick from _pick_build_cached — gen runs its own tiered
# order over the no-data set; the mesh pick only sees gen + light flat
# ready entries. Cached against the AC-0217 key PLUS the in-flight depths.
# The dedup state of any candidate changes only when a task enqueues or
# lands (TG: _tg_inflight_keys, disk: _io_read_keys) — and every landing
# also bumps _pool_ver — so a matching key means the skip set is unchanged.
func _pick_data_cached(maxb: int) -> Dictionary:
	var ck := _pool_key(maxb) + "_" + str(threadgen_inflight.size()) + "_" + str(_io_read_inflight.size())
	if _pool_data.size() == 5 and _pool_data[0] == ck:
		var e: Dictionary = _pool_data[1]
		if e.is_empty():
			perf_pool_hits += 1
			return {"e": e, "c": null, "s": _pool_data[3], "pool_empty": _pool_data[4]}
		var c = chunks.get(e["key"])
		if c != null and c.data.is_empty() \
				and not _tg_inflight_keys.has(e["key"]) \
				and not _io_read_keys.has(e["key"]) and not _spawn_fast:
			perf_pool_hits += 1
			return {"e": e, "c": c, "s": _pool_data[3], "pool_empty": _pool_data[4]}
	perf_pool_misses += 1
	var dp: Array = _collect_pool(false, false, maxb)
	var dp_e: Dictionary = {}
	var dp_s := 1e30
	for e in dp:
		# AC-0077: skip chunks whose gen is already in flight. The
		# scored pick used to keep re-picking the same in-flight
		# no-data entry (dedup no-op) every iteration, burning the
		# frame budget and starving the next chunk's enqueue (~1 real
		# enqueue / 5-6 frames), which left want-set stragglers
		# unbuilt by the batch pass and forced self light computes.
		if _tg_inflight_keys.has(e["key"]):
			continue
		# AC-0164: a disk read in flight owns the data landing —
		# never re-pick it for generation (same dedup rationale).
		if _io_read_keys.has(e["key"]):
			continue
		# AC-0160 run 2: while the SPAWN fast path is active, the
		# data pass enqueues NOTHING — the recenter 5x5 burst (a
		# single high-priority group task) owns the 3x3's full
		# 8-neighborhood, and far data behind the group would only
		# steal threads from the spawn build window. The pass
		# resumes the frame after the spawn 3x3 builds (_spawn_fast
		# clears) — it must not wait on _startup_pending(), which is
		# true for the whole walking session and would starve the
		# forward edge of all data (boundary gate regression).
		if _spawn_fast:
			continue
		var s := _grid_score(e)  # AC-0257: the bake order (layer, taxi)
		if s < dp_s:
			dp_s = s
			dp_e = e
	_pool_data.resize(5)
	_pool_data[0] = ck
	_pool_data[1] = dp_e
	_pool_data[2] = null
	_pool_data[3] = dp_s
	_pool_data[4] = dp.is_empty()
	return {"e": dp_e, "c": null, "s": dp_s, "pool_empty": dp.is_empty()}

func _drain_build_queue() -> void:
	_startup_gen_apply()
	_drain_units_last = 0  # AC-0231: the low idle gate (units dispatched this frame)
	if edit_inflight_count > 0:
		return
	if queue_size == 0:
		if _bl_want.is_empty() and _col_pending.is_empty():
			return
		_col_drain_step()
		return
	_rescore_step()  # AC-0233: the amortized waiting-parts rewrite (idle = 1 bool check)
	var t0 := Time.get_ticks_usec()
	# AC-0160 spawn-fast: while the spawn 3x3 is still pending, raise the
	# per-frame unit budget (3 -> 12) and time budget (x2) so the spawn ring
	# lands in ~1s; afterwards the bounded trickle budget (2/1) drains the
	# rest of the set toward steady state. (Old 3-unit budget + O(queue) pool
	# scans = 11.7s spawn and ~7.7k entries stranded at r50.)
	var startup := _startup_pending()
	# AC-0160 run 2: the spawn fast path ends the first frame the spawn 3x3
	# is built — after that the data pass and the recenter slice run
	# normally (walking recenters must stream, see the _spawn_fast note).
	if _spawn_fast and not startup:
		_spawn_fast = false
	# AC-0160 run 2: hold ALL startup builds until the 5x5 burst is fully
	# applied (the apply already ran at the top of this frame). Dispatching
	# (0,0) as soon as its d=1 gate passes (t+0.5 s) lands its handoff
	# face-cache refresh on the main thread BEFORE the d=2 apply, which
	# blocked the apply and staggered the other 8 3x3 gates — measured
	# 3x3: 4.5 s. With the hold, all 9 gates pass on one frame at burst
	# completion and all 9 dispatches go out together (the 9-wide startup
	# TM cap below), landing in ~2.3 s.
	if startup and _startup_gen_pending_n > 0:
		return
	# AC-0178: loading window — unbounded unit budget, LOAD_DRAIN_BUDGET_MS
	# time budget. AC-0231 fps-tuning: the steady-state UNIT budget is
	# WALL-CLOCK paced (the DRAIN_UNIT_PACE_MS accumulator — the chunk
	# generation/build pace is identical at 30 fps and 60 fps; at 60 fps
	# this reproduces the old 2/frame fast / 1/frame slow budgets exactly).
	var now_ms := Time.get_ticks_msec()
	var frame_dt_ms := 16.67
	if _drain_last_t > 0:
		frame_dt_ms = minf(float(now_ms) - float(_drain_last_t), DRAIN_DT_CLAMP_MS)
	_drain_last_t = now_ms
	var unit_pace := DRAIN_UNIT_PACE_MS if last_build_us < BUILD_FAST_US else DRAIN_UNIT_PACE_SLOW_MS
	var budget := 0
	if loading_active:
		budget = LOAD_DRAIN_UNITS
	elif startup:
		budget = 12
	else:
		_drain_acc_ms = minf(_drain_acc_ms + frame_dt_ms, float(DRAIN_UNITS_FRAME_CAP) * unit_pace)
		budget = mini(DRAIN_UNITS_FRAME_CAP, int(_drain_acc_ms / unit_pace))
	# AC-0213: small-move budget — right after a recenter the ahead ring was
	# just (re)queued; pace the drain at the trickle rate (1 unit/frame) for
	# SMALL_MOVE_BUDGET_MS so a tap forward does not burst 2 gen+build units
	# on top of the recenter slice work.
	if budget > 1 and not startup and not loading_active and Time.get_ticks_msec() < _sm_move_until:
		budget = 1
	# AC-0160 run 2: the startup budget used to be 2x drain_budget_ms
	# (60 ms) — but the spawn frame dispatches ALL nine 3x3 builds and each
	# dispatch costs ~30-50 ms of main-thread strip/nbs work, so 60 ms cut
	# the frame off after ~2 dispatches and the tail re-dispatched on the
	# first-landing frame (cascade-blocked) — measured 3x3: 4.5 s. The
	# 12-unit budget is the real cap now; the time budget only bounds the
	# trickle (post-startup) as before.
	var budget_us := int(1e9 if startup else drain_budget_ms * 1000)
	# AC-0160: windowed pool scan. The drain scans buckets 0.._drain_win_b
	# only (spawn-fast covers the spawn ring at b1_eff+2); the trickle window
	# grows one bucket per DRAIN_WIN_PACE_MS (wall clock — was 15 frames)
	# until it spans the whole queue, so the queue trends down continuously
	# instead of stranding the far tail.
	if _drain_win_b < 0:
		_drain_win_b = b1_eff() + 2
	if not startup and not loading_active:
		_drain_win_acc += int(frame_dt_ms)  # AC-0231 fps-tuning: ms, not frames
		if _drain_win_acc >= DRAIN_WIN_PACE_MS:
			_drain_win_acc = 0
			if _drain_win_b < _bucket_count() - 1:
				_drain_win_b += 1
	# AC-0178: loading window — full window (no trickle growth limit).
	var maxb := band_buckets.size() - 1 if loading_active else mini(_drain_win_b, band_buckets.size() - 1)
	var gen_used_ms := 0
	var units := 0
	# AC-0178: cap the per-frame disk-read enqueues during the loading window
	# (a render-distance change over a fully-saved area would otherwise
	# enqueue thousands of cheap-but-main-threaded tasks in one frame).
	var io_n0 := _io_read_inflight.size() if loading_active else 0
	# AC-0178: loading window — two independent feed phases per frame. The
	# single steady-state loop below starves the TG pool while loading: the
	# build-ready set is always non-empty (gen leads mesh), so the data pass
	# (pass 2) never ran and gen froze at ~3/s while the mesh pool idled
	# between dispatch waves (measured pre-fix: 3020/7845 gen'd in 30 min,
	# the pools ~80% idle). Phase 1 dispatches builds until the TM depth
	# (threadmesh_max = LOAD_TM_CAP) or the frame budget; phase 2 enqueues
	# gen until the TG depth (threadgen_max = LOAD_TG_CAP) or the io cap.
	# The frame is bounded (LOAD_DRAIN_BUDGET_MS) so the polls — the
	# handoffs — run every frame and the in-flight counters stay fresh; the
	# DEPTHS keep both pools saturated in between. Steady state: this block
	# never runs; the loop below is the unchanged legacy path.
	if loading_active:
		var lp_t0 := Time.get_ticks_usec()
		while Time.get_ticks_usec() - lp_t0 < LOAD_DRAIN_BUDGET_MS * 1000:
			# Phase 1: nearest build-ready entry -> worker build. The
			# per-iteration re-pick (fresh _collect_pool + re-score) keeps the
			# dispatch order adaptive: as chunks land mid-frame their scores
			# and _build_ready gates change, and a compact frontier keeps the
			# E2 light-convergence wave from re-meshing (measured: a
			# score-once snapshot order raised the full-load churn 1.3x ->
			# 1.94x — ~5000 wasted re-meshes, a net ~10 min regression).
			var lb: Array = _collect_pool(true, false, maxb)
			var le: Dictionary = {}
			var lc: Node3D = null
			var ls := 1e30
			for e in lb:
				var c = chunks.get(e["key"])
				# AC-0257 (AC-0263): keep-high — a meshed column is skipped.
				if c == null or c.data.is_empty() or c.mesh_built:
					continue
				# AC-0261 (AC-0263): the load's high builds are the HIGH band
				# only — the visible band [medium_start_r, render_radius) is
				# slab-wave owned (its avg LOD is final there).
				var dxl := int(e["cx"]) - last_pcx
				var dzl := int(e["cz"]) - last_pcz
				if absi(dxl) + absi(dzl) >= medium_start_r and not _is_tier0_col(dxl, dzl):
					continue
				if not _build_ready(int(e["cx"]), int(e["cz"])):
					continue
				var s := _grid_score(e)  # AC-0257: the bake order (layer, taxi)
				if s < ls:
					ls = s
					le = e
					lc = c
			if lc == null:
				break
			# AC-0263: per-slab — a high-complete winner (a landing raced the
			# pick) frees its entry and the loop re-picks; otherwise the best
			# slab is dispatched and the entry STAYS queued for the rest.
			var sih := _hslab_best_pending_cached(lc)
			if sih < 0:
				_remove_entry(le)
				continue
			if _build_unit_hslab(lc, int(le["cx"]), int(le["cz"]), sih):
				break  # deferred (TM depth) — phase 2 feeds the TG pool now
			units += 1
		# Phase 2: nearest no-data entry -> TG pool (disk read first).
		while threadgen_inflight.size() < threadgen_max:
			var dp: Array = _collect_pool(false, false, maxb)
			if dp.is_empty():
				break
			var de: Dictionary = {}
			var ds := 1e30
			for e in dp:
				if _tg_inflight_keys.has(e["key"]):
					continue
				if _io_read_keys.has(e["key"]):
					continue
				if _spawn_fast:
					continue
				var s := _grid_score(e)  # AC-0257: the bake order (layer, taxi)
				if s < ds:
					ds = s
					de = e
			if de.is_empty():
				break
			_advance_dq_past(int(de["cx"]), int(de["cz"]))
			var cx: int = int(de["cx"])
			var cz: int = int(de["cz"])
			var c = chunks.get(de["key"])
			if c == null:
				if absi(cx - last_pcx) > render_radius + 1 or absi(cz - last_pcz) > render_radius + 1:
					break  # stale out-of-radius candidate — leave it queued
				stub_chunk(cx, cz)
				c = chunks.get(de["key"])
			if c == null or not c.data.is_empty():
				break
			_gen_unit(c, cx, cz)
			units += 1
			if _io_read_inflight.size() - io_n0 >= LOAD_POOL_CAP:
				break  # one pool-width of disk reads per frame
		if units > 0:
			perf_build_units += units
			perf_drain_frames += 1
			var fm := (Time.get_ticks_usec() - t0) / 1000.0
			if fm > perf_max_drain_ms:
				perf_max_drain_ms = fm
			if timing:
				print("DRAINMS units=%d ms=%.1f t=%d inflight=%d enq=%d cap=%d dedup=%d" % [units, fm, Time.get_ticks_msec(), threadgen_inflight.size(), _tg_enq, _tg_capdrop, _tg_dedup])
		_drain_units_last = units  # AC-0231
		_col_drain_step()
		return
	while budget > 0:
		if Time.get_ticks_usec() - t0 > budget_us:
			break
		var u := 0  # a build dispatched this frame (the data pass paces on it)
		# AC-0217/AC-0233/AC-0250: the scored pick is cached against (queue
		# version + maxb + spawn-fast + center + sim radius) — since the
		# look left the key (AC-0250), it is a pure function of the pool
		# state: an idle frame with an unchanged world serves the last
		# pool/score and skips the rescan + rescore.
		# AC-0262: the steady pass is high-band-only (see _collect_pool's
		# high_only note) — the wave's entries no longer hold the top pick.
		var bpick := _pick_build_cached(maxb, false, true)
		var best_e: Dictionary = bpick["e"]
		var best_c: Node3D = bpick["c"]
		var best_s: float = bpick["s"]
		var best_from_fb := false  # AC-0217 pick trace: which pass won
		if best_c == null:
			# AC-0079 v3 C1: lead-column pre-build, second pass. The in-radius
			# READY pool is empty — pick the lowest-score READY candidate from
			# _collect_pool(true, true) (identical _build_ready gate, identical
			# _build_unit/_remove_entry). In-radius READY ALWAYS wins (this pass
			# only runs when the first pass found nothing); the forward band is
			# exactly 2r+1 entries, so the pass is bounded.
			var fpick := _pick_build_cached(maxb, true)
			if not (fpick["e"] as Dictionary).is_empty() and float(fpick["s"]) < best_s:
				best_s = float(fpick["s"])
				best_e = fpick["e"]
				best_c = fpick["c"]
				best_from_fb = true
		if best_c != null:
			# AC-0261 (AC-0263): the main build lane is the HIGH band only
			# (taxi < medium_start_r, or the tier-0 set — the section's
			# slabs outrank the rings via the score prefix). An out-of-band
			# top pick blocks the high dispatch for the frame (the unit
			# falls to the data pass below); the entry stays queued and is
			# re-picked whenever an in-band entry goes ready (in-band
			# entries always out-score it on taxi). The visible band
			# [medium_start_r, render_radius) is the slab wave's (its avg
			# LOD is final there); the WAVE 3 catch-up upgrades a
			# low-holding column when it ENTERS the high band (per-slab).
			var dxg := int(best_e["cx"]) - last_pcx
			var dzg := int(best_e["cz"]) - last_pcz
			if absi(dxg) + absi(dzg) >= medium_start_r and not _is_tier0_col(dxg, dzg):
				best_c = null
				perf_high_gate_holds_n += 1
		if best_c != null:
			# AC-0263: the build unit is ONE SLAB (the (layer, taxi) ring
			# order; the tier-0 section's slabs first — the score prefix).
			# A high-complete column (the probe owes nothing — a landing
			# raced the pick) frees its queue entry; a pending column
			# dispatches its best slab and STAYS queued (re-picked next
			# frame; the in-flight dedup paces one slab per column).
			var sih := _hslab_best_pending_cached(best_c)
			if sih < 0:
				_remove_entry(best_e)
			else:
				var deferred := _build_unit_hslab(best_c, int(best_e["cx"]), int(best_e["cz"]), sih)
				if not deferred and _picklog:
					print("PICK %s %d,%d slab=%d s=%.6f t=%d" % ["fb" if best_from_fb else "b", int(best_e["cx"]), int(best_e["cz"]), sih, best_s, Time.get_ticks_msec()])
				if deferred:
					# AC-0160 run 2 / AC-0263: worker slots full (or a task
					# already in flight for this key, or data/neighbors not
					# ready) — the entry stays queued (NOT removed) and the
					# frame ends; the next frame re-dispatches when a slot
					# frees / the data lands. The drain NEVER takes a sync
					# fallback (AC-0263: there is no sync build left).
					break
				u = 1
		if u == 0 and (gen_budget_ms < 0 or gen_used_ms < gen_budget_ms):
			# AC-0079 round 3: scored DATA pick. The spec requires the lowest-score
			# no-data entry (not FIFO), else forward leading-edge data only arrives
			# after all nearer-band data drains and _build_ready stalls the forward
			# mesh. Pool = _collect_pool(false) (band scan from the dq cursor,
			# capped at PICK_POOL_CAP, same as before); each candidate is scored
			# with the AC-0233/AC-0250 3-tier priority (_tier_score) and the
			# lowest wins.
			# Per-consumption FIFO cursor bookkeeping (dq_b/dq_i advance past the
			# consumed entry) is kept so entries are never re-picked and queue_size
			# stays exact.
			# AC-0217: the scored data pick (pool scan + in-flight dedup
			# gates + _tier_score) — cached against the AC-0217 key plus
			# the in-flight depths (see _pick_data_cached). The pre-AC-0217
			# rationale for the gates lives on in that function.
			var dpick := _pick_data_cached(maxb)
			var dp_e: Dictionary = dpick["e"]
			var dp_s: float = dpick["s"]
			if not dp_e.is_empty():
				_advance_dq_past(int(dp_e["cx"]), int(dp_e["cz"]))
				var cx: int = int(dp_e["cx"])
				var cz: int = int(dp_e["cz"])
				var c = chunks.get(dp_e["key"])
				if c == null:
					if absi(cx - last_pcx) > render_radius + 1 or absi(cz - last_pcz) > render_radius + 1:
						# Out-of-radius stale pool candidate (possible after a
						# recenter mid-frame): skip this pick, leave the entry
						# queued for the next recenter rebuild to drop it.
						pass
					else:
						var s0 := Time.get_ticks_usec() if _recprobe else 0
						stub_chunk(cx, cz)
						if _recprobe:
							_rp_drain_stub_ms += (Time.get_ticks_usec() - s0) / 1000.0
							_rp_drain_stub_n += 1
						c = chunks.get(dp_e["key"])
				if c != null and c.data.is_empty():
					var dg := _gen_unit(c, cx, cz)
					u = 1
					gen_used_ms += dg
					if _picklog:
						print("PICK d %d,%d s=%.6f t=%d" % [cx, cz, dp_s, Time.get_ticks_msec()])
					# AC-0155: a disk read is a main-thread inflate (~20 ms) —
					# one per frame, same pacing rationale as the sync gen.
					if _gen_last_disk and not loading_active:
						break
					# AC-0160: the threadgen pool is saturated — every further
					# iteration would re-pick + cap-drop the same entry (11
					# wasted ~2ms pool scans per frame while the handoffs are
					# still in flight). End the frame; the slots free next
					# frame and the pick resumes there.
					if threadgen_inflight.size() >= threadgen_max:
						break
			if u == 0 and bool(dpick["pool_empty"]):
				# Pool exhausted this frame (all entries consumed): park the
				# cursor past the scanned region, same as the old FIFO scan.
				var db := dq_b
				var di := dq_i
				while db < band_buckets.size() and di < band_buckets[db].size():
					db += 1
					di = 0
				dq_b = db
				dq_i = di
		if u == 0:
			break
		units += 1
		budget -= 1
		if not startup and not loading_active:
			_drain_acc_ms = maxf(0.0, _drain_acc_ms - unit_pace)  # spend the banked wall ms
	if units > 0:
		perf_build_units += units
		perf_drain_frames += 1
		var fm := (Time.get_ticks_usec() - t0) / 1000.0
		if fm > perf_max_drain_ms:
			perf_max_drain_ms = fm
		if timing:
			print("DRAINMS units=%d ms=%.1f t=%d inflight=%d enq=%d cap=%d dedup=%d" % [units, fm, Time.get_ticks_msec(), threadgen_inflight.size(), _tg_enq, _tg_capdrop, _tg_dedup])
	if timing:
		# AC-0217: the pool/score debounce counters (cumulative).
		print("POOLCACHE hits=%d misses=%d t=%d" % [perf_pool_hits, perf_pool_misses, Time.get_ticks_msec()])
	_drain_units_last = units  # AC-0231
	_col_drain_step()

func _advance_dq_past(cx: int, cz: int) -> void:
	# AC-0079 round 3: advance the sticky data cursor (dq_b/dq_i) past the entry
	# at (cx,cz), keeping the cursor consistent with the scored pool pick the
	# way the old FIFO scan did (entries at/below the cursor are considered
	# consumed). Fallback-only bookkeeping: the pick itself is score-driven.
	for b in range(dq_b, band_buckets.size()):
		var arr: Array = band_buckets[b]
		for i in range(dq_i if b == dq_b else 0, arr.size()):
			if int(arr[i]["cx"]) == cx and int(arr[i]["cz"]) == cz:
				dq_b = b
				dq_i = i + 1
				while dq_b < band_buckets.size() and dq_i >= band_buckets[dq_b].size():
					dq_b += 1
					dq_i = 0
				return

func _remove_entry(e: Dictionary) -> void:
	# AC-0160: fast path via the key -> bucket map (O(bucket) instead of
	# O(queue)); the full scan stays as the fallback and rebuilds the map
	# when it was stale (recenter races).
	var b0: int = int(_qb.get(e["key"], -1))
	if b0 >= 0 and b0 < band_buckets.size():
		var arr0: Array = band_buckets[b0]
		for i in range(arr0.size()):
			if arr0[i]["key"] == e["key"]:
				var was_build := not bool(arr0[i].get("data_only", false))  # AC-0222: capture before removal
				arr0.remove_at(i)
				_qb.erase(e["key"])
				queued_keys.erase(e["key"])
				queue_size -= 1
				if was_build:
					_build_q_n -= 1  # AC-0222
				_pool_touch()  # AC-0217: a pool candidate left the queue
				return
		_qb.erase(e["key"])
	for b in range(band_buckets.size()):
		var arr: Array = band_buckets[b]
		for i in range(arr.size()):
			if arr[i]["key"] == e["key"]:
				if not bool(arr[i].get("data_only", false)):
					_build_q_n -= 1  # AC-0222
				arr.remove_at(i)
				# AC-0152: keep queued_keys in lockstep with band_buckets (the
				# invariant _strip_candidate_builds maintained). Without this,
				# a consumed "build" entry left a stale queued_keys flag and
				# _enqueue_build's dedup no-op'd the _tm_retrigger re-queue —
				# a threadmesh handoff drop (worker lost the add_task/slot
				# race) then stranded the chunk unbuilt and unqueued forever.
				queued_keys.erase(e["key"])
				queue_size -= 1
				_rebuild_qb()
				_pool_touch()  # AC-0217: a pool candidate left the queue
				return

func _rebuild_qb() -> void:
	# AC-0160: (re)build the key -> bucket map from band_buckets.
	_qb = {}
	for b in range(band_buckets.size()):
		for e2 in band_buckets[b]:
			_qb[e2["key"]] = b


func _queue_build_depth_scan() -> int:
	# AC-0222: verify the lockstep _build_q_n counter against the buckets
	# (only ever run when the counter claims the cap is exceeded).
	var n := 0
	for b in range(band_buckets.size()):
		var arr: Array = band_buckets[b]
		for e in arr:
			if not bool(e["data_only"]):
				n += 1
	return n


func _cap_queue_depth() -> void:
	# AC-0222: cap the total queued BUILD depth to the render circle count
	# (circle_count(): about 797 at R16, 7845 at R50). When full, evict the
	# FARTHEST band first (highest non-empty bucket, oldest entries within
	# the band = the tail, since the newest are pushed to the front). The
	# data_only (band-3) entries are EXEMPT: they are the 8-neighbor build
	# gate's fuel (AC-0160: the collar ∪ circle-ring data feeds the
	# circle-edge chunks' 8-neighborhood) and do no mesh work — evicting
	# them strands the circle edge unbuilt until the next recenter
	# re-queues the feed. The exemption keeps the total queue bounded by
	# the stream set (circle ∪ collar ∪ ring) while the build queue stays
	# at the circle count. Build entries are unique keys over the meshable
	# set (exactly the circle), so the cap is a hard guard: it fires only
	# on a bookkeeping drift (the scan below self-heals it) or a bug that
	# ever re-queues past the circle — the queue then stays bounded
	# instead of growing to the full stream set.
	var cap := circle_count()
	if _build_q_n <= cap:
		return
	var n := _queue_build_depth_scan()  # verify: never trust a drifted counter
	_build_q_n = n
	if n <= cap:
		return
	var over := n - cap
	while over > 0:
		var evicted := false
		for b in range(band_buckets.size() - 1, -1, -1):  # farthest band first
			var arr: Array = band_buckets[b]
			var i := arr.size() - 1
			while i >= 0 and not evicted:  # oldest of the band (the tail) first
				var e: Dictionary = arr[i]
				if not bool(e["data_only"]):
					arr.remove_at(i)
					_qb.erase(e["key"])
					queued_keys.erase(e["key"])
					queue_size -= 1
					_build_q_n -= 1
					_pool_touch()  # AC-0217: a pool candidate was evicted
					over -= 1
					evicted = true
				i -= 1
		if not evicted:
			break  # only exempt data_only entries remain

# --- AC-0077: crossing-batched per-chunk light (P1.3) ----------------------

# AC-0129: per-dispatch fresh strip copies (main thread only; workers get the
# copies in their entry). eff strips = 8 combined last_eff rings [E,W,N,S,
# SE,SW,NE,NW] for the 20x20 bake box margins (Chunk._bake_box); blk strips =
# 4 side rings [E,W,N,S] derived from neighbor data+last_eff (source light
# EXACT, eff>sky EXACT, else 0 CONSERVATIVE — one top-down column pass each,
# web sky rule index.html:1013-1021). Neighbor missing/never lit -> empty
# (0-length) arrays: bake margin stays 0, no injection from that side.
#
# AC-0207: C++ strips (gdext/src/strips.cpp — AweStrips, the LOSSLESS port
# of the strip compute: _side_blk_strip's slab cell reads decode in C++
# [free int lookup] instead of the GDScript ChunkIO._slab_getbits per cell —
# 24k Variant calls / dispatch = the 74 ms idle hitch; the face compute rides
# the same C++ flood/inject kernels as the pull path). AC-0208: the C++
# extension is REQUIRED — the AWECRAFT_STRIPSCPP kill switch and the
# GDScript strip-compute branch were removed; AweStrips is the only strip
# path (Game._ready fails fast if the library is missing). The GDScript
# strip kernels (_side_eff_strip/_side_blk_strip/_corner_eff_strip/
# _compute_face_blk_gd) SURVIVE solely as the stripsprobe A/B references
# (gd_strips_calls is the no-fallback sentinel for them).
var _strips_cpp: Variant = null
var _strips_cpp_done := false


func _strips_cpp_inst() -> Variant:
	if not _strips_cpp_done:
		_strips_cpp_done = true
		if ClassDB.class_exists("AweStrips"):
			_strips_cpp = ClassDB.instantiate("AweStrips")
		else:
			push_error("AWECRAFT: AweStrips C++ class not registered — the gdext library is missing (AC-0208: the C++ extension is REQUIRED, no GDScript strips fallback).")
	return _strips_cpp


func _strips_for(cx: int, cz: int) -> Dictionary:
	var h: int = Data.HEIGHT
	# AC-0207: C++ strips (gdext/src/strips.cpp). The neighbor lookups + the
	# memoized face strips (_face_of) stay in GDScript — World owns the
	# chunks map + the _face_blk cache; the compute (eff gathers + v channel
	# slab decode + b copy + corners) is native and byte-identical
	# (stripsprobe: 100% exact vs the GDScript reference).
	Lighting._tables()
	var sides: Array = []
	for s in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
		var nc = chunks.get(_key(cx + int(s[0]), cz + int(s[1])))
		var sd: Dictionary = {"data": [], "eff": PackedByteArray(), "face": PackedByteArray(), "have": false}
		if nc != null and not nc.data.is_empty() and not nc.last_eff.is_empty():
			sd["data"] = nc.data
			sd["eff"] = nc.last_eff["arr"]
			sd["face"] = _face_of(nc, _shared_face(int(s[0]), int(s[1])))
			sd["have"] = true
		sides.append(sd)
	var corners: Array = []
	for s in [[1, 1], [-1, 1], [1, -1], [-1, -1]]:
		var nc = chunks.get(_key(cx + int(s[0]), cz + int(s[1])))
		var cd: Dictionary = {"eff": PackedByteArray(), "have": false}
		if nc != null and not nc.data.is_empty() and not nc.last_eff.is_empty():
			cd["eff"] = nc.last_eff["arr"]
			cd["have"] = true
		corners.append(cd)
	strips_cpp_calls += 1
	return _strips_cpp_inst().compute_strips(sides, corners, h, Lighting._att, Lighting._glow)


func _side_eff_strip(nc: Node3D, dx: int, dz: int, h: int) -> PackedByteArray:
	gd_strips_calls += 1  # AC-0208: no-fallback sentinel — the game never calls this (C++ AweStrips is the only strip lane); stripsprobe only
	# c=0 the column directly across our boundary, c=1 the next; t = our z
	# (E/W) or our x (S/N). 2*16*h bytes, idx = c*(16*h) + y*16 + t.
	# AC-0091: sized by h (was hard-coded 2560 = H=80).
	var e := PackedByteArray()
	e.resize(2 * 16 * h)
	var narr: PackedByteArray = nc.last_eff["arr"]
	var colsz := 16 * h
	var nx0: int = 0 if dx > 0 else 15
	var nz0: int = 0 if dz > 0 else 15
	if dx != 0:
		for c in range(2):
			for y in range(h):
				var srow := y * 16
				for t in range(16):
					e[c * colsz + srow + t] = narr[(y << 8) | (t << 4) | (nx0 - c)]
	else:
		for c in range(2):
			for y in range(h):
				var srow := y * 16
				for t in range(16):
					e[c * colsz + srow + t] = narr[(y << 8) | ((nz0 - c) << 4) | t]
	return e


# AC-0134 run-2 (fix-6): per-chunk face-boundary BLOCK-light cache for
# _side_blk_strip: _face_blk[key] = [data_snapshot (PackedByteArray),
# faces (4 x 2*16*h PackedByteArray, AC-0091, idx = c*(16*h) + y*16 + t — c=0 the face
# row, which is the ONLY half _chunk_blk_inject reads; c=1 zero), deps
# (4 x [neighbor_key, neighbor_eff_gen], _FACE_SIDES order)]. Face order =
# ring side convention: 0=E (x=15) 1=W (x=0) 2=S (z=15) 3=N (z=0).
#
# FIX-6 ROOT CAUSE (lightaudit REGRESSION 2026-08-28, fix-5): the fix-5
# face was the IN-CHUNK glow flood only — a 1-hop carrier. Source chunk C
# lights neighbor A (A's kernel injects C's boundary row), but A's OWN
# in-chunk flood never sees the imported level, so A's face to A's neighbor
# B is 0 and block light DIES AT THE SECOND BOUNDARY. Empirically: 1173
# hard cliffs, all cross-boundary 14/0 lava pairs (source two chunks from
# the dark cell), while the AC-0129 lightaudit — 0 cliffs on the
# final-state ring carrier — regressed. The face now mirrors the kernel's
# OWN blk pipeline (lighting.gd: seed glow -> flood -> inject neighbor
# strips -> re-flood): the chunk's SETTLED block light, sky NEVER included
# (the kernel's arr is max(sky,blk) and would re-leak the AC-0134 phantom).
# The source-within-G induction still holds (inject cand = L-att with L
# source-at-G-L keeps every carried level a true block-light path), so the
# fix-3/4 phantom class — bright, marked, no source within 14 — stays
# impossible and the nightlot leak gate stays green by the same proof, now
# with 2-hop (and transitive) propagation restored.
# A face depends only on (own data, neighbors' faces) — never on own eff —
# and any data change that could alter a face (att/glow change) forces a
# re-light (eff_gen bump), so the (key, eff_gen) deps are a sufficient
# invalidation key.
var _face_blk: Dictionary = {}
# Cycle guard for the recursive face fetch: a neighbor still computing
# contributes an empty strip this pass; its landing's E2 re-fire converges
# the wave (the same pull semantics as the kernel's re-dispatch).
var _face_blk_inflight: Dictionary = {}
var _FACE_SIDES: Array = [[1, 0], [-1, 0], [0, 1], [0, -1]]
# AC-0231: the face fetch is recursive (a chunk's face pulls its 4
# neighbors' faces, each pulling theirs) with only the CYCLE guard above —
# an acyclic stale CHAIN is unbounded. A landing burst (the AC-0231 order
# gate lets the tier>=2 high land in a wave once the in-r low drains)
# invalidates a whole diamond of face memos at once, so the recompute fans
# out through a deep stale chain and overflows the stack (R16 gate run:
# signal 11 in _compute_face_blk). The pull depth is therefore bounded: at
# the limit a neighbor contributes its best-available face (the current
# memo even if stale — eff only ever increases, so a stale memo
# under-reports light, never over-reports) or an empty strip if it has
# never been computed. The same E2 re-fire that converges the cycle-guard
# approximation converges this one (the neighbor's landing bumps its
# eff_gen, dep-invalidates the face, and it recomputes at the next read).
const FACE_PULL_MAX_DEPTH := 16
var _face_pull_depth := 0


# The face index of the NEIGHBOR's face set [E,W,S,N] that faces us across
# the shared boundary (dx,dz = us -> neighbor): east neighbor shows its W
# face (local x=0), west its E (x=15), north its N (local z=0), south its
# S (z=15).
func _shared_face(dx: int, dz: int) -> int:
	if dx > 0:
		return 1
	if dx < 0:
		return 0
	if dz > 0:
		return 3
	return 2


func _face_deps(c: Node3D) -> Array:
	var out: Array = []
	for s in _FACE_SIDES:
		var m = chunks.get(_key(int(c.cx) + int(s[0]), int(c.cz) + int(s[1])))
		if m == null:
			out.append(["", 0])
		else:
			out.append([_key(int(m.cx), int(m.cz)), int(m.eff_gen)])
	return out


func _face_deps_ok(c: Node3D, deps: Array) -> bool:
	for side in range(4):
		var s: Array = _FACE_SIDES[side]
		var m = chunks.get(_key(int(c.cx) + int(s[0]), int(c.cz) + int(s[1])))
		var k: String = "" if m == null else _key(int(m.cx), int(m.cz))
		var g: int = 0 if m == null else int(m.eff_gen)
		if deps[side][0] != k or deps[side][1] != g:
			return false
	return true


func _face_of(c: Node3D, fi: int) -> PackedByteArray:
	# Memoized final block face. Valid iff own data matches AND all 4
	# neighbor (key, eff_gen) deps match — no face outlives its
	# neighborhood state.
	var nkey: String = _key(int(c.cx), int(c.cz))
	if _face_blk_inflight.has(nkey):
		return PackedByteArray()
	# AC-0203: validity key = data_gen (a face depends on own data only;
	# every data mutation bumps the gen).
	var cur: Array = _face_blk.get(nkey, [])
	if cur.size() == 3 and int(cur[0]) == int(c.data_gen):
		var deps: Array = cur[2]
		if _face_deps_ok(c, deps):
			return cur[1][fi]
	# AC-0231: the pull-depth bound (the burst-stale chain that overflowed
	# the stack) — see FACE_PULL_MAX_DEPTH. Best-available face, never a
	# deeper recompute; the E2 re-fire converges it.
	if _face_pull_depth >= FACE_PULL_MAX_DEPTH:
		return cur[1][fi] if cur.size() == 3 else PackedByteArray()
	var fresh: Array = _compute_face_blk(c)
	_face_blk[nkey] = [c.data_gen, fresh, _face_deps(c)]
	return fresh[fi]


# AC-0203 recenter fix: glow scan over the SLAB store (a paletted slab is
# glow-free iff its palette is glow-free — no 98 KB flat expansion needed
# to decide). A raw slab (>16 ids) scans its 4096 values (rare).
func _chunk_has_glow(c: Node3D) -> bool:
	for s in c.data:
		if s == null:
			continue
		if int(s["n"]) == 0:
			var ri: PackedByteArray = s["i"]
			var k := 0
			while k < 4096:
				if Lighting._glow[ri[k]] > 0:
					return true
				k += 1
		else:
			var pp: PackedByteArray = s["p"]
			var k := 0
			while k < pp.size():
				if Lighting._glow[pp[k]] > 0:
					return true
				k += 1
	return false


func _compute_face_blk(c: Node3D) -> Array:
	# fix-6: the chunk's SETTLED block light — own glow flood, then the
	# neighbors' FINAL faces injected (the [E,W,N,S] strip order
	# _chunk_blk_inject expects), then re-flood. Block-only twin of the
	# kernel's eff pipeline; sky never enters (see the _face_blk doc).
	# 2*16*h-wide faces (AC-0091; was 2560 at H=80): c=0 half = face row
	# (the inject half), c=1 zero.
	# AC-0207: the neighbor-face fetch (the recursive _face_of pulls, under
	# the in-flight cycle guard) feeds the C++ face compute on captured
	# strips. AC-0208: C++-ONLY — the _compute_face_blk_gd fallback line was
	# removed (it survives solely as the stripsprobe A/B reference).
	var h: int = Data.HEIGHT
	var fk0: String = _key(int(c.cx), int(c.cz))
	_face_blk_inflight[fk0] = true
	# AC-0231: the neighbor pulls below are the recursion — account the
	# depth; the C++ compute after the loop never calls back into
	# _face_of, so the counter drops before it.
	_face_pull_depth += 1
	var strips: Array = []
	for side in range(4):
		var s: Array = _FACE_SIDES[side]
		var nc = chunks.get(_key(int(c.cx) + int(s[0]), int(c.cz) + int(s[1])))
		var st: PackedByteArray = PackedByteArray()
		if nc != null and not nc.data.is_empty():
			st = _face_of(nc, _shared_face(int(s[0]), int(s[1])))
		strips.append(st)
	_face_pull_depth -= 1
	_face_blk_inflight.erase(fk0)
	# AC-0207: C++ face compute (gdext/src/strips.cpp) — the glow
	# palette probe + flat expand + flood + inject through the SAME C++
	# kernels the pull path runs (byte-identical to the GDScript reference;
	# stripsprobe face gate).
	Lighting._tables()
	var r: Dictionary = _strips_cpp_inst().compute_face(c.data, h, Lighting._att, Lighting._glow, strips[0], strips[1], strips[2], strips[3])
	strips_cpp_calls += 1
	return r["faces"]


func _compute_face_blk_gd(c: Node3D, h: int, strips: Array) -> Array:
	# AC-0134 fix-6 / AC-0203 GDScript compute (the AC-0207 fallback; the
	# neighbor face `strips` [E,W,S,N] are passed in by _compute_face_blk).
	# AC-0203 recenter fix: the no-glow column (the common terrain case)
	# probes the inject on a ZERO column instead of expanding the 98 KB
	# flat store: a zero cell attenuates by _att[0] = 1 (the minimum), so
	# the probe reports every injection the real run would (it can over-
	# report, never under-report); a no-change probe proves the face is
	# exactly zero. ids pass = the flat store itself (the old separate 98
	# KB copy loop is gone — the flood/inject only read it).
	Lighting._tables()
	var glow: bool = _chunk_has_glow(c)
	var nd: PackedByteArray
	var blk := PackedByteArray()
	if glow:
		nd = c.flat_data()
		blk.resize(nd.size())
		var i := 0
		while i < nd.size():
			var g: int = Lighting._glow[nd[i]]
			if g > 0:
				blk[i] = g
			i += 1
		Lighting._flood_flat(blk, nd, 16, h, 16)
	else:
		nd = PackedByteArray()
		nd.resize(h * 256)
		blk.resize(h * 256)
	var inj: bool = Lighting._chunk_blk_inject(blk, nd, h, strips)
	if inj:
		if not glow:
			# the probe ran on the zero column (min attenuation) — the
			# boundary values it wrote are over-attenuation-free; redo the
			# inject on the REAL column so the boundary cells carry the
			# exact cand = strip - _att[real_id] values.
			nd = c.flat_data()
			blk.fill(0)
			Lighting._chunk_blk_inject(blk, nd, h, strips)
		Lighting._flood_flat(blk, nd, 16, h, 16)
	var fsize := 2 * 16 * h
	var fe := PackedByteArray()
	fe.resize(fsize)
	var fw := PackedByteArray()
	fw.resize(fsize)
	var fs := PackedByteArray()
	fs.resize(fsize)
	var fn := PackedByteArray()
	fn.resize(fsize)
	for y in range(h):
		var rowb: int = y * 16
		var row: int = y << 8
		for t in range(16):
			fe[rowb + t] = blk[row | (t << 4) | 15]
			fw[rowb + t] = blk[row | (t << 4)]
			fs[rowb + t] = blk[row | (15 << 4) | t]
			fn[rowb + t] = blk[row | t]
	return [fe, fw, fs, fn]


func _side_blk_strip(nc: Node3D, dx: int, dz: int, h: int) -> Dictionary:
	gd_strips_calls += 1  # AC-0208: no-fallback sentinel — stripsprobe reference only (game uses C++ AweStrips)
	# fix-7: TWO channels (AC-0129 wiring, sound content):
	#   v (the eff import): the neighbor boundary cell's TRUE light with the
	#   sky part DATA-ONLY (AC-0129 "sky carry", verbatim formula): source
	#   EXACT (22->14, 23->12, 24->15), else max(eff_n, sky_n) where sky_n =
	#   15 iff the neighbor's boundary column is open to the sky (data scan,
	#   the kernel's binary sky) and eff_n = the neighbor's settled baked eff
	#   (0 until its first landing — the data-only sky fallback stays exact
	#   then). The sky carry is REQUIRED: the kernel's sky is per-chunk, so
	#   cross-chunk SKY corner-bleed (a sealed cell next to an open column:
	#   14/13/...) crosses the boundary ONLY via this strip. fix-5/6's
	#   blk-only eff strip killed it => 1173 lightaudit cliffs (14 on the
	#   open side, 0 across the boundary; the in-chunk value is provably
   #   not block light — the final-blk face is 0 there). Cannot over-
	#   inject: sky_n (open column = 15) <= the neighbor's true eff at that
	#   cell, and eff_n is the neighbor's settled value.
	#   b (the mask import): the neighbor's FINAL block face (fix-6 memo) —
	#   block-only, sourced, lossless (supersedes AC-0129's lossy ring).
	#   The mask marks block-derived light for the bake's night scale; sky
	#   never marks. c=1 half zero: _chunk_blk_inject reads c=0 only.
	# AC-0203 recenter fix: slab-aware — NO full-column flat_data() here (it
	# ran on EVERY dispatch and cost ~20 ms/neighbor). Per column:
	# solid_top = the topmost att==0 cell, found by palette probe (a slab
	# whose palette holds no solid id cannot close the column; raw slabs
	# scan their 4096 values — rare). sky_n = 15 iff y > solid_top: every
	# cell above solid_top is att>0 by construction, and a cell below it is
	# closed — provably the same as the old per-cell open walk. Per-cell bl
	# is read straight from the slab store (null -> 0, uniform -> p[0],
	# paletted -> _slab_getbits, raw -> i[pos]).
	var b := PackedByteArray()
	b.resize(2 * 16 * h)  # AC-0091: was hard-coded 2560 = H=80
	var narr: PackedByteArray = PackedByteArray()
	var nvalid := false
	if not nc.last_eff.is_empty():
		narr = nc.last_eff["arr"]
		nvalid = narr.size() == h * 256
	Lighting._tables()
	var slabs: Array = nc.data
	var nsl: int = slabs.size()
	var nx0: int = 0 if dx > 0 else 15
	var nz0: int = 0 if dz > 0 else 15
	for t in range(16):
		var nx: int
		var nz: int
		if dx != 0:
			nx = nx0
			nz = t
		else:
			nx = t
			nz = nz0
		var solid_top := -1
		var si := nsl - 1
		while si >= 0:
			var s = slabs[si]
			if s != null:
				var has_solid := false
				var parr: PackedByteArray
				var pn: int
				if int(s["n"]) == 0:
					parr = s["i"]
					pn = 4096
				else:
					parr = s["p"]
					pn = int(s["p"].size())
				var k := 0
				while k < pn:
					if Lighting._att[parr[k]] == 0:
						has_solid = true
						break
					k += 1
				if has_solid:
					var slb0: int = si * 16
					var k2 := 15
					while k2 >= 0:
						var y2: int = slb0 + k2
						var blv: int
						if int(s["n"]) == 1:
							blv = int(s["p"][0])
						elif int(s["n"]) == 0:
							blv = int(s["i"][(k2 << 8) | (nz << 4) | nx])
						else:
							blv = int(s["p"][ChunkIO._slab_getbits(s["i"], int(s["b"]), (k2 << 8) | (nz << 4) | nx)])
						if Lighting._att[blv] == 0:
							solid_top = y2
							break
						k2 -= 1
			if solid_top >= 0:
				break
			si -= 1
		si = 0
		while si < nsl:
			var s2 = slabs[si]
			var slb: int = si * 16
			var ly: int = 15
			var y: int = 0
			var sky_n: int = 0
			var eff_n: int = 0
			if s2 == null:
				while ly >= 0:
					y = slb + ly
					sky_n = 15 if y > solid_top else 0
					eff_n = 0
					if nvalid:
						eff_n = narr[(y << 8) | (nz << 4) | nx]
					if eff_n > sky_n:
						b[y * 16 + t] = eff_n
					else:
						b[y * 16 + t] = sky_n
					ly -= 1
			elif int(s2["n"]) == 1:
				var blc: int = int(s2["p"][0])
				var lvc: int = Lighting._glow[blc]
				ly = 15
				while ly >= 0:
					y = slb + ly
					sky_n = 15 if y > solid_top else 0
					eff_n = 0
					if nvalid:
						eff_n = narr[(y << 8) | (nz << 4) | nx]
					if lvc > 0:
						b[y * 16 + t] = lvc
					elif eff_n > sky_n:
						b[y * 16 + t] = eff_n
					else:
						b[y * 16 + t] = sky_n
					ly -= 1
			else:
				var packed: PackedByteArray = s2["i"]
				var raw2: bool = int(s2["n"]) == 0
				var pp2: PackedByteArray = s2["p"]
				var bits: int = int(s2["b"])
				ly = 15
				while ly >= 0:
					y = slb + ly
					var pos: int = (ly << 8) | (nz << 4) | nx
					var bl: int
					if raw2:
						bl = int(packed[pos])
					else:
						bl = int(pp2[ChunkIO._slab_getbits(packed, bits, pos)])
					sky_n = 15 if y > solid_top else 0
					eff_n = 0
					if nvalid:
						eff_n = narr[(y << 8) | (nz << 4) | nx]
					var lv: int = Lighting._glow[bl]
					if lv > 0:
						b[y * 16 + t] = lv
					elif eff_n > sky_n:
						b[y * 16 + t] = eff_n
					else:
						b[y * 16 + t] = sky_n
					ly -= 1
			si += 1
	var sf: PackedByteArray = _face_of(nc, _shared_face(dx, dz))
	var bm := PackedByteArray()
	if sf.size() == 2 * 16 * h:  # AC-0091: face width by h (was 2560)
		bm = sf.duplicate()
	else:
		bm.resize(2 * 16 * h)
	return {"v": b, "b": bm}


func _corner_eff_strip(nc: Node3D, dx: int, dz: int, h: int) -> PackedByteArray:
	gd_strips_calls += 1  # AC-0208: no-fallback sentinel — stripsprobe reference only (game uses C++ AweStrips)
	# a = x-depth (0 = directly across), b = z-depth (0 = directly across);
	# 2x2*h bytes, idx = (a*2+b)*h + y. AC-0091: sized by h (was 320 = H=80).
	var e := PackedByteArray()
	e.resize(4 * h)
	var narr: PackedByteArray = nc.last_eff["arr"]
	var nx0: int = 0 if dx > 0 else 15
	var nz0: int = 0 if dz > 0 else 15
	for a in range(2):
		for b in range(2):
			var nx: int = nx0 - a
			var nz: int = nz0 - b
			for y in range(h):
				e[(a * 2 + b) * h + y] = narr[(y << 8) | (nz << 4) | nx]
	return e


var _scoped_strips_cache := {}
var _scoped_strips_cache_n := 0


func _strips_for_scoped(cx: int, cz: int, y_lo: int, y_hi: int) -> Dictionary:
	var h: int = Data.HEIGHT
	var y0 := maxi(0, y_lo - 2)
	var y1 := mini(h - 1, y_hi + 1)
	var parts: Array = [cx, cz, y0, y1]
	var sides := [[1, 0], [-1, 0], [0, 1], [0, -1]]
	var corners := [[1, 1], [-1, 1], [1, -1], [-1, -1]]
	for s in sides:
		var nc = chunks.get(_key(cx + int(s[0]), cz + int(s[1])))
		parts.append(-1 if nc == null else "%d/%d" % [int(nc.data_gen), int(nc.eff_gen)])
	for s in corners:
		var nc = chunks.get(_key(cx + int(s[0]), cz + int(s[1])))
		parts.append(-1 if nc == null else "%d/%d" % [int(nc.data_gen), int(nc.eff_gen)])
	var k := str(parts)
	var hit = _scoped_strips_cache.get(k)
	if hit != null:
		return hit
	var effs: Array = []
	var blks: Array = []
	var blks_b: Array = []
	for s in sides:
		var nc = chunks.get(_key(cx + int(s[0]), cz + int(s[1])))
		var e := PackedByteArray()
		var b := PackedByteArray()
		if nc != null and not nc.data.is_empty() and not nc.last_eff.is_empty():
			e = _side_eff_strip_scoped(nc, int(s[0]), int(s[1]), y0, y1, h)
			b = _side_blk_v_scoped(nc, int(s[0]), int(s[1]), y0, y1, h)
			var bm := PackedByteArray()
			bm.resize(2 * 16 * h)
			blks_b.append(bm)
		else:
			var bm0 := PackedByteArray()
			bm0.resize(2 * 16 * h)
			blks_b.append(bm0)
		effs.append(e)
		blks.append(b)
	for s in corners:
		var nc = chunks.get(_key(cx + int(s[0]), cz + int(s[1])))
		var e := PackedByteArray()
		if nc != null and not nc.data.is_empty() and not nc.last_eff.is_empty():
			e = _corner_eff_strip_scoped(nc, int(s[0]), int(s[1]), y0, y1, h)
		effs.append(e)
	var out := {"eff": effs, "blk": blks, "blk_b": blks_b}
	if _scoped_strips_cache_n >= 32:
		_scoped_strips_cache.clear()
		_scoped_strips_cache_n = 0
	_scoped_strips_cache[k] = out
	_scoped_strips_cache_n += 1
	return out


func _side_eff_strip_scoped(nc: Node3D, dx: int, dz: int, y0: int, y1: int, h: int) -> PackedByteArray:
	var e := PackedByteArray()
	e.resize(2 * 16 * h)
	var narr: PackedByteArray = nc.last_eff["arr"]
	var colsz := 16 * h
	var nx0: int = 0 if dx > 0 else 15
	var nz0: int = 0 if dz > 0 else 15
	if dx != 0:
		for c in range(2):
			for y in range(y0, y1 + 1):
				var srow := y * 16
				for t in range(16):
					e[c * colsz + srow + t] = narr[(y << 8) | (t << 4) | (nx0 - c)]
	else:
		for c in range(2):
			for y in range(y0, y1 + 1):
				var srow := y * 16
				for t in range(16):
					e[c * colsz + srow + t] = narr[(y << 8) | ((nz0 - c) << 4) | t]
	return e


func _corner_eff_strip_scoped(nc: Node3D, dx: int, dz: int, y0: int, y1: int, h: int) -> PackedByteArray:
	var e := PackedByteArray()
	e.resize(4 * h)
	var narr: PackedByteArray = nc.last_eff["arr"]
	var nx0: int = 0 if dx > 0 else 15
	var nz0: int = 0 if dz > 0 else 15
	for a in range(2):
		for b in range(2):
			var nx: int = nx0 - a
			var nz: int = nz0 - b
			for y in range(y0, y1 + 1):
				e[(a * 2 + b) * h + y] = narr[(y << 8) | (nz << 4) | nx]
	return e


func _side_blk_v_scoped(nc: Node3D, dx: int, dz: int, y0: int, y1: int, h: int) -> PackedByteArray:
	# AC-0187: v channel only. The b (mask) channel is left zero for the fast
	# path: it is consumed exclusively by the self-light pull kernel, which a
	# frozen-light scoped build never runs (the stale eff always carries its
	# mask). Skipping it also skips the _face_of lookup whose cold-cache miss
	# costs ~190 ms on the main thread.
	var b := PackedByteArray()
	b.resize(2 * 16 * h)
	var nd: PackedByteArray = nc.flat_data()
	var narr: PackedByteArray = PackedByteArray()
	if not nc.last_eff.is_empty():
		narr = nc.last_eff["arr"]
	var nvalid: bool = narr.size() == nd.size()
	Lighting._tables()
	var nx0: int = 0 if dx > 0 else 15
	var nz0: int = 0 if dz > 0 else 15
	for t in range(16):
		var nx: int
		var nz: int
		if dx != 0:
			nx = nx0
			nz = t
		else:
			nx = t
			nz = nz0
		var open := true
		for y in range(h - 1, y0 - 1, -1):
			var idx: int = (y << 8) | (nz << 4) | nx
			var bl: int = nd[idx]
			var sky_n := 0
			if open and Lighting._att[bl] > 0:
				sky_n = 15
			if open and Lighting._att[bl] == 0:
				open = false
			var eff_n: int = 0
			if nvalid:
				eff_n = narr[idx]
			var lv: int = Lighting._glow[bl]
			var v: int
			if lv > 0:
				v = lv
			elif eff_n > sky_n:
				v = eff_n
			else:
				v = sky_n
			if y >= y0:
				b[y * 16 + t] = v
	return b


func _ngens_for(cx: int, cz: int) -> Array:
	# eff_gens of (E,W,N,S); 0 for a missing chunk. An eff-cache entry is
	# valid iff own data matches AND this 4-tuple matches — the data-
	# signature on the batch's neighbor-eff inputs (plan §2.C.3).
	var out: Array = []
	for s in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
		var nc = chunks.get(_key(cx + int(s[0]), cz + int(s[1])))
		out.append(0 if nc == null else int(nc.eff_gen))
	return out


# AC-0129 E2 (web lightOnNewChunk :1041-1044, beyond it: actually re-lights);
# AC-0134 fix-6: the re-enqueue is no longer gated on blk_src — non-glow
# chunks relay imported block light, so EVERY arr-changing landing refreshes
# the face cache (dep-invalidated) and the per-side frame-gated neighbors
# are evicted + re-enqueued ONCE — an identical re-light bumps no gens, so
# the chain dies when all frames settle.
# Per-side FRAME gate (perf, correctness-identical; plan 2.C.2 says "evict +
# re-enqueue 4 built neighbors" unconditionally — the gate only skips sides
# whose shared 2-deep boundary frame is byte-identical old->new, i.e. the
# neighbor's import is unchanged and its re-light a provable no-op; eff only
# ever increases, so no staleness can be masked).
func _eff_landed(c: Node3D, old_eff: Dictionary, new_eff: Dictionary) -> void:
	var _wpt := Time.get_ticks_usec()  # AC-0251 FACELIGHT sub-stage
	if new_eff.is_empty():
		_wprof_add(WP_FACELIGHT, Time.get_ticks_usec() - _wpt)
		return
	var changed: bool = old_eff.is_empty() or old_eff.get("arr", PackedByteArray()) != new_eff.get("arr", PackedByteArray())
	if not changed:
		_wprof_add(WP_FACELIGHT, Time.get_ticks_usec() - _wpt)
		return
	c.eff_gen += 1
	# AC-0134 run-2 (fix-6): refresh the face-boundary cache for EVERY
	# landed chunk — fix-5 gated this on blk_src, wrong for fix-6: a
	# non-glow chunk's settled face is non-zero via imports, and this
	# landing is the moment its neighborhood deps (neighbor eff_gens) can
	# have changed. Stale entries are also rebuilt lazily at read time
	# (_face_of). Skipped entirely for arr-unchanged landings (no gen bump).
	var fk0 := _key(int(c.cx), int(c.cz))
	var cur: Array = _face_blk.get(fk0, [])
	if cur.size() != 3 or int(cur[0]) != int(c.data_gen) or not _face_deps_ok(c, cur[2]):
		_face_blk[fk0] = [c.data_gen, _compute_face_blk(c), _face_deps(c)]
	# fix-6: the E2 re-enqueue is NO LONGER gated on blk_src — a non-glow
	# chunk is a RELAY: its settled face (and hence its neighbors' imports)
	# changes when its own imported light lands. The per-side frame gate
	# still skips byte-identical sides (perf), and AWECRAFT_E2=off still
	# kills the whole wave (diagnostic kill switch).
	if OS.get_environment("AWECRAFT_E2") == "off":
		_wprof_add(WP_FACELIGHT, Time.get_ticks_usec() - _wpt)
		return
	var cx := int(c.cx)
	var cz := int(c.cz)
	var old_arr: PackedByteArray = old_eff.get("arr", PackedByteArray())
	var new_arr: PackedByteArray = new_eff.get("arr", PackedByteArray())
	# Per-side FRAME gate (perf, correctness-identical): a neighbor's strips
	# read ONLY the 2-deep boundary frame on the shared side (side strips
	# c=0/1 + corner strips), so if that frame is byte-identical old->new the
	# neighbor's import is unchanged and its re-light is a provable no-op.
	# This is what keeps the lava-ocean initial load from 2x-churning: a
	# chunk-center lava pocket never reaches the boundary -> zero enqueues.
	var ns := [[cx + 1, cz], [cx - 1, cz], [cx, cz + 1], [cx, cz - 1]]
	# AC-0218: the BORDER COMPARE (cheap edge-value compare vs the full
	# rebuild). A first landing (old_eff empty) is the "new column" case:
	# every built neighbor read an EMPTY strip from each side while the
	# column was missing (margin 0, no injection — _strips_for), so the
	# before-state edge values are all zero. Compare them against the NEW
	# edge values (_frame_nonzero — the 2-deep eff frame toward that side):
	# only mark light-dirty (re-enqueue the neighbor for the full light
	# rebuild + remesh) when the edge values DIFFER. A zero frame means the
	# neighbor's import is byte-identical (the bake box pre-zeros the
	# margin; the block face is subsumed — arr >= blk, the face row is
	# inside the 2-deep frame — so cand = 0 - att <= 0 cannot inject) and
	# its re-light is a PROVABLE NO-OP: the mark is skipped. Any nonzero
	# edge value (an open-sky frame row, block light) differs from the
	# before state and marks exactly as before. Steady-state landings
	# (old_eff non-empty) keep the existing per-side frame gate — that gate
	# IS the before/after border compare for re-lights (old frame vs new
	# frame), unchanged.
	var first_landing := old_eff.is_empty()
	for side in range(4):
		var side_changed: bool
		if first_landing:
			side_changed = _frame_nonzero(new_arr, side)
		else:
			side_changed = _frame_changed(old_arr, new_arr, side)
		# AC-0218: the border-compare verdicts (R16 dirty-count evidence).
		if first_landing:
			if side_changed:
				perf_e2_first_marks += 1
			else:
				perf_e2_first_skips += 1
		else:
			if side_changed:
				perf_e2_side_changed += 1
			else:
				perf_e2_side_unchanged += 1
		if not side_changed:
			continue
		var nkey := _key(int(ns[side][0]), int(ns[side][1]))
		var nc = chunks.get(nkey)
		if nc == null or nc.data.is_empty() or not nc.mesh_built:
			continue
		_eff_cache_evict(nkey)
		if not light_pending_set.has(nkey):
			light_pending.append(nkey)
			light_pending_set[nkey] = true
			perf_e2_marks += 1
	flush_active = true
	_wprof_add(WP_FACELIGHT, Time.get_ticks_usec() - _wpt)


# side 0=E (our lx 14,15) 1=W (lx 0,1) 2=S (lz 14,15) 3=N (lz 0,1); arrays
# are 16x16xh, idx = (y<<8) | (lz<<4) | lx.
func _frame_changed(a: PackedByteArray, b: PackedByteArray, side: int) -> bool:
	if a.size() != b.size():
		return true
	var h := a.size() / 256
	for y in range(h):
		var row := y << 8
		if side == 0:
			for lz in range(16):
				var i := row | (lz << 4) | 14
				if a[i] != b[i] or a[i | 1] != b[i | 1]:
					return true
		elif side == 1:
			for lz in range(16):
				var i := row | (lz << 4)
				if a[i] != b[i] or a[i | 1] != b[i | 1]:
					return true
		elif side == 2:
			for lx in range(16):
				var i := row | (14 << 4) | lx
				if a[i] != b[i] or a[i | 16] != b[i | 16]:
					return true
		else:
			for lx in range(16):
				var i := row | lx
				if a[i] != b[i] or a[i | 240] != b[i | 240]:
					return true
	return false


# AC-0218: the cheap border compare for a FIRST landing (the "new column"
# case of _eff_landed). Returns true when the new column's 2-deep eff frame
# toward `side` differs from the before-state — the EMPTY strip every built
# neighbor read while the column was missing (margin 0, no injection —
# _strips_for), i.e. ALL ZERO. Same cell set as _frame_changed (side strips
# c=0/1). A zero frame is a PROVABLE NO-OP for the neighbor: the bake box
# pre-zeros its margin (an all-zero strip writes zeros), and eff = max(sky,
# blk) so a zero frame means zero block light on the border too — the face
# row is inside the 2-deep frame (no separate face scan needed) and
# cand = 0 - att <= 0 can never raise — so the neighbor's light and mesh are
# byte-identical and its full re-light + remesh is skipped. Scans top-down:
# the open-sky rows above the column top (eff 15 — rows above the column's
# max non-air y are air open to the sky) exit after the first row on
# surface chunks; only a fully dark enclosed frame scans to the bottom and
# earns the skip it justifies. Later border changes are still caught: any
# frame value rising 0->n requires a re-light, whose _eff_landed re-runs the
# steady-state old-vs-new gate (eff only ever increases — no staleness).
func _frame_nonzero(arr: PackedByteArray, side: int) -> bool:
	var h := arr.size() / 256
	if side == 0:
		for y in range(h - 1, -1, -1):
			var row := y << 8
			for lz in range(16):
				var i := row | (lz << 4) | 14
				if arr[i] != 0 or arr[i | 1] != 0:
					return true
	elif side == 1:
		for y in range(h - 1, -1, -1):
			var row := y << 8
			for lz in range(16):
				var i := row | (lz << 4)
				if arr[i] != 0 or arr[i | 1] != 0:
					return true
	elif side == 2:
		for y in range(h - 1, -1, -1):
			var row := y << 8
			for lx in range(16):
				var i := row | (14 << 4) | lx
				if arr[i] != 0 or arr[i | 16] != 0:
					return true
	else:
		for y in range(h - 1, -1, -1):
			var row := y << 8
			for lx in range(16):
				var i := row | lx
				if arr[i] != 0 or arr[i | 240] != 0:
					return true
	return false


func _eff_cache_put(key: String, c: Node3D, eff: Dictionary, ngen = null) -> void:
	if eff.is_empty():
		return
	# AC-0203: the stamp ([data_gen, fl_gen]) replaces the 98 KB
	# data.duplicate() — every in-place column mutation bumps a gen.
	_eff_cache[key] = {"stamp": c.stamp(), "eff": eff, "ngen": ngen}
	if not _eff_cache_order.has(key):
		_eff_cache_order.append(key)
		while _eff_cache_order.size() > EFF_CACHE_CAP:
			_eff_cache.erase(_eff_cache_order.pop_front())

func _eff_cache_evict(key: String) -> void:
	_eff_cache.erase(key)
	if _eff_cache_order.has(key):
		_eff_cache_order.erase(key)

func _eff_for(c: Node3D, cx: int, cz: int) -> Dictionary:
	var key := _key(cx, cz)
	var cached = _eff_cache.get(key)
	if cached == null:
		return {}
	if int(c.data_gen) != int(cached.stamp[0]) or int(c.fl_gen) != int(cached.stamp[1]):
		return {}
	# AC-0129: the entry's light is only valid while the 4 neighbor eff_gens
	# (captured at its dispatch) are unchanged — a stale entry -> {} -> the
	# worker self-lights with fresh strips.
	if cached.get("ngen", null) == null or cached.ngen != _ngens_for(cx, cz):
		return {}
	perf_light_cache_hits += 1
	return cached.eff

# AC-0079 v3 C2: _bl_batch_step (the AC-0077 main-thread batch light) is
# DELETED — contained light now runs off the main thread: workers self-light
# their fresh copies (ChunkScript.build_accs) and the handoff feeds the eff
# cache below. _bl_want bookkeeping stays (recenter WANT fills it, release
# erases it); its early-return check in _drain_build_queue stays behavior-
# neutral. No light math changed (byte-identity: compute_light_flat_batch and
# compute_light_flat_chunk both route through _chunk_light_into).

# --- AC-0077: staged collision bodies (P1.4) --------------------------------

func _col_immediate_for(cx: int, cz: int) -> bool:
	if not col_stage_enabled:
		return true
	if cx == 0 and cz == 0:
		return true
	return maxi(absi(cx - last_pcx), absi(cz - last_pcz)) <= 1

func _stage_check(c: Node3D, key: String) -> void:
	if c == null or not col_stage_enabled:
		return
	if not c.collision_enabled or not c.any_col_dirty():
		return
	if c.has_all_slab_bodies():
		return
	var ccx := int(c.cx)
	var ccz := int(c.cz)
	if (ccx == 0 and ccz == 0) or maxi(absi(ccx - last_pcx), absi(ccz - last_pcz)) <= 1:
		return
	if not _col_pending_set.has(key):
		_col_pending.append(key)
		_col_pending_set[key] = true

func _col_dist(key: String) -> int:
	var c = chunks.get(key)
	if c == null:
		return 1000000
	return maxi(absi(int(c.cx) - last_pcx), absi(int(c.cz) - last_pcz))

func _col_drain_step() -> void:
	# <=2 staged bodies per frame, nearest-first, behind the build queue.
	# Validity: chunk present + mesh_built + no body yet (dup guard) +
	# collision_enabled + col_dirty + in radius; anything else drops (a
	# rebuilt or out-of-radius chunk is cancelled, never double-bodied).
	if _col_pending.is_empty():
		return
	_col_pending.sort_custom(func(a, b): return _col_dist(a) < _col_dist(b))
	var done := 0
	var i := 0
	while done < 2 and i < _col_pending.size():
		var key: String = _col_pending[i]
		var c = chunks.get(key)
		var ok: bool = c != null and c.mesh_built and c.collision_enabled and c.any_col_dirty() and maxi(absi(int(c.cx) - last_pcx), absi(int(c.cz) - last_pcz)) <= render_radius
		_col_pending.remove_at(i)
		_col_pending_set.erase(key)
		if not ok:
			perf_staged_dropped += 1
			continue
		c.build_dirty_slab_bodies()
		if not c.any_col_dirty():
			_count_collision_build(c)
			perf_staged_drained += 1
		else:
			perf_staged_dropped += 1
		done += 1

func _count_collision_build(c: Node3D) -> void:
	var dt := int(c.last_collision_build_ms)
	if dt > 0:
		perf_collision_ms += dt
		perf_collision_n += 1
		if dt > perf_collision_max_ms:
			perf_collision_max_ms = dt

func _key(cx: int, cz: int) -> String:
	var k := cx * 65536 + cz
	var s = chunk_keys.get(k)
	if s == null:
		s = "%d,%d" % [cx, cz]
		chunk_keys[k] = s
	return s

func _make_chunk_node(cx: int, cz: int) -> Node3D:
	var c: Node3D = _column_checkout()  # AC-0247: pooled column (fresh state) or a fresh node
	c.col_gen += 1  # AC-0247: the logical identity bump (instance_id is fixed per object)
	c.cx = cx
	c.cz = cz
	c.position = Vector3(cx * 16, 0, cz * 16)
	# AC-0152: band 0 gets collision; 1/2/3 do not. Out-of-set (stale
	# caller) clamps to collar so it can never mesh by accident.
	var nb := band_of(int(cx) - last_pcx, int(cz) - last_pcz)
	c.band = nb if nb >= 0 else 3
	c.collision_enabled = collision_enabled and c.band == 0
	c.init_slabs()
	add_child(c)
	chunks[_key(cx, cz)] = c
	return c

func create_chunk(cx: int, cz: int, mesh_now: bool) -> Node3D:
	# AC-0263: node creation only — the sync materialize/build are GONE
	# (fully queue-driven: the drain's data lane feeds the column, the
	# build lanes mesh it). mesh_now is a no-op kept for the signature
	# (no caller passed true).
	var c: Node3D = _make_chunk_node(cx, cz)
	return c

func stub_chunk(cx: int, cz: int) -> Node3D:
	return _make_chunk_node(cx, cz)

# AC-0119: pure lookup — a read NEVER generates. Missing chunk = null,
# stub = empty data; both read as air at the call sites (web world.block
# parity). All data generation lives in the drain/threadgen path.
func _chunk_data(cx: int, cz: int) -> Node3D:
	return chunks.get(_key(cx, cz))

func _enter_candidate(key: String, c: Node3D) -> bool:
	# AC-0168 hide-not-kill candidacy: keep node + data + fl + edits AND the
	# mesh (mesh_built stays true, slabs whole, instances never hidden) —
	# the fog at fog_far=(R+1)*16*0.875 (AC-0226) fully fogs the whole r+1
	# band before its near face, so stepping back re-enters the chunk
	# instantly (no re-queue, no re-mesh, no collision gap). True free
	# stays at r+2 after the 2-recenter
	# hysteresis in recenter(); the retained mesh dies with the node.
	c.candidate = true
	c.cand_since = 0
	# AC-0231: the old LOD cache clear (lod_pending/clear_lod_cache) is gone
	# with band 2 — the retained mesh is full fidelity (keep-high).
	var had_mesh: bool = c.mesh_built
	if had_mesh:
		# Pending mesh-bound work on an out-of-set chunk is stale; re-entry
		# re-marks it dirty via the normal paths. The eff cache stays — data
		# is kept, so the cached light is still valid on re-entry.
		light_pending_set.erase(key)
		light_pending.erase(key)
		fluid_dirty.erase(key)
		tex_refresh.erase(key)
		_col_pending_set.erase(key)
		_col_pending.erase(key)
	return had_mesh


func _strip_candidate_builds(keys: Array) -> void:
	# Remove surviving "build" queue entries of freshly-candidated chunks so
	# the drain cannot re-mesh them while they are invisible. "data" entries
	# are left in place (data gen on the r+1 ring is unchanged behavior).
	if keys.is_empty():
		return
	var kset := {}
	for k in keys:
		kset[k] = true
	for b in range(band_buckets.size()):
		var arr: Array = band_buckets[b]
		var i := 0
		while i < arr.size():
			var e: Dictionary = arr[i]
			if not bool(e["data_only"]) and kset.has(e["key"]):
				queued_keys.erase(e["key"])
				_qb.erase(e["key"])  # AC-0160
				arr.remove_at(i)
				queue_size -= 1
				_build_q_n -= 1  # AC-0222: a build entry left the queue
				_pool_touch()  # AC-0217: a pool candidate left the queue
			else:
				i += 1


# AC-0257 (instance cap): the one-column evict (the recenter free loop and
# the deferred drain share it). The heavy work — the instance detach + the
# pool checkins (_lod_free_all + _col_checkin) — is what the cap bounds.
func _free_chunk_key(key: String) -> void:
	var c: Node3D = chunks[key]
	_queue_chunk_save(c)  # AC-0155: full column to disk on evict (stubs skipped)
	_banana_evict(key)  # AC-0040: drop this chunk's hanging-fruit entries
	chunks.erase(key)
	queued_keys.erase(key)
	light_pending_set.erase(key)
	light_pending.erase(key)
	fluid_dirty.erase(key)
	tex_refresh.erase(key)
	_eff_cache_evict(key)
	_face_blk.erase(key)
	_bl_want.erase(key)
	_col_pending_set.erase(key)
	_col_pending.erase(key)
	if _cblog:
		# AC-0247: the scan runs BEFORE the pool checkins (the children
		# are still attached) — it counts the same nodes as the legacy
		# post-queue_free scan (a queue_free'd child stays in the tree
		# until the frame's deferred flush).
		var _nf := 0
		var _ms := 0
		var _surfs := 0
		for _ch in c.get_children():
			_nf += 1
			if _ch is MeshInstance3D:
				var _m = (_ch as MeshInstance3D).mesh
				if _m != null and _m is ArrayMesh:
					_surfs += (_m as ArrayMesh).get_surface_count()
		_nf += 1
		print("FREECH %d,%d n=%d surfs=%d" % [int(c.cx), int(c.cz), _nf, _surfs])
	_lod_free_all(c, false)  # AC-0247: the placeholders return to the MultiMesh pool (leave the live counts)
	if not _nofree:
		_col_checkin(c)  # AC-0247: the column node is reset + pooled (the legacy c.queue_free() is gone)

# AC-0257 (instance cap): the deferred free list (recenter defers the
# over-cap column frees — already-hidden r+1 candidates, a few frames of
# deferral is invisible). Each entry carries the column's identity (inst +
# col_gen — a pooled column REUSE keeps its instance_id, so col_gen is the
# discriminator, the AC-0247 stale-guard pattern): the drain frees ONLY the
# exact column that was evicted — a key the player re-occupied meanwhile is
# a DIFFERENT column object and must not be freed. Drained from _process at
# the per-frame cap.
var _deferred_free: Array = []

func _drain_deferred_free() -> void:
	if _deferred_free.is_empty():
		return
	var n := 0
	while n < stream_ho_cap and not _deferred_free.is_empty():
		var fe: Dictionary = _deferred_free[0]
		_deferred_free.remove_at(0)
		var c = chunks.get(fe["key"])
		if c == null or int(c.get_instance_id()) != int(fe["inst"]) or int(c.col_gen) != int(fe["colgen"]):
			continue  # already freed, or the key holds a re-occupied column
		_free_chunk_key(String(fe["key"]))
		n += 1

func recenter(wx: float, wz: float, mesh_now := true, wy: float = -1.0) -> void:
	last_pcx = int(floorf(wx / 16.0))
	last_pcz = int(floorf(wz / 16.0))
	# AC-0257: the AC-0234 vertical window recompute/tier-0 sync are gone —
	# the recenter walk (below) is the single collection point. The player
	# Y (carried on slab crossings) is the layer-rank origin for the bake
	# order (_grid_score); a -1 wy keeps the last known slab (X/Z-only
	# recenters).
	if wy >= 0.0:
		last_wy = wy
	# AC-0248: TOP-UP the pools to the ring target of the CURRENT render
	# radius (a no-op in the steady state — three int compares). Every
	# radius change ends in a recenter (Settings.apply_render_distance /
	# apply_world at boot / the harness arms), so the burst that follows a
	# slider move finds its ring of columns/MIs/MM pairs already warm.
	_pool_top_up()
	var pcx := last_pcx
	var pcz := last_pcz
	# AC-0213: small-move pacing — mark the move now; the drain paces at the
	# trickle budget until the window expires (see _drain_build_queue).
	var _now_ms := Time.get_ticks_msec()
	_sm_move_until = _now_ms + SMALL_MOVE_BUDGET_MS
	# AC-0231 order gate: the circle moved — a fog-only far chunk may have
	# just become in-r pending (and a pending in-r chunk may have left).
	_low_inr_invalidate()
	# AC-0213: ahead-ring requeue debounce — a recenter one chunk past the
	# previous center within AHEAD_RING_DEBOUNCE_MS re-queues the same ahead
	# ring the prior rebuild just queued (tap-forward across boundaries);
	# skip the full queue rebuild and let the in-flight/finalized walk stand.
	# The next non-debounced recenter rebuilds from the new center.
	# AC-0233: the debounce stands only while that standing rebuild still
	# covers the new center (REBUILD_COVER_L1, L1 from the walked center).
	# At high speed the player outruns the walked circle — past the limit
	# the standing queue is all behind (evicting farthest-first) and the
	# circle ahead has no entries at all, so the drain starves once the
	# pre-warmed line is exhausted (R16 50x flight). Past the limit this
	# recenter escalates to a full rebuild instead of debouncing.
	var _cover := absi(pcx - _rec_center_pcx) + absi(pcz - _rec_center_pcz)
	var _debounced := (_now_ms - _last_recenter_ms) < AHEAD_RING_DEBOUNCE_MS \
		and (absi(pcx - _last_recenter_pcx) + absi(pcz - _last_recenter_pcz)) == 1 \
		and _cover <= REBUILD_COVER_L1
	_last_recenter_ms = _now_ms
	_last_recenter_pcx = pcx
	_last_recenter_pcz = pcz
	_rp_free_ms = 0.0
	_rp_stub_ms = 0.0
	_rp_stub_n = 0
	_rp_walk_ms = 0.0
	_rp_insert_ms = 0.0
	_rp_dequeue_ms = 0.0
	_rp_deq_n = 0
	var rt0 := Time.get_ticks_usec()
	# AC-0080 two-stage hysteresis (AC-0168 hide-not-kill): r+1 = candidate
	# (keep node+data+edits+mesh, the fog hides it); r+2+ for 2 recenter
	# events = free. Jitter at r+1 resets cand_since, so a chunk never
	# flaps in and out.
	var rr := render_radius
	var to_free: Array[String] = []
	var cand_builds: Array = []
	for key in chunks:
		var c: Node3D = chunks[key]
		# AC-0143 face 2-11 chunks live in the 1024-cell sphere grid — the
		# home streaming set has no claim on them. (The old Chebyshev walk
		# swept them by accident; AC-0152 scopes it to home chunks.)
		if int(c.face) > 1:
			continue
		var dx := int(c.cx) - pcx
		var dz := int(c.cz) - pcz
		if in_stream_set(dx, dz):
			if c.candidate:
				c.candidate = false
				c.cand_since = 0
				_stage_check(c, key)
		else:
			if not c.candidate:
				if _enter_candidate(key, c):
					cand_builds.append(key)
			# Free once TWO rings clear the set after 2 recenter events;
			# one-ring-out chunks keep node+data as candidates (the old r+1
			# behavior). AC-0152 ring: the Euclidean one-ring-out predicate
			# is in_circle_ring itself — the old L2 (R+1)^2 threshold missed
			# the diagonal ring corners ((R+1,1) at R^2+2R+2 > (R+1)^2),
			# which would have been freed instead of kept as candidates.
			var two_out := not in_circle_ring(dx, dz) and absi(dx) + absi(dz) > b1_eff() + 2
			if not two_out:
				c.cand_since = 0
			else:
				c.cand_since += 1
				if c.cand_since >= 2:
					to_free.append(key)
	var tf1 := Time.get_ticks_usec()
	_strip_candidate_builds(cand_builds)
	# AC-0257 (instance cap): the per-frame detach/checkin is bounded by
	# the SAME cap as the attach burst (stream_ho_cap — the "Chunk meshes
	# per frame" setting, "one configurable number"). The free's heavy
	# work is the instance detach + the pool checkins (_lod_free_all +
	# _col_checkin — dozens of node detaches per column), so a recenter
	# over a full render circle used to detach the whole rim in ONE frame.
	# Free the first stream_ho_cap columns now, DEFER the rest — they are
	# already hidden candidates (r+1), so a few frames of deferral are
	# invisible; the drain runs from _process at the same cap.
	var free_n := 0
	for key in to_free:
		if free_n >= stream_ho_cap:
			var dc: Node3D = chunks[key]
			_deferred_free.append({"key": key, "inst": dc.get_instance_id(), "colgen": dc.col_gen})
			continue
		_free_chunk_key(key)
		free_n += 1
	_rp_free_ms += (Time.get_ticks_usec() - tf1) / 1000.0
	threadgen_poll()
	threadmesh_poll()
	io_poll()  # AC-0164
	# AC-0263: the mesh_now=false SYNC-FILL is GONE (every shipped caller
	# passes true; a dead branch that sync-materialized the whole stream
	# set — hundreds of columns of main-thread disk read/gen — would have
	# been the largest remaining sync path). Stream-set coverage is owned
	# by the recenter walk + the drain (queue-driven).
	var tr1 := Time.get_ticks_usec()
	if _debounced:
		# AC-0213: no queue rebuild — the prior rebuild (in flight or
		# finalized) already queued this ahead ring; the pre-warm below
		# still enqueues the fresh 5x5 and the drain trickles the rest.
		# AC-0233: a debounced column cross still REWRITES the waiting
		# parts — re-stamp the queue's tier/rank at the new center (the
		# pool key also changed via pcx/pcz, so the cached picks re-scan
		# anyway; this is the cheap amortized restamp for AC-0231).
		_rescore_kick()
	elif _rec_pending and _cover > REBUILD_COVER_L1:
		# AC-0233: outrun while a walk is in flight. Restarting the walk
		# from the new center on every crossing would livelock (each
		# restart discards the in-flight walk before it finalizes). Park
		# the target instead; the merge finalize re-checks and chains the
		# next walk if the player is still past coverage.
		_rec_escalate_pcx = pcx
		_rec_escalate_pcz = pcz
	else:
		_rec_start_walk(pcx, pcz)
	_rp_walk_ms += (Time.get_ticks_usec() - tr1) / 1000.0
	# AC-0160 spawn fast path (the pre-warm): the queue normally only exists
	# once the recenter slice's MERGE phase finishes (~2s of wall at r50:
	# 8k stubs), and the drain idles the whole time. Queue the spawn 5x5
	# (taxi <= 2 — exactly the 8-neighborhood the startup _build_ready gate
	# needs) NOW so the threadgen data pass starts while the slice walks:
	# the 3x3 data gen overlaps the stub walk instead of serializing behind
	# it. The merge rebuild re-queues these keys (WANT) or moves the
	# survivors; the handoff drop + finalization sweep (AC-0160) keep the
	# consumed entries from stranding the queue.
	for pdx in range(-2, 3):
		for pdz in range(-2, 3):
			# AC-0040: in_stream_set takes a DELTA from the center (its
			# circle/diamond/ring tests are center-relative). The old call
			# passed the ABSOLUTE (pcx+pdx, pcz+pdz), which only coincides
			# with the delta at the origin — away from it the pre-warm 5x5
			# silently shrank (at (1,6) only 8 of 25 cells survived),
			# starving the recenter of its build queue.
			if not in_stream_set(pdx, pdz):
				continue
			var wcx := pcx + pdx
			var wcz := pcz + pdz
			if not chunks.has(_key(wcx, wcz)):
				stub_chunk(wcx, wcz)
			_enqueue_build(wcx, wcz)
	# AC-0160 run 2: the 5x5 startup burst. The drain's data pass paces one
	# threadgen enqueue per frame, so the 5x5 (the 3x3's full 8-neighborhood)
	# landed in 2.5-3.1 s and the spawn 3x3 in ~5 s. A single HIGH-priority
	# GROUP task instead feeds all 24 non-center chunks to the pool at once
	# (tasks_needed = 6 of 6 threads -> 4 sequential gens per thread): the
	# 5x5 data lands in ~0.6-0.8 s and the 8 build gates pass together, so
	# the 3x3 builds pipeline right behind it. Workers run only
	# WorldGen.generate_args (the worker-safe core of _threadgen_worker)
	# and store the result in their own slot; the main-thread apply pass
	# (_startup_gen_apply) does the handoff (data + init_fl + edits) at a
	# bounded 4/frame. (0,0) is excluded: the spawn contract keeps its sync
	# gen in _gen_unit. A later recenter over already-generated terrain is a
	# no-op (had_data snapshot). The drain's data path keeps the 5x5 scope
	# as a fallback (TG enqueues race the group harmlessly: the apply pass
	# and the handoff both drop duplicates).
	# AC-0160 run 2: prune finished burst groups. A recenter whose group is
	# STILL in flight must leave the elems/slots arrays untouched: the
	# in-flight workers index those arrays (a reset races them — measured
	# in the boundary gate: "Invalid assignment of index '22'" worker
	# crashes, and a stale worker could write chunk A's terrain into chunk
	# B's slot). In that case the in-flight burst lands data on its own
	# chunks (still in the world — the player moved at most a couple of
	# chunks), this recenter's new forward chunks get data from the drain's
	# data pass, and pending_n = 0 keeps the drain hold from sticking.
	var _grp_keep: Array = []
	for _t in _startup_gen_group_tids:
		if threadgen_pool.is_group_task_completed(int(_t)):
			# AC-0178: a completed burst is CONSUMED here. The pool frees its
			# Group object only via wait_for_group_task_completion — without
			# it every burst leaks a Group ("Pages in use exist at exit in
			# PagedAllocator: WorkerThreadPool::Group"). The old
			# is_task_completed check was the wrong API for a group id: it
			# printed "Invalid Task ID" and returned false, so nothing was
			# ever pruned and the no-new-burst branch below stuck for the
			# whole session.
			threadgen_pool.wait_for_group_task_completion(int(_t))
		else:
			_grp_keep.append(_t)
	_startup_gen_group_tids = _grp_keep
	if _startup_gen_group_tids.is_empty():
		_startup_gen_elems = []
		_startup_gen_slots = []
		for pdx in range(-2, 3):
			for pdz in range(-2, 3):
				# AC-0263: the CENTER is in the burst (25 cells) — the
				# recenter's sync gen of (0,0) is GONE (fully queue-driven:
				# no main-thread generation ever). The startup burst is the
				# spawn anti-fall contract (kept).
				var bwx := pcx + pdx
				var bwz := pcz + pdz
				# AC-0040: in_stream_set is CENTER-RELATIVE (dx,dz = offset
				# from the recenter target). Passing the ABSOLUTE (bwx,bwz)
				# filtered the 5x5 against the ORIGIN's stream set — at the
				# spawn (pcx=pcz=0) delta==absolute so it worked; away from
				# it the burst only kept the cells whose absolute position
				# fell in the origin set (8 of 24 at (1,6)), so the new
				# center's 8-neighborhood never got its data and the 3x3
				# (and _spawn_fast) stalled. Every other call site (L3843,
				# L3907, L4173, L4219, L4243) passes the explicit delta.
				if not in_stream_set(pdx, pdz):
					continue
				var bc = chunks.get(_key(bwx, bwz))
				# AC-0164: a saved 5x5 column is read by a WORKER (the old
				# sync 24-column load was the ~500 ms recenter hitch). A
				# successful enqueue (file exists, or a read is already in
				# flight) marks the had_data snapshot true so the burst
				# worker skips it; the read lands via io_poll and the
				# pending key keeps gen from re-enqueueing the column.
				var had_data: bool = bc != null and not bc.data.is_empty()
				if bc != null and bc.data.is_empty():
					had_data = _io_read_enqueue(bwx, bwz, _key(bwx, bwz), false)
				# args snapshot in the element (worker never derefs Game/Data —
				# the _threadgen_worker entry pattern). AC-0216: e[7] = the
				# offscreen-interior lazy-skip flag (the 5x5 burst is band 0
				# in practice — never skipped — but computed for uniformity).
				_startup_gen_elems.append([absi(bwx - pcx) + absi(bwz - pcz), bwx, bwz, had_data, Game.world_seed, Data.HEIGHT, Data.SEA, _gen_skip_flag(bwx, bwz)])
				_startup_gen_slots.append(null)
		_startup_gen_elems.sort_custom(func(a, b): return int(a[0]) < int(b[0]) or (int(a[0]) == int(b[0]) and (int(a[1]) < int(b[1]) or (int(a[1]) == int(b[1]) and int(a[2]) < int(b[2])))))
		var _burst_need := 0
		for _be in _startup_gen_elems:
			if not bool(_be[3]):
				_burst_need += 1
		_startup_gen_pending_n = _burst_need
		if _burst_need > 0:
			_startup_gen_started_ms = Time.get_ticks_msec()  # AC-0263: self-heal window
			# HIGH priority + 3-wide: measured on this Godot build, a LOW
			# priority GROUP task runs its elements strictly serially on ONE
			# thread (24 x 120 ms = 2.9 s) even with tasks_needed=3 — so the
			# burst must stay high priority (3-wide, ~165 ms/task, 24 chunks in
			# ~1.3 s). The FIFO overlap problem a high-priority group would
			# cause (TM builds queueing behind the 24 gen elements) is gone by
			# construction: the drain hold below keeps ALL builds out of the
			# pool until the burst is fully applied, so the group runs alone on
			# 3 of the 6 threads and the 9 spawn builds start on the 6 free
			# threads the frame after the burst lands. 3-wide keeps the gen wms
			# near the solo floor (6-wide runs ~320 ms/task here — allocator/
			# bandwidth bound). Elements are taxi-ordered (d=1 first).
			_startup_gen_group_tids.append(threadgen_pool.add_group_task(_startup_gen_worker, _startup_gen_elems.size(), 3, true))
			if timing:
				print("GENBURST n=%d t=%d" % [_burst_need, Time.get_ticks_msec()])
	else:
		# A previous burst is still landing: its apply pass owns the
		# pending count bookkeeping for its own chunks; this recenter
		# adds nothing to the pool (the data pass covers the new edge).
		_startup_gen_pending_n = 0
	# AC-0263: the (0,0) sync gen is GONE — fully queue-driven (the startup
	# burst now carries the center; the drain data path feeds the rest).
	if _recprobe:
		print("RECPROBE r=%d total_ms=%.1f free_ms=%.1f rebuild_ms=%.1f new_n=%d queue=%d chunks=%d drain_stubs_ms=%.1f drain_stubs_n=%d" % [
			render_radius,
			(Time.get_ticks_usec() - rt0) / 1000.0,
			_rp_free_ms, _rp_walk_ms, _rp_stub_n,
			queue_size, chunks.size(),
			_rp_drain_stub_ms, _rp_drain_stub_n])

func _recenter_slice() -> void:
	if not _rec_pending:
		return
	# AC-0160 run 2: pause the slice for the SPAWN window only (_spawn_fast,
	# cleared when the spawn 3x3 builds). The rebuild walk/stubs are ~5 s of
	# main-thread work at r50; racing it against the burst inflates the gen
	# wms, and racing it against the spawn handoffs starves them (the (0,0)
	# handoff's face-cache refresh is ~1.2 s of main-thread work, and the
	# other 8 handoffs then wait on slice frame gaps — measured 3x3
	# 4.0-5.6 s with the slice running). Paused: the burst runs 3-wide at
	# solo wms (~1.3 s) and the 9 spawn handoffs run on a free main thread
	# right after the worker wave lands. The slice then takes its ~5 s and
	# the queue swap lands a couple of seconds after the 3x3 (the bandmap
	# arm waits for the swap before the trickle sample). Keying this on
	# _startup_pending() instead broke walking: that flag stays true for
	# every recenter (the forward 3x3 is unbuilt), the slice never rebuilt
	# the queue, and the drain had nothing to stream (35 s stall, empty
	# world ahead of the player — boundary gate regression).
	if _spawn_fast:
		return
	var t0 := Time.get_ticks_msec()
	var units := 0
	while _rec_pending and units < REC_UNITS_PER_FRAME and Time.get_ticks_msec() - t0 < REC_SLICE_BUDGET_MS:
		if _rec_phase == 0:
			_rec_want_step()
		elif _rec_phase == 1:
			_rec_stub_step()
		elif _rec_phase == 2:
			_rec_merge_old_step()
		elif _rec_phase == 3:
			_rec_merge_want_step()
		else:
			_rec_merge_ring_step()
		units += 1
	var fm := float(Time.get_ticks_msec() - t0)
	_rec_slice_total_ms += fm
	_rec_slice_frames += 1
	if fm > _rec_slice_max_ms:
		_rec_slice_max_ms = fm
	if not _rec_pending:
		if _recprobe:
			print("RECSLICE r=%d total_ms=%.1f max_ms=%.1f frames=%d new_n=%d stubs=%d queue=%d" % [
				render_radius, _rec_slice_total_ms, _rec_slice_max_ms,
				_rec_slice_frames, _rec_new_n, _rp_stub_n, queue_size])
		_rp_stub_n = _rec_new_n

func _reband(c: Node3D, key: String, oldb: int, nb: int) -> void:
	# AC-0231: band 2 (the coarse LOD) is GONE — every meshed band is
	# full fidelity, so a band change only moves the collision flag
	# (0 <-> 1) or the data-only bookkeeping (3 <-> 0/1). The MESH (high)
	# is never rebuilt by a band change (keep-high); the low placeholder
	# exists only on never-built far chunks (band 3) and a reband leaves
	# its fog/low untouched.
	c.band = nb
	c.collision_enabled = collision_enabled and nb == 0
	if not bool(c.mesh_built):
		return
	if oldb == 0 and nb != 0:
		c.drop_slab_bodies()
	elif nb == 0 and oldb != 0:
		c.mark_all_slabs_dirty()
		if not _col_pending_set.has(key):
			_col_pending.append(key)
			_col_pending_set[key] = true
func _rec_start_walk(pcx: int, pcz: int) -> void:
	# AC-0233: start (or restart) the recenter rebuild walk at (pcx, pcz)
	# and arm the coverage anchor. A restart discards the in-flight walk's
	# partial state safely: the WANT/STUB phases are pure bookkeeping and
	# the queue swap is atomic at the merge finalize, so nothing partial
	# ever reaches band_buckets.
	_rec_pending = true
	_rec_pcx = pcx
	_rec_pcz = pcz
	_rec_center_pcx = pcx
	_rec_center_pcz = pcz
	_rec_escalate_pcx = -9999
	_rec_escalate_pcz = -9999
	_rec_phase = 0
	_rec_cursor = 0
	_rec_i = 0
	_rec_want = {}
	_rec_want_keys = []
	_rec_new_buckets = []
	for i in range(_bucket_count()):
		_rec_new_buckets.append([])
	_rec_slice_total_ms = 0.0
	_rec_slice_max_ms = 0.0
	_rec_slice_frames = 0
	_rec_new_n = 0

func _rec_want_step() -> void:
	# AC-0152: walk the stream-set bounding box (circle ∪ collar ∪ ring);
	# skip out-of-set cells. Band changes on existing chunks reband (kill
	# the old representation, keep data) and re-queue under the new band's
	# dispatch path.
	var half := maxi(render_radius + 1, b1_eff() + 1)
	var side := 2 * half + 1
	if _rec_cursor >= side * side:
		_rec_phase = 1
		_rec_cursor = 0
		_bl_want = {}
		for k in _rec_want:
			_bl_want[k] = true
		return
	var dx := _rec_cursor / side - half
	var dz := _rec_cursor % side - half
	_rec_cursor += 1
	if not in_stream_set(dx, dz):
		return
	var nb := band_of(dx, dz)
	if nb == 3:
		# Band 3 (collar ∪ circle ring): data only — MERGE_RING enqueues
		# the data entries.
		return
	var cx := _rec_pcx + dx
	var cz := _rec_pcz + dz
	var key := _key(cx, cz)
	var c = chunks.get(key)
	var old = queued_keys.get(key)
	if c != null:
		var cb := int(c.band)
		if cb != nb:
			# AC-0231: no LOD hysteresis / keep-high-to-band-2 — band 2 is
			# gone and _reband never rebuilds the mesh (keep-high is
			# structural: the low placeholder is only for never-built far).
			_reband(c, key, cb, nb)
			if old == "data":
				_convert_data_to_build(key)
				old = queued_keys.get(key)
	if old != "build" and (c == null or not c.mesh_built):
		_rec_want[key] = {"cx": cx, "cz": cz, "d": absi(dx) + absi(dz)}
		_rec_want_keys.append(key)

func _rec_stub_step() -> void:
	# AC-0152: stub every missing stream-set chunk (circle ∪ collar ∪ ring).
	# The old Chebyshev r+1 data-ring stub walk is folded into the band-3
	# walk of the MERGE_RING phase.
	var half := maxi(render_radius + 1, b1_eff() + 1)
	var side := 2 * half + 1
	if _rec_cursor >= side * side:
		_rec_phase = 2
		_rec_cursor = 0
		_rec_i = 0
		return
	var dx := _rec_cursor / side - half
	var dz := _rec_cursor % side - half
	_rec_cursor += 1
	if not in_stream_set(dx, dz):
		return
	var cx := _rec_pcx + dx
	var cz := _rec_pcz + dz
	if not chunks.has(_key(cx, cz)):
		stub_chunk(cx, cz)
		_rp_stub_n += 1

func _rec_merge_old_step() -> void:
	var b := _rec_cursor
	if b >= band_buckets.size():
		_rec_phase = 3
		_rec_cursor = 0
		return
	var arr: Array = band_buckets[b]
	if _rec_i >= arr.size():
		_rec_cursor = b + 1
		_rec_i = 0
		return
	var e: Dictionary = arr[_rec_i]
	_rec_i += 1
	var key: String = e["key"]
	var adxs := int(e["cx"]) - _rec_pcx
	var adzs := int(e["cz"]) - _rec_pcz
	if not in_stream_set(adxs, adzs):
		if not chunks.has(key):
			queued_keys.erase(key)
		return
	if _rec_want.has(key):
		queued_keys.erase(key)
		return
	_rec_new_buckets[mini(absi(adxs) + absi(adzs), _rec_new_buckets.size() - 1)].append(e)

func _rec_merge_want_step() -> void:
	if _rec_cursor >= _rec_want_keys.size():
		_rec_phase = 4
		_rec_cursor = 0
		return
	var key: String = _rec_want_keys[_rec_cursor]
	_rec_cursor += 1
	var c = chunks.get(key)
	if c != null and c.mesh_built:
		return
	var w: Dictionary = _rec_want[key]
	queued_keys[key] = "build"
	# AC-0222: the fresh ahead chunks (this recenter's new stream set) go to
	# the FRONT of their band bucket — the newest entries first, ahead of
	# the re-bucketed older entries (the drain's per-bucket scan visits
	# index 0 first).
	var entry := {"key": key, "cx": int(w["cx"]), "cz": int(w["cz"]), "data_only": false}
	_tier_stamp(entry)  # AC-0233: the new waiting part carries its tier
	_rec_new_buckets[mini(int(w["d"]), _rec_new_buckets.size() - 1)].push_front(entry)
	_rec_new_n += 1

func _rec_merge_ring_step() -> void:
	# AC-0152: the old Chebyshev r+1 data ring is now the BAND-3 walk —
	# band 3 chunks (the collar: diamond b1_eff+1 outside the circle, plus
	# the circle ring: outside the circle, touching it within 8-neighbors)
	# get data-only entries so band 0/1 edge chunks (small R) and band 2
	# edge chunks (large R) build against real 4-axis neighbors.
	var half := maxi(render_radius + 1, b1_eff() + 1)
	var side := 2 * half + 1
	if _rec_cursor >= side * side:
		# AC-0160: the pre-warm queue ran in parallel with this walk, so the
		# drain may have consumed entries the walk also moved/re-queued. An
		# entry whose chunk is now done (build: mesh_built, data: has data)
		# would strand the queue forever (both pools skip it) — drop the
		# stale ones against the LIVE chunk state, not the walk-time state.
		for b in range(_rec_new_buckets.size()):
			var arrf: Array = _rec_new_buckets[b]
			var i := 0
			while i < arrf.size():
				var e2: Dictionary = arrf[i]
				var c2 = chunks.get(e2["key"])
				if c2 != null and (not c2.data.is_empty() if bool(e2["data_only"]) else c2.mesh_built):
					# Stale: the chunk finished while the walk ran — the entry is
					# a no-op now (both pools skip it); drop it from the rebuilt queue.
					arrf.remove_at(i)
					continue
				i += 1
		var qs := 0
		var bns := 0
		for b in range(_rec_new_buckets.size()):
			for e2 in _rec_new_buckets[b]:
				qs += 1
				if not bool(e2["data_only"]):
					bns += 1
		band_buckets = _rec_new_buckets
		_pool_touch()  # AC-0217: the whole queue was re-bucketed
		_rebuild_qb()  # AC-0160
		_drain_win_b = b1_eff() + 2  # AC-0160: restart the drain window at the new center
		_drain_win_acc = 0
		dq_b = 0
		dq_i = 0
		mq_b = 0
		mq_i = 0
		queue_size = qs
		_build_q_n = bns  # AC-0222: recompute the build depth at the merge swap
		_cap_queue_depth()  # AC-0222: apply the cap to the rebuilt queue
		_rescore_kick()  # AC-0233: column cross — rewrite the rebuilt queue's tiers
		_rec_pending = false
		_rec_want = {}
		_rec_want_keys = []
		_rec_new_buckets = []
		_rec_cursor = 0
		_rec_i = 0
		# AC-0233: outrun escalation parked in recenter while this walk was
		# in flight — if the player is STILL past this walk's coverage,
		# chain the next walk at the player's current center right now (one
		# R16 walk is a single 8 ms frame, so the chain stays cheap); if
		# they moved back inside, drop it.
		if _rec_escalate_pcx > -9000:
			if absi(last_pcx - _rec_pcx) + absi(last_pcz - _rec_pcz) > REBUILD_COVER_L1:
				_rec_start_walk(last_pcx, last_pcz)
			_rec_escalate_pcx = -9999
			_rec_escalate_pcz = -9999
		return
	var dx := _rec_cursor / side - half
	var dz := _rec_cursor % side - half
	_rec_cursor += 1
	if band_of(dx, dz) != 3:
		return
	var cx := _rec_pcx + dx
	var cz := _rec_pcz + dz
	var key := _key(cx, cz)
	if queued_keys.has(key):
		return
	var c = chunks.get(key)
	if c != null and not c.data.is_empty():
		return
	queued_keys[key] = "data"
	# AC-0222: the fresh band-3 feed entries (collar ∪ circle ring) go to the
	# FRONT of their band bucket — newest first, like the want entries.
	var entry := {"key": key, "cx": cx, "cz": cz, "data_only": true}
	_tier_stamp(entry)  # AC-0233: the new waiting part carries its tier
	_rec_new_buckets[mini(absi(dx) + absi(dz), _rec_new_buckets.size() - 1)].push_front(entry)
	_rec_new_n += 1

func get_block(x: int, y: int, z: int) -> int:
	if y < 0 or y >= Data.HEIGHT:
		return 0
	var c := _chunk_data(int(floorf(float(x) / 16.0)), int(floorf(float(z) / 16.0)))
	if c == null or c.data.is_empty():
		return 0
	return c.get_local(x & 15, y, z & 15)

func set_block(x: int, y: int, z: int, id: int, create := true) -> void:
	if y < 0 or y >= Data.HEIGHT:
		return
	var cx := int(floorf(float(x) / 16.0))
	var cz := int(floorf(float(z) / 16.0))
	var c: Node3D
	if create:
		c = _chunk_data(cx, cz)
	else:
		c = chunks.get(_key(cx, cz))
	if c == null or c.data.is_empty():
		return
	var lx := x & 15
	var lz := z & 15
	c.set_local(lx, y, lz, id)
	if _fluidprobe:
		_fp_writes += 1
	var fi := (y << 8) | (lz << 4) | lx
	if is_fluid_id(id):
		if c.fl_at(fi) == 0:
			c.set_fl_at(fi, 7)
		fluid_wet[_key(cx, cz)] = true
	else:
		c.set_fl_at(fi, 0)
	c.mark_edit_slabs(y)
	_edit_stale_eff[_key(cx, cz)] = _eff_cache.get(_key(cx, cz))
	_dirty_add(_key(cx, cz), y)  # AC-0233: edited chunk -> dirtyQueue (drains first, 1/frame)
	# AC-0199: a boundary edit (lx/lz in [0,1] or [14,15] - the SNAP_W 18
	# ring reaches 1 cell past the chunk edge, 2 deep for the merge margin)
	# also dirties the E/W/N/S neighbor, jumped to the queue front.
	var elx := x & 15
	var elz := z & 15
	if elx <= 1:
		_dirty_front(_key(cx - 1, cz), y)
	elif elx >= 14:
		_dirty_front(_key(cx + 1, cz), y)
	if elz <= 1:
		_dirty_front(_key(cx, cz - 1), y)
	elif elz >= 14:
		_dirty_front(_key(cx, cz + 1), y)
	_eff_cache_evict(_key(cx, cz))
	_mark_light_around(cx, cz)
	if _fluid_near(x, y, z):
		_fluid_write = true
		# AC-0244 (2026-09-09 user bug): natural (worldgen) water is fl=0 -
		# stationary by the AC-0203 sparse-scan design, and _fluid_write
		# alone does not help because the scan is gated on the per-chunk
		# fluid_wet set, which natural water never enters. Breaking a block
		# next to/under a lake must wake the water: give every adjacent
		# fl=0 fluid cell an active level so the scan (fl!=0 cells only)
		# can move it into the dig. The rest of the lake stays fl=0
		# (zero scan work); only the edge cells an edit touches activate.
		_wake_fluid_around(x, y, z)
	_record_edit(cx, cz, fi, id, c.fl_at(fi))


func _wake_fluid_around(x: int, y: int, z: int) -> void:
	for d in [[0, 1, 0], [0, -1, 0], [1, 0, 0], [-1, 0, 0], [0, 0, 1], [0, 0, -1]]:
		var nx: int = x + int(d[0])
		var ny: int = y + int(d[1])
		var nz: int = z + int(d[2])
		if ny < 0 or ny >= Data.HEIGHT:
			continue
		var ncx: int = int(floorf(float(nx) / 16.0))
		var ncz: int = int(floorf(float(nz) / 16.0))
		var nc: Node3D = chunks.get(_key(ncx, ncz))
		if nc == null or nc.data.is_empty():
			continue
		var nfi: int = (ny << 8) | ((nz & 15) << 4) | (nx & 15)
		if is_fluid_id(nc.get_at(nfi)) and nc.fl_at(nfi) == 0:
			nc.set_fl_at(nfi, 7)
			fluid_wet[_key(ncx, ncz)] = true

func _mark_light_around(cx: int, cz: int) -> void:
	for dx in range(-LIGHT_NEIGHBOR, LIGHT_NEIGHBOR + 1):
		for dz in range(-LIGHT_NEIGHBOR, LIGHT_NEIGHBOR + 1):
			var k := _key(cx + dx, cz + dz)
			# AC-0218: count only NEW marks (an already-dirty key is a no-op
			# re-mark; the counter is the "dirty count" the R16 arm reports).
			if not light_dirty.has(k):
				light_dirty[k] = true
				perf_lightdirty_marks += 1

func _mark_fluid_around(cx: int, cz: int) -> void:
	for dx in range(-LIGHT_NEIGHBOR, LIGHT_NEIGHBOR + 1):
		for dz in range(-LIGHT_NEIGHBOR, LIGHT_NEIGHBOR + 1):
			fluid_dirty[_key(cx + dx, cz + dz)] = true

func _record_edit(cx: int, cz: int, fi: int, b: int, f: int) -> void:
	var key := _key(cx, cz)
	if not edits.has(key):
		edits[key] = {}
	edits[key][fi] = {"b": b, "f": f}

func _apply_edits_to_chunk(c: Node3D) -> bool:
	var key := _key(c.cx, c.cz)
	if not edits.has(key):
		return false
	if c.data.is_empty():
		return false
	var cells: Dictionary = edits[key]
	var changed := false
	var fl_changed := false
	for fkey in cells:
		var e: Dictionary = cells[fkey]
		var fi := int(fkey)
		var b := int(e.get("b", 0))
		var f := int(e.get("f", 0))
		if c.get_at(fi) != b:
			changed = true
		if c.fl_at(fi) != f:
			fl_changed = true
		c.set_local(fi & 15, fi >> 8, (fi >> 4) & 15, b)
		c.set_fl_at(fi, f)
		if f > 0:
			fluid_wet[_key(c.cx, c.cz)] = true
	if not changed and not fl_changed:
		return false
	c.update_top()  # AC-0197: edits may raise (or clear) the top
	c.mark_all_slabs_dirty()
	_eff_cache_evict(key)
	if changed:
		c.saved_light = {}
		_mark_light_around(c.cx, c.cz)
	_mark_fluid_around(c.cx, c.cz)
	return changed

# AC-0155: full-column persistence (Bedrock LevelDB / Java region style).
# Every generated 16xHx16 column is saved whole (data + fl, palette+bitpack
# per 16^3 subchunk, zlib, versioned) when it leaves the streaming set; a
# revisit reads the file instead of re-running the generator. Edits are
# already baked into c.data, so the file is the source of truth and the
# JSON edits diff is redundant-but-idempotent on load (re-applied below).

func _chunk_face(cx: int) -> int:
	return 1 if cx < 0 else 0

func _try_disk_load(c: Node3D, cx: int, cz: int) -> bool:
	if Save.active_slot < 0:
		return false
	# AC-0175: region-first (table + one blob seek), legacy per-column file
	# fallback - read_column_bytes is the shared worker-safe helper.
	var bytes := ChunkIO.read_column_bytes(int(Save.active_slot), cx, cz)
	if bytes.is_empty():
		return false
	var t0 := Time.get_ticks_usec()
	var res = ChunkIO.decode_column(bytes, int(Game.world_seed), int(Data.HEIGHT))
	disk_read_ms += (Time.get_ticks_usec() - t0) / 1000.0
	if res == null or (typeof(res) != TYPE_DICTIONARY) or (res as Dictionary).is_empty():
		return false
	_land_column(c, res)
	_banana_register_disk(c, cx, cz)  # AC-0040: saved hanging bananas resume
	c.saved_light = _saved_light_from_res(res.get("light", {}), cx, cz)
	disk_reads += 1
	chunk_origin[_key(cx, cz)] = "disk"
	return true

# AC-0203 recenter fix: the disk-landing choke point. v4 blobs carry the
# slab array (decode_column d_slabs/f_slabs) -> reference handoff; v1-v3
# (old saves) fall back to the flat palettize path.
func _land_column(c: Node3D, res: Dictionary) -> void:
	var ds = res.get("d_slabs")
	if ds != null and (ds is Array) and res.get("f_slabs") != null:
		c.slabs_landed(ds, res["f_slabs"])
	else:
		c.data_landed(res["data"], res["fl"])
	# AC-0237: restore the generated state (v5 stores the 24-bit mask;
	# v1-v4 = the full column). An ungenerated slab that reloads is
	# solid-for-snap + capped + regen-owed, NOT air.
	var gmask := int(res.get("gen_mask", 0xFFFFFF))
	c.gen_mask = gmask
	var gk := PackedByteArray()
	if gmask != 0xFFFFFF:
		gk.resize(int(c.data.size()))
		for si in range(gk.size()):
			gk[si] = 1 if ((gmask >> si) & 1) != 0 else 0
	c.gen_keep = gk
	# AC-0257: an old AC-0237 save may hold a range-generated column (a
	# partial gen_mask — slabs the old window never generated). The vwin
	# owed-regen is gone: a plain full regen refills the missing slabs
	# (bit-exact). The built mesh was made against the stone-snap view of
	# those slabs and rides until the next re-mesh (tier flip / edit /
	# reband) — a deep-interior cosmetic at worst.
	if gmask != 0xFFFFFF:
		threadgen_enqueue(int(c.cx), int(c.cz), _key(int(c.cx), int(c.cz)), c.get_instance_id(), false, int(c.col_gen))
	_pool_touch()  # AC-0217: disk data landed on a queued entry
	_low_fog_for(c)  # AC-0231: the immediate fog-box first pass (far only)


func _saved_light_from_res(light: Dictionary, cx: int, cz: int) -> Dictionary:
	if light.is_empty():
		return {}
	var arr: PackedByteArray = light.get("arr", PackedByteArray())
	var mask: PackedByteArray = light.get("mask", PackedByteArray())
	if arr.size() != 256 * Data.HEIGHT or mask.size() != 256 * Data.HEIGHT:
		return {}
	return {
		"mn": Vector3i(cx * 16, 0, cz * 16),
		"w": 16,
		"d": 16,
		"arr": arr,
		"mask": mask,
		"blk_src": bool(light.get("blk_src", false)),
	}



func _queue_chunk_save(c: Node3D) -> void:
	if Save.active_slot < 0 or c.data.is_empty():
		return
	# AC-0164: the slot is captured AT ENQUEUE — the active slot can change
	# mid-flight (continue / new game) and a write in flight must still land
	# in the captured slot's dir, not the current one's.
	var key := _key(int(c.cx), int(c.cz))
	var light: Dictionary = _save_light_for(c, key)
	_save_queue.append({
		"slot": int(Save.active_slot),
		"face": _chunk_face(int(c.cx)),
		"cx": int(c.cx),
		"cz": int(c.cz),
		# AC-0203 recenter fix: the evict path ran on every recenter frame —
		# flat_data()/flat_fl() expanded both 98 KB columns on the main
		# thread. The worker encodes from the slab copies (~20 KB/col) via
		# _slabs_flat; the on-disk bytes are unchanged (same flat -> v4).
		# AC-0214: both ops are C++ (ChunkIOPalette.slab_copy — true byte
		# copies, COW-isolated from the live chunk — and the worker's
		# slabs_flat below).
		"data": ChunkIO.io_cpp().slab_copy(c.data),
		"fl": ChunkIO.io_cpp().slab_copy(c.fl),
		"light": light,
		"gen_mask": int(c.gen_mask),  # AC-0237: v5 — the generated mask rides on disk
	})

func _save_light_for(c: Node3D, key: String) -> Dictionary:
	var out := {}
	if light_pending_set.has(key) or light_dirty.has(key):
		return out
	var cached = _eff_cache.get(key)
	if cached == null or int(c.data_gen) != int(cached.stamp[0]) or int(c.fl_gen) != int(cached.stamp[1]):
		return out
	var full: Dictionary = cached.eff
	var arr: PackedByteArray = full.get("arr", PackedByteArray())
	var mask: PackedByteArray = full.get("mask", PackedByteArray())
	if arr.is_empty() or mask.is_empty():
		return out
	return {
		"arr": arr.duplicate(),
		"mask": mask.duplicate(),
		"blk_src": bool(full.get("blk_src", false)),
	}

func _drain_save_queue() -> void:
	if _save_queue.is_empty():
		return
	# AC-0178: loading window — lift the 1-2 cols/frame write pacing
	# (encode+write already run on the AC-0164 worker).
	var n := LOAD_SAVE_PER_FRAME if loading_active else (2 if _save_queue.size() > 8 else 1)
	for k in n:
		if _save_queue.is_empty():
			break
		var e: Dictionary = _save_queue.pop_front()
		# AC-0164: enqueue only — encode + file write run on a worker.
		_io_write_enqueue(e)

func _io_write_enqueue(e: Dictionary) -> void:
	var cx := int(e["cx"])
	var cz := int(e["cz"])
	var key := _key(cx, cz)
	if _io_write_keys.has(key):
		# A write for this column is already in flight: its snapshot (plus
		# the JSON edits diff on load) is valid; the newer one would race the
		# same file path. Drop it.
		_io_wdedup += 1
		return
	var t0 := Time.get_ticks_usec()
	var slot := int(e["slot"])
	ChunkIO.ensure_dir(slot)
	var entry := {
		"key": key,
		"slot": slot,
		"cx": cx,
		"cz": cz,
		"data": e["data"],
		"fl": e["fl"],
		"light": e.get("light", {}),
		"gen_mask": int(e.get("gen_mask", 0xFFFFFF)),  # AC-0237
		"seed": int(Game.world_seed),
		"height": int(Data.HEIGHT),
	}
	var tid = io_pool.add_task(_io_write_worker, false)
	entry["tid"] = tid
	_io_slots[tid] = entry
	_io_write_inflight.append(entry)
	_io_write_keys[key] = true
	_io_write_n += 1
	_io_main_write_ms += (Time.get_ticks_usec() - t0) / 1000.0

func _io_write_worker() -> void:
	# AC-0164: encode + FileAccess on a worker. The worker owns its entry's
	# data copies (duplicated at enqueue) — no shared state is touched.
	var tid = io_pool.get_caller_task_id()
	var entry = _io_slots.get(tid)
	var ns := 0
	while entry == null and ns < 200:
		OS.delay_msec(1)
		entry = _io_slots.get(tid)
		ns += 1
	if entry == null:
		return
	# AC-0203 recenter fix: the entry carries slab arrays (the main thread
	# no longer expands them); _slabs_flat reproduces the exact 98 KB column.
	# AC-0214: the expansion is C++ (ChunkIOPalette.slabs_flat; the worker
	# io_cpp() instantiate is the established pattern — _io_read_worker's
	# decode_column already runs it here).
	# AC-0175: the worker encodes only; the REGION FILE commit (table update
	# + blob write) runs on the main thread in _io_write_commit because the
	# region file is shared by many columns and must be mutated serially.
	var io: Variant = ChunkIO.io_cpp()
	var blob := ChunkIO.encode_column(io.slabs_flat(entry["data"]), io.slabs_flat(entry["fl"]), int(entry["seed"]), int(entry["height"]), entry.get("light", {}), -1, int(entry.get("gen_mask", 0xFFFFFF)))  # AC-0237: v5 when range-generated
	entry["blob"] = blob

func _io_read_enqueue(cx: int, cz: int, key: String, apply_edits: bool) -> bool:
	# AC-0164: true = the column is covered by a worker read (file exists,
	# or a read for it is already in flight). The caller must NOT enqueue
	# generation for that column. Main-thread cost = file_exists + add_task.
	if Save.active_slot < 0:
		return false
	if _io_read_keys.has(key):
		_io_dedup += 1
		return true
	var t0 := Time.get_ticks_usec()
	var slot := int(Save.active_slot)
	# AC-0175: region entry OR legacy file (the helper covers both).
	if not ChunkIO.saved_column_exists(slot, cx, cz):
		return false
	var entry := {
		"key": key,
		"slot": slot,
		"cx": cx,
		"cz": cz,
		"seed": int(Game.world_seed),
		"height": int(Data.HEIGHT),
		"apply_edits": apply_edits,
	}
	var tid = io_pool.add_task(_io_read_worker, false)
	entry["tid"] = tid
	_io_slots[tid] = entry
	_io_read_inflight.append(entry)
	_io_read_keys[key] = true
	_io_enq += 1
	_io_main_read_ms += (Time.get_ticks_usec() - t0) / 1000.0
	return true

func _io_read_worker() -> void:
	# AC-0164: file read + decode on a worker. Fails closed: any open/decode
	# problem (missing file, torn write) leaves result empty and the
	# handoff falls back to generation — never a silent empty column.
	var tid = io_pool.get_caller_task_id()
	var entry = _io_slots.get(tid)
	var ns := 0
	while entry == null and ns < 200:
		OS.delay_msec(1)
		entry = _io_slots.get(tid)
		ns += 1
	if entry == null:
		return
	var t0 := Time.get_ticks_usec()
	var res := {}
	# AC-0175: region-first blob read (shared with the main-thread disk-first
	# load); legacy per-column fallback inside. A torn read (a main-thread
	# commit racing the region file) fails the MD5 in decode_column ->
	# fail-closed generation + edits re-apply.
	var bytes := ChunkIO.read_column_bytes(int(entry["slot"]), int(entry["cx"]), int(entry["cz"]))
	if not bytes.is_empty():
		var r = ChunkIO.decode_column(bytes, int(entry["seed"]), int(entry["height"]))
		if typeof(r) == TYPE_DICTIONARY and not (r as Dictionary).is_empty():
			res = r
	entry["result"] = res
	entry["ms"] = (Time.get_ticks_usec() - t0) / 1000.0

# AC-0175: main-thread region commit (called from io_poll when the worker's
# encode lands). The region file is shared by 1024 columns, so every file
# mutation is serialized here: table entry updated in place, the blob
# overwrites its slot when it fits or appends at the end otherwise. A
# compacting region defers the save (re-queued) until the rename lands.
func _io_write_commit(e: Dictionary) -> void:
	var slot := int(e["slot"])
	var cx := int(e["cx"])
	var cz := int(e["cz"])
	var blob: PackedByteArray = e.get("blob", PackedByteArray())
	if blob.is_empty():
		return
	var cell := ChunkIO.region_cell(slot, cx, cz)
	var path: String = cell["path"]
	if _io_compacting.has(path):
		# The region is mid-compaction: re-queue (the entry still owns the
		# snapshot; _io_write_enqueue re-adds the dedup key).
		_save_queue.append({
			"slot": slot,
			"cx": cx,
			"cz": cz,
			"data": e["data"],
			"fl": e["fl"],
			"light": e.get("light", {}),
			"gen_mask": int(e.get("gen_mask", 0xFFFFFF)),
		})
		return
	ChunkIO.ensure_dir(slot)
	if not FileAccess.file_exists(path):
		var nf := FileAccess.open(path, FileAccess.WRITE)
		if nf == null:
			return
		nf.store_buffer(ChunkIO.region_new())
		nf.close()
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	if f == null:
		return
	var head := f.get_buffer(ChunkIO.REGION_HEAD_SIZE)
	var t := ChunkIO.region_table(head)
	if t.is_empty():
		f.close()
		push_warning("AC-0175: corrupt region %s - the column save is dropped (fail closed)" % path)
		return
	var i := int(cell["idx"])
	var off := int(t["offsets"][i])
	var sz := int(t["sizes"][i])
	var fsize: int = f.get_length()
	var appended := false
	if off > 0 and blob.size() <= sz:
		# Overwrite the slot in place (a smaller blob leaves an unreferenced
		# tail - garbage for the next compaction).
		f.seek(off)
		f.store_buffer(blob)
	else:
		appended = true
		off = fsize
		f.seek(fsize)
		f.store_buffer(blob)
	# The 8-byte table entry (offset + size, LE).
	var ent := PackedByteArray()
	ent.resize(8)
	ent[0] = off & 255
	ent[1] = (off >> 8) & 255
	ent[2] = (off >> 16) & 255
	ent[3] = (off >> 24) & 255
	ent[4] = blob.size() & 255
	ent[5] = (blob.size() >> 8) & 255
	ent[6] = (blob.size() >> 16) & 255
	ent[7] = (blob.size() >> 24) & 255
	f.seek(12 + i * 8)
	f.store_buffer(ent)
	# Used bytes after this commit (this entry now contributes blob.size()).
	var used := 0
	for k in range(ChunkIO.REGION_ENTRIES):
		if k == i:
			used += blob.size()
		elif int(t["offsets"][k]) > 0:
			used += int(t["sizes"][k])
	f.close()
	var new_size: int = fsize + (blob.size() if appended else 0)
	# Compaction threshold: garbage past 4 MB AND less than half the file is
	# live -> rebuild (worker) + atomic rename.
	if new_size - ChunkIO.REGION_HEAD_SIZE - used > 4194304 and used * 2 < new_size - ChunkIO.REGION_HEAD_SIZE:
		_io_compact_enqueue(slot, int(cell["rx"]), int(cell["rz"]))

# AC-0175: enqueue a full-region compaction on the io pool. The worker
# re-packs the file to <path>.compact; io_poll renames it into place.
func _io_compact_enqueue(slot: int, rx: int, rz: int) -> void:
	var path := ChunkIO.region_for(slot, rx, rz)
	if _io_compacting.has(path):
		return
	_io_compacting[path] = Time.get_ticks_msec()
	var entry := {"path": path}
	var tid = io_pool.add_task(_io_compact_worker, false)
	entry["tid"] = tid
	_io_slots[tid] = entry
	_io_compact_inflight.append(entry)
	_io_compact_n += 1

func _io_compact_worker() -> void:
	var tid = io_pool.get_caller_task_id()
	var entry = _io_slots.get(tid)
	var ns := 0
	while entry == null and ns < 200:
		OS.delay_msec(1)
		entry = _io_slots.get(tid)
		ns += 1
	if entry == null:
		return
	var path: String = entry["path"]
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var bytes := f.get_buffer(f.get_length())
	f.close()
	var compact := ChunkIO.region_compact(bytes)
	if compact.is_empty():
		return
	var tf := FileAccess.open(path + ".compact", FileAccess.WRITE)
	if tf == null:
		return
	tf.store_buffer(compact)
	tf.close()

func io_poll() -> void:
	if _io_read_inflight.is_empty() and _io_write_inflight.is_empty() and _io_compact_inflight.is_empty():
		return
	var i := 0
	while i < _io_read_inflight.size():
		var e: Dictionary = _io_read_inflight[i]
		if io_pool.is_task_completed(int(e["tid"])):
			_io_read_inflight.remove_at(i)
			_io_slots.erase(int(e["tid"]))
			_io_read_keys.erase(e["key"])
			_io_read_handoff(e)
			continue
		i += 1
	i = 0
	var committed := 0
	while i < _io_write_inflight.size():
		var w: Dictionary = _io_write_inflight[i]
		if io_pool.is_task_completed(int(w["tid"])):
			# AC-0175: region commits touch a shared file on the main
			# thread - cap them per frame (a load-flush drains 16 saves a
			# frame; the rest wait one frame, their encode is done).
			if committed >= 4:
				i += 1
				continue
			committed += 1
			_io_write_inflight.remove_at(i)
			_io_slots.erase(int(w["tid"]))
			_io_write_keys.erase(w["key"])
			_io_write_commit(w)
			continue
		i += 1
	# AC-0175: compaction completion -> atomic rename + re-queue is free
	# (deferred saves retry on the next drain).
	i = 0
	while i < _io_compact_inflight.size():
		var c: Dictionary = _io_compact_inflight[i]
		var path: String = c["path"]
		if io_pool.is_task_completed(int(c["tid"])):
			_io_compact_inflight.remove_at(i)
			_io_slots.erase(int(c["tid"]))
			var abs_new := ProjectSettings.globalize_path(path + ".compact")
			var abs_old := ProjectSettings.globalize_path(path)
			# Worker produced no tmp (open/compact failure) -> the original
			# file is untouched; just clear the marker.
			if FileAccess.file_exists(abs_new):
				DirAccess.rename_absolute(abs_new, abs_old)
			_io_compacting.erase(path)
			continue
		# Stale guard: a worker that never lands (crash) must not wedge the
		# region's saves forever.
		if Time.get_ticks_msec() - int(_io_compacting.get(path, 0)) > 30000:
			_io_compact_inflight.remove_at(i)
			_io_slots.erase(int(c["tid"]))
			_io_compacting.erase(path)
			push_warning("AC-0175: region compaction for %s did not land in 30 s - stale" % path)
			continue
		i += 1

func _io_read_handoff(e: Dictionary) -> void:
	# AC-0164: main-thread handoff (the AC-0082 pattern). Provenance is
	# marked when the data LANDS. A failed decode with an empty column
	# falls back to threadgen (fail closed, column still materializes).
	var key: String = e["key"]
	var c = chunks.get(key)
	if c == null:
		_io_drops += 1
		return
	if not c.data.is_empty():
		_io_drops += 1
		return
	var res = e.get("result", {})
	var ok := typeof(res) == TYPE_DICTIONARY and not (res as Dictionary).is_empty()
	if not ok:
		_io_fails += 1
		threadgen_enqueue(int(e["cx"]), int(e["cz"]), key, int(c.get_instance_id()), false, int(c.col_gen))
		return
	_land_column(c, res)  # AC-0203 recenter fix: v4 slabs direct, v1-v3 flat
	c.saved_light = _saved_light_from_res(res.get("light", {}), int(e["cx"]), int(e["cz"]))
	disk_reads += 1
	disk_read_ms += float(e.get("ms", 0.0))
	chunk_origin[key] = "disk"
	if bool(e.get("apply_edits", false)):
		_apply_edits_to_chunk(c)

func surface_top(x: int, z: int) -> int:
	for y in range(Data.HEIGHT - 1, -1, -1):
		var b := get_block(x, y, z)
		if b != 0:
			var info = Data.block(b)
			if info.solid:
				return y
	return 0

# AC-0119 (AC-0263): the boot-time sync gen of the spawn chunk is GONE —
# the surface top is the ANALYTIC heightmap (the spawn plateau is flat at
# SPAWN_H by design: terrain_height == surface top there), and the startup
# burst delivers the ground data (collision) before the player lands.
func spawn_point() -> Vector3:
	var top := WorldGen.terrain_height(WorldGen.SPAWN_X, WorldGen.SPAWN_Z, Game.world_seed)
	return Vector3(WorldGen.SPAWN_X + 0.5, float(top) + 1.0, WorldGen.SPAWN_Z + 0.5)

# AC-0213: flat-column cache for light_at (key -> [data_gen, PackedByteArray]).
# Steady state (no edits) re-materializes nothing; capped so the cache
# cannot outlive the chunks it describes.
var _lightflat: Dictionary = {}

func light_at(x: int, y: int, z: int) -> Dictionary:
	var r := 8
	var mn := Vector3i(x - r, maxi(y - r, 0), z - r)
	var mx := Vector3i(x + r, mini(y + r, Data.HEIGHT - 1), z + r)
	if _lightflat.size() > 8:
		_lightflat.clear()
	var res: Dictionary = Lighting.compute_light_split({"min": mn, "max": mx}, self, _lightflat)
	var c := Vector3i(x, y, z)
	return {"sky": int(res.sky.get(c, 0)), "block": int(res.block.get(c, 0)), "eff": int(res.eff.get(c, 0))}

func mesh_info() -> Array:
	var out := []
	for key in chunks:
		var c: Node3D = chunks[key]
		var e := {"pos": [int(c.position.x), int(c.position.z)], "built": c.mesh_built}
		var slot_tot := [0, 0, 0, 0]
		var fslot_tot := [0, 0, 0, 0]
		var aabb = null
		var faabb = null
		# AC-0245: post mesh-split - the opaque slot lives on the opaque
		# mesh instance, the fluid slots (1..3) on the fluid mesh instance.
		for s in c.slabs:
			var mi = s.mesh_instance
			if mi and mi.mesh:
				var m: ArrayMesh = mi.mesh
				var ab = m.get_aabb()
				aabb = ab if aabb == null else aabb.merge(ab)
				var sidx: PackedInt32Array = s.sidx
				if sidx[0] >= 0:
					var arrs = m.surface_get_arrays(sidx[0])
					slot_tot[0] += (arrs[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			if s.fluid_instance != null and s.fluid_instance.mesh != null:
				var fm: ArrayMesh = s.fluid_instance.mesh
				var fab = fm.get_aabb()
				faabb = fab if faabb == null else faabb.merge(fab)
				var fsi: PackedInt32Array = s.sidx
				for si in range(1, fsi.size()):
					if fsi[si] >= 0:
						var farrs = fm.surface_get_arrays(fsi[si])
						fslot_tot[si] += (farrs[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		if aabb != null:
			e["aabb"] = [aabb.position, aabb.size]
			var vc := []
			for t in slot_tot:
				if t > 0:
					vc.append(t)
			e["verts"] = vc
		if faabb != null:
			e["faabb"] = [faabb.position, faabb.size]
			var fvc := []
			for t in fslot_tot:
				if t > 0:
					fvc.append(t)
			e["fverts"] = fvc
		out.append(e)
	return out

func spawn_drop(id: int, pos: Vector3) -> void:
	if Game.drops == null:
		return
	if Game.drops.get_child_count() >= 80:
		return
	var d: Node3D = DropScript.new()
	d.id = id
	d.position = pos
	Game.drops.add_child(d)


# --- AC-0040 bouncy-banana (the fall roll + the RigidBody3D spawn) --------

# The per-frame roll: every 0.5 s, each hanging banana within 10 blocks of
# the player has a 6% chance to come loose — the B_BANANA cell is cleared
# (remesh + light) and a RigidBody3D (entities/banana.gd) bounces from that
# point until rest, then the drop-magnet pickup delivers item 126.
func _banana_tick(dt: float) -> void:
	if Game.mode != "play" or Game.player == null or _banana_fruits.is_empty():
		return
	_banana_roll_t += dt
	if _banana_roll_t < 0.5:
		return
	_banana_roll_t = 0.0
	var ppos: Vector3 = Game.player.position + Vector3(0.0, 1.0, 0.0)
	var pluck: Array = []
	for k in _banana_fruits:
		var parts: PackedStringArray = String(k).split(",")
		if parts.size() != 3:
			continue
		var cpos := Vector3(float(int(parts[0])) + 0.5, float(int(parts[1])) + 0.5, float(int(parts[2])) + 0.5)
		if cpos.distance_to(ppos) > 10.0:
			continue
		if randf() < 0.06:
			pluck.append([int(parts[0]), int(parts[1]), int(parts[2]), k])
	for e in pluck:
		var x: int = int(e[0])
		var y: int = int(e[1])
		var z: int = int(e[2])
		# Re-verify: a concurrent mine may already have taken the fruit.
		if get_block(x, y, z) != WorldGen.B_BANANA:
			_banana_fruits.erase(e[3])
			continue
		_banana_fruits.erase(e[3])
		set_block(x, y, z, 0)
		_banana_plucked += 1
		spawn_banana(Vector3(float(x) + 0.5, float(y) + 0.5, float(z) + 0.5))


func spawn_banana(pos: Vector3) -> void:
	if Game.drops == null:
		return
	if Game.drops.get_child_count() >= 80:
		return
	var b: Node3D = BananaScript.new()
	b.position = pos
	Game.drops.add_child(b)
	_banana_spawned += 1


# Register planted fruit cells (chunk-local [lx, y, lz]) as world cells.
func _banana_register(cx: int, cz: int, fruits: Array) -> void:
	for f in fruits:
		var k := "%d,%d,%d" % [int(cx) * 16 + int(f[0]), int(f[1]), int(cz) * 16 + int(f[2])]
		_banana_fruits[k] = [int(cx), int(cz)]


# Saved chunks (disk landing) may already hold hanging bananas — scan the
# slab store (cheap palette prefilter; full 98 KB expand only on a hit).
func _banana_register_disk(c: Node3D, cx: int, cz: int) -> void:
	if c == null or c.data.is_empty():
		return
	var slabs: Array = c.data
	var has := false
	for s in slabs:
		if s == null:
			continue
		var n: int = int(s["n"])
		if n == 1:
			if int(s["p"][0]) == WorldGen.B_BANANA:
				has = true
				break
		var p: PackedByteArray = s["p"] if n >= 2 else s["i"]
		if p != null and p.has(WorldGen.B_BANANA):
			has = true
			break
	if not has:
		return
	# AC-0214: the 98 KB expand is C++ (ChunkIOPalette.slabs_flat).
	var flat: PackedByteArray = ChunkIO.io_cpp().slabs_flat(slabs)
	var found: Array = []
	var y := 0
	while y < Data.HEIGHT:
		var row := y << 8
		var i := 0
		while i < 256:
			if flat[row + i] == WorldGen.B_BANANA:
				found.append([i & 15, y, i >> 4])
			i += 1
		y += 1
	_banana_register(cx, cz, found)


# Eviction: drop the registry entries owned by the freed chunk.
func _banana_evict(key: String) -> void:
	var dead: Array = []
	for k in _banana_fruits:
		var v: Array = _banana_fruits[k]
		if _key(int(v[0]), int(v[1])) == key:
			dead.append(k)
	for k in dead:
		_banana_fruits.erase(k)


func is_fluid_id(id: int) -> bool:
	return id == 5 or id == 24

func fluid_replaceable(b: int) -> bool:
	if b == 0:
		return true
	var info = Data.block(b)
	if info == null:
		return false
	# Web: fluidReplaceable(b) = b===0 || (BLOCKS[b] && BLOCKS[b].cross). In the web,
	# cross marks only small cutout plants, and water/lava use `blend` — never cross —
	# so fluid cells are NOT replaceable by other fluid cells. That is exactly why
	# the natural sea is stable: a sea cell sees water below (no down-flow) and water
	# on all four sides (no sideways flow), so it never moves. Godot's Data reuses
	# cross=true for the translucent render pass, so fluid ids must be excluded here
	# to keep the simulation faithful and the sea from churning or draining.
	if is_fluid_id(b):
		return false
	return bool(info.get("cross", false)) and not bool(info.solid)

func set_fluid(x: int, y: int, z: int, id: int, lvl: int, create := false) -> void:
	if y < 0 or y >= Data.HEIGHT:
		return
	lvl = clampi(lvl, 0, 8)
	var cx := int(floorf(float(x) / 16.0))
	var cz := int(floorf(float(z) / 16.0))
	var c: Node3D
	if create:
		c = _chunk_data(cx, cz)
	else:
		c = chunks.get(_key(cx, cz))
	if c == null or c.data.is_empty():
		return
	var lx := x & 15
	var lz := z & 15
	var i := (y << 8) | (lz << 4) | lx
	if c.get_local(lx, y, lz) == id and c.fl_at(i) == lvl:
		return
	c.set_local(lx, y, lz, id)
	c.set_fl_at(i, lvl)
	_fluid_write = true
	if _fluidprobe:
		_fp_writes += 1
	_mark_fluid_around(cx, cz)
	_record_edit(cx, cz, i, id, lvl)
	if lvl > 0:
		fluid_wet[_key(cx, cz)] = true

func fluid_level(x: int, y: int, z: int) -> int:
	if y < 0 or y >= Data.HEIGHT:
		return 0
	var cx := int(floorf(float(x) / 16.0))
	var cz := int(floorf(float(z) / 16.0))
	var c = chunks.get(_key(cx, cz))
	if c == null or c.data.is_empty():
		return 0
	var i := (y << 8) | ((z & 15) << 4) | (x & 15)
	var v: int = c.fl_at(i)
	if v == 0:
		var b: int = c.get_at(i)
		if is_fluid_id(b):
			v = 8
	return v

func fluid_at(x: int, y: int, z: int) -> Array:
	return [get_block(x, y, z), fluid_level(x, y, z)]

func _nb_block(nc: Node3D, li: int, gx: int, gy: int, gz: int) -> int:
	if nc != null and not nc.data.is_empty():
		return nc.get_at(li)
	return 0


func _data_at_slab(c: Node3D, si: int, pos: int, cache: Dictionary) -> int:
	# AC-0203: slab-indexed data read (pos = within-slab cell), cached per
	# call site (the fluid tick caches all slabs of one column per tick).
	if si < 0:
		return 0
	if not cache.has(si):
		# AC-0214: the cached unpacked view per section — the cache stays
		# (per-tick Dictionary), the unpack itself is C++ (ChunkIOPalette
		# slab_flat — direct palette index ops, no per-cell GDScript work).
		cache[si] = ChunkIO.io_cpp().slab_flat(c.data[si])
	var dv: PackedByteArray = cache[si]
	return 0 if dv.is_empty() else int(dv[pos])

func tick_fluids() -> void:
	fluid_tick_count += 1  # AC-0158: fluid pass now runs inside the 20 Hz game tick
	if chunks.is_empty():
		return
	var cl: Array[Vector2i] = []
	if Game.player != null:
		# AC-0152: the tick region is the band-0 taxicab diamond (Bedrock
		# Simulate 4 = 41 chunks), not the fluid_tick_radius BLOCKS square.
		# The per-chunk `fluid_wet` gate below keeps the scan cheap (the
		# natural ocean is stationary fl=0 → zero work).
		for key in chunks:
			var c: Node3D = chunks[key]
			if int(c.face) > 1:
				continue
			if int(c.band) != 0:
				continue
			cl.append(Vector2i(int(c.cx), int(c.cz)))
		cl.sort()
	else:
		for key in chunks:
			var c: Node3D = chunks[key]
			cl.append(Vector2i(c.cx, c.cz))
	var t0 := Time.get_ticks_usec()
	var sig := "all"
	if Game.player != null and not cl.is_empty():
		sig = "%d:%d" % [cl.size(), int(floorf(float(cl[0].x) / 2.0)) * 4096 + int(floorf(float(cl[0].y) / 2.0))]
	if sig != _fluid_sig:
		_fluid_sig = sig
		_fluid_stable = 0
	if _fluid_write:
		_fluid_write = false
		_fluid_stable = 0
	else:
		_fluid_stable += 1
	if fluid_sleep and _fluid_stable >= 3:
		if tick_time:
			print("TICKMS ", (Time.get_ticks_usec() - t0) / 1000.0)
		if _fluidprobe:
			print("FLUIDPROBE slept=1 tick_ms=%.3f window=%d wet_cells=0 writes=%d stable=%d sig=%s" % [
				(Time.get_ticks_usec() - t0) / 1000.0, cl.size(), _fp_writes, _fluid_stable, sig])
		fluid_tick_samples.append((Time.get_ticks_usec() - t0) / 1000.0)
		return
	var hmax := Data.HEIGHT - 1
	var fp_wet := 0
	var fp_chunks := 0
	var fp_writes0 := _fp_writes
	for pos in cl:
		var c: Node3D = chunks.get(_key(pos.x, pos.y))
		if c == null or c.data.is_empty():
			continue
		var ck := _key(int(c.cx), int(c.cz))
		if not fluid_wet.has(ck):
			continue
		# AC-0203: sparse fluid scan — only fl slabs with nz>0 are
		# materialized and only their non-zero cells processed (the old full
		# scan skipped every fl==0 cell anyway; same cell set, same order,
		# same y window [1, hmax)). Natural (worldgen) water is a stationary
		# source (fl=0, MC-style): oceans/rivers generate stationary and do
		# not flow until block-updated — the natural ocean produces ZERO
		# writes and stays 100% stable. Player/bucket water arrives with an
		# explicit fl (8) and runs the full fall/spread pass below.
		var wet_cells := 0
		var cx: int = int(c.cx)
		var cz: int = int(c.cz)
		if _fluidprobe:
			fp_chunks += 1
		var wx0: int = cx * 16
		var wz0: int = cz * 16
		var ne: Node3D = chunks.get(_key(cx + 1, cz))
		var nw: Node3D = chunks.get(_key(cx - 1, cz))
		var ns: Node3D = chunks.get(_key(cx, cz + 1))
		var nn: Node3D = chunks.get(_key(cx, cz - 1))
		var dviews: Dictionary = {}
		var si := 0
		while si < ChunkScript.slab_n():
			var fslab = c.fl[si]
			if fslab != null and int(fslab["nz"]) > 0:
				# AC-0214: the wet-fluid slab unpack is C++ (ChunkIOPalette
				# slab_flat — the fluid tick no longer runs the GDScript
				# _slab_getbits per cell).
				var fflat: PackedByteArray = ChunkIO.io_cpp().slab_flat(fslab)
				var srow: int = si * 16
				var cell := 0
				while cell < 4096:
					var l: int = int(fflat[cell])
					if l != 0:
						var y: int = srow + (cell >> 8)
						if y >= 1 and y < hmax:
							var ry: int = cell >> 8
							var row: int = y << 8
							var i: int = row | (cell & 255)
							# user bug 2026-09-09 (flow regression): the per-slab cell
							# index is (ly<<8)|(lz<<4)|lx - the FULL 12-bit value.
							# The AC-0203 rewrite masked it to a byte (cell & 255),
							# which read the ly=0 row of every slab: above-slab water
							# saw deep stone, failed is_fluid_id, and its fl level was
							# zeroed every tick (the water could never move). The
							# below-chain (below_pos) had the same masked input.
							var b: int = _data_at_slab(c, si, cell, dviews)
							if not is_fluid_id(b):
								c.set_fl_at(i, 0)
							else:
								wet_cells += 1
								if _fluidprobe:
									fp_wet += 1
								var lx: int = cell & 15
								var lz: int = (cell >> 4) & 15
								var x := wx0 + lx
								var z := wz0 + lz
								var below_si: int = si if ry > 0 else si - 1
								var below_pos: int = cell - 256 if ry > 0 else (cell & 255) | (15 << 8)
								var below: int = _data_at_slab(c, below_si, below_pos, dviews)
								var br: int = below_pos >> 8
								var bb_si: int = below_si if br > 0 else below_si - 1
								var bb_pos: int = below_pos - 256 if br > 0 else (below_pos & 255) | (15 << 8)
								if b == 5 and below == 24:
									set_block(x, y - 1, z, 25 if l == 8 else 9, false)
								elif b == 24 and below == 5:
									set_block(x, y - 1, z, 9, false)
								else:
									var n_l: int = 7 if l == 8 else l - 1
									if fluid_replaceable(below):
										set_fluid(x, y - 1, z, b, 8, false)
										set_fluid(x, y, z, 0, 0, false)
									elif n_l > 0:
										var hold := false
										if is_fluid_id(below) and y >= 2 and fluid_replaceable(_data_at_slab(c, bb_si, bb_pos, dviews)):
											hold = true
										if not hold:
											for d in FLUID_DIRS:
												var ddx: int = int(d[0])
												var ddz: int = int(d[1])
												var nx := x + ddx
												var nz := z + ddz
												var nb: int
												if ddx == 1 and lx == 15:
													nb = _nb_block(ne, row | (lz << 4), nx, y, nz)
												elif ddx == -1 and lx == 0:
													nb = _nb_block(nw, row | (lz << 4) | 15, nx, y, nz)
												elif ddz == 1 and lz == 15:
													nb = _nb_block(ns, row | lx, nx, y, nz)
												elif ddz == -1 and lz == 0:
													nb = _nb_block(nn, row | 240 | lx, nx, y, nz)
												else:
													nb = _data_at_slab(c, si, (cell & 3840) | ((nz & 15) << 4) | (nx & 15), dviews)
												if fluid_replaceable(nb):
													set_fluid(nx, y, nz, b, n_l, false)
												elif nb == 5 and b == 24:
													set_block(nx, y, nz, 9, false)
												elif nb == 24 and b == 5:
													set_block(nx, y, nz, 9, false)
					cell += 1
			si += 1
		if wet_cells == 0:
			fluid_wet.erase(ck)
	if tick_time:
		print("TICKMS ", (Time.get_ticks_usec() - t0) / 1000.0)
	if _fluidprobe:
		print("FLUIDPROBE slept=0 tick_ms=%.3f window=%d chunks=%d wet_cells=%d writes=%d stable=%d sig=%s" % [
			(Time.get_ticks_usec() - t0) / 1000.0, cl.size(), fp_chunks, fp_wet, _fp_writes - fp_writes0, _fluid_stable, sig])
	fluid_tick_samples.append((Time.get_ticks_usec() - t0) / 1000.0)

# AC-0158: one random tick per 16x16x16 subchunk per game tick, over the
# band-0 diamond (Simulate 4 = 41 columns; band 1-3 / far 13-50 NEVER tick).
# Deterministic: the chosen cell is a pure function of (world seed, tick
# index, column, subchunk) via a splitmix64 chain, so two fresh runs
# produce identical sequences. The consumer is a counter/hook — crops and
# wheat do not exist in this codebase yet; future growth/redstone ticks
# attach in _apply_random_tick (world cell = cx*16+lx, sub*16+ly, cz*16+lz).
func _random_tick_pass(t: int) -> void:
	var cols: Array = []
	for key in chunks:
		var c: Node3D = chunks[key]
		if int(c.face) > 1 or int(c.band) != 0 or c.data.is_empty():
			continue
		cols.append([int(c.cx), int(c.cz)])
	if cols.is_empty():
		return
	var seq: PackedInt32Array = PackedInt32Array()
	if random_tick_log:
		cols.sort()
	for col in cols:
		var cx := int(col[0])
		var cz := int(col[1])
		var base: int = (cx + 4096) * 16384 + (cz + 4096)
		var hcol: int = _rt_colhash(t, cx, cz)
		for sub in SUBCHUNKS_PER_COLUMN:
			var h := _rt_mix64(hcol ^ (sub * 0x9E3779B9))
			var lx := h & 15
			var ly := (h >> 4) & 15
			var lz := (h >> 8) & 15
			_apply_random_tick(base, sub, lx, ly, lz, seq)
	if random_tick_log:
		random_tick_seq.append(seq)

func _apply_random_tick(base: int, sub: int, lx: int, ly: int, lz: int, seq: PackedInt32Array) -> void:
	random_tick_total += 1
	var sk: int = base * 24 + sub
	random_tick_map[sk] = int(random_tick_map.get(sk, 0)) + 1
	if random_tick_log:
		seq.append(base)
		seq.append(sub)
		seq.append(lx)
		seq.append(ly)
		seq.append(lz)
	# consumer hook: base encodes the column ((cx+4096)*16384+(cz+4096));
	# decode cz = base % 16384 - 4096, cx = (base - (cz+4096)) / 16384 - 4096;
	# world cell (cx*16+lx, sub*16+ly, cz*16+lz)

func _rt_mix64(x: int) -> int:
	x = x + _rt_c1
	x = ((x ^ (x >> 30)) * _rt_c2)
	x = ((x ^ (x >> 27)) * _rt_c3)
	return (x ^ (x >> 31))

func _rt_colhash(t: int, cx: int, cz: int) -> int:
	var h := Game.world_seed
	h = _rt_mix64(h + t)
	h = _rt_mix64(h ^ (cx * 0x85EBCA6B))
	h = _rt_mix64(h ^ (cz * 0xC2B2AE35))
	return h

# AC-0158: Bedrock region contracts (pure predicates — feature work
# deferred). in_mob_spawn_region = circle 24-44 (squared distance in the
# caller's units) ∪ the (n-1) taxi diamond of the Simulate radius.
func in_mob_spawn_circle(d2: int) -> bool:
	return d2 >= MOB_SPAWN_CIRCLE_MIN * MOB_SPAWN_CIRCLE_MIN and d2 <= MOB_SPAWN_CIRCLE_MAX * MOB_SPAWN_CIRCLE_MAX

func in_mob_spawn_diamond(dx: int, dz: int) -> bool:
	return absi(dx) + absi(dz) <= band0_r - 1

func in_mob_spawn_region(dx: int, dz: int) -> bool:
	return in_mob_spawn_diamond(dx, dz) or in_mob_spawn_circle(dx * dx + dz * dz)

func _fluid_near(x: int, y: int, z: int) -> bool:
	if is_fluid_id(get_block(x, y, z)) or fluid_level(x, y, z) > 0:
		return true
	if y > 0:
		if is_fluid_id(get_block(x, y - 1, z)) or fluid_level(x, y - 1, z) > 0:
			return true
	if y < Data.HEIGHT - 1:
		if is_fluid_id(get_block(x, y + 1, z)) or fluid_level(x, y + 1, z) > 0:
			return true
	if is_fluid_id(get_block(x + 1, y, z)) or fluid_level(x + 1, y, z) > 0:
		return true
	if is_fluid_id(get_block(x - 1, y, z)) or fluid_level(x - 1, y, z) > 0:
		return true
	if is_fluid_id(get_block(x, y, z + 1)) or fluid_level(x, y, z + 1) > 0:
		return true
	if is_fluid_id(get_block(x, y, z - 1)) or fluid_level(x, y, z - 1) > 0:
		return true
	return false

# --- AC-0143 M3: (face, cx, cz) keying API (non-home faces, data level) ---
# Non-home faces are sparse on-demand chunks: generated on first
# key_for_sphere_pos / get_block_key / set_block_key access, FIFO-capped,
# never meshed or lit in P1a (AC-0144+). Faces 0,1 (+Y halves) stay the
# flat home grid (legacy "%d,%d" key, flat grid, streaming unchanged).
const FACE_CELLS := 1024  # SphereMath.CELLS_PER_FACE
const FACE_CHUNK_CAP := 512  # max resident non-home chunks (FIFO)
var _face_order: Array = []  # FIFO of non-home chunk keys (eviction)

func _key_f(face: int, ccx: int, ccz: int) -> String:
	return "%d:%d:%d" % [face, ccx, ccz]

# Single position->key resolver for planet-surface positions (radius R).
# +Y halves (faces 0,1) = the flat home world (1m columns): face 0
# x = R*u (x in [0,R]), face 1 x = R*(u-1) (x in [-R,0]); z = R*(2v-1).
# Faces 2-11 resolve to their 1024-cell grid columns. Deterministic:
# same position + R => same key.
func key_for_sphere_pos(pos: Vector3, R: float) -> Dictionary:
	var r: Dictionary = SphereMath.world_to_face(pos, R)
	var face: int = int(r["face"])
	var u: float = float(r["u"])
	var v: float = float(r["v"])
	if face == 0 or face == 1:
		var fx: float = R * u if face == 0 else R * (u - 1.0)
		return {"face": face, "cx": int(roundf(fx)), "cz": int(roundf(R * (2.0 * v - 1.0)))}
	return {
		"face": face,
		"cx": clampi(int(floorf(u * float(FACE_CELLS))), 0, FACE_CELLS - 1),
		"cz": clampi(int(floorf(v * float(FACE_CELLS))), 0, FACE_CELLS - 1),
	}

func _ensure_face_chunk(face: int, colx: int, colz: int) -> Node3D:
	var ccx: int = int(floorf(float(colx) / 16.0))
	var ccz: int = int(floorf(float(colz) / 16.0))
	var key: String = _key_f(face, ccx, ccz)
	var c: Node3D = chunks.get(key)
	if c != null:
		return c
	c = _column_checkout()  # AC-0247: pooled column (fresh state) or a fresh node
	c.col_gen += 1  # AC-0247: the logical identity bump (instance_id is fixed per object)
	c.face = face
	c.cx = ccx
	c.cz = ccz
	c.position = Vector3(ccx * 16, 0, ccz * 16)
	c.collision_enabled = false
	c.init_slabs()
	add_child(c)
	# AC-0040: face-planet columns get the banana trees too (same shore
	# rule in face space — the generate_face coordinate/seed transform);
	# no fruit registration (the player can't reach face chunks, so there
	# is no fall/pickup — trees only, visually).
	var fdata: PackedByteArray = WorldGen.generate_face(face, ccx, ccz, Game.world_seed)
	WorldGen.apply_banana_trees(fdata, face * 64 + ccx, face * 64 + ccz, Game.world_seed ^ (face * 1000003), Data.HEIGHT)
	c.data_landed(fdata, PackedByteArray())
	chunks[key] = c
	_face_order.append(key)
	if _face_order.size() > FACE_CHUNK_CAP:
		var old: String = String(_face_order.pop_front())
		if chunks.has(old):
			var oc: Node3D = chunks[old]
			chunks.erase(old)
			_lod_free_all(oc, false)  # AC-0247: placeholders to the pool (a no-op — face chunks are data-only)
			if not _nofree:
				_col_checkin(oc)  # AC-0247: the column node is reset + pooled (the legacy oc.queue_free() is gone)
	return c

# Storage-level block access, any face. Face 0 (colx,colz) = flat 1m world
# columns (routes to the flat API); faces 1-11 (colx,colz) = 1024-cell grid
# columns (chunk = 16x16 cells). Non-home reads generate on first access
# (data level; AC-0119's never-generate rule covers the flat read path).
func get_block_key(face: int, colx: int, colz: int, y: int) -> int:
	if y < 0 or y >= Data.HEIGHT:
		return 0
	if face == 0 or face == 1:
		return get_block(colx, y, colz)
	var c: Node3D = _ensure_face_chunk(face, colx, colz)
	if c == null or c.data.is_empty():
		return 0
	return c.get_local(colx & 15, y, colz & 15)

func set_block_key(face: int, colx: int, colz: int, y: int, id: int) -> void:
	if y < 0 or y >= Data.HEIGHT:
		return
	if face == 0 or face == 1:
		set_block(colx, y, colz, id)
		return
	var c: Node3D = _ensure_face_chunk(face, colx, colz)
	if c == null or c.data.is_empty():
		return
	var fi: int = (y << 8) | ((colz & 15) << 4) | (colx & 15)
	c.set_local(colx & 15, y, colz & 15, id)
	c.set_fl_at(fi, 0)


# AC-0187: dedicated single-thread pool for the block-edit fast remesh.
# WorkerThreadPool is the engine singleton (not constructible), so the edit
# lane gets its own Thread + Mutex + Semaphore. The build starts the moment
# it is submitted — it never queues behind the shared pool's full builds
# (measured 460 ms behind 3 in-flight builds at R50 streaming). Completion
# is signalled per-entry (the worker sets entry["done"]); threadmesh_poll
# checks the flag for epool entries.
class EditPool:
	var _thread: Thread = null
	var _mutex := Mutex.new()
	var _wake := Semaphore.new()
	var _dl := Mutex.new()
	var _queue: Array = []
	var _stop := false
	func mark_done(entry: Dictionary, res: Dictionary) -> void:
		_dl.lock()
		entry["result"] = res
		entry["done"] = true
		entry["t_done"] = Time.get_ticks_usec()
		_dl.unlock()
	func start() -> void:
		_thread = Thread.new()
		_thread.start(_run)
	func submit(call: Callable) -> void:
		_mutex.lock()
		_queue.append(call)
		_mutex.unlock()
		_wake.post()
	func stop() -> void:
		if _thread == null:
			return
		_mutex.lock()
		_stop = true
		_queue.clear()
		_mutex.unlock()
		_wake.post()
		_thread.wait_to_finish()
		_thread = null
	func _run() -> void:
		while true:
			_mutex.lock()
			while _queue.is_empty() and not _stop:
				_mutex.unlock()
				_wake.wait()
				_mutex.lock()
			if _queue.is_empty():
				_mutex.unlock()
				if _stop:
					return
				continue
			var call: Callable = _queue.pop_front()
			_mutex.unlock()
			call.call()
