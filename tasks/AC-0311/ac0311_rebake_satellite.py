#!/usr/bin/env python3
# AC-0311 RE-BAKE (re-ship of the AC-0310 bake) — the per-face satellite bake (numpy).
#
# Adapted MINIMALLY from tasks/AC-0310/ac0310_bake_satellite.py (the P2
# index/gradient fixes and the permanent variance guard are carried
# unchanged). Changes vs the AC-0310 script — all paths/metadata only:
#   * DUMP    -> .scratch/AC-0311/far_dump.bin (magic "AC0311F1"; produced
#     by .scratch/AC-0311/ac0311_far_dump.gd from the POST-PORT world:
#     one seed, (face, R) threaded, the per-face seed salt dropped —
#     the AC-0311 sphere-domain port changed the far generation lane,
#     so the shipped seed-44 textures are pre-port and re-baked).
#   * OUTDIR  -> godot/assets/satellite/ (the SHIPPED location — this is
#     a re-ship, the assets the game loads become the new ones).
#   * STATS   -> tasks/AC-0311/ac0311_rebake_stats.json.
#   * FCC_JSON-> tasks/AC-0310/ac0310_fcc_probe.json (reused: the fcc
#     colours are an atlas-tile property — atlas + data.gd tints —
#     untouched by the generation-lane port).
#   * cost log -> .scratch/AC-0311/dump_run44.log.
# The pixel convention, the colour/shade recipe, the census, the
# roundness checks and the guard are byte-identical to the P2 script.
#
# Reads the far-payload dump (the canonical gen_far payload) and bakes
# the 12 per-face satellite textures (1024x1024 RGB8 PNG each), plus the
# numeric evidence JSON.
#
# COLOUR CONVENTION (reused from the streaming pipeline, not invented):
#   the far tier's per-block top-face colour is the fcc cache
#   (world.gd _lod_fcc_get: the sRGB average of the atlas tile, then
#   srgb_to_linear, dir d == 2 = "top"; the atlas already carries the
#   data.gd _bake_atlas_tints web tints for ids 1/5/7). This bake uses
#   EXACTLY those linear values (ac0310_fcc_probe.json), so a satellite
#   pixel is the same colour the far band draws for that block's top.
#   The data.gd flat palette (C_GRASS_TOP etc.) is the "no tile"
#   fallback and differs measurably for grass/water — see section 5 of
#   the results page.
#
# SHADE: "height for shading" — a fixed-sun lambert term from the
# height gradient. Land columns only; ocean is flat at sea level (the
# far payload's solid top S = max(H, sea): the water surface is a plane,
# so no gradient shading on it). Light dir L in the face tangent frame
# (u, radial, v) = normalize(0.4, 1.0, 0.2); brightness =
# 0.45 + 0.55*max(0, N.L) with N = normalize(-dH/du, 1, -dH/dv). The
# stored pixel is the baked linear colour converted to sRGB (the PNG is
# an unlit bake; the later render tier modulates day/night through the
# existing atmosphere shaders, per the ticket).
#
# PAYLOAD (1024 B per chunk, gen_far): [H u16x256 LE][biome x256][top x256].
#   H    = surface height (the no-cave column height; the promotion
#          contract makes it bit-exact with the full path's H).
#   biome= bcode: 0 snow, 1 desert, 2 forest, 3 plains (col_heights_pass).
#   top  = the fill-loop y==H surface block: B_GRASS(1) / B_SAND(4) /
#          B_SNOW_GRASS(12) / B_DEEPSLATE(32) (gen_far's formula — the
#          beach/deepslate overrides are included).
#
# TEXTURE PIXEL CONVENTION (the later render tier maps a face's (u,v)
# chart point to this texture 1:1):
#   pixel (i, j), i = column (0..1023, u 0->1 left->right), j = row
#   (0..1023, v 0->1 top->bottom) = the surface at chart point
#   (u, v) = ((i+0.5)/1024, (j+0.5)/1024).
#   faces 2-11: exactly one face CELL per pixel (cell (iu, iv) = (i, j);
#   the 1024-cell face grid matches the 1024-px texture 1:1).
#   faces 0/1 (the home pair, 1 m columns): the pixel samples the 1 m
#   column whose centre lies at the pixel centre's flat position
#   (floor of the chart->flat inverse of SphereMath.home_uv).
#
# INDEX RULE (the piece-1 smear repair): a u-axis (column i) index array
# is a ROW pattern (each image row = the i-array); a v-axis (row j) index
# array is a COLUMN pattern (each image column = the j-array). np.tile on
# a 1-D array with reps (NPIX, 1) ALWAYS makes row patterns — result[j,i]
# = a[i] — so tiling the j-arrays that way silently made the sample a
# function of i only: a 1-D slice repeated down every row (the smear).
# The per-face VARIANCE GUARD below asserts the stored image varies along
# BOTH axes and fails the bake otherwise.
#
# ROUNDNESS/LIMB: SphereMath (core/sphere_math.gd) is mirrored in numpy
# below (the grid lock: W = pi*R/2 = 6283 at R = 4000; the per-coordinate
# pre-warp tan(c*pi/4); face_for_dir's sign-order tie-breaks). The checks:
#   (a) 4e6 random sphere directions -> face_for_dir -> world_to_face ->
#       forward uv_to_world round-trip (max residual) + per-face counts;
#   (b) per-face solid angle: Monte-Carlo count vs the analytic
#       surface-integral of the warped face (the two must agree);
#   (c) the limb at the +Y view: the great circle d.y = 0 (the equator)
#       sampled densely -> per-face arcs (the side faces 4-11 each get
#       exactly 90 deg; the home pair and the -Y pair get 0 deg apart
#       from the measure-zero corner points);
#   (d) a generic limb ((1,1,1)/sqrt(3)): every point on the great
#       circle is painted (no empty-space gaps), arcs sum to 360 deg;
#   (e) every face boundary curve is classified great-circle-or-not by
#       a plane-through-origin fit (the design says all 24 shared edges
#       are great-circle arcs — the cube edges lie in the x=+-y class of
#       planes and the midlines in the x=0 / z=0 planes);
#   (f) the gapless shared-edge invariant (the _EDGES table, the same
#       dual-face evaluation the harness's sphere arm runs): both faces
#       of every shared edge evaluate the SAME sphere point.
import json
import os
import struct
import sys
import time
import zlib

import numpy as np

ROOT = "/home/angrygiant/github_projects/AweCraft"
DUMP = os.path.join(ROOT, ".scratch/AC-0311/far_dump.bin")
OUTDIR = os.path.join(ROOT, "godot/assets/satellite")
STATS = os.path.join(ROOT, "tasks/AC-0311/ac0311_rebake_stats.json")
FCC_JSON = os.path.join(ROOT, "tasks/AC-0310/ac0310_fcc_probe.json")

R = 4000.0
W = np.pi * R * 0.5          # face_width(R) = pi*R/2 = 6283.1853...
HW = W * 0.5                 # half-face = pi*R/4 = 3141.5927...
SEA = 126                    # Data.SEA
HMAX = 384                   # Data.HEIGHT
DEEPSLATE_Y = 64             # gen.cpp DEEPSLATE_Y
NPIX = 1024
HOME_RANGE = 197             # home chunks per axis: cx, cz in [-197, 196]
FACE_GRID = 64               # face chunks per axis (2-11)

t_start = time.monotonic()


def phase(label):
    return time.monotonic() - t_start


def linear_to_srgb(v):
    # sRGB companding, the standard piecewise (the inverse of the
    # srgb_to_linear the fcc probe applied).
    v = np.asarray(v, dtype=np.float64)
    out = np.where(v <= 0.0031308, v * 12.92, 1.055 * np.power(v, 1.0 / 2.4) - 0.045)
    return out


def write_png(path, img):
    # img: (H, W, 3) uint8. Minimal RGB8 encoder (filter 0 scanlines).
    h, w, _ = img.shape
    scan = np.zeros((h, 1 + 3 * w), dtype=np.uint8)
    scan[:, 1:] = img.reshape(h, 3 * w)
    raw = scan.tobytes()

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        c += struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        return c

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)
    return len(png)


def decode_png_rgb8(path):
    # Minimal decode of write_png's own output (filter-0 scanlines only).
    # The variance guard uses this so it tests the BYTES ON DISK, not the
    # in-memory array an encoder bug could corrupt invisibly.
    with open(path, "rb") as fh:
        b = fh.read()
    assert b[:8] == b"\x89PNG\r\n\x1a\n", path
    pos = 8
    idat = b""
    w = h = 0
    while pos + 8 <= len(b):
        (ln,) = struct.unpack(">I", b[pos:pos + 4])
        tag = b[pos + 4:pos + 8]
        data = b[pos + 8:pos + 8 + ln]
        if tag == b"IHDR":
            w, h = struct.unpack(">II", data[:8])
        elif tag == b"IDAT":
            idat += data
        elif tag == b"IEND":
            break
        pos += 12 + ln
    raw = zlib.decompress(idat)
    stride = 1 + 3 * w
    assert h > 0 and len(raw) == h * stride, (h, len(raw), h * stride)
    px = np.frombuffer(raw, dtype=np.uint8).reshape(h, stride)
    assert (px[:, 0] == 0).all(), "unexpected non-zero PNG filter byte in %s" % path
    return px[:, 1:].reshape(h, w, 3)


# --------------------------------------------------------------------------
# 1. Load the dump
# --------------------------------------------------------------------------
raw = np.fromfile(DUMP, dtype=np.uint8)
hdr = raw[:44]
assert hdr[:8].tobytes() == b"AC0311F1", "bad magic"
nrec = (raw.size - 44) // 1036
seed = int(np.frombuffer(hdr, dtype="<i8", count=1, offset=12)[0])
R_h = float(np.frombuffer(hdr, dtype="<f4", count=1, offset=20)[0])
hw_h = float(np.frombuffer(hdr, dtype="<f4", count=1, offset=24)[0])
sea = int(np.frombuffer(hdr, dtype="<u4", count=1, offset=28)[0])
hmax = int(np.frombuffer(hdr, dtype="<u4", count=1, offset=32)[0])
home_range = int(np.frombuffer(hdr, dtype="<u4", count=1, offset=36)[0])
face_grid = int(np.frombuffer(hdr, dtype="<u4", count=1, offset=40)[0])
assert abs(R_h - R) < 1e-3 and abs(hw_h - HW) < 1e-2, (R_h, hw_h)
assert sea == SEA and hmax == HMAX
assert home_range == HOME_RANGE and face_grid == FACE_GRID

rec = raw[44:].reshape(nrec, 1036)
cx = rec[:, :4].view("<i4").reshape(-1)
cz = rec[:, 4:8].view("<i4").reshape(-1)
face = rec[:, 8:12].view("<u4").reshape(-1)
pay = rec[:, 12:].copy()
H = pay[:, :512].view("<u2").reshape(nrec, 256)
BM = pay[:, 512:768].copy()
TOP = pay[:, 768:1024].copy()
t_load = phase("load")

n_home = int(np.count_nonzero(face <= 1))
assert n_home == (2 * HOME_RANGE - 1) ** 2 or n_home == (2 * HOME_RANGE - 1 + 1) ** 2, n_home
# the dump's home range is [-197, 196] both axes = 394 per axis
assert n_home == 394 * 394, n_home
assert nrec == 394 * 394 + 10 * FACE_GRID * FACE_GRID, nrec
home_idx = np.arange(n_home)
face_idx = np.arange(n_home, nrec)

# home grids (row-major cx outer, cz inner, as dumped)
Hh = H[home_idx].reshape(394, 394, 256)
BMh = BM[home_idx].reshape(394, 394, 256)
Toph = TOP[home_idx].reshape(394, 394, 256)

# --------------------------------------------------------------------------
# 2. Colours (the fcc probe)
# --------------------------------------------------------------------------
fcc = json.load(open(FCC_JSON))
# block id -> linear top-face colour (the far tier's exact fcc value)
COL = {}
for bid in (1, 4, 5, 12, 32):
    e = fcc["ids"][str(bid)]
    assert e.get("probe_linear") is not None, bid
    COL[bid] = np.asarray(e["probe_linear"], dtype=np.float64)
FLAT = {}
for bid in (1, 4, 5, 12, 32):
    FLAT[bid] = np.asarray(fcc["ids"][str(bid)]["flat_linear"], dtype=np.float64)

# --------------------------------------------------------------------------
# 3. Bake the 12 face textures
# --------------------------------------------------------------------------
L = np.array([0.4, 1.0, 0.2])
L = L / np.linalg.norm(L)
S_CELL = W / 1024.0   # face_cell_size(R)

# VARIANCE GUARD FLOORS (the piece-1 smear repair). The stored per-face image
# must vary along BOTH axes: a smear (one axis's index dropped) passes every
# data/mapping check and must not pass the bake. Distinct-row/column counts
# are over 256 sampled lines (every 4th) of the decoded PNG; the smear
# measured 1. Real terrain clears these floors by >= 4x on seed 44:
# the post-fix faces measured 256/256 distinct lines, H spread 74-110 m,
# and 179-233 bytes of spread on every colour channel (see the repair
# section of the results page for the per-face table).
VAR_ROW_FLOOR = 64        # distinct rows  (of 256 sampled)
VAR_COL_FLOOR = 64        # distinct cols  (of 256 sampled)
VAR_H_SPREAD_FLOOR = 8    # H max-min, metres, over the face
VAR_RGB_SPREAD_FLOOR = 8  # min over channels of (max-min) stored bytes

faces_out = {}
face_stats = {}

for f in range(12):
    if f <= 1:
        # --- home pair: pixel -> 1 m column
        i = np.arange(NPIX, dtype=np.float64)
        if f == 0:
            xp = (i + 0.5) * HW / NPIX            # flat x of the pixel centre
        else:
            xp = (i + 0.5 - NPIX) * HW / NPIX
        j = np.arange(NPIX, dtype=np.float64)
        zp = (2.0 * (j + 0.5) / NPIX - 1.0) * HW  # flat z of the pixel centre
        x = np.floor(xp).astype(np.int64)
        z = np.floor(zp).astype(np.int64)
        cxi = x // 16
        lxi = x - cxi * 16
        czj = z // 16
        lzj = z - czj * 16
        if f == 0:
            assert cxi.min() >= 0 and cxi.max() <= 196, cxi
        else:
            assert cxi.min() >= -197 and cxi.max() <= -1, cxi
        assert czj.min() >= -197 and czj.max() <= 196, czj
        # build 2D index grids — row patterns for the u-axis (i) arrays,
        # COLUMN patterns for the v-axis (j) arrays (see the INDEX RULE in
        # the header; np.tile(a_1d, (NPIX, 1)) is a row pattern only).
        I = np.tile(cxi, (NPIX, 1)) + 197                         # (j, i) -> cx+197
        J = np.broadcast_to(czj[:, None], (NPIX, NPIX)) + 197     # (j, i) -> cz+197
        Li = np.tile(lxi, (NPIX, 1))
        Lj = np.broadcast_to(lzj[:, None], (NPIX, NPIX))
        K = Lj * 16 + Li
        H2 = Hh[I, J, K].astype(np.int32)
        B2 = BMh[I, J, K].astype(np.int32)
        T2 = Toph[I, J, K].astype(np.int32)
        # column-space gradient (1 m spacing), clamped at chunk edges.
        # Hgf axes: [cx+197, cz+197, lz, lx] (slot = lz*16+lx splits 256
        # -> 16x16; the chunk axes inherit Hh's +197 offset), so axis 2
        # differences are dH/dz and axis 3 differences are dH/dx.
        Hgf = Hh.astype(np.float32).reshape(394, 394, 16, 16)
        P = np.pad(Hgf, [(0, 0), (0, 0), (1, 1), (1, 1)], mode="edge")
        dHdx = (P[:, :, 1:17, 2:18] - P[:, :, 1:17, 0:16]) / 2.0   # dH/dlx
        dHdz = (P[:, :, 2:18, 1:17] - P[:, :, 0:16, 1:17]) / 2.0   # dH/dlz
        # index the 4D gradient grids. AC-0310 P2 (2026-09-30) FIX: the
        # original `dHdx[I - 197, J - 197, ...]` indexed the +197-offset
        # axes with raw cxi/czj in [-197, 196] — numpy silently WRAPS the
        # negative indices, so every home pixel was shaded with a
        # DIFFERENT chunk's slope (~69% of home-face pixels off, max
        # channel diff 40). Caught when P2's in-engine bake byte-compared
        # against these shipped PNGs (the in-engine bake was always
        # correct). Index with I/J directly. Faces 2-11 were never affected
        # (their gradients are per-face; no offset axis).
        gxc = dHdx[I, J, Lj, Li]
        gzc = dHdz[I, J, Lj, Li]
        gx = gxc.reshape(NPIX, NPIX)
        gz = gzc.reshape(NPIX, NPIX)
        du_m, dv_m = 1.0, 1.0
    else:
        # --- faces 2-11: pixel == cell (1:1)
        recs = face_idx[(face[face_idx] == f)]
        assert recs.size == FACE_GRID * FACE_GRID, recs.size
        Hf = H[recs].reshape(FACE_GRID, FACE_GRID, 256)
        Bf = BM[recs].reshape(FACE_GRID, FACE_GRID, 256)
        Tf = TOP[recs].reshape(FACE_GRID, FACE_GRID, 256)
        iu = np.arange(NPIX, dtype=np.int64)
        iv = np.arange(NPIX, dtype=np.int64)
        mirrored = (2 <= f <= 5) or (8 <= f <= 9)   # SphereMath.face_mirror_x (machine-diffed, repair probe)
        liu = (15 - (iu & 15)) if mirrored else (iu & 15)
        # row patterns for the u-axis (i) arrays, COLUMN patterns for the
        # v-axis (j) arrays — the smear was the j-arrays tiled as rows.
        I = np.tile((iu >> 4), (NPIX, 1))
        J = np.broadcast_to((iv >> 4)[:, None], (NPIX, NPIX))
        Li = np.tile(liu, (NPIX, 1))
        Lj = np.broadcast_to((iv & 15)[:, None], (NPIX, NPIX))
        K = Lj * 16 + Li
        H2 = Hf[I, J, K].astype(np.int32)
        B2 = Bf[I, J, K].astype(np.int32)
        T2 = Tf[I, J, K].astype(np.int32)
        Hm = H2.astype(np.float32)
        Hmp = np.pad(Hm, 1, mode="edge")
        if 4 <= f <= 7:
            du_m, dv_m = S_CELL, S_CELL * 0.5   # x-faces: u full, v half
        else:
            du_m, dv_m = S_CELL * 0.5, S_CELL   # y/z-faces: u half, v full
        # H2 axes: [row j = v, column i = u] — gx is the u-derivative
        # (column differences, du_m), gz the v-derivative (row differences, dv_m).
        gx = ((Hmp[1:-1, 2:] - Hmp[1:-1, :-2]) / (2.0 * du_m)).astype(np.float64)
        gz = ((Hmp[2:, 1:-1] - Hmp[:-2, 1:-1]) / (2.0 * dv_m)).astype(np.float64)

    # --- colour + shade
    ocean = H2 < SEA
    col = np.zeros((NPIX, NPIX, 3), dtype=np.float64)
    col[:] = COL[5]  # ocean by default
    for bid in (1, 4, 12, 32):
        m = (~ocean) & (T2 == bid)
        col[m] = COL[bid]
    nz = np.sqrt(gx * gx + gz * gz + 1.0)
    nL = (-L[0] * gx + L[1] - L[2] * gz) / nz
    b = 0.45 + 0.55 * np.clip(nL, 0.0, 1.0)
    b[ocean] = 1.0
    lin = col * b[:, :, None]
    srgb = linear_to_srgb(lin)
    img8 = np.clip(np.round(srgb * 255.0), 0, 255).astype(np.uint8)
    out = os.path.join(OUTDIR, "satellite_face%02d.png" % f)
    png_bytes = write_png(out, img8)
    faces_out[f] = (out, png_bytes)

    # --- VARIANCE GUARD (the piece-1 smear repair): the image on disk must
    # vary along BOTH axes. Catches: a dropped/fixed axis index (a 1-D slice
    # repeated down every row or across every column — the piece-1 smear),
    # a constant/uniform face, a dead colour channel, and a degenerate PNG.
    # Data/mapping checks cannot see any of these: they test the payload and
    # the chart, not whether the image varies in two dimensions.
    dec = decode_png_rgb8(out)
    rows = dec[::4]
    cols = dec[:, ::4]
    drows = 1 + sum(1 for r in rows[1:] if not np.array_equal(r, rows[0]))
    dcols = 1 + sum(1 for k in range(1, 256) if not np.array_equal(cols[:, k], cols[:, 0]))
    hmin, hmax = int(H2.min()), int(H2.max())
    cmin = dec.reshape(-1, 3).min(axis=0)
    cmax = dec.reshape(-1, 3).max(axis=0)
    rspread = cmax - cmin
    variance = {
        "distinct_rows": int(drows), "distinct_cols": int(dcols),
        "h_min": hmin, "h_max": hmax, "h_spread": hmax - hmin,
        "rgb_min": [int(v) for v in cmin], "rgb_max": [int(v) for v in cmax],
        "rgb_spread": [int(v) for v in rspread],
    }
    variance["pass"] = bool(drows >= VAR_ROW_FLOOR and dcols >= VAR_COL_FLOOR
                            and variance["h_spread"] >= VAR_H_SPREAD_FLOOR
                            and int(rspread.min()) >= VAR_RGB_SPREAD_FLOOR)
    print("VARIANCE face %2d: rows %3d/256 cols %3d/256 H %3d..%3d (spread %3d m) "
          "rgb spread %s -> %s" % (f, drows, dcols, hmin, hmax, variance["h_spread"],
                                   list(rspread), "OK" if variance["pass"] else "FAIL"))

    # per-face evidence
    npx = NPIX * NPIX
    npix_ocean = int(np.count_nonzero(ocean))
    npix_land = npx - npix_ocean
    cls_counts = {}
    for bid in (1, 4, 12, 32):
        m = (~ocean) & (T2 == bid)
        cls_counts[str(bid)] = {
            "pixels": int(np.count_nonzero(m)),
            "frac_of_land": float(np.count_nonzero(m) / max(1, npix_land)),
            "mean_brightness": float(np.mean(b[m])) if np.any(m) else None,
            "mean_stored_srgb": [float(v) for v in np.mean(srgb[m], axis=0)] if np.any(m) else None,
        }
    biome_counts = {str(bm): int(np.count_nonzero(B2 == bm)) for bm in (0, 1, 2, 3)}
    face_stats[str(f)] = {
        "file": os.path.basename(out),
        "png_bytes": png_bytes,
        "pixels": npx,
        "ocean_pixels": npix_ocean,
        "land_pixels": npix_land,
        "ocean_frac": npix_ocean / npx,
        "H_mean_all": float(np.mean(H2)),
        "H_min": int(H2.min()),
        "H_max": int(H2.max()),
        "land_H_mean": float(np.mean(H2[~ocean])) if npix_land else None,
        "class_pixels": cls_counts,
        "biome_pixels_sampled": biome_counts,
        "du_m": du_m,
        "dv_m": dv_m,
        "variance": variance,
    }
    print("FACE %2d: ocean %.3f land %.3f png %6d B" %
          (f, npix_ocean / npx, npix_land / npx, png_bytes))

t_bake = phase("bake")

# The guard is permanent: a smeared or constant bake must never pass again.
var_fail = [f for f in range(12) if not face_stats[str(f)]["variance"]["pass"]]
if var_fail:
    for f in var_fail:
        print("VARIANCE GUARD FAIL face %d: %s" % (f, face_stats[str(f)]["variance"]))
    sys.exit(1)

# --------------------------------------------------------------------------
# 4. Planet-wide column census (ALL 256 columns of ALL chunks)
# --------------------------------------------------------------------------
H_all = H.reshape(-1).astype(np.int32)
BM_all = BM.reshape(-1)
TOP_all = TOP.reshape(-1)
n_cols = H_all.size
ocean_cols = int(np.count_nonzero(H_all < SEA))
land_cols = n_cols - ocean_cols

# top internal consistency: recompute the gen_far formula from (bm, H)
top_expect = np.full(H_all.shape, 1, dtype=np.int32)
top_expect[BM_all == 1] = 4
top_expect[BM_all == 0] = 12
top_expect[(H_all <= SEA + 1) & (BM_all != 1)] = 4
top_expect[H_all < DEEPSLATE_Y] = 32
top_mismatch = int(np.count_nonzero(top_expect != TOP_all.astype(np.int32)))

census = {
    "columns_total": n_cols,
    "ocean_cols_H_lt_sea": ocean_cols,
    "land_cols_H_ge_sea": land_cols,
    "ocean_frac": ocean_cols / n_cols,
    "H_min": int(H_all.min()),
    "H_max": int(H_all.max()),
    "H_mean": float(H_all.mean()),
    "biome_counts_all": {str(bm): int(np.count_nonzero(BM_all == bm)) for bm in (0, 1, 2, 3)},
    "biome_counts_land": {str(bm): int(np.count_nonzero((BM_all == bm) & (H_all >= SEA))) for bm in (0, 1, 2, 3)},
    "top_counts_all": {str(bid): int(np.count_nonzero(TOP_all == bid)) for bid in (1, 4, 12, 32)},
    "top_counts_land": {str(bid): int(np.count_nonzero((TOP_all == bid) & (H_all >= SEA))) for bid in (1, 4, 12, 32)},
    "top_formula_mismatches": top_mismatch,
    "seed": seed,
}

# home-pair-only census (the chunk set the streaming pipeline actually
# demotes to far today — faces 0/1)
Hh_all = Hh.reshape(-1).astype(np.int32)
census["home_pair"] = {
    "columns": int(Hh_all.size),
    "ocean_frac": float(np.mean(Hh_all < SEA)),
    "land_frac": float(np.mean(Hh_all >= SEA)),
    "H_mean": float(Hh_all.mean()),
}
# faces 2-11 census
Hf_all = H[face_idx].reshape(-1).astype(np.int32)
census["faces_2_11"] = {
    "columns": int(Hf_all.size),
    "ocean_frac": float(np.mean(Hf_all < SEA)),
    "land_frac": float(np.mean(Hf_all >= SEA)),
    "H_mean": float(Hf_all.mean()),
}

# the oceansurface arm's window (drypit: +-5 chunks around the spawn
# chunk (0,0), the arm's default half=5) — recomputed here from the far
# payload's H (the promotion contract: far H is bit-exact with the full
# path's H, so the land/sea SPLIT should match the arm's counts exactly).
win = (cx[home_idx] >= -5) & (cx[home_idx] <= 5) & (cz[home_idx] >= -5) & (cz[home_idx] <= 5)
Hw = Hh[win.reshape(394, 394)].reshape(-1).astype(np.int32)
census["drypit_window_pm5"] = {
    "chunks": 121,
    "columns": int(Hw.size),
    "ocean_cols_H_lt_sea": int(np.count_nonzero(Hw < SEA)),
    "land_cols_H_ge_sea": int(np.count_nonzero(Hw >= SEA)),
    "note": ("compare against the oceansurface arm (AWECRAFT_SEED=%d, half=5); "
             "AC-0311 post-port run: land 29896 / ocean 1080 (pre-port was 29895/1081)"
             % seed),
}

t_census = phase("census")

# --------------------------------------------------------------------------
# 5. Roundness / limb checks (SphereMath mirrored in numpy)
# --------------------------------------------------------------------------
def prewarp(c):
    return np.tan(c * np.pi / 4.0)


def prewarp_inv(c):
    return np.arctan(c) * 4.0 / np.pi


# cube maps C(face, u, v) from the sphere_math.gd header
def uv_cube(f, u, v):
    if f == 0:
        return np.stack([u, np.ones_like(u), 2.0 * v - 1.0], axis=-1)
    if f == 1:
        return np.stack([u - 1.0, np.ones_like(u), 2.0 * v - 1.0], axis=-1)
    if f == 2:
        return np.stack([u, -np.ones_like(u), 2.0 * v - 1.0], axis=-1)
    if f == 3:
        return np.stack([u - 1.0, -np.ones_like(u), 2.0 * v - 1.0], axis=-1)
    if f == 4:
        return np.stack([np.ones_like(u), 2.0 * u - 1.0, v], axis=-1)
    if f == 5:
        return np.stack([np.ones_like(u), 2.0 * u - 1.0, v - 1.0], axis=-1)
    if f == 6:
        return np.stack([-np.ones_like(u), 2.0 * u - 1.0, v], axis=-1)
    if f == 7:
        return np.stack([-np.ones_like(u), 2.0 * u - 1.0, v - 1.0], axis=-1)
    if f == 8:
        return np.stack([u, 2.0 * v - 1.0, np.ones_like(u)], axis=-1)
    if f == 9:
        return np.stack([u - 1.0, 2.0 * v - 1.0, np.ones_like(u)], axis=-1)
    if f == 10:
        return np.stack([u, 2.0 * v - 1.0, -np.ones_like(u)], axis=-1)
    return np.stack([u - 1.0, 2.0 * v - 1.0, -np.ones_like(u)], axis=-1)


def uv_to_world(f, u, v):
    c = uv_cube(f, u, v)
    p = prewarp(c)
    return p / np.linalg.norm(p, axis=-1, keepdims=True) * R


def face_for_dir(d):
    # d: (..., 3) unit directions
    n = np.maximum.reduce([np.abs(d[..., 0]), np.abs(d[..., 1]), np.abs(d[..., 2])])
    x = d[..., 0] / n
    y = d[..., 1] / n
    z = d[..., 2] / n
    axis = np.select(
        [x == 1.0, x == -1.0, y == 1.0, y == -1.0, z == 1.0],
        [2, 3, 0, 1, 4], default=5)
    sp = np.where((axis == 2) | (axis == 3), z, x)
    return axis * 2 + np.where(sp < 0.0, 1, 0)


def world_to_face_uvw(d):
    # d: (..., 3) unit directions -> (face, u, v)
    f = face_for_dir(d)
    dom = np.maximum.reduce([np.abs(d[..., 0]), np.abs(d[..., 1]), np.abs(d[..., 2])])
    Cx = prewarp_inv(d[..., 0] / dom)
    Cy = prewarp_inv(d[..., 1] / dom)
    Cz = prewarp_inv(d[..., 2] / dom)
    u = np.where(np.isin(f, [0, 2, 8, 10]), Cx,
                 np.where(np.isin(f, [1, 3, 9, 11]), Cx + 1.0,
                          (Cy + 1.0) * 0.5))
    v = np.where(np.isin(f, [0, 1, 2, 3]), (Cz + 1.0) * 0.5,
                 np.where(np.isin(f, [4, 6]), Cz,
                          np.where(np.isin(f, [5, 7]), Cz + 1.0, (Cy + 1.0) * 0.5)))
    return f, u, v


def fwd_for_face(f, u, v):
    # per-face forward map for a subset
    return uv_to_world(f, u, v)


# (a) Monte-Carlo coverage + round-trip
rng = np.random.default_rng(20260917)
N_MC = 4_000_000
gauss = rng.standard_normal((N_MC, 3))
d = gauss / np.linalg.norm(gauss, axis=1, keepdims=True)
f_m = face_for_dir(d)
_, u_m, v_m = world_to_face_uvw(d)
# forward round-trip: per-face
P = np.zeros_like(d)
for f in range(12):
    m = f_m == f
    P[m] = fwd_for_face(int(f), u_m[m], v_m[m])
resid = np.linalg.norm(P / R - d, axis=1)   # direction-space residual
rt = {
    "N": N_MC,
    "max_residual": float(resid.max()),
    "mean_residual": float(resid.mean()),
    "over_1e-6": int(np.count_nonzero(resid > 1e-6)),
    "u_range": [float(u_m.min()), float(u_m.max())],
    "v_range": [float(v_m.min()), float(v_m.max())],
    "uv_in_unit_square": bool(np.all((u_m >= -1e-12) & (u_m <= 1 + 1e-12) &
                                      (v_m >= -1e-12) & (v_m <= 1 + 1e-12))),
}

# (b) per-face solid angle: MC counts vs the analytic integral
face_counts = np.array([int(np.count_nonzero(f_m == f)) for f in range(12)])
omega_mc = 4.0 * np.pi * face_counts / N_MC
omega_int = np.zeros(12)
area_m2 = np.zeros(12)
for f in range(12):
    gu = (np.arange(NPIX) + 0.5) / NPIX
    gv = (np.arange(NPIX) + 0.5) / NPIX
    GU, GV = np.meshgrid(gu, gv, indexing="xy")
    Pm = uv_to_world(f, GU, GV)                       # (1024, 1024, 3)
    h = 0.5 / NPIX                                    # half-grid central offset
    Pu = uv_to_world(f, np.clip(GU + h, 0, 1), GV)
    Pu2 = uv_to_world(f, np.clip(GU - h, 0, 1), GV)
    Pv = uv_to_world(f, GU, np.clip(GV + h, 0, 1))
    Pv2 = uv_to_world(f, GU, np.clip(GV - h, 0, 1))
    du = (Pu - Pu2) / (2.0 * h)                       # true dP/du (m per unit-u)
    dv = (Pv - Pv2) / (2.0 * h)
    cross = np.cross(du, dv)
    dA = np.linalg.norm(cross, axis=-1)               # m^2 per unit (u,v)
    cell = 1.0 / (NPIX * NPIX)                        # (du)(dv) per grid cell
    area_m2[f] = dA.sum() * cell                      # m^2
    dot = np.einsum("ijk,ijk->ij", cross, Pm)         # (cross.P) per cell
    omega_int[f] = np.abs(dot).sum() * cell / (R ** 3)  # solid angle (sr)
roundness = {
    "solid_angle_sr_MC": [float(x) for x in omega_mc],
    "solid_angle_sr_int": [float(x) for x in omega_int],
    "area_m2_int": [float(x) for x in area_m2],
    "rel_err_area": [float(abs(a - b) / b) for a, b in zip(omega_mc, omega_int)],
    "total_area_m2_int": float(area_m2.sum()),
    "sphere_area_4piR2": float(4.0 * np.pi * R * R),
    "total_rel_err": float(abs(area_m2.sum() - 4.0 * np.pi * R * R) / (4.0 * np.pi * R * R)),
}

# (c) the +Y limb: the equator d.y = 0
phi = np.linspace(0.0, 2.0 * np.pi, 100_000, endpoint=False)
d_eq = np.stack([np.cos(phi), np.zeros_like(phi), np.sin(phi)], axis=1)
f_eq = face_for_dir(d_eq)
arcs_eq = {str(f): float(np.count_nonzero(f_eq == f) / len(phi) * 360.0) for f in range(12)}

# (d) generic limb (1,1,1)/sqrt(3)
d0 = np.array([1.0, 1.0, 1.0]) / np.sqrt(3.0)
t1 = np.array([1.0, -1.0, 0.0])
t1 = t1 - t1.dot(d0) * d0
t1 /= np.linalg.norm(t1)
t2 = np.cross(d0, t1)
phi2 = np.linspace(0.0, 2.0 * np.pi, 100_000, endpoint=False)
d_limb = np.outer(np.cos(phi2), t1) + np.outer(np.sin(phi2), t2)
f_limb = face_for_dir(d_limb)
_, u_limb, v_limb = world_to_face_uvw(d_limb)
arcs_limb = {str(f): float(np.count_nonzero(f_limb == f) / len(phi2) * 360.0) for f in range(12)}
limb_ok = bool(np.all((u_limb >= -1e-12) & (u_limb <= 1 + 1e-12) &
                      (v_limb >= -1e-12) & (v_limb <= 1 + 1e-12)))

# (e) edge great-circle classification (257 samples per edge)
edge_dev = {}
for f in range(12):
    ts = np.linspace(0.0, 1.0, 257)
    edges = {}
    for ename, (u_e, v_e) in {
        "u1": (np.ones_like(ts), ts),
        "u0": (np.zeros_like(ts), ts),
        "v1": (ts, np.ones_like(ts)),
        "v0": (ts, np.zeros_like(ts)),
    }.items():
        P_e = uv_to_world(f, u_e, v_e)
        nrm = np.cross(P_e[0], P_e[1])
        nn = np.linalg.norm(nrm)
        if nn < 1e-12:
            edges[ename] = {"great": None, "dev": None}
            continue
        nrm = nrm / nn
        dev = float(np.max(np.abs(P_e @ nrm))) / R
        edges[ename] = {"great": bool(dev < 1e-9), "dev_rel": dev}
    edge_dev[str(f)] = edges

# (f) the gapless shared-edge invariant (the _EDGES table, mirrored)
_EDGES = [
    [[[0.0, 0.5, 5, 0, 0.0, 2.0], [0.5, 1.0, 4, 0, -1.0, 2.0]],
     [[0.0, 1.0, 1, 0, 0.0, 1.0]],
     [[0.0, 1.0, 8, 2, 0.0, 1.0]],
     [[0.0, 1.0, 10, 2, 0.0, 1.0]]],
    [[[0.0, 1.0, 0, 1, 0.0, 1.0]],
     [[0.0, 0.5, 7, 0, 0.0, 2.0], [0.5, 1.0, 6, 0, -1.0, 2.0]],
     [[0.0, 1.0, 9, 2, 0.0, 1.0]],
     [[0.0, 1.0, 11, 2, 0.0, 1.0]]],
    [[[0.0, 0.5, 5, 1, 0.0, 2.0], [0.5, 1.0, 4, 1, -1.0, 2.0]],
     [[0.0, 1.0, 3, 0, 0.0, 1.0]],
     [[0.0, 1.0, 8, 3, 0.0, 1.0]],
     [[0.0, 1.0, 10, 3, 0.0, 1.0]]],
    [[[0.0, 1.0, 2, 1, 0.0, 1.0]],
     [[0.0, 0.5, 7, 1, 0.0, 2.0], [0.5, 1.0, 6, 1, -1.0, 2.0]],
     [[0.0, 1.0, 9, 3, 0.0, 1.0]],
     [[0.0, 1.0, 11, 3, 0.0, 1.0]]],
    [[[0.0, 1.0, 0, 0, 0.5, 0.5]],
     [[0.0, 1.0, 2, 0, 0.5, 0.5]],
     [[0.0, 1.0, 8, 0, 0.0, 1.0]],
     [[0.0, 1.0, 5, 2, 0.0, 1.0]]],
    [[[0.0, 1.0, 0, 0, 0.0, 0.5]],
     [[0.0, 1.0, 2, 0, 0.0, 0.5]],
     [[0.0, 1.0, 4, 3, 0.0, 1.0]],
     [[0.0, 1.0, 10, 0, 0.0, 1.0]]],
    [[[0.0, 1.0, 1, 1, 0.5, 0.5]],
     [[0.0, 1.0, 3, 1, 0.5, 0.5]],
     [[0.0, 1.0, 9, 1, 0.0, 1.0]],
     [[0.0, 1.0, 7, 2, 0.0, 1.0]]],
    [[[0.0, 1.0, 1, 1, 0.0, 0.5]],
     [[0.0, 1.0, 3, 1, 0.0, 0.5]],
     [[0.0, 1.0, 6, 3, 0.0, 1.0]],
     [[0.0, 1.0, 11, 1, 0.0, 1.0]]],
    [[[0.0, 1.0, 4, 2, 0.0, 1.0]],
     [[0.0, 1.0, 9, 0, 0.0, 1.0]],
     [[0.0, 1.0, 0, 2, 0.0, 1.0]],
     [[0.0, 1.0, 2, 2, 0.0, 1.0]]],
    [[[0.0, 1.0, 8, 1, 0.0, 1.0]],
     [[0.0, 1.0, 6, 2, 0.0, 1.0]],
     [[0.0, 1.0, 1, 2, 0.0, 1.0]],
     [[0.0, 1.0, 3, 2, 0.0, 1.0]]],
    [[[0.0, 1.0, 5, 3, 0.0, 1.0]],
     [[0.0, 1.0, 11, 0, 0.0, 1.0]],
     [[0.0, 1.0, 0, 3, 0.0, 1.0]],
     [[0.0, 1.0, 2, 3, 0.0, 1.0]]],
    [[[0.0, 1.0, 10, 1, 0.0, 1.0]],
     [[0.0, 1.0, 7, 3, 0.0, 1.0]],
     [[0.0, 1.0, 1, 3, 0.0, 1.0]],
     [[0.0, 1.0, 3, 3, 0.0, 1.0]]],
]
gap_max = 0.0
gap_samples = 0
gap_per_edge_max = {}
for f in range(12):
    for e in range(4):
        for seg in _EDGES[f][e]:
            tlo = seg[0]
            span = seg[1] - tlo
            for k in range(17):
                t = tlo + span * (k / 8.0) if k < 8 else tlo + span * ((k - 8) / 9.0)
                if e == 0:
                    uA, vA = 1.0, t
                elif e == 1:
                    uA, vA = 0.0, t
                elif e == 2:
                    uA, vA = t, 1.0
                else:
                    uA, vA = t, 0.0
                B = seg[2]
                eB = seg[3]
                s = seg[4] + seg[5] * t
                if eB == 0:
                    uB, vB = 1.0, s
                elif eB == 1:
                    uB, vB = 0.0, s
                elif eB == 2:
                    uB, vB = s, 1.0
                else:
                    uB, vB = s, 0.0
                PA = uv_to_world(f, np.array([uA]), np.array([vA]))[0]
                PB = uv_to_world(B, np.array([uB]), np.array([vB]))[0]
                dist = float(np.linalg.norm(PA - PB))
                gap_max = max(gap_max, dist)
                gap_samples += 1
                key = "f%de%d" % (f, e)
                gap_per_edge_max[key] = max(gap_per_edge_max.get(key, 0.0), dist)

roundness["roundtrip"] = rt
roundness["equator_arcs_deg"] = arcs_eq
roundness["limb_111_arcs_deg"] = arcs_limb
roundness["limb_111_all_painted"] = limb_ok
roundness["edge_great_circle"] = edge_dev
roundness["gapless_max_m"] = gap_max
roundness["gapless_samples"] = gap_samples
roundness["gapless_per_edge_max_m"] = gap_per_edge_max

t_round = phase("roundness")

# --------------------------------------------------------------------------
# 6. Cost summary (the 4.5 s claim)
# --------------------------------------------------------------------------
dump_log = {}
try:
    with open(os.path.join(ROOT, ".scratch/AC-0311/dump_run44.log")) as fl:
        for line in fl:
            if line.startswith("RESULT "):
                dump_log = json.loads(line[len("RESULT "):])
except Exception as ex:  # noqa: BLE001
    dump_log = {"error": str(ex)}

import resource  # noqa: E402
rss_kb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss

cost = {
    "ticket_claim": "1024^2 per face ~ 12.6M samples ~ 4.5 s CPU at ~92 us/chunk, one-time per seed",
    "assumed_chunks_in_claim": 12 * NPIX * NPIX // 256,
    "actual_chunks": nrec,
    "chunks_per_face_actual": {
        "home_pair_each": (394 * 394), "faces_2_11_each": FACE_GRID * FACE_GRID,
    },
    "far_us_per_chunk_measured": dump_log.get("far_us_per_chunk"),
    "far_us_total_c": dump_log.get("gen_timing", {}).get("far_us"),
    "c_plus_plus_gen_wall_s": dump_log.get("wall_ms", 0) / 1000.0,
    "dump_process_wall_s": None,   # filled from the /usr/bin/time line below
    "dump_max_rss_kbytes": None,
    "python_bake_wall_s": t_bake,
    "python_bake_phases_s": {
        "load_dump": t_load, "bake+png": t_bake - t_load, "census": t_census - t_bake,
        "roundness": t_round - t_census,
    },
    "python_max_rss_kbytes": rss_kb,
    "note": ("the claim's 4.5 s assumed 49,152 chunks (12 faces x 4096); the "
             "home pair's 1 m columns need 155,236 chunks (394x394, 19x the "
             "assumed per-face count) — the real chunk count is 196,196."),
}
# parse the /usr/bin/time wall + rss from the dump log
try:
    with open(os.path.join(ROOT, ".scratch/AC-0311/dump_run44.log")) as fl:
        for line in fl:
            if "Elapsed" in line:
                # Godot time -v: "h:mm:ss" or "m:ss" after the last label colon
                tstr = line.rsplit(": ", 1)[-1].strip()
                parts = tstr.split(":")
                if len(parts) == 2:
                    cost["dump_process_wall_s"] = float(parts[0]) * 60.0 + float(parts[1])
                elif len(parts) == 3:
                    cost["dump_process_wall_s"] = (float(parts[0]) * 3600.0 +
                                                   float(parts[1]) * 60.0 + float(parts[2]))
            elif "Maximum resident set size" in line:
                cost["dump_max_rss_kbytes"] = int(line.split(":")[-1].strip())
except Exception as ex:  # noqa: BLE001
    cost["dump_time_parse_error"] = str(ex)

# --------------------------------------------------------------------------
# 7. Emit
# --------------------------------------------------------------------------
stats = {
    "ticket": "AC-0311 re-bake (re-ship of the AC-0310 bake, post-port world)",
    "seed": seed,
    "R": R,
    "W_face": W,
    "hw": HW,
    "sea": SEA,
    "hmax": HMAX,
    "n_pixels_per_face": NPIX * NPIX,
    "n_faces": 12,
    "total_texture_pixels": 12 * NPIX * NPIX,
    "pixel_convention": "pixel (i,j) = chart point ((i+0.5)/1024, (j+0.5)/1024); faces 2-11 one cell per pixel; faces 0/1 the 1 m column at the pixel centre's flat position",
    "colour_source": "fcc top-face linear (ac0310_fcc_probe.json); flat data.gd palette in 'flat_linear' for reference",
    "shade": "fixed-sun lambert L=normalize(0.4,1,0.2), brightness=0.45+0.55*max(0,N.L), land only; ocean flat at sea",
    "faces": face_stats,
    "census": census,
    "roundness": roundness,
    "cost": cost,
    "phases_s": {
        "t_load": t_load, "t_bake": t_bake, "t_census": t_census,
        "t_round": t_round, "total": t_round,
    },
}
with open(STATS, "w") as f:
    json.dump(stats, f, indent=1)
print("STATS -> %s" % STATS)
print("total python wall %.1f s (load %.1f bake %.1f census %.1f round %.1f)" %
      (t_round, t_load, t_bake - t_load, t_census - t_bake, t_round - t_census))
print("census: ocean_frac %.4f (planet), %.4f (home), %.4f (faces2-11); top mismatches %d" %
      (census["ocean_frac"], census["home_pair"]["ocean_frac"],
       census["faces_2_11"]["ocean_frac"], top_mismatch))
print("roundness: rt_max %.3e equator arcs %s gapless_max %.3e m" %
      (rt["max_residual"],
       {k: round(v, 2) for k, v in arcs_eq.items() if v > 0.01},
       gap_max))
