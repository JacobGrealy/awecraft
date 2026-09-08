// AC-0035 (web night-sky stars, index.html :718-730) + AC-0133 (sky-fixed
// orientation). The MeshInstance "Stars" is a child of the world root and is
// recentered on the camera POSITION each frame (web :3248, position copy
// only); its rotation is NEVER set, so the field is fixed in world
// orientation — stars scroll with the sky under camera yaw, no parallax
// under walking. The (UV - 0.5) quad offset is applied in the camera's
// WORLD basis (world-space billboard below), because the node frame no
// longer tracks the camera. u_opacity = 1 - day (web :1347). No fog() call
// = web fog:false; depth draw off = web depthWrite:false.
// AC-0235 retest 5: per-star VARIATION (user: all stars were too bright
// and uniform). The 4.7 spatial shader exposes NO VERTEX_COLOR builtin, so
// the per-star data rides UV2: x = size factor (mostly small, a few big),
// y = hue_class * 20 + brightness_q (b15 0-15, dim-heavy; hue 0 white,
// 1 blue-white, 2 warm, 3 red-orange). The shape is picked per star from
// a stable hash of the star center: mostly soft round dots, a fair number
// of tight points, and a rare cross sparkle (the MC-style bright star).
// Hard square edges are gone.

shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;

uniform float u_opacity = 1.0;
uniform float quad_size = 0.85;  // retest 6: 0.70 made the field sub-pixel dim
// AC-0242: unshaded output needs the compat pre-decode like the chunks.
uniform float u_srgb_pre : hint_range(0.0, 1.0) = 0.0;

varying vec3 v_center;  // star center in world space (stable per star)

// AC-0235 retest 6 cont (star fix): the render_mode fog_disabled flag
// does not keep the engine fog off this material on the harness
// renderer (llvmpipe) - the 320-unit shell sits past the fog end and
// was painted fully in the (near-black) night fog color, so the field
// never drew. The cloud layer's empty fog_fragment() override is the
// proven exemption in this codebase (the decks stay crisp far beyond
// the fog end), so the stars get the same one.
void fog_fragment() {
}

void vertex() {
	v_center = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;  // star center, world space
	vec3 w = v_center;
	mat3 v = mat3(VIEW_MATRIX);
	vec3 cam_right = transpose(v) * vec3(1.0, 0.0, 0.0);       // row 0 of the view rotation = camera right (world)
	vec3 cam_up = transpose(v) * vec3(0.0, 1.0, 0.0);          // row 1 = camera up (world)
	// UV2.x = per-star size factor (the mesh bakes it)
	vec3 off = (cam_right * (UV.x - 0.5) + cam_up * (UV.y - 0.5)) * quad_size * UV2.x;
	VERTEX = w + off - MODEL_MATRIX[3].xyz;                    // back to node-local (node basis = identity, origin = eye)
}

void fragment() {
	vec2 c = UV - 0.5;
	float d = length(c);
	// stable per-star hash (stars are ~50 world units apart on the r=320
	// shell; a 4-unit cell never collides within one star's quad)
	float sh = fract(sin(dot(floor(v_center * 0.25), vec3(12.9898, 78.233, 37.719))) * 43758.5453);
	float shape;
	if (sh < 0.10) {
		// cross sparkle: bright core + thin arms (the MC-style bright star)
		float core = 1.0 - smoothstep(0.03, 0.22, d);
		float armx = (1.0 - smoothstep(0.0, 0.5, abs(c.x))) * (1.0 - smoothstep(0.015, 0.09, abs(c.y)));
		float army = (1.0 - smoothstep(0.0, 0.5, abs(c.y))) * (1.0 - smoothstep(0.015, 0.09, abs(c.x)));
		shape = core + 0.55 * max(armx, army);
	} else if (sh < 0.60) {
		// soft round dot (the majority)
		shape = 1.0 - smoothstep(0.10, 0.42, d);
	} else {
		// tight point
		shape = 1.0 - smoothstep(0.05, 0.28, d);
	}
	// unpack the per-star color (see header)
	float hue = floor(UV2.y / 20.0);
	float b15 = UV2.y - hue * 20.0;
	float br = 0.45 + 0.55 * (b15 / 15.0);  // retest 6: the 0.22 floor made the field barely visible
	vec3 tint = vec3(1.0);
	if (hue > 0.5 && hue < 1.5) {
		tint = vec3(0.72, 0.84, 1.0);
	} else if (hue > 1.5 && hue < 2.5) {
		tint = vec3(1.0, 0.93, 0.78);
	} else if (hue > 2.5) {
		tint = vec3(1.0, 0.62, 0.45);
	}
	ALBEDO = tint * br;
	// AC-0235 retest 6 cont: the star field is calibrated against a
	// black sky in display space (br 0.45-1.0). The AC-0242 pre-decode
	// (pow 2.2, Forward+) crushes that to sub-threshold on Forward+,
	// so lift by one sRGB curve first - the pre-decode below then
	// round-trips to the designed brightness (identity on compatibility).
	ALBEDO = mix(ALBEDO, pow(ALBEDO, vec3(0.4545)), u_srgb_pre);
	ALPHA = shape * u_opacity;
	ALBEDO = mix(ALBEDO, pow(ALBEDO, vec3(2.2)), u_srgb_pre); // AC-0242
}
