## RUN — Sat Oct 24 12:21:47 EDT 2026 — AC-0295
Reproduce-first on current tree: standing-still radius-lower orphan count, then travelling.

## LANDED — Sat Oct 24 12:44:26 EDT 2026 — AC-0295
BEFORE probe (current tree, no fix): STANDING 596 orphans (flat over 25 s), TRAVELLING 13 (596 -> 13 after 128 m walk; the 13 = the walking hysteresis trailing ring at the two_out edge, taxi 7-8 vs the 96 m window — normal-play residue, not radius-change orphans). Face lane 0/0 in both phases (its window is sim_dist-based).
FIX LANDED in godot/world/world.gd: (1) _resident_sweep gains bypass_travel_gate (default false — normal cadence untouched); (2) new force_resident_sweep() = the home pass as event #2 with the gate bypassed for that call only (cap + deferred drain unchanged); (3) note_render_distance calls it on a real value change (the Options path; the recenter it follows is event #1, cand 0->1; the forced pass makes cand 2 = free). Standing policy + travel-gate threshold untouched: the bypass fires only from the explicit settings event, never during ordinary standing.

## GATES — Sat Oct 24 12:58:17 EDT 2026 — AC-0295
All gates green (consolidated run, .scratch/AC-0295-gates/*-r3.log + g0-r4.log):
- ac0295 probe (after fix): STANDING 0 (drain [144,0,0,...,0]), TRAVELLING 7 (hysteresis ring), face 0/0; before fix (ac0295-r1.log): STANDING 596 flat, TRAVELLING 13.
- residency (fixed position, no radius change): ok true, leak FALSE, steady STABLE (92/74 plateau, converged, keys_same) — standing policy intact.
- g0: 0/0 (r3, with fix + probe; r4, after probe removal — final tree).
- genhash: 25/25, chunk (0,0) 46c20b07... = the standing AC-0367/AC-0311 reference.
- planetwalk: ok true, 25/26 derived boundary pairs covered with mesh and body (the documented home_pair_midline waiver).
- boundary r4: ok/marker_ok/remesh_ok true, p95 38 (recent band 34-42), p50 13 flat, col_deferred_in_footprint 0.
Probe arm REMOVED (harness.gd back to 39937 lines, 0 ac0295 refs). Deliverables: AC-0295-results.html, continuity.md, AC-0295-deviations.txt. No git, no registry, no new tickets.
