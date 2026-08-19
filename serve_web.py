#!/usr/bin/env python3
import gzip
import io
import os
import socket
import ssl
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "0.0.0.0"
PORT = 8140
SSL_PORT = 8443
WEB_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")
SSL_DIR = os.path.join(WEB_DIR, "ssl")

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


def main():
    if "--ssl" in sys.argv[1:]:
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


if __name__ == "__main__":
    main()
