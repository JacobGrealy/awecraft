## RUN — Sun Oct 25 13:32:34 EDT 2026 — AC-0482

## MEASURED (BEFORE, gate a) — aimface probe r1, seed 44, R = 4000
Instrument: temporary `aimface` arm in harness.gd (dispatch after voxelcost +
functions at file tail; the AC-0479 aimslide shape — box centre offset from
the block's TRUE centre, 8 box corners' nearest-corner distance split radial
vs tangential, box-up vs block-up). Block truth: home = the exact per-vertex
warp (the AC-0479 construction the mesh/collision consume); face = the
chunk's own LSQ transform (face_chunk_transform + face_local_x — the same
placement _sim_cell_center and the mob spawn use). Player fly-mode-teleports
above each column, aims straight down (pitch -1.55), the aim must stably
land on the column top (30 frames stable) before the highlight transform is
read. Sites: spawn, home_far (D~153), face4_edge (3 cells inside the +x home
edge, mirror class), face4_mid (+x hemisphere midline), face2_pole (-Y pole).
Full numbers in .scratch/AC-0482-gates/aimface-r1.log (gate a):

  site          face  cell              D (m)    centre_mm      corner_tang_mm   corner_rad_mm  box_up_deg
  spawn         0     [8,140,8]         12.02    0.0            10.87            10.36          ~0.000
  home_far      0     [152,164,-8]      152.68   0.0            15.00            10.61          0.000
  face4_edge    4     [6280,138,1570]   -        3,313,236.8    3,035,943.1      1,327,219.1    45.39
  face4_mid     4     [3141,154,1570]   -        3,028,876.0    2,820,392.8      1,104,938.7    88.02
  face2_pole    2     [1570,141,3141]   -        7,220,077.1    3,538,831.3      6,293,670.4    155.27

Non-home faces are WRONG BY KILOMETRES (centre 3.0-7.2 km; the "cell-sized
~16 m" class is a lower bound — the generic conversion puts the box on the
HOME patch, on the opposite side of the planet at the pole). The pre-fix
face>1 branch never sets hl.global_basis — the pre-fix box-up is the stale
home-pair warp basis [0.038, 0.999, -0.002] (≈ global +Y) vs the block's
radial. Home face = AC-0479's post-fix numbers intact (10.87 vs 10.9 mm at
spawn; 15.00 vs 15.5 mm at D≈153).

The seam (established before the fix, per plan §2): aim_hit()/_flat_ray()
deliver hit.cell in the face chunk's CELL frame (absolute face columns,
~1 m/cell in-plane, AC-0309 C5 / AC-0462) for face > 1, but
_update_interaction's face>1 branch (player.gd:3227) feeds those cell coords
into world_pos_of_flat — the generic home-chart flat->world conversion
(SphereMath.flat_to_world, NO face argument). Faces 0/1 ARE the home chart
so their flat coords are the cell coords; faces 2-11 are NOT pre-mapped
into it. The mesh/collision for face>1 consume the chunk's own LSQ
transform (world.gd:16160 face_chunk_transform at _face_land), which is
what the box must ride.

## LANDED — the fix (one file: godot/player/player.gd)
The mixing conversion, named: the face>1 branch of _update_interaction fed
hit.cell (CELL frame — absolute face columns, ~1 m/cell) into
world_pos_of_flat (the generic home-chart FLAT->world, no face argument).
Fix at that source: the branch now places the box through the chunk's own
LSQ transform — face_chunk_transform(face, cell's ccx, ccz, R) applied to
the cell's local slot (face_local_x mirror layout, lz = cell.z - ccz*16),
and orients it by the chunk basis orthonormalized (T.basis.y is the radial
at the chunk centre — the block's actual up). Same placement convention as
_sim_cell_center (player.gd:3342) and the face mob spawn (world.gd:15076).
Also corrected the stale "the aimed cell is FLAT" comment (it is FLAT on
the home pair, CELL frame past the edge). No per-face fudge offset; no
other file touched; home branch (AC-0479) untouched.

## PROBE GROUND-TRUTH CORRECTION (before finalizing the fix)
The first AFTER run measured 49-183 mm face corner_tang — a PROBE bug,
discovered while checking what the mesh actually consumes: with the default
AWECRAFT_WARP (on), the face mesh vertices are warped POINTWISE through
chunk.gd _warp_cell_point and the chunk node is set to IDENTITY
(chunk.gd build_mesh_face:2033-2036) — face_chunk_transform (the LSQ affine
fit) is only the flag-off legacy placement. The block's true frame is the
per-vertex warp (the AC-0479 ground truth, face edition). The probe was
updated to read the block corners through the chunk's OWN _warp_cell_point
method (the mesh's construction itself — no second placement invented; the
faceedit convention), falling back to the legacy node transform when the
flag is off. THE FIX WAS ALSO CORRECTED AT THE SOURCE to ride the same
per-vertex warp: player.gd _ac0482_face_warp_point (the exact
_warp_cell_point construction: local slot -> chart (u,v) ->
(R+ly)*normalize(uv_to_world(face,u,v,R))-(0,R,0)) at the cell centre,
oriented by the RAW warp Jacobian (central difference, normalized by 2e).
Raw, NOT orthonormalized (unlike the home twin): the face chart's in-plane
metric is sheared (the fit's in-plane axes run ~26 deg off-orthogonal at
chunk corners; the home warp is ~D/R ~ 3 deg), and orthonormalizing the
frame left 32-172 mm of corner error on a 1.02 box (measured). A node basis
may carry the shear: the indicator is unshaded and the sheared transform is
exactly what the block mesh rides. The home branch is untouched.
Iteration trail (all in .scratch/AC-0482-gates/): r1a first attempt (home_far
aim bled into a neighbour cell — player placed on the integer cell boundary;
fixed by the +0.5 cell-centre placement + eye-derived want), r1 = BEFORE
(gate a), r2-affine-iteration = the intermediate face_chunk_transform fix
(the unit mismatch fixed, 49-183 mm shear residual exposed the warp ground
truth), r2 = the final warp fix.

## MEASURED (AFTER, gate b+c) — aimface probe r2 (final), seed 44, R = 4000
Full numbers in .scratch/AC-0482-gates/aimface-r2.log:

  site          face  cell              D (m)    centre_mm   corner_tang_mm  corner_rad_mm  box_up_deg
  spawn         0     [8,140,8]         12.02    0.0         10.87           10.36          ~0.000
  home_far      0     [152,164,-8]      152.68   0.0         15.00           10.61          0.000
  face4_edge    4     [6280,138,1570]   -        0.0         13.81           11.18          ~0.000
  face4_mid     4     [3141,154,1570]   -        0.0         14.23           10.62          0.000
  face2_pole    2     [1570,141,3141]   -        0.0         13.96           11.05          ~0.000

Non-home, pre -> post (centre offset / corner_tang / box-up):
  face4_edge  3,313,236.8 mm -> 0.0 mm (2e7x) | 3,035,943.1 -> 13.8 mm (2.2e5x) | 45.39 deg -> ~0
  face4_mid   3,028,876.0 mm -> 0.0 mm        | 2,820,392.8 -> 14.2 mm (2.0e5x) | 88.02 deg -> 0.0
  face2_pole  7,220,077.1 mm -> 0.0 mm (2.4e7x) | 3,538,831.3 -> 14.0 mm (2.5e5x) | 155.27 deg -> ~0
Two non-home faces verified (face 4 at two sites + face 2 pole, both mirror
class). Home regression (gate 3.4): spawn 10.87 mm / ~0 deg (AC-0479: 10.9 /
0.013) and home_far D=152.7: 15.00 mm / 0.000 deg (AC-0479 farA: 15.5 / 0.162
@ D=153) — UNCHANGED. The post-fix face residual (11-14 mm) is the same class
as the home face's own (10.4-15.0 mm): the 1.02 overhang + second-order warp
curvature — the box matches the block 1:1 to the indicator's own design.
Mid-iteration bug found and fixed (record for the trail): dropping
orthonormalization exposed a missing /(2e) in the central difference (the
home twin hides it inside orthonormalized()) — the box rendered at 20%
scale (measured residual 397.9-398.1 mm = exactly 0.5 - 0.51*0.2), fixed by
normalizing the differences.

## CLOSEOUT — probe removed, final gates (gate d)
The aimface probe (dispatch branch + all _aimface_* functions) was
REMOVED from harness.gd via git checkout of that single file (its diff
was 316 pure insertions, all probe code — verified line by line first).
git diff --stat: only godot/player/player.gd modified (the fix);
harness.gd byte-identical to HEAD. (docs/INDEX.md + tasks/TASKS.yaml
dirt belong to other sessions — untouched.)

Final gate set: python3 tasks/scripts/gate_run.py AC-0482 --arms
g0,genhash,smoke,interact (rev 3 / rev 1 per arm) — .scratch/AC-0482-gates/
summary.txt + per-arm logs:
  g0       rc=0  script=0  shader=0  ok=true
  genhash  25/25 hashes, byte-IDENTICAL to the AC-0479 baseline
           (diff of the 25 GENHASH lines: no changes) — the fix is
           UI-frame only; generation untouched
  player   sprint_ok=true
  interact place_ok=true  drop_spawned=true  highlight_visible=true
           mine_diag.prog_max=0.972222222222223 — the KNOWN flake value
           0.9722, still as recorded (not chased, per the ticket)
  light    cave_census_cands=590  cave_eff=0  surface_eff=15  (recorded)
  fluids   sea_stable=true  sea_backed_before=320  sea_backed_final=320 (recorded)
All standing values as recorded. GATE D PASS.
