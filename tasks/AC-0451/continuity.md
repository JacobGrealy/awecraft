## RUN — Wed Oct 21 15:32:36 EDT 2026 — AC-0451 (P1 coverage predicate, MEDIUM)
- started: baseline renders (pre-change), then edits, then gates+post renders.

## LANDED — AC-0451 P1 (baseline renders done first, pre-change tree)
- Baseline (pre-change) renders COMPLETE: pre-aerial 0533ab54854c4d2327881efcc21304a1,
  pre-ground bae39f92d6db5d73ec2d453fc2b64828, pre-edge 95e107f2cbe9026ce920c0bd95910460
  (R24/F83, T=0.5 frozen, CLOUDS=0, Forward+/llvmpipe, fog_far=332.0 render_edge=400.0
  asserted in the SATDIAG lines; aerial visually verified to carry the near disc + hazy annulus).
- Edits: 12 near-field shaders (8 chunk_lit_*.gdshader, core/lod_avg.gdshader +
  core/lod_avg_seam.gdshader, core/fluid_anim{,_bf}.gdshader) — every u_fog_far discard
  routed through ac0451_covered(d), a marked P1 STUB returning false unconditionally
  (contract comment in chunk_lit_opaque.gdshader, pointers in the other 11); u_coverage
  uniform declared in all 12 (both lod variants, so the AC-0446 material-shader swap
  stays valid). godot/world/world.gd _ac0401_push: new (1a) block pushes u_coverage
  change-gated (value + material-set size, the AC-0420 pattern) to the same material set
  as u_fog_far + _lod_avg_material (AC-0443 latch pattern); AWECRAFT_COVERAGE=0|1 env,
  NO Settings row (AC-0445 precedent). godot/ARCHITECTURE.md: AC-0451 P1 bullet after
  the AC-0401 bullet (the rule + that P1 is inert). Body shader, draw order, stale-LOD
  cache, fog values, placement, keys, saves, SphereMath: untouched.
- Next: gates g0,genhash,light -> post renders (4) -> md5 compare.

## FINDING — the plan's A/B recipe is nondeterministic (noise floor > the pre/post delta)
- First post-render A/B (the plan's recipe: air preset alt 300 nadir / first-person
  spawn / air alt 300 pitch 55, drain 600): all three pairs DIFFER
  (pre-aerial 0533ab54 vs post-aerial 5e42a82f; pre-ground bae39f92 vs
  post-ground 84446021; pre-edge 95e107f2 vs post-edge 5c8babc0;
  post-aerial-cov1 a8925397 differs from post-aerial too).
- NOT concluded non-inert: CONTROL RUNS on the SAME (post) tree, same pose,
  re-ran the aerial and ground and also differ (ctl-aerial2 f3c7e43d vs
  post-aerial: 10,689 px; ctl-ground2 29b32e85 vs post-ground). The
  run-to-run noise floor (10.7k px) is LARGER than the pre/post delta (4.9k px) —
  a no-op would fail this A/B. The plan's byte-identity gate is unachievable on
  this recipe as written.
- Noise sources identified (pixel-overlay evidence in .scratch/AC-0451/):
  (1) the animated fluid surface (fluid_anim TIME-driven UV frames) wherever
      near-field water is in frame (the spawn pond sits in the 300 m nadir frame);
  (2) near/far LOD promotion timing — the shot is a FIXED frame count after
      body-LOADED (air/planet branches, harness.gd ~1510/1698) while world
      streaming is wall-clock-budgeted (Time.get_ticks_msec, world.gd), so the
      streamed state at shot time varies per run; the ground path's
      "SNAPDRAIN not fully drained" (main.gd:1848 _await_world_build) hits its
      cap even at 3000 frames at R24 (the R24 world never settles in budget).
- Resolution in flight: find deterministic vantages (no animated water within
  300m of the vantage, frame over settled geometry) and PROVE the recipe
  deterministic with same-tree control pairs (must be md5-identical) before
  re-running the pre/post A/B. Trials: +600,0 offset went over open ocean
  (featureless haze frame — rejected, risk-2: a frame that cannot see the
  effect); batch 2 tries -600,0 / 0,-600 offsets + a straight-down
  first-person aim (core 3x3 chunks only).

## RESOLUTION — deterministic recipe found (control pairs md5-identical)
- GROUND view: first-person spawn aimed straight down (AWECRAFT_AIM="8,141.8,8,
  0,-1.57", frame = the core 3x3 chunks only, no water, no streaming ring):
  t2-ground-nadir a6416111030623e61885724caee82797 ==
  t3-ground-nadir-b a6416111030623e61885724caee82797 — BYTE-IDENTICAL.
- First aerial attempt (AIR_ALT=330) failed the control (6c14e4cb vs af8470ea,
  diff at the pond): AIR_ALT is TRUE RADIAL ABOVE THE R SPHERE
  (harness.gd:1599-1601), and the spawn terrain sits 141 m above the R sphere —
  so AIR_ALT=330 was only 189 m above surface and the pond stayed in the
  near zone (animated fluid). Corrected: AIR_ALT=471 = 330 m above surface
  (near zone = the 26 m core disc, water-free; annulus 26-221 m wide;
  [332,400] fade band + 400 m render edge in-frame). t4 batch re-runs
  aerial (NADIR) + edge (PITCH=55) at 471 with -a/-b control pairs.
- Note: the body shader (core/satellite_body.gdshader) has NO TIME usage —
  it is static; the only animated surface is the near-field fluid (within
  d < 332 of the camera). The straight-down ground aim also sidesteps the
  R24 never-settling streaming ring (the "SNAPDRAIN not fully drained" cap
  line stays in the log but is inert: the far ring is out of frame).

## DECISION — why the seed-44 aerial/edge cannot be byte-identical, and the path
- t4 (AIR_ALT=471 = 330 m above surface, the corrected altitude): aerial
  control pair ab545fb7 vs 00111745 (689 px, sparse 1-px speckles, max D67,
  inside the haze band only); edge control 413767a8 vs 80c9d902. Camera
  pose + ALL measured uniforms (fog_far 332, render_edge 400, u_air,
  u_sky_alt, op_nadir 0.096, body_phase 4, mesh verts 1707596) are
  BIT-IDENTICAL across the two runs (RESULT lines) — so the residual diff
  is not camera, not uniforms, not the body (no TIME, static), not the sky
  (no TIME, CLOUDS=0).
- Root cause: the near field is NOT the 26 m core disc at h=330 — it
  stretches over every hill (terrain up to hmax 384 m above the R sphere:
  a 384 m peak under a 471 m camera sits only 87 m below it, so the
  d<332 near zone reaches ~320 m horizontally toward it). Those hill
  pockets draw the near field in per-run state (animated fluid where a
  hill pond is in zone + med/hi LOD promotion timing) = sparse speckles
  through the haze. The ground view is immune (core 3x3 only, no hills,
  no water) = proven byte-identical.
- Body shader (core/satellite_body.gdshader) and sky
  (core/aero_sky_gradient.gdshader) confirmed TIME-free by grep.
- PATH: seed search (seed 45 now, 46 if needed) for a spawn vicinity that
  is flat + water-free within ~350 m, so the near zone IS the settled core
  disc -> deterministic aerial/edge, full byte-identity A/B on the plan's
  own terms. Per-seed cost: one ~13 min bake (cached in /tmp/dsh_home) +
  ~4 min runs. Ground AIM coords are seed-specific (seed 44: 8,141.8,8) —
  re-derive from the winning seed's RESULT "spawn" field.
- FALLBACK if seeds fail (recorded as deviation): the no-op control proves
  the recipe nondeterministic; deliver the noise-floor proof (pre/post
  delta confined to the near-state speckle class, <= the no-op floor) +
  the ground byte-identity + the stub's logical inertness.

## WIN — seed 45: the deterministic A/B recipe
- Seed 45 (spawn [8.5,142.0,8.5]): the aerial471 control pair is
  BYTE-IDENTICAL: seed45-aerial471-a 10042ff617f15bdd73725b578dc327c6 ==
  seed45-aerial471-b 10042ff617f15bdd73725b578dc327c6. The spawn vicinity
  is low/flat with no water within the near zone (the ponds sit 100 m+
  out, in the static body zone). This is the scene for the full A/B.
- Edge + ground control pairs now running (s45-edge-a/b, s45-ground-a/b;
  ground AIM 8.5,143.8,8.5 straight down). If all pairs are identical,
  the protocol fires: post cov1 (aerial471 + AWECRAFT_COVERAGE=1), then
  reverse p1.patch -> PRE tree -> the 3 views -> re-apply -> compare.
- Seed 44 remains the non-deterministic counter-example (documented above)
  — its no-op control failing its own pair is the evidence the plan's
  recipe (as run on seed 44) cannot carry the byte-identity gate.

## EDGE VIEW — grazing-incidence body noise is intrinsic (drain does not help)
- Seed-45 status so far: aerial471 pair IDENTICAL (10042ff6 x2); ground
  straight-down pair IDENTICAL (021bb03f x2); edge pitch-55 pair DIFFERS
  (af47970f vs db8a6c14): 151k px (3170 >16, max D215) as thin
  terrain-contour lines across the grazing body surface; measured camera
  pos/aim/up/hd + all uniforms BIT-IDENTICAL between the runs.
- Drain 2400 edge pair: 151038 px / max D215 — identical character.
  Not a settling state. Diagnosis: sub-ulp floating-point state in the
  body mesh build (non-associative float merges under thread scheduling)
  shifts the displaced surface sub-pixel; a grazing view projects that
  across the frame as contour lines, while nadir/straight-down views are
  insensitive (sub-pixel in vertical projection). Intrinsic to llvmpipe
  renders of the grazing body surface — cannot be settled or seeded away.
- Fallback in flight: pitch-70 edge (band [332,400] still in-frame at
  56-86 deg depression; frame dominated by steeper near-nadir terrain).

## EDGE VIEW — slanted body views are never byte-stable; pivoting to nadir
- Pitch-70 pair ALSO differs (ac205700 vs a04efcb0, 190k px, max D243 —
  worse than pitch-55, incl. sky-adjacent rows). Conclusion: ANY slanted
  view of the textured body surface differs run-to-run (sub-ulp float
  state of the body-mesh build stretches through UV sampling at grazing
  incidence = terrain-contour lines). Nadir/vertical views are immune
  (aerial + ground proven identical). No drain or seed fixes the
  slanted case (the mesh-build float order varies per run).
- New render-edge design: a SECOND NADIR view at h=325 (AIR_ALT=466):
  near zone = 68 m core disc (water-free on seed 45: nearest pond 87 m
  out = body zone), annulus 68-215 m, d=332 wall ring + d=400 render-edge
  ring + solid body all in-frame. Test pair s45-nadir466-a/b running.
  Views if it passes: aerial = 471/330 m (10042ff6, proven), ground =
  straight-down (021bb03f, proven), render-edge = 466/325 m (pending).

## FINAL VIEW DESIGN (protocol launched)
- V1 AERIAL (mandatory annulus): seed 45, AIR_ALT=471 NADIR — deterministic
  (10042ff6 x2). V2 GROUND: straight-down AIM 8.5,143.8,8.5 — deterministic
  (021bb03f x2). V3 RENDER EDGE: AIR_ALT=471 PITCH=55 — proven
  nondeterministic by 4 no-op experiments (pitch55@600, pitch55@2400,
  pitch70@600, nadir@466; nadir@466 also dirty: the lower camera pulls
  hill pockets into the near zone); delivered as a noise-floor pair
  (pre/post delta <= no-op floor af47970f-vs-db8a6c14, same contour
  class). Protocol: post cov1 -> reverse patch -> pre x3 -> re-apply ->
  verify tree == patch.

## PROTOCOL RESULT + the per-run state question
- Ground A/B: pre-ground-nadir 021bb03f == s45-ground-a 021bb03f ==
  s45-ground-b 021bb03f — 3/3 identical across both trees. PROVEN.
- Render edge: pre-edge471 db8a6c14 == s45-edge-B db8a6c14 (post-A was
  af47970f) — the edge view is per-run BIMODAL and the pre tree produced
  exactly one of the post states. Per-run state, not tree state.
- Aerial: post pair 10042ff6 x2, but pre-aerial471 5b77ff02 differs from
  both by 242,908 px (98% sub-16 shifts + 4045 >16, max 243) localized to
  the body fade window (r 120-680 px = 44-248 m from nadir; near disc and
  solid outer body clean). All 12 shader hunks re-audited: every removed
  `if (EXPR >= u_fog_far)` vs added `float d = EXPR; if (d >= u_fog_far
  && !ac0451_covered(d))` is expression-identical — the predicate is
  provably inert at the expression level; world.gd only sets a uniform
  the pre/post shaders read into a dead `&& false`. So the aerial diff
  must be per-run state (the post pair may have drawn the same state).
  Decisive samples in flight: post-aerial471-c (3rd post) + pre-aerial471-b
  (2nd pre). If post-c == 10042ff6 and pre-b == 5b77ff02 the pattern is
  per-run; any exact match between a pre and a post sample further
  confirms tree-independence.
- cov1 (5abe8626) also differs from 10042ff6 — same class check pending;
  if per-run state, the switch A/B is read as: cov1 matches one of the
  post-state samples or the delta is the body-band class.

## OUTCOME — P1 delivered (2026-10-21 21:31)
- Change: 12 shaders (the marked inert stub ac0451_covered, the discard
  re-routed), world.gd (AWECRAFT_COVERAGE=0|1 env-only push, change-
  gated, no Options row), ARCHITECTURE.md handover bullet.
- Gates: g0/genhash/light round 2 all ok (rc=0 script=0 shader=0; round 1
  SHADER ERROR from a `(void) d;` cast, removed). genhash 25/25 byte-
  identical to the AC-0450 reference.
- Byte-identity verdicts (seed 45, AIR_ALT=471 = 330 m above surface):
  * GROUND straight-down A/B: 021bb03f x3 across both trees — IDENTICAL.
  * COVERAGE switch A/B: 5abe8626 (COV1) == 5abe8626 (COV0 same state)
    — IDENTICAL, 0 px.
  * AERIAL A/B: 5b77ff02 (pre, stable x3) vs 10042ff6 (post, early) —
    242,908 px, 98% sub-16, body-surface class; the POST tree alone
    yields 3 hashes in 5 runs => per-run render state, not a tree
    effect; predicate expression-inert by audit (12/12 hunks).
  * RENDER EDGE (pitch 55) A/B: pre reproduces a post state EXACTLY
    (db8a6c14); delta vs the other post state = the no-op floor itself
    (151,067 px, 0 excess).
- Fence: predicate INERT (the "stop and report" condition was never met);
  the unmet item is the plan's byte-identity RECIPE on body-visible
  views (nondeterministic scene: animated near-field water, wall-clock
  streaming at a fixed-frame shot, sub-ulp body-mesh float state) —
  reported with the full evidence ledger.
- Deliverables: AC-0451-deviations.txt, AC-0451-results.html (rendered,
  integrity-checked), this journal, renders/ (18 PNGs), .scratch/
  AC-0451-gates/ (arm logs, md5.txt, md5-compare.txt, genhash-verify.txt).
- No git add/commit/push, no registry edits, no new tickets (fence).

## RUN — Fri Oct 23 19:07:12 EDT 2026 — AC-0451 (P2 the coverage query, MEDIUM)
- started: edits (12 shaders predicate truth + u_render_edge uniform, world.gd (1a2) push), G0, then renders (COV0 then COV1: aerial471-nadir / ground-nadir / edge471-pitch55, seed 45), then genhash/residency/planetwalk. Plan count deviation: plan says 7 near shaders, P1 landed the stub in 12 — applying to all 12 (the anchor set), recorded as deviation.

## LANDED — AC-0451 P2
- 12 near shaders (the plan's anchor set: every file carrying the P1
  stub — 8 chunk_lit_*.gdshader incl. the 4 _fade variants, both lod
  variants, both fluid variants; plan text said 7, deviation
  recorded): ac0451_covered(d) now `u_coverage > 0.5 && d >= u_render_edge`
  ("the body is already drawing here"); new uniform
  `u_render_edge = 400.0` (R24 default, the u_fog_far 332.0 pattern)
  declared in all 12. Contract comment updated in chunk_lit_opaque.
- world.gd _ac0401_push: new (1a2) block pushes u_render_edge =
  float(render_radius + 1) * 16.0 to the chunk cache + both fluid mat
  sets (value + n_mats gate, AC-0420 pattern) and latches it onto
  _lod_avg_material (AC-0443 pattern). Source = world.render_radius,
  the SAME member main.gd:1523 reads for the same uniform (no shared
  helper exists — DayNight owns the fog side only; derivation copied
  from satellite_body.gd:945 / main.gd:1523, number's source shared —
  stated in the state-var comment + deviation). (1a) comment updated
  (P1-inert wording -> P2 state).
- Untouched: satellite_body.gdshader (body op window), main.gd, far
  tier, lane split, fog distances, generation, residency, light.
- TOOLING NOTE: the first render timed out at 1200 s (rc=124) — the
  body never reached LOADED. Root cause: today's C++ build (libchunkio
  .so, 2026-10-23 09:14) bakes the satellite from 1,700,726 records
  (1169 shards x 1454) vs P1's 196,196 (98 x 2002) — identical
  configure line otherwise; external to this change (the bake is the
  C++/world-data lane). Relaunch: bake run 3000 s, warm runs 1800 s
  (the satellite cache lives in /tmp/dsh_home, shared within one bash
  invocation). Timed-out logs kept as p2-cov0-aerial-t1200.log.

## GATES — AC-0451 P2 (2026-10-23, all values greppable under .scratch/AC-0451-gates/)
- gate_run g0,genhash,residency,planetwalk (one invocation, summary.json):
  g0 rc=0 script=0 shader=0 (3.4s); genhash rc=0 — 25/25 hashes
  byte-identical to .scratch/AC-0450/genhash.log (genhash-verify-p2.txt);
  residency rc=0 leak=false verdict STABLE (home_resident 103 in all 6
  steady samples, peak 177, evictions 220); planetwalk rc=0 ok 25/26
  (lap_0-1 home_pair_midline documented, fails=[], 2899 frames, 37.8s).
- RENDERS (seed 45, R24/F83, 1280x720, aerial471-nadir / ground /
  edge471-pitch55, p2-renders-console2/4.log + per-run logs, md5.txt):
  six-run set (drain 600): p2-cov0/1-aerial, -ground, -edge — all
  rc=0, 0 errors each.
  drain-1500 set: p2-cov1-aerial1500 (STEPS 600,1200) +
  p2-cov0-aerial1500 — rc=0, 0 errors.
- (a) OFF identity (P1's own method — pixel diff vs the P1-recorded
  states, p2-pixel-compare.txt): aerial COV0 vs P1 post-state
  10042ff6 = 587 px (0.06%, 442 >16, max 67); edge COV0 vs P1 record
  db8a6c14 = 646 px (0.07%, max 67) — both 0.4% of the documented
  151,067-px no-op floor (same per-run state). ground COV0 vs P1
  record 021bb03f = 32,512 px (3.53%, 98% sub-16, max 75, scattered)
  — the ground view is no longer byte-stable across TODAY'S tree
  boundary (the 2026-10-23 C++ rebuild — see tooling note); the
  within-tree statement holds: ground COV0 vs COV1 = 0 px
  (byte-identical md5 8a2bf60f x2).
- (b) altitude (p2-pixel-compare.txt, p2-pixel-compare-1500.txt):
  the switch's effect measured SAME RUN-STATE (P2-COV1 vs P1-COV0
  pre-state 5b77ff02, the body region diff = 0 px): 704 px (0.08%),
  513 px >16, max 67 — ALL in r 33-88 px about the frame centre = the
  BUILT inner annulus (d 332-~370 m): the fogged near tier replaces
  the body fade there. The rest of the [332,400] m annulus (chunks
  3-14) is UNBUILT at shot time — residency (AC-0399's half, the
  ticket's own "does not fix"): ring samples COV0 vs COV1 identical
  within 1/255 in all three bands at drain 600 AND 1500 (the COV0
  world is byte-identical across 600/1500 frames — no visible build
  progress; P1: the R24 world never settles in budget, and today's
  pacing is ~0.5-1.3 FPS vs P1-day's ~4). Where geometry exists the
  annulus fills with the env fog colour (the near tier fully fogged
  past fog_depth_end) — the same colour the body's haz blends to; no
  terrain appears in the window; no see-through where geometry exists.
  The 243,505-px (26.42%) COV1-vs-COV0 total at drain 1500 is the
  per-run body state (P1's documented 26.4% class), not the change.
- (c) ground ON vs OFF: 0 px (byte-identical) — the annulus is out of
  the ground frame; nothing moved.
- FLICKER: no coplanar speckle in any still (the annulus boundary in
  the COV1 frames is a clean contour); the depth order is geometric
  (the body's vertex stage pulls its surface 2 m inward —
  satellite_body.gdshader:166 — so the near tier wins the depth test
  deterministically wherever they overlap).
- ENV: machine load spiked 4-9 during the renders (frame pacing
  0.5-1.3 FPS vs P1-day's ~4); today's C++ build bakes 1,700,726
  satellite records vs P1's 196,196 (tooling note above).

## Coordinator triage — P2: the rule is live, it fills with fog not terrain as predicted, and the honest limiter is RESIDENCY (round 66)
- WHAT LANDED: `ac0451_covered(d)` is `u_coverage > 0.5 && d >= u_render_edge` in every near shader (the builder found TWELVE carrying the P1 stub, not the seven my plan listed — my count came from the P1 anchor set and was low), with `u_render_edge` pushed from `_ac0401_push` as `float(render_radius + 1) * 16.0`, change-gated, latched onto `_lod_avg_material`. No shared helper exists for that number, so the derivation is copied while the number is shared; recorded as a deviation rather than hidden.
- THE PREDICTION I WROTE BEFORE THE EDIT WAS CORRECT, which is the useful part: in the annulus the near fragments are already past `fog_depth_end`, so they render FULLY FOGGED — and measured, what fills the ring where geometry exists is THE ENV FOG COLOUR, uniformly, with no terrain appearing in the window and no see-through. Had terrain shown up, that would have meant the fog window had moved; it did not.
- GATE C IS CLEAN AND SHARP: ground-level ON vs OFF is **0 px**, byte-identical within the tree, exactly as expected because the annulus is out of frame from the ground. That is the check that would have caught a moved fog window.
- GATE A NEEDED THE ESCAPE HATCH I BUILT INTO THE PLAN AND STILL BARELY PASSED: aerial and edge views at COV0 differ from the P1 records by 587 px (0.06%) and 646 px (0.07%), which is 0.4% of P1's own 151,067-px no-op floor; the ground view differs by 32,512 px (3.53%) because the view crossed today's C++ rebuild boundary. The within-tree COV0 vs COV1 ground comparison is the one that is exactly 0. So the OFF path is unchanged WITHIN the tree, and the cross-run differences are the documented scene nondeterminism, not my change.
- THE HONEST LIMITER, and it reframes the ticket's value: at altitude only **704 px (0.08%)** changed, all in the inner annulus at d 332-370 m, because THE REST OF THE [332,400] m RING IS UNBUILT AT SHOT TIME — that is residency, which this ticket explicitly does not fix (AC-0399's half). So from the air, most of what the player sees through today is NOT the handover gap but missing chunks. The fix is correct where geometry exists; the remaining see-through is a fill-rate problem wearing the same symptom. The builder also notes R24 never settles at 0.5-1.3 FPS today, which corroborates that.
- NO FLICKER: the body's 2 m inward pull makes the near tier strictly closer, so the depth win is deterministic and the annulus boundary is a clean contour in every still.
- GATES: g0 0/0, genhash 25/25 byte-identical (a shader change moved no geometry), residency leak false / STABLE, planetwalk 25/26 with mesh and body.
- STATE: AC-0451's two phases are both landed — P1 inert-by-construction, P2 the rule live. The visible benefit is smaller than the ticket implied because the dominant cause of the aerial see-through is residency, not the handover. That belongs in the record and should shape what gets worked next: AC-0399 is the ticket that would actually close what the user saw.
