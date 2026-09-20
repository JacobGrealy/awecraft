#!/usr/bin/env python3
"""AC-0090 prototype server.

ES modules cannot be loaded over file://, so the prototype needs a static HTTP
server. This one serves the REPOSITORY ROOT (so the page is reachable at the
same URL the spec and the writeup quote) with no dependencies and a correct
MIME type for .js/.mjs.

    python3 prototypes/ac-0090-ragdoll/serve.py [port] [--host 0.0.0.0]

It binds 0.0.0.0 by default so the page is reachable from another machine on the
LAN; pass --host 127.0.0.1 to keep it local. The banner prints every URL it is
reachable on.
"""
import argparse
import functools
import http.server
import socket
import socketserver
import sys
from pathlib import Path

ROOT = str(Path(__file__).resolve().parents[2])
DEFAULT_PORT = 8177
DEFAULT_HOST = "0.0.0.0"
PATH = "/prototypes/ac-0090-ragdoll/"


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".js": "text/javascript",
        ".mjs": "text/javascript",
        ".json": "application/json",
        ".html": "text/html",
    }

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, fmt, *args):
        import os
        if os.environ.get("AC0090_VERBOSE"):
            super().log_message(fmt, *args)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def lan_addresses() -> list[str]:
    """Best-effort list of this machine's non-loopback IPv4 addresses.

    Uses the UDP-connect trick (no packets are sent) plus a hostname lookup so
    the banner lists the address a phone or laptop on the same network needs.
    """
    found: list[str] = []
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("192.168.0.1", 1))
            found.append(s.getsockname()[0])
        finally:
            s.close()
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip not in found and not ip.startswith("127."):
                found.append(ip)
    except OSError:
        pass
    return found


def main():
    ap = argparse.ArgumentParser(description="AC-0090 prototype static server")
    ap.add_argument("port", nargs="?", type=int, default=DEFAULT_PORT)
    ap.add_argument("--host", default=DEFAULT_HOST,
                    help="bind address (default 0.0.0.0 = LAN reachable)")
    args = ap.parse_args()

    handler = functools.partial(Handler, directory=ROOT)
    with Server((args.host, args.port), handler) as httpd:
        print(f"AC-0090 prototype — serving {ROOT}")
        print(f"  local:   http://127.0.0.1:{args.port}{PATH}")
        if args.host == "0.0.0.0":
            for ip in lan_addresses():
                print(f"  LAN:     http://{ip}:{args.port}{PATH}")
        else:
            print(f"  bound:   http://{args.host}:{args.port}{PATH}")
        print("  (ctrl-c to stop)")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nstopped")


if __name__ == "__main__":
    main()

