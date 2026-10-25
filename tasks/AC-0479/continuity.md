## RUN — 2026-10-25T14:02:46Z — AC-0479

RUN notes (2026-10-25, mid-run):
- Mechanism located in code (before any measurement): the aim box is placed
  by position only with an IDENTITY basis (player.gd:3176-3192,
  `_update_interaction`); the box geometry is axis-aligned (`_aim_wire_t`
  player.gd:1164); but the mesh AND the collision consume the per-vertex
  home warp (chunk.gd `_warp_home_apply` runs before `_assemble_slab` and
  `_post_build_collision` derives the ConcavePolygonShape from the warped
  mesh — AC-0461 verified, not assumed). `world_pos_of_flat` is the RIGID
  PER-COLUMN FACET map (sphere_math.gd:419-424 `flat_to_world`), while the
  mesh warp is the exact spherical projection (chunk.gd:1941
  `_warp_home_cell_point`). The player's up is the exact radial
  (player.gd:3388). R = 4000, so the warp slope at distance D is D/R.
- Temporary measurement arm `aimslide` added to harness.gd (dispatch after
  voxelcost + `_aimslide_test`/`_aimslide_find_site`/`_aimslide_at` at the
  file tail). MUST BE REMOVED AT CLOSEOUT (pristine rule).
- r1: rc 127 (engine path was $HOME/tools/godot with HOME=/tmp/dsh_home —
  the engine lives at the real home /home/angrygiant/tools/godot/godot;
  gate_run.py uses Path.home() for the engine and /tmp/dsh_home for the
  engine's HOME — they are different values).
- r2: two parse errors in my probe (rad2deg -> rad_to_deg; `:=` on the
  untyped surface_top return) and one runtime error (Vector3-Vector3
  assigned to a Vector2 in the walk section); site finder found no dry
  flat ground in the +x-only rings 140-165/285-315 (spawn top 140 is only
  14 m above SEA 126 — that side of the world is ocean at seed 44).
- r3: finder rewritten (16 directions x 1 m steps, bands 140-260/280-420,
  dry_seen diag), it2 fixed. RUNNING.
- Standing values for the gate (interact arm): place_ok is a KNOWN
  arm-timing flake (coordinator note: ~0.583 s sim dt in a 3 s window vs
  dirt's 0.6 s need) — do not chase it as a regression.
- FINDING (durable): `WorldGen.terrain_height` (godot/world/generator.gd:76)
  is the OLD 2D probe kernel (three AweNoise.fbm2 calls). The LIVE C++
  surface_h (gdext/src/gen.cpp:1038) is a coarse-3D-field trilinear
  formula with a calibration remap (0.4219 + (c-0.3681)*(0.1280/0.0467)
  etc.). Measured divergence r6: 8/10 analytic candidates rejected
  against the live grid, 3..23 m both directions. Use the live grid
  (the streamed band) for any site selection — never the mirror.
- Probe r5/r6: site search rebuilt (analytic -> live band search); the
  box metrics' corner matching was tangential-only (degenerate: the
  vertically opposite corner has the same tangential distance) — now
  full Euclidean nearest-corner. r6 spawn numbers (pre-fix, gate a):
  D=11.3 m, center_offset 24.8 mm, corner_tangential_max 37.1 mm,
  corner_radial_max 11.9 mm, box_up_vs_block_up 0.172 deg (= D/R),
  topface_tilt 0.153 deg, stand drift 0.0 mm/s (AC-0420 damper active),
  walk veer 0.0485 deg / 3.93 m/s.
- r7/r8 (pre-fix, gate a MAGNITUDE TEST, CONFIRMED): the box error GROWS
  with the warp magnitude (D/R):
    spawn D=11.3 m : center 24.8 mm, corner_tang 37.1 mm, box_up 0.172 deg
    farA  D=153 m  : center 264.2 mm, corner_tang 296.1 mm, box_up 2.316 deg
    (264/25 ~ D ratio; 2.316/0.172 ~ D ratio 13.5) -> hypothesis CONFIRMED.
- r8 xray: at farA hl_origin == facet_center (world_pos_of_flat) and the
  warped (home_point sphere) centre is 26 cm away -> the facet map is the
  box placement and the sphere is the block; the gap IS the misalignment.
- FINDING (durable, out of scope): the per-column rigid facet net
  (world_pos_of_flat) diverges from the home_point sphere by metres at
  large D (farB D=310: the player's warped-station position reads back as
  flat y 158.6 vs the block-grid top 159.0, a ~0.4 m round-trip gap; the
  aim-box/teleport machinery that uses the flat frame is only trustworthy
  near spawn). The 4.1 fix removes the BOX's dependence on the facet map
  (it now uses the exact sphere construction) so the box is right at every
  D; the flat-frame aim DDA / teleport divergence is a separate, larger
  issue (the flat frame itself), not the box.
- r9 (POST-FIX, gate b): the box now matches the warped block 1:1 at both
  home-patch magnitudes (residuals = the designed 1.02 overhang + the
  straight-box-vs-curved-wedge second order):
    spawn D=11.3 m : center 0.0 mm, corner_tang 10.9 mm, box_up 0.013 deg
    farA  D=153 m  : center 0.1 mm, corner_tang 15.5 mm, box_up 0.162 deg
  (before 24.8/37.1/0.172 and 264.2/296.1/2.316). stand drift unchanged
  0.0 / 0.68 mm/s (uphill noise) — the fix is visual only, physics
  untouched. farB (D=310) is a BROKEN probe site (player embeds in the
  block, walk frozen, highlight stale) — not a valid fix measurement.
- 4.2 slide: no physical standing/walking slide measured at either
  magnitude (stand <= 0.71 mm/s, residual UPHILL = numerical settling,
  below the AC-0420 0.2 m/s damper band; walk veer 0.007 deg at farA, far
  under the ~2.5 deg terrain-noise floor). The damper-widening candidate
  is NOT triggered (needs non-zero DOWNHILL stand drift). The user's
  perceived "slides the way the block is angled" is the box/facet tilt vs
  the warped terrain — the box now aligns with the terrain (4.1). No
  friction/speed/damper change (per contract).
- GATES (post-fix, harness.gd PRISTINE — probe removed, byte-identical to
  HEAD): g0 rc=0 script=0 shader=0; genhash 25/25 byte-identical to the
  recorded reference set (the AC-0400 smoke-genhash set; the AC-0367 note
  in HARNESS.md predates a later rebase); player smoke ok (sprint_ok=true);
  light + fluids at standing values (sea_stable, cave census unchanged);
  interact place_ok=false/drop_spawned=false with prog_max 0.9722 = the
  documented mine-timing flake (HARNESS.md: "~0.972 in every run; true in
  one run and false in the next") — "still as recorded", NOT chased.
  gate_run: AC-0479 all arms ok, RC=0.
- Deliverables: AC-0479-deviations.txt (D1-D6), AC-0479-results.html
  (gate tables + before/after tables + captures), snap-{before,after}_
  {spawn,farA}.png copied into this folder, .r7.json/.r9.json (the
  before/after RESULT JSON). All logs under .scratch/AC-0479-gates/.
- CLOSEOUT STATE: only godot/player/player.gd is modified in the tree
  (the 4.1 fix, +41 lines). harness.gd pristine. No git add/commit/push
  (coordinator's job). TASKS.yaml was flipped open->in-progress by the
  coordinator at 10:00 (not this session).
