shader_type spatial;
render_mode cull_disabled;
// AC-0245 follow-up 3 (2026-09-09, user: "removing the option to see the
// water surface from underwater is not an option" + "show/hide outside /
// inside faces based on camera position"): the OUTWARD pass of the
// two-pass camera-side fluid culling. The engine's render_mode cull
// options are UNRELIABLE in this build (both cull_back and cull_front
// render extra sides - probe-confirmed 2026-09-09: byte-identical frames
// with and without the "culled" side), so the camera-side selection is
// done EXPLICITLY in the fragment: the geometric face normal (screen-space
// derivatives of the world position) is computed per fragment and
// compared with the direction to the camera - only the fragment on the
// camera's OUTSIDE (air) side of the boundary survives; the INWARD pass
// (fluid_anim_bf.gdshader) keeps exactly the complementary set. Every
// water-air boundary (the surface seen from underwater, the shore edges
// from either side) is two-sided, and each boundary face is rasterized by
// exactly ONE pass per frame - no coincident fragments, so the
// cull_disabled z-fight ("moving shadows" mottle on water-covered
// terrain) cannot return. (Mesh-side companion, follow-up 2: emit_fluid
// no longer emits fluid faces toward solid neighbors.)

// Web-faithful fluid animation (index.html updateAtlasAnims):
// stacked-frame texture flip, 300 ms/frame (web default frametime),
// frame = floor(elapsed_ms / frametime) % N_frames, sequential cycle.
// Mesh UVs point at frame 0 of the vertical strip; the shader scrolls
// UV.y down the strip per frame. Texture/UV-side only.
uniform sampler2D atlas : filter_nearest, repeat_disable;
uniform float anim_frames : hint_range(1.0, 64.0) = 1.0;
uniform float frame_time : hint_range(0.01, 5.0) = 0.3;
uniform float phase = 0.0;
uniform float alpha_scale : hint_range(0.0, 1.0) = 0.62;
uniform float u_srgb_pre : hint_range(0.0, 1.0) = 0.0;
uniform float u_underwater : hint_range(0.0, 1.0) = 0.0;
uniform vec3 u_cam_pos = vec3(0.0);
// AC-0401: the fog-wall partition (env.fog_depth_end, pushed per frame by
// world.gd _process - the same value main.gd sets on the env fog).
uniform float u_fog_far = 332.0;
varying vec3 v_world_pos;

const float TILE_F = 1.0 / 32.0;


void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// AC-0401: the fog-wall partition (chunk_lit_opaque.gdshader owns the
	// contract) - the animated water/lava surface stays inside the
	// world's fog window; the satellite body owns the view beyond it.
	if (distance(v_world_pos, u_cam_pos) >= u_fog_far) {
		discard;
	}
	// AC-0036 (+AC-0245): same underwater near-cull as chunk_lit_fluid
	// (~1.2 blocks - only the face inside the head; the surface above
	// stays visible when you are deeper, so the boundary is readable
	// from underwater).
	if (u_underwater > 0.5 && distance(v_world_pos, u_cam_pos) < 1.2) {
		discard;
	}
	// AC-0245 follow-up 3: EXPLICIT camera-side cull (OUTWARD pass) - the
	// engine's render_mode cull is unreliable in this build, so select the
	// camera's outside (air) side of each boundary face per fragment:
	// derivative face normal vs direction to the camera. The INWARD pass
	// (fluid_anim_bf.gdshader) keeps exactly the complementary set, so
	// each boundary face is drawn by exactly one pass per frame.
	vec3 fw = normalize(cross(dFdx(v_world_pos), dFdy(v_world_pos)));
	if (dot(fw, normalize(u_cam_pos - v_world_pos)) < 0.0) {
		discard;
	}
	vec2 uv = UV;
	int frame = int(mod(floor((TIME + phase) / frame_time), anim_frames));
	uv.y += float(frame) * TILE_F;
	vec4 tex = texture(atlas, uv);
	ALBEDO = tex.rgb * COLOR.rgb;
	ALBEDO = mix(ALBEDO, pow(ALBEDO, vec3(2.2)), u_srgb_pre); // AC-0242
	ALPHA = alpha_scale * tex.a;
}
