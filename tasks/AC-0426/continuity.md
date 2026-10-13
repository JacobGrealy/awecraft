## RUN - Tue 2026-10-13 06:05:43 EDT - AC-0426

- Resumed docs read: TASKS.yaml AC-0426 notes, AC-0425 results (the f1 blob frame, the
  measured mechanism, the fingerprint), CONTINUITY.md top (r26), ARCHITECTURE.md (conventions
  + the AC-0128/AC-0135/AC-0204 lighting design + the look-change pattern), HARNESS.md
  (2/4/5), OPS.md, world/AGENTS.md, gdext/AGENTS.md, scenes/AGENTS.md (harness.gd PRISTINE).
- Lighting chain located: bake = C++ (gdext/src/mesh.cpp light_color -> vColor r=sky s,
  g=block-light, b=faceShade); display = the 4 chunk_lit_*.gdshader unlit formula
  `L = 0.20 + 0.80*max(u_day*s, g)` (AC-0128 structure, user-directed 0.20 floor).
  u_day = DayNight.day(t) pushed per frame (chunk.gd set_day_factor): exactly 0.0 at night,
  1.0 at noon. Tree shape (gen.cpp veg pass): log trunk tth 4-6, crown = 5x5-minus-corners
  leaf rings at the top two log layers -> the top 2 log cells are fully ring-enclosed by
  leaves, their side faces sample s=0,g=0 -> L=0.20 at ALL times of day ->
  tex*faceShade*0.20 sub-8-bit on the dark atlas cells (measured: log min (56,43,24),
  leaf tinted p25 lum 0) -> the black silhouette.
- CHOSEN FIX (ticket option 2 + time-of-day): additive sky-ambient term for zero-light faces
  only: `L += u_amb * u_day * (1.0 - step(0.0, max(u_day*s, g)))`, u_amb default 0.0 (off =
  bit-identical: 0*x=0, x+0=x; night u_day=0 -> term exactly 0.0 -> night bit-identical).
  0.20 floor untouched. Switch = the project look-change pattern: Settings bool
  `ambient_sky` default false + AWECRAFT_AMBSKY=0|1 boot env (no save) + change-gated push
  in world.gd _ac0401_push + shader uniform default 0.0. Files: 4 shaders, world.gd,
  settings.gd, menu.gd, HARNESS.md 2, ARCHITECTURE.md. No fenced file touched;
  harness.gd untouched (no new arm; genhash/PROBE/SMOKE/G0/shaderforce + 5 Forward+ renders
  carry the evidence).
- Render plan (all Forward+ recipe, 1280,720, R24, default boot camera = the AC-0425 f1 view,
  1200 s budget each): (1) BEFORE-day at HEAD, no env; (2) AFTER-off-day (new code, switch
  off) must be pixel-identical to (1) [off-state proof]; (3) AFTER-on-day [acceptance];
  (4) AFTER-off-night (AWECRAFT_TIME=0.0); (5) AFTER-on-night must be pixel-identical to (4)
  [night check]. Plus AWECRAFT_MENU_SHOT options view (the row, default off).

## GATES (post-edit, light set)
- BEFORE-day render (HEAD, no env, Forward+ R24 1280,720): RC=0, SNAP ok,
  blob reproduces the AC-0425 f1 published frame PIXEL-EXACT in the tree
  region (0/12750 px differ at x 690-860, y 0-75; the 1.26% frame-wide diff
  is the sky/body region above the horizon = shot-moment state). Baseline:
  67.9% exact-black in the blob region.
- G0: RC=0, gate_census SCRIPT ERROR 0 / SHADER ERROR 0.
- PROBE: RC=0, RESULT ok (biomes 4, spawn_h 141.0 — the standing values).
- SMOKE (player;interact;light;fluids;genhash): RC=0, ok:true; player start
  [8.78,140.98,8.78] jump 142.42, fluids 1719/1719 stable, light 0/15/14 —
  byte-equal to AC-0425's own smoke run on this tree.
- GENHASH standalone: RC=0, 25/25 BYTE-IDENTICAL to
  .scratch/AC-0425/genhash-final.log (the pre-edit baseline).
- SHADERFORCE (fwdshot): RC=0, 12/12 verdict ok (the four edited chunk
  shaders compile with the new u_amb uniform; Forward+ boot line present).
- Fenced files: mtimes pre-date the session (main.gd 10-06, game.gd 10-02,
  debug.gd 10-03, drop.gd 10-02, TASKS.yaml 06:03 = the filing) — untouched.

## EDIT LOG (this run)
- 4 chunk_lit_*.gdshader: u_amb uniform (default 0.0) + L += u_amb * u_day
  * (1.0 - step(0.0, max(u_day*COLOR.r, COLOR.g))); contract comment in
  opaque (the reference shader).
- world.gd: const AMB_SKY_L = 0.35; state vars _ac0426_amb/_ac0426_n_mats;
  AWECRAFT_AMBSKY boot env preload (no save, after the SKYHORIZON block);
  (1b) change-gated push in _ac0401_push (value + material-set-size gate).
- settings.gd: "ambient_sky": false default + sanitize_bool clamp.
- menu.gd: AmbientSkyCheck row (after relief), sync line, _on_ambient_sky_toggled.
- HARNESS.md 2: AWECRAFT_AMBSKY row. ARCHITECTURE.md: AC-0426 entry in the
  Settings autoload row.
- Renders pending: after-off-day (running), after-on-day, after-off-night,
  after-on-night, menu shot (options).

## OFF-STATE PROOF (after-off-day vs before-day, same recipe, new code, switch OFF)
- Tree/blob region (x 690-860, y 0-75): 0/12750 px - EXACT.
- Everything below the horizon (y >= 176): 1/696320 px - a single 1-LSB red flip at
  (1130,179), a far-tier horizon-band streaming transient (the off term is 0.0 *exactly*,
  so no light value can differ; the world state at shot time moved one far pixel).
- Above the horizon (sky/far tier/body): 12471 px, max delta 255 - the same
  shot-moment world-state class measured when the BEFORE frame was compared against the
  published AC-0425 f1 (1.26% there too, same top band): far-tier vs body-haz handoff at
  the shot frame. NOT a code effect: the off state adds 0.0 bit-for-bit.
- Off-state blob exact-black fraction 0.679 = the BEFORE value.

## DEVIATION - mask bug found by the A/B measurement (fixed)
- First-pass mask `1.0 - step(0.0, m_direct)` is ALWAYS 0.0: m_direct =
  max(u_day*s, g) is non-negative by construction, and step(0.0, x) = 1.0 for
  every x >= 0. The added term was dead; the after-on-day render came out
  byte-equal to before-day (blob stats identical) - the measurement caught it
  before any claim was made.
- Fix: mask = step(m_direct, 0.0) (1.0 iff m_direct is exactly zero) in all
  four shaders; doc references (ARCHITECTURE.md, results, plan) updated.
- Off-state bit-identity argument unaffected (the term carries the factor
  u_amb = 0.0 either way: 0.0 * x = 0.0, x + 0.0 = x).
- Gates re-run on the final tree state after the fix (G0, PROBE, SMOKE,
  GENHASH, SHADERFORCE), then the ON render re-shot.

## DEVIATION 2 - AC-0425 premise wrong: the light scalar has a floor (mask re-targeted)
- The fixed strict-zero mask still produced a byte-identical ON render
  (probe R4, blob 0/12750) with u_amb = 0.35 proven on all three lit
  materials at snap time (AMBPROBE timeline_tail) - the term evaluated
  to 0.0 on every trunk pixel. The push chain, the compile, the mask
  direction were all verified working; the condition simply never held.
- Root cause (measured): `chunk.gd:995` clamps the face light scalar to
  `clampf(v/15, MIN_AMB, 1.0)` with `MIN_AMB = 0.08` (chunk.gd:5,
  mesh.cpp:117). An unlit face therefore NEVER stores s = 0 - it stores
  the floor, which reads 20/255 = 0.0784 after the 8-bit vertex-colour
  packing. AMBPROBE2 (temporary arm, removed at closeout) walked the
  built R4 tree column: 4,461 opaque vertices within 5 m of (12,-45),
  ZERO with r = 0.0, r_min = exactly 20/255; g = 0.0 everywhere (no
  block light); y-buckets: ground under the crown (y=-1, n=385) and the
  whole trunk/inner-crown band (y=12..43) sit at the floor, only the
  outer-crown faces climb to full pull (up to 1.0). AC-0425's "s = 0"
  was the conceptual model (the column's sky is occluded) - the
  implementation floors the scalar at 0.08, so "zero light" is
  unreachable and step(m_direct, 0.0) can never fire.
- Fix: mask = step(m_direct, 0.08) in all four chunk_lit_* shaders -
  1.0 iff m_direct <= MIN_AMB, i.e. the face is AT the floor
  (sky pull level <= 1 or no block light): "effectively unlit". 0.08 is
  the light-layer constant itself, not a new tunable; the floor is
  deterministic (round(0.08*255) = 20), so 20/255 < 0.08 holds exactly.
  Faces with real pull (>= 21/255) are untouched - including the
  25/255 = 0.098 faces of the floating structure the probe column also
  sampled (y=143..144), which a wider threshold would have lifted.
- Night guarantee unchanged: u_day = 0.0 exactly at AWECRAFT_TIME=0.0
  (DayNight.day(0.0) = clamp((sin(-pi/2)+0.12)/0.35, 0, 1) = 0.0), so
  the term is 0.0 at night even ON. Off state unchanged: u_amb = 0.0 ->
  0.0 * x = 0.0 exactly, mask value irrelevant.
- Night frame triage (probe R4, ticket deliverable either way): night
  ON vs OFF = 16,163 px full-frame, of which 14,442 are the far-field
  shot-moment class (top-right far tier/body) and 9 are canopy-edge
  streaming transients at (690-691, 0-5) (ON (0,58,4) - a far-tier/sky
  read-through the cutout gaps, not a chunk-formula output - vs OFF
  (0,0,0)); blob proper otherwise exact. The day red-tail census
  (canopy band y 0-30: 1,297 px; trunk band y 30-70: 455 px, R 1-12)
  falls to (0,0,0) at night, consistent with m_direct > 0 on those
  faces (the pull never floors to 0 on lit-adjacent faces) - the trunk
  band's black core (8,661 px) is the floor faces the mask now targets.
- Gates re-run on the re-targeted tree (G0, SHADERFORCE green 12/12,
  census 0/0 both), then the probe ON frame re-shot and measured.

## CLOSEOUT (final tree state)
- Harness PRISTINE: all three temporary arms removed (AMBPROBE timeline arm
  lines 116-154, AMBPROBE2 mesh-dump arm lines 155-223, AMBSHADER gate
  lines 224-235, plus _amb_probe_mesh() and _ambshader_test() at the tail)
  - 272 lines out, 0 parse errors on --check-only, G0 re-run clean
  (SCRIPT ERROR 0 / SHADER ERROR 0, clean run to timeout-kill).
- Gates on the FINAL tree (floor mask step(m_direct, 0.08), arms removed):
  G0 census 0/0 (g0-final3); GENHASH RC=0, 25/25 byte-identical to
  .scratch/AC-0425/genhash-final.log (genhash-final2); SHADERFORCE RC=0
  12/12 ok, chunk_lit family declared=8, census 0/0 (shaderforce-final2).
  PROBE + SMOKE were green earlier and are logic arms (unaffected by the
  display-side mask constant).
- Final R24 frames (all Forward+ llvmpipe, boot camera, seed 44):
  after-on-day (12:08), after-on-night (12:11), after-off-night (12:13);
  after-off-day + before-day from the earlier pair (off state bit-identical
  to before by IEEE - u_amb = 0.0 kills the term regardless of mask).
- Acceptance (R24, blob x 690-860 y 0-75): before = 8661 exact-black
  (67.9%), red tail 1752, mean lum 5.31; after-ON = 7374 exact-black
  (57.8%), red tail 2193, mean lum 6.06, 1320 px lifted (bark pixels e.g.
  (44,15,0), leaves (7,56,0) where they read (0,0,0)); after-OFF vs before
  = 0/12750 EXACT. Ground band (y >= 176): 0 px differ (no flattening).
  Trunk rows y 30-64 all lift (+0.47..+1.71 mean lum); lit ground
  (y >= 70) untouched.
- Night check (R24): ON vs OFF = 9794 px, ALL in the y < 200 sky/far-field
  shot-moment band (the standing class, on-brighter); near tier (y >= 200)
  bit-identical (0 px); blob 23 px = the 2-px canopy-edge green strip
  (x 858-859) read through the cutout gaps - the R4 probe pair showed the
  identical transient class. u_day = 0.0 exactly at midnight kills the term
  by construction.
- Results page fully filled: tasks/AC-0426/AC-0426-results.html (both
  deviations recorded with the measurement trail; §4-§7 from the final
  frames). plan.html refreshed (formula + deviation 2). ARCHITECTURE.md +
  HARNESS.md in sync.
- Fence check: git status shows only this task's files (4 shaders,
  world.gd, settings.gd, menu.gd, HARNESS.md, ARCHITECTURE.md,
  tasks/AC-0426/) + the other sessions' pre-existing dirty files
  (main.gd, game.gd, drop.gd, debug.gd, AC-0067/*, AC-0384/*) - untouched
  by this task. No commit/push (fence).
