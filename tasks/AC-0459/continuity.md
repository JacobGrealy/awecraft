## RUN — 2026-10-20 20:11 — AC-0459

## STOP — 2026-10-20 20:21 — AC-0459

PLAN-INSUFFICIENT: the plan's measured blast radius (one producer, five parsers) is contradicted by the code — unlisted hardcoded chunk-key producers at main.gd:1704/1827/1873/1908 (and ~40 more in fence-protected harness.gd), and 3 of the 5 listed "parsers" (world.gd:13685, main.gd:1732/1805) are cell-key parsers, not chunk-key parsers. Full findings: tasks/AC-0459/AC-0459-deviations.txt. No code changed, no gates run.
## RUN — 2026-10-20 23:08 EDT — AC-0459
## FINDINGS — 2026-10-20 23:08 — AC-0459 (PLAN-INSUFFICIENT, no code changes)

PLAN-INSUFFICIENT: plan §2/§3 require world.chunk_key / world.chunk_key_face
(world.gd:11406), but AC-0465's refactor was REVERTED from the tree after landing:
fa50122 added it, 3b44f90 reverted all of godot/ (git diff fa50122~1 HEAD -- godot/
is EMPTY; working tree == HEAD == pre-AC-0465), 041cced "AC-0465 closed" carried the
revert, TASKS.yaml still says done. The 44 by-hand world.chunks.get("%d,%d") lookups
(main.gd:1704/1827/1873/1908 + 40 harness.gd) are all still literals.

Reader audit (plan §4.1) COMPLETED on the current tree — the full table is in
AC-0459-deviations.txt (the appended resume-run section): 49 chunk-key sites the flip
would break without the AC-0465 wrappers; 6 CELL-key parsers (world.gd:13721,
main.gd:1732/1805, harness.gd:1754/23287/10782 — do NOT touch); 4 EDIT-key sites
(main.gd:593/635, save.gd:142/145 — do NOT touch); save.gd's 2-part re-keyer branch
goes dead post-flip and the 3-part branch absorbs home keys with a round-trip that
holds; the only harness site parsing a real chunk-key string is _seamcensus:32253.

No code changes, no gates run (nothing landed to prove). Coordinator next step:
re-land AC-0465 (git checkout fa50122 -- godot/; re-verify g0 + genhash 25/25),
fix TASKS.yaml/commits record, re-run AC-0459.

## RUN — 2026-10-20 23:53 EDT — AC-0459 (relaunch after d0874f4 re-land)

## LANDED — 2026-10-20 — AC-0459
- world.gd:11400  _key cache fill flipped "%d,%d" -> "0:%d:%d" (the ONE producer); chunk_key comment updated
- world.gd:14603  _face_star_pass guard: `int(parts[0]) < 2` added (home keys are 3-part face 0 now)
- save.gd:5       SAVE_VERSION 4 -> 5, comment names AC-0459 + key-format reason
- harness.gd:32253 _seamcensus: parse the 3-part colon form; chart-face keys (face>=2) skip the flat pair check (pre-flip unparseable -> same)
- harness.gd:25361 flysave: e["col"].split(":") parts[1]/parts[2] (e["col"] = world.chunk_key home key)
- ARCHITECTURE.md §5 (AC-0459 4->5 bump note), §6 grid-lock bullet (home key 0:%d:%d), §6 face-chart bullet (shared spelling)
- Baselines captured pre-edit at .scratch/AC-0459-gates/*-r0.log (genhash 25 lines -> .scratch/AC-0459/gh-r0.txt; light surface_eff=15 cave_eff=0 torch 14 pocket [8,120,-50] cands 590; ac0423probe ok ms=5557)
- Gates (rev 1) running: g0,genhash,light,ac0423probe,faceedit,save,load

## DONE — 2026-10-20 — AC-0459
Gates (rev 1, all logs .scratch/AC-0459-gates/): g0 0/0 clean; genhash 25/25 BYTE-IDENTICAL vs
pre-edit baseline (diff gh-r0/gh-r1 empty); light fields identical (cave_census_ms 461->460 only);
ac0423probe equal excl ms (5557->5545); faceedit green both charts (0.578/0.397 m); save ok=true
(blocks 6/6, v1_softfail true, R 4000 round-trip, clamps 8000/2000); load ok=true simband_ms=6740
(~6.7 s tree normal — no 50 s stall). Version-rejection NEGATIVE CONTROL EXERCISED: probe scene
(temporary, removed in-task) booted a real world, saved 1 edit (v5), tampered version->4, ran the
real _continue_slot: "SAVE SOFT-FAIL (old save format: version_ok=0 planets_ok=1 edits_v2_ok=1) -
edits discarded, fresh world" + seed=44 + edits_empty=1, clean exit (negctrl-ver4-r1.log). Note:
the player POSE was restored on the soft-fail — that path is height-gated (main.gd:684), pre-existing,
untouched (plan says do not rewrite the rejection path); safe here since genhash 25/25 = same terrain.
Legacy-key grep: 0 quoted 2-part int pairs in all r1 logs + negctrl log + save snapshots
(save_v5.json edit key "0:0:0:0:136" 5-part; save_v4_tampered.json = same file, version 4).
Results page rewritten: tasks/AC-0459/AC-0459-results.html.
