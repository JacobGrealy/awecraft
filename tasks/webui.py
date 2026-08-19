#!/usr/bin/env python3
"""AweCraft task board server (stdlib only, loopback-only).

Canonical start:
    python3 tasks/webui.py                      http://127.0.0.1:5180/

Flags:
    --port N        listen port (default 5180)
    --sandbox DIR   copy tasks/TASKS.yaml into DIR first and work against the
                    copy (per the jarvis sandbox pattern: try the board or
                    reproduce a bug without any write reaching the real YAML).
                    The per-task FOLDERS (spec/results/PNGs) stay served from
                    the real tasks/ dir - sandboxing redirects the registry,
                    not the read-only artifact store.

Design (mirrors the user's work webapp):
  * YAML is the source of truth; every request loads it fresh, no cache.
  * The server binds 127.0.0.1 only - single user, no auth, never expose it.
  * Edits (add/status/comment/queue) go through tasks_lib - the SAME mutation
    layer as the CLI - and re-render through scripts/render.py, so the webui
    and the CLI can never disagree about the data or the layout.
  * Mutations return the freshly rendered board; the page swaps it in place.
"""

import argparse
import json
import mimetypes
import shutil
import socket
import sys
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

HOST = "127.0.0.1"
DEFAULT_PORT = 5180

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
    # Single-user loopback tool: keep the logs quiet (one line per request).
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


def main():
    parser = argparse.ArgumentParser(description="AweCraft task board (loopback-only)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--sandbox", default=None,
                        help="dir to hold a copy of TASKS.yaml (writes never touch the real one)")
    args = parser.parse_args()

    if args.sandbox:
        _prepare_sandbox(args.sandbox)

    try:
        server = ThreadingHTTPServer((HOST, args.port), Handler)
    except OSError as exc:
        print("cannot bind %s:%d - %s (is another instance running?)" % (HOST, args.port, exc),
              file=sys.stderr)
        return 1

    banner = ["task board: http://%s:%d/  (loopback-only, no auth)" % (HOST, args.port),
              "registry:   %s" % STATE["yaml_path"],
              "task files: %s" % STATE["static_root"]]
    if STATE["sandbox"]:
        banner.append("SANDBOX:    writes go to the copy above, never the live TASKS.yaml")
    print("\n".join(banner))
    server.daemon_threads = True
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
