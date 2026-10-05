shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;
// (the dummy/headless renderer rejects `transparent` and logs a
// SHADER ERROR - the same accepted condition satellite_body.gdshader
// has lived with since AC-0310; the shipped forward_plus compiles it.)

// AC-0235: the procedural cloud layer (replaces the clouds that the old
// AeroSky dome painted in view-direction space). AC-0385: the layer is now
// a SPHERICAL SHELL around the planet (three concentric SphereMeshes at
// R + 275 / 330 / 400, centred at (0, -R, 0) - the same altitudes the old
// quads hovered at) instead of three flat 6144/5120/4096-block quads that
// followed the player's XZ. From orbit the old quads read as sparse puffs
// on a flat sheet (3.1-5.7% of the planet disc had day alpha > 0.2 at any
// altitude - tasks/AC-0385/AC-0385-results.html); the shell wraps the
// planet (67.8% of the globe, even across latitude bands).
// The PATTERN is still world-anchored: it is sampled on the unit direction
// from the planet centre, so it parallaxes correctly and scrolls by a
// rotation about world Y (u_drift * u_cloud_time; main.gd advances
// u_cloud_time each frame and derives u_drift from the old per-layer wind,
// so the drift speeds are the old ones in blocks/sec, now angular).
// The feature sizes stay in BLOCKS (u_scale3 = 2*pi*(R+h)/feature is set
// by main.gd per layer). Fog stays disabled (depth fog is tuned for the
// local 238-714 m band; a 4300 m shell would be erased by it).
// AC-0385 coverage: the old window smoothstep(0.62, 0.88, base) sat 1.3
// std above the fbm mean (0.485, std 0.107) - that is what made the puffs
// sparse. The window is now 0.50-0.58 (+0.14 to +0.79 std) and the fine
// octave modulates the alpha (in AC-0235 it was computed into `n` and
// never used). Day coverage is 67.8% of the globe at alpha > 0.2 (bands
// 66.6-68.3%; longest clear streak p95 7.2 deg), night 37.3%.
// AC-0385 lighting: lit by the SAME DayNight.sun_direction convention
// AC-0382 wired into the satellite body (u_sun = direction TO the sun;
// u_day = 0.18 + 0.82*day; u_day_gain = 0.82*day - the satellite's exact
// uniform set, pushed per frame by main.gd). Lighting multiplies the
// ALBEDO, never the ALPHA - the weather coverage is a function of world
// direction and time-of-day only, so the shell can never pop as the
// player moves or climbs (the no-pop argument at the satellite body's
// emergence). The grazing fade thins the mass to the silhouette, where
// the body's own limb haze is strongest (no double-counted white rim).
// AC-0384 r6: the NMS read - thick, banded, OCCLUDING decks with visible
// depth and darker undersides, from orbit AND from below/inside the
// layer. Changes vs r5: (1) cull_back -> cull_disabled + fragment-stage
// cull emulation (the rasterizer cull killed the whole underside view;
// with cull off the far side would draw through the near side in the
// transparent pass, so back faces are discarded only while the camera is
// outside the shell - the orbit view is unchanged by construction);
// (2) broad warped latitude bands modulate the alpha (NMS banding);
// (3) a soft bimodal contrast window (0.05/0.80) turns the haze/clear
// split into thin veil vs opaque cores; (4) u_boost 2.0 clamps the dense
// cores to full opacity (occlusion); (5) darker undersides - the albedo
// darkens with optical thickness (u_under 0.70).
uniform vec3 u_center = vec3(0.0, -4000.0, 0.0);  // planet centre (main.gd)
uniform float u_scale3 = 107.92;  // 2*pi*(R+h)/feature, per layer (main.gd)
uniform float u_drift = 0.00122;  // rad/s about world Y, per layer (main.gd)
uniform float u_cloud_time = 0.0;
uniform float u_coverage : hint_range(0.0, 1.0) = 0.5;
uniform vec3 u_cloud_tint : source_color = vec3(1.0);
uniform vec3 u_sun = vec3(0.0, 1.0, 0.0);
uniform float u_day : hint_range(0.0, 2.0) = 1.0;
uniform float u_day_gain : hint_range(0.0, 2.0) = 0.82;
// AC-0242: unshaded output needs the compat pre-decode like the chunks.
uniform float u_srgb_pre : hint_range(0.0, 1.0) = 0.0;
// AC-0384 r5: screen scale for the noise field's distance LOD (px per
// radian at the current window size and camera fov). main.gd pushes it
// per frame; the default is the 1280x720 harness window (720 /
// (2*tan(37.5 deg)) - the 75 deg camera fov).
uniform float u_cpxrad : hint_range(50.0, 4000.0) = 476.0;
// AC-0384 r6: opacity boost - the dense cores clamp to 1.0 (the deck
// occludes the sky/terrain behind it, the NMS "thick cloud" read).
uniform float u_boost : hint_range(0.0, 4.0) = 2.0;
// AC-0384 r6: underside darkening - the albedo of an optically thick
// fragment is multiplied by u_under (the thinner the patch, the closer
// to 1.0 - the full sun-lit albedo).
uniform float u_under : hint_range(0.0, 1.0) = 0.70;

varying vec3 v_wp;  // world position (spatial shaders have no WORLD_POSITION builtin)

void vertex() {
	v_wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fog_fragment() {
}

float ahash(vec3 p) {
	p = fract(p * vec3(234.34, 435.345, 341.345));
	p += dot(p, p + 34.23);
	return fract(p.x * p.y * p.z);
}

float anv(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float c000 = ahash(i);
	float c100 = ahash(i + vec3(1.0, 0.0, 0.0));
	float c010 = ahash(i + vec3(0.0, 1.0, 0.0));
	float c110 = ahash(i + vec3(1.0, 1.0, 0.0));
	float c001 = ahash(i + vec3(0.0, 0.0, 1.0));
	float c101 = ahash(i + vec3(1.0, 0.0, 1.0));
	float c011 = ahash(i + vec3(0.0, 1.0, 1.0));
	float c111 = ahash(i + vec3(1.0, 1.0, 1.0));
	float x00 = mix(c000, c100, f.x);
	float x10 = mix(c010, c110, f.x);
	float x01 = mix(c001, c101, f.x);
	float x11 = mix(c011, c111, f.x);
	return mix(mix(x00, x10, f.y), mix(x01, x11, f.y), f.z);
}

// 5 octaves, same structure as the old 2-D fbm (AC-0235 retest 5).
float fbm(vec3 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * anv(p);
		p = p * 2.03 + vec3(17.1, 9.2, 4.7);
		a *= 0.5;
	}
	return v;
}

void fragment() {
	// World-anchored direction from the planet centre (parallax + wrap).
	vec3 n = normalize(v_wp - u_center);
	// Wind drift: rotate the sampling direction about world Y. The old
	// 2-D wind was a translation; on the sphere the equivalent is a
	// rotation (east-west drift, polar stagnation for free).
	float ang = u_drift * u_cloud_time;
	float ca = cos(ang);
	float sa = sin(ang);
	vec3 dr = vec3(ca * n.x + sa * n.z, n.y, -sa * n.x + ca * n.z);
	vec3 q = dr * u_scale3;
	// AC-0384 r5: distance LOD for the noise field (the round-4 "near-
	// disc static"). fbm() is 5 octaves (2.03x), so a band with
	// multiplier m has its finest octave at argument scale u_scale3*m*
	// 2.03^4; on this shell (radius R_sh) that is a world feature of
	// R_sh/(u_scale3*m*2.03^4), i.e. that/d_cam * u_cpxrad px on
	// screen. Below ~2.5 px the per-fragment white noise aliases into
	// the salt-and-pepper static (measured, 2600 m, same 400x400 box:
	// grain 23.2 clouds-ON vs 0.81 clouds-OFF - the static is this
	// field, not the body's texture). Each band is clamped so its
	// finest octave stays >= 2.5 px; at ground view the factors are
	// 1.0 (the finest octaves there are >= 1.8 px and low-contrast).
	float d_cam = max(length(CAMERA_POSITION_WORLD - v_wp), 1.0);
	float R_sh = length(v_wp - u_center);
	float px13 = R_sh * u_cpxrad / (u_scale3 * 1.3 * 16.974 * d_cam);
	float px22 = R_sh * u_cpxrad / (u_scale3 * 2.2 * 16.974 * d_cam);
	float px41 = R_sh * u_cpxrad / (u_scale3 * 4.1 * 16.974 * d_cam);
	float l13 = min(px13 / 2.5, 1.0);
	float l22 = min(px22 / 2.5, 1.0);
	float l41 = min(px41 / 2.5, 1.0);
	// Three frequencies, as in AC-0235 retest 5 - now in 3-D so the
	// pattern is continuous over the whole globe (no UV seam, no flat
	// projection).
	float base = fbm(q * 1.3 * l13);
	float mid = fbm(q * 2.2 * l22 + vec3(13.7, 7.3, 5.9));
	float fine = fbm(q * 4.1 * l41 + vec3(71.3, 33.9, 21.7));
	// AC-0385: coverage window 0.50-0.58 (was 0.62-0.88 - see header).
	float cl = smoothstep(0.50, 0.58, base);
	cl = smoothstep(0.0, 0.55, cl) * cl;
	cl *= 0.75 + 0.25 * (0.55 * base + 0.45 * mid);
	cl *= 0.85 + 0.15 * fine;
	// AC-0384 r6: broad warped latitude bands - large-scale weather
	// structure (the NMS deck is banded, not uniform). The band follows
	// the drift-rotated direction so it scrolls with the weather.
	float band = 0.5 + 0.5 * sin(dr.y * 11.0 + 2.2 * base);
	cl *= mix(0.5, 1.0, smoothstep(0.18, 0.82, band));
	// AC-0384 r6: soft bimodal contrast - the haze reads as a thin veil
	// and the cores as opaque masses (wide window 0.05/0.80; the first
	// pass 0.16/0.58 steepened the edges and raised the orbit grain).
	cl = smoothstep(0.05, 0.80, cl);
	// Grazing fade: thin the mass where the shell is seen edge-on, so the
	// silhouette stays clean where the satellite body's own limb haze is
	// strongest (no double white rim at the limb from orbit). AC-0384 r6:
	// abs() - the same fade applies to the underside view from inside.
	vec3 V = normalize(CAMERA_POSITION_WORLD - v_wp);
	float ndv = dot(n, V);
	float graze = smoothstep(0.02, 0.18, abs(ndv));
	// AC-0384 r6: occluding cores - the dense cores clamp to full opacity
	// (u_boost 2.0), so the deck hides the sky and the terrain behind it.
	float a = clamp(cl * u_coverage * u_boost, 0.0, 1.0);
	// AC-0384 r6: fragment-stage cull emulation. cull_disabled is
	// required to see the shell from inside (the rasterizer cull with
	// cull_back discarded the whole underside), but with cull off the
	// far side of the shell would draw through the near side (the
	// transparent pass keeps no depth). Discard the back faces only
	// while the camera is OUTSIDE this shell: the orbit view is exactly
	// the r5 view, and the underside renders when the camera is inside.
	float cam_out = step(R_sh, length(CAMERA_POSITION_WORLD - u_center));
	if (cam_out > 0.5 && ndv < 0.0) {
		discard;
	}
	ALPHA = a * graze;
	// AC-0382 sun convention (the satellite body's exact uniform set):
	// u_sun is the direction TO the sun, the light travels along
	// DayNight.sun_direction. Noon (sun_l=1) is unchanged; the night
	// floor 0.18 matches the satellite's pre-AC-0382 night.
	float sun_l = clamp(dot(n, u_sun), 0.0, 1.0);
	float light = u_day - u_day_gain * (1.0 - sun_l);
	// AC-0384 r6: darker undersides - the optically thicker the patch
	// (the final alpha a), the less light leaks through it.
	ALBEDO = u_cloud_tint * light * mix(1.0, u_under, a);
	ALBEDO = mix(ALBEDO, pow(ALBEDO, vec3(2.2)), u_srgb_pre); // AC-0242
}
