# AC-0117 continuity log (append-only)

## Run-1 (research) — 2026-08-25

### Milestone: bug reproduced (A/B)
- Seed 16, R=1, iso, NO_FOG, merge ON vs `AWECRAFT_MERGE=0`: diff = 1.97% of pixels
  (threshold >8), blob at frame (475,177)-(819,522). Crops show full-tile substitution:
  stone cliffs render as tan planks-X texture; tree trunks render as brown/white
  (snowgrass-bottom/top mix) where merge-OFF shows plain log/stone. Saved:
  `repro_seed16_on.png`, `repro_seed16_off.png`, `repro_seed16_crop_on/off.png`,
  `repro_diffband_on/off.png`, `repro_seed16_diffmask.png`, plus top-view
  `repro_seed16_top_on/off.png` + `repro_seed16_top_diffmask.png`.
- Seed 44 (AC-0106's gate seed) is a sky-only view at R=1 iso — that is why AC-0106's
  A/B gate passed: the only land visible was the spawn chunk (see root cause).

### Milestone: root cause found (chunk.gd:46-47)
- `_merge_atlas()` returns `{"tex", "rects", "h": float(img2.get_height())}` on the
  FRESH build path (chunk.gd:107) but the CACHE-HIT path (chunk.gd:46-47) returns
  `{"tex", "rects"}` — NO "h" key.
- `_emit_ro_merged` reads `var ms_h: float = float(ms.get("h", Data.ATLAS_PX))`
  (chunk.gd:439) → 1024.0 for every chunk except the first one built (the d=0 spawn
  chunk in `_build_queue_for_center`, world.gd:635).
- The merged y-UV at chunk.gd:412 divides by `ms_h` (1024) instead of the real
  extended-atlas height 1760 → the sampled image row is 1760/1024 = 1.71875× too far
  down → merged faces in every chunk after the first land in the tile strip ~2 rows
  lower (256px): stone(0,352)→planks(0,608), log-side(512,480)→snowgrass-top/bottom
  (the user's "trunks show dirt"), grass-top(0,96)→partly grass-bottom/dirt.
- Quantitative match: stone quad center intended y=368 → actual 632.4 = inside planks
  strip (0,608)-(512,736) ✓; log H=2 rows → snowgrass-bottom (brown/white) ✓; matches
  the observed crops exactly.

### Verification evidence (throwaway, under .scratch/AC-0117/)
- Python re-implementation of strip layout + UV math (sim_merge_atlas.py): 11067
  cells over all (id,face)×W{1,2,4,8,16}×H{1,2,4} → 0 wrong-tile samples when the UV
  is divided by 1760. So the strip contents and the slope-31 UV formula are correct;
  only the denominator is wrong at runtime for 8 of 9 chunks.
- Godot probe (ac0117_probe.gd, `godot --headless --path godot -s`): the
  Godot-built extended atlas is correct — SPOT checks of the dirt/stone/log/planks/
  snowgrass-side strips (center + last repeat) all match the original tile pixels;
  image size (1024,1760). `Image.blit_rect` semantics fine. Autoload Data IS present
  under -s.
- World facts (seed 16, probe map/BCELL): no ocean (`ocean_cells=0`; the light-blue
  around the island is SKY past the R=1 world edge, color (129,155,161)); whole world
  forest, heights 34 (basin with lava lake at world (2..14,2..14)) to 63; spawn (8,8)
  in the basin under a tree (BCELL topb=7 at_y=40).
- First-chunk = (0,0) (Manhattan-band order in `_build_queue_for_center` world.gd:635)
  → explains why the region around the lake/spawn shows only the small 31/32 phase
  drift in the diff, while the rest of the island shows the full tile swap.

### Design decisions
- Fix = add `"h"` to the cache-hit return (chunk.gd:47):
  `return {"tex": _ms_tex, "rects": _ms_rects, "h": float(_ms_tex.get_image().get_height())}`
  (1 line; ImageTexture.get_image() is cheap, called once per chunk build).
- Optional 1-token hardening (same file, chunk.gd:427): the tile-bearing fallback
  branch divides y by `Data.ATLAS_PX` — wrong for the 1024×1760 texture; currently
  UNREACHABLE (every ro id has all three face tiles, so `_merge_strip` never fails),
  so behavior-identical today; change denominator to `Vector2(Data.ATLAS_PX, ms_h)`.
- UV-only fix: geometry/quads unchanged → opaque vert count stays 125552 (AC-0106).
- Residual A/B difference after fix = the AC-0106 slope-31 phase drift (≤(W-1)/(H-1)px
  intra-tile shift on quads with W>1/H>1; 1×1 quads pixel-identical). Documented in
  plan §7; G2 criterion = no wrong-tile substitution (crops + diff-band analysis),
  NOT strict pixel-identity.
- G2 seed: 16 (terrain-rich). Seed 44 must NOT be used as the A/B gate seed.

### State
- plan.html written (this run). All repro PNGs in tasks/AC-0117/. Scratch probes in
  .scratch/AC-0117/ (sim_merge_atlas.py, ac0117_probe.gd, extended_atlas_*.png, logs).
- No .gd files edited. No git. No builds. Next: coordinator gate → Run-2 implements
  the 1-line fix (+optional hardening), runs G0/SMOKE/G2/G3/G4, writes results.html.

## RUN 2 (implementation) — 2026-08-25

### Milestone: fix + hardening applied
- `godot/world/chunk.gd` (ONLY file edited):
  - :47 cache-hit return now includes `"h": float(_ms_tex.get_image().get_height())` (mirrors fresh-build :107) — THE FIX.
  - :427 tile-bearing fallback denominator `Data.ATLAS_PX` → `Vector2(Data.ATLAS_PX, ms_h)` — optional hardening, INCLUDED (branch unreachable today; behavior byte-identical, confirmed by G1/G3/G4).
- No comments added; unmerged/cutout/fluid emitters untouched.

### Gate results (all PASS)
- **G0** RC=0, zero script errors (.scratch/AC-0117/g0.log).
- **G1** genhash 25/25 — all (cx,cz) 16-hex prefixes identical to .scratch/ac0106/genhash_baseline_44.log (baseline stores 16-hex prefixes; new run prints full 32-hex).
- **G2** seed 16, R=1, iso, NO_FOG=1 (matches Run-1 conditions): diff>4 = 0.694%, diff>8 = 0.629% (pre-fix 1.97% @>8). Diff mask = fine intra-tile speckle (31/32 slope phase drift on W>1/H>1 merged quads + lava-anim frame), NO solid foreign-tile blocks. Tree crops: trunks = brown log-side wood in ON, matches OFF; cliffs = stone/sand, matches OFF. PNGs: post_seed16_on/off.png, post_seed16_on/off_tree_crop.png, post_seed16_diffmask.png; 3× zooms in .scratch/AC-0117/ (left_tree_*, edge_row_*).
- **G3** battery RC=0 ok:true; sea 2730/2730 + 1406/1406 (sea_stable true), torch_level 14, horizontal_moved 2.82, place_ok true, drop_spawned true, water_on_lava 25, sideways_lava 9.
- **G4** DEVIATION: `AWECRAFT_LOGIC=meshdump` is not a real mode (unknown-logic fallback prints MINFO before meshes settle — all built:false). Used `AWECRAFT_LOGIC=perf AWECRAFT_MESH_INFO=1 AWECRAFT_RADIUS=4` (waits for all_meshed, same world.mesh_info() source, main.gd:4637): 81/81 chunks built, **surface-0 opaque vert sum = 125552 EXACTLY** (AC-0106 value).
- **G5** git status: `M godot/world/chunk.gd` + untracked tasks/AC-0117/ files only. All scratch logs in .scratch/AC-0117/.

### State
- DONE: all gates G0–G5 pass. Deliverables: tasks/AC-0117/AC-0117-results.html (self-contained: root cause, exact diff, gate table, A/B + crops embedded, residual explanation, hardening decision, deviations) + PNGs. No git, no builds (coordinator commits + builds). Next: coordinator review → commit+push → builds.
