## RUN — Tue Oct 20 09:26:32 EDT 2026 — AC-0458

LANDED (2026-10-20): AC-0458 in place per plan. godot/world/chunk.gd: added
`static var _warp_on` (env AWECRAFT_WARP == "1", default OFF, resolved on first
use) + `_warp_face_slabs(res)` (plan §3.2: pointwise rewrite of every vertex of
every slab array from chunk-local metres to world metres on the legacy 1024
chart, chart = exact inverse of SM.face_local_x — mirror class uses the
continuous inverse u1024 = ccx*16 + 16 - lx, see AC-0458-deviations.txt item 1;
normals untouched per plan §3.2; face<2 guard logs one line and skips per
§3.3). build_mesh_face calls it between mc.build_accs and apply_accs only when
the flag is on, then forces position/basis identity. No other file touched in
godot/. Probe written: tasks/AC-0433/warp_probe.gd (pure SphereMath, faces
2..11 × 2 adjacent chunk pairs, 17 shared-edge vertices each, warp vs legacy
contrast, one-cell v negative control).

GATES + OUTCOME (2026-10-20): ALL THREE PLAN §4 GATES GREEN.
(1) Flag-OFF light set (gate_run.py AC-0433 --arms g0,smoke,ac0423probe,
logs .scratch/AC-0433-gates g0-r12/player-r8/interact-r8/light-r8/fluids-r8/
genhash-r10/ac0423probe-r11, copied to .scratch/AC-0458-gates/): every arm
rc=0, SCRIPT=0/SHADER=0; genhash 25/25 byte-identical to the AC-0433 r9
reference (diff empty); ac0423probe RESULT equal to
tasks/AC-0433/captures/ac0423probe-r2.log excluding ms, nine overlaps
654/752/660/662/758/848/800/1290/1290. Shipped path byte-identical: proven.
(2) Flag-ON same arms with AWECRAFT_WARP=1 (r13/r9/r11/r12 set + interact-r10
rerun): every arm rc=0, SCRIPT=0/SHADER=0; genhash 25/25 byte-identical
(generation-only). Non-ms values did NOT deterministically move: ac0423probe
byte-equal (it inspects home-lane chunks, untouched by the face-lane warp),
light/fluids differ only in ms; interact place_ok is a flaky arm (false in
9 of the last 10 runs across both flag states — see AC-0458-deviations.txt 3).
(3) Warp probe (.scratch/AC-0458-gates/warp-probe.log, rc=0, gate_census
0/0, R=4000.0 from Game.planet_R): ok=true, pairs=20, warp_max_gap_m=0.0
(EXACTLY 0 as expected), legacy_max_gap_m=0.450873 (gate >0.1 met; the plan
§3.4 "order 1-2 m" text is for terrain height — measured at h=0 per the
M1 finding, see deviations 4), negative_detected=true, negative_gap_m=
6.135892 (exactly one chart cell, as designed).
OUTCOME: acceptance met — flag off: nothing moves (standing gates); flag on:
face-lane shared edges evaluate to the same chart point across chunk joins
(probe), legacy contrast + negative control in the log; AWECRAFT_WARP is the
only thing standing between the game and the new placement. No structural
change (no ARCHITECTURE.md update owed: no new autoload/subsystem/format).
Deliverables: AC-0458-results.html (results_page.py), AC-0458-deviations.txt
(4 findings), logs under .scratch/AC-0458-gates/ (summary.json merged).
Next per plan §8: AC-0459 (canonical keys + save bump).

## Coordinator triage — AC-0458
- H1-H6: clean. Independent rerun of warp_probe.gd: rc=0, SCRIPT=0, SHADER=0, RESULT identical to the builder's — pairs 20, warp_max_gap_m 0.0 (exactly), legacy_max_gap_m 0.450873, negative fired at 6.135892 m.
- MY PLAN WAS WRONG ON THE MIRROR AND THE BUILDER CAUGHT IT: §3.2 specified u = (iu + frac)/1024 with a per-cell floor(lx), which on mirror faces is a per-metre sawtooth (a one-chart-cell fold at every local metre). The builder implemented the continuous inverse of SM.face_local_x instead (u1024 = ccx*16 + 16 - lx on mirror faces), which agrees with the plan on non-mirror faces and at every cell centre and makes the seam gap 0. Recorded in AC-0458-deviations.txt; this is the second time in this series that a plan-level geometry detail was wrong and the builder refused to implement it blindly.
- Flag guard inspected by hand: both warp lines sit inside `if _warp_on`, so the shipped path executes the identical code as before — which is why the flag-OFF gates reproduce the standing values byte-for-byte (genhash 25/25, ac0423probe equal incl. the nine overlaps).
- HONEST ACCEPTANCE GAP, carried forward deliberately: with the flag ON the algebra is proven and nothing crashes, but NO ARM EXERCISES FACE-LANE GEOMETRY VISUALLY — the flag-ON light set moved nothing because ac0423probe reads the home lane and light/fluids report timings. The rendered result, and the identity-transform consequences (culler AABB, occluder box, low-LOD, collision still node-local), belong to AC-0460 and AC-0461 by design. This ticket does NOT claim the game looks right with the flag on; it claims the placement algebra is exact and that the switch exists and defaults off.
- `interact` place_ok=false appears in 9 of the last 10 runs across BOTH flag states, so it is pre-existing flake, not caused here.
- AC-0458 closes as: placement slice landed behind an off-by-default flag, seam algebra exact, shipped path provably unchanged. AC-0460 is the ticket that must make the flag-ON world actually render correctly.
