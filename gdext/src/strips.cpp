// AC-0207: GDExtension native port of the palette-strips hot path
// (godot/world/world.gd _strips_for + _side_blk_strip + _side_eff_strip +
// _corner_eff_strip + _compute_face_blk/_chunk_has_glow — the LAST GDScript
// hot spot; the AC-0165/AC-0188/AC-0189/AC-0190 pipeline, same .so/.dll,
// same chunkio_library_init entry symbol).
//
// LOSSLESS INVARIANT: AweStrips.compute_strips produces the SAME eff/blk/
// blk_b strips as World._strips_for (GDScript) for the same input, and
// AweStrips.compute_face produces the SAME [E,W,S,N] settled block-light
// faces as World._compute_face_blk. Verified by AWECRAFT_LOGIC=stripsprobe
// (C++ vs GDScript at N chunks: eff x8 + blk x4 + blk_b x4 strips and the
// x4 faces byte-identical per chunk; gate: 100% exact).
//
// Ported verbatim (integer-only kernels — no float):
//   * _side_blk_strip v channel (world.gd:2727-2849): the per-column
//     solid_top palette probe (a slab whose palette holds no solid id
//     cannot close the column — the AC-0203 recenter fix) + the bottom-up
//     per-slab cell walk (null -> sky/eff only; uniform -> glow or
//     eff/sky; paletted/raw -> per-cell glow/eff/sky, the AC-0129 sky
//     carry: source EXACT (glow), else max(eff_n, sky_n)). The cell values
//     come from the C++ decode (awe_common slab_unpack — free int lookup)
//     instead of the GDScript ChunkIO._slab_getbits per cell (24k Variant
//     calls per dispatch = the 74 ms hitch); the has_solid probe reads the
//     PALETTE only (paletted cell set == palette; raw slabs scan 4096 —
//     rare), exactly like the GDScript.
//   * _side_eff_strip (world.gd:2484) + _corner_eff_strip (world.gd:2860):
//     the last_eff boundary gathers (2x16xh sides, 2x2xh corners).
//   * _compute_face_blk (world.gd:2623) + _chunk_has_glow (world.gd:2602):
//     the glow palette probe, the flat expansion, the glow seed, the
//     bucket-16 flood + UN-gated boundary injection (the SAME C++ kernels
//     the pull path runs — awelight::flood_flat/blk_inject, lighting.cpp —
//     byte-identical by construction), the no-glow zero-column probe +
//     real-column re-inject (AC-0203 recenter fix), the [E,W,S,N] face
//     extract (2*16*h, c=0 = the inject half, c=1 zero).
//
// The face MEMO stays in GDScript (World._face_blk, keyed by data_gen + the
// 4 neighbor (key, eff_gen) deps + the in-flight cycle guard): compute_face
// is the pure compute, and the memoized face strip is what compute_strips
// copies into the b channel (exactly _side_blk_strip's sf.duplicate()).
//
// WORKER SAFETY: no Data/Game autoloads — the slab arrays, last_eff rows,
// face strips and att/glow arrive as value copies. _strips_for runs on the
// MAIN thread (world.gd:2448) — the C++ call is synchronous and the slab
// reads are read-only.
//
// Toggle: AWECRAFT_STRIPSCPP=0 forces the GDScript path (the world.gd
// fallbacks stay intact); AWECRAFT_STRIPSCPP=1 or unset = C++ whenever this
// library registered AweStrips.

#include <gdextension_interface.h>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <vector>

#include "awe_common.h"

using namespace godot;

namespace awestrips {

using awecommon::S3;
using awecommon::pba_from;
using awecommon::slab_unpack;
using awecommon::slab_views;

constexpr int SKY_FULL = 15;

// The block tables (value copies of the pre-warmed Lighting._att/_glow,
// size 48). b >= size = 0 (GDScript would index-error there; valid data
// never does — same convention as lighting.cpp).
struct Tables {
	const uint8_t *att = nullptr;
	const uint8_t *glow = nullptr;
	int att_sz = 0;
	int glow_sz = 0;
	inline int a(int b) const {
		return (b >= 0 && b < att_sz) ? att[b] : 0;
	}
	inline int g(int b) const {
		return (b >= 0 && b < glow_sz) ? glow[b] : 0;
	}
};

static Tables tables_from(const PackedByteArray &p_att, const PackedByteArray &p_glow) {
	Tables t;
	if (p_att.size() > 0) {
		t.att = p_att.ptr();
		t.att_sz = (int)p_att.size();
	}
	if (p_glow.size() > 0) {
		t.glow = p_glow.ptr();
		t.glow_sz = (int)p_glow.size();
	}
	return t;
}

// ---------------------------------------------------------------------------
// GDScript packed-array indexing semantics (the shipped strips rely on
// them — verified empirically on 4.7.1): a NEGATIVE idx wraps from the end
// (a[-k] = a[size-k]); idx >= size is a FATAL runtime error (cannot occur
// on valid data — max idx = h*256-1). The E/N c=1 halves compute idx = -1
// (E: (y<<8)|(t<<4)|-1, all bits set) or idx = t-16 (N: (y<<8)|((-1)<<4)|t),
// so the far margin column wraps onto the neighbor's TOP row — a shipped
// quirk of the original, replicated verbatim (LOSSLESS).
// ---------------------------------------------------------------------------

static inline int narr_idx(int idx, int sz) {
	if (idx < 0)
		idx += sz;
	return (idx >= 0 && idx < sz) ? idx : 0;
}

// ---------------------------------------------------------------------------
// _side_eff_strip port (world.gd:2484). c=0 the column directly across our
// boundary, c=1 the next; t = our z (E/W) or our x (S/N). 2*16*h bytes,
// idx = c*(16*h) + y*16 + t.
// ---------------------------------------------------------------------------

static PackedByteArray side_eff_strip(const PackedByteArray &narr, int dx, int dz, int h) {
	const int colsz = 16 * h;
	std::vector<uint8_t> e((size_t)2 * 16 * h, 0);
	const int nx0 = dx > 0 ? 0 : 15;
	const int nz0 = dz > 0 ? 0 : 15;
	const int nsz = (int)narr.size();
	const bool nvalid = nsz == h * 256;
	const uint8_t *na = nvalid ? narr.ptr() : nullptr;
	for (int c = 0; c < 2; c++) {
		for (int y = 0; y < h; y++) {
			const int srow = y * 16;
			for (int t = 0; t < 16; t++) {
				int idx;
				if (dx != 0)
					idx = (y << 8) | (t << 4) | (nx0 - c);
				else
					idx = (y << 8) | ((nz0 - c) * 16) | t; // -1*16 = -16 (two's complement)
				e[c * colsz + srow + t] = (na != nullptr) ? na[narr_idx(idx, nsz)] : 0;
			}
		}
	}
	return pba_from(e);
}

// ---------------------------------------------------------------------------
// _corner_eff_strip port (world.gd:2860). a = x-depth (0 = directly across),
// b = z-depth; 2x2*h bytes, idx = (a*2+b)*h + y.
// ---------------------------------------------------------------------------

static PackedByteArray corner_eff_strip(const PackedByteArray &narr, int dx, int dz, int h) {
	std::vector<uint8_t> e((size_t)4 * h, 0);
	const int nx0 = dx > 0 ? 0 : 15;
	const int nz0 = dz > 0 ? 0 : 15;
	const int nsz = (int)narr.size();
	const bool nvalid = nsz == h * 256;
	const uint8_t *na = nvalid ? narr.ptr() : nullptr;
	for (int a = 0; a < 2; a++) {
		for (int b = 0; b < 2; b++) {
			const int nx = nx0 - a; // E/N a|b == 1 -> negative (the wrap quirk)
			const int nz = nz0 - b;
			for (int y = 0; y < h; y++) {
				const int idx = (y << 8) | (nz << 4) | nx;
				e[(a * 2 + b) * h + y] = (na != nullptr) ? na[narr_idx(idx, nsz)] : 0;
			}
		}
	}
	return pba_from(e);
}

// ---------------------------------------------------------------------------
// The v-channel slab descriptors: the has_solid probe reads the PALETTE
// only (a paletted slab's cell set IS its palette; a raw slab scans its
// 4096 values — rare), the cell values come from the C++ decode
// (slab_unpack — the verified AC-0189/AC-0190 lanes, identical to
// ChunkIO._slab_getbits per cell).
// ---------------------------------------------------------------------------

struct SlabDesc {
	int n = -1; // -1 null slab, 0 raw, 1 uniform, 2..16 paletted
	const uint8_t *p = nullptr;
	int psz = 0;
	bool has_solid = false;
	std::vector<uint8_t> view; // n==0 or 2..16: the full 4096-cell decode
};

static void slab_descs(const Array &p_data, const Tables &t, std::vector<SlabDesc> &out) {
	out.assign(p_data.size(), SlabDesc());
	for (int si = 0; si < (int)out.size(); si++) {
		Variant v = p_data[si];
		if (v.get_type() != Variant::DICTIONARY)
			continue;
		Dictionary d = v;
		int n = d.get("n", 0);
		SlabDesc &sd = out[si];
		sd.n = n;
		PackedByteArray p = d.get("p", PackedByteArray());
		sd.p = p.ptr();
		sd.psz = (int)p.size();
		if (n == 0) {
			PackedByteArray i = d.get("i", PackedByteArray());
			if (i.size() >= S3) {
				sd.view.assign(i.ptr(), i.ptr() + S3);
				for (int k = 0; k < S3; k++)
					if (t.a(sd.view[k]) == 0) {
						sd.has_solid = true;
						break;
					}
			} else {
				sd.view.assign(S3, 0);
				if (i.size() > 0)
					std::memcpy(sd.view.data(), i.ptr(), i.size());
			}
		} else if (n == 1) {
			if (sd.psz > 0 && t.a(sd.p[0]) == 0)
				sd.has_solid = true;
		} else {
			PackedByteArray i = d.get("i", PackedByteArray());
			int b = d.get("b", 0);
			sd.view = slab_unpack(i.ptr(), (int)i.size(), b, sd.p);
			for (int k = 0; k < sd.psz; k++)
				if (t.a(sd.p[k]) == 0) {
					sd.has_solid = true;
					break;
				}
		}
	}
}

// ---------------------------------------------------------------------------
// _side_blk_strip v channel port (world.gd:2727-2849). b = 2*16*h, idx =
// c*(16*h) + y*16 + t; only c=0 is written (the inject half), c=1 stays
// zero. sky_n = 15 iff y > solid_top; eff_n = the neighbor's settled last_eff
// (nvalid only); the cell's own glow wins over both (source EXACT).
// ---------------------------------------------------------------------------

static std::vector<uint8_t> side_blk_v_impl(const Array &p_data, const uint8_t *narr, int narr_sz, int dx, int dz, int h, const Tables &t) {
	std::vector<uint8_t> b((size_t)2 * 16 * h, 0);
	const bool nvalid = (narr_sz == h * 256);
	const uint8_t *na = nvalid ? narr : nullptr;
	std::vector<SlabDesc> descs;
	slab_descs(p_data, t, descs);
	const int nsl = (int)descs.size();
	const int nx0 = dx > 0 ? 0 : 15;
	const int nz0 = dz > 0 ? 0 : 15;
	for (int tt = 0; tt < 16; tt++) {
		const int nx = (dx != 0) ? nx0 : tt;
		const int nz = (dx != 0) ? tt : nz0;
		// solid_top (world.gd:2748-2786): the topmost att==0 cell in the
		// column; a slab whose palette holds no solid id cannot close it,
		// so the top-down walk skips palette-solid-free slabs and descends
		// cell-by-cell into the first slab that can.
		int solid_top = -1;
		for (int si = nsl - 1; si >= 0 && solid_top < 0; si--) {
			const SlabDesc &sd = descs[si];
			if (sd.n < 0 || !sd.has_solid)
				continue;
			const int slb0 = si * 16;
			for (int k2 = 15; k2 >= 0; k2--) {
				int blv;
				if (sd.n == 1)
					blv = (sd.psz > 0) ? sd.p[0] : 0;
				else
					blv = sd.view[(k2 << 8) | (nz << 4) | nx];
				if (t.a(blv) == 0) {
					solid_top = slb0 + k2;
					break;
				}
			}
		}
		// The bottom-up per-slab cell walk (world.gd:2787-2850).
		for (int si = 0; si < nsl; si++) {
			const SlabDesc &sd = descs[si];
			const int slb = si * 16;
			if (sd.n < 0) {
				for (int ly = 15; ly >= 0; ly--) {
					const int y = slb + ly;
					if (y >= h)
						continue;
					const int sky_n = (y > solid_top) ? SKY_FULL : 0;
					const int eff_n = (na != nullptr) ? na[(y << 8) | (nz << 4) | nx] : 0;
					b[(size_t)y * 16 + tt] = (eff_n > sky_n) ? (uint8_t)eff_n : (uint8_t)sky_n;
				}
			} else if (sd.n == 1) {
				const int blc = (sd.psz > 0) ? sd.p[0] : 0;
				const int lvc = t.g(blc);
				for (int ly = 15; ly >= 0; ly--) {
					const int y = slb + ly;
					if (y >= h)
						continue;
					const int sky_n = (y > solid_top) ? SKY_FULL : 0;
					const int eff_n = (na != nullptr) ? na[(y << 8) | (nz << 4) | nx] : 0;
					if (lvc > 0)
						b[(size_t)y * 16 + tt] = (uint8_t)lvc;
					else if (eff_n > sky_n)
						b[(size_t)y * 16 + tt] = (uint8_t)eff_n;
					else
						b[(size_t)y * 16 + tt] = (uint8_t)sky_n;
				}
			} else {
				for (int ly = 15; ly >= 0; ly--) {
					const int y = slb + ly;
					if (y >= h)
						continue;
					const int bl = sd.view[(ly << 8) | (nz << 4) | nx];
					const int sky_n = (y > solid_top) ? SKY_FULL : 0;
					const int eff_n = (na != nullptr) ? na[(y << 8) | (nz << 4) | nx] : 0;
					const int lv = t.g(bl);
					if (lv > 0)
						b[(size_t)y * 16 + tt] = (uint8_t)lv;
					else if (eff_n > sky_n)
						b[(size_t)y * 16 + tt] = (uint8_t)eff_n;
					else
						b[(size_t)y * 16 + tt] = (uint8_t)sky_n;
				}
			}
		}
	}
	return b;
}

// ---------------------------------------------------------------------------
// _chunk_has_glow port (world.gd:2602): a paletted slab is glow-free iff
// its palette is glow-free — no 4096 expansion needed to decide; a raw
// slab scans its 4096 values (rare).
// ---------------------------------------------------------------------------

static bool chunk_has_glow(const Array &p_data, const Tables &t) {
	for (int si = 0; si < (int)p_data.size(); si++) {
		Variant v = p_data[si];
		if (v.get_type() != Variant::DICTIONARY)
			continue;
		Dictionary d = v;
		int n = d.get("n", 0);
		if (n == 0) {
			PackedByteArray i = d.get("i", PackedByteArray());
			for (int k = 0; k < (int)i.size() && k < S3; k++)
				if (t.g(i[k]) > 0)
					return true;
		} else {
			PackedByteArray p = d.get("p", PackedByteArray());
			for (int k = 0; k < (int)p.size(); k++)
				if (t.g(p[k]) > 0)
					return true;
		}
	}
	return false;
}

// ---------------------------------------------------------------------------
// _compute_face_blk port (world.gd:2623). p_nf0..p_nf3 = the neighbor
// [E,W,S,N] face strips (empty = missing/in-flight) — the memoized _face_of
// results the GDScript wrapper fetches (under the in-flight cycle guard)
// and passes. Pure compute: no memo state, no Data/Game.
// ---------------------------------------------------------------------------

static Dictionary compute_face_impl(const Array &p_data, int h, const Tables &t, const PackedByteArray &p_nf0, const PackedByteArray &p_nf1, const PackedByteArray &p_nf2, const PackedByteArray &p_nf3) {
	const int sz = 16 * 16;
	const bool glow = chunk_has_glow(p_data, t);
	std::vector<uint8_t> ids((size_t)sz * h, 0);
	std::vector<uint8_t> blk((size_t)sz * h, 0);
	awelight::FloodTables ft;
	ft.att = t.att;
	ft.att_sz = t.att_sz;
	ft.glow = t.glow;
	ft.glow_sz = t.glow_sz;
	if (glow) {
		// The flat expansion (world.gd:2654 — c.flat_data()): full column,
		// null slab = 4096 zeros (position preserved), paletted = the C++
		// decode (free int lookup vs the GDScript _slabs_flat Variant pass).
		std::vector<std::vector<uint8_t>> dviews;
		slab_views(p_data, dviews);
		for (int si = 0; si < (int)dviews.size() && si < h / 16; si++) {
			const std::vector<uint8_t> &dv = dviews[si];
			if (dv.empty())
				continue;
			int c = (int)dv.size() < S3 ? (int)dv.size() : S3;
			std::memcpy(ids.data() + (size_t)si * S3, dv.data(), (size_t)c);
		}
		for (int i = 0; i < sz * h; i++) {
			int g = t.g(ids[i]);
			if (g > 0)
				blk[i] = (uint8_t)g;
		}
		awelight::flood_flat(blk.data(), ids.data(), 16, h, 16, -1, ft);
	}
	Array strips;
	strips.push_back(p_nf0);
	strips.push_back(p_nf1);
	strips.push_back(p_nf2);
	strips.push_back(p_nf3);
	bool inj = awelight::blk_inject(blk.data(), ids.data(), h, strips, -1, ft);
	if (inj) {
		if (!glow) {
			// The probe ran on the zero column (min attenuation _att[0] = 1)
			// — the boundary values it wrote are over-attenuation-free; redo
			// the inject on the REAL column so the boundary cells carry the
			// exact cand = strip - att[real_id] values (world.gd:2669-2676).
			std::vector<std::vector<uint8_t>> dviews;
			slab_views(p_data, dviews);
			std::fill(ids.begin(), ids.end(), 0);
			for (int si = 0; si < (int)dviews.size() && si < h / 16; si++) {
				const std::vector<uint8_t> &dv = dviews[si];
				if (dv.empty())
					continue;
				int c = (int)dv.size() < S3 ? (int)dv.size() : S3;
				std::memcpy(ids.data() + (size_t)si * S3, dv.data(), (size_t)c);
			}
			std::fill(blk.begin(), blk.end(), 0);
			awelight::blk_inject(blk.data(), ids.data(), h, strips, -1, ft);
		}
		awelight::flood_flat(blk.data(), ids.data(), 16, h, 16, -1, ft);
	}
	// The [E,W,S,N] face extract (world.gd:2678-2695): 2*16*h faces, the
	// c=0 half = the face row (the only half _chunk_blk_inject reads), the
	// c=1 half zero.
	std::vector<uint8_t> fe((size_t)2 * 16 * h, 0);
	std::vector<uint8_t> fw((size_t)2 * 16 * h, 0);
	std::vector<uint8_t> fs((size_t)2 * 16 * h, 0);
	std::vector<uint8_t> fn((size_t)2 * 16 * h, 0);
	for (int y = 0; y < h; y++) {
		const int rowb = y * 16;
		const int row = y << 8;
		for (int t = 0; t < 16; t++) {
			fe[rowb + t] = blk[row | (t << 4) | 15];
			fw[rowb + t] = blk[row | (t << 4)];
			fs[rowb + t] = blk[row | (15 << 4) | t];
			fn[rowb + t] = blk[row | t];
		}
	}
	Dictionary d;
	d["glow"] = glow;
	Array faces;
	faces.push_back(pba_from(fe));
	faces.push_back(pba_from(fw));
	faces.push_back(pba_from(fs));
	faces.push_back(pba_from(fn));
	d["faces"] = faces;
	return d;
}

// ---------------------------------------------------------------------------
// Registered class.
// ---------------------------------------------------------------------------

class AweStrips : public RefCounted {
	GDCLASS(AweStrips, RefCounted)

public:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("compute_strips", "sides", "corners", "h", "att", "glow"), &AweStrips::compute_strips);
		ClassDB::bind_method(D_METHOD("side_blk_v", "data", "eff", "dx", "dz", "h", "att", "glow"), &AweStrips::side_blk_v);
		ClassDB::bind_method(D_METHOD("compute_face", "data", "h", "att", "glow", "nf0", "nf1", "nf2", "nf3"), &AweStrips::compute_face);
	}

	// _strips_for port (world.gd:2455): sides = 4 dicts {data: slab array,
	// eff: last_eff["arr"], face: the memoized _face_of(nc, _shared_face)
	// strip, have: bool} in [E,W,N,S] order; corners = 4 dicts {eff, have}
	// in [NE,NW,SE,SW] order. The neighbor lookups + the face memo stay in
	// GDScript (World owns the chunks map + the _face_blk cache); returns
	// {eff, blk, blk_b} exactly as the GDScript path (a missing neighbor
	// contributes 0-length strips everywhere).
	Dictionary compute_strips(const Array &p_sides, const Array &p_corners, int p_h, const PackedByteArray &p_att, const PackedByteArray &p_glow) {
		static const int SD[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
		static const int CD[4][2] = {{1, 1}, {-1, 1}, {1, -1}, {-1, -1}};
		Tables t = tables_from(p_att, p_glow);
		Array effs;
		Array blks;
		Array blks_b;
		for (int si = 0; si < 4; si++) {
			Dictionary sd = p_sides[si];
			bool have = sd.get("have", false);
			if (!have) {
				effs.push_back(PackedByteArray());
				blks.push_back(PackedByteArray());
				blks_b.push_back(PackedByteArray());
				continue;
			}
			Array data = sd.get("data", Array());
			PackedByteArray narr = sd.get("eff", PackedByteArray());
			PackedByteArray face = sd.get("face", PackedByteArray());
			effs.push_back(side_eff_strip(narr, SD[si][0], SD[si][1], p_h));
			std::vector<uint8_t> v = side_blk_v_impl(data, narr.ptr(), (int)narr.size(), SD[si][0], SD[si][1], p_h, t);
			blks.push_back(pba_from(v));
			if ((int)face.size() == 2 * 16 * p_h)
				blks_b.push_back(face.duplicate()); // the GDScript's sf.duplicate()
			else {
				std::vector<uint8_t> z((size_t)2 * 16 * p_h, 0);
				blks_b.push_back(pba_from(z));
			}
		}
		for (int ci = 0; ci < 4; ci++) {
			Dictionary cd = p_corners[ci];
			bool have = cd.get("have", false);
			if (!have) {
				effs.push_back(PackedByteArray());
				continue;
			}
			PackedByteArray narr = cd.get("eff", PackedByteArray());
			effs.push_back(corner_eff_strip(narr, CD[ci][0], CD[ci][1], p_h));
		}
		Dictionary d;
		d["eff"] = effs;
		d["blk"] = blks;
		d["blk_b"] = blks_b;
		return d;
	}

	// _side_blk_strip v channel (world.gd:2727-2849) — the 18.5 ms Variant
	// path this replaces (the stripsprobe arm times it per side).
	PackedByteArray side_blk_v(const Array &p_data, const PackedByteArray &p_eff, int p_dx, int p_dz, int p_h, const PackedByteArray &p_att, const PackedByteArray &p_glow) {
		Tables t = tables_from(p_att, p_glow);
		std::vector<uint8_t> v = side_blk_v_impl(p_data, p_eff.ptr(), (int)p_eff.size(), p_dx, p_dz, p_h, t);
		return pba_from(v);
	}

	// _compute_face_blk port (world.gd:2623): the [E,W,S,N] settled block-
	// light faces — the glow palette probe + flat expand + glow seed +
	// bucket-16 flood + UN-gated boundary injection through the SAME C++
	// kernels the pull path runs (lighting.cpp), the no-glow zero-column
	// probe + real-column re-inject, the face extract. Returns {glow, faces
	// [E,W,S,N]}. nf0..nf3 = the neighbor [E,W,S,N] face strips (empty =
	// missing).
	Dictionary compute_face(const Array &p_data, int p_h, const PackedByteArray &p_att, const PackedByteArray &p_glow, const PackedByteArray &p_nf0, const PackedByteArray &p_nf1, const PackedByteArray &p_nf2, const PackedByteArray &p_nf3) {
		Tables t = tables_from(p_att, p_glow);
		return compute_face_impl(p_data, p_h, t, p_nf0, p_nf1, p_nf2, p_nf3);
	}
};

void register_classes() {
	GDREGISTER_CLASS(AweStrips);
}

} // namespace awestrips
