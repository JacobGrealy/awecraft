// AC-0189: GDExtension native port of the single-chunk PULL lighting kernel
// (godot/world/lighting.gd) — the build_accs hot path, on the AC-0165/AC-0188
// pipeline (same .so/.dll, same chunkio_library_init entry symbol).
//
// LOSSLESS INARIANT: AweLighting.compute_chunk_pull produces the SAME light
// values as Lighting.compute_light_flat_chunk_pull for the SAME input —
// eff (sky|blk per cell), mask (blk-flood visited), ring (sparse boundary
// block light), blk_src. Verified by AWECRAFT_LOGIC=lightprobe (C++ vs
// GDScript at every cell of N built chunks; gate: 100% exact).
//
// Ported verbatim (integer-only kernel — no float, so no FP concerns, but
// the -ffp-contract=off build flag is inherited):
//   * compute_light_flat_chunk_pull (lighting.gd:320) — the AC-0197
//     top-truncated column scan (per-slab flat views, open carried across
//     slabs) + eff = max(sky, blk) + rows above top filled 15;
//   * _flood_flat (lighting.gd:519) — the bucket-16 BFS flood (patt = att
//     per cell; seeds lv>1 with any lower neighbor; relax nl = lv - att[n],
//     buckets walked 15..2, hact = active rows, rows beyond hact never
//     seeded nor stepped into);
//   * _chunk_blk_inject (lighting.gd:454) — the UN-gated boundary
//     injection, sides [E,W,N,S], cand = strip[y*16+t] - att[own boundary
//     cell], raise when cand > eff;
//   * the mask + ring re-derivation (AC-0128 RUN 3 / AC-0091 19-bit pack).
//
// WORKER SAFETY: no Data/Game autoloads. The block tables arrive as value
// copies (att/glow PackedByteArrays = the pre-warmed Lighting._att/_glow,
// warmed on the main thread before any worker starts — world.gd:455), and
// the inputs are the chunk's slab array + the neighbor strips (main-thread
// copies that ride the build entry). Slab views are materialized per call
// (same decode as ChunkIOPalette.slab_flat / ChunkIO._slab_flat).
//
// FLOOD TIMING: every _flood_flat call is timed (usec) into a capped
// histogram; flood_stats()/reset_flood_stats() expose n/total/p50/p95/max
// (the lightprobe arm reports the GDScript vs C++ p95 — the speedup gate).
//
// Toggle: AWECRAFT_LIGHTCPP=0 forces the GDScript path (chunk.gd build_accs);
// unset/1 = C++ whenever this library registered AweLighting.

#include <gdextension_interface.h>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>

#include "awe_common.h"

using namespace godot;

namespace awelight {

// AC-0190: the slab view decode moved to awe_common.cpp (shared with the
// mesh module) — identical verified code, same namespace-qualified names.
using awecommon::S3;
using awecommon::pba_from;
using awecommon::slab_views;

constexpr int SKY_FULL = 15;

// ---------------------------------------------------------------------------
// The block tables (value copies of the pre-warmed Lighting._att/_glow).
// b >= size = 0 (GDScript would index-error there; valid data never does).
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// _flood_flat port (lighting.gd:519) — the bucket-16 BFS. Integer-only,
// verbatim neighbor order (x+1, x-1, y+1, y-1, z+1, z-1), verbatim seed
// test (lv>1 and any patt>0 neighbor with src<lv) and relaxation
// (nl = lv - patt[n]; raise when nl>0 and nl > src[n]).
// ---------------------------------------------------------------------------

static void flood(uint8_t *src, const uint8_t *ids, int w, int h, int d, int hact, const Tables &t) {
	const int sz = w * d;
	const int rows = (hact < 0) ? h : std::min(hact, h);
	const int size = sz * rows;
	std::vector<uint8_t> patt((size_t)size);
	for (int i = 0; i < size; i++)
		patt[i] = (uint8_t)t.a(ids[i]);
	std::array<std::vector<uint32_t>, 16> buckets;
	for (int i = 0; i < size; i++) {
		int lv = src[i];
		if (lv <= 1)
			continue;
		int yy = i / sz;
		int rem = i - yy * sz;
		int zz = rem / w;
		int xx = rem - zz * w;
		bool spr = false;
		if (xx + 1 < w) {
			int n = i + 1;
			if (patt[n] > 0 && src[n] < lv)
				spr = true;
		}
		if (!spr && xx > 0) {
			int n = i - 1;
			if (patt[n] > 0 && src[n] < lv)
				spr = true;
		}
		if (!spr && yy + 1 < rows) {
			int n = i + sz;
			if (patt[n] > 0 && src[n] < lv)
				spr = true;
		}
		if (!spr && yy > 0) {
			int n = i - sz;
			if (patt[n] > 0 && src[n] < lv)
				spr = true;
		}
		if (!spr && zz + 1 < d) {
			int n = i + w;
			if (patt[n] > 0 && src[n] < lv)
				spr = true;
		}
		if (!spr && zz > 0) {
			int n = i - w;
			if (patt[n] > 0 && src[n] < lv)
				spr = true;
		}
		if (spr)
			buckets[lv].push_back((uint32_t)i);
	}
	for (int lv = SKY_FULL; lv > 1; lv--) {
		std::vector<uint32_t> &q = buckets[lv];
		size_t qi = 0;
		while (qi < q.size()) {
			int i = (int)q[qi++];
			int yy = i / sz;
			int rem = i - yy * sz;
			int zz = rem / w;
			int xx = rem - zz * w;
			if (xx + 1 < w) {
				int n = i + 1;
				int at = patt[n];
				if (at > 0) {
					int nl = lv - at;
					if (nl > 0 && nl > src[n]) {
						src[n] = (uint8_t)nl;
						buckets[nl].push_back((uint32_t)n);
					}
				}
			}
			if (xx > 0) {
				int n = i - 1;
				int at = patt[n];
				if (at > 0) {
					int nl = lv - at;
					if (nl > 0 && nl > src[n]) {
						src[n] = (uint8_t)nl;
						buckets[nl].push_back((uint32_t)n);
					}
				}
			}
			if (yy + 1 < rows) {
				int n = i + sz;
				int at = patt[n];
				if (at > 0) {
					int nl = lv - at;
					if (nl > 0 && nl > src[n]) {
						src[n] = (uint8_t)nl;
						buckets[nl].push_back((uint32_t)n);
					}
				}
			}
			if (yy > 0) {
				int n = i - sz;
				int at = patt[n];
				if (at > 0) {
					int nl = lv - at;
					if (nl > 0 && nl > src[n]) {
						src[n] = (uint8_t)nl;
						buckets[nl].push_back((uint32_t)n);
					}
				}
			}
			if (zz + 1 < d) {
				int n = i + w;
				int at = patt[n];
				if (at > 0) {
					int nl = lv - at;
					if (nl > 0 && nl > src[n]) {
						src[n] = (uint8_t)nl;
						buckets[nl].push_back((uint32_t)n);
					}
				}
			}
			if (zz > 0) {
				int n = i - w;
				int at = patt[n];
				if (at > 0) {
					int nl = lv - at;
					if (nl > 0 && nl > src[n]) {
						src[n] = (uint8_t)nl;
						buckets[nl].push_back((uint32_t)n);
					}
				}
			}
		}
	}
}

// ---------------------------------------------------------------------------
// _chunk_blk_inject port (lighting.gd:454) — UN-gated boundary injection.
// sides [E,W,N,S]; side strip = 2 cols x 16 x h, idx = y*16 + t (t = our z
// for E/W, our x for S/N); own boundary cell B per side; cand = strip - att.
// ---------------------------------------------------------------------------

static bool inject(uint8_t *eff, const uint8_t *ids, int h, const Array &strips, int hgate, const Tables &t) {
	if ((int)strips.size() < 4)
		return false;
	bool changed = false;
	int hrow = (hgate < 0) ? h : hgate;
	for (int si = 0; si < 4; si++) {
		PackedByteArray strip = strips[si]; // null -> empty (skipped below)
		if ((int)strip.size() != 2 * 16 * h)
			continue;
		for (int y = 0; y < hrow; y++) {
			int row = y * 256;
			int srow = y * 16;
			for (int t2 = 0; t2 < 16; t2++) {
				int B;
				if (si == 0)
					B = row + t2 * 16 + 15; // E (x=15)
				else if (si == 1)
					B = row + t2 * 16; // W (x=0)
				else if (si == 2)
					B = row + 15 * 16 + t2; // N (z=15)
				else
					B = row + t2; // S (z=0)
				int at = t.a(ids[B]);
				if (at > 0) {
					int cand = (int)strip[srow + t2] - at;
					if (cand > eff[B]) {
						eff[B] = (uint8_t)cand;
						changed = true;
					}
				}
			}
		}
	}
	return changed;
}

// ---------------------------------------------------------------------------
// compute_light_flat_chunk_pull port (lighting.gd:320).
// ---------------------------------------------------------------------------

struct PullResult {
	std::vector<uint8_t> eff; // sz*h
	std::vector<uint8_t> mask; // sz*h
	std::vector<int32_t> ring;
	bool blk_src = false;
};

// Each flood call is timed (us) into r_flood (the class records it).
static inline uint64_t now_usec() {
	return Time::get_singleton()->get_ticks_usec();
}

static void timed_flood(uint8_t *src, const uint8_t *ids, int w, int h, int d, int hact, const Tables &t, std::vector<uint32_t> &r_flood) {
	uint64_t t0 = now_usec();
	flood(src, ids, w, h, d, hact, t);
	r_flood.push_back((uint32_t)(now_usec() - t0));
}

static PullResult compute_pull(const Array &p_data, int h, const Array &p_blk_strips, const Array &p_blk_strips_b, int top, const Tables &t, std::vector<uint32_t> &r_flood) {
	const int sz = 16 * 16;
	int hact = (top >= 0) ? top + 1 : h;
	int hblk = (top >= 0) ? std::min(h, top + 15) : h;
	if (hact > h)
		hact = h;
	if (hact < 0)
		hact = 0;

	std::vector<std::vector<uint8_t>> dviews;
	slab_views(p_data, dviews);

	std::vector<uint8_t> ids((size_t)sz * h, 0);
	std::vector<uint8_t> sky((size_t)sz * h, 0);
	std::vector<uint8_t> blk((size_t)sz * h, 0);
	bool has_glow = false;
	int s_top = std::max(0, (hact - 1) >> 4);
	static const std::vector<uint8_t> EMPTY_VIEW; // null slab = empty view
	for (int ix = 0; ix < 16; ix++) {
		for (int iz = 0; iz < 16; iz++) {
			int i0 = ix + iz * 16;
			bool open = true;
			for (int si = s_top; si >= 0; si--) {
				int lo = si * 16;
				int c_hi = std::min(16, hact - lo);
				if (c_hi <= 0)
					continue;
				const std::vector<uint8_t> *dv = (si < (int)dviews.size()) ? &dviews[si] : &EMPTY_VIEW;
				bool hasv = !dv->empty();
				for (int cy = c_hi - 1; cy >= 0; cy--) {
					int y = lo + cy;
					int b = 0;
					if (hasv)
						b = (int)(*dv)[(cy << 8) | (iz << 4) | ix];
					int i = y * sz + i0;
					ids[i] = (uint8_t)b;
					int at = t.a(b);
					if (open && at > 0)
						sky[i] = SKY_FULL;
					int lv = t.g(b);
					if (lv > 0) {
						blk[i] = (uint8_t)lv;
						has_glow = true;
					}
					if (open && at == 0)
						open = false;
				}
			}
		}
	}

	std::vector<uint8_t> eff((size_t)sz * h, 0);
	for (int y = hact; y < h; y++)
		for (int x = 0; x < sz; x++)
			eff[(size_t)y * sz + x] = SKY_FULL;
	for (int i = 0; i < sz * hact; i++) {
		int s = sky[i];
		int b2 = blk[i];
		eff[i] = (uint8_t)((s >= b2) ? s : b2);
	}
	timed_flood(eff.data(), ids.data(), 16, h, 16, hact, t, r_flood);
	if (inject(eff.data(), ids.data(), h, p_blk_strips, hact, t))
		timed_flood(eff.data(), ids.data(), 16, h, 16, hact, t, r_flood);
	// The block-light VISITED companion (AC-0128 RUN 3): own glow flood
	// (truncated to top+15) + the BLOCK-ONLY strip injection (full height —
	// a tall neighbor's torch may carry block light above our top).
	if (has_glow)
		timed_flood(blk.data(), ids.data(), 16, h, 16, hblk, t, r_flood);
	bool blk_inj = inject(blk.data(), ids.data(), h, p_blk_strips_b, -1, t);
	if (blk_inj)
		timed_flood(blk.data(), ids.data(), 16, h, 16, -1, t, r_flood);

	PullResult r;
	r.eff = std::move(eff);
	r.mask.assign((size_t)sz * h, 0);
	r.blk_src = has_glow;
	if (has_glow || blk_inj) {
		for (int i = 0; i < sz * h; i++)
			r.mask[i] = (blk[i] > 0) ? 1 : 0;
		// AC-0091 19-bit pack: (side << 17) | (yy << 4) | level — side 2 bits
		// (0=E x=15, 1=W x=0, 2=N z=15, 3=S z=0), yy 13 bits (y*16+t),
		// level 4 bits.
		for (int y = 0; y < h; y++) {
			int row = y << 8;
			for (int t2 = 0; t2 < 16; t2++) {
				int yy = y * 16 + t2;
				int lv0 = blk[row | (t2 << 4) | 15];
				if (lv0 > 0)
					r.ring.push_back((0 << 17) | (yy << 4) | lv0);
				int lv1 = blk[row | (t2 << 4)];
				if (lv1 > 0)
					r.ring.push_back((1 << 17) | (yy << 4) | lv1);
				int lv2 = blk[row | (15 << 4) | t2];
				if (lv2 > 0)
					r.ring.push_back((2 << 17) | (yy << 4) | lv2);
				int lv3 = blk[row | t2];
				if (lv3 > 0)
					r.ring.push_back((3 << 17) | (yy << 4) | lv3);
			}
		}
	}
	return r;
}

// ---------------------------------------------------------------------------
// AC-0190: cross-module bridge (declared in awe_common.h) — the mesh module
// (src/mesh.cpp) recomputes light through THIS SAME kernel, so the C++
// mesh's light is byte-identical to the AweLighting class path.
// ---------------------------------------------------------------------------

PullOut pull(const Array &p_data, int p_h, const Array &p_blk_strips, const Array &p_blk_strips_b, int p_top, const uint8_t *p_att, int p_att_sz, const uint8_t *p_glow, int p_glow_sz, std::vector<uint32_t> *p_r_flood) {
	Tables t;
	if (p_att != nullptr) {
		t.att = p_att;
		t.att_sz = p_att_sz;
	}
	if (p_glow != nullptr) {
		t.glow = p_glow;
		t.glow_sz = p_glow_sz;
	}
	std::vector<uint32_t> floods;
	PullResult r = compute_pull(p_data, p_h, p_blk_strips, p_blk_strips_b, p_top, t, floods);
	if (p_r_flood != nullptr)
		p_r_flood->insert(p_r_flood->end(), floods.begin(), floods.end());
	PullOut out;
	out.eff = std::move(r.eff);
	out.mask = std::move(r.mask);
	out.ring = std::move(r.ring);
	out.blk_src = r.blk_src;
	return out;
}

// ---------------------------------------------------------------------------
// AC-0207: cross-module bridge for the strips face compute (src/strips.cpp)
// — the SAME flood/inject kernels the pull path runs (byte-identical by
// construction; the C++ face's block light equals the GDScript
// Lighting._flood_flat / _chunk_blk_inject path).
// ---------------------------------------------------------------------------

static Tables tables_from_flood(const FloodTables &p_ft) {
	Tables t;
	t.att = p_ft.att;
	t.att_sz = p_ft.att_sz;
	t.glow = p_ft.glow;
	t.glow_sz = p_ft.glow_sz;
	return t;
}

void flood_flat(uint8_t *p_src, const uint8_t *p_ids, int p_w, int p_h, int p_d, int p_hact, const FloodTables &p_ft) {
	flood(p_src, p_ids, p_w, p_h, p_d, p_hact, tables_from_flood(p_ft));
}

bool blk_inject(uint8_t *p_eff, const uint8_t *p_ids, int p_h, const Array &p_blk_strips, int p_hgate, const FloodTables &p_ft) {
	return inject(p_eff, p_ids, p_h, p_blk_strips, p_hgate, tables_from_flood(p_ft));
}

// ---------------------------------------------------------------------------
// Registered class.
// ---------------------------------------------------------------------------

class AweLighting : public RefCounted {
	GDCLASS(AweLighting, RefCounted)

public:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("compute_chunk_pull", "data", "cx", "cz", "h", "eff_strips", "blk_strips", "blk_strips_b", "top", "att", "glow"), &AweLighting::compute_chunk_pull);
		ClassDB::bind_method(D_METHOD("flood_stats"), &AweLighting::flood_stats);
		ClassDB::bind_method(D_METHOD("reset_flood_stats"), &AweLighting::reset_flood_stats);
	}

	// The pull kernel. data = the 24-slab array (null | {n,b,p,i,nz});
	// eff_strips rides along for the caller's bake box (unused by the
	// kernel, kept for signature parity with the GDScript entry);
	// blk_strips / blk_strips_b = the 4 side strips [E,W,N,S]; att/glow =
	// value copies of the pre-warmed Lighting._att/_glow (size 48).
	Dictionary compute_chunk_pull(const Array &p_data, int p_cx, int p_cz, int p_h, const Array &p_eff_strips, const Array &p_blk_strips, const Array &p_blk_strips_b, int p_top, const PackedByteArray &p_att, const PackedByteArray &p_glow) {
		Tables t;
		if (p_att.size() > 0) {
			t.att = p_att.ptr();
			t.att_sz = (int)p_att.size();
		}
		if (p_glow.size() > 0) {
			t.glow = p_glow.ptr();
			t.glow_sz = (int)p_glow.size();
		}
		std::vector<uint32_t> r_flood;
		PullResult r = compute_pull(p_data, p_h, p_blk_strips, p_blk_strips_b, p_top, t, r_flood);
		record_flood(r_flood);

		Dictionary d;
		d["mn"] = Vector3i(p_cx * 16, 0, p_cz * 16);
		d["w"] = 16;
		d["d"] = 16;
		d["arr"] = pba_from(r.eff);
		d["blk_src"] = r.blk_src;
		d["mask"] = pba_from(r.mask);
		PackedInt32Array ring;
		ring.resize((int64_t)r.ring.size());
		if (!r.ring.empty())
			std::memcpy(ring.ptrw(), r.ring.data(), r.ring.size() * sizeof(int32_t));
		d["ring"] = ring;
		return d;
	}

	// Flood timing (usec per _flood_flat call, capped histogram).
	Dictionary flood_stats() const {
		std::lock_guard<std::mutex> lk(_flood_mtx);
		Dictionary d;
		d["n"] = (int64_t)_flood_n;
		d["total_ms"] = (double)_flood_total_us / 1000.0;
		if (_flood_hist.empty()) {
			d["p50_ms"] = 0.0;
			d["p95_ms"] = 0.0;
			d["max_ms"] = 0.0;
			return d;
		}
		std::vector<uint32_t> hv = _flood_hist;
		std::sort(hv.begin(), hv.end());
		size_t p50 = (size_t)std::min<double>((double)hv.size() * 0.50, (double)(hv.size() - 1));
		size_t p95 = (size_t)std::min<double>((double)hv.size() * 0.95, (double)(hv.size() - 1));
		d["p50_ms"] = (double)hv[p50] / 1000.0;
		d["p95_ms"] = (double)hv[p95] / 1000.0;
		d["max_ms"] = (double)_flood_max_us / 1000.0;
		return d;
	}

	void reset_flood_stats() {
		std::lock_guard<std::mutex> lk(_flood_mtx);
		_flood_hist.clear();
		_flood_n = 0;
		_flood_total_us = 0;
		_flood_max_us = 0;
	}

private:
	static void record_flood_local(const std::vector<uint32_t> &floods, std::mutex &mtx, std::vector<uint32_t> &hist, int64_t &n, uint64_t &total_us, uint32_t &max_us) {
		std::lock_guard<std::mutex> lk(mtx);
		for (uint32_t us : floods) {
			n++;
			total_us += us;
			if (us > max_us)
				max_us = us;
			if (hist.size() < 100000)
				hist.push_back(us);
		}
	}

	void record_flood(const std::vector<uint32_t> &floods) {
		record_flood_local(floods, _flood_mtx, _flood_hist, _flood_n, _flood_total_us, _flood_max_us);
	}

	mutable std::mutex _flood_mtx;
	std::vector<uint32_t> _flood_hist; // capped (100k) for the percentiles
	int64_t _flood_n = 0;
	uint64_t _flood_total_us = 0;
	uint32_t _flood_max_us = 0;
};

void register_classes() {
	GDREGISTER_CLASS(AweLighting);
}

} // namespace awelight
