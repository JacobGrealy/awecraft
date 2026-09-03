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
