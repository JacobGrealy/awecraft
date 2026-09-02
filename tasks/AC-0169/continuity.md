# AC-0169 — debug stats overlay: CPU/RAM/VRAM/FPS

## RUN — 2026-09-02 07:36 EDT — AC-0169 (xhigh subagent, single blocking)

Milestones:
- READ: CONTINUITY §00v, ARCHITECTURE, HARNESS §1/§3/§4, spec.html, TASKS.yaml notes.
- API audit (task map was optimistic — verified against 4.7 docs/source tags, not the map):
  - `OS.get_cpu_usage()` DOES NOT EXIST in 4.7 → CPU(process) = `Performance.get_monitor(Performance.TIME_PROCESS)` (s/frame) deltas over the 0.25 s tick, reported as % of 1 core (labeled in the overlay text).
  - `OS.get_process_memory_usage()` / `OS.get_total_memory()` / `OS.get_free_memory()` DO NOT EXIST in 4.7 → system RAM from `OS.get_memory_info()` (`physical`/`free` bytes); process RAM = closest honest value `OS.get_static_memory_usage()` (engine static mem; debug builds only, 0 in release) — labeled as such.
  - VRAM = `Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)` (renderer video-mem bytes) — a real public stat, so no "n/a" needed.
  - FPS = `Performance.get_monitor(Performance.TIME_FPS)` (4.7 renamed `MONITOR_FPS`).
  - Godot 4.7: no `reorder_child` on Container (only Node.move_child(child,to_index) + get_index() argless) — used a child-scan + move_child.
- IMPL:
  - `godot/autoload/settings.gd` — DEFAULTS + `_clamp` gain `debug_stats` (bool).
  - `godot/ui/menu.gd` — programmatic CheckBox "Show debug stats (CPU/RAM/VRAM/FPS)" after HungerCheck (no .tscn edit), wired to `Settings.set_value("debug_stats",…)`; `_sync_controls` + OPTSYNC print synced.
  - `godot/scenes/main.gd` — `stats_overlay` CanvasLayer(25)+Label top-left, created in `_create_game_nodes` (frees any prior — battery double-create is pre-existing), freed in `_free_game_nodes`; 0.25 s tick in `_process` → `_refresh_stats` (visibility from Settings.values + text from APIs); `AWECRAFT_LOGIC=debugstats` arm (save phase `AWECRAFT_DSSTATS_SAVE=1`, probe phase) + render hooks `AWECRAFT_DSSTATS=1` / `AWECRAFT_OPTS_SNAP=path`.
- GATES:
  - G0: exit 0, 0 SCRIPT ERROR (after one parse fix: `get_index(child)` → child-scan + `move_child`).
  - debugstats run A (save): ok:true cfg_saved:true. run B (fresh process, same HOME): ok:true persisted_after_restart:true visible_when_on:true visible_when_off:true text_has_fields:true. stats sample: `FPS: 1  CPU proc: 0.0% (of 1 core) | RAM: proc 51.7 MB (engine static)  sys 26980/63063 MB (43%) | VRAM: 0 MB (render)` (headless: no GPU → VRAM 0; idle → CPU 0.0%).
  - SMOKE `player;interact;light;fluids;genhash`: battery ok:true; player start [8.5,137,8.5] / jump 135.43 / fly 136.78; interact drop_spawned+place_ok true (breakable 2); light 15/10/14/1→9; fluids sea_stable true, 2756/2756 + 914/914, 25/9; 0 SCRIPT ERROR.
  - genhash: 25/25, byte-IDENTICAL vs `.scratch/AC-0187-fix-gates/genhash_A.txt` (world/* untouched).
  - RENDER: single xvfb run (R=1, AWECRAFT_DSSTATS=1 + AWECRAFT_OPTS_SNAP), exit 0, m4:ok, 0 SCRIPT ERROR. `ac0169_overlay.png` = first-person, overlay on: FPS 24 / CPU 0.0% (of 1 core) / RAM proc 52.2 MB (engine static) + sys 27093/63063 MB (43%) / VRAM 51 MB (render). `ac0169_options.png` = Options panel, new "Show debug stats (CPU/RAM/VRAM/FPS)" CheckBox CHECKED after Hunger.
- DONE: plan.html + continuity.md + AC-0169-results.html on disk; all gates green. No world/*, no .tscn, no git.
