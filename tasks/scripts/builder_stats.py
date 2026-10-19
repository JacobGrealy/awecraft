#!/usr/bin/env python3
"""The builder scoreboard from the DSH session logs (AC-0455).

    python3 tasks/scripts/builder_stats.py [--since YYYY-MM-DD] [--json]
                                           [--top N] [--sessions GLOB] [--all]

Reads ~/.dsh/sessions/**/session.jsonl.zstd (decompressed with `zstd -dc`
via subprocess — no python zstd dependency assumed) and reports, per
session, in this exact schema:

  * the {"type":"session"} record gives createdAt (ms epoch) and
    delegationDepth — keep depth > 0 (builders) unless --all;
  * wall = (max time over records) - createdAt, both in ms;
  * steps = count of step/start;
  * tokens = sum of assistant/message -> data.usage input/output
    (accepts outputTokens / output_tokens spellings too);

then fits wall_s = a + b*out_tokens (ordinary least squares, done by hand —
no numpy) and prints the law line with R². Baseline to reproduce on the
current logs: ~15 tok/s, R² ≈ 0.93, median run 2.40 h / 138k tokens /
154 steps. --json emits the same as a dict; --top N prints the N longest.

Exit codes: 0 ok; 2 bad usage (no sessions found, zstd missing, bad date).
"""

import argparse
import datetime
import json
import re
import statistics
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SESSIONS_ROOT = Path.home() / ".dsh" / "sessions"


class StatsError(Exception):
    """A user-facing failure with a clean message (no traceback)."""


def workspace_session_root():
    """This repo's session dir under ~/.dsh/sessions (DSH mangles the repo
    path into the dir name, e.g. /home/x/AweCraft -> --home-x-AweCraft--).
    The scoreboard is about THIS project's builders: the AC-0454 baseline
    (R² ≈ 0.93, ~15 tok/s) is reproduced on the AweCraft population, not on
    every workspace on the box (other workspaces dilute the fit to
    R² ≈ 0.84). --sessions overrides for any other population."""
    mangled = REPO_ROOT.as_posix().replace("/", "-")
    if SESSIONS_ROOT.is_dir():
        hits = [d for d in SESSIONS_ROOT.iterdir()
                if d.is_dir() and mangled in d.name]
        if hits:
            return sorted(hits)[0]
    return SESSIONS_ROOT


def default_sessions():
    root = workspace_session_root()
    if root != SESSIONS_ROOT:
        sys.stderr.write("builder_stats: session root %s (this workspace)\n"
                         % root)
    return sorted(root.rglob("session.jsonl.zstd"))


ENVELOPE_RE = re.compile(r'^\{"type":"[^"]*","seq0?":\d+,"time0?":(\d+)')
CANDIDATE_MARKERS = ('"step/start"', '"assistant/message"')


def zstd_decompress(path):
    """Decompress path with `zstd -dc` (subprocess) -> text. No python zstd
    dependency is assumed."""
    proc = subprocess.run(["zstd", "-dc", str(path)], capture_output=True)
    if proc.returncode != 0:
        raise StatsError("zstd failed on %s: %s"
                         % (path, proc.stderr.decode(errors="replace").strip()))
    return proc.stdout.decode("utf-8", errors="replace")


def session_head(path):
    """The first line of the decompressed file as a dict, or None. Used to
    filter by delegationDepth WITHOUT decompressing the whole file (a
    depth-0 session's log is never read past its header)."""
    path = Path(path)
    proc = subprocess.Popen(["zstd", "-dc", str(path)],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    first = proc.stdout.readline()
    proc.stdout.close()
    proc.wait()
    if not first.strip():
        return None
    try:
        rec = json.loads(first)
    except ValueError:
        return None
    return rec if isinstance(rec, dict) and rec.get("type") == "session" \
        else None


def _usage_int(usage, *keys):
    for k in keys:
        v = usage.get(k)
        if isinstance(v, (int, float)):
            return int(v)
    return 0


def _parse_count(ln, session, counts):
    """Full json.loads of a type-candidate line; dispatches on the REAL type
    (a candidate literal inside a message body parses to its own type and
    counts nothing), and tallies time/steps/tokens in place."""
    try:
        rec = json.loads(ln)
    except ValueError:
        return session
    if not isinstance(rec, dict):
        return session
    t = rec.get("type")
    if t == "session":
        session = rec
    elif t == "step/start":
        counts["steps"] += 1
    elif t == "assistant/message":
        usage = (rec.get("data") or {}).get("usage") or {}
        counts["in"] += _usage_int(usage, "input", "inputTokens",
                                   "input_tokens")
        counts["out"] += _usage_int(usage, "output", "outputTokens",
                                    "output_tokens")
    tm = rec.get("time")
    if isinstance(tm, (int, float)):
        counts["max_time"] = (tm if counts["max_time"] is None
                              else max(counts["max_time"], tm))
    return session


def read_session(path):
    """One session file -> dict, or None (not a session / unreadable).

    Fast path: the record envelope carries "time" as a leading field on
    EVERY non-session record, so the envelope regex reads it without a JSON
    parse; only the type-candidate lines (step/start, assistant/message)
    get a full json.loads (which dispatches on the real type, so the counts
    stay exact).
    """
    path = Path(path)
    session = None
    counts = {"steps": 0, "in": 0, "out": 0, "max_time": None}
    for ln in zstd_decompress(path).splitlines():
        if not ln:
            continue
        m = ENVELOPE_RE.match(ln)
        if m:
            v = int(m.group(1))
            counts["max_time"] = (v if counts["max_time"] is None
                                  else max(counts["max_time"], v))
            if any(c in ln for c in CANDIDATE_MARKERS):
                session = _parse_count(ln, session, counts)
            continue
        if ln.startswith('{"type":"session"'):
            session = _parse_count(ln, session, counts)
        elif any(c in ln for c in CANDIDATE_MARKERS):
            session = _parse_count(ln, session, counts)
    if session is None:
        return None
    created = session.get("createdAt")
    if not isinstance(created, (int, float)) or counts["max_time"] is None:
        return None
    wall_ms = counts["max_time"] - created
    return {
        "session": str(session.get("id", path.parent.name)),
        "depth": session.get("delegationDepth", 0),
        "created_at": created,
        "wall_s": wall_ms / 1000.0,
        "steps": counts["steps"],
        "in_tokens": counts["in"],
        "out_tokens": counts["out"],
    }


def gather(session_files, since=None, all_depths=False):
    """Read every session file; returns (kept, skipped) with the filter
    applied (depth > 0 unless --all; createdAt >= since-midnight)."""
    since_ms = None
    if since:
        try:
            d = datetime.date.fromisoformat(since)
        except ValueError:
            raise StatsError("bad --since date %r (YYYY-MM-DD)" % since)
        since_ms = int(datetime.datetime(d.year, d.month, d.day,
                                         tzinfo=datetime.timezone.utc)
                       .timestamp() * 1000)
    kept, skipped = [], 0
    for path in session_files:
        try:
            # Depth filter BEFORE the full decompress: a depth-0 session's
            # log is large and is never read past its header.
            if not all_depths:
                head = session_head(path)
                if head is None:
                    skipped += 1
                    continue
                if head.get("delegationDepth", 0) <= 0:
                    skipped += 1
                    continue
            row = read_session(path)
        except StatsError:
            skipped += 1
            continue
        if row is None:
            skipped += 1
            continue
        if not all_depths and row["depth"] <= 0:
            skipped += 1
            continue
        if since_ms is not None and row["created_at"] < since_ms:
            skipped += 1
            continue
        row["file"] = str(path)
        kept.append(row)
    return kept, skipped


def fit(kept):
    """OLS wall_s = a + b*out_tokens by hand; (a, b, r2, n) or None."""
    pts = [(r["out_tokens"], r["wall_s"]) for r in kept
           if r["wall_s"] > 0 and r["out_tokens"] > 0]
    n = len(pts)
    if n < 2:
        return None
    sx = sum(x for x, _y in pts)
    sy = sum(y for _x, y in pts)
    sxy = sum(x * y for x, y in pts)
    sxx = sum(x * x for x, _y in pts)
    denom = n * sxx - sx * sx
    if denom == 0:
        return None
    b = (n * sxy - sx * sy) / denom
    a = (sy - b * sx) / n
    ybar = sy / n
    ss_tot = sum((y - ybar) ** 2 for _x, y in pts)
    ss_res = sum((y - (a + b * x)) ** 2 for x, y in pts)
    r2 = 1.0 - ss_res / ss_tot if ss_tot > 0 else 1.0
    return a, b, r2, n


def _fmt_row(r):
    dur_h = r["wall_s"] / 3600.0
    ops = (r["out_tokens"] / r["steps"]) if r["steps"] else 0.0
    tps = (r["out_tokens"] / r["wall_s"]) if r["wall_s"] > 0 else 0.0
    return "%s  %7.2f h  %5d steps  %8d out  %8d in  %8.0f out/step  %6.2f tok/s" \
        % (r["session"][:12], dur_h, r["steps"], r["out_tokens"],
           r["in_tokens"], ops, tps)


def law_line(fit_res):
    if fit_res is None:
        return "law: (not enough points to fit)"
    a, b, r2, n = fit_res
    tps = ("~%.1f tok/s" % (1.0 / b)) if b > 0 else "(b <= 0)"
    return "law: wall_s = %.0f + %.4f*out_tokens  (R²=%.3f, n=%d)  %s" \
        % (a, b, r2, n, tps)


def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__.splitlines()[0])
    ap.add_argument("--since", help="only sessions created on/after "
                   "YYYY-MM-DD (UTC midnight)")
    ap.add_argument("--json", action="store_true",
                    help="emit the whole report as one JSON dict")
    ap.add_argument("--top", type=int, default=None,
                    help="print the N longest runs (default: all)")
    ap.add_argument("--sessions", help="glob for session.jsonl.zstd files "
                   "(default: ~/.dsh/sessions/**/session.jsonl.zstd)")
    ap.add_argument("--all", action="store_true",
                    help="include depth-0 sessions (default: builders only)")
    a = ap.parse_args(argv)

    if a.sessions:
        import glob
        files = sorted(Path(p) for p in glob.glob(a.sessions,
                                                  recursive=True))
    else:
        files = default_sessions()
    if not files:
        print("builder_stats: no session files matched %s"
              % (a.sessions or str(SESSIONS_ROOT)), file=sys.stderr)
        return 2

    try:
        kept, skipped = gather(files, since=a.since, all_depths=a.all)
    except StatsError as exc:
        print("builder_stats: %s" % exc, file=sys.stderr)
        return 2
    if not kept:
        print("builder_stats: no sessions passed the filters "
              "(skipped %d)" % skipped, file=sys.stderr)
        return 2

    kept.sort(key=lambda r: r["created_at"])
    fit_res = fit(kept)
    med = {
        "wall_h": statistics.median(r["wall_s"] for r in kept) / 3600.0,
        "out_tokens": statistics.median(r["out_tokens"] for r in kept),
        "steps": statistics.median(r["steps"] for r in kept),
        "n": len(kept),
    }
    if a.json:
        out = {
            "sessions": [{k: r[k] for k in
                          ("session", "depth", "created_at", "wall_s",
                           "steps", "in_tokens", "out_tokens")}
                         for r in kept],
            "fit": None if fit_res is None else
                    {"a": fit_res[0], "b": fit_res[1], "r2": fit_res[2],
                     "n": fit_res[3],
                     "tok_per_s": (1.0 / fit_res[1]
                                   if fit_res[1] > 0 else None)},
            "median": med,
            "skipped": skipped,
        }
        print(json.dumps(out, indent=2))
        return 0

    rows = sorted(kept, key=lambda r: -r["wall_s"])
    if a.top is not None:
        rows = rows[:max(0, a.top)]
    for r in rows:
        print(_fmt_row(r))
    print("median: %.2f h / %.0fk tokens / %.0f steps (n=%d, skipped %d)"
          % (med["wall_h"], med["out_tokens"] / 1000.0, med["steps"],
             med["n"], skipped))
    print(law_line(fit_res))
    return 0


if __name__ == "__main__":
    sys.exit(main())
