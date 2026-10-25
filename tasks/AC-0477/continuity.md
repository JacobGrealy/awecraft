## RUN — 2026-10-25T05:25:53Z — AC-0477

## LANDED — AC-0477
Created tasks/scripts/battery_compare.py (documented CLI; based on the
.scratch/AC-0288-gates/battery_compare.py value-diff engine — identical to the
AC-0287 copy; added: argparse CLI, mode discovery from input dirs, dataless
file skip, harness_data.yaml declaration read for the four AC-0330
value-reporting arms, and the full status layer: STATUS-CHANGE/NEW-RED/
STATUS-LOST hard-fail, BASELINE-RED loud report with opt-in
--fail-on-baseline-red, declared/no-status info lines). .scratch copies
untouched. Fixtures built under .scratch/AC-0477-gates/fixtures/
(clean_base/cur, status_base/cur, real_cur).

## GATES — AC-0477
- gate_a (baseline-red): percol_battery vs fixtures/real_cur → rc=1,
  BASELINE-RED x7 (water, trees + 5 stale-archive reds), STATUS-CHANGE craft
  false->true, declared four arms silent. Log: compare_baseline_red.log
- gate_b (status change): status_base vs status_cur → rc=1, 3x STATUS-CHANGE
  (alpha false->true, beta true->false, water true->false on the real red log).
  Log: compare_status_change.log
- gate_c (quiet): clean_base vs clean_cur → rc=0 PASS, no status findings;
  real_cur vs itself → rc=0 PASS, only standing-red lines. Logs:
  compare_clean.log, compare_same_tree.log
- gate_d (cry-wolf): the four declared arms produce only the informational
  declared-no-ok line in every run — zero complaints.
- gate_e: gate_run AC-0477 --arms g0,genhash (r2): g0 rc=0 script=0,
  genhash rc=0 ok=true (25 GENHASH lines). test_tasks.py: 53 passed, 0 failed.
