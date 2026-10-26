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
//  (2) HAZE: ONE term (AC-0511 - the two-term model collapsed):
//      (a) haz_a - the air column along the view ray: haz_a =
//          clamp(d / u_air_cm, 0, 1), d the per-fragment camera
//          distance, u_air_cm the sky's OWN limb normalization
//          (2*sqrt(rout^2 - (R+SEA)^2), rout = R + A + 0.25A, A =
//          Aero.atmosphere_height - the game's single-source
//          atmosphere, pushed by satellite_body.gd). The column grows
//          with the ACTUAL path through the air instead of the old
//          (1-cosv)^2 grazing proxy, which saturated 324 m from the
//          camera inside the A shell and painted the disc 3x (941 m)
//          to 22x (300 m wall) too hazy (the AC-0511 measurement).
//          1.0 at d = u_air_cm: the tangent chord - the rim stays
//          fully hazy, the disc's edge stays continuous.
//      (b) haz_d - REMOVED AC-0511. The EDGE-CONTINUITY term (1 - op)
//          existed to paint the body 100% u_air exactly where the
//          world rendered 100% env-fog colour (the AC-0399 seam
//          bridge against the engine env fog). AC-0510 removed that
//          fog, so the window [u_fog_far, u_render_edge] now shows
//          real near-tier terrain or the sky - there is nothing
//          fog-coloured to bridge, and haz_d held the fade-in
//          annulus at 100% air (the blue-chunk seam the user
//          photographed). Its justification was deleted by a later
//          ticket; the term is gone with it.
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
// bridge: existence ramps over the world's fog window and the haze mixes
// toward u_air (== env.fog_light_color) with the ray's air column (header
// items (1) and (2); the haz_d 100%-fog bridge was removed AC-0511 with
// the env fog, AC-0510). With the engine env fog
// still applied, every fragment beyond fog_depth_end is repainted fog
// colour by the engine - the established disc is erased and the user
// sees a featureless fog-colour ball with only the fog_disabled cloud
// shell as detail (the cloud shader carries the same flag, its comment
// naming this exact failure for the 4300 m shell). This flag is the
// designed state, not a workaround: below the fog wall the body's
// fragments are discarded by `op` anyway, so no double-fog is possible.
render_mode cull_back, depth_draw_always, fog_disabled;

// AC-0412: filter_linear_mipmap_anisotropic (the AC-0384 r5 state,
// re-landed behind the AWECRAFT_SAT_MIP switch in satellite_body.gd).
// A mipmap-filtering sampler over a texture WITHOUT a chain is a no-op
// (the r5 note) - the chain side is the env-gated generate_mipmaps in
// every texture-creation site, so AWECRAFT_SAT_MIP=0 reproduces the
// pre-AC-0412 sampling exactly. `filter_linear` filters ONE level: no
// chain, no anisotropy - a 1024^2 texture bilinear-sampled at sub-texel
// pitch aliases (the AC-0384 r4 ladder measured it), and at the limb the
// compressed texel columns smear into the vertical streaks the AC-0384
// r19/r21 assessment recorded.
uniform sampler2D tex : filter_linear_mipmap_anisotropic;
uniform float u_fog_far : hint_range(0.0, 20000.0);
uniform float u_render_edge : hint_range(0.0, 20000.0);
uniform vec4 u_air : source_color;
// AC-0511: the air-column normalization (metres of line-of-sight air at
// the R + SEA disc tangent) - the SAME cm the sky's limb term normalizes
// by (aero_sky_gradient sky_on: 2*sqrt(rout^2 - u_limb_radius^2),
// rout = R + A + 0.25A; A = Aero.atmosphere_height, the game's
// single-source atmosphere). Pushed per frame by satellite_body.gd;
// the default is the A = 1200 value so the shader is sane unpushed.
// haz_a = clamp(d / u_air_cm, 0, 1) - the body and the sky limb count
// the same air.
uniform float u_air_cm : hint_range(0.0, 100000.0) = 7273.5;
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
// AC-0421: the height-based RELIEF switch (Settings "relief_shading",
// default ON - the user asked for it in their own words: "alter the color
// of the sample based on the height ... baked lighting, like what minecraft
// does with its maps"). 0.0 = the exact pre-AC-0421 path (the fragment
// short-circuits the relief, bit-identical); 1.0 modulates the decoded
// sample by the texel's height channel (the alpha carries H/HMAX) so the
// surface reads as baked-lit relief instead of a flat pastel map. Pushed
// per face by satellite_body.gd.
uniform float u_relief : hint_range(0.0, 1.0) = 0.0;
// AC-0421: the SPECULAR amount for this material. Shipped value 0.0 (the
// satellite LOD must not be reflective - the user's phrase is the spec):
// the engine's default specular (0.5, lit by the sun) is the glossy cast
// the user reported. Pushed per face by satellite_body.gd from the
// AWECRAFT_SPEC env (0.0 shipped; 0.5 the pre-AC-0421 state, A/B only).
uniform float u_spec : hint_range(0.0, 1.0) = 0.0;
// AC-0436: the moonlight term (Settings "moonlight", default ON). u_moon =
// MOON_L (world.gd) * night * switch, u_moon_dir = direction TO the moon
// (the sun's antipode - DayNight.sun_direction, the same convention the
// u_sun header comment describes inverted). At night u_day_gain = 0 and
// u_day = 0.18, so without this term the whole disc sits on the flat 0.18
// floor (measured 3.0/255 planet luma at 2600 m - "a faint mottle"); with
// it, the hemisphere facing the moon re-weights up to 0.18 + u_moon and
// carries the baked texture. OFF or day -> u_moon = 0.0 -> + 0.0 -> the
// AC-0382 factor bit-identical (0.0 * x = 0.0, x + 0.0 = x in IEEE 754).
uniform float u_moon : hint_range(0.0, 4.0) = 0.0;
uniform vec3 u_moon_dir = vec3(0.0, 1.0, 0.0);

const float INV_BAKE_SUN_RADIAL = 1.09544512; // sqrt(1.2) = 1 / L_RADIAL

// AC-0428: per-fragment WORLD position + the RADIAL normal, computed in the
// VERTEX stage and interpolated to the fragment via varyings. AC-0384 built
// the world position in the fragment stage as `INV_VIEW_MATRIX * VERTEX`, on
// the (wrong) premise that the fragment-stage VERTEX builtin is the
// fragment's interpolated view-space position. In the 4.7.1 engine that is
// NOT the case: the fragment-stage VERTEX degenerates to a constant across a
// whole draw, so `d`, the `op` existence window, `haz_d` and `cosv` were all
// computed against ONE fixed point instead of the fragment - the limb haze
// (designed as a per-fragment impact-parameter model) collapsed into a
// dot-against-a-fixed-direction and the disc washed flat across the frame
// (the user's "see-through / half-flat satellite LOD"). Verified in-engine
// for AC-0428: the vertex-stage world position is a true sphere
// (|v_world - planet centre| == R at every fragment, whole frame), while the
// fragment-stage reconstruction was constant. This matches the repo's
// established pattern (cloud_layer.gdshader / lod_avg.gdshader compute the
// world position in the vertex stage as MODEL_MATRIX * VERTEX and pass it
// through a varying). The body carries translation only, so the mesh-local
// radial direction IS the world-space normal (no NORMAL matrix needed).
varying vec3 v_world;
varying vec3 v_nrm;

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
	// AC-0428: the exact radial normal (the mesh is a sphere, so the local
	// position direction IS the surface normal; the inset above is radial and
	// leaves the direction unchanged). Translation-only transform => this
	// local direction equals the world-space normal.
	v_nrm = normalize(VERTEX);
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// World-space geometry (AC-0428, superseding the AC-0384 fragment-stage
	// reconstruction): p_w is the vertex-stage world position interpolated
	// through the v_world varying (see the note above the vertex stage - the
	// fragment-stage VERTEX builtin does not give the per-fragment position
	// in 4.7.1, and the AC-0384 INV_VIEW_MATRIX * VERTEX was a constant).
	// nrm is the vertex-stage radial normal through v_nrm. CAMERA_POSITION_WORLD
	// is the camera in world space. All three are world space, so the d / op /
	// haz / cosv / sun-lambert math below is a true per-fragment model again.
	vec3 p_w = v_world;
	vec3 nrm = v_nrm;
	vec3 cam_w = CAMERA_POSITION_WORLD;
	float d = length(p_w - cam_w);
	float op = smoothstep(u_fog_far, u_render_edge, d);
	if (op <= 0.001) {
		discard;
	}
	// TERM 1 - haz_a: the air column along the view ray (AC-0511).
	// d (above) is the true per-fragment camera->fragment path. The
	// body's fragments render from d >= u_fog_far (op discards the
	// rest) and the measured vantages are inside the A shell (A =
	// Aero.atmosphere_height = h_full), so the path is in-shell air:
	// haz_a = clamp(d / u_air_cm, 0, 1) grows with the ACTUAL depth
	// through the atmosphere. u_air_cm is the sky's own limb
	// normalization (the full chord at the R + SEA disc tangent), so
	// the body and the sky limb count the same air. 1.0 at
	// d = u_air_cm (the tangent chord) - the rim stays fully hazy.
	// Replaces the (1-cosv)^2 grazing proxy, which saturated 324 m
	// from the camera inside the shell and painted the disc 3x (941 m)
	// to 22x (300 m wall) too hazy - the AC-0511 measurement. Above
	// the A shell d over-counts the air a ray sweeps in space; the
	// clamp bounds it (the authorized model, inside-shell exact).
	float haz_a = (u_air_cm > 0.0) ? clamp(d / u_air_cm, 0.0, 1.0) : 0.0;
	// TERM 2 - haz_d (the EDGE-CONTINUITY term, 1 - op) was REMOVED
	// in AC-0511, not weakened. Its one job was to paint the body
	// 100% u_air exactly where the world rendered 100% env-fog colour
	// (AC-0390/AC-0399 - the seam bridge against the engine env fog).
	// AC-0510 removed that fog THIS SESSION, so the window
	// [u_fog_far, u_render_edge] now shows REAL near-tier terrain (or
	// the sky, through the op fade) - there is nothing fog-coloured
	// to bridge: the premise is gone, and no other job was listed.
	// Kept, haz = clamp(haz_a + 1 - op, 0, 1) would still hold the
	// fade-in annulus at 100% air regardless of the column fix (the
	// blue-chunk seam the user photographed; wall haz 1.0 against the
	// ~0.05 the column says). The haze is haz_a alone now.
	float haz = haz_a;
	float sun_l = clamp(dot(u_sun, nrm) * INV_BAKE_SUN_RADIAL, 0.0, 1.0);
	// AC-0436: the moon's radial lambert (see the uniform block) - the same
	// radial convention as the sun term (the body is the satellite LOD: its
	// per-fragment slope modulation stays baked, only the radial ratio moves).
	float moon_l = clamp(dot(u_moon_dir, nrm) * INV_BAKE_SUN_RADIAL, 0.0, 1.0);
	// AC-0411: decode the baked sRGB bytes BEFORE the day factor. The
	// factor (u_day - u_day_gain*(1-sun_l), in [0.18, 1.0]) is a linear
	// light scalar, not part of the display colour, so the domain
	// correction belongs on the texture value: decode-then-scale
	// preserves the texel's channel ratios (its hue) at the 0.18 night
	// floor, where scale-then-pow (the atlas materials' order) would
	// shift them; at sun_l = 1 the two orders are identical, so this
	// agrees with the AC-0242 convention exactly where it is measured.
	// u_air is NOT pre-decoded (already linear) - see the header.
	vec4 texs = texture(tex, UV);
	vec3 texv = texs.rgb;
	texv = mix(texv, pow(texv, vec3(2.2)), u_srgb_pre);
	// AC-0421: the height-based RELIEF - the map renderer's "baked lighting"
	// (the user's own fix direction): modulate the decoded sample by the
	// height of the terrain it represents (the alpha channel carries H/HMAX,
	// a data channel, so it is sampled as-is - no sRGB decode), so high ground
	// reads as catching the light and the low ground reads in shade - the
	// surface stops reading as a flat pastel map. Conservative amplitude,
	// centred on the mid height; applied in the LINEAR domain (after the sRGB
	// decode above) so the texel's hue is preserved. u_relief <= 0.5
	// short-circuits before this line: the pre-AC-0421 path is bit-identical.
	if (u_relief > 0.5) {
		texv *= 1.0 + 0.4 * (texs.a - 0.5);
	}
	vec3 base = texv * (u_day - u_day_gain * (1.0 - sun_l) + u_moon * moon_l);
	// AC-0394: spatial outputs are ALBEDO and ALPHA - COLOR is the canvas_item
	// (2D) output and is a read-only vertex input here, which is why the parser
	// reported "Constants cannot be modified" at this line.
	ALBEDO = mix(base, u_air.rgb, haz);
	// AC-0421: the satellite LOD must NOT look reflective - the user's phrase
	// is the specification. The material is a lit spatial shader, and its
	// SPECULAR contribution (the engine default 0.5, lit by the sun's
	// DirectionalLight3D) is the term that gives the surface its glossy cast
	// instead of a matte terrain read. Remove it for this material: the
	// relief now comes from the baked lambert + the height modulation above,
	// not from a specular sheen. (The haz limb term is the fog-wall bridge,
	// not a sheen - it stays.)
	SPECULAR = u_spec;
	ALPHA = op;
}
