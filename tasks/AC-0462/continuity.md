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

## RUN — 2026-10-20 18:52 EDT — AC-0462b (scale probe: which world->cell conversion matches the mesh)
- LANDED: tasks/AC-0462/scale_probe.gd (NEW — the ONE deliverable; no product code touched, read-only anchors: sphere_math.gd face_cell_scale/face_chunk_transform/face_mirror_x/face_local_x, world.gd player_anchor 15225, player.gd _flat_ray 2810). Standalone SceneTree probe per plan §3: R=4000, face 5 (mirror) + face 11 (non-mirror), ccx/ccz in {0,1,31,63}, all 256 cells per chunk = 8192 samples; ground truth = the cell square under face_chunk_transform (the chunk node's transform, world.gd:15363 — the MESH's transform, plan §6, stated in the probe header and RESULT); anchor = the sample's own chunk (player_anchor's pre-divided basis, bx = B.basis.x/sc.x); the four plan-§3 candidates + a negative self-check; ccx*16/ccz*16 + the AC-0462-fix mirror form before comparing to the true absolute column.
- GATES (2026-10-20, AC-0462b):
  * g0 + ac0423probe via gate_run.py: both rc=0, script=0 shader=0, ok=true (gate_run rc=0; .scratch/AC-0462-gates/g0-r4.log, ac0423probe-r4.log; the fix-run summary was backed up to summary-fixrun.json.bak first).
  * Probe standalone (scaleprobe-r2.log): rc=0, gate_census 0/0, RESULT ok=true, samples 8192, truth_recover 8192/8192, ms 157.
  * THE TABLE (pooled n=8192, error in cells; per-face in the log — face 5 norm_basis exact 0.440673828125 / face 11 0.44384765625, same shape):
      shipped         worst 15  mean 4.7459716796875   exact 0.1060791015625
      no_second_div   worst 91  mean 38.468994140625   exact 0.0
      norm_basis      worst 16  mean 4.0980224609375   exact 0.4422607421875  <- WINNER
      raw_nominal     worst 91  mean 38.468994140625   exact 0.0 (≡ no_second_div algebraically — duplicate in the plan's list)
  * Scales (per chunk in the log; basis_x_len == spacing_u to 4dp at every chunk): face 5 u-spacing 4.36562061309814..6.13580513000488 (sc.x 6.13592338562012); face 11 u-spacing 2.19582390785217..3.06790900230408 (sc.x 3.06796169281006). Equirectangular variation ~30-40% along the face, as the round-19 journal said.
  * FINDING (reported, not fixed): NO candidate is exact on every sample — and the no-second-division hypothesis is refuted by data (it is the worst). The true inverse of the LSQ mesh placement divides by |e|² and inverts the FULL 3x3: at the chart-corner chunks the LSQ basis is strongly non-orthogonal (5:0:0: |bx|=5.7503, |bz|=2.8924, bx.bz=8.1625, cos≈0.49 — scalediag-r1.log), so norm_basis's orthogonal-projection approximation still fails there (worst 16 = one chunk width). The fix ticket needs candidate 5 = B.affine_inverse() + the mirror/absolute-column form — a design decision this measurement plan deliberately does not make. The ~14 m faceedit residual is the v-axis half of the same defect at the 63:63 stand: sc.x 6.1359 ≈ |bx| 6.1358 (u nearly exact), sc.y 3.068 vs |bz| 2.1958 (ratio 0.716 — the journal's "half axis" is the v axis at that stand); scalediag-r1.log at the 5:63:63 chunk centre: shipped cell (1015,1012) vs truth (1015,1016) — 4 v-cells ≈ faceedit surface_error_m 14.753/14.332.
  * Instrument trust: truth_recover 8192/8192 (the consumer's own world_to_face recovers the truth cell for EVERY sample — ground truth and the consumer's chart map agree at cell resolution on both chart classes); negative self-check exact_frac 0.015625 < 0.5 (the instrument can fail). Caveats: samples on the chunk plane (cell-y not compared; all four candidates share the same y), and the warp moves the mesh from the LSQ placement by ≤ the fit residual (~0.4 m << 1 cell), so the plan-§6 truth-model choice cannot flip the verdict.
- Resume point: MEASUREMENT COMPLETE — the table + scales are the deliverable (AC-0462-deviations.txt item 11, results page rendered). Next (coordinator): the fix ticket — apply B.affine_inverse() (full 3x3) + the AC-0462 mirror/absolute-column form in the anchor/flat-ray path, re-run faceedit against the ≤2.0 m surface_error target, then AC-0459 and AC-0463.

## Coordinator triage — AC-0462b (the scale measurement). MY HYPOTHESIS WAS WRONG; THE DATA ANSWERS IT ANYWAY.
- THE MEASUREMENT (8,192 samples, face 5 mirror + face 11 non-mirror, ground truth = the chunk node's own transform, recoverable 8192/8192): shipped o·bx/sc.x — worst 15 cells, mean 4.75, exact 10.6%. no_second_div o·bx — worst 91, mean 38.5, exact 0%. norm_basis o·e/|e|² — worst 16, mean 4.10, exact 44.3%. raw_nominal — identical to no_second_div (my plan's candidates 2 and 4 were the same formula, a flaw in the plan).
- WHAT IT REFUTES: I claimed the bug was the scale being applied twice. It is not — the "no second division" candidate is the WORST of the four (exact 0%), so that hypothesis is dead and would have made the code worse had I implemented it from reasoning alone. This is the second time in this series that measuring instead of deriving saved a wrong fix.
- WHAT IT SHOWS: **no per-axis projection can be exact**, because the LSQ chunk fit's basis is strongly NON-ORTHOGONAL at corner chunks (measured on 5:0:0: |bx| 5.7503, |bz| 2.8924, bx·bz 8.1625, cos ≈ 0.49). The correct world→cell conversion therefore needs the full 3×3 inverse — `B.affine_inverse()` — plus the AC-0462 mirror form, not a dot-product per axis.
- THE 14 m RESIDUAL, explained and localised: at the 63:63 stand the v axis is the mismatched one (sc.y 3.06796 vs |bz| 2.19582, ratio 0.716 — the journal's earlier "half axis" note was reading v, not u; u is nearly exact there: 6.135923 vs 6.135803). ~4 v-cells × that ratio ≈ the measured 14.753/14.332 m. So the residual is one axis at one stand, not a global scale error.
- Also on the record: the u-spacing varies 4.37-6.14 m on face 5 and 2.20-3.07 m on face 11 across chunks — an equirectangular ~30-40% variation, which is exactly why a single nominal `face_cell_scale` cannot express the local frame.
- NEXT (the fix, not done here): replace the per-axis dot products in `_flat_ray`'s face branch with `_anchor["basis"]`-based matrix inversion (or have `player_anchor` return the inverse directly), keeping the AC-0462 absolute-column and mirror handling that already landed. Then the same two-chart arm must go green with surface_error under 2 m.

## RUN — 2026-10-20 19:20 EDT — AC-0462c (affine inverse fix, plan §3)
- LANDED: (1) world.gd player_anchor face return: added ONE key "inv": B.affine_inverse() (line 15254; existing keys untouched). (2) player.gd _flat_ray face branch: new guard `if _anchor.has("inv")` runs the full 3x3 inverse (lo = inv * camera.global_position, dl = inv.basis * aim_dir()) and the UNCHANGED absolute-column + mirror conversion, early-returning; the per-axis per-dot code is kept verbatim below the guard as the pre-"inv" fallback; non-face/home path byte-identical. (3) scale_probe.gd: added candidate "affine_inverse" (inv * p) to CANDS + the locals array; nothing else touched.
- GATES (2026-10-20, AC-0462c; all logs .scratch/AC-0462-gates/):
  * Probe standalone (scaleprobe-r3.log): rc=0, gate_census 0/0, RESULT ok=true, samples 8192, truth_recover 8192/8192, ms 184. THE PLAN'S STOP CHECK PASSED: affine_inverse exact_frac 1.0, mean 0.0, worst 0 (pooled n=8192; face 5 n=4096 exact 1.0 worst 0; face 11 n=4096 exact 1.0 worst 0) — the full 3x3 inverse is exact on every sample on both chart classes. The other four candidates are unchanged (shipped 0.1060791015625 / norm_basis 0.4422607421875 / no_second_div 0.0 / raw_nominal 0.0); negative self-check exact_frac 0.015625. Launch note: the probe header's RELATIVE `-s tasks/AC-0462/scale_probe.gd` form does not resolve under `--path godot` (res://tasks/... File not found, rc=1 — same shape as scaleprobe-r1.log); the run used the ABSOLUTE filesystem path for -s.
  * WARP ON light set (gate_run rev 6-8, summary.json): g0 rc=0 script=0 shader=0 3s; player 16s sprint_ok=true; interact 8s; light 9s; fluids 12s; genhash 3s (GENMS 128 — 25/25 lines byte-identical to the pre-change tree, genhash-r5 vs genhash-r6); ac0423probe 8s (RESULT equal to the pre-change run ac0423probe-r6 excluding ms). faceedit 43s — RESULT ok=false (HARD FAIL, not relaxed): chart 0 (edge 0, face 5, mirror 1): fail no_target, anchor_col [1,184,7], aim_col [1022,1015], candidates 67, scanned 4, own_cell_hits 0, lift 47.22, local_top 182, stand [2930.98,-1080.68,-1.96]; chart 1 (edge 1, face 11, mirror 0): fail no_target, anchor_col [7,184,14], aim_col [1015,1022], candidates 70, scanned 4, own_cell_hits 0, lift 42.01, local_top 181, stand [-2.15,-1077.59,-2933.85]. (gate_run's per-arm "ok" is process-level rc+census; the RESULT payload's ok is the arm's real gate.)
  * WARP OFF light set (gate_run rev 7-9, --env AWECRAFT_WARP=0): g0/player/interact/light/fluids/genhash/ac0423probe all rc=0 script=0 shader=0; genhash 25/25 identical to pre-change tree (GENMS 127); ac0423probe equal to the warp-ON run excl ms. faceedit 43s — RESULT ok=false (same hard fail): chart 0 fail no_target, own_cell_hits 336 (the eye was buried this run — spawn variance), anchor_col [0,170,7], aim_col [1023,1015], candidates 53, lift 56.88, local_top 167, stand [2912.87,-1097.43,-2.13]; chart 1 fail no_target, own_cell_hits 0, anchor_col [7,184,14], aim_col [1015,1022], lift 42.01, stand [-2.15,-1077.59,-2933.85].
  * FINDING (the faceedit gate is RED in both flag states — a failed expectation, reported, never weakened): the GAME-side conversion is proven exact by the probe (the plan's named check), but the ACCEPTANCE ARM's own eye/candidate/lift maths still runs in the per-axis anchor frame (harness.gd:36142/36167/36179 — ocell from dot-products, oabs and the +/-3 candidate window from ocell, local_top from the per-axis column). At the 63:63 corner stand the per-axis frame and the exact inverse frame diverge by ~4 v-cells (scaleprobe/scalediag-r1: 5:63:63 shipped (1015,1012) vs truth (1015,1016)) — MORE than the arm's +/-3 window and its ~6 m (~2-3 cell) reach — so the now-exact player ray aims the true surface cell OUTSIDE the arm's candidate window and no look in the 12x7 scan hits any of the 4 scanned candidates. r9's green run was a per-axis ray against per-axis candidates — self-consistent in the wrong frame; that self-consistency is exactly what produced the 14.753/14.332 m residual this fix targets. Plan §2 names harness.gd as "No edit required" — converting the arm's own frame to the inverse (or widening its window/reach) is a design decision this plan does not make, so the arm was NOT edited.
- Resume point: game-side fix LANDED and exact at the conversion level (probe 1.0 both faces, worst 0); faceedit acceptance is BLOCKED on a coordinator plan decision for the arm's own frame (candidate: AC-0462d — arm frame -> _anchor["inv"], same absolute/mirror form the fix landed in player.gd). Standing guards all green (genhash 25/25 both states; ac0423probe unchanged excl ms; g0/smoke clean both states).

## Coordinator triage — AC-0462c (the fix is in; the ARM is now the blocker)
- THE GAME-SIDE CONVERSION IS PROVEN EXACT, and I verified it myself rather than taking the builder's word: `scale_probe.gd` run by the coordinator gives affine_inverse **worst_cells 0, mean 0.0, exact_frac 1.0** over 8,192 samples on face 5 (mirror) and face 11 (non-mirror), with truth_recover 8192/8192. So a world point on a face chart now converts to exactly the cell whose geometry contains it — that is the whole question this sub-thread was about, answered by measurement on both chart classes.
- THE ARM WENT RED, AND THE RED IS THE ARM: `faceedit` now reports no_target on both charts because ITS OWN eye/candidate/lift maths (harness.gd ~36142/36167/36179) still builds the aim from the per-axis frame, which diverges ~4 v-cells from the exact frame at the 63:63 corner stand — outside its ±3 candidate window and its ~6 m reach. My plan forbade editing the arm, so the builder left it pristine. That was my scope error: the arm samples the aim, so it needs the same conversion the game uses.
- THE SHARPEST FINDING IN THIS SUB-THREAD, from the builder and worth keeping: r9's GREEN WAS NEVER REAL EVIDENCE. It passed because the arm and the game both used the SAME wrong per-axis conversion — per-axis-vs-per-axis self-consistency, which is exactly the 14.75 m residual it reported as "small". A test that agrees with itself measures nothing about the world. Once the game side became exact, the arm could no longer find the target at all.
- NO STANDING VALUE MOVED: genhash 25/25 identical, ac0423probe equal excluding ms, every arm rc=0 with SCRIPT/SHADER 0/0 in both warp states. This change touches aim conversion only.
- NEXT (small, and mine to author): let `faceedit` use the anchor inverse for its own eye/candidate/lift maths, then re-run. With both sides on the exact conversion, the arm should go green with a surface_error that means something. Until then the ticket stays open and the arm is not evidence either way.
