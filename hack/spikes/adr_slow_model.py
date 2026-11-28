"""Stand-in in front of the stub model for the ADR spikes. Standard library only.

It records every chat request it gets (time, the last user text, finish time, status) and serves them at GET /events. A request whose
last user text holds SLOWRUN waits SLOW_SECONDS before it is forwarded, so a run takes long enough to watch. Everything is then sent
unchanged to the stub model (UPSTREAM, host:port). It holds no secret and logs no request header.
"""
import http.client
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UP = os.environ.get("UPSTREAM", "stub-model.agentgateway-system.svc.cluster.local:8080")
SLOW = float(os.environ.get("SLOW_SECONDS", "25"))
EV, LOCK = [], threading.Lock()


def last_user_text(req):
    for m in reversed(req.get("messages") or []):
        if m.get("role") == "user":
            c = m.get("content")
            if isinstance(c, list):
                c = " ".join(p.get("text", "") for p in c if isinstance(p, dict))
            return c or ""
    return ""


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/events":
            with LOCK:
                return self._send(200, json.dumps(EV).encode())
        self._send(200, b"ok", "text/plain")

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        try:
            req = json.loads(raw or b"{}")
        except ValueError:
            req = {}
        text = last_user_text(req)
        ev = {"t0": time.time(), "text": text[:300], "stream": bool(req.get("stream")), "t1": None, "status": None}
        with LOCK:
            EV.append(ev)
        if "SLOWRUN" in text:
            time.sleep(SLOW)
        try:
            c = http.client.HTTPConnection(UP, timeout=120)
            c.request("POST", self.path, raw, {"Content-Type": "application/json"})
            r = c.getresponse()
            body = r.read()
            ev["status"], ev["t1"] = r.status, time.time()
            self._send(r.status, body, r.getheader("Content-Type") or "application/json")
        except Exception as e:  # noqa: BLE001
            ev["status"], ev["t1"] = "error: %s" % e, time.time()
            self._send(502, b'{"error":"upstream"}')


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
