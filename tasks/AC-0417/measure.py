#!/usr/bin/env python3
"""AC-0417 pixel measurement: the sky forward model + patch statistics.

The sky shader (godot/core/aero_sky_gradient.gdshader) is re-implemented
1:1 here in BOTH its current form (pre-AC-0417) and the new one, and the
Forward+ pipeline is reproduced (pow 2.2 pre-decode -> exposure 0.85 ->
ACES -> contrast 1.1 -> saturation 1.25 -> sRGB encode), so every capture
is compared pixel by pixel against the model at the pushed uniforms.
Pure PIL (no numpy on this box); patches are small.

Geometry mirrors the harness `planet` preset (harness.gd, the AC-0417
extension): camera at spawn + radial*alt_param (alt_param is the DISTANCE
ALONG THE RADIAL from the spawn point, so the true radial altitude is
alt_param + (|spawn|-R)); limb aim = tangent to the R sphere (or the
nadir when AWECRAFT_CAM_NADIR=1); fov 75 deg vertical.

Usage:
  python3 measure.py ladder <log> [more logs...]
        the pushed u_space/u_space_sky/u_sky_alt/u_air per run (parsed
        from the preset RESULT) + op_nadir + star op, with the true
        radial altitude back-solved from u_space_sky on the tree that
        pushed it.
  python3 measure.py strip <png> <run.json>
        F1: the sky strip above the disc limb (rows limb_row+4 .. top-4,
        central 200 columns) - raw stats + model-vs-pixel deltas.
  python3 measure.py ring <png> <run.json>
        F2/F3: the coverage-gap annulus in the nadir view (d between
        fog_far and render_edge) - an intercept fit of pixel vs body op
        recovers the background (the sky) the annulus shows through.
  python3 measure.py patch <png> <run.json>
        a raw rectangular patch (x0 y0 x1 y1 in run.json) for the
        ground-level A/B shots.

run.json: {"preset":"planet"|"default", "alt": <param>, "off":[dx,dz],
 "nadir": bool, "R":4000, "sea":126, "fog_far":332, "render_edge":400,
 "time":0.5, "tree":"before"|"after", "u_space":f, "u_space_sky":f,
 "u_sky_alt":f, "u_air":[r,g,b] (sRGB 0-255), "spawn":[x,y,z]}
"""
import json
import math
import re
import sys

from PIL import Image

R_DEF = 4000.0
SEA = 126.0
FOV = 75.0
HALF = math.tan(math.radians(FOV / 2.0))
# aero.gd constants (day, T=0.5 - day(0.5)=1.0, dusk=0):
DAY_ZENITH = (46, 134, 216)
DAY_MID = (95, 198, 234)
DAY_HORIZON = (223, 246, 251)
HAZE = (186, 233, 250)
HAZE_AMT = 0.4
SUN_CORE = (255, 255, 255)
SUN_HALO = (255, 246, 222)
SUN_AMOUNT = 1.0
SPACE = (2, 3, 10)
# DayNight.sun_direction(0.5) negated and normalized (aero.gd sky_uniforms
# "body" branch - body.y > -0.10 so it is the SUN, not the moon):
a = (0.5 - 0.25) * 2.0 * math.pi
_s = (-math.cos(a), -math.sin(a), -0.4 * math.sin(a))
_n = math.sqrt(sum(v * v for v in _s))
SUN_DIR = tuple(v / _n for v in _s)  # (0, -0.928, -0.371) light travel
SUN_TO = tuple(-v for v in _s)  # to-sun: (0, 0.928, 0.371)
# the grade (aero.gd apply_grade, Forward+):
EXPOSURE = 0.85
CONTRAST = 1.1
SATURATION = 1.25
WASH_COLOR = (168, 238, 255)
WASH_AMOUNT_BASE = 0.03
WASH_TOP_GLOW = 0.5


def c8(c):
    return tuple(round(v) for v in c)


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def smoothstep(lo, hi, x):
    t = max(0.0, min(1.0, (x - lo) / (hi - lo)))
    return t * t * (3.0 - 2.0 * t)


def ss_inv(lo, hi, ss):
    """invert smoothstep(lo, hi, x) = ss by bisection."""
    if ss <= 0.0:
        return lo
    if ss >= 1.0:
        return hi
    lo2, hi2 = 0.0, 1.0
    for _ in range(60):
        mid = (lo2 + hi2) / 2.0
        v = mid * mid * (3.0 - 2.0 * mid)
        if v < ss:
            lo2 = mid
        else:
            hi2 = mid
    return lo + (lo2 + hi2) / 2.0 * (hi - lo)


def srgb_to_lin(v):
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def lin_to_srgb(v):
    return 12.92 * v if v <= 0.0031308 else 1.055 * v ** (1.0 / 2.4) - 0.055


def aces(v):
    return (v * (2.51 * v + 0.03)) / (v * (2.43 * v + 0.59) + 0.14)


def encode_lin(lin):
    """The Forward+ tail: linear HDR -> 8-bit sRGB (exposure, ACES, contrast,
    saturation, sRGB encode)."""
    out = []
    for v in lin:
        v = aces(max(0.0, v) * EXPOSURE)
        v = (v - 0.5) * CONTRAST + 0.5  # contrast
        out.append(v)
    # saturation about luma (Godot adjustment order: contrast, then sat)
    lum = 0.2126 * out[0] + 0.7152 * out[1] + 0.0722 * out[2]
    out = [lum + (v - lum) * SATURATION for v in out]
    return [max(0, min(255, round(lin_to_srgb(max(0.0, v)) * 255.0))) for v in out]


def pipeline(col_disp, wash_g=None, wash_amt=0.0):
    """Forward+ chain: display-space shader output -> 8-bit sRGB pixel.
    wash_* = the aero_wash quad's linear add (before the tonemap)."""
    lin = []
    for i in range(3):
        v = col_disp[i] ** 2.2  # u_srgb_pre = 1.0 on Forward+
        if wash_amt > 0.0:
            v += (WASH_COLOR[i] / 255.0) * wash_amt * (1.0 + WASH_TOP_GLOW * wash_g) ** 2.2
        lin.append(v)
    return encode_lin(lin)


def sky_model_before(dirv, u):
    """The current shader, verbatim (h = dir.y - the WORLD axis)."""
    h = dirv[1]
    uc = max(0.0, min(1.0, h))
    col = mix(DAY_HORIZON, DAY_MID, smoothstep(0.0, 0.30, uc))
    col = mix(col, DAY_ZENITH, smoothstep(0.25, 0.90, uc))
    if h < 0.0:
        col = mix(col, tuple(v * 0.5 for v in DAY_HORIZON), max(0.0, min(1.0, -h * 2.0)))
    hz = math.exp(-abs(h) * 9.0) * HAZE_AMT
    col = mix(col, HAZE, hz)
    def ssmix(a, b, t):
        return a + (b - a) * t
    ws = ssmix(u["u_space"] ** 2, u["u_space"], uc)
    ws = ssmix(ws, ssmix(u["u_space_sky"] ** 2, u["u_space_sky"], uc), u["u_sky_alt"])
    col = mix(col, SPACE, ws)
    # limb term (shared): u_limb_center = centre relative to the camera
    if u["u_limb_amount"] > 0.0 and u["u_limb_radius"] > 0.0:
        lc = u["u_limb_center"]
        b = math.sqrt(max(0.0,
                          (lc[1] * dirv[2] - lc[2] * dirv[1]) ** 2 +
                          (lc[2] * dirv[0] - lc[0] * dirv[2]) ** 2 +
                          (lc[0] * dirv[1] - lc[1] * dirv[0]) ** 2))
        limb = min(1.0, math.exp(-(b - u["u_limb_radius"]) / 300.0))
        limb_col = tuple((DAY_HORIZON[i] * 0.5 + DAY_MID[i] * 0.5) / 255.0 for i in range(3))
        sd = sum(dirv[i] * SUN_TO[i] for i in range(3))
        sun_side = 0.55 + 0.45 * max(0.0, min(1.0, sd)) ** 2
        fade = (u["u_space"] if u["u_limb_gate"] > 0.5 else 1.0) * (u["u_body_loaded"] if u["u_limb_loaded"] > 0.5 else 1.0)
        col = tuple(col[i] / 255.0 + limb_col[i] * limb * u["u_limb_amount"] * sun_side * fade for i in range(3))
        col = tuple(min(1.0, v) * 255.0 for v in col)
    sd = sum(dirv[i] * SUN_TO[i] for i in range(3))
    up = max(0.0, min(1.0, sd))
    disc = smoothstep(0.99894, 0.99985, sd) * SUN_AMOUNT
    glow = (up ** 24 * 0.60 + up ** 5 * 0.22) * SUN_AMOUNT * (1.0 - u["u_space"])
    col = tuple(col[i] / 255.0 + (SUN_CORE[i] / 255.0) * disc + (SUN_HALO[i] / 255.0) * glow for i in range(3))
    return col


def sky_model_after(dirv, u):
    """The AC-0417 sky (final): local zenith + two colours + one cone +
    the A window + the limb at the A shell (clause D). Verbatim port of
    sky_on() in aero_sky_gradient.gdshader (the shader clamps only the
    limb FACTOR, not col - the port matches that)."""
    upc = tuple(-v for v in u["u_limb_center"])
    r = math.sqrt(sum(v * v for v in upc))
    if r > 0.0:
        hl = sum(dirv[i] * upc[i] for i in range(3)) / r
    else:
        hl = dirv[1]
    below = min(1.0, (1.0 if hl < 0.0 else 0.0) + (0.0 if r > u["u_limb_radius"] else 1.0))
    air = tuple(v / 255.0 for v in u["u_air"])
    sp = tuple(v / 255.0 for v in SPACE)
    col = mix(sp, air, below * (1.0 - u["u_space_sky"]))
    if u["u_limb_amount"] > 0.0:
        # clause D: the A-shell tangent (u_atmo_radius = R + A, falloff
        # 0.25 A); a 0.0 (no push) falls back to the pre-AC-0417 rim.
        lr = u["u_atmo_radius"] if u["u_atmo_radius"] > 0.0 else u["u_limb_radius"]
        if lr > 0.0:
            lf = u["u_atmo_falloff"] if u["u_atmo_falloff"] > 0.0 else 300.0
            lc = u["u_limb_center"]
            b = math.sqrt(max(0.0,
                              (lc[1] * dirv[2] - lc[2] * dirv[1]) ** 2 +
                              (lc[2] * dirv[0] - lc[0] * dirv[2]) ** 2 +
                              (lc[0] * dirv[1] - lc[1] * dirv[0]) ** 2))
            limb = min(1.0, math.exp(-(b - lr) / lf))
            limb_col = tuple((DAY_HORIZON[i] * 0.5 + DAY_MID[i] * 0.5) / 255.0 for i in range(3))
            sd = sum(dirv[i] * SUN_TO[i] for i in range(3))
            sun_side = 0.55 + 0.45 * max(0.0, min(1.0, sd)) ** 2
            # the A-window re-derivation: when ON the rim's altitude gate
            # rides u_space_sky (the sky IS space at A, so the rim is too);
            # OFF keeps the AC-0401 u_space exactly (bit-for-bit).
            fade = (u["u_space_sky"] if u["u_limb_gate"] > 0.5 else 1.0) * (u["u_body_loaded"] if u["u_limb_loaded"] > 0.5 else 1.0)
            col = tuple(col[i] + limb_col[i] * limb * u["u_limb_amount"] * sun_side * fade for i in range(3))
    sd = sum(dirv[i] * SUN_TO[i] for i in range(3))
    up = max(0.0, min(1.0, sd))
    disc = smoothstep(0.99894, 0.99985, sd) * SUN_AMOUNT
    glow = (up ** 24 * 0.60 + up ** 5 * 0.22) * SUN_AMOUNT * (1.0 - u["u_space_sky"])
    col = tuple(col[i] + (SUN_CORE[i] / 255.0) * disc + (SUN_HALO[i] / 255.0) * glow for i in range(3))
    return col


SKY = {"before": sky_model_before, "after": sky_model_after}


def load_run(path):
    with open(path) as f:
        return json.load(f)


def camera_basis(run, W=1280, H=720):
    """Mirror the harness planet preset exactly. Returns (pos, f, u, r, cen)."""
    R = float(run["R"])
    cen = (0.0, -R, 0.0)
    spn = tuple(float(v) for v in run["spawn"])
    up = tuple((v - cen[i]) for i, v in enumerate(spn))
    nl = math.sqrt(sum(v * v for v in up))
    up = tuple(v / nl for v in up)
    off = run.get("off") or [0.0, 0.0]
    if float(off[0]) != 0.0 or float(off[1]) != 0.0:
        # the preset projects the offset position ONTO THE R SPHERE (the
        # altitude then rides the new radial) - unset offset keeps the
        # spawn point exactly (radius |spawn| - R above the sphere).
        o = (float(off[0]), 0.0, float(off[1]))
        dot = o[0] * up[0] + o[1] * up[1] + o[2] * up[2]
        prj = tuple(o[i] - up[i] * dot for i in range(3))
        pt = tuple(spn[i] + prj[i] for i in range(3))
        d = tuple(pt[i] - cen[i] for i in range(3))
        dl = math.sqrt(sum(v * v for v in d))
        spn = tuple(cen[i] + d[i] * R / dl for i in range(3))
        up = tuple((spn[i] - cen[i]) / R for i in range(3))
    alt = float(run["alt"])
    pos = tuple(spn[i] + up[i] * alt for i in range(3))
    a = tuple(pos[i] - cen[i] for i in range(3))
    alen = math.sqrt(sum(v * v for v in a))
    cg = max(0.0, min(1.0, R / alen))
    sg = math.sqrt(max(0.0, 1.0 - cg * cg))
    ref = (0.0, 0.0, 1.0)
    an = math.sqrt(sum(v * v for v in a))
    if abs((a[0] / an) * ref[0] + (a[1] / an) * ref[1] + (a[2] / an) * ref[2]) > 0.99:
        ref = (1.0, 0.0, 0.0)
    hd = (ref[1] * a[2] - ref[2] * a[1], ref[2] * a[0] - ref[0] * a[2], ref[0] * a[1] - ref[1] * a[0])
    hl = math.sqrt(sum(v * v for v in hd))
    hd = tuple(v / hl for v in hd)
    if run.get("nadir"):
        f = tuple(-v for v in up)
        cu = hd
    else:
        tanpt = tuple(cen[i] + a[i] * (R * cg / alen) + hd[i] * (R * sg) for i in range(3))
        f = tuple((tanpt[i] - pos[i]) for i in range(3))
        fl = math.sqrt(sum(v * v for v in f))
        f = tuple(v / fl for v in f)
        cu = up
    # look_at makes the camera up the PROJECTION of the hint onto the plane
    # perpendicular to the view - f and cu must be orthonormal for the
    # pinhole tan-math in pix_dir to hold.
    dcf = f[0] * cu[0] + f[1] * cu[1] + f[2] * cu[2]
    cu = (cu[0] - f[0] * dcf, cu[1] - f[1] * dcf, cu[2] - f[2] * dcf)
    cn = math.sqrt(sum(v * v for v in cu))
    cu = tuple(v / cn for v in cu)
    r = (f[1] * cu[2] - f[2] * cu[1], f[2] * cu[0] - f[0] * cu[2], f[0] * cu[1] - f[1] * cu[0])
    rn = math.sqrt(sum(v * v for v in r))
    r = tuple(v / rn for v in r)
    return pos, f, cu, r, cen


def pix_dir(px, py, W, H, f, u, r):
    th = (px - W / 2.0) / (H / 2.0) * HALF
    tv = (H / 2.0 - py) / (H / 2.0) * HALF
    d = (f[0] + r[0] * th + u[0] * tv, f[1] + r[1] * th + u[1] * tv, f[2] + r[2] * th + u[2] * tv)
    n = math.sqrt(sum(v * v for v in d))
    return tuple(v / n for v in d)


def uniforms(run, pos, cen):
    R = float(run["R"])
    u = {
        "u_space": float(run.get("u_space", -1.0)),
        "u_space_sky": float(run.get("u_space_sky", -1.0)),
        "u_sky_alt": float(run.get("u_sky_alt", -1.0)),
        "u_air": [float((run.get("u_air") or [208, 241, 251])[i]) for i in range(3)],
        "u_limb_center": tuple(cen[i] - pos[i] for i in range(3)),
        "u_limb_radius": R + float(run["sea"]),
        "u_limb_amount": 0.55,
        "u_limb_gate": 1.0,
        "u_limb_loaded": 1.0,
        "u_body_loaded": 1.0,
        # AC-0417 clause D: the A-shell limb (Aero.atmo_limb_radius/falloff:
        # R + A, 0.25 A; the default A = 1200 m, env AWECRAFT_ATMO - a run
        # may override with "atmo").
        "u_atmo_radius": R + float(run.get("atmo", 1200.0)),
        "u_atmo_falloff": 0.25 * float(run.get("atmo", 1200.0)),
    }
    return u


def stats(vals):
    vals = sorted(vals)
    n = len(vals)
    med = vals[n // 2]
    mean = sum(vals) / n
    p999 = vals[min(n - 1, int(n * 0.999))]
    return mean, med, p999, vals[0], vals[-1]


def patch_stats(img, x0, y0, x1, y1):
    px = img.load()
    out = {ch: [] for ch in "rgb"}
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            p = px[x, y]
            out["r"].append(p[0])
            out["g"].append(p[1])
            out["b"].append(p[2])
    return {k: c8(stats(v)) for k, v in out.items()}  # (mean, med, p999, min, max) per channel


H_DEF = 720.0


def deg2px(deg, H=H_DEF):
    """Pinhole: a direction `deg` degrees above the frame axis sits this many
    px above the frame centre (y decreases upward)."""
    return (H / 2.0) * math.tan(math.radians(deg)) / HALF


def px2deg(px, H=H_DEF):
    return math.degrees(math.atan(px / (H / 2.0) * HALF))


def geom_note(run, W=1280, H=720):
    """The strip geometry (limb aim) and the ring geometry (nadir)."""
    R = float(run["R"])
    RB = R + float(run["sea"])
    pos, f, cu, r, cen = camera_basis(run, W, H)
    alen = math.sqrt(sum((pos[i] - cen[i]) ** 2 for i in range(3)))
    note = {"cam_radius": round(alen, 1), "true_alt_rad": round(alen - R, 1)}
    if not run.get("nadir"):
        dep_R = math.degrees(math.acos(max(-1.0, min(1.0, R / alen))))
        dep_RB = math.degrees(math.acos(max(-1.0, min(1.0, RB / alen))))
        limb_row = deg2px(dep_R - dep_RB, H)  # px above frame centre
        note["depression_R"] = round(dep_R, 2)
        note["depression_RB"] = round(dep_RB, 2)
        note["limb_row_above_centre"] = round(limb_row, 1)
    else:
        ff = float(run["fog_far"])
        edge = float(run["render_edge"])
        phis = {}
        for lab, d in (("inner", ff), ("outer", edge)):
            c = (alen * alen + RB * RB - d * d) / (2.0 * alen * RB)
            phis[lab] = math.degrees(math.acos(max(-1.0, min(1.0, c))))
        note["ring_deg"] = [round(phis["inner"], 2), round(phis["outer"], 2)]
        note["ring_px"] = [round(deg2px(phis["inner"], H), 1),
                           round(deg2px(phis["outer"], H), 1)]
        note["nadir_d"] = round(alen - RB, 1)
    return note


def cmd_strip(png, run):
    img = Image.open(png).convert("RGB")
    W, H = img.size
    pos, f, cu, r, cen = camera_basis(run, W, H)
    u = uniforms(run, pos, cen)
    note = geom_note(run, W, H)
    limb_row = note["limb_row_above_centre"]  # px above the frame centre
    # the sky strip: from the frame top down to 4 px ABOVE the disc limb
    # (the limb itself carries the clamped limb glow - excluded).
    y0 = 4
    y1 = int(H / 2.0 - limb_row) - 4
    x0, x1 = int(W / 2.0 - 100), int(W / 2.0 + 99)
    model = SKY[run["tree"]]
    px = img.load()
    deltas = []
    raw = {ch: [] for ch in range(3)}
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            d = pix_dir(x + 0.5, y + 0.5, W, H, f, cu, r)
            col = model(d, u)
            g = 1.0 - (y + 0.5) / H  # wash UV.y: 0 bottom, 1 top
            wa = WASH_AMOUNT_BASE * (1.0 - u["u_space"])
            pred = pipeline(col, wash_g=g, wash_amt=wa)
            p = px[x, y]
            for i in range(3):
                deltas.append(abs(p[i] - pred[i]))
                raw[i].append(p[i])
    st = stats(deltas)

    def band(ya, yb):
        acc = {i: [] for i in range(3)}
        for y in range(ya, yb + 1):
            for x in range(x0, x1 + 1):
                p = px[x, y]
                for i in range(3):
                    acc[i].append(p[i])
        return [c8(stats(acc[i])) for i in range(3)]

    # same-local-elevation bands: the top 20 rows are at the same local
    # elevation in every run (the frame geometry is identical for equal
    # altitudes), so the A-vs-B difference of `top20` is the pure
    # position-dependence of the painted sky (F1).
    out = {
        "frame": png, "run": {k: run.get(k) for k in ("preset", "alt", "off", "nadir", "tree", "time")},
        "geometry": note,
        "strip": {"x": [x0, x1], "y": [y0, y1]},
        "raw_rgb": [c8(stats(raw[i])) for i in range(3)],
        "top20": band(y0, y0 + 19),
        "bottom20": band(y1 - 19, y1),
        "model_delta": {"mean": round(st[0], 2), "median": round(st[1], 2),
                        "p999": round(st[2], 2), "max": st[4]},
        "pushed": {k: u[k] for k in ("u_space", "u_space_sky", "u_sky_alt", "u_air")},
    }
    return out


def cmd_ring(png, run):
    """F3: the coverage-gap annulus in the nadir view (the body's op 0->1
    ring). FINDING this ticket (B5 capture): at true altitude 341 m the
    annulus background is the VOXEL SEA (the terrain occludes the sky -
    the body gap sits over the sea, so the sky is never the visible
    background there). The honest report is therefore: (a) the raw
    annulus statistics (what is actually visible: sea/body), and (b) the
    MODEL sky at the same pixels (what the background WOULD be where the
    tiers draw nothing - the air colour after AC-0417, the dark
    below-horizon branch before). The old linear-space intercept fit was
    removed: it mixed post-tonemap pixels with pre-tonemap model values
    (different spaces) and assumed the background was the sky, which the
    scene does not give at nadir."""
    img = Image.open(png).convert("RGB")
    W, H = img.size
    pos, f, cu, r, cen = camera_basis(run, W, H)
    u = uniforms(run, pos, cen)
    note = geom_note(run, W, H)
    R = float(run["R"])
    RB = R + float(run["sea"])
    alen = math.sqrt(sum((pos[i] - cen[i]) ** 2 for i in range(3)))
    ff = float(run["fog_far"])
    edge = float(run["render_edge"])
    rpx_lo = max(2.0, deg2px(note["ring_deg"][0], H) - 1.0)
    rpx_hi = deg2px(note["ring_deg"][1], H) - 1.0
    model = SKY[run["tree"]]
    pxi = img.load()
    raw = {i: [] for i in range(3)}
    bg8 = {i: [] for i in range(3)}
    n = 0
    ops = []
    for y in range(int(H / 2.0 - rpx_hi), int(H / 2.0 + rpx_hi) + 1):
        for x in range(int(W / 2.0 - rpx_hi), int(W / 2.0 + rpx_hi) + 1):
            dx, dy = x - W / 2.0, y - H / 2.0
            rad = math.sqrt(dx * dx + dy * dy)
            if rad < rpx_lo or rad > rpx_hi:
                continue
            phi = px2deg(rad, H) * math.pi / 180.0
            d = math.sqrt(alen * alen + RB * RB - 2.0 * alen * RB * math.cos(phi))
            if d < ff or d > edge:
                continue
            op = smoothstep(ff, edge, d)
            if op < 0.01 or op > 0.99:
                continue
            n += 1
            ops.append(op)
            p = pxi[x, y]
            for i in range(3):
                raw[i].append(p[i])
            # the model sky at this pixel (display 0-1) through the full
            # Forward+ chain (the wash quad rides u_space - main.gd,
            # unchanged by AC-0417):
            dirv = pix_dir(x + 0.5, y + 0.5, W, H, f, cu, r)
            col = model(dirv, u)
            g = 1.0 - (y + 0.5) / H
            wa = WASH_AMOUNT_BASE * (1.0 - u["u_space"])
            pred = pipeline(col, wash_g=g, wash_amt=wa)
            for i in range(3):
                bg8[i].append(pred[i])
    if not n:
        return {"frame": png, "error": "no annulus samples (check the geometry note)", "geometry": note}
    return {
        "frame": png,
        "run": {k: run.get(k) for k in ("alt", "tree", "time")},
        "geometry": note,
        "n_samples": n,
        "op_range": [round(min(ops), 3), round(max(ops), 3)],
        "annulus_raw_rgb": [c8(stats(raw[i])) for i in range(3)],
        "model_sky_bg_8bit": [c8(stats(bg8[i])) for i in range(3)],
        "note": ("the visible annulus is sea/body (the terrain occludes the "
                 "sky at nadir - F3's sky background is the model_sky_bg_8bit "
                 "column; where the tiers draw nothing the sky IS that colour"),
    }


def cmd_patch(png, run):
    img = Image.open(png).convert("RGB")
    x0, y0, x1, y1 = [int(v) for v in run["patch"]]
    st = patch_stats(img, x0, y0, x1, y1)
    return {"frame": png, "run": {k: run.get(k) for k in ("preset", "alt", "tree", "time")},
            "patch": [x0, y0, x1, y1], "rgb": st}


def cmd_ladder(logs):
    out = []
    for path in logs:
        with open(path) as f:
            txt = f.read()
        m = re.search(r"RESULT (\{.*\})", txt)
        if not m:
            out.append({"log": path, "error": "no RESULT line"})
            continue
        try:
            res = json.loads(m.group(1))
        except json.JSONDecodeError:
            out.append({"log": path, "error": "RESULT is not JSON: " + m.group(1)[:120]})
            continue
        if "planet" not in res:
            out.append({"log": path, "error": "not a planet-preset RESULT"})
            continue
        sky = res.get("sky", {})
        alt_param = res.get("alt")
        row = {"log": path, "alt_param": alt_param,
               "u_space": sky.get("u_space"), "u_space_sky": sky.get("u_space_sky"),
               "u_sky_alt": sky.get("u_sky_alt"), "u_air": sky.get("u_air"),
               "body_phase": res.get("body_phase")}
        # true radial altitude: the preset flies spawn + radial*alt_param, and
        # the spawn sits 141 m above the R sphere (|spawn - cen| - R; the
        # measured player altitude at alt_param 700 is 841.0, confirmed by
        # the pushed u_space back-solve). With an in-plane offset the
        # position is projected ONTO the R sphere first, so the true
        # altitude is exactly alt_param.
        off = res.get("cam_off") or [0.0, 0.0]
        row["true_alt_rad"] = alt_param + (0.0 if (off[0] or off[1]) else 141.0)
        # op_nadir (satellite_body opacity_at(nadir_d), nadir_d = true_alt - SEA):
        row["op_nadir"] = round(smoothstep(332.0, 400.0, row["true_alt_rad"] - 126.0), 3)
        # star opacity (day = 1 at T0.5): before = S (physics), after = ws
        row["star_op"] = round(sky.get("u_space") if row["u_sky_alt"] < 0.5 else sky.get("u_space_sky"), 3)
        # back-solved altitude from u_space_sky on the pushing tree:
        if sky.get("u_space_sky") is not None:
            if row["u_sky_alt"] >= 0.5:
                row["back_solved_alt"] = round(ss_inv(300.0, 1200.0, sky["u_space_sky"]), 1)
            else:
                row["back_solved_alt"] = round(ss_inv(500.0, 3200.0, sky["u_space_sky"]), 1)
        out.append(row)
    return out


def main():
    cmd = sys.argv[1]
    if cmd == "ladder":
        res = cmd_ladder(sys.argv[2:])
    elif cmd == "strip":
        res = cmd_strip(sys.argv[2], load_run(sys.argv[3]))
    elif cmd == "ring":
        res = cmd_ring(sys.argv[2], load_run(sys.argv[3]))
    elif cmd == "patch":
        res = cmd_patch(sys.argv[2], load_run(sys.argv[3]))
    else:
        print(__doc__)
        sys.exit(2)
    print(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
