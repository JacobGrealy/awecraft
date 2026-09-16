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
// LANDING-ORDER HEALING (AC-0283 P2): columns land in streaming ORDER, not
// all-at-once (P1's tests seeded a whole region first). When a section
// SETTLES (its last queue entry pops — or it seeds with nothing to spread)
// it re-injects its FINAL boundary light into its already-seeded neighbor
// sections (settle_notify -> boundary_inject on each seeded neighbor).
// boundary_inject is a MONOTONE MAX (relax only raises), so the re-inject
// can never corrupt: it adds exactly the boundary light the neighbor
// missed while this section was still relaxing, and it is a no-op when the
// boundary is unchanged. A later-landing neighbor therefore heals the
// already-settled ones (its settle re-injects into them; if it raised a
// cell, the neighbor un-settles, re-settles, and re-notifies ITS neighbors
// — the cascade walks the settle frontier to the region edge). The two
// phases are exact against each other: the edit two-phase's affected set
// (3x3 x/z x sections 0..si+1) provably contains every cell the change can
// lower (block range 14 < 16; sky is a column pull), so the monotone max
// outside the set only ever adds light a LANDING put there.
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
		ClassDB::bind_method(D_METHOD("seed_column", "cx", "cz", "flat"), &AweStarlight::seed_column);
		ClassDB::bind_method(D_METHOD("on_section_data", "cx", "cz", "si", "ids"), &AweStarlight::on_section_data);
		ClassDB::bind_method(D_METHOD("step", "budget_us"), &AweStarlight::step);
		ClassDB::bind_method(D_METHOD("on_edit", "wx", "wy", "wz", "new_id"), &AweStarlight::on_edit);
		ClassDB::bind_method(D_METHOD("box_settled", "cx", "cz", "si0", "si1"), &AweStarlight::box_settled);
		ClassDB::bind_method(D_METHOD("box_epochs", "cx", "cz", "si0", "si1"), &AweStarlight::box_epochs);
		ClassDB::bind_method(D_METHOD("column_settled", "cx", "cz"), &AweStarlight::column_settled);
		ClassDB::bind_method(D_METHOD("column_light_dict", "cx", "cz"), &AweStarlight::column_light_dict);
		ClassDB::bind_method(D_METHOD("slab_light_payload", "cx", "cz", "si0", "si1"), &AweStarlight::slab_light_payload);
		ClassDB::bind_method(D_METHOD("evict_column", "cx", "cz"), &AweStarlight::evict_column);
		ClassDB::bind_method(D_METHOD("frame_diff", "old", "new", "dx", "dz", "y0", "y1"), &AweStarlight::frame_diff);
		ClassDB::bind_method(D_METHOD("light_ver"), &AweStarlight::light_ver);
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
		light_ver_n = 0;
	}

	bool seed_section(int p_cx, int p_cz, int p_si, const PackedByteArray &p_ids, const PackedByteArray &p_sky_above) {
		if (p_si < 0 || p_si >= NSL)
			return false;
		if (p_ids.size() != S3)
			return false;
		if (p_sky_above.size() != 0 && p_sky_above.size() != 256)
			return false;
		// validate BEFORE mutating: a failed seam must not leave a
		// half-section (allocated, zero light, pending 0 = falsely settled)
		uint8_t open_in[256];
		if (!open_in_of(p_cx, p_cz, p_si, p_sky_above, open_in))
			return false; // the section above must be seeded (contiguous column)
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
		scan_and_seed(s, open_in);
		link_neighbors(s);
		boundary_inject(s);
		enqueue_seeds(s);
		if (s.pending == 0)
			settle_notify(s); // seeds with nothing to spread settle NOW
		mutate();
		return true;
	}

	// AC-0283 P2: seed ALL 24 sections top-down (si 23 -> 0) from the flat
	// column ids (NSL*4096 bytes, the slabs_flat layout: section si at
	// offset si*4096, cell (y<<8)|(z<<4)|x within the section). One call per
	// NEW column landing: the seam is always satisfiable (si 23 = the
	// full-open sky row; each lower section reads the just-seeded section
	// above), so no partial-failure state is possible here.
	void seed_column(int p_cx, int p_cz, const PackedByteArray &p_flat) {
		if (p_flat.size() != NSL * S3)
			return;
		for (int si = NSL - 1; si >= 0; si--) {
			PackedByteArray sids;
			sids.resize(S3);
			std::memcpy(sids.ptrw(), p_flat.ptr() + (size_t)si * S3, S3);
			seed_section(p_cx, p_cz, si, sids, PackedByteArray());
		}
	}

	// AC-0283 P2: re-land a section's DATA (a re-seed — a regen merge, an
	// evict-reload with edits since save). DIFF vs the stored ids first:
	// identical data is a NO-OP (the deterministic regen re-lands — nothing
	// un-settles, no churn). A diff runs on_edit's EXACT two-phase (clear
	// the 3x3 x/z box x sections 0..min(si+1,23) + epoch bump + ids write +
	// boundary re-inject + top-down sky re-scan + glow re-seed) with the
	// whole section's ids replaced. Unlike on_edit the x/z neighborhood need
	// not be fully seeded: an unseeded face drops (the region-boundary
	// semantics) and heals when that neighbor lands (the landing section's
	// settle re-injects into the existing side — the landing-order healing,
	// file header). Returns {"ok": bool, "changed": bool}.
	Dictionary on_section_data(int p_cx, int p_cz, int p_si, const PackedByteArray &p_ids) {
		Dictionary d;
		d["ok"] = false;
		d["changed"] = false;
		if (p_si < 0 || p_si >= NSL || p_ids.size() != S3)
			return d;
		Sec *s0 = find_sec(p_cx, p_cz, p_si);
		if (s0 == nullptr) {
			// unseeded section: a plain seed (the live load path seeds whole
			// columns top-down; this is the defensive single-section case)
			bool ok = seed_section(p_cx, p_cz, p_si, p_ids, PackedByteArray());
			d["ok"] = ok;
			d["changed"] = ok;
			return d;
		}
		if (std::memcmp(s0->ids.data(), p_ids.ptr(), S3) == 0) {
			d["ok"] = true; // no data change — nothing un-settles
			return d;
		}
		// the affected set (the on_edit set, anchored at the section): 3x3
		// x/z neighborhood x sections 0..min(si+1, 23) — every cell the
		// change can reach (block range 14 < 16 inside the box; the sky
		// carry down the own column below the section) is inside it.
		int hi = p_si + 1;
		if (hi > NSL - 1)
			hi = NSL - 1;
		std::vector<uint64_t> keys;
		std::set<uint64_t> kset;
		for (int dx = -1; dx <= 1; dx++) {
			for (int dz = -1; dz <= 1; dz++) {
				for (int ssi = 0; ssi <= hi; ssi++) {
					uint64_t k = sec_key(p_cx + dx, p_cz + dz, ssi);
					if (kset.count(k) > 0)
						continue;
					kset.insert(k);
					if (secs.find(k) != secs.end())
						keys.push_back(k); // unseeded sections stay out (heal on landing)
				}
			}
		}
		// phase 1: darkness — clear the seeded part of the set
		for (uint64_t k : keys) {
			Sec &S = secs[k];
			S.sky.assign(NIB, 0);
			S.blk.assign(NIB, 0);
			S.epoch++;
		}
		std::memcpy(s0->ids.data(), p_ids.ptr(), S3); // the ids ALWAYS update
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
			// the section above: seeded (a live column is seeded whole,
			// top-down, atomically) or the world top
			if (!open_in_of(S.cx, S.cz, S.si, PackedByteArray(), open_in))
				continue;
			scan_and_seed(S, open_in);
			enqueue_seeds(S);
			if (S.pending == 0)
				settle_notify(S);
		}
		mutate();
		d["ok"] = true;
		d["changed"] = true;
		return d;
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
		// the affected set, restricted to the SEEDED sections: an unseeded
		// face drops (the region-boundary semantics) and heals when that
		// column lands — the landing section's settle re-injects into the
		// existing side (AC-0283 P2, the landing-order healing; the old
		// full-neighborhood requirement was a byproduct of the no-heal
		// P1 engine).
		std::vector<uint64_t> keys;
		std::set<uint64_t> kset;
		for (int dx = -1; dx <= 1; dx++) {
			for (int dz = -1; dz <= 1; dz++) {
				for (int ssi = 0; ssi <= hi; ssi++) {
					uint64_t k = sec_key(cx + dx, cz + dz, ssi);
					if (kset.count(k) > 0)
						continue;
					kset.insert(k);
					if (secs.find(k) != secs.end())
						keys.push_back(k);
				}
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
		bool failed = false;
		for (uint64_t k : keys) {
			Sec &S = secs[k];
			uint8_t open_in[256];
			// the section above (same column — a live column is seeded
			// whole, top-down, atomically) or the world top; a broken
			// seam (a partially-seeded column, unreachable live) fails
			// soft: the ids are already written, the caller re-seeds the
			// whole column (seed_column) on a false return
			if (!open_in_of(S.cx, S.cz, S.si, PackedByteArray(), open_in)) {
				failed = true;
				continue;
			}
			scan_and_seed(S, open_in);
			enqueue_seeds(S);
			if (S.pending == 0)
				settle_notify(S);
		}
		mutate();
		edits_n++;
		return !failed;
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

	// AC-0283 P2: the E2 frame gate — the column's boundary frame on the
	// neighbor direction (dx/dz, the neighbor's offset from THIS column)
	// over rows [y0, y1] (a slab's bake-box window on the shared face):
	// returns 0 = identical to the old arr, 1 = changed (the old arr
	// matches in size — some frame cell differs), 2 = FIRST (the old arr
	// is missing/mis-sized — the frame is non-zero: the margin was empty
	// before). Frame layout (the legacy _frame_changed, world.gd): E (dx=1)
	// = lx 14,15; W (dx=-1) = lx 0,1; S (dz=1) = lz 14,15; N (dz=-1) = lz
	// 0,1; cell idx = (y<<8)|(lz<<4)|lx.
	int frame_diff(const PackedByteArray &p_old, const PackedByteArray &p_new, int p_dx, int p_dz, int p_y0, int p_y1) {
		const int h = NSL * 16;
		if (p_new.size() != 256 * h)
			return 0;
		int c0, c1;
		bool byz;
		if (p_dx > 0) {
			c0 = 14; c1 = 15; byz = false;
		} else if (p_dx < 0) {
			c0 = 0; c1 = 1; byz = false;
		} else if (p_dz > 0) {
			c0 = 14; c1 = 15; byz = true;
		} else {
			c0 = 0; c1 = 1; byz = true;
		}
		const uint8_t *no = (p_old.size() == p_new.size()) ? (const uint8_t *)p_old.ptr() : nullptr;
		const uint8_t *nn = (const uint8_t *)p_new.ptr();
		bool first_nonzero = false;
		for (int y = p_y0; y <= p_y1; y++) {
			size_t row = (size_t)y * 256;
			for (int t = 0; t < 16; t++) {
				size_t i0 = byz ? row + (size_t)c0 * 16 + t : row + (size_t)t * 16 + c0;
				size_t i1 = byz ? row + (size_t)c1 * 16 + t : row + (size_t)t * 16 + c1;
				if (nn[i0] > 0 || nn[i1] > 0)
					first_nonzero = true;
				if (no != nullptr && (no[i0] != nn[i0] || no[i1] != nn[i1]))
					return 1;
			}
		}
		if (no != nullptr)
			return 0;
		return first_nonzero ? 2 : 0;
	}

	// AC-0283 P2: drop a whole column's 24 sections (the chunk eviction —
	// the live world evicts far columns; the engine must bound its memory
	// to the live set). The nb[] links pointing AT the dropped sections are
	// cleared first (bidirectional slots — link_neighbors filled both
	// sides), so no neighbor dangles. In-flight queue entries for the
	// dropped sections self-expire on pop (the find fails — the queue_n
	// decrement there keeps the counter honest). The light the dropped
	// column imported into its neighbors STAYS (the neighbors' light is a
	// function of their own box data minus this column — when the column
	// reloads it re-seeds and the settle re-inject re-raises the
	// neighbor boundary cells the drop should have lowered... a reloaded
	// column can only ADD light at the boundary (absent = 0), and a
	// reloaded column with DIFFERENT data goes through on_section_data —
	// which is a fresh seed (the section is gone) — the neighbor's stale
	// boundary import is then healed by the next edit/re-seed wave; the
	// live reload path (evict + load) lands a fresh column, which the
	// streaming re-mesh (E2) covers: the neighbors' slabs re-mesh on the
	// column's settle against the engine's current values.
	void evict_column(int p_cx, int p_cz) {
		for (int si = 0; si < NSL; si++) {
			Sec *s = find_sec(p_cx, p_cz, si);
			if (s == nullptr)
				continue;
			for (int d = 0; d < 6; d++) {
				Sec *n = s->nb[d];
				if (n != nullptr && n->nb[REV[d]] == s)
					n->nb[REV[d]] = nullptr;
			}
			secs.erase(sec_key(p_cx, p_cz, si));
		}
	}

	// AC-0283 P2: the 3x3 x/z x [si0..si1] section box (the light gate).
	// Enumeration order (shared with box_epochs): ssi outer, then dx, then
	// dz, each -1..1.
	bool box_settled(int p_cx, int p_cz, int p_si0, int p_si1) {
		int s0 = std::max(0, p_si0);
		int s1 = std::min(NSL - 1, p_si1);
		if (s0 > s1)
			return false;
		for (int ssi = s0; ssi <= s1; ssi++) {
			for (int dx = -1; dx <= 1; dx++) {
				for (int dz = -1; dz <= 1; dz++) {
					if (!section_settled(p_cx + dx, p_cz + dz, ssi))
						return false;
				}
			}
		}
		return true;
	}

	// the box's section epochs in the box_settled enumeration order
	// (unseeded sections = -1): a dispatch captures this, a landing
	// re-checks it — any mutation inside the box (a neighbor seed, an
	// edit, a re-seed) bumped an epoch and datadrops the in-flight build.
	Array box_epochs(int p_cx, int p_cz, int p_si0, int p_si1) {
		Array out;
		int s0 = std::max(0, p_si0);
		int s1 = std::min(NSL - 1, p_si1);
		for (int ssi = s0; ssi <= s1; ssi++) {
			for (int dx = -1; dx <= 1; dx++) {
				for (int dz = -1; dz <= 1; dz++) {
					Sec *s = find_sec(p_cx + dx, p_cz + dz, ssi);
					out.append(s == nullptr ? (int64_t)-1 : (int64_t)s->epoch);
				}
			}
		}
		return out;
	}

	bool column_settled(int p_cx, int p_cz) {
		for (int si = 0; si < NSL; si++)
			if (!section_settled(p_cx, p_cz, si))
				return false;
		return true;
	}

	// the column's SETTLED light as the classic eff dict (the same shape
	// the pull kernel's dictionary output has: mn/w/d/arr/mask/ring/
	// blk_src) — feeds last_eff, the eff cache, the E2 frame compare and
	// the save-light capture. Empty when any section is unseeded.
	Dictionary column_light_dict(int p_cx, int p_cz) {
		Dictionary d;
		if (!column_seeded(p_cx, p_cz))
			return d;
		int h = NSL * 16;
		std::vector<uint8_t> eff((size_t)256 * h, 0);
		std::vector<uint8_t> blk((size_t)256 * h, 0);
		bool has_glow = false;
		for (int si = 0; si < NSL; si++) {
			const Sec &s = *find_sec(p_cx, p_cz, si);
			for (int p = 0; p < S3; p++) {
				int y = si * 16 + (p >> 8);
				size_t i = (size_t)y * 256 + (size_t)((p >> 4) & 15) * 16 + (p & 15);
				int sk = nib_get(s.sky, p);
				int bl = nib_get(s.blk, p);
				eff[i] = (uint8_t)(sk > bl ? sk : bl);
				blk[i] = (uint8_t)bl;
				if (t.g(s.ids[p]) > 0)
					has_glow = true;
			}
		}
		bool blk_inj = column_blk_inj(p_cx, p_cz);
		PackedByteArray mask;
		mask.resize((size_t)256 * h);
		PackedInt32Array ring;
		if (has_glow || blk_inj) {
			uint8_t *mp = mask.ptrw();
			for (size_t i = 0; i < (size_t)256 * h; i++)
				mp[i] = blk[i] > 0 ? 1 : 0;
			// the AC-0091 19-bit pack (lighting.cpp 359-379, side order
			// 0=E x=15, 1=W x=0, 2=N z=15, 3=S z=0)
			for (int y = 0; y < h; y++) {
				size_t row = (size_t)y * 256;
				for (int t2 = 0; t2 < 16; t2++) {
					int yy = y * 16 + t2;
					int lv0 = blk[row | (t2 << 4) | 15];
					if (lv0 > 0)
						ring.append((0 << 17) | (yy << 4) | lv0);
					int lv1 = blk[row | (t2 << 4)];
					if (lv1 > 0)
						ring.append((1 << 17) | (yy << 4) | lv1);
					int lv2 = blk[row | (15 << 4) | t2];
					if (lv2 > 0)
						ring.append((2 << 17) | (yy << 4) | lv2);
					int lv3 = blk[row | t2];
					if (lv3 > 0)
						ring.append((3 << 17) | (yy << 4) | lv3);
				}
			}
		}
		d["mn"] = Vector3i(p_cx * 16, 0, p_cz * 16);
		d["w"] = (int64_t)16;
		d["d"] = (int64_t)16;
		d["arr"] = awecommon::pba_from(eff);
		d["mask"] = mask;
		d["ring"] = ring;
		d["blk_src"] = has_glow;
		return d;
	}

	// AC-0283 P2: the DISPATCH PAYLOAD — everything the worker's build_accs
	// star path needs to bake slab window [si0..si1] without the pull
	// kernel (the gate guarantees the box is settled at capture time):
	//   eff    the own column's eff, full height (256*h) — the bake core +
	//          the res.light arr the eff cache / neighbor strips / save
	//          light read at full-height indices
	//   blk    the own column's blk, full height — ONLY when
	//          has_glow||blk_inj (the mask/ring source; empty otherwise,
	//          the common sky-only column)
	//   has_glow / blk_inj  the mask/ring gate (lighting.cpp 354-380)
	//   w_lo/w_hi  the bake-box row window (si0*16-2 .. (si1+1)*16-1,
	//          clamped — the 2-row overhang)
	//   side[4]    the 4 axis neighbors' boundary rows, EFF only (the
	//          margin bakes eff, exactly like the legacy eff_strips read
	//          last_eff["arr"]), each rows x 32 bytes:
	//          [inner 16, outer 16] per row (c=0 then c=1, t = the
	//          in-plane coord); E: x=0/1, W: x=15/14, S: z=0/1, N: z=15/14
	//   corner[4]  the 4 diagonal neighbors' 2x2 corner rows, EFF only,
	//          each rows x 4 bytes in (a*2+b) order (a = x-depth,
	//          b = z-depth — the bake_box corner layout); SE/SW/NE/NW
	//          StripSet order. Unseeded neighbors read zero (the
	//          missing-strip semantics).
	Dictionary slab_light_payload(int p_cx, int p_cz, int p_si0, int p_si1) {
		Dictionary d;
		d["ok"] = false;
		int s0 = std::max(0, p_si0);
		int s1 = std::min(NSL - 1, p_si1);
		if (s0 > s1 || !column_seeded(p_cx, p_cz))
			return d;
		int h = NSL * 16;
		int y_lo = std::max(0, s0 * 16 - 2);
		// AC-0283 P2 brightslab fix: the window must reach the bake box's
		// TOP margin rows ((s1+1)*16, +1) - the per-slab bake box spans
		// [s0*16-2, (s1+1)*16+1] and the worker zero-fills any strip row
		// outside the payload (a missing top margin under-lights the
		// max-probe of the slab's top-row faces by up to a few levels).
		int y_hi = std::min(h - 1, (s1 + 1) * 16 + 1);
		int rows = y_hi - y_lo + 1;
		std::vector<uint8_t> eff((size_t)256 * h, 0);
		std::vector<uint8_t> blk((size_t)256 * h, 0);
		bool has_glow = false;
		for (int si = 0; si < NSL; si++) {
			const Sec &s = *find_sec(p_cx, p_cz, si);
			for (int p = 0; p < S3; p++) {
				int y = si * 16 + (p >> 8);
				size_t i = (size_t)y * 256 + (size_t)((p >> 4) & 15) * 16 + (p & 15);
				int sk = nib_get(s.sky, p);
				int bl = nib_get(s.blk, p);
				eff[i] = (uint8_t)(sk > bl ? sk : bl);
				blk[i] = (uint8_t)bl;
				if (t.g(s.ids[p]) > 0)
					has_glow = true;
			}
		}
		bool blk_inj = column_blk_inj(p_cx, p_cz);
		d["eff"] = awecommon::pba_from(eff);
		d["has_glow"] = (int64_t)(has_glow ? 1 : 0);
		d["blk_inj"] = (int64_t)(blk_inj ? 1 : 0);
		if (has_glow || blk_inj)
			d["blk"] = awecommon::pba_from(blk);
		d["w_lo"] = (int64_t)y_lo;
		d["w_hi"] = (int64_t)y_hi;
		const int NSDX[4] = {1, -1, 0, 0};
		const int NSDZ[4] = {0, 0, 1, -1};
		Array sides;
		for (int k = 0; k < 4; k++) {
			std::vector<uint8_t> prow((size_t)rows * 32, 0);
			for (int y = y_lo; y <= y_hi; y++) {
				int si = y >> 4;
				int yl = y & 15;
				uint8_t *rr = prow.data() + (size_t)(y - y_lo) * 32;
				if (NSDX[k] != 0) {
					for (int t = 0; t < 16; t++) {
						rr[t] = (uint8_t)cell_eff(p_cx + NSDX[k], p_cz, si, (yl << 8) | (t << 4) | (NSDX[k] > 0 ? 0 : 15));
						rr[16 + t] = (uint8_t)cell_eff(p_cx + NSDX[k], p_cz, si, (yl << 8) | (t << 4) | (NSDX[k] > 0 ? 1 : 14));
					}
				} else {
					for (int t = 0; t < 16; t++) {
						rr[t] = (uint8_t)cell_eff(p_cx, p_cz + NSDZ[k], si, (yl << 8) | ((NSDZ[k] > 0 ? 0 : 15) << 4) | t);
						rr[16 + t] = (uint8_t)cell_eff(p_cx, p_cz + NSDZ[k], si, (yl << 8) | ((NSDZ[k] > 0 ? 1 : 14) << 4) | t);
					}
				}
			}
			sides.append(awecommon::pba_from(prow));
		}
		d["side"] = sides;
		Array corners;
		const int CDX[4] = {1, -1, 1, -1}; // SE, SW, NE, NW (the StripSet 4..7 order)
		const int CDZ[4] = {1, 1, -1, -1};
		for (int k = 0; k < 4; k++) {
			std::vector<uint8_t> prow((size_t)rows * 4, 0);
			for (int y = y_lo; y <= y_hi; y++) {
				int si = y >> 4;
				int yl = y & 15;
				uint8_t *rr = prow.data() + (size_t)(y - y_lo) * 4;
				for (int a = 0; a < 2; a++) {
					for (int b = 0; b < 2; b++) {
						int nx, nz;
						if (k == 0) {
							nx = a; // SE: local (a, b)
							nz = b;
						} else if (k == 1) {
							nx = 15 - a; // SW: local (15-a, b)
							nz = b;
						} else if (k == 2) {
							nx = a; // NE: local (a, 14+b)
							nz = 14 + b;
						} else {
							nx = 15 - a; // NW: local (15-a, 14+b)
							nz = 14 + b;
						}
						rr[a * 2 + b] = (uint8_t)cell_eff(p_cx + CDX[k], p_cz + CDZ[k], si, (yl << 8) | (nz << 4) | nx);
					}
				}
			}
			corners.append(awecommon::pba_from(prow));
		}
		d["corner"] = corners;
		d["ok"] = true;
		return d;
	}

	int64_t pending_cells() {
		return queue_n;
	}

	// AC-0283 P2: the global light-state mutation counter (seed / re-seed /
	// edit / every relaxation write) — a cheap "the engine moved" token
	// for the wprof live dict + diagnostics (the per-box epochs are the
	// landing staleness token; the eff cache rides the neighbor eff_gen
	// tuple).
	int64_t light_ver() {
		return light_ver_n;
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

	// AC-0283 P2: a neighbor cell's eff = max(sky, blk) (the display
	// light) — 0 for an unseeded section (the missing-strip semantics).
	int cell_eff(int p_cx, int p_cz, int p_si, int p_p) const {
		if (p_si < 0 || p_si >= NSL)
			return 0;
		auto it = secs.find(sec_key(p_cx, p_cz, p_si));
		if (it == secs.end())
			return 0;
		const Sec &s = it->second;
		return std::max(nib_get(s.sky, p_p), nib_get(s.blk, p_p));
	}

	bool column_seeded(int p_cx, int p_cz) const {
		for (int si = 0; si < NSL; si++) {
			if (secs.find(sec_key(p_cx, p_cz, si)) == secs.end())
				return false;
		}
		return true;
	}

	// an axis neighbor's shared-face cell carries block light (the pull
	// kernel's blk_inject reads the c=0 face half, full height —
	// lighting.cpp 348)
	bool column_blk_inj(int p_cx, int p_cz) const {
		const int NSDX[4] = {1, -1, 0, 0};
		const int NSDZ[4] = {0, 0, 1, -1};
		for (int si = 0; si < NSL; si++) {
			for (int k = 0; k < 4; k++) {
				auto it = secs.find(sec_key(p_cx + NSDX[k], p_cz + NSDZ[k], si));
				if (it == secs.end())
					continue;
				const Sec &n = it->second;
				for (int yl = 0; yl < 16; yl++) {
					for (int t = 0; t < 16; t++) {
						int p = (yl << 8) | ((NSDX[k] != 0) ? (t << 4) | (NSDX[k] > 0 ? 0 : 15) : ((NSDZ[k] > 0 ? 0 : 15) << 4) | t);
						if (nib_get(n.blk, p) > 0)
							return true;
					}
				}
			}
		}
		return false;
	}

	// AC-0283 P2: the landing-order healing (file header) — the section
	// has just SETTLED (its boundary light is final for the current
	// neighborhood state); re-inject it into every already-seeded
	// neighbor section (the monotone max — adds only what the neighbor
	// missed while this section was still relaxing; a no-op otherwise).
	void settle_notify(Sec &s) {
		for (int d = 0; d < 6; d++) {
			Sec *n = s.nb[d];
			if (n == nullptr)
				continue;
			boundary_inject(*n);
		}
	}

	// the eff-cache mutation counter (bumped on ANY light-state change —
	// seed, re-seed, edit, and every relaxation write): the GDScript eff
	// cache captures it at dispatch and misses while the engine state
	// moves (a later-landing neighbor's settle re-inject invalidates the
	// captured column without any per-column bookkeeping).
	void mutate() {
		light_ver_n++;
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
			mutate(); // the light state moved (AC-0283 P2)
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
		if (it == secs.end()) {
			queue_n--; // the section was evicted (AC-0283 P2) mid-flight
			return;
		}
		Sec &s = it->second;
		s.pending--;
		queue_n--;
		if (s.pending == 0)
			settle_notify(s); // the last entry drained — the section settles
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
	int64_t light_ver_n = 0;
};

void register_classes() {
	GDREGISTER_CLASS(AweStarlight);
}

} // namespace awestarlight
