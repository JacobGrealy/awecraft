## RUN - Fri Oct 16 09:46:22 EDT 2026 - AC-0438

- started: single-subagent run for ticket AC-0438 (chart-seam-line-across-the-planet-disc).
- fresh run: tasks/AC-0438/ did not exist, no prior entries.

## RESULT - FINDING (no effective in-repo fix) - Fri Oct 16 2026

- TRUE LAYER: the line is in the satellite body (12-face chart mesh). Proven by a black-body
  render (ALBEDO=0 -> line gone, row 358 (179,210,95)->(0,0,0)). Not fog/atmosphere/clouds/HUD.
- MECHANISM: a sub-texel rasterization/sampling artifact at the chart's coincident face seam
  (1 px ~ 5.5 m < 1 texel). It is UV-INDEPENDENT: three sample-UV sources (mesh UV attribute,
  fragment-stage chart UV, vertex-stage chart UV with the authoritative per-face index = exact
  inverse of SphereMath.uv_to_world) all render a PIXEL-IDENTICAL disc with the line present in
  all three (seam 357->358: 444 pts>=6, mean 75.5, max 229 - identical to r24; disc stats
  identical (115.9,178.7,149.6)/0.228).
- RULED OUT (each by a decisive A/B on this box): bake content (all 12 faces scanned, zero spike
  rows; seam columns identical, gapless), minification (mipmaps ON -> pixel-identical; imports
  reverted), haze/relief/sun (term-field probes uniform at row 358; line hue not reproducible
  from any texel x day/relief or from a haz mix toward u_air), stale shader cache (.godot
  wipe+import -> byte-identical), two-mesh interaction, UV-attribute corruption as the cause.
- FIX ATTEMPTED + REVERTED: the computed chart-UV sample source (u_uv_mode switch default 1.0,
  authoritative u_face per-material float, vertex-stage inverse) was implemented and proven
  pixel-inert on the line (it cannot fix a UV-independent artifact), then reverted. Shader +
  satellite_body.gd are back at HEAD (no diff). Tree = HEAD + other session's fenced dirty files
  (left as-is) + 5 new untracked .uid files from --import rebuilds (tracked-convention; left for
  the coordinator).
- LIGHT GATES (post-revert tree): G0 clean (0 SCRIPT ERROR + 0 SHADER ERROR, world LOADED;
  genhash arm rc=0 + clean census); genhash 25/25 byte-identical to the AC-0437 reference set
  (GENMS 158; the AC-0367 set in HARNESS is stale); >10 clean Forward+ lavapipe renders; r24
  recipe bit-identical on the clean tree. No shaderforce owed (no shader change remains).
- NEXT (coordinator): confirm on the Windows build whether the artifact is renderer-specific.
  If absent there -> environmental llvmpipe sub-texel caveat (OPS.md) + close. If present ->
  follow-up ticket on the coincident seam geometry (shader-only per-face radial offset, or a
  bake-worker seam-UV nudge that owes a deliberate genhash rebase).
- Evidence: .scratch/AC-0438/ (probe frames + re-takes + logs), .scratch/AC-0438-gates/ (G0 +
  genhash). Docs: tasks/AC-0438/plan.html + AC-0438-results.html.
