#!/usr/bin/env python3
"""AC-0483 column profile: the pixel column(s) through where the synthetic
local-horizon band was.

Frames are 1280x720 planet-preset shots (FOV 75 deg vertical), seed 44.
Camera basis is recomputed from the preset contract (harness.gd planet
branch, horizon aim): pos = spawn + up*alt, up = (spawn - centre)/|..|,
centre (0, -R, 0), R = 4000, aim dir = the in-plane tangent reference
hd = normalize(cross((0,0,1), pos-centre)) (the local horizon hl = 0 sits
at the frame centre row).

hl = dot(dir, up) is the LOCAL ELEVATION (1 = straight up, 0 = local
horizontal, negative below). The removed band lived exactly at hl = 0.

Kinds:
  col   frame alt sx sy sz [win_deg] -> the centre column through the band:
        every row's (row, hl_deg, R, G, B, lum) for |hl| <= win (default 6),
        plus per-column statistics over the whole window band: the max
        single-row |step| (raw and 5-smoothed luminance) with its row and
        hl, and the sign-change count of the 3-smoothed first difference
        (a stripe/bump = non-monotonic extremum at/near the horizon row;
        a floor = one big step to a different flat colour; a kink = a
        first-difference reversal). A smooth sky through local horizontal
        = small, distributed steps, no single dominant step at hl ~ 0.
        Also the full-frame row-median profile (y, lum) every 20 rows,
        like the AC-0439 lineage, for the silhouette/limb landmarks.

Usage:
  python3 colprof.py col <frame.png> <alt> <sx> <sy> <sz> [win_deg]
"""
import math
import sys

from PIL import Image

R = 4000.0
FOV = 75.0
W, H = 1280, 720
HALF = math.tan(math.radians(FOV / 2.0))


def vsub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def vadd(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def vmul(a, s):
    return (a[0] * s, a[1] * s, a[2] * s)


def vdot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def vcross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0])


def vlen(a):
    return math.sqrt(vdot(a, a))


def vnorm(a):
    l = vlen(a)
    return (a[0] / l, a[1] / l, a[2] / l)


def lum(r, g, b):
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def basis(alt, spawn):
    cen = (0.0, -R, 0.0)
    spn = (spawn[0], spawn[1], spawn[2])
    up = vnorm(vsub(spn, cen))
    pos = vadd(spn, vmul(up, alt))
    a = vsub(pos, cen)
    ref = (0.0, 0.0, 1.0)
    if abs(vdot(a, ref)) > 0.99:
        ref = (1.0, 0.0, 0.0)
    hd = vnorm(vcross(ref, a))
    right = vnorm(vcross(hd, up))
    return pos, up, hd, right


def hl_grid(pos, up, d, right):
    grid = []
    for y in range(H):
        v = 1.0 - (2.0 * y / (H - 1))
        row = []
        for x in range(W):
            u = (2.0 * x / (W - 1)) - 1.0
            dir = vnorm(vadd(vadd(d, vmul(right, u * HALF)), vmul(up, v * HALF)))
            row.append(vdot(dir, up))
        grid.append(row)
    return grid


def smooth3(vals):
    out = []
    for i in range(len(vals)):
        s = vals[max(0, i - 1):i + 2]
        out.append(sum(s) / len(s))
    return out


def smooth5(vals):
    out = []
    for i in range(len(vals)):
        s = vals[max(0, i - 2):i + 3]
        out.append(sum(s) / len(s))
    return out


def main():
    args = sys.argv[1:]
    if args and args[0] == "col":
        args = args[1:]
    if len(args) < 5:
        print(__doc__)
        sys.exit(2)
    path = args[0]
    alt = float(args[1])
    spawn = tuple(float(v) for v in args[2:5])
    win = float(args[5]) if len(args) > 5 else 6.0
    winr = math.radians(win)

    im = Image.open(path).convert("RGB")
    px = im.load()
    pos, up, d, right = basis(alt, spawn)
    grid = hl_grid(pos, up, d, right)
    print("KIND col ALT_SAT %.0f (radial %.0f) WIN %.1f deg" %
          (alt, vlen(vsub(pos, (0.0, -R, 0.0))) - R, win))
    print("pos %s  aim hl(centre row) = %.4f" %
          (" ".join("%.1f" % v for v in pos), grid[H // 2][W // 2]))

    # per-column statistics over the |hl| <= win window.
    # BAND TESTS (the removed feature lived exactly at hl = 0, full width):
    #  (a) crossing  = |lum 3 rows below hl=0 minus 3 rows above| per column
    #      (a floor / two-colour meeting shows as a large crossing in MOST
    #      columns; a smooth gradient shows the local slope only);
    #  (b) bump      = |lum AT the closest row minus the mean of the rows
    #      6 above / below| (the hz stripe peaks exactly at hl = 0);
    #  (c) reversals = sign changes of the 5-smoothed first difference
    #      (a stripe/bump reverses the profile at the horizon row).
    worst_raw = (0.0, -1, -1.0)   # (step, row, hl)
    worst_sm = (0.0, -1, -1.0)
    cross, bumps, revs, rcross, rbumps = [], [], [], [], []
    n_cols_in = 0
    for x in range(W):
        rows = []
        for y in range(H):
            if abs(grid[y][x]) <= winr:
                c = px[x, y]
                rows.append((y, grid[y][x], lum(*c), c[0]))
        if len(rows) < 16:
            continue
        n_cols_in += 1
        y0 = min(rows, key=lambda t: abs(t[1]))[0]  # row closest to hl = 0
        y0l, y0u = y0 - 3, y0 + 3
        yl = [r for r in rows if abs(r[0] - y0l) <= 1]
        yu = [r for r in rows if abs(r[0] - y0u) <= 1]
        if yl and yu:
            cross.append(abs(yu[0][2] - yl[0][2]))
            rcross.append(abs(yu[0][3] - yl[0][3]))
        ym = [r for r in rows if abs(r[0] - y0) <= 1]
        ya = [r for r in rows if abs(r[0] - (y0 - 6)) <= 1]
        yb = [r for r in rows if abs(r[0] - (y0 + 6)) <= 1]
        if ym and ya and yb:
            bumps.append(abs(ym[0][2] - 0.5 * (ya[0][2] + yb[0][2])))
            rbumps.append(abs(ym[0][3] - 0.5 * (ya[0][3] + yb[0][3])))
        lums = [r[2] for r in rows]
        sm = smooth5(lums)
        d = [sm[i] - sm[i - 1] for i in range(1, len(sm))]
        revs.append(sum(1 for i in range(1, len(d)) if d[i] * d[i - 1] < 0))
        for i in range(1, len(lums)):
            dd = abs(lums[i] - lums[i - 1])
            if dd > worst_raw[0]:
                worst_raw = (dd, rows[i][0], rows[i][1] * (180.0 / math.pi))
            ds = abs(sm[i] - sm[i - 1])
            if ds > worst_sm[0]:
                worst_sm = (ds, rows[i][0], rows[i][1] * (180.0 / math.pi))
    import statistics as st

    def pct(v, p):
        if not v:
            return 0.0
        s = sorted(v)
        return s[min(len(s) - 1, int(p * len(s)))]

    print("columns with >=16 in-window rows: %d" % n_cols_in)
    print("max single-row step (raw)   : %.2f/255 at row %d (hl %.2f deg)" % worst_raw)
    print("max single-row step (5sm)   : %.2f/255 at row %d (hl %.2f deg)" % worst_sm)
    if cross:
        print("horizon crossing |lum(+0.12deg) - lum(-0.12deg)| per column: "
              "mean %.2f  median %.2f  p95 %.2f  max %.2f (of 255)"
              % (st.mean(cross), st.median(cross), pct(cross, 0.95), max(cross)))
        print("  columns with crossing > 5/255 : %d / %d (%.0f%%)"
              % (sum(1 for v in cross if v > 5.0), len(cross),
                 100.0 * sum(1 for v in cross if v > 5.0) / len(cross)))
        print("  columns with crossing > 15/255: %d / %d (%.0f%%)"
              % (sum(1 for v in cross if v > 15.0), len(cross),
                 100.0 * sum(1 for v in cross if v > 15.0) / len(cross)))
        print("R-channel crossing (the band's channel, |dR=15|) per column: "
              "mean %.2f  median %.2f  p95 %.2f  max %.2f (of 255)"
              % (st.mean(rcross), st.median(rcross), pct(rcross, 0.95), max(rcross)))
        print("  columns with R crossing > 8/255: %d / %d (%.0f%%)"
              % (sum(1 for v in rcross if v > 8.0), len(rcross),
                 100.0 * sum(1 for v in rcross if v > 8.0) / len(rcross)))
        print("R-channel hl=0 stripe bump per column: mean %.2f  median %.2f  p95 %.2f  max %.2f (of 255)"
              % (st.mean(rbumps), st.median(rbumps), pct(rbumps, 0.95), max(rbumps)))
        print("  columns with R bump > 4/255: %d / %d (%.0f%%)"
              % (sum(1 for v in rbumps if v > 4.0), len(rbumps),
                 100.0 * sum(1 for v in rbumps if v > 4.0) / len(rbumps)))
    if bumps:
        print("hl=0 stripe bump |lum(hl=0) - mean(nei +-6rows)| per column: "
              "mean %.2f  median %.2f  p95 %.2f  max %.2f (of 255)"
              % (st.mean(bumps), st.median(bumps), pct(bumps, 0.95), max(bumps)))
        print("  columns with bump > 4/255 : %d / %d (%.0f%%)"
              % (sum(1 for v in bumps if v > 4.0), len(bumps),
                 100.0 * sum(1 for v in bumps if v > 4.0) / len(bumps)))
    if revs:
        print("profile reversals (5sm) per column: mean %.2f  max %d "
              "(a smooth gradient reverses a few times; a stripe adds one AT the horizon)"
              % (st.mean(revs), max(revs)))

    # the centre column, every row in |hl| <= win
    x = W // 2
    print("centre column x=%d (row, hl_deg, R, G, B, lum):" % x)
    for y in range(H):
        hl = grid[y][x]
        if abs(hl) <= winr:
            c = px[x, y]
            print("  row %4d  hl %+8.2f  %3d %3d %3d  %7.2f" %
                  (y, hl * (180.0 / math.pi), c[0], c[1], c[2], lum(*c)))

    # full-frame row-median profile (the AC-0439 lineage landmark view)
    print("full-frame row-median lum every 20 rows:")
    for y in range(0, H, 20):
        vals = sorted(lum(*px[x2, y]) for x2 in range(W))
        print("  row %4d  %7.2f" % (y, vals[W // 2]))
    vals = sorted(lum(*px[x2, H - 1]) for x2 in range(W))
    print("  row %4d  %7.2f  <- last" % (H - 1, vals[W // 2]))


if __name__ == "__main__":
    main()
