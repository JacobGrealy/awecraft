## RUN - Sat Oct 10 10:15:28 EDT 2026 - AC-0415

- 10:15 run opened (READ-FIRST done: ticket notes in TASKS.yaml, CONTINUITY top checkpoint,
  ARCHITECTURE.md, aero.gd/aero_sky_gradient/lod_avg, the AC-0399/0400/0404 results, HARNESS §2/§4/§5, OPS).
- Recon key facts: lod_avg.gdshader = render_mode fog_disabled + u_air/u_fog_near/u_fog_far +
  fog_f = clamp((d-u_fog_near)/max(u_fog_far-u_fog_near,1),0,1) + ALBEDO=mix(ALBEDO,u_air,fog_f)
  (the duplicate); u_render_edge/u_center declared+pushed but never read (dead); u_fog_far also
  feeds the AC-0401 partition discard (KEEP). u_air == env.fog_light_color == Aero.fog_display
  (single source, AC-0384 r8). main.gd:1474-1479 pushes the uniforms per frame (FENCE-LOCKED —
  the u_air/u_fog_near/u_render_edge/u_center pushes become no-ops after the shader change; the
  u_fog_far push stays live; dead-push deletion lands in the coordinator's commit per the
  ticket's fence note). world.gd _ac0401_push + satellite_body.gd compute DayNight.fog_far
  INDEPENDENTLY of env (so chunk/fluid/body walls are unaffected by the fog switch; only
  lod_avg reads env.fog_depth_end for its partition — true before AND after this change).
- plan.html written. G0 baseline on the pre-edit (dirty, 4 fenced files M) tree: rc=0, 0 SCRIPT
  ERROR, 0 SHADER ERROR (census ok).
- Render recipe (deterministic; settings ignored via _harness_env_set, env overrides pin the
  user's config): xvfb-run + VK_ICD lvp + --rendering-driver vulkan, AWECRAFT_CAM=planet
  AWECRAFT_SAT_ALT=300|120 AWECRAFT_TIME=0.30 AWECRAFT_RADIUS=24 AWECRAFT_FOG_PCT=83
  AWECRAFT_SIZE=1280,720 AWECRAFT_SNAP_DRAIN=600 [AWECRAFT_NO_FOG=1 for the OFF pair], no
  AWECRAFT_LOGIC. Budget 1200 s/run, file-existence + SNAP FAIL check per run.
- BEFORE renders (pre-edit tree): on300 + on120 (fog ON) done rc=0, body LOADED (phase 4),
  Forward+ llvmpipe line present; frames visually confirmed (near tiers + far-tier haze + wall
  band at 300 m; med/low avg tiers visible at 120 m). off300 + off120 (fog OFF) running next.
- Mystery of the NO_FOG frames RESOLVED with a temporary read-only probe in world.gd
  (_ac0415_probe, added at the _ac0401_push seam, REMOVED before gates): in the NO_FOG
  render run the env state is CONSTANT across all frames: mode=play, fog_on=false,
  env_begin=10.0, env_end=100.0 (the engine defaults — 10/100 in Godot 4.7.1, not 4/100
  as assumed), and the lod_avg material at the snapshot frame carries u_near=10.0
  u_far=100.0 u_air=(0.6308,0.8796,0.9647). So in the fresh fog-off state the annulus
  (view distance > 100 at these altitudes) is entirely DISCARDED by the partition —
  the "gray mid-frame" in the off120 frame is the CLOUD DECK (fog_disabled, drawn in
  every state) over sky, not the annulus. Fog-ON state (probe run 2): the live window
  (100, 332) + fog_on=true (to be confirmed in the log). Consequences for the A/B:
  the on-pairs must be near-identical (manual (d-100)/232 vs engine ramp, same window
  and colour — the engine curve is the open question the A/B settles empirically);
  the off-pairs must be near-identical for a different reason (annulus discarded at
  the stale 100 wall in BOTH builds — the partition wall is env-fed and unchanged by
  this fix; the user's actual runtime-toggle state, stale 332 wall, is not
  reproducible headless and is the case the fix actually serves: fog off -> the
  annulus shows true vertex colours up to the wall instead of the manual u_air wash).
- Determinism control: on120 re-rendered with identical env differs 1.16% of px
  (0.95% at d>=8, mean 48.5) — run-to-run noise floor (fluid/animation phase); the
  fog on/off delta (22.3%, 18.7% d>=8) far exceeds it. A/B threshold: treat <=~1-2%
  differing px as "no visible change".
- EDIT APPLIED (the prepped three-part change):
  (1) godot/core/lod_avg.gdshader rewritten: render_mode fog_disabled GONE (the
      material now rides the engine env fog, the standard spatial path); uniforms
      cut 6 -> 2 (day + u_fog_far); the manual ramp (u_air/u_fog_near, fog_f, haz,
      ALBEDO mix) and the dead u_render_edge/u_center deleted; the AC-0283 P3 lit
      floor, the hash/jit breakup, the AC-0401 partition discard (d >= u_fog_far)
      and ALPHA=1.0 kept; header history compressed with an AC-0415 note (the full
      r8/AC-0399/AC-0400/AC-0404 history lives in those results pages).
  (2) godot/ARCHITECTURE.md synced: AC-0338 bullet — the stale "HAZE BRIDGE"
      sentence replaced with a superseded-by-AC-0415 note (the AC-0401 partition
      sentence kept intact); §3 WorldEnvironment bullet — AC-0415 note added
      (single source, seam preserved by construction, partition stays).
  (3) world.gd probe REMOVED — git diff confirms world.gd byte-identical to HEAD.
- FOG-ON probe measurement (before the edit, same dirty tree): env fog_on=true,
  env_begin=100.0, env_end=332.0, lod_avg material u_near=100.0 u_far=332.0
  u_air=(0.6308,0.8796,0.9647) at the snapshot frame — the live window the manual
  ramp ran on; the engine ramp in the same window is what the A/B on-pairs test.
- LIGHT GATES (post-edit, all green):
  G0 headless: rc=0, SCRIPT ERROR 0, SHADER ERROR 0 (census ok).
  SMOKE battery player;interact;light;fluids;genhash: rc=0, battery ok=true,
  census ok, 25 GENHASH lines.
  PROBE meshprobe: rc=0, ok=true, match_rate 1.0, 0 mismatches.
  shaderforce (Forward+ llvmpipe): 12/12 shaders ok, failed=[];
  lod_avg.gdshader declared=2 params=2 verdict=ok (the expected 2/2).
  genhash A/B against my own edit (stash push/pop of my 2 files, same dirty tree):
  PRE==POST byte-identical (25/25) — the edit changes nothing on the generation
  path; the drift vs the AC-0367 pristine reference (25/25 lines differ) is
  PRE-EXISTING on this dirty tree (the 4 fenced WIP files), not owed to this
  ticket. world/* untouched by the final diff, so G2's byte-identical rule does
  not apply to my change; the pre/post pair is the proof owed.
- FOG MECHANISM RESOLVED (the definitive ground truth, source + probe + A/B):
  Godot 4.7 Forward+ env fog (FOG_MODE_DEPTH) is computed PER FRAGMENT in
  scene_forward_clustered.glsl fog_process():
      fog_amount = pow(smoothstep(fog_depth_begin, fog_depth_end,
                                   length(view_position)),
                       fog_depth_curve) * fog_density
  - METRIC: length(view_position) = slant range (identical to the manual
    ramp's length(CAMERA_POSITION_WORLD - v_world_pos)). NOT view-space z.
  - CURVE: smoothstep (curve exponent 1.0 default), i.e. t^2(3-2t) on
    t = (d - begin)/(end - begin) - NOT linear.
  - DENSITY: the Environment resource default is 0.01 (docs), but
    Environment::set_fog_mode() AUTO-SETS fog_density = 1.0 for every mode
    except FOG_MODE_EXPONENTIAL (environment.cpp) - main.gd's
    env.fog_mode = FOG_MODE_DEPTH push therefore carries density 1.0.
    Probe v2 (AFTER tree, f=1..642): fog_mode=1 (FOG_MODE_DEPTH - the 4.7
    enum is {EXPONENTIAL=0, DEPTH=1}), fog_density=1.0, fog_curve=1.0,
    env (100, 332), color (0.6308, 0.8796, 0.9647) - identical state to the
    BEFORE probe run.
  CONSEQUENCE (measured A/B, same dirty tree, same recipes):
  - BEFORE manual ramp = clamp((d-100)/232, 0, 1) - LINEAR over [100,332].
  - AFTER engine ramp = smoothstep over the same [100,332] slant window.
  - The two agree ONLY at the endpoints (d=100 -> 0, d=332 -> 1): the wall
    band and the body rim are byte-stable (wall strip max delta 0-1; at 120 m
    the wall row differs only in the mid-frame by d<=19 - the mid-annulus
    shift, not the seam).
  - In between: smoothstep < linear for d < 216 (near annulus LESS hazy in
    AFTER) and smoothstep > linear for d > 216 (far annulus MORE hazy, up to
    +7-9% haze weight near the wall). The 120 m A/B is the visible
    consequence: 15.3% px differ, mean delta 32.8, max 121, 77% of them
    less-hazy / 23% more-hazy, concentrated in the annulus region
    (y 420-720); body, sky, cloud deck, band A and the wall seam are
    unchanged (the row-band diff is 0.00% for y < 360 and the diff map shows
    the change tracing the annulus silhouette only).
  - 300 m A/B: 0.81% px differ (within the 1.16% run-to-run noise floor;
    the annulus is barely drawn there - view distance starts ~327 m at the
    wall) - no visible change at the user's verified altitude class.
  - BONUS: in the BEFORE build the band A / annulus boundary already carried
    a small haze-weight step (band A = engine smoothstep vs annulus = manual
    linear, differing by up to ~9% of haze weight at mid window). After the
    change both sides take the SAME per-pixel factor - the boundary is
    continuous by construction at every view distance, not only at the
    window edges (r8's "same factor as band A" comment was true in intent,
    approximate in fact).
  - k-ratio curve discrimination via per-pixel (before-air)/(after-air)
    norms is INVALID here: the before-vs-before-control pair shows the same
    k spread (median 1.95, 91% outside 0.9-1.1) from run-to-run surface
    noise (water shimmer / lit) alone; the collinearity test (92.6% of
    differing pixels on the same air line) still proves same-surface +
    same-air + different-factor, and the source+probe fix the curve.
- off300 A/B (NO_FOG both builds): 0 px differ - the PNGs are
  BYTE-IDENTICAL. As predicted: at 300 m the annulus view distance starts
  ~205 m > the fresh-NO_FOG partition wall (100) in BOTH builds, so the
  annulus draws nothing; fog disabled in both; every other pixel matches.
- CLOSEOUT STATE (subagent done, coordinator to verify/close):
  Final tree: godot/core/lod_avg.gdshader (rewritten: 139 -> 81 lines, the
  duplicate fog deleted, engine env fog is the standard path, AC-0401
  partition + hash/jit/lit kept, uniforms = day + u_fog_far) +
  godot/ARCHITECTURE.md (two regions synced incl. the measured
  smoothstep-vs-linear finding). world.gd byte-identical to HEAD (probes
  out). Fenced files untouched (M = the other session's WIP). No commits,
  no TASKS.yaml mutation (coordinator's).
  Deliverables: tasks/AC-0415/plan.html, continuity.md (this journal),
  AC-0415-results.html (self-contained: verdict table, engine-ramp
  measurement, A/B table + 8 frames + diff map, gates with rc, files
  changed, deliberately-not-done, deviations) + 9 captures copied in.
  A/B SUMMARY: on300 0.81% (noise floor, wall strip max delta 0);
  on120 15.3% (mid-annulus smoothstep-vs-linear haze-weight shift, mean
  delta 33, wall row stable within mid-annulus bleed); off300
  BYTE-IDENTICAL; off120 noise floor (13 px d>=8).
  Gates: G0 rc=0 0/0 errors; SMOKE battery ok=true rc=0; PROBE
  meshprobe ok match_rate 1.0; shaderforce 12/12 ok (lod_avg 2/2);
  genhash: pre/post-my-edit byte-identical (stash A/B), 25/25 drift vs
  AC-0367 reference is PRE-EXISTING on the dirty tree (fenced WIP files),
  reported not re-baselined.
  Owed to the coordinator: (a) commit the shader + ARCHITECTURE.md + the
  4 dead main.gd pushes (1474-1476, 1478-1479) in one commit when the
  fence lifts; (b) the genhash reference re-baseline belongs to the WIP
  session's closeout; (c) heavy gates (boundary/perf, full battery,
  Windows build) per ticket; (d) the smoothstep curve finding is
  report-level - if the old linear feel is wanted exactly, that is a
  settings-level follow-up (fog_depth_curve is exposed), single-source
  stays.
