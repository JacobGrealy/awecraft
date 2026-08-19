#!/usr/bin/env python3
"""AweCraft task board server (stdlib only, LAN-reachable, no auth).

Canonical start (daemon; detached, survives opencode restarts):
    python3 tasks/webui.py --daemon          http://<lan-ip>:5180/

Flags:
    --port N        listen port (default 5180). Binds 0.0.0.0 (LAN, no auth -
                     explicit user request 2026-08-19: the board must be
                     reachable from the network, not just localhost).
    --sandbox DIR   copy tasks/TASKS.yaml into DIR first and work against the
                     copy (per the jarvis sandbox pattern: try the board or
                     reproduce a bug without any write reaching the real YAML).
                     The per-task FOLDERS (spec/results/PNGs) stay served from
                     the real tasks/ dir - sandboxing redirects the registry,
                     not the read-only artifact store.
    --daemon        fully detach (double fork + setsid, own session); writes
                     .scratch/tasks_webui.pid, appends to
                     .scratch/tasks-webui.log with a start marker, prints the
                     daemon pid.
    --replace       if a tasks/webui.py already holds the port, kill that pid
                     (only that pid) and start a new one.

Without --replace, if a live tasks/webui.py already holds the port the script
prints "already running (pid X, port Y)" and exits 0. If a non-webui process
holds the port it is reported and the script exits 1 (left untouched).

Design (mirrors the user's work webapp):
  * YAML is the source of truth; every request loads it fresh, no cache.
  * Edits (add/status/comment/queue) go through tasks_lib - the SAME mutation
    layer as the CLI - and re-render through scripts/render.py, so the webui
    and the CLI can never disagree about the data or the layout.
  * Mutations return the freshly rendered board; the page swaps it in place.
"""

import argparse
import datetime
import json
import mimetypes
import os
import shutil
import signal
import subprocess
import sys
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

WEBUI_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = WEBUI_DIR / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))
import render  # noqa: E402
import tasks_lib  # noqa: E402
from tasks_lib import NotFound, TaskError  # noqa: E402

HOST = "0.0.0.0"
DEFAULT_PORT = 5180
SCRATCH_DIR = WEBUI_DIR.parent / ".scratch"
PIDFILE = SCRATCH_DIR / "tasks_webui.pid"
LOG_PATH = SCRATCH_DIR / "tasks-webui.log"

# Set in main() when --sandbox is given.
STATE = {
    "yaml_path": tasks_lib.TASKS_PATH,
    "static_root": WEBUI_DIR,
    "sandbox": None,
}


def _prepare_sandbox(sandbox_dir):
    """Copy the real registry into the sandbox dir (jarvis pattern)."""
    sandbox = Path(sandbox_dir).expanduser()
    sandbox.mkdir(parents=True, exist_ok=True)
    live = WEBUI_DIR / "TASKS.yaml"
    target = sandbox / "TASKS.yaml"
    if not target.exists():
        shutil.copy(live, target)
    STATE["yaml_path"] = target
    STATE["sandbox"] = str(target)


def _board(todos=None):
    return render.build_board(todos, interactive=True, base="/tasks/",
                              task_root=STATE["static_root"])


def _page(todos=None):
    return render.render_page(todos, interactive=True, base="/tasks/",
                              task_root=STATE["static_root"], title="AweCraft Tasks")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    # ------------------------------------------------------------------ GET
    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")
        if path in ("", "/"):
            try:
                body = _page(tasks_lib.load_tasks(STATE["yaml_path"]))
            except Exception:
                self._send(500, "application/json",
                           json.dumps({"ok": False, "error": "registry failed to load"}))
                traceback.print_exc()
                return
            self._send(200, "text/html; charset=utf-8", body)
        elif path == "/healthz":
            self._send(200, "application/json", json.dumps({"ok": True,
                            "yaml": str(STATE["yaml_path"])}, indent=0))
        elif path.startswith("/tasks/"):
            self._serve_static(path[len("/tasks/"):])
        else:
            self._send(404, "text/plain", "Not found")

    # ----------------------------------------------------------------- POST
    def do_POST(self):
        parsed = urlparse(self.path)
        if not parsed.path.startswith("/api/"):
            self._send(404, "text/plain", "Not found")
            return
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        form = {k: v[-1] for k, v in parse_qs(raw.decode("utf-8")).items()}
        action = parsed.path[len("/api/"):]
        handler_name = "_api_" + action.replace("-", "_")
        handler = getattr(self, handler_name, None)
        if handler is None:
            self._send(404, "application/json",
                       json.dumps({"ok": False, "error": "unknown action %r" % action}))
            return
        try:
            handler(form)
        except NotFound as exc:
            self._send(404, "application/json", json.dumps({"ok": False, "error": str(exc)}))
        except TaskError as exc:
            self._send(400, "application/json", json.dumps({"ok": False, "error": str(exc)}))
        except Exception:
            traceback.print_exc()
            self._send(500, "application/json",
                       json.dumps({"ok": False, "error": "internal error, see server log"}))

    # ---- api actions (each: load -> mutate via tasks_lib -> save -> re-render)
    def _persist(self, todos):
        tasks_lib.save_tasks(todos, STATE["yaml_path"])
        return {"ok": True, "board": _board(todos)}

    def _api_add(self, form):
        todos = tasks_lib.load_tasks(STATE["yaml_path"])
        item = tasks_lib.add(todos, form.get("title", ""), form.get("source", "agent"),
                             form.get("priority", 2), form.get("notes", ""))
        body = self._persist(todos)
        body["id"] = item["id"]
        body["message"] = "Added %s" % item["id"]
        self._send(200, "application/json", json.dumps(body))

    def _api_status(self, form):
        todos = tasks_lib.load_tasks(STATE["yaml_path"])
        item = tasks_lib.set_status(todos, form.get("id", ""), form.get("status", ""))
        body = self._persist(todos)
        body["message"] = "%s -> %s" % (item["id"], item["status"])
        self._send(200, "application/json", json.dumps(body))

    def _api_comment(self, form):
        todos = tasks_lib.load_tasks(STATE["yaml_path"])
        author = form.get("author") or None
        comment = tasks_lib.add_comment(todos, form.get("id", ""), form.get("text", ""), author)
        body = self._persist(todos)
        body["message"] = "Comment %d added to %s" % (comment["id"], form.get("id"))
        self._send(200, "application/json", json.dumps(body))

    def _api_queue_add(self, form):
        todos = tasks_lib.load_tasks(STATE["yaml_path"])
        changed = tasks_lib.queue_add(todos, form.get("id", ""))
        body = self._persist(todos)
        body["message"] = "%s" % ("Queued" if changed else "Already queued")
        self._send(200, "application/json", json.dumps(body))

    def _api_queue_remove(self, form):
        todos = tasks_lib.load_tasks(STATE["yaml_path"])
        changed = tasks_lib.queue_remove(todos, form.get("id", ""))
        body = self._persist(todos)
        body["message"] = "%s" % ("Unqueued" if changed else "Not in queue")
        self._send(200, "application/json", json.dumps(body))

    # ------------------------------------------------------------- helpers
    def _serve_static(self, rel):
        """Serve a file under the task folder store (real tasks/ dir)."""
        rel = rel.replace("%2f", "/")
        target = (STATE["static_root"] / rel).resolve()
        root = STATE["static_root"].resolve()
        if root not in target.parents and target != root:
            self._send(403, "text/plain", "Forbidden")
            return
        if not target.is_file():
            self._send(404, "text/plain", "Not found")
            return
        ctype = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
        if ctype.startswith("text/") or ctype in ("application/json", "image/svg+xml"):
            ctype += "; charset=utf-8"
        self._send(200, ctype, target.read_bytes())

    def _send(self, status, ctype, body):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)


# ---------------------------------------------------------------- process info

def _alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True  # exists but not ours to signal
    return True


def _cmdline(pid):
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as fh:
            return fh.read().replace(b"\0", b" ").decode("utf-8", "replace")
    except OSError:
        return ""


def _is_webui(pid):
    return "webui.py" in _cmdline(pid)


def _port_inodes(port):
    """socket inodes of sockets LISTENing on `port` (Linux /proc)."""
    inodes = set()
    for path in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            with open(path) as fh:
                lines = fh.readlines()
        except OSError:
            continue
        for line in lines[1:]:
            parts = line.split()
            if len(parts) < 10 or parts[3] != "0A":  # 0A == LISTEN
                continue
            try:
                lport = int(parts[1].rsplit(":", 1)[1], 16)
            except (IndexError, ValueError):
                continue
            if lport == port:
                inodes.add(parts[9])
    return inodes


def _pids_with_inode(inodes):
    pids = set()
    if not inodes:
        return pids
    try:
        entries = os.listdir("/proc")
    except OSError:
        return pids
    for entry in entries:
        if not entry.isdigit():
            continue
        fd_dir = os.path.join("/proc", entry, "fd")
        try:
            fds = os.listdir(fd_dir)
        except OSError:
            continue
        for fd in fds:
            try:
                link = os.readlink(os.path.join(fd_dir, fd))
            except OSError:
                continue
            if link.startswith("socket:[") and link[8:-1] in inodes:
                pids.add(int(entry))
                break
    return pids


def _holds_port(pid, port):
    inodes = _port_inodes(port)
    if not inodes:
        return False
    fd_dir = "/proc/%d/fd" % pid
    try:
        fds = os.listdir(fd_dir)
    except OSError:
        return False
    for fd in fds:
        try:
            link = os.readlink(os.path.join(fd_dir, fd))
        except OSError:
            continue
        if link.startswith("socket:[") and link[8:-1] in inodes:
            return True
    return False


# ------------------------------------------------------------- pidfile + guard

def _read_pidfile():
    try:
        with open(PIDFILE) as fh:
            text = fh.read().strip()
    except OSError:
        return None  # missing / unreadable -> stale, treat as none
    try:
        pid = int(text)
    except ValueError:
        return None  # corrupt -> stale
    return pid if pid > 0 else None


def _clear_pidfile():
    try:
        PIDFILE.unlink()
    except OSError:
        pass


def find_running(port):
    """pid of a live tasks/webui.py actually listening on `port`, else None."""
    candidates = []
    pid = _read_pidfile()
    if pid is not None:
        candidates.append(pid)
    candidates.extend(sorted(_pids_with_inode(_port_inodes(port))))
    seen = set()
    for pid in candidates:
        if pid in seen:
            continue
        seen.add(pid)
        if _alive(pid) and _is_webui(pid) and _holds_port(pid, port):
            return pid
    return None


def port_holder(port):
    """pid holding `port` (used for the foreign-holder refusal)."""
    pids = sorted(_pids_with_inode(_port_inodes(port)))
    return pids[0] if pids else None


def kill_webui(pid, port, timeout=10.0):
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    deadline = time.time() + timeout
    while _alive(pid) and time.time() < deadline:
        time.sleep(0.1)
    if _alive(pid):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        deadline = time.time() + timeout
        while _alive(pid) and time.time() < deadline:
            time.sleep(0.1)
    deadline = time.time() + timeout
    while _port_inodes(port) and time.time() < deadline:
        time.sleep(0.1)


def lan_ip():
    """Best-effort non-loopback IPv4 address of this machine (None if unknown)."""
    try:
        out = subprocess.check_output(["ip", "-4", "-o", "addr", "show"],
                                      text=True, timeout=5)
    except (OSError, subprocess.CalledProcessError):
        return None
    for line in out.splitlines():
        parts = line.split()
        # ip -o addr format: <ifidx>: <iface> inet <addr>/<cidr> <brd> scope ...
        if len(parts) >= 4 and parts[2] == "inet" and parts[1] != "lo":
            ip = parts[3].split("/")[0]
            if ip != "127.0.0.1":
                return ip
    return None


# ----------------------------------------------------------------------- serve

def serve(port):
    def _cleanup(signum, frame):
        _clear_pidfile()
        os._exit(0)

    signal.signal(signal.SIGTERM, _cleanup)
    signal.signal(signal.SIGINT, _cleanup)

    try:
        server = ThreadingHTTPServer((HOST, port), Handler)
    except OSError as exc:
        print("cannot bind %s:%d - %s (is another instance running?)" % (HOST, port, exc),
              file=sys.stderr, flush=True)
        sys.exit(1)

    lines = ["task board: http://localhost:%d/  (all interfaces, no auth)" % port]
    ip = lan_ip()
    if ip:
        lines.append("          http://%s:%d/  (LAN)" % (ip, port))
    lines.append("registry:   %s" % STATE["yaml_path"])
    lines.append("task files: %s" % STATE["static_root"])
    if STATE["sandbox"]:
        lines.append("SANDBOX:    writes go to the copy above, never the live TASKS.yaml")
    print("\n".join(lines), flush=True)
    server.daemon_threads = True
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


# ------------------------------------------------------------------- daemonize

def start_daemon(port, log_path):
    """Double-fork the server; return the daemon pid, or None on failure."""
    _clear_pidfile()

    pid = os.fork()
    if pid > 0:
        # original parent: first child exits right after the second fork;
        # the daemon writes its pid to PIDFILE after re-parenting. The parent
        # only reports a pid that is alive, is a webui, AND actually holds
        # the port, so a bind failure in the grandchild reads as "failed".
        os.waitpid(pid, 0)
        deadline = time.time() + 10.0
        while time.time() < deadline:
            daemon_pid = _read_pidfile()
            if (daemon_pid is not None
                    and daemon_pid != pid
                    and _alive(daemon_pid)
                    and _is_webui(daemon_pid)
                    and _holds_port(daemon_pid, port)):
                return daemon_pid
            time.sleep(0.05)
        return None

    # first child: fork again so the daemon can never reacquire a
    # controlling terminal
    intermediate = os.fork()
    if intermediate > 0:
        os._exit(0)

    # final daemon (grandchild): become session leader, stdio from
    # /dev/null to the log file (append)
    os.setsid()
    devnull = os.open(os.devnull, os.O_RDONLY)
    logfd = os.open(str(log_path), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    os.dup2(devnull, 0)
    os.dup2(logfd, 1)
    os.dup2(logfd, 2)
    if devnull > 2:
        os.close(devnull)
    if logfd > 2:
        os.close(logfd)

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    sys.stdout.write("==== %s tasks/webui.py start pid=%d port=%d ====\n"
                     % (stamp, os.getpid(), port))
    sys.stdout.flush()
    with open(PIDFILE, "w") as fh:
        fh.write("%d\n" % os.getpid())
    serve(port)


# ------------------------------------------------------------------------ main

def main():
    parser = argparse.ArgumentParser(description="AweCraft task board (LAN, no auth)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--sandbox", default=None,
                        help="dir to hold a copy of TASKS.yaml (writes never touch the real one)")
    parser.add_argument("--daemon", action="store_true",
                        help="fully detach (double fork + setsid); prints the daemon pid")
    parser.add_argument("--replace", action="store_true",
                        help="kill an existing webui holding the port first (only that pid)")
    args = parser.parse_args()

    if args.sandbox:
        _prepare_sandbox(args.sandbox)

    SCRATCH_DIR.mkdir(parents=True, exist_ok=True)

    running = find_running(args.port)
    if running is not None:
        if args.replace:
            print("replacing tasks/webui.py (pid %d, port %d)" % (running, args.port), flush=True)
            kill_webui(running, args.port)
        else:
            print("already running (pid %d, port %d)" % (running, args.port), flush=True)
            return 0
    else:
        holder = port_holder(args.port)
        if holder is not None:
            print("port %d is already in use by pid %d (not webui.py); refusing to start"
                  % (args.port, holder), file=sys.stderr, flush=True)
            return 1

    if args.daemon:
        daemon_pid = start_daemon(args.port, LOG_PATH)
        if daemon_pid is None:
            print("daemon failed to start; see %s" % LOG_PATH, file=sys.stderr, flush=True)
            return 1
        print("daemon pid: %d" % daemon_pid, flush=True)
        print("log: %s" % LOG_PATH, flush=True)
        return 0

    serve(args.port)
    return 0


if __name__ == "__main__":
    sys.exit(main())
