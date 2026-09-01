# AC-0178 — loading-screen-bypass-throttles — builder continuity

## Crash + resume (mandatory record)
The first builder (xhigh subagent) implemented the loading-screen + bypass
scaffolding (world.gd `LOAD_*` consts, `start_loading/stop_loading/
note_render_distance/circle_count/meshed_in_circle/_loading_tick`, main.gd
`start_game` + `_load_test` probe, settings.gd render-distance hook, new
`godot/ui/loading_screen.gd`) but **crashed mid-run** before verifying gates.
State at resume: SMOKE battery green (`.scratch/AC-0178-gates/smoke5.log`,
14:46) but the load-ON arm failed its 30-min cap
(`load_on.log`: ok:false, 2717/7845 meshed, 5531 still queued) and every arm
exited with `Pages in use exist at exit in PagedAllocator:
N16WorkerThreadPool5GroupE` (also visible in the passing smoke5.log tail —
pre-existing, not AC-0178-caused).

## Root cause of the 30-min stall (measured, 240 s timed probe)
`AWECRAFT_TIMING=1` probe (`.scratch/AC-0178-gates/load_probe240.log`):
- The pre-fix drain ran with an UNBOUNDED per-frame budget
  (`budget_us = 1e9` while loading): one drain frame blocked the main thread
  0.4–2.6 s (DRAINMS ms=49..2638). During that block the polls (the handoffs)
  never ran, in-flight counters went stale, and the TM pool — 24 deep at the
  time — drained its queue in ~1.6 s and idled until the next frame's
  dispatch wave. Measured ~80% pool idle.
- The steady-state single drain loop does one build OR one gen per
  iteration. While loading the build-ready set is ALWAYS non-empty (gen
  leads mesh), so the data pass (pass 2) starved: gen froze at ~3.8/s while
  the mesh pool idled at 6.1/s (3020/7845 gen'd in 30 min, tg_inflight
  pinned at the cap).
- Per-dispatch main cost 26–58 ms (nbs dup + `_strips_for` + scoring scans);
  handoff `_eff_landed` face-block refresh ~70 ms avg with a 0.4–1.0 s tail
  on the first landing wave (TMH_PART probe, 681 handoffs).

## Godot 4.7.1 WorkerThreadPool facts (verified from fetched source,
`.scratch/AC-0178-gates/wtp.cpp/.h`, tag 4.7.1-stable)
- `add_task(action, high_priority=false, ...)` — 2nd arg is HIGH_PRIORITY.
  TG enqueues are LOW (default), TM are HIGH. Low-priority cap =
  `CLAMP(threads*0.5, 1, threads-1)` = 3 of 6 threads on this box.
- The 5×5 recenter burst is a GROUP task
  (`add_group_task(_startup_gen_worker, n, 3, true)`). A group's `Group`
  object is freed ONLY by `wait_for_group_task_completion(group)` (a
  waiter). A group whose completion is never consumed leaks → the
  `Pages in use ... N16WorkerThreadPool5GroupE` exit error.
  `is_task_completed()` is the REGULAR-task API; calling it with a group id
  prints `Invalid Task ID` and returns false (the old recenter prune used it
  → the "Invalid Task ID at recenter" error + the prune never ran, so the
  no-new-burst branch stuck for the whole session).

## Fixes (all in `godot/world/world.gd` unless noted; every new path gated on
`loading_active` — steady state is byte-for-byte the legacy throttles)
1. **Two-phase loading drain** (replaces the single loop while loading):
   phase 1 dispatches builds until the TM depth (`LOAD_TM_CAP=64`) or the
   frame budget (`LOAD_DRAIN_BUDGET_MS=300`); phase 2 enqueues gen until the
   TG depth (`LOAD_TG_CAP=24`) or the io cap (`LOAD_POOL_CAP=24` disk reads/
   frame). The frame is bounded so the polls (handoffs) run every frame; the
   DEPTHS keep both pools saturated between frames. The legacy `while
   budget > 0` loop is untouched for steady state.
2. **TM handoff pacing** (`threadmesh_poll`): `LOAD_TM_HANDOFF=6` handoffs/
   frame while loading (each `_eff_landed` is ~70 ms avg, 1 s tail) — the
   uncapped batch blocked the main 1–2.5 s and let the pool queue drain to
   idle. The inflight gate oscillates at the handoff rate so the pool queue
   stays ~LOAD_TM_CAP − lag − running (deep; workers never starve). Steady
   state: cap 64 ≫ steady inflight (≤9) → unchanged.
3. **Group-consumption fix** (kills the exit leak + the "Invalid Task ID"):
   recenter prune now uses `is_group_task_completed` + consumes completed
   groups via `wait_for_group_task_completion` (frees the Group);
   `_exit_tree` consumes any still-listed burst groups after the existing
   1000 ms in-flight wait (bounded: a still-running burst finishes its
   remaining elements first, ≤~1.3 s worst case).
4. **TG null-result guard** (kills the AC-0137-class
   `Cannot convert argument 2 from Nil to PackedByteArray` SCRIPT ERROR, 4×
   in the pre-fix 30-min log): `_threadgen_worker` spins (≤2000 × 1 ms) for
   the slot set a couple of statements after `add_task`; `threadgen_poll`
   re-enqueues a completed task whose result is null/empty instead of
   handing off null.
5. **Caps** (`start_loading`/`stop_loading`): TG 4→`LOAD_TG_CAP=24`,
   TM 6→`LOAD_TM_CAP=64` (restored on `stop_loading` from
   `_tg_max_norm/_tm_max_norm` saved in `_ready`); flush/tex remesh caps
   `LOAD_FLUSH_MAX_PER_FRAME=6` (was 16: each dispatch is ~45 ms of main
   strip work — 16/frame = 0.7 s of one frame); save drain
   `LOAD_SAVE_PER_FRAME=16`.
6. **main.gd**: `_load_test` RESULT gains `gen_per_s` / `mesh_per_s`;
   in-arm cap 30 → 45 min; the probe break predicate now equals the
   `_loading_tick` predicate (circle meshed AND both pools drained).
7. **`_exit_tree` poll drain** (replaces the 1000 ms is_task_completed
   wait): bounded 20 s `threadgen_poll + threadmesh_poll + io_poll` loop
   until all in-flight lists are empty — hands off queued tasks on the
   live node before the free (kills the post-free Callable segfault, see
   the A/B section).

## A/B results (measured, same disk state — disk 0 both arms)
- **ON (bypass)** `load_on3.log`: ok:true, 7845/7845, **wall 27.6 min**,
  gen 8253, gen/s 5.0, disk 0, spawn3x3 3.3 s, exit CLEAN (0 "Pages in use",
  0 SCRIPT ERROR, 0 Invalid Task/Group ID). Churn (handoffs/columns) 1.3x.
- **OFF (spread)** `load_off.log`: **ok:false at the 45-min probe cap** —
  7061/7845 meshed (90%), queue 1191, wall ≥45 min, gen/s 3.0, disk 0,
  exit CLEAN.
- Ratio: ON completes in 27.6 min what OFF could not finish in 45 min
  (≥1.6x, ON < OFF decisively).
- **REGRESSION FOUND + REVERTED:** a "score-once per frame" drain variant
  (collect + sort the candidate set once, dispatch in snapshot order) cut
  the pool scans but raised the full-load re-mesh churn 1.3x → 1.94x
  (15,270 handoffs / 7845 columns; spawn-ring chunks remeshed up to 6×) —
  the adaptive per-iteration re-pick keeps the frontier compact so the E2
  light-convergence wave doesn't re-mesh. Net wall 27.6 → ~32 min. The
  shipped drain re-picks every iteration (both phases).
- **EXIT SEGFAULT FOUND + FIXED:** the old `_exit_tree` 1000 ms wait (a)
  checked TM task ids against the THREADGEN pool (wrong pool → "Invalid
  Task ID" at every exit + the cap always consumed) and (b) only waited,
  never drained the pool queue. At the loading depths (64 TM) a 45-min-cap
  exit with 58 TM in flight left QUEUED tasks that started after the World
  node freed → worker's bound Callable hit the dangling ObjectID →
  segfault at shutdown (measured: EXIT=139, `load_on_final.log` — that run
  still printed RESULT ok:true 7845/7845 before the crash). Fix:
  `_exit_tree` now runs a bounded (20 s) POLL DRAIN — `threadgen_poll +
  threadmesh_poll + io_poll` until all four in-flight lists are empty —
  handing every task off on the live node and emptying the pool queue
  before the free; `_shutting_down` flag makes a TG null-result retry drop
  (not re-enqueue) at shutdown.

## Known deviation for the coordinator (boundary r4 p95 73–89 + perf re-run)
The group-consumption fix CHANGES recenter-burst behavior after completion:
completed burst groups are now pruned (previously they leaked and stuck the
no-new-burst branch forever), so a LATER recenter (e.g. render-distance
change, or a recenter to the same spot after the first burst completed) can
re-burst a few new 5×5 elements that the old (leaked, unpruned) state would
have skipped. Steady-state drain/flush/throttle paths are otherwise
byte-identical (every AC-0178 branch is `loading_active`-gated; in
battery/chunkio/save/continue arms `loading_active` is always false — those
flows never run `start_game`/`start_loading`).

## Strips stay on the main thread (decision)
`_side_eff_strip/_side_blk_strip/_corner_eff_strip` read live main-thread
state (`nc.last_eff["arr"]`, `_face_blk` / `_face_blk_inflight` recursive
AC-0134 face pulls) — moving them to workers risks the byte-identity
contract (genhash/MESHRECS) and is out of scope for AC-0178. The feeder
dynamics fix (above) delivers the saturation without touching the strip
pipeline. FOLLOW-UP CANDIDATE (noted, not done): moving the
`apply_accs`/`_assemble_slab` ArrayMesh construction into the
`_threadmesh_worker` (pure-CPU; instances + add_child stay on main) — in
headless `apply_accs` measures ~1 ms so the win is GPU-build-specific.

## Gates (all run from repo root, ONE godot at a time,
`HOME=/tmp/dsh_home`, logs in `.scratch/AC-0178-gates/`)
- [ ] G0 ×2 (`--quit`) — 0 errors
- [ ] load ON (`AWECRAFT_LOGIC=load`) — ok:true, R=50, wall, disk/gen/
      meshed consistent, exit CLEAN (no `Pages in use`, no SCRIPT ERROR)
- [ ] load OFF (`AWECRAFT_LOADBYPASS=0`) — spread baseline wall; ON < OFF;
      ratio + gen/s reported
- [ ] SMOKE battery `AWECRAFT_BATTERY=player;interact;light;fluids;genhash`
      — exact standing values (see results.html)
- [ ] genhash standalone — 25/25 byte-identical to
      `.scratch/AC-0091-gates/genhash_new.txt`
- [ ] chunkio / save / continue — ok:true unchanged
- [ ] RENDER (`xvfb-run -a`, `--rendering-method gl_compatibility`,
      `AWECRAFT_RADIUS=1`, `timeout -k 15 480`, retry once on GL hang) —
      PNG under `tasks/AC-0178/`

## Files changed
- `godot/world/world.gd` — the fixes above (LOAD_* consts, two-phase drain,
  handoff pacing, group consumption, TG guard, caps)
- `godot/scenes/main.gd` — `start_game` hook, `logic == "load"` dispatch,
  `_load_test` probe (+`gen_per_s`/`mesh_per_s`, 45-min cap)
- `godot/autoload/settings.gd` — `apply_render_distance` captures prev +
  calls `world.note_render_distance(prev)`
- `godot/ui/loading_screen.gd` (+ `.uid`) — NEW: code-built CanvasLayer
  loading screen (layer 90, title, ProgressBar, stats label
  `"%d%% — %d / %d cols (disk %d · gen %d)"`), headless-safe
- `tasks/AC-0178/results.html`, `tasks/AC-0178/continuity.md` — deliverables
