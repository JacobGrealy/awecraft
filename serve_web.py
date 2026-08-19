#!/usr/bin/env python3
"""Static file server for the AweCraft web build, with daemon mode.

Usage:
  python3 serve_web.py [--ssl] [--daemon] [--replace]

  --ssl      serve https on 0.0.0.0:8443 using web/ssl/cert.pem + key.pem
  (without)  serve http  on 0.0.0.0:8140
  --daemon   fully detach (double fork + setsid); prints the daemon pid.
             Daemon writes .scratch/serve_web.pid, logs to
             .scratch/awecraft-web-{https,http}.log, survives session ends.
  --replace  if a serve_web.py already holds the target port, kill that pid
             (only that pid) and start a new one.

Without --replace, if a live serve_web.py already holds the port the script
prints "already running (pid X, port Y)" and exits 0. If a non-serve_web
process holds the port it is reported and the script exits 1 (left untouched).
Stdlib only.
"""
import datetime
import gzip
import io
import os
import signal
import socket
import ssl
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "0.0.0.0"
PORT = 8140
SSL_PORT = 8443
ROOT_DIR = os.path.dirname(os.path.abspath(__file__))
WEB_DIR = os.path.join(ROOT_DIR, "web")
SSL_DIR = os.path.join(WEB_DIR, "ssl")
SCRATCH_DIR = os.path.join(ROOT_DIR, ".scratch")
PIDFILE = os.path.join(SCRATCH_DIR, "serve_web.pid")

CONTENT_TYPES = {
    ".wasm": "application/wasm",
    ".js": "application/javascript",
    ".html": "text/html; charset=utf-8",
    ".pck": "application/octet-stream",
    ".json": "application/json",
    ".map": "application/json",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".svg": "image/svg+xml",
    ".gif": "image/gif",
    ".ico": "image/x-icon",
    ".css": "text/css; charset=utf-8",
    ".mp3": "audio/mpeg",
    ".ogg": "application/ogg",
    ".wav": "audio/wav",
    ".woff": "font/woff",
    ".woff2": "font/woff2",
    ".txt": "text/plain; charset=utf-8",
}

GZIP_EXTS = {".wasm", ".js", ".html", ".pck"}


def lan_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return "192.168.0.224"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        self._send(True)

    def do_HEAD(self):
        self._send(False)

    def _send(self, send_body):
        url_path = self.path.split("?", 1)[0].split("#", 1)[0]
        if url_path in ("", "/"):
            url_path = "/index.html"
        rel = os.path.normpath(url_path.lstrip("/"))
        full = os.path.abspath(os.path.join(WEB_DIR, rel))
        if not full.startswith(os.path.abspath(WEB_DIR) + os.sep):
            self.send_error(403, "forbidden")
            return
        if not os.path.isfile(full):
            self.send_error(404, "not found")
            return
        with open(full, "rb") as f:
            body = f.read()
        ext = os.path.splitext(full)[1].lower()
        ctype = CONTENT_TYPES.get(ext, "application/octet-stream")
        accept = self.headers.get("Accept-Encoding", "")
        do_gzip = ext in GZIP_EXTS and "gzip" in accept
        if do_gzip:
            buf = io.BytesIO()
            gz = gzip.GzipFile(fileobj=buf, mode="wb", compresslevel=9)
            gz.write(body)
            gz.close()
            body = buf.getvalue()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        if do_gzip:
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Vary", "Accept-Encoding")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if send_body:
            self.wfile.write(body)


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


def _is_serve_web(pid):
    return "serve_web.py" in _cmdline(pid)


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
        os.remove(PIDFILE)
    except OSError:
        pass


def find_running(port):
    """pid of a live serve_web.py actually listening on `port`, else None."""
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
        if _alive(pid) and _is_serve_web(pid) and _holds_port(pid, port):
            return pid
    return None


def port_holder(port):
    """pid holding `port` when it is not a serve_web.py instance, else None."""
    pids = sorted(_pids_with_inode(_port_inodes(port)))
    return pids[0] if pids else None


def kill_serve_web(pid, port, timeout=10.0):
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


# ----------------------------------------------------------------------- serve

def serve(use_ssl):
    def _cleanup(signum, frame):
        _clear_pidfile()
        os._exit(0)

    signal.signal(signal.SIGTERM, _cleanup)
    signal.signal(signal.SIGINT, _cleanup)

    if use_ssl:
        httpd = ThreadingHTTPServer((HOST, SSL_PORT), Handler)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(
            os.path.join(SSL_DIR, "cert.pem"),
            os.path.join(SSL_DIR, "key.pem"),
        )
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
        print("https://localhost:%d/" % SSL_PORT, flush=True)
        print("https://%s:%d/" % (lan_ip(), SSL_PORT), flush=True)
    else:
        httpd = ThreadingHTTPServer((HOST, PORT), Handler)
        print("http://localhost:%d/" % PORT, flush=True)
        print("http://%s:%d/" % (lan_ip(), PORT), flush=True)
    httpd.serve_forever()


# ------------------------------------------------------------------- daemonize

def start_daemon(port, log_path):
    """Double-fork the server; return the daemon pid, or None on failure."""
    _clear_pidfile()
    use_ssl = port == SSL_PORT

    pid = os.fork()
    if pid > 0:
        # original parent: first child exits right after the second fork;
        # the daemon writes its pid to PIDFILE after re-parenting
        os.waitpid(pid, 0)
        deadline = time.time() + 10.0
        while time.time() < deadline:
            daemon_pid = _read_pidfile()
            if (
                daemon_pid is not None
                and daemon_pid != pid
                and _alive(daemon_pid)
                and _is_serve_web(daemon_pid)
            ):
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
    logfd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    os.dup2(devnull, 0)
    os.dup2(logfd, 1)
    os.dup2(logfd, 2)
    if devnull > 2:
        os.close(devnull)
    if logfd > 2:
        os.close(logfd)

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    sys.stdout.write(
        "==== %s serve_web.py start pid=%d %s port=%d ====\n"
        % (stamp, os.getpid(), "https" if use_ssl else "http", port)
    )
    sys.stdout.flush()
    with open(PIDFILE, "w") as fh:
        fh.write("%d\n" % os.getpid())
    serve(use_ssl)


def main():
    argv = sys.argv[1:]
    use_ssl = "--ssl" in argv
    do_daemon = "--daemon" in argv
    do_replace = "--replace" in argv
    port = SSL_PORT if use_ssl else PORT
    log_path = os.path.join(
        SCRATCH_DIR, "awecraft-web-https.log" if use_ssl else "awecraft-web-http.log"
    )
    os.makedirs(SCRATCH_DIR, exist_ok=True)

    running = find_running(port)
    if running is not None:
        if do_replace:
            print("replacing serve_web.py (pid %d, port %d)" % (running, port), flush=True)
            kill_serve_web(running, port)
        else:
            print("already running (pid %d, port %d)" % (running, port), flush=True)
            sys.exit(0)
    else:
        holder = port_holder(port)
        if holder is not None:
            print(
                "port %d is already in use by pid %d (not serve_web.py); refusing to start"
                % (port, holder),
                file=sys.stderr,
                flush=True,
            )
            sys.exit(1)

    if do_daemon:
        daemon_pid = start_daemon(port, log_path)
        if daemon_pid is None:
            print("daemon failed to start; see %s" % log_path, file=sys.stderr, flush=True)
            sys.exit(1)
        print("daemon pid: %d" % daemon_pid, flush=True)
        print("log: %s" % log_path, flush=True)
        sys.exit(0)

    try:
        serve(use_ssl)
    except OSError as exc:
        print("failed to start server on %s:%d: %s" % (HOST, port, exc), file=sys.stderr, flush=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
