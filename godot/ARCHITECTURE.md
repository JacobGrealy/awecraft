# AweCraft — architecture

What the game is made of, and the conventions that don't change per task. Every structural
claim here was verified against the tree at **AC-0298** (2026-09-16); line counts and file
lists drift, the *shape* is the contract.

**If a task changes the structure — a new autoload, a moved/renamed component, a new
subsystem, a changed data or save format, a new native layer, a changed convention — it
updates this file in the same task.** That rule is standing; see invariant 2 in `AGENTS.md`.

Detail lives elsewhere by design:

| Topic | Owner |
|---|---|
| scope rules for a directory (auto-loaded when you touch a file there) | that directory's `AGENTS.md` |
| test arms, battery, standing gate values, run recipes | `godot/HARNESS.md` |
| machine, sandbox, daemons, build/serve | `godot/OPS.md` |
| current state, resume steps | `godot/CONTINUITY.md` |
| delegation, gates, closeout | the project skills in `.dsh/skills/`, `COORDINATOR.md`, the builder prompts in `tasks/templates/` |
| world generation & streaming internals | `docs/worldgen-current.html` |

## 1. Shape

- Godot project root is **`godot/`**; always run from the repo root with `--path godot`.
  Engine `~/tools/godot/godot` = **4.7.1.stable.official.a13da4feb**.
- **GDScript** for game logic; **C++ GDExtension** (`gdext/`) for the hot paths. §4.
- The product is **Windows-only** (AC-0124). This Linux box is for development and headless
  verification; the user playtests a stamped Windows build over the LAN.
- Size at AC-0298: ~47.9k lines of GDScript in 34 files, ~7.8k lines of C++ in `gdext/src/`.
  It is heavily concentrated — `scenes/harness.gd` (23.0k, the test arms) and
  `world/world.gd` (11.0k, streaming/scheduling) are ~70% of the GDScript. Splitting those
  monoliths is tracked as AC-0115.

## 2. Autoloads

Registered in `godot/project.godot`, **exactly in this order**, six of them:

| # | Name | File | Owns |
|---|---|---|---|
| 1 | `Game` | `autoload/game.gd` | global state: `mode` (menu/play/pause/crash), `dimension`, `world_seed`, `time_of_day`, `planet_R`; the live `world`/`player`/`drops`/`entities`/`hotbar`/`console` handles; the native-extension presence check (`cpp_ext_ok`/`cpp_ext_missing`); `new_world()`/`start()`/`message()`; cursor mode |
| 2 | `Data` | `autoload/data.gd` | all tables + lookups: world constants (`CHUNK` 16, `HEIGHT` 384, `SEA` 126), block/item/mob tables (AC-0141/AC-0142: loaded in `_init` from `res://data/blocks.json` + `items.json` + `mobs.json` by `_load_table` — mobs load with `int_keys=false`, name-keyed — §5), recipe tables, atlas rects, colours, crafting match |
| 3 | `Audio` | `autoload/audio.gd` | the procedural sound layer (AC-0039 — §6): 9 synthesized voices cached at startup, the 16-voice SFX pool, the ambient bed player (toggleable, default OFF — AC-0389, `Audio.set_ambient`), `play(name)` + the alias table; the `sound` arm asserts the generated buffers under the dummy driver |
| 4 | `Debug` | `autoload/debug.gd` | the headless test API (§6 of this file lists its shape), plus `error()`/crash capture with the modal dialog, session logs, `bug_report`, console tee |
| 5 | `Settings` | `autoload/settings.gd` | user options, ranges and the clamp chain (sim → render, window apply, chunk meshes per frame), plus the AC-0088 controls remap layer (`controls` key — a flat `action:cls:idx` token list, default `[]` = the shipped `project.godot [input]` map; the merge/apply/conflict logic lives in `core/controls_map.gd` and a corrupt stored map fails safe toward the defaults — it can never empty an action), and the AC-0089 analog tuning layer (`look_sensitivity` 0.25–2.0, `deadzone_left`/`deadzone_right` 0–0.9, `invert_y`/`invert_x` bool — bounds + math in `core/analog_tune.gd`, applied live by the player's look/movement paths; a corrupt stored value clamps into the band, never out of it), plus the AC-0205 `smooth_ramps` bool (default OFF — the smooth ground-ramp toggle; the `sanitize_bool` clamp, `world.note_ramps()` on change, the Settings-surface row and the `AWECRAFT_RAMPS` harness env all follow the pattern — see the AC-0205 bullet in §4), and the AC-0398 `modern_light` bool (DEFAULT ON — the modern per-vertex lighting toggle; same pattern — `sanitize_bool` clamp, `world.note_modern()` on change (colour-only, no `geom_epoch` bump), the Settings-surface row and and the AC-0401 `cloud_deck` + `limb_space` bools (both DEFAULT ON — the user asked for both; the deck character and the limb-glow altitude gate; same look-change pattern — `sanitize_bool` clamp, the Settings-surface rows, the `AWECRAFT_CLOUDDECK=0|1` / `AWECRAFT_LIMB=0|1` harness envs — but NO apply step: `world._ac0401_push()` reads the live values every frame and pushes `u_deck` to the three cloud-layer materials and `u_limb_gate` to the sky material, and the shader defaults (0.0) short-circuit to the pre-AC-0401 paths; see the AC-0401 bullet in §4), and the AC-0402 `sky_altitude` bool (DEFAULT ON — the sky's altitude-aware space blend; same look-change pattern — `sanitize_bool` clamp, the Settings-surface row, the `AWECRAFT_SKYALT=0|1` harness env — and NO apply step: `world._ac0401_push()` pushes `u_sky_alt` (change-gated) + `u_space_sky` (per frame, the stretched-window blend from the live player's band constants; skipped when OFF) to the sky material; see the AC-0402 bullet in §4) and the AC-0405 `cloud_volume` bool (DEFAULT ON — the raymarched-volumetric-clouds rework the user ordered; same look-change pattern — `sanitize_bool` clamp, the Settings-surface row, the `AWECRAFT_CLOUDVOL=0|1` harness env — and NO apply step: `world._ac0401_push()` pushes `u_vol` + the annulus radii `u_vol_r/rmin/rmax` (change-gated on `planet_R`) to the three cloud-layer materials and toggles the two inner shells' visibility (ON = the outer shell carries the raymarched volume in the [R+275, R+400] annulus, inner shells hidden; OFF = the exact AC-0401 three-shell path — the shader short-circuits on `u_vol < 0.5` before any volume work); see the AC-0405 note in the CloudLayer bullet, §3), and the AC-0394 `viewmodel_occlude` bool (DEFAULT ON since AC-0435 — the 2026-10-03 report's held-item residual was the viewmodel's `no_depth_test` making the hand draw OVER terrain, which the user reported as the defect (the screenshot's flat tan quad over the scene, read as a sizing issue; the AC-0421 follow-up re-adjudicated it — "the screenshot is the authority: the defect is that it draws at all" — and shipped the orbit half as the no-switch altitude hide; this switch owns the on-surface half). AC-0435 re-ruled the default because the shipped-off state is the reported defect (the AC-0426/AC-0432 ambient_sky shape); the always-on-top look is the env-A/B / saved-setting OFF state; same look-change pattern — `sanitize_bool` clamp, the Settings-surface row, the `AWECRAFT_VMOCC=0|1` harness env (preloaded at boot WITHOUT save in `player.gd _ready` — the viewmodel is the player's, so the preload rides the player rather than world.gd's boot block) — and NO apply step: `player.gd _process` reads the live value every frame and re-applies `no_depth_test` across the whole viewmodel material registry on change (ON re-enables the depth TEST only — the depth WRITE stays `DEPTH_DRAW_DISABLED` in both states, the hand still never blocks the depth of anything behind it); the render evidence: `tasks/AC-0394/` (the 0.4 m wall A/B, hand occluded with the switch ON, still visible against sky)), and the AC-0395 `noclip` bool (DEFAULT OFF — the player-collision switch for geometry inspection, the user's own request: the body stops colliding while movement stays under the player's control; same pattern — `sanitize_bool` clamp, the Settings-surface row, the `AWECRAFT_NOCLIP=0|1` harness env preloaded at boot WITHOUT save in `player.gd _ready` (the noclip is the player's, so the preload rides the player) — and NO apply step: `player.gd _process` reads the live value and applies on change — `col_shape.disabled` (the player's OWN shape only — the slab bodies, mobs, drops and the grid-DDA mine/place raycast are untouched) + the AC-0145 `flying` state (noclip implies FREE FLIGHT: no gravity, the existing flight controls, so the radial gravity is not fought) + the void-kill gate (`not _noclip` — the tool's purpose is being below the surface) + the one-line indicator label visible only while on; the arm evidence: `tasks/AC-0395/` (the stop/pass-through arm, the same-path repeat, the before/after cave renders)), and the AC-0414 `sat_preload` bool (DEFAULT ON — the user's own request: the satellite body's terrain baked BEFORE the world handover, "the level of detail was not showing at all ... the world was still baking"; same pattern — `sanitize_bool` clamp, the Settings-surface row — and NO apply step: the bake starts at `SatelliteBody.configure()` from the live value (and `force_rebake()` follows the same switch, so the arm's REBAKE proves whichever path the game will use), and the loading window rides it — `world._ac0414_hold_tick()` holds the loading-window drain phase 1 (the real-band diamond) while the bake is in WORK, on a bounded 42 s budget with a LOUD release line when it fires (the bake continues in the background at the 4-worker tail); the loading screen shows a live progress line (seed, shard k/14 or face k/12, payload); the `AWECRAFT_SATPRELOAD=0|1` harness env preloads at boot WITHOUT save in `world.gd _ready`; OFF = the pre-AC-0414 single LOW-priority task with no hold — byte-identical behaviour; see the AC-0414 bullets in §3/§4), and the AC-0421 `relief_shading` bool (DEFAULT ON — the user's own fix direction for the flat satellite disc: "alter the color of the sample based on the height to make it more like baked lighting, like what minecraft does with its maps"; same look-change pattern — `sanitize_bool` clamp, the Settings-surface row, the `AWECRAFT_RELIEF=0|1` harness env preloaded at boot WITHOUT save in `satellite_body.gd` — and NO apply step: `satellite_body._tick_view()` reads the live value every frame and re-pushes `u_relief` on change to the 12 face materials, 0.0 short-circuits the shader's height modulation (the exact pre-AC-0421 flat sample); the sibling `u_spec` (the body's specular amount, shipped 0.0 — "the satellite level of detail should not be reflective"; `AWECRAFT_SPEC=0.5` restores the pre-fix sheen for the A/B only) rides the same push), and the AC-0426 `ambient_sky` bool (DEFAULT ON since AC-0432 — the user's ticket (AC-0432) was that the OFF look IS the defect: the black fully-lit faces along the seam / under the crown, with the measured lift parked behind this switch defaulting OFF (the AC-0426 shape) rounds earlier; the floor-only path is the env-A/B / saved-setting OFF state; the fix is the light-floor sky-ambient fallback — a face whose BOTH direct terms sit at the light floor (trunk under its own crown: the crown's leaves ring the top log cells so the sky pull never reaches them, and the scalar is clamped to the `MIN_AMB` = 0.08 floor at mesh time — chunk.gd / mesh.cpp — so it reads 20/255 after 8-bit packing, never 0.0: the strict-zero mask can never fire, measured on 4,461 tree vertices), or an enclosed cave/hollow, rested on ~0.26 at every hour and went sub-8-bit black on the dark bark/leaf atlas cells; ON adds `u_amb · u_day · step(max(u_day·s, g), 0.08)` (GLSL argument order — 1.0 iff the direct terms are at or below the MIN_AMB floor, i.e. "effectively unlit") to the four `chunk_lit_*` shaders' L — a sky-ambient that tracks the sky's actual day factor at that hour (u_day is exactly 0.0 at night → the term is 0.0 → the night look bit-identical even ON, a tree at midnight stays black; 1.0 at noon → the measured `AMB_SKY_L` = 0.35 lift in `world.gd`), faces with any direct light untouched at any hour, and the user-directed 0.20 floor never re-tuned; same look-change pattern — `sanitize_bool` clamp, the Settings-surface row, the `AWECRAFT_AMBSKY=0|1` harness env preloaded at boot WITHOUT save in `world.gd` — and NO apply step: `world._ac0401_push()` reads the live value and pushes `u_amb` (0.0 / 0.35) to the chunk materials on change, gated on the value + the material-set size (the AC-0420 late-material pattern); OFF is bit-identical by IEEE construction (0·x = 0, x + 0 = x), proven by a pixel-identical A/B frame; evidence `tasks/AC-0426/`), and the AC-0428 `cloud_gate` bool (DEFAULT ON since AC-0435 — the user's own words order the change — "we need some kind of noise or something around the planet that determines where groups of clouds are, it should not be uniformly cloudy across the entire planet"; AC-0428 shipped the measured fix behind the switch defaulting OFF, so the shipped look WAS the uniform deck the user asked to remove — the OFF look is the reported absence, re-ruled by the AC-0435 sweep (the AC-0426/AC-0432 ambient_sky shape); the uniform deck is the env-A/B / saved-setting OFF state; same look-change pattern — `sanitize_bool` clamp, the Settings-surface row, the `AWECRAFT_CLOUDGATE=0|1` harness env preloaded at boot WITHOUT save in `world.gd _ready` — and NO apply step: `world._ac0401_push()` reads the live value (change-gated on `_ac0428_gate`) and pushes `u_gate` to the three cloud-layer ShaderMaterials; the `vgate` helper in `cloud_layer.gdshader` returns 1.0 at `u_gate < 0.5` (bit-for-bit the pre-AC-0428 uniform deck) and otherwise `smoothstep(0.40, 0.52, anv(q·3.0 + offset))` — a single low-frequency octave in the drift-rotated planetary space `q`, applied in BOTH `vdens` and `vdens_coarse` (the volume path, the default — `cloud_volume` ON), so the cloud cover is grouped into broad cloudy + clear regions across the globe; the frequency `3.0` (feature ~19°) is tuned so the groups are smaller than the orbital visible-disc cap (≤ 54.7° at the lowest orbit) and visibly vary across it — at `q·0.8` (~72°) the whole disc sat inside one feature and the gate was invisible (measured byte-identical); the gate is a planetary field, not a camera term, so it holds at every orbit altitude; evidence `tasks/AC-0428/`), and the AC-0429 `no_sky_floor` bool (DEFAULT ON — the user's correction to the AC-0428 horizon blend, in their own words: "the sky box can't have a bottom edge, we are in space! We can't fake the horizon, the planet and satellite is the horizon." The AC-0428 blend removed the STEP at the local horizon but kept the STRUCTURE — the u_air air floor below it, the anchor, the band; this removes the lower boundary as a CONCEPT. Same look-change pattern — `sanitize_bool` clamp, the Settings-surface row, the `AWECRAFT_NOSKYFLOOR=0|1` harness env preloaded at boot WITHOUT save in `world.gd _ready` — and NO apply step: `world._ac0401_push()` reads the live value (change-gated on `_ac0429_nofloor`) and pushes `u_no_floor` to the sky material; the shader default 0.0 short-circuits to the pre-AC-0429 path bit-for-bit (the AC-0401 convention), and OFF is bit-identical by IEEE construction (`mix(x, y, 0.0) = x`); with it ON the below-branch fill + the gradient's horizon anchor + the horizon haze band blend to space with the floor's space weight `ws = u_space_out`, pushed per-frame from `Aero.sky_outside(alt_rad)` = smoothstep(A, A + 0.25A, alt_rad) — the player's INSIDE/OUTSIDE position about the A shell (AC-0439, the third skybox-edge report: the 2026-10-16 "blue above, black below" frame, because AC-0429's `ws = smoothstep(0, 0.3, w)` reached 1 at ~630 m — deep INSIDE the atmosphere — and made below-horizon space at every altitude; the rule the user had been stating: the sky must be consistent with WHERE THE PLAYER IS): below A (ws = 0) the fill is the same air as the sky above (the AC-0428 continuous-air shape — `u_air` at `alt = 0`, the ground-level AC-0384 r8 fog seam) and only the planet's surface ends it; at/above A (ws → 1 over the limb's own 0.25A tail, where w = 1 makes the above horizon space exactly) the fill + anchor are space and the planet's limb is the only boundary (the AC-0429 shape); `ws` is read only through the `u_no_floor` mixes, so the OFF contract stays bit-for-bit; evidence `tasks/AC-0429/`, `tasks/AC-0439/`), and the AC-0427 `seam_light` bool (DEFAULT ON — the user asked for the seam discontinuity gone: the per-chunk vertex lighting changed across a boundary by up to 0.922 luminance step at same-height twin corners (the AC-0420 measurement); same look-change pattern — `sanitize_bool` clamp, the `AWECRAFT_SEAM_LIGHT=0|1` harness env preloaded at boot WITHOUT save in `world.gd _ready` — WITH an apply step (a re-mesh is genuinely needed, unlike the uniform-push toggles): `world.note_seam_light()` updates `world.seamc_on`, sets `_tm_ctx["seamc"]` and re-dispatches every resident chunk via `tex_refresh` (colour-only — no `geom_epoch` bump); the C++ side reads the ctx `seamc` flag (absent = OFF = the pre-AC-0427 byte path on the hand-built arm ctxs and the stored fingerprints); evidence `tasks/AC-0427/`), and the AC-0436 `moonlight` bool (DEFAULT ON — the AC-0384 §29 assessment filed the night as the disqualifying gap (ground a near-black void at the 0.20 floor, the orbit planet a faint mottle, the HUD the brightest object), so the shipped-off state is the reported defect — the ambient_sky/cloud_gate/viewmodel_occlude re-ruling; OFF is the exact pre-AC-0436 night, the env-A/B state). The moon is the sun's antipode: direction-to-moon = `DayNight.sun_direction(t)` (whose y is positive exactly when the sun is below the horizon), intensity one home `DayNight.MOON_L` (core/daynight.gd). Same look-change pattern — `sanitize_bool` clamp, the Settings-surface row, the `AWECRAFT_MOON=0|1` harness env preloaded at boot WITHOUT save in `world.gd _ready` — and NO apply step: `world._ac0401_push()` reads the live value and pushes `u_moon`/`u_moon_dir` to the four chunk_lit_* materials (value + material-set-size gated, the AC-0420 pattern), `u_moon`/`u_moon_w`/`u_moon_dir` to the three cloud-layer materials, the `u_moon` disc flag to the sky material and `u_star_lift` to the star field — all change-gated; `satellite_body._tick_view()` reads it in its own per-frame uniform loop (`u_moon`/`u_moon_dir` on the 12 face materials). OFF or day → every consumer's added term is exactly 0.0 (0·x = 0, x + 0 = x, mix(x,y,0) = x in IEEE 754) — the pre-AC-0436 night bit-identical; see the AC-0436 bullet in §3; evidence `tasks/AC-0436/`), and the AC-0437 `stat_captions` + `inventory_dim` bools (both DEFAULT ON — the whole-experience assessment (AC-0384 §29) judged the caption-less identical-looking stat rows and the undimmed inventory panel the interface's stopping points, so the shipped-off state IS the reported look — the ambient_sky/cloud_gate/viewmodel_occlude/moonlight re-ruling; OFF is the exact pre-AC-0437 HUD, the env-A/B state). Same look-change pattern — `sanitize_bool` clamp, the Settings-surface rows, the `AWECRAFT_STATCAP=0|1` / `AWECRAFT_INVDIM=0|1` harness envs preloaded at boot WITHOUT save in `ui/inventory.gd _ready` (the consumer owns the HUD, not world.gd) — and NO apply step: `inventory.gd` reads the live value every frame (captions beside the heart/food rows; the 0.45-alpha world-dim rect, first child of the HUD layer). Evidence `tasks/AC-0437/`), and the AC-0441 `cloud_jitter` bool (DEFAULT ON — the cloud-deck banding/moire fix the AC-0384 §29 assessment filed: parallel stripes across the raymarched deck at oblique distance, the 120 m and 300 m frames; the banded look IS the reported defect, so the AC-0435/0436/0437 re-ruling ships it in). OFF = the exact current march grid bit-for-bit (the shader's `u_jit` 0.0 default + the `(i+0.5+0.0)` identity — the IEEE OFF contract). Same look-change pattern — `sanitize_bool` clamp, the Settings-surface row, the `AWECRAFT_CLOUDJIT=0|1` harness env preloaded at boot WITHOUT save in `world.gd _ready` — and NO apply step: `world._ac0401_push()` reads the live value every frame and pushes `u_jit` 0/1 to the three cloud-layer materials (change-gated; see the AC-0441 entry in the CloudLayer bullet, §3). A boot-only cost instrument rides the same seam: `AWECRAFT_VOLSTEPS=n` (env only, no Settings row — the AWECRAFT_SPEC pattern) pushes the march's `u_vol_steps` cost knob, which nothing pushed before this ticket. Evidence `tasks/AC-0441/`), and the AC-0446 `far_seam` bool (DEFAULT OFF — the tier-seam shading step: the far average band is a SHADED material, so the engine ambient/direct multiplied onto a light model the unshaded near tier has no left the same face ~3× darker through the band; ON swaps the band's material to the unshaded near-tier-parity variant `core/lod_avg_seam.gdshader` — render_mode is a render state, not a uniform, so the switch is a material-SHADER swap, and the lift's day-gating / the band's fog wall / the fog's depth cue are the near tier's own by construction). Same look-change pattern — `sanitize_bool` clamp, the Settings-surface row, the `AWECRAFT_FARSEAM=0|1` harness env preloaded at boot WITHOUT save in `world.gd _ready` — and NO apply step: `world._ac0401_push()` reads the live value every frame, swaps the material's shader on change (`world._ac0446_apply_shader`) and pushes `u_day` (per-frame, value-gated) + `u_moon`/`u_moon_dir` (the AC-0436 latches) to it; the shared `u_amb` push + main.gd's per-frame `u_fog_far` feed both variants; OFF = the original `lod_avg.gdshader` untouched, bit-identical (see the AC-0446 note in the WorldEnvironment bullet, §3. Evidence `tasks/AC-0446/`), and the AC-0447 `night_lift` bool (DEFAULT OFF — the dark-readable midnight floor; the shipped moonlight-only night stays the default, ON is the measured lift, OFF is the A/B. Same look-change pattern — `sanitize_bool` clamp, the Settings-surface row, the `AWECRAFT_NIGHTLIFT=0|1` harness env preloaded at boot WITHOUT save in `world.gd _ready` — and NO apply step: `world._ac0401_push()` reads the live value every frame and pushes `u_night_lift = (1 - day)` (per-frame, value-gated — moves with the clock, the moon-pair pattern) to the chunk AND fluid materials; the eight `chunk_lit_*.gdshader` turn it into a luma-scaled gain `1 + w*42.5*(0.00175/(lum+0.00175))^1.5` on the PREDECODED ALBEDO (A/d/p fitted against the game's own tone curve, measured in-game — `tasks/AC-0447/`): midnight floor byte 0 -> ~12, moonlit grass top 18 -> ~45, lum=0 stays 0, and w=0.0 (day or OFF) makes the gain exactly 1.0 — bit-identical by IEEE 754 (0*x, 1+0.0, x*1.0). Evidence `tasks/AC-0447/`) |
| 6 | `Save` | `autoload/save.gd` | slot save/continue and the per-slot on-disk layout |

Adding an autoload means editing `project.godot` **and this table** (and the order matters —
`Data` and `Debug` are used by everything downstream).

## 3. Scene tree — constructed at runtime

`godot/scenes/main.tscn` contains a single `Main` (Node3D) with `main.gd`. Everything else
is instantiated in code, so the scene files are shallow and the tree is not discoverable by
opening a `.tscn`:

```
Main                      scenes/main.tscn  →  scenes/main.gd
                          state machine (menu/play/pause), sky + day/night + aero,
                          HUD wiring, star node, stats overlay, snapshot/aim hooks
├─ Harness                scenes/harness.gd   all AWECRAFT_LOGIC/AWECRAFT_BATTERY arms;
│                                             inert during normal play (AC-0140)
├─ DirectionalLight3D     "sun" — modulated by Game.time_of_day
├─ WorldEnvironment       the SKY PASS (main.gd `_ready` + per-frame `_update_sky`):
│                         the Environment's Sky carries core/aero_sky_gradient.gdshader
│                         — the day/night gradient + sun/moon disc (the DayNight sun
│                         convention, shared with the satellite body AC-0382 and the
│                         clouds AC-0385), and AC-0386's SPACE TRANSITION:
│                         `u_space` = the flight band's own smoothstep over the radial
│                         altitude (|pos - C| - R, the band window read off player.gd —
│                         one number, one home; the sky darkens exactly where the
│                         controls hand over). The atmospheric gradient (incl. horizon
│                         haze) mixes to `Aero.SPACE_SKY` with weight S at the zenith /
│                         S² at the horizon (the grazing column of air keeps its blue
│                         longest); S=0 is bit-identical to the pre-AC-0386 sky. The
│                         sun's glow (scattering) fades ×(1-S); the disc stays. The
│                         space gradient touches the BACKGROUND ONLY —
│                         `env.background_color` stays the DayNight.sky_display
│                         reference (no double-darkening: the ground seen from
│                         orbit is depth-fog only). AC-0384 r8: the fog colour
│                         and the satellite's `u_air` are now the SAME single
│                         source — `Aero.fog_display(t)`, the sky pass's
│                         exact h=0 output (horizon mixed with the haze by
│                         haze_amount, 8-bit sRGB-rounded) — so 100%-fogged
│                         terrain, the dome's haz, and the sky's horizon are
│                         one colour by construction (pre-r8 all three took
│                         the separate DayNight.sky_display lerp; main.gd
│                         pushes env.fog_light_color, satellite_body.gd
│                         pushes u_air). It is deliberately NOT
│                         space-adjusted: the AC-0386 contract (above) says
│                         the space gradient touches the background only —
│                         the first r8 pass mixed this value to SPACE_SKY by
│                         S² and it erased the fog wall at flight altitude
│                         (measured 2600 m nadir (177,240,255) → (24,25,23));
│                         reverted and documented in aero.gd.
│                         AC-0415: the far-tier material (core/lod_avg.gdshader) rides this same
│                         env fog now — its hand-rolled duplicate (render_mode fog_disabled + the
│                         u_air mix of the engine's own depth ramp, the AC-0384 r8 haze-bridge
│                         residue thinned to a plain fade by AC-0400/AC-0404) is deleted: one
│                         ramp, one air colour, and the fog_enabled switch governs the whole
│                         ladder, not the near tiers only. The single-source seam at the fog wall
│                         is preserved by construction (the engine factor is 1.0 at fog_depth_end,
│                         exactly where the manual ramp reached u_air — the body's haz_d rim at
│                         the same wall, AC-0400). AC-0446: the band's LIGHT model gained a parity
│                         variant — the tier-seam step (the same face ~3× darker through the
│                         shaded band than the unshaded near tier) is closed by
│                         core/lod_avg_seam.gdshader: render_mode unshaded, the near tier's own
│                         L model on the band's binary a channel (m_direct = mix(20/255, u_day,
│                         COLOR.a)), the day-gray tint dropped, the same ±6% world-fixed jitter +
│                         the same AC-0401 fog-wall partition; Settings "far_seam" (default OFF —
│                         the original lod_avg.gdshader stays bit-identical) swaps the material's
│                         shader (render_mode is not a uniform; world._ac0446_apply_shader) and
│                         world._ac0401_push feeds it u_day + the shared u_amb/u_moon pushes. The
│                         env fog still governs the tier's depth cue — the variant is unshaded,
│                         never fog_disabled. AC-0415 measured: the engine depth ramp is a
│                         SMOOTHSTEP across the view range (Godot 4.7 fog_process:
│                         pow(smoothstep(begin, end, |view_pos|), curve) * density, with density
│                         auto-set to 1.0 by set_fog_mode), where the deleted manual ramp was
│                         LINEAR over the same window - the two agree only at the endpoints (the
│                         wall band stays byte-stable) but the mid-annulus haze weight shifts
│                         (120 m A/B: near annulus less hazy, far annulus more; 300 m: within the
│                         run-to-run noise floor), and the band A / annulus boundary is continuous
│                         by construction now (one factor per pixel), not only at the window
│                         edges as r8's "same factor as band A" comment assumed. The AC-0401
│                         partition (d >= u_fog_far, fed by env.fog_depth_end) is not fog and stays.
│                         AC-0384 r4 adds the ATMOSPHERIC LIMB GLOW: an additive rim
│                         term in the background keyed to the view ray's IMPACT
│                         PARAMETER about the planet centre (b = |cross(centre,
│                         dir)| — the same grazing-ray physics as the body's haz_a),
│                         exp-decaying 300 m outward from the tangent, coloured
│                         horizon*0.5+mid*0.5 (day/night/dusk-adjusted, dies at night
│                         for free) with a mild sun-side boost. It paints the region
│                         the drawn disc does not cover — including the sub-horizon
│                         band the camera's pitched-down view exposes between its own
│                         horizon and the displaced limb (pre-r4 that band rendered
│                         the dark h<0 sky: the measured (96,143,153) halo of the
│                         700 m capture) — so it is the No Man's Sky blue rim. Uniforms
│                         `u_limb_center` (centre minus CAMERA, per frame — the
│                         AC-0036 no-CAMERA_POSITION-builtin precedent), `u_limb_radius`
│                         (= R + SEA, the star-occlusion pair — one home),
│                         `u_limb_amount` (AeroLib.limb_amount(), default 0.55,
│                         AWECRAFT_LIMB env A/B; the term is off when radius = 0,
│                         i.e. no player/world yet). AC-0417 CLAUSE D: the limb's
│                         EXTENT is driven by the one atmosphere height A — two
│                         more change-gated uniforms, `u_atmo_radius`
│                         (`Aero.atmo_limb_radius(R)` = R + A, the tangent cone
│                         at the A shell) and `u_atmo_falloff`
│                         (`Aero.atmo_limb_falloff()` = 0.25A — 300 m at the
│                         default A: today's hard-coded value, now a stated
│                         fraction), pushed by world.gd _ac0401_push to the sky
│                         material AND the cloud materials (one home); the ON
│                         path's term is the NORMALIZED AIR COLUMN (AC-0419 — the pre-fix
│                         clamped exp(-(b - u_atmo_radius)/u_atmo_falloff)
│                         filled the annulus inside the A-shell tangent to
│                         a flat 1.0: a hard boundary circle in space, the
│                         2026-10-11 "large blue circle" report): the FORWARD air
│                         column through the shell's tail (rout =
│                         u_atmo_radius + u_atmo_falloff), CAMERA-AWARE — the
│                         ray crosses the rout sphere at s = -r*hl ±
│                         sqrt(rout²-b²) (hl = the ray's radial component):
│                         outside the shell, heading in, the visible air is
│                         the full chord (1.0 at the terrain limb, 0.89 at
│                         the deck top, 0.49 at the old A-shell tangent, 0.0
│                         at the tail); inside the shell or pointing away it
│                         is the near exit (0.04 straight up at A; exactly
│                         0 everywhere above the horizon from outside —
│                         looking up in space is space), normalized by the
│                         chord at the R+SEA disc tangent, clamped to 1.0,
│                         smooth, no edge. A 0.0-uniform
│                         fallback keeps rout = u_limb_radius + 300 (the OFF
│                         path is unchanged), so the
│                         glow reaches PAST THE CLOUDS (the cloud tops, R+400 +
│                         the AC-0407 virtual extend 50 = R+450, sit strictly
│                         inside A — asserted once in _ac0401_push with a loud
│                         push_warning if A is ever lowered past the deck)
│                         instead of ending below them (pre-AC-0417 the fixed
│                         300 m falloff on R+SEA put the rim 5.85° INSIDE the
│                         deck-top tangent at 1341 m; post, the A-shell rim is
│                         20.38° outside it). Pre-AC-0401 the term was NOT gated by S
│                         (the rim existed at every altitude, reading as the
│                         horizon glow at ground level). AC-0401: ALTITUDE-GATED on
│                         u_space behind
│                         `u_limb_gate` — the term is multiplied by
│                         mix(1.0, u_space, u_limb_gate). The rim is an ORBIT
│                         instrument (Settings "limb_space", default ON — the
│                         user asked; world.gd _ac0401_push pushes u_limb_gate
│                         to this material, the fence-locked main.gd
│                         workaround, see the AC-0401 bullet in §4): gate ON,
│                         the glow rides the flight-band blend (no rim below
│                         the flight band, where the low LOD's fog fade alone
│                         is the horizon read; full rim from orbit); the
│                         shader default u_limb_gate = 0.0 is the pre-AC-0401
│                         behaviour (rim at every altitude). AC-0402 (SUPERSEDED
│                         by AC-0417): had given the BACKGROUND blend its own
│                         stretched space window (Ss = `u_space_sky`, the
│                         BAND_WALK_MAX .. BAND_FLY_MIN×1.6 band) behind the
│                         `sky_altitude` switch. AC-0417 REDEFINES the whole
│                         switch — `sky_altitude` (Settings, DEFAULT ON, env
│                         AWECRAFT_SKYALT) now selects between two sky BODIES,
│                         not two windows: OFF (u_sky_alt < 0.5) = the
│                         pre-AC-0402 expression VERBATIM (world-Y gradient,
│                         the S²/S window, the rim at R+SEA/300 gated on S —
│                         bit-for-bit, `sky_off()`); ON = `sky_on()`: the
│                         gradient is keyed to the LOCAL zenith (hl = the ray's
│                         elevation about the radial through the camera —
│                         the fake-horizon fix: the same altitude at two
│                         positions on the sphere paints the same sky), the
│                         background is the day/night/dusk GRADIENT (horizon→mid→zenith,
│                         the sky_off expression re-keyed from world Y to hl)
│                         above the local horizon, thinned to SPACE smoothly
│                         by the A window (zenith by w, grazing by w² — the
│                         grazing ray's longer air column; w = 1 = space
│                         exactly), plus the horizon haze band (|hl|-keyed,
│                         dies with the air); BELOW the local tangent cone
│                         of the R+SEA disc the single-source AIR colour
│                         `u_air` (the 8-bit display value of
│                         `Aero.fog_display(t)`, the exact colour the env
│                         fog and the body dissolve to) is unchanged —
│                         AC-0439: the FLOOR DECISION is the player's
│                         INSIDE/OUTSIDE position, not the sky blend:
│                         `u_space_out = Aero.sky_outside(alt)` =
│                         smoothstep(A, A + 0.25A, alt) (pushed
│                         per-frame by world.gd _ac0401_push block (3),
│                         the same seam/radial as u_space_sky; the
│                         shader default 0.0 = the floor stays air,
│                         the conservative look) drives the below-
│                         branch fill, the gradient's horizon anchor
│                         and the horizon haze band through ws. Inside
│                         the A shell (ws = 0): the AC-0428
│                         continuous-air shape — the sky below the
│                         local horizon is the same air as the sky
│                         above it, and only the planet's surface ends
│                         it. Outside (ws → 1 over [A, A + 0.25A],
│                         where w = 1 makes the above horizon space
│                         exactly): the AC-0429 shape — space below
│                         the horizon, the planet's limb the only
│                         boundary; the fade reuses the limb's own
│                         0.25A tail, so the floor's last air is the
│                         grazing column the limb already paints and
│                         no single altitude shows a line. AC-0429
│                         had keyed this on the sky blend (ws =
│                         smoothstep(0, 0.3, w) — 1 from ~630 m, deep
│                         INSIDE the atmosphere) and made below-
│                         horizon space at every altitude: the user's
│                         2026-10-16 "blue above, black below" frame.
│                         `u_no_floor = 0` keeps ws unused (bit-for-
│                         bit pre-AC-0429)
│                         (AC-0419: the pre-fix ON path painted SPACE_SKY
│                         across the whole upper hemisphere — the
│                         2026-10-11 "the sky is dark during the day"
│                         report), and ONE atmosphere height
│                         `Aero.atmosphere_height()` (A, default 1200 m, env
│                         AWECRAFT_ATMO — one number, one home) drives every
│                         "how far up is space" consumer: the sky's space
│                         blend `u_space_sky = Aero.sky_space(alt)` =
│                         smoothstep(0.25A, A, alt) (the AC-0402 band is
│                         gone), the star field's full-opacity point (star.gdshader
│                         ALPHA = shape·mix(u_opacity, mix(u_night, 1.0,
│                         u_space_sky), u_sky_alt)·occl — ON, the stars are
│                         full exactly when the sky is space; at night
│                         mix(u_night,1,·) = 1.0 exactly as before; OFF keeps
│                         the u_opacity contract verbatim), the sun-glow fade
│                         ×(1−u_space_sky), the body's `h_full` (diagnostic —
│                         see the SatelliteBody bullet) and the limb's
│                         geometry (clause D below). The gate/stars/sun-glow
│                         keep riding the physics S on the OFF path (the
│                         AC-0386 contracts). AC-0414
│                         clause 2: the limb term is ADDITIONALLY LOADED-GATED
│                         (the user's 2026-10-09 report — the "planet" was a
│                         pale disc while the body was still baking): two more
│                         change-gated uniforms, `u_limb_loaded` (the switch,
│                         sat_preload) and `u_body_loaded` (1.0 iff
│                         satellite.phase == LOADED, pushed by
│                         world.gd _ac0401_push — the same fence-locked seam as
│                         every other limb uniform), and the term is multiplied
│                         by `mix(1.0, u_body_loaded, u_limb_loaded)` — OFF
│                         (u_limb_loaded = 0, the shader default) = ×1.0
│                         exactly (pre-AC-0414); ON + body not yet LOADED =
│                         ×0.0 (the sky never fakes a planet over an unbaked
│                         body); ON + LOADED = ×1.0 (the full limb term). This
│                         gate is the "no planet faked while the body is not
│                         LOADED" contract any future limb-radius work rides on.
├─ CloudLayer ×3          core/cloud_layer.gdshader — the cloud SHELL (AC-0235 →
│                         AC-0385): three concentric transparent shells at
│                         radii R + 275/330/400, centred at (0,-R,0), WORLD-FIXED
│                         (main.gd `_place_clouds()` re-places after the world
│                         loads, since Game.planet_R is only final then). 3-D
│                         value noise on the unit direction from the centre
│                         (u_scale3 = 2π(R+h)/feature keeps feature sizes in
│                         blocks); wind = rotation about world Y; sun-lit with
│                         the AC-0382 DayNight convention (u_sun = -sun_dir).
│                         Weather, not generation (genhash-neutral); fog_disabled;
│                         alpha depends on world direction + time-of-day only,
│                         never player distance — so it cannot pop at the
│                         satellite body's emergence. (Was: three flat
│                         player-following QuadMeshes, AC-0235.)
│                         AC-0384 r5: DISTANCE LOD on the noise field — each
│                         fbm band's scale is clamped per fragment so its
│                         FINEST octave (×2.03⁴) stays ≥ 2.5 px on screen
│                         (u_cpxrad = px per radian, pushed per frame by
│                         main.gd from window height + camera fov; the
│                         per-fragment camera distance is the driver). A
│                         per-fragment procedural field has no mip chain, so
│                         its sub-2.5-px octaves alias into the salt-and-
│                         pepper "near-disc static" (measured: 2600 m disc
│                         grain 23.2 clouds-ON vs 0.81 clouds-OFF). The
│                         no-pop argument survives: at or below the fog wall
│                         (the body's emergence) every factor is 1.0, and the
│                         clamp is a continuous function of camera position,
│                         so the pattern stretches, never pops.
│                         AC-0384 r6: the NMS deck character (shader-side
│                         defaults u_boost 2.2 (r8b, was 2.0) / u_under 0.70
│                         / contrast window 0.05-0.80 — never pushed, so
│                         main.gd is untouched): dense cores are occluding
│                         (alpha = clamp(cl·u_coverage·u_boost,0,1)), thin
│                         haze is collapsed to clear gaps (bimodal contrast),
│                         broad warped latitude bands give large-scale
│                         weather structure, and locally thick cloud shades
│                         its own underside (u_under — grey cores, white
│                         fringes). The grazing fade is now abs(dot(n,V)):
│                         edge-on means thin on EITHER side, so the deck's
│                         UNDERSIDE is visible from low altitude (the old
│                         max(dot,0) zeroed it) while the orbit limb still
│                         thins to the silhouette (no double white rim).
│                         cull_back → cull_disabled, with the
│                         missing back-face cull emulated in the
│                         fragment stage (discard back faces only
│                         while the camera is OUTSIDE the shell —
│                         orbit view unchanged by construction,
│                         underside renders from inside). CULL BOUNDS
│                         (AC-0384 r7, the r6 follow-up landed): on this
│                         engine build the shell instance's cull AABB
│                         degenerates to the node origin (the planet
│                         centre), so the shells drew only while the
│                         centre was inside the frustum (≈ above 2429 m
│                         on the planet preset) — _place_clouds set an
│                         explicit unit-box custom AABB (the AC-0235
│                         star-fix pattern), which was NOT enough: the
│                         r9/r10 dump probe measured a partial,
│                         ALTITUDE-DEPENDENT cap on the scaled
│                         SphereMesh (cap ~41 deg from nadir at 300 m,
│                         a comparable cap at 1600 m, far-side only
│                         from inside, nothing at 1600 m, full at
│                         2600 m — the bottom dome the user reported),
│                         pixel-identical on Forward+ and Compatibility
│                         (the r10 A/B), i.e. this build's shared cull
│                         of the PrimitiveMesh bounds class. AC-0384
│                         r10: the shell is a custom unit-lattice
│                         ArrayMesh (_build_cloud_shell_mesh, the
│                         SphereMesh 96x48 tessellation, 9216
│                         triangles) with the explicit unit-box AABB at
│                         CONSTRUCTION (the AC-0235 star pattern;
│                         _place_clouds re-sets it on every re-place) —
│                         the node transform (position (0,-R,0), scale
│                         R+h) carries centre and radius, so the
│                         geometry is the same shells, and the dump
│                         ladder now shows the whole visible hemisphere
│                         drawn at 2600/1600/700/300/120 m (30.45/40.25/
│                         52.87/68.77/100.00% of frame). AC-0384 r9:
│                         per-shell u_phase (a fixed per-shell offset
│                         vector pushed by _place_clouds) decorrelates
│                         the three shells' noise fields; the field
│                         stays a function of world direction +
│                         time-of-day (no-pop argument intact).
│                         View-dependent alpha is the geometric graze
│                         only; the weather field itself stays a
│                         function of world direction + time-of-day.
│                         All r6 terms are ≤ the clamped base-band
│                         frequency (grain-safe).
│                         AC-0384 r8: the PATTERN re-placement for the
│                         descent view — coverage window 0.46-0.54
│                         (centred on the fbm mean 0.485; was 0.50-0.58,
│                         which left the mid-latitude belt — the only
│                         part of the deck visible from inside the
│                         shells — at 0.19% pattern at
│                         CLOUD_T0=411200) and the latitude banding
│                         5 cycles with a 0.75 floor (was 11 cycles /
│                         0.5 floor); r8b (the one sanctioned tuning
│                         iteration): u_boost 2.0 → 2.2, window kept at
│                         0.46/0.54. Low-frequency / threshold changes
│                         only — the r5 distance-LOD clamp chain is
│                         byte-identical; the measured 2600 m grain moved
│                         4.71/1.90 → 7.64/4.56, diagnosed as the
│                         required content (fog colour + bridge + belt),
│                         not aliasing (tasks/AC-0384/AC-0384-results.
│                         html §23.4).
│                         AC-0401: the DECK CHARACTER behind `u_deck`
│                         (Settings "cloud_deck", default ON — the user asked;
│                         world.gd _ac0401_push pushes u_deck to the three
│                         layer materials; the shader default u_deck = 0.0 is the
│                         exact pre-AC-0401 path, bit-identical): 1.0 runs the field
│                         at 1/3 frequency (the masses ~3x wider), a tighter
│                         coverage window (fewer clouds), a 0.60 band floor (the
│                         belt troughs clear into real gaps), softer edge windows,
│                         and a volumetric read (puff brightness off the mid field
│                         + the thickness darkening deepened to 0.58 at full
│                         opacity). All windows/scale are u_deck-parameterised in
│                         the fragment; u_deck < 0.5 selects the exact r9 constants.
│                         AC-0405: the RAYMARCHED VOLUME behind `u_vol`
│                         (Settings "cloud_volume", DEFAULT ON — the user
│                         ordered the rework: "rethink clouds... forget how
│                         we currently do it"; the AC-0384/AC-0401
│                         patterned surface could not give parallax or
│                         internal depth because it is one surface at one
│                         radius). u_vol > 0.5 runs a volume path IN
│                         fragment() (the dummy parser resolves the
│                         fragment builtins + discard + no-return there
│                         only) that raymarches the annulus [R+275, R+400]
│                         about (0,-R,0) — the SAME verified shell extent,
│                         geometry untouched — through a 3-D FBM density
│                         field (the same ahash/anv noise + the u_deck
│                         windows/banding, sampled at 3 octaves, radially
│                         gated to the annulus so the light march can
│                         EXIT the cloud), up to two annulus segments per
│                         ray (near + far limb side; the one-hemisphere
│                         rule keeps each pixel marched exactly once),
│                         24 count-based view steps/segment (distance-
│                         adaptive = the grain gate), Beer accumulation
│                         with T<0.004 early exit, and per-sample
│                         lighting: a 6-tap 1-octave MARCH TOWARD THE SUN
│                         (self-shadow — lit tops, dark undersides), a
│                         Henyey-Greenstein phase (g=0.65, peak-
│                         normalised) for the in/out-scatter, and a 1-
│                         tap dark-edge term (the HZD powder role).
│                         ALPHA = 1-T (soft silhouette). The outer shell
│                         (max-h layer) carries the march; world.gd
│                         _ac0401_push (same seam) pushes u_vol + the
│                         annulus radii u_vol_r/rmin/rmax (change-gated
│                         on planet_R) and hides the two inner shells
│                         while ON (node visible; geometry untouched).
│                         u_vol < 0.5 short-circuits to the three-shell
│                         path byte-identical to AC-0401. Env
│                         AWECRAFT_CLOUDVOL=0|1; composes with
│                         cloud_deck (re-parameterises the 3-D field).
│                         AC-0406: the volume's LIGHTING MODEL (the user's
│                         "why are all the clouds dark?" — self-shadow-
│                         only scattering is ~0 from underneath, which is
│                         every sample a player sees). Three terms join the
│                         sun term in the volume branch: (a) an AMBIENT SKY
│                         FILL — per-sample in-scatter of the whole sky
│                         dome (exit-transmittance-weighted Σ T·ds, NOT
│                         self-shadowed — that attenuation is exactly the
│                         multiple scattering), coloured with the
│                         SINGLE-SOURCE air colour u_vol_air —
│                         Aero.fog_display (the env fog and the satellite's
│                         u_air take the same value; no fourth air colour
│                         for clouds) — pushed per frame by
│                         _ac0401_push (value-gated); (b) the self-shadow
│                         transmittance becomes a 3-octave sum with
│                         DECREASING extinction (the standard cheap
│                         multiple-scattering treatment), normalised so a
│                         fully lit sample keeps sh = 1.0 exactly (the 2.5
│                         gain and the lit tops keep their calibration);
│                         (c) the HG phase blended PARTWAY toward isotropic
│                         (constant 1.0 on vhg's 4π scale — normalisation
│                         exact, forward peak untouched). Shipped-tuning
│                         uniforms u_vol_ms1/ms2/iso/amb (the u_vol_sigma
│                         class — no new Settings toggle: this IS the
│                         lighting of the default-ON cloud_volume feature;
│                         u_vol < 0.5 still short-circuits to the byte-
│                         identical three-shell path).
│                         AC-0407: the user's three reports (still too
│                         dark / no height variance / not immersive
│                         inside) — a structural + lighting change in
│                         the volume branch (u_vol > 0.5; the
│                         byte-identical three-shell OFF path is
│                         untouched): (a) a VERTICAL PROFILE — the
│                         density had NO vertical profile before (every
│                         column filled the annulus uniformly: one slab
│                         at one altitude); vprof2 (replacing vgate)
│                         gives a flat dense base and lumpy tops —
│                         thinning to 0 over the last 0.20 of each
│                         column's top, whose altitude is
│                         mix(0.45, 0.98, smoothstep(0.35, 0.65,
│                         topf)) with topf a 1-octave field at HALF
│                         the base frequency (+ offset 5.3, 11.7, 8.1)
│                         — it MUST be independent of the coverage
│                         window (which sits on base's octaves):
│                         driving the top off the windowed field pins
│                         every cloudy column's top to ~400 m
│                         (measured: a 13 m "skyline", no variance);
│                         the coarse light-march density takes the
│                         SAME topf so the self-shadow exits at each
│                         column's own top (the tops stay lit —
│                         without it the light march over-shadows tops
│                         shorter than the flat gate); u_vol_lsteps
│                         6→5 offsets the added topf tap (400 m reach
│                         still clears the 175 m layer); (b) a
│                         THICKENED virtual annulus — the march+gate
│                         top moves R+400 → R+450 (world.gd pushes
│                         u_vol_rmax = R + hmax + AC0407_VOL_TOP_EXTEND
│                         (50 m); the shell MESHES stay 275/330/400,
│                         the base stays R+275 — clear of the ~139 m
│                         ground; the extension is upward only);
│                         (c) brightness WITHOUT the rejected
│                         ambient-weight raise (0.7 flattened the
│                         spread to 39.1): u_vol_ms2 0.18→0.24
│                         (brighter multiple-scattering penetration of
│                         the shadowed interior; the normalisation
│                         keeps sh = 1.0 at τ = 0), a FORWARD-SCATTER
│                         GLOW (a narrow sun-side lobe
│                         pow(max(cosSun,0), u_vol_glow_pow)·u_vol_glow
│                         added to the in-scatter — the "brighten
│                         toward the light" inside-the-cloud read), and
│                         u_vol_air_lift 0.10 (the single-source air
│                         colour lifted 10 % toward a brighter sky
│                         value — a brighter effective albedo, NOT a
│                         bigger ambient weight; 0.0 = the pre-AC-0407
│                         colour). Shipped-tuning uniforms u_vol_glow /
│                         u_vol_glow_pow / u_vol_air_lift (the
│                         u_vol_sigma class — no new Settings toggle;
│                         u_vol < 0.5 still short-circuits to the
│                         byte-identical three-shell path).
│                         AC-0417 (addendum 2): the deck is WASHED BY THE
│                         LIMB — two more change-gated uniforms, u_atmo_radius
│                         / u_atmo_falloff (the SAME values the sky material
│                         takes — one home, Aero.atmo_limb_radius/falloff,
│                         pushed by _ac0401_push to all three layer
│                         materials) + u_limb_wash (the sky_altitude switch,
│                         0.0 = the pre-AC-0417 material bit-for-bit), and
│                         ac0417_wash() in the fragment: the impact-parameter
│                         haze 1 - exp(-b / u_atmo_falloff) about the same
│                         centre, the same scale, the same centre source as
│                         the sky's limb term, blending ALBEDO toward the
│                         material's OWN single-source air colour u_vol_air
│                         (no new colour), gated by an
│                         outside = smoothstep(u_atmo_radius - 0.4·falloff,
│                         u_atmo_radius + 0.4·falloff, d) so the wash is
│                         exactly zero from inside the atmosphere (ground and
│                         deck-below views are bit-identical to before — the
│                         wash only kicks in for cameras at/above the A
│                         shell) and the deck's contrast drops toward its
│                         limb exactly like the terrain's fog fade (the 1341 m
│                         deck band measured (98,151,160) → (82,199,227) —
│                         toward u_air). The engine fog stays off on the
│                         clouds (fog_disabled) — the wash is the only new
│                         atmospheric term.
│                         AC-0441: the raymarch-grid JITTER (the deck
│                         banding/moire fix; u_jit 0/1 from the
│                         cloud_jitter switch, DEFAULT ON — see the
│                         Settings row). The shipped vmarchseg grid is
│                         FIXED-COUNT per annulus segment (t0 +
│                         (i+0.5)·dl, dl = chord/u_vol_steps): t0 and dl
│                         vary smoothly across the screen with the ray's
│                         impact parameter, so adjacent pixels march the
│                         SAME PHASED grid against the world-fixed
│                         density field — the aliasing accumulates
│                         coherently into parallel stripes (the AC-0384
│                         §29 frames). u_jit > 0.5 shifts each segment's
│                         grid by an independent per-pixel random in
│                         [0,1) — two ahashes of a quantized v_wp (a
│                         cell ~4.6 m ≈ the frame's pixel footprint;
│                         stable between frames, unique per pixel,
│                         moving with the world as the camera moves):
│                         the coherent phase offset becomes an
│                         uncorrelated per-pixel random, the structured
│                         artifact becomes noise the eye tolerates, at
│                         the SAME sample count (the 1191/1200 s render
│                         budget holds; a shifted sample past the
│                         segment end is dropped). The A/B measured in
│                         the ticket: 48 steps SOFTENED the pattern
│                         (residual stripes at 4x zoom, +39 % render
│                         wall) while the jitter REMOVED it (no visible
│                         structure at the same sample count) — the
│                         cause was the coherent alignment, not just
│                         step coarseness. u_jit < 0.5 (the shader
│                         default, OFF) is bit-for-bit the current grid
│                         ((i+0.5+0.0) = (i+0.5), the t>t1 break never
│                         trips). The light-march taps are NOT jittered
│                         (their grid is anchored to the sample's world
│                         position, not a screen-coherent grid — and the
│                         AC-0436 moon re-aim/HG/glow stay verbatim).
├─ Stars                  core/star.gdshader — the star field (main.gd
│                         `_build_star_mesh`): a 320-unit shell re-centered on the
│                         camera POSITION each frame, rotation never set — fixed in
│                         world orientation, zero parallax (a skybox in disguise);
│                         500 stars with per-star size/hue/brightness in UV2.
│                         AC-0386: `u_opacity = mix(1-day, 1, u_space)` (bit-identical
│                         to the pre-AC-0386 (1-day) below the flight band; fully on
│                         above it, day AND night — the above-the-sky-limit look) +
│                         planet-disc occlusion: a star whose direction ray-hits the
│                         body disc (sphere (0,-R,0), radius R + SEA = the Satellite-
│                         Body's own radius) is hidden — the 320-unit shell sits in
│                         front of the disc, so without it the dots painted on top of
│                         the planet. `u_cam_pos` is an explicit uniform (the headless
│                         dummy renderer rejects the CAMERA_POSITION builtin, the
│                         AC-0036 precedent). AC-0417: the field's altitude blend
│                         follows the one atmosphere height — three change-gated
│                         uniforms (u_sky_alt / u_space_sky / u_night, pushed by
│                         world.gd _ac0401_push — the main.gd u_opacity push
│                         stays verbatim for the OFF path) and
│                         ALPHA = shape·mix(u_opacity, mix(u_night, 1.0,
│                         u_space_sky), u_sky_alt)·occl: OFF = the AC-0386
│                         contract bit-for-bit; ON, the stars are full exactly
│                         when the SKY is space (u_space_sky = the A window —
│                         the same number the sky blends with), and at night
│                         mix(u_night, 1.0, ·) = 1.0 exactly as before.
├─ AeroWash               core/aero_wash.gdshader — the screen air-tint: a
│                         camera-following additive quad 0.12 m in front of the eye
│                         (WASH_AMOUNT 0.03). AC-0386: `wash_amount ×(1 - u_space)`
│                         — the lens wash fades with the atmosphere; the quad stays up.
├─ World                  world/world.tscn  →  world/world.gd
│  │                      chunk manager: streaming bands, LOD tiers, scheduler/drain,
│  │                      chunk pool, fluid ticking, edit flush, drops + mob spawning
│  │                      AC-0401: per-frame `_ac0401_push()` — the fog-wall
│  │                      partition uniform (u_fog_far, change-gated, to the shared
│  │                      chunk/fluid materials) + the cloud_deck / limb_space switch
│  │                      pushes (u_deck / u_limb_gate) to the Main-owned cloud and sky
│  │                      materials via the parent node (the fence-locked main.gd
│  │                      workaround; see the AC-0401 bullet in §4)
│  │                      AC-0402: the same seam gains the sky_altitude switch push
│  │                      (u_sky_alt, change-gated) + the per-frame u_space_sky
│  │                      (smoothstep(BAND_WALK_MAX, BAND_FLY_MIN×1.6, alt_rad) off
│  │                      the live player; skipped when the switch is OFF — see the
│  │                      AC-0402 bullet in §4)
│  │                      AC-0405: the same seam gains the cloud_volume switch push
│  │                      (u_vol to the three cloud-layer materials, change-gated;
│  │                      the two inner shells' visible=false while ON — the outer
│  │                      max-h shell carries the raymarched volume; restored to
│  │                      visible when OFF) + the annulus radii u_vol_r/rmin/rmax
│  │                      (change-gated on planet_R; rmin/rmax derived from the live
│  │                      layer table's min/max h — no duplicated constants; see the
│  │                      AC-0405 note in the CloudLayer bullet, §3)
│  │                      AC-0407: the same push thickens the volume's
│  │                      virtual top — u_vol_rmax = R + hmax +
│  │                      AC0407_VOL_TOP_EXTEND (50 m upward; u_vol_rmin
│  │                      stays R + hmin and the shell meshes are
│  │                      unchanged — see the AC-0407 note in the
│  │                      CloudLayer bullet, §3)
│  │                      AC-0417: the same seam becomes the ONE-HOME seam
│  │                      for the atmosphere height A (Aero.atmosphere_height,
│  │                      env AWECRAFT_ATMO): u_space_sky is now
│  │                      Aero.sky_space(alt_rad) = smoothstep(0.25A, A, alt)
│  │                      (the AC-0402 band constants are gone from here —
│  │                      see the AC-0417 bullet in §4), + the A-shell limb
│  │                      pair u_atmo_radius/u_atmo_falloff (change-gated on
│  │                      R and A; pushed to the sky material AND the three
│  │                      cloud-layer materials — clause D + addendum 2), +
│  │                      u_limb_wash (the sky_altitude switch to the clouds)
│  │                      + the star uniforms (u_sky_alt change-gated;
│  │                      u_space_sky/u_night value-gated when ON, the night
│  │                      factor = 1 - DayNight.day(Game.time_of_day)) via
│  │                      the Main-owned Stars material_override (get_node_or_null
│  │                      "Stars") + u_air = Aero.fog_display_srgb(t) (the
│  │                      8-bit DISPLAY value — the sky pass's native space —
│  │                      under the same 1/255-linear change gate as the
│  │                      existing linear air push) + the once-asserted
│  │                      invariant that the cloud tops (live hmax + the
│  │                      AC-0407 extend) sit strictly inside A (a loud
│  │                      push_warning if A is ever lowered past the deck)
│  ├─ drops (Node)        entities/drop.gd instances
│  ├─ entities (Node)     entities/mob.gd, arrow.gd, banana.gd
│  └─ SatelliteBody       world/satellite_body.gd — the satellite body tier (AC-0310 P2):
│                         the 12-face great-circle chart (sphere_math.gd) on the DISPLACED surface
│                         (AC-0384 r2: each vertex at R + H(u,v), the baked terrain height on
│                         a per-face 16 m grid — the body IS the terrain's far LOD; the height
│                         channel travels in the face PNG's alpha),
│                         unlit by the engine lights (the bake carries the piece-1 fixed-sun
│                         lambert, re-weighted by the shader to track the world's actual sun —
│                         the DayNight convention, AC-0382), per-fragment
│                         dissolve into the drawn disc at the depth-fog wall
│                         (core/satellite_body.gdshader); FOG-WALL CONTRACT (AC-0384 r3): the body's
│                         render_mode is fog_disabled — the engine env fog must NOT be applied: the
│                         body's own op/haz model IS the fog-wall bridge (existence ramps over [fog_far,
│                         render_edge], haz_d mixes the rim toward u_air, which is env.fog_light_color
│                         itself — AC-0384 r8: the single-source Aero.fog_display sky-model colour),
│                         and with the env fog still on, everything
│                         beyond fog_depth_end repaints fog colour: the established disc erases to a
│                         featureless ball and only the fog_disabled cloud shell keeps detail (the cloud
│                         shader carries the same flag, its comment naming this exact "erased by it"
│                         failure); below the fog wall the body's fragments are discarded by op anyway,
│                         so no double-fog is possible. The displaced grid step is the
│                         AC-0401: the fog wall is now a PARTITION, not a
│                         bridge — every near-field material (the four
│                         chunk_lit_*.gdshader kinds, lod_avg.gdshader, the two
│                         fluid_anim_*.gdshader) discards its fragments at
│                         d >= u_fog_far (the same DayNight.fog_far value main.gd
│                         puts on env.fog_depth_end; world.gd _ac0401_push pushes
│                         it to the shared materials, change-gated). The near
│                         tiers never draw past the wall (pre-AC-0401 they drew
│                         to the render edge at 100% fog colour — a fog-colour
│                         patch over the body's own displaced terrain from orbit,
│                         and the coplanar z-fighting in the 332-400 m band);
│                         the engine fog fade is the whole "dissolve" as the
│                         camera climbs, the body's haz_d rim at the wall is the
│                         seam (single-source air colour), and orbit shows the
│                         body alone. RADIUS ORDERING: the shader's vertex stage
│                         moves the displaced surface 2 m radially INWARD (the
│                         mesh origin is the sphere centre: local == radial), so
│                         wherever the same terrain still coexists (relief
│                         straddling the wall) the near tiers win the depth test
│                         by construction — no flicker; the op window and the
│                         star-occlusion radius (R + SEA, the star shader) are
│                         untouched.
│                         AWECRAFT_SAT_MESH_STEP env override (default 16 = unchanged — software-renderer
│                         render runs use ~64 so a settled frame carrying the body completes); runtime
│                         bake cache
│                         user://satellite/p{planet}_r{R}_s{seed}_h/ (the _h token = the
│                         height-channel era; pre-r2 RGB caches trigger a one-time re-bake),
│                         seeded from godot/assets/satellite/ for the canonical seed 44; the
│                         bake pipeline runs off-thread, AC-0414: sharded multi-threaded
│                         (98 payload shards × 2,002 records, streamed at the core-count
│                         width + 12 face tasks; HIGH under the loading-window hold, LOW
│                         (world.gd bake_yield) after the bounded late release until the
│                         player lands, HIGH-capped after; the main thread merges +
│                         assembles — single-writer, bit-identical to the pre-AC-0414
│                         single LOW task, which remains the sat_preload OFF path),
│                         AC-0418 worker-detached: every task is a static of the plain
│                         script world/satellite_bake_worker.gd — input = the bound per-
│                         bake state Dict + the AweGen handle + class statics, so the
│                         node is out of every worker frame and a mid-bake exit frees it
│                         under workers that hold no reference to it (the UAF close);
│                         _mt_exit_aborted stays the exit stand-down — gated by the
│                         sat_preload setting (ON default; the loading window holds on
│                         the in-flight bake, bounded + loud, AC-0414)
│     (scenes/test_range.tscn substitutes for World in the AC-0191 test range)
├─ Player                 player/player.tscn  →  player/player.gd
│                         CharacterBody3D + CollisionShape3D + Camera3D
│                         (CameraAttributesPractical = camera_attributes/main-camera-attributes.tres)
│                         movement, look, mine/place/bucket/bow, combat, inventory model,
│                         held-item viewmodel, swing/bob.
│                         HELD-TOOL COLOUR (AC-0098): the 32×32 TOOL_GRIDS voxels
│                         take their per-cell colour from the item's own icon in
│                         godot/assets/items_atlas.png — the icons are per-cell
│                         renderings of the same grid (1:1 shape match), so voxel
│                         (i,j) = icon pixel (i,j), sRGB-decoded to linear (the
│                         generated TOOL_ICON_TONES table in player.gd, rebuilt by
│                         tasks/AC-0098/sample_tool_icons.py). Two canonical pins:
│                         the icon tone nearest Data.item_tint(id) renders as the
│                         tint EXACTLY (the "head" node, read by toolres'
│                         held_head_color()), and the tone nearest HANDLE_C renders
│                         as HANDLE_C ("handle"). "head"/"handle" are INVISIBLE
│                         full-extent anchor meshes (pose contract — the toolpose
│                         arm's AABB centroid must not move); the visible meshes are
│                         one per colour (head_cN/handle_cN).
│                         NOCLIP (AC-0395): the player-collision switch for geometry
│                         inspection (the user's own request — fly through blocks to
│                         see a build from inside / inspect misbehaving geometry):
│                         the `noclip` setting (DEFAULT OFF — the shipped state is
│                         exactly today's behaviour; §2 owns the row/env/clamp, §6
│                         the decision) is read live in `_process` (`_noclip_sync`,
│                         the viewmodel_occlude pattern) and applied on change:
│                         `col_shape.disabled` (the body stops colliding — the slab
│                         bodies, mobs, drops and the grid-DDA mine/place raycast are
│                         untouched) + the AC-0145 `flying` state (noclip implies
│                         FREE FLIGHT: no gravity, the existing flight controls, so
│                         the radial gravity is not fought; the `fly` key F stays the
│                         in-flight exit — pressing it drops the player at gravity
│                         speed) + the void-kill gate (`not _noclip` — the tool's
│                         purpose is being below the surface) + the one-line
│                         indicator label on the debug CanvasLayer (visible only
│                         while on — the "not left on by accident" pair to the
│                         default OFF).
├─ ui/inventory.gd        CanvasLayer — hotbar, backpack + crafting grid, armour,
│                         hearts/food, crosshair, messages (Game.hotbar).
│                         AC-0437: the crosshair is REAL (a pixel plus —
│                         the absence of a feature, no switch); the stat
│                         rows carry "Health" / "Hunger" captions
│                         (Settings "stat_captions", default ON,
│                         AWECRAFT_STATCAP A/B); opening the panel dims
│                         the world (Settings "inventory_dim", default
│                         ON, AWECRAFT_INVDIM A/B — the 0.45-alpha
│                         rect is the layer's first child)
├─ ui/console.gd          CanvasLayer — in-game console (AC-0121)
├─ Particles              entities/particle_pool.gd — the pooled particle system
│                         (AC-0038): break debris / hit sparks / arrow burst / pickup
│                         puff. One fixed 200-slot ring behind one MultiMesh +
│                         MultiMeshInstance3D (this engine build has NO
│                         InstancedMesh3D class, and MultiMesh has no `material`
│                         property — the material rides the mesh; `use_colors` must
│                         be set before `instance_count`). Allocated once in _ready,
│                         ZERO allocations thereafter; reused round-robin — a burst
│                         can never grow the pool, over-cap drops the OLDEST live
│                         slot (the ring guarantees it is the one overwritten).
│                         Gravity is RADIAL (the AC-0145 P3 up pattern, captured per
│                         particle at emission); quads are unshaded camera billboards
│                         with per-instance colour (no new light/sun convention —
│                         DayNight.sun_direction stays the only hook). Four event
│                         kinds share the pool, distinguished by per-slot kind +
│                         per-instance colour (break takes the block colour).
│                         Game.particles; kill switch AWECRAFT_PARTICLES=0; census
│                         arm AWECRAFT_LOGIC=pcensus (harness_data.yaml)
└─ Menu                   scenes/menu.tscn  →  ui/menu.gd — main menu + options.
│                         AC-0437: the "Test Range" entry (AC-0191) is
│                         dev-only — `menu.gd _ready` hides it when
│                         `Build.ID != "dev"`, i.e. in any build stamped
│                         by build_windows.sh (the project's dev/shipped
│                         distinction is the stamp; there is no runtime
│                         debug flag anywhere in the tree)
│                         (three options tabs: Settings / Developer /
│                         Controls — AC-0088; the Controls tab is
│                         code-built rows over the remap actions,
│                         press-to-capture rebind + conflict report +
│                         reset, persisted via Settings "controls";
│                         AC-0089 adds its "Analog tuning" group —
│                         look sensitivity, per-stick deadzones,
│                         invert X/Y rows, persisted via the Settings
│                         analog keys, applied live by the player's
│                         look / movement input paths)
```

There is **no** `hud.gd`/`hud.tscn`, `player/interaction.gd`, `player/combat.gd`,
`entities/manager.gd` or `entities/models/*.tscn`: those duties are consolidated inside
`main.gd`, `player.gd`, `world.gd` and `ui/inventory.gd`. `world/chunk.gd` is the
per-column/slab object; `core/*.gd` are pure-logic helpers with no node dependencies
(`math.gd` DDA, `noise.gd`, `atlas.gd`, `chunk_io.gd`, `sphere_math.gd`, `held_mesh.gd`,
`aero.gd`, `daynight.gd`, `build_id.gd`, `controls_map.gd` — AC-0088 remap layer:
token grammar, the captured `project.godot` defaults, the safe-fallback merge,
apply + conflict detection, shared by the Controls tab and the `controls` arm,
`analog_tune.gd` — AC-0089 analog tuning: the deadzone/invert/sensitivity math +
the bounded ranges, shared by the Controls-tab "Analog tuning" group, the player's
look / movement paths and the `analog` arm),
plus the `.gdshader` files under `world/` and `core/`.

**Input (AC-0087 + AC-0088)**: the `[input]` section of `project.godot` is the
single home of the DEFAULT action map (movement, jump, the pad_* Bedrock
buttons, and the mouse/keyboard game actions — `attack` LMB, `use` RMB,
`inventory` E, `sprint` Shift — which AC-0088 promoted from raw
`button_index`/`physical_keycode` checks in `player.gd` so they are
remappable; defaults are byte-identical to the old raw checks). Game code
checks ACTIONS (`Input.is_action_pressed` / `event.is_action_pressed`), never
raw keys/buttons, so a remap reaches every use site. Custom bindings are the
`Settings` `controls` layer (applied over the defaults at boot, §2 row 5);
the built-in `ui_*` actions stay on their engine defaults (native GUI focus
navigation) and are not remappable from the Controls tab.

**Analog tuning (AC-0089)**: the Options > Controls "Analog tuning" group tunes
the two stick input paths (the Settings analog keys, `core/analog_tune.gd`): the
right-stick LOOK path stores the raw stick value and applies per-axis deadzone +
invert X/Y + the LINEAR look sensitivity at its `_process` application; the
left-stick MOVEMENT path reads the `move_*` action STRENGTH (`Input.
get_action_strength` — the old `is_action_pressed` booleans made the stick digital)
and applies the `deadzone_left` on top of the engine's per-action deadzone rescale
(0.5, `project.godot`). Invert and sensitivity are look-only (the left stick also
drives the native focus nav and the sprint-latch forward sign). Bounds keep the
game navigable at every legal setting: a full deflection is exactly full output at
any deadzone ≤ 0.9, and the keyboard (strength 1.0) can never be filtered out.
Values are read live — a slider change applies the next frame, no apply step.

## 4. Native extension (`gdext/`)

The hot paths are C++ (GDExtension), guarded at boot: if a class is missing, `Game`
reports `C++ extension (gdext) not loaded — missing: …`, prints the CANNOT START banner and
quits.

| Source | Role |
|---|---|
| `awe_common.{h,cpp}` | shared helpers/registration |
| `gen.cpp` | terrain, biome, cave and ore generation (the density-field generator) + the **AC-0290 classic carver pass** (the post-density room/trunk/canyon carve — see the carver bullet in §4) + the **AC-0292 P4 families** (vanilla pillars in the deep branch, big ore veins, the 3-D biome field → deepslate/dripstone/sculk/moss surface rules + the post-carve drip pass — see the AC-0292 bullet in §4); `generate_resl`'s `skip` arg: 0 = full / 1 = **band-A materialization fill** (no cave field — the drain's high lane runs it on each band-A column's first mesh, AC-0312; **AC-0397: driven from the column's far payload** (the binding's optional last arg — the 1024 bytes `generate_far` emits): solid 0..PAYLOAD H (the carved top, not the un-carved heightmap — pre-fix the fill stood on the un-carved H, up to 91 blocks proud on the user-settings ring), the top row = the payload TOP id (the far emit's surface block), the water gate = the fill's own top (the far emit's St rule), veg bases follow the fill top (the far lane's veg contract); the no-payload call keeps the legacy un-carved fill bit-for-bit) / 2 = **far h-only** (AC-0284b; **AC-0387: the H is now the CARVED top** — the lane runs the full path's per-column sequence (cave-lattice dens_at scan + aquifer + the AC-0290 carver) on a mask so the far/veg H IS the height the full path would produce (the promotion contract); the 3 surface fields + the 8 cave-lattice fields + the aquifer table + the carver plan are built per chunk — the AC-0387 price, measured 95 → 3,353 µs/chunk vs 5,651 µs full on the 2026-10-01 box; still NO slabs) |
| `mesh.cpp` | chunk meshing (greedy/FACE-BLOCK path); the avg far emitters `AweMesh.h_avg_emit` / `low_emit_avg` at a grid G (4 or 8 — AC-0312's band C / band B), byte-identical to the slab emitter on the same fill (shared `avg_grid_emit`), with the WATER EXCEPTION (a water-topped cell emits its top face with the translucent water material — `top_water` + atlas-rect params) and the `AweMesh.sky_eff` heightmap-sky light/strips builder (band A + the G-grid avg lanes); the far-tier floor (AC-0331) as a `p_yfloor` param on all three (−1 = off): a post-fill mask in the shared `avg_grid_emit` tail (avg tiers) + the per-voxel row gate + si0 in `build_accs` (band A) — the fill loops and the float32 op order are untouched; the AC-0205 smooth-ground-ramp branch in the ro scan (guarded by the ctx `ramps` flag + `!coarse`: a Δ1 rampable step meeting air suppresses the vertical face via `rmask` and emits the 45° quad into the same opaque acc — off = the pre-feature byte path; the far/coarse tiers never enter it, so H stays bit-exact — see the AC-0205 bullet in §4); the AC-0398 modern per-vertex lighting (guarded by the ctx `modern` flag + `!coarse`: the per-build 18×18 column-top grid + `s_modern_corner` replace the per-face `FSH` constant and the 4-level `AO_MULT` steps with continuous geometric `(sl, oshade)` per corner in `emit_ro_merged`/`emit_faces`/`emit_ramp` — `hgp == null` = the pre-feature byte path; H stays bit-exact — see the AC-0398 bullet in §4); the AC-0423/AC-0427/AC-0433 seam-V extension is DELETED (AC-0467 stage B, closing AC-0434): the per-edge K tables, `build_seam_ext` (home + the AC-0433 face-lane branch), the E(t,i) displacement of the top-face edge rows (AC-0423) and the edge column's outward side faces (AC-0427), the `SEAM_V_MARGIN`/`SEAM_V_MAX` clamp, the `SeamExt` plumbing through `qwrite`/`qwrite_vc`/`qwrite_merged`/the emit lanes, and the `sphere_r`/`seam_v_max`/`face`/`face_edge_*` ctx keys are all gone — the canonical placement (the §6 per-column bullet; DEFAULT ON on both lanes) makes the shared seam corners coincide by construction, so the crack the extension covered no longer exists and it was a visible band (AC-0467 stage A: 602-730 mm with the crack, 1212-1349 mm with the crack gone); the emit is the exact footprint now; and the AC-0427 `seamc` ctx flag (Settings `seam_light`, default ON; key absent = off = the pre-AC-0427 byte path): in `s_modern_corner` the INWARD reads of a boundary corner (west `gx == 1` / south `gz == 1`) are evaluated as the corner's own column (`self`), so the two twin corners straddling a seam use only SHARED data (own edge column + the neighbour's edge column via the ring + the seam column) and get identical `(sl, oshade)` — the colour-only seam-continuity clamp (no geometry, no `geom_epoch` bump) — see the per-column placement bullet in §5 |
| `strips.cpp` | strip meshing lane |
| `chunk_io.cpp` | column/slab blob encode+decode, region disk I/O |
| `lighting.cpp` | **test-only reference**: the legacy `AweLighting` flood kernel (AC-0283 P4) |
| `starlight.cpp` | the live light engine: single-queue sky+block propagation, per-section nibbles (`AweStarlight`) |
| `random_tick.cpp` | the 20 Hz tick's per-tick random block pass (`AweRandomTick`, AC-0370): the splitmix64 hash (colhash + 24× per-sub-chunk mix64) + the `random_tick_map` bookkeeping, ported from GDScript — bit-identical (int64 wrap + arithmetic `>>`; the `tick` arm recomputes every logged position with the GDScript `_rt_colhash`/`_rt_mix64` reference and gates `recompute_mismatch == 0`, now cross-lane). One synchronous main-thread call per fired tick; the map is C++ state, exposed on demand (`map_dict()`/`reset()` — the arm's scope check). The consumer hook is still a stub (no crops/leaves dispatch yet — leaf decay runs separately in GDScript) |

Build and loading:
- Built with SCons: `python3 -m SCons -C gdext platform=linux|windows target=template_release`
  (both are run by `./build_windows.sh`) → `gdext/bin/libchunkio.{so,dll}`.
- Loaded in-project via `godot/res/libchunkio.gdextension` (entry symbol
  `chunkio_library_init`, `compatibility_minimum = 4.5`) pointing at `godot/bin/`.
- The name is historical — it started as chunk I/O only and now covers gen, mesh, strips,
  IO and lighting.
- **`gdext/bin/` and `godot/bin/*` are git-ignored**: they are build outputs. A fresh
  worktree or clone has no `.so`, and headless startup will fail to parse — copy it from the
  main tree (see `godot/OPS.md`).
- Proof that the C++ lanes actually carry the work (and that no GDScript reference kernel
  silently took over) is the `nofallback` arm — `godot/HARNESS.md`.

## 5. Data, assets, saves

- **Tables live in `autoload/data.gd`** as GDScript dictionaries (shapeless/shaped
  recipes, atlas rects); **blocks, items and mobs are JSON data files**
  (AC-0141/AC-0142): `res://data/blocks.json` (34 entries), `res://data/items.json`
  (48 entries) and `res://data/mobs.json` (9 entries), loaded in `Data._init` by
  `_load_table` + `_decode_table_value`. The lookups (`block()`, `item()`, `block_drops`,
  `block_tool`, the rect/tint/frames helpers, `match_shapeless`/`match_shaped`) are
  unchanged and read the same in-memory dicts. **The JSON encoding is typed and must be
  kept exact** (Godot's JSON parser yields a `float` for EVERY bare number, and these
  tables mix int and float per value — `speed` is int 2/4/6/7 on tools but 1.5 on
  swords): top-level keys are the int ids written as strings (converted back to int on
  load — a non-int key is a deliberate script error so G0 sees it — the
  `int_keys=true` policy, blocks/items; AC-0142: mobs load with `int_keys=false`
  and the string name keys pass through verbatim); ints are tagged
  `{"i": n}` (never guessed from value — `hard` 1.0/2.0/50.0 stay floats); colours are
  tagged `{"c": [r, g, b, a]}` (floats; the source spelling was transcribed verbatim and
  the JSON doubles proven equal to the literal doubles, so the float32 channels are
  bit-identical); a bare JSON number is a float (`hard` 0.6 / 1.0 / 1e9). A missing or
  corrupt file fails startup with a SCRIPT ERROR on purpose (no silent empty tables).
  AC-0141 proved the move bit-identical by a before/after `var_to_str` dump diff
  (sorted; 12,070 B each, 34 blocks + 48 items, empty diff); AC-0142 did the same
  for mobs (2,200 B each, 9 mobs, empty diff). The remaining tables
  (shapeless/shaped recipes) still live in code, so do not assume a JSON file
  exists for them.
- **Textures**: `godot/assets/blocks_atlas.png` + `.json` and `items_atlas.png` + `.json`,
  generated from the Faithful pack by the pack-import probe (`godot/probe_alpha.gd`, hook
  `AWECRAFT_IMPORT_PACK`). The runtime can also load a user resource pack (`*.zip`/`*.mcpack`)
  from the menu. `godot/assets/satellite/satellite_faceNN.png` (AC-0310 P2) are the 12
  per-face 1024² satellite textures of the canonical seed 44 (the piece-1 bake, 16.0 m²/texel
  equal-area). **AC-0384 r2: they are RGBA8 — the alpha channel carries the terrain height
   (A = round(H·255/HMAX)), so the cache and res paths rebuild the displaced body mesh (each
   vertex at R + H on the 16 m grid) without the full payload; a legacy image without the
   channel falls back to the constant R + SEA sphere, loud.** Any other seed bakes them at
   runtime to
  `user://satellite/p{planet}_r{R}_s{seed}_h/` (the _h token = the height-channel era; a
  pre-r2 RGB cache is a different format, so it triggers a one-time re-bake, loud)
  **AC-0384 r5: the 12 face imports carry `mipmaps/generate=true`, and
  `satellite_body.gd` guarantees a FULL MIP CHAIN on every texture-producing
  path (res / cache / bake — `Image.generate_mipmaps()` before the
  `ImageTexture` wrap; the bake path goes through no import at all, so the
  code is the only place a chain can come from there). The body sampler is
  `filter_linear_mipmap_anisotropic` (the 4.7.1 combined hint) — a
  mipmap-filtering sampler over a chainless texture is a no-op, so the
  sampler and the chain ship together.**
  (off-thread, keyed by
  (planet_id, R, seed); the main thread polls and consumes one face per frame, AC-0382).
  **AC-0414: the bake is sharded and multi-threaded** — the payload stage splits the
  196,196 `generate_far` records into 98 shards (2,002 each) STREAMED at the core-count
  width (the poller enqueues the next shard as slots open — the first batch fills the
  pool at start), each shard appending to its OWN buffer (no shared-array writes from
  workers); the main thread merges the shards in deterministic order into the payload
  (one concat), then enqueues the 12 face tasks (colour + PNG + read-back + guard +
  geometry on the worker, per-face state dict, inflight capped — 12 while the loading
  window holds the bake, 4 after a late release so streaming keeps 2+ workers). The
  pre-AC-0414 single LOW task was the defect (it measured 1.00 effective thread — LOW is
  a one-thread pool class, world.gd:6216-6222 — and starved behind streaming, so the
  planet landed ~13 min after the player). The priorities are YIELD-AWARE: HIGH under
  the loading-window hold (the bake owns the cores); after the hold's bounded late
  release, world.gd sets `bake_yield` and the bake's remaining work enqueues LOW until
  the window closes, so the sim-band diamond build (HIGH) does not queue behind the
  bake's payload — the player lands at the budget + at most one shard slice (the
  pre-yield design measured a 109 s release on this box instead of ~48); after landing
  the tail goes HIGH again (capped). The main thread is the single writer of
  `pay`/`guard`/`_worker_images`/`_geom`/`bake_done`; the sharded path is bit-identical
  to the old single-task path by construction (deterministic shard order, verbatim
  per-face arithmetic) — the standing proof is the satellite arm's REBAKE pixel-compare
  through whichever path the `sat_preload` switch selects. OFF (the setting or
  `AWECRAFT_SATPRELOAD=0`) runs the untouched pre-AC-0414 single LOW task.
  **AC-0418: the worker side is detached from the node** — every bake task is a STATIC
  function of the plain script `world/satellite_bake_worker.gd` (`SatelliteBakeWorker`),
  and its only inputs are the bound per-bake state Dictionary (`_bake_state()`: the
  AweGen C++ handle, the configure() values by value, and the per-shard / per-face
  channels), class statics (SphereMath, the exit flag) and engine singletons. A Callable
  to a static holds no object, and the state is kept alive by the tasks' own bound
  arguments, so the node's teardown at process exit frees nothing a worker frame
  references: the mid-bake exit UAF (measured this ticket: 6/6 pre-detach stage-1 exits
  symptomatic — 2 SIGSEGV + 4 VM-level “Bad address index”; 2/2 as-shipped face-stage
  exits SIGSEGV in `_pixel_mt`, the AC-0414 crash; 10/10 as-shipped stage-1 clean — the
  AC-0414 `_mt_exit_aborted` mitigation holds only where its check cadence reaches, and a
  5 s face slice is past it) is closed. The flag stays and is read FIRST in every task
  (the exit stand-down, exercised on both paths). The node keeps the main-thread
  poll/merge/assemble, the consume/load paths, a thin `_bake_main_step_single()` collect
  for the OFF path, and the `_geom` cache (the build is the single worker-side
  implementation). Byte-identity stands: same arithmetic, same operation order — the
  proof is the satellite arm's REBAKE cmp (12/12 PNGs) through both paths.
  **AC-0311 piece 3**: the in-engine bake's per-face SEED SALT was dropped in
  `world/satellite_bake_worker.gd` `gen_one` (AC-0418: moved out of `satellite_body.gd`; the two far lanes thread (face, R) raw into
  `generate_far`, matching the sphere-domain port — the field is one planet, one seed, so the
  bake must be the SAME field, not a per-face-salted variant). The SHIPPED seed-44 textures are
  re-baked + re-shipped post-port (AC-0311): the in-engine bake is salt-consistent with the
  world, and the satellite arm's rebuild_vs_shipped check (the forced re-bake pixel-compared
  against the res:// assets) is the standing proof — 0-diff as of AC-0382 (re-baselined to the
   height-channel set in AC-0384 r2, RGB byte-identical). The satellite body's camera-far
   extension (the default
  4000 m plane clips the body's far limb) is owned by the tier, not the camera; the far
   bound uses the displaced surface's max radius R + HMAX (AC-0384 r2).
- **Saves**: slot-based (`Save` autoload + `core/chunk_io.gd` + `gdext/chunk_io.cpp`), column
  blob format **v6**, per-slot chunk directories under `user://` — which in this sandbox is
  `/tmp/dsh_home/...`, so saves do not survive a reboot (see `godot/OPS.md`). v6 = v5
  (the 24-bit generated mask) + one flag byte in the MD5-hashed head: **bit 0 = no-caves**
  (AC-0284a, solid 0..H slab-skip) / **bit 1 = far h-only** (AC-0284b — the column stores
  NO slabs, just a `[H u16×256][biome×256][top×256]` payload, ~198 B on disk); old v1–v5
  and bit-0-only v6 decode unchanged.
  **Save-content filter (AC-0287, shipped)**: the region write (`World._queue_chunk_save`,
  the one production save entry — the evict path) persists a column **only** if it is
  inside the **SIM DIAMOND** (`taxi <= band0_r`, the boundary EXACTLY — no tier-0
  exception, that set is gone) **or** it carries **edits** (`world.edits`); **far (h-only)
  columns are NEVER encoded** — the bit-1 payload write is dead and its DECODE stays for
  pre-AC-0287 saves. A column absent on disk regenerates on load (cheap far ~92 µs/col,
  bit-exact; the sim diamond re-gens full), and an edited FAR column persists through the
  JSON edits diff (`Save.save_now`) + the edit's own promotion regen (§6) — the edit is
  not in the far payload (no slabs), so the diff is the authoritative edit store. In
  natural flow an evicted column already sits two rings past the render edge, so in
  practice only edited columns persist and the save size stays FLAT under flight (the
  `flysave` arm is the proof: bytes per flown distance + edited-far persistence through
  promotion, read back from disk). No `SAVE_VERSION` bump was owed: the on-disk format is
  byte-compatible (decode untouched — only the write-side content policy changed), so the
  clean-reject option below was not exercised.
- **Save compatibility policy**: **old worlds are disposable during development** (user, 2026-09-17).
  A save-format or world-shape change may make existing worlds unusable and owes **no migration** —
  but it must bump `SAVE_VERSION` so an old save is **rejected cleanly**: fail fast with a log line and
  start a fresh world, never half-load. Migration work is therefore a deliberate choice, not a default.
  This supersedes the earlier "keep older saves decoding" rule; AC-0288…AC-0292 and AC-0293 already
  assumed it. Scope rule: the "Traps" list in `world/AGENTS.md`. **AC-0311 piece 3 bumped
  `SAVE_VERSION` 3 → 4** (`autoload/save.gd`): the sphere-domain port re-derived the terrain field
  (the lattice fields are f((d, δ)), the per-face seed salt dropped), so an old world half-loaded into
  the re-derived world would place its edits on different ground and its player pose in mid-air; the
  clean reject (a log line + a fresh world, no migration) is the owed protection. The bump is enforced
  in `_continue_slot`'s `version_ok` gate (a SAVE SOFT-FAIL print; edits/pose/leaf-decay gated).
  **AC-0459 bumped `SAVE_VERSION` 4 → 5** (`autoload/save.gd`): the home chunk key was re-spelled
  `"cx,cz"` → `"0:cx:cz"` (the 3-part form, one key shape with the chart faces), so a version-4
  save's edit diff re-keys onto the OLD home spelling and would half-load into the flipped world —
  the same clean reject, no migration. The 5-part edit-key form itself is unchanged (the re-keyer's
  3-part branch now absorbs the face-0 home keys).

## 6. Stable design decisions

Match these; do not improvise a different approach in a task.

**Proposed, not implemented — AC-0433 P1:** the coordinator's selected replacement for the
home/face split is documented in [the unified-model design](../docs/ac0433-unified-model.html).
It specifies one radius-derived nominal-metre chart grid and shared-vertex radial embedding,
canonical ownership, and a staged consumer/save migration. Sampled equal-height seam and
inverse validation passed (AC-0433 P1); production mesh/collision/streaming validation remains
pending. The implemented grid and placement below stay unchanged until their migration gates pass.

**Dormant, no callers — AC-0433 P2a:** the pure canonical grid/conversion API of the design
above has landed in `core/planet_grid.gd` (class `PlanetGrid`, extends RefCounted, pure statics
on the shipped `SphereMath` — preloaded by path, never transcribed): `grid_shape`, `vertex_key`,
`vertex_to_world`, `cell_to_world`, `world_to_cell`, `address_key`. It implements the one
radius-derived grid rule (H = face_width(R)/2, N = 16·ceil(H/16); faces 4–7 = (2N,N), others
(N,2N)) and the shared-vertex radial embedding (canonical integer cube-lattice vertex Q, owning
chart = the shipped `face_for_dir` tie order on the raw Q, P(h) = (R+h)·n − (0,R,0)). DORMANT:
zero production callers, no runtime key, save, native or shader change; `address_key` defines
cell identity only and is NOT an activated save format. Evidence: tasks/AC-0433/AC-0433-results.html
(P2a).

**Cell identity and adjacency (AC-0433 P2b, still dormant):** `cell_lattice`, `cell_owner` and
`cell_neighbour` give every chart cell ONE face-independent identity — `(plane, a, b)` on the cube
lattice, plane being the even face id of a cube plane and a/b in-plane cell indices in
[-N, N) — which is what makes the two historical grid scales (1 m on the home pair, ~6.14 m on
the other charts) an artefact of the two grids rather than a property of the sphere: every chart
cell is exactly one unit lattice square, and a cell's four corners rebuilt from the identity equal
`vertex_key` exactly on all 12 faces. **The owning chart is DERIVED, never carried** — non-X
planes (0, 2, 8, 10) split on `a`, X planes (4, 6) split on `b`, and the coordinate's sign selects
the even or odd chart — so a sector crossing falls out of the derivation and needs no special
case (`cell_owner` therefore takes no `sign` argument). `cell_neighbour` is one lattice step plus
that derivation, and it is **total**: a step leaving [-N, N) folds onto the adjacent cube plane
(the axis-parallel rule in the AC-0433 plan), so every valid cell has a real neighbour in all four
directions and no sentinel remains. **A fold is a real 90° rotation, so the way back is NOT the
opposite dir** — of 216 measured folds the return lands on dir 0/1/2/3 for 48/48/60/60 of them,
each fold reciprocal in exactly one direction. A consumer navigating across a cube edge must ask
the far cell which dir returns, never mirror the dir it came by. Key storage, streaming and the
player/mob consumers remain unmigrated. **Chunk level (AC-0433 P2c-1):** the same identity now
lifts to the 16×16 chunk — `chunk_of`, `chunk_cell_origin`, `chunk_neighbour`. Every face's cell
dimensions are multiples of 16, so no chunk straddles a chart edge, and `chunk_neighbour` resolves
through `cell_neighbour` rather than a second fold rule (960 chunks, 12288 crossing cells, zero
straddles, every pair reciprocal). There is still no save key. **Chunk key (AC-0433 P2c-2):** `chunk_key`/`chunk_from_key` give one
canonical spelling per chunk (`"face:cx:cz"`, plain integers) and a strict inverse that accepts
only that spelling — no trimming, no sign, no leading zeros, no coercion. Strictness is the point:
a streaming dictionary keyed on strings would otherwise hold two copies of one chunk under two
spellings. `address_key` and this chunk key define identity only; neither is an activated save
format. Evidence: tasks/AC-0433/p2b_probe.gd, p2b2_probe.gd,
p2b3_probe.gd, p2c1_probe.gd.

- **Planet coordinate convention — the grid lock (AC-0143 → AC-0306)**: the planet is a
  12-face cube-sphere (`core/sphere_math.gd`, face = axis*2 + sector, 1024-cell
  `CELLS_PER_FACE` grid per face; the non-home faces are sparse data-level chunks).
  **One flat metre is one metre of arc**: one lap of the flat world (4 cube faces of
  W columns) equals the sphere circumference 2πR, so **W/R = π/2** — the flat width of
  one cube face is `SphereMath.face_width(R) = π·R/2` (the per-planet rule W = 1.5708·R;
  a sphere is not developable, so the grid scales with the radius). At the shipped
  `Game.planet_R = 4000` (unchanged by AC-0306 — save record `planets:[{id,R,orbit}]`
  keeps R only, W is derived, no migration): W = 6283 and the home pair (faces 0,1 —
  the flat world, 1 m integer columns keyed `0:%d:%d` (AC-0459: the home key
  carries the 3-part `face:ccx:ccz` spelling, face 0 — one key shape with the
  chart faces; pre-AC-0459 it was the 2-part `"%d,%d"`)) is a 6283×6283 m patch
  (3141 per half). The position→cell map for the home pair is `World.key_for_sphere_pos`
  (half-face width πR/4; pre-AC-0306 it was R — the 0.72 m-per-block "shrunken
  Minecraft" defect). The cube-sphere mapping pre-warps each cube coordinate
  `c → tan(c·π/4)` (per-coordinate on purpose: both faces of a shared edge evaluate
  the same cube arithmetic, so the gapless invariant stays bitwise), which makes the
  midlines exactly 1.0000 m/column; the irreducible residual is ~0.93 m face-average,
  0.86 m pole-to-corner (the `sphere` arm's block 6 asserts it). **No data change:**
  on the home pair a column IS its flat x/z and stays that way — genhash 25/25 and
  the save edit keys are untouched by the mapping; only the position→cell ratio and
  the pre-warp move. The `sphere` probe (harness arm `AWECRAFT_LOGIC=sphere`) is the
  permanent proof. **Per-column placement (AC-0307; seam grout AC-0362):** the
  chunk node transform is a RIGID per-column placement (affine: the facet basis is
  scaled by `(1 + SphereMath.SEAM_FILL)` in its x/z columns),
  `SphereMath.column_transform(cx, cz, R)` — the facet is
  the tangent plane at the sphere point of the column's own flat centre (local +Y =
  the radial there), and its shared edges are aligned to the intersection line of the
  neighbours' tangent planes (shared-edge bisector): the folded-net convention —
  neighbours meet along the shared edge to the irreducible non-developable residual
  (mm–cm near the spawn; up to ~1–2 m in the spacing-stretch corner regions — a
  sub-mm-deep wedge, AC-0042 grout territory). The ACROSS-seam footprint component
  of that residual was closed by the AC-0362 grout: a centre-anchored in-plane
  overlap (`SEAM_FILL = 1e-4` → 0.8 mm extra footprint per side, 1.6 mm double
  coverage per seam; rendered worst case a 1.07 mm overlap), so all 308,112
  home-pair seams are opaque — before: up to 53 um (design) / 502 um (float32
  rendered) slits on 1,284 / 1,403 seams. The residual's radial/along-seam
  component — the V-crack: the sheets' edge lines diverge with height (the
  neighbour's radial leans 16/R away, V width ≈ h·16/R at surface height h) —
  was left OPEN in the home placement (AC-0307's close note attributed the
  closure to AC-0042's flat-world filler, which never existed in the sphere
  placement; AC-0423 measured the see-through: 552–558 mm slits at ground
  level, skybox behind). **It is now closed by the canonical placement
  itself, not by geometry compensation (AC-0467):** the one-world warp —
  AC-0458/AC-0460 on the face lane (DEFAULT ON since AC-0460 stage 5),
  extended to the home pair by AC-0467 (DEFAULT ON since stage B;
  `AWECRAFT_WARP_HOME=0` restores the legacy per-column fit exactly) — places
  every column pointwise on its own radial, so the two sides of a seam
  evaluate the SAME shared corner to the SAME world point by construction
  (homecensus: the shared-corner error floor goes 558.123 mm → exactly
  0.000 mm on all 153 census corners). The **AC-0423/AC-0427/AC-0433 seam-V
  extension that compensated the crack is DELETED in the same landing
  (AC-0467 stage B, closing AC-0434)**: the per-edge K tables, `build_seam_ext`
  (home + the face-lane branch), the E(t,i) displacement of the top-face edge
  rows and the edge column's outward side faces, and the `sphere_r`/
  `seam_v_max`/`face_edge_*` ctx keys + `world._face_edge_meta` are all gone —
  with the crack closed the extension was pure overshoot (the visible band:
  602-730 mm flag-off, 1212-1349 mm flag-on, stage A), and the seam is now
  asserted BOTH directions per cell — gap ≤ grout AND overlap ≤ grout
  (AC-0434's gate; the seam-band probe reads the live mesh and the placement).
  The legacy per-column transform remains only as the `AWECRAFT_WARP_HOME=0`
  contrast path (the far-tier low LOD maps through the same canonical
  construction under the flag — stage B's fix of the misplaced far tier). The
  user-visible detector is the `seamcensus` arm (missing_faces 0 on 393,216
  seam rows r4). The GLOBAL frame is the planet frame
  shifted by (0,−R,0) so the +Y pole (flat origin) sits on the global origin and the
  spawn facet is sub-degree. Point conversions: `SphereMath.flat_to_world(x,y,z,R)` /
  `world_to_flat(p,R)` (exact inverse — height = above the LOCAL facet plane; at a
  seam the point is attributed to the facet it lies on). Converters: the player
  spawn + `_recenter` (the recenter contract takes FLAT coords everywhere), the
  interaction rays (the DDA runs in the flat frame, `Player._flat_ray`; highlight and
  fluid box-tests convert), and the altitude semantics: the flight band blend +
  the cruise speed step key on the RADIAL altitude (|pos−C|−R, AC-0145), while
  fall distance + the void kill key on the FLAT height (sim_height) — never the
  global Y. The ground
  stays a gapless polyhedron of 16 m facets (physics = visuals; the flat pipeline
  is unchanged) and the terrain data does not move (genhash 25/25). Cross-face
  movement (faces 2–11) is AC-0309; the round-planet look is its own ticket.
- **Player-on-sphere convention (AC-0308)**: the player's rendered frame is
  `Player._col_frame()` = the column basis times the look yaw, so the camera up
  is the column's +Y — the radial at the column centre = the normal of the
  ground facet underfoot (within 0.115° of the radial at the player's exact
  position; the `consumers` arm pins `up_dot ≥ 0.999`). **The velocity lives in
  the COLUMN frame** (`Player._col_basis()`, no yaw): the `(tx, tz)` target
  formula already rotates the input by −yaw into the column frame, so mapping
  the lerp back with `_col_frame()` would apply the yaw TWICE (walking 90° off
  at yaw −π/2 — found in bring-up); gravity likewise runs on the local −Y (the
  local radial). Every data read from the player is in FLAT absolute coords —
  `_block_at`, the crouch edge guard and `vm_refresh` convert world→flat
  first; `Debug.teleport`/`aim_at` take FLAT arguments (their contract), and
  the settings render-distance recenter converts to flat before calling.
  **Auto-step**: the player auto-climbs any forward step ≤ 0.5 m — the
  folded-net seam residual varies continuously along a seam (down to sub-mm),
  so ANY positive step under 0.5 m is stepped; real 1 m terrain steps stay
  walls and are climbed by jumping as before. Standing proof: the `consumers`
  arm (`AWECRAFT_LOGIC=consumers`) — mine/place/step at the x=0 midline fold +
  two high-latitude positions, the no-fall-through census, terrain restored.
- **Player continuous frame + altitude/flight band (AC-0145)**: supersedes the
  "velocity lives in the COLUMN frame" statement above. The movement/up frame is a
  **CONTINUOUS ACCUMULATED basis** (piece 1), not re-derived per column:
  `_sphere_align` (player.gd) slerps local Y toward the EXACT radial
  `up = normalize(pos - C)` (C = (0,−R,0) global) at SPHERE_SLEW 12 rad/s (a
  ≥0.35 rad teleport-class misalignment snaps), and the look yaw is applied as a
  DELTA around that local Y — the 0.23°/column step is a continuous slew, never a
  re-snap. **The altitude/flight model is ONE band blend on RADIAL altitude**
  (piece 2): `alt = |pos - C| - R` (the same number on every face — a flat-Y
  altitude breaks over a fold) and `band = smoothstep(500, 2000, alt)`. band 0
  (alt ≤ 500) = surface walk: full up-alignment + full gravity (−up·26) +
  tangent-plane WASD + auto-step (byte-identical to piece 1); band 1 (alt ≥ 2000)
  = 6-DOF: a FREE basis (no up-alignment / auto-level) + no gravity (thrust
  only); the blend is the rate-limited slerp + the gravity scale (1−band), so
  takeoff/landing are seamless on any face — `_sphere_align(dt, align_amount)`
  takes `align_amount = 1 - band`. The existing flight knobs are reconciled, not
  re-derived: `cruising_altitude` (275) survives as a RADIAL speed step (2×→6×,
  no longer a motion-model boundary), `sub_cruising_speed` (2) /
  `cruising_speed` (6) are re-keyed to RADIAL, the A/SHIFT thrust is unchanged,
  and `flight_speed` was a disconnected Developer slider whose flight meaning
  is RETIRED (piece 3 removed the key, the clamp branch and the Developer-menu
  row — a stale cfg key is simply never read, no migration: load_settings only
  pulls keys in the DEFAULTS table). The 2000 m edge sits above the atmosphere's visible
  (depth-fog) boundary (full fog 714 m @ the R50 render edge 800 m) — the
  planet-epic window (docs/planet-epic.html §09 T6). Fall distance + the void
  kill still key on the FLAT height (sim_height) — a surface concept. Standing
  proof: the `spherewalk` arm's piece-2 fly fields (`alt_max_rad_m > 2000`,
  `band_peak > 0.95`, `freeze_dot < 0.99` the 6-DOF free-basis proof,
  `band_land < 0.05` + `land_up_dot ≥ 0.999` the surface re-alignment + seamless
  landing on the second face).
  **Entity fall direction (AC-0145 piece 3)**: everything that falls falls toward
  the centre (−up, the exact radial), not world −Y: drops (`entities/drop.gd`,
  radial gravity + a sim-frame ground read — home: the world→flat conversion,
  face: the anchor's cell frame — replacing a global-as-flat mix), bananas
  (a per-frame compensating force so the RigidBody's NET gravity is radial),
  arrows (radial light gravity + sim-frame solid read) and mob gravity (radial,
  the grounded zero strips the radial velocity component). The mob WALK/FACING
  motion model is still flat (world-xz intent + `rotation.y`) — the tangent-plane
  port is the follow-up, as is the sim-routed face-world mob spawn
  (`world._mob_tick` now picks the home-pair spawn region in the sim frame and
  skips a face spawn rather than misplace).
- **Cross-face movement (AC-0309)**: beyond the home patch the 12 face charts
  (faces 2–11) stream around the net. The face grid is 1024×1024 cells per
  face — ANISOTROPIC: the u axis spans the full face width (S ≈ 6.14 m per
  cell), the v axis the half-face (S/2 per cell on the z faces). Face chunks
  hold 16×16 cells, keyed `face:ccx:ccz` (AC-0459: the home pair now shares this
  spelling with face 0 — `0:ccx:ccz` — so the chunk dict has one key shape; the
  face ≥ 2 guard in `_face_star_pass` keeps home keys out of the per-face
  engines), placed by `face_chunk_transform`
  (the pre-warp + per-chunk LSQ — the chart placement; the net-vs-chart
  placement residual it leaves at the seam is the AC-0307/AC-0308 property
  and STANDS — AC-0311 piece 3 removed the C1 blend band, which masked the
  surface-HEIGHT seam (0–1 m vcrack, unchanged band-free; the sphere-domain
  (d, δ) field is continuous across the edge on its own), NOT the placement
  split (crossing-row chasm 2.19 m, corner 3.73 m, bit-identical pre/post
  band removal); the split's closure is filed as **AC-0433** (the one-world-
  model unification — `tasks/AC-0433/plan.html`); its first increment armed
  the seam-V extension on the face lane and fixed `parse_nbs` to accept the
  RAW compact rings (`_face_home_ring` / `_solid_ring` / `_patch_edge_ring`
  store the (HEIGHT/16)×256 B ring bare in the nbs dict) that the dict-only
  check silently DROPPED — pre-fix the face chunk's home edge and every
  window/absent-neighbour edge read the neighbour as air and emitted a
  full-height boundary wall (measured at the home/face seam: a 0→186 m side
  wall, 886 wall verts; post-fix the 0–6 m chasm ledge + the top rows extended
  past the nominal footprint).
  **Residency is ONE model with TWO pacing policies (AC-0469 G1–G4):**
  one resident list (`_resident_order`), one predicate (`resident_of`),
  one sweep (`_resident_sweep`) and one travel gate (`_evict_sweep_due`)
  over BOTH lanes. Policy A (home) runs at RECENTER cadence — the r+1/
  r+2 hysteresis + the AC-0257 capped/deferred free. Policy B (face) runs
  PER-FRAME when the travel gate passes (16 m of travel) — immediate,
  uncapped windowed free through `resident_of`. Creation is the ONE pass
  (`_create_pass`): the home part is the unbudgeted 5×5 recenter pre-warm;
  the FACE part is `_face_stream` (per-frame), which streams the player's
  window (sim_dist × 16 m, the per-face half of the edge — the along-edge
  clamp pairs faces 4/6/8/10 with the + half and 5/7/9/11 with the −
  half; lumping the pair is the r15 hole-to-void bug) inside
  `FACE_STREAM_BUDGET_MS`. The window is ALSO edge-normal gated (r30): a
  face streams only when the player is within `win` of THAT edge — the
  along-edge window alone is non-empty for every face mid-patch and would
  stream all eight edges' bands on an interior walk (boundary r4 resident
  93→272, p95 48→97 ms); a player already on the face side has a negative
  distance and still streams. The three geometric rules live as
  `_create_pass`'s named sub-rules (`_face_edge_dist`, `_face_band_rows`,
  `_face_edge_chart`); the face FIFO cap `FACE_CHUNK_CAP` refines the
  windowed eviction on landing. **`_face_player_flat` returns
  the recenter coords as-is: they are ALREADY flat** (the recenter contract
  takes flat — `player._recenter` and the main.gd sim_dist recenter convert
  world→flat before calling); re-reading them through `flat_of_world_pos`
  collapsed the boundary projection onto the +x edge near z 0 and starved
  face 5's stream budget (the crossing row never streamed while the player
  stood home-side near the edge). **No cross-face merge**: the face edge
  cells mirror the home edge data (the cross-face ring) and the seam stays
  coherent in both landing orders: `_face_rearm_home_neighbors` re-arms
  the home neighbours on a face landing, and (AC-0433 P0.5)
  `_face_rebake_boundary` re-bakes the resident face edge row on a home
  boundary-column change of EITHER kind — an EDIT landing (AC-0309 C5) or
  the column's data LANDING (the gen / disk / band-A-materialization
  handoffs): a face chunk is a sync build against a ring SNAPSHOT, so a
  straddler whose data lands AFTER the face build left that chunk's home
  edge against an air ring (extends nothing + a full-height seam wall)
  until the hook re-bakes it. The matching dispatch side: `_build_ready`'s
  8-neighbor gate (AC-0160) skips a neighbour that is fully past the patch
  edge (face territory — its data never lands; the dispatch ring
  synthesizes it via `_patch_edge_ring`), so the boundary straddler's high
  build no longer defers forever after a recenter jump (AC-0433 F4).
  **Per-face AweStarlight** (`_star_for_face`): each face owns a
  star instance stepped in the per-frame face pass; `_face_star_pass`
  re-bakes a settled face column on the star payload only when it differs
  from the landing (pull) light — the AC-0297 seam contract (byte-equal in
  steady state, a self-heal if the engines disagree). **Player anchor (C5)**:
  at the edge the player's anchor switches to the face frame — the face
  auto-step is 1.0 m (`Player.FACE_STEP`; the 6 m cell resolution makes
  2–3 m steps common; the 1.35 m jump covers the rest) vs 0.5 m on the home
  net. Gate: the `crossface` arm (`AWECRAFT_LOGIC=crossface` — the
  walk/flight crossing, the light seam, the edit interactions, the save
  round-trip, the seam audit).
- **Collision**: player and mobs are `CharacterBody3D`; voxel collision is a **per-slab**
  `StaticBody3D` (24 per column) built in `chunk.gd _build_slab_collision` from the slab's
  opaque surface plus the flora CUTOUT surface (AC-0270 — leaves have collision; fluids and
  cross-flowers do not), and rebuilt from the MESH (the body mirrors the mesh, never the raw
  data). Two lanes feed it: the IMMEDIATE lane (`_col_immediate_for` — Chebyshev ≤ 1 of the
  recenter anchor + column (0,0): free + rebuild in the landing frame, the footing guarantee)
  and the STAGED lane (`_col_pending`, ≤ 2 columns/frame in the drain's
  `build_dirty_slab_bodies`; `AWECRAFT_COLSTAGE=0` disables it — then only the immediate
  footprint is serviced). **Per-frame collision budget (AC-0340)**: the staged lane is
  ALSO time-capped at `collide_drain_budget_ms` (default 8 ms — the `drain_budget_ms`
  model that bounds the build lane; `AWECRAFT_COLLIDE_MS` overrides) — measured at
  AC-0337, a column is up to 24 slabs at ~2 ms each, so the fixed 2-columns/frame
  could carry 48 slab bodies (≈100 ms) in one frame. `build_dirty_slab_bodies` stops
  BEFORE starting a slab once the budget is spent; a column whose slabs outlast it is
  RE-QUEUED as debt (`perf_col_deferred`), never dropped (a drop is still an
  invalidation: eviction / band change / stale). The FENCE: the immediate footprint
  (the `_col_immediate_for` predicate) is built UNBOUNDED in the drain — the budget
  must NEVER defer a slab under the player (a missing body there was the shipped
  "player falls through" bug, chunk.gd:1355 / the AC-0264 hunt); a spent budget skips
  out-of-footprint entries and keeps scanning (the (0,0) column can sit in the queue
  sorted by distance — the band-0 re-entry staging does not foot-check). Standing
  proof: the `perf_col_deferred_in_footprint` tripwire + the arm-side `footprint` scan
  (meshed slabs missing a body, Chebyshev ≤ 1 + (0,0)) in the boundary/perf arms and
  the tripwire in the player arm (HARNESS.md §1). **Band-edge lifecycle (AC-0337)**: a body is a deterministic
  function of its geometry inputs, stamped per slab — the slab's own `(dgen, fgen)` plus the
  four orthogonal neighbors' same-slab `(dgen, fgen)` (`_slab_geom_stamp`; the per-slab
  generations move only at a write to that slab / a column landing; **light is excluded** —
  a settled-light re-bake remeshes without re-deriving collision). `collision_enabled`
  follows the band (`band == 0`, = sim), and the bodies **survive a band excursion**:
  leaving band 0 is the flag only (no free — the geometry did not change), and re-entry
  re-arms ONLY the stale slabs (`rearm_slab_bodies` frees the bodies whose stamp moved
  while the column was out; the staged drain rebuilds them) — a clean re-entry keeps every
  body. An edit re-derives exactly its closure: the live `set_block` path marks the
  greedy-merge closure (`mark_edit_slabs`, rows `y-3..y+1`), and a landing apply
  (`_apply_edits_to_chunk`) marks the block-changed cells' closures — the per-slab stamps
  do the rest (the old whole-column `mark_all_slabs_dirty` re-derive is gone). The wprof
  ring carries a **COLLIDE sub-stage** (`WP_COLLIDE`, bracketing both the
  `_post_build_collision` and `build_dirty_slab_bodies` derivations — a subset of
  DRAIN/HANDOFF, never in the 5-stage partition, the STAR/MESHATTACH pattern), and the
  permanent per-slab census (`perf_collision_slabs` + ms + 6-bin histogram, counted at the
  single body-derivation choke point — the `perf_collision_*` trio counts BATCHES, not
  slabs) plus the `perf_reband_*` excursion counters are the standing gate evidence
  (HARNESS.md §3).
- **Crossing attribution (AC-0348)**: the synchronous `recenter()` sweep — the chunk-change
  walk run from the PHYSICS frame (player.gd `_recenter()` on a chunk change) and the
  `_process` snap-back — runs OUTSIDE the per-frame wprof partition (whose `WP_RECENTER`
  stage brackets only the sliced continuation `_recenter_slice()`, the 8 ms-budgeted path),
  so its cost never appears in the 5-stage partition — the home of the previously-
  unattributable 782 ms-class worst frames. The WORLD CROSSING RING (`crossing_ring` /
  `crossing_seq` in world.gd, capped 256 entries) brackets each synchronous call (total µs,
  scan µs) and carries the per-crossing CAUSE CENSUS: demoted / promoted / halo evicts /
  reentry flips / synchronous `generate_far` calls + the scanned count. The boundary arm
  pairs each crossing with the frame time of the frame it ran on — `crossing_burst_*` (the
  sweep) and `crossing_frame_*` (the frame — the gate fields of the HARNESS.md §3 standing
  row "boundary r24 crossing frame latency", thresholds `crossing_frame_p95_ms` ≤ 75 /
  `crossing_burst_max_ms` ≤ 15, coordinator-only ~20 min run). The arm's `burst_*` /
  `forward_*` / `trailing_*` fields stay WALL-CLOCK THROUGHPUT (the forward wall resolves
  only when the whole wall is `mesh_built` — unresolvable at R24, so they read −1/0 there)
  and must never be gated as frame latency. Measured (R24, 2026-09-21): the sweep was
  5.3–9.1 ms per crossing — dominated by the RESIDENT-SET SCAN (the full ~1453-column set
  walked on every crossing; the code-reading estimate of 1–3 ms dominated by sync
  `generate_far` did not hold — it is ~0.9 ms) — and the crossing FRAME was 8–58 ms (p50 9).
  **AC-0350 (band-bounded sweep):** that resident-set walk is now bounded — O(ring), not
  O(resident): with K = this recenter's center shift (taxi) and R_outer = the stream set's
  outermost taxi (maxi(R, b1_eff()) + 2), the sweep visits only (A) the fills taxi ≤
  band0_r + K around BOTH centers (the real-band window: build backstop, crossing-out
  demote, re-entry flip), (B) the rings taxi ∈ [R_outer − K, R_outer + K] around both
  centers (the stream-set flip set — and, every resident OUTSIDE column is proven at taxi
  ≤ R_outer + K, so the free logic runs on exactly the set the old walk reached), and
  (C) the maintained `_stream_outside` set (the exact backstop; the sole outside source
  when K > R_outer — a jump/teleport, which degenerates B to the two set fills). The
  per-entry body is unchanged. The AC-0346 1→1-hop class (a FULL-data column outside the
  real band at BOTH centers — producible only by a full halo-band landing, a sim-band
  shrink, or boot) is not within K of any edge: it is owed through `_real_demote_owed`
  (flagged at the threadgen/disk/sync landing sites, in-set only — out-of-set full
  columns are freed full by the free logic, never demoted) + a one-time full sweep
  (boot/load and any detected band0_r shrink), cleared with the same body. Measured
  (R24, 2026-09-22, before/after pair): the sweep is 4.2–8.5 ms (p50 5.4 / p95 7.4 vs
  6.6 / 8.5 — at R24 the ring is the same order as the resident set; the O(R) vs O(R²)
  scaling is the win) with a BYTE-IDENTICAL per-crossing census (97/97/97/97/97) and
  resident_final 1453 — so the multi-hundred-ms tail frames remain NON-crossing storm
  work (drain/handoff/mesh-attach), which this ring attributes by exclusion.
  Since AC-0469 G2 the free logic runs in `_resident_sweep`'s home pass
  over the ONE `_resident_order` list instead of inside that walk — the
  invariant above (every two_out resident and every live cand_since>0
  entry is visited by the walk) is exactly what makes the list pass see
  the walk's set, so the bounded-set proof stands.
- **Worst-frame capture (AC-0352)**: the wprof ring (p50/p95/max per stage over 180 frames)
  cannot NAME the stage of a single worst frame — the R24 storm's 549–719 ms class shows up
  as one max value and was attributable only by exclusion + the crossing ring. The
  WORST-FRAME CAPTURE (world.gd, the wprof block; MAIN-THREAD-ONLY, PRE-ALLOCATED) closes
  that: every frame whose `World._process` total exceeds 30 ms (`WFC_THRESHOLD_US`) is
  captured at `_wprof_end_frame` (AFTER the f1 stamp, so the capture cost never enters the
  measured total) into the worst-N ring `wfc_ring` (`WFC_CAP` 256 — a newcomer displaces the
  ring's minimum; `wfc_total_n` counts all over-threshold frames since boot): the full 13-slot
  split (five top stages + MISC + the six sub-stages, ms at 0.1), the frame's streaming state
  (queue depth, tm/tg in-flight, low tasks, star pending, resident, in-radius present/built
  against the player chunk — the one O(resident) cost, run only on over-threshold frames),
  and the re-mesh correlation fields (the cumulative `perf_edit_dispatches/defers/syncs`
  snapshots, the `dirty_queue` depth, the remesh-lane depth, and the per-frame
  dispatch/defer/sync ACTIVITY over the capture frame + the 8 preceding frames — a dispatch
  that slows frame T fires in T or a few frames before, never after). The per-frame activity
  rows come from the small `_wfa_rows` ring (64) fed by the `perf_edit_*` counter deltas at
  each committed frame. It is the lead the seam series (AC-0353+) needs, read both ways:
  worst frames with NO edit/remesh activity in the window → the tail is ordinary streaming
  (the attribution stands as the answer); worst frames WITH activity → a correlation with the
  counts to record, NOT proof of causation (the seam census is the next probe). The boundary
  arm reports the walk-frame percentiles (`storm_walk_n` / `storm_walk_p99_ms` /
  `storm_walk_max_ms` — the worst-frame class's standing value; the max is single-sample by
  nature and never the gate), the worst 20 captured entries inside the walk window
  (`worst_frames`) and the BLIND-SPOT CENSUS (`census_walk_start` / `census_walk_end`: the
  in-tree MeshInstance3D count — the radius-independent post-AC-0338-ring-batching class — +
  the collision-body population + the node count; headless has no rasterizer, so the
  draw-call/object counters are meaningless there and the census is the instance-level ground
  for the costs the partition cannot see: the physics step, the physics server and the render
  server all run OUTSIDE `World._process`). Standing value: HARNESS.md §3, the "boundary r24
  crossing frame latency" row (extended at AC-0352 with the storm-tail
  `storm_walk_p99_ms` threshold).
- **Raycasting**: the analytical voxel DDA in `core/math.gd` for select/mine/place and
  projectiles — not physics rays (faster and deterministic).
- **Meshing**: one `ArrayMesh` per slab/chunk via `SurfaceTool` (GDScript path) or the C++
  greedy/strip lanes; level-aware fluid faces; rebuilt on edit. **Handoff staleness contract
  (AC-0354)**: a worker build's cross-chunk face decisions are made against the DISPATCH-time
  neighbour snapshot (the compact `snap_rings` rings), so `threadmesh_handoff` re-validates its
  inputs when the result LANDS, not just the own column: the own column via `rows_eq` over the
  dispatch's scoped row window (or `data_gen`/`fl_gen` when full) + the band check + the star
  `lver` box epochs; and the NEIGHBOURS via `nbs_stamps` — the `[col_gen, data_gen, fl_gen]`
  epoch of each of the 4 axis neighbours captured beside every `snap_rings` call (the AC-0247
  identity+stamp pattern, one level out; `col_gen` covers a freed-and-reused neighbour) —
  compared against the LIVE neighbours (a gone neighbour is a mismatch; the re-dispatch defers
  until the data lands). Any mismatch is the existing own-column treatment: `_tm_datadrop` +
  `_tm_retrigger` (re-dispatch with a fresh snapshot) — a mesh built on a stale neighbour ring
  never lands. (Pre-AC-0354 nothing compared the neighbour state: a neighbour that changed
  between dispatch and landing passed the check and the wrong face decision landed — at a
  boundary that is the user's see-through seam gap, because the edited column re-dispatches from
  a snapshot taken before the edit while its neighbour rides `_dirty_front` to the front.)
  **Scoped-build boundary equivalence (AC-0355)**: the per-slab lane's scoped builds decide
  interiority with the fast `ymask` boundary grid instead of the full path's `s_is_interior`,
  and the two MUST read identical neighbour sets — in particular the mask's guard cells
  (the ring row/column at lx=-1/lz=-1) must come from the snap rings, never from the own
  slab source (the C++ port once lacked the lower bounds and read `flat[-1]` — out-of-bounds
  garbage that misclassified cave-side seam cells as interior and silently dropped their
  faces from every scoped build while full builds stayed complete). If a scoped mesh ever
  disagrees with a full build of the same inputs at a seam, suspect this equivalence first
  (the seamcensus F-F class + a direct scoped-vs-full build diff is the probe).
- **Lighting**: baked into each face's **vertex colour** (albedo × light) — no realtime GI.
  Sky+block light come from the C++ `AweStarlight` single-queue engine inside the sim band;
  beyond it a heightmap-sky halo (sky 15 strictly above the terrain top, 0 at/below, no
  flood, no nibbles) keeps the far field cheap. World writes fire `star.on_edit` (a per-write
  two-phase re-seed of the 3×3 columns × sections 0..hi box); the 20 Hz fluid tick instead
  BATCHES its whole pass — `begin/end_edit_batch` runs the same two-phase ONCE per tick over
  the union of the touched sections (AC-0356 — a sustained fluid flow fired ~550 on_edit/s
  into an unbounded queue the 3 ms/frame drain could never catch; batched, the queue holds at
  a few K entries with settled light unchanged). A far (h-only) column is **never seeded
  into the engine as all air** (a stale all-air seam mis-carries sky across the promotion
  re-seed); a far→full promotion re-seeds the WHOLE column top-down. One `DirectionalLight3D`
  sun is modulated by `Game.time_of_day`; the mesh stores noon light and the shader uniform
  `u_day` does the darkening (AC-0204 — no day factor anywhere in the build path). Light is
   MONOTONE: the engine only raises (relax never lowers), so a column keeps the light its
   neighbors contributed until the column itself exits the band and re-seeds — a since-evicted
   neighbor's contribution is never lowered (there is no lowering pass; the display-consistent
   consequence: the settled state and its baked mesh agree, both holding the last full
   re-derivation of the column's residency — the AC-0286 "old bake is always the settled
   light" class). Concretely, a column RETAINED across a recenter (in both the old and the new
   real band) settles to max(old-domain fixed point, new-domain fixed point) — the RESIDENCY
   light (AC-0361: cell-exact on the live state; the aquifer's y≤28 lava pools made the class
   measurable for the first time — 123 cells, +1..+4 levels, at the corners facing the
   since-evicted neighbors; closer to the full-world truth than either fixed point alone). The
   halo arm's reference models the unseeded halo as an OPAQUE WALL (no light crosses at any
   depth — not the skip-fill / air-above-H terrain) and the retained columns against the
   residency union (AC-0334's glow-zero model completed; the arm's `resid_over` census reports
   the residency cells, report-only).
- **Far data (the draw band, taxi > `band0_r`, + the offscreen interior collar)**: columns
  store **no slabs at all** — just a `[H u16×256][biome×256][top-block×256]` payload
  (~1 KB, ~198 B on disk; AC-0284b; the v6 flag bit 1 — **write-dead since AC-0287**:
  the save filter never encodes a far column; the bit-1 shape survives on disk only in
  pre-AC-0287 saves and is decode-only). Gen builds only the 3 coarse
  SURFACE fields (the ones H depends on) + the heights pass for a data-less column, against
  the FULL path's cost — **re-measured by AC-0363 (2026-09-26) at 5,502 ± 25 µs per chunk on
  the current tree**, i.e. ≈ 20.8 µs per column at 256 columns per chunk. The sentence that
  used to sit here ("~92 µs/col vs ~1.7 ms full (≈18×)") is **stale AND unit-inconsistent** —
  both figures predate the cave series (AC-0290/AC-0291/AC-0292/AC-0359/AC-0360) and the ratio
  divided a per-chunk figure by a per-column one, so it never meant anything; AC-0363's
  attribution names the real history instead: 2,884 µs/chunk after the C48 lattice, 4,532 after
  the Voronoi aquifers (the per-block 4-nearest search alone is ~1.6 ms), 5,711 after the P4
  contents and 5,319 after the deep-only tunnel gate, 4,758 after the AC-0367-B vanilla tunnel
  wiring (the 4 dense builds cost +347 µs but the 11× smaller void population saves −842 µs of
  per-cell aquifer fill + −98 µs of drip), with the planet pieces contributing
  nothing to generation (`git diff` over the native lane is empty across them).
  H is bit-exact
  with the full path (the stored H *is* the heightmap — promotion must not shift terrain).
  **AC-0312: the draw band is THREE tiers** (`_lod_tier_of`, the render-edge guard first —
  a knob sitting past the render radius is data-only): **BAND A** (`sim` < taxi ≤
  `medium_start`) — the far column MATERIALIZED to the full 16×16×16 no-cave fill: the
  drain's high lane runs `generate_resl(skip=1)` + the full-column build under a cached
  heightmap-sky eff (`AweMesh.sky_eff`, `chunk.far_eff`), water/trees/flowers included —
  full-LOD draw, no engine light; **AC-0397: the fill stands on the far payload's carved
  top** (solid 0..payload H, the payload top row, the far emit's water rule — the mat
  entry hands the worker the column's 1024-byte payload; pre-fix the fill stood on the
  un-carved heightmap, up to 91 blocks proud of the carved ground on the user-settings
  ring, 1.63 % of the ring's columns) — the band-A surface is the far emit's surface;
  **BAND B** (`medium_start` < taxi ≤ `low_start`) — 8×8
  avg (`low_emit_avg` at G=8); **BAND C** (`low_start` < taxi < render) — 4×4 avg
  (`h_avg_emit`); both avg tiers byte-identical to the slab emitter on the same skip-fill
  grid, heightmap sky, and the WATER EXCEPTION (a water-topped cell emits its top face in
  the translucent water material). Nothing in a draw tier ever shows caves. The
  skip=1 slab-skip path is therefore LIVE again (the `cols_skip` gen census reads the
  band-A count). A far column entering the real band schedules a FULL regen (AC-0283 P2
  late-landing machinery). **AC-0346 — the skip/band contract is TOTAL**: the skip-flag
  policy at enqueue (`_gen_skip_flag`) is tier-total — EVERY non-real tier (1–4,
  including the data-only tier past the render edge) is generated far (skip 2); only
  tier 0 is ever full (skip 0; skip 1 is the band-A materialization fill run by the
  drain). Pre-AC-0346 the tier check missed tier 4, so a data-only column could land
  FULL through the `band_of` / offscreen-frustum tail (and the band 1→1 reband hop was
  a no-op, so the data rode at band A indefinitely — the AC-0312 violation). The
  matching DATA-RESOLUTION INVARIANT at recenter: any column OUTSIDE the real band that
  holds full data (not `c.far`) is demoted to the far representation on EVERY recenter
  (the crossing test, generalized — the 1→1 hop now actually re-bands; a mid-regen
  landing that exits a frame later is cleared by the next recenter).
  `star_halo_promotes` is the total halo→real crossing count (the far-side promotion —
  the owed regen — is counted at the crossing too).
  AC-0286 completes the promotion contract: (1) **detection** — the crossing is owed from
  THREE points: the recenter walk, an in-band disk load, and a FAR data landing already
  inside the real band (gen-queue lag past the crossing); the owed step retries the enqueue
  until it lands (cap-drop = retry, not loss) — exactly ONE accepted full regen per
  residency (freed/reloaded or demoted+re-crossed = new residency); (2) **retain-swap** —
  the landing never hides/un-settles the existing slabs: the far low keeps showing, each
  full slab's landing atomically flips (high on / low off) behind the settled-payload gate,
  so the column never holes (a slab is "owed" only once it has first shown a visible mesh)
  and never shows unlit (the old bake is always the settled light); (3) **single flood** —
  the was_far branch re-seeds the WHOLE column exactly once via `_star_seed_column` (a
  mid-regen demote lands unseeded; the re-entry re-seeds via the AC-0283 P3 path, a
  separate mechanism); (4) **burst** — `_promo_build` marks the landing column and
  `_promo_build_step` (per frame, beside the owed step in `_drain_build_queue`) dispatches
  its best pending slab through the SAME `_mesh_dispatch_hslab` (all gates unchanged),
  bypassing only the queue score — the conversion takes ~24+ frames instead of the flight's
  multi-thousand-deep build backlog. Permanent counters: `star_seed_count/us`,
  `promo_enq_count`, `promo_land_count/ms`, `star_late_landings_promo` (expect 0 — the
  retain-swap never HIDEs), `hslab_defer_settle`.
  **AC-0331 — the far-tier FLOOR** (`p_yfloor`, a SETTING since AC-0332 — the pair
  `yfloor_enabled` (bool, default true) + `yfloor_chunks_below_sea` (int, default 0,
  the plain 0..24 scale `Settings.YFLOOR_MAX`, no sentinel) with a Developer-tab
  row): the sub-waterline world of FAR columns is genuinely REMOVED — the far draw
  tiers draw only the world above the floor, and nothing changes from above (the
  water surface is bit-identical). Semantics (decided O3): a grid CELL
  is kept iff its topmost world-y > floor, kept WHOLE (sub-floor content inside a kept
  cell still counts in the solid test and the color); cells entirely below the floor are
  zeroed. The floor NEVER applies to the real band (tier 0 — `yfloor` stays −1). Three
  implementation points: (1) **avg tiers (bands B/C)** — the shared tail `avg_grid_emit`
  applies a post-fill mask over its 3-slab grid window (rows whose cell top ≤ floor are
  zeroed; at G=8 126 is a cell boundary, at G=4 the 124–127 cell is kept whole — the
  documented 2-block coarse cap); the fill loops and the float32 op order are untouched,
  so the byte-identity gate holds on the floor path (farab runs both emits at
  `yfloor=Data.SEA`); (2) **band A** — a per-voxel row gate inside `build_accs` (dflat/
  fflat rows below the floor zeroed per slab, in place) + the mat dispatch starts at the
  floor slab (si0 = floor/16; slabs 0..6 never mesh, `apply_accs` nulls their refs); the
  waterline row survives, so the water surface (the water-topped face in the translucent
  water material) is emitted as usual, and the CAP is the natural −Y face of the first
  kept voxel — no explicit cap code (for a water column that is the fluid's bottom face;
  the deep-ocean class is then fluid-only: no opaque mesh at all — the ladder's
  `band_a_fluid_only_cols`); (3) **the probes** — the far-column low-lane probes skip
  slabs entirely below the floor (`si*16+15 < floor`) so pruned slabs never re-dispatch;
  the mat handoff stamps 0..si1 unconditionally as before, so stamped-but-never-meshed
  slabs read done to the visibility-flip bookkeeping. Cost: the low-lane dispatch
  census drops ~25% (r16 `low_enqueue_n` 47847 → 36057) and the far slab censuses
  shrink accordingly (ladder band B 519 → 155, band C 318 → 94). Honest caveat:
  submerged INSIDE a far column below the floor you see the cap (water at 126 / the
  coarse 4×4 at 124), not the real ocean floor.
  **AC-0332 — the floor is a setting.** Derivation lives ONCE in
  `world.note_yfloor()` (next to the other two Settings band reads; `_far_floor_y()`
  is the seam every emitter/probe reads): `y_floor = -1` when the toggle is off,
  else `Data.SEA - n*16`. The `-1` is an INTERNAL sentinel produced only by the
  toggle — nothing in the 0..24 scale can yield it. The Developer tab carries a
  CheckBox + SpinBox row (the AC-0260 fix: typeable SpinBox, the exact small int 0
  reachable; the dependent spin dims while the toggle is off). The harness env
  preloads `AWECRAFT_YFLOOR=<0..24>` + `AWECRAFT_YFLOOR_ENABLED=<0|1>` (the
  `AWECRAFT_TM_HO`/`AWECRAFT_FOG_PCT` pattern — written into `Settings.values`
  WITHOUT `save()`, so the arms never clobber the user's cfg). Cache staleness on a
  value change: `note_yfloor` clears `chunk.far_eff` (the cached sky eff — floor-
  aware, must not outlive the change) on every resident far column and re-opens the
  band-A `far_mat` mark (with both probe caches invalidated, or the cached
  "complete" verdict keeps the column settled forever) so materialized columns
  re-materialize at the new floor. The pair is a BOOT/DEV KNOB: the change applies
  to newly built columns immediately, existing ones converge as they demote and
  re-mesh (band B/C lows keep their stamps — they re-emit on the normal re-lower);
  the LIVE RE-FLOOR storm (re-meshing the whole far field at once — the expensive ON
  direction) is DEFERRED, the follow-up designs both directions against measured
  churn.
- **AC-0205 — smooth ground ramps (a geometry toggle, not H)**: the ro scan in
  `build_accs` ramps the stair step where the rule fires — a rampable solid
  block (the Data `"ramp"` flag: grass/dirt/sand/snowy-grass, ids 1/2/4/12)
  with a non-solid cell above, one of whose four horizontal neighbours is
  non-solid with a rampable solid one below (water counts as air; buried
  ground and Δ2 never ramp). The vertical face is suppressed via `rmask` and
  the 45° quad (shade 0.9, the AC-0159 `s_corner_tag(2, j, …)` corner
  lighting of the riding column) is emitted into the SAME opaque acc, so the
  collider (derived from that acc) carries the ramp by construction — the
  `ramp` arm asserts mesh/collider agreement per slab in both toggle states.
  The toggle SHORT-CIRCUITS BEFORE geometry: `Ctx.ramps` (parsed from the
  dispatch ctx) off = rmask 0 + empty record list = the pre-feature byte
  path (the arm's REF fingerprint checks the OFF state against the
  pre-feature .so + `on_differs` proves the ON state moves it). FAR/COARSE
  DECISION: the coarse/far tiers do NOT ramp — the branch is guarded by
  `!C.coarse` and the far emits never enter it — so H stays bit-exact
  (farab `h_mismatch` 0, genhash 25/25): ramps are geometry derived from H,
  never H itself. Persistence follows the AC-0088/0089/0389 pattern: the
  `smooth_ramps` setting (DEFAULT OFF, `sanitize_bool` clamped) on the
  Settings surface + `world.note_ramps()` (the geom-epoch bump re-derives
  mesh + collider band-wide) + the harness env override `AWECRAFT_RAMPS=0|1`
  (written into `Settings.values` without `save()`).
- **AC-0395 — noclip (a PLAYER-collision toggle, not H, not a new model)**:
  the user's own request (2026-10-03, "an option for disabling my characters
  collision box so I can [fly] through blocks") — a diagnostic instrument for
  inspecting geometry without walls in the way. The toggle is the player's
  (player.gd `_noclip_sync`, the viewmodel_occlude pattern: live value read
  every frame, applied on change): `col_shape.disabled` — the player's OWN
  `CollisionShape3D` (the node stays, disabled; the slab bodies, mobs, drops
  and the grid-DDA mine/place raycast are untouched — the DDA is a grid read,
  not a physics raycast, and the drop's ground is a grid read — so nothing
  else in the world changes in either state) — plus the AC-0145 `flying`
  state: noclip implies FREE FLIGHT, not merely "collision off" (the walk
  band's 26 m/s² radial gravity would free-fall the player through terrain —
  which cannot hover over a broken chunk; the flight branch applies no
  gravity at any altitude, so the radial gravity is not fought by
  construction; the `fly` key F stays the in-flight exit — pressing it with
  noclip on drops the player at gravity speed, the user's own escape). The
  void kill (`flat_h < -12`) is gated on `not _noclip`: the tool's purpose is
  being BELOW the surface, and a hard-kill is a wall-in-the-way of exactly
  that (walking/flight without noclip keeps it — the player cannot normally
  get below the local floor). Fall damage / drown / hunger already skip for
  `flying`; lava damage stays (documented, not gated). The state that ships
  is exactly today's: `noclip` defaults OFF, the sync is a no-op, and the
  OFF-path is byte-identical by construction (proven by the `noclip` arm's
  state-0 stop + the same-path repeat stop |Δx| < 0.15 m, and by the
  movement arms' standing values unchanged at the default). Persistence
  follows the AC-0205/AC-0389/AC-0394 pattern: the `noclip` setting (DEFAULT
  OFF, `sanitize_bool` clamped) on the Settings surface (the user called it
  "an option" — a player-facing switch lives there, not on a key: a
  one-keystroke path is the "left on by accident" route the ticket forbids)
  + the harness env override `AWECRAFT_NOCLIP=0|1` (preloaded at boot
  WITHOUT save in player.gd `_ready`). The "not left on by accident" pair to
  the default OFF is the one-line indicator label on the player's debug
  CanvasLayer (visible only while on). Proof: the `noclip` arm
  (`tasks/AC-0395/` — the stop / pass-through by cell occupancy / same-cell
  DDA in both states / count-identical StaticBody3D census / same-path
  repeat / env-preload run) + the before/after cave renders.
- **AC-0398 — modern per-vertex lighting (a SHADING toggle, not H)**: the
  per-face shading constant `FSH` and the 4-level `AO_MULT` corner steps
  (both AC-0159) plateau across the terrain, so a step edge renders as a hard
  40–60% band on every stair contour. The modern model replaces both with
  CONTINUOUS geometric fields derived from a per-build **18×18 column-top
  grid** (topmost solid y per snap-box column, −1 = none; the same
  coordinates as `snap`, built once per chunk in `build_accs` — row-wise
  top-down scan — ONLY when `ctx.modern && !coarse`): the sky term
  `sl = clampf(1 − 0.4·occl, MIN_AMB, 1)`, `occl = Σ_d w_d·max(0, H_d − by +
  1)` over the 4 cardinal (w 0.5) + 4 diagonal (w 0.25) neighbour columns of
  the corner (0→1.0, 1→0.8, 2→0.6, 3→0.5 — the Java Fancy levels as a
  continuous function of the neighbour HEIGHTS; a buried corner saturates to
  the MIN_AMB floor so caves stay dark), and the face-shade term
  `oshade = 0.5·FSH[fi] + 0.5·clamp(dot(N, SUN)/SUN_y, 0, 1)` where N is the
  per-vertex geometric normal (central difference of the 4 cardinal column
  tops; a missing neighbour reads the corner column's own top, so a
  chunk-edge corner never invents a slope) and SUN = normalize(0.25, 1,
  0.10) — a flat TOP stays exactly FSH (1.0), a flat side reads 0.4–0.525,
  a slope vertex falls in between (the ramp quad's corners each carry their
  own — the fixed 0.9 is gone). The three smooth emit sites
  (`emit_ro_merged`/`emit_faces`/`emit_ramp`) take the grid (`hgp`, null =
  pre-feature) and compute the per-corner `(sl, oshade)` in the modern
  branch; the MERGE key becomes `(id, fni, mask, s, oshade)` (a gradient
  cannot cross a merge — the product alone is not enough, the r and b
  channels carry s and oshade·s separately). The toggle SHORT-CIRCUITS
  BEFORE shading: `hgp == null` = every emit site takes its pre-feature
  branch, so OFF is byte-identical to the pre-AC-0398 mesh. **POLARITY
  NOTE**: the game default is ON (`modern_light`, the user asked for the
  interpolated look) but the C++ `parse_ctx` key-absent default is OFF — the
  arms build their ctx dicts by hand (no `modern` key) and the ramp arm's
  stored `_RAMP_REF` fingerprint is pre-AC-0398, so a hand-built ctx must
  stay on the pre-feature path (harness.gd is pristine). The live world
  always writes the key at boot (`note_modern`), so the game path is
  explicit in both states. The change is COLOUR-ONLY: no geometry, so
  `note_modern()` re-meshes through the tex-refresh drain but does NOT bump
  `geom_epoch` (the collider is derived from the slab's opaque surface and
  is untouched — unlike `note_ramps`). H is untouched (the grid is derived
  from `snap`, never written back — genhash 25/25 byte-identical).
  Persistence follows the AC-0205 pattern: the `modern_light` setting
  (DEFAULT ON, `sanitize_bool` clamped) on the Settings surface +
  `world.note_modern()` + the harness env override `AWECRAFT_MODERN=0|1`
  (written into `Settings.values` without `save()`).
- **AC-0401 — the fog-wall partition + the deck character + the limb gate**:
  the user's four reports (too many small clouds; the low LOD should have NO limb
  effect, only fog; z-fighting between the clouds / the low LOD / the satellite
  LOD; the high-detail terrain should not be visible from space) all reduce to
  ONE contract violation: the satellite body owns the rule “the body is only
  where the world's depth fog has already fully faded the world (d >= fog_far)”,
  but the near tiers kept drawing PAST the wall (at 100% fog colour, coplanar
  with the body's own displaced terrain — the fog-colour diamond patch in the
  1600/2600 m orbital frames, the flicker in the 332-400 m band). The fix:
  (1) PARTITION — every near-field material discards fragments at d >= u_fog_far
  (the four chunk_lit_*.gdshader kinds, lod_avg.gdshader, fluid_anim{,_bf}.
  gdshader); u_fog_far is the same DayNight.fog_far(render_radius,
  fog_start_pct) main.gd puts on env.fog_depth_end (one number, one home), pushed
  change-gated by world.gd `_ac0401_push()` (main.gd already pushes it to
  `_lod_avg_mat` from the env). The engine fog fade is the whole dissolve as the
  camera climbs (no pop); the body's haz_d rim at the wall is the seam (the
  single-source u_air, AC-0400 preserved); from orbit the disc is the body alone.
  There is NO new threshold: the “certain height” where the high detail vanishes
  IS the body's own fog wall, checked against the body's own op ramp by
  construction (the near field stops exactly where the body's existence begins).
  (2) RADIUS ORDERING — satellite_body.gdshader gains a vertex stage moving the
  displaced surface 2 m radially inward (mesh origin = sphere centre: local ==
  radial), so wherever the same terrain still coexists (relief straddling the
  wall) the near tiers win the depth test by construction. (3) DECK CHARACTER
  — cloud_layer.gdshader behind `u_deck` (Settings `cloud_deck`, DEFAULT ON, the
  user asked; env AWECRAFT_CLOUDDECK): 1.0 = the field at 1/3 frequency (bigger
  masses), a tighter coverage window (fewer), a 0.60 band floor (clear gaps
  between the belts), softer edge windows, volumetric shading (puff brightness
  off the mid field + thickness darkening 0.70 → 0.58); 0.0 (the shader default)
  selects the exact pre-AC-0401 constants (r9 path, bit-identical) — the
  short-circuit before the work. (4) LIMB GATE — aero_sky_gradient.gdshader's
  limb term is multiplied by mix(1.0, u_space, u_limb_gate) (Settings
  `limb_space`, DEFAULT ON, the user asked; env AWECRAFT_LIMB): the rim is an
  orbit instrument — no glow below the flight band (u_space 0), full rim from
  orbit; u_limb_gate 0.0 (the shader default) is the pre-AC-0401 glow at every
  altitude. PUSH PATH DEVIATION: both switches ride world.gd `_ac0401_push()`
  reaching the cloud/sky materials through the PARENT Main node (main.gd is
  fence-locked by the parallel session; the shader-side defaults are OFF, so a
  material without the push keeps the old look; the push is per-frame,
  change-gated, and the values are read live from Settings). The switches are
  render-path only: generation untouched (genhash 25/25), the cloud shells
  keep their exact radii/centres, and the AC-0398/AC-0399/AC-0400 behaviours
  (interpolated lighting, view-weighted fill, single-source seam) stand.
- **AC-0451 P1 — the near-field discard becomes a RULE, landed inert
  (stubbed)**: the handover between the near tiers and the satellite body
  is a distance gap by construction (near dies at d >= u_fog_far, the
  body's op ramp only becomes solid at u_render_edge = (render_radius+1)*16
  — the ring in between belongs to neither; from the air it is the wide
  disc under the player). The fix makes it a RULE — "stop drawing only
  where something else is already drawing" — asked of the layer that
  would take over. Every near-field `u_fog_far` discard (the eight
  chunk_lit_*.gdshader, lod_avg.gdshader + its AC-0446 seam twin,
  fluid_anim{,_bf}.gdshader) now routes through `ac0451_covered(d)`
  (contract comment in chunk_lit_opaque.gdshader): P1 lands it as a
  MARKED STUB answering false for every d, so the discard fires exactly
  where it fired pre-ticket — P1 changes nothing the player can see, and
  byte-identical A/B renders (aerial h≈300 nadir / ground / render-edge
  + the switch ON) are the acceptance proof (`tasks/AC-0451/`). The
  switch `AWECRAFT_COVERAGE=0|1` is env-only (NO Options row — the
  AC-0445 precedent: a correctness rule, not a toggleable look), pushed
  change-gated as `u_coverage` by `world._ac0401_push()` to the same
  material set as `u_fog_far` (+ `_lod_avg_material`, the AC-0443
  latch-only-when-landed pattern; both lod variants declare it so the
  AC-0446 material-shader swap keeps the stored parameter valid). P2
  turns the real coverage query on (the switch then governs it); the
  body's own discard (satellite_body.gdshader) is the handover's other
  half and is untouched in P1.
- **AC-0402 — the sky's altitude-aware space blend (the "leaving a planet"
  half)**: the user's report — the sky-to-space transition completes by ~1600
  m (space term 0.13→0.92 over 700–1600 m, fully black by 1600 m, the same
  state at every altitude above it) — is that the sky's BACKGROUND blend rode
  the physics flight-band S (500–2000 m, main.gd), which is a BAND, not a
  climb. The fix gives the background its own stretched window:
  aero_sky_gradient.gdshader blends `ws = mix(mix(S², S, u), mix(Ss², Ss, u),
  u_sky_alt)`, where Ss = `u_space_sky` is pushed PER FRAME by
  world.gd `_ac0401_push()` from the SAME radial altitude but the window
  BAND_WALK_MAX .. BAND_FLY_MIN×1.6 (the constants read off the live player —
  one number, one home; ~0.04/0.44/0.92 at the 700/1600/2600 m frames — so the
  blue thins gradually over the whole climb instead of snapping to black).
  The switch is Settings `sky_altitude` (DEFAULT ON — the user story asked
  for it; env AWECRAFT_SKYALT=0|1): OFF (u_sky_alt 0.0, also the shader
  default) makes ws exactly the pre-AC-0402 expression, bit-identical, and
  the per-frame push is skipped (short-circuit before the work). DELIBERATE
  DEVIATION from the AC-0386 "one number, one home" contract: the physics
  band stays the home for the limb gate, the star opacity and the sun-glow
  fade (all unchanged); the background blend alone gets a documented
  sky-specific derivation from the same live constants, because the flight
  band's purpose is the walk/fly split, not the sky. D5 of the same ticket
  ("the planet as a pale grey ball at some times of day") was found to be
  NONE of the three pale-planet causes (uncompiled shader, fog erasure, body
  day/night re-weight — the latter is identity at the T0.5 nadir) but the
  cloud deck's r9-character overcast phase (cloud_amount 0.75 at noon ×
  u_boost 2.2 = an opaque neutral veil), already addressed by AC-0401's
  default-ON deck re-characterisation — reported, no deck change.
- **AC-0417 — sky-local-zenith-and-atmosphere-height (SUPERSEDES the
  AC-0402 window and REDEFINES its switch)**: the user's three reports,
  one root cause: the sky was painted against WORLD Y (the face-centre
  radial), so the "horizon" sat at a different place for every position
  on the sphere (measured at 841 m true altitude: face-centre top-20 rows
  (210,250,255) pale vs a 5600 m in-plane offset position (0,67,252)
  saturated — same altitude, Δ up to 210/255 per channel); the blue-to-
  space transition ran to 3200 m while the body's full-establishment
  threshold was 526 m (the ~700 m gap); and the coverage gap behind the
  body's dissolve read the dark below-horizon branch, not haze. The fix:
  the sky's `sky()` splits on `u_sky_alt` into `sky_off()` (the
  pre-AC-0402 body VERBATIM — h = dir.y, the S²/S window, the rim at
  u_limb_radius/300 gated on u_space: OFF is bit-for-bit pre-AC-0402, not
  pre-AC-0417, per the ticket) and `sky_on()`: the gradient is keyed to
  the LOCAL zenith (hl = dot(dir, normalize(-u_limb_center)) — the
  substitution the ticket names; below the local tangent cone of the
  R+SEA disc the background is the single-source AIR colour `u_air`,
  above it SPACE_SKY — two colours + one cone, the cone keeping the limb
  term), and ONE atmosphere height A (`Aero.atmosphere_height()`,
  default 1200 m, env AWECRAFT_ATMO — one number, one home, the
  AC-0386 contract applied to the sky itself) drives every consumer: the
  sky's space blend (`Aero.sky_space(alt)` = smoothstep(0.25A, A, alt) —
  measured on the pushed uniform: 0.006/0.322/0.650/0.917/1.000 at
  341/641/841/1041/1341 m), the star field's full-opacity point (the A
  window — at day the stars are visible exactly when the sky is space;
  night unchanged), the sun-glow fade, the body's `h_full` (DIAGNOSTIC
  ONLY — the per-fragment opacity stays fog-distance driven and the fog
  wall stays render-distance-coupled, the AC-0415 contract; op_nadir
  reaches 1.0 at 526 m, stated) and the limb's geometry (clause D:
  `Aero.atmo_limb_radius(R)` = R + A tangent cone +
  `Aero.atmo_limb_falloff()` = 0.25A — the fixed 300 m becomes a stated
  fraction of A; the glow now reaches 20.38° PAST the cloud-top tangent
  at 1341 m instead of ending 5.85° short of it; the AC-0414
  LOADED-gate already in the tree is the fake-planet gate any
  limb-radius work rides on; the cloud-tops-inside-A invariant is
  asserted once in `_ac0401_push` — 450 < 1200, loud push_warning if
  violated). Addendum 2: the deck is washed by the limb — the cloud
  material takes the same air colour it already has (u_vol_air) and the
  same impact-parameter haze factor the limb term uses (ac0417_wash(),
  one home, gated to cameras at/above the A shell — ground views
  bit-identical; the engine fog stays off). `u_air` is the 8-bit DISPLAY
  value of `Aero.fog_display(t)` in the sky pass (the pass pre-decodes
  under Forward+, AC-0242); every other consumer takes the
  srgb_to_linear of the SAME 8-bit source (`Aero.fog_display()`
  refactored to `fog_display_srgb()` — bit-identical output). Stated
  deviations: h_first STAYS fog-derived (re-deriving it against A gives
  sqrt((R+A)² + fog_far²) − R ≈ 1211 m > A — the rim would pop in at full
  opacity past the space transition); the star's day opacity = the A
  window (the stars are an orbit instrument). Render evidence (lavapipe
  proxy): tasks/AC-0417/AC-0417-results.html (F1 position pair, the A
  ladder on pushed uniforms, the F3 gap, the clause-D before/after pair
  at 1341 m; gates: genhash 25/25 byte-identical, shaderforce 12/12,
  farab h_mismatch 0, satellite ok (h_full 1200 diagnostic), farhigh
  leg2 3/3 all-FACET, SMOKE ok, G0 0/0). **AC-0429 — the lower boundary
  as a concept is gone** (the user's correction to the AC-0428 blend:
  "the sky box can't have a bottom edge, we are in space! We can't fake
  the horizon, the planet and satellite is the horizon" — the blend
  removed the STEP at the local horizon but kept the box: the anchor,
  the band, the u_air floor below it). The below-branch fill (the
  "air floor" AC-0417 left below the local tangent cone; AC-0422 made
  it u_air at every altitude; AC-0428 anchored the gradient to it) now
  blends to `space_color` with the floor's space weight
  `ws = smoothstep(0, 0.3, w)`, the gradient's horizon ANCHOR blends to
  `space_color` with the SAME ws (the colour at `hl = 0` stays
  continuous for every w: |seam| = |horizon − u_air|·(1−ws), 0 from
  ws = 1 — no line, no band), the horizon haze band dies with ws
  (the "air seen edge-on" of the floor is a ground-level phenomenon),
  and the thinning weight (w·u — the AC-0428 uniform rate) + the limb
  air-column term are untouched. `u_air` survives ONLY at w = 0 (the
  ground-level AC-0384 r8 fog seam). Below the local horizon the sky is
  the same black + stars as the space above; the only content of the
  lower frame is the planet's disc, its u_air rim haze and the limb
  glow — the planet IS the horizon. Switch: `no_sky_floor` (default
  ON), `AWECRAFT_NOSKYFLOOR=0|1`, `u_no_floor` on the sky material
  (0.0 = the pre-AC-0429 path bit-for-bit); `sky_off` untouched (the
  sky's off state stays byte-identical). Evidence
  `tasks/AC-0429/AC-0429-results.html` (the user's 800 m frame
  re-taken: below the horizon 246.9–248.2 → 0.00 spread 0.00 flat
  space + stars, the only step the planet's limb).
- **AC-0436 — the moon (the night's directional light source)**: the
  AC-0384 §29 whole-experience assessment found day at target and
  night not (the ground a near-black void at the 0.20 light floor —
  measured 4.0/255 luma vs 98.4 by day; the orbit planet a faint
  mottle at the 0.18 floor; the HUD the brightest object). Both named
  causes were confirmed: (1) the floor does die in the tone mapping —
  ACES + exposure 0.85 + the 1.1 contrast adjustment put a hard dead
  zone below ~L 0.28 for the atlas greens, so the 0.20 floor outputs
  0/255 literally (measured, not approximated); (2) there was no moon
  as a light source — the only DirectionalLight3D is the sun (0.1
  energy pointing below the horizon at night), every sky-light term is
  × u_day (0.0 at night), and the sky pass' body-flip disc (the only
  "moon") was a ~6 px dot at 0.3 brightness that nothing answered to.
  The fix is the sun's ANTIPODE as a real night source: the
  direction-to-moon IS `DayNight.sun_direction(t)` (the sun sits at
  −sun_direction, so the antipode sits at +sun_direction, whose y is
  positive exactly when the sun is below the horizon), and
  `DayNight.MOON_L` (0.25, core/daynight.gd) is the ONE-SOURCE base
  intensity for the unshaded consumers; the satellite body (a LIT
  material — engine ambient ≈0.20 at night multiplies its ALBEDO on top
  of the shader's 0.18 floor, a triple product) scales its push by its
  documented `BODY_MOON_SCALE` (8×) so the moonlit hemisphere clears the
  ACES dead zone. Consumers, all switch-gated by the
  `moonlight` Settings bool (default ON — the shipped night IS the
  reported defect; the ambient_sky/cloud_gate re-ruling) with
  `AWECRAFT_MOON=0|1` env preload (world.gd, no save): the four
  `chunk_lit_*` shaders take `u_moon · max(dot(NORMAL, u_moon_dir),
  0)` on L (a per-fragment lambert off the mesh face normals — the
  mesher emits ARRAY_NORMAL — the night landscape's slopes; the 0.20
  floor never re-tuned, the moon ADDS), the satellite body's night
  factor gains `u_moon · moon_l` (the radial L_RADIAL convention — the
  moonlit hemisphere), the cloud volume's light march re-aims at
  `mix(u_sun, u_moon_dir, u_moon_w)` (self-shadow + HG phase +
  forward-scatter follow the moon: moonlit tops, silver lining) with
  the day factor `u_day + u_moon`, the sky pass' night disc gets the
  `u_moon` flag (a wider full-brightness window — the dot becomes a
  full moon; pushed by `world._ac0401_push` like the other look
  switches, the sky's `sun_dir` already points at the moon), and the
  star field takes `u_star_lift` (the 500-star shell is a mesh fact —
  main.gd — so density comes from the vertex-stage size lift: most
  quads ~1.2 px sub-pixel → ~1.9 px, ~68 of 500 visible at orbit
  before). OFF or day makes every consumer's added term exactly 0.0 /
  `mix(x, y, 0.0) = x` — the pre-AC-0436 night bit-identical by IEEE
  construction (and the day bit-identical, so the day-flatten failure
  mode of the ticket is structurally excluded — the day frames are
  measured before/after anyway). No DirectionalLight3D node: the
  unshaded chunk shaders never see engine lights, and a node would
  double-light the LIT satellite body (engine ambient × its u_day) —
  the shader terms are the moon. Evidence
  `tasks/AC-0436/AC-0436-results.html` (the r24 frames re-taken:
  night + day ground, night + day 2600 orbit, the A/B with
  AWECRAFT_MOON=0, the luminance + star-count census).
- **AC-0338 — the ring-level far batch (how bands B/C DRAW)**: the avg tiers'
  per-slab geometry is a DRAW-batched, not an emit-batched, thing. The emit is
  still the per-slab C++ avg emit (byte-identical — farab 1080/1080 + h_mismatch 0,
  halo, ladder, meshprobe are the standing proof), but the DRAW is per RING SECTOR:
  one `MeshInstance3D` per (avg tier, world-space 1/32-angle sector) — 32 sectors ×
  2 tiers = up to 64 children of `World` (`_ring_*` in `world.gd`), each wearing a
  merged `ArrayMesh` of every visible slab of that tier in that sector, in world
  coordinates on the column FACET (AC-0416: each slab's local `(x, si*16+y, z)` is
   mapped through `SphereMath.column_transform(cx, cz, R)` — the SAME transform
   the high tier's chunk node carries — and the normals ride the basis's
   inverse-transpose, renormalised, the water-exception surfaces included; the
   ring MI sits at the identity, so the baked vertices/normals are already world
   space. Pre-AC-0416 the merge used a FLAT offset `Vector3(cx*16, si*16, cz*16)`
   with unrotated normals, which stood the far tier above the curved high surface
   by the sagitta d²/2R (1.25 m @100, 16 m @358, 125 m @1000, 500 m @2000 — the
   user's "raised plateaus"); the `farhigh` standing instrument (HARNESS.md §1)
   is the gate — leg 2 classifies the live ring mesh facet-vs-flat, leg 1 reads
   the counterfactual sagitta on the battery columns) (surface 0 = the opaque avg in the shared `_lod_avg_mat()`; surfaces
  1/2 = the WATER EXCEPTION faces in the shared fluid materials — the two-pass
  camera-side cull is per surface and survives the merge). AC-0384 r8: the
  `_lod_avg_mat()` material (core/lod_avg.gdshader) took the far tier OFF the
  engine fog — `render_mode fog_disabled` + a hand-rolled per-fragment copy of
  the engine's own depth ramp (the "haze bridge", thinned to a plain u_air
  fade by AC-0400/AC-0404) — superseded by AC-0415: the duplicate is deleted
  and the material rides the engine environment fog like every other
  near-tier material (one ramp, one air colour, the fog switch governs this
  tier too — see the AC-0415 note in the §3 WorldEnvironment bullet; the full
  r8/AC-0399/AC-0400/AC-0404 history lives in those results pages). AC-0401:
  the annulus now ENDS at the fog wall — lod_avg.gdshader discards its fragments at d >= u_fog_far (the PARTITION; pre-AC-0401 it drew out to the render edge at 100% fog colour, coplanar with the body's displaced terrain: the orbital fog-colour patch + the 332-400 m z-fighting band). The body's haz_d rim at the wall is the seam (same u_air), so the AC-0400 single-source seam target is preserved — the fade now runs in the body's rim, not in the annulus. See the AC-0401 bullet in §4. The per-slab RECORD
  survives on the slot `MeshInstance3D`s that `c.low_instances` holds — the slots
  are OFF-TREE now (pooled exactly as before; their `.visible` flag is the far
  draw state the ring re-derives, and their `.mesh` is the exact emit arrays the
  harness byte gates read). A slab draws in the ring of its STORED tier stamp,
  NOT its column's live tier (the AC-0257 stale-tier window: a knob change or
  recenter leaves it at the old tier until the re-emit lands — it must keep
  SHOWING then, exactly as the old on-tree MIs did; classifying by live tier
  makes the slab vanish for the window — measured, AC-0338 resumed). Exit
  teardown: the resident columns' off-tree slots are freed explicitly in
  `_pool_free_all` — this Godot (4.7.1) does not release an off-tree node
  referenced only from a freed node's script state (the pooled MIs always had
  this treatment; the slots join them). Churn (attach / drop / flip / column
  evict) marks the
  column's sector(s) dirty; the coalesced step in `_low_step` re-merges ONE sector
  per frame (per-sector 250 ms cooldown, 60 ms global floor). The sector
  partition is STATIC in world space (chunk nodes sit at absolute `(cx*16, cz*16)`
  and recenter only evicts/creates), so a recenter re-buckets nothing — its cost
  is a paced far-field re-draw over a few seconds (a rebuild is whole-sector: the
  `ArrayMesh` API has no in-place surface append, and a full-tier GDScript re-merge
  is ~1.1 s at the R50 converged scale — the measured reason the tiers are
  sectorized instead of one MI per tier). Memory: the sector meshes are one extra
  copy of the visible far geometry (the slot meshes survive for the gates).
- **The cave field (the single density field, AC-0215 / the vanilla density router since AC-0347
  P2 / the vanilla tunnel wiring at AC-0367 piece B)**: caves are wherever the ONE density field
  reads solid→air, and the
  surface AND the caves come from the same field. **Since AC-0347 P2 (THE STRUCTURE) the field is
  vanilla's density ROUTER** (Java 1.21.4 `overworld.json` `final_density`'s `range_choice`,
  verified against the shipped JSON; density > 0 = solid in both conventions): with
  `k = H − y` (depth from the surface — NOT S_ramp, which saturates) and
  `K_CUT = 16` (the P3-recalibrated switch depth — inside the ticket's 10-25 band, set by
  measurement, AC-0347 P3 results page; R_BAND = 10 stays the ramp saturation depth, and since
  the ramp reads +1 for k ≥ 9.5 the shallow branch stays degenerate — solid + entrance slits —
  across its whole width, so the cut-continuity proof holds unchanged):
  `k < K_CUT: d = min(S_ramp(H,y), 5·entrances)` (SHALLOW — S_ramp kept as the surface, the
  entrance family carves the deliberate openings; BIT-IDENTICAL to the pre-AC-0367-B router —
  the AC-0360 near-surface seal is structural); `k ≥ K_CUT: d = min(entrances,
  4·layer_c² + clamp(−1,1)(0.27+cheese_c) + clamp(0,0.5)(1.5−0.64·k/K_CUT),
  spaghetti_2d + spaghetti_roughness, spaghetti_roughness + spaghetti_3d, noodle)` (DEEP — the
  base terrain contributes NOTHING: the solid/air decision below the shallow band IS the cave
  router; the suppressor is 0.5 at the cut and 0 at k = 2.34375·K_CUT = 37.5 — vanilla's 1.5/0.64
  constants as-is, anchored at the cut; the squared ONE-SIDED layer term gates the
  cheese caves into stacked levels in absolute y; AC-0367 piece B: the four vanilla tunnel
  sources join the deep min chain — the AC-0289 outside tunnel rule is GONE). The old `A(y)/DEEP_GROW/CAVE_AMP`
  depth-amplifier structure is GONE. The "air for sure above H+11" margin is now STRUCTURAL (no
  noise budget): for y ≥ H+10.5 the ramp clamps −1 exactly and the shallow branch reads
  `min(−1, 5·entrances) ≤ −1 < 0` for any noise values (and under the router the effective
  surface can only wobble DOWN — he ≤ H: d > 0 in the shallow branch requires S_ramp > 0, i.e.
  y ≤ H). **All ported noise is centered `2·(vn3−0.5)`** — the vanilla O(1) convention; the
  constants (0.27, 0.64, 1.5, 5, 4, 0.37) are only meaningful in those units. The noise fields
  (sampled by the `vn3` octave machine in both lanes — `AweNoise.vn3(x,y,z,s,first_oct,amps)` =
  `Σ(aᵢ·vnoise3(p·2^firstOctave·2^i)) / Σ|aᵢ|`, vanilla's octave machine which `fbm3` could not
  express; the scale MULTIPLIES the block coordinate): **cheese** = vanilla's `cave_cheese`
  AS-IS `{firstOctave −8, [0.5,1,2,1,2,1,0,2,0]}` at xz 1.0 / y 0.6667, seed+301, on the CAVE
  lattice (P1; dense samples read mean 0.503294 / std 0.088558 / max|C−0.5| = 0.353027);
  **layer** = vanilla's `cave_layer` AS-IS `{firstOctave −8, [1.0]}` at xz 1.0 / y 8.0, seed+302
  (P2; the ~32-block vertical period rides 4 samples/period on the cave lattice — pre-AC-0359 it
  was evaluated DENSE in the scan, it cannot ride the 48-block SURFACE lattice, AC-0344);
  **entrances** = the vanilla `caves/entrances` function — AC-0367 piece B: the FULL vanilla
  form INCLUDING its spaghetti min, `min( base, spaghetti_roughness + spaghetti_3d )` with
  `base = 0.37 + 2·(E−0.5) + 0.3·(1−clamp01((y−54)/40))` and E = `cave_entrance` AS-IS
  `{firstOctave −7, [0.4,0.5,1.0]}` at xz 0.75 / y 0.5, seed+306 (the +64 shift maps
  vanilla's from_y −10 / to_y 30 onto our 54 / 94; the 0.37 offset makes entrances RARE) — the
  y-gradient stays ANALYTIC per-y (exact under trilinear), E is read from the cave lattice; the
  spaghetti min enters the deep branch as the `spaghetti_roughness + spaghetti_3d` term (below).
  **AC-0359 (C48 — the selective lattice raise, the AC-0344 verdict)**: the CAVE family (cheese
  + the 4 vanilla tunnel sources [AC-0367 piece B — the 3 AC-0289 stand-in fields they replaced]
  + layer + entrance) rides a SECOND lattice — 48 y-cells of the 384-block
  height = **8-block Y cells** (Bedrock's resolution; `GY_CELLS_CAVE = 48`, FieldC 7×49×7 =
  2401 pts, same xz cells as the coarse lattice) — while the SURFACE + ORE fields (f_sc/f_sh/
  f_sr, f_ore1-3) stay on the original 48-block-y coarse lattice (`GY_CELLS = 8`, 441 pts); the
  split is what keeps the SURFACE H bit-exact by construction (the cave lattice never feeds the
  3 surface fields / the heights pass / column_heights16). AC-0387: the FAR lanes (gen_far /
  gen_veg_cells) now BUILD the cave lattice too (the carved_top_pass runs the full path's
  per-column dens_at scan + aquifer + carver so the far/veg H is the full path's CARVED top —
  the promotion contract, pre-AC-0387 they emitted the un-carved surface_h, which this ticket
  measured wrong on 866/102,400 columns, worst a 91-block canyon). The in-column AND veg-margin scans read every cave input trilinearly off
  the cave lattice (the dense per-block vn3 calls LEFT the scan at AC-0359 — per-chunk
  generation 5076→2884 µs, the scan stage 4373→1291 µs); the dense sources `density_layer` /
  `density_entrance` stay bound as the genprobe lockstep references. The deep zone is now
  structured stone (k 50-80 air 78.7%→21.8%, an 85%-solid band at abs y 48-72, 98.1% of air
  runs ≤32 blocks, openings avg depth 92→21); the second-order trilinear fidelity residuals are
  recorded (not fixed) in `tasks/AC-0359/AC-0359-results.html` (measured: the layer peak
  undershoot is 1.0 — a quintic-Perlin 1D slice is monotone between its lattice planes, so its
  extrema sit on the 32-block period planes, a subset of the 8-block rows; the entrance peak
  undershoot ≈0.996). The heightmap H (surface_h of the 3 coarse SURFACE fields) is structurally
  independent of the cave field: cave tuning MUST NOT touch f_sc/f_sh/f_sr or SEA (the far-band H
  bit-exactness + promotion contract — AC-0347 P2's thash proved H byte-identical before/after:
  `8df7aeb4…0dc4f11`, 21×21-chunk `column_heights16` SHA-256). The router's `max(…, pillars_choice)`
  outer term is AC-0292's (SEQUENCE). P3 (same ticket) recalibrated the surface openings /
  asymmetry against the measured censuses: K_CUT 10 → 16 (the first cave on intact columns
  deepens, the k 10-16 air set was proven 100% tunnel family, the stacked levels survive);
  the suppressor constants stayed vanilla as-is.
  **AC-0367 piece B (the vanilla tunnel wiring — the AC-0289 outside rule is DELETED)**:
  AC-0289's tunnel structure (three CAVE-LATTICE stand-in fields — `f_spag`/`f_nood`/`f_gate`,
  `fbm3` seeds +303/304/305 — with the outside edge-density rule
  `|f_spag−0.5| < 0.16·w` or `|f_nood−0.5| < 0.08·w`, `w = clamp01((f_gate−0.52)/0.06)`, applied
  as "tunnel air wins over solid" BEFORE the scan's solid flag) is GONE — the constants, the
  fields, `gate_weight`/`tunnel_air`/`tunnel_air_c`, the `AweGen` bindings and the genprobe
  tunnel block all removed. In its place the FOUR vanilla 1.21.4 tunnel sources (the piece-A
  ports, `AweGen::spag2d_density / spag3d_density / spagrough_density / noodle_density`, slots
  seed+337..346) ride the C48 cave lattice as 4 more `FieldC`'s (the dense expressions at the
  2,401 lattice points, the AC-0292 pillar pattern) and enter the DEEP-branch min chain:
  `min( 4·layer_c² + q + supp, entrances, spaghetti_2d + spaghetti_roughness,
  spaghetti_roughness + spaghetti_3d, noodle )` (min is associative — the exact `final_density` /
  `caves_entrances` structure; the outer pillar `max` stays in the scan). The tunnels no longer
  "win over" the router — they ARE a min term of it (the vanilla structure). DEEP-ONLY
  (`k ≥ K_CUT`): vanilla applies the spag3d/noodle terms at all depths, but the shallow branch
  must stay bit-identical or the AC-0360 near-surface seal (32,249→0 void) comes back — the
  deviation is recorded. Built and read ONLY on the full path (skip==0) and in the deep band,
  so the heightmap H (surface_h of the 3 SURFACE fields) / the skip payload stay bit-exact by
  construction (thash `8df7aeb4…0dc4f11` byte-identical before/after + farab `h_mismatch` 0
  prove it). AC-0387 moved the FAR payload's H off that heightmap: the far lane now runs the
  same per-column sequence (the `carved_top_pass`), so the far H is the full path's carved
  top — the full/far H identity holds by construction (genhash 25/25 unchanged — the hash
  covers the full path only, which this ticket does not touch). The dense source functions are `AweGen::density_cave` (the cheese),
  `AweGen::spag2d_density / spag3d_density / spagrough_density / noodle_density` (the vanilla
  tunnels) and `AweGen::density_layer / density_entrance / dens_at` (the router's layer /
  entrance family / the 9-arg router itself); the genprobe arm mirrors those exact expressions
  in GDScript (the lockstep contract — a parameter change updates both sides in the same task;
  the piece-B run: 10,300/10,300 f64-exact, the tunnel block's 1,200 pts replaced by the dens
  block covering the new chain). **AC-0342 (the fluid decision BEFORE the carve —
  the vanilla ordering)**: the aquifer is decided from PRE-CARVE inputs only — `gen_flat`'s fill
  writes water at `y ∈ [he+1, SEA]` only when the heightmap says `H < SEA` (the gate READS H,
  never writes it). `he` (the post-carve topmost solid) remains the fill START, so a submarine
  cave open to the sea still floods to sea level — the vanilla caption, "a cave under the sea
  floor, flooded to sea level" — while a land column (H ≥ SEA) stays DRY whatever the caves
  below do: a cave/tunnel mouth that removed the column's top leaves air above its own floor
  (the y < 8 pockets keep their Y-only lava rule). The inverted `he < sea` gate it replaced let
  the carve feed back into the fluid — such a mouth filled the whole opening to y = SEA on land
  (a pool at water height in the middle of dry terrain) and a fully-caved column became a
  126-block water column. The skip path (he = H) and the far path already obeyed the pre-carve
  rule; the three paths now agree, so a demoted-then-promoted column can no longer change its
  water. H itself is untouched — the far-payload contract (thash `8df7aeb4…0dc4f11` byte-identical
  before/after + farab `h_mismatch` 0 is the proof).
- **The Voronoi aquifer (AC-0291 — Bedrock's per-cell local water tables, FULL PATH ONLY)**:
  the flat fill-to-SEA is gone on the full path — every underground pocket gets its own table.
  The model: cells 16×12×16 with corner offset (5,5,1); each center is corner+5/+5/+1 plus
  jitter 0–9 (xz) / 0–8 (y) from `hash3i` at seed+316/317/318. Cell status comes from 13 dense
  surface samples (`aqu_surface_h_dense` — the three coarse SURFACE fields' `surface_h` formula
  direct-evaluated at the sea slice y = SEA/64, 2 octaves each; pure f(world, seed), so chunk
  seams are consistent — it differs from the exact H only by the trilinear lattice residual):
  the own sample (k=0) sets the branch (global if the cell bottom is above it — water to SEA, or
  the lava layer when the cell sits in it; "sea" if the cell top pokes above a sample below sea —
  level SEA), else underground: exclusion (erosion < −0.225 ∧ 1.5−cy/128 > 0.9 → dry), then
  floodedness (`vn3` seed+311) vs thresholds (full > −0.3→0.8, partial > −0.8→0.4, both linear
  over 64 blocks below the lowest sample when that sample is under sea; flat 0.8/0.4 on land) —
  full → level SEA; partial → `40·⌊cy/40⌋+20` + spread quantized to {−10,−7,−4,−1,2,5,8}
  (spread noise seed+312, per 16×40×16 region) and **capped at the lowest sampled surface** (no
  vanilla +8: H here is the actual surface, so a lake can never sit above its rim — the
  open-pool artifact is structurally impossible). Lava type when level ≤ 54 (vanilla −10) ∧
  |lava noise| (seed+313, per 64×40×64 region) > 0.3. Per air block (`aqu_block`): the 4
  nearest of the 12 candidate centers; the barrier zone (2-nearest squared-distance gap < 25)
  applies pressure between differing-status cells in the cluster (between levels: 1+min(dist);
  lid ≤5 rows above the higher; floor ≤23 rows below the lower; water↔lava constant 6.0;
  +2·barrier noise seed+314) → `B_STONE` **only where y < he** (the rim never raises the
  surface). Else the nearest cell's status fills `y ≤ level` (water/lava). Then, per block, the
  global lava layer **y ≤ 10** (vanilla −54, "exists regardless of aquifers") supersedes the
  aquifer — it replaces the old y < 8 deep-pocket rule on the FULL path only (skip/far keep
  y < 8 bit-exact by construction, never building the table). Documented adaptations vs vanilla
  (plan.html §2 owns the full list): the cap (above), the erosion shifted-noise shift omitted,
  the barrier formula is the wiki's stated shape with the 5/23 constants, the deep floor 8→10,
  and — the load-bearing one for the AC-0342 contract — **aquifer fluid is gated to y < he**
  (same gate as the barrier stone): a cave that opens a land column's top gets its mouth DRY
  with the lake below, so open water in land columns stays 0 while the perched/cave lakes (all
  hidden, y < he — measured 272,366 cells / 17,983 columns in an 11×11 window, 2,165 columns
  with the surface ABOVE sea) are the feature. `generate_resl` returns real fl slabs on the
  full path: `fl = 8` marks the scheduled flowing tick on differing-status boundary fluids
  (the waterfalls — the fluid system flows them like sources) and on water at y = 11; the fl
  slabs round-trip through the v6 codec and mesh identically to fl = 0. Noise slots 311–315
  (floodedness/spread/barrier/lava/erosion) + 316/317/318 (jitter) are new; the five `aquifer_*`
  dense sources are genprobe-mirrored (standing lockstep 9400/9400 f64-exact). H / heights / SEA
  are untouched (writes are flat[] cells only; thash `8df7aeb4…0dc4f11` + farab `h_mismatch` 0
  are the standing proof; the genhash rebased 25/25 at AC-0291). Cost: ~1.4 ms of the fill stage
  (per-chunk 2884→4532 µs) — the per-block Voronoi over ~11,700 cave air blocks/chunk, with a
  sky-block fast path (y > he ∧ y > max_fluid ∧ y > 10 skips the 4-nearest search — 84% of the
  air blocks; it is load-bearing: without it the fill was 8.5 ms).
- **The classic carver pass (AC-0290 — the room / trunk / canyon family, POST-DENSITY)**: a second,
  independent carve runs in `gen_flat` AFTER the density fill (`g_t_fill_us`) and BEFORE veg
  (`g_t_carve_us`, ~20 µs/chunk measured): `build_carver_plan(cx, cz, seed, ell, feat)` draws the
  per-chunk plan from a dedicated splitmix64 stream `carve_chunk_seed(seed, cx, cz)` (the
  (cx+1000000)/(cz+2000000) salts — a pure `f(seed, cx, cz)`, no noise fields, so the AweNoise
  lockstep / genprobe surface is untouched) — a cave roll `u < 0.15` → position rolls (x/z uniform
  in-chunk, y 8..244) → 1-in-4 **main room** (h 1-14, Ø 5-15, the FLAT-FLOOR ellipse: full-ellipse
  floor at `y0 − ⌈ry⌉` + dome ceiling, plus an exit trunk 30-60 long) vs 3-in-4 **I/T trunk**
  (85-112 long, rx0 2-8 / ry0 1+rx0·(0.4+0.8u), 1-3 right-angle-ish branches 15-44 long attached in
  the middle half, the walk's flicker 0.6-1.4× with ~12% bubble jitter 1.6×/1.3×, ±0.25 rad/step
  wander, drift clamped ±0.5, y clamped 8..240); a canyon roll `u < 0.01` → the **ravine** (start
  y 74-131, thickness 2+4u², rx = thick/2·(0.75-1.0), ry = 3rx, meander rotation ±0.125/step,
  drift 0.05-0.15 blocks/step — NEARLY VERTICAL, the drift small enough that the tube's bottom and
  its surface break sit close together (a tight meander = the deep gully; a wide arc would only
  graze the surface), len `(45+105u)·df`, 1-block steps, deterministic path after setup). The apply
  (`carver_carve_column`, per local column with WORLD x/z for the ellipsoid q-test) carves each
  covered solid cell (`≠ 0/WATER/LAVA`) to AIR (to LAVA below y < 8), then walks the topmost solid
  down (`he2`) and — only where `he2 < he` — re-skins the new top with the fill's EXACT surface
  rule + the 3-deep dirt band; the caller updates `heff[]` so veg plants on the carved surface. The
  carver writes only `flat[]` cells: it NEVER touches the heights[] / surface fields / SEA — H does
  not move (thash `8df7aeb4…0dc4f11` byte-identical + farab `h_mismatch` 0 is the standing proof),
  only the EFFECTIVE surface (he) can drop (measured: ~600 opened columns, max drop ~29 blocks in a
  31×31 window; the drops are the ground truth, the topmost-solid census is the instrument). The
  skip (1/2) and far paths NEVER build the plan, so the far/skip payloads stay bit-exact by
  construction. Two accepted artifacts (documented, not fixed): the carve is PER-CHUNK, so a tube
  that meanders out of its home chunk loses the neighbor-side portion (the vanilla seam), and the
  veg pass runs AFTER the carver (the ticket's ordering), so trees may grow into a freshly-carved
  opening.
- **Pillars + veins + biome field + surface rules (AC-0292 — the cave series' finishing piece, FULL PATH ONLY)**: the
  deep-branch density scan (k = H−y ≥ 16, K_CUT) reads one more term per block — the **vanilla pillars** expression
  (Java 1.21.4 `caves/pillars` as-is): P = (2·Np + (−1−Nr))·(0.55+0.55·Nt)³ with Np = pillar noise {−7, [1,1],
  xz 25.0, y 0.3} seed+320, Nr = rareness {−8, [1], 1.0} +321, Nt = thickness +322 (every ported source centered
  2·(vn3−0.5)); P ≥ 0.03 makes the block PILLAR SOLID (the pillar term wins over the tunnel; it runs identically
  in the veg-margin scan — 83% of the dense-pillar solids sit on the cheese-air side: "pillars in the cheese").
  **Big ore veins** add density BLOBS to the thin `f_ore` speckle thresholds (which stay below): one vn3 field
  (seed+323) with nested per-read thresholds y<16 coal 0.80 / y<42 iron 0.78 / y<60 diamond 0.76 — the largest
  measured blob is 11,063 cells (the coal-seam family, seed 44, 11×11 window). The **3-D cave biome field** (one
  vn3, seed+319, {−7, [1,1]}, xz 0.5 / y 0.5) value-maps to deep-dark (<0.40) / dripstone (0.40–0.60) / lush
  (>0.60) — vanilla 1.21.4 `surface_rule`'s +64-shifted abs-y windows (deep-dark 1..63, dripstone 48..128,
  lush 64..128) — is read per column into a 16-band table (one read per level) and applied in the fill:
  **deepslate** (B_DEEPSLATE, id 32) at y<64 with a 64..71 blend from `rock_base` (seed+326; vanilla's
  true-below-0/false-above-8 mapped onto our absolute y), **sculk** (35) in deep-dark cells (<0.10 gate,
  seed+327) and **moss** (36) in lush cells (<0.06 gate, seed+328). A **post-carve drip pass** (dripstone
  biome only, `g_t_drip_us` ~238 µs/chunk): stalactites (33; 35% column gate +330, length +332) hang from
  cave ceilings into air, stalagmites (gate +331, length +335) rise from floors, and clay pools (34; 6%
  column gate +329, depth rolls +334/+336) swap WATER cells only — the aquifer tables never move (the AC-0342
  land-dry contract re-measured green: land open water 0, ocean surface 1081/1081). The full path's **bedrock
  band** y 0..4 = B_BEDROCK — the aquifer lava floor y≤10 supersedes it per block (the lava layer reads on
  top); the skip/far paths stay vein/pillar/biome-free by construction (y<8 / y0 bit-exact — no P4 source is
  ever read there), so H / the far payload / the promotion contract are untouched (thash `8df7aeb4…0dc4f11`
  byte-identical + farab `h_mismatch` 0; genhash rebased 25/25 at AC-0292). New block ids 32–36 in `data.gd`
  (table + atlas tiles from the Faithful 32x pack — all solid, drop themselves; pick 32/33/35/36, shovel 34).
  Noise slots 319, 320–323, 326–336 (333 obsidian untouched); the dense sources `density_pillar` /
  `density_vein` / `density_biome` are genprobe-mirrored as PERMANENT lockstep blocks (standing 10300/10300
  f64-exact). Cost: per-chunk 4532→5711 µs (+26%; field +456 — three new FieldC builds; scan +339 — the
  per-block pillar tril; fill +219; drip +238 new stage).
- **Edits on far / data-less columns (AC-0325)**: the flat write path has **no silent
  no-op**. `World.set_block` returns a bool and, when the target column holds no slabs
  (`data` empty — a node-only chunk that can sit data-less indefinitely since AC-0263's
  sync materialize), it performs a **record-only edit**: the cell diff `{b, f}` goes
  into `world.edits` (the authoritative edit store) and nothing else (no slab/fluid/
  light/queue machinery — there is no data to touch). `get_block` reads recorded edits
  back on such columns (air everywhere else), so the write is visible immediately;
  every data landing (threadgen / disk / sync) re-applies the diff via
  `_apply_edits_to_chunk`, so the read can never disagree with what the same edit does
  once the column is material. A far (h-only) column — 24 null slabs, `far` true —
  already carries data, so `set_block` writes the cell into the slab array directly
  AND records it; the far draw (payload-based) ignores the slab until promotion, and
  the recorded edit is what schedules the owed full regen on a re-landing ("the edit's
  own promotion regen"). Persistence: far columns are never encoded (the AC-0287 save
  filter), so an edited far column survives only through the save's JSON edits diff +
  the promotion re-apply — the `flysave` arm is the standing proof (edit → evict →
  regenerate → read-back, far at edit time).
- **Demotion + lane ownership (AC-0312)**: the keep-all-LOD DATA retention is RETIRED —
  a column leaving the real band is swapped to the h-only far form (`generate_far`
  payload, the CARVED top H — the height the full path would produce (AC-0387) — +
  `no_caves` (the payload carries no cave data: it is the silhouette)) with
  `clear_data()`: **band A** keeps its
  OLD high-LOD mesh resident + visible (no re-materialization owed — the build pick
  skips meshed columns; the next promotion's full regen re-converges the delta),
  **bands B/C** flip to the ready stored low (else the low obligation re-opens and
  `_low_relower_owed` RE-LOWS the far column — the re-lower reaches far columns, the
  low re-emitted at the current data_gen). Work ownership is per-RING (AC-0335 unified
  the two lanes into the drain's single order — see the build-order bullet): the ring
  decides the work via `_dispatch_column_work` (rings 0/1 → the high build, rings 2/3 →
  the avg emit), and the probes stay per-ring — the low probe (`_entry_best_pending`)
  returns -1 for tier ≤ 1 / ≥ 4 (a band-A far column is never "pending" for the low
  side, or `band_drained()` stalls), the unmaterialized band-A special case lives in
  the HIGH probe (`_hslab_best_pending`). Chunk fields: `far_mat` (fill slabs resident) +
  `far_eff` (cached sky eff, dies with the data). **Mesh-attach contract
  (AC-0321)**: a FULL build (si1=-1, unscoped — the real-band full landing, the
  tex-refresh, the band-A mat landing) emits its opaque UVs in the
  merged-atlas canvas space (v / ms.h) and lands through `apply_accs` (the
  opaque material samples the merged canvas `_tm_ms_full.tex`); a SCOPED build
  (the per-slab hslab lane, the edit) emits per-face plain-atlas UVs and lands
  through `apply_edit_accs` (the plain-atlas material). Crossing the two is a
  UV-space/material mismatch (band A once rendered untextured exactly this
  way, AC-0321); the ladder arm's band-A gate (landed surfaces u-exact vs a
  fresh real-band emit + the material-canvas check) and the editmat arm
  (plain material under plain UVs) are the permanent proofs. **AC-0445 (column-atomic
   tier 0 + the first-enable fade)**: the real band (tier 0) now dispatches COLUMN-ATOMIC
   — the whole 16 m column is one off-thread unit and ONE full landing (si0=0/si1=-1,
   `col_atomic:true`, NO `hslab` flag → it routes to the full-landing branch and stamps
   every slab 0..top in one shot), so the "half-built tower with holes" the user saw
   (24 per-slab landings scattered across frames) is gone — the `_vflight` census proves
   no resident tier-0 column is ever partially stamped (PENDING or COMPLETE, never
   partial). On a first-enable landing (no high showing before) the column takes a
   display-side FADE: per-surface `surface_set_material(i, fadeMat)` where fadeMat = the
   shared kind material `.duplicate()` (inherits the live per-frame uniforms) + the shader
   swapped to the `chunk_lit_*_fade.gdshader` variant (`render_mode …, blend_mix` — the
   Godot4 standard alpha-blend mode; the plain `blend` keyword is rejected in this build,
   and the headless dummy server rejects ALL transparent render modes, so the fade is
   SKIPPED headless — `DisplayServer.get_name() == "headless"`, since this build's
   `OS.has_feature("headless")` is false under `--headless`) + `u_fade` ramped 0.0→1.0
   (smoothstep) over `COL_FADE_MS` (350, `AWECRAFT_FADE_MS`); at completion the surfaces
   restore the shared kind material and the per-column fade mats are dropped (RefCounted —
   no `.free()`). The fade is a pure display ramp (no pixels headless); the render proof is
   the `vflight` arm under the fwdshot recipe (`fade.started > 0`, `completed == started`)
   + the `shaderforce` count (16 — the four fade variants compile) + the A/B frames.
- **Build order (AC-0313, UNIFIED at AC-0335 — one order, the ring decides the work)**:
  ONE scheduler — `_drain_build_queue`'s steady pass — works the whole world in a single
  **inside-out work order**: the bake score is `taxi` — across columns the
  innermost owed column first (a pure function of the live recenter anchor, no timer or
  mode). **AC-0445: the score is TAXI-ONLY** — the `(taxi, layer)` second key (the
   player-Y layer rank + its per-candidate probe call) is GONE with the player-Y
   recenter anchor (the AC-0234 Y-trigger deletion): the build order is a pure function
   of the recenter anchor's X/Z, altitude-stable (a pure vertical move re-scores
   nothing — the `_vflight` sweep proves it) — and the high lanes (tier 0/1) now
   dispatch COLUMN-ATOMIC (the whole 16 m column is one off-thread unit and one landing
   — the "half-built tower with holes" the user saw is gone) while the far lanes
   (tier 2/3) still dispatch per-slab (P2, unchanged). — **AC-0399 (the flight-band
   view weight)**: in the flight band the score's
  taxi is a VIEW-WEIGHTED EFFECTIVE taxi — the column's distance to the anchor is
  shortened by `max(0, cos(column-dir, view-dir)) x |lead|`, where the lead is the
  camera's flat xz view direction (the player's `aim_dir()` projected through the
  recenter-anchor column's sphere basis) weighted by the player's flight band (the
  AC-0145 P2 blend, `player.flight_band()`) x `vbias_w` (0.7, env
  `AWECRAFT_VBIAS_W`/`AWECRAFT_VBIAS_FLIP`): a column directly in the view loses up
  to 70% of its effective distance, a column 90 deg+ behind is untouched — the arc
  being looked at fills first on takeoff; on the ground the band is 0 and the score
  is byte-identical to the original `(taxi, layer)`. Tier 4 (data-only, past the
  render edge — never rendered) is NOT biased, so the invisible outer world keeps
  its order and the draw band gets the view priority. The lead is QUANTIZED into
  the pool key (8 compass sectors x band level, `_view_bucket`/`_view_band8`) so a
  look change rescans only across a sector or band boundary — the AC-0250 removal
  (the continuous look rescore storm) keeps its debounce. The data (gen) pass runs
  the same score, so gen and build share the order. — within a column the slabs
  go in Y-distance from the player's slab
  (`_layer_rank_of`: 0 = player slab, then −1, +1, −2, +2, …), and the column's LOD ring
  (`_lod_tier_of`) decides WHAT gets done for it — the one per-ring switch is
  `_dispatch_column_work`: ring 0/1 (real band + band A) → the high slab build (band A's
  first dispatch is the materialization, inside `_mesh_dispatch_hslab`), ring 2/3
  (band B/C) → the far payload avg emit (the old slab wave's dispatch). A completed
  column (its ring's probe owes nothing) is complete and its queue entry is freed —
  there is no window rework; a column entering the real band is simply the next column
  in the order whose ring changed (the AC-0231 WAVE 3 idle catch-up is GONE with the
  lane seam). `sim_dist` has a floor of **4** (`Settings.SIM_MIN`), so the player's 3x3
  (taxi ≤ 2) is always inside the real band: the band itself is the footing guarantee.
  The AC-0263 Y-window, the AC-0283 P3 walk regime, and the tier-0 set are all GONE, and
  AC-0335 removed the second scheduler with them (`_low_step` keeps only the attach
  side it owns — `_low_poll`: the cap swap, the all-air terminal marks,
  the per-slab tier stamps — plus the re-lower debt step): after the player is active
  the drain is ALWAYS the ONE wall-clock paced unit budget (surviving pacing model:
  `LOW_WAVE_PACE_MS` 3.5 ms/unit + `LOW_WAVE_FRAME_CAP` 8/frame — both pre-unification
  paces were wall-clock accumulators, which is exactly what the AC-0231 fps-independence
  constraint requires; the far-lane pace survived on its data-landing-rate tuning) +
  the `drain_budget_ms` time cap — no main-thread blocking build pass. The AC-0283 P3
  **TG-empty data feed** was removed with that regime and RESTORED by AC-0322 as a
  stateless part of the steady drain (the data pass also runs on a build-dispatched
  iteration when the TG pool is fully drained — the slab unit frees a queue entry only
  once per 24 slabs, so the `u == 0` gate alone starved the TG pipeline to the
  column-completion rate and the walk's taxi-8 sim disc plateaued at ~53%): the data
  supply is part of the scheduler's contract, not a regime. **Queue lifecycle
  (AC-0345)**: the scheduler picks from a CANDIDATE WINDOW — `_collect_pool` scans
  the queue in band order (innermost ring first) and returns at most
  `PICK_POOL_CAP` (512) entries; the cap is a performance device (AC-0217/AC-0233/
  AC-0250 removed the per-frame full-pool rescan), so what fills the window
  matters: a column leaves the window the moment it no longer owes its ring's
  work, by that lane's own readiness test — a high column through `c.mesh_built`
  (and its queue entry is freed outright when it completes), a far column (rings
  2/3) through the LOW probe (`_entry_best_pending < 0`). Far columns are never
  `mesh_built` (the flag is the high lane's), so without the probe test in the
  scan the 512 innermost settled far columns hold the window permanently and the
  far field stops exactly there — at the shipped render distance 50 that was a
  frozen 8704 = 512 × 17-slab wave with the pools idle (the AC-0338 find, fixed
  at AC-0345: the R50 far field now streams to completion — 80,852 = 4,756 × 17
  dispatched, `pend` → 0, the window empty at the floor). A settled far entry
  STAYS IN THE QUEUE: the tier/knob-change re-dispatch, the AC-0222 depth cap and
  the AC-0274 defer set all work on queue membership, and a re-pended slab (a
  tier flip, an edit, a recenter) re-admits the entry on the next scan (those
  events bump `_pool_ver` and force the rescan).
- **Load screen (AC-0313, clause 4 as CORRECTED)**: the loading window closes the
  moment the **SIM TAXI DIAMOND** around the load anchor — every column with
  `taxi(dx,dz) <= band0_r` (= sim), 41 columns at sim 4 — is `mesh_built` by the
  NORMAL streaming machinery, and `start_game` (fresh spawn) / `_continue_slot`
  (continue — the window arms there via the world-owned AC-0186 trigger)
   activate the player only after the SAME
  condition (`_await_sim_band`, the diamond wait; `_await_core_3x3` survives as
  the harness arms' settling helper) — the `simband` wall (the load arm's
  `simband_ms`, renamed from `spawn3x3_ms`) IS the load→activation wall. The
  original clause-4 text ("the 9 spawn chunks") predates the user's answer —
  "instead of 3x3 let's do sim taxi distance" (recorded on AC-0312's notes by
  mistake; the CLAUSE 4 CORRECTION note on AC-0313 is the requirement). There is
  no special startup build pass: AC-0293 retired the 5x5 startup data *burst*
  (the high-priority GROUP task feeding the 24 non-center spawn columns, its
  main-thread apply pass, the drain hold and the one-shot `_spawn_fast`
  latch that kept its window unopposed) — spawn and recenter ride the SAME
  normal streaming path as everything else (the recenter pre-warm enqueues
  the 5x5 through the normal build queue; the (taxi, layer) inside-out order
  builds the inner ring first), and the diamond gate above is the anti-fall:
  the player activates only on fully meshed footing, so no mechanism the
  player can see owes their ground. **AC-0414 (the bake-before-load hold)**:
  with `sat_preload` ON (default), a fresh-spawn loading window ALSO waits on
  the satellite body's in-flight bake before closing — `world.gd
  _ac0414_hold_tick()` holds the drain's phase 1 (the real-band diamond, the
  ONLY dispatch path in a loading window) while `satellite.phase == WORK`, so
  the window's release set is exactly the sim-band release set (nothing else
  rides the hold; the OFF path never runs it). The hold is BOUNDED: a 42 s
  budget (`AC0414_HOLD_BUDGET_MS`) after which it releases the player with a
  LOUD log line. On that late release the bake YIELDS (world.gd sets
  `satellite.bake_yield`): its remaining work enqueues LOW priority until the
  window closes, so the diamond build (HIGH) takes the pool and the player's
  ground lands at the budget + at most one shard slice — measured 48.4 s
  release on this box (the pre-yield design measured 109 s: the up-front HIGH
  shards held the pool past the budget). After the window closes the tail goes
  HIGH again at a reduced 4-worker inflight cap (`AC0414_TAIL_WORKERS`, so
  streaming keeps 2+ of the 6 pool threads) and the planet finishes at full
  speed. The loading screen shows a live progress line (seed, shard k/98 or
  face k/12, payload) instead of a frozen bar. This is the bounded-timeout-
  loud path the ticket sanctions, the measured outcome on every realistic
  machine (the bake's wall exceeds 42 s even multi-threaded here; the planet
  lands ~2.8 min after spawn instead of 13+; on desktop-class hardware the
  bake finishes inside the budget and the player is never released early).
  The hold latches (no second stall) and resets with the window.
  **AC-0186 (the continue-path window)**: the window was fresh-spawn-only —
  `main._continue_slot` has no `start_loading` caller, so a Continue press
  hid the menu and the player watched the half-built world for the whole
  sim-band wait. The world now arms the SAME window on that path
  (`world.gd _ac0186_continue_window`, called from `_process` before
  `_loading_tick`): the first process frame where `loading_bypass` + first
  window of the boot + mode play + the player not handed over yet + the
  active slot HAS a save file (a fresh spawn's slot is empty until
  `Save.save_now` after the load — and its own `start_loading` has already
  fired synchronously, so the fresh-spawn path is untouched) + the Menu
  node exists under Main (the real menu-first flow; the harness arms boot
  without a menu and keep `loading_active=false` — the load arm's standing
  contract; `AWECRAFT_LOADCONTINUE=1` forces the trigger for the probe runs).
  Title "Continuing world (seed N)..." — the progress line, the disk/gen
  counters (a continue's `disk` count IS the saved-columns load), the AC-0414
  bake hold + live line and the diamond close are the existing path-agnostic
  machinery.
- **Deterministic spawn search (AC-0324)**: the player's start column is NOT a
  fixed constant — `World.spawn_point()` runs a no-RNG search once the
  SIM-BAND data the load gate guarantees is built, and returns the searched
  position (pre-data callers keep the legacy pad anchor). Per candidate
  column (centre cell `x = cx*16+8`, `z = cz*16+8`, `T` = topmost non-air
  cell): DRY (top id != water and T >= SEA), GENTLY SLOPED (max |ΔT| ≤ 2 over
  the 4 cardinal neighbour cells), UN-VEGETATED (neither the feet cell
  T+1 nor the head cell T+2 is log/leaves/rose/dandelion/banana). First
  pass in (taxi, cx, cz) order over the INNER diamond taxi ≤ sim−1 (every
  candidate's slope neighbours are then inside the guaranteed diamond — a
  boundary column's outward neighbour is timing-dependent and would make the
  search non-deterministic); fallbacks over the full band: T1 = first dry,
  T2 = highest T ((taxi,cx,cz) tie-break). AC-0314 removed the flat spawn
  plateau (the `SPAWN_H=136` pad term is gone from the C++ `surface_h` AND
  the GDScript mirror `terrain_height` — see the gen.cpp / generator.gd
  header notes), so the search now places the player on a NATURAL column —
  for seeds 44/1/7 that is the anchor column [8,8] itself (tier 0, tops
  141/148/200); the pre-data fallback `spawn_point()` is the C++ analytic
  `column_heights16` H at the anchor (the mirror is deliberately NOT used —
  it is a coarse 2-D approximation, not the generator's heightmap). The
  `spawnsearch` arm re-derives all of it independently (HARNESS.md §1) and
  the `SPAWNSEARCH` log line records the chosen column + surface H.
- **`gdext/lighting.cpp` (`AweLighting`) and the classic light pull are TEST-ONLY
  references** (AC-0283 P4). They exist so arms can compare against the old kernel. Never
  wire them into game code; the last live consumers were removed by AC-0297.
- **Fluids**: per-cell levels (`source = 8`, decaying flow), water/lava reactions, buckets,
  level-aware meshing, ticking near the player.
- **Rendering**: `forward_plus` (AC-0241) with the Linear tonemap restored (ACES reads
  washed out on hand-tuned unshaded chunk shaders), occlusion culling on.
- **Frustum culling**: engine-side (AC-0212). The manual per-camera-change pass was removed —
  do not reintroduce a manual cull for chunks.
- **Dimensions**: `Game.dimension` exists **but the nether/second dimension was never
  built** — the variable has no consumers anywhere in the tree. Treat "two worlds,
  per-dimension save, portals" as an unbuilt intention, not a feature.
- **Sound (AC-0039 — the procedural sound layer, no asset files)**: the Windows product
  ships **no .wav/.ogg** — every sound is synthesized in code in `autoload/audio.gd`.
  Nine base voices (block, step, hit, eat, splash, arrow, bow, mob, ambient) are
  generated ONCE at autoload `_ready` as deterministic 22050 Hz mono PCM (pure `static
  func synth()` per voice, fixed RNG seeds) and cached as `AudioStreamWAV`; a shape-
  preserving 0.9-peak limiter runs at the end of `synth()` so "no clipping" is a
  property of the synth, not of the 16-bit clamp. `Audio.play(name)` maps call-site
  names onto the bases — the alias table (`break`/`place`/`door` → block, `hurt`/
  `pickup` → hit, `gorilla` → mob) exists so **no existing event can be silent** and an
  unknown name falls back to the neutral `hit` thud. Concurrency is the AC-0038
  discipline: a fixed 16-voice `AudioStreamPlayer` pool, round-robin, **preempt-oldest**
  on cap, with an allocation counter that must stay flat after `_ready` (`play()` never
  allocates). The **ambient** is a 2 s seamless loop (integer-cycle sines + Hann-
  windowed noise) on ONE dedicated bed player outside the pool — a looping stream must
  never occupy a one-shot voice (it would hold the slot forever). **AC-0389: the bed is
  TOGGLEABLE and DEFAULT OFF** — the user reported the AC-0039 always-on loop as a
  defect, so `audio.gd` no longer auto-plays it in `_ready`; the persisted setting
  `Settings.values["ambient_enabled"]` (default `false`) is pushed by
  `Settings.apply_audio()` → `Audio.set_ambient()` at main `_ready` and on every
  Options toggle (the Settings-page "Ambient sound" checkbox, `menu.gd`). The 8 EVENT
  voices never read the flag: `play()` gates only the bed branch, so the SFX pool is
  untouched either way (the sound arm's D2 asserts the events fire with the bed off).
  All voices are
  **non-positional** (a 2D SFX bed): no positional audio exists, so the sphere-frame /
  radial-up convention does not apply; if positional sound is added it MUST follow the
  DayNight/radial rules (the arrow's radial gravity in `entities/arrow.gd` is the model).
  Wire events at the interaction site (`Audio.play` in player.gd / arrow.gd / mob.gd);
  the step cadence is distance-based on the player's LOCAL frame (`vloc`, radial-up —
  sphere-safe by construction), one `step` per `STEP_DIST` (2.3 m) of tangent travel.
  The permanent gate is the harness `sound` arm (`AWECRAFT_LOGIC=sound`, run with
  `--audio-driver Dummy`): it asserts the GENERATED buffer (duration, non-silent RMS,
  no clip, no all-ones), pairwise distinctness of all 9 voices (fingerprint = RMS +
  ZCR + 9-bin Goertzel bands + spectral centroid), resolution of every call-site name,
  the pool's flat allocation counter under a 1000-trigger burst, and NEGATIVE tests
  proving the checker fails on silent / all-ones / aliased inputs.

## 7. Conventions

- GDScript: `snake_case`, 4-space indent, type hints where trivial.
- **Comments are the documentation style.** Non-obvious blocks carry an `AC-NNNN`-tagged
  rationale (why the constant, why the ordering, what was measured). The port-era "no
  comments" rule is retired: an unexplained optimisation in this codebase is a liability.
- **`_` means "not this module's interface".** GDScript has no access modifiers and the
  engine enforces nothing, so this is a review rule: do not reach a `_`-prefixed member or
  method on another object from another file. Two files needing it means the underscore is
  wrong — and the fix is **never a rename**, which promotes a private field to public API
  and freezes its name. Add the missing contract instead: a getter (and a setter only where
  the caller is the authority) for internal data, returning a value or a copy, since a live
  reference encapsulates nothing. Otherwise: a coarser operation on the owner when the
  caller is doing the owner's work, injection when a child pulls its parent's services, a
  move when a shared utility sits in the wrong home.
- **The arms are the one exception.** `scenes/harness.gd` reaches into the system under
  test deliberately — it is inert during normal play (§3) — so those accesses are part of
  the proof, not a defect. Where the arms need state, prefer a declared introspection
  surface.
- Surgical edits. Do not reformat unrelated files; do not restructure a file you were not
  asked to touch.
- Every change is a ticket. `tasks/TASKS.yaml` is mutated **only** through
  `python3 tasks/scripts/tasks.py` (§ `AGENTS.md`).
- Verification is not optional: every task ends with the arms that prove it, and the values
  are recorded (see `godot/HARNESS.md`).

## 8. History

- The original game was a web (Three.js) project; the Godot port's **M1–M13 checklist is
  retired** and no longer describes anything. `M11` (endgame) was explicitly removed. Work
  now flows as AC tickets.
- Older port-era statements that are now wrong and were corrected at AC-0298: four autoloads
  (now six); a hand-authored `hud`/`interaction`/`combat`/`manager` node layout (consolidated
  into scripts); "no comments" (inverted); a four-command VERIFY block (now
  `godot/HARNESS.md`); an implemented nether (never built).
- Deep history lives in git and `godot/CONTINUITY.archive.md`.
