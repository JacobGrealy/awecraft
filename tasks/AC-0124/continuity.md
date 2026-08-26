# AC-0124 continuity log (append-only; resume from the last entry)

## RUN 1 (research/planner, xhigh) — 2026-08-26

### Entry R1.0 — context read (spec, CONTINUITY 00e, ARCHITECTURE, two-phase template, build scripts, HARNESS, .gitignore)
- Spec gates G1–G6 read verbatim from `tasks/AC-0124/spec.html` (coordinator-gated).
- Deletion inventory candidates confirmed on disk (see R1.1).
- `build_windows.sh` references presets BY NAME (`--export-release "Windows"` :105, `--export-debug "Windows (console debug)"` :118) → deleting `[preset.0]` (Web) from `export_presets.cfg` is safe; Godot renumbers remaining presets; script needs NO change.
- `build_web.sh` stamps `godot/core/build_id.gd` and restores it; on-disk value = `"dev"`; `build_windows.sh` never stamps it → deleting build_web.sh loses nothing (menu shows `AweCraft[dev]` today already).
- `web/ssl/` cert: self-signed CN=AweCraft, made 2026-08-18 08:52 UTC by a one-time manual `openssl req` (no generator code in repo). ONLY reader = `serve_web.py` (lines 7, 36, 293–294). Nothing else reads web/ssl.
- 8443 daemon state at research time: NOT LISTENING (ss shows only 5180 + 8080); `.scratch/serve_web.pid` = 5 = STALE (dead). 5th known death (around the 08:53 AC-0119 background build). So the 8443 stop = verify-dead + remove pidfile/logs, or kill-if-revived (procedure in plan §4/G5).
- 5180 = tasks webui (AC-0046; `.scratch/tasks_webui.pid`), 8080 = windows export serve (`.scratch/serve_win_export.pid`) — BOTH stay, different processes.
- No README, no CI/.github in repo. Repo-root `plan.html` (2026-08-15 legacy) mentions "WebAudio" (JS API — false positive, allowlisted, out of doc-edit scope).
- `REMAINING_FEATURES.html` web refs = web-as-frozen-spec references only (lines 5, 7) — KEEP, no edit.
- `godot/ARCHITECTURE.md` has NO web-compat section (all "web" mentions = frozen-spec fidelity refs, lines 10–12, 39–40, 43, 47, 52–57, 62) — only a one-line note about the dropped export is needed.
- `godot/project.godot`: no web references at all.

### Entry R1.1 — web-reference sweep (code + scripts + configs + harness + docs)
Full audit table goes into plan.html §4. Key findings:
- NO WebRTC, NO ENet, NO MultiplayerPeer code anywhere in godot/ — the "WebRTC/ENet duality" from the registry is a phantom; ENet is reserved-for-MP only in the sense that no net code exists yet. Stated in plan decision D-ENet.
- `chunk.gd` / `lighting.gd` have NO runtime web gates (no has_feature) — only frozen-spec reference comments (chunk.gd:606 needs a wording update: it names "web + AWECRAFT_THREADMESH=0"; lighting.gd:21,109,194 are spec refs, keep).
- `save.gd` (AC-0081) has NO explicit web/IndexedDB branch — `user://` is transparent (Godot maps it to IndexedDB on web exports, files on native). The "IndexedDB quirk" is implicit and vanishes with the web export. `clear()` uses `DirAccess.remove_absolute(ProjectSettings.globalize_path(p))` (:101) — native-safe, keep.
- `main.gd:458/461/852/856/3477-3481` `webfall`/`_web_waterfall` = WEB-fALL fluid waterfall test (name collision) — KEEP, not web-platform.
- `main.gd:4048` `mainmenuexit` RESULT field `"web_nothreads": OS.has_feature("web_nothreads")` — informational, DELETE (update HARNESS.md row).
- 5 `has_feature` sites total: main.gd:4048, menu.gd:56, menu.gd:221, world.gd:150, world.gd:165.
- menu.gd `_is_web` sites: 38, 56, 66 (FileDialog ACCESS_FILESYSTEM), 227 (pack dialog no-op), 437–439 + 580–582 (pack buttons disabled+tooltip).
- world.gd env gates: 147–182 (AWECRAFT_THREADGEN/THREADMESH/FORCE_WEB/web_nothreads + _N + TGDEBUG/TMDEBUG).
- Spawn chunk: data gen sync at world.gd:424 (`absi(cx)>0 and absi(cz)>0`), mesh sync at world.gd:595 (`cx==0 and cz==0`) + `_ensure_spawn_chunk` 1499–1504 + `spawn_point` 1506. All NATIVE, all stay.
- `_mesh_dispatch` sync fallbacks (world.gd:586–642): spawn / empty-data / missing-neighbor (:608) / cap-drop (:622) — NATIVE safety paths, stay. Only the env-gate web arms die.
- `chunk.gd:1363` `build_mesh` (~185 lines, sync body) + `:1549` `apply_accs` (thread handoff) — both survive; `build_mesh` serves spawn + cap-drop + missing-neighbor.
- settings.gd:6 `const RENDER_MAX := 96` (clamp :52); menu.gd:536 slider max 96; main.gd:521 settings harness asserts 96.

### Entry R1.2 — headless pre-change anchors (measured 2026-08-26, UNMODIFIED tree, threaded default = production config)
Sequence (godot ONE at a time): G0 --quit → genhash → full battery → perf r4 → boundary r4 → [bg] boundary r50 RECPROBE → [bg] perf r96.
- **G0**: RC=0, 0× SCRIPT ERROR.
- **G2 genhash**: 25/25 lines, GENMS 803, MD5-of-25-lines = `61de26e9a542a5ce2db62e7157d6c018`.
- **G3 battery** (player;interact;light;fluids;buckets): ok=true, 0 errors. player 2.82/36.43/37.78; interact drop+place true (breakable 2, after_place 2); light 15/0/14/9; fluids 2730/2730, 1406/1406, stable, water_delta 1, shore [5,7], source [5,8], lava 25/9; buckets scoop [5,8]→140×1→place [5,8].
- **G4 perf r4** (`AWECRAFT_LOGIC=perf AWECRAFT_RADIUS=4`): chunks=81 all_meshed=true; **total_ms=6447**; build_ms=332; gen_ms=693; p95=43/p50=14; max_frame=68; first_draw=262; drain_frames=684; **read_sync_gen=0**; create_sync_gen=1; collision_shapes=81; light_batch_calls=1.
- **G4 boundary r4** (`AWECRAFT_LOGIC=boundary AWECRAFT_RADIUS=4`): ok=true; p95=33/p50=14/max=73; **flap=0**; **forward_p95_ms=4840** (fwd_max 4944); trailing_p95=38; burst_p95=4840; irb 81/81/19; present 81; loads 220/unloads 209; mem_delta 29.8 MB; marker+remesh ok.
- **G4 boundary r50 + RECPROBE** (`AWECRAFT_LOGIC=boundary AWECRAFT_RADIUS=50 AWECRAFT_RECPROBE=1`, bg job): ok=true; **RECSLICE cold = total 138.0 / max_ms 11.0 / 28 frames** (first recenter, new_n=10609); **RECSLICE steady = total 62.0 / max_ms 7.0 / 27 frames** (cross recenter); RECPROBE walk-recentsers ≈ 9–11 ms; RESULT p95=44/max=108/flap=0; **read_sync_gen=0**; create_sync_gen=1; irb 350/193/20; present 10201; queue 10274; mem_delta 163 MB; forward_p95=0 (walk completes before r50 band resolves — same shape as the AC-0118 era; the gate uses RECSLICE + p95 + flap).
- **G4 RENDER_MAX-96 definition run** (`AWECRAFT_LOGIC=perf AWECRAFT_RADIUS=96`): definition = all_meshed:true @ render_radius 96 (37249 chunks), RC=0, 0 errors, wall ≤ pre+10%. FIRST ATTEMPT (bg bash-31, 09:56:43): killed by MY 2900 s timeout wrap at wall_s=2901 (RC=124) — 0 script errors, no RESULT line (no progress lines in log without AWECRAFT_TIMING). Run-1 ops error (wrap too short for a worker-bound r96: ~37249 chunks × ~150–230 ms worker / 3 in-flight ≈ 41–50 min + recenter/drain). RERUN launched (bg bash-32) with 7200 s wrap; value recorded in R1.3.
- Ops note: one botched early call (ran godot without a quit hook, 120 s tool-kill) left NO stray process (verified by /proc scan); a `pkill -f` pattern self-matched its own shell once — corrected to pid-scoped /proc verification. No other impact.

### Entry R1.3 — plan.html written + citation audit (2026-08-26 ~10:50)
- `tasks/AC-0124/plan.html` complete: 7 sections in order (Goal / Files-to-touch audit / Frozen spec refs / Data.* ids / Harness gates G1–G6 / Snapshot names (N/A, justified) / Risks + D1–D7). Audit = 55 rows (19 DELETE / 22 REWRITE / 14 KEEP).
- Every cited file:line re-verified against the unmodified tree in this run (menu.gd 38/56/66-67/220-223/226-229/437-439/580-582; world.gd 147-182 exact if/elif structure (web branches are PRINT-ONLY), 200-225, 424, 589, 595, 608, 622; chunk.gd 606/1294/1363/1475/1549; lighting.gd 21/109/194; atlas.gd 192; data.gd 3-5/208; generator.gd 45-54; save.gd 10-104; main.gd 106/153/204/4048/521; settings.gd 6/52; menu.gd 536; build_id.gd; export_presets.cfg 1-42; build_windows.sh 105/118; serve_web.py 293-294; .gitignore 2; HARNESS.md 39/50/51/59/101/175; AGENTS.md 4/10/17/18/19/20/23/24/44/47-48; CONTINUITY.md 213/219; ARCHITECTURE.md 10-12).
- NEW findings during the citation pass: (1) `build_windows.sh:2` comment "mirrors build_web.sh" — fence-protected file, comment stays, allowlisted in D7e(6); (2) `exports/*.exe` contain 7 byte-level "8140" hits each — binary coincidence, allowlisted D7e(7); (3) spec's "battery web BATTSKIP arms" + "WebRTC/ENet dual net code" + "IndexedDB save quirk" = PHANTOMS (no such code exists; documented in b26/c1/c2); (4) HARNESS.md:51 boundary row ALSO lists the bare AWECRAFT_THREADGEN knob (d3 now covers :50/:51/:175); (5) the 8443 daemon is dead (5th build-adjacent death) — G5 default path = verify + cleanup.
- Phantom items the spec's auto-gate table (pre-web-drop era) will not match post-change — expected and noted: none affect G1–G6.
- REMAINING: collect the r96 definition-run rerun (bg bash-32, 7200 s wrap, launched ~10:47) → transcribe its RESULT + wall into plan §5-G4 row (4) + D4 → final report.

### Entry R1.4 — RENDER_MAX-96 definition run COMPLETE + D4 finalized (2026-08-26 11:41)
- bash-32 (7200 s wrap) finished: **wall_s=3096, PERF_R96_RC=0, 0 script errors**, log `.scratch/AC-0124/perf_r96b.log`.
- RESULT: `frames=186245` (= the harness cap `maxi(1200,(2r+1)²·5)` at r96 — main.gd:4649), **`all_meshed=false`, `chunks_built=20424` (54.8% of the 37249 band)** at the cap; `total_chunks=38025` (=195², world r97); `total_ms=3,093,673`; `build_ms=10436`; `gen_ms=15832`; `first_draw_ms=1582`; `recenter_ms=1` (amortized); `p95_ms=68` (p50 0); `max_frame_ms=135`; `drain_frames=41736`; `max_drain_ms=132.0`; `staged_drained=20415 staged_dropped=0 staged_pending_final=0`; `read_sync_gen=0`; `create_sync_gen=1`; `collision_shapes=20424`; `light_batch_calls=0`; `mem_after=8.97 GB`; `fog_ok=true`.
- INTERPRETATION: sustained ~6.6 chunks/s at the cap → full all_meshed at r96 ≈ **90–100 min progressive pop-in** (fog_far 1474 u ≈ 92-chunk radius hides the edge — AC-0072 design). The harness cap is an observation window (the game keeps meshing in play), NOT a behavior limit.
- **D4 (plan §5-G4 row 4 + §7) finalized** to the measured definition: RC=0/0-errors/`staged_dropped=0`/`read_sync_gen=0` hard/`fog_ok`/`p95 ≤ 80`/`max_frame ≤ 160`/`chunks_built ≥ 18000` (−15% floor)/`frames=186245`/`total_ms ∈ [2.6M,3.6M]`. No harness change needed.
- Also this session: (1) dry-ran ALL G1 greps pre-change → baseline captured; FOUND + fixed 3 audit gaps: **e14** (AGENTS.md:51 rolling status line carries build_web/serve_web/web_nothreads/IndexedDB/AWECRAFT_THREADMESH tokens — was uncovered), **b28** (chunk.gd:606 worker-header comment — was misfiled in the zero-action note), G1d allowlist corrected (§5 :124 incident note; §8:211 claim was stale). Audit now 57 rows = 19 DELETE / 24 REWRITE / 14 KEEP. (2) Verified every doc row (e1–e14) against actual AGENTS/CONTINUITY/HARNESS/ARCHITECTURE/REMAINING_FEATURES lines. (3) Fixed cross-refs (b19→b23, b23→d4) + §6 spec-quote accuracy.
- **STATE: plan.html COMPLETE (all 7 sections, all citations line-verified, all pre-change anchors measured, D1–D7 unambiguous). Run-1 done — hand off to coordinator → Run-2.**
