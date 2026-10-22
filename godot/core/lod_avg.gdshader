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
//
// AC-0415: this material rides the ENGINE ENVIRONMENT FOG (the standard
// spatial path) — its duplicate of the fog is deleted. The far tier once
// carried `render_mode fog_disabled` + a hand-rolled copy of the engine's
// own depth ramp (the u_air mix): the AC-0384 r8 haze bridge, thinned by
// AC-0400 (fade target at u_air) and AC-0404 (bridge removed, "fog only")
// to one value the engine already computes for band A at the same view
// distance. Deletion restores the single source: env.fog_depth_begin/end
// + env.fog_light_color = AeroLib.fog_display (the same colour the
// satellite body's u_air and the sky horizon take) — one ramp, one air
// colour, and the fog_enabled switch now governs this tier with every
// other near-tier material. The seam at the partition wall is preserved
// by construction: the engine factor is 1.0 at fog_depth_end, exactly
// where the manual ramp reached u_air (the body's haz_d rim at the same
// wall, AC-0400). The AC-0401 partition below is NOT fog — it ends the
// annulus at the wall so the near tiers never draw over the body's own
// displaced terrain — and stays. The full r8/AC-0399/AC-0400/AC-0404
// history lives in those results pages (tasks/AC-0399, AC-0400, AC-0404).
//
// AC-0446: this file is the OFF path of the far-seam parity switch —
// UNCHANGED (bit-identical). ON swaps the material to
// lod_avg_seam.gdshader (world._ac0446_apply_shader).
shader_type spatial;

uniform vec4 day : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float u_fog_far = 332.0;  // env.fog_depth_end (main.gd) — the AC-0401 partition wall
// AC-0443: the AC-0426 parity lift for the a=0 faces (Settings "ambient_sky",
// AMB_SKY_L via world.gd _ac0401_push). 0.0 (default/OFF) is bit-identical.
uniform float u_amb : hint_range(0.0, 1.0) = 0.0;

varying vec3 v_world_pos;
// AC-0451 P1: the coverage-predicate switch (AWECRAFT_COVERAGE=0|1 —
// the contract comment lives in world/chunk_lit_opaque.gdshader). P1
// is INERT: the stub below answers false for every d, so the discard
// is byte-identical to the pre-ticket build; P2 turns the real query
// on. Declared in BOTH lod variants so the AC-0446 material-shader
// swap (world._ac0446_apply_shader) keeps the stored parameter valid.
uniform float u_coverage : hint_range(0.0, 1.0) = 0.0;
bool ac0451_covered(float d) {  // AC-0451 P1 STUB: never covered (P2 turns the query on)
	return u_coverage > 0.5 && false;
}

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// ~1.5-block noise cells in world space (the far LOD samples are
	// 2-4 blocks, so the jitter stays sub-cell — breakup, not texture).
	vec3 cell = floor(v_world_pos * 0.6667);
	float h = fract(sin(dot(cell, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
	float jit = 1.0 + (h - 0.5) * 0.12; // +/-6% around the vertex color
	// AC-0283 P3: the HALO band's light is the heightmap sky carried in
	// COLOR.a (1.0 above the terrain top, 0.0 at/below — no block light).
	// The real band (all-real worlds) still emits a=1.0, so lit==1.0 and
	// the legacy brightness is byte-identical. A cave far band (a=0.0)
	// renders at the 0.2 floor instead of full bright. ALPHA stays 1.0
	// (the a channel is light, not transparency).
	float lit = mix(0.2, 1.0, COLOR.a);
	// AC-0443: the a=0 faces (COLOR.a 0.0 = "at/below the terrain top")
	// carry the 0.2 cave floor even when the face is a sky-exposed
	// surface cliff — the R24 horizon dark patch: a west-facing ridge
	// flank at 130 m read (30,27,23) at midday while the BAND A
	// (chunk_lit) flank of the same ridge reads ~(135,116,103). The
	// AC-0426/AC-0432 "unlit terrain = shaded, not black" collapse was
	// fixed for the chunk tiers and never crossed the tier seam. The
	// same measured lift (AMB_SKY_L), day-gated (night ~= 1/255, OFF =
	// bit-identical via u_amb = 0.0):
	lit += u_amb * day.r * (1.0 - COLOR.a);
	ALBEDO = COLOR.rgb * day.rgb * jit * lit;
	// AC-0401: the fog-wall partition (kept — it is not fog). The
	// satellite body owns the rule "the body is only where the world's
	// depth fog has already fully faded the world (d >= u_fog_far)";
	// this material is part of the world, so it obeys the same wall:
	// the annulus ends at the fog wall instead of drawing PAST it,
	// coplanar with the body's own displaced terrain at the same view
	// distance (the orbital fog-colour patch + the 332-400 m z-fighting
	// band, the pre-AC-0401 state). The engine environment fog does the
	// fading up to the wall (AC-0415: this material now rides it, like
	// every other near-tier material) — the factor reaches 1.0 exactly
	// at the wall, the single-source seam with the body's haz_d rim.
	vec3 V = CAMERA_POSITION_WORLD - v_world_pos;
	float d = length(V);
	if (d >= u_fog_far && !ac0451_covered(d)) {  // AC-0451 P1: the coverage rule (the stub is inert)
		discard;
	}
	ALPHA = 1.0;
}
