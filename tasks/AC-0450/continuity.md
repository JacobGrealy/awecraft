## RUN - Mon Oct 19 00:00:34 EDT 2026 - AC-0450

- Fresh run (no prior entries). Tree 2b2f048 (AC-0449 committed); only the standing
  untracked set in git status.
- Read the ticket notes in full (TASKS.yaml AC-0450), CONTINUITY r26 checkpoint,
  ARCHITECTURE.md, AC-0399/AC-0449/AC-0394 results + AC-0449 continuity, HARNESS.md
  (§2 env table, §4 recipes, §5 gates), OPS.md, gate_census.py.
- Spec-verified derivation homes (line numbers had drifted since the notes were
  written — the functions/expressions are the homes, not the lines):
  - fog_far home = `DayNight.fog_far(render_radius, fog_start_pct)` —
    core/daynight.gd:49-50 (notes said 27-28); pushed to env.fog_depth_end at
    scenes/main.gd:1538 and to the tier materials at world.gd:5338 (_ac0401_push).
  - render edge home = `float(world.render_radius + 1) * 16.0` — scenes/main.gd:1523
    (notes said 1477-1478); the same expression at world/satellite_body.gd:931
    (_tick_view), stored on the body as last_render_edge / last_fog_far (live reads).
  - User's settings: R24 / FOG_PCT 83 -> fog_far 332.0 / edge 400.0 (matches the
    notes; 25*16*0.83 = 332.0).
- Elimination hooks confirmed by code read:
  - AWECRAFT_SKYALT=0|1 -> Settings sky_altitude boot preload (settings.gd:114):
    selects the two sky BODIES (aero_sky_gradient.gdshader u_sky_alt). Geometry
    pixels are switch-blind; background pixels change.
  - AWECRAFT_NO_FOG=1 -> env.fog_enabled = false at boot (main.gd:94-95): the
    engine depth fog off. Near/far tiers de-fog; body untouched (fog_disabled);
    sky untouched.
  - AWECRAFT_SAT_BODY=0 -> satellite_body.gd:358 _body_off: the body hidden.
  - AWECRAFT_NO_WORLD_VIS=1 -> world.visible = false (main.gd:241-242): ALL world
    geometry hidden (near + far tiers + body) — the background reference frame, and
    the "coverage disabled" negative test (no coverage pass exists yet to disable).
  - CLOUDS=0 (AeroLib.clouds_on, aero.gd:140) kills the cloud shells at creation —
    measurement runs are cloud-free (the AC-0399 precedent).
- AC-0449 measured facts that bound the design: at the 941 m radial vantage the
  engine fog carries NOTHING (fog-off frame BYTE-IDENTICAL to as-shipped, md5
  998abb98...); the planet-preset frame is byte-identical across runs (CLOUDS=0,
  settled); the preset camera carries NO CameraAttributesPractical (no DoF) — the
  user's camera is 90 base / x1.10 in flight (player.tscn:20, player.gd:851).
- Vantage decision (recorded, not pre-decided): radial altitude 941 m (the user's
  documented flight altitude, AC-0449) looking down and outward (30 deg below the
  local horizon by default, env-settable), FOV default 99 (the flight FOV). A
  nadir aim flag gives the AC-0451 annulus view; a player-camera flag gives the
  DoF-carrying frame. At 941 m every in-frame ground pixel is >~960 m out — past
  the render edge — so the tiers (which discard at d >= fog_far 332) own nothing
  in frame; the census isolates body vs background vs sky, which is exactly the
  elimination the ticket asks for. The 300 m case (the handover annulus) is a
  separate reading, reported as context, not conflated with the user's vantage.

## OUTCOME - AC-0450 (appended at run end)
- Built: the `air` preset (harness.gd air branch, self-contained like `planet`:
  frozen-player vantage, body-LOADED wait, AWECRAFT_SNAP_STEPS settle pairs,
  RESULT carries the measured shot pose + LIVE derived fog_far/render_edge +
  the sky's pushed uniforms) + `tasks/AC-0450/aircensus.py` (pure Python+PIL,
  no numpy on this box) + the HARNESS.md §2 `AWECRAFT_AIR_*` row.
- Census mechanics: per-pixel max-channel-delta elimination against the
  world-hidden reference (tol 2/255): (a) background = |F0-F4|<=tol, split by
  the F1 sky-swap (sky_true = changes with the sky body; hazed = does not =
  fully-hazed body reading as the air colour, the AC-0401/AC-0429 single-
  source design) and by the ray->R-sphere model off the MEASURED pose
  ((a)_hole = reads-background where the ray hits the planet). (d) body =
  |F0-F3|>tol; fog-owned = |F0-F2|>tol. Distance axis = the per-pixel near
  ray->sphere intersection (sign error caught in test: the near root is
  -bd - sqrt(disc); the far root is the opposite side of the planet).
  The bare-R-sphere model undercounts the disc by the silhouette-extension
  band (terrain height above the bare sphere at the tangent): 44,736 px
  (4.85%) at 941/30deg, reported as the band, not hidden.
- HEADLINE (941 m, 30 deg, 99 FOV, R24/FOG_PCT 83, fog_far 332.0, edge 400.0
  live-derived): (a) 66.95% (64.57% true sky + 2.38% hazed body), (a)_hole
  0.006% (55 px, ALL hazed; 0 sky-true), (d) body 33.05%, tiers 0 in frame
  (min geometry distance 961 m > 332 m wall - measured, not assumed),
  fog-owned 0.0. NEGATIVE TEST: (a) rises 66.95% -> 100% with the world
  hidden (F4) and with the body alone off (F3 - F3 == F4 byte-identical,
  md5 bc024f8d...: at 941 m the body is 100% of the drawn world geometry);
  the rise = exactly the removed geometry; (a)_hole rises to the whole
  planet-intersecting disc (28.20%). The counter CAN be made to fail.
  F2 (fog off) == F0 settled BYTE-IDENTICAL (md5 a9d2876a...) - the engine
  fog carries zero pixels at this vantage (the AC-0449 finding reproduced
  on an independent camera).
- Contrast-with-distance profile (visible geometry, adjacent-pixel luma
  delta, 12 equal bins 961-2889 m): C_mean 1.96 (near) falling to 0.68
  (far) - a ~3x far-field collapse. The sky reference (body-off disc) is
  flat air: C 0.0-0.06 - so the measured profile is the body's OWN far-LOD
  contrast, not fog or sky. 941 m nadir: 3.49 -> 0.94. 300 m nadir:
  10.38 (300-370 m, the real band + band A) collapsing to 0.1-0.5 at 440 m+
  (bands B/C 8x8/4x4 averages - the far tier is near-flat in frame: the
  handover-annulus reading, reported as context with the 11.5% tier class
  in that frame). Playercam (DoF live, 90 FOV): the profile tracks the
  bare camera within ~0.15 C units and shifts 1.7% of the frame from
  visible-geometry to background-reading - the AC-0449 DoF fix held; the
  far-field collapse is the body's far LOD, not DoF.
- THE TRAPEZOID: a flat brown (96,68,38) trapezoid pinned to the frame top
  in every preset-camera frame, surviving AWECRAFT_NO_WORLD_VIS - the
  frozen player's head block, near-clipped (the preset camera sits at the
  player's vantage). Fix: player.visible=false in the preset-cam path only
  (the body's uniform rides position, not visibility). Re-rendered the
  whole matrix clean. Documented in the HARNESS.md row.
- Gates (mine): G0 RC=0 + 0 SCRIPT + 0 SHADER ERROR (3rd run; the first
  caught a real cosf/sinf parse error in the new branch - fixed); SMOKE
  battery player;interact;light;fluids;genhash ok true RC=0; genhash 25/25
  byte-identical to AC-0445 AND the coordinator's HEAVY-r22 set (world gen
  untouched; the AC-0367 reference file is STALE - pre-AC-0311-piece-2
  rebase); PROBE = the air arm: 25 render runs, all RC=0, all carrying the
  Forward+ boot line, all SNAP-confirmed, PNG existence + exit status
  checked on every one.
- Files (NEW): tasks/AC-0450/aircensus.py, tasks/AC-0450/census-{941-30,
  941-nadir,300-nadir,playercam}.{json,out}, tasks/AC-0450/plan.html,
  tasks/AC-0450/continuity.md, tasks/AC-0450/AC-0450-results.html,
  tasks/AC-0450/captures/*.png (17 frames). MODIFIED: godot/scenes/
  harness.gd (air branch only), godot/HARNESS.md (the air row + the
  preset list). .scratch/AC-0450/ = 25 run logs + g0/smoke/genhash logs.
- Deliberately NOT done: no coverage pass (the instrument precedes the
  fix - the ticket builds a counter, not a cure); no winner declared among
  the four states (reported as evidence: fog owns 0, the sky body owns
  64.57% of the frame, the body owns 33.05% visible + 2.38% hazed,
  tiers own 0 at 941 m / 11.5% at 300 m); no change to world/, shaders or
  autoloads; no commit (coordinator's closeout); the HEAVY gates are the
  coordinator's.
