# AC-0474 continuity — the fill stalls after the inner ball

## RUN — 2026-10-23 23:19 EDT — AC-0474
Builder (HIGH). Plan: tasks/AC-0474/plan.html. Order: instrument the dispatch→land gap
(dispatched/landed/pending/drop-by-reason per frame), name the culprit from counts, fix that one
thing, repair stale voxelcost arm, prove with the same M1 rate measurement + gates
g0,genhash,residency,planetwalk,boundary,light,lightstate,voxelcost.

## RUN — completed (same session, ~01:40 EDT) — AC-0474: DONE
Order followed; deliverables in this folder (deviations D1–D7, results.html). FINDINGS:
1. Star-gate hypothesis REFUTED — the reason table (perf_r24-r3.log `reasons`) has ZERO holds at
   every gate (hs_settle/hs_payload/hs_sky/hs_cap/hs_nodata/hs_nbs/races all 0, lo_cap/lo_noop 0);
   only transient in-flight dedup (hs 198 / lo 14165). Drops 0, inflight 0.
2. The M1 "stall" is a MEASUREMENT ARTIFACT: build_worker_n/mesh_built sees only the high lane
   (its R24 set = the taxi-8 diamond = exactly 145); the far tiers draw via low slabs (land_lo
   16320) and never set mesh_built by design. Per-live-tier fill (built_rep) = 1201/1201 (100%)
   at t100=67.7 s, pending 0 — the world FILLS; rate past the inner ball ~16–20 c/s non-zero.
   The "fix" the counts name = the arm's completion metric (built_rep/required/t90/t100/
   pending_final + reason table + dispatch census). No pipeline change made or owed (world.gd
   edits counter-only; genhash 25/25 proves it).
3. Total that did not add up (RESOLVED): -1388 against perf_build_units — it counts drain
   FRAME-BUDGET ITERATIONS (a build+gen co-dispatch shares one slot and disp=build_units-gen
   attributes it to the gen); the true enqueue census (hs_enq 145 + lo_enq 16320 = 16465) EQUALS
   the landing census (16465) exactly. No leak.
4. voxelcost repaired (D32-prescribed re-point: _face_order → _resident_order + face subset
   int(c.face)>=2): runs clean (rc=0, 0 SCRIPT ERROR), reports per-chunk costs (gen 22.1 ms /
   mesh 7.0 ms / build 29.1 ms). Residual (fenced follow-up): arm-internal ok=false —
   fresh_ensure_not_data_only 0/16 (face-8 edge row now reads the 0.0 sentinel of
   _face_chunk_min_dist → in-window → mesh build; the arm's ~3.1–3.9 km premise is stale).
   Warpcensus ×4 + ac0433probe ×1 _face_order reads remain stale (D5, same re-point owed).
GATES: g0 0-script ✓; genhash 25/25 byte-identical to post-AC-0311-p2 ((0,0) 46c20b07…) ✓;
residency 93/74 STABLE leak-false keys_same ✓ (== M1-era readings); planetwalk 25/26 all
mesh+body ✓; boundary r4 walk p95=39 (band 39–42), crossing_frame p95=38 (band 35–55) ✓;
light 15/0/14/0→9 unchanged (pocket doc values stale since p2 — D6a, re-baseline owed at
closeout); lightstate leaks 0 / wash false (vc_diff 4 vs doc 1–2 tail — watch item D6b);
voxelcost rc=0 + costs reported (gate d met).
Resume (if any follow-up is tasked): the two fenced re-points (_warpcensus_test, _ac0433probe_test)
and the voxelcost gen-path re-baseline are the open threads; nothing else left. Logs:
.scratch/AC-0474-gates/ (perf r1–r3, all gate rev-1 logs, run scripts, summary.json).

## Coordinator triage — the "stall" DID NOT EXIST. My hypothesis was wrong and the instrument was blind (round 69)
- THE REASON TABLE IS EMPTY: every gate reads ZERO holds — hs_settle, hs_payload, hs_sky, hs_cap, hs_nodata, lo_cap, lo_noop, races all 0, drops 0, in-flight 0. So there was nothing blocking, and the star pending-queue hypothesis I recorded as the lead — correctly labelled a code reading rather than a measurement — was simply wrong.
- THE M1 MEASUREMENT WAS AN ARTEFACT OF THE INSTRUMENT, which is the failure mode I have spent this whole session catching in other people's work and then walked into myself: `build_worker_n` / `mesh_built` only observes the HIGH lane, whose R24 set is exactly the taxi-8 diamond (145). The far tiers draw through LOW SLABS which by design never set `mesh_built`, and they landed **16,320**. So the 16,484 "dispatch attempts with 145 completions" was never a stall — it was one counter watching one lane while the other lane did the work. The world fills.
- THE HONEST RATE, now measured on the right instrument: **t90 = 60.5 s, t100 = 67.7 s** at R24, climbing 254 -> 658 -> 981 -> 1201 chunks between 10 s and 70 s, i.e. roughly **16-20 drawable chunks/s** steady. Per-chunk cost from the repaired voxelcost arm: **gen 22.1 ms / mesh 7.0 ms / build 29.1 ms**.
- SO THE TAKEOFF PROBLEM IS REAL BUT IS NOT WHAT I SAID IT WAS: not a stall, not a broken gate, not (primarily) the view order which AC-0399 already fixed. It is that a 1 m grid at R24 needs ~1400 chunks and the pipeline delivers ~18/s, so the world takes about a minute to arrive — and a minute of flying over a half-built world is exactly the experience the user complained about.
- THE FIX WAS TO THE INSTRUMENT, AND THAT IS THE RIGHT OUTCOME: the completion metric is now per-live-tier fill (built_rep/required/t90/t100 plus a pending census), with a per-gate reason table and a true dispatch census. No pipeline change, no cap raised, the light-settling guarantee untouched, and world.gd's edits are counter-only with genhash 25/25 byte-identical. A counter that had watched BOTH lanes would have saved AC-0473 and AC-0474 a round each.
- THE ARITHMETIC GAP IS EXPLAINED TOO: the -1388 discrepancy against `perf_build_units` is that counter counting drain frame-budget iterations where build and gen co-dispatch share one slot; the true census adds exactly (145 + 16,320 = 16,465 landed, 0 dropped, 0 in flight). Nobody was losing work.
- REPAIRED DEBT: voxelcost now runs clean (it read the removed `_face_order`; now `_resident_order` + a face subset) and reports real per-chunk costs, which is what made the cost split measurable at all. Residual fenced items recorded: its internal `fresh_ensure_not_data_only 0/16` premise is stale (the arm assumed a face-8 distance from the old grid), and the warpcensus/ac0433probe re-points remain D32 follow-ups.
- TWO WATCH ITEMS: the light pocket doc values have been stale since AC-0311-p2 (the arm reports 9 where the docs say 14/0/9 — the values themselves are unchanged, the documentation drifted), and lightstate's vc_diff now reads 4 against a documented 1-2, inside the settle tail but worth a look.
- WHAT THIS MEANS FOR THE QUEUE: AC-0473 can be unblocked, because its lever table is now a REAL question rather than a number faked by a bug — R24 needs ~1400 chunks at ~18/s, and the levers shrink that set 3.4x / 6.5x / 17.4x for radius 12/8/4. That is a product decision for the user, not a code decision for me.
