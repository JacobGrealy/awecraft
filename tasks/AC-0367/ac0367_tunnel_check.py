#!/usr/bin/env python3
"""AC-0367 piece A — the INDEPENDENT python port of the vanilla tunnel noises.

Written from the SPEC, not transcribed from the C++:
  * base kernel (hash2i/hash3i/fade/vnoise3/vn3) — the project's AweNoise
    contract (godot/core/noise.gd op order, f64, i32-wrapped hashes);
  * the four dense sources — the 1.21.4 density functions
    (data/minecraft/worldgen/density_function/overworld/caves/{
    spaghetti_2d, spaghetti_roughness_function, noodle}.json + the
    spaghetti part of caves/entrances.json) with the noise instances from
    worldgen/noise/*.json (mcmeta 1.21.4), the weird_scaled_sampler
    semantics (v = input(pos); d = mapper(v); return d * |noise(pos/d)|)
    and the two RarityValueMappers — verified against the decompiled
    official 1.21.4 client jar; caches (interpolated / cache_once) are
    value-identity in the 1.21.4 dense evaluation.
  * conventions — the project's centered noise value 2*(vn3-0.5) (the
    vanilla O(1) units, AC-0347 P2), per-instance seed slots +337..+350,
    and the +64 world shift on the y-structure (gradient -64..320 -> 0..384,
    noodle band [-60,321) -> [4,385)), NOT on the noise coordinates.

Check: the genprobe arm (AWECRAFT_LOGIC=genprobe) prints the C++ values at
a fixed 208-point grid (res["vntun"]); this script recomputes every value
from the spec and requires f64 EXACT equality — the third leg of the
three-way lockstep (GDScript == C++ in genprobe; python == C++ here).
Also runs a larger self-sweep reporting range/branch-coverage per source.

Usage:
    python3 tasks/AC-0367/ac0367_tunnel_check.py <genprobe-log>
Exit 0 + "PASS" iff all 720 cross-check values are f64-exact.
"""
import math
import struct
import sys

M32 = 0xFFFFFFFF


def bits(f):
    # exact IEEE-754 bit pattern of a python f64 (the comparison unit).
    return struct.unpack("<Q", struct.pack("<d", f))[0]

# ---------------------------------------------------------------------------
# Base kernel — the AweNoise contract (f64; hashes i32-wrapped).
# ---------------------------------------------------------------------------

def hash2i(x, z, s):
    h = (s ^ (x * 374761393) ^ (z * 668265263)) & M32
    h = ((h ^ (h >> 13)) * 1274126177) & M32
    h = h ^ (h >> 16)
    return h / 4294967296.0


def hash3i(x, y, z, s):
    h = (s ^ (x * 374761393) ^ (y * 2246822519) ^ (z * 668265263)) & M32
    h = ((h ^ (h >> 13)) * 1274126177) & M32
    h = h ^ (h >> 16)
    return h / 4294967296.0


def _fade(t):
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)


def _lerp(a, b, t):
    # Godot lerpf: from + (to - from) * weight
    return a + (b - a) * t


def vnoise3(x, y, z, s):
    xf = math.floor(x)
    yf = math.floor(y)
    zf = math.floor(z)
    xi, yi, zi = int(xf), int(yf), int(zf)
    u = _fade(x - xf)
    v = _fade(y - yf)
    w = _fade(z - zf)
    x00 = _lerp(hash3i(xi, yi, zi, s), hash3i(xi + 1, yi, zi, s), u)
    x10 = _lerp(hash3i(xi, yi + 1, zi, s), hash3i(xi + 1, yi + 1, zi, s), u)
    x01 = _lerp(hash3i(xi, yi, zi + 1, s), hash3i(xi + 1, yi, zi + 1, s), u)
    x11 = _lerp(hash3i(xi, yi + 1, zi + 1, s), hash3i(xi + 1, yi + 1, zi + 1, s), u)
    return _lerp(_lerp(x00, x10, v), _lerp(x01, x11, v), w)


def vn3(x, y, z, s, first_oct, amps):
    # the vanilla NormalNoise octave machine (2^firstOct via ldexp — exact).
    f = math.ldexp(1.0, first_oct)
    a = 0.0
    tot = 0.0
    for i, amp in enumerate(amps):
        if amp != 0.0:
            a += amp * vnoise3(x * f, y * f, z * f, s + i * 101)
        tot += (-amp) if amp < 0.0 else amp
        f *= 2.0
    return a / tot


def n1(x, y, z, s, slot, first_oct, sx=1.0, sy=1.0):
    # ONE single-octave instance {firstOctave, amps [1.0]}: vn3 with one
    # amplitude divides by 1.0 (exact) — the centered vanilla value.
    return 2.0 * (vn3(x * sx, y * sy, z * sx, s + slot, first_oct, [1.0]) - 0.5)


# ---------------------------------------------------------------------------
# The rarity mappers (1.21.4 decompiled: eda.a::a / eda.a::b statics).
# ---------------------------------------------------------------------------

def rarity_type1(v):
    if v < -0.5:
        return 0.75
    if v < 0.0:
        return 1.0
    if v < 0.5:
        return 1.5
    return 2.0


def rarity_type2(v):
    if v < -0.75:
        return 0.5
    if v < -0.5:
        return 0.75
    if v < 0.5:
        return 1.0
    if v < 0.75:
        return 2.0
    return 3.0


# ---------------------------------------------------------------------------
# The four dense sources (the 1.21.4 caves/*.json expressions as-is).
# ---------------------------------------------------------------------------

def spag2d(x, y, z, s):
    # cave spaghetti_2d.json:
    # clamp(max( add(weird_scaled_sampler(input=noise{spaghetti_2d_modulator,
    #   2.0, 1.0}, noise=spaghetti_2d, mapper=type_2),
    #   mul(0.083, spaghetti_2d_thickness_modulator)),
    #   cube(add(abs(add(0.0, mul(8.0, noise{spaghetti_2d_elevation, 1.0,
    #   0.0})), y_clamped_gradient(8.0, -64 -> -40.0, 320))),
    #   spaghetti_2d_thickness_modulator))), -1, 1)
    # where spaghetti_2d_thickness_modulator = cache_once(add(-0.95,
    # mul(-0.35, noise{spaghetti_2d_thickness, 2.0, 1.0})) (cache = identity).
    m = n1(x, y, z, s, 338, -11, 2.0, 1.0)          # spaghetti_2d_modulator
    d = rarity_type2(m)
    wv = d * abs(n1(x / d, y / d, z / d, s, 337, -7))
    nt = n1(x, y, z, s, 339, -11, 2.0, 1.0)         # spaghetti_2d_thickness
    tm = -0.95 + (-0.35000000000000003 * nt)
    ev = n1(x, y, z, s, 340, -8, 1.0, 0.0)          # spaghetti_2d_elevation
    tg = (y - 0.0) / (384.0 - 0.0)                  # +64-shifted -64..320
    if tg < 0.0:
        tg = 0.0
    if tg > 1.0:
        tg = 1.0
    g = 8.0 + (-40.0 - 8.0) * tg
    e = abs((0.0 + 8.0 * ev) + g)
    c = e + tm
    cc = c * c * c
    a = wv + (0.083 * tm)
    r = a if a > cc else cc
    if r < -1.0:
        r = -1.0
    if r > 1.0:
        r = 1.0
    return r


def spag3d(x, y, z, s):
    # the spaghetti part of caves/entrances.json (replaces AweCraft's f_gate):
    # clamp( add( max(weird(spaghetti_3d_1, type_1), weird(spaghetti_3d_2,
    #   type_1)), add(-0.0765, mul(-0.0115, noise{spaghetti_3d_thickness,
    #   1.0, 1.0})) ), -1, 1) — both samplers share the ONE cache_once'd
    # spaghetti_3d_rarity noise (xz 2.0 / y 1.0).
    r = n1(x, y, z, s, 341, -11, 2.0, 1.0)          # spaghetti_3d_rarity
    d1 = rarity_type1(r)
    w1 = d1 * abs(n1(x / d1, y / d1, z / d1, s, 342, -7))
    d2 = rarity_type1(r)
    w2 = d2 * abs(n1(x / d2, y / d2, z / d2, s, 343, -7))
    nt = n1(x, y, z, s, 344, -8)                    # spaghetti_3d_thickness
    # 0.011499999999999996 as the EXACT division mantissa / 2^59 (the
    # correctly-rounded double of the 1.21.4 JSON text; all three lanes
    # spell it identically because GDScript's literal parser cannot round
    # that decimal — see the AC-0367 BIT-EXACT NOTE in gen.cpp).
    c2 = -6629298651489368.0 / 576460752303423488.0
    th = -0.0765 + (c2 * nt)
    a = (w1 if w1 > w2 else w2) + th
    if a < -1.0:
        a = -1.0
    if a > 1.0:
        a = 1.0
    return a


def spagrough(x, y, z, s):
    # cave spaghetti_roughness_function.json:
    # cache_once(mul(add(-0.05, mul(-0.05, noise{spaghetti_roughness_modulator,
    #   1.0, 1.0})), add(-0.4, abs(noise{spaghetti_roughness, 1.0, 1.0}))))
    rm = n1(x, y, z, s, 346, -8)                    # roughness_modulator
    rs = n1(x, y, z, s, 345, -5)                    # spaghetti_roughness
    a = -0.05 + (-0.05 * rm)
    b = -0.4 + abs(rs)
    return a * b


def noodle(x, y, z, s):
    # cave noodle.json: range_choice(input = interpolated(range_choice(
    #   input=y, min=-60, max=321, in=noise{noodle,1,1}, out=-1)),
    #   min=-1e6, max=0, in=64, out=add(interpolated(range_choice(y, -60,
    #   321, in=add(-0.075, mul(-0.025, noise{noodle_thickness,1,1})), out=0)),
    #   mul(1.5, max(abs(interpolated(range_choice(y,-60,321,
    #   in=noise{noodle_ridge_a, 8/3, 8/3}, out=0))), abs(... ridge_b ...))))))
    # y-band +64-shifted: vanilla [-60, 321) -> our [4, 385).
    inb = (y >= 4.0) and (y < 385.0)
    nv = n1(x, y, z, s, 347, -8) if inb else -1.0
    if nv >= -1000000.0 and nv < 0.0:
        return 64.0
    nt = n1(x, y, z, s, 348, -8)                    # noodle_thickness
    ra = n1(x, y, z, s, 349, -7, 8.0 / 3.0, 8.0 / 3.0)   # noodle_ridge_a
    rb = n1(x, y, z, s, 350, -7, 8.0 / 3.0, 8.0 / 3.0)   # noodle_ridge_b
    ot = (-0.07500000000000001 + (-0.025 * nt)) if inb else 0.0
    va = abs(ra) if inb else 0.0
    vb = abs(rb) if inb else 0.0
    return ot + (1.5 * (va if va > vb else vb))


FUNCS = {
    "spag2d": spag2d,
    "spag3d": spag3d,
    "spagrough": spagrough,
    "noodle": noodle,
}

# The fixed grid the genprobe arm prints (208 points per function):
#   180 small-domain: seeds {44, -17} x y {3,4,10,64,128,256,320,384,385,386}
#       x {-128,0,128} z {-128,0,128}  (straddles the noodle band boundary)
#   + 28 wide-domain: seeds {44, -17} x y {32, 288} x the (x,z) pairs below —
#       the rarity field is nearly constant over ±128 (firstOctave -11), so
#       these ±8192 points exist to exercise EVERY mapper bucket (t1 0..3,
#       t2 0..4) in the bit-exact cross-lane check.
_WIDE_XZ = [(-8192.0, -8192.0), (-8192.0, 0.0), (-8192.0, 8192.0),
            (-4096.0, 0.0), (-1024.0, 8192.0), (1024.0, -8192.0),
            (4096.0, 8192.0)]
POINTS = (
    [(x2, y2, z2, s2)
     for s2 in (44, -17)
     for y2 in (3.0, 4.0, 10.0, 64.0, 128.0, 256.0, 320.0, 384.0, 385.0, 386.0)
     for x2 in (-128.0, 0.0, 128.0)
     for z2 in (-128.0, 0.0, 128.0)]
    + [(x2, y2, z2, s2)
       for s2 in (44, -17)
       for y2 in (32.0, 288.0)
       for (x2, z2) in _WIDE_XZ]
)
assert len(POINTS) == 208


def main(log_path):
    import json
    import re

    text = open(log_path).read()
    m = re.search(r"^RESULT (.*)$", text, re.M)
    if not m:
        print("FAIL: no RESULT line in the genprobe log")
        return 1
    res = json.loads(m.group(1))
    vntun = res.get("vntun")
    if not vntun or res.get("vntun_points") != 208:
        print("FAIL: the genprobe log has no vntun block")
        return 1
    if not (res.get("ok") and res.get("exact") == res.get("n")):
        print("FAIL: the genprobe itself is not all-exact "
              "(exact %s != n %s)" % (res.get("exact"), res.get("n")))
        return 1

    bad = 0
    for name in ("spag2d", "spag3d", "spagrough", "noodle"):
        vals = vntun[name]
        if len(vals) != 208:
            print("FAIL: %s has %d values, want 208" % (name, len(vals)))
            return 1
        for i, tv in enumerate(vals):
            x, y, z, s = POINTS[i]
            got = FUNCS[name](x, y, z, s)
            want_bits = int(tv) & 0xFFFFFFFFFFFFFFFF  # the C++ value's bits
            if bits(got) != want_bits:
                bad += 1
                if bad <= 5:
                    want = struct.unpack("<d", struct.pack("<Q", want_bits))[0]
                    print("MISMATCH %s #%d (%r): python %r != cpp %r"
                          % (name, i, (x, y, z, s), repr(got), repr(want)))
    total = 4 * 208
    print("third-lane cross-check: %d/%d f64-exact (python spec port vs C++)"
          % (total - bad, total))

    # Larger self-sweep (spec port against itself — range + branch coverage,
    # the evidence the fixed grid straddles the interesting regions).
    sweep = {}
    for name, fn in FUNCS.items():
        vals = []
        for x in range(-64, 64, 4):
            for y in range(0, 384, 4):
                for z in range(-64, 64, 4):
                    vals.append(fn(float(x), float(y), float(z), 44))
        sweep[name] = {
            "n": len(vals),
            "min": min(vals),
            "max": max(vals),
            "mean": sum(vals) / len(vals),
        }
    # branch coverage on the sweep (mapper buckets + noodle band/branch)
    cov = {"t1": [0, 0, 0, 0], "t2": [0, 0, 0, 0, 0],
           "noodle64": 0, "noodle_out": 0, "spag2d_clamp": 0}
    for x in range(-64, 64, 8):
        for y in range(0, 384, 8):
            for z in range(-64, 64, 8):
                xf, yf, zf = float(x), float(y), float(z)
                m = n1(xf, yf, zf, 44, 338, -11, 2.0, 1.0)
                if m < -0.75:
                    cov["t2"][0] += 1
                elif m < -0.5:
                    cov["t2"][1] += 1
                elif m < 0.5:
                    cov["t2"][2] += 1
                elif m < 0.75:
                    cov["t2"][3] += 1
                else:
                    cov["t2"][4] += 1
                r = n1(xf, yf, zf, 44, 341, -11, 2.0, 1.0)
                if r < -0.5:
                    cov["t1"][0] += 1
                elif r < 0.0:
                    cov["t1"][1] += 1
                elif r < 0.5:
                    cov["t1"][2] += 1
                else:
                    cov["t1"][3] += 1
                if noodle(xf, yf, zf, 44) == 64.0:
                    cov["noodle64"] += 1
                else:
                    cov["noodle_out"] += 1
                if spag2d(xf, yf, zf, 44) in (-1.0, 1.0):
                    cov["spag2d_clamp"] += 1
    print("sweep (32x96x32 grid @ seed 44): %s" % json.dumps(sweep))
    print("branch coverage (8-step subsweep): %s" % json.dumps(cov))
    if bad:
        print("FAIL")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else ".scratch/AC-0367-gates/genprobe.log"))
