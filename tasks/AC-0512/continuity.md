## RUN — Tue Oct 27 01:10:44 EDT 2026 — AC-0512

## LANDED — Tue Oct 27 01:58 EDT 2026
- world.gd: AC-0512 block before `_process` (state + `_ac0512_init_now/_tick/_holding/_census`),
  two hooks after `_sw_frame += 1`, held-publication gate at the top of `threadmesh_handoff`
  (data/mat entries pass; mesh attach suppressed; slab stays PENDING → re-dispatched).
  Census at pose (tag "pose"), frame 560 (tag "late"), and hold-end (tag "holdend"):
  per-column top + satellite H + SIGNED err, tier, data/mesh state, counters,
  camera basis rows; JSON → .scratch/AC-0512-gates/census-<tag>.json; `AC0512` log lines.
- satellite_body.gd: NO edit — the missing-fallback negative control reuses the existing
  `AWECRAFT_SAT_BODY=0` A/B env (body-off from t=0).
- Env (default off): AWECRAFT_AC0512=1, _HOLD=<ms> (5000), _HOLD_AT=<frames> (300 for the hold
  render — 5 s ≈ 1 frame at 0.25-0.5 fps, so the window opens where attach is actually pending),
  _ALT=<m> (250, pose trigger; lowered for headless tests).
- Verified: parse clean (rc 0, 0 SCRIPT/SHADER ERROR), census fires headless (pose 25 chunks,
  late 1401 chunks / 393 ms / nodata 960 / delay 2 / drawn 143), genhash 25/25 byte-identical to
  the AC-0510 reference WITH instrumentation on (extra inertness evidence).
- Render set launched serially (job, ~25 min each, llvmpipe): base (air 300/pitch30),
  hold (+HOLD=5000@300, SNAP_STEPS=300,301,600), bodyoff (AWECRAFT_SAT_BODY=0),
  seam (AWECRAFT_AIM=2890,500,0,-1.5708,-0.52 — ~250 m inside the +x patch edge, facing it).
- .scratch/AC-0512/gaps.py — the pixel instrument (ray→sphere classes, local-sky A/B gap test,
  per-gap five-way attribution via the census, exterior-gap counter, AC-0510 wall-jump/contrast
  extension, census signed-error + projected-displacement tables per tier × case).

## ANALYZED — Tue Oct 27 04:40 EDT 2026
- All 4 renders re-run per-case (AWECRAFT_AC0512_DIR), rc=0, 0 errors; censuses: air = 1401 home /
  nodata 960 / delay 2 / drawn 143 @ frame 560 (identical across base/hold/bodyoff); seam re-rendered
  with the wall-clock late trigger (aim-flow drain = 600 PHYSICS frames = 10 s wall; the idle-frame
  fallback was unreachable — deviation 3 superseded): 2802 home / 0 face / nodata 1064 / delay 22 /
  discard 41 / drawn 19; "SNAPDRAIN not fully drained after 600 frames".
- gaps.py final detector (deviation 10): GEOMETRIC presence (fixture + census), never colour — the
  AC-0511 haze endpoint is sky-matched so a colour test cannot discriminate the exterior; census
  terrain mask per pixel + chamfer sky model (seed = bodyoff exterior + space) for the (5) read.
- Diagnosis (air, frame 560): (1) 49,656 px = the tier-3 NO-DATA ring (960 chunks) under the visible
  annulus; (2) 0 visible (no tier-4 data past the edge yet); (3) 0 visible (the 2 delay chunks project
  y=791/891 — below the frame); (4) 0 gap px (census-side: cliffs err −7.6…−8 m, px 11.9–14.5);
  (5) 151,371 px of exterior reads as sky while the body is drawn (61.4 % of the exterior).
- Negative control (gate d): counter BEFORE (base) 49,656 → AFTER (bodyoff) 296,362 (6.0×; Δ = the
  246,706-px exterior the body covered; the 49,656 missing-chunk component identical in both).
- Hold (gate c): START frame 300 / END hold_n=127; s300 vs base = 458 px (suppressed slabs, cause 3
  slab-level); s300→s301 = 13 px; s301→final = 490 px; final vs base = 40 px (recovered, steady state
  unchanged); holdend census identical to baseline.
- Frontier (same pose as AC-0510 after-pitch, AC-0510-exact definitions, n=1574): wall jump 23.21 /
  110.16 / 205.64 vs AC-0510 20.0/69.0/249.3 (images not byte-identical — build drift); contrast
  300-400 15.65 (17.97), 400-800 1.068 (0.813), 800-1600 1.040 (0.276); bodyoff 800-1600 = 0.0 → the
  entire far-band contrast is body texture (AC-0511 haz_a-only reads 4× more textured far than AC-0510).
- Signed error: air tier 0 n=10347 mean −1.21 (p50 −1.0, systematic ~1 m low + the 2 m z-fight inset),
  tier 1 n=25822 mean −1.55; coast n=1208 −4…+1 m (<7 px); cliff n=39 −7.6…−8 m (the (4) signature);
  tiers 2-3 hold no data in the census at these poses.
- SEAM (gate b partial): PLAN-INSUFFICIENT as planned — at 498 m altitude min possible hit t = 498 >
  render_edge 400, so the chunk seam can never be in the near band (measured min t 509 m; 0 near-band
  px; 0 face chunks ever created — the edge ensure arms at the edge column, player at 180). Measured
  instead: the visible line x≈640 = the home/face boundary in the BODY — 4-px |ΔL| across it
  51.35/p95 137.26/max 177.79 vs 6.60 baseline (8×); 1-px at line left 10.11 / right 52.98; seam census
  tier 0 n=9456 mean −3.36. Correction for the Windows re-take is in the protocol file.
- Anchor recheck: all intact (satellite_body.gd:827 process_frame; core/satellite_body.gdshader:205
  fragment / :218 op / :250 haz=haz_a; world.gd:1816/2006/3039; _patch_edge_ring :15575→:15920 shifted
  by this ticket's block); no pre-existing exterior-gap counter — built in Python.

## GATES — Tue Oct 27 04:40 EDT 2026
- gate_run.py AC-0512 --arms g0,genhash,residency: GATE_EXIT=0. g0 rc=0 0/0 (3 s); genhash 25/25
  diff-identical to the AC-0510 reference (4 s); residency leak False / STABLE / home evictions 220 /
  face 0 / 408 frames (17 s). Logs .scratch/AC-0512-gates/{g0,genhash,residency}-r1.log + summary.txt.
- Genhash also 25/25 + 0 errors WITH the instrumentation envs ON (test5). Mesh output not byte-compared
  (deviation 8, stated in results).

## DONE — Tue Oct 27 04:45 EDT 2026
- Deliverable: tasks/AC-0512/AC-0512-results.html (self-contained; every number greppable from
  .scratch/AC-0512-gates/). Diagnosis: frontier gaps = (1) absent tier-3 chunks (49,656 px) + (5)
  sky-like body endpoint (151,371 px); (2)/(3)/(4) zero visible px at this pose, (3) proven at slab
  level by the hold fixture (458 px), (4) census-side on cliffs (−8 m). Negative control rose 49,656 →
  296,362. Seam subcase PLAN-INSUFFICIENT (pose geometry) — established facts + correction in the
  protocol. No engine code beyond the default-off instrumentation; harness.gd, satellite_body.gd,
  TASKS.yaml, the other session's dirty files: untouched. No git ops (closeout owns the commit).
