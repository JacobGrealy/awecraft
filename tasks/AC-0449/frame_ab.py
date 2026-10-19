#!/usr/bin/env python3
"""AC-0449 instrument: two-frame A/B pixel census.

Proves what changed between two same-view renders (the
"removing the blur did not flatten or change anything else" evidence)
and localises it: per-row mean/max abs diff (0-255 per channel), the
diff mass per band, and a byte-identity verdict.

Usage:  python3 frame_ab.py <a.png> <b.png>
"""
import sys
from PIL import Image

W, H = 1280, 720
BANDS = [
    ("SKY     (y<0.30H, above horizon)", 0, int(0.30 * H)),
    ("RIM     (0.42-0.55H, ->horizon)", int(0.42 * H), int(0.55 * H)),
    ("MID     (0.55-0.75H)", int(0.55 * H), int(0.75 * H)),
    ("NEAR    (y>=0.90H, nadir/closest)", int(0.90 * H), H),
]


def main():
    pa, pb = sys.argv[1], sys.argv[2]
    ia = Image.open(pa).convert("RGB")
    ib = Image.open(pb).convert("RGB")
    if ia.size != ib.size:
        print("SIZE MISMATCH", ia.size, ib.size)
        return
    xa, xb = ia.load(), ib.load()
    rowsum = [0] * H
    rowmax = [0] * H
    bandsum = {k: 0 for k, _, _ in BANDS}
    changed = 0
    for y in range(H):
        for x in range(W):
            a = xa[x, y]
            b = xb[x, y]
            d = abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2])
            if d:
                changed += 1
            rowsum[y] += d
            if d > rowmax[y]:
                rowmax[y] = d
            for k, y0, y1 in BANDS:
                if y0 <= y < y1:
                    bandsum[k] += d
    npx = W * H
    print("frames: %s vs %s  (%dx%d)" % (pa, pb, W, H))
    print("changed px: %d / %d (%.2f%%)" % (changed, npx, 100.0 * changed / npx))
    print("band diff mass (sum |d| over channels, 0-765/px):")
    for k, _, _ in BANDS:
        print("  %-38s %12d" % (k, bandsum[k]))
    print("rows with the largest diff (y, mean |d|, max |d|):")
    order = sorted(range(H), key=lambda y: -rowsum[y])[:12]
    for y in sorted(order):
        print("  y=%3d  mean %8.3f  max %4d" % (y, rowsum[y] / W, rowmax[y]))
    print("sky rows (y<0.30H) diff mass: %d  (0 = the above-horizon sky is untouched)" % sum(
        rowsum[y] for y in range(int(0.30 * H))))


if __name__ == "__main__":
    main()
