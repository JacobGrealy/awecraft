## RUN - 2026-10-12 03:41 - AC-0421

- Subagent start. Reading spec (TASKS.yaml AC-0421), CONTINUITY top checkpoint, ARCHITECTURE, AC-0401/0405/0406/0407/0411 results, HARNESS (2/4/5), OPS.
- Four defects from the user's two orbital screenshots: (1) satellite body reads reflective/glossy (find + remove the sheen term), (2) cloud z-fighting/flicker on the near face in orbit (same family as the AC-0401 near-tier/body radial ordering; must not reintroduce it), (3) flat satellite view -> height-based shading of the sampled colour (the user's own fix direction; behind a switch, conservative default; measure relief before/after), (4) held item renders in orbit (a prior triage closed it as a stale SIZE complaint - the screenshot is the authority: the defect is that it renders AT ALL at that altitude).
- Environment verified: engine ~/tools/godot/godot present, godot/bin/libchunkio.so present, no live godot process (pgrep clean).

## RESUME - 2026-10-12 - AC-0421 (verification + completion run)

- The first run died after its code edits, before any gate/render/results page.
- Verified the five diffs file by file (see the results page): defects 1 (u_spec,
  shipped 0.0), 3 (u_relief, default-ON switch, ±20 % centred on mid height,
  alpha = H/HMAX height channel), 4 (player.gd _vm_orbit_sync at/above
  Aero.atmosphere_height + harness AWECRAFT_FPV_ITEM instrument) all COMPLETE
  and correct. Defect 2 (cloud-vs-body ordering) was NOT STARTED (no
  cloud_layer.gdshader / world.gd change), and the plan's menu.gd row +
  HARNESS.md env docs were missing — both completed this run.
- Defect 2 mechanism, measured (this build, .scratch/AC-0421/tie matrix):
  cloud shell nodes and body face nodes are ALL at the planet centre, so the
  transparent sort (key = camera-to-node distance + sorting_offset; LARGER
  key draws LATER — verified 4-case) is a perfect tie and the tie-break put a
  body face AFTER the cloud -> the op~1 body covers the near-face cloud
  (hidden/flickering as cull/rebuild state moves the tie; limb survives).
  render_priority does NOT exist in 4.7.1; sorting_offset does.
- Fix (world.gd, one-time push in _ac0401_push): sorting_offset +2.0 on each
  cloud shell node (the AC-0401 2 m idiom on the sort key) — cloud sorts
  deterministically after every body face at every altitude. Depth untouched
  (no thin-veil holes; the AC-0401 near-tier ordering is opaque-pass and
  unchanged).
- Gates (this run): smoke battery player;interact;light;fluids;genhash
  rc=0, 0 SCRIPT/SHADER ERROR, ok=true; genhash 25/25 identical to the
  AC-0419-r2/AC-0422 reference set (the AC-0367 log is an old rebase);
  shaderforce; BEFORE render (all four defects, A/B envs) captured pre-fix
  (07:49:17, 31 s before the world.gd fix — mtime-verified true before).
- Renders: R24/F83, T0.5, CLOUD_T0=411200, SAT_ALT=2600, nadir, drain 60
  (the AC-0417 R24 note), 1200 s wall, file-existence checked.

## CLOSE - 2026-10-12 - AC-0421 (complete)

- BUG FOUND in the prior run's player.gd: _vm_orbit_sync's change-gate was
  inverted (visible==orbit) — a no-op in every state; defect 4 was dead
  code. Proven by the vmorbit probe (281 orbit frames, zero state changes,
  ok:false), corrected (want_visible = not orbit), re-probed ok:true
  (surface visible / orbit 2600 m hidden / descent 200 m restored).
- AWECRAFT_CLOUDS verified live (aero.clouds_on, main._place_clouds);
  the prior run's "clouds-off" scratch frame was actually deck mode (three
  shells vis=true) — kept as pre-fix context only; the true on/off pair is
  after-orbit vs after-orbit-clouds-off (SATDIAG "clouds: none").
- All gates on FINAL code: battery_final rc=0 census 0/0 ok; genhash 25/25;
  vmorbit4 ok:true (probe arm removed after — evidence in vmorbit4.log);
  shaderforce2 12/12 ok rc=0 census 0/0 (first attempt without xvfb failed
  on DisplayServer — rerun under the fwdshot recipe).
- Renders final: after-orbit (+steps), after-orbit-clouds-off,
  relief-off-clouds-off (the control pair for the relief measurement).
- Measurements: near-face std 1.07/1.08 (pre-fix, featureless) -> 7.38
  (after, clouds over body) / 1.12 (clouds off); held-item corner
  dark-frac 0.895 -> 0.000; relief control pair 9.0 % pixels differ,
  structured terrain-following (diff_relief_amp12.png), crisp band 20.4 %
  darker 1-4/255, expected pre-haze mean -3.7 % (mean H~156 < mid 192).
- Deliverable: tasks/AC-0421/AC-0421-results.html (+ all captures in the
  ticket folder). Status change is the coordinator's closeout; no commits.
