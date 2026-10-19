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

## RUN - Mon Oct 19 08:32:04 EDT 2026 - AC-0433 run 2
- STAGE: P0.5 (per plan.html + the run-1 findings F3/F4) — the face re-bake ordering gap (a face chunk's home edge reads a BUILD-TIME ring snapshot; a straddler that lands after the face build is never re-baked) + the jump-band straddler stall (the tier-0/1 _build_ready 8-neighbor gate demands data from fully-past-patch stubs that never hold data — AC-0309 D2). Both named in the plan; taking them in order. Read first: continuity.md, plan.html, ticket notes (TASKS.yaml AC-0433), godot/CONTINUITY.md top checkpoint (r26), ARCHITECTURE.md (AC-0309 two-models + crossface sections), world/AGENTS.md, gdext/AGENTS.md, HARNESS.md (recipes §4, gates §5, render §2, standing §3), OPS.md.
- OUTCOME: **STAGE PROVEN, naturally.** plan.html updated up front (P0 row = landed; P0.5 made an EXPLICIT
  stage row with its own evidence column; new §5 "What run 2 lands"; §5→§6 renumber; F3/F4 annotated).
- LANDED (GDScript only — no C++, no .so rebuild):
  - world.gd `_build_ready` (F4): the 8-neighbor gate now SKIPS a neighbour `_chunk_past_patch` (fully
    past the patch edge). The dispatch ring construction at all four home sites already synthesizes that
    neighbour's ring (`_patch_edge_ring`, D2 — live face ring or solid ring, NEVER a defer); the gate and
    the dispatch previously disagreed (the gate demanded data the design says never lands). R ≤ 0 →
    `_chunk_past_patch` false → harness-arm behaviour unchanged.
  - world.gd (F3): `_face_rebake_boundary` (the home-EDIT call, AC-0309 C5) now ALSO fires from the three
    full-landing paths: `threadgen_handoff` (skip flag ≠ 2 — not a far landing), `_land_column` (not a far
    column), and the band-A `mat` TM handoff (first real slab data). Far landings carry no ring (payload
    H-only) and are excluded; their promotion lands through threadgen_handoff.
  - world.gd: `face_rebake_n` (World census) + per-chunk meta `ac0433_rebake_n`, incremented in the
    `if rebake:` block of `_face_rebake_boundary` — the per-chunk meta is what the probe reads (a sibling
    edge row's landing must not false-positive this chunk's natural flag).
  - harness.gd `_ac0433probe_test` section B reworked: captures the INITIAL-build state the frame the face
    FIRST meshes (`initial_ring_live`, initial bands, per-chunk counter base), then waits on the
    straddler's MESH (the loop break was already `hb or timeout` — now a HARD control, not best-effort),
    then reads the FINAL state with NO probe-side rebuild; `rebake_natural` / `manual_fallback` make the
    verdict mechanical. The run-1 forced `build_mesh_face` survives ONLY as a flagged last resort.
  - ARCHITECTURE.md: the AC-0309 cross-face bullet now states BOTH landing orders (the home-landing hook)
    + the `_build_ready` past-patch clause.
- PROBE r8 (site z0=68 face=4 iv=22, chunk "4:63:1", straddler "196,4"): face first meshes frame 2 with
  `initial_ring_live = false` — INITIAL state = the air-ring signature (home_edge [0.0, 0.0] extends
  nothing; side wall [0,0,186,876] full-height). Then the hook fires NATURALLY on the straddler's data
  landing: `rebake_natural = true`, chunk counter 0→3 (three straddler columns (196,3/4/5) each cross the
  49–98 m edge row), world census 4, `manual_fallback = false`. FINAL state (frame 20) = run 1's forced
  re-bake EXACTLY: home_edge [-0.47, -0.008], side wall [−0.47, 0, 186, 390] (the 0–6 m chasm ledge).
  Straddler: `home_mesh_built = true`, `home_build_ready = true`, `home_queued = "nq"` (run 1:
  false/false/"build" — stalled to the cap); its top face at the patch edge now visible
  (`at_edge [5.0, 6.0, 116]` — the sliver cell; run 1: empty). Section A byte-identical to run 1's
  r5/r6/r7. Both failure branches are negative-tested by construction (no hook → manual_fallback fires;
  no gate fix → timeout with home_queued "build").
- REGRESSION GUARD HOLDS: ac0423probe r2 — the full RESULT dict (ex wall-time) is BYTE-IDENTICAL to BOTH
  run 1's increment-tree log AND run 1's pristine-HEAD-.so log → chain pristine ≡ increment ≡ run-2 tree.
  Standing seam overlap: 654 / 752 / 660 / 662 / 758 / 848 / 800 / 1290 / 1290 mm — inside the standing
  654–1290 mm band to the mm.
- GENHASH: 25/25 byte-identical to the HEAVY-r22 reference — the genhash did NOT move (scheduling-only;
  no data-path change owed, none present).
- GATES (all RC=0 + census 0/0): G0 (g0-r5) ✓; ac0433probe r8 ✓; ac0423probe r2 ✓; genhash ✓; meshprobe
  match_rate 1.0 ✓; farab ok true (h_mismatch 0) ✓; boundary r4 ok true — built_final 68 (AC-0445 value),
  resident_final 93, footprint fence 0 unchanged; NOISE-CLASS finding: col_deferred 48→57, walk p95 35→37
  ms (frame-pacing census on a ~46 s live walk; contract fields untouched — reported, not re-baselined);
  seamcensus r5: the pre-existing RED (F6) is DATA-IDENTICAL to run 1 (only wall_ms differs) — provably
  neutral.
- ASSESSMENT (the coordinator's question): P0.5 is NOT cosmetic without P1 — the ring snapshot is a
  property of the sync build lane, not the placement rule; the hook stays the face lane's coherence
  mechanism through P1/P2. P0.5 does not touch the base split (the 1.7–3.7 m h=0 residual P1 removes).
  Stage ordering UNCHANGED; the only plan change = making P0.5 an explicit row.
- FILES: modified world.gd, harness.gd, ARCHITECTURE.md, plan.html, continuity.md, AC-0433-results.html
  (new §8, self-contained). NEW captures (name them for the scanner): g0-r5.log, probe-r8.log,
  ac0423probe-r2.log, genhash-r2.log, meshprobe-r2.log, farab-r2.log, boundary-r2.log, seamcensus-r5.log;
  results.json appended with the `ac0433probe_run2_p05` section. Scratch: .scratch/AC-0433-gates/.
- EXIT: my gates done. Next run = **P1 (design stage)** per plan §3: the unified footprint (every column
  extrudes along its own radial) — seam algebra on paper + probe BEFORE code (candidate (c)); the P0.5
  machinery (K-table consumer, landing hooks, gate) is the substrate it lands on. Still owed (not this
  ticket): the seamcensus rebaseline ticket (F6, coordinator's queue) + the coordinator's heavy set
  (crossface 20-min arm) on this tree. No render owed this run (the re-bake geometry = run 1's measured
  geometry; a render is a P2 concern when the placement itself moves).
