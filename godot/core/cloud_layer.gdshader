shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;

// AC-0235: the procedural cloud layer (replaces the clouds that the old
// AeroSky dome painted in view-direction space). A flat quad at CLOUD_H
// follows the player's XZ (MC-style cloud layer); the PATTERN is anchored
// to world XZ, so it parallaxes correctly while the player moves, and
// scrolls by u_wind * u_cloud_time (main.gd advances u_cloud_time each
// frame). Fog is disabled so the layer stays crisp at the horizon (the
// dome clouds were fog_disabled too).
uniform vec2 u_wind = vec2(6.0, 2.0);  // blocks per second of drift
uniform float u_cloud_time = 0.0;
uniform float u_coverage : hint_range(0.0, 1.0) = 0.5;
uniform vec3 u_cloud_tint : source_color = vec3(1.0);
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

float fbm2(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * anv(p);
		p = p * 2.03 + vec2(17.1, 9.2);
		a *= 0.5;
	}
	return v;
}

void fragment() {
	// world-anchored sampling (parallax) + wind scroll
	vec2 p = v_wxz * (1.0 / 26.0) + u_wind * u_cloud_time;
	float n = fbm2(p * 1.3) * 0.65 + fbm2(p * 3.1 + vec2(13.7, 7.3)) * 0.35;
	float lo = mix(0.68, 0.38, u_coverage);
	float cl = smoothstep(lo, lo + 0.22, n);
	// fade the layer boundary so the quad edge never reads as a wall
	vec2 e = abs(v_uv - 0.5) * 2.0;
	float edge = 1.0 - smoothstep(0.86, 1.0, max(e.x, e.y));
	ALBEDO = u_cloud_tint;
	ALPHA = cl * edge;
	ALBEDO = mix(ALBEDO, pow(ALBEDO, vec3(2.2)), u_srgb_pre); // AC-0242
}
