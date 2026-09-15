// AC-0283 P1: AweStarlight — the Starlight-style single-queue light engine,
// a STRUCTURE rewrite of AweLighting's (lighting.cpp) semantics, NOT a
// values rewrite: the same per-cell light the current engine produces,
// computed incrementally on per-section (16x16x16, slab-aligned) nibble
// arrays with one global queue instead of a per-chunk re-flood.
//
// SEMANTICS PORTED EXACTLY (the current engine is the reference):
//   * sky seed = the column-pull open scan (open carried top-down from the
//     world top, sky 15 iff open && att>0 — the game's sky is column-pull,
//     NOT MC's full sky spread: the combined eff flood of the pull kernel
//     never crossed a chunk edge for sky; only the BLOCK strips did). The
//     port keeps the game's model: the sky kind never propagates across an
//     x/z section (chunk) boundary, only vertically (same column) and
//     horizontally WITHIN a section (the chunk-local spread the eff flood
//     has always had);
//   * block seed = the cell's own glow (glowstone 12, lava 15, torch 14 —
//     the Tables, data.gd single-sourced via Lighting._att/_glow value
//     copies, shared with lighting.cpp through awe_common.h);
//   * relaxation = the bucket-16 flood verbatim: nl = lv - att[neighbor],
//     raise when nl > 0 && nl > stored[neighbor], neighbor order
//     (x+1, x-1, y+1, y-1, z+1, z-1); the writes are EAGER at relaxation
//     time (the legacy `src[n] = nl`), so a queued entry carries the level
//     it must PROPAGATE (the pop re-checks only the section epoch — the
//     edit-clear invalidation — and relaxes at the carried level, exactly
//     like the legacy bucket walk processes a stale-low entry at its own
//     level). The fixed point reached is the greatest fixed point >= the
//     seeds — identical to the legacy flood's result (monotone integer
//     map; see the AC-0283 P1 report for the invariant proof).
//   * eff = max(sky, block) — the legacy combined eff flood is
//     max-distributive over the two kind floods (AC-0129), so running both
//     kinds through the same relaxation and displaying the max is
//     byte-identical to the combined single flood.
//
// SEAM (cross-section sky context): seed_section takes an optional
// sky_above row (256 bytes, nonzero = open at that x/z cell). Empty =
// resolve: si == 23 (the world top, y 368..383 — full sky at y=383) or the
// already-seeded section above; the open carry OUT of a section is its
// bottom-row sky (== 15 iff open after the bottom cell, by construction of
// the scan), so no extra storage. The caller (P2) seeds top-down or hands
// the sky_above row (P3's far-band heightmap sky).
//
// EDITS (two-phase): on_edit(wx, wy, wz, new_id) clears the AFFECTED SET
// and re-floods it:
//   * affected set = the 3x3 x/z section neighborhood x sections
//     0..min(si+1, 23) — the block change is confined to the L1-14 ball
//     around the edit (max glow 15 -> range 14 < 16, inside the 3x3x3 box)
//     and the sky change to the L1-14 ball of the edit's own column below
//     it (the open carry only changes in that column); the set covers both
//     for every edit class (source removal, opaque add, blocker removal /
//     sky shaft opening, fluid changes);
//   * phase 1 (darkness): every section in the set is zeroed and its epoch
//     bumped — stale queue entries for it self-expire on pop (the Starlight
//     dirty pass, epoch variant) — then the set's boundary cells are
//     re-seeded from the SURVIVING outside light (cand = outside level -
//     att[boundary cell]; the strip-injection equivalent), which is exact
//     because the edit cannot affect light outside the set;
//   * phase 2 (heal): the cleared sections re-run the sky column scan
//     (open carry resolved top-down through the set) + the glow seeds, and
//     both are re-queued. Clear + boundary injection + re-seed recomputes
//     exactly the contained flood of the set against the true outside
//     light = the legacy "re-flood the affected region".
//
// STATELESS: reset() clears storage + queue; the only light source is block
// data (seed) — a section that is never seeded allocates nothing (the
// "no nibble alloc for far" property P3 relies on).
//
// WORKER SAFETY: same discipline as AweLighting — the tables arrive as
// value copies (set_tables, the pre-warmed Lighting._att/_glow), no
// autoloads.

#include <gdextension_interface.h>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <map>
#include <set>
#include <deque>
#include <vector>

#include "awe_common.h"

using namespace godot;

namespace awestarlight {

constexpr int S3 = 4096; // section cells
constexpr int NIB = S3 / 2; // 2048 nibble bytes per array
constexpr int NSL = 24; // sections per column (Data.HEIGHT 384 / 16)
constexpr int SKY_FULL = 15;

using awelight::Tables;

// Direction order = the legacy neighbor order (x+1, x-1, y+1, y-1, z+1,
// z-1); nb[] slots carry the same indices.
static const int DX[6] = {1, -1, 0, 0, 0, 0};
static const int DY[6] = {0, 0, 1, -1, 0, 0};
static const int DZ[6] = {0, 0, 0, 0, 1, -1};
static const int REV[6] = {1, 0, 3, 2, 5, 4};

static inline int nib_get(const std::vector<uint8_t> &v, int p) {
	return (v[p >> 1] >> ((p & 1) << 2)) & 15;
}
static inline void nib_set(std::vector<uint8_t> &v, int p, int lv) {
	if (p & 1)
		v[p >> 1] = (uint8_t)((v[p >> 1] & 0x0F) | (lv << 4));
	else
		v[p >> 1] = (uint8_t)((v[p >> 1] & 0xF0) | (lv & 0xF));
}
static inline void nib_max(std::vector<uint8_t> &v, int p, int lv) {
	if (lv > nib_get(v, p))
		nib_set(v, p, lv);
}

// the section key: 28-bit two's-complement fields (|coord| < 2^27 chunks),
// non-overlapping: si bits 0..4, cz bits 5..32, cx bits 33..60
static inline uint64_t sec_key(int cx, int cz, int si) {
	return ((uint64_t)(((uint32_t)cx) & 0x0FFFFFFFu) << 33)
		| ((uint64_t)(((uint32_t)cz) & 0x0FFFFFFFu) << 5)
		| (uint64_t)si;
}
static inline int floor16(int v) {
	return v >= 0 ? v / 16 : -((-v + 15) / 16);
}
static inline uint64_t now_us() {
	return (uint64_t)Time::get_singleton()->get_ticks_usec();
}

struct Sec {
	uint64_t key = 0;
	int cx = 0;
	int cz = 0;
	int si = 0;
	std::vector<uint8_t> ids; // 4096 block ids ((y<<8)|(z<<4)|x)
	std::vector<uint8_t> sky; // 2048 nibble bytes
	std::vector<uint8_t> blk;
	uint32_t epoch = 0;
	int pending = 0; // queue entries currently referencing this section
	Sec *nb[6] = {nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};
};

struct QEnt {
	uint64_t key = 0;
	uint32_t cell = 0;
	uint32_t epoch = 0;
	uint8_t kind = 0; // 0 = sky, 1 = block
	uint8_t lv = 0;
};

class AweStarlight : public RefCounted {
	GDCLASS(AweStarlight, RefCounted)

public:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("set_tables", "att", "glow"), &AweStarlight::set_tables);
		ClassDB::bind_method(D_METHOD("reset"), &AweStarlight::reset);
		ClassDB::bind_method(D_METHOD("seed_section", "cx", "cz", "si", "ids", "sky_above"), &AweStarlight::seed_section);
		ClassDB::bind_method(D_METHOD("step", "budget_us"), &AweStarlight::step);
		ClassDB::bind_method(D_METHOD("on_edit", "wx", "wy", "wz", "new_id"), &AweStarlight::on_edit);
		ClassDB::bind_method(D_METHOD("section_sky", "cx", "cz", "si"), &AweStarlight::section_sky);
		ClassDB::bind_method(D_METHOD("section_block", "cx", "cz", "si"), &AweStarlight::section_block);
		ClassDB::bind_method(D_METHOD("section_settled", "cx", "cz", "si"), &AweStarlight::section_settled);
		ClassDB::bind_method(D_METHOD("pending_cells"), &AweStarlight::pending_cells);
		ClassDB::bind_method(D_METHOD("stats"), &AweStarlight::stats);
		ClassDB::bind_method(D_METHOD("compare_eff", "cx", "cz", "eff"), &AweStarlight::compare_eff);
		ClassDB::bind_method(D_METHOD("compare_eff_all", "cx", "cz", "eff", "limit"), &AweStarlight::compare_eff_all);
		ClassDB::bind_method(D_METHOD("compare_split", "cx", "cz", "sky", "blk"), &AweStarlight::compare_split);
	}

	void set_tables(const PackedByteArray &p_att, const PackedByteArray &p_glow) {
		att_buf.resize(p_att.size());
		if (p_att.size() > 0)
			std::memcpy(att_buf.data(), p_att.ptr(), p_att.size());
		glow_buf.resize(p_glow.size());
		if (p_glow.size() > 0)
			std::memcpy(glow_buf.data(), p_glow.ptr(), p_glow.size());
		t.att = att_buf.data();
		t.att_sz = (int)att_buf.size();
		t.glow = glow_buf.data();
		t.glow_sz = (int)glow_buf.size();
	}

	void reset() {
		secs.clear();
		for (int i = 0; i < 16; i++)
			q[i].clear();
		queue_n = 0;
		cells_processed = 0;
		enqueued_n = 0;
		stale_pops = 0;
		edits_n = 0;
	}

	bool seed_section(int p_cx, int p_cz, int p_si, const PackedByteArray &p_ids, const PackedByteArray &p_sky_above) {
		if (p_si < 0 || p_si >= NSL)
			return false;
		if (p_ids.size() != S3)
			return false;
		if (p_sky_above.size() != 0 && p_sky_above.size() != 256)
			return false;
		uint64_t key = sec_key(p_cx, p_cz, p_si);
		auto it = secs.find(key);
		if (it == secs.end()) {
			Sec ns;
			ns.key = key;
			ns.cx = p_cx;
			ns.cz = p_cz;
			ns.si = p_si;
			ns.ids.resize(S3);
			ns.sky.assign(NIB, 0);
			ns.blk.assign(NIB, 0);
			it = secs.emplace(key, std::move(ns)).first;
		} else {
			// a re-seed REPLACES the section's light (stale entries
			// self-expire through the epoch bump)
			it->second.sky.assign(NIB, 0);
			it->second.blk.assign(NIB, 0);
			it->second.epoch++;
		}
		Sec &s = it->second;
		std::memcpy(s.ids.data(), p_ids.ptr(), S3);
		uint8_t open_in[256];
		if (!open_in_of(p_cx, p_cz, p_si, p_sky_above, open_in))
			return false; // the section above must be seeded (contiguous column)
		scan_and_seed(s, open_in);
		link_neighbors(s);
		boundary_inject(s);
		enqueue_seeds(s);
		return true;
	}

	int64_t step(int64_t p_budget_us) {
		uint64_t t0 = p_budget_us > 0 ? now_us() : 0;
		int64_t n = 0;
		// the legacy bucket walk: levels 15..2, each bucket fully drained
		// (new lower-level pushes land in buckets not yet reached this pass)
		for (int lv = SKY_FULL; lv > 1; lv--) {
			std::deque<QEnt> &dq = q[lv];
			while (!dq.empty()) {
				QEnt e = dq.front();
				dq.pop_front();
				pop_entry(e);
				n++;
				cells_processed++;
				if (p_budget_us > 0 && (n & 4095) == 0 && now_us() - t0 >= (uint64_t)p_budget_us)
					return n;
			}
		}
		return n;
	}

	bool on_edit(int p_wx, int p_wy, int p_wz, int p_new_id) {
		if (p_wy < 0 || p_wy >= NSL * 16 || p_new_id < 0 || p_new_id > 255)
			return false;
		int cx = floor16(p_wx);
		int cz = floor16(p_wz);
		int si = p_wy >> 4;
		Sec *s0 = find_sec(cx, cz, si);
		if (s0 == nullptr)
			return false;
		// the affected set: 3x3 x/z neighborhood x sections 0..min(si+1, 23)
		// (block change inside the L1-14 ball of the edit; sky change inside
		// the L1-14 ball of the edit's own column below it — see the file
		// header). Both the set and its direct section neighbors must be
		// seeded (the boundary injection needs the true outside light; a
		// region-edge edit cannot be answered statelessly).
		int hi = si + 1;
		if (hi > NSL - 1)
			hi = NSL - 1;
		std::vector<uint64_t> keys;
		std::set<uint64_t> kset;
		for (int dx = -1; dx <= 1; dx++) {
			for (int dz = -1; dz <= 1; dz++) {
				for (int ssi = 0; ssi <= hi; ssi++) {
					uint64_t k = sec_key(cx + dx, cz + dz, ssi);
					if (kset.count(k) > 0)
						continue;
					kset.insert(k);
					keys.push_back(k);
					if (secs.find(k) == secs.end())
						return false;
				}
			}
		}
		for (uint64_t k : keys) {
			Sec &S = secs[k];
			for (int d = 0; d < 6; d++) {
				int nx = S.cx + DX[d];
				int nz = S.cz + DZ[d];
				int nsi = S.si + DY[d];
				if (nsi < 0 || nsi >= NSL)
					continue;
				uint64_t nk = sec_key(nx, nz, nsi);
				if (kset.count(nk) > 0)
					continue;
				if (secs.find(nk) == secs.end())
					return false;
			}
		}
		// phase 1: darkness — clear the set, expire its stale entries
		for (uint64_t k : keys) {
			Sec &S = secs[k];
			S.sky.assign(NIB, 0);
			S.blk.assign(NIB, 0);
			S.epoch++;
		}
		int ep = ((p_wy & 15) << 8) | ((p_wz & 15) << 4) | (p_wx & 15);
		s0->ids[ep] = (uint8_t)p_new_id;
		// phase 1.5: boundary injection from the surviving outside light
		for (uint64_t k : keys)
			boundary_inject(secs[k]);
		// phase 2: heal — top-down (the open carry flows down through the
		// cleared sections), sky scan + glow re-seed + re-queue
		std::sort(keys.begin(), keys.end(), [](uint64_t a, uint64_t b) {
			return (int)(a & 31) > (int)(b & 31);
		});
		for (uint64_t k : keys) {
			Sec &S = secs[k];
			uint8_t open_in[256];
			if (!open_in_of(S.cx, S.cz, S.si, PackedByteArray(), open_in))
				return false; // unseeded section above — the caller keeps columns contiguous
			scan_and_seed(S, open_in);
			enqueue_seeds(S);
		}
		edits_n++;
		return true;
	}

	PackedByteArray section_sky(int p_cx, int p_cz, int p_si) {
		Sec *s = find_sec(p_cx, p_cz, p_si);
		if (s == nullptr)
			return PackedByteArray();
		PackedByteArray out;
		out.resize(NIB);
		std::memcpy(out.ptrw(), s->sky.data(), NIB);
		return out;
	}

	PackedByteArray section_block(int p_cx, int p_cz, int p_si) {
		Sec *s = find_sec(p_cx, p_cz, p_si);
		if (s == nullptr)
			return PackedByteArray();
		PackedByteArray out;
		out.resize(NIB);
		std::memcpy(out.ptrw(), s->blk.data(), NIB);
		return out;
	}

	bool section_settled(int p_cx, int p_cz, int p_si) {
		Sec *s = find_sec(p_cx, p_cz, p_si);
		return s != nullptr && s->pending == 0;
	}

	int64_t pending_cells() {
		return queue_n;
	}

	Dictionary stats() {
		Dictionary d;
		d["sections"] = (int64_t)secs.size();
		d["pending"] = queue_n;
		d["cells_processed"] = cells_processed;
		d["enqueued"] = enqueued_n;
		d["stale_pops"] = stale_pops;
		d["edits"] = edits_n;
		d["att_sz"] = t.att_sz;
		d["glow_sz"] = t.glow_sz;
		return d;
	}

	Dictionary compare_eff(int p_cx, int p_cz, const PackedByteArray &p_eff) {
		Dictionary d;
		d["mismatches"] = (int64_t)0;
		d["max_diff"] = 0;
		d["first"] = Dictionary();
		if (p_eff.size() != NSL * S3)
			return d;
		int64_t mism = 0;
		int maxd = 0;
		Dictionary first;
		bool unseeded = false;
		for (int si = 0; si < NSL; si++) {
			Sec *s = find_sec(p_cx, p_cz, si);
			if (s == nullptr) {
				unseeded = true;
				break;
			}
			for (int p = 0; p < S3; p++) {
				int star = std::max(nib_get(s->sky, p), nib_get(s->blk, p));
				int ref = p_eff[(size_t)si * S3 + p];
				int df = star > ref ? star - ref : ref - star;
				if (df > maxd)
					maxd = df;
				if (star != ref) {
					if (mism == 0) {
						first["y"] = si * 16 + (p >> 8);
						first["x"] = p & 15;
						first["z"] = (p >> 4) & 15;
						first["starlight"] = star;
						first["current"] = ref;
					}
					mism++;
				}
			}
		}
		d["mismatches"] = unseeded ? (int64_t)-1 : mism;
		d["max_diff"] = maxd;
		d["first"] = first;
		return d;
	}

	// every mismatch (up to p_limit): int32 = (si<<20)|(p<<8)|(star<<4)|ref
	PackedInt32Array compare_eff_all(int p_cx, int p_cz, const PackedByteArray &p_eff, int p_limit) {
		PackedInt32Array out;
		if (p_eff.size() != NSL * S3)
			return out;
		int n = 0;
		for (int si = 0; si < NSL; si++) {
			Sec *s = find_sec(p_cx, p_cz, si);
			if (s == nullptr)
				return out;
			for (int p = 0; p < S3; p++) {
				int star = std::max(nib_get(s->sky, p), nib_get(s->blk, p));
				int ref = p_eff[(size_t)si * S3 + p];
				if (star != ref) {
					out.append((si << 20) | (p << 8) | (star << 4) | ref);
					if (++n >= p_limit)
						return out;
				}
			}
		}
		return out;
	}

	Dictionary compare_split(int p_cx, int p_cz, const PackedByteArray &p_sky, const PackedByteArray &p_blk) {
		Dictionary d;
		d["mismatches_sky"] = (int64_t)0;
		d["mismatches_blk"] = (int64_t)0;
		d["first"] = Dictionary();
		if (p_sky.size() != NSL * S3 || p_blk.size() != NSL * S3)
			return d;
		int64_t ms = 0;
		int64_t mb = 0;
		Dictionary first;
		bool unseeded = false;
		for (int si = 0; si < NSL; si++) {
			Sec *s = find_sec(p_cx, p_cz, si);
			if (s == nullptr) {
				unseeded = true;
				break;
			}
			for (int p = 0; p < S3; p++) {
				int ss = nib_get(s->sky, p);
				int rs = p_sky[(size_t)si * S3 + p];
				if (ss != rs) {
					if (first.is_empty()) {
						first["field"] = "sky";
						first["y"] = si * 16 + (p >> 8);
						first["x"] = p & 15;
						first["z"] = (p >> 4) & 15;
						first["starlight"] = ss;
						first["current"] = rs;
					}
					ms++;
				}
				int sb = nib_get(s->blk, p);
				int rb = p_blk[(size_t)si * S3 + p];
				if (sb != rb) {
					if (first.is_empty()) {
						first["field"] = "blk";
						first["y"] = si * 16 + (p >> 8);
						first["x"] = p & 15;
						first["z"] = (p >> 4) & 15;
						first["starlight"] = sb;
						first["current"] = rb;
					}
					mb++;
				}
			}
		}
		d["mismatches_sky"] = unseeded ? (int64_t)-1 : ms;
		d["mismatches_blk"] = unseeded ? (int64_t)-1 : mb;
		d["first"] = first;
		return d;
	}

private:
	Sec *find_sec(int p_cx, int p_cz, int p_si) {
		if (p_si < 0 || p_si >= NSL)
			return nullptr;
		auto it = secs.find(sec_key(p_cx, p_cz, p_si));
		return it == secs.end() ? nullptr : &it->second;
	}

	// the open carry IN at the top of the section: the sky_above row (the
	// caller's context), the world top (si == 23, full open), or the
	// seeded section above — its bottom-row sky IS the open carry out
	// (== 15 iff open after the bottom cell, by construction of the scan).
	bool open_in_of(int p_cx, int p_cz, int p_si, const PackedByteArray &p_sky_above, uint8_t *r_out) const {
		if (p_sky_above.size() == 256) {
			const uint8_t *a = p_sky_above.ptr();
			for (int i = 0; i < 256; i++)
				r_out[i] = (uint8_t)(a[i] != 0);
			return true;
		}
		if (p_si == NSL - 1) {
			std::memset(r_out, 1, 256);
			return true;
		}
		auto it = secs.find(sec_key(p_cx, p_cz, p_si + 1));
		if (it == secs.end())
			return false;
		for (int i = 0; i < 256; i++)
			r_out[i] = (uint8_t)(nib_get(it->second.sky, i) == 15);
		return true;
	}

	// the column scan + seed pre-write (the legacy seed pass writes the
	// seeds into src before the bucket walk): sky 15 where open && att>0,
	// the cell's own glow into blk.
	void scan_and_seed(Sec &s, const uint8_t *p_open_in) {
		for (int ix = 0; ix < 16; ix++) {
			for (int iz = 0; iz < 16; iz++) {
				int tt = iz * 16 + ix;
				int open = p_open_in[tt];
				for (int cy = 15; cy >= 0; cy--) {
					int p = (cy << 8) | (iz << 4) | ix;
					int b = s.ids[p];
					int at = t.a(b);
					if (t.g(b) > 0)
						nib_max(s.blk, p, t.g(b));
					if (open && at > 0)
						nib_max(s.sky, p, SKY_FULL);
					if (open && at == 0)
						open = 0;
				}
			}
		}
	}

	// the legacy seed-pass spr test (the cell seeds the queue only when it
	// can actually raise a neighbor — an open-sky section then costs zero
	// queue work, exactly like the legacy flood)
	bool spread_test(const Sec &s, int p_kind, int p_p, int p_lv) const {
		int x = p_p & 15;
		int z = (p_p >> 4) & 15;
		int y = (p_p >> 8) & 15;
		for (int d = 0; d < 6; d++) {
			int nx = x + DX[d];
			int ny = y + DY[d];
			int nz = z + DZ[d];
			Sec *ns;
			int np;
			if (!neighbor_of(s, x, y, z, d, ns, np))
				continue;
			// the sky kind spreads within the section and vertically across
			// sections, but never across a chunk x/z boundary (the column-
			// pull model — the legacy eff flood was chunk-local for sky)
			bool crossed_xz = (nx < 0 || nx > 15) || (nz < 0 || nz > 15);
			if (p_kind == 0 && crossed_xz)
				continue;
			int at = t.a(ns->ids[np]);
			if (at > 0 && p_lv - at > nib_get(p_kind ? ns->blk : ns->sky, np))
				return true;
		}
		return false;
	}

	// the neighbor section + the cell in it, for direction d from (x,y,z)
	bool neighbor_of(const Sec &s, int p_x, int p_y, int p_z, int p_d, Sec *&r_ns, int &r_np) const {
		int x = p_x + DX[p_d];
		int y = p_y + DY[p_d];
		int z = p_z + DZ[p_d];
		if (x >= 0 && x < 16 && y >= 0 && y < 16 && z >= 0 && z < 16) {
			r_ns = const_cast<Sec *>(&s);
			r_np = (y << 8) | (z << 4) | x;
			return true;
		}
		r_ns = s.nb[p_d];
		if (r_ns == nullptr)
			return false;
		if (DX[p_d] == 1)
			r_np = (p_y << 8) | (p_z << 4);
		else if (DX[p_d] == -1)
			r_np = (p_y << 8) | (p_z << 4) | 15;
		else if (DY[p_d] == 1)
			r_np = (p_z << 4) | p_x;
		else if (DY[p_d] == -1)
			r_np = (15 << 8) | (p_z << 4) | p_x;
		else if (DZ[p_d] == 1)
			r_np = (p_y << 8) | p_x;
		else
			r_np = (p_y << 8) | (15 << 4) | p_x;
		return true;
	}

	// link the nb[] pointers (monotone fill; the map keeps pointers stable,
	// so a neighbor seeded later just fills the slot it left null)
	void link_neighbors(Sec &s) {
		for (int d = 0; d < 6; d++) {
			if (s.nb[d] != nullptr)
				continue;
			int nsi = s.si + DY[d];
			if (nsi < 0 || nsi >= NSL)
				continue;
			auto it = secs.find(sec_key(s.cx + DX[d], s.cz + DZ[d], nsi));
			if (it == secs.end())
				continue;
			Sec *n = &it->second;
			s.nb[d] = n;
			if (n->nb[REV[d]] == nullptr)
				n->nb[REV[d]] = &s;
		}
	}

	// seed the section from the ALREADY-seeded neighbors' light (the
	// strip-injection equivalent: cand = the outside level - att[this
	// cell]; the sky kind only across the y faces — the column-pull model)
	void boundary_inject(Sec &s) {
		for (int d = 0; d < 6; d++) {
			if (s.nb[d] == nullptr)
				continue;
			Sec &n = *s.nb[d];
			for (int a = 0; a < 16; a++) {
				for (int b = 0; b < 16; b++) {
					int p;
					int np;
					if (DX[d] == 1) {
						p = (a << 8) | (b << 4) | 15;
						np = (a << 8) | (b << 4);
					} else if (DX[d] == -1) {
						p = (a << 8) | (b << 4);
						np = (a << 8) | (b << 4) | 15;
					} else if (DY[d] == 1) {
						p = (15 << 8) | (b << 4) | a;
						np = (b << 4) | a;
					} else if (DY[d] == -1) {
						p = (b << 4) | a;
						np = (15 << 8) | (b << 4) | a;
					} else if (DZ[d] == 1) {
						p = (a << 8) | (15 << 4) | b;
						np = (a << 8) | b;
					} else {
						p = (a << 8) | b;
						np = (a << 8) | (15 << 4) | b;
					}
					int at = t.a(s.ids[p]);
					if (at == 0)
						continue;
					int cand_blk = nib_get(n.blk, np) - at;
					if (cand_blk > 0)
						relax(&s, p, 1, cand_blk);
					if (DX[d] == 0 && DZ[d] == 0) {
						int cand_sky = nib_get(n.sky, np) - at;
						if (cand_sky > 0)
							relax(&s, p, 0, cand_sky);
					}
				}
			}
		}
	}

	// the seed path: the value is already stored (the scan / glow
	// pre-write) — queue it for propagation when the spr test passes
	void enqueue_seeds(Sec &s) {
		for (int kind = 0; kind < 2; kind++) {
			const std::vector<uint8_t> &arr = kind ? s.blk : s.sky;
			for (int p = 0; p < S3; p++) {
				int lv = nib_get(arr, p);
				if (lv <= 1)
					continue;
				if (spread_test(s, kind, p, lv)) {
					QEnt e;
					e.key = s.key;
					e.cell = (uint32_t)p;
					e.epoch = s.epoch;
					e.kind = (uint8_t)kind;
					e.lv = (uint8_t)lv;
					q[lv].push_back(e);
					s.pending++;
					queue_n++;
					enqueued_n++;
				}
			}
		}
	}

	// the relaxation path (eager write, the legacy src[n] = nl): raise the
	// neighbor when nl > stored, and queue it at the raised level (level 1
	// writes but never queues — the legacy buckets[1] is never walked and
	// a level-1 pop can raise nothing: nl = 1 - att <= 0)
	void relax(Sec *s, int p_p, int p_kind, int p_lv) {
		std::vector<uint8_t> &arr = p_kind ? s->blk : s->sky;
		if (p_lv > 0 && p_lv > nib_get(arr, p_p)) {
			nib_set(arr, p_p, p_lv);
			if (p_lv > 1) {
				QEnt e;
				e.key = s->key;
				e.cell = (uint32_t)p_p;
				e.epoch = s->epoch;
				e.kind = (uint8_t)p_kind;
				e.lv = (uint8_t)p_lv;
				q[p_lv].push_back(e);
				s->pending++;
				queue_n++;
				enqueued_n++;
			}
		}
	}

	// the legacy bucket pop: relax the 6 neighbors (legacy order) at the
	// carried level; a stale-low entry does the (redundant) 6 checks and
	// raises nothing — the same work the legacy bucket walk does
	void pop_entry(QEnt &e) {
		auto it = secs.find(e.key);
		if (it == secs.end())
			return; // unreachable — sections are never removed
		Sec &s = it->second;
		s.pending--;
		queue_n--;
		if (e.epoch != s.epoch) {
			stale_pops++;
			return; // the section was cleared after this entry was queued
		}
		int x = e.cell & 15;
		int z = (e.cell >> 4) & 15;
		int y = (e.cell >> 8) & 15;
		for (int d = 0; d < 6; d++) {
			int nx = x + DX[d];
			int ny = y + DY[d];
			int nz = z + DZ[d];
			Sec *ns;
			int np;
			if (!neighbor_of(s, x, y, z, d, ns, np))
				continue;
			// the sky kind: within-section + vertical only (the column-
			// pull model — never across a chunk x/z boundary)
			bool crossed_xz = (nx < 0 || nx > 15) || (nz < 0 || nz > 15);
			if (e.kind == 0 && crossed_xz)
				continue;
			int at = t.a(ns->ids[np]);
			if (at == 0)
				continue;
			int nl = e.lv - at;
			if (nl <= 0)
				continue;
			relax(ns, np, e.kind, nl);
		}
	}

	Tables t;
	std::vector<uint8_t> att_buf;
	std::vector<uint8_t> glow_buf;
	std::map<uint64_t, Sec> secs; // node-stable (nb[] pointers)
	std::deque<QEnt> q[16];
	int64_t queue_n = 0;
	int64_t cells_processed = 0;
	int64_t enqueued_n = 0;
	int64_t stale_pops = 0;
	int64_t edits_n = 0;
};

void register_classes() {
	GDREGISTER_CLASS(AweStarlight);
}

} // namespace awestarlight
