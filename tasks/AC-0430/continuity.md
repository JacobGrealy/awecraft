# AC-0430 continuity — terrain faces wearing the lava texture

## RUN — 2026-10-14 21:58 EDT — AC-0430 (subagent)

**State at run start (established before touching anything):**
- Ticket: user report 2026-10-13 — large flat faces on grass/tree surfaces wearing the LAVA
  tile; whole side faces of stepped terrain rendered orange. Screenshot not on this box;
  the ticket note is the description.
- `git status`: the only uncommitted native change is `gdext/src/mesh.cpp` = the AC-0427
  work (seam-V side-face extension, `seamv = (se != nullptr)` in `qwrite`/`qwrite_vc` +
  the `seamc` seam-lighting flag in `s_modern_corner` + 3 call sites; 89 lines).
  No other gdext file is modified. mesh.cpp mtime 2026-10-14 20:48.
- **The served build contains the uncommitted change (fingerprint, not assumption):**
  `godot/bin/libchunkio.so` (and the Windows .dll) are stamped 21:11 — 23 min after the
  mesh.cpp edit — and `strings` finds the `seamc` key in the .so, which only the
  working-tree code contains. Last commit to touch mesh.cpp = 356da23 (AC-0423, 10-12).
  So the build the user runs = committed GDScript + uncommitted native.
- Atlas facts (godot/assets/blocks_atlas.json, 1024px): lava = id 24 at [0,32] (row 1,
  col 0 — the tile directly BELOW grass-top [0,0]); grass side = id 1 at [32,0]; dirt
  [64,0]; log (bark) id 6 side [288,0]; leaves id 7 [320,0]. A face sampling the lava
  tile carries uv in (0..31.5, 32.5..63.5) px — i.e. it was written with the rect of
  id 24, face "side" (or an equivalent uv error), not its own (id, face).
- Emit-path map (gdext/src/mesh.cpp): home-tier opaque ro scan takes `emit_ro_merged`
  (→ `qwrite_merged`, line 4025) whenever the merge atlas is nonempty (it is, for the
  game — chunk.gd `build_mesh` passes `_merge_atlas()`), else the per-face
  `emit_faces` (→ `qwrite`/`qwrite_vc`). AC-0427's side-face extension landed in
  `qwrite`/`qwrite_vc` ONLY; `qwrite_merged` still extends TOP faces only (line 1871).
  `seamc` (lighting, colour-only) applies on both paths. UVs on every path come from
  (block id, face index) via `s_uvc` (per-face) / `merge_strip`+`brect` (merged) —
  nothing in the AC-0427 diff touches a uv, so an A/B where the uv census is
  IDENTICAL but the frames differ would point at visibility (a newly-exposed face),
  and an A/B where a face carries the lava uv in both builds points above the
  extension entirely.
- Seam-closure detector: `seamcensus` arm (harness.gd 31844) — emitted edge-plane
  faces vs solid cells on the edge planes (missing/spurious/shifted). AC-0427's
  under-void census was a temporary probe (removed per the pristine rule); its
  recipes survive in .scratch/AC-0427/.

**Plan:** tasks/AC-0430/plan.html. A/B first (render the user's view on the served
.so = B, and on a committed-mesh.cpp .so = A, built out-of-tree so the other
session's working tree is never touched), then locate the emitting face with a
temporary UV-census arm in harness.gd, fix in mesh.cpp so every newly emitted face
carries its own orientation's tile, re-verify user's view + seam closure + gates.

## RUN - 2026-10-14 22:5x EDT - A/B + census progress (SUBAGENT, mid-task)

A/B status: B frame (served .so, md5 369456d6...) and A frame (committed
mesh.cpp, re-linked with random_tick.os — the old Aug build log's link line
predates random_tick.cpp) are PIXEL-IDENTICAL in the terrain regions. The
large black step face at the seam (upper center, left of the seam line) is
present in BOTH builds — it is NOT caused by the uncommitted AC-0427 change.
No orange/lava face is visible in the default snapshot view of either build;
the "orange" pixels scanned in the frame are dandelion flowers (233,102,0)
plus a warm-lit dirt band.

Build pipeline note: godot/bin/libchunkio.so + .dll are the 21:11
working-tree builds (contain `seamc` strings); the served build packages
uncommitted native code while labelling itself with the committed hash.
A .so build recipe (manual g++, SCons absent) lives in
.scratch/AC-0430/build_A.sh (now with random_tick.os in the link line).

UV census (temp arm `ac0430uv` in harness.gd — MUST be removed before
closeout): view-independent audit of every emitted near-tier quad's uv
center vs the tile its (block id, face) owns (merge strip / original tile /
(0,0) no-tile). Census bugs found+fixed along the way (the instrument, not
the game): (1) Mesh.ARRAY_TEX_UV (not ARRAY_UV) in this engine build;
(2) resolver: seam-V-extended planes are fractional but OUTSIDE 0..16 —
in-cell (cross/fluid-top) only when fractional AND inside the footprint;
(3) canvas_space is PER-MATERIAL (opaque mat carries merge canvas 1024x
~2656 vs original 1024x1024 — detected via the shader "tex" parameter),
not per-surface; per-face surfaces (cutout/ramp/fluid/cross) are always
original-atlas space; (4) main slab/fluid/flora meshes carry ABSOLUTE y
(seamcensus convention: [mi, 0] / [li, si*16] — yoff was wrongly si*16);
(5) along-plane cell reads must clamp the seam-V-extended span min to the
corner column; the xmin>15 guard wrongly rejected plane-at-16 edge faces.

Census B (served .so), r4 around spawn, after fixes:
  quads 80,969 | ok 67,150 | foreign_strip 0 | foreign_plain 0 | padding 0
  | no_tile_broken 0 | lava_on_nonlava 0 | skip_slope 2,513 |
  skip_no_cell 11,306 (under instrumentation — class 1 = AC-0427 extended
  edge faces, x=-2.5 corners; class 2 = plane-at-16 faces whose owner cell
  reads air in flat_data — get_local cross-check in flight).
Interpretation so far: the current working tree produces NO wrong-tile
face (incl. no lava tile on non-lava) in the r4 spawn region — the user's
10-13 defect is not reproduced by the census in that region; next: same
census on A (diff), and if both clean, widen the sample (bigger radius /
recenter on the stepped-terrain region the user saw) and check the far tier.

## RUN - 2026-10-15 00:3x EDT - A/B verdict + census closure (SUBAGENT, mid-task)

Census instrument now at full coverage (all fixes in the temp `ac0430uv`
arm): absolute-y walk, per-material canvas-space, seam-V clamp, owner
test = any non-air block (leaves are cutouts on the fluid_instance
cutout surface), corner-cell fallback owner for the B-only WARPED
extended side faces (E(t,i) varies per corner -> the 2,513 "slope"
quads in B are NOT ramps (ramps are off by default) — they are AC-0427
seam-V side-face extensions with tilted planes; A has 0 of them).

RESULTS (r4 around spawn, 41 resident chunks):
  A (committed 356da23 .so): 80,969/80,969 ok, 0 foreign, 0 lava.
  B (served .so, uncommitted AC-0427): 80,969/80,969 verified
    (78,456 strict + 2,513 corner-validated soft), 0 foreign, 0 lava,
    0 ambiguous. Frames A/B pixel-identical in the user view.

VERDICT ON THE COORDINATOR'S PREMISE: the uncommitted AC-0427 change is
NOT the cause. Evidence: (1) A/B frame equality — the defect, if view-
visible, would appear in one or both; neither shows a lava terrain face;
(2) the UV census — view-independent, every quad audited — is clean in
B including the 2,513 faces that ONLY B emits (the extended side faces,
each verified to sample its own block's tile); (3) TIMELINE: the
user's report is dated 10-13, the AC-0427 mesh.cpp work ran 10-14
08:11-20:55 (AC-0427 continuity), last committed mesh.cpp = 356da23
(10-12 22:29). A 10-13 build therefore carried the SAME native as my
A build — which the census proves tile-clean in the spawn region. The
"regression already in the shipped build" premise is chronologically
impossible for a 10-13 report (it fits only if the user's report is
really about the 10-14 21:11 build, i.e. B — which the census also
clears in the spawn region).

REMAINING LEADS (in order): (1) wide sample r8 incl. BAND A (far+tier1
materialized TEXTURED columns — AC-0321 was a Sept user report of band-A
texturing, status done) — running; (2) merge-canvas PIXEL audit (uv ->
position is proven; position -> pixel is now audited too: every strip
must be the 16x4 tiling of its claimed original rect — a blit mistake
would render the wrong tile's pixels under correct uvs = the exact
user symptom with a clean uv census); (3) the black seam step-face is a
SEPARATE lighting artifact (uv-correct, vColor sky ~0.08) — follow-up
ticket candidate, not the lava bug. Low/B/C far tiers are the no-UV
average-color placeholders (_lod_avg_mat, "textured emit is dormant") —
they cannot wear a tile by construction.

GATES OWED (my slot): G0 parse+exit (census runs carry 0/0 so far),
smoke, meshprobe, genhash 25/25, seamcensus r4 (seam closure).
A re-run with the final arm (band A + canvas audit) for the record, then
restore B .so (md5 369456d68c2d37823c5cce9d569771d3).

---
SESSION PROGRESS (post-compaction) — THE BUG IS FOUND AND FIXED
- r4 A/B CLOSED: A (HEAD 356da23 .so) ≡ B (served .so) — pixel-identical
  user view + census equality (80,969/80,969 ok both; B's 2,513 ok_soft =
  the AC-0427 warped extended side faces, verified own-tile). The
  UNCOMMITTED AC-0427 change is NOT the cause of the user's report.
- WIDE SAMPLE r8 (radius 8, 113 chunks, 155,143 quads): THE DEFECT
  CLASS — foreign_plain 30,586 + lava_on_nonlava 9,316 — all on
  tier-1 FAR (BAND A materialized) chunks, 100% orig_uv_foreign
  fingerprint (every foreign quad's uv is a valid original-1024-space
  uv for its OWN face tile, but the chunk's opaque material is the
  2144-tall merge canvas → v read 2.09x lower → neighbouring atlas
  rows; column-0 tiles (grass top [0,0]) into the LAVA row [0,32]).
  r4 is clean because the defect only exists past the sim ring
  (band A = far+tier1 materialized columns; r4 has none).
- A-vs-B at r8: THE COMMITTED C++ (A build) SHOWS THE SAME DEFECT
  (31,449 + 9,322, same chunks/class) → the bug is in COMMITTED code
  → this is the user's 10-13 bug (a 10-13 build carried the committed
  mesher). Not AC-0427.
- MECHANISM (proven at every level): the non-uniform fallback quad
  inside emit_ro_merged (the per-corner-lighting "one quad, one colour
  per vertex" path — modern_light default ON; fires on every face with
  a per-corner (msl,mosh,chan) difference = every step-edge face on
  stepped terrain) gets its uv from s_uvc → s_corner_uv which divides
  by atlas_px (1024) — the PER-FACE path's space — but the merged
  build is assembled against the MERGE CANVAS (ms.h=2144 tall). The
  unscaled v samples canvas y = v*2144 instead of v*1024: a stone
  bottom face (own tile [128,0], uv v=16/1024) lands at canvas
  y=33.5 = row 1 = [128,32] (a foreign block's tile); grass top
  (column 0) lands on [0,32] = THE LAVA TILE. Data: 100% of foreign
  quads are single-block (vspan1024=31.0, ncolors=2-4 per-corner
  gradient) — the qwrite_vc signature; zero multi-block.
- The near tier is clean because the flat spawn terrain has uniform
  corners (all faces merge — canvas uv). Stepped terrain (band A far
  ring = the user's mid-distance "stepped terrain") has step-edge
  faces → fallback → 1024 uv on canvas material → the user's exact
  symptom. AC-0321 (Sept, band-A texturing, done) fixed the
  MATERIAL half (mat landing must wear the canvas material via
  apply_accs) but the fallback quad's UV space was never checked.
- MSDEBUG instrumentation (temp, env-gated prints in world.gd, REMOVED
  at closeout): the ms table is FULL (72 rects, h=2144) at ready AND
  at every mat dispatch → dispatch/assemble table divergence ruled
  OUT (the earlier "empty ms at dispatch" hypothesis is dead).
- THE FIX (gdext/src/mesh.cpp, emit_ro_merged fallback only): scale
  the s_uvc v by atlas_px/ms.h before qwrite_vc — the quad then
  samples its own tile in the canvas's BASE region (identical pixels:
  strips are repeat blits of the same rects). The emit_faces call site
  (per-face path, 1024 material) keeps the 1024 uv — untouched.
- POST-FIX BUILD: .scratch/AC-0430/libchunkio_fix.so (md5
  6dc07dbcb62ac3281d1bb08fcb4edac0) — working tree (AC-0427 + fix),
  build_fix.sh (manual g++ recipe, SCons absent). Installed to
  godot/bin/libchunkio.so — the post-fix rebuild the fence allows
  ("B build OR the post-fix rebuild").
- CENSUS UPDATED: new ok_base class — a canvas-space quad sampling
  the face's OWN original tile in the base region = the post-fix
  fallback contract (identical pixels to the strip).
- OPEN: post-fix r8 census (running — expect foreign→0,
  ok_base≈30,586); then user-view re-render (r4), seamcensus r4,
  G0/smoke/meshprobe/genhash gates, A-record rerun, results page,
  REMOVE temp arm (harness.gd) + MSDEBUG prints (world.gd) PRISTINE.

POST-FIX VERIFICATION (running to close)
- census-FIXED-r8: foreign_strip/foreign_plain/foreign_soft/no_tile_broken/
  lava_on_nonlava ALL 0 (155,143 quads); the 30,586 previously-foreign
  fallback quads now classify ok_base (canvas-space, sampling their own
  original tile in the canvas's base region — vspan1024 31→15 = the
  1024/2144 scale, as predicted). The fix works at the UV level.
- BEFORE/AFTER FRAMES: the default r8 user view is byte-identical pre/
  post (md5 548851063ac2… both) — at that camera the mis-sampled rows
  land on visually similar tiles / the affected ring is fog-washed, so
  the defect is sub-visible there. For a VISIBLE before/after the arm
  gained (a) a lava_list (world positions of the quads wearing the lava
  tile on non-lava blocks — 30 recorded: the first cluster is chunk
  -5,2, id 1 GRASS top faces at y=148 around (-67,148,41) — the user's
  exact symptom, grass wearing lava) and (b) an AWECRAFT_CAMT=x,y,z
  camera target (teleport + look_at + snap) so a shot can frame a
  known-bad quad. BEFORE shot in flight (B .so), AFTER shot next
  (fix .so), then the gates (smoke+genhash, meshprobe, seamcensus r4,
  r4 user view), then pristine removal (arm + MSDEBUG prints) + final
  smoke on the pristine tree.
- FINDING (canvas pixel audit): the r8b audit's 90.6% base / 48% strip
  pixel mismatch is a READBACK ARTIFACT, not a canvas bug — the atlas
  texture is sRGB-flagged (import pipeline) while the canvas texture is
  a plain ImageTexture: the two get_image() readbacks are in different
  color spaces (gamma curve → ~90% of non-extreme pixels "differ").
  The UV-level evidence is unaffected and decisive; the canvas content
  is structurally proven by the census itself (121,891 merged quads land
  exactly on their claimed strips + 30,586 fallback quads on their own
  base tiles, post-fix).

CLOSEOUT (all gates done, tree pristine)
- Gates (my slot, all exit 0 / 0 SCRIPT+0 SHADER ERROR): G0 (every run),
  smoke battery ok:true (fixed .so AND the pristine tree post-removal),
  meshprobe match_rate 1.0 (verts 247,848 both sides), genhash 25/25
  BYTE-IDENTICAL to the last verified run (AC-0425 final, 10-13) — on BOTH
  the fixed .so and the served B .so (the manual g++ recipe is
  generation-bit-identical to the shipped pipeline). FINDING: the on-disk
  .scratch/AC-0367-gates/genhash_pristine_r1.log reference is STALE (predates
  the deliberate generation rebases; AC-0400 documents the criterion as
  byte-identity with the LAST verified run, which holds). seamcensus r4:
  4 runs, pre-fix ≡ post-fix byte-identical (1910 missing / 4603 map
  anomalies / 1307 below-floor on BOTH .so builds) — the fix is seam-
  neutral; the 1910 pre-exists on this working tree (AC-0427's in-flight
  seam-V extension vs the AC-0423-rebased census reverse map — AC-0427
  owes the census rebase at its closeout; fenced here, flagged, NOT
  re-baselined).
- Frames: the default r8 view is byte-identical pre/post (defect
  sub-visible at that camera — honest record); the no-fog r8 pair's 12x
  amplified diff shows the ONLY changed pixels = the far step-edge faces;
  cmp-stepface-band.png = zoomed before/after (left: foreign pale tile,
  right: own dirt/grass tile) — the user's defect class in one crop.
  after-fix-r4-userview.png = the acceptance view (grass green, dirt
  brown). Known-bad positions: chunk (-5,2), grass top faces y=148 ~
  (-67,148,41) (30 recorded in lava_list).
- PRISTINE: harness.gd back to HEAD (arm branch + 593-line tail + 2 stray
  blank lines removed, git diff clean); world.gd = AC-0427's 31 lines only
  (my 6 MSDEBUG lines removed). Fenced files untouched (the other modified
  files = pre-existing in-flight work of other tickets).
- .so END STATE: godot/bin/libchunkio.so = the POST-FIX REBUILD
  (6dc07dbcb62ac3281d1bb08fcb4edac0) — the fence-allowed state; it now
  MATCHES the working tree (which carries the fix). The B .so remains at
  .scratch/AC-0430/libchunkio_B.so (369456d6…) should the coordinator want
  the served pre-fix binary. The Windows .dll (the shipped artifact) is
  built from the working tree by the coordinator = carries the fix.
- Deliverables: AC-0430-results.html (self-contained evidence page),
  this journal, 38 gate logs in .scratch/AC-0430-gates/, frames + .so
  builds in .scratch/AC-0430/.
