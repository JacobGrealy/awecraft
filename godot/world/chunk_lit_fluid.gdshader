// AC-0128: unlit day/night shading for thin-cross fluid-kind
// blocks (torch / glowstone cross), which ride the "fluid" material slot.
// Same vColor repack + formula as chunk_lit_opaque.gdshader, plus the
// current 0.62 alpha (StandardMaterial3D albedo alpha 0.62 in
// _fluid_material) so the look is preserved.
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
	float L = 0.20 + 0.80 * max(u_day * COLOR.r, COLOR.g);
	float pr = clamp(u_player_light - distance(v_world_pos, u_player_pos), 0.0, u_player_radius);
	L = max(L, 0.12 + 0.88 * pr / 15.0);
	ALBEDO = t.rgb * COLOR.b * L;
	ALPHA = 0.62 * t.a;
}
