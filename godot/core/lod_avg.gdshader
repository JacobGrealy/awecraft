// AC-0252: the med/low AVERAGE-COLOR LOD material (the 8x8x8 med + 4x4x4
// low placeholder tiers — vertex-color geometry, NO UVs, no texture).
//
// The far LODs are flat-color boxes: a uniform color per merged quad looks
// like a painted wall at distance. This shader breaks the faces up with a
// STATIC per-fragment hash of the FRAGMENT WORLD POSITION — stable under
// camera motion (no flicker: the hash input is world-fixed, not view-
// fixed), ~6% brightness jitter around the vertex color.
//
// Spatial shaders have no WORLD_POSITION builtin (this engine build) — the
// world position is computed in the vertex stage as MODEL_MATRIX * VERTEX
// and carried to the fragment stage in a varying (the repo pattern:
// cloud_layer.gdshader / chunk_lit_*.gdshader).
//
// "day" tracks the same sky_display color the fog box uses (the
// placeholders darkened at night before the split — the avg LODs keep it;
// it defaults to white, so the material is never black at rest).
//
// Applies ONLY to the med/low avg-color instances (world._lod_avg_mat).
// The high path, the fog boxes, and the cap material are untouched.
shader_type spatial;

uniform vec4 day : source_color = vec4(1.0, 1.0, 1.0, 1.0);

varying vec3 v_world_pos;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// ~1.5-block noise cells in world space (the far LOD samples are
	// 2-4 blocks, so the jitter stays sub-cell — breakup, not texture).
	vec3 cell = floor(v_world_pos * 0.6667);
	float h = fract(sin(dot(cell, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
	float jit = 1.0 + (h - 0.5) * 0.12; // +/-6% around the vertex color
	ALBEDO = COLOR.rgb * day.rgb * jit;
	ALPHA = COLOR.a;
}
