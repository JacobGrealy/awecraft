#!/usr/bin/env python3
"""Auto-fill a task spec.html scaffold from the TASKS.yaml entry + repo facts.

Usage:
    spec_template.py AC-NNNN [--force] [--out PATH]

Writes tasks/AC-NNNN/spec.html (or --out PATH) as a scaffold with two kinds of
sections:

  AUTO  — generated from TASKS.yaml and godot/HARNESS.md. Labeled
           "AUTO (… do not hand-edit)".

Slim vs full: the DEFAULT output is slim — the big AUTO tables (Data.* constants,
  RESULT shapes, known-stable values) are emitted as PATH POINTERS, not inlined
  rows, so the scaffold stays ~6 KB instead of ~20 KB (every subagent prompt
  that references spec.html pays for the size). Pass --full to inline the
  tables (parsed fresh at run time so the spec never carries stale numbers) —
  the coordinator's verbatim-constants gate diff (two-phase.md) uses --full.

  The gates section is TIERED: "Builder gates (Run-2, in-session)" (G0 + SMOKE
  + task probe + ≤1 render) vs "Coordinator Heavy Gates (background
  bash/workflow, not builder, r50 nightly only)".

Unregistered ids (AC-9999 not in TASKS.yaml) get a bare scaffold (empty
  registry fields, status "?") with a warning — for template checks.
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
# Deliberate exception to the "never scrape docs" rule (AC-0301): these are CODE,
# a machine-readable artefact versioned with the behaviour it describes, and the
# spec's "Frozen refs" block is meant to carry exact constants with file:line.
DATA_GD = REPO_ROOT / "godot" / "autoload" / "data.gd"
GEN_GD = REPO_ROOT / "godot" / "world" / "generator.gd"
# The machine source for the mode table + known-stable values. The doc
# (godot/HARNESS.md) is a RENDERING of this file - never parse the doc.
HARNESS_DATA = REPO_ROOT / "tasks" / "harness_data.yaml"

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


def _harness_data():
    """Load the harness machine data (AC-0301).

    `tasks/harness_data.yaml` is the single source for the mode table and the
    known-stable value table. Do NOT scrape godot/HARNESS.md: that doc is the
    agent-facing reference, and coupling a script to its markdown layout means a
    reformat silently weakens every generated spec (the reason the source moved).
    """
    if not HARNESS_DATA.exists():
        raise SpecError("harness data not found: %s" % HARNESS_DATA)
    with open(HARNESS_DATA) as fh:
        return yaml.safe_load(fh) or {}


def _harness_modes(data):
    """Return (columns, {mode: {field: text}}) for the mode table."""
    cols = list(data.get("mode_columns") or [])
    modes = {name: dict(fields or {}) for name, fields in (data.get("modes") or {}).items()}
    return cols, modes


def _known_stable_rows(data):
    """Return [[value, fresh result, established by], ...]."""
    return [[v.get("value", ""), v.get("fresh", ""), v.get("established_by", "")]
            for v in (data.get("standing_values") or [])]


def _battery_modes(data):
    """The battery mode list, authoritative from the data file (not the doc)."""
    return list((data.get("battery") or {}).get("modes") or [])


def _value_columns(data):
    """Column labels for the known-stable value table."""
    return list(data.get("value_columns") or [])



def _const_table_row(name, val, lineno, relpath):
    return ("<tr><td><code>%s</code></td><td><code>%s</code></td>"
            "<td class='note'>%s:%d</td></tr>"
            % (escape(name), escape(val), escape(relpath), lineno))


def _build_html(task, task_id, full=False):
    data_consts = _parse_gd_constants(DATA_GD)
    gen_consts = _parse_gd_constants(GEN_GD)
    data_rel = "godot/autoload/data.gd"
    gen_rel = "godot/world/generator.gd"

    hdata = _harness_data()
    hcols, hrows = _harness_modes(hdata)
    bat_modes = _battery_modes(hdata)
    vcols = _value_columns(hdata)
    known = _known_stable_rows(hdata)

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
      "is a FROZEN historical artifact — do NOT modify. <b>User 2026-08-29: the web spec is no "
      "longer referenced</b> — never cite it as the justification for behavior or values. "
      "Source of truth = the in-repo Godot code + user directives.</li>")
    a('<li>Minecraft wiki = canonical reference for tools/crafting/blocks, match exactly '
      'unless the user specifies otherwise: '
      '<a href="https://minecraft.wiki/w/Tool">Tool</a>, '
      '<a href="https://minecraft.wiki/w/Block">Block</a>, '
      '<a href="https://minecraft.wiki/w/Mining">Mining</a>, '
      '<a href="https://minecraft.wiki/w/Crafting_table">Crafting_table</a>, '
      '<a href="https://minecraft.wiki/w/Item">Item</a>.</li>')
    a("</ul>")

    # ---- Data.* constants (AUTO; slim = path pointer, --full = tables) ----
    a('<h2>Data.* world constants</h2>')
    if full:
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
    else:
        a('<div class="auto"><b>AUTO (paths only — regenerate with '
          '<code>python3 tasks/scripts/spec_template.py AC-NNNN --full</code> to '
          'inline the tables; values are parsed fresh at run time)</b></div>')
        a("<ul>")
        a("<li><code>%s</code> — all <code>Data.B_*</code> block ids, items, tools, "
          "SEA/HEIGHT/CHUNK constants (grep <code>^const </code>).</li>" % escape(data_rel))
        a("<li><code>%s</code> — biome constants + <code>T_G_*</code> tool ids; biome "
          "thresholds are computed in <code>biome_at()</code> (t &lt; -0.25 snow; "
          "t &gt; 0.35 &amp; m &lt; 0.1 desert; m &gt; 0.25 forest; else plains).</li>" % escape(gen_rel))
        a("</ul>")

    # ---- Builder gates (AUTO — what Run-2 runs in-session) ----
    a('<h2>Builder gates (Run-2, in-session)</h2>')
    a('<div class="auto"><b>AUTO (tiered per godot/HARNESS.md §3 — do not hand-edit)</b></div>')
    a('<div class="auto"><b>G0</b> — <code>env HOME=/tmp/dsh_home godot --headless '
      '--path godot --quit</code> exits 0 with <b>zero</b> <code>SCRIPT ERROR</code> '
      'lines.</div>')
    a('<div class="auto"><b>SMOKE</b> — one battery launch with the 2–4 '
      'dependency-mapped modes for this change area (HARNESS.md §3 table, e.g. '
      'world/* → <code>player;interact;light;fluids</code>) + the <code>genhash</code> '
      'arm (25/25) whenever <code>world/*</code> or <code>data.gd</code> is touched; '
      '~30 s total. The task-specific probe mode (if this spec defines one, '
      'env-gated, headless ≤ 60 s) runs here too.</div>')
    a('<div class="auto"><b>RENDER</b> — ≤ 1 render at <code>AWECRAFT_RADIUS=1</code> '
      '(xvfb, gl_compatibility — a PROXY renderer that cannot show Forward+-only '
      'features such as DOF; see <code>godot/HARNESS.md</code> §2), PNG under '
      '<code>tasks/AC-NNNN/</code>.</div>')
    a('<div class="auto"><b>EXIT</b> — after G0+SMOKE(+probe)+≤1 render the builder '
      'writes results + continuity and EXITS. The heavy gates below are the '
      'coordinator&#39;s background job — the builder never runs them.</div>')
    a('<div class="auto"><b>Sandbox env</b> — every godot call is ONE bash command that '
      'sets HOME first; <b>one godot at a time</b> (concurrent runs corrupt the '
      '<code>.godot</code> cache and hang). Scratch to project-local <code>.scratch/</code>.</div>')
    a("<pre>export HOME=/tmp/dsh_home; mkdir -p $HOME; "
      "cd /home/angrygiant/github_projects/AweCraft</pre>")

    # ---- Coordinator heavy gates (AUTO — background bash/workflow, NOT the builder) ----
    a('<h2>Coordinator Heavy Gates (background bash/workflow, not builder, r50 nightly only)</h2>')
    a('<div class="auto"><b>AUTO (HEAVY-GATE PIPELINE — the coordinator runs these as a '
      'background job (no LLM slot) after Run-2 exits; the builder NEVER runs them; '
      'commit/push only after they pass — do not hand-edit)</b></div>')
    a("<ul>")
    a("<li><b>boundary r4 ×1</b> + <b>perf r4</b> — ONLY when scope touches "
      "<code>godot/world/*</code> | <code>lighting.gd</code> (HARNESS.md §3 tier); "
      "UI/tool tasks: SMOKE only, no boundary/perf. (Was ×2, sliced 2026-08-27.)</li>")
    a("<li><b>genhash</b> — independent re-run (25/25) whenever <code>world/*</code>/"
      "<code>data.gd</code> touched.</li>")
    a("<li><b>flake ×1</b> — perf tier only (was ×4, sliced 2026-08-27).</li>")
    a("<li><b>boundary r50 / perf r50 (RECSLICE)</b> — nightly batch only (NOT per "
      "task; was per-task).</li>")
    a("<li><b>task-specific probe mode</b> — when this spec&#39;s Task-specific gates "
      "define one (the builder&#39;s SMOKE runs it; the gate job re-runs it fresh).</li>")
    a("<li><b>windows build</b> — <code>./build_windows.sh</code> (XDG pattern) + "
      "8080/5180 curls — every task.</li>")
    a("</ul>")
    a("<p class='note'>Log → <code>.scratch/AC-NNNN-gates/gates.log</code>; marker "
      "<code>.scratch/AC-NNNN-gates/HEAVY_GATES_DONE</code>. Full protocol: "
      "<code>AGENTS.md</code> HEAVY-GATE PIPELINE + "
      "<code>tasks/templates/two-phase.md</code>.</p>")

    # ---- RESULT shapes (AUTO; slim = path pointer, --full = table) ----
    a('<h2>Expected RESULT shapes (default battery + genhash)</h2>')
    if full:
        a('<div class="auto"><b>AUTO (rows from tasks/harness_data.yaml, rendered into '
          'godot/HARNESS.md §1 — do not hand-edit)</b></div>')
        if hrows:
            a("<table><tr><th>mode</th><th>key RESULT fields</th><th>typical wall</th></tr>")
            for mode in (bat_modes or BATTERY_MODES):
                r = hrows.get(mode)
                if not r:
                    continue
                a("<tr><td><code>%s</code></td><td>%s</td><td>%s</td></tr>"
                  % (mode, escape(r.get("result_fields", "")), escape(r.get("wall", ""))))
            a("</table>")
        else:
            a("<p class='note'>no modes in tasks/harness_data.yaml — regenerate after it is "
              "restored (it is the machine source for the mode table).</p>")
    else:
        a('<div class="auto"><b>AUTO (paths only — the RESULT shapes live in '
          '<code>godot/HARNESS.md</code> §1; inline them with <code>--full</code>)</b></div>')
        a("<ul>")
        a("<li>Battery arms: %s — key fields + ok-conditions per mode in "
          "<code>godot/HARNESS.md</code> §1.</li>"
          % " / ".join("<code>%s</code>" % m for m in (bat_modes or BATTERY_MODES)))
        a("<li>Heavy modes: <code>boundary</code>, <code>recprobe</code>, "
          "<code>perf</code>, <code>minfo</code>, <code>pickorder</code> — §2.</li>")
        a("</ul>")

    # ---- Known-stable values (AUTO; slim = path pointer, --full = table) ----
    a('<h2>Known-stable gate values</h2>')
    if full:
        a('<div class="auto"><b>AUTO (values from tasks/harness_data.yaml, rendered into '
          'godot/HARNESS.md §3 — verify fresh on any fluids/world-touching change)</b></div>')
        if known:
            a("<table><tr>%s</tr>"
              % "".join("<th>%s</th>" % escape(c) for c in vcols))
            for cells in known:
                pad = cells + [""] * (len(vcols) - len(cells))
                a("<tr><td>%s</td><td>%s</td><td>%s</td></tr>"
                  % (escape(pad[0]), escape(pad[1]), escape(pad[2])))
            a("</table>")
        else:
            a('<p class="note">no standing values in <code>tasks/harness_data.yaml</code> '
              "(it is the machine source for the anchor table) — <b>establish them "
              "fresh</b> before gating.</p>")
    else:
        a('<div class="auto"><b>AUTO (paths only — the anchor table lives in '
          '<code>godot/HARNESS.md</code> §3, generated from '
          '<code>tasks/harness_data.yaml</code>; verify fresh on any '
          'fluids/world-touching change; inline with <code>--full</code>)</b></div>')

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
    parser.add_argument("--full", action="store_true",
                        help="inline the big AUTO tables (Data.* constants, RESULT "
                             "shapes, known-stable values); default is slim (paths only)")
    args = parser.parse_args(argv)

    task_id = args.id
    if not ID_RE.match(task_id):
        print("error: %r is not a valid task id (expected AC-NNNN)" % task_id, file=sys.stderr)
        return 2

    try:
        task = _load_task(task_id)
    except SpecError as exc:
        if "unknown task id" in str(exc):
            print("warning: %s is not in TASKS.yaml — writing a bare scaffold" % task_id,
                  file=sys.stderr)
            task = {}
        else:
            print("error: %s" % exc, file=sys.stderr)
            return 1

    if task.get("status") == "done":
        print("warning: %s is status 'done'; regenerating anyway" % task_id, file=sys.stderr)

    out = Path(args.out).expanduser() if args.out else (TASKS_DIR / task_id / "spec.html")
    if out.exists() and not args.force:
        print("error: %s already exists (use --force to overwrite)" % out, file=sys.stderr)
        return 1

    try:
        html = _build_html(task, task_id, full=args.full)
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
