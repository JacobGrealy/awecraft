#!/usr/bin/env python3
"""AC-0439 sky-band measurement: for a planet-preset frame, the SKY
pixels (outside the analytic R+SEA disc + a stated margin, the region
the sky pass owns) are censused: luminance spread, star-like pixel
count, and the row-median profile's max single-row step (the
'flat space, planet is the only boundary' check for the OUTSIDE
acceptance; on an inside frame the same region reads the air family).

Usage: python3 skyband.py <frame.png> <alt_sat_m> <sx> <sy> <sz> [margin_m]
alt_sat_m = AWECRAFT_SAT_ALT (the preset adds it to the spawn radius).
"""
import sys, math
from PIL import Image

R = 4000.0

def load(path):
    return Image.open(path).convert("RGB")

def lum(r, g, b):
    return 0.2126 * r + 0.7152 * g + 0.0722 * b

def vs(a, b):
    return (a[0]-b[0], a[1]-b[1], a[2]-b[2])

def vd(a, b):
    return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]

def vx(a, b):
    return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])

def vn(a):
    l = math.sqrt(vd(a, a))
    return (a[0]/l, a[1]/l, a[2]/l)

def main():
    path = sys.argv[1]
    alt = float(sys.argv[2])
    spawn = tuple(float(x) for x in sys.argv[3:6])
    margin = float(sys.argv[6]) if len(sys.argv) > 6 else 40.0
    im = load(path)
    W, H = im.size
    px = im.load()
    half_fov = 75.0 / 2.0
    t = math.tan(math.radians(half_fov))

    cen = (0.0, -R, 0.0)
    spn = spawn
    up = vn(vs(spn, cen))
    pos = (spn[0] + up[0]*alt, spn[1] + up[1]*alt, spn[2] + up[2]*alt)
    # aim = the limb (the preset's default aim: the tangent point of the
    # line of sight to the R disc)
    a = vs(pos, cen)
    D = math.sqrt(vd(a, a))
    th = math.acos(min(1.0, R / D))
    hd = vn(vx((0.0, 0.0, 1.0), vn(a)))
    tg = (cen[0] + up[0]*R*math.cos(th) + hd[0]*R*math.sin(th),
          cen[1] + up[1]*R*math.cos(th) + hd[1]*R*math.sin(th),
          cen[2] + up[2]*R*math.cos(th) + hd[2]*R*math.sin(th))
    d = vn(vs(tg, pos))
    right = vn(vx(d, up))

    disc_r = R + 126.0  # R + SEA (the body's own disc, the occlusion radius)
    n_sky, n_star, lum_min, lum_max, lum_sum = 0, 0, 1e9, 0.0, 0.0
    rowmed = []
    for y in range(H):
        vals = []
        for x in range(W):
            u = (2.0 * x / (W - 1)) - 1.0
            v = 1.0 - (2.0 * y / (H - 1))
            dd = vn((d[0] + right[0]*u*t + up[0]*v*t,
                     d[1] + right[1]*u*t + up[1]*v*t,
                     d[2] + right[2]*u*t + up[2]*v*t))
            # the ray's closest approach to the centre (impact parameter):
            # |cross(dir, origin - centre)|
            oc = (pos[0] - cen[0], pos[1] - cen[1], pos[2] - cen[2])
            b = math.sqrt(vd(vx(dd, oc), vx(dd, oc)))
            if b < disc_r + margin:
                continue  # inside the planet disc + margin: not sky
            L = lum(*px[x, y])
            vals.append(L)
            n_sky += 1
            if L > 40:
                n_star += 1
            if L < lum_min:
                lum_min = L
            if L > lum_max:
                lum_max = L
            lum_sum += L
        rowmed.append(vals[W//2] if len(vals) == W else (sorted(vals)[len(vals)//2] if vals else 0.0))
    # max single-row step of the full-width row medians (the drawn-edge hunt)
    full = []
    for y in range(H):
        allv = sorted(lum(*px[x, y]) for x in range(W))
        full.append(allv[W//2])
    best = (0.0, -1)
    for i in range(1, H):
        dd = abs(full[i] - full[i-1])
        if dd > best[0]:
            best = (dd, i)
    spread = lum_max - lum_min
    print("KIND skyband ALT_SAT %.0f (radial %.0f)" % (alt, D - R))
    print("sky pixels (outside R+SEA disc + %.0f m): %d" % (margin, n_sky))
    print("sky lum min/max/mean: %.2f / %.2f / %.2f  (spread %.2f)" %
          (lum_min, lum_max, lum_sum / max(1, n_sky), spread))
    print("star-like (lum > 40): %d" % n_star)
    print("full-frame row-median profile (y, lum) every 40 rows:")
    for y in range(0, H, 40):
        print("  row %4d  %7.2f" % (y, full[y]))
    print("  row %4d  %7.2f  <- last" % (H-1, full[H-1]))
    print("max single-row step (raw): %.2f at row %d" % best)
    sm = full
    for _ in range(4):
        sm = [sum(sm[max(0, i-1):i+2]) / len(sm[max(0, i-1):i+2]) for i in range(H)]
    b2 = (0.0, -1)
    for i in range(1, H):
        dd = abs(sm[i] - sm[i-1])
        if dd > b2[0]:
            b2 = (dd, i)
    print("max single-row step (5sm):  %.2f at row %d" % b2)

if __name__ == "__main__":
    main()
