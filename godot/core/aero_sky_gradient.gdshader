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

void sky() {
	vec3 dir = normalize(EYEDIR);
	float h = dir.y;
	float u = clamp(h, 0.0, 1.0);
	vec3 col = mix(horizon_color, mid_color, smoothstep(0.0, 0.30, u));
	col = mix(col, zenith_color, smoothstep(0.25, 0.90, u));
	if (h < 0.0) {
		col = mix(col, horizon_color * 0.5, clamp(-h * 2.0, 0.0, 1.0));
	}
	float hz = exp(-abs(h) * 9.0) * haze_amount;
	col = mix(col, haze_color, hz);
	// AC-0386: the atmosphere thins with the radial altitude. The zenith
	// darkens first (weight S), the horizon last (weight S^2 - the grazing
	// column of air keeps its blue longest). S = 0 is bit-identical to the
	// pre-AC-0386 sky; S = 1 makes the whole dome space.
	// AC-0402: with u_sky_alt = 0 this is exactly the pre-AC-0402 ws
	// (mix(x, y, 0.0) = x); with it ON the background rides the stretched
	// sky window u_space_sky (see the uniform's note).
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
		// AC-0414 clause 2: multiply by the body-loaded gate (see the
		// u_limb_loaded/u_body_loaded note) - the fake-planet disc is
		// gone while the body is not LOADED, exactly 1.0 when the switch
		// is OFF or the body is loaded.
		col += limb_col * (limb * u_limb_amount * sun_side * mix(1.0, u_space, u_limb_gate) * mix(1.0, u_body_loaded, u_limb_loaded));
	}
	float sd = dot(dir, sun_dir);
	float up = clamp(sd, 0.0, 1.0);
	float disc = smoothstep(0.99894, 0.99985, sd) * sun_amount;
	// the sun's GLOW is scattering - it dies with the air; the disc stays.
	float glow = (pow(up, 24.0) * 0.60 + pow(up, 5.0) * 0.22) * sun_amount * (1.0 - u_space);
	col = col + (sun_core * disc) + (sun_halo * glow);
	// sky shader COLOR is a vec3 (unlike spatial ALBEDO)
	COLOR = mix(col, pow(col, vec3(2.2)), u_srgb_pre); // AC-0242
}
