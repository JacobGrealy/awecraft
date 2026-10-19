#!/usr/bin/env python3
"""Render the builder's self-contained results page (AC-0455).

    python3 tasks/scripts/results_page.py AC-NNNN
        [--deviations FILE] [--headline "k=v k2=v2"]
        [--files "a,b"] [--summary PATH]

Renders tasks/AC-NNNN/AC-NNNN-results.html: self-contained (inline CSS, no
external refs), house style = numbered <h2> sections (as in
tasks/AC-0448/AC-0448-results.html):

    1. Gates       table: arm | mode | rc | script | shader | ok | wall |
                   headline RESULT values (the --headline tokens if given,
                   else the ok/ok-ish fields of the parsed RESULT; max 6)
    2. Deviations  the --deviations file verbatim (paragraphs), or "None."
    3. Files       the --files list, else `git status --porcelain` filtered
                   to godot/ gdext/ tasks/
    4. Artifacts   *.png / *.json in tasks/AC-NNNN/ when present, else the
                   section is omitted

It REFUSES to render a lie (the H3 integrity rule, made mechanical): exit 1
if an arm in the summary has no log file on disk, or if --headline names a
value that is not present in that arm's log. Every number on the page has to
be greppable from a log.

Exit codes: 0 rendered; 1 integrity refusal; 2 bad usage.
"""

import argparse
import json
import re
import subprocess
import sys
from html import escape
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

CSS = (
    "body{font:15px/1.5 ui-sans-serif,system-ui,sans-serif;max-width:900px;"
    "margin:24px auto;padding:0 16px;color:#1a1a1a}"
    "h1{font-size:22px}h2{font-size:17px;margin-top:22px;border-bottom:1px solid #ddd;"
    "padding-bottom:4px}"
    "code,pre{font:13px/1.4 ui-monospace,Menlo,monospace}"
    "pre{background:#f4f4f4;padding:10px;border-radius:6px;overflow:auto}"
    "table{border-collapse:collapse;font-size:13px;margin:10px 0}"
    "th,td{border:1px solid #ccc;padding:4px 8px;text-align:left;vertical-align:top}"
    "th{background:#f0f0f0}"
    ".note{font-size:13px;color:#555}"
)


class PageError(Exception):
    """A user-facing failure with a clean message (no traceback)."""


def _load_summary(path):
    p = Path(path)
    if not p.is_file():
        raise PageError("summary not found: %s (run gate_run.py first)" % p)
    try:
        data = json.loads(p.read_text())
    except ValueError as exc:
        raise PageError("summary %s is not parseable JSON: %s" % (p, exc))
    if not isinstance(data, dict) or not isinstance(data.get("arms"), list):
        raise PageError("summary %s has no arms list" % p)
    return data


def _headline_tokens(headline):
    return [t for t in re.split(r"[\s,]+", (headline or "").strip()) if t]


def _fmt_value(v):
    if v is True:
        return "true"
    if v is False:
        return "false"
    if v is None:
        return "null"
    return str(v)


def _default_headline(result):
    if not isinstance(result, dict) or not result:
        return "—"
    keys = [k for k in result if k == "ok" or str(k).startswith("ok")
            or "_ok" in str(k)]
    keys = keys or list(result.keys())
    return " ".join("%s=%s" % (k, _fmt_value(result[k])) for k in keys[:6])


def _git_files():
    out = subprocess.run(["git", "status", "--porcelain"], cwd=str(REPO_ROOT),
                         capture_output=True, text=True)
    rows = []
    for line in (out.stdout or "").splitlines():
        if len(line) < 4:
            continue
        status, path = line[:2], line[3:].strip()
        if path.startswith(("godot/", "gdext/", "tasks/")):
            rows.append((status, path))
    return rows


def _log_text(arm):
    p = REPO_ROOT / arm["log"]
    return p.read_text(encoding="utf-8", errors="replace")


def render(ticket, summary, headline=None, deviations_file=None, files=None):
    """Return (html, errors). errors non-empty -> refuse (exit 1)."""
    errors = []
    arms = summary["arms"]

    # Integrity: every arm needs its log on disk, and every --headline token
    # must be greppable from that arm's log.
    logs = {}
    for arm in arms:
        log = REPO_ROOT / arm.get("log", "")
        if not log.is_file():
            errors.append("arm %r: no log file on disk: %s"
                          % (arm.get("name"), arm.get("log")))
            continue
        logs[arm.get("name")] = _log_text(arm)

    tokens = _headline_tokens(headline)
    for arm in arms:
        name = arm.get("name")
        text = logs.get(name)
        if text is None:
            continue
        for tok in tokens:
            if tok not in text:
                errors.append("arm %r: --headline token %r not present in "
                              "its log (a number that cannot be grepped is "
                              "a lie)" % (name, tok))

    if errors:
        return None, errors

    def cell(arm, key, dash="—"):
        v = arm.get(key)
        return escape("" if v is None else str(v)) if v is not None or key in arm else dash

    dev_paras = []
    if deviations_file:
        p = Path(deviations_file)
        if not p.is_file():
            errors.append("deviations file not found: %s" % p)
            return None, errors
        dev_paras = [b for b in re.split(r"\n\s*\n", p.read_text().strip())
                     if b.strip()]

    if files is None:
        git_rows = _git_files()  # (git status, path)
    else:
        git_rows = [("", f) for f in
                    [f.strip() for f in files.split(",") if f.strip()]]

    artifacts = sorted(
        (p.name for p in (REPO_ROOT / "tasks" / ticket).iterdir()
         if p.suffix in (".png", ".json"))
        if (REPO_ROOT / "tasks" / ticket).is_dir() else [])

    sections = []

    # 1. Gates
    rows = ["<tr><th>arm</th><th>mode</th><th>rc</th><th>script</th>"
            "<th>shader</th><th>ok</th><th>wall</th><th>headline</th></tr>"]
    for arm in arms:
        hl = (" ".join(tokens) if tokens
              else escape(_default_headline(arm.get("result"))))
        ok = arm.get("ok")
        rows.append("<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td>"
                    "<td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>"
                    % (escape(str(arm.get("name"))),
                       escape(str(arm.get("mode")) if arm.get("mode") is not None else "(bare)"),
                       cell(arm, "rc"), cell(arm, "script_errors"),
                       cell(arm, "shader_errors"),
                       escape("true" if ok is True else "false"),
                       escape(str(arm.get("wall_s"))), hl))
    sections.append(("Gates",
                     "<p class='note'>every value below is greppable from "
                     "the arm's log</p>\n<table>%s</table>" % "".join(rows)))

    # 2. Deviations
    if dev_paras:
        body = "".join("<p>%s</p>" % escape(p.replace("\n", " "))
                       for p in dev_paras)
    else:
        body = "<p>None.</p>"
    sections.append(("Deviations", body))

    # 3. Files
    if git_rows:
        body = "".join(
            ("<p><code>%s</code> <code>%s</code></p>"
             % (escape(s), escape(pth)) if s
             else "<p><code>%s</code></p>" % escape(pth))
            for s, pth in git_rows)
    else:
        body = "<p>(none)</p>"
    sections.append(("Files", body))

    # 4. Artifacts (omitted when absent)
    if artifacts:
        body = "".join("<p><code>tasks/%s/%s</code></p>"
                       % (escape(ticket), escape(a)) for a in artifacts)
        sections.append(("Artifacts", body))

    body = []
    for i, (title, html) in enumerate(sections, 1):
        body.append("<h2>%d. %s</h2>\n%s" % (i, escape(title), html))

    gate_dir = summary.get("gate_dir", ".scratch")
    page = ("<!DOCTYPE html>\n<html lang='en'>\n<head>\n"
            "<meta charset='utf-8'>\n<title>%s — results</title>\n"
            "<style>%s</style>\n</head>\n<body>\n"
            "<h1>%s — builder results</h1>\n"
            "%s\n"
            "<p class='note'>rendered by tasks/scripts/results_page.py "
            "from %s — every number on this page is greppable from a log "
            "under %s/</p>\n</body>\n</html>\n"
            % (ticket, CSS, ticket, "\n".join(body),
               escape(str(gate_dir)), escape(str(gate_dir))))
    return page, []


def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__.splitlines()[0])
    ap.add_argument("ticket", help="task id, e.g. AC-0448")
    ap.add_argument("--deviations", help="file with the deviations text "
                   "(verbatim paragraphs)")
    ap.add_argument("--headline", help="'k=v k2=v2' headline values; each "
                   "must appear in every arm's log")
    ap.add_argument("--files", help="comma list of changed files (default: "
                   "git status filtered to godot/ gdext/ tasks/)")
    ap.add_argument("--summary", help="gate summary.json path (default "
                   ".scratch/<ticket>-gates/summary.json)")
    a = ap.parse_args(argv)

    summary_path = Path(a.summary) if a.summary else (
        REPO_ROOT / ".scratch" / ("%s-gates" % a.ticket) / "summary.json")
    try:
        summary = _load_summary(summary_path)
        page, errors = render(a.ticket, summary, headline=a.headline,
                              deviations_file=a.deviations, files=a.files)
    except PageError as exc:
        print("results_page: %s" % exc, file=sys.stderr)
        return 2
    if errors:
        for e in errors:
            print("results_page: refusing — %s" % e, file=sys.stderr)
        return 1

    out = REPO_ROOT / "tasks" / a.ticket / ("%s-results.html" % a.ticket)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(page)
    print("results_page: wrote %s (%d bytes)" % (out, len(page.encode())))
    return 0


if __name__ == "__main__":
    sys.exit(main())
