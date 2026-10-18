// AC-0445: the first-enable FADE variant of chunk_lit_cutout.gdshader - the identical
// fragment (day/night + moon + player light + ambient, the AC-0128/0426/0436 formula)
// plus a blend_mix render_mode (the Godot4 standard alpha-blend mode; the plain `blend` keyword is rejected in this build) so the per-column u_fade ramp (0.0 -> 1.0, world.gd
// _col_fade_step) actually alpha-blends. This build's ShaderMaterial has no
// 'transparency' property (a BaseMaterial3D concept), so the blend is the render_mode.
// The shared (non-fade) material uses the chunk_lit_cutout.gdshader (opaque render, ALPHA ignored).
// AC-0128: unlit day/night shading for cutout (leaves) faces.
// Same vColor repack + formula as chunk_lit_opaque.gdshader (incl. the
// AC-0426 zero-light sky-ambient term on L, see the fragment), plus the
// alpha-scissor discard (cutout path, threshold 0.5).
shader_type spatial;
render_mode unshaded, cull_back, blend_mix;

uniform float u_day : hint_range(0.0, 1.0) = 1.0;
uniform sampler2D tex : filter_nearest;
uniform vec3 u_player_pos = vec3(0.0, 0.0, 0.0);
uniform float u_player_light = 0.0;
uniform float u_player_radius = 5.0;
uniform float u_srgb_pre : hint_range(0.0, 1.0) = 0.0;
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
// 1.0; the fade material multiplies the cutout alpha by it - see
// chunk_lit_opaque.gdshader for the contract).
uniform float u_fade : hint_range(0.0, 1.0) = 1.0;
varying vec3 v_world_pos;


void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// AC-0401: the fog-wall partition (chunk_lit_opaque.gdshader owns the
	// contract) - cutout faces (leaves) stay inside the world's fog
	// window; the satellite body owns the view beyond it.
	if (distance(CAMERA_POSITION_WORLD, v_world_pos) >= u_fog_far) {
		discard;
	}
	vec4 t = texture(tex, UV);
	if (t.a < 0.5) discard;
	float m_direct = max(u_day * COLOR.r, COLOR.g);
	float L = 0.20 + 0.80 * m_direct;
	// AC-0426: the zero-light sky-ambient fallback (the contract comment
	// lives in chunk_lit_opaque.gdshader; leaves under their own canopy
	// are the other half of the silhouette).
	L += u_amb * u_day * step(m_direct, 0.08);  // AC-0426 mask: 1.0 iff m_direct <= MIN_AMB (the light floor - see chunk_lit_opaque.gdshader)
	// AC-0436: the moon's directional lambert (see the uniform block).
	// u_moon = 0.0 at day/OFF -> the term is 0.0 -> bit-identical.
	L += u_moon * max(dot(NORMAL, u_moon_dir), 0.0);
	float pr = clamp(u_player_light - distance(v_world_pos, u_player_pos), 0.0, u_player_radius);
	L = max(L, 0.12 + 0.88 * pr / 15.0);
	ALBEDO = t.rgb * COLOR.b * L;
	ALBEDO = mix(ALBEDO, pow(ALBEDO, vec3(2.2)), u_srgb_pre); // AC-0242
	ALPHA = t.a * u_fade;  // AC-0445: the first-enable fade (the surviving cutout pixels, t.a ~ 1.0)
}
