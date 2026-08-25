# AC-0107 continuity log (append-only handoff record)

## RUN 1 (xhigh research/planner) — completed

### Read (by path, in order)
- tasks/AC-0107/spec.html (coordinator-filled; G1–G8 + task-specific reqs + scope + fences)
- godot/CONTINUITY.md (checkpoint: AC-0106/AC-0117 merged-mesh state, AC-0082 threadgen history)
- godot/ARCHITECTURE.md, tasks/templates/two-phase.md (7-section plan schema + coordinator gate)
- godot/world/world.gd (1221 ln), godot/world/chunk.gd (915 ln), godot/world/lighting.gd (327 ln),
  godot/world/generator.gd, godot/autoload/data.gd, godot/core/math.gd (VoxelMath.FACES),
  godot/scenes/main.gd (perf harness: `_perf_test` @4640, `AWECRAFT_LOGIC=perf` @910,
  `_await_world_build` @4080, battery reset @126, `_light_test` @3137)
- tasks/HARNESS.md (perf row: r4 ≈12.3 s total_ms pre-AC-0082-era note; recipes §4)
- tasks/AC-0117/AC-0117-results.html (render A/B diff recipe: PIL, diff>4 %, seed-16 gate lesson)

### Key findings
1. **Spec path typo:** spec says `godot/autoload/lighting.gd`; the file is `godot/world/lighting.gd`
   (class_name Lighting, `compute_light_flat` @146, `_flood_flat` @223, `_tables` @29, static caches
   `_cross/_glow/_att` @15-17 sized 48).
2. **All mesh-build entry points (production + harness):** world.gd:187 (light flush, bulk eff),
   world.gd:203 (fluid remesh, `cc.last_eff`), world.gd:228 (tex_refresh, `c.last_eff`),
   world.gd:399 (`_build_unit` drain — the G4 perf path, no eff → internal `Lighting.compute_light_flat`
   with `Game.world` @735), world.gd:607 (`create_chunk(mesh_now)` — called false-only today),
   main.gd:1327 (`_build_walk_pad` harness only). `_build_batch` (world.gd:936) is DEAD (no callers).
3. **Light is self-contained per chunk:** `build_mesh` uses STANDALONE_MARGIN=0 → box == exact chunk →
   in `compute_light_flat` every wx column maps to the SAME chunk (`floor(wx/16)=cx`), so `world` is
   dereferenced only to find `c` (always non-null); the `world.get_block` fallbacks never fire. A
   data-only static variant `compute_light_flat_chunk(data, h)` is provably output-identical.
   Cross-chunk light propagation happens only in the margin-2 BULK path (`_bulk_light`, world.gd:300) —
   that stays main-thread and its eff is passed INTO workers (byte-identical).
4. **Node/Game/Data refs in the worker path (chunk.gd):** `_effl` Data.HEIGHT; `_face_light`→`_effl`;
   `_corner_uv` Data.ATLAS_PX; `_face_rect` Data.block_rect; `_faces` Data.HEIGHT;
   `_fluid_quad_count` Data.HEIGHT + VoxelMath.FACES; `_emit_faces` cx/cz + Data.block_tint + _face_light;
   `_qwrite_merged` Data.block_tint/block_rect/ATLAS_PX; `_emit_ro_merged` cx/cz + Data.HEIGHT + ms dict;
   `_emit_xquad` cx/cz + Data.block_tint + _effl; `_emit_fluid` Data.HEIGHT + Data.block_tint;
   `_build_snap` **Game.world** + node data/fl + get_world_block (on-demand neighbor gen);
   `build_mesh` node instance add/free + materials + `_build_collision`. Pure (no refs): `_light_color`,
   `_fluid_hgt`, `_qgrow`, `_qwrite`, `_merge_strip`, `_band`, `_face_uvs`, `_uvc`, `_flood_flat`.
   `VoxelMath.FACES` (core/math.gd:3-10) is a class-level const — safe in workers, but the plan still
   routes it through ctx for zero autoload/class dependency.
5. **Merge-atlas:** `_merge_atlas()` (chunk.gd:45-107) static cache `_ms_key/_ms_tex/_ms_rects` (40-42),
   keyed by `Data.atlas_tex` identity; AC-0117's fix = cache-hit return includes `"h"` (line 47).
   Workers need ONLY `rects` (String→Vector2i) + `h` (float) for UVs; the Texture2D is consumed ONLY on
   the main thread (`_opaque_material(ms.tex)` @861). ⇒ main thread pre-builds once before first dispatch;
   workers receive a DUPLICATED rects dict + h; no texture ever crosses threads.
6. **`_build_snap` neighbor need:** reads all 8 neighbors (dx,dz ∈ -1..1 except (0,0)) via `_band`;
   missing neighbor today = on-demand sync gen through `get_world_block` (`_chunk_data` second branch).
   Threaded dispatch rule: all 8 neighbors' data present → worker; else → SYNC fallback build (legacy
   on-demand gen path, exactly today's behavior). The drain's `_build_ready` (4-orthogonal) stays as the
   candidate gate — no drain filter change. Own-data-emptiness guard added in `_mesh_dispatch` (skip).
   (AC-0082 invariant verified: own data is ready before a build is picked, because the outer neighbor's
   gen is always enqueued after own gen in ring order.)
7. **WorkerThreadPool = engine singleton** — `Engine.get_singleton("WorkerThreadPool")` returns ONE shared
   pool (AC-0082's `threadgen_pool` is the same object; no `set_thread_count` call exists). Thread-mesh
   bookkeeping is separate (`_tm_*` arrays/dicts), same pool object, own in-flight cap ≤6. Concurrency is
   bounded by the two caps (6 gen + 6 mesh tasks queued; pool default threads run them).
8. **`perf` mode has no player** (main.gd:910-916: recenter → `_perf_test`); RESULT already carries
   build_ms/gen_ms/total_ms/drain_s/first_draw_ms/p95_ms/max_frame_ms/frames/all_meshed/collision_shapes/
   mem (main.gd:4686-4713). No main.gd edit needed: threaded `perf_build_ms` counts MAIN-THREAD assembly
   time only (dispatch + apply_accs); worker-side time is printed per chunk under `AWECRAFT_TIMING=1`
   (`BUILDCHUNK_T cx,cz build_ms=…`).
9. **Battery runs at render_radius 4** (`_batt_reset_state` main.gd:144) → 81 chunks through the pool per
   mode; reset `e.data.fill(0)` (main.gd:134) is SAFE with fresh copies (workers hold duplicates).
   Stale check at handoff = `c.data != entry.data_copy` (or fl mismatch) → drop + re-enqueue (20KB compare,
   cheap). This is what makes the player/buckets flake loops green under edits-during-flight.
10. **`last_eff` consumers:** fluid remesh (world.gd:203) + tex_refresh (world.gd:228) only — set at
    apply time from the result's light (drain path) or the passed eff (flush/fluid/tex paths).
11. **Lighting pre-warm:** `Lighting._tables()` (Data.blocks read) must run ONCE on the main thread before
    first dispatch; workers then only READ the static PackedByteArrays (no resize after warm-up).

### Pre-change baseline (measured Run-1, seed 44, r4, threadgen ON + mesh SYNC = today)
`env HOME=/tmp/dsh_home AWECRAFT_LOGIC=perf AWECRAFT_RADIUS=4 ~/tools/godot/godot --headless --path godot`
- Run 1: build_ms **4336**, gen_ms 675, total_ms **8864**, drain_s 8.86, first_draw_ms 200, p95 63,
  max_frame 74, frames 538, chunks 81/81 all_meshed, collision_shapes 81, build_units 938,
  mem_after 78742089.
- Run 2: build_ms **4319**, gen_ms 664, total_ms **8825**, drain_s 8.82, first_draw_ms 195, p95 61,
  max_frame 99, frames 536, chunks 81/81.
- G0 sanity (`--headless --quit`): RC=0, zero SCRIPT ERROR. (OPS NOTE: after `export HOME=...`, `~`
  expands to the new HOME — use the FULL godot path `/home/angrygiant/tools/godot/godot`.)

### Decisions (all six, full text in plan.html §2/§5/§7)
- D1 static surface: new pure-static mirror functions in chunk.gd + `ChunkScript.build_accs(...)` worker
  pipeline + `make_ctx()` main-thread table snapshot; legacy sync `build_mesh`/`_build_snap` bodies kept
  for the sync path (web + kill switch byte-identical by construction); shared pure helpers converted
  to static in place.
- D2 handoff: worker receives FRESH COPIES (data/fl duplicate() + 8× neighbor data/fl copies) via
  `_tm_slots[tid]`; returns fresh Acc dicts (PackedVector3/Float32/Int32) + light dict; main thread
  consumes in `threadmesh_poll` → `chunk.apply_accs(res, ms)` (ArrayMesh/StaticBody only).
- D3 merge-atlas: main thread calls `_merge_atlas()` once before first dispatch (and in
  `refresh_textures`); workers get a duplicated rects dict + h; texture stays main-thread.
- D4 dispatch: second bookkeeping set on the shared WorkerThreadPool singleton; dedup by chunk key,
  cap ≤6 (cap-drop → sync fallback build), stale drop (node gone / data-fl mismatch → re-enqueue),
  spawn chunk (0,0) ALWAYS sync; `AWECRAFT_THREADMESH` ("0"=sync) + `AWECRAFT_THREADMESH_N` +
  `AWECRAFT_TMDEBUG`, gate mirroring world.gd:95-109.
- D5 perf: `AWECRAFT_LOGIC=perf AWECRAFT_RADIUS=4` seed 44, 2× each arm; PASS = build_ms mean drop ≥30%
  AND total_ms mean drop ≥10% (report worker-side total via AWECRAFT_TIMING=1; honest FAIL if flat).
- D6 risks: duplicate-enqueue hang (dedup+cap+stale), shared-array races (fresh copies), first-frame
  flicker (spawn sync; pop-in strictly earlier than serial drain), lighting (self-contained per-chunk
  proof + torch-14 battery), AC-0117 render-gate lesson (seed 16 for the texture-sensitive A/B).

### State
- plan.html WRITTEN (7 sections, constants re-parsed from current source).
- Probes done: G0 sanity RC=0; perf r4 baseline ×2 (above). NO code touched.
- Next: coordinator gate (re-parse constants, 7 sections) → Run-2 (builder) per plan.html.
