// AC-0190: GDExtension native port of the chunk MESH build
// (godot/world/chunk.gd build_accs — the LAST of the 4 C++ ports; the
// AC-0165/AC-0188/AC-0189 pipeline, same .so/.dll, same
// chunkio_library_init entry symbol).
//
// LOSSLESS INARIANT: AweMesh.build_accs produces the SAME verts/indices/
// colors/UVs/light as ChunkScript.build_accs for the SAME input (the
// worker pipeline: light -> bake box -> snap -> ro scan -> greedy merged
// emit). Verified by AWECRAFT_LOGIC=meshprobe (C++ vs GDScript on N
// chunks; gate: 100% exact — q/v/n/c/u/i per slab + light arr/mask/ring).
//
// Ported verbatim (integer kernels + float32 color/UV math replicated with
// the SAME per-operation rounding order — the build is -O2
// -ffp-contract=off, so no FMA folding; GDScript is float32 throughout):
//   * build_accs (chunk.gd:1683) — the entry: top clamp (AC-0197), slab
//     views, scoped sgrid/ymask pre-pass (AC-0187), the ro scan
//     (stab/oktab/ktab/xtab/ttab tables, the 98k stab/interior test),
//     fluid + face record collection;
//   * _build_snap_data (chunk.gd:1553) — the 18-wide SNAP_ROW x h snapshot
//     (own 16x16 + the 4 edge-neighbor rings, fluid-fill-8 for 5/24);
//   * _bake_box (chunk.gd:1999) — the 20x20x(rows) face-light bake (core
//     16x16 at (2,2) + eff strips: sides E/W/S/N, corners SE/SW/NE/NW —
//     corner cells keep the y_hi write order of the GDScript, byte-exact);
//   * _s_emit_ro_merged (chunk.gd:1388) — the greedy 2D merge (width
//     along u up to 16, height along v up to 4, merge key [id, fni,
//     shade=fsh*s]) + _s_qwrite_merged (chunk.gd:1284) + _merge_strip;
//   * _s_emit_faces (chunk.gd:1230) — the per-face (non-merged) quad
//     path + _qwrite (chunk.gd:751) + _s_uvc/_s_face_uvs/_s_corner_uv;
//   * _s_emit_fluid (chunk.gd:1509), _s_emit_xquad (chunk.gd:1470),
//     _s_faces (chunk.gd:1184), _s_fluid_quad_count (chunk.gd:1206),
//     _fluid_hgt (chunk.gd:732), _s_effl/_s_face_light (chunk.gd:1101/1113),
//     _mask_sample/_face_mask (chunk.gd:622/636), _light_color (chunk.gd:606),
//     _s_is_interior (chunk.gd:1172), _band (chunk.gd:1082).
//
// AC-0203 FOLLOW-ON: the paletted slab format (null | {n,b,p,i,nz} — bits
// 1-8 + palette[16] + idx 4096 packed) is decoded HERE in C++ (awe_common
// slab_views — direct palette lookup, ~1 ns per cell) instead of the
// GDScript ChunkIO._slab_flat (the 18.5 ms*4 per-dispatch Variant
// expansion). The paletted slabs ride the entry as value copies and are
// never re-flattened in GDScript first.
//
// LIGHT (AC-0283 P4): the STAR payload (light["star"] — the AweStarlight
// settled nibbles) is the game's slab light (the slab + remesh lanes always
// carry it); a cached eff (with "mask") is consumed as-is (the eff-cache /
// saved-light / edit-scoped fast paths); an empty/maskless eff recomputes
// light through the SAME C++ pull kernel the AweLighting class uses
// (awelight::pull — same .so, byte-identical to the class path, lightprobe
// 100% exact). That last branch is the LEGACY path: live only for the
// edit-fallback full bake + the tex-refresh rebuild (no-mask last_eff) +
// the star==null fallback + the harness arms' empty-eff dispatches.
//
// WORKER SAFETY: no Data/Game autoloads — every table arrives as a value
// copy in ctx/ms/nbs/eff (the same copies the GDScript worker consumes).
//
// Toggle: AWECRAFT_MESHCPP=0 forces the GDScript path (chunk.gd
// build_accs); unset/1 = C++ whenever this library registered AweMesh
// (wired at world.gd _tm_worker_run).
//
// AC-0211: the remaining GDScript hot spots around build_accs moved here:
//   * snap_rings — the dispatch's neighbor SNAP snapshot (the 16x16
//     boundary slice per slab; replaces the per-neighbor _slabs_deepcopy
//     of all 24 slabs — the worker reads only this slice, and parse_nbs
//     accepts the compact PackedByteArray ring alongside the legacy
//     paletted-slab Array);
//   * slab_copy — the dispatch's own-column value-copy
//     (ChunkIO._slabs_deepcopy stand-in, true byte copies);
//   * sync_snap — the sync fallback lane's _build_snap core (chunk.gd
//     build_mesh) — the paletted decode replaces the GDScript
//     flat_data()/flat_fl() materialization (5 x 98k cells);
//   * rows_eq — the scoped handoff stale check (world.gd
//     threadmesh_handoff) — 256-B row equality without the per-row 4096
//     flat materialization.
// The main-thread scene handoff (ArrayMesh/MeshInstance3D/materials/
// collision bodies) stays GDScript — Godot scene-tree + engine mesh
// upload are main-thread work (the worker's arrays arrive already
// trimmed and refcounted, so the handoff's data cost is engine-side).

#include <gdextension_interface.h>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <unordered_map>
#include <vector>

#include "awe_common.h"

using namespace godot;

namespace awemesh {

constexpr int SIZE = 16;
constexpr int SNAP_W = 18;
constexpr int SNAP_ROW = 324; // 18 * 18
constexpr float MIN_AMB = 0.08f;
// AC-0312: the water block id (data.gd contract — B_WATER in gen.cpp;
// the fluid ids 5/24 in the high path). The avg-emit water-surface
// exception's "topmost non-air is water" test.
constexpr int AW_B_WATER = 5;

// ---------------------------------------------------------------------------
// VoxelMath.FACES (godot/core/math.gd:3) — verbatim.
// ---------------------------------------------------------------------------

static const int FN[6][3] = {
	{-1, 0, 0},
	{1, 0, 0},
	{0, 1, 0},
	{0, -1, 0},
	{0, 0, -1},
	{0, 0, 1},
};
static const float FSH[6] = {0.8f, 0.8f, 1.0f, 0.5f, 0.8f, 0.8f};
static const float FCV[6][4][3] = {
	{{0.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 1.0f}, {0.0f, 1.0f, 1.0f}, {0.0f, 1.0f, 0.0f}},
	{{1.0f, 0.0f, 1.0f}, {1.0f, 0.0f, 0.0f}, {1.0f, 1.0f, 0.0f}, {1.0f, 1.0f, 1.0f}},
	{{0.0f, 1.0f, 1.0f}, {1.0f, 1.0f, 1.0f}, {1.0f, 1.0f, 0.0f}, {0.0f, 1.0f, 0.0f}},
	{{0.0f, 0.0f, 0.0f}, {1.0f, 0.0f, 0.0f}, {1.0f, 0.0f, 1.0f}, {0.0f, 0.0f, 1.0f}},
	{{1.0f, 0.0f, 0.0f}, {0.0f, 0.0f, 0.0f}, {0.0f, 1.0f, 0.0f}, {1.0f, 1.0f, 0.0f}},
	{{0.0f, 0.0f, 1.0f}, {1.0f, 0.0f, 1.0f}, {1.0f, 1.0f, 1.0f}, {0.0f, 1.0f, 1.0f}},
};
// chunk.gd:8-9 (XQ cross-quad corners)
static const float XQ_A[4][3] = {{0.0f, 0.0f, 0.5f}, {1.0f, 0.0f, 0.5f}, {1.0f, 1.0f, 0.5f}, {0.0f, 1.0f, 0.5f}};
static const float XQ_B[4][3] = {{0.5f, 0.0f, 0.0f}, {0.5f, 0.0f, 1.0f}, {0.5f, 1.0f, 1.0f}, {0.5f, 1.0f, 0.0f}};

// ---------------------------------------------------------------------------
// Float helpers — GDScript arithmetic is float32 per operation; the
// -ffp-contract=off build flag guarantees no FMA folding, so the same
// parenthesization in C++ float is bit-identical.
// ---------------------------------------------------------------------------

static inline float clampf(float v, float lo, float hi) {
	if (v < lo)
		return lo;
	if (v > hi)
		return hi;
	return v;
}

static inline Color mul_cc(const Color &a, const Color &b) {
	return Color(a.r * b.r, a.g * b.g, a.b * b.b, a.a * b.a);
}

static inline Color mul_cf(const Color &a, float k) {
	return Color(a.r * k, a.g * k, a.b * k, a.a * k);
}

// ---------------------------------------------------------------------------
// ctx snapshot (make_ctx + the dispatch additions: strips/top/coarse/
// uv_scale) — parsed once per build from the value-copy Dictionary.
// ---------------------------------------------------------------------------

struct StripSet {
	const uint8_t *ptr[8];
	int size[8];
	int n = 0;
	StripSet() {
		for (int i = 0; i < 8; i++) {
			ptr[i] = nullptr;
			size[i] = 0;
		}
	}
};

static void strip_set(const Variant &v, StripSet &out) {
	out.n = 0;
	if (v.get_type() != Variant::ARRAY)
		return;
	Array a = v;
	for (int i = 0; i < (int)a.size() && i < 8; i++) {
		PackedByteArray pba = a[i];
		out.ptr[i] = (const uint8_t *)pba.ptr();
		out.size[i] = (int)pba.size();
		out.n = i + 1;
	}
}

static void copy_table(const PackedByteArray &src, uint8_t *dst, int n) {
	for (int i = 0; i < n; i++)
		dst[i] = (i < (int)src.size()) ? src[i] : 0;
}

static void copy_colors(const PackedColorArray &src, Color *dst, int n) {
	for (int i = 0; i < n; i++)
		dst[i] = (i < (int)src.size()) ? src[i] : Color(0.0f, 0.0f, 0.0f, 1.0f);
}

struct Ctx {
	int h = 384;
	int top = -1;
	float atlas_px = 1024.0f;
	bool has_tex = false;
	bool coarse = false;
	int uv_scale = 1;
	float ppb = 31.0f;
	uint8_t oktab[256];
	uint8_t xtab[256];
	uint8_t stab[256];
	uint8_t ktab[256];
	uint8_t ttab[256];
	Color ct[256];
	Color cs[256];
	Color cb[256];
	Color tint_top[256];
	Color tint_side[256];
	Color tint_bottom[256];
	Vector2i brect[256][3]; // 0=side, 1=top, 2=bottom
	StripSet eff_strips;
};

static String rect_key(int id, int face) {
	static const char *names[3] = {"side", "top", "bottom"};
	return String::num_int64(id) + String("_") + String(names[face]);
}

static bool parse_rect_key(const String &k, int &id, int &face) {
	int64_t u = k.find("_");
	if (u < 0)
		return false;
	String head = k.left(u);
	id = (int)head.to_int();
	String tail = k.right(k.length() - u - 1);
	if (tail == "side")
		face = 0;
	else if (tail == "top")
		face = 1;
	else if (tail == "bottom")
		face = 2;
	else
		return false;
	return true;
}

static void parse_ctx(const Dictionary &ctx, Ctx &out) {
	out.h = (int)ctx.get("h", 384);
	out.top = (int)ctx.get("top", -1);
	out.atlas_px = (float)ctx.get("atlas_px", 1024.0);
	out.has_tex = (bool)ctx.get("has_tex", false);
	out.coarse = (bool)ctx.get("coarse", false);
	out.uv_scale = (int)ctx.get("uv_scale", 1);
	out.ppb = 31.0f / (float)out.uv_scale;
	copy_table(ctx.get("oktab", PackedByteArray()), out.oktab, 256);
	copy_table(ctx.get("xtab", PackedByteArray()), out.xtab, 256);
	copy_table(ctx.get("stab", PackedByteArray()), out.stab, 256);
	copy_table(ctx.get("ktab", PackedByteArray()), out.ktab, 256);
	copy_table(ctx.get("ttab", PackedByteArray()), out.ttab, 256);
	copy_colors(ctx.get("ct", PackedColorArray()), out.ct, 256);
	copy_colors(ctx.get("cs", PackedColorArray()), out.cs, 256);
	copy_colors(ctx.get("cb", PackedColorArray()), out.cb, 256);
	copy_colors(ctx.get("tint_top", PackedColorArray()), out.tint_top, 256);
	copy_colors(ctx.get("tint_side", PackedColorArray()), out.tint_side, 256);
	copy_colors(ctx.get("tint_bottom", PackedColorArray()), out.tint_bottom, 256);
	Dictionary brect = ctx.get("brect", Dictionary());
	for (int bi = 0; bi < 256; bi++) {
		for (int f = 0; f < 3; f++)
			out.brect[bi][f] = (Vector2i)brect.get(rect_key(bi, f), Vector2i(-1, -1));
	}
	strip_set(ctx.get("eff_strips", Array()), out.eff_strips);
}

// ms (the merge-atlas snapshot: rects "id_face" -> Vector2i + canvas h).
struct Ms {
	bool nonempty = false;
	float h = 0.0f;
	Vector2i rects[256][3];
};

static void parse_ms(const Dictionary &ms, Ms &out, float atlas_px) {
	out.nonempty = false;
	out.h = (float)ms.get("h", atlas_px);
	for (int i = 0; i < 256; i++)
		for (int f = 0; f < 3; f++)
			out.rects[i][f] = Vector2i(-1, -1);
	Dictionary rects = ms.get("rects", Dictionary());
	if (rects.is_empty())
		return;
	Array keys = rects.keys();
	for (int k = 0; k < (int)keys.size(); k++) {
		String ks = keys[k];
		int id = 0;
		int f = 0;
		if (!parse_rect_key(ks, id, f) || id < 0 || id >= 256)
			continue;
		out.rects[id][f] = (Vector2i)rects.get(ks, Vector2i(-1, -1));
	}
	out.nonempty = true;
}

// ---------------------------------------------------------------------------
// Acc — the per-surface vertex buffers (v/n/c/u interleaved float32 + i
// int32 + q = quad count). Output is trimmed to q (the main thread's
// _surface() resizes to q*4/q*6 anyway — the pre-sized tails of the
// GDScript _qgrow are always discarded).
// ---------------------------------------------------------------------------

struct Acc {
	std::vector<float> v; // 3 floats per vertex
	std::vector<float> n;
	std::vector<float> c; // 4 floats per vertex (rgba)
	std::vector<float> u; // 2 floats per vertex
	std::vector<int32_t> i;
	int q = 0;

	void ensure(int quads) {
		if ((int)v.size() >= quads * 4 * 3)
			return;
		v.resize(quads * 4 * 3);
		n.resize(quads * 4 * 3);
		c.resize(quads * 4 * 4);
		u.resize(quads * 4 * 2);
		i.resize(quads * 6);
	}
};

// _qwrite (chunk.gd:751) — one quad: positions lx/cv.x, y/py_j, lz/cv.z;
// normals n; per-vertex uvs (precomputed); color c; index pattern
// b, b+2, b+1, b, b+3, b+2.
static void qwrite(Acc &acc, const Color &c, const int n[3], const float *uvs, const float (*fcv)[3], int lx, int y, int lz, float py0, float py1, float py2, float py3) {
	int k = acc.q;
	acc.ensure(k + 1);
	int b = k * 4;
	acc.v[(b + 0) * 3 + 0] = (float)lx + fcv[0][0];
	acc.v[(b + 0) * 3 + 1] = (float)y + py0;
	acc.v[(b + 0) * 3 + 2] = (float)lz + fcv[0][2];
	acc.v[(b + 1) * 3 + 0] = (float)lx + fcv[1][0];
	acc.v[(b + 1) * 3 + 1] = (float)y + py1;
	acc.v[(b + 1) * 3 + 2] = (float)lz + fcv[1][2];
	acc.v[(b + 2) * 3 + 0] = (float)lx + fcv[2][0];
	acc.v[(b + 2) * 3 + 1] = (float)y + py2;
	acc.v[(b + 2) * 3 + 2] = (float)lz + fcv[2][2];
	acc.v[(b + 3) * 3 + 0] = (float)lx + fcv[3][0];
	acc.v[(b + 3) * 3 + 1] = (float)y + py3;
	acc.v[(b + 3) * 3 + 2] = (float)lz + fcv[3][2];
	for (int j = 0; j < 4; j++) {
		acc.n[(b + j) * 3 + 0] = (float)n[0];
		acc.n[(b + j) * 3 + 1] = (float)n[1];
		acc.n[(b + j) * 3 + 2] = (float)n[2];
		acc.u[(b + j) * 2 + 0] = uvs[j * 2 + 0];
		acc.u[(b + j) * 2 + 1] = uvs[j * 2 + 1];
		acc.c[(b + j) * 4 + 0] = c.r;
		acc.c[(b + j) * 4 + 1] = c.g;
		acc.c[(b + j) * 4 + 2] = c.b;
		acc.c[(b + j) * 4 + 3] = c.a;
	}
	int ib = k * 6;
	acc.i[ib + 0] = b;
	acc.i[ib + 1] = b + 2;
	acc.i[ib + 2] = b + 1;
	acc.i[ib + 3] = b;
	acc.i[ib + 4] = b + 3;
	acc.i[ib + 5] = b + 2;
	acc.q = k + 1;
}

// ---------------------------------------------------------------------------
// Light sampling (chunk.gd:1101/1113) + mask evidence (chunk.gd:622/636)
// + the vColor repack (chunk.gd:606).
// ---------------------------------------------------------------------------

static inline int s_effl(const Vector3i &lmn, const uint8_t *larr, int lw, int ld, int x, int y, int z, int h) {
	if (y < 0)
		return 0;
	if (y >= h)
		return 15;
	int ix = x - lmn.x;
	int iz = z - lmn.z;
	if (ix < 0 || iz < 0 || ix >= lw || iz >= ld)
		return 15;
	return larr[(size_t)(y - lmn.y) * lw * ld + iz * lw + ix];
}

static inline float s_face_light(int id, int wx, int y, int wz, const int n[3], const Vector3i &lmn, const uint8_t *larr, int lw, int ld, int h) {
	int v = 0;
	if (id == 22) {
		v = s_effl(lmn, larr, lw, ld, wx, y, wz, h);
	} else {
		int nx = wx + n[0];
		int ny = y + n[1];
		int nz = wz + n[2];
		v = s_effl(lmn, larr, lw, ld, nx, ny, nz, h);
		if (v < 15 && id != 5 && id != 24) {
			if (n[0] == 0) {
				v = std::max(v, s_effl(lmn, larr, lw, ld, nx + 1, ny, nz, h));
				if (v < 15)
					v = std::max(v, s_effl(lmn, larr, lw, ld, nx - 1, ny, nz, h));
			}
			if (v < 15 && n[1] == 0) {
				v = std::max(v, s_effl(lmn, larr, lw, ld, nx, ny + 1, nz, h));
				if (v < 15)
					v = std::max(v, s_effl(lmn, larr, lw, ld, nx, ny - 1, nz, h));
			}
			if (v < 15 && n[2] == 0) {
				v = std::max(v, s_effl(lmn, larr, lw, ld, nx, ny, nz + 1, h));
				if (v < 15)
					v = std::max(v, s_effl(lmn, larr, lw, ld, nx, ny, nz - 1, h));
			}
		}
	}
	return clampf((float)v / 15.0f, MIN_AMB, 1.0f);
}

static inline int mask_sample(int wx, int y, int wz, const Vector3i &lmn, int h, const uint8_t *bmask, int bmask_sz) {
	if (bmask_sz != 256 * h)
		return 0;
	int lx = (wx - lmn.x) - 2;
	int lz = (wz - lmn.z) - 2;
	if (y < 0 || y >= h || lx < 0 || lx >= 16 || lz < 0 || lz >= 16)
		return 0;
	return bmask[(y << 8) | (lz << 4) | lx];
}

static inline int face_mask(int id, int wx, int y, int wz, const int n[3], const Vector3i &lmn, int h, const uint8_t *bmask, int bmask_sz) {
	if (id == 22)
		return mask_sample(wx, y, wz, lmn, h, bmask, bmask_sz);
	int nx = wx + n[0];
	int ny = y + n[1];
	int nz = wz + n[2];
	int m = mask_sample(nx, ny, nz, lmn, h, bmask, bmask_sz);
	if (id != 5 && id != 24 && m == 0) {
		if (n[0] == 0) {
			m = mask_sample(nx + 1, ny, nz, lmn, h, bmask, bmask_sz);
			if (m == 0)
				m = mask_sample(nx - 1, ny, nz, lmn, h, bmask, bmask_sz);
		}
		if (m == 0 && n[1] == 0) {
			m = mask_sample(nx, ny + 1, nz, lmn, h, bmask, bmask_sz);
			if (m == 0)
				m = mask_sample(nx, ny - 1, nz, lmn, h, bmask, bmask_sz);
		}
		if (m == 0 && n[2] == 0) {
			m = mask_sample(nx, ny, nz + 1, lmn, h, bmask, bmask_sz);
			if (m == 0)
				// VERBATIM quirk (chunk.gd:675): the second z-branch probe samples
				// (nx, ny-1, nz), NOT (nx, ny, nz-1). The GDScript _face_mask diverges
				// from _s_face_light here; the lossless port must keep the quirk.
				m = mask_sample(nx, ny - 1, nz, lmn, h, bmask, bmask_sz);
		}
	}
	return m;
}

// AC-0128 vColor repack: has_tex -> r = sky s (or 0), g = s (only when the
// face has block-light evidence, else 0), b = face shade; no atlas ->
// face_color * (fsh * s).
static inline Color light_color(float s, float fsh, int mask, const Color &face_color, bool has_tex) {
	if (has_tex) {
		if (mask > 0)
			return Color(0.0f, s, fsh, 1.0f);
		return Color(s, 0.0f, fsh, 1.0f);
	}
	float k = fsh * s;
	return mul_cf(face_color, k);
}

// ---------------------------------------------------------------------------
// UV helpers (chunk.gd:1138-1169): _s_corner_uv / _s_face_uvs / _s_uvc.
// The uvc cache is per emit CALL (a fresh {} each call in the GDScript).
// ---------------------------------------------------------------------------

// _s_corner_uv: tl (-1,-1) -> (0,0); else (tl + (0.5 + u*ppb, 0.5 + v*ppb))
// / atlas_px (SCALAR division — the ms_h split exists only in the merged
// path, exactly as in the GDScript).
static inline void s_corner_uv(float cx, float cy, float cz, const int n[3], const Vector2i &tl, float atlas_px, float ppb, float *ou, float *ov) {
	if (tl.x < 0) {
		*ou = 0.0f;
		*ov = 0.0f;
		return;
	}
	float u;
	float v;
	if (n[1] != 0) {
		u = cx;
		v = cz;
	} else if (n[0] != 0) {
		u = cz;
		v = 1.0f - cy;
	} else {
		u = cx;
		v = 1.0f - cy;
	}
	*ou = ((float)tl.x + (0.5f + u * ppb)) / atlas_px;
	*ov = ((float)tl.y + (0.5f + v * ppb)) / atlas_px;
}

// Per-call uvc cache: key -> 8 floats (4 uv pairs).
using UvcCache = std::unordered_map<int, std::array<float, 8>>;

// _s_uvc: key = int(ppb)*256*8 + id*8 + fi; tl from brect (id, face_name).
static const float *s_uvc(UvcCache &uvc, const Ctx &ctx, int id, int fi, int face_idx) {
	int key = (int)ctx.ppb * 256 * 8 + id * 8 + fi;
	auto it = uvc.find(key);
	if (it != uvc.end())
		return it->second.data();
	const Vector2i &tl = ctx.brect[id][face_idx];
	std::array<float, 8> out;
	for (int j = 0; j < 4; j++)
		s_corner_uv(FCV[fi][j][0], FCV[fi][j][1], FCV[fi][j][2], FN[fi], tl, ctx.atlas_px, ctx.ppb, &out[j * 2], &out[j * 2 + 1]);
	uvc[key] = out;
	return uvc.find(key)->second.data();
}

// ---------------------------------------------------------------------------
// Records (the recs arrays of the GDScript ro scan).
// ---------------------------------------------------------------------------

struct FRec {
	int lx;
	int y;
	int lz;
	int fi;
	int id;
	int fni;
};
struct FluidRec {
	int lx;
	int y;
	int lz;
	int id;
	float hgt;
};
struct XRec {
	int lx;
	int y;
	int lz;
	int id;
};



// ---------------------------------------------------------------------------
// _build_snap_data (chunk.gd:1553) — the 18-wide snapshot with the 4
// edge-neighbor rings. snap/snap_fl arrive zero-filled (like the
// PackedByteArray.resize fill).
// ---------------------------------------------------------------------------

struct Nv {
	// The 4 EDGE neighbors the dispatch hands over (the GDScript skip
	// condition (dx==0)==(dz==0) keeps exactly (±1,0)/(0,±1)):
	// 0 = (-1,0) west, 1 = (1,0) east, 2 = (0,-1) south, 3 = (0,1) north.
	std::vector<std::vector<uint8_t>> nd[4];
	std::vector<std::vector<uint8_t>> nfd[4];
};

static inline int nv_ki(int dx, int dz) {
	if (dx == -1)
		return 0;
	if (dx == 1)
		return 1;
	if (dz == -1)
		return 2;
	return 3;
}

static void parse_nbs(const Dictionary &nbs, Nv &out) {
	static const int DX[4] = {-1, 1, 0, 0};
	static const int DZ[4] = {0, 0, -1, 1};
	for (int k = 0; k < 4; k++) {
		String key = String::num_int64(DX[k]) + "," + String::num_int64(DZ[k]);
		Variant v = nbs.get(key, Variant());
		if (v.get_type() != Variant::DICTIONARY)
			continue;
		Dictionary nb = v;
		Variant vd = nb.get("d", Variant());
		if (vd.get_type() == Variant::PACKED_BYTE_ARRAY) {
			// AC-0211 compact ring: slab*256 + y_in*16 + t (the boundary
			// slice only — build_snap_data indexes it accordingly).
			PackedByteArray rd = vd;
			Variant vf = nb.get("f", Variant());
			PackedByteArray rf = (vf.get_type() == Variant::PACKED_BYTE_ARRAY) ? PackedByteArray(vf) : PackedByteArray();
			int nsl = (int)rd.size() / 256;
			out.nd[k].resize(nsl);
			for (int s = 0; s < nsl; s++)
				out.nd[k][s].assign(rd.ptr() + s * 256, rd.ptr() + s * 256 + 256);
			int nfl = (int)rf.size() / 256;
			out.nfd[k].resize(nfl);
			for (int s = 0; s < nfl; s++)
				out.nfd[k][s].assign(rf.ptr() + s * 256, rf.ptr() + s * 256 + 256);
		} else {
			// Legacy: paletted slab arrays (the probe + fallback shape) —
			// full decode.
			awecommon::slab_views(nb.get("d", Array()), out.nd[k]);
			awecommon::slab_views(nb.get("f", Array()), out.nfd[k]);
		}
	}
}

// _band (chunk.gd:1082): delta -1 -> [(0,15)], +1 -> [(17,0)], 0 ->
// [(v+1, v) for v in 0..15]. Returns (sxy-offset-x, gi-x) pairs.
struct Band {
	int x[16]; // sxy offset (dx == -1: 0, dx == 1: 17, else v+1)
	int g[16]; // slab-column read (dx == -1: 15, dx == 1: 0, else v)
	int n = 0;
};

static Band band(int delta) {
	Band b;
	if (delta == -1) {
		b.x[0] = 0;
		b.g[0] = 15;
		b.n = 1;
	} else if (delta == 1) {
		b.x[0] = 17;
		b.g[0] = 0;
		b.n = 1;
	} else {
		for (int v = 0; v < 16; v++) {
			b.x[v] = v + 1;
			b.g[v] = v;
			b.n = v + 1;
		}
	}
	return b;
}

// ---------------------------------------------------------------------------
// AC-0211: compact neighbor SNAP RING + slab copy/row helpers.
//
// The worker path only ever reads ONE 16x16 boundary slice per slab from
// each edge neighbor (the build_snap_data ring: x=15/0 for dx neighbors,
// z=15/0 for dz neighbors) — never the full 4096-cell slab. The dispatch
// builds the compact ring on the MAIN thread (AweMesh.snap_rings, 256 B
// per slab — the thread-safe snapshot replaces the per-neighbor
// _slabs_deepcopy of all 24 slabs) and the C++ build_accs consumes it
// directly (parse_nbs accepts a PackedByteArray ring entry alongside the
// legacy paletted-slab Array — the legacy format is still accepted for
// probes + the AWECRAFT_MESHCPP=0 parity). Byte-identical to the full
// decode (the meshprobe compact arm gates it, 100% exact).
// ---------------------------------------------------------------------------

// One 16x16 boundary slice of a paletted slab (null/missing slab = zeros —
// the caller pre-zeros `out`). out[base + y_in*16 + t]: t = z for dx
// neighbors (dx != 0, source x = dx<0 ? 15 : 0), t = x for dz neighbors
// (dz != 0, source z = dz<0 ? 15 : 0). Decode = the same lanes as
// slab_views (n==1 uniform / n==0 raw / else palette getbits).
static void ring_slice(const Variant &v, int base, int dx, int dz, std::vector<uint8_t> &out) {
	if (v.get_type() != Variant::DICTIONARY)
		return;
	Dictionary d = v;
	int n = (int)d.get("n", 0);
	int fx = (dx != 0) ? (dx < 0 ? 15 : 0) : -1;
	int fz = (dz != 0) ? (dz < 0 ? 15 : 0) : -1;
	if (n == 1) {
		PackedByteArray p = d.get("p", PackedByteArray());
		uint8_t val = p.size() > 0 ? p[0] : 0;
		for (int j = 0; j < 256; j++)
			out[base + j] = val;
		return;
	}
	// AC-0253: the neighbor slab's solid/air bitset (gen ahead) — the ring
	// cells become a BIT TEST first: air cells stay 0 without the palette
	// decode, solid cells decode as before. The output ring is byte-
	// identical to the full decode (the meshprobe compact arm gates it).
	{
		PackedByteArray bsarr = d.get("bs", PackedByteArray());
		if (bsarr.size() == awecommon::S3B) {
			const uint8_t *bs = bsarr.ptr();
			PackedByteArray ib0 = d.get("i", PackedByteArray());
			const uint8_t *i0 = ib0.ptr();
			int isz0 = (int)ib0.size();
			PackedByteArray pb0 = d.get("p", PackedByteArray());
			const uint8_t *p0 = pb0.ptr();
			int b0 = (int)d.get("b", 0);
			for (int y_in = 0; y_in < 16; y_in++) {
				int fi = y_in * 256;
				for (int t = 0; t < 16; t++) {
					int x = (dx != 0) ? fx : t;
					int z = (dz != 0) ? fz : t;
					int pos = fi + z * 16 + x;
					if (!awecommon::slab_bit(bs, pos)) {
						out[base + y_in * 16 + t] = 0;
						continue;
					}
					out[base + y_in * 16 + t] = (n == 0) ? i0[pos] : p0[awecommon::slab_getbits(i0, isz0, b0, pos)];
				}
			}
			return;
		}
	}
	PackedByteArray ib = d.get("i", PackedByteArray());
	if (n == 0) {
		for (int y_in = 0; y_in < 16; y_in++) {
			int fi = y_in * 256;
			for (int t = 0; t < 16; t++) {
				int x = (dx != 0) ? fx : t;
				int z = (dz != 0) ? fz : t;
				out[base + y_in * 16 + t] = ib[fi + z * 16 + x];
			}
		}
		return;
	}
	int b = (int)d.get("b", 0);
	PackedByteArray pb = d.get("p", PackedByteArray());
	const uint8_t *i = ib.ptr();
	int isize = (int)ib.size();
	const uint8_t *p = pb.ptr();
	for (int y_in = 0; y_in < 16; y_in++) {
		int fi = y_in * 256;
		for (int t = 0; t < 16; t++) {
			int x = (dx != 0) ? fx : t;
			int z = (dz != 0) ? fz : t;
			out[base + y_in * 16 + t] = p[awecommon::slab_getbits(i, isize, b, fi + z * 16 + x)];
		}
	}
}

// One full 16x16 row (all x, fixed y_in) of a paletted slab (null/missing
// = zero row) — the rows_eq 256-B window, decoded exactly like slab_views.
static void slab_row(const Variant &v, int y_in, uint8_t *out) {
	std::fill(out, out + 256, 0);
	if (v.get_type() != Variant::DICTIONARY)
		return;
	Dictionary d = v;
	int n = (int)d.get("n", 0);
	int fi = y_in * 256;
	if (n == 1) {
		PackedByteArray p = d.get("p", PackedByteArray());
		uint8_t val = p.size() > 0 ? p[0] : 0;
		std::fill(out, out + 256, val);
		return;
	}
	PackedByteArray ib = d.get("i", PackedByteArray());
	if (n == 0) {
		int sz = (int)ib.size();
		for (int j = 0; j < 256; j++)
			out[j] = (fi + j < sz) ? ib[fi + j] : 0;
		return;
	}
	int b = (int)d.get("b", 0);
	PackedByteArray pb = d.get("p", PackedByteArray());
	const uint8_t *i = ib.ptr();
	int isize = (int)ib.size();
	const uint8_t *p = pb.ptr();
	for (int j = 0; j < 256; j++)
		out[j] = p[awecommon::slab_getbits(i, isize, b, fi + j)];
}

// Deep-copy a PackedByteArray (a true byte copy — the worker's slab copy
// must not share the live chunk's COW buffer).
static PackedByteArray pba_deep(const PackedByteArray &src) {
	PackedByteArray o;
	o.resize((int)src.size());
	if (src.size() > 0)
		std::memcpy(o.ptrw(), src.ptr(), src.size());
	return o;
}

// AC-0253: per-slab source for the build_accs walk. The HIGH walk needs
// every cell id (the snap stores them) — so the flat view is always
// materialized (exactly the pre-AC-0253 slab_views decode, same cost in
// the same untimed spot). The bitset ("bs") contributes where the id is
// NOT needed: the nz count (the instant all-air early out). The
// bitset-FIRST decode lives in the low emit (low_emit_avg) and the
// neighbor ring (snap_rings), where the ids of the air cells are never
// materialized at all.
struct SlabSrc {
	bool valid = false; // the entry is a dict
	bool empty = true;  // null/missing slab (all air)
	const uint8_t *flat = nullptr;
	int fsize = 0;
	int nz = 0; // the entry's non-air count (== the "bs" bit count)
	inline bool solid(int pos) const {
		return flat != nullptr && pos < fsize && flat[pos] != 0;
	}
	inline uint8_t cell(int pos) const {
		return solid(pos) ? flat[pos] : 0;
	}
};

// One slab array -> SlabSrc row (null slab = empty; every present slab
// materializes its flat view in `flat_store` — the pre-AC-0253 decode).
static void parse_slab_srcs(const Array &arr, std::vector<SlabSrc> &srcs, std::vector<std::vector<uint8_t>> &flat_store) {
	srcs.resize(arr.size());
	flat_store.resize(arr.size());
	for (int k = 0; k < (int)arr.size(); k++) {
		Variant v = arr[k];
		if (v.get_type() != Variant::DICTIONARY)
			continue; // null slab: stays empty/air
		Dictionary d = v;
		SlabSrc &s = srcs[k];
		s.valid = true;
		s.empty = false;
		s.nz = (int)d.get("nz", 0);
		awecommon::slab_view_one(v, flat_store[k]);
		s.flat = flat_store[k].data();
		s.fsize = (int)flat_store[k].size();
		if (s.fsize != awecommon::S3)
			s.empty = true;
	}
}

static void build_snap_data(std::vector<uint8_t> &snap, std::vector<uint8_t> &snap_fl, const std::vector<std::vector<uint8_t>> &dviews, const std::vector<std::vector<uint8_t>> &fviews, const std::vector<SlabSrc> *dsrc, const std::vector<SlabSrc> *fsrc, const Nv &nv, int h, int y_lo, int y_hi) {
	if (y_hi < 0)
		y_hi = h - 1;
	// Own 16x16 (snap ring offset +1). The own-cell read is a DIRECT
	// view load (exactly the pre-AC-0253 cost — the view is always S3
	// bytes or empty).
	for (int y = y_lo; y <= y_hi; y++) {
		size_t si = (size_t)y * SNAP_ROW;
		const SlabSrc *ds = dsrc ? &(*dsrc)[y >> 4] : nullptr;
		const SlabSrc *fs = fsrc ? &(*fsrc)[y >> 4] : nullptr;
		const uint8_t *dp = (ds && !ds->empty) ? ds->flat : nullptr;
		const uint8_t *fp = (fs && !fs->empty) ? fs->flat : nullptr;
		const std::vector<uint8_t> *dview = dp ? nullptr : &dviews[y >> 4];
		const std::vector<uint8_t> *fview = fp ? nullptr : &fviews[y >> 4];
		int drow = (y & 15) << 8;
		for (int lz = 0; lz < SIZE; lz++) {
			int szi = (int)si + (lz + 1) * SNAP_W;
			int r0 = drow + (lz << 4);
			for (int lx = 0; lx < SIZE; lx++) {
				int ci = r0 + lx;
				int dv = dp ? (int)dp[ci] : (dview->empty() ? 0 : (int)(*dview)[ci]);
				size_t sxy = (size_t)szi + lx + 1;
				snap[sxy] = (uint8_t)dv;
				int fv = fp ? (int)fp[ci] : (fview->empty() ? 0 : (int)(*fview)[ci]);
				if (fv == 0 && (dv == 5 || dv == 24))
					fv = 8;
				snap_fl[sxy] = (uint8_t)fv;
			}
		}
	}
	// The 4 EDGE-neighbor rings (the skip condition keeps (±1,0)/(0,±1));
	// the 4 corner ring cells (0,0)/(17,0)/(17,17)/(0,17) stay 0 — the
	// GDScript never writes them either.
	for (int dx = -1; dx <= 1; dx++) {
		for (int dz = -1; dz <= 1; dz++) {
			if ((dx == 0) == (dz == 0))
				continue;
			int ki = nv_ki(dx, dz);
			const std::vector<std::vector<uint8_t>> &ndv = nv.nd[ki];
			const std::vector<std::vector<uint8_t>> &nfdv = nv.nfd[ki];
			Band xb = band(dx);
			Band zb = band(dz);
			for (int y = y_lo; y <= y_hi; y++) {
				size_t si = (size_t)y * SNAP_ROW;
				const std::vector<uint8_t> &nd = (y >> 4) < (int)ndv.size() ? ndv[y >> 4] : std::vector<uint8_t>();
				const std::vector<uint8_t> &nfd = (y >> 4) < (int)nfdv.size() ? nfdv[y >> 4] : std::vector<uint8_t>();
				int drow = (y & 15) << 8;
				for (int e = 0; e < zb.n; e++) {
					int szi = (int)si + zb.x[e] * SNAP_W;
					int r0 = drow + (zb.g[e] << 4);
					for (int g2 = 0; g2 < xb.n; g2++) {
						int sxy = szi + xb.x[g2];
						int dv;
						int fv;
						if (nd.size() == 256) {
							// AC-0211 compact ring (the 16x16 boundary
							// slice): index = y_in*16 + t, t = z (dx edge:
							// e) / x (dz edge: g2) — the same cell the
							// full-layout read (r0 + gi) addresses.
							int t = (dx != 0) ? e : g2;
							int ci = (y & 15) * 16 + t;
							dv = nd.empty() ? 0 : (int)nd[ci];
							fv = nfd.empty() ? 0 : (int)nfd[ci];
						} else {
							int gi = xb.g[g2];
							dv = nd.empty() ? 0 : (int)nd[r0 + gi];
							fv = nfd.empty() ? 0 : (int)nfd[r0 + gi];
						}
						if (fv == 0 && (dv == 5 || dv == 24))
							fv = 8;
						snap[(size_t)sxy] = (uint8_t)dv;
						snap_fl[(size_t)sxy] = (uint8_t)fv;
					}
				}
			}
		}
	}
}

// ---------------------------------------------------------------------------
// _bake_box (chunk.gd:1999) — 20x20x(rows); the core 16x16 at (2,2) from
// the light arr + the eff strips (sides 2 cols x 16 x h, corners 4 x h).
// The corner writes keep the GDScript write ORDER (the dst corner cell has
// no row offset — every y overwrites it, y_hi last wins) — byte-exact.
// ---------------------------------------------------------------------------

static void bake_box(const Dictionary &light, const StripSet &eff_strips, int h, int y_lo, int y_hi, std::vector<uint8_t> &out_arr, Vector3i &out_mn) {
	int w = 20;
	if (y_hi < 0)
		y_hi = h - 1;
	int rows = y_hi - y_lo + 1;
	out_arr.assign((size_t)w * w * rows, 0);
	Vector3i mn(-2, y_lo, -2);
	if (light.is_empty()) {
		out_mn = mn;
		return;
	}
	Vector3i lmn = (Vector3i)light.get("mn", Vector3i(0, 0, 0));
	PackedByteArray arrc = light.get("arr", PackedByteArray());
	int lwc = (int)light.get("w", 16);
	int ldc = (int)light.get("d", 16);
	mn = Vector3i(lmn.x - 2, y_lo, lmn.z - 2);
	// Defensive: a valid light always carries a full sz*h arr (the GDScript
	// would index-error on a short one); read 0 where it would have crashed.
	const uint8_t *src = arrc.size() > 0 ? arrc.ptr() : nullptr;
	size_t src_sz = arrc.size();
	for (int y = y_lo; y <= y_hi; y++) {
		size_t src_row = (size_t)y * lwc * ldc;
		int dst_row = (y - y_lo) * w * w;
		for (int bz = 2; bz < 18; bz++) {
			int dst_z = dst_row + bz * w;
			int src_z = (int)src_row + (bz - 2) * lwc;
			for (int bx = 2; bx < 18; bx++) {
				size_t si2 = (size_t)src_z + (bx - 2);
				out_arr[(size_t)dst_z + bx] = (src != nullptr && si2 < src_sz) ? src[si2] : 0;
			}
		}
	}
	if (eff_strips.n >= 8) {
		int c1 = 16 * h;
		int fsize = 2 * 16 * h;
		int csize = 4 * h;
		if (eff_strips.size[0] == fsize) { // E (x=18/19, t = our z)
			for (int y = y_lo; y <= y_hi; y++) {
				int row = (y - y_lo) * w * w;
				int srow = y * 16;
				for (int t = 0; t < 16; t++) {
					out_arr[(size_t)row + (2 + t) * w + 18] = eff_strips.ptr[0][srow + t];
					out_arr[(size_t)row + (2 + t) * w + 19] = eff_strips.ptr[0][c1 + srow + t];
				}
			}
		}
		if (eff_strips.size[1] == fsize) { // W (x=1/0)
			for (int y = y_lo; y <= y_hi; y++) {
				int row = (y - y_lo) * w * w;
				int srow = y * 16;
				for (int t = 0; t < 16; t++) {
					out_arr[(size_t)row + (2 + t) * w + 1] = eff_strips.ptr[1][srow + t];
					out_arr[(size_t)row + (2 + t) * w + 0] = eff_strips.ptr[1][c1 + srow + t];
				}
			}
		}
		if (eff_strips.size[2] == fsize) { // S (z=18/19)
			for (int y = y_lo; y <= y_hi; y++) {
				int row = (y - y_lo) * w * w;
				int srow = y * 16;
				for (int t = 0; t < 16; t++) {
					out_arr[(size_t)row + 18 * w + (2 + t)] = eff_strips.ptr[2][srow + t];
					out_arr[(size_t)row + 19 * w + (2 + t)] = eff_strips.ptr[2][c1 + srow + t];
				}
			}
		}
		if (eff_strips.size[3] == fsize) { // N (z=1/0)
			for (int y = y_lo; y <= y_hi; y++) {
				int row = (y - y_lo) * w * w;
				int srow = y * 16;
				for (int t = 0; t < 16; t++) {
					out_arr[(size_t)row + 1 * w + (2 + t)] = eff_strips.ptr[3][srow + t];
					out_arr[(size_t)row + 0 * w + (2 + t)] = eff_strips.ptr[3][c1 + srow + t];
				}
			}
		}
		if (eff_strips.size[4] == csize) { // SE (bx,bz = 18+a,18+b; a = x-depth, b = z-depth)
			for (int a = 0; a < 2; a++)
				for (int b = 0; b < 2; b++)
					for (int y = y_lo; y <= y_hi; y++)
						out_arr[(size_t)(18 + b) * w + (18 + a)] = eff_strips.ptr[4][(a * 2 + b) * h + y];
		}
		if (eff_strips.size[5] == csize) { // SW (bx = 1-a, bz = 18+b)
			for (int a = 0; a < 2; a++)
				for (int b = 0; b < 2; b++)
					for (int y = y_lo; y <= y_hi; y++)
						out_arr[(size_t)(18 + b) * w + (1 - a)] = eff_strips.ptr[5][(a * 2 + b) * h + y];
		}
		if (eff_strips.size[6] == csize) { // NE (bx = 18+a, bz = 1-b)
			for (int a = 0; a < 2; a++)
				for (int b = 0; b < 2; b++)
					for (int y = y_lo; y <= y_hi; y++)
						out_arr[(size_t)(1 - b) * w + (18 + a)] = eff_strips.ptr[6][(a * 2 + b) * h + y];
		}
		if (eff_strips.size[7] == csize) { // NW (bx = 1-a, bz = 1-b)
			for (int a = 0; a < 2; a++)
				for (int b = 0; b < 2; b++)
					for (int y = y_lo; y <= y_hi; y++)
						out_arr[(size_t)(1 - b) * w + (1 - a)] = eff_strips.ptr[7][(a * 2 + b) * h + y];
		}
	}
	out_mn = mn;
}

// ---------------------------------------------------------------------------
// Face record collection (chunk.gd:1184/1206/732/1172).
// ---------------------------------------------------------------------------

// _s_faces: the 6-face exposure test (skip solid neighbors; same-id is
// culled for OPAQUE blocks only - AC-0111: cutout/cross blocks stay
// see-through, so a leaf's faces toward its leaf neighbors are emitted
// and a cluster interior is visible through the cutout holes).
static void s_faces(std::vector<FRec> &recs, const uint8_t *stab, int lx, int y, int lz, int id, const std::vector<uint8_t> &snap, int h, const uint8_t *ktab, const uint8_t *xtab) {
	int sxi = (lz + 1) * SNAP_W + (lx + 1);
	for (int fi = 0; fi < 6; fi++) {
		int ny = y + FN[fi][1];
		int nb;
		if (ny < 0 || ny >= h) {
			nb = 0;
		} else {
			nb = snap[(size_t)ny * SNAP_ROW + sxi + FN[fi][2] * SNAP_W + FN[fi][0]];
		}
		if (nb == id && ktab[id] == 0 && xtab[id] == 0)
			continue;
		if (stab[nb] > 0)
			continue;
		int fni = 0;
		if (fi == 2)
			fni = 1;
		else if (fi == 3)
			fni = 2;
		recs.push_back(FRec{lx, y, lz, fi, id, fni});
	}
}

// _fluid_hgt: the fluid fill height (lvl/8.0 — exact; -1 when dry).
// (The GDScript _s_fluid_quad_count budget is a pre-size only — no effect
// on the emitted quads, so it is not ported.)
static inline float fluid_hgt(int lx, int y, int lz, const std::vector<uint8_t> &snap_fl) {
	int rowl = (lz + 1) * SNAP_W + (lx + 1);
	int lvl = snap_fl[(size_t)y * SNAP_ROW + rowl];
	if (lvl <= 0)
		return -1.0f;
	return (float)lvl / 8.0f;
}

// _s_is_interior: 6-neighbor solid test on the snap (y 0/h-1 = never
// interior — the chunk boundary).
static inline bool s_is_interior(int lx, int y, int lz, const std::vector<uint8_t> &snap, const uint8_t *stab, int h) {
	if (y == 0 || y == h - 1)
		return false;
	int mid = (lz + 1) * SNAP_W + (lx + 1);
	int row = y * SNAP_ROW + mid;
	int rowd = (y - 1) * SNAP_ROW + mid;
	int rowu = (y + 1) * SNAP_ROW + mid;
	return stab[snap[(size_t)row - 1]] > 0 && stab[snap[(size_t)row + 1]] > 0 && stab[snap[(size_t)row - SNAP_W]] > 0 && stab[snap[(size_t)row + SNAP_W]] > 0 && stab[snap[(size_t)rowu]] > 0 && stab[snap[(size_t)rowd]] > 0;
}

// ---------------------------------------------------------------------------
// Emitters.
// ---------------------------------------------------------------------------

// _s_emit_faces (chunk.gd:1230) — the per-face quad path (the scoped edit
// fast-pass + the non-merged fallback).
static void emit_faces(const std::vector<FRec> &recs, std::vector<Acc> &accs, const Vector3i &lmn, const uint8_t *larr, int lw, int ld, int cx, int cz, bool has_tex, const Ctx &ctx, const uint8_t *xtab, const uint8_t *bmask, int bmask_sz) {
	int h = ctx.h;
	int wx0 = cx * SIZE;
	int wz0 = cz * SIZE;
	UvcCache uvc;
	for (const FRec &r : recs) {
		int lx = r.lx;
		int y = r.y;
		int lz = r.lz;
		int fi = r.fi;
		int id = r.id;
		int fni = r.fni;
		const int n[3] = {FN[fi][0], FN[fi][1], FN[fi][2]};
		Color face_color;
		int face_idx = 0;
		Color tint = ctx.tint_side[id];
		if (fni == 1) {
			face_color = ctx.ct[id];
			face_idx = 1;
			tint = ctx.tint_top[id];
		} else if (fni == 2) {
			face_color = ctx.cb[id];
			face_idx = 2;
			tint = ctx.tint_bottom[id];
		} else {
			face_color = ctx.cs[id];
		}
		if (xtab[id] > 0) {
			face_idx = 0;
			tint = ctx.tint_side[id];
		}
		float sl = s_face_light(id, wx0 + lx, y, wz0 + lz, n, lmn, larr, lw, ld, h);
		int mask = face_mask(id, wx0 + lx, y, wz0 + lz, n, lmn, h, bmask, bmask_sz);
		Color c = light_color(sl, FSH[fi], mask, face_color, has_tex);
		if (has_tex)
			c = mul_cc(c, tint);
		const float *uvs = s_uvc(uvc, ctx, id, fi, face_idx);
		Acc &sa = accs[y / 16];
		qwrite(sa, c, n, uvs, FCV[fi], lx, y, lz, FCV[fi][0][1], FCV[fi][1][1], FCV[fi][2][1], FCV[fi][3][1]);
	}
}

// _merge_strip (chunk.gd:813): the merge-atlas strip rect for (id, face),
// or (-1,-1) (plain atlas).
static inline Vector2i merge_strip(const Ms &ms, int id, int fni) {
	int face_idx = 0;
	if (fni == 1)
		face_idx = 1;
	else if (fni == 2)
		face_idx = 2;
	return ms.rects[id][face_idx];
}

// _s_qwrite_merged (chunk.gd:1284) — one MERGED quad: the per-face
// px/py/pz/uu/vv formulas + the strip/plain-rect UV (the ms_h split lives
// only here — v / ms_h).
struct MergedCell {
	int id;
	int fni;
	float shade;
	float s;
	int mask;
	int u0;
	int v0;
	int plane;
};

static void qwrite_merged(Acc &acc, int fi, const int n[3], const MergedCell &c0, int W, int H, bool has_tex, const Ctx &ctx, const Vector2i &sr, float ms_h) {
	int id = c0.id;
	int fni = c0.fni;
	int mask = c0.mask;
	float s = c0.s;
	int u0 = c0.u0;
	int v0 = c0.v0;
	int plane = c0.plane;
	Color face_color = ctx.cs[id];
	Color tint = ctx.tint_side[id];
	int face_idx = 0;
	if (fni == 1) {
		face_color = ctx.ct[id];
		face_idx = 1;
		tint = ctx.tint_top[id];
	} else if (fni == 2) {
		face_color = ctx.cb[id];
		face_idx = 2;
		tint = ctx.tint_bottom[id];
	}
	Color c = light_color(s, FSH[fi], mask, face_color, has_tex);
	if (has_tex)
		c = mul_cc(c, tint);
	const Vector2i &tl = ctx.brect[id][face_idx];
	int b = acc.q * 4;
	acc.ensure(acc.q + 1);
	int ib = acc.q * 6;
	for (int j = 0; j < 4; j++) {
		float cvx = FCV[fi][j][0];
		float cvy = FCV[fi][j][1];
		float cvz = FCV[fi][j][2];
		float px;
		float py;
		float pz;
		float uu;
		float vv;
		if (fi == 2) {
			px = (float)u0 + cvx * (float)W;
			py = (float)plane + 1.0f;
			pz = (float)v0 + cvz * (float)H;
			uu = 0.5f + cvx * (float)W * ctx.ppb;
			vv = 0.5f + cvz * (float)H * ctx.ppb;
		} else if (fi == 3) {
			px = (float)u0 + cvx * (float)W;
			py = (float)plane;
			pz = (float)v0 + cvz * (float)H;
			uu = 0.5f + cvx * (float)W * ctx.ppb;
			vv = 0.5f + cvz * (float)H * ctx.ppb;
		} else if (fi == 0) {
			px = (float)plane;
			py = (float)v0 + cvy * (float)H;
			pz = (float)u0 + cvz * (float)W;
			uu = 0.5f + cvz * (float)W * ctx.ppb;
			vv = 0.5f + (1.0f - cvy) * (float)H * ctx.ppb;
		} else if (fi == 1) {
			px = (float)plane + 1.0f;
			py = (float)v0 + cvy * (float)H;
			pz = (float)u0 + cvz * (float)W;
			uu = 0.5f + cvz * (float)W * ctx.ppb;
			vv = 0.5f + (1.0f - cvy) * (float)H * ctx.ppb;
		} else if (fi == 4) {
			px = (float)u0 + cvx * (float)W;
			py = (float)v0 + cvy * (float)H;
			pz = (float)plane;
			uu = 0.5f + cvx * (float)W * ctx.ppb;
			vv = 0.5f + (1.0f - cvy) * (float)H * ctx.ppb;
		} else {
			px = (float)u0 + cvx * (float)W;
			py = (float)v0 + cvy * (float)H;
			pz = (float)plane + 1.0f;
			uu = 0.5f + cvx * (float)W * ctx.ppb;
			vv = 0.5f + (1.0f - cvy) * (float)H * ctx.ppb;
		}
		acc.v[(b + j) * 3 + 0] = px;
		acc.v[(b + j) * 3 + 1] = py;
		acc.v[(b + j) * 3 + 2] = pz;
		acc.n[(b + j) * 3 + 0] = (float)n[0];
		acc.n[(b + j) * 3 + 1] = (float)n[1];
		acc.n[(b + j) * 3 + 2] = (float)n[2];
		acc.c[(b + j) * 4 + 0] = c.r;
		acc.c[(b + j) * 4 + 1] = c.g;
		acc.c[(b + j) * 4 + 2] = c.b;
		acc.c[(b + j) * 4 + 3] = c.a;
		float tu;
		float tv;
		if (sr.x != -1 || sr.y != -1) {
			tu = ((float)sr.x + uu) / ctx.atlas_px;
			tv = ((float)sr.y + vv) / ms_h;
		} else if (tl.x < 0) {
			tu = 0.0f;
			tv = 0.0f;
		} else {
			float cu;
			float cvv;
			if (fi == 2 || fi == 3) {
				cu = cvx;
				cvv = cvz;
			} else if (fi == 0 || fi == 1) {
				cu = cvz;
				cvv = 1.0f - cvy;
			} else {
				cu = cvx;
				cvv = 1.0f - cvy;
			}
			tu = ((float)tl.x + (0.5f + cu * ctx.ppb)) / ctx.atlas_px;
			tv = ((float)tl.y + (0.5f + cvv * ctx.ppb)) / ms_h;
		}
		acc.u[(b + j) * 2 + 0] = tu;
		acc.u[(b + j) * 2 + 1] = tv;
	}
	acc.i[ib + 0] = b;
	acc.i[ib + 1] = b + 2;
	acc.i[ib + 2] = b + 1;
	acc.i[ib + 3] = b;
	acc.i[ib + 4] = b + 3;
	acc.i[ib + 5] = b + 2;
	acc.q += 1;
}

// _s_emit_ro_merged (chunk.gd:1388) — the greedy 2D merge. Grid layout
// per face: fi0/1 plane = lx (strip runs along z), fi2/3 plane = y (3D
// columns survive), fi4/5 plane = lz (strip runs along x). Merge key =
// [id, fni, shade]; growth = width along u (to 16) then height along v
// (to 4, full-width rows — the atlas strips tile 4 rows). The grid cells
// are MergedCell* into a per-face arena (reserved up front so the pointers
// never invalidate).
static void emit_ro_merged(const std::vector<FRec> &recs, std::vector<Acc> &accs, const Vector3i &lmn, const uint8_t *larr, int lw, int ld, int cx, int cz, bool has_tex, const Ctx &ctx, const Ms &ms, const uint8_t *bmask, int bmask_sz) {
	int hgt = ctx.h;
	int wx0 = cx * SIZE;
	int wz0 = cz * SIZE;
	std::vector<MergedCell> cells[6];
	std::vector<MergedCell *> grids[6];
	for (int f = 0; f < 6; f++) {
		cells[f].reserve(recs.size());
		grids[f].assign((size_t)16 * hgt * 16, nullptr);
	}
	for (const FRec &r : recs) {
		const int n[3] = {FN[r.fi][0], FN[r.fi][1], FN[r.fi][2]};
		float sl = s_face_light(r.id, wx0 + r.lx, r.y, wz0 + r.lz, n, lmn, larr, lw, ld, hgt);
		int mask = face_mask(r.id, wx0 + r.lx, r.y, wz0 + r.lz, n, lmn, hgt, bmask, bmask_sz);
		float shade = FSH[r.fi] * sl;
		int fi = r.fi;
		size_t idx;
		if (fi == 2 || fi == 3)
			idx = (size_t)r.y * 256 + r.lz * 16 + r.lx;
		else if (fi == 0 || fi == 1)
			idx = (size_t)r.lx * (hgt * 16) + r.y * 16 + r.lz;
		else
			idx = (size_t)r.lz * (hgt * 16) + r.y * 16 + r.lx;
		cells[fi].push_back(MergedCell{r.id, r.fni, shade, sl, mask, 0, 0, 0});
		MergedCell &cell = cells[fi].back();
		if (fi == 2 || fi == 3) {
			cell.u0 = r.lx;
			cell.v0 = r.lz;
			cell.plane = r.y;
		} else if (fi == 0 || fi == 1) {
			cell.u0 = r.lz;
			cell.v0 = r.y;
			cell.plane = r.lx;
		} else {
			cell.u0 = r.lx;
			cell.v0 = r.y;
			cell.plane = r.lz;
		}
		grids[fi][idx] = &cell;
	}
	for (int fi = 0; fi < 6; fi++) {
		const int n[3] = {FN[fi][0], FN[fi][1], FN[fi][2]};
		bool horiz = (fi == 2 || fi == 3);
		int pmax = horiz ? hgt : 16;
		int vmax = horiz ? 16 : hgt;
		int pstride = vmax * 16;
		std::vector<MergedCell *> &g = grids[fi];
		for (int plane = 0; plane < pmax; plane++) {
			int pi = plane * pstride;
			for (int v0 = 0; v0 < vmax; v0++) {
				int vi = pi + v0 * 16;
				for (int u0 = 0; u0 < 16; u0++) {
					MergedCell *c0 = g[vi + u0];
					if (c0 == nullptr)
						continue;
					int w = 1;
					while (u0 + w < 16) {
						MergedCell *cn = g[vi + (u0 + w)];
						if (cn == nullptr || cn->id != c0->id || cn->fni != c0->fni || cn->shade != c0->shade)
							break;
						w += 1;
						g[vi + (u0 + w - 1)] = nullptr;
					}
					int h = 1;
					while (h < 4 && v0 + h < vmax) {
						bool vmatch = true;
						for (int u = u0; u < u0 + w; u++) {
							MergedCell *cc = g[vi + h * 16 + u];
							if (cc == nullptr || cc->id != c0->id || cc->fni != c0->fni || cc->shade != c0->shade) {
								vmatch = false;
								break;
							}
						}
						if (!vmatch)
							break;
						for (int u = u0; u < u0 + w; u++)
							g[vi + h * 16 + u] = nullptr;
						h += 1;
					}
					g[vi + u0] = nullptr;
					int si = (fi == 0 || fi == 1 || fi == 4 || fi == 5) ? (c0->v0 / 16) : (c0->plane / 16);
					qwrite_merged(accs[si], fi, n, *c0, w, h, has_tex, ctx, merge_strip(ms, c0->id, c0->fni), ms.h);
				}
			}
		}
	}
}

// _s_emit_fluid (chunk.gd:1509) — top/sides/bottom fluid quads with the
// height-clipped corners (hgt where the corner sits on the surface, else
// the neighbor's height hn).
static void emit_fluid(const std::vector<FluidRec> &recs, std::vector<Acc> &accs, const std::vector<uint8_t> &snap, const std::vector<uint8_t> &snap_fl, bool has_tex, const Ctx &ctx, int h) {
	UvcCache uvc;
	for (const FluidRec &r : recs) {
		int lx = r.lx;
		int y = r.y;
		int lz = r.lz;
		int id = r.id;
		float hgt = r.hgt;
		Acc &sa = accs[y / 16];
		int rowl = (lz + 1) * SNAP_W + (lx + 1);
		const Color &tint_t = ctx.tint_top[id];
		const Color &tint_s = ctx.tint_side[id];
		const Color &tint_b = ctx.tint_bottom[id];
		int above = 0;
		if (y + 1 < h)
			above = snap[(size_t)(y + 1) * SNAP_ROW + rowl];
		// AC-0245 follow-up (2026-09-09): emit a fluid face toward a neighbor
		// only when that neighbor does NOT already render an opaque face there
		// (stab>0 = solid occluder, same rule as s_faces for opaque blocks).
		// The AC-0245 cull_disabled made both sides of every fluid face
		// visible, so the faces against solid neighbors (the lake floor,
		// underwater cliffs) render exactly on top of the opaque terrain and
		// z-fight (camera-motion-dependent "moving shadows" on water-covered
		// terrain). Faces toward air/transparent neighbors are kept, so the
		// water surface + edges stay visible from every side.
		if (above != id && ctx.stab[above] == 0) {
			float top_h = std::min(hgt, (id == 5) ? 0.875f : 0.95f);
			Color c = has_tex ? mul_cc(Color(0.95f, 0.95f, 0.95f, 1.0f), tint_t) : mul_cf(ctx.ct[id], 0.95f);
			const float *uvs = s_uvc(uvc, ctx, id, 2, 1);
			static const int N_TOP[3] = {0, 1, 0};
			qwrite(sa, c, N_TOP, uvs, FCV[2], lx, y, lz, top_h, top_h, top_h, top_h);
		}
		for (int fi : {0, 1, 4, 5}) {
			const int n[3] = {FN[fi][0], FN[fi][1], FN[fi][2]};
			int nb = snap[(size_t)y * SNAP_ROW + rowl + n[2] * SNAP_W + n[0]];
			if (ctx.stab[nb] > 0)
				continue; // AC-0245 follow-up: solid neighbor has its own face
			float hn = 0.0f;
			if (nb == id)
				hn = (float)snap_fl[(size_t)y * SNAP_ROW + rowl + n[2] * SNAP_W + n[0]] / 8.0f;
			if (hn >= hgt)
				continue;
			Color c = has_tex ? mul_cc(Color(0.85f, 0.85f, 0.85f, 1.0f), tint_s) : mul_cf(ctx.cs[id], 0.85f);
			const float *uvs = s_uvc(uvc, ctx, id, fi, 0);
			float py0 = FCV[fi][0][1] == 1.0f ? hgt : hn;
			float py1 = FCV[fi][1][1] == 1.0f ? hgt : hn;
			float py2 = FCV[fi][2][1] == 1.0f ? hgt : hn;
			float py3 = FCV[fi][3][1] == 1.0f ? hgt : hn;
			qwrite(sa, c, n, uvs, FCV[fi], lx, y, lz, py0, py1, py2, py3);
		}
		int below = 0;
		if (y > 0)
			below = snap[(size_t)(y - 1) * SNAP_ROW + rowl];
		if (y > 0 && below != id && ctx.stab[below] == 0) {
			Color c = has_tex ? mul_cc(Color(0.6f, 0.6f, 0.6f, 1.0f), tint_b) : mul_cf(ctx.cb[id], 0.6f);
			const float *uvs = s_uvc(uvc, ctx, id, 3, 2);
			static const int N_BOT[3] = {0, -1, 0};
			qwrite(sa, c, N_BOT, uvs, FCV[3], lx, y, lz, 0.0f, 0.0f, 0.0f, 0.0f);
		}
	}
}

// _s_emit_xquad (chunk.gd:1470) — the flora/cross 2-quad emit (XQ_A/XQ_B,
// the top-face UVs at ppb 31.0 — the DEFAULT, not the ctx ppb).
static void emit_xquad(const std::vector<XRec> &recs, std::vector<Acc> &accs, const Vector3i &lmn, const uint8_t *larr, int lw, int ld, int cx, int cz, bool has_tex, const Ctx &ctx, const uint8_t *bmask, int bmask_sz) {
	int h = ctx.h;
	int wx0 = cx * SIZE;
	int wz0 = cz * SIZE;
	// per-call uvc: key id*8+2 -> [u0(4), u1(4)]
	std::unordered_map<int, std::array<float, 16>> uvc;
	for (const XRec &r : recs) {
		int lx = r.lx;
		int y = r.y;
		int lz = r.lz;
		int id = r.id;
		float s = clampf((float)s_effl(lmn, larr, lw, ld, wx0 + lx, y, wz0 + lz, h) / 15.0f, MIN_AMB, 1.0f);
		int mask = mask_sample(wx0 + lx, y, wz0 + lz, lmn, h, bmask, bmask_sz);
		Color c;
		if (has_tex)
			c = mul_cc(light_color(s, 0.9f, mask, Color(1.0f, 1.0f, 1.0f, 1.0f), true), ctx.tint_top[id]);
		else
			c = mul_cf(ctx.ct[id], 0.9f);
		int ukey = id * 8 + 2;
		auto it = uvc.find(ukey);
		if (it == uvc.end()) {
			const Vector2i &tl = ctx.brect[id][1];
			std::array<float, 16> out;
			static const int N_A[3] = {0, 0, 1};
			static const int N_B[3] = {1, 0, 0};
			for (int i = 0; i < 4; i++) {
				s_corner_uv(XQ_A[i][0], XQ_A[i][1], XQ_A[i][2], N_A, tl, ctx.atlas_px, 31.0f, &out[i * 2], &out[i * 2 + 1]);
				s_corner_uv(XQ_B[i][0], XQ_B[i][1], XQ_B[i][2], N_B, tl, ctx.atlas_px, 31.0f, &out[8 + i * 2], &out[8 + i * 2 + 1]);
			}
			uvc[ukey] = out;
			it = uvc.find(ukey);
		}
		Acc &sa = accs[y / 16];
		static const int N_A[3] = {0, 0, 1};
		static const int N_B[3] = {1, 0, 0};
		qwrite(sa, c, N_A, it->second.data(), XQ_A, lx, y, lz, 0.0f, 0.0f, 1.0f, 1.0f);
		qwrite(sa, c, N_B, it->second.data() + 8, XQ_B, lx, y, lz, 0.0f, 0.0f, 1.0f, 1.0f);
	}
}

// ---------------------------------------------------------------------------
// build_accs (chunk.gd:1683) — the full pipeline.
// ---------------------------------------------------------------------------

static PackedVector3Array pv3_from(const std::vector<float> &v, int count) {
	PackedVector3Array out;
	out.resize(count);
	if (count > 0)
		std::memcpy(reinterpret_cast<uint8_t *>(out.ptrw()), v.data(), (size_t)count * 3 * sizeof(float));
	return out;
}

static PackedVector2Array pv2_from(const std::vector<float> &u, int count) {
	PackedVector2Array out;
	out.resize(count);
	if (count > 0)
		std::memcpy(reinterpret_cast<uint8_t *>(out.ptrw()), u.data(), (size_t)count * 2 * sizeof(float));
	return out;
}

static PackedColorArray pca_from(const std::vector<float> &c, int count) {
	PackedColorArray out;
	out.resize(count);
	if (count > 0)
		std::memcpy(reinterpret_cast<uint8_t *>(out.ptrw()), c.data(), (size_t)count * 4 * sizeof(float));
	return out;
}

static PackedInt32Array pi32_from(const std::vector<int32_t> &i, int count) {
	PackedInt32Array out;
	out.resize(count);
	if (count > 0)
		std::memcpy(out.ptrw(), i.data(), (size_t)count * sizeof(int32_t));
	return out;
}

static Dictionary acc_to_dict(const Acc &a) {
	Dictionary d;
	int q4 = a.q * 4;
	int q6 = a.q * 6;
	d["v"] = pv3_from(a.v, q4);
	d["n"] = pv3_from(a.n, q4);
	d["c"] = pca_from(a.c, q4);
	d["u"] = pv2_from(a.u, q4);
	d["i"] = pi32_from(a.i, q6);
	d["q"] = (int64_t)a.q;
	return d;
}

static inline int64_t now_msec() {
	return (int64_t)Time::get_singleton()->get_ticks_msec();
}

// ---------------------------------------------------------------------------
// AC-0236 part 2: the low placeholder EMIT — the worker-side port of
// world.gd _low_slab_grid x3 + _low_neighbor_id + _low_emit_slab (the
// textured low's 4x4x4 grid + greedy mesh). The node ATTACH stays on the
// main thread (Godot SceneTree — world.gd _low_place_slab via the
// _low_handoff branch). Worker-safe: reads only the value-copied slab
// array + the immutable ms snapshot (the same AC-0082 pattern as
// build_accs).
//
// Grid: 4x4x4 coarse cells per slab (a cell = 4x4x4 blocks), ONE sample
// per cell at its center (local (4sx+2, 4sy+2, 4sz+2)); layout
// x + z*4 + y*16. Emit: per face, the (pu,pv) line is scanned FROM THE
// VIEWING SIDE (the side the face normal points at) inward and keeps the
// FIRST solid cell — its face shows only when the neighbor (the grid, the
// slab above/below across the coarse boundary, or air off the column) has
// a DIFFERENT id; merge key = id*16+(k+1) (same id AND same outermost
// plane only — mesh.cpp's emit_ro_merged plane discipline); greedy W
// along u, H = 1 (a v span above 4 blocks would sample outside the
// 4-row merged strip); STRIP quads tile 31px per WORLD BLOCK, PLAIN
// quads sample exactly ONE 32px tile (31px span, the plain branch);
// vertices are SLAB-LOCAL 0..16; color = (1.0, 0.0, sh, 1.0).
//
// ms: {rects: {"id_face": Vector2i} (the merged-atlas STRIP rects, from
// _tm_ms_full.rects), plain: {str(id): {face: [x,y,w,h]}} (the ORIGINAL
// atlas = Data.atlas_rects — the no-strip fallback _low_tile_base reads),
// h: the merged canvas height, atlas_px: the original atlas width}.
// Returns {empty: true} when the slab samples all-air, else
// {v, n, c, u, i, mh} (mh = the mesh AABB height, the low_max_h feed).
// ---------------------------------------------------------------------------

static Dictionary low_emit_impl(const Array &p_slabs, int si, const Dictionary &ms) {
	Dictionary res;
	const int G = 4; // LOW_GRID
	const float CELL = 4.0f; // LOW_CELL_BLOCKS

	// --- the tile tables (the _low_tile_base port: strip first, then the
	// original-atlas plain rect; neither = no tile (UV zero, has_tl false))
	Vector2i strip[256][3];
	Vector2i plain[256][3];
	bool strip_ok[256][3];
	bool plain_ok[256][3];
	for (int id = 0; id < 256; id++) {
		for (int f = 0; f < 3; f++) {
			strip[id][f] = Vector2i(-1, -1);
			plain[id][f] = Vector2i(-1, -1);
			strip_ok[id][f] = false;
			plain_ok[id][f] = false;
		}
	}
	static const char *fnames[3] = {"side", "top", "bottom"};
	Dictionary rects = ms.get("rects", Dictionary());
	if (!rects.is_empty()) {
		Array keys = rects.keys();
		for (int k = 0; k < (int)keys.size(); k++) {
			String ks = keys[k];
			int id = 0;
			int f = 0;
			if (!parse_rect_key(ks, id, f) || id < 0 || id > 255)
				continue;
			Vector2i r = (Vector2i)rects.get(ks, Vector2i(-1, -1));
			if (r.x >= 0) {
				strip[id][f] = r;
				strip_ok[id][f] = true;
			}
		}
	}
	Dictionary pl = ms.get("plain", Dictionary());
	if (!pl.is_empty()) {
		Array pkeys = pl.keys();
		for (int k = 0; k < (int)pkeys.size(); k++) {
			String ks = pkeys[k];
			int id = (int)ks.to_int();
			if (id < 0 || id > 255)
				continue;
			Dictionary e = pl.get(ks, Dictionary());
			for (int f = 0; f < 3; f++) {
				Array r = (Array)e.get(fnames[f], Array());
				if (r.size() == 4) {
					int x = (int)(int64_t)(float)r[0];
					int y = (int)(int64_t)(float)r[1];
					if (x >= 0) {
						plain[id][f] = Vector2i(x, y);
						plain_ok[id][f] = true;
					}
				}
			}
		}
	}
	float atlas_px = (float)ms.get("atlas_px", 1024.0f);
	float hms = (float)ms.get("h", atlas_px);

	// --- the three 4x4x4 grids (si-1 / si / si+1; the slab-boundary
	// culling reads across them) — slab_views decodes the paletted slabs
	// in C++ (null slab = empty view = air).
	int nsl = (int)p_slabs.size();
	std::vector<std::vector<uint8_t>> views;
	awecommon::slab_views(p_slabs, views);
	uint8_t grids[3][G * G * G];
	int gsi[3] = {si - 1, si, si + 1};
	bool ghave[3] = {false, false, false};
	for (int t = 0; t < 3; t++) {
		memset(grids[t], 0, sizeof(grids[t]));
		int s = gsi[t];
		if (s < 0 || s >= nsl || (int)views[s].size() != awecommon::S3)
			continue;
		const uint8_t *v = views[s].data();
		for (int sy = 0; sy < G; sy++) {
			for (int sz = 0; sz < G; sz++) {
				for (int sx = 0; sx < G; sx++) {
					grids[t][sy * G * G + sz * G + sx] = v[(4 * sy + 2) * 256 + (4 * sz + 2) * 16 + (4 * sx + 2)];
				}
			}
		}
		ghave[t] = true;
	}
	bool any = false;
	for (int i = 0; i < G * G * G; i++) {
		if (grids[1][i] != 0) {
			any = true;
			break;
		}
	}
	if (!any) {
		res["empty"] = true;
		return res;
	}
	// the _low_neighbor_id port: in-grid -> the grid; across the slab
	// boundary -> the neighbor slab's grid edge row; off the column -> air.
	auto neighbor_id = [&](int ix, int iy, int iz, int nax, const int n[3]) -> int {
		if (nax == 0) {
			int nx = ix + n[0];
			if (nx < 0 || nx >= G)
				return 0;
			return grids[1][nx + iz * G + iy * G * G];
		}
		if (nax == 2) {
			int nz = iz + n[2];
			if (nz < 0 || nz >= G)
				return 0;
			return grids[1][ix + nz * G + iy * G * G];
		}
		int ny = iy + n[1];
		if (ny < 0 || ny >= G) {
			int gsi2 = si + n[1];
			int t2 = gsi2 == si + 1 ? 2 : 0;
			if (gsi2 < 0 || gsi2 >= nsl || !ghave[t2])
				return 0;
			int gyb = n[1] > 0 ? 0 : G - 1;
			return grids[t2][ix + iz * G + gyb * G * G];
		}
		return grids[1][ix + iz * G + ny * G * G];
	};

	// --- the 6-face shell scan + greedy merge (the _low_emit_slab port;
	// the face tables FN/FSH/FCV are VoxelMath.FACES verbatim above).
	const int UA[6] = {2, 2, 0, 0, 0, 0};
	const int VA[6] = {1, 1, 2, 2, 1, 1};
	std::vector<float> av;
	std::vector<float> an;
	std::vector<float> ac;
	std::vector<float> au;
	std::vector<int32_t> ai;
	float y_min = 1e9f;
	float y_max = -1e9f;
	av.reserve(6 * 4 * 4 * 4 * 3);
	an.reserve(6 * 4 * 4 * 4 * 3);
	ac.reserve(6 * 4 * 4 * 4 * 4);
	au.reserve(6 * 4 * 4 * 4 * 2);
	ai.reserve(6 * 4 * 4 * 4 * 6);
	for (int fi = 0; fi < 6; fi++) {
		int nax = FN[fi][0] != 0 ? 0 : (FN[fi][1] != 0 ? 1 : 2);
		int ua = UA[fi];
		int va = VA[fi];
		int ns = nax == 0 ? FN[fi][0] : (nax == 1 ? FN[fi][1] : FN[fi][2]);
		int m[G][G];
		int kmap[G][G];
		for (int pv = 0; pv < G; pv++) {
			for (int pu = 0; pu < G; pu++) {
				int cc[3] = {0, 0, 0};
				cc[ua] = pu;
				cc[va] = pv;
				int idv = -1;
				int kk = 0;
				int k = ns > 0 ? G - 1 : 0;
				while (kk < G) {
					cc[nax] = k;
					int idx = cc[0] + cc[2] * G + cc[1] * G * G;
					int idc = grids[1][idx];
					if (idc != 0) {
						if (neighbor_id(cc[0], cc[1], cc[2], nax, FN[fi]) != idc)
							idv = idc;
						break;
					}
					k += ns > 0 ? -1 : 1;
					kk += 1;
				}
				m[pv][pu] = idv >= 0 ? idv * 16 + (k + 1) : -1;
				kmap[pv][pu] = k;
			}
		}
		for (int pv = 0; pv < G; pv++) {
			int pu = 0;
			while (pu < G) {
				int key2 = m[pv][pu];
				if (key2 < 0) {
					pu += 1;
					continue;
				}
				int idv2 = key2 / 16;
				int W = 1;
				while (pu + W < G && m[pv][pu + W] == key2)
					W += 1;
				int H = 1; // the v span cap is ONE coarse cell (4 blocks)
				int cc0[3] = {0, 0, 0};
				cc0[ua] = pu;
				cc0[va] = pv;
				cc0[nax] = kmap[pv][pu];
				float wx = cc0[0] * CELL;
				float wy = cc0[1] * CELL;
				float wz = cc0[2] * CELL;
				if (nax == 0)
					wx += FN[fi][0] > 0 ? CELL : 0.0f;
				else if (nax == 1)
					wy += FN[fi][1] > 0 ? CELL : 0.0f;
				else
					wz += FN[fi][2] > 0 ? CELL : 0.0f;
				int fidx = fi == 2 ? 1 : (fi == 3 ? 2 : 0);
				Vector2i tl(-1, -1);
				bool is_strip = false;
				if (strip_ok[idv2][fidx]) {
					tl = strip[idv2][fidx];
					is_strip = true;
				} else if (plain_ok[idv2][fidx]) {
					tl = plain[idv2][fidx];
				}
				bool has_tl = tl.x >= 0;
				float su = is_strip ? (float)W * CELL * 31.0f : 31.0f;
				float sv = is_strip ? (float)H * CELL * 31.0f : 31.0f;
				float sh = FSH[fi];
				int cb = (int)av.size() / 3;
				for (int j = 0; j < 4; j++) {
					float cvx = FCV[fi][j][0];
					float cvy = FCV[fi][j][1];
					float cvz = FCV[fi][j][2];
					float px = wx;
					float py = wy;
					float pz = wz;
					float uu;
					float vv;
					if (fi == 0 || fi == 1) { // u = z (W cells), v = y (H cells)
						py = wy + cvy * (float)H * CELL;
						pz = wz + cvz * (float)W * CELL;
						uu = 0.5f + cvz * su;
						vv = 0.5f + (1.0f - cvy) * sv;
					} else if (fi == 2 || fi == 3) { // u = x (W cells), v = z (H cells)
						px = wx + cvx * (float)W * CELL;
						pz = wz + cvz * (float)H * CELL;
						uu = 0.5f + cvx * su;
						vv = 0.5f + cvz * sv;
					} else { // fi 4/5: u = x (W cells), v = y (H cells)
						px = wx + cvx * (float)W * CELL;
						py = wy + cvy * (float)H * CELL;
						uu = 0.5f + cvx * su;
						vv = 0.5f + (1.0f - cvy) * sv;
					}
					av.push_back(px);
					av.push_back(py);
					av.push_back(pz);
					if (py < y_min)
						y_min = py;
					if (py > y_max)
						y_max = py;
					an.push_back((float)FN[fi][0]);
					an.push_back((float)FN[fi][1]);
					an.push_back((float)FN[fi][2]);
					ac.push_back(1.0f);
					ac.push_back(0.0f);
					ac.push_back(sh);
					ac.push_back(1.0f);
					if (has_tl) {
						au.push_back(((float)tl.x + uu) / atlas_px);
						au.push_back(((float)tl.y + vv) / hms);
					} else {
						au.push_back(0.0f);
						au.push_back(0.0f);
					}
				}
				ai.push_back(cb);
				ai.push_back(cb + 2);
				ai.push_back(cb + 1);
				ai.push_back(cb);
				ai.push_back(cb + 3);
				ai.push_back(cb + 2);
				for (int v2 = pv; v2 < pv + H; v2++) {
					for (int u2 = pu; u2 < pu + W; u2++)
						m[v2][u2] = -1;
				}
				pu += W;
			}
		}
	}
	if (av.empty()) {
		res["empty"] = true;
		return res;
	}
	PackedVector3Array pv3;
	pv3.resize((int)av.size() / 3);
	for (int i = 0; i < (int)av.size() / 3; i++)
		pv3[i] = Vector3(av[i * 3], av[i * 3 + 1], av[i * 3 + 2]);
	PackedVector3Array pn3;
	pn3.resize((int)an.size() / 3);
	for (int i = 0; i < (int)an.size() / 3; i++)
		pn3[i] = Vector3(an[i * 3], an[i * 3 + 1], an[i * 3 + 2]);
	PackedColorArray pcol;
	pcol.resize((int)ac.size() / 4);
	for (int i = 0; i < (int)ac.size() / 4; i++)
		pcol[i] = Color(ac[i * 4], ac[i * 4 + 1], ac[i * 4 + 2], ac[i * 4 + 3]);
	PackedVector2Array puv;
	puv.resize((int)au.size() / 2);
	for (int i = 0; i < (int)au.size() / 2; i++)
		puv[i] = Vector2(au[i * 2], au[i * 2 + 1]);
	PackedInt32Array pidx;
	pidx.resize((int)ai.size());
	for (int i = 0; i < (int)ai.size(); i++)
		pidx[i] = ai[i];
	res["v"] = pv3;
	res["n"] = pn3;
	res["c"] = pcol;
	res["u"] = puv;
	res["i"] = pidx;
	res["mh"] = y_max - y_min;
	return res;
}

// ---------------------------------------------------------------------------
// AC-0252: the med/low AVERAGE-COLOR emit — the worker-side port of
// world.gd _avg_slab_grid + _avg_emit_slab (the 8x8x8 MED / 4x4x4 LOW
// tiers). Each slab's FULL 16x16x16 volume is read (4096 ids per slab,
// via the slab views — the whole 16/G block volume of every sample, not
// the old one-point sample): a sample is AIR when MORE THAN HALF its
// volume is air (>=5 of 8 for med, >=33 of 64 for low) and its per-face
// color = the average of the CACHED per-block-face colors (fcc, 256 ids x
// 6 directions x rgb, LINEAR floats — built once per atlas on the main
// thread) over the sample's NON-AIR blocks.
//
// Emit: the same 6-face outermost-shell scan + greedy merge as
// low_emit_impl, but the merge key = the QUANTIZED face color (31 levels
// per channel: (r*1024 + g*32 + b)) x 16 + (plane k + 1) — there is no
// block id to merge on; a face shows only when the neighbor (grid / slab
// above-below via the solid masks / air off the column) is AIR; the v
// span merges same-key strips (one-color quads, coplanar). Vertices are
// SLAB-LOCAL 0..16; the vertex color IS the face color (NO UVs — the
// noise shader material owns the surface).
//
// p_grid = MED_GRID (8) or LOW_GRID (4); p_fcc = the face-color cache
// (value copy in the dispatch entry; the worker-safe immutable snapshot,
// the same AC-0082 pattern as the ms snapshot). The per-block accumulation
// order (cy/cz/cx cells, then py/pz/px) mirrors the GDScript twin's
// float32 op order exactly (-ffp-contract=off: no FMA folding), so the
// outputs are byte-identical (the meshprobe avg_emit A/B).
// Returns {empty: true} when nothing emits, else {v, n, c, i, mh}.
// ---------------------------------------------------------------------------

// AC-0283 P3: p_sky = the per-cell HEIGHTMAP sky light for the slab
// (G*G*G bytes, 0..15 — 15 iff the whole 4x4x4 cell sits strictly above
// the terrain top over its x/z footprint, else 0; the halo band's draw
// light, computed at dispatch from the column heightmap). When present
// (size matches), the QUAD's alpha = its origin cell's sky/15 and the
// lod_avg shader multiplies it into the brightness — the far band is lit
// by the heightmap, not the engine. Empty = the legacy all-bright emit
// (the real band passes nothing — byte-identical output).
// AC-0284b: the SHARED avg-emit tail (defined below) — the slab and far
// emitters both end here (the byte-identity rests on it).
// AC-0312: top_water = the per-cell (G^3, t==1 grid) "topmost non-air
// is water" flag (nullptr = the exception off); wtlx/wtly/w_atlas_px =
// the water atlas top-rect origin + the atlas width in px (wtlx < 0 =
// off) — the +Y faces of water-topped cells emit a SEPARATE water
// surface (the real translucent water material's quad count, one 31-px
// tile per G-block).
static Dictionary avg_grid_emit(int G, float CELL, int si, int nsl,
		uint8_t grids_solid[3][512], const float grids_cols[3][512 * 18],
		const bool ghave[3], uint8_t *top_water,
		const PackedFloat32Array &p_fcc, const PackedByteArray &p_sky,
		int wtlx, int wtly, float w_atlas_px, int p_yfloor);

static Dictionary low_emit_avg_impl(const Array &p_slabs, int si, int p_grid, const PackedFloat32Array &p_fcc, const PackedByteArray &p_sky, int p_wtlx, int p_wtly, float p_w_atlas_px, int p_yfloor) {
	Dictionary res;
	const int G = (p_grid == 4) ? 4 : 8;
	const int CELLB = 16 / G;
	const float CELL = (float)CELLB;
	const int TOT = CELLB * CELLB * CELLB;
	const float *fcc = p_fcc.ptr();
	bool fcc_ok = p_fcc.size() >= 256 * 18;
	// AC-0312: the per-cell water-surface flag (t==1 grid; the tail's
	// +Y scan reads it). 512 = the 8^3 max.
	uint8_t top_water[512];
	memset(top_water, 0, sizeof(top_water));

	// --- the three average-color grids (si-1 / si / si+1; the
	// slab-boundary culling reads the neighbor SOLID masks).
	// AC-0253: the solid/air test is the slab's "bs" BITSET first — the
	// >half-air sample test is a bit COUNT (no decode), the palette
	// decode runs only for the non-air cells of the samples that EMIT
	// (the own slab's colors; the neighbor slabs' colors were never
	// read — only their solid masks). A slab without "bs" takes the
	// pre-AC-0253 decode (slab_view_one, on demand).
	struct AvgSrc {
		bool ok = false;
		const uint8_t *bs = nullptr;
		std::vector<uint8_t> flat; // fallback decode storage
		int n = 0, b = 0, psz = 0, isz = 0;
		const uint8_t *p = nullptr;
		const uint8_t *ib = nullptr;
		inline bool solid(int pos) const {
			if (bs != nullptr)
				return awecommon::slab_bit(bs, pos);
			return pos < (int)flat.size() && flat[pos] != 0;
		}
		inline uint8_t cell(int pos) const { // the non-air decode
			if (bs != nullptr) {
				if (n == 1)
					return psz > 0 ? p[0] : 0;
				if (n == 0)
					return pos < isz ? ib[pos] : 0;
				int idx = awecommon::slab_getbits(ib, isz, b, pos);
				return idx < psz ? p[idx] : 0;
			}
			return pos < (int)flat.size() ? flat[pos] : 0;
		}
	};
	AvgSrc asrc[3];
	uint8_t grids_solid[3][512];
	float grids_cols[3][512 * 18];
	bool ghave[3] = {false, false, false};
	int nsl = (int)p_slabs.size();
	int gsi[3] = {si - 1, si, si + 1};
	for (int t = 0; t < 3; t++) {
		memset(grids_solid[t], 0, sizeof(grids_solid[t]));
		memset(grids_cols[t], 0, sizeof(grids_cols[t]) / sizeof(float));
		int s = gsi[t];
		if (s < 0 || s >= nsl)
			continue;
		Variant v = p_slabs[s];
		if (v.get_type() != Variant::DICTIONARY)
			continue;
		Dictionary d = v;
		PackedByteArray bsarr = d.get("bs", PackedByteArray());
		if (bsarr.size() == awecommon::S3B) {
			AvgSrc &a = asrc[t];
			a.bs = bsarr.ptr();
			a.n = (int)d.get("n", 0);
			a.b = (int)d.get("b", 0);
			PackedByteArray pb = d.get("p", PackedByteArray());
			a.p = pb.ptr();
			a.psz = (int)pb.size();
			PackedByteArray ib = d.get("i", PackedByteArray());
			a.ib = ib.ptr();
			a.isz = (int)ib.size();
		} else {
			awecommon::slab_view_one(v, asrc[t].flat);
		}
		asrc[t].ok = true;
		const AvgSrc &a = asrc[t];
		// AC-0258: the clutter count (derived slab field, like "bs") —
		// when > 0 the solid cells can include clutter (flora), which the
		// avg tiers treat as AIR; the cell recount below excludes it.
		// Missing "nc" (pre-AC-0258 slab) = the clutter-free fast path.
		int nc = (int)d.get("nc", 0);
		for (int cy = 0; cy < G; cy++) {
			for (int cz = 0; cz < G; cz++) {
				for (int cx = 0; cx < G; cx++) {
					// the >half-air test: a bit count (the solid count),
					// the decode-free fast path.
					int pc = 0;
					for (int py = 0; py < CELLB; py++) {
						int r0 = (cy * CELLB + py) * 256;
						for (int pz = 0; pz < CELLB; pz++) {
							int base = r0 + (cz * CELLB + pz) * 16 + cx * CELLB;
							for (int px = 0; px < CELLB; px++)
								pc += a.solid(base + px);
						}
					}
					int idx = cy * G * G + cz * G + cx;
					if (pc == 0 || (TOT - pc) * 2 > TOT) {
						grids_solid[t][idx] = 0;
						continue;
					}
					if (nc == 0) {
						// the clutter-free slab (the common slab): the
						// pre-AC-0258 path, untouched.
						grids_solid[t][idx] = 1;
						if (t != 1)
							continue; // neighbor: the solid mask is all it feeds
						int cnt = 0;
						float acc[18] = {0.0f};
						// AC-0312: the water-surface flag — the cell's topmost
						// non-air sub-cell is water (ALL of them at that top py —
						// a land or tree cell alongside disqualifies).
						int top_py = -1;
						bool top_water_cell = true;
						for (int py = 0; py < CELLB; py++) {
							int r0 = (cy * CELLB + py) * 256;
							for (int pz = 0; pz < CELLB; pz++) {
								int base = r0 + (cz * CELLB + pz) * 16 + cx * CELLB;
								for (int px = 0; px < CELLB; px++) {
									int pos = base + px;
									if (!a.solid(pos))
										continue;
									cnt++;
									int bid = a.cell(pos);
									if (py > top_py) {
										top_py = py;
										top_water_cell = (bid == AW_B_WATER);
									} else if (py == top_py && bid != AW_B_WATER) {
										top_water_cell = false;
									}
									if (fcc_ok && bid < 256) {
										const float *fc = fcc + bid * 18;
										for (int d = 0; d < 18; d++)
											acc[d] += fc[d];
									}
								}
							}
						}
						float inv = 1.0f / (float)cnt;
						for (int d = 0; d < 18; d++)
							grids_cols[t][idx * 18 + d] = acc[d] * inv;
						if (top_py >= 0 && top_water_cell)
							top_water[idx] = 1;
						continue;
					}
					// AC-0258: the clutter slab — a solid cell can be
					// CLUTTER (flora), which counts as AIR at the avg
					// tiers: recount from the decode with the clutter
					// excluded (from both the count and the color); a cell
					// whose solid cells are ALL clutter is air. (The
					// decode cost lands only on slabs that hold flowers —
					// the very slabs that speckled before; the t==1 color
					// pass already decodes, the t=0/2 masks are the rare
					// extra pass and only when that slab has clutter too.)
					int cnt = 0;
					float acc[18] = {0.0f};
					int top_py = -1;  // AC-0312: the water-surface flag (the cell's
					bool top_water_cell = true;  // topmost non-air is water — clutter excluded)
					for (int py = 0; py < CELLB; py++) {
						int r0 = (cy * CELLB + py) * 256;
						for (int pz = 0; pz < CELLB; pz++) {
							int base = r0 + (cz * CELLB + pz) * 16 + cx * CELLB;
							for (int px = 0; px < CELLB; px++) {
								int pos = base + px;
								if (!a.solid(pos))
									continue;
								int bid = a.cell(pos);
								if (awecommon::is_clutter_block(bid))
									continue;
								cnt++;
								if (py > top_py) {
									top_py = py;
									top_water_cell = (bid == AW_B_WATER);
								} else if (py == top_py && bid != AW_B_WATER) {
									top_water_cell = false;
								}
								if (t == 1 && fcc_ok && bid < 256) {
									const float *fc = fcc + bid * 18;
									for (int d = 0; d < 18; d++)
										acc[d] += fc[d];
								}
							}
						}
					}
					if (cnt == 0 || (TOT - cnt) * 2 > TOT) {
						grids_solid[t][idx] = 0;
						continue;
					}
					grids_solid[t][idx] = 1;
					if (t == 1) {
						float inv = 1.0f / (float)cnt;
						for (int d = 0; d < 18; d++)
							grids_cols[t][idx * 18 + d] = acc[d] * inv;
						if (top_py >= 0 && top_water_cell)
							top_water[idx] = 1;
					}
				}
			}
		}
		ghave[t] = true;
	}
	return avg_grid_emit(G, CELL, si, nsl, grids_solid, grids_cols, ghave, top_water, p_fcc, p_sky, p_wtlx, p_wtly, p_w_atlas_px, p_yfloor);
}

// ---------------------------------------------------------------------------
// AC-0284b: the SHARED tail of the avg-tier emits — the >half-air "any"
// check, the 6-face outermost-shell scan + greedy merge, and the vertex
// assembly (the low_emit_avg_impl port). low_emit_avg_impl (the slab
// grid) and h_avg_emit_impl (the far payload grid) both feed this — the
// byte-identity of the two emits rests on the SHARED grid contract
// (grids_solid: the >half-solid cell mask; grids_cols[1]: the per-face
// average color) and this shared emit.
// ---------------------------------------------------------------------------

static Dictionary avg_grid_emit(int G, float CELL, int si, int nsl,
		uint8_t grids_solid[3][512], const float grids_cols[3][512 * 18],
		const bool ghave[3], uint8_t *top_water,
		const PackedFloat32Array &p_fcc, const PackedByteArray &p_sky,
		int wtlx, int wtly, float w_atlas_px, int p_yfloor) {
	Dictionary res;
	const float *fcc = p_fcc.ptr();
	const uint8_t *skyp = p_sky.ptr();
	bool sky_ok = p_sky.size() == (int)(G * G * G);
	// AC-0331: the far-tier mesh FLOOR (the production callers pass
	// Data.SEA = 126; p_yfloor < 0 = off, byte-identical to the
	// pre-floor call). A grid CELL is KEPT iff its TOPMOST world y is
	// > p_yfloor — a cell entirely below the floor is zeroed out of
	// the solid masks (and the water-surface flag), a cell that
	// STRADDLES the floor is kept WHOLE (its below-floor sub-cells
	// already counted in the fill loop's >half-air solid test + color).
	// The gate is this single post-fill mask in the SHARED tail — the
	// fill loops above are untouched, so the two emitters' byte
	// identity (the farab gate) and the float32 op order (the
	// bit-exactness contract) hold by construction. The face scan
	// below then reads the masked grids: it bounds itself to the
	// post-floor cell range (no face bounds the removed region), and
	// the bottommost kept cell's -Y face IS the opaque cap at the
	// floor (world y 126 at G=8 — the cut lands on the cell
	// boundary; at G=4 the containing cell spans 124-127, so the cap
	// sits at 124 — the tier's own 4-block granularity).
	if (p_yfloor >= 0) {
		const int CELLB = 16 / G;
		for (int t = 0; t < 3; t++) {
			int s_t = si + (t - 1);
			if (s_t < 0 || s_t >= nsl)
				continue; // the grid is all-zero (absent slab)
			int y0t = s_t * 16;
			for (int cy = 0; cy < G; cy++) {
				if (y0t + (cy + 1) * CELLB - 1 > p_yfloor)
					continue; // the cell's top is above the floor
				for (int i = 0; i < G * G; i++)
					grids_solid[t][cy * G * G + i] = 0;
			}
		}
		for (int cy = 0; cy < G; cy++) {
			if (si * 16 + (cy + 1) * CELLB - 1 > p_yfloor)
				continue;
			for (int i = 0; i < G * G; i++)
				top_water[cy * G * G + i] = 0;
		}
	}
	bool any = false;
	for (int i = 0; i < G * G * G; i++) {
		if (grids_solid[1][i] != 0) {
			any = true;
			break;
		}
	}
	if (!any) {
		res["empty"] = true;
		return res;
	}
	// the _avg_neighbor_solid port: in-grid -> the solid mask; across the
	// slab boundary -> the neighbor slab's solid edge row; off the
	// column -> air. (A SOLID neighbor culls — the avg tiers have no block
	// id, so the textured emit's "different id" collapses to "air".)
	auto neighbor_solid = [&](int ix, int iy, int iz, int nax, const int n[3]) -> int {
		if (!ghave[1])
			return 0;
		if (nax == 0) {
			int nx = ix + n[0];
			if (nx < 0 || nx >= G)
				return 0;
			return grids_solid[1][nx + iz * G + iy * G * G];
		}
		if (nax == 2) {
			int nz = iz + n[2];
			if (nz < 0 || nz >= G)
				return 0;
			return grids_solid[1][ix + nz * G + iy * G * G];
		}
		int ny = iy + n[1];
		if (ny < 0 || ny >= G) {
			int gsi2 = si + n[1];
			int t2 = gsi2 == si + 1 ? 2 : 0;
			if (gsi2 < 0 || gsi2 >= nsl || !ghave[t2])
				return 0;
			int gyb = n[1] > 0 ? 0 : G - 1;
			return grids_solid[t2][ix + iz * G + gyb * G * G];
		}
		return grids_solid[1][ix + iz * G + ny * G * G];
	};

	// --- the 6-face shell scan + greedy merge (the _avg_emit_slab port).
	std::vector<float> av;
	std::vector<float> an;
	std::vector<float> ac;
	std::vector<int32_t> ai;
	// AC-0312: the WATER-EXCEPTION surface — the +Y faces of
	// water-topped cells merge under WATER_KEY (a dedicated key
	// outside the quantized color-key range) into a SEPARATE
	// surface (the real translucent water material; one 31-px
	// tile per G-block; the fluid_anim shader scrolls the anim
	// frames). Same quad count as today's opaque top quads.
	std::vector<float> wv;
	std::vector<float> wn;
	std::vector<float> wc;
	std::vector<float> wu;
	std::vector<int32_t> wi;
	bool water_ok = top_water != nullptr && wtlx >= 0 && wtlx < 32768 \
		&& wtly >= 0 && wtly < 32768 && w_atlas_px > 0.0f;
	static const int WATER_KEY = 0x40000000;
	float y_min = 1e30f;
	float y_max = -1e30f;
	static const int UA[6] = {2, 2, 0, 0, 0, 0};
	static const int VA[6] = {1, 1, 2, 2, 1, 1};
	for (int fi = 0; fi < 6; fi++) {
		const int *n = FN[fi];
		int nax = n[0] != 0 ? 0 : (n[1] != 0 ? 1 : 2);
		int ua = UA[fi];
		int va = VA[fi];
		int ns = nax == 0 ? n[0] : (nax == 1 ? n[1] : n[2]);
		// m[pv][pu] = the merge key (quantized color x16 + plane k+1)
		// or -1; kmap = the outermost plane k.
		int m[8][8];
		int kmap[8][8];
		for (int pv = 0; pv < G; pv++) {
			for (int pu = 0; pu < G; pu++) {
				int cc[3] = {0, 0, 0};
				cc[ua] = pu;
				cc[va] = pv;
				int keyv = -1;
				int kk = 0;
				int k = ns > 0 ? G - 1 : 0;
				while (kk < G) {
					cc[nax] = k;
					int idx = cc[0] + cc[2] * G + cc[1] * G * G;
					if (grids_solid[1][idx] != 0) {
						if (neighbor_solid(cc[0], cc[1], cc[2], nax, n) == 0) {
						// AC-0312: the +Y face of a water-topped cell is the
						// water surface (the dedicated merge key).
						if (fi == 2 && water_ok && top_water[idx] != 0) {
							keyv = WATER_KEY;
						} else {
							float cr = grids_cols[1][idx * 18 + fi * 3 + 0];
							float cg = grids_cols[1][idx * 18 + fi * 3 + 1];
							float cb = grids_cols[1][idx * 18 + fi * 3 + 2];
							int q = (int)(cr * 31.0f) * 1024 + (int)(cg * 31.0f) * 32 + (int)(cb * 31.0f);
							keyv = q * 16 + (k + 1);
						}
						}
						break;
					}
					k += ns > 0 ? -1 : 1;
					kk++;
				}
				m[pv][pu] = keyv;
				kmap[pv][pu] = k;
			}
		}
		for (int pv = 0; pv < G; pv++) {
			int pu = 0;
			while (pu < G) {
				int key2 = m[pv][pu];
				if (key2 < 0) {
					pu++;
					continue;
				}
				int W = 1;
				while (pu + W < G && m[pv][pu + W] == key2)
					W++;
				int H = 1;
				while (pv + H < G) {
					bool okh = true;
					for (int u2 = 0; u2 < W; u2++) {
						if (m[pv + H][pu + u2] != key2) {
							okh = false;
							break;
						}
					}
					if (!okh)
						break;
					H++;
				}
				int cc0[3] = {0, 0, 0};
				cc0[ua] = pu;
				cc0[va] = pv;
				cc0[nax] = kmap[pv][pu];
				float wx = cc0[0] * CELL;
				float wy = cc0[1] * CELL;
				float wz = cc0[2] * CELL;
				if (nax == 0)
					wx += n[0] > 0 ? CELL : 0.0f;
				else if (nax == 1)
					wy += n[1] > 0 ? CELL : 0.0f;
				else
					wz += n[2] > 0 ? CELL : 0.0f;
				// the quad color = the ORIGIN cell's face color (every
				// merged cell shares the quantized key). AC-0283 P3: the
				// quad's alpha = the ORIGIN cell's heightmap sky (the halo
				// band's light; 1.0 when p_sky is absent).
				int oidx = cc0[0] + cc0[2] * G + cc0[1] * G * G;
				float qcr = grids_cols[1][oidx * 18 + fi * 3 + 0];
				float qcg = grids_cols[1][oidx * 18 + fi * 3 + 1];
				float qcb = grids_cols[1][oidx * 18 + fi * 3 + 2];
				float qca = sky_ok ? (float)skyp[oidx] / 15.0f : 1.0f;
				bool is_water = (key2 == WATER_KEY);  // AC-0312
				int cb0 = (int)(is_water ? wv.size() : av.size()) / 3;
				for (int j = 0; j < 4; j++) {
					float cvx = FCV[fi][j][0];
					float cvy = FCV[fi][j][1];
					float cvz = FCV[fi][j][2];
					float px = wx;
					float py = wy;
					float pz = wz;
					if (fi == 0 || fi == 1) { // u = z (W cells), v = y (H cells)
						py = wy + cvy * (float)H * CELL;
						pz = wz + cvz * (float)W * CELL;
					} else if (fi == 2 || fi == 3) { // u = x (W cells), v = z (H cells)
						px = wx + cvx * (float)W * CELL;
						pz = wz + cvz * (float)H * CELL;
					} else { // fi 4/5: u = x (W cells), v = y (H cells)
						px = wx + cvx * (float)W * CELL;
						py = wy + cvy * (float)H * CELL;
					}
					if (is_water) {
						// AC-0312: the water surface vertex — the position,
						// normal and (face-averaged) color as the opaque path;
						// the UV = the water tile top-left + one 31-px tile per
						// G-block (the corner's block indices — the high path's
						// plain-branch convention; the fluid_anim shader scrolls
						// the anim frames).
						wv.push_back(px);
						wv.push_back(py);
						wv.push_back(pz);
						if (py < y_min)
							y_min = py;
						if (py > y_max)
							y_max = py;
						wn.push_back((float)n[0]);
						wn.push_back((float)n[1]);
						wn.push_back((float)n[2]);
						wc.push_back(qcr);
						wc.push_back(qcg);
						wc.push_back(qcb);
						wc.push_back(qca);
						int bxx = (int)((pu + cvx * W) * CELL);
						int bzz = (int)((pv + cvz * H) * CELL);
						wu.push_back((wtlx + 31 * bxx) / w_atlas_px);
						wu.push_back((wtly + 31 * bzz) / w_atlas_px);
					} else {
						av.push_back(px);
						av.push_back(py);
						av.push_back(pz);
						if (py < y_min)
							y_min = py;
						if (py > y_max)
							y_max = py;
						an.push_back((float)n[0]);
						an.push_back((float)n[1]);
						an.push_back((float)n[2]);
						ac.push_back(qcr);
						ac.push_back(qcg);
						ac.push_back(qcb);
						ac.push_back(qca);
					}
				}
				if (is_water) {
					wi.push_back(cb0);
					wi.push_back(cb0 + 2);
					wi.push_back(cb0 + 1);
					wi.push_back(cb0);
					wi.push_back(cb0 + 3);
					wi.push_back(cb0 + 2);
				} else {
					ai.push_back(cb0);
					ai.push_back(cb0 + 2);
					ai.push_back(cb0 + 1);
					ai.push_back(cb0);
					ai.push_back(cb0 + 3);
					ai.push_back(cb0 + 2);
				}
				for (int v2 = pv; v2 < pv + H; v2++) {
					for (int u2 = pu; u2 < pu + W; u2++)
						m[v2][u2] = -1;
				}
				pu += W;
			}
		}
	}
	// AC-0312: the emit is empty only when BOTH surfaces are —
	// a slab of pure water column emits a water surface alone.
	if (av.empty() && wv.empty()) {
		res["empty"] = true;
		return res;
	}
	PackedVector3Array pv3;
	pv3.resize((int)av.size() / 3);
	for (int i = 0; i < (int)av.size() / 3; i++)
		pv3[i] = Vector3(av[i * 3], av[i * 3 + 1], av[i * 3 + 2]);
	PackedVector3Array pn3;
	pn3.resize((int)an.size() / 3);
	for (int i = 0; i < (int)an.size() / 3; i++)
		pn3[i] = Vector3(an[i * 3], an[i * 3 + 1], an[i * 3 + 2]);
	PackedColorArray pcol;
	pcol.resize((int)ac.size() / 4);
	for (int i = 0; i < (int)ac.size() / 4; i++)
		pcol[i] = Color(ac[i * 4], ac[i * 4 + 1], ac[i * 4 + 2], ac[i * 4 + 3]);
	PackedInt32Array pidx;
	pidx.resize((int)ai.size());
	for (int i = 0; i < (int)ai.size(); i++)
		pidx[i] = ai[i];
	PackedVector3Array pwv3;
	pwv3.resize((int)wv.size() / 3);
	for (int i = 0; i < (int)wv.size() / 3; i++)
		pwv3[i] = Vector3(wv[i * 3], wv[i * 3 + 1], wv[i * 3 + 2]);
	PackedVector3Array pwn3;
	pwn3.resize((int)wn.size() / 3);
	for (int i = 0; i < (int)wn.size() / 3; i++)
		pwn3[i] = Vector3(wn[i * 3], wn[i * 3 + 1], wn[i * 3 + 2]);
	PackedColorArray pwcol;
	pwcol.resize((int)wc.size() / 4);
	for (int i = 0; i < (int)wc.size() / 4; i++)
		pwcol[i] = Color(wc[i * 4], wc[i * 4 + 1], wc[i * 4 + 2], wc[i * 4 + 3]);
	PackedVector2Array pwu2;
	pwu2.resize((int)wu.size() / 2);
	for (int i = 0; i < (int)wu.size() / 2; i++)
		pwu2[i] = Vector2(wu[i * 2], wu[i * 2 + 1]);
	PackedInt32Array pwidx;
	pwidx.resize((int)wi.size());
	for (int i = 0; i < (int)wi.size(); i++)
		pwidx[i] = wi[i];
	res["v"] = pv3;
	res["n"] = pn3;
	res["c"] = pcol;
	res["i"] = pidx;
	res["wv"] = pwv3;
	res["wn"] = pwn3;
	res["wc"] = pwcol;
	res["wu"] = pwu2;
	res["wi"] = pwidx;
	res["mh"] = y_max - y_min;
	return res;
}

// ---------------------------------------------------------------------------
// AC-0284b: the FAR (h-only) column's avg emit — the H-driven 4x4x4 halo
// emitter. A far column holds NO slabs (the AC-0284b representation): the
// grid is derived from the far payload (256 H u16 + 256 biome + 256
// top-block id) + the deep-color precompute (AweGen.stone_ore_slab — the
// exact stone_ore chain the fill loop uses, per slab cell):
//
//   * the skip fill is solid exactly 0..H (+ the aquifer H+1..sea when
//     H < sea), so the per-(x,z) SOLID TOP is S = max(H, sea) and a cell's
//     solid count = sum over its 16 (x,z) of clamp(S - y0 + 1, 0, CELLB)
//     (the slab path's bit count over the same solid set — the clutter
//     path's recount lands on the same set too: the skip column's trees
//     sit strictly above the surface and count as air in both);
//   * the per-face color = the average over the solid sub-cells' EXACT
//     skip-fill block ids (bedrock / water / top block / dirt-sand /
//     stone-ore) in the slab path's py/pz/px accumulation order (the
//     float32 op order — the equivalence contract the farab gate checks:
//     the emitted mesh is BYTE-IDENTICAL to low_emit_avg run on the same
//     column's skip-filled slabs, same world, same seed).
//
// The emit tail (the >half-air scan + greedy merge + assembly) is the
// SHARED avg_grid_emit above — the identity rests on the shared tail +
// the exact grids.
// ---------------------------------------------------------------------------

// AC-0284b: the far emitter's block ids — == awegen::B_* in gen.cpp
// (the data.gd contract; the awecommon.h B_STONE pattern).
constexpr int FAR_B_DIRT = 2;
constexpr int FAR_B_SAND = 4;
constexpr int FAR_B_WATER = 5;
constexpr int FAR_B_BEDROCK = 11;
constexpr int FAR_B_SNOW_GRASS = 12;
constexpr int FAR_B_STONE = 3;

static Dictionary h_avg_emit_impl(const PackedByteArray &p_h, const PackedByteArray &p_bm,
		const PackedByteArray &p_top, const PackedByteArray &p_ore, const PackedByteArray &p_veg,
		int si, int p_grid, const PackedFloat32Array &p_fcc, const PackedByteArray &p_sky, int p_sea, int p_hmax,
		int p_wtlx, int p_wtly, float p_w_atlas_px, int p_yfloor) {
	Dictionary res;
	if (p_h.size() != 512 || p_bm.size() != 256 || p_top.size() != 256) {
		res["empty"] = true; // malformed payload — fail as all-air
		return res;
	}
	const int G = (p_grid == 4) ? 4 : 8;
	const int CELLB = 16 / G;
	const float CELL = (float)CELLB;
	const int TOT = CELLB * CELLB * CELLB;
	bool fcc_ok = p_fcc.size() >= 256 * 18;
	const uint8_t *ore = (p_ore.size() == awecommon::S3) ? p_ore.ptr() : nullptr;
	const int nsl = p_hmax / 16;

	// The payload: H (u16 LE) + S = the solid top INCLUDING the aquifer
	// (the skip fill's water fills H+1..sea when H < sea — solid bs cells
	// in the slab path too, so the counts + colors include it).
	int Hh[256], St[256];
	const uint8_t *hp = p_h.ptr();
	for (int i = 0; i < 256; i++) {
		int H = (int)hp[2 * i] | ((int)hp[2 * i + 1] << 8);
		Hh[i] = H;
		St[i] = (H > p_sea) ? H : p_sea;
	}

	// AC-0284b: the TREE cells (veg_cells — 4 bytes/cell:
	// id<<24 | y<<8 | z<<4 | x). The skip slab's bs bitset INCLUDES the
	// trees (log/leaves are not clutter — they count as solid in the
	// slab emit's >half test AND color), so the far grid adds them too:
	// a per-layer slab-local id table (0 = no tree). A tree cell is
	// always AIR in the skip fill (y >= H + 1 > S), so it never
	// conflicts with a fill cell — the tables are exclusive.
	uint8_t tree_id[3][awecommon::S3];
	memset(tree_id, 0, sizeof(tree_id));
	{
		int gsi0[3] = {si - 1, si, si + 1};
		int vn = (p_veg.size() >= 4) ? (p_veg.size() / 4) : 0;
		const uint8_t *vp = p_veg.ptr();
		for (int k = 0; k < vn; k++) {
			uint32_t c = (uint32_t)vp[k * 4] | ((uint32_t)vp[k * 4 + 1] << 8)
				| ((uint32_t)vp[k * 4 + 2] << 16) | ((uint32_t)vp[k * 4 + 3] << 24);
			int id = (int)(c >> 24);
			int y = (int)((c >> 8) & 0xFFFF);
			int z = (int)((c >> 4) & 0xF);
			int x = (int)(c & 0xF);
			int s = y >> 4;
			for (int t = 0; t < 3; t++) {
				if (gsi0[t] == s)
					tree_id[t][((y - s * 16) << 8) | (z << 4) | x] = (uint8_t)id;
			}
		}
	}

	uint8_t grids_solid[3][512];
	float grids_cols[3][512 * 18];
	// AC-0312: the per-cell water-surface flag (t==1 grid).
	uint8_t top_water[512];
	memset(top_water, 0, sizeof(top_water));
	bool ghave[3] = {false, false, false};
	int gsi[3] = {si - 1, si, si + 1};
	for (int t = 0; t < 3; t++) {
		memset(grids_solid[t], 0, sizeof(grids_solid[t]));
		memset(grids_cols[t], 0, sizeof(grids_cols[t]));
		int s = gsi[t];
		if (s < 0 || s >= nsl)
			continue;
		int y0 = s * 16;
		for (int cy = 0; cy < G; cy++) {
			for (int cz = 0; cz < G; cz++) {
				for (int cx = 0; cx < G; cx++) {
					// Solid count — the skip fill is solid exactly
					// y <= S over each (x,z), PLUS the tree cells
					// (the slab path's bs bitset includes them).
					int pc = 0;
					for (int py = 0; py < CELLB; py++) {
						int y = y0 + cy * CELLB + py;
						for (int pz = 0; pz < CELLB; pz++) {
							int lz = cz * CELLB + pz;
							for (int px = 0; px < CELLB; px++) {
								int idx = lz * 16 + (cx * CELLB + px);
								int tid = tree_id[t][((y - y0) << 8) | (lz << 4) | (cx * CELLB + px)];
								pc += ((y <= St[idx]) || tid != 0) ? 1 : 0;
							}
						}
					}
					int idxc = cy * G * G + cz * G + cx;
					if (pc == 0 || (TOT - pc) * 2 > TOT) {
						grids_solid[t][idxc] = 0;
						continue;
					}
					grids_solid[t][idxc] = 1;
					if (t != 1)
						continue;
					// The per-face average color — the EXACT skip-fill
					// block id per solid sub-cell (the fill loop's chain,
					// he = H, no lava: the water branch preempts it
					// below H < sea) in the slab path's py/pz/px order.
					int cnt = 0;
					float acc[18] = {0.0f};
					int top_py = -1;  // AC-0312: the water-surface flag (the cell's
					bool top_water_cell = true;  // topmost non-air is water)
					for (int py = 0; py < CELLB; py++) {
						int y = y0 + cy * CELLB + py;
						for (int pz = 0; pz < CELLB; pz++) {
							int lz = cz * CELLB + pz;
							for (int px = 0; px < CELLB; px++) {
								int lx = cx * CELLB + px;
								int idx = lz * 16 + lx;
								int tid = tree_id[t][((y - y0) << 8) | (lz << 4) | lx];
								if (!(y <= St[idx]) && tid == 0)
									continue;
								cnt++;
								int bid;
								if (tid != 0) {
									// Tree cell — the veg id (log/leaves),
									// the flat's value at the cell.
									bid = tid;
								} else {
								int Hi = Hh[idx];
								if (y < 5) {
									// AC-0292: the bedrock band (the fill
									// loop's y < 5 — the far emit mirrors the
									// skip fill's bottom rows exactly).
									bid = FAR_B_BEDROCK;
								} else if (Hi < p_sea && y >= Hi + 1 && y <= p_sea) {
									bid = FAR_B_WATER;
								} else if (y == Hi) {
									bid = p_top[idx];
								} else if (y >= Hi - 3) {
									bid = (p_bm[idx] == 1) ? FAR_B_SAND : FAR_B_DIRT;
								} else if (ore != nullptr) {
									// Deep (y < H - 3): the precomputed
									// stone_ore chain (slab-local pos).
									bid = ore[((y - y0) << 8) | (lz << 4) | lx];
								} else {
									bid = FAR_B_STONE;
								}
								}
								// AC-0312: the per-bid top test (bid is the fill's block id —
								// water only in the aquifer band H+1..sea; trees/land disqualify).
								if (py > top_py) {
									top_py = py;
									top_water_cell = (bid == FAR_B_WATER);
								} else if (py == top_py && bid != FAR_B_WATER) {
									top_water_cell = false;
								}
								if (fcc_ok && bid < 256) {
									const float *fc = p_fcc.ptr() + bid * 18;
									for (int d = 0; d < 18; d++)
										acc[d] += fc[d];
								}
							}
						}
					}
					float inv = 1.0f / (float)cnt;
					for (int d = 0; d < 18; d++)
						grids_cols[t][idxc * 18 + d] = acc[d] * inv;
					if (top_py >= 0 && top_water_cell)
						top_water[idxc] = 1;
				}
			}
		}
		ghave[t] = true;
	}
	return avg_grid_emit(G, CELL, si, nsl, grids_solid, grids_cols, ghave, top_water, p_fcc, p_sky, p_wtlx, p_wtly, p_w_atlas_px, p_yfloor);
}

// The registered class.
class AweMesh : public RefCounted {
	GDCLASS(AweMesh, RefCounted)

public:
	static void _bind_methods() {
		// AC-0234: "mask" = the vertical-window keep mask (24 bytes;
		// empty = build every slab — the pre-AC-0234 behavior).
		// AC-0331: yfloor (DEFVAL(-1) = off) — the far-tier mesh floor
		// for the band-A materialization (see build_accs' row gate).
		ClassDB::bind_method(D_METHOD("build_accs", "data", "fl", "cx", "cz", "nbs", "ctx", "ms", "eff", "si0", "si1", "d_off", "att", "glow", "mask", "yfloor"), &AweMesh::build_accs, DEFVAL(-1));
		// AC-0211: the surrounding-step ports (dispatch snapshot + sync
		// snap + stale-check rows) — same class, same .so.
		// AC-0284b: far/sea = the neighbor's far payload (1024 bytes = the
		// h-only shape — the ring is the skip-fill edge row) + the sea
		// level (the aquifer top). Empty = the slab ring (legacy).
		ClassDB::bind_method(D_METHOD("snap_rings", "d", "f", "dx", "dz", "genkeep", "far", "sea"), &AweMesh::snap_rings, DEFVAL(PackedByteArray()), DEFVAL(PackedByteArray()), DEFVAL(126));
		ClassDB::bind_method(D_METHOD("slab_copy", "slabs"), &AweMesh::slab_copy);
		ClassDB::bind_method(D_METHOD("sync_snap", "own_d", "own_f", "rings", "h"), &AweMesh::sync_snap);
		ClassDB::bind_method(D_METHOD("rows_eq", "a", "b", "y_lo", "y_hi"), &AweMesh::rows_eq);
		ClassDB::bind_method(D_METHOD("slab_boundary_air", "d", "lo", "hi"), &AweMesh::slab_boundary_air);
		// AC-0236 part 2: the low placeholder emit (the worker-side
		// 4x4x4 grid + greedy mesh; the node attach stays main-thread).
		// AC-0252: the med/low AVERAGE-COLOR emit (grid 8 = MED / 4 = LOW,
		// fcc = the face-color cache) — the active lane's emit.
		ClassDB::bind_method(D_METHOD("low_emit", "slabs", "si", "ms"), &AweMesh::low_emit);
		// AC-0283 P3: the optional 5th arg = the halo band's per-cell
		// heightmap sky (empty = the legacy all-bright avg emit).
		// AC-0331: yfloor = the far-tier mesh floor (world y; the
		// production callers pass Data.SEA = 126; -1 = off, byte-identical
		// to the pre-floor call — the grid cells entirely below it are
		// air, the straddling cell is kept whole, see avg_grid_emit).
		ClassDB::bind_method(D_METHOD("low_emit_avg", "slabs", "si", "grid", "fcc", "sky", "wtlx", "wtly", "w_atlas_px", "yfloor"), &AweMesh::low_emit_avg, DEFVAL(PackedByteArray()), DEFVAL(-1), DEFVAL(-1), DEFVAL(0.0), DEFVAL(-1));
		// AC-0284b: the far (h-only) column's avg emit — the H-driven
		// halo emitter (see h_avg_emit_impl for the full contract).
		// h/bm/top = the far payload (512/256/256 bytes); ore = the
		// AweGen.stone_ore_slab 4096-byte deep-color precompute (empty =
		// pure stone — pass it for the slabs with deep cells, si <= 3);
		// veg = the AweGen.veg_cells tree-cell list (4 bytes/cell; empty
		// = no trees — the solid set + colors stay the skip fill);
		// sea/hmax = the world constants (the aquifer + slab count).
		// AC-0312: the water-exception params (wtlx/wtly = the water
		// tile's top-left rect in px, w_atlas_px = the atlas width in
		// px; wtlx < 0 = the exception off — byte-identical to the
		// pre-AC-0312 call).
		// AC-0331: yfloor = the far-tier mesh floor (same contract as
		// low_emit_avg's — the farab identity holds because both go
		// through the same shared-tail mask).
		ClassDB::bind_method(D_METHOD("h_avg_emit", "h", "bm", "top", "ore", "veg", "si", "grid", "fcc", "sky", "sea", "hmax", "wtlx", "wtly", "w_atlas_px", "yfloor"), &AweMesh::h_avg_emit, DEFVAL(-1), DEFVAL(-1), DEFVAL(0.0), DEFVAL(-1));
		// AC-0312: the band-A synthetic cached eff (the heightmap sky as
		// the classic light dict + the 8 clamped-H margin strips).
		ClassDB::bind_method(D_METHOD("sky_eff", "cx", "cz", "h", "hgt"), &AweMesh::sky_eff);
	}

	// AC-0236 part 2: slabs = the value-copied slab array (null | {n,b,p,i,
	// nz}), si = the target slab, ms = the merge-atlas snapshot (+ the
	// plain original-atlas rects + atlas_px). See low_emit_impl above for
	// the full contract.
	Dictionary low_emit(const Array &p_slabs, int p_si, const Dictionary &p_ms) {
		return low_emit_impl(p_slabs, p_si, p_ms);
	}

	// AC-0252: the med/low average-color emit (see low_emit_avg_impl for
	// the full contract). grid = MED_GRID (8) or LOW_GRID (4); fcc = the
	// (block id x 6 face direction) average-color cache (256 x 18 LINEAR
	// floats, the value copy in the dispatch entry). sky = the halo band's
	// per-cell heightmap sky (AC-0283 P3; empty = the legacy all-bright
	// emit — the real band and the battery arms pass nothing).
	// AC-0312: wtlx/wtly/w_atlas_px = the water-exception params (the
	// water tile's top-left px rect + the atlas width in px; wtlx < 0 =
	// off — byte-identical to the pre-AC-0312 call).
	Dictionary low_emit_avg(const Array &p_slabs, int p_si, int p_grid, const PackedFloat32Array &p_fcc, const PackedByteArray &p_sky, int p_wtlx, int p_wtly, double p_w_atlas_px, int p_yfloor) {
		return low_emit_avg_impl(p_slabs, p_si, p_grid, p_fcc, p_sky, p_wtlx, p_wtly, (float)p_w_atlas_px, p_yfloor);
	}

	// AC-0284b: the far (h-only) column's avg emit (see h_avg_emit_impl
	// above). Returns the SAME shape as low_emit_avg ({empty} or
	// {v,n,c,i,mh}) — the low lane attaches it unchanged.
	Dictionary h_avg_emit(const PackedByteArray &p_h, const PackedByteArray &p_bm, const PackedByteArray &p_top, const PackedByteArray &p_ore, const PackedByteArray &p_veg, int p_si, int p_grid, const PackedFloat32Array &p_fcc, const PackedByteArray &p_sky, int p_sea, int p_hmax, int p_wtlx, int p_wtly, double p_w_atlas_px, int p_yfloor) {
		return h_avg_emit_impl(p_h, p_bm, p_top, p_ore, p_veg, p_si, p_grid, p_fcc, p_sky, p_sea, p_hmax, p_wtlx, p_wtly, (float)p_w_atlas_px, p_yfloor);
	}

	// AC-0312: the band-A synthetic cached eff — the heightmap sky as the
	// classic light dict ({mn, w, d, arr, blk_src, mask, ring} — the
	// "has mask" shape build_accs consumes AS-IS) + the 8 full-height
	// margin strips in the bake_box layout (sides 2*16*h — idx
	// y*16+t, inner c=0/outer c=1; corners 4*h — idx (a*2+b)*h+y). The
	// rule: eff = 15 strictly above the column's terrain top H, 0 at or
	// below; a margin column reads the sky through the column's own
	// surface (its x/z clamped to the edge — the band-A "no caves,
	// sky-only light" contract, the halo band's heightmap sky at 16x).
	// AC-0331: FLOOR-AWARE BY CONSTRUCTION — the dict is FULL HEIGHT
	// (arr = 256*h, h = Data.HEIGHT = 384; the strips 2*16*h / 4*h), so
	// the AC-0331 cap face at the far-tier floor (y = Data.SEA = 126,
	// the -Y face of the floor row) reads the SAME rule: lit 15 on an
	// ocean column (H < 126 — the cap floats in light), dark 0 on a
	// land column (H >= 126 — the cap is buried) — no change needed.
	Dictionary sky_eff(int p_cx, int p_cz, const PackedByteArray &p_h, int p_hgt) {
		Dictionary r;
		if (p_h.size() != 512) {
			r["err"] = "bad H";
			return r;
		}
		int h = p_hgt;
		int Hh[256];
		const uint8_t *hp = p_h.ptr();
		for (int i = 0; i < 256; i++)
			Hh[i] = (int)hp[2 * i] | ((int)hp[2 * i + 1] << 8);
		// arr: 256*h — eff(x, y, z) = 15 iff y > H[z*16+x]
		PackedByteArray arr;
		arr.resize((size_t)256 * h);
		uint8_t *ap = arr.ptrw();
		for (int y = 0; y < h; y++)
			for (int z = 0; z < 16; z++)
				for (int x = 0; x < 16; x++)
					ap[(size_t)y * 256 + z * 16 + x] = (y > Hh[z * 16 + x]) ? 15 : 0;
		PackedByteArray mask;
		mask.resize((size_t)256 * h); // zeros — no block light
		PackedInt32Array ring;       // empty
		Dictionary ld;
		ld["mn"] = Vector3i(p_cx * SIZE, 0, p_cz * SIZE);
		ld["w"] = (int64_t)16;
		ld["d"] = (int64_t)16;
		ld["arr"] = arr;
		ld["blk_src"] = false;
		ld["mask"] = mask;
		ld["ring"] = ring;
		// the 8 margin strips (the bake_box layout) — each column's
		// value clamped to the column edge it represents.
		auto side = [&](int mode) {
			// mode 0: E (x = 16..19 clamped to 15; t = z): Hh[t*16+15]
			// mode 1: W (x = 1..0 clamped to 0; t = z): Hh[t*16+0]
			// mode 2: S (z = 16..19 clamped to 15; t = x): Hh[15*16+t]
			// mode 3: N (z = 1..0 clamped to 0; t = x): Hh[0*16+t]
			PackedByteArray ss;
			ss.resize((size_t)2 * 16 * h);
			uint8_t *p = ss.ptrw();
			for (int y = 0; y < h; y++)
				for (int t = 0; t < 16; t++) {
					int he = (mode < 2) ? Hh[t * 16 + (mode == 0 ? 15 : 0)] : Hh[(mode == 2 ? 15 : 0) * 16 + t];
					uint8_t v = (y > he) ? 15 : 0;
					p[(size_t)y * 16 + t] = v;
					p[(size_t)16 * h + (size_t)y * 16 + t] = v;
				}
			return ss;
		};
		auto corner = [&](int xe, int ze) {
			PackedByteArray cc;
			cc.resize((size_t)4 * h);
			uint8_t *p = cc.ptrw();
			for (int y = 0; y < h; y++)
				for (int m = 0; m < 4; m++)
					p[(size_t)m * h + y] = (y > Hh[ze * 16 + xe]) ? 15 : 0;
			return cc;
		};
		Array strips;
		strips.append(side(0)); // E
		strips.append(side(1)); // W
		strips.append(side(2)); // S
		strips.append(side(3)); // N
		strips.append(corner(15, 15)); // SE (x=15, z=15)
		strips.append(corner(0, 15));  // SW (x=0, z=15)
		strips.append(corner(15, 0));  // NE (x=15, z=0)
		strips.append(corner(0, 0));   // NW (x=0, z=0)
		r["light"] = ld;
		r["strips"] = strips;
		return r;
	}

	// Lossless port of ChunkScript.build_accs (chunk.gd:1683). data/fl =
	// the 24-slab paletted arrays (decoded HERE — the AC-0203 follow-on);
	// p_mask = the AC-0234 vertical-window keep mask (24 bytes, one per
	// slab; EMPTY = no gating, byte-identical to the pre-AC-0234 call);
	// nbs = the 4 edge neighbors {d, f} (keys -1,0/1,0/0,-1/0,1); ctx = the make_ctx snapshot +
	// dispatch additions (strips/top/coarse/uv_scale); ms = the
	// merge-atlas snapshot; eff = the light dict (empty = recompute
	// through the shared C++ pull kernel); att/glow = the pre-warmed
	// Lighting._att/_glow tables. Returns the SAME shape as the GDScript:
	// {slabs, light, light_recomputed, wms, si0, si1, nq, ns, phet, ph}.
	Dictionary build_accs(const Array &data, const Array &fl, int cx, int cz, const Dictionary &nbs, const Dictionary &ctx, const Dictionary &ms, const Dictionary &eff, int p_si0, int p_si1, int p_d_off, const PackedByteArray &p_att, const PackedByteArray &p_glow, const PackedByteArray &p_mask, int p_yfloor) {
		(void)p_d_off; // retained for signature stability (AC-0203)
		int64_t t0 = now_msec();
		int64_t ph_light = 0;
		int64_t ph_box = 0;
		int64_t ph_faces = 0;

		Ctx C;
		parse_ctx(ctx, C);
		int h = C.h;
		int topv = C.top;
		int slab_n = (h + 15) / 16;

		Ms M;
		parse_ms(ms, M, C.atlas_px);

		bool was_full = p_si1 < 0;
		int si0 = std::clamp(p_si0, 0, slab_n - 1);
		int si1 = p_si1;
		if (si1 < 0) {
			si1 = slab_n - 1;
			// AC-0197: a full build stops at the column's top slab.
			if (topv >= 0)
				si1 = std::min(si1, topv / 16);
		}
		si1 = std::clamp(std::max(si1, si0), si0, slab_n - 1);
		int y_lo = si0 * 16;
		int y_hi = std::min(h, (si1 + 1) * 16);
		if (topv >= 0 && si1 == topv / 16)
			y_hi = std::min(y_hi, topv + 1);

		// Slab sources — AC-0253: every present slab materializes its
		// flat view HERE (exactly the pre-AC-0253 decode, same C++ int
		// lookups); the "bs" bitset's contribution is the nz field (the
		// instant all-air early out below).
		std::vector<SlabSrc> dsrc, fsrc;
		std::vector<std::vector<uint8_t>> dflat, fflat;
		parse_slab_srcs(data, dsrc, dflat);
		parse_slab_srcs(fl, fsrc, fflat);
		dsrc.resize(slab_n);
		fsrc.resize(slab_n);
		// AC-0331: the far-tier mesh FLOOR for the band-A
		// materialization (p_yfloor < 0 = off — byte-identical to the
		// pre-floor build; the real band never floors — caves and
		// sub-floor digging survive there). The band-A grid cell is
		// the whole 16-cell slab and DOES straddle the floor, so this
		// tier gates per VOXEL: the slab rows entirely below the
		// floor are air. The waterline row (y == p_yfloor, the
		// aquifer top) STAYS — the band-A water surface (the
		// translucent +Y face of the floor voxel) and the opaque cap
		// (the -Y face of that same row, exactly at the floor) ride
		// on it. The snap bake, the ro face walk and the neighbor
		// culling all read the zeroed rows (id 0 = air); the stale
		// nz counts over-count only (a fully-zeroed slab just scans
		// as air and stamps empty — the all-air early-out is the
		// only nz consumer and it fires on == 0).
		if (p_yfloor >= 0) {
			for (int si = 0; si < (int)dflat.size(); si++) {
				int cut = std::clamp(p_yfloor - si * 16, 0, 16); // rows y < p_yfloor
				if (cut > 0 && !dflat[si].empty())
					memset(dflat[si].data(), 0, (size_t)cut * 256);
				if (cut > 0 && !fflat[si].empty())
					memset(fflat[si].data(), 0, (size_t)cut * 256);
			}
		}
		Nv nv;
		parse_nbs(nbs, nv);

		// Light: three sources — (AC-0283 P2) the STAR payload (the
		// AweStarlight engine's settled nibbles, captured at dispatch under
		// the 3x3x3 box gate — expanded here on the worker into the classic
		// light dict + the 8 margin strips: no pull kernel, no ctx strips,
		// no recompute — the gate made the bake final; THE GAME'S SLAB
		// LIGHT — AC-0283 P4: the slab + remesh lanes always carry it); the
		// cached eff (has "mask", consumed as-is); else recompute through
		// the SHARED C++ pull kernel (byte-identical to the AweLighting
		// class — lightprobe 100% exact). P4: that branch is the LEGACY
		// path — the meshprobe arm + the no-engine fallback + the
		// edit-fallback full bake + the tex-refresh rebuild ride it.
		Dictionary light = eff;
		bool star = (bool)light.get("star", false);
		std::vector<std::vector<uint8_t>> star_strips(8);
		bool light_recomputed = !star && (light.is_empty() || (light.get("mask", Variant()).get_type() == Variant::NIL));
		if (star) {
			int64_t tl = now_msec();
			PackedByteArray effc = light.get("eff", PackedByteArray());
			PackedByteArray blkc = light.get("blk", PackedByteArray());
			int has_glow = (int)light.get("has_glow", 0);
			int blk_inj = (int)light.get("blk_inj", 0);
			int w_lo = (int)light.get("w_lo", 0);
			Array side = light.get("side", Array());
			Array corner = light.get("corner", Array());
			// the mask: (blk > 0) iff (has_glow || blk_inj), else all-zero
			// (lighting.cpp 354-358) — full 256*h (mask_sample's contract)
			bool has_blk = (has_glow || blk_inj) && blkc.size() == (int)(256 * (size_t)h);
			PackedByteArray mask;
			mask.resize((size_t)256 * h);
			PackedInt32Array ring;
			if (has_blk) {
				const uint8_t *bp = blkc.ptr();
				uint8_t *mp = mask.ptrw();
				for (size_t i = 0; i < (size_t)256 * h; i++)
					mp[i] = bp[i] > 0 ? 1 : 0;
				// the AC-0091 19-bit pack (lighting.cpp 359-379: side
				// 0=E x=15, 1=W x=0, 2=N z=15, 3=S z=0)
				for (int y = 0; y < h; y++) {
					size_t row = (size_t)y * 256;
					for (int t2 = 0; t2 < 16; t2++) {
						int yy = y * 16 + t2;
						int lv0 = bp[row | (t2 << 4) | 15];
						if (lv0 > 0)
							ring.append((0 << 17) | (yy << 4) | lv0);
						int lv1 = bp[row | (t2 << 4)];
						if (lv1 > 0)
							ring.append((1 << 17) | (yy << 4) | lv1);
						int lv2 = bp[row | (15 << 4) | t2];
						if (lv2 > 0)
							ring.append((2 << 17) | (yy << 4) | lv2);
						int lv3 = bp[row | t2];
						if (lv3 > 0)
							ring.append((3 << 17) | (yy << 4) | lv3);
					}
				}
			}
			Dictionary ld;
			ld["mn"] = Vector3i(cx * SIZE, 0, cz * SIZE);
			ld["w"] = (int64_t)16;
			ld["d"] = (int64_t)16;
			ld["arr"] = effc;
			ld["blk_src"] = has_glow;
			ld["mask"] = mask;
			ld["ring"] = ring;
			light = ld; // res["light"] = this (eff cache / last_eff / save shape)
			// the 8 margin strips (the bake_box layout): zero-fill full
			// height, fill the payload rows [w_lo, w_lo+rows) — side
			// idx = c*16*h + y*16 + t (c=0 inner, c=1 outer), corner
			// idx = (a*2+b)*h + y
			for (int k = 0; k < 4; k++)
				star_strips[k].assign((size_t)2 * 16 * h, 0);
			for (int k = 4; k < 8; k++)
				star_strips[k].assign((size_t)4 * h, 0);
			for (int k = 0; k < 4 && k < (int)side.size(); k++) {
				PackedByteArray sp = side[k];
				int sprows = (int)sp.size() / 32;
				for (int r = 0; r < sprows; r++) {
					int y = w_lo + r;
					if (y < 0 || y >= h)
						continue;
					const uint8_t *sr = sp.ptr() + (size_t)r * 32;
					for (int t = 0; t < 16; t++) {
						star_strips[k][(size_t)y * 16 + t] = sr[t];
						star_strips[k][(size_t)16 * h + (size_t)y * 16 + t] = sr[16 + t];
					}
				}
			}
			for (int k = 0; k < 4 && k < (int)corner.size(); k++) {
				PackedByteArray cp = corner[k];
				int cprows = (int)cp.size() / 4;
				for (int r = 0; r < cprows; r++) {
					int y = w_lo + r;
					if (y < 0 || y >= h)
						continue;
					const uint8_t *cr = cp.ptr() + (size_t)r * 4;
					for (int m = 0; m < 4; m++)
						star_strips[4 + k][(size_t)m * h + y] = cr[m];
				}
			}
			C.eff_strips.n = 8;
			for (int k = 0; k < 8; k++) {
				C.eff_strips.ptr[k] = star_strips[k].data();
				C.eff_strips.size[k] = (int)star_strips[k].size();
			}
			ph_light = now_msec() - tl;
		}
		if (light_recomputed) {
			int64_t tl = now_msec();
			// The kernel consumes the raw strip Arrays exactly like the
			// GDScript path (side strips 2*16*h, corners 4*h).
			Array blk_strips = ctx.get("blk_strips", Array());
			Array blk_strips_b = ctx.get("blk_strips_b", Array());
			awelight::PullOut r = awelight::pull(data, h, blk_strips, blk_strips_b, topv, p_att.ptr(), (int)p_att.size(), p_glow.ptr(), (int)p_glow.size(), nullptr);
			ph_light = now_msec() - tl;
			Dictionary ld;
			ld["mn"] = Vector3i(cx * SIZE, 0, cz * SIZE);
			ld["w"] = (int64_t)16;
			ld["d"] = (int64_t)16;
			ld["arr"] = awecommon::pba_from(r.eff);
			ld["blk_src"] = r.blk_src;
			ld["mask"] = awecommon::pba_from(r.mask);
			PackedInt32Array ring;
			ring.resize((int64_t)r.ring.size());
			if (!r.ring.empty())
				std::memcpy(ring.ptrw(), r.ring.data(), r.ring.size() * sizeof(int32_t));
			ld["ring"] = ring;
			light = ld;
		}

		int64_t tb = now_msec();
		// The 20x20 bake box + the snap (both scoped y_lo-2 .. y_hi+1).
		int b_lo = std::max(0, y_lo - 2);
		int b_hi = std::min(h - 1, y_hi + 1);
		std::vector<uint8_t> barr;
		Vector3i bmn;
		bake_box(light, C.eff_strips, h, b_lo, b_hi, barr, bmn);
		std::vector<uint8_t> snap((size_t)SNAP_ROW * h, 0);
		std::vector<uint8_t> snap_fl((size_t)SNAP_ROW * h, 0);
		build_snap_data(snap, snap_fl, dflat, fflat, &dsrc, &fsrc, nv, h, b_lo, b_hi);
		ph_box = now_msec() - tb;

		bool has_tex = C.has_tex;
		const uint8_t *bmask_ptr = nullptr;
		int bmask_sz = 0;
		{
			Variant mv = light.get("mask", Variant());
			if (mv.get_type() == Variant::PACKED_BYTE_ARRAY) {
				PackedByteArray mb = mv;
				bmask_ptr = (const uint8_t *)mb.ptr();
				bmask_sz = (int)mb.size();
			}
		}

		// The scoped (edit) fast-pass: sgrid + per-column boundary bitmask
		// (AC-0187) — the interior test becomes one bitmask read.
		bool scoped = (!was_full) && ((si1 - si0 + 1) < slab_n);
		std::vector<uint8_t> sgrid;
		std::vector<int32_t> ymask;
		if (scoped) {
			int GW = 18;
			int yb0 = std::max(0, y_lo - 1);
			int yb1 = std::min(h - 1, y_hi);
			sgrid.assign((size_t)(yb1 - yb0 + 1) * GW * GW, 0);
			for (int y = yb0; y <= yb1; y++) {
				int grow = (y - yb0) * GW * GW;
				const SlabSrc &ds = dsrc[y >> 4];
				int drowg = (y & 15) << 8;
				for (int lz = -1; lz < 17; lz++) {
					int base = grow + (lz + 1) * GW;
					for (int lx = -1; lx < 17; lx++) {
						int id2;
						if (y >= y_lo && y < y_hi && lx >= 0 && lz >= 0 && lx < 16 && lz < 16) {
							// AC-0253: the own cell via the slab source
							// (the flat view load — the pre-AC-0253 cost).
							// AC-0355: the lower bounds are LOAD-BEARING —
							// the loops run -1..16, so without them the
							// GUARD cells (lx=-1 / lz=-1) of in-window
							// rows took the own-cell branch with
							// ds.cell(negative offset) — an out-of-bounds
							// flat read (garbage) instead of the snap ring
							// read. The ymask boundary test then saw
							// garbage neighbours: a seam cell beside a
							// cave/air could read "all six solid" and be
							// misclassified INTERIOR — its face silently
							// dropped from every SCOPED build (the per-
							// slab lane's steady-state mesh) while the
							// full path (s_is_interior on the real snap)
							// stayed complete. The see-through holes at
							// chunk-boundary caves/cliff openings.
							id2 = ds.cell(drowg + (lz << 4) + lx);
						} else {
							id2 = snap[(size_t)y * SNAP_ROW + (lz + 1) * 18 + (lx + 1)];
						}
						if (C.stab[id2] > 0)
							sgrid[(size_t)base + lx + 1] = 1;
					}
				}
			}
			ymask.assign(256, 0);
			for (int lz = 0; lz < 16; lz++) {
				for (int lx = 0; lx < 16; lx++) {
					int64_t m = 0;
					int gi0 = (y_lo - yb0) * GW * GW + (lz + 1) * GW + (lx + 1);
					for (int r = 0; r < y_hi - y_lo; r++) {
						int gi = gi0 + r * GW * GW;
						bool bnd = false;
						if ((r == 0 && y_lo == 0) || sgrid[(size_t)gi - GW * GW] == 0)
							bnd = true;
						else if ((r == y_hi - y_lo - 1 && y_hi >= h) || sgrid[(size_t)gi + GW * GW] == 0)
							bnd = true;
						else if (sgrid[(size_t)gi - 1] == 0)
							bnd = true;
						else if (sgrid[(size_t)gi + 1] == 0)
							bnd = true;
						else if (sgrid[(size_t)gi - GW] == 0)
							bnd = true;
						else if (sgrid[(size_t)gi + GW] == 0)
							bnd = true;
						if (bnd)
							m |= (int64_t)1 << r;
					}
					ymask[(lz << 4) | lx] = (int32_t)m;
				}
			}
		}

		// The ro scan (chunk.gd:1851-1905): per-slab cell walk over the
		// flat slab views (AC-0197: empty slab = count + skip; fluids 5/24;
		// interior skip; xtab/ktab routing).
		int64_t tf = now_msec();
		std::vector<FRec> ro, rc_o, rk;
		std::vector<XRec> rq;
		std::vector<FluidRec> rf_w, rf_l;
		std::vector<int> c_ns(slab_n, 0);
		// AC-0234 vertical window: the keep mask (24 bytes, one per slab;
		// empty = build every slab, the pre-AC-0234 behavior). A masked-out
		// slab is counted + skipped EXACTLY like an all-air slab: its cells
		// render as the pre-baked black cap box on the GDScript side, and
		// its RAW data still feeds the snap (built above, before this scan)
		// so the faces of built neighbors against it cull correctly (they
		// hide behind the opaque box, no z-fighting).
		const uint8_t *vmask = p_mask.ptr();
		const int vmsz = (int)p_mask.size();
		for (int si = si0; si <= si1; si++) {
			const SlabSrc &src = dsrc[si];
			int lo = si * 16;
			int c_hi = std::min(16, y_hi - lo);
			if ((vmsz > si && vmask[si] == 0) || src.empty || src.nz == 0) {
				// All-air slab: every cell is id 0 (stab 0) — count + skip.
				// AC-0253: nz == 0 (== the bitset count) is the instant
				// all-air early-out; a present-but-empty entry takes the
				// same path. (A window-masked slab takes the same path —
				// row[6] (full-solid) and the emits see it as empty.)
				c_ns[si] += c_hi * 256;
				continue;
			}
			const uint8_t *dflat = src.flat; // non-null: empty early-out above
			for (int cy = 0; cy < c_hi; cy++) {
				int y = lo + cy;
				int r0 = cy << 8;
				for (int lz = 0; lz < SIZE; lz++) {
					int drow = r0 + (lz << 4);
					for (int lx = 0; lx < SIZE; lx++) {
						// The id is needed for routing/culling — the flat
						// view load (exactly the pre-AC-0253 cost).
						int id = dflat[drow + lx];
						if (C.stab[id] == 0)
							c_ns[si] += 1;
						if (id == 0)
							continue;
						if (id == 5 || id == 24) {
							float hgt = fluid_hgt(lx, y, lz, snap_fl);
							if (hgt > 0.0f) {
								// (the GDScript also computes the quad budget
								// _s_fluid_quad_count here — pre-size only, no
								// effect on the emitted quads)
								if (id == 5)
									rf_w.push_back(FluidRec{lx, y, lz, id, hgt});
								else
									rf_l.push_back(FluidRec{lx, y, lz, id, hgt});
							}
							continue;
						}
						if (C.oktab[id] == 0)
							continue;
						if (C.stab[id] > 0) {
							bool skip = false;
							if (scoped) {
								// int64 shift like GDScript's 64-bit ints (r
								// >= 31 would be UB in C++ int).
								skip = (((int64_t)ymask[(lz << 4) | lx] & ((int64_t)1 << (y - y_lo))) == 0);
							} else {
								skip = s_is_interior(lx, y, lz, snap, C.stab, h);
							}
							if (skip)
								continue;
						}
						if (C.xtab[id] > 0) {
							if (!C.coarse && C.ttab[id] > 0)
								s_faces(rc_o, C.stab, lx, y, lz, id, snap, h, C.ktab, C.xtab);
							else if (!C.coarse)
								rq.push_back(XRec{lx, y, lz, id});
						} else if (C.ktab[id] > 0) {
							if (C.coarse)
								s_faces(ro, C.stab, lx, y, lz, id, snap, h, C.ktab, C.xtab);
							else
								s_faces(rk, C.stab, lx, y, lz, id, snap, h, C.ktab, C.xtab);
						} else {
							s_faces(ro, C.stab, lx, y, lz, id, snap, h, C.ktab, C.xtab);
						}
					}
				}
			}
		}
		ph_faces = now_msec() - tf;

		std::vector<Acc> s_ao(slab_n), s_ac(slab_n), s_af_w(slab_n), s_af_l(slab_n), s_ak(slab_n), s_ax(slab_n);

		// The emits (AC-0187: scoped builds take the per-face path).
		std::vector<int64_t> phet(6, 0);
		{
			int64_t te = now_msec();
			if (M.nonempty && !ro.empty() && !scoped)
				emit_ro_merged(ro, s_ao, bmn, barr.data(), 20, 20, cx, cz, has_tex, C, M, bmask_ptr, bmask_sz);
			else
				emit_faces(ro, s_ao, bmn, barr.data(), 20, 20, cx, cz, has_tex, C, C.xtab, bmask_ptr, bmask_sz);
			phet[0] = now_msec() - te;
			te = now_msec();
			emit_faces(rc_o, s_ac, bmn, barr.data(), 20, 20, cx, cz, has_tex, C, C.xtab, bmask_ptr, bmask_sz);
			phet[1] = now_msec() - te;
			te = now_msec();
			emit_fluid(rf_w, s_af_w, snap, snap_fl, has_tex, C, h);
			phet[2] = now_msec() - te;
			te = now_msec();
			emit_fluid(rf_l, s_af_l, snap, snap_fl, has_tex, C, h);
			phet[3] = now_msec() - te;
			te = now_msec();
			emit_faces(rk, s_ak, bmn, barr.data(), 20, 20, cx, cz, has_tex, C, C.xtab, bmask_ptr, bmask_sz);
			phet[4] = now_msec() - te;
			te = now_msec();
			emit_xquad(rq, s_ax, bmn, barr.data(), 20, 20, cx, cz, has_tex, C, bmask_ptr, bmask_sz);
			phet[5] = now_msec() - te;
		}
		int64_t ph_emit = phet[0] + phet[1] + phet[2] + phet[3] + phet[4] + phet[5];

		Array slabs_out;
		for (int si = si0; si <= si1; si++) {
			Array row;
			row.append(acc_to_dict(s_ao[si]));
			row.append(acc_to_dict(s_ac[si]));
			row.append(acc_to_dict(s_af_w[si]));
			row.append(acc_to_dict(s_af_l[si]));
			row.append(acc_to_dict(s_ak[si]));
			row.append(acc_to_dict(s_ax[si]));
			row.append(c_ns[si] == 0);
			slabs_out.append(row);
		}

		Dictionary res;
		res["slabs"] = slabs_out;
		res["light"] = light;
		res["light_recomputed"] = light_recomputed;
		res["wms"] = (int64_t)(now_msec() - t0);
		res["si0"] = (int64_t)si0;
		res["si1"] = (int64_t)si1;
		res["nq"] = (int64_t)(ro.size() + rc_o.size() + rk.size() + rq.size() + rf_w.size() + rf_l.size());
		Array ns;
		ns.append((int64_t)ro.size());
		ns.append((int64_t)rc_o.size());
		ns.append((int64_t)rk.size());
		ns.append((int64_t)rq.size());
		ns.append((int64_t)rf_w.size());
		ns.append((int64_t)rf_l.size());
		res["ns"] = ns;
		Array phet_out;
		for (int i = 0; i < 6; i++)
			phet_out.append(phet[i]);
		res["phet"] = phet_out;
		Array ph;
		ph.append(ph_light);
		ph.append(ph_box);
		ph.append(ph_emit);
		ph.append(ph_faces);
		res["ph"] = ph;
		return res;
	}

	// AC-0211: deep copy of a paletted slab array — the C++ stand-in for
	// ChunkIO._slabs_deepcopy (the dispatch's value-copy for the worker
	// lane). Byte-identical output shape ({n,b,p,i,nz} dicts, nulls kept,
	// p/i true byte copies — no COW sharing with the live chunk).
	Array slab_copy(const Array &slabs) {
		Array out;
		out.resize(slabs.size());
		for (int k = 0; k < (int)slabs.size(); k++) {
			Variant v = slabs[k];
			if (v.get_type() != Variant::DICTIONARY) {
				out[k] = v;
				continue;
			}
			Dictionary d = v;
			Dictionary o;
			o["n"] = (int64_t)(int)d.get("n", 0);
			o["b"] = (int64_t)(int)d.get("b", 0);
			o["p"] = pba_deep(d.get("p", PackedByteArray()));
			o["i"] = pba_deep(d.get("i", PackedByteArray()));
			o["nz"] = (int64_t)(int)d.get("nz", 0);
			// AC-0253: the solid/air bitset rides the dispatch value copy
			// (the worker's build_accs / low_emit_avg read it as the air/
			// solid fast path; entries without "bs" take the decode
			// fallback, exactly as before).
			PackedByteArray sbs = d.get("bs", PackedByteArray());
			if (sbs.size() == awecommon::S3B)
				o["bs"] = pba_deep(sbs);
			// AC-0258 (the AC-0261 fix): the clutter count "nc" rides the
			// dispatch value copy too — without it EVERY dispatch slab
			// took the clutter-free fast path and flowers (18/19) counted
			// as solid + tinted the avg colors (the r16 AVERAGEBAD).
			// Mirrors ChunkIOPalette.slab_copy in chunk_io.cpp.
			if (d.has("nc"))
				o["nc"] = (int64_t)(int)d.get("nc", 0);
			out[k] = o;
		}
		return out;
	}

	// AC-0211: the compact edge-neighbor snap ring (the main-thread
	// snapshot that replaces the per-neighbor _slabs_deepcopy of all 24
	// slabs — the worker only ever reads this boundary slice). d/f = the
	// neighbor's paletted slab arrays; dx/dz = the edge offset
	// (-1,0)/(1,0)/(0,-1)/(0,1). Returns {"d": PackedByteArray(slabs*256),
	// "f": ...} with layout slab*256 + y_in*16 + t.
	// AC-0237: p_genkeep = the NEIGHBOR's 24-byte generated mask (slab si
	// generated iff p_genkeep[si] != 0; EMPTY = every slab generated —
	// the pre-AC-0237 behavior). A slab the neighbor NEVER generated has
	// no section; for face culling it must read as SOLID (stone), not
	// air — the boundary face hides behind the window's cap box (the
	// same outcome as a real solid slab; no z-fight). The re-entry regen
	// (world.gd) + the neighbor re-mesh on data landing keep it honest:
	// when the slab is generated, its real data replaces the stone.
	Dictionary snap_rings(const Array &d, const Array &f, int dx, int dz, PackedByteArray p_genkeep, PackedByteArray p_far, int p_sea) {
		std::vector<uint8_t> rd((size_t)d.size() * 256, 0);
		std::vector<uint8_t> rf((size_t)f.size() * 256, 0);
		if (p_far.size() == 1024) {
			// AC-0284b: a FAR (h-only) neighbor — synthesize the EXACT
			// skip-fill edge row (solid 0..S = max(H, sea); the aquifer
			// water H+1..sea; the fill top ids bedrock/water/top/
			// dirt-sand/stone) so the boundary culling + fluid rings
			// match the AC-0284a skip slab's rings bit-for-bit (the far
			// column's slabs are all null — the ring would otherwise
			// read all-air and the real band would over-draw its
			// boundary wall against the halo, z-fighting the halo's own
			// boundary quads).
			const uint8_t *fp = p_far.ptr();
			for (int k = 0; k < (int)d.size(); k++) {
				int y0 = k * 16;
				for (int y_in = 0; y_in < 16; y_in++) {
					int y = y0 + y_in;
					for (int t = 0; t < 16; t++) {
						int lx = (dx != 0) ? (dx < 0 ? 15 : 0) : t;
						int lz = (dz != 0) ? (dz < 0 ? 15 : 0) : t;
						int idx = lz * 16 + lx;
						int H = (int)fp[2 * idx] | ((int)fp[2 * idx + 1] << 8);
						int id;
						if (y < 5) // AC-0292: the bedrock band (the fill mirror)
							id = 11; // B_BEDROCK
						else if (H < p_sea && y >= H + 1 && y <= p_sea)
							id = 5; // B_WATER
						else if (y == H)
							id = (int)fp[768 + idx];
						else if (y >= H - 3)
							id = ((int)fp[512 + idx] == 1) ? 4 : 2; // B_SAND / B_DIRT
						else
							id = 3; // B_STONE (the ore chain is opaque+solid — same culling)
						rd[(size_t)k * 256 + y_in * 16 + t] = (uint8_t)id;
						rf[(size_t)k * 256 + y_in * 16 + t] = (uint8_t)((id == 5) ? 5 : 0);
					}
				}
			}
			Dictionary out;
			out["d"] = awecommon::pba_from(rd);
			out["f"] = awecommon::pba_from(rf);
			return out;
		}
		for (int k = 0; k < (int)d.size(); k++)
			ring_slice(d[k], k * 256, dx, dz, rd);
		if (p_genkeep.size() > 0) {
			const uint8_t *gk = p_genkeep.ptr();
			for (int k = 0; k < (int)d.size() && k < (int)p_genkeep.size(); k++) {
				if (d[k].get_type() != Variant::DICTIONARY && gk[k] == 0)
					std::fill(rd.begin() + (size_t)k * 256, rd.begin() + (size_t)(k + 1) * 256, (uint8_t)awecommon::B_STONE);
			}
		}
		for (int k = 0; k < (int)f.size(); k++)
			ring_slice(f[k], k * 256, dx, dz, rf);
		Dictionary out;
		out["d"] = awecommon::pba_from(rd);
		out["f"] = awecommon::pba_from(rf);
		return out;
	}

	// AC-0211: the sync-path snap (the chunk.gd _build_snap core) — the
	// own 16x16 + the 4 edge-neighbor rings, the paletted slabs decoded
	// in C++ (no GDScript flat_data()/flat_fl() materialization). rings =
	// [west, east, south, north], each a snap_rings() Dictionary or null
	// (missing/empty neighbor = air — the GDScript parity; the corner ring
	// cells stay 0, as in the GDScript). Returns {"snap":
	// PackedByteArray(18*18*h), "snap_fl": ...} byte-identical to the
	// GDScript _build_snap output (the world==null get_world_block
	// fallback stays GDScript).
	Dictionary sync_snap(const Array &own_d, const Array &own_f, const Array &rings, int h) {
		std::vector<std::vector<uint8_t>> dviews, fviews;
		awecommon::slab_views(own_d, dviews);
		awecommon::slab_views(own_f, fviews);
		Nv nv;
		for (int k = 0; k < 4; k++) {
			Variant v = (k < (int)rings.size()) ? rings[k] : Variant();
			if (v.get_type() != Variant::DICTIONARY)
				continue;
			Dictionary r = v;
			PackedByteArray rd = r.get("d", PackedByteArray());
			PackedByteArray rf = r.get("f", PackedByteArray());
			int nsl = (int)rd.size() / 256;
			nv.nd[k].resize(nsl);
			for (int s = 0; s < nsl; s++)
				nv.nd[k][s].assign(rd.ptr() + s * 256, rd.ptr() + s * 256 + 256);
			int nfl = (int)rf.size() / 256;
			nv.nfd[k].resize(nfl);
			for (int s = 0; s < nfl; s++)
				nv.nfd[k][s].assign(rf.ptr() + s * 256, rf.ptr() + s * 256 + 256);
		}
		std::vector<uint8_t> snap((size_t)SNAP_ROW * h, 0);
		std::vector<uint8_t> snap_fl((size_t)SNAP_ROW * h, 0);
		build_snap_data(snap, snap_fl, dviews, fviews, nullptr, nullptr, nv, h, 0, h - 1);
		Dictionary out;
		out["snap"] = awecommon::pba_from(snap);
		out["snap_fl"] = awecommon::pba_from(snap_fl);
		return out;
	}

	// AC-0211: the scoped handoff stale check (world.gd
	// threadmesh_handoff) — row-by-row 256-B equality of two paletted
	// slab arrays over y in [y_lo, y_hi], decoded in C++ (no 4096 flat
	// materialization per row). Byte-identical verdict to the GDScript
	// row loop (a null slab row = zero row, as in _slabs_row).
	bool rows_eq(const Array &a, const Array &b, int y_lo, int y_hi) {
		if (a.size() != b.size())
			return false;
		uint8_t ra[256];
		uint8_t rb[256];
		for (int y = y_lo; y <= y_hi; y++) {
			if (y < 0 || y >= (int)a.size() * 16)
				return false;
			int s = y >> 4;
			slab_row(a[s], y & 15, ra);
			slab_row(b[s], y & 15, rb);
			if (std::memcmp(ra, rb, 256) != 0)
				return false;
		}
		return true;
	}

	// AC-0237: does any EDGE-boundary cell (the four shared faces: x=0/15,
	// z=0/15) of slabs lo..hi decode to AIR (0)? The REGEN-neighbor
	// re-mesh gate: a neighbor built against a stone-snap of the
	// ungenerated slab owes a rebuild only when the REAL boundary has
	// air (a face to emit); an all-non-air boundary keeps the stone-snap
	// culling correct (face-vs-face -- the id is irrelevant to culling).
	// A null slab in the range is all-air (returns true).
	bool slab_boundary_air(const Array &d, int lo, int hi) {
		int nsl = (int)d.size();
		if (lo < 0)
			lo = 0;
		if (hi >= nsl)
			hi = nsl - 1;
		uint8_t row[256];
		for (int s = lo; s <= hi; s++) {
			for (int y_in = 0; y_in < 16; y_in++) {
				slab_row(d[s], y_in, row);
				for (int t = 0; t < 16; t++) {
					if (row[t] == 0 || row[240 + t] == 0 || row[t * 16] == 0 || row[t * 16 + 15] == 0)
						return true;
				}
			}
		}
		return false;
	}
};

void register_classes() {
	GDREGISTER_CLASS(AweMesh);
}

} // namespace awemesh
