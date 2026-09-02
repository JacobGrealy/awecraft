# AC-0197 continuity — sparse-air-slabs-skip-empty-top

## RUN — 2026-09-02 13:13 EDT — AC-0197

Subagent: single xhigh subagent, PLAN + IMPLEMENT + VERIFY in one turn.

### Baselines captured (BEFORE edits)
- **genhash baseline** (25 lines, byte-identical target): `.scratch/AC-0156-gates/genhash_A.txt`
  (first line `GENHASH -2 -2 8b4cf7c7975d560dff183f2359d019ee`).
- **colbytes v2 (dense codec) storage**: `.scratch/AC-0197-gates/colbytes_before.log`
  `RESULT {"bytes_avg":4338,"bytes_max":5947,"bytes_min":2806,"codec_version":2,"n":25,
  "top_max":219,"top_min":143,...}` — 25 real columns (spawn + golden-angle ring r=24,
  seed 44). Note: v2 zlib already crushes zero slabs → avg 4338 B, not the 8 KB in the notes.
- **R50 before**: `.scratch/AC-0197-gates/r50_before.log` — 2 attempts:
  1. `timeout 3200` run (new arm + pre-edit world/chunk/lighting/io) → **EXIT=124, no RESULT,
     0 SCRIPT ERROR, log = 4 banner lines only**. Two latent problems, both fixed for attempt 2:
     (a) no progress output existed, so it was invisible whether `all`/frame-cap was approached
         (headless physics_frame can tick slower than 60 Hz under load → 108000 frames can
         exceed 3200 s of wall time); (b) the arm's RESULT referenced
         `world.perf_build_worker_ms_list`, a property the pre-edit world.gd does not have →
         the moment the loop exits, RESULT construction would have thrown before Debug.result.
  2. Relaunched (job bash-85) with the **null-safe arm** (`world.get(...)`) against the pre-edit
     world/chunk/lighting/io files (staged from the git index; post-edit copies backed up in
     `.scratch/AC-0197-gates/after_backup/`, md5s in `md5_state.txt`). Env:
     `AWECRAFT_LOGIC=perf AWECRAFT_RADIUS=50 AWECRAFT_PERF_FRAMES=108000`, timeout 3200.
  3. **bash-85 SEGFAULTED (exit 134) at ~frame 80400 (~22.3 min)** — `handle_crash: signal 11`,
     GDScript frame `_tm_worker_run (world.gd:1290)` = `_tm_slots.get(skey)` in the worker spin;
     immediately preceded by `ERROR: /root: The caller thread can't call the function
     propagate_notification()` from the same worker. Root cause: **pre-existing cross-thread
     data race** — worker threads read `_tm_slots`/`_tg_slots` (AC-0152/AC-0178 spin-waits)
     while the main thread sets/erases the same Godot Dictionaries (no internal locking).
     Never hit in the 117+ min of prior R50 load-arm runs; exposed by the longer perf-arm soak.
     Fix (D3): `Mutex` around every `_tm_slots`/`_tg_slots` access in BOTH the before and the
     after world.gd (behavior-neutral thread safety; the spin semantics unchanged). Log:
     `r50_before_crash1.log`.
  4. bash-86 (before + mutex fix) — **no segfault** (passed the old crash point at
     frame 80400 cleanly) and the world meshing actually COMPLETED: `all` went true at
     ~frame 98500 (PERFPROG last line: frames=98400 built=7831 gen=8241). But the arm then
     died on its own null-safe line: `var wml: Array = world.get("perf_build_worker_ms_list")`
     assigns Nil into a TYPED Array var → SCRIPT ERROR (main.gd:8909) → no RESULT → idled to
     the 3200 s timeout (exit 124). Log kept as `r50_before_partial2.log`.
  5. Fixed (wml untyped), bash-87 = before 3rd run. Expected: RESULT at ~frame 98500
     (~28 min of frames), exit 0.

### Arm changes (main.gd, identical in before/after so the comparison is fair)
- `AWECRAFT_PERF_FRAMES` env override (default r50 budget of 51005 frames is smaller than the
  ~27.6-min full R50 drain measured in AC-0178).
- `all` scan skips `band > 2` chunks (the data-only collar made `all` unreachable in the square;
  band-2 runs coarse out to R, so every mesh-eligible chunk in the square is band ≤ 2).
- `PERFPROG` progress line every 600 frames (frames, chunks, built, gen, all) — a stalled drain
  is now visible in the log.
- RESULT gains `built_final`, `band3_in_square`, `max_frames`, `build_worker_n/p50/p95/max`
  (worker list read null-safe; the before run reports n=0 for those).

### Implementation (post-edit state)
- `chunk.gd`: `var top := -1` + `update_top()` (top-down row early-out); `set_local` monotonic
  bump; `init_fl` rescan (covers all 5 gen paths); `build_accs` top clamp (`si1 = mini(slab_n()-1,
  top/16)` for full builds, `y_hi = mini(y_hi, top+1)` on the top slab, `ctx.get("top", -1)` so
  the AC-0187 scoped edit path is untouched); `_bake_box` row-scoped allocation (`bmn.y = y_lo`,
  full-height call byte-identical); `apply_accs` range-aware (`res.slabs[si - si0]`, si0/si1 from
  res).
- `lighting.gd`: `compute_light_flat_chunk_pull(..., top := -1)` — `hact = top+1`; column scan
  truncated; eff rows above top filled 15 directly (provably identical: open sky, flood only
  raises, 15 is max); eff flood/inject/re-flood truncated to hact; own-glow flood truncated to
  `min(h, top+15)`; **imported (neighbor-strip) light path stays full-height so the block-light
  mask is byte-identical in every cell**; `_flood_flat(..., hact := -1)` (seed scan + upward-step
  bound + pattern sized to active rows; default full height).
- `world.gd`: `c.update_top()` at both disk-load sites + `_apply_edits_to_chunk`;
  `ctx_w["top"] = int(c.top)` in `_mesh_dispatch`; `perf_build_worker_ms_list` + appends at both
  threadmesh handoff sites.
- `chunk_io.gd`: `VERSION := 3`, `V2_VERSION := 2`; decode accepts {1,2,3}; v3 section =
  `u8 n_present + u16 slab indices + self-delimiting payloads`, absent slabs zero-filled;
  slabs > top/16 omitted without scanning, slabs ≤ top/16 get an early-exit 4096-byte zero scan;
  `encode_column(..., top := -1)` derives the top internally (io write worker unchanged);
  decoder fail-closed (count/index/range/dup/palette/bit consistency/truncation).

### Gates — FINAL (all run 2026-09-02 EDT)
- [x] **G0** — PASS (EXIT=0, 0 SCRIPT ERROR).
- [x] **genhash 25/25** — PASS, byte-IDENTICAL (raw diff) vs `.scratch/AC-0156-gates/genhash_A.txt`.
- [x] **codec self-test** — PASS, 14/14 true (`v3_selftest.gd`: v1 20526 B / v2 20835 B / v3 20802 B
      decode, round-trip ±top ±light, explicit-vs-derived top identical blob, corrupt/seed/height reject).
- [x] **colbytes** — before v2 avg 4338 B → after v3 avg **4258 B** (−1.8%), min 2806→2734,
      max 5947→5867, ms 6362→6267, tops identical. Modest by construction (zlib pre-crush).
- [x] **SMOKE battery** — PASS, all 5 arms, 0 SCRIPT ERROR; light arm EXACT
      (surface 15 / cave 10 / torch 14 / far 1→9).
- [x] **R50 before** — final (4th) run clean: built_final **7845**, build_ms **668,805**,
      frame p95 **143 ms**, frame max **4876 ms**, frames 99,244, drain 3106 s, mem 6087 MB.
      (attempts 1–3: timeout, segfault→mutex fix, typed-nil arm bug→fixed, load-kill→re-run;
      see notes 2–4.)
- [x] **R50 after** — EXIT=0, 0 errors: built_final **7845**, build_ms **617,398 (−7.7%)**,
      frames **88,910 (−10.4%)**, frame max **3282 ms (−32.7%)**, frame p95 163 ms,
      build_worker n/p50/p95/max **22,553 / 191 / 240 / 431 ms** (after-only metric),
      mem 5978 MB (−109 MB). **The as-written p95 build_worker <30 ms target is NOT met**
      (240 ms) — unreachable at full-24-slab-build granularity on a 3×-loaded box; the before
      side has no worker instrumentation. Frames/build_ms/tail deltas are the honest wins.
- **Coordinator owns: r4 heavy + genhash×2 + Windows build (NOT run by this subagent).**
- Gate-run hiccups (all fixed, all gates green on re-run): missing `return` in legacy
  `_decode_array` (v3 rewrite artifact → 2 SCRIPT ERRORs cascading to save.gd) and an orphaned
  line in `v3_selftest.gd`; before-baseline also hit the pre-existing `_tm_slots`/`_tg_slots`
  cross-thread race (segfault, D3 mutex fix applied to both sides).
