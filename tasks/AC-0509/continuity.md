## RUN — Sun Oct 25 22:35:45 EDT 2026 — AC-0509

Survey-and-classify ticket: 3x "face == 0 or face == 1" branches in world.gd (located at :16022/:16203/:16215 by search), 29 "home" uses in player.gd. Plan = tasks/AC-0509/plan.html.

### LANDED (Mon Oct 26 ~00:27 EDT)
- Survey: 32/32 classified, zero unclassified (3 world.gd branches — all LEGITIMATE canonical chart anchoring / storage routing; 29 player.gd uses — 25 LEGITIMATE incl. the `home_point` identifier, 4 BEHAVIOURAL: 2 documenting the FACE_STEP branch + the viewmodel-light guard + the bucket no-op). Full table: `AC-0509-deviations.txt`.
- REMOVED (3.2): the FACE_STEP behavioural branch (1.0 m on faces 2-11 vs 0.5 m on home) — unified to `Player.AUTO_STEP_MAX := 0.5` for all twelve faces (geometry: post-AC-0471 both charts ~1 m/cell + pointwise-continuous face warp, no seam lip; 1 m = a jumped wall everywhere). Stale "6 m cell resolution" comments corrected in player.gd and ARCHITECTURE.md :1302 (invariant 2).
- LEFT (fenced): viewmodel-light floor on faces 2-11 (fix = face-grid light pull = light ownership, don't-touch; the guard is the AC-0482-class bug shield) and the bucket no-op on faces 2-11 (fluids ticket's scope; no new tickets).
- NEW STANDING GATE (3.3): `aimface` arm — harness.gd dispatch (after voxelcost) + 7 trailing functions; harness_data.yaml row; HARNESS.md re-rendered via `harness_doc.py --render` (--check clean). Reuses AC-0482's method verbatim (fly-stand 2.0 m above the column top, straight-down aim, 30-frame stable-aim gate, the chunk's own warp as block truth, the AC-0482 sites). Teeth: every site in the home class (centre/corner_tang < 100 mm, box_up < 5 deg) + both chart classes covered. NEGCTRL mode feeds the verdict the recorded pre-AC-0482 km numbers and must reject them.

### GATES (logs .scratch/AC-0509-gates/)
- aimface BEFORE (r3, pre-removal player) / AFTER (r4, post-removal): ok, IDENTICAL per-site values — spawn 10.8699 mm (centre 0.0, D 12.05), home_far 15.0104 mm (centre 0.49, D 152.7, top = non-solid block 19 at [152,164,-8]), face4_edge 13.8095 / face4_mid 14.2322 / face2_pole 13.9563 mm (centre 0.0 each), box_up <= 0.028 deg — face values reproduce AC-0482's post-fix r2 log to 4 dp.
- aimface NEGCTRL (r5): rejects_pre_fix true (9 fails: centre/corner_tang/box_up at all three non-home sites), accepts_post_fix true — gate proven able to fail.
- g0 (r1): rc 0, 0 script / 0 shader errors.
- genhash (r1): 25/25 byte-identical to the reference set (diff vs tasks/AC-0433/captures/genhash-ref2.txt clean).
- smoke: player/interact/light/fluids all ok (0/0; sprint_ok, place_ok, sea_stable).
- residency (r1): leak=false, verdict STABLE, crossings ok (face resident 73->74, home steady 93, keys_same).
- Discarded runs: r1 (parse errors — coroutine await + unsigned_angle_to absent in 4.7.1), r2 (first live run — exposed the face_local_x data-layout truth fix and the DDA-top aim-target fix; both fixed before the baseline).
- Deliverables: `AC-0509-results.html` (results_page.py, integrity-checked), `AC-0509-deviations.txt`, this journal. Files: godot/player/player.gd, godot/scenes/harness.gd, godot/harness_data.yaml, godot/HARNESS.md (rendered), godot/ARCHITECTURE.md. No git add/commit (fence).
