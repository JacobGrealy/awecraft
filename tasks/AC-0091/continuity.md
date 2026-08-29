## RUN — Sat Aug 29 14:26:29 EDT 2026 — AC-0091
launched by coordinator; spec pre-written; H 80→384 (sea y30→y126, MC Y = y−64 at coordinate surfaces; ALL old baselines void)

## RUN — 2026-08-29 15:42 EDT — AC-0091 (continued after checkpoint)
MILESTONE all code edits applied, pre-G0:
- data.gd: HEIGHT 80→384, SEA 30→126 (+comment block)
- generator.gd: SPAWN_H 34→136; NEW TERRAIN_H_MAX 300; terrain_height + generate_args height loop remapped to y = 105.2 + c*36.4 + h*52.0 + (r>0.62 ? (r-0.62)*390 : 0), clamp [3,300] (= int(2.6*y_old_raw+48), sea 30→126 exact); tree_at → Data.SEA; generate() → Data.HEIGHT/Data.SEA; heights clamp 74→TERRAIN_H_MAX; scratch buffers n1/n2/n3/nc1/nc2 96→hmax, p0a/p0c/p1a/p1c 48→hmax; _ytable(+hmax param) 96→hmax + 9 call sites. Ore/lava bands kept ABSOLUTE bottom-anchored (documented).
- lighting.gd: RING re-derived (side<<17)|(yy<<4)|level [19-bit collision-free; old (side<<16)|(yy<<8)|level collided at H=384, yy max 6143]; ring is write-only (AC-0134 face mask is the live carrier) — retained for provenance; _chunk_blk_inject 2560→2*16*h
- world.gd: _side_eff_strip 2560→2*16*h; _compute_face_blk fe/fw/fs/fn 2560→2*16*h; _side_blk_strip b 2560→2*16*h + sf.size()==2*16*h + bm 2560→2*16*h; _corner_eff_strip 320→4*h; frustum cull: column center 40→H/2, dy y0-32→y0+8-H/2, col span 40*|ny|→(H/2)*|ny|
- chunk.gd: NEW static slab_n() = (Data.HEIGHT+15)/16 (24 @384); perf arrays empty → resized in init_slabs; init_slabs/slab_for_y/mark_edit_slabs dynamic; build_accs + build_mesh per-slab counters [0]*slab_n() + range(slab_n()) (6 sites); apply_accs range(slab_n()); _bake_box E/W/S/N 2560→2*16*h, SE/SW/NE/NW 320→4*h
- save.gd: save_now adds "height": int(Data.HEIGHT)
- main.gd: _continue_slot SOFT-FAIL (height mismatch → new world same seed, drop edits+player pose, keep spawn_point; never an error); probe scans range(75/74)→Data.HEIGHT-1 (3 sites); biome dbg 40→152, map 38/44→147/162, _tint_find_cell 74→300, desert 40→152; stale "80" comment fixed
- Fluid sim: verified index-driven (no hard-coded column limits) — trap 3 CLEARED; y-in-low-bits (fi=(y<<8)|...) < 98304 — trap 5 CLEARED
NEXT: G0 headless, then battery + genhash + basis sanity + MINFO + boundary one-shot + render R=1.

## RUN — 2026-08-29 16:30 EDT — AC-0091 GATES (all green)
G0 headless: RC=0, 0 script errors (clean).
- GATE fix found+applied in-run: GDScript has NO `[0] * n` array repetition → all 6 chunk.gd
  per-slab counters use new `Chunk._zeros(slab_n())` static (was `[0] * slab_n()`); this was the
  only cause of the G0 "Invalid operands Array and int for *" parse errors.
BATTERY (all NEW baselines, old VOID):
- player: start [8.5,137,8.5] (on SPAWN_H=136 pad), jump_peak_y 135.43, after_fly_y 136.78, after_fwd [8.5,5.68], horizontal_moved 2.82, is_on_floor true
- interact: target/place_cell [8,136,8], breakable_id 2, drop_spawned/place_ok true, after_place_cell 2
- light: surface_eff 15, cave_eff 10 (was 0), torch_level 14, torch_far_before 1 (was 0), torch_far_after 9
- fluids: sea_surface 2730/2730 FLAT (unchanged), sea_backed 888/888 (was 1406), sea_stable true, water_delta 1, water_on_lava 25, sideways_lava 9, shore [5,7], source [5,8]
- genhash: 25/25 deterministic (2 runs byte-identical) → .scratch/AC-0091-gates/genhash_new.txt
BASIS sanity (new AWECRAFT_LOGIC=basis probe added to main.gd, env-gated, harness-only):
- bedrock y=0 (id 11) in spawn + ocean cols; sea cell id 5 (water) at y=126 with air above;
  spawn_top y=136 solid + air above; surface sky 15 / eff 15; mc_y {bedrock:-64,sea:62,spawn_top:72,world_top:319}; ok:true
- probe fix in-run: `world` is untyped in main.gd → `:=` can't infer from its methods; used explicit `: int` types (pattern already in file).
nightday: cave 15.0 day / 3.0 night, torch 14.19996 day==night (EXACT vs AC-0135), ok:true
lightaudit: cliffs 0, tunnel seq==ref EXACT, sky_pairs 5 (natural, max_delta 3), ok:true
  (pre-existing diag-only SCRIPT ERROR in `_ac134_diag_torch` Array→Vector3i — SAME error at main.gd:3925 in AC-0134's own post log; NOT a regression; RESULT unaffected)
MINFO (AWECRAFT_LOGIC=perf AWECRAFT_MESH_INFO=1) → .scratch/AC-0091-gates/minfo_new.txt:
- 121 lines, chunks_built 81/81, all_meshed true, built:false=40 (== old baseline), empty_verts=0, min first-verts 2912, total verts 483032
BOUNDARY r4 ONE-SHOT (ESTABLISHES NEW band; old 108-133/10898-13019 VOID):
- ok:true, remesh_ok:true, marker_ok:true, walk p95=344 (old ~133), forward_p95=46404 (old ~12076),
  burst_p95=48918, trailing_p95=42457, max_ms 1017, queue_size 95 (non-zero final is normal, == old 90),
  walk_chunks 20, staged_pending_final 0, mem_delta 93.9 MB. HONEST: 4.8x-taller world costs ~2.6x walk / ~3.9x fwd (expected; spec anticipates it). No bounce (no crash/hang/queue-stuck).
  1× known PRE-EXISTING threadgen_handoff Nil→PackedByteArray world.gd transient (AC-0137 class).
RENDER R=1 (1 sanctioned, ~130 s): tasks/AC-0091/tall_world_r1.png 1280x720, RESULT m4:ok —
  grass terrain + sea water at new mid-level, sky visible (not clipped), no black void below.
  (2× threadgen transient, same AC-0137 class.)
ALL GATES GREEN. Writing deliverables (results.html, HARNESS.md) next.
