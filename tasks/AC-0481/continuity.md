## RUN — Mon Oct 26 00:33:48 EDT 2026 — AC-0481
- 01:40 FINDINGS: seam ABSENT on the current tree (zenith dome + r120 limb repro
  renders, 0 seam candidates; also absent in all ten AC-0483 captures, old and
  new tree) — 4.2 skipped (conditional). Attribution: the 2026-10-24 blur-off
  ruling (user: "several of those filings were read off blurred captures",
  settings.gd:441-448, shipped AC-0480) + AC-0480's three-seams audit; AC-0483
  removed a HORIZONTAL band, not this vertical line. Cloud form: weights NOT
  drifted (u_vol_amb 0.45 / ms1 0.30 / iso 0.4 = AC-0406 calibrated; ms2 0.24
  = AC-0407's documented re-calibration, nothing pushes any of them); r700
  lower_mid spread 52.2 vs calibrated 44.9 / floor 40.2 / rejected 39.1 -> form
  survives; r120 underside min 175.9 (no black). No code change made (4.4: no
  fix owed). Deliverables: AC-0481-deviations.txt, AC-0481-results.html
  (results_page.py), captures seam-zenith-day / seam-r120-limb / r700-on,
  seam.py + measure logs under .scratch/AC-0481-gates/.
- 01:41 GATES: gate_run.py AC-0481 --arms g0,genhash,lightstate (r1, unmodified
  tree): g0 rc=0 script=0 shader=0 ok=true 3s; genhash rc=0 ok=true 25/25 4s;
  lightstate rc=0 leaks 0 before/after, wash_detected false, move.delta 0,
  hole_slabs 106 flat, stragglers 3 — all arms ok (summary.json). Renders 3/3
  rc=0, 0 SHADER ERROR, 0 SCRIPT ERROR, Forward+ asserted, DOF off in all.
  Exit: no git ops (fenced), no TASKS.yaml, no new tickets.
