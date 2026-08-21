shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;

uniform vec3 zenith_color : source_color = vec3(0.1804, 0.5255, 0.8471);
uniform vec3 mid_color : source_color = vec3(0.3725, 0.7765, 0.9176);
uniform vec3 horizon_color : source_color = vec3(0.8745, 0.9647, 0.9843);
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.2);
uniform vec3 sun_core : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 sun_halo : source_color = vec3(1.0, 0.9647, 0.8706);
uniform float sun_amount : hint_range(0.0, 4.0) = 1.0;
uniform vec3 cloud_color : source_color = vec3(1.0, 1.0, 1.0);
uniform float cloud_amount : hint_range(0.0, 1.0) = 0.55;
uniform vec3 haze_color : source_color = vec3(0.7294, 0.9137, 0.9804);
uniform float haze_amount : hint_range(0.0, 1.0) = 0.35;
uniform vec3 cam_pos = vec3(0.0, 0.0, 0.0);

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
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
	vec3 dir = normalize(wpos - cam_pos);
	float h = dir.y;
	float u = clamp(h, 0.0, 1.0);
	vec3 col = mix(horizon_color, mid_color, smoothstep(0.0, 0.30, u));
	col = mix(col, zenith_color, smoothstep(0.25, 0.90, u));
	if (h < 0.0) {
		col = mix(col, horizon_color * 0.5, clamp(-h * 2.0, 0.0, 1.0));
	}
	float hz = exp(-abs(h) * 9.0) * haze_amount;
	col = mix(col, haze_color, hz);
	float sd = dot(dir, sun_dir);
	float up = clamp(sd, 0.0, 1.0);
	float disc = smoothstep(0.99894, 0.99985, sd) * sun_amount;
	float glow = (pow(up, 24.0) * 0.60 + pow(up, 5.0) * 0.22) * sun_amount;
	col = col + (sun_core * disc) + (sun_halo * glow);
	if (h > 0.015) {
		vec2 cp = dir.xz / max(h, 0.18);
		cp = cp * 0.5 + vec2(TIME * 0.011, TIME * 0.004);
		float n = fbm2(cp * 1.3) * 0.65 + fbm2(cp * 3.1 + vec2(13.7, 7.3)) * 0.35;
		float cl = smoothstep(0.46, 0.70, n) * cloud_amount * smoothstep(0.015, 0.14, h);
		vec3 cc = mix(cloud_color, haze_color, 0.25);
		col = mix(col, cc, cl);
	}
	ALBEDO = col;
}
