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
// AC-0384 r8: the HAZE BRIDGE. This material owns the far tier (the
// 128-384 m annulus about the terrain anchor). Pre-r8 it took the plain
// engine depth fog: at any altitude above the fog wall the whole annulus
// repainted 100% fog colour — a flat featureless ring whose outer edge
// stepped hard onto the satellite body's crisp terrain (the body's haz is
// haz_a + (1-op), ~0 at the render edge: op is 1 there, haz_a is
// limb-only). Measured at the user's config (R24, fog full at 332 m):
// annulus median (76,156,179) vs the dome just outside (117,199,220) at
// 700 m — the visible discontinuity. Now the fragment haze is a
// crossfade across the annulus from the ENGINE-FOG MODEL (the inner
// edge: the same factor as band A at the same view distance, so the
// band A/annulus boundary is continuous by construction) toward the
// single-source AIR COLOUR (the outer edge, AC-0400 — see below). One
// fade instead of a wall with a hard edge: ground -> haze -> air. Fog
// stays DISABLED here (the engine fog would re-assert its flat factor
// over the crossfade) — the bridge IS the fog, now with the body's
// geometry in it.
//
// AC-0400: the OUTER-EDGE TARGET of the crossfade changed. r8 faded the
// outer 48 m toward haz_b — a mirror of satellite_body.gdshader's own
// haz (haz_a + (1-op)) — so the annulus/dome boundary matched in HAZE
// WEIGHT. That only works while the dome's haz there is substantial
// (ground altitude: haz_b ~ 0.6, a hazy dome the annulus dissolves
// into). At the orbital nadir haz_b ~ 0 (limb haz is limb-only; op = 1
// at the render edge), so the fade went toward the un-fogged slab base
// instead of the air — the AC-0283 lit-0.2 floor (measured (16,8,0) in
// AC-0399 §4) — a thin dark rim at the annulus's outer edge, the residue
// AC-0399 documented and left (its mix-argument swap had fixed the
// core, not the fade target). AC-0400 points the fade at u_air: the
// SAME single source main.gd pushes as env.fog_light_color
// (AeroLib.fog_display) to this material, to the satellite body and to
// the sky horizon — one air colour, no fourth. The annulus now
// dissolves into the air behind it at every altitude; the dome keeps
// its own haz model for its own edge (satellite_body.gdshader).
shader_type spatial;
render_mode fog_disabled;

uniform vec4 day : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec3 u_air : source_color = vec3(0.529, 0.808, 0.922);  // AeroLib.fog_display (main.gd)
uniform float u_fog_near = 100.0;   // env.fog_depth_begin (main.gd)
uniform float u_fog_far = 332.0;    // env.fog_depth_end (main.gd)
uniform float u_render_edge = 400.0;  // (R+1)*16 (main.gd)
uniform vec3 u_center = vec3(0.0, -4000.0, 0.0);  // planet centre (main.gd)

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
	// AC-0283 P3: the HALO band's light is the heightmap sky carried in
	// COLOR.a (1.0 above the terrain top, 0.0 at/below — no block light).
	// The real band (all-real worlds) still emits a=1.0, so lit==1.0 and
	// the legacy brightness is byte-identical. A cave far band (a=0.0)
	// renders at the 0.2 floor instead of full bright. ALPHA stays 1.0
	// (the a channel is light, not transparency).
	float lit = mix(0.2, 1.0, COLOR.a);
	ALBEDO = COLOR.rgb * day.rgb * jit * lit;
	// AC-0384 r8: the crossfade (see header). d = view distance (the
	// engine fog's own coordinate); w = 1 inside the annulus, 0 beyond
	// the render edge — the MANHATTAN distance from the terrain anchor
	// (0,0,0), because the tiers are taxi diamonds (|x|+|z| in chunks),
	// so the blend lands exactly on the tier boundaries. fog_f is the
	// engine depth-fog ramp (the band A's factor at the same d).
	vec3 V = CAMERA_POSITION_WORLD - v_world_pos;
	float d = length(V);
	float fog_f = clamp((d - u_fog_near) / max(u_fog_far - u_fog_near, 1.0), 0.0, 1.0);
	float taxi = abs(v_world_pos.x) + abs(v_world_pos.z);
	// The fade occupies the OUTER 48 m of the annulus (336-384), not the
	// whole band: with w=1 out to 336, haz = fog_f (the engine ramp)
	// across the nadir core, so at orbit altitude the near field stays
	// the fog wall the pre-r8 frames show (the 2600 m grain box must not
	// see the slab texture through the haze - measured 7.33/4.02 vs the
	// 4.71/1.90 gate when the fade spanned 128-384). The fade is
	// smoothstep (zero slope at both ends) and ends exactly at the tier
	// boundary.
	float w = 1.0 - smoothstep(336.0, 384.0, taxi);
	// AC-0399 r1: r8 shipped the mix BACKWARDS — mix(fog_f, haz_b, w)
	// returned haz_b (~0 at the orbital nadir: the body's limb haz with
	// cosv~1, op=1) across the whole w=1 core, contradicting the block
	// above ("with w=1 out to 336, haz = fog_f"): at 2600 m the built
	// annulus rendered the AC-0283 lit-0.2 base (measured (16,8,0), a
	// dark diamond) instead of the fog wall. Swapped so w=1 -> fog_f
	// (the engine ramp, the nadir core) and w=0 -> the seam target,
	// exactly as written.
	// AC-0400: the seam target (w=0 end of the fade) is the
	// SINGLE-SOURCE AIR COLOUR — full u_air (the weight below is 1.0),
	// not the dome-mirror haz_b r8 used. haz_b ~ 0 at the orbital nadir
	// made the fade go toward the lit-0.2 slab base — the dark rim at
	// the annulus edge (AC-0399 §7). u_air is the same single source the
	// fog wall, the dome haze and the sky horizon use (main.gd pushes
	// env.fog_light_color = AeroLib.fog_display(t) to all three); no
	// fourth colour is introduced. The dome keeps its own haz model for
	// its own edge (satellite_body.gdshader).
	float haz = mix(1.0, fog_f, w);
	ALBEDO = mix(ALBEDO, u_air, haz);
	ALPHA = 1.0;
}
