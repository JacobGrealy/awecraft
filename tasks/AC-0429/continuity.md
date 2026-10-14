## RUN - 2026-10-14 06:13 - AC-0429

- Fresh start (no prior entries). Read notes, ARCHITECTURE, AC-0428 + AC-0422 results, aero.gd, aero_sky_gradient.gdshader.

### Survey — what draws/imposes a lower boundary (all in `sky_on()`, aero_sky_gradient.gdshader)
Root cause: the model treats "below the local horizon (hl<0) or under the R+SEA disc" as a region with a DIFFERENT STATE (an air floor), instead of letting the sky be the space background everywhere and the planet+air the only content. Five things:
1. **below-branch air floor** `belowc = mix(mix(space,u_air,1-w), u_air, u_horizon)` — a flat pale u_air band below hl=0 = the skybox's bottom face (the main body).
2. **gradient horizon anchor** `horizon_eff = mix(horizon_color, u_air, w*u_horizon)` (AC-0428) — the upper gradient's lower edge anchored to the air colour; AC-0428's "step 0.00" made the two box halves the same colour, the boundary-as-structure remained.
3. **branch-switch band** `smoothstep(0,0.03,-hl)` (AC-0422) — a ~2deg blend band straddling the local horizon.
4. **horizon haze band** `exp(-|hl|*9)*haze_amount*(1-w)` — a bright band centred on the local horizon (a fake-horizon line, 20% weight at the user's w=0.8).
5. **thinning weight's horizon exemption** `thin = w*u` (AC-0428) — the local horizon is where the sky darkens LAST (the lower edge of the space transition).
NOT lower-boundary (untouched): the limb term (the planet's own air — becomes the ONLY boundary), the star field (full sphere, no bottom face), AeroWash (uniform, no edge), satellite body + cloud shells (the planet+air), env fog/fog wall (terrain), sky_off (the sky OFF state, byte-identical), and under_disc (w==0 there, provably a no-op).

### Implementation (5 code edits + 3 doc edits)
1. **Pre-edit baseline**: genhash ×2 → `.scratch/AC-0429-genhash-base1/2.log` (25 GENHASH lines each, rc=0, base1==base2, last `f037f94d...`). Tree is dirty with another session's work, so the baseline is the only valid genhash comparison point.
2. `aero_sky_gradient.gdshader`: new uniform `u_no_floor` (default 0.0 = pre-ticket path verbatim); in `sky_on()` only: `ws = smoothstep(0.0, 0.3, w)` after `w`; `anchor = mix(horizon_eff, mix(horizon_color, space_color, ws), u_no_floor)` keyed into `grad`; `belowc = mix(belowc, mix(u_air, space_color, ws), u_no_floor)`; haze `hz` × `mix(1.0, 1.0-ws, u_no_floor)`. UNTOUCHED: `thin = mix(mix(w*w,w,u)*1.0, w*u, u_horizon)` (AC-0428 uniform rate), `above`/`below`/`below_soft`, limb term, sun terms, `sky_off`. Seam at hl=0: above(0)=below(0−)=mix(u_air-ish, space, ws) — continuous for every w; |residual| = |horizon−u_air|·(1−ws), 0 from ws=1. w=0 ⇒ ws=0 ⇒ all mixes return pre-ticket values even with the switch ON.
3. `world.gd`: `_ac0429_nofloor := -1.0` state var; `AWECRAFT_NOSKYFLOOR` boot preload (no save); `_ac0401_push` block 2d pushes `u_no_floor` change-gated (block 2c = `u_horizon`/AC-0428).
4. `settings.gd`: DEFAULTS `"no_sky_floor": true` (user asked for ON) + `sanitize_bool` branch.
5. `menu.gd`: `no_sky_floor_check` CheckBox — var decl (after `cloud_gate_check`), row at slot hi+20 ("Sky: space below the horizon (the planet is the horizon)"), sync line, `_on_no_sky_floor_toggled` (set_value, no apply step owed — `_ac0401_push` pushes live).
6. Docs: ARCHITECTURE.md (Settings row §2 + sky-pass §3 note), HARNESS.md §2 env row `AWECRAFT_NOSKYFLOOR=0|1`. (HARNESS §1/§3 are GENERATED — §2 env table is hand-maintained, verified by marker scan.)

### Light gates (all run post-edit)
- **G0** `--headless --quit`: EXIT=0, SCRIPT ERROR 0 / SHADER ERROR 0 (census ok). Exit status checked per the UAF trap.
- **genhash ×2 post-edit**: 25/25 lines byte-identical to the pre-edit baseline (world.gd/settings.gd/menu.gd/shader touched, world hash untouched — expected: the change is render-only) and post1==post2 deterministic.
- **SMOKE** `player;interact;light;fluids;genhash`: EXIT=0, battery `"ok":true`, all 5 RESULT lines, census 0/0.
- **shaderforce** (Forward+/llvmpipe): EXIT=0, 12/12 ok, `aero_sky_gradient` declared=25 params=25 (the new uniform is declared + pushed), census 0/0. Boot line: `Vulkan 1.4.318 - Forward+ - llvmpipe`.

### Renders (all: HOME=/tmp/dsh_home, xvfb+lavapipe vulkan, 1280,720, T=0.5, R50, drain 60, no AWECRAFT_LOGIC, file-existence checked)
- `before-h800-horizon.png` (`AWECRAFT_CAM=planet AWECRAFT_CAM_HORIZON=1 AWECRAFT_SAT_ALT=800 AWECRAFT_NOSKYFLOOR=0`) + `after-h800-horizon.png` (default ON): the user's frame re-taken. RESULT live uniforms: `u_space_sky=0.799` (w=0.80, radial 941 m), `u_air=[208,241,251]`.
- `before-limb2000.png` / `after-limb2000.png` (limb aim = planet preset default, `AWECRAFT_SAT_ALT=2000`, w=1.0).
- `after-nadir900-gate0.png` / `after-nadir900-gate1.png` (nadir aim, 900 m, w=0.917; CLOUDGATE 0/1 for the cloud-variation diff).

### Measurements (tasks/AC-0429/measure.py — AC-0428 copy + new `limb` aim matching harness.gd's tangent contract)
- **User's frame, below-horizon band rows 380–520**: BEFORE 246.92–248.20 (spread 1.28 — flat pale u_air floor, the skybox's bottom face) → AFTER 0.00–0.00 (**spread 0.00**, flat space). Star-like pixels (lum>40) rows 360–680: **22981** in the AFTER frame — stars below the horizon; BEFORE the floor is uniformly >240 (stars buried in it).
- Step at the local-horizon row (359→360): 0.00 both (no line). AFTER max single-row step 25.67 at row 684→685 (31.0→56.7) = the planet's LIMB — the only boundary; BEFORE max step 5.91 (no real boundary — a flat wall).
- Limb2000 (w=1.0): sky pixels outside the disc+40 m margin = 135540 (both frames); BEFORE all 135540 lum>40 (the bright floor — zero stars visible), AFTER 2945 star-like (stars in black space).
- **Planet opaque** (disc, nadir900 after): body coverage 100.00%, LEAK 0.00% — same as AC-0428.
- **Cloud cover varies** (diff gate0 vs gate1, nadir900): 36.12% of inner-disc pixels differ (delta≥6), mean |dL| 8.80, max 124.72 — the AC-0428 gate still groups clouds.
- **Rate uniform**: `thin = w·u` line bit-identical to AC-0428 (untouched); after-frame upper-half profile is a smooth gradient (per-20-row band steps 0.08–1.5, no convex concentration near the top).

### Docs + page
- `plan.html` (written pre-edit), `measure.py`, captures/, `AC-0429-results.html` (self-contained, embedded PNGs + all numbers above).
- FENCES respected: main.gd / game.gd / drop.gd / debug.gd untouched; no TASKS.yaml hand edits; no commits. Heavy gates left to the coordinator.
