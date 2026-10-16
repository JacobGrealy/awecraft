## RUN - 2026-10-16 12:08 UTC - AC-0437

### 2026-10-16 09:00 UTC — implementation complete, pre-gate
- Read-first done: ticket notes (TASKS.yaml), AC-0384 §29 assessment (3444–3598), continuity top checkpoint, ARCHITECTURE.md, AC-0435 sweep (default re-ruling + pattern), HARNESS.md §2/§4/§5, OPS.md, fence state (main.gd / game.gd / drop.gd / debug.gd dirty = other session's AC-0038 particles + AC-0396 snap + controls dispatch), settings arm, held arm, build_windows.sh.
- THE FINDING established before any edit: `grep -rn is_debug_build godot` = zero hits; RangeButton declared unconditionally in menu.tscn; the only shipping-path dev/shipped mechanism is build_windows.sh's sed rewrite of `build_id.gd` (version string only) + git-checkout exit trap. So: the gate didn't exist. The `[dev]` tag = `"AweCraft[" + Build.ID + "]"` (menu.gd:761) — dev-provenance only, cannot leak into stamped builds.
- Code: inventory.gd (CrossCtl + `_health_cap`/`_hunger_cap` + `_dim_bg` first-child + env preloads + live reads), settings.gd (2 DEFAULTS + 2 `_clamp` arms, sanitize_bool), menu.gd (`_ready` gate `Build.ID != "dev"` + 2 CheckBox rows + sync + handlers), ARCHITECTURE.md §2/§3, HARNESS.md §2 (2 env rows after NOSKYFLOOR).
- plan.html written (goal, finding, per-item approach, files, gates, frame recipes).
- No fence file needed for the crosshair (it lives in ui/inventory.gd).

### 2026-10-16 09:05 UTC — light gates green
- G0: exit 0, census 0/0 (checked exit status per the UAF trap).
- SMOKE (player;interact;light;fluids;genhash): exit 0, 0/0, ok:true.
- genhash standalone: 25/25 byte-identical to `.scratch/AC-0311-gates/p2_genhash_r1.log` (the documented current-tree reference; chunk (0,0) = 46c20b07…).
- settings arm: exit 0, 0/0, ok:true (rows_21 Controls count unchanged).
- held-item probe: exit 0, 0/0, Forward+ llvmpipe boot line. RESULT reds (box_ok / cross_ok / depth_ok) → proven PRE-EXISTING: identical with my files stashed (A/B), identical on a clean-HEAD archive (git archive f3140d0 + libchunkio.so + untracked .uid files + `--import` pass — the archive needs the uids + import or it fails with 249 parse errors on class_name resolution). box_ok red already filed by AC-0435 (last green 08-24); tool/cross fields have no recorded standing value (stale AC-0066-era §1 row); sibling toolpose arm: ok:true, depth_ok true — the viewmodel depth contract itself is green. Recorded, not absorbed.
- shaderforce: N/A — no .gdshader changed.

### 2026-10-16 09:35 UTC — frames captured, crosshair bug found + fixed
- First play frames: crosshair absent (0 white px at centre). Diagnosis: visibility keyed on MOUSE_MODE_HIDDEN but play runs MOUSE_MODE_CAPTURED (Player.start captures). Fix: `Input.mouse_mode != MOUSE_MODE_VISIBLE` (covers CAPTURED + HIDDEN, hides when the cursor is back). G0 re-run after the fix: exit 0, 0/0.
- Final frames (all 1280×720 llvmpipe Forward+, exit 0, 0/0, SNAP lines verified + files exist): play-day (TIME 0.5) / play-night (TIME 0.0) — crosshair 44 near-white px both, centre hole dark; statcap-before (STATCAP=0) — 163 vs 332 white px in the row band, red 1560 both (icons untouched); inv-open vs inv-open-nodim — world-band mean L 51.5 vs 93.6 (exactly ×0.55 = the 0.45-alpha contract); menu-dev (`"build":"dev"`, [dev] tag + Test Range visible) vs menu-stamped (build script's exact sed applied temporarily, `"build":"20261016-0852 f3140d0"`, stamp tag, no Test Range; build_id.gd reverted to "dev" immediately after — clean at HEAD); menu-options (1280×1500 — the Settings list overflows 720 px) shows both new rows checked.
- crosshair-before.png = copy of the assessment's own AC-0384 r24 day frame (the true pre-AC-0437 look).

### 2026-10-16 09:45 UTC — DONE
- AC-0437-results.html written (self-contained w/ captures/; finding box, 4 item sections with before/after + measurements, gate table with exit statuses + the held-arm pre-existing proof chain, files table, deliberate non-changes, continuity note).
- Fence respected: no fence file edited; tasks/AC-0067 PNGs untouched by this run (those writers are the AWECRAFT_WALL_SHOTS-gated _wallshot_test arm, not _held_test); no TASKS.yaml mutation; no commits (closeout is the coordinator's).
- Resume point: none — awaiting closeout (docs sync already done in-task; rule harvest candidates: the clean-archive .uid + --import requirement for archive runs, and the held-arm stale standing values — both for the coordinator to place).
