## RUN - 2026-10-12 22:32:21 EDT - AC-0425
- 2026-10-12 22:32 — RUN opened. Docs read (CONTINUITY top, ARCHITECTURE, AC-0423/0416/0417 results,
  scope AGENTS.md x5, HARNESS, OPS). Tree verified (fenced dirty files pre-existing, .so present,
  ac0423probe still in harness.gd).
- Static sweep COMPLETE. Candidates: C4 (STRONG, new — flat-frame cull boxes vs world-space
  frustum in _frustum_cull_pass [dev manual lane, LIVE] + _gen_skip_flag tail [DEAD under the
  AC-0346 total tier rule: tier0 ⇒ b≤1 ⇒ early return; verified vs band_of/_lod_tier_of/clamps]);
  C1 (flat-frame sun in modern per-vertex lighting — by-design fixed-noon bake, unshaded chunks);
  C3 (generate_resl hardcoded R=4000.0 — latent, only R≠4000 saves). Lanes cleared: mobs/arrows/
  drops/particles (radial, AC-0145 P3/AC-0377), collision (chunk children), fluids, trees, sky,
  stars, clouds, satellite, lod_avg/star/fluid shaders, star shell.
- 2026-10-12 23:05 — plan.html written.
- Baselines (pre-edit): G0 exit 0 + 0/0; genhash 25 lines; SMOKE battery ok (player/interact/
  light/fluids/genhash).
- Temp instruments added to harness.gd (env-gated, unset = byte-identical, OUT AT CLOSEOUT):
  ac0425scan arm (pure-gen cliff-moat scan) + AWECRAFT_AC0425CENSUS=1 planet-preset census
  (flat-box vs placed-box cull decision mismatch + offsets). G0 green after (one parse error fixed:
  missing sort_custom paren; top_of lambda → .call()).
- ac0423probe: ok=true. Seam closure HOLDS (ext_edge live: side A extends to ~0.88 m past the
  seam at t≈140 ⇒ UV stretch on the extension strip ≈ 1.88× at spawn seams — the R4 measurement).
- ac0425scan: 9 cliff-moat candidates; BEST = seam x=-16 @ z≈44 (spawn +(-24.5, 0, +35.5)):
  cliff top 143, moat (neighbour edge cell) 134, far cliff 141 ⇒ dip 9 m, moat width 1 cell (1 m),
  far cliff 1 cell in. f4 target.
- crossface (2×, A/B): all placement/generation/seam sub-gates PASS with IDENTICAL numbers both
  runs (f_seam_max_m 3.73244404792786 = standing corner value; b_edge_delta_max 2.0; crossing-row
  surface chasm 0.388 m at the walk site — the AC-0309 2.19 m was the net-level crossing max, now
  2.7037). THE WALK PHASE fails both runs (walk_frames=5000 cap, walk_crossed=false): A/B-proven
  PRE-EXISTING flake (pristine harness.gd via git stash fails identically; rescue counts differ
  run-to-run: 0 vs 10) — NOT caused by this ticket's harness edits. Report as standing-arm note.
- f1 ground render (R24, default boot camera, +Z): far tier (band B) visible upper-right with
  clean handoff; NO slit at far-tier seams (R2 = harmless, confirmed by frame: 0.5 m at 128–332 m
  is <0.1 px); near seams closed (AC-0423 holds). FOUND: a compact pure-black blob at the cliff
  base (upper-center, ~160 px wide) — present in the AC-0423 after-frame too (standing, not a
  regression). f5 identify render (nadir 600 m over the cliff base) in flight.
- C4 FIX applied to world.gd (placed-frame cull boxes): _placed_cull_prepare/_placed_col_span/
  _placed_slab_span helpers; _frustum_cull_pass uses c.global_transform (cached, no trig) + exact
  transformed-box support 8|n·B.x|+192|n·B.y|+8|n·B.z| (exact for rigid AND LSQ bases); the
  _gen_skip_flag dead tail uses SphereMath.column_transform (home columns only reach it).
  No switch (data/cull correctness, not a look change). genhash must stay 25/25 (verify post).
- 2026-10-13 01:30 — f5 (600m nadir @ (48,158)): real terrain (camera above ground at 600).
  f5b/f5c/f5d (40-80m nadirs): ALL showed an AIR-colour surface — NOT terrain.
- 2026-10-13 02:40 — ROOT CAUSE of the air frames (instrument, not product): the planet preset
  places the camera/player at pl_spn + radial*SAT_ALT, i.e. SAT_ALT above the radius-R SPHERE
  (heightmap h=0), NOT above the terrain. Terrain top here = 141, so SAT_ALT 40/80 puts the
  camera ~60-100 m INSIDE the ground; nadir rays hit nothing until the aero dome's far side
  (air colour 208,241,251 = the f5e frame). Census diagnostics prove it: player y=64.6
  (radius R+80, exactly), anchor still [0,0] (no recenter — recenter is CROSSING-driven, not
  position-polled; a frozen player never crosses — by design, "frozen player = streaming
  anchor"), n=81 chunks = the R4 spawn band. Low-alt planet nadirs only work when SAT_ALT
  exceeds the local terrain top. f5 (600 m) and all orbit shots (2000 m) are unaffected.
  Also: f5's "pale speckled" surface was the SNOW BIOME at (48,158) (biome is temperature-noise,
  not altitude) — spawn grass is ringed by snow beyond ~150 m.
- Terrain map (±480 m, 8 m grid, pre-carve): spawn grass ~0-150 m; ridge (h>=165) first at
  328-336 m in the ±X+Z diagonals; highest 239 at (-392,+304); the +X-Z ray has its ridge at
  656 m (beyond the 400 m render edge). Default boot camera faces -Z (player local -Z, yaw 0),
  frame right = +X — so the f1 "cliff" is the +X-Z direction (azimuth ~+50° right of -Z).
- Mountain-base carve audit (post-carve columns, x -136..-200 / z 280..344, the -X+Z peak side):
  the summit is CARVED OFF — carved top 142-150 vs heightmap 191-218 (punched 48-73 m), void 0:
  a flat 144 plateau where the mountain was. The visible f1 "cliff" (+X-Z) is NOT this side.
- The black blob (f1, ~765,40): 92% of interior pixels are EXACT (0,0,0) — not a dark-lit face
  (shader floor is 0.20*L*0.4*texture ≈ (5,2,0)); hard edge to bright green (3,107,0).
  FOG_PCT=100 re-render (f1b, fog_far=400) leaves the blob pixel-identical (756 vs 761 black
  samples; 480/57600 differing) — NOT a fog-wall window. Unidentified: needs a render with the
  camera ABOVE the terrain (f5f: 250 m nadir over (192,-308), in flight).

## 2026-10-13 03:50 EDT — the f1 black blob: mechanism closed (tree in the light floor), NOT a flat-world defect
- Full-frame re-read of f1 (with HUD): the boot camera is pitched DOWN; the horizon sits at the
  frame's top edge (y~0-2). The top band (y 0-10) is the ground AT the horizon — green grass
  ((3,108,0)/(33,157,0) fog-pale) + 12% black = the tree crown clipped at the top edge. NO black
  sky band, no star-shell space, no body-space sliver (SPACE_SKY is (2,3,10), not (0,0,0), and the
  sky pass fills u_air (208,241,251) at ground level: under_disc=1 → belowc=u_air, verified in
  aero_sky_gradient.gd sky_on + star.gdshader (point sprites only, no space fill)).
- The blob (x 690-860, y 0-75) = a GRASSLAND TREE ~54 m ahead of spawn, world ~(12, -45):
  base at y=75 (2.1° below horizon → d=2m/ tan2.1° ≈ 54 m), 3.9° right of centre → x≈12. Canopy
  ~4.6 m wide, crown above the horizon (clipped). First green below it at y=75.
- Fingerprint: 87% exact (0,0,0) + tail (1-8, 0, 0) (red-shifted, G=0 — trunk bark (60,15,8)-ish,
  NOT grey → NOT the cloud deck (white tint), NOT space (2,3,10)). f1g A/B (AWECRAFT_SAT_BODY=0):
  blob PIXEL-IDENTICAL (2568/6400 both) → in front of the body → near-terrain object.
- Mechanism: the trunk blocks sit UNDER the crown in their own column → starlight sky pull s = 0
  (the crown occludes the sky in that column) AND sun pull g = 0 (leaves are opaque to the light
  pull) → L = the 0.20 floor → ALBEDO = tex × faceShade(0.8 side / 0.5 under) × 0.20 = ~0.1-0.16×
  the dark bark/leaf atlas cells → sub-8-bit → (0,0,0) silhouette + the thin sunlit rim where the
  sky opens past the crown. The cutout shader (chunk_lit_cutout.gdshader) has the SAME 0.20 floor
  as opaque — the dark canopy undersides (f2 nadir shows the crowns' LIT tops green; the f1 view
  shows the shadowed sides/undersides).
- DISPOSITION: look property of the 0.20 light floor (a daytime tree reads as a black silhouette;
  MC renders the forest floor ~1/16 = brighter). Standing state (predates AC-0423). NOT a
  flat-world assumption, NOT a see-through, NOT one of the four residuals → reported with the f1
  frame, NOT fixed.
- The f2 seam zoom (nadir 160 m @ (16,8)): the x16_z0 seam is CONTINUOUS — no slit, no stitch,
  terrain steps normal (brown dirt edges = 1-2 m step sides). Yellow + grid at chunk corners
  (64..96, -32..-64) confirms the chunk lattice is intact. R1/R4 frame evidence done; the 0.88 m
  extension-strip UV stretch is sub-pixel at 0.4 m/px (probe owns the number: 1.88×).
- Dark 16 m block at f2's left edge = a natural POND (45,101,120 blue-grey water, world
  ~(16, 244)) — matches the heightmap water cells, not a blob phenomenon.
- Satellite-bake edge check (f1 wedge follow-up): face00.left vs face01.right = the internal
  x=0 seam (mean diff 0.4/765 — continuous, gapless invariant holds); face00.right vs face01.left
  = the wraparound patch edges (mean 228 — expected: different neighbours, not a defect).
  No black pixels anywhere in either full PNG.

## RUN (resumed) - 2026-10-13 05:54 EDT - AC-0425
- 2026-10-13 05:00 — RESUME. No stray processes (the previous run's f3a render had died at t≈277s
  with no PNG; the C4 fix was left in `stash@{0}` "AC-0425 f3a pre-fix" — the previous run stashed
  world.gd for the pre-fix state and never popped). Tree state: world.gd == HEAD (pre-fix),
  harness.gd = HEAD + AC-0425 instruments, a 04:13 results-page DRAFT with {{placeholders}}.
- f3a RE-RUN (reconstructed recipe: planet nadir CAM_OFF 3917,110, SAT_ALT 170, R4, manual, census):
  exit 0, 0/0, PNG written. THE PLAN'S CORNER STATE HAS NO RESIDENT WORLD: the preset flies a FROZEN
  player → anchor pinned at spawn (recenter is crossing-driven by design) → camera 3.9 km into
  unstreamed face territory. Frame = the satellite body's snow disc, no terrain. Census: n=81 (spawn
  band), mismatch 0, max_off_m 4.5017 (chunk "1,5"). The 2.3 km flat↔placed case (column 188,188) is
  UNREACHABLE: the resident band caps ~130 m from the anchor; AC-0346 keeps the _gen_skip_flag tail
  dead. The previous draft's expected "mis-culled band" at that state was wrong.
- f3c (spawn nadir 170 m, R4, manual, pre-fix, census): exit 0, 0/0. Frame: terrain + a pale
  (233,255,255) fog-washed far-field region with a chunk-grid staircase boundary. Census: n=81,
  mismatch 0, max_off 4.5017. The pale region's colour ≠ u_air (208,241,251) — pixel-archaeology
  inconclusive; resolved by A/B instead.
- f3d (identical state, ENGINE cull): exit 0, 0/0. **f3c vs f3d: 0/921,600 px differ (pixel-identical)**
  → the pale region is a cull-lane-independent layer (same structure as the previous run's f4 frame);
  the pre-fix manual lane renders exactly what the engine lane renders in the renderable state.
- Face-chunk reachability check (why C4 is unrenderable): _face_stream gates on _rec_player_wx/wz
  (recenter state, win = sim_dist*16 = 64 m of the 3141 m patch edge); a frozen player never
  recenters → face chunks never resident in any snapshot-capable arm → the only >32 m case
  (face chunk adjacent to the patch edge, flat box ~3.1 km from placed) cannot be rendered here.
- C4 VERDICT: real code shape, FIXED (kept), NOT frame-confirmed → unconfirmed table (U1) with the
  measured bound (≤4.5 m < 32 m margin; 0 decision mismatches; pixel-identical A/B).
- stash popped (world.gd +57/−13). G0 post-fix: exit 0, 0/0.
- f3b (post-fix, manual, spawn nadir, census): exit 0, 0/0. **f3b vs f3c: 0/921,600 px differ** —
  the fix is frame-neutral in every renderable state.
- Instruments REMOVED from harness.gd (ac0425scan branch, the AWECRAFT_AC0425CENSUS census block +
  result field, _ac0425scan_test + _ac0425cave_test): harness.gd now BYTE-IDENTICAL TO HEAD
  (git diff empty). ac0423probe stays — it is committed in HEAD (the AC-0423 instrument).
- GATES on the final tree, all exit 0 + 0/0 census: G0; SMOKE battery ok:true 260 s; PROBE ok;
  GENHASH 25/25 byte-identical to the pre-edit baseline (standalone + battery); SHADERFORCE 12/12;
  BOUNDARY r4 in-band (20/20 crossings, p50 13 flat, p95 35, crossing_frame 32/47/50,
  staged_dropped 2646 ≤3200, residue 0, footprint missing 0, resident 93 identical, built 64 vs 61
  count drift, unbodied_built 0 vs the flagged 8). No standing value moved out of band.
- Results page rewritten (the draft's C4 "confirmed" row + {{placeholders}} replaced with the
  reclassification above); frames f3a/f3b/f3c/f3d added to captures.
- OPEN FOR THE COORDINATOR: (1) the black-mass tree deserves its own LOOK ticket (not filed —
  TASKS.yaml fenced this run); (2) the crossface walk-phase flake (A/B-proven pre-existing, rescues
  0 vs 10) is a standing-arm reliability note; (3) the U5 planet-preset SAT_ALT instrument bug —
  note for the instrument owner; (4) the heavy gate set (farab/ladder/meshprobe/halo/lightstate/r16/
  r50) is owed by the coordinator's job.
