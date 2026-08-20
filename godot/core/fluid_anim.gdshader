shader_type spatial;
render_mode cull_back;

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

const float TILE_F = 1.0 / 32.0;

void fragment() {
	vec2 uv = UV;
	int frame = int(mod(floor((TIME + phase) / frame_time), anim_frames));
	uv.y += float(frame) * TILE_F;
	vec4 tex = texture(atlas, uv);
	ALBEDO = tex.rgb * COLOR.rgb;
	ALPHA = alpha_scale * tex.a;
}
