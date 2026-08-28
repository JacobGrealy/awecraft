// AC-0128: unlit web-faithful day/night shading for cross (flower) quads.
// Same vColor repack + formula as chunk_lit_opaque.gdshader, plus the
// alpha discard + cull_disabled (web :740 cross path, two-sided).
shader_type spatial;
render_mode unshaded, cull_disabled, alpha_scissor;

uniform float u_day : hint_range(0.0, 1.0) = 1.0;
uniform sampler2D tex;

void fragment() {
	vec4 t = texture(tex, UV);
	if (t.a < 0.5) discard;
	float L = 0.12 + 0.88 * max(u_day * COLOR.r, COLOR.g);
	ALBEDO = t.rgb * COLOR.b * L;
}
