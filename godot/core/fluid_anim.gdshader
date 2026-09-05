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
// AC-0227: dither-fade band in blocks from the player (pushed per frame from
// DayNight.dither_start/end, pure functions of render_radius). 0/0 = off.
// The ocean rides to the render edge like any chunk, so water/lava get the
// same distance dither as the solid meshes.
uniform vec3 u_player_pos = vec3(0.0, 0.0, 0.0);
uniform float u_dither_start = 0.0;
uniform float u_dither_end = 0.0;
varying vec3 v_world_pos;

const float TILE_F = 1.0 / 32.0;

// AC-0227: classic 4x4 Bayer matrix (0..15), row-major.
const float DITHER44[16] = float[16](
	0.0, 8.0, 2.0, 10.0,
	12.0, 4.0, 14.0, 6.0,
	3.0, 11.0, 1.0, 9.0,
	15.0, 7.0, 13.0, 5.0);

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// AC-0227: screen-space checkerboard dither fade (complements the AC-0226
	// fog pull: the fog fades the COLOR, this discards FRAGMENTS). fade = 0
	// at/below u_dither_start (solid), 1 at/above u_dither_end (fully
	// dithered out); the per-pixel Bayer threshold decides which pixels are
	// discarded, so far chunks dissolve into a checkerboard that fills in as
	// they get closer. Runs BEFORE the fog tints the surviving fragments.
	// Inlined here (not a helper): this engine build only binds FRAGCOORD
	// inside the processor function.
	float dspan = u_dither_end - u_dither_start;
	if (dspan > 0.0) {
		float fade = clamp((distance(v_world_pos, u_player_pos) - u_dither_start) / dspan, 0.0, 1.0);
		if (fade > 0.0) {
			int bx = int(FRAGCOORD.x) & 3;
			int by = int(FRAGCOORD.y) & 3;
			if (DITHER44[by * 4 + bx] / 16.0 < fade) {
				discard;
			}
		}
	}
	vec2 uv = UV;
	int frame = int(mod(floor((TIME + phase) / frame_time), anim_frames));
	uv.y += float(frame) * TILE_F;
	vec4 tex = texture(atlas, uv);
	ALBEDO = tex.rgb * COLOR.rgb;
	ALPHA = alpha_scale * tex.a;
}
