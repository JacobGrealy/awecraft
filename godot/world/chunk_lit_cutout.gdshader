// AC-0128: unlit web-faithful day/night shading for cutout (leaves) faces.
// Same vColor repack + formula as chunk_lit_opaque.gdshader, plus the
// alpha-scissor discard (web :740 cutout path, threshold 0.5).
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
	if (t.a < 0.5) discard;
	float L = 0.12 + 0.88 * max(u_day * COLOR.r, COLOR.g);
	float pr = clamp(u_player_light - distance(v_world_pos, u_player_pos), 0.0, u_player_radius);
	L = max(L, 0.12 + 0.88 * pr / 15.0);
	ALBEDO = t.rgb * COLOR.b * L;
}
