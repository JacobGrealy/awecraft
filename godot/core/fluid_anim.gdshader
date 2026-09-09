shader_type spatial;
render_mode cull_back;
// AC-0245 follow-up (2026-09-09 user bug "moving shadows" on water-covered
// terrain): cull_back, NOT cull_disabled. The "water boundary from both
// sides" request (cull_disabled) made the water's BACK faces render on top
// of the opaque underwater terrain and z-fight - a camera-motion-dependent
// blocky "shadow" mottle on the lake floor, from above OR below the water.
// cull_back keeps the water surface readable from above and the side faces
// from the water side, without the back-face z-fight. (The mesh-side
// companion: emit_fluid no longer emits fluid faces toward solid neighbors.)

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
varying vec3 v_world_pos;

const float TILE_F = 1.0 / 32.0;


void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// AC-0036 (+AC-0245): same underwater near-cull as chunk_lit_fluid
	// (~1.2 blocks - only the face inside the head; the surface above stays
	// visible so the boundary is readable from underwater).
	if (u_underwater > 0.5 && distance(v_world_pos, u_cam_pos) < 1.2) {
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
