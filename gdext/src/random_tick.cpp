// AC-0370: AweRandomTick — the per-tick random block pass (the hash and the
// random_tick_map bookkeeping) ported from GDScript (world.gd
// _random_tick_pass / _rt_colhash / _rt_mix64 / _apply_random_tick) to the
// native lane. One synchronous call per fired 20 Hz tick (the AC-0356 shape:
// a batched native call removing a per-tick main-thread cost wholesale; the
// work is a few µs in C++, so no queue / no drain pacing).
//
// BIT-IDENTICAL BY CONSTRUCTION (the GDScript reference stays in world.gd as
// _rt_colhash / _rt_mix64 — the `tick` arm's recompute check runs them
// against this class's logged positions and gates recompute_mismatch == 0):
//   * the mix64 chain runs on int64_t: + and * wrap mod 2^64 exactly like the
//     GDScript int, and >> is an ARITHMETIC shift on both lanes (GDScript int
//     is int64; C++ right-shift on negative signed is arithmetic on the
//     toolchains this builds with — the unpacks (& 15) mask the extension
//     bits either way);
//   * the constants are the GDScript int64 bit patterns
//     ((0x9E3779B9 << 32) | 0x7F4A7C15 etc. — the high word sets the sign
//     bit, so they are negative as int64; the casts below keep the pattern);
//   * the map update is map[base*24+sub] += 1 per position — the GDScript
//     `random_tick_map[sk] = int(random_tick_map.get(sk, 0)) + 1` verbatim.
// The consumer hook stays a stub (it was a stub in the GDScript: the only
// observable state is the counter and this map); the map is C++ state now —
// the only reader is the harness `tick` arm (scope check via map_dict()).
//
// Shares the libchunkio library (one .so/.dll, entry chunkio_library_init).

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <cstdint>
#include <unordered_map>

using namespace godot;

namespace awert {

static inline int64_t mix64(int64_t x) {
	x += (int64_t)0x9E3779B97F4A7C15ULL;
	x = ((x ^ (x >> 30)) * (int64_t)0xBF58476D1CE4E5B9ULL);
	x = ((x ^ (x >> 27)) * (int64_t)0x94D049BB133111EBULL);
	return x ^ (x >> 31);
}

class AweRandomTick : public RefCounted {
	GDCLASS(AweRandomTick, RefCounted)

private:
	std::unordered_map<int64_t, int64_t> map_;

public:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("random_tick_pass", "t", "seed", "cxs", "czs", "log"), &AweRandomTick::random_tick_pass);
		ClassDB::bind_method(D_METHOD("map_dict"), &AweRandomTick::map_dict);
		ClassDB::bind_method(D_METHOD("reset"), &AweRandomTick::reset);
	}

	// One fired tick over the band-0 columns (cx, cz pairs — the caller has
	// already applied the band/face/data filter and the log-sort). Per
	// column: the colhash, then 24 sub-chunks of mix64 positions, each
	// incrementing map_[base*24+sub]. Returns the logged seq —
	// (base, sub, lx, ly, lz) × 5 × n — when log, else an empty array.
	PackedInt32Array random_tick_pass(int64_t t, int64_t seed, const PackedInt32Array &cxs, const PackedInt32Array &czs, bool log) {
		PackedInt32Array seq;
		const int n = cxs.size();
		if (log)
			seq.resize(n * 24 * 5);
		int64_t j = 0;
		for (int i = 0; i < n; i++) {
			const int64_t cx = cxs[i];
			const int64_t cz = czs[i];
			const int64_t base = (cx + 4096) * 16384 + (cz + 4096);
			int64_t h = seed;
			h = mix64(h + t);
			h = mix64(h ^ (cx * 0x85EBCA6B));
			h = mix64(h ^ (cz * 0xC2B2AE35));
			for (int sub = 0; sub < 24; sub++) {
				const int64_t hh = mix64(h ^ ((int64_t)sub * 0x9E3779B9));
				const int64_t lx = hh & 15;
				const int64_t ly = (hh >> 4) & 15;
				const int64_t lz = (hh >> 8) & 15;
				map_[base * 24 + sub] += 1;
				if (log) {
					seq[j] = (int32_t)base;
					seq[j + 1] = (int32_t)sub;
					seq[j + 2] = (int32_t)lx;
					seq[j + 3] = (int32_t)ly;
					seq[j + 4] = (int32_t)lz;
					j += 5;
				}
			}
		}
		return seq;
	}

	// The map on demand (the harness scope check — built only when read).
	Dictionary map_dict() {
		Dictionary d;
		for (const auto &kv : map_)
			d[(int64_t)kv.first] = (int64_t)kv.second;
		return d;
	}

	void reset() {
		map_.clear();
	}
};

void register_classes() {
	GDREGISTER_CLASS(AweRandomTick);
}
} // namespace awert
