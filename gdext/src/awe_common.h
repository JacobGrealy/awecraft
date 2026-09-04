// AC-0190: shared decode helpers for the libchunkio GDExtension modules
// (chunk_io / gen / lighting / mesh). The paletted slab format (AC-0203
// v4 codec) is null | {n,b,p,i,nz}: n==1 uniform fill, n==0 raw 8-bit,
// n==2..16 paletted (bits 1-8 MSB-first packed indices over palette[16],
// 4096 cells). Decode = direct palette lookup (int[] speed — the C++
// follow-on to AC-0203's "C++ palette is int lookup ~1ns" note).
//
// The slab view materialization (flat 4096-byte view per slab, empty for
// null) is what the worker hot paths consume: the GDScript _slab_flat
// used to run this in the Variant world (~18 ms per slab set); the C++
// ports (lighting AC-0189, mesh AC-0190) decode it here instead.

#pragma once

#include <cstdint>
#include <vector>

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace awecommon {

constexpr int S3 = 4096; // slab cells (16x16)

// Extract the `bits`-wide value at cell `pos` from a packed bitstream
// (MSB-first, identical to chunk_io.gd _slab_getbits / the codec's
// bitunpack).
int slab_getbits(const uint8_t *i, int isize, int bits, int pos);

// Full 4096-cell unpack: out[j] = palette[idx(j)] (the fast 1/2/3/4-bit
// lanes + the generic lane, identical to chunk_io.cpp slab_unpack).
std::vector<uint8_t> slab_unpack(const uint8_t *i, int isize, int bits, const uint8_t *p);

// Per-slab flat views for a slab array (null slab = empty view; n==1 =
// uniform fill; n==0 = raw copy; else palette unpack). out has exactly
// p_data.size() entries.
void slab_views(const godot::Array &p_data, std::vector<std::vector<uint8_t>> &out);

// std::vector<uint8_t> -> PackedByteArray (the common output conversion).
godot::PackedByteArray pba_from(const std::vector<uint8_t> &v);

} // namespace awecommon

namespace awelight {

struct PullOut {
	std::vector<uint8_t> eff; // sz*h
	std::vector<uint8_t> mask; // sz*h
	std::vector<int32_t> ring;
	bool blk_src = false;
};

// AC-0190: cross-module bridge into the pull kernel (same .so as the mesh
// module — the C++ build_accs recomputes light through the SAME kernel the
// AweLighting class exposes, so the mesh path's light is byte-identical to
// the class path). att/glow = the pre-warmed Lighting._att/_glow tables
// (size 48 value copies); r_flood (nullptr = do not record) collects the
// per-flood call times (usec).
PullOut pull(const godot::Array &p_data, int h, const godot::Array &p_blk_strips, const godot::Array &p_blk_strips_b, int top, const uint8_t *att, int att_sz, const uint8_t *glow, int glow_sz, std::vector<uint32_t> *r_flood);

// AC-0207: the bare bucket-16 flood + UN-gated boundary injection exposed
// for the strips face compute (src/strips.cpp) — the SAME kernels the pull
// kernel runs in lighting.cpp (byte-identical by construction, so the C++
// face's block light equals the GDScript Lighting._flood_flat/_chunk_blk_
// inject path). hact = active rows (-1 = full height); hgate = the inject
// row cap (-1 = full height).
struct FloodTables {
	const uint8_t *att = nullptr;
	int att_sz = 0;
	const uint8_t *glow = nullptr;
	int glow_sz = 0;
};
void flood_flat(uint8_t *p_src, const uint8_t *p_ids, int p_w, int p_h, int p_d, int p_hact, const FloodTables &p_t);
bool blk_inject(uint8_t *p_eff, const uint8_t *p_ids, int p_h, const godot::Array &p_blk_strips, int p_hgate, const FloodTables &p_t);

} // namespace awelight
