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

## RUN - Mon Oct 19 09:35:10 EDT 2026 - AC-0433 run 3

## RUN — Mon Oct 19 11:43:11 EDT 2026 — AC-0433 (P1 validation, medium, resume from run-2 OUTCOME)
- LANDED (P1 validation instrument only — no production edits, per plan §2/§7):
  - tasks/AC-0433/p1_probe.gd (NEW): standalone SceneTree probe, calls shipped SphereMath only.
    §3.1 grid (N=16*ceil(face_width(R)/2/16)); §3.2 canonical integer-cube-vertex Q with the
    face_for_dir tie order on raw Q + chart-inverse formulas (sphere_math.gd:129-144 on Q/N,
    NOT world_to_face(Q)); §3.3 all 12 cube edges at t=k/32 (33 pts/edge, 2N/32=N/16 integral),
    incident-chart grouping, one-cell neighbours, interior chunk (1,1)+adjacent vertices;
    §3.4 inverse round trips (fractions 1/8..7/8, h=0/140/168); §3.5 negative control
    (f0 t=0.5 boundary, h=168, one-cell shift); §3.6 old controls copied from _ac0433probe_test
    (home/home 4 sites, face/face 10+10 sites, home/face f4 iv1000); §3.7 one RESULT JSON,
    exit nonzero + HONEST DEVIATION on any tolerance fail.
  - Probe run #1 (draft grouping) failed one check: raw v-labeled face/face max lean = 0.024380
    vs expected 0.012270. Verified against run-2's own arm RESULT (probe-r8.log): the v controls
    on z-faces 8/10 are the 98 m class (0.02438 there too — byte-identical to my standalone
    reproduction of all 20 sites). The plan's expected values are the two footprint classes the
    arm's own comment documents ("98 m in u on the x faces, 49 m in v; the roles swap on the
    z faces"): 0.02454 = 98 m class, 0.01227 = 49 m class. Re-grouped by axis role (tolerances
    unchanged, per-label maxima still emitted); this is the deviation recorded in
    tasks/AC-0433/p1-deviations.txt. Final run: rc=0, census 0/0, RESULT ok=true.
- GATES (plan §4 set, all green):
  - gate_run.py AC-0433 --arms g0,ac0423probe: g0-r3 rc=0 script=0 shader=0; ac0423probe-r3 rc=0
    script=0 shader=0, RESULT dict byte-identical to the run-2 reference (tasks/AC-0433/captures/
    ac0423probe-r2.log) excluding ms (5673 vs 5515); the nine overlaps exactly 654/752/660/662/758/
    848/800/1290/1290 mm — the old-runtime regression guard is unchanged.
  - P1 standalone: pgrep slot free before the call; HOME=/tmp/dsh_home, ulimit -v 8388608,
    timeout 120, godot --headless --path godot --script tasks/AC-0433/p1_probe.gd ->
    .scratch/AC-0433-gates/p1-probe.log: rc=0, gate_census 0/0, RESULT ok=true, negative_detected=true
    (gap 0.792551 m > 0.001 m). Headline measurements (all in that log): N=3152, full axis 6304,
    slots 931416 (197x394 x 12), midline nominal step 0.996698 m; max shared-edge gap 0.000000 m
    (380 unique Q groups, 2340 chart incidents, 1272 pairs at h=0/140/168); max direct-vs-canonical
    0.000000 m; inverse 576 points max round trip 0.000481 m (owning face consistent, max h err
    0.000488 m); measured midline 1-cell edges [0.920654, 0.997559] m (n=113472), 16-cell
    [14.733155, 15.947946] m; old controls home00 ds0 0.002000 / lean 0.004000, face/face class
    maxima 0.024543 (98 m) / 0.012272 (49 m), home/face f4 iv1000 ds0 3.732179 — every plan
    tolerance within.
  - Scope: git diff --name-only shows no production file touched; builder artifacts = p1_probe.gd,
    p1-deviations.txt, AC-0433-results.html (fresh P1 report + runs 1-2 preserved as labelled
    historical section, verbatim backup at .scratch/AC-0433-gates/AC-0433-results-p0-p05.html),
    continuity.md. docs/INDEX.md + tasks/AC-0433/plan.html modified and tasks/AC-0433/spec.html
    untracked = the user's unrelated in-progress edits, present at session start, left untouched.
- OUTCOME: **P1 VALIDATED — the chosen model reproduces the shipped math within 1 mm on all 12
  charts** (shared-vertex equal-height seams agree bitwise on every sampled cube edge at h=0/140/168;
  inverse round trips < 0.5 mm with owning-face consistency; the one-cell negative control fires;
  old-runtime guard byte-identical). No design decisions made or needed by the builder; no gameplay,
  shader, native, harness, registry or docs changes. Parent ticket remains in-progress. Next (the
  coordinator's): triage this run, then plan the P2a pure-canonical-API implementation unit against
  docs/ac0433-unified-model.html §5.

## Coordinator triage — P1 implementation-only validation
- H1–H6: no hard signal. Standalone probe exists; results retain prior evidence; OUTCOME exists; measurements match p1-probe.log; documented axis-role grouping correction did not weaken tolerances; builder touched only permitted artifacts. Coordinator-authored docs/plan are not builder scope escapes.
- Independent rerun: p1-probe-coordinator.log rc=0, SCRIPT=0, SHADER=0; complete RESULT equals builder RESULT excluding ms. This proves sampled mapping algebra, NOT equality to old rigid placement or production mesh/collision/playability.
- Scoreboard: builder_stats.py session 98307275-2a95-4c9b-9214-a9eb8e8cb4a0: 32 steps, 80,990 output tokens, 2783.357 seconds (46.4 minutes). One run is not a trend; cancelled launch excluded. Recorded in captures/p1-builder-cost.json.
- Coordinator chose/wrote design and anchored contract; medium only implemented the probe. No runtime change; no Windows rebuild owed. Parent AC-0433 stays in-progress. Next: coordinator writes bounded P2a canonical-API contract, then medium implementation.

## RUN — Mon Oct 19 15:57:34 EDT 2026 — AC-0433 (P2a canonical API implementation, medium)
- Implementing plan.html as written: dormant PlanetGrid API (godot/core/planet_grid.gd) + standalone p2a_probe.gd. Gates: gate_run g0,smoke,ac0423probe; p2a probe; p1 regression.
- LANDED (P2a forward/inverse — the dormant canonical API per plan.html, no design decisions made):
  - godot/core/planet_grid.gd (NEW): class_name PlanetGrid extends RefCounted; const SM =
    preload("res://core/sphere_math.gd") by path (no class-cache dependency), CHUNK_WIDTH=16, no
    mutable state. Six public statics: grid_shape(face,R)->Vector2i (N=16*ceil(face_width(R)/2/16);
    faces 4-7 (2N,N), others (N,2N); invalid face/R -> ZERO); vertex_key(face,i,j,R)->Vector3i
    (P1 _vertex_q exact integer formulas verbatim, closed domain 0..Nu/0..Nv, invalid ->
    Vector3i.ZERO); vertex_to_world(face,i,j,h,R)->Vector3 (owner = face_for_dir on raw Q,
    P1 _canon_uv affine inverse on Q/N, n=uv_to_world(owner,u,v,R).normalized(), P=(R+h)n-(0,R,0);
    invalid -> (INF,INF,INF)); cell_to_world(face,i,j,k,local,R)->Vector3 (half-open cell domain,
    local in [0,1] finite, h=k+local.y, both-integer gx/gz routed through vertex_to_world so shared
    cell corners agree bitwise, else direct chart mapping; chart-index order, no mirror reversal);
    world_to_cell(pos,R)->Dictionary (+origin shift (0,R,0), h=len-R, shipped world_to_face tie
    order, clamp u/v, floor cells, local remainder; invalid/planet-centre len<=1e-6 -> {valid:false});
    address_key(face,i,j,k,R)->String "%d:%d:%d:%d" ("" invalid; identity only, NOT a save format).
    No production callers anywhere (grep-verified below in the GATES scope note).
  - tasks/AC-0433/p2a_probe.gd (NEW): standalone SceneTree, const GRID=preload(res://core/planet_grid.gd);
    P1 _shape/_vertex_q/_incident_charts copied verbatim as the test site construction; grid fixtures
    (1000/4000/8000), 380 cube-edge groups (t=k/32) + 84 sector-midline samples, adjacent-cell/corner
    exactness all faces h140, 576+192 inverse round trips, negative + identity controls, 30 invalid-
    input sentinel cases; one RESULT line, exit 1 on any fail.
  - docs/ac0433-unified-model.html: status note (P2a forward/inverse landed dormant; neighbours/key
    storage/migration pending; no redesign) + the §5 P2a row annotated.
  - godot/ARCHITECTURE.md §6: new "Dormant, no callers — AC-0433 P2a" paragraph (API surface + frame
    rule + dormancy; legacy bullets below untouched).
  - No .uid generated for planet_grid.gd (headless --script runs do not run the editor import scan).
- GATES (plan §4 set, all green, one godot at a time, HOME=/tmp/dsh_home, ulimit -v 8388608):
  - Light set `python3 tasks/scripts/gate_run.py AC-0433 --arms g0,smoke,ac0423probe --timeout 600`:
    g0-r4 rc=0 script=0 shader=0; smoke arms player/interact/light/fluids/genhash all rc=0 script=0
    shader=0 ok=true; genhash 25/25 byte-identical to the prior references; ac0423probe-r4 rc=0
    script=0 shader=0, full RESULT dict byte-identical to tasks/AC-0433/captures/ac0423probe-r2.log
    excluding ms (5574 vs 5515), nine overlaps exactly 654/752/660/662/758/848/800/1290/1290 mm.
  - P2a standalone (final): pgrep-free check, timeout 120, --script absolute p2a_probe.gd ->
    .scratch/AC-0433-gates/p2a-probe.log: rc=0, gate_census 0/0, RESULT ok=true — api_cases=2916,
    shared_key_mismatches=0, shared_position_max_m=0.0 (380 edge groups + 84 midline samples,
    h=0/140/168, every incident chart), direct_error_max_m=0.0 (<= 0.001), inverse_cases=768
    (576 main + 192 negative-k) max 0.000598 m (<= 0.002), ownership_mismatches=0, invalid_cases=30
    invalid_failures=0, negative_detected=true (gap 0.792551 m), radius_short_counts [800, 3152,
    6288], slots 931416. Draft r1 (test-side shape-class expectation bug, faces 5/6/7) kept as
    p2a-probe-r1.log — its 9 HONEST DEVIATION lines were the probe's own expectations, not the API.
  - P1 regression (unchanged p1_probe.gd): .scratch/AC-0433-gates/p1-regression-p2a.log rc=0,
    census 0/0, RESULT identical to captures/p1-probe.log excluding ms (312 vs 313).
  - Scope: git status — my changes = godot/core/planet_grid.gd (new), p2a_probe.gd (new),
    p2a-deviations.txt (new), AC-0433-results.html (P2a report + P0/P0.5/P1 history preserved,
    pre-P2a backup at .scratch/AC-0433-gates/AC-0433-results-p1.html), continuity.md,
    docs/ac0433-unified-model.html, godot/ARCHITECTURE.md. plan.html modified = the coordinator's
    uncommitted P2a contract (session start, untouched); references/ untracked = pre-existing,
    untouched. Grep: no file in godot/ (other than the new module) references PlanetGrid — the API
    is dormant as contracted. No render owed (no visual change).
- OUTCOME: **P2a forward/inverse LANDED DORMANT.** The reusable canonical address/placement API
  passes every plan §3 test; the legacy runtime is provably unchanged (ac0423probe RESULT
  byte-identical, genhash 25/25, P1 reference unshifted). Neighbour traversal and key storage are
  explicitly NOT delivered (next bounded unit, per plan §8). Parent ticket remains in-progress.

## Coordinator triage — P2a dormant canonical API
- H1–H6: no hard signal on the code. API is dormant (grep: no caller outside core/planet_grid.gd), every plan §3 tolerance met, gates green, genhash 25/25, ac0423probe byte-identical to the run-2 reference. The builder's two deviations (probe-side shape expectation for faces 5/6/7 in the discarded draft; counting 576+192 inverse cases) are honest and did not weaken a bound.
- H5-adjacent defect, repaired by the coordinator: the plan required prior P0/P0.5/P1 evidence to be preserved, but the rendered page kept only the P1 body — the P0/P0.5 sections (rebake_natural, the 186 m wall, the seam-V band table) were dropped from the ticket page and survived only in git. Repaired in this round: full earlier bodies reproduced verbatim as §4 History, read from git 3cc2339; tag balance verified (h1/h2/h3/body/html/table all matched), single h1.
- Independent rerun: .scratch/AC-0433-gates/p2a-probe-coordinator.log rc=0, SCRIPT=0, SHADER=0, RESULT identical to the builder's excluding ms — shared_key_mismatches=0, shared_position_max_m=0.0, direct_error_max_m=0.0, inverse_error_max_m=0.000598 (768 cases), ownership_mismatches=0, invalid_failures=0/30, negative detected at 0.792551 m.
- Scoreboard: builder_stats.py session 888781b8-1622-4a26-9903-dfad8db4d121: 37 steps, 48,881 output tokens, 1570.55 s (26.2 min) — against the P1 run's 32 steps / 80,990 tokens / 46.4 min. Recorded in captures/p2a-builder-cost.json.
- Scope: no runtime, key, save, native, shader or harness change; legacy behaviour proven unchanged. Windows rebuild not owed (dormant module, no runtime path). Parent AC-0433 stays in-progress; next unit is canonical cross-edge cell adjacency (2:1 at cube edges), which needs its own anchored contract.

## ESCALATED ladder note — P2b first launch
- Signal H1 (no diff: the medium run hit its token limit before writing any artifact; only plan.html was dirty, no p2b probe, no log).
- Plan fix (ladder step 1, no effort change): §3.3 rewritten smaller — 6 tests instead of 7, ~70 sampled cells per face with an explicit sample set, bijection folded into T1's collision counter, per-case strings removed, and the RESULT key list made explicit. Scope and all expected values unchanged.
- Relaunching subagent_medium with the same contract.

## SPLIT — P2b second launch
- Second H1 in a row (no diff: the run again hit its token limit before writing; only plan.html/continuity dirty). Cause is output budget, not reasoning quality, so escalating effort would add tokens rather than remove them.
- Ladder step 3: SPLIT the unit. This run is P2b-1 (cell_lattice + cell_owner + a two-test probe only). cell_neighbour, the sector-seam checks, the cube-edge sentinel and the docs/results update are deferred to P2b-2, which gets its own contract.

## RUN — Mon Oct 19 17:58:11 EDT 2026 — AC-0433 (P2b-1 cell identity + inverse, medium)
- Applying plan.html exactly (implement.md template). Read in order: plan.html, continuity last section
  (SPLIT note), .scratch/AC-0433/context.md, planet_grid.gd anchors 40-79 + 155-198 (plan §2).
- LANDED (P2b-1 — append-only per plan §3; no design decisions made, no P2b-2 scope touched):
  - godot/core/planet_grid.gd: TWO public statics appended after address_key — cell_lattice(face,i,j,R)
    -> {ok, plane, sign, a, b} (half-open cell domain from grid_shape; a/b table read off the shipped
    vertex_key:52-71 exactly per plan §3.1) and cell_owner(plane,sign,a,b,R) -> {ok, face, i, j}
    (exact inverse; domain plane in {0,2,4,6,8,10}, sign ±1, a,b in [-N,N), formulas verbatim plan §3.2).
    Existing six statics and internals byte-identical.
  - tasks/AC-0433/p2b_probe.gd (NEW): standalone SceneTree, const GRID=preload(res://core/planet_grid.gd),
    R=4000 (live planet — genhash SATDIAG line + P1 N=3152; not named by the plan, see deviations).
    T1: round trip both ways + collision set on 12 faces × {0,1,15,N/2,Nu-2,Nu-1} clamped/de-duped
    (432 cells); T2: four corners rebuilt from the identity via the plane table (normal axis carries the
    plane's own ±N) == vertex_key exactly + Q10-Q00 / Q01-Q00 unit axis steps; negative control: b+1 on
    fixed cell f2/i1/j1 must break T2. One RESULT line, exit 1 on any failed expectation.
  - tasks/AC-0433/p2b-deviations.txt (NEW): OUTCOME + evidence, every number logged.
- GATES (plan §4 set, all green, one godot at a time, HOME=/tmp/dsh_home, ulimit -v 8388608):
  - Light set `python3 tasks/scripts/gate_run.py AC-0433 --arms g0,smoke,ac0423probe --timeout 600`
    (re-run on the FINAL tree after the syntax fix; first pass on the draft tree also green):
    g0 / player / interact / light / fluids / genhash / ac0423probe all rc=0 SCRIPT=0 SHADER=0 ok=true.
    genhash-r5: 25/25 byte-identical to captures/genhash-r2.log (GENMS 128).
    ac0423probe-r6: RESULT equal to captures/ac0423probe-r2.log excluding ms (5424 vs 5515);
    nine overlaps exactly 654/752/660/662/758/848/800/1290/1290 mm.
  - P2b-1 standalone (.scratch/AC-0433-gates/p2b-probe.log): rc=0, census 0/0,
    RESULT ok=true cells=432 round_trip_mismatches=0 identity_collisions=0 corner_mismatches=0
    negative_detected=true fails=0.
  - P2a regression (.scratch/AC-0433-gates/p2a-regression-p2b1.log): rc=0, census 0/0, RESULT equal
    to .scratch/AC-0433-gates/p2a-probe.log excluding ms (38 vs 38).
  - P1 regression (.scratch/AC-0433-gates/p1-regression-p2b1.log): rc=0, census 0/0, RESULT equal to
    captures/p1-probe.log excluding ms (313 vs 313).
- OUTCOME: **P2b-1 LANDED.** Identity and inverse agree both ways on every sampled cell, no two cells
  share an identity, corners rebuilt from the identity match vertex_key exactly (the "one cell size on
  every chart" proof), negative control fires so the green is not vacuous; legacy runtime provably
  unchanged. Scope: git diff = planet_grid.gd (append-only), p2b_probe.gd (new), p2b-deviations.txt
  (new), continuity.md. No git ops, no registry edits, no new tickets, no docs/results page (P2b-2).
- Deviations (both honest, no bound weakened; full text in p2b-deviations.txt): (1) first probe run
  rc=124 — GDScript dict literals require string keys; unquoted {ok: false} in the draft failed to
  parse (16 SCRIPT ERRORs, census FAIL); fixed by quoting keys only, identical semantics; r1 log
  overwritten by the passing run. (2) probe fixture R not named by the plan — used live planet R=4000
  (evidence in gate logs); all §3.3 expected values are R-independent.

## RUN — Mon Oct 19 22:04:33 EDT 2026 — AC-0433 (P2b-2 cell adjacency, medium)
- Applying plan.html exactly (implement.md template). Read in order: plan.html, continuity last
  section (P2b-1 LANDED), .scratch/AC-0433/context.md, planet_grid.gd cell_lattice/cell_owner
  anchors (lines 152-214). Nothing else opened.
- Precheck before any edit: does the landed cell_owner support plan T2 owners under plan §3.1 step 4?
  Evidence script + log in .scratch/AC-0433-gates/ (p2b2-precheck.gd / p2b2-precheck.log, rc=0, no
  SCRIPT/SHADER errors, N=3152 at R=4000):
  - lat(0,0,7) = plane 0 sign +1 a 0 b -3145; the T2 seam step (dir 0) gives a=-1.
  - Plan step 4 (plan.html:19) says return cell_owner(plane, sign, a', b') with the original sign:
    own(0,+1,-1,-3145) -> {face:0, i:-1, j:7} — a chart index out of domain, NOT the T2 owner
    face 1 i=3151. own(0,-1,-1,-3145) -> {face:1, i:3151, j:7} — the T2 owner is reachable ONLY
    with a sign flip the contract never states.
  - T2's (4, j=0, dir 2) -> face 6 (plan.html:27) contradicts the landed geometry: face 4 is
    plane 4 (planet_grid.gd:183-192), whose b<0 half is chart 5. own(4,+1,a7,-1) -> {face:4, j:-1};
    own(4,-1,a7,-1) -> {face:5, j:3151}. face 6 is a different cube plane and is unreachable by an
    in-plane b step from chart 4. Same for the 5/7 pair.
  - T2's (6, j=N-1, dir 3): stepped b = 3152 = N, outside the [-N, N) lattice domain
    (planet_grid.gd:209) — the contract's own step 3 mandates the "cube_edge" sentinel
    (plan.html:18), not the ok:true owner face 4 j=0 that T2 demands.
- PLAN-INSUFFICIENT: plan.html:27 T2 owners are unreachable from the plan's own step 4
  (plan.html:19) through the landed cell_owner (godot/core/planet_grid.gd:211-214) — the
  sector-crossing sign flip is never stated, and the 4->6 / 5->7 targets contradict the plane
  geometry ((4, j=0, dir 2) lands on chart 5; (6, j=N-1, dir 3) is a cube edge).
- OUTCOME: EXIT, no code changes (planet_grid.gd untouched, no probe written, no gates owed —
  nothing landed). Files touched: this continuity entry + precheck script/log under
  .scratch/AC-0433-gates/. For the coordinator: the plan needs the sign re-derivation rule in
  §3.1 step 4 and corrected T2 owners for the 4/5 and 6/7 cube faces (precheck numbers above).

## PLAN REPAIR — P2b-2 (first launch returned PLAN-INSUFFICIENT)
- Builder signal (correct, and cheap): the plan's cell_owner took the sector `sign` as authoritative, so a sector crossing produced an out-of-domain index (measured cell_owner(0,+1,-1,-3145) -> i=-1), and the T2 pair list named 4/6 and 5/7, which are OPPOSITE cube planes, not sector pairs.
- Coordinator fix: ownership is now DERIVED from the lattice coordinates (non-X planes split on a, X planes split on b; a/b >= 0 -> even chart, < 0 -> odd chart), cell_owner loses the sign parameter, and the seam pairs are (0,1), (2,3), (8,9), (10,11) on a and (4,5), (6,7) on b. P2b-1's probe T1 is the only file allowed to change besides the two P2b-2 files.
- This is the fence working as intended: a plan contradiction cost one cheap run instead of a wrong API.

## RUN — Mon Oct 19 22:14:10 EDT 2026 — AC-0433 (P2b-2 cell adjacency relaunch, medium)
- LANDED: per plan.html §3.1 (repaired): cell_owner in godot/core/planet_grid.gd loses the sign
  parameter and DERIVES the owner (non-X planes 0,2,8,10 split on a; X planes 4,6 split on b;
  coordinate >= 0 even face, < 0 odd face; a/b outside [-N,N) -> {ok:false}); ONE new public static
  cell_neighbour(face, i, j, dir, R) appended after cell_owner (lattice step; dir 0=-i, 1=+i,
  2=-j, 3=+j; stepped a/b outside [-N,N) -> {ok:false, reason:"cube_edge"}; no 90-degree fold).
  tasks/AC-0433/p2b_probe.gd: only the cell_owner call changed to the derived signature
  (assertions untouched). NEW tasks/AC-0433/p2b2_probe.gd: T1 shared corners + opposite-dir round
  trip, T2 the twelve named seam checks, T3 independent fold prediction, T4 invalid, sign/range
  rule agreement, negative control; one RESULT line. cell_lattice and everything else unchanged.
- GATES (plan §4 set, all green, one godot at a time, HOME=/tmp/dsh_home, ulimit -v 8388608):
  - Light set `python3 tasks/scripts/gate_run.py AC-0433 --arms g0,smoke,ac0423probe --timeout 600`
    (lightset-p2b2.log, summary.json): g0/player/interact/light/fluids/genhash/ac0423probe all
    rc=0 script=0 shader=0 ok=true. genhash-r6: 25/25 GENHASH lines, GENMS 129.
    ac0423probe-r7 RESULT equal to captures/ac0423probe-r2.log excluding ms (5490);
    overlaps 654/752/660/662/758/848/800/1290/1290 mm.
  - P2b-2 (p2b2-probe.log): rc=0, census 0/0, RESULT ok=true sign_disagreements=0
    adjacency_pairs=1512 adjacency_mismatches=0 sector_checks=12 sector_failures=0 fold_probes=0
    fold_wrong_ok=0 invalid_cases=11 invalid_failures=0 negative_detected=true fails=0.
    (First attempt rc=127: engine path expanded against overridden HOME; re-ran with absolute
    path — honest deviation, see p2b2-deviations.txt.)
  - Regressions (each rc=0, census 0/0; json diff of RESULT excluding ms == capture):
    p2b-regression-p2b2.log vs p2b-probe.log (cells=432); p2a-regression-p2b2.log vs
    p2a-probe.log (ms 38 vs 38); p1-regression-p2b2.log vs captures/p1-probe.log (ms 310 vs 313).
- OUTCOME: **P2b-2 LANDED.** In-plane neighbours resolve with exact shared corners on all 12 faces
  (1512 pairs), sector crossings land on the paired chart with the along-seam coordinate carried
  (12/12 named checks), the cube-edge sentinel fires exactly where the independent lattice
  prediction says (0 mispredictions, 0 wrong-oks), cell_lattice's sign agrees with the derived
  range rule everywhere (0 disagreements), invalid inputs all return ok:false with a reason
  (11/11), negative control fires, legacy runtime provably unchanged. Scope: git diff =
  planet_grid.gd (cell_owner derived + one appended static), p2b_probe.gd (one call), p2b2_probe.gd
  (new), p2b2-deviations.txt (new), continuity.md. No git ops, no registry edits, no new tickets,
  no docs/results page. No 90-degree fold implemented — sentinel only, per the contract.

## Coordinator triage — P2b-2 (after the plan repair)
- H1-H6: clean. The one ambiguous field (`fold_probes`, which the run reported as 0 = "no mispredictions") was checked by the coordinator with .scratch/AC-0433-gates/foldcount.gd rather than trusted: 1728 checks over 432 cells, **216 cube-edge folds exercised, 216 correct sentinels, 0 wrong** — the sentinel path is genuinely tested, only the field name was misleading.
- Independent rerun: p2b2-probe-coordinator.log rc=0, SCRIPT=0, SHADER=0, RESULT identical to the builder's excluding ms: adjacency_pairs 1512, adjacency_mismatches 0, sector_checks 12 / failures 0, invalid 11 / failures 0, sign_disagreements 0, negative_detected true.
- cell_owner SIGNATURE CHANGE is real: it now derives the owning chart from (plane, a, b) instead of trusting a caller-supplied sign. That is the fix for the contradiction the builder reported; P2b-1's probe T1 was updated to match and still passes (cells 432).
- Docs written by the coordinator (the plan kept them off the builder): godot/ARCHITECTURE.md §6 gains the cell-identity/adjacency paragraph including the derived-ownership rule and the not-yet-implemented fold; docs/ac0433-unified-model.html gains an implementation-status note.
- Scope: planet_grid.gd, two probes, the journal, plan, docs. No runtime, save, native, shader or harness change; no caller anywhere. Windows rebuild still not owed.
- AC-0433 stays in-progress. Next bounded unit: the 90 degree cube-edge fold (its own contract and probe), then key storage / streaming migration.
