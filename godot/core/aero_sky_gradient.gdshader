shader_type sky;
// AC-0235 follow-up: with env fog ENABLED the engine fog path replaces
// the custom-sky background with the flat fog color (the sky never showed
// - the 'no sun / flat sky' bug). disable_fog keeps the sky pass pure;
// the cloud quad and terrain keep their own fog handling.
render_mode disable_fog;
// AC-0235: the AeroSky dome (aero_sky.gdshader, a flipped sphere at
// SKY_RADIUS) is gone - the DayNight gradient + sun now render in the
// engine SKY PASS (fullscreen, no geometry). The fragment math is copied
// 1:1 from the dome: the dome was a sphere centered on the camera, so its
// normalize(wpos - cam_pos) is exactly EYEDIR here. The painted clouds were
// moved to the real cloud layer (cloud_layer.gdshader on a flat quad).
uniform vec3 zenith_color : source_color = vec3(0.1804, 0.5255, 0.8471);
uniform vec3 mid_color : source_color = vec3(0.3725, 0.7765, 0.9176);
uniform vec3 horizon_color : source_color = vec3(0.8745, 0.9647, 0.9843);
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.2);
uniform vec3 sun_core : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 sun_halo : source_color = vec3(1.0, 0.9647, 0.8706);
uniform float sun_amount : hint_range(0.0, 4.0) = 1.0;
uniform vec3 haze_color : source_color = vec3(0.7294, 0.9137, 0.9804);
uniform float haze_amount : hint_range(0.0, 1.0) = 0.35;
// AC-0242: same pre-decode as the dome had - Forward+ displays
// unshaded/sky output one sRGB curve brighter without it.
uniform float u_srgb_pre : hint_range(0.0, 1.0) = 0.0;
// AC-0386: the space transition. u_space is the flight band's S (main.gd
// _update_sky - the SAME smoothstep(500, 2000, radial altitude) the
// controls use, so the sky darkens exactly where the controls hand over).
uniform float u_space : hint_range(0.0, 1.0) = 0.0;
uniform vec3 space_color : source_color = vec3(0.0078, 0.0118, 0.0392);
// AC-0384 r4: the atmospheric limb glow - the bright blue rim around the
// planet that is the No Man's Sky signature look (and the only thing that
// currently separates the disc from the space sky). The sky pass had no
// limb term at all: AC-0386 mixes the horizon to space_color with weight
// S^2, so at altitude the disc's haz_a rim (bright, on the disc side)
// meets a dead-black sky (off the disc side) - a hard edge - and the
// h<0 "below-horizon" branch darkens the band between the camera's
// horizon and the drawn limb (the measured (96,143,153) band of the
// 700 m capture, tasks/AC-0384/rd4-d700.png). The glow is a function of
// the view ray's IMPACT PARAMETER about the planet centre - the same
// grazing-ray physics the body's haz_a uses (header item (2)(a)): b =
// |cross(u_limb_center, dir)| is the ray's closest approach to the
// centre, so the term peaks where the ray is tangent (b = u_limb_radius)
// and falls off outward through the air shell, independent of altitude
// and render distance. It is painted in the BACKGROUND, so it shows
// exactly in the region the drawn disc does not cover - including the
// gap between the geometric tangent (R+SEA) and the lower displaced
// surface (the dark band), which it fills with glow instead of dark sky.
// u_limb_center is the centre relative to the CAMERA (pushed per frame
// by main.gd - the AC-0036 precedent: no CAMERA_POSITION builtin in a
// sky shader on the headless dummy renderer), u_limb_radius = R + SEA
// (the star-occlusion radius - the same pair _update_sky already
// computes, one home). u_limb_amount is 0 by default behaviour OFF only
// via the AWECRAFT_LIMB=0 env (A/B); the colour derives from the
// day/night/dusk-adjusted horizon+mid colours, so it dies at night for
// free. A mild sun-side boost (forward scattering) rides sun_dir.
uniform vec3 u_limb_center = vec3(0.0);
uniform float u_limb_radius : hint_range(0.0, 20000.0) = 0.0;
uniform float u_limb_amount : hint_range(0.0, 4.0) = 0.55;
// AC-0401: the altitude gate for the limb glow (Settings "limb_space",
// default ON; world.gd pushes u_limb_gate = 1.0 when ON). The glow is an
// ORBIT instrument - the signature rim you see the planet FROM SPACE -
// so it rides u_space (the flight-band blend, the same uniform that
// darkens the dome): 0.0 near the ground (no rim below the flight band,
// where the low LOD's fog fade alone is the horizon read), 1.0 from
// orbit (the full r4 rim). 0.0 (the shader default - no push) is the
// pre-AC-0401 behaviour, the glow at every altitude.
uniform float u_limb_gate : hint_range(0.0, 1.0) = 0.0;
// AC-0414 clause 2: while the body is not LOADED, the sky must not
// fake-present a planet. The limb term's clamped impact parameter is a
// FILLED disc (limb = 1.0 inside the tangent - the "pale ball" the user
// saw while the bake was still running), so the term is multiplied by
// u_body_loaded: 0.0 while the body is WORK/LOAD (no fake planet), 1.0
// once it is LOADED (the signature rim around the real planet). Both
// uniforms are pushed from world.gd _ac0401_push (like u_limb_gate).
// u_limb_loaded is the switch (Settings "sat_preload", default ON):
// mix(1.0, x, 0.0) = 1.0, so the shader default (0.0, no push yet) is
// exactly the pre-AC-0414 limb — OFF is bit-identical.
uniform float u_limb_loaded : hint_range(0.0, 1.0) = 0.0;
uniform float u_body_loaded : hint_range(0.0, 1.0) = 0.0;

// AC-0402: the sky's OWN space-blend window (the "leaving a planet" half of
// the objective). u_space (above) is the physics flight-band S (500-2000 m
// alt_rad, main.gd) and completes by ~1600 m, so the sky went fully black
// before the climb was half done and the altitude ladder carried no
// mid-state (AC-0384 s25/D4). The BACKGROUND blend therefore uses
// u_space_sky, pushed per frame by world.gd (_ac0401_push) from the SAME
// radial altitude but a stretched window (BAND_WALK_MAX .. BAND_FLY_MIN
// times 1.6 - the band constants read off the live player, never
// duplicated), so the blue thins gradually over the whole climb (S_sky
// about 0.04 / 0.44 / 0.92 at the 700 / 1600 / 2600 m frames). The
// limb-glow gate (u_limb_gate * u_space), the star opacity and the
// sun-glow fade all keep riding the physics S (the AC-0386/AC-0401
// contracts). u_sky_alt is the switch (Settings "sky_altitude", default
// ON): 0.0 makes the mix below exactly the pre-AC-0402 ws, so OFF is
// bit-identical to the old sky; 0.0 is also the shader default, so a
// material that never sees the push keeps the old look.
uniform float u_space_sky : hint_range(0.0, 1.0) = 0.0;
uniform float u_sky_alt : hint_range(0.0, 1.0) = 0.0;
// AC-0417: u_sky_alt REDEFINED (Settings "sky_altitude", default ON):
// ON (1.0) = the local-zenith sky below (sky_on) - the atmosphere height
// A is the single home (Aero.atmosphere_height, env AWECRAFT_ATMO): the
// background is the two-colour model (air below the local tangent cone,
// space above), the limb geometry is the tangent cone at the A shell,
// and the star field / sun glow ride the same A window. OFF (0.0) =
// sky_off - the pre-AC-0402 expression VERBATIM (h = world Y, the
// physics-S window mix, the physics-S gates): bit-for-bit. 0.0 is also
// the shader default, so a material that never sees the push keeps the
// old look (the OFF contract, as before).
// AC-0417: the SINGLE-SOURCE air colour in the sky pass's native space
// (DISPLAY space - the sky pass pre-decodes with u_srgb_pre under
// Forward+, AC-0242, so the 8-bit sRGB value Aero.fog_display_srgb goes
// in as-is; the env fog and the body's u_air take srgb_to_linear of the
// same 8-bit source, world.gd pushes one value to both). One home,
// three consumers (the AC-0400 identity). The default is the T = 0.5
// value; world.gd pushes the live day/night value per frame.
uniform vec3 u_air : source_color = vec3(0.8157, 0.9451, 0.9843);
// AC-0422: the continuous-horizon switch (Settings "sky_horizon",
// default ON; pushed change-gated by world.gd _ac0401_push block 2c).
// 0.0 = the pre-AC-0422 path VERBATIM (the hard branch step at
// hl = 0 + the space-thinned below branch), so a material that never
// sees the push keeps the old look; 1.0 is the fix (see sky_on).
uniform float u_horizon : hint_range(0.0, 1.0) = 0.0;
// AC-0429: the skybox-must-have-no-bottom-edge switch (Settings
// "no_sky_floor", default ON; pushed change-gated by world.gd
// _ac0401_push block 2d). 0.0 = the pre-AC-0429 path VERBATIM (the
// u_air air floor below the local horizon, the u_air horizon anchor,
// the (1-w) horizon haze band) — a material that never sees the push
// keeps the AC-0428 look (the AC-0401 short-circuit convention).
// 1.0 removes the lower boundary as a CONCEPT (not a smoother version
// of it): below the local horizon the sky is SPACE — the same black,
// the same stars — with no anchor, no band and no fade at the bottom
// of the sky. The gradient's horizon anchor fades to space with the
// floor's space weight ws (see sky_on), the below-branch fill blends
// u_air -> space with the same ws (u_air survives ONLY at w = 0 — the
// ground-level AC-0384 r8 fog seam), and the horizon haze band dies
// with ws (the "air seen edge-on" of the floor is a ground-level
// phenomenon; at altitude the local horizon is not the atmosphere).
// What remains in the lower frame: the planet's disc, its u_air rim
// haze and the limb air-column term — the planet and its air, the
// only boundary present (the planet IS the horizon).
uniform float u_no_floor : hint_range(0.0, 1.0) = 0.0;
// AC-0417 clause D: the limb geometry at the atmosphere top A.
// u_atmo_radius = R + A (the A shell's radius - the visible-tangent
// convention u_limb_radius uses for R + SEA extends to A, so the
// atmosphere's silhouette is legitimately LARGER than the terrain's;
// the cloud tops at R + 400 sit strictly inside R + A - asserted in
// world.gd). u_atmo_falloff = 0.25 A (a stated fraction of A, not the
// hard-coded 300 m - which it equals at the default A = 1200). Both are
// 0.0 by default and UNREAD on the OFF path (bit-for-bit contract); on
// the ON path a 0.0 falls back to the pre-AC-0417 value (u_limb_radius /
// 300) so a material that never sees the push degrades to the old rim.
uniform float u_atmo_radius : hint_range(0.0, 20000.0) = 0.0;
uniform float u_atmo_falloff : hint_range(0.0, 5000.0) = 0.0;

// AC-0417: the OFF path - the pre-AC-0402 sky VERBATIM (h = dir.y, the
// world axis). Everything keyed on h is the world-Y expression, the ws
// mix evaluates to the first argument exactly with u_sky_alt = 0, and
// the limb/sun gates ride the physics S. Do not "clean up" this body -
// it is the OFF contract, bit-for-bit.
vec3 sky_off(vec3 dir) {
	float h = dir.y;
	float u = clamp(h, 0.0, 1.0);
	vec3 col = mix(horizon_color, mid_color, smoothstep(0.0, 0.30, u));
	col = mix(col, zenith_color, smoothstep(0.25, 0.90, u));
	if (h < 0.0) {
		col = mix(col, horizon_color * 0.5, clamp(-h * 2.0, 0.0, 1.0));
	}
	float hz = exp(-abs(h) * 9.0) * haze_amount;
	col = mix(col, haze_color, hz);
	// AC-0386/AC-0402: the atmosphere thins with the radial altitude.
	// The zenith darkens first (weight S), the horizon last (weight S^2
	// - the grazing column of air keeps its blue longest). S = 0 is
	// bit-identical to the pre-AC-0386 sky; S = 1 makes the whole dome
	// space. With u_sky_alt = 0 this is exactly the pre-AC-0402 ws.
	float ws = mix(mix(u_space * u_space, u_space, u), mix(u_space_sky * u_space_sky, u_space_sky, u), u_sky_alt);
	col = mix(col, space_color, ws);
	// AC-0384 r4: the atmospheric limb glow (see the uniform block).
	// u_limb_radius = 0 (no player / no world yet) turns the term off:
	// b - 0 > 0 always, exp(-b/300) ~ 0, and the step keeps it at 0.
	if (u_limb_amount > 0.0 && u_limb_radius > 0.0) {
		float b = length(cross(u_limb_center, dir));
		float limb = exp(-(b - u_limb_radius) / 300.0);
		if (limb > 1.0) {
			limb = 1.0; // inside the tangent: clamped, not amplified
		}
		vec3 limb_col = horizon_color * 0.5 + mid_color * 0.5;
		float sun_side = 0.55 + 0.45 * pow(clamp(dot(dir, sun_dir), 0.0, 1.0), 2.0);
		// AC-0401: gate on u_space when u_limb_gate is ON (the mix is
		// exactly 1.0 with the default u_limb_gate = 0.0 - the old path).
		// AC-0414 clause 2: multiply by the body-loaded gate (the fake
		// planet disc is gone while the body is not LOADED).
		col += limb_col * (limb * u_limb_amount * sun_side * mix(1.0, u_space, u_limb_gate) * mix(1.0, u_body_loaded, u_limb_loaded));
	}
	float sd = dot(dir, sun_dir);
	float up = clamp(sd, 0.0, 1.0);
	float disc = smoothstep(0.99894, 0.99985, sd) * sun_amount;
	// the sun's GLOW is scattering - it dies with the air; the disc stays.
	float glow = (pow(up, 24.0) * 0.60 + pow(up, 5.0) * 0.22) * sun_amount * (1.0 - u_space);
	col = col + (sun_core * disc) + (sun_halo * glow);
	return col;
}

// AC-0417 (local-zenith re-key) / AC-0419 (the day sky + the limb
// boundary removed). hl = dot(dir, local up) with local up = the radial
// through the camera = -u_limb_center / r (u_limb_center is the planet
// centre RELATIVE TO THE CAMERA - the same uniform the limb term uses,
// one home); fallback dir.y when the camera is at the centre (no world
// yet).
// AC-0419: the background above the local horizon is the day/night/dusk
// GRADIENT keyed to the local zenith (the sky_off expression re-keyed
// from world Y to hl) - the AC-0417 ON path painted space_color across
// the whole upper hemisphere at every altitude (the gradient uniforms
// were pushed but never read here: "the sky is dark during the day",
// the user's 2026-10-11 report 1). The A window (u_space_sky = w)
// thins the gradient to space SMOOTHLY: the zenith by w, the horizon
// by w*w (the grazing ray sweeps a longer air column, so the horizon
// holds the sky blue longest); at w = 1 the mix is space exactly, so
// "the sky is space" still lands at A with the body's h_full
// (satellite_body.gd) at the same A. Below the local tangent cone of
// the R + SEA disc the single-source AIR colour is UNCHANGED (clause C
// / AC-0417 F3: mix(space, u_air, 1 - w) - a coverage gap reads haze,
// not a hole).
// The limb term keeps the AC-0417 clause-D geometry (the A shell:
// u_atmo_radius = R + A) but the CLAMPED EXPONENTIAL is gone - it
// filled the whole annulus inside the A-shell tangent to a flat 1.0
// (a hard boundary circle in space: report 2 "a large blue circle
// above and below you") and its 0.25 A tail sat a hard 750 m past the
// cloud tops (report 3 "the edge ... does not extend past clouds").
// The new term is the FORWARD AIR COLUMN through the shell's outer
// tail (rout = u_atmo_radius + u_atmo_falloff = R + A + 0.25A),
// normalized by the full chord at the R + SEA disc tangent (cm). The
// ray crosses the rout sphere at s = -r*hl +/- half (half =
// sqrt(rout^2 - b^2); hl = the ray's radial component, the same local
// zenith elevation the background uses): if the near crossing is ahead
// of the camera (s_enter > 0 - the camera is OUTSIDE the shell, ray
// heading in) the visible air is the full chord 2*half (1.0 at the
// terrain limb, 0.89 at the deck top R + 450, 0.49 at the old
// A-shell tangent, 0.0 at the tail); if the camera is INSIDE the
// shell or the ray points AWAY (upper hemisphere), the visible air is
// the near exit max(0, s_exit) - 300 m straight up at A (0.04), and
// EXACTLY ZERO everywhere above the horizon from outside the shell
// (looking up in space is space - the AC-0419 r1 chord formula
// painted the upper hemisphere from outside as if the ray grazed the
// shell, a visible circle in the upward view, caught in a08). Bounded
// by 1.0 (clamped), smooth, no tangent edge anywhere.
vec3 sky_on(vec3 dir) {
	vec3 upc = -u_limb_center;
	float r = length(upc);
	float hl = (r > 0.0) ? dot(dir, upc) / r : dir.y;
	// below the cone: the ray is under the local horizon (hl < 0) or the
	// camera is inside the R + SEA disc (r <= u_limb_radius - no horizon
	// exists, everything is air).
	// AC-0422: the continuous horizon (u_horizon - see the uniform).
	// The old path DREW a boundary instead of computing one: a hard
	// step at hl = 0 (a straight line across the frame at altitude)
	// with BOTH branches space-thinned by the A window (w) - so at
	// w > 0 the sky no longer met the world's single-source fog
	// colour (u_air - the env fog and the satellite body's rim ARE
	// u_air, the AC-0384 r8 seam), and the fog wall and the body rim
	// became visible hard edges (measured before: a 64.15/255
	// single-row step at the local horizon and a 12.43/255 step at
	// the body rim, tasks/AC-0422/AC-0422-results.html). The fix
	// keeps every contract AC-0417/AC-0419 verified (the local-zenith
	// gradient; the sky is space at A when LOOKING UP; the below
	// branch reads as haze, not a hole) and removes the boundary:
	// (1) the below branch is u_air at EVERY altitude - the air is
	//     not space-thinned (the air does not become space, the view
	//     does): the fog fades to u_air, the body's rim is u_air, the
	//     sky under the horizon is u_air - one colour at the seam;
	// (2) the space thinning spares the horizon: the weight is
	//     multiplied by u - 0 at the local horizon (the grazing ray
	//     sweeps the longest air column and keeps its colour: the
	//     bright band at the horizon IS the atmosphere seen edge-on),
	//     w at the zenith (u = 1 keeps the weight exactly w - the
	//     sky is still space at A when looking up);
	// (3) the branch switch is a smooth blend of width 0.03 (~2 deg)
	//     below the horizon instead of the step.
	float under_disc = 1.0 - step(u_limb_radius, r);
	float below_old = clamp(step(0.0, -hl) + under_disc, 0.0, 1.0);
	float below_soft = max(under_disc, smoothstep(0.0, 0.03, -hl));
	float below = mix(below_old, below_soft, u_horizon);
	float w = u_space_sky;
	// AC-0429: the FLOOR'S SPACE WEIGHT - the one number that removes the
	// lower boundary as a concept. 0.0 at the ground (w = 0: the air
	// floor stays - the AC-0384 r8 fog seam - and every expression below
	// reduces to its pre-ticket value), 1.0 from w >= 0.3 (alt ~630 m:
	// the local horizon is space well before the user's 800 m frame at
	// w = 0.8, where it is space EXACTLY). Derived from w (the A window
	// - one number, one home, the AC-0417 principle), not a new altitude
	// constant.
	float ws = smoothstep(0.0, 0.3, w);
	// the local-zenith gradient (the sky_off expression, re-keyed):
	// horizon -> mid over the lower third, -> zenith over the top.
	float u = clamp(hl, 0.0, 1.0);
	// AC-0428 item 1 ("sky still has a horizon"): the gradient's horizon
	// anchor blends to the single-source air colour as the A window opens
	// (w). The body's rim (haz) and the world's fog are u_air (the AC-0384
	// r8 seam), so the sky just outside the limb must be u_air too -
	// otherwise the seam keeps a visible step: AC-0422 softened the branch
	// SWITCH (the 0.03 blend) but the two branch COLOURS still differed by
	// the horizon/u_air gap (223,246,251 vs 208,241,251 at T = 0.5), which
	// reads as a line across the frame at altitude. At w = 0 (ground) the
	// anchor is horizon_color exactly (the daytime sky is untouched); the
	// u_horizon gate keeps the OFF path bit-for-bit.
	vec3 horizon_eff = mix(horizon_color, u_air, w * u_horizon);
	// AC-0429: the gradient's horizon ANCHOR - the sky's lower edge -
	// fades to SPACE (not u_air) as ws opens: the anchor and the below
	// branch (belowc) mix toward space with the SAME ws, so the colour
	// at hl = 0 stays continuous for every w (|seam| =
	// |horizon - u_air| * (1-ws) - the pre-existing ground-level seam
	// order, 0 from ws = 1): no line, no band; from ws = 1 the sky
	// simply IS space at the local horizon - the lower boundary is gone,
	// not smoothed. At w = 0, ws = 0 and the mix returns horizon_eff
	// exactly (the ground daytime sky, bit-for-bit); u_no_floor = 0
	// keeps horizon_eff verbatim (the pre-ticket path).
	vec3 anchor = mix(horizon_eff, mix(horizon_color, space_color, ws), u_no_floor);
	vec3 grad = mix(anchor, mid_color, smoothstep(0.0, 0.30, u));
	grad = mix(grad, zenith_color, smoothstep(0.25, 0.90, u));
	// above the horizon: the gradient thinned to space by the A window;
	// w = 1 is space exactly at the zenith (the AC-0417 contract).
	// AC-0428 item 2 ("the top of the sky turns into space faster than
	// the rest - the entire sky should transition at the same rate"): the
	// pre-fix weight mix(w*w, w, u) * u was CONVEX in the local elevation
	// (slow near the horizon, fast near the zenith - the change
	// concentrated near the top, the user's screenshot). The fix is w*u -
	// a UNIFORM rate: the u_air -> space transition spreads evenly over
	// the elevation range, still 0 at the horizon (the seam stays one
	// colour, item 1) and w at the zenith (space at A looking up). The
	// OFF path (u_horizon = 0) keeps the pre-AC-0422 weight bit-for-bit.
	float thin = mix(mix(w * w, w, u) * 1.0, w * u, u_horizon);
	vec3 above = mix(grad, space_color, thin);
	vec3 belowc = mix(mix(space_color, u_air, 1.0 - w), u_air, u_horizon);
	// AC-0429: the below branch - the "air floor", the skybox's bottom
	// face - blends to SPACE with ws: below the local horizon the sky is
	// the same black, the same stars as the space above, with no anchor,
	// no band and no fade at the bottom of the sky. The planet and its
	// air (the limb term, the body, the clouds) are the only thing left
	// in the lower frame. u_air survives ONLY at w = 0 (ws = 0 - the
	// ground-level AC-0384 r8 fog seam: the world's fog fades to u_air
	// and the body's rim IS u_air, so the sky beyond must be the same).
	// u_no_floor = 0 keeps the pre-ticket fill verbatim; at w = 0 the
	// mix returns it exactly.
	belowc = mix(belowc, mix(u_air, space_color, ws), u_no_floor);
	vec3 col = mix(above, belowc, below);
	// the horizon haze band (the sky_off term) hugs the local horizon
	// from both sides and dies with the air (it is low-atmosphere
	// scatter - at w = 1 there is no air left to haze).
	// AC-0429: the band is the "air seen edge-on" of the FLOOR - a
	// ground-level phenomenon (at w = 0 the local horizon is the real
	// horizon). At altitude the local horizon is space, so the band must
	// not survive there as a bright line hugging the sky's lower edge:
	// it dies with the floor ((1-ws) - 1 at the ground, 0 from w >= 0.3),
	// on top of the unchanged (1-w) air fade. u_no_floor = 0 is
	// verbatim (mix(1.0, 1.0-ws, 0.0) = 1.0).
	float hz = exp(-abs(hl) * 9.0) * haze_amount * (1.0 - w) * mix(1.0, 1.0 - ws, u_no_floor);
	col = mix(col, haze_color, hz);
	// the limb term - the atmosphere's edge (the normalized air column,
	// see the function header). u_limb_radius = 0 (no world yet) turns
	// the term off with the pre-AC-0419 guard shape (b - 0 > 0 always,
	// exp ~ 0 - now: the chord is 0 outside the disc and the disc
	// radius is 0, so the block gate does it).
	if (u_limb_amount > 0.0 && u_limb_radius > 0.0) {
		float lr = (u_atmo_radius > 0.0) ? u_atmo_radius : u_limb_radius;
		if (lr > 0.0) {
			float lf = (u_atmo_falloff > 0.0) ? u_atmo_falloff : 300.0;
			float rout = lr + lf;
			float b = length(cross(u_limb_center, dir));
			// AC-0419 r2: the FORWARD air column through the shell,
			// camera-aware (see the function header). The ray crosses the
			// rout sphere at s = -r*hl + half (half = sqrt(rout^2-b^2),
			// hl = the ray's radial component = the local zenith
			// elevation, +1 straight up). Inside the shell or pointing
			// away, the visible air is that near exit; outside the
			// shell heading in, it is the full chord 2*half. min(2*half,
			// ...) keeps the b >= rout case at 0 (a ray tangent to the
			// tail sweeps no air).
			float half = sqrt(max(0.0, rout * rout - b * b));
			float s_exit = -r * hl + half;
			float air = min(2.0 * half, max(0.0, s_exit));
			float cm = 2.0 * sqrt(max(0.0, rout * rout - u_limb_radius * u_limb_radius));
			float limb = (cm > 0.0) ? min(1.0, air / cm) : 0.0;
			vec3 limb_col = horizon_color * 0.5 + mid_color * 0.5;
			float sun_side = 0.55 + 0.45 * pow(clamp(dot(dir, sun_dir), 0.0, 1.0), 2.0);
			// AC-0401: the rim's altitude gate rides the A window (the
			// sky is space at A, so the rim is too) - the OFF path keeps
			// the AC-0401 physics-S contract. AC-0414 clause 2: the body
			// gate (no fake planet while the body is not LOADED).
			col += limb_col * (limb * u_limb_amount * sun_side * mix(1.0, w, u_limb_gate) * mix(1.0, u_body_loaded, u_limb_loaded));
		}
	}
	float sd = dot(dir, sun_dir);
	float up = clamp(sd, 0.0, 1.0);
	float disc = smoothstep(0.99894, 0.99985, sd) * sun_amount;
	// the sun's GLOW is scattering - it dies with the air; the disc stays.
	// The fade rides the A window on the ON path (the sky is space at A).
	float glow = (pow(up, 24.0) * 0.60 + pow(up, 5.0) * 0.22) * sun_amount * (1.0 - u_space_sky);
	col = col + (sun_core * disc) + (sun_halo * glow);
	return col;
}

void sky() {
	vec3 dir = normalize(EYEDIR);
	vec3 col;
	if (u_sky_alt < 0.5) {
		col = sky_off(dir);
	} else {
		col = sky_on(dir);
	}
	// sky shader COLOR is a vec3 (unlike spatial ALBEDO)
	COLOR = mix(col, pow(col, vec3(2.2)), u_srgb_pre); // AC-0242
}
