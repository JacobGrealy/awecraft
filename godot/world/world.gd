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
# burst is the tuning knob — AWECRAFT_TM_HO overrides it at boot (clamped
# 1..STREAM_TM_HANDOFF_MAX) so 2/3 can be A/B'd in the harness.
const STREAM_TM_HANDOFF_PER_FRAME := 3
const STREAM_TM_HANDOFF_MAX := 16
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
const LOD_HYS_FULL_MAX := 11
const LOD_HYS_COARSE_MIN := 14
const LOD_HYS_RING_MIN := 11
const LOD_HYS_RING_MAX := 14

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
# mesh, no tick, no collision — same builder path as band 0), band 2 = the
# rest of the Euclidean render circle (COARSE 32-scale merged, uv_scale 2,
# flora cut, cutout->opaque, no tick, no collision), band 3 = collar
# (diamond band1+1 outside the circle) ∪ circle ring (points outside the
# circle touching it within 8-neighbors): data-only, never meshed.
# Harness-overridable: AWECRAFT_BAND0/BAND1.
# AC-0160: the band-2 heightmap impostor was removed (user decision) —
# band 2 flows through the normal build_accs path like band 0/1.
# AC-0181: monotonic LOD — band1_r widened to 12 (taxi 0-12 full), band 2
# (taxi >= 13) takes the old band-1 coarse ctx: uniform out to R, no more
# high->low->high pop while walking.
var band0_r := 4
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
# AC-0187: block-edit remesh front queue. set_block pushes the edited chunk's
# key (with the dirty slab closure) here; _process drains it BEFORE the
# AC-0126 light_pending flush so the hole lands on the next frame instead of
# behind the far-queue drain. Each entry = {"key", "si0", "si1"}.
var edit_front: Array = []
var edit_front_set := {}
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
# scans admit (spawn-fast = b1_eff+2, grows one bucket / 15 frames in the
# trickle); _drain_win_b < 0 = unset.
var _drain_win_b := -1
var _drain_win_acc := 0
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
var _tm_enq := 0
var _tm_dedup := 0
var _tm_capdrop := 0
var _tm_stale := 0
var _tm_datadrop := 0
var _tm_handoff := 0
# AC-0219: per-frame streaming handoff counter. threadmesh_poll can run up
# to twice per process frame (_physics_process_impl + _process, plus the
# recenter call), so the cap is keyed on the process frame, not the call.
var _stream_ho_frame := -1
var _stream_ho_n := 0
# AC-0224: the effective per-frame streaming handoff burst (the const
# default; _ready overrides it from AWECRAFT_TM_HO when set — the
# tuning knob, clamped 1..STREAM_TM_HANDOFF_MAX).
var stream_ho_cap := STREAM_TM_HANDOFF_PER_FRAME
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
var _look_yaw := 0.0
var _look_dir := Vector2(1, 0)
const PICK_POOL_CAP := 512
const PICK_LOOK_REFRESH_DEG := 10.0
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
	var nenv := OS.get_environment("AWECRAFT_THREADGEN_N")
	# AC-0079 v3 C3: default threadgen = mini(cores, 6). The r4 cold wall is the
	# 36-chunk crossing-1 core fill: 36 x ~220 ms of gen paced by the pool size
	# (3 -> 2.64 s vs 6 -> 1.32 s). Env override above stays; final cap below.
	threadgen_max = mini(OS.get_processor_count(), 6)
	# AC-0160 run 2: the 6-wide data pass is SLOWER per task than 4-wide here
	# (measured wms 360-530 ms at 6 concurrent vs 120-170 at 3; allocator/
	# memory-bandwidth contention on 6 cores) and would pile 6 far-data
	# tasks on top of the 4 build slots during the startup window. 4-wide
	# keeps the 5x5 spawn data (24 chunks) at ~1.3 s while the builds
	# pipeline behind it. Placed BEFORE the env override so
	# AWECRAFT_THREADGEN_N can still select 5/6 (final cap 6 below).
	threadgen_max = mini(threadgen_max, 4)
	if nenv != "":
		threadgen_max = maxi(1, nenv.to_int())
	threadgen_max = mini(threadgen_max, 6)
	threadgen_pool = Engine.get_singleton("WorkerThreadPool")
	threadgen = true
	io_pool = threadgen_pool  # AC-0164: column I/O shares the threadgen pool
	_tg_debug = OS.get_environment("AWECRAFT_TGDEBUG") == "1"
	print("THREADGEN on threadgen=true pool=%d" % threadgen_max)
	var menv := OS.get_environment("AWECRAFT_THREADMESH_N")
	# AC-0079 v3 C2 (pool-saturation mitigation, plan risk (c)): contained light
	# now runs on the mesh workers (64 ms/chunk instead of 44), so TM3 + TG6 +
	# main = 10 threads on 6 cores oversubscribes the cold phase (measured:
	# X1 wall 4256-4325 ms with TM3 vs 3342 ms with TM2; walk p95 61 either way,
	# max 121 vs 111). TM2 keeps build capacity (15.6 chunks/s) above the
	# steady r4 demand (9-14/s). Env override above stays; cap below stays.
	# AC-0160 run 2: cap 2 -> cores (6 here). The priority split changes the
	# calculus: TM tasks are HIGH priority (they always get their share) and
	# the drain data path is idle during the startup window (the recenter
	# 5x5 burst group task owns the data), so the 9 spawn builds can use all
	# 6 pool threads (9 x ~320 ms / 6 = ~0.7 s) — the spawn 3x3 lands in
	# ~1.5 s. In the trickle, TM6 + TG (low-priority, capped at 3 of 6
	# threads by the pool's low-priority ratio) = 9 runnable on 6 cores:
	# ~10 mesh tasks/s, the front advances ~5/s net — well past taxi 10
	# inside the 1500-frame bandmap sample. (The old all-low-priority
	# oversubscription measured by AC-0079 — TM3 + TG6 = 10, X1 wall 4.3 s —
	# no longer applies: TG is capped at 4 and low priority after startup.)
	threadmesh_max = maxi(1, mini(OS.get_processor_count(), 6))
	if menv != "":
		threadmesh_max = maxi(1, menv.to_int())
	threadmesh_max = mini(threadmesh_max, 6)
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
	_tm_ctx_atlas = Data.atlas_tex  # AC-0160: stamp for the _process staleness guard
	threadmesh = true
	_tm_debug = OS.get_environment("AWECRAFT_TMDEBUG") == "1"
	print("THREADMESH on threadmesh=true pool=%d" % threadmesh_max)
	_recprobe = OS.get_environment("AWECRAFT_RECPROBE") == "1"
	var dr := OS.get_environment("AWECRAFT_DRAIN_MS")
	if dr != "" and dr.to_int() > 0:
		drain_budget_ms = dr.to_int()
	# AC-0224: tuning knob for the streaming handoff burst (default
	# STREAM_TM_HANDOFF_PER_FRAME = 3); clamped so a bad value can't
	# disable the cap (1) or burst back to the recenter-burst regime (16).
	var hoe := OS.get_environment("AWECRAFT_TM_HO")
	if hoe != "":
		stream_ho_cap = clampi(hoe.to_int(), 1, STREAM_TM_HANDOFF_MAX)
	# AC-0152: harness band overrides (default 4/8 per Bedrock Realms).
	var b0e := OS.get_environment("AWECRAFT_BAND0")
	if b0e != "":
		band0_r = maxi(0, b0e.to_int())
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
		while waited < 20000 and (not threadgen_inflight.is_empty() or not threadmesh_inflight.is_empty() or not _io_read_inflight.is_empty() or not _io_write_inflight.is_empty()):
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
	_io_read_inflight.clear()  # AC-0164
	_io_write_inflight.clear()
	_io_slots.clear()
	# AC-0187: the edit lane is this node's own thread (not the engine
	# singleton); its queue is drained above, so stop it at exit.
	if threadmesh_edit_pool != null:
		threadmesh_edit_pool.stop()
		threadmesh_edit_pool = null

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


func _process(_delta: float) -> void:
	var pf0 := Time.get_ticks_usec()
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
	# AC-0212: engine mode = no manual pass at all (the render server culls
	# each MeshInstance3D automatically); one bool check per frame.
	if _cull_enabled:
		_frustum_cull_pass()
	# threadmesh_inflight keeps this running while mesh tasks are in flight
	# even when every bookkeeping list is drained (else the poll never runs).
	if light_dirty.is_empty() and fluid_dirty.is_empty() and queue_size == 0 and light_pending.is_empty() and tex_refresh.is_empty() and threadmesh_inflight.is_empty() and _io_read_inflight.is_empty() and _io_write_inflight.is_empty() and not _rec_pending and _bl_want.is_empty() and _col_pending.is_empty() and edit_front.is_empty():
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
	if not edit_front.is_empty():
		_edit_front_drain()
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
	threadgen_poll()
	var fp3 := Time.get_ticks_usec()
	threadmesh_poll()
	io_poll()  # AC-0164: land finished column I/O tasks
	var fp4 := Time.get_ticks_usec()
	_recenter_slice()
	var fp5 := Time.get_ticks_usec()
	_drain_build_queue()
	var fp6 := Time.get_ticks_usec()
	_drain_tex_refresh()
	var pf2 := Time.get_ticks_usec()
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
		_tm_ctx_atlas = Data.atlas_tex  # AC-0160: re-stamp (the _process guard would catch it, but stamp now)

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
# shows the screen. Target = the render circle's column count (band 3 is
# data-only, never meshed — it is excluded by construction).
func start_loading(title: String) -> void:
	if not loading_bypass:
		return
	loading_active = true
	_loading_target = circle_count()
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

# Meshed columns of the current render circle (progress evidence from the
# chunk nodes themselves — no shadow counters to drift).
func meshed_in_circle() -> int:
	var n := 0
	for dx in range(-render_radius, render_radius + 1):
		for dz in range(-render_radius, render_radius + 1):
			if not in_render_circle(dx, dz):
				continue
			var c = chunks.get(_key(last_pcx + dx, last_pcz + dz))
			if c != null and c.mesh_built:
				n += 1
	return n

# Per-frame: refresh the UI from the real provenance counters, then test the
# completion predicate — circle fully meshed and both worker pools drained.
func _loading_tick() -> void:
	if not loading_active:
		return
	# A radius change mid-load (Options over a paused load) re-anchors the
	# target instead of stalling on the stale one.
	if render_radius != _loading_radius:
		_loading_radius = render_radius
		_loading_target = circle_count()
	var m := meshed_in_circle()
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


func in_render_circle(dx: int, dz: int) -> bool:
	return dx * dx + dz * dz <= render_radius * render_radius


# AC-0152 ring: outside the render circle but touching it within the
# 8-neighborhood. Band-2 edge chunks build against their 4-axis neighbors,
# which sit OUTSIDE the circle at large R (the diamond collar is far inside
# the circle) — without this ring their data never arrives and ~400 boundary
# chunks strand the queue. Data-only, band 3, never meshed.
# The min squared distance over the 8-neighborhood is the SUM of the per-axis
# mins (axis 0 stays 0, axis |a| drops to (|a|-1)^2) — closed form, no loop:
# the ring walk runs this per box cell, so the 9-test loop was ~3x the walk.
func in_circle_ring(dx: int, dz: int) -> bool:
	if in_render_circle(dx, dz):
		return false
	var ax := absi(dx)
	var az := absi(dz)
	var gx := ax - 1 if ax > 0 else 0
	var gz := az - 1 if az > 0 else 0
	return gx * gx + gz * gz <= render_radius * render_radius


func in_stream_set(dx: int, dz: int) -> bool:
	# circle(R) ∪ diamond(b1_eff + 1) ∪ circle ring: the extra sets are band
	# 3 (data-only) — the collar covers band 0/1 edge neighbors at small R,
	# the ring covers band 2 edge neighbors at large R.
	return in_render_circle(dx, dz) or absi(dx) + absi(dz) <= b1_eff() + 1 or in_circle_ring(dx, dz)


# 0 = full (tick+collide), 1 = full mesh (no tick/collide), 2 = coarse
# (no tick/collide), 3 = collar ∪ circle ring data-only. -1 = outside the
# stream set. Note: band 2 is everything inside the circle OUTSIDE the
# diamond — at r50 that is 7532 of the 7845 chunks (taxi ranges to ~100 in
# the circle). AC-0181: band 1/2 fidelity swapped vs AC-0152 (0-12 full,
# 13+ coarse).
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
	band_buckets[b].push_front({"key": key, "cx": cx, "cz": cz, "data_only": false})
	_qb[key] = b  # AC-0160
	queued_keys[key] = "build"
	queue_size += 1
	_build_q_n += 1
	_cap_queue_depth()  # AC-0222: keep the build depth at the circle cap
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
		if cx == 0 and cz == 0:
			# AC-0155/AC-0164: the spawn column keeps the synchronous
			# disk-first read (spawn contract: immediate ground under the
			# player; one column, once per boot).
			if _try_disk_load(c, cx, cz):
				_gen_last_disk = true
				_apply_edits_to_chunk(c)
				return 0
		elif _io_read_enqueue(cx, cz, _key(cx, cz), true):
			# AC-0164: disk-first off the main thread — file read + decode
			# on a worker; the data lands in _io_read_handoff (edits
			# applied there, provenance marked when it LANDS).
			return 0
	# AC-0152: sync gen is now ONLY the spawn chunk (0,0) — the documented
	# spawn contract (AC-0082: "the player needs immediate ground data").
	# The old axis exclusion (cx==0 OR cz==0 sync) was pre-AC-0082 Phase-1
	# legacy with no recorded rationale; at render 50 it is 200 axis chunks
	# x ~125 ms of main-thread gen that paced the drain and made the
	# spawn-3x3 ~1 s target unreachable (measured 11.7 s). All other chunks
	# threadgen through the identical handoff (data/init_fl/edits, stale-drop,
	# dedup — proven at r50 in AC-0082 G4: gen_ms −98%). AC-0208: the sync
	# gen runs the C++ generator (WorldGen.generate = AweGen.generate_flat);
	# the GDScript gen fallback was removed — there is no non-C++ gen path.
	if threadgen and (cx != 0 or cz != 0):
		threadgen_enqueue(cx, cz, _key(cx, cz), c.get_instance_id())
		if timing:
			print("GENCHUNK %d,%d gen_ms=0 thread=1 t=%d" % [cx, cz, Time.get_ticks_msec()])
		return 0
	# AC-0040: the banana-tree pass (shore dirt edge only) runs on the
	# world-building landings — WorldGen.generate itself stays untouched
	# (the genhash arm hashes it directly; the AC-0215 baseline holds).
	var gdata: PackedByteArray = WorldGen.generate(cx, cz, Game.world_seed)
	var gres: Dictionary = WorldGen.apply_banana_trees(gdata, cx, cz, Game.world_seed, Data.HEIGHT)
	c.data_landed(gdata, PackedByteArray())
	_banana_register(cx, cz, gres["fruits"])
	gen_count += 1
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


func threadgen_enqueue(cx: int, cz: int, key: String, inst: int) -> void:
	if _tg_inflight_keys.has(key):
		_tg_dedup += 1
		return
	if threadgen_inflight.size() >= threadgen_max:
		_tg_capdrop += 1
		if _tg_debug:
			print("TGEN CAPDROP %d,%d inflight=%d" % [cx, cz, threadgen_inflight.size()])
		return
	var skipf := _gen_skip_flag(cx, cz)  # AC-0216 (0 = full density)
	if skipf:
		perf_gen_skip_enq += 1
	var entry := {"key": key, "cx": cx, "cz": cz, "inst": inst, "args": [cx, cz, Game.world_seed, Data.HEIGHT, Data.SEA, skipf], "tenq": Time.get_ticks_msec()}
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
	var resl: Array = g.generate_resl(int(a[0]), int(a[1]), int(a[2]), int(a[3]), int(a[4]), int(a[5]))
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
		_banana_register(int(e[1]), int(e[2]), gres["fruits"])
		gen_count += 1
		chunk_origin[_key(int(e[1]), int(e[2]))] = "gen"  # AC-0155
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
				threadgen_enqueue(int(e["cx"]), int(e["cz"]), e["key"], int(e["inst"]))
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
	if expected_inst >= 0 and int(c.get_instance_id()) != expected_inst:
		_tg_stale += 1
		if _tg_debug:
			print("TGEN STALE %d,%d (inst mismatch %d != %d)" % [int(e["cx"]), int(e["cz"]), expected_inst, int(c.get_instance_id())])
		return
	if c.data.size() != 0:
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
	c.slabs_landed(resl[0], resl[1])
	_banana_register(tcx, tcz, gres["fruits"])
	gen_count += 1
	chunk_origin[e["key"]] = "gen"  # AC-0155
	_apply_edits_to_chunk(c)
	_tg_handoff += 1
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
	var res: Dictionary = mc.build_accs(entry["data"], entry["fl"], int(entry["cx"]), int(entry["cz"]), entry["nbs"], entry["ctx"], entry["ms"], entry["eff"], int(entry.get("si0", 0)), int(entry.get("si1", -1)), int(entry.get("d_off", 0)), Lighting._att, Lighting._glow)
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
	if bool(e.get("edit", false)):
		edit_inflight_count = maxi(0, edit_inflight_count - 1)
	var c = chunks.get(key)
	if c == null:
		_tm_stale += 1
		if _tm_debug:
			print("TMESH STALE %d,%d (chunk gone)" % [int(e["cx"]), int(e["cz"])])
		return
	if int(c.get_instance_id()) != int(e["inst"]):
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
			_editprobe_done_ms = int((int(e.get("t_done", 0)) - int(e.get("t_submit", 0))) / 1000.0)
			_editprobe_ns = res.get("ns", [])
			_editprobe_phet = res.get("phet", [])
			_editprobe_prime_flag = false
	if bool(e.get("edit", false)):
		var ta2 := Time.get_ticks_msec()
		var old_eff2 = c.last_eff
		c.apply_edit_accs(res, _tm_ms_full)
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
	var ta := Time.get_ticks_msec()
	var old_eff = c.last_eff
	var lod_swap := bool(c.lod_pending)
	var lod_cap: Array = []
	if lod_swap:
		lod_cap = c.capture_lod()
	c.apply_accs(res, _tm_ms_full)
	c.saved_light = {}
	if lod_swap:
		var ltaxi := absi(int(c.cx) - last_pcx) + absi(int(c.cz) - last_pcz)
		var lkind := 0 if int(e["band"]) == 2 else 1
		c.store_lod_cache(lod_cap, lkind, ltaxi >= LOD_HYS_RING_MIN and ltaxi <= LOD_HYS_RING_MAX)
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


func _edit_front_add(key: String, y: int) -> void:
	var si0 := maxi(0, (y - 3) / 16)
	var si1 := mini(ChunkScript.slab_n() - 1, (y + 1) / 16)
	for e in edit_front:
		if e["key"] == key:
			e["si0"] = mini(int(e["si0"]), si0)
			e["si1"] = maxi(int(e["si1"]), si1)
			return
	edit_front.append({"key": key, "si0": si0, "si1": si1})
	edit_front_set[key] = true
	_edit_front_dispatch(key)


func _edit_front_entry(key: String):
	for e in edit_front:
		if e["key"] == key:
			return e
	return null


func _edit_front_drop(key: String) -> void:
	for i in range(edit_front.size()):
		if edit_front[i]["key"] == key:
			edit_front.remove_at(i)
			edit_front_set.erase(key)
			return


func _edit_front_dispatch(key: String) -> void:
	var e: Dictionary = _edit_front_entry(key)
	if e == null:
		return
	var c = chunks.get(key)
	if c == null or not bool(c.mesh_built):
		_edit_front_drop(key)
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
		_edit_front_drop(key)
		return
	if not _eff_stored_eq(cached.eff, c.last_eff):
		_edit_front_drop(key)
		return
	if not _mesh_dispatch_edit(c, int(c.cx), int(c.cz), int(e["si0"]), int(e["si1"]), cached.eff):
		return
	perf_edit_front_scoped += 1
	_edit_front_drop(key)


func _edit_front_drain() -> void:
	if _shutting_down or edit_front.is_empty():
		return
	var key: String = edit_front[0]["key"]
	var c = chunks.get(key)
	if c == null or not bool(c.mesh_built):
		_edit_front_drop(key)
		return
	_edit_front_dispatch(key)


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
			nbs["%d,%d" % [dx, dz]] = mc.snap_rings(nc.data, nc.fl, dx, dz)
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
	if int(c.band) == 2:
		ctx_w["coarse"] = true
		ctx_w["uv_scale"] = 2
	# AC-0211: own-column value-copy via C++ (AC-0208: the only lane).
	var entry := {
		"key": key, "cx": cx, "cz": cz, "inst": c.get_instance_id(),
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
	# AC-0152/AC-0160: band 2 has no special path anymore — the impostor
	# dispatch was removed; it builds a full mesh through the same
	# nbs/eff/worker pipeline as band 0/1.
	# AC-0160 run 2: the spawn chunk (0,0) now BUILDS through the workers
	# like every other chunk — the gate's model is "5x5 data + 9 worker
	# builds", and the (0,0) sync BUILD was the startup serializer: a
	# 650 ms main-thread mesh + ~600 ms face-block-light cascade (~1.3 s
	# block) that froze the drain and idled the pool. The spawn contract
	# that stays is the SYNC GEN one (AC-0082: "the player needs immediate
	# ground DATA" — recenter() sync-gens (0,0) before the first drain
	# frame). The data-empty sync below still covers the degenerate case
	# (a dispatch reaching (0,0) before its data — impossible in the
	# normal flow: the recenter burst owns it).
	if c.data.is_empty():
		if defer_on_cap:
			perf_edit_syncs += 1
		var old_eff = c.last_eff
		c.build_mesh(get_block, eff)
		c.saved_light = {}
		_eff_landed(c, old_eff, c.last_eff)
		_count_collision_build(c)
		_stage_check(c, key)
		_bd_log(cx, cz)
		return true
	var nbs: Dictionary = {}
	var mc: Variant = ChunkScript.mesh_cpp()
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			if (dx == 0) == (dz == 0):
				continue
			var nc = chunks.get(_key(cx + dx, cz + dz))
			if nc == null or nc.data.is_empty():
				# AC-0160 spawn fast path: while the spawn 3x3 is pending, a
				# missing neighbor must NOT force the sync fallback (the
				# on-demand gen is 100-500 ms of main-thread build that paced
				# the drain to ~1 unit/frame — 10s for the 3x3). Defer: the
				# caller's retry path re-queues; threadgen delivers the
				# missing data within ~500 ms. The drain itself never hits
				# this (its _build_ready startup gate already requires all 8
				# neighbors), so no queue entry is consumed by a defer.
				if _startup_pending():
					return false
				# Workers can't on-demand-generate; the sync _build_snap can.
				if defer_on_cap:
					perf_edit_syncs += 1
				var old_eff = c.last_eff
				c.build_mesh(get_block, eff)
				c.saved_light = {}
				_eff_landed(c, old_eff, c.last_eff)
				_count_collision_build(c)
				_stage_check(c, key)
				_bd_log(cx, cz)
				return true
			# AC-0211: C++ compact snap ring (256 B/slab, the boundary
			# slice only) — replaces the per-neighbor _slabs_deepcopy of
			# all 24 slabs; the C++ build_accs consumes it directly and
			# the worker never sees live neighbor state (the ring is a
			# main-thread value snapshot). AC-0208: C++-ONLY — the GDScript
			# deep-copy nbs (the mc==null fallback) was removed.
			nbs["%d,%d" % [dx, dz]] = mc.snap_rings(nc.data, nc.fl, dx, dz)
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
	tm_cap = maxi(1, tm_cap - (2 if not edit_front.is_empty() else 1))
	if threadmesh_inflight.size() >= tm_cap:
		_tm_capdrop += 1
		if _tm_debug:
			print("TMESH CAPDROP %d,%d inflight=%d" % [cx, cz, threadmesh_inflight.size()])
		if defer_on_cap:
			# AC-0126: the edit path never syncs on a cap drop — the flush
			# re-queues the chunk (FIFO, chunk-key deduped) and retries next
			# frame when a worker slot frees.
			perf_edit_defers += 1
			return false
		var old_eff = c.last_eff
		c.build_mesh(get_block, eff)
		c.saved_light = {}
		_eff_landed(c, old_eff, c.last_eff)
		_count_collision_build(c)
		_stage_check(c, key)
		_bd_log(cx, cz)
		return true
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
	if int(c.band) == 2:
		# AC-0152 coarse LOD (was the band-1 ctx): 2x UV scale (32-block
		# texture period), cutout falls back opaque, flora dropped (in
		# build_accs). AC-0181: routed to band 2 (taxi >= 13) — uniform
		# coarse out to R; band 1 (taxi 5-12) now builds full like band 0.
		ctx_w["coarse"] = true
		ctx_w["uv_scale"] = 2
	# AC-0211: the own-column value-copy goes through C++ (AC-0208: the
	# only lane — the worker + the handoff stale check consume the same
	# paletted shape).
	var entry := {
		"key": key, "cx": cx, "cz": cz, "inst": c.get_instance_id(),
		"data": mc.slab_copy(c.data),  # AC-0208: C++-only value copy (the GDScript _slabs_deepcopy fallback is gone)
		"fl": mc.slab_copy(c.fl),
		"stamp": c.stamp(),
		"band": int(c.band),
		"nbs": nbs, "eff": eff, "eff_trust": eff_trust,
		"ctx": ctx_w, "ms": ms_w, "ngen": _ngens_for(cx, cz),
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

func _refresh_look_dir() -> void:
	var p = Game.player
	if p == null:
		return
	var dy := float(p._yaw) - _look_yaw
	dy = fposmod(dy + PI, TAU)
	if dy > PI:
		dy = TAU - dy
	if dy * 180.0 / PI < PICK_LOOK_REFRESH_DEG:
		return
	# AC-0079 fix: match player.gd aim_dir() = Basis.from_euler(pitch,yaw,0)*(0,0,-1)
	# = (-sin(yaw), -cos(yaw)) in (x,z). Old (cos,sin) pointed sideways at yaw=-PI/2.
	var d := Vector2(-sin(float(p._yaw)), -cos(float(p._yaw)))
	var l := d.length()
	_look_dir = d / l if l > 1e-6 else Vector2(1, 0)
	_look_yaw = float(p._yaw)

func _entry_score(e: Dictionary, pcx: int, pcz: int, px: float, pz: float) -> float:
	var cx := int(e["cx"])
	var cz := int(e["cz"])
	var d := absi(cx - pcx) + absi(cz - pcz)
	var to_cx := float(cx * 16 + 8) - px
	var to_cz := float(cz * 16 + 8) - pz
	var l := Vector2(to_cx, to_cz).length()
	var dot := _look_dir.x * to_cx + _look_dir.y * to_cz
	var a := dot / l if l > 1e-6 else 0.0
	a = clampf(a, 0.0, 1.0)
	var cheby := maxi(absi(cx - pcx), absi(cz - pcz))
	var boost := 2.0 if cheby <= 1 else 0.0
	return float(d) + (1.0 - a) * 0.75 * float(d) - boost

func _collect_pool(build: bool, include_fb := false, maxb := -1) -> Array:
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
				if c == null or c.data.is_empty() or c.mesh_built:
					continue
				out.append(e)
			else:
				if c == null or not c.data.is_empty():
					continue
				out.append(e)
	return out

func _drain_build_queue() -> void:
	_startup_gen_apply()
	if edit_inflight_count > 0:
		return
	if queue_size == 0:
		if _bl_want.is_empty() and _col_pending.is_empty():
			return
		_col_drain_step()
		return
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
	# time budget (steady state: 2/1 units, drain_budget_ms).
	var budget := LOAD_DRAIN_UNITS if loading_active else (12 if startup else (2 if last_build_us < BUILD_FAST_US else 1))
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
	# grows one bucket per 15 frames until it spans the whole queue, so the
	# queue trends down continuously instead of stranding the far tail.
	if _drain_win_b < 0:
		_drain_win_b = b1_eff() + 2
	if not startup and not loading_active:
		_drain_win_acc += 1
		if _drain_win_acc >= 15:
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
	var px: float = Game.player.position.x if Game.player != null else 0.0
	var pz: float = Game.player.position.z if Game.player != null else 0.0
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
				if c == null or c.data.is_empty() or c.mesh_built:
					continue
				if not _build_ready(int(e["cx"]), int(e["cz"])):
					continue
				var s := _entry_score(e, last_pcx, last_pcz, px, pz)
				if s < ls:
					ls = s
					le = e
					lc = c
			if lc == null:
				break
			if _build_unit(lc, int(le["cx"]), int(le["cz"])):
				break  # TM depth reached — phase 2 feeds the TG pool now
			_remove_entry(le)
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
				var s := _entry_score(e, last_pcx, last_pcz, px, pz)
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
		_col_drain_step()
		return
	while budget > 0:
		if Time.get_ticks_usec() - t0 > budget_us:
			break
		var u := 0
		_refresh_look_dir()
		var bp: Array = _collect_pool(true, false, maxb)
		var best_e: Dictionary = {}
		var best_c: Node3D = null
		var best_s := 1e30
		for e in bp:
			var c = chunks.get(e["key"])
			if c == null or c.data.is_empty() or c.mesh_built:
				continue
			if not _build_ready(int(e["cx"]), int(e["cz"])):
				continue
			var s := _entry_score(e, last_pcx, last_pcz, px, pz)
			if s < best_s:
				best_s = s
				best_e = e
				best_c = c
		if best_c == null:
			# AC-0079 v3 C1: lead-column pre-build, second pass. The in-radius
			# READY pool is empty — pick the lowest-score READY candidate from
			# _collect_pool(true, true) (identical _build_ready gate, identical
			# _build_unit/_remove_entry). In-radius READY ALWAYS wins (this pass
			# only runs when the first pass found nothing); the forward band is
			# exactly 2r+1 entries, so the pass is bounded.
			var fp: Array = _collect_pool(true, true, maxb)
			for e in fp:
				var c = chunks.get(e["key"])
				if c == null or c.data.is_empty() or c.mesh_built:
					continue
				if not _build_ready(int(e["cx"]), int(e["cz"])):
					continue
				var s := _entry_score(e, last_pcx, last_pcz, px, pz)
				if s < best_s:
					best_s = s
					best_e = e
					best_c = c
		if best_c != null:
			var deferred := _build_unit(best_c, int(best_e["cx"]), int(best_e["cz"]))
			if deferred:
				# AC-0160 run 2: worker slots full (or a task already in
				# flight for this key) — the entry stays queued (NOT removed)
				# and the frame ends; the next frame re-dispatches when a slot
				# frees. The drain NEVER takes the sync fallback: the 8-
				# neighbor gate above guarantees the nbs snapshot, and
				# defer_on_cap turns the cap drop into this defer instead of
				# a 270-1235 ms main-thread build (the measured spawn
				# serializer).
				break
			_remove_entry(best_e)
			u = 1
		if u == 0 and (gen_budget_ms < 0 or gen_used_ms < gen_budget_ms):
			# AC-0079 round 3: scored DATA pick. The spec requires the lowest-score
			# no-data entry (not FIFO), else forward leading-edge data only arrives
			# after all nearer-band data drains and _build_ready stalls the forward
			# mesh. Pool = _collect_pool(false) (band scan from the dq cursor,
			# capped at PICK_POOL_CAP, same as before); each candidate is scored
			# with _entry_score and the lowest wins. Per-consumption FIFO cursor
			# bookkeeping (dq_b/dq_i advance past the consumed entry) is kept so
			# entries are never re-picked and queue_size stays exact.
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
				var s := _entry_score(e, last_pcx, last_pcz, px, pz)
				if s < dp_s:
					dp_s = s
					dp_e = e
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
			if u == 0 and dp.is_empty():
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
	if units > 0:
		perf_build_units += units
		perf_drain_frames += 1
		var fm := (Time.get_ticks_usec() - t0) / 1000.0
		if fm > perf_max_drain_ms:
			perf_max_drain_ms = fm
		if timing:
			print("DRAINMS units=%d ms=%.1f t=%d inflight=%d enq=%d cap=%d dedup=%d" % [units, fm, Time.get_ticks_msec(), threadgen_inflight.size(), _tg_enq, _tg_capdrop, _tg_dedup])
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
	var strips: Array = []
	for side in range(4):
		var s: Array = _FACE_SIDES[side]
		var nc = chunks.get(_key(int(c.cx) + int(s[0]), int(c.cz) + int(s[1])))
		var st: PackedByteArray = PackedByteArray()
		if nc != null and not nc.data.is_empty():
			st = _face_of(nc, _shared_face(int(s[0]), int(s[1])))
		strips.append(st)
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
	if new_eff.is_empty():
		return
	var changed: bool = old_eff.is_empty() or old_eff.get("arr", PackedByteArray()) != new_eff.get("arr", PackedByteArray())
	if not changed:
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
	var c: Node3D = ChunkScript.new()
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
	perf_create_sync_gen += 1
	var c: Node3D = _make_chunk_node(cx, cz)
	_materialize_chunk_data(c, cx, cz)  # AC-0155: disk-first, else sync gen
	_apply_edits_to_chunk(c)
	if mesh_now:
		c.build_mesh(get_block)
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
	# the fog at fog_far=(R+1)*16*0.95 covers the whole r+1 band, so
	# stepping back re-enters the chunk instantly (no re-queue, no re-mesh,
	# no collision gap). True free stays at r+2 after the 2-recenter
	# hysteresis in recenter(); the retained mesh dies with the node.
	c.candidate = true
	c.cand_since = 0
	c.lod_pending = false
	c.clear_lod_cache()
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
			else:
				i += 1


func recenter(wx: float, wz: float, mesh_now := true) -> void:
	last_pcx = int(floorf(wx / 16.0))
	last_pcz = int(floorf(wz / 16.0))
	var pcx := last_pcx
	var pcz := last_pcz
	# AC-0213: small-move pacing — mark the move now; the drain paces at the
	# trickle budget until the window expires (see _drain_build_queue).
	var _now_ms := Time.get_ticks_msec()
	_sm_move_until = _now_ms + SMALL_MOVE_BUDGET_MS
	# AC-0213: ahead-ring requeue debounce — a recenter one chunk past the
	# previous center within AHEAD_RING_DEBOUNCE_MS re-queues the same ahead
	# ring the prior rebuild just queued (tap-forward across boundaries);
	# skip the full queue rebuild and let the in-flight/finalized walk stand.
	# The next non-debounced recenter rebuilds from the new center.
	var _debounced := (_now_ms - _last_recenter_ms) < AHEAD_RING_DEBOUNCE_MS \
		and (absi(pcx - _last_recenter_pcx) + absi(pcz - _last_recenter_pcz)) == 1
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
	for key in to_free:
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
		if not _nofree:
			c.queue_free()
	_rp_free_ms += (Time.get_ticks_usec() - tf1) / 1000.0
	threadgen_poll()
	threadmesh_poll()
	io_poll()  # AC-0164
	if not mesh_now:
		# AC-0152: sync-fill the whole stream set (circle ∪ collar ∪ ring;
		# the ring reaches one chunk past the circle edge).
		var half := maxi(rr + 1, b1_eff() + 1)
		var make: Array[Dictionary] = []
		for dx in range(-half, half + 1):
			for dz in range(-half, half + 1):
				if not in_stream_set(dx, dz):
					continue
				var cx := pcx + dx
				var cz := pcz + dz
				if not chunks.has(_key(cx, cz)):
					make.append({"cx": cx, "cz": cz, "d": absi(dx) + absi(dz)})
		make.sort_custom(func(a, b): return a.d < b.d)
		for e in make:
			create_chunk(e.cx, e.cz, false)
		return
	var tr1 := Time.get_ticks_usec()
	if _debounced:
		# AC-0213: no queue rebuild — the prior rebuild (in flight or
		# finalized) already queued this ahead ring; the pre-warm below
		# still enqueues the fresh 5x5 and the drain trickles the rest.
		pass
	else:
		_rec_pending = true
		_rec_pcx = pcx
		_rec_pcz = pcz
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
				if pdx == 0 and pdz == 0:
					continue
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
	# (0,0) keeps its sync gen (the spawn contract: immediate ground under
	# the player) — done here in recenter so it exists before the first
	# drain frame; the group burst and the drain data path both skip it.
	var c0 = chunks.get(_key(pcx, pcz))
	if c0 != null and c0.data.is_empty():
		var sg0 := Time.get_ticks_usec()
		_materialize_chunk_data(c0, pcx, pcz)  # AC-0155: disk-first, else sync gen
		_apply_edits_to_chunk(c0)
		if timing:
			print("GENCHUNK %d,%d gen_ms=%d t=%d" % [pcx, pcz, (Time.get_ticks_usec() - sg0) / 1000, Time.get_ticks_msec()])
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
	var taxi := absi(int(c.cx) - last_pcx) + absi(int(c.cz) - last_pcz)
	var old_kind := 1 if oldb == 2 else 0
	var new_kind := 1 if nb == 2 else 0
	c.band = nb
	c.collision_enabled = collision_enabled and nb == 0
	if not bool(c.mesh_built):
		return
	if old_kind == new_kind:
		if oldb == 0 and nb != 0:
			c.drop_slab_bodies()
		elif nb == 0 and oldb != 0:
			c.mark_all_slabs_dirty()
			if not _col_pending_set.has(key):
				_col_pending.append(key)
				_col_pending_set[key] = true
		return
	if new_kind == 0:
		c.mark_all_slabs_dirty()
		if not _col_pending_set.has(key):
			_col_pending.append(key)
			_col_pending_set[key] = true
	else:
		c.drop_slab_bodies()
	if bool(c.lod_cache_valid(new_kind)):
		c.swap_to_cached(taxi >= LOD_HYS_RING_MIN and taxi <= LOD_HYS_RING_MAX)
	else:
		c.clear_lod_cache()
		c.lod_pending = true
		if not light_pending_set.has(key):
			light_pending.append(key)
			light_pending_set[key] = true
		flush_active = true


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
		var taxi := absi(dx) + absi(dz)
		if int(c.alt_lod) >= 0 and not (taxi >= LOD_HYS_RING_MIN and taxi <= LOD_HYS_RING_MAX):
			c.clear_lod_cache()
		var cb := int(c.band)
		if cb != nb:
			var target := nb
			if cb == 2 and nb == 1 and taxi > LOD_HYS_FULL_MAX:
				target = cb
			if cb == 1 and nb == 2 and taxi < LOD_HYS_COARSE_MIN:
				target = cb
			if cb != target:
				_reband(c, key, cb, target)
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
	_rec_new_buckets[mini(int(w["d"]), _rec_new_buckets.size() - 1)].push_front({"key": key, "cx": int(w["cx"]), "cz": int(w["cz"]), "data_only": false})
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
					queued_keys.erase(e2["key"])
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
		_rec_pending = false
		_rec_want = {}
		_rec_want_keys = []
		_rec_new_buckets = []
		_rec_cursor = 0
		_rec_i = 0
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
	_rec_new_buckets[mini(absi(dx) + absi(dz), _rec_new_buckets.size() - 1)].push_front({"key": key, "cx": cx, "cz": cz, "data_only": true})
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
	_edit_front_add(_key(cx, cz), y)
	_eff_cache_evict(_key(cx, cz))
	_mark_light_around(cx, cz)
	if _fluid_near(x, y, z):
		_fluid_write = true
	_record_edit(cx, cz, fi, id, c.fl_at(fi))

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
	var path := ChunkIO.path_for(Save.active_slot, _chunk_face(cx), cx, cz)
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var bytes := f.get_buffer(f.get_length())
	f.close()
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

func _materialize_chunk_data(c: Node3D, cx: int, cz: int) -> int:
	if c.data.is_empty() and _io_read_keys.has(_key(cx, cz)):
		# AC-0164: a worker read is in flight for this column — the data is
		# on its way; never sync-load or sync-gen on top of it.
		return 0
	if c.data.is_empty() and _try_disk_load(c, cx, cz):
		return 0
	if c.data.is_empty():
		var tg := Time.get_ticks_msec()
		# AC-0040: the banana-tree pass (shore dirt edge only) — see the
		# sync-gen landing above (WorldGen.generate stays untouched).
		var gdata: PackedByteArray = WorldGen.generate(cx, cz, Game.world_seed)
		var gres: Dictionary = WorldGen.apply_banana_trees(gdata, cx, cz, Game.world_seed, Data.HEIGHT)
		c.data_landed(gdata, PackedByteArray())
		_banana_register(cx, cz, gres["fruits"])
		gen_count += 1
		var dg := Time.get_ticks_msec() - tg
		gen_ms_total += dg
		chunk_origin[_key(cx, cz)] = "gen"
		return dg
	return 0

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
		"data": ChunkIO._slabs_deepcopy(c.data),
		"fl": ChunkIO._slabs_deepcopy(c.fl),
		"light": light,
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
		"path": ChunkIO.path_for(slot, int(e["face"]), cx, cz),
		"data": e["data"],
		"fl": e["fl"],
		"light": e.get("light", {}),
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
	var blob := ChunkIO.encode_column(ChunkIO._slabs_flat(entry["data"]), ChunkIO._slabs_flat(entry["fl"]), int(entry["seed"]), int(entry["height"]), entry.get("light", {}))
	var f = FileAccess.open(String(entry["path"]), FileAccess.WRITE)
	if f == null:
		return
	f.store_buffer(blob)
	f.close()

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
	var path := ChunkIO.path_for(slot, _chunk_face(cx), cx, cz)
	if not FileAccess.file_exists(path):
		return false
	var entry := {
		"key": key,
		"cx": cx,
		"cz": cz,
		"path": path,
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
	var f = FileAccess.open(String(entry["path"]), FileAccess.READ)
	if f != null:
		var bytes := f.get_buffer(f.get_length())
		f.close()
		var r = ChunkIO.decode_column(bytes, int(entry["seed"]), int(entry["height"]))
		if typeof(r) == TYPE_DICTIONARY and not (r as Dictionary).is_empty():
			res = r
	entry["result"] = res
	entry["ms"] = (Time.get_ticks_usec() - t0) / 1000.0

func io_poll() -> void:
	if _io_read_inflight.is_empty() and _io_write_inflight.is_empty():
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
	while i < _io_write_inflight.size():
		var w: Dictionary = _io_write_inflight[i]
		if io_pool.is_task_completed(int(w["tid"])):
			_io_write_inflight.remove_at(i)
			_io_slots.erase(int(w["tid"]))
			_io_write_keys.erase(w["key"])
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
		threadgen_enqueue(int(e["cx"]), int(e["cz"]), key, int(c.get_instance_id()))
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

# AC-0119: the one legitimate boot-time sync gen, made explicit (port rule:
# the spawn chunk is generated synchronously at boot, NOT on read). Idempotent.
func _ensure_spawn_chunk() -> void:
	var scx := int(floorf(float(WorldGen.SPAWN_X) / 16.0))
	var scz := int(floorf(float(WorldGen.SPAWN_Z) / 16.0))
	var c = chunks.get(_key(scx, scz))
	if c == null or c.data.is_empty():
		create_chunk(scx, scz, false)

func spawn_point() -> Vector3:
	_ensure_spawn_chunk()
	var top := surface_top(WorldGen.SPAWN_X, WorldGen.SPAWN_Z)
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
		var has_fluid := false
		for s in c.slabs:
			if s.fluid_instance != null and s.fluid_instance.mesh != null:
				has_fluid = true
		for s in c.slabs:
			var mi = s.mesh_instance
			if mi and mi.mesh:
				var m: ArrayMesh = mi.mesh
				var ab = m.get_aabb()
				aabb = ab if aabb == null else aabb.merge(ab)
				var sidx: PackedInt32Array = s.sidx
				for si in range(sidx.size()):
					if sidx[si] >= 0:
						var arrs = m.surface_get_arrays(sidx[si])
						slot_tot[si] += (arrs[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
				if has_fluid:
					var fab = m.get_aabb()
					faabb = fab if faabb == null else faabb.merge(fab)
					for si in range(sidx.size()):
						if sidx[si] >= 0:
							var farrs = m.surface_get_arrays(sidx[si])
							fslot_tot[si] += (farrs[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			elif has_fluid and s.fluid_instance != null and s.fluid_instance.mesh != null:
				var fm: ArrayMesh = s.fluid_instance.mesh
				var fab = fm.get_aabb()
				faabb = fab if faabb == null else faabb.merge(fab)
				var fsi: PackedInt32Array = s.sidx
				for si in range(fsi.size()):
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
	var flat: PackedByteArray = ChunkIO._slabs_flat(slabs)
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
		cache[si] = ChunkIO._slab_flat(c.data[si])
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
				var fflat: PackedByteArray = ChunkIO._slab_flat(fslab)
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
							var b: int = _data_at_slab(c, si, cell & 255, dviews)
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
								var below_pos: int = (cell & 255) - 256 if ry > 0 else (cell & 255) | (15 << 8)
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
	c = ChunkScript.new()
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
			oc.queue_free()
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
