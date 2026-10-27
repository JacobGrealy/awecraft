// AC-0446: the far-seam PARITY variant of the med/low AVERAGE-COLOR LOD
// material (the 8x8x8 med + 4x4x4 low placeholder tiers — vertex-color
// geometry, NO UVs, no texture). ON of Settings "far_seam" (default OFF —
// OFF is the original lod_avg.gdshader, unchanged and bit-identical;
// AWECRAFT_FARSEAM=0|1 at boot, world.gd).
//
// WHY A VARIANT AND NOT A UNIFORM: the defect is the TIER SEAM — the same
// ridge face reads ~3x darker through the band than one tier closer
// (measured (50,40,31) vs (135,116,103), AC-0443's R24 frame). The shape
// of the difference (the two shaders side by side, tasks/AC-0446/plan.html):
//   - the near tier is `render_mode unshaded` — its L (0.20 + 0.80·m_direct
//     + the AC-0426 lift + the AC-0436 moon lambert) is the WHOLE light;
//   - the band is SHADED — the engine multiplies its ALBEDO by (sun·lambert
//     + sky·ambient) ON TOP of its own `lit`, and the band additionally
//     carries the day-gray tint the near tier has no.
// Result: the band's a=0 faces (the heightmap-sky floor, the sky-exposed
// surface cliffs — the visible band) are ~3x too dark, while its a=1 tops
// are ~17% too bright. NOT a constant factor — a single multiplier cannot
// close the seam (the ticket's named risk).
//
// THE FIX IS STRUCTURAL: the band's per-vertex a channel is exactly the
// near tier's two face classes at the seam — 1.0 = sky-exposed top (the
// near tier's s=1) and 0.0 = at/below the terrain top (the near tier's
// light floor 20/255 — mesh.cpp: the avg quad alpha = skyp/15 with
// skyp ∈ {0,15}; the near tier packs the same 20/255 floor into its sky
// channel). So this variant runs UNSHADED, mirrors the near tier's L model
// on that data (m_direct = mix(20/255, u_day, COLOR.a)), and drops the
// day-gray tint the near tier has no. Every face class then computes the
// same L the near tier does — the seam closes by construction; the
// residual is the band's own 8x8 color AVERAGING + the ±6% world-fixed
// jitter (its representation limit, the near tier's per-vertex texture it
// cannot carry).
//
// KEPT FROM lod_avg.gdshader: the ±6% world-fixed breakup jitter (stable
// under camera motion), and the AC-0401 fog-wall partition (NOT fog — the
// annulus ends at u_fog_far so the near tiers never draw over the body's
// displaced terrain; main.gd pushes u_fog_far every frame). The engine
// ENVIRONMENT FOG still applies (unshaded materials ride it unless
// fog_disabled — the AC-0415 single source): the far terrain's depth cue
// is the fog's, not this shader's — a wide shot verifies the gradient.
//
// NIGHT / DAY-GATE: the lift term is ×u_day — 0.0 at night (DayNight.day
// is exactly 0.0), so the day-gating is the near tier's own (the AC-0426
// contract). The band's night becomes the near tier's own night (the 0.20
// floor + the moon's lambert, u_moon = MOON_L·(1−day) — 0.0 by day or
// with "moonlight" OFF), not the old near-black: at night the unshaded
// floor 0.20 ACES-crushes to a few 8-bit units, the same value the near
// tier's night reads (the AC-0436 calibration), so the seam is closed at
// night too. The u_amb lift and the u_moon term are both 0.0 whenever the
// near tier's corresponding term is 0.0 — parity at every hour.
//
// OMITTED BY CONSTRUCTION: the near tier's player-light term
// (L = max(L, 0.12 + 0.88·pr/15)) — at band distances (taxi ≥ 6, ≥ ~90 m)
// pr ≡ 0 and the term degenerates to max(L, 0.12), a no-op under the 0.20
// floor. No player uniforms are owed.

shader_type spatial;
render_mode unshaded;

uniform float u_day : hint_range(0.0, 1.0) = 1.0;  // DayNight.day(t) — world.gd per frame
uniform float u_fog_far = 332.0;  // env.fog_depth_end (main.gd) — the AC-0401 partition wall
// AC-0446: the AC-0426 parity lift (Settings "ambient_sky", AMB_SKY_L via
// world.gd _ac0401_push — the same push the chunk materials get). 0.0 is
// the bit-identical pre-lift path; the term is ×u_day (day-gated).
uniform float u_amb : hint_range(0.0, 1.0) = 0.0;
// AC-0446: the AC-0436 moon term — the same push the chunk materials get
// (u_moon = MOON_L·(1−day)·switch, u_moon_dir = the direction TO the moon).
// 0.0 by day / with "moonlight" OFF -> the term is 0.0 -> bit-identical.
uniform float u_moon : hint_range(0.0, 2.0) = 0.0;
uniform vec3 u_moon_dir = vec3(0.0, 1.0, 0.0);
// AC-0480 r3: the seam-lattice probe (u_debug = 0.0 by default — the block
// below is skipped entirely, so the shipped path is bit-identical). 1.0
// paints a thin (0.75 m) MAGENTA line on every 16 m CHUNK plane of the
// band — the chunk-grid reference for the intra-tier seam ticket (the
// measured seam lattice is the 2 m avg CELL, 1/8 of the chunk, so a
// healthy frame shows ~8 seam lines between two magenta lines and no
// extra structure on them).
uniform float u_debug = 0.0;

varying vec3 v_world_pos;
// AC-0451 P1: the coverage-predicate switch (AWECRAFT_COVERAGE=0|1 —
// the contract comment lives in world/chunk_lit_opaque.gdshader). P1
// is INERT: the stub below answers false for every d, so the discard
// is byte-identical to the pre-ticket build; P2 turns the real query
// on. Declared in BOTH lod variants so the AC-0446 material-shader
// swap (world._ac0446_apply_shader) keeps the stored parameter valid.
uniform float u_coverage : hint_range(0.0, 1.0) = 0.0;
// AC-0451 P2: the body's solid boundary — its op ramp (satellite_body.
// gdshader: op = smoothstep(u_fog_far, u_render_edge, d)) reaches full
// opacity at d >= u_render_edge. (render_radius+1)*16, the same source
// main.gd pushes the same uniform from (world.render_radius); world.gd
// _ac0401_push (the (1a2) block) pushes it change-gated.
uniform float u_render_edge = 400.0;
bool ac0451_covered(float d) {  // AC-0451 P2: covered where the body is already solid
	return u_coverage > 0.5 && d >= u_render_edge;
}

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// AC-0401: the fog-wall partition (the band is part of the world, so
	// it obeys the same wall as every near-tier material).
	float d = distance(CAMERA_POSITION_WORLD, v_world_pos);
	if (d >= u_fog_far && !ac0451_covered(d)) {  // AC-0451 P1: the coverage rule (the stub is inert)
		discard;
	}
	// ~1.5-block noise cells in world space (the far LOD samples are
	// 2-4 blocks, so the jitter stays sub-cell — breakup, not texture;
	// the lod_avg.gdshader contract, unchanged).
	vec3 cell = floor(v_world_pos * 0.6667);
	float h = fract(sin(dot(cell, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
	float jit = 1.0 + (h - 0.5) * 0.12; // +/-6% around the vertex color
	// The near tier's L model on the band's binary data
	// (chunk_lit_opaque.gdshader owns the formula; this is its twin):
	// COLOR.a 1.0 (the sky-exposed top) reads the full sky scalar,
	// u_day — the near tier's s=1 faces read max(u_day·1, g) = u_day by
	// day. COLOR.a 0.0 (at/below the terrain top — the unlit sides, the
	// sky-exposed surface cliffs) reads 20/255 — the EXACT value the near
	// tier's unlit faces read after the 8-bit packing (the MIN_AMB floor
	// in chunk.gd/mesh.cpp; the step threshold below is the near tier's
	// own 0.08, and 20/255 ≤ 0.08 fires the lift, exactly as there).
	float m_direct = mix(20.0 / 255.0, u_day, COLOR.a);
	float L = 0.20 + 0.80 * m_direct;
	// The AC-0426 light-floor sky-ambient lift (×u_day — day-gated, 0.0 at
	// night; 0.0 with "ambient_sky" OFF via the shared push):
	L += u_amb * u_day * step(m_direct, 0.08);
	// The AC-0436 moon lambert (the band mesh carries world-space face
	// normals — the ring merge's per-column rotation, AC-0416):
	L += u_moon * max(dot(NORMAL, u_moon_dir), 0.0);
	ALBEDO = COLOR.rgb * jit * L;
	ALPHA = 1.0;
	// AC-0480 r3: the seam-lattice probe — a thin magenta line on every
	// 16 m CHUNK plane of the band, so the visible seam grid can be
	// compared against the chunk grid in ONE frame (seams ON the magenta
	// lines = the chunk grid; a finer lattice BETWEEN them = not).
	// u_debug 0.0 (default, world.gd _lod_avg_mat env-gated via
	// AWECRAFT_LATTICE_DEBUG) skips this block — bit-identical.
	if (u_debug > 0.5) {
		vec2 fc = v_world_pos.xz - floor(v_world_pos.xz * 0.0625) * 16.0;
		float dc = min(min(fc.x, 16.0 - fc.x), min(fc.y, 16.0 - fc.y));
		if (dc < 0.75)
			ALBEDO = vec3(1.0, 0.0, 1.0);
	}
}
