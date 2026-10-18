## RUN - Sun Oct 18 15:29:28 EDT 2026 - AC-0448

- Fresh run (no prior entries). Read the ticket (tasks/TASKS.yaml AC-0448), CONTINUITY r26,
  ARCHITECTURE/ui scenes scopes, AC-0435 sweep, menu.gd + settings.gd + menu.tscn, harness
  settings/controls arms, HARNESS.md, OPS.md, awecraft-run-verify skill.
- DIRTY TREE INSPECTED (pre-existing uncommitted work, unknown provenance per coordinator):
  - godot/scenes/main.gd: AC-0038 pooled-particle system (ParticlePool node + AWECRAFT_PARTICLES=0
    A/B) in _create_game_nodes/_free_game_nodes + AC-0088 `controls` arm dispatch (harness
    _controls_test exists in scenes/harness.gd:3900 — consistent).
  - godot/autoload/game.gd: `particles` ref var (AC-0038).
  - godot/entities/drop.gd: pickup puff into Game.particles (AC-0038).
  - godot/autoload/debug.gd: snap() now fails loudly (SNAP FAIL line + push_error) — AC-0396 work.
  - godot/entities/particle_pool.gd is untracked (AC-0038's pool; class_name ParticlePool present).
  All four dirty files left as-is; my changes go alongside, reported for the coordinator.
- Plan written: tasks/AC-0448/plan.html. Census: Settings page ~41 children (~1.3-1.4k px),
  Developer ~11 rows, Controls ~31 children; the full-rect CenterContainer centers an
  oversized TabContainer -> top/bottom rows off-window, no clip, no scroll. Mechanism:
  ScrollContainer per tab page (CenterContainer inside keeps centering) + OptionsBox/Center
  -> MarginContainer (bounded frame); 12 internal switches -> Developer page.
- Next: baseline gates on the dirty tree (G0, SMOKE+genhash, settings arm, held arm), then the
  pre-fix render measurement.

## RUN - implementation + renders + gates (final)
- tscn: OptionsBox/Center CenterContainer -> MarginContainer (margins set at runtime by
  _sync_options_frame; note: .tscn comments are ';' not '#' — first attempt broke the scene
  load, fixed).
- menu.gd: _mk_scroll_page (ScrollContainer v-auto/h-off -> Center "Center" v-EXPAND_FILL)
  wraps all 3 pages (page keeps tab name; list renamed SettingsList/DevList/ControlsList);
  AC-0448 move block: 12 rows + "Feature flags (internal switches)" label -> DevList
  (remove_child BEFORE add_child — Godot does not reparent on add_child; caught in the
  settings arm, ERROR line, fixed); _sync_options_frame (40px top/bottom, sides centre a
  0.62*vp panel capped 820/floored 560; inner Center custom_minimum_size.x = inner width —
  ScrollContainer gives the child MIN size on the non-scroll axis, measured) at boot +
  root.size_changed.
- main.gd: AWECRAFT_MENU_SCROLL=bottom|<px> (vbar.max_value pattern — no scroll_vertical_max
  in 4.7) + pages census in the menu-shot RESULT (rows/content/page/scroll_max per page);
  unset env = old behaviour.
- harness.gd _settings_test: row lookups follow seats (.../Settings/Center/SettingsList,
  .../Developer/Center/DevList, .../Controls/Center/ControlsList; noclip lookup via ydev),
  AC-0448 placement block (12 moved / 17 kept assertions), menu.rows in RESULT, ok chain
  extended. DISCLOSED instrument edit (scenes AGENTS.md).
- Gates: G0 rc=0 0/0 (baseline + final); SMOKE ok:true rc=0 0/0, genhash 25/25 byte-identical
  pre/post (== AC-0446/AC-0447 verified set, tip chunk 46c20b07…); settings arm ok:true,
  menu={moved:true,kept:true,rows:{29,24,21}}; held probe RESULT byte-identical pre/post
  (box_ok:false = documented pre-existing staleness per AC-0394 page).
- Renders (xvfb + lvp + vulkan Forward+, AWECRAFT_SIZE comma form, no AWECRAFT_LOGIC, PNG
  existence checked; all rc=0 0/0): BEFORE 1280,720 (HEAD worktree w/ .godot copy — a fresh
  worktree has no .godot -> 258 class_name parse errors; copied cache fixed it): tab bar
  clipped top, list "Hunger".."Sky: space below the horizon", bottom rows + Back off-screen.
  AFTER settings-top (tab bar visible, panel centred, scrollbar 610/1009),
  settings-BOTTOM (acceptance: scroll to vbar.max — last row "Night: lift the floor" + Back
  reached), developer (flags under the new header), settings-bottom @1920,1080 (970 vs 1009).
- Worktree removed; probe .gd deleted; git status = intended 4 files + pre-existing 4 dirty.
- Deliverables: AC-0448-results.html (5 frames in captures/), this journal, plan.html.
- NOT done: heavy gates/Windows build/TASKS.yaml/commit (coordinator+closeout); no default
  flips; no row reordering; no Controls rework.
