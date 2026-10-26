# AC-0483 continuity journal

## RUN — Sun Oct 25 20:16 EDT 2026 — AC-0483 (MEDIUM builder, removal of synthetic sky horizon)
Plan read (tasks/AC-0483/plan.html). No spec.html in folder. Godot slot free at run start (pgrep empty).
Step 1 = survey by symbol, not line; then removals; gates g0,genhash + render pixel columns.

### SURVEY (step 1) — located by symbol, current lines (shader = 459 lines)
1. ARTIFICIAL LOCAL-HORIZONTAL DIVISION — EXISTS: `hl = (r>0.0) ? dot(dir,upc)/r : dir.y` :284;
   `under_disc = 1.0 - step(u_limb_radius, r)` :313; `below_old = clamp(step(0.0,-hl)+under_disc,0.0,1.0)` :314;
   `below_soft = max(under_disc, smoothstep(0.0,0.03,-hl))` :315; `below = mix(below_old,below_soft,u_horizon)` :316.
2. BELOW-HORIZON AIR/SPACE FLOOR — EXISTS: `belowc = mix(mix(space_color,u_air,1.0-w),u_air,u_horizon)` :377;
   `belowc = mix(belowc, mix(u_air,space_color,ws), u_no_floor)` :388; `col = mix(above,belowc,below)` :389.
3. HORIZON ANCHOR / FLOOR COMPENSATION — EXISTS: `u = clamp(hl,0.0,1.0)` :339;
   `horizon_eff = mix(horizon_color,u_air,w*u_horizon)` :350;
   `anchor = mix(horizon_eff, mix(horizon_color,space_color,ws), u_no_floor)` :361;
   `grad = mix(anchor,mid_color,smoothstep(0.0,0.30,u))` :362; thin `:375` (u-anchored, zero at hl=0).
   Filing's mechanism CONFIRMED: u_no_floor=1 + ws=0 => anchor = horizon_color while belowc = u_air —
   two colours meeting across the 0.03 blend at hl=0.
4. LOCAL-HORIZONTAL HAZE STRIPE — EXISTS AT BOTH SITES (the "moved / both" answer): the CORRECTED
   path's stripe is in sky_on at :400-401 using `hl` EXACTLY as the filing quoted
   (`hz = exp(-abs(hl)*9.0) * haze_amount * (1.0-w) * mix(1.0,1.0-ws,u_no_floor)`); the :200-201 one
   using `h` (`h = dir.y`, :193) is the LEGACY sky_off world-Y version. The filing's "already gone,
   only legacy remains" hypothesis is WRONG — both exist.
AUDIT 1 (legacy sky_off :192-236): the synthetic horizon (h<0 darkening :197-199 + world-Y haze
:200-201) is confined to sky_off; sky_off is reachable ONLY via `u_sky_alt < 0.5` (:452) — the
explicit "sky_altitude" switch (Settings default ON, world.gd:5712). Turning the switch OFF is an
explicit user action, not a silent reintroduction; the corrected path carries none of it.
AUDIT 2 (sky() routing :449-459): `u_sky_alt < 0.5 ? sky_off : sky_on`; shader default u_sky_alt = 0.0
(material never pushed degrades to legacy — documented convention), but the runtime default is
CORRECTED: world.gd:5712 pushes u_sky_alt = 1.0 from Settings "sky_altitude" (default ON).
Pushes to drop in world.gd: (2c) u_horizon :5668-5679 + state :5339-5340; (2d) u_no_floor
:5680-5698 + state :5341-5342; (3) u_space_out :5732-5741 + state :5348-5351. main.gd pushes NONE
of the three (creation block :95-103 only pushes u_srgb_pre + space_color) => main.gd untouched.
Aero.sky_outside (aero.gd:75) becomes unused (aero.gd not in the plan's file list — left alone).
Settings "sky_horizon" / "no_sky_floor" become inert (their data JSON / env preloads stay — untouchable).

### Design (the removal shape)
sky_on becomes: hl/upc/r kept (the limb term needs hl, r, u_limb_center); `w = u_space_sky` kept;
ONE smooth directional gradient keyed to local elevation continuing through local horizontal
(u = hl unclamped — the smoothstep windows are C1 at hl=0, so no kink; the day sky is
bit-identical for hl >= 0), thinned to space by the A window w at a UNIFORM rate
(`col = mix(grad, space_color, w)` — the boundary-anchored w*u thin (AC-0428) existed only to keep
the removed belowc seam one colour; AC-0402 "w=1 => space exactly" contract preserved).
Removed: under_disc/below_old/below_soft/below, belowc + the mix, horizon_eff, the u_no_floor
anchor bypass, ws = u_space_out, the hz stripe, and uniforms u_horizon / u_no_floor / u_space_out
(+ their world.gd pushes). Preserved verbatim: sky_off (OFF contract), the limb air-column term
(:407-435), sun/moon (:436-445), u_sky_alt routing, u_space_sky window.

### LANDED — Sun Oct 25 20:4x EDT 2026
EDITS (2 files):
1. godot/core/aero_sky_gradient.gdshader (459 -> 332 lines):
   - removed uniforms u_horizon (AC-0422), u_no_floor (AC-0429), u_space_out (AC-0439) +
     their comment blocks (one-line AC-0483 note in their place).
   - sky_on: removed under_disc/below_old/below_soft/below (site 1, incl. the under_disc
     forced fill), ws = u_space_out, horizon_eff, the u_no_floor anchor bypass, the u-anchored
     thin (w*u), belowc + col = mix(above, belowc, below) (site 2), the hz = exp(-abs(hl)*9.0)
     stripe (site 4). Now: hl/upc/r kept (the limb term needs them), w = u_space_sky,
     u = hl UNCLAMPED, grad = the sky_off expression re-keyed (C1 through hl = 0),
     col = mix(grad, space_color, w) — uniform-rate A-window thin (AC-0402 "w=1 => space
     exactly" contract intact). sky_off UNTOUCHED (OFF contract bit-for-bit). Limb air
     column + sun/moon UNTOUCHED.
2. godot/world/world.gd: removed the (2c) u_horizon + (2d) u_no_floor change-gated pushes,
   the per-frame u_space_out push, and the three state vars; AC-0483 marker comments in place.
   main.gd: NO change (it pushes none of the three — verified).
   Aero.sky_outside (aero.gd:75) now unused — aero.gd not in the plan's file list, left alone.
BEFORE renders (pre-edit tree, the old band's stances): before-h100 (SAT_ALT=100, radial ~241,
w=0) + before-h800 (the AC-0439 user-frame lineage, radial ~941, w~0.8), seed 44 T=0.5 R50
1280x720 drain 600 steps 300/600 — running at landing time.

### BEFORE-evidence correction (switches-off artifact found)
First true-BEFORE attempt installed only the pre-edit SHADER (world.gd was already my
post-edit version) — so the removed switch pushes never ran and u_horizon/u_no_floor
sat at their shader defaults (0.0 = OFF). Those frames (before-h100-switches-off /
before-h800-switches-off) show the OLD shader in its switches-OFF (pre-AC-0422)
configuration: h800 has a 62.75/255 median crossing at hl=0 (the pre-AC-0422 boundary),
h100 the classic step+stripe band (crossing median 5.33, 88% of cols > 5/255,
bump + reversals). h100 at w=0 is nearly identical with switches ON (the colours are
the same; only the 0.03-blend vs hard step differs), so h100 remains valid
current-configuration band evidence. h800 switches-off is NOT the current tree's look
(AC-0439's saved after-inside-h800.png — same stance, pre-edit tree, switches ON —
measures a smooth 246-250 below-horizon with ~1-2/255 steps: the subtle residual
band). Re-rendering BOTH before frames with pre-edit shader AND pre-edit world.gd
(byte-exact from git HEAD; HEAD == pre-edit tree verified: shader 459 lines / 8
u_no_floor / all marker lines exact; world.gd diff vs HEAD == exactly my 3 regions).

### GATES
- gate_run.py AC-0483 --arms g0,genhash (bash-1450): g0 rc=0 script=0 shader=0 ok=true 3.7s;
  genhash rc=0 ok=true 4.0s (25 GENHASH lines). summary.json: both ok. Logs .scratch/AC-0483-gates/{g0-r1,genhash-r1}.log.
- Renders (all RENDERTAG rc=0 file=yes): before-h100/h800 (true, pre-edit tree), before-*-switches-off (bonus),
  early-h800-newcode (= after-h800), after-h100, after-outside-day/night (2000 m), after-sun-zenith, after-moon-zenith.
- colprof.py band metrics (logs colprof-*.log):
  before-h100 (old, sw ON): lum cross med 0.93/p95 3.21/max 11.98, R cross med 1.00/p95 5.00/max 18, R bump p95 3.50 (4%>4), rev 4.42.
  after-h100 (new): lum cross med 0.00, R cross med 0.00/p95 4.00, rev 3.25 (saturation jitter).
  before-h800 (old): lum cross med 0.00/p95 0.21; R bump p95 3.00 (0%>4), rev 0.45.
  after-h800 (new): lum cross med 0.07, R bump p95 0.50, rev 0.03; row medians 1.80→73.90 monotonic, only in-frame step = limb row 719 (191.66).
  switches-off rows: h800 crossing 62.58 med (100% cols > 15/255), h100 5.33 med (88% > 5/255).
- Seam rows (x=640): before-h100 (209,250,255)/(209,250,255); after-h100 (227,255,255)/(228,255,255);
  before-h800 (232,255,255)/(233,255,255); after-h800 (13,44,55)/(13,44,55).
- Preserved (pixel-evidence.log): planet body after-h100 rows 680/719 (249,241,202) byte-identical to before-h100
  (same max 254 at (622,646), same 921211 bright px); limb 57.66→73.90; sun disc 255 at (828,175); moon disc 255 at (591,260);
  stars 199 px (both outside frames, max 255 at (885,52)) / 2815 night; u_air day [208,241,251] night [48,97,109];
  transition w=0/0.799/1.0 measured (outside row medians 0.00, u_space=1.0).
- Day sky hl>=0 bit-identical at w=0: after-h100 row 0 = 128.55 = before-h100 row 0 (both profiles).

### CLOSE
- Deliverables: AC-0483-results.html (all numbers traceable to .scratch/AC-0483-gates/ logs), deviations D1-D7,
  captures/ (10 frames + step snaps), colprof.py, this journal.
- No git operations performed (fenced by ticket); no TASKS.yaml edits; no new tickets; main.gd untouched;
  generation/streaming/residency/light-ownership/far-tier/bake/JSON/aim-box untouched; blur off in all renders.
- Tree state verified at the end: fixed shader 332 lines + fixed world.gd 16307 lines on disk (STATE_OK after each swap).
- Residuals noted: Settings toggles sky_horizon/no_sky_floor + UI checkboxes inert (D2); Aero.sky_outside unused (D3);
  coordinator's shaderforce (not in this ticket's arm set) will see the uniform count 27→24.
