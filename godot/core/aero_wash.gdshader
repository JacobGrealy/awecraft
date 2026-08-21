shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, fog_disabled;

uniform vec3 wash_color : source_color = vec3(0.4980, 0.9059, 1.0);
uniform float wash_amount : hint_range(0.0, 1.0) = 0.06;
uniform float top_glow : hint_range(0.0, 2.0) = 0.4;

void fog_fragment() {
}

void fragment() {
	float g = UV.y;
	ALBEDO = wash_color * (wash_amount * (1.0 + top_glow * g));
}
