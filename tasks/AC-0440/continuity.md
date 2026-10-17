## RUN - Fri Oct 16 22:23:18 EDT 2026 - AC-0440

- Read spec (TASKS.yaml AC-0440), AC-0384 §29 (the measurement + flat-grass frame),
  CONTINUITY top checkpoint, ARCHITECTURE.md, AC-0420/0427/0432 results, HARNESS/OPS.
- KEY FINDING (pixel forensics on ac0384-r24-ground-down-day.png, camera model from
  AWECRAFT_AIM "8.5,143.62,8.5,0,-1.5", fov 75, eye 143.62, ground top y=140/surface 141):
  the ENTIRE frame lies inside chunk (0,0) (world x 4.9..12.1, z 6.2..10.2 — the x=16 / z=16
  seams are out of frame). The dark square projects to world [8.18,8.83]x[8.10,8.76], i.e. a
  ~1 m footprint centred on the spawn cell (8,8) — it is NOT a 16 m chunk square, and no seam
  is even visible in the frame. The 1x1 depression footprint [8,9]x[8,9] at y=140 projects to
  px (575,329)-(705,459), matching the observed dark region (582,322)-(698,440) within edge
  tolerance. Hypothesis: the spawn cell is a 1-deep pit (top=140 vs neighbours 141); its floor
  corners are fully horizon-occluded in the AC-0398 modern field (8 neighbours all >= by)
  -> sl = MIN_AMB -> light floor -> L=0.6127 (ambient_sky ON) vs 1.0 open ground.
  SPAWNSEARCH (r24 log): cell=[8,8] top=140 — neighbour tops still to be confirmed by probe.
- Static analysis of the mesher (gdext/src/mesh.cpp): in modern mode the R channel is the
  geometric sl from the per-chunk 18x18 column-top grid (hg), B is oshade from the same grid;
  starlight per-cell sky does NOT enter R in modern mode. hg is built once per build from the
  snap over the build's y-window. Top-slab builds include their own top -> correct on flat
  terrain. Seam corners are handled by seamc (AC-0427). Nothing in the static path shares one
  value across 16x16 on flat grass — the 16 m reading of the frame appears to be a scale
  misjudgement of a 1 m feature.
- Added TEMPORARY ac0440probe arm to harness.gd (terrain tops 5x5 + top-slab vertex colours
  around spawn). Pristine contract: remove before closeout + re-run gates after removal.

- PROBE 1 (ac0440probe, headless): terrain is COMPLETELY FLAT — all 25 cells of the 5x5
  around spawn have top=140, top block id=1 (grass). No pit at spawn (the ticket's
  depression hypothesis is dead). Every top-slab vertex of chunk (0,0) in the dark-square
  region carries R=1.0, G=0.0, B=1.0 — full sun, full face shade. The MESH IS INNOCENT:
  the dark square is drawn OVER a correctly-lit mesh.
- PIXEL FORENSICS round 2: the dark region is a sharp rectangle px x 580..703, y 320..442
  (~120px), interior is the grass texture dimmed uniformly; measured luma ratio
  inner/ring = 0.750 (a 0.28-alpha black overlay in linear light is 0.72, ~0.75 after
  ACES at mid-tones — an exact match for a 28% black fill). The whole CELL is only 0.85x
  its neighbours, so it is NOT a 1.02m overlay covering the cell... until the camera model
  was re-derived from the LIVE camera.
- PROBE 2 (scene census, reproducing the r24 AIM state: fly + teleport(8.5,143.62-EYE,8.5)
  + look(0,-1.5)): the live player camera has FOV 98.99 — player.tscn carries fov 90 and
  player.gd:837 boosts it x1.10 while flying (90*1.10 = 99.0). My 75-fov model was wrong;
  at 99 fov the nadir scale is 118 px/m. Re-projecting with the live transform
  (pos 8.787,143.602,8.787 — the world frame carries the +0.282 flat-frame offset):
  the aim-highlight BoxMesh 1.02^3 (player.gd _build_highlight, AC-0309 era) top face
  projects to px (578,321)-(701,443). OBSERVED dark square: (580,320)-(703,442).
  Match within 2px on ALL FOUR EDGES. The highlight census says visible=true, 1.02^3,
  centred on the aimed cell.
- CONCLUSION: the "16x16 m dark square" of the ticket is the DDA AIM HIGHLIGHT — the
  28% black semi-transparent target box (Color(0,0,0,0.28), BoxMesh 1.02^3) drawn over
  the aimed block while the camera looks straight down. It is UI, not lighting: terrain
  flat, vertex colours uniform, no lighting path involved. The 16 m reading was a scale
  misjudgement (fly fov 99: 1 m ~ 118 px; the frame spans only ~10.3 m of ground).
  "The same problem remains inside chunks" is consistent: it is one cell mid-chunk by
  construction. Nothing in the lighting shares one value across 16 m — there is no
  lighting defect in this frame.
- FIX DESIGN: ship the highlight as a black WIREFRAME outline (no fill — the aimed face
  keeps its terrain lighting; the indicator reads as a mark, not a differently-lit
  patch), behind Settings "aim_wire" DEFAULT ON (the look the user reported IS the
  defect, AC-0426/0432/0436 re-ruling: the fix ships in, OFF is the A/B), env
  AWECRAFT_AIMWIRE=0|1 (the viewmodel_occlude preload pattern, player.gd _ready),
  options-menu checkbox (menu.gd pattern), apply-on-change in _update_interaction
  (material rebuilt only on flip). No mesher/C++/shader change -> genhash must stay
  25/25, meshprobe 1.0, seam twins hold by construction (re-measured by extending the
  probe with the corner-paired twin dump of the 3x3 block's 12 seams).

## RUN - AC-0440 (cont., after mechanism confirmation)

- FIX IMPLEMENTED (behind a switch, per the ticket):
  * settings.gd: new key "aim_wire" DEFAULT TRUE (the reported look is the
    defect — the AC-0426/0428/0432/0435/0436 ruling: the fix ships in, OFF is
    the A/B), full ticket comment.
  * player.gd: _aim_wire_material() (ON: unshaded black WIREFRAME, no
    transparency — the aimed face keeps its terrain lighting; OFF: the exact
    pre-fix Color(0,0,0,0.28) alpha fill). _aim_wire_sync() in
    _update_interaction rebuilds the material only on a flip (old material
    freed; the viewmodel_occlude apply-on-change pattern). _ready env preload
    AWECRAFT_AIMWIRE=0|1 (the AWECRAFT_VMOCC pattern, written WITHOUT save).
  * menu.gd: options-page checkbox row (last row) + _on_aim_wire_toggled +
    button_pressed sync from the stored value.
  * No C++/shader/mesher change. No .so rebuild. No shaderforce owed.
- LIGHT GATES (all on the fix tree, one godot at a time, HOME=/tmp/dsh_home):
  * G0: EXIT=0, SCRIPT 0, SHADER 0 (g0-final.log). PASS.
  * SMOKE (player;interact;light;fluids;genhash): EXIT=0, battery ok=true,
    25/25 GENHASH lines, 0 errors (smoke.log). interact arm:
    highlight_visible=true (the indicator still works with the new look). PASS.
  * PROBE (meshprobe): ok=true, ac0211_ok=true (meshprobe.log). PASS.
- SEAM TWIN RE-MEASURED (extended the temporary ac0440probe with the
  corner-paired top-vertex-colour dump over the 3x3 block's 12 internal seams).
  Method note: the mesh carries NO vertex exactly on the nominal seam line —
  the seam-V edge quads overhang the seam (corners at local 16.61 / -0.61,
  each side), so a seam window pairs the two overhanging corners. AC-0427's
  deleted probe's exact selection is not reconstructable, so the absolute
  count (180 pairs, 145 level, 135 exact, max level step 0.9216) is NOT
  directly comparable to their 190/191. THE HOLDING CHECK IS THE A/B:
  twin measurement on the fix tree vs the pre-fix tree (the 3 fix files
  stashed for the run): BYTE-IDENTICAL (twin-before.json == twin-after.json,
  0 row diffs). Zero mesh-path diff + genhash 25/25 + meshprobe 1.0 => the
  AC-0427 twin result holds.
- PROBE parse-error detour (logged for the record): a GDScript "Parse Error"
  on harness.gd reload was the seamdump append block indented one level too
  shallow (the append sat outside the for-k loop, referencing the then-out-of-
  scope wp3/k). GDScript reports out-of-scope identifiers as a parse failure
  through GDScript::reload — "Could not parse script from" is the umbrella
  for semantic errors, not just syntax. Fixed by re-indenting; bisection via
  --headless --quit after each step.
- DESIGN CORRECTION (measured): StandardMaterial3D.wireframe is IGNORED on this
  dev pipeline — a 1.02^3 box with wireframe=true + unshaded opaque albedo
  rendered as a SOLID fill (the first after-capture was a pitch-black square,
  luma 0 across the interior; a red A/B (ac0440-exp-red) confirmed: interior
  (255,0,0) everywhere, no lines). So the ON look is REAL GEOMETRY: a hollow
  12-strip edge frame (unit-cube MultiMesh, 12 instances: 8 face-edge strips
  1.02 x 0.02 x 0.02 + 4 corner pillars 0.02 x 1.02 x 0.02), unshaded opaque
  black, no transparency, no filled faces. The highlight node is now a
  MultiMeshInstance3D in BOTH states (OFF = 1 instance at the 1.02 scale =
  the pre-AC-0440 box bit-for-bit); `highlight` re-typed MeshInstance3D ->
  GeometryInstance3D (all other uses are visible/global_position/
  global_transform — audited: player.gd + harness arms 7650/7718/24619).
  Renderer-independent by construction (the product ships on Windows; the
  dev pipeline is a llvmpipe proxy). MeshInstance3D.multi_mesh does not exist
  (the first attempt hit "Invalid access to property or key 'multi_mesh'" —
  that is the MultiMeshInstance3D.multimesh property).

## AC-0440 closeout

- FINAL STATE: fix in 3 files (settings.gd +17, player.gd +124/-13, menu.gd +29);
  harness.gd byte-identical to HEAD (probe arm + function removed, one AC-0324
  comment line restored after the cut; git diff empty). Fenced files untouched.
- FINAL GATES (post-removal, all green): G0 EXIT=0 / SCRIPT 0 / SHADER 0
  (g0-pristine.log); SMOKE EXIT=0, battery ok=true, 25/25 GENHASH, 0 errors,
  interact highlight_visible=true (smoke-pristine.log); meshprobe ok /
  ac0211_ok (meshprobe-pristine.log); shaderforce not owed (no .gdshader).
- RENDERS (final API, all rc=0, Forward+/llvmpipe, 0 errors): 4 captures in
  tasks/AC-0440/captures/ (before/after at T=0.5 and T=0.25). Numbers:
  T=0.5 band 82.2->82.2, square interior 59.8->79.3 (ratio 0.727->0.965);
  T=0.25 band 15.5->15.5, interior 9.3->15.3 (0.600->0.986); wireframe line
  2 px (x=580-581/698-699); collateral diff bbox exactly (580,322)-(700,442)
  in both hours. Seam twin A/B byte-identical (pre-fix vs fix), final-tree
  180 pairs / 145 level / 135 exact / max level step 0.9216.
- HARVESTED into godot/OPS.md §6: (a) wireframe flag ignored on this
  Forward+/lavapipe path (measured, red A/B); (b) this build's MultiMesh is
  the Godot-3-style API (mesh not base_mesh, instance_count, material on the
  base mesh, get_instance_transform read-back returns identity).
- DELIVERED: plan.html, AC-0440-results.html (self-contained, captures
  linked), this journal, .scratch/AC-0440/ (logs, scripts, twin JSONs).
