#!/usr/bin/env python3
"""One markdown context pack for a ticket builder (AC-0455).

Collapses the builder's multi-document read (registry entry, notes, plan,
anchor context, harness rows, architecture sections, last continuity block)
into a single file:

    python3 tasks/scripts/context_pack.py AC-NNNN [--out PATH]
                                           [--max-tokens 12000] [--stdout]

Default output: .scratch/AC-NNNN/context.md. Sections, in order: Ticket,
Notes, Plan, Anchors, Frozen refs, Harness modes, Architecture, Last
continuity, Cap.

The hard cap is the point of the tool: tokens are estimated as bytes/3.6,
and over --max-tokens items are dropped from the BOTTOM up (Last continuity
and Harness modes are never dropped first); every drop is recorded in the
Cap section. Two structural guards:

  * no single excerpt may exceed 200 lines;
  * the known monsters (godot/scenes/harness.gd, godot/world/world.gd,
    godot/ARCHITECTURE.md, godot/HARNESS.md) are refused with exit 2 when a
    request would include more than 200 lines of one of them.

Never parses a document's markdown for machine facts: the only machine
sources are the registry (tasks_lib) and tasks/harness_data.yaml (the mode
NAMES and the per-mode rows, both lookups). Plan anchors are resolved
against CODE: a `file:line` anchor reads +-8 lines, a symbol anchor is a
literal search in the file, and a `grep -n "X"` anchor is run.

Exit codes: 0 ok, 2 bad usage or a monster refusal.
"""

import argparse
import datetime
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import yaml  # noqa: E402

import tasks_lib  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
HARNESS_DATA = REPO_ROOT / "tasks" / "harness_data.yaml"

# The known monsters: refusing >200 lines of one is exit 2 (the builder
# cannot load them whole anyway — this guard makes that mechanical).
MONSTERS = (
    "godot/scenes/harness.gd",
    "godot/world/world.gd",
    "godot/ARCHITECTURE.md",
    "godot/HARNESS.md",
)
MONSTER_MAX_LINES = 200
MAX_EXCERPT_LINES = 200
SPAN = 8  # +-8 lines of context around a line anchor

FILELINE_RE = re.compile(
    r"([A-Za-z0-9_][A-Za-z0-9_./\-]*\.(?:gd|gdshader|gdinc|cpp|cc|h|hpp|"
    r"md|yaml|yml|py|sh|html|tscn|res|tres|json|cfg|txt|svg))\s*:\s*(\d{1,6})")
TOKEN_RE = re.compile(r"[\w.\-/]+")
BACKTICK_RE = re.compile(r"`([^`]{2,80})`")
QUOTED_RE = re.compile(r'"([^"]{4,80})"')
GREP_RE = re.compile(r"grep\s+-n\s+[\"']([^\"']+)[\"']")
PATHISH_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_./\-]*\.[A-Za-z0-9]+")
PRUNE_DIRS = {".git", ".godot", ".scratch", "exports", "node_modules",
              "__pycache__", ".dsh", "bin"}

_BASENAME_INDEX = None


class PackError(Exception):
    """A user-facing failure with a clean message (no traceback)."""


def _basename_index():
    """Map basename -> [repo-relative Paths]; built once, pruned dirs skipped."""
    global _BASENAME_INDEX
    if _BASENAME_INDEX is None:
        idx = {}
        for dirpath, dirnames, filenames in _walk_repo():
            dirnames[:] = [d for d in dirnames if d not in PRUNE_DIRS]
            for fn in filenames:
                idx.setdefault(fn, []).append(Path(dirpath) / fn)
        _BASENAME_INDEX = idx
    return _BASENAME_INDEX


def _walk_repo():
    import os
    return os.walk(str(REPO_ROOT))


def resolve_path(name):
    """Resolve a plan-named file to a repo path, or None (missing/ambiguous)."""
    p = (REPO_ROOT / name)
    if p.is_file():
        return p
    if "/" in name:
        return None
    cands = [c for c in _basename_index().get(Path(name).name, [])
             if not any(part in PRUNE_DIRS for part in c.parts)]
    if len(cands) == 1:
        return cands[0]
    return None


def _read_lines(path):
    return path.read_text(encoding="utf-8", errors="replace").splitlines()


def _rel(path):
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def _subhead(title, idx):
    title = title.strip()
    if re.match(r"\d+[.)]", title):
        return "### %s" % title
    return "### %d. %s" % (idx, title)


def _field(value):
    s = str(value)
    return s if len(s) <= FIELD_MAX else s[:FIELD_MAX] + " …"


class _PlanHTML(HTMLParser):
    """Collect h2 sections as (title, chunks); a chunk is ('text', s) or
    ('table', [cells...])."""

    def __init__(self):
        super().__init__()
        self.sections = []
        self.cur = None
        self.in_h2 = False
        self.in_table = False
        self.row = None
        self.cell = None

    def handle_starttag(self, tag, attrs):
        if tag == "h2":
            self.in_h2 = True
            self.cur = ["", []]
            self.sections.append(self.cur)
        elif tag == "table":
            self.in_table = True
        elif tag == "tr" and self.in_table:
            self.row = []
        elif tag in ("td", "th") and self.in_table:
            self.cell = []

    def handle_endtag(self, tag):
        if tag == "h2":
            self.in_h2 = False
        elif tag == "table":
            self.in_table = False
        elif tag == "tr" and self.row is not None:
            if self.in_table and any(c.strip() for c in self.row):
                self.cur[1].append(("table", self.row))
            self.row = None
        elif tag in ("td", "th") and self.cell is not None:
            self.row.append("".join(self.cell).strip())
            self.cell = None

    def handle_data(self, data):
        if self.in_h2:
            self.cur[0] += data
        elif self.cell is not None:
            self.cell.append(data)
        elif self.cur is not None:
            self.cur[1].append(("text", data))


def parse_plan(html):
    p = _PlanHTML()
    p.feed(html)
    return p.sections


def _section_text(section):
    out = []
    for kind, payload in section[1]:
        if kind == "text":
            out.append(payload)
        else:
            out.append(" | ".join(payload))
    text = re.sub(r"\n{3,}", "\n\n", "".join(out))
    return re.sub(r"[ \t]+\n", "\n", text).strip()


def _section_table(section):
    rows = [payload for kind, payload in section[1] if kind == "table"]
    return rows[0] if rows else None


def _secnum(title):
    m = re.match(r"\s*(\d+)[.)]?\s", title)
    return int(m.group(1)) if m else None


def _section_by_number(sections, n):
    for s in sections:
        if _secnum(s[0]) == n:
            return s
    return sections[n - 1] if 0 < n <= len(sections) else None


def collect_anchors(sections, body_text):
    """(file, line) and (file, symbol) anchors, in plan order, deduped.

    Sources: the section-2 file table (File/Anchor columns) first, then every
    inline `file:line` reference in the plan body (prose plans carry their
    anchors inline — the AC-0433 fixture).
    """
    line_anchors, sym_anchors, notes = [], [], []
    seen = set()

    sec2 = _section_by_number(sections, 2)
    if sec2 is not None:
        table = _section_table(sec2)
        if table and len(table) >= 2:
            header = [c.lower() for c in table[0]]
            fi = next((i for i, c in enumerate(header)
                       if "file" in c), 0)
            ai = next((i for i, c in enumerate(header)
                       if "anchor" in c), 1)
            for row in table[1:]:
                if len(row) <= max(fi, ai):
                    continue
                m = PATHISH_RE.search(row[fi])
                if not m:
                    continue
                fname = m.group(0)
                anchor = row[ai].strip()
                if not anchor or re.fullmatch(r"NEW", anchor, re.I):
                    continue  # file does not exist yet — nothing to resolve
                gm = GREP_RE.search(anchor)
                if gm:
                    sym_anchors.append((fname, gm.group(1)))
                    continue
                bm = BACKTICK_RE.search(anchor)
                if bm:
                    sym_anchors.append((fname, bm.group(1)))
                    continue
                notes.append("anchor %r for %s has no resolvable symbol; skipped"
                             % (anchor, fname))

    for m in FILELINE_RE.finditer(body_text):
        key = (m.group(1), int(m.group(2)))
        if key in seen:
            continue
        seen.add(key)
        line_anchors.append(key)
    for fname, sym in list(sym_anchors):
        key = ("sym", fname, sym)
        if key in seen:
            continue
        seen.add(key)

    return line_anchors, sym_anchors, notes


def resolve_symbol(fname, sym):
    """Literal search for sym in fname; a dotted token falls back to its last
    segment (the plan names keys like `battery.smoke` that appear as `smoke:`)."""
    path = resolve_path(fname)
    if path is None:
        return None, None
    lines = _read_lines(path)
    for i, ln in enumerate(lines, 1):
        if sym in ln:
            return path, i
    if "." in sym:
        tail = sym.rsplit(".", 1)[1]
        if tail:
            for i, ln in enumerate(lines, 1):
                if tail in ln:
                    return path, i
    return path, None


def excerpt_block(path, line):
    """+-SPAN lines around `line`, numbered; capped at MAX_EXCERPT_LINES."""
    lines = _read_lines(path)
    if line < 1 or line > len(lines):
        return None
    lo, hi = max(1, line - SPAN), min(len(lines), line + SPAN)
    body = ["%5d| %s" % (i, lines[i - 1]) for i in range(lo, hi + 1)]
    if len(body) > MAX_EXCERPT_LINES:
        body = body[:MAX_EXCERPT_LINES]
    return body


def plan_excerpts(sections, body_text):
    """All (label, rel_path, lines-included, markdown) planned for the pack,
    plus unresolvable notes. Checked against the monster guard BEFORE any
    output is written."""
    line_anchors, sym_anchors, notes = collect_anchors(sections, body_text)
    items, per_file = [], {}
    for fname, line in line_anchors:
        path = resolve_path(fname)
        if path is None:
            notes.append("%s:%d — file not found (or ambiguous); skipped"
                         % (fname, line))
            continue
        body = excerpt_block(path, line)
        if body is None:
            notes.append("%s:%d — line out of range; skipped" % (fname, line))
            continue
        rel = _rel(path)
        per_file[rel] = per_file.get(rel, 0) + len(body)
        items.append((rel, line, body))
    for fname, sym in sym_anchors:
        path, line = resolve_symbol(fname, sym)
        if path is None:
            notes.append("%s (%r) — file not found (or ambiguous); skipped"
                         % (fname, sym))
            continue
        if line is None:
            notes.append("%s — no line matches %r; skipped" % (_rel(path), sym))
            continue
        body = excerpt_block(path, line)
        rel = _rel(path)
        per_file[rel] = per_file.get(rel, 0) + len(body)
        items.append((rel, line, body))
    return items, per_file, notes


def check_monsters(per_file):
    """Exit-2 refusal when a monster would contribute >200 lines to the pack."""
    for rel, n in per_file.items():
        if rel in MONSTERS and n > MONSTER_MAX_LINES:
            raise PackError(
                "refusing: the request would include %d lines of %s "
                "(more than %d — the known monster cap; split the plan "
                "anchors or narrow them)" % (n, rel, MONSTER_MAX_LINES))


def last_run_block(task_id):
    p = REPO_ROOT / "tasks" / task_id / "continuity.md"
    if not p.is_file():
        return None
    lines = _read_lines(p)
    idxs = [i for i, l in enumerate(lines) if l.startswith("## RUN")]
    if not idxs:
        return None
    start = idxs[-1]
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].startswith("## ")), len(lines))
    return lines[start:end]


def harness_row(mode):
    """The mode's row from harness_data.yaml (lookups only)."""
    data = yaml.safe_load(HARNESS_DATA.read_text()) or {}
    row = (data.get("modes") or {}).get(mode)
    if not isinstance(row, dict):
        return None
    return row


def arch_sections(body_text):
    """ARCHITECTURE.md sections whose heading the plan names (a quoted or
    backticked string matching a heading, case-insensitive). Each included
    section runs until the next heading of the same or higher level."""
    p = REPO_ROOT / "godot" / "ARCHITECTURE.md"
    if not p.is_file():
        return []
    lines = _read_lines(p)
    heads = [(i, len(l) - len(l.lstrip("#")), l.lstrip("#").strip())
             for i, l in enumerate(lines) if l.startswith("#")]
    cands = set()
    for rx in (BACKTICK_RE, QUOTED_RE):
        for m in rx.finditer(body_text):
            cands.add(m.group(1).strip().casefold())
    norm = lambda s: re.sub(r"[^a-z0-9]+", "", s.casefold())
    out = []
    for i, level, title in heads:
        t = norm(title)
        if not t:
            continue
        if any(t == norm(c) or (len(t) >= 6 and t in norm(c)) for c in cands):
            end = len(lines)
            for j in range(i + 1, len(lines)):
                if lines[j].startswith("#"):
                    lv = len(lines[j]) - len(lines[j].lstrip("#"))
                    if lv <= level:
                        end = j
                        break
            body = lines[i:min(end, i + 1 + MAX_EXCERPT_LINES)]
            out.append(("godot/ARCHITECTURE.md — %s" % title, body))
    return out


def frozen_refs(sections):
    """Lines a 'Frozen refs' plan section quotes (file:line + the line text)."""
    sec = next((s for s in sections if "frozen" in s[0].lower()), None)
    if sec is None:
        return []
    out = []
    for ln in _section_text(sec).splitlines():
        m = FILELINE_RE.search(ln)
        if m:
            out.append((m.group(1), int(m.group(2)),
                        ln.strip()[:m.start(1) - 1] or ln.strip()))
    return out


FIELD_MAX = 500  # per-field cap on a mode row: rows are lookups, not reading
                 # material (the yaml stays the machine source — link, don't
                 # restate); without it a 9 KB notes field eats the budget
                 # and the anchor excerpts — the point of the pack — drop.


def _cap(items, max_tokens):
    """Drop items from the bottom up — unprotected first, protected last —
    until the estimate (bytes/3.6) fits. Returns (kept, cap lines)."""
    dropped = []
    working = list(items)

    def total():
        b = sum(len(i[3].encode()) for i in working)
        b += sum(len(l.encode()) for l in dropped) + 160  # headers/overhead
        return b / 3.6

    guard = 0
    while total() > max_tokens and working and guard < 1000:
        guard += 1
        pool = [i for i in working if not i[2]]
        pool = pool or working
        item = pool[-1]
        working.remove(item)
        dropped.append("TRUNCATED: %s" % item[1])
    return working, dropped


def build_pack(task_id, max_tokens=12000):
    """Build the full markdown pack; returns (markdown, cap_lines)."""
    data = tasks_lib.load_tasks()
    task = tasks_lib.find_task(data, task_id)
    if task is None:
        raise PackError("unknown task id %r (no such entry in TASKS.yaml)"
                        % task_id)

    plan_path = REPO_ROOT / "tasks" / task_id / "plan.html"
    sections = []
    if plan_path.is_file():
        sections = parse_plan(plan_path.read_text())
    body_text = "\n".join(_section_text(s) for s in sections)

    items = []  # (section, drop-label, protected, markdown-block)

    t = task
    items.append(("Ticket", "Ticket", False, "\n".join([
        "- title: %s" % t.get("title"),
        "- status: %s" % t.get("status"),
        "- priority: %s" % t.get("priority"),
        "- labels: %s" % (", ".join(t.get("labels") or []) or "(none)"),
        "- created: %s" % t.get("created_at"),
        "- updated: %s" % t.get("updated_at"),
    ])))

    notes = str(t.get("notes") or "").strip() or "(none)"
    nlines = notes.splitlines()
    if len(nlines) > MAX_EXCERPT_LINES:
        notes = "\n".join(nlines[:MAX_EXCERPT_LINES]) \
            + "\n(… capped at %d lines)" % MAX_EXCERPT_LINES
    items.append(("Notes", "Notes", False, notes))

    # Plan: §1 goal text + the §2 file-table rows (tags stripped, anchors kept)
    plan_md = []
    sec1 = sections[0] if sections else None
    if sec1 is not None:
        plan_md.append(_subhead(sec1[0], 1))
        plan_md.append(_section_text(sec1))
    sec2 = _section_by_number(sections, 2)
    table = _section_table(sec2) if sec2 is not None else None
    if table:
        plan_md.append(_subhead(sec2[0] if sec2 is not None else "Files", 2))
        plan_md.append("*(the plan's file table, anchors kept)*")
        for row in table:
            plan_md.append("- " + " | ".join(row))
    elif sec2 is not None:
        plan_md.append(_subhead(sec2[0], 2)
                       + " *(no file table; anchors resolve inline)*")
    items.append(("Plan", "Plan", False, "\n".join(plan_md) if plan_md
                  else "(no plan.html for this ticket)"))

    # Anchors (the monster guard runs on the PLANNED set, before anything
    # is emitted)
    excerpts, per_file, anotes = (plan_excerpts(sections, body_text)
                                  if sections else ([], {}, []))
    check_monsters(per_file)
    anchor_blocks = []
    for rel, line, body in excerpts:
        anchor_blocks.append(
            "### %s:%d\n```\n%s\n```\n" % (rel, line, "\n".join(body)))
    for n in anotes:
        anchor_blocks.append("(note: %s)" % n)
    for i in range(0, len(anchor_blocks), 4):
        chunk = "\n".join(anchor_blocks[i:i + 4])
        label = ("Anchors (%s)" % excerpts[i][0]) if excerpts else "Anchors"
        items.append(("Anchors", label, False, chunk))
    if not anchor_blocks:
        items.append(("Anchors", "Anchors", False, "(none resolvable)"))

    # Frozen refs
    refs = frozen_refs(sections)
    ref_blocks = []
    for fname, line, _quote in refs:
        path = resolve_path(fname)
        if path is not None and 1 <= line <= len(_read_lines(path)):
            ref_blocks.append("- %s:%d — %s"
                              % (fname, line,
                                 _read_lines(path)[line - 1].strip()))
        else:
            ref_blocks.append("- %s:%d — (unresolved)" % (fname, line))
    items.append(("Frozen refs", "Frozen refs", False,
                  "\n".join(ref_blocks) if ref_blocks else "(none named)"))

    # Harness modes named in plan §4 (mode NAMES are machine facts; rows are
    # lookups from harness_data.yaml, field-capped — the yaml stays the
    # machine source, the pack carries a pointer, not a restate)
    sec4 = _section_by_number(sections, 4)
    text4 = _section_text(sec4) if sec4 is not None else ""
    data = yaml.safe_load(HARNESS_DATA.read_text()) or {}
    n_mode_items = 0
    for mode in (data.get("modes") or {}):
        if re.search(r"\b%s\b" % re.escape(mode), text4):
            row = harness_row(mode)
            if row is None:
                continue
            n_mode_items += 1
            block = "\n".join(
                ["### %s" % mode]
                + ["- %s: %s" % (k, _field(row[k])) for k in
                   ("entry", "tests", "result_fields", "notes") if k in row]
                + ["- (full row: tasks/harness_data.yaml — modes.%s)" % mode])
            items.append(("Harness modes", "Harness modes: %s" % mode,
                          True, block))
    if not n_mode_items:
        items.append(("Harness modes", "Harness modes", False,
                      "(none named in plan §4)"))

    # Architecture sections whose heading the plan names
    for label, body in arch_sections(body_text):
        items.append(("Architecture", label, False,
                      "```\n%s\n```" % "\n".join(body)))
    if not any(i[0] == "Architecture" and i[1].startswith("godot/")
               for i in items):
        items.append(("Architecture", "Architecture", False,
                      "(no heading named by the plan)"))

    # Last continuity (the final ## RUN block)
    run = last_run_block(task_id)
    if run:
        blk = "\n".join(run)
        rlines = blk.splitlines()
        if len(rlines) > MAX_EXCERPT_LINES:
            blk = "\n".join(rlines[:MAX_EXCERPT_LINES]) \
                + "\n(… capped at %d lines)" % MAX_EXCERPT_LINES
        items.append(("Last continuity", "Last continuity", True,
                      "```\n%s\n```" % blk))
    else:
        items.append(("Last continuity", "Last continuity", False,
                      "(no continuity.md)"))

    kept, cap_lines = _cap(items, max_tokens)

    out = ["# Context pack — %s" % task_id,
           "*generated by tasks/scripts/context_pack.py on %s — "
           "do not hand-edit*" % datetime.date.today().isoformat(), ""]
    last = None
    for section, _label, _prot, block in kept:
        if section != last:
            out.append("## %s" % section)
            last = section
        out.append(block)
        out.append("")
    out.append("## Cap")
    out.extend(cap_lines or ["(none)"])
    return "\n".join(out) + "\n", cap_lines


def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__.splitlines()[0])
    ap.add_argument("ticket", help="task id, e.g. AC-0433")
    ap.add_argument("--out", help="output path (default "
                   ".scratch/<ticket>/context.md)")
    ap.add_argument("--max-tokens", type=float, default=12000,
                    help="hard token cap, estimated as bytes/3.6 (default 12000)")
    ap.add_argument("--stdout", action="store_true",
                    help="also print the pack to stdout")
    a = ap.parse_args(argv)

    out = Path(a.out) if a.out else (REPO_ROOT / ".scratch"
                                     / a.ticket / "context.md")
    try:
        md, _caps = build_pack(a.ticket, a.max_tokens)
    except PackError as exc:
        print("context_pack: %s" % exc, file=sys.stderr)
        return 2
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(md)
    print("context_pack: wrote %s (%d bytes, ~%.0f tokens)"
          % (out, len(md.encode()), len(md.encode()) / 3.6))
    if a.stdout:
        sys.stdout.write(md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
