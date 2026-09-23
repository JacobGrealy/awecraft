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
| `mesh.cpp` | chunk meshing (greedy/FACE-BLOCK path); the avg far emitters `AweMesh.h_avg_emit` / `low_emit_avg` at a grid G (4 or 8 — AC-0312's band C / band B), byte-identical to the slab emitter on the same fill (shared `avg_grid_emit`), with the WATER EXCEPTION (a water-topped cell emits its top face with the translucent water material — `top_water` + atlas-rect params) and the `AweMesh.sky_eff` heightmap-sky light/strips builder (band A + the G-grid avg lanes); the far-tier floor (AC-0331) as a `p_yfloor` param on all three (−1 = off): a post-fill mask in the shared `avg_grid_emit` tail (avg tiers) + the per-voxel row gate + si0 in `build_accs` (band A) — the fill loops and the float32 op order are untouched |
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
  assumed it. Scope rule: the "Traps" list in `world/AGENTS.md`.

## 6. Stable design decisions

Match these; do not improvise a different approach in a task.

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
- **Raycasting**: the analytical voxel DDA in `core/math.gd` for select/mine/place and
  projectiles — not physics rays (faster and deterministic).
- **Meshing**: one `ArrayMesh` per slab/chunk via `SurfaceTool` (GDScript path) or the C++
  greedy/strip lanes; level-aware fluid faces; rebuilt on edit.
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
  `u_day` does the darkening (AC-0204 — no day factor anywhere in the build path).
- **Far data (the draw band, taxi > `band0_r`, + the offscreen interior collar)**: columns
  store **no slabs at all** — just a `[H u16×256][biome×256][top-block×256]` payload
  (~1 KB, ~198 B on disk; AC-0284b; the v6 flag bit 1 — **write-dead since AC-0287**:
  the save filter never encodes a far column; the bit-1 shape survives on disk only in
  pre-AC-0287 saves and is decode-only). Gen builds only the 3 coarse
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
- **AC-0338 — the ring-level far batch (how bands B/C DRAW)**: the avg tiers'
  per-slab geometry is a DRAW-batched, not an emit-batched, thing. The emit is
  still the per-slab C++ avg emit (byte-identical — farab 1080/1080 + h_mismatch 0,
  halo, ladder, meshprobe are the standing proof), but the DRAW is per RING SECTOR:
  one `MeshInstance3D` per (avg tier, world-space 1/32-angle sector) — 32 sectors ×
  2 tiers = up to 64 children of `World` (`_ring_*` in `world.gd`), each wearing a
  merged `ArrayMesh` of every visible slab of that tier in that sector, in world
  coordinates (surface 0 = the opaque avg in the shared `_lod_avg_mat()`; surfaces
  1/2 = the WATER EXCEPTION faces in the shared fluid materials — the two-pass
  camera-side cull is per surface and survives the merge). The per-slab RECORD
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
  P2 / P1 tunnels at AC-0289)**: caves are wherever the ONE density field reads solid→air, and the
  surface AND the caves come from the same field. **Since AC-0347 P2 (THE STRUCTURE) the field is
  vanilla's density ROUTER** (Java 1.21.4 `overworld.json` `final_density`'s `range_choice`,
  verified against the shipped JSON; density > 0 = solid in both conventions): with
  `k = H − y` (depth from the surface — NOT S_ramp, which saturates) and
  `K_CUT = 16` (the P3-recalibrated switch depth — inside the ticket's 10-25 band, set by
  measurement, AC-0347 P3 results page; R_BAND = 10 stays the ramp saturation depth, and since
  the ramp reads +1 for k ≥ 9.5 the shallow branch stays degenerate — solid + entrance slits —
  across its whole width, so the cut-continuity proof holds unchanged):
  `k < K_CUT: d = min(S_ramp(H,y), 5·entrances)` (SHALLOW — S_ramp kept as the surface, the
  entrance family carves the deliberate openings); `k ≥ K_CUT: d = min(entrances,
  4·layer_c² + clamp(−1,1)(0.27+cheese_c) + clamp(0,0.5)(1.5−0.64·k/K_CUT))` (DEEP — the base
  terrain contributes NOTHING: the solid/air decision below the shallow band IS the cave router;
  the suppressor is 0.5 at the cut and 0 at k = 2.34375·K_CUT = 37.5 — vanilla's 1.5/0.64
  constants as-is, anchored at the cut; the squared ONE-SIDED layer term gates the
  cheese caves into stacked levels in absolute y). The old `A(y)/DEEP_GROW/CAVE_AMP`
  depth-amplifier structure is GONE. The "air for sure above H+11" margin is now STRUCTURAL (no
  noise budget): for y ≥ H+10.5 the ramp clamps −1 exactly and the shallow branch reads
  `min(−1, 5·entrances) ≤ −1 < 0` for any noise values (and under the router the effective
  surface can only wobble DOWN — he ≤ H: d > 0 in the shallow branch requires S_ramp > 0, i.e.
  y ≤ H). **All ported noise is centered `2·(vn3−0.5)`** — the vanilla O(1) convention; the
  constants (0.27, 0.64, 1.5, 5, 4, 0.37) are only meaningful in those units. The noise fields
  (sampled by the `vn3` octave machine in both lanes — `AweNoise.vn3(x,y,z,s,first_oct,amps)` =
  `Σ(aᵢ·vnoise3(p·2^firstOctave·2^i)) / Σ|aᵢ|`, vanilla's octave machine which `fbm3` could not
  express; the scale MULTIPLIES the block coordinate): **cheese** = vanilla's `cave_cheese`
  AS-IS `{firstOctave −8, [0.5,1,2,1,2,1,0,2,0]}` at xz 1.0 / y 0.6667, seed+301, on the coarse
  lattice (P1; dense samples read mean 0.503294 / std 0.088558 / max|C−0.5| = 0.353027);
  **layer** = vanilla's `cave_layer` AS-IS `{firstOctave −8, [1.0]}` at xz 1.0 / y 8.0, seed+302
  (P2; the ~32-block vertical period is evaluated DENSE in the scan — it cannot ride the
  48-block lattice, AC-0344); **entrances** = the vanilla `caves/entrances` function minus its
  spaghetti min — `0.37 + 2·(E−0.5) + 0.3·(1−clamp01((y−54)/40))` with E = `cave_entrance` AS-IS
  `{firstOctave −7, [0.4,0.5,1.0]}` at xz 0.75 / y 0.5, seed+306 (DENSE; the +64 shift maps
  vanilla's from_y −10 / to_y 30 onto our 54 / 94; the 0.37 offset makes entrances RARE) — also
  DENSE in the scan. The heightmap H (surface_h of the 3 coarse SURFACE fields) is structurally
  independent of the cave field: cave tuning MUST NOT touch f_sc/f_sh/f_sr or SEA (the far-band H
  bit-exactness + promotion contract — AC-0347 P2's thash proved H byte-identical before/after:
  `8df7aeb4…0dc4f11`, 21×21-chunk `column_heights16` SHA-256). The router's `max(…, pillars_choice)`
  outer term is AC-0292's (SEQUENCE). P3 (same ticket) recalibrated the surface openings /
  asymmetry against the measured censuses: K_CUT 10 → 16 (the first cave on intact columns
  deepens, the k 10-16 air set was proven 100% tunnel family, the stacked levels survive);
  the suppressor constants stayed vanilla as-is.
  AC-0289 (cave P1) added the **tunnel (edge-density)
  structure** on top of the same one field: two more coarse fields —
  **f_spag** = `fbm3(x/14, y/10, z/14, seed+303, 2 oct)` (spaghetti, the wide tagliatelle,
  1.0× the primary xz scale) and **f_nood** = `fbm3(x/10.5, y/10, z/10.5, seed+304, 2 oct)`
  (noodle, the 1–5-wide wormholes, 0.75× the primary xz scale) — plus the **rarity gate**
  **f_gate** = `fbm3(x/56, y/10, z/56, seed+305, 2 oct)` (low-frequency 3D patchiness:
  tunnels appear in patches, the AweCraft stand-in for Bedrock's spaghetti_3d_rarity). Tunnel
  air wins over cheese solid where `|f_spag−0.5| < 0.16·w` or `|f_nood−0.5| < 0.08·w` with
  `w = clamp01((f_gate−0.52)/0.06)` (the thickness scales with the gate weight — the tunnel
  pinches out at the patch edge); the rule runs BEFORE the he/solidf scan's solid flag and
  identically in the veg margin scan, so the tree base matches the full column. The tunnel
  fields are built and read ONLY on the full path (skip==0) — the lazy skip fill and the far
  h-only payload never read them, so the H / far / promotion contracts stay bit-exact by
  construction (a tunnel breaking the surface only wobbles the EFFECTIVE surface, inside the
  documented H±R band, like the cheese term). The dense source functions are
  `AweGen::density_cave` (the cheese), `AweGen::density_spag / density_nood / density_gate /
  tunnel_air` (the tunnels) and `AweGen::density_layer / density_entrance / dens_at` (the P2
  router's layer / entrance family / the router itself); the genprobe arm mirrors those exact
  expressions in GDScript (the lockstep contract — a parameter change updates both sides in the
  same task; P2's run: 7900/7900 f64-exact).
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
  payload, bit-exact no-cave H + `no_caves`) with `clear_data()`: **band A** keeps its
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
