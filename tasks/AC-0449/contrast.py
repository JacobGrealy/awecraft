#!/usr/bin/env python3
"""AC-0449 instrument: the CONTRAST-WITH-DISTANCE profile.

The ticket's measurement is a profile, not a number: sample the same terrain
at several distances and show that clarity RETURNS AS DISTANCE FALLS. In a
first-person aim-spot frame the distance axis is the frame's vertical axis
(bottom rows = a few metres, horizon rows = far). Per row we measure:

  L(y)      median luminance of the row (255 scale)
  C(y)      mean |L(x+1) - L(x)| over the row — the horizontal edge
            density: texture detail / local contrast between adjacent
            terrain features
  AIR(y)    fraction of the row's pixels within 15/255 (per channel) of the
            single-source air colour (208,241,251) at T=0.5 — the wash

Bands (1280x720, the aim-spot first-person view):
  NEAR  y in [0.90H, H)   — arm's-length to a few metres
  MID   y in [0.55H, 0.75H)
  FAR   y in [0.42H, 0.55H)  — approaching the horizon / the fog window
  SKY   y in [0, 0.30H)     — above the horizon (the AC-0439 preservation check:
                              row medians, max single-row step, black-sky census)

Usage:
  python3 contrast.py <frame.png>            # per-row table + band summary
  python3 contrast.py <a.png> <b.png>        # per-band diff a vs b
"""
import sys
from PIL import Image

W, H = 1280, 720
AIR = (208.0, 241.0, 251.0)   # fog_display_srgb(0.5), the single-source air colour
TOL = 15.0


def lum(p):
    return 0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2]


def row_stats(px, y):
    L = []
    C = []
    air = 0
    for x in range(W):
        p = px[x, y]
        L.append(lum(p))
        if (abs(p[0] - AIR[0]) <= TOL and abs(p[1] - AIR[1]) <= TOL
                and abs(p[2] - AIR[2]) <= TOL):
            air += 1
    Cs = [abs(L[x + 1] - L[x]) for x in range(W - 1)]
    s = sorted(L)
    return s[len(s) // 2], sum(Cs) / len(Cs), air / W


def analyse(frame):
    im = Image.open(frame).convert("RGB")
    px = im.load()
    rows = []
    for y in range(H):
        rows.append(row_stats(px, y))
    return rows


def band(rows, y0, y1):
    sub = rows[y0:y1]
    L = sorted(r[0] for r in sub)
    C = sorted(r[1] for r in sub)
    A = sorted(r[2] for r in sub)
    n = len(sub)
    return (L[n // 2], C[n // 2], C[int(n * 0.9)], A[n // 2])


def report(name, rows):
    print("=== %s (%s) ===" % (name, "1280x720"))
    print("row    L_med   C_mean  AIRfrac")
    for y in range(0, H, 40):
        L, C, A = rows[y]
        print("  %3d  %7.1f  %7.2f  %6.3f" % (y, L, C, A))
    y = H - 1
    L, C, A = rows[y]
    print("  %3d  %7.1f  %7.2f  %6.3f  <- last" % (y, L, C, A))
    bands = {
        "NEAR (y>=0.90H, a few m)": band(rows, int(0.90 * H), H),
        "MID  (0.55-0.75H)": band(rows, int(0.55 * H), int(0.75 * H)),
        "FAR  (0.42-0.55H, ->horizon)": band(rows, int(0.42 * H), int(0.55 * H)),
        "SKY  (y<0.30H, above horizon)": band(rows, 0, int(0.30 * H)),
    }
    print("band summary:  L_med   C_p50   C_p90   AIR_med")
    vals = {}
    for k, (L, C, Cp, A) in bands.items():
        vals[k] = (L, C, Cp, A)
        print("  %-32s %7.1f  %7.2f  %7.2f  %7.3f" % (k, L, C, Cp, A))
    near = vals["NEAR (y>=0.90H, a few m)"]
    far = vals["FAR  (0.42-0.55H, ->horizon)"]
    ratio = near[1] / max(1e-9, far[1])
    print("NEAR/FAR contrast ratio (C_p50): %.2f  (clear-near-hazy-far wants this >> 1)" % ratio)
    # sky preservation: the above-horizon rows
    skyrows = rows[:int(0.30 * H)]
    sl = [r[0] for r in skyrows]
    steps = [abs(sl[i + 1] - sl[i]) for i in range(len(sl) - 1)]
    black = sum(1 for v in sl if v < 8.0)
    print("sky rows: L_med p50 %.1f, max single-row step %.2f, rows <8 (black sky) %d" % (
        sorted(sl)[len(sl) // 2], max(steps) if steps else 0.0, black))
    return vals


def main():
    a = sys.argv[1:]
    ra = analyse(a[0])
    va = report(a[0], ra)
    if len(a) > 1:
        rb = analyse(a[1])
        vb = report(a[1], rb)
        print("=== per-band delta (%s -> %s) ===" % (a[0], a[1]))
        print("band                         dL_med  dC_p50  dC_p90  dAIR_med")
        for k in va:
            da = [vb[k][i] - va[k][i] for i in range(4)]
            print("  %-32s %8.1f  %8.2f  %8.2f  %8.3f" % (k, *da))


if __name__ == "__main__":
    main()
