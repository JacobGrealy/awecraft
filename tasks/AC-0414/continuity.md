# AC-0414 — continuity (append-only journal)

## RUN - Sat Oct 10 04:16:17 EDT 2026 - AC-0414

- Read in order: TASKS.yaml AC-0414 notes (the spec + plan), spec.html, CONTINUITY.md top
  checkpoint, ARCHITECTURE.md, world/gdext/scenes AGENTS.md, HARNESS.md, OPS.md, AC-0313
  results (the simband baseline: 2089 ms user config / 959 ms harness default), AC-0384
  results (the 794 s / ~13 min single-threaded bake wall on this box), AC-0410 notes.
- Key facts established before planning:
  - godot slot free (pgrep clean). 6 cores (nproc 6); WorkerThreadPool = 6 threads,
    LOW-priority add_task runs on ONE thread (world.gd:6216-6222 measured precedent) —
    the ticket's pool-priority claim is verified by the project's own measurement of the
    4.7.1 pool behaviour.
  - Release gate = main.gd `_await_sim_band` (FENCED): the sim taxi diamond
    (taxi <= band0_r, `world._is_real_col`) meshed, 3000 physics-frame cap = 50 s wall
    (default 60 Hz physics). Loading window = `loading_active` (start_loading), closed by
    `world._loading_tick` when the same diamond is meshed. So the hold must ride the
    world-side diamond dispatch (loading-window phase 1 of the drain, world.gd ~8854-8909,
    which only ever dispatches real-band columns while loading) and must release its own
    bounded budget < 50 s so the screen and the player release stay consistent.
  - The loading window's phase 1 builds ONLY the real band (the diamond); the halo is
    trickle-paced after the window closes (streaming := not loading_active). Holding the
    diamond therefore idles the TM lane for the bake's duration — the load wall becomes
    bake_wall + diamond build (the trade the ticket names).
  - Satellite arm (harness.gd _satellite_test) waits for LOADED/FAILED (90000 frames),
    reports sb.bake_stats opaquely (no sub-field assertions), and with
    AWECRAFT_SATELLITE_REBAKE=1 force-rebakes and pixel-compares vs shipped seed-44 PNGs
    (max_diff <= 1, diff <= 1%) — that is the bit-identity gate for the new MT path.
  - `generate_far` is a `const` C++ method (gdext/src/gen.cpp:4693), already run from
    multiple pool workers by the threadgen lane (LOAD_TG_CAP=8) — sharding is safe, no new
    C++.
  - The snapshot/planet-preset flow (main.gd _run_game) never calls start_loading —
    loading_active is false in render/arm runs, so the hold cannot fire there; the preset
    waits for the body LOADED (6000 process frames) before snapping.
  - Harness env preload pattern (world.gd ~3852-3893, AWECRAFT_RAMPS class); settings
    pattern (settings.gd DEFAULTS + _clamp sanitize_bool; menu.gd checkbox row);
    uniform-push seam (world.gd _ac0401_push, parent.sky_mat; shader defaults = pre-change
    behaviour, mix(...,0.0) = 1.0).
- PLAN written to tasks/AC-0414/plan.html. Deviations recorded there and (later) in the
  results page.

## RUN (final) - AC-0414 closeout
  - IMPLEMENTATION COMPLETE on the FINAL design: 98 streamed shards x 2,002 records at the
    core-count width + 12 face tasks, yield-aware priorities, main-thread merge/assemble.
    All ticket clauses landed: (1) bake-before-load with a live progress line, (2) the MT
    bake, (3) the progress line (seed, shard k/98, record k/196196, face k/12), (4) the
    sat_preload switch (default ON, env-overridable AWECRAFT_SATPRELOAD, OFF = today),
    (5) clause 2 (the limb term gated on body LOADED).
  - MEASURED (this box, ~40x slower per record than desktop-class target): OFF 798.2 s;
    FINAL 98-shard+yield bake wall 169.3 s (gen 145.0 / face 23.5); pre-yield 14-shard
    194.9 s; **4.1-4.7x speedup**. Hold engages at window open, LOUD line at the 42 s
    budget, player release 48.4 s (budget + at most one shard slice, by construction; the
    pre-yield design measured 109.5 s), planet LOADED 169.4 s after boot.
  - GATES (all green, this code state): G0 final 0/0 rc 0 (after BOTH temp arms removed);
    SMOKE battery player;interact;light;fluids;genhash ok, 0/0, GENHASH 40c8e34e...
    identical; PROBE satboot ON (48.4 s release) / OFF (1.29 s, clean abort); REBAKE ON on
    the FINAL build **rebuild_vs_shipped identical=true, diff_px=0, max_abs_diff=0
    (589,824 samples)**; boundary r4 (the builder's ONE self-check) ok,
    col_deferred_in_footprint=0; renders R1-R5 + the clause-2 mid-bake A/B all rc 0.
  - FINDINGS (recorded, see results §6): (a) the mid-bake EXIT UAF - a worker holds the
    node's script instance in its call stack; process exit frees it mid-slice (segfault).
    Predates AC-0414 (the old single-task bake had the same race) but now more reachable;
    mitigated via a file-scope `static var _mt_exit_aborted` set in `_exit_tree()` and read
    first by every worker abort check (shrinks the window to the epilogue; a full close
    needs the workers detached from the node - their own ticket). (b) the MT failure path
    never set `bake_done` (a wait on it ran its full frame cap); `_fail()` now sets it, so
    a probe abort wind-down finishes in 17-24 frames. (c) one REBAKE render-probe overlap
    (a one-godot-at-a-time miss) - both runs independently passed their gates, no observed
    .godot corruption, not sanctioned.
  - TEMP ARMS BOTH REMOVED at closeout (the satboot probe + the satmid clause-2 probe),
    G0 re-verified 0/0 after the removal. The standing `satellite` arm is untouched.
  - The clause-2 mid-bake evidence is renders/r5c_midbake.png (body WORK at the snapshot -
    the standing planet preset can never capture this because it waits for LOADED first);
    it shows empty sky (no body, no limb ring, no pale disc). R1 (LOADED) shows the full
    planet + limb ring; R4 (SAT_BODY=0) isolates the "pale disc" = the limb halo around the
    body-silhouette disc (the painter fix is deliberately a separate clause).
  - RESULTS page tasks/AC-0414/AC-0414-results.html is complete and self-contained
    (design, measurements, all gates, findings, renders, files). plan.html is done.
  - READY FOR COORDINATOR: heavy gate set (Windows build, shaderforce arm) + commit/push.
    No commits made by this subagent (fences). Nothing further owed on the builder side.
