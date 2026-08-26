# AC-0118 continuity log (append-only handoff record)

## RUN 1 (research/planner, xhigh) — 2026-08-25

### Entry 1 — context read, design decided
- Read: spec.html (G1-G6 + fences), CONTINUITY.md 00e, ARCHITECTURE.md, tasks/templates/two-phase.md (7-section schema), world.gd (full: recenter :956-1046, _build_queue_for_center :838-903, drain :668-786, _collect_pool :641, _entry_score :627, dispatches threadgen_poll :430 / threadmesh_poll :486 / _mesh_dispatch :546, _process :196-274), index.html updateWorldStreaming :1295-1326 (gen ring ≤3/frame :1299-1304, mesh ring 8ms cap + 3/frame :1305-1317, unload :1319-1325), main.gd boundary/perf harness (perf :910-915 → _perf_test :4640; boundary :917-925 → _await_boundary_core :4734 + _boundary_test :4753-5076), player.gd _recenter :1079-1086, AC-0076 + AC-0079 results.
- KEY DATA (AC-0079 G3, current code, r=50 RECPROBE): initial recenter total_ms=98.8-100.3 (free 0.0, rebuild 100.3, new_n=10608); walk crossings total_ms=32.6-35.8 (free 0.1, rebuild 25.5-27.7, new_n=204, chunks=10712). → hysteresis walk ≈ total−rebuild−free ≈ 7-8 ms @r50 (must stay <15 ms → keep hysteresis synchronous, see plan §5).
- MECHANISM DECIDED: frame-budgeted SLICED rebuild (web-style count+8ms caps, 5 sequential phases WANT→STUB→MERGE_OLD→MERGE_WANT→MERGE_RING, exact per-cell semantics of today's _build_queue_for_center/stub loops, dx-major order preserved so final band arrays + dict insertion order are byte-identical to today's single-shot rebuild → drain pick order identical). Rejected lazy incremental: a 1-chunk move changes every entry's Manhattan distance → re-bucketing is O(R²) anyway, or it would alter band/cursor semantics (AC-0079 gate risk).
- CRITICAL CORRECTNESS DETAIL: WANT snapshot spans frames; a want chunk can be meshed by the drain before MERGE_WANT → MERGE_WANT must re-check mesh_built and skip (else a meshed chunk gets a "build" entry the drain never consumes → queue_size never 0 → G5 fail). Cannot happen in today's single-shot (no frame elapses) — the re-check is a no-op against today's semantics.
- Slice state vars + constants + _process hook (early-return :199 gains `and not _rec_pending`; `_recenter_slice()` called between threadmesh_poll :272 and _drain_build_queue :273) — full spec in plan.html §5.
- G4 measurement decided: RECPROBE total_ms per recenter call (walk crossings = 20 lines in boundary r50 run) → p95 across crossings; + new RECSLICE line (slice total/max/frame count/queue/new_n) at SWAP. r50 pre-change: initial ≈97-100 ms, walk ≈33-36 ms. r4 baseline: p95 65, irb_max 67, flap 0 (AC-0079/HARNESS :139) — re-measuring now.

### Entry 2 — pre-change baseline probes launched (background job bash-9)
- Script: `.scratch/ac0118_probe_chain.sh` (ONE sequential chain — godot runs one at a time; HOME=/tmp/dsh_home per ops rule; all calls `--path godot` from repo root):
  - P0 G0 headless `--quit` → `.scratch/AC-0118/p0_g0.log`
  - P1 genhash → `.scratch/AC-0118/p1_genhash.log`, lines → `.scratch/AC-0118/genhash_baseline.txt` (25 expected)
  - P2 boundary r4 → `.scratch/AC-0118/p2_boundary_r4.log` (RESULT: p95_ms, in_radius_built_max, flap, ok)
  - P3 perf r50 + RECPROBE → `.scratch/AC-0118/p3_perf_r50.log` (recenter_ms, first_draw_ms, p95_ms, total_ms)
  - P4 boundary r50 + RECPROBE → `.scratch/AC-0118/p4_boundary_r50.log` (21 RECPROBE lines + RESULT)
- Expected wall ~45 min (r50 runs ≈14 + ≈23 min per HARNESS.md).
- NEXT: collect job_output(bash-9) → fill plan.html §7 A/B baseline table + verify pre-change numbers → finalize plan.html → report. Run-2 relaunch reads THIS file first.
- Constraints honored: NO .gd edits (research only), no git, no builds, no renders (perf/scheduling task — G6 render skipped per brief; zero script errors is the hard gate), no python server kills.

### Entry 3 — pre-change baselines COMPLETE (job bash-9, 22:17-22:36 EDT, all rc=0, zero script errors)
Logs: `.scratch/AC-0118/{p0_g0,p1_genhash,p2_boundary_r4,p3_perf_r50,p4_boundary_r50}.log`; genhash baseline (25 lines) → `.scratch/AC-0118/genhash_baseline.txt`.
- **G0/G1**: rc=0, 0 SCRIPT ERROR lines.
- **G2 genhash**: 25 lines → baseline file (post-change must diff empty).
- **G3 battery**: NOT run by the probe chain (Run-1 is research-only; G3 is a Run-2 post-change gate — the battery values are stable knowns from the spec; Run-2 runs it per plan §G3).
- **Fresh r4 (boundary, threading ON default)**: `p95_ms=21` (p50 14, max 68), `in_radius_built_max=68`, built_final 81, flap 0, remesh_ok true, marker_ok true, ok true, forward_p95 5200, trailing_p95 206, burst_p95 5199, walk_s 19.52. **⚠️ GATE RE-ANCHORING:** the spec/registry "r4 p95 65, irb_max 67" are PRE-AC-0107 numbers (AC-0107 threaded mesh+light cut frame p95 62→21 — see CONTINUITY AC-0107 entry). A/B "unchanged" = against 21/68, i.e. post ≤26 / 67-69 / flap 0.
- **Fresh r50 cold start (perf, RECPROBE)**: RECPROBE initial `total_ms=102.6` (rebuild 102.6, free 0.0, new_n 10608, queue 10609); RESULT `recenter_ms=102`, `first_draw_ms=366`, frame `p95_ms=29`/max 78, total_ms 848955 (51005 frames, all_meshed false — normal r50 cap).
- **Fresh r50 walk (boundary, RECPROBE)**: 22 lines = 1 cold start (105.1) + 21 crossings (20 walk + 1 settle re-center, new_n=721). Crossings: **p95 ≈41 ms** (40.8 ceil-index / 41.3 linear; min 34.0, max 43.5, mean 38.0); rebuild 26.7-34.7, free 0.0-0.1, **residual (hysteresis+setup) 7.2-13.3 ms mean 8.9** → post-change call p95 ≈10-11 < 15 ✓ (margin ~4 ms; contingency = slice the hysteresis walk, plan §5.10). RESULT: frame `p95_ms=41`/max 123, irb_max 105 (mid-walk, not a gate), built_final 228, flap 0, remesh_ok/marker_ok/ok true, walk_s 19.6.
- **plan.html FINAL**: all 7 sections complete, spec gate numbering G0-G6, A/B table filled with fresh pre-change numbers, exact commands per gate, re-anchoring note in §G4. Run-2 (subagent tool, medium effort) can implement from §5 verbatim.
- Deviations from the brief: (a) r4 gate re-anchored 65/67 → 21/68 (pre-AC-0107 values stale; documented in plan); (b) genhash baseline file lives in .scratch (ephemeral) — plan §G2 instructs Run-2 to paste both column sets into results.html as durable evidence; (c) G6 has no render gate in the spec (spec G6 = tree clean + results.html) — plan notes no-render decision explicitly.
- Plan.html: `tasks/AC-0118/plan.html`. Baseline table: §7 G4. Design: §5 (5-phase sliced rebuild, MERGE_WANT meshed re-check, _process :199 early-return fix + slice hook between threadmesh_poll :272 and _drain_build_queue :273, _build_queue_for_center :838-903 deleted).
