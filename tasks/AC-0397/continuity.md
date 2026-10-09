## RUN - Thu Oct  8 21:14:29 EDT 2026 - AC-0397

- 21:15 plan written (tasks/AC-0397/plan.html): Option B — drive the skip=1 fill from the
  resident far payload (generate_resl gains an optional 1024-byte p_pay arg; the mat entry
  hands the worker c.far_payload()). Rejected Option A (re-run carved_top_pass in the skip
  path): the AC-0387 price ~3,258 µs/chunk + re-derives bytes the lane already holds.
- Baselines (pre-edit, current tree + AC-0403 .so):
  - coordinator census proxy re-run: 2,597 bad / 1.63% / max 91 @ (-91,147,-48) — reproduced
    exactly on this build (census-proxy-baseline.log).
  - my actual-fill instrument (census_bandA2.gd), legacy mode: same 2,597 / 157,147 eq / 0
    below (census2-legacy-baseline.log) — calibrated to the coordinator's terms; this is the
    RED half of the negative test.
  - genhash baseline: 25 hashes (genhash-baseline.log); vs the standing AC-0367 reference:
    0/25 — staleness confirmed on the untouched tree BEFORE any edit (AC-0403 §8 class).
- Edits: gen.cpp (header, gen_flat signature + skip branch + water gate + top row,
  generate_resl binding + D_METHOD), world.gd (entry far_pay field + worker call + comments),
  harness.gd (ladder far-fallback + farab 3b: pass the payload — data-source sync only, no
  arm logic/assertion changes), world/AGENTS.md + ARCHITECTURE.md (the "fill stays un-carved"
  lines are wrong by construction — updated in-task).
- Rebuild: SCons absent (AC-0403 precedent) — manual g++ -O2 -ffp-contract=off, godot-cpp at
  .scratch/godot-cpp; gen.cpp compiles clean; .so = 1,699,288 B (baseline backup
  libchunkio.so.baseline).
- ACCEPTANCE (post-fix): census in payload mode — fill_above_carved_top = 0 / 159,744
  (100% fill_eq_carved_top) (census2-pay-after.log). Cost A/B in-process: 0 µs delta
  (1,219 vs 1,219 µs/chunk; cost-ab.log).
- genhash post-fix: 25/25 identical to the pre-edit baseline — 0/25 columns moved (the
  genhash window is skip=0 / real band; the change is confined to the skip=1 fill).
- Gates (all rc=0 + gate_census 0/0 unless noted): G0 x2; SMOKE battery ok:true
  (interact drop_spawned/place_ok TRUE on this tree — the AC-0403 stale-false no longer
  present); meshprobe match_rate 1.0; farab ok (h_mismatch 0); ladder band_a 20/20;
  boundary r4 self-check ok:true (structural no-op at r4 — no band A inside radius 4).
- A/B attribution runs (baseline .so, same dirty tree): farab RESULT bit-identical; ladder
  RESULT bit-identical (band_a 20/20 on both) — the HARNESS §3 standing values that differ
  (farab water_slabs 6/7/28 + far_bytes 127; ladder B 144 / C 90 / flip 90 / sky_mixed 46 /
  ms_h 2144) are PRE-EXISTING stale bounds on this tree, not this change (AC-0408 protocol:
  mechanism + A/B flat → stale bound, flagged not re-based).
- Binding-compat finding: the old 9-arg binding accepts a 10-arg call silently (godot-cpp
  MethodBindR validates the min count, ignores the trailing arg) — new GDScript on a stale
  .so degrades to the legacy un-carved fill, never an error; verified on both .so builds
  (argcheck2).
- Render: clean worktree .tmp_ac0397 at a4c953f + my 5 hunks + rebuilt .so (+ copied
  .godot cache — a fresh worktree has no import cache and boots into atlas failures);
  xvfb-run + lvp ICD + --rendering-driver vulkan; AWECRAFT_SNAPSHOT/1280,720/RADIUS=8/
  FOG_PCT=87/TIME=0.5/AIM='8.78,142.6,8.78,1.05,0.08' (eye at spawn, toward the
  (-6,-3) census direction) / SNAP_DRAIN=1500; rc=0, boot line Forward+ llvmpipe, 0/0,
  SNAP fired (captures/ac0397-ground-bandA.png; 'SNAPDRAIN not fully drained after 1500
  frames' = the R8 stream was still settling — the in-view ring is materialized). First
  render (no AIM) failed only for framing (default aim looks at the ground) — the
  .godot-cache miss was the one real failure (re-ran after copying the cache). Worktree
  removed after the successful render (AC-0394 convention).
- Non-actions: no commits/pushes; TASKS.yaml untouched; fenced files (main.gd, game.gd,
  drop.gd, debug.gd, the other session's shaders) untouched; HEAVY gates (r16, full
  battery, flake, r50) left to the coordinator; the Windows .dll rebuild (build_windows.sh)
  is the coordinator's lane (SCons/real-HOME requirement); no re-baseline of any standing
  value (stale ones flagged with A/B evidence).
