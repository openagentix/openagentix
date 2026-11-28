"""Recording stand-in between the A2A gate and the kagent controller, for the live check of event callers (ADR 0027, hack/ci/event-live.sh).
Standard library only. It runs as a second container of the gate pod, so the gate's own NetworkPolicy and its path to the controller apply to it.

The gate sends its requests to 127.0.0.1:18083 (A2A_GATE_UPSTREAM is patched by the live script). This process writes down every request exactly as it
arrived (method, path, header names and values, body bytes) and passes it on to the controller unchanged, then returns the controller's answer. The
records are served on 127.0.0.1:18084: GET /records, POST /reset. A header that can carry a credential (Authorization, Cookie) is recorded by name only.
It holds no secret and logs nothing.
"""
import http.client
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UP = os.environ.get("UPSTREAM", "kagent-controller.kagent.svc.cluster.local:8083")
REC, LOCK = [], threading.Lock()
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers", "transfer-encoding", "upgrade", "host", "content-length"}
SECRET = {"authorization", "cookie", "proxy-authorization"}


class Proxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _go(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        hdrs = {}
        for k in self.headers.keys():
            hdrs.setdefault(k, []).extend(self.headers.get_all(k))
        shown = {k: (["<present>"] if k.lower() in SECRET else v) for k, v in hdrs.items()}
        with LOCK:
            REC.append({"method": self.command, "path": self.path, "headers": shown, "body": body.decode("utf-8", "replace"), "length": len(body)})
        fwd = {k: v[0] for k, v in hdrs.items() if k.lower() not in HOP}
        try:
            c = http.client.HTTPConnection(UP, timeout=120)
            c.request(self.command, self.path, body or None, fwd)
            r = c.getresponse()
            data = r.read()
            self.send_response(r.status)
            for k, v in r.getheaders():
                if k.lower() not in HOP:
                    self.send_header(k, v)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception:  # noqa: BLE001
            b = b'{"error":"upstream"}'
            self.send_response(502)
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)

    do_GET = do_POST = do_PUT = do_DELETE = _go


class Records(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, b):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        with LOCK:
            self._send(json.dumps(REC).encode())

    def do_POST(self):
        with LOCK:
            REC.clear()
        self._send(b"{}")


if __name__ == "__main__":
    threading.Thread(target=ThreadingHTTPServer(("127.0.0.1", 18084), Records).serve_forever, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", 18083), Proxy).serve_forever()
