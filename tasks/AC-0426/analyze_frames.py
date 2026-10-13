#!/usr/bin/env python3
"""AC-0426 frame evidence: pixel-identity diffs + trunk luminance profile +
world contrast statistics. Usage:
  analyze_frames.py identity <a.png> <b.png>          # per-pixel diff count
  analyze_frames.py profile <day-before.png> <day-after-on.png>
  analyze_frames.py stats <png>                       # full-frame luminance stats
  analyze_frames.py all <before> <afteron> <nightoff> <nighton>
Pure Python + PIL (no numpy on this box).
"""
import sys
from PIL import Image

BLOB = (690, 0, 860, 75)  # x0, y0, x1, y1 - the AC-0425 f1 blob region


def lum(p):
    return 0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2]


def load(path):
    im = Image.open(path).convert("RGB")
    return im, im.load()


def identity(a, b):
    ia, pa = load(a)
    ib, pb = load(b)
    if ia.size != ib.size:
        print(f"SIZE MISMATCH {a}={ia.size} {b}={ib.size}")
        return 1
    n = ia.size[0] * ia.size[1]
    diff = 0
    worst = 0
    for y in range(ia.size[1]):
        for x in range(ia.size[0]):
            d = max(abs(pa[x, y][i] - pb[x, y][i]) for i in range(3))
            if d > 0:
                diff += 1
                worst = max(worst, d)
    print(f"IDENTITY {a} vs {b}: {diff}/{n} px differ, max channel delta {worst}")
    return 0 if diff == 0 else 2


def blob_crop(px, size):
    x0, y0, x1, y1 = BLOB
    out = []
    for y in range(y0, min(y1, size[1])):
        for x in range(x0, min(x1, size[0])):
            out.append(px[x, y])
    return out


def profile(name, px, size):
    cells = blob_crop(px, size)
    lums = sorted(lum(p) for p in cells)
    n = len(lums)

    def q(p):
        return lums[min(n - 1, int(n * p))]

    exact_black = sum(1 for p in cells if p == (0, 0, 0))
    reds = sum(1 for p in cells if p[0] > 0 and p[1] == 0 and p[2] == 0)
    mean_r = sum(p[0] for p in cells) / n
    mean_g = sum(p[1] for p in cells) / n
    mean_b = sum(p[2] for p in cells) / n
    # horizontal profile: one row every 8 rows across the blob, luminance per x
    print(f"{name}: blob={BLOB} n={n}")
    print(f"  exact-black {exact_black} ({100.0*exact_black/n:.1f}%)  "
          f"red-tail(>0,0,0) {reds} ({100.0*reds/n:.1f}%)")
    print(f"  mean RGB ({mean_r:.1f}, {mean_g:.1f}, {mean_b:.1f})  "
          f"mean lum {q(0.5):.1f}")
    print(f"  lum min={lums[0]:.1f} p5={q(0.05):.1f} p25={q(0.25):.1f} "
          f"p50={q(0.5):.1f} p75={q(0.75):.1f} p95={q(0.95):.1f} max={lums[-1]:.1f}")
    # trunk rows: the blob's lower rows (y 30..75) are the trunk (crown above)
    x0, y0, x1, y1 = BLOB
    rows = []
    for y in range(max(y0, 30), min(y1, size[1]), 6):
        line = [int(round(lum(px[x, y]))) for x in range(x0, min(x1, size[0]))]
        rows.append((y, line))
    print("  trunk-row luminance profile (row y: lum across x0..x1):")
    for y, line in rows:
        print(f"    y={y}: " + " ".join(f"{v:3d}" for v in line))
    return exact_black, reds, mean_r, mean_g, mean_b, lums


def stats(name, path):
    im, px = load(path)
    w, h = im.size
    lums = []
    for y in range(0, h, 2):
        for x in range(0, w, 2):
            lums.append(lum(px[x, y]))
    lums.sort()
    n = len(lums)

    def q(p):
        return lums[min(n - 1, int(n * p))]

    mean = sum(lums) / n
    var = sum((v - mean) ** 2 for v in lums) / n
    std = var ** 0.5
    # contrast = p95-p5 spread of the luminance distribution
    print(f"{name} ({path.split('/')[-1]}): full-frame luminance (2x2 sub-sample, n={n})")
    print(f"  min={lums[0]:.1f} p1={q(0.01):.1f} p5={q(0.05):.1f} p25={q(0.25):.1f} "
          f"p50={q(0.5):.1f} p75={q(0.75):.1f} p95={q(0.95):.1f} max={lums[-1]:.1f}")
    print(f"  mean={mean:.2f} std={std:.2f} contrast(p95-p5)={q(0.95)-q(0.05):.2f}")
    print(f"  dark-fraction lum<8: {100.0*sum(1 for v in lums if v<8)/n:.2f}%")
    return mean, std, q(0.95) - q(0.05)


def main():
    mode = sys.argv[1]
    if mode == "identity":
        sys.exit(identity(sys.argv[2], sys.argv[3]))
    if mode == "stats":
        stats("frame", sys.argv[2])
        return
    if mode == "profile":
        im, px = load(sys.argv[2])
        profile(sys.argv[2].split("/")[-1], px, im.size)
        return
    if mode == "all":
        before, afteron, noff, non = sys.argv[2:6]
        print("=== TRUNK BLOB: BEFORE vs AFTER-ON (daylight, same tree, same view) ===")
        im, px = load(before)
        profile("BEFORE (switch off / pre-fix tree)", px, im.size)
        im2, px2 = load(afteron)
        profile("AFTER-ON (AWECRAFT_AMBSKY=1)", px2, im2.size)
        print()
        print("=== WORLD CONTRAST (full frame, daylight) ===")
        stats("BEFORE", before)
        stats("AFTER-ON", afteron)
        print()
        print("=== NIGHT (AWECRAFT_TIME=0.0): off vs on must be identical ===")
        stats("NIGHT-OFF", noff)
        stats("NIGHT-ON", non)
        sys.exit(identity(noff, non))


if __name__ == "__main__":
    main()
