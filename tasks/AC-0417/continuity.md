
## RUN - Sat Oct 10 21:41:01 EDT 2026 - AC-0417

### Pre-change re-measurement (current tree, d3f07c1 + 4 fenced WIP files)
- G0: exit 0, SCRIPT 0 / SHADER 0 (`.scratch/AC-0417/g0-before.log`).
- genhash baseline: 25/25 (`.scratch/AC-0417/genhash-before.log`, GENHASH xz lines — save, compare post).
- shaderforce: 12/12 ok, failed:[] (`.scratch/AC-0417/shaderforce-before.log`).
- measure.py built + synthetic-validated: the sky forward model (both current and AC-0417
  forms) + Forward+ pipeline (pow2.2 → exposure 0.85 → ACES → contrast 1.1 → sat 1.25 → sRGB)
  reproduces model-painted frames bit-exactly (delta 0.0); the ring intercept fit recovers the
  background exactly (residuals < 0.004 lin). Geometry: spawn radius R+142 (preset "alt" param
  is distance along the radial, true alt = param + 142); B position = AWECRAFT_CAM_OFF=5600,0
  (in-plane 3220 m at the R-sphere foot — 79 m past the 3141 m face edge; tilt 53.6°);
  F1 pair rendered at equal TRUE altitudes (A@700≡B@842≡842 m; A@1058≡B@1200≡1200 m).
- Ring (gap) geometry at R24: the annulus (body op 0→1, d ∈ [332,400]) exists only while
  nadir_d < 400, i.e. true alt < 526 (param < 384); the pure-background disc center (op 0,
  d < 332) exists while true alt < 458 (param < 316). Nadir renders: param 200/260/300.
- Pending: smoke, farab, satellite, farhigh (pre), 6 BEFORE renders, then implementation.

### Pre-change gates (all green, exit 0)
- SMOKE battery `player;interact;light;fluids;genhash`: `"ok": true` (258 s; the battery
  mode has NO --quit — a --quit run exits after the first frame with no battery output).
- farab: `h_mismatch 0`, slab_cmp 1080/1080 both grids, mat_surf_diff 0 (water census
  6/7/28 vs the doc's 4/5/20 — the current-tree baseline; report-only fields).
- satellite (r4): ok — thresholds fog_far 69.6 / edge 80 / h_first 126.59 / h_full 206,
  ladder hidden/rim/dissolve/full green, geom ok, ac0390 ok, height_decode ok.
- farhigh R16: ok — leg1 h_ident 0, leg2 facet_cols 3/3 flat 0 max_dev 0.0 (AC-0416 holds),
  leg3 body_fit_max 0.197 body_excess 0.0.

### Render mechanics (measured this run)
- **R24 on llvmpipe ≈ 0.5 FPS** (B1: a 600-frame drain + the 300-frame floor wait never
  finished a 1200 s wall; game time runs 1.0x wall). Drain 120 + timeout 1200 = the recipe
  now (.scratch/AC-0417/render.sh); the measured regions (sky pass stateless, body LOADED
  before the drain) do not need the long settle — the drain covers the far ring's first fill.
- harness.gd planet preset extended (env-gated, unset = byte-identical): AWECRAFT_CAM_OFF
  (tangent offset projected onto the R sphere), AWECRAFT_CAM_NADIR (nadir aim, horizontal
  up hint), RESULT gains the live sky uniforms + cam_off/nadir (u_air guarded by
  has_shader_parameter so the pre-change RESULT shape is unchanged). Parse-checked 0/0.
  One real bug caught by the parse check: Vector3 members are x/y/z (the first draft used
  .r/.g/.b — 8 SCRIPT ERROR lines, fixed).

### Post-change (AC-0417 implementation, this run)
- Code (7 files, the fenced 4 untouched): aero.gd (ATMOSPHERE_HEIGHT=1200, atmosphere_height()
  env AWECRAFT_ATMO, sky_space(), atmo_limb_radius/falloff(), fog_display_srgb(); fog_display
  refactored to it — bit-identical), aero_sky_gradient.gdshader (u_air/u_atmo_radius/u_atmo_falloff;
  sky() split sky_off (pre-AC-0402 VERBATIM) / sky_on (local zenith hl, two colours + one cone,
  limb at the A shell with 0.25A falloff, A-window gates, glow ×(1−u_space_sky))),
  star.gdshader (u_sky_alt/u_space_sky/u_night; ALPHA = shape·mix(u_opacity, mix(u_night,1,
  u_space_sky), u_sky_alt)·occl), cloud_layer.gdshader (addendum 2: ac0417_wash() — the same
  air colour u_vol_air + impact-parameter haze, gated ±0.4·falloff on camera radius, u_limb_wash
  switch), world.gd (_ac0401_push: A window replaces the AC-0402 band; atmo pair to sky AND
  clouds; wash; star uniforms via Stars material_override; u_air display 8-bit; cloud-tops-
  inside-A assert), satellite_body.gd (h_full = A diagnostic; h_first comment — deviation D1:
  re-derive would be 1211 m > A → full-opacity rim pop).
- harness.gd: one more bug caught by a real render (not the parse check): get_shader_parameter
  returns a COLOR for a Color-pushed vec3 uniform — `var pa: Vector3 = ...` aborted run() before
  RESULT/snap (the render then idled to timeout). Fixed (Color/Vector3 dual path) + the planet
  RESULT gains the ORIGINAL spawn (pre-offset projection) for the measurement side.
- AFTER gates (all green): G0 exit 0 / 0-0; genhash 25/25 byte-identical (GENMS 125→127);
  shaderforce 12/12 failed:[] (sky 23 / star 9 / cloud 35 params); farab h_mismatch 0, slab_cmp
  1080, mat_surf_diff 0; satellite ok (h_full 1200 diagnostic, ladder green, "full" h=1300 →
  nadir_d 1174); farhigh R16 leg2 3/3 all-FACET max_dev 0.0; SMOKE ok true (259 s).
- Renders (drain 60, timeout 1200, one godot at a time): A1/A2 (F1 pair, 841/842 m), A5 (nadir
  341), aL500/aL900 (641/1041), A10 (1341 clouds ON — space + stars + wash), A11 (ground), and
  B10 (BEFORE at 1341 clouds ON — rendered via a TEMPORARY `git stash push` of the 7 code files,
  render, `git stash pop`; the before tree was verified-consistent pre-stash and the pop restored
  all 7 files + left the fenced 4 untouched; no commits/pushes).
- Measurements (tasks/AC-0417/measure.py — 1:1 port of both sky forms + the Forward+ chain;
  model-vs-pixel medians 11–22/255): F1 top-20s BEFORE A (210,250,255) vs B (0,67,252) — Δ(210,183,3)
  the fake horizon; AFTER A (0,5,17) vs B (0,42,63) — Δ(0,37,46), reproduced by the model's
  fixed-sun term (model Δ (29,45,46)). F2 pushed-uniform ladder (AFTER): 0.0060/0.3219/0.6496/
  0.9174/1.0000 at 341/641/841/1041/1341 (stars ≡ window at day); BEFORE: 0.0438 @841, 0.4396
  @1741 (still 44% air past where the body is "fully established"). F3: the nadir annulus is
  SEA-occluded (visible (131,205,205)/(132,207,205) — terrain behind the gap; stated finding);
  the sky BEHIND it: (123,149,154) dark branch → (211,228,232) ≈ air (208,241,251) ✓ haze not black.
  Clause D @1341: BEFORE rim 50.58° < deck top 56.43° (deck exceeds rim by 5.85°); AFTER rim
  (R+A) 76.81° > deck (inside by 20.38°); glow 0.625 at the local horizon. Deck band wash:
  (98,151,160) → (82,199,227).
- Docs synced: ARCHITECTURE.md (sky path redefined + clause D + addendum 2 + Stars + world seam
  + the §4 AC-0417 bullet), HARNESS.md §2 (planet preset envs + RESULT spawn/sky; drain note
  corrected to 60; spawn radius 141 m not 142). Captures: tasks/AC-0417/captures/ (12 PNGs).
  Results page: tasks/AC-0417/AC-0417-results.html.
- Stated deviations (also on the results page): D1 h_first fog-derived (1211 m pop math);
  op_nadir fog-driven (1.0 at 526 m, not at A — the fog wall stays render-distance-coupled,
  the ticket's own requirement); star day opacity = the A window (orbit instrument); u_air
  display-space in the sky pass, linear elsewhere (one 8-bit source).
