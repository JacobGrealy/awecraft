# AC-0077 continuity log (append-only)

## RUN 1 — research/planner (2026-08-26)

### Deliverables
- `tasks/AC-0077/plan.html` — 7 sections, six decisions D1–D6 embedded, exact gates.
- FRESH baselines (this run, current tree = AC-0107 threadmesh + AC-0118 sliced recenter ON, headless, seed 44, pools 3/3):
  - boundary r4: `forward_p95_ms 5216` (max 5228), `trailing_p95_ms 212`, walk_s 19.52, frame p95/max 21/68, `in_radius_built_max 69` (scaffold line said 67 on 08-24), ok/flap 0, marker+remesh ok, `queue_size 95`, loads 220/unloads 209, mem Δ30.4 MB, fluid_tick_p95 12.52. Log: `.scratch/AC-0077/baseline_boundary_r4.log`.
  - perf r4 first-load: build_units 2428 / drain_s 8.32 (≈292 u/s dispatch), build_ms 158 total (≈2.0 ms/chunk main apply), gen_ms 684, max_drain_ms 64.0, total_ms 8319, all_meshed true. Log: `.scratch/AC-0077/baseline_perf_r4.log`.
  - Probe (3×3 cluster around spawn): per-chunk light 17.8 ms median (9 = 160 ms); union box m0 296 ms (1.85× slower than 9 per-chunk, same 184 320 cells), m2 346 ms; byte diff per-chunk vs union-m0 slice = 74/184 320 cells (0.040%), all union-brighter, max Δ6, 0 chunk-brighter; m2 same 74. Worker `build_accs` full 269 ms vs mesh-only (eff given) 252 ms; sync `build_mesh` (light+mesh+collision) 270 ms → collision ≈ ≤2 ms. Logs: `.scratch/AC-0077/probe_light2.log` (+ first run probe_light.log). Probe scene archived: `.scratch/AC-0077/probe_scene.gd` + `.tscn` (temp dir `godot/.scratch_ac0077/` deleted — G6 clean).
- `.scratch/AC-0077/consts.html` — fresh spec_template re-parse (CHUNK 16 :3, HEIGHT 80 :4, SEA 30 :5 + generator constants).

### Key findings / decisions (mirrored in plan.html D1–D6)
- **Union-flood variant REJECTED with measured evidence**: single geometric flood over the union box is 1.85× slower than 9 per-chunk computes AND differs in 74 light cells (sky/cave light leaking across chunk borders) → violates the spec's byte-identity fence ("IDENTICAL per-chunk light values … torch 14 exact"). Implemented design: `Lighting.compute_light_flat_batch(items)` = per-chunk contained floods through the same kernel as `compute_light_flat_chunk` (refactored into `_chunk_light_into`), margin 0, byte-identical by construction. Batch = the recenter WANT set (world.gd:336–353; 9 wall chunks/steady r4 crossing, 81 at load), eff cached per data-signature, sliced ≤2 chunks/drain call inside the 30 ms budget; eff reaches workers via the existing `eff` param (chunk.gd:1136 skip-light) — handoff contract untouched.
- **Staging (P1.4)**: `col_stage_enabled` single flag (env `AWECRAFT_COLSTAGE=0` reverts), `col_immediate` per chunk (±1 Chebyshev + spawn (0,0) always immediate), separate `_col_pending` queue (queue_size/AC-0118 gates untouched), ≤2/frame nearest-first drain with validity checks (chunk present + mesh_built + collision_body==null + collision_enabled + col_dirty + in-radius → else drop; free paths prune), per-build `collision_ms` counters.
- **Expected post (plan D4)**: fwd_p95 5216 → ≈4950–5100 (−2…−5%): worker stage 11.15→11.90 chunks/s (+6.7%) is the lever (light = 17.8 ms = 6.3% of the 269 ms worker task; the 252 ms mesh emit dominates and is OUT of scope — AC-0119/0120 territory). p95 ≤26, max ≤68, built_max ≥69, queue_size 95, 9→1 light per crossing, collision_ms ≈1–2 ms. G4 A/B: 2 runs/side, best-of AND median; no measurable improvement → honest FAIL per spec.
- Ops notes: every godot call `HOME=/tmp/dsh_home` + mkdir in the same call; godot ONE at a time; probe had to run as a real scene (autoload `Data` identifier does not compile in `-s` script mode — `Identifier not found: Data` in lighting.gd:25; AC-0117's probe dodged this by never calling Lighting). GDScript 2 gotcha hit: for-loop-body variables leak to function scope (probe name collisions); `ChunkScript` is a `const preload` in world.gd:3, NOT a class_name (chunk.gd has no class_name).
- Baseline nuance: AC-0079-era "~20 u/s serial data→mesh ring" is stale — on this tree the drain dispatches ≈292 u/s (first load) and the binding constraint is the 3-worker mesh stage (269 ms/task ≈ 11.15 chunks/s), which explains fwd wall ≈ 5.2 s for 36 chunks.

### State / next step
- Run-1 complete: plan.html + this log + fresh baselines + probe evidence. No .gd edits made, no git, no builds, no renders. Temp probe dir deleted; `git status --porcelain` = `?? tasks/AC-0077/plan.html` only.
- Run-2 (builder, `subagent` tool): implement plan.html §2 D1–D3 (world.gd, chunk.gd, lighting.gd, main.gd), save pre-genhash baseline first (G2), gates G1–G6 per §5, keep THIS log appended.

---

## RUN 2 (implementation) — 2026-08-26, RESUMED (this span)

### Files changed (final)
- `godot/world/lighting.gd` — kernel refactored into private static `_chunk_light_into` (verbatim); `compute_light_flat_chunk` calls it (G2-identical); new `compute_light_flat_batch(items, budget_us=0)` — reused ids/sky/blk, fresh eff per item, **18 ms/frame budget enforced INSIDE the compute loop** (first chunk always runs; later chunks only while under budget).
- `godot/world/chunk.gd` — `col_immediate` + `last_collision_build_ms`; `build_mesh`/`apply_accs` collision tail split immediate (free+build+clear) vs deferred (free stale body only, `col_dirty` stays true); `_build_collision()` self-times.
- `godot/world/world.gd` — `_bl_want` snapshot at recenter WANT-phase completion; `_bl_batch_step()` (nearest-first, 18 ms budget, per-data-signature eff cache 128 FIFO, hit = no recompute); eff cache fed by batch + trusted worker handoffs (`eff_trust`), never bulk/`last_eff`; eviction on edit/free (NOT on candidacy — data preserved); P1.4 staging (`col_stage_enabled` env, `_stage_check` after sync build + handoff apply, `_col_pending` dedup queue, `_col_drain_step` ≤2/frame nearest-first validity-checked); **drain-loop pacing fix**: scored data pick skips `_tg_inflight_keys` entries + cursor park conditional on `dp.is_empty()`; batch yields while `_rec_pending`; counters (perf_light_*, perf_collision_*, perf_staged_*).
- `godot/scenes/main.gd` — boundary RESULT: per-crossing light arrays + totals, collision totals, staging, `unbodied_built_final`; perf RESULT: totals.

### Root-cause findings this span (measured, debug-instrumented then removed)
1. **Pre-existing drain pacing bug (starved the batch pass):** the scored data pick re-picked the same gen-in-flight no-data entry every iteration (threadgen dedup no-op still counted `u=1`) → ~1 real enqueue per 5–6 frames → 3–4 chunks/crossing had no data when the next recenter replaced `_bl_want` → they self-computed later. Fix = skip in-flight entries. After fix: 10–12 enqueues/crossing, pass completes in every steady-state crossing, steady-state self-computes = 0.
2. **Chunk light is 17–34 ms, not D1's 6 ms.** G2-identical kernel; heavy = glow/lava chunks. ⇒ ~150–300 ms NEW main-thread light per crossing ⇒ ~9 boosted frames/crossing ⇒ ~10% of walk frames ≥26 ms ⇒ **walk-frame p95 ≤26 is mathematically unreachable with on-main contained light** (p95 33 / max 71–79 measured, consistent across 6 post runs). D4's own "≤18 ms/frame" parenthetical was the binding budget (2-chunk slices measured 34–68 ms). Follow-up task needed for the sub-gate (off-main batch light / faster kernel).
3. Frame profiler (temp) attributed slow frames to the batch component (avg 24 ms on ≥26 ms frames); recenter/fluid overlap negligible.

### Gate results (final code)
- G1 PASS — zero script errors in every run; player 2.82/on_floor (worker eff path live).
- G2 PASS — 150/150 GENHASH identical vs pre (re-run final code; only GENMS differs).
- G3 PASS — battery exact re-run on final code (sea 2730/2730+1406/1406, torch 14, 2.82, place/drop ok, water_on_lava 25, sideways_lava 9, ok:true).
- G4 **FAIL as written (D4 clause)** — fwd p95 PASS: post 4832/4291 vs pre 5216/5148 (best-of 4291<5148, median 4562<5182); light 9→(0 self + 1 batch)/crossing steady (warmup crossings 3–8: 2–6 self, worker-side, recenter-restart churn); **walk-frame sub-gate FAIL: p95 33>26, max 71–72>68** (root cause #2); trailing 34/44≤212 ✓; ok/flap/marker/remesh ✓; built_max 81≥69 ✓ final 81 ✓; **queue_size 93 (pre 95)** = pacing fix consumed 2 extra far data_only entries (queue shrank — documented deviation); collision 307–314 ms / 228–233 builds / max 3 ms ✓; staged_drained 233 / dropped 0 / pending 0 / unbodied 0 ✓.
- G5 PASS — (a) 2.82 exact ×4 player; (b) unbodied 0/pending 0/dropped 0 in every boundary run; (c) save run ok:true all sub-checks, spawn/continue clean; (d) flake boundary ×2 + player ×4 all ok:true/no hang (logs `.scratch/AC-0077/flake_boundary_r2.log`, `flake_r2.log`); (e) COLSTAGE=0 → staged_drained 0 (immediate-everywhere = today), ok true.
- G6 PASS — `git status --short` = exactly the 4 .gd M + `?? tasks/AC-0077/AC-0077-results.html` (+ this log M).

### State / next step
Run-2 COMPLETE: all code + gates done, results in `tasks/AC-0077/AC-0077-results.html`. Coordinator: commit (4 .gd + task dir), no builds required by spec (no web/windows impact — logic layer only), report = fwd PASS / walk sub-gate honest FAIL-as-delivered with root cause; recommend follow-up task (off-main batch light) to close the AC-0034 walk-frame residual. Debug instrumentation fully removed (grep BLDBG/_bp_ clean). Scratch: `.scratch/AC-0077/` (bldebug2–5, blprof1–2 = instrumentation traces).
