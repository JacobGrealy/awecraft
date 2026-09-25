extends Node3D

const ChunkScript = preload("res://world/chunk.gd")
const DropScript = preload("res://entities/drop.gd")
const BananaScript = preload("res://entities/banana.gd")  # AC-0040 bouncy-banana
const MobScript = preload("res://entities/mob.gd")  # AC-0037 mobs
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
# AC-0274: the per-frame dispatch cap for the loading window's build pass
# (the re-collect per skip keeps the order adaptive but costs a 2100-entry
# pool scan; capping the dispatches bounds the frame at ~60-100 ms so the
# poll/handoff (LOAD_TM_HANDOFF/frame) and the recenter queue walk run).
const LOAD_HSLAB_UNITS_PER_FRAME := 16
# AC-0274: the loading-window handoff TIME budget (replaces the fixed
# LOAD_TM_HANDOFF=6 count, which was sized for the first-wave face-block
# refresh (~70 ms/landing) but throttled steady-state landings (2-5 ms
# each) to 6/frame: at ~10 fps that is 64/s and a 900-slab load takes
# ~14 s of pure handoff waiting). Land handoffs until this budget is used;
# the first wave naturally lands 1-2/frame (the cost is the gate), the
# steady state lands dozens.
const LOAD_HO_BUDGET_MS := 100
# TG in-flight cap while loading (low-priority share = 3 of 6 pool threads;
# 24 deep = ~8 waves of queue, the pool never sees an empty queue).
# AC-0274: was 24 - a 24-deep gen queue on the shared 6-core
# WorkerThreadPool starved the 2 ms mesh tasks behind it (measured:
# mesh landings capped at ~43/s while gen held 24 in flight; the
# load's mesh phase froze for ~15 s). 8 keeps the gen wavefront ~1-2
# rings ahead of the mesh (the nbs gate defers until the diagonals
# land) while the mesh tasks get their pool share.
const LOAD_TG_CAP := 8
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

const DRAIN_MS_DEFAULT := 30
# AC-0340: the staged collision lane's per-frame time cap (the drain_budget_ms
# model — that one bounds the build lane). Measured at AC-0337: per-slab body
# derivation averages ~2.1 ms (24 slabs/column, worst slab 6.7 ms on the
# boundary walk), so the old fixed 2 columns/frame could carry 48 slabs ≈
# 100 ms in one frame. 8 ms ≈ 3–4 bodies/frame = 48% of a 60 fps frame; the
# excess re-queues as debt (never drops). AWECRAFT_COLLIDE_MS overrides
# (tuning knob for the A/B, the AWECRAFT_DRAIN_MS pattern).
const COLLIDE_DRAIN_BUDGET_MS := 8
const REC_SLICE_BUDGET_MS := 8
const REC_UNITS_PER_FRAME := 2048
# AC-0335: the drain is the ONLY scheduler and its pacing is the surviving
# wall-clock unit budget — LOW_WAVE_PACE_MS per unit (accumulated on the
# frame wall clock) + LOW_WAVE_FRAME_CAP units/frame (defined below, next
# to the low-attach machinery it paces). The old fast/slow
# DRAIN_UNIT_PACE_* / DRAIN_UNITS_FRAME_CAP governor is GONE (the
# unification kept the wall-clock pair — identical pace at 30 and 60 fps
# is what AC-0231's fps-independence constraint required). The loading
# window keeps its own LOAD_* per-frame budgets (one-shot spawn contract
# / AC-0178 pacing).
const DRAIN_DT_CLAMP_MS := 100.0       # clamp the wall-clock frame sample (pause/hitch)
# AC-0313: the AC-0283 P3 walk-regime constants (WALK_CROSS_PERIOD_MS,
# DRAIN_STARTUP_PASS_BUDGET_MS, DRAIN_DEFER_MAX_PER_FRAME) are GONE — the
# startup 3x3 completion pass and its regime were removed: no main-thread
# blocking build pass after the player is active. The drain is ALWAYS the
# wall-clock paced unit budget + drain_budget_ms time cap (the loading
# window keeps its own LOAD_* budgets; see _drain_build_queue).
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
#     1m columns; streaming/recenter byte-identical to pre-M3. AC-0306 grid
#     lock: the sphere mapping covers |x|,|z| <= pi*R/4 (W/2, W = pi*R/2 =
#     face_width(R) — one flat metre is one metre of arc; pre-AC-0306 it
#     covered |x|,|z| <= R). Face 0 = x >= 0, face 1 = x < 0.
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
# AC-0283 P3: band0_r (the sim distance) is the world-gen boundary AGAIN
# — the REAL band (taxi ≤ band0_r or the tier-0 set) is the only region
# that seeds the starlight engine, floods light, and builds full-res
# 1:1 (the tier-0 ball's columns first, in the dedicated section). The
# HALO band (band0_r, render_radius) is the 4x4x4 avg draw with the
# heightmap sky light (15 strictly above the terrain top, 0 at or below;
# no block light, no engine, never saved — AC-0287: the save filter makes
# this true again for the FAR (h-only) columns AC-0284b briefly persisted
# as the v6 bit-1 payload; they are now ephemeral and regenerate on load).
# band0_r still gates mob/fluid simulation (collision band 0, the data
# tier-1 priority square, mob spawn). Settings "sim_dist".
var band0_r := 4
# AC-0312: the BAND A/B boundary (taxi chunks) — the outer edge of the
# full-LOD draw tier (see _lod_tier_of). Live-read by the tier model;
# note_medium_start keeps it in sync with Settings (clamped above sim,
# at or below render) and re-stamps the queue.
var medium_start_r := 8
var band1_r := 96
var collision_enabled := true
var chunks := {}
var chunk_keys := {}
var edits := {}
# AC-0283 P2: the AweStarlight engine (gdext/src/starlight.cpp) live-light
# state — replaces the per-column re-flood + the 1-column/frame flush wave
# (light_dirty / light_pending / flush_active, removed here).
# AC-0283 P4: the AweLighting class is now TEST/REFERENCE only (the gold
# reference the starlighttest/brightslab/halo arms check the engine
# against); the worker's classic pull branch (a no-star/no-mask eff)
# stays LIVE for the edit-fallback full bake + the tex-refresh rebuild
# (last_eff carries no mask) + the star==null fallback — proven by the
# dispatch trace, so it was kept, not removed.
#   star         the engine (null in the fallback build — every star site
#                degrades to the legacy pull path)
#   star_owed    key -> true: a column whose light gate (all 24 sections
#                settled) has not been drained yet — the drain publishes
#                last_eff (eff_gen bumps iff the eff changed) and re-arms
#                the per-slab E2 wave (replacing the flush + _eff_landed)
#   star_remesh  key -> {si: true}: slabs whose settled light changed
#                (late landing / edit / E2) and need a re-bake — the
#                remesh lane drains these paced; each re-bake lands as a
#                settled (flush_slabs) attach
var star: Variant = null
var star_owed := {}
var star_remesh := {}
var _star_last_t := 0.0
var star_late_landings := 0
var star_lver_drops := 0
# AC-0283 P3: the halo lifecycle at recenter (the engine holds the REAL
# band only — taxi ≤ band0_r or the tier-0 set). A column crossing INTO
# the real band (halo -> real) seeds the engine from its current data
# (the promotion: one full flood per column); a crossing OUT (real ->
# halo) evicts it (free the nibbles — its draw is the 4x4 avg +
# heightmap sky now). AC-0346: the count is TOTAL over crossings — the
# far-side promotion (the owed full regen, whose landing does the flood;
# _star_halo_promote early-returns for far data) is counted at the
# crossing too.
var star_halo_promotes := 0
var star_halo_evicts := 0
var star_bake_probe: Variant = null
# AC-0286: promotion observability (harness-visible, the star_bake_probe
# style — pure counters, zero behavior change). The flight profile's
# acceptance: 1 engine re-seed + 1 accepted full-regen enqueue per
# promoted column per residency. The per-KEY dicts are cumulative over
# the node's life (a re-crossed column keeps its key) — the arms take
# deltas around each crossing; the entries are erased at column free
# (a freed-and-respawned column is a new residency, count restarts).
var star_seed_count: Dictionary = {}  # key -> whole-column seed_column calls
var star_seed_us: Dictionary = {}     # key -> cumulative us in seed_column
var promo_enq_count: Dictionary = {}  # key -> accepted promotion full-regen enqueues
var promo_land_count: Dictionary = {}  # key -> far->full (was_far) regen landings
var promo_land_ms: Dictionary = {}     # key -> tick-ms of the last was_far landing
# AC-0286: the late-landing ORIGIN split — star_late_landings stays the
# total; the regen-merge landing (_star_reseed_column) is the only hide
# caller and the promotion (was_far) never goes through it (it takes the
# retain-swap branch — the probe proves the split).
var star_late_landings_promo := 0
const STAR_STEP_BUDGET_MS := 3.0
const LOAD_STAR_STEP_BUDGET_MS := 30.0
const STAR_REMESH_KEYS_PER_FRAME := 2
const LOAD_STAR_REMESH_KEYS_PER_FRAME := 8
# AC-0286: the promotion burst's per-frame column cap (one slab each).
# Promotions are crossings (~1 per flight minute), so 3 covers any
# realistic overlap without adding more than 3 extra dispatch units.
const PROMO_BURST_COLS_PER_FRAME := 3
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
# AC-0287: the save-filter counters (the flysave arm's evidence).
# _save_skip_n = evicts the filter declined (outside the sim diamond and
# unedited, or far — the no-bloat proof); _save_far_n = evicts of a FAR
# column (the never-encoded class — 0 in every filtered run, >0 only under
# the AWECRAFT_SAVEALL=1 baseline A/B).
var _save_skip_n := 0
var _save_far_n := 0
# AC-0287: the AWECRAFT_SAVEALL=1 A/B seam, read lazily (the harness envs
# are exported by the launch command, never changed mid-run). 0 = the
# filter (product), 1 = pre-AC-0287 save-all (the flysave baseline run).
var _saveall_env := -1
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
# AC-0231 fps-tuning (AC-0335: the surviving pace is LOW_WAVE_PACE_MS —
# see the _drain_build_queue pacing-decision comment) — the chunk build
# pace is frame-rate independent.
var _drain_last_t := 0       # wall ms of the previous drain frame (dt sample)
var _drain_acc_ms := 0.0     # unit-pace accumulator (wall ms banked)
# AC-0217 + AC-0233/AC-0250: the pool/score debounce. The drain's scored
# picks (build / forward-lead / data) re-ran _collect_pool (up to
# PICK_POOL_CAP entries) + scoring every frame even when the player stands
# still and the world is idle. A pick is a pure function of (queue
# membership + eligibility, maxb, the recenter center, the
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
	# drain window + recenter center + sim radius) — the look no longer
	# affects the order at all (AC-0250 removed the look bias), so moving OR
	# turning within a column does not change the tier order and px/pz left
	# the key. A key hit means no rescan: the waiting parts are rewritten
	# only on a column cross (pcx/pcz), a sim-radius change, or a pool
	# change. (AC-0293: the spawn-fast term left the key with the burst.)
	return "%d_%d_%d_%d_%d" % [
		_pool_ver,
		maxb,
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

# AC-0331: the far-tier mesh FLOOR (world y). The sub-waterline geometry
# of the THREE FAR DRAW TIERS (band A full-LOD materialization + bands
# B/C avg) is REMOVED at the floor: the far ocean keeps its translucent
# water surface at Data.SEA (the waterline voxel stays) + the opaque cap
# face at the floor (no see-through from below — the cap is the -Y face
# of the first kept cell / the floor row), and the slabs entirely below
# it are never built or dispatched (the cost win: 7 of 24 low-lane slabs
# + the band-A mat build starts at slab 7). The REAL band (tier 0)
# NEVER floors — caves + sub-floor digging survive there.
# AC-0332: the value is a SETTING now — note_yfloor (next to the other
# two Settings band reads) derives it once: -1 when the toggle is off,
# else Data.SEA - n*16 for the 0..24 chunks-below-sea scale. This
# function is the single seam every emitter/probe reads; the initial
# state matches the shipped default (on, 0 = Data.SEA) and _ready
# re-derives from the live Settings (after the harness env preloads).
var yfloor_y := int(Data.SEA)

func _far_floor_y() -> int:
	return yfloor_y

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
# AC-0313: the AC-0263 Y-window (the windowed probe while the player
# moved) is GONE — the probe is always FULL (every slab counts). A column
# is built as a FULL 24-slab column (inside-out: taxi-major across
# columns, this Y-distance order within one — see _grid_score), so there
# is no window for passed columns to re-build and no windowed "nothing
# pending" to miscount as completion.
func _entry_best_pending(c: Node3D) -> int:
	if c == null or c.data.is_empty():
		return -1
	var pys := _player_slab()
	var sn: int = c.data.size()
	var tier := _lod_tier_of(int(c.cx) - last_pcx, int(c.cz) - last_pcz)
	# AC-0312: the low lane OWNS the draw bands 2/3 only — the real band
	# (the build lane) and band A (the materializing high lane) never owe
	# a low, and past the render edge nothing renders: a pending report
	# there would stall band_drained() (the probe's consumers used to
	# skip those chunks themselves).
	if tier <= 1 or tier >= 4:
		return -1
	for r in range(sn * 2):
		var dy: int
		if r == 0:
			dy = 0
		elif r % 2 == 1:
			dy = -(r + 1) / 2
		else:
			dy = r / 2
		var si := pys + dy
		# AC-0331: the far-tier mesh floor — a far column's slabs
		# ENTIRELY BELOW the floor are never built (the dispatch
		# prunes them, _low_pending_sis) — they must read as NOT
		# pending here, or the column never settles (this probe drives
		# the pick + band_drained + the probe cache).
		if c.far and si * 16 + 15 < _far_floor_y():
			continue
		# AC-0284b: a far column's slabs are all null BY REPRESENTATION —
		# every slab is still buildable (the emit reads the payload).
		if si < 0 or si >= sn or (c.data[si] == null and not c.far):
			continue
		if c.has_low_si(si):
			# a LOW slab is pending only when stale (edited after the low,
			# or built at a different band tier).
			if c.low_stamps.get(si, []) == c.stamp() and c.low_tiers.get(si, -1) == tier:
				continue
		elif int(c.low_failed.get(si, -1)) == int(c.data_gen):
			continue  # terminal all-air mark (sampled all-air at this data_gen)
		return si
	return -1

# AC-0262: single-slab pendingness (the probe's inner check for ONE si) —
# factored out so the probe cache can re-validate a cached si cheaply
# (~5 dict lookups) instead of re-running the 32-probe sweep.
func _low_slab_pending_at(c: Node3D, si: int, tier: int) -> bool:
	if si < 0 or si >= c.data.size() or (c.data[si] == null and not c.far):  # AC-0284b: a far column's null slabs are buildable (the payload is the data)
		return false
	# AC-0331: the far-tier mesh floor — slabs entirely below it are
	# never built on a far column (the dispatch pruning) — not pending
	# (the probe-cache re-validation + the demote flip path read this).
	if c.far and si * 16 + 15 < _far_floor_y():
		return false
	if c.has_low_si(si):
		# a LOW slab is pending only when stale (edited after the low,
		# or built at a different band tier).
		return not (c.low_stamps.get(si, []) == c.stamp() and c.low_tiers.get(si, -1) == tier)
	# terminal all-air mark (sampled all-air at this data_gen).
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
# fingerprint (an attach, a drop, an air mark) must erase the
# entry — every such site calls _low_probe_invalidate.
var _low_probe_cache: Dictionary = {}

func _low_probe_invalidate(c: Node3D) -> void:
	_low_probe_cache.erase(_key(int(c.cx), int(c.cz)))

func _entry_best_pending_cached(c: Node3D) -> int:
	var key := _key(int(c.cx), int(c.cz))
	# AC-0313: the AC-0263 window bit (fingerprint element 5) is gone with
	# the Y-window — the probe is always full, 4 fingerprint parts.
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
	if c == null or c.data.is_empty():
		return -1
	# AC-0312: an UNMATERIALIZED band-A far column is owed — its first
	# slab dispatch is the materialization (the worker runs the skip=1
	# fill and builds the slab on it). The fill lands the full column,
	# so any slab answers; the player-slab clamp matches the bake order.
	# (top is -1 while unmaterialized, so the early-out below would
	# read "complete" — the special case precedes it.)
	if c.far and not c.far_mat \
			and _lod_tier_of(int(c.cx) - last_pcx, int(c.cz) - last_pcz) == 1:
		return clampi(_player_slab(), 0, c.data.size() - 1)
	if int(c.top) < 0:
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
	# AC-0313: the AC-0263 window bit (fingerprint element 5) is gone with
	# the Y-window — the probe is always full, 4 fingerprint parts.
	var f: Array = [int(c.data_gen), int(c.fl_gen), _player_slab(),
		_lod_tier_of(int(c.cx) - last_pcx, int(c.cz) - last_pcz)]
	var ck = _hslab_probe_cache.get(key, null)
	if ck != null:
		var cf: Array = ck["f"]
		if cf[0] == f[0] and cf[1] == f[1] and cf[2] == f[2] and cf[3] == f[3]:
			var si0: int = int(ck["si"])
			if si0 < 0:
				return -1
			if si0 < c.data.size():
				if c.data[si0] != null \
						and int(c.high_stamps.get(si0, -1)) != int(c.data_gen):
					return si0  # still pending -> still the best (see above)
				# AC-0312: the unmaterialized band-A slab (null by
				# representation) stays owed until the materialization
				# lands (the fingerprint already pins tier + data_gen).
				if c.far and not c.far_mat and int(f[3]) == 1:
					return si0
		_hslab_probe_cache.erase(key)
	if _hslab_probe_cache.size() > 8000:
		_hslab_probe_cache.clear()  # eviction safety (bounded working set)
	var si := _hslab_best_pending(c)
	_hslab_probe_cache[key] = {"si": si, "f": f}
	return si

# AC-0257 (AC-0313): the BAKE SCORE — the order the drain picks and the
# low lanes walk: INSIDE-OUT (the AC-0233/AC-0250 (layer, taxi) layer-
# major order is gone — passed columns were re-fanned as the player's Y
# moved and the deep layers of the inner rings waited behind the shallow
# layers of the far rings). Now the COLUMNS are radial: the innermost
# unbuilt column first (taxi-major — a pure function of the live recenter
# anchor, no timer/mode), and WITHIN a column the slabs keep the Y-
# distance order from the player's slab (player slab first, then ±1, ±2,
# ... — _layer_rank_of, max 47 < 10000 so it breaks taxi ties only).
# Every column in the real band is built FULL (24 slabs), so a built
# column is complete and never re-dispatched — no window rework. The
# load-target and tier-0 score prefixes are gone with the Y-window /
# tier-0 set: the 9-chunk load target (Chebyshev ≤ 1) IS the innermost
# taxi, and the real band (taxi ≤ band0_r) outranks the halo on taxi.
# The live layer is derived from the chunk's pending state per pick (a
# completed slab moves the best slab outward; there is no stamp to go
# stale).
func _grid_score(e: Dictionary) -> float:
	var dx := int(e["cx"]) - last_pcx
	var dz := int(e["cz"]) - last_pcz
	var layer := 0
	var c = chunks.get(e["key"])
	# AC-0335: the pending probe is per-RING (the ring decides the work) —
	# rings 0/1 (real band + band A, the high slab build) probe the HIGH
	# completion stamps (an unmaterialized band-A column's first slab is
	# the mat entry — the hslab probe carries that special case), so band
	# A now gets a real layer rank instead of a constant 0; rings 2/3
	# (band B/C, the avg emit) probe the low state (the AC-0262
	# cached probe).
	var in_high := c != null and _lod_tier_of(dx, dz) <= 1
	if c != null and not c.data.is_empty():
		var si: int = _hslab_best_pending_cached(c) if in_high else _entry_best_pending_cached(c)
		if si >= 0:
			layer = _layer_rank_of(si)
	var s := float(absi(dx) + absi(dz)) * 10000.0 + float(layer)
	return s

# AC-0257: the AC-0233 _tier_score ((sim-tier, taxi) pick order) is gone —
# replaced by _grid_score (the AC-0313 (taxi, layer) inside-out order).
# _tier_of / the tier stamps survive: the tier-2 high order gate (build
# handoff) and the low task's dispatch-tier check still classify by sim
# tier.

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
# band tier, so re-stamp the queue's stamps (the live tier is recomputed
# at probe time, so the boundary itself needs no stamp — the kick covers
# the ordering).
func note_medium_start() -> void:
	medium_start_r = maxi(0, int(Settings.values.get("medium_start", 8)))
	_rescore_kick()
	_pool_touch()  # AC-0335: the tier 1<->2 edge re-pends/completes slab work on both lanes — the pick cache must re-scan

# AC-0332: the far-tier mesh FLOOR became a setting (AC-0331's kernel
# seam). The derivation happens HERE, once, next to the other two
# Settings band reads (note_medium_start / apply_low_start): y_floor =
# -1 when the toggle is off, else Data.SEA - n*16 for the plain 0..24
# chunks-below-sea scale (no sentinel in the setting — the -1 is an
# INTERNAL sentinel produced only by the toggle; nothing in the 0..24
# range can yield it). _far_floor_y() returns the derived value. Called
# from _ready (the boot derive, AFTER the AWECRAFT_YFLOOR /
# AWECRAFT_YFLOOR_ENABLED env preloads land in Settings.values) and from
# Settings.apply_yfloor (a mid-session change — the Developer-tab row /
# set_value apply step).
func note_yfloor() -> void:
	var en := bool(Settings.values.get("yfloor_enabled", true))
	var n := clampi(int(Settings.values.get("yfloor_chunks_below_sea", 0)), 0, Settings.YFLOOR_MAX)
	var yf := -1 if not en else int(Data.SEA) - n * 16
	if yf == yfloor_y:
		return
	yfloor_y = yf
	# AC-0332: the cache staleness a floor change owes (the AC-0331
	# caveat): c.far_eff is floor-aware and must not outlive the change;
	# a materialized band-A column re-opens its far_mat mark so the high
	# lane OWES the re-materialization at the new floor (it rides the
	# normal drain — the boot/dev-knob contract: new columns build at the
	# new floor, existing ones converge as they demote and re-mesh; the
	# live re-floor storm that re-emits the whole far field at once is
	# DEFERRED, the follow-up designs both directions against measured
	# churn). The probe caches must go with the mark — a cached
	# "complete" verdict (served without re-validation) would keep the
	# column settled forever. Band B/C lows are untouched here (their
	# stamps did not move — they converge through the normal re-lower).
	for c in chunks.values():
		if not c.far:
			continue
		c.far_eff = {}
		if c.far_mat:
			c.far_mat = false
			_hslab_probe_invalidate(c)
			_low_probe_invalidate(c)

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
# consumer). AC-0335: ONE scheduler — the drain's steady pass dispatches
# every ring's work in the (taxi, layer) order (_dispatch_column_work:
# rings 0/1 = the high slab build, 2/3 = the avg emit below); a
# low-holding column entering the real band is simply the next column
# whose ring changed. AC-0336: the (off) fog wave, the in-r pre-low lane,
# and the WAVE 3 idle catch-up are GONE — the far fill is the drain's
# ring-2/3 dispatch, paced by ONE wall-clock unit budget.
# The per-slab avg emit runs on the TM WORKER POOL (the C++ low_emit_avg
# on a value-copied slab column: ZERO generation on the main thread).
# The main thread only dispatches (a ~20 KB slab copy + task enqueue)
# and, when the result lands, does the scene-tree attach + the per-slab
# bookkeeping (the _low_handoff); a slab whose DATA is null has nothing
# to emit — its air bookkeeping runs inline (_low_air_slab).
# TEXTURE MAPPING (fix3): blocks WITH a merged-atlas strip (solid,
# non-cutout) use REPEATING UVs — 31px per world block, the texture
# repeats 4x across each 4-block quad (the qwrite_merged convention —
# NOT stretched, and the 512x128 strip always covers the span); blocks
# WITHOUT a strip (non-solid/cross/cutout: water, leaves, flowers,
# torch, lava, banana) sample exactly ONE 32px tile (31px span) from the
# original atlas rect — the high mesh's plain-branch convention
# (mesh.cpp) — because a repeating span from a plain rect walks 3+ tiles
# past the block's own tile into its atlas neighbors (the "wrong texture
# mapping" the user saw on the far leaves).
# KEEP RULES: never downgrade built high at its Y to low (keep high until
# freed per cand_since >= 2 after queue work); low only for never-built
# slabs. low_downgrade_n must stay 0.
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
# AC-0312/AC-0335: the far fill is data-limited, not build-limited — the
# wall-clock pace below keeps up with the TG data landings (~33/s) at
# any frame rate (AC-0231 fps-independence: the same pace at 30 and
# 60 fps). LOW_WAVE_PACE_MS is the drain's unit pace (one unit = one
# dispatch); LOW_WAVE_FRAME_CAP the per-frame catch-up cap.
const LOW_WAVE_PACE_MS := 3.5      # one dispatch unit per 3.5 ms wall clock (~36 units/s,
                                    # just above the ~33/s TG data-landing rate)
const LOW_WAVE_FRAME_CAP := 8      # per-frame catch-up cap (a stall never turns into a
                                    # frame-killing catch-up)
const LOW_TASK_CAP := 64           # AC-0236 part 2 / AC-0250: max in-flight low EMIT
                                   # tasks (64 x ~20 KB slab copies = ~1.3 MB; a
                                   # saturated pool leaves the slab PENDING — the
                                   # in-r pass or the far wave re-picks it next frame;
                                   # AC-0250 removed the sync main-thread fallback)
const LOW_POLL_BUDGET_MS := 4.0    # AC-0236 part 2: the per-frame wall-clock cap on
                                   # low HANDOFFS (the attach cost, ~0.2 ms each)
                                   # whole circle+ring fits; a capped scan leaves the
                                   # gate CLOSED rather than proving drained)
# AC-0261 (AC-0283 P3): the med/low split is RETIRED from the draw tier —
# the halo band (band0_r, render_radius) is all 4x4x4 + heightmap sky
# (see _lod_tier_of). low_start_r stays for settings/harness compat
# (recomputed by apply_low_start; it no longer selects a draw tier).
var low_start_r := 27
var _low_tl: Dictionary = {}      # id*256+fi -> Vector2 (the tile top-left in the ms canvas)
var _drain_units_last := 0        # units the last _drain_build_queue dispatched (the r16 arm's idle-wait predicate)
var low_built_n := 0              # per-slab textured-low builds (cumulative)
var low_rebuilds_n := 0           # per-slab stale (edited) low rebuilds
var low_upgrades_n := 0           # high landings that replaced a placeholder (the catch-up)
var low_downgrade_n := 0          # MUST stay 0 (keep-high — high never downgrades to low)
# the max slab-local textured-low AABB height ever built (<= 16 by
# construction: each low mesh is ONE slab, slab-local 0..16).
var low_max_h := 0.0
# AC-0236 part 2: the low-lane threading (the EMIT rides the TM pool via
# the C++ AweMesh.low_emit; the node attach stays on the main thread).
# low_enqueue_n = slabs dispatched to a worker; low_emit_cpp = C++ emits
# completed on the pool; low_handoff_n = main-thread attaches;
# low_drop_stale_n = dropped results (data changed mid-flight / chunk
# gone — the slab is still PENDING in the chunk state, so the drain's
# steady pass re-picks it next frame — no re-queue logic needed);
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
# bake (P3) only orders them.
# AC-0336: the (off) fog wave is GONE with its flag — FOG_WAVE_ON was
# const false and every _fog_ensure_slab caller was gated by it, so
# nothing ever fed the fog_slabs bookkeeping in the shipped path. The
# pre-baked 16x16x16 fog box, its MultiMesh instance pool, and the cap
# reuse are gone with it.
# =====================================================================

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
# columns — the fog-box MM pool is gone with the dormant fog wave,
# AC-0336). Memory-warming ONLY: nothing visible differs; grow-on-demand
# stays the safety net past the prewarm.
# ============================================================================
const POOL_PREWARM_RINGS := 2   # AC-0248: ~1-2 rings of columns (the ticket)
# AC-0248: the floor sizes — a tiny-radius run (or a radius whose ring
# target is smaller) still keeps the AC-0247 warm minimum.
const POOL_MI_MIN := 32
const POOL_COL_MIN := 16

var _mi_pool: Array = []     # pooled MeshInstance3D (high + low slab instances)
var _col_pool: Array = []    # pooled column nodes (detached, fresh state)
# AC-0248: the POOL GROW COUNTERS — on-demand (fresh-allocation) checkouts,
# i.e. the checkouts the prewarm did not cover. This is the ticket's
# evidence: with the prewarm in place a sustained fly-forward shows ~0
# grows after the initial burst (steady state recycles — the r+2 evict
# check-in feeds the ring check-out); pre-AC-0248 the first burst grew
# everything.
var perf_pool_mi_grows_n := 0
var perf_pool_col_grows_n := 0
# AC-0248: the one-time prewarm cost (ready + every top-up, ms).
var perf_pool_prewarm_ms := 0.0
# AC-0248: the cached targets + the radius they were computed for — the
# recenter top-up check is three int compares in the steady state.
var _pool_target_r := -1
var _pool_target_mi := 0
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


# AC-0248: the (mi, col) pool targets for a render radius — POOL_
# PREWARM_RINGS recenter rings of columns + their slab demand (MI),
# floored by the AC-0247 minimums.
func _pool_targets_for(r: int) -> Array:
	var cols := maxi(POOL_PREWARM_RINGS * _pool_ring_cols(r), POOL_COL_MIN)
	return [
		maxi(cols * _pool_mi_per_col(), POOL_MI_MIN),
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
		_pool_target_col = int(t[1])
		_pool_target_r = render_radius
	if _mi_pool.size() >= _pool_target_mi \
			and _col_pool.size() >= _pool_target_col:
		return
	var t0 := Time.get_ticks_usec()
	while _mi_pool.size() < _pool_target_mi:
		_mi_pool.append(MeshInstance3D.new())
	while _col_pool.size() < _pool_target_col:
		_col_pool.append(ChunkScript.new())
	perf_pool_prewarm_ms += (Time.get_ticks_usec() - t0) / 1000.0
	# AC-0248: env-gated verification hook (AWECRAFT_POOL_DEBUG=1) — the
	# one-time prewarm cost at any radius (the r16 arm reports the R16
	# number in its RESULT; this prints the live one for interactive /
	# R50 runs).
	if OS.get_environment("AWECRAFT_POOL_DEBUG") == "1":
		print("POOLTOPUP r=%d mi=%d col=%d total_ms=%.1f" % [render_radius, _mi_pool.size(), _col_pool.size(), perf_pool_prewarm_ms])


# AC-0247 (the small fixed prewarm) -> AC-0248 (ring-sized): prewarm on
# World ready — the world starts at the default render radius and the
# first recenter tops up to the live radius (a new-world boot applies
# Settings.render_dist AFTER ready, then the spawn recenter runs).
func _pool_prewarm() -> void:
	_pool_top_up()


func pool_sizes() -> Dictionary:
	# AC-0248: the harness-readable pool depths (the "pool sizes at end"
	# of the r16 arm's pool evidence).
	return {"mi": _mi_pool.size(), "col": _col_pool.size()}


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
	# need the C++ emit side).
	mi.mesh = null
	if mi.get_parent() != null:
		mi.get_parent().remove_child(mi)
	_mi_pool.append(mi)


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
	# The streaming-out (r+2) / face-FIFO free path. The per-slab lows
	# were already handled by _lod_free_all before this runs; here the
	# remaining child kinds are handled: the HIGH slab MeshInstance3Ds
	# (mesh/fluid/flora) go to the MeshInstance3D pool, the out-of-scope
	# nodes (the StaticBody3D collision bodies + the OccluderInstance3D)
	# keep the legacy free.
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
# leak at exit.
func _pool_free_all() -> void:
	# AC-0338: the RESIDENT columns' off-tree slot MIs first — this
	# engine version does NOT release an off-tree node at exit that is
	# referenced only from a freed node's script state (measured: the
	# R16 census leaked 1104 slots + their meshes + RIDs at exit; a
	# minimal repro + the explicit-free fix in .scratch/AC-0338/
	# leak_test2.gd). Free them explicitly and clear the owning arrays
	# so the later tree teardown releases nothing dangling. (The pooled
	# MIs below already had this treatment since AC-0247 — the pool
	# teardown is what keeps them RID-clean at exit.)
	for key in chunks:
		var c: Node3D = chunks[key]
		if c == null or not is_instance_valid(c):
			continue
		for mi in c.low_instances:
			if mi != null and is_instance_valid(mi):
				mi.free()
		c.low_instances = []
	for mi in _mi_pool:
		if mi != null and is_instance_valid(mi):
			mi.free()
	_mi_pool = []
	for c in _col_pool:
		if c != null and is_instance_valid(c):
			c.free()
	_col_pool = []

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

# =====================================================================
# AC-0338 — the ring-level far batch (bands B/C draw batching)
# =====================================================================
# The far avg tiers used to draw one MeshInstance3D per column per slab
# (~16.7k scene-tree nodes / draw calls at the shipped render distance
# 50 — the AC-0338/AC-0345 converged census). The DRAW is now batched
# per RING SECTOR: one MeshInstance3D per (avg tier, world-space 1/32
# angle sector) wearing a merged ArrayMesh of every visible slab of
# that tier in that sector, in world coordinates (surface 0 = the
# opaque avg in the shared _lod_avg_mat(); surfaces 1/2 = the WATER
# EXCEPTION faces in the shared fluid materials — the same two-pass
# camera-side cull as the slot path). A DRAW change, not an emit
# change: the emitted geometry stays byte-identical (farab 1080/1080 +
# h_mismatch 0, halo, ladder and meshprobe are the proof) — the batch
# only re-packages the already-emitted arrays.
# The per-slab RECORD survives on the slot MeshInstance3Ds that
# c.low_instances already holds (the exact emit arrays + the
# visibility flag) — the slots just stop being scene-tree children
# (they were pooled before AC-0247 and pool exactly the same way
# now), so every harness read site (c.low_instances[i].visible/.mesh —
# the r16 far census, the ladder, the halo) keeps its exact semantics,
# and "at most one visible tier per slab" is still the slot's
# .visible flag.
# SECTORING (the merge-cost finding, measured — see the AC-0338
# results): a full-tier re-merge in GDScript is ~1.1 s at the R50
# converged scale (per-vertex translate + index rebase, ~218 ns/vert)
# on top of a ~350 ms add_surface_from_arrays engine floor that no
# caller-side C++ helper removes (the floor is the engine surface
# build). So each tier is split into RING_SECTORS world-space angle
# wedges and a rebuild touches ONE sector only (≤ ~40 ms at the R50
# sector scale, ~5 ms at R16). The sector partition is STATIC in
# world space (the chunk node sits at absolute (cx*16, cz*16) and is
# never repositioned — recenter only evicts/creates), so a recenter
# re-buckets nothing; the churn (the trailing-arc evicts + the
# leading-arc far fill) marks the affected sectors dirty and the
# coalesced step (one sector per frame, per-sector cooldown) re-merges
# them. Re-merge is whole-sector (the ArrayMesh API has no in-place
# surface append) — the paced cost of a recenter is a far-field
# re-draw over a few seconds, recorded in the results.
const RING_SECTORS := 32
const RING_REBUILD_GAP_MS := 250  # per-sector cooldown between re-merges
const RING_MIN_GAP_MS := 60       # global floor between any two sector re-merges

var _ring_mi: Array = []        # [(tier-2)*32+sec] -> MeshInstance3D (lazy)
var _ring_dirty: Array = []     # same index -> bool (membership changed)
var _ring_last_ms: Array = []   # same index -> wall ms of the last re-merge
var _ring_slab_n: Array = []    # same index -> merged slab count (census)
var _ring_cur := 0              # rotating scan pointer (fairness under churn)
var _ring_last_any_ms := 0
var _ring_water_mat: Material = null
var _ring_water_bf_mat: Material = null
var ring_rebuilds_n := 0
var ring_rebuild_ms := 0.0
var ring_rebuild_max_ms := 0.0

func _ring_ready() -> void:
	if _ring_mi.is_empty():
		for i in range(RING_SECTORS * 2):
			_ring_mi.append(null)
			_ring_dirty.append(false)
			_ring_last_ms.append(0)
			_ring_slab_n.append(0)

# The harness-readable ring census (the census50 arm + the results).
func ring_stats() -> Dictionary:
	_ring_ready()
	var mi_n := 0
	var slabs := 0
	for i in range(_ring_mi.size()):
		if _ring_mi[i] != null:
			mi_n += 1
		slabs += int(_ring_slab_n[i])
	return {
		"mi": mi_n,
		"sectors": RING_SECTORS,
		"slabs": slabs,
		"rebuilds": ring_rebuilds_n,
		"ms": ring_rebuild_ms,
		"max_ms": ring_rebuild_max_ms,
	}

# The sector of a column: its WORLD-space angle in 1/32-turn units.
# Static (the nodes never move) — a recenter re-buckets nothing.
func _ring_sector_of(cx: int, cz: int) -> int:
	if cx == 0 and cz == 0:
		return 0
	var a := fmod(atan2(float(cz), float(cx)) + PI, TAU)
	var s := int(a / (TAU / float(RING_SECTORS)))
	return s if s >= 0 and s < RING_SECTORS else 0

func _ring_mi_for(tier: int, sec: int) -> MeshInstance3D:
	var i := (tier - 2) * RING_SECTORS + sec
	if _ring_mi[i] == null:
		var mi := MeshInstance3D.new()
		mi.name = "ring_t%d_s%d" % [tier, sec]
		add_child(mi)
		_ring_mi[i] = mi
	return _ring_mi[i]

# Mark the column's sector dirty on BOTH avg tiers — the rebuild
# re-classifies every segment by the slab's stored tier stamp
# (c.low_tiers), so the double-mark is at worst one redundant re-merge
# (coalesced like everything else).
func _ring_dirty_column(c) -> void:
	_ring_ready()
	var sec := _ring_sector_of(int(c.cx), int(c.cz))
	for t in [2, 3]:
		_ring_dirty[(t - 2) * RING_SECTORS + sec] = true

# The shared ring water materials (the slot path's materials, shared
# per world): Data.fluid_anim(_bf)_mats[5] when the atlas pack built
# them, one cached fallback otherwise (the chunk _fluid_material
# shape — the no-atlas path).
func _ring_water_material() -> Material:
	var m = Data.fluid_anim_mats.get(5)
	if m != null:
		return m
	if _ring_water_mat == null:
		_ring_water_mat = _ring_fallback_fluid_mat()
	return _ring_water_mat

func _ring_water_bf_material() -> Material:
	var m = Data.fluid_anim_bf_mats.get(5)
	if m != null:
		return m
	if _ring_water_bf_mat == null:
		_ring_water_bf_mat = _ring_fallback_fluid_mat()
	return _ring_water_bf_mat

func _ring_fallback_fluid_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.cull_mode = BaseMaterial3D.CULL_DISABLED  # AC-0245: boundary faces from all sides
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(1, 1, 1, 0.62)
	m.roughness = 0.15
	if Data.atlas_tex != null:
		m.albedo_texture = Data.atlas_tex
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	return m

# The coalesced step — runs from _low_step after the attach poll (the
# same frame the churn lands). One sector per frame, per-sector
# cooldown, a global floor between re-merges; steady state (no churn)
# costs the 64-flag scan.
func _ring_step() -> void:
	_ring_ready()
	var now := Time.get_ticks_msec()
	if now - _ring_last_any_ms < RING_MIN_GAP_MS:
		return
	for k in range(RING_SECTORS * 2):
		var i := (_ring_cur + k) % (RING_SECTORS * 2)
		if not _ring_dirty[i]:
			continue
		if now - int(_ring_last_ms[i]) < RING_REBUILD_GAP_MS:
			continue
		_ring_cur = (i + 1) % (RING_SECTORS * 2)
		_ring_dirty[i] = false
		_ring_rebuild_sector(i)
		_ring_last_any_ms = Time.get_ticks_msec()
		return

# Re-merge ONE sector from the live slot records (read-back — the
# slots always hold the exact emit arrays, so there is no registry to
# keep in sync and no registry memory: the sector mesh is the only
# extra copy of the visible far geometry).
func _ring_rebuild_sector(i: int) -> void:
	var tier := 2 + i / RING_SECTORS
	var sec := i % RING_SECTORS
	var t0 := Time.get_ticks_usec()
	var bv := PackedVector3Array()
	var bn := PackedVector3Array()
	var bc := PackedColorArray()
	var bi := PackedInt32Array()
	var wv := PackedVector3Array()
	var wn := PackedVector3Array()
	var wc := PackedColorArray()
	var wu := PackedVector2Array()
	var wi := PackedInt32Array()
	var slab_n := 0
	for key in chunks:
		var c: Node3D = chunks[key]
		if int(c.face) > 1:
			continue
		# NO live-tier prefilter: a slab is drawn in the ring of its
		# STORED tier stamp (the AC-0257 stale-tier window — a knob
		# change / recenter leaves the slab at its old tier until the
		# re-emit lands, and the old per-slab MIs kept SHOWING it then).
		# Prefiltering on the column's live tier would make the slab
		# vanish for the window (measured: an R50 boot dispatch at the
		# cfg knobs stamped a band-C slab in a band-B column — the
		# .scratch/AC-0338/census50-waterprobe2.log probe). The
		# per-slab stamp check below does the real classification;
		# skipping the live-tier check costs a cheap int compare per
		# column per sector (~0.1 ms at the R50 scale).
		if _ring_sector_of(int(c.cx), int(c.cz)) != sec:
			continue
		var ox := float(int(c.cx) * 16)
		var oz := float(int(c.cz) * 16)
		for j in range(c.low_slabs.size()):
			var si: int = int(c.low_slabs[j])
			# classified by the STORED tier stamp (the AC-0257
			# stale-tier window: a slab re-pending at a new tier keeps
			# showing its old-tier mesh until the re-emit — the ring
			# draws exactly what the visible slot holds, identical to
			# the old per-slab MI draw).
			if int(c.low_tiers.get(si, -1)) != tier:
				continue
			var mi: MeshInstance3D = c.low_instances[j]
			if mi == null or not mi.visible or not (mi.mesh is ArrayMesh):
				continue
			var am: ArrayMesh = mi.mesh
			var off := Vector3(ox, float(si * 16), oz)
			# surface_get_arrays returns an ARRAY_MAX Array of Variants
			# (null where the slot surface has no such array) — the
			# `as`-cast + null check keeps a degenerate surface from
			# throwing a typed-assignment error (G0's zero-SCRIPT-ERROR
			# contract).
			var arrs: Array = am.surface_get_arrays(0)
			var vv = arrs[Mesh.ARRAY_VERTEX]
			var v: PackedVector3Array = vv as PackedVector3Array
			if v == null or v.is_empty():
				continue
			var idx: PackedInt32Array = arrs[Mesh.ARRAY_INDEX] as PackedInt32Array
			var base := bv.size()
			for k in range(v.size()):
				bv.append(v[k] + off)
			if idx != null:
				for k in range(idx.size()):
					bi.append(idx[k] + base)
			var nrm: PackedVector3Array = arrs[Mesh.ARRAY_NORMAL] as PackedVector3Array
			if nrm != null and not nrm.is_empty():
				bn.append_array(nrm)
			var col: PackedColorArray = arrs[Mesh.ARRAY_COLOR] as PackedColorArray
			if col != null and not col.is_empty():
				bc.append_array(col)
			# the WATER EXCEPTION (AC-0312): surfaces 1 and 2 of the slot
			# share the same arrays — the ring keeps both (the two-pass
			# camera-side cull is per surface and survives the merge).
			if am.get_surface_count() > 1:
				var warrs: Array = am.surface_get_arrays(1)
				var w2: PackedVector3Array = warrs[Mesh.ARRAY_VERTEX] as PackedVector3Array
				if w2 != null and not w2.is_empty():
					var wbase := wv.size()
					for k in range(w2.size()):
						wv.append(w2[k] + off)
					var widx: PackedInt32Array = warrs[Mesh.ARRAY_INDEX] as PackedInt32Array
					if widx != null:
						for k in range(widx.size()):
							wi.append(widx[k] + wbase)
					var wnm: PackedVector3Array = warrs[Mesh.ARRAY_NORMAL] as PackedVector3Array
					if wnm != null and not wnm.is_empty():
						wn.append_array(wnm)
					var wcm: PackedColorArray = warrs[Mesh.ARRAY_COLOR] as PackedColorArray
					if wcm != null and not wcm.is_empty():
						wc.append_array(wcm)
					var wum: PackedVector2Array = warrs[Mesh.ARRAY_TEX_UV] as PackedVector2Array
					if wum != null and not wum.is_empty():
						wu.append_array(wum)
			slab_n += 1
	var ring_mi := _ring_mi_for(tier, sec)
	if bv.is_empty():
		ring_mi.mesh = null
	else:
		var mesh := ArrayMesh.new()
		var a: Array = []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = bv
		if not bn.is_empty():
			a[Mesh.ARRAY_NORMAL] = bn
		if not bc.is_empty():
			a[Mesh.ARRAY_COLOR] = bc
		a[Mesh.ARRAY_INDEX] = bi
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
		mesh.surface_set_material(0, _lod_avg_mat())
		if not wv.is_empty():
			var aw: Array = []
			aw.resize(Mesh.ARRAY_MAX)
			aw[Mesh.ARRAY_VERTEX] = wv
			if not wn.is_empty():
				aw[Mesh.ARRAY_NORMAL] = wn
			if not wc.is_empty():
				aw[Mesh.ARRAY_COLOR] = wc
			if not wu.is_empty():
				aw[Mesh.ARRAY_TEX_UV] = wu
			aw[Mesh.ARRAY_INDEX] = wi
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, aw)
			mesh.surface_set_material(mesh.get_surface_count() - 1, _ring_water_material())
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, aw)
			mesh.surface_set_material(mesh.get_surface_count() - 1, _ring_water_bf_material())
		ring_mi.mesh = mesh
	_ring_slab_n[i] = slab_n
	var dt := float(Time.get_ticks_usec() - t0) / 1000.0
	ring_rebuilds_n += 1
	ring_rebuild_ms += dt
	ring_rebuild_max_ms = maxf(ring_rebuild_max_ms, dt)
	_ring_last_ms[i] = Time.get_ticks_msec()

# AC-0283 P3 (AC-0313): the REAL band — taxi ≤ band0_r (the sim square):
# the collision/fluid sim square, exactly P2 (the star seed on data
# landing, the full 24-slab light walk, the 1:1 high build). The old
# MED/LOW split (medium_start_r / low_start_r) is GONE from the draw tier:
# everything outside the real band up to the render edge is the HALO —
# the 4x4x4 avg draw with the heightmap sky light, never seeded, never
# saved (AC-0287). AC-0313: the tier-0 disjunct is GONE too — the tier-0
# set's job (the player's 3x3 never a placeholder) is now implied by the
# band: sim has a floor of 4 (Settings.SIM_MIN), and every column of the
# player's 3x3 has taxi ≤ 2, so the footing guarantee holds for any
# storable sim.
func _is_real_col(dx: int, dz: int) -> bool:
	return absi(dx) + absi(dz) <= band0_r

# AC-0261 (AC-0283 P3; AC-0312 restored): the LOD zone of a chunk at
# (dx, dz) from the recenter anchor, taxi metric (the render edge is
# taxi too — "render distance is the max value for everything that is
# rendered"): 0 = the REAL band [0, band0_r] — the build lane owns it
# (pending renders NOTHING, no placeholder of any kind); 1 = BAND A
# (band0_r, medium_start_r] — the full-LOD draw tier (the cave-free
# skip fill materialized at first mesh, heightmap-sky light, normal
# high lane); 2 = BAND B (medium_start_r, low_start_r] — the 8x8 avg;
# 3 = BAND C (low_start_r, render_radius) — the 4x4 avg; 4 = DATA-ONLY
# [render_radius, ring edge) — nothing renders past the render
# distance. AC-0312: medium_start / low_start are DRAW tier boundaries
# again (live reads — nothing hardcodes 27/50); data is h-only for
# every tier 1-3 column (the AC-0284b representation).
func _lod_tier_of(dx: int, dz: int) -> int:
	if _is_real_col(dx, dz):
		return 0
	var taxi := absi(dx) + absi(dz)
	# AC-0312: the draw tiers live INSIDE the render edge — the band
	# knobs may sit past the render radius (a harness that forces
	# render_radius directly, e.g. the R=4 battery: medium_start 8 >
	# render 4). Past the edge there is nothing to draw: data-only,
	# whatever the knobs say (the knobs are DRAW-tier boundaries, not
	# data boundaries — the band_of streaming rule is untouched).
	if taxi >= render_radius:
		return 4
	if taxi <= medium_start_r:
		return 1  # AC-0312 band A (full LOD, materialized)
	if taxi <= low_start_r:
		return 2  # AC-0312 band B (8x8 avg)
	return 3  # AC-0312 band C (4x4 avg)

# AC-0313: the TIER-0 SET (tier0_r / _is_tier0_col / note_tier0_radius,
# the "tier0_radius" setting) is GONE — the real band (taxi ≤ band0_r) is
# the footing guarantee (see _is_real_col), and the build lane owns it
# the same way the tier-0 set did.

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
	_rescore_kick()
	_pool_touch()  # AC-0335: a tier change re-pends/completes wave-band slabs — the pick cache must re-scan

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
# AC-0331: yfloor = the far-tier mesh floor (the GD twin of the C++
# shared-tail mask in avg_grid_emit — a grid cell is kept iff its
# TOPMOST world y is > yfloor; the cell entirely below it is air, the
# straddling cell is kept whole; -1 = off, the pre-floor emit).
func _avg_emit_slab(g: Dictionary, grids: Array, si: int, G: int, yfloor := -1) -> ArrayMesh:
	# AC-0331: the floor mask on LOCAL copies (the caller's grids are
	# untouched — the arm samples with AND without the floor). The cell
	# condition mirrors the C++ tail exactly (per-grid slab index; the
	# same kept-whole/zeroed-below semantics).
	if yfloor >= 0:
		var cellb: int = 16 / G
		var gm: Array = grids.duplicate()
		for tsi in [si - 1, si, si + 1]:
			if tsi < 0 or tsi >= gm.size():
				continue
			var gg = gm[tsi]
			if gg == null:
				continue
			var src: PackedByteArray = gg["solid"]
			var sm: PackedByteArray = src.duplicate()
			var y0: int = tsi * 16
			for cy in range(G):
				if y0 + (cy + 1) * cellb - 1 > yfloor:
					continue
				for i in range(cy * G * G, (cy + 1) * G * G):
					sm[i] = 0
			gm[tsi] = {"solid": sm, "cols": gg["cols"]}
		grids = gm
		g = {"solid": gm[si]["solid"], "cols": g["cols"]}
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
# drain dispatches slab-by-slab through _dispatch_column_work): every
# PENDING slab (the data slabs holding no low + every stale low slab to
# rebuild from the edited data), ascending si. The per-slab core is
# _low_build_slab — the worker dispatch + the null-slab air bookkeeping
# (NO main-thread generation).
func _low_build(c: Node3D) -> void:
	var t0 := Time.get_ticks_usec()
	var targets: Array = _low_pending_sis(c)
	if targets.is_empty():
		return
	for si in targets:
		_low_build_slab(c, int(si))
	if timing:
		print("LOWBUILD %d,%d slabs=%d ms=%.1f" % [int(c.cx), int(c.cz), targets.size(), (Time.get_ticks_usec() - t0) / 1000.0])

# AC-0231 fix3: every PENDING slab of a chunk, ascending si — a low slab
# to rebuild (stale: edited after the low, or built at a different band
# tier) + every data slab that holds NO low (the pending source
# directly; bounded 24-slab scan). AC-0257: the cap set and the kept
# mask are gone (vwin removal); every slab is wanted. AC-0336: the fog
# walk is gone with the fog wave (fog_slabs never held a slab in the
# shipped path).
func _low_pending_sis(c: Node3D) -> Array:
	var out: Array = []
	var tier := _lod_tier_of(int(c.cx) - last_pcx, int(c.cz) - last_pcz)  # AC-0252: the live band tier
	# AC-0331: the far-tier mesh floor — the spec's dispatch pruning:
	# slabs entirely below the floor are dropped from the pending set
	# for far columns so no worker task is ever dispatched for them
	# (the cost win: 7 of 24 low-lane slabs per far column, on entry
	# AND on every re-lower). -1 for non-far (the real band never
	# floors — caves + sub-floor digging survive there).
	var yfl := _far_floor_y() if c.far else -1
	for l in range(c.low_slabs.size()):
		var si := int(c.low_slabs[l])
		if yfl >= 0 and si * 16 + 15 < yfl:
			continue  # AC-0331: below the far floor — never dispatched
		# a LOW slab older than the chunk stamp (edited after the low)
		# or built at a DIFFERENT band tier (AC-0252: the low-start
		# boundary moved since the build — re-lower at the live tier)
		# — PER-SLAB staleness: the finished slabs of a partially-
		# lowered chunk stay fresh while its other slabs are pending.
		if c.low_stamps.get(si, []) != c.stamp() \
				or c.low_tiers.get(si, -1) != tier:
			out.append(si)
	# AC-0240: a kept data slab that holds NO low is the pending source
	# directly (a terminal all-air mark skips it until the data changes).
	for si in range(c.data.size()):
		var si2 := int(si)
		if yfl >= 0 and si2 * 16 + 15 < yfl:
			continue  # AC-0331: below the far floor — never dispatched
		if c.data[si2] != null and not c.has_low_si(si2) \
				and int(c.low_failed.get(si2, -1)) != int(c.data_gen):
			out.append(si2)
	out.sort()
	return out

# AC-0257: the old _low_pending_si (the min-si first-pending probe) is
# gone — the drain's pick uses _entry_best_pending (the LAYER-best
# pending slab — the bake order, see its comment). AC-0336: the WAVE 3
# _low_any_stale helper is gone with the idle catch-up.

# AC-0231 fix3 / AC-0252 (+ worker offload): the per-slab low entry —
# ZERO slab generation on the main thread. The band-tier AVERAGE-COLOR
# grid sample + emit (MED 8x8x8 inside the configurable low-start
# distance, LOW 4x4x4 outside it — _lod_tier_of) run on the TM WORKER
# POOL (the C++ low_emit_avg, the _low_dispatch_slab path); the attach +
# every bit of the per-slab bookkeeping (the cap swap, the per-slab
# stamp WITH THE TIER, the all-air terminal mark, the counters) lands
# in the _low_handoff on the main thread — the scene-tree work that has
# to stay there. The TEXTURED 4x4x4 emit (_low_emit_slab) stays in the
# tree, dormant. The ONLY thing that runs inline is a slab whose DATA
# IS NULL (the dispatch's -1 verdict — an empty column slab has no grid
# to sample and no emit to run): the air bookkeeping via _low_air_slab
# (a slab whose data went NULL shows nothing — its stale low is
# dropped). A slab that has blocks but SAMPLES all-air is a real emit
# (a worker task): the terminal low_failed mark lands in the
# _low_handoff.
func _low_build_slab(c: Node3D, si: int) -> void:
	if c.data.is_empty() or si < 0 or si >= c.data.size():
		return
	# AC-0284b: a far column's null slab is NOT air — it dispatches to the
	# payload emit (only a real null slab takes the air bookkeeping).
	if c.data[si] == null and not c.far:
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
# per-slab stamp.
func _low_air_slab(c: Node3D, si: int) -> void:
	if si < 0 or si >= c.data.size() or c.data[si] != null:
		return
	_low_drop_slab(c, si)
	c.low_stamps.erase(si)  # not low anymore (no data — air)

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

# AC-0283 P3: the column's heightmap (256 bytes — H[lz*16+lx], the terrain
# top y). The C++ heights pass (the three surface fields + the 256
# surface_h reads; ~33us once per column), cached on the chunk. The halo
# band's draw light is a function of H alone — no flood, no nibbles.
func _halo_hmap_get(c: Node3D) -> PackedByteArray:
	if c.hmap.is_empty():
		c.hmap = WorldGen.gen_cpp().column_heights(int(c.cx), int(c.cz), Game.world_seed, int(Data.HEIGHT))
	return c.hmap

# AC-0283 P3: the per-slab halo SKY payload (64 bytes for the 4x4x4 grid,
# cell order cy*16 + cz*4 + cx): a 4x4x4 cell is lit (15) iff it sits
# STRICTLY above the terrain top over its whole 4x4 x/z footprint (the
# quad rule — the max of H over the footprint, one compare per cell),
# else 0. Computed at dispatch on the main thread (H is known the moment
# the data lands — the halo dispatch needs no engine settle). The
# worker's low_emit_avg writes each quad's origin-cell sky into the
# vertex alpha (the lod_avg shader multiplies it into the brightness).
func _halo_sky_for(c: Node3D, si: int) -> PackedByteArray:
	# AC-0312: G follows the live band tier — band B (tier 2) emits the
	# 8x8 avg, so its per-cell sky is G=8 (512 B); band C (tier 3) keeps
	# G=4 (64 B). The quad rule is unchanged: a grid cell is lit (15)
	# iff its BOTTOM sits strictly above the max terrain top over its
	# x/z footprint, else 0. (Band A / real / data-only — no avg sky.)
	var G := 4
	var t := _lod_tier_of(int(c.cx) - last_pcx, int(c.cz) - last_pcz)
	if t == 2:
		G = 8
	elif t != 3:
		return PackedByteArray()
	var CB := 16 / G
	# AC-0284b: a far column's stored H (the u16 payload) IS the
	# heightmap — no C++ heights pass and no u8 wrap above 255 (TERRAIN_H
	# MAX is 300). The slab-shaped halo path below keeps the u8 cache.
	var fh: Array = []
	fh.resize(G * G)
	if c.far:
		for gz in range(G):
			for gx in range(G):
				var m := 0
				for lz in range(gz * CB, gz * CB + CB):
					var r0 := lz * 32
					for lx in range(gx * CB, gx * CB + CB):
						var o := r0 + lx * 2
						var v := int(c.far_h[o]) | (int(c.far_h[o + 1]) << 8)
						if v > m:
							m = v
				fh[gz * G + gx] = m
	else:
		var hm: PackedByteArray = _halo_hmap_get(c)
		for gz in range(G):
			for gx in range(G):
				var m := 0
				for lz in range(gz * CB, gz * CB + CB):
					var r0 := lz * 16
					for lx in range(gx * CB, gx * CB + CB):
						if int(hm[r0 + lx]) > m:
							m = int(hm[r0 + lx])
				fh[gz * G + gx] = m
	var y0f := si * 16
	var outf := PackedByteArray()
	outf.resize(G * G * G)
	for cy in range(G):
		for cz in range(G):
			for cx in range(G):
				outf[cy * G * G + cz * G + cx] = 15 if y0f + cy * CB > int(fh[cz * G + cx]) else 0
	return outf

func _low_dispatch_slab(c: Node3D, si: int) -> int:
	# AC-0284b: a far column's null slabs ARE the payload — dispatchable.
	if threadmesh_pool == null or si < 0 or si >= c.data.size() or (c.data[si] == null and not c.far):
		return -1
	# AC-0312: band A (tier 1) is owned by the HIGH lane (the
	# materialization + the per-slab high builds) — the low lane no-ops
	# it (the wave scan skips tier 1; this guards the direct callers).
	# 0 = handled (no air-slab bookkeeping for a non-air slab).
	if _lod_tier_of(int(c.cx) - last_pcx, int(c.cz) - last_pcz) == 1:
		return 0
	# AC-0331: the far-tier mesh floor — a far column's slabs entirely
	# below it are never dispatched (the spec's dispatch pruning; the
	# probes + _low_pending_sis already drop them — this guards the
	# direct callers). 0 = handled (nothing to do).
	if c.far and si * 16 + 15 < _far_floor_y():
		return 0
	if _low_tasks.size() >= LOW_TASK_CAP:
		return 2
	var key := _key(int(c.cx), int(c.cz))
	var lkey: String = key + ":" + str(si)
	if _low_task_keys.has(lkey):
		return 0
	# AC-0284b: a far column carries the payload instead of the slab copy
	# (the emit reads no slabs — ~1 KB vs ~20 KB on the wire).
	var mc: Variant = ChunkScript.mesh_cpp() if not c.far else null
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
		"tier": tier,  # AC-0312: 2 = band B (8x8 avg), 3 = band C (4x4 avg)
		# AC-0283 P3 (AC-0312: both avg bands): the per-cell heightmap
		# sky light (the dispatch tier is the band — a
		# promotion/demotion re-pick re-emits at the new tier; the real
		# band never reaches this lane, empty payload). Band A (tier 1)
		# never dispatches here (the high lane owns it — the wave skips
		# tier 1, _low_dispatch_slab no-ops it).
		"sky": _halo_sky_for(c, si) if tier >= 2 else PackedByteArray(),
		"slabs": mc.slab_copy(c.data) if not c.far else PackedByteArray(),  # the full column (~20 KB; the C++ emit reads si-1/si/si+1) — a far column carries the payload below
		# AC-0284b: the far payload (h u16 + biome + top) — null for every
		# non-far dispatch. Packed arrays are COW value types: the worker
		# reads a stable copy (the entry is the last consumer). far_hmax
		# is the deep-cell guard (the ore precompute trigger).
		"far": [c.far_h, c.far_biome, c.far_top] if c.far else null,
		"far_hmax": int(c.far_hmax) if c.far else 0,
		# AC-0284b: the cached tree-cell list (empty = not computed yet —
		# the FIRST far slab worker computes it (veg_cells) and lands it
		# back on the column via the entry (the handoff stamps c.far_veg;
		# the later slabs of the column read the cache, no recompute).
		"far_veg": c.far_veg if c.far else PackedByteArray(),
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
# greedy mesh in C++): per-slab stamp, the all-air terminal mark. A
# dropped result (null / stale data / chunk gone) needs no re-queue: the
# slab is still PENDING in the chunk state (low_stamps), so the drain's
# steady pass re-picks it next frame.
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
	# AC-0284b: the first far slab's worker computed the tree cells
	# (veg_cells — lazy, worker-side); stamp them on the column so the
	# column's later slabs read the cache at dispatch (a stale-tier drop
	# still stamps — the tree set is tier-independent).
	if c.far:
		var vd: Variant = e.get("veg_done", null)
		if c.far_veg.size() == 0 and vd is PackedByteArray and (vd as PackedByteArray).size() > 0:
			c.far_veg = vd
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
		# bookkeeping) — marked TERMINAL so the picks advance past it
		# until the data changes.
		_low_drop_slab(c, si)
		c.low_stamps.erase(si)
		# AC-0284b: a far slab that sampled all-air (a slab above the
		# column top) is TERMINAL-marked like a real slab — without the
		# mark it would re-pick + re-emit forever (its null slab is not
		# air to the picker). A real null slab needs no mark: the probe
		# skips null data slabs outright. AC-0336: the terminal mark is
		# the low lane's all-air record (the fog wave it once paired with
		# is gone).
		if not (c.data[si] == null and not c.far):
			c.low_failed[si] = c.data_gen
			_low_probe_invalidate(c)  # AC-0262: terminal mark -> not pending
	else:
		# AC-0252: the avg-color surface (vertex color, NO UVs — the noise
		# shader material owns the surface; the textured low's "u" array is
		# gone from the active path).
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _low_surface(res["v"], res["i"], res["n"], res["c"]))
		# AC-0312: the WATER EXCEPTION — a water-topped cell's top face
		# rides as extra surfaces with the real translucent water
		# material (the two-pass camera-side cull, like the high path's
		# fluid mesh): the C++ emit splits the water verts out of the
		# avg surface (wv/wn/wc/wu/wi — the avg surface stays
		# byte-identical, the farab A/B contract holds with the water
		# face on both sides).
		var wv: PackedVector3Array = res.get("wv", PackedVector3Array())
		if wv.size() > 0:
			var ws: Array = _low_surface(res["wv"], res["wi"], res["wn"], res["wc"], res["wu"])
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, ws)
			mesh.surface_set_material(mesh.get_surface_count() - 1, c._fluid_anim_material(5))
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, ws)
			mesh.surface_set_material(mesh.get_surface_count() - 1, c._fluid_anim_bf_material(5))
		low_max_h = maxf(low_max_h, float(res.get("mh", 0.0)))
		_low_place_slab(c, si, mesh)
		if _low_first_attach_frame < 0:
			_low_first_attach_frame = Time.get_ticks_msec()  # AC-0263: section-first evidence
		c.low_built = true
		c.low_failed.erase(si)
		_low_probe_invalidate(c)  # AC-0262: the un-mark re-pends the slab
		# PER-SLAB stamp (the _low_build_slab comment: a chunk-level stamp
		# would keep the other slabs' finished neighbors stale and the
		# drain would re-pick the built slabs forever).
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
# attach is a node create + cap swap, ~0.2 ms). Runs every frame from
# _low_step so a ready placeholder lands without waiting for a high
# handoff (the high lane keeps its own stream_ho_cap pace in
# threadmesh_poll). The cap clamps to the frame wall time: at 600 fps a
# flat 4 ms cap would eat the whole 1.67 ms step.
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

# AC-0231 rewrite: drop the low for ONE slab (it becomes air, or the
# column flips/re-lowers).
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
	_ring_dirty_column(c)  # AC-0338: a segment left — the ring re-merges

# AC-0231 rewrite: place/replace the per-slab low instance (slab-local
# 0..16 geometry at (0, si*16, 0), sorted by slab index).
func _low_place_slab(c: Node3D, si: int, mesh: ArrayMesh) -> void:
	# AC-0263 spec (keep-all-LOD): the slab holds a stored HIGH - the low
	# landing is the FLIP: attach the low, turn the high off. The high
	# instances stay on the node (hidden) until the column recycles - the
	# re-entry flip brings them back WITHOUT a rebuild. AC-0275's
	# double-LOD refusal is gone: the flip is atomic (one visible tier at
	# a time).
	if c.slabs[si].mesh_instance != null:
		c.high_slab_visible(si, false)
		low_on_high_n += 1  # the flip count (high kept, low now active)
	var _wpt := Time.get_ticks_usec()  # AC-0251 MESHATTACH sub-stage
	var i := 0
	while i < c.low_slabs.size() and int(c.low_slabs[i]) < si:
		i += 1
	var mi := _mi_checkout()  # AC-0247: pool (per-slab ArrayMesh from the C++ low_emit handoff)
	mi.mesh = mesh
	if mesh.get_surface_count() > 1:
		# AC-0312: a water surface rides with the slab — per-surface
		# materials (a material_override would override the water's
		# fluid material); surface 0 wears the avg noise material
		# exactly as the override did.
		mesh.surface_set_material(0, _lod_avg_mat())
	else:
		# AC-0252: the placeholder slabs are AVERAGE-COLOR (vertex color,
		# no UVs) — they wear the noise shader material, not the
		# textured-low opaque material (the textured emit is dormant
		# with the band split).
		mi.material_override = _lod_avg_mat()
	mi.position = Vector3(0.0, float(si * 16), 0.0)
	# AC-0338: the slot is NO LONGER a scene-tree child — the far tier's
	# draw is the ring-level batch (the _ring_* block above). The slot
	# stays a plain (pooled, off-tree) MeshInstance3D that holds the
	# per-slab record: the exact emit arrays (the harness byte gates
	# read them off mi.mesh) + the visibility flag (the flip contract).
	# Its position stays slab-local (the r16 arm checks 0/si*16/0).
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
	_ring_dirty_column(c)  # AC-0338: a new/replaced segment — the ring re-merges

# AC-0231 fix3: the atlas TEXTURE SWAP re-merges the strip table
# (_tm_ms_full) — the merged-atlas strip POSITIONS move (a different
# unique-rect set re-packs the 512x128 rows), so every EXISTING low mesh
# keeps the OLD strip UVs and samples the wrong texture on the new canvas
# (the "wrong texture mapping" the user reported at distance). The HIGH
# meshes recover through the tex_refresh drain (every chunk re-pushed),
# but the lows are main-thread MeshInstance3Ds that only the drain's
# steady pass (re)builds — so on a swap, drop every low; the drain
# re-lowers all of them against the new table within a few hundred frames.
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
		# c.low_stamps was already cleared by the last _low_drop_slab (the
		# empty-low reset); c.low_failed stays — its marks are keyed by
		# data_gen, which the atlas swap does NOT change (the terminal
		# all-air verdicts survive: re-picking them would just re-fail the
		# sample).

# AC-0231 rewrite: the high REPLACES the per-slab lows — free every
# per-slab low instance. as_upgrade counts a placeholder->high
# replacement (the catch-up evidence); the evict path frees without
# counting. Keep-high from here on: a meshed chunk is never downgraded
# to low (low_downgrade_n stays 0 — the low path only serves never-built
# slabs).
func _lod_free_all(c: Node3D, as_upgrade: bool) -> void:
	if as_upgrade and bool(c.low_built):
		low_upgrades_n += 1
	if as_upgrade:
		# AC-0263 spec (keep-all-LOD): the high takes over - the per-slab
		# lows are STORED (visible=false), not freed: the band-exit
		# flip-back renders them without a rebuild, and they pool out at
		# column recycle. Their stamps/tiers/masks stay (the slabs remain
		# low-complete - the low probe does not re-pend them).
		for i in range(c.low_slabs.size()):
			var mi2: MeshInstance3D = c.low_instances[i]
			if mi2 != null:
				mi2.visible = false
		_low_probe_invalidate(c)  # conservative (visible state moved)
		_ring_dirty_column(c)  # AC-0338: the lows went stored — the ring drops them
		return
	# the free path (chunk clear / candidate): everything returns to the
	# pools, the low state clears (the column is gone).
	c.drop_low()
	_low_probe_invalidate(c)  # AC-0262: drop_low re-pends the slab
	_ring_dirty_column(c)  # AC-0338: the column's segments are gones


# AC-0231 rewrite: the legacy SYNC build fallbacks (data-empty,
# missing-neighbor, cap-drop with defer_on_cap=false, create_chunk
# mesh_now) establish a high mesh WITHOUT the worker handoff — the
# per-slab placeholders must be dropped here or the fog/low renders on
# top of the fresh high.
func _low_drop_sync(c: Node3D) -> void:
	_lod_free_all(c, true)


var _slab_wave_last_t := 0    # AC-0231 fps-tuning: wall usec of the previous low frame


# AC-0231 fix3 (AC-0335 UPDATED, AC-0336 PRUNED): the far-LOD lane's
# ATTACH side — the picking half is GONE with the unification (AC-0335:
# the drain's steady pass is the ONLY scheduler — it dispatches the far
# payload avg emits (rings 2/3) in the same (taxi, layer) order as the
# high builds, through _dispatch_column_work; a column entering the real
# band is simply the next column whose ring changed). AC-0336: the dead
# in-r lane (flag upkeep + the WP_LOW_INR bracket) and the fog-material
# upkeep are gone too. What _low_step owns: _low_poll (the attach — the
# cap swap, the all-air terminal marks, the per-slab tier stamps) and the
# re-lower debt step; the avg-LOD material tracks the sky's brightness.
func _low_step() -> void:
	if _shutting_down:
		return
	# AC-0231 fps-tuning: the frame's WALL-CLOCK duration (clamped) — the
	# pacing basis (identical build pace at 30-60 fps).
	var now_t := Time.get_ticks_usec()
	var dt_ms := 16.67
	if _slab_wave_last_t > 0:
		dt_ms = minf((now_t - float(_slab_wave_last_t)) / 1000.0, 100.0)
	_slab_wave_last_t = now_t
	# AC-0252 (the AC-0261 follow-up): the med/low avg-color LODs track the
	# sky's BRIGHTNESS — a GRAY derived from the sky color's average — not
	# the sky's hue. AC-0252 originally passed the sky color itself; the
	# midday sky-blue (0.53,0.81,0.92) multiplied into every albedo pulled
	# bright warm surfaces toward cyan (midday sand -> mint green). The
	# night darkening is preserved (night sky avg ~= 0.07, same as before).
	# The sky color changes slowly, so the per-frame set is skipped when
	# unchanged (set_shader_parameter touches the material — keep it out of
	# the hot main-thread LOW stage). AC-0336: read the sky directly (the
	# old carrier was the fog material, gone with the fog wave).
	if _lod_avg_material != null:
		var sdc := DayNight.sky_display(Game.time_of_day)
		var dl := (sdc.r + sdc.g + sdc.b) / 3.0
		var day_c := Color(dl, dl, dl)
		if not _lod_day_last.is_equal_approx(day_c):
			_lod_day_last = day_c
			_lod_avg_material.set_shader_parameter("day", day_c)
	# AC-0293: the spawn-fast term is gone with the burst (loading_active
	# already covers the spawn window) — the attach pauses with it (the
	# dispatch side keeps its own loading budgets).
	if loading_active:
		return
	# AC-0335: the WAVE 3 idle catch-up (the low->high upgrade when a
	# low-holding column entered the real band) is GONE with the lane
	# seam — a column entering the real band is simply the next column in
	# the drain's (taxi, layer) order whose ring changed, and its ring-0/1
	# work is the high slab build (_dispatch_column_work). AC-0336: the
	# _low_idle / LOW_UPGRADE_PER_FRAME / LOW_IDLE_GRACE_FRAMES leftovers
	# are gone too.
	# AC-0236 part 2 (AC-0335 UPDATED): attach the completed low emits —
	# a ready placeholder lands this frame (the emit started the moment
	# the data landed, not when the main-thread pass got to it). The
	# DISPATCH is the drain's (one order, the ring decides the work —
	# _dispatch_column_work) — this lane attaches. AC-0262: sub-stage
	# brackets — the LOW stage is split for the poll (the attach poll,
	# incl. mesh create).
	var _wpt2 := Time.get_ticks_usec()
	_low_poll(dt_ms)
	_wprof_add(WP_LOW_POLL, Time.get_ticks_usec() - _wpt2)
	# AC-0338: the ring-level far batch's coalesced rebuild step (the
	# DRAW side of the low lane — the poll attaches the records, the
	# ring re-merges the visible ones into the sector meshes). Rides
	# WP_LOW_POLL (the low stage) — the five-stage partition is kept.
	_ring_step()
	# AC-0335: the WAVE 2b global slab wave dispatch (the _low_scan_slabs
	# pick + the _slab_wave_acc_ms pacing loop) is GONE with the lane
	# seam — the drain's steady pass dispatches rings 2/3 in the same
	# (taxi, layer) order through _dispatch_column_work, paced by the ONE
	# wall-clock unit budget (LOW_WAVE_PACE_MS / LOW_WAVE_FRAME_CAP — the
	# surviving pacing model; see the _drain_build_queue comment).
	_low_relower_owed_step()  # AC-0284b: the meshed columns' re-lower debt


# AC-0284b: drain the low re-lower debt (one owed column per frame — the
# dispatch's per-key:si dedup + the worker pace keep it smooth). The
# normal slab wave can only reach QUEUED entries; a demoted meshed column
# has none (the recenter recompute skips meshed columns), so its stale /
# missing lows would never re-lower and the demote flip never lands. The
# re-landing attach does the flip (high off, low on — the demote
# contract). AC-0312: the probe decides for EVERY representation — a
# demoted far column re-lowers from its payload (its null slabs ARE the
# data; the far emit is byte-identical to the slab emit on the same
# grid). Clearing: the real band or band A (the high owns the draw),
# or a fresh probe (all lows current at the live tier).
func _low_relower_owed_step() -> void:
	if _low_relower_owed.is_empty():
		return
	for key in _low_relower_owed.keys():
		var rc = chunks.get(key)
		if rc == null or rc.data.is_empty():
			_low_relower_owed.erase(key)
			continue
		# AC-0312: the tier is the whole story (the old `rc.far`
		# short-circuit is RETIRED — a DEMOTED far column re-lowers from
		# the payload: its null slabs ARE the data, the far emit reads
		# the payload; the probe is pending against the live tier until
		# the re-lower lands). The real band and BAND A clear the debt
		# (the high owns the draw; the wave skips band A — a low there
		# would be the wrong tier).
		var rc_tier := _lod_tier_of(int(rc.cx) - last_pcx, int(rc.cz) - last_pcz)
		if rc_tier <= 1:
			_low_relower_owed.erase(key)
			continue
		var rsi := _entry_best_pending_cached(rc)
		if rsi < 0:
			_low_relower_owed.erase(key)  # the lows are current — done
			continue
		if _low_dispatch_slab(rc, rsi) < 0:
			_low_air_slab(rc, rsi)
		break  # one owed column per frame (the rest retry next frame)


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
var collide_drain_budget_ms := COLLIDE_DRAIN_BUDGET_MS  # AC-0340: the staged collision lane's per-frame cap
# AC-0213: small-move (recenter) pacing state.
var _sm_move_until := 0        # drain budget drops to 1 unit/frame until this ms
var _last_recenter_ms := 0     # wall ms of the last recenter() entry
var _last_recenter_pcx := 0    # center of the last recenter (debounce delta)
var _last_recenter_pcz := 0
const SMALL_MOVE_BUDGET_MS := 1500
const AHEAD_RING_DEBOUNCE_MS := 1000
# AC-0277: predictive recenter target (REPLACES the AC-0213 debounced
# skip). A crossing within AHEAD_FAST_MS of the previous recenter is FAST
# movement (sprint ~2.9 s/chunk is fast; walk ~3.7 s/chunk is not) - the
# recenter then targets the chunk AHEAD_DIST in front of the player along
# the crossing direction, so the baked queue leads where the player is
# headed instead of trailing where the player was. Slow crossings center
# on the current chunk. When the crossing stream is quiet for
# AHEAD_FAST_MS, the _process snap-back recenters to the chunk under the
# player.
const AHEAD_FAST_MS := 3500
const AHEAD_DIST := 1
var _ahead_active := false      # the current center leads the player
var _last_cross_ms := 0         # wall ms of the last PLAYER-chunk crossing
# AC-0313: the AC-0283 P3 walk-regime state (_prev_cross_ms — the crossing
# period) and the AC-0263 Y-window moving state (_lod_move_anchor /
# _lod_move_ms) are GONE — the walk regime and the Y-window are removed
# (see the drain and _grid_score).
var _rec_player_wx := 0.0       # raw player position at the last recenter
var _rec_player_wz := 0.0
var _rec_player_pcx := 0
var _rec_player_pcz := 0
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
# AC-0270: leaf decay - pending (loaded from save, not yet on a chunk) and
# the enabled flag (harness can shorten the timer window via env).
var pending_leaf_decay := {}
var leaf_decay_enabled := true
var leaf_decay_min_ms := 2000
var leaf_decay_max_ms := 12000
var leaf_decay_debug := false
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
# AC-0284b: the promotion's FULL regen is owed, not one-shot — a bare
# threadgen_enqueue at the recenter crossing can be cap-dropped (the pool
# is full of the new forward band's data pass) and never retried, leaving
# a far (no-caves) column far INSIDE the real band (the halo arm's (d)
# caught it: the promoted column never regenerated). The drain retries
# every frame (a fresh identity capture each try) until the regen is
# accepted and lands; a full landing (no_caves false) or the column
# leaving the real band clears the entry.
var _far_promo_owed: Dictionary = {}
# AC-0286: the PROMOTION BURST — the keys of the columns whose far->full
# regen just LANDED (was_far). Their 24-slab high conversion would queue
# behind the streaming backlog (the R50 flight's q_build sits ~5000 deep
# — the conversion would take minutes, the user flies through the
# low-detail far mesh for seconds). The burst bypasses the lane's queue
# score: _promo_build_step dispatches each marked column's best pending
# slab every frame through the SAME _mesh_dispatch_hslab (the settled-
# payload box gate, the TM inflight cap, the 1-slab/key dedup — all
# reused, nothing new). The mark dies at mesh_built or column free (a
# mid-conversion demote keeps the mark — the step is real-band gated,
# the re-entry resumes the burst).
var _promo_build: Dictionary = {}
# AC-0284b: the LOW re-lower debt — a meshed column owes a low at its
# live tier (stale after a data change — the promotion's full regen
# bumps data_gen and its halo low goes stale — or no low at all after a
# first demote) but is INVISIBLE to the slab wave: the wave only scans
# queued entries, and a meshed column gets no fresh entry on recenter
# (the WANT/merge meshed skip). The low step drains the debt: one owed
# column per frame, its best pending slab dispatched through the normal
# low lane (the per-key:si dedup paces it; the re-landing attach flips
# the tiers — the demote contract). A fresh probe, a far column, or a
# return to the real band clears the entry.
var _low_relower_owed: Dictionary = {}
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
# AC-0274: the per-second LOADER timeline (env AWECRAFT_LOADLOG=1) - the
# stall repro's evidence: progress %, both pool depths, io/gen counts.
# print() is piped-buffered - run under stdbuf -oL.
var _loadlog_on := OS.get_environment("AWECRAFT_LOADLOG") == "1"
# AC-0275: the double-LOD GUARD counter - low/fog attach attempts on a slab
# that ALREADY holds a high mesh. The high landing drops its slab's low/fog
# (the designed direction); the low/fog side now REFUSES (the slab stays
# high; the slab is marked low-terminal with NO instance so the wave probe
# stops owing it). The user's "washed-out / stuck-in-night" chunks were
# exactly this state: the sky-colored fog box veiling the high mesh (day =
# washed, night = dark).
var low_on_high_n := 0
# AC-0275: the demote evidence - columns regenerated at their new band
# tier on a recenter (the user's decision A).
var demoted_cols_n := 0
# AC-0275: high builds that landed after their column left the high band
# (freed, never attached).
var hslab_stragglers_n := 0
# AC-0274: the stall forensics (the per-second LOADLOG line reports these).
var hslab_defer_nbs := 0
var hslab_defer_dedup := 0
var hslab_stale_key_n := 0
# AC-0286: the settled-payload gate deferrals (reason 5 — the 3x3x3 box
# not settled). The promotion burst's stall forensics (a re-seeded /
# evicted column's settle window is the burst's only legitimate pause).
var hslab_defer_settle := 0
# AC-0339 STEP 0 (INSTRUMENTATION ONLY): hslab_defer_settle counts
# DEFERRALS (one per re-pick), not WAITING TIME — a slab can be deferred
# for hundreds of frames and the counter shows one. The settle-wait
# census measures the WAIT itself: an "episode" opens on the slab's FIRST
# settle-defer (the gate below in _mesh_dispatch_hslab) and closes on its
# dispatch (the gate passing). The bookkeeping is additive-only (a small
# Dictionary + array appends per defer/dispatch EVENT) — no behaviour
# change; the arms control the window via settlewait_reset/report.
var _sw_frame := 0  # frame counter (one _process = one frame)
var _sw_open := {}  # "cx,cz:si" -> first-defer frame (open episodes)
var _sw_samples: Array = []  # closed waits in frames (first defer -> dispatch)
var _sw_stalled: Array = []  # per settle-defer: the high-lane columns queued behind it
var _sw_episodes := 0
var _sw_defer_frames := 0
var _sw_max_open := 0
var _sw_remesh_max := 0  # star_remesh lane depth, max (the armed re-bake count)
var _sw_star_busy_frames := 0  # frames where _star_step had pending > 0
var _sw_star_pending_max := 0  # the relaxation queue depth at step start, max
var _sw_star_drained_max := 0  # star.step's returned drained count, max/frame
var _sw_star_pending_sum := 0
var _sw_star_drained_sum := 0
# AC-0274: the last hslab-dispatch deferral reason (0 = dispatched, 1 =
# per-column dedup, 2 = TM pool full, 3 = diagonal neighbor ungenerated,
# 4 = no data). The drain's skip-and-continue policy reads it: a
# per-column deferral must not end the pass (only a full pool does).
var _hslab_last_defer := 0
# AC-0274: per-100ms drain window (the stall forensics, frame resolution).
var _loadwin_ms := 0
var _loadwin_disp := 0
var _loadwin_dedup := 0
var _loadwin_nopick := 0
var _loadwin_maxinf := 0
var _load_wms_sum := 0
var _load_wms_n := 0
var hslab_defer_cap := 0
# AC-0312: the band-A materialization forensics — mat dispatches (the
# far column's first high dispatch), their worker-side ms (fill + full
# column build), and the deferrals on a missing sky eff (should never
# happen: the far payload is resident).
var band_a_mat_dispatches := 0
var band_a_mat_ms_sum := 0
var band_a_mat_ms_n := 0
var hslab_defer_sky := 0
var load_phase1_ready_fail := 0
var _loadlog_t0 := 0
var _loadlog_next_ms := 0
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
# AC-0293: the 5x5 startup burst (elems/slots/group-tids/pending-n state,
# the group worker + apply pass, the drain hold and the one-shot _spawn_fast
# latch that kept its window unopposed) is RETIRED — spawn and recenter ride
# the SAME normal streaming path as everything else (the recenter pre-warm
# enqueues the 5x5 through the normal build queue; the data pass feeds it).
# Anti-fall is carried by the AC-0313 clause-4 load gate: the SIM TAXI
# DIAMOND (taxi <= band0_r, 41 cols at sim 4) meshed by normal streaming
# before the player activates (main.gd _await_sim_band), so no special pass
# owes the player's footing.
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
# AC-0263 (AC-0313): the section-first order contract evidence (wall ms):
# the INITIAL ANCHOR COLUMN's (taxi 0 — the tier-0 set's default, now the
# innermost column of the (taxi, layer) order) high completion (first
# anchor-column slab to complete high after boot — a moving recenter's
# new anchor column does NOT reset it), and the FIRST textured-low attach
# (the wave's first landing). The contract: low_first >= section_done.
# (The AC-0263 one-shot wave gate is gone with the tier-0 set — see the
# wave scan in _low_step.)
var _hslab_section_done_frame := -1
var _low_first_attach_frame := -1
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
# AC-0340: the debt census — a column whose slabs outlast the per-frame
# collision budget (collide_drain_budget_ms) is RE-QUEUED, never dropped:
# perf_col_deferred counts the deferrals (informational; a healthy walk
# shows a small steady number, the debt converges in <1 s).
var perf_col_deferred := 0
# AC-0340 FENCE TRIPWIRE: a deferral INSIDE the immediate footprint
# (the _col_immediate_for predicate — Chebyshev <= 1 of the anchor, plus
# the (0,0) spawn column) is the "player falls through" class (chunk.gd
# :1355, the AC-0264 hunt) — the budget must NEVER defer a slab there.
# Must read 0 in every gate (the boundary/perf/player arms expose it).
var perf_col_deferred_in_footprint := 0
# AC-0337 step 0: the per-SLAB collision census (the trio above counts
# BATCHES — one per immediate landing / per staged column drain — so the
# gate's "ms per collision" was per-batch). Counted at the single body-
# derivation choke point (chunk.gd _build_slab_collision) at usec
# resolution; the ms histogram is the per-slab cost shape AC-0340's
# budget needs. perf_reband_* = the band-0 excursion census (the walk's
# oscillation: exit/entry column transitions + the kept bodies freed on
# re-entry — step 1 makes re-entry re-arm only the STALE slabs, so
# rearm ≈ 0 is the healthy reading).
var perf_collision_slabs := 0
var perf_collision_slab_ms := 0.0
var perf_collision_slab_max_ms := 0.0
var perf_collision_slab_hist := PackedInt32Array([0, 0, 0, 0, 0, 0])  # ms bins: <1, 1-2, 2-5, 5-10, 10-25, >=25
var perf_reband_exit := 0
var perf_reband_entry := 0
var perf_reband_rearm_slabs := 0
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
# AC-0348: the crossing ring — one entry per SYNCHRONOUS recenter() call.
# That sweep runs from the PHYSICS frame (the player.gd chunk-change call)
# and from the _process snap-back (line ~4368) — both OUTSIDE the per-frame
# wprof partition, whose WP_RECENTER stage brackets _recenter_slice() (the
# SLICED continuation) only. So the crossing's synchronous cost (the chunk
# walk + the band-exit/entry calls + the inline polls + the pre-warm) has
# nowhere to land in the partition — the R4 boundary max_ms 782 class. Each
# entry carries the whole-call wall, the chunk-scan sub-part, and the
# per-crossing cause census (demoted / promoted / halo evicts / re-entry
# flips / the synchronous generate_far calls) — so the next reader sees
# which term owns the tail instead of inferring it. INSTRUMENTATION ONLY:
# pure counters + one append at call end (the cap drops the oldest).
# The boundary arm reads crossing_seq / crossing_ring over its walk window.
const CROSSING_RING_CAP := 256
var crossing_seq := 0
var crossing_ring: Array = []
var crx_gen_far_sync := 0  # cumulative synchronous generate_far calls (the per-sweep delta is the census term)
# AC-0350: the band-bounded sweep's state. _stream_outside = the resident
# home-face columns OUTSIDE the stream set (w.r.t. the current recenter
# center) — maintained per recenter by the sweep's re-entry/exit branches
# (the stream-set flip set) and rebuilt when the stream-set signature
# (render radius / b1) changes; the bounded passes reach exactly the
# columns the old O(resident) walk reached (see recenter()).
# _real_demote_owed = the AC-0346 1→1 hop class: a column holding FULL
# (caved) data outside the real band — producible only by a full landing
# in the halo band (flagged at the threadgen/disk/sync landing sites), a
# sim-band (band0_r) shrink, or boot; the next recenter clears it with the
# SAME body the old walk's (iii) ran (a scan bound, not a behaviour change).
# _real_demote_full_sweep: the one-time legacy full walk on the first
# recenter (boot/load) and after any detected band0_r shrink.
var _stream_outside: Dictionary = {}
var _stream_outside_sig: Array = [-1, -1]
var _real_demote_owed: Dictionary = {}
var _real_demote_full_sweep := true
var _last_sweep_band0_r := band0_r

func _bd_log(cx: int, cz: int) -> void:
	build_dispatch_total += 1
	build_dispatch_log.append(Vector2i(cx, cz))
	if build_dispatch_log.size() > BUILD_DISPATCH_LOG_CAP:
		build_dispatch_log.pop_front()

func _ready() -> void:
	# AC-0270: the harness shortens the decay window deterministically.
	var _ldms := OS.get_environment("AWECRAFT_LEAFDECAY_MS")
	if _ldms != "":
		leaf_decay_min_ms = maxi(1, int(_ldms))
		leaf_decay_max_ms = maxi(1, int(_ldms))

	timing = OS.get_environment("AWECRAFT_TIMING") == "1"
	_picklog = OS.get_environment("AWECRAFT_PICKLOG") == "1"  # AC-0217
	_wprof_init()  # AC-0251: pre-allocate the per-stage pipeline timing ring
	# AC-0252: seed the med/low band boundary from the user setting (the
	# later Settings.apply_world re-applies it against the live radii).
	apply_low_start()
	# AC-0313: the tier-0 set (note_tier0_radius) is GONE — the real band
	# is taxi ≤ band0_r (the sim distance, applied via apply_world).
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
	# AC-0283 P2: the AweStarlight engine (gdext/src/starlight.cpp) — the
	# single relaxation queue that replaces the per-column re-flood + flush
	# wave. The tables are the pre-warmed Lighting att/glow (worker-safe
	# value copies — the engine dereferences no autoloads).
	star = AweStarlight.new()
	star.set_tables(Lighting._att, Lighting._glow)
	_tm_ctx = ChunkScript.make_ctx()
	_tm_ms_full = ChunkScript._merge_atlas()
	_low_ms_snap_dirty = true  # AC-0236 part 2: the low emit snapshot is stale (new atlas)
	_tm_ctx_atlas = Data.atlas_tex  # AC-0160: stamp for the _process staleness guard
	_pool_prewarm()  # AC-0247/AC-0248: the ring-sized pool prewarm (the recenter that follows a radius change tops up — _pool_top_up)
	threadmesh = true
	_tm_debug = OS.get_environment("AWECRAFT_TMDEBUG") == "1"
	print("THREADMESH on threadmesh=true pool=%d" % threadmesh_max)
	_recprobe = OS.get_environment("AWECRAFT_RECPROBE") == "1"
	var dr := OS.get_environment("AWECRAFT_DRAIN_MS")
	if dr != "" and dr.to_int() > 0:
		drain_budget_ms = dr.to_int()
	# AC-0340: the staged collision lane's per-frame cap (the DRAIN_MS
	# pattern — the harness A/B's tuning knob).
	var cl := OS.get_environment("AWECRAFT_COLLIDE_MS")
	if cl != "" and cl.to_int() > 0:
		collide_drain_budget_ms = cl.to_int()
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
	# AC-0332: the far-tier mesh floor (AC-0331's kernel) — harness env
	# preloads, the AWECRAFT_TM_HO / AWECRAFT_FOG_PCT pattern: written to
	# Settings.values WITHOUT save() so the arms never clobber the user's
	# cfg. AWECRAFT_YFLOOR=<0..24> (the chunks-below-sea scale) and
	# AWECRAFT_YFLOOR_ENABLED=<0|1> (the on/off axis). The boot derive
	# below runs AFTER these land.
	var yfe := OS.get_environment("AWECRAFT_YFLOOR_ENABLED")
	if yfe != "":
		Settings.values["yfloor_enabled"] = yfe.to_int() == 1
	var yfn := OS.get_environment("AWECRAFT_YFLOOR")
	if yfn != "":
		Settings.values["yfloor_chunks_below_sea"] = clampi(yfn.to_int(), 0, Settings.YFLOOR_MAX)
	note_yfloor()  # AC-0332: the boot derive (the live Settings after the preloads)
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
	# AC-0293: the 5x5 burst GROUP-task consumption is gone with the burst
	# (it was the only add_group_task caller — the "Pages in use … GroupE"
	# exit line dies with it); the generic poll drain above covers the
	# remaining in-flight TM/TG/IO tasks.
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
	if leaf_decay_enabled:
		_leaf_decay_tick()
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
	_mob_tick(_d)


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
# never into the 5-stage partition): the low-lane attach poll.
# AC-0336: the in-r / slab-wave / pick sub-stages are GONE (the in-r
# lane died at AC-0261; the WAVE/PICK brackets moved to WP_DRAIN with
# the dispatch at AC-0335 — they were never _wprof_added again).
const WP_LOW_POLL := 10
# AC-0283 P2: the AweStarlight engine step (budgeted relaxation + the
# settled-column drain). A DRAIN subset (bracketed inside the drain pass —
# it sums to <= DRAIN, never into the 5-stage partition).
const WP_STAR := 11
# AC-0337 step 0: the collision body work (the slab body derivation in
# chunk.gd _build_slab_collision, reached from BOTH _post_build_collision
# (the landing/apply passes — a HANDOFF/DRAIN subset) and
# build_dirty_slab_bodies (the staged drain — a DRAIN subset)). A SUB-STAGE
# like STAR/MESHATTACH: it accumulates where the work happens and never
# into the 5-stage partition, so the reconciliation stays exact. Before
# this stage the collision cost was only visible in the MISC residual and
# the batch counters (which count batches, not slabs).
const WP_COLLIDE := 12
const WP_STAGES := 13
const WP_RING := 180

# --- AC-0352: per-frame WORST-FRAME CAPTURE (instrument-ONLY) ---
# The WP_RING ring summarizes (p50/p95/max per stage over 180 frames) — the
# 549-719 ms-class worst frames of the R24 streaming storm show up as ONE max
# value and cannot be stage-attributed (AC-0348 attributed them only by
# EXCLUSION + the crossing ring). This capture keeps the worst-N frames over
# the threshold with their FULL stage split + the streaming state at that
# frame + the edit/remesh activity of a small window around it, so a stage
# that is slow because the queue is deep is distinguishable from one that is
# slow on its own. MAIN-THREAD-ONLY and PRE-ALLOCATED (the wprof discipline):
# the per-frame cost is a few subtractions and two array sizes (the activity
# row); the capture path (the one O(resident) in-radius loop) runs ONLY on
# over-threshold frames and AFTER the f1 stamp, so its cost never enters the
# measured frame total. It measures; it changes NO scheduling, pacing,
# ordering, or allocation behavior.
const WFC_THRESHOLD_US := 30000   # the capture threshold (the ticket's 30 ms)
const WFC_CAP := 256              # worst-N ring (bounded; a newcomer displaces the ring min)
const WFC_WIN := 8                # the edit-activity window (capture frame + preceding frames)
const WFA_RING := 64              # the per-frame edit-activity ring (holds the WFC_WIN history)

var wfc_ring: Array = []          # the capture entries (dicts, worst-N)
var wfc_total_n := 0              # frames over threshold since boot (incl. the load storm)
var _wfa_rows: Array = []         # WFA_RING rows [per-frame edit activity, dirty depth, remesh depth]
var _wfa_head := 0
var _wfa_ed := 0                  # last committed frame's cumulative perf_edit_dispatches
var _wfa_df := 0                  # ... perf_edit_defers
var _wfa_sy := 0                  # ... perf_edit_syncs

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
		"LOW_POLL", "STAR", "COLLIDE"]  # AC-0337 step 0: the collision sub-stage
	_wp_live = {}
	for j in range(WP_STAGES):
		_wp_live[_wp_names[j]] = _wp_stat[j]
	_wp_live["partition"] = ["DRAIN", "LOW", "HANDOFF", "IO", "RECENTER", "MISC"]
	_wp_live["substages"] = ["FACELIGHT", "RESCORE", "MESHATTACH", "LOW_POLL", "STAR", "COLLIDE"]
	_wp_live["occupancy"] = {"tg": 0, "tm": 0, "low": 0, "star": 0}
	_wp_live["misc_neg_max_us"] = 0
	_wp_scratch.resize(WP_RING)
	# AC-0352: pre-allocate the worst-frame capture ring + the edit-activity ring.
	wfc_ring.clear()
	wfc_total_n = 0
	_wfa_rows.clear()
	for i in range(WFA_RING):
		_wfa_rows.append([0, 0, 0])
	_wfa_head = 0
	_wfa_ed = 0
	_wfa_df = 0
	_wfa_sy = 0

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

# AC-0337 step 0: chunk.gd convenience for the collision sub-stage (the
# _post_build_collision bracket — the staged-drain side is bracketed in
# _col_drain_step below, where the WP_ constant is in scope anyway).
func _wprof_collide(us: int) -> void:
	_wprof_add(WP_COLLIDE, us)

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
	# AC-0352: the per-frame edit-activity row (the counter deltas since the
	# previous committed frame — the dispatches/defers/syncs fired IN this
	# frame, whatever stage they ran in) + the queue/remesh depths.
	var _wfa_row: Array = _wfa_rows[_wfa_head]
	_wfa_row[0] = maxi(0, (int(perf_edit_dispatches) - _wfa_ed) \
			+ (int(perf_edit_defers) - _wfa_df) + (int(perf_edit_syncs) - _wfa_sy))
	_wfa_row[1] = int(dirty_queue.size())
	_wfa_row[2] = star_light_pending_depth()
	_wfa_ed = int(perf_edit_dispatches)
	_wfa_df = int(perf_edit_defers)
	_wfa_sy = int(perf_edit_syncs)
	_wfa_head = (_wfa_head + 1) % WFA_RING
	# AC-0352: the worst-frame capture — AFTER the f1 stamp, so the capture
	# cost never enters the measured total.
	if int(_wp_cur[WP_FRAME]) > WFC_THRESHOLD_US:
		_wfc_capture()

# AC-0352: one stage of the just-committed row, in ms at 1 decimal.
func _wfc_ms(stage: int) -> float:
	return roundf(float(int(_wp_cur[stage])) / 1000.0 * 10.0) / 10.0

# AC-0352: capture the just-committed frame into the worst-N ring: the full
# stage split (five top stages + MISC + the six sub-stages), the streaming
# state (queue depth, tm/tg in-flight, low tasks, star pending, resident,
# in-radius present/built against the player chunk) and the re-mesh
# correlation fields (the cumulative perf_edit_* snapshots, the dirty_queue
# depth, the remesh-lane depth, and the per-frame dispatch/defer/sync
# ACTIVITY over the capture frame + the WFC_WIN preceding frames — the
# "small window" of the coordinator's addition: a dispatch that slows frame T
# fires in T or a few frames before, never after). Bounded worst-N: a
# newcomer displaces the ring's minimum, so the ring always holds the worst
# WFC_CAP frames over threshold since boot.
func _wfc_capture() -> void:
	wfc_total_n += 1
	var split := {
		"drain": _wfc_ms(WP_DRAIN), "low": _wfc_ms(WP_LOW), "handoff": _wfc_ms(WP_HANDOFF),
		"io": _wfc_ms(WP_IO), "recenter": _wfc_ms(WP_RECENTER), "misc": _wfc_ms(WP_MISC),
		"facelight": _wfc_ms(WP_FACELIGHT), "rescore": _wfc_ms(WP_RESCORE),
		"meshattach": _wfc_ms(WP_MESHATTACH), "low_poll": _wfc_ms(WP_LOW_POLL),
		"star": _wfc_ms(WP_STAR), "collide": _wfc_ms(WP_COLLIDE),
	}
	# The one O(resident) cost — the in-radius census (the player-chunk
	# square, the arm's own convention), run only on over-threshold frames.
	var pcx := int(_rec_player_pcx)
	var pcz := int(_rec_player_pcz)
	var rr := int(render_radius)
	var inr_present := 0
	var inr_built := 0
	for key in chunks:
		var c: Node3D = chunks[key]
		if absi(int(c.cx) - pcx) <= rr and absi(int(c.cz) - pcz) <= rr:
			inr_present += 1
			if c.mesh_built:
				inr_built += 1
	var act_win := 0
	var dirty_max := 0
	var remesh_max := 0
	for i in range(WFC_WIN + 1):
		var row: Array = _wfa_rows[(_wfa_head - 1 - i + WFA_RING) % WFA_RING]
		act_win += int(row[0])
		if int(row[1]) > dirty_max:
			dirty_max = int(row[1])
		if int(row[2]) > remesh_max:
			remesh_max = int(row[2])
	var entry := {
		"t_ms": int(Time.get_ticks_msec()),
		"ms": roundf(float(int(_wp_cur[WP_FRAME])) / 1000.0 * 10.0) / 10.0,
		"split": split,
		"state": {
			"queue": int(queue_size), "tm": int(threadmesh_inflight.size()),
			"tg": int(threadgen_inflight.size()), "low": int(_low_tasks.size()),
			"star": 0 if star == null else int(star.pending_cells()),
			"resident": int(chunks.size()), "inr_present": inr_present, "inr_built": inr_built,
		},
		"edit": {
			"dispatches": int(perf_edit_dispatches), "defers": int(perf_edit_defers),
			"syncs": int(perf_edit_syncs), "dirty_depth": int(dirty_queue.size()),
			"remesh_depth": star_light_pending_depth(),
			"act_window": act_win, "dirty_max_window": dirty_max,
			"remesh_max_window": remesh_max,
		},
	}
	if wfc_ring.size() < WFC_CAP:
		wfc_ring.append(entry)
	else:
		var min_i := 0
		for i in range(1, WFC_CAP):
			if float(wfc_ring[i]["ms"]) < float(wfc_ring[min_i]["ms"]):
				min_i = i
		if float(entry["ms"]) > float(wfc_ring[min_i]["ms"]):
			wfc_ring[min_i] = entry

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
	occ["star"] = 0 if star == null else int(star.pending_cells())
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
	_sw_frame += 1  # AC-0339: the settle-wait frame counter (before the idle return)
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
	# AC-0277: the recenter target LED the player (fast movement). If the
	# crossing stream has been quiet for AHEAD_FAST_MS without a new
	# crossing, snap the target back to the chunk under the player. The
	# snap is a SLOW recenter (dt >= AHEAD_FAST_MS) - it centers on the
	# player chunk and starts (or parks onto) a fresh walk there, and the
	# settle below then stands down (centers match).
	if _ahead_active and _last_cross_ms > 0 \
			and Time.get_ticks_msec() - _last_cross_ms >= AHEAD_FAST_MS \
			and (last_pcx != _rec_player_pcx or last_pcz != _rec_player_pcz):
		_ahead_active = false
		recenter(_rec_player_wx, _rec_player_wz, true)
	# AC-0277: stand down while the center still LEADS the player
	# (_ahead_active) — the snap-back below (AHEAD_FAST_MS quiet) recenters
	# to the player first; this settle must not lock the queue onto the
	# stale ahead center in between.
	# AC-0293: the spawn-fast term is gone with the burst — during the load
	# window the center equals the player chunk (a fresh spawn/continue
	# recenters to it), so the distance fact below is false anyway.
	if not _rec_pending and _last_recenter_ms > 0 \
			and Time.get_ticks_msec() - _last_recenter_ms > AHEAD_RING_DEBOUNCE_MS \
			and not _ahead_active \
			and (absi(last_pcx - _rec_center_pcx) + absi(last_pcz - _rec_center_pcz)) > 0:
		_rec_start_walk(last_pcx, last_pcz)
	# AC-0257 (instance cap): drain the DEFERRED column frees (the recenter
	# free batch is capped at stream_ho_cap/frame — the same per-frame
	# instance-work cap as the attach burst; a recenter over a full circle
	# used to detach the whole rim in one frame).
	_drain_deferred_free()
	# threadmesh_inflight keeps this running while mesh tasks are in flight
	# even when every bookkeeping list is drained (else the poll never runs).
	# AC-0283 P2: the engine's light work (the pending relaxation, the
	# settled-column drain, the remesh lane) keeps the frame active the way
	# the flush wave did.
	var star_work := star != null \
			and (not star_owed.is_empty() or not star_remesh.is_empty() or int(star.pending_cells()) > 0)
	if (not star_work) and fluid_dirty.is_empty() and queue_size == 0 and tex_refresh.is_empty() and threadmesh_inflight.is_empty() and _io_read_inflight.is_empty() and _io_write_inflight.is_empty() and _io_compact_inflight.is_empty() and not _rec_pending and _bl_want.is_empty() and _col_pending.is_empty() and dirty_queue.is_empty() and _deferred_free.is_empty():
		_wprof_end_frame(pf0)  # AC-0251: idle frame (all stages 0, MISC = total)
		return
	# AC-0283 P2: the fluid re-mesh arms the per-slab remesh lane (the
	# legacy full-column fluid re-mesh dispatch is retired — the lane paces
	# it; the star gate keeps the bake final).
	var fluid_marks: Array = []
	for key in fluid_dirty:
		var c = chunks.get(key)
		if c == null or (not c.mesh_built and c.high_stamps.is_empty()):
			continue
		fluid_marks.append([c, int(fluid_dirty[key][0]), int(fluid_dirty[key][1])])
	fluid_dirty = {}
	if not dirty_queue.is_empty():
		_dirty_drain()  # AC-0233: dirtyQueue drains first (1/frame), before the streaming work
	var pf1 := Time.get_ticks_usec()
	var fp0 := pf1
	var fp1 := Time.get_ticks_usec()
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
	# AC-0283 P2: the AweStarlight pass (a DRAIN subset — the WP_STAR
	# substage): the budgeted relaxation step, the settled-column drain
	# (last_eff publish + the per-slab E2 re-arm), the remesh lane, and the
	# fluid re-mesh arming. It runs BEFORE _drain_build_queue so the drain
	# dispatches see this frame's settle state.
	if star != null:
		_sw_remesh_max = maxi(_sw_remesh_max, star_light_pending_depth())  # AC-0339: the remesh lane's depth (the armed re-bake count), sampled per frame
		var _wps := Time.get_ticks_usec()
		_star_step()
		_wprof_add(WP_STAR, Time.get_ticks_usec() - _wps)
		_star_settled_drain()
		_star_remesh_drain()
		for fm in fluid_marks:
			var cc: Node3D = fm[0]
			var ckey := _key(int(cc.cx), int(cc.cz))
			for si in range(int(fm[1]), int(fm[2]) + 1):
				if int(cc.high_stamps.get(si, -1)) == int(cc.data_gen) and not bool(cc.flush_slabs.has(si)):
					_star_remesh_add(ckey, si)
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
		threadmesh_inflight.size(), queue_size, 0 if star == null else int(star.pending_cells())])
	if _prof_ring.size() > 120:
		_prof_ring.pop_front()

# AC-0283 P2: the light-idle predicate — the legacy light_dirty +
# light_pending emptiness the arm settle-waits used, expressed in the
# engine's own state: the owed drain is empty (every settled column
# published), the remesh lane is empty (no re-bake armed), and the
# relaxation queue is empty (the light gate closed everywhere).
func star_light_idle() -> bool:
	if star == null:
		return true
	return star_owed.is_empty() and star_remesh.is_empty() and int(star.pending_cells()) == 0

# The remesh lane's depth (the legacy light_pending.size() equivalent —
# the armed re-bake slab count the arm debug lines reported).
func star_light_pending_depth() -> int:
	if star == null:
		return 0
	var n := 0
	for k in star_remesh:
		n += int(star_remesh[k].size())
	return n

# AC-0283 P2: the AweStarlight live-light pass (the replacement for the
# per-column re-flood + the 1-column/frame flush wave).

# The budgeted relaxation step (design: the DRAIN clamp discipline — the
# wall-clock frame sample, clamped, sizes the budget; the steady state
# costs ~3 ms/frame, the loading window gets 30 ms).
func _star_step() -> void:
	var now_ms := Time.get_ticks_msec()
	var dt := minf(float(now_ms) - _star_last_t, DRAIN_DT_CLAMP_MS)
	_star_last_t = float(now_ms)
	if dt <= 0.0:
		dt = 16.67
	if int(star.pending_cells()) > 0:
		# AC-0339: drained-vs-pending census (instrumentation only — the
		# SAME step call, its return value [cells drained this frame] and
		# the queue depth at step start captured; star.step's budget logic
		# is untouched). The light budget is the other half of the settle
		# wait: the gate only passes once this queue drains.
		var sw_pend: int = int(star.pending_cells())
		var base_ms := LOAD_STAR_STEP_BUDGET_MS if loading_active else STAR_STEP_BUDGET_MS
		var budget_us: int = int(float(base_ms) * (dt / 16.67) * 1000.0)
		if budget_us < 1:
			budget_us = 1
		var sw_drained: int = int(star.step(budget_us))
		_sw_star_busy_frames += 1
		_sw_star_pending_max = maxi(_sw_star_pending_max, sw_pend)
		_sw_star_drained_max = maxi(_sw_star_drained_max, sw_drained)
		_sw_star_pending_sum += sw_pend
		_sw_star_drained_sum += sw_drained

# The settled-column drain: a column whose light gate (all 24 sections
# settled) has not been drained publishes its settled light (last_eff),
# bumps its eff_gen iff the eff actually changed (the face/eff cache dep),
# and re-arms the per-slab E2 wave on its built neighbors (replacing the
# flush + the _eff_landed landing cascade).
func _star_settled_drain() -> void:
	if star == null or star_owed.is_empty():
		return
	var done: Array = []
	for key in star_owed:
		var c = chunks.get(key)
		if c == null:
			done.append(key)
			continue
		var cx := int(c.cx)
		var cz := int(c.cz)
		if not star.column_settled(cx, cz):
			continue
		var new_eff: Dictionary = star.column_light_dict(cx, cz)
		if new_eff.is_empty():
			done.append(key)
			continue
		var old_arr: PackedByteArray = c.last_eff.get("arr", PackedByteArray())
		var new_arr: PackedByteArray = new_eff.get("arr", PackedByteArray())
		var changed: bool = old_arr.size() != new_arr.size() or old_arr != new_arr
		c.last_eff = ChunkScript._eff_store(new_eff)
		if changed:
			c.eff_gen += 1
			_star_e2_rearm(c, cx, cz, old_arr, new_arr)
		done.append(key)
	for key in done:
		star_owed.erase(key)

# The per-slab E2 wave (the legacy E2 re-targeted to light-relevant
# change): a settled column's boundary frame on each built neighbor's
# shared face is compared per stamped slab window (the 2-row overhang of
# the slab's bake box) — a changed/nonzero frame re-arms that slab's
# re-mesh (its margin bakes the neighbor's light). The frame compare is
# C++ (star.frame_diff) — the churn bound: a zero-frame window is a
# provable no-op (no re-arm, no work).
func _star_e2_rearm(c: Node3D, cx: int, cz: int, old_arr: PackedByteArray, new_arr: PackedByteArray) -> void:
	var first: bool = old_arr.is_empty()
	var h := Data.HEIGHT
	var offs: Array = [[1, 0], [-1, 0], [0, 1], [0, -1]]
	for o in offs:
		# AC-0283 P3: never arm a HALO (unseeded) built neighbor — its
		# payload can never capture (column_seeded false) and the arm
		# would wedge the remesh lane forever (the stored high is DORMANT:
		# the 4x4 avg owns the halo draw; a re-entry promotes the column
		# and the remesh arm re-bakes its stored high on the new light).
		var ndx := int(cx + int(o[0])) - last_pcx
		var ndz := int(cz + int(o[1])) - last_pcz
		if not _is_real_col(ndx, ndz):
			continue
		var nkey := _key(cx + int(o[0]), cz + int(o[1]))
		var nc = chunks.get(nkey)
		if nc == null or not bool(nc.mesh_built):
			continue
		for si in nc.high_stamps.keys():
			var y0 := maxi(0, int(si) * 16 - 2)
			var y1 := mini(h - 1, int(si) * 16 + 17)
			var v: int = star.frame_diff(old_arr, new_arr, int(o[0]), int(o[1]), y0, y1)
			if v != 0:
				if first:
					perf_e2_first_marks += 1
				else:
					perf_e2_marks += 1
				_star_remesh_add(nkey, int(si))

# The remesh lane: star_remesh (key -> {si}) drains paced (one slab per
# key per frame — the per-key in-flight dedup paces the rest; 2 keys/frame
# steady, 8 in the loading window). A slab re-bakes from the engine's
# CURRENT settled light (the dispatch's star payload) and its landing
# re-sets the settled-bake mark (flush_slabs) — construction, not a
# re-arm (no loop).
func _star_remesh_drain() -> void:
	if star == null or star_remesh.is_empty() or edit_inflight_count > 0:
		return
	var cap := LOAD_STAR_REMESH_KEYS_PER_FRAME if loading_active else STAR_REMESH_KEYS_PER_FRAME
	var built := 0
	for key in star_remesh.keys():
		if star_remesh[key].is_empty():
			star_remesh.erase(key)  # every entry was erased (unstamped /
			# re-settled since the arm) — drop the zombie key or it eats a
			# cap slot forever and starves the real work
			continue
		var c = chunks.get(key)
		if c == null:
			star_remesh.erase(key)
			continue
		var cx := int(c.cx)
		var cz := int(c.cz)
		# AC-0283 P3: an UNSEEDED column's slabs can never dispatch (the
		# payload gate needs the seed) — drop the key outright (a
		# re-entry re-arms it on the promotion re-seed). Defensive: the
		# E2 skip above already keeps these out.
		if star != null and not _is_real_col(cx - last_pcx, cz - last_pcz):
			star_remesh.erase(key)
			continue
		var sis: Array = star_remesh[key].keys()
		sis.sort()
		for si in sis:
			si = int(si)
			if int(c.high_stamps.get(si, -1)) != int(c.data_gen):
				star_remesh[key].erase(si)  # the build lane owns it (its landing re-bakes)
				continue
			if bool(c.flush_slabs.has(si)):
				star_remesh[key].erase(si)  # re-settled since the arm (no-op)
				continue
			if built >= cap:
				break  # the budget spent (a deferred key spent nothing — it retries, the healthy keys behind it keep their slots)
			if _mesh_dispatch_hslab(c, cx, cz, si, {}, true):
				star_remesh[key].erase(si)
				built += 1
				break  # one slab per key per frame
			break  # deferred (gate / cap / dedup) — the entry retries next frame
	if built > 0:
		perf_flush_frames += 1

# Arm a slab for the remesh lane (idempotent) + pop its settled-bake mark
# (the current bake is no longer settled — the band re-entry hides it
# until the re-bake lands; the slab itself keeps showing, the edit /
# margin behavior).
func _star_remesh_add(key: String, si: int) -> void:
	if not star_remesh.has(key):
		star_remesh[key] = {}
	star_remesh[key][si] = true
	var c = chunks.get(key)
	if c != null:
		c.flush_slabs.erase(si)

# Seed a NEW column into the engine (the data landing): all 24 sections
# top-down from the flat column data (the seam is always satisfiable),
# then the column joins the owed drain (its light gate settles in a few
# step frames).
func _star_seed_column(c: Node3D) -> void:
	if star == null:
		return
	var cx := int(c.cx)
	var cz := int(c.cz)
	var key := _key(cx, cz)
	var flat: PackedByteArray = ChunkIO.io_cpp().slabs_flat(c.data)
	# AC-0286: the single-flood probe — count + cost every whole-column
	# re-seed (the promotion's acceptance is exactly one per residency).
	var _t0s := Time.get_ticks_usec()
	star.seed_column(cx, cz, flat)
	var _t1s := Time.get_ticks_usec()
	star_seed_count[key] = int(star_seed_count.get(key, 0)) + 1
	star_seed_us[key] = int(star_seed_us.get(key, 0)) + (_t1s - _t0s)
	star_owed[key] = true

# Re-land CHANGED slabs of an existing column (a regen merge / an
# evict-reload with edits since save): on_section_data per slab —
# identical data is a no-op (the deterministic regen re-lands with ZERO
# churn), a diff runs the two-phase re-seed (the engine un-settles the
# affected box) and the late-landing contract applies (hide + un-settle +
# re-arm).
func _star_reseed_column(c: Node3D, sis: Array) -> void:
	if star == null:
		return
	var cx := int(c.cx)
	var cz := int(c.cz)
	var io: Variant = ChunkIO.io_cpp()
	var changed := false
	var ok := true
	for si in sis:
		var sids: PackedByteArray = io.slab_flat(c.data[int(si)])
		if sids.is_empty():
			continue
		var r: Dictionary = star.on_section_data(cx, cz, int(si), sids)
		if bool(r.get("changed", false)):
			changed = true
		if not bool(r.get("ok", false)):
			# the seam is not satisfiable (a partially-seeded column —
			# unreachable live; the atomic whole-column re-seed heals it)
			ok = false
			changed = true
			break
	if not ok:
		star.seed_column(cx, cz, io.slabs_flat(c.data))
	star_owed[_key(cx, cz)] = true
	if changed:
		_star_late_invalidate(c, sis)

# AC-0283 P3: DEMOTE (real -> halo) at recenter — the engine evicts the
# column (free the nibbles; the live set is the real band only) and the
# queued owed/remesh entries go with it. The column's draw is the 4x4
# avg + heightmap sky from here; a re-entry promotes it again (the
# re-seed is the single full flood per column).
func _star_halo_evict(c: Node3D, key: String) -> void:
	if star == null:
		return
	star.evict_column(int(c.cx), int(c.cz))
	star_owed.erase(key)
	star_remesh.erase(key)
	star_halo_evicts += 1

# AC-0283 P3: PROMOTE (halo -> real) at recenter — seed the engine from
# the column's current data (one full flood per column; the column then
# settles through the normal owed drain and its owed slabs re-bake on
# the settled light — no unlit frame, the halo mesh shows until the
# settled high lands). A no-op when the column is already settled
# (defensive: a demote always evicts, so a promote sees an unseeded
# column; the guard keeps a re-crossing jitter from re-seeding).
func _star_halo_promote(c: Node3D, key: String) -> void:
	# AC-0284b: a FAR column holds no slabs — seeding its all-null data is a
	# light hole, and the owed full regen's per-slab re-seed would scan its
	# sky against the stale all-air seam left here (stone cells keep sky 15;
	# the deep-pocket glow misses). The regen seeds the column whole instead.
	if star == null or c.data.is_empty() or c.far:
		return
	if star.column_settled(int(c.cx), int(c.cz)):
		return
	_star_seed_column(c)
	star_halo_promotes += 1

# The late-landing contract (binding): data changed inside a settled
# region. OWN column: the affected stamped slabs hide, lose their
# settled-bake mark, and re-arm (the build lane re-owns them through
# data_gen; they show again after the re-settled re-bake lands).
# NEIGHBORS: no hide (the E2 margin behavior — the old margin was valid
# when it was baked; the re-mesh picks up the new light) — only the
# re-arm over the changed sections' block range.
# AC-0286: origin tags the counter split (the promotion's retain-swap
# branch never HIDEs — "promo" must stay 0; the regen-merge landing is
# the only live caller today, origin "regen").
func _star_late_invalidate(c: Node3D, sis: Array, origin := "regen") -> void:
	var cx := int(c.cx)
	var cz := int(c.cz)
	var si_min := 99
	var si_max := -1
	for si in sis:
		si_min = mini(si_min, int(si))
		si_max = maxi(si_max, int(si))
	if si_max < 0:
		return
	for si in range(0, mini(23, si_max + 1) + 1):
		if int(c.high_stamps.get(si, -1)) == int(c.data_gen) and bool(c.flush_slabs.has(si)):
			c.flush_slabs.erase(si)
			c.high_slab_visible(si, false)
			star_late_landings += 1
			if origin == "promo":
				star_late_landings_promo += 1
			_star_remesh_add(_key(cx, cz), si)
	_star_update_light_settled(c)
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			if dx == 0 and dz == 0:
				continue
			var nkey := _key(cx + dx, cz + dz)
			var nc = chunks.get(nkey)
			if nc == null or not bool(nc.mesh_built):
				continue
			for si in range(maxi(0, si_min - 1), mini(23, si_max + 1) + 1):
				if int(nc.high_stamps.get(si, -1)) == int(nc.data_gen) and bool(nc.flush_slabs.has(si)):
					nc.flush_slabs.erase(si)
					_star_remesh_add(nkey, si)

# The edit re-arm (set_block / set_fluid / the apply-edits wave): the
# engine's on_edit already un-settled + re-healed the light (the 3x3 x/z
# box x sections 0..si+1 two-phase, with the landing-order healing for
# unseeded faces). Here the MESH side: the own column's affected slabs
# (the sky carry below + the block range — the build lane re-owns them
# through data_gen; pop the settled-bake mark so a band re-entry hides
# them until the re-bake) and the 8 neighbors' slabs in the changed
# sections' block range (remesh only — no hide, the E2 margin behavior).
func _star_rearm_edit(c: Node3D, cx: int, cz: int, si: int) -> void:
	if star == null:
		return
	var ckey := _key(cx, cz)
	for si2 in range(0, mini(23, si + 1) + 1):
		if int(c.high_stamps.get(si2, -1)) == int(c.data_gen) and bool(c.flush_slabs.has(si2)):
			c.flush_slabs.erase(si2)
			_star_remesh_add(ckey, si2)
	_star_update_light_settled(c)
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			if dx == 0 and dz == 0:
				continue
			var nkey := _key(cx + dx, cz + dz)
			var nc = chunks.get(nkey)
			if nc == null or not bool(nc.mesh_built):
				continue
			for si2 in range(maxi(0, si - 1), mini(23, si + 1) + 1):
				if int(nc.high_stamps.get(si2, -1)) == int(nc.data_gen) and bool(nc.flush_slabs.has(si2)):
					nc.flush_slabs.erase(si2)
					_star_remesh_add(nkey, si2)

# The chunk-level settled flag (kept for the band re-entry + the save
# guard fallbacks): all STAMPED slabs carry a settled-bake mark.
func _star_update_light_settled(c: Node3D) -> void:
	var all := true
	for si in c.high_stamps.keys():
		if not bool(c.flush_slabs.has(int(si))):
			all = false
			break
	c.light_settled = all

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
		# AC-0297: star-native tex refresh — the rebuild rides the SETTLED
		# STAR payload (the remesh lane's own capture), not c.last_eff.
		# false = waiting (in-flight dedup / the settle gate): re-queue so
		# the chunk is rebuilt once that lands.
		if not _tex_refresh_dispatch(c, int(c.cx), int(c.cz)):
			tex_refresh.push_back(key)
		done += 1


# AC-0297: the tex-refresh rebuild, star-native. The texture swap changed
# the TABLES (the worker ctx / the face-color cache / the merge atlas) —
# the light did not (the engine owns it), so the rebuild is the column's
# SETTLED star payload: the remesh lane's own capture (one full-column
# window), epoch-checked at landing (the full-landing lver gate — a
# concurrent edit datadrops the bake and the lane re-bakes with the
# refreshed ctx). Unseeded (demoted / halo) columns DROP: the promotion
# re-bake (the recenter's stamped-slab re-arm) re-bakes the stored high
# from the settled payload on the refreshed ctx. The HALO side needs no
# payload at all: the 4x4 avg emit (h_avg_emit) re-runs with the new face-
# color cache through the low lane's re-lower (refresh_textures ->
# _low_reset_all). The c.last_eff classic dispatch stays for the
# star==null test arms only.
func _tex_refresh_dispatch(c: Node3D, cx: int, cz: int) -> bool:
	if star == null:
		return _mesh_dispatch(c, cx, cz, c.last_eff, false)
	if not star.box_settled(cx, cz, -1, 24):
		return false  # an edit is still settling — the re-queue retries after
	var pl: Dictionary = star.slab_light_payload(cx, cz, 0, maxi(0, int(c.top) >> 4))
	if not bool(pl.get("ok", false)):
		return true  # unseeded (demoted / halo) — the promotion re-bake owns it
	pl["star"] = true
	pl["lver"] = star.box_epochs(cx, cz, -1, 24)
	return _mesh_dispatch(c, cx, cz, pl, true, true, false, false)

# --- AC-0178: loading window (first spawn / render-distance change) --------

# Entry. No-op when AWECRAFT_LOADBYPASS=0 (the legacy spread drain). Raises
# the in-flight caps + drain budgets (each site checks loading_active) and
# shows the screen. Target = the SIM TAXI DIAMOND (AC-0313 clause 4 as
# CORRECTED: every column with taxi(dx,dz) <= band0_r = sim — 41 columns at
# sim 4; the user's "instead of 3x3 let's do sim taxi distance") — built
# by normal streaming, the load-screen gate.
func start_loading(title: String) -> void:
	if not loading_bypass:
		return
	loading_active = true
	_loading_target = _loading_band_count()

	if _loadlog_on:
		print("LOADLOGPOOL cores=%d tg=%d tm=%d" % [OS.get_processor_count(), threadgen_max, threadmesh_max])
		_load_wms_sum = 0
		_load_wms_n = 0
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

# AC-0261 (AC-0263, AC-0283 P3): the loading target is the REAL band
# (taxi ≤ band0_r) — the only region that ever gets a full mesh. The
# halo band (band0_r, render_radius) fills in via the disc-ordered slab
# wave while the player plays (the normal streaming experience); waiting
# for it would stall the load on work the streaming loop already owns.
func _high_band_count() -> int:
	var n := 0
	for dx in range(-band0_r, band0_r + 1):
		for dz in range(-band0_r, band0_r + 1):
			if absi(dx) + absi(dz) <= band0_r:
				n += 1
	return n


func _high_band_meshed() -> int:
	var n := 0
	for dx in range(-band0_r, band0_r + 1):
		for dz in range(-band0_r, band0_r + 1):
			if absi(dx) + absi(dz) > band0_r:
				continue
			var c = chunks.get(_key(last_pcx + dx, last_pcz + dz))
			if c != null and c.mesh_built:
				n += 1
	return n


# AC-0313 (user decision B, the load-screen gate; clause 4 as CORRECTED —
# the user's "instead of 3x3 let's do sim taxi distance"): the LOAD
# WINDOW's target is the SIM TAXI DIAMOND around the load anchor — every
# column with taxi(dx,dz) <= band0_r (= sim), 41 columns at sim 4 — built
# by the NORMAL streaming machinery (drain + workers, full columns
# inside-out), not by any special pass. The window closes the moment those
# 41 are mesh_built and the player activates only after (main.gd
# start_game / _continue_slot await the same condition via
# _await_sim_band) — the simband wall IS the load->activation wall.
# Everything after is normal streaming (the pools keep running behind the
# closed window). The first run's 3x3 target (and the original clause-4
# "9 spawn chunks" text) predates the user's answer and is gone; the
# 3x3 sits at taxi ≤ 2, the innermost, so it builds first by the
# (taxi, layer) order anyway — the diamond is the real-band core.
func _loading_target_col(dx: int, dz: int) -> bool:
	return absi(dx) + absi(dz) <= band0_r


func _loading_band_count() -> int:
	var n := 0
	for dx in range(-band0_r, band0_r + 1):
		for dz in range(-band0_r, band0_r + 1):
			if _loading_target_col(dx, dz):
				n += 1
	return n


func _loading_band_meshed() -> int:
	var n := 0
	for dx in range(-band0_r, band0_r + 1):
		for dz in range(-band0_r, band0_r + 1):
			if not _loading_target_col(dx, dz):
				continue
			var c = chunks.get(_key(last_pcx + dx, last_pcz + dz))
			if c != null and c.mesh_built:
				n += 1
	return n


# AC-0261 (AC-0283 P3): true when no slab of the HALO band (band0_r,
# render_radius) is still owed to the slab wave (every data slab holds
# its low or is all-air). The drain-wait predicate (loading arms /
# harness).
func band_drained() -> bool:
	for key in chunks:
		var c: Node3D = chunks[key]
		var taxi := absi(int(c.cx) - last_pcx) + absi(int(c.cz) - last_pcz)
		if taxi <= band0_r or taxi >= render_radius:
			continue
		if c.data.is_empty():
			continue
		# AC-0263 spec (keep-all-LOD): a meshed wave-band column is a
		# demoted column - its pending lows still count as owed (the
		# probe below decides; a fully flipped column owes nothing).
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
		_loading_target = _loading_band_count()
	var m := _loading_band_meshed()
	if _loadlog_on:
		if _loadlog_t0 == 0:
			_loadlog_t0 = Time.get_ticks_msec()
		if Time.get_ticks_msec() >= _loadlog_next_ms:
			_loadlog_next_ms = Time.get_ticks_msec() + 1000
			print("LOADLOG t=%d pct=%.1f meshed=%d/%d tm=%d tg=%d io=%d gen=%d q=%d dnbs=%d ddedup=%d dstale=%d dcap=%d rfail=%d keys=%d wms_avg=%.0f wms_n=%d" % [
				Time.get_ticks_msec() - _loadlog_t0,
				100.0 * float(m) / maxf(1.0, float(_loading_target)),
				m, _loading_target, threadmesh_inflight.size(), threadgen_inflight.size(), disk_reads, gen_count, queue_size, hslab_defer_nbs, hslab_defer_dedup, hslab_stale_key_n, _tm_capdrop, load_phase1_ready_fail, _tm_inflight_keys.size(), float(_load_wms_sum) / maxf(1.0, float(_load_wms_n)), _load_wms_n])
	if _loading_screen != null:
		_loading_screen.update_progress(m, _loading_target, disk_reads, gen_count)
	# AC-0313 (user decision B; clause 4 as CORRECTED): the window closes
	# the moment the LOAD TARGET (the SIM TAXI DIAMOND, taxi <= band0_r)
	# is meshed - the pools keep running: the loading screen waits until
	# the whole sim band around spawn is built and then it's normal
	# streaming. Waiting for the pools to drain
	# here would never fire (phase 2 keeps
	# the TG pool warm for the rest of the circle, and phase 1 keeps
	# dispatching the outer band - the whole point of the early close).
	# stop_loading() drops the caps back to steady state, so the rest
	# streams at the normal trickle pace.
	if m >= _loading_target:
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
		# other column. AC-0293: the startup burst that used to "carry the
		# spawn anti-fall" is retired — the anti-fall is the AC-0313
		# clause-4 load gate (the SIM TAXI DIAMOND meshed by normal
		# streaming before the player activates).
		if _io_read_enqueue(cx, cz, _key(cx, cz), true):
			# AC-0164: disk-first off the main thread — file read + decode
			# on a worker; the data lands in _io_read_handoff (edits
			# applied there, provenance marked when it LANDS).
			return 0
	# AC-0152 (AC-0263): sync gen is GONE entirely — every column (the
	# spawn chunk included) threadgens through the identical handoff
	# (data/init_fl/edits, stale-drop, dedup). AC-0082's spawn contract
	# rides the normal data pass + the AC-0313 clause-4 load gate (AC-0293:
	# the 5x5 startup burst that used to carry it is retired). The sync
	# tail below survives only for the threadgen-less fallback (threadgen
	# false = the pre-pool dev path that no shipped build uses).
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
	c.no_caves = false
	# AC-0346/AC-0350: the same 1→1 hop OWE as the threadgen handoff (the
	# sync fallback is the threadgen-off dev path — identical landing
	# semantics).
	if not c.far and not _is_real_col(cx - last_pcx, cz - last_pcz) \
			and in_stream_set(cx - last_pcx, cz - last_pcz):
		_real_demote_owed[_key(cx, cz)] = true
	_pool_touch()  # AC-0217: sync data landed on a queued entry
	_banana_register(cx, cz, gres["fruits"])
	gen_count += 1
	_apply_edits_to_chunk(c)
	_apply_pending_leaf_decay(c)  # AC-0270: restore the saved timers
	# AC-0283 P2 (P3): the engine seed (post-edits data) — REAL band only
	# (the halo never seeds; a halo column that later promotes seeds at
	# the recenter crossing with its current data).
	if star != null and _is_real_col(int(c.cx) - last_pcx, int(c.cz) - last_pcz):
		_star_seed_column(c)
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
# AC-0284b: the skip flag is now the FAR flag — 0 = full, 2 = FAR (h-only:
# no slabs at all, just the far payload). The 284a value 1 (the slab-skip
# fill) is no longer produced here: nothing enqueues it in-game — it
# survives in the C++ as the farab A/B reference. Both rules below (the
# halo band + the offscreen collar) produce far data: the offscreen collar
# is never meshed, and its save payload shrinks ~100x (a later load in
# the real band hits the same full-regen trigger as a halo column).
func _gen_skip_flag(cx: int, cz: int) -> int:
	var dx := cx - last_pcx
	var dz := cz - last_pcz
	# AC-0284a (AC-0284b: h-only; AC-0312 all draw tiers; AC-0346 TOTAL):
	# EVERY tier beyond the real band is far-generated: the h-only
	# payload's draws (the materialized skip fill / the h_avg emits) never
	# show caves; the umbrella marker (no_caves) rides the column so a
	# real-band landing schedules the full regen. Taxi-only rule (no
	# frustum test — the far representation IS the draw for these bands).
	# Tier-0 columns are REAL (full fidelity) — never far. AC-0346: the
	# check is TOTAL — tier 4 (data-only, past the render edge) is far
	# too. The old `< 4` bound let a rim column fall through to the
	# band_of / offscreen-collar rule below, where the outermost taxi ring
	# (band_of 1) returned 0 = FULL and the collar/ring (band_of 3)
	# returned 0 whenever the column was inside the camera frustum — a
	# data-only column generated FULL (caves and all), and the 1 -> 1
	# reband hop was a no-op, so the data rode at band A indefinitely
	# (the AC-0312 violation behind the AC-0334 halo red).
	var _lt := _lod_tier_of(dx, dz)
	if _lt > 0:
		return 2
	var b := band_of(dx, dz)
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
			return 2  # AC-0284b: the collar is never meshed — far data
	return 0


# Returns true when the gen is actually enqueued (false = deduped or
# cap-dropped — the caller of an OWED regen (the _far_promo_owed retry
# below) uses that to know the retry is needed; the data pass callers
# ignore it — their re-pick self-heals).
func threadgen_enqueue(cx: int, cz: int, key: String, inst: int, regen: bool = false, colgen: int = -1) -> bool:
	if _tg_inflight_keys.has(key):
		_tg_dedup += 1
		return false
	if threadgen_inflight.size() >= threadgen_max:
		_tg_capdrop += 1
		if _tg_debug:
			print("TGEN CAPDROP %d,%d inflight=%d" % [cx, cz, threadgen_inflight.size()])
		return false
	var skipf := 0 if regen else _gen_skip_flag(cx, cz)  # AC-0216/0284b (0 = full density, 2 = far h-only)
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
	return true

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

# AC-0293: the burst worker (_startup_gen_worker) and its main-thread apply
# pass (_startup_gen_apply, incl. the dead-slot self-heal) are RETIRED —
# the 5x5 group burst is gone; spawn/recenter data lands through the normal
# threadgen handoff (threadgen_handoff) like every other column.

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
			# AC-0284b: a far (h-only) result is a 3-elem resl (the payload
			# rides [2]); the handoff consumes the shape.
			if res == null or not (res is Array) or (int(res.size()) != 2 and int(res.size()) != 3):
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

# AC-0284b: consume the FAR (h-only) landing — resl[2] = {h, bm, top}
# (true iff it is one). Stamps the payload on the column (far_hmax = the
# max H, the low dispatch's deep-cell guard for the ore precompute). The
# caller stamps the umbrella (no_caves) from the skip flag — a far column
# is cave-less by representation.
func _gen_far_stamp(c: Node3D, resl: Array) -> bool:
	if resl == null or int(resl.size()) < 3 or not (resl[2] is Dictionary):
		return false
	var fp: Dictionary = resl[2]
	var fh: PackedByteArray = fp.get("h", PackedByteArray())
	if fh.size() != 512:
		return false
	c.far = true
	c.far_h = fh
	c.far_biome = fp.get("bm", PackedByteArray())
	c.far_top = fp.get("top", PackedByteArray())
	var mh := 0
	for i in range(0, 512, 2):
		var v := int(fh[i]) | (int(fh[i + 1]) << 8)
		if v > mh:
			mh = v
	c.far_hmax = mh
	return true

func threadgen_handoff(e: Dictionary, resl: Array) -> void:
	# AC-0203 recenter fix: resl = [data_slabs, fl_slabs] (worker-palettized
	# — the flat column never lands on the main thread). AC-0284b: a far
	# (h-only) landing is [all-null slabs, all-null fl, far payload].
	if resl == null or (int(resl.size()) != 2 and int(resl.size()) != 3) or not (resl[0] is Array):
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
	# AC-0284b: captured BEFORE the far stamp below — the far->full regen
	# seeds the engine column WHOLE (see the re-seed branch).
	var was_far: bool = is_regen and c.far
	if is_regen:
		var ds: Array = resl[0]
		if ekeep.is_empty():
			# AC-0284a: a FULL regen (the empty keep mask) replaces the
			# column whole — the nulls above the top included. A per-slab
			# merge would keep a no-caves column's solid top slabs when
			# the full regen's surface (he < H, a cave-opened top) ends
			# in a lower slab.
			c.data = ds
		else:
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
	c.no_caves = int(e["args"][5]) != 0
	# AC-0284b: the far (h-only) landing stamps the payload (no slabs at
	# all — the resl[0] all-null array IS the column); ANY full landing
	# clears it — the full regen replaces the column whole, the 284a
	# no-caves-slab merge fix generalized (the payload goes with the
	# slabs it replaced).
	if not _gen_far_stamp(c, resl):
		c.clear_far()
	# AC-0346/AC-0350: a FULL landing on a column OUTSIDE the real band (the
	# mid-regen landing after the exit demote) is the 1→1 hop class — the
	# bounded sweep never visits it (not within K of any edge); OWE the
	# demote so the next recenter clears it with the same body the old
	# walk's (iii) ran. Out-of-set landings are never flagged: the free
	# logic (vi) frees such a column FULL (the save keeps the full form) —
	# the old sweep's (iii) only ever ran in-set.
	if not c.far and not _is_real_col(tcx - last_pcx, tcz - last_pcz) \
			and in_stream_set(tcx - last_pcx, tcz - last_pcz):
		_real_demote_owed[_key(tcx, tcz)] = true
	_banana_register(tcx, tcz, gres["fruits"])
	gen_count += 1
	chunk_origin[e["key"]] = "gen"  # AC-0155
	_apply_edits_to_chunk(c)
	_apply_pending_leaf_decay(c)  # AC-0270: restore the saved timers
	# AC-0283 P2 (P3): seed the engine (AFTER the edits apply — the engine
	# seeds the post-edit data): a new column seeds all 24 sections
	# top-down; a regen merge re-seeds the replaced slabs by diff
	# (identical data = no-op = zero churn — the deterministic regen
	# guarantee). REAL band only — the halo never seeds (the
	# unseeded-tolerant box gate settles the edge against the halo
	# neighbors; a promoting column seeds at the recenter crossing).
	if _is_real_col(tcx - last_pcx, tcz - last_pcz):
		if is_regen:
			var dsr: Array = resl[0]
			var rsis: Array = []
			for si in range(c.data.size()):
				if si < int(dsr.size()) and dsr[si] is Dictionary:
					rsis.append(si)
			if was_far:
				# AC-0284b: the far->full regen replaces the column whole —
				# the engine column is absent or a stale ALL-AIR seed (any
				# pre-regen seed of the far column's null slabs is a light
				# hole). A per-slab re-seed would scan each slab's sky
				# against the stale all-air sections ABOVE the data slabs
				# (stone cells keep sky 15; the deep-pocket glow misses).
				# Re-seed the whole column top-down: the seam is
				# satisfiable (the null slabs above the top are air).
				# AC-0286: the RETAIN-SWAP branch (the promotion never
				# takes the late-landing HIDE path — no hide/un-settle of
				# the existing slabs): the far low (the correctly-lit
				# 4x4-avg mesh) keeps showing while the full-data slabs
				# build, and each slab's landing flips it (high on, low
				# off) atomically. The one whole-column re-seed above is
				# the promotion's ONLY engine flood; the slabs' builds
				# ride the settled-payload gate (the remesh lane's own
				# box_settled capture — "never show an unlit slab" holds
				# because the gate makes every bake final at dispatch).
				_star_seed_column(c)
				var _pk := _key(tcx, tcz)
				promo_land_count[_pk] = int(promo_land_count.get(_pk, 0)) + 1
				promo_land_ms[_pk] = Time.get_ticks_msec()
				# AC-0286: arm the promotion burst (the conversion
				# bypasses the lane's queue score — _promo_build_step).
				_promo_build[_pk] = true
			else:
				_star_reseed_column(c, rsis)
			# AC-0284b: a FAR column promoted into the real band looks
			# mesh-COMPLETE to the high probe (top < 0 — no slabs), so the
			# crossing's re-queue (mesh_built false) never fires and the
			# owed full regen lands on a column nobody owes a high build:
			# the probe goes pending (real slabs, no stamps at the new
			# data_gen) and the stale mesh_built bool hides it (the
			# AC-0278 re-queue fires only on a recenter crossing). Re-
			# derive mesh_built from the probe and re-queue — the same
			# contract as the crossing; the far low mesh shows meanwhile
			# (no unlit frame).
			c.mesh_built = _hslab_best_pending(c) < 0
			_hslab_probe_invalidate(c)
			if not c.mesh_built and queued_keys.get(key) != "build":
				_enqueue_build(tcx, tcz)
		elif not c.far:
			# AC-0284b: a FAR landing in the real band (a recenter crossed
			# it in flight) seeds NO air hole — the crossing's owed full
			# regen lands behind it and seeds the column whole (was_far).
			_star_seed_column(c)
		elif c.far and c.no_caves:
			# AC-0286: a FAR landing ALREADY inside the real band (the
			# gen queue lagged the crossing — the recenter's crossing
			# check found no data yet, the disk-load path is for saves).
			# The crossing's owed never fired: OWE it here (the owed
			# step's retry contract — one accepted full regen per
			# residency; a mid-regen demote still lands the data and
			# the re-entry seeds it). Without this the column would sit
			# far in the sim band forever (the low-detail patch that
			# never upgrades).
			_far_promo_owed[key] = true
	_tg_handoff += 1
	_pool_touch()  # AC-0217: queued entry's data landed (pool membership flipped)
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
		# AC-0312: band B (tier 2) is the 8x8 avg; band C (tier 3) the
		# 4x4 (the tier values moved — the grid pick follows them).
		var grid := 8 if int(entry.get("tier", 1)) == 2 else 4
		# AC-0283 P3: the halo's per-cell heightmap sky (empty on the
		# legacy real-band / battery path — the emit's all-bright default).
		var sky: PackedByteArray = entry.get("sky", PackedByteArray())
		# AC-0312: the water exception's rect — Data.atlas_rects["5"].top
		# + the atlas pixel size, snapshotted in the entry's ms (the
		# avg emit's water surface: the water-topped cell's top face
		# wears the real translucent water material). -1 / 0.0 = no
		# atlas (the surface is skipped — the no-atlas fallback). Both
		# emits (the far h_avg + the slab low_avg) share the tail, so
		# the farab A/B identity holds WITH the water surface.
		var ms_w: Dictionary = entry.get("ms", {})
		var plain_w = ms_w.get("plain", {})
		var w5 = plain_w.get("5", {}) if plain_w is Dictionary else {}
		if not (w5 is Dictionary):
			w5 = {}
		var wtop_r = w5.get("top", [])
		var wtlx := int(wtop_r[0]) if wtop_r.size() == 2 else -1
		var wtly := int(wtop_r[1]) if wtop_r.size() == 2 else -1
		var wpx := float(ms_w.get("atlas_px", 0.0))
		# AC-0284b: a FAR column — the payload emit (byte-identical to
		# low_emit_avg on the same column's skip-filled slabs; the deep
		# cells' ore color comes from the stone_ore_slab precompute —
		# owed only while the slab has deep cells, si <= 3 in the ore
		# bands). Game.world_seed is a static int — the established
		# worker-side read pattern.
		# (the typed-Array-null assignment is a runtime error in 4.7 —
		# the untyped get + guard; a non-far entry carries "far": null)
		var frv: Variant = entry.get("far", null)
		if frv != null:
			var fr: Array = frv
			var ore := PackedByteArray()
			# the slab owes deep cells (y < H - 3) only while its top
			# exceeds the ore band's reach — then (and only then) run the
			# stone_ore precompute (3 fields + 4096 chain reads, ~0.3 ms).
			if int(entry.get("far_hmax", 0)) > int(entry["si"]) * 16 + 3 and int(entry["si"]) <= 3:
				ore = WorldGen.gen_cpp().stone_ore_slab(int(entry["cx"]), int(entry["cz"]), int(Game.world_seed), int(Data.HEIGHT), int(entry["si"]))
			# AC-0284b: the tree cells (the skip slab's bs bitset includes
			# the trees — the far grid must too, or the halo loses the
			# tree blobs). LAZY: the first slab of the column computes
			# (veg_cells — 3 surface fields + the veg pass, ~0.1 ms), the
			# others read the column's cache; the handoff stamps the
			# compute back on the column (concurrent first slabs may each
			# compute — deterministic, same bytes).
			var veg: PackedByteArray = entry.get("far_veg", PackedByteArray())
			if veg.size() == 0:
				veg = WorldGen.gen_cpp().veg_cells(int(entry["cx"]), int(entry["cz"]), int(Game.world_seed), int(Data.HEIGHT), int(Data.SEA))
				entry["veg_done"] = veg
			# AC-0331: the far-tier mesh floor — the low lane is the
			# tier 2/3 far draw tiers only (the dispatch no-ops tier
			# 1 and below), so the floor applies to BOTH emits (the far
			# payload + the demoted-real data path — a demoted real
			# column drawn in band B/C is a far draw tier too: same cap,
			# same cost win, no visible change from above).
			entry["result"] = mcl.h_avg_emit(fr[0], fr[1], fr[2], ore, veg, int(entry["si"]), grid, entry["fcc"], sky, int(Data.SEA), int(Data.HEIGHT), wtlx, wtly, wpx, _far_floor_y())
			low_emit_cpp += 1
			return
		entry["result"] = mcl.low_emit_avg(entry["slabs"], int(entry["si"]), grid, entry["fcc"], sky, wtlx, wtly, wpx, _far_floor_y())
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
	# AC-0312: BAND A materialization — the mat entry (the far column's
	# first high dispatch): materialize the column's slabs (the skip=1
	# fill — the exact band-A contract: no caves, sky-only light, water
	# + trees + flowers) and build the FULL column's mesh under the
	# dispatch-time sky eff (the entry's eff + eff_strips — no star:
	# band A is never seeded). The slabs ride back as mat_data (the
	# handoff stamps the column — the far payload is kept). A failed
	# generation (null / wrong shape) datadrops: the entry stays queued
	# and retries (the retrigger re-enqueues it).
	if bool(entry.get("mat", false)):
		var mat_t0 := Time.get_ticks_usec()
		var mg: Variant = WorldGen.gen_cpp()
		var mresl: Array = mg.generate_resl(int(entry["cx"]), int(entry["cz"]), int(Game.world_seed), int(Data.HEIGHT), int(Data.SEA), 1, PackedByteArray())
		if mresl == null or int(mresl.size()) != 2:
			entry["result"] = null
			return
		WorldGen.apply_banana_resl(mresl, int(entry["cx"]), int(entry["cz"]), int(Game.world_seed), int(Data.HEIGHT))
		entry["mat_data"] = mresl
		# AC-0331: the far-tier mesh floor — the band-A mat build starts
		# at the FLOOR SLAB (126/16 = 7) and rows below the floor are
		# zeroed in build_accs (the per-voxel gate: the band-A cell
		# straddles the floor, so the slab range alone would mesh the
		# sub-floor rows of slab 7). The mat DATA is still the full
		# column (the fill identity — c.data lands complete; only the
		# MESH floors). The real band never gets this (yfloor -1).
		var yfl_m := int(entry.get("yfloor", -1))
		var si0_m: int = int(yfl_m / 16) if yfl_m >= 0 else 0
		var mat_res: Dictionary = mc.build_accs(mresl[0], mresl[1], int(entry["cx"]), int(entry["cz"]), entry["nbs"], entry["ctx"], entry["ms"], entry["eff"], si0_m, -1, 0, Lighting._att, Lighting._glow, PackedByteArray(), yfl_m)
		entry["mat_ms"] = (Time.get_ticks_usec() - mat_t0) / 1000
		mesh_cpp_builds += 1
		entry["result"] = mat_res
		return
	# AC-0234: entry["mask"] = the vertical-window keep mask at dispatch
	# (24 bytes; EMPTY = tier 0 / full build — byte-identical to the
	# pre-AC-0234 call). Masked slabs are skipped like all-air slabs; the
	# black cap renders them on the main thread.
	# AC-0331: the last arg = the far-tier mesh floor (-1 for every
	# non-band-A entry — the real band never floors).
	var res: Dictionary = mc.build_accs(entry["data"], entry["fl"], int(entry["cx"]), int(entry["cz"]), entry["nbs"], entry["ctx"], entry["ms"], entry["eff"], int(entry.get("si0", 0)), int(entry.get("si1", -1)), int(entry.get("d_off", 0)), Lighting._att, Lighting._glow, entry.get("mask", PackedByteArray()), int(entry.get("yfloor", -1)))
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
	# AC-0274: the loading handoff is time-budgeted (see LOAD_HO_BUDGET_MS).
	var _ho_t0 := Time.get_ticks_usec()
	var _ho_n := 0
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
				# AC-0313: the AC-0263 significant-move anchor (the
				# Y-window's moving state) is GONE with the Y-window.
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
			if loading_active:
				_ho_n += 1
				# AC-0274: time-budgeted handoffs (the fixed count throttled
				# the steady state to 6/frame at ~10 fps).
				if Time.get_ticks_usec() - _ho_t0 > LOAD_HO_BUDGET_MS * 1000 or _ho_n >= 64:
					break
			continue
		i += 1
	if timing and hb_n > 0:
		print("TMPOLL n=%d ms=%.1f t=%d" % [hb_n, (Time.get_ticks_usec() - hb_t0) / 1000.0, Time.get_ticks_msec()])  # AC-0178 diag (timing-gated)

func _tm_retrigger(key: String, c: Node3D, e: Dictionary) -> void:
	# A dropped result can't be applied: rebuild from current state.
	# AC-0283 P2: a meshed chunk's stamped slabs re-enter the remesh lane
	# (the re-bake re-captures the engine's current settled light); a
	# not-yet-meshed chunk re-enters the build band queue.
	if star != null and not bool(e.get("hslab", false)):
		for si in c.high_stamps.keys():
			_star_remesh_add(key, int(si))
	elif star != null:
		var si0: int = int(e.get("si0", -1))
		if si0 >= 0:
			_star_remesh_add(key, si0)
	if bool(c.mesh_built):
		perf_lightpend_retrigger += 1  # AC-0218: drop retrigger adds (the remesh arm)
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
	# AC-0354: the NEIGHBOUR set was snapshotted at dispatch (nbs_stamps —
	# the col_gen/data_gen/fl_gen epoch of each axis neighbour the ring
	# covers — the AC-0247 own-column identity+stamp pattern, one level
	# out). The own-column checks above compare NOTHING of the neighbour
	# state: a neighbour that moved between dispatch and landing (a
	# boundary edit's _dirty_front re-dispatch, a far payload stamp, a
	# demote, an evicted column) leaves a mesh built on a stale ring — a
	# WRONG face decision lands (at a boundary: the see-through gap).
	# Compare the captured epochs against the LIVE neighbours (a gone
	# neighbour is a mismatch — the re-dispatch defers until it lands);
	# any mismatch is the own-column mismatch treatment: datadrop +
	# retrigger, which re-dispatches with a fresh snapshot.
	var nbs_st: Dictionary = e.get("nbs_stamps", {})
	if not nbs_st.is_empty():
		var nb_stale := false
		for nk in nbs_st:
			var nc2 = chunks.get(nk)
			if nc2 == null or [int(nc2.col_gen), int(nc2.data_gen), int(nc2.fl_gen)] != nbs_st[nk]:
				nb_stale = true
				break
		if nb_stale:
			_tm_datadrop += 1
			if key == _editprobe_key:
				_editprobe_drop += 1
			if _tm_debug:
				print("TMESH DATADROP %d,%d (neighbour changed mid-build)" % [int(e["cx"]), int(e["cz"])])
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
	# AC-0297: the FULL-column dispatch (the edit-fallback feed + the tex
	# refresh) captured the 3x3x3 box epochs under the settle gate — the
	# hslab branch's late-landing check for the full path: any engine
	# mutation inside the box since dispatch (an edit, a re-seed, a
	# neighbor seed) bumped an epoch — the in-flight bake is stale light,
	# datadrop + retrigger (the retrigger re-arms the remesh lane, which
	# re-bakes every stamped slab from the current settled payload).
	if star != null and e.has("lver") and not bool(e.get("hslab", false)):
		var box_now_f: Array = star.box_epochs(int(e["cx"]), int(e["cz"]), -1, 24)
		if box_now_f != e["lver"]:
			_tm_datadrop += 1
			star_lver_drops += 1
			if _tm_debug:
				print("TMESH LVERDROP %d,%d (full)" % [int(e["cx"]), int(e["cz"])])
			_tm_retrigger(key, c, e)
			if star_bake_probe != null:
				star_bake_probe.call("drop", int(e["cx"]), int(e["cz"]), -1, {"eff": e.get("eff", {})})
			return
	if bool(e.get("hslab", false)):
		# AC-0312: the BAND-A mat landing — the far column's first high
		# dispatch materialized the column (the worker ran the skip=1
		# fill + the full-column build under the sky eff). The DATA
		# STAMP IS THIS LANDING (the column held no slabs at dispatch —
		# the stale/band checks above passed against the null-slab
		# stamps): land the slabs (the reference handoff — data_gen /
		# fl_gen bump, top update), mark the column materialized (the
		# far flag + payload are KEPT — the save form, the snap rings,
		# and the promotion contract all ride on them), attach the
		# full-column mesh, stamp + flush every built slab. The entry
		# stays queued (the pick drops it the frame the probe finds
		# nothing left).
		if bool(e.get("mat", false)):
			var md: Array = e.get("mat_data", [])
			if md.size() != 2:
				_tm_datadrop += 1
				_tm_retrigger(key, c, e)
				return
			var ta_m := Time.get_ticks_msec()
			c.slabs_landed(md[0], md[1])
			c.far_mat = true
			c.no_caves = true  # the skip fill is cave-less (the promotion owes the full regen)
			var ms_m: int = int(e.get("mat_ms", 0))
			band_a_mat_ms_sum += ms_m
			band_a_mat_ms_n += 1
			# AC-0321: the mat build is a FULL column build (si0=0,
			# si1=-1, empty mask — C++ scoped=false), so its opaque UVs
			# are emitted in the MERGED-atlas canvas space (v / ms.h; the
			# strip quads sit below the plain atlas height) — the attach
			# must wear the merged-canvas material: the reference full
			# apply (apply_accs passes _tm_ms_full.tex into
			# _get_mat("opaque", …)) is the contract the real band's
			# full landing uses. apply_edit_accs is the SCOPED build's
			# apply (emit_faces plain-space UVs + the plain-atlas
			# material — the editmat arm's contract): landing the mat
			# through it pinned the opaque surface to the 1024-tall
			# plain material under merged-canvas UVs — band A rendered
			# untextured/wrong (the user's in-game report). apply_accs
			# differs from apply_edit_accs(…, false) here only in the
			# material + no-op slab-ref nulling (a mat column holds no
			# old instances) + mesh_built (set again below).
			c.apply_accs(res, _tm_ms_full)
			var si1_m: int = int(res.get("si1", c.data.size() - 1))
			for si_m in range(si1_m + 1):
				c.high_stamps[si_m] = int(c.data_gen)
				c.flush_slabs[si_m] = true
			_star_update_light_settled(c)
			c.saved_light = {}
			# high-complete in one shot (the full column landed; slabs
			# above the top are air and never pending — the probe's lim).
			c.mesh_built = true
			_hslab_probe_invalidate(c)
			_low_probe_invalidate(c)
			# AC-0312: the ACTIVE tier is the LIVE tier — band A (and the
			# real band) show the high (any low is stored OFF for the
			# demote flip); a live demote to B/C while in flight shows
			# the READY lows (the stored highs flip on re-entry) and
			# re-opens the rest for the wave.
			var tier_m := _lod_tier_of(int(c.cx) - last_pcx, int(c.cz) - last_pcz)
			if tier_m > 1:
				hslab_stragglers_n += 1
				for si_l in c.low_slabs:
					var si_l2: int = int(si_l)
					if not _low_slab_pending_at(c, si_l2, tier_m):
						c.low_slab_visible(si_l2, true)
						c.high_slab_visible(si_l2, false)
				_low_relower_owed[key] = true
			else:
				for si_l in c.low_slabs:
					c.low_slab_visible(int(si_l), false)  # stored (flip on demote)
				for si_m2 in range(c.data.size()):
					c.high_slab_visible(si_m2, bool(c.flush_slabs.has(si_m2)))
			if bool(e.get("eff_trust", false)):
				_eff_cache_put(key, c, res.get("light", {}), e.get("ngen", null))
			_count_collision_build(c)
			_stage_check(c, key)
			perf_build_ms += Time.get_ticks_msec() - ta_m
			perf_build_worker_ms += ms_m
			perf_build_worker_ms_list.append(ms_m)
			if loading_active:
				_load_wms_sum += ms_m
				_load_wms_n += 1
			_tm_handoff += 1
			_tm_hslab_n += 1
			if timing or _tm_debug:
				print("BUILDCHUNK_MAT %d,%d slabs=%d ms=%d t=%d" % [int(e["cx"]), int(e["cz"]), si1_m + 1, ms_m, Time.get_ticks_msec()])
			return
		# AC-0263: a per-slab FULL-RES landing (the tier-0 section / the
		# high-band rings). The scoped stale check (rows_eq on the
		# dispatch window) and the band check above already ran. Scoped
		# retain-swap attach (the edit lane's machinery, mark_complete=false
		# — a slab landing does NOT complete the column), the slab's
		# placeholder (the low) drops, the completion stamp lands (empty
		# all-air builds stamped too — done, not pending), and the probe
		# flips mesh_built when the column owes nothing.
		var si_h: int = int(e["si0"])
		# AC-0283 P2: the light staleness check — the dispatch captured the
		# 27 section epochs of the 3x3x3 box; any engine mutation inside
		# the box (a neighbor seed, an edit, a late-landing re-seed) bumped
		# one: the in-flight bake would be stale light — datadrop and
		# retrigger (the re-dispatch re-captures under the gate).
		if star != null and e.has("lver"):
			var box_now: Array = star.box_epochs(int(e["cx"]), int(e["cz"]), si_h - 1, si_h + 1)
			if box_now != e["lver"]:
				_tm_datadrop += 1
				star_lver_drops += 1
				if _tm_debug:
					print("TMESH LVERDROP %d,%d slab=%d" % [int(e["cx"]), int(e["cz"]), si_h])
				_tm_retrigger(key, c, e)
				if star_bake_probe != null:
					star_bake_probe.call("drop", int(e["cx"]), int(e["cz"]), si_h, {"eff": e.get("eff", {})})
				return
		# AC-0263 spec (keep-all-LOD): a STRAGGLER (the column left the
		# high band while this build was in flight) is no longer an error
		# - the high landing IS the slab's STORED high (the re-entry flip
		# is a visibility toggle, never a rebuild). Attach it (the
		# retain-swap) and set the active tier: in the high band the high
		# is ON (any low is stored OFF); out of band a READY low stays ON
		# and the high is stored OFF, or - no low yet - the high stays ON
		# until the wave's low lands and flips it (the slab never shows
		# two tiers or nothing).
		var taxi_now := absi(int(c.cx) - last_pcx) + absi(int(c.cz) - last_pcz)
		# AC-0283 P3 (AC-0313, AC-0312): the straggler test is the exit
		# from the HIGH draw tiers (the column left REAL + BAND A while
		# this build was in flight) — bands B/C own the draw now (the
		# avg LOD). Band A is IN-band: the high stays showing (the
		# full-LOD draw tier — AC-0312 restored the band, so the old
		# real-band-exit test mis-classified every band-A landing).
		# taxi_now stays for the log line.
		var straggler := _lod_tier_of(int(c.cx) - last_pcx, int(c.cz) - last_pcz) > 1
		if straggler:
			hslab_stragglers_n += 1
		var ta_h := Time.get_ticks_msec()
		c.apply_edit_accs(res, _tm_ms_full, false)
		c.high_stamps[si_h] = int(c.data_gen)
		# AC-0263 spec: the slab's low is STORED, not dropped (the
		# band-exit flip-back renders it without a rebuild).
		# AC-0283 P2: a landing IS the settled bake — the dispatch passed
		# the box gate (the 3x3x3 light settled at capture) and the epochs
		# verified above (no engine mutation since). Set the per-slab
		# settled-bake mark (the show rule), re-derive the chunk flag, and
		# show. There is no flush to arm: construction, not re-arm (no
		# loop). (The legacy late_landing un-settle is GONE — the engine's
		# on_section_data does the hide + un-settle + re-arm at the data
		# change itself, before any stale build can dispatch.)
		c.flush_slabs[si_h] = true
		_star_update_light_settled(c)
		if star_bake_probe != null:
			star_bake_probe.call("land", int(e["cx"]), int(e["cz"]), si_h, {"eff": e.get("eff", {})})
		var show_h: bool = bool(c.flush_slabs.has(si_h))
		if straggler and c.has_low_si(si_h):
			c.low_slab_visible(si_h, true)
			c.high_slab_visible(si_h, false)  # stored (flip-back on re-entry)
		elif straggler:
			c.high_slab_visible(si_h, show_h)   # active until the wave flips
		else:
			c.high_slab_visible(si_h, show_h)
			if c.has_low_si(si_h):
				c.low_slab_visible(si_h, false)  # stored (flip on demote)
		_hslab_probe_invalidate(c)
		_low_probe_invalidate(c)
		if not bool(c.mesh_built) and _hslab_best_pending(c) < 0:
			c.mesh_built = true
			# high-complete: the column's placeholders are all gone now
			# (each landing dropped its own) — nothing to free in bulk.
		c.saved_light = {}
		perf_build_ms += Time.get_ticks_msec() - ta_h
		var _wms_h: int = int(res.get("wms", 0))
		perf_build_worker_ms += _wms_h
		perf_build_worker_ms_list.append(_wms_h)
		if loading_active:
			_load_wms_sum += _wms_h
			_load_wms_n += 1
		_count_collision_build(c)
		_stage_check(c, key)
		if bool(e.get("eff_trust", false)):
			_eff_cache_put(key, c, res.get("light", {}), e.get("ngen", null))
		_tm_handoff += 1
		_tm_hslab_n += 1  # AC-0263: the per-slab lane's landing count
		# AC-0263 (AC-0313): section evidence — the INITIAL ANCHOR
		# COLUMN's completion (the first slab of the taxi-0 column to
		# finish high — the tier-0 set's default, now the innermost
		# column of the (taxi, layer) order; a later recenter's new
		# anchor column does not move the milestone).
		if _hslab_section_done_frame < 0 \
				and int(e["cx"]) == last_pcx and int(e["cz"]) == last_pcz:
			_hslab_section_done_frame = Time.get_ticks_msec()
		# AC-0263: NO _drop_queued — the entry STAYS queued (the column's
		# remaining slabs are still pending) and is re-picked next frame;
		# the pick removes it the frame the probe finds nothing left.
		if timing or _tm_debug:
			print("BUILDCHUNK_H %d,%d slab=%d build_ms=%d t=%d" % [int(e["cx"]), int(e["cz"]), si_h, int(res.get("wms", 0)), Time.get_ticks_msec()])
		return
	if bool(e.get("edit", false)):
		var ta2 := Time.get_ticks_msec()
		c.apply_edit_accs(res, _tm_ms_full)
		# AC-0263: an edit's scoped remesh is a HIGH landing — stamp the
		# covered slabs done at the NEW data_gen (the edit window includes
		# the boundary slabs, so the probe won't re-owe them).
		for si_e in range(int(res.get("si0", 0)), int(res.get("si1", 0)) + 1):
			c.high_stamps[si_e] = int(c.data_gen)
		# AC-0283 P2 (brightslab fix): the legacy scoped bake above carries
		# the PRE-EDIT eff snapshot - it is not the settled star light (the
		# set_block re-arm fired BEFORE the data_gen bump, so its stamped
		# condition never matched and the own column was never armed). Stamp
		# the whole on_edit re-settle window (sections 0..si1+1) at the new
		# data_gen and re-arm the star remesh lane: the drain re-bakes each
		# slab with the settled payload (the dispatch gates on the 3x3x3 box
		# settle, so the re-bake lands on the settled light; the slab keeps
		# showing the legacy bake until then - the no-hide edit contract
		# holds).
		if star != null:
			for si_r in range(0, mini(int(res.get("si1", 0)) + 2, 24)):
				c.high_stamps[si_r] = int(c.data_gen)
				_star_remesh_add(key, si_r)
			_star_update_light_settled(c)
		if star_bake_probe != null:
			star_bake_probe.call("land", int(e["cx"]), int(e["cz"]), int(res.get("si0", 0)), {"eff": e.get("eff", {}), "light": res.get("light", {}), "scoped": true, "y_lo": int(e.get("d_off", 0)), "y_hi": int(e.get("d_hi", 0))})
		c.saved_light = {}
		perf_build_ms += Time.get_ticks_msec() - ta2
		perf_build_worker_ms += int(res.get("wms", 0))
		perf_build_worker_ms_list.append(int(res.get("wms", 0)))
		_count_collision_build(c)
		_stage_check(c, key)
		if bool(e.get("eff_trust", false)):
			_eff_cache_put(key, c, res.get("light", {}), e.get("ngen", null))
		_tm_handoff += 1
		_drop_queued(key)
		if timing or _tm_debug:
			print("BUILDCHUNK_E %d,%d build_ms=%d t=%d" % [int(e["cx"]), int(e["cz"]), int(res.get("wms", 0)), Time.get_ticks_msec()])
		return
	var ta := Time.get_ticks_msec()
	if not bool(c.mesh_built):
		_tm_full_firstbuild_n += 1  # AC-0263: first-build evidence
	c.apply_accs(res, _tm_ms_full)
	# AC-0263: a full-column landing stamps every slab at/below the top
	# done (the per-slab probe's completion record for the legacy path).
	for si_f in range(mini(int(c.top) >> 4, int(c.data.size() - 1)) + 1):
		c.high_stamps[si_f] = int(c.data_gen)
	# AC-0263 spec (user 2026-09-13) unchanged: a chunk whose lighting is
	# not calculated never shows. AC-0297: the live full-column dispatches
	# (the edit-fallback feed + the tex refresh) now carry the SETTLED star
	# payload (the lver gate above re-checks the box epochs), so a settled
	# landing IS the settled light — flush and show. The not-settled branch
	# (an unseeded/demoted column, or the star==null test-arm path whose
	# bake is not engine-gated) still hides + arms the remesh lane.
	# AC-0283 P2's edit_full re-arm is GONE: the FEED bake is already the
	# settled payload — re-arming every stamped slab after it would only
	# double-bake (the lver drop / not-settled paths own the re-bake).
	if star != null and star.column_settled(int(c.cx), int(c.cz)):
		for si_f in range(mini(int(c.top) >> 4, int(c.data.size() - 1)) + 1):
			c.flush_slabs[si_f] = true
	elif star != null:
		c.hide_all_high()
		for si_f in range(mini(int(c.top) >> 4, int(c.data.size() - 1)) + 1):
			c.flush_slabs.erase(si_f)  # the stale bake is not the settled light
			_star_remesh_add(key, si_f)
	_star_update_light_settled(c)
	if star_bake_probe != null:
		star_bake_probe.call("land", int(e["cx"]), int(e["cz"]), -1, {"eff": e.get("eff", {}), "light": res.get("light", {}), "edit_full": bool(e.get("edit_full", false))})
	_hslab_probe_invalidate(c)
	c.saved_light = {}
	# AC-0231 rewrite: the high REPLACES the per-slab placeholders (the
	# 4x4x4 textured lows) at every slab's Y. Keep-high
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
		if not _dirty_full_dispatch(c, int(c.cx), int(c.cz)):
			return  # deferred (settle gate / pool cap) — retry next frame
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


# AC-0297: the edit-fallback full bake, STAR-NATIVE. The engine is the
# single light source for this dispatch: it captures the column's SETTLED
# per-slab payload (the remesh lane's own capture — one full-column
# window) and the 3x3x3 box epochs (the landing re-checks them — any
# engine mutation inside the box since dispatch bumped an epoch and
# datadrops the in-flight bake; the retrigger re-arms the remesh lane,
# which re-bakes from the current settled payload). The classic-pull
# self-light is GONE from the live path: the star==null fallback keeps
# it for the test arms only (they drive the star=false world).
# (a) evidence (.scratch/ac0297/report.md): for boundary edits the pull
# light is byte-equal to the settled star payload (0/98304 cells), so
# FEED loses no light fidelity — and the lane alone does NOT cover the
# edit face's slab (uncovered_delete), so the dispatch stays a full bake
# (the face update stays 1 frame after the settle, not lane-paced).
func _dirty_full_dispatch(c: Node3D, cx: int, cz: int) -> bool:
	if star == null:
		return _mesh_dispatch(c, cx, cz, {}, true, true, false, true)
	# The box gate (the remesh lane's own): the payload is final only
	# when the column's full 3x3x3 box has settled — a not-yet-settled
	# box defers (the entry retries next frame; the settle is 1-3 frames
	# after an edit).
	if not star.box_settled(cx, cz, -1, 24):
		return false
	var pl: Dictionary = star.slab_light_payload(cx, cz, 0, maxi(0, int(c.top) >> 4))
	if not bool(pl.get("ok", false)):
		# The column is not seeded (a demoted neighbor): no payload
		# exists. Mirror the full landing's not-settled behavior — hide
		# the dormant high + re-arm the stamped slabs (the promotion
		# re-seed + remesh lane re-bakes them on the settled payload;
		# until then the column shows nothing — the AC-0263 rule).
		c.hide_all_high()
		for si_f in range(mini(int(c.top) >> 4, int(c.data.size() - 1)) + 1):
			c.flush_slabs.erase(si_f)
			_star_remesh_add(_key(cx, cz), si_f)
		_star_update_light_settled(c)
		return true
	pl["star"] = true
	pl["lver"] = star.box_epochs(cx, cz, -1, 24)
	return _mesh_dispatch(c, cx, cz, pl, true, true, false, true)


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
	var nbs_stamps: Dictionary = {}  # AC-0354: the 4 axis neighbours' epochs (col_gen/data_gen/fl_gen) the rings were taken from — the handoff validates them against the LIVE neighbours (the own-column stamp says nothing about the neighbour state)
	var mc: Variant = ChunkScript.mesh_cpp()
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			if (dx == 0) == (dz == 0):
				continue
			var nk := _key(cx + dx, cz + dz)
			var nc = chunks.get(nk)
			if nc == null or nc.data.is_empty():
				return false
			nbs["%d,%d" % [dx, dz]] = mc.snap_rings(nc.data, nc.fl, dx, dz, nc.gen_keep, nc.far_payload())  # AC-0237: ungenerated slabs read as solid; AC-0284b: a far neighbor's ring is the skip-fill edge row
			if dx == 0 or dz == 0:
				nbs_stamps[nk] = [int(nc.col_gen), int(nc.data_gen), int(nc.fl_gen)]  # AC-0354: the axis neighbours the ring covers (the diagonal entries are unused for face decisions — not stamped)
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
		"nbs": nbs, "nbs_stamps": nbs_stamps,  # AC-0354: neighbour epochs the handoff re-checks
		"eff": fast_eff, "eff_trust": false,
		"ctx": ctx_w, "ms": ms_w, "ngen": _ngens_for(cx, cz),
		"edit": true, "si0": si0, "si1": si1,
		"scoped_snap": true, "d_off": d_lo, "d_hi": d_hi,
		"t_submit": Time.get_ticks_usec(),
	}
	if star_bake_probe != null:
		star_bake_probe.call("disp", cx, cz, si0, {"eff": fast_eff, "strips": strips["eff"], "strips_blk": strips["blk"], "y_lo": d_lo, "y_hi": d_hi, "scoped": true})
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

func _mesh_dispatch(c: Node3D, cx: int, cz: int, eff: Dictionary, eff_trust := true, defer_on_cap := false, settle := false, edit_full := false) -> bool:
	# AC-0263 spec (settle): the light-FLUSH dispatch (the chunk's lighting
	# is calculated now) - the handoff marks the chunk light_settled and the
	# re-meshed slabs show.
	if not timing:
		return _mesh_dispatch_impl(c, cx, cz, eff, eff_trust, defer_on_cap, settle, edit_full)
	var _t0 := Time.get_ticks_usec()
	var _r: bool = _mesh_dispatch_impl(c, cx, cz, eff, eff_trust, defer_on_cap, settle, edit_full)
	print("DISPATCHMS %d,%d ms=%.1f t=%d" % [cx, cz, (Time.get_ticks_usec() - _t0) / 1000.0, Time.get_ticks_msec()])
	return _r


func _mesh_dispatch_impl(c: Node3D, cx: int, cz: int, eff: Dictionary, eff_trust := true, defer_on_cap := false, settle := false, edit_full := false) -> bool:
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
	# worker slot frees. AC-0293: the spawn contract that motivated the
	# legacy fallbacks rides the normal data pass + the AC-0313 clause-4
	# load gate (the 5x5 startup burst that carried it is retired).
	if c.data.is_empty():
		perf_edit_syncs += 1
		return false  # AC-0263: the data lane owns it (the sync gen is gone)
	var nbs: Dictionary = {}
	var nbs_stamps: Dictionary = {}  # AC-0354: the 4 axis neighbours' epochs (col_gen/data_gen/fl_gen) the rings were taken from — the handoff validates them against the LIVE neighbours (the own-column stamp says nothing about the neighbour state)
	var mc: Variant = ChunkScript.mesh_cpp()
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			if (dx == 0) == (dz == 0):
				continue
			var nk := _key(cx + dx, cz + dz)
			var nc = chunks.get(nk)
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
			nbs["%d,%d" % [dx, dz]] = mc.snap_rings(nc.data, nc.fl, dx, dz, nc.gen_keep, nc.far_payload())  # AC-0237: ungenerated slabs read as solid; AC-0284b: a far neighbor's ring is the skip-fill edge row
			if dx == 0 or dz == 0:
				nbs_stamps[nk] = [int(nc.col_gen), int(nc.data_gen), int(nc.fl_gen)]  # AC-0354: the axis neighbours the ring covers (the diagonal entries are unused for face decisions — not stamped)
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
	# AC-0297: a STAR payload eff IGNORES the ctx strips (the worker expands
	# the payload's own side/corner strips — build_accs replaces C.eff_strips
	# before the bake), so the main-thread strip build (the classic-pull
	# margin kernel) is skipped for star dispatches. The star==null
	# (test-arm) path still needs them.
	var strips: Dictionary
	if bool(eff.get("star", false)):
		var ze: Array = []
		for zk in range(8):
			ze.append(PackedByteArray())
		strips = {"eff": ze, "blk": ze, "blk_b": ze}
	else:
		strips = _strips_for(cx, cz)
	var ctx_w: Dictionary = _tm_ctx.duplicate()
	ctx_w["eff_strips"] = strips["eff"]
	ctx_w["blk_strips"] = strips["blk"]
	if edit_full and star != null:
		ctx_w["blk_strips"] = strips["blk_b"]
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
		"nbs": nbs, "nbs_stamps": nbs_stamps,  # AC-0354: neighbour epochs the handoff re-checks
		"eff": eff, "eff_trust": eff_trust, "settle": settle,
		"edit_full": bool(edit_full),  # AC-0283 P2 brightslab fix: the edit-fallback full bake
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
# AC-0312: the band-A cached sky eff — the heightmap sky as the classic
# light dict + the 8 clamped-H margin strips, computed ONCE per column
# from its far_h (AweMesh.sky_eff, C++) and cached on the column
# (c.far_eff — ~534 KB; it dies with the column, freed explicitly on a
# full landing via clear_far). The band-A high dispatches (the
# materialization + any retrigger) build under it: band A is never
# seeded into the engine (sky-only light — no caves, no block light),
# so the settled-payload gate never applies. {} = no payload (the
# dispatch defers; a far column always has one).
func _band_a_eff_for(c: Node3D) -> Dictionary:
	# AC-0331: floor-awareness — sky_eff is FULL HEIGHT (arr = 256 x
	# Data.HEIGHT, the margin strips full-height too), so the far-tier
	# cap face at the floor (y = Data.SEA = 126) reads the same heightmap
	# rule (15 above the column's H, 0 at/below) — the cap is lit on an
	# ocean column and dark on a land one, no change owed. CACHE CAVEAT:
	# c.far_eff must not outlive a floor CHANGE — while the floor is
	# fixed (this ticket) it is stable by construction; AC-0332 (the
	# setting) must invalidate c.far_eff (see the clear_far reset below
	# at the full landing) whenever the floor value changes.
	if not c.far or c.far_h.size() != 512:
		return {}
	if not c.far_eff.is_empty():
		return c.far_eff
	var me: Variant = ChunkScript.mesh_cpp()
	if me == null:
		return {}
	var r: Dictionary = me.sky_eff(int(c.cx), int(c.cz), c.far_h, int(Data.HEIGHT))
	if r.has("err"):
		return {}
	c.far_eff = r
	return r

func _mesh_dispatch_hslab(c: Node3D, cx: int, cz: int, si: int, eff: Dictionary, settle := false) -> bool:
	var key := _key(cx, cz)
	c.col_immediate = _col_immediate_for(cx, cz)
	if c.data.is_empty():
		_hslab_last_defer = 4
		return false  # AC-0263: the data lane owns it (the sync gen is gone)
	if _tm_inflight_keys.has(key):
		_tm_dedup += 1
		hslab_defer_dedup += 1
		_hslab_last_defer = 1
		return false
	# AC-0312: BAND A — a far column in the full-LOD draw tier. Its high
	# dispatch is the MATERIALIZATION (the "mat" entry): the worker runs
	# the skip=1 fill (generate_resl — the exact band-A contract: no
	# caves, sky-only light, water + trees + flowers) and builds the
	# FULL column's mesh under the cached sky eff (AweMesh.sky_eff on
	# the column's far_h — band A is never seeded into the engine, so
	# the settled-payload gate and the star payload are bypassed). A
	# mat-landed far column (far_mat — the retrigger path) takes the
	# same sky-eff dispatch for its slab (an unseeded column's payload
	# is never ok — defer-forever without this branch). The mat handoff
	# stamps the slabs (the column's data IS the landing); the retrigger
	# lands through the unchanged hslab path below.
	var band_a := bool(c.far) \
			and _lod_tier_of(int(cx) - last_pcx, int(cz) - last_pcz) == 1
	if band_a:
		var sea: Dictionary = _band_a_eff_for(c)
		if sea.is_empty():
			hslab_defer_sky += 1
			_hslab_last_defer = 6
			return false
		var tm_cap_a := threadmesh_max
		if _startup_pending() and tm_cap_a < 9:
			tm_cap_a = 9
		tm_cap_a = maxi(1, tm_cap_a - (2 if not dirty_queue.is_empty() else 1))
		if threadmesh_inflight.size() >= tm_cap_a:
			_tm_capdrop += 1
			hslab_defer_cap += 1
			_hslab_last_defer = 2
			return false
		var nbs_a: Dictionary = {}
		var nbs_a_stamps: Dictionary = {}  # AC-0354: the 4 axis neighbours' epochs (col_gen/data_gen/fl_gen) the rings were taken from — the handoff validates them against the LIVE neighbours
		var mc_a: Variant = ChunkScript.mesh_cpp()
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				if (dx == 0) == (dz == 0):
					continue
				var nk := _key(cx + dx, cz + dz)
				var nc = chunks.get(nk)
				if nc == null or nc.data.is_empty():
					hslab_defer_nbs += 1
					_hslab_last_defer = 3
					return false  # the neighbor lands, the entry retries
				nbs_a["%d,%d" % [dx, dz]] = mc_a.snap_rings(nc.data, nc.fl, dx, dz, nc.gen_keep, nc.far_payload())
				if dx == 0 or dz == 0:
					nbs_a_stamps[nk] = [int(nc.col_gen), int(nc.data_gen), int(nc.fl_gen)]  # AC-0354: the axis neighbours the ring covers (the diagonal entries are unused for face decisions — not stamped)
		var is_mat := not bool(c.far_mat)
		var ms_wa: Dictionary
		if not _tm_ms_full.rects.is_empty():
			ms_wa = {"rects": _tm_ms_full.rects.duplicate(), "h": float(_tm_ms_full.get("h", 0.0))}
		else:
			ms_wa = {"rects": {}}
		var ctx_wa: Dictionary = _tm_ctx.duplicate()
		ctx_wa["eff_strips"] = sea["strips"]
		var entry_a := {
			"key": key, "cx": cx, "cz": cz, "inst": c.get_instance_id(), "colgen": int(c.col_gen),
			"data": mc_a.slab_copy(c.data),  # all-null (a far column) — the mat build owns the data
			"fl": mc_a.slab_copy(c.fl),
			"stamp": c.stamp(),
			"band": int(c.band),
			"nbs": nbs_a, "nbs_stamps": nbs_a_stamps,  # AC-0354: neighbour epochs the handoff re-checks
			"eff": sea["light"], "eff_trust": true, "settle": false,
			"ctx": ctx_wa, "ms": ms_wa, "ngen": _ngens_for(cx, cz),
			"tier": _tier_of(int(cx) - last_pcx, int(cz) - last_pcz),
			"hslab": true, "si0": 0 if is_mat else si, "si1": -1 if is_mat else si,
			"mat": is_mat,
			"scoped_snap": not is_mat,
			"d_off": 0 if is_mat else maxi(0, si * 16 - 1),
			"d_hi": Data.HEIGHT - 1 if is_mat else mini(Data.HEIGHT - 1, (si + 1) * 16),
			# AC-0331: the far-tier mesh floor — band A is a far draw
			# tier: the mat build starts at the floor slab (the worker
			# clamps si0) + build_accs zeroes the sub-floor rows; the
			# per-slab RETRIGGER carries it too (a remeshed slab of a
			# mat-landed column matches the floored mat build — no
			# sub-floor faces appear on a remesh).
			"yfloor": _far_floor_y(),
			"t_submit": Time.get_ticks_usec(),
		}
		var skey_a := _tm_next_slot
		_tm_next_slot += 1
		var tid_a = threadmesh_pool.add_task(_tm_worker_run.bind(skey_a), true)
		entry_a["tid"] = tid_a
		entry_a["skey"] = skey_a
		_tm_slots_mutex.lock()
		_tm_slots[skey_a] = entry_a
		_tm_slots_mutex.unlock()
		_tm_inflight_keys[key] = tid_a
		threadmesh_inflight.append(entry_a)
		_tm_enq += 1
		if is_mat:
			band_a_mat_dispatches += 1
		_hslab_last_defer = 0
		_bd_log(cx, cz)
		if _tm_debug:
			print("TMESH HSLAB %d,%d slab=%d mat=%d inflight=%d" % [cx, cz, si, is_mat, threadmesh_inflight.size()])
		return true
	# AC-0283 P2: the light gate — the 3x3x3 section box around the slab
	# (the bake-box overhang) must be SETTLED in the engine: a slab never
	# dispatches (and never shows) on lighting that is not calculated.
	if star != null and not star.box_settled(cx, cz, si - 1, si + 1):
		_hslab_last_defer = 5
		hslab_defer_settle += 1
		_sw_settle_defer(cx, cz, si)  # AC-0339: open/extend the settle-wait episode (instrumentation only)
		return false
	var tm_cap := threadmesh_max
	if _startup_pending() and tm_cap < 9:
		tm_cap = 9
	tm_cap = maxi(1, tm_cap - (2 if not dirty_queue.is_empty() else 1))
	if threadmesh_inflight.size() >= tm_cap:
		_tm_capdrop += 1
		hslab_defer_cap += 1
		_hslab_last_defer = 2
		if _tm_debug:
			print("TMESH HSLABCAPDROP %d,%d slab=%d inflight=%d" % [cx, cz, si, threadmesh_inflight.size()])
		return false
	var nbs: Dictionary = {}
	var nbs_stamps: Dictionary = {}  # AC-0354: the 4 axis neighbours' epochs (col_gen/data_gen/fl_gen) the rings were taken from — the handoff validates them against the LIVE neighbours (the own-column stamp says nothing about the neighbour state)
	var mc: Variant = ChunkScript.mesh_cpp()
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			if (dx == 0) == (dz == 0):
				continue
			var nk := _key(cx + dx, cz + dz)
			var nc = chunks.get(nk)
			if nc == null or nc.data.is_empty():
				hslab_defer_nbs += 1
				_hslab_last_defer = 3
				return false  # AC-0263: defer — the neighbor lands, the entry retries
			nbs["%d,%d" % [dx, dz]] = mc.snap_rings(nc.data, nc.fl, dx, dz, nc.gen_keep, nc.far_payload())  # AC-0237: ungenerated slabs read as solid; AC-0284b: a far neighbor's ring is the skip-fill edge row
			if dx == 0 or dz == 0:
				nbs_stamps[nk] = [int(nc.col_gen), int(nc.data_gen), int(nc.fl_gen)]  # AC-0354: the axis neighbours the ring covers (the diagonal entries are unused for face decisions — not stamped)
	var y_lo := si * 16
	var y_hi := (si + 1) * 16 - 1
	var d_lo := maxi(0, y_lo - 1)
	var d_hi := mini(Data.HEIGHT - 1, y_hi + 1)
	var ms_w: Dictionary
	if not _tm_ms_full.rects.is_empty():
		ms_w = {"rects": _tm_ms_full.rects.duplicate(), "h": float(_tm_ms_full.get("h", 0.0))}
	else:
		ms_w = {"rects": {}}
	# AC-0283 P2: the star payload (the engine's SETTLED light for this
	# slab's bake box, captured under the box gate) replaces the eff: the
	# worker expands it into the classic light dict + the 8 margin strips
	# (no pull kernel, no ctx strips — the gate made the bake final).
	var strips: Dictionary
	if star != null:
		var pl: Dictionary = star.slab_light_payload(cx, cz, si, si)
		if not bool(pl.get("ok", false)):
			_hslab_last_defer = 6
			return false
		pl["star"] = true
		pl["lver"] = star.box_epochs(cx, cz, si - 1, si + 1)
		eff = pl
		strips = {"eff": [], "blk": [], "blk_b": []}
		if star_bake_probe != null:
			star_bake_probe.call("disp", cx, cz, si, {"pl": pl})
	else:
		strips = _strips_for_scoped(cx, cz, y_lo, y_hi)
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
		"nbs": nbs, "nbs_stamps": nbs_stamps,  # AC-0354: neighbour epochs the handoff re-checks
		"eff": eff, "eff_trust": true, "settle": settle or star != null,
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
	_hslab_last_defer = 0
	_bd_log(cx, cz)
	# AC-0339: the gate passed — close this slab's settle-wait episode
	# (first-defer frame -> this dispatch frame). A slab that never
	# settled-deferred (first dispatch on settled light) has no open
	# episode and records nothing. Instrumentation only.
	var swk := "%d,%d:%d" % [cx, cz, si]
	if _sw_open.has(swk):
		_sw_samples.append(_sw_frame - int(_sw_open[swk]))
		_sw_open.erase(swk)
	if _tm_debug:
		print("TMESH HSLAB %d,%d slab=%d inflight=%d" % [cx, cz, si, threadmesh_inflight.size()])
	return true

# AC-0339 STEP 0 (instrumentation only): open/extend this slab's
# settle-wait episode on a gate defer and census the high-lane work
# queued behind it.
func _sw_settle_defer(cx: int, cz: int, si: int) -> void:
	var swk := "%d,%d:%d" % [cx, cz, si]
	if not _sw_open.has(swk):
		_sw_open[swk] = _sw_frame
		_sw_episodes += 1
	_sw_max_open = maxi(_sw_max_open, _sw_open.size())
	_sw_defer_frames += 1
	_sw_stalled.append(_sw_stalled_cols(cx, cz))

# AC-0339: the OTHER high-lane columns (real band + band A — the
# star-gated work) in the build queue at a settle defer. AC-0335's
# per-column defer set means the drain SKIPS the deferred column within
# the frame and dispatches the next-best, so this is the work ORDERED
# behind the gated light (the inside-out (taxi, layer) order), not
# hard-blocked frames — read the numbers with that semantics.
func _sw_stalled_cols(cx: int, cz: int) -> int:
	var self_key := _key(cx, cz)
	var n := 0
	for b in band_buckets:
		for e in b:
			if bool(e["data_only"]):
				continue
			if str(e["key"]) == self_key:
				continue
			if _lod_tier_of(int(e["cx"]) - last_pcx, int(e["cz"]) - last_pcz) <= 1:
				n += 1
	return n

# AC-0339: window control for the settle-wait census — the arms reset
# before the scenario and report at the end; a world's counters keep
# accumulating across resets (the live values stay the diagnostics
# surface).
func settlewait_reset() -> void:
	_sw_open.clear()
	_sw_samples.clear()
	_sw_stalled.clear()
	_sw_episodes = 0
	_sw_defer_frames = 0
	_sw_max_open = 0
	_sw_remesh_max = 0
	_sw_star_busy_frames = 0
	_sw_star_pending_max = 0
	_sw_star_drained_max = 0
	_sw_star_pending_sum = 0
	_sw_star_drained_sum = 0

# AC-0339: the settle-wait census as the arm reports it: the per-slab
# wait (first-defer frame -> dispatch frame) p50/p95/max, the stalled
# columns behind defers, and the starlight queue state (the remesh lane
# depth + the _star_step drained-vs-pending census).
func settlewait_report() -> Dictionary:
	var ss: Array = _sw_samples.duplicate()
	ss.sort_custom(func(a, b): return int(a) < int(b))
	var st: Array = _sw_stalled.duplicate()
	st.sort_custom(func(a, b): return int(a) < int(b))
	var pct := func(arr: Array, p: float) -> int:
		if arr.is_empty():
			return 0
		return int(arr[int(ceilf(p * float(arr.size()))) - 1])  # nearest-rank, 1-based
	# the queue census at report time (context for the stalled counts —
	# meshed columns' entries persist in the queue after completion, so
	# the high-lane count is the work ORDERED behind a defer, see
	# _sw_stalled_cols).
	var q_tot := 0
	var q_high := 0
	for b in band_buckets:
		for e in b:
			q_tot += 1
			if not bool(e["data_only"]) \
					and _lod_tier_of(int(e["cx"]) - last_pcx, int(e["cz"]) - last_pcz) <= 1:
				q_high += 1
	return {
		"queue_total": q_tot,
		"queue_high": q_high,
		"frames": _sw_frame,
		"episodes": _sw_episodes,  # slabs that settled-deferred at least once
		"n": ss.size(),  # closed waits
		"open": _sw_open.size(),  # still waiting at report time (a non-zero = the window ended mid-wait)
		"defer_frames": _sw_defer_frames,  # total settle-defer frame occurrences
		"max_open": _sw_max_open,  # concurrent open episodes, max
		"p50": pct.call(ss, 0.50),
		"p95": pct.call(ss, 0.95),
		"max": int(ss.max()) if not ss.is_empty() else 0,
		"stalled_n": st.size(),
		"stalled_p50": pct.call(st, 0.50),
		"stalled_p95": pct.call(st, 0.95),
		"stalled_max": int(st.max()) if not st.is_empty() else 0,
		"remesh_max": _sw_remesh_max,  # the armed re-bake queue depth, max
		"star_busy_frames": _sw_star_busy_frames,  # frames with relaxation work
		"star_pending_max": _sw_star_pending_max,  # queue depth at step start, max
		"star_drained_max": _sw_star_drained_max,  # cells drained in one step, max
		"star_pending_sum": _sw_star_pending_sum,
		"star_drained_sum": _sw_star_drained_sum,
	}

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
	# contained kernel (ChunkScript.build_accs / the C++ pull — AC-0283 P4:
	# the AweLighting TEST/REFERENCE class's kernel).
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

# AC-0263 (AC-0313): the per-slab high variant of _build_unit — dispatches
# ONE slab (the (taxi, layer) inside-out order's build unit) through the
# worker pool. Same
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

# AC-0335: the per-ring work choice — ONE function is the "one worker
# thread doing what is needed for the column based on its ring" switch.
# The caller (the _drain_build_queue steady pass — the ONLY scheduler,
# AC-0335) picks the next column by the (taxi, layer) grid order
# (_grid_score) and asks this what the column's ring owes:
#   ring 0/1 (real band + band A) -> the high slab build (both reach
#     _mesh_dispatch_hslab; band A's first dispatch is the
#     materialization — the mat entry — the branch that lives inside
#     _mesh_dispatch_hslab),
#   ring 2/3 (band B/C)           -> the far payload avg emit (the old
#     slab wave's dispatch — the grid sample + C++ low_emit_avg ride the
#     TM worker, the attach lands through _low_poll).
# Ring 4 (data-only, past the render edge) owes nothing — the pool
# filter never offers it (the data pass feeds it instead).
# Verdict: 1 = a unit consumed (the worker owns the work, or an air slab
# was bookkept terminal — nothing dispatched), 0 = the slab is already
# in flight (dedup — the handoff clears it), 2 = deferred (pool/cap
# saturated or a high defer — the caller ends the frame and retries next
# frame).
func _dispatch_column_work(c: Node3D, si: int) -> int:
	var tier := _lod_tier_of(int(c.cx) - last_pcx, int(c.cz) - last_pcz)
	match tier:
		0, 1:
			# The high slab build — _build_unit_hslab returns true when
			# DEFERRED (TM cap / in-flight dedup / data / neighbors /
			# sky eff / settle gate), false when the worker owns the slab.
			return 2 if _build_unit_hslab(c, int(c.cx), int(c.cz), si) else 1
		2, 3:
			# The far payload avg emit — _low_dispatch_slab's verdicts:
			# 1 = a worker owns the emit, 0 = in-flight dedup, 2 = the
			# low task queue is saturated (the slab stays PENDING), -1 =
			# a NULL slab (no grid to sample, no emit to run — the air
			# bookkeeping runs inline).
			var d := _low_dispatch_slab(c, si)
			if d < 0:
				_low_air_slab(c, si)
				return 1
			return d
		_:
			return 2  # tier 4 — data-only: no work (unreachable in the pool)

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
	# AC-0262 (AC-0335 UPDATED): high_only narrows the MESH pool to the
	# HIGH draw tiers (the real band + band A — _lod_tier_of ≤ 1). AC-0335
	# unified the lanes: the steady drain pass now takes the UNFILTERED
	# pool (high_only=false) — the far entries (rings 2/3) are in this
	# queue and owe their avg emit through _dispatch_column_work, so the
	# true-filter path is dead and sweeps at AC-0336.
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
				# AC-0345: the FAR lane's own readiness test — a settled
				# far column (live tier ≥ 2 whose low probe owes nothing:
				# _entry_best_pending < 0) leaves the candidate window the
				# way a meshed high column does. The c.mesh_built skip
				# above is the HIGH lane's test — a far column is never
				# mesh_built (the low lane stamps, not the high lane), so
				# without this test the R50 far wave starved: the 512
				# innermost settled far columns filled the band-order
				# window (PICK_POOL_CAP) permanently, the scan never
				# reached the columns behind them, and the far field
				# froze after exactly 8704 = 512 x 17 slabs with the
				# pools idle (the AC-0338 find). The queue entry STAYS:
				# the AC-0222 depth cap, the AC-0274 defer set and the
				# tier/knob re-dispatch all work on queue membership, and
				# a re-pended slab (a tier flip, an edit, a recenter)
				# re-admits the entry on the next scan (those events bump
				# _pool_ver and force the rescan). Tier 4 (data-only,
				# past the render edge) reads -1 from the probe and
				# leaves the window too — the pool contract already says
				# "ring 4 owes nothing, the data pass feeds it".
				var dxp := int(e["cx"]) - last_pcx
				var dzp := int(e["cz"]) - last_pcz
				if _lod_tier_of(dxp, dzp) >= 2 and _entry_best_pending_cached(c) < 0:
					continue
				if high_only:
					# AC-0262 (AC-0313): the visible band's build entries
					# are the slab wave's work list, not the drain's. The
					# per-pick high gate below the caller would null the
					# top pick every frame (the wave keeps up — its halo-
					# band entries always out-score the real band's entries
					# on taxi), and the deep-slab high band (a high layer
					# rank) starved behind them forever: a recentered center
					# chunk with deep pending slabs stayed unmeshed
					# indefinitely (measured: r16 settle frozen on 6 slabs
					# of the new taxi-0 chunk while the drain dispatched 0
					# units). Pre-filter the drain's pool to the REAL band
					# only (AC-0283 P3: the halo band's work is the slab
					# wave's, never the drain's).
					# AC-0312: the drain's pool is the HIGH draw tiers —
					# the REAL band (tier 0) + BAND A (tier 1, the
					# full-LOD materialization lane — AC-0312 restored it
					# to the drain). Bands B/C (2/3) are the slab wave's
					# (their avg LOD is final there); data-only (4) is
					# nothing (the old real-band-only filter starved the
					# band-A mat dispatches — the drain is the lane).
					var dxh := int(e["cx"]) - last_pcx
					var dzh := int(e["cz"]) - last_pcz
					if _lod_tier_of(dxh, dzh) > 1:
						continue
				out.append(e)
			else:
				if c == null or not c.data.is_empty():
					continue
				out.append(e)
	return out

# --- AC-0217: the cached scored picks (the pool/score debounce) ------------
# _pick_build_cached: the MESH candidate pick (the ThreadMesh pool feed):
# pool scan + re-validate + _build_ready (gen + light flat ready — the
# 8-neighbor gate; AC-0335: the gate is the HIGH draw tiers' — rings 2/3
# avg emits read their own payload only, no neighbors, as the old wave
# dispatch never had the gate) + the (taxi, layer) grid score, cached
# against the AC-0217 key (AC-0233/AC-0250: column + sim radius only —
# the tier order is invariant to in-column moves and to turns). On a hit
# the cached candidate is re-validated (c == null
# / data / mesh_built / _build_ready); a stale candidate re-scans instead of
# being served. A cached EMPTY pick is trusted: a membership or readiness
# change always bumps _pool_ver, so a matching key means a fresh scan would
# find nothing either.
# AC-0313: the `skip` parameter (the AC-0283 P3 startup 3x3 pass's
# per-frame defer set) is GONE with that pass.
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
		var etier := _lod_tier_of(int(e["cx"]) - last_pcx, int(e["cz"]) - last_pcz) if c != null else 4
		# AC-0335: the 8-neighbor gate re-validates the HIGH draw tiers
		# only (rings 2/3 avg emits read no neighbors — see the scan); a
		# cached tier-2/3 candidate must still OWE a low (a handoff or a
		# tier change completes it — the probe is the gate; see the
		# boundary-flip note in the scan).
		if c != null and not c.data.is_empty() \
				and not c.mesh_built \
				and (etier > 1 or _build_ready(int(e["cx"]), int(e["cz"]))) \
				and (etier <= 1 or _entry_best_pending_cached(c) >= 0):
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
		var etier := _lod_tier_of(int(e["cx"]) - last_pcx, int(e["cz"]) - last_pcz)
		# AC-0335: the 8-neighbor data gate is the HIGH draw tiers' (the
		# full-res build reads the 3x3x3 rings) — the far payload avg
		# emit (rings 2/3) reads its own payload only, so a far column
		# dispatches the moment its own data lands (the old wave's
		# dispatch never had the gate).
		if etier <= 1 and not _build_ready(int(e["cx"]), int(e["cz"])):
			continue
		# AC-0335 (the ladder's boundary-flip fix; AC-0345 UPDATED): a
		# tier-2/3 candidate must still OWE a low — a fully-lowered far
		# column (the probe owes nothing) is NOT a candidate. AC-0345:
		# the settled-far exclusion now lives in the POOL SCAN itself
		# (_collect_pool's build filter runs this same probe — a settled
		# far column no longer occupies a candidate-window slot, which
		# was the R50 far-wave starvation); this loop's gate is now the
		# same-frame race guard (a candidate settles between the scan
		# and this gate — a low handoff landing this frame). The entry
		# stays queued either way (a tier change / edit re-pends its
		# slabs and this SAME entry drives the re-dispatch — the old
		# slab wave depended on far entries' queue residency; the old
		# high-only drain never removed them).
		if etier > 1 and _entry_best_pending_cached(c) < 0:
			continue
		var s := _grid_score(e)  # AC-0313: the bake order (taxi, layer)
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
		# AC-0293: the spawn-fast skip is gone with the burst — the data
		# pass is the spawn's data source (it used to wait for the 5x5
		# group to own the spawn neighborhood; that is retired).
		if c != null and c.data.is_empty() \
				and not _tg_inflight_keys.has(e["key"]) \
				and not _io_read_keys.has(e["key"]):
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
		# AC-0293: the spawn-fast no-enqueue is GONE with the burst —
		# the data pass feeds the spawn neighborhood itself (the 5x5
		# group that used to own it is retired); the (taxi, layer)
		# score below still builds the innermost columns first.
		var s := _grid_score(e)  # AC-0313: the bake order (taxi, layer)
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

# AC-0284b: the promotion's owed full regens (the persistent retry).
# A no-caves column that crossed into the real band owes a FULL regen;
# the one-shot enqueue can cap-drop at the crossing, so the drain retries
# every frame (fresh identity capture — a pooled reuse is seen through
# the colgen) until it is accepted and lands. Clearing: a FULL landing
# sets no_caves false (the far payload goes with the replaced column);
# a column that left the real band again is far-owed (the halo draw is
# the far representation) — the next crossing re-ows it.
func _far_promo_owed_step() -> void:
	if _far_promo_owed.is_empty():
		return
	for key in _far_promo_owed.keys():
		var c = chunks.get(key)
		if c == null or not c.no_caves or not _is_real_col(int(c.cx) - last_pcx, int(c.cz) - last_pcz):
			_far_promo_owed.erase(key)
			continue
		# AC-0286: count the ACCEPTED enqueues (the retry contract —
		# dedup/cap-drop are not enqueues; one promotion per residency
		# must land exactly one). The landing clears no_caves, so a
		# second accepted enqueue for the same residency is a bug the
		# flight probe would catch (promo_enq_count > 1).
		var _ok_e: bool = threadgen_enqueue(int(c.cx), int(c.cz), key, c.get_instance_id(), true, int(c.col_gen))
		if _ok_e:
			promo_enq_count[key] = int(promo_enq_count.get(key, 0)) + 1
		# a dedup (a regen already in flight for this key) is fine — it
		# lands and clears no_caves; a cap-drop retries next frame.


func _promo_build_step() -> void:
	# AC-0286: the promotion burst (the retain-swap's fast path). One
	# best-pending slab per marked column per frame, dispatched through
	# the SAME _mesh_dispatch_hslab the lane and the remesh lane use —
	# the settled-payload box gate (a slab never dispatches on unsettled
	# light), the TM inflight cap, and the 1-slab/key dedup all apply
	# unchanged. What it bypasses is only the queue SCORE (the backlog
	# order) — the promoted column's slabs convert in ~24 frames + the
	# settle window instead of waiting out the ~5000-deep flight queue.
	# Bounded: the mark dies at mesh_built, so at most a few columns are
	# marked at once (promotions are crossings — ~1 per flight minute);
	# PROMO_BURST_COLS_PER_FRAME caps the per-frame extra units.
	if _promo_build.is_empty():
		return
	var n := 0
	for key in _promo_build.keys():
		if n >= PROMO_BURST_COLS_PER_FRAME:
			break
		n += 1
		var c = chunks.get(key)
		if c == null or bool(c.mesh_built):
			_promo_build.erase(key)
			continue
		var dx := int(c.cx) - last_pcx
		var dz := int(c.cz) - last_pcz
		if not _is_real_col(dx, dz):
			continue  # demoted — the mark waits (the re-entry resumes it)
		var si := _hslab_best_pending(c)
		if si < 0:
			continue
		_mesh_dispatch_hslab(c, int(c.cx), int(c.cz), si, {}, false)


func _drain_build_queue() -> void:
	_far_promo_owed_step()  # AC-0284b: the promotion's owed full regens
	_promo_build_step()  # AC-0286: the promotion burst (post-landing)
	# AC-0293: the burst apply pass (_startup_gen_apply) is gone with the
	# burst — spawn/recenter data lands through threadgen_handoff like
	# every other column.
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
	# AC-0313: the AC-0160 spawn-fast unit budget (3 -> 12 while the spawn
	# 3x3 is pending) is GONE with the walk regime — the drain is ALWAYS
	# the wall-clock paced unit budget + drain_budget_ms time cap (normal
	# streaming). startup = _startup_pending() stays for the 9-wide tm_cap
	# bumps and the small-move/window-growth pacing (AC-0293: the burst
	# hold + _spawn_fast latch that also keyed off it are gone with the
	# 5x5 burst — spawn/recenter ride this same drain).
	var startup := _startup_pending()
	# AC-0178: loading window — unbounded unit budget, LOAD_DRAIN_BUDGET_MS
	# time budget. AC-0335 (one work order, one dispatch): the steady-
	# state UNIT budget is ONE wall-clock paced accumulator for EVERY ring
	# (gen enqueue + high slab + far emit all ride it). PACING DECISION —
	# which of the two pre-unification paces survives: BOTH candidates
	# (the drain's DRAIN_UNIT_PACE_MS 8 ms/unit and the far lane's
	# LOW_WAVE_PACE_MS 3.5 ms/slab) are wall-clock accumulators, and that
	# is exactly what AC-0231's fps-independence constraint requires —
	# "the game must build at the same wall-clock pace at 30 fps as at
	# 60 fps; a low frame rate must never let the player out-fly the
	# build pipeline". A dt-sampled, dt-clamped accumulator with a
	# per-frame catch-up cap IS fps-independent by construction (there is
	# no per-frame rate to rescale), so AC-0231 rules OUT a per-frame
	# reinterpretation but does not pick between the two wall-clock
	# models. The tie-break is tuning: LOW_WAVE_PACE_MS (3.5 ms/unit,
	# cap LOW_WAVE_FRAME_CAP = 8) SURVIVES because it was tuned "just
	# above the ~33/s TG data-landing rate" — the far fill is
	# data-limited, not dispatch-limited, and keeping the pace keeps the
	# far band's fill rate (and the r16 wall — at the arm's 600 fps the
	# pace constant dominates at ~285 units/s) at its tuned value; the
	# high lane riding the same pace adds no main-thread cost while the
	# TM pool is saturated (a deferred dispatch ends the frame, as
	# before) and only fills an underfull pool faster — the real work is
	# bounded by threadmesh_max inflight + the stream_ho_cap attach pace,
	# not by the dispatch rate. Measured fps-independence: the cap is
	# frame-rate bound — 8 units x 30 fps = 4-5 units x 60 fps ≈ the same
	# ~240-270/s wall rate at both rates (the bounded quantization of a
	# 3.5 ms tick against a 16.7 ms frame, the same arithmetic the far
	# lane ran under AC-0231; perf r4 --fixed-fps 30 vs 60 in the
	# AC-0335 results). DRAIN_UNIT_PACE_MS / DRAIN_UNIT_PACE_SLOW_MS /
	# DRAIN_UNITS_FRAME_CAP are no longer consulted (the fast/slow
	# last_build_us governor retires with them — AC-0336 sweeps the
	# constants); drain_budget_ms (the wall-clock time cap),
	# DRAIN_DT_CLAMP_MS and DRAIN_WIN_PACE_MS STAY — they are the
	# scheduler's frame guards, not a second pace.
	var now_ms := Time.get_ticks_msec()
	var frame_dt_ms := 16.67
	if _drain_last_t > 0:
		frame_dt_ms = minf(float(now_ms) - float(_drain_last_t), DRAIN_DT_CLAMP_MS)
	_drain_last_t = now_ms
	var unit_pace := LOW_WAVE_PACE_MS
	var budget := 0
	if loading_active:
		budget = LOAD_DRAIN_UNITS
	else:
		# AC-0335: the ONE wall-clock paced unit budget (see the pacing
		# decision above) — the old per-frame spawn/walk budgets are long
		# gone (AC-0160/AC-0313); the trickle fills the footing at walk.
		_drain_acc_ms = minf(_drain_acc_ms + frame_dt_ms, float(LOW_WAVE_FRAME_CAP) * unit_pace)
		budget = mini(LOW_WAVE_FRAME_CAP, int(_drain_acc_ms / unit_pace))
	# AC-0213: small-move budget — right after a recenter the ahead ring was
	# just (re)queued; pace the drain at the trickle rate (1 unit/frame) for
	# SMALL_MOVE_BUDGET_MS so a tap forward does not burst 2 gen+build units
	# on top of the recenter slice work.
	if budget > 1 and not startup and not loading_active and Time.get_ticks_msec() < _sm_move_until:
		budget = 1
	# AC-0313: the AC-0283 P3 walk regime (slow_cross / startup3x) and the
	# unbounded `1e9 if startup` time budget are GONE — the drain is ALWAYS
	# time-capped at drain_budget_ms (the loading window keeps its own
	# LOAD_DRAIN_BUDGET_MS loop above). AC-0293: the 5x5 startup burst is
	# retired — nothing special about spawn/recenter in this drain. No
	# main-thread blocking build pass after the player is active.
	var budget_us := int(drain_budget_ms * 1000)
	# AC-0160: windowed pool scan. The drain scans buckets 0.._drain_win_b
	# only (initial b1_eff+2 — the spawn ring, reached by normal streaming
	# now the spawn-fast window is gone, AC-0293); the trickle window grows
	# one bucket per DRAIN_WIN_PACE_MS (wall clock — was 15 frames) until it
	# spans the whole queue, so the queue trends down continuously instead
	# of stranding the far tail.
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
		var _lw_now := Time.get_ticks_msec()
		if _loadwin_ms == 0 or _lw_now - _loadwin_ms >= 100:
			if _loadwin_ms > 0 and _loadlog_on:
				print("LOADWIN t=%d disp=%d skip=%d nopick=%d maxinf=%d tm=%d tg=%d" % [
					_lw_now - _loadlog_t0, _loadwin_disp, _loadwin_dedup, _loadwin_nopick, _loadwin_maxinf, threadmesh_inflight.size(), threadgen_inflight.size()])
			_loadwin_ms = _lw_now
			_loadwin_disp = 0
			_loadwin_dedup = 0
			_loadwin_nopick = 0
			_loadwin_maxinf = 0
		var lp_t0 := Time.get_ticks_usec()
		# AC-0274: the per-column defer set persists for the WHOLE frame
		# loop (not per pass): a pass that dispatches column A and then
		# finds B's slab already in flight must skip B on its NEXT pass -
		# a fresh set per pass re-picked the same in-flight column and
		# spun the 300 ms frame budget with zero progress (self-starvation:
		# the poll/handoff and the recenter queue walk never ran).
		var _lw_skip: Dictionary = {}
		var _lw_disp_n := 0  # AC-0274: per-frame dispatch cap (frame bound)
		while Time.get_ticks_usec() - lp_t0 < LOAD_DRAIN_BUDGET_MS * 1000:
			if _lw_disp_n >= LOAD_HSLAB_UNITS_PER_FRAME:
				break
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
				if _lw_skip.has(e["key"]):
					continue  # AC-0274: deferred earlier this frame (dedup/nbs)
				# AC-0257 (AC-0263): keep-high — a meshed column is skipped.
				if c == null or c.data.is_empty() or c.mesh_built:
					continue
				# AC-0261 (AC-0263, AC-0283 P3): the load's high builds are
				# the REAL band only — the halo band (band0_r, render_radius)
				# is slab-wave owned (its avg LOD is final there).
				var dxl := int(e["cx"]) - last_pcx
				var dzl := int(e["cz"]) - last_pcz
				if not _is_real_col(dxl, dzl):
					continue
				if not _build_ready(int(e["cx"]), int(e["cz"])):
					load_phase1_ready_fail += 1
					continue
				var s := _grid_score(e)  # AC-0313: the bake order (taxi, layer)
				if s < ls:
					ls = s
					le = e
					lc = c
			if lc == null:
				_loadwin_nopick += 1
				break
			# AC-0263: per-slab — a high-complete winner (a landing raced the
			# pick) frees its entry and the loop re-picks; otherwise the best
			# slab is dispatched and the entry STAYS queued for the rest.
			var sih := _hslab_best_pending_cached(lc)
			if sih < 0:
				# AC-0263 (AC-0313): the probe is always FULL — a -1 IS
				# completion; the entry is freed and the loop re-picks
				# (the AC-0263 windowed -1 hold is gone with the Y-window).
				_remove_entry(le)
				continue
			var _lw_deferred := _build_unit_hslab(lc, int(le["cx"]), int(le["cz"]), sih)
			_loadwin_maxinf = maxi(_loadwin_maxinf, threadmesh_inflight.size())
			if _lw_deferred:
				if _hslab_last_defer == 2:
					break  # TM pool full — phase 2 feeds the TG pool now
				# AC-0274: a PER-COLUMN defer (a slab of this column is
				# already in flight / a neighbor is ungenerated) must not end
				# the pass — the deterministic re-pick would loop on the same
				# best column forever (the one-column-at-a-time load stall:
				# ~200 ms worker time x 8 slabs x 113 columns, serial). Skip
				# the column for this pass and try the next-best.
				_lw_skip[_key(int(le["cx"]), int(le["cz"]))] = true
				_loadwin_dedup += 1
				continue
			_loadwin_disp += 1
			_lw_disp_n += 1
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
				# AC-0293: the spawn-fast skip is gone with the burst — this
				# full-throttle feed IS the spawn's data source now.
				var s := _grid_score(e)  # AC-0313: the bake order (taxi, layer)
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
	# AC-0313: the AC-0283 P3 WALK-REGIME startup 3x3 completion pass is
	# GONE — it existed because the Y-window (AC-0263) left the 3x3's
	# windowed neighbors forever window-pending (mesh_built never flipped,
	# _startup_pending latched, the data feed starved). With FULL columns
	# (no window) every column completes and frees its entry, the trickle
	# drain reaches the crossed 3x3 on its own, and no special pass is
	# needed — and no main-thread blocking build pass runs after the
	# player is active.
	# AC-0335 (the AC-0262 one-scan discipline): the per-frame skip-aware
	# candidate LIST — a frame's FIRST defer rescans the pool ONCE
	# (collected in score order); later defers in the same frame advance
	# through the list instead of rescanning (a per-defer rescan would be
	# the AC-0262 LOW_PICK storm: N defers x O(pool) re-scores/frame).
	var steady_skip: Dictionary = {}
	var steady_list: Array = []
	var steady_i := 0
	while budget > 0:
		if Time.get_ticks_usec() - t0 > budget_us:
			break
		var u := 0  # a build dispatched this frame (the data pass paces on it)
		# AC-0335: ONE ORDER, THE RING DECIDES THE WORK. The top pick is
		# the next column in the (taxi, layer) grid order across ALL the
		# draw tiers (high_only=false — the far entries are in this queue
		# and owe their avg emit), and its ring (_lod_tier_of) decides
		# what gets done for it — the one per-ring switch is
		# _dispatch_column_work:
		#   ring 0/1 (real band + band A) -> the high slab build (a
		#     band-A column's first dispatch is the materialization —
		#     the mat entry — inside _mesh_dispatch_hslab),
		#   ring 2/3 (band B/C)           -> the far payload avg emit
		#     (the old slab wave's dispatch).
		# A column ENTERING the real band (ring 2/3 -> 0/1) is simply the
		# next column in this order whose ring changed — the high build
		# is just this loop's ring-0/1 work (keep-high: its stored lows
		# flip on demote, low_downgrade_n stays 0).
		# The build unit is ONE SLAB — the column's best pending slab at
		# its ring's lane (the (taxi, layer) order: the innermost column
		# first, its slabs fanned in Y-distance from the player's slab).
		# A complete column (the lane's probe owes nothing — a landing
		# raced the pick, or the lows are fully terminal) frees its queue
		# entry; a pending column dispatches its best slab and STAYS
		# queued (re-picked; the in-flight dedup paces one slab per
		# column PER FRAME — the defer set below).
		# AC-0335 (the AC-0274 pattern, unified): the per-frame per-column
		# DEFER set — a per-column defer (a slab in flight, data /
		# neighbors / sky not ready, a low in-flight dedup, a low cap hit
		# on ANOTHER column's slab) skips that column for the rest of the
		# frame and re-picks the NEXT-BEST, so one frame dispatches
		# SEVERAL distinct columns — the old slab wave's same-frame
		# parallelism (its batch scanned up to LOW_WAVE_FRAME_CAP
		# distinct candidates per frame). A deterministic re-pick without
		# the set would loop on the same in-flight column forever (the
		# one-column-at-a-time stall AC-0274 killed in the loading
		# window). Only a POOL-FULL defer (the TM cap / the LOW_TASK_CAP)
		# ends the frame — nothing else can dispatch behind a saturated
		# pool.
		var unit_done := false
		while budget > 0 and not unit_done:
			# AC-0217/AC-0233/AC-0250: the scored pick is cached against
			# (queue version + maxb + spawn-fast + center + sim radius) —
			# since the look left the key (AC-0250), it is a pure function
			# of the pool state: an idle frame with an unchanged world
			# serves the last pool/score and skips the rescan + rescore.
			var bpick := _pick_build_cached(maxb, false, false)
			var best_e: Dictionary = bpick["e"]
			var best_c: Node3D = bpick["c"]
			var best_s: float = bpick["s"]
			var best_from_fb := false  # AC-0217 pick trace: which pass won
			if steady_skip.size() > 0 and (best_c == null or steady_skip.has(_key(int(best_e["cx"]), int(best_e["cz"])))):
				# AC-0335: a column was deferred earlier this frame — the
				# cached pick cannot skip it. The per-frame list (ONE scan
				# per defer frame — the AC-0262 one-scan discipline)
				# serves the next best non-deferred candidate; each
				# served candidate is re-checked against the live state
				# (a removal or a completion that raced the list is
				# skipped — the probe is the gate).
				if steady_i >= steady_list.size():
					# AC-0335 (stale-list fix): the list is a SNAPSHOT — an
					# entry leaves the queue mid-frame (the sigo<0 remove
					# below) and a stale slot would re-present a column the
					# pool no longer holds: the live-chunk re-check passes
					# (the chunk still exists), the dispatch probe says
					# -1, and _remove_entry on the already-gone entry is a
					# silent no-op that bumps no _pool_ver — the pick
					# cache stays warm, the same slot is served again, and
					# the inner loop spins with a frozen state (the
					# battery's light;fluids stall: 99.9% main thread,
					# workers idle). The membership check below keeps the
					# slot honest; the clear keeps rebuilds duplicate-free.
					steady_list.clear()
					for e in _collect_pool(true, false, maxb, false):
						if steady_skip.has(_key(int(e["cx"]), int(e["cz"]))):
							continue
						var c = chunks.get(e["key"])
						if c == null or c.data.is_empty() or c.mesh_built:
							continue
						var etier := _lod_tier_of(int(e["cx"]) - last_pcx, int(e["cz"]) - last_pcz)
						if etier <= 1 and not _build_ready(int(e["cx"]), int(e["cz"])):
							continue
						if etier > 1 and _entry_best_pending_cached(c) < 0:
							continue
						steady_list.append([_grid_score(e), e, c])
					steady_list.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
					steady_i = 0
				while steady_i < steady_list.size():
					var le: Dictionary = steady_list[steady_i][1]
					var lc: Node3D = steady_list[steady_i][2]
					if not steady_skip.has(_key(int(le["cx"]), int(le["cz"]))) \
							and queued_keys.has(le["key"]) \
							and lc != null and not lc.data.is_empty() and not lc.mesh_built \
							and (_lod_tier_of(int(le["cx"]) - last_pcx, int(le["cz"]) - last_pcz) <= 1 \
									or _entry_best_pending_cached(lc) >= 0):
						break
					steady_i += 1
				if steady_i < steady_list.size():
					best_s = float(steady_list[steady_i][0])
					best_e = steady_list[steady_i][1]
					best_c = steady_list[steady_i][2]
				else:
					best_e = {}
					best_c = null
					best_s = 1e30
			if best_c == null:
				# AC-0079 v3 C1: lead-column pre-build, second pass. The
				# in-radius READY pool is empty — pick the lowest-score
				# READY candidate from _collect_pool(true, true). In-radius
				# READY ALWAYS wins (this pass only runs when the first
				# pass found nothing); the forward band is exactly 2r+1
				# entries, so the pass is bounded.
				var fpick := _pick_build_cached(maxb, true, false)
				# AC-0335: the FB pass must honor the defer set — the lead
				# column (tier 4, data-only) is never work, and re-offering
				# a column deferred earlier this frame would loop the inner
				# pick forever (the first AC-0335 build hung exactly there:
				# the tier-4 lead re-presented on every inner iteration,
				# deferred, re-presented — physics never fired).
				if not (fpick["e"] as Dictionary).is_empty() and float(fpick["s"]) < best_s \
						and not steady_skip.has(_key(int(fpick["e"]["cx"]), int(fpick["e"]["cz"]))):
					best_s = float(fpick["s"])
					best_e = fpick["e"]
					best_c = fpick["c"]
					best_from_fb = true
			if best_c == null:
				break  # no candidate — u stays 0, the data pass below runs
			var dxg := int(best_e["cx"]) - last_pcx
			var dzg := int(best_e["cz"]) - last_pcz
			var tierg := _lod_tier_of(dxg, dzg)
			var sigo: int
			if tierg <= 1:
				sigo = _hslab_best_pending_cached(best_c)
			else:
				sigo = _entry_best_pending_cached(best_c)
			if sigo < 0:
				# The column is COMPLETE at its ring (the lane's probe is
				# always FULL — a -1 is a genuine "nothing owed"):
				#   ring 0/1 — TERMINAL: the high build is done (the
				#     column is meshed — the pool excludes it now); free
				#     the entry (the build-order contract: a completed
				#     column frees its queue entry); the removal bumps
				#     _pool_ver, so the re-pick below re-scans.
				#   ring 2/3 — NOT terminal: a far column's "complete" is
				#     stale-prone (a low_start/medium_start change, an
				#     edit, a demote re-pends its slabs) and the queue
				#     entry is what drives the re-dispatch (the old slab
				#     wave depended on far entries' queue residency — the
				#     old high-only drain never removed them). AC-0345:
				#     the pick's pending gate (this probe test) lives in
				#     the pool scan now, so this -1 is a pure same-frame
				#     race (the candidate settled between the scan and
				#     this dispatch probe): the entry STAYS and the
				#     column is deferred for the frame (the fresh re-pick
				#     skips it).
				if tierg <= 1:
					_remove_entry(best_e)
				else:
					steady_skip[_key(int(best_e["cx"]), int(best_e["cz"]))] = true
				continue
			var dv := _dispatch_column_work(best_c, sigo)
			if dv != 1:
				# dv 0 = a task already in flight for this slab (the
				# handoff clears it — the slab leaves the pending set at
				# its _low_poll / TM landing), dv 2 = a cap saturated
				# (the LOW_TASK_CAP low queue, or the TM pool for a high
				# dispatch). POOL-FULL ends the frame (nothing else can
				# dispatch behind it); everything else is PER-COLUMN —
				# defer the column, try the next-best (AC-0274). The drain
				# NEVER takes a sync fallback (AC-0263: there is no sync
				# build left).
				var pool_full := (tierg > 1 and dv == 2) \
						or (tierg <= 1 and _hslab_last_defer == 2)
				if pool_full:
					break
				steady_skip[_key(int(best_e["cx"]), int(best_e["cz"]))] = true
				continue
			if _picklog:
				print("PICK %s %d,%d slab=%d s=%.6f t=%d" % ["fb" if best_from_fb else "b", int(best_e["cx"]), int(best_e["cz"]), sigo, best_s, Time.get_ticks_msec()])
			u = 1
			unit_done = true
		# AC-0322: the AC-0283 P3 TG-empty data feed is RESTORED. AC-0313
		# removed it believing the FULL-column free-on-complete made the
		# u==0 gate sufficient — but the build unit is ONE SLAB, so an
		# entry frees once per 24 slabs and the high pool (real band +
		# band A) is almost always owed while walking: u==1 every frame,
		# the data pass runs at the column-completion rate (~5 cols/s),
		# the 2-slot TG pipeline sits idle (tg_inf ~ 0) and the walk's
		# taxi-8 sim disc plateaus at ~53-61% (AC-0312 profile + this
		# ticket's before run). Re-enqueuing on a DRAINED TG pool keeps
		# the pipeline fed (~16-20 cols/s, more than the ~5-8 cols/s rim
		# growth) and self-limits: one enqueue per drained frame, the
		# pool refills to threadgen_max, the break below ends the frame.
		# The predicate is stateless (no slow_cross / no timer — the
		# AC-0313 clause-5 rule), and the enqueue is a worker submit
		# (µs main thread; the gen work was always going to run — only
		# its innermost-first order is restored). On flight the recenter
		# burst normally keeps the TG fed, so the drained-pool branch
		# rarely fires there.
		if (u == 0 or threadgen_inflight.size() == 0) \
				and (gen_budget_ms < 0 or gen_used_ms < gen_budget_ms):
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
	# AC-0283 P4: REFERENCE/TEST ONLY — no game call site (the C++
	# AweStrips.compute_face is always available; AC-0208 C++-ONLY), the
	# harness stripsprobe arm calls it as the A/B reference.
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
# AC-0283 P2: the landing E2 wave (_eff_landed + the _frame_changed /
# _frame_nonzero side gates) is retired — the settled-column drain
# (_star_settled_drain -> _star_e2_rearm) runs the same per-slab
# frame gate against the engine (C++ star.frame_diff) on the SETTLED
# light, and the face/eff caches ride the eff_gen deps (lazy).
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
# neutral. No light math changed (byte-identity: the deleted batch/chunk
# entries both routed through _chunk_light_into — AC-0283 P4 removed them
# as the last zero-caller GD entries).

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
	# <=2 staged columns/frame (the pacing contract) AND <= collide_drain_
	# budget_ms of body derivation (the AC-0340 time cap — the drain_budget_ms
	# model bounds the build lane the same way). Nearest-first, behind the
	# build queue. A column whose slabs outlast the budget is RE-QUEUED
	# (debt, perf_col_deferred) — never dropped: a dropped entry lost validity
	# before its drain (eviction / band change / the mesh finished).
	#
	# THE FENCE: a column inside the IMMEDIATE footprint (the _col_immediate_for
	# predicate — Chebyshev <= 1 of the anchor, plus the (0,0) spawn column)
	# is built in full, ignoring the budget. A missing body under the player
	# was a shipped bug (chunk.gd:1355 "the player falls through"): the budget
	# must never defer a slab inside that footprint. perf_col_deferred_in_
	# footprint is the tripwire (boundary/perf/player arms read it); the
	# arm-side footprint scan is the independent check. Note the (0,0) column
	# CAN sit in this queue (the band-0 re-entry staging at _reband does not
	# foot-check) sorted by distance — so a spent budget SKIPS out-of-
	# footprint entries and keeps scanning rather than breaking.
	if _col_pending.is_empty():
		return
	_col_pending.sort_custom(func(a, b): return _col_dist(a) < _col_dist(b))
	var done := 0
	var i := 0
	var t0 := Time.get_ticks_usec()
	var budget_us := int(collide_drain_budget_ms * 1000)
	while done < 2 and i < _col_pending.size():
		var key: String = _col_pending[i]
		var c = chunks.get(key)
		if c == null:
			# Stale (the chunk was freed) — cancel regardless of the budget
			# (no work is owed; a never-served entry would only accumulate).
			_col_pending.remove_at(i)
			_col_pending_set.erase(key)
			perf_staged_dropped += 1
			continue
		var footprint: bool = _col_immediate_for(int(c.cx), int(c.cz))
		if not footprint and Time.get_ticks_usec() - t0 >= budget_us:
			# The budget is spent — this out-of-footprint entry keeps its
			# debt in the queue; the loop advances (it may hold a footprint
			# entry behind it, which is still served unbounded).
			i += 1
			continue
		var ok: bool = c != null and c.mesh_built and c.collision_enabled and c.any_col_dirty() and maxi(absi(int(c.cx) - last_pcx), absi(int(c.cz) - last_pcz)) <= render_radius
		_col_pending.remove_at(i)
		_col_pending_set.erase(key)
		if not ok:
			perf_staged_dropped += 1
			continue
		var _ct := Time.get_ticks_usec()  # AC-0337 step 0: the COLLIDE sub-stage (staged side)
		# -1 = unbounded (the fence) or the remaining budget in usec.
		var rem_us: int = -1 if footprint else (budget_us - (Time.get_ticks_usec() - t0))
		c.build_dirty_slab_bodies(rem_us)
		_wprof_add(WP_COLLIDE, Time.get_ticks_usec() - _ct)
		if not c.any_col_dirty():
			_count_collision_build(c)
			perf_staged_drained += 1
		else:
			# AC-0340: budget-deferred — the column keeps its dirty slabs
			# (the debt) and re-enters the queue (nearest-first re-sort next
			# frame). The old code DROPPED a still-dirty column here; with a
			# budget that is the normal exit of a partial column. This
			# PARTIAL build was a batch — count it now: build_dirty_slab_
			# bodies resets last_collision_build_ms at entry, so the partial
			# ms is lost if the count waits for the full drain (the per-slab
			# census at the choke point is unaffected either way).
			_count_collision_build(c)
			_col_pending.append(key)
			_col_pending_set[key] = true
			perf_col_deferred += 1
			if footprint:
				# Structurally unreachable (the footprint is unbounded —
				# build_dirty_slab_bodies(-1) clears every owed slab): a
				# non-zero reading means a future change re-introduced the
				# fall-through class. The gates read it.
				perf_col_deferred_in_footprint += 1
		done += 1

func _count_collision_build(c: Node3D) -> void:
	var dt := int(c.last_collision_build_ms)
	if dt > 0:
		perf_collision_ms += dt
		perf_collision_n += 1
		if dt > perf_collision_max_ms:
			perf_collision_max_ms = dt

# AC-0337 step 0: one slab body was derived (chunk.gd _build_slab_collision,
# usec since its entry). Bins are ms; the histogram is RESULT-ready via
# collision_slab_hist_dict().
func _count_collision_slab(us: int) -> void:
	perf_collision_slabs += 1
	var ms := float(us) / 1000.0
	perf_collision_slab_ms += ms
	if ms > perf_collision_slab_max_ms:
		perf_collision_slab_max_ms = ms
	if ms < 1.0:
		perf_collision_slab_hist[0] += 1
	elif ms < 2.0:
		perf_collision_slab_hist[1] += 1
	elif ms < 5.0:
		perf_collision_slab_hist[2] += 1
	elif ms < 10.0:
		perf_collision_slab_hist[3] += 1
	elif ms < 25.0:
		perf_collision_slab_hist[4] += 1
	else:
		perf_collision_slab_hist[5] += 1

func collision_slab_hist_dict() -> Dictionary:
	return {
		"lt1ms": int(perf_collision_slab_hist[0]),
		"1_2ms": int(perf_collision_slab_hist[1]),
		"2_5ms": int(perf_collision_slab_hist[2]),
		"5_10ms": int(perf_collision_slab_hist[3]),
		"10_25ms": int(perf_collision_slab_hist[4]),
		"gte25ms": int(perf_collision_slab_hist[5]),
	}

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
	# AC-0278: no flag to set - the out-of-set distance IS the candidacy;
	# this is the one-time entry work for a chunk that just left the set.
	c.cand_since = 0
	# AC-0231: the old LOD cache clear (lod_pending/clear_lod_cache) is gone
	# with band 2 — the retained mesh is full fidelity (keep-high).
	var had_mesh: bool = c.mesh_built
	if had_mesh:
		# Pending mesh-bound work on an out-of-set chunk is stale; re-entry
		# re-marks it dirty via the normal paths. The eff cache stays — data
		# is kept, so the cached light is still valid on re-entry.
		# (AC-0283 P2: the light-pending flush queue is gone — the remesh
		# lane's entries self-expire at dispatch (the chunk check).)
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
	# AC-0283 P2: the engine evicts with the chunk (bounded memory — the
	# live set only; a reloaded column re-seeds at its data landing).
	if star != null:
		star.evict_column(int(c.cx), int(c.cz))
	star_owed.erase(key)
	star_remesh.erase(key)
	# AC-0286: the promotion probe counters die with the column (a
	# freed-and-reloaded column is a NEW residency — its counts restart).
	star_seed_count.erase(key)
	star_seed_us.erase(key)
	promo_enq_count.erase(key)
	promo_land_count.erase(key)
	promo_land_ms.erase(key)
	_far_promo_owed.erase(key)
	_promo_build.erase(key)
	_stream_outside.erase(key)  # AC-0350: the bounded sweep's outside set
	_real_demote_owed.erase(key)  # AC-0350: the AC-0346 backstop flag
	chunks.erase(key)
	queued_keys.erase(key)
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

# AC-0263 spec (keep-all-LOD, 2026-09-13): a column that crossed OUT of
# the high band on a recenter keeps its stored high - nothing is freed,
# no fog veil (the user's "fog cubes" were this path). Per slab: one that
# already holds a READY low (a prior round-trip, fresh stamp + tier)
# flips NOW (high off, low on - one visible tier at a time); the rest
# keep SHOWING the high until the low lands and _low_place_slab
# flips them. mesh_built stays as-is: a complete high is STILL complete
# (it is stored on the node) - the drain must not re-pick the column
# (the re-entry flip is visibility-only); a PARTIAL
# high keeps mesh_built=false and the high lane rebuilds the missing
# slabs on re-entry (the AC-0278 re-queue).
# AC-0312: the real -> band demotion's data side — the full (caved)
# slabs are replaced with the h-only far form (generate_far: the
# canonical no-cave H + biome + top, bit-exact with the full path's
# surface H — the promotion contract). The resident high mesh stays
# (band A shows it, B/C store it hidden). The no-caves umbrella makes
# the promotion's full regen owed (AC-0286, unchanged). A generation
# failure (no extension) leaves the column as-is (the demote is a
# memory optimization, never a data loss — the slabs stay resident).
func _demote_to_far(c: Node3D, key: String) -> void:
	var g: Variant = WorldGen.gen_cpp()
	if g == null:
		return
	crx_gen_far_sync += 1  # AC-0348 census: the synchronous generate_far (only caller: the recenter walk's _demote_high_band_exit)
	var pay: PackedByteArray = g.generate_far(int(c.cx), int(c.cz), int(Game.world_seed), int(Data.HEIGHT), int(Data.SEA))
	if pay.size() != 1024:
		return
	c.far_h = pay.slice(0, 512)
	c.far_biome = pay.slice(512, 768)
	c.far_top = pay.slice(768, 1024)
	c.far = true
	var hmax := 0
	for i in range(256):
		var hv := int(c.far_h[2 * i]) | (int(c.far_h[2 * i + 1]) << 8)
		if hv > hmax:
			hmax = hv
	c.far_hmax = hmax
	c.far_veg = PackedByteArray()
	c.far_eff = {}  # the cached sky eff dies with the old data (recomputed on the next band-A dispatch)
	c.far_mat = false
	c.no_caves = true
	# free the slabs (the stamp bump re-pends nothing visible — the probe
	# reads the far representation; the mesh instances stay attached).
	c.clear_data()
	_hslab_probe_invalidate(c)
	_low_probe_invalidate(c)

func _demote_high_band_exit(c: Node3D, key: String) -> void:
	var tier := _lod_tier_of(int(c.cx) - last_pcx, int(c.cz) - last_pcz)
	var flipped := 0
	var reopened := 0
	# AC-0312: the flip (the ready stored low takes over) is owed in BANDS
	# B/C only — band A (tier 1) keeps showing the high (the full-LOD draw
	# tier); a low flip there would show the wrong tier (the wave skips
	# band A — the low is not even emitted for it).
	if tier > 1:
		for si in range(c.data.size()):
			if c.has_low_si(si) and not _low_slab_pending_at(c, si, tier):
				# the ready stored low takes over - the atomic flip.
				c.high_slab_visible(si, false)
				c.low_slab_visible(si, true)
				flipped += 1
			else:
				# no ready low: the high keeps showing. Re-open the low
				# obligation so the wave claims the slab at the new tier
				# (the flip lands in _low_place_slab); a genuine all-air
				# mark costs one re-sample, which re-marks it.
				c.low_failed.erase(si)
				reopened += 1
	# AC-0312: the keep-all-LOD DATA retention is RETIRED — a demoted
	# column's FULL (caved) data is replaced with the h-only far form
	# (generate_far: the canonical no-cave H + biome + top — bit-exact
	# with the full path's surface H: the save form, the snap rings, the
	# promotion contract). The resident HIGH mesh stays (a DATA swap,
	# not a mesh free — band A shows it, B/C keep it stored hidden; the
	# re-entry flip is a visibility toggle). A demoted band-A column is
	# then the steady band-A state: h-only payload + materialized mesh,
	# mesh_built (no re-materialization owed — the mesh is current; the
	# promotion's full regen re-converges any cave-breakthrough delta).
	if tier >= 1 and not c.far and not c.data.is_empty():
		_demote_to_far(c, key)
	if reopened > 0:
		# AC-0284b: a slab owes a re-lower (stale after the promotion's
		# full regen bumped data_gen, or no low at all on a first demote)
		# — but the column is meshed, so the recenter recompute gave it no
		# queue entry and the slab wave (which only scans queued entries)
		# can never reach it. Owe the re-lower: the low step dispatches
		# the column's best pending slab through the normal lane and the
		# re-landing attach flips the tiers.
		_low_relower_owed[key] = true
	_hslab_probe_invalidate(c)
	_low_probe_invalidate(c)
	demoted_cols_n += 1
	if timing or _tm_debug:
		print("DEMOBAND %s flipped=%d reopened=%d" % [key, flipped, reopened])


# AC-0263 spec (keep-all-LOD): a column that crossed BACK into the high
# band on a recenter flips its stored highs back on - a visibility
# toggle, NEVER a rebuild (the instances were kept on the node). A slab
# with no stored high, or a STALE one (data changed after the high
# landed - high_stamps != data_gen), keeps its low active; the high probe
# owes it and the high lane rebuilds it (the AC-0278 re-queue re-enters
# such columns, and the landing flips per the hslab rule). mesh_built is
# re-derived from the probe (a column that still owes slabs re-queues; a
# fully stored one stays drained).
func _reentry_flip_high(c: Node3D, key: String) -> void:
	var flipped := 0
	for si in range(c.data.size()):
		if c.data[si] == null:
			continue
		if c.slabs[si].mesh_instance == null:
			continue  # no stored high (the lane builds it if owed)
		if int(c.high_stamps.get(si, -1)) != int(c.data_gen):
			continue  # stale stored high (the lane rebuilds it)
		# AC-0263 spec: a stored high that never saw its first flush stays
		# hidden (the flush settles + shows it). AC-0283 P2: per-slab — the
		# settled-bake mark (the engine gate made it final) decides, not the
		# chunk-level flag.
		if bool(c.flush_slabs.has(si)):
			c.high_slab_visible(si, true)
		if c.has_low_si(si):
			c.low_slab_visible(si, false)  # stored (flip on the next demote)
		flipped += 1
	if flipped > 0:
		_low_probe_invalidate(c)
	_hslab_probe_invalidate(c)
	c.mesh_built = _hslab_best_pending(c) < 0  # AC-0263 spec (AC-0313): FULL probe
	if timing or _tm_debug:
		print("FLIPBACK %s flipped=%d mesh_built=%d" % [key, flipped, int(c.mesh_built)])


func recenter(wx: float, wz: float, mesh_now := true, wy: float = -1.0) -> void:
	# AC-0348: the crossing ring — bracket the WHOLE synchronous sweep
	# (this call runs from the physics frame, outside the wprof partition)
	# and count its cause census (see CROSSING_RING_CAP above).
	# Instrumentation only — no behaviour change.
	var crx_t0 := Time.get_ticks_usec()
	var crx_genfar_base := int(crx_gen_far_sync)
	var cx_demoted := 0
	var cx_promoted := 0
	var cx_halo_evicts := 0
	var cx_reentry_flips := 0
	var cx_scanned := 0
	# AC-0275: the PRE-move center (the band-exit demote compares each
	# column's old and new taxi).
	var opcx := last_pcx
	var opcz := last_pcz
	var pcx := int(floorf(wx / 16.0))
	var pcz := int(floorf(wz / 16.0))
	# AC-0277: the fast-crossing predicate (the old AC-0213 debounce
	# predicate's successor) - measured between PLAYER chunks (the ahead
	# targets are never stored in _last_recenter_pcx). The crossing delta
	# is also the ahead DIRECTION.
	var _cross := absi(pcx - _last_recenter_pcx) + absi(pcz - _last_recenter_pcz)
	# AC-0277: the fast window is measured from the last PLAYER-CHUNK
	# CROSSING (_last_cross_ms) - not _last_recenter_ms: the snap-back and
	# Y-only recenters carry _cross = 0 and must not re-arm the window
	# (a walk crossing 0.3 s after a snap would read "fast").
	var _now2 := Time.get_ticks_msec()
	var _fast := _last_cross_ms > 0 \
			and (_now2 - _last_cross_ms) < AHEAD_FAST_MS \
			and _cross > 0
	if _fast:
		last_pcx = pcx + signi(pcx - _last_recenter_pcx) * AHEAD_DIST
		last_pcz = pcz + signi(pcz - _last_recenter_pcz) * AHEAD_DIST
		_ahead_active = true
	else:
		last_pcx = pcx
		last_pcz = pcz
		_ahead_active = false
	_rec_player_wx = wx
	_rec_player_wz = wz
	_rec_player_pcx = pcx
	_rec_player_pcz = pcz
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
	# AC-0277: pcx/pcz are the recenter CENTER (player chunk + the ahead
	# offset when fast) — the walk, the pre-warm band math, the
	# band/candidate/demote decisions below and the drain's pools all key
	# off last_pcx/pcz (reassigned here from the player-chunk values above).
	pcx = last_pcx
	pcz = last_pcz
	# AC-0213: small-move pacing — mark the move now; the drain paces at the
	# trickle budget until the window expires (see _drain_build_queue).
	var _now_ms := Time.get_ticks_msec()
	_sm_move_until = _now_ms + SMALL_MOVE_BUDGET_MS
	# AC-0277: the debounced rebuild SKIP is GONE (see the AHEAD_FAST_MS
	# comment at the state block + the ahead-target decision at the top of
	# this function): fast crossings recenter to the chunk in front of the
	# player and every crossing rebuilds (the walk is a single ~8 ms frame
	# at r16; long R50 walks are protected by the in-flight park below),
	# so the baked queue leads instead of the AC-0213/AC-0233 stale queue
	# (up to REBUILD_COVER_L1 chunks behind, forced-refresh cadence).
	_last_recenter_ms = _now_ms
	if _cross > 0:
		_last_cross_ms = _now_ms
		# AC-0313: the AC-0283 P3 crossing-period bookkeeping
		# (_prev_cross_ms) is GONE with the walk regime.
	# AC-0277: the fast predicate measures between PLAYER chunks (pcx here
	# is the recenter CENTER - possibly the ahead target - and must not be
	# stored: a 1-chunk crossing toward an ahead target already 1 chunk in
	# front would read _cross = 0 and cancel the fast mode).
	_last_recenter_pcx = _rec_player_pcx
	_last_recenter_pcz = _rec_player_pcz
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
	# AC-0350: the crossing sweep is BAND-BOUNDED — O(ring) instead of
	# O(resident). The old walk visited EVERY resident column (1453 at R24)
	# on every crossing; the per-entry work can only fire near a band edge:
	#   K       = this recenter's center shift (taxi) — |taxi_new − taxi_old| ≤ K,
	#             so membership in any taxi-monotone band can only change
	#             within K of its edge;
	#   R_outer = the stream set's outermost taxi (maxi(R, b1_eff()) + 2).
	# Passes (a resident cell is looked up once, deduped, and the UNCHANGED
	# per-entry body below runs over the entries):
	#   (A) the real-band window — the fills taxi ≤ band0_r + K around BOTH
	#       centers: _enqueue_build (taxi ≤ band0_r), the crossing-out
	#       demote (its was-real evict side), the re-entry flip/promote;
	#   (B) the stream-set boundary band — rings taxi ∈ [R_outer − K,
	#       R_outer + K] around both centers: every cell whose in/out
	#       membership can flip (the re-entry _stage_check, the
	#       _enter_candidate) and the halo-side demotes — and, because every
	#       resident OUTSIDE column is not-two_out (taxi ≤ R_outer) or
	#       became two_out within the last recenter (taxi ≤ R_outer + K),
	#       also every outside-resident column: the free logic (vi) runs on
	#       exactly the set the old walk reached;
	#   (C) _stream_outside — the maintained outside-resident set — the
	#       exact backstop, and the sole outside source when K > R_outer
	#       (a jump/teleport, never a walk; (B) degenerates to the two set
	#       fills there).
	# The AC-0346 1→1 hop class (a FULL-data column outside the real band at
	# BOTH centers — producible only by a full halo-band landing, a sim-band
	# shrink, or boot) is not within K of any edge: the _real_demote_owed
	# flag (set at the landing sites) + the one-time full sweep below clear
	# it with the SAME body the old walk's (iii) ran.
	var K := absi(pcx - opcx) + absi(pcz - opcz)
	var R_outer := maxi(rr, b1_eff()) + 2
	# the outside set is only valid for the stream-set signature it was built
	# under — a radius change ends in a recenter, so detect it here (the
	# first recenter rebuilds from the empty default).
	if _stream_outside_sig != [rr, b1_eff()]:
		_stream_outside.clear()
		for _kso in chunks:
			var _cso: Node3D = chunks[_kso]
			if int(_cso.face) <= 1 and not in_stream_set(int(_cso.cx) - pcx, int(_cso.cz) - pcz):
				_stream_outside[_kso] = true
		_stream_outside_sig = [rr, b1_eff()]
	var crx_entries: Array = []
	var crx_visited: Dictionary = {}
	var _crx_cell := func(cellx: int, celly: int) -> void:
		var ck := _key(cellx, celly)
		if crx_visited.has(ck):
			return
		var cc: Node3D = chunks.get(ck)
		if cc == null:
			return
		crx_visited[ck] = true
		crx_entries.append([ck, cc, int(cc.cx) - pcx, int(cc.cz) - pcz, int(cc.cx) - opcx, int(cc.cz) - opcz])
	var _crx_ring := func(t: int, ox: int, oz: int) -> void:
		# the 4t cells with |x| + |y| == t, around (ox, oz)
		for x in range(-t, t + 1):
			var y := t - absi(x)
			var xx := ox + x
			if y == 0:
				_crx_cell.call(xx, oz)
			elif x == 0:
				_crx_cell.call(xx, oz + y)
				_crx_cell.call(xx, oz - y)
			else:
				_crx_cell.call(xx, oz + y)
				_crx_cell.call(xx, oz - y)
	var _crx_fill := func(t: int, ox: int, oz: int) -> void:
		# the fill |x| + |y| <= t, around (ox, oz)
		for x in range(-t, t + 1):
			var m := t - absi(x)
			for y in range(-m, m + 1):
				_crx_cell.call(ox + x, oz + y)
	# (A) the real-band window (K ≤ R_outer keeps the K-edge band tight; past
	# it the band0_r fills are exact — (ii) lives in the new fill, the
	# (iii)/(iv) edge cases in the old fill, for any K).
	var rA := band0_r + (K if K <= R_outer else 0)
	_crx_fill.call(rA, pcx, pcz)
	_crx_fill.call(rA, opcx, opcz)
	# (B) the stream-set boundary band (or the two set fills for a jump).
	if K <= R_outer:
		for t in range(maxi(0, R_outer - K), R_outer + K + 1):
			_crx_ring.call(t, pcx, pcz)
			_crx_ring.call(t, opcx, opcz)
	else:
		_crx_fill.call(R_outer, pcx, pcz)
		_crx_fill.call(R_outer, opcx, opcz)
	# (C) the outside-resident set (a stale member = a column the drain freed
	# between recenters — self-heal).
	for _cko in _stream_outside.keys():
		if crx_visited.has(_cko):
			continue
		var _cco: Node3D = chunks.get(_cko)
		if _cco == null:
			_stream_outside.erase(_cko)
			continue
		crx_visited[_cko] = true
		crx_entries.append([_cko, _cco, int(_cco.cx) - pcx, int(_cco.cz) - pcz, int(_cco.cx) - opcx, int(_cco.cz) - opcz])
	for ent in crx_entries:
		var key: String = ent[0]
		var c: Node3D = ent[1]
		var dx := int(ent[2])
		var dz := int(ent[3])
		var odx := int(ent[4])
		var odz := int(ent[5])
		# AC-0143 face 2-11 chunks live in the 1024-cell sphere grid — the
		# home streaming set has no claim on them. (The old Chebyshev walk
		# swept them by accident; AC-0152 scopes it to home chunks.)
		if int(c.face) > 1:
			continue
		cx_scanned += 1  # AC-0348 census: home-face columns visited by the sweep
		if in_stream_set(dx, dz):
			# AC-0278: re-entry is a distance fact (out of set w.r.t. the
			# previous center, in now) - no flag to clear.
			if not in_stream_set(odx, odz):
				c.cand_since = 0
				_stream_outside.erase(key)  # AC-0350: the entrant leaves the outside set (bookkeeping only)
				_stage_check(c, key)
			# AC-0278 (the stuck-mesh fix, AC-0283 P3): the single-source
			# re-queue - a REAL-band chunk that holds data, has no high mesh,
			# and has NO build entry gets one. Previously this only happened
			# in the WANT walk - which DEBOUNCED recenters skip (AC-0213) -
			# so a build entry stripped when the chunk candidated on exit
			# could strand: in set, data, never meshed again (the report:
			# "candidate out of sync kept mesh from generating even at
			# tier 0" while flying back over it). Harmless over-queue:
			# _enqueue_build dedupes, and the drain's high_only pool gate
			# only dispatches entries whose chunk is in the real band.
			if not c.data.is_empty() and not c.mesh_built and _is_real_col(dx, dz) \
					and queued_keys.get(key) != "build":
				_enqueue_build(int(c.cx), int(c.cz))
			# AC-0263 spec (keep-all-LOD, AC-0283 P3): the column just LEFT
			# the REAL band on this recenter - the engine evicts (free the
			# nibbles; a re-entry re-seeds from the current data) and the
			# stored high keeps, the ready lows flip, the rest re-open (the
			# demote above - no free).
			# AC-0346 (generalized - the DATA-RESOLUTION INVARIANT): a
			# column OUTSIDE the real band holds the h-only far
			# representation, never the full (caved) data (AC-0312). The
			# crossing test above covered the normal 0 -> 1 demote; the
			# tier-4 rim full-landing class (the _gen_skip_flag fall-through,
			# closed at the source) was NEVER real, so its band 1 -> 1
			# reband hop never tripped the crossing test and the full data
			# rode at band A indefinitely. Any full data (not c.far) outside
			# the real band is demoted here on EVERY recenter - this is the
			# 1 -> 1 hop actually re-banding the data. The starlight evict
			# stays was-real-gated (the engine only seeds real columns; the
			# rim class never seeded). A mid-regen full landing (the
			# documented tolerance: the regen was enqueued in the real band
			# and lands after the exit) is cleared by the next recenter the
			# same way.
			if not c.data.is_empty() \
					and not c.far \
					and not _is_real_col(dx, dz):
				if _is_real_col(odx, odz):
					_star_halo_evict(c, key)
					cx_halo_evicts += 1  # AC-0348 census
				_demote_high_band_exit(c, key)
				cx_demoted += 1  # AC-0348 census (generate_far counted in _demote_to_far)
			# AC-0263 spec (keep-all-LOD, AC-0283 P3): the column just CAME
			# BACK into the REAL band - the stored highs flip on (visibility
			# only, no rebuild; the mirror of the demote above) and the
			# engine (re-)seeds from the current data (the promotion: one
			# full flood per column - its owed slabs re-bake on the settled
			# light while the halo mesh shows, so no unlit frame).
			if not c.data.is_empty() \
					and not _is_real_col(odx, odz) \
					and _is_real_col(dx, dz):
				_reentry_flip_high(c, key)
				cx_reentry_flips += 1  # AC-0348 census
				_star_halo_promote(c, key)
				cx_promoted += 1  # AC-0348 census
				# AC-0284a: a NO-CAVES column promoted into the real band
				# owes a FULL regen (the promotion's data side — skip data
				# -> full data). It rides the same late-landing machinery
				# as any other data change inside a settled region (the
				# engine was just seeded from the current data above; the
				# regen merge re-seeds the changed slabs by diff and the
				# re-bake converges with no unlit slab). A mid-regen
				# demote is harmless: the landing's real-band check skips
				# the re-seed and the column keeps the full data (a later
				# promotion seeds it directly).
				# AC-0284b: OWE it (the drain's persistent retry) — a
				# one-shot enqueue cap-drops at the crossing (the pool is
				# full of the new forward band's data) and the column
				# stays far in the real band forever.
				if c.no_caves:
					_far_promo_owed[key] = true
				# AC-0283 P3: a stored high (a former REAL column that
				# demoted) just flipped back on the OLD bake — arm every
				# stamped slab for the remesh lane: it re-bakes on the
				# column's NEW settled light (the promotion re-bake; the
				# payload gate defers until the re-seed settles). The old
				# bake keeps showing meanwhile (calculated light — the
				# box gate's "never unlit" holds).
				if bool(c.mesh_built):
					for si_e in c.high_stamps.keys():
						if int(c.high_stamps[si_e]) == int(c.data_gen):
							_star_remesh_add(key, int(si_e))
				# AC-0346: a FAR column promotes through the owed full
				# regen above (_star_halo_promote early-returns — seeding
				# its h-only data would be a light hole), so count its
				# promotion here: the counter stays TOTAL over halo ->
				# real crossings (one full flood per column — the regen's
				# landing does the flood). Pre-AC-0346 the counter only
				# saw the seed-side promotions; the far side was invisible
				# (and the full-data rim class that used to enter as full
				# is now far at the source, so the far count is the clean
				# one).
				if bool(c.far):
					star_halo_promotes += 1
		else:
			# AC-0278: "just exited" is a distance fact (in set w.r.t. the
			# previous center, out now) - the one-time entry work (clear
			# pending sets, strip the build entry) runs exactly once per
			# exit, same as the old flag transition.
			if in_stream_set(odx, odz):
				_stream_outside[key] = true  # AC-0350: the leaver enters the outside set (bookkeeping only)
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
	# AC-0346 backstop (AC-0350): the 1→1 hop class — a FULL-data column
	# outside the real band at BOTH centers. Not within K of any band edge,
	# so the bounded passes above never visit it; the old walk demoted it on
	# every recenter. It can only arise from a full halo-band landing
	# (flagged at the landing sites), a sim-band (band0_r) shrink, or boot —
	# so clear it here with the SAME body the old walk's (iii) ran (identical
	# semantics; the census counts identically).
	var _do_full_sweep := _real_demote_full_sweep
	if band0_r < _last_sweep_band0_r:
		_do_full_sweep = true  # the sim band shrank since the last sweep — the legacy walk, once
	_last_sweep_band0_r = band0_r
	if not _real_demote_owed.is_empty() or _do_full_sweep:
		for _fkey in _real_demote_owed.keys():
			if crx_visited.has(_fkey):
				_real_demote_owed.erase(_fkey)  # an entry pass ran its (iii) already
				continue
			var _fc: Node3D = chunks.get(_fkey)
			if _fc == null:
				_real_demote_owed.erase(_fkey)  # freed in the meantime
				continue
			cx_scanned += 1
			var _fdx := int(_fc.cx) - pcx
			var _fdz := int(_fc.cz) - pcz
			# (iii) exact: in-set, full data, outside the real band (the
			# out-of-set full columns the old walk freed full stay untouched).
			if in_stream_set(_fdx, _fdz) and not _fc.data.is_empty() \
					and not _fc.far and not _is_real_col(_fdx, _fdz):
				if _is_real_col(int(_fc.cx) - opcx, int(_fc.cz) - opcz):
					_star_halo_evict(_fc, _fkey)
					cx_halo_evicts += 1
				_demote_high_band_exit(_fc, _fkey)
				cx_demoted += 1
			_real_demote_owed.erase(_fkey)
			crx_visited[_fkey] = true
		if _do_full_sweep:
			# the legacy walk: every unvisited resident home column gets the
			# (iii) check (boot/load, a sim-band shrink). One time only.
			for _gkey in chunks:
				if crx_visited.has(_gkey):
					continue
				var _gc: Node3D = chunks[_gkey]
				if int(_gc.face) > 1:
					continue
				cx_scanned += 1
				var _gdx := int(_gc.cx) - pcx
				var _gdz := int(_gc.cz) - pcz
				if in_stream_set(_gdx, _gdz) and not _gc.data.is_empty() \
						and not _gc.far and not _is_real_col(_gdx, _gdz):
					if _is_real_col(int(_gc.cx) - opcx, int(_gc.cz) - opcz):
						_star_halo_evict(_gc, _gkey)
						cx_halo_evicts += 1
					_demote_high_band_exit(_gc, _gkey)
					cx_demoted += 1
					crx_visited[_gkey] = true
		_real_demote_full_sweep = false
	var tf1 := Time.get_ticks_usec()
	var crx_scan_us := tf1 - rt0  # AC-0348: the synchronous chunk-scan sub-part (walk + the band calls)
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
	if _rec_pending:
		# AC-0277 (supersedes the AC-0213 debounced skip and generalizes
		# the AC-0233 cover-only park): never discard an in-flight walk.
		# The center moved at most ~1 chunk since this walk started (fast
		# mode's ahead offset) or this is a long R50-class walk — let it
		# finish; its merge finalize chains the next walk from the current
		# center if the player is still past coverage (REBUILD_COVER_L1),
		# and the quiet-stream settle rebuilds at the resting center when
		# movement stops. Restarting on every crossing would livelock
		# long walks (each restart discards the in-flight walk).
		_rec_escalate_pcx = pcx
		_rec_escalate_pcz = pcz
	else:
		_rec_start_walk(pcx, pcz)
	_rp_walk_ms += (Time.get_ticks_usec() - tr1) / 1000.0
	# AC-0160 spawn pre-warm (AC-0293: the 5x5 burst it used to complement
	# is retired — this NORMAL queue enqueue is now the only spawn/recenter
	# data path): the queue normally only exists once the recenter slice's
	# MERGE phase finishes (~2s of wall at r50: 8k stubs), and the drain
	# idles the whole time. Queue the spawn 5x5 (taxi <= 2 — exactly the
	# 8-neighborhood the startup _build_ready gate needs) NOW so the
	# threadgen data pass starts while the slice walks: the 3x3 data gen
	# overlaps the stub walk instead of serializing behind it. The merge
	# rebuild re-queues these keys (WANT) or moves the survivors; the
	# handoff drop + finalization sweep (AC-0160) keep the consumed entries
	# from stranding the queue. Inside-out (taxi, layer) scoring (AC-0313)
	# builds the inner ring first, so the pre-warm's own ordering already
	# favors the footing the load gate waits on.
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
	# AC-0293: the 5x5 startup burst (the high-priority group task, the
	# elems/slots handoff, the group prune/consume) is RETIRED — the
	# pre-warm enqueue above + the drain's normal data pass (AC-0322 feed)
	# are the spawn/recenter data path; the (0,0) sync gen is GONE (fully
	# queue-driven, AC-0263); the anti-fall is the AC-0313 clause-4 load
	# gate (the SIM TAXI DIAMOND meshed by normal streaming before the
	# player activates), so no group task owes the spawn its footing.
	if _recprobe:
		print("RECPROBE r=%d total_ms=%.1f free_ms=%.1f rebuild_ms=%.1f new_n=%d queue=%d chunks=%d drain_stubs_ms=%.1f drain_stubs_n=%d" % [
			render_radius,
			(Time.get_ticks_usec() - rt0) / 1000.0,
			_rp_free_ms, _rp_walk_ms, _rp_stub_n,
			queue_size, chunks.size(),
			_rp_drain_stub_ms, _rp_drain_stub_n])
	# AC-0348: append the crossing-ring entry — the whole synchronous
	# sweep wall + its cause census (the oldest drops past the cap).
	crossing_seq += 1
	crossing_ring.append({
		"seq": crossing_seq,
		"cross": int(_cross),
		"ahead": bool(_fast),
		"us": Time.get_ticks_usec() - crx_t0,
		"scan_us": int(crx_scan_us),
		"free_ms": roundf(_rp_free_ms * 1000.0) / 1000.0,
		"start_ms": roundf(_rp_walk_ms * 1000.0) / 1000.0,
		"scanned": int(cx_scanned),
		"demoted": int(cx_demoted),
		"gen_far": int(crx_gen_far_sync) - int(crx_genfar_base),
		"promoted": int(cx_promoted),
		"halo_evicts": int(cx_halo_evicts),
		"reentry_flips": int(cx_reentry_flips),
	})
	if crossing_ring.size() > CROSSING_RING_CAP:
		crossing_ring.pop_front()

func _recenter_slice() -> void:
	if not _rec_pending:
		return
	# AC-0293: the SPAWN-window slice pause (the _spawn_fast gate) is gone
	# with the burst it protected — the slice now runs concurrently with
	# the normal data pass at spawn (the drain is wall-clock paced, so the
	# slice's main-thread share is bounded by REC_SLICE_BUDGET_MS).
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
	# its low untouched.
	# AC-0337 step 1: the collision bodies SURVIVE the excursion. Leaving
	# band 0 is the flag only — the geometry did not change (and at
	# R <= sim the exit side never even reaches here: _rec_want_step
	# early-returns on nb == 3, so a trailing column keeps its band).
	# Re-entry re-arms ONLY the stale slabs — rearm_slab_bodies frees the
	# bodies whose geometry moved while the column was out (a data
	# landing, an edit, a neighbor landing) and the staged drain rebuilds
	# them; the common re-entry (light-only re-bakes during the excursion
	# moved no data/fl, so the per-slab geometry stamps still match)
	# keeps every body. The old mark_all_slabs_dirty re-derived all 24
	# for nothing on every re-entry. With staging disabled the re-arm
	# would free bodies nothing ever rebuilds, so it is skipped (the
	# pre-existing behavior: the kept — possibly stale — bodies stay).
	c.band = nb
	c.collision_enabled = collision_enabled and nb == 0
	if oldb == 0 and nb != 0:
		perf_reband_exit += 1  # AC-0337: the band-edge excursion census
	elif nb == 0 and oldb != 0:
		perf_reband_entry += 1  # AC-0337: the re-entry census
	if not bool(c.mesh_built):
		return
	if nb == 0 and oldb != 0:
		if col_stage_enabled and c.any_col_dirty():
			perf_reband_rearm_slabs += int(c.rearm_slab_bodies())
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
	# AC-0263 spec (user 2026-09-13): the queue is RECOMPUTED, not merged -
	# every in-set column that still owes build/data work gets a fresh
	# entry, whether or not the OLD queue held one (the old entry is
	# dropped at the MERGE_OLD stage; an old "build" flag - e.g. set by the
	# AC-0278 re-queue that runs BEFORE this walk - must not suppress the
	# re-queue, or the column strands: entry dropped, flag stale, WANT
	# skipping = never built again).
	if c == null or not c.mesh_built:
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
	# AC-0263 spec (user 2026-09-13): "every time we move to a new chunk we
	# should recalculate the ENTIRE queue of work." WANT (above) re-queues
	# EVERY owing column FRESH against the new center - that is the
	# recompute (the stranded-entry class is dead: a debounced recenter
	# skip can no longer strand a column, WANT re-queues it each crossing).
	# Entries WANT does not re-queue (meshed columns) keep their entry
	# RE-BUCKETED by the NEW taxi, so the queue stays consistent with the
	# new center during the walk (the long b1_eff walk keeps the old
	# buckets live until finalize - a dropped carry desynced flags/entries
	# in that window and latched the (since-retired, AC-0293) _spawn_fast
	# on the spawn column's tail slab, killing the low stage: measured
	# 172 s in the lightstate arm).
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
		# AC-0263 spec: the recompute DROPS the old entries (no carry), so
		# their queued_keys flags would go stale (a stale "build" flag makes
		# _enqueue_build's dedup no-op - exactly the old stranded-entry
		# bug). Rebuild the flags from the LIVE queue: flag exists <=> entry
		# exists.
		queued_keys = {}
		for b in range(band_buckets.size()):
			for e2 in band_buckets[b]:
				queued_keys[e2["key"]] = "data" if bool(e2["data_only"]) else "build"
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
	var cx := int(floorf(float(x) / 16.0))
	var cz := int(floorf(float(z) / 16.0))
	var c := _chunk_data(cx, cz)
	if c == null or c.data.is_empty():
		# AC-0325: a data-less column reads as air EXCEPT for recorded edits
		# (set_block's record-only path) — the write is visible before any
		# data lands; every data landing re-applies the same value
		# (_apply_edits_to_chunk, idempotent), so the read can never
		# disagree with what the edit does once the data is material.
		var e: Variant = edits.get(_key(cx, cz), null)
		if e != null:
			var ed: Variant = (e as Dictionary).get((y << 8) | ((z & 15) << 4) | (x & 15), null)
			if ed != null:
				return int(ed.get("b", 0))
		return 0
	return c.get_local(x & 15, y, z & 15)

# Returns true when the write is applied (data present) or recorded
# (data-less column — the record-only path below), false on rejection
# (y out of range). AC-0325: this write path has NO silent no-op — a
# write to a column without slab data (a node-only chunk the pre-AC-0263
# sync materialize used to fill) is recorded in the global edits dict,
# which every data landing re-applies (_apply_edits_to_chunk) and which
# the save's JSON edits diff persists — the same path an edited FAR
# column persists on (AC-0287). get_block reads recorded edits back on
# data-less columns, so the write is visible immediately and, once data
# lands, matches what the same edit does in the real band.
func set_block(x: int, y: int, z: int, id: int, create := true) -> bool:
	if y < 0 or y >= Data.HEIGHT:
		return false
	var cx := int(floorf(float(x) / 16.0))
	var cz := int(floorf(float(z) / 16.0))
	var c: Node3D
	if create:
		c = _chunk_data(cx, cz)
	else:
		c = chunks.get(_key(cx, cz))
	if c == null or c.data.is_empty():
		# AC-0325: the record-only edit (above). No slab/fluid/light/queue
		# machinery here — there is no data to touch; the re-apply on the
		# landing data runs that path's semantics. The fluid level rides
		# the record (f=7 for fluid ids, mirroring the data path).
		var rfi := (y << 8) | ((z & 15) << 4) | (x & 15)
		_record_edit(cx, cz, rfi, id, 7 if is_fluid_id(id) else 0)
		return true
	var lx := x & 15
	var lz := z & 15
	# AC-0270: leaf decay is triggered by the BEFORE/AFTER ids - a log or
	# leaf that changes can connect or disconnect the surrounding groups.
	var old_id := int(c.get_local(lx, y, lz))
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
	# AC-0283 P2 (P3): the engine sees the edit (the two-phase re-seed —
	# the landing-order healing covers an unseeded face) and the mesh side
	# re-arms (the affected slabs re-bake on the settled light). REAL band
	# only: an edit that lands on an unseeded halo column is not seeded
	# here (the halo stays engine-free; a promotion re-seeds the column
	# with its current data).
	if star != null:
		var _staredit: bool = star.on_edit(x, y, z, id)
		if not bool(_staredit) and _is_real_col(cx - last_pcx, cz - last_pcz):
			_star_seed_column(c)
		_star_rearm_edit(c, cx, cz, y >> 4)
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
	# AC-0270: connectivity re-evaluation - a log removed (or a leaf that
	# decayed away / was broken) can orphan the group; a log placed back
	# reconnects it (the scan cancels the timers it can reach).
	if (old_id == 6 or id == 6 or is_leaf_id(old_id) or is_leaf_id(id)) and old_id != id:
		_leaf_decay_scan_around(x, y, z)
	return true


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
	# AC-0283 P2: repurposed — the legacy 3x3 light_dirty mark (the flush
	# wave's trigger) is gone; the engine + the remesh lane own the
	# re-light. This is the BULK version (the apply-edits wave — the
	# per-cell sections are unknown): the own column's stamped slabs + the
	# 3x3 neighbors' stamped slabs re-arm (the per-edit call sites use
	# _star_rearm_edit with the section range).
	if star == null:
		return
	var key := _key(cx, cz)
	var c = chunks.get(key)
	if c == null:
		return
	for si in range(24):
		if int(c.high_stamps.get(si, -1)) == int(c.data_gen) and bool(c.flush_slabs.has(si)):
			c.flush_slabs.erase(si)
			_star_remesh_add(key, si)
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			if dx == 0 and dz == 0:
				continue
			var nkey := _key(cx + dx, cz + dz)
			var nc = chunks.get(nkey)
			if nc == null or not bool(nc.mesh_built):
				continue
			for si in range(24):
				if int(nc.high_stamps.get(si, -1)) == int(nc.data_gen) and bool(nc.flush_slabs.has(si)):
					nc.flush_slabs.erase(si)
					_star_remesh_add(nkey, si)
	_star_update_light_settled(c)

func _mark_fluid_around(cx: int, cz: int, si := -1) -> void:
	# AC-0283 P2: the mark carries the slab range (si = the fluid cell's
	# slab, the boundary slab included; -1 = the whole column — the
	# apply-edits wave). The remesh lane drains it per slab.
	for dx in range(-LIGHT_NEIGHBOR, LIGHT_NEIGHBOR + 1):
		for dz in range(-LIGHT_NEIGHBOR, LIGHT_NEIGHBOR + 1):
			var k := _key(cx + dx, cz + dz)
			var lo := 0
			var hi := 23
			if si >= 0:
				lo = si
				hi = mini(23, si + 1)
			var old: Variant = fluid_dirty.get(k, null)
			if old == null:
				fluid_dirty[k] = [lo, hi]
			else:
				fluid_dirty[k] = [mini(int(old[0]), lo), maxi(int(old[1]), hi)]

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
	# AC-0284b: a far column holds NO slabs (all null) — the edit would
	# land nowhere. Schedule the full regen (the no-caves umbrella); the
	# landing re-applies the edit from the global edits dict (the handoff
	# runs _apply_edits_to_chunk after the slab arrays are in).
	if c.far:
		threadgen_enqueue(int(c.cx), int(c.cz), _key(int(c.cx), int(c.cz)), c.get_instance_id(), true, int(c.col_gen))
		return false
	var cells: Dictionary = edits[key]
	var changed := false
	var fl_changed := false
	var edit_ys: Array[int] = []  # AC-0337: the block-changed cells' slabs
	for fkey in cells:
		var e: Dictionary = cells[fkey]
		var fi := int(fkey)
		var b := int(e.get("b", 0))
		var f := int(e.get("f", 0))
		if c.get_at(fi) != b:
			changed = true
			edit_ys.append(fi >> 8)
		if c.fl_at(fi) != f:
			fl_changed = true
		c.set_local(fi & 15, fi >> 8, (fi >> 4) & 15, b)
		c.set_fl_at(fi, f)
		if f > 0:
			fluid_wet[_key(c.cx, c.cz)] = true
	if not changed and not fl_changed:
		return false
	c.update_top()  # AC-0197: edits may raise (or clear) the top
	# AC-0337 step 1: the old mark_all_slabs_dirty is GONE. The per-slab
	# geometry stamp already invalidates exactly the edited slabs (their
	# dgen/fgen moved at set_local/set_fl_at above), and the closure marks
	# cover the greedy-merge overhang (an edit at row y reshapes quads
	# anchored at [y-3, y]). Confirmed the landing path needs NOTHING
	# beyond this closure: the full-column mesh re-dispatch runs the
	# assembly's stamp check on every slab, so any slab whose geometry
	# inputs moved re-derives — the mark_all was a 24x over-rebuild. A
	# fluid-only edit marks nothing new (fluids are not in the body; the
	# touched slab's fgen move is the conservative flora case).
	if changed:
		for y in edit_ys:
			c.mark_edit_slabs(int(y))
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
	c.no_caves = bool(res.get("no_caves", false))
	# AC-0284b: a far (h-only) disk column (v6 bit 1) — the payload IS the
	# column (the res slab arrays are the all-null handoff shape). The
	# regen trigger below (the umbrella) already covers it: a far column
	# in the real band schedules the full regen, which CLEARS the payload
	# on landing.
	if bool(res.get("far", false)):
		var fh: PackedByteArray = res.get("far_h", PackedByteArray())
		c.far = true
		c.far_h = fh
		c.far_biome = res.get("far_biome", PackedByteArray())
		c.far_top = res.get("far_top", PackedByteArray())
		var mh := 0
		for i in range(0, int(fh.size()), 2):
			var v := int(fh[i]) | (int(fh[i + 1]) << 8)
			if v > mh:
				mh = v
		c.far_hmax = mh
	else:
		c.clear_far()
		# AC-0346/AC-0350: a FULL disk column loaded in the halo band (a
		# re-visit of a previously-saved full column) is the 1→1 hop class —
		# OWE the next recenter's demote (the same body as the old walk's
		# (iii)). Far disk columns (the h-only form) and real-band loads are
		# the normal state; out-of-set loads are freed full by (vi), never
		# demoted.
		var _ldx := int(c.cx) - last_pcx
		var _ldz := int(c.cz) - last_pcz
		if not c.data.is_empty() and in_stream_set(_ldx, _ldz) and not _is_real_col(_ldx, _ldz):
			_real_demote_owed[_key(int(c.cx), int(c.cz))] = true
	var gk := PackedByteArray()
	if gmask != 0xFFFFFF:
		gk.resize(int(c.data.size()))
		for si in range(gk.size()):
			gk[si] = 1 if ((gmask >> si) & 1) != 0 else 0
	c.gen_keep = gk
	# AC-0284a: a no-caves column in the REAL band (taxi ≤ band0_r at
	# landing) owes a FULL regen — the player must never see a cave-less
	# column up close. It lands through the late-landing machinery
	# (hide + re-bake + engine re-seed; the AC-0283 P2 contract). A
	# no-caves column in the halo band stays as-is (the halo draw never
	# shows caves; the recenter crossing promotes it with a regen).
	# AC-0284b: owed (the drain's persistent retry — a one-shot enqueue
	# cap-drops when the pool is full and the column would stay
	# cave-less in the real band).
	if c.no_caves and _is_real_col(int(c.cx) - last_pcx, int(c.cz) - last_pcz):
		_far_promo_owed[_key(int(c.cx), int(c.cz))] = true
	# AC-0257: an old AC-0237 save may hold a range-generated column (a
	# partial gen_mask — slabs the old window never generated). The vwin
	# owed-regen is gone: a plain full regen refills the missing slabs
	# (bit-exact). The built mesh was made against the stone-snap view of
	# those slabs and rides until the next re-mesh (tier flip / edit /
	# reband) — a deep-interior cosmetic at worst.
	if gmask != 0xFFFFFF:
		threadgen_enqueue(int(c.cx), int(c.cz), _key(int(c.cx), int(c.cz)), c.get_instance_id(), false, int(c.col_gen))
	_pool_touch()  # AC-0217: disk data landed on a queued entry


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



# AC-0287: lazy read of the A/B seam (see _saveall_env). Returns 0 = the
# save filter is ON (product), 1 = pre-AC-0287 save-all (test-only
# baseline). Read once, cached for the process.
func _save_filter_bypass() -> int:
	if _saveall_env < 0:
		_saveall_env = 1 if OS.get_environment("AWECRAFT_SAVEALL") == "1" else 0
	return _saveall_env

func _queue_chunk_save(c: Node3D) -> void:
	if Save.active_slot < 0 or c.data.is_empty():
		return
	# AC-0287: the save filter — the region write persists a column ONLY if
	# it is inside the SIM DIAMOND (taxi <= band0_r = sim, the spec's
	# boundary EXACTLY — AC-0313 clause 6 deleted the tier-0 set, so there
	# is no real-column-outside-sim case left to special-case) OR it
	# carries EDITS (world.edits). Far (h-only) columns are NEVER encoded —
	# the v6 bit-1 payload write is dead and its DECODE stays for
	# pre-AC-0287 saves: absent on disk = regenerate on load (cheap far,
	# ~92 us/col, bit-exact; the sim diamond re-gens full), and an EDITED
	# far column persists through the JSON edits diff (Save.save_now) + the
	# edit's own promotion regen (AC-0284b/AC-0286) — the edit is NOT in
	# the far payload (no slabs), so writing it would add nothing. In
	# natural flow an evicted column already sits two rings past the render
	# edge (the r+2 free: taxi > sim + 2), so the practical effect: only
	# edited columns persist, and the save size stays FLAT under flight
	# (the flysave arm's proof). AWECRAFT_SAVEALL=1 = the pre-AC-0287
	# baseline A/B (every evicted column saved — the flysave arm's
	# comparison run; never set in product runs).
	if _save_filter_bypass() == 0 and c.far:
		_save_skip_n += 1
		_save_far_n += 1
		return
	var key := _key(int(c.cx), int(c.cz))
	if _save_filter_bypass() == 0 \
			and not _is_real_col(int(c.cx) - last_pcx, int(c.cz) - last_pcz) \
			and not edits.has(key):
		_save_skip_n += 1
		return
	# AC-0164: the slot is captured AT ENQUEUE — the active slot can change
	# mid-flight (continue / new game) and a write in flight must still land
	# in the captured slot's dir, not the current one's.
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
		"no_caves": bool(c.no_caves),  # AC-0284a: v6 flag — the no-caves marker rides on disk
		# AC-0284b: the far (h-only) column's 1024-byte payload (H u16
		# LE + biome + top) — the v6 bit-1 section replacing the slab
		# section. Empty for every non-far column.
		"far": c.far_h if c.far else PackedByteArray(),
		"far_biome": c.far_biome if c.far else PackedByteArray(),
		"far_top": c.far_top if c.far else PackedByteArray(),
	})

func _save_light_for(c: Node3D, key: String) -> Dictionary:
	var out := {}
	# AC-0283 P2: the guard is the engine's — save only a SETTLED light
	# (the column's light gate closed) with no pending re-bake (the remesh
	# lane would supersede it). The saved light is IGNORED on load (the
	# engine recomputes from the data) — the disk writes stay until
	# AC-0287.
	if star != null and (star_remesh.has(key) or not star.column_settled(int(c.cx), int(c.cz))):
		return out
	var cached = _eff_cache.get(key)
	if cached == null or int(c.data_gen) != int(cached.stamp[0]) or int(c.fl_gen) != int(cached.stamp[1]):
		return out
	if cached.get("ngen", null) != null and cached.get("ngen") != _ngens_for(int(c.cx), int(c.cz)):
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
		"no_caves": bool(e.get("no_caves", false)),  # AC-0284a
		# AC-0284b: the far payload (empty = the slab shape) — the worker
		# assembles the 1024-byte section (H u16 + biome + top).
		"far": e.get("far", PackedByteArray()),
		"far_biome": e.get("far_biome", PackedByteArray()),
		"far_top": e.get("far_top", PackedByteArray()),
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
	# AC-0284b: a FAR column (the 512-byte far_h rides the entry) — the
	# far payload section (H u16 LE + biome + top, 1024 bytes) replaces the
	# slab section in the v6 bit-1 head; the slabs are all-null (nothing to
	# flatten). ~1 KB on disk instead of ~20-100 KB.
	var fhp: PackedByteArray = entry.get("far", PackedByteArray())
	var fpay := PackedByteArray()
	if fhp.size() == 512:
		fpay.append_array(fhp)
		fpay.append_array(entry.get("far_biome", PackedByteArray()))
		fpay.append_array(entry.get("far_top", PackedByteArray()))
	var blob := ChunkIO.encode_column(io.slabs_flat(entry["data"]) if fpay.is_empty() else PackedByteArray(), io.slabs_flat(entry["fl"]) if fpay.is_empty() else PackedByteArray(), int(entry["seed"]), int(entry["height"]), entry.get("light", {}), -1, int(entry.get("gen_mask", 0xFFFFFF)), bool(entry.get("no_caves", false)), fpay)  # AC-0237: v5 when range-generated; AC-0284a: v6 when no-caves; AC-0284b: v6 bit 1 when far
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
			"no_caves": bool(e.get("no_caves", false)),
			"far": e.get("far", PackedByteArray()),  # AC-0284b: the far payload rides the re-queue
			"far_biome": e.get("far_biome", PackedByteArray()),
			"far_top": e.get("far_top", PackedByteArray()),
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
	_apply_pending_leaf_decay(c)  # AC-0270: restore the saved timers (disk columns too)
	# AC-0283 P2 (P3): seed ALL sections (post-edits data). The SAVED LIGHT
	# in the column (c.saved_light) is IGNORED for builds — the engine
	# recomputes from the data (the saved-light disk writes stay until
	# AC-0287). REAL band only — the halo never seeds (a promoting column
	# seeds at the recenter crossing). AC-0284b: a FAR disk column seeds
	# NO air hole — its owed full regen (the no-caves umbrella above)
	# lands behind it and seeds the column whole (was_far).
	if _is_real_col(int(c.cx) - last_pcx, int(c.cz) - last_pcz) and not c.far:
		_star_seed_column(c)

func surface_top(x: int, z: int) -> int:
	for y in range(Data.HEIGHT - 1, -1, -1):
		var b := get_block(x, y, z)
		if b != 0:
			var info = Data.block(b)
			if info.solid:
				return y
	return 0

# AC-0324: the deterministic spawn search — the world decides where the
# player starts (AC-0314 removed the spawn pad this search rides on —
# the picked column is NATURAL terrain). The load gate
# (main._await_sim_band) builds the SIM TAXI DIAMOND (taxi <= band0_r;
# 41 columns at sim 4) before activation, so the search evaluates only
# data the load gate guarantees — the footing is guaranteed.
#
# Per candidate column (cx, cz) — the centre cell x = cx*16+8, z = cz*16+8,
# T = the topmost non-air cell of (x, z) (= the generator's effective
# surface, the "terrain_height == surface top" contract), T_id its id:
#   DRY      T_id != water and T >= SEA.
#   SLOPED   max |T_nb - T| <= SPAWN_SLOPE_MAX_DH over the 4 CARDINAL
#            neighbour CELLS (x±1, z), (x, z±1) (their topmost non-air
#            cells; a canopy in a neighbour's cell counts — a conservative
#            rejection beside a tree).
#   UN-VEG   neither (x, T+1, z) (the feet cell) nor (x, T+2, z) (the head
#            cell) is a tree/clutter id (log/leaves/rose/dandelion/banana
#            — the gen veg + banana pass's writes).
#
# T0 = first column in (taxi, cx, cz) order passing all three, over the
# INNER diamond taxi <= band0_r - 1 (every T0 candidate's 4 slope
# neighbours are then inside the load-gate diamond — a boundary column's
# outward neighbour data is timing-dependent and would make the search
# non-deterministic). T1 = first DRY column in (taxi, cx, cz) order over
# the full band (ignoring slope + veg) — the "no candidate passes"
# fallback. T2 = highest-T column over the full band, (taxi, cx, cz)
# tie-break — the last resort for a band-wide ocean (reachable now that
# AC-0314 removed the pad that made the centre cell always dry).
#
# Deterministic: a pure function of (seed, band data) — no RNG. The result
# is cached per world node and logged once (the SPAWNSEARCH line).
const SPAWN_SLOPE_MAX_DH := 2

var _spawn_search: Dictionary = {}

func _spawn_search_ready() -> bool:
	for taxi in range(band0_r + 1):
		for dx in range(-taxi, taxi + 1):
			var rem := taxi - absi(dx)
			var dzs: Array = [rem] if rem == 0 else [-rem, rem]
			for dz in dzs:
				var c = chunks.get(_key(last_pcx + dx, last_pcz + dz))
				if c == null or c.data.is_empty():
					return false
	return true

# AC-0324: the search core — PURE (no node state, no RNG) over pre-gathered
# candidate rows in (taxi, cx, cz) order. Each row:
#   cx, cz, taxi, x, z — column + centre cell
#   top, top_id — the centre cell's topmost non-air cell + its block id
#   feet_id, head_id — the blocks at (x, top+1, z) / (x, top+2, z)
#   nb — [top_w, top_e, top_s, top_n] of the 4 cardinal neighbour CELLS
#        (-1 = not available; T0 rows always carry all 4 — the inner
#        diamond guarantees them — outer rows carry -1 and are T0-
#        ineligible via the "t0" flag, never via a skipped slope check)
#   t0 — true for inner-diamond rows (taxi <= band0_r - 1)
func _spawn_pick(rows: Array) -> Dictionary:
	var veg := [WorldGen.B_LOG, WorldGen.B_LEAVES, WorldGen.B_ROSE, WorldGen.B_DANDELION, WorldGen.B_BANANA]
	var t1: Dictionary = {}
	var t2: Dictionary = {}
	var t2_top := -1
	for r in rows:
		var top: int = int(r["top"])
		var top_id: int = int(r["top_id"])
		var dry: bool = top_id != WorldGen.B_WATER and top >= WorldGen.B_SEA
		if t1.is_empty() and dry:
			t1 = r
		if top > t2_top:
			t2 = r
			t2_top = top
		if dry and bool(r.get("t0", false)):
			var ok_slope := true
			var nb: Array = r["nb"]
			for i in 4:
				var nh: int = int(nb[i])
				if nh >= 0 and absi(nh - top) > SPAWN_SLOPE_MAX_DH:
					ok_slope = false
					break
			if ok_slope and int(r["feet_id"]) not in veg and int(r["head_id"]) not in veg:
				return {"tier": 0, "row": r}
	if not t1.is_empty():
		return {"tier": 1, "row": t1}
	return {"tier": 2, "row": t2}

func _spawn_search_cell_top(x: int, z: int) -> int:
	var y := Data.HEIGHT - 1
	while y >= 0 and get_block(x, y, z) == 0:
		y -= 1
	return maxi(y, 0)

# AC-0324: run (and cache) the deterministic spawn search. Empty until the
# sim-band data guarantee holds; after activation the cache is final (a
# fresh world has no edits).
func spawn_search() -> Dictionary:
	if not _spawn_search.is_empty():
		return _spawn_search
	if not _spawn_search_ready():
		return _spawn_search
	var r: int = band0_r
	var rows: Array = []
	for taxi in range(r + 1):
		for dx in range(-taxi, taxi + 1):
			var rem := taxi - absi(dx)
			var dzs: Array = [rem] if rem == 0 else [-rem, rem]
			for dz in dzs:
				var cx2: int = last_pcx + dx
				var cz2: int = last_pcz + dz
				var x: int = cx2 * 16 + 8
				var z: int = cz2 * 16 + 8
				var top: int = _spawn_search_cell_top(x, z)
				var row := {
					"cx": cx2, "cz": cz2, "taxi": taxi, "x": x, "z": z,
					"top": top, "top_id": get_block(x, top, z),
					"feet_id": get_block(x, top + 1, z),
					"head_id": get_block(x, top + 2, z),
					"t0": taxi < r,
				}
				if taxi < r:
					row["nb"] = [
						_spawn_search_cell_top(x - 1, z),
						_spawn_search_cell_top(x + 1, z),
						_spawn_search_cell_top(x, z - 1),
						_spawn_search_cell_top(x, z + 1),
					]
				else:
					row["nb"] = [-1, -1, -1, -1]
				rows.append(row)
	var pick := _spawn_pick(rows)
	var row: Dictionary = pick["row"]
	_spawn_search = {
		"tier": int(pick["tier"]),
		"row": row,
		"anchor": [last_pcx, last_pcz],
		"sim": r,
		"seed": Game.world_seed,
	}
	print("SPAWNSEARCH seed=%d anchor=[%d,%d] sim=%d col=[%d,%d] cell=[%d,%d] top=%d pos=[%.1f,%.1f,%.1f] tier=%d" % [
		Game.world_seed, last_pcx, last_pcz, r,
		int(row["cx"]), int(row["cz"]), int(row["x"]), int(row["z"]), int(row["top"]),
		float(int(row["x"])) + 0.5, float(int(row["top"])) + 1.0, float(int(row["z"])) + 0.5,
		int(pick["tier"])])
	return _spawn_search

# AC-0119 (AC-0263): the boot-time sync gen of the spawn chunk is GONE —
# the pre-data surface top is the ANALYTIC heightmap. AC-0293: the ground
# data (collision) the player lands on is delivered by the NORMAL data
# pass + the AC-0313 clause-4 load gate (the SIM TAXI DIAMOND fully meshed
# before the player activates) — the 5x5 startup burst that used to carry
# it is retired.
# AC-0324: once the sim-band data is ready the searched column (NATURAL
# terrain) is the position. AC-0314: the spawn PAD is REMOVED from the gen
# — the pre-data fallback is the anchor column's NATURAL surface: the C++
# analytic H (AweGen.column_heights16 — the same function the far payload
# stores and the farab battery gates; the GDScript terrain_height mirror
# is a coarse 2-D approximation, NOT the C++ H), so spawn y = surface H +
# 1 at the (SPAWN_X, SPAWN_Z) anchor and the pre-data position sits exactly
# on the natural terrain the data will have.
func spawn_point() -> Vector3:
	var s: Dictionary = spawn_search()
	if not s.is_empty():
		var row: Dictionary = s["row"]
		return Vector3(float(int(row["x"])) + 0.5, float(int(row["top"])) + 1.0, float(int(row["z"])) + 0.5)
	# pre-data: the anchor column's natural surface (C++ analytic H).
	var ch: PackedByteArray = WorldGen.gen_cpp().column_heights16(0, 0, Game.world_seed, Data.HEIGHT)
	var i8 := WorldGen.SPAWN_Z * 16 + WorldGen.SPAWN_X  # cell (8,8) within chunk (0,0)
	var top := int(ch[2 * i8]) | (int(ch[2 * i8 + 1]) << 8)
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


# ---------------------------------------------------------------- AC-0270:
# leaf decay. Natural leaves (7) die when no oak log (6) is within 6
# steps through the leaf path; player-placed leaves (30) never decay.
# Triggers: a log/leaf change (set_block hook) re-runs the connectivity
# scan around the cell; the 20 Hz game tick counts down the timers while
# the chunk is in sim distance (band 0). The timer values ride the chunk
# (like a block entity) and survive sim exit/entry and save/load.
func is_log_id(id: int) -> bool:
	return id == 6

func is_leaf_id(id: int) -> bool:
	return id == 7 or id == 30

# Reads a cell WITHOUT creating chunk data (a BFS probe must not force
# generation of the neighborhood). -1 = unknown (chunk unloaded).
func _leaf_block_at(x: int, y: int, z: int) -> int:
	if y < 0 or y >= Data.HEIGHT:
		return 0
	var c: Node3D = chunks.get(_key(int(floorf(float(x) / 16.0)), int(floorf(float(z) / 16.0))))
	if c == null or c.data.is_empty():
		return -1
	return int(c.get_local(x & 15, y, z & 15))

# Re-evaluates every natural leaf in the R=6 L1 box around (x,y,z):
#  - a leaf is ALIVE when a log reaches it in <= 6 leaf-path steps
#    (multi-source BFS from the logs inside the box, depth capped at 6);
#  - a DEAD leaf (every leaf neighbor also in the box, no log found) gets
#    a random timer when it has none - the "random timer per leaf group":
#    one group draw + a small per-leaf jitter, so a disconnected cluster
#    dies roughly together but not in perfect lockstep;
#  - a leaf with a leaf neighbor OUTSIDE the box (or an unloaded chunk)
#    is UNKNOWN (its connectivity may be preserved through the unscanned
#    territory) and is left alone;
#  - alive leaves have their timer CANCELLED (a log was planted back).
func _leaf_decay_scan_around(x: int, y: int, z: int) -> void:
	if not leaf_decay_enabled:
		return
	var R := 6
	var box: Dictionary = {}
	var leaves: Array = []
	var logs: Array = []
	var y0 := maxi(0, y - R)
	var y1 := mini(Data.HEIGHT - 1, y + R)
	var xx0: int = x - R
	var xx1: int = x + R
	var zz0: int = z - R
	var zz1: int = z + R
	var nb6 := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
	for bx in range(xx0, xx1 + 1):
		for bz in range(zz0, zz1 + 1):
			for by in range(y0, y1 + 1):
				var b := _leaf_block_at(bx, by, bz)
				if b < 0:
					continue  # unloaded neighbor - territory stays unknown
				if is_log_id(b):
					logs.append(Vector3i(bx, by, bz))
				elif is_leaf_id(b):
					leaves.append(Vector3i(bx, by, bz))
					box["%d,%d,%d" % [bx, by, bz]] = true
	if leaves.is_empty():
		return
	# multi-source BFS from the logs through {7,30,6}, depth <= 6.
	var alive: Dictionary = {}
	var frontier: Array = []
	for lg in logs:
		frontier.append([lg, 0])
		alive["%d,%d,%d" % [lg.x, lg.y, lg.z]] = true
	while not frontier.is_empty():
		var nxt: Array = []
		for e in frontier:
			var pos: Vector3i = e[0]
			var d: int = e[1]
			if d >= 6:
				continue
			for nb in nb6:
				var npos: Vector3i = pos + nb
				var k := "%d,%d,%d" % [npos.x, npos.y, npos.z]
				if alive.has(k):
					continue
				var b := _leaf_block_at(npos.x, npos.y, npos.z)
				if b < 0:
					continue  # unloaded - stop (that territory is unknown)
				if is_leaf_id(b) or is_log_id(b):
					alive[k] = true
					nxt.append([npos, d + 1])
		frontier = nxt
	# one group draw for this scan (the leaves found dead share the base)
	var base: int = randi_range(leaf_decay_min_ms, leaf_decay_max_ms)
	var started := 0
	var cancelled := 0
	for lf in leaves:
		var k := "%d,%d,%d" % [lf.x, lf.y, lf.z]
		if alive.has(k):
			# connected to a log: cancel any pending timer.
			var ccx := int(floorf(float(lf.x) / 16.0))
			var ccz := int(floorf(float(lf.z) / 16.0))
			var cc: Node3D = chunks.get(_key(ccx, ccz))
			if cc != null:
				var fii: int = (lf.y << 8) | ((lf.z & 15) << 4) | (lf.x & 15)
				if cc.leaf_decay.has(str(fii)):
					cc.leaf_decay.erase(str(fii))
					cancelled += 1
			continue
		# unknown? a leaf neighbor outside the box (or an unloaded chunk)
		# means the path may continue there - no timer we can't judge.
		var unknown := false
		for nb in nb6:
			var npos: Vector3i = lf + nb
			var nk := "%d,%d,%d" % [npos.x, npos.y, npos.z]
			var nb_b := _leaf_block_at(npos.x, npos.y, npos.z)
			if nb_b < 0 or (is_leaf_id(nb_b) and not box.has(nk)):
				unknown = true
				break
		if unknown:
			continue
		# dead: start a timer - natural leaves only (30 is persistent).
		if _leaf_block_at(lf.x, lf.y, lf.z) != 7:
			continue
		var ccx := int(floorf(float(lf.x) / 16.0))
		var ccz := int(floorf(float(lf.z) / 16.0))
		var cc: Node3D = chunks.get(_key(ccx, ccz))
		if cc == null:
			continue
		var fii: int = (lf.y << 8) | ((lf.z & 15) << 4) | (lf.x & 15)
		if not cc.leaf_decay.has(str(fii)):
			var jit: int = int(float(base) * 0.15)
			cc.leaf_decay[str(fii)] = maxi(1, base + (randi() % (jit + 1)) - (jit / 2))
			started += 1
	if leaf_decay_debug:
		print("LEAFDECAY scan t=%d at=%s leaves=%d logs=%d started=%d cancelled=%d" % [Time.get_ticks_msec(), str(Vector3i(x, y, z)), leaves.size(), logs.size(), started, cancelled])

# The 20 Hz tick: count down every timer in the band-0 (sim) chunks; a
# fired leaf becomes air through set_block (which records the edit - the
# decay IS the persistence - and re-triggers the scan: the hole may
# disconnect the leaves further out).
func _leaf_decay_tick() -> void:
	if not leaf_decay_enabled:
		return
	var ms := int(TICK_INTERVAL * 1000.0)
	for key in chunks:
		var c: Node3D = chunks[key]
		if int(c.band) != 0 or c.data.is_empty():
			continue
		if c.leaf_decay.is_empty():
			continue
		var lfkeys: Array = c.leaf_decay.keys()
		for kidx in lfkeys.size():
			var fi = lfkeys[kidx]
			var fii: int = int(fi)
			if not c.leaf_decay.has(fi):
				continue
			var rem: int = int(c.leaf_decay[fi]) - ms
			if rem <= 0:
				c.leaf_decay.erase(fi)
				var lx: int = fii & 15
				var ly: int = fii >> 8
				var lz: int = (fii >> 4) & 15
				if int(c.get_local(lx, ly, lz)) != 7:
					continue  # changed since (broken/placed over) - drop
				var wx := int(c.cx) * 16 + lx
				var wz := int(c.cz) * 16 + lz
				leaf_decay_fires += 1
				set_block(wx, ly, wz, 0)
			else:
				c.leaf_decay[fi] = rem

# AC-0270: harness helpers - the live (chunk-resident) timer count and
# the fire counter (a decayed leaf that actually hit the ground).
var leaf_decay_fires := 0

func leaf_decay_live_n() -> int:
	var n := 0
	for key in chunks:
		var c: Node3D = chunks[key]
		n += int(c.leaf_decay.size())
	return n

func leaf_decay_fire_count() -> int:
	return leaf_decay_fires

func cell_is_persistent(c: Vector3i) -> bool:
	return get_block(c.x, c.y, c.z) == 30

# The save view: "cx,cz" -> {fi: ms} for the chunks that have timers.
func leaf_decay_index() -> Dictionary:
	var out: Dictionary = {}
	for key in chunks:
		var c: Node3D = chunks[key]
		if c.leaf_decay.is_empty():
			continue
		var cells: Dictionary = {}
		for fkey in c.leaf_decay:
			cells[str(fkey)] = int(c.leaf_decay[fkey])
		out[_key(int(c.cx), int(c.cz))] = cells
	return out

# Merges a chunk's pending (saved) timers in when it materializes - a cell
# the materialized data says is NOT a natural leaf is skipped (the edit
# that changed it won over the saved timer).
func _apply_pending_leaf_decay(c: Node3D) -> void:
	var key := _key(int(c.cx), int(c.cz))
	if not pending_leaf_decay.has(key):
		return
	var raw = pending_leaf_decay[key]
	pending_leaf_decay.erase(key)
	if typeof(raw) != TYPE_DICTIONARY or c.data.is_empty():
		return
	var n := 0
	for fkey in raw:
		var fii := int(fkey)
		var y := fii >> 8
		if y < 0 or y >= Data.HEIGHT:
			continue
		if int(c.get_local(fii & 15, y, (fii >> 4) & 15)) == 7:
			c.leaf_decay[str(fii)] = maxi(1, int(raw[fkey]))
			n += 1
	if leaf_decay_debug:
		print("LEAFDECAY restore chunk=%s n=%d" % [key, n])

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
	_mark_fluid_around(cx, cz, y >> 4)
	# AC-0283 P2: fluids carry light (water att 3, lava glow 15) — a
	# fluid write is a data edit for the engine (the id changed), same
	# re-arm as set_block.
	if star != null:
		var _staredit: bool = star.on_edit(x, y, z, id)
		if not bool(_staredit):
			_star_seed_column(c)
		_star_rearm_edit(c, cx, cz, y >> 4)
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
	# AC-0356: batch this tick's light-side edit events. The fluid pass (and
	# the water/lava reactions inside it) is a sustained burst of set_fluid /
	# set_block calls — each used to fire its own star.on_edit (a 3x3 x 0..hi
	# re-flood PER CELL), which the 3 ms star drain could never absorb: the
	# R24 boundary arm's OOM was that per-cell queue growth. The batched
	# two-phase runs once over the union of the touched sections — same
	# settled light, one epoch bump per section per tick.
	if star != null:
		star.begin_edit_batch()
	_tick_fluids_body()
	if star != null:
		star.end_edit_batch()

func _tick_fluids_body() -> void:
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


# AC-0037: the day/night mob spawn/despawn tick (runs on the world
# physics clock; ~one attempt per 0.5 s). Passive types spawn by day,
# hostiles (incl. the spider) at night; anything past the despawn
# radius is freed. The AC-0158 region contract (circle 24-44 around the
# player) bounds the spawn attempts.
var _mob_acc := 0.0
var _mob_cap := 20
const MOB_DESPAWN_R := 52.0

func _mob_tick(d: float) -> void:
	if Game.player == null or Game.mode != "play" or Game.entities == null:
		return
	var ppos: Vector3 = Game.player.position
	# despawn first (keeps the population bounded at the region edge)
	var alive := 0
	for c in Game.entities.get_children():
		if c is Node3D and c.has_method("center"):
			if c.position.distance_to(ppos) > MOB_DESPAWN_R:
				c.queue_free()
				continue
			alive += 1
	if alive >= _mob_cap:
		return
	_mob_acc += d
	if _mob_acc < 0.5:
		return
	_mob_acc = 0.0
	var night: bool = DayNight.is_night(Game.time_of_day)
	# the day/night spawn table (type, weight)
	var table: Array = []
	if night:
		table = [["zombie", 24], ["skeleton", 18], ["spider", 16], ["pig", 6], ["chicken", 6], ["wolf", 4], ["bunny", 4]]
	else:
		table = [["pig", 18], ["sheep", 16], ["chicken", 14], ["cow", 12], ["wolf", 8], ["bunny", 8]]
	var total := 0
	for e in table:
		total += int(e[1])
	for att in range(3):
		var ang := randf() * TAU
		var dist := randf_range(float(MOB_SPAWN_CIRCLE_MIN), float(MOB_SPAWN_CIRCLE_MAX))
		var sx := int(floorf(ppos.x + cos(ang) * dist))
		var sz := int(floorf(ppos.z + sin(ang) * dist))
		var sy: int = surface_top(sx, sz)
		if sy <= 0:
			continue
		# open ground: sy is the topmost SOLID by definition, so only
		# the cell above it matters - water/canany overhead rejects.
		if get_block(sx, sy + 1, sz) != 0:
			continue
		var r := randi() % total
		var pick := str(table[0][0])
		for e in table:
			r -= int(e[1])
			if r < 0:
				pick = str(e[0])
				break
		var m: Node3D = MobScript.new()
		m.key = pick
		Game.entities.add_child(m)
		m.position = Vector3(float(sx) + 0.5, float(sy) + 1.02, float(sz) + 0.5)
		return

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
# +Y halves (faces 0,1) = the flat home world (1m columns). AC-0306 grid lock:
# the home pair (one cube face) is W x W m with W = pi*R/2 = face_width(R) —
# one flat metre is one metre of arc. Half-face width = pi*R/4: face 0
# x = (pi*R/4)*u (x in [0, pi*R/4]), face 1 x = (pi*R/4)*(u-1)
# (x in [-pi*R/4, 0]); z = (pi*R/4)*(2v-1). (Pre-AC-0306 this was R, tying the
# face width to the radius — the 0.72 m-per-block defect.) Faces 2-11 resolve
# to their 1024-cell grid columns. Deterministic: same position + R => same key.
func key_for_sphere_pos(pos: Vector3, R: float) -> Dictionary:
	var r: Dictionary = SphereMath.world_to_face(pos, R)
	var face: int = int(r["face"])
	var u: float = float(r["u"])
	var v: float = float(r["v"])
	if face == 0 or face == 1:
		var hw: float = SphereMath.face_width(R) * 0.5  # AC-0306: pi*R/4 per half
		var fx: float = hw * u if face == 0 else hw * (u - 1.0)
		return {"face": face, "cx": int(roundf(fx)), "cz": int(roundf(hw * (2.0 * v - 1.0)))}
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
	c.no_caves = false
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

func set_block_key(face: int, colx: int, colz: int, y: int, id: int) -> bool:
	if y < 0 or y >= Data.HEIGHT:
		return false
	if face == 0 or face == 1:
		return set_block(colx, y, colz, id)
	var c: Node3D = _ensure_face_chunk(face, colx, colz)
	if c == null or c.data.is_empty():
		# AC-0325: no silent no-op (a face chunk is generated on ensure,
		# so this is unreachable — the honest return anyway).
		return false
	var fi: int = (y << 8) | ((colz & 15) << 4) | (colx & 15)
	c.set_local(colx & 15, y, colz & 15, id)
	c.set_fl_at(fi, 0)
	return true


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
