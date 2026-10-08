#!/usr/bin/env python3
"""SCRIPT ERROR + SHADER ERROR census over godot run logs (AC-0396).

G0's rule is ZERO `SCRIPT ERROR` lines in the run log, not `rc=0` - the
engine exits 0 even when scripts fail to compile. AC-0396 adds the twin:
zero `SHADER ERROR` lines. A shader that fails to compile is replaced by
the engine's fallback material (the white planet that hid behind a flat
pale disc for two days) and the process still exits 0 - the only trace
is the `SHADER ERROR` line in the run log, and for a week nothing read
it: the arms printed the error on every run while their gates checked
only their own RESULT fields.

AC-0403 (2026-10-08) adds the inverse blind spot: a native crash
(SIGSEGV, rc=134) leaves a log with ZERO `SCRIPT ERROR` and ZERO
`SHADER ERROR` lines - the backtrace is a C++ `handle_crash` dump the
census never counts, and the process exit status is 134, not 0. The
get_local segfault (chunk.gd:657) produced exactly this: a clean
census on a dead process. G0 must therefore pair this census WITH the
process exit status (rc == 0) - either alone is a false pass.

Usage:

    python3 tasks/scripts/gate_census.py LOG [LOG ...]
    python3 tasks/scripts/gate_census.py --allow-script N --allow-shader M LOG [LOG ...]

Per log: counts the `SCRIPT ERROR` and `SHADER ERROR` lines, names each
shader error (the res:// path it carries, else the first GDScript call
site in its backtrace), prints the table, and exits non-zero when any
log exceeds an allowance (default: zero of both). The forced-compile
arm (AWECRAFT_LOGIC=shaderforce) is the standing check that forces
every shipped shader to compile; its log is the one this census must
run on in the heavy-gate job, alongside every other arm's log.
"""

import argparse
import re
import sys

# The engine prints these at line start (leading whitespace tolerated):
# `SHADER ERROR: <message>` / `SCRIPT ERROR: <message>`. The colon is the
# discriminator — arm RESULT lines may quote the phrase (this helper's
# own note does) and must not count.
SHADER_RE = re.compile(r"^\s*SHADER ERROR:")
SCRIPT_RE = re.compile(r"^\s*SCRIPT ERROR:")
ATTR_RE = re.compile(r"at:.*?(res://[^\s()]+)")
BT_RE = re.compile(r"\[\d+\]\s+\S+\s+\((res://[^\s()]+)\)")


def shader_error_attr(lines, idx):
    """Name the shader a SHADER ERROR at lines[idx] belongs to.

    The engine block is:

        SHADER ERROR: <message>
                  at: (null) (res://core/x.gdshader:12)
                  GDScript backtrace (most recent call first):
                      [0] _setup_aero (res://scenes/main.gd:1049)

    File shaders carry their res:// path on the `at:` line; embedded
    (in-code set_code) shaders carry none - the call site names them.
    """
    for j in range(idx + 1, min(idx + 12, len(lines))):
        ln = lines[j]
        if SHADER_RE.search(ln) or ln.startswith("ERROR:"):
            break
        m = ATTR_RE.search(ln)
        if m:
            return m.group(1)
        m = BT_RE.search(ln)
        if m:
            return m.group(1) + " (call site)"
    return "(unnamed)"


def census(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    script = 0
    shader = []
    for i, ln in enumerate(lines):
        if SCRIPT_RE.search(ln):
            script += 1
        elif SHADER_RE.search(ln):
            shader.append((i + 1, shader_error_attr(lines, i)))
    return script, shader


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--allow-script", type=int, default=0,
                    help="tolerated SCRIPT ERROR lines per log (default 0)")
    ap.add_argument("--allow-shader", type=int, default=0,
                    help="tolerated SHADER ERROR lines per log (default 0)")
    ap.add_argument("logs", nargs="+", help="godot run logs to count")
    a = ap.parse_args(argv)
    rc = 0
    for path in a.logs:
        script, shader = census(path)
        bad = script > a.allow_script or len(shader) > a.allow_shader
        print("%s: SCRIPT ERROR %d (allow %d), SHADER ERROR %d (allow %d) %s"
              % (path, script, a.allow_script, len(shader), a.allow_shader,
                 "FAIL" if bad else "ok"))
        for lineno, attr in shader:
            print("    line %d: %s" % (lineno, attr))
        if bad:
            rc = 1
    print("census: %s" % ("FAIL" if rc else "ok"))
    return rc


if __name__ == "__main__":
    sys.exit(main())
