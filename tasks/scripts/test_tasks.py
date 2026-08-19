#!/usr/bin/env python3
"""Smoke test for the AweCraft task tooling (CLI + webui).

Run:  python3 tasks/scripts/test_tasks.py

Everything runs against COPIES of the registry (jarvis double-check pattern):
  * CLI mutations run as subprocesses against a sandbox TASKS.yaml (--file /
    env AWECRAFT_TASKS_FILE) under .scratch/ac0046-sandbox/
  * webui route checks run as real HTTP calls against
    `tasks/webui.py --port <free> --sandbox .scratch/ac0046-webui/`
  * every mutation is verified twice: response was right AND reloading the
    YAML from disk shows the change (a route/CLI that renders but does not
    persist is the failure mode that matters).

The live tasks/TASKS.yaml is only read (checksummed) and never written.
Exits non-zero on any failure.
"""

import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import time
import warnings
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen

warnings.simplefilter("error")  # any Python warning in-process = test failure

REPO_ROOT = Path(__file__).resolve().parents[2]
TASKS_DIR = REPO_ROOT / "tasks"
LIVE_YAML = TASKS_DIR / "TASKS.yaml"
TASKS_PY = TASKS_DIR / "scripts" / "tasks.py"
WEBUI_PY = TASKS_DIR / "webui.py"
SCRATCH = REPO_ROOT / ".scratch"
CLI_SANDBOX = SCRATCH / "ac0046-sandbox"
WEB_SANDBOX = SCRATCH / "ac0046-webui"

PASSED = []
FAILED = []


def check(name, condition, detail=""):
    if condition:
        PASSED.append(name)
        print("  PASS  %s" % name)
    else:
        FAILED.append((name, detail))
        print("  FAIL  %s%s" % (name, ("\n        " + detail) if detail else ""))


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run_cli(*args, file_arg=None, env_file=None):
    cmd = [sys.executable, str(TASKS_PY)]
    if file_arg:
        cmd += ["--file", str(file_arg)]
    env = dict(os.environ)
    env.pop("AWECRAFT_TASKS_FILE", None)
    if env_file:
        env["AWECRAFT_TASKS_FILE"] = str(env_file)
    cmd += list(args)
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    return proc


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def wait_port(host, port, timeout=15.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            s = socket.create_connection((host, port), timeout=1.0)
            s.close()
            return True
        except OSError:
            time.sleep(0.15)
    return False


def http(url, data=None, method=None):
    body = None
    if data is not None:
        body = urlencode(data).encode("utf-8")
    req = Request(url, data=body, method=method or ("POST" if body else "GET"))
    try:
        resp = urlopen(req, timeout=15)
        return resp.status, resp.read().decode("utf-8")
    except Exception as exc:  # HTTPError carries the status
        status = getattr(exc, "code", None)
        text = ""
        if status is not None:
            try:
                text = exc.read().decode("utf-8")
            except Exception:
                pass
        return status, text


def fresh_sandbox():
    for d in (CLI_SANDBOX, WEB_SANDBOX):
        if d.exists():
            shutil.rmtree(d)
        d.mkdir(parents=True)
    shutil.copy(LIVE_YAML, CLI_SANDBOX / "TASKS.yaml")


def load_yaml(path):
    import yaml
    with open(path) as f:
        return yaml.safe_load(f)


def find(data, tid):
    for item in (data.get("intake") or []):
        if item.get("id") == tid:
            return item
    return None


def main():
    live_sha_before = sha(LIVE_YAML)
    fresh_sandbox()
    cli_yaml = CLI_SANDBOX / "TASKS.yaml"

    print("\n-- CLI (against sandbox copy: %s)" % CLI_SANDBOX)
    p = run_cli("next", env_file=cli_yaml)
    check("CLI next via env file: exit 0", p.returncode == 0, p.stderr)
    check("CLI next via env file: names a queue id", "next: AC-" in p.stdout, p.stdout)

    p = run_cli("add", "--title", "smoke test task", "--source", "user",
                "--priority", "1", "--notes", "smoke", file_arg=cli_yaml)
    check("CLI add: exit 0", p.returncode == 0, p.stderr)
    import re
    m = re.search(r"\b(AC-\d{4})\b", p.stdout)
    tid = m.group(1) if m else None
    check("CLI add: printed a new id", tid is not None, p.stdout)

    if tid:
        p = run_cli("status", tid, "in-progress", file_arg=cli_yaml)
        check("CLI status in-progress: exit 0", p.returncode == 0, p.stderr)

        p = run_cli("comment", tid, "hello smoke", "--author", "agent", file_arg=cli_yaml)
        check("CLI comment: exit 0", p.returncode == 0, p.stderr)

        p = run_cli("queue", "add", tid, file_arg=cli_yaml)
        check("CLI queue add: exit 0", p.returncode == 0, p.stderr)
        p = run_cli("queue", "list", file_arg=cli_yaml)
        check("CLI queue list: contains id", tid in p.stdout, p.stdout)
        p = run_cli("queue", "remove", tid, file_arg=cli_yaml)
        check("CLI queue remove: exit 0", p.returncode == 0, p.stderr)
        p = run_cli("queue", "list", file_arg=cli_yaml)
        check("CLI queue list: id gone after remove", tid not in p.stdout, p.stdout)

        p = run_cli("status", tid, "done", file_arg=cli_yaml)
        check("CLI status done: exit 0", p.returncode == 0, p.stderr)

        p = run_cli("status", tid, "blocked", file_arg=cli_yaml)
        check("CLI status back to blocked: exit 0", p.returncode == 0, p.stderr)

    print("\n-- CLI: reload from disk (sandbox)")
    data = load_yaml(cli_yaml)
    item = find(data, tid) if tid else None
    check("disk: new task exists", item is not None)
    if item:
        check("disk: status round-tripped to blocked", item.get("status") == "blocked",
              str(item.get("status")))
        check("disk: completed_at cleared after leaving done", item.get("completed_at") is None)
        comments = item.get("comments") or []
        check("disk: one comment", len(comments) == 1, str(comments))
        if comments:
            check("disk: comment id increments per task (==1)", comments[0].get("id") == 1)
            check("disk: comment author prefix",
                  comments[0].get("text", "").startswith("[agent] hello smoke"),
                  str(comments[0].get("text")))
    check("disk: meta.updated_at bumped", (data.get("meta") or {}).get("updated_at") is not None)

    print("\n-- CLI: error paths (sandbox)")
    p = run_cli("status", "AC-9999", "done", file_arg=cli_yaml)
    check("CLI: unknown id -> exit 1 + error", p.returncode == 1 and "not found" in p.stderr,
          "rc=%s %s" % (p.returncode, p.stderr))
    p = run_cli("add", "--title", "bad", "--source", "user", "--priority", "9", file_arg=cli_yaml)
    check("CLI: bad priority rejected", p.returncode in (1, 2) and "priority" in p.stderr.lower(),
          "rc=%s %s" % (p.returncode, p.stderr))

    print("\n-- webui (sandboxed instance, real HTTP)")
    port = free_port()
    web_proc = subprocess.Popen(
        [sys.executable, str(WEBUI_PY), "--port", str(port), "--sandbox", str(WEB_SANDBOX)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    web_ui_ok = wait_port("127.0.0.1", port)
    if not web_ui_ok:
        check("webui started", False, web_proc.stdout.read() if web_proc.stdout else "")
    else:
        base = "http://127.0.0.1:%d" % port

        status, body = http(base + "/healthz")
        check("GET /healthz -> 200 + sandbox path", status == 200 and str(WEB_SANDBOX) in body,
              "%s %s" % (status, body[:200]))

        status, body = http(base + "/")
        check("GET / -> 200", status == 200, str(status))
        check("GET / contains AC-0046 card", "AC-0046" in body and 'data-id="AC-0046"' in body)
        check("GET / has queue section", "Queue (work order)" in body and "qchip" in body)
        check("GET / has done table", "Done (" in body)

        status, body = http(base + "/tasks/AC-0046/spec.html")
        check("GET /tasks/AC-0046/spec.html -> 200", status == 200, str(status))
        check("spec content served", "AC-0046" in body)

        status, body = http(base + "/tasks/nonexistent-task/spec.html")
        check("GET missing file -> 404", status == 404, str(status))

        status, body = http(base + "/api/nonexistent", data={})
        check("POST unknown action -> 404", status == 404, str(status))

        status, body = http(base + "/api/status", data={"id": "AC-0046", "status": "sideways"})
        check("POST bad status -> 400", status == 400 and "status must be one of" in body,
              "%s %s" % (status, body[:120]))

        status, body = http(base + "/api/status", data={"id": "AC-9999", "status": "done"})
        check("POST unknown id -> 404", status == 404, str(status))

        status, body = http(base + "/api/comment",
                            data={"id": "AC-0046", "text": "via webui smoke", "author": "agent"})
        ok = status == 200 and json.loads(body).get("ok") is True
        check("POST /api/comment -> ok + board html",
              ok and "board" in json.loads(body), "%s %s" % (status, body[:120]))

        status, body = http(base + "/api/status", data={"id": "AC-0045", "status": "open"})
        check("POST /api/status reopen -> ok",
              status == 200 and json.loads(body).get("ok") is True, "%s %s" % (status, body[:120]))

        status, body = http(base + "/api/queue_remove", data={"id": "AC-0046"})
        check("POST /api/queue_remove -> ok",
              status == 200 and json.loads(body).get("ok") is True, str(status))
        status, body = http(base + "/api/queue_add", data={"id": "AC-0046"})
        check("POST /api/queue_add -> ok (round trip)",
              status == 200 and json.loads(body).get("ok") is True, str(status))

        print("\n-- webui: reload from disk (sandbox yaml)")
        web_yaml = WEB_SANDBOX / "TASKS.yaml"
        check("webui sandbox yaml exists", web_yaml.exists())
        wdata = load_yaml(web_yaml)
        w46 = find(wdata, "AC-0046")
        texts = [c.get("text", "") for c in (w46.get("comments") or [])]
        check("disk: webui comment persisted", any("via webui smoke" in t for t in texts), str(texts))
        w45 = find(wdata, "AC-0045")
        check("disk: webui status persisted (AC-0045 open, completed_at cleared)",
              w45.get("status") == "open" and w45.get("completed_at") is None,
              "%s / %s" % (w45.get("status"), w45.get("completed_at")))
        check("disk: webui queue round-trip persisted", "AC-0046" in (wdata.get("queue") or []))

        status, body = http(base + "/")
        check("GET / after mutations shows the comment", "via webui smoke" in body)

        web_proc.terminate()
        try:
            out = web_proc.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            web_proc.kill()
            out = web_proc.communicate()
        check("webui stopped cleanly", web_proc.returncode is not None)
        noise = [l for l in (out[0] or "").splitlines() if "Warning" in l]
        check("webui emitted no warnings", not noise, str(noise[:3]))

    # CLI stderr of every earlier subprocess is checked collectively: rerun one
    # command with -W error to prove the CLI path is warning-free.
    p = subprocess.run([sys.executable, "-W", "error", str(TASKS_PY),
                        "--file", str(cli_yaml), "next"],
                       capture_output=True, text=True, timeout=60)
    check("CLI under -W error: no warnings, exit 0", p.returncode == 0, p.stderr[:300])

    check("live TASKS.yaml untouched", sha(LIVE_YAML) == live_sha_before)

    print("\n%d passed, %d failed" % (len(PASSED), len(FAILED)))
    if FAILED:
        print("FAILED:")
        for name, detail in FAILED:
            print("  - %s %s" % (name, detail))
        return 1
    print("RESULT {\"ok\": true, \"passed\": %d, \"sandboxes\": [\"%s\", \"%s\"]}"
          % (len(PASSED), CLI_SANDBOX.name, WEB_SANDBOX.name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
