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
// AC-0227: dither-fade band in blocks from the player (pushed per frame from
// DayNight.dither_start/end, pure functions of render_radius). 0/0 = off.
uniform float u_dither_start = 0.0;
uniform float u_dither_end = 0.0;
varying vec3 v_world_pos;

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
	vec4 t = texture(tex, UV);
	float L = 0.20 + 0.80 * max(u_day * COLOR.r, COLOR.g);
	float pr = clamp(u_player_light - distance(v_world_pos, u_player_pos), 0.0, u_player_radius);
	L = max(L, 0.12 + 0.88 * pr / 15.0);
	ALBEDO = t.rgb * COLOR.b * L;
}
