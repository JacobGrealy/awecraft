#!/usr/bin/env python3
"""AC-0428 measurements: the three instruments this ticket needs.

All frames are 1280x720 planet-preset shots (FOV 75 deg vertical), seed 44,
T = 0.5 (noon). Camera basis is recomputed here from the preset contract
(harness.gd planet branch): pos = spawn + up*alt, up = (spawn - centre)/|..|,
centre (0, -R, 0), R = 4000; optional CAM_OFF in-plane offset is re-applied
exactly as harness.gd does (project off the radial, then project the point
onto the R sphere).

Pinhole model (the AC-0422 measure.py convention):
  tan(theta) = v * tan(half_fov), v the normalised offset;
  dir = normalize(aim_dir + u*tan(h)*right + v*tan(h)*up_vec)

Kinds
  profile  frame aim alt spawn -> the luminance profile down the frame:
           row medians, max single-row step (raw + 5-smoothed), thirds,
           the step at the frame-centre row (the local horizon in the
           horizon aim). A DRAWN edge is one big single-row step; a
           computed gradient is small distributed steps.
  disc     frame aim alt spawn -> the body coverage / opacity instrument:
           the analytic silhouette (b = |cross(cam-centre, dir)| vs the
           R+SEA disc and an INNER disc at R+250, well inside the body's
           displaced silhouette and outside the haz_a limb-haze band).
           Inside the inner disc the body must own every pixel: the
           classifier is LOCAL TEXTURE VARIANCE - the baked terrain is
           strongly textured (the fixed-sun lambert + height relief),
           the sky's below-branch fill is flat (u_air + a smooth haze
           band). Leak = fraction of inner-disc pixels with low local
           variance and sky-like mean (a sky seen through the body).
           Also reports the row-median luminance INSIDE the disc (a
           see-through disc reads as the flat u_air value).
  diff     base ref frame aim alt spawn -> the cloud instrument:
           per-pixel |dL| between the base frame and a clouds-off (or
           clouds-changed) reference, restricted to the inner disc:
           fraction above a delta (the cloud-covered fraction), the
           mean dL and the max dL. With AWECRAFT_CLOUDS=0 as the
           reference, every pixel that differs is cloud material -
           including the FAR-SIDE deck if the volume leaks it.
  skyfit   frame aim alt spawn -> fit a per-channel affine display
           transform to the pure-sky model (the aero_sky_gradient sky_on
           expression at T=0.5, all uniforms from the shipped constants)
           on pixels outside the R+SEA disc and away from the disc edge;
           reports the per-channel fit + residual max/mean (how faithfully
           the measured sky follows the computed model - the line hunt).

Usage:
  python3 measure.py <kind> <frame.png> <aim> <alt> <sx> <sy> <sz> [ox oz]
  aim in {nadir, zenith, horizon}
  python3 measure.py diff <base.png> <ref.png> <aim> <alt> <sx> <sy> <sz> [ox oz]
"""
import math
import sys
from PIL import Image

R = 4000.0
SEA = 126.0
FOV = 75.0
W, H = 1280, 720
HALF = math.tan(math.radians(FOV / 2.0))

# T = 0.5 (noon) display-space constants (aero.gd, main.gd pushes).
ZEN = (46.0 / 255, 134.0 / 255, 216.0 / 255)
MID = (95.0 / 255, 198.0 / 255, 234.0 / 255)
HOR = (223.0 / 255, 246.0 / 255, 251.0 / 255)
HAZE = (186.0 / 255, 233.0 / 255, 250.0 / 255)
HAZE_AMT = 0.4
SPACE = (2.0 / 255, 3.0 / 255, 10.0 / 255)
A = 1200.0
BAND_LO, BAND_HI = 500.0, 2000.0  # player.BAND_WALK_MAX/BAND_FLY_MIN (main.gd space_t)
AIR = tuple(HOR[i] * 0.6 + HAZE[i] * 0.4 for i in range(3))  # fog_display_srgb(0.5)
SUN_BODY = (0.0, 1.0, 0.4)
SUN_BODY = tuple(v / math.sqrt(sum(x * x for x in SUN_BODY)) for v in SUN_BODY)
SUN_HALO = (255.0 / 255, 246.0 / 255, 222.0 / 255)
LIMB_AMT = 0.55


def vsub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def vadd(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def vmul(a, s):
    return (a[0] * s, a[1] * s, a[2] * s)


def vdot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def vcross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def vlen(a):
    return math.sqrt(vdot(a, a))


def vnorm(a):
    l = vlen(a)
    return (a[0] / l, a[1] / l, a[2] / l)


def mixc(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def sstep(e0, e1, x):
    t = min(1.0, max(0.0, (x - e0) / (e1 - e0)))
    return t * t * (3.0 - 2.0 * t)


def basis(aim, alt, spawn, off=(0.0, 0.0)):
    cen = (0.0, -R, 0.0)
    spn = (spawn[0], spawn[1], spawn[2])
    up = vnorm(vsub(spn, cen))
    if off != (0.0, 0.0):
        o = (off[0], 0.0, off[1])
        prj = vsub(o, vmul(up, vdot(o, up)))
        pt = vadd(spn, prj)
        pt = vadd(cen, vmul(vnorm(vsub(pt, cen)), R))
        spn = pt
        up = vnorm(vsub(spn, cen))
    pos = vadd(spn, vmul(up, alt))
    if aim == "nadir":
        ref = (0.0, 0.0, 1.0)
        hd = vnorm(vcross(ref, up)) if abs(vdot(up, ref)) < 0.99 else vnorm(vcross((1.0, 0.0, 0.0), up))
        d = vmul(up, -1.0)
    elif aim == "zenith":
        ref = (0.0, 0.0, 1.0)
        hd = vnorm(vcross(ref, up)) if abs(vdot(up, ref)) < 0.99 else vnorm(vcross((1.0, 0.0, 0.0), up))
        d = up
    elif aim == "horizon":
        a = vsub(pos, cen)
        ref = (0.0, 0.0, 1.0)
        if abs(vdot(a, ref)) > 0.99:
            ref = (1.0, 0.0, 0.0)
        hd = vnorm(vcross(ref, a))
        d = hd
    elif aim == "limb":
        # AC-0429: the planet preset's DEFAULT aim (harness.gd: the
        # tangent point of the line of sight to the R disc) -
        # t = cen + up*(R*cos(th)) + hd*(R*sin(th)), cos(th) = R/|pos-cen|,
        # d = normalize(t - pos).
        a = vsub(pos, cen)
        D = vlen(a)
        th = math.acos(min(1.0, R / D))
        ref = (0.0, 0.0, 1.0)
        if abs(vdot(a, ref)) > 0.99:
            ref = (1.0, 0.0, 0.0)
        hd = vnorm(vcross(ref, a))
        t = vadd(cen, vadd(vmul(up, R * math.cos(th)),
                           vmul(hd, R * math.sin(th))))
        d = vnorm(vsub(t, pos))
    else:
        raise SystemExit("unknown aim " + aim)
    return pos, up, d, hd


def pidx(u, v):
    x = int((u + 1.0) * 0.5 * (W - 1))
    y = int((1.0 - v) * 0.5 * (H - 1))
    return min(W - 1, max(0, x)), min(H - 1, max(0, y))


def pixdir(u, v, d, hd, up):
    rgt = vcross(up, d)
    if vlen(rgt) < 1e-6:  # nadir/zenith: d is the radial, hd is the horizontal right
        rgt = hd
    rgt = vnorm(rgt)
    return vnorm(vadd(vadd(d, vmul(rgt, u * HALF)), vmul(up, v * HALF)))


def sky_on(direction, pos):
    """aero_sky_gradient sky_on, T=0.5, u_sky_alt=1, u_horizon=1, display space."""
    cen = (0.0, -R, 0.0)
    c = vsub(pos, cen)
    r = vlen(c)
    up = vnorm(c)
    hl = vdot(direction, up)
    under_disc = 1.0 if r < R + SEA else 0.0
    below_soft = max(under_disc, sstep(0.0, 0.03, -hl))
    below = below_soft  # u_horizon = 1
    u = min(1.0, max(0.0, hl))
    grad = mixc(HOR, MID, sstep(0.0, 0.3, u))
    grad = mixc(grad, ZEN, sstep(0.25, 0.9, u))
    w = sstep(BAND_LO, BAND_HI, r - R)  # main.gd space_t (flight band)
    thin = (w * w + u * (w - w * w)) * u  # mix(w*w,w,u) * u  (u_horizon = 1)
    above = mixc(grad, SPACE, thin)
    belowc = AIR  # mix(mix(space, air, 1-w), air, 1)
    col = mixc(above, belowc, below)
    hz = math.exp(-9.0 * abs(hl)) * HAZE_AMT * (1.0 - w)
    col = mixc(col, HAZE, hz)
    # the AC-0419 air-column limb term
    b = vlen(vcross(up, direction))
    rout = R + A + 0.25 * A
    if b < rout:
        half = math.sqrt(max(0.0, rout * rout - b * b))
        s_exit = -r * hl + half
        air = min(2.0 * half, s_exit)
        cm = 2.0 * math.sqrt(max(1e-9, rout * rout - (R + SEA) ** 2))
        limb = min(1.0, air / cm)
        limb_col = mixc(HOR, MID, 0.5)
        sun_side = 0.55 + 0.6 * max(vdot(vnorm(vsub(cen, pos)), SUN_BODY), 0.0)
        col = vadd(col, vmul(limb_col, limb * LIMB_AMT * sun_side * w))
    # the sun (display-space terms)
    sd = vdot(direction, SUN_BODY)
    upc = max(0.0, min(1.0, sd))
    disc = sstep(0.99894, 0.99985, sd)
    glow = (upc ** 24.0 * 0.60 + upc ** 5.0 * 0.22) * (1.0 - w)
    col = vadd(col, vmul((1.0, 1.0, 1.0), disc))
    col = vadd(col, vmul(SUN_HALO, glow))
    return col


def lum(c):
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def load(frame):
    im = Image.open(frame).convert("RGB")
    return im, im.load()


def rows(aim, alt, spawn, off=(0.0, 0.0)):
    """per-row: (y, hl_row, median luminance) for the whole frame."""
    pos, up, d, hd = basis(aim, alt, spawn, off)
    im, px = load(0) if False else (None, None)
    return pos, up, d, hd


def profile(frame, aim, alt, spawn, off=(0.0, 0.0)):
    pos, up, d, hd = basis(aim, alt, spawn, off)
    im, px = load(frame)
    r0 = (vlen(vsub(pos, (0.0, -R, 0.0))) - R)
    print("camera radial altitude above R sphere: %.1f m (alt param %.1f)" % (r0, alt))
    print("w (sky space_t) = %.3f" % sstep(BAND_LO, BAND_HI, r0))
    rowlum = []
    for y in range(H):
        vals = []
        for x in range(0, W, 2):
            u = 2.0 * (x + 0.5) / W - 1.0
            v = 1.0 - 2.0 * (y + 0.5) / H
            rd = pixdir(u, v, d, hd, up)
            p = px[x, y]
            vals.append(lum((p[0] / 255.0, p[1] / 255.0, p[2] / 255.0)))
        vals.sort()
        rowlum.append(vals[len(vals) // 2])
    steps = [rowlum[i + 1] - rowlum[i] for i in range(H - 1)]
    smooth = [rowlum[i] for i in range(0, H - 4)]
    sm = [(sum(rowlum[i:i + 5]) / 5.0) for i in range(H - 4)]
    ssteps = [sm[i + 1] - sm[i] for i in range(len(sm) - 1)]
    print("row-median luminance profile (255 scale):")
    for y in range(0, H, 20):
        print("  row %3d  %7.2f" % (y, rowlum[y] * 255.0))
    print("  row %3d  %7.2f  <- last" % (H - 1, rowlum[-1] * 255.0))
    print("max single-row step (raw):   %7.2f" % (max(steps) * 255.0))
    print("max single-row step (5sm):   %7.2f" % (max(ssteps) * 255.0))
    print("min single-row step (raw):   %7.2f" % (min(steps) * 255.0))
    third = H // 3
    t1 = sum(rowlum[:third]) / third
    t2 = sum(rowlum[third:2 * third]) / third
    t3 = sum(rowlum[2 * third:]) / (H - 2 * third)
    print("thirds (top/mid/bottom): %7.2f / %7.2f / %7.2f" % (t1 * 255, t2 * 255, t3 * 255))
    # rate uniformity: the step magnitude per 20-row band across the frame
    bands = []
    for b0 in range(0, H - 20, 20):
        band = [abs(s) for s in steps[b0:b0 + 20]]
        bands.append(sum(band) / len(band))
    if bands:
        print("mean |step| per 20-row band (top->bottom, 255 scale):")
        print("  " + "  ".join("%.2f" % (b * 255) for b in bands))
        print("  band max/min ratio: %.2f" % (max(bands) / max(1e-9, min(bands))))
    mid = H // 2
    print("step at frame-centre row (%d->%d): %7.2f" % (mid - 1, mid, (rowlum[mid] - rowlum[mid - 1]) * 255.0))


def innerdisc(x, y, pos, up, d, hd, rinner):
    u = 2.0 * (x + 0.5) / W - 1.0
    v = 1.0 - 2.0 * (y + 0.5) / H
    rd = pixdir(u, v, d, hd, up)
    c = vsub(pos, (0.0, -R, 0.0))
    b = vlen(vcross(vnorm(c), rd))
    return b


def disc(frame, aim, alt, spawn, off=(0.0, 0.0), rinner=R + 250.0):
    pos, up, d, hd = basis(aim, alt, spawn, off)
    im, px = load(frame)
    inside = []
    outl = []
    for y in range(0, H, 2):
        for x in range(0, W, 2):
            b = innerdisc(x, y, pos, up, d, hd, rinner)
            p = px[x, y]
            L = lum((p[0] / 255.0, p[1] / 255.0, p[2] / 255.0))
            (inside if b < rinner else outl).append((L, p))
    inl = [L for L, _ in inside]
    outl = [L for L, _ in outl]
    inl.sort()
    outl.sort()
    n = len(inside)
    print("inner disc (b < %.0f m): %d px (stride 2), outside: %d px" % (rinner, n, len(outl)))
    if n:
        print("  inside  L median %7.2f  p10 %7.2f  p90 %7.2f" % (
            inl[n // 2] * 255, inl[n // 10] * 255, inl[n * 9 // 10] * 255))
    if outl:
        print("  outside L median %7.2f  (the sky)" % (outl[len(outl) // 2] * 255))
    # texture-variance classifier: 5x5 local variance of luminance at stride 2
    imf = im
    arr = imf.load()
    leak = 0
    total = 0
    leakL = []
    for y in range(2, H - 2, 2):
        for x in range(2, W - 2, 2):
            b = innerdisc(x, y, pos, up, d, hd, rinner)
            if b >= rinner:
                continue
            vals = []
            for dy in range(-2, 3, 2):
                for dx in range(-2, 3, 2):
                    p = arr[x + dx, y + dy]
                    vals.append(lum((p[0] / 255.0, p[1] / 255.0, p[2] / 255.0)))
            m = sum(vals) / len(vals)
            var = sum((s - m) ** 2 for s in vals) / len(vals)
            sd = math.sqrt(var)
            total += 1
            # sky-like: flat (low local sd) AND within 0.06 of the outside
            # (sky) median luminance - a sky seen through the body
            if sd < 0.015 and outl and abs(m - outl[len(outl) // 2]) < 0.06:
                leak += 1
                leakL.append(m)
    if total:
        print("body coverage (inner disc): %d px classified" % total)
        print("  LEAK (sky-like flat pixels inside the disc): %d = %.2f%%" % (
            leak, 100.0 * leak / total))
        if leakL:
            leakL.sort()
            print("  leak-pixel L median %.2f (sky outside %.2f)" % (
                leakL[len(leakL) // 2] * 255, outl[len(outl) // 2] * 255))
        print("  body-covered fraction: %.2f%%" % (100.0 * (total - leak) / total))
    # row medians inside the disc only (a see-through disc reads flat)
    rows_in = {}
    for y in range(0, H, 4):
        rowv = []
        for x in range(0, W, 2):
            b = innerdisc(x, y, pos, up, d, hd, rinner)
            if b < rinner:
                p = arr[x, y]
                rowv.append(lum((p[0] / 255.0, p[1] / 255.0, p[2] / 255.0)))
        if rowv:
            rows_in[y] = sorted(rowv)[len(rowv) // 2]
    print("  row-median L inside the disc (y: L, 255 scale):")
    for y in sorted(rows_in):
        if y % 40 == 0 or y > H - 40:
            print("    row %3d  %7.2f" % (y, rows_in[y] * 255.0))


def diff(base, ref, aim, alt, spawn, off=(0.0, 0.0), rinner=R + 250.0, delta=6.0):
    pos, up, d, hd = basis(aim, alt, spawn, off)
    ima, pa = load(base)
    imb, pb = load(ref)
    n = 0
    hit = 0
    dsum = 0.0
    dmax = 0.0
    hitL = []
    for y in range(0, H, 2):
        for x in range(0, W, 2):
            b = innerdisc(x, y, pos, up, d, hd, rinner)
            if b >= rinner:
                continue
            a = pa[x, y]
            c = pb[x, y]
            da = lum((a[0] / 255.0, a[1] / 255.0, a[2] / 255.0))
            dc = lum((c[0] / 255.0, c[1] / 255.0, c[2] / 255.0))
            dd = abs(da - dc) * 255.0
            n += 1
            dsum += dd
            dmax = max(dmax, dd)
            if dd > delta:
                hit += 1
                hitL.append(dd)
    if n:
        print("inner disc: %d px compared (stride 2), delta = %.0f (255 scale)" % (n, delta))
        print("  differing fraction: %d = %.2f%%" % (hit, 100.0 * hit / n))
        print("  mean |dL|: %.2f  max |dL|: %.2f" % (dsum / n, dmax))
        if hitL:
            hitL.sort()
            print("  differing-pixel dL median %.2f  p90 %.2f" % (
                hitL[len(hitL) // 2], hitL[len(hitL) * 9 // 10]))


def skyfit(frame, aim, alt, spawn, off=(0.0, 0.0), rdisc=R + SEA):
    pos, up, d, hd = basis(aim, alt, spawn, off)
    im, px = load(frame)
    # collect (model, measured) pairs: outside the disc, 40px margin from edge
    pairs = []
    for y in range(0, H, 2):
        for x in range(0, W, 2):
            b = innerdisc(x, y, pos, up, d, hd, rdisc)
            if b < rdisc + 40.0:
                continue
            u = 2.0 * (x + 0.5) / W - 1.0
            v = 1.0 - 2.0 * (y + 0.5) / H
            rd = pixdir(u, v, d, hd, up)
            m = sky_on(rd, pos)
            p = px[x, y]
            pairs.append((m, (p[0] / 255.0, p[1] / 255.0, p[2] / 255.0)))
    # per-channel affine fit measured = s * model + o (least squares)
    print("sky model fit on %d pure-sky px (outside the R+SEA disc + 40px):" % len(pairs))
    for ch in range(3):
        xs = [p[0][ch] for p in pairs]
        ys = [p[1][ch] for p in pairs]
        n = len(xs)
        sx = sum(xs)
        sy = sum(ys)
        sxx = sum(a * a for a in xs)
        sxy = sum(a * b for a, b in zip(xs, ys))
        den = n * sxx - sx * sx
        s = (n * sxy - sx * sy) / den if den else 1.0
        o = (sy - s * sx) / n
        resid = [abs((s * a + o) - b) * 255.0 for a, b in zip(xs, ys)]
        resid.sort()
        print("  ch%d: s=%.4f o=%.4f  resid mean %.2f max %.2f p95 %.2f (255 scale)" % (
            ch, s, o, sum(resid) / len(resid), resid[-1], resid[int(len(resid) * 0.95)]))


def main():
    a = sys.argv[1:]
    if a[0] == "profile":
        profile(a[1], a[2], float(a[3]), (float(a[4]), float(a[5]), float(a[6])),
                (float(a[7]), float(a[8])) if len(a) > 8 else (0.0, 0.0))
    elif a[0] == "disc":
        disc(a[1], a[2], float(a[3]), (float(a[4]), float(a[5]), float(a[6])),
             (float(a[7]), float(a[8])) if len(a) > 8 else (0.0, 0.0))
    elif a[0] == "diff":
        off = (float(a[9]), float(a[10])) if len(a) > 10 else (0.0, 0.0)
        diff(a[1], a[2], a[3], float(a[4]), (float(a[5]), float(a[6]), float(a[7])), off)
    elif a[0] == "skyfit":
        skyfit(a[1], a[2], float(a[3]), (float(a[4]), float(a[5]), float(a[6])),
               (float(a[7]), float(a[8])) if len(a) > 8 else (0.0, 0.0))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
