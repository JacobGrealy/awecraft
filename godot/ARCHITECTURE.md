# AweCraft — architecture

What the game is made of, and the conventions that don't change per task. Every structural
claim here was verified against the tree at **AC-0298** (2026-09-16); line counts and file
lists drift, the *shape* is the contract.

**If a task changes the structure — a new autoload, a moved/renamed component, a new
subsystem, a changed data or save format, a new native layer, a changed convention — it
updates this file in the same task.** That rule is standing; see `AGENTS.md`.

Detail lives elsewhere by design:

| Topic | Owner |
|---|---|
| test arms, battery, standing gate values, run recipes | `godot/HARNESS.md` |
| machine, sandbox, daemons, build/serve | `godot/OPS.md` |
| current state, resume steps | `godot/CONTINUITY.md` |
| delegation, gates, closeout | `COORDINATOR.md`, `tasks/templates/two-phase.md` |
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
| `gen.cpp` | terrain, biome, cave and ore generation (the density-field generator) |
| `mesh.cpp` | chunk meshing (greedy/FACE-BLOCK path) |
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
  `/tmp/dsh_home/...`, so saves do not survive a reboot (see `godot/OPS.md`). The save-content
  filter (write only the sim band or edited columns) is AC-0287.

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
  flood, no nibbles) keeps the far field cheap. One `DirectionalLight3D` sun is modulated by
  `Game.time_of_day`; the mesh stores noon light and the shader uniform `u_day` does the
  darkening (AC-0204 — no day factor anywhere in the build path).
- **`gdext/lighting.cpp` (`AweLighting`) and the classic light pull are TEST-ONLY
  references** (AC-0283 P4). They exist so arms can compare against the old kernel. Never
  wire them into game code; AC-0297 removes the last live consumers.
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
