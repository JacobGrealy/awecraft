# AC-0433 continuity (append-only)

## RUN - Mon Oct 19 02:13:49 EDT 2026 - AC-0433
- Fresh start (no prior entries in this file; tasks/AC-0433/ did not exist).
- Read in order: ticket notes (TASKS.yaml AC-0433, in full), godot/CONTINUITY.md top checkpoint (r26, 2026-10-08),
  godot/ARCHITECTURE.md (two-models sections: home per-column facets ~990-1030, non-home LSQ faces ~1104-1146),
  tasks/AC-0423-results.html, tasks/AC-0425-results.html (C4 + R1 standing values), godot/world/AGENTS.md,
  gdext/AGENTS.md, godot/HARNESS.md (all five sections), godot/OPS.md.
- Plan for this run: MEASURE the hypothesis (lean-term decomposition of the 2.19 m crossing row / 3.73 m corner)
  BEFORE any design; confirm the live defect (build_mesh_face carries no sphere_r); write plan.html;
  land one self-contained increment; gates G0+census+exit, SMOKE, PROBE, genhash, farab, boundary r4.

## RUN - Mon Oct 19 (run 1, first increment) - AC-0433
- MEASURED (probe r5, deterministic, seed = Game.world_seed): offset(h) = offset(0) + h·(n_face − n_home) exact.
  The 2.19/3.73 m splits are h=0 BASE splits (crossing 2.704 @ f4 iv536 ≈ AC-0425 2.7037; corner 3.732 @ f4 iv1000
  = standing f_seam_max 3.732444); lean is additive (home/home ds0 0.002 m + 0.004/m = 16/4000; face/face ≈1 mm
  + u 0.02454/m, v 0.01227/m; worst ch168 full 5.631 @ f4 iv979). VERDICT: hypothesis refuted as literally
  stated (they are not frame-lean) — plan.html §1. Live defect confirmed: 10 of 12 faces (2–11 sync-only
  build_mesh_face, no seam-V arming; ticket's "11" off by one) — all edge bands nominal at site "4:63:1".
- LANDED (first increment — face-lane seam-V extension + the ring fix):
  - sphere_math_cpp.h: SM_FIT_INV + sm_face_mirror_x + sm_face_chunk_transform moved into namespace awesm
    (verbatim; scaled-basis NOTE); gen.cpp defs removed (one usage via `using namespace awesm`).
  - mesh.cpp: Ctx +face/seam_v_max/fec[4]/fen[8]/feh[64] (copy_ints; plain Arrays — negative hcx/hcz);
    SeamExt.scale[4]/max_v; seam_ext_at = clamp(E,[0,max_v])/scale (home /1.0 exact);
    build_seam_ext: shared ring_top lambda (verbatim move) + `C.face >= 2` face path (unified dot-product
    form of the four home K formulas, hand-verified term-for-term; K0/K1 WORLD metres; home-edge table
    per-cell via feh; class 0/1/2 gate — synthetic-solid edges never extend);
    **parse_nbs: raw-PBA branch (FINDING→FIX)** — the dict-only check silently dropped the bare compact
    rings (_face_home_ring/_solid_ring/_patch_edge_ring/_home_face_ring store PBAs bare) → neighbour read
    as air → full-height boundary walls. Measured A/B at the home/face seam: pre-fix 0→186 m wall,
    886 wall verts; post-fix 0–6 m chasm ledge + top rows extended past the footprint.
  - world.gd: _face_edge_kind (one source of truth: mirror + home-edge + neighbour residency), _face_rings
    refactored onto it (rings unchanged), _face_edge_meta (the ctx arrays, dirs in C++ k order
    [-x,+x,-z,+z]; home array mirrors _face_home_ring resampling).
  - chunk.gd: build_mesh_face ctx sets sphere_r = Game.planet_R, face, seam_v_max = 6.0, face_edge_*.
  - harness.gd: ac0433probe arm kept standing (probe-class, no harness_data.yaml row — ac0423probe
    precedent): section A (deterministic decomposition + controls), section B (live site z0=68 f4
    "4:63:1" + straddler "196,4": edge-band census, seam-row tops, side-face wall census, POST-REBAKE
    re-read — the home ring is a snapshot at build time; the straddler's data lands later, so the
    home edge extends nothing until a re-bake — the face re-bake gap = P0.5/P2; re-bake read proves the
    mechanism: home_edge [−0.47, −0.008] ≈ 2.9 m past the footprint once the ring is live).
- POST-FIX PROBE r6 (site "4:63:1"): initial build extends only v_seam_s (only that ring live at build
  frame); re-bake extends all: u_seam +4.4–4.6 m, v_seam_n +1.7–2.8 m, v_seam_s −1.8–2.9 m, home_edge
  −0.05–2.9 m; section A byte-identical to r5 (deterministic). A/B pre-fix (r7): all bands nominal + the
  186 m wall — the before/after table in the results page.
- GATES (all RC=0 + census 0/0): G0 g0-r3 ✓; ac0433probe r6 ✓ + r7 A/B ✓; genhash 25/25 vs HEAVY-r22
  reference (bit-identical — mesh-only change did not move generation; the AC-0367 log is the stale 0/25
  trap) ✓; ac0423probe: pristine-HEAD .so ≡ increment .so (every field), standing overlap 654–1290 mm to
  the mm; old baseline's fine counts drift (pre-existing, F5) ✓; meshprobe match_rate 1.0 (1878/1878) ✓;
  seamcensus r4 RED — PRE-EXISTING (fixture 32/44 byte-identical to the AC-0430-era run; documented in
  AC-0430 results as the AC-0427 extension vs AC-0423-rebased census, rebalance owed to AC-0427 closeout —
  F6; my increment provably neutral); farab ok true ✓; boundary r4 ok true (built_final 68 = AC-0445 value;
  the walk streams the face window so the refactored _face_rings ran in-gate) ✓.
- SCons on this box: `python3 -m SCons` broken (no module, PEP 668, no ensurepip) → `pip3 install -q
  --target .scratch/scons-target scons` (4.11.1) + `PYTHONPATH=.scratch/scons-target python3 -m SCons -C
  gdext platform=linux target=template_release` + cp to godot/bin (F7 — OPS.md harvest candidate).
- Docs: ARCHITECTURE.md updated (placement bullet — face-lane arming; cross-face bullet — the
  "unfiled concern" note → filed as AC-0433 + the ring-drop wall, measured).
- EXIT: my gates done. Remaining = the coordinator's heavy set (crossface 20-min arm) + closeout.
  Run 2: P0.5 (the face re-bake ordering gap + the jump-band straddler stall — the home-edge extension
  is only as good as the ring at build time) → P1 (the unified placement design) per plan.html §3.
