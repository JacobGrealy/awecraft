# AC-0473 continuity

## RUN — 2026-07-08 — AC-0473 M1 (measurement only)
Stage M1: measure the R24 required set, the achieved fill rate, the per-chunk cost split, the
arithmetic verdict and the lever-shrink factors. No code change. Gates g0,residency,genhash.

MEASURED: gates green first (g0 0/0, genhash 25/25 GENMS 130, residency r4 STABLE home 92/face 74
leak false). Then, script-file runs (logs .scratch/AC-0473-gates/): perf AWECRAFT_RADIUS=24
(cold fill: required 1401, built 145/1401 at the 12,005-frame cap, all_meshed false, avg 0.71 c/s,
burst 14.2 c/s for 10 s then 0.0 c/s for 194 s, 16,484 dispatch attempts vs 145 completions,
build_worker 4/8/9 ms p50/p95/max, drain max 34 ms); residency at R24 (spawn t0 home 1401 + face 0;
seam steady 2429 + 74 = 2503, STABLE, policy readout rr24/b1_eff24/med8/sim4) and at R12 (417) / R8
(217) for the measured lever factors; voxelcost FAILED (stale arm — world._face_order removed,
SCRIPT ERROR harness.gd:39071) — reported as a gap per plan, not fixed.

GATES: g0 0/0 (rc 0); genhash 25/25, GENMS 130, rev1 vs rev2 MD5 sets byte-identical; residency
leak false / STABLE (home 92-93 / face 74 at r4, keys_same, converge_ms ~504-510, converge series
flat, peak 177-197 during crossings) — identical before and after all measurements: the tree is
provably untouched. Measurement logs + scripts: .scratch/AC-0473-gates/{perf_r24-r2,
residency_r24-r2,residency_r12-r1,residency_r8-r1,voxelcost-r2}.log. Results page + deviations:
tasks/AC-0473/. DONE.

## Coordinator triage — M1: THE PREMISE IS REFUTED. The fill does not run slowly, it STOPS (round 68)
- THE NUMBER THAT CHANGES EVERYTHING: the build rate is **14.2 chunks/s for the first 10 seconds, then 0.0 chunks/s for the next 194 seconds** — 145 completions against **16,484 dispatch attempts**. So the pipeline is not rate-limited, it is STALLED: dispatch keeps trying and builds stop landing. A 33-minute fill would have been a throughput problem; a fill that stops dead after 145 chunks is a BUG, and no radius/LOD lever fixes it because the rate is zero.
- THAT MEANS I FILED THIS TICKET WITH THE WRONG FRAMING and the measure-first rule I wrote into it is what caught me. I said "ordering cannot beat a rate limit, so the constraint is throughput". The measurement says ordering and throughput are both fine, and something stops completing builds after the inner ball. The ticket's own §6 fence ("do not optimise in this stage") is the only reason I did not spend a round optimising a pipeline that is not running.
- THE SHAPE OF THE STALL IS DIAGNOSTIC: 145 chunks is EXACTLY the taxi-8 ball (`medium_start_r 8`), the initial burst is real work at 14.2 c/s, and the DATA set does converge (1401/1401 by ~30 s) — so generation is complete and it is the BUILD/LAND half that stops. The builder's one hypothesis is the STAR PENDING-QUEUE DEPTH (a settled-light gate) and correctly flagged it as a code reading, not a measurement.
- THE REQUIRED SET IS KNOWN AND MODEST: 1401 chunks standing at spawn, 2503 at a chart seam. The resident set converges and the arm calls it STABLE at 92-93 home / 74 face — meaning the small set that DOES land is stable and the rest simply never arrives. So residency is not leaking; it is starved.
- THE LEVER TABLE EXISTS AND IS NOT THE ANSWER: radius 24->12/8/4 shrinks the set 3.4x/6.5x/17.4x, handover and LOD would shrink the meshed set 1.5-6.3x — all computed and all irrelevant while the rate is zero. I will NOT take a design question to the user on the back of a number that a bug is faking.
- HONEST GAPS, reported rather than estimated: per-chunk gen/mesh ms could not be measured because the voxelcost arm is STALE (`world._face_order` was removed at AC-0469 G2, so harness.gd:39071 throws SCRIPT ERROR) and perf's gen_ms reads 0 on the R24 path; the star pending-queue depth is unmeasured; and no arm measures an altitude fill rate. The stale voxelcost arm is a real debt that G0 does not catch because that arm is not in the standing set.
- NEXT STEP, and it is a bug hunt not an optimisation: find why builds stop completing after the inner ball — instrument the pending/settled gate the builder named (star pending-queue depth), count dispatch-to-land drop-offs by reason, and fix the gate. THAT is what delivers the takeoff; AC-0473's radius/LOD question goes back to the user only if the stall is fixed and the honest rate is still too low.
