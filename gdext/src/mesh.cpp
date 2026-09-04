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
// LIGHT: an empty/maskless eff recomputes light through the SAME C++ pull
// kernel the AweLighting class uses (awelight::pull — same .so), so the
// C++ mesh's light is byte-identical to the class path (lightprobe:
// 100% exact). A cached eff (with "mask") is consumed as-is.
//
// WORKER SAFETY: no Data/Game autoloads — every table arrives as a value
// copy in ctx/ms/nbs/eff (the same copies the GDScript worker consumes).
//
// Toggle: AWECRAFT_MESHCPP=0 forces the GDScript path (chunk.gd
// build_accs); unset/1 = C++ whenever this library registered AweMesh
// (wired at world.gd _tm_worker_run).

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
		awecommon::slab_views(nb.get("d", Array()), out.nd[k]);
		awecommon::slab_views(nb.get("f", Array()), out.nfd[k]);
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

static void build_snap_data(std::vector<uint8_t> &snap, std::vector<uint8_t> &snap_fl, const std::vector<std::vector<uint8_t>> &dviews, const std::vector<std::vector<uint8_t>> &fviews, const Nv &nv, int h, int y_lo, int y_hi) {
	if (y_hi < 0)
		y_hi = h - 1;
	// Own 16x16 (snap ring offset +1).
	for (int y = y_lo; y <= y_hi; y++) {
		size_t si = (size_t)y * SNAP_ROW;
		const std::vector<uint8_t> &dslab = dviews[y >> 4];
		const std::vector<uint8_t> &fslab = fviews[y >> 4];
		int drow = (y & 15) << 8;
		for (int lz = 0; lz < SIZE; lz++) {
			int szi = (int)si + (lz + 1) * SNAP_W;
			int r0 = drow + (lz << 4);
			for (int lx = 0; lx < SIZE; lx++) {
				int dv = dslab.empty() ? 0 : (int)dslab[r0 + lx];
				snap[(size_t)szi + lx + 1] = (uint8_t)dv;
				int fv = fslab.empty() ? 0 : (int)fslab[r0 + lx];
				if (fv == 0 && (dv == 5 || dv == 24))
					fv = 8;
				snap_fl[(size_t)szi + lx + 1] = (uint8_t)fv;
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
						int gi = xb.g[g2];
						int dv = nd.empty() ? 0 : (int)nd[r0 + gi];
						int fv = nfd.empty() ? 0 : (int)nfd[r0 + gi];
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

// _s_faces: the 6-face exposure test (skip same-id + solid neighbors).
static void s_faces(std::vector<FRec> &recs, const uint8_t *stab, int lx, int y, int lz, int id, const std::vector<uint8_t> &snap, int h) {
	int sxi = (lz + 1) * SNAP_W + (lx + 1);
	for (int fi = 0; fi < 6; fi++) {
		int ny = y + FN[fi][1];
		int nb;
		if (ny < 0 || ny >= h) {
			nb = 0;
		} else {
			nb = snap[(size_t)ny * SNAP_ROW + sxi + FN[fi][2] * SNAP_W + FN[fi][0]];
		}
		if (nb == id)
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
		if (above != id) {
			float top_h = std::min(hgt, (id == 5) ? 0.875f : 0.95f);
			Color c = has_tex ? mul_cc(Color(0.95f, 0.95f, 0.95f, 1.0f), tint_t) : mul_cf(ctx.ct[id], 0.95f);
			const float *uvs = s_uvc(uvc, ctx, id, 2, 1);
			static const int N_TOP[3] = {0, 1, 0};
			qwrite(sa, c, N_TOP, uvs, FCV[2], lx, y, lz, top_h, top_h, top_h, top_h);
		}
		for (int fi : {0, 1, 4, 5}) {
			const int n[3] = {FN[fi][0], FN[fi][1], FN[fi][2]};
			int nb = snap[(size_t)y * SNAP_ROW + rowl + n[2] * SNAP_W + n[0]];
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
		if (y > 0 && below != id) {
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

// The registered class.
class AweMesh : public RefCounted {
	GDCLASS(AweMesh, RefCounted)

public:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("build_accs", "data", "fl", "cx", "cz", "nbs", "ctx", "ms", "eff", "si0", "si1", "d_off", "att", "glow"), &AweMesh::build_accs);
	}

	// Lossless port of ChunkScript.build_accs (chunk.gd:1683). data/fl =
	// the 24-slab paletted arrays (decoded HERE — the AC-0203 follow-on);
	// nbs = the 4 edge neighbors {d, f} (keys -1,0/1,0/0,-1/0,1); ctx = the make_ctx snapshot +
	// dispatch additions (strips/top/coarse/uv_scale); ms = the
	// merge-atlas snapshot; eff = the light dict (empty = recompute
	// through the shared C++ pull kernel); att/glow = the pre-warmed
	// Lighting._att/_glow tables. Returns the SAME shape as the GDScript:
	// {slabs, light, light_recomputed, wms, si0, si1, nq, ns, phet, ph}.
	Dictionary build_accs(const Array &data, const Array &fl, int cx, int cz, const Dictionary &nbs, const Dictionary &ctx, const Dictionary &ms, const Dictionary &eff, int p_si0, int p_si1, int p_d_off, const PackedByteArray &p_att, const PackedByteArray &p_glow) {
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

		// Slab views — the paletted decode happens HERE (C++ int lookups).
		std::vector<std::vector<uint8_t>> dviews, fviews;
		awecommon::slab_views(data, dviews);
		awecommon::slab_views(fl, fviews);
		Nv nv;
		parse_nbs(nbs, nv);

		// Light: cached eff (has "mask") is consumed as-is; else recompute
		// through the SHARED C++ pull kernel (byte-identical to the
		// AweLighting class — lightprobe 100% exact).
		Dictionary light = eff;
		bool light_recomputed = light.is_empty() || (light.get("mask", Variant()).get_type() == Variant::NIL);
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
		build_snap_data(snap, snap_fl, dviews, fviews, nv, h, b_lo, b_hi);
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
				const std::vector<uint8_t> &dslab = dviews[y >> 4];
				int drowg = (y & 15) << 8;
				for (int lz = -1; lz < 17; lz++) {
					int base = grow + (lz + 1) * GW;
					for (int lx = -1; lx < 17; lx++) {
						int id2;
						if (y >= y_lo && y < y_hi && lx < 16 && lz < 16) {
							id2 = dslab.empty() ? 0 : (int)dslab[drowg + (lz << 4) + lx];
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
		for (int si = si0; si <= si1; si++) {
			const std::vector<uint8_t> &dslab = dviews[si];
			int lo = si * 16;
			int c_hi = std::min(16, y_hi - lo);
			if (dslab.empty()) {
				// All-air slab: every cell is id 0 (stab 0) — count + skip.
				c_ns[si] += c_hi * 256;
				continue;
			}
			for (int cy = 0; cy < c_hi; cy++) {
				int y = lo + cy;
				int r0 = cy << 8;
				for (int lz = 0; lz < SIZE; lz++) {
					int drow = r0 + (lz << 4);
					for (int lx = 0; lx < SIZE; lx++) {
						int id = dslab[drow + lx];
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
								s_faces(rc_o, C.stab, lx, y, lz, id, snap, h);
							else if (!C.coarse)
								rq.push_back(XRec{lx, y, lz, id});
						} else if (C.ktab[id] > 0) {
							if (C.coarse)
								s_faces(ro, C.stab, lx, y, lz, id, snap, h);
							else
								s_faces(rk, C.stab, lx, y, lz, id, snap, h);
						} else {
							s_faces(ro, C.stab, lx, y, lz, id, snap, h);
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
};

void register_classes() {
	GDREGISTER_CLASS(AweMesh);
}

} // namespace awemesh
