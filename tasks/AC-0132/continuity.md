# AC-0132 continuity log (append-only handoff record)

## RUN 1 (research → plan.html) — 2026-08-28
- Static file research only; zero godot runs (AC-0035 gate marker present; godot free; not needed).
- Deliverable: `tasks/AC-0132/plan.html` (7 sections, all constants + line refs verbatim).
- Key findings:
  - Grid semantics pinned: `match_shapeless` (data.gd:357, skip at :367 `r.grid > grid_size`) ⇒ `"grid": 2` recipes match in BOTH the 2×2 E grid AND the 3×3 table (call site player.gd:1415-1421, gs = 3 table / 2 E; `_current_craft_cells` :1406-1412 = table_grid[9] / first 4 of craft_grid). `"grid": 3` = table-only. Already gate-proven by AC-0052 arms (main.gd:2425-2479).
  - Torch entry form: shapeless `{"in": {106: 1, 100: 1}, "grid": 2, "out": {"id": 22, "n": 4}}` appended after data.gd:118 (placement-independent ⇒ vertical C-over-S works; no shaped variant needed; no shadowing — no existing entry references 106 in inputs).
  - Probe: `AWECRAFT_LOGIC=craft` ALREADY EXISTS (dispatch main.gd:886-890, `_craft_test` :2285-2553) — reuse; append arms T-neg/T1 (E vertical)/T2 (E horizontal)/T3 (table vertical)/T4 (regression 9+100→143×4). PRE run ok:false, POST ok:true.
  - Prompt mislabels corrected: block 9 = Cobblestone (data.gd:159, web :201) NOT planks; item 143 = Arrow (data.gd:89, web :245) NOT crafting table (that's block 20, data.gd:163). Regression recipe = data.gd:118 (shapeless, grid:2) == web index.html:273.
  - Charcoal item ABSENT (items 100-147 data.gd:46-94; blocks 1-25 :150-174) ⇒ spec "if present" = skip.
  - Web parity: Godot tables are FULL 22/22 shapeless + 14/14 shaped port of frozen web (index.html:251-290); web has NO torch recipe (no out.id 22) ⇒ user-directed addition (deviation class ii, MC-wiki canonical). Coordinator's stale "3 of 22" note corrected.
  - UI (inventory.gd) needs NO change: recipe list reads Data.shapeless directly (:651-662) with the same grid filter (:677-691).
  - SMOKE mapping: battery `player;interact;light;genhash` (data.gd touched ⇒ genhash 25/25 required; no world/*|lighting.gd ⇒ no boundary/perf/flake).
- Current state: plan complete; nothing else written; no tree changes.
- Next step: coordinator launches Run-2 (builder, `subagent` tool, medium) — builder reads plan.html §7 open items IN ORDER (PRE probe arms first, then data.gd entry, then SMOKE), keeps appending to this log.

## RUN 2 (implementation) — 2026-08-28 (medium builder)
- PRE: probe arms Tneg/T1/T2/T3/T4 appended to `_craft_test()` (main.gd, after arm F's `p.close_inventory()`, before `Debug.result(...)`) exactly per plan §5.4 — recipe entry NOT added.
  - G0 PRE: RC 0, 0 SCRIPT ERROR (`.scratch/AC-0132/g0_pre.log`).
  - PRE probe (`AWECRAFT_LOGIC=craft`, RC 0, 0 SCRIPT ERROR, ~2 s wall): **ok:false**; Tneg_out [0,0]; T1_out/T2_out/T3_out [0,0]; T1_torch/T2_torch/T3_torch 0; T2_filled 3, T3_filled 2 (unconsumed inputs); T4_out [143,4], T4_arrow 4, T4_grid drained (regression green pre-fix); every pre-existing r key = old-arms baseline. Verbatim RESULT in `.scratch/AC-0132/probe_pre.log` (+ `probe_pre_result.txt`) and quoted in results.html §2.1.
- POST: added the ONE line to data.gd after the arrow entry (old :118): `{"in": {106: 1, 100: 1}, "grid": 2, "out": {"id": 22, "n": 4}},` (tab/brace style matched).
  - G0 POST: RC 0, 0 SCRIPT ERROR (`.scratch/AC-0132/g0_post.log`).
  - POST probe (RC 0, 0 SCRIPT ERROR, ~2 s wall): **ok:true**; Tneg_out [0,0]; T1_out [22,4], T1_torch 4, T1_grid all [0,0]; T2_out [22,4], T2_torch 8, T2_filled 0; T3_out [22,4], T3_torch 12, T3_filled 0 (grid:2 reaches the 3×3 table — proven); T4_out [143,4], T4_arrow 4, T4_grid drained; every pre-existing r key byte-identical to PRE. Verbatim RESULT in `.scratch/AC-0132/probe_post.log` (+ `probe_post_result.txt`) and quoted in results.html §2.2.
- SMOKE (`AWECRAFT_BATTERY=player;interact;light;genhash`, RC 0, 0 SCRIPT ERROR, 66 s wall): combined **ok:true** (total_ms 65346). player horizontal_moved 2.82 / is_on_floor true / jump_peak_y 36.43; interact drop_spawned true / place_ok true / breakable_id 2 / after_place_cell 2; light surface_eff 15 / cave_eff 0 / torch_level 14 / torch_far_after 9 — all EXACT vs HARNESS §3. genhash **25/25** GENHASH lines BYTE-IDENTICAL to `.scratch/AC-0035/genhash.log` (`.scratch/AC-0132/genhash_ac0132.txt`).
- RENDER (the one allowed): R=1 `AWECRAFT_INV=1` shot, 7 s, RC 0, 0 SCRIPT ERROR, RESULT m4:ok 1280×720 → `tasks/AC-0132/inv_torch_ui.png`. The existing hook (main.gd:1386) also auto-wrote `inv_torch_ui_placed.png` (autofill variant — same single call, NOT a hook extension; fence holds). UI renders correctly; the new torch row lands LAST in the Craftable list (below the list's visible viewport in the shot) — behavioral proof is the probe RESULT.
- Deliverables: `tasks/AC-0132/AC-0132-results.html` (verbatim PRE/POST RESULTs, T-* PASS matrix, mislabel correction [9=Cobblestone / 143=Arrow], charcoal-skip [item absent], exact-count + consumption-quirk notes, web-parity finding [Godot = full 22/22 + 14/14 port; web has no torch recipe ⇒ user-directed addition class ii], gates, embedded PNGs).
- Current state: ALL BUILDER GATES PASS (G0 ×2, probe A/B, SMOKE+genhash, 1 render). Files changed: `godot/autoload/data.gd` (1 line) + `godot/scenes/main.gd` (probe arms only) + task deliverables. Fences held (no UI/world/other godot files, no git, index.html frozen, foreign docs/halo-loot-brainstorm.html untouched).
- Next step: BUILDER EXITS — heavy tier (genhash independent re-run + `./build_windows.sh` + 8080/5180 curls → `.scratch/AC-0132-gates/`) is the coordinator's background job; commit+push only after it passes.

## RUN 2.5 (coordinator heavy gates + FINAL, 2026-08-28 08:40)
- Gate job bash-96 (08:39-08:40): g0 rc=0; craft probe REPRODUCED ok=true (Tneg [0,0], T1 [22,4]/4, T2 [22,4]/8, T3 [22,4]/12 = grid:2→3×3 proof, T4 [143,4]/4); genhash 25/25; smoke3 EXACT; build RC=0 exe 109,622,568 B; daemons 200.
- DECISION: PASS — status → done; spec FILL sections completed by coordinator (Goal/requirements/gates/scope/fences incl. the corrected R3 parity finding + item-id corrections); commit (explicit paths) + push; NEXT = AC-0109 frustum-culling-chunks (spec written by coordinator; Run-1 launching).
