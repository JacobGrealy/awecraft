// AC-0165: GDExtension native port of the v4 paletted slab codec
// (godot/core/chunk_io.gd, AC-0203). Byte-for-byte compatible wire format:
// section = u8 present-count + u16 ascending slab idx + per-slab payload
// [n, bits, palette(n), packed]. n==1 uniform (bits 0, no packed);
// n==2..16 paletted (bits = slab_bits_for(n), MSB-first packed palette
// indices over 4096 cells); n==0 raw 8-bit slab (>16 unique ids).
// Decode hot path: out[base + j] = order[idx[j]] direct palette lookup.

#include <gdextension_interface.h>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <vector>

using namespace godot;

// AC-0188: the gen module (src/gen.cpp) shares this library — one
// .so/.dll, one entry symbol. AweGen registers from the same initializer
// below (namespace awegen, defined in gen.cpp).
// AC-0189: the lighting module (src/lighting.cpp) joins the same library —
// AweLighting (the pull kernel + bucket-16 flood port) registers from the
// same initializer (namespace awelight, defined in lighting.cpp).
// AC-0190: the mesh module (src/mesh.cpp) joins the same library — AweMesh
// (the build_accs port + greedy merged emit + bake box + snap + the C++
// paletted-slab decode) registers from the same initializer (namespace
// awemesh, defined in mesh.cpp).
// AC-0207: the strips module (src/strips.cpp) joins the same library —
// AweStrips (the _strips_for/_side_blk_strip port + the _compute_face_blk
// face compute with the C++ glow/solid_top palette probes) registers from
// the same initializer (namespace awestrips, defined in strips.cpp).
namespace awegen {
void register_classes();
}
namespace awelight {
void register_classes();
}
namespace awemesh {
void register_classes();
}
namespace awestrips {
void register_classes();
}

namespace {

constexpr int S3 = 4096;

int slab_bits_for(int n) {
	int b = 0;
	while ((1 << b) < n)
		b++;
	return b;
}

std::vector<uint8_t> bitpack(const uint8_t *vals, int n, int bits) {
	std::vector<uint8_t> out((n * bits + 7) / 8, 0);
	uint32_t cur = 0;
	int bitpos = 0;
	int bytepos = 0;
	for (int i = 0; i < n; i++) {
		cur = (cur << bits) | vals[i];
		bitpos += bits;
		while (bitpos >= 8) {
			bitpos -= 8;
			out[bytepos] = (cur >> bitpos) & 255;
			bytepos++;
			cur &= (1u << bitpos) - 1;
		}
	}
	if (bitpos > 0)
		out[bytepos] = cur & ((1u << bitpos) - 1);
	return out;
}

std::vector<uint8_t> bitunpack(const uint8_t *packed, int bits, int n) {
	std::vector<uint8_t> out(n, 0);
	uint32_t cur = 0;
	int bitpos = 0;
	int bytepos = 0;
	uint32_t mask = (1u << bits) - 1;
	for (int i = 0; i < n; i++) {
		while (bitpos < bits) {
			cur = (cur << 8) | packed[bytepos];
			bytepos++;
			bitpos += 8;
		}
		out[i] = (cur >> (bitpos - bits)) & mask;
		bitpos -= bits;
		cur &= (1u << bitpos) - 1;
	}
	return out;
}

int slab_getbits(const uint8_t *i, int isize, int bits, int pos) {
	int bo = (pos * bits) >> 3;
	int sh = (pos * bits) & 7;
	uint32_t w = (uint32_t)i[bo] << 8;
	if (bo + 1 < isize)
		w |= i[bo + 1];
	return (w >> (16 - sh - bits)) & ((1u << bits) - 1);
}

int slab_nz_count(const uint8_t *i, int isize, int bits, const uint8_t *p) {
	int cnt = 0;
	if (bits == 1) {
		for (int k = 0; k < isize; k++) {
			uint32_t b = i[k];
			for (int r = 0; r < 8; r++)
				if (p[(b >> (7 - r)) & 1] != 0)
					cnt++;
		}
	} else if (bits == 2) {
		for (int k = 0; k < isize; k++) {
			uint32_t b = i[k];
			for (int r = 0; r < 4; r++)
				if (p[(b >> (6 - 2 * r)) & 3] != 0)
					cnt++;
		}
	} else if (bits == 3) {
		int k = 0;
		int j = 0;
		while (j < S3) {
			uint32_t w = (uint32_t)i[k] << 16;
			if (k + 1 < isize)
				w |= (uint32_t)i[k + 1] << 8;
			if (k + 2 < isize)
				w |= i[k + 2];
			for (int r = 0; r < 8; r++)
				if (p[(w >> (21 - 3 * r)) & 7] != 0)
					cnt++;
			k += 3;
			j += 8;
		}
	} else if (bits == 4) {
		for (int k = 0; k < isize; k++) {
			uint32_t b = i[k];
			if (p[(b >> 4) & 15] != 0)
				cnt++;
			if (p[b & 15] != 0)
				cnt++;
		}
	} else {
		for (int j = 0; j < S3; j++)
			if (p[slab_getbits(i, isize, bits, j)] != 0)
				cnt++;
	}
	return cnt;
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
		int j = 0;
		for (int k = 0; k < isize; k++) {
			uint32_t b = i[k];
			out[j] = p[(b >> 4) & 15];
			out[j + 1] = p[b & 15];
			j += 2;
		}
	} else {
		for (int j = 0; j < S3; j++)
			out[j] = p[slab_getbits(i, isize, bits, j)];
	}
	return out;
}

PackedByteArray pba_from(const std::vector<uint8_t> &v) {
	PackedByteArray out;
	out.resize((int)v.size());
	if (!v.empty())
		std::memcpy(out.ptrw(), v.data(), v.size());
	return out;
}

// AC-0214: direct bit SET (the C++ twin of chunk_io.gd _slab_setbits — the
// slab-write hot op: write the bits-wide val at cell pos, MSB-first, 16-bit
// carry window exactly as the GDScript).
void slab_setbits_w(uint8_t *i, int isize, int bits, int pos, int val) {
	int bo = (pos * bits) >> 3;
	if (bo < 0 || bo >= isize)
		return;
	int sh = (pos * bits) & 7;
	uint32_t w = (uint32_t)i[bo] << 8;
	if (bo + 1 < isize)
		w |= i[bo + 1];
	uint32_t mask = (1u << bits) - 1;
	int sb = 16 - sh - bits;
	w = (w & ~(mask << sb)) | ((uint32_t)val << sb);
	i[bo] = (uint8_t)((w >> 8) & 255);
	if (bo + 1 < isize)
		i[bo + 1] = (uint8_t)(w & 255);
}

// AC-0214: single-cell read from a slab Dictionary (the C++ twin of
// chunk_io.gd _slab_cell — direct palette index op: n==1 uniform fill,
// n==0 raw byte, n>=2 palette[getbits]).
int slab_cell_of(const Dictionary &d, int pos) {
	int n = d.get("n", 0);
	if (n == 1) {
		PackedByteArray p = d.get("p", PackedByteArray());
		return p.size() > 0 ? (int)p[0] : -1;
	}
	if (n == 0) {
		PackedByteArray i = d.get("i", PackedByteArray());
		return pos < (int)i.size() ? (int)i[pos] : -1;
	}
	PackedByteArray p = d.get("p", PackedByteArray());
	PackedByteArray i = d.get("i", PackedByteArray());
	int b = d.get("b", 0);
	int idx = slab_getbits(i.ptr(), (int)i.size(), b, pos);
	return idx < (int)p.size() ? (int)p[idx] : -1;
}

// AC-0214: full 4096-cell value vector for a slab Dictionary (the C++ twin
// of chunk_io.gd _slab_flat: n==1 fill, n==0 raw copy, else palette unpack).
std::vector<uint8_t> slab_flat_of(const Dictionary &d) {
	int n = d.get("n", 0);
	if (n == 1) {
		PackedByteArray p = d.get("p", PackedByteArray());
		uint8_t v = p.size() > 0 ? p[0] : 0;
		return std::vector<uint8_t>(S3, v);
	}
	if (n == 0) {
		PackedByteArray i = d.get("i", PackedByteArray());
		return std::vector<uint8_t>(i.ptr(), i.ptr() + i.size());
	}
	PackedByteArray p = d.get("p", PackedByteArray());
	PackedByteArray i = d.get("i", PackedByteArray());
	int b = d.get("b", 0);
	return slab_unpack(i.ptr(), (int)i.size(), b, p.ptr());
}

std::vector<uint8_t> encode_section_impl(const uint8_t *arr, int sub, int top) {
	std::vector<uint8_t> out;
	std::vector<int> idxs;
	for (int s = 0; s < sub; s++) {
		bool present = true;
		if (top >= 0 && s > top / 16) {
			present = false;
		} else {
			int base0 = s * S3;
			bool any = false;
			for (int i = 0; i < S3; i++) {
				if (arr[base0 + i] != 0) {
					any = true;
					break;
				}
			}
			if (!any)
				present = false;
		}
		if (present)
			idxs.push_back(s);
	}
	out.push_back((uint8_t)idxs.size());
	for (int si : idxs) {
		out.push_back((uint8_t)(si & 255));
		out.push_back((uint8_t)((si >> 8) & 255));
	}
	int seen[256];
	for (int si2 : idxs) {
		for (int i = 0; i < 256; i++)
			seen[i] = -1;
		std::vector<uint8_t> order;
		int base = si2 * S3;
		for (int i = 0; i < S3; i++) {
			uint8_t v = arr[base + i];
			if (seen[v] < 0) {
				seen[v] = (int)order.size();
				order.push_back(v);
			}
		}
		std::sort(order.begin(), order.end());
		int n = (int)order.size();
		if (n <= 16) {
			int rank[256];
			for (int j = 0; j < n; j++)
				rank[order[j]] = j;
			std::vector<uint8_t> vals(S3);
			for (int i = 0; i < S3; i++)
				vals[i] = (uint8_t)rank[arr[base + i]];
			out.push_back((uint8_t)n);
			if (n == 1) {
				out.push_back(0);
				out.push_back(order[0]);
			} else {
				int bits = slab_bits_for(n);
				out.push_back((uint8_t)bits);
				out.insert(out.end(), order.begin(), order.end());
				std::vector<uint8_t> packed = bitpack(vals.data(), S3, bits);
				out.insert(out.end(), packed.begin(), packed.end());
			}
		} else {
			out.push_back(0);
			out.push_back(8);
			for (int i = 0; i < S3; i++)
				out.push_back(arr[base + i]);
		}
	}
	return out;
}

bool decode_section_impl(const uint8_t *blob, int bsize, int off, int sub, std::vector<uint8_t> &out_flat, int &out_off) {
	out_flat.assign((size_t)sub * S3, 0);
	out_off = 0;
	int o = off;
	if (o >= bsize)
		return false;
	int np = blob[o];
	o += 1;
	if (np > sub)
		return false;
	std::vector<int> idxs;
	for (int i = 0; i < np; i++) {
		if (o + 1 >= bsize)
			return false;
		int si = blob[o] | (blob[o + 1] << 8);
		o += 2;
		if (si < 0 || si >= sub || std::find(idxs.begin(), idxs.end(), si) != idxs.end())
			return false;
		idxs.push_back(si);
	}
	for (int i = 0; i < np; i++) {
		int si2 = idxs[i];
		if (o + 2 >= bsize)
			return false;
		int n = blob[o];
		o += 1;
		int bits = blob[o];
		o += 1;
		int base = si2 * S3;
		if (n == 0) {
			if (bits != 8 || o + S3 > bsize)
				return false;
			for (int j = 0; j < S3; j++)
				out_flat[base + j] = blob[o + j];
			o += S3;
		} else if (n == 1) {
			if (bits != 0 || o + 1 > bsize)
				return false;
			int fillv = blob[o];
			o += 1;
			for (int j = 0; j < S3; j++)
				out_flat[base + j] = (uint8_t)fillv;
		} else {
			if (n > 16 || bits != slab_bits_for(n) || o + n > bsize)
				return false;
			std::vector<uint8_t> order(n);
			for (int j = 0; j < n; j++) {
				order[j] = blob[o];
				o += 1;
			}
			int nbytes = (S3 * bits + 7) / 8;
			if (o + nbytes > bsize)
				return false;
			std::vector<uint8_t> idx = bitunpack(blob + o, bits, S3);
			for (int j = 0; j < S3; j++)
				out_flat[base + j] = order[idx[j]];
			o += nbytes;
		}
	}
	out_off = o;
	return true;
}

struct Slab {
	int n = 0;
	int b = 0;
	int nz = 0;
	std::vector<uint8_t> p;
	std::vector<uint8_t> i;
};

bool decode_slabs_impl(const uint8_t *blob, int bsize, int off, int sub, std::vector<Slab *> &out_slabs, int &out_off) {
	out_slabs.assign(sub, nullptr);
	out_off = 0;
	int o = off;
	if (o >= bsize)
		return false;
	int np = blob[o];
	o += 1;
	if (np > sub)
		return false;
	std::vector<int> idxs;
	for (int i = 0; i < np; i++) {
		if (o + 1 >= bsize)
			return false;
		int si = blob[o] | (blob[o + 1] << 8);
		o += 2;
		if (si < 0 || si >= sub || std::find(idxs.begin(), idxs.end(), si) != idxs.end())
			return false;
		idxs.push_back(si);
	}
	for (int i = 0; i < np; i++) {
		int si2 = idxs[i];
		if (o + 2 >= bsize)
			return false;
		int n = blob[o];
		o += 1;
		int bits = blob[o];
		o += 1;
		if (n == 0) {
			if (bits != 8 || o + S3 > bsize)
				return false;
			int nz = 0;
			for (int j = 0; j < S3; j++)
				if (blob[o + j] != 0)
					nz++;
			if (nz > 0) {
				Slab *s = new Slab();
				s->n = 0;
				s->b = 8;
				s->i.assign(blob + o, blob + o + S3);
				s->nz = nz;
				out_slabs[si2] = s;
			}
			o += S3;
		} else if (n == 1) {
			if (bits != 0 || o + 1 > bsize)
				return false;
			int fillv = blob[o];
			o += 1;
			if (fillv != 0) {
				Slab *s = new Slab();
				s->n = 1;
				s->b = 0;
				s->p.push_back((uint8_t)fillv);
				s->nz = S3;
				out_slabs[si2] = s;
			}
		} else {
			if (n > 16 || bits != slab_bits_for(n) || o + n > bsize)
				return false;
			Slab *s = new Slab();
			for (int j = 0; j < n; j++) {
				s->p.push_back(blob[o]);
				o += 1;
			}
			int nbytes = (S3 * bits + 7) / 8;
			if (o + nbytes > bsize) {
				delete s;
				return false;
			}
			s->i.assign(blob + o, blob + o + nbytes);
			s->n = n;
			s->b = bits;
			s->nz = slab_nz_count(s->i.data(), nbytes, bits, s->p.data());
			if (s->nz > 0)
				out_slabs[si2] = s;
			else
				delete s;
			o += nbytes;
		}
	}
	out_off = o;
	return true;
}

}

class ChunkIOPalette : public RefCounted {
	GDCLASS(ChunkIOPalette, RefCounted)

public:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("encode_section", "data", "sub", "top"), &ChunkIOPalette::encode_section, DEFVAL(-1));
		ClassDB::bind_method(D_METHOD("decode_section", "blob", "off", "sub"), &ChunkIOPalette::decode_section);
		ClassDB::bind_method(D_METHOD("decode_slabs", "blob", "off", "sub"), &ChunkIOPalette::decode_slabs);
		ClassDB::bind_method(D_METHOD("slab_flat", "slab"), &ChunkIOPalette::slab_flat);
		ClassDB::bind_method(D_METHOD("slabs_flat", "slabs"), &ChunkIOPalette::slabs_flat);
		ClassDB::bind_method(D_METHOD("slab_cell", "slab", "pos"), &ChunkIOPalette::slab_cell);
		ClassDB::bind_method(D_METHOD("slab_nz", "packed", "bits", "palette"), &ChunkIOPalette::slab_nz);
		// AC-0214: the remaining slab ops (the per-block GDScript palette
		// reads/writes moved to C++ — direct palette index ops, no
		// per-cell Variant work).
		ClassDB::bind_method(D_METHOD("palettize_flat", "arr", "nsl"), &ChunkIOPalette::palettize_flat);
		ClassDB::bind_method(D_METHOD("slab_set", "slabs", "si", "pos", "val"), &ChunkIOPalette::slab_set);
		ClassDB::bind_method(D_METHOD("slabs_top", "slabs"), &ChunkIOPalette::slabs_top);
		ClassDB::bind_method(D_METHOD("slab_row", "slabs", "y"), &ChunkIOPalette::slab_row);
		ClassDB::bind_method(D_METHOD("slab_copy", "slabs"), &ChunkIOPalette::slab_copy);
	}

	PackedByteArray encode_section(const PackedByteArray &p_data, int p_sub, int p_top) const {
		std::vector<uint8_t> out = encode_section_impl(p_data.ptr(), p_sub, p_top);
		return pba_from(out);
	}

	Dictionary decode_section(const PackedByteArray &p_blob, int p_off, int p_sub) const {
		Dictionary d;
		std::vector<uint8_t> flat;
		int off = 0;
		bool ok = decode_section_impl(p_blob.ptr(), (int)p_blob.size(), p_off, p_sub, flat, off);
		d["arr"] = pba_from(ok ? flat : std::vector<uint8_t>());
		d["off"] = ok ? off : 0;
		return d;
	}

	Dictionary decode_slabs(const PackedByteArray &p_blob, int p_off, int p_sub) const {
		Dictionary d;
		std::vector<Slab *> slabs;
		int off = 0;
		bool ok = decode_slabs_impl(p_blob.ptr(), (int)p_blob.size(), p_off, p_sub, slabs, off);
		Array arr;
		arr.resize(p_sub);
		for (int i = 0; i < p_sub; i++) {
			Slab *s = slabs[i];
			if (s == nullptr) {
				arr[i] = Variant();
				continue;
			}
			Dictionary sd;
			sd["n"] = s->n;
			sd["b"] = s->b;
			sd["p"] = pba_from(s->p);
			sd["i"] = pba_from(s->i);
			sd["nz"] = s->nz;
			arr[i] = sd;
			delete s;
		}
		d["slabs"] = arr;
		d["off"] = ok ? off : 0;
		return d;
	}

	PackedByteArray slab_flat(const Variant &p_slab) const {
		if (p_slab.get_type() != Variant::DICTIONARY)
			return PackedByteArray();
		Dictionary d = p_slab;
		int n = d.get("n", 0);
		if (n == 1) {
			PackedByteArray p = d.get("p", PackedByteArray());
			std::vector<uint8_t> out(S3, 0);
			uint8_t v = p.size() > 0 ? p[0] : 0;
			for (int i = 0; i < S3; i++)
				out[i] = v;
			return pba_from(out);
		}
		if (n == 0) {
			PackedByteArray i = d.get("i", PackedByteArray());
			std::vector<uint8_t> out(i.size());
			if (i.size() > 0)
				std::memcpy(out.data(), i.ptr(), i.size());
			return pba_from(out);
		}
		PackedByteArray p = d.get("p", PackedByteArray());
		PackedByteArray i = d.get("i", PackedByteArray());
		int b = d.get("b", 0);
		std::vector<uint8_t> out = slab_unpack(i.ptr(), (int)i.size(), b, p.ptr());
		return pba_from(out);
	}

	PackedByteArray slabs_flat(const Array &p_slabs) const {
		std::vector<uint8_t> out((size_t)p_slabs.size() * S3, 0);
		for (int k = 0; k < p_slabs.size(); k++) {
			Variant v = p_slabs[k];
			if (v.get_type() != Variant::DICTIONARY)
				continue;
			Dictionary d = v;
			int n = d.get("n", 0);
			int base = k * S3;
			if (n == 1) {
				PackedByteArray p = d.get("p", PackedByteArray());
				uint8_t val = p.size() > 0 ? p[0] : 0;
				for (int j = 0; j < S3; j++)
					out[base + j] = val;
			} else if (n == 0) {
				PackedByteArray i = d.get("i", PackedByteArray());
				int c = (int)i.size() < S3 ? (int)i.size() : S3;
				if (c > 0)
					std::memcpy(out.data() + base, i.ptr(), c);
			} else {
				PackedByteArray p = d.get("p", PackedByteArray());
				PackedByteArray i = d.get("i", PackedByteArray());
				int b = d.get("b", 0);
				std::vector<uint8_t> flat = slab_unpack(i.ptr(), (int)i.size(), b, p.ptr());
				for (int j = 0; j < S3; j++)
					out[base + j] = flat[j];
			}
		}
		return pba_from(out);
	}

	int slab_cell(const Variant &p_slab, int p_pos) const {
		if (p_slab.get_type() != Variant::DICTIONARY || p_pos < 0 || p_pos >= S3)
			return -1;
		Dictionary d = p_slab;
		int n = d.get("n", 0);
		if (n == 1) {
			PackedByteArray p = d.get("p", PackedByteArray());
			return p.size() > 0 ? (int)p[0] : -1;
		}
		if (n == 0) {
			PackedByteArray i = d.get("i", PackedByteArray());
			return p_pos < (int)i.size() ? (int)i[p_pos] : -1;
		}
		PackedByteArray p = d.get("p", PackedByteArray());
		PackedByteArray i = d.get("i", PackedByteArray());
		int b = d.get("b", 0);
		int idx = slab_getbits(i.ptr(), (int)i.size(), b, p_pos);
		return idx < (int)p.size() ? (int)p[idx] : -1;
	}

	// AC-0214: flat -> paletted slab array (the C++ port of ChunkIO
	// palettize_flat — the single flat->paletted conversion point every data
	// landing goes through: per-slab LUT + ONE batch bitpack, no per-cell
	// Variant hashing). Same dict shape as the wire form: null | {n,b,p,i,nz}
	// (n==1 uniform, n>=2 paletted with sorted palette, n==0 raw >16 ids).
	// Byte-for-byte the GDScript output (slabops arm A/B).
	Array palettize_flat(const PackedByteArray &p_arr, int p_nsl) const {
		int n = (int)p_arr.size() / S3;
		Array out;
		out.resize(p_nsl > n ? p_nsl : n);
		int seen[256];
		std::vector<uint8_t> order;
		int remap[256];
		std::vector<uint8_t> vals(S3);
		for (int si = 0; si < n; si++) {
			int base = si * S3;
			for (int i = 0; i < 256; i++)
				seen[i] = -1;
			order.clear();
			int nz = 0;
			for (int i = 0; i < S3; i++) {
				uint8_t v = p_arr[base + i];
				if (seen[v] < 0) {
					seen[v] = (int)order.size();
					order.push_back(v);
				}
				if (v != 0)
					nz++;
			}
			if (nz == 0)
				continue; // stays null
			int nn = (int)order.size();
			Dictionary sd;
			if (nn == 1) {
				sd["n"] = 1;
				sd["b"] = 0;
				std::vector<uint8_t> pv;
				pv.push_back(order[0]);
				sd["p"] = pba_from(pv);
				sd["i"] = PackedByteArray();
				sd["nz"] = nz;
			} else if (nn <= 16) {
				std::vector<uint8_t> p(order);
				std::sort(p.begin(), p.end());
				for (int i = 0; i < 256; i++)
					remap[i] = -1;
				for (int j = 0; j < (int)p.size(); j++)
					remap[p[j]] = j;
				for (int i = 0; i < S3; i++)
					vals[i] = (uint8_t)remap[p_arr[base + i]];
				int bits = slab_bits_for((int)p.size());
				sd["n"] = (int)p.size();
				sd["b"] = bits;
				sd["p"] = pba_from(p);
				sd["i"] = pba_from(bitpack(vals.data(), S3, bits));
				sd["nz"] = nz;
			} else {
				std::vector<uint8_t> raw(p_arr.ptr() + base, p_arr.ptr() + base + S3);
				sd["n"] = 0;
				sd["b"] = 8;
				sd["p"] = PackedByteArray();
				sd["i"] = pba_from(raw);
				sd["nz"] = nz;
			}
			out[si] = sd;
		}
		return out;
	}

	// AC-0214: single-slab write with palette growth (the C++ port of the
	// GDScript Chunk._slab_write — the per-block edit op). Mutates the slab
	// array IN PLACE (the passed Array shares its storage with GDScript).
	// Invariant on return: null = all air; otherwise nz>0, n<=16 (or raw
	// n==0 on palette overflow), i consistent with b. Covers every branch:
	// null->slab, uniform split, bit widening + repack, raw fallback,
	// back-to-air nullification. Byte-for-byte the GDScript output (the
	// slabops arm A/Bs a seeded 400-write sequence per column).
	// AC-0214: one-cell write (the C++ port of chunk.gd _slab_write).
	// IMPORTANT (empirically verified, cowprobe): in this godot-cpp build a
	// PackedByteArray is an opaque engine-handle wrapper — raw ptrw() writes
	// on a handle shared with a Dictionary do NOT propagate back to the dict
	// entry, but FRESH byte arrays (pba_from) assigned into a fresh Dictionary
	// do. So every branch builds fresh std::vector<uint8_t> payloads, converts
	// with pba_from, and publishes a fresh Dictionary via slabs[p_si] = nd.
	// The branches mirror the GDScript reference exactly.
	void slab_set(const Array &p_slabs, int p_si, int p_pos, int p_val) const {
		if (p_si < 0 || p_si >= (int)p_slabs.size() || p_pos < 0 || p_pos >= S3 || p_val < 0 || p_val > 255)
			return;
		Array slabs = p_slabs; // shared ref — element assignment reaches GDScript
		Variant vs = slabs[p_si];
		if (vs.get_type() != Variant::DICTIONARY) {
			if (p_val == 0)
				return;
			Dictionary nd;
			std::vector<uint8_t> pv;
			pv.push_back(0);
			pv.push_back((uint8_t)p_val);
			std::vector<uint8_t> idx(S3 / 8, 0);
			slab_setbits_w(idx.data(), (int)idx.size(), 1, p_pos, 1);
			nd["n"] = 2;
			nd["b"] = 1;
			nd["p"] = pba_from(pv);
			nd["i"] = pba_from(idx);
			nd["nz"] = 1;
			slabs[p_si] = nd;
			return;
		}
		Dictionary d = vs;
		int cur = slab_cell_of(d, p_pos);
		if (cur == p_val)
			return;
		int n = d.get("n", 0);
		// raw slab: i holds 4096 raw value bytes
		if (n == 0) {
			PackedByteArray ri = d.get("i", PackedByteArray());
			int isz = (int)ri.size();
			std::vector<uint8_t> rv(isz);
			if (isz > 0)
				std::memcpy(rv.data(), ri.ptr(), isz);
			if (p_pos < isz)
				rv[p_pos] = (uint8_t)p_val;
			int rz = d.get("nz", 0);
			if (cur != 0)
				rz--;
			if (p_val != 0)
				rz++;
			if (rz == 0)
				slabs[p_si] = Variant();
			else {
				Dictionary nd;
				nd["n"] = 0;
				nd["b"] = 8;
				nd["p"] = PackedByteArray();
				nd["i"] = pba_from(rv);
				nd["nz"] = rz;
				slabs[p_si] = nd;
			}
			return;
		}
		// paletted slab: work on local copies of palette + bitstream
		PackedByteArray p2 = d.get("p", PackedByteArray());
		int psz = (int)p2.size();
		std::vector<uint8_t> pv(psz);
		if (psz > 0)
			std::memcpy(pv.data(), p2.ptr(), psz);
		int pi = -1;
		for (int k = 0; k < n && k < psz; k++) {
			if (pv[k] == (uint8_t)p_val) {
				pi = k;
				break;
			}
		}
		int b = d.get("b", 0);
		PackedByteArray isrc = d.get("i", PackedByteArray());
		int isz = (int)isrc.size();
		std::vector<uint8_t> ibytes(isz);
		if (isz > 0)
			std::memcpy(ibytes.data(), isrc.ptr(), isz);
		if (pi < 0) {
			if (n == 1) {
				int v0 = psz > 0 ? (int)pv[0] : 0;
				std::vector<uint8_t> np;
				np.push_back((uint8_t)v0);
				np.push_back((uint8_t)p_val);
				std::vector<uint8_t> idx2(S3 / 8, 0);
				slab_setbits_w(idx2.data(), (int)idx2.size(), 1, p_pos, 1);
				int nz2 = 0;
				if (v0 != 0)
					nz2 = S3 - 1;
				if (p_val != 0)
					nz2 += 1;
				if (nz2 == 0)
					slabs[p_si] = Variant();
				else {
					Dictionary nd;
					nd["n"] = 2;
					nd["b"] = 1;
					nd["p"] = pba_from(np);
					nd["i"] = pba_from(idx2);
					nd["nz"] = nz2;
					slabs[p_si] = nd;
				}
				return;
			}
			if (n >= 16) {
				std::vector<uint8_t> raw = slab_flat_of(d);
				raw[p_pos] = (uint8_t)p_val;
				int nz3 = 0;
				for (int i = 0; i < S3; i++) {
					if (raw[i] != 0)
						nz3++;
				}
				if (nz3 == 0)
					slabs[p_si] = Variant();
				else {
					Dictionary nd;
					nd["n"] = 0;
					nd["b"] = 8;
					nd["p"] = PackedByteArray();
					nd["i"] = pba_from(raw);
					nd["nz"] = nz3;
					slabs[p_si] = nd;
				}
				return;
			}
			// grow the palette
			pv.push_back((uint8_t)p_val);
			pi = n;
			int nn = n + 1;
			int nb = slab_bits_for(nn);
			if (nb > b) {
				int inv[256];
				for (int i = 0; i < 256; i++)
					inv[i] = -1;
				for (int kk = 0; kk < n; kk++)
					inv[pv[kk]] = kk;
				std::vector<uint8_t> flatv = slab_flat_of(d);
				std::vector<uint8_t> nidx((S3 * nb + 7) / 8, 0);
				for (int pos2 = 0; pos2 < S3; pos2++)
					slab_setbits_w(nidx.data(), (int)nidx.size(), nb, pos2, inv[flatv[pos2]]);
				ibytes = std::move(nidx);
			}
			b = nb;
			n = nn;
		}
		// final: set this cell's bits (width b), recount nz, publish fresh dict
		slab_setbits_w(ibytes.data(), (int)ibytes.size(), b, p_pos, pi);
		int nz4 = d.get("nz", 0);
		if (cur != 0)
			nz4--;
		if (p_val != 0)
			nz4++;
		if (nz4 == 0)
			slabs[p_si] = Variant();
		else {
			Dictionary nd;
			nd["n"] = n;
			nd["b"] = b;
			nd["p"] = pba_from(pv);
			nd["i"] = pba_from(ibytes);
			nd["nz"] = nz4;
			slabs[p_si] = nd;
		}
	}

	// AC-0214: the column top (the C++ port of Chunk.update_top — max y
	// holding a non-air cell, -1 if none). Direct palette index ops, no
	// flat expansion: the first non-null slab from the top is scanned row 15
	// down (a non-null slab always has nz>0, so the first non-null slab
	// yields the top — the GDScript behavior).
	int slabs_top(const Array &p_slabs) const {
		for (int si = (int)p_slabs.size() - 1; si >= 0; si--) {
			Variant v = p_slabs[si];
			if (v.get_type() != Variant::DICTIONARY)
				continue;
			Dictionary d = v;
			int n = d.get("n", 0);
			int cy = -1;
			if (n == 1) {
				PackedByteArray p = d.get("p", PackedByteArray());
				if (p.size() > 0 && p[0] != 0)
					cy = 15;
			} else if (n == 0) {
				PackedByteArray i = d.get("i", PackedByteArray());
				for (int c = 15; c >= 0 && cy < 0; c--) {
					int row = c << 8;
					for (int ix = 0; ix < 256; ix++) {
						if (row + ix < (int)i.size() && i[row + ix] != 0) {
							cy = c;
							break;
						}
					}
				}
			} else {
				PackedByteArray p = d.get("p", PackedByteArray());
				PackedByteArray i = d.get("i", PackedByteArray());
				int b = d.get("b", 0);
				bool pnz[16] = {false};
				for (int k = 0; k < (int)p.size(); k++)
					pnz[k] = (int)p[k] != 0;
				for (int c = 15; c >= 0 && cy < 0; c--) {
					int row = c << 8;
					for (int ix = 0; ix < 256; ix++) {
						int idx = slab_getbits(i.ptr(), (int)i.size(), b, row + ix);
						if (idx < (int)p.size() && pnz[idx]) {
							cy = c;
							break;
						}
					}
				}
			}
			if (cy >= 0)
				return si * 16 + cy;
		}
		return -1;
	}

	// AC-0214: one 256-cell row (the C++ port of Chunk._slabs_row — the
	// (y<<8)|(lz<<4)|lx row within slab y>>4; null slab = zero row, the
	// GDScript parity).
	PackedByteArray slab_row(const Array &p_slabs, int p_y) const {
		std::vector<uint8_t> out(256, 0);
		int si = p_y >> 4;
		if (si >= 0 && si < (int)p_slabs.size()) {
			Variant v = p_slabs[si];
			if (v.get_type() == Variant::DICTIONARY) {
				Dictionary d = v;
				int n = d.get("n", 0);
				int base = (p_y & 15) << 8;
				if (n == 1) {
					PackedByteArray p = d.get("p", PackedByteArray());
					uint8_t val = p.size() > 0 ? p[0] : 0;
					for (int ix = 0; ix < 256; ix++)
						out[ix] = val;
				} else if (n == 0) {
					PackedByteArray i = d.get("i", PackedByteArray());
					for (int ix = 0; ix < 256; ix++) {
						if (base + ix < (int)i.size())
							out[ix] = i[base + ix];
					}
				} else {
					PackedByteArray p = d.get("p", PackedByteArray());
					PackedByteArray i = d.get("i", PackedByteArray());
					int b = d.get("b", 0);
					for (int ix = 0; ix < 256; ix++) {
						int idx = slab_getbits(i.ptr(), (int)i.size(), b, base + ix);
						out[ix] = (uint8_t)(idx < (int)p.size() ? (int)p[idx] : 0);
					}
				}
			}
		}
		return pba_from(out);
	}

	// AC-0214: deep copy of a paletted slab array (the C++ port of
	// ChunkIO._slabs_deepcopy — the save-queue value copy; p/i are TRUE byte
	// copies (COW isolation from the live chunk), nulls kept, the
	// {n,b,p,i,nz} shape unchanged).
	Array slab_copy(const Array &p_slabs) const {
		Array out;
		out.resize(p_slabs.size());
		for (int k = 0; k < (int)p_slabs.size(); k++) {
			Variant v = p_slabs[k];
			if (v.get_type() != Variant::DICTIONARY) {
				out[k] = v;
				continue;
			}
			Dictionary d = v;
			PackedByteArray sp = d.get("p", PackedByteArray());
			PackedByteArray cp;
			cp.resize(sp.size());
			if (sp.size() > 0)
				std::memcpy(cp.ptrw(), sp.ptr(), sp.size());
			PackedByteArray si = d.get("i", PackedByteArray());
			PackedByteArray ci;
			ci.resize(si.size());
			if (si.size() > 0)
				std::memcpy(ci.ptrw(), si.ptr(), si.size());
			Dictionary o;
			o["n"] = (int)d.get("n", 0);
			o["b"] = (int)d.get("b", 0);
			o["p"] = cp;
			o["i"] = ci;
			o["nz"] = (int)d.get("nz", 0);
			out[k] = o;
		}
		return out;
	}

	int slab_nz(const PackedByteArray &p_packed, int p_bits, const PackedByteArray &p_palette) const {
		if (p_packed.size() == 0 || p_palette.size() == 0)
			return 0;
		return slab_nz_count(p_packed.ptr(), (int)p_packed.size(), p_bits, p_palette.ptr());
	}
};

void initialize_chunkio_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE)
		return;
	GDREGISTER_CLASS(ChunkIOPalette);
	awegen::register_classes(); // AC-0188: AweGen (coarse 3D density gen)
	awelight::register_classes(); // AC-0189: AweLighting (pull kernel + flood)
	awemesh::register_classes(); // AC-0190: AweMesh (build_accs + greedy emit)
	awestrips::register_classes(); // AC-0207: AweStrips (strips + face compute)
}

void uninitialize_chunkio_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE)
		return;
}

extern "C" {
GDExtensionBool GDE_EXPORT chunkio_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address, GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_chunkio_module);
	init_obj.register_terminator(uninitialize_chunkio_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}
