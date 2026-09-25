#!/usr/bin/env python3
"""Stand-in for api.github.com + codeload.github.com, for the updater e2e test.

    fake_github.py <port> <certfile> <keyfile> <sha> <zipfile>

Serves, over HTTPS:
  /repos/<owner>/<repo>/commits/main  -> {"sha": <sha>, "commit": {...}}
  /zip/<sha>                          -> <zipfile>
"""
import http.server
import json
import ssl
import sys

port, certfile, keyfile, sha, zipfile = sys.argv[1:6]


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.endswith("/commits/main"):
            body = json.dumps({
                "sha": sha,
                "commit": {
                    "message": "E2E test build\n\nlonger description",
                    "committer": {"date": "2026-09-25T10:00:00Z"},
                },
            }).encode()
            self._send(200, body, "application/json")
        elif self.path == "/zip/" + sha:
            with open(zipfile, "rb") as f:
                self._send(200, f.read(), "application/zip")
        else:
            self._send(404, b"not found", "text/plain")

    def log_message(self, fmt, *args):
        sys.stderr.write("fake_github: " + fmt % args + "\n")


ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(certfile, keyfile)
srv = http.server.ThreadingHTTPServer(("0.0.0.0", int(port)), Handler)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
