#!/usr/bin/env python3
"""Auto-fill a task spec.html scaffold from the TASKS.yaml entry + repo facts.

Usage:
    spec_template.py AC-NNNN [--force] [--out PATH]

Writes tasks/AC-NNNN/spec.html (or --out PATH) as a scaffold with two kinds of
sections:

  AUTO  — generated from TASKS.yaml, tasks/HARNESS.md and the data.gd/generator.gd
          constants (parsed fresh at run time so the spec never carries stale
          numbers). Labeled "AUTO (… do not hand-edit)".
  FILL  — the five coordinator-only sections (Goal, Task-specific requirements,
          Task-specific gates, Scope, Fences), each a clear <!-- FILL: … -->
          placeholder with a one-line example. Labeled "FILL BY COORDINATOR".

Exit codes (matching tasks.py conventions):
    0  wrote the spec
    1  spec.html already exists (refuse to overwrite; --force overrides)
       / TASKS.yaml missing / constants file missing / I/O error
    2  unknown task id / malformed id

Stdlib only + PyYAML (tasks.py uses it the same way). No network, no godot.
Read-only on everything except the single spec.html it writes.
"""

import argparse
import re
import sys
from html import escape
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
TASKS_DIR = Path(__file__).resolve().parent.parent
ENV_FILE = "AWECRAFT_TASKS_FILE"
DATA_GD = REPO_ROOT / "godot" / "autoload" / "data.gd"
GEN_GD = REPO_ROOT / "godot" / "world" / "generator.gd"
HARNESS = TASKS_DIR / "HARNESS.md"

ID_RE = re.compile(r"^AC-(\d{4,})$")

# The default battery modes whose RESULT shapes get embedded (HARNESS.md §1/§3).
BATTERY_MODES = ["player", "interact", "light", "fluids", "buckets", "genhash"]

CSS = (
    "body{font:15px/1.5 ui-sans-serif,system-ui,sans-serif;max-width:900px;"
    "margin:24px auto;padding:0 16px;color:#1a1a1a}"
    "h1{font-size:22px}h2{font-size:17px;margin-top:22px;border-bottom:1px solid #ddd;"
    "padding-bottom:4px}h3{font-size:15px;margin-top:18px}"
    "code,pre{font:13px/1.4 ui-monospace,Menlo,monospace}"
    "pre{background:#f4f4f4;padding:10px;border-radius:6px;overflow:auto}"
    "table{border-collapse:collapse;font-size:13px;margin:10px 0}"
    "th,td{border:1px solid #ccc;padding:4px 8px;text-align:left;vertical-align:top}"
    "th{background:#f0f0f0}"
    ".auto{background:#eef4ff;border-left:4px solid #3b6fe0;padding:8px 12px;margin:8px 0;"
    "border-radius:0 6px 6px 0}"
    ".fill{background:#fff8e6;border-left:4px solid #e0a800;padding:8px 12px;margin:10px 0;"
    "border-radius:0 6px 6px 0}"
    ".meta{color:#555;font-size:14px}"
    ".note{font-size:13px;color:#555}"
)


class SpecError(Exception):
    """A user-facing failure with a clean message (no traceback)."""


def _tasks_path():
    import os
    env = os.environ.get(ENV_FILE, "")
    return Path(env).expanduser().resolve() if env else TASKS_DIR / "TASKS.yaml"


def _load_task(task_id):
    p = _tasks_path()
    if not p.exists():
        raise SpecError("TASKS.yaml not found at %s (set %s to override)" % (p, ENV_FILE))
    try:
        data = yaml.safe_load(p.read_text()) or {}
    except yaml.YAMLError as exc:
        raise SpecError("TASKS.yaml at %s is not parseable YAML: %s" % (p, exc))
    for value in data.values():
        if not isinstance(value, list):
            continue
        for item in value:
            if isinstance(item, dict) and item.get("id") == task_id:
                return item
    raise SpecError("unknown task id %r (no such entry in %s)" % (task_id, p.name))


def _parse_gd_constants(path):
    """Parse top-level `const NAME := value` lines -> [(name, value, lineno)]."""
    if not path.exists():
        raise SpecError("constants file not found: %s" % path)
    out = []
    for i, line in enumerate(path.read_text().splitlines(), 1):
        m = re.match(r"^const ([A-Z][A-Z0-9_]*) := (.+)$", line)
        if m:
            out.append((m.group(1), m.group(2).strip(), i))
    return out


def _parse_md_rows(text):
    """Return the data rows of the first markdown table (lists of cells)."""
    rows = []
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("|"):
            cells = [c.strip() for c in s.strip("|").split("|")]
            if all(set(c) <= set("-: ") and c for c in cells):
                continue  # separator row
            rows.append(cells)
    return rows


def _harness_rows():
    """Return (header, rows) for the §1 MODE TABLE.

    The header row is the first table row whose first cell is exactly `mode`;
    data rows follow until the first non-table line. Row cells are backticked
    (e.g. `` `player` ``) and are stripped of backticks on the mode key only."""
    if not HARNESS.exists():
        return []
    text = HARNESS.read_text()
    lines = text.splitlines()
    header = None
    start = -1
    for i, line in enumerate(lines):
        s = line.strip()
        if not s.startswith("|"):
            continue
        cells = [c.strip() for c in s.strip("|").split("|")]
        if cells and cells[0].strip("`").lower() == "mode":
            header = cells
            start = i + 1
            break
    if header is None:
        return []
    rows = []
    for line in lines[start:]:
        s = line.strip()
        if not s.startswith("|"):
            break
        cells = [c.strip() for c in s.strip("|").split("|")]
        if all(set(c) <= set("-: ") and c for c in cells):
            continue  # separator row
        rows.append(cells)
    return header, rows


def _known_stable_rows():
    if not HARNESS.exists():
        return []
    text = HARNESS.read_text()
    idx = text.find("Known-stable gate values")
    if idx < 0:
        return []
    rows = []
    for line in text[idx:].splitlines():
        s = line.strip()
        if s.startswith("|"):
            cells = [c.strip() for c in s.strip("|").split("|")]
            if all(set(c) <= set("-: ") and c for c in cells):
                continue
            rows.append(cells)
    # drop the header row (first)
    return rows[1:] if rows else []


def _const_table_row(name, val, lineno, relpath):
    return ("<tr><td><code>%s</code></td><td><code>%s</code></td>"
            "<td class='note'>%s:%d</td></tr>"
            % (escape(name), escape(val), escape(relpath), lineno))


def _build_html(task, task_id):
    data_consts = _parse_gd_constants(DATA_GD)
    gen_consts = _parse_gd_constants(GEN_GD)
    data_rel = "godot/autoload/data.gd"
    gen_rel = "godot/world/generator.gd"

    harness = _harness_rows()
    if harness:
        header, all_rows = harness
    else:
        header, all_rows = None, []
    hrows = {}
    for r in all_rows:
        if r:
            hrows[(r[0]).strip("`").strip()] = r
    known = _known_stable_rows()

    status = task.get("status", "?")
    title = task.get("title", "")
    source = task.get("source", "")
    priority = task.get("priority", "")
    created = task.get("created_at", "")
    parent = task.get("parent_id") or ""
    notes = task.get("notes") or ""

    parts = []
    a = parts.append

    a("<!DOCTYPE html>")
    a('<html lang="en"><head><meta charset="utf-8">')
    a("<title>%s — spec (generated scaffold)</title>" % task_id)
    a("<style>%s</style></head><body>" % CSS)
    a("<h1>%s — %s</h1>" % (escape(task_id), escape(title)))

    # ---- AUTO header ----
    a('<div class="auto"><b>AUTO (from TASKS.yaml — do not hand-edit)</b></div>')
    a('<p class="meta"><b>id:</b> <code>%s</code> · <b>status:</b> <code>%s</code> '
      "· <b>priority:</b> %s · <b>source:</b> %s · <b>created:</b> %s "
      "· <b>parent:</b> %s</p>"
      % (task_id, escape(status), escape(str(priority)), escape(str(source)),
         escape(str(created)), escape(parent) if parent else "—"))
    a('<p class="note">Registry <code>notes</code> (verbatim, quoted):</p>')
    if notes:
        a("<blockquote><pre>%s</pre></blockquote>" % escape(notes))
    else:
        a("<blockquote><p>(no notes in the registry entry)</p></blockquote>")

    # ---- Goal (FILL) ----
    a('<h2>Goal</h2>')
    a('<div class="fill"><b>FILL BY COORDINATOR</b> — one line, from the registry notes '
      '(marked REVIEW until confirmed). <b>REVIEW</b></div>')
    a('<!-- FILL: Goal — one sentence. Example: "Add a torch-light-bake pass to the '
      'chunk mesher so caves are readable at night." -->')
    a("<p><em>REVIEW — draft from notes: %s</em></p>"
      % (escape(notes.split(".")[0].strip() + ".") if notes else "(no notes)"))

    # ---- Frozen spec refs (AUTO boilerplate) ----
    a('<h2>Frozen spec references</h2>')
    a('<div class="auto"><b>AUTO (fixed boilerplate — do not hand-edit)</b></div>')
    a("<ul>")
    a('<li><code>index.html</code> — build <code>20260816-r12</code> (Three.js single-file) '
      "is the <b>source of truth for ALL behavior/data — do NOT modify</b>. The Godot "
      "port is faithful; when unsure, the web file wins.</li>")
    a('<li>Minecraft wiki = canonical reference for tools/crafting/blocks, match exactly '
      'unless the user specifies otherwise: '
      '<a href="https://minecraft.wiki/w/Tool">Tool</a>, '
      '<a href="https://minecraft.wiki/w/Block">Block</a>, '
      '<a href="https://minecraft.wiki/w/Mining">Mining</a>, '
      '<a href="https://minecraft.wiki/w/Crafting_table">Crafting_table</a>, '
      '<a href="https://minecraft.wiki/w/Item">Item</a>.</li>')
    a("</ul>")

    # ---- Data.* constants (AUTO, parsed) ----
    a('<h2>Data.* world constants</h2>')
    a('<div class="auto"><b>AUTO (parsed from %s + %s at generation time — do not '
      'hand-edit; values are current as of the run)</b></div>' % (escape(data_rel), escape(gen_rel)))
    a("<h3>%s</h3>" % escape(data_rel))
    a("<table><tr><th>const</th><th>value</th><th>file:line</th></tr>")
    for name, val, ln in data_consts:
        a(_const_table_row(name, val, ln, data_rel))
    a("</table>")
    a("<h3>%s</h3>" % escape(gen_rel))
    a("<table><tr><th>const</th><th>value</th><th>file:line</th></tr>")
    for name, val, ln in gen_consts:
        a(_const_table_row(name, val, ln, gen_rel))
    a("</table>")
    a("<p class='note'>Biome thresholds are computed in <code>generator.gd "
      "biome_at()</code> (t &lt; -0.25 snow; t &gt; 0.35 &amp; m &lt; 0.1 desert; "
      "m &gt; 0.25 forest; else plains) — not top-level constants, so they are not in "
      "the tables above.</p>")

    # ---- Verify gates (AUTO) ----
    a('<h2>Verify gates (default)</h2>')
    a('<div class="auto"><b>AUTO (from tasks/HARNESS.md — do not hand-edit)</b></div>')
    a('<div class="auto"><b>G0</b> — <code>~/tools/godot/godot --headless --path godot '
      '--quit</code> exits 0 with <b>zero</b> <code>SCRIPT ERROR</code> lines.</div>')
    a('<div class="auto"><b>AC-0061 tiered protocol</b> — subagent runs the <b>SMOKE</b> '
      'tier (2–4 dependency-mapped modes + genhash); the <b>coordinator</b> runs the '
      '<b>FULL battery</b> before build; the dependency table points at '
      '<code>tasks/AC-0061/AC-0061-results.html</code>.</div>')
    a('<div class="auto"><b>Sandbox env</b> — every godot call is ONE bash command that '
      'sets HOME first; <b>one godot at a time</b> (concurrent runs corrupt the '
      '<code>.godot</code> cache and hang). Scratch to project-local <code>.scratch/</code>.</div>')
    a("<pre>export HOME=/tmp/dsh_home; mkdir -p $HOME; "
      "cd /home/angrygiant/github_projects/AweCraft</pre>")

    # ---- RESULT shapes (AUTO, from HARNESS.md) ----
    a('<h2>Expected RESULT shapes (default battery + genhash)</h2>')
    a('<div class="auto"><b>AUTO (rows pulled from tasks/HARNESS.md §1 — do not '
      'hand-edit)</b></div>')
    if header and hrows:
        a("<table><tr><th>mode</th><th>key RESULT fields</th><th>typical wall</th></tr>")
        field_idx = header.index("key RESULT fields") if "key RESULT fields" in header else 3
        wall_idx = (header.index("typical wall (2026-08-24)")
                    if "typical wall (2026-08-24)" in header else 5)
        for mode in BATTERY_MODES:
            r = hrows.get(mode)
            if not r:
                continue
            fields = r[field_idx] if len(r) > field_idx else ""
            wall = r[wall_idx] if len(r) > wall_idx else ""
            a("<tr><td><code>%s</code></td><td>%s</td><td>%s</td></tr>"
              % (mode, escape(fields), escape(wall)))
        a("</table>")
    else:
        a("<p class='note'>HARNESS.md mode table not found — regenerate after tasks/HARNESS.md exists.</p>")

    # ---- Known-stable values (AUTO) ----
    a('<h2>Known-stable gate values</h2>')
    a('<div class="auto"><b>AUTO (from tasks/HARNESS.md §3, else boilerplate — verify '
      'fresh on any fluids/world-touching change)</b></div>')
    if known:
        a("<table><tr><th>value</th><th>fresh result (2026-08-24)</th><th>established by</th></tr>")
        for cells in known:
            pad = cells + [""] * (3 - len(cells))
            a("<tr><td>%s</td><td>%s</td><td>%s</td></tr>"
              % (escape(pad[0]), escape(pad[1]), escape(pad[2])))
        a("</table>")
    else:
        a('<p class="note">sea 2730/2730 · backed 1406/1406 · sea_stable true · '
          "water_on_lava 25 / sideways 9 · drop_spawned/place_ok true · torch 14 · "
          "genhash 25/25 — <b>verify fresh</b> (HARNESS.md §3 not parsed).</p>")

    # ---- FILL sections ----
    for heading, hint, example in [
        ("Task-specific requirements",
         "the concrete behavior/data changes this task makes",
         "e.g. \"fluids: source water over a hole writes 0 cells (zero-write invariant)\""),
        ("Task-specific gates",
         "the specific mode(s)/values that must be green beyond the defaults",
         "e.g. \"G1: AWECRAFT_LOGIC=fluids → sea_stable true, sea_surface 2730\""),
        ("Scope (files expected to change)",
         "the exact files this task will edit (helps G5 stay clean)",
         "e.g. \"godot/world/chunk.gd, godot/scenes/main.gd (fluids branch only)\""),
        ("Fences",
         "what this task must NOT touch",
         "e.g. \"no .gd outside the listed scope; no TASKS.yaml edits; no git\""),
    ]:
        a('<h2>%s</h2>' % escape(heading))
        a('<div class="fill"><b>FILL BY COORDINATOR</b> — %s.</div>' % escape(hint))
        a("<!-- FILL: %s. Example: %s -->" % (escape(heading), escape(example)))

    a('<p class="note">Scaffold generated by <code>tasks/scripts/spec_template.py</code> '
      "(no wall-clock timestamps; the only date is the registry created_at). "
      "Auto sections are reproducible byte-for-byte; fill sections are for the "
      "coordinator.</p>")
    a("</body></html>")
    return "\n".join(parts) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)
    parser.add_argument("id", help="task id (AC-NNNN)")
    parser.add_argument("--force", action="store_true",
                        help="overwrite an existing spec.html")
    parser.add_argument("--out", default=None,
                        help="write to an alternate path (for tests) instead of tasks/<id>/spec.html")
    args = parser.parse_args(argv)

    task_id = args.id
    if not ID_RE.match(task_id):
        print("error: %r is not a valid task id (expected AC-NNNN)" % task_id, file=sys.stderr)
        return 2

    try:
        task = _load_task(task_id)
    except SpecError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 1 if "unknown task id" not in str(exc) else 2

    if task.get("status") == "done":
        print("warning: %s is status 'done'; regenerating anyway" % task_id, file=sys.stderr)

    out = Path(args.out).expanduser() if args.out else (TASKS_DIR / task_id / "spec.html")
    if out.exists() and not args.force:
        print("error: %s already exists (use --force to overwrite)" % out, file=sys.stderr)
        return 1

    try:
        html = _build_html(task, task_id)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(html)
    except SpecError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 1
    except OSError as exc:
        print("error: could not write %s: %s" % (out, exc), file=sys.stderr)
        return 1

    print("wrote %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
