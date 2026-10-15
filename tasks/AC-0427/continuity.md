## RUN - 2026-10-14 08:11 EDT - AC-0427

## 2026-10-14 20:55 EDT - AC-0427 closeout state (SUBAGENT, all work in-repo)

**DONE — both defects fixed, gates green, docs written. Coordinator: verify + heavy set + closeout.**

1. **Holes (fixed + verified).** Root cause: AC-0423 seam-V extended TOP FACES ONLY
   (`fcv == FCV[2]` guard). At a solid height step across a seam the higher side's sliver
   overhangs ~0.6 m with an OPEN UNDER-VOID → one floating wedge per stepped cell = the
   user's periodic, evenly-spaced holes. Fix: `qwrite`/`qwrite_vc` now
   `bool seamv = (se != nullptr)` — the edge column's outward side faces extend with the
   sliver; the extended cliff face's bottom edge lands on the lower ground → closed.
   Census (solidity-aware; flowers/leaves excluded): 3×3 block 50 step cells, 0/50 covered
   before → 50/50 after; 5×5 region 147/147 covered (re-run identical); 0 cells >50 mm
   opening on all 12 measured seams. Renders: 01-before (white see-through face + wedges)
   vs 04-final-along-vz (closed, continuous) in `tasks/AC-0427/captures/`.
2. **Shading (fixed + measured).** Root cause: twin corners on the same seam point read
   different inputs (edge side = own inward real data; halo side = flat continuation of its
   own edge column off-grid) → different (sl, oshade) → the AC-0420 line. Fix: `seamc`
   ctx flag — in `s_modern_corner` the INWARD reads of a boundary corner (west gx==1 /
   south gz==1) return `self` (the corner's own edge-column top); both twins then use only
   SHARED data → identical (sl, oshade). Switch: Settings `seam_light` DEFAULT ON (user
   asked; modern_light precedent), OFF = key-absent C++ path = pre-fix byte-identical;
   colour-only, no geom_epoch; apply = `world.note_seam_light()` (tm_ctx + tex_refresh
   drain); env `AWECRAFT_SEAM_LIGHT`; NO menu.gd checkbox (documented gap).
   Corner-paired measurement (twin = highest-y top-face vertex per side; the first
   band-average measurement was contaminated by the sliver outer corners, constant −658 mm
   gap proved the mixed pairing — corrected method used for BOTH ON/OFF columns):
   level (same-height) twins: OFF 2 residual cells (x16_z16 0.922, z16_x16 0.102) →
   ON 190/191 at exactly 0.000 (z16_x16 fixed 0.102→0.000; the lone x16_z16 i15 cell =
   one-block neighbour-ring data staleness at world (15..16, z≈31), far from spawn, NOT
   fixable by the read clamp → follow-up candidate, §6 of results.html). Step twins
   0.2–0.92 = legitimate terrain-step shading (different world points); ON shifts some
   step-cell values vs OFF (consistency-over-local-accuracy trade, documented).
3. **Cleanup done:** all MDBG blocks + cstdio/cstdlib removed from mesh.cpp; the whole
   ac0427probe arm removed from harness.gd (pristine, 35,699 lines, 0 refs); .so clean-
   rebuilt (`-O2 -ffp-contract=off` manual g++ recipe, SCons absent on this box).
4. **Gates (this subagent's mandated set, all green):** G0 rc=0 0/0; SMOKE battery
   player;interact;light;fluids;genhash rc=0 ok:true (run 1 = known stochastic UAF
   signal-11 clean-log at world.gd:5663 → re-run once per protocol); meshprobe ok
   match_rate 1.0 verts 277,720/277,720 32/32 chunks; genhash 25/25 byte-identical to
   the CURRENT reference set (== AC-0425-final/AC-0423/AC-0422 sets — the AC-0367
   reference file is stale, superseded by later rebases). Logs: .scratch/AC-0427-g0.log,
   .scratch/AC-0427-smoke2.log, .scratch/AC-0427-meshprobe.log + .scratch/AC-0427/*.
5. **OWED (coordinator):** the heavy standing set (farab, ladder, seamcensus r4, r16,
   boundary r4, shaderforce 12/12 — awecraft-heavy-gates); Windows build; commit + push
   (no commits/pushes from this subagent by scope); TASKS.yaml status via tasks.py.

## Resume point
Nothing to resume on the code side. If a re-check is wanted: G0 + meshprobe are the
fast re-verifications; the seam census + corner-paired luminance need the ac0427probe
arm re-added (it was removed per the pristine rule — the recipes + parsing are in
.scratch/AC-0427/ logs: census-solid.log, seams-final-on/off.log).
