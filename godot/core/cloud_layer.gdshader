shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;

// AC-0235: the procedural cloud layer (replaces the clouds that the old
// AeroSky dome painted in view-direction space). A flat quad at CLOUD_H
// follows the player's XZ (MC-style cloud layer); the PATTERN is anchored
// to world XZ, so it parallaxes correctly while the player moves, and
// scrolls by u_wind * u_cloud_time (main.gd advances u_cloud_time each
// frame). Fog is disabled so the layer stays crisp at the horizon (the
// dome clouds were fog_disabled too).
// AC-0235 retest 3/4: the layer is now MULTI (main.gd builds 3 quads at
// different heights, each with its own u_scale feature size, u_wind drift
// speed and coverage multiplier) - height/size/speed vary per layer like
// a real cloud deck. u_wind default = the top layer (the slowest).
uniform vec2 u_wind = vec2(0.005, 0.002);  // blocks per second of drift (top-layer default; main.gd sets a per-layer wind - retest 6: graded slow, top essentially static)
uniform float u_cloud_time = 0.0;
uniform float u_coverage : hint_range(0.0, 1.0) = 0.5;
uniform vec3 u_cloud_tint : source_color = vec3(1.0);
// AC-0235 retest 5: pattern cell size in BLOCKS (bigger = bigger features).
// Per layer: 256 (top), 160 (mid), 110 (low).
uniform float u_scale = 0.00390625;  // 1/256 - shader uniform defaults must be constant literals
// AC-0242: unshaded output needs the compat pre-decode like the chunks.
uniform float u_srgb_pre : hint_range(0.0, 1.0) = 0.0;

varying vec2 v_uv;
varying vec2 v_wxz;  // world XZ (spatial shaders have no WORLD_POSITION builtin)

void vertex() {
	v_uv = UV;
	v_wxz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fog_fragment() {
}

float ahash(vec2 p) {
	p = fract(p * vec2(234.34, 435.345));
	p += dot(p, p + 34.23);
	return fract(p.x * p.y);
}

float anv(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = ahash(i);
	float b = ahash(i + vec2(1.0, 0.0));
	float c = ahash(i + vec2(0.0, 1.0));
	float d = ahash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// AC-0235 retest 5: 5 octaves (was 4) - the extra octave is what smooths
// the blocky aliased edges the user saw (the pattern cell is coarse; the
// sub-detail had to be finer to round the lobes).
float fbm2(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * anv(p);
		p = p * 2.03 + vec2(17.1, 9.2);
		a *= 0.5;
	}
	return v;
}

void fragment() {
	// world-anchored sampling (parallax) + wind scroll.
	// AC-0235 retest 5: three frequencies blended (base lobe + mid detail +
	// fine grain) instead of two - the fine octave dissolves the flat
	// stepped edges into soft billowy contours. The coverage window stays
	// on the base lobe so the FRACTION of sky covered does not drift as
	// the detail octaves shift.
	vec2 p = v_wxz * u_scale + u_wind * u_cloud_time;
	float base = fbm2(p * 1.3);
	float mid = fbm2(p * 2.2 + vec2(13.7, 7.3));
	float fine = fbm2(p * 4.1 + vec2(71.3, 33.9));
	float n = base * 0.55 + mid * 0.30 + fine * 0.15;
	float cl = smoothstep(0.62, 0.88, base);
	cl = smoothstep(0.0, 0.55, cl) * cl;
	cl *= 0.75 + 0.25 * (0.55 * base + 0.45 * mid);
	// fade the layer boundary so the quad edge never reads as a wall
	vec2 e = abs(v_uv - 0.5) * 2.0;
	float edge = 1.0 - smoothstep(0.86, 1.0, max(e.x, e.y));
	ALBEDO = u_cloud_tint;
	ALPHA = cl * edge * u_coverage;
	ALBEDO = mix(ALBEDO, pow(ALBEDO, vec3(2.2)), u_srgb_pre); // AC-0242
}
