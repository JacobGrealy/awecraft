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
