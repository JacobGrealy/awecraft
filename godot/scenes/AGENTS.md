# godot/scenes/ — the main loop and the test-arm monolith (scope rules)

## harness.gd (24,280 lines) — the arms

- It holds **every** `AWECRAFT_LOGIC` arm and is **inert during normal play** (AC-0140). It stays
  **pristine**: a temporary measurement arm goes in **and comes out** in the same task. Do not
  restructure or reformat it, and never leave a probe behind.
- **Adding or changing an arm means two files**: the branch in `harness.gd` **and** a row in
  `tasks/harness_data.yaml` (entry / tests / result_fields / envs / wall / notes), then
  `python3 tasks/scripts/harness_doc.py --render`. `--check` compares the doc against the data — it
  knows nothing about your branch, so an arm with no row is silent drift.
- Every mode prints `RESULT {…}` (JSON, also written to `user://debug_result.json`) and quits. An arm
  that quits the process itself must be BATTSKIP-ed out of the battery (see `mainmenuexit`).
- **G0 = zero `SCRIPT ERROR` lines, not `rc=0`.** The engine exits 0 even when scripts fail to
  compile — verified 2026-09-16, when a broken `harness.gd` parse printed 5 SCRIPT ERROR lines and
  still exited 0. Count the errors; that is why this gate exists.

## main.gd (1,815 lines) — the tree and the dispatch

- It builds the entire scene tree at runtime (see `../ARCHITECTURE.md` §3). Nothing is discoverable
  by opening a `.tscn`.
- **Dispatch order is load order.** The `settings` arm is dispatched *before* the game nodes exist so
  it runs standalone as well as in the battery; battery entries re-dispatch their `*_body` variants.
  A new arm follows the same shape, or it will not work in both contexts.

## Shots and substitutes

- Render and shot hooks, plus the **proxy-renderer warning**: `../HARNESS.md` §2/§4. A render here is
  evidence about geometry and layout, never about the shipped `forward_plus` look.
- `test_range.tscn` substitutes for `World` in the AC-0191 test range — do not assume the normal
  world tree when an arm uses it.

Cross-scope: world-side effects of an arm (`genhash`, `boundary`) are `../world/AGENTS.md`.
