#!/usr/bin/env python3
"""AC-0419 measurement: the sky frames, measured, not modelled.

Reads the 1280x720 planet-preset frames and reports:
  (a) DOME LUMINANCE - median RGB + luminance of the sky dome (zenith frames:
      the whole frame is sky; the sun disc is excluded as an outlier band).
  (b) RADIAL PROFILE + EDGE SCAN - nadir/limb frames: the row-median
      luminance along the camera axis (nadir frames: angle from nadir;
      limb frames: angle from the tangent-aim axis) with the angle mapped
      through the pinhole model tan(th) = v * tan(half_fov). An edge scan
      reports the largest single-row luminance steps: a BOUNDARY SURFACE
      reads as one big step in an otherwise smooth profile, a smooth
      integral as small distributed steps.
  (c) DECK VS HALO (space frames) - the deck ring is the bright cyan
      silhouette; the halo is the sky luminance between the disc and space.
      Reported: the deck-edge angle, the halo value at the deck edge, the
      half-peak angle, and the angle where the halo returns to space+3.

Usage: python3 measure.py <frame.png> <kind: zenith|nadir|limb> <alt_m> <R>
"""
import sys
import math
from array import array

def load_png(path):
    from PIL import Image
    im = Image.open(path).convert("RGB")
    return im

def lum(r, g, b):
    return 0.2126 * r + 0.7152 * g + 0.0722 * b

def main():
    path, kind, alt_s, R_s = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
    alt, R = alt_s, R_s
    im = load_png(path)
    W, H = im.size
    px = im.load()
    half_fov = 75.0 / 2.0  # main.gd _make_camera: c.fov = 75.0 (vertical)

    # per-row median luminance (full width)
    rowmed = []
    for y in range(H):
        vals = sorted(lum(*px[x, y]) for x in range(W))
        rowmed.append(vals[W // 2])
    # central column luminance (the exact radial scan: one ray angle per row)
    cx = W // 2
    colmed = [lum(*px[cx, y]) for y in range(H)]

    if kind == "zenith":
        # whole frame is the dome; exclude the sun (bright outlier rows are
        # fine: use the MEDIAN, and report the top-5% row for the sun side)
        allv = sorted(lum(*px[x, y]) for y in range(H) for x in range(W))
        n = len(allv)
        med = allv[n // 2]
        p10 = allv[int(n * 0.10)]
        p90 = allv[int(n * 0.90)]
        # median RGB
        rs = sorted(px[x, y][0] for y in range(0, H, 4) for x in range(0, W, 4))
        gs = sorted(px[x, y][1] for y in range(0, H, 4) for x in range(0, W, 4))
        bs = sorted(px[x, y][2] for y in range(0, H, 4) for x in range(0, W, 4))
        m = len(rs)
        print("KIND zenith  alt=%.0f R=%.0f" % (alt, R))
        print("  dome median luminance = %.1f /255 (p10 %.1f, p90 %.1f)" % (med, p10, p90))
        print("  dome median RGB = (%d, %d, %d)" % (rs[m // 2], gs[m // 2], bs[m // 2]))
        # edge scan along rows (a circle crossing the dome reads as a row step)
        diffs = [(abs(rowmed[y + 1] - rowmed[y]), y) for y in range(H - 1)]
        diffs.sort(reverse=True)
        print("  top row steps (|dL|, row, angle_from_zenith):")
        for d, y in diffs[:8]:
            v = (y - H / 2.0) / (H / 2.0)
            th = math.degrees(math.atan(abs(v) * math.tan(math.radians(half_fov))))
            print("    dL=%.1f  row=%d  %.1f deg" % (d, y, th))
        return

    # nadir / limb: profile along the camera axis (rows 0..H/2 = away from the
    # aim point; the aim point is the frame centre)
    d = R + alt
    if kind == "nadir":
        # aim = nadir; row y -> angle from nadir
        def ang_from_nadir(y):
            v = (y - H / 2.0) / (H / 2.0)
            return math.degrees(math.atan(abs(v) * math.tan(math.radians(half_fov))))
    else:
        # aim = the R-sphere tangent; the aim axis sits asin(R/d) from nadir
        aim_off = math.degrees(math.asin(min(1.0, R / d)))
        def ang_from_nadir(y):
            v = (y - H / 2.0) / (H / 2.0)
            th = math.degrees(math.atan(abs(v) * math.tan(math.radians(half_fov))))
            # upper rows: away from the planet (larger angle from nadir);
            # lower rows: toward the disc (smaller angle from nadir)
            return aim_off + th if y < H / 2.0 else aim_off - th
    print("KIND %s  alt=%.0f R=%.0f d=%.0f  (row->angle-from-nadir; nadir-frame centre = 0 deg)" % (kind, alt, R, d))
    # reference angles for the named structures
    def a_from_nadir(radius):
        if radius > d:
            return None  # tangent does not exist (camera inside)
        return math.degrees(math.asin(radius / d))
    refs = {"disc(R)": a_from_nadir(R), "R+SEA": a_from_nadir(R + 126.0),
            "deck_top(R+450)": a_from_nadir(R + 450.0),
            "A_shell(R+1200)": a_from_nadir(R + 1200.0),
            "tail(R+1500)": a_from_nadir(R + 1500.0)}
    print("  reference angles from nadir: " +
          "  ".join("%s=%s" % (k, ("n/a-inside" if v is None else "%.1f" % v)) for k, v in refs.items()))
    # profile: rows 0..H (upper half = the sky side of the aim axis)
    print("  profile CENTRAL COLUMN (row: angle_from_nadir  L=central-col luminance):")
    for y in range(0, H, max(1, H // 40)):
        print("    row=%3d  %.1f deg  L=%.1f" % (y, ang_from_nadir(y), colmed[y]))
    print("  profile ROW-MEDIAN (row: angle_from_nadir  L=median luminance):")
    for y in range(0, H, max(1, H // 40)):
        print("    row=%3d  %.1f deg  L=%.1f" % (y, ang_from_nadir(y), rowmed[y]))
    # edge scan over the whole frame (row medians)
    diffs = [(abs(rowmed[y + 1] - rowmed[y]), y) for y in range(H - 1)]
    diffs.sort(reverse=True)
    print("  top row steps (|dL|, row, angle_from_nadir):")
    for dd, y in diffs[:8]:
        print("    dL=%.1f  row=%d  %.1f deg" % (dd, y, ang_from_nadir(y)))
    # central-column edge scan (the exact radial boundary check)
    cdiffs = [(abs(colmed[y + 1] - colmed[y]), y) for y in range(H - 1)]
    cdiffs.sort(reverse=True)
    print("  top central-column steps (|dL|, row, angle_from_nadir):")
    for dd, y in cdiffs[:8]:
        print("    dL=%.1f  row=%d  %.1f deg" % (dd, y, ang_from_nadir(y)))
    # deck vs halo (space frames): the deck ring = the luminance peak in the
    # band around the deck-top angle (central column = exact radial scan)
    def row_at_angle(target):
        cand = [y for y in range(H) if abs(ang_from_nadir(y) - target) < 0.4]
        return cand[len(cand) // 2] if cand else None
    if refs["deck_top(R+450)"] is not None:
        best = row_at_angle(refs["deck_top(R+450)"])
        win = 70
        if best is not None:
            lo_i = max(0, best - win)
            hi_i = min(H, best + win)
            seg = colmed[lo_i:hi_i]
            peak_l = max(seg)
            peak_row = lo_i + seg.index(peak_l)
            print("  deck band: near angle %.1f -> local peak L=%.1f at row=%d (%.1f deg)"
                  % (refs["deck_top(R+450)"], peak_l, peak_row, ang_from_nadir(peak_row)))
            space_l = min(colmed[:H // 4])  # the frame-top rows are pure space
            print("  space level (frame top, central col): L=%.1f" % space_l)
            # outward walk from the deck angle: report L at +5, +10, ... deg
            for ddeg in (5.0, 10.0, 15.0, 20.0, 25.0):
                yy = row_at_angle(refs["deck_top(R+450)"] + ddeg)
                if yy is not None:
                    print("    halo at +%.0f deg (%.1f): L=%.1f  (above space by %.1f)"
                          % (ddeg, refs["deck_top(R+450)"] + ddeg, colmed[yy], colmed[yy] - space_l))

if __name__ == "__main__":
    main()
