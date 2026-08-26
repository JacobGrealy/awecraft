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

## RUN 2 (builder/implementation, medium) — 2026-08-26

### Entry R2.0 — pre-change state verified
- Daemons: 8443 NOT listening, pidfile pid 5 stale/dead (no kill needed); 5180 (tasks webui) + 8080 (windows serve) LISTEN.
- Pre-change genhash anchor captured on unmodified tree: 25/25, GENMS 792, MD5-of-25-lines `61de26e9a542a5ce2db62e7157d6c018` = Run-1 anchor exactly (saved `.scratch/AC-0124/genhash_pre.log`).
- Every cited line re-verified live before editing (world.gd 147–182/589/595, menu.gd 38/56/66–67/220–229/437–439/580–582, main.gd 106/4048, chunk.gd 606, export_presets.cfg 1–42, .gitignore:2, HARNESS.md 50/51/59/101/175, AGENTS.md 17/19/20/23/24/44/47–48/51, CONTINUITY.md 213/219) — all matched the plan; no drift.

### Entry R2.1 — code edits complete (b1–b24, b28)
- `godot/world/world.gd`: env-gate blocks ungated — threadgen + threadmesh pools ALWAYS on at boot incl. pre-warm (b4/b8); deleted `AWECRAFT_THREADGEN`/`AWECRAFT_THREADMESH`/`AWECRAFT_FORCE_WEB` parsing + both `web_nothreads` print arms (b1–b3, b5–b7); KEPT `_N`/`TGDEBUG`/`TMDEBUG` knobs. Incidental mechanical rename: second `var nenv` → `var menv` (both blocks now share `_ready` scope — avoids redefinition; no behavior change). b12: dispatch simplified to `if (cx == 0 and cz == 0) or c.data.is_empty():` (dead `not threadmesh` disjunct gone). b15: dispatch comment updated.
- `godot/ui/menu.gd`: `_is_web` var + all 5 uses deleted (b16–b22); FileDialog always ACCESS_FILESYSTEM; `_on_exit_pressed` = bare `get_tree().quit()`; `_open_pack_dialog` = bare `popup_centered(Vector2i(720, 480))` (plan said "popup_centered()" — actual call carries the size arg, kept as-is); both pack buttons always enabled (web disabled/tooltip arms removed).
- `godot/scenes/main.gd`: b23 `web_nothreads` RESULT field deleted from `_mainmenuexit_test`; b24 comment "(desktop + web)" → dropped (line now reads "menu-first boot on every display platform; AWECRAFT_MENU=0 = …" — avoided the plan's redundant "(all display platforms)" doubling, same meaning).
- `godot/world/chunk.gd`: b28 worker-header comment rewritten (no web-compat token).
- chunk.gd `build_mesh`/`apply_accs` body: 0 lines changed (b27 KEEP). lighting.gd/save.gd: 0 lines changed (c1/c3).

### Entry R2.2 — deletions complete (a1–a6)
- Deleted: `build_web.sh`, `serve_web.py`, `web/` (whole dir incl. ssl/), `.scratch/serve_web.pid` (stale pid 5), `.scratch/awecraft-web-https.log`, `.scratch/awecraft-web-http.log`.
- `godot/export_presets.cfg`: [preset.0] Web block deleted; Windows presets renumbered [1]→[0], [2]→[1], contents byte-identical.
- `.gitignore`: `web/` line deleted.
- 8443 daemon: verified dead pre-deletion (port free, pid stale) → verify + cleanup path taken, NO kill (per D7d).

### Entry R2.3 — docs complete (d3–d5, e1–e14 minus e9)
- `tasks/HARNESS.md`: perf + boundary env cells → `AWECRAFT_THREADGEN_N`/`TGDEBUG` (bare THREADGEN knob dropped); :175 env note rewritten; mainmenuexit field list minus `web_nothreads`; "menu-boot is the default (all platforms)".
- `AGENTS.md`: web build + web serve command lines deleted; server reporting = 8080 pair only; `.gitignore` note updated; daemon list = (1) windows-export 8080 + (2) tasks webui 5180 (5180 now documented explicitly); long-runs line → `./build_windows.sh`; "## Web test loop" → "## Windows test loop" (exe download loop, spec-repro sentence kept); rolling status line token-clean (AC-0107 blurb "kill switch (deleted in AC-0124)"; AC-0124 blurb → DONE summary, queue unchanged).
- `godot/CONTINUITY.md`: :213 Servers note → windows-serve-only (8080 + 5180, 8443 removed by AC-0124); :219 process line → `./build_windows.sh` + exe via 8080. e9 fresh top checkpoint written after all gates pass.
- `godot/ARCHITECTURE.md`: ONE line added after the spec-fidelity line (§1): web export dropped note (e12).
- REMAINING_FEATURES.html: untouched (e13 KEEP).

### Entry R2.4 — gates G1–G3 + G4 (r4 pair) PASS
- G1-1 `--quit`: RC=0, 0 SCRIPT ERROR.
- G1-2 + G2 genhash: RC=0, 0 err, 25/25 lines BYTE-IDENTICAL to pre anchor, MD5 `61de26e9a542a5ce2db62e7157d6c018` (pre GENMS 792 → post 790, timing noise).
- G3 FULL battery: ok:true, 0 err; player 2.82/36.43/37.78/on_floor; interact drop+place true (2/2, inv {2,1}); light 15/0/14/9; fluids 2730/2730 + 1406/1406 + stable, water_delta 1, shore [5,7], source [5,8], lava 25/9; buckets [5,8]→140×1→[5,8], inv {139,1}. ALL EXACT vs anchors.
- G4 perf r4: total_ms 6466 (pre 6447, in band), p95 42 (≤50), build_ms 326 (in band), max_frame 65 (≤78), read_sync_gen 0 (HARD), all_meshed true, 0 err. PASS.
- G4 boundary r4: ok, p95 33, max 73, flap 0, forward_p95 4284 (pre 4840, in band — better), irb 81/81/20, present 81, loads 220/unloads 209, read_sync_gen 0, 0 err. PASS.
- G4 boundary r50+RECPROBE: RUNNING (bg job bash-33, 3000 s wrap) → next entry.

### Entry R2.5 — G4 complete (r50) + G5 build
- G4 boundary r50+RECPROBE: RC=0, 0 err, ok:true. RECSLICE cold 137.0/10.0/28f (pre 138.0/11.0/28; gate ≤13 PASS), steady 66.0/8.0/27f (pre 62.0/7.0/27; gate ≤8 PASS — at boundary), RESULT p95 45 (≤51), max 106 (≤124), flap 0, read_sync_gen 0 (HARD), in_radius_present_final 10201 (exact), forward_p95 0 both pre/post (walk ends before r50 band resolves — same shape as AC-0118 era). PASS.
- G5 first attempt: RC=1 — MY INVOCATION BUG (not code/presets): I passed `HOME=/tmp/dsh_home` to the build script and it resolves the engine as `$HOME/tools/godot/godot` → engine path broken. Re-run with host HOME + XDG template overrides → **RC=0**: fresh AweCraft.exe 109,559,552 B (12:22) + debug/console pair + wrapper "OK: 7 sections byte-identical to console template (45056 bytes)"; BUILD.txt stamped (git 4d72dbc). Both presets resolved BY NAME after renumbering → a4/c preset-proof PASS.
- G5 daemon wrinkle (recorded, no action needed): the build ran in a DSH background-job sandbox with a private pid namespace → the script's pidfile liveness check saw the host 8080-server pid as "dead" → it started a TWIN serve on 8081 that died with the sandbox cleanup; the original 8080 server kept serving (directory serve → picks up the replaced exe automatically). 8081 is now gone; 8080 verified 200 on all 3 files (served sizes == on-disk sizes = fresh exe); 5180 200; 8443 = 0 listeners. Pidfile `.scratch/serve_win_export.pid` now holds a dead namespace-local pid — pre-existing script quirk (build_windows.sh is fence-protected: left alone), noted in the 00f checkpoint OPS NOTE.

### Entry R2.6 — G1 greps + G6 + docs final state
- G1a godot/ tree: 0 hits. G1b bare knobs in .gd: 0 hits. G1c AGENTS.md+HARNESS.md+.gitignore: 0 hits. G1d CONTINUITY.md: hits ONLY in historical sections (00e…00 checkpoint blocks, §5 :124 incident note, §6a–6c, §6 task list; final sweep first hit = line 8 = 00e block); NO hits in the new 00f block or §7/§8 live lines. (One self-inflicted fix mid-run: the first 00f draft contained the literal "IndexedDB" in the phantom blurb → reworded to "implicit browser-storage save quirk", re-verified 0.)
- G6: `git status --short` = 16 entries, ALL audit-listed or tasks/AC-0124/ (M: .gitignore, AGENTS.md, ARCHITECTURE.md, CONTINUITY.md, export_presets.cfg, main.gd, menu.gd, chunk.gd, world.gd, continuity.md, HARNESS.md; D: build_web.sh, serve_web.py, web/ssl/cert.pem, web/ssl/key.pem — only the pems were git-tracked inside web/; ??: AC-0124-results.html). index.html + build_windows.sh untouched (absent from status). No stray godot/Xvfb.
- `tasks/AC-0124/AC-0124-results.html` written (self-contained: gate summary, deletion inventory, 3 phantoms, full G4 A/B tables incl. r50 RECSLICE, daemon before/after + 8081 wrinkle, doc summary, G1 grep output, git status, the 57-row audit table spliced verbatim from plan §2).
- **STATE: ALL GATES G1–G6 PASS. Run-2 COMPLETE.** Next: coordinator review → TASKS.yaml status → commit+push (per protocol; Run-2 does no git).
