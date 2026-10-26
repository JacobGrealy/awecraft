## RUN - Mon Oct 26 06:00:27 EDT 2026 - AC-0438 (round 114, REPAIR plan: (A) geometry and (B) bake content REFUTED by round 113; cause is (C) the sampling path at the chart boundary; four ordered checks: (1) address mode/wrap, (2) UV derivation at face boundary, (3) anisotropy separate from mip chain, (4) atlas layout one vs twelve textures)

### PROGRESS round 114 (in flight)

- Check (4) ANSWERED (static): TWELVE separate 1024x1024 ImageTextures, one per face
  (satellite_body.gd:893/931, gate arm "12 meshes/12 textures 1024x1024"). NOT one atlas.
- Check (2) ANSWERED (static): mesh UV = i/nu exactly [0,1] (satellite_bake_worker.gd:599);
  affine interpolation, last column = exactly 1.0, no overshoot in the attribute.
- Check (1): Godot 4.7.1 exposes NO address-mode/repeat knob for 3D textures in GDScript
  (engine binary: repeat concept exists only for 2D/canvas_item; no RepeatMode enum, no
  ImageTexture.repeat member — verified by introspection + pixel attempts). Static reading
  says clamp-to-edge is the only 3D mode — being PROVEN pixel-level by an in-game
  diagnostic render (below) per the plan's ordered check.
- Standalone 3D probe DEAD END on this box: a minimal .tscn probe renders 2D (ColorRect
  visible) but 3D never draws (clear colour only) under forward+ AND gl_compatibility,
  with env/light/current-camera/100 s warmup; the real game renders 3D fine. Same capture
  path (root.get_texture()) as Debug.snap. Abandoned the standalone probe; all evidence
  now comes from the game-context render + offline math on the existing frame.
- NEW FORENSICS on rem2-baseline-day.png (offline, free): decoded screen pixels to
  (face,u,v) via the harness camera (spawn [8.5,141,8.5], R=4000, alt 2600, fov 75, nadir,
  up hint = pl_hd = (0,0,1)x(pl_a) per harness.gd:1456-1537; sphere_math prewarp
  tan(c*PI/4)). Results: the line row (358) lies ENTIRELY on face 1's final texel-column
  band (u in [0.99906, 0.99982] -> texel pos [1023.0, 1023.8], v sweeping 0.21..1.0 along
  the line); the boundary (x=0 great circle) falls between rows 358 and 359; row 359 =
  face 0 pos ~0.7 (safe interior). At x=640 (v~0.5008, j512) all of rows 354-357 and
  359-363 sample the seam columns = dark grass (55,104,34) and all render (41,157,0)
  (dark, consistent); ONLY the line row renders (179,210,95). Along the line the rendered
  colour VARIES with x (cyan 188,242,238 / white 247,255,241 / pale 209,229,168 / dark
  38,155,0 / blue 108,219,255) while the decoded texel neighbourhood is uniform dark grass
  at most positions (x640: face1 cols 1016-1023 all (55,104,34); the bright bands are 2-10
  texels INSIDE at cols 1005-1015). The line-row colours match NO local texel and some
  resemble distant content (water (35,76,165), bright (246,251,251)) — the signature of
  the boundary band blending the edge column with the OPPOSITE edge (wrap), whose content
  varies along v and explains the per-x colour variety. (Caveat: the offline colour
  pipeline round-trip on this box is not exactly modelled, so the per-pixel colour match
  is corroborating, not by itself decisive; the pixel-level render below is decisive.)
- DIAGNOSTIC RENDER (rem2-diag-addr, launched): satellite_body.gdshader carries a temporary
  discard block: d_k = |tex(1.5, y_k).r - tex(0.5, y_k).r| for y_k = 256.5/512.5/768.5
  texel-centres; discard if all three < 0.01. Under REPEAT the u=1.5 sample wraps to
  u=0.5 and is IDENTICAL to the centre reference on every face -> ALL fragments discarded
  -> disc vanishes. Under CLAMP u=1.5 lands on the last column; offline-verified all 12
  faces have max d >= 0.022 > 0.01 (range 0.022..0.871) -> NO fragment discarded -> the
  disc renders normally and the seam is re-measured in the same frame (sanity: should
  match baseline n=415 mean_abs 45.0 max 212).
- Pending on the render: (wrap -> fix = shader UV shrink UV *= 1023.0/1024.0 so no sample
  crosses the boundary; verify render + seam before/after) or (clamp -> revert, then
  aniso-off A/B render as check (3); if the line survives that too -> PLAN-INSUFFICIENT
  with the full ruled-out list + this forensics).

### RESULT round 114 (render rem2-diag-addr landed; CHECK (1) = CAUSE)

- CHECK (1) ANSWERED PIXEL-LEVEL: the 3D sampler in this build REPEATS (wrap), it is
  NOT clamp-to-edge. rem2-diag-addr render (0 SCRIPT/SHADER ERROR, same recipe/timing
  as baseline, satellite LOADED 12/12, snapshot at the same t~391-400): the ENTIRE disc
  was discarded (frame = uniform (0,34,56) = the space-sky; space_color (0.0078,
  0.0118, 0.0392) display-encoded with u_space=1.0 matches (0,34,56)) - the discard
  predicate fired on every fragment of every face, i.e. the u=1.5 probe returned the
  u=0.5 centre content on all 3 texel-centre rows for all 12 faces. That identity holds
  under wrap (1.5 mod 1 = 0.5, same texels) and is impossible under clamp (offline
  margins 0.022..0.871 > 0.01 on every face). Texture-missing is ruled out: the
  baseline render (same day, same src=res via=import path, 12/12) shows fully textured
  terrain. The static reading ("4.7.1 has no 3D repeat knob, so 3D must clamp") was
  WRONG for this pipeline: no knob exists, but the effective mode is REPEAT.
- CAUSE: with repeat addressing, the last half-texel band of every face edge (sample
  pos in [1023.5, 1024)) blends the edge column with the opposite edge's column
  (1024.5 wraps to 0.5) - a colour no texel has - the 1 px seam line (filing rows
  357/358: n=415, mean_abs 45.0, max 212, line (179,210,95)@(640,358)). This also
  explains the forensics: the line row sits exactly on face 1's final texel column
  band; its per-x colour variety tracks the opposite-edge content along v; the line is
  texture-dependent (flat probe), mip-independent (a level-0 addressing issue), and in
  both bakes (same sampler).
- FIX (applied, in the named file godot/core/satellite_body.gdshader, sample site):
  UV remap UVs = UV * (1023.0/1024.0) on BOTH axes so no bilinear footprint (p +/- 0.5
  texels) ever crosses a texture edge and the wrap path is never read; the address mode
  itself is not settable in 4.7.1 (repeat is a 2D/canvas_item-only concept in this
  build - no Texture2D/ImageTexture repeat API, no 3D RepeatMode enum). Cost: a 0.098%
  sub-texel content shift at each edge; the seam columns are still sampled (from pos
  <= 1023.0). No re-bake (sample-time fix, no asset change -> no genhash rebase owed).
- VERIFICATION RENDER (rem2-fixed-day, same recipe, 0 SCRIPT/SHADER ERROR): the remap
  MOVED the measured step but did NOT fix it: 357->358 n=276 (was 415), mean_abs 51.5
  (was 45.0), max 212 (same), mean_signed +40.3 (was +28.3); the line signature colour
  persists ((179,210,95)@(640,358) -> (181,211,98); the per-x variety cyan/white/pale/
  dark/blue at x300/400/500/600/700/900 survives, some shifted a few units). Reading:
  the wrap reads in the last half-texel band are NOT the line's mechanism - eliminating
  every out-of-bounds bilinear footprint left the line. Per the plan's revert rule the
  UV remap was REVERTED (shader back to HEAD, git diff empty) - it is not a fix and
  would corrupt the before/after baseline.
- WRAP FINDING STANDS AS A FACT BUT IS NOT THE CAUSE: the sampler demonstrably repeats
  (diag render) yet the line is independent of the wrap reads in the edge band. The
  line's mechanism still reads non-local texture content (the per-x colour variety +
  "colour in no texel" forensics hold on the fixed frame too). Remaining ordered check:
  (3) ANISOTROPY, tested separately from the mip chain as the plan requires (mips-off
  round 113 changed the census only mildly: n 415->356, max 212->119 - the line
  survived a chainless texture, so the chain alone is not it; the aniso component of
  the filter is the untested half).
- ANISO A/B RENDER (rem2-aniso-off, launched): ONLY change = the filter hint
  `filter_linear_mipmap_anisotropic` -> `filter_linear_mipmap` (line 99 block, mips ON).
  Baseline for the A/B = rem2-baseline-day (aniso ON): 357->358 n=415 mean_abs 45.0
  max 212. If the line SURVIVES aniso-off too: all four (C) checks are answered
  (wrap proven but line-independent; UV exact; aniso line-independent; twelve
  separate textures) -> the run returns PLAN-INSUFFICIENT with the full ruled-out
  list + forensics, and every temporary change is reverted (shader at HEAD).

### FINAL round 114 - PLAN-INSUFFICIENT (all four (C) checks answered; line survives all)

- rem2-aniso-off landed (0 SCRIPT/SHADER ERROR, same recipe, satellite LOADED 12/12):
  357->358 n=434 (was 415), mean_abs 44.6 (was 45.0), max 211 (was 212), mean_signed
  +26.8; 358->359 n=429 mean_abs 44.3; line px (187,213,102)@(640,358) with the same
  per-x variety (cyan/white/pale/dark/blue at x300/400/500/600/700/900). ANISOTROPY IS
  LINE-INDEPENDENT. The hint was REVERTED; godot/ git diff vs HEAD = empty.
- CHECKS SUMMARY: (1) wrap proven pixel-level (rem2-diag-addr) but line-independent
  (the UV-remap fix moved n 415->276 without removing the line - REVERTED per the
  plan's revert rule); (2) UV reaches exactly 1.0, no overshoot (static); (3) aniso
  line-independent (rem2-aniso-off); (4) TWELVE separate textures (static + gate arm).
  No fix was kept; the mechanism remains open.
- GATES (final tree = HEAD; gate_run.py AC-0438 --arms g0,genhash,satellite --rev 2):
  g0 rc=0 (0 script + 0 shader errors); genhash rc=0 25/25, census byte-identical to
  rev 1 (no rebase owed, no bake/asset touched); satellite rc=0 src=res via=import,
  textures 12/12 1024x1024, height_decode 12/12 (diff_px=0, max_byte=0,
  alpha_max_byte_diff=0), guard ok, res_export_ok, tex_shape_ok.
- CLEANUP: temp probe scene godot/probe_min.tscn/.gd + orphan .uid deleted; all temp
  shader edits reverted; AC-0438-results.html rewritten for round 114; deviations
  extended R114-1..R114-10. No git add/commit/push; no TASKS.yaml; no new tickets;
  other sessions' dirty files untouched.
- SUGGESTED NEXT PLAN (full reasoning in the results page): the line is
  boundary-row-confined and reads non-local texture content while being
  wrap/aniso/mip/UV-source independent - remaining suspects: (i) rasterizer
  derivative/LOD blow-up at the coincident boundary (the boundary row's footprint may
  be estimated far larger than the true ~1.9 texels/px), (ii) coincident-geometry
  rasterization mixing BOTH faces' coverage in the boundary row (round 113's
  UV-source swap kept the geometry coincident, so it could not test this). Cheapest
  decisive probe: shader-only per-face radial offset VERTEX -= normalize(VERTEX) *
  (2.0 + 0.05*FACE) (no re-bake, no genhash rebase) + measure; if the line dies,
  coincident-geometry interaction is the cause. Also: one Windows check - if the line
  is absent in the shipped forward_plus build, close with an OPS.md lavapipe caveat.

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

## RUN - Mon Oct 26 05:46:06 UTC 2026 - AC-0438 (round 113, rewritten plan: re-measure post-AC-0469D/AC-0478 rebuild, then pick (A) shader radial offset vs (B) bake-worker UV nudge with evidence)
- GATE (a) RE-MEASURED on the current tree (post-AC-0469D/AC-0478 rebuild): seam PRESENT.
  Filing method (.scratch/AC-0438/rem2/measure_seam.py, rem2-baseline-day.png, recipe = cap_baseline.sh:
  AWECRAFT_SIZE=1280,720 AWECRAFT_RADIUS=24 AWECRAFT_FOG_PCT=83 AWECRAFT_SEED=44 AWECRAFT_TIME_FREEZE=1
  AWECRAFT_CLOUD_T0=411200 AWECRAFT_TIME=0.5 AWECRAFT_CAM=planet AWECRAFT_SAT_ALT=2600 AWECRAFT_CAM_NADIR=1
  AWECRAFT_SNAP_DRAIN=600): BEST rows 357->358: n=415, mean_signed=+28.3, mean_abs=45.0, max=212,
  hardx=238..1043; the 1-px bright line sits at row 358 (colour (179,210,95) at x=640, neighbours
  (41,157,0)); row 358->359: n=388, mean_signed=-28.8, mean_abs=46.0, max=123 (the darkening side).
  Row index matches the filing (357-358); disc span this frame 236..1043 (filed 136..1142).
- DISTINGUISHING MEASUREMENTS (each a dedicated render, .scratch/AC-0438/rem2/):
  1. FLAT BODY (shader probe u_flat_probe: texv := vec3(0.4) constant, relief/haze/lighting kept,
     AWECRAFT_SAT_FLAT=1 -> rem2-flat-day.png): the line VANISHES - centre column rows 336-385 all
     exactly (236,233,222); row-358 step census n=0/808 (max 2 = dither). Per the plan's own rule a
     step that vanishes on a flat-coloured body is NOT a geometric (A) step: a per-face radial offset
     would persist with the texture bypassed. => (A) ruled out by measurement.
  2. MIP CHAIN OFF (AWECRAFT_SAT_MIP=0, chainless texture -> rem2-nomip-day.png): line UNCHANGED
     (n=399, +29.6, 46.3, max 211 - same class as baseline) => minification chain not involved.
- STATIC FACTS (offline, both new and pre-AC-0478 bakes, .scratch/AC-0438/rem2/ + old_pngs/):
  - Seam boundary columns f00[i=0] and f01[i=1023] are BYTE-IDENTICAL in BOTH bakes.
  - The line colour (179,210,95) exists NOWHERE in either home-pair PNG (tolerance-6 scan); max R in
    all 12 face PNGs is 250 (< 255), so the line is not any texel (not even a bright far-edge texel).
  - The line is present in BOTH the old and the new bake => the rebuilds neither introduced nor
    removed it; the boundary content they rewrote was already continuous and still is.
- PROBE-2 UV DUMP (u_probe2: ALBEDO := vec3(UV.x, UV.y, texs.r), unshaded -> rem2-probe2-day.png,
  valid run, nadir=true, 0 errors): the decoded per-fragment field is INTERNALLY INCONSISTENT - the
  sampled-texel channel (B) fails to match the face PNG at the decoded (i,j) for 479/500 interior
  face0 pixels (bilinear 2x2 tolerance); some B values equal 255 (a texel R=1.0 that exists in no
  face PNG); the decoded brightness structure is offset ~1 screen row and compressed (~30-texel
  bright bands in the PNG map to the 1-px line). => the exact per-fragment UV->texel mapping at the
  line row is UNRESOLVED. The prior run's "UV-independent" finding (three UV sample sources rendered
  a pixel-identical disc with the line present in all three) remains the best-supported
  characterisation: the line does not follow the UV source.
- PLAN CONTRADICTION (why this run exits PLAN-INSUFFICIENT): the plan's decision rule
  ("vanishes on a flat-coloured body -> (B)") nominally points at (B), but the plan's (B) definition
  ("adjacent charts sampling texels that DISAGREE at the boundary" - a baked-content mismatch) is
  refuted by the byte-identical boundary columns in BOTH bakes and by the line's presence in both
  bakes: there is no content mismatch for a bake-worker nudge to fix, so a re-bake (1,198-1,269 s,
  ~4.6 GiB) + deliberate genhash rebase cannot be justified against a target that does not exist.
  (A) is refuted by measurement #1. The remaining candidate cause class (a rasterization/sampling
  discontinuity at the coincident seam that is texture-dependent, UV-source-independent, and
  content-independent) is a design decision this plan does not make.
- PROBES REVERTED: all temporary probes (u_flat_probe + u_probe2 branches, the env pushes in
  satellite_body.gd, the temporary `unshaded` render_mode) are REMOVED; godot/core/satellite_body.gdshader
  and godot/world/satellite_body.gd are byte-identical to HEAD (md5 1e3960730ea8eb600b95a91482bd5a6f /
  a0289cbdc4131aaeede337152aaf605c, git clean on both). No fix was kept; NO re-bake was performed;
  NO genhash rebase is owed or done.
- GATES (post-revert tree = HEAD, gate_run.py AC-0438 --arms g0,genhash,satellite rev 1, all ok):
  g0 rc=0 with 0 SCRIPT ERROR + 0 SHADER ERROR; genhash 25/25 byte-identical to the reference set
  (GENMS 131; gh_ref vs genhash-r1 diff empty, .scratch/AC-0438-gates/); satellite arm ok=true -
  src=res (mode=res, res_load_via=import), height_decode 12/12 (every face diff_px=0, max_byte=0),
  guard_ok=true, res_export_ok=true, tex_shape_ok=true, 12 meshes / 12 textures 1024x1024.
  Standing values hold on the untouched tree. No genhash rebase owed (no asset change made).
- EVIDENCE: .scratch/AC-0438/rem2/ (rem2-baseline/flat/nomip/probe2-day.png + .log, measure_baseline.log,
  decode scripts). NEXT (coordinator): amend the plan with a third option or an explicit ruling -
  e.g. authorise a shader-side sampling probe/fix at the coincident seam (a level-0 texel-neighbour
  dump to pin the sampled texel, then a clamp/nudge of the sampling - no asset change, no genhash
  rebase), or rule (B) despite the byte-identical boundary columns and accept the re-bake cost.
