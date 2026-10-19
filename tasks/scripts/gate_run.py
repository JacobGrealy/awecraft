#!/usr/bin/env python3
"""Drive a light gate set for a ticket, one command (AC-0455).

    python3 tasks/scripts/gate_run.py AC-NNNN --arms g0,smoke,probe
        [--rev N] [--dry-run] [--mem-mb 8192] [--timeout 600]
        [--timeout arm=sec,...] [--env 'K=V K2=V2'] [--heavy] [--wait-slot 1800]

Arm vocabulary: `g0` is a bare `--headless` load with NO AWECRAFT_LOGIC (its
gate is rc==0 AND the census 0/0 — either alone is a false pass, per
gate_census.py's docstring). `smoke` expands to the five names in
harness_data.yaml battery.smoke, each as its own arm and log. Anything else
is a literal AWECRAFT_LOGIC mode; unknown names are accepted (ticket probes
are deliberately rowless — ac0433probe is the precedent) and a name that IS
in modes is only noted in the summary (informational).

This tool deliberately parses NO markdown for machine facts: the mode NAMES
and battery.smoke come from tasks/harness_data.yaml; timeouts and extra envs
come from the CLI with the documented defaults.

Per arm, the run shape (the .scratch/AC-0287-gates/gates_run.sh precedent,
with the envs passed as a list — never a shell string, no eval):

    bash -c 'ulimit -v <mem_mb*1024>; cd <repo>;
             exec timeout <sec> /home/angrygiant/tools/godot/godot
             --headless [--fixed-fps 600 when --fps] --path godot'
    > .scratch/AC-NNNN-gates/<arm>-r<N>.log 2>&1

with HOME=/tmp/dsh_home and the mode envs in the child's environment.

Guards: before EVERY arm, while `pgrep -f '[g]odot'` matches, sleep 20 s and
retry with a bounded wait (--wait-slot, default 1800 s); on expiry the run
exits 3 rather than starting a second engine. NEVER kill a process. The
memory cap (ulimit -v, in KB) is always on — an unbounded run OOM-kills the
harness itself (godot/OPS.md §2).

Outputs in .scratch/AC-NNNN-gates/: summary.json (per arm: name, mode, rc,
script_errors, shader_errors, wall_s, ok, the parsed RESULT, log path) and
summary.txt (one line per arm). With --heavy, HEAVY_GATES_DONE is touched on
completion and its path printed; without it, the marker is never created.

--dry-run prints the exact per-arm command lines and the planned log paths,
invokes nothing, writes nothing outside stdout — the only mode CI can run.

Exit codes: 0 iff every arm is ok; 1 otherwise; 3 slot-timeout; 2 bad usage.
"""

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import gate_census  # noqa: E402  (census: never reimplement the rule)
import yaml  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
ENGINE = "/home/angrygiant/tools/godot/godot"
GODOT_HOME = "/tmp/dsh_home"
HARNESS_DATA = REPO_ROOT / "tasks" / "harness_data.yaml"
MARKER = "HEAVY_GATES_DONE"

ARM_NAME_RE = re.compile(r"[A-Za-z0-9_.\-]+\Z")
ENV_KEY_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")


class GateRunError(Exception):
    """A user-facing failure with a clean message (no traceback)."""


def _harness_data():
    data = yaml.safe_load(HARNESS_DATA.read_text()) or {}
    smoke = (data.get("battery") or {}).get("smoke") or []
    modes = (data.get("modes") or {})
    return smoke, modes


def expand_arms(arms):
    """Arm names -> [(name, mode-or-None, known-in-modes)]. `smoke` expands to
    battery.smoke; `g0` stays a bare load; the rest are literal modes."""
    smoke, modes = _harness_data()
    out, seen = [], set()
    for a in arms:
        if a == "smoke":
            for m in smoke:
                if m not in seen:
                    seen.add(m)
                    out.append((m, m, True))
        elif a == "g0":
            if a not in seen:
                seen.add(a)
                out.append((a, None, False))
        else:
            if a not in seen:
                seen.add(a)
                out.append((a, a, a in modes))
    return out


def parse_envs(env_args):
    """`--env 'K=V K2=V2'` (repeatable) -> [(K, V)]; validated keys, values
    passed through as-is (they never touch a shell string)."""
    out = []
    for chunk in env_args or []:
        for tok in chunk.split():
            if "=" not in tok:
                raise GateRunError("bad --env token %r (expected K=V)" % tok)
            k, v = tok.split("=", 1)
            if not ENV_KEY_RE.match(k):
                raise GateRunError("bad --env key %r" % k)
            out.append((k, v))
    return out


def parse_timeouts(timeout_args, arm_names):
    """`--timeout 600` (global) and/or `--timeout arm=sec,...` (per-arm)."""
    default, per = None, {}
    for t in timeout_args or []:
        if re.fullmatch(r"\d+", t):
            default = int(t)
            continue
        for part in t.split(","):
            part = part.strip()
            if "=" not in part:
                raise GateRunError("bad --timeout %r (arm=sec expected)" % part)
            arm, sec = part.split("=", 1)
            if not re.fullmatch(r"\d+", sec):
                raise GateRunError("bad --timeout seconds %r" % sec)
            per[arm] = int(sec)
    for arm in per:
        if arm not in arm_names:
            raise GateRunError("--timeout names unknown arm %r" % arm)
    return default, per


def next_rev(gate_dir, arm, rev):
    if rev is not None:
        return rev
    highest = 0
    if gate_dir.is_dir():
        for p in gate_dir.iterdir():
            m = re.fullmatch(re.escape(arm) + r"-r(\d+)\.log", p.name)
            if m:
                highest = max(highest, int(m.group(1)))
    return highest + 1


def build_body(mem_mb, timeout_s, fps, quit=False):
    """The bash -c body: ulimit + cd + exec. Paths are the only interpolations
    and they are shlex-quoted constants — envs are NOT in the string. The bare
    g0 load carries `--quit` (the G0 recipe: a bare load has no arm to exit
    the process); the arms own their own exit and get no flag."""
    fps_flag = " --fixed-fps 600" if fps else ""
    quit_flag = " --quit" if quit else ""
    return ("ulimit -v %d; cd %s; exec timeout %d %s --headless%s%s --path godot"
            % (mem_mb * 1024, shlex.quote(str(REPO_ROOT)), timeout_s,
               shlex.quote(ENGINE), fps_flag, quit_flag))


def _slot_free():
    """True when no godot process matches `pgrep -f '[g]odot'`."""
    return subprocess.run(["pgrep", "-f", "[g]odot"],
                          capture_output=True).returncode != 0


def wait_for_slot(deadline_s):
    """Sleep-20s retry loop with a bounded wait; True on free, False on
    timeout. Never kills anything."""
    deadline = time.monotonic() + deadline_s
    while True:
        if _slot_free():
            return True
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(20, remaining))


def last_result(log_path):
    """The LAST `RESULT {...}` JSON line of the log, parsed (absent -> None)."""
    try:
        lines = Path(log_path).read_text(
            encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return None
    for ln in reversed(lines):
        s = ln.strip()
        if s.startswith("RESULT"):
            try:
                return json.loads(s[len("RESULT"):].strip())
            except (ValueError, TypeError):
                return None
    return None


def _fmt_value(v):
    if v is True:
        return "true"
    if v is False:
        return "false"
    if v is None:
        return "null"
    return str(v)


def headline(result):
    """ok/ok-ish key=value from the parsed RESULT (max 6, or first 6)."""
    if not isinstance(result, dict) or not result:
        return ""
    keys = [k for k in result if k == "ok" or str(k).startswith("ok")
            or "_ok" in str(k)]
    keys = keys or list(result.keys())
    return " ".join("%s=%s" % (k, _fmt_value(result[k])) for k in keys[:6])


def arm_ok(rc, script, shader, result):
    if rc != 0 or script != 0 or shader != 0:
        return False
    if isinstance(result, dict) and "ok" in result:
        return result["ok"] is True
    return True


def run_arm(name, mode, timeout_s, mem_mb, fps, envs, gate_dir, rev):
    log = gate_dir / ("%s-r%d.log" % (name, rev))
    body = build_body(mem_mb, timeout_s, fps, quit=(mode is None))
    env = dict(os.environ)
    env["HOME"] = GODOT_HOME
    if mode is not None:
        env["AWECRAFT_LOGIC"] = mode
    for k, v in envs:
        env[k] = v
    t0 = time.monotonic()
    with open(log, "w", encoding="utf-8") as f:
        proc = subprocess.run(["bash", "-c", body], env=env,
                              cwd=str(REPO_ROOT), stdout=f,
                              stderr=subprocess.STDOUT)
    wall = time.monotonic() - t0
    script, shader = gate_census.census(str(log))
    result = last_result(str(log))
    return {
        "name": name,
        "mode": mode,
        "rc": proc.returncode,
        "script_errors": script,
        "shader_errors": len(shader),
        "wall_s": round(wall, 1),
        "ok": arm_ok(proc.returncode, script, len(shader), result),
        "result": result,
        "log": str(log.relative_to(REPO_ROOT)),
    }


def run(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ticket", help="task id, e.g. AC-0433")
    ap.add_argument("--arms", required=True,
                    help="comma list: g0 / smoke / literal mode names")
    ap.add_argument("--rev", type=int, default=None,
                    help="log revision N (default: highest existing + 1)")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the per-arm commands and log paths; "
                         "invoke nothing, write nothing")
    ap.add_argument("--mem-mb", type=int, default=8192,
                    help="ulimit -v in MB (default 8192 — never removed)")
    ap.add_argument("--timeout", action="append", default=[],
                    help="global seconds (600) or per-arm (arm=sec,...)")
    ap.add_argument("--env", action="append", default=[],
                    help="'K=V K2=V2' extra envs (repeatable)")
    ap.add_argument("--fps", action="store_true",
                    help="add --fixed-fps 600 to the engine call")
    ap.add_argument("--wait-slot", type=int, default=1800,
                    help="bounded wait for a free godot slot, seconds "
                         "(default 1800; exit 3 on expiry)")
    ap.add_argument("--heavy", action="store_true",
                    help="touch HEAVY_GATES_DONE in the gate dir on completion")
    a = ap.parse_args(argv)

    try:
        arms_raw = [x for x in a.arms.split(",") if x]
        if not arms_raw:
            raise GateRunError("--arms is empty")
        for x in arms_raw:
            if not ARM_NAME_RE.match(x):
                raise GateRunError("bad arm name %r" % x)
        envs = parse_envs(a.env)
        arms = expand_arms(arms_raw)
        names = [n for n, _m, _k in arms]
        default_to, per_to = parse_timeouts(a.timeout, set(names))
    except GateRunError as exc:
        print("gate_run: %s" % exc, file=sys.stderr)
        return 2

    gate_dir = REPO_ROOT / ".scratch" / ("%s-gates" % a.ticket)

    if a.dry_run:
        for name, mode, _known in arms:
            to = per_to.get(name, default_to if default_to is not None else 600)
            rev = next_rev(gate_dir, name, a.rev)
            body = build_body(a.mem_mb, to, a.fps, quit=(mode is None))
            env_bits = ["HOME=%s" % GODOT_HOME]
            if mode is not None:
                env_bits.append("AWECRAFT_LOGIC=%s" % mode)
            env_bits += ["%s=%s" % (k, v) for k, v in envs]
            print("%s: cmd=bash -c '%s'" % (name, body))
            print("%s: env=%s" % (name, " ".join(env_bits)))
            print("%s: log=%s" % (name, gate_dir / ("%s-r%d.log" % (name, rev))))
        return 0

    try:
        gate_dir.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        print("gate_run: cannot create %s: %s" % (gate_dir, exc),
              file=sys.stderr)
        return 2

    results = []
    for name, mode, known in arms:
        if not wait_for_slot(a.wait_slot):
            print("gate_run: %s — the godot slot was still held after %d s; "
                  "not starting a second engine (exit 3)"
                  % (name, a.wait_slot), file=sys.stderr)
            _write_summaries(a.ticket, gate_dir, results, known_modes=arms)
            return 3
        to = per_to.get(name, default_to if default_to is not None else 600)
        rev = next_rev(gate_dir, name, a.rev)
        print("gate_run: %s (rev %d, timeout %d s, %d MB) ..."
              % (name, rev, to, a.mem_mb), file=sys.stderr)
        results.append(run_arm(name, mode, to, a.mem_mb, a.fps, envs,
                               gate_dir, rev))

    _write_summaries(a.ticket, gate_dir, results, known_modes=arms)
    if a.heavy:
        marker = gate_dir / MARKER
        marker.write_text("gate_run %s complete %s\n"
                          % (a.ticket, time.strftime("%Y-%m-%d %H:%M:%S")))
        print("gate_run: %s" % marker)

    all_ok = all(r["ok"] for r in results)
    print("gate_run: %s — %s" % (a.ticket,
                                  "all arms ok" if all_ok else "FAILURES"))
    return 0 if all_ok else 1


def _write_summaries(ticket, gate_dir, results, known_modes):
    known = {n for n, _m, k in known_modes if k}
    arms = []
    for r in results:
        entry = dict(r)
        entry["known_mode"] = r["name"] in known
        arms.append(entry)
    summary = {
        "ticket": ticket,
        "gate_dir": str(gate_dir.relative_to(REPO_ROOT)),
        "arms": arms,
    }
    (gate_dir / "summary.json").write_text(json.dumps(summary, indent=2)
                                           + "\n")
    lines = []
    for r in results:
        lines.append("%s  rc=%d  script=%d shader=%d  ok=%s  %ds  %s"
                     % (r["name"], r["rc"], r["script_errors"],
                        r["shader_errors"], "true" if r["ok"] else "false",
                        int(r["wall_s"]), headline(r["result"])))
    (gate_dir / "summary.txt").write_text("\n".join(lines) + "\n")
    sys.stderr.write("\n".join(lines) + "\n")


def main(argv=None):
    try:
        return run(argv)
    except GateRunError as exc:
        print("gate_run: %s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
