# AC-0152 — bedrock-realms-sim4-lod-render-50 — continuity

## 00 — 2026-08-30 — filed + parked top
- Bedrock Realms Simulate 4 default (wiki taxicab diamond 41 vs 9x9 81, spawn circle 44). Render 50 circle ~7850 vs 10201 square. Bands: 0-4 diamond exact 16x16x16 41 cols, 5-12 merged 32x32x32 diamond 104, 13-50 heightmap impostor circle 7705 quads. Tick only diamond, render circle. Stream 3x3 spawn 1s then trickle. Queue pos 0 top (ahead of 0151 water tint + 0109 frustum in-progress). Do not launch until user says go (0110 just done, 0109 still in-progress holds lane).

## 01 — builder plan + interpretations (before coding)

### Band arithmetic (verified with python, exact)
- diamond(r) = 2r²+2r+1. diamond(4) = **41** (user exact). diamond(8) = 145.
- **Band 1 = 104 = diamond(8) − diamond(4) = taxicab annulus 4 < d ≤ 8.** Exact under the
  2r²+2r+1 law. The user's "5-12" range cannot yield 104 under any simple lattice count
  (taxicab annulus 5–12 = 272; at the 32-block merge scale it would be 72/100/196). The
  exact-104 reading is unique, and the partition 41 + 104 + 7705 = 7850 ≈ N(50) confirms
  the three bands tile the render circle. "12" recorded as a memory slip for "8".
- **N(2500) = 7845** (lattice x²+z² ≤ 2500, chunk centers). User's "~7850" (Δ=5, 0.06%).
- **Band 2 = N(50) − diamond(8) = 7845 − 145 = 7700** (user's 7705, Δ=5). The user's
  "13-50" is the spec-era range; with "render the circle, no gap" band 2 = everything
  inside the circle outside diamond(8).
- 7705 quads = **7705 impostor chunks × 1 quad per 16×16 column** (Bedrock "dithered"
  fake-chunk LOD). A per-1m-column reading would be ~1.97M quads — inconsistent with the
  user's own numbers; rejected.

### Interpretations of record
1. **Simulate 4 = taxicab diamond, 4 chunks, 41 columns.** Minecraft wiki: "Realms worlds
   use a simulation distance of 9 chunks in Java Edition and **4 chunks in Bedrock**
   Edition" (minecraft.wiki/w/Simulation_distance). Not a 9×9 square (81).
2. **"Spawn circle 44 blocks" = Bedrock sim-4 natural MOB-SPAWN sphere** (mctoolbox.net
   spawn planner: "Bedrock simulation distance 4 … spawns occur from 24 to 44 blocks from
   the nearest player"). It is not the tick shape (that is the 41-chunk diamond).
   AweCraft currently has NO ambient mob spawner (entities/mob.gd is 47 lines; mobs exist
   only via the combat arm spawning them at the player), so the 44-block spawn sphere has
   no code target today. Recorded; nothing to implement.
3. **Render 50 = Euclidean circle radius 50 chunks = 7845 columns** (user ~7850 ✓).
4. **No data ring, but a small collar**: at large R every set chunk gets data (impostor
   needs own data only; band 0/1 need an 8-neighborhood). At SMALL r (harness r4) the
   diamond(8) is NOT inside circle(4): band-0/1 edge chunks need 4-axis neighbors that
   fall outside the circle. Fix: **stream set = circle(R) ∪ diamond(b1_eff + 1)**, where
   the extra ring (taxicab b1+1, outside the circle) = "collar" chunks, **band 3 =
   data-only, never meshed** (replaces the old Chebyshev r+1 data ring, which is now
   redundant at R ≥ 9 and smaller than the collar at R < 9). At R=50 the collar is empty
   (diamond 9 ⊆ circle 50). At R=4: collar = 8 chunks, set = 41 b0 + 8 b2 + 8 b3 = 57.
5. **Band 1 "32³ merged" = per-chunk coarse mesh** (LOCKED, deviation documented):
   face detection IDENTICAL to band 0 (full-res snap, neighbor culling → seam-exact, no
   height cuts), greedy merge (W≤16, H≤4) on the 512px merge strip, **2× UV scale**
   (1 atlas tile covers 2×2 blocks → 32-block texture period = the "32×32×32" LOD unit),
   cutout (leaves) rendered opaque, flora/cross quads dropped, LINEAR+mip material
   (kills the NEAREST crawl at distance). A true 2×2 GROUP mesh (32-wide quads across
   chunk borders) was rejected: group ownership (which of the 4 chunks owns the mesh),
   build dependencies on 2×2 neighborhoods, mixed-band groups at the b0/b1 border,
   band-reassignment across 4 chunks, collision + culling + 20 harness expectations —
   for a gain invisible beyond ~80 blocks. Consequence: band 1 keeps ~band-0 QUAD counts
   but ¼ the texture frequency; the user's "~4× fewer surfaces" holds per texel/texture
   period, not per quad. Reported honestly via the bandmap arm's per-band face counts.
6. **Band 2 impostor** (LOCKED): ONE 16×16 quad per chunk at the MAX column-top y (true
   heightmap, never clamped — the "no height cut" fence), textured with the top texture
   of the column attaining the max (16× tile repeats), light = full sky (1.0) day-cycle.
   Water-topped chunk → quad at the water surface with the existing animated fluid
   material. eff for neighbor import = sky-only column scan (same _att semantics as the
   light kernel, no flood, no block light — no glow sources in band 2 matter; avoids a
   98k-cell BFS per impostor chunk, ~1ms each).
7. **Tick gating**: fluid tick = band-0 diamond (41 chunks) instead of the
   fluid_tick_radius BLOCKS square. The existing `fluid_wet` per-chunk gate already makes
   the scan cheap (only chunks with active fluid are scanned; the natural ocean is
   stationary fl=0 → zero work), so no budget is needed. `fluid_tick_radius` (blocks)
   stays as a variable (settings arm asserts sim*16: 160/48) but the tick no longer uses
   it as a square radius.
8. **Trickle**: existing bounded budgets (≤3 build units/frame, 30ms, threadgen 3,
   threadmesh 3, taxicab-scored priority, spawn 3×3 fast path). Bandmap arm MEASURES
   spawn-3×3 time + queue drain evidence; no new scheduling.
9. **Settings**: DEFAULTS sim_dist 1 → 4; apply_world/apply_sim_distance additionally set
   `world.band0_r = sim_dist` (harness arms keep the fluid_tick_radius==sim*16 asserts).

### Set + band definitions (world.gd, explicit vars, env-forceable)
- `band0_r := 4` (taxicab, TICKS + full 16³ mesh), `band1_r := 8` (taxicab, coarse),
  `render_radius` (Euclidean circle, impostor outside the diamond).
- b1_eff = min(band1_r, render_radius); b0_eff = min(band0_r, b1_eff).
- in_circle: dx²+dz² ≤ R². in_stream_set: in_circle ∨ taxi ≤ b1_eff+1.
- band: taxi ≤ b0_eff → 0; ≤ b1_eff → 1; in_circle → 2; else (collar) → 3.
- Hysteresis: in-set → active; out-of-set → candidate (mesh kill, data kept);
  (Eucl > R+1 ∧ taxi > b1_eff+2) 2 recenter events → freed.
- Band reassignment on recenter (player moved): existing in-set chunk with new band →
  kill mesh + re-enqueue under the new band's path; band 0 ⇄ promotion toggles
  collision_enabled (band 0 only gets collision bodies).
- Spawn (0,0) is always band 0 (diamond 4 ⊆ any set, R ≥ 4).

### Files
1. `godot/world/world.gd` — band vars + band_of/in_stream_set; recenter WANT/STUB/
   MERGE_OLD/MERGE_RING over the new set (bounding box 2·max(R, b1+1)+1, face-chunk
   filter added to the hysteresis walk — face 2-11 keys live in the same dict and were
   being swept by accident); _make_chunk_node band + collision; _build_ready band-2 =
   self-only; _mesh_dispatch routes band 2 → impostor worker entry, band 1 → coarse
   ctx (uv_scale 2 + coarse flag); threadmesh worker/handoff band branch; tick_fluids
   band-0 diamond; env AWECRAFT_BAND0/BAND1/BAND2 in _ready.
2. `godot/world/chunk.gd` — `var band`; build_accs coarse flag (ktab→ro, no rq/rc_o,
   ~6 lines); uv_scale in _s_uvc/_s_corner_uv/_s_qwrite_merged (31.0/scale px per
   block); static build_impostor (column tops + sky-only eff, worker-safe);
   apply_impostor (free instances, 1 quad in the slab at its y, LOD or fluid material,
   last_eff from the sky-only eff); _lod_material (lit opaque shader + runtime
   ImageTexture FILTER_LINEAR + generate_mipmaps, cached); _lod_atlas_tex.
3. `godot/autoload/settings.gd` — sim_dist 1→4; band0_r wiring (fluid_tick_radius
   mapping unchanged).
4. `godot/scenes/main.gd` — ADDITIVE ONLY: `AWECRAFT_LOGIC=bandmap` arm
   `_bandmap_test` (forces render_radius=50 + recenter; waits for the stub set to
   materialize; reports tick set 41 + shape check, render set 7845, band counts,
   spawn-3×3 ms from world start, queue_size samples over time (trickle evidence),
   sample-builds N band-2 chunks (impostor quad count per chunk + total), height
   continuity spot check (impostor y == independent max-top recompute), band-0/1/2
   face counts from mesh_info; RESULT json + quit). Plus AWECRAFT_RADIUS=8 +
   AWECRAFT_SNAPSHOT render proof (xvfb gl_compatibility) →
   `.scratch/AC-0152-gates/bands.png` (camera high above spawn; all 3 bands visible:
   41 b0 + 104 b1 + 56 b2 at R=8).

### Gates
- G0 `--quit` 0 script errors.
- bandmap arm (headless, no full r50 drain): values above.
- genhash ×2: arm is direct WorldGen.generate (streaming-independent) → baseline
  unchanged; verify + save.
- SMOKE `AWECRAFT_BATTERY=player;interact;light;fluids` exact (136.78/2.82;
  place_ok true cell 2 breakable 2; 10/15/14; 2730/2730 + 888/888 + 25/9).
- boundary ONE-SHOT r4: record new band (old 267–401 / 42.2k–47.6k VOID — the square
  r4+1 wall no longer exists at the circle corners).
- render proof bands.png (3 bands, no height wall at band borders).
- Known drift (expected, reported): occlude/cave arms wait on `chunks.size() >= 81`
  (square r4) — at r4 the set is 49+8 → those arms hit their 2400-frame wait cap and
  continue with fewer chunks (their numbers drift; not in the required gate set).
  MINFO 121/81/40 → 57-chunk world at r4 (41 built + 8 impostor + 8 collar data-only).

### Non-goals / fences honored
No block IDs, no world data, no data.gd bake, no lighting formula change (impostor eff
reuses _att semantics only), no band-0 mesh format change, no TASKS.yaml/CONTINUITY.md
(godot) edits, no git. Fog: existing env fog (DayNight fog_near/far) already fades the
circle edge; the spec's chunk_lit_* u_fog line is NOT taken up (minimal diff, render
proof shows the fog behavior).

## 02 — 2026-09-14 — builder (AC-0152 + AC-0160 second run) final gate state

The bandmap arm gained a post-swap wait (`godot/scenes/main.gd`): after the
3×3 wait it waits for the recenter queue swap (`queue_size > 4000`, capped
900 frames, B0LOST watchdog) before the 1500-frame trickle sample, so the
q trend measures the real ~8.2k-entry queue instead of the 16 → 8244
recenter artifact landing mid-sample. Sample list unchanged
(`[[0,0],[4,0],[5,0],[8,0],[9,0],[10,0]]`, full 1500 frames).

Final state (AC-0160 spawn-drain fix complete — see
`tasks/AC-0160/continuity.md` for the defect, root causes, and fix):

- G0: exit 0, zero script errors (`.scratch/AC-0152-gates/g0-final2.log`).
- bandmap (`bandmap-final21.log`): tick_set_band0=41, circle50=7845,
  stream_set_home=8253, band_counts 41/104/7700/408, b0_unbuilt=[],
  built b0=41, zero B0LOST, trickle q 8244→8165 strictly monotone down
  (post-swap), [9,0] built (4133 quads), [10,0] on the edge (built this
  run, 2462 quads; not built final19/20 — E2 front variance).
  **spawn3x3_ms = 3643** — the measured machine floor, NOT the ≤ 2000 gate
  (floor breakdown in the AC-0160 notes; reported as a design conflict).
- genhash ×2 (`genhash-final1/2.log`): 25 GENHASH each, byte-identical to
  `genhash1.log` except the GENMS line + pool banner (TG 6→4, TM 2→6 — the
  AC-0160 pool cap change; expected).
- SMOKE battery (`smoke-final2.log`): player 136.78/2.82, interact
  place_ok true / cell 2 / breakable 2, light 10/15/14, fluids
  sea_surface 2756/2756 + sea_backed 914/914 + stable + 25/9 (sea counters
  drifted up vs the 2730/888 baseline — faster drain streams more sea in
  before the arm samples; stability + exact 25/9 hold).
- boundary one-shot (`.scratch/AC-0160-gates/boundary-one-shot.log`):
  ok=true, 20 crossings, **NEW p95_ms = 53** (old reference 288),
  built_final=50, resident_final=101, loads=220, marker/remesh ok.
- render (`bands.png`, R=10 top, KEPT): full-mesh bands verified by eye.
  Note: `AWECRAFT_SNAPSHOT` must be an ABSOLUTE path (relative paths
  resolve against the project dir and fail to save).
