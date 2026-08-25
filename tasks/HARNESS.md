# AweCraft — headless test harness reference (tasks/HARNESS.md)

Single reference for every `AWECRAFT_LOGIC` mode + render/shot env hooks, the
`AWECRAFT_BATTERY` runner, known-stable gate values, and sandboxed run recipes.
Written 2026-08-24 (AC-0103) from `godot/scenes/main.gd` as it exists post-AC-0061/0079/0082/0085.
Line refs drift — mode names, RESULT fields, and envs are the stable contract.
Future subagent prompts: point here instead of grepping main.gd.

Engine: `~/tools/godot/godot` (4.7.1), always `--path godot`, run from repo root.
All values below were re-measured on this box on **2026-08-24** unless marked otherwise.

## 1. MODE TABLE

Every `logic == "..."` branch in `godot/scenes/main.gd` (grep count: **36 mode branches**
+ 1 incidental comparison at the headless-idle check). All modes: headless, print
`RESULT {…}` (JSON, also written to `user://debug_result.json`) then quit.
Default world seed 44. All modes run with `fluid_sim_enabled=false` at dispatch
unless noted (boundary sets it true). `AWECRAFT_RADIUS` forces `world.render_radius`
before any mode; without it, harness envs force radius 4.

| mode | harness entry | what it tests (1 line) | key RESULT fields | envs | typical wall (2026-08-24) | notes |
|---|---|---|---|---|---|---|
| `player` | `_player_logic_test` (`_player_logic_test_body` in battery) | WASD move, floor, jump peak, fly toggle, time ticks | `start`, `after_fwd`, `horizontal_moved`, `is_on_floor`, `jump_peak_y`, `after_fly_y`, `time_before`, `time_after` | — | 3 s (standalone) / 2.7 s battery | battery smoke mode |
| `look` | `_look_test` | mouse-drag look deltas, pointer-lock behavior, no drag-mine | `yaw_after_drag`, `drag_yaw_delta`, `drag_pitch_delta`, `locked_yaw_delta`, `dragging`, `drag_mined`, `drag_yaw_ok`, `drag_pitch_ok`, `locked_yaw_ok`, `locked_pitch_ok`, `ok` | — | ~4 s (1 s, 2026-08-24, ok:true) | pointer-lock input via synthetic events |
| `interact` | `_interact_test` (`_interact_test_body` in battery) | DDA select, long-press mine → drop + pickup, place block | `target_cell`, `breakable_id`, `highlight_visible`, `after_mine_cell`, `drop_spawned`, `inv_grew`, `place_cell`, `after_place_cell`, `place_ok` | — | 3 s (standalone) / 1.3 s battery | known-stable: `drop_spawned`/`place_ok` true |
| `craft` | `_craft_test` | shapeless 2×log→4 planks, table shaped pickaxe, inv bookkeeping | `ok`, `data` (r: `logs_start`, `out_a`, `planks_a`, …), `inv` (Debug.inv_dump), `armor` (Debug.armor_dump) | — | ~15–30 s (not re-run 08-24; long scripted UI sequence) | slow-ish UI mode |
| `guiclick` | `_guiclick_test` | inventory click/drag routing, held grab/drop, real recipe click (E planks, table pickaxe) | `ok`, `data` (r: `held0`, `held_down`, `hot0_up`, `two_click`, `drop_hot0`, `drop_storage`, + real-recipe keys) | — | ~15–30 s (not re-run 08-24) | AC-0059 gate |
| `combat` | `_combat_test` | bare-hand punch 1 dmg, attack cooldown, sword 4 dmg, mob death drops, no-target safe | `bare`, `bare_hp`, `post_double_hp`, `cooldown_ok`, `weapon_dmg`, `death_drops`, `death_ok`, `no_target`, `ok` | — | ~10–20 s (not re-run 08-24) | spawns mobs |
| `swing` | `_swing_test` | swing-by-rotation (AC-0085): single-axis pitch arc, punch, 0.9 s loop cycles, tool voxel render, tier tint, walk sway/bob | `ok`, `data` (r: `saw_mid_swing`, `mid_frac`, `swing_max_rot` (>0.4, ≈0.85), `settled`, `punch_max_rot`, `loop_cycles_0.9s` (3–5), `tool_111..123`, `tier_differs_111_vs_113`, `fist_after_empty`, `walk_bobs` (4–10), `walk_y_crossings`, `walk_idle_max_off`) | — | ~15 s (not re-run 08-24) | post-AC-0085 asserts rotation not position |
| `survival` | `_survival_test` | tool vs bare mine speed, gated drops, armor DR, hunger drain/regen/starve, eat, respawn | `tool_ratio`, `bare_ms`, `pick_ms`, `drop_bare`, `drop_pick`, `dmg_none`, `dmg_armor`, `hunger_drain`, `hunger_mine`, `hunger_regen`, `starve`, `eat`, `respawn`, `dump`, `ok` | — | ~60–120 s (not re-run 08-24) | long survival sequence; builds flat pad |
| `hunger` | `_hunger_toggle_test` | hunger_enabled off pins 20 + regen intact; on → starve damage | `pin_to_full`, `off` {`hunger`,`min_hp`,`regen_gain`,`regen_ms`,`attack_cost_zero`}, `on` {`starve_dmg`,`starve_ms`}, `ok` | — | ~20–40 s (not re-run 08-24) | AC-0063 gate |
| `light` | `_light_test` | sky light bake: surface 15, cave 0, torch level 14, BFS reach | `surface_eff` (15), `cave_eff` (0), `torch_level` (14), `torch_far_before` (0), `torch_far_after` (9) | — | 4 s (standalone) / 2.9 s battery | known-stable |
| `daynight` | `_daynight_test` | sun energy/sky color at t=0.25 vs 0.75, full cycle period | `time_025`, `time_075` (DayNight readouts), `cycle_elapsed_ms`, `cycle_expected`, `cycle_actual`, `cycle_delta_ok`, `colcheck`, `ok` | `AWECRAFT_TIME` | ~30–60 s (not re-run 08-24) | runs a full day cycle |
| `tint` | `_tint_test` | per-block vertex tint (tinted vs untinted surface samples) | `ok`, `samples` (out) | — | ~10 s (not re-run 08-24) | |
| `settings` | `_settings_test` | settings defaults 50/1, ranges 4–96, sim→render clamp, load clamp, apply, volume, hunger toggle (AC-0072) | `defaults`, `range`, `sim_clamp`, `load_clamp`, `apply`, `volume_ok`, `hunger` {saved_off, reloaded_off, back_on, default_true}, `ok` | `AWECRAFT_IGNORE_SETTINGS` (self-managed) | ~5 s (not re-run 08-24; fast class) | dispatched at main.gd:576 BEFORE game nodes (works standalone + in battery) |
| `fluids` | `_fluids_test` | source stability, level-7 sideways spread, water+lava reactions, sea zero-write invariant | `shore_after` ([5,7]), `source_after` ([5,8]), `water_delta` (1), `water_on_lava_result` (25), `sideways_lava_result` (9), `sea_stable` (true), `sea_surface_before`/`_final` (2730), `sea_backed_before`/`_final` (1406); prints `FLUIDSTAT` line | — | 5 s (standalone) / 3.8 s battery | known-stable; AC-0068 invariant |
| `fluidprobe` | `_fluidprobe_test` | probes water column positions (debug scout) | `done` (true) | — | ~5 s (not re-run 08-24) | |
| `fluidfall` | `_fluidfall_test` | AC-0068: source over hole stationary (0 writes), descending column lands + 7-wide spread, flat pool shore | `sy`, `caseA_source`, `caseB_full`, `caseC_flat`, `shore`, `far`, `beyond`, `center`, `caseA_ok`, `caseB_ok`, `caseC_ok`, `ok` | `AWECRAFT_SETTLE_TICKS` (forces hard settle) | ~10 s (not re-run 08-24) | r=2 forced |
| `webfall` | `_webfall_test` | web-fall parity: settled + landed + floor spread ≥100 cells | `settled`, `landed`, `floor_cells`, `total_water`, `sy`, `ok` | — | ~10 s (not re-run 08-24) | r=2 forced |
| `fluidsettle` | `_fluidsettle_test` | world-wide fluid settle: ticks to quiescence, final water count | `ticks_to_settle`, `quiet`, `water_final`, `chunk_count` | `AWECRAFT_SETTLE_TICKS` | ~10–20 s (not re-run 08-24) | |
| `buckets` | `_buckets_test` (`_buckets_test_body` in battery) | bucket scoop water → item 140, place back | `scoop_before`, `after_scoop`, `inv_scoop`, `place_after`, `inv_place` | — | ~5 s (standalone, not re-run 08-24) / ~3 s battery | battery full mode (not in 08-24 smoke) |
| `water` | `_water_test` | player water-column physics: rise to shore top, land on shore, water cell intact | `B`, `shore_top`, `timeline`, `max_y`, `first_above_frame`, `above_top`, `landed_frame`, `standing_on_shore`, `final`, `final_on_floor`, `water_cell_intact`, `ok` | — | ~20 s (not re-run 08-24) | |
| `fpv` | `_fpv_test` | first-person view atlas UVs in range, grass top/side distinct | `has_uv`, `uv_min`, `uv_max`, `uv_in_range`, `grass_top`, `grass_side`, `grass_distinct` | — | ~5 s (not re-run 08-24) | |
| `held` | `_held_test` | held block box vs cross sprite visibility (AC-0066 fidelity) | `ok`, `block_held_ok`, `block_visible`, `block_type_ok`, `sprite_hidden_during_block`, `region_actual`, `region_want`, `tool_held_ok`, `tool_visible`, `tool_type_ok`, `empty_hidden_ok` | — | ~10 s (not re-run 08-24) | |
| `toolres` | `_toolres_test` | tool voxel model resolution: 5 tools present + type + tier color + box/fist fallback | `ok`, `tool_111`/`115`/`119`/`123`/`113` {`present`,`type`,`fist`,`sprite`,`box`,`ok`}, `headcolor_111`/`headcolor_113`, `tier_differs_111_vs_113`, `box_after_tool`, `fist_after_empty` | — | ~10 s (not re-run 08-24) | AC-0070 gate |
| `toolpose` | `_toolpose_test` | tool orientation + scale ×2 + depth-disable (AC-0073/0067/0085) | `ok`, `held_box_scale_x` (≈0.70), `held_sprite_scale_x`, `scale_ok`, `tool_…` {`position_ok`,`arc_ok`,`vertical_ok`,`handle_below_cam`,`bbox_diag`,`diag_2x_ok`,`depth_disabled`,`ok`}, `depth` {tool,box,fist,sprite}, `depth_ok` | — | ~15 s (not re-run 08-24) | handle y < −0.55 |
| `viewmodel` | `_viewmodel_shot` | AC-0085 render hook: idle/apex head+handle centroids for a held tool | `vmshot`, `frac`, `idle_head`, `idle_handle`, `apex_head`, `apex_handle` | `AWECRAFT_VMITEM`, `AWECRAFT_VMSHOT`, `AWECRAFT_VMFRACTION` | ~10 s headless (render hook; xvfb for the shot) | centroid-only in headless |
| `wallshot` | `_wallshot_test` | AC-0067 on-top: held box/sprite vs stone wall pixel regions (before/after) | `before`, `shots`, `wall_face_z`, `block` {`block_frame_stone`,`block_vm_nonstone`,`block_box_vis`,`block_depth_on`}, `item` {`item_vm_cyan`,`item_sprite_vis`} | `AWECRAFT_WALL_BEFORE` (1), `AWECRAFT_WALL_SHOTS`, `AWECRAFT_SNAPSHOT` (paths) | render mode (~300 s timeout) | xvfb; writes shots into `tasks/AC-0067/` |
| `editperf` | `_editperf_test` | single block edit: flush frames, build cost, no hitch | `cell`, `edited_id`, `cell_after`, `flush_done`, `flush_frames`, `max_frame_build_ms`, `single_build_ms`, `total_ms` | — | ~5–10 s (not re-run 08-24) | |
| `perf` | `_perf_test` | full-radius build/drain/first-draw/frame percentiles + memory | `chunks`, `render_radius`, `fog_near`/`fog_far`/`fog_edge`/`fog_ok`, `total_chunks`, `all_meshed`, `collision_shapes`, `total_ms`, `frames`, `recenter_ms`, `max_frame_ms`, `build_units`, `drain_frames`, `max_drain_ms`, `gen_ms`, `build_ms`, `first_draw_ms`, `p50_ms`, `p95_ms`, `frame_max_ms`, `mem_before_bytes`, `mem_after_bytes`, `drain_s` | `AWECRAFT_RADIUS`, `AWECRAFT_THREADGEN`/`_N`/`TGDEBUG`, `AWECRAFT_RECPROBE`, `AWECRAFT_DRAIN_MS`, `AWECRAFT_GEN_BUDGET`, `AWECRAFT_MESH_INFO` | r4 ≈12.3 s total_ms (measured `.scratch/ac0082_g4_perf_r4_t1.log` 2026-08-24); **r50 ≈850 s total_ms (from 2026-08-24 03:25 log `ac0082_g4_perf_r50_t1.log`)** | SLOW at r50 — use 3000 s timeout |
| `boundary` | `_boundary_test` (via `_await_boundary_core`) | chunk streaming: walk r chunks, crossings, bursts, forward/trailing wall, mem, marker round-trip | `ok`, `radius`, `walk_chunks`, `walk_speed`, `walk_s`, `crossings`, `p50_ms`, `p95_ms`, `max_ms`, `loads`, `unloads`, `flap`, `burst_ms_per_crossing`, `burst_p50_ms`, `burst_p95_ms`, `burst_max_ms`, `forward_wall_ms_per_crossing`, `forward_p95_ms`, `forward_max_ms`, `trailing_*`, `fluid_tick_ms_p95`, `mem_delta_mb`, `marker`, `marker_ok`, `remesh_ok`, `resident_final`, `built_final`, `in_radius_built_final`/`_max`/`_min`, `in_radius_present_final`, `target_in_radius` | `AWECRAFT_RADIUS` (r), `AWECRAFT_WALK`, `AWECRAFT_WALK_SPEED`, `AWECRAFT_TICKTIME`, `AWECRAFT_THREADGEN`/`_N`/`TGDEBUG`, `AWECRAFT_RECPROBE` | r3 45 s, r4 46 s (measured 2026-08-24); r50 ≈1400 s wall (from 2026-08-24 10:34 log `.scratch/ac0079r3_battery/b_r50.log`) | SLOW at r≥8 — 3000 s timeout; fluid sim enabled |
| `atlas` | `_atlas_test` | spawn chunk mesh UV sanity | `ok` (or `error`) | — | ~5 s (not re-run 08-24) | |
| `genhash` | `_genhash_print` | 5×5 (25) chunk data-gen MD5 parity — world/* change gate | prints `GENHASH cx cz <32-hex>` ×25 + `GENMS` (no RESULT dict) | `AWECRAFT_SEED` (default 44) | 2 s | known-stable: 25/25 identical across verified tasks; seed 99 → all 25 differ |
| `trees` | `_trees_test` | tree generation + cross-quad mesh per chunk | `ok`, `data` (out), `per_chunk` | — | ~10 s (not re-run 08-24) | |
| `save` | `_save_test` | 3-slot save/continue: edits persist, player/inv/slot isolation, clear | `ok`, `saved_ok`, `clear_ok`, `clear_pre_ok`, `blocks_match`, `blocks_total`, `unedited_match`, `player_match`, `pos_ok`, `sel_ok`, `hp_ok`, `hunger_ok`, `time_ok`, `inv_match`, `slot0_ok`, `iso_ok`, `iso_base` | — | ~10–20 s (not re-run 08-24) | uses `user://` saves |
| `dropshot` | `_dropshot_test` | textured block-drop render (AC-0083) | `dropshot` (true), `spawned`, `drop_count`, `cam` | `AWECRAFT_SNAPSHOT` (output path) | render mode (~300 s) | xvfb |
| `crossshot` | `_crossshot_test` | flower cross-sprite render (AC-0084) | `crossshot` (true), `placed`, `tx`, `ty`, `tz` | `AWECRAFT_SNAPSHOT` | render mode (~300 s) | xvfb |
| `quitmenu` | `_quitmenu_test` | pause→quit-to-menu: save written, world freed, back to active menu (AC-0081) | `ok`, `paused_ok`, `menu_scene_active`, `world_cleared`, `save_written`, `seed_ok`, `edits_ok`, `slot`, `script_errors_seen` | — | ~10–20 s (not re-run 08-24) | clears all 3 slots first |
| `mainmenuexit` | `_mainmenuexit_test` | main-menu Exit button: menu-first boot, finds Exit button, press → app quit (AC-0099) | `menu`, `menu_state`, `menu_visible`, `exit_found`, `web_nothreads`, `ready_to_quit` | — | ~5–10 s | self-quit harness (Exit press → `get_tree().quit()` on desktop); intercepted in `_ready()` BEFORE the game dispatch; BATTSKIP in battery (self-quits the process) |

`settings` is also a valid battery mode (`AWECRAFT_BATTERY=settings;…`) — it runs the
same `_settings_test` inside the battery (see its table row).

### Not in table (deliberately excluded)
- `logic == ""` (main.gd:102) — incidental comparison in the headless-idle check, not a
  mode branch. Grep count is therefore 37 lines = 36 modes + 1 incidental; table
  coverage = 36/36 = 100%.
- `AWECRAFT_PROBE`/`AWECRAFT_BCELL` (main.gd:586–758) — not `logic` branches; debug
  print hooks (`PROBE ocean_cells=…`, `MAP`/`BIO` rows, `SEED` scan, `BCELL`) that run
  under any logic dispatch before the mode body and quit early.
- `AWECRAFT_MESH_INFO` (main.gd:965) — `MINFO {…}` prints in the unknown-logic fallback
  path (falls through to the legacy `_logic_check()` RESULT, now unused).
- `AWECRAFT_IMPORT_PACK` (main.gd:30) — atlas pack import probe in `_ready()`, exits
  before any mode; not a logic branch.

## 2. Render / shot env hooks

All render hooks need the software-GL recipe (§4); typical timeout **300 000 ms**
(llvmpipe is slow; keep `AWECRAFT_RADIUS` 1–2). All are in the `HARNESS_ENVS` list
(main.gd:273) which also forces radius 4 + default settings when set.

| env | what it does | required flags / notes |
|---|---|---|
| `AWECRAFT_SNAPSHOT=path.png` | boot world (menu-first unless `AWECRAFT_MENU_BOOT=1`), wait for build, snap viewport PNG | xvfb-run -a + `--rendering-method gl_compatibility`; sets `RESULT {"m4":"ok",w,h,cam}` |
| `AWECRAFT_SNAPSHOT2=path.png` | second snap in `AWECRAFT_CAM=shaft` (after fluid settle) | only with cam=shaft |
| `AWECRAFT_CAM=top\|iso\|iso2\|sky\|eyeup\|sandpad\|shaft` | camera preset for snapshot runs (main.gd:1003–1083) | `sky`/`eyeup` look at sun; `shaft` drops a water column + double-snap; default (empty) = first-person player spawn |
| `AWECRAFT_SIZE=W,H` | force window size (e.g. `1280,720`) before boot | no-size → `Settings.apply_window` |
| `AWECRAFT_MENU_SHOT=path.png` | snap the main menu (skips world boot); `AWECRAFT_MENU_VIEW=options` opens options panel | `RESULT {"menu":true,"mode",…,"build","values"}` |
| `AWECRAFT_FLUID_SHOT=1` | with snapshot: teleport player to shore aim, place water bucket, snap before+after | needs player spawn (default cam) |
| `AWECRAFT_ANIM_SHOT=1` + `AWECRAFT_ANIM_PHASE=0..1` | camera above a water cell to capture fluid anim; phase sets shader `phase` | without a water cell near spawn it prints and skips |
| `AWECRAFT_HELD=id` | give + select item id for the held viewmodel in snapshot runs | with `AWECRAFT_SNAPSHOT` |
| `AWECRAFT_INV=1\|table` | open inventory (E) or crafting table with seeded contents for UI shots | `1` also autofills + hovers item 111 |
| `AWECRAFT_FPV_ITEM=id` | held item for first-person snapshot (also used by `AWECRAFT_WALK_SHOT`) | |
| `AWECRAFT_WALK_SHOT=1` | build flat pad, walk forward, snap ×2 (`_w2` suffix) | |
| `AWECRAFT_EMPTYHAND=1` | empty inventory for bare-hand shot | |
| `AWECRAFT_SWING=fraction` | hold swing at fraction for the shot | float 0..1 |
| `AWECRAFT_HP=n` / `AWECRAFT_HUNGER=n` | set player hp / hunger for HUD shots | 0..20 |
| `AWECRAFT_TIME=f` | set `Game.time_of_day` (0..1, wrapped) before boot | also used by daynight mode |
| `AWECRAFT_SEED=n` | world seed (default 44) — all modes + genhash | |
| `AWECRAFT_ONLY=cx,cz;…` | hide mesh/fluid instances of all chunks NOT in the list (visibility filter) | post-recenter; **not** the battery |
| `AWECRAFT_MENU_BOOT=1` / `AWECRAFT_MENU=0` | menu-first boot → click Play / explicit game-first skip | menu-boot is the desktop/web default |
| `AWECRAFT_PAUSE_SHOT=1` | with menu_boot: snap the pause menu (P key) | `RESULT {"pause_shot":true,…}` |
| `AWECRAFT_NO_FOG=1` / `AWECRAFT_NO_COLLISION=1` | disable env fog / chunk collision at boot | |
| `AWECRAFT_WALL_BEFORE=1` / `AWECRAFT_WALL_SHOTS=…` | `wallshot` mode: before/after AC-0067 comparison shots | writes into `tasks/AC-0067/` |

## 3. Battery + known-stable values

### `AWECRAFT_BATTERY` (main.gd:207, post-AC-0061)
`AWECRAFT_BATTERY=a;b;c` = ONE process, ONE `Game.new_world` per mode, in order:
- each mode runs its normal harness body (per-mode `RESULT` printed verbatim, also
  written to `user://debug_result.json`);
- `BATTMODE <mode> ms=<n>` printed per mode;
- between modes: `_batt_reset_state` — `Game.mode="pause"` drop-freeze pre-settle,
  player freed, chunk `data`/`fl` zeroed, drops freed, light/fluid dirty maps cleared,
  `render_radius=4`, time 0.3, recenter + await build;
- final combined `RESULT {"battery": {mode: {…per-mode RESULT + ms}}, "ok": <all ok,
  genhash exempt>, "total_ms": …}`.
- Battery modes: `player`, `interact`, `light`, `fluids`, `buckets`, `genhash`,
  `settings`; anything else prints `BATTSKIP <mode>` (no RESULT, no failure).
- Per-mode reset adds wall cost vs standalone runs (≈+10 s per reset at r4);
  SMOKE tier (2–4 dependency-mapped modes + genhash) is the fast path.
- `AWECRAFT_SEED` applies to every battery mode (genhash arm included — use the
  full mode list, a truncated list that ends before genhash loses the seed arm).

Fresh smoke battery 2026-08-24 (`player;interact;light;fluids;genhash`): wall 33 s;
BATTMODE: player 2739 ms, interact 1349 ms, light 2879 ms, fluids 3763 ms, genhash 884 ms.

### Known-stable gate values (FRESH runs, 2026-08-24)

| value | fresh result (2026-08-24) | established by |
|---|---|---|
| fluids `sea_surface_before`/`_final` | **2730 / 2730** (FLAT) | AC-0068 (sea zero-write invariant) |
| fluids `sea_backed_before`/`_final` | **1406 / 1406** | AC-0068 |
| fluids `sea_stable` | **true** (`water_delta` 1, `shore_after` [5,7], `source_after` [5,8]) | AC-0068 |
| fluids `water_on_lava_result` / `sideways_lava_result` | **25 / 9** (obsidian / stone) | M6 fluids port |
| interact `drop_spawned` / `place_ok` | **true / true** (`breakable_id` 2, `after_place_cell` 2) | M4 interaction |
| light `torch_level` | **14** (`surface_eff` 15, `cave_eff` 0, `torch_far_after` 9) | M5 lighting |
| genhash | **25/25** `GENHASH` lines, 32-hex MD5 each; default seed 44; seed 99 → all 25 lines differ | AC-0082 (world/* parity gate) |
| boundary r4 `in_radius_built_max` | **67** (`built_final` 81, `ok` true, `flap` 0, `p95_ms` 65) | AC-0079 (look-priority scoring; pre-fix gate was 55) |

## 4. Run recipes (sandboxed, one godot at a time)

Sandbox note: `/tmp` is ephemeral per bash call; the real HOME is read-only — so every
godot call is ONE bash command that sets `HOME` first. Never run two godot processes
in parallel (`.godot` cache corruption). Scratch → project-local `.scratch/` (or
capture `RESULT` into your reply — /tmp files do not survive to the next call).

```bash
# common prefix for EVERY godot call (one bash command):
export HOME=/tmp/dsh_home; mkdir -p $HOME
cd /home/angrygiant/github_projects/AweCraft   # engine: ~/tools/godot/godot, always --path godot
S=/home/angrygiant/tools/godot/godot

# G0 — headless load, zero script errors (~5 s, timeout 300 s):
timeout 300 $S --headless --path godot --quit

# single logic mode (fast class, timeout 240 s):
timeout 240 env AWECRAFT_LOGIC=fluids $S --headless --path godot

# slow modes (boundary/perf at r≥8, r50) — timeout 3000 s, wall ~25+ min:
timeout 3000 env AWECRAFT_LOGIC=boundary AWECRAFT_RADIUS=50 $S --headless --path godot

# smoke battery (2–4 dependency-mapped modes + genhash; quote the list, ~30 s):
timeout 300 env 'AWECRAFT_BATTERY=player;interact;light;fluids;genhash' $S --headless --path godot

# full battery (pre-build gate, ~60–90 s):
timeout 600 env 'AWECRAFT_BATTERY=player;interact;light;fluids;buckets;genhash' $S --headless --path godot

# render (software GL under virtual X; R=1–2; timeout 300000 ms):
xvfb-run -a env AWECRAFT_SNAPSHOT=/tmp/shot.png AWECRAFT_CAM=top AWECRAFT_RADIUS=2 $S --path godot --rendering-method gl_compatibility

# env knobs that matter (any mode):
#   AWECRAFT_SEED=n   world seed (default 44)
#   AWECRAFT_RADIUS=n render radius (forces world.render_radius; default 4 under harness envs)
#   AWECRAFT_THREADGEN=1 / AWECRAFT_THREADGEN_N=n / AWECRAFT_TGDEBUG=1   (world.gd, desktop)
#   AWECRAFT_RECPROBE=1 / AWECRAFT_DRAIN_MS=ms / AWECRAFT_GEN_BUDGET=n   (world.gd streaming budgets)
#   AWECRAFT_TICKTIME=1   (boundary: enable world tick timing)
#   AWECRAFT_WALK / AWECRAFT_WALK_SPEED   (boundary walk config)
#   AWECRAFT_VMITEM / AWECRAFT_VMSHOT / AWECRAFT_VMFRACTION   (viewmodel mode)
#   AWECRAFT_SETTLE_TICKS=n   (fluidfall/fluidsettle hard settle cap)
#   AWECRAFT_ONLY=cx,cz;…   chunk-visibility filter (NOT the battery)
```

## 5. Verification gates (per task)

- **G0**: `--headless --path godot --quit` exits 0 with zero `SCRIPT ERROR` lines;
  `git status --short` shows only the task's own new files.
- **G1**: dependency-mapped mode(s) green (each `RESULT` ok / expected values).
- **G2**: genhash 25/25 byte-identical to the last verified run **only if** `world/*`
  changed.
- **G3**: known-stable values (§3) unchanged after any fluids/world-touching change.
- New world/* or fluid change → also run `boundary` r4 (or the AC-0079 gate values).
