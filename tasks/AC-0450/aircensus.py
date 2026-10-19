#!/usr/bin/env python3
"""AC-0450 instrument: the AIRBORNE VOID CENSUS.

Per-frame pixel ownership at a fixed airborne vantage, by frame A/B
ELIMINATION (not by colour - colour cannot separate fog-washed terrain
from sky: both sit at the single-source air colour):

  F0  as shipped
  F1  AWECRAFT_SKYALT=0       (the sky's air term off: background pixels
                               change, geometry is switch-blind)
  F2  AWECRAFT_NO_FOG=1       (the engine depth fog off: near/far tier
                               pixels in the fog window change; the body
                               is fog_disabled; the sky is untouched)
  F3  AWECRAFT_SAT_BODY=0     (the satellite body off: its pixels fall
                               back to the background)
  F4  AWECRAFT_NO_WORLD_VIS=1 (ALL world geometry hidden: the pure
                               background reference, and the "coverage
                               disabled" frame - the negative test)

Per-pixel (max-channel delta, tolerance T):
  (a) background   = |F0 - F4| <= T     (reads as background: nothing
                                         distinguishable drawn in front)
  (d) body         = |F0 - F3| > T      (the body drew there - VISIBLE)
  fog-owned        = |F0 - F2| > T      (the engine fog tinted it)
  skybody          = |F0 - F1| > T      (the sky body owns it)
  geometry (visible) = not (a)

  (a) carries one documented ambiguity and the instrument resolves it
  with the F1 (sky-off) state: at and beyond the fog wall the geometry
  is ON PURPOSE indistinguishable from the air colour (the AC-0401
  near-field discard + the body's haz that mixes the rim toward the
  single-source u_air, which IS the sky's air fill). A pixel that reads
  as background and does NOT change when the sky body is swapped is
  owned by hazed geometry, not by sky:
    (a)_sky_true = (a) AND skybody  (the sky owns it)
    (a)_hazed    = (a) AND NOT skybody (fully hazed geometry reading
                                         as background - by design, not
                                         a hole)
  True sky that sits exactly at the w = 0 air-floor line does not
  change with the body swap either, so it lands in (a)_hazed - a thin
  horizon band, reported, not hidden.

  (a) also splits analytically against the planet-sphere ray model built
  from the arm's MEASURED shot pose (RESULT): (a)_sky = background
  pixels whose ray MISSES the planet (above the local horizon -
  expected), (a)_hole = background pixels whose ray HITS the planet
  surface distance - background where terrain is expected, the class
  the standing r16 far_holes census reports as 0/0 while the user
  photographs it. (a)_hole = (a)_sky_true_hole + (a)_hazed_hole.

  geometry not body = tier pixels; per-pixel camera distance (the
  ray->sphere near intersection) is reported against the LIVE derived
  fog_far / render_edge the arm printed (DayNight.fog_far home / the
  (rr+1)*16 home) - no constant in this script.

The CONTRAST-WITH-DISTANCE profile (the measurement AC-0449's acceptance
wants): per-pixel camera distance bins the frame; in each bin the mean
and p50 of |dL| between adjacent pixels (both in-class), L = the luma.
Reported for F0 (as shipped, over geometry pixels) and F3 (body off, over
disc pixels - the sky reference the profile is measured against).

The NEGATIVE TEST is in the matrix: with no world geometry drawn (F4) the
background fraction must RISE to ~100 % and (a)_hole to the whole disc.
If it does not, the instrument is broken - the script prints the numbers
anyway, and they are the evidence.

Consistency guards (the instrument must be able to be incoherent):
  body XOR ~bg      must be ~0  (opaque-or-blended body: bg <-> not body
                                  exactly, for any opacity)
  fog AND body      must be ~0  (the body is fog_disabled)
  skybody AND ~bg AND ~body must be ~0 (a geometry pixel does not change
                                  with the sky body)
Violations are reported as counts, not hidden.

Pure Python + PIL (no numpy on this box - the AC-0449 instrument
precedent). ~1280x720 x 5 frames runs in a few seconds.

Usage:
  python3 aircensus.py --f0 F0.png --f1 F1.png --f2 F2.png --f3 F3.png \
      --f4 F4.png --result 'RESULT_JSON' [--tol 2] [--out census.json] \
      [--extra F0_s30.png F0_s60.png]
"""
import argparse
import json
import math
import sys

from PIL import Image, ImageChops

LUMA = (0.2126, 0.7152, 0.0722)


def load(path):
    im = Image.open(path).convert("RGB")
    return im


def maxdiff(a, b):
    """Per-pixel MAX-channel abs delta, as an 'L' image (PIL, C speed)."""
    d = ImageChops.difference(a, b)
    r, g, bl = d.split()
    return ImageChops.lighter(ImageChops.lighter(r, g), bl)


def mask_bytes(dmax, tol):
    """True (1) where the max-channel delta exceeds the tolerance."""
    return dmax.point(lambda v: 1 if v > tol else 0).tobytes()


def cam_basis(pos, aim, up, fov_deg, w, h):
    """Orthonormal camera basis from the arm's measured pose."""
    f = (aim[0], aim[1], aim[2])
    fl = math.sqrt(sum(c * c for c in f))
    f = (f[0] / fl, f[1] / fl, f[2] / fl)
    u = (up[0], up[1], up[2])
    # right = forward x up (Godot camera: basis.x x basis.y = -forward)
    r = (f[1] * u[2] - f[2] * u[1],
         f[2] * u[0] - f[0] * u[2],
         f[0] * u[1] - f[1] * u[0])
    rl = math.sqrt(sum(c * c for c in r))
    r = (r[0] / rl, r[1] / rl, r[2] / rl)
    # re-orthogonalize up (the reported up may be a hint, not exact)
    u = (u[0] - (u[0] * f[0] + u[1] * f[1] + u[2] * f[2]) * f[0],
         u[1] - (u[0] * f[0] + u[1] * f[1] + u[2] * f[2]) * f[1],
         u[2] - (u[0] * f[0] + u[1] * f[1] + u[2] * f[2]) * f[2])
    ul = math.sqrt(sum(c * c for c in u))
    u = (u[0] / ul, u[1] / ul, u[2] / ul)
    th = math.tan(math.radians(fov_deg) * 0.5)
    asp = w / h
    return f, u, r, th, asp


def ray_dist(pos, direction, cen, R):
    """Near ray->sphere intersection distance, or -1.0 if the ray misses.

    The camera is OUTSIDE the sphere (radial altitude > 0), so both roots
    are positive and the NEAR one is -bd - sqrt(disc) (the far root is the
    other side of the planet - the sign error that would misbin the whole
    distance axis).
    """
    b = (pos[0] - cen[0], pos[1] - cen[1], pos[2] - cen[2])
    bd = b[0] * direction[0] + b[1] * direction[1] + b[2] * direction[2]
    c = (b[0] * b[0] + b[1] * b[1] + b[2] * b[2]) - R * R
    disc = bd * bd - c
    if disc < 0.0:
        return -1.0
    t = -bd - math.sqrt(disc)
    if t <= 0.0:
        return -1.0
    return t


def pixel_dirs(f, u, r, th, asp, w, h):
    """The per-pixel ray direction (row-major), precomputed once."""
    dirs = []
    for y in range(h):
        yndc = 1.0 - (2.0 * (y + 0.5) / h)
        for x in range(w):
            xndc = 2.0 * (x + 0.5) / w - 1.0
            dx = f[0] + xndc * th * asp * r[0] + yndc * th * u[0]
            dy = f[1] + xndc * th * asp * r[1] + yndc * th * u[1]
            dz = f[2] + xndc * th * asp * r[2] + yndc * th * u[2]
            dl = math.sqrt(dx * dx + dy * dy + dz * dz)
            dirs.append((dx / dl, dy / dl, dz / dl))
    return dirs


def luma_bands(im):
    r, g, b = im.split()
    return (r.tobytes(), g.tobytes(), b.tobytes())


def profile(frame, sel, dists, w, h, nbins=12):
    """Mean / p50 adjacent-pixel luma delta, binned by camera distance.

    sel: 1-byte buffer (1 = in-class pixel), dists: per-pixel distance
    (meters, -1 = the ray misses the planet). Adjacent pairs count only
    when BOTH endpoints are in-class.
    """
    rb, gb, bb = luma_bands(frame)
    L = [0.0] * (w * h)
    for i in range(w * h):
        L[i] = LUMA[0] * rb[i] + LUMA[1] * gb[i] + LUMA[2] * bb[i]
    # bin edges over the in-class distances
    dd = [dists[i] for i in range(w * h) if sel[i] and dists[i] >= 0.0]
    if not dd:
        return None
    lo, hi = min(dd), max(dd)
    if hi - lo < 1e-6:
        return None
    bw = (hi - lo) / nbins
    sums = [0.0] * nbins
    cnts = [0] * nbins
    p50s = [[] for _ in range(nbins)]
    for y in range(h):
        row = y * w
        for x in range(w):
            i = row + x
            if not sel[i] or dists[i] < 0.0:
                continue
            bi = int((dists[i] - lo) / bw)
            if bi >= nbins:
                bi = nbins - 1
            if x + 1 < w:
                j = i + 1
                if sel[j] and dists[j] >= 0.0 and abs(dists[j] - dists[i]) <= bw:
                    v = abs(L[i] - L[j])
                    sums[bi] += v
                    cnts[bi] += 1
                    p50s[bi].append(v)
            if y + 1 < h:
                j = i + w
                if sel[j] and dists[j] >= 0.0 and abs(dists[j] - dists[i]) <= bw:
                    v = abs(L[i] - L[j])
                    sums[bi] += v
                    cnts[bi] += 1
                    p50s[bi].append(v)
    out = []
    for bi in range(nbins):
        if cnts[bi] == 0:
            out.append({"d_lo": round(lo + bi * bw, 1),
                        "d_hi": round(lo + (bi + 1) * bw, 1),
                        "pairs": 0})
            continue
        p50s[bi].sort()
        out.append({"d_lo": round(lo + bi * bw, 1),
                    "d_hi": round(lo + (bi + 1) * bw, 1),
                    "pairs": cnts[bi],
                    "C_mean": round(sums[bi] / cnts[bi], 3),
                    "C_p50": round(p50s[bi][cnts[bi] // 2], 3)})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--f0", required=True)
    ap.add_argument("--f1", required=True)
    ap.add_argument("--f2", required=True)
    ap.add_argument("--f3", required=True)
    ap.add_argument("--f4", required=True)
    ap.add_argument("--result", required=True,
                    help="the F0 run's RESULT JSON (the measured pose + the "
                         "live derived thresholds)")
    ap.add_argument("--tol", type=int, default=2)
    ap.add_argument("--out", default=None)
    ap.add_argument("--extra", nargs="*", default=[],
                    help="settle-pair frames (SNAP_STEPS) to census against F4")
    a = ap.parse_args()

    res = json.loads(a.result)
    f0 = load(a.f0)
    w, h = f0.size
    res_w, res_h = int(res["w"]), int(res["h"])
    if (res_w, res_h) != (w, h):
        print("CENSUS ABORT: RESULT w/h %dx%d does not match the frame %dx%d"
              % (res_w, res_h, w, h))
        return 2
    f1 = load(a.f1)
    f2 = load(a.f2)
    f3 = load(a.f3)
    f4 = load(a.f4)

    tol = a.tol
    m_f4 = mask_bytes(maxdiff(f0, f4), tol)  # background
    m_f3 = mask_bytes(maxdiff(f0, f3), tol)  # body
    m_f2 = mask_bytes(maxdiff(f0, f2), tol)  # fog-owned
    m_f1 = mask_bytes(maxdiff(f0, f1), tol)  # skybody

    # the per-pixel distance field (the arm's measured pose)
    R = float(res["R"])
    cen = (0.0, -R, 0.0)
    pos = tuple(float(v) for v in res["pos"])
    f, u, r, th, asp = cam_basis(pos, res["aim"], res["up"], float(res["fov"]), w, h)
    dirs = pixel_dirs(f, u, r, th, asp, w, h)
    dists = [ray_dist(pos, d, cen, R) for d in dirs]

    n = w * h
    # mask_bytes is 1 where the DELTA EXCEEDS the tolerance:
    #   m_f4 = 1 where hiding the world changes the pixel = VISIBLE geometry
    #   m_f3 = 1 where turning the body off changes the pixel = body drew
    #   m_f2 = 1 where turning the fog off changes the pixel = fog tinted
    #   m_f1 = 1 where swapping the sky body changes the pixel = sky owned
    # background (a) = the COMPLEMENT of m_f4 (reads as the world-hidden
    # reference within the tolerance) - the one place a sign slip inverts
    # the whole census.
    geom = m_f4
    bg = bytes(1 - v for v in geom)
    body = m_f3
    fog = m_f2
    skyb = m_f1

    bg_c = sum(bg)
    body_c = sum(body)
    fog_c = sum(fog)
    skyb_c = sum(skyb)
    geo_c = n - bg_c
    bg_sky_c = 0
    bg_hole_c = 0
    bg_true_c = 0
    bg_hazed_c = 0
    hole_true_c = 0
    hole_hazed_c = 0
    skyb_hole_c = 0  # sky-changing pixels whose ray HITS the planet:
    # the semi-transparent body region (the sky bleeds through the body
    # there - the AC-0451 annulus class, quantified)
    for i in range(n):
        if bg[i]:
            hit = dists[i] >= 0.0
            if not hit:
                bg_sky_c += 1
            else:
                bg_hole_c += 1
            if skyb[i]:
                bg_true_c += 1
                if hit:
                    hole_true_c += 1
            else:
                bg_hazed_c += 1
                if hit:
                    hole_hazed_c += 1
        elif skyb[i] and dists[i] >= 0.0:
            skyb_hole_c += 1
    # tier pixels (geometry, not body) + their distance stats
    tier_c = 0
    dmin_geo = None
    dmax_geo = None
    tier_dmin = None
    for i in range(n):
        if bg[i]:
            continue
        d = dists[i]
        if d >= 0.0:
            if dmin_geo is None or d < dmin_geo:
                dmin_geo = d
            if dmax_geo is None or d > dmax_geo:
                dmax_geo = d
        if not body[i]:
            tier_c += 1
            if d >= 0.0 and (tier_dmin is None or d < tier_dmin):
                tier_dmin = d
    # consistency guards
    guard_bg_xor_nobody = 0
    guard_fog_body = 0
    guard_skyb_geo = 0
    for i in range(n):
        isbg = bool(bg[i])
        isbody = bool(body[i])
        if isbg != (not isbody):
            guard_bg_xor_nobody += 1
        if fog[i] and isbody:
            guard_fog_body += 1
        if skyb[i] and not isbg and not isbody:
            guard_skyb_geo += 1

    fog_far = float(res["fog_far"])
    render_edge = float(res["render_edge"])

    out = {
        "instrument": "AC-0450 airborne void census",
        "tol": tol, "w": w, "h": h, "pixels": n,
        "pose": {"pos": list(pos), "aim": res["aim"], "up": res["up"],
                 "fov": float(res["fov"]), "R": R,
                 "alt": float(res.get("alt", -1)),
                 "playercam": bool(res.get("playercam", False)),
                 "nadir": bool(res.get("nadir", False))},
        "derived": {"fog_far": fog_far, "render_edge": render_edge,
                    "render_radius": int(res.get("render_radius", -1)),
                    "fog_start_pct": float(res.get("fog_start_pct", -1)),
                    "source": "the arm printed them off env.fog_depth_end "
                              "(DayNight.fog_far home) and "
                              "satellite.last_render_edge ((rr+1)*16 home)"},
        "fractions": {
            "background_a": round(bg_c / n, 6),
            "background_a_sky_true": round(bg_true_c / n, 6),
            "background_a_hazed": round(bg_hazed_c / n, 6),
            "background_sky": round(bg_sky_c / n, 6),
            "background_hole_a": round(bg_hole_c / n, 6),
            "background_hole_abs": bg_hole_c,
            "background_hole_sky_true": hole_true_c,
            "background_hole_hazed": hole_hazed_c,
            "body_d": round(body_c / n, 6),
            "geometry_total": round(geo_c / n, 6),
            "tier_pixels_b_c": tier_c,
            "tier_fraction": round(tier_c / n, 6),
            "fog_owned": round(fog_c / n, 6),
            "skybody": round(skyb_c / n, 6),
            "skybody_on_planet_disc": round(skyb_hole_c / n, 6),
        },
        "distance": {
            "geo_dmin_m": round(dmin_geo, 1) if dmin_geo is not None else None,
            "geo_dmax_m": round(dmax_geo, 1) if dmax_geo is not None else None,
            "tier_dmin_m": round(tier_dmin, 1) if tier_dmin is not None else None,
            "fog_far_m": fog_far,
            "render_edge_m": render_edge,
            "note": "tier pixels = geometry not body; a tier pixel with "
                    "d >= fog_far would contradict the AC-0401 discard - "
                    "reported, not filtered",
        },
        "consistency": {
            "bg_xor_not_body": guard_bg_xor_nobody,
            "fog_and_body": guard_fog_body,
            "skybody_on_bare_geometry": guard_skyb_geo,
            "expect": "all three ~0 (see the module docstring)",
        },
        "negative_test": {
            "a_f0": round(bg_c / n, 6),
            "note": "F4/F3 fractions computed per-frame below. The (a) "
                    "counter must RISE when geometry is removed: at this "
                    "vantage part of the frame already READS as background "
                    "(the hazed body is on purpose the air colour, the "
                    "AC-0401/AC-0429 single-source design), so the rise is "
                    "a_f4 - a_f0 = the visible-geometry fraction, and "
                    "(a)_hole must rise to the whole planet-intersecting "
                    "disc. A counter that cannot be made to rise is a "
                    "broken instrument - these numbers are the test.",
        },
        "profile_f0_geo": profile(f0, bytes(1 - b for b in bg), dists, w, h),
    }

    # the F3 (body off) profile over the disc pixels (the sky reference)
    disc_sel = bytes(1 if d >= 0.0 else 0 for d in dists)
    out["profile_f3_disc"] = profile(f3, disc_sel, dists, w, h)

    # per-frame census: F4 (world hidden = the negative test), F3 (body off)
    for name, frm in (("f4", f4), ("f3", f3)):
        # the frame's OWN background class: |frame - F4| <= tol (F4 IS the
        # world-hidden reference, so for F4 itself this is the self-identity)
        mref = mask_bytes(maxdiff(frm, f4), tol)  # 1 = differs from the reference
        geomf = sum(mref)
        bgf = n - geomf
        holef = 0
        for i in range(n):
            if not mref[i] and dists[i] >= 0.0:
                holef += 1
        out["negative_test"]["%s_background" % name] = round(bgf / n, 6)
        out["negative_test"]["%s_background_hole" % name] = round(holef / n, 6)
    out["negative_test"]["rise_f4"] = round(
        out["negative_test"]["f4_background"] - out["negative_test"]["a_f0"], 6)
    out["negative_test"]["rise_f3"] = round(
        out["negative_test"]["f3_background"] - out["negative_test"]["a_f0"], 6)

    # the settle pair (SNAP_STEPS frames): census each against F4
    extras = []
    for xp in a.extra:
        xf = load(xp)
        if xf.size != (w, h):
            print("CENSUS ABORT: %s is %dx%d, expected %dx%d"
                  % (xp, xf.size[0], xf.size[1], w, h))
            return 2
        mx = mask_bytes(maxdiff(xf, f4), tol)  # 1 = differs from the reference
        bgx = n - sum(mx)
        hlex = 0
        for i in range(n):
            if not mx[i] and dists[i] >= 0.0:
                hlex += 1
        bx = mask_bytes(maxdiff(xf, f3), tol)
        extras.append({"file": xp, "background": round(bgx / n, 6),
                       "background_hole": round(hlex / n, 6),
                       "body": round(sum(bx) / n, 6),
                       "vs_f4_maxdiff": int(maxdiff(xf, f4).getextrema()[1])})
    out["settle_pair"] = extras

    print(json.dumps(out, indent=1))
    if a.out:
        with open(a.out, "w") as fh:
            json.dump(out, fh, indent=1)
        print("CENSUS written to %s" % a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
