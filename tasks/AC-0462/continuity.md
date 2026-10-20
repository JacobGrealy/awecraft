# AC-0462 — continuity journal (append-only)

## RUN — Tue Oct 20 15:33:53 EDT 2026 — AC-0462
Started. Plan read (tasks/AC-0462/plan.html). No prior entries; fresh run.
Anchors located: warpcensus dispatch harness.gd:342, _warpcensus_test :35929, interact arm ~6355.

## LANDED — Tue Oct 20 17:20:00 EDT 2026
- godot/scenes/harness.gd: ONE new arm `_faceedit_test` (dispatch branch after the warpcensus
  branch, BATTSKIP by the battery's fallback match — no main.gd entry, the neighbour arms don't
  need it) + helper `_faceedit_scan_aim` (the interact arm's aim/verify, bounded 12x7 look
  sweep). Stand = the warpcensus shape PAST the +x edge (flat x = hw + 8, z = 0); asserts the
  anchor face > 1 (fails loudly `anchor_on_home_pair`); data-driven lift 2.5 m above the game's
  own surface_top_key; candidates around the anchor column (domain-guarded), each set to a known
  breakable (id 2) before a REAL aim via the player's own aim_hit, verified hit.cell == the
  candidate. BEFORE any edit it measures aim_point (camera + aim_dir * t/|M(aim_dir)|),
  aim_cell (the DDA cell), aim_cell_key (world.key_for_sphere_pos), and surface_error_m (aim
  point -> nearest placed surface of the aimed cell's own unit box, six faces x 4x4 samples, the
  chunk node's LIVE transform applied — under the warp the node is identity and the box runs
  through _warp_cell_point, the same construction the mesh uses; flag off the node transform IS
  the legacy placement). Then break (wall-clock mine wait, 3 s cap, assert air) and place (re-aim
  until cell + normal == the hole, wood back in the SAME cell, assert id 2). RESULT: ok, face,
  frames, stand, aim_point, aim_cell, aim_cell_key, aim_id, surface_error_m, break_ok, place_ok,
  place_cell, target_chunk, target_mesh_built, warp, fails, diag (frame diagnostics incl. the
  game's own _sim_cell_center on the aimed cell), ms.
- tasks/harness_data.yaml: the faceedit row (tests/result_fields/envs/wall/notes incl. the gate-
  run findings) -> harness_doc.py --render + --check green. godot/HARNESS.md regenerated.
- NO product changes: warp, placement, transforms, streaming, keys, saves, SphereMath, docs all
  untouched. Read-only anchors used: player.gd 2776/2786/2810/2891/3030/3454, world.gd
  15225/15398, chunk.gd 1737/1817/1921, sphere_math.gd 90/110.

## GATES + OUTCOME — Tue Oct 20 17:20:00 EDT 2026
- Light set g0,smoke,ac0423probe,faceedit via tasks/scripts/gate_run.py, both flag states,
  one godot at a time, logs .scratch/AC-0462-gates/ (saved copies .scratch/AC-0462/*.final):
  - WARP ON (set rev 2; faceedit faceedit-r7.log): every arm rc=0, SCRIPT=0, SHADER=0, ok=true
    (g0 3s, player 16s sprint_ok=true, interact 8s place_ok=false [standing], light 9s, fluids
    12s sea_stable=true, genhash 3s, ac0423probe 8-9s ok=true). faceedit (15 s, ms=13425):
    ok=true, face=5, frames=240, stand [2918.49,-1091.94,-1.44], aim_cell [0,136,7],
    aim_cell_key 5:281:1023, aim_point [2931.005,-1080.211,-1.307], aim_id=2, break_ok=true,
    place_ok=true, place_cell [0,136,7], target_chunk 5:0:0, target_mesh_built=true,
    warp=1, chunk_identity=true, ocell [0.93,139.49,7.93], anchor_cc [63,63],
    surface_error_m=5841.189 (target <= 1.5 m — NOT MET), eye_to_hit_cell_m=6274.25,
    hit_cell_world [7311.88,-5570.99,-45.96].
  - WARP OFF (set rev 3; faceedit faceedit-r8.log): same all-green. faceedit (15 s, ms=12348):
    face=5, stand [2912.87,-1097.42,-2.14], aim_cell [0,136,7], aim_id=2, break_ok=true,
    place_ok=true, warp=0, chunk_identity=false, chunk_origin [2346.69,-6233.86,-2346.43],
    surface_error_m=5840.47, eye_to_hit_cell_m=6274.16.
- harness_doc.py --check: in sync (modes, standing-values).
- OUTCOME — the gate expectations and what the numbers say (plan §6: a failed expectation is a
  FINDING about the shipped default; reported, nothing adjusted):
  1. face > 1: MET (face 5, both states; the home-pair guard never tripped in 7/7 faceedit
     result runs — the 8th run was the builder's own parse-error revision, no RESULT).
     break_ok AND place_ok: MET (both states — the face-routed edit pipeline, AC-0309 C5, runs
     clean end-to-end and writes face data).
  2. surface_error_m vs the 1.5 m target: NOT MET — 5841.189 m (warp on) / 5840.47 m (warp off).
     The cause is a STRUCTURAL coordinate-space mismatch in the shipped face aim, not the
     placement residual: the DDA origin (player.gd _flat_ray face branch) is the player's offset
     in the ANCHOR CHUNK's local cell frame (measured ocell ~ (0.94, 139.5, 7.76) for a player
     whose anchor chunk is (63,63) — the (u~1, v~1) corner of face 5), but the block callback
     feeds those local indices to world.get_block_key, whose contract is ABSOLUTE face-grid
     columns 0..1023 (_ensure_face_chunk floors by 16). The ray therefore walks local cells
     (0,136,7)-ish while the data it reads is the CHART CORNER CHUNK (0,0) — the OPPOSITE corner
     of the face. The game's OWN _sim_cell_center (the drop spawn's cell->world map) puts the
     aimed cell 6274.25 m from the eye (warp on) / 6274.16 m (warp off); the arm's placed-
     surface model puts it 5841.189 / 5840.47 m from the aim point. A player-facing face edit
     does NOT land on the block the player's ray points at — only a player standing in the
     chart's corner chunk (0,0) region would see aim and data agree.
  3. Flag comparison: warp OFF (5840.47) is NOT larger than warp ON (5841.189) — 0.719 m SMALLER,
     inside the ~7 m run-to-run noise floor (spawn variation; deviation 6). The measurement
     CANNOT DISCRIMINATE the warp flag here, for a reason now understood: the frame mismatch
     (~5.8 km) dwarfs the placement residual (the cm-m scale the flag actually toggles — visible
     only in the node transform: identity under the warp vs the LSQ chunk_origin (2346.69,
     -6233.86, -2346.43) with the flag off).
  4. Secondary finding (reported, not fixed — keys are read-only per plan §3):
     world.key_for_sphere_pos derives (u,v) from the UN-shifted position while player_anchor
     shifts by (0, R, 0) into the planet frame before world_to_face — the two disagree on u for
     the same point (281 vs ~1009: diag.player_key 5:281:102x vs diag.anchor_cc [63,63]). A
     second, independent frame bug in the key API.
- Resume point: none — the ticket's deliverables are complete (arm, yaml+doc, gates, findings,
  this journal, AC-0462-deviations.txt, AC-0462-results.html). A follow-up ticket (aim frame
  fix) is a COORDINATOR decision; the builder made no product change per plan §6/§8.

## Coordinator triage — the faceedit arm (round 17)
- WHAT THE ARM MEASURED: with the player on face 5, break_ok/place_ok both true, but the aimed cell resolves to a cell whose surface is ~5,841 m from the aim point. The SAME numbers appear with the warp ON and OFF (5,841.19 vs 5,840.47 — the 0.7 m difference is inside the arm's own spawn-variation noise). So whatever this is, it is NOT caused by the warp, and the arm cannot discriminate between the two placements.
- I DID NOT ACCEPT THE "PRE-EXISTING AIM BUG" HEADLINE. Reading the code before reporting it: `get_block_key` (world.gd:15398) treats `colx` as an ABSOLUTE face column (`_ensure_face_chunk` does floor(colx/16), and `face_local_x(face, colx, c.cx)` needs the absolute index), while `player_anchor` (world.gd:15246-15251) returns `origin = B.origin`, i.e. the ANCHOR CHUNK's own origin — so the anchor-frame cell coordinates the player computes at player.gd:3232-3239 are chunk-LOCAL [0,16). If the aim/DDA (`hit.cell` -> `_sim_get_block` -> `get_block_key`) actually hands those local coordinates to an absolute-indexed API, every face edit lands in chunk (0,0) — which is precisely the ~5.8 km this arm measured (chunk 0,0 of face 5 is the chart corner).
- WHY THAT IS STILL UNPROVEN: I have not yet found where `hit.cell` is produced and whether it is absolute or anchor-local. Two very different conclusions are live — (a) a real, long-standing bug in face editing that predates this migration, or (b) the arm mixing frames when it samples the aim, exactly the class of error that produced the AC-0460 "death screen" A/B and the AC-0449 blue/blur confusion. Reporting (a) without locating `hit.cell` would repeat that mistake.
- STATE: the arm is kept (it is a good instrument) and the ticket STAYS OPEN. The next step is one focused question — locate the producer of `hit.cell` and state the frame — not a placement change. The warp is not implicated either way.

## THE ANSWER, round 18 — it is a real shipped bug, proven by code trace
- THE QUESTION WAS: is the ~5.8 km face-edit error a real bug, or my arm sampling in the wrong frame? ANSWER: a real bug, and the arm was right.
- THE TRACE (three reads, no inference):
  1. `player._flat_ray()` (player.gd:2810-2830), face branch, builds the ray in the ANCHOR CHUNK's local frame: `o = (camera.global_position - _anchor["origin"])` projected onto the anchor basis and divided by the cell scale, and `d` the same way. `_anchor["origin"]` is `B.origin` from `world.player_anchor` (world.gd:15251) — the ANCHOR CHUNK's own transform origin, so `o` is chunk-local cell coordinates in [0,16).
  2. `player.aim_hit` (player.gd:2796-2798) runs `VoxelMath.raycast_blocks(fr.o, fr.d, reach, cb)` with `cb(x, y, z) = Game.world.get_block_key(face, x, z, y)` — so the DDA's chunk-LOCAL coordinates are handed straight to the block API.
  3. `world.get_block_key` (world.gd:15398-15408) treats `colx` as an ABSOLUTE face column: `_ensure_face_chunk(face, colx, colz)` does `ccx = floor(colx/16)` and `SphereMath.face_local_x(face, colx, c.cx)` needs the absolute index. With local coords in [0,16) that is always chunk (0,0) of the face.
- CONSEQUENCE: on every chart except the home pair, the aim DDA queries face chunk (0,0) — the chart CORNER — regardless of where the player stands. Break/place then act on that corner. The measured 5,841 m is the distance from the player to that corner, and it is frame-independent (identical with the warp on and off), which is why the warp was never implicated.
- SAME DEFECT, SECOND ENTRY POINT: `_sim_get_block`/`_sim_set_block` (player.gd:3248/3256) pass their cell coordinates straight to `get_block_key` too, so doors and any other sim-routed face access read the same wrong chunk.
- THIS IS PRE-EXISTING, not from the AC-0433 migration: the warp changed where face geometry sits; it did not touch `_flat_ray`, `aim_hit` or `get_block_key`. Face editing has been landing on the chart corner since the face block API and the anchor cell frame were introduced.
- THE FIX IS NOT A ONE-LINER, and that is why it is not being rushed here: the ray origin must be expressed in ABSOLUTE face columns before the DDA, and on the MIRROR class (faces 4-7) the mesh's local +X runs AGAINST u, so the local→absolute map is `ccx*16 + 15 - local` there, not `ccx*16 + local`. `get_block_key` already applies `face_local_x` internally for absolute→slot, so the ray side must produce true absolute columns and let the API do the mirror. The next plan must state that mapping explicitly and prove it with an arm that places a block on a mirror face AND a non-mirror face and asserts the edit lands in the aimed cell.

## RUN — 2026-10-20 17:44 EDT — AC-0462 (fix: face aim frame)
- LANDED: (1) player.gd `_flat_ray` face branch now returns ABSOLUTE face columns (plan §3 mirror form: ax = ccx*16 + (16.0 - ocells.x if mirror else ocells.x), d.x flipped on mirror, y/reach untouched) — get_block_key/set_block_key NOT touched. (2) harness.gd `faceedit` extended to TWO charts in one run: `_faceedit_test` spawns once, then runs `_faceedit_chart(p, edge, pf0, R, warp)` for edge 0 = +x edge (mirror class, face 4/5) and edge 1 = -z edge (non-mirror class, face 10/11); per-chart asserts face > 1 AND the expected mirror class (wrong class = loud fail), plus the existing aim/verify, break-then-place-same-cell, surface_error_m; per-chart RESULT: face, mirror, aim_cell, placed_cell, break_ok, place_ok, surface_error_m (+ existing fields). The arm's own candidate/lift column maths was ALSO converted to absolute columns (it had the same local/absolute mix — without that, the fixed DDA would never hit the corner-chunk candidates). (3) tasks/harness_data.yaml faceedit row updated (two-file rule, scenes/AGENTS.md) + HARNESS.md re-rendered.
- GATES (fix run, 2026-10-20):
  * WARP ON (rev 4, .scratch/AC-0462-gates/faceedit-r9.log): g0 + 5 smoke + ac0423probe + faceedit all rc=0, SCRIPT=0/SHADER=0, ok=true.
    - Chart 1 (edge 0, +x stand): face 5, mirror=1, aim_cell [1022,183,1014] == placed_cell, break_ok=true, place_ok=true, target_chunk 5:63:63 (the player's own anchor chunk — NOT the chart corner), surface_error_m 14.753.
    - Chart 2 (edge 1, -z stand): face 11, mirror=0, aim_cell [1014,183,1023] == placed_cell, break_ok=true, place_ok=true, target_chunk 11:63:63, surface_error_m 14.332.
  * WARP OFF (rev 5, --env AWECRAFT_WARP=0, faceedit-r10.log): same arms all rc=0, SCRIPT=0/SHADER=0, ok=true.
    - face 5 mirror: aim==placed [1023,167,1015], break/place ok, surface_error_m 16.55. face 11 non-mirror: aim==placed [1014,183,1023], break/place ok, surface_error_m 14.26.
  * harness_doc.py --check: exit 0 (after the yaml row update + re-render).
- FINDING (reported, not fixed — SphereMath/player_anchor are read-only per plan §2): surface_error_m is 14.26-16.55 m, far above the 2.0 m gate target, while every cell-identity assertion passes. Cause: the anchor cell frame uses face_cell_scale's uniform constants (3.068 m/cell on the half axis) but the true chart spacing at the home-edge stand is 2.194 m/cell (verified two ways: the game's own LSQ chunk-fit basis length is 2.194, and the adjacent chart cell-centre distance is 2.194; the arm's diag basis_lens 0.716 = 2.194/3.068 measures exactly that ratio). The folded net is equirectangular — per-cell spacing varies ~30% along the face, and the uniform anchor scale cannot agree with the LSQ placement at home-edge stands. The column fix itself is proven: edits land in the DDA's absolute cell on a mirror and a non-mirror chart alike, both warp states — down from 5,841.19 m (warp on) / 5,840.47 m (warp off), round-18 baseline.
- Resume point: none for this fix — deliverables complete (fix, two-chart arm, both gate sets, journal, deviations, results page). Follow-up for the COORDINATOR: the anchor v-scale inaccuracy (face_cell_scale uniform constants vs the equirectangular chart) is the remaining aim-surface residual; it also distorts face-chart player movement (bz length 0.716) and is a candidate for its own ticket. The round-18 secondary findings (key_for_sphere_pos u mismatch; _sim_cell_center's un-localised z) persist — diag numbers in both faceedit logs.

## Coordinator triage — the fix (round 19)
- VERIFIED INDEPENDENTLY: faceedit run by the coordinator, rc=0, SCRIPT/SHADER 0/0 — face 5 (mirror) aim_cell [1022,183,1014] == placed_cell, face 11 (non-mirror) aim_cell [1014,183,1023] == placed_cell, surface_error 14.753 / 14.332 m. Both charts now edit in the player's OWN anchor chunk (5:63:63 and 11:63:63) instead of the chart corner (0,0): the round-18 5,841.19/5,840.47 m is gone, and place/break both succeed on a mirror and a non-mirror face.
- THE MIRROR FORM IS NOT INVERTED — that was the main risk of this fix and both chart classes pass, which is what the two-chart arm was for.
- TARGET NOT MET, AND THE REASON IS A SECOND, DIFFERENT BUG: plan §5 asked for surface_error ≤ 2.0 m and it reads ~14.3-14.8 m. The builder's diagnosis is specific and checkable: the anchor frame divides by `SphereMath.face_cell_scale`'s uniform ~3.068 m per cell, while the true chart spacing at that stand is ~2.194 m per cell (the LSQ chunk-fit basis length and the adjacent cell-centre distance both read 2.194; the ratio 0.716 is exactly 2.194/3.068). A ~1.4x cell-scale error over the anchor offset yields the ~14 m residual. That is a SEPARATE defect in the anchor basis/scale, out of this ticket's §2 scope (SphereMath is read-only there), and it is pre-existing rather than caused by the frame fix.
- SO THE FIX IS PARTIAL AND THE TICKET STAYS OPEN: the wrong-chunk bug (kilometres) is fixed and proven; the wrong-cell-within-chunk bug (metres) remains and needs its own contract covering `player_anchor`'s scale against the real chart spacing. Do NOT close this on the strength of "aim == placed" alone — aim == placed only proves the two sides agree, and both still carry the scale error.
- The round-18 secondary findings persist and are unchanged by this fix: the `key_for_sphere_pos` u mismatch and the `_sim_cell_center` un-localised z.
