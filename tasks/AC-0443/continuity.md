## RUN - Sat Oct 17 07:59:39 EDT 2026 - AC-0443

## AC-0443 progress — attribution + fix (Sat Oct 17)

### Attribution (analytic, render-confirmed)
- **Occupant**: the west-facing side flank of the BAND B (8x8x8 avg-LOD,
  `lod_avg.gdshader`, ring sector 37) ridge column, ~120-135 m out at the
  right horizon (flat ≈ (−45..−52, 142..154, −100..−125), chunks (−2,−7) /
  (−3,−6..−8) — taxi 9+ = band B; h-only data, block data not landed there).
- **Edges**: top y≈375 = ridge top H≈147 (ray-tangent line; above = sky);
  left x≈1192 = the 29 m tree's canopy silhouette (probe near-hit block 7 at
  (−7,143,−17), t≈29 m); right = frame edge.
- **Darkness mechanism** (colour model verified to ±a few units):
  `lit = mix(0.2, 1.0, COLOR.a)` with COLOR.a=0 (side face "at/below terrain
  top") → 0.2 cave floor; west face has zero sun lambert at noon; the
  material is SHADED (engine ambient 0.65·sky ≈ 0.58 only); day=0.7529;
  fog ≈ 4% at 130 m. (51,51,51)→(40,35,30); (38,31,9)→(30,26,15)+fog ≈
  observed (30,27,23) ✓.
- **Parity break**: the same cliff face on the BAND A side of the tier seam
  (taxi ≤ 8, chunk_lit UNSHADED + AC-0426 lift L≈0.55) reads ~(135,116,103)
  — a 3.5× step at the seam. The AC-0432 "unlit terrain = shaded not black"
  collapse was fixed for the chunk tiers and never crossed the tier seam.
- **Clouds RULED OUT by render**: r2-cloudoff (AWECRAFT_CLOUDS=0) patch box
  (29,29,27) byte-identical to r1-base (29,27,29→27) and r3-shell (29,29,27).
  Sky band above the ridge also cloud-independent.
- **Repro**: r1-base (current tree, drain-9000, SNAPDRAIN_TIMEOUT = same
  mid-build capture state as r24's drain-3000) reproduces the patch at the
  same pixels: box avg (29,29,27) vs r24 (34,35,34).

### Fix (applied, pre-render)
- `godot/core/lod_avg.gdshader`: `uniform float u_amb = 0.0` +
  `lit += u_amb * day.r * (1.0 - COLOR.a)` (AC-0426 parity lift; OFF /
  night bit-identical; a=0 faces only).
- `godot/world/world.gd`: latch var `_ac0443_lod_amb` + push in the (1b)
  `_ac0401_push` block (same AMB_SKY_L / ambient_sky seam as the chunks;
  lazy material → latch-only-when-landed).
- Prediction: patch box (29,29,27) → ~(58,48,40) at noon; a=0 faces only;
  a=1 (top) faces and OFF state bit-identical.

### Render battery v3 (absolute paths, SNAP_DRAIN=9000) — status
- r1-base DONE (drain TIMEOUT = mid-build, the r24-equivalent state).
- r2-cloudoff DONE — patch byte-identical (clouds out).
- r3-shell DONE — patch byte-identical (shells out, volume→3-shell).
- r4-close RUNNING — second view from the ridge's east flank
  (AIM −20,150,−60 / yaw 0.566 / pitch −0.058 → the band cliff face ~52 m out,
  dead centre).
- NEXT: r5-fix render (same AIM as r1, post-fix) → patch must brighten to
  ~(55-75) with nothing else moving; then G0/SMOKE/PROBE/genhash 25/25
  (world.gd touched)/shaderforce (shader touched); remove the ac0443probe
  arm (pristine); final gates; results page.

### Trap log (this run)
- `env.fog_curve` does not exist on Environment in this engine build —
  property is `fog_depth_curve` (float); dump via get_property_list instead.
- The probe's first two addenda surveyed the WRONG quadrant (−X fwd chunks);
  the patch lives at −Z right-edge (wall flat ≈ (−30,147,−104), chunks
  (−2,−7)/(−2,−6)). Always recompute the wall position from the ray, not
  from the ticket's azimuth words.
- r1/r2/r3 all hit SNAPDRAIN_TIMEOUT even at 9000 frames — the R24 build
  does not finish on this box within the render budget; every r24-frame
  comparison MUST use the mid-build state (this is a faithful r24-equivalent
  capture, and the attribution is state-independent: the band flank exists in
  the fully-built world too — band B owns taxi 9..23 permanently).

## AC-0443 CLOSEOUT (Sat Oct 17 ~13:40)

- **Attribution**: legitimate object (real terrain — the NW ridge's west flank at
  120–135 m, BAND B 8x8x8 avg-LOD, ring:37, h-only data) rendered at the 0.2
  cave floor (a=0 side face + no sun lambert at noon + ambient only) = the
  AC-0432 collapse past the tier seam. Edges matched per AC-0440 (top = ridge
  crest H≈147, left = 29 m tree silhouette, right = frame clip, bottom =
  sheep/ground). Clouds render-eliminated (r2/r3 byte-identical). r1-base
  reproduces the patch on the current tree: (29,29,27) vs r24 (34,35,34).
- **Fix**: lod_avg.gdshader `u_amb` + `lit += u_amb*day.r*(1.0-COLOR.a)`;
  world.gd pushes AMB_SKY_L/ambient_sky to the band material in the AC-0426
  seam (latch `_ac0443_lod_amb`, lazy-material safe). A/B same pose:
  (29,29,27) → (50,40,31); 0.9% of frame moved, all band a=0 faces; OFF/night
  bit-identical.
- **Gates (post-fix, post arm-removal)**: G0 rc=0 0/0 · SMOKE ok:true 0/0 ·
  genhash 25/25 byte-identical · meshprobe ok match 1.0 32/32 0/0 ·
  shaderforce 12/12 (lod_avg declared=3/params=3) 0/0. Heavy standing set
  (farab/ladder/halo/lightstate/r16/boundary r4) = coordinator's job —
  structurally untouched (no C++/mesh/data/bake).
- **Pristine**: ac0443probe arm REMOVED from harness.gd (dispatch + 470-line
  function block; grep -c ac0443 = 0). harness.gd = 35714 lines.
- **Deliverables**: tasks/AC-0443/AC-0443-results.html (self-contained) +
  captures/ (r24-original, r1-base-pre-fix, r2-cloudoff, r4-close-second-view,
  r5-post-fix, r6-west-angled-view, crops, compare-patch-strip); plan.html
  updated with the final attribution; no commit (coordinator's closeout).
- **Deliberately not done** (see results §8): emit-side sky-exposure flag
  (the honest follow-up ticket), full 3.5× parity lift (unmeasured constant),
  commit/push, the pre-existing muted teal sky band above the ridge
  (sky-shader output, cloud-independent, separate tree difference).
