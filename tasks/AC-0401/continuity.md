# AC-0401 continuity journal

## RUN - Wed Oct  7 10:12:01 EDT 2026 - AC-0401

- Fresh run (no prior continuity). Spec generated with `spec_template.py AC-0401`.
- Reading the READ-FIRST set (TASKS.yaml notes, CONTINUITY top, ARCHITECTURE,
  spec, AC-0384 §25, HARNESS, OPS) before planning.
- Plan written (plan.html). Core mechanism found: the body owns the fog-wall rule
  (d >= fog_far), the near tiers violate it — they keep drawing past the wall as a
  100% fog-colour patch over the body's terrain (the 1600/2600 m diamond). The fix =
  strict partition (near-field discard at d >= u_fog_far) + 2 m radial inset of the
  body (radius ordering) + sky limb-glow gate on u_space + cloud re-characterization
  behind a u_deck switch. Two new settings (cloud_deck, limb_space, both default ON).
- IMPL DONE: satellite_body.gdshader (+2 m vertex inset), lod_avg.gdshader
  (d >= u_fog_far discard), chunk_lit_{opaque,cutout,flower,fluid}.gdshader
  (+u_fog_far + discard), fluid_anim{,_bf}.gdshader (same, via u_cam_pos),
  aero_sky_gradient.gdshader (u_limb_gate gate on u_space), cloud_layer.gdshader
  (u_deck switch: 1/3 field frequency, window 0.46-0.56, band floor 0.60, softer
  edges, puff + deep-core shading; u_deck<0.5 = exact r9 constants), world.gd
  (_ac0401_push: change-gated u_fog_far to the shared materials + per-frame
  u_deck/u_limb_gate to the Main-owned cloud/sky materials; AWECRAFT_CLOUDDECK /
  AWECRAFT_LIMB env preloads), settings.gd (2 bools, sanitize_bool, default ON),
  menu.gd (2 rows + handlers), ARCHITECTURE.md (tree + §2 row + §3 AC-0338 bullet
  + new §4 AC-0401 bullet).
- GATES: G0 0/0 (rc 0, Forward+ n/a headless). shaderforce 12/12 ok + 0/0 census.
  SMOKE player;interact;light;fluids;genhash ok:true + 0/0; GENHASH 25/25
  byte-identical to the AC-0400-era set (.scratch/AC-0400-gates/smoke-genhash.log)
  — generation untouched. (The AC-0367-era .scratch reference set is stale from an
  older .so era — NOT the standing reference; the AC-0400 set is.)
- FINDING (pre-existing, fixed in-task): the SATDIAG cloud dump
  (satellite_body.gd _satdiag_clouds, whole-tree walk) did float(null) when the
  shaderforce probe's pbox wore the cloud shader with no parameters set (first
  diag tick inside the probe's 12-frame window) — a SCRIPT ERROR that failed the
  census on the very run the probe measures (intermittent; bake-time dependent).
  Hardened: cov = -1.0 for non-float values. Second shaderforce run: 0/0.
- BOUNDARY r4 one-shot: ok/marker_ok/remesh_ok true, p50 13 / p95 34 / max 164,
  built_final 68, staged_dropped 2303 (<=2500), flap 84 — field-identical to the
  AC-0399 pre-change run (flap 144 there; 84-225 across the recent gate history,
  the "flap 0" HARNESS row is the stale AC-0359-era reading). No streaming
  regression (expected: render-path only, headless never runs the shaders).
- RENDERS: the 8-render ladder launched in the background (job bash-567):
  after-descent-2600/1600, after-700, after-700-clouds-off, after-300, after-120,
  deckoff-2600, deckoff-700 — the AC-0384 §25.7 recipe, R24/F83, T0.5 frozen,
  CLOUD_T0=411200, planet preset, 1200-frame drain each (~40 min total).
  Logs in .scratch/ac0401-runs/; PNGs to tasks/AC-0401/. Next: analyze the frames
  (patch gone? rim gated? deck character? deck-off A/B vs before frames?), then
  AC-0401-results.html + report.
  (Job bash-567's first attempt raced through all 8 with rc=127 — an empty-string
  third arg reached `env`; fixed the capture script, relaunched as job bash-568,
  which completed 8/8 rc=0 at 13:55.)
- LADDER RESULT — all four items verified on the settled final frames (the
  _s600 mid-drain companions kept for the drain curve):
  * 2600 m: the disc is the body's baked terrain — the Manhattan fog-colour
    diamond (the chunk render-footprint at 100% engine fog, drawn over the body)
    is gone (nadir box: bright-white 54.9% → 0.0%, sat 17.0 → 77.0); the limb
    rim glow present (S=1.0); the deck is few large soft masses.
  * 1600 m: same at S=0.921 — rim arc at the limb, terrain+water disc, no patch
    (nadir box lum 214.4 → 199.9, sat 11.1 → 19.1).
  * 700 m: the dark terrain-horizon band and the diamond are gone; at 700 m every
    chunk fragment is ≥ 700 m from the camera (past the 332 m wall) so the frame
    is the body's own surface (2 m baked colour / 16 m displacement) + deck — the
    high detail is hidden above the wall (item 4). S=0.132 → the rim is 13%,
    visually gone.
  * 300 m: NO rim (S=0) — the pre-AC-0401 UNGATED horizon glow band is gone;
    crisp terrain to the wall (the nadir ground at 300 m is inside the 332 m
    wall), hazy 332–400 m band at the horizon, clean sky.
  * 120 m: the dense fine-structure membrane (the user's "too many clouds") is
    now few large soft volumetric masses with the sky visible between them.
    No window re-tune was needed (the one allowed r8b-style iteration unused).
  * 700 clouds-off pair: the partition stands alone (crisp terrain to the wall,
    no diamond, no dark band) — the z-fight fix is in the layer construction.
  * Deck-OFF A/B (2600/700): u_deck=0 reproduces the old r9 character — at 2600
    the bright/low-sat wash matches the before frame to within noise (66.9% =
    66.9%; 210,163 vs 210,056 cloud px) = the bit-identical OFF path; the
    deck-ON settled frame is 11.1% (discrete masses). The deck-OFF frames
    differ from before only in the terrain region = the partition (documented).
- MECHANISM VERIFIED (read the body shader + all discard sites): u_fog_far =
  332.0 is a PER-FRAGMENT VIEW DISTANCE; the body's op = smoothstep(332,400,d)
  and the near-field discard d ≥ 332 are the same window (the body's haz_d
  carries the single-source u_air seam in the 332–400 m band, AC-0400 preserved).
  At the nadir view distance ≈ altitude, so the "certain height" ≈ the fog wall:
  120/300 m show high detail, 700/1600/2600 m show the body only — never both
  layers, never neither. The cloud shader carries NO fog discard (the shells
  stay a visible overlay — verified by grep of all five discard sites).
- AC-0401-results.html WRITTEN (per-item verdicts, switch table, the
  "was the shader shared" answer, separation + threshold, gates, the SATDIAG
  finding, deviations, the 8-frame ladder with before/after pairs + measurements,
  deliberate non-actions). Task complete — report delivered; coordinator runs the
  heavy gates (farab, ladder, meshprobe, halo, lightstate, r16, boundary r50,
  full battery, Windows build) before closeout.
