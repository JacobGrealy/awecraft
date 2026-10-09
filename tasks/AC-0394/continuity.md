## TRIAGE - Thu Oct  8 18:37:18 EDT 2026 - AC-0394

## RUN - Thu Oct  8 18:52:33 EDT 2026 - AC-0394

- Thu Oct  8 19:14:24 EDT 2026: plan.html written; viewmodel_occlude switch implemented (settings.gd DEFAULTS+_clamp, menu.gd row/sync/handler, player.gd env preload + _vm_occ_sync + build-time apply, ARCHITECTURE note).

- Thu Oct  8 20:13:09 EDT 2026: gates green on final tree (G0 rc=0 0/0 paired, SMOKE ok:true, toolpose ok (pre+post fix), held box_ok FALSE = pre-existing (pristine worktree A/B identical), genhash 25/25 identical to AC-0408 ref). Renders done from a39c6e9 worktree + 3 hunks: wall OFF (on-top) / ON (occluded) / sky-aimed (item vs sky) / sky-auto (dirt vs terrain). Worktree removed.
- Thu Oct  8 20:13:09 EDT 2026: CENSUS (residual one, for both tickets): 2597/159744 band-A ring columns (taxi 5..8, 3 anchors, seed 44) have the skip=1 fill ABOVE the carved top = 1.63% (0.51%/2.29%/2.07% per anchor; taxi 5->8: 0.49%->2.39%); max delta 91 blocks at (-91,147,-48). Visible from ground at user settings (80-128 m << fog 332): user WILL still see floating slabs. No generation code changed (other ticket owns the fix; direction: fill band-A to the carved top).
- Thu Oct  8 20:13:09 EDT 2026: results page written (tasks/AC-0394/AC-0394-results.html). Exit: no commits (fence); HEAVY gates left to coordinator; findings: re-measure player/interact/held standing rows (post-AC-0314 staleness, spawn top 141->140).
