// AC-0423: the home-hemisphere (faces 0/1) SPHERE MATH, shared by the
// generation lane (gen.cpp — the field sampling follows the shipped
// placement) and the meshing lane (mesh.cpp — the seam-V extension
// measures the V-crack in the PLACED frames, so it must use the exact
// same transform the chunk node wears).
//
// Moved here VERBATIM from gen.cpp (AC-0311's sphere-domain piece — the
// section header and the <1e-6-vs-GD verification note live in gen.cpp's
// design record; the code below is that piece's implementation,
// unmodified). The face 2-11 LSQ-affine placement (sm_face_chunk_
// transform + SM_FIT_INV) stays in gen.cpp — the meshing lane never
// places a face chunk (the home-pair build path is the only AC-0423
// consumer).
//
// The GD originals (sphere_math.gd) this mirrors: _prewarp :68,
// uv_to_world :90, home_point :324, column_transform :332 (the
// SEAM_FILL grout included — the shipped placement).

#pragma once

#include <cmath>
#include <cstdint>

namespace awesm {

constexpr double SM_PI = 3.141592653589793238462643383279502884;

// AC-0469 stage A: the planet grid's CELLS PER FACE EDGE. One named
// constant per language — the GD twin is SphereMath.CELLS_PER_FACE
// (godot/core/sphere_math.gd, keep the two in lockstep). Derivation: a
// face is W = pi*R/2 wide (the grid lock, 4 face-widths = 2*pi*R); at the
// shipped R = 4000, W = 6283.19 m, so 6283 cells span the face and one
// cell is W/6283 = 1.000 m — the user-fixed ~1 m x 1 m x 1 m block.
// (The pre-AC-0469 value was 1024 cells = 6.136 m cells.)
// SM_CHUNKS_PER_FACE: face chunks on the FULL axis (ceil — the last
// row/column of chunks is partial: 392*16 = 6272 full cells + 11 more =
// 393 chunks). AC-0471: this is the MAX of the per-axis counts
// (sm_chunks_u/v — the halved axis is 197 chunks); the chunk-space
// linearization (face*SM_CHUNKS_PER_FACE + ccx, gen.cpp's sp_col_index /
// generator.gd's generate_face) therefore spans SM_CHUNKS_PER_FACE*16 =
// 6288 cells per face — 5 padding cells past the 6283 chart cells — and
// stays collision-free for the halved axes' shorter ranges; sm_chart_dir
// strips THAT span and divides by the per-axis count (cell i <-> uv
// i/cells, the grid definition).
constexpr int64_t SM_CELLS_PER_FACE = 6283;
constexpr int64_t SM_CHUNKS_PER_FACE = (SM_CELLS_PER_FACE + 15) / 16; // 393
// AC-0471: the halved axis's cell count (the GD twin is SphereMath.CELLS_HALF
// — keep in lockstep). Every face but the home pair spans HALF a cube face
// along one axis; at AC-0469 that axis still charted 6,283 cells over hw
// (0.500 m cells). AC-0471 halves the COUNT instead of the size: 3,141
// cells of (W/2)/3141 = 1.00019 m, so every block is ~1 m on both axes.
constexpr int64_t SM_CELLS_HALF = SM_CELLS_PER_FACE / 2; // 3141
// AC-0471: the per-axis cell counts — the ONE grid source of truth (the
// GDScript twins are SphereMath.cells_u/cells_v). The AC-0309 halving
// rule, moved from sizes to counts: the x faces (4-7) run the full axis
// on u (y, W wide) and the halved axis on v (z); every other face runs
// the halved axis on u and the full axis on v.
static inline int64_t sm_cells_u(int face) {
	return (face >= 4 && face <= 7) ? SM_CELLS_PER_FACE : SM_CELLS_HALF;
}
static inline int64_t sm_cells_v(int face) {
	return (face >= 4 && face <= 7) ? SM_CELLS_HALF : SM_CELLS_PER_FACE;
}
// AC-0471: the per-axis chunk counts (ceil). The chunk-space
// linearization stride stays the MAX axis (SM_CHUNKS_PER_FACE) so
// face*stride + ccx stays collision-free across faces with different
// ccx ranges (sm_chart_dir / sp_col_index).
static inline int64_t sm_chunks_u(int face) {
	return (sm_cells_u(face) + 15) / 16;
}
static inline int64_t sm_chunks_v(int face) {
	return (sm_cells_v(face) + 15) / 16;
}

struct SmV3 {
	double x, y, z;
};

static inline SmV3 sm_cross(const SmV3 &a, const SmV3 &b) {
	return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}

static inline double sm_dot(const SmV3 &a, const SmV3 &b) {
	return a.x * b.x + a.y * b.y + a.z * b.z;
}

static inline SmV3 sm_norm(SmV3 v) {
	double n = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
	if (n > 0.0) {
		v.x /= n;
		v.y /= n;
		v.z /= n;
	}
	return v;
}

// The per-coordinate pre-warp (sphere_math.gd :68) — the cube step plus the
// AC-0306 spacing warp; the only warp shape that keeps the gapless invariant.
static inline double sm_prewarp(double c) {
	return std::tan(c * SM_PI * 0.25);
}

// The (u, v) cell of one cube face -> the planet frame (sphere_math.gd :90)
// — the cube maps AS-IS from the header table, prewarped pointwise,
// normalised to R. CONTINUOUS in (u, v) past the face edges (the pre-warp
// is a pointwise cube-coord function): an off-face sample is the same cube
// point the neighbouring face would chart — the gapless continuation.
static inline SmV3 sm_uv_to_world(int face, double u, double v, double R) {
	double cx, cy, cz;
	switch (face) {
	case 0: cx = u; cy = 1.0; cz = 2.0 * v - 1.0; break;
	case 1: cx = u - 1.0; cy = 1.0; cz = 2.0 * v - 1.0; break;
	case 2: cx = u; cy = -1.0; cz = 2.0 * v - 1.0; break;
	case 3: cx = u - 1.0; cy = -1.0; cz = 2.0 * v - 1.0; break;
	case 4: cx = 1.0; cy = 2.0 * u - 1.0; cz = v; break;
	case 5: cx = 1.0; cy = 2.0 * u - 1.0; cz = v - 1.0; break;
	case 6: cx = -1.0; cy = 2.0 * u - 1.0; cz = v; break;
	case 7: cx = -1.0; cy = 2.0 * u - 1.0; cz = v - 1.0; break;
	case 8: cx = u; cy = 2.0 * v - 1.0; cz = 1.0; break;
	case 9: cx = u - 1.0; cy = 2.0 * v - 1.0; cz = 1.0; break;
	case 10: cx = u; cy = 2.0 * v - 1.0; cz = -1.0; break;
	// AC-0460 stage 4: face 11 used to fall through to the default, which
	// duplicates face 10 - so every native caller asking for face 11 got the
	// WRONG half of the -Z cube face (measured 2,736 m error at R = 4000).
	// GDScript has always mapped it as cx = u - 1 (sphere_math.gd:105).
	case 11: cx = u - 1.0; cy = 2.0 * v - 1.0; cz = -1.0; break;
	default: cx = u; cy = 2.0 * v - 1.0; cz = -1.0; break;
	}
	SmV3 p = sm_norm({sm_prewarp(cx), sm_prewarp(cy), sm_prewarp(cz)});
	return {p.x * R, p.y * R, p.z * R};
}

// The home-hemisphere chart (sphere_math.gd home_point :324) — the flat home
// pair (faces 0/1) bent onto the planet; continuous past the patch edges
// (no pole in the neighbourhood).
static inline SmV3 sm_home_point(double x, double z, double R) {
	double hw = SM_PI * R * 0.25;
	if (x < 0.0)
		return sm_uv_to_world(1, x / hw + 1.0, (z / hw + 1.0) * 0.5, R);
	return sm_uv_to_world(0, x / hw, (z / hw + 1.0) * 0.5, R);
}

// A placed chunk column: basis COLUMNS m[0..2] (x, y, z) + origin o —
// P_world = m[0]*lx + m[1]*ly + m[2]*lz + o (o already carries the
// planet-frame shift, so P_planet = P_world + (0, R, 0)).
struct SmT {
	double m[3][3];
	double o[3];
};

static inline SmV3 sm_apply(const SmT &t, double lx, double ly, double lz) {
	return {
		t.m[0][0] * lx + t.m[1][0] * ly + t.m[2][0] * lz + t.o[0],
		t.m[0][1] * lx + t.m[1][1] * ly + t.m[2][1] * lz + t.o[1],
		t.m[0][2] * lx + t.m[1][2] * ly + t.m[2][2] * lz + t.o[2],
	};
}

// The home pair's RIGID per-column placement (column_transform :332) AS-IS
// (the SEAM_FILL grout included — it is the shipped placement the fields
// must follow).
static inline SmT sm_column_transform(int cx, int cz, double R) {
	double cxx = (double)cx * 16.0 + 8.0;
	double czz = (double)cz * 16.0 + 8.0;
	SmV3 P = sm_home_point(cxx, czz, R);
	SmV3 n = {P.x / R, P.y / R, P.z / R};
	SmV3 hp1 = sm_home_point(cxx, czz + 8.0, R);
	SmV3 hp2 = sm_home_point(cxx, czz - 8.0, R);
	SmV3 z0 = sm_norm({hp1.x - hp2.x, hp1.y - hp2.y, hp1.z - hp2.z});
	SmV3 e1 = sm_home_point(cxx + 16.0, czz, R);
	// GD: uE = (e1n).cross(n) — e1n × n (the z0 sign check below
	// normalises the facing).
	SmV3 uE = sm_norm(sm_cross({e1.x / R, e1.y / R, e1.z / R}, n));
	if (sm_dot(uE, z0) < 0.0)
		uE = {-uE.x, -uE.y, -uE.z};
	SmV3 e2 = sm_home_point(cxx - 16.0, czz, R);
	SmV3 uW = sm_norm(sm_cross({e2.x / R, e2.y / R, e2.z / R}, n));
	if (sm_dot(uW, z0) < 0.0)
		uW = {-uW.x, -uW.y, -uW.z};
	SmV3 z;
	bool hasE = (uE.x * uE.x + uE.y * uE.y + uE.z * uE.z) > 1.0e-12;
	bool hasW = (uW.x * uW.x + uW.y * uW.y + uW.z * uW.z) > 1.0e-12;
	if (hasE && hasW)
		z = sm_norm({uE.x + uW.x, uE.y + uW.y, uE.z + uW.z});
	else if (hasE)
		z = uE;
	else if (hasW)
		z = uW;
	else
		z = z0;
	SmV3 x = sm_norm(sm_cross(n, z));
	const double s = 1.0 + 1.0e-4; // SEAM_FILL (sphere_math.gd :56)
	SmT t;
	t.m[0][0] = x.x * s; t.m[0][1] = x.y * s; t.m[0][2] = x.z * s;
	t.m[1][0] = n.x;     t.m[1][1] = n.y;     t.m[1][2] = n.z;
	t.m[2][0] = z.x * s; t.m[2][1] = z.y * s; t.m[2][2] = z.z * s;
	t.o[0] = P.x - 8.0 * s * x.x - 8.0 * s * z.x;
	t.o[1] = P.y - 8.0 * s * x.y - 8.0 * s * z.y - R;
	t.o[2] = P.z - 8.0 * s * x.z - 8.0 * s * z.z;
	return t;
}

// ---------------------------------------------------------------------------
// AC-0433: the face 2-11 placement, moved from gen.cpp (the AC-0423 pattern
// for the home math above) so the mesh lane's seam-V extension can consume
// the shipped face placement from one home. gen.cpp keeps using it via
// `using namespace awesm`.
// ---------------------------------------------------------------------------

// The 16×16 local-grid Gram inverse (sphere_math.gd _fit_build_gram) — the
// local positions are identical for every face chunk, so the inverse is a
// compile-time constant (Cramer's-rule cofactors of the normal matrix,
// round-trip-verified). Row-major.
static const double SM_FIT_INV[9] = {
	0.0001838235294117647, 0, -0.0014705882352941176,
	0, 0.0001838235294117647, -0.0014705882352941176,
	-0.0014705882352941176, -0.0014705882352941176, 0.027435661764705882,
};

static inline bool sm_face_mirror_x(int face) {
	return (face >= 2 && face <= 5) || (face >= 8 && face <= 9);
}

// The face 2-11 per-chunk LSQ-AFFINE placement (face_chunk_transform :508)
// AS-IS — the 256 cell centres of the chunk (home frame, minus (0, R, 0))
// fit the local (cell) grid by least squares; the local +Y is the radial at
// the chunk centre; the mirror class enters through the data layout only.
// NOTE for the mesh lane: the in-plane basis columns are SCALED (|col| ≈
// the face-cell size, ~1 m on both axes at AC-0471 — one face cell per
// local unit; pre-AC-0471 the halved axis was S/2 = 0.5 m; the home
// transform is 1 m/unit),
// and at the home edge the local x-axis is NOT world-x (it runs along the
// cube edge ≈ world-y/z) — consumers must work in dot products, not [0]/[2]
// components (the home-lane K formulas are the degenerate x̂=(1,0,0) case).
static inline SmT sm_face_chunk_transform(int face, int ccx, int ccz, double R) {
	bool mirrored = sm_face_mirror_x(face);
	// AC-0471: the chunk-centre cell and every sampled cell centre chart
	// through the per-axis counts (sm_cells_u/v — the halved axis' 3,141-
	// cell span is what keeps the chart geometry the same with cubic
	// cells).
	double u0 = ((double)ccx * 16.0 + 8.0) / (double)sm_cells_u(face);
	double v0 = ((double)ccz * 16.0 + 8.0) / (double)sm_cells_v(face);
	SmV3 Pc = sm_uv_to_world(face, u0, v0, R);
	SmV3 n = {Pc.x / R, Pc.y / R, Pc.z / R};
	double s[3][3];
	for (int i = 0; i < 3; i++)
		for (int j = 0; j < 3; j++)
			s[i][j] = 0.0;
	for (int lx = 0; lx < 16; lx++) {
		int iu = ccx * 16 + (mirrored ? 15 - lx : lx);
		double x = (double)lx + 0.5;
		for (int lz = 0; lz < 16; lz++) {
			int iv = ccz * 16 + lz;
			SmV3 w = sm_uv_to_world(face,
					((double)iu + 0.5) / (double)sm_cells_u(face),
					((double)iv + 0.5) / (double)sm_cells_v(face), R);
			w.y -= R;
			double y = (double)lz + 0.5;
			s[0][0] += x * w.x; s[0][1] += y * w.x; s[0][2] += w.x;
			s[1][0] += x * w.y; s[1][1] += y * w.y; s[1][2] += w.y;
			s[2][0] += x * w.z; s[2][1] += y * w.z; s[2][2] += w.z;
		}
	}
	// co[ci][cj] = (inv * s[ci] row)[cj] — [coef_lx, coef_lz, const]
	double co[3][3];
	for (int ci = 0; ci < 3; ci++) {
		for (int cj = 0; cj < 3; cj++) {
			double v = 0.0;
			for (int k = 0; k < 3; k++)
				v += SM_FIT_INV[cj * 3 + k] * s[ci][k];
			co[ci][cj] = v;
		}
	}
	SmT t;
	t.m[0][0] = co[0][0]; t.m[0][1] = co[1][0]; t.m[0][2] = co[2][0];
	t.m[1][0] = n.x;      t.m[1][1] = n.y;      t.m[1][2] = n.z;
	t.m[2][0] = co[0][1]; t.m[2][1] = co[1][1]; t.m[2][2] = co[2][1];
	t.o[0] = co[0][2];
	t.o[1] = co[1][2];
	t.o[2] = co[2][2];
	return t;
}

} // namespace awesm
