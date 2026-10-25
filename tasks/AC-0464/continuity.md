# AC-0464 continuity

## RUN — 2026-10-25 09:20 EDT — AC-0464

Verify-first ticket: does the boundary chunk still render unlit black? Reproduce, then
cancel with evidence if gone, or localise (unlit geometry vs hole) if present. Steps:
3.1 aim arithmetic vs current grid/placement, 3.2 render + pixel-read, 3.3/3.4 branch.

## 3.1 — AIM ARITHMETIC (current tree, 2026-10-25)

- face_width(4000) = pi*4000/2 = 6283.1853 m; hw = 3141.5927 m (sphere_math.gd
  face_width/home_uv — the home pair (faces 0/1) still charts flat x in [-hw,+hw],
  z in [-hw,+hw]; AC-0467's canonical placement moves the PLANET frame, not the
  flat chart, and player_anchor (world.gd:15981) returns Basis.IDENTITY on the
  home pair, so flat coords are unchanged by the placement move).
- Aim x=3133, z=0: on face 0, 8.59 m inside the +hw boundary (3141.5927-3133).
  UNCHANGED gap — the boundary did not move in flat coordinates.
- 1 m grid (AC-0469/0471): cell = 6283.1853/6283 = 1.000 m; x=3133 is exactly a
  cell boundary (column 3133). Chunks = 16 m (>>4): aim in col 195 [3120,3136);
  the boundary x=hw falls in col 196 [3136,3152) at 5.59 m into it — the first
  column right of the aim straddles the boundary (home pair ends at x=+hw;
  beyond it are face-lane charts).
- View: yaw 0 = local -Z at the identity anchor (Godot camera forward) => looking
  ALONG the x=+hw edge, 8.59 m from it, pitch -0.4 rad = 22.9 deg down, eye y=60.
  FOV 75 deg (82.5 while flying). R=4 band = 81 chunks x 16 m; the boundary is
  8.59 m away — deep inside the band.
- VERDICT: x=3133,z=0 yaw 0 is STILL a boundary view. No aim change needed.

## HOOKS CHECK
- AWECRAFT_AIM (main.gd:935), AWECRAFT_TIME (main.gd:134,1022), AWECRAFT_SIZE
  (main.gd:126), AWECRAFT_NOCLIP (harness.gd:3534), AWECRAFT_RADIUS
  (main.gd:264), AWECRAFT_SNAP_DRAIN (main.gd:982), AWECRAFT_SNAPSHOT
  (main.gd:123) — all present.
- The flag AWECRAFT_WARP STILL EXISTS (chunk.gd:1740 _warp_on, default on; the
  off-switch is =0) — so the same flag pair is rendered.

## LANDED — measurement complete (no code change, per plan 3.3)

- Rendered the recorded recipe verbatim on the current tree, both flag states
  (AWECRAFT_WARP still exists, chunk.gd:1740): tasks/AC-0464/captures/rerun-flagoff.png
  (WARP=0) and rerun-flagon.png (WARP=1), Forward+ llvmpipe, zero script/shader
  errors, ~4-5 min each.
- The filed black block (lower right, x[~800..1100] y[~460..720]) is now LIT gray
  stone in BOTH reruns: filed mean (45,53,55) / 79% dark px / corners ~(20,21,21)
  -> rerun mean (149,155,157) / 0 dark px / corners (153,153,154)/(143,144,144)/
  (137,137,137). Flag pair: full-frame mean abs diff 0.00, 0 pixels > 30 apart.
  No other dark region in either frame. DEFECT GONE — ticket closes as CANCELLED
  on these numbers. Most plausible remover: AC-0463 L6 (face builds now consume
  the star payload instead of the documented empty own-column pull — the exact
  zero-light path for boundary face chunks); AC-0469 E the alternative.
- Deviations: tasks/AC-0464/AC-0464-deviations.txt (aim height below the current
  surface h=153 — same vantage as filed, frames match; aim flat position still
  8.59 m inside +hw = boundary view; BCELL read via existing hook).

## GATES — all green (gate_run.py AC-0464 --arms g0,genhash,lightstate --timeout 900)

- g0 r1: rc=0, 0 SCRIPT ERROR, 0 SHADER ERROR (3 s).
- genhash r1: 25 GENHASH lines, BYTE-IDENTICAL to the current-tree reference
  (.scratch/AC-0478-gates/genhash-r1.log — the newest prior run; the AC-0367
  pristine log is stale pre-1m-grid-rebase), GENMS 132. 25/25.
- lightstate r1: rc=0 ok=true, leaks 0 on all 20 grid chunks, wash_detected
  false, ab arr_diff_cells 1 @ [0,141,0] (the standing re-baselined value),
  double-LOD 0/0, stragglers 3 (machine-timing class, not a gate).
- No code touched anywhere (verification only).
