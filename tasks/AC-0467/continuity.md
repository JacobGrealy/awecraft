## RUN — 2026-10-21 05:04 EDT — AC-0467

- single MEDIUM builder, stage A: home canonical placement behind AWECRAFT_WARP_HOME (default OFF).
- contract: tasks/AC-0467/plan.html. Template applied.
- EDITS DONE (pre-gate): mesh.cpp warp_home_verts + bind (native build 7.1s, .so -> godot/bin);
  chunk.gd (_warp_home flag default OFF, _warp_home_slabs + _warp_home_cell_point +
  _warp_home_slab_footprint_aabb, build_mesh branch, occluder degenerate fallback extended);
  world.gd (_warp_home_on in _ready, identity node in _make_chunk_node, canonical _view_basis);
  harness.gd homecensus arm; harness_data.yaml row + doc render;
  tasks/AC-0467/seam_band_flagon.gd (flag-ON-aware copy of the AC-0434 probe) +
  tasks/AC-0467/seam_render.gd (gate-d render); runners in .scratch/AC-0467-gates/.
- GATE (a) flag-OFF set started via gate_run.py (job bash-1179): g0,smoke,genhash,ac0423probe,faceedit,planetwalk,homecensus.
- FIX: Transform3D.is_approx_identity() does not exist in Godot 4.7.1 (neither does .is_identity()
  on Transform3D) — the working identity check is
  t.is_equal_approx(Transform3D(Basis.IDENTITY, Vector3.ZERO)) (verified with a -s probe).
  Applied to harness.gd (2), seam_band_flagon.gd (4), seam_render.gd (2).
- seam_band_flagon.gd FLAG-OFF self-check: rc=0, S1 within 0.5 mm of all nine standing values,
  per-cell overlap 602.4-730.4 (mean 656.1), crack 506.3-634.3 — the AC-0434 baseline reproduced
  (copy is faithful). Log: seamband-off-r1.log.
- GATE (a) flag-OFF (job bash-1180): ALL ARMS OK. g0 0 script errors; smoke 5/5
  (player sprint_ok, interact place_ok, light, fluids); genhash 25/25 (0 diff vs
  AC-0466/AC-0465 rebase refs); ac0423probe nine EXACT: 654/752/660/662/758/848/800/1290/1290;
  faceedit ok (surface_error_m 0.578); planetwalk ok; homecensus BASELINE: flag_on=false,
  n_corners=153, min 558.123 mm, mean 1625.269 mm, max 8020.576 mm (mean/max inflated by corners
  with REAL height steps — both sides share the step; the seam error is the ~558 mm flat-corner min).
- GATE (b) flag-ON (job bash-1181) started: same arms + AWECRAFT_WARP_HOME=1.
- BUG FOUND + FIXED (stage A first-pass miss): the home-lane LIVE build is the C++ worker
  pool (world.gd:7641 mc.build_accs) + handoff apply (apply_accs/apply_edit_accs at
  8060/8152/8152/8219/8286) — NOT chunk.build_mesh (the sync fallback / test-arm path only).
  The first-pass warp in build_mesh never ran (warped_chunks=0; the world-bounds dump showed
  the identity node wearing a LOCAL-space mesh — col (1,0) rendered at world x [0,16.9]
  instead of [16.3,33.2]). The flag-ON gate (b) run before this fix is INVALID (its
  interact place_ok=false and the seam-band copy's 15-32 mm... 15000-32000 mm "overlaps"
  are the misplacement, not the extension). FIX: new _warp_home_apply(res) — guard
  `_warp_home and int(face) < 2` — called at the top of BOTH apply_accs and apply_edit_accs
  (every home build lands through them: worker full/per-slab/edit/band-A mat + the sync
  fallbacks); the build_mesh block removed (that line is exactly the shipped one again).
  Face lane excluded (face >= 2 warps in build_mesh_face — no double warp). Flag off:
  the condition is false — no changed arithmetic, no reordering. VERIFIED by the dump:
  col (1,0) world x [15.93, 33.76], col (0,0) [-0.63, 17.18] (radial scale 1+ly/R +
  extension), warped_chunks=2, warp_verts=7128, warp_us=369 (native).
- KNOWN LIMITATION (flag ON only, far view): the far-tier home chunks' LOW avg-LOD
  placeholders (low_instances, band B/C) are attached in local space against the identity
  node — misplaced ghost geometry >~1 render radius out under the flag. Near view (all
  gate sets) is correct. Not in the plan's scope (stage B owns the flag flip + the low
  path); recorded in deviations.
- GATE (a) flag-OFF re-run (job bash-1182) in progress; then (b) flag-ON, (c) seam band,
  (d) renders.
- GATE (a) flag-OFF re-run (post-fix): ALL GREEN, byte-identical to pre-fix —
  g0 0/0; smoke player(sprint)/interact place_ok=true/light/fluids ok; genhash 25/25
  (0 differing vs AC-0466 ref — genhash_parity.log); ac0423probe nine EXACT
  654/752/660/662/758/848/800/1290/1290; faceedit ok (0.578/0.397); planetwalk ok;
  homecensus baseline min 558.123 / mean 1625.269 / max 8020.576 (153 corners).
- GATE (b) flag-ON (post-fix): ALL GREEN — g0 0/0; smoke ok (interact place_ok=false
  = flat-aim artifact, deviation 4); genhash 25/25 (0 differing); ac0423probe ok
  (transform-based readout degenerate under identity, expected); faceedit ok
  (0.578/0.397, place_ok=true, warp=1); planetwalk ok both crossings;
  homecensus COLLAPSE: min 0.0, mean 1228.741, max 8000.319 (the true 8 m step),
  all 153 corners, node identity asserted.
- GATE (c) seam band (copy, axis-fixed + exact-inverse inverse-warp):
  OFF  = 602.4..730.4 mm (mean 656.1), crack 506.3..634.3 (reproduces AC-0434,
          S1 <= 0.5 mm — faithful instrument).
  ON   = 1212.3..1349.3 mm (mean 1261.8), crack -64..+64 (mean -3.3) —
  crack COLLAPSED, E unchanged (ext. still fires, static K tables), overlap
  WIDENS. Original probe flag-on: crack = -16000.0 mm uniform (identity
  degeneracy), S1/S3 fail — degenerate as predicted.
- GATE (d) renders: tasks/AC-0467/render_off.png + render_on.png (same seam cell
  [16,139,8] top 139/139 flush, was_id 1->2, camera (0,155,8) straight down,
  player on line; OFF nodes transformed [false,false], ON identity [true,true]).
  What changed: the seam line (vertical, slightly right of centre) is a soft
  near-invisible transition in the OFF render; in the ON render it is a sharper,
  clearly visible vertical tonal band (~1.3 m double-covered extension band +
  radial displacement of the top faces). Everything else (block, HUD, terrain,
  step at left) identical. Both renders are dim (time 0.25 ambient).
- DEVIATIONS written (tasks/AC-0467/AC-0467-deviations.txt, 9 items: build-lane
  fix, seam band widens not narrows, original probe degenerate, interact
  flat-aim, far-tier low placeholder, WARP=0+WARP_HOME=1 combo, Windows .dll,
  ARCHITECTURE.md, render settle drift).
- BUILD: original 7.1 s (recorded in native_build.log) + no-op re-verify
  "libchunkio.so is up to date" (no relink; .so untouched, mtime 05:39).

## Coordinator triage — stage A landed, and it proves the placement AND that the flip must wait for stage B
- THE PLACEMENT WORKS, verified by my own runs of `homecensus` in both flag states: with the flag OFF the shared-corner error has a floor of **558.1 mm** (a whole seam, `z16_xm16`, sits at 566.4 mm on all 17 corners); with the flag ON that same seam reads **exactly 0.000 mm on all 17 corners** and the global minimum goes 558 -> 0. That is the canonical placement doing precisely what it should: two adjacent columns evaluating the same shared edge point agree to the bit.
- READ THE MAXIMA CAREFULLY, because they are not placement error: `max_mm` is 8020 off and 8000 on, and the builder's note ("max = true 8 m step both") is right — the census spans corners that sit on genuinely different terrain heights across a seam, so a large distance there is the WORLD, not the placement. The correct summary statistic for this question is the minimum and the per-seam floors, which is why the 566 -> 0 seam is the evidence rather than the mean.
- THE FLIP MUST NOT HAPPEN YET, and the builder's own honest answer to gate (c) is why: the seam band does not collapse, it WIDENS from 602-730 mm to 1212-1349 mm, because the crack has gone to ~0 (-64..+64 mm) while the static K-table extension still fires at full width. The renders confirm the consequence: the same seam cell goes from a soft near-invisible transition to a sharp visible vertical tonal band. So canonical placement alone makes the user's complaint WORSE, exactly as predicted: the extension was compensation for a crack that no longer exists, and un-compensated it is pure overshoot.
- THEREFORE STAGE B IS THE REAL DELIVERY and stage A is its prerequisite: delete the extension apparatus (K tables, ring reads, sphere_r, margins, clamp) in the same landing that flips the default, and re-measure with seam_band_probe + the render pair. Do not flip the flag alone on any argument about intent.
- STANDING GUARDS HELD EXACTLY: genhash 25/25 in BOTH flag states, and flag-OFF ac0423probe reproduces all nine overlaps byte-identically (654/752/660/662/758/848/800/1290/1290), so the shipped lane is untouched. faceedit 0.578/0.397 and planetwalk both still green with the flag on.
- OPEN DEVIATIONS THAT STAGE B MUST NOT INHERIT SILENTLY: the far-tier low LOD is misplaced when the home warp is on; the Windows .dll was not rebuilt; ARCHITECTURE.md is deferred to stage B; and `interact place_ok=false` under the flag is the documented pre-existing flat-aim artifact, not a new defect.
