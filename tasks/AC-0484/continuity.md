## RUN — 2026-10-26 21:03:29 EDT — AC-0484
(measurement-only; contract tasks/AC-0484/plan.html; orienting: grep anchors, design instrument)

## LANDED — 2026-10-26 21:55 EDT — AC-0484
Code in place: (1) gdext/src/gen.cpp — the AC0484_GEN_TIMING block (negative-control
injection AC0484_INJECT_US + per-call JSONL record AC0484_TIMING_FILE, diffing the
standing AC-0237 stage counters; top-of-file guarded includes; call-site wraps in
generate_flat + generate_resl incl. the far path) — default OFF; (2) gdext/SConstruct —
the opt-in define; (3) godot/world/world.gd — 2 timing-gated prints (TMESHW around the
mesh-lane build_accs; STSEED around star.seed_column) behind the existing
AWECRAFT_TIMING=1 gate. Build: instrumented .so md5 23533acb… (AC0484_GEN_TIMING=1),
default rebuild md5 8feae1e8… = BIT-IDENTICAL to the pre-AC-0484 .so (AC-0480 pattern
clean; SCons v4.11.1 via the .scratch venv — not on PATH). Driver + runners in
.scratch/AC-0484/ (driver.gd / run_engine.sh / run_envlog.sh / parse.py).

## GATES — 2026-10-26 22:05 EDT — AC-0484
ALL GREEN, development-only (Linux i5-9400F, llvmpipe):
- G0 canonical (gate_run) rc=0 script=0 shader=0; 0 SCRIPT ERROR in every measurement log.
- genhash (default .so): 25/25 byte-identical across 2 runs AND = the standing reference
  (.scratch/AC-0311-gates/p2_genhash_r1.log); GENMS 130/142 (box spread 126–138).
  Driver's own corpus output: 25/25 = reference. Features intact by the hashes.
- Negative control: 5000 us injected -> per-call wall median 5346 -> 10399 us (delta
  5053 us); stage-sum unchanged -> the timer is proven sensitive.
- 5 interleaved trials x 25 chunks (corpus C1, 125 samples): generation stage-sum median
  5226 us; ranked: field 1888 / scan 1592 / fill 1142 / pallet 256 / drip 225 / aquifer 49 /
  heights 34 / veg 15 / carve 7 (carve n>0=124); whole-call wall median 5345 us (97.8%
  stage-attributed); trial medians 5329-5350 (0.4% spread — interleaving holds).
- Production buckets (battery=player, seed 44, 2 gen/4 mesh workers, 103 chunks):
  queue wait median 0 ms (p95 1); worker gen wall median 5 ms (p99 9); mesh build
  (build_accs incl. its internal light pull) median 3278 us; light seed median 2434 us;
  I/O+data-lane pull (colbytes) 36.1 ms/column, 2070 B avg, v4 codec.
- No trial was contended or discarded (every run's envlog: other_engine=none,
  loadavg 0.72-1.17, top procs = our own shells).
Deliverables: tasks/AC-0484/{corpus.txt, protocol.html, AC-0484-results.html,
AC-0484-deviations.txt}; logs + stats json + build.log in .scratch/AC-0484-gates/.
Windows handed over as protocol.html §8 — NOT run here, NOT faked.
