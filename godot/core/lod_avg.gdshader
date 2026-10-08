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
//
// AC-0404: the HAZE BRIDGE IS REMOVED (the r8/AC-0399/AC-0400 history
// above is history — the bridge no longer exists in this material).
// The bridge forced haz = 1.0 (100% air colour) across the outer 48 m
// of the annulus at EVERY view distance — a limb treatment on a
// NEAR-TIER material: it mirrored the satellite body's rim onto the
// ground, and the user saw it as "the limb effect applied to the low
// LODs" (visible wherever the player is far enough from the world
// origin that the bridge's 336-384 m taxi band sits inside the view
// distance; at the ladder geometry the band sits exactly at the
// partition wall, so the harness frames never painted it). The
// atmospheric limb belongs to the satellite lod's material alone
// (satellite_body.gdshader haz_a/haz_d — kept). This material is now
// FOG-ONLY: the annulus fades with the engine depth-fog model
// (fog_f — the same factor band A receives at the same view distance,
// so the band A/annulus boundary is continuous by construction, as in
// r8) and ends at the partition wall (d >= u_fog_far, AC-0401), where
// fog_f = 1.0 = u_air — the body's haz_d rim at the same wall, so the
// AC-0400 single-source seam is preserved by construction, and now at
// EVERY view distance, not only at the bridge's inner edge. No gate
// can bring the term back: it is not in the path.
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
	// AC-0401: the fog-wall partition. The satellite body owns the rule
	// "the body is only where the world's depth fog has already fully
	// faded the world (d >= u_fog_far)"; this material is part of the
	// world, so it obeys the same wall. Pre-AC-0401 the annulus kept
	// drawing PAST the wall at 100% fog colour (fog_f = 1 here) - over
	// the body's own displaced terrain at the same view distance,
	// coplanar with it: the fog-colour diamond patch in the orbital
	// frames (the "patch of ground you just left") and the 332-400 m
	// z-fighting band. The body's haz_d rim at the wall is exactly the
	// single-source air colour (u_air), so the seam target AC-0400 set
	// is preserved - the fade now runs in the body's own rim instead of
	// in this annulus, which ends at the wall.
	if (d >= u_fog_far) {
		discard;
	}
	float fog_f = clamp((d - u_fog_near) / max(u_fog_far - u_fog_near, 1.0), 0.0, 1.0);
	// AC-0404: FOG ONLY (the haze bridge is gone — see the header). The
	// annulus fades with the engine depth-fog model, the same factor
	// band A receives at the same view distance; at the partition wall
	// fog_f = 1.0 = u_air, the single-source seam with the body's haz_d
	// rim (AC-0400). This path carries no limb term in any state.
	float haz = fog_f;
	ALBEDO = mix(ALBEDO, u_air, haz);
	ALPHA = 1.0;
}
