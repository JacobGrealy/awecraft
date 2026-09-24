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
//            period, evaluated DENSELY in the scan: a 32-block period
//            cannot ride the 48-block lattice, AC-0344's cell-size
//            decision, not re-litigated here; seed+302 = the slot P1
//            freed) and the cheese (P1's coarse field, see below).
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

constexpr int TERRAIN_H_MAX = 300;

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
// DENSE in the scan: a 32-block period cannot ride the 48-block lattice,
// AC-0344's cell-size decision, not re-litigated here).
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

// oct: the fbm octave count per lattice point (default 2 — every pre-AC-0288
// field; AC-0288's primary cave octave passes 3).
static void build_field(Field &f, int bx, int bz, double ystep, int64_t seed,
		double fx, double fy, double fz, double ox, double oy, double oz,
		int oct = 2) {
	for (int64_t ix = -1; ix <= 5; ix++) {
		for (int64_t iy = 0; iy <= 8; iy++) {
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
		for (int64_t iy = 0; iy <= 8; iy++) {
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
// old two-octave cheese blend went away). Evaluated DENSELY in the scan:
// a 32-block period cannot ride the 48-block lattice (AC-0344's
// cell-size decision). The genprobe lockstep source (AweGen::density_layer).
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
// shifted by +64 (the world's min_y). The genprobe lockstep source
// (AweGen::density_entrance).
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

// AC-0347 P2: THE VANILLA DENSITY ROUTER — the ONE density field at a
// cell (solid where > 0, air where < 0), the SHALLOW/DEEP split of the
// file header (Java 1.21.4 overworld.json final_density's range_choice,
// verified against the shipped JSON; density > 0 = solid is the vanilla
// AND our convention — no sign flip). Inputs: H (the heightmap — the
// far/payload/promotion contract, untouched), y, cave (the P1 coarse
// cheese field's trilinear value), ent (the dense entrance family,
// entrance_cave), layer (the dense cave layer's RAW vn3 value — the
// centering happens here; pass 0.0 in the shallow band, it is not read).
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
		int skip = 0, const uint8_t *p_keep = nullptr) {
	int bx = cx * 16;
	int bz = cz * 16;
	int nsl = hmax / 16;
	auto slab_kept = [&](int sl) -> bool {
		return p_keep == nullptr || sl < nsl || p_keep[sl] != 0;
	};
	double ystep = (double)hmax / GY_CELLS;

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
	Field f_cheese{}, f_ore1, f_ore2, f_ore3;
	Field f_spag{}, f_nood{}, f_gate{};
	if (!skip) {
		// AC-0347 P1: the cheese field = vanilla's cave_cheese as-is (see
		// the CHEESE_* constants + the file header) — ONE vn3 field
		// replaces the old AC-0288 two-octave blend (f_cave/f_cave2 gone).
		build_field_vn(f_cheese, bx, bz, ystep, seed + 301,
				CHEESE_XZ_SCALE, CHEESE_Y_SCALE, CHEESE_XZ_SCALE,
				CHEESE_FIRST_OCT, CHEESE_AMPS, CHEESE_AMPS_N);
		// AC-0289: the P1 tunnel fields (see the file header) — FULL PATH
		// only: skip != 0 keeps the H/far/promotion contracts bit-exact
		// (the lazy fill and the far payload never read them).
		build_field(f_spag, bx, bz, ystep, seed + 303, SPAG_XZ, 10.0, SPAG_XZ, 0.0, 0.0, 0.0);
		build_field(f_nood, bx, bz, ystep, seed + 304, NOOD_XZ, 10.0, NOOD_XZ, 0.0, 0.0, 0.0);
		build_field(f_gate, bx, bz, ystep, seed + 305, GATE_XZ, 10.0, GATE_XZ, 0.0, 0.0, 0.0);
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
		if (y < 16 && tril(f_ore1, gx, (double)y / ystep, gz) > 0.78)
			return B_DIAMOND_ORE;
		if (y < 42 && tril(f_ore2, gx, (double)y / ystep, gz) > 0.8)
			return B_IRON_ORE;
		if (y < 60 && tril(f_ore3, gx, (double)y / ystep, gz) > 0.82)
			return B_COAL_ORE;
		if (y < 10 && hash3i(x, y, z, seed + 333) < 0.02)
			return B_OBSIDIAN;
		return B_STONE;
	};

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
					// AC-0347: the router inputs — the cheese from the P1
					// coarse field (trilinear, unchanged), the entrance
					// family DENSE (vanilla cave_entrance AS-IS, ~64-block y
					// period — cannot ride the 48-block lattice), the layer
					// DENSE in the deep band only (it is not read in the
					// shallow branch — vanilla's 32-block period, AC-0344).
					double cave = tril(f_cheese, gx, (double)y / ystep, gz);
					double ent = entrance_cave(x, (double)y, z, seed);
					double lay = (H - y >= K_CUT)
							? layer_cave(x, (double)y, z, seed)
							: 0.0;
					// AC-0289: the tunnel air wins over the router's solid —
					// applied OUTSIDE dens_at (the vanilla spaghetti min,
					// kept where AC-0289 put it: the tunnels pierce the caps).
					bool s = dens_at(H, y, cave, ent, lay) > 0.0
							&& !tunnel_air(f_spag, f_nood, f_gate, gx, (double)y / ystep, gz);
					solidf[y] = s ? 1 : 0;
					if (s && he < 0)
						he = y;
				}
				if (he < 0)
					he = 0; // a fully-caved column: the bedrock is the "surface"
			}
			g_t_scan_us.fetch_add(now_us() - t_scan, std::memory_order_relaxed);
			heff[idx] = he;
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
				if (y == 0) {
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
						// Surface block (biome top; sand on shallow non-desert).
						cell = B_GRASS;
						if (bm == 1)
							cell = B_SAND;
						else if (bm == 0)
							cell = B_SNOW_GRASS;
						if (he <= sea + 1 && bm != 1)
							cell = B_SAND;
					} else if (y >= he - 3 && solid) {
						cell = (bm == 1) ? B_SAND : B_DIRT;
					} else if (!solid) {
						// Air (cave) — deep cave pockets at y<8 hold LAVA
						// (the old deep-carve lava lakes, now from the field).
						cell = (y < 8) ? B_LAVA : 0;
					} else {
						cell = stone_ore(x, y, z, gx, gz);
					}
				}
					flat[(size_t)(y << 8) | base] = cell;
				}
			}
			g_t_fill_us.fetch_add(now_us() - t_fill, std::memory_order_relaxed);
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
					// AC-0347: the same router inputs as the in-column scan
					// (the tree base must match the full column's surface —
					// dense entrance + layer exactly as there).
					double cave = tril(f_cheese, gx2, (double)y / ystep, gz2);
					double ent = entrance_cave(tx, (double)y, tz, seed);
					double lay = (H2 - y >= K_CUT)
							? layer_cave(tx, (double)y, tz, seed)
							: 0.0;
					// AC-0289: the same tunnel rule as the in-column scan.
					if (dens_at(H2, y, cave, ent, lay) > 0.0
							&& !tunnel_air(f_spag, f_nood, f_gate, gx2, (double)y / ystep, gz2)) {
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

	// [data_slabs, fl_slabs] — the exact threadgen resl shape (fl = all null;
	// gen produces no fluid). AC-0284b: skip == 2 = the FAR (h-only)
	// column — the slabs are ALL NULL and the 1024-byte far payload rides
	// resl[2] as {h, bm, top} (the v6 codec's bit-1 section replaces the
	// slab section on disk).
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
		std::vector<uint8_t> f = awegen::gen_flat(p_cx, p_cz, p_s, p_h, p_sea, p_skip, keep);
		Array resl;
		resl.append(awegen::palettize_slabs(f, p_h));
		Array fl;
		fl.resize(p_h / 16); // all null
		resl.append(fl);
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
			if (wy >= 60)
				break; // past every ore band (the chain returns B_STONE)
			for (int lz = 0; lz < 16; lz++) {
				double gz = (double)lz / 4.0;
				for (int lx = 0; lx < 16; lx++) {
					int x = bx + lx;
					int z = bz + lz;
					double gx = (double)lx / 4.0;
					int id = B_STONE;
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
