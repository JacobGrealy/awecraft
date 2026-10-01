# AC-0310 P2 - the satellite body tier (whole-planet view above the
# atmosphere). One material per face of the 12-face great-circle chart
# (the piece-1 baked 1024^2 per-face textures; the bake carries the
# piece-1 fixed-sun lambert in the pixels - (3) below).
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
#  (3) DAY/NIGHT (AC-0382 - the moving sun): the baked pixels carry the
#      piece-1 FIXED-sun lambert. Its dominant term is the dot of the
#      fragment's RADIAL direction with the bake sun - constant for
#      EVERY fragment (the chart's local radial axis,
#      L_RADIAL = 1/sqrt(1.2) = the LY component of the bake sun), so
#      the baked brightness is re-weighted by the ratio
#          sun_l = clamp(dot(u_sun, NORMAL) / L_RADIAL, 0, 1)
#      where u_sun is the world's ACTUAL direction-to-sun - the
#      DayNight.sun_direction convention the flat world's
#      DirectionalLight3D uses (the light travels along sun_direction,
#      so the sun sits at -sun_direction; main.gd pushes the same
#      vector). The factor
#          u_day - u_day_gain * (1 - sun_l)
#      equals u_day at sun_l = 1 (the noon appearance is unchanged) and
#      the 0.18 night floor at sun_l = 0, so the terminator now moves
#      with the world's sun while the per-texel slope modulation stays
#      baked (frozen at the piece-1 fixed sun - the minor term). At
#      night u_day_gain = 0 (DayNight.day = 0) -> the flat 0.18 floor,
#      exactly the pre-AC-0382 night. No re-bake per sun position and no
#      new texture channel: the ratio is exact for the radial term,
#      which is the one that moves the terminator.
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
uniform float u_day_gain : hint_range(0.0, 2.0);
// direction FROM the surface TO the sun. World frame == body-local
// frame (the body carries translation only, no rotation), so the dot
// against the local-space NORMAL is the world-space sun lambert.
uniform vec3 u_sun;

const float INV_BAKE_SUN_RADIAL = 1.09544512; // sqrt(1.2) = 1 / L_RADIAL

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
	float sun_l = clamp(dot(u_sun, NORMAL) * INV_BAKE_SUN_RADIAL, 0.0, 1.0);
	vec3 base = texture(tex, UV).rgb * (u_day - u_day_gain * (1.0 - sun_l));
	COLOR = vec4(mix(base, u_air.rgb, haz), op);
}
