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
	float ws = mix(u_space * u_space, u_space, u);
	col = mix(col, space_color, ws);
	float sd = dot(dir, sun_dir);
	float up = clamp(sd, 0.0, 1.0);
	float disc = smoothstep(0.99894, 0.99985, sd) * sun_amount;
	// the sun's GLOW is scattering - it dies with the air; the disc stays.
	float glow = (pow(up, 24.0) * 0.60 + pow(up, 5.0) * 0.22) * sun_amount * (1.0 - u_space);
	col = col + (sun_core * disc) + (sun_halo * glow);
	// sky shader COLOR is a vec3 (unlike spatial ALBEDO)
	COLOR = mix(col, pow(col, vec3(2.2)), u_srgb_pre); // AC-0242
}
