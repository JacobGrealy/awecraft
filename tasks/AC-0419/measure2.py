#!/usr/bin/env python3
"""AC-0419 measurements (v2).

Usage:
  python3 measure2.py dome <png>                 # sky luminance stats (zenith frames)
  python3 measure2.py colscan <png> <alt_m> <R>  # central-column upper-half radial scan
  python3 measure2.py bmap <png> <alt_m> <R>     # coarse 2D b-map + left/right symmetry check
  python3 measure2.py ring <png> <alt_m> <R>     # nadir frames: central column from centre outward

Geometry (verified against harness.gd planet preset, R24, seed 44):
  camera on the radial through the spawn, d = R + 141 + SAT_ALT from the centre.
  LIMB aim: frame centre ray is the tangent (b = R exactly, angle asin(R/d) from nadir).
  ZENITH aim: frame centre = local zenith. NADIR aim: frame centre = nadir.
  Pixel (x,y): u = x/640 - 1, v = 1 - y/360 (v up).
  dir = normalize(aim + Xc*(u*tan_h) + Vc*(v*tan_v)); b = |cross(-p, dir)|.
"""
import math
import sys
from PIL import Image

TAN_V = math.tan(math.radians(37.5))
TAN_H = TAN_V * (1280.0 / 720.0)


def cam_basis(alt, R, aim):
    d = R + 141.0 + alt
    # spawn radial (seed 44 spawn (8.5,141,8.5) - tiny tilt, kept for exactness)
    sx, sy, sz = 8.5, 141.0, 8.5
    sl = math.sqrt(sx * sx + sy * sy + sz * sz)
    rad = (sx / sl, sy / sl, sz / sl)          # radial unit (centre -> camera)
    p = (rad[0] * d, rad[1] * d, rad[2] * d)   # camera position
    n = (-rad[0], -rad[1], -rad[2])            # nadir unit (camera -> centre)
    # pl_hd = normalize(cross((0,0,1), rad))
    h = (-rad[1], rad[0], 0.0)
    hl = math.sqrt(h[0] * h[0] + h[2] * h[2])
    h = (h[0] / hl, h[1] / hl, h[2] / hl)
    if aim == "limb":
        a = math.asin(R / d)
        aimv = tuple(math.cos(a) * n[i] + math.sin(a) * h[i] for i in range(3))
        vdir = tuple(-math.sin(a) * n[i] + math.cos(a) * h[i] for i in range(3))
    elif aim == "zenith":
        aimv = (-n[0], -n[1], -n[2])  # zenith = -nadir
        vdir = h  # horizontal up-hint (matches harness pl_hd)
    elif aim == "nadir":
        aimv = n
        vdir = h
    else:
        raise SystemExit("bad aim")
    # Xc = cross(vdir, -aimv)
    Xc = (vdir[1] * (-aimv[2]) - vdir[2] * (-aimv[1]),
          vdir[2] * (-aimv[0]) - vdir[0] * (-aimv[2]),
          vdir[0] * (-aimv[1]) - vdir[1] * (-aimv[0]))
    xl = math.sqrt(Xc[0] ** 2 + Xc[1] ** 2 + Xc[2] ** 2)
    Xc = (Xc[0] / xl, Xc[1] / xl, Xc[2] / xl)
    return p, aimv, Xc, vdir


def ray_b(x, y, alt, R, aim):
    p, a, Xc, vdir = cam_basis(alt, R, aim)
    u = x / 640.0 - 1.0
    v = 1.0 - y / 360.0
    d3 = (a[0] + Xc[0] * u * TAN_H + vdir[0] * v * TAN_V,
          a[1] + Xc[1] * u * TAN_H + vdir[1] * v * TAN_V,
          a[2] + Xc[2] * u * TAN_H + vdir[2] * v * TAN_V)
    l = math.sqrt(d3[0] ** 2 + d3[1] ** 2 + d3[2] ** 2)
    d3 = (d3[0] / l, d3[1] / l, d3[2] / l)
    c = (-p[0], -p[1], -p[2])
    cr = (c[1] * d3[2] - c[2] * d3[1], c[2] * d3[0] - c[0] * d3[2], c[0] * d3[1] - c[1] * d3[0])
    return math.sqrt(cr[0] ** 2 + cr[1] ** 2 + cr[2] ** 2)


def L(px):
    return 0.2126 * px[0] + 0.7152 * px[1] + 0.0722 * px[2]


def med(vals):
    v = sorted(vals)
    return v[len(v) // 2]


def dome(png):
    im = Image.open(png).convert("RGB")
    px = im.load()
    W, H = im.size
    vals = [L(px[x, y]) for y in range(30, H - 30, 2) for x in range(20, W - 20, 4)]
    n = len(vals)
    vs = sorted(vals)
    print("%s: median L = %.1f, p10 = %.1f, p25 = %.1f, p75 = %.1f, p90 = %.1f (of %d px)"
          % (png, vs[n // 2], vs[n // 10], vs[n // 4], vs[3 * n // 4], vs[9 * n // 10], n))


def colscan(png, alt, R, aim="limb"):
    im = Image.open(png).convert("RGB")
    px = im.load()
    print("row : L   b     (centre column, upper half; aim=%s, d=%.0f)" % (aim, R + 141 + alt))
    prev = None
    maxstep = (0, 0.0)
    for y in range(30, 358, 3):
        l = L(px[640, y])
        b = ray_b(640, y, alt, R, aim)
        step = abs(l - prev) if prev is not None else 0.0
        if step > maxstep[1]:
            maxstep = (y, step)
        prev = l
        print("%4d : %5.1f  %7.0f" % (y, l, b))
    print("max adjacent delta in upper half: %.1f L at row %d" % (maxstep[1], maxstep[0]))


def bmap(png, alt, R, aim="limb"):
    im = Image.open(png).convert("RGB")
    px = im.load()
    W, H = im.size
    # coarse map: rows 40..680 step 40, cols 40..1240 step 80
    print("coarse b-map (L values; each cell's b under its L):")
    bins = {}
    for y in range(40, 681, 40):
        row = []
        for x in range(40, 1241, 80):
            l = L(px[x, y])
            b = ray_b(x, y, alt, R, aim)
            row.append((l, b))
            bins.setdefault(int(b / 500), []).append(l)
        print("y=%3d %s" % (y, "  ".join("%4.0f" % (l) for l, _ in row)))
    print("symmetry by b (median L per 500 m b-bin; left vs right halves of the same bin):")
    im2 = Image.open(png).convert("RGB")
    px2 = im2.load()
    for k in sorted(bins):
        lo, hi = k * 500, (k + 1) * 500
        lefts = [L(px2[x, y]) for y in range(40, 681, 40) for x in range(40, 641, 80)
                if lo <= ray_b(x, y, alt, R, aim) < hi]
        rights = [L(px2[x, y]) for y in range(40, 681, 40) for x in range(640, 1241, 80)
                  if lo <= ray_b(x, y, alt, R, aim) < hi]
        if lefts and rights:
            print("  b %4d-%4d: left med %5.1f (n=%d)   right med %5.1f (n=%d)   diff %5.1f"
                  % (lo, hi, med(lefts), len(lefts), med(rights), len(rights), abs(med(lefts) - med(rights))))


def ring(png, alt, R, aim="nadir"):
    im = Image.open(png).convert("RGB")
    px = im.load()
    print("row : L   b     (centre column from frame centre upward; aim=%s)" % aim)
    for y in range(358, 28, -6):
        l = L(px[640, y])
        b = ray_b(640, y, alt, R, aim)
        print("%4d : %5.1f  %7.0f" % (y, l, b))


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "dome":
        dome(sys.argv[2])
    elif cmd == "colscan":
        colscan(sys.argv[2], float(sys.argv[3]), float(sys.argv[4]),
                sys.argv[5] if len(sys.argv) > 5 else "limb")
    elif cmd == "bmap":
        bmap(sys.argv[2], float(sys.argv[3]), float(sys.argv[4]),
             sys.argv[5] if len(sys.argv) > 5 else "limb")
    elif cmd == "ring":
        ring(sys.argv[2], float(sys.argv[3]), float(sys.argv[4]),
             sys.argv[5] if len(sys.argv) > 5 else "nadir")
