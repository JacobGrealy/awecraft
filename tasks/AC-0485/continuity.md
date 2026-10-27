
## RUN — 2026-10-26 22:12 EDT — AC-0485 (medium builder, measurement-only: startup/cache bytes+time inventory)

## LANDED (instrumentation + corpus) — AC-0485
- Facts: user:// = /tmp/dsh_home/.local/share/AweCraft (probed; absent at session start — /tmp reboot-wipe). res:// = godot/ (no .godot import cache at start; g0 created it — all runs start PCK-equivalent).
- Ownership: save.gd = user://awecraft_save_{0,1,2}.json (BASE) + ChunkIO.clear_dir; chunk_io.gd dir_for = user://chunkdir_<slot> (region files, AC-0287 filter => ~0 bytes in natural flow, far cols never encoded); satellite_body.gd = three-phase (user://satellite/p<id>_r<R>_s<seed>_h/ 12 PNGs -> shipped res://assets/satellite/ 12 PNGs [10,834,903 B, AC-0478] -> bake; shipped set IS the seed-44 bake (ship step AWECRAFT_SATELLITE_SHIP) = the duplicate.
- KEY DESIGN FINDING: the battery (C2) runs with Save.active_slot=-1 => column cache INERT there. The cache-relevant product path is the MENU flow (Play -> new world / continue, Save.active_slot set). So A-pairs = AWECRAFT_MENU_BOOT=1 (product launch->playable), batt = C2 travel/bucket run, flysave = column-family byte trace, bake = seed-45 far-tier run.
- Milestones: t0 (engine first line, stamp wrapper) / m_world (SATDIAG configure) / m_body_loaded (phase=LOADED) / m_first_mesh (first TMESHW) / m_playable (41st first-TMESHW over the sim taxi diamond |dx|+|dz|<=4 — the exact loading-screen gate set). Buckets: TGENW wms/wait, TMESHW wus, STSEED wus (AC-0484 attribution, re-used). Meter control: LD_PRELOAD shim (shim.c) injecting AC0485_INJECT_US at the first AweCraft/godot open (5000/50000 us runs).
- r1 pair validated: mcold first-playable 10.84 s, mwarm 11.50 s, 41/41 diamond, cold created 367,045 B (save 837 B + cfg 1008 B + godot.log 365,200 B; NO chunkdir — as designed). rc=124 = bounded 120 s cap (expected).
- In flight: A pairs 2-5 (background job bash-1515). Then negctrl x2, batt x3, fly x1, bake x1 (seed 45, RSS 5 s), colbytes + genhash gates (g0 already green: script=0 shader=0).

## LANDED (2026-10-27 00:31 EDT) — measurement complete except D-run bake tail
- **A pairs (5 valid + 1 extra cold):** cold playable median 10,611 ms (p95 10,842, spread 385, n=6); warm 10,602 ms (spread 191, n=5); paired Δ +14.3/+12.8/+0.8/−109.3/−0.6 ms → **warm ≈ cold** (save JSON buys nothing; column cache ~0 B natural flow). mwarm-r1 INVALID (per-call /tmp wipe — fresh tmpfs per bash call; every pair since ran in ONE call).
- **B ×4:** gen med 5–6 ms, wait med 0, mesh med ~3.3 ms, light ~2.4 ms, skip1=61 const, battmode ~18.5 s. **C flysave:** 1024 blocks → 0 B on disk (757 skips, 691 far evicts never encoded). **colbytes:** 25 edited cols → avg 2,070 B (1,045–3,545).
- **E negative control PASSES (sleep wrapper, not LD_PRELOAD):** nc1 measured 11,114.9 µs → t0 +14,220 µs; nc2 measured 55,960.4 µs → t0 +59,080 µs (constant +3.1 ms exec overhead); engine-internal timeline moved none. Shim saga documented (direct openat syscalls blind to interposition; LD_PRELOAD fires in timeout wrapper too).
- **Gates:** g0 0/0; genhash 25/25 byte-identical to BOTH AC-0484 refs; colbytes ok.
- **D run (bake2, stage 2 running):** menu flow 2-stage (cfg seed 44→45 via the product's own settings path, save removed → new-world branch). AC0414 hold engaged 3.687 s, released LATE at 45.695 s (= 42.00 s budget exact); **new-seed first-playable = 46.867 s** (diamond 41/41 at 46.884 s stamp). RSS trajectory climbing (1.52 GiB at ~10 min; AC-0469 peak was 4.71 GiB). Awaiting: bake wall (start 3.68 s → "SATELLITE bake done"), peak RSS, F3b bytes (state-post), m_body_loaded (planet LOADED).
- bake-r1 (first D attempt) INVALID ×3 (battery self-exit 115 s / no loading window so no hold / RSS sampler matched timeout wrapper) — superseded, recorded.
- Results page + deviations + windows protocol written (D numbers pending).

## LANDED (2026-10-27 01:05 EDT) — D run complete, all deliverables written
- **D run (bake2-b2stage2, menu flow seed 45, rc=124 bounded by design):**
  bake wall **1,274,256 ms (21.2 min)** engine-reported (gen_wall 1,224,166 ms on
  1169 shards, face 23.7 s) — Δ 0.4% vs AC-0469's 1,269.0 s; hold released LATE at
  exactly the 42.00 s budget (45,695−3,687 stamp µs); **new-seed first-playable
  46.867 s**; planet LOADED 1,278.0 s; **peak RSS 4,730,172 KB (4,619.3 MiB)** —
  trajectory 418 MiB → 2,359 MiB (payload done) → 4,619 MiB merge spike ~30 s →
  2,359 MiB (incremental 4,201 MiB = 65.6× the 64 MiB scratch target);
  **F3b = 10,736,864 B (10.24 MiB, 12 PNGs, 809,135–1,081,711 each)**;
  combined post-bake total 13,413,471 B (12.79 MiB). Guard 12/12 ok, ship="" (cache bake, not ship).
- **Deliverables written:** tasks/AC-0485/AC-0485-results.html (all numbers, no
  pending slots), AC-0485-deviations.txt (8 items), AC-0485-windows-protocol.html
  (sleep-launcher primary control + instrumented-.dll alternative + the
  direct-openat-syscall finding).
- Ticket complete: gates green, §2 quantified, inventory by family sums to the
  snapshot totals, every figure dev-only-labeled, fences held (no product
  edits, no git ops, no TASKS.yaml).
