# AC-0176 — custom user dir

## RUN — 2026-07-09 — AC-0176
Medium builder started. Plan: tasks/AC-0176/plan.html. Change: two settings in godot/project.godot
(application/config/use_custom_user_dir=true, custom_user_dir_name="AweCraft"). Verify: path move
(measured headless), save/load from clean user dir, grep for orphaned paths, ARCHITECTURE.md §5 update.
LANDED: project.godot +2 settings under [application] (use_custom_user_dir=true, custom_user_dir_name="AweCraft", with comment), after config/name (:5→:5, now :5-:10). No other code change — save.gd (BASE user://awecraft_save, :4), settings.gd, chunk_io.gd, satellite cache all ride relative user:// and follow the setting; grep found zero hardcoded app_userdata/user_data_dir paths in godot/ or gdext/ (only sandbox-HOME refs in tasks/scripts/gate_run.py + spec_template.py). ARCHITECTURE.md §5 saves bullet updated (AC-0176 paragraph). MEASURED (probe, headless -s): BEFORE /tmp/dsh_home/.local/share/godot/app_userdata/AweCraft (udir-before-r1.log); AFTER /tmp/dsh_home/.local/share/AweCraft (udir-after-r1.log; settings read true/"AweCraft"). Gates running in background job (gates.sh: clean user dir -> g0,save,load [timeout load=4200, mem 12288] -> genhash,planetwalk); gate summaries will need merging before results_page render (second gate_run overwrites summary.json).
GATES: all 5 arms green, one background job (gates.sh; clean user dir first — CLEAN_LIST empty, /tmp fresh tmpfs per call; after gates the job's user dir held only /.local/share/AweCraft{,/logs}):
- g0 rc=0 script=0 3s; save rc=0 script=0 44s ok=true (blocks_match 6/6, inv_match, iso, r_saved/r_loaded 4000, clamps 2000/8000)
- load rc=0 script=0 779s ok=true, simband_ms 6755 (usual seconds class), disk=0 / gen=5509 (fresh install — no old file read), clean exit
- genhash 25 GENHASH lines, byte-identical to the current standing references (.scratch/AC-0474/AC-0473/AC-0451 genhash logs) -> 25/25
- planetwalk rc=0 36s ok=true — 25/26 pairs covered with mesh + body, the documented lap_0-1 home_pair_midline waiver
Deliverables: tasks/AC-0176/AC-0176-results.html (rendered via results_page.py from the merged 5-arm summary), AC-0176-deviations.txt, probes under .scratch/AC-0176-gates/ (udir-before-r1.log / udir-after-r1.log). No PLAN-INSUFFICIENT; no deviations beyond the stated gate knobs (load timeout 4200 s, 12 GB cap) and the no-migration decision.
