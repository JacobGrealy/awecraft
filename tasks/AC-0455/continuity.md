# AC-0455 — continuity

## RUN — 2026-10-19 14:03 UTC — AC-0455
- Builder (subagent_medium) started. Plan read in full; references: gate_census.py, spec_template.py,
  tasks_lib.py, harness_data.yaml (smoke+modes), .scratch/AC-0287-gates/gates_run.sh, scripts/AGENTS.md,
  AC-0448 results headings, godot/OPS.md §2.
- Scope: 4 new scripts + test_builder_tools.py + 2 doc edits (scripts/AGENTS.md bullet,
  awecraft-run-verify SKILL.md). One real godot run authorised: gate_run.py AC-0433 --arms g0.
- Baseline to hold: test_tasks.py = 53 passed, 0 failed.

## LANDED — 2026-10-19 14:55 UTC — AC-0455
- All four tools + test file written: context_pack.py, gate_run.py, results_page.py,
  builder_stats.py, test_builder_tools.py (16 tests). Doc edits: tasks/scripts/AGENTS.md bullet,
  awecraft-run-verify SKILL.md gate-run section.
- Design notes (mechanical, not redesign): (1) plan.html sections parsed by <h2>; §2 file-table
  anchors + inline file:line anchors both resolve (AC-0433 prose-plan fixture needs the latter);
  (2) harness mode rows field-capped at 500 chars (the yaml stays the machine source — without it a
  9 KB notes field eats the 12k budget and the anchor excerpts drop, failing the plan's own fixture);
  (3) builder_stats default root = this workspace's ~/.dsh/sessions dir (the plan's all-workspace
  glob dilutes the fit to R²=0.837; the AweCraft population reproduces the AC-0454 baseline);
  (4) session reads use an envelope fast path (zstd -dc via subprocess, regex time, JSON only on
  type-candidate lines) — 473 files in ~100 s.
- Gates so far: unit 16/16 OK; registry 53 passed / 0 failed (log .scratch/AC-0455-gates/).

## GATES — 2026-10-19 15:05 UTC — AC-0455
- unit: test_builder_tools.py 16/16 OK (logs .scratch/AC-0455-gates/unit-r1.log / unit-r2.log).
- registry: test_tasks.py 53 passed, 0 failed (registry-r1.log; wall 58 s — LLM-load variance, result unchanged).
- fixtures: context_pack AC-0433 = 29,034 B ≈ 8,065 tokens ≤ 12k, all 9 sections, 7 anchor excerpts,
  no monster >200 lines (fixtures-r1.log); builder_stats law: wall_s = -487 + 0.0644*out_tokens,
  R²=0.924, n=417, ~15.5 tok/s, median 1.69 h / 107k / 101 (fixtures-r2.log).
- g0 (real, the one authorised run): gate_run.py AC-0433 --arms g0 → rc=0, script=0 shader=0,
  ok=true, wall 3.2 s; .scratch/AC-0433-gates/summary.json + summary.txt + g0-r2.log written;
  no HEAVY_GATES_DONE (not the heavy stage). NOTE: the g0 arm needed --quit (the canonical G0
  recipe, HARNESS.md §4) — deviation 1 in the results page.
- negative (hand): results_page.py AC-0433 with an absent-arm summary → exit 1, refusal recorded
  in .scratch/AC-0455/deviations.md.
- Results page rendered with the new tool: results_page.py → tasks/AC-0455/AC-0455-results.html
  (3 sections; Artifacts omitted — no png/json in the ticket dir).
- EXIT: my gates done. Next = the coordinator's triage + closeout.
