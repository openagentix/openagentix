"""Stand-in MCP backend for the ToolHive diagnostics spike (issue #230, ADR 0025 slice 2). Standard library only.

One process serves many backends: the URL path (/mcp/<name>) picks the tool set. It speaks streamable HTTP with JSON answers
(no sessions, no SSE). It records what the caller sent, so the spike can see what ToolHive forwards:

  whoami   returns, for every request header, its length and SHA-256 (and the value for headers that cannot hold a credential)
  ping     returns "pong"
  pods_list  a pretend diagnostic tool; its result holds a canary (RESULT_CANARY) and it echoes the argument "namespace" back only as a length

It logs one line per request: path, JSON-RPC method, SHA-256 prefix of Authorization (or "none"), and the names of all headers.
It never logs a header value other than the ones named in LOG_VALUE_HEADERS.
"""
import hashlib
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RESULT_CANARY = os.environ.get("RESULT_CANARY", "RESULT-CANARY-UNSET")
SENSITIVE = {"authorization", "cookie", "proxy-authorization"}
LOG_VALUE_HEADERS = {"x-caller-id"}


def sha(v):
    return hashlib.sha256(v.encode()).hexdigest()


def tool(name, desc, props=None):
    return {"name": name, "description": desc,
            "inputSchema": {"type": "object", "properties": props or {}, "additionalProperties": True}}


TOOLS = {
    "ok": [tool("ping", "returns pong"), tool("whoami", "reports the headers this backend received"),
           ],
    "dg": [tool("pods_list", "pretend diagnostic tool: lists pods", {"namespace": {"type": "string"}}), tool("whoami", "reports the headers this backend received")],
}


def tools_for(path):
    name = path.rstrip("/").split("/")[-1]
    if name.startswith("dg"):
        return TOOLS["dg"]
    if name.startswith("ok"):
        return TOOLS["ok"]
    return [tool("whoami", "reports the headers this backend received"), tool("ping", "returns pong")]


def call(path, name, args, headers):
    if name == "ping":
        return "pong"
    if name == "pods_list":
        return "%s pod-a Running (namespace length %d)" % (RESULT_CANARY, len(str((args or {}).get("namespace", ""))))
    if name == "whoami":
        out = {}
        for k, v in headers.items():
            e = {"len": len(v), "sha256": sha(v)}
            if k.lower() not in SENSITIVE:
                e["value"] = v
            out[k.lower()] = e
        return json.dumps({"path": path, "headers": out}, sort_keys=True)
    return None


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # replaced by our own line
        pass

    def _send(self, code, body=b"", ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/healthz", "/"):
            return self._send(200, b"ok", "text/plain")
        self._send(405)

    def do_DELETE(self):
        self._send(200)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            req = json.loads(raw or b"{}")
        except ValueError:
            return self._send(400)
        method = req.get("method", "")
        hdrs = {k: v for k, v in self.headers.items()}
        auth = hdrs.get("Authorization")
        extra = " ".join("%s=%s" % (k.lower(), v) for k, v in hdrs.items() if k.lower() in LOG_VALUE_HEADERS)
        print("REQ path=%s rpc=%s authz=%s headers=%s %s" % (
            self.path, method, sha(auth)[:12] if auth else "none", ",".join(sorted(k.lower() for k in hdrs)), extra), flush=True)
        rid = req.get("id")
        if rid is None:  # a notification
            return self._send(202)
        res = None
        if method == "initialize":
            res = {"protocolVersion": (req.get("params") or {}).get("protocolVersion", "2025-03-26"),
                   "capabilities": {"tools": {"listChanged": False}}, "serverInfo": {"name": "spike-stub", "version": "0"}}
        elif method == "ping":
            res = {}
        elif method == "tools/list":
            res = {"tools": tools_for(self.path)}
        elif method == "tools/call":
            p = req.get("params") or {}
            text = call(self.path, p.get("name", ""), p.get("arguments"), hdrs)
            if text is None:
                return self._send(200, json.dumps({"jsonrpc": "2.0", "id": rid,
                                                   "error": {"code": -32602, "message": "unknown tool"}}).encode())
            res = {"content": [{"type": "text", "text": text}], "isError": False}
        else:
            return self._send(200, json.dumps({"jsonrpc": "2.0", "id": rid,
                                               "error": {"code": -32601, "message": "method not found"}}).encode())
        self._send(200, json.dumps({"jsonrpc": "2.0", "id": rid, "result": res}).encode())


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    print("spike backend on :%d" % port, flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()
