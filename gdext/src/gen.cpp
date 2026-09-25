// AC-0215 (supersedes AC-0188): the MC 1.18 style COARSE 3D DENSITY FIELD
// gen — caves AND surface come from ONE field (the user's AC-0215 ask:
// "replace the heightmap + per column cave carve").
//
// The per-cell DENSITY (one field, sampled on a coarse 4x8x4-CELL grid per
// chunk — 4x48x4 BLOCKS per cell: 4 x, 8 y-cells of h/8 = 48 blocks, 4 z
// (AC-0347 P1 doc fix — the "4x8x4" cell count was readable as vanilla's
// 4x8x4-BLOCK cell); 7x9x7 = 441 lattice points per field, the 1-cell
// margin covering the 2-ring tree neighborhood; each lattice point an
// AweNoise sample):
//
//   AC-0347 P2 (cave-density rebudget — THE STRUCTURE, the vanilla DENSITY
//   ROUTER, Java 1.21.4 noise_settings/overworld.json final_density — the
//   range_choice at its core, verified against the shipped JSON): the ONE
//   field is now a SHALLOW/DEEP SPLIT, switched by k = H - y (the DEPTH
//   FROM THE SURFACE — NOT S_ramp, which saturates):
//
//     k <  K_CUT (K_CUT = 16 — the P3-recalibrated switch depth, the
//            ticket's 10-25 band; the ramp saturates at +1 for k >= 9.5,
//            so the whole shallow band is solid + entrance slits)
//            [SHALLOW]:
//        d = min( S_ramp(H, y), 5 * entrances )
//     k >= K_CUT [DEEP]:
//        d = min( entrances,
//                4 * layer_c^2 + clamp(-1,1)(0.27 + cheese_c)
//                + clamp(0, 0.5)(1.5 - 0.64 * k / K_CUT) )
//
//   THE LOAD-BEARING FACT: in the DEEP branch the base terrain contributes
//   NOTHING — the suppressor clamp(0,0.5)(...) is 0 once k >= 37.5
//   (2.34375*K_CUT) and the
//   ramp appears nowhere else in that branch, so below the shallow band the
//   solid/air decision IS the cave router (that is why vanilla's O(1) cave
//   constants are portable; our old S_ramp was +1 EVERYWHERE below H-10 and
//   A(y) was the lever fighting it — BOTH GONE with the structure: the
//   AC-0288 C-budget invariant 1.8*max|C-0.5| < 1 is RETIRED, not carried:
//   the H+11 scan-start "air for sure" margin is now STRUCTURAL — for
//   y >= H+10.5 the ramp clamps -1 exactly and the shallow branch reads
//   min(-1, 5*entrances) <= -1 < 0 for ANY noise values, so no noise term
//   can add solidity there. P1's field statistic (max|C-0.5| 0.353027 ->
//   1.8*0.353027 = 0.6354 < 1) is recorded, not load-bearing.)
//   The old A(y) / DEEP_GROW / CAVE_AMP depth-amplifier structure (and the
//   "the deep fattens sooner" tuning) is GONE: vanilla suppresses near the
//   surface (the clamp above, +0.5 solid, gone by k = 2.34375*K_CUT) and
//   the layer term 4*layer_c^2 (always positive — the SQUARED layer noise,
//   ONE-SIDED as in vanilla) gates the cheese caves into ~32-block stacked
//   levels in ABSOLUTE y (cave LEVELS only read as levels at consistent
//   world heights — the user's ask), instead of amplifying with relative
//   depth. The router's max(..., pillars_choice) outer term is AC-0292's
//   (SEQUENCE: this lands before AC-0290/0291/0292).
//   CENTERING (the unit decision): every ported noise value is
//   2*(vn3 - 0.5) — the vanilla convention (noise centred on 0, O(1));
//   the vanilla constants (0.27, 0.64, 1.5, 5, 4, 0.37) are only
//   meaningful in those units (un-centred, 0.27+cheese would be
//   always-positive and the deep branch solid everywhere).
//   S_ramp = the quintic SPLINE SURFACE DENSITY (C2, the same polynomial as
//            AweNoise._fade) clamped to +/-1: +1 (solid) below the surface,
//            -1 (air) above, the zero crossing IS the surface. R = 10.
//            KEPT as the SHALLOW branch's surface (the ticket's KEEP list:
//            H + S_ramp are the far payload / promotion / skip-fill
//            contract — the surface model is NOT replaced).
//   entrances = the ENTRANCE FAMILY, the vanilla caves/entrances function
//            WITHOUT its spaghetti_3d min (ours: the AC-0289 tunnel rule,
//            which stays OUTSIDE dens_at — the tunnels keep piercing the
//            caps and connecting the levels, the vanilla topology):
//              entrances = 0.37 + 2*(E - 0.5) + 0.3*(1 - clamp01((y-54)/40))
//              E = vn3(x*0.75, y*0.5, z*0.75, seed+306, -7, [0.4, 0.5, 1.0])
//            — the vanilla cave_entrance noise instance AS-IS (the +64
//            world shift maps vanilla's y-gradient from_y -10 / to_y 30
//            onto our 54 / 94); the 0.37 offset makes entrances RARE — the
//            surface breaks only in the noise's lower tail. The shallow
//            5*entrances carves the surface openings (the "deliberate
//            entrances"); the deep min(..., entrances) extends them down —
//            vanilla: "call the cave entrance again here, otherwise the
//            entrance would only be generated in the surface part and cut
//            off at the underground part".
//   layer_c / cheese_c: the centered (2*(v-0.5)) values of the two vn3
//            fields — the layer (vanilla cave_layer AS-IS, {firstOctave -8,
//            amplitudes [1.0]}, xz 1.0 / y 8.0 — the ~32-BLOCK vertical
//            period; AC-0359: on the C48 CAVE lattice, the period rides 4
//            samples/period — pre-AC-0359 it was evaluated DENSELY in the
//            scan, a 32-block period cannot ride the 48-block SURFACE
//            lattice, AC-0344's cell-size decision; seed+302 = the slot
//            P1 freed) and the cheese (see below).
//   C(x,y,z) = trilinear of the coarse 3D CAVE field — AC-0347 P1:
//            vanilla's cave_cheese AS-IS, sampled with the vn3 octave
//            machine (AweNoise.vn3 / the mirror below — a custom AMPLITUDE
//            LIST + a firstOctave FREQUENCY OFFSET, normalized by
//            sum(|a_i|)):
//              C = vn3(x*1.0,  y*0.6667, z*1.0, seed+301, -8,
//                     [0.5, 1, 2, 1, 2, 1, 0, 2, 0])
//            — the scale MULTIPLIES the block coordinate (the vanilla
//            convention); dominant wavelengths ~64 blocks xz / ~96 y. The
//            old AC-0288 field (C1 = fbm3(gx/14, ...) + C2 = fbm3(gx/8,
//            ...) blended 0.30) is GONE — this field replaces it (the
//            seed+301 slot is kept). The dense source is
//            AweGen::density_cave (genprobe lockstep).
//
//   AC-0289 (cave P1, the SPAGHETTI/NOODLE TUNNELS — Bedrock-style EDGE
//   densities blended into this one field, tasks/cave-compare §4 P1):
//   three MORE coarse fields (same 7x9x7 lattice, 2 octaves each, built
//   ONLY on the full path — the skip and far paths never read them, so the
//   H / far / promotion contracts stay bit-exact by construction):
//     f_spag = fbm3(gx/14,   gy/10, gz/14,   seed+303, 2)  (spaghetti —
//              the wide tagliatelle; 1.0x the primary cave xz scale)
//     f_nood = fbm3(gx/10.5, gy/10, gz/10.5, seed+304, 2)  (noodle — the
//              1-5-wide wormholes; 0.75x the primary cave xz scale)
//     f_gate = fbm3(gx/56,   gy/10, gz/56,   seed+305, 2)  (the RARITY
//              SELECTOR — a low-frequency 3D patchiness: tunnels appear in
//              patches, not world-wide; the AweCraft stand-in for Bedrock's
//              spaghetti_3d_rarity, which picks the spaghetti scale per
//              region)
//   Tunnel air where the EDGE wins (the max(|noise|-threshold) test):
//     |f_spag - 0.5| < SPAG_TH * w  or  |f_nood - 0.5| < NOOD_TH * w
//   with w = clamp01((f_gate - GATE_LO)/(GATE_HI - GATE_LO)) — the
//   thickness scales with the gate weight (the tunnel pinches out at the
//   patch edge). The rule is applied BEFORE the he/solidf scan's solid
//   flag (a tunnel carves air even where the cheese field says solid) and
//   identically in the veg margin scan (the tree base matches the full
//   column). The heightmap H (surface_h of the 3 SURFACE fields) is
//   untouched — a tunnel breaking the surface only wobbles the EFFECTIVE
//   surface (he), inside the documented H+/-R band, exactly like the
//   cheese term already does. The H+R+1 scan-start "air for sure" margin
//   is preserved (the tunnel only removes solidity).
//
//   AC-0359 (the AC-0344 C48 decision — the CAVE FAMILY ON AN 8-BLOCK-Y
//   LATTICE): the cave family (cheese + the 3 tunnel fields + the NEW
//   layer + entrance fields) rides a SECOND lattice, GY_CELLS_CAVE = 48
//   (8-block y cells — Bedrock's resolution) vs the surface/ore lattice's
//   48-block cells: FieldC = 7x49x7 = 2401 points, SAME xz cells. The
//   in-column AND veg-margin scans read every cave input trilinearly off
//   it (tril_c / tunnel_air_c / entrance_from_latt — the entrance y
//   gradient stays analytic per-y) — the two dense per-block vn3 calls
//   (entrance_cave / layer_cave) LEAVE the scan (they stay bound for the
//   genprobe lockstep). The surface + ore fields (f_sc/f_sh/f_sr,
//   f_ore1-3) and every skip/far path are UNTOUCHED (GY_CELLS = 8), which
//   is what makes H / the far payload / the skip payload bit-exact by
//   construction (thash 8df7aeb4... byte-identical, the gate proves it).
//   Measured (AC-0344, seed 44, 5x5 window): per-chunk generation
//   5076 -> 2884 us (-43.2% — the scan drops 4373 -> 1291 us, the field
//   build grows 237 -> 1046 us), and the deep zone goes from a continuous
//   75-78% air void to structured stone (k 50-80 air 78.7% -> 21.8%,
//   k 80-130 75.1% -> 37.6%; an 85%-solid band at abs y 48-72; air runs
//   collapse to <= 32 blocks; surface openings avg 92 -> 21 depth, max
//   141 -> 62). Second-order fidelity residuals (recorded, not fixed):
//   the trilinear between the 8-block samples undershoots the dense
//   quintic PEAK amplitude (~cos(pi/4) = 0.707 for the layer's 4
//   samples/period sinusoid — the level caps read marginally weaker than
//   dense), and the entrance's finest y feature sits at the sampling
//   border (the analytic gradient term is exact — see AC-0359's results
//   page for the measurement of both).
//
//   AC-0290 (cave P2 — the classic CARVER family: galleries,
//   bubble-interrupted trunks, ravine canyons): the pre-1.18 worm carvers,
//   re-added as a POST-DENSITY pass. Vanilla's worldgen runs the carver
//   stage after the density field; ours runs it after the flat[] fill,
//   before veg — the same ordering in substance, and deliberately
//   SEPARATE from the density router (the router stays vanilla's; the
//   post-pass is exactly why the carvers can intersect the surface and
//   features with a cut-through policy). The families (vanilla parameters —
//   minecraft.wiki/w/Cave §Carver caves + the 1.21
//   data/minecraft/worldgen/configured_carver JSONs, +64 y-shift onto the
//   0-based world): cave carver 0.15/chunk (cave.json probability), canyon
//   0.01/chunk (canyon.json probability); Y range vanilla -56..180 -> ours
//   8..244 (cave.json y = uniform above_bottom 8 .. absolute 180 — the
//   ticket's "absolute Y range -56..180"); the main room (the gallery) is
//   1-in-4 of the carvers (the ticket's main-room vs I/T split) — 1-14
//   tall, Ø 5-15, FLAT FLOOR (the floor plane is the ellipsoid's bottom
//   tangent: full-ellipse floor, elliptical dome ceiling) + a short exit
//   trunk (the "room + trunk" shape); the trunk is 85-112 long (the
//   ticket), direction wander + vertical drift, per-trunk radii (h 2-8 /
//   v 1-9 — inside the wiki's 2-38 h / 1-36 v thickness range once the
//   flicker and bubbles are in), per-step THICKNESS FLICKER (0.6-1.4x) and
//   BUBBLE INTERRUPTIONS (~12% of the steps carve a 1.6x bulb — the wiki's
//   "cave with bubbles"), 1-3 branches of 2-7 h / 1-7 v thickness at
//   right-ish angles (the I/T shapes); the canyon (the tall ravine,
//   canyon.json) is a vertical shaft starting at y 74..131 (vanilla 10..67),
//   horizontal radius ~1-3 (thickness trapezoid(0,6,plateau 2) x factor
//   0.75-1.0), VERTICAL RADIUS = 3x HORIZONTAL (yScale 3.0),
//   vertical_rotation ±0.125 (the meander), length 45-150 x
//   distance_factor 0.75-1.0 — it punches the surface: the steep cliff
//   walls. DETERMINISM: a per-chunk splitmix64 stream (chunk-hash of world
//   seed + cx/cz) — a pure f(seed, cx, cz); NO noise field is involved (the
//   carvers are geometry, like the tree pass — the genprobe lockstep
//   contract covers the AweNoise sources only). THE CUT-THROUGH POLICY: a
//   carved cell replaces whatever solid is there (stone, ore, dirt, sand,
//   the surface block — the trees/flowers do not exist yet, veg runs after)
//   with AIR (or LAVA at y < 8 — the same deep-pocket rule the fill gives
//   field-carved air). AIR/WATER/LAVA are never re-carved (a submarine
//   carve reads flooded — the AC-0342 model — water is not a carvable
//   solid); the bedrock row y = 0 is out of range by construction. If the
//   carve drops a column's topmost solid (he2 < he), the new top is
//   re-skinned with the fill's EXACT surface rule (grass / sand / snow-
//   grass + the 3-deep dirt band — the vanilla finalize-stage behavior:
//   cave mouths get a grass lip). H (the heightmap), the 3 surface fields
//   and SEA are NEVER touched — the pass may lower the EFFECTIVE surface,
//   which is the documented wobble class the farab contract already
//   tolerates (the entrance/tunnel mouths do it today). The skip (1/2) and
//   far paths never build the plan at all — the far/skip payloads stay
//   bit-exact by construction (thash + farab h_mismatch prove it per run).
//   A(y) = 1.8 * (1 + max(0, H - y - R) / DEEP_GROW) — the cave amplitude
//   — is GONE with DEEP_GROW and CAVE_AMP at AC-0347 P2 (the structure
//   change: the shallow suppressor + the squared layer term replace the
//   depth amplification). The old "air for sure above H+R+1" invariant
//   (CAVE_AMP * max|C-0.5| < 1; P1 re-derived it on the new field as
//   1.8 * 0.353027 = 0.6354 < 1) is RETIRED with A(y) — the margin is now
//   structural (the scan-start comment): the ramp clamps -1 above H+10.5
//   and the shallow branch reads min(-1, 5*entrances) <= -1 < 0 for any
//   noise values.
//   H(x,z) = the surface height derived from the coarse 3D SURFACE field —
//            the AC-0091 2D heightmap (c/h/r fbm2) is REPLACED by the 3D
//            fields on the same 4x8x4 grid, read at the sea-level slice
//            y = 126 (trilinear):
//              c = tril(f_sc, gx, 126/ystep, gz)  fbm3(X/220,  Y/64, Z/220,  seed,     3)
//              h = tril(f_sh, gx, 126/ystep, gz)  fbm3(X/70+333,  Y/64, Z/70+333,  seed+7, 4)
//              r = tril(f_sr, gx, 126/ystep, gz)  fbm3(X/300+500, Y/64, Z/300+500, seed+13, 3)
//            The slice stats differ from the old 2D fbm's, so the remap is
//            affine-calibrated per field onto the OLD 2D distribution (see
//            surface_h — the calibration constants), keeping the AC-0091
//            ocean/land/mountain balance (sea 126). H = 105.2 + cc*36.4 +
//            hc*52 + (rc > 0.62 ? (rc-0.62)*390 : 0), clamp [3,300]. The
//            SPAWN PAD (d<=6 -> 136 flat, 6<d<=10 smoothstep blend) was
//            REMOVED at AC-0314 — the spawn plateau is gone; the player
//            spawns on natural terrain via the AC-0324 deterministic search.
//
// SOLID where d > 0, AIR where d < 0. The surface, the caves, and the deep
// lava lakes (deep cave pockets at y<8 fill LAVA instead of air) all come
// from this one field. The aquifer is unchanged: water fills from the
// effective surface up to SEA (126) where the surface is below sea.
//
// Kept from AC-0188/AC-0091:
//   * the coarse ORE fields + OLD bands/thresholds (diamond y<16 >0.78,
//     iron y<42 >0.8, coal y<60 >0.82); obsidian keeps the exact old
//     per-cell hash3i(x,y,z,seed+333) < 0.02 (now y 8..9; the y<8 cave
//     pockets are the lava floor);
//   * the 2D biome texture field (t/m fbm2) for the surface block / dirt /
//     snow / desert colors (biomes are a surface texture, not terrain);
//   * trees + flowers: exact old hash logic, base = the effective surface
//     (h_eff = topmost d > 0 of the one field) instead of the 2D height.
//
// NOISE INVARIANT: hash2i/hash3i/fade/lerp/vnoise2/vnoise3/fbm2/fbm3/vn3
// are bit-for-bit ports of godot/core/noise.gd (f64 math, i64/i32 integer
// hash, lerpf = a + (b-a)*t; vn3 = the vanilla octave machine — AC-0347
// P1, the frequency is an exact power of two, no pow). gen.cpp is
// compiled with -ffp-contract=off so the compiler never contracts the
// fade/ramp polynomials into FMA (baseline x86-64 has none, MinGW
// included). Verified by AWECRAFT_LOGIC=genprobe.
//
// The terrain is NEW again (new genhash baseline — expected, AC-0215 gate):
// the surface now comes from the coarse 3D surface field, the caves run the
// full depth from the same field, and the genhash is deterministic (two
// runs byte-identical).
//
// AC-0216 LAZY SKIP (offscreen interior bands): generate_flat/slabs/resl
// take an optional 6th arg `skip` (default 0 — the pre-AC-0216 behavior,
// bit-for-bit). When skip != 0 the 150-pt per-column DENSITY EVALUATION is
// skipped free: the cave field (f_cheese) is not built and the top-down
// d > 0 scan does not run; the column is solid exactly 0..H (the heightmap
// surface from the coarse 3D surface field), he = H, no caves, no lava
// pockets — NO HIDDEN CAVES BUILT in the chunk. The surface (H), the ore
// fields, the biomes, trees and flowers are UNCHANGED (the visible surface
// is still correct). The caller (the GDScript streaming system, world.gd
// _gen_skip_flag) sets skip only for OFFSCREEN INTERIOR chunks: band > 1
// (the band-3 data-only collar/ring — outside the render circle, never
// meshed until the player approaches) AND the whole column AABB fully
// past the camera frustum (expanded by the AC-0109 cull margin). Visible
// bands 0/1 always run the full density field (caves stay exact where the
// player can see them). Cumulative counters (skip_chunks_total /
// skip_cols_total) let the harness report how many columns skipped.
//
// AC-0284b FAR (h-only) COLUMNS: skip == 2 (generate_resl) produces NO
// slabs at all — only the 1024-byte FAR PAYLOAD (256 H as u16 LE + 256
// biome + 256 top-block id; see gen_far). The H is bit-exact with the
// full path's H (the shared col_heights_pass — the 3 surface fields at
// the same lattice; the promotion-consistency contract). skip == 1 keeps
// the AC-0216/AC-0284a SLAB-SKIP fill (solid 0..H slabs + palettize):
// nothing enqueues it in-game after AC-0284b — it survives as the
// A/B REFERENCE for the farab gate (h_avg_emit must be byte-identical to
// low_emit_avg on the same column's skip-filled slabs). Cumulative
// counters: g_t_cols_far / g_t_far_us (the far columns' end-to-end cost;
// gen_timing).
//
// Shares the libchunkio library (one .so/.dll, entry chunkio_library_init
// registers ChunkIOPalette + AweGen — see chunk_io.cpp).

#include <gdextension_interface.h>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <functional> // AC-0292: build_field_eval_c's per-point expression
#include <vector>

#include "awe_common.h"

using namespace godot;

namespace awegen {

// ---------------------------------------------------------------------------
// AweNoise — EXACT port of godot/core/noise.gd (same op order, f64/i64).
// ---------------------------------------------------------------------------

static inline double hash2i(int64_t x, int64_t z, int64_t s) {
	// (s ^ (x * 374761393) ^ (z * 668265263)) & 0xFFFFFFFF  [i64 ops]
	int64_t h = (s ^ (x * 374761393LL)) ^ (z * 668265263LL);
	uint32_t u = (uint32_t)(h & 0xFFFFFFFFLL);
	u = (u ^ (u >> 13)) * 1274126177u;
	u ^= u >> 16;
	return (double)u / 4294967296.0;
}

static inline double hash3i(int64_t x, int64_t y, int64_t z, int64_t s) {
	// (s ^ (x * 374761393) ^ (y * 2246822519) ^ (z * 668265263)) & 0xFFFFFFFF
	int64_t h = ((s ^ (x * 374761393LL)) ^ (y * 2246822519LL)) ^ (z * 668265263LL);
	uint32_t u = (uint32_t)(h & 0xFFFFFFFFLL);
	u = (u ^ (u >> 13)) * 1274126177u;
	u ^= u >> 16;
	return (double)u / 4294967296.0;
}

static inline double fade(double t) {
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

static inline double lerp_gd(double a, double b, double t) {
	// Godot lerpf: from + (to - from) * weight
	return a + (b - a) * t;
}

static inline double vnoise2(double x, double z, int64_t s) {
	double xf = std::floor(x);
	double zf = std::floor(z);
	int64_t xi = (int64_t)xf;
	int64_t zi = (int64_t)zf;
	double u = fade(x - xf);
	double v = fade(z - zf);
	double aa = hash2i(xi, zi, s);
	double ab = hash2i(xi + 1, zi, s);
	double ba = hash2i(xi, zi + 1, s);
	double bb = hash2i(xi + 1, zi + 1, s);
	return lerp_gd(lerp_gd(aa, ab, u), lerp_gd(ba, bb, u), v);
}

static inline double vnoise3(double x, double y, double z, int64_t s) {
	double xf = std::floor(x);
	double yf = std::floor(y);
	double zf = std::floor(z);
	int64_t xi = (int64_t)xf;
	int64_t yi = (int64_t)yf;
	int64_t zi = (int64_t)zf;
	double u = fade(x - xf);
	double v = fade(y - yf);
	double w = fade(z - zf);
	double x00 = lerp_gd(hash3i(xi, yi, zi, s), hash3i(xi + 1, yi, zi, s), u);
	double x10 = lerp_gd(hash3i(xi, yi + 1, zi, s), hash3i(xi + 1, yi + 1, zi, s), u);
	double x01 = lerp_gd(hash3i(xi, yi, zi + 1, s), hash3i(xi + 1, yi, zi + 1, s), u);
	double x11 = lerp_gd(hash3i(xi, yi + 1, zi + 1, s), hash3i(xi + 1, yi + 1, zi + 1, s), u);
	return lerp_gd(lerp_gd(x00, x10, v), lerp_gd(x01, x11, v), w);
}

static inline double fbm2(double x, double z, int64_t s, int oct) {
	double a = 0.0;
	double amp = 1.0;
	double f = 1.0;
	double tot = 0.0;
	for (int i = 0; i < oct; i++) {
		a += vnoise2(x * f, z * f, s + (int64_t)i * 101) * amp;
		tot += amp;
		amp *= 0.5;
		f *= 2.0;
	}
	return a / tot;
}

static inline double fbm3(double x, double y, double z, int64_t s, int oct) {
	double a = 0.0;
	double amp = 1.0;
	double f = 1.0;
	double tot = 0.0;
	for (int i = 0; i < oct; i++) {
		a += vnoise3(x * f, y * f, z * f, s + (int64_t)i * 101) * amp;
		tot += amp;
		amp *= 0.5;
		f *= 2.0;
	}
	return a / tot;
}

// AC-0347 P1: the vanilla NormalNoise octave machine — BIT-EXACT mirror of
// AweNoise.vn3 (godot/core/noise.gd, same op order, f64). A custom
// amplitude list + a firstOctave FREQUENCY OFFSET, normalized by
// sum(|a_i|): f = 2^firstOct is an EXACT power of two (ldexp — no
// rounding; no pow), doubled per octave; per-octave seed s + i*101 (the
// fbm3 convention); zero-amplitude octaves are skipped (their
// contribution is exactly +0.0 either way). genprobe lockstep.
static inline double vn3(double x, double y, double z, int64_t s, int first_oct,
		const double *amps, int n) {
	double f = std::ldexp(1.0, first_oct);
	double a = 0.0;
	double tot = 0.0;
	for (int i = 0; i < n; i++) {
		double amp = amps[i];
		if (amp != 0.0) {
			a += amp * vnoise3(x * f, y * f, z * f, s + (int64_t)i * 101);
		}
		tot += amp < 0.0 ? -amp : amp;
		f *= 2.0;
	}
	return a / tot;
}

// ---------------------------------------------------------------------------
// Terrain constants (godot/world/generator.gd).
// ---------------------------------------------------------------------------

constexpr int B_GRASS = 1;
constexpr int B_DIRT = 2;
constexpr int B_STONE = 3;
constexpr int B_SAND = 4;
constexpr int B_WATER = 5;
constexpr int B_LOG = 6;
constexpr int B_LEAVES = 7;
constexpr int B_BEDROCK = 11;
constexpr int B_SNOW_GRASS = 12;
constexpr int B_COAL_ORE = 14;
constexpr int B_IRON_ORE = 15;
constexpr int B_DIAMOND_ORE = 16;
constexpr int B_ROSE = 18;
constexpr int B_DANDELION = 19;
constexpr int B_LAVA = 24;
constexpr int B_OBSIDIAN = 25;
// AC-0292: the cave-feature block family (the free slots above 25):
// deepslate (the vanilla y<0 stone), pointed dripstone (the speleothem),
// clay (the cave pools), sculk (the deep dark), moss (the lush caves).
constexpr int B_DEEPSLATE = 32;
constexpr int B_DRIPSTONE = 33;
constexpr int B_CLAY = 34;
constexpr int B_SCULK = 35;
constexpr int B_MOSS = 36;

constexpr int TERRAIN_H_MAX = 300;

// AC-0292: the surface-rule stage (the vanilla 1.21.4 surface_rule, +64
// y-shift: vanilla y_v = y − 64). Bedrock = vertical_gradient
// above_bottom 0..5 (true at the bottom row, false above 5, a per-column
// random patch between — simplified to the FULL band y 0..4 so the fill /
// skip / far-emit / ring paths stay in lockstep with no signature changes;
// the bottom rows sit below the farab/halo windows anyway). Deepslate =
// vertical_gradient random_name, true below absolute 0 / false above 8
// (vanilla y<0 -> deepslate; the 0..8 random gradient = our 64..71 blend).
constexpr int DEEPSLATE_Y = 64;        // vanilla y < 0 -> deepslate
constexpr int DEEPSLATE_BLEND_TOP = 72; // the vanilla 0..8 blend (our 64..71)
constexpr int BEDROCK_BAND = 5;        // vanilla above_bottom 5 (our y 0..4)
// AC-0292: the cave biome bands (the documented vanilla ranges, +64 shift —
// the 1.19+ biome selector is code-internal, so the single 3-D biome field +
// the fixed value mapping is the documented adaptation; the y-bands are the
// vanilla eligibility gates): deep dark -63..-1, dripstone -16..64, lush 0..64.
constexpr int DD_Y_LO = 1, DD_Y_HI = 63;
constexpr int DRIP_Y_LO = 48, DRIP_Y_HI = 128;
constexpr int LUSH_Y_LO = 64, LUSH_Y_HI = 128;
// AC-0292: the vanilla caves/pillars range_choice threshold
// (max_exclusive 0.03 — the deep branch only, the file header).
constexpr double PILLAR_CHOICE_TH = 0.03;
// AC-0292: the cave biome field — one vn3 (see the section below for the
// model); the value -> biome mapping (one biome per position).
constexpr double BIOME_DD_V = 0.40;
constexpr double BIOME_DRIP_V = 0.60;
constexpr int BIOME_FIRST_OCT = -7;
static const double BIOME_AMPS[] = { 1.0, 1.0 };
constexpr double BIOME_XZ_SCALE = 0.5;
constexpr double BIOME_Y_SCALE = 0.5;
// AC-0292: the ore vein field — ONE vn3 (32+16-block isotropic period),
// the nested per-ore thresholds in the stone_ore chain (the coal blob
// contains the iron which contains the diamond — the layered deposit).
constexpr int VEIN_FIRST_OCT = -5;
static const double VEIN_AMPS[] = { 1.0, 0.5 };
constexpr double VEIN_XZ_SCALE = 1.0;
constexpr double VEIN_Y_SCALE = 1.0;
constexpr double VEIN_D_TH = 0.80; // diamond (the nested tip) — census-tuned
constexpr double VEIN_I_TH = 0.78; // iron
constexpr double VEIN_C_TH = 0.76; // coal (the widest)

// AC-0347 P2: the vanilla density router (see the file header — the
// SHALLOW/DEEP split switched by k = H - y; the AC-0215 one-field +
// AC-0288 A(y) depth-amplifier structure is GONE: CAVE_AMP / DEEP_GROW /
// cave_amp() deleted, the "air for sure" margin re-derived structurally).
constexpr double R_BAND = 10.0;    // spline surface half-width in y blocks
// (the ramp saturates at H+/-10.5). KEPT — the shallow branch's surface.
constexpr double K_CUT = 16.0;     // the router's switch depth (k = H - y) —
// AC-0347 P3 RECALIBRATION (was 10 at P2), picked inside the ticket's
// 10-25 band AGAINST THE MEASURES (5x5 window, seed 44, 6400 cols, the
// cavestat arm): at K_CUT 10 the near-surface band read 34% air at
// k 10-16 — 29% of that air was CHEESE-CAVE (the deep structure starting
// right at the cut) and the first-cave-below-intact-surface depth had a
// mode at the cut (9.1% of intact columns at k 10-15, ~29% of it cheese)
// — "one void from just under the grass" on the cheese side. The surface
// openings themselves are the knob-immune families (tunnel piercings —
// AC-0289's topology — 72% of the opened columns; the entrance family
// opens 0 columns, rarer than the tunnels), so the switch is the only P3
// lever with a measured effect: 16 moves the deep structure's start (and
// the suppressor's 0.5-bias band, k 10-15.6 -> 16-25) six blocks deeper.
// The ramp saturates at +1 for k >= 9.5, so the shallow band stays
// degenerate (solid + entrance slits) across its full width, and the
// continuity proof is unchanged (below). The suppressor is at its 0.5
// clamp maximum exactly at the cut (1.5 - 0.64*1 = 0.86 -> 0.5, vanilla's
// value at ITS cut 1.5 - 0.64*1.5625 = 0.5); k_norm = k/K_CUT, the
// suppressor reaches 0 at k = 2.34375*K_CUT = 37.5 (vanilla's 1.5/0.64 =
// 2.34375 "gone by" value). Continuity at the cut is provable: with
// S_ramp = +1 at k = 16 both branches read d < 0 iff entrances < 0 (the
// deep branch may add solid->air via the cheese tail — never air->solid:
// d_shallow < 0 implies ent < 0 implies d_deep = min(ent, ...) < 0) — no
// solid/air seam.
constexpr double ENTR_OFFSET = 0.37; // vanilla caves/entrances offset —
// makes entrances RARE (surface breaks only in the noise's lower tail).
constexpr double ENTR_GRAD_LO = 0.3; // the entrance y-gradient from_value.
constexpr double ENTR_GRAD_FROM_Y = 54.0; // vanilla from_y -10 + the +64
// world shift (vanilla min_y -64 -> our 0; same 384 height).
constexpr double ENTR_GRAD_TO_Y = 94.0;   // vanilla to_y 30 + 64.
constexpr double LAYER_XZ_SCALE = 1.0;    // vanilla cave_layer scales AS-IS
constexpr double LAYER_Y_SCALE = 8.0;     // (~32-block vertical period —
// AC-0359: on the C48 CAVE lattice the 32-block period rides 4
// samples/period (vanilla's own convention); pre-AC-0359 it was DENSE in
// the scan, a 32-block period cannot ride the 48-block SURFACE lattice —
// the AC-0344 cell-size decision).
constexpr int LAYER_FIRST_OCT = -8;
static const double LAYER_AMPS[] = { 1.0 };
constexpr int LAYER_AMPS_N = 1;
constexpr double ENTR_XZ_SCALE = 0.75;    // vanilla cave_entrance AS-IS
constexpr double ENTR_Y_SCALE = 0.5;      // (~43 xz / ~64 y)
constexpr int ENTR_FIRST_OCT = -7;
static const double ENTR_AMPS[] = { 0.4, 0.5, 1.0 };
constexpr int ENTR_AMPS_N = 3;
// AC-0347 P1 (cave-density rebudget — P1 ONLY, the structure change is
// P2): the CHEESE field is vanilla's cave_cheese AS-IS — the NormalNoise
// octave machine (vn3 above / AweNoise.vn3) with firstOctave -8 and the
// amplitude list [0.5,1,2,1,2,1,0,2,0] (two zero octaves — their
// contribution is exactly +0.0 and the samples are skipped), at
// xz_scale 1.0 / y_scale 0.6667. Scale convention: the scale MULTIPLIES
// the block coordinate (the wiki's "scales the X and Z before sampling";
// a y_scale of 0.0 in other vanilla entries is undefined under division,
// and this 0.6667 reads as the dominant octave's ~96-block vertical
// period — the amp-2 octave at 2^-6 = 1/64 xz, × 0.6667 → 1/96 y; the
// dominant wavelengths are ~64 blocks xz / ~96 y). The old AC-0288 field
// (primary fbm3 3-oct xz/14 seed+301 + detail fbm3 2-oct xz/8 seed+302
// blended at CAVE_W2 0.30) is GONE — this field replaces it (the seed+301
// slot is kept). The dense source is AweGen::density_cave (genprobe
// lockstep).
constexpr int CHEESE_FIRST_OCT = -8;
constexpr double CHEESE_XZ_SCALE = 1.0;
constexpr double CHEESE_Y_SCALE = 0.6667;
static const double CHEESE_AMPS[] = { 0.5, 1.0, 2.0, 1.0, 2.0, 1.0, 0.0, 2.0, 0.0 };
constexpr int CHEESE_AMPS_N = 9;
// AC-0289 (cave P1): the spaghetti/noodle tunnel fields — EDGE densities
// (see the file header). The xz scales are the primary cave field's 14
// times the family's relative scale (spaghetti 1.0x, noodle 0.75x).
constexpr double SPAG_XZ = 14.0;  // the spaghetti xz scale (1.0x primary)
constexpr double NOOD_XZ = 10.5;  // the noodle xz scale (0.75x primary)
constexpr double GATE_XZ = 56.0;  // the rarity selector's patch scale
constexpr double SPAG_TH = 0.16;  // the spaghetti half-thickness (|S-0.5|)
constexpr double NOOD_TH = 0.08;  // the noodle half-thickness (1-5 wide)
constexpr double GATE_LO = 0.52;  // the rarity gate window (the fbm3 mean
constexpr double GATE_HI = 0.58;  // is 0.5 — tunnels patchy, not world-wide)
constexpr double SURF_YSCALE = 64.0; // 3D surface-field y-scale (slow).
constexpr int GY_CELLS = 8;        // 4x8x4 cells -> 8 y-cells of h/8.

// SOLID_IDS (generator.gd) — tree ground check.
static bool solid_ids[256] = {
	false,  // 0
	true, true, true, true, false, true, false,  // 1..7
	true, true, false, true, true, true, true,   // 8..14
	true, true, true, false, true, true, false,  // 15..21 (15 iron,16 diamond,17,20,21)
	false, true, false, true, false, true, false,  // 22..27 (23,25)
};

static inline int clampi(int v, int lo, int hi) {
	if (v < lo)
		return lo;
	if (v > hi)
		return hi;
	return v;
}

static inline int iabs(int v) {
	return v < 0 ? -v : v;
}

// ---------------------------------------------------------------------------
// Coarse 3D fields: grid 7x9x7 (4x8x4 cells + 1-cell margin per axis for the
// 2-ring tree neighborhood). Index ((ix + 1) * 9 + iy) * 7 + (iz + 1);
// world coords x = bx + ix*4, y = iy * ystep, z = bz + iz*4 (ystep = h/8).
// ---------------------------------------------------------------------------

constexpr int GXN = 7;
constexpr int GYN = 9;
constexpr int GZN = 7;
constexpr int GFN = GXN * GYN * GZN; // 441

using Field = std::array<double, GFN>;

static inline size_t grid_idx(int64_t ix, int64_t iy, int64_t iz) {
	return (size_t)((ix + 1) * GYN + iy) * GZN + (iz + 1);
}

// AC-0359 (the AC-0344 C48 decision): a SECOND lattice for the CAVE family
// only — 8-block Y CELLS (Bedrock's resolution) vs the surface/ore lattice's
// 48. The selective raise (AC-0344 verdict: the naive global raise B48 is
// +16.9% per chunk, the selective C48 is -43.2% — the layer/entrance fields
// ride it and stop being evaluated densely per block in the scan):
// GY_CELLS_CAVE = 48 -> ystep_cave = hmax/48 = 8 blocks, GYN_C = 49 lattice
// rows (y = 0..384), FieldC = 7x49x7 = 2401 doubles. The SAME xz cells (4
// blocks, 1-cell margin) — only Y is refined. The CAVE family on it:
// cheese (vn3, seed+301) + the 3 tunnel fields (fbm3, seeds +303/304/305) +
// layer (vn3, seed+302 — the 32-block period rides 4 samples/period,
// vanilla's own convention) + entrance (vn3, seed+306) — ALL BUILT ONLY ON
// THE FULL PATH (skip/far never read them). UNTOUCHED (they keep GY_CELLS =
// 8): the surface + ore fields (f_sc/f_sh/f_sr, f_ore1-3), gen_far,
// gen_veg_cells, column_heights16 — that is what makes H / the far payload /
// the skip payload bit-exact by construction (the thash gate proves it).
constexpr int GY_CELLS_CAVE = 48; // 4x48x4 cells -> 48 y-cells of h/48 = 8 blocks
constexpr int GYN_C = GY_CELLS_CAVE + 1;
constexpr int GFN_C = GXN * GYN_C * GZN; // 2401
using FieldC = std::array<double, GFN_C>;

static inline size_t grid_idx_c(int64_t ix, int64_t iy, int64_t iz) {
	return (size_t)((ix + 1) * GYN_C + iy) * GZN + (iz + 1);
}

// oct: the fbm octave count per lattice point (default 2 — every pre-AC-0288
// field; AC-0288's primary cave octave passes 3).
static void build_field(Field &f, int bx, int bz, double ystep, int64_t seed,
		double fx, double fy, double fz, double ox, double oy, double oz,
		int oct = 2) {
	for (int64_t ix = -1; ix <= 5; ix++) {
		// AC-0359: the y bound was the hardcoded 8 — it HAD to be raised
		// together with GY_CELLS in AC-0344's B-variants (latent bug). The
		// constant form is the same value for the coarse lattice.
		for (int64_t iy = 0; iy <= GYN - 1; iy++) {
			for (int64_t iz = -1; iz <= 5; iz++) {
				f[grid_idx(ix, iy, iz)] = fbm3(
						((double)(bx + ix * 4)) / fx + ox,
						((double)(iy * (int)(ystep))) / fy + oy,
						((double)(bz + iz * 4)) / fz + oz,
						seed, oct);
			}
		}
	}
}

// AC-0347 P1: the vanilla-style field builder — the lattice points are
// SAMPLED at (world coord * scale): the vanilla convention is that the
// scale MULTIPLIES the block coordinate (the wiki's "scales the X and Z
// before sampling"). No coordinate offsets (the vanilla cave entries have
// none). The old build_field (divide-by-scale) is kept for the other
// fields. y is the lattice row's block index, exactly as build_field.
static void build_field_vn(Field &f, int bx, int bz, double ystep, int64_t seed,
		double sx, double sy, double sz, int first_oct,
		const double *amps, int n) {
	for (int64_t ix = -1; ix <= 5; ix++) {
		// AC-0359: `iy <= GYN - 1` (was the hardcoded 8 — see build_field).
		for (int64_t iy = 0; iy <= GYN - 1; iy++) {
			for (int64_t iz = -1; iz <= 5; iz++) {
				f[grid_idx(ix, iy, iz)] = vn3(
						(double)(bx + ix * 4) * sx,
						(double)(iy * (int)(ystep)) * sy,
						(double)(bz + iz * 4) * sz,
						seed, first_oct, amps, n);
			}
		}
	}
}

// AC-0359: the C48 cave-lattice builders — build_field / build_field_vn with
// the 2401-pt FieldC and grid_idx_c (same world coords, 8-block y rows).
static void build_field_c(FieldC &f, int bx, int bz, double ystep, int64_t seed,
		double fx, double fy, double fz, double ox, double oy, double oz,
		int oct = 2) {
	for (int64_t ix = -1; ix <= 5; ix++) {
		for (int64_t iy = 0; iy <= GYN_C - 1; iy++) {
			for (int64_t iz = -1; iz <= 5; iz++) {
				f[grid_idx_c(ix, iy, iz)] = fbm3(
						((double)(bx + ix * 4)) / fx + ox,
						((double)(iy * (int)(ystep))) / fy + oy,
						((double)(bz + iz * 4)) / fz + oz,
						seed, oct);
			}
		}
	}
}

static void build_field_vn_c(FieldC &f, int bx, int bz, double ystep, int64_t seed,
		double sx, double sy, double sz, int first_oct,
		const double *amps, int n) {
	for (int64_t ix = -1; ix <= 5; ix++) {
		for (int64_t iy = 0; iy <= GYN_C - 1; iy++) {
			for (int64_t iz = -1; iz <= 5; iz++) {
				f[grid_idx_c(ix, iy, iz)] = vn3(
						(double)(bx + ix * 4) * sx,
						(double)(iy * (int)(ystep)) * sy,
						(double)(bz + iz * 4) * sz,
						seed, first_oct, amps, n);
			}
		}
	}
}

// AC-0292: the C48 evaluator builder — the lattice points are filled by a
// caller-supplied expression (world x, lattice-row block y, world z). The
// pillar field uses it: the field stores the FULL vanilla caves/pillars
// value (3 vn3 per lattice point at build time) so the scan pays one
// tril_c instead of three dense vn3 per deep point (the AC-0359 lesson —
// the dense evaluation stays out of the scan).
static void build_field_eval_c(FieldC &f, int bx, int bz, double ystep,
		const std::function<double(double, double, double)> &fn) {
	for (int64_t ix = -1; ix <= 5; ix++) {
		for (int64_t iy = 0; iy <= GYN_C - 1; iy++) {
			for (int64_t iz = -1; iz <= 5; iz++) {
				f[grid_idx_c(ix, iy, iz)] =
						fn((double)(bx + ix * 4), (double)(iy * (int)(ystep)),
								(double)(bz + iz * 4));
			}
		}
	}
}

// Trilinear sample. gx = (x - bx)/4 in [-1, 5), gy = y/ystep in [0, 8),
// gz = (z - bz)/4 in [-1, 5) — the caller stays inside the grid, so no
// clamping is needed (tree margin covers gx/gz >= -0.5, <= 4.25).
static inline double tril(const Field &f, double gx, double gy, double gz) {
	double fx = std::floor(gx);
	double fy = std::floor(gy);
	double fz = std::floor(gz);
	int64_t ix = (int64_t)fx;
	int64_t iy = (int64_t)fy;
	int64_t iz = (int64_t)fz;
	double u = gx - fx;
	double v = gy - fy;
	double w = gz - fz;
	double x00 = lerp_gd(f[grid_idx(ix, iy, iz)], f[grid_idx(ix + 1, iy, iz)], u);
	double x10 = lerp_gd(f[grid_idx(ix, iy + 1, iz)], f[grid_idx(ix + 1, iy + 1, iz)], u);
	double x01 = lerp_gd(f[grid_idx(ix, iy, iz + 1)], f[grid_idx(ix + 1, iy, iz + 1)], u);
	double x11 = lerp_gd(f[grid_idx(ix, iy + 1, iz + 1)], f[grid_idx(ix + 1, iy + 1, iz + 1)], u);
	return lerp_gd(lerp_gd(x00, x10, v), lerp_gd(x01, x11, v), w);
}

// AC-0359: the C48 cave-lattice trilinear sample — tril on the 2401-pt
// FieldC. gx/gz have the same meaning (the tree margin covers gx/gz >= -0.5,
// <= 4.25 exactly as the coarse lattice); gy = y/ystep_cave in [0, 48).
// The second-order fidelity residual is recorded, not hidden: trilinear
// between the 8-block samples undershoots the dense-quintic PEAK amplitude
// (~cos(pi/4) = 0.707 for the layer's 4-samples/period 32-block sinusoid —
// the level caps read marginally weaker than a dense evaluation), and the
// entrance's finest y feature sits at the sampling border (see AC-0359's
// results page for the measurement).
static inline double tril_c(const FieldC &f, double gx, double gy, double gz) {
	double fx = std::floor(gx);
	double fy = std::floor(gy);
	double fz = std::floor(gz);
	int64_t ix = (int64_t)fx;
	int64_t iy = (int64_t)fy;
	int64_t iz = (int64_t)fz;
	double u = gx - fx;
	double v = gy - fy;
	double w = gz - fz;
	double x00 = lerp_gd(f[grid_idx_c(ix, iy, iz)], f[grid_idx_c(ix + 1, iy, iz)], u);
	double x10 = lerp_gd(f[grid_idx_c(ix, iy + 1, iz)], f[grid_idx_c(ix + 1, iy + 1, iz)], u);
	double x01 = lerp_gd(f[grid_idx_c(ix, iy, iz + 1)], f[grid_idx_c(ix + 1, iy, iz + 1)], u);
	double x11 = lerp_gd(f[grid_idx_c(ix, iy + 1, iz + 1)], f[grid_idx_c(ix + 1, iy + 1, iz + 1)], u);
	return lerp_gd(lerp_gd(x00, x10, v), lerp_gd(x01, x11, v), w);
}

// AC-0215: the surface height H(x,z) from the coarse 3D SURFACE field —
// the AC-0091 2D heightmap (c/h/r fbm2, same remap) is REPLACED by the 3D
// fields on the same 4x8x4 grid, read at the SEA-LEVEL SLICE y = 126. The
// slice's statistics differ from the old 2D fbm's, so the remap is
// affine-calibrated per field onto the OLD 2D distribution (measured over a
// 640x640 block area, seed 44 — the calibration constants below):
//   c: old mean 0.4219 std 0.1280  <-  new slice: mean 0.3681 std 0.0467
//   h: old mean 0.4964 std 0.1361  <-  new slice: mean 0.5112 std 0.1107
//   r: old mean 0.4292 std 0.1366  <-  new slice: mean 0.5743 std 0.1443
// so the H distribution (the ocean/land/mountain balance, sea 126) matches
// the AC-0091 heightmap. AC-0314: the spawn pad (d<=6 -> SPAWN_H=136 flat,
// 6<d<=10 smoothstep blend) is REMOVED — the surface is natural everywhere;
// the spawn position comes from the AC-0324 deterministic search on the
// natural terrain.
static inline int surface_h(int x, int z, const Field &f_sc, const Field &f_sh,
		const Field &f_sr, double ystep, int bx, int bz) {
	double gx = (double)(x - bx) / 4.0;
	double gz = (double)(z - bz) / 4.0;
	double gy = 126.0 / ystep; // the sea-level slice row
	double c = tril(f_sc, gx, gy, gz);
	double h = tril(f_sh, gx, gy, gz);
	double r = tril(f_sr, gx, gy, gz);
	// Calibrated fields (mapped onto the old 2D distribution).
	double cc = 0.4219 + (c - 0.3681) * (0.1280 / 0.0467);
	double hc = 0.4964 + (h - 0.5112) * (0.1361 / 0.1107);
	double rc = 0.4292 + (r - 0.5743) * (0.1366 / 0.1443);
	double y = 105.2 + cc * 36.4 + hc * 52.0;
	if (rc > 0.62)
		y += (rc - 0.62) * 390.0;
	return clampi((int)std::floor(y), 3, TERRAIN_H_MAX);
}

// AC-0215 "spline surface density": quintic ramp in [-1, 1], C2 at the
// clamps (quintic = the same polynomial as AweNoise._fade). +1 (solid)
// below the surface, -1 (air) above; the zero crossing IS the surface. The
// +0.5 keeps an unshifted column (cave term 0) solid exactly for y <= H.
static inline double density_ramp(double H, int y) {
	double t = (H + 0.5 - (double)y) / R_BAND;
	if (t > 1.0)
		t = 1.0;
	else if (t < -1.0)
		t = -1.0;
	double u = 0.5 * (t + 1.0);
	double q = u * u * u * (u * (u * 6.0 - 15.0) + 10.0);
	return 2.0 * q - 1.0;
}

// AC-0347 P2: the dense CAVE LAYER source — vanilla's cave_layer noise
// instance AS-IS ({firstOctave -8, amplitudes [1.0]} at xz 1.0 / y 8.0 —
// the ~32-block vertical period), seed+302 (the slot P1 freed when the
// old two-octave cheese blend went away). AC-0359: the scan reads the
// LATTICE value (f_layer on the C48 cave lattice — the 32-block period
// rides 4 samples/period); this dense source stays bound as the genprobe
// lockstep reference (AweGen::density_layer) and nothing else calls it.
static inline double layer_cave(double x, double y, double z, int64_t s) {
	return vn3(x * LAYER_XZ_SCALE, y * LAYER_Y_SCALE, z * LAYER_XZ_SCALE,
			s + 302, LAYER_FIRST_OCT, LAYER_AMPS, LAYER_AMPS_N);
}

// AC-0347 P2: the dense ENTRANCE FAMILY source — the vanilla
// caves/entrances function WITHOUT its spaghetti_3d min (ours: the AC-0289
// tunnel rule, which stays OUTSIDE dens_at):
//   0.37 + 2*(E - 0.5) + 0.3*(1 - clamp01((y - 54)/40))
// with E = vn3 at the vanilla cave_entrance instance AS-IS ({firstOctave
// -7, amplitudes [0.4, 0.5, 1.0]} at xz 0.75 / y 0.5), seed+306. The 2*(v-0.5)
// is the centering onto the vanilla convention (noise centred on 0, O(1) —
// the unit in which the constants are meaningful); the +0.37 offset is
// vanilla's (entrances RARE — the surface breaks only in the noise's lower
// tail); the gradient is vanilla's from_y -10 / to_y 30 / 0.3 -> 0.0
// shifted by +64 (the world's min_y). AC-0359: the scan reads the LATTICE
// value (f_entr on the C48 cave lattice via entrance_from_latt); this dense
// source stays bound as the genprobe lockstep reference
// (AweGen::density_entrance) and nothing else calls it.
static inline double entrance_cave(double x, double y, double z, int64_t s) {
	double e = vn3(x * ENTR_XZ_SCALE, y * ENTR_Y_SCALE, z * ENTR_XZ_SCALE,
			s + 306, ENTR_FIRST_OCT, ENTR_AMPS, ENTR_AMPS_N);
	double t = (y - ENTR_GRAD_FROM_Y) / (ENTR_GRAD_TO_Y - ENTR_GRAD_FROM_Y);
	if (t < 0.0)
		t = 0.0;
	else if (t > 1.0)
		t = 1.0;
	return 2.0 * (e - 0.5) + ENTR_OFFSET + ENTR_GRAD_LO * (1.0 - t);
}

// AC-0359: the entrance family OFF the cave lattice — e is the f_entr
// lattice value (tril_c of the seed+306 vn3 field) and the analytic y
// GRADIENT stays per-y, exactly as the dense source has it (a linear
// function is exact under trilinear, so no residual there):
//   2*(e - 0.5) + 0.37 + 0.3*(1 - clamp01((y - 54)/40)).
// entrance_cave (the dense vn3 source) stays bound for the genprobe
// lockstep; the scan no longer calls it.
static inline double entrance_from_latt(double e, double y) {
	double t = (y - ENTR_GRAD_FROM_Y) / (ENTR_GRAD_TO_Y - ENTR_GRAD_FROM_Y);
	if (t < 0.0)
		t = 0.0;
	else if (t > 1.0)
		t = 1.0;
	return 2.0 * (e - 0.5) + ENTR_OFFSET + ENTR_GRAD_LO * (1.0 - t);
}

// AC-0289: the rarity gate weight — 0 outside the tunnel patches, 1 at
// their core, linear in between (the patch edge). The production path
// reads the coarse f_gate trilinearly; AweGen::tunnel_air is the dense
// source of the same predicate (the genprobe lockstep).
static inline double gate_weight(double g) {
	double w = (g - GATE_LO) / (GATE_HI - GATE_LO);
	if (w < 0.0)
		return 0.0;
	if (w > 1.0)
		return 1.0;
	return w;
}

// AC-0289: the TUNNEL air predicate — true where an edge density wins
// over the cheese (a tunnel carves air even where dens_at says solid).
// Called at every scan point of the full-path scan (before the solid
// flag) and identically in the veg margin scan; the skip/far paths never
// call it (no tunnel fields are built there — the H contract).
static inline bool tunnel_air(const Field &f_spag, const Field &f_nood, const Field &f_gate,
		double gx, double gy, double gz) {
	double w = gate_weight(tril(f_gate, gx, gy, gz));
	if (w <= 0.0)
		return false;
	double sp = tril(f_spag, gx, gy, gz) - 0.5;
	if (sp < 0.0)
		sp = -sp;
	if (sp < SPAG_TH * w)
		return true;
	double nd = tril(f_nood, gx, gy, gz) - 0.5;
	if (nd < 0.0)
		nd = -nd;
	return nd < NOOD_TH * w;
}

// AC-0359: the C48 tunnel predicate — tunnel_air on the cave lattice
// (tril_c). The AC-0344 B-variant data showed the tunnels already read
// correctly from the raised lattice; the scan now uses this everywhere the
// coarse lattice used to.
static inline bool tunnel_air_c(const FieldC &f_spag, const FieldC &f_nood, const FieldC &f_gate,
		double gx, double gy, double gz) {
	double w = gate_weight(tril_c(f_gate, gx, gy, gz));
	if (w <= 0.0)
		return false;
	double sp = tril_c(f_spag, gx, gy, gz) - 0.5;
	if (sp < 0.0)
		sp = -sp;
	if (sp < SPAG_TH * w)
		return true;
	double nd = tril_c(f_nood, gx, gy, gz) - 0.5;
	if (nd < 0.0)
		nd = -nd;
	return nd < NOOD_TH * w;
}

// AC-0347 P2: THE VANILLA DENSITY ROUTER — the ONE density field at a
// cell (solid where > 0, air where < 0), the SHALLOW/DEEP split of the
// file header (Java 1.21.4 overworld.json final_density's range_choice,
// verified against the shipped JSON; density > 0 = solid is the vanilla
// AND our convention — no sign flip). Inputs: H (the heightmap — the
// far/payload/promotion contract, untouched), y, cave (the cheese field's
// trilinear value — the C48 cave lattice since AC-0359), ent (the entrance
// family value — entrance_from_latt on the cave lattice since AC-0359,
// dense entrance_cave before), layer (the cave layer's RAW vn3 value —
// the C48 lattice value since AC-0359; the centering happens here; pass
// 0.0 in the shallow band, it is not read).
// TUNNELS: the AC-0289 tunnel_air rule is applied OUTSIDE this function
// (the scan's "&& !tunnel_air") — the vanilla spaghetti min, kept where
// AC-0289 put it so the tunnels pierce the caps and connect the levels.
// PILLARS: the outer max(..., pillars_choice) is AC-0292 (SEQUENCE).
static inline double dens_at(int H, int y, double cave, double ent, double layer) {
	double k = (double)H - (double)y; // depth from the surface
	if (k < K_CUT) {
		// SHALLOW: min(S_ramp, 5 * entrances). The surface (S_ramp) is
		// kept as-is (the KEEP list); the entrance family carves the
		// deliberate surface openings where it dips low.
		double s = density_ramp((double)H, y);
		double e = 5.0 * ent;
		return s < e ? s : e;
	}
	// DEEP: min(entrances, 4*layer_c^2 + clamp(-1,1)(0.27 + cheese_c)
	// + clamp(0,0.5)(1.5 - 0.64*k/K_CUT)). The base terrain contributes
	// NOTHING here (the load-bearing fact) — the solid/air decision IS
	// the cave router. The layer is squared ONE-SIDED (vanilla's square:
	// always positive — it gates the cheese caves into stacked levels).
	double q = 0.27 + 2.0 * (cave - 0.5); // centered cheese, then +0.27
	if (q < -1.0)
		q = -1.0;
	else if (q > 1.0)
		q = 1.0;
	double kn = k / K_CUT;
	double supp = 1.5 - 0.64 * kn; // the shallow suppressor (0.5 at the
	// cut, 0 at k = 2.34375*K_CUT — vanilla's shape, k-normalized)
	if (supp < 0.0)
		supp = 0.0;
	else if (supp > 0.5)
		supp = 0.5;
	double lc = 2.0 * (layer - 0.5); // centered layer (vanilla convention)
	double s = 4.0 * lc * lc + q + supp;
	return ent < s ? ent : s;
}

// ---------------------------------------------------------------------------
// AC-0290: the classic CARVER family (galleries / bubble-interrupted trunks /
// ravine canyons) — the post-density pass (see the file header for the
// families, the vanilla parameters and the cut-through policy).
// ---------------------------------------------------------------------------

// AC-0290: the per-chunk carver PRNG — splitmix64 (the vanilla
// RandomSource.chunk role: a deterministic per-chunk stream). The carvers
// are geometry, not noise: a pure f(seed, cx, cz).
static inline uint64_t splitmix64_next(uint64_t &state) {
	uint64_t z = (state += 0x9E3779B97F4A7C15ull);
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
	z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
	return z ^ (z >> 31);
}

struct CarveRng {
	uint64_t s;
	explicit CarveRng(uint64_t seed) : s(seed) {}
	uint64_t next() { return splitmix64_next(s); }
	double u() { return (double)(next() >> 11) * (1.0 / 9007199254740992.0); } // [0,1)
	int ri(int n) { return (int)(next() % (uint64_t)n); }
	int rangei(int lo, int hi) { return lo + ri(hi - lo + 1); }
};

static uint64_t carve_chunk_seed(int64_t seed, int cx, int cz) {
	uint64_t h = (uint64_t)(uint32_t)(uint64_t)seed;
	h ^= (uint64_t)(uint32_t)(uint64_t)(int64_t)(cx + 1000000) * 0xBF58476D1CE4E5B9ull;
	h = splitmix64_next(h);
	h ^= (uint64_t)(uint32_t)(uint64_t)(int64_t)(cz + 2000000) * 0x94D049BB133111EBull;
	return splitmix64_next(h);
}

// AC-0290: the vanilla carver parameters (see the file header; the +64
// y-shift maps vanilla's -64-based world onto ours).
constexpr int CARVE_Y_MIN = 8; // vanilla -56 (cave.json y min above_bottom 8)
constexpr int CARVE_Y_MAX = 244; // vanilla 180 (cave.json y max absolute 180)
constexpr double CARVE_PROB = 0.15; // cave.json probability (per chunk)
constexpr double CANYON_PROB = 0.01; // canyon.json probability (per chunk)
constexpr int CANYON_Y_MIN = 74; // vanilla 10 (canyon.json y min absolute 10)
constexpr int CANYON_Y_MAX = 131; // vanilla 67 (canyon.json y max absolute 67)

// One carved ellipsoid (world coords). flat = the flat-floor room shape
// (the floor plane is the bottom tangent: the full-ellipse floor, the
// elliptical dome ceiling).
struct CarveEll {
	int x, y, z;
	double rx, ry, rz;
	bool flat;
	int floor; // the flat floor y (flat only)
};

// One carver feature (census/shot reporting). kind: 0 room, 1 trunk, 2 canyon.
struct CarveFeature {
	int kind;
	int x, y, z; // start (room center / trunk start / canyon x,z + start y)
	int len; // trunk/canyon length (0 = room)
	int n_branches;
	int n_bubbles;
};

// AC-0290: the worm walk — the step loop shared by the trunk and the
// branches: per-step thickness flicker (0.6-1.4x) + bubble interruptions
// (~12% of the steps carve a 1.6x bulb), direction wander + vertical drift
// (clamped ±0.5/step), 1.5-block steps.
static void carve_walk(CarveRng &rng, std::vector<CarveEll> &out, int x0, int y0, int z0,
		int len, double rx0, double ry0, double ang0, double dy0,
		int &n_bubbles, bool record_path, std::vector<std::array<double, 4>> *path) {
	double ang = ang0, dy = dy0;
	double x = (double)x0, y = (double)y0, z = (double)z0;
	int bubbles = 0;
	for (int t = 0; t < len; t++) {
		if (record_path)
			path->push_back({x, y, z, ang});
		double flick = 0.6 + 0.8 * rng.u(); // the thickness flicker
		double rx = rx0 * flick;
		double ry = ry0 * flick;
		if (rng.u() < 0.12) { // the bubble interruption (the bulb)
			rx *= 1.6;
			ry *= 1.3;
			bubbles++;
		}
		out.push_back({(int)std::floor(x + 0.5), (int)std::floor(y + 0.5), (int)std::floor(z + 0.5), rx, ry, rx, false, 0});
		ang += (rng.u() - 0.5) * 0.5; // the wander
		dy += (rng.u() - 0.5) * 0.3; // the vertical drift
		if (dy > 0.5)
			dy = 0.5;
		else if (dy < -0.5)
			dy = -0.5;
		x += std::cos(ang) * 1.5;
		z += std::sin(ang) * 1.5;
		y += dy * 1.5;
		if (y < (double)CARVE_Y_MIN)
			y = (double)CARVE_Y_MIN;
		if (y > (double)(CARVE_Y_MAX - 4))
			y = (double)(CARVE_Y_MAX - 4);
	}
	n_bubbles = bubbles;
}

// AC-0290: the trunk (the I/T shape) — 85-112 long (the ticket), per-trunk
// radii, the shared walk, 1-3 branches of 2-7 h / 1-7 v thickness attached
// in the middle half at right-ish angles.
static void carve_trunk(CarveRng &rng, std::vector<CarveEll> &out, int x0, int y0, int z0,
		CarveFeature &f) {
	f.kind = 1;
	f.x = x0;
	f.y = y0;
	f.z = z0;
	f.len = rng.rangei(85, 112); // the ticket: trunk 85-112 long
	double rx0 = 2.0 + (double)rng.ri(7); // h radius 2-8
	double ry0 = 1.0 + rx0 * (0.4 + 0.8 * rng.u()); // v radius ~1-9
	double ang0 = rng.u() * 6.283185307179586;
	double dy0 = (rng.u() - 0.5) * 0.6;
	std::vector<std::array<double, 4>> path;
	path.reserve(f.len);
	int bubbles = 0;
	carve_walk(rng, out, x0, y0, z0, f.len, rx0, ry0, ang0, dy0, bubbles, true, &path);
	int nb = 1 + rng.ri(3); // 1-3 branches
	for (int b = 0; b < nb; b++) {
		int bt = rng.rangei(f.len / 4, (f.len * 3) / 4);
		double bx = path[bt][0], by = path[bt][1], bz = path[bt][2];
		double bang = path[bt][3] + (rng.u() < 0.5 ? 1.0 : -1.0) * (1.5707963 + (rng.u() - 0.5) * 0.6);
		double brx = 1.0 + (double)rng.ri(3); // h radius 1-3 (thickness 2-7)
		double bry = 1.0 + 0.8 * (double)rng.ri(3); // v radius ~1-3 (thickness 1-7)
		double bdy = (rng.u() - 0.5) * 0.4;
		int blen = 15 + rng.ri(30); // 15-44
		carve_walk(rng, out, (int)std::floor(bx + 0.5), (int)std::floor(by + 0.5),
				(int)std::floor(bz + 0.5), blen, brx, bry, bang, bdy, bubbles, false, nullptr);
	}
	f.n_branches = nb;
	f.n_bubbles = bubbles;
}

// AC-0290: the main room (the gallery) — 1-14 tall, Ø 5-15 (the ticket),
// FLAT FLOOR (the floor plane is the ellipsoid's bottom tangent: the
// full-ellipse floor, the elliptical dome ceiling) + the short exit trunk
// (the classic "room + trunk" shape).
static void carve_room(CarveRng &rng, std::vector<CarveEll> &out, int x0, int y0, int z0,
		CarveFeature &f) {
	f.kind = 0;
	f.x = x0;
	f.y = y0;
	f.z = z0;
	f.len = 0;
	int h = rng.rangei(1, 14); // the ticket: main room 1-14 blocks tall
	int dia = rng.rangei(5, 15); // the ticket: Ø 5-15

	double ry = (double)h / 2.0;
	double rx = (double)dia / 2.0;
	out.push_back({x0, y0, z0, rx, ry, rx, true, y0 - (int)std::ceil(ry)});
	// The exit trunk (from the room edge, mostly horizontal).
	int bubbles = 0;
	double ang = rng.u() * 6.283185307179586;
	int sx = x0 + (int)std::floor(std::cos(ang) * rx);
	int sz = z0 + (int)std::floor(std::sin(ang) * rx);
	int sy = y0 - (int)std::floor(ry * 0.5);
	int trlen = 30 + rng.ri(31); // 30-60
	carve_walk(rng, out, sx, sy, sz, trlen, 2.0 + (double)rng.ri(3), 1.0 + (double)rng.ri(2),
			ang, (rng.u() - 0.5) * 0.4, bubbles, false, nullptr);
	f.n_branches = 0;
	f.n_bubbles = bubbles;
}

// AC-0290: the canyon (the tall ravine, canyon.json) — the vertical shaft:
// start y 74..131 (vanilla 10..67), horizontal radius ~1-3 (thickness
// trapezoid(0,6,plateau 2) x factor 0.75-1.0), vertical radius = 3x
// horizontal (yScale 3.0 — the tall ravine), vertical_rotation ±0.125 (the
// meander), length 45-150 x distance_factor 0.75-1.0 — it punches the
// surface: the steep cliff walls.
static void carve_canyon(CarveRng &rng, std::vector<CarveEll> &out, int x0, int z0,
		CarveFeature &f) {
	f.kind = 2;
	f.x = x0;
	f.z = z0;
	f.y = rng.rangei(CANYON_Y_MIN, CANYON_Y_MAX);
	f.len = 0;
	f.n_branches = 0;
	f.n_bubbles = 0;
	double thick = 2.0 + 4.0 * rng.u() * rng.u(); // ~2-6, narrow-biased (the trapezoid)
	double rx = thick / 2.0 * (0.75 + 0.25 * rng.u()); // x factor 0.75-1.0
	double ry = rx * 3.0; // yScale 3.0 — the TALL ravine
	double vr = (rng.u() - 0.5) * 0.25; // vertical_rotation ±0.125
	double df = 0.75 + 0.25 * rng.u(); // distance_factor 0.75-1.0
	f.len = (int)((45.0 + rng.u() * 105.0) * df);
	// The drift is small (the ravine rises NEARLY VERTICAL — vanilla's
	// vertical_rotation is a gentle meander rate, not a worm's 1-block
	// wander): the tube stays close to its start column, which is what
	// punches the surface (a large wander would carry the tube out of the
	// home chunk before it reaches the surface — the carve is per-chunk,
	// so the rest of the tube would be lost to the seam). Small drift +
	// the full ±0.125 rotation rate = a tight meander: the tube's bottom
	// and its surface break sit close together, which is what makes the
	// DEEP gully (a wide arc would only graze the surface — a shallow
	// notch instead of a ravine).
	double drift = 0.05 + 0.1 * rng.u(); // 0.05-0.15 blocks/step
	double ang = rng.u() * 6.283185307179586;
	double x = (double)x0, z = (double)z0, y = (double)f.y;
	for (int t = 0; t < f.len; t++) {
		out.push_back({(int)std::floor(x + 0.5), (int)std::floor(y + 0.5), (int)std::floor(z + 0.5), rx, ry, rx, false, 0});
		ang += vr; // the meander (the rotation as it extends)
		x += std::cos(ang) * drift;
		z += std::sin(ang) * drift;
		y += 1.0; // upward
		if (y > 383.0)
			break;
	}
}

// AC-0290: the per-chunk carver plan (deterministic f(seed, cx, cz)).
// feat may be nullptr (the production path does not need the per-feature
// report).
static void build_carver_plan(int cx, int cz, int64_t seed, std::vector<CarveEll> &ell,
		std::vector<CarveFeature> *feat) {
	CarveRng rng(carve_chunk_seed(seed, cx, cz));
	if (rng.u() < CARVE_PROB) { // cave.json probability (0.15/chunk)
		int x = cx * 16 + rng.ri(16);
		int z = cz * 16 + rng.ri(16);
		int y = rng.rangei(CARVE_Y_MIN, CARVE_Y_MAX);
		CarveFeature f;
		if (rng.ri(4) == 0)
			carve_room(rng, ell, x, y, z, f); // 1-in-4: the main room (the gallery)
		else
			carve_trunk(rng, ell, x, y, z, f); // 3-in-4: the I/T trunk
		if (feat)
			feat->push_back(f);
	}
	if (rng.u() < CANYON_PROB) { // canyon.json probability (0.01/chunk)
		int x = cx * 16 + rng.ri(16);
		int z = cz * 16 + rng.ri(16);
		CarveFeature f;
		carve_canyon(rng, ell, x, z, f);
		if (feat)
			feat->push_back(f);
	}
}

// AC-0290: the cut-through predicate — a carvable solid (everything except
// air / water / lava — the water stays, the AC-0342 flooded model).
static inline bool carve_is_solid(uint8_t id) {
	return id != 0 && id != B_WATER && id != B_LAVA;
}

static inline bool carve_slab_kept(int y, const uint8_t *p_keep, int nsl) {
	int sl = y >> 4;
	return p_keep == nullptr || sl < nsl || p_keep[sl] != 0;
}

// AC-0290: the per-column carver apply (the cut-through + the re-skin).
// ax/az = the LOCAL column (the flat[] index), wx/wz = the WORLD column
// (the ellipsoid centers are world coords). Returns he2 = the topmost SOLID
// after the carve (he = before): the caller updates heff[] so veg plants on
// the carved surface. The re-skin (the new top gets the fill's exact surface
// rule + the 3-deep dirt band) only fires where the carve dropped the top
// (he2 < he) — block-level only; H / the surface fields / SEA are never
// touched (the header's cut-through policy).
static int carver_carve_column(std::vector<uint8_t> &flat, int ax, int az, int wx, int wz,
		int he, int sea, int bm, const std::vector<CarveEll> &ell, int hmax, const uint8_t *p_keep) {
	int nsl = hmax / 16;
	for (const CarveEll &c : ell) {
		double dx = (double)(wx - c.x);
		double dz = (double)(wz - c.z);
		double q = (dx * dx) / (c.rx * c.rx) + (dz * dz) / (c.rz * c.rz);
		if (q >= 1.0)
			continue;
		int ylo, yhi;
		if (c.flat) {
			// The flat-floor room: the full-ellipse floor at c.floor, the
			// dome ceiling (the upper half-ellipsoid).
			ylo = c.floor;
			yhi = (int)std::floor(c.y + c.ry * std::sqrt(1.0 - q));
		} else {
			double ym = c.ry * std::sqrt(1.0 - q);
			ylo = (int)std::floor(c.y - ym);
			yhi = (int)std::ceil(c.y + ym);
		}
		if (ylo < 1)
			ylo = 1; // the bedrock row is never carved
		if (yhi > hmax - 1)
			yhi = hmax - 1;
		for (int y = ylo; y <= yhi; y++) {
			if (!c.flat) {
				double dy = (double)y - c.y;
				if (q + (dy * dy) / (c.ry * c.ry) > 1.0)
					continue;
			}
			if (!carve_slab_kept(y, p_keep, nsl))
				continue;
			size_t k = (size_t)(y << 8) | (az << 4) | ax;
			if (carve_is_solid(flat[k]))
				flat[k] = (y < 8) ? B_LAVA : 0; // the cut-through (the deep-pocket lava rule)
		}
	}
	// The new effective top (topmost solid): above he is air/water only, so
	// walk down from he.
	int he2 = he;
	while (he2 >= 1) {
		uint8_t id = flat[(size_t)(he2 << 8) | (az << 4) | ax];
		if (id != 0 && id != B_WATER && id != B_LAVA)
			break;
		he2--;
	}
	// The re-skin (the fill's exact surface rule at the new top).
	if (he2 < he && he2 >= 1) {
		uint8_t top = B_GRASS;
		if (bm == 1)
			top = B_SAND;
		else if (bm == 0)
			top = B_SNOW_GRASS;
		if (he2 <= sea + 1 && bm != 1)
			top = B_SAND;
		size_t k = (size_t)(he2 << 8) | (az << 4) | ax;
		if (carve_is_solid(flat[k]))
			flat[k] = top;
		for (int y = he2 - 3; y < he2; y++) {
			if (y < 1)
				break;
			if (!carve_slab_kept(y, p_keep, nsl))
				continue;
			size_t kk = (size_t)(y << 8) | (az << 4) | ax;
			if (flat[kk] == B_STONE)
				flat[kk] = (bm == 1) ? B_SAND : B_DIRT;
		}
	}
	return he2;
}

// ---------------------------------------------------------------------------
// AC-0216: cumulative lazy-skip counters (the harness reads them through
// AweGen.skip_*(); the workers increment from any thread — atomics).
// ---------------------------------------------------------------------------

static std::atomic<long long> g_skip_chunks_total{0};
static std::atomic<long long> g_skip_cols_total{0};

// AC-0237 phase 0: the gen cost BREAKDOWN (us, process-wide, all TG
// threads) — fields (the 7 coarse field builds) / heights (the 256
// per-column surface + biome) / scan (the top-down density evaluation —
// the part the window would skip) / fill (the per-cell emit incl. ore) /
// veg (trees + flowers) / pallet (palettize_slabs). Read via
// AweGen.gen_timing().
static std::atomic<long long> g_t_field_us{0};
static std::atomic<long long> g_t_heights_us{0};
static std::atomic<long long> g_t_scan_us{0};
static std::atomic<long long> g_t_fill_us{0};
static std::atomic<long long> g_t_veg_us{0};
static std::atomic<long long> g_t_pallet_us{0};
static std::atomic<long long> g_t_carve_us{0}; // AC-0290: the carver pass
// AC-0291: the aquifer stage (the per-chunk table build), in gen_timing()
// as "aquifer_us", + the placed-cell census (fluid via the aquifer /
// barrier stone / the lava layer / fl=8 scheduled flow). Read via
// AweGen.aquifer_stats().
static std::atomic<long long> g_t_aquifer_us{0};
static std::atomic<long long> g_aqu_water{0};
static std::atomic<long long> g_aqu_lava{0};
static std::atomic<long long> g_aqu_stones{0};
static std::atomic<long long> g_aqu_lava_layer{0};
static std::atomic<long long> g_aqu_fl8{0};
// AC-0292: the P4 census (the TEMP census arms read it; process-wide like
// the aquifer stats — reset_gen_timing() zeros it). Read via AweGen.p4_stats().
static std::atomic<long long> g_p4_pillar{0};      // pillar-solid cells (deep, P >= 0.03)
static std::atomic<long long> g_p4_pillar_void{0}; // ...of which the router+tunnel said AIR (the true void fill)
static std::atomic<long long> g_p4_ore_vein{0};    // vein-blob ore cells (per-ore in the arm)
static std::atomic<long long> g_p4_deepslate{0};   // deepslate cells placed (y<64 + blend)
static std::atomic<long long> g_p4_dripstone{0};   // speleothem cells (the drip pass)
static std::atomic<long long> g_p4_clay{0};        // clay pool cells (the drip pass)
static std::atomic<long long> g_p4_sculk{0};       // deep dark sculk
static std::atomic<long long> g_p4_moss{0};        // lush moss
static std::atomic<long long> g_t_drip_us{0};      // the drip pass stage (gen_timing "drip_us")
static std::atomic<long long> g_t_cols_full{0};
static std::atomic<long long> g_t_cols_skip{0};
// AC-0284b: the far (h-only) column counters — g_t_cols_far = the far
// columns generated (skip == 2), g_t_far_us = their CUMULATIVE end-to-end
// cost (the fields + the heights pass + the payload emit — no fill, no
// veg, no palettize). Read via gen_timing() like the stage counters.
static std::atomic<long long> g_t_cols_far{0};
static std::atomic<long long> g_t_far_us{0};
// AC-0284b: the far tree-cell precompute (veg_cells — the far emitter's
// solid-set extension; the lazy worker-side cost, NOT in g_t_far_us).
static std::atomic<long long> g_t_vegcells_us{0};

static inline long long now_us() {
	return (long long)std::chrono::duration_cast<std::chrono::microseconds>(
			std::chrono::steady_clock::now().time_since_epoch()).count();
}

// ---------------------------------------------------------------------------
// AC-0291 — the VORONOI AQUIFERS (minecraft.wiki/w/Cave §Aquifer — the Java
// 1.18+ algorithm; the +64 y-shift maps vanilla y_v = y − 64 onto our
// 0-based world, so vanilla −54 → 10 and vanilla −10 → 54). Replaces the
// flat "caves below SEA fill to SEA" model with per-cell local water tables:
// every non-solid block takes the status of its nearest aquifer cell center
// (Voronoi, the 25-squared-distance rule), so underground pockets get their
// OWN water tables (perched mountain lakes, lava pools, waterfalls) instead
// of one global fill.
//
// THE MODEL (vanilla constants literal, per the AC-0347 prerequisite):
//   cells      16×12×16, grid offset (5,5,1); center = corner + 5/+5/+1
//              + jitter 0–9 x / 0–8 y / 0–9 z (hash3i, seed+316/317/318).
//   status     per cell center, from 13 surface samples (the chunk-centre
//              columns around the centre chunk: own + W1-3/E1/N1/S1 + the 4
//              diagonals + (0,±2) — the wiki's "13 chunk offsets"; only the
//              own + the min are consumed, so the exact 12-set is immaterial):
//              (1) cell bottom (cy−12) above its own surface → GLOBAL (water
//              level SEA, or the lava layer when the cell lies in it);
//              (2) cell top (cy+12) above any sampled surface below sea →
//              SEA (water level SEA);
//              (3) else underground: the EXCLUSION (erosion < −0.225 and
//              depth 1.5 − cy/128 > 0.9 → dry; the deep-dark analogue — see
//              the plan's adaptation note) or fluid_level_floodedness vs the
//              thresholds (full > −0.3→0.8 / partial > −0.8→0.4, linear over
//              64 blocks below the lowest sampled surface when the own
//              surface is under sea, 0.8/0.4 on land): full → level SEA;
//              partial → 40·⌊cy/40⌋ + 20 + spread (spread ∈ {−10,−7,−4,−1,
//              2,5,8} from fluid_level_spread, once per 16×40×16 region),
//              CAPPED AT THE LOWEST SAMPLED SURFACE ("capped at the
//              preliminary surface");
//              (4) lava type: flooded cell with level ≤ 54 (vanilla −10) and
//              |lava noise| > 0.3 (once per 64×40×64 region).
//   block      12 candidate centers (2×3×2), 4 nearest by squared distance;
//              gap ≥ 25 → the nearest status (fluid when y ≤ level, else air);
//              gap < 25 → the BARRIER zone: pressure between the differing
//              fluid statuses among the cluster (d2 − d2[0] < 25) — between
//              the levels: 1 + min distance to either level (peaks in the
//              middle); above the higher: decays over 5 rows (the ≤5 lid);
//              below the lower: decays over 23 rows (the ≤23 floor); a
//              water-lava pair: the strong constant 6.0; + 2·barrier noise
//              (the irregular rim). p > 0 → stone (only where y < he — the
//              rim can never raise the surface, so H cannot move).
//   fluids     the lava layer y ≤ 10 (vanilla −54, "exists regardless of
//              aquifers") supersedes the aquifer per block (replacing the old
//              y < 8 pocket rule); aquifer fluid gets fl = 8 (the scheduled
//              flowing tick — the waterfalls) when it sits in the barrier
//              zone next to a differing status, or is water directly above
//              the lava layer (y = 11). The AC-0342 surface rule (y ∈
//              [he+1, SEA], H < sea → WATER) stays FIRST and unchanged — the
//              ocean surface + the submarine flood to sea level are
//              byte-identical by construction; the aquifer only decides the
//              cells below he+1 (ocean) or all air cells (land).
//
// ADAPTATIONS (vs vanilla's exact text — see tasks/AC-0291/plan.html §2):
//   * NO +8 RAISE — vanilla raises its PRELIMINARY surface (≈ actual −8)
//     before the comparisons; AweCraft's H IS the actual surface, so all
//     comparisons use the raw sampled H. Consequence: a lake can NEVER sit
//     above the lowest sampled ground (the AC-0342 open-pool artifact class
//     is structurally impossible; land caves gain hidden perched lakes only).
//   * H samples are DENSE (aqu_surface_h_dense — the same three surface
//     fields evaluated directly at the sea slice, no lattice build): they
//     differ from the exact H by the trilinear residual (a few blocks). The
//     cell status must be a pure f(world, seed) (shared across chunk seams),
//     so the own-chunk exact heights[] are not used. Exact H itself never
//     moves (thash is the proof).
//   * erosion/depth for the exclusion: the vanilla erosion instance as-is
//     (firstOctave −9, amps [1,1,0,1,1], xz 0.25 / y 0) WITHOUT its
//     shift_x/shift_z (they derive from the unported overworld/offset graph);
//     depth = the vanilla y-gradient without the offset blend.
//   * the barrier pressure closed form implements the wiki's stated shape
//     (positive between, ≤5 lid, ≤23 floor, strong water-lava constant,
//     noise-irregular) with the ticket's 5/23 constants.
//
// FULL PATH ONLY: the skip (lazy) path keeps its old `!solid` behavior
// (y < 8 lava) — the aquifer, like the cave field and the carver, is built
// only where the full density runs, so the skip/far payloads stay bit-exact
// by construction. The dense sources (aqu_* below) are bound for the
// genprobe lockstep (the AC-0291 aquifer block in the arm).
// ---------------------------------------------------------------------------

static inline int floordiv(int a, int b) {
	int q = a / b;
	if (a % b != 0 && ((a < 0) != (b < 0)))
		q -= 1;
	return q;
}

// The vanilla noise instances (overworld.json AS-IS; all single-octave
// except erosion; xz scale 1.0 = 64-block wavelength, y scale as ticketed).
constexpr double AQU_FLOOD_Y = 0.67;
constexpr int AQU_FLOOD_OCT = -7;
constexpr double AQU_SPREAD_Y = 0.7142857142857143;
constexpr int AQU_SPREAD_OCT = -5;
constexpr double AQU_BARRIER_Y = 0.5;
constexpr int AQU_BARRIER_OCT = -3;
constexpr int AQU_LAVA_OCT = -1;
constexpr double AQU_EROSION_XZ = 0.25;
constexpr int AQU_EROSION_OCT = -9;
static const double AQU_ONE[] = { 1.0 };
static const double AQU_EROSION_AMPS[] = { 1.0, 1.0, 0.0, 1.0, 1.0 };
constexpr int AQU_EROSION_N = 5;

// The aquifer geometry (vanilla AS-IS) + the +64-shifted lava constants.
constexpr int AQU_CX = 16, AQU_CY = 12, AQU_CZ = 16;
constexpr int AQU_OX = 5, AQU_OY = 5, AQU_OZ = 1;
constexpr int AQU_LAVA_SURF = 10;    // vanilla −54 + 64 — the lava layer surface row
constexpr int AQU_LAVA_LEVEL_MAX = 54; // vanilla −10 + 64 — "level at or below"
constexpr double AQU_LAVA_WALL = 6.0;  // the strong fixed water-lava pressure
// The 13 surface-sample chunk offsets (see the section header).
static const int AQU_SX[13] = { 0, -1, -2, -3, 1, 0, 0, 1, 1, -1, -1, 0, 0 };
static const int AQU_SZ[13] = { 0, 0, 0, 0, 0, 1, -1, 1, -1, 1, -1, 2, -2 };

static inline double aqu_floodedness(double x, double y, double z, int64_t s) {
	return vn3(x, y * AQU_FLOOD_Y, z, s + 311, AQU_FLOOD_OCT, AQU_ONE, 1);
}
static inline double aqu_spread(double x, double y, double z, int64_t s) {
	return vn3(x, y * AQU_SPREAD_Y, z, s + 312, AQU_SPREAD_OCT, AQU_ONE, 1);
}
static inline double aqu_barrier(double x, double y, double z, int64_t s) {
	return vn3(x, y * AQU_BARRIER_Y, z, s + 313, AQU_BARRIER_OCT, AQU_ONE, 1);
}
static inline double aqu_lava(double x, double y, double z, int64_t s) {
	return vn3(x, y, z, s + 314, AQU_LAVA_OCT, AQU_ONE, 1);
}
static inline double aqu_erosion(double x, double z, int64_t s) {
	// The vanilla erosion instance at xz_scale 0.25 / y_scale 0 (2-D); the
	// shifted_noise shift is omitted (see the section header).
	return vn3(x * AQU_EROSION_XZ, 0.0, z * AQU_EROSION_XZ, s + 315,
			AQU_EROSION_OCT, AQU_EROSION_AMPS, AQU_EROSION_N);
}

// The aquifer's H reference — the DENSE sea-slice surface (the exact
// surface_h formula with the three fields evaluated directly instead of
// trilinear off the 4-block lattice; the 2-octave builds match
// build_field's default). Differs from the exact H by the trilinear
// residual; the cap uses it raw (no +8 — the section header).
static inline int aqu_surface_h_dense(int x, int z, int64_t seed) {
	double c = fbm3((double)x / 220.0, 126.0 / 64.0, (double)z / 220.0, seed, 2);
	double h = fbm3((double)x / 70.0 + 333.0, 126.0 / 64.0, (double)z / 70.0 + 333.0, seed + 7, 2);
	double r = fbm3((double)x / 300.0 + 500.0, 126.0 / 64.0, (double)z / 300.0 + 500.0, seed + 13, 2);
	double cc = 0.4219 + (c - 0.3681) * (0.1280 / 0.0467);
	double hc = 0.4964 + (h - 0.5112) * (0.1361 / 0.1107);
	double rc = 0.4292 + (r - 0.5743) * (0.1366 / 0.1443);
	double y = 105.2 + cc * 36.4 + hc * 52.0;
	if (rc > 0.62)
		y += (rc - 0.62) * 390.0;
	return clampi((int)std::floor(y), 3, TERRAIN_H_MAX);
}

struct AquCell {
	int16_t cx, cy, cz; // the center (world block)
	int8_t type;        // 0 dry, 1 water, 2 lava
	int16_t level;      // the topmost fluid row (0 when dry)
	int8_t cls;         // 0 excluded, 1 dry-noise, 2 sea, 3 global, 4 full, 5 partial
};

// The per-chunk table: the 315 cells the chunk's blocks can ever query
// (cell x index ∈ {cx−1, cx, cx+1}, y ∈ {−2..32} (35), z ∈ {cz−1, cz, cz+1})
// + the 7×5 dense-H window (the chunk-centre columns of ncx ∈ [cx−4, cx+2],
// ncz ∈ [cz−2, cz+2]).
struct AquTable {
	AquCell cells[3][35][3];
	int16_t h[35];
	// The max fluid level over all 315 cells (0 when none is a fluid) —
	// the per-chunk bound for the sky-block fast path in the fill loop
	// (a block with y > this can hold no aquifer fluid).
	int16_t max_fluid{0};
};

static inline void aqu_cell_build(int ix, int iy, int iz, int64_t seed, int sea,
		const AquTable &hm, int cx0, int cz0, AquCell &c) {
	c.cx = (int16_t)(ix * AQU_CX + AQU_OX + (int)(hash3i((int64_t)ix, 0, (int64_t)iz, seed + 316) * 10.0));
	c.cy = (int16_t)(iy * AQU_CY + AQU_OY + (int)(hash3i(0, (int64_t)iy, (int64_t)iz, seed + 317) * 9.0));
	c.cz = (int16_t)(iz * AQU_CZ + AQU_OZ + (int)(hash3i((int64_t)ix, 0, (int64_t)iz, seed + 318) * 10.0));
	int hown = 1 << 30;
	int hmin = 1 << 30;
	bool sea_poke = false;
	for (int k = 0; k < 13; k++) {
		int h = hm.h[(ix + AQU_SX[k] - (cx0 - 4)) * 5 + (iz + AQU_SZ[k] - (cz0 - 2))];
		if (k == 0)
			hown = h;
		if (h < hmin)
			hmin = h;
		if (h < sea && c.cy + 12 > h)
			sea_poke = true;
	}
	if (c.cy - 12 > hown) {
		// The global fluid rule (the cell's bottom is above its own
		// surface — "cells high above ground contain only air" once the
		// per-block y ≤ level test runs).
		if (c.cy + 12 <= AQU_LAVA_SURF) {
			c.type = 2;
			c.level = AQU_LAVA_SURF;
		} else {
			c.type = 1;
			c.level = sea;
		}
		c.cls = 3;
		return;
	}
	if (sea_poke) {
		c.type = 1;
		c.level = sea;
		c.cls = 2;
		return;
	}
	// Underground.
	bool excluded = (aqu_erosion((double)c.cx, (double)c.cz, seed) < -0.225)
			&& (1.5 - (double)c.cy / 128.0 > 0.9);
	if (excluded) {
		c.type = 0;
		c.level = 0;
		c.cls = 0;
		return;
	}
	double f = aqu_floodedness((double)c.cx, (double)c.cy, (double)c.cz, seed);
	if (f < -1.0)
		f = -1.0;
	else if (f > 1.0)
		f = 1.0;
	double full_th, part_th;
	if (hown < sea) {
		// Under the sea floor: the thresholds relax from the land values
		// toward the underwater values over 64 blocks below the lowest
		// sampled surface (the wiki's two-column table, linear between).
		double t = ((double)hmin - (double)c.cy) / 64.0;
		if (t < 0.0)
			t = 0.0;
		else if (t > 1.0)
			t = 1.0;
		full_th = -0.3 + 1.1 * t;
		part_th = -0.8 + 1.2 * t;
	} else {
		full_th = 0.8;
		part_th = 0.4;
	}
	if (f > full_th) {
		c.type = 1;
		c.level = sea;
		c.cls = 4;
	} else if (f > part_th) {
		int rx = floordiv(c.cx, 16);
		int ry = floordiv(c.cy, 40);
		int rz = floordiv(c.cz, 16);
		double sv = aqu_spread(16.0 * rx + 8.0, 40.0 * ry + 20.0, 16.0 * rz + 8.0, seed);
		int sraw = (int)std::floor(sv * 10.0 + 0.5);
		if (sraw < -10)
			sraw = -10;
		else if (sraw > 10)
			sraw = 10;
		int q = (int)std::floor((sraw + 10) / 3.0 + 0.5);
		if (q < 0)
			q = 0;
		else if (q > 6)
			q = 6;
		int level = 40 * floordiv(c.cy, 40) + 20 + (q * 3 - 10);
		if (level > hmin)
			level = hmin; // capped at the lowest sampled surface (no +8 — see above)
		c.type = 1;
		c.level = (int16_t)level;
		c.cls = 5;
	} else {
		c.type = 0;
		c.level = 0;
		c.cls = 1;
		return;
	}
	// The lava type: a flooded cell becomes lava when its level is at or
	// below vanilla −10 (ours 54) and |lava| > 0.3, once per 64×40×64 region.
	if (c.type == 1 && c.level <= AQU_LAVA_LEVEL_MAX) {
		int lx = floordiv(c.cx, 64);
		int ly = floordiv(c.cy, 40);
		int lz = floordiv(c.cz, 64);
		double lv = aqu_lava(64.0 * lx + 32.0, 40.0 * ly + 20.0, 64.0 * lz + 32.0, seed);
		if (lv < 0.0)
			lv = -lv;
		if (lv > 0.3)
			c.type = 2;
	}
}

static inline void aqu_table_build(int cx, int cz, int64_t seed, int sea, AquTable &t) {
	for (int i = 0; i < 7; i++) {
		for (int j = 0; j < 5; j++) {
			int ncx = cx - 4 + i;
			int ncz = cz - 2 + j;
			t.h[i * 5 + j] = (int16_t)aqu_surface_h_dense(ncx * 16 + 8, ncz * 16 + 8, seed);
		}
	}
	for (int ax = 0; ax < 3; ax++) {
		for (int ay = 0; ay < 35; ay++) {
			for (int az = 0; az < 3; az++) {
				aqu_cell_build(cx - 1 + ax, -2 + ay, cz - 1 + az, seed, sea, t, cx, cz,
						t.cells[ax][ay][az]);
			}
		}
	}
	int16_t mf = 0;
	for (int ax = 0; ax < 3; ax++) {
		for (int ay = 0; ay < 35; ay++) {
			for (int az = 0; az < 3; az++) {
				const AquCell &c = t.cells[ax][ay][az];
				if (c.type > 0 && c.level > mf)
					mf = c.level;
			}
		}
	}
	t.max_fluid = mf;
}

// The barrier pressure between two fluid levels at block height y (the
// wiki's shape: positive between, peaking in the middle; ≤5 rows of lid
// above the higher; ≤23 rows of floor below the lower).
static inline double aqu_pressure(int y, int la, int lb) {
	int lo = (la < lb) ? la : lb;
	int hi = (la < lb) ? lb : la;
	if (y > hi)
		return (double)hi + 5.0 - (double)y;
	if (y >= lo)
		return 1.0 + (y - lo < hi - y ? (double)(y - lo) : (double)(hi - y));
	return (double)y - (double)lo + 23.0;
}

struct AquOut {
	uint8_t block; // 0 = air (no fluid / no stone), B_WATER, B_LAVA, B_STONE (rim)
	uint8_t fl;    // 0 = stationary, 8 = the scheduled flowing tick
};

static inline void aqu_block(int x, int y, int z, int he, int cx, int cz,
		const AquTable &t, int64_t seed, int sea, AquOut &out) {
	out.block = 0;
	out.fl = 0;
	int ix = floordiv(x - AQU_OX, AQU_CX);
	int iy = floordiv(y - AQU_OY, AQU_CY);
	int iz = floordiv(z - AQU_OZ, AQU_CZ);
	int ax = ix - (cx - 1);
	int ay = iy + 2;
	int az = iz - (cz - 1);
	// The 4 nearest of the 12 candidate centers (insertion-sorted list).
	double d2[4];
	int ci[4];
	for (int i = 0; i < 4; i++) {
		d2[i] = 1e300;
		ci[i] = 0;
	}
	for (int dx = 0; dx <= 1; dx++) {
		for (int dy = -1; dy <= 1; dy++) {
			for (int dz = 0; dz <= 1; dz++) {
				int aax = ax + dx;
				int aay = ay + dy;
				int aaz = az + dz;
				if (aax < 0 || aax >= 3 || aay < 0 || aay >= 35 || aaz < 0 || aaz >= 3)
					continue; // out of the table (≥ 20 blocks away in y — never 4th nearest)
				const AquCell &c = t.cells[aax][aay][aaz];
				double dx2 = (double)x - (double)c.cx;
				double dy2 = (double)y - (double)c.cy;
				double dz2 = (double)z - (double)c.cz;
				double dd = dx2 * dx2 + dy2 * dy2 + dz2 * dz2;
				// Insertion into the size-4 nearest list: a candidate FARTHER than
				// the current 4th can never enter (the list stays sorted ascending)
				// — the guard is also what keeps the shift inside the array (an
				// unconditional tail write at i = 3 would overflow it).
				if (dd > d2[3])
					continue;
				int i = 3;
				while (i >= 1 && d2[i - 1] > dd) {
					d2[i] = d2[i - 1];
					ci[i] = ci[i - 1];
					i--;
				}
				d2[i] = dd;
				ci[i] = aay * 9 + aaz * 3 + aax;
			}
		}
	}
	// idx = aay * 9 + aaz * 3 + aax (the candidate loop's packing) —
	// decode against the STORED layout cells[ax][ay][az] = [3][35][3]:
	// x = idx % 3, y = idx / 9, z = (idx / 3) % 3.
	auto cell_at = [&](int idx) -> const AquCell & {
		return t.cells[idx % 3][idx / 9][(idx / 3) % 3];
	};
	const AquCell &n0 = cell_at(ci[0]);
	bool diff_status = false;
	if (d2[1] - d2[0] < 25.0) {
		// The barrier zone: pressure between the differing fluid statuses
		// among the cluster (d2 − d2[0] < 25).
		double p = 0.0;
		for (int i = 0; i < 4 && d2[i] - d2[0] < 25.0; i++) {
			for (int j = i + 1; j < 4 && d2[j] - d2[0] < 25.0; j++) {
				const AquCell &a = cell_at(ci[i]);
				const AquCell &b = cell_at(ci[j]);
				if (a.type > 0 && b.type > 0 && (a.type != b.type || a.level != b.level)) {
					double pa = (a.type != b.type)
							? AQU_LAVA_WALL
							: aqu_pressure(y, a.level, b.level);
					if (pa > p)
						p = pa;
					diff_status = true;
				}
			}
		}
		if (p > 0.0) {
			p += 2.0 * aqu_barrier((double)x, (double)y, (double)z, seed);
		}
		if (p > 0.0 && y < he) {
			// The stone rim (only below the topmost solid — the rim can
			// never raise the surface; H cannot move by construction).
			out.block = B_STONE;
			g_aqu_stones.fetch_add(1, std::memory_order_relaxed);
			return;
		}
	}
	// The nearest status (the clear zone takes it outright; the barrier
	// zone falls through here when it did not turn the block to stone).
	// The AC-0342 land-dry gate: fluid only BELOW the topmost solid
	// (y < he) — the same gate the barrier stone above uses. A cave that
	// opens a land column's top (he drops below the pre-carve surface)
	// therefore does NOT get its opening flooded to the water table: the
	// perched/cave lakes stay hidden (y < he, below the terrain — the
	// feature) and open water in land columns stays 0 (the contract).
	// Vanilla would flood the opened mouth to the table; AweCraft's
	// AC-0342 contract is stricter, and this is the documented adaptation
	// that reconciles the two (ocean columns are untouched — their sea
	// fill is the separate rule above, H < sea).
	if (n0.type > 0 && y <= n0.level && y < he) {
		out.block = (n0.type == 1) ? B_WATER : B_LAVA;
		if (n0.type == 1)
			g_aqu_water.fetch_add(1, std::memory_order_relaxed);
		else
			g_aqu_lava.fetch_add(1, std::memory_order_relaxed);
		// The scheduled flowing tick: a fluid at a boundary between cells
		// of DIFFERING statuses (the waterfalls) — or water directly above
		// the lava layer (always scheduled, per the wiki).
		bool flow = diff_status;
		if (!flow && n0.type == 1 && y == AQU_LAVA_SURF + 1)
			flow = true;
		if (flow) {
			out.fl = 8;
			g_aqu_fl8.fetch_add(1, std::memory_order_relaxed);
		}
	}
}

// ---------------------------------------------------------------------------
// Column generation.
// ---------------------------------------------------------------------------

// AC-0284b: the shared 256-height pass — the heights (the surface_h of the
// three coarse SURFACE fields) and the biome bcode (the two direct fbm2
// calls). Extracted VERBATIM from gen_flat's inline loop (the full/skip
// paths call it with their already-built fields; the far path calls it
// with its own). The H of EVERY path — full, skip and far — is bit-exact
// by construction (same fields, same lattice, same surface_h; the genhash
// canary + the farab H battery gate it). AC-0314: the padcol output is
// gone with the spawn pad.
static void col_heights_pass(const Field &f_sc, const Field &f_sh, const Field &f_sr,
		double ystep, int bx, int bz, int64_t seed,
		std::vector<int> &heights, std::vector<int> &bcode) {
	for (int lz = 0; lz < 16; lz++) {
		for (int lx = 0; lx < 16; lx++) {
			int idx = lz * 16 + lx;
			int x = bx + lx;
			int z = bz + lz;
			heights[idx] = surface_h(x, z, f_sc, f_sh, f_sr, ystep, bx, bz);
			double t = fbm2((double)x / 260.0 + 900.0, (double)z / 260.0 + 900.0, seed + 21, 3) * 2.0 - 1.0;
			double m = fbm2((double)x / 260.0 + 1700.0, (double)z / 260.0 + 1700.0, seed + 33, 3) * 2.0 - 1.0;
			// bcode: 0 snow, 1 desert, 2 forest, 3 plains (biome_at order).
			int bc = 3;
			if (t < -0.25)
				bc = 0;
			else if (t > 0.35 && m < 0.1)
				bc = 1;
			else if (m > 0.25)
				bc = 2;
			bcode[idx] = bc;
		}
	}
}

// ---------------------------------------------------------------------------
// AC-0292 — the cave P4 trio: the NOISE PILLARS (the vanilla caves/pillars
// literal port), the ORE VEINS (sparse density blobs) and the 3-D CAVE
// BIOME field (deepslate / dripstone / lush / deep dark), + the extended
// surface-rule stage (deepslate transition, the bedrock band).
//
// PILLARS — the 1.21.4 `caves/pillars` density function AS-IS (verified
// against the shipped JSON, .scratch/AC-0292-vanilla/):
//   cache_once(mul(
//       add(mul(2.0, noise{pillar, xz 25.0, y 0.3}),
//           add(-1.0, mul(-1.0, noise{pillar_rareness, 1.0, 1.0}))),
//       cube(add(0.55, mul(0.55, noise{pillar_thickness, 1.0, 1.0})))))
// with the three vanilla noise instances (worldgen/noise/*.json):
//   pillar              {firstOctave -7, amps [1, 1]}
//   pillar_rareness     {firstOctave -8, amps [1]}
//   pillar_thickness    {firstOctave -8, amps [1]}
// The `noise` density-function value is the CENTERED vn3 value per the
// project convention (AC-0347 P2: all ported noise = 2*(vn3-0.5) — the
// vanilla O(1) units). So the port is
//   P = (2*Np + (-1 - Nr)) * (0.55 + 0.55*Nt)^3      (N* centered).
// In the router the pillar max sits in the DEEP branch only (the
// final_density range_choice's when_out_of_range, the sloped-cheese split
// AweCraft models with k = H - y >= K_CUT):
//   solid = (router > 0 and not tunnel) or (deep and P >= 0.03).
// The vanilla max is OUTSIDE the spaghetti min, so a pillar cell is solid
// even where the tunnels carve — the pillar wins. The deep-only gate keeps
// every pillar solid <= H - 16, so he <= H (the H/far/promotion contract)
// holds by construction. The field stores P on the C48 cave lattice (the
// build_field_eval_c route — one tril_c per deep scan point); the dense
// pillar_density below is the exact expression the genprobe lockstep
// mirrors.
//
// VEINS — one vn3 field (seed +323, {firstOctave -5, amps [1, 0.5]},
// isotropic 32+16-block period — the blob scale). The stone_ore chain
// checks it FIRST (full path only), with the NESTED per-ore thresholds
// VEIN_D/I/C_TH inside the speckle's y-bands (y<16/42/60): the coal blob
// contains the iron which contains the diamond — the layered deposit.
// The legacy f_ore1/2/3 speckle runs after (kept — the ticket says the
// blobs are IN ADDITION to the thin thresholds). The skip/far paths stay
// vein-free (the band-A materialization is the provisional no-cave fill —
// same documented adaptation as the caves/aquifer/carvers).
//
// CAVE BIOME — one vn3 field (seed +319, {firstOctave -7, amps [1, 1]},
// scale 0.5 — ~100-300-block regions). One biome per position: value <
// 0.40 -> DEEP DARK, < 0.60 -> DRIPSTONE, else LUSH; the y-bands (the
// vanilla ranges +64) gate each. The cost route (the budget ask): the
// biome is precomputed per column at the 16 y-levels (16 tril_c reads/
// column — not per cell), and the per-cell cost drops to one hash where
// the level's biome matches. Rules (full path only):
//   deep dark (y 1..63):   stone/deepslate -> sculk   (hash +327, p 0.10)
//   lush (y 64..128):      stone/deepslate -> moss    (hash +328, p 0.06)
//   dripstone (y 48..128): the post-carve air-run pass — stalactite from
//     the ceiling / stalagmite from the floor (2-6 blocks, 35% of eligible
//     runs, hashes +330/+331, lengths +332/+335) where the CONTACT level's
//     biome is dripstone; and the CLAY POOLS: aquifer water over a solid
//     floor in a pool-hash column (hash +329, p 0.06) -> the bottom 1-3
//     water cells become clay (depths +334/+336). The clay is a block swap
//     ONLY — the water table level + fl marks + sea fills are never
//     touched (the AC-0291 aquifer contract).
//
// SURFACE RULES — the deepslate transition (rock_base: y<64 deepslate,
// the 64..71 vanilla random-gradient blend per-cell hash +326, stone
// above) in the fill chain AND stone_ore_slab (the far deep-color
// precompute — the farab identity); the bedrock band y 0..4 in the fill
// AND h_avg_emit (mesh.cpp); the top block H<64 -> deepslate in the fill
// top row AND gen_far (the farab 4a identity — both move together). Ores
// in the deepslate zone keep their ore ids (the vanilla deepslate-ore
// variants are a documented simplification).
// ---------------------------------------------------------------------------

static const double PILLAR_OCT_AMPS[2] = { 1.0, 1.0 };
static const double ONE_AMP[1] = { 1.0 };

// The vanilla caves/pillars expression AS-IS (see the section above) — the
// DENSE source (the genprobe lockstep mirrors this; the field build uses
// the SAME expression via build_field_eval_c, so the lattice points are
// bit-exact with a dense evaluation).
static inline double pillar_density(double x, double y, double z, int64_t s) {
	double p = vn3(x * 25.0, y * 0.3, z * 25.0, s + 320, -7, PILLAR_OCT_AMPS, 2);
	double r = vn3(x, y, z, s + 321, -8, ONE_AMP, 1);
	double t = vn3(x, y, z, s + 322, -8, ONE_AMP, 1);
	double np = 2.0 * (p - 0.5); // centered (the vanilla noise-function value)
	double nr = 2.0 * (r - 0.5);
	double nt = 2.0 * (t - 0.5);
	double a = 2.0 * np + (-1.0 - nr);
	double b = 0.55 + 0.55 * nt;
	return a * b * b * b;
}

// The vein field's dense source (the one vn3; the per-ore thresholds live
// in the stone_ore chain).
static inline double vein_density(double x, double y, double z, int64_t s) {
	return vn3(x * VEIN_XZ_SCALE, y * VEIN_Y_SCALE, z * VEIN_XZ_SCALE,
			s + 323, VEIN_FIRST_OCT, VEIN_AMPS, 2);
}

// The cave biome field's dense source (the one vn3; the value -> biome
// mapping lives in the per-column precompute in gen_flat).
static inline double biome_density(double x, double y, double z, int64_t s) {
	return vn3(x * BIOME_XZ_SCALE, y * BIOME_Y_SCALE, z * BIOME_XZ_SCALE,
			s + 319, BIOME_FIRST_OCT, BIOME_AMPS, 2);
}

// The rock base — the surface-rule stage's deepslate transition. The fill
// chain, stone_ore_slab and (via it) the far emit's deep cells must all
// agree on this (the farab A/B contract).
static inline uint8_t rock_base(int y, int x, int z, int64_t s) {
	if (y < DEEPSLATE_Y)
		return (uint8_t)B_DEEPSLATE;
	if (y < DEEPSLATE_BLEND_TOP) {
		double t = (double)(DEEPSLATE_BLEND_TOP - y) * 0.125; // 1.0 @64 -> 0.125 @71
		return hash3i(x, y, z, s + 326) < t ? (uint8_t)B_DEEPSLATE : (uint8_t)B_STONE;
	}
	return (uint8_t)B_STONE;
}

// AC-0284b: the FAR (h-only) column — the skip arg value 2 (see the file
// header). NO slabs, NO cave field, NO ore fields: only the 256 H (u16
// LE), the 256 biome bcodes and the 256 TOP-BLOCK ids (the bit-exact
// fill-loop top-row formula: the surface block from biome/H, the same
// cell the skip path fills at y == H — the halo's 4x4 avg emitter
// (AweMesh.h_avg_emit) reconstructs the exact skip-fill surface from it).
// The H is bit-exact with the full path's H (the shared col_heights_pass
// above — the promotion-consistency contract: a promoted far column's
// full regen keeps the same H, the halo terrain never shifts). The 1024-
// byte payload is what the v6 codec (flag bit 1) stores in place of the
// slab section (~1 KB on disk — AC-0287's save filter drops it entirely).
static std::vector<uint8_t> gen_far(int cx, int cz, int64_t seed, int hmax, int sea) {
	int bx = cx * 16;
	int bz = cz * 16;
	double ystep = (double)hmax / GY_CELLS;
	long long t0 = now_us();
	g_t_cols_far.fetch_add(1, std::memory_order_relaxed);
	// Only the 3 SURFACE fields (the 2-octave 441-pt builds — the H's
	// physics). The cave + ore fields are never read here.
	long long t_field = now_us();
	Field f_sc, f_sh, f_sr;
	build_field(f_sc, bx, bz, ystep, seed, 220.0, SURF_YSCALE, 220.0, 0.0, 0.0, 0.0);
	build_field(f_sh, bx, bz, ystep, seed + 7, 70.0, SURF_YSCALE, 70.0, 333.0, 0.0, 333.0);
	build_field(f_sr, bx, bz, ystep, seed + 13, 300.0, SURF_YSCALE, 300.0, 500.0, 0.0, 500.0);
	g_t_field_us.fetch_add(now_us() - t_field, std::memory_order_relaxed);
	long long t_ht = now_us();
	std::vector<int> heights(256);
	std::vector<int> bcode(256);
	col_heights_pass(f_sc, f_sh, f_sr, ystep, bx, bz, seed, heights, bcode);
	g_t_heights_us.fetch_add(now_us() - t_ht, std::memory_order_relaxed);
	std::vector<uint8_t> out(1024, 0);
	for (int i = 0; i < 256; i++) {
		int H = heights[i];
		out[2 * i] = (uint8_t)(H & 0xFF);
		out[2 * i + 1] = (uint8_t)((H >> 8) & 0xFF);
		out[512 + i] = (uint8_t)bcode[i];
		// Top block — the fill loop's y == he row with he = H, verbatim
		// (the skip fill writes exactly this at the surface).
		uint8_t top = B_GRASS;
		if (bcode[i] == 1)
			top = B_SAND;
		else if (bcode[i] == 0)
			top = B_SNOW_GRASS;
		if (H <= sea + 1 && bcode[i] != 1)
			top = B_SAND;
		if (H < DEEPSLATE_Y)
			top = B_DEEPSLATE; // AC-0292: the fill top row matches (H<64 -> deepslate)
		out[768 + i] = top;
	}
	g_t_far_us.fetch_add(now_us() - t0, std::memory_order_relaxed);
	return out;
}

// AC-0284b: the column's TREE cells — the veg pass's tree writes (the
// log trunk + the leaf blob) that land INSIDE this column, in the veg
// loop's write order, first-writer-wins (the flat[i] == 0 guard — a
// later tree never overwrites an earlier tree's cell). 4 bytes/cell:
// (id << 24) | (y << 8) | (z << 4) | x. The skip-mode veg is a pure
// f(H, biome, x, z, seed): hcol = H2 (the shared surface — the neighbor
// band is lazy too, no cave term), the in-column top check always
// passes (H2 > sea + 1 gates the tree; the fill top at H2 is a solid
// non-water block), and every tree cell lands in AIR (the skip fill is
// solid exactly y <= max(H, sea) < H2 + 1) — so the flat[i] == 0 guard
// is a no-op here. The flowers are CLUTTER (air in both the slab emit's
// recount and the far emit) — they never flip a 4x4x4 cell, so they are
// not listed. The 20x20 neighborhood: trees up to 2 cells OUTSIDE the
// column reach into it (the 5x5 leaf footprint).
static std::vector<uint8_t> gen_veg_cells(int cx, int cz, int64_t seed, int hmax, int sea) {
	long long t0 = now_us();
	int bx = cx * 16;
	int bz = cz * 16;
	double ystep = (double)hmax / GY_CELLS;
	Field f_sc, f_sh, f_sr;
	build_field(f_sc, bx, bz, ystep, seed, 220.0, SURF_YSCALE, 220.0, 0.0, 0.0, 0.0);
	build_field(f_sh, bx, bz, ystep, seed + 7, 70.0, SURF_YSCALE, 70.0, 333.0, 0.0, 333.0);
	build_field(f_sr, bx, bz, ystep, seed + 13, 300.0, SURF_YSCALE, 300.0, 500.0, 0.0, 500.0);
	std::vector<int> heights(256);
	std::vector<int> bcode(256);
	col_heights_pass(f_sc, f_sh, f_sr, ystep, bx, bz, seed, heights, bcode);
	// seen: 0 = air, 1 = a tree cell (first-writer-wins, the veg loop's
	// write order), -1 = FLOWER-OVERWRITTEN (see below). The flower
	// pass runs AFTER the trees and writes rose/dandelion at
	// (x, H + 1, z) UNCONDITIONALLY (no flat == 0 guard) when the top
	// is grass — it can overwrite this column's own trunk-base cell OR
	// a margin tree's leaf cell that landed at (x, H(x,z) + 1, z). A
	// flower is CLUTTER (air in both the slab emit's recount and the
	// far emit), so an overwritten cell drops out of the list.
	std::vector<char> seen((size_t)hmax * 256, 0);
	std::vector<int> cells;
	std::vector<uint8_t> ids;
	for (int tz = bz - 2; tz < bz + 18; tz++) {
		for (int tx = bx - 2; tx < bx + 18; tx++) {
			double hv = hash2i(tx, tz, seed + 55);
			if (hv >= 0.14)
				continue;
			int glx = tx - bx;
			int glz = tz - bz;
			int H2;
			if (glx >= 0 && glx < 16 && glz >= 0 && glz < 16)
				H2 = heights[glz * 16 + glx];
			else
				H2 = surface_h(tx, tz, f_sc, f_sh, f_sr, ystep, bx, bz);
			if (H2 <= sea + 1)
				continue;
			double tv = fbm2((double)tx / 260.0 + 900.0, (double)tz / 260.0 + 900.0, seed + 21, 3) * 2.0 - 1.0;
			double mv = fbm2((double)tx / 260.0 + 1700.0, (double)tz / 260.0 + 1700.0, seed + 33, 3) * 2.0 - 1.0;
			bool snow = tv < -0.25;
			bool desert = tv > 0.35 && mv < 0.1;
			bool forest = mv > 0.25;
			double dens = 0.0;
			if (forest)
				dens = 0.14;
			else if (snow || (!desert && !forest))
				dens = 0.02; // plains or snow
			if (hv >= dens)
				continue;
			int hcol = H2; // the lazy margin = the heightmap surface exactly
			if (hcol < 1)
				continue;
			int tth = 4 + (int)(hash2i(tx, tz, seed + 66) * 3.0);
			for (int dy = 1; dy <= tth; dy++) {
				int wy = hcol + dy;
				int ax = tx - bx;
				int az = tz - bz;
				if (ax >= 0 && ax < 16 && az >= 0 && az < 16 && wy >= 1 && wy < hmax) {
					int k = (wy << 8) | (az << 4) | ax;
					if (seen[k])
						continue;
					seen[k] = 1;
					cells.push_back(k);
					ids.push_back((uint8_t)B_LOG);
				}
			}
			for (int ly = tth - 1; ly <= tth + 2; ly++) {
				int rad = (ly >= tth + 1) ? 1 : 2;
				for (int dx = -rad; dx <= rad; dx++) {
					for (int dz = -rad; dz <= rad; dz++) {
						bool sk = false;
						if (rad == 2 && iabs(dx) == 2 && iabs(dz) == 2)
							sk = true;
						if (ly == tth + 2 && iabs(dx) == 1 && iabs(dz) == 1)
							sk = true;
						if (sk)
							continue;
						int wy = hcol + ly;
						int ax = tx + dx - bx;
						int az = tz + dz - bz;
						if (ax >= 0 && ax < 16 && az >= 0 && az < 16 && wy >= 1 && wy < hmax) {
							int k = (wy << 8) | (az << 4) | ax;
							if (seen[k])
								continue;
							seen[k] = 1;
							cells.push_back(k);
							ids.push_back((uint8_t)B_LEAVES);
						}
					}
				}
			}
		}
	}
	// The flower pass (after the trees — see the seen[] comment): the
	// in-column grass tops with the hash gates hit grow a flower at
	// (x, H + 1, z), overwriting whatever tree cell landed there.
	for (int lz = 0; lz < 16; lz++) {
		for (int lx = 0; lx < 16; lx++) {
			int idx = lz * 16 + lx;
			int fh = heights[idx];
			if (fh > sea && fh < hmax - 2) {
				uint8_t top = B_GRASS;
				if (bcode[idx] == 1)
					top = B_SAND;
				else if (bcode[idx] == 0)
					top = B_SNOW_GRASS;
				if (fh <= sea + 1 && bcode[idx] != 1)
					top = B_SAND;
				if (top == B_GRASS && hash2i(bx + lx, bz + lz, seed + 777) < 0.02) {
					int k = ((fh + 1) << 8) | (lz << 4) | lx;
					seen[k] = -1; // the flower wins (unconditional write)
				}
			}
		}
	}
	std::vector<uint8_t> out;
	for (size_t i = 0; i < cells.size(); i++) {
		if (seen[cells[i]] != 1)
			continue; // flower-overwritten (clutter — air in both emits)
		int wy = cells[i] >> 8;
		int az = (cells[i] >> 4) & 0xF;
		int ax = cells[i] & 0xF;
		uint32_t c = ((uint32_t)ids[i] << 24) | ((uint32_t)wy << 8) | ((uint32_t)az << 4) | (uint32_t)ax;
		out.push_back((uint8_t)(c & 0xFF));
		out.push_back((uint8_t)((c >> 8) & 0xFF));
		out.push_back((uint8_t)((c >> 16) & 0xFF));
		out.push_back((uint8_t)((c >> 24) & 0xFF));
	}
	g_t_vegcells_us.fetch_add(now_us() - t0, std::memory_order_relaxed);
	return out;
}

// skip != 0: the AC-0216 lazy path (offscreen interior band) — the 150-pt
// density evaluation is skipped free (see the file header).
//
// AC-0237 (window-scoped generation): p_keep = the 24-byte SLAB KEEP
// MASK (slab si generated iff p_keep[si] != 0; nullptr = the FULL column,
// bit-identical to the pre-AC-0237 output — the genhash A==B gate relies
// on it). A mask can be DISJOINT (the window's kept set = the tower's
// terrain span UNION the player band — two intervals while the player
// flies high); only the kept slabs get density-scanned + filled, every
// other slab stays ALL ZERO in the flat array, so palettize_slabs turns
// it into a NULL slab (the v4 codec's per-slab section is simply ABSENT —
// no format change). The caller (world.gd) stamps the chunk with the
// generated slabs (gen_mask): an absent slab is NOT air — the dispatch
// prep synthesizes it as a SOLID slab for the neighbor snap (the face
// hides behind the window's cap box) and the window's re-entry path
// regenerates it on demand (this function is a pure deterministic
// f(world coords, seed) — a regenerated slab is bit-exact, no
// cross-slab state exists). The surface slab is always kept (the span
// contains the tower's top), so the effective surface + veg always land.
static std::vector<uint8_t> gen_flat(int cx, int cz, int64_t seed, int hmax, int sea,
		int skip = 0, const uint8_t *p_keep = nullptr, std::vector<uint8_t> *p_fl = nullptr) {
	int bx = cx * 16;
	int bz = cz * 16;
	int nsl = hmax / 16;
	// AC-0291: the fl (fluid-level) array — the scheduled-flow marks (fl = 8
	// on the aquifer boundary water, 0 elsewhere). Only the FULL path marks
	// (the skip path keeps its all-zero fl — the band-A contract).
	if (p_fl != nullptr && !skip)
		p_fl->assign((size_t)hmax * 256, 0);
	AquTable aq;
	const AquTable *aq_p = nullptr;
	if (!skip) {
		long long ta = now_us();
		aqu_table_build(cx, cz, seed, sea, aq);
		aq_p = &aq;
		g_t_aquifer_us.fetch_add(now_us() - ta, std::memory_order_relaxed);
	}
	auto slab_kept = [&](int sl) -> bool {
		return p_keep == nullptr || sl < nsl || p_keep[sl] != 0;
	};
	double ystep = (double)hmax / GY_CELLS;
	// AC-0359: the cave lattice's y step (8 blocks — Bedrock's cell).
	double ystep_cave = (double)hmax / GY_CELLS_CAVE;

	if (skip) {
		g_skip_chunks_total.fetch_add(1, std::memory_order_relaxed);
		g_skip_cols_total.fetch_add(256, std::memory_order_relaxed);
		g_t_cols_skip.fetch_add(1, std::memory_order_relaxed);
	} else {
		g_t_cols_full.fetch_add(1, std::memory_order_relaxed);
	}

	// Coarse fields (441 lattice points each = 4x8x4 cells + 1-cell margin,
	// 2-octave AweNoise.fbm3 per lattice point). AC-0215: the 3D SURFACE
	// field (the AC-0091 2D heightmap's c/h/r, now 3D on the same coarse
	// grid — replaces the heightmap).
	long long t_field = now_us();
	// AC-0359: the CAVE family rides the second (C48) lattice — 8-block y
	// cells, 2401 points/field (cheese + 3 tunnels MOVED here from the
	// coarse lattice; layer + entrance NEW here, built only on the full
	// path — the dense vn3 calls leave the scan, the AC-0344 verdict).
	FieldC f_cheese{}, f_spag{}, f_nood{}, f_gate{}, f_layer{}, f_entr{};
	// AC-0292: the P4 fields (full path only — same as the cave family;
	// the skip/far paths never read them, the contracts hold by
	// construction).
	FieldC f_pillar{}, f_vein{}, f_biome{};
	Field f_ore1, f_ore2, f_ore3;
	if (!skip) {
		// AC-0347 P1: the cheese field = vanilla's cave_cheese as-is (see
		// the CHEESE_* constants + the file header) — ONE vn3 field
		// replaces the old AC-0288 two-octave blend (f_cave/f_cave2 gone).
		// AC-0359: on the cave lattice (ystep_cave).
		build_field_vn_c(f_cheese, bx, bz, ystep_cave, seed + 301,
				CHEESE_XZ_SCALE, CHEESE_Y_SCALE, CHEESE_XZ_SCALE,
				CHEESE_FIRST_OCT, CHEESE_AMPS, CHEESE_AMPS_N);
		// AC-0289: the P1 tunnel fields (see the file header) — FULL PATH
		// only: skip != 0 keeps the H/far/promotion contracts bit-exact
		// (the lazy fill and the far payload never read them).
		// AC-0359: on the cave lattice (ystep_cave).
		build_field_c(f_spag, bx, bz, ystep_cave, seed + 303, SPAG_XZ, 10.0, SPAG_XZ, 0.0, 0.0, 0.0);
		build_field_c(f_nood, bx, bz, ystep_cave, seed + 304, NOOD_XZ, 10.0, NOOD_XZ, 0.0, 0.0, 0.0);
		build_field_c(f_gate, bx, bz, ystep_cave, seed + 305, GATE_XZ, 10.0, GATE_XZ, 0.0, 0.0, 0.0);
		// AC-0359: the layer (vanilla cave_layer AS-IS — the 32-block period
		// rides 4 samples/period) and the entrance (vanilla cave_entrance
		// AS-IS) move ONTO the cave lattice — the AC-0344 C48 design. They
		// were DENSE vn3 in the scan before (layer deep-band only).
		build_field_vn_c(f_layer, bx, bz, ystep_cave, seed + 302,
				LAYER_XZ_SCALE, LAYER_Y_SCALE, LAYER_XZ_SCALE,
				LAYER_FIRST_OCT, LAYER_AMPS, LAYER_AMPS_N);
		build_field_vn_c(f_entr, bx, bz, ystep_cave, seed + 306,
				ENTR_XZ_SCALE, ENTR_Y_SCALE, ENTR_XZ_SCALE,
				ENTR_FIRST_OCT, ENTR_AMPS, ENTR_AMPS_N);
		// AC-0292: the PILLAR field — the full vanilla caves/pillars value
		// stored per lattice point (3 vn3 at build time, 1 tril_c in the
		// scan). The SAME expression as the dense pillar_density (the
		// genprobe lockstep source) — the lattice points are bit-exact
		// with a dense evaluation.
		build_field_eval_c(f_pillar, bx, bz, ystep_cave,
				[&](double x, double y, double z) {
					return pillar_density(x, y, z, seed);
				});
		// AC-0292: the ORE VEIN field (one vn3 — the nested per-ore
		// thresholds in the stone_ore chain below).
		build_field_vn_c(f_vein, bx, bz, ystep_cave, seed + 323,
				VEIN_XZ_SCALE, VEIN_Y_SCALE, VEIN_XZ_SCALE,
				VEIN_FIRST_OCT, VEIN_AMPS, 2);
		// AC-0292: the CAVE BIOME field (one vn3 — the per-column
		// 16-level precompute below).
		build_field_vn_c(f_biome, bx, bz, ystep_cave, seed + 319,
				BIOME_XZ_SCALE, BIOME_Y_SCALE, BIOME_XZ_SCALE,
				BIOME_FIRST_OCT, BIOME_AMPS, 2);
	}
	build_field(f_ore1, bx, bz, ystep, seed + 77, 7.0, 7.0, 7.0, 0.0, 0.0, 0.0);
	build_field(f_ore2, bx, bz, ystep, seed + 88, 9.0, 9.0, 9.0, 900.0, 0.0, 900.0);
	build_field(f_ore3, bx, bz, ystep, seed + 99, 6.0, 6.0, 6.0, 1700.0, 0.0, 1700.0);
	Field f_sc, f_sh, f_sr;
	build_field(f_sc, bx, bz, ystep, seed, 220.0, SURF_YSCALE, 220.0, 0.0, 0.0, 0.0);
	build_field(f_sh, bx, bz, ystep, seed + 7, 70.0, SURF_YSCALE, 70.0, 333.0, 0.0, 333.0);
	build_field(f_sr, bx, bz, ystep, seed + 13, 300.0, SURF_YSCALE, 300.0, 500.0, 0.0, 500.0);
	g_t_field_us.fetch_add(now_us() - t_field, std::memory_order_relaxed);
	long long t_ht = now_us();

	std::vector<int> heights(256);
	std::vector<int> heff(256);
	std::vector<int> bcode(256);
	col_heights_pass(f_sc, f_sh, f_sr, ystep, bx, bz, seed, heights, bcode);
	g_t_heights_us.fetch_add(now_us() - t_ht, std::memory_order_relaxed);

	std::vector<uint8_t> flat((size_t)hmax * 256, 0);

	// Solid rock fill (unchanged from AC-0188): the old ore chain (same
	// bands/thresholds, read from the coarse ore fields) + the exact old
	// obsidian hash.
	auto stone_ore = [&](int x, int y, int z, double gx, double gz) {
		// AC-0292: the VEIN blobs first (full path only — the skip/far
		// paths keep the speckle chain bit-exact, the documented
		// band-A adaptation). The nested thresholds on ONE field:
		// the coal blob contains the iron which contains the diamond.
		// The band short-circuit keeps y >= 60 cells free of the reads.
		if (!skip) {
			double gy_c = (double)y / ystep_cave;
			if (y < 16 && tril_c(f_vein, gx, gy_c, gz) > VEIN_D_TH) {
				g_p4_ore_vein.fetch_add(1, std::memory_order_relaxed);
				return B_DIAMOND_ORE;
			}
			if (y < 42 && tril_c(f_vein, gx, gy_c, gz) > VEIN_I_TH) {
				g_p4_ore_vein.fetch_add(1, std::memory_order_relaxed);
				return B_IRON_ORE;
			}
			if (y < 60 && tril_c(f_vein, gx, gy_c, gz) > VEIN_C_TH) {
				g_p4_ore_vein.fetch_add(1, std::memory_order_relaxed);
				return B_COAL_ORE;
			}
		}
		if (y < 16 && tril(f_ore1, gx, (double)y / ystep, gz) > 0.78)
			return B_DIAMOND_ORE;
		if (y < 42 && tril(f_ore2, gx, (double)y / ystep, gz) > 0.8)
			return B_IRON_ORE;
		if (y < 60 && tril(f_ore3, gx, (double)y / ystep, gz) > 0.82)
			return B_COAL_ORE;
		if (y < 10 && hash3i(x, y, z, seed + 333) < 0.02)
			return B_OBSIDIAN;
		// AC-0292: the surface-rule stage's deepslate transition (the
		// far emit's stone_ore_slab precompute agrees cell-for-cell).
		int b = rock_base(y, x, z, seed);
		if (b == B_DEEPSLATE)
			g_p4_deepslate.fetch_add(1, std::memory_order_relaxed);
		return b;
	};

	// AC-0290: the carver pass (post-density, pre-veg — see the file
	// header). The per-chunk plan (pure f(seed, cx, cz) — the splitmix64
	// chunk stream, no noise field). FULL PATH only: skip != 0 never builds
	// it (the far/skip payloads stay bit-exact by construction).
	const std::vector<CarveEll> no_carves;
	const std::vector<CarveEll> *carves_p = &no_carves;
	std::vector<CarveEll> carves;
	if (!skip) {
		build_carver_plan(cx, cz, seed, carves, nullptr);
		carves_p = &carves;
	}

	for (int lz = 0; lz < 16; lz++) {
		for (int lx = 0; lx < 16; lx++) {
			int idx = lz * 16 + lx;
			int H = heights[idx];
			int bm = bcode[idx];
			int x = bx + lx;
			int z = bz + lz;
			double gx = (double)lx / 4.0;
			double gz = (double)lz / 4.0;
			int base = (lz << 4) | lx;

			int he;
			std::vector<uint8_t> solidf;
			long long t_scan = now_us();
			if (skip) {
				// AC-0216: the 150-pt density evaluation is skipped free —
				// solid exactly 0..H (the heightmap surface), no caves, no
				// hidden caves built (no f_cheese read, no scan, no lava
				// pocket). The aquifer/surface/dirt/ore rules below apply
				// unchanged with he = H.
				he = H;
			} else {
				// The ONE density field, top-down: the solid flags + the
				// effective surface (topmost d > 0). Above H + R + 1 the field
				// is air for sure — RE-DERIVED structurally at AC-0347 P2:
				// for y >= H+10.5 (k <= -10.5 < K_CUT) the ramp clamps -1
				// exactly and the SHALLOW branch applies, so
				// d = min(-1, 5*entrances) <= -1 < 0 for ANY noise values;
				// the deep branch cannot reach above H - K_CUT and the tunnel
				// rule only removes solidity. The H+11 start stands on the
				// min/clamp structure — no noise budget is involved (the old
				// CAVE_AMP argument died with A(y)).
				// AC-0237: bounded to the generated slabs — solidf of an
				// ungenerated slab is never read (the fill loop never
				// emits there).
				solidf.resize((size_t)hmax, 0);
				he = -1;
				int top = H + 11;
				if (top > hmax - 1)
					top = hmax - 1;
				for (int y = top; y >= 1; y--) {
					if (!slab_kept(y >> 4))
						continue; // AC-0237: ungenerated slab — skip
					// AC-0359: the router inputs ALL from the C48 cave
					// lattice (8-block y cells) — cheese + the 3 tunnel
					// fields MOVED here, layer + entrance ONTO the lattice
					// (the dense vn3 calls leave the scan; the analytic
					// entrance y-gradient stays per-y in
					// entrance_from_latt). This is the scan that dropped
					// 4373 -> 1291 us/chunk in the AC-0344 measurement.
					double gy_c = (double)y / ystep_cave;
					double cave = tril_c(f_cheese, gx, gy_c, gz);
					double ent = entrance_from_latt(tril_c(f_entr, gx, gy_c, gz), (double)y);
					double lay = (H - y >= K_CUT)
							? tril_c(f_layer, gx, gy_c, gz)
							: 0.0;
					// AC-0289: the tunnel air wins over the router's solid —
					// applied OUTSIDE dens_at (the vanilla spaghetti min,
					// kept where AC-0289 put it: the tunnels pierce the caps).
					bool s0 = dens_at(H, y, cave, ent, lay) > 0.0
							&& !tunnel_air_c(f_spag, f_nood, f_gate, gx, gy_c, gz);
					// AC-0292: the PILLAR (the vanilla caves/pillars max,
					// deep branch only — the range_choice split). The max
					// sits OUTSIDE the spaghetti min, so a pillar cell is
					// solid even where the tunnels carve (the pillar wins):
					// solid = s0 or (deep and P >= 0.03). Deep-only (k >=
					// K_CUT) keeps every pillar solid <= H - 16, so he <= H
					// holds by construction (the H/far/promotion contract).
					bool s = s0;
					if (H - y >= K_CUT) {
						double pil = tril_c(f_pillar, gx, gy_c, gz);
						if (pil >= PILLAR_CHOICE_TH) {
							s = true;
							g_p4_pillar.fetch_add(1, std::memory_order_relaxed);
							if (!s0)
								g_p4_pillar_void.fetch_add(1, std::memory_order_relaxed);
						}
					}
					solidf[y] = s ? 1 : 0;
					if (s && he < 0)
						he = y;
				}
				if (he < 0)
					he = 0; // a fully-caved column: the bedrock is the "surface"
			}
			g_t_scan_us.fetch_add(now_us() - t_scan, std::memory_order_relaxed);
			heff[idx] = he;
			// AC-0292: the per-column CAVE BIOME table — one entry per
			// 8-block y-LEVEL (48 levels; the fill + drip paths index
			// bio[y >> 3] up to level 47, so the table must cover the
			// full height). Cost route: only the 16 levels touching a
			// biome band read the field (the band check skips the rest),
			// not a per-cell read. One biome per position (the value
			// mapping), gated by the vanilla y-bands at the LEVEL (a
			// level touching the band's edge counts — the <= 7-block edge
			// bleed is the documented granularity; the y=0 row is bedrock
			// anyway).
			uint8_t bio[48] = {0};
			if (!skip) {
				for (int L = 0; L < 48; L++) {
					int yb = L * 8;
					int yt = yb + 7;
					bool dd_ok = yt >= DD_Y_LO && yb <= DD_Y_HI;
					bool dr_ok = yt >= DRIP_Y_LO && yb <= DRIP_Y_HI;
					bool lu_ok = yt >= LUSH_Y_LO && yb <= LUSH_Y_HI;
					if (!dd_ok && !dr_ok && !lu_ok)
						continue;
					double v = tril_c(f_biome, gx, (double)(yb + 4) / ystep_cave, gz);
					if (v < BIOME_DD_V)
						bio[L] = dd_ok ? 1 : 0;
					else if (v < BIOME_DRIP_V)
						bio[L] = dr_ok ? 2 : 0;
					else
						bio[L] = lu_ok ? 3 : 0;
				}
			}
			long long t_fill = now_us();

			// AC-0237: the emit loop is bounded to the generated slabs —
			// every ungenerated cell stays the flat-array 0 (the null-slab
			// / absent-section encoding). The bedrock special case
			// (y == 0) only applies when slab 0 is generated.
			for (int ysi = 0; ysi < nsl; ysi++) {
				if (!slab_kept(ysi))
					continue;
				for (int y = ysi * 16; y < ysi * 16 + 16 && y < hmax; y++) {
				uint8_t cell = 0;
				if (y < BEDROCK_BAND) {
					// AC-0292: the bedrock band (vanilla above_bottom 0..5;
					// the ticket's "bedrock -64..-59" — the full band keeps
					// the fill/skip/far-emit/ring paths in lockstep).
					cell = B_BEDROCK;
				} else {
					bool solid = skip ? (y <= he) : (solidf[y] != 0);
					// AC-0342: the aquifer gate reads the PRE-CARVE heightmap H,
					// not the post-carve effective surface he — the fluid
					// decision is made BEFORE the carve, from pre-carve inputs
					// only (the vanilla ordering). The inverted `he < sea` gate
					// let the carve feed back into the fluid: a cave/tunnel
					// mouth that removed a column's top moved he below SEA and
					// filled the whole opening to y = SEA on land (a pool at
					// water height in the middle of dry terrain), and a
					// fully-caved column (he = 0) became a 126-block water
					// column. With H < sea: ocean columns fill he+1..SEA
					// exactly as before (he <= H < SEA always held — the
					// AC-0347 P2 structural fact — so a submarine cave open to
					// the sea still floods to sea level: the fill START stays
					// he+1), and land columns (H >= SEA) stay dry whatever the
					// caves below do (air above the floor; the y < 8 lava
					// pockets keep their Y-only rule, which was already
					// correct). The skip path (he = H) and the far path already
					// obeyed this rule — the full path was the odd one out, so
					// the three paths now agree and a demoted-then-promoted
					// column can no longer change its water.
					if (y >= he + 1 && y <= sea && H < sea) {
						cell = B_WATER; // aquifer: ocean fill up to Sea 126, gated on pre-carve H
					} else if (y == he) {
						if (he < DEEPSLATE_Y) {
							// AC-0292: below vanilla y=0 no biome top fires
							// (they are all y_above 0) — the top falls to the
							// stone rule = deepslate. gen_far's top formula
							// agrees (the farab 4a identity).
							cell = B_DEEPSLATE;
							g_p4_deepslate.fetch_add(1, std::memory_order_relaxed);
						} else {
							// Surface block (biome top; sand on shallow non-desert).
							cell = B_GRASS;
							if (bm == 1)
								cell = B_SAND;
							else if (bm == 0)
								cell = B_SNOW_GRASS;
							if (he <= sea + 1 && bm != 1)
								cell = B_SAND;
						}
					} else if (y >= he - 3 && solid) {
						cell = (bm == 1) ? B_SAND : B_DIRT;
					} else if (!solid) {
						if (aq_p == nullptr) {
							// The skip path: no aquifer (the lazy path keeps its
							// old behavior — the skip/far payloads stay bit-exact
							// by construction, AC-0291).
							cell = (y < 8) ? B_LAVA : 0;
						} else {
							// AC-0291: the VORONOI AQUIFER (full path only — the
							// model + the documented adaptations in the section
							// above). The AC-0342 surface rule above already owns
							// [he+1, SEA] on ocean columns; here the aquifer
							// decides the rest — the per-cell local water tables
							// (perched mountain lakes, lava pools), the barrier
							// stone rims, and the scheduled-flow marks.
							//
							// Sky-block fast path: a block ABOVE the topmost
							// solid (barrier stone requires y < he), ABOVE
							// every cell's fluid table (fluid requires
							// y <= level <= max_fluid) and ABOVE the lava layer
							// is provably inert for the aquifer — the 4-nearest
							// search is skipped (measured: 84% of the air blocks
							// in the census window).
							if (y > he && y > aq_p->max_fluid && y > AQU_LAVA_SURF) {
								cell = 0;
							} else {
								AquOut aout;
								aqu_block(x, y, z, he, cx, cz, *aq_p, seed, sea, aout);
								if (aout.block == 0 && y <= AQU_LAVA_SURF) {
									// The global lava layer (vanilla -54 + 64 =
									// 10, "exists regardless of aquifers") —
									// replaces the old y < 8 deep-pocket rule
									// on the full path.
									cell = B_LAVA;
									g_aqu_lava_layer.fetch_add(1, std::memory_order_relaxed);
								} else {
									cell = aout.block;
								}
								if (p_fl != nullptr && aout.fl != 0)
									(*p_fl)[(size_t)(y << 8) | base] = aout.fl;
							}
						}
					} else {
						cell = stone_ore(x, y, z, gx, gz);
						// AC-0292: the CAVE BIOME rock rules (full path
						// only — the level's biome, one hash where it
						// matches; the dripstone biome's features live in
						// the post-carve drip pass below).
						if (!skip) {
							int bb = bio[y >> 3];
							if (bb == 1 && (cell == B_STONE || cell == B_DEEPSLATE)
									&& hash3i(x, y, z, seed + 327) < 0.10) {
								cell = B_SCULK;
								g_p4_sculk.fetch_add(1, std::memory_order_relaxed);
							} else if (bb == 3 && (cell == B_STONE || cell == B_DEEPSLATE)
									&& hash3i(x, y, z, seed + 328) < 0.06) {
								cell = B_MOSS;
								g_p4_moss.fetch_add(1, std::memory_order_relaxed);
							}
						}
					}
				}
					flat[(size_t)(y << 8) | base] = cell;
				}
			}
			g_t_fill_us.fetch_add(now_us() - t_fill, std::memory_order_relaxed);

			// AC-0290: the carver pass (post-fill, pre-veg) — the cut-
			// through + the re-skin + heff updated to the carved surface
			// (veg plants on the lip, not the pre-carve top). The skip
			// paths never carve (the far/skip payloads stay bit-exact).
			long long t_carve = now_us();
			if (!skip)
				heff[idx] = carver_carve_column(flat, lx, lz, x, z, he, sea, bm, *carves_p, hmax, p_keep);
			g_t_carve_us.fetch_add(now_us() - t_carve, std::memory_order_relaxed);

			// AC-0292: the DRIPSTONE CAVES pass (full path only, post-carve
			// — the carver's new air runs get speleothems too). Walks the
			// column's air/water runs: a run with a solid CEILING in the
			// dripstone biome grows a STALACTITE (2-6 blocks, 35% of the
			// eligible runs); a run with a solid FLOOR grows a STALAGMITE
			// (the floor's level must be dripstone — the floor must be rock,
			// not water/lava); a pure-WATER run over a solid floor in a
			// pool-hash column becomes a CLAY POOL (the bottom 1-3 water
			// cells -> clay — a block swap ONLY: the water table level and
			// the fl marks are never touched, the AC-0291 aquifer contract).
			// Ungenerated slabs break the runs (their cells are unknown).
			long long t_drip = now_us();
			if (!skip) {
				int y = 1;
				while (y < hmax) {
					if (!slab_kept(y >> 4)) {
						y = ((y >> 4) + 1) * 16;
						if (y > hmax)
							break;
						continue;
					}
					uint8_t c0 = flat[(size_t)(y << 8) | base];
					if (c0 != 0 && c0 != B_WATER) {
						y++;
						continue;
					}
					int a = y;
					while (y < hmax && slab_kept(y >> 4)) {
						uint8_t cc = flat[(size_t)(y << 8) | base];
						if (cc == 0 || cc == B_WATER)
							y++;
						else
							break;
					}
					int b = y - 1;
					int len = b - a + 1;
					int up = a - 1;
					int dn = b + 1;
					bool ceil_solid = up >= 0 && flat[(size_t)(up << 8) | base] != 0
							&& flat[(size_t)(up << 8) | base] != B_WATER
							&& flat[(size_t)(up << 8) | base] != B_LAVA;
					bool floor_solid = dn < hmax && slab_kept(dn >> 4)
							&& flat[(size_t)(dn << 8) | base] != 0
							&& flat[(size_t)(dn << 8) | base] != B_WATER
							&& flat[(size_t)(dn << 8) | base] != B_LAVA;
					// Stalactite — from the ceiling (its level must be drip).
					if (ceil_solid && bio[up >> 3] == 2
							&& hash3i(x, a, z, seed + 330) < 0.35) {
						int h = 2 + (int)(hash2i(x, z, seed + 332) * 5.0); // 2..6
						if (h > len)
							h = len;
						for (int yy = a; yy < a + h; yy++) {
							if (flat[(size_t)(yy << 8) | base] == 0) {
								flat[(size_t)(yy << 8) | base] = B_DRIPSTONE;
								g_p4_dripstone.fetch_add(1, std::memory_order_relaxed);
							}
						}
					}
					// Stalagmite — from the floor (its level must be drip).
					if (floor_solid && bio[dn >> 3] == 2
							&& hash3i(x, b, z, seed + 331) < 0.35) {
						int h = 2 + (int)(hash2i(x, z, seed + 335) * 5.0); // 2..6
						if (h > len)
							h = len;
						for (int yy = b - h + 1; yy <= b; yy++) {
							if (flat[(size_t)(yy << 8) | base] == 0) {
								flat[(size_t)(yy << 8) | base] = B_DRIPSTONE;
								g_p4_dripstone.fetch_add(1, std::memory_order_relaxed);
							}
						}
					}
					// Clay pool — the pure-water run over a solid floor.
					if (floor_solid && c0 == B_WATER && bio[dn >> 3] == 2
							&& hash2i(x, z, seed + 329) < 0.06) {
						bool all_water = true;
						for (int yy = a; yy <= b; yy++) {
							if (flat[(size_t)(yy << 8) | base] != B_WATER) {
								all_water = false;
								break;
							}
						}
						if (all_water) {
							int d = 1 + (hash2i(x, z, seed + 334) < 0.5)
									+ (hash2i(x, z, seed + 336) < 0.3); // 1..3
							if (d > len)
								d = len;
							for (int yy = b - d + 1; yy <= b; yy++) {
								if (flat[(size_t)(yy << 8) | base] == B_WATER) {
									flat[(size_t)(yy << 8) | base] = B_CLAY;
									g_p4_clay.fetch_add(1, std::memory_order_relaxed);
								}
							}
						}
					}
				}
			}
			g_t_drip_us.fetch_add(now_us() - t_drip, std::memory_order_relaxed);
		}
	}

	long long t_veg = now_us();
	// Trees: 20x20 neighborhood (old loop: bx-2 .. bx+17), same hash logic,
	// base = the effective surface (inside) / computed from the one density
	// field (2-ring margin).
	for (int tz = bz - 2; tz < bz + 18; tz++) {
		for (int tx = bx - 2; tx < bx + 18; tx++) {
			double hv = hash2i(tx, tz, seed + 55);
			if (hv >= 0.14)
				continue;
			int glx = tx - bx;
			int glz = tz - bz;
			int H2;
			if (glx >= 0 && glx < 16 && glz >= 0 && glz < 16)
				H2 = heights[glz * 16 + glx];
			else
				H2 = surface_h(tx, tz, f_sc, f_sh, f_sr, ystep, bx, bz);
			if (H2 <= sea + 1)
				continue;
			double tv = fbm2((double)tx / 260.0 + 900.0, (double)tz / 260.0 + 900.0, seed + 21, 3) * 2.0 - 1.0;
			double mv = fbm2((double)tx / 260.0 + 1700.0, (double)tz / 260.0 + 1700.0, seed + 33, 3) * 2.0 - 1.0;
			bool snow = tv < -0.25;
			bool desert = tv > 0.35 && mv < 0.1;
			bool forest = mv > 0.25;
			double dens = 0.0;
			if (forest)
				dens = 0.14;
			else if (snow || (!desert && !forest))
				dens = 0.02; // plains or snow
			if (hv >= dens)
				continue;
			int hcol;
			if (glx >= 0 && glx < 16 && glz >= 0 && glz < 16) {
				hcol = heff[glz * 16 + glx];
			} else if (skip) {
				// AC-0216: the lazy margin column = the heightmap surface
				// exactly (no cave term — the f_cheese field was not built;
				// the neighbor band is lazy too, so H2 is the shared
				// surface).
				hcol = H2;
			} else {
				// Margin column: the one density field's surface (the
				// fields' 1-cell margin covers tx,tz in [bx-4, bx+20]).
				hcol = 0;
				double gx2 = (double)glx / 4.0;
				double gz2 = (double)glz / 4.0;
				int top2 = H2 + 11;
				if (top2 > hmax - 1)
					top2 = hmax - 1;
				for (int y = top2; y >= 1; y--) {
					// AC-0347/AC-0359: the same router inputs as the
					// in-column scan (the tree base must match the full
					// column's surface — the C48 cave-lattice reads exactly
					// as there; the fields' 1-cell xz margin covers the
					// margin band on both lattices).
					double gy2 = (double)y / ystep_cave;
					double cave = tril_c(f_cheese, gx2, gy2, gz2);
					double ent = entrance_from_latt(tril_c(f_entr, gx2, gy2, gz2), (double)y);
					double lay = (H2 - y >= K_CUT)
							? tril_c(f_layer, gx2, gy2, gz2)
							: 0.0;
					// AC-0289: the same tunnel rule as the in-column scan.
					bool sv = dens_at(H2, y, cave, ent, lay) > 0.0
							&& !tunnel_air_c(f_spag, f_nood, f_gate, gx2, gy2, gz2);
					// AC-0292: the same pillar rule as the in-column scan
					// (deep branch only, the max outside the tunnel min).
					if (H2 - y >= K_CUT
							&& tril_c(f_pillar, gx2, gy2, gz2) >= PILLAR_CHOICE_TH)
						sv = true;
					if (sv) {
						hcol = y;
						break;
					}
				}
			}
			if (hcol < 1)
				continue;
			bool skip = false;
			if (glx >= 0 && glx < 16 && glz >= 0 && glz < 16) {
				int gb = flat[(size_t)(hcol << 8) | (glz << 4) | glx];
				if (gb == 0 || gb == B_WATER || gb == B_LAVA)
					skip = true;
				else if (!solid_ids[gb])
					skip = true;
			}
			if (skip)
				continue;
			int tth = 4 + (int)(hash2i(tx, tz, seed + 66) * 3.0);
			for (int dy = 1; dy <= tth; dy++) {
				// _putc (log): only empty cells, inside the chunk, and
				// (AC-0237) inside the generated slab range.
				int wx = tx, wz = tz, wy = hcol + dy;
				int ax = wx - bx, az = wz - bz;
				if (ax >= 0 && ax < 16 && az >= 0 && az < 16 && wy >= 1 && wy < hmax && slab_kept(wy >> 4)) {
					int i = (wy << 8) | (az << 4) | ax;
					if (flat[i] == 0)
						flat[i] = B_LOG;
				}
			}
			for (int ly = tth - 1; ly <= tth + 2; ly++) {
				int rad = (ly >= tth + 1) ? 1 : 2;
				for (int dx = -rad; dx <= rad; dx++) {
					for (int dz = -rad; dz <= rad; dz++) {
						bool sk = false;
						if (rad == 2 && iabs(dx) == 2 && iabs(dz) == 2)
							sk = true;
						if (ly == tth + 2 && iabs(dx) == 1 && iabs(dz) == 1)
							sk = true;
						if (sk)
							continue;
						int wy = hcol + ly;
						int ax = tx + dx - bx;
						int az = tz + dz - bz;
						if (ax >= 0 && ax < 16 && az >= 0 && az < 16 && wy >= 1 && wy < hmax && slab_kept(wy >> 4)) {
							int i = (wy << 8) | (az << 4) | ax;
							if (flat[i] == 0)
								flat[i] = B_LEAVES;
						}
					}
				}
			}
		}
	}

	// Flowers: grass tops, exact old hash gates (on the effective surface).
	for (int lz = 0; lz < 16; lz++) {
		for (int lx = 0; lx < 16; lx++) {
			int idx = lz * 16 + lx;
			int fh = heff[idx];
			if (fh > sea && fh < hmax - 2) {
				int idxf = (fh << 8) | (lz << 4) | lx;
				// AC-0237: the flower cell (fh + 1) must be in a
				// generated slab (the grass check alone cannot guard
				// the slab above).
				if (!slab_kept((fh + 1) >> 4))
					continue;
				if (flat[idxf] == B_GRASS && hash2i(bx + lx, bz + lz, seed + 777) < 0.02) {
					flat[idxf + 256] = hash2i(bx + lx, bz + lz, seed + 778) < 0.5 ? B_ROSE : B_DANDELION;
				}
			}
		}
	}
	g_t_veg_us.fetch_add(now_us() - t_veg, std::memory_order_relaxed);
	(void)nsl;
	return flat;
}

// AC-0283 P3: the column's HEIGHTMAP — the 256 terrain-top heights
// (heights[lz * 16 + lx], the surface_h of gen_flat's heights pass) as
// bytes. The HALO band (taxi > sim_dist) never seeds or floods (AC-0283
// P3): its draw light is the heightmap sky (15 strictly above the terrain
// top per (x,z), 0 at or below), read from this at dispatch time on the
// main thread. Only the three SURFACE fields are built (the cave/ore
// fields are never read) — the heights pass of gen_flat, ~33us, with no
// density scan, no fill, no palettize.
static std::vector<uint8_t> column_heights(int cx, int cz, int64_t seed, int hmax) {
	int bx = cx * 16;
	int bz = cz * 16;
	double ystep = (double)hmax / GY_CELLS;
	Field f_sc, f_sh, f_sr;
	build_field(f_sc, bx, bz, ystep, seed, 220.0, SURF_YSCALE, 220.0, 0.0, 0.0, 0.0);
	build_field(f_sh, bx, bz, ystep, seed + 7, 70.0, SURF_YSCALE, 70.0, 333.0, 0.0, 333.0);
	build_field(f_sr, bx, bz, ystep, seed + 13, 300.0, SURF_YSCALE, 300.0, 500.0, 0.0, 500.0);
	std::vector<uint8_t> out(256);
	for (int lz = 0; lz < 16; lz++) {
		for (int lx = 0; lx < 16; lx++) {
			int H = surface_h(bx + lx, bz + lz, f_sc, f_sh, f_sr, ystep, bx, bz);
			out[(size_t)lz * 16 + lx] = (uint8_t)clampi(H, 0, hmax - 1);
		}
	}
	return out;
}

// ---------------------------------------------------------------------------
// Palettize (identical to ChunkIO.palettize_flat / chunk_io.cpp encode).
// ---------------------------------------------------------------------------

static int slab_bits_for(int n) {
	int b = 0;
	while ((1 << b) < n)
		b++;
	return b;
}

static PackedByteArray bitpack(const uint8_t *vals, int n, int bits) {
	std::vector<uint8_t> out((n * bits + 7) / 8, 0);
	uint32_t cur = 0;
	int bitpos = 0;
	int bytepos = 0;
	for (int i = 0; i < n; i++) {
		cur = (cur << bits) | vals[i];
		bitpos += bits;
		while (bitpos >= 8) {
			bitpos -= 8;
			out[bytepos] = (cur >> bitpos) & 255;
			bytepos++;
			cur &= (1u << bitpos) - 1;
		}
	}
	if (bitpos > 0)
		out[bytepos] = cur & ((1u << bitpos) - 1);
	PackedByteArray pba;
	pba.resize((int)out.size());
	if (!out.empty())
		std::memcpy(pba.ptrw(), out.data(), out.size());
	return pba;
}

static Array palettize_slabs(const std::vector<uint8_t> &flat, int hmax) {
	long long t_pallet = now_us();
	int nsl = hmax / 16;
	Array out;
	out.resize(nsl);
	int seen[256];
	for (int si = 0; si < nsl; si++) {
		int base = si * 4096;
		for (int i = 0; i < 256; i++)
			seen[i] = -1;
		std::vector<uint8_t> order;
		int nz = 0;
		// AC-0253: the solid/air bitset (1 bit/cell) — built in the SAME
		// nz scan (all 4096 ids are in hand here) and rides the slab entry
		// as the optional "bs" field (the meshing fast path).
		// AC-0258: + the clutter count "nc" (same scan) — the avg-LOD
		// clutter-as-air rule, identical to chunk_io's palettize_flat.
		int nc = 0;
		std::vector<uint8_t> bs(awecommon::S3B, 0);
		for (int i = 0; i < 4096; i++) {
			uint8_t v = flat[base + i];
			if (seen[v] < 0) {
				seen[v] = (int)order.size();
				order.push_back(v);
			}
			if (v != 0) {
				nz++;
				awecommon::slab_bit_set(bs.data(), i);
				if (awecommon::is_clutter_block(v))
					nc++;
			}
		}
		int nn = (int)order.size();
		if (nz == 0) {
			out[si] = Variant(); // null slab
		} else if (nn == 1) {
			Dictionary d;
			d["n"] = 1;
			d["b"] = 0;
			PackedByteArray p;
			p.resize(1);
			p[0] = order[0];
			d["p"] = p;
			d["i"] = PackedByteArray();
			d["nz"] = nz;
			d["nc"] = nc;
			d["bs"] = awecommon::pba_from(bs);
			out[si] = d;
		} else if (nn <= 16) {
			std::vector<uint8_t> pvals = order;
			std::sort(pvals.begin(), pvals.end());
			int rank[256];
			for (int j = 0; j < nn; j++)
				rank[pvals[j]] = j;
			std::vector<uint8_t> vals(4096);
			for (int i = 0; i < 4096; i++)
				vals[i] = (uint8_t)rank[flat[base + i]];
			int bits = slab_bits_for(nn);
			Dictionary d;
			d["n"] = nn;
			d["b"] = bits;
			PackedByteArray p;
			p.resize(nn);
			for (int j = 0; j < nn; j++)
				p[j] = pvals[j];
			d["p"] = p;
			d["i"] = bitpack(vals.data(), 4096, bits);
			d["nz"] = nz;
			d["nc"] = nc;
			d["bs"] = awecommon::pba_from(bs);
			out[si] = d;
		} else {
			Dictionary d;
			d["n"] = 0;
			d["b"] = 8;
			d["p"] = PackedByteArray();
			PackedByteArray iarr;
			iarr.resize(4096);
			std::memcpy(iarr.ptrw(), flat.data() + base, 4096);
			d["i"] = iarr;
			d["nz"] = nz;
			d["nc"] = nc;
			d["bs"] = awecommon::pba_from(bs);
			out[si] = d;
		}
	}
	g_t_pallet_us.fetch_add(now_us() - t_pallet, std::memory_order_relaxed);
	return out;
}

// ---------------------------------------------------------------------------
// Registered class.
// ---------------------------------------------------------------------------

class AweGen : public RefCounted {
	GDCLASS(AweGen, RefCounted)

public:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("fbm2", "x", "z", "s", "oct"), &AweGen::fbm2, DEFVAL(4));
		ClassDB::bind_method(D_METHOD("fbm3", "x", "y", "z", "s", "oct"), &AweGen::fbm3, DEFVAL(3));
		// AC-0347 P1: the vanilla octave machine (amplitude list +
		// firstOctave, normalized — the genprobe sampler bit-exactness gate).
		ClassDB::bind_method(D_METHOD("vn3", "x", "y", "z", "s", "first_oct", "amps"), &AweGen::vn3);
		ClassDB::bind_method(D_METHOD("vnoise2", "x", "z", "s"), &AweGen::vnoise2);
		ClassDB::bind_method(D_METHOD("vnoise3", "x", "y", "z", "s"), &AweGen::vnoise3);
		ClassDB::bind_method(D_METHOD("hash2i", "x", "z", "s"), &AweGen::hash2i);
		ClassDB::bind_method(D_METHOD("hash3i", "x", "y", "z", "s"), &AweGen::hash3i);
		ClassDB::bind_method(D_METHOD("fade", "t"), &AweGen::fade);
		ClassDB::bind_method(D_METHOD("density_cave", "x", "y", "z", "s"), &AweGen::density_cave);
		// AC-0347 P2: the router's dense sources + the router itself (the
		// genprobe layer/entrance/dens lockstep blocks).
		ClassDB::bind_method(D_METHOD("density_layer", "x", "y", "z", "s"), &AweGen::density_layer);
		ClassDB::bind_method(D_METHOD("density_entrance", "x", "y", "z", "s"), &AweGen::density_entrance);
		ClassDB::bind_method(D_METHOD("dens_at", "H", "y", "cave", "ent", "layer"), &AweGen::dens_at);
		// AC-0289: the tunnel field dense sources + predicate (the genprobe
		// tunnel lockstep — see density_spag et al. above).
		ClassDB::bind_method(D_METHOD("density_spag", "x", "y", "z", "s"), &AweGen::density_spag);
		ClassDB::bind_method(D_METHOD("density_nood", "x", "y", "z", "s"), &AweGen::density_nood);
		ClassDB::bind_method(D_METHOD("density_gate", "x", "y", "z", "s"), &AweGen::density_gate);
		ClassDB::bind_method(D_METHOD("tunnel_air", "x", "y", "z", "s"), &AweGen::tunnel_air);
		// AC-0291: the aquifer dense sources (the vanilla noise instances
		// AS-IS — the genprobe aquifer lockstep block mirrors them in
		// GDScript) + the cumulative census + the per-chunk cell census.
		ClassDB::bind_method(D_METHOD("aquifer_floodedness", "x", "y", "z", "s"), &AweGen::aquifer_floodedness);
		ClassDB::bind_method(D_METHOD("aquifer_spread", "x", "y", "z", "s"), &AweGen::aquifer_spread);
		ClassDB::bind_method(D_METHOD("aquifer_barrier", "x", "y", "z", "s"), &AweGen::aquifer_barrier);
		ClassDB::bind_method(D_METHOD("aquifer_lava", "x", "y", "z", "s"), &AweGen::aquifer_lava);
		ClassDB::bind_method(D_METHOD("aquifer_erosion", "x", "z", "s"), &AweGen::aquifer_erosion);
		ClassDB::bind_method(D_METHOD("aquifer_stats"), &AweGen::aquifer_stats);
		// AC-0292: the P4 dense sources (the genprobe lockstep mirrors each
		// in GDScript) + the cumulative P4 census.
		ClassDB::bind_method(D_METHOD("density_pillar", "x", "y", "z", "s"), &AweGen::density_pillar);
		ClassDB::bind_method(D_METHOD("density_vein", "x", "y", "z", "s"), &AweGen::density_vein);
		ClassDB::bind_method(D_METHOD("density_biome", "x", "y", "z", "s"), &AweGen::density_biome);
		ClassDB::bind_method(D_METHOD("p4_stats"), &AweGen::p4_stats);
		// AC-0216: the optional 6th arg `skip` (default 0 = the pre-AC-0216
		// full density field, bit-for-bit) — the lazy offscreen-interior
		// skip (see the file header).
		ClassDB::bind_method(D_METHOD("generate_flat", "cx", "cz", "s", "h", "sea", "skip", "keep"), &AweGen::generate_flat, DEFVAL(0), DEFVAL(PackedByteArray()));
		ClassDB::bind_method(D_METHOD("generate_slabs", "cx", "cz", "s", "h", "sea", "skip", "keep"), &AweGen::generate_slabs, DEFVAL(0), DEFVAL(PackedByteArray()));
		ClassDB::bind_method(D_METHOD("generate_resl", "cx", "cz", "s", "h", "sea", "skip", "keep"), &AweGen::generate_resl, DEFVAL(0), DEFVAL(PackedByteArray()));
		// AC-0283 P3: the halo band's heightmap sky source (the heights
		// pass only — see column_heights above).
		ClassDB::bind_method(D_METHOD("column_heights", "cx", "cz", "s", "h"), &AweGen::column_heights);
		// AC-0284b: the far (h-only) column — the 1024-byte far payload
		// (256 H u16 LE + 256 biome + 256 top-block id; see gen_far).
		// generate_resl with skip == 2 returns it as resl[2] too.
		ClassDB::bind_method(D_METHOD("generate_far", "cx", "cz", "s", "h", "sea"), &AweGen::generate_far);
		// AC-0284b: the u16 LE heightmap (512 bytes — the legacy u8
		// column_heights wraps above 255; the farab H battery compares
		// the far payload against THIS).
		ClassDB::bind_method(D_METHOD("column_heights16", "cx", "cz", "s", "h"), &AweGen::column_heights16);
		// AC-0284b: the far emitter's DEEP-COLOR precompute — the exact
		// stone_ore chain (the fill lambda) per slab cell (see the
		// method). Pass it to AweMesh.h_avg_emit for the slabs with deep
		// cells (si <= 3 — the ore bands end at y = 60).
		ClassDB::bind_method(D_METHOD("stone_ore_slab", "cx", "cz", "s", "h", "si"), &AweGen::stone_ore_slab);
		// AC-0284b: the column's tree cells (the far emitter's solid-set
		// extension — see gen_veg_cells).
		ClassDB::bind_method(D_METHOD("veg_cells", "cx", "cz", "s", "h", "sea"), &AweGen::veg_cells);
		ClassDB::bind_method(D_METHOD("skip_chunks_total"), &AweGen::skip_chunks_total);
		ClassDB::bind_method(D_METHOD("skip_cols_total"), &AweGen::skip_cols_total);
		ClassDB::bind_method(D_METHOD("reset_skip_stats"), &AweGen::reset_skip_stats);
		ClassDB::bind_method(D_METHOD("gen_timing"), &AweGen::gen_timing);
		ClassDB::bind_method(D_METHOD("reset_gen_timing"), &AweGen::reset_gen_timing);
	}

	Dictionary gen_timing() const {
		Dictionary d;
		d["field_us"] = (int64_t)g_t_field_us.load(std::memory_order_relaxed);
		d["heights_us"] = (int64_t)g_t_heights_us.load(std::memory_order_relaxed);
		d["vegcells_us"] = (int64_t)g_t_vegcells_us.load(std::memory_order_relaxed);
		d["scan_us"] = (int64_t)g_t_scan_us.load(std::memory_order_relaxed);
		d["fill_us"] = (int64_t)g_t_fill_us.load(std::memory_order_relaxed);
		d["veg_us"] = (int64_t)g_t_veg_us.load(std::memory_order_relaxed);
		d["pallet_us"] = (int64_t)g_t_pallet_us.load(std::memory_order_relaxed);
		d["carve_us"] = (int64_t)g_t_carve_us.load(std::memory_order_relaxed); // AC-0290
		d["aquifer_us"] = (int64_t)g_t_aquifer_us.load(std::memory_order_relaxed); // AC-0291
		d["drip_us"] = (int64_t)g_t_drip_us.load(std::memory_order_relaxed); // AC-0292: the drip pass
		d["cols_full"] = (int64_t)g_t_cols_full.load(std::memory_order_relaxed);
		d["cols_skip"] = (int64_t)g_t_cols_skip.load(std::memory_order_relaxed);
		d["cols_far"] = (int64_t)g_t_cols_far.load(std::memory_order_relaxed);
		d["far_us"] = (int64_t)g_t_far_us.load(std::memory_order_relaxed);
		return d;
	}

	void reset_gen_timing() {
		g_t_field_us.store(0, std::memory_order_relaxed);
		g_t_heights_us.store(0, std::memory_order_relaxed);
		g_t_scan_us.store(0, std::memory_order_relaxed);
		g_t_fill_us.store(0, std::memory_order_relaxed);
		g_t_carve_us.store(0, std::memory_order_relaxed); // AC-0290
		g_t_aquifer_us.store(0, std::memory_order_relaxed); // AC-0291
		g_aqu_water.store(0, std::memory_order_relaxed);
		g_aqu_lava.store(0, std::memory_order_relaxed);
		g_aqu_stones.store(0, std::memory_order_relaxed);
		g_aqu_lava_layer.store(0, std::memory_order_relaxed);
		g_aqu_fl8.store(0, std::memory_order_relaxed);
		// AC-0292: the P4 census + the drip stage.
		g_p4_pillar.store(0, std::memory_order_relaxed);
		g_p4_pillar_void.store(0, std::memory_order_relaxed);
		g_p4_ore_vein.store(0, std::memory_order_relaxed);
		g_p4_deepslate.store(0, std::memory_order_relaxed);
		g_p4_dripstone.store(0, std::memory_order_relaxed);
		g_p4_clay.store(0, std::memory_order_relaxed);
		g_p4_sculk.store(0, std::memory_order_relaxed);
		g_p4_moss.store(0, std::memory_order_relaxed);
		g_t_drip_us.store(0, std::memory_order_relaxed);
		g_t_veg_us.store(0, std::memory_order_relaxed);
		g_t_pallet_us.store(0, std::memory_order_relaxed);
		g_t_cols_full.store(0, std::memory_order_relaxed);
		g_t_cols_skip.store(0, std::memory_order_relaxed);
		g_t_cols_far.store(0, std::memory_order_relaxed);
		g_t_far_us.store(0, std::memory_order_relaxed);
	}

	// Noise probe surface (bit-exact AweNoise port).
	double fbm2(double p_x, double p_z, int p_s, int p_oct) const {
		return awegen::fbm2(p_x, p_z, p_s, p_oct);
	}
	double fbm3(double p_x, double p_y, double p_z, int p_s, int p_oct) const {
		return awegen::fbm3(p_x, p_y, p_z, p_s, p_oct);
	}
	double vnoise2(double p_x, double p_z, int p_s) const {
		return awegen::vnoise2(p_x, p_z, p_s);
	}
	double vnoise3(double p_x, double p_y, double p_z, int p_s) const {
		return awegen::vnoise3(p_x, p_y, p_z, p_s);
	}
	double hash2i(int p_x, int p_z, int p_s) const {
		return awegen::hash2i(p_x, p_z, p_s);
	}
	double hash3i(int p_x, int p_y, int p_z, int p_s) const {
		return awegen::hash3i(p_x, p_y, p_z, p_s);
	}
	double fade(double p_t) const {
		return awegen::fade(p_t);
	}
	// The cave-density noise at a point (the coarse field's source function).
	// AC-0347 P1: the cheese field = vanilla's cave_cheese as-is — the vn3
	// octave machine at the CHEESE_* constants above (the scale MULTIPLIES
	// the block coordinate: xz 1.0 / y 0.6667; firstOctave -8; the 9-amp
	// list; the seed+301 slot). The genprobe arm mirrors this exact
	// expression in GDScript (the lockstep contract).
	double density_cave(double p_x, double p_y, double p_z, int p_s) const {
		return awegen::vn3(p_x * CHEESE_XZ_SCALE, p_y * CHEESE_Y_SCALE, p_z * CHEESE_XZ_SCALE,
				p_s + 301, CHEESE_FIRST_OCT, CHEESE_AMPS, CHEESE_AMPS_N);
	}
	// AC-0347 P1: the vanilla NormalNoise octave machine (the bit-exact
	// mirror of AweNoise.vn3 — the genprobe sampler gate).
	double vn3(double p_x, double p_y, double p_z, int p_s, int p_first_oct, const Array &p_amps) const {
		int n = (int)p_amps.size();
		if (n > 16)
			n = 16;
		double amps[16];
		for (int i = 0; i < n; i++)
			amps[i] = (double)p_amps[i];
		return awegen::vn3(p_x, p_y, p_z, p_s, p_first_oct, amps, n);
	}
	// AC-0289: the tunnel field dense sources + the tunnel air predicate
	// (world coordinates). The genprobe arm mirrors these exact expressions
	// in GDScript (the tunnel lockstep contract). The production path
	// samples the COARSE 4x8x4 fields trilinearly — the documented grid
	// approximation of these dense sources (the same as every other field).
	double density_spag(double p_x, double p_y, double p_z, int p_s) const {
		return awegen::fbm3(p_x / SPAG_XZ, p_y / 10.0, p_z / SPAG_XZ, p_s + 303, 2);
	}
	double density_nood(double p_x, double p_y, double p_z, int p_s) const {
		return awegen::fbm3(p_x / NOOD_XZ, p_y / 10.0, p_z / NOOD_XZ, p_s + 304, 2);
	}
	double density_gate(double p_x, double p_y, double p_z, int p_s) const {
		return awegen::fbm3(p_x / GATE_XZ, p_y / 10.0, p_z / GATE_XZ, p_s + 305, 2);
	}
	double tunnel_air(double p_x, double p_y, double p_z, int p_s) const {
		double w = awegen::gate_weight(
				awegen::fbm3(p_x / GATE_XZ, p_y / 10.0, p_z / GATE_XZ, p_s + 305, 2));
		if (w <= 0.0)
			return 0.0;
		double sp = awegen::fbm3(p_x / SPAG_XZ, p_y / 10.0, p_z / SPAG_XZ, p_s + 303, 2) - 0.5;
		if (sp < 0.0)
			sp = -sp;
		if (sp < SPAG_TH * w)
			return 1.0;
		double nd = awegen::fbm3(p_x / NOOD_XZ, p_y / 10.0, p_z / NOOD_XZ, p_s + 304, 2) - 0.5;
		if (nd < 0.0)
			nd = -nd;
		if (nd < NOOD_TH * w)
			return 1.0;
		return 0.0;
	}
	// AC-0347 P2: the router's dense sources + the router itself — the
	// genprobe layer/entrance/dens lockstep blocks mirror these EXACT
	// expressions in GDScript (op-order identical, f64).
	double density_layer(double p_x, double p_y, double p_z, int p_s) const {
		return awegen::layer_cave(p_x, p_y, p_z, p_s);
	}
	double density_entrance(double p_x, double p_y, double p_z, int p_s) const {
		return awegen::entrance_cave(p_x, p_y, p_z, p_s);
	}
	double dens_at(double p_H, double p_y, double p_cave, double p_ent, double p_layer) const {
		return awegen::dens_at((int)p_H, (int)p_y, p_cave, p_ent, p_layer);
	}

	// AC-0291: the aquifer dense sources (the vanilla noise instances
	// AS-IS — the genprobe aquifer lockstep mirrors each in GDScript).
	double aquifer_floodedness(double x, double y, double z, int s) const {
		return awegen::aqu_floodedness(x, y, z, (int64_t)s);
	}
	double aquifer_spread(double x, double y, double z, int s) const {
		return awegen::aqu_spread(x, y, z, (int64_t)s);
	}
	double aquifer_barrier(double x, double y, double z, int s) const {
		return awegen::aqu_barrier(x, y, z, (int64_t)s);
	}
	double aquifer_lava(double x, double y, double z, int s) const {
		return awegen::aqu_lava(x, y, z, (int64_t)s);
	}
	double aquifer_erosion(double x, double z, int s) const {
		return awegen::aqu_erosion(x, z, (int64_t)s);
	}

	// AC-0292: the P4 dense sources (the genprobe lockstep mirrors each in
	// GDScript): the vanilla caves/pillars expression (the three noise
	// instances + the centered-convention centering), the vein field's
	// vn3, the cave biome field's vn3.
	double density_pillar(double x, double y, double z, int s) const {
		return awegen::pillar_density(x, y, z, (int64_t)s);
	}
	double density_vein(double x, double y, double z, int s) const {
		return awegen::vein_density(x, y, z, (int64_t)s);
	}
	double density_biome(double x, double y, double z, int s) const {
		return awegen::biome_density(x, y, z, (int64_t)s);
	}

	// AC-0291: the cumulative aquifer census (the harness arm reads it;
	// process-wide like gen_timing — reset_gen_timing() zeros it).
	// AC-0291: the placed-cell census (see the counter block near the top).
	Dictionary aquifer_stats() const {
		Dictionary d;
		d["water"] = (int64_t)g_aqu_water.load(std::memory_order_relaxed);
		d["lava"] = (int64_t)g_aqu_lava.load(std::memory_order_relaxed);
		d["stones"] = (int64_t)g_aqu_stones.load(std::memory_order_relaxed);
		d["lava_layer"] = (int64_t)g_aqu_lava_layer.load(std::memory_order_relaxed);
		d["fl8"] = (int64_t)g_aqu_fl8.load(std::memory_order_relaxed);
		d["aquifer_us"] = (int64_t)g_t_aquifer_us.load(std::memory_order_relaxed);
		return d;
	}

	// AC-0292: the P4 cumulative census (the TEMP census arms read it;
	// process-wide like aquifer_stats — reset_gen_timing() zeros it).
	// pillar = the deep cells with P >= 0.03 (pillar-solid); pillar_void
	// = the subset the router+tunnel said AIR (the true void fill);
	// ore_vein = the vein-blob ore cells; deepslate = the deepslate cells
	// placed (the y<64 chain + the 64..71 blend + the H<64 tops);
	// dripstone/clay = the drip pass's speleothem + pool cells;
	// sculk/moss = the biome rock rules.
	Dictionary p4_stats() const {
		Dictionary d;
		d["pillar"] = (int64_t)g_p4_pillar.load(std::memory_order_relaxed);
		d["pillar_void"] = (int64_t)g_p4_pillar_void.load(std::memory_order_relaxed);
		d["ore_vein"] = (int64_t)g_p4_ore_vein.load(std::memory_order_relaxed);
		d["deepslate"] = (int64_t)g_p4_deepslate.load(std::memory_order_relaxed);
		d["dripstone"] = (int64_t)g_p4_dripstone.load(std::memory_order_relaxed);
		d["clay"] = (int64_t)g_p4_clay.load(std::memory_order_relaxed);
		d["sculk"] = (int64_t)g_p4_sculk.load(std::memory_order_relaxed);
		d["moss"] = (int64_t)g_p4_moss.load(std::memory_order_relaxed);
		d["drip_us"] = (int64_t)g_t_drip_us.load(std::memory_order_relaxed);
		return d;
	}

	// AC-0216: p_skip != 0 = the lazy offscreen-interior path (the 150-pt
	// density evaluation skipped free — see the file header). Default 0.
	// AC-0237: p_keep = the 24-byte slab keep mask (slab si generated iff
	// p_keep[si] != 0); an EMPTY array = the full column, bit-identical
	// to the pre-AC-0237 output (the genhash A==B gate relies on it).
	PackedByteArray generate_flat(int p_cx, int p_cz, int p_s, int p_h, int p_sea, int p_skip, PackedByteArray p_keep) const {
		const uint8_t *keep = p_keep.size() > 0 ? (const uint8_t *)p_keep.ptr() : nullptr;
		std::vector<uint8_t> f = awegen::gen_flat(p_cx, p_cz, p_s, p_h, p_sea, p_skip, keep);
		PackedByteArray out;
		out.resize((int)f.size());
		if (!f.empty())
			std::memcpy(out.ptrw(), f.data(), f.size());
		return out;
	}

	Array generate_slabs(int p_cx, int p_cz, int p_s, int p_h, int p_sea, int p_skip, PackedByteArray p_keep) const {
		const uint8_t *keep = p_keep.size() > 0 ? (const uint8_t *)p_keep.ptr() : nullptr;
		std::vector<uint8_t> f = awegen::gen_flat(p_cx, p_cz, p_s, p_h, p_sea, p_skip, keep);
		return awegen::palettize_slabs(f, p_h);
	}

	// [data_slabs, fl_slabs] — the exact threadgen resl shape. AC-0284b:
	// skip == 2 = the FAR (h-only) column — the slabs are ALL NULL and the
	// 1024-byte far payload rides resl[2] as {h, bm, top} (the v6 codec's
	// bit-1 section replaces the slab section on disk). AC-0291: the FULL
	// path now returns the scheduled-flow fl array (fl = 8 on the aquifer
	// boundary water — the "scheduled flowing ticks" the ticket asks for;
	// the fluid tick's explicit-fl pass makes them flow: the waterfalls).
	// The skip paths keep all-null fl (no flow marks — the band-A/far
	// payloads stay bit-exact by construction).
	Array generate_resl(int p_cx, int p_cz, int p_s, int p_h, int p_sea, int p_skip, PackedByteArray p_keep) const {
		if (p_skip == 2) {
			std::vector<uint8_t> pay = awegen::gen_far(p_cx, p_cz, p_s, p_h, p_sea);
			Array resl;
			Array ds;
			ds.resize(p_h / 16); // all null — the far column holds no slabs
			resl.append(ds);
			Array fl;
			fl.resize(p_h / 16); // all null
			resl.append(fl);
			Dictionary fp;
			PackedByteArray ph;
			ph.resize(512);
			std::memcpy(ph.ptrw(), pay.data(), 512);
			PackedByteArray pb;
			pb.resize(256);
			std::memcpy(pb.ptrw(), pay.data() + 512, 256);
			PackedByteArray pt;
			pt.resize(256);
			std::memcpy(pt.ptrw(), pay.data() + 768, 256);
			fp["h"] = ph;
			fp["bm"] = pb;
			fp["top"] = pt;
			resl.append(fp);
			return resl;
		}
		const uint8_t *keep = p_keep.size() > 0 ? (const uint8_t *)p_keep.ptr() : nullptr;
		std::vector<uint8_t> ffl;
		std::vector<uint8_t> f = awegen::gen_flat(p_cx, p_cz, p_s, p_h, p_sea, p_skip, keep, &ffl);
		Array resl;
		resl.append(awegen::palettize_slabs(f, p_h));
		if (p_skip == 0) {
			resl.append(awegen::palettize_slabs(ffl, p_h)); // AC-0291: the flow marks
		} else {
			Array fl;
			fl.resize(p_h / 16); // all null (the skip paths mark no flow)
			resl.append(fl);
		}
		return resl;
	}

	// AC-0284b: the far (h-only) column's 1024-byte payload (256 H u16
	// LE + 256 biome + 256 top-block id — see gen_far above).
	PackedByteArray generate_far(int p_cx, int p_cz, int p_s, int p_h, int p_sea) const {
		std::vector<uint8_t> f = awegen::gen_far(p_cx, p_cz, p_s, p_h, p_sea);
		PackedByteArray out;
		out.resize((int)f.size());
		if (!f.empty())
			std::memcpy(out.ptrw(), f.data(), f.size());
		return out;
	}

	// AC-0284b: the column's 256 heights as u16 LE (512 bytes). The u8
	// column_heights above wraps above 255 (TERRAIN_H_MAX = 300); this is
	// the exact form the far payload stores.
	PackedByteArray column_heights16(int p_cx, int p_cz, int p_s, int p_h) const {
		int bx = p_cx * 16;
		int bz = p_cz * 16;
		double ystep = (double)p_h / GY_CELLS;
		Field f_sc, f_sh, f_sr;
		build_field(f_sc, bx, bz, ystep, p_s, 220.0, SURF_YSCALE, 220.0, 0.0, 0.0, 0.0);
		build_field(f_sh, bx, bz, ystep, p_s + 7, 70.0, SURF_YSCALE, 70.0, 333.0, 0.0, 333.0);
		build_field(f_sr, bx, bz, ystep, p_s + 13, 300.0, SURF_YSCALE, 300.0, 500.0, 0.0, 500.0);
		PackedByteArray out;
		out.resize(512);
		for (int lz = 0; lz < 16; lz++) {
			for (int lx = 0; lx < 16; lx++) {
				int H = clampi(surface_h(bx + lx, bz + lz, f_sc, f_sh, f_sr, ystep, bx, bz), 0, p_h - 1);
				int i = lz * 16 + lx;
				out[2 * i] = (uint8_t)(H & 0xFF);
				out[2 * i + 1] = (uint8_t)((H >> 8) & 0xFF);
			}
		}
		return out;
	}

	// AC-0284b: the far emitter's deep-color precompute — the EXACT
	// stone_ore chain (the fill lambda above, bit-for-bit) evaluated for
	// every cell of slab si: 4096 block ids (slab-local pos =
	// (y%16, lz, lx) — the same (y<<8)|(z<<4)|x layout as the slab). The
	// ore bands end at y = 60 (coal), so rows past that (and slabs si > 3)
	// are plain B_STONE without a field read. AweMesh.h_avg_emit colors
	// its deep sub-cells (y < H - 3) from this — the skip-fill equivalence
	// the farab A/B gate checks.
	PackedByteArray stone_ore_slab(int p_cx, int p_cz, int p_s, int p_h, int p_si) const {
		int bx = p_cx * 16;
		int bz = p_cz * 16;
		double ystep = (double)p_h / GY_CELLS;
		Field f_ore1, f_ore2, f_ore3;
		build_field(f_ore1, bx, bz, ystep, p_s + 77, 7.0, 7.0, 7.0, 0.0, 0.0, 0.0);
		build_field(f_ore2, bx, bz, ystep, p_s + 88, 9.0, 9.0, 9.0, 900.0, 0.0, 900.0);
		build_field(f_ore3, bx, bz, ystep, p_s + 99, 6.0, 6.0, 6.0, 1700.0, 0.0, 1700.0);
		std::vector<uint8_t> out(4096, B_STONE);
		for (int ly = 0; ly < 16; ly++) {
			int wy = p_si * 16 + ly;
			if (wy >= DEEPSLATE_BLEND_TOP)
				break; // AC-0292: past the deepslate blend top (was 60 — the
				// ore-band end; rows 60..71 are the deepslate transition,
				// not plain stone — the fill chain agrees cell-for-cell).
				// The veins are full-path only (the far emit stays
				// vein-free, like it is cave-free).
			for (int lz = 0; lz < 16; lz++) {
				double gz = (double)lz / 4.0;
				for (int lx = 0; lx < 16; lx++) {
					int x = bx + lx;
					int z = bz + lz;
					double gx = (double)lx / 4.0;
					// AC-0292: the rock base first (the deepslate
					// transition), the ore chain overrides — the fill's
					// stone_ore chain's exact shape (same ops, f64).
					int id = rock_base(wy, x, z, p_s);
					if (wy < 16 && tril(f_ore1, gx, (double)wy / ystep, gz) > 0.78)
						id = B_DIAMOND_ORE;
					else if (wy < 42 && tril(f_ore2, gx, (double)wy / ystep, gz) > 0.8)
						id = B_IRON_ORE;
					else if (wy < 60 && tril(f_ore3, gx, (double)wy / ystep, gz) > 0.82)
						id = B_COAL_ORE;
					else if (wy < 10 && hash3i(x, wy, z, p_s + 333) < 0.02)
						id = B_OBSIDIAN;
					out[(ly << 8) | (lz << 4) | lx] = (uint8_t)id;
				}
			}
		}
		PackedByteArray pb;
		pb.resize(4096);
		std::memcpy(pb.ptrw(), out.data(), 4096);
		return pb;
	}

	// AC-0284b: the column's TREE cells (see gen_veg_cells — the far
	// emitter adds them to the H-driven solid set so the halo's tree
	// blobs are byte-identical to the skip slab's emit).
	PackedByteArray veg_cells(int p_cx, int p_cz, int p_s, int p_h, int p_sea) const {
		std::vector<uint8_t> v = awegen::gen_veg_cells(p_cx, p_cz, p_s, p_h, p_sea);
		PackedByteArray out;
		out.resize((int)v.size());
		if (!v.empty())
			std::memcpy(out.ptrw(), v.data(), v.size());
		return out;
	}

	// AC-0283 P3: the column's 256-byte heightmap (the halo sky source).
	PackedByteArray column_heights(int p_cx, int p_cz, int p_s, int p_h) const {
		std::vector<uint8_t> h = awegen::column_heights(p_cx, p_cz, p_s, p_h);
		PackedByteArray out;
		out.resize(256);
		std::memcpy(out.ptrw(), h.data(), h.size());
		return out;
	}

	// AC-0216: cumulative lazy-skip counters (process-wide, all threads).
	int64_t skip_chunks_total() const {
		return (int64_t)g_skip_chunks_total.load(std::memory_order_relaxed);
	}
	int64_t skip_cols_total() const {
		return (int64_t)g_skip_cols_total.load(std::memory_order_relaxed);
	}
	void reset_skip_stats() {
		g_skip_chunks_total.store(0, std::memory_order_relaxed);
		g_skip_cols_total.store(0, std::memory_order_relaxed);
	}
};

void register_classes() {
	GDREGISTER_CLASS(AweGen);
}

} // namespace awegen
