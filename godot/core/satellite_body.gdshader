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
#      AC-0384: both haze inputs and the distance were being evaluated
#      with the wrong BUILTIN SPACES (Godot 4.7.1, verified in the
#      engine source, forward_plus scene_forward_clustered.glsl):
#      the fragment's VIEW is the NORMALIZED fragment->camera
#      direction in VIEW space, so `d = length(VIEW)` was identically
#      1.0 - op was identically 0 and the body discarded EVERY
#      fragment (it never rendered; the user's "white planet" is a
#      different layer, not this body); and the old limb dot mixed a
#      view-space direction with the world-space NORMAL (camera-
#      orientation dependent). Now everything is world space:
#      p_w from INV_VIEW_MATRIX * VERTEX (VERTEX is the view-space
#      position, camera at the origin), cam_w = CAMERA_POSITION_WORLD,
#      d = the true camera distance, cosv = the true fragment->camera
#      / normal angle.
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
	// World-space geometry (AC-0384 - the builtin spaces, verified in
	// the 4.7.1 engine source): VERTEX here is the fragment's VIEW-space
	// position (the camera sits at the origin), so INV_VIEW_MATRIX takes
	// it to world; CAMERA_POSITION_WORLD is the camera in world space;
	// NORMAL is world space (the body is translation-only). The old
	// `d = length(VIEW)` was identically 1.0 (VIEW is a unit vector) -
	// see the header note: the body discarded every fragment.
	vec3 p_w = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 cam_w = CAMERA_POSITION_WORLD;
	float d = length(p_w - cam_w);
	float op = smoothstep(u_fog_far, u_render_edge, d);
	if (op <= 0.001) {
		discard;
	}
	// The limb term, in world space: (1 - cosv) is a monotone function
	// of the ray's impact parameter (perpendicular distance from the
	// planet centre to the view ray) - 0 at the disc centre (b = 0, the
	// ray's shortest path through the air shell) and 1 at the limb
	// (b = the body radius, the grazing ray's longest path).
	float cosv = clamp(dot(normalize(cam_w - p_w), NORMAL), 0.0, 1.0);
	float haz_a = pow(1.0 - cosv, 2.0);
	// The proximity term hugs the render edge: just outside the disc's
	// edge the fragments are 100% fogged, so the body must read as the
	// fog colour there (continuous across the edge), and on descent the
	// near region dissolves to the air colour under the drawn disc.
	float haz_d = 1.0 - smoothstep(u_render_edge, u_clear_dist, d);
	float haz = clamp(haz_a + haz_d, 0.0, 1.0);
	float sun_l = clamp(dot(u_sun, NORMAL) * INV_BAKE_SUN_RADIAL, 0.0, 1.0);
	vec3 base = texture(tex, UV).rgb * (u_day - u_day_gain * (1.0 - sun_l));
	COLOR = vec4(mix(base, u_air.rgb, haz), op);
}
