# AC-0138 continuity — leaves-always-black-regression

## RUN — $(date) — AC-0138 — spec written, queue top, launching subagent_plan xhigh
- Task added AC-0138 priority 1, queue inserted at position 1, status in-progress.
- Spec written: goal fix leaves black day+night, requirements root-cause among shader/vColor/lighting/tint, gates G0+SMOKE+leaf probe+day/night renders.
- Next: launch subagent_plan (xhigh) single-phase per two-phase.md.
## RUN — Sat Aug 29 08:30:59 EDT 2026 — AC-0138

## MILESTONE — 2026-08-29T16:30:18Z — ROOT CAUSE CONFIRMED (candidate 4, NOT 3)
- PRE probe (seed 44, cell [-28,35,34] chunk [-2,2], exposed top-layer leaf): vcolor [1.0,0,0.8], L_day=1.0 L_night=0.2, u_day_cut=1.0, cut shader correct, light{sky:0,blk:0,eff:0} at the leaf cell itself (leaves occlude sky — port semantics, faces sample opposite cell so NOT the bug)
- BUT atlas leaf tile = (1,19,0) nearly black; expected single bake of raw (119,117,119) x TINT_LEAVES(60,140,48) = (28,64,22). Triple-bake sequence (28,64,22)->(6,35,4)->(1,19,0) EXACT match.
- Root cause: `_bake_atlas_tints()` (data.gd AC-0128) loops faces; block 7 (and 5) share ONE tile rect (320,0)/(224,0) across top+side+bottom => same tile tinted 3x. Grass (id 1) has distinct per-face rects => unaffected (matches user: trunks/grass fine).
- Fix applied: data.gd _bake_atlas_tints rect-dedup (baked{} set, ~4 lines). lighting.gd B2 plan NOT needed — not applied (eff byte-identical, battery safe).
- Probe debug notes: cell.x<0 sentinel bug in probe (fixed: use pick flag); String(Image.Format) parse error (fixed: str(int())); Image.is_srgb() absent in 4.7.1 (removed).

## MILESTONE — 2026-08-29 — DONE, ALL GATES GREEN
- POST probe ok:true: atlas_texel (28,64,22) exact single-bake, L_day 1.0 / L_night 0.2, green_day 0.201 / green_night 0.04, found_v true, cell [-28,35,34], vcolor [1.0,0,0.8].
- G0 --quit: 0 script errors.
- SMOKE: player after_fly 37.78 EXACT (3× known threadgen transient, AC-0137 class); interact all-true EXACT; light 14/9 EXACT; fluids 2730/1406 EXACT; genhash 25/25 byte-identical (diff .scratch/AC-0035 baseline = 0); nightday cave 15.0/3.0 + torch 14.19996 day==night EXACT.
- ONE-SHOT boundary r4: walk p95 123 (band 108–126) / fwd_p95 11725 (band ~10898–13019) — IN BAND.
- Renders R=1 AWECRAFT_AIM=22,38,7,1.09,-0.25 (tree (11,1) in-frame, named cams don't survive player respawn): render_day.png leaves clearly GREEN; render_night.png same tree at 0.20 floor, tinted not black. Note: AWECRAFT_SNAPSHOT needs ABSOLUTE path (relative resolves vs project dir godot/).
- MINFO N/A (mesh code untouched). tools_dump_atlas.gd moved to .scratch/AC-0138/.
- Deliverables: tasks/AC-0138/AC-0138-results.html (self-contained, embedded renders) + render_day.png + render_night.png.
