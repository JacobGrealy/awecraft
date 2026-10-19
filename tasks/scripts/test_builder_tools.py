#!/usr/bin/env python3
"""unittest for the four AC-0455 builder tools. No network, no godot; every
file the tests touch lives under .scratch/AC-0455-tests/ (plus a transient
tasks/AC-9999/ results page that each test cleans up). One negative test per
guard: a guard without a failing replica is not a tested guard.

Run: python3 tasks/scripts/test_builder_tools.py
"""

import contextlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))

import builder_stats  # noqa: E402
import context_pack  # noqa: E402
import gate_run  # noqa: E402
import results_page  # noqa: E402
import yaml  # noqa: E402

SCRATCH = REPO_ROOT / ".scratch" / "AC-0455-tests"
GATES = REPO_ROOT / ".scratch" / "AC-9999-gates"  # where gate_run writes
TICKET_DIR = REPO_ROOT / "tasks" / "AC-9999"
MONSTER_BASENAMES = {Path(m).name for m in context_pack.MONSTERS}


def _zstd(src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["zstd", "-q", "-f", str(src), "-o", str(dst)],
                   check=True)


def _synth_session(path, sid, created, depth, wall_ms, steps, out, inp):
    """One synthetic session.jsonl.zstd with known counts/timestamps.

    Written COMPACT, as the DSH harness emits it (the envelope fast path
    keys on the no-space `{"type":...` shape)."""
    src = path.with_suffix(".jsonl")
    recs = [{"type": "session", "id": sid, "createdAt": created,
             "delegationDepth": depth, "cwd": "/tmp/synth"}]
    recs.append({"type": "turn/start", "seq": 0, "time": created + 1000})
    for i in range(steps):
        recs.append({"type": "step/start", "seq": 10 + i,
                     "time": created + wall_ms // (steps + 1) * (i + 1),
                     "data": {"turn": 1, "step": i + 1}})
    recs.append({"type": "assistant/message", "seq": 99,
                 "time": created + wall_ms,
                 "data": {"usage": {"inputTokens": inp,
                                    "outputTokens": out}}})
    src.parent.mkdir(parents=True, exist_ok=True)
    src.write_text("\n".join(
        json.dumps(r, separators=(",", ":")) for r in recs) + "\n")
    _zstd(src, path)
    src.unlink()
    return path


def _run_cli(fn, argv, want_rc):
    """Run a tool's main() capturing stdout+stderr; assert the exit code."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), \
            contextlib.redirect_stderr(buf):
        rc = fn(argv)
    if want_rc is not None:
        self_rc = rc
        assert self_rc == want_rc, \
            "rc=%s (want %s)\n%s" % (rc, want_rc, buf.getvalue())
    return rc, buf.getvalue()


class Base(unittest.TestCase):
    def setUp(self):
        shutil.rmtree(SCRATCH, ignore_errors=True)
        SCRATCH.mkdir(parents=True)
        shutil.rmtree(GATES, ignore_errors=True)
        shutil.rmtree(TICKET_DIR, ignore_errors=True)

    def tearDown(self):
        shutil.rmtree(GATES, ignore_errors=True)
        shutil.rmtree(TICKET_DIR, ignore_errors=True)




class ContextPackTest(Base):
    """Fixture: AC-0433 (a real ticket with a prose plan and inline
    file:line anchors)."""

    def test_ac0433_pack_under_cap_with_anchors(self):
        out = SCRATCH / "ac0433" / "context.md"
        rc, _log = _run_cli(context_pack.main,
                            ["AC-0433", "--out", str(out)], 0)
        text = out.read_text()
        b = len(text.encode())
        self.assertLessEqual(b / 3.6, 12000,
                             "pack over its cap: %d bytes" % b)
        # an anchor excerpt with a file:line header
        m = re.search(r"^### (\S+):(\d+)$", text, re.M)
        self.assertIsNotNone(m, "no anchor excerpt with a file:line header")
        # each section the plan promises
        for sec in ("## Ticket", "## Notes", "## Plan", "## Anchors",
                    "## Harness modes", "## Cap"):
            self.assertIn(sec, text)
        # no more than 200 lines from any monster file
        headers = list(re.finditer(r"^### (\S+):(\d+)$", text, re.M))
        for i, h in enumerate(headers):
            if Path(h.group(1)).name not in MONSTER_BASENAMES:
                continue
            end = headers[i + 1].start() if i + 1 < len(headers) else \
                text.find("\n## ", h.end())
            block = text[h.end():end]
            lines = [l for l in block.splitlines() if re.match(r"\s*\d+\|", l)]
            self.assertLessEqual(
                len(lines), 200,
                "monster %s contributed %d lines" % (h.group(1), len(lines)))

    def test_token_cap_drops_items_and_names_them(self):
        out = SCRATCH / "tiny" / "context.md"
        _run_cli(context_pack.main,
                 ["AC-0433", "--out", str(out), "--max-tokens", "250"], 0)
        text = out.read_text()
        self.assertLessEqual(len(text.encode()) / 3.6, 250 * 1.10,
                             "cap not held")
        self.assertIn("## Cap", text)
        trunc = [l for l in text.splitlines() if l.startswith("TRUNCATED:")]
        self.assertGreaterEqual(len(trunc), 2, "no drops recorded")
        self.assertIn("TRUNCATED: Notes", text)  # 9.6 KB — the big one
        self.assertNotIn("## Notes", text)

    def test_monster_refusal_guard(self):
        # >200 lines of a known monster is a hard refusal (exit-2 path)
        with self.assertRaises(context_pack.PackError):
            context_pack.check_monsters({"godot/scenes/harness.gd": 201})
        with self.assertRaises(context_pack.PackError):
            context_pack.check_monsters({"godot/world/world.gd": 201})
        # under the cap: no refusal
        context_pack.check_monsters({"godot/scenes/harness.gd": 17,
                                     "godot/world/world.gd": 34})
        # a non-monster file may exceed 200 lines in the plan's accounting
        context_pack.check_monsters({"tasks/AC-0433/plan.html": 5000})

    def test_unknown_ticket_is_bad_usage(self):
        _run_cli(context_pack.main,
                 ["AC-9999", "--out", str(SCRATCH / "nope.md")], 2)


class GateRunTest(Base):
    def test_dry_run_prints_n_commands_invokes_nothing(self):
        rc, log = _run_cli(gate_run.main,
                           ["AC-9999", "--arms", "g0,smoke,probe",
                            "--dry-run"], 0)
        cmd_lines = [l for l in log.splitlines() if " cmd=bash -c " in l]
        self.assertEqual(len(cmd_lines), 7, log)  # 1 + 5 (smoke) + 1
        self.assertNotIn("AWECRAFT_LOGIC",
                         [l for l in log.splitlines()
                          if l.startswith("g0: env=")][0],
                         "g0 must be a bare load")
        log_lines = [l for l in log.splitlines() if " log=" in l]
        self.assertEqual(len(log_lines), 7)
        self.assertFalse(GATES.exists(), "dry-run wrote nothing")

    def test_smoke_expands_to_battery_smoke(self):
        import yaml as _yaml
        want = (yaml.safe_load(
            (REPO_ROOT / "tasks" / "harness_data.yaml").read_text())
                .get("battery", {}).get("smoke", []))
        self.assertEqual(len(want), 5)
        _run_cli(gate_run.main, ["AC-9999", "--arms", "smoke",
                                 "--dry-run"], 0)
        log = io.StringIO()
        with contextlib.redirect_stdout(log), \
                contextlib.redirect_stderr(io.StringIO()):
            rc = gate_run.run(["AC-9999", "--arms", "smoke", "--dry-run"])
        self.assertEqual(rc, 0)
        names = re.findall(r"^(\w+): cmd=", log.getvalue(), re.M)
        self.assertEqual(names, want)

    def test_bad_usage_exit_2(self):
        _run_cli(gate_run.main,
                 ["AC-9999", "--arms", "g0 bad name", "--dry-run"], 2)
        _run_cli(gate_run.main,
                 ["AC-9999", "--arms", "g0", "--dry-run",
                  "--timeout", "zz=5"], 2)
        _run_cli(gate_run.main,
                 ["AC-9999", "--arms", "g0", "--dry-run",
                  "--env", "1BAD=x"], 2)

    def test_slot_guard_exit_3_never_kills(self):
        real = gate_run._slot_free
        gate_run._slot_free = lambda: False  # the slot is "held"
        try:
            rc, log = _run_cli(gate_run.main,
                               ["AC-9999", "--arms", "g0",
                                "--wait-slot", "1"], 3)
            self.assertIn("exit 3", log)
        finally:
            gate_run._slot_free = real


class ResultsPageTest(Base):
    def _stub(self, with_log=True):
        GATES.mkdir(parents=True)
        log_name = ".scratch/AC-9999-gates/g0-r1.log"
        summary = {"ticket": "AC-9999", "gate_dir": ".scratch/AC-9999-gates",
                   "arms": [{"name": "g0", "mode": None, "rc": 0,
                             "script_errors": 0, "shader_errors": 0,
                             "wall_s": 42.0, "ok": True,
                             "result": {"ok": True}, "log": log_name}]}
        (GATES / "summary.json").write_text(json.dumps(summary))
        if with_log:
            (GATES / "g0-r1.log").write_text(
                "boot ok\nRESULT {\"ok\": true}\n")
        return GATES / "summary.json"

    def test_missing_log_refuses(self):
        stub = self._stub(with_log=False)
        rc, log = _run_cli(results_page.main,
                           ["AC-9999", "--summary", str(stub)], 1)
        self.assertIn("no log file on disk", log)
        self.assertFalse(TICKET_DIR.exists(), "refusal must not write")

    def test_headline_not_in_log_refuses(self):
        stub = self._stub(with_log=True)
        rc, log = _run_cli(results_page.main,
                           ["AC-9999", "--summary", str(stub),
                            "--headline", "ok=false"], 1)
        self.assertIn("not present in", log)

    def test_complete_stub_renders_four_sections(self):
        stub = self._stub(with_log=True)
        TICKET_DIR.mkdir(parents=True)
        (TICKET_DIR / "dummy.json").write_text("{}")  # forces Artifacts
        rc, _log = _run_cli(results_page.main,
                            ["AC-9999", "--summary", str(stub),
                             "--files", "tasks/scripts/results_page.py"],
                            0)
        page = (TICKET_DIR / "AC-9999-results.html").read_text()
        for sec in ("1. Gates", "2. Deviations", "3. Files", "4. Artifacts"):
            self.assertIn("<h2>%s</h2>" % sec, page)
        self.assertIn("ok=true", page)  # the greppable headline
        self.assertIn("None.", page)  # deviations default
        self.assertNotIn("http://", page)  # self-contained
        self.assertNotIn("https://", page)

    def test_missing_summary_is_bad_usage(self):
        _run_cli(results_page.main,
                 ["AC-9999", "--summary", str(SCRATCH / "absent.json")], 2)


class BuilderStatsTest(Base):
    def test_synthetic_exact_wall_and_toks(self):
        sdir = SCRATCH / "sessions" / "exact"
        created = 1_700_000_000_000
        path = _synth_session(sdir / "s1" / "session.jsonl.zstd", "s1",
                              created, 1, 3_600_000, 2, 1000, 500)
        kept, skipped = builder_stats.gather([path])
        self.assertEqual(len(kept), 1)
        r = kept[0]
        self.assertEqual(r["wall_s"], 3600.0)
        self.assertEqual(r["steps"], 2)
        self.assertEqual(r["out_tokens"], 1000)
        self.assertEqual(r["in_tokens"], 500)
        self.assertAlmostEqual(r["out_tokens"] / r["wall_s"],
                               1000.0 / 3600.0)

    def test_depth_filter_uses_head_peek(self):
        sdir = SCRATCH / "sessions" / "depth"
        created = 1_700_000_000_000
        p1 = _synth_session(sdir / "a" / "session.jsonl.zstd", "a",
                            created, 1, 1_000, 1, 10, 5)
        p0 = _synth_session(sdir / "b" / "session.jsonl.zstd", "b",
                            created, 0, 1_000, 1, 10, 5)
        kept, skipped = builder_stats.gather([p0, p1])
        self.assertEqual([r["session"] for r in kept], ["a"])
        self.assertEqual(skipped, 1)
        kept_all, _ = builder_stats.gather([p0, p1], all_depths=True)
        self.assertEqual(len(kept_all), 2)

    def test_perfectly_linear_gives_r2_1(self):
        sdir = SCRATCH / "sessions" / "linear"
        created = 1_700_000_000_000
        paths = []
        for i in range(5):
            out = (i + 1) * 1000
            wall_ms = int((10 + 0.01 * out) * 1000)  # exact: 20..60 s
            paths.append(_synth_session(
                sdir / ("s%d" % i) / "session.jsonl.zstd", "s%d" % i,
                created + i, 1, wall_ms, 1, out, 100))
        kept, _sk = builder_stats.gather(paths)
        a, b, r2, n = builder_stats.fit(kept)
        self.assertEqual(n, 5)
        self.assertGreater(r2, 0.9999)
        self.assertAlmostEqual(b, 0.01, places=6)
        self.assertAlmostEqual(a, 10.0, places=4)

    def test_sessions_glob_cli(self):
        sdir = SCRATCH / "sessions" / "cli"
        created = 1_700_000_000_000
        _synth_session(sdir / "c" / "session.jsonl.zstd", "c", created,
                       1, 3_600_000, 3, 6000, 900)
        out = io.StringIO()
        with contextlib.redirect_stdout(out), \
                contextlib.redirect_stderr(io.StringIO()):
            rc = builder_stats.main(["--sessions",
                                     str(sdir / "**" / "session.jsonl.zstd"),
                                     "--json"])
        self.assertEqual(rc, 0)
        data = json.loads(out.getvalue())
        self.assertEqual(len(data["sessions"]), 1)
        self.assertEqual(data["sessions"][0]["out_tokens"], 6000)
        self.assertEqual(data["sessions"][0]["steps"], 3)


if __name__ == "__main__":
    unittest.main(verbosity=2)
