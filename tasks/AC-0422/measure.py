#!/usr/bin/env python3
"""AC-0422 measurement: the luminance profile down the frame, measured, not modelled.

The acceptance is a profile, because a profile is what distinguishes a
computed gradient from a drawn edge: a hard straight edge reads as one big
single-row step in an otherwise smooth profile; a computed gradient reads
as small distributed steps.

Kinds (all 1280x720 planet-preset frames, fov 75 deg vertical, the
pinhole model tan(th) = v * tan(half_fov), v the normalised row offset):

  horizon  - the user's frame: the local horizon (hl = 0) at the frame
             centre (AWECRAFT_CAM_HORIZON=1). Reports:
               * the row-median luminance profile down the frame (table),
               * the max single-row step of the raw profile and of the
                 5-row-smoothed profile (a drawn edge = one big step;
                 a computed gradient = many small ones),
               * the step at the horizon row (frame centre) and the
                 step at the fog-wall row if detectable,
               * top/mid/bottom third means.
  zenith   - straight up the local radial (AWECRAFT_CAM_ZENITH=1): the
             whole frame is sky. Reports the whole-frame luminance
             median + p10/p90 (the "sky is space at A" check: dark at
             high altitude; the "day sky is bright" check at ground).
  limb     - out at the tangent limb (the default planet aim): reports
             the radial profile (row-median luminance vs angle from the
             aim axis) and its max single-row step (the "smooth rim
             glow, no boundary surface" check - the AC-0419 acceptance).

Usage: python3 measure.py <frame.png> <horizon|zenith|limb> <alt_rad_m>
"""
import sys
import math


def load_png(path):
    from PIL import Image
    return Image.open(path).convert("RGB")


def lum(r, g, b):
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def main():
    path, kind, alt_s = sys.argv[1], sys.argv[2], float(sys.argv[3])
    im = load_png(path)
    W, H = im.size
    px = im.load()
    half_fov = 75.0 / 2.0  # main.gd _make_camera: c.fov = 75.0 (vertical)
    t = math.tan(math.radians(half_fov))

    def row_angle(y):
        v = (y - H / 2.0) / (H / 2.0)  # -1..+1, -1 = top of frame
        return math.degrees(math.atan(v * t))

    # per-row median luminance (full width) + mean
    rowmed, rowmean = [], []
    for y in range(H):
        vals = sorted(lum(*px[x, y]) for x in range(W))
        rowmed.append(vals[W // 2])
        rowmean.append(sum(vals) / W)

    def max_step(prof, smooth=1):
        s = prof
        for _ in range(smooth - 1):
            s = [sum(s[max(0, i - 1):i + 2]) / len(s[max(0, i - 1):i + 2]) for i in range(len(s))]
        best = (0.0, -1)
        for i in range(1, len(s)):
            d = abs(s[i] - s[i - 1])
            if d > best[0]:
                best = (d, i)
        return best

    raw_step = max_step(rowmed, 1)
    sm5_step = max_step(rowmed, 5)

    print("KIND %s ALT_RAD %.0f" % (kind, alt_s))
    print("PROFILE rows (y, angle_deg_from_aim, row_median_lum):")
    for y in range(0, H, 30):
        print("  %4d %+7.2f  %7.2f" % (y, row_angle(y), rowmed[y]))
    print("STEPS raw_max %.2f @ row %d (angle %+.2f)" % (
        raw_step[0], raw_step[1], row_angle(raw_step[1])))
    print("STEPS smooth5_max %.2f @ row %d (angle %+.2f)" % (
        sm5_step[0], sm5_step[1], row_angle(sm5_step[1])))

    if kind == "horizon":
        cy = H // 2
        d = abs(rowmed[cy] - rowmed[cy - 1]) if cy > 0 else 0.0
        print("HORIZON_ROW centre row %d: lum %.2f (above %.2f / below %.2f, step %.2f)" % (
            cy, rowmed[cy], rowmed[cy - 1], rowmed[cy + 1], d))
        thirds = [sum(rowmean[0:H // 3]) / (H // 3),
                  sum(rowmean[H // 3:2 * H // 3]) / (H // 3),
                  sum(rowmean[2 * H // 3:]) / (H - 2 * H // 3)]
        print("THIRDS top %.2f mid %.2f bottom %.2f" % tuple(thirds))
        # the profile should be smooth DOWN the frame; report the max
        # step in each third separately (a fog-wall seam sits below the
        # horizon = in the bottom third region)
        for name, lo, hi in (("top", 0, H // 3), ("mid", H // 3, 2 * H // 3),
                             ("bottom", 2 * H // 3, H)):
            s, i = max_step(rowmed[lo:hi], 1)
            print("THIRD_STEP %s max %.2f @ row %d (angle %+.2f)" % (
                name, s, lo + i, row_angle(lo + i)))
    elif kind == "zenith":
        allv = sorted(lum(*px[x, y]) for y in range(H) for x in range(W))
        n = len(allv)
        print("DOME median %.2f p10 %.2f p90 %.2f" % (
            allv[n // 2], allv[int(n * 0.10)], allv[int(n * 0.90)]))
    elif kind == "limb":
        print("RADIAL (angle from aim axis = angle from the tangent):")
        for y in range(0, H, 30):
            print("  %4d %+7.2f  %7.2f" % (y, row_angle(y), rowmed[y]))


if __name__ == "__main__":
    main()
