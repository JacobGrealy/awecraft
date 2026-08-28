// AC-0128: unlit web-faithful day/night shading for thin-cross fluid-kind
// blocks (torch / glowstone cross), which ride the "fluid" material slot.
// Same vColor repack + formula as chunk_lit_opaque.gdshader, plus the
// current 0.62 alpha (StandardMaterial3D albedo alpha 0.62 in
// _fluid_material) so the look is preserved.
shader_type spatial;
render_mode unshaded, cull_back, transparent;

uniform float u_day : hint_range(0.0, 1.0) = 1.0;
uniform sampler2D tex;

void fragment() {
	vec4 t = texture(tex, UV);
	float L = 0.12 + 0.88 * max(u_day * COLOR.r, COLOR.g);
	ALBEDO = t.rgb * COLOR.b * L;
	ALPHA = 0.62 * t.a;
}
