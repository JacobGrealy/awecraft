import json, sys, time
from playwright.sync_api import sync_playwright
from PIL import Image

URL = "https://localhost:8443/"
OUTDIR = "/home/angrygiant/github_projects/AweCraft/tasks/AC-0058"

MEASURE = """
() => {
  const c = document.getElementById('canvas');
  const r = c.getBoundingClientRect();
  return {
    innerWidth: window.innerWidth, innerHeight: window.innerHeight,
    dpr: window.devicePixelRatio,
    styleW: c.style.width, styleH: c.style.height,
    clientW: c.clientWidth, clientH: c.clientHeight,
    bufW: c.width, bufH: c.height,
    rectX: r.x, rectY: r.y, rectW: r.width, rectH: r.height,
    injected: document.head.innerHTML.indexOf('MutationObserver') !== -1,
  };
}
"""

def measure(page, tag):
    m = page.evaluate(MEASURE)
    m["tag"] = tag
    print(json.dumps(m), flush=True)
    return m

def black_frac(path):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    px = im.load()
    tot = blk = 0
    for y in range(0, h, 4):
        for x in range(0, w, 4):
            c = px[x, y]
            tot += 1
            if c[0] < 12 and c[1] < 12 and c[2] < 12:
                blk += 1
    return blk / tot

def black_runs(path):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    px = im.load()
    def is_black(c): return c[0] < 12 and c[1] < 12 and c[2] < 12
    row = [is_black(px[x, h // 2]) for x in range(0, w, 4)]
    col = [is_black(px[w // 2, y]) for y in range(0, h, 4)]
    def runs(arr):
        out = []
        s = 0
        for i in range(1, len(arr) + 1):
            if i == len(arr) or arr[i] != arr[s]:
                out.append((s * 4, i * 4, arr[s]))
                s = i
        return [r for r in out if r[2]]
    return w, h, runs(row), runs(col)

def changed_ratio(pa, pb):
    a = Image.open(pa).convert("RGB")
    b = Image.open(pb).convert("RGB")
    w = min(a.width, b.width)
    h = min(a.height, b.height)
    a = a.crop((0, 0, w, h)).resize((320, max(1, int(h * 320 / w))))
    b = b.crop((0, 0, w, h)).resize((320, max(1, int(h * 320 / w))))
    pa_ = a.load()
    pb_ = b.load()
    diff = tot = 0
    for y in range(0, a.height, 2):
        for x in range(0, a.width, 2):
            ta = pa_[x, y]
            tb = pb_[x, y]
            tot += 1
            if abs(ta[0] - tb[0]) + abs(ta[1] - tb[1]) + abs(ta[2] - tb[2]) > 40:
                diff += 1
    return diff / tot

def hotbar_center(path):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    px = im.load()
    xs = set()
    for x in range(0, w, 2):
        for y in range(h - 120, h, 3):
            if max(px[x, y]) > 50:
                xs.add(x)
                break
    return w, (min(xs), max(xs)) if xs else None

errs = []
logs = []
t0 = time.time()

def run_once(p):
    browser = p.chromium.launch(headless=True, args=["--enable-unsafe-swiftshader", "--use-gl=angle", "--use-angle=swiftshader"])
    ctx = browser.new_context(ignore_https_errors=True, viewport={"width": 1920, "height": 1080})
    page = ctx.new_page()
    page.on("console", lambda m: logs.append(m.type + "|" + m.text))
    page.on("pageerror", lambda e: errs.append(str(e)))
    try:
        page.goto(URL, wait_until="domcontentloaded", timeout=300000)
        page.wait_for_selector("canvas", timeout=300000)
        print("canvas at %.0fs" % (time.time() - t0), flush=True)
        page.wait_for_timeout(60000)
        m1 = measure(page, "1920x1080-load")
        page.screenshot(path=OUTDIR + "/ac0058_after_1080.png")
        w, h, row_runs, col_runs = black_runs(OUTDIR + "/ac0058_after_1080.png")
        print("1080 black_runs row=%s col=%s" % (row_runs, col_runs), flush=True)
        print("1080 hotbar: %s" % (hotbar_center(OUTDIR + "/ac0058_after_1080.png"),), flush=True)
        cx, cy = 960, 540
        page.mouse.move(cx, cy)
        page.wait_for_timeout(300)
        page.screenshot(path=OUTDIR + "/ac0058_after_1080_drag0.png")
        page.mouse.down()
        page.wait_for_timeout(400)
        for i in range(12):
            page.mouse.move(cx + (i + 1) * 24, cy - (i + 1) * 8, steps=4)
            page.wait_for_timeout(60)
        page.wait_for_timeout(400)
        page.mouse.up()
        page.wait_for_timeout(1500)
        page.screenshot(path=OUTDIR + "/ac0058_after_1080_drag1.png")
        ratio = changed_ratio(OUTDIR + "/ac0058_after_1080_drag0.png", OUTDIR + "/ac0058_after_1080_drag1.png")
        print("mouse_changed_ratio=%.4f" % ratio, flush=True)
        page.set_viewport_size({"width": 1366, "height": 768})
        page.wait_for_timeout(6000)
        m2 = measure(page, "1366x768-after-resize")
        page.screenshot(path=OUTDIR + "/ac0058_after_1366.png")
        w2, h2, row_runs2, col_runs2 = black_runs(OUTDIR + "/ac0058_after_1366.png")
        print("1366 black_runs row=%s col=%s" % (row_runs2, col_runs2), flush=True)
        globals().update(dict(m1=m1, m2=m2, ratio=ratio, col_runs=col_runs,
                              row_runs=row_runs, row_runs2=row_runs2, col_runs2=col_runs2))
    finally:
        browser.close()

with sync_playwright() as p:
    for attempt in range(1, 4):
        try:
            run_once(p)
            break
        except Exception as e:
            print("ATTEMPT %d FAILED: %s" % (attempt, str(e).splitlines()[-1]), flush=True)
            if attempt == 3:
                raise
            time.sleep(5)

sel = [l for l in logs if any(k in l.upper() for k in ("SCRIPT ERROR", "ERROR:"))]
with open(OUTDIR + "/console.log", "w") as f:
    for l in logs:
        f.write(l + "\n")
print("pageerrors:", errs[:5], flush=True)
print("== console errors ==")
for l in sel[:20]:
    print("  ", l)

BF1080 = black_frac(OUTDIR + "/ac0058_after_1080.png")
BF1366 = black_frac(OUTDIR + "/ac0058_after_1366.png")
print("black_frac 1080=%.4f 1366=%.4f" % (BF1080, BF1366), flush=True)
g_injected = m1["injected"]
g_fill1080 = (m1["clientW"] == m1["innerWidth"] and m1["clientH"] == m1["innerHeight"]
              and m1["bufW"] == m1["innerWidth"] * int(m1["dpr"]) and m1["bufH"] == m1["innerHeight"] * int(m1["dpr"])
              and BF1080 < 0.02)
g_fill1366 = (m2["clientW"] == m2["innerWidth"] and m2["clientH"] == m2["innerHeight"]
              and m2["bufW"] == m2["innerWidth"] and m2["bufH"] == m2["innerHeight"]
              and BF1366 < 0.02)
g_mouse = ratio > 0.03
real_errs = [e for e in errs if "Pointer Lock" not in e]
print("gate_injected:", g_injected)
print("gate_fill_1080:", g_fill1080)
print("gate_fill_1366:", g_fill1366)
print("gate_mouse:", g_mouse)
print("gate_no_real_pageerrors:", not real_errs)
print("headless pointer-lock artifacts (excluded, headless-only):", [e for e in errs if "Pointer Lock" in e][:2])
ok = g_injected and g_fill1080 and g_fill1366 and g_mouse and not real_errs and not sel
print("gate_all:", ok, flush=True)
sys.exit(0 if ok else 2)
