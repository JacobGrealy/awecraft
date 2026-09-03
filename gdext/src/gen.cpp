// AC-0188: GDExtension native port of world generation — the *coarse* 4x8x4
// 3D density approach from the (cancelled) AC-0198 spec, ported directly to
// C++ per the 2026-09-03 user decision.
//
// Replaces the GDScript generate_args hot path (5x _fbm2chunk 17 oct +
// 3x _fbm3col + 2x _vnoise3col per 98k-cell column) with:
//   * the AC-0091 2D heightmap (c/h/r) + biome (t/m) kept EXACT (same AweNoise
//     calls, same remap y = 105.2 + c*36.4 + h*52 + r-boost, spawn pad 136)
//     — sea 126, mountains, biomes, spawn contract stay;
//   * one coarse 3D field per chunk sampled on a 4x8x4-cell grid (points
//     extended one cell per axis for the 2-ring tree neighborhood, 7x9x7 =
//     441 points x 4 fields), each point an AweNoise.fbm3 (2 octaves) with
//     the OLD noise params:
//       CAVE = fbm3(gx/16, gy/10, gz/16, seed+301, 2)   (old nc1 anisotropy)
//       ORE1 = fbm3(gx/7,  gy/7,  gz/7,  seed+77,  2)   (old diamond n1, exact)
//       ORE2 = fbm3(gx/9+900, gy/9, gz/9+900, seed+88, 2) (old iron n2, exact)
//       ORE3 = fbm3(gx/6+1700, gy/6, gz/6+1700, seed+99, 2) (old coal n3, exact)
//   * per-cell trilinear + a quintic "spline surface" ramp (MC-1.18 style):
//       d(x,y,z) = ramp((s - y + 0.5)/6) + 1.8 * (cave(x,y,z) - 0.5)
//       solid where d > 0 (cheese/noodle 3D caves; the surface sits s +/- 6).
//     The ramp is clamped +/-1 with |1.8*(cave-0.5)| < 1, so d is +1 (solid)
//     for y <= s-6 and -1 (air) for y >= s+7 — the surface band is the only
//     region that needs the trilinear.
//   * deep zone y<16 (non-pad columns): cave < 0.42 carves; y<8 fills LAVA
//     (MC-style deep lakes) instead of air — replaces the 2x _vnoise3col.
//   * ore placement keeps the OLD bands/thresholds (diamond y<16 >0.78,
//     iron y<42 >0.8, coal y<60 >0.82) but reads the coarse ore fields;
//     obsidian keeps the exact old per-cell hash3i(x,y,z,seed+333) < 0.02.
//   * trees + flowers keep the exact old hash logic, but the tree base is the
//     effective surface (h_eff) instead of the 2D height.
//
// NOISE INVARIANT: hash2i/hash3i/fade/lerp/vnoise2/vnoise3/fbm2/fbm3 are
// bit-for-bit ports of godot/core/noise.gd (f64 math, i64/i32 integer hash,
// lerpf = a + (b-a)*t). gen.cpp is compiled with -ffp-contract=off so the
// compiler never contracts the fade/ramp polynomials into FMA (baseline
// x86-64 has none, MinGW included). Verified by AWECRAFT_LOGIC=genprobe.
//
// The terrain is NEW (new genhash baseline — accepted, AC-0188 gate): caves
// are 3D-connected, ore comes from the coarse fields, deep pockets are lava.
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

// AC-0198 coarse-density params.
constexpr double CAVE_AMP = 1.8;   // |CAVE_AMP * (cave-0.5)| < 1 keeps the
// ramp asymptotes solid/air (surface always in s +/- 6).
constexpr double BAND = 6.0;       // ramp half-width in y blocks.
constexpr double DEEP_T = 0.42;    // deep-zone carve threshold (y < 16).
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

// AC-0091 exact 2D height (same formula as WorldGen.terrain_height; the
// generate_args column variant uses the same numbers).
static inline int height2d(int x, int z, int64_t seed) {
	double c = fbm2((double)x / 220.0, (double)z / 220.0, seed, 3);
	double h = fbm2((double)x / 70.0 + 333.0, (double)z / 70.0 + 333.0, seed + 7, 4);
	double r = fbm2((double)x / 300.0 + 500.0, (double)z / 300.0 + 500.0, seed + 13, 3);
	double y = 105.2 + c * 36.4 + h * 52.0;
	if (r > 0.62)
		y += (r - 0.62) * 390.0;
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

// Spawn-pad zone (box + circle, matches the height2d pad condition).
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

// AC-0198 "spline surface": quintic ramp in [-1, 1], C2 at the clamps
// (quintic = the same polynomial as AweNoise._fade). +1 (solid) below the
// surface, -1 (air) above; the zero crossing is the surface. The +0.5 keeps
// an unshifted column (cave term 0) solid exactly for y <= s.
static inline double density_ramp(double s, int y) {
	double t = (s + 0.5 - (double)y) / BAND;
	if (t > 1.0)
		t = 1.0;
	else if (t < -1.0)
		t = -1.0;
	double u = 0.5 * (t + 1.0);
	double q = u * u * u * (u * (u * 6.0 - 15.0) + 10.0);
	return 2.0 * q - 1.0;
}

// ---------------------------------------------------------------------------
// Column generation.
// ---------------------------------------------------------------------------

static std::vector<uint8_t> gen_flat(int cx, int cz, int64_t seed, int hmax, int sea) {
	int bx = cx * 16;
	int bz = cz * 16;
	int nsl = hmax / 16;
	double ystep = (double)hmax / GY_CELLS;

	// Coarse fields (441 points each, 2-octave AweNoise.fbm3).
	Field f_cave, f_ore1, f_ore2, f_ore3;
	build_field(f_cave, bx, bz, ystep, seed + 301, 16.0, 10.0, 16.0, 0.0, 0.0, 0.0);
	build_field(f_ore1, bx, bz, ystep, seed + 77, 7.0, 7.0, 7.0, 0.0, 0.0, 0.0);
	build_field(f_ore2, bx, bz, ystep, seed + 88, 9.0, 9.0, 9.0, 900.0, 0.0, 900.0);
	build_field(f_ore3, bx, bz, ystep, seed + 99, 6.0, 6.0, 6.0, 1700.0, 0.0, 1700.0);

	std::vector<int> heights(256);
	std::vector<int> heff(256);
	std::vector<int> bcode(256);
	std::vector<char> padcol(256, 0);

	for (int lz = 0; lz < 16; lz++) {
		for (int lx = 0; lx < 16; lx++) {
			int idx = lz * 16 + lx;
			int x = bx + lx;
			int z = bz + lz;
			int s = height2d(x, z, seed);
			heights[idx] = s;
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
			// Effective surface: pad columns keep the exact pad height (the
			// spawn contract — no cave shift there); others take the topmost
			// solid y of d(y) in [s-6, s+6] (d > 0 is guaranteed at s-6).
			if (padcol[idx]) {
				heff[idx] = s;
			} else {
				int he = s - 6;
				for (int y = s + 6; y >= s - 6; y--) {
					double cave = tril(f_cave, (double)lx / 4.0, (double)y / ystep, (double)lz / 4.0);
					if (density_ramp((double)s, y) + CAVE_AMP * (cave - 0.5) > 0.0) {
						he = y;
						break;
					}
				}
				heff[idx] = he;
			}
		}
	}

	std::vector<uint8_t> flat((size_t)hmax * 256, 0);

	// Solid rock fill for a cell that is neither surface, dirt, water, air,
	// bedrock, nor deep-carved: the old ore chain (same bands/thresholds,
	// read from the coarse ore fields) + the exact old obsidian hash.
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
			int s = heights[idx];
			int he = heff[idx];
			int bm = bcode[idx];
			bool pad = padcol[idx] != 0;
			int x = bx + lx;
			int z = bz + lz;
			double gx = (double)lx / 4.0;
			double gz = (double)lz / 4.0;
			int base = (lz << 4) | lx;

			for (int y = 0; y < hmax; y++) {
				uint8_t cell = 0;
				if (y == 0) {
					cell = B_BEDROCK;
				} else {
					bool solid;
					double cave = -1.0; // -1 = not computed
					if (y < s - 6) {
						solid = true; // ramp clamped +1: d >= 0.1 > 0 always
					} else if (y > s + 6) {
						solid = false; // ramp clamped -1: d <= -0.1 < 0 always
					} else {
						cave = tril(f_cave, gx, (double)y / ystep, gz);
						solid = density_ramp((double)s, y) + (pad ? 0.0 : CAVE_AMP * (cave - 0.5)) > 0.0;
					}
					if (y >= he + 1 && y <= sea && he < sea) {
						cell = B_WATER; // ocean fill (underwater pockets stay water)
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
						cell = 0; // air (cave)
					} else if (!pad && y < 16) {
						// Deep zone: carve + lava lakes (replaces 2x _vnoise3col).
						if (cave < 0.0)
							cave = tril(f_cave, gx, (double)y / ystep, gz);
						if (cave < DEEP_T)
							cell = (y < 8) ? B_LAVA : 0;
						else
							cell = stone_ore(x, y, z, gx, gz);
					} else {
						cell = stone_ore(x, y, z, gx, gz);
					}
				}
				flat[(size_t)(y << 8) | base] = cell;
			}
		}
	}

	// Trees: 20x20 neighborhood (old loop: bx-2 .. bx+17), same hash logic,
	// base = the effective surface (inside) / computed (2-ring margin).
	for (int tz = bz - 2; tz < bz + 18; tz++) {
		for (int tx = bx - 2; tx < bx + 18; tx++) {
			double hv = hash2i(tx, tz, seed + 55);
			if (hv >= 0.14)
				continue;
			int s2 = height2d(tx, tz, seed);
			if (s2 <= sea + 1)
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
			int glx = tx - bx;
			int glz = tz - bz;
			if (glx >= 0 && glx < 16 && glz >= 0 && glz < 16) {
				hcol = heff[glz * 16 + glx];
			} else {
				// Margin column: 2D height + the same surface scan (the
				// fields' 1-cell margin covers tx,tz in [bx-4, bx+20]).
				if (is_pad(tx, tz)) {
					hcol = s2;
				} else {
					double gx2 = (double)(tx - bx) / 4.0;
					double gz2 = (double)(tz - bz) / 4.0;
					hcol = s2 - 6;
					for (int y = s2 + 6; y >= s2 - 6; y--) {
						double cave = tril(f_cave, gx2, (double)y / ystep, gz2);
						if (density_ramp((double)s2, y) + CAVE_AMP * (cave - 0.5) > 0.0) {
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
