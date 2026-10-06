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
| delegation, gates, closeout | the project skills in `.dsh/skills/`, `COORDINATOR.md`, `tasks/templates/two-phase.md` |
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
| 2 | `Data` | `autoload/data.gd` | all tables + lookups: world constants (`CHUNK` 16, `HEIGHT` 384, `SEA` 126), block/item/mob/recipe tables, atlas rects, colours, crafting match |
| 3 | `Audio` | `autoload/audio.gd` | the procedural sound layer (AC-0039 — §6): 9 synthesized voices cached at startup, the 16-voice SFX pool, the ambient bed player (toggleable, default OFF — AC-0389, `Audio.set_ambient`), `play(name)` + the alias table; the `sound` arm asserts the generated buffers under the dummy driver |
| 4 | `Debug` | `autoload/debug.gd` | the headless test API (§6 of this file lists its shape), plus `error()`/crash capture with the modal dialog, session logs, `bug_report`, console tee |
| 5 | `Settings` | `autoload/settings.gd` | user options, ranges and the clamp chain (sim → render, window apply, chunk meshes per frame), plus the AC-0088 controls remap layer (`controls` key — a flat `action:cls:idx` token list, default `[]` = the shipped `project.godot [input]` map; the merge/apply/conflict logic lives in `core/controls_map.gd` and a corrupt stored map fails safe toward the defaults — it can never empty an action), and the AC-0089 analog tuning layer (`look_sensitivity` 0.25–2.0, `deadzone_left`/`deadzone_right` 0–0.9, `invert_y`/`invert_x` bool — bounds + math in `core/analog_tune.gd`, applied live by the player's look/movement paths; a corrupt stored value clamps into the band, never out of it), plus the AC-0205 `smooth_ramps` bool (default OFF — the smooth ground-ramp toggle; the `sanitize_bool` clamp, `world.note_ramps()` on change, the Settings-surface row and the `AWECRAFT_RAMPS` harness env all follow the pattern — see the AC-0205 bullet in §4) |
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
│                         i.e. no player/world yet). NOT gated by S — the rim exists
│                         at every altitude (at ground level it reads as the horizon
│                         glow).
├─ CloudLayer ×3          core/cloud_layer.gdshader — the cloud SHELL (AC-0235 →
│                         AC-0385): three concentric transparent SphereMeshes at
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
│                         on the planet preset) — _place_clouds now
│                         sets an explicit unit-box custom AABB (the
│                         AC-0235 star-fix pattern), so the deck draws
│                         from below at every altitude. View-dependent
│                         alpha is the geometric graze only; the weather
│                         field itself stays a function of world
│                         direction + time-of-day. All r6 terms are
│                         ≤ the clamped base-band frequency (grain-safe).
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
│                         AC-0036 precedent).
├─ AeroWash               core/aero_wash.gdshader — the screen air-tint: a
│                         camera-following additive quad 0.12 m in front of the eye
│                         (WASH_AMOUNT 0.03). AC-0386: `wash_amount ×(1 - u_space)`
│                         — the lens wash fades with the atmosphere; the quad stays up.
├─ World                  world/world.tscn  →  world/world.gd
│  │                      chunk manager: streaming bands, LOD tiers, scheduler/drain,
│  │                      chunk pool, fluid ticking, edit flush, drops + mob spawning
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
│                         AWECRAFT_SAT_MESH_STEP env override (default 16 = unchanged — software-renderer
│                         render runs use ~64 so a settled frame carrying the body completes); runtime
│                         bake cache
│                         user://satellite/p{planet}_r{R}_s{seed}_h/ (the _h token = the
│                         height-channel era; pre-r2 RGB caches trigger a one-time re-bake),
│                         seeded from godot/assets/satellite/ for the canonical seed 44; the
│                         bake pipeline runs off-thread (one WorkerThreadPool slot, AC-0382)
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
├─ ui/inventory.gd        CanvasLayer — hotbar, backpack + crafting grid, armour,
│                         hearts/food, crosshair, messages (Game.hotbar)
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
└─ Menu                   scenes/menu.tscn  →  ui/menu.gd — main menu + options
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
| `gen.cpp` | terrain, biome, cave and ore generation (the density-field generator) + the **AC-0290 classic carver pass** (the post-density room/trunk/canyon carve — see the carver bullet in §4) + the **AC-0292 P4 families** (vanilla pillars in the deep branch, big ore veins, the 3-D biome field → deepslate/dripstone/sculk/moss surface rules + the post-carve drip pass — see the AC-0292 bullet in §4); `generate_resl`'s `skip` arg: 0 = full / 1 = **band-A materialization fill** (no cave field, solid 0..H + aquifer + surface top + veg — the drain's high lane runs it on each band-A column's first mesh, AC-0312) / 2 = **far h-only** (AC-0284b; **AC-0387: the H is now the CARVED top** — the lane runs the full path's per-column sequence (cave-lattice dens_at scan + aquifer + the AC-0290 carver) on a mask so the far/veg H IS the height the full path would produce (the promotion contract); the 3 surface fields + the 8 cave-lattice fields + the aquifer table + the carver plan are built per chunk — the AC-0387 price, measured 95 → 3,353 µs/chunk vs 5,651 µs full on the 2026-10-01 box; still NO slabs) |
| `mesh.cpp` | chunk meshing (greedy/FACE-BLOCK path); the avg far emitters `AweMesh.h_avg_emit` / `low_emit_avg` at a grid G (4 or 8 — AC-0312's band C / band B), byte-identical to the slab emitter on the same fill (shared `avg_grid_emit`), with the WATER EXCEPTION (a water-topped cell emits its top face with the translucent water material — `top_water` + atlas-rect params) and the `AweMesh.sky_eff` heightmap-sky light/strips builder (band A + the G-grid avg lanes); the far-tier floor (AC-0331) as a `p_yfloor` param on all three (−1 = off): a post-fill mask in the shared `avg_grid_emit` tail (avg tiers) + the per-voxel row gate + si0 in `build_accs` (band A) — the fill loops and the float32 op order are untouched; the AC-0205 smooth-ground-ramp branch in the ro scan (guarded by the ctx `ramps` flag + `!coarse`: a Δ1 rampable step meeting air suppresses the vertical face via `rmask` and emits the 45° quad into the same opaque acc — off = the pre-feature byte path; the far/coarse tiers never enter it, so H stays bit-exact — see the AC-0205 bullet in §4) |
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

- **Tables live in `autoload/data.gd`** as GDScript dictionaries (blocks, items, recipes,
  mobs, atlas rects). Splitting them into JSON is AC-0141/AC-0142 — still open, so do not
  assume JSON.
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
  (off-thread on one WorkerThreadPool slot —
  generate_far × 196,196 + colour + PNG + read-back + guard + geometry — keyed by
  (planet_id, R, seed); the main thread polls and consumes one face per frame, AC-0382).
  **AC-0311 piece 3**: the in-engine bake's per-face SEED SALT was dropped in
  `world/satellite_body.gd` `_gen_one` (the two far lanes thread (face, R) raw into
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

## 6. Stable design decisions

Match these; do not improvise a different approach in a task.

- **Planet coordinate convention — the grid lock (AC-0143 → AC-0306)**: the planet is a
  12-face cube-sphere (`core/sphere_math.gd`, face = axis*2 + sector, 1024-cell
  `CELLS_PER_FACE` grid per face; the non-home faces are sparse data-level chunks).
  **One flat metre is one metre of arc**: one lap of the flat world (4 cube faces of
  W columns) equals the sphere circumference 2πR, so **W/R = π/2** — the flat width of
  one cube face is `SphereMath.face_width(R) = π·R/2` (the per-planet rule W = 1.5708·R;
  a sphere is not developable, so the grid scales with the radius). At the shipped
  `Game.planet_R = 4000` (unchanged by AC-0306 — save record `planets:[{id,R,orbit}]`
  keeps R only, W is derived, no migration): W = 6283 and the home pair (faces 0,1 —
  the flat world, 1 m integer columns keyed `"%d,%d"`) is a 6283×6283 m patch (3141
  per half). The position→cell map for the home pair is `World.key_for_sphere_pos`
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
  component stays AC-0311's V-crack class (double-covered, not see-through). The GLOBAL frame is the planet frame
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
  hold 16×16 cells, keyed `face:ccx:ccz`, placed by `face_chunk_transform`
  (the pre-warp + per-chunk LSQ — the chart placement; the net-vs-chart
  placement residual it leaves at the seam is the AC-0307/AC-0308 property
  and STANDS — AC-0311 piece 3 removed the C1 blend band, which masked the
  surface-HEIGHT seam (0–1 m vcrack, unchanged band-free; the sphere-domain
  (d, δ) field is continuous across the edge on its own), NOT the placement
  split (crossing-row chasm 2.19 m, corner 3.73 m, bit-identical pre/post
  band removal); the split's closure is a separate, unfiled concern).
  `_face_stream` (per-frame)
  streams the player's window (sim_dist × 16 m, the per-face half of the
  edge — the along-edge clamp pairs faces 4/6/8/10 with the + half and
  5/7/9/11 with the − half; lumping the pair is the r15 hole-to-void bug).
  The window is ALSO edge-normal gated (r30): a face streams only when the
  player is within `win` of THAT edge — the along-edge window alone is
  non-empty for every face mid-patch and would stream all eight edges'
  bands on an interior walk (boundary r4 resident 93→272, p95 48→97 ms);
  a player already on the face side has a negative distance and still
  streams. Within `FACE_STREAM_BUDGET_MS`, evicting face chunks past
  `_face_chunk_min_dist` every 16 m of travel. **`_face_player_flat` returns
  the recenter coords as-is: they are ALREADY flat** (the recenter contract
  takes flat — `player._recenter` and the main.gd sim_dist recenter convert
  world→flat before calling); re-reading them through `flat_of_world_pos`
  collapsed the boundary projection onto the +x edge near z 0 and starved
  face 5's stream budget (the crossing row never streamed while the player
  stood home-side near the edge). **No cross-face merge**: the face edge
  cells mirror the home edge data (the cross-face ring) and
  `_face_rearm_home_neighbors` re-arms the home neighbours on a face
  landing. **Per-face AweStarlight** (`_star_for_face`): each face owns a
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
  full-LOD draw, no engine light; **BAND B** (`medium_start` < taxi ≤ `low_start`) — 8×8
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
- **AC-0338 — the ring-level far batch (how bands B/C DRAW)**: the avg tiers'
  per-slab geometry is a DRAW-batched, not an emit-batched, thing. The emit is
  still the per-slab C++ avg emit (byte-identical — farab 1080/1080 + h_mismatch 0,
  halo, ladder, meshprobe are the standing proof), but the DRAW is per RING SECTOR:
  one `MeshInstance3D` per (avg tier, world-space 1/32-angle sector) — 32 sectors ×
  2 tiers = up to 64 children of `World` (`_ring_*` in `world.gd`), each wearing a
  merged `ArrayMesh` of every visible slab of that tier in that sector, in world
  coordinates (surface 0 = the opaque avg in the shared `_lod_avg_mat()`; surfaces
  1/2 = the WATER EXCEPTION faces in the shared fluid materials — the two-pass
  camera-side cull is per surface and survives the merge). AC-0384 r8: the
  `_lod_avg_mat()` material (core/lod_avg.gdshader) carries the far tier's HAZE
  BRIDGE — `render_mode fog_disabled` + a per-fragment haz: inside 336 m the
  fragment takes the engine depth-fog model (the same factor as band A at the
  same view distance — at orbit altitude the flat fog wall), and the outer 48 m
  of the annulus (Manhattan distance 336→384 from the terrain anchor, the
  exact tier boundary) crossfades into the satellite body's own haz model
  (same model and same u_air as the dome; the haz mixes the slab colour
  toward u_air) — so the 100%-fog annulus dissolves
  into the dome instead of
  stepping onto it (pre-r8 the plain engine fog left the annulus a flat
  featureless wall against the body's crisp terrain, the measured seam); the
  bridge's uniforms (u_air / u_fog_near / u_fog_far / u_render_edge / u_center)
  are pushed per frame from main.gd `_update_sky` off the live env fog +
  render radius + `Aero.fog_display`. The per-slab RECORD
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
  (plain material under plain UVs) are the permanent proofs.
- **Build order (AC-0313, UNIFIED at AC-0335 — one order, the ring decides the work)**:
  ONE scheduler — `_drain_build_queue`'s steady pass — works the whole world in a single
  **inside-out work order**: the bake score is `(taxi, layer)` — across columns the
  innermost owed column first (a pure function of the live recenter anchor, no timer or
  mode), within a column the slabs go in Y-distance from the player's slab
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
  (continue — no loading window there) activate the player only after the SAME
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
  player can see owes their ground.
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
