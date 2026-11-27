#!/usr/bin/env python3
"""A tiny MCP endpoint for the live check of mcp.endpoints (ADR 0026, slice 2). Test code for CI only; it is not a model of any real service.

Stateless streamable HTTP: POST /mcp carries one JSON-RPC message and gets one JSON answer. The header named by ECHO_HEADER (default Authorization) must hold
the value in the file ECHO_EXPECTED_FILE, else the answer is 401 and nothing else happens. The value is never logged. The log has one JSON line per request with
the path and who the presented header belongs to: "self" (this server's value), a label from ECHO_OTHER_FILES ("label=path,label=path"), "other" or "none".

ECHO_MODE=redirect: every POST answers ECHO_REDIRECT_CODE (default 307) with Location ECHO_REDIRECT_TO, before any check (a probe for what the gateway does with a
redirect and which headers it keeps).

Besides tools the server has a resource, a resource template, a prompt, completions, subscriptions and a log level, so that the live check can see which of these methods a
profile vMCP lets through. It cannot start a request of its own (sampling, elicitation): it answers one JSON message per POST.
"""
import hmac
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NAME = os.environ.get("ECHO_NAME", "echo")
MODE = os.environ.get("ECHO_MODE", "echo")
HEADER = os.environ.get("ECHO_HEADER", "Authorization")
TARGET = os.environ.get("ECHO_REDIRECT_TO", "")
REDIRECT_CODE = int(os.environ.get("ECHO_REDIRECT_CODE", "307"))


def read(path):
    with open(path) as f:
        return f.read().strip()


EXPECTED = read(os.environ["ECHO_EXPECTED_FILE"]) if os.environ.get("ECHO_EXPECTED_FILE") else ""
OTHERS = {}
for pair in filter(None, os.environ.get("ECHO_OTHER_FILES", "").split(",")):
    label, _, path = pair.partition("=")
    OTHERS[label] = read(path)

TOOLS = [
    {"name": "echo", "description": "Returns the text it is given.", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}},
    {"name": "list_notes", "description": "Lists the notes.", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "set_note", "description": "Writes a note (a write tool: a profile must not offer it unless it lists it).", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}},
]


def who(presented):
    if not presented:
        return "none"
    if EXPECTED and hmac.compare_digest(presented.encode(), EXPECTED.encode()):
        return "self"
    for label, value in OTHERS.items():
        if hmac.compare_digest(presented.encode(), value.encode()):
            return label
    return "other"


def log(**kw):
    print(json.dumps(kw), flush=True)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send(self, code, body=b"", headers=None):
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/healthz", "/readyz"):
            return self.send(200, b"ok")
        self.send(405, b"", {"Allow": "POST"})

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        presented = who(self.headers.get(HEADER, ""))
        log(event="request", server=NAME, path=self.path, header=HEADER, presented=presented)
        if MODE == "redirect":
            return self.send(REDIRECT_CODE, b"", {"Location": TARGET})
        if self.path != "/mcp":
            return self.send(404)
        if presented != "self":
            return self.send(401, b'{"error":"unauthorized"}', {"Content-Type": "application/json"})
        try:
            req = json.loads(raw or b"{}")
        except ValueError:
            return self.send(400)
        method, rid, params = req.get("method", ""), req.get("id"), req.get("params") or {}
        if rid is None:
            return self.send(202)
        result = None
        if method == "initialize":
            result = {"protocolVersion": params.get("protocolVersion", "2025-03-26"), "capabilities": {"tools": {"listChanged": False}, "resources": {"subscribe": True, "listChanged": True}, "prompts": {"listChanged": True}, "completions": {}, "logging": {}}, "serverInfo": {"name": NAME, "version": "ci"}}
        elif method == "ping":
            result = {}
        elif method == "tools/list":
            result = {"tools": TOOLS}
        elif method == "tools/call":
            tool, args = params.get("name"), params.get("arguments") or {}
            if tool == "echo":
                result = {"content": [{"type": "text", "text": "echo from %s: %s" % (NAME, args.get("text", ""))}]}
            elif tool in ("list_notes", "set_note"):
                result = {"content": [{"type": "text", "text": "%s ran on %s" % (tool, NAME)}]}
        elif method == "resources/list":
            result = {"resources": [{"uri": "echo://%s/note" % NAME, "name": "note of " + NAME}]}
        elif method == "resources/read":
            result = {"contents": [{"uri": params.get("uri", ""), "text": "the note of " + NAME}]}
        elif method == "resources/templates/list":
            result = {"resourceTemplates": [{"uriTemplate": "echo://%s/notes/{id}" % NAME, "name": "notes of " + NAME, "description": "a template of " + NAME}]}
        elif method == "completion/complete":
            result = {"completion": {"values": ["completion-of-" + NAME], "total": 1, "hasMore": False}}
        elif method in ("resources/subscribe", "resources/unsubscribe", "logging/setLevel"):
            result = {}
        elif method == "prompts/list":
            result = {"prompts": [{"name": "greet-" + NAME, "description": "a prompt of " + NAME}]}
        elif method == "prompts/get":
            result = {"messages": [{"role": "user", "content": {"type": "text", "text": "a prompt of " + NAME}}]}
        if result is None:
            body = {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "method not found"}}
        else:
            body = {"jsonrpc": "2.0", "id": rid, "result": result}
        self.send(200, json.dumps(body).encode(), {"Content-Type": "application/json"})


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
