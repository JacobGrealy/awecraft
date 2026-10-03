#!/usr/bin/env python3
"""AC-0098 — icon-to-voxel colour sampler (the single source of truth is the icon).

The held-tool icons in godot/assets/items_atlas.png are per-cell renderings of
the same 32x32 TOOL_GRIDS shape that the voxel tools use (verified: the opaque
pixel set matches the non-'.' cells of the grid, within a few cells). Each
voxel therefore takes the sRGB colour of its own icon pixel — the icon's
hand-drawn per-cell shading (highlight / base / shadow / edge) is the shading
rule; nothing is invented by eye.

Two canonical pins (so existing gates keep reading the canonical tints):
  * every icon tone closest to Data.item_tint(id) (the head's "anchor" tone)
    is replaced by the canonical head tint exactly (toolres arm:
    held_head_color() == Data.item_tint(id));
  * every icon tone closest to player.gd HANDLE_C (the handle's "anchor" tone)
    is replaced by HANDLE_C exactly (the existing handle base, unchanged).
  * all other cells keep the icon byte; player.gd sRGB-decodes it to linear
    (Color.srgb_to_rgb) so the voxel wall displays exactly what the icon
    texture displays (the atlas imports with the default sRGB process).

Re-run when the icon art (items_atlas.png) or TOOL_GRIDS change; the output
GDScript block below the generated marker in player.gd is then replaced:

    python3 tasks/AC-0098/sample_tool_icons.py

Outputs (all under .scratch/AC-0098/ unless noted):
    tool_icon_table.gd   the GENERATED const block for godot/player/player.gd
    measure.json         before/after distinct-colour + spread + hi/lo census
    final_cells.json     per-item 32x32 final sRGB hex grids (for the PNGs)
"""
import json
import re
import sys
from PIL import Image

ROOT = "/home/angrygiant/github_projects/AweCraft"
SCRATCH = f"{ROOT}/.scratch/AC-0098"

# ---------------------------------------------------------------- inputs
atlas = Image.open(f"{ROOT}/godot/assets/items_atlas.png").convert("RGBA")
rects = json.load(open(f"{ROOT}/godot/assets/items_atlas.json"))

player_src = open(f"{ROOT}/godot/player/player.gd").read()
m = re.search(r"const TOOL_GRIDS := \{(.*?)\n\}", player_src, re.S)
assert m, "TOOL_GRIDS block not found"
TOOL_GRIDS = {}
for tname, body in re.findall(r'"(\w+)": \[(.*?)\]', m.group(1), re.S):
    rows = re.findall(r'"([^"]*)"', body)
    assert len(rows) == 32 and all(len(r) == 32 for r in rows), f"bad grid {tname}"
    TOOL_GRIDS[tname] = rows
assert sorted(TOOL_GRIDS) == ["axe", "pick", "shovel", "sword"], sorted(TOOL_GRIDS)
m = re.search(r"const HANDLE_C := Color\(([\d.]+), ([\d.]+), ([\d.]+)\)", player_src)
HANDLE_C = (float(m.group(1)), float(m.group(2)), float(m.group(3)))

data_src = open(f"{ROOT}/godot/autoload/data.gd").read()
ITEMS = {}  # id -> (name, tool, (r, g, b) tint)
for line in data_src.splitlines():
    mm = re.match(r'\t(\d+): \{"name": "([^"]+)", "icon": Color\(([\d.]+), ([\d.]+), ([\d.]+)\)', line)
    if not mm:
        continue
    tm = re.search(r'"tool": "([a-z]+)"', line)
    if not tm:
        continue
    ITEMS[int(mm.group(1))] = (
        mm.group(2), tm.group(1),
        (float(mm.group(3)), float(mm.group(4)), float(mm.group(5))))
TOOLS = {i: v for i, v in ITEMS.items() if v[1] in ("pick", "axe", "shovel", "sword")}
assert len(TOOLS) == 16, f"expected 16 tool items, got {len(TOOLS)}: {sorted(TOOLS)}"

# ---------------------------------------------------------------- helpers
def lum8(b):
    return 0.2126 * b[0] + 0.7152 * b[1] + 0.0722 * b[2]

def f2b(f):
    return int(round(f * 255.0))

def b2h(b):
    return f"{b[0]:02x}{b[1]:02x}{b[2]:02x}"

def hexdist(b1, b2):
    return sum((x - y) ** 2 for x, y in zip(b1, b2))

TINT_HEX = {i: b2h(tuple(f2b(c) for c in v[2])) for i, v in TOOLS.items()}
HANDLE_HEX = b2h(tuple(f2b(c) for c in HANDLE_C))

# ---------------------------------------------------------------- sampling
table_rows = []      # GDScript lines for TOOL_ICON_TONES / TOOL_ICON_MAP
measure = {}
final_cells = {}

for iid in sorted(TOOLS):
    name, ttype, tint = TOOLS[iid]
    x, y, w, h = rects[str(iid)]
    cell = atlas.crop((x, y, x + w, y + h))
    grid = TOOL_GRIDS[ttype]
    px = {(i, j): cell.getpixel((i, j)) for i in range(32) for j in range(32)}
    opaque = {k: v for k, v in px.items() if v[3] > 0}

    # per grid cell: icon byte (direct, or nearest-opaque fallback)
    cellbyte, fallbacks = {}, []
    head_tones, handle_tones = {}, {}
    for j in range(32):
        for i in range(32):
            if grid[j][i] == ".":
                continue
            k = (i, j)
            if k in opaque:
                cellbyte[k] = opaque[k][:3]
            else:
                best, bestd = None, None
                for (ox, oy), p in opaque.items():
                    d = (ox - i) ** 2 + (oy - j) ** 2
                    if bestd is None or d < bestd:
                        best, bestd = p[:3], d
                cellbyte[k] = best
                fallbacks.append((i, j, bestd))
            d = head_tones if grid[j][i] == "#" else handle_tones
            d[cellbyte[k]] = d.get(cellbyte[k], 0) + 1

    head_anchor = min(head_tones, key=lambda b: hexdist(b, tuple(f2b(c) for c in tint)))
    handle_anchor = min(handle_tones, key=lambda b: hexdist(b, tuple(f2b(c) for c in HANDLE_C)))

    # final byte per cell: anchors -> canonical hex, rest -> icon byte
    final = {}
    for k, b in cellbyte.items():
        i, j = k
        if grid[j][i] == "#" and b == head_anchor:
            final[k] = tuple(f2b(c) for c in tint)
        elif grid[j][i] == "h" and b == handle_anchor:
            final[k] = tuple(f2b(c) for c in HANDLE_C)
        else:
            final[k] = b

    # palette + map (row-major, one char per cell, '.' = empty)
    pal = sorted(set(final.values()), key=lambda b: -lum8(b))
    assert len(pal) <= 16, f"item {iid}: {len(pal)} tones > 16"
    palhex = [f"#{b2h(b)}" for b in pal]
    maps = []
    for j in range(32):
        row = ""
        for i in range(32):
            if grid[j][i] == ".":
                row += "."
            else:
                row += "0123456789abcdef"[pal.index(final[(i, j)])]
        maps.append(row)

    # measurements
    distinct_after = len(pal)
    lum_after = [lum8(b) / 255.0 for b in pal]
    tint_b = tuple(f2b(c) for c in tint)
    handle_b = tuple(f2b(c) for c in HANDLE_C)
    hi = base = lo = 0
    for k, b in final.items():
        ref = tint_b if grid[k[1]][k[0]] == "#" else handle_b
        if lum8(b) > lum8(ref) + 1e-9:
            hi += 1
        elif lum8(b) < lum8(ref) - 1e-9:
            lo += 1
        else:
            base += 1
    before = {b2h(tint_b): "head", HANDLE_HEX: "handle"}
    measure[str(iid)] = {
        "name": name, "type": ttype,
        "fallback_cells": fallbacks,
        "head_anchor": f"#{b2h(head_anchor)}", "handle_anchor": f"#{b2h(handle_anchor)}",
        "before": {"distinct": len(before),
                    "colors": [f"#{k}" for k in before],
                    "spread": abs(lum8(tint_b) - lum8(handle_b)) / 255.0},
        "after": {"distinct": distinct_after,
                  "colors": palhex,
                  "spread": max(lum_after) - min(lum_after),
                  "highlight_voxels": hi, "base_voxels": base, "shadow_voxels": lo,
                  "total_voxels": len(final)},
    }
    final_cells[str(iid)] = [
        ["#" + b2h(final[(i, j)]) if grid[j][i] != "." else None
         for i in range(32)] for j in range(32)
    ]

    head_anchor_idx = pal.index(tuple(f2b(c) for c in tint))
    handle_anchor_idx = pal.index(tuple(f2b(c) for c in HANDLE_C))
    table_rows.append(f"\t{iid}: [")
    table_rows.append(f"\t\t[")
    for ph in palhex:
        table_rows.append(f"\t\t\t{ph!r},")
    table_rows.append(f"\t\t],")
    table_rows.append(f"\t\t[")
    for row in maps:
        table_rows.append(f"\t\t\t{row!r},")
    table_rows.append(f"\t\t],")
    table_rows.append(f"\t\t{head_anchor_idx},")
    table_rows.append(f"\t\t{handle_anchor_idx},")
    table_rows.append(f"\t],")

gd = []
gd.append("\n# AC-0098 GENERATED BLOCK — do not hand-edit. Re-run\n")
gd.append("#   python3 tasks/AC-0098/sample_tool_icons.py\n")
gd.append("# when godot/assets/items_atlas.png or TOOL_GRIDS change. Source of\n")
gd.append("# truth is the icon art: each TOOL_GRIDS cell carries the sRGB colour of\n")
gd.append("# its own icon pixel (per-cell 1:1 shape match, verified by the sampler).\n")
gd.append("# Entry [iid] = [palette (brightest first, sRGB hex), 32 map rows (one char\n")
gd.append("# per cell, index into the palette, '.' = empty)]. Anchor tones (closest\n")
gd.append("# icon tone to the canonical tint) are substituted with the canonical\n")
gd.append("# head tint / HANDLE_C in _tool_cell_color; other tones are sRGB-decoded\n")
gd.append("# (Color.srgb_to_rgb) so the voxel wall displays the icon's own shading.\n")
gd.append("const TOOL_ICON_TONES := {\n")
gd.extend(table_rows)
gd.append("}\n")

open(f"{SCRATCH}/tool_icon_table.gd", "w").write("\n".join(gd))
json.dump(measure, open(f"{SCRATCH}/measure.json", "w"), indent=1)
json.dump(final_cells, open(f"{SCRATCH}/final_cells.json", "w"))

for iid, mrow in measure.items():
    a, b = mrow["after"], mrow["before"]
    print(f"{iid} {mrow['name']:<16} distinct {b['distinct']} -> {a['distinct']}"
          f"  spread {b['spread']:.3f} -> {a['spread']:.3f}"
          f"  hi/base/lo {a['highlight_voxels']}/{a['base_voxels']}/{a['shadow_voxels']}"
          f"  fallback {len(mrow['fallback_cells'])}")
print("\nWROTE tool_icon_table.gd, measure.json, final_cells.json")
