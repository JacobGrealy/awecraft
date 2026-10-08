## RUN - 2026-10-08 12:18 EDT - AC-0407

- plan: read shader/world.gd/harness/ops/prior-results; design chosen (vertical profile + thicken + glow + ms2 + air lift)
- implement: shader vprof2 (flat base / lumpy tops, top=mix(0.45,0.98,lump)), glow (0.30/pow6), ms2 0.18->0.24, air_lift 0.10; world.gd AC0407_VOL_TOP_EXTEND=50 (u_vol_rmax R+450); ARCHITECTURE.md synced

### Milestone — top driver redesign (topf) + re-render
- First field-sampling pass (pure-stdlib reimplementation, 64k column
  directions) showed the lump-driven top (0.55*base+0.45*mid, remapped
  linearly) gives only a **13 m p10-p90 skyline**: the coverage window
  pins base to ~[0.46, 0.56] for cloudy columns, so the top is pinned
  to ~400 m. No variance — the user's complaint would have survived.
- Root cause: the top must be driven by a field INDEPENDENT of the
  coverage window (which sits on base's octaves).
- Fix: topf = anv(q * (sc3 * 0.5) + (5.3, 11.7, 8.1)) — 1 octave at
  HALF the base frequency (a ~512 m-scale updraft field, uncorrelated
  with the window). top = mix(0.45, 0.98, smoothstep(0.35, 0.65,
  topf)). Measured over the field: cloudy-column tops now span
  **353.8–446.5 m, p10-p90 = 92.7 m, p50 = 400.5** (was 0).
- The coarse light-march path takes the SAME topf (otherwise the light
  march would exit at the flat gate and over-shadow every top shorter
  than the gate — phantom cloud above a short column's top).
- Cost: +1 anv in vdens, +1 in vdens_coarse; u_vol_lsteps 6→5
  (400 m reach still clears the 175 m layer) to offset the added
  light-march taps. Net 13→19 noise anv per view step.
- First render batch (bash-614) killed after 2 frames — it predated
  this change. Final batch: bash-615 (all six frames, final shader).

### Milestone — final batch measured + gates green + results written
- Final render batch (bash-615) complete, all six frames rc=0, Forward+
  asserted, SHADER/SCRIPT ERROR 0 each, SNAP files present:
  r700-on 829 s / r2600-on 823 s / r300-on 976 s / r120-on 831 s
  (pre-change walls 776/810/880/792; r300 pays most — longest chord) /
  r700-off 491 s / r300-off 481 s. All inside the 1200 s cap.
- Measurements (before = tasks/AC-0406 frames, same recipe; masks vs
  clouds-OFF twins, DSSTATS overlay region excluded):
  - top-altitude spread: 0 m -> 92.7 m p10-p90 (tops 353.8-446.5,
    p50 400.5; field-sampled, 18,031 cloudy columns / 64,440 dirs)
  - sunlit-top reference (r700 deck mask): lum mean 139.5 -> 142.3,
    p90 178.4 -> 183.6, max 241.6 both (tops clamp); coverage 8.35%
    -> 7.56% (the lumpy thin tops fall under the diff-8 threshold)
  - underside r120 (y 80-290): mean 185.7 -> 187.3, p10 149.5 -> 155.3
    (dark cores lift), p90 228.1 -> 227.9 (lit side holds)
  - interior r300 (y 215-360): mean 184.7 -> 190.3, p10 142.2 -> 150.7,
    std 34.4 -> 32.3 (brighter AND lower-contrast), min 126.2 -> 129.9
  - inside-annulus mask (r300): coverage 18.1% -> 17.2%, mask lum mean
    165.6 -> 170.5 (p10 +5.8), std 21.1 -> 20.3, RGB (124,175,189) ->
    (132,180,192)
  - spread (r700 lower_mid lum_std): 44.9 -> 44.0 (floor 40.2, rejected
    line 39.1, reference 32.4 — survives)
  - tint (r700 px_center): (181,229,190) -> identical
- G0 on the final tree: GODOT_EXIT=0, census SCRIPT 0 / SHADER 0 ok.
- Boundary r4 A/B (two runs): ok/remesh_ok/marker_ok true both; p50
  13/14, p95 34/32, max_ms 205/185 (below the 357-824 noisy band),
  crossing_frame p95 39/53 (<=75), crossing_burst p50 4.1/4.2 (<=10),
  built_final 66/67, resident_final 103/93, in_radius_built_final
  61/62, col_deferred_in_footprint 0/0, footprint.missing 0/0,
  staged_pending_final 0/0, storm_walk_p99 87/92 (<=200). FINDING:
  staged_dropped 2663/2568 marginally above the <=2500 threshold —
  the collision-staging lane (untouched by this change class; genhash
  identical, all fence fields clean; drain 477/453, pending 0 = not
  stalled). The row's own September readings already drifted
  (999/1845/1667). Reported, not re-based — coordinator to confirm.
- Results page: tasks/AC-0407/AC-0407-results.html (self-contained,
  six captures in the ticket folder). DONE — exit after light gates;
  the heavy set (rest of the standing set, full battery, flake, r50,
  Windows) is the coordinator's.
