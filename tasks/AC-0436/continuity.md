
## RUN - Fri Oct 16 03:17:22 EDT 2026 - AC-0436

### Plan (03:17)
- Read the ticket + AC-0384 §29 assessment + the daynight/aero/cloud/sky/
  star/satellite code paths. Two causes to test by measurement (not assume):
  (1) the 0.20 night light floor dies in the tone mapping at 8 bits;
  (2) there is no moon as a light source at all.
- Wrote plan.html (the 7-component design: the moon as the sun's antipode,
  one-source MOON_L, per-consumer u_moon terms, the sky disc, the star
  size lift, the Options switch, the day-flatten guard).

### Implementation (03:20–06:40)
- **daynight.gd**: `MOON_L := 0.25` (one home) + the antipode direction
  convention comment (direction-TO-moon = `DayNight.sun_direction(t)`;
  its y > 0 exactly when the sun is below the horizon).
- **chunk_lit_{opaque,cutout,flower,fluid}.gdshader**: `u_moon` +
  `u_moon_dir` uniforms; `L += u_moon * max(dot(NORMAL, u_moon_dir), 0.0)`
  (the per-fragment lambert off the mesh face normals).
- **satellite_body.gdshader**: `u_moon`/`u_moon_dir`;
  `moon_l = clamp(dot(u_moon_dir, nrm) * INV_BAKE_SUN_RADIAL, 0, 1)`;
  the night factor gains `+ u_moon * moon_l`.
- **satellite_body.gd**: per-frame push (the relief_shading pattern);
  **BODY_MOON_SCALE := 8.0** (deviation, documented): the body is a LIT
  material — engine ambient (~0.20 at night) × its 0.18 shader floor ×
  the baked-dark night-side texels is a triple product the unshaded
  chunks don't have; MOON_L 0.25 alone leaves the moonlit hemisphere
  sub-threshold (~1/255, pipeline math), 8× lifts it to ~50/255.
- **cloud_layer.gdshader**: `u_moon_w` (the march re-aim gate 0..1),
  `u_moon`, `u_moon_dir`; `Ldir = mix(u_sun, u_moon_dir, u_moon_w)`
  (self-shadow + HG phase + forward-scatter follow the moon); volume
  `ALBEDO = u_cloud_tint * (u_day + u_moon) * clamp(...)`; deck
  `light = u_day - u_day_gain*(1-sun_l) + u_moon * moon_l`.
- **star.gdshader**: `u_star_lift` (0/1 switch) — the vertex-stage quad
  size lift `mix(UV2.x, 0.5 + 0.9*UV2.x, u_star_lift)` (the 500-star
  shell is a mesh fact — main.gd fenced — density comes from size).
- **aero_sky_gradient.gdshader**: `u_moon` disc flag (both sky_off/sky_on)
  — wider full-brightness window + full core at night; glow untouched.
- **world.gd**: `AWECRAFT_MOON=0|1` boot env preload (no save); the
  `_ac0436_*` push state vars; block (6) of `_ac0401_push`: the chunk /
  cloud / sky-disc / star pushes (change-gated; chunk gates on
  material-set size, the AC-0420 pattern). The sky disc flag is
  `sun_direction.y > 0.10` (the exact aero.gd flip test mirrored).
- **settings.gd**: `moonlight` DEFAULTS ON + sanitize_bool case.
- **menu.gd**: the Options row "Sky: moonlight at night" + handler + sync.
- **ARCHITECTURE.md**: the AC-0436 §3 bullet + the §2 Settings clause
  (invariant 2, same task).

### Deviations from plan.html (recorded in both)
- **NO MoonLight DirectionalLight3D node** (plan component 6 dropped):
  the unshaded chunk shaders never see engine lights, and a node would
  double-light the LIT satellite body (engine ambient × its u_day). The
  moon IS the shader terms; lit materials keep the 0.25 ambient at night
  (never the reported defect).
- **The moon halo stays at amount 0.3** (the 0.3→0.45 aero.gd bump was
  dropped): it would have broken the bit-identical OFF state (aero.gd is
  switch-blind by design — a core pure-logic helper).
- MOON_L calibrated 0.40 → **0.25** after the pipeline math (0.40 put
  the night top faces at ~80% of day — dusk, not night).

### BEFORE baseline (04:17–04:19, tree as found: fence hunks, no
AC-0436 code — the fence hunks proven render-invisible)
- `ac0436-before-ground-horizon-night.png`: near_ground luma **4.01**
  (frac<20 = 0.907), sky max 195.8, stars 233, brightest_nonUI 255.
- `ac0436-before-2600-night.png`: planet luma **3.04** (frac<20 = 0.927),
  stars 68. — EXACTLY the AC-0384 §29 assessment references (4.01 / 3.04
  / 68): the before frames reproduce the filed defect.

### Gates (light set, all PASS)
- G0 (headless): exit 0, SCRIPT ERROR 0, SHADER ERROR 0.
- shaderforce: 12/12 verdict=ok (every shipped .gdshader forced through
  live Forward+), exit 0, Forward+ boot line present.
- SMOKE battery `player;interact;light;fluids;genhash`: RESULT ok:true,
  exit 0; **genhash 25/25** (the world/* touch — no drift, the expected
  result: generation code untouched).
- PROBE: meshprobe match_rate 1.0 (verts 277720/277720, 32/32 chunks,
  0 mismatches); lightstate clean (leaks 0 every chunk, worst null,
  wash false, double-LOD census 0/0, arr_diff_cells 1 = the documented
  AC-0311 one-cell fixture, stragglers 0).

### After frames (06:45–07:21, the working tree WITH the AC-0436 code)
- capture_after.sh (job bash-935): 6 frames, ALL rc=0, fwd=1, fog
  332/400, err=0, SNAP present (the before/after recipe, r24).

### MEASUREMENTS (the acceptance census)
- **Night ground** (near-ground band y440–600): luma **4.01 → 13.17**
  (3.3×), green 4.0 → 16.5, frac<20 0.907 → 0.869. The frame reads as
  terrain (the stepped bank, trees, the stone block, mobs, flowers —
  directional top-lit/side-dark slopes), not a void.
- **Day ground** (the flatten guard): **98.41 → 98.41 — bit-identical**
  (0.00 shift, the gate is >2/255 = fail). Day is untouched by
  construction (every moon term ×0.0 at day) and by measurement.
- **Night orbit planet**: luma **3.04 → 46.71** (15×), frac<20
  0.927 → 0.432, frac>80 0 → 0.196. Reads as a world: green terrain,
  tan patches, white clouds, blue water, the dark anti-moon limb.
- **Day orbit planet**: **139.58 → 139.58** — the assessment reference
  EXACTLY (the day orbit is also bit-identical).
- **Stars** (luma-40 components in the sky region): ground sky
  **233 → 441** (1.9×); orbit top-sky **68 → 103**; the day orbit
  space shows 4240 components (the size lift also helps the day-space
  star field — the "stars are an orbit instrument" note, AC-0417).
- **Interface no longer the brightest object**: the red stat row
  (~89/255) is now far below the scene content in every frame (terrain
  up to ~100, stars 198.8 ground / 255 orbit, the moon disc ~255 in the
  ground-up frame). Note, honestly: in the ground-horizon frame the
  hotbar's 1-px WHITE BORDER (255 @ (414,702) — a border, not an
  object; present in the before frame too) still tops the 198.8 sky
  max of that specific frame.
- **A/B (AWECRAFT_MOON=0)**: the orbit night frame is **PIXEL-IDENTICAL
  to the pre-AC-0436 before frame** (57,600-px sample, 0 differing
  pixels; the PNGs are the same size to the byte). OFF = the exact
  filed-defect look, the contract holds by measurement.
- **The moon, shown**: ground-up-night (the r24 pitch-1.3 recipe):
  the full moon disc (wider window + full core, the pale-blue halo) at
  68° elevation — the ~6-px dot is gone.

### Results
- AC-0436-results.html written (the self-contained evidence page:
  cause verdicts, the component table, the census, the gates, the
  deliberate non-actions, the tree state).
- VERDICT: **PASS** — all acceptance items measured; the day guard
  holds at 0.00; the light gates all green; the heavy gates are the
  coordinator's.
