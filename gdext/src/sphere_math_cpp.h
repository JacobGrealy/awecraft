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

namespace awesm {

constexpr double SM_PI = 3.141592653589793238462643383279502884;

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

} // namespace awesm
