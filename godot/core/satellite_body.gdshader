# AC-0310 P2 - the satellite body tier (whole-planet view above the
# atmosphere). One material per face of the 12-face great-circle chart
# (the piece-1 baked 1024^2 per-face textures, unlit: the fixed-sun
# lambert is already in the pixels).
#
# The per-fragment model is the no-pop contract (see AC-0310-results):
#  (1) EXISTENCE: the body is only where the world's depth fog has
#      already fully faded the world (view distance >= u_fog_far), and
#      fully established by the render edge (d >= u_render_edge). The
#      rim therefore emerges exactly as it passes the fog wall, and the
#      body's near region dissolves under the drawn disc on descent.
#  (2) HAZE: a slant path through the air shell - the limb is always
#      hazy, and the distance term hugs the render edge so that just
#      outside the disc's edge (whose fragments are 100% fogged) the
#      body reads as the fog colour itself: continuous across the edge.
#  (3) DAY/NIGHT: the bake is the unlit day appearance; u_day modulates
#      brightness only (the sun direction is not tracked - owed).
#
# Colour domain: sRGB values throughout (the texture bytes, u_air and
# the output are all sRGB-domain, the same convention the aero sky
# shader and the env fog colour use). No linear conversion here.
shader_type spatial;
render_mode cull_back, transparent, depth_draw_always;

uniform sampler2D tex : filter_linear;
uniform float u_fog_far : hint_range(0.0, 20000.0);
uniform float u_render_edge : hint_range(0.0, 20000.0);
uniform float u_clear_dist : hint_range(0.0, 40000.0);
uniform vec4 u_air : hint_color;
uniform float u_day : hint_range(0.0, 2.0);

void fragment() {
	float d = length(VIEW);
	float op = smoothstep(u_fog_far, u_render_edge, d);
	if (op <= 0.001) {
		discard;
	}
	float cosv = clamp(dot(normalize(-VIEW), NORMAL), 0.0, 1.0);
	float haz_a = pow(1.0 - cosv, 2.0);
	float haz_d = 1.0 - smoothstep(u_render_edge, u_clear_dist, d);
	float haz = clamp(haz_a + haz_d, 0.0, 1.0);
	vec3 base = texture(tex, UV).rgb * u_day;
	COLOR = vec4(mix(base, u_air.rgb, haz), op);
}
