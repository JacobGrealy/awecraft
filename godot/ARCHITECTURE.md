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
| 3 | `Audio` | `autoload/audio.gd` | procedural synth (headless has no audio device — assertions check the trigger, never the sound) |
| 4 | `Debug` | `autoload/debug.gd` | the headless test API (§6 of this file lists its shape), plus `error()`/crash capture with the modal dialog, session logs, `bug_report`, console tee |
| 5 | `Settings` | `autoload/settings.gd` | user options, ranges and the clamp chain (sim → render, window apply, chunk meshes per frame) |
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
├─ WorldEnvironment
├─ World                  world/world.tscn  →  world/world.gd
│  │                      chunk manager: streaming bands, LOD tiers, scheduler/drain,
│  │                      chunk pool, fluid ticking, edit flush, drops + mob spawning
│  ├─ drops (Node)        entities/drop.gd instances
│  └─ entities (Node)     entities/mob.gd, arrow.gd, banana.gd
│     (scenes/test_range.tscn substitutes for World in the AC-0191 test range)
├─ Player                 player/player.tscn  →  player/player.gd
│                         CharacterBody3D + CollisionShape3D + Camera3D
│                         (CameraAttributesPractical = camera_attributes/main-camera-attributes.tres)
│                         movement, look, mine/place/bucket/bow, combat, inventory model,
│                         held-item viewmodel, swing/bob
├─ ui/inventory.gd        CanvasLayer — hotbar, backpack + crafting grid, armour,
│                         hearts/food, crosshair, messages (Game.hotbar)
├─ ui/console.gd          CanvasLayer — in-game console (AC-0121)
└─ Menu                   scenes/menu.tscn  →  ui/menu.gd — main menu + options
```

There is **no** `hud.gd`/`hud.tscn`, `player/interaction.gd`, `player/combat.gd`,
`entities/manager.gd` or `entities/models/*.tscn`: those duties are consolidated inside
`main.gd`, `player.gd`, `world.gd` and `ui/inventory.gd`. `world/chunk.gd` is the
per-column/slab object; `core/*.gd` are pure-logic helpers with no node dependencies
(`math.gd` DDA, `noise.gd`, `atlas.gd`, `chunk_io.gd`, `sphere_math.gd`, `held_mesh.gd`,
`aero.gd`, `daynight.gd`, `build_id.gd`), plus the `.gdshader` files under `world/` and
`core/`.

## 4. Native extension (`gdext/`)

The hot paths are C++ (GDExtension), guarded at boot: if a class is missing, `Game`
reports `C++ extension (gdext) not loaded — missing: …`, prints the CANNOT START banner and
quits.

| Source | Role |
|---|---|
| `awe_common.{h,cpp}` | shared helpers/registration |
| `gen.cpp` | terrain, biome, cave and ore generation (the density-field generator); `generate_resl`'s `skip` arg: 0 = full / 1 = **band-A materialization fill** (no cave field, solid 0..H + aquifer + surface top + veg — the drain's high lane runs it on each band-A column's first mesh, AC-0312) / 2 = **far h-only** (AC-0284b: builds only the 3 surface fields + H/biome/top-block, NO slabs, ~92 µs/col vs ~1.7 ms full) |
| `mesh.cpp` | chunk meshing (greedy/FACE-BLOCK path); the avg far emitters `AweMesh.h_avg_emit` / `low_emit_avg` at a grid G (4 or 8 — AC-0312's band C / band B), byte-identical to the slab emitter on the same fill (shared `avg_grid_emit`), with the WATER EXCEPTION (a water-topped cell emits its top face with the translucent water material — `top_water` + atlas-rect params) and the `AweMesh.sky_eff` heightmap-sky light/strips builder (band A + the G-grid avg lanes) |
| `strips.cpp` | strip meshing lane |
| `chunk_io.cpp` | column/slab blob encode+decode, region disk I/O |
| `lighting.cpp` | **test-only reference**: the legacy `AweLighting` flood kernel (AC-0283 P4) |
| `starlight.cpp` | the live light engine: single-queue sky+block propagation, per-section nibbles (`AweStarlight`) |

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
  from the menu.
- **Saves**: slot-based (`Save` autoload + `core/chunk_io.gd` + `gdext/chunk_io.cpp`), column
  blob format **v6**, per-slot chunk directories under `user://` — which in this sandbox is
  `/tmp/dsh_home/...`, so saves do not survive a reboot (see `godot/OPS.md`). v6 = v5
  (the 24-bit generated mask) + one flag byte in the MD5-hashed head: **bit 0 = no-caves**
  (AC-0284a, solid 0..H slab-skip) / **bit 1 = far h-only** (AC-0284b — the column stores
  NO slabs, just a `[H u16×256][biome×256][top×256]` payload, ~198 B on disk); old v1–v5
  and bit-0-only v6 decode unchanged. The save-content filter (write only the sim band or
  edited columns) is AC-0287.
- **Save compatibility policy**: **old worlds are disposable during development** (user, 2026-09-17).
  A save-format or world-shape change may make existing worlds unusable and owes **no migration** —
  but it must bump `SAVE_VERSION` so an old save is **rejected cleanly**: fail fast with a log line and
  start a fresh world, never half-load. Migration work is therefore a deliberate choice, not a default.
  This supersedes the earlier "keep older saves decoding" rule; AC-0288…AC-0292 and AC-0293 already
  assumed it. Scope rule: the "Traps" list in `world/AGENTS.md`.

## 6. Stable design decisions

Match these; do not improvise a different approach in a task.

- **Collision**: player and mobs are `CharacterBody3D`; voxel collision is a per-chunk
  `StaticBody3D` built from that chunk's solid blocks and rebuilt on edit.
- **Raycasting**: the analytical voxel DDA in `core/math.gd` for select/mine/place and
  projectiles — not physics rays (faster and deterministic).
- **Meshing**: one `ArrayMesh` per slab/chunk via `SurfaceTool` (GDScript path) or the C++
  greedy/strip lanes; level-aware fluid faces; rebuilt on edit.
- **Lighting**: baked into each face's **vertex colour** (albedo × light) — no realtime GI.
  Sky+block light come from the C++ `AweStarlight` single-queue engine inside the sim band;
  beyond it a heightmap-sky halo (sky 15 strictly above the terrain top, 0 at/below, no
  flood, no nibbles) keeps the far field cheap. A far (h-only) column is **never seeded
  into the engine as all air** (a stale all-air seam mis-carries sky across the promotion
  re-seed); a far→full promotion re-seeds the WHOLE column top-down. One `DirectionalLight3D`
  sun is modulated by `Game.time_of_day`; the mesh stores noon light and the shader uniform
  `u_day` does the darkening (AC-0204 — no day factor anywhere in the build path).
- **Far data (the draw band, taxi > `band0_r`, + the offscreen interior collar)**: columns
  store **no slabs at all** — just a `[H u16×256][biome×256][top-block×256]` payload
  (~1 KB, ~198 B on disk; AC-0284b; the v6 flag bit 1). Gen builds only the 3 coarse
  SURFACE fields (the ones H depends on) + the heights pass — ~92 µs/col vs ~1.7 ms full
  (≈18×); the heights pass alone is ~34 µs (the RP "heights-only" line). H is bit-exact
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
  late-landing machinery).
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
- **Demotion + lane ownership (AC-0312)**: the keep-all-LOD DATA retention is RETIRED —
  a column leaving the real band is swapped to the h-only far form (`generate_far`
  payload, bit-exact no-cave H + `no_caves`) with `clear_data()`: **band A** keeps its
  OLD high-LOD mesh resident + visible (no re-materialization owed — the build pick
  skips meshed columns; the next promotion's full regen re-converges the delta),
  **bands B/C** flip to the ready stored low (else the low obligation re-opens and
  `_low_relower_owed` RE-LOWS the far column — the re-lower reaches far columns, the
  low re-emitted at the current data_gen). Lane ownership is per-lane: the BUILD lane
  owes the real band + band A (the drain's `high_only` pool admits tier ≤ 1), the WAVE
  (low) lane owns bands 2/3 only — the low probe (`_entry_best_pending`) returns -1 for
  tier ≤ 1 / ≥ 4 (a band-A far column is never "pending" for the low lane, or
  `band_drained()` stalls). The unmaterialized band-A special case lives in the HIGH
  probe (`_hslab_best_pending`). Chunk fields: `far_mat` (fill slabs resident) +
  `far_eff` (cached sky eff, dies with the data).
- **Build order (AC-0313)**: every real-band column (taxi ≤ `band0_r` — the sim band) is
  built as a **FULL 24-slab column, inside-out**: the bake score is `(taxi, layer)` —
  across columns the innermost unbuilt column first (a pure function of the live
  recenter anchor, no timer or mode), within a column the slabs go in Y-distance from
  the player's slab (`_layer_rank_of`: 0 = player slab, then −1, +1, −2, +2, …). A built
  column is complete and its queue entry is freed — there is no window rework.
  `sim_dist` has a floor of **4** (`Settings.SIM_MIN`), so the player's 3x3 (taxi ≤ 2)
  is always inside the real band: the band itself is the footing guarantee. The
  AC-0263 Y-window (the player-slab ±1 windowed probe while moving), the AC-0283 P3
  walk regime (the startup 3x3 completion pass, the TG-empty data-feed extension, the
  `1e9 if startup` time budget, the 12-unit spawn budget) and the tier-0 set
  (`tier0_r` / `_is_tier0_col` / the `tier0_radius` setting + Developer-menu row + the
  wave-start gate) are all GONE: after the player is active the drain is ALWAYS the
  wall-clock paced unit budget + the `drain_budget_ms` time cap — no main-thread
  blocking build pass.
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
  no special startup build pass (the 5x5 startup data *burst* is a separate
  mechanism, deferred to AC-0293).
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
