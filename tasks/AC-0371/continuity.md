# AC-0371 continuity (builder journal)

## Resume point (2026-09-28 05:40)
DONE — ready for coordinator closeout. Working tree: only `gdext/src/gen.cpp` modified
(the fix + the two permanent counters `g_aqu_searches`/`g_scan_blocks` + their
`gen_timing()`/`reset_gen_timing()` entries); `harness.gd` pristine; `tasks/TASKS.yaml`
carries the coordinator's own open→in-progress flip (02:30). All temp instrumentation
(probe counters, env stub, AQP line, `<cstdio>` include, `aqucensus` arm) removed;
final build E re-verified G0 0/0 + genhash 25/25 byte-identical. Windows DLL rebuilt +
re-staged (`AweCraft-20260928-0535` stamp). Evidence: `AC-0371-results.html` +
`.scratch/AC-0371-gates/` (all logs). No commit made (coordinator closes).

## Chronology
- 02:35 session start on tree d5e3967 (post-AC-0370). F1 recorded up front: the ticket's
  1,600 µs / 14,057-search numbers price the PRE-AC-0367 tree (filed 05:56, 4 h before
  AC-0367 piece A). Baseline: G0 0/0, genhash 25/25 vs AC-0367 ref, GENMS 126, R24
  (probe build, superseded), fill 1,149.2 µs/chunk (clean build C).
- 03:20 SCons note: `python3 -m SCons` / `.scratch/scons/bin/scons` fail on this box —
  the working invocation is `PYTHONPATH=.scratch/scons python3 .scratch/scons/bin/scons
  -C gdext platform=linux target=template_release` (the Windows pipeline's own
  `PYTHONPATH=.scratch/scons-src python3 -m SCons` form also works via build_windows.sh).
  Verify the .so mtime after every build — a `| tail`-masked build failure stages a stale .so.
- 04:10 probe census (25 genhash chunks): 869.3 searches/chunk (was 14,057), exactly
  12.000 candidates/search (a refuted), 5.18 searches per (column, slab) key (b
  confirmed), 86.0% all-dry slabs, barrier entries 31% but only 2 barrier-noise calls in
  25 chunks. True term (stub difference, clean build): 82.2 µs/chunk = 94.5 ns/search.
- 04:50 fix in `aqu_block`: per-column `AqColState` (A[dx][dz] xz precompute), per-slab
  12-slot candidate cache (original (dx,dy,dz) slot order — the tie-break order),
  all-dry early-out, int d² with `INT32_MAX` sentinel + 256-entry squared-diff table
  (|y−cy| ≤ 23 proven), pointer barrier pass (no idx%3/idx/9 decode). Bit-identical by
  construction (all d² exact in int32 and were exact in double).
- 05:00 verification: genhash 25/25 ×4 runs (incl. the battery's genhash mode), term
  82.2 → 28.1 µs (32.3 ns/search, 2.9×), fill −38.6 µs, searches unchanged. Census
  (11×11 seed 44, temp arm) identical C vs D field-for-field; contracts: open_water 0,
  max water y 144 (perched lakes). F2 recorded: on this tree 791 of the 1,081 lattice
  ocean columns are carved islets (pre-carve he ≥ 126 → no ocean fill per AC-0342 policy;
  post-carve top below sea, dry) — the AC-0342 "1081/1081 at sea" strict form no longer
  holds on this tree (AC-0367 density change); flag for coordinator. Census arm lesson:
  land/ocean split must use the generator's lattice H (`column_heights16` = `surface_h`,
  column order (lz<<4)|lx), not the dense `terrain_height` (trilinear residual
  misclassifies coastal columns).
- 05:10 gates on D (recipe = AC-0367's, battery at 16 GB per ticket): meshprobe 1.0,
  halo 0, lightstate 0/0, boundary_r4 ok, farab h_mismatch 0, ladder 20/20
  (155/155 + 94/94), r16 far_holes 0/0 both bands, battery 7/7 mode-identical to
  AC-0367's accepted run. Gate-script trap: the `run()` bash -c expansion splits
  `AWECRAFT_BATTERY=a;b;c` on the semicolons (rc 127) — AC-0367's script has the same
  bug; run the battery as a standalone command with the value single-quoted inside the
  -c string.
- 05:35 R24 before/after (one run each, clean C vs D): no measurable change (queue
  1316/1316; walk 11.22→10.22 s; storm/built deltas inside same-tree run variance —
  the window is main-thread drain/collide/dispatch-bounded; ~54 µs × ~1,300 chunks
  ≈ 70 ms of a 10 s walk is below that floor). Windows: `./build_windows.sh --no-serve`
  (REAL HOME — the script needs the real export templates; the default bash HOME here
  already is the real one), rc 0.
