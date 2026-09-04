// AC-0215 (supersedes AC-0188): the MC 1.18 style COARSE 4x8x4 3D DENSITY
// FIELD gen — caves AND surface come from ONE field (the user's AC-0215
// ask: "replace the heightmap + per column cave carve").
//
// The per-cell DENSITY (one field, sampled on a coarse 4x8x4-cell grid per
// chunk — 7x9x7 = 441 lattice points per field, the 1-cell margin covering
// the 2-ring tree neighborhood; each lattice point an AweNoise.fbm3):
//
//   d(x,y,z) = S_ramp((H(x,z) - y + 0.5) / R) + A(y) * (C(x,y,z) - 0.5)
//
//   S_ramp = the quintic SPLINE SURFACE DENSITY (C2, the same polynomial as
//            AweNoise._fade) clamped to +/-1: +1 (solid) below the surface,
//            -1 (air) above, the zero crossing IS the surface. R = 10.
//   C(x,y,z) = trilinear of the coarse 3D CAVE field (the AC-0188 field:
//            fbm3(gx/16, gy/10, gz/16, seed+301, 2)) — the per-column cave
//            carve (old 1D _vnoise3col / the y<16 0.42 threshold carve) is
//            GONE: caves are where the one field says d < 0, at ANY depth.
//   A(y) = 1.8 * (1 + max(0, H - y - R) / DEEP_GROW): the cave amplitude.
//            1.8 in the surface band (the surface wobbles +/-~9 with the
//            cave noise and caves break through it), growing with depth
//            (DEEP_GROW = 8) so the 3D caves widen into the deep — MC 1.18
//            deepslate cheese: the deep zone is ~30-38% air, opening
//            downward (the C field is tight — mean 0.506, std 0.105 — so
//            the fast growth is what widens the pockets).
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
//            hc*52 + (rc > 0.62 ? (rc-0.62)*390 : 0), clamp [3,300]; the
//            SPAWN PAD stays EXACT (d<=6 -> 136, 6<d<=10 smoothstep blend —
//            the spawn contract).
//
// SOLID where d > 0, AIR where d < 0. The surface, the caves, and the deep
// lava lakes (deep cave pockets at y<8 fill LAVA instead of air) all come
// from this one field. The aquifer is unchanged: water fills from the
// effective surface up to SEA (126) where the surface is below sea.
//
// Kept from AC-0188/AC-0091:
//   * the coarse ORE fields + OLD bands/thresholds (diamond y<16 >0.78,
//     iron y<42 >0.8, coal y<60 >0.82); obsidian keeps the exact old
//     per-cell hash3i(x,y,z,seed+333) < 0.02 (now y 8..9, y<8 is the
//     non-pad lava floor);
//   * the 2D biome texture field (t/m fbm2) for the surface block / dirt /
//     snow / desert colors (biomes are a surface texture, not terrain);
//   * trees + flowers: exact old hash logic, base = the effective surface
//     (h_eff = topmost d > 0 of the one field) instead of the 2D height.
//
// NOISE INVARIANT: hash2i/hash3i/fade/lerp/vnoise2/vnoise3/fbm2/fbm3 are
// bit-for-bit ports of godot/core/noise.gd (f64 math, i64/i32 integer hash,
// lerpf = a + (b-a)*t). gen.cpp is compiled with -ffp-contract=off so the
// compiler never contracts the fade/ramp polynomials into FMA (baseline
// x86-64 has none, MinGW included). Verified by AWECRAFT_LOGIC=genprobe.
//
// The terrain is NEW again (new genhash baseline — expected, AC-0215 gate):
// the surface now comes from the coarse 3D surface field, the caves run the
// full depth from the same field, and the genhash is deterministic (two
// runs byte-identical).
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
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

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

constexpr int SPAWN_X = 8;
constexpr int SPAWN_Z = 8;
constexpr int SPAWN_H = 136;
constexpr int TERRAIN_H_MAX = 300;

// AC-0215 one-density-field params (MC 1.18 style).
constexpr double CAVE_AMP = 1.8;   // |CAVE_AMP * (cave-0.5)| < 1 keeps the
// ramp asymptotes solid/air (surface always in H +/- R).
constexpr double R_BAND = 10.0;    // spline surface half-width in y blocks.
constexpr double DEEP_GROW = 8.0; // cave-amplitude growth scale with depth.
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

static inline double smoothstep_gd(double e0, double e1, double x) {
	// Godot smoothstep(edge0, edge1, x)
	double t = (x - e0) / (e1 - e0);
	if (t < 0.0)
		t = 0.0;
	else if (t > 1.0)
		t = 1.0;
	return t * t * (3.0 - 2.0 * t);
}

static inline int clampi(int v, int lo, int hi) {
	if (v < lo)
		return lo;
	if (v > hi)
		return hi;
	return v;
}

static inline int64_t absi(int64_t v) {
	return v < 0 ? -v : v;
}

static inline int iabs(int v) {
	return v < 0 ? -v : v;
}

// Spawn-pad zone (box + circle, matches the old height2d pad condition).
static inline bool is_pad(int x, int z) {
	if (absi((int64_t)x - SPAWN_X) > 10 || absi((int64_t)z - SPAWN_Z) > 10)
		return false;
	double dx = (double)x - (double)SPAWN_X;
	double dz = (double)z - (double)SPAWN_Z;
	return std::sqrt(dx * dx + dz * dz) <= 10.0;
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

static void build_field(Field &f, int bx, int bz, double ystep, int64_t seed,
		double fx, double fy, double fz, double ox, double oy, double oz) {
	for (int64_t ix = -1; ix <= 5; ix++) {
		for (int64_t iy = 0; iy <= 8; iy++) {
			for (int64_t iz = -1; iz <= 5; iz++) {
				f[grid_idx(ix, iy, iz)] = fbm3(
						((double)(bx + ix * 4)) / fx + ox,
						((double)(iy * (int)(ystep))) / fy + oy,
						((double)(bz + iz * 4)) / fz + oz,
						seed, 2);
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
// the AC-0091 heightmap. The spawn pad stays EXACT (the spawn contract):
// d<=6 -> SPAWN_H, 6<d<=10 smoothstep blend.
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
	double dx = (double)x - (double)SPAWN_X;
	double dz = (double)z - (double)SPAWN_Z;
	double d = std::sqrt(dx * dx + dz * dz);
	if (d <= 6.0) {
		y = (double)SPAWN_H;
	} else if (d <= 10.0) {
		double w = 1.0 - smoothstep_gd(6.0, 10.0, d);
		y = y * (1.0 - w) + (double)SPAWN_H * w;
	}
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

// AC-0215: the cave amplitude of the one density field. CAVE_AMP in the
// surface band (|y - H| <= R), growing with depth (the deep caves widen
// downward — MC 1.18 cheese). The per-column deep carve is gone.
static inline double cave_amp(int H, int y) {
	double d = (double)H - (double)y - R_BAND;
	if (d < 0.0)
		d = 0.0;
	return CAVE_AMP * (1.0 + d / DEEP_GROW);
}

// The ONE density field at a cell (solid where > 0, air where < 0). Pad
// columns keep the exact flat surface (spawn contract: no cave term).
static inline double dens_at(int H, int y, double cave, bool pad) {
	double s = density_ramp((double)H, y);
	if (pad)
		return s;
	return s + cave_amp(H, y) * (cave - 0.5);
}

// ---------------------------------------------------------------------------
// Column generation.
// ---------------------------------------------------------------------------

static std::vector<uint8_t> gen_flat(int cx, int cz, int64_t seed, int hmax, int sea) {
	int bx = cx * 16;
	int bz = cz * 16;
	int nsl = hmax / 16;
	double ystep = (double)hmax / GY_CELLS;

	// Coarse fields (441 lattice points each = 4x8x4 cells + 1-cell margin,
	// 2-octave AweNoise.fbm3 per lattice point).
	Field f_cave, f_ore1, f_ore2, f_ore3;
	build_field(f_cave, bx, bz, ystep, seed + 301, 16.0, 10.0, 16.0, 0.0, 0.0, 0.0);
	build_field(f_ore1, bx, bz, ystep, seed + 77, 7.0, 7.0, 7.0, 0.0, 0.0, 0.0);
	build_field(f_ore2, bx, bz, ystep, seed + 88, 9.0, 9.0, 9.0, 900.0, 0.0, 900.0);
	build_field(f_ore3, bx, bz, ystep, seed + 99, 6.0, 6.0, 6.0, 1700.0, 0.0, 1700.0);
	// AC-0215: the 3D SURFACE field (the AC-0091 2D heightmap's c/h/r, now
	// 3D on the same coarse grid — replaces the heightmap).
	Field f_sc, f_sh, f_sr;
	build_field(f_sc, bx, bz, ystep, seed, 220.0, SURF_YSCALE, 220.0, 0.0, 0.0, 0.0);
	build_field(f_sh, bx, bz, ystep, seed + 7, 70.0, SURF_YSCALE, 70.0, 333.0, 0.0, 333.0);
	build_field(f_sr, bx, bz, ystep, seed + 13, 300.0, SURF_YSCALE, 300.0, 500.0, 0.0, 500.0);

	std::vector<int> heights(256);
	std::vector<int> heff(256);
	std::vector<int> bcode(256);
	std::vector<char> padcol(256, 0);

	for (int lz = 0; lz < 16; lz++) {
		for (int lx = 0; lx < 16; lx++) {
			int idx = lz * 16 + lx;
			int x = bx + lx;
			int z = bz + lz;
			heights[idx] = surface_h(x, z, f_sc, f_sh, f_sr, ystep, bx, bz);
			padcol[idx] = is_pad(x, z) ? 1 : 0;
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
			bool pad = padcol[idx] != 0;
			int x = bx + lx;
			int z = bz + lz;
			double gx = (double)lx / 4.0;
			double gz = (double)lz / 4.0;
			int base = (lz << 4) | lx;

			// The ONE density field, top-down: the solid flags + the
			// effective surface (topmost d > 0). Above H + R + 1 the field is
			// air for sure (the ramp clamps -1, |CAVE_AMP*(cave-0.5)| < 1),
			// so the scan starts there; everything above stays the flag 0.
			std::vector<uint8_t> solidf((size_t)hmax, 0);
			int he = -1;
			int top = H + 11;
			if (top > hmax - 1)
				top = hmax - 1;
			for (int y = top; y >= 1; y--) {
				double cave = tril(f_cave, gx, (double)y / ystep, gz);
				bool s = dens_at(H, y, cave, pad) > 0.0;
				solidf[y] = s ? 1 : 0;
				if (s && he < 0)
					he = y;
			}
			if (he < 0)
				he = 0; // a fully-caved column: the bedrock is the "surface"
			heff[idx] = he;

			for (int y = 0; y < hmax; y++) {
				uint8_t cell = 0;
				if (y == 0) {
					cell = B_BEDROCK;
				} else {
					bool solid = solidf[y] != 0;
					if (y >= he + 1 && y <= sea && he < sea) {
						cell = B_WATER; // aquifer: ocean fill up to Sea 126
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
						cell = (!pad && y < 8) ? B_LAVA : 0;
					} else {
						cell = stone_ore(x, y, z, gx, gz);
					}
				}
				flat[(size_t)(y << 8) | base] = cell;
			}
		}
	}

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
			} else {
				// Margin column: the one density field's surface (the
				// fields' 1-cell margin covers tx,tz in [bx-4, bx+20]).
				hcol = 0;
				double gx2 = (double)glx / 4.0;
				double gz2 = (double)glz / 4.0;
				bool pad2 = is_pad(tx, tz);
				int top2 = H2 + 11;
				if (top2 > hmax - 1)
					top2 = hmax - 1;
				for (int y = top2; y >= 1; y--) {
					if (pad2) {
						if (density_ramp((double)H2, y) > 0.0) {
							hcol = y;
							break;
						}
					} else {
						double cave = tril(f_cave, gx2, (double)y / ystep, gz2);
						if (dens_at(H2, y, cave, false) > 0.0) {
							hcol = y;
							break;
						}
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
				// _putc (log): only empty cells, inside the chunk.
				int wx = tx, wz = tz, wy = hcol + dy;
				int ax = wx - bx, az = wz - bz;
				if (ax >= 0 && ax < 16 && az >= 0 && az < 16 && wy >= 1 && wy < hmax) {
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
						if (ax >= 0 && ax < 16 && az >= 0 && az < 16 && wy >= 1 && wy < hmax) {
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
				if (flat[idxf] == B_GRASS && hash2i(bx + lx, bz + lz, seed + 777) < 0.02) {
					flat[idxf + 256] = hash2i(bx + lx, bz + lz, seed + 778) < 0.5 ? B_ROSE : B_DANDELION;
				}
			}
		}
	}
	(void)nsl;
	return flat;
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
		for (int i = 0; i < 4096; i++) {
			uint8_t v = flat[base + i];
			if (seen[v] < 0) {
				seen[v] = (int)order.size();
				order.push_back(v);
			}
			if (v != 0)
				nz++;
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
			out[si] = d;
		}
	}
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
		ClassDB::bind_method(D_METHOD("vnoise2", "x", "z", "s"), &AweGen::vnoise2);
		ClassDB::bind_method(D_METHOD("vnoise3", "x", "y", "z", "s"), &AweGen::vnoise3);
		ClassDB::bind_method(D_METHOD("hash2i", "x", "z", "s"), &AweGen::hash2i);
		ClassDB::bind_method(D_METHOD("hash3i", "x", "y", "z", "s"), &AweGen::hash3i);
		ClassDB::bind_method(D_METHOD("fade", "t"), &AweGen::fade);
		ClassDB::bind_method(D_METHOD("density_cave", "x", "y", "z", "s"), &AweGen::density_cave);
		ClassDB::bind_method(D_METHOD("generate_flat", "cx", "cz", "s", "h", "sea"), &AweGen::generate_flat);
		ClassDB::bind_method(D_METHOD("generate_slabs", "cx", "cz", "s", "h", "sea"), &AweGen::generate_slabs);
		ClassDB::bind_method(D_METHOD("generate_resl", "cx", "cz", "s", "h", "sea"), &AweGen::generate_resl);
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
	double density_cave(double p_x, double p_y, double p_z, int p_s) const {
		return awegen::fbm3(p_x / 16.0, p_y / 10.0, p_z / 16.0, p_s + 301, 2);
	}

	PackedByteArray generate_flat(int p_cx, int p_cz, int p_s, int p_h, int p_sea) const {
		std::vector<uint8_t> f = awegen::gen_flat(p_cx, p_cz, p_s, p_h, p_sea);
		PackedByteArray out;
		out.resize((int)f.size());
		if (!f.empty())
			std::memcpy(out.ptrw(), f.data(), f.size());
		return out;
	}

	Array generate_slabs(int p_cx, int p_cz, int p_s, int p_h, int p_sea) const {
		std::vector<uint8_t> f = awegen::gen_flat(p_cx, p_cz, p_s, p_h, p_sea);
		return awegen::palettize_slabs(f, p_h);
	}

	// [data_slabs, fl_slabs] — the exact threadgen resl shape (fl = all null;
	// gen produces no fluid).
	Array generate_resl(int p_cx, int p_cz, int p_s, int p_h, int p_sea) const {
		std::vector<uint8_t> f = awegen::gen_flat(p_cx, p_cz, p_s, p_h, p_sea);
		Array resl;
		resl.append(awegen::palettize_slabs(f, p_h));
		Array fl;
		fl.resize(p_h / 16); // all null
		resl.append(fl);
		return resl;
	}
};

void register_classes() {
	GDREGISTER_CLASS(AweGen);
}

} // namespace awegen
