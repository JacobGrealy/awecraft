## RUN - Sat Oct 17 13:47:27 EDT 2026 - AC-0444

### 14:1x — band reproduced in fresh drain-3000 run (pre-band.png)
- Band byte-present at x=1200 (dark teal rows ~282-370) and x=1100; left-edge muted wedge present.
- SKYPROBE read-back (f=299, pre-recenter instance): ALL sky uniforms exactly as predicted — w=0, ws=0, u_horizon=1, u_no_floor=1, u_limb_gate=1, u_air 8-bit (208,241,251), u_limb_center=(-8.79,-4143.6,-8.79), u_limb_radius=4126, u_atmo_radius=5200, haze 0.4, u_moon=0. Player (8.78,141.98,8.78), alt_rad=142.
- Single probe print = R-band recenter (AC-0135) freed/recreated World mid-run; value-gated pushes make snapshot-time uniforms the same deterministic values.

### 14:3x — corrected-basis sim (sim2.py)
- fwd basis fixed: (-0.9968,0.0799,-0.0008) vs measured (-0.99664,0.08191,-0.00063). Right side of frame looks -X/-Z; band pixels x=1200 have hl=+1.8..+12.7 (ABOVE local horizon).
- Committed sky_on model + live uniforms predict BRIGHT sky (121-209,208-241,237-250) at every band pixel; observed dark teal. Irreconcilable → band pixels are NOT the sky pass output.

### 14:5x — A/B battery — LAYER EXCLUSIONS
- ab-aero0 (sky pass OFF): band PERSISTS → NOT the sky pass.
- ab-radius4 (no terrain beyond ~80m): right band → bright sky (234,255,255); BUT x=1100 shows surface colour change (dark-green (0,58,0) → teal (46,128,118)) under BYTE-IDENTICAL sky rows → R4 not a clean A/B at x=1100 (surface/tree swap), partially contaminated.
- ab-limb0: band byte-identical (limb term 0 at ground anyway).
- ab-body0 (AWECRAFT_SAT_BODY=0): band 99% byte-identical → NOT the satellite body.

### 15:0x — terrain decode (baked face PNGs, decode_faces.py)
- Right-band sightline (dir -0.43,+, -0.90): GRASS (55,104,34) sRGB, H 129-163 m at flat d=80-300. Left band: same grass, H 135-148. Centre: sand (217,205,162) H 150-157.
- grass × day_gray(0.75) × lit∈[0.2,1.0] cannot produce B=113 (grass B=34) under any lighting. Water (40,110,220) matches R,G but B 2× too high and geometrically invisible at hl>0. fog_display (208,242,251) bright — not it.
- LOD avg: ALBEDO = block_avg × day(sky-brightness GRAY) × jit ±6% × lit(mix(0.2,1.0,COLOR.a)+u_amb·day.r·(1-a)); engine env fog begins ~275.6 m (no fog at band distances); discards d≥332.

### 15:3x — R4 diff map: diffs follow terrain silhouette full-frame; sky-top zero diffs; crest rows identical at x=640/800/1000 → NOT global pose drift; far-terrain disappearance pattern.

### 15:4x — PIXPROBE (temporary, env-gated, REVERT AT CLOSEOUT)
- world.gd: AWECRAFT_SKYPROBE_PIX="px,py" raycasts the pixel through all non-satellite MeshInstance3D children, prints 3 nearest hits + material identity (_ac0444_mat_id: LOD_AVG/RING_WATER/FLUID5/SHD:path).
- Two parse-error incidents fixed: `is` with call-expression RHS; untyped-loop-var `:=` inference + Vector4(Vector3,float) (no such ctor — use Transform3D*Vector3 + basis.transposed()).
- Parse verified headless --check-only (standalone "Identifier not found: Game" at :872 is EXPECTED — autoloads absent).
- RUN bash-973 in flight (drain 3000).

### Resume point (15:4x)
1. Collect PIXPROBE prints (grep PIXPROBE pixprobe.log) — band surface identity at x=1200,y=312.
2. If band is a legit surface: is its colour correct-for-model or a tier-seam lighting inconsistency (second AC-0443 a=0-class instance)?
3. 5-fixes battery: .scratch/AC-0444/fixes_run.sh (alt1200 limb / alt941 hz / alt1441 hz / alt2141 hz / alt2000 nadir; R24 drain 60 NO_FOG CLOUDS=0; RESULT carries live sky uniforms). AFTER pixprobe.
4. Ground-frame evidence: pre-band.png (AC-0419 bright day sky; AC-0422 profile across row ~393 for hard step).
5. REVERT probe EXACTLY (counter var, both probe blocks, _ac0444_mat_id); re-verify world.gd; G0 (gate_census.py, check PROCESS EXIT STATUS), SMOKE, PROBE, genhash 25/25, shaderforce.
6. results page + ≤20-line report; band-gone/consolidation verdict.

### 16:1x — PIXPROBE mystery: the probe never fires at snapshot time
- pixprobe.log (bash-973): SKYPROBE prints EXACTLY once (f=299), then nothing, though SNAPDRAIN ran to 3000 frames (t=228.8 s wall, ~12.8 FPS). No SCRIPT/SHADER ERROR (census clean, RC=0).
- SATDIAG state lines flow to the END of the run — but they come from SATELLITE's own `_process` (satellite_body.gd:1337 `_satdiag_tick`, 2 s period), NOT from world._process → satellite.liveness does NOT prove world._process liveness (red herring).
- Added PROBECALL (n,f) every 100 calls + PIXPROBE window f>=2800 every 25 f (pixprobe2, bash-975): STILL only SKYPROBE f=299, no PIXPROBE.
- pixprobe3 (bash-977) with call-based triggers: PROBECALL n=100→f=99 … n=500→f=499 (1:1), then STOPS. Game renders to f=3000. → **world's `_ac0401_push` (hence world._process tail) stopped after call ~500 while the satellite's own _process keeps running and the scene keeps rendering.** No set_process(false) in game path (only breakspike arm harness.gd:9128), no tree pause, no process_mode anywhere in GDScript. Cause unknown — instrumented PROCTOP (world._process head, %200) + SATPROC (satellite _process, %500) + moved the PIXPROBE raycast FIRING into satellite _process (calls 2900-3000, every 50) via `w2.call("_ac0444_pixprobe", mn2, pixenv2)`.
- satellite_body.gd now carries a TEMPORARY probe (counter var _ac0444_satn + _process block) — REVERT AT CLOSEOUT (add to revert list).
- RUN bash-995 in flight (pixprobe4): will answer (a) is world._process fully stopped? (b) is satellite _process alive to the end? (c) WHAT IS AT THE BAND PIXELS (1200,312),(1200,348),(60,405),(100,300),(1100,340) — mesh + material identity.

### 16:5x-17:4x — probe mystery deepens (not ticket-blocking, logged for the report)
- pixprobe6/7: tick-fired raycast (inside _satdiag_tick) never fires; PIXTRIG (added run 7) never prints, yet the state line (same function, same node, same _satdiag gate) flows to t=233-262. A single-object same-function paradox.
- pixprobe7 run: env vars provably alive at f=499 (SATENV env=[1]); no set_environment touches AWECRAFT_SKYPROBE; only one satellite configure burst (no second node _ready); no tree pause / process_mode anywhere; no on-disk script cache in .godot.
- STATE CADENCE FINDING: _satdiag state period is 2.0 s but the observed interval is ~9.4 s steady from t≈14 s onward (2.0 s at t=12-14). Explained by frame hitches (llvmpipe build load, 0.5-2 s frames) + the default 0.1 s Engine.max_frame_delta clamp: acc clamps, tick interval stretches. NOT the f~500 freeze (that is a hard stop of the _process HEAD blocks in BOTH world.gd and satellite_body.gd, at n=400-500/f=399-499, while the _process TAIL keeps running).
- TREECENSUS attempt (run 8): SceneTree.process_frame lambda connected in satellite _ready - NEVER fired (no census, no PIXPROBE). Either the boot object ran a pre-v8 script or the process-frame signal itself stopped firing.
- Run 9 (bash-1002): physics-phase probe in WORLD._physics_process (the physics phase demonstrably survives - the drain loop awaits get_tree().physics_frame to 3000): PHYS liveness print every 500 calls + one-shot _ac0444_phys_probe() at n>=2900 (names WORLDID/SATELLID/CAM instance ids + has_method flags + runs the companion raycast on the live world object).
- IF run 9 also fails: fall back to OFFLINE tier-identity reasoning (the sightline block census from the baked face PNGs + lod_avg tier windows) - the band tier is already bounded to lod_avg BAND B (96-332 m) by the R4 A/B.

### 17:5x — MYSTERY SOLVED (there was no process stop at all)
- pixprobe9 PHYS probe: _physics_process keeps calling (n=3500) while Engine.get_process_frames() only reached ~583. Ratio ~6 physics steps per engine frame: under llvmpipe frame hitches (0.4-0.5 s frames) the engine runs multiple physics steps per frame (max_physics_steps_per_frame, default 8).
- THE "3000-FRAME DRAIN" COUNTS get_tree().physics_frame AWAITS = PHYSICS STEPS, not engine frames. The run ended at engine frame ~583.
- Every "frozen" probe was engine-frame-cadenced (next print at f=599/749/999) - the run simply ended before the next print. No freeze, no node replacement, no stale cache, no mystery. WORLDID/SATELLID single generation, satellite has the new methods (has_local=true).
- PHYSPROBE fired (n~2900 physics steps, f=508 engine frame, ~12 steps before the snapshot at n=3000/f~520) but "CAM inst=null": Main's `camera` member is null in this setup - the rendering camera is the viewport's current camera. Fixed: get_viewport().get_camera_3d() fallback in both _ac0444_phys_probe and _ac0444_pixprobe.
- Run 10 (bash-1004) in flight with the viewport-camera fix.

### 18:0x-18:3x - raycast debugging sequence (pixprobe11-16)
- pixprobe11: AABB pre-set + is_ray_intersect: still n=0 on all pixels (incl. the (640,620) foreground-grass control).
- pixprobe12/13: RSTAT census: find_children("*","MeshInstance3D") = 0, find_children("*","") = 0, find_children("*","Node3D") = 0 - but get_children() shows 1468 children (64 MeshInstance3D + 1 MultiMeshInstance3D + 1402 Node3D + CanvasLayer). VERDICT: Node.find_children() is broken / returns empty on this engine build (4.7.1.a13da4feb) regardless of pattern/type. Hand tree-walk required.
- pixprobe14: manual walk + is_ray_intersect crashed: ArrayMesh.aabb is READ-ONLY on this engine ("Invalid assignment of property or key 'aabb'"). The zero-aabb fix is impossible; is_ray_intersect on degenerate-aabb meshes is untrustworthy.
- pixprobe15: replaced with a manual Moller-Trumbore _ac0444_tri_ray (per-surface surface_get_arrays, 400k-tri cap). CONTROL RAY WORKS: straight down from frame centre hits a mesh at d=0.5 m (the ground under the camera); 634 MeshInstance3Ds found by the hand walk. Then crashed: Mesh.get_surface_material does not exist on this engine's ArrayMesh.
- pixprobe16 (bash-1012): material lookup guarded by has_method (get_surface_material / get_material fallbacks). In flight.
- Engine-build API notes for the report (verified, 4.7.1): Node.find_children returns empty; ArrayMesh.aabb is read-only; ArrayMesh lacks get_surface_material.

## AC-0444 — BAND IDENTIFIED (decisive, 2026-10-17)

**WHERE THE BAND COMES FROM (magenta-probe decisive):**
The teal band is the `lod_avg` FAR LOD tier (med/low avg-color placeholder),
specifically its **a=0 (unlit/side) faces**. Proven by forcing lod_avg.gdshader
ALBEDO to magenta (probe-magenta.png: the whole band -> magenta) and then
splitting a=1->cyan / a=0->magenta (probe-ab.png: the big dark band is the
magenta a=0 faces; the a=1 tops are only scattered cyan specks).

**Geometry:** the distant terrain on the far side of the planet curves up into
view above the local horizon; at the grazing angle we see the vertical SIDES
of the far terrain boxes (a=0 faces), which form the horizontal band. The band
sits in the sky region (hl>0) where the aero sky model renders BRIGHT
(~208,240,250) — the band is (41,62,69) dark. So the band is NOT the sky; it
is terrain drawn in the sky region.

**Why dark (the chromatic signature):** a=0 faces render at the cave-floor
`lit = 0.2 + u_amb*day.r` (u_amb=AMB_SKY_L=0.35, AC-0443) x day.rgb (the sky
display colour, teal tint) x jit — far darker than the chunk_lit (band A)
shaded flank of the same ridge. This is EXACTLY the AC-0443 "R24 horizon dark
patch" (lod_avg.gdshader lines 66-75 comment): the tier seam where the far
tier's unlit faces are darker than the chunk tiers.

**Fog-gated (probe-ab-fog0.png):** with AWECRAFT_NO_FOG=1 the a=0 band region
is EMPTY (bright sky, only a tiny speck). The far tier is a fog-gated
distance placeholder: built/rendered only when env fog is on (to fill the
distance to the fog wall u_fog_far=332m). The brown far boxes below the
horizon (y=450+) are unaffected by fog; only the above-horizon a=0 band is
fog-gated.

**IS IT A SYMPTOM OF THE 5 SKY FIXES? NO.**
- The aero sky model renders BRIGHT at the band elevation (measured, w=0,
  ws=0, u_horizon=1, u_no_floor=1 live): (1200,342)->(208,240,250). The band
  is (41,62,69). The band CANNOT be the sky pass (sky_on OR the aero-off
  sky_off default path — aero0 A/B keeps the band).
- Exclusion chain (byte-measured A/B): sky pass (aero0: persists) X, clouds
  (AC-0443) X, satellite body (body0: identical) X, limb glow (limb0:
  identical) X, fog colour (fog is bright u_air, band is dark) X.
- The 5 sky fixes (AC-0417/0419/0422/0429/0439) are all sky-model fixes; they
  are correct and hold, but they never touched the far tier's a=0 face
  rendering — which is where the band actually comes from.

**VERDICT:** the band is a FAR-LOD / TIER-SEAM artifact (the a=0 faces), NOT a
sky-model artifact and NOT a symptom of the accumulated sky fixes. It is the
AC-0443 "R24 horizon dark patch," partially addressed (u_amb lift) but not
fully closed. STRUCTURAL in the far-LOD sense (the tier seam remains latent
for every ridge flank seen at a grazing angle), one-off in the sky sense
(no sky consolidation needed for it).

**CONSOLIDATION RECOMMENDATION (valid outcome per ticket):** close the tier
seam — shade the far tier's a=0 faces to match the chunk_lit shaded
brightness (the u_amb lift is a partial parity, not a full match). This is a
far-LOD fix, not a sky fix. The 5 sky fixes keep holding; do not touch the
sky model for this band.

## Engine API + harness observations (harvest candidates)
- find_children() returns EMPTY (all patterns/types) on a node with 1468
  children — hand-walk get_children() recursively.
- ArrayMesh.aabb is READ-ONLY; ArrayMesh has no get_surface_material in this
  build (guard has_method); Basis has no .columns (use cb*Vector3.UP).
- is_ray_intersect untrustworthy on degenerate-aabb / the satellite body
  mesh (reports hits at impossible distances, 6061 from the body centre); a
  manual Moller-Trumbore with front-face cull is more reliable but still
  flagged SAT hits that A/B disproved — treat the raycast as corroborating,
  the A/B isolations as ground truth.
- _physics_process runs ~6 physics steps per engine frame under llvmpipe
  hitches (max_physics_steps_per_frame catch-up): a "frame" drain counted in
  physics_frame awaits is only ~500 engine frames. No freeze, no node
  replacement — the "frozen process probes" simply never reached their next
  print before the run ended.

## AC-0444 — CLOSEOUT (gates + 5-fixes, 2026-10-17)

**5 fixes hold (planet-camera altitude frames, fog+clouds off to isolate the sky):**
- AC-0417 reg-a1200-limb (alt=A=1200): smooth sky above the limb, no
  face-boundary step, not black. Live u_space_sky=1.0.
- AC-0419 (all): day sky bright cyan; nadir reg-a2000 shows the planet an
  OPAQUE green/white/blue disc (not black).
- AC-0422 reg-a941/1441/2141-hz: continuous horizon, centre-left ==
  centre-right (dL=0,0,0).
- AC-0429 reg-a2141-hz (outside A) + nadir: below-horizon = smooth SPACE,
  no bottom edge, the planet is the boundary. Live u_space=1.0 @2141.
- AC-0439 reg-a941-hz (inside A): below-horizon = bright AIR
  (205,250,250), not black. Live u_space=0.335 u_space_sky=0.953 @941.

**GATES (light only; heavy is the coordinator's):**
- SMOKE (player;interact;light;fluids;genhash): rc=0, 0 SCRIPT/SHADER
  ERROR, all 5 arms ok, ok:true.
- genhash: 25/25 byte-identical to the CURRENT baselines (HEAVY-r22
  2026-10-17, AC-0441, AC-0439-r2). The AC-0367 ref is STALE — the
  genhash legitimately moved AC-0367->AC-0439 via other world/light
  tickets. Tree clean (git diff empty on world files) + matches the
  immediately-prior ticket's baseline => NO drift from this task.
- shaderforce: rc=0, ok:true, 12/12 shaders verdict=ok, 0 real
  SHADER/SCRIPT ERROR (the lone "SHADER ERROR" grep hit is the arm's own
  note text; gate_census keys on the line-start "SHADER ERROR:" colon).
- G0 (gate_census + rc): 0 SCRIPT/SHADER ERROR across all 8 gate logs,
  every rc=0, census ok, exit 0.

**REVERT (pristine rule):** all probes out — world.gd (4 counters, PHYS
block, _ac0444_phys_probe/_pixprobe/_tri_ray/_mat_id, SKYPROBE+SKYPROBE_PIX
blocks, PROCTOP), satellite_body.gd (3 vars, TREECENSUS lambda, SATENV/
SATPROC, _ac0444_pixprobe_local, PIXTRIG), lod_avg.gdshader (magenta/a-b
probe). git diff --stat on all three = empty. Both .gd parse 0 Parse Error.

**NO-ACTIONS:** no patch (the ticket accepts a consolidation recommendation;
a symptom-hiding patch is not wanted; the band fix belongs to a far-LOD
ticket). Fences untouched. No commit/push.
