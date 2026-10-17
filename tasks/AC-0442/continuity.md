## RUN - Sat Oct 17 05:44:59 EDT 2026 - AC-0442

- 05:49 root cause established: _low_handoff stale-tier branch (world.gd 2949-2960) caches res["v"] guarded only by "empty"; the worker's pre-start early-out shape {"skipped": true} (world.gd:7302) has no v/empty -> the error. Coordinator's r16 log: low_skip_stale_n=1, one error, backtrace _low_poll->threadmesh_handoff->_low_handoff:2952 (fly50 phase, 97 recenters). SATDIAG adjacency = 2s periodic reporter, not causal.
- plan.html written (tasks/AC-0442/plan.html).
- pre-fix G0: rc=0, 0 script / 0 shader (g0_prefix.log).
- Temporary arm ac0442repro added to harness.gd (run() branch + _ac0442_repro_test + _ac0442_dummy_task) - REMOVED IN THIS TASK (pristine).
- Repro attempts 1-3: knob flip 350ms period (0 skips - pool idles, queue ~1 task), knob flip 15ms (0 - frames slow under re-pend storm), recenter oscillation (0 - one 1.7s sweep per flip, pool backlog drains between flips). WorkerThreadPool thread_count/set_thread_count NOT exposed to GDScript in this build (probe).
- Attempt 4: arm bug (thread_count read) -> arm aborted, process idled to timeout. Fixed arm.
- **REPRODUCED AT WILL (attempts 5-6, dummy-flood construction: 40x100ms HIGH-priority dummies on the shared pool + low_start 6<->15 flips every ~15ms): 28 SCRIPT ERRORs + skip_delta=28 = drop_delta=28, rc=0, census FAIL - identical error, identical backtrace, BOTH runs. The arm's own RESULT says ok:true - the census is the gate (the ticket's process finding confirmed).**
- fix applied to godot/world/world.gd _low_handoff stale-tier branch: cache only when `not res.get("empty") and res.has("v")` (a skipped record is dropped cleanly, slab stays pending -> lane re-picks; identical to the non-stale skipped path).
- **post-fix A/B via the construction: G0 rc=0 0/0; repro arm constructed=true skip_delta=29 drop_delta=29 with ZERO script errors (census ok, rc=0). Pre-fix same construction: 28/28 errors twice. Fix proven.**
- temporary arm REMOVED from harness.gd (0 ac0442 refs left) - pristine.
- next: final G0 on final tree, extended r16 (3 runs), SMOKE, ladder, boundary r4, genhash (in smoke).

- Extended r16 (3 full runs, post-fix, final tree): 3/3 rc=0, census ok, 0 script / 0 shader each, ok:true, far_holes 0/0 both bands, wave/inr ok, low drop/kept/handoff 107/43/45177, 101/37/44597, 106/49/45063 (coordinator's pre-fix neighbourhood). ~20.5 min of the exact workload class that fired the error: zero errors.
- SMOKE battery (player;interact;light;fluids;genhash): rc=0, 0/0, all 5 modes ok; genhash 25/25 BYTE-IDENTICAL vs HEAVY-r22 reference.
- Ladder: ok:true (band A 20/20, B 144/144, C 90/90, tier_mismatch 0, boundary_flip_ok, 90 flips). Boundary r4: ok:true, frame p95 36 ms in band, footprint missing 0.
- Temporary arm removed from harness.gd BEFORE the extended/gate runs (gates verified the final tree); harness.gd git-diff clean (back to HEAD).
- RESULTS PAGE WRITTEN: tasks/AC-0442/AC-0442-results.html (self-contained: root cause, record + why key missing, repro attempts table 1-6, fix diff, A/B table, extended-run census, LOD-unchanged table, gates with rc, deviations, harvest candidates). Captures copied to tasks/AC-0442/captures/ (13 files, 972K).
- DONE (light gates only, per ticket). HEAVY (shaderforce/meshprobe/halo/lightstate/farab/r24/build+serve) + closeout + commit = coordinator. No commits made by me.
