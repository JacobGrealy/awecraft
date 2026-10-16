// AC-0128: unlit day/night shading for opaque chunk faces.
// vColor repack channels: r = sky channel (light scalar s), g = block-light
// channel (s when the face has block-light source evidence within Chebyshev 14
// in own-chunk data, else 0), b = face shade. Fragment (AC-0128 structure,
// const+gain = 1.0; user-directed 0.20 floor, AC-0135 Run-2):
//   ALBEDO = tex.rgb * faceShade * (0.20 + 0.80 * max(u_day * r, g))
// AC-0426: + the zero-light sky-ambient term (u_amb, default 0.0 = the
// formula above bit-identical; see the fragment comment for the contract).
shader_type spatial;
render_mode unshaded, cull_back;

uniform float u_day : hint_range(0.0, 1.0) = 1.0;
uniform sampler2D tex : filter_nearest;
uniform vec3 u_player_pos = vec3(0.0, 0.0, 0.0);
uniform float u_player_light = 0.0;
uniform float u_player_radius = 5.0;
uniform float u_srgb_pre : hint_range(0.0, 1.0) = 0.0;
// AC-0401: the fog-wall partition (env.fog_depth_end, pushed per frame by
// world.gd _process - the same value main.gd sets on the env fog).
uniform float u_fog_far = 332.0;
// AC-0426: the zero-light sky-ambient magnitude (Settings "ambient_sky",
// default OFF; world.gd _ac0401_push pushes AMB_SKY_L on change). 0.0 is
// the shipped path bit-identical (0*x = 0, x + 0 = x in IEEE 754).
uniform float u_amb : hint_range(0.0, 1.0) = 0.0;
// AC-0436: the moonlight term (Settings "moonlight", default ON). u_moon =
// MOON_L (world.gd) * night * switch, pushed per frame by world.gd
// _ac0401_push (the u_amb seam); u_moon_dir = direction TO the moon (the
// sun's antipode - DayNight.sun_direction, the same convention the sky
// pass's body-flip disc draws at). The night's directional light source -
// the ticket's named gap: at night u_day = 0 kills every sky-light term,
// the 0.20 floor is all a face has, and ACES crushes that to a few 8-bit
// units (measured 4.0/255 ground luma vs 98.4 by day). A per-fragment
// lambert off the mesh's FACE normals (ARRAY_NORMAL, chunk.gd _surface -
// the mesher emits them) gives the night landscape its slopes. OFF or day
// -> u_moon = 0.0 -> the added term is 0.0 -> the AC-0128/AC-0426 formula
// bit-identical (0.0 * x = 0.0, x + 0.0 = x in IEEE 754). The 0.20 floor
// is never re-tuned; the moon ADDS to it.
uniform float u_moon : hint_range(0.0, 2.0) = 0.0;
uniform vec3 u_moon_dir = vec3(0.0, 1.0, 0.0);
varying vec3 v_world_pos;


void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// AC-0401: the near detail obeys the satellite body's fog wall -
	// beyond it the world is 100% fog colour and the body (its haz_d rim
	// is exactly that air colour) owns the view. Pre-AC-0401 the high
	// tiers kept drawing past the wall as a fog-colour patch over the
	// body's terrain from orbit (the "patch of ground you just left");
	// the engine fog already fades them to air up to the wall, so the
	// dissolve as the camera climbs is the fog itself.
	if (distance(CAMERA_POSITION_WORLD, v_world_pos) >= u_fog_far) {
		discard;
	}
	vec4 t = texture(tex, UV);
	float m_direct = max(u_day * COLOR.r, COLOR.g);
	float L = 0.20 + 0.80 * m_direct;
	// AC-0426: the light-floor sky-ambient fallback. A face whose BOTH
	// direct terms sit at the light floor - the trunk under its own crown
	// (the crown's leaves ring the top log cells, so the sky pull never
	// reaches them) or an enclosed cave/hollow - rests on ~0.26 at EVERY
	// hour, and tex * faceShade * 0.26 is sub-8-bit on the dark bark and
	// leaf atlas cells: the AC-0425 black silhouette. The fix adds a
	// sky-ambient that tracks the sky's ACTUAL brightness at that hour -
	// u_day is DayNight.day(t), exactly 0.0 at night (the term is 0.0 then:
	// a tree at midnight stays black, the night look bit-identical) and 1.0
	// at noon. Faces with real direct light (m_direct above the floor) are
	// untouched at any hour; the 0.20 floor itself (the user-directed
	// AC-0128/AC-0135 value) is never re-tuned.
	// The mask threshold is MIN_AMB = 0.08 (chunk.gd / mesh.cpp): the
	// light scalar is clamped to [MIN_AMB, 1.0] at mesh time, so an
	// unlit face NEVER reads s = 0 - it reads the floor (20/255 = 0.0784
	// after the 8-bit vertex-colour packing), and the strict-zero mask
	// step(m_direct, 0.0) can never fire (measured: 4,461 vertices of the
	// R4 tree, r_min = 20/255, zero at 0.0). step(m_direct, 0.08) is 1.0
	// iff m_direct <= 0.08, i.e. the face is at the floor (sky pull level
	// <= 1, no block light): "effectively unlit". step(edge, x) is 1.0
	// for x >= edge; the tempting 1.0 - step(0.0, m_direct) is always
	// 0.0 - the first pass shipped exactly that dead mask, caught by the
	// A/B measurement; this floor threshold is the second pass. u_amb =
	// 0.0 (the shipped default) makes the added term 0.0 for every pixel:
	// the AC-0128 formula bit-identical.
	L += u_amb * u_day * step(m_direct, 0.08);
	// AC-0436: the moon's directional lambert (see the uniform block).
	// u_moon = 0.0 at day/OFF -> the term is 0.0 -> bit-identical.
	L += u_moon * max(dot(NORMAL, u_moon_dir), 0.0);
	float pr = clamp(u_player_light - distance(v_world_pos, u_player_pos), 0.0, u_player_radius);
	L = max(L, 0.12 + 0.88 * pr / 15.0);
	ALBEDO = t.rgb * COLOR.b * L;
	ALBEDO = mix(ALBEDO, pow(ALBEDO, vec3(2.2)), u_srgb_pre); // AC-0242
}
