// AC-0128: unlit web-faithful day/night shading for opaque chunk faces.
// vColor repack (web index.html :736 vColor channels): r = sky channel
// (light scalar s), g = block-light channel (s when the face has block-light
// source evidence within Chebyshev 14 in own-chunk data, else 0), b = face
// shade. Fragment = the web formula verbatim (:746):
//   ALBEDO = tex.rgb * faceShade * (0.12 + 0.88 * max(u_day * r, g))
shader_type spatial;
render_mode unshaded, cull_back;

uniform float u_day : hint_range(0.0, 1.0) = 1.0;
uniform sampler2D tex;
uniform vec3 u_player_pos = vec3(0.0, 0.0, 0.0);
uniform float u_player_light = 0.0;
uniform float u_player_radius = 5.0;
varying vec3 v_world_pos;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec4 t = texture(tex, UV);
	float L = 0.12 + 0.88 * max(u_day * COLOR.r, COLOR.g);
	float pr = clamp(u_player_light - distance(v_world_pos, u_player_pos), 0.0, u_player_radius);
	L = max(L, 0.12 + 0.88 * pr / 15.0);
	ALBEDO = t.rgb * COLOR.b * L;
}
