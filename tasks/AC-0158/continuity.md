# AC-0158 — 20hz-diamond-game-tick — continuity

## 2026-08-31 — builder run (plan + implement + verify)

### Design
- **Clock:** `TICK_INTERVAL := 0.05` (20 Hz) replaces `FLUID_TICK_INTERVAL := 0.2`. The 5 Hz `Timer` node is gone (`fluid_timer`/`_on_fluid_tick` deleted). Fixed-step accumulator `world.gd::_game_tick_accumulate(delta)` runs at the top of the existing `_process`: `while _tick_acc >= 0.05 and n < 4: tick` — stalled frames drop backlog (cap `TICK_MAX_CATCHUP=4`), no death spiral. Gated on `game_tick_enabled` (default true) + `Game.mode in {play,pause}` (same gate the old timer had). `_game_tick()` = `tick_index += 1` → `_random_tick_pass(tick_index)` → `tick_fluids()` if `fluid_sim_enabled` → append ms to `game_tick_samples`.
- **Random ticks:** per 20 Hz tick, per existing band-0 home chunk (face≤1, band==0, data non-empty), per 16×16×16 subchunk (24/column, `SUBCHUNKS_PER_COLUMN`): exactly one cell. Deterministic derivation: `hcol = splitmix64-chain(world_seed, t, cx, cz)` (once per column); per subchunk `h = mix(hcol ^ (sub * 0x9E3779B9))`; `lx = h & 15; ly = (h>>4) & 15; lz = (h>>8) & 15`. 64-bit constants built from 32-bit halves in `_ready` (GDScript has no hex literal > 2^63-1 — verified: `0xFFFFFFFFFFFFFFFF` is a SCRIPT ERROR; int arithmetic wraps mod 2^64; use `& 15` not `% 16` on possibly-negative hashes).
- **Counters/hook:** `random_tick_total`, `random_tick_map` (int key `((cx+4096)*16384+(cz+4096))*24+sub` — no strings in the hot path; the first key design with 8192 wasn't invertible mod 24, caught by inspection), opt-in `random_tick_log` → `random_tick_seq` (one PackedInt32Array per tick: [base,sub,lx,ly,lz] × 984, columns sorted for stable ordering). Consumer hook = `_apply_random_tick` (counter only — no crops in this codebase).
- **Fluids at 20 Hz:** `tick_fluids()` unchanged except `fluid_tick_count += 1`. The `fluid_wet` sleep (stable ≥ 3) kept as-is — at 20 Hz sleep engages in 0.15 s (faster than the old 0.6 s); natural ocean is fl=0 → zero work either way.
- **Region contracts (predicates + constants only, feature work deferred):** `REDSTONE_DUST_DELAY_TICKS := 1`; `MOB_SPAWN_CIRCLE_MIN/MAX := 24/44` (`in_mob_spawn_circle(d2)` squared-distance, unit per caller); `in_mob_spawn_diamond(dx,dz)` = taxi ≤ `band0_r - 1` (n−1 of Simulate n=4); `in_mob_spawn_region` = union. Self-checked in the probe (`region_ok`).
- **Probe** `AWECRAFT_LOGIC=tick` (`_tick_test` in main.gd): disable tick at dispatch → recenter r4 → wait 41-set data-ready → settle (41-set MESHED + queue size stable 90 frames — 40 unbuildable ring entries make queue_size==0 unreachable; builds-in-flight collapse measured hz to ~9 Hz via the catch-up cap, so the window must run at rest) → reset `tick_index=0` + counters → 120-tick window (fluid sim on) → measure. RESULT: hz + hz2 (last-half, GATED [18,22]), fluid_hz, cols/subchunks/min/max counts, scope_bad, band123_ticks, 6 per-subchunk samples, local-cell min/max (4096 bins), recompute mismatch vs the spec function, md5_first/md5_last/window_md5, tick_ms mean/p95/max, frame p95/max/>100 ms, phase_ms, region_ok.
- **Why hz2:** a 247–563 ms worker-handoff frame drops 4–7 catch-up ticks (cap 4); full-window rate dipped to 17.2 in one run. Last-half rate = steady-state clock rate (20.03).

### Builder gate results (logs `.scratch/AC-0158-gates/`)
- G0: exit 0, 0 SCRIPT ERROR (g0_final.log).
- SMOKE battery (smoke1.log, 284.5 s): battery ok:true — player [8.5,137,8.5]/135.43/136.78; interact place_ok true; light 15/10/14/9; fluids sea **2756/2756 + 914/914 stable**, 25/9, delta 1 (NO drift — fluids arm is tick-count based via explicit Debug.tick_fluids() calls); genhash 25/25 byte-identical to AC-0091 baseline (genhash_new.txt diff clean).
- tick probe (tick10.log; tick5/7/8/9/10 all ok:true with IDENTICAL window_md5 d81250cdbeb79419156517a7bad108b0): hz 19.90 / hz2 20.03; fluid_hz 19.90; 41 cols, 984 subchunks, min=max=120; scope_bad 0; recompute 0/118080; region_ok true; tick_ms 1.83/6.77/21.96 (mean/p95/max); wall 49.0 s.
- save arm ok:true (6/6 blocks, iso, v1_softfail); continue arm edits_ok/pos_ok/saved_ok true (load_spawn_ms 72580 — observation only).
- RENDER: exit 0, m4 ok 1280×720 → tasks/AC-0158/render_r1.png (top-down AWECRAFT_AIM 8,240,8,0,-1.57, R=1). First attempt with a relative PNG path failed to save (save_png needs absolute) — no file, not counted; the saved pass is the single render.

### Deviations of record (details in results.html)
1. "half columns" = 41 ≈ 81/2 (taxi diamond vs the 9×9 chebyshev square).
2. "exactly 1 tick/16³/tick" implemented per brief ⇒ ~205 s/wheat cadence, not the note's ~68 s (which implies ~3 ticks/16³/tick, Bedrock randomTickSpeed=1). Recorded for when crops land.
3. Redstone/mob-spawn = constants + pure predicates only; feature work deferred.
4. hz gated on last-half (hz2); full hz also reported.
5. Probe boot served from AC-0155 chunk disk files (boot_ready ~3 ms); fresh boot +3–6 s (still ≤60 s).

### Coordinator watch items (heavy gates)
- boundary r4 walk p95 (band 73–89): +tick cost (~1.8 ms mean every ~3rd frame at 60 fps) + 4× fluid-pass calls → expect small upward drift.
- perf r4: +~4 % per-frame budget; frame p95 (~49 ms) may drift up a few ms.
- tick probe re-run must reproduce window_md5 d81250cdbeb79419156517a7bad108b0 (fresh process, seed 44, ticks 1..120).
- HARNESS.md §1 needs a `tick` row at closeout (builder left it alone per fence).
