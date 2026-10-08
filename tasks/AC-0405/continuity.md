
## RUN - 2026-10-07 19:10 - AC-0405
- First action: journal created. Plan+implement in one turn. Gates: G0 + smoke + genhash + renders (the acceptance) + one boundary r4 A/B. Fence: main.gd / game.gd / drop.gd / debug.gd untouched.

## MILESTONES (2026-10-07)
- Shader rewrite landed (cloud_layer.gdshader: volume path = 3-D FBM density in the annulus
  [R+275,R+400], Beer accumulation, 6-tap coarse light march toward sun, HG phase, dark-edge
  tap; u_vol<0.5 short-circuits to the exact AC-0401 path — OFF body verified byte-identical
  to the original by difflib over the whole fragment body + vertex/fog/ahash/anv/fbm).
  Parser findings (measured, G0): the dummy parser resolves fragment builtins + `discard` in
  fragment() ONLY (nested entry -> SHADER ERROR), and `return` is forbidden in fragment()
  (the if/else structure is the workaround). world.gd pushes u_vol + u_vol_r/rmin/rmax
  (change-gated, retry-until-visible latch, outer shell = max-h layer) + inner-shell
  visible=false while ON; AWECRAFT_CLOUDVOL env preload; settings.gd default true + sanitize;
  menu.gd row CloudVolCheck (hi+13) + sync + _on_cloud_vol_toggled.
- G0 PASS: headless --quit rc=0, SCRIPT ERROR 0 / SHADER ERROR 0 (.scratch/AC-0405/g0.log).
- SMOKE PASS: AWECRAFT_BATTERY=player;interact;light;fluids;genhash rc=0, battery ok:true —
  player (col_deferred_in_footprint 0, is_on_floor, sprint ok), interact (drop/place ok),
  light (surface 15 / cave 0 / torch 14 / far 0->9), fluids (sea_stable, 1719/320, 25/9),
  census 0/0 (.scratch/AC-0405/smoke.log). NOTE: the battery self-quits — `--quit` breaks it
  (the process dies after frame 1, zero RESULT lines, silent rc=0); the recipe is
  HARNESS.md §4 as written (no --quit).
- GENHASH 25/25 byte-identical vs the current standing set (AC-0400-gates/smoke-genhash.log
  == AC-0399 == AC-0398; the AC-0367 ref file is stale vs those) — .scratch/AC-0405/
  genhash_{ref,new}.txt. Rendering-only, confirmed.
- RENDERS launched (run_renders.sh, job bash-575): r2600-on, r700-on, r700-off (CLOUDS=0),
  r300-on (parallax), r120-on (descent); R24/F83/T0.5 frozen/CLOUD_T0=411200/CAM=planet/
  SNAP_DRAIN=1200/SNAP_STEPS=600/DSSTATS=1; 1200 s cap each; Forward+ boot line asserted.
- RENDERS round 1 (pre-fix, job bash-575): r2600-on wall=772s rc0, r700-on wall=763s rc0,
  r700-off (CLOUDS=0) wall=471s rc0, Forward+ boot line all, volume path live (SATDIAG
  clouds: outer shell vis=true carrying the march, inner two hidden). Measurements on the
  700 pair (analyze2.py): lower_mid lum_std ON 57.5 / OFF 40.2 (baseline 16.9/32.4 - the
  spread target is MET), px_center [181,229,190] = the reference water tint (not 222 grey),
  pct_diff8 ON-minus-OFF 8.88%. BUT the deck band at 700 m read as one dark storm band
  (~60-90 luminance, no lit tops).
- LIGHTING DEFECT FOUND + FIXED (before round 2): (1) the FBM field filled ALL space around
  the shell - the light march (480 m toward sun) and the dark-edge tap never exited the
  "cloud", so every sample self-shadowed (sh ~ 0.07 everywhere); (2) the HG phase arg had
  the wrong sign (in-scatter scattering angle is dot(sun, -rd) = -cosSun, not cosSun -
  the lit-top peak sits at the wrong terminator side); (3) the HG peak (~13 at g=0.65)
  unnormalised would saturate every lit sample to flat white. Fixes: vgate(q) radial gate
  confines field to the annulus (light march exits at a top sample, stays inside on
  undersides; view-chord ends get a ~20 m smooth fade), phase normalised by vhg(1.0) in
  both L and Lo, dark-edge sun suppression uses -cosSun (lit camera-facing faces keep
  their brightness; backlit silhouettes keep the powder rim). Also learned: vgate had to
  be defined before vdens (GLSL no forward decls) - G0 caught it (SHADER ERROR round).
  G0 re-pass after fixes (g0b.log: 0/0 rc=0). Round 2 launched (job bash-576, all 5 frames).

## MILESTONES (2026-10-07 cont. — ticket complete, light gates)
- RENDERS round 2 (final shader, job bash-576): r2600-on 786s, r700-on 781s, r700-off 496s,
  r300-on 867s, r120-on 814s — all rc=0, all SNAP OK, Forward+ boot line every log.
- ACCEPTANCE MET: (a) parallax = r300-on (camera inside annulus: near dark clumps in front
  of the brighter far layer — one mass behind another); descent = r120-on (player on the
  ground below a thick 3-D layer of overlapping masses at different depths). (b) spread
  (700 m, analyze2.py lower_mid lum_std): old deck 16.9 -> volume 68.9 (cloudless same-tree
  40.2, baseline pair 16.9/32.4); horizon band 75.3 vs 35.6; px_center [181,229,190] =
  reference tint, not 222 grey. Cost: volume +285 s (+57 %) vs same-frame clouds-off at
  700 m; drain ~1.5-2 FPS worst case (1 FPS at 120 m full-sky) — inside the 1200 s cap
  for all 5 frames (no 640x360 fallback).
- BOUNDARY r4 A/B: ON rc=0 / OFF rc=0, ok:true both, fences 0/0, footprint 0/0;
  crossing_frame p95 32(ON)/44(OFF) + built_final 64/66 = machine-timing churn (documented
  class), ON ~= OFF -> no streaming effect, no re-baseline owed.
- All 10 gate logs census-clean (0 SCRIPT / 0 SHADER ERROR). ARCHITECTURE.md synced
  (Settings row, CloudLayer bullet, _ac0401_push seam). Captures copied to tasks/AC-0405/
  (5 PNGs). Results page: tasks/AC-0405/AC-0405-results.html. Durable rules (dummy-parser
  limits, field confinement, HG peak normalisation, battery --quit) recorded in results §9
  for closeout harvest. Heavy set + closeout (commit/push, TASKS.yaml, CONTINUITY
  checkpoint) = coordinator's job. EXIT.
