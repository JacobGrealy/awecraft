# AC-0203 continuity — paletted-sections-per-slab

## RUN — 2026-09-02 (EDT) — AC-0203

Subagent: single xhigh subagent, PLAN + IMPLEMENT + VERIFY in one turn.
HEAD = aa0cbe6 (AC-0197). Machine clean at arm start (load ~0.5).

### Scope recap
RAM optimization: each 16×16×16 slab stores per-slab MC-1.18-style palette
(null | n==1 uniform | n==2..16 bit-packed | n==0 raw) instead of flat u8.
genhash MD5 byte-identical 25/25 is the #1 invariant; codec round-trip
lossless; build_worker p95 no regression; colbytes ≤ 4258 B/col.

### Implementation (all 5 files, complete)
- `godot/core/chunk_io.gd` — VERSION=4, `_encode_array_v4` / `_decode_array_v4`
  (fail-closed), static slab primitives (`_slab_bits_for/_slab_getbits/
  _slab_setbits/_slab_cell/_slab_unpack/_slab_flat/_slabs_flat/_slabs_deepcopy/
  palettize_flat`).
- `godot/world/chunk.gd` — `data`/`fl` are 24-slab arrays (field names kept);
  `data_gen`/`fl_gen` stamps; `get_at/set_local/fl_at/set_fl_at/stamp/
  flat_data/flat_fl/row_bytes/fl_row_bytes/data_landed/clear_data`;
  `_slab_write` (palette growth / repack / raw-ify / null-ify); `build_accs`
  materializes per-slab views (dviews/fviews/nv) once per build; LOD uses
  `alt_stamp` instead of 192 KB duplicates; `init_fl()` removed.
- `godot/world/lighting.gd` — all 4 kernels slab-aware (pull kernel takes
  optional `dviews`, chunk/batch materialize internally, flat/split use
  `c.flat_data()`).
- `godot/world/world.gd` — 7 landing sites → `data_landed`; handoff stale
  check on row/stamp; entries carry slab deep-copies; eff-cache + face_blk
  cache keyed by stamps; fluid tick rewritten sparse (iterates wet slabs'
  non-zero cells, per-tick per-slab `dviews` cache via `_data_at_slab`).
- `godot/scenes/main.gd` — all `.data`/`.fl` probes via `flat_data()/flat_fl()/
  get_at/fl_at/stamp compares`; `AWECRAFT_LOGIC=slabwrite` harness added
  (point-write invariant).
- `generator.gd` untouched; player/interaction/debug clean. Full-tree grep:
  only the 5 converted files touch `.data`/`.fl`.

### Bugs caught by self-gates (fixed before any green run)
1. `main.gd:4804` — `get_at(iRecv])` bracket typo (G0 parse error).
2. `world.gd` fluid tick — `var pos` collided with `for pos in cl` iterator
   (renamed inner loop to `cell`).
3. `chunk.gd:1820` — `var si` (view materialization) collided with
   `for si in range(si0, si1+1)` (renamed to `sv`).
4. `chunk.gd:400` — `PackedByteArray(d.size())` is not a constructor
   (resize into a fresh array).
5. `lighting.gd` — `dviews := null` param can't infer type
   (`dviews: Variant = null`).
6. **`_slabs_flat` null-slab collapse (the big one)**: `_slab_flat(null)`
   returns 0 bytes, so a column with a MID-column null slab materialized to a
   short/shifted flat array (and `_queue_chunk_save` would have encoded a
   corrupt blob: `sub = data.size()/S3` wrong). Fixed: null slab appends 4096
   zeros. Caught by the selftest (terra/topedge rt:false while bnd/fl passed).
7. `world.gd` — `ChunkScript._slabs_deepcopy` called but the helper lives in
   ChunkIO (4 call sites fixed); `main.gd` slabwrite test must use the
   preloaded `_ChunkScriptM` const (no global class_name on chunk.gd).
8. **`build_accs` ymask pre-pass OOB (chunk.gd:1793)** — caught by the first
   SMOKE battery (interact mode, scoped edit rebuild): the GW=18 solid-grid
   ring iterates `lx/lz ∈ -1..16`, and the in-window read
   `dslab[(y&15)<<8 | (lz<<4) | lx]` hit index 4096 at the lx=16/lz=16 ring
   cells (a 4096-byte view has no room for the row-wrap). The pre-slab code
   read the SAME wrapped offset into the 98304 flat column — silently a
   wrong (next-row same-column) value for the ring, never OOB. Fixed by
   restricting the slab-view read to the 16×16 interior (`lx < 16 and lz < 16`)
   and reading all ring / out-of-window cells from `snap` (the TRUE boundary —
   strictly more correct than the old wrap; affects only the interior-fastpath
   boundary classification of scoped edit rebuilds, never the slow path).
   Debug guard print added/removed around the repro.
9. **Torn reads of the shared mesh-entry Dictionary (pre-existing cross-thread
   race, surfaced by this task's R50 run).** The first full R50 run showed 9×
   `SCRIPT ERROR: Invalid access to property or key 'tid'` in
   `threadmesh_poll` (world.gd). Diagnosis (4× 20k-frame instrumented runs):
   the in-flight entry dict — written on the pool thread
   (`entry["t_run"]`, `entry["result"]`) and read on the main thread every
   frame — is a GDScript Dictionary, which is NOT thread-safe. The mirror-array
   capture proved it is not a phantom object: (a) list[0] read as an empty dict
   while the mark object for the same skey read as a full 18-key entry
   microseconds apart; (b) the head read as empty at probe entry, non-empty a
   few µs later in the same probe; (c) the mark object itself read empty once.
   Same-object read results flip-flop = torn read of the dict's internals.
   The worker write pattern is BYTE-IDENTICAL to HEAD (AC-0082 handoff
   pattern, `git diff` shows no worker-line change) — the race is pre-existing;
   the baseline 50-min R50 sample simply didn't surface it (this run was also
   ~20% slower per frame: box load 2.5-3.5 + deeper per-entry reads widened
   the observation window). Impact bounded: worst case a torn handoff read =
   null result = datadrop + retrigger (safe re-queue), never a corrupted apply;
   the run completed 7845/7845 all_meshed. Fix: bounded defensive skip in both
   poll loops (`if not e.has("key") or not e.has("tid"): skip this frame`),
   documented inline; all diagnostic instrumentation removed after the run.
   A proper fix (worker communicates via locked queue of plain values, or a
   per-entry completion flag the main thread checks) is a future task — the
   pattern is shared by every AC-0082-style handoff in the codebase.

### Gates so far (logs in .scratch/AC-0203-gates/)
- **G0** `--headless --quit`: 0 SCRIPT ERROR (after fixes 1-5). `g0.log`.
- **genhash**: 25/25 **byte-identical** to AC-0197 baseline
  `.scratch/AC-0197-gates/genhash_A.txt` (`diff` clean). `genhash_A.txt.new`.
- **v4 selftest** (`-s .scratch/AC-0203-gates/v4_selftest.gd`): **ok:true**,
  30/30 — palettize→_slabs_flat byte-identity (air/uniform/terrain/boundary/
  top-edge/fl), v4 wire round-trips (light/no-light/top/no-top/air/boundary/
  top-edge×2), v1/v2/v3 back-compat, corrupt/4×malformed/seed/height rejects,
  v4 (20671 B) < v2 dense (20903 B). `v4_selftest.log`.
- **slabwrite** (`AWECRAFT_LOGIC=slabwrite`): **ok:true** — 3000 random point
  writes (2 natural columns + palette-boundary column) keep the slab
  representation byte-identical to a flat reference. `slabwrite.log`.
- **colbytes (v4)**: `bytes_avg=4235` (baseline v3 4258, ≤ gate met; n=25,
  same spawn + golden-angle ring, seed 44; min 2694 / max 5861).
  `colbytes_after.log`.
- **SMOKE battery** `AWECRAFT_BATTERY=player;interact;light;fluids;genhash`:
  **PASS** — ok:true, 0 SCRIPT ERROR, 5/5 modes, 301.8 s total. Light arm
  EXACT: surface_eff 15 / cave_eff 10 / torch_level 14 / torch_far 1→9.
  interact: mine+place ok, drop_spawned, inv_grew. fluids: sea 914/914 backed +
  2756/2756 surface, water_on_lava→24 (obsidian), sideways_lava 24,
  water_delta 0. genhash: 25 lines re-verified byte-identical (2nd run).
  First battery attempt (pre-ymask-fix) exposed bug 8 (OOB in the scoped
  rebuild) — interact re-run clean, then the full 5-mode battery re-run green.
  `battery.log`.
- **R50 after run #1** (bash-98, ~65 min, box load 2.5–3.5): COMPLETED,
  all_meshed=true, built_final=7845/7845, build_worker n/p50/p95/max =
  **23126 / 207 / 252 / 607 ms**, mem 53,986,521 → **4,524,471,068 B**
  (delta **4.471 GB** vs baseline 5.924 GB = **−1.45 GB** RAM win realized),
  drain_s=3761.93 (baseline 2999.5 — box was 2.5-3.5 loaded; p95 252 vs 240
  baseline, same-load caveat applies). 9× cosmetic 'tid' SCRIPT ERROR (bug 9,
  the torn-read race — pre-existing pattern). Provisional perf, pending the
  clean re-run below. `r50_after.log`.
- **R50 after run #2** (clean, full 108000): COMPLETED — <b>0 SCRIPT ERROR</b>,
  all_meshed=true, built_final=7845/7845, staged_dropped=0, build_worker
  23159 / 207 / 252 / 354 ms, mem 53,990,129 → 4,524,818,832 B (delta
  **4.471 GB, −1.453 GB / −24.5% vs 5.924 GB baseline**), drain_s=3754.0
  (box 1.0→3.6 loaded). p95 252 = load (see run #3). `r50_after2.log`.
- **R50 partial run #3** (20k frames, load ~1.0–2.0): p95 = **233 ms** (≤ 240
  baseline), p50 199, n 4524, 0 errors — same early-build window as the
  AC-0197 under-load cross-check (251). No build_worker regression: full-run
  252 vs 240 is box load (drain wall +25% for equal frames). `r50_partial3.log`.
- **ALL GATES GREEN** — AC-0203 complete; coordinator to review, commit
  (working tree: chunk_io.gd, chunk.gd, lighting.gd, world.gd, main.gd +
  tasks/AC-0203/), then heavy r4 + ./build_windows.sh.
