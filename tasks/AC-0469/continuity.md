# AC-0469 continuity

## RUN — Thu Oct 22 15:27 EDT 2026 — AC-0469
Stage 0 measurement: add one arm `voxelcost` to godot/scenes/harness.gd (templates: `residency` AC-0463 s2a, `warpcensus` AC-0460 s1). Deliverable: measured cost table cell_size x view_distance -> chunks, resident bytes, streaming ms, 60 fps verdict. World unchanged (genhash 25/25). Gates: g0, genhash, voxelcost; harness_doc.py --check.

## LANDED — AC-0469
- godot/scenes/harness.gd: dispatch branch `voxelcost` (after `residency`) + `_voxelcost_test` at the file tail. Warpcensus stand (flat x = hw-8, z=0) + 240-frame settle; then (4.1) live-tree bytes census over the 72 resident face chunks (slab p+i payload bytes for c.data+c.fl, slab mesh ArrayMesh surface-array bytes, ConcavePolygonShape3D face bytes; node/dict overhead = labeled gap); (4.2) timed per-chunk build ON FACE 8'S EDGE ROW (ccz=63 — face 4's far rows are unusable: face_cell_band's d.y<=0 sentinel returns distance 0.0 and every ensure there builds the mesh, measured): 16 fresh data-only `_ensure_face_chunk(8, 760+i*16, 1016)` (gen path; gen_diag proves resident_before=false, in_window=0, min_dist 3244 m) + 16 sync `build_mesh_face()` on the ccx 25..40 band line (padded, primed untimed) with data-live in-line neighbours (mesh path, incl. warp); warp sub-part = chunk.gd accumulator delta around the mesh pass; (4.3) table: 3 cells (fw/6283, fw/3000, fw/1024) x 4 views (0.5/1/2/4 km), chunks=(2*ceil(D/16c)+1)^2, bytes=chunks*B, stream_ms=chunks*M, fill_s=stream_ms/12, x_vs_6m per row; (4.4) verdict: build<=16.7 ms frame + demand 2*(v/60)/(16c)*M <= 12 ms at walk 4.3 / cruise-sprint 33.6 m/s.
- tasks/harness_data.yaml: `voxelcost` row added (after `noclip`); harness_doc.py --render done, --check clean (after the face-8 design update).
- tasks/AC-0469/AC-0469-deviations.txt: formula + 6 deviations (square window vs disc, node/dict gap, derived-by-addition build ms, the face-4 sentinel finding + face-8 edge-row choice, render-side out of scope, the 34 extra resident chunks in-process only).
- Gotchas found (for the record): Godot 4.7.1 `roundf()` takes ONE arg (no precision) — use roundf(x*10^n)/10^n; `ArrayMesh` has NO `get_arrays()` (Godot-3 API) — iterate `get_surface_count()` + `surface_get_arrays(i)` (returns an Array of typed arrays, index by Mesh.ARRAY_*).

## GATES — AC-0469
- `python3 tasks/scripts/gate_run.py AC-0469 --arms g0,genhash,voxelcost --timeout 900` → all arms ok (g0 rc=0 script=0 shader=0; genhash rc=0 script=0 shader=0 — 25/25, all 25 GENHASH lines byte-identical to the standing AC-0311 piece-2 reference `.scratch/AC-0311-gates/p2_genhash_r1.log`; voxelcost rc=0 script=0 shader=0, ok=true, fails=[]). Logs: .scratch/AC-0469-gates/{g0,genhash,voxelcost}-r{4,5}.log. Earlier revs (r1-r3) red on MY arm bugs only (roundf 2-arg parse error; get_arrays missing; face-4 sentinel — no world-code involvement at any rev).
- `python3 tasks/scripts/harness_doc.py --check` → exit 0 (in sync: modes, standing-values).
- Headline (voxelcost rev 5, ms=11502): bytes_per_chunk.measure 202,105 B (slab 9,772 + fl 0 + mesh 69,588 + collision 122,746; 72/72 chunks meshed); ms_per_chunk.build 32.654 ms = gen 13.435 (MEASURED; band-prime cross-check 13.816) + mesh 19.219 (MEASURED, incl. warp 0.966 MEASURED) — build derived by addition; table 12 rows (1.000/2.094/6.136 m x 0.5/1/2/4 km); fits_60fps [] (one build 32.654 ms > 16.7 ms frame, cell-size-independent; per-frame movement demand <= 2.286 ms/frame at cruise-sprint fits the 12 ms budget in every row — the budget paces the fill, it does not cap the view); verdict: 1 m = 37.6x the chunks of 6.136 m at the same distance; deciding numbers = bytes (0.032-47.2 GB) and fill_s (0.46-683 s).

## RUN — Thu Oct 22 17:02 EDT 2026 — AC-0469 (stage A)
Stage A: CELLS_PER_FACE 1024 -> 6283 (1.000 m blocks, R=4000). Classified list first (GRID/PAYLOAD/OTHER per site); parameterise GRID-class only; never touch the 1024-byte slab/far payload. Gates: g0, player,light,planetwalk, genhash (REBASE — new values), save,load, residency, warpcensus.
## LANDED — AC-0469 stage A
- GD (one source of truth: SphereMath.CELLS_PER_FACE := 6283 + derived CHUNKS_PER_FACE := 393, sphere_math.gd): world.gd FACE_CELLS mirror const DELETED; key_for_sphere_pos, _face_stream (clamp 0..CELLS_PER_FACE-1 >> 4, row cap mini(CHUNKS_PER_FACE), edge chunk (CELLS_PER_FACE-1)>>4 = 392), _face_edge_kind (edge_last 392, neighbour bound CHUNKS_PER_FACE-1), _face_rebake_boundary (edge_last x4), banana face*CHUNKS_PER_FACE; generator.gd generate_face face*CHUNKS_PER_FACE+cx; chunk.gd warp chart divide /CELLS_PER_FACE (GD twin of mesh.cpp); player.gd comment 0..6282; stale 1024/1023/63 comments updated (world.gd x9, sphere_math.gd, chunk.gd).
- C++ (one source of truth: awesm::SM_CELLS_PER_FACE 6283 + SM_CHUNKS_PER_FACE 393, sphere_math_cpp.h + <cstdint>): sm_face_chunk_transform x4 divides; sm_chart_dir strips face*(SM_CHUNKS_PER_FACE*16) = the 6288-cell chunk-space span and divides by SM_CELLS_PER_FACE (cell i <-> uv i/6283; the 5 padding cells past 6283 chart the gapless continuation); sp_col_index c - face*SM_CHUNKS_PER_FACE; mesh.cpp warp_face_verts divide.
- PAYLOAD/OTHER 1024s UNTOUCHED: gen.cpp 2880/3935/4475/4500, mesh.cpp 4027 (1024-byte slab/far payload), chunk_io REGION_ENTRIES, satellite 1024^2 textures, ATLAS_PX, color hash q, (v4>>8)&0x3FF block-id decode, harness pay.size checks. Classified list: AC-0469-deviations.txt (stage A section).
- Rebuild: Linux .so BUILT OK via vendored SCons (python3 -m SCons absent on this box; .scratch/run_scons.py is STALE (SCons.main import — wrong in 4.11.1) — the working recipe is `PYTHONPATH=.scratch/scons_target python3 .scratch/scons_target/bin/scons -C gdext platform=linux target=template_release -j6`, copied gdext/bin -> godot/bin). Windows .dll: cross-compile running (status in GATES entry).
- FINDINGS (deviations D1-D3 in AC-0469-deviations.txt): (1) planet_grid.gd from plan §3 does not exist; generator.gd + chunk.gd edited beyond the §3 table (user (b) requires — the C++ sp_col_index / warp twins). (2) Satellite far tier (FACE_GRID 64 + 1024^2 texture + res:// canonical asset) NOT parameterised — a 6283^2-vs-resample design decision this plan does not make; follow-up owed; inert in this gate set (canonical seed 44 loads the asset, no in-process bake). (3) Stale harness arms (leavetint/stripsprobe/lightprobe/pullprobe/meshprobe/farab/farhigh/crossface/faceedit/ac0433probe) keep hardcoded 1024/1023 — outside the gate set, harness.gd fenced; follow-up owed.

## Coordinator triage — stage A landed: the planet is on a 1 m grid (round 40)
- THE CHANGE IS REAL AND VERIFIED BY ME, not just reported: `CELLS_PER_FACE := 6283` in sphere_math.gd:58 with `SM_CELLS_PER_FACE = 6283` as the single C++ constant (sphere_math_cpp.h:42), 25 GRID sites parameterised (16 GDScript + 9 C++), and the payload constants provably untouched — the three `out(1024)/resize(1024)/== 1024` section-payload sites are still there, which is the line this stage must never cross. Both binaries built, including the Windows .dll cross-compile.
- BOOTS CLEAN AT THE NEW GRID: g0 rc=0 with SCRIPT=0/SHADER=0 (my own run), player ok with sprint_ok, and planetwalk crosses both seams into the NEW edge chunks — dest 5:392:391 and 11:391:392, where 392 is the 393-chunk face edge the new grid implies. The machine works at 1 m.
- THE GENHASH SURPRISE, reported as the builder found it rather than as the plan predicted: genhash is **25/25 byte-identical to the standing reference**. My plan assumed the rebase would move it; it did not, because the genhash 5x5 window sits on the home pair and that window's generation is grid-independent by construction. So the declared rebase lands on faces 2-11, which genhash does not cover — and that is exactly why planetwalk crossing into the new edge chunks matters as evidence: those faces do regenerate and mesh at 1 m.
- WHAT IS NOT DONE, and it is honestly flagged in the builder's deviations rather than hidden: the satellite far tier is sized for the old grid (a 1024^2 texture and a 64x64 bake) and was NOT parameterised, because re-bake vs resample is a design decision the plan did not make. It is inert in the gate set but it is real debt and a follow-up is owed. The builder also recorded the working SCons recipe (python3 -m SCons is not on this box; .scratch/run_scons.py is stale), which is a durable ops fact worth harvesting.
- STATE: the grid is 1 m planet-wide and the game runs. The next two stages are the ones stage 0 named as the real bottlenecks — per-chunk gen (13.4 ms) and mesh (19.2 ms) cost, plus fill time — now measurable at the true resolution rather than projected.

## RUN — Thu Oct 22 18:09 EDT 2026 — AC-0469 (stage B)
Stage B: face-lane window unit bug (metres/cells vs chunks) in _face_stream rows; one helper _chunks_across; gates residency (leak false, plateau vs 499), g0,player,light,planetwalk,seamcensus, save,load.
## LANDED — AC-0469 stage B
- godot/world/world.gd: new helper `_chunks_across(win_m, stride_m)` = int(ceili(win_m / (16.0 * stride_m))) + 1 (the ONE metres->chunk conversion; placed after _face_in_mesh_window, before _face_stream). The `rows` site (~15126, now ~15143) converted to `_chunks_across(win, S)` x-faces / `_chunks_across(win, S * 0.5)` z-faces — z-face halving rule kept verbatim. At sim_dist 4 (win 64 m, 1 m cells): x-face rows 65 -> 5, z-face rows 129 -> 9.
- Siblings audited inside _face_stream (ALL genuinely in cells/metres, UNCHANGED): lo/hi (flat-metre positions, p±win clamped to ±hw — never indices); edge_dist > win (metres vs metres); idx_lo/idx_hi (lo/hi divided by stride = S*0.5 m/cell => CELLS, correct units) and cc0/cc1 ((cell index ± 16-cell pad) clamped to cell range then >> 4 — cells to chunks, correct); edge_cc*16+8 / cc*16+8 (chunk-local centre cell slots). _face_chunk_min_dist (15055) uses ccx*16+1/+14 cell corners — CORRECT, left. _face_in_mesh_window: sim_dist*16 m + 8.0*S (cells->metres margin) vs _face_chunk_min_dist (metres) — consistent, left. Eviction sweep, travel gate, window VALUE (win from _stream_window), chunk size 16, generation, mesher, warp: untouched.
## GATES — AC-0469 stage B
- THE FIX GATE (residency, canonical run): `python3 tasks/scripts/gate_run.py AC-0469 --arms g0,residency,player,light,planetwalk,seamcensus,save,load --timeout 1500` → ALL rc=0, SCRIPT/SHADER 0/0. residency: leak=false, stable=true, converged=true, verdict STABLE, keys_same=true — face residency PLATEAUS at 129 (home 127) with a stationary player vs pre-fix 79 -> 499 unbounded growth (round 41): 3.9x fewer resident face chunks, bounded (win 64 m < evict radius 128 m). Convergence 80->97->112->128->129->129 then 6 flat samples. Log .scratch/AC-0469-gates/residency-r4.log (an earlier solo residency run, r3, agreed: plateau 130).
- Other arms, same run: g0 ok; player ok sprint_ok=true; light ok (surface 15/cave 0/torch 14); planetwalk ok — STILL CROSSES INTO THE NEW EDGE CHUNKS (dest 5:392:391 x_seam, 11:391:392 z_seam; 392 = the 393-chunk face edge); seamcensus ok=true rows_ok=393216 (clean); save ok (r_saved/r_loaded 4000); load ok, simband_ms 6628 (stage A was 6670 — within run noise, no window widening). No boundary holes: the shrunk row count did not under-stream (planetwalk + seamcensus both clean).
- Logs: .scratch/AC-0469-gates/{g0-r8, residency-r4, player-r4, light-r3, planetwalk-r4, seamcensus-r2, save-r3, load-r3}.log.

## Coordinator triage — stage B: the leak is FIXED and I verified it myself (round 42)
- THE FIX, and it was one defect: `_chunks_across(win_m, stride_m)` (world.gd:15099) is now the face lane's single metres→chunks conversion, and the `rows` computation was the ONLY site with the bug — a grep for `win / S` across world.gd returned exactly one hit pre-fix. Everything else the builder audited (lo/hi, edge_dist, idx_lo/idx_hi, cc0/cc1, the local slots, `_face_chunk_min_dist`) is genuinely in cells or metres and was correctly left alone, with the reasoning recorded per site.
- VERIFIED BY MY OWN RUN, not taken on report: `leak False, stable True, converged True`, and the steady series is `130, 130, 130, 130, 130, 130` — a flat plateau at 130 face chunks and 117 home, against the pre-fix 79→499 unbounded climb. That is a 3.9x reduction AND, more importantly, a bound where there was none.
- WHY IT WAS ONLY ONE LINE OF DAMAGE: the old code divided metres by CELL size where it needed CHUNK size, and at 6.136 m cells the resulting error (11 rows instead of 2) was absorbed by the eviction radius being larger than the creation window. At 1 m cells it inverted that relationship. So the bug was latent for the project's entire history and the resolution change is what made it express — which is exactly the class of defect that a grid change is most likely to surface, and why measuring residency immediately after the change was the right order.
- NOT A REGRESSION SWEEP: planetwalk still crosses into the new edge chunks (5:392:391, 11:391:392), seamcensus is clean over 393,216 rows, g0/player/light all ok, and save/load runs at simband_ms 6628 — no boundary under-streaming and no radius widening was needed.
- STATE: the planet is on a 1 m grid AND bounded. The remaining work in this ticket is throughput (gen 13.4 ms + mesh 19.2 ms per chunk, measured before the grid change and worth re-measuring now) and the satellite far-tier re-baseline; then the home grid deletion and the twelve-chart lap.

## Coordinator triage — streaming still keeps up at 1 m (round 43, the gameplay question)
- THE MEASUREMENT THAT MATTERS FOR THE CONSTRAINT, run by me on the new grid: the boundary r4 walk reports **crossing_frame p50 31 ms / p95 38 ms**, against the documented standing band (p50 27 / p95 38, drift band 35-55). p95 matches the standing value exactly; p50 is 4 ms above it, inside the band. 42 crossings, 20 walk chunks, `ok` true with `marker_ok` and `remesh_ok`, built_final 76, resident_final 114, mem_delta 124.4 MB over a 21.9 s walk.
- WHY THIS IS THE ANSWER TO "does 1 m work": the fear was that 37.6x the addressing resolution would starve the streamer. It did not — because the streaming window, the chunk size (16 cells) and the residency policy are all expressed in CHUNKS and METRES, not in cells per face, so the per-frame work is unchanged by the grid. What the grid change DID break was the face lane's unit conversion (found and fixed at ee123a3); with that corrected, the walk behaves like the pre-change tree.
- THE HONEST CAVEAT, stated because the plan's own risk list demands it: this arm walks the HOME pair, where geometry density did not change (the home patch was already 1 m). It proves the streamer is healthy and that the grid change did not poison the shared machinery; it does NOT by itself prove the same about a long traverse over faces 2-11 at 1 m. That is what the twelve-chart lap is for, and it remains owed.
- MEMORY at the new grid: mem_delta 124.4 MB across the walk with resident_final 114 — in the same class as before the change, not a new regime.
- STATE: 1 m grid landed (f926ab5), its face-lane unit bug found and fixed (ee123a3), residency bounded at 130/117, and the walk green at its standing latency. The remaining AC-0469 work is the satellite far-tier re-baseline (flagged at stage A), the home-grid deletion, and the twelve-chart lap.

## RUN — AC-0469 (stage C) — twelve-chart lap
Extend the planetwalk arm from 2-of-12 boundary coverage to the full lap: derive the face adjacency by probing world_to_face along +u/-u/+v/-v (record the table in deviations as a deliverable), cross every undirected pair it gives, keep every existing field and the negative control (AWECRAFT_PWN_SKIP_WAIT=1 must still report saw_unbuilt true), and report which of the 12 faces were stood on. Measurement only; no game behaviour change. Gates: g0, genhash (25/25), planetwalk (ok, differing faces, mesh AND body at every destination), the negative control, harness_doc.py --check.
## LANDED — AC-0469 stage C
- godot/scenes/harness.gd: planetwalk arm extended to the twelve-chart lap (measurement only, no game behaviour change): `_planetwalk_derive_adjacency` (probes world_to_face 8 m past each of the 12 faces' 4 edges at two along-edge points — the derived table is a deliverable, cross-checked against SphereMath._EDGES and the match reported), `_planetwalk_lap_pair` (one crossing per derived undirected pair except the two legacy seams, kept verbatim for comparability: stand 8 m inside the from face at the candidate crossing point — edge middle / 40 m from either end, keeper whose probe lands on the to face and sits nearest a home patch corner — walk 8 m steps in the face's own (u,v) until the anchor face changes, same snapshots/waits/fields as the legacy helper), `_planetwalk_corner_dist`, `_planetwalk_sorted_keys`. New result fields: adjacency {table, pairs_total, edge_table_matches}, lap {covered, covered_total, pairs_total, uncovered, faces_stood_on, faces_src_built}; all pre-existing fields and the negative control unchanged. A pair whose src never builds is a DOCUMENTED uncovered pair (src_settle_timeout); a src that builds but the dest does not is a genuine finding and fails the arm.

## GATES/RESULTS — AC-0469 stage C (final)
- FINAL GATE (all green): `python3 tasks/scripts/gate_run.py AC-0469 --arms g0,genhash,planetwalk --timeout 900` (by-name runner .scratch/AC-0469-gates/run_stage_c_lap.sh) → g0 ok (0 script errors, rev 18); genhash ok — 25/25 region hashes, BIT-IDENTICAL to the pre-lap run (genhash-r6 vs r7 diff empty: the world is unchanged by the arm work); planetwalk ok=true, 31 s gate / 28.1 s arm.
- THE LAP: 25 of 26 derived boundary pairs covered with mesh AND body at the destination (23 generic lap crossings + the 2 legacy seams 4-5/10-11 walked verbatim). Uncovered: lap_0-1 = `home_pair_midline` — the home pair is a keying split inside the flat world (world.player_anchor collapses it to face 0 inside the patch), so no chart boundary is observable there: documented (plan §7: a documented subset, never a silent gap), excluded from the red conditions and from the saw_unbuilt scan (it is a no-boundary result, not an unbuilt boundary — excluding it keeps the normal/skip contrast).
- ADJACENCY (the deliverable): derived by probing world_to_face 8 m past each face's 4 edges; 26 undirected pairs (the plan's "24" was an estimate); table in AC-0469-deviations.txt (C-section) + adjacency.table in the RESULT; edge_table_matches=true (vs SphereMath._EDGES, runtime) AND an independent Python re-derivation (.scratch/AC-0469-gates/derive_adjacency.py).
- FACES STOOD ON: anchor faces 0,2,3,4,5,6,7,8,9,10,11 (face 1 reads face 0 by the collapse); per-pair intended chart faces: ALL 12 (lap.faces_stood_intended). faces_src_built: 0,2,3,4,5,6,7,8,9,10,11 (every chart src built at the stand — src_wait_ms -1; only the home-src settles for the 0-* pairs waited, 0.6-3.8 s).
- NEGATIVE CONTROL (unchanged semantics, still firing): normal mode negctrl.saw_unbuilt=FALSE (the contrast — everything the arm reads is built); skip mode (AWECRAFT_PWN_SKIP_WAIT=1) saw_unbuilt=TRUE (0-* home src unbuilt at check time + stand-instant destination snapshots), face still changes, ok=true. Log .scratch/AC-0469-gates/negctrl-r2.log.
- HEADLINE FINDING (measurement, no fix made — deviations C5): the face lane prestreams only the 4 x-faces correctly. The z-face band window (world.gd:15199) doubles the along-edge index (z-faces' u axis charts at 1.0 m/cell; the stride is 0.5): faces 8/10 degenerate to ONE corner column (measured footprint 8:392:384-392 = 9 chunks vs the designed ~10 columns x 9 rows); faces 9/11 over-stream the whole chart from ccx 0 (budget never reaches the crossing window); faces 2/3 are never streamed at the lap stands. Yet every one of the 25 crossings lands on terrain with mesh AND body at the crossing frame (honest snapshot, before any ensure) because the game's own per-frame player column query (player.gd fluid checks 579-583/748/888 -> get_block_key -> _ensure_face_chunk; live auto-step surface_top_key player.gd:790) builds the player's own anchor column on arrival, and _face_in_mesh_window's is_inf sentinel (face<4/far hemisphere) makes that ensure build the MESH synchronously. No hole at any boundary; the PRESTREAM (build ahead of the crossing) is what is unmet on the z/-Y faces. Scattered corner chunks in the resident census are the same on-demand path at the corner-ward anchor the 141 m stand altitude produces (not isolated per chunk).
- INSTRUMENT FIXES MADE DURING THE LAP (harness.gd only, the legacy _planetwalk_crossing untouched field-for-field): stand 9 m inside (not 8 — 8 m = exactly one chunk on the 0.5 m/cell axis; the anchor's ccx flipped on float noise: key_match false + spurious src_settle_timeout measured pre-fix); player velocity zeroed at stand and walk step (stand_drift_m 0.0 in every final crossing); the collapsed home anchor (no "inv" key) guarded in the lift diagnostic; the from-face assert collapse-aware (face 1 stands read face 0); (0,1) returns the documented home_pair_midline result instead of a red. Stage-C debug fields on lap pairs: src_key/lift_key/key_match/lift_built, stand_drift_m, to_resident_at_cross/to_resident_sample (the band footprints are read straight off these).
- harness_doc: tasks/harness_data.yaml planetwalk row updated (notes/result_fields/wall) -> harness_doc.py --render + --check pass (in sync: modes, standing-values).
- Logs: .scratch/AC-0469-gates/{g0-r18, genhash-r7, planetwalk-r12, fullgate-r1, normal-r9, negctrl-r2}.log + derive_adjacency.py.

## Coordinator triage — the 1 m grid is NOT 1 m on the chart faces (round 45) — filed as AC-0471
- CHASING THE LAP'S PRESTREAM FINDING LED SOMEWHERE MORE IMPORTANT THAN PRESTREAM. `face_cell_scale` (sphere_math.gd:450-454) is anisotropic BY DESIGN (AC-0309): faces 4-7 are (s, s*0.5), faces 8-11 are (s*0.5, s). The halved axis exists because each chart face covers only half a cube face along that axis. At the old 6.136 m nominal cell the halved axis was 3.068 m and the asymmetry hid inside a world whose blocks were already metres wide. At the 1 m target it yields a 0.500 m axis.
- MEASURED, not inferred: nominal S = 1.0000 m, so faces 4-7 are 1.000 x 1.000 x 0.500 m and faces 8-11 are 0.500 x 1.000 x 1.000 m. The z-face u chart is internally consistent (6,283 cells x 0.500 = 3,141.6 m = hw), which is exactly why nothing crashes: the geometry is right and the BLOCKS ARE NOT CUBIC. The user's constraint is "as close to 1m x 1m x 1m as possible"; on eight of twelve faces it is currently 1 x 1 x 0.5.
- WHY IT CAUSED THE PRESTREAM SYMPTOM: the window converts flat metres to CELLS using the halved scale, so the derived cell count is twice what the chunk derivation expects, and chunks collapse to a corner (8/10) or blow out across the chart (9/11). Fixing the window arithmetic alone would have papered over a block-size defect with a window tweak — which is why this was filed separately rather than "fixed" in AC-0470.
- THE REAL FIX IS A PER-AXIS GRID: the halved axis needs half the cells (3,141 not 6,283) for its cells to be 1 m, so CELLS_PER_FACE becomes two numbers threaded through indexing, keys, chunk derivation, generation addressing and the C++ lanes. That is an address-space change, not a constant tweak, and it needs the same GRID/PAYLOAD/OTHER census discipline AC-0469 stage A used - because 6283 now appears exactly where 1024 used to.
- SCOPE GOOD NEWS: faces 0-3 are already isotropic at 1 m, so the defect is confined to the eight chart faces, and under the "no home" design it is those faces that must become the standard. This is the next real step toward uniformity rather than a detour.

## RUN — Fri Oct 23 01:18:14 EDT 2026 — AC-0469 (stage D)
Far-tier rebase: FACE_GRID 64 -> SphereMath.CHUNKS_PER_FACE (393), threaded through the bake state dict and indexing; shard consts derived from the new pay_total; bake worker cell-space mapping (2.6 texels/chunk). Measure BEFORE bake (old code, seed 45) before touching code, then AFTER bake + gates g0,genhash,planetwalk,residency + one nadir render at the user vantage.

## GATES — AC-0469 stage D (round 48, 2026-10-23 01:18-03:00 EDT)
- g0 rc=0, SCRIPT 0 / SHADER 0 (g0-r20.log).
- genhash 25/25, the 25 GENHASH lines byte-identical to the stage-C reference
  (diffed genhash-r8 vs genhash-r7) — generation untouched (the far-tier
  indexing fix writes no world state).
- planetwalk rc=0, 25/26 crossings ok (the one excluded: lap_0-1
  home_pair_midline, the stage-C convention); all 25 have mesh_built +
  body_present + cross_mesh_built + cross_body_present (planetwalk-r14.log).
- residency rc=0: leak=false, ok=true, verdict STABLE, converged, 6 flat
  samples (face 55 / home 117), keys_same true — bounded (residency-r6.log).
- COVERAGE (gate a): 154,449/154,449 (100%) of the 393^2 chunk slots per
  chart face, x10 faces — the merge check ("bake: payload done - 1699726
  records merged"; it fails the bake if short) + 12/12 face tasks ok, all
  12 variance guards pass.
- COST (gate b), seed 45, sharded bake, 8 GB cap, 10 s RSS sampling:
  BEFORE bake wall 182.8 s / peak RSS 1,829,208 KB (1.744 GiB) / 196,196
  records; AFTER bake wall 1,269.0 s (21.2 min) / peak RSS 4,823,572 KB
  (4.603 GiB, the merge spike: shard bufs 1.74 GB + merged pay 1.74 GB +
  base) / 1,699,726 records (1,740,519,424 B). Wall ratio 6.94x (the
  37.7x-per-face is records; the wall scales total records / 6 threads).
  Face stage FLAT (27.3 s vs 27.9 s wall). A full bake is PRACTICAL:
  one-time per seed (user:// cache, key untouched), ~21 min on this 6-core
  box, ~12 min projected desktop (the AC-0414 slice scaling). The offered
  trade (2x payload cut: bake only chunks_u x chunks_v per face) is noted
  in D12, not implemented (plan fence).
- RENDER (gate d): tasks/AC-0469/ac0469d_far_nadir.png — nadir preset at
  the user's vantage (2,000 m, straight down), 1280x720, drain 600 (fully
  drained: RESULT body_phase=4, drain=600), seed 45 (non-canonical: seed 44
  would load the stale shipped assets). The far field REACHES THE HORIZON
  on the chart faces: terrain runs continuously to the disc's limb, fading
  in the limb haze at grazing angle; NO visible edge, seam ring or empty
  region. A/B pair bake-before-r1.png vs bake-after-r1.png (drain 60, same
  vantage/seed): 54.3% of pixels differ, strong-diff (delta>60) 10.2%
  overall rising 0.0% (disc centre, the home pair - bit-identical) to
  28.3% (the chart-face limb annulus) with radius — the fix's footprint is
  exactly the chart-face far tier.
- Deviations D9-D15 (AC-0469-deviations.txt): the fix + its provenance
  (the old bake charted columns ccx-329f PAST the face since stage A), the
  shard re-factorization 98x2002 -> 1169x1454 (mechanical, required by the
  exact-factorization invariant), NPIX=1024 stays (2.6 texels/chunk, 6.136
  m/texel UNCHANGED in metres), the cost numbers, the coverage proof, the
  render description, genhash 25/25.
- Engine work via named runners (run_bake_measure.sh, run_gate_render.sh,
  run_stage_d_gates.sh) — the pgrep -f "[g]odot" slot-test trap; renders
  serial; 8 GB ulimit + RSS sampling per OPS.md 2.

## Coordinator triage — stage D: the far tier now covers the whole planet, at a measured price (round 47)
- THE DEFECT WAS WORSE THAN I MEASURED. I reported FACE_GRID := 64 as covering 16% of each chart face. The builder found that since stage A the C++ stride is 393, so the old bake did not merely under-cover — it charted columns ccx - 329f PAST the face, i.e. it was reading the wrong ground entirely. Deriving the constant from SphereMath.CHUNKS_PER_FACE fixes both the coverage and the stride mismatch.
- COVERAGE IS NOW 100% AND IS PROVEN, not asserted: 154,449/154,449 slots per chart face across 10 faces, enforced by the merge check itself ("bake: payload done - 1699726 records merged", which fails if short) plus 12/12 face tasks and 12/12 guards.
- THE PRICE OF 1 m EVERYWHERE, stated in full because the user deserves the real number rather than a reassurance: the far-tier bake goes from 182.8 s / 196,196 records / 191.6 MiB / 1.744 GiB peak to **1,269 s (21.2 min) / 1,699,726 records / 1.62 GiB / 4.603 GiB peak RSS**. That is a 6.94x wall increase (not 37.7x — per-face records scale, wall scales with total work over 6 threads). It is a ONE-TIME per-seed cost on this 6-core box, cached in user://; a desktop is projected around 12 minutes. Under the 8 GB cap with headroom.
- THE VISUAL ANSWER, which is what the user will actually judge: an A/B render at nadir 2,000 m shows the far field reaching the horizon with terrain continuous to the disc's limb and no visible edge, seam ring or empty region; 54.3% of pixels differ from the old bake with 0% strong-diff at centre (the home pair is bit-identical) and 28% in the chart-face annulus. So the change is confined to the chart faces exactly as intended.
- NOTHING ELSE MOVED: genhash 25/25 byte-identical against the stage-C reference (this is an indexing fix, generation did not move), planetwalk 25/26 with mesh and body everywhere, residency STABLE and bounded.
- A CHEAPER OPTION EXISTS AND WAS DELIBERATELY NOT TAKEN: baking only chunks_u x chunks_v per face would halve the payload, and it is recorded in D12 rather than implemented because the plan fenced scope. Worth revisiting if the 21-minute bake proves annoying in practice.
- STATE: at 1 m cubic blocks the planet now has near-field detail, a fully covered far field, bounded residency, a green twelve-chart lap and a green boundary walk. AC-0469's last item is the home-grid deletion.

## RUN — Fri Oct 23 04:00:26 EDT 2026 — AC-0469 (stage E)

## LANDED — AC-0469 stage E
- godot/world/world.gd ONLY (harness.gd untouched — the arms are the instruments):
  (1) `const FACE_DRAIN_MAX_PER_POLL := 1` (next to threadgen_max, ~3482): the drain's per-poll cap on FACE handoffs — the face landing carries the main-thread mesh build (~20 ms class); a batch of worker completions must not pile into one drain frame. 1 = the old pass's effective per-frame rate (one ensure per FACE_STREAM_BUDGET_MS pass), minus the gen (now off-frame). Home handoffs stay unpaced (reference swap).
  (2) `_threadgen_worker`: face branch (kind="face") — the SAME worker, the (face, R) generate_flat (args = [ccx_lin, ccz_lin, seed, HEIGHT, SEA, face, R]; the linearization face*CHUNKS_PER_FACE+cc is computed ONCE at enqueue, mirroring generate_args' last line — no second transform site; the C++ sp_col_index inverts it). Result = the flat column PackedByteArray. Banana + landing stay on the main thread (the home resl split).
  (3) `threadgen_enqueue_face(face, ccx, ccz, key, inst, colgen)`: the face request on the SAME worker queue (no second protocol) — dedup on _tg_inflight_keys (the 3-part face key is a namespace disjoint from home "0:cx:cz" — single owner per key, two queues cannot double-generate), same threadgen_max cap, same slots/pool, cap-drop = retry not loss.
  (4) `threadgen_poll`: face branch — PackedByteArray shape check (no result => re-enqueue, the AC-0178 home retry rule, _shutting_down drop parity); pacing (a completed face result that hits the cap STAYS in inflight — result held, dedup key with it — and lands on a later poll). Home path untouched, statement-for-statement (res read moved to the top of the completed block — same value, same side-effect order).
  (5) `_ensure_face_chunk(face, colx, colz, sync_build = true)`: register at checkout (chunks[key]=c + _face_order.append at checkout — the home-lane pattern, _make_chunk_node inserts before the gen; single owner from the instant of checkout). Data-empty + sync_build=false (+threadgen) => ENQUEUE (the prestream/window request, the common case) and return — a resident-but-unbuilt chunk (a cap-drop) re-enqueues (dedup-safe). Data-empty + sync_build=true (DEFAULT — every existing caller: get_block_key, set_block_key, surface_top_key, the mob spawn — unchanged) => the SYNC FALLBACK: generate_face + banana + _face_land NOW (the player's own column query, incl. the far-hemisphere faces whose _face_chunk_min_dist reads the is_inf sentinel — the player must never stand on nothing, AC-0145). An in-flight key hit by the sync path: the worker's later drain result lands as a datadrop (gen is deterministic — bit-identical).
  (6) `_face_land(c, face, ccx, ccz, key, fdata)`: the landing EXTRACTED from the old inline body — the SAME sequence verbatim (data_landed, no_caves, _rt_dirty x2, _apply_edits_to_chunk, transform, collision_enabled, star seed_column + star_owed, build_mesh_face iff _face_in_mesh_window (the occluder rides this build — AC-0460 parity), _face_rearm_home_neighbors, the FIFO cap). Both the sync fallback and the drain call it — a drained chunk cannot half-land.
  (7) `_face_threadgen_handoff(e, fdata)`: the drain landing — inst+colgen validation (AC-0247 pattern), data-empty check (sync-fallback-landed => _tg_datadrop, exact), banana, _face_land.
  (8) `_face_stream`: the two prestream/window call sites (x/z faces) pass sync_build=false — the budget checks are UNCHANGED (an enqueue is O(1); the pass still spends at most FACE_STREAM_BUDGET_MS).
- NOT touched: home-lane policy/residency/eviction/travel gate, prestream arithmetic (AC-0470), keys, saves, light, mesher, warp, harness.gd.
## GATES — AC-0469 stage E (all green; logs under .scratch/AC-0469-gates/)
- (a) g0-r22: rc=0, SCRIPT/SHADER 0/0. planetwalk-r15 (normal): rc=0, ok=true, 25/26 covered (lap_0-1 home_pair_midline = the documented waiver); ALL 25 crossings have mesh_built AND body_present (post-settle) — and cross_mesh_built AND cross_body_present at the crossing-frame snapshot for every crossing (the async prestream lands BEFORE the player crosses in all 25; settle_ms 0-1). negctrl r15: ran=false saw_unbuilt=false (the contrast holds: normal sees everything built). residency-r7: rc=0, leak=false, ok=true, steady face 74 / home 127 FLAT over 6 samples, converged=true, keys_same=true, verdict STABLE, face evictions 0 (in-flight chunks are residents from checkout — the home-lane pattern; the count converges to the same band, the window is unchanged). seamcensus-r3: rc=0, ok=true, rows_ok=393216 (clean).
- (b) boundary-r2: rc=0, ok=true, marker_ok/remesh_ok true, 44 crossings, crossing_frame p50 30 / p95 38 / max 47 (mem_delta 118.4 MB) vs the current reference 26/38 (AC-0470 boundary-r1): p95 EXACT; p50 +4 ms vs that single reference run — but this ticket's own boundary-r1 (stage-A era) and round-43's run both measured p50 31: the single-run p50 band on this tree is 26-31 and 30 sits in it. THE WALK IS HOME-ONLY (face_wall_ms: 0 in boundary-r2.log — the face lane is inert in the walk region), so the stage's change is not in any crossing's path; the delta is run-to-run variance on a home-only walk, reported not explained away.
- (c) genhash-r9: rc=0, 25/25 — BYTE-IDENTICAL to the stage-C/D reference (genhash-r7, diff empty). Same terrain, different scheduling.
- (d) save-r4: rc=0, ok=true, r_saved=r_loaded=4000 (unchanged from stage B). load-r4: rc=0, ok=true, simband_ms=6632 (stage B 6628 / stage A 6670 — noise, no window widening).
- NEGCTRL (the teeth): planetwalk-r16 with AWECRAFT_PWN_SKIP_WAIT=1: rc=0, ok=true, ran=true, saw_unbuilt=TRUE (the 0-* crossings' home-side src unbuilt at stand time; stand_dest_built=false at every snapshot) — the instrument still sees an unbuilt boundary.
- Deviations D16-D20 in AC-0469-deviations.txt (stage E section). Results page re-rendered.

## Coordinator triage — stage E: the two lanes now share the generation machinery (round 50)
- VERIFIED BY MY OWN RUN: `leak False / stable True`, convergent in 504 ms, 74 face / 138 home flat across six samples with `keys_same` true, g0 0/0 and genhash 25/25. The builder's planetwalk report is 25/26 with mesh AND body at every destination plus the negative control firing.
- WHAT ACTUALLY LANDED, and it is the structural milestone this whole ticket was for: face chunks now ENQUEUE on the home lane's threadgen queue and land via the home lane's drain, reusing the same worker, the same `threadgen_poll`, the same `_tg_inflight_keys` single-owner dedup (3-part face keys, disjoint from home). No second protocol, no second drain. The landing was extracted to `_face_land` and is called by BOTH the drain handoff and the sync fallback, so there is one landing path rather than two that could drift.
- THE SAFETY LINE HELD EXACTLY AS SPECIFIED: the prestream and window requests enqueue; the player's own `get_block_key`/`set_block_key`/`surface_top_key`/mob-spawn path still builds SYNCHRONOUSLY, which is what guarantees the player never stands on nothing (the AC-0145 hazard). A sync-built chunk's later worker result is a bit-identical datadrop rather than a second build.
- THE LATENCY NUMBER, reported honestly rather than dressed: boundary p50 30 / p95 38 / max 47 against p50 26 / p95 38 — p95 exact, p50 +4 ms, and the builder's own note that this tree's single-run p50s have read 26 and 31 in the last two rounds, so it is within observed variance. It ALSO notes the walk is home-only (face_wall_ms 0), so this stage's change is not on any crossing's path at all — which is the correct way to read a flat result rather than claiming an improvement that did not happen.
- ONE DESIGN DECISION THE BUILDER HAD TO MAKE (D18): drain pacing, `FACE_DRAIN_MAX_PER_POLL = 1`, because a face landing carries the main-thread mesh build and unpaced results would burst. Reasonable, recorded, and the residency plateau (74/138, stable) is the evidence the pacing is adequate.
- STATE: both lanes generate through one queue and one drain, share one landing path and one node-creation path (slice 1), one travel gate and one window (slice 2b), one key shape, one placement, and one grid. What remains is genuinely the last mile: retire the face lane's now-redundant special-case machinery (its own budgeted prestream pass and its separate residency bookkeeping) and let the generalised lane own faces 0-11 outright.

## RUN — Fri Oct 23 05:13:35 EDT 2026 — AC-0469 (stage F)
## LANDED — AC-0469 stage F (design note; NO code touched)
- tasks/AC-0469/AC-0469-deviations.txt: stage F section answering §2.1-2.5 with file:line evidence.
- 2.1 COORDINATES: NO single space. The band predicate is taxicab on flat INTEGER chunk deltas (in_stream_set 6894-6898; _rec_player_wx/wz 3416-3417); a face player has no position of its own there — _face_player_flat CLAMPS to the patch (15178-15191), and extended-flat (sphere_math.gd face_cell_band 650-670 / home_flat_ext 628-634) is INF on the far hemisphere (the is_inf sentinel, 15171-15172). The planet frame contains both player and chunks but is not the band metric. Option A = merge the residency policy on extended-flat (keeps the clamp + sentinel special cases); Option B = move band0_r/band1_r/in_stream_set to angular radii = a change to the band model itself (a bigger ticket).
- 2.2 CLASSIFICATION: edge-normal gate (15296-15302) = (b) face rule; per-face edge band rows (15257, _chunks_across 15210) = (b); along-edge half-window + mirror chart (15270-15285, 15324-15333) = (b); budgeted pass FACE_STREAM_BUDGET_MS (15234) = (c); separate _face_order/_face_evict_last (14809, 14826; travel gate already unified at 11950/12377/15365) = (c). Nothing is (a). Also (b): the mesh window (15193-15199) and the sync fallback (15651-15672, AC-0145).
- 2.3 BANDS GUARANTEE: stream set = taxisquare(4) ∪ diamond(b1_eff+1=5) ∪ ring (6898); band 0 (taxi<=4, 41 cols, 6754) is the only full-fidelity region, held by the band-bounded crossing sweep (12062-12097) + queue + drain; the face half of "the chunk under the player exists" is the sync fallback, expressed in a CONTINUOUS per-chunk metric (_face_chunk_min_dist 15165-15176) — not per-face expressible in the band's integer predicate; evict margins differ (home 32 m at 12104 vs face 64 m at 14827) — the unified lane must choose.
- 2.4 FIRST FAILURE: the edge-crossing frame stall from losing the 12 ms budget — the home crossing sweep (11972, 6054) is a one-shot synchronous, flat-keyed, un-budgeted event; a naive merge creates the whole face band in one frame (arm: boundary p95/p50, standing 38/26-31), and its correctness twin is the crossing-row void if the sync fallback is dropped (arm: planetwalk 25/26 + negctrl saw_unbuilt). The 16 m travel gate vs wide band is eviction-side hysteresis by design; the real risk is a new window/evict radius mismatch (round-41 leak class, residency arm).
- 2.5 STAGED ORDER: (1) one residency PREDICATE resident_of(key), zero behaviour change — gate genhash 25/25 + residency plateau; (2) one resident list + one travel-gated sweep — gate residency + planetwalk; (3) creation through the per-frame unified pass with the (b) rules as named sub-rules, budget kept, sync fallback kept — gate boundary p95<=38 + planetwalk + negctrl + genhash; (4) delete _face_stream and the split's constants — gate the full stage-E set.
## GATES — AC-0469 stage F (tree provably untouched; logs under .scratch/AC-0469-gates/)
- g0-r24: rc=0, SCRIPT/SHADER 0/0.
- genhash-r11: rc=0, 25/25 — BYTE-IDENTICAL to the stage-E reference genhash-r9 (diff empty).
- residency-r9: rc=0, leak=false, ok=true, steady face 74 / home 127 FLAT over 6 samples, converged=true, keys_same=true, verdict STABLE, face evictions 0 — the SAME plateau as stage E (stage-E builder log residency-r7/D19: 74/127; coordinator round-50 hand run: 74/138 — the home steady count sits in the 127-138 band across runs; the face count is exact).
- Engine work via the named script .scratch/AC-0469-gates/run_stage_f_gates.sh (gate_run.py g0,genhash,residency).

## Coordinator triage — stage F: the answer is "not one coordinate space", and that is worth knowing before writing code (round 51)
- I EXPECTED THIS STAGE TO SAY "merge the two residency models". IT DOES NOT, AND IT IS RIGHT. The band predicate is a TAXICAB distance over FLAT INTEGER chunk deltas around `_rec_player_wx/wz` (world.gd:6894-6898, 3416-3417). A player standing on a chart face has NO position in that space of its own: `_face_player_flat` clamps them to the patch (15191), and extended-flat is INF on the far hemisphere (sphere_math.gd:630-631), which is exactly what the is_inf sentinel at 15171 is for. So the planet frame contains both player and chunks but is NOT the band metric, and a naive merge would silently band around a clamped point.
- TWO REAL OPTIONS, and the choice belongs to the user or a later stage: (A) merge on extended-flat, keeping two special cases alive; (B) move the band radii into angular units, which is a change to the band MODEL rather than to the code that consults it. Option B is the honest "no home" end state; Option A is the smaller step that leaves a residue. Recording both rather than picking one silently inside an implementation stage.
- THE INVENTORY IS THE USEFUL HALF: three face-lane behaviours are GENUINELY face-specific and must survive the merge as rules — the edge-normal gate (15296-15302), the per-face edge-band rows (15257), and the along-edge half-window with its mirror chart (15270-15285, 15324-15333) — while only two are SPLIT ARTEFACTS that can die: the 12 ms budgeted pass (15234) and the separate `_face_order`/`_face_evict_last` bookkeeping (14809/14826). Nothing is subsumed by the bands. A merge written on the assumption that bands subsume the face window would have deleted three rules that exist for geometric reasons.
- THE FIRST FAILURE IS NAMED, which is what makes the staging credible: losing the 12 ms budget stalls the edge-crossing frame, because the home crossing sweep (11972, 6054) is one-shot, synchronous, flat-keyed and UNBUDGETED. Its correctness twin is a crossing-row void if the sync fallback is ever dropped. The arms that catch both are already standing: boundary p95/p50 and planetwalk 25/26 with its negative control.
- THE STAGED ORDER IS FOUR STEPS, each playable: (1) one `resident_of(key)` predicate with ZERO behaviour change; (2) one resident list and one sweep; (3) creation through the unified per-frame pass with the three (b) rules as sub-rules, gated on boundary p95 <= 38 plus planetwalk and negctrl; (4) delete `_face_stream` and its constants under the full stage-E gate set.
- TREE PROVABLY UNTOUCHED, as this stage required: genhash 25/25 byte-identical to the stage-E reference, and residency leak false / STABLE at face 74 with home 127 in this run (the round-50 hand run read 74/138 — same plateau band, face count exact).
- WHERE THE MIGRATION ACTUALLY STANDS: one grid, one placement, one key shape, one node path, one landing, one queue, one drain, one travel gate, one window, cubic 1 m blocks, complete far tier, correct prestream, green twelve-chart lap, bounded residency — and now a designed, staged, failure-aware plan for the final merge, which remains genuinely open and is the largest single piece left.

## RUN — Fri Oct 23 05:38:21 EDT 2026 — AC-0469 stage G1
- LANDED (G1): world.gd gains ONE predicate `resident_of(face, cx, cz) -> bool` after band_of (~6918): face<=1 -> in_stream_set(cx-last_pcx, cz-last_pcz) (the recenter center; pcx/pcz at the call sites ARE last_pcx/last_pcz after 12030 — pcx is a LOCAL of the recenter fn, last_pcx is the global the drain fills use); face>=2 -> _face_chunk_min_dist <= _stream_window(sim_dist, FACE_STREAM_EVICT_MARGIN).y with p=_face_player_flat(). Both call lanes converted: (1) outside-set rebuild (old 12112), (2) the recenter sweep's current-center membership (old 12184); (3) the face windowed-eviction test (old 15378, now `not resident_of`). OLD-CENTER hysteresis tests (12187/12227/12289, odx/odz) left on in_stream_set directly — a different question (previous center), not "right now". Temporary AWECRAFT_G1_CHECK cross-check (old vs new per site, push_error + G1RCHECK counts) in place for the check run; to be deleted before the final gates. No radius, margin, cadence or metric moved.
- GATES (G1, all MATCH, named scripts — no inline godot command lines):
  identity-check run (AWECRAFT_G1_CHECK=1, run_stage_g1_check.sh; g0-r25/
  residency-r10/planetwalk-r17, all rc=0 SCRIPT/SHADER 0/0): 28,381 old-vs-
  new comparisons (sweep 3,646+19,988; face-evict 327+4,420), ZERO
  mismatches; outside-set site never fires in the arms (empty chunks dict
  at first recenter, no radius change) — its identity is the one-line diff
  (D22). Temporary check then DELETED; final set on the clean tree
  (run_stage_g1_gates.sh):
  - g0-r26: rc=0, SCRIPT/SHADER 0/0.
  - genhash-r12: rc=0, 25/25 slabs; GENHASH lines diff EMPTY vs the
    stage-E reference (genhash-r9) and the stage-F reference (genhash-
    r11) — the world is byte-identical.
  - residency-r11: rc=0, leak=false, ok=true, steady face 74 / home 138
    FLAT over 6 samples, converged=true, keys_same=true, verdict STABLE,
    face evictions 0 — the stage-F plateau (face exact; home in the
    127-138 run band).
  - planetwalk-r18: rc=0, 25/26 pairs covered with mesh_built AND
    body_present at every destination (lap_0-1 = home_pair_midline, the
    documented uncovered pair, C3).
  - save-r5 / load-r5: rc=0, ok=true both; load simband_ms 6812 (~6.6 s
    class).
  No A/B decision forced: the predicate dispatches on the space (home
  taxicab vs extended-flat Euclidean) and each branch is the lane's own
  rule verbatim — no metric had to move. Single predicate = step 1 done;
  steps 2-4 of the stage-F order follow (step 2+ needs the A/B choice).
  Results page re-rendered (summary-g1.json = the two gate runs merged;
  the live summary.json is gate_run's per-invocation output, so the page
  points at the merge).

## Coordinator triage — stage G1: one residency predicate, and the identity was PROVED not assumed (round 52)
- VERIFIED BY MY OWN RUN: leak false / stable true at face 74 / home 127, converged in 497 ms, g0 0/0 and genhash 25/25 — the same plateau as stages E and F, so the refactor moved nothing.
- THE IDENTITY PROOF IS THE PART THAT MAKES THIS TRUSTWORTHY: the builder ran a temporary env-gated runtime cross-check (since deleted) comparing the new predicate against the old inline test on **28,381 comparisons — sweep 3,646 + 19,988, face-evict 327 + 4,420 — with ZERO mismatches**, and noted that the one never-fired site was verified by a one-line expression diff instead. That is a far stronger statement than "the gates are green", because green gates cannot distinguish "the refactor is correct" from "the refactor is never consulted on the interesting path".
- THE PREDICATE DISPATCHES, AND THAT IS CORRECT RATHER THAN A FAILURE: `resident_of(face, cx, cz)` answers by space — faces 0/1 through the home taxicab `in_stream_set` around the recenter centre, faces 2+ through the extended-flat `_face_chunk_min_dist` against the ONE window helper, with the is_inf sentinel still meaning resident. Stage F established the two lanes have no common metric, so dispatch preserves both answers without inventing one.
- THE A/B DECISION WAS NOT FORCED, which was the point of choosing this step first: the refactor needed no metric change, so the open question (extended-flat vs angular bands) is still open and still belongs to the user or a later stage rather than having been decided by a builder in passing.
- ONE DISTINCTION WORTH KEEPING: three "right now" sites were converted (the recenter sweep's membership, the outside-set rebuild, the face windowed-eviction test), but the old-centre HYSTERESIS queries deliberately stayed on `in_stream_set` — that is a different question (r+1 candidate / r+2+ free) and merging it would have silently changed the eviction hysteresis.
- STATE: step 1 of the four-step residency merge is landed and proved. Steps 2-4 (one resident list and one sweep; creation through the unified per-frame pass with the three geometric rules as sub-rules; deleting `_face_stream` and its constants) remain, and step 3 is where the budget-stall failure stage F named becomes live.

## RUN — Fri Oct 23 06:16:33 EDT 2026 — AC-0469 stage G2 (one resident list + one sweep)
- LANDED (G2): world.gd — ONE resident list + ONE sweep, two pacing policies over it.
  (1) `_face_order` is renamed `_resident_order` and now holds the keys of ALL
  resident chunks (home + face), FIFO by insertion: home appends in
  `_make_chunk_node` (the only home insert), face appends in `_ensure_face_chunk`
  (the only face insert); home erases in `_free_chunk_key` (the only home free,
  including the deferred drain), face erases in `_face_free_chunk`; the sweep's
  null-cleanup is the backstop. The list mirrors `chunks` membership.
  (2) New `_resident_sweep(lane, p, pcx, pcz, home_win)` after `_stream_window`
  (world.gd ~12029): one loop over the list, one `resident_of`, both lanes'
  removals through it. LANE RES_SWEEP_HOME (called from recenter after the walk
  + `_strip_candidate_builds`): the r+1/r+2+ hysteresis (two_out / cand_since,
  the expression VERBATIM from the old walk's else branch) over the list, then
  the AC-0257 split unchanged — travel gate (_home_evict_last, 16 m), first
  stream_ho_cap freed now, the rest identity-guarded into _deferred_free.
  LANE RES_SWEEP_FACE (called from _face_stream under the same travel gate as
  before): immediate uncapped windowed free via resident_of (verbatim from the
  old _face_stream loop). PACING stayed PER-LANE (two policies over one list):
  home's hysteresis counts RECENTER EVENTS (a per-frame cadence would change
  the r+1/r+2+ semantics) and its cap-defer is the measured AC-0257 rim
  protection; face's is the immediate uncapped windowed free — one policy
  cannot express both without a re-measure (step 3).
  (3) The recenter walk's else branch keeps the exit one-shot only
  (_stream_outside + _enter_candidate — its cand_since-reset-first order is
  preserved, the sweep runs after the walk). Set-identity argument (in-code
  comment): every two_out resident and every live cand_since>0 entry is visited
  by the walk (the AC-0350 invariant — the boundary rings + the outside set
  reach every outside-resident column), so the list pass scores exactly the
  walk's old set.
  (4) _face_land's FIFO cap now counts FACE chunks and evicts the OLDEST FACE
  key (the interleaved home keys do not move the cap's victim);
  _face_rebake_boundary skips home keys. No radius, margin, gate, budget or
  hysteresis value moved. 12 targeted edits, all in godot/world/world.gd.

## GATES — AC-0469 stage G2 (final, clean tree; logs under .scratch/AC-0469-gates/)
- (a) g0-r30: rc=0, SCRIPT/SHADER 0/0. genhash-r14: rc=0, 25/25 — BYTE-IDENTICAL to the G1 reference (genhash-r12, diff empty). residency-r17 (final clean run; r13/r14 the same clean tree): rc=0, leak=FALSE, stable=TRUE, face 74 EXACT, home 92 (r13/r14: 93), converge 497 ms, keys_same=true, verdict STABLE, face evictions 0, home evictions 220 (G1: 219). HOME STEADY 92-93 vs the G1-era 127-138 = the D28 FINDING (drain-data-lane leading-arc stubs created out-of-set — a latent leak of hidden candidates the old band-bounded walk never visited and never freed; the unified list pass evicts them per the lane's own 2-recenter hysteresis policy). face EXACT, leak/stable/converge all match; pacing verified unchanged by (b). planetwalk-r19: rc=0, ok=true, 25/26 lap coverage with the documented lap_0-1 (home_pair_midline) waiver; ALL 25 walked crossings have mesh_built AND body_present at the destination AND cross_mesh_built AND cross_body_present at the crossing frame; negctrl inert (ran=false, saw_unbuilt=false).
- (b) boundary-r3 (the single boundary probe, clean tree): rc=0, ok=true, marker_ok=true, remesh_ok=true, radius 4, crossing_n=38, crossing_frame p50 21 / p95 38 vs the G1 reference 30/38 — p95 EXACT (the plan's "a p95 REGRESSION IS A FAILURE" — none; p50 is LOWER). The AC-0257 capped/deferred free survived the unification: a full render-circle crossing at r4 stalls no more than before.
- (c) save-r6: rc=0, ok=true (43 s). load-r6: rc=0, ok=true, simband_ms=6603 (G1: 6812 — same ~6.6 s class, the window is unchanged).
- Every official arm ran on the clean tree (the AWECRAFT_G2CHECK diagnostic — per-recenter G2REC/G2UNVIS scored-vs-walk-visited lines and G2NEW creation lines that pinned the D28 mechanism — was removed before the final g0+r17 confirmation run; its runs are r15/r16 and are NOT part of the official set).
- Deviations D24-D28 in AC-0469-deviations.txt. Results page re-rendered from summary-g2.json.

## Coordinator triage — stage G2: one list, and the unification EXPOSED A LATENT LEAK the old walk was hiding (round 53)
- WHAT LANDED: ONE resident list `_resident_order` (FIFO, both lanes) and ONE sweep `_resident_sweep` consulting the shared `resident_of`. Pacing deliberately stayed per-lane - home keeps its recenter-cadence hysteresis and the AC-0257 cap-defer (the measured rim protection), face keeps its per-frame travel-gated free - because the plan's §7 risk said unifying the LIST is safe while unifying the PACING without measuring would be a regression. One list, one loop, two pacing policies; that is the honest landing rather than a forced merge.
- GATES ALL MATCH OR IMPROVE: genhash 25/25 byte-identical to G1, residency leak false / STABLE, face 74 exact, converge 497 ms, planetwalk 25/26 with mesh and body at every destination and crossing frame, and boundary p50 **21** / p95 **38** against the reference ~30/38 - p95 exact (the number this stage could have broken), p50 lower.
- THE FINDING, and it is worth more than the refactor: home steady residency reads **92-93 where G1 read 127-138**. The builder pinned it with a per-recenter trace rather than shrugging at variance: the drain data lane stubs a leading arc of out-of-set cells (per-axis rr+1 bound, in_set=0 at birth, taxi 6-7 ahead of travel) that NEVER EXITED the set, so the old bounded walk never visited them and never freed them - with the candidate counter frozen at 0, i.e. invisible to the sweep. That is a LATENT LEAK in the pre-G2 code, and the ~45-chunk difference is exactly its size.
- SO THE NUMBER MOVED BECAUSE THE BUG WAS FIXED, not because behaviour drifted: those stubs are data-only (written to disk when freed), the eviction is what the 2-recenter policy says should happen, and nothing is lost. Decision: ACCEPT. Reverting to the old count would mean restoring a leak to make a number match, which is the opposite of what this migration is for.
- HONEST CAVEAT ON THE ACCEPT: I am accepting on the builder's trace and the gates, and the trace is specific enough to be wrong in a checkable way (the in_set=0-at-birth / taxi 6-7 claim). If anyone later finds those stubs were holding something, this is the note that says why the count changed.
- STATE: three of four merge steps are done (predicate proved on 28,381 comparisons; one list and one sweep landed). Step 3 - creation through the unified per-frame pass with the three geometric rules as sub-rules - is where stage F's budget-stall failure becomes live, and step 4 deletes `_face_stream` and its constants.

## RUN — AC-0469 (stage G3) — $(date)
Step 3 of the 4-step residency merge: ONE creation pass that consults the same resident_of membership and the same window as the sweep, the three geometric face rules as sub-rules, NO edge-crossing frame stall. Gates: g0 first, then g0,boundary (p95 <= 38 vs G2 21/38), planetwalk,residency,seamcensus, genhash 25/25, save,load (~6.6 s class). Engine work via named scripts only (the pgrep -f "[g]odot" trap).

## LANDED — AC-0469 stage G3 (one creation pass; no code touched outside godot/world/world.gd)
- godot/world/world.gd (5 targeted edits):
  (1) `_create_pass(p, pcx, pcz, part)` — the ONE creation pass (after _chunks_across):
      CREATE_PART_HOME = the 5x5 spawn pre-warm VERBATIM from recenter(), now with the
      membership through resident_of's home branch (bit-identical dispatch: pcx/pcz ARE
      last_pcx/last_pcz at the call site; G1's 28,381-comparison identity proves the
      dispatch class) — one-shot, synchronous, flat-keyed, UNBUDGETED (no time check —
      that IS the stall). CREATE_PART_FACE = the face band, ALWAYS inside
      FACE_STREAM_BUDGET_MS from every call site (the budget checks are verbatim in the
      ensure loops). Pacing explicit in the part selector AND the body (plan §5.1).
  (2) The three geometric rules extracted as sub-rules, verbatim expressions + original
      comments retained, each individually checkable: `_face_edge_dist` (1: the
      edge-normal gate, AC-0309 r30), `_face_band_rows` (2: FULL in-band axis, rows from
      the ONE _chunks_across helper, cap the per-face edge-axis chunk count),
      `_face_edge_chart` (3: along-edge half-window + mirror chart — the AC-0470 fix as
      ONE boolean raw_idx = face in {4,6,8,10}, not re-derived; z faces index the halved
      axis' 3,141-cell chart; +-1 chunk padding; returns [cc0,cc1,edge_last], [-1,-1,-1]
      when hi<=lo).
  (3) recenter(): the 5x5 pre-warm loop replaced in-place by
      `_create_pass(_face_player_flat(), pcx, pcz, CREATE_PART_HOME)` (same position —
      before RECPROBE + the crossing-ring append; the ring `us` still excludes the face
      part, the crossing-frame metric unchanged).
  (4) `_face_stream()` = thin face-side entry: `_create_pass(p, 0, 0, CREATE_PART_FACE)`
      + the G2 travel-gated RES_SWEEP_FACE tail verbatim (both old call sites, 6125 /
      recenter, unchanged).
  (5) Same work, same order: creation set identical (band + pre-warm unchanged except
      the proven-identical predicate dispatch); creation order identical (pre-warm pdx/pdz;
      faces 4..11, r edge-inward, cc0..cc1). Only pure per-face computation order moved
      (rows/chart/gate) — no side effects, no budget spend.
  - NOT touched: sync fallback (get_block_key is_inf path), travel gate, radii/margins,
    hysteresis, generation, mesher, keys, saves, light, warp, harness.gd.

## GATES — AC-0469 stage G3 (all green; logs under .scratch/AC-0469-gates/)
- (a) NO STALL (boundary-r4, the stage's reason for existing): rc=0, ok=true,
  marker_ok/remesh_ok true, crossing_n=32, crossing_frame p50 14 / p95 37 / max 44
  ms vs the G2 reference 21/38 (n=38, max 47). **p95 37 <= 38 — NO stall** (1 ms
  UNDER G2; p50 14 is the low end of this tree's recent single-run band 14-31).
  crossing_burst (the synchronous sweep wall, the ring `us`) p50 4.1 / p95 9.1 /
  max 15.1 — the home one-shot sits inside the ring exactly as before.
- (b) planetwalk-r20: rc=0, ok=true, 25/26 pairs covered with mesh_built AND
  body_present at the destination AND cross_mesh_built AND cross_body_present at
  the crossing frame (no crossing-row void); uncovered = lap_0-1
  home_pair_midline (the documented stage-C waiver — the home-pair keying
  collapse, not a boundary); faces_stood_on 0,2-11. residency-r18: rc=0,
  leak=FALSE, stable=TRUE, verdict STABLE, converged 497 ms, keys_same=true,
  face 74 EXACT / home 93 (the G2 plateau 92-93), face evictions 0. seamcensus-r4:
  rc=0, ok=true, rows_ok=393,216 (clean).
- (c) genhash-r15: rc=0, 25/25 GENHASH lines BYTE-IDENTICAL to the G2 reference
  (genhash-r14; diff empty) — the world is bit-identical under the pass (the arm
  prints hashes with no RESULT line; r15's log is structurally identical to the
  reference's 32-line log).
- (d) save-r7: rc=0, ok=true. load-r9: rc=0, ok=true, simband_ms 6945
  (the ~6.6 s class — this arm's run band on the tree: 6670/6628/6812/6603/6945
  across stages A/B/G1/G2/G3; the pre-warm is identical work, the window is
  unchanged). Note: the combined run's load-r7 was killed mid-boot by the
  executor's 600 s command cap (load is a ~13 min wall arm) — load-r9 re-ran
  alone (in a background job); every other arm in the combined run completed.
- Deviations D29-D30 (AC-0469-deviations.txt): the stage-3 decision (both
  pacings expressible — neither moved; two paced call sites share one
  membership + one rule set), the membership/window consultation, the three
  sub-rules, same-work-same-order, and the gate numbers.
- Results page re-rendered from summary-g3.json (the per-arm walls for the
  combined-run arms are file-mtime deltas; load/g0/boundary are gate_run-reported).

## Coordinator triage — stage G3: one creation pass, no stall (round 54)
- VERIFIED BY MY OWN RUN, because "no stall" is exactly the claim this stage could fake: boundary p50 26 / p95 **38** / max 38, n=36, ok true with marker_ok and remesh_ok. p95 at or below the 38 reference, so the failure stage F named in advance did not happen.
- WHAT LANDED IS SMALLER THAN THE PLAN'S AMBITION AND BETTER FOR IT: one entry point `_create_pass(p, pcx, pcz, part)` with two parts — the home 5x5 spawn pre-warm (verbatim from recenter, now asking `resident_of`'s home branch, whose dispatch is bit-identical because pcx/pcz ARE last_pcx/last_pcz) and the face band (same `_stream_window` value the sweep's predicate uses). The THREE GEOMETRIC RULES were extracted as named sub-rule helpers with their original comments retained (`_face_edge_dist`, `_face_band_rows`, `_face_edge_chart`), and the AC-0470 half-split survives as the ONE boolean `raw_idx = face in {4,6,8,10}` precisely so nobody re-derives it.
- BOTH PACINGS WERE EXPRESSIBLE AND NEITHER MOVED, which is the §8 acceptable landing rather than the forced merge: home stays one-shot, synchronous, flat-keyed and unbudgeted at recenter; face work stays inside the 12 ms budget from every call site. Two paced call sites now share one membership, one window and one rule set - that is the unification that was safe, and the pacing difference that was not safe to erase was kept.
- NOTHING ELSE MOVED: genhash 25/25 byte-identical to G2, residency leak false / stable at face 74 / home 93 (the G2 plateau, so the latent-leak fix from last round stayed fixed), planetwalk 25/26 with mesh and body at every destination, simband in the normal class.
- THE HONEST NOTE ON THE LATENCY: p50 has now read 21 (G2) and 26 (mine) for the same code, and 14 in the builder's run - this arm's p50 wanders by more than the change it is being asked to detect, which is why p95 (stable at 37-38 across G2, G3 and this run) is the number I judge the stage on. Recorded so nobody later reads a p50 delta as a regression or an improvement.
- STATE: three of four merge steps done, and the last one is now a deletion: `_face_stream` is a thin face-side entry (pass + travel-gated sweep), so G4 removes the remaining constants and any dead path.

## RUN — 2026-10-23 13:13 UTC — AC-0469 (stage G4: deletion of what G1-G3 made dead)
- Deletion-only stage. Contract: plan.html §4.1-4.3. Gates: g0,genhash,residency,planetwalk,boundary (p95 <= 38) + save,load (simband ~6.6s class). Deletion list may legitimately be empty.

## LANDED — AC-0469 stage G4
- DELETION LIST: EMPTY (plan §7's legitimate outcome). G1-G3 consumed the
  dead code: _face_order is already gone (G2), the face sweep loop is
  _resident_sweep's face branch (G2), the creation code is _create_pass
  (G3). Every candidate has a live reference outside its own definition —
  full per-candidate counts in the deviations (D31, count script
  .scratch/AC-0469-gates/g4_counts.py). Must-not-delete list intact:
  FACE_STREAM_BUDGET_MS (def 15427 + 4 checks), sync get_block_key
  fallback, travel gate (_evict_sweep_due + _face_evict_last at 15545),
  the three sub-rule helpers, _chunks_across, _stream_window, the AC-0257
  deferred-free machinery — all still referenced.
- CHANGED (comments/docs only, 0 executable lines — git diff is the
  proof, see deviations D33/D34):
  (1) godot/world/world.gd resident_of header: "exactly the _face_stream
      window test" -> points at the pre-G1 inline test it was (4 comment
      lines).
  (2) godot/ARCHITECTURE.md §6: face-lane bullet rewritten — residency is
      ONE model (one list / predicate / sweep / travel gate) with TWO
      pacing policies (home recenter cadence + AC-0257 cap-defer; face
      per-frame travel-gated windowed free), _face_stream the FACE side
      of the one creation pass; AC-0350 bullet: one sentence on the free
      logic moving into _resident_sweep's home pass.
- FINDING (deviation D32): the six harness.gd world._face_order reads sit
  in three stale measurement arms (_warpcensus_test 36204/36206/36234/
  36255, _ac0433probe_test 37449, _voxelcost_test 39051) — none in this
  gate set; harness.gd fenced, so they stay; follow-up owed to re-point
  them at _resident_order (same class as D3's stale 1024 arms).
- Gates: g0/genhash/residency/planetwalk/boundary via
  .scratch/AC-0469-gates/run_stage_g4_main.sh (all ok); save,load via
  run_stage_g4_save_load.sh. See the GATES entry below.

## GATES — AC-0469 stage G4 (logs under .scratch/AC-0469-gates/)
- (a) g0-r33: rc=0, SCRIPT/SHADER 0/0.
- (b) genhash-r16: rc=0, 25/25 GENHASH lines BYTE-IDENTICAL to the G3
    reference (genhash-r15; diff empty) — the world is bit-identical
    under the (comments-only) change.
- (c) residency-r19: rc=0, leak=FALSE, stable=TRUE, converged TRUE (497
    ms), keys_same=true, verdict STABLE — steady face 74 EXACT / home 93
    (the G3 plateau), face evictions 0, 6 flat samples.
- (d) planetwalk-r21: rc=0, ok=true, 25/26 pairs covered with
    mesh_built AND body_present at the destination AND cross_mesh_built
    AND cross_body_present at the crossing frame; uncovered = lap_0-1
    home_pair_midline (the documented stage-C waiver); faces_stood_on
    0,2-11.
- (e) boundary-r6: rc=0, ok=true, marker_ok/remesh_ok true —
    crossing_frame p50 26 / p95 **39** / max 39, n=40. **p95 ONE MS OVER
    the plan's 38 line (deviation D34)** — the stage's world.gd change is
    four COMMENT lines (git diff: no executable line), so this is the
    arm's single-run wander (the coordinator's G3 triage documented the
    same-code band: p50 14/21/26, p95 37-38). One-shot boundary rule: no
    re-run by the builder; the heavy boundary is the coordinator's gate
    set — a coordinator re-run is the arbiter of the 38 line.
- (f) save-r8: rc=0, ok=true (blocks 6/6, pos ok). load-r10: rc=0,
    ok=true, simband_ms 6835 (the ~6.6 s class — this arm's run band on
    the tree: 6670/6628/6812/6603/6945/6835 across stages).

## Coordinator triage — G4: an empty deletion list, and a threshold I set too tight (round 55)
- THE DELETION LIST IS EMPTY, WHICH IS THE PLAN'S OWN SANCTIONED OUTCOME: G1-G3 had already consumed the dead code, and the builder proved it per candidate with reference counts (D31) rather than manufacturing deletions to look productive. The must-not-delete list is intact — FACE_STREAM_BUDGET_MS 11 references, _face_evict_last 5, the three sub-rule helpers 3/3/4, _chunks_across 5, _stream_window 7, the sync fallback and the AC-0257 machinery all still referenced. What did change is documentation only: the resident_of header no longer points at a gone window test, and ARCHITECTURE.md §6 now says residency is ONE model with TWO pacing policies.
- THE BOUNDARY NUMBER, AND I AM THE ARBITER THE BUILDER ASKED FOR: it reported p95 39, one over my ≤38 line, with a comments-only diff, and correctly DECLINED to re-run until green (that would have been the re-run-until-it-passes trap). I re-ran it: **p95 40**. So the sequence across effectively identical code is 37, 38, 39, 40 — and the honest conclusion is that MY THRESHOLD WAS OVER-FITTED to two samples, not that G4 regressed anything. A comments-only change cannot move a frame time; the git diff proving zero executable change is the stronger evidence, and it is the one I should have weighted first.
- WHAT I WILL NOT DO IS QUIETLY WIDEN THE LINE: instead, the record now says the arm's real spread on this code is ~37-40 at n=36-40, so any future stage judged on p95 needs either more samples or a different statistic before a 1-2 ms delta is treated as signal. The stage is accepted on the diff, not on a threshold I picked from too few runs.
- ONE FOLLOW-UP OWED (D32): six stale `_face_order` reads remain in three fenced harness arms — arms, not product code, but they reference a list G2 deleted, so they are dead references that will confuse the next reader. Filed as work for the harness-tidy pass rather than done here.
- STATE: the residency merge is CLOSED as four stages — predicate (identity-proved), one list and one sweep (which exposed and fixed a latent leak), one creation pass with the three geometric rules (no stall), and a deletion pass that found nothing left to delete and a documentation sync that found one over-tight threshold. AC-0469's remaining item is the AC-0463 lane question, which is paused on a product decision the user has already partly answered.
