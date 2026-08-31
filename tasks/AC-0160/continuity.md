# AC-0160 — spawn-drain defect — continuity

## 00 — 2026-09-14 — builder (second, focused run) notes

### Defect (as filed)
`spawn3x3_ms` measured **14612 ms** (gate target ≤ ~2000). Worker handoffs
serialized 0.3–2.4 s apart; sync fallback builds ran on the main thread for
270–1235 ms each. The spawn 3×3 (and the whole startup window) was paced by
main-thread work instead of the 6-thread pool.

### Root causes (measured, with evidence)
1. **Shared-pool priority starvation.** `threadgen_pool` and `threadmesh_pool`
   are the SAME 6-thread `WorkerThreadPool`. Godot caps LOW-priority tasks at
   `CLAMP(threads*0.5, 1, …)` = 3 concurrent. The old mix ran data-gen at
   default (low) priority 6-wide and builds mixed in → gen saturated the 3
   low-prio slots (6-wide gen is slower per task than 3-wide on this machine —
   allocator/bandwidth bound), builds starved to ~2/s → 13–14 s 3×3.
2. **Drain sync fallbacks.** `_mesh_dispatch` fell back to a MAIN-thread
   `build_mesh` (270–1235 ms) whenever a worker slot or a neighbor was
   missing — every cap drop and missing-neighbor gate pass re-blocked the
   main thread and paced the whole drain.
3. **(0,0) sync build.** The (0,0) spawn-chunk was built synchronously
   (650 ms mesh + ~600 ms face-cache refresh = 1.27 s main-thread block)
   before the worker wave, freezing the drain and idling the pool.
4. **Recenter slice racing the spawn window.** The 8.2k-entry queue rebuild
   (WANT walk + 8661 stubs + merge, ~5 s of main-thread work) ran against the
   burst and the spawn handoffs, starving them.

### Fix (all in `godot/world/world.gd` unless noted)
- **Burst.** `recenter()` dispatches the whole 5×5 data set (24 chunks, taxi-
  ordered) as ONE high-priority 3-wide pool group task; (0,0) keeps its sync
  GEN (data only — the contract); a per-element slot array
  (`_startup_gen_slots`, worker i writes only slots[i]) + `_startup_gen_apply`
  (drain top, unlimited pace) land the data as it completes. Measured 3-wide
  solo wms ~140–260 ms → 24 chunks in ~1.35 s.
  - Godot 4.7.1 quirk found by measurement: a **LOW-priority GROUP task runs
    its elements strictly serially on ONE thread** (24 × 120 ms = 2.9 s) even
    with `tasks_needed=3`; the same group at high priority runs 3-wide
    (~1.35 s). The burst must stay high priority.
- **Burst recenter-race guard.** The group task ids are tracked
  (`_startup_gen_group_tids`); a recenter whose burst is STILL in flight does
  NOT reset the elems/slots arrays (the in-flight workers index them — a reset
  crashes the worker, "Invalid assignment of index '22'", and could write
  chunk A's terrain into chunk B's slot; measured in the boundary gate), and
  sets `pending_n = 0` (the in-flight burst lands data on its own chunks; the
  data pass covers the new forward edge).
- **Drain hold.** `_drain_build_queue` applies burst slots, then holds ALL
  startup builds until `_startup_gen_pending_n == 0` (the 5×5 fully applied).
  This guarantees the 9 spawn dispatches go out in ONE frame (TM cap raised 6
  → 9 for startup only) and keeps the high-priority FIFO free of TM tasks
  while the burst group runs.
- **One-shot spawn fast path (`_spawn_fast`).** The aggressive parts — data
  pass off + recenter-slice pause — gate on `_spawn_fast`, a one-shot flag
  cleared on the first frame the spawn 3×3 is built. Keying them on
  `_startup_pending()` (3×3 around center not built) was a regression: that
  flag is true for the ENTIRE walking session (every recenter's forward 3×3
  is unbuilt), which permanently disabled the data pass + queue rebuild and
  emptied the world ahead of the player (boundary: built_final=0,
  resident_final=0, 35 s drain stall, 2 dead burst workers stuck the hold).
- **No sync fallback on the drain path.** Every drain dispatch requires all 8
  neighbors with data (all bands, no startup conditional); a cap drop or
  missing neighbor DEFERS (entry kept, `_build_unit` returns deferred → drain
  breaks, never syncs). Only the (0,0) empty-data sync GEN remains (in
  recenter, data only).
- **Slice pause.** `_recenter_slice` returns early while `_spawn_fast` (the
  spawn window) — the burst runs at solo wms and the 9 spawn handoffs run on
  a free main thread. The queue swap then lands a couple of seconds after the
  3×3. (Keyed on `_startup_pending()` this broke walking — see above.)
- **Bandmap arm (`godot/scenes/main.gd`).** After the 3×3 wait, the arm waits
  for the recenter queue swap (`queue_size > 4000`, capped 900 frames) before
  the 1500-frame trickle sample, so the q trend measures the real ~8.2k-entry
  queue (down from 8244) instead of a 16 → 8244 recenter artifact mid-sample.
  The sample list stays `[[0,0],[4,0],[5,0],[8,0],[9,0],[10,0]]`, full 1500
  frames, no early break.
- **Caps.** `threadgen_max = mini(nproc, 6)` then `mini(…, 4)` (final 4 here,
  `AWECRAFT_THREADGEN_N` override); `threadmesh_max = maxi(1, mini(nproc, 6))`
  (= 6, `AWECRAFT_THREADMESH_N` override). TM tasks are ALWAYS high priority;
  TG data tasks are LOW priority always (the TM is high, so it can no longer
  be starved — the original starvation was all-default-priority; and high
  data during walking would fight the forward mesh builds). The spawn 5×5
  data is owned by the high-priority burst group, not the TG path.

### Gate evidence (`.scratch/AC-0152-gates/`, `.scratch/AC-0160-gates/`)
- G0 → `g0-final2.log`: exit 0, zero script errors (re-verified after probe
  removal).
- bandmap → `bandmap-final21.log` (final state, post boundary-fix re-verify;
  final6…20 = iteration trail):
  - `tick_set_band0=41`, `circle50=7845`, `stream_set_home=8253`,
    band_counts 41/104/7700/408 (stable across all runs).
  - `b0_unbuilt=[]`, built b0=41, zero B0LOST.
  - trickle q0=8244 → qN=8165, **monotone decreasing** (post-swap sample),
    built b0=41/b1=38/b2=7 during the sample (drain alive; front advancing).
  - band2 sample: `[9,0]` mesh_built=true (4133 quads) every run; `[10,0]`
    built in final21 (2462 quads) but not in final19/20 — the E2 front is on
    the edge of reaching taxi 10 inside the sample (variance, see below).
  - 1 SCRIPT ERROR = the known AC-0137-class `threadgen_handoff`
    Nil→PackedByteArray transient (3–17/run noise; not chased).
  - **spawn3x3_ms = 3643 (final21; 3796 final20; 3962 final19) — the machine
    floor, not the ≤ 2000 gate.** Breakdown (engine ms, final19/20): recenter setup
    ~0.1 → 5×5 burst 1.35 (24 gens, 3-wide, wms 141–258) → 9 dispatches in
    one frame ~0.01 → 9 TM builds 6-wide 0.92 (330–920 ms each) → (0,0)
    handoff face-cache refresh (AC-0134 `_eff_landed` →
    `_compute_face_blk` region cascade) 1.32 → remaining handoffs + frame
    granularity ~0.5. Every component is at its measured per-chunk floor
    (burst: 3-wide beats 6-wide here, 1.35 vs 1.48 s; builds: 6-wide is the
    max; cascade: AC-0134 lighting machinery, fenced; boot: engine). The
    task's 2.0 s model assumed ~0.5 s of gen for 25 chunks (measured
    1.35–1.48 s on this machine) and did not include the ~1.3 s spawn-region
    face-cache refresh. **Reported as a design conflict, per fence.**
- genhash ×2 → `genhash-final1.log` / `genhash-final2.log`: 25 GENHASH lines
  each, byte-identical to `genhash1.log` except (a) the final GENMS line and
  (b) the pool banner (baseline `TG pool=6 / TM pool=2` → now `TG pool=4 /
  TM pool=6` — the AC-0160 cap change, expected). World data unchanged.
- SMOKE battery `player;interact;light;fluids` → `smoke-final2.log` (PASS):
  - player: after_fly_y=136.78, horizontal_moved=2.82 (exact-match gate).
  - interact: place_ok=true, after_place_cell=2, breakable_id=2 (exact).
  - light: cave_eff=10, surface_eff=15, torch_level=14 (exact).
  - fluids: sea_surface 2756/2756, sea_backed 914/914, sea_stable=true,
    water_on_lava=25, sideways_lava=9 (exact interaction counts). The sea
    counters drifted UP from the checkpoint baseline (2723/881) and the
    AC-0152 continuity (2730/888) — the faster drain streams more sea in
    before the fluids arm samples; stability + the exact 25/9 are the gate.
    Recorded as a deviation (below). 3 SCRIPT ERRORs = known AC-0137 class.
- boundary one-shot → `.scratch/AC-0160-gates/boundary-one-shot.log` (PASS,
  20 crossings): **NEW p95_ms = 53** (p50=7, max=1550) vs the old
  `boundary-final.log` reference p95_ms=288 (X1-era reference ~1.32 s).
  built_final=50, resident_final=101, loads=220, unloads=208, marker_ok=true,
  remesh_ok=true, fwd wall resolves 5–9 ms per crossing. 2 SCRIPT ERRORs =
  known AC-0137 class; **zero** burst-worker crashes (the recenter-race guard
  holds — see fix section).
- render → `.scratch/AC-0160-gates/bands.png` (R=10 top, 1280×720, KEPT,
  verified by eye: full-mesh grass/stone/trees/water band + player HUD).
  Note: `AWECRAFT_SNAPSHOT` must be an ABSOLUTE path — Godot resolves
  relative save paths against the project dir (`godot/`), so the relative
  form fails with "Can't save PNG". "SNAPDRAIN not fully drained after 3000
  frames" is the arm's expected 3000-frame cap warning at R=10; the snapshot
  is taken mid-drain regardless.

### Deviations / surprises of record
- The ≤ 2000 ms spawn3x3 gate is unreachable on this machine (measured floor
  ~3.6–4.0 s across final19/20/21: 3962/3796/3643; full breakdown above). All
  other bandmap sub-gates pass.
- The E2 re-light wave consumes ~2/3 of TM capacity in the trickle (each
  fresh landing re-enqueues 1–2 built neighbors; frame-gated, AC-0129/0134
  machinery — fenced). Net front ≈ 1.5–2 builds/s: `[9,0]` (taxi 9) builds
  every run; `[10,0]` (taxi 10) is ON THE EDGE — built in final21, not in
  final19/20. Expect run-to-run variance on that one sample.
- Smoke fluids sea counters drifted UP vs the recorded baselines (2756/914
  now vs 2723/881 checkpoint / 2730/888 AC-0152 continuity): the faster
  drain streams more sea in before the fluids arm samples. sea_stable=true
  and the exact water_on_lava=25 / sideways_lava=9 hold; the stability +
  interaction counts are the gate, the raw counters are the drift.
- The boundary gate IMPROVED, not just recovered: p95 288 → 53 ms
  (TM6 + defer-only drain + one-shot fast path also fix the walking path).
- `threadgen_max` is now 4 (was 6): 6-wide gen is slower per task than
  3–4-wide on this machine (230–450 ms vs 130–170 ms), so capping at 4
  raises net data rate.
