# AC-0463 continuity

## RUN — 2026-10-21 — AC-0463 slice 1

- Contract: tasks/AC-0463/plan.html (pure refactor, one node-creation skeleton).
- Shared set verified (deviations file): checkout, col_gen bump, face/cx/cz, init_slabs, add_child — same order in both lanes; ChunkScript has no _ready, so add_child reads nothing lane-specific.
- LANDED: _chunk_checkout_registered() helper in world.gd; _make_chunk_node and _ensure_face_chunk both call it; home keeps transform/band/collision after it (was between cx/cz and init_slabs — order shift documented as safe: no reader of those fields before add_child existed, and the face lane already enters the tree with pooled defaults).
- GATES: all green, both modes. Default: g0 0/0, genhash 25/25, homecensus min_mm 0.0 (0.000 mm floor),
  planetwalk ok on both boundaries, faceedit 0.578/0.397, seamcensus rows_ok=393216.
  AWECRAFT_WARP_HOME=0: same set, all rc=0, genhash 25/25, same faceedit/seamcensus values.
  save ok=true; load ok=true simband_ms=6633 (normal ~6.7 s). Results page rendered.

## Slice 1 landed (round 32) — one node-creation skeleton
- WHAT WAS SHARED, measured before extracting: five statements, not two — `_column_checkout()` -> the AC-0247 `col_gen` identity bump -> face/cx/cz assignment -> `init_slabs()` -> `add_child()`, in the same relative order in both lanes. That cleared the plan's "stop if trivial" condition on its merits rather than by assumption.
- EXTRACTED to `_chunk_checkout_registered(face, cx, cz)` (world.gd:11461), called by both `_make_chunk_node` and `_ensure_face_chunk`; everything after it is byte-untouched, so generation, the worker handoff, the drain and `_face_stream` are exactly as they were.
- THE ONE ORDER CHANGE, stated rather than buried: the home lane's transform/band lines now run after `add_child`. The builder's justification is checkable and was checked — `ChunkScript` has no `_ready` and no tree-signal readers, and the face lane already enters the tree with pooled defaults. The full gate set in BOTH placement modes is what backs that claim.
- VERIFIED: `g0` 0/0 and `genhash` 25/25 re-run by the coordinator; the builder's full set green in both modes (homecensus 0.000 mm floor, planetwalk both boundaries, faceedit 0.578/0.397, seamcensus 393,216 rows) and save/load `simband_ms 6633`, which is this tree's normal rather than the ~50 s a lost registration would produce.
- REMAINING SLICES, unchanged by this: (2) one residency model — the risky one, home banded+drain vs face lazy budgeted; (3) one light ownership — `_star_faces` per-face engines vs the home path, gated by AC-0358's feed invariant and lightstate; (4) deletion, mostly already done by AC-0459/AC-0465; and the twelve-chart lap that AC-0466 waived at 2 of 12.

## RUN — 2026-10-21 — AC-0463 slice 2a (residency baseline)

- Contract: tasks/AC-0463/plan.html (measurement: add ONE harness arm `residency`, change no behaviour).
- LANDED: ONE arm `residency` in harness.gd (dispatch branch + _residency_test + 5 helpers, planetwalk shape: standalone/quits/BATTSKIP); world.gd READ-ONLY (plan §3); harness_data.yaml row + harness_doc --render/--check green.
  Instrument decisions (deviations file §2): evictions = key-set sample-diffs (the lanes own no eviction counter); pooled-column accounting = the col_gen census (every checkout bumps exactly one col_gen; perf_pool_col_grows_n counts on-demand creation only); resident = presence in world.chunks (face<=1 home / >1 chart, the world's own split); steady verdict = the plan's STABLE/GROWING dichotomy taken after a BOUNDED plateau wait (the face lane fills its window ~2 s after the settle at the 12 ms budget — a bounded fill, first run's naive first<last rule would have misreported it as a LEAK).
- GATES: all green. gate_run.py AC-0463 --arms g0,genhash,residency --timeout 900: g0 rc=0 script=0 shader=0 (3 s); genhash rc=0, 25 GENHASH lines BYTE-IDENTICAL to slice 1's run (genhash-r3.log diff empty); residency rc=0 ok=true (19 s wall, 498 frames, 15813 ms in-arm):
  home traverse: resident 81 -> 93 (flat 93 for ten of sixteen 8 m steps), home_traverse pooled_new=0 / pooled_reused=109.
  crossings (planetwalk route): x_seam 4->5 in 3 steps, face before/at/after 0/12/12, ev h/f 32/0; z_seam 10->11 in 3 steps, face 12/9/9, ev h/f 22/2.
  steady: STABLE — home 125 / face 93, keys_same=true, 6/6 samples identical; converged=true (face fill 60->72->85->93->93 in converge_ms=1974 after the 180-frame settle), leak=false.
  whole run: home {resident 125, evictions 151, pooled_new 68, pooled_reused 380, peak 125}; face {resident 93, evictions 2, window_cells 12, budget_ms 12.0}; pools {col_pool_final 0 / peak 33, mi_pool_final 0 / peak 437, checkouts_total 448}.
  policy (live): home {sim_dist 4, band0_r 4, band1_r 96, medium_start_r 8, render_radius 4, b1_eff 4}; face {budget 12.0 ms, win 64 m, cell 6.14 m, edge_rows_x 12 / edge_rows_z 22, evict margin 64 m, hw 3141.6 m}.
  harness_doc.py --check exit 0 (rendered). Results page rendered from .scratch/AC-0463-gates/summary.json.
