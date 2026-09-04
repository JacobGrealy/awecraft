// AC-0190: definitions for awe_common.h. The slab decode bodies are the
// exact verified code from AC-0189 lighting.cpp (slab_getbits/slab_unpack/
// slab_views) and AC-0165 chunk_io.cpp (slab_unpack) — moved verbatim so
// every module decodes paletted slabs the same way (the codec's
// byte-for-byte contract is unchanged).

#include "awe_common.h"

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <cstring>

namespace awecommon {

int slab_getbits(const uint8_t *i, int isize, int bits, int pos) {
	int bo = (pos * bits) >> 3;
	int sh = (pos * bits) & 7;
	uint32_t w = (uint32_t)i[bo] << 8;
	if (bo + 1 < isize)
		w |= i[bo + 1];
	return (w >> (16 - sh - bits)) & ((1u << bits) - 1);
}

std::vector<uint8_t> slab_unpack(const uint8_t *i, int isize, int bits, const uint8_t *p) {
	std::vector<uint8_t> out(S3, 0);
	if (bits == 1) {
		int j = 0;
		for (int k = 0; k < isize; k++) {
			uint32_t b = i[k];
			for (int r = 0; r < 8; r++) {
				out[j] = p[(b >> (7 - r)) & 1];
				j++;
			}
		}
	} else if (bits == 2) {
		int j = 0;
		for (int k = 0; k < isize; k++) {
			uint32_t b = i[k];
			for (int r = 0; r < 4; r++) {
				out[j] = p[(b >> (6 - 2 * r)) & 3];
				j++;
			}
		}
	} else if (bits == 3) {
		int j = 0;
		int k = 0;
		while (j < S3) {
			uint32_t w = (uint32_t)i[k] << 16;
			if (k + 1 < isize)
				w |= (uint32_t)i[k + 1] << 8;
			if (k + 2 < isize)
				w |= i[k + 2];
			for (int r = 0; r < 8; r++) {
				out[j] = p[(w >> (21 - 3 * r)) & 7];
				j++;
			}
			k += 3;
		}
	} else if (bits == 4) {
		for (int k = 0; k < isize; k++) {
			uint32_t b = i[k];
			out[2 * k] = p[(b >> 4) & 15];
			out[2 * k + 1] = p[b & 15];
		}
	} else {
		for (int j = 0; j < S3; j++)
			out[j] = p[slab_getbits(i, isize, bits, j)];
	}
	return out;
}

void slab_views(const godot::Array &p_data, std::vector<std::vector<uint8_t>> &out) {
	out.assign(p_data.size(), std::vector<uint8_t>());
	for (int k = 0; k < (int)out.size(); k++) {
		godot::Variant v = p_data[k];
		if (v.get_type() != godot::Variant::DICTIONARY)
			continue;
		godot::Dictionary d = v;
		int n = d.get("n", 0);
		if (n == 1) {
			godot::PackedByteArray p = d.get("p", godot::PackedByteArray());
			uint8_t val = p.size() > 0 ? p[0] : 0;
			out[k].assign(S3, val);
		} else if (n == 0) {
			godot::PackedByteArray i = d.get("i", godot::PackedByteArray());
			if (i.size() > 0)
				out[k].assign(i.ptr(), i.ptr() + i.size());
		} else {
			godot::PackedByteArray p = d.get("p", godot::PackedByteArray());
			godot::PackedByteArray i = d.get("i", godot::PackedByteArray());
			int b = d.get("b", 0);
			out[k] = slab_unpack(i.ptr(), (int)i.size(), b, p.ptr());
		}
	}
}

godot::PackedByteArray pba_from(const std::vector<uint8_t> &v) {
	godot::PackedByteArray out;
	out.resize((int)v.size());
	if (!v.empty())
		std::memcpy(out.ptrw(), v.data(), v.size());
	return out;
}

} // namespace awecommon
