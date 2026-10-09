// AC-0128: unlit day/night shading for opaque chunk faces.
// vColor repack channels: r = sky channel (light scalar s), g = block-light
// channel (s when the face has block-light source evidence within Chebyshev 14
// in own-chunk data, else 0), b = face shade. Fragment (AC-0128 structure,
// const+gain = 1.0; user-directed 0.20 floor, AC-0135 Run-2):
//   ALBEDO = tex.rgb * faceShade * (0.20 + 0.80 * max(u_day * r, g))
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
	float L = 0.20 + 0.80 * max(u_day * COLOR.r, COLOR.g);
	float pr = clamp(u_player_light - distance(v_world_pos, u_player_pos), 0.0, u_player_radius);
	L = max(L, 0.12 + 0.88 * pr / 15.0);
	ALBEDO = t.rgb * COLOR.b * L;
	ALBEDO = mix(ALBEDO, pow(ALBEDO, vec3(2.2)), u_srgb_pre); // AC-0242
}
