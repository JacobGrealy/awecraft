// AC-0310 P2 - the satellite body tier (whole-planet view above the
// atmosphere). One material per face of the 12-face great-circle chart
// (the piece-1 baked 1024^2 per-face textures; the bake carries the
// piece-1 fixed-sun lambert in the pixels - (3) below).
//
// The per-fragment model is the no-pop contract (see AC-0310-results):
//  (1) EXISTENCE: the body is only where the world's depth fog has
//      already fully faded the world (view distance >= u_fog_far), and
//      fully established by the render edge (d >= u_render_edge). The
//      rim therefore emerges exactly as it passes the fog wall, and the
//      body's near region dissolves under the drawn disc on descent.
//  (2) HAZE: two terms, each doing ONE job with its own driver
//      (AC-0390 separated them - see the fragment-stage note):
//      (a) haz_a - the LIMB haze, driven by the ray's path length
//          through the air shell (the impact parameter): the limb is
//          always hazy at EVERY render distance, and because the limb
//          is where the disc meets the 100% fogged world, this term is
//          also what keeps the edge continuous.
//      (b) haz_d - the EDGE-CONTINUITY term, the only distance term:
//          the complement of the existence ramp, 1 while the fragment
//          still sits at/inside the world's fog window [u_fog_far,
//          u_render_edge] (where the world renders as the fog colour)
//          and 0 once it is fully established (d >= u_render_edge) -
//          at every render distance by construction.
//      AC-0384: both haze inputs and the distance were being evaluated
//      with the wrong BUILTIN SPACES (Godot 4.7.1, verified in the
//      engine source, forward_plus scene_forward_clustered.glsl):
//      the fragment's VIEW is the NORMALIZED fragment->camera
//      direction in VIEW space, so `d = length(VIEW)` was identically
//      1.0 - op was identically 0 and the body discarded EVERY
//      fragment (it never rendered; the user's "white planet" is a
//      different layer, not this body); and the old limb dot mixed a
//      view-space direction with the world-space NORMAL (camera-
//      orientation dependent). Now everything is world space:
//      p_w from INV_VIEW_MATRIX * VERTEX (VERTEX is the view-space
//      position, camera at the origin), cam_w = CAMERA_POSITION_WORLD,
//      d = the true camera distance, cosv = the true fragment->camera
//      / normal angle.
//  (3) DAY/NIGHT (AC-0382 - the moving sun): the baked pixels carry the
//      piece-1 FIXED-sun lambert. Its dominant term is the dot of the
//      fragment's RADIAL direction with the bake sun - constant for
//      EVERY fragment (the chart's local radial axis,
//      L_RADIAL = 1/sqrt(1.2) = the LY component of the bake sun), so
//      the baked brightness is re-weighted by the ratio
//          sun_l = clamp(dot(u_sun, NORMAL) / L_RADIAL, 0, 1)
//      where u_sun is the world's ACTUAL direction-to-sun - the
//      DayNight.sun_direction convention the flat world's
//      DirectionalLight3D uses (the light travels along sun_direction,
//      so the sun sits at -sun_direction; main.gd pushes the same
//      vector). The factor
//          u_day - u_day_gain * (1 - sun_l)
//      equals u_day at sun_l = 1 (the noon appearance is unchanged) and
//      the 0.18 night floor at sun_l = 0, so the terminator now moves
//      with the world's sun while the per-texel slope modulation stays
//      baked (frozen at the piece-1 fixed sun - the minor term). At
//      night u_day_gain = 0 (DayNight.day = 0) -> the flat 0.18 floor,
//      exactly the pre-AC-0382 night. No re-bake per sun position and no
//      new texture channel: the ratio is exact for the radial term,
//      which is the one that moves the terminator.
//
// Colour domain (AC-0411): the baked face bytes are sRGB-COMPANDED (the
// bake's _l2s; a 71%-grass disc centre reads (55,104,34) in the face
// PNG) but the texture upload is a LINEAR-format texture (ImageTexture.
// create_from_image, no sRGB flag), so the sampler returns them as-is
// and the Forward+ pipeline sRGB-encodes ALBEDO again at the output -
// a double companding: the daylit disc's flat pale-cyan wash where
// green is expected (the user's "plain white ball", the fourth
// attribution of that symptom). The AC-0242 round-trip applies to the
// terrain term only: the shader pre-decodes it (pow 2.2, gated by
// u_srgb_pre, 1.0 on Forward+) so the output encode round-trips the
// bake. u_air is the one already-linear input (Aero.fog_display is
// srgb_to_linear'd) and stays as-is; the ALBEDO mix is therefore
// linear-domain, exactly like the annulus (lod_avg.gdshader), the one
// far material that reads correctly from orbit.
shader_type spatial;
// AC-0384 r3: fog_disabled - the body's own op/haz model IS the fog-wall
// bridge: existence ramps over the world's fog window and haz_d mixes the
// rim toward u_air (== env.fog_light_color) exactly where the world is
// 100% fog colour (header items (1) and (2)(b)). With the engine env fog
// still applied, every fragment beyond fog_depth_end is repainted fog
// colour by the engine - the established disc is erased and the user
// sees a featureless fog-colour ball with only the fog_disabled cloud
// shell as detail (the cloud shader carries the same flag, its comment
// naming this exact failure for the 4300 m shell). This flag is the
// designed state, not a workaround: below the fog wall the body's
// fragments are discarded by `op` anyway, so no double-fog is possible.
render_mode cull_back, depth_draw_always, fog_disabled;

uniform sampler2D tex : filter_linear;
uniform float u_fog_far : hint_range(0.0, 20000.0);
uniform float u_render_edge : hint_range(0.0, 20000.0);
uniform vec4 u_air : source_color;
uniform float u_day : hint_range(0.0, 2.0);
uniform float u_day_gain : hint_range(0.0, 2.0);
// direction FROM the surface TO the sun. World frame == body-local
// frame (the body carries translation only, no rotation), so the dot
// against the local-space NORMAL is the world-space sun lambert.
uniform vec3 u_sun;
// AC-0411: the AC-0242 sRGB round-trip switch (1.0 on Forward+, 0.0 on
// gl_compatibility) - pushed by satellite_body.gd, the same value
// main.gd pushes to the other sRGB-domain materials.
uniform float u_srgb_pre : hint_range(0.0, 1.0) = 0.0;

const float INV_BAKE_SUN_RADIAL = 1.09544512; // sqrt(1.2) = 1 / L_RADIAL

void vertex() {
	// AC-0401: radius ordering with a real gap. The displaced surface is the
	// SAME terrain the near tiers (band A + the annulus) draw at full
	// resolution, so wherever they coexist (terrain relief straddling the
	// fog wall) coplanar surfaces z-fought - the user's flicker between
	// the clouds, the low LOD and the satellite LOD. The body now sits 2 m
	// radially INSIDE the displaced surface (VERTEX is radial by
	// construction: the mesh origin is the sphere centre, the node is the
	// planet centre), so the near tiers always win the depth test where
	// they overlap and the body never flickers over them. The 2 m is
	// sub-degree at every render altitude (0.028 deg at R4000) and does
	// not move the fog-wall contract (the op window is untouched); the
	// star-occlusion radius (R + SEA, the star shader) is a separate home.
	VERTEX -= normalize(VERTEX) * 2.0;
}

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
	// TERM 1 - haz_a: the LIMB haze (the disc's edge is always hazy).
	// In world space: (1 - cosv) is a monotone function of the ray's
	// IMPACT PARAMETER (perpendicular distance from the planet centre
	// to the view ray - the path length through the air shell): 0 at
	// the disc centre (b = 0, the shortest path) and 1 at the limb
	// (b = the body radius, the grazing ray's longest path). This is
	// the physically right driver for the limb, and it is INDEPENDENT
	// of the render distance: no matter how short the fog is set, the
	// limb is fully hazy, which is what keeps the disc's edge
	// continuous with the 100% fogged world just outside it.
	float cosv = clamp(dot(normalize(cam_w - p_w), NORMAL), 0.0, 1.0);
	float haz_a = pow(1.0 - cosv, 2.0);
	// TERM 2 - haz_d: the EDGE-CONTINUITY term - the only distance
	// term. It is the complement of the existence ramp (op above): 1
	// while the fragment still sits at/inside the world's own fog
	// window [u_fog_far, u_render_edge] (there the world renders as
	// the fog colour, so the body must too - no pop at the fog wall or
	// the disc's emerging edge) and 0 once it is fully established
	// (d >= u_render_edge). Its window IS the world's fog window, so
	// the continuity holds at EVERY render distance by construction.
	// AC-0390: the old window was [u_render_edge, 4*u_render_edge] -
	// it lingered the haze up to 4x the render edge, so at short
	// render distances a fully-established orbital altitude (d > edge)
	// still sat inside it and the WHOLE disc washed to the air colour
	// (the user's "smooth pale ball"; disc-centre haze measured
	// 0.0000 only at the arm's long settings, which is why that fix
	// was declared good). One term was doing two jobs (limb haze AND
	// edge continuity) that pull in opposite directions as the render
	// distance shrinks; now each has its own driver.
	float haz_d = 1.0 - op;
	float haz = clamp(haz_a + haz_d, 0.0, 1.0);
	float sun_l = clamp(dot(u_sun, NORMAL) * INV_BAKE_SUN_RADIAL, 0.0, 1.0);
	// AC-0411: decode the baked sRGB bytes BEFORE the day factor. The
	// factor (u_day - u_day_gain*(1-sun_l), in [0.18, 1.0]) is a linear
	// light scalar, not part of the display colour, so the domain
	// correction belongs on the texture value: decode-then-scale
	// preserves the texel's channel ratios (its hue) at the 0.18 night
	// floor, where scale-then-pow (the atlas materials' order) would
	// shift them; at sun_l = 1 the two orders are identical, so this
	// agrees with the AC-0242 convention exactly where it is measured.
	// u_air is NOT pre-decoded (already linear) - see the header.
	vec3 texv = texture(tex, UV).rgb;
	texv = mix(texv, pow(texv, vec3(2.2)), u_srgb_pre);
	vec3 base = texv * (u_day - u_day_gain * (1.0 - sun_l));
	// AC-0394: spatial outputs are ALBEDO and ALPHA - COLOR is the canvas_item
	// (2D) output and is a read-only vertex input here, which is why the parser
	// reported "Constants cannot be modified" at this line.
	ALBEDO = mix(base, u_air.rgb, haz);
	ALPHA = op;
}
