## RUN - Thu Oct 15 05:34:33 EDT 2026 - AC-0431

**State at run start:**
- Fresh run (no prior entries). Task ticket in tasks/TASKS.yaml (AC-0431).
- Working tree: only the 4 fenced game files modified by the parallel session (main.gd, game.gd,
  drop.gd, debug.gd) + tasks files. AC-0427 + AC-0430 are committed (01e8a36); the served
  godot/bin/libchunkio.so (rebuilt 05:32, post-AC-0430-fix state) MATCHES the working tree
  native — no native rebuild owed; leave the tree as-is.
- Prior evidence read: AC-0426 (ambient_sky switch, default OFF, AWECRAFT_AMBSKY env, AMB_SKY_L
  0.35, mask step(m_direct, 0.08) = MIN_AMB floor; safety: frame mean +0.15, ground band 0 px,
  night bit-identical), AC-0427 (seam light + hole fix; acceptance view = ground level along the
  x=0 seam at spawn), AC-0430 (black step face: UV verified correct, vertex sky term ≈ 0.078 =
  the 20/255 floor; frame .scratch/AC-0430/after-fix-r4-userview.png, black polygon x~690-890
  y~0-95, lit brown neighbour band to its right).
- Light model (verified in mesh.cpp/chunk_lit_opaque.gdshader): modern per-vertex ON by default:
  vColor r = sl = clamp(1-0.4*occl, 0.08, 1.0) (geometric, floor 0.08 = 20/255 after 8-bit
  truncation), g = block light (0 without glow), b = oshade; L = 0.20+0.80*max(u_day*r, g);
  ALBEDO = tex*b*L; + AC-0426 term L += u_amb*u_day*step(m_direct, 0.08).
- Day/night: day(0.3) = 1.0 (default boot time is full day); day(0.0) = 0.0 (midnight).
- Atlas facts: grass top tile [0,0] is grayscale on disk, tint-baked green at load
  (data.gd _bake_atlas_tints); dirt [96,0] brown. (Explains the green field vs the gray tile.)

**Plan:** tasks/AC-0431/plan.html. Temporary ac0431probe arm in harness.gd (seam step-face
vColor census + boot-camera projection) -> probe run -> 4 Forward+ captures (before/after/night
pair) -> pixel analysis -> if the floor-face hypothesis holds, flip the ambient_sky default in
settings.gd (+ comments + ARCHITECTURE.md) -> final default-boot capture -> remove the arm ->
light gates (G0 x2 + census + exit status, SMOKE, PROBE, genhash, shaderforce) -> results page.

## FINDINGS (investigation outcome — both causes contribute)

**The cheap hypothesis is PARTIALLY right. Two distinct causes contribute (as the ticket
anticipated: "THE TWO ARE NOT MUTUALLY EXCLUSIVE and the run should say so if both contribute").**

**What the black region is (measured, not surmised).** Seed 44, default user camera (aim cell
(8,140,8), cam (8.5,143.5,10.5), yaw 0, pitch -0.98279), r4. The black quadrilateral (frame x
694-886, y 0-72) is terrain IN FRONT of the camera at world (x 9-16, z -8..-1): grass tops
(block 1, top y=140), a tree (logs block 6 at y140-142, leaves block 7 at y143-144, x 12-15,
z -8..-5), and the step faces between them. A ray-march from 221 pixels of the black region
hit a SOLID block in 221/221 cases (zero miss) -> it is NOT a void/hole; every pixel lands on
real geometry.

**Cause A - light floor (the hypothesis; CONFIRMED for its part).** The step/top faces next to
the tree are occluded by the tree's tall columns (occl >= ~2.3) and sit at the light floor:
measured vColor r=20/255 (=0.078) on the grass tops at (x11-15, world z -8..-5, y140) and on
the x=16 seam face (t=8..13). These render DARK BROWN (e.g. (22,7,0)), NOT pure black. The
AC-0426 ambient term (mask step(m_direct,0.08) fires at m_direct=0.078) lifts them: region
mean lum 6.51 -> 7.18; the left cliff face lifts strongly (4.08 -> 5.90, +45%); ~1,300 px go
black->lit. No flattening: the lit neighbour (x890-960) is stable at lum 71.67, the wider
ground band (y400-660) at 88.68, both 0 pure-black, unchanged. Night: terrain stable, nothing
became brighter (only the sky strip y0-76 differs, slightly darker with the switch ON).

**Cause B - the dominant "exactly (0,0,0)" (the ticket's headline measurement) is a
TEXTURE/MATERIAL bug, NOT a lighting one.** The remaining pure-black pixels (64% of the region
even with the switch ON) map, by ray-march, to FULLY-LIT grass TOP faces (vColor r=153-255) at
world z -4..-1 and to tree side faces. A fully-lit face has L=0.20+0.8*1.0=1.0 and b (oshade)
~0.6-1.0, so ALBEDO = tex*b*L can be (0,0,0) ONLY IF the sampled texel is (0,0,0). Those faces
sample the grass-top tile (canvas (1,1)-(32,32)) — the SAME tile the green neighbours use — so
the blackness is in the merged-canvas/material path, not the vColor. ambient_sky CANNOT fix it:
the mask requires m_direct <= 0.08, but these faces have m_direct up to 1.0, so the added term
is 0 for them (consistent: they stay (0,0,0) with the switch ON). This matches the ticket
candidate "the face being emitted by a different path" (the AC-0430 merged-canvas material path).

**Why ambient_sky alone does not meet the acceptance.** The acceptance is "step faces shaded
like their neighbours rather than black." With the switch ON the region is still ~10x darker
than the lit neighbour (lum ~7 vs ~72) and 64% pure black (cause B). So a change of default is
NOT the complete fix and was NOT made: the ambient_sky default stays OFF (no look shipped), to
avoid shipping an incomplete fix. The real fix is cause B.

**Cause B is in the merged-canvas material/UV path.** The canvas is built in
godot/world/chunk.gd (_merge_atlas, GDScript — NOT fenced), but the UV generation and the
high/low emit paths are in gdext/src/mesh.cpp (C++ — FENCED). AC-0430 fixed one mis-sampling
(the tier-1 ring) and declared the rest sub-visible at that camera; this run shows a fully-lit
near tier-0 face sampling black, so the AC-0430 fix did not cover this path. Root-causing cause
B needs the mesh/canvas code; if it lands in mesh.cpp the work must STOP and report (fenced).

**Acceptance evidence (tasks/AC-0431/captures/):** before-off-day.png (byte-identical to the
AC-0430 flagged frame, md5 d3498c6f...), after-on-day.png, day-sidebyside-x3boost.png,
day-diff-x8.png (ambient lifted only the left cliff + two thin edge lines), night-off.png /
night-on.png / night-sidebyside-x3boost.png (terrain identical). Numbers: region (x694-886,
y0-72) before mean lum 6.51 / 73.5% pure black; after 7.18 / 64.4%; neighbour 71.67 both;
ground band 88.68 both.

**Run state at handoff:** tree = HEAD + the 4 fenced parallel-session files only; the temporary
ac0431probe arm in harness.gd MUST be removed before closeout (pristine rule); no native
rebuild owed; .so matches tree. Light gates (G0 x2 + census + exit status, SMOKE, PROBE,
genhash, shaderforce) to run on the pristine tree after the arm is out.
