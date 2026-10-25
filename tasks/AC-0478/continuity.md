# AC-0478 continuity (builder journal, append-only)

## RUN — 2026-10-25 09:24 UTC — AC-0478 (re-bake + re-ship the canonical seed-44 satellite faces)

- TASK: regenerate `godot/assets/satellite/satellite_face00..11.png` from the CURRENT (post-AC-0469-stage-D)
  bake. The coordinator's round-103 finding (in TASKS.yaml) proved the canonical seed reads the SHIPPED
  res:// PNGs (phase 2 of the three-phase source, `satellite_body.gd:455-470`, `ResourceLoader.res`
  predicate — the AC-0384 export-condition fix), and the bake is only the non-canonical fallback. The
  shipped set is dated Oct 4 (AC-0384 r3 re-ship), before stage D rebuilt the far-tier bake.
- PROVENANCE ANSWER (step 1): the shipped PNGs were produced by the in-engine bake worker's own output,
  re-shipped in-process by the harness-only `AWECRAFT_SATELLITE_SHIP=<abs dir>` env: the `satellite` arm
  run with `AWECRAFT_SATELLITE_REBAKE=1` forces the full bake (sharded pipeline, `sat_preload` default ON),
  and at assembly `SatelliteBakeWorker.ship_faces` (satellite_bake_worker.gd:645-663, called from
  satellite_body.gd:808) byte-copies the 12 cache PNGs into the ship dir. The Oct 4 re-ship used exactly
  this path (AC-0384 results §r2: "satellite (REBAKE + SHIP, seed 44): bake wall 793.9 s, guard 12/12,
  rebuild_vs_shipped identical (589,824 samples, diff 0), 12 faces shipped", then `.ctex` re-imported).
  THE PATH STILL EXISTS, UNCHANGED — no approximation needed. (Historic alternative: the AC-0310/AC-0311
  python rebake over a dumped far payload — superseded; the in-engine ship is the canonical mechanism.)
- BEFORE METRICS (AC-0412 instruments, .scratch/AC-0412/pngmetrics.py + rendermetrics.py, full frame,
  all 12 shipped faces): face00 grain_x 0.0104 / grain_y 0.0144, runH max 107, colrow 0.36, streakdir
  0.48 — reproduces the AC-0412 archived log line exactly (instrument validated). THE r21-Era SIGNATURE
  IS IN THE ASSET: chart faces 02-11 carry runH mean_frac 0.93-0.96 (near-flat rows), max constant runs
  up to 769 px (face04 runH) and 777 px (face08 runV) vs ~112-115 on the current-pipeline bake faces
  (seed 5432, AC-0412 log); per-face streakdir (dcol/drow) 1.28-2.93 on faces 02/03/04/05/08/09/10/11
  (face09 = 2.93), colrow spread 0.36-2.21 — the old bake's flat/bleeded ground + column structure,
  exactly what stage D (100% face coverage, no 329-chunk past-edge read) was supposed to fix.
- BAKE: launched 09:24:34Z as the ALONE engine job (`.scratch/AC-0478/run_bake.sh`: satellite arm +
  REBAKE=1 + SHIP=.scratch/AC-0478/ship, headless, 8 GiB ulimit, timeout 3600 s). Budget per AC-0469
  stage D: 1,269 s wall / 4.603 GiB peak RSS per seed. Startup log confirms `seed=44 src=res
  predicate=ResourceLoader.res` (the res phase — the stale asset) then `multithreaded start (seed 44) -
  1169 shards x 1454 records + 12 faces` = 1,699,726 records (the sD payload exactly).
  (Deviations D1: first launch rc=127 — the script exported HOME=/tmp/dsh_home BEFORE the
  `~/tools/godot/godot` call, so `~` expanded to the sandboxed HOME; fixed to the absolute engine path.
  D2: this pre-ship bake run's RESULT is expected to report ok=false on `rebuild_vs_shipped` alone —
  that diff IS the staleness proof, by design of the arm's reproducibility check.)

- BAKE DONE 09:45:22Z: **rc=0, wall 1198 s** (under the 1,269 s / 4.603 GiB stage-D budget;
  RESULT rebake block: gen_wall_ms 1,146,371 + face_wall_ms 26,029 + png ~7 s = 1,179.5 s bake;
  frames 4773; guard 12/12; the arm's own census: 0 SCRIPT / 0 SHADER ERROR lines). Ship report:
  "shipped 12 height-channel faces to .scratch/AC-0478/ship". **STALENESS PROOF (as designed, D2):
  rebuild_vs_shipped diff_px 138,220 / 589,824 (23.4%), max_abs_diff 233/255, identical=false** —
  the current in-engine bake diverges strongly from the shipped asset. Everything else in that run's
  RESULT was green (res_export_ok 12/12, guard, ladder 4/4, height_decode on the old res asset,
  ac0390 ok).
- SHIPPED-OUTPUT VERIFICATION: 12 x "PNG 1024x1024 8-bit RGBA non-interlaced" = the SAME format,
  dimensions and orientation contract as the old set (the ship step is a byte copy of the worker's
  cache PNG, satellite_bake_worker.gd:645-663; md5-verified ship/ == the harness's hardcoded
  rebake cache copies 12/12; pixel layout in the worker is deterministic — u->x, v->y row-major,
  alpha = round(H*255/HMAX) — unchanged by sD, which altered only which cell each texel reads).
  CROSS-CHECK: faces 00/01 (the home pair — the f<=1 branch the sD fix does not touch) came out
  BYTE-IDENTICAL to the old shipped md5s (244b5109.../fb140791...); faces 02-11 (the chart faces,
  the sD footprint) are new. AC-0469's own A/B render showed the same split (disc centre / home
  pair bit-identical). So the diff is exactly where stage D changed the pipeline.
- DEPLOY: 12 PNGs copied to godot/assets/satellite/ under the same names (md5-verified), .import
  sidecars untouched. Re-import via engine `--headless --import` (rc=0): the 10 changed faces'
  `.godot/imported/*.ctex` rewritten IN PLACE under their stable hash names (face02 772,494 ->
  866,012 B; the `.md5` sidecars now carry the new source_md5, e.g. face02
  source_md5=13ff1248... = the new PNG); faces 00/01 correctly skipped (source byte-identical).
  The .import `path=` lines needed nothing (stable-hash naming); .godot/ was rewritten by the
  engine, never hand-edited. (D5: the first import launch was refused by the script's own slot
  guard — my OUTER command line contained the string "godot" in a path, the same self-match trap;
  relaunched with a clean invocation.)
- AFTER METRICS (same instruments, full frame, the new shipped 12): the r21-era signature is gone
  from the chart faces. runH mean_frac 0.924-0.964 (old) -> 0.804-0.871 (new; the current-pipeline
  reference band is 0.80-0.84). Max near-constant runs: runH 769/610/607/556 (old f04/f06/f07/f05)
  -> 308/239/186/255; runV 777/547/590/690 (old f08/f09/f10/f11) -> 372/288/315/238. Per-face
  streakdir (dcol/drow): f02 1.29->0.88, f03 1.43->0.89, f08 2.15->1.21, f09 2.93->0.99,
  f10 1.28->0.74, f11 1.54->0.62 (f04/f05 2.34/2.47 = the geometric 2:1 texel-pitch anisotropy,
  cf. AC-0412's current-bake face04 = 2.10 "geometric, not streaky"). HEIGHT-LEVEL PROOF (alpha
  channel, old-from-git vs new): the old H field's profile autocorrelation decays SLOWLY (L10 =
  0.67-0.80 — the past-edge bled ground is long-range correlated); the new field decays to ~0 by
  L8-L10 (f02 u: L1 0.954 -> L8 -0.024; f09 u: L1 0.874 -> L8 -0.050) = the current-pipeline
  signature (AC-0412: L10 0.04-0.28). Full tables in .scratch/AC-0478-gates/facemetrics.log.
- GATES: g0 rc=0 script=0 shader=0 (gate_run.py AC-0478, 3 s); genhash 25 GENHASH lines,
  BYTE-IDENTICAL to the AC-0412 reference (world code untouched); POST-SHIP satellite arm (plain,
  no rebake) **ok=true** — canonical seed 44 took src=res / ResourceLoader.res / via=import on the
  NEW asset: height_decode ok=true with alpha_diff_px=0 and max_byte_diff=0 on 12/12 faces (the
  re-imported .ctex is byte-identical to the raw shipped PNG through the import system),
  geom_vs_texture 0.49 m (pure alpha quantization), guard 12/12, ladder 4/4, ac0390 ok, 0 error
  lines, 15 s wall. (The lone JSON-NaN warning is the arm's pre-existing null rim value at the
  ladder's hidden level — present in every satellite run, this one included pre-ship.)
- RENDER: 2600 m planet-limb shot at seed 44 (the res path = the shipped asset), fwdshot
  Forward+/lavapipe recipe, SAT_ALT=2600, R4, TIME=0.5, NO_FOG=1, CLOUDS=0, SNAP_DRAIN=600,
  1280x720. DONE 09:59Z: rc=0, wall 220 s, PNG 356,413 B. Boot line = the shipped Forward+ path
  (Vulkan 1.4.318 - Forward+ - llvmpipe); configure src=res predicate=ResourceLoader.res (the SHIPPED
  asset); RESULT body_phase 4, drain 600, alt 2600; 0 error lines. METRIC in the r21 box
  (420,350,980,560): **streakdir 0.99** vs the old asset's 1.21 (same box, seed, altitude — the
  AC-0384 r21 frame), grain 0.0071/0.0093 vs 0.0098/0.0108 (−28%); wide limb box streakdir 0.88.
  Frame content (described with numbers, not adjectives): disc carries continuous terrain to the limb
  (green land / blue water / white cloud-snow / tan coast), limb haze gradient, star field; no white
  sphere, no black disc, no seam ring, no tear streaks.
- FINAL STATE: all ticket gates green. Git footprint: exactly 10 modified files
  (satellite_face02..11.png — 00/01 byte-identical, untouched); no .import, no code, no TASKS.yaml.
  Deliverables: AC-0478-results.html, this journal, AC-0478-deviations.txt (D1-D6),
  ac0478-limb-2600.png. No commits (coordinator closeout). D6: peak RSS not sampled this run —
  reported as wall 1,198 s under the 1,269 s / 4.603 GiB stage-D budget, no OOM under the 8 GiB cap.
