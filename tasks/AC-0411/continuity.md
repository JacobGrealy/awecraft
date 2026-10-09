## RUN - Fri Oct  9 06:00:52 EDT 2026 - AC-0411
- first run; no prior journal. Reading READ-FIRST stack, then re-confirming measurement on current tree before any edit.
- 06:1x - plan.html written; capture + analysis tooling in .scratch/AC-0411/ (r21 recipe verbatim, nadir_box + disc sat/contrast + green-dom metrics).
- BEFORE sweep (job bash-630): 6 renders 1600/2600 x T0.25/0.5/0.75 on the current tree (HEAD e243af2; shader tree == r21-assessed 449654c).
- NO game-file edits while the sweep is in flight (later runs would pick them up).
- 07:30 - BEFORE 1600 m done (all rc=0, SNAP files exist):
  - T0.25 nadir (2.3, 49.5, 64.0) dark textured (no wash)
  - T0.50 nadir (127.2, 191.6, 201.9) sat 0.378 wash 1.6% - EXACT match to r21 assessment -> defect re-confirmed on current tree
  - T0.75 nadir (18.7, 95.5, 107.3) dark
  Time dependence present: wash only in the daylit regime. 2600 m runs in flight (job bash-631).
- 08:20 - Fix applied (shader u_srgb_pre + terrain-term decode-then-scale; driver push in _build_face).
  Gates: G0 rc=0 (0/0 errors); shaderforce 12/12 rc=0; SMOKE first attempt rc=134 = the KNOWN stochastic
  UAF class (signal 11, single libc+0x45f60 stub frame, clean log, streaming context - documented signature),
  re-run rc=0 all arms green; genhash 25/25 identical to current standing reference (AC-0408 set; AC-0367 set is
  pre-r2-r3-rebase and stale); meshprobe match_rate 1.0 rc=0. BEFORE sweep: 6/6 rc=0, all Forward+, zero errors;
  2600 T0.5 re-confirms (130.7,195.7,206.5) EXACT; 1600 T0.5 (127.2,191.6,201.9) EXACT; wash only at T0.5 (daylit).
  AFTER set (job bash-632): 6 sweep + clouds-off + 3 landing in flight.

## RUN (continued) - Fri Oct 9 ~15:00-16:30 EDT 2026 - AC-0411 - ROOT CAUSE FOUND + FIX
- The wash is NOT (only) the double companding. The root cause is INSIDE-OUT WINDING of the
  satellite body mesh: the per-face corner test in _geom_for_face (satellite_body.gd:1066,
  (p01-p00).cross(p10-p00).dot(p00) >= 0) picks the index order whose geometric normal points
  OUTWARD - but under Forward+ cull_back an indexed triangle rasterises as FRONT from outside
  exactly when its geometric normal points TOWARD the centre (verified in Python against the
  exact orbital camera: the real [a,c,b] order of faces 0/1 is back-facing-from-outside).
  Consequence: faces 0/1 (the +Y hemisphere = the whole near-side cap) are CULLED; faces 2-11
  draw their FAR side - the orbital disc is the planet's UNDERSIDE. Disc centre = far-side
  nadir (d~10215 at (640,575)): NORMAL=(0,-1,0) points AWAY from the camera -> cosv=0 ->
  haz_a=(1-cosv)^2=1.0 -> ALBEDO = u_air exactly = (144,209,221) flat wash. Perfect flatness
  (659/665 samples byte-identical) = flat far-side surface + haz=1 across the nadir region.
  The ticket's "71% grass" texel is a NEAR-side cap texel - it is never rendered.
- Evidence chain (all in .scratch/AC-0411/): (1) meshprobe2 census on the ACTUAL arrays:
  100% of 1,399,218 triangles have outward 3D normals (inward=0, all 12 faces) - mesh data is
  fine, only the engine-facing classification is inverted; (2) DIAG-12 face-id render: the disc
  is green (faces 2-11, their far side) with scattered red triangular speckles (face 0/1
  fragments whose screen winding locally flips - displacement-dependent); (3) original
  render_mode = cull_back, depth_draw_always, fog_disabled (I only ever added unshaded for
  diags); (4) no second sphere/duplicate exists (gizmo off, no .duplicate(), single body at
  (0,-4000,0) scale 1, op_nadir=1, near plane 0.1, walk pad is 10 m); (5) the (155,255,68)
  uniform in the DIAG-12 frame = the THICK cloud deck of that run (cov=0.750), not the body -
  red herring resolved; (6) Python screen-space winding of the real index orders (exact camera:
  cam (14.47,2741,14.47), FOV 75, nadir pixel (640,706)): faces 0/1 [a,c,b] back-facing;
  faces 2-11 far side drawn - matches the render exactly.
- FIX (applied, diagnostics all reverted): (a) ONE-LINE - the corner test comparison inverted
  (>= 0.0 -> < 0.0) in _geom_for_face, with an AC-0411 comment; every face now winds
  CCW-in-engine-convention (front from outside). (b) fix v1 (u_srgb_pre decode-then-scale) KEPT
  as the separate, real domain defect on correctly-rendered lit terrain (it was a byte-identical
  NO-OP on the wash - consistent: the wash is haz=1 u_air, independent of the texel domain).
  Shader restored to cull_back, depth_draw_always, fog_disabled (no unshaded, no u_face_id, no
  DIAG blocks). SATAC0411 census prints + u_face_id push removed.
- Gates on the fixed tree: SMOKE rc=0 (no UAF this time); G0 census on smoke_fix.log: 0/0 ok.
- VERIFICATION render (ac0411-after-2600-t050.png, fixed tree, 2600 T0.5): nadir box
  (134.4, 202.8, 151.9) GREEN-dominant (was (130.7, 195.7, 206.5) cyan wash); green_dom
  94.7% (was 1.7%); whole-disc sat 0.337 -> 0.370, lum_std 45.7 -> 62.5.
  LINK TEST VERDICT: the single winding edit moves BOTH the disc centre AND the disc's overall
  saturation/contrast -> the ticket and the pastel low-contrast finding are ONE job.
- FINAL after set in flight (job bash-645): 6 sweep (1600/2600 x T0.25/0.5/0.75, fresh names
  final-*) + clouds-off 2600 T0.5 + landing 120/300/ground. Then genhash 25/25, meshprobe 1.0,
  shaderforce 12/12, full analysis, results page, report.

## RUN (continued) - Fri Oct 9 18:30-18:50 EDT 2026 - AC-0411 - FINAL SET + GATES COMPLETE
- FINAL after set (job bash-645): 10/10 rc=0, all PNGs in tasks/AC-0411/ (final-{1600,2600}-t0{25,50,75},
  final-2600-t050-cloudsoff, after-landing-{120,300}, after-ground; each + _s600 twin).
- Acceptance sweep (analyze-ac0411.py): daylit rows now green-dominant - 1600 T0.5
  (143.4,206.2,147.3) green_dom 96.1% (was (127.2,191.6,201.9), 5.2%); 2600 T0.5 (134.4,202.8,151.9)
  green_dom 94.7% (was (130.7,195.7,206.5), 1.7%). Dark rows dark + green-dominant (night floor +
  grass texel; before they were the night u_air haze wash, B-dominant). Clouds-off A/B: nadir box
  byte-identical with/without clouds (134.4,202.8,151.9).
- Landing half vs r21: 120 m = no regression (farm/near terrain layout+colour identical; horizon =
  per-run weather drift, r21's own A/B precedent 61% with near terrain unchanged; the body is not
  visible at 120 m - the 2 m inset). 300 m = VISIBLE CHANGE, the fix not a regression (r21's 300 m
  frame is the streaky pastel far-side wash; the fixed frame is the textured near-side cap - green
  terrain/sand/water, correct curvature, smooth handover band, no nadir z-fighting). Ground =
  geometry identical, per-run light/cloud drift only.
- Gates on the fixed tree: genhash 25/25 IDENTICAL to .scratch/AC-0408-gates/genhash_r1.log (GENMS 150)
  rc=0; meshprobe match_rate 1.0 ok=true verts 236716/236716 rc=0; shaderforce 12/12 ok
  (satellite_body.gdshader declared=8 params=8) rc=0; G0 census on smoke_fix.log 0/0 rc=0; SMOKE rc=0
  (no UAF on this run).
- Deliverables complete: AC-0411-results.html (rewritten around the winding root cause, all tables
  filled), this journal, the before/final frame sets, the report.
