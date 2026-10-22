// AC-0128: unlit day/night shading for cross (flower) quads.
// Same vColor repack + formula as chunk_lit_opaque.gdshader (incl. the
// AC-0426 zero-light sky-ambient term on L, see the fragment), plus the
// alpha discard + cull_disabled (cross path, two-sided).
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform float u_day : hint_range(0.0, 1.0) = 1.0;
uniform sampler2D tex : filter_nearest;
uniform vec3 u_player_pos = vec3(0.0, 0.0, 0.0);
uniform float u_player_light = 0.0;
uniform float u_player_radius = 5.0;
uniform float u_srgb_pre : hint_range(0.0, 1.0) = 0.0;
// AC-0447: the NIGHT TOE weight (0.0 = day / switch OFF = bit-identical).
uniform float u_night_lift : hint_range(0.0, 1.0) = 0.0;
// AC-0401: the fog-wall partition (env.fog_depth_end, pushed per frame by
// world.gd _process - the same value main.gd sets on the env fog).
uniform float u_fog_far = 332.0;
// AC-0426: zero-light sky-ambient magnitude (default 0.0 = the shipped
// formula bit-identical; the contract comment lives in
// chunk_lit_opaque.gdshader).
uniform float u_amb : hint_range(0.0, 1.0) = 0.0;
// AC-0436: the moonlight term (Settings "moonlight", default ON) - the
// uniform set and the bit-identity contract (OFF/day -> u_moon = 0.0 ->
// 0.0 * x = 0.0, x + 0.0 = x) are owned by chunk_lit_opaque.gdshader.
uniform float u_moon : hint_range(0.0, 2.0) = 0.0;
uniform vec3 u_moon_dir = vec3(0.0, 1.0, 0.0);
// AC-0445: the first-enable fade ramp (the shared material leaves it at
// 1.0; the fade material multiplies the cross alpha by it - see
// chunk_lit_opaque.gdshader for the contract).
uniform float u_fade : hint_range(0.0, 1.0) = 1.0;
varying vec3 v_world_pos;
// AC-0451 P1: the coverage-predicate switch (AWECRAFT_COVERAGE=0|1 —
// the contract comment lives in chunk_lit_opaque.gdshader). P1 is
// INERT: the stub below answers false for every d, so the discard is
// byte-identical to the pre-ticket build; P2 turns the real query on.
uniform float u_coverage : hint_range(0.0, 1.0) = 0.0;
bool ac0451_covered(float d) {  // AC-0451 P1 STUB: never covered (P2 turns the query on)
	return u_coverage > 0.5 && false;
}


void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// AC-0401: the fog-wall partition (chunk_lit_opaque.gdshader owns the
	// contract) - flower crosses stay inside the world's fog window; the
	// satellite body owns the view beyond it.
	float d = distance(CAMERA_POSITION_WORLD, v_world_pos);
	if (d >= u_fog_far && !ac0451_covered(d)) {  // AC-0451 P1: the coverage rule (the stub is inert)
		discard;
	}
	vec4 t = texture(tex, UV);
	if (t.a < 0.5) discard;
	float m_direct = max(u_day * COLOR.r, COLOR.g);
	float L = 0.20 + 0.80 * m_direct;
	// AC-0426: the zero-light sky-ambient fallback (the contract comment
	// lives in chunk_lit_opaque.gdshader).
	L += u_amb * u_day * step(m_direct, 0.08);  // AC-0426 mask: 1.0 iff m_direct <= MIN_AMB (the light floor - see chunk_lit_opaque.gdshader)
	// AC-0436: the moon's directional lambert (see the uniform block).
	// u_moon = 0.0 at day/OFF -> the term is 0.0 -> bit-identical.
	L += u_moon * max(dot(NORMAL, u_moon_dir), 0.0);
	float pr = clamp(u_player_light - distance(v_world_pos, u_player_pos), 0.0, u_player_radius);
	L = max(L, 0.12 + 0.88 * pr / 15.0);
	ALBEDO = t.rgb * COLOR.b * L;
	ALBEDO = mix(ALBEDO, pow(ALBEDO, vec3(2.2)), u_srgb_pre); // AC-0242
	// AC-0447: the NIGHT TOE (the dark-readable midnight floor). A
	// luma-scaled gain f = 1 + u_night_lift*A*(d/(lum+d))^p on the
	// predecoded ALBEDO; A/d/p = 42.5/0.00175/1.5 are fitted against the
	// game's own tone curve (in-game probe, tasks/AC-0447): the midnight
	// floor (lum~0.0004) lifts ~31x to byte ~12, the moonlit grass top
	// (lum~0.017) ~2.2x to byte ~45, lum=0 stays 0, lum*f monotone.
	// u_night_lift 0.0 (day / "night_lift" OFF) makes f exactly 1.0 -
	// bit-identical (IEEE 754: 0*x = 0, 1 + 0.0 = 1.0, x * 1.0 = x).
	float ac47_lum = dot(ALBEDO, vec3(0.2126, 0.7152, 0.0722));
	ALBEDO *= 1.0 + u_night_lift * 42.5 * pow(0.00175 / (ac47_lum + 0.00175), 1.5);
	ALPHA = t.a * u_fade;  // AC-0445: the first-enable fade (the surviving cross pixels, t.a ~ 1.0)
}
