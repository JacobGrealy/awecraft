## RUN - 2026-10-09 21:11:09 EDT - AC-0395

## 2026-10-09 21:4x EDT — implementation complete, gates pending
- All player-side + settings/UI edits done (settings.gd, menu.gd, player.gd — per the earlier
  session notes: DEFAULTS `"noclip": false`, `_clamp` sanitize_bool branch, Options CheckBox
  row `NoclipCheck` + `_on_noclip_toggled`, player `_noclip_sync()` in `_process`
  (shape disable + flight + void-kill gate + indicator label), `AWECRAFT_NOCLIP` env
  preload in `_ready` WITHOUT save).
- Harness arm added: `if logic == "noclip":` dispatch branch in harness.gd (rides the
  existing main.gd → harness.run forwarding — NO main.gd edit, fence-respecting) +
  `_noclip_test()` + the `_noclip_count_static_bodies` helper (the StaticBody3D census).
  Measurement: fixture pad+wall ~8 m above spawn (scanned clear band, set_block,
  restored before exit); state 0 (default off) — boot state is today's behaviour,
  walk STOPS short of the wall face, chest cell never solid; state 1 (UI path) —
  same drive ends with the chest cell SOLID inside the wall column (cell-occupancy
  pass-through, not "the player moved"); the game's own grid DDA (VoxelMath.
  raycast_blocks, the exact interaction call) hits the same wall cell in both
  states; StaticBody3D census count-identical across the toggle + collision_enabled
  true; state 0 again — same-path repeat stop |Δx| < 0.15 m.
- `_settings_test` extended with the noclip block (default_off, save/reload
  round-trip, corrupt→false, Options-row presence + sync).
- `tasks/harness_data.yaml` noclip row added + `harness_doc.py --render` done
  (in sync: modes, standing-values).
- `godot/ARCHITECTURE.md` synced: §2 Settings row (the noclip bool), §3 Player
  bullet (the NOCLIP block), §6 decision bullet (AC-0395 — free-flight rationale,
  void-kill gate, Options-surface-over-key rationale, byte-identical-by-construction
  claim + its proof).
- Gates pending: G0 (census + exit status), SMOKE (player;interact;light;fluids;
  genhash), PROBE (AWECRAFT_LOGIC=noclip, then the AWECRAFT_NOCLIP=1 env run),
  genhash 25/25 vs .scratch/AC-0367-gates/genhash_pristine_r1.log, movement +
  collision arms at the default (off), before/after cave renders.

## 2026-10-10 03:1x EDT — FINAL: all light gates green, deliverables in place, exit to coordinator

Gates (all in `.scratch/AC-0395-gates/`, every census PAIRED with exit status; one godot at a time):
- G0: r2–r8 after every harness edit — 0/0 script/shader, EXIT=0 each.
- SMOKE: `BATTERY=player;interact;light;fluids;genhash` — 0/0, EXIT=0, 5 RESULT, standing values.
- PROBE (arm): `AWECRAFT_LOGIC=noclip` no-env — r7–r12 green after each arm restructure, final r12
  `ok:true` (state0 stop 12.996 / blocked / never_solid / label_off; state1 inside [13,149,8] stone
  / shape_disabled / flying / label_on / pass_through; state0b delta 0.001; bodies 262=262;
  col_face face_x 13.0 / stop_to_face 0.004; ray1_same; restore_ok).
- PROBE (env): `AWECRAFT_NOCLIP=1` — env r2 `ok:true`, `env_preload_ok` (shape disabled + flight at
  boot), same pass-through, EXIT=0, 0/0.
- settings: `ok:true`, noclip block all-true (default_off, saved, reload, corrupt_false,
  row_present, row_sync — the `NoclipCheck` CheckBox row is live on the Options surface).
- movement (default off): look / swing / spherewalk / boundary — 0/0, EXIT=0, standing values
  unchanged (player jump_peak_y 142.42 / col_deferred_in_footprint 0, etc.).
- collision consumers: ×2 + A/B (my 4 files stashed) — mine/place PASS; the `step` sub-check is
  PRE-EXISTING red, byte-identical with my files stashed (D2 — flagged for coordinator).
- genhash: 25/25 == chain tip `.scratch/AC-0311-gates/p2_genhash_r1.log` (the AC-0311 p2 rebase tip;
  the ticket-pointed AC-0367 file is the STALE pre-rebase tip — same finding as AC-0411), and the
  A/B stash run is IDENTICAL — my change contributes nothing to the hash.
- RENDER (fwdshot: xvfb + lavapipe + `--rendering-driver vulkan`, R4, 1280×720): r1–r6. Final r6:
  0/0, EXIT=0, boot line `Vulkan 1.4.318 - Forward+ - … - llvmpipe (LLVM 20.1.8, 256 bits)`, the
  FULL arm `ok:true` under the renderer, both arm-owned shots PIXEL-VERIFIED
  (`before_stone [61,62,62]` = the stone west face 1.5 m ahead, label off; `after_stone [98,99,106]`
  = the stone east face, camera 0.5 m past it in the scanned air gap looking back, label on).
  `tasks/AC-0395/noclip_after_off.png` + `noclip_after.png` are the deliverable renders.

The render saga (r1–r6) — all arm-side fixes, nothing in game code:
- r1: frame-budget starvation under the ~5 FPS proxy renderer — first teleport onto a not-landed
  pad collider (player sank into the pad floor row), state transitions measured before the
  player's `_process` sync (several physics frames fit in one process frame), chunk-level
  world-build wait timed out on the R4 radius. Fix: fixture-body wait gates the first teleport;
  transitions wait for the APPLIED shape/flight state; shot waits replaced the chunk-level wait
  (all no-ops in headless).
- r2: before shot read a partially presented buffer (black capture).
- r2–r5: after frames showed open terrain instead of the wall — first misdiagnosed as a CPU/GPU
  mesh-upload lag (CPU-side mesh landed, wall absent), disproven by r5's clean stone before shot.
  REAL mechanism (D5): a 1 m solid column is FACELESS FROM INSIDE — all six face normals point
  outward, the interior eye sees every face backface-culled, the frames looked through the
  invisible wall at the terrain beyond. The pixel-verified capture (throwaway snap retried until
  a stone-gray sample — low saturation + brightness cap 0.15..0.60, after an r4 false positive on
  fogged sand (207,207,181)) is what made this fail loudly instead of passing silently.
- r5 also exposed a REAL fixture bug: the band scan covered only the pad's x-range
  (`dx ∈ [-3,5)`) — the wall's own column (`x = ax+5`) was never scanned, so a band overlapping
  pre-existing terrain there would have been EATEN by the restore (the "restore must never eat
  terrain" fence — latent in this world, the band happened to be clear). Fix: the scan now covers
  pad + wall + the EAST GAP column (`dx ∈ [-3,7)`); the gap also keeps the wall's east face
  exposed to the mesher — the face the after shot photographs from its air side.
- r6: green. The full arm passes under the renderer — the arm's timing/composition assumptions
  are regime-proof.

Deliverables: `tasks/AC-0395/AC-0395-results.html` (self-contained: design decisions, pass-through
RESULT JSON, OFF-unchanged evidence incl. col_face + genhash A/B + consumers A/B, gates table with
exit statuses, the two renders, deviations D1–D5), the two PNGs, `plan.html`, this journal.
Files: `godot/autoload/settings.gd`, `godot/ui/menu.gd`, `godot/player/player.gd`,
`godot/scenes/harness.gd` (arm + helpers + settings-arm block), `tasks/harness_data.yaml`
(+ regenerated `godot/HARNESS.md`, `--check` green), `godot/ARCHITECTURE.md` (§2/§3/§6).

Deliberately not done (fence): NO commits, NO pushes, NO `TASKS.yaml` edits (status flips at
coordinator closeout); HEAVY gates (boundary/flake/r50/full battery) are the coordinator's; the
other session's uncommitted files (main.gd, game.gd, debug.gd, drop.gd + their doc lines) were
never touched — my A/B stash only ever stashed my four code files. The consumers step red (D2) is
left as-is for the coordinator to triage (A/B-proven pre-existing; the mine/place consumer paths
pass).
