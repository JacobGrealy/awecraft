#!/usr/bin/env python3
"""Compare two battery outputs, on VALUES and on pass/fail STATUS (AC-0477).

Why it exists
-------------
The per-ticket .scratch battery_compare copies diffed RESULT values only: an
arm returning ok:false in BOTH the baseline and the current run looked
"identical" and passed silently. That is how `water`/`trees` sat red for
months. This is the ONE maintained tool for battery comparison — the
per-ticket copies under .scratch/ (AC-0287, AC-0288, ac0284a) are historical
artifacts, not fix targets.

Inputs
------
Each of BASE and CUR is a DIRECTORY of per-mode battery output. For mode M
the candidates are tried in order:  M.result, M.log, the sorted M-r*.log and
M-*.log files (hyphen boundary — "water" never reads "waterfall.log"); the
first one carrying usable data wins, so a dataless M.result does not shadow
the M.log that has the lines. A file carries either a `RESULT {json}` line (an
arm result) or `GENHASH ...` lines (the genhash arm — it prints no RESULT
dict, so it is compared line-for-line and has no pass/fail status). Modes
are the union of what exists in either directory; a mode with usable data on
only one side is a MISSING finding.

Status semantics (RESULT arms; AC-0330 declared the contract)
-------------------------------------------------------------
- ok:false in baseline AND current      -> BASELINE-RED: reported loudly, does
  NOT change the exit code by default (a standing red is a debt to fix or
  re-baseline, not a regression this comparison introduced). Use
  --fail-on-baseline-red to make it fail.
- ok value DIFFERS in either direction  -> STATUS-CHANGE: FAIL (both the
  regression true->false and the improvement false->true — a silent flip in
  either direction was the bug).
- ok present in baseline, absent in current and NOT declared value-reporting
  -> STATUS-LOST: FAIL (a pass/fail gate removed without a recorded contract).
- ok absent in baseline, false in current -> NEW-RED: FAIL (red where there
  was no gate to hold it).
- ok absent in BOTH: declared in godot/harness_data.yaml (AC-0330 "VALUE-
  REPORTING arm: no top-level `ok` by design") -> declared-no-ok, no
  complaint. NOT declared -> no-status: a visible line, no exit impact (the
  classification is a human process — AC-0330 — and crying on it at first run
  is how a good check gets disabled).
- ok absent in baseline, true in current -> status-added, information only.

Value diff
----------
Kept exactly from the prior art (the AC-0288 copy): recursive RESULT diff;
timing-ish leaves (wall_ms, ms, frames, ...) are jitter-tolerated; anything
else is STRUCTURAL and fails. genhash arms: GENHASH lines must match.

Exit: 1 on any STRUCTURAL / missing / STATUS-CHANGE / NEW-RED / STATUS-LOST
(and BASELINE-RED under --fail-on-baseline-red), else 0.

Usage
-----
    python3 tasks/scripts/battery_compare.py BASE_DIR CUR_DIR
        [--harness-data PATH]     (default: godot/harness_data.yaml next to the repo)
        [--fail-on-baseline-red]
"""
import argparse
import json
import os
import re
import sys

DEFAULT_HARNESS = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)),
                 "..", "..", "godot", "harness_data.yaml"))

# AC-0330's declaration phrase in harness_data.yaml notes.
DECLARED_MARKER = "VALUE-REPORTING arm"

# timing-ish leaves = jitter (verbatim from the .scratch/AC-0288-gates copy)
JITTER_LEAVES = ("wall_ms", "wall", "elapsed_ms", "frames", "n_frames",
                 "t0", "t", "ms", "ms_avg", "total_ms")


def load_mode_file(path):
    """Return ('result', dict) / ('genhash', [lines]) / (None, None)."""
    try:
        txt = open(path).read()
    except (FileNotFoundError, OSError):
        return None, None
    m = re.search(r"RESULT (\{.*)", txt)
    if m:
        try:
            return "result", json.loads(m.group(1))
        except json.JSONDecodeError:
            return None, None
    lines = [l for l in txt.splitlines() if l.startswith("GENHASH ")]
    if lines:
        return "genhash", lines
    return None, None


def resolve_mode_data(directory, mode):
    """First candidate file that carries usable data (a dataless
    <mode>.result must not shadow the <mode>.log that has the lines)."""
    cands = [n for n in (f"{mode}.result", f"{mode}.log")
             if os.path.isfile(os.path.join(directory, n))]
    # hyphen boundary required, so mode "water" never picks up "waterfall.log"
    pat = re.compile(rf"^{re.escape(mode)}(?:-r\d+|-[\w]+)?\.log$")
    seen = set(cands)
    cands += sorted(n for n in os.listdir(directory)
                    if pat.match(n) and n not in seen)
    for name in cands:
        kind, data = load_mode_file(os.path.join(directory, name))
        if data is not None:
            return kind, data
    return None, None


def discover_modes(directory):
    modes = set()
    for n in os.listdir(directory):
        if not os.path.isfile(os.path.join(directory, n)):
            continue
        m = re.match(r"(.+)\.(?:result|log)$", n)
        if m:
            modes.add(m.group(1))
        else:
            m = re.match(r"(.+)-r\d+\.log$", n)
            if m:
                modes.add(m.group(1))
    return modes


def declared_no_ok_modes(harness_path):
    try:
        import yaml
    except ImportError:
        return set()
    try:
        with open(harness_path) as f:
            data = yaml.safe_load(f)
    except (OSError, yaml.YAMLError):
        return set()
    out = set()
    for name, row in (data.get("modes") or {}).items():
        notes = (row or {}).get("notes") or ""
        if DECLARED_MARKER in notes:
            out.add(name)
    return out


def diff_keys(a, b, prefix=""):
    out = []
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            p = f"{prefix}.{k}" if prefix else k
            if k not in a:
                out.append((p, "<missing>", b[k]))
            elif k not in b:
                out.append((p, a[k], "<missing>"))
            else:
                out.extend(diff_keys(a[k], b[k], p))
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            out.append((f"{prefix}[len]", len(a), len(b)))
        else:
            for i, (x, y) in enumerate(zip(a, b)):
                out.extend(diff_keys(x, y, f"{prefix}[{i}]"))
    else:
        if a != b:
            out.append((prefix or "(root)", a, b))
    return out


def status_of(result):
    """Top-level ok as True/False/None (only a real bool counts)."""
    if isinstance(result, dict) and isinstance(result.get("ok"), bool):
        return result["ok"]
    return None


def fmt(v):
    return {True: "true", False: "false", None: "(no ok)"}.get(v, str(v))


def main():
    ap = argparse.ArgumentParser(
        description="Compare two battery outputs on values AND pass/fail status.")
    ap.add_argument("base", help="baseline directory (per-mode .result/.log)")
    ap.add_argument("cur", help="current directory (per-mode .result/.log)")
    ap.add_argument("--harness-data", default=DEFAULT_HARNESS,
                    help="godot/harness_data.yaml (declaration source for "
                         "value-reporting arms; default: repo godot/harness_data.yaml)")
    ap.add_argument("--fail-on-baseline-red", action="store_true",
                    help="make BASELINE-RED arms fail the comparison "
                         "(default: report only, no exit impact)")
    args = ap.parse_args()

    for d in (args.base, args.cur):
        if not os.path.isdir(d):
            print(f"battery_compare: not a directory: {d}", file=sys.stderr)
            return 2
    declared = declared_no_ok_modes(args.harness_data)

    modes = sorted(discover_modes(args.base) | discover_modes(args.cur))
    if not modes:
        print("battery_compare: no mode files found in either input",
              file=sys.stderr)
        return 2

    identical, jitter_only, structural, missing = [], [], [], []
    status_change, new_red, status_lost, baseline_red = [], [], [], []
    declared_lines, no_status, status_added = [], [], []

    for mode in modes:
        bkind, bdata = resolve_mode_data(args.base, mode)
        ckind, cdata = resolve_mode_data(args.cur, mode)
        if bdata is None and cdata is None:
            continue  # no usable data on either side: not a finding
        if bdata is None or cdata is None:
            missing.append((mode, "cur" if cdata is None else "base"))
            continue
        if bkind != ckind:
            structural.append((mode, [(f"(kind)", bkind, ckind)], 1))
            continue

        # --- status (RESULT arms only; genhash has no pass/fail) ---
        if bkind == "result":
            bok, cok = status_of(bdata), status_of(cdata)
            if bok is False and cok is False:
                baseline_red.append(mode)
            elif bok is not None and cok is not None and bok != cok:
                status_change.append((mode, bok, cok))
            elif bok is not None and cok is None:
                if mode in declared:
                    declared_lines.append((mode, f"ok {fmt(bok)} in base, none in cur (declared value-reporting)"))
                else:
                    status_lost.append((mode, bok))
            elif bok is None and cok is False:
                new_red.append(mode)
            elif bok is None and cok is True:
                status_added.append(mode)
            elif bok is None and cok is None:
                (declared_lines if mode in declared else no_status).append(mode)

        # --- value diff (kept from the AC-0288 copy) ---
        if bkind == "genhash":
            if bdata == cdata:
                identical.append(mode)
            else:
                structural.append((mode, [("genhash lines differ",
                                           len(bdata), len(cdata))], 1))
            continue
        diffs = diff_keys(bdata, cdata)
        if not diffs:
            if mode not in identical:
                identical.append(mode)
            continue
        st = [d for d in diffs
              if d[0].split(".")[-1] not in JITTER_LEAVES
              and not d[0].endswith("[wall_ms]")]
        if st:
            structural.append((mode, st[:3], len(st)))
        elif mode not in identical:
            jitter_only.append((mode, len(diffs) - len(st) or len(diffs)))

    n = len(modes)
    print(f"battery_compare: {args.base}  vs  {args.cur}  ({n} modes)")
    print(f"\nvalue diff")
    print(f"  identical    ({len(identical)}): {', '.join(identical) or '-'}")
    print(f"  jitter-only  ({len(jitter_only)}): {jitter_only or '-'}")
    print(f"  STRUCTURAL   ({len(structural)}):")
    for m, st, tot in structural:
        print(f"    {m}: {st}" + (f"  (+{tot - len(st)} more)" if tot > len(st) else ""))
    print(f"  missing      ({len(missing)}): {missing or '-'}")
    print(f"\nstatus")
    for m, a, b in status_change:
        print(f"  !! STATUS-CHANGE  {m}: ok {fmt(a)} -> {fmt(b)} (either direction is a finding)")
    for m in new_red:
        print(f"  !! NEW-RED         {m}: no ok in baseline, ok=false in current")
    for m, bok in status_lost:
        print(f"  !! STATUS-LOST     {m}: ok {fmt(bok)} in baseline, no ok in current (not declared)")
    if baseline_red:
        note = ("FAILS with --fail-on-baseline-red" if args.fail_on_baseline_red
                else "standing reds — reported, not a regression this comparison introduced")
        print(f"  !! BASELINE-RED    ({len(baseline_red)}): {', '.join(baseline_red)}  [{note}]")
    for m in declared_lines:
        extra = f": {m[1]}" if isinstance(m, tuple) else ""
        print(f"  declared-no-ok  {m[0] if isinstance(m, tuple) else m}{extra} (value-reporting by design, harness_data.yaml)")
    for m in no_status:
        print(f"  no-status       {m} (no ok either side, NOT declared — classify it, AC-0330 style)")
    for m in status_added:
        print(f"  status-added    {m} (no ok in baseline, ok=true in current)")

    fails = []
    if structural:
        fails.append(f"{len(structural)} structural")
    if missing:
        fails.append(f"{len(missing)} missing")
    if status_change:
        fails.append(f"{len(status_change)} status-change")
    if new_red:
        fails.append(f"{len(new_red)} new-red")
    if status_lost:
        fails.append(f"{len(status_lost)} status-lost")
    if args.fail_on_baseline_red and baseline_red:
        fails.append(f"{len(baseline_red)} baseline-red")
    verdict = "FAIL (" + ", ".join(fails) + ")" if fails else "PASS"
    print(f"\nRESULT: {verdict}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
