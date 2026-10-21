# AC-0466 — planet traversal arm (continuity)

## RUN — 2026-10-21 — AC-0466 (medium builder, first run)
- Plan: tasks/AC-0466/plan.html (measurement ticket — one arm `planetwalk`, no game behaviour change).
- Status: started.

## LANDED — AC-0466 (code in place, gates pending)
- godot/scenes/harness.gd: dispatch branch `planetwalk` after the faceedit branch (standalone, BATTSKIP) + four functions at EOF: `_planetwalk_test`, `_planetwalk_crossing`, `_planetwalk_chunk_under`, `_planetwalk_lift`, `_planetwalk_fail`. Two edge seams (+x 4/5 pair, -z 10/11 pair), faceedit positioning, SphereMath-derived expected to_face, 8 m position-set walk, bounded 1200-frame settles with the crossface r23 recenter nudge, existing predicates only (first_opaque_mesh, has_all_slab_bodies, surface_top_key, player_anchor, chunk_key_face). Negctrl env: `AWECRAFT_PWN_SKIP_WAIT=1`.
- tasks/harness_data.yaml: `planetwalk` row added (after faceedit); harness_doc.py --render + --check clean.
- G0 first run: 3 script errors — one `:=` inference failure on `has_all_slab_bodies()` through a Node3D var; fixed with explicit bool types. G0 re-run: rc=0, SCRIPT=0/SHADER=0.
- Resume point: full gate set `g0,genhash,planetwalk` (gate_run.py, background), then the negctrl run (`--env AWECRAFT_PWN_SKIP_WAIT=1`), then harness_doc --check, results page.

## GATES — AC-0466 (all green)
- Official set (planetwalk-r9.log): g0 rc=0 SCRIPT=0/SHADER=0 (3 s); genhash rc=0, 25 GENHASH lines byte-identical pre/post arm code (r1 vs r2) AND matching the latest tree baseline .scratch/AC-0465-gates/genhash-r3.log (3.5 s); planetwalk rc=0 ok=true (10.9 s, arm ms 7348) — 4→5 (3 steps, 616 ms, dest 5:63:63, aabb_delta 6.48 m) and 10→11 (3 steps, 374 ms, dest 11:63:63, aabb_delta 5.78 m), both destinations mesh_built + body_present true; cross_resident true at the crossing frame in both modes (no streaming gap on this tree).
- Negative control (planetwalk-r8.log): negctrl.ran=true, saw_unbuilt=true, ok=true — saw_unbuilt via the stand-instant snapshots (stand_dest_built=false both seams; the crossing frame is already built because the 64 m pre-stream window beats the walk — deviation 3).
- harness_doc.py --check: in sync (exit 0). Results page: tasks/AC-0466/AC-0466-results.html.
- FINDINGS (deviations 2+3, also in the yaml row notes): (1) has_all_slab_bodies() is structurally false for every fully built chunk on this tree (empty slabs never get bodies; probed home 8/8, face 13/11, 12/12) — the plan's named predicate cannot gate, the gate rides the composed hazard condition (body_present) with the literal reported as body_all; the crossface arm's wait (harness.gd ~34154) is probably stale now — coordinator should run crossface to confirm. (2) The 64 m pre-stream window beats the 8 m/step walk — no streaming gap; the waits bound the AC-0463-class stall, they do no work on a healthy tree.
- No git add/commit; no TASKS.yaml mutation; no new tickets.

## Coordinator triage — the instrument exists and it has teeth (round 27)
- VERIFIED BY MY OWN RUNS, not by the builder's report: `planetwalk` green with two crossings on genuinely different charts — x_seam 4->5 into dest chunk 5:63:63 (frame 614 ms, mesh T, body T, aabb_delta 6.48 m) and z_seam 10->11 into 11:63:63 (frame 371 ms, mesh T, body T, aabb_delta 5.78 m); genhash 25/25 byte-identical; whole set ~17 s.
- THE NEGATIVE CONTROL FIRES, and I checked it myself rather than accepting the claim: with `AWECRAFT_PWN_SKIP_WAIT=1` it reports `negctrl {ran: true, saw_unbuilt: true}`. My first attempt used the wrong env name and read `ran: false` — which is exactly why the coordinator re-runs the control instead of trusting the summary: an instrument that silently does not run its own falsification looks identical to one that passes.
- WHAT IT ALREADY TELLS US ABOUT THE MERGE: the 64 m pre-stream window beats the walk at these two seams, so there is no streaming gap for the walker to fall through — the AC-0463 slices therefore have a working baseline rather than an unknown one. Recorded as a waiver, not a silence: 2 of the 12 chart boundaries are covered, and the twelve-chart lap is owed to the merge slices that need it.
- BUILDER'S DEVIATION 1 IS A REAL FINDING AND IS NOT MINE TO FIX HERE: `has_all_slab_bodies()` is structurally unsatisfiable on this tree because empty slabs never receive a body (probed 8/8 home, 13/11 and 12/12 face), so the gate rides the composed AC-0145 hazard condition and reports the literal as `body_all:false`. The implication — that the `crossface` arm's wait on that predicate may be stale — should be confirmed by running crossface before anyone relies on it.
- STATE: the instrument precedes the merge by design. AC-0463's first slice can now be measured against a known-good baseline.
