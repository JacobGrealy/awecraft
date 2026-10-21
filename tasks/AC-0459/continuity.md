## RUN — 2026-10-20 20:11 — AC-0459

## STOP — 2026-10-20 20:21 — AC-0459

PLAN-INSUFFICIENT: the plan's measured blast radius (one producer, five parsers) is contradicted by the code — unlisted hardcoded chunk-key producers at main.gd:1704/1827/1873/1908 (and ~40 more in fence-protected harness.gd), and 3 of the 5 listed "parsers" (world.gd:13685, main.gd:1732/1805) are cell-key parsers, not chunk-key parsers. Full findings: tasks/AC-0459/AC-0459-deviations.txt. No code changed, no gates run.
