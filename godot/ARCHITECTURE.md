# AweCraft — Godot Port: architecture & subagent contract

READ ALL OF THIS, then do ONLY your assigned task (from §8), then VERIFY + REPORT.
This is the single source of truth for structure, conventions, and the headless test harness.

## 1. Ground rules
- Project root: `/home/angrygiant/github_projects/AweCraft/godot/`
- Language: **GDScript**, Godot **4.7** (engine at `~/tools/godot/godot`). Run with `--path AweCraft/godot`.
- **No comments.** snake_case. 4-space indent. Type hints where trivial.
- This is a **faithful behavioral port** of the web game
  `/home/angrygiant/github_projects/AweCraft/index.html` (frozen at build `20260816-r12` = the SPEC).
  Port behavior, not literal code. When unsure, the web file is the source of truth for data + mechanics.
  Web EXPORT dropped 2026-08-26 (AC-0124): the product is Windows-native (`exports/windows/`); `index.html` remains the frozen spec and every "web" reference below is spec-fidelity, not platform support.
- **1 subagent = 1 task.** Build on what earlier tasks already created. Do not build other tasks.
- Every task ends with verification (render screenshot and/or headless logic assert) + a short report.
- Surgical edits. No comments. Do not reformat unrelated files.

## 2. Autoloads (register in `project.godot`, exactly, in this order)
1. `Game`   (`autoload/game.gd`)   — global state: mode (menu/play/pause), dimension (overworld/nether), world_seed, time_of_day (0..1). API: `Game.new_world(seed)`, `Game.start()`, `Game.message(t)`.
2. `Data`   (`autoload/data.gd`)   — all ported tables + lookups + crafting match (API §5).
3. `Audio`  (`autoload/audio.gd`)  — procedural synth (WS8). Stub early (no-op `Audio.play(name)` etc.).
4. `Debug`  (`autoload/debug.gd`)  — headless test/verify hooks (API §6). CRITICAL.

## 3. Scene / node layout
```
Main (scenes/main.tscn + main.gd)                      # state machine: menu/play/pause/dim switch
├─ World (world/world.tscn + world.gd)                 # ChunkManager (Node3D)
│    └─ <chunk> (world/chunk.gd) ×N                     # Node3D + MeshInstance3D; block data + mesh + light bake + StaticBody
├─ Player (player/player.tscn + player.gd)             # CharacterBody3D + child Camera3D (first-person)
│    └─ interaction (player/interaction.gd)           # DDA select/mine/place/bucket/bow
│    └─ combat    (player/combat.gd)                  # damagePlayer (armor DR), attackMob (bare-hand 1)
├─ Entities (entities/manager.tscn + manager.gd)       # parents mobs + arrows
│    ├─ Mob (entities/mob.gd)                          # base AI state/hp/drops
│    │    └─ models/*.tscn (skeleton/chicken/wolf/spider/pig/cow/sheep/zombie) — UNIQUE models, hip-pivoted limbs
│    └─ Arrow (entities/arrow.gd)                      # projectile (Area3D, vel+gravity, DDA vs blocks/mobs/player)
└─ HUD (ui/hud.tscn + hud.gd)                          # hearts, food bar, hotbar, crosshair, msg
     └─ Inventory (ui/inventory.tscn + inventory.gd)   # backpack 9x3 + craft grid + output + armor 4; tooltip + recipe autofill

Pure logic (class_name scripts, static funcs, no node deps):
  core/math.gd   — Vec3 helpers + `raycast_blocks(origin,dir,max,get_block_fn)` analytical voxel DDA (port web raycastVoxel) + face normals.
  core/noise.gd  — value/perlin noise + fbm (port web fbm3 + terrain noise), seeded.
```

## 4. Key design decisions (match web look + perf; do NOT improvise differently)
- **Collisions:** player & mobs are `CharacterBody3D`. Voxel collision = a `StaticBody3D` per chunk built from that chunk's solid blocks (box `CollisionShape3D`s), rebuilt on block edit.
- **Raycast:** use `core/math.gd` analytical voxel DDA for select/mine/place/projectiles — NOT physics ray (faster, faithful).
- **Meshing:** one chunk → one `ArrayMesh` via `SurfaceTool` from visible solid faces + level-aware fluid faces. Update on edit.
- **Lighting (port web):** column sky light (open-to-sky) + block light BFS (torch=14, glowstone, lava). **Bake a light factor into each face's VERTS COLOR** (multiply albedo by light). One `DirectionalLight3D` "sun" modulates by `time_of_day`. Do not lean on Godot realtime GI.
- **Fluids (port `tickFluids`):** per-cell flow level (source=8, flowing decays); water=5, lava=24; reactions water+lava→obsidian(25)/stone(9, sideways); buckets (scoop/place). Level-aware fluid mesh.
- **Rendering method:** verify under `gl_compatibility` on llvmpipe (§7). Real play may use forward_plus; headless MUST use gl_compatibility.
- **Dimensions (M11/WS6):** two World instances; per-dimension save; portal teleport 1:1.

## 5. `Data` autoload — port these tables from web (grep the web file; do NOT transcribe from memory)
- `blocks`: id 1..28 → `{name, solid, cross, tile(top/side/bottom ids), hard(mine time), drop}` (port web `BLOCKS`).
- `items`: auto from blocks + specials **100..147** — 100-110 misc (106 coal,107 diamond,109 iron sword,110 raw iron), 111-125 tools (`.tool/.tier/.dmg/.speed`), **126 flint&steel**, 127-138 armor (`.armor/.dr/.mat`), 139-141 buckets (`.bucket`), 142 bow, 143 arrow, 144 bone, 145 string, 146/147 raw/cooked chicken.
- `recipes`: `shapeless` (ingredient-count key → `{id,n}`) + `shaped` (`{pattern[rows (MUST be 3 wide)], map(char→id), out}`); port web `SHAPELESS`/`SHAPED`.
- `mobs`: existing 4 + skeleton/chicken/wolf/spider → `{hp,speed,hostile,night_only,drops[],model}` (port web `MOBS`).
- `tiles`: icon atlas id map (port web `T`).
- `World constants`: world height, sea level (30), spawn area, 4 biomes, ore fbm3 thresholds.
- Lookups + crafting: `Data.block(id)`, `Data.item(id)`, `Data.match_shapeless(counts)`, `Data.match_shaped(rows)`.

## 6. `Debug` autoload — headless test/verify harness (CRITICAL for every task)
Provide (mirror web `__debug`):
- `Debug.snap(path)` → `await RenderingServer.frame_post_draw`; `get_tree().root.get_viewport().get_texture().get_image().save_png(path)`.
- `Debug.set_block(x,y,z,id)`, `Debug.block_at(x,y,z)`, `Debug.set_fluid(x,y,z,id,lvl)`, `Debug.fluid_at(x,y,z)`, `Debug.tick_fluids()`.
- `Debug.give_item(id,n)`, `Debug.sel(index)`, `Debug.teleport(x,y,z)`, `Debug.aim_at(x,y,z)` (set pos + look).
- `Debug.spawn_mob(key,x,y,z)`, `Debug.mobs_list()`, `Debug.player` (→ player node: pos/hp/hunger/armor[]/inv/state), `Debug.time`, `Debug.set_time(t)`, `Debug.fly(bool)`.
- `Debug.result(dict)` → `JSON.stringify` to `user://debug_result.json` AND `print("RESULT ", ...)`.
Task verify = drive these (via a throwaway test scene OR by editing Main to run a short scripted scenario), assert, `Debug.result`, `get_tree().quit()`. Read back the printed `RESULT` / the json.

## 7. VERIFY commands (PROVEN working on this box)
```
# LOGIC only (no GPU, no display):
~/tools/godot/godot --headless --path AweCraft/godot
# RENDER (software GL under virtual X, llvmpipe):
xvfb-run -a ~/tools/godot/godot --path AweCraft/godot --rendering-method gl_compatibility
```
- First run imports assets (prints steps) — normal.
- `look_at` on a node not yet in the tree errors → call after `add_child` (or `look_at_from_position`).
- **No audio device** here → Godot uses the **dummy** audio driver (WS8 can't be heard; assert the synth triggers the right playback, not by ear).
- Save screenshots to `/tmp/opencode/<task>_<name>.png`. The orchestrator will VIEW the PNGs (esp. for M10 mob appearance).

## 8. Migration checklist (one subagent each, strictly in order)
- [ ] **M1 Scaffold** — `project.godot` (5 autoloads, §2 order), folders, `Main.tscn`+`main.gd`, a minimal first-person scene (Camera3D) rendering ONE lit colored voxel block; `Debug` autoload with `snap`+`result` working. VERIFY: xvfb render → `Debug.snap` → a PNG the orchestrator can see (block visible, first-person).
- [ ] **M2 Chunk world** — chunk data + deterministic generator (4 biomes, caves, ores, bedrock, sea, seeded) + SurfaceTool meshing (visible faces) + per-chunk StaticBody collision. VERIFY: render terrain (player view + from above) + headless `block_at` (grass top, sea water, bedrock floor).
- [ ] **M3 Player** — `CharacterBody3D` move, gravity/jump, fly(F), first-person mouse look, time(G), F3 debug, world spawn. VERIFY: headless (pos changes on input, fly toggles, time changes) + player render.
- [ ] **M4 Interaction** — DDA select highlight cube, long-press mine (`block.hard`), place (incl. buckets), drops on break, hotbar select. VERIFY: mine a block (→0, drop), place it back.
- [ ] **M5 Lighting** — column sky light + block BFS + torches; bake to vertex color; sun by time_of_day. VERIFY: day vs night render + torch lights a cave.
- [ ] **M6 Fluids** — flow levels, reactions, buckets, level-aware mesh, tick near player. VERIFY: dug cell refloods (lvl-7 spread, source stable); source water over lava→obsidian; water sideways vs lava→stone.
- [ ] **M7 Inventory+Craft UI** — backpack 9x3 + hotbar + craft grid + output (shapeless+shaped) + armor 4 + **hover tooltip (name)** + **transparent empty slots** + **craftable-recipe autofill list**. VERIFY: craft log→planks→wooden pick (logic) + UI screenshot (transparent slots, hover tooltip visible).
- [ ] **M8 Survival** — tool speed + gated drops (stone/ores need pick), armor DR, hunger (sprint/attack/mine drain, regen>18, starve), food bar, eat. VERIFY: drain/regen/starve logic; armor reduces damage; food bar width.
- [ ] **M9 Combat + bare-hand punch** — `attackMob`; **empty hand deals 1 dmg**. VERIFY: punch mob empty-handed → −1 hp; with sword → weapon dmg.
- [ ] **M10 Mobs** — base Mob + **8 UNIQUE, recognizable models** (skeleton w/bow, chicken w/comb, wolf quadruped, spider 8-leg, + 4 originals reworked) + **limbs pivoted at hip/shoulder** + AI (hostile chase, chicken passive, wolf tame by bone, spider night-only) + bow/arrow/projectiles + day/night spawn tables. VERIFY: orchestrator SEES a PNG of each mob (must read as its animal) + legs pivot at hip + skeleton shoots + wolf tames + spider night-hostile + arrow hits. (Expect model iteration.)
- [ ] **M11 REMOVED (2026-08-18)** — user is redirecting the endgame in a new direction (spec TBD; see CONTINUITY.md §6).
- [ ] **M12 WS7 Particles** — pooled particle system (color/velocity/gravity/life): block-break debris (block avg color), hit sparks, arrow-hit burst, pickup puff. VERIFY: breaking a block spawns debris (render).
- [ ] **M13 WS8 Sound** — procedural synth (block break/place per category, footsteps, hit/eat/splash, arrow/bow, mob hurt, ambient day/night). VERIFY: headless assert each action triggers the correct `Audio.play`/buffer (no listening).

## 9. Report format (each subagent — concise, no code dumps)
- Task id + files/symbols/autoloads added.
- Verification: command run + the asserted values (printed `RESULT` / json) + screenshot paths.
- Deviations / known limits.
