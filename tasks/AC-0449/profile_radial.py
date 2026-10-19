#!/usr/bin/env python3
"""AC-0449 instrument: RADIAL edge-energy profile (nadir view).

In the nadir view (camera 941 m above the surface, looking straight
down, 90 deg FOV) the distance axis is RADIAL from the frame centre:
the centre is the nadir (941 m, the ground "right in front of you"),
the frame edge is ~1546 m (45 deg off the nadir; the local horizon,
~2903 m, is outside the frame). Per ring of radius r px we measure:

   C(r) = mean |L(p) - L(next p along the ring)|  — the edge energy
          (high-frequency detail) on that ring

plus the ring -> line-of-sight distance mapping for R = 4000 m,
camera radius D0 = 4941 m (941 m altitude), focal 360 px (90 deg
FOV, 720 px frame): theta(r) = atan(r/360);
d(theta) = D0*cos(theta) - sqrt(R^2 - D0^2 sin^2(theta))
(the near-side intersection; valid while theta < 54.05 deg = the
tangent, which the whole frame satisfies).

Usage:
  python3 profile_radial.py <frame.png> [frame.png ...]
(one C(r) column per frame; the near->far fall-off is the readout:
 a healthy blur is flat/near-zero near the centre and rises toward
 the edge; a wrong one collapses the centre too.)
"""
import math
import sys
from PIL import Image

W, H = 1280, 720
CX, CY = W / 2.0, H / 2.0
F = 360.0          # focal length in px (90 deg FOV / 720 px)
R = 4000.0         # planet radius (Game.planet_R)
D0 = R + 941.0     # camera radius (the user's 941 m altitude)
THETA_MAX = math.asin(R / D0)  # 54.05 deg, the tangent


def lum(p):
    return 0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2]


def dist_of(r_px):
    th = math.atan2(r_px, F)
    if th >= THETA_MAX:
        return float("inf")
    return D0 * math.cos(th) - math.sqrt(R * R - D0 * D0 * math.sin(th) ** 2)


def inb(x, y):
    return 0 <= x < W and 0 <= y < H


# the HUD (hunger/health row + hotbar) sits bottom-centre and is a
# SHARP UI — it would inflate C on the lower arcs; mask it out
HUD = (400, 608, 882, 712)


def in_hud(x, y):
    return HUD[0] <= x <= HUD[2] and HUD[1] <= y <= HUD[3]


def ring_stats(px, r, n=1440):
    # a sphere centred on the optical axis projects to a TRUE CIRCLE in
    # image space; in a 16:9 frame the far rings exit top/bottom, so
    # sample the in-frame ARC (the left/right limb arcs for r > 360) —
    # the same terrain the user's frame actually shows. Need >= 25% of
    # the circle in frame, else the arc is too small to trust.
    Cs = []
    Ls = []
    used = 0
    for i in range(n):
        a0 = 2.0 * math.pi * i / n
        a1 = 2.0 * math.pi * (i + 1) / n
        x0 = int(CX + r * math.cos(a0))
        y0 = int(CY + r * math.sin(a0))
        x1 = int(CX + r * math.cos(a1))
        y1 = int(CY + r * math.sin(a1))
        if not (inb(x0, y0) and inb(x1, y1)):
            continue
        if in_hud(x0, y0) or in_hud(x1, y1):
            continue
        used += 1
        l0 = lum(px[x0, y0])
        l1 = lum(px[x1, y1])
        Ls.append(l0)
        Cs.append(abs(l0 - l1))
    if used < n * 0.25:
        return None, None
    s = sorted(Ls)
    return s[len(s) // 2], sum(Cs) / len(Cs)


RINGS = [20, 40, 60, 80, 100, 120, 140, 160, 200, 240, 280, 320, 360, 400, 440, 470, 490]


def analyse(path):
    im = Image.open(path).convert("RGB")
    px = im.load()
    out = []
    for r in RINGS:
        L, C = ring_stats(px, r)
        d = dist_of(r)
        out.append((r, d, L, C))
    return out


def main():
    frames = sys.argv[1:]
    data = [(f, analyse(f)) for f in frames]
    hdr = "ring(px)  dist(m)" + "".join("%14s" % f.split("/")[-1][:14] for f in frames)
    if len(frames) > 1:
        hdr += "  ratio %s / %s" % (
                frames[1].split("/")[-1][:8], frames[0].split("/")[-1][:8])
    print(hdr)
    for i, (r, d, _, _) in enumerate(data[0][1]):
        line = "%7d  %8.0f" % (r, d)
        Cs = []
        for f, rows in data:
            L, C = rows[i][2], rows[i][3]
            Cs.append(C)
            line += "%14s" % ("   -" if C is None else "%.3f" % C)
        if len(frames) > 1 and Cs[0] is not None and Cs[1] is not None:
            line += "  %13.3f" % (Cs[1] / Cs[0])
        else:
            line += "  %13s" % ("-" if (Cs[0] is None or Cs[1] is None) else "")
        print(line)
    print("(C = mean |dL| along the ring, 0-255 scale; higher = sharper / more edge)")
    print("(ratio = frame[1]/frame[0] at the same ring: ~1 = the two frames carry the")
    print("  same edge energy; well below 1 = frame[0]'s pass destroyed the edges there)")
    for f, rows in data:
        def c(r):
            for rr, dd, L, C in rows:
                if rr == r:
                    return C
        near, mid, limb = c(20), c(240), c(490)
        if None in (near, mid, limb):
            continue
        print("%s: C(nadir ~943 m) = %.3f   C(~1200 m) = %.3f   C(~2549 m, limb arc) = %.3f"
              % (f.split("/")[-1], near, mid, limb))


if __name__ == "__main__":
    main()
