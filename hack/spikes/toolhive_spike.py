"""Checks for the ToolHive diagnostics spike (issue #230, ADR 0025 slice 2). Standard library only; run with `python3 -I`.

  toolhive_spike.py jwks <key.pem> <kid>            print a JWKS for the RSA key
  toolhive_spike.py run                             run every check against the cluster in the current kube context

`run` reads its settings from the environment (set by hack/spikes/toolhive-diagnostics-spike.sh):
  SPIKE_NS, SPIKE_KEY (RSA private key PEM), SPIKE_KID, SPIKE_ISSUER, SPIKE_AUDIENCE, SPIKE_HDR_VALUE_FILE (the injected Authorization
  value, "Bearer <hex>"), SPIKE_HDR_RAW_FILE (the hex part alone), SPIKE_RESULT_CANARY, SPIKE_REQUEST_CANARY, SPIKE_OUT (output directory).
Every check records a verdict (PASS, FAIL, INCONCLUSIVE or INFO) and evidence. A check that raises is recorded as ERROR, never as PASS.
Nothing here prints the injected header value.
"""
import base64
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

NS = os.environ.get("SPIKE_NS", "spike-mcp")


def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def sha(s):
    return hashlib.sha256(s.encode()).hexdigest()


# ---------------------------------------------------------------- JWT and JWKS (openssl does the RSA)
def jwks(keyfile, kid):
    out = subprocess.run(["openssl", "rsa", "-in", keyfile, "-noout", "-modulus"], capture_output=True, text=True, check=True).stdout
    n = bytes.fromhex(out.strip().split("=", 1)[1])
    return {"keys": [{"kty": "RSA", "use": "sig", "alg": "RS256", "kid": kid, "n": b64u(n), "e": "AQAB"}]}


def make_jwt(keyfile, kid, iss, aud, sub, extra=None):
    now = int(time.time())
    claims = {"iss": iss, "aud": aud, "sub": sub, "iat": now, "nbf": now - 5, "exp": now + 3000}
    claims.update(extra or {})
    head = b64u(json.dumps({"alg": "RS256", "typ": "JWT", "kid": kid}).encode())
    body = b64u(json.dumps(claims).encode())
    sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", keyfile], input=(head + "." + body).encode(),
                         capture_output=True, check=True).stdout
    return head + "." + body + "." + b64u(sig)


# ---------------------------------------------------------------- kubectl
def k(*args, timeout=60):
    try:
        r = subprocess.run(["kubectl", *args], capture_output=True, text=True, timeout=timeout)
        return r.stdout + (("\n[stderr] " + r.stderr) if r.returncode and r.stderr else "")
    except Exception as e:  # noqa: BLE001
        return "[kubectl error] %s" % e


def pods_of(vmcp):
    names = k("get", "pods", "-n", NS, "-o", "name").split()
    # the operator names the Deployment (and so the pods) after the VirtualMCPServer; the Service is vmcp-<name>
    return [n for n in names if re.fullmatch(r"pod/%s-[a-z0-9]+-[a-z0-9]{5}" % re.escape(vmcp), n)]


def logs_of(vmcp):
    out = ""
    for p in pods_of(vmcp):
        out += k("logs", "-n", NS, p, "--all-containers", "--tail=2000")
    return out


# ---------------------------------------------------------------- port-forward and a small MCP client
class Fwd:
    ports = {}
    procs = {}

    @classmethod
    def url(cls, vmcp):
        p = cls.procs.get(vmcp)
        if p is None or p.poll() is not None:
            port = cls.ports.get(vmcp) or (15000 + len(cls.ports) + 1)
            cls.ports[vmcp] = port
            cls.procs[vmcp] = subprocess.Popen(["kubectl", "port-forward", "-n", NS, "svc/vmcp-%s" % vmcp, "%d:4483" % port],
                                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for _ in range(40):
                try:
                    socket.create_connection(("127.0.0.1", port), 0.5).close()
                    break
                except OSError:
                    time.sleep(0.5)
        return "http://127.0.0.1:%d/mcp" % cls.ports[vmcp]

    @classmethod
    def stop(cls):
        for p in cls.procs.values():
            p.terminate()


class Mcp:
    def __init__(self, vmcp, token=None, headers=None):
        self.url, self.sid, self.n = Fwd.url(vmcp), None, 0
        self.h = {"content-type": "application/json", "accept": "application/json, text/event-stream"}
        if token:
            self.h["authorization"] = "Bearer " + token
        self.h.update(headers or {})

    def rpc(self, method, params=None, notify=False):
        body = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            body["params"] = params
        if not notify:
            self.n += 1
            body["id"] = self.n
        h = dict(self.h)
        if self.sid:
            h["mcp-session-id"] = self.sid
        req = urllib.request.Request(self.url, json.dumps(body).encode(), h)
        try:
            r = urllib.request.urlopen(req, timeout=60)
        except urllib.error.HTTPError as e:
            return {"http_error": e.code, "body": e.read().decode()[:300]}
        self.sid = r.headers.get("mcp-session-id") or self.sid
        raw = r.read().decode()
        if notify or not raw.strip():
            return None
        if "data:" in raw and (r.headers.get("content-type") or "").startswith("text/event-stream"):
            raw = [ln[5:].strip() for ln in raw.splitlines() if ln.startswith("data:")][-1]
        return json.loads(raw)

    def init(self):
        r = self.rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "spike", "version": "0"}})
        self.rpc("notifications/initialized", notify=True)
        return r

    def tools(self):
        r = self.rpc("tools/list")
        if not r or "result" not in r:
            return None, r
        return r["result"]["tools"], r

    def call(self, name, args=None):
        return self.rpc("tools/call", {"name": name, "arguments": args or {}})


def text_of(resp):
    """All text in a tools/call answer (content items, or the error), as one string."""
    if not resp:
        return ""
    if "result" in resp:
        return " ".join(c.get("text", "") for c in resp["result"].get("content", []) if isinstance(c, dict))
    return json.dumps(resp.get("error") or resp)


def refused(resp):
    return bool(resp) and ("error" in resp or "http_error" in resp or (resp.get("result") or {}).get("isError") is True)


# ---------------------------------------------------------------- results
R = []


def rec(cid, question, verdict, detail, evidence=None):
    R.append({"id": cid, "q": question, "verdict": verdict, "detail": detail, "evidence": evidence})
    print("[%s] %s %s: %s" % (verdict, cid, question, detail), flush=True)


def guarded(fn):
    try:
        fn()
    except Exception as e:  # noqa: BLE001
        rec(fn.__name__, "-", "ERROR", "%s: %s" % (type(e).__name__, e))


def verdict_of(r):
    return next((x["verdict"] for x in R if x["id"] == r), "MISSING")


# ---------------------------------------------------------------- the checks
CANARY = os.environ.get("SPIKE_RESULT_CANARY", "RESULT-CANARY")
REQ_CANARY = os.environ.get("SPIKE_REQUEST_CANARY", "REQ-CANARY")
SHARED_DIAG = "dgs_pods_list"
SCRIPT_DIAG = "return %s()" % SHARED_DIAG
LISTS = {}


def anon(vmcp):
    c = Mcp(vmcp)
    c.init()
    return c


def listing():
    for v in ("sh-open", "sh-excl", "sh-deny", "sh-cedar", "sh-sep"):
        c = anon(v)
        tools, raw = c.tools()
        LISTS[v] = [t["name"] for t in tools] if tools is not None else None
        rec("list/" + v, "1", "INFO", "tools: %s" % (LISTS[v] if tools is not None else "list failed: %s" % json.dumps(raw)[:200]))
        if v == "sh-excl" and tools:
            d = [t for t in tools if t["name"] == "execute_tool_script"]
            LISTS["script-desc/" + v] = d[0].get("description", "") if d else ""


def direct_and_script():
    ctl = anon("sh-open").call(SHARED_DIAG, {"namespace": REQ_CANARY})
    ok_ctl = CANARY in text_of(ctl)
    rec("ctl/direct-open", "1", "PASS" if ok_ctl else "FAIL", "control: a direct call of %s on the unfiltered shared vMCP returns the backend result: %s" % (SHARED_DIAG, ok_ctl))
    sc = anon("sh-open").call("execute_tool_script", {"script": SCRIPT_DIAG})
    sc_ok = CANARY in text_of(sc)
    rec("ctl/script-open", "5", "PASS" if sc_ok else "INCONCLUSIVE",
        "control: a code mode script calling %s on the unfiltered shared vMCP returns the backend result: %s; answer: %s" % (SHARED_DIAG, sc_ok, text_of(sc)[:200]))
    for v in ("sh-excl", "sh-deny", "sh-cedar"):
        c = anon(v)
        d = c.call(SHARED_DIAG, {"namespace": REQ_CANARY})
        s = c.call("execute_tool_script", {"script": SCRIPT_DIAG})
        okc = c.call("ok_ping")
        okx = c.call("execute_tool_script", {"script": "return ok_ping()"})
        d_leak, s_leak = CANARY in text_of(d), CANARY in text_of(s)
        rec("call/" + v, "1", "PASS" if (not d_leak and refused(d)) else "FAIL",
            "direct call of %s: result leaked=%s refused=%s; answer: %s" % (SHARED_DIAG, d_leak, refused(d), text_of(d)[:200]))
        rec("script/" + v, "5", "PASS" if (not s_leak and refused(s)) else "FAIL",
            "code mode call of %s: result leaked=%s refused=%s; answer: %s" % (SHARED_DIAG, s_leak, refused(s), text_of(s)[:200]))
        rec("allowed/" + v, "1", "PASS" if ("pong" in text_of(okc) and "pong" in text_of(okx)) else "INCONCLUSIVE",
            "control: ok_ping still works, direct=%s, code mode=%s" % ("pong" in text_of(okc), "pong" in text_of(okx)))
    # does the code mode tool advertise names of the excluded backend?
    for v in ("sh-excl", "sh-deny", "sh-cedar"):
        c = anon(v)
        tools, _ = c.tools()
        desc = " ".join(json.dumps(t) for t in (tools or []) if t["name"] == "execute_tool_script")
        rec("script-names/" + v, "5", "INFO", "execute_tool_script schema mentions 'dgs_': %s" % ("dgs_" in desc))


def separate_group():
    c = anon("sh-sep")
    l = LISTS.get("sh-sep") or []
    d = c.call("dg_pods_list")
    d2 = c.call(SHARED_DIAG)
    leak = CANARY in text_of(d) or CANARY in text_of(d2)
    none = not any(n.startswith(("dg_", "dgs_")) for n in l)
    rec("sep/group", "1", "PASS" if (none and not leak and refused(d) and refused(d2)) else "FAIL",
        "vMCP on a group without the diagnostics backend: lists none=%s, call leaked=%s, refused=%s/%s" % (none, leak, refused(d), refused(d2)))
    # the dedicated vMCP sees them
    tok = make_jwt(os.environ["SPIKE_KEY"], os.environ["SPIKE_KID"], os.environ["SPIKE_ISSUER"], os.environ["SPIKE_AUDIENCE"], "spike-agent-1")
    c2 = Mcp("diag", token=tok)
    c2.init()
    t, raw = c2.tools()
    names = [x["name"] for x in t] if t else None
    rec("sep/dedicated", "1", "PASS" if names and "dg_pods_list" in names else "FAIL", "the dedicated vMCP lists: %s" % (names if names else json.dumps(raw)[:200]))


def listing_verdicts():
    sh = lambda v: LISTS.get(v)
    for v in ("sh-open", "sh-excl", "sh-deny", "sh-cedar"):
        l = sh(v)
        if l is None:
            rec("hidden/" + v, "1", "INCONCLUSIVE", "no list")
            continue
        shown = [n for n in l if n.startswith("dgs_")]
        if v == "sh-open":
            rec("hidden/" + v, "1", "PASS" if shown else "INCONCLUSIVE", "control: unfiltered shared vMCP lists the diagnostics tools: %s" % shown)
        elif v == "sh-cedar":
            rec("hidden/" + v, "1", "INFO", "Cedar forbid on the two tool names, list shows: %s" % shown)
        else:
            rec("hidden/" + v, "1", "PASS" if not shown else "FAIL", "shared vMCP lists none of the diagnostics tools: shown=%s, other tools=%s" % (shown, [n for n in l if n not in shown]))


def headers():
    val = open(os.environ["SPIKE_HDR_VALUE_FILE"]).read().strip()
    raw = open(os.environ["SPIKE_HDR_RAW_FILE"]).read().strip()
    tok = make_jwt(os.environ["SPIKE_KEY"], os.environ["SPIKE_KID"], os.environ["SPIKE_ISSUER"], os.environ["SPIKE_AUDIENCE"], "spike-agent-1")
    c = Mcp("diag", token=tok)
    c.init()
    tools, _ = c.tools()
    names = [t["name"] for t in tools or []]
    rec("hdr/list", "2", "INFO", "tools on the dedicated vMCP: %s" % names)
    forms = {"hdra": "MCPServerEntry.headerForward.addHeadersFromSecret", "hdrb": "MCPExternalAuthConfig headerInjection",
             "hdrc": "MCPExternalAuthConfig bearerToken", "hdrd": "headerForward without externalAuthConfigRef"}
    for e, form in forms.items():
        tn = "%s_whoami" % e
        if tn not in names:
            rec("hdr/" + e, "2", "FAIL" if e != "hdrd" else "INFO", "%s: the backend is not in the vMCP tool list (dropped, see hdr/dropped)" % form)
            continue
        r = c.call(tn)
        try:
            h = json.loads(text_of(r))["headers"]
        except Exception:  # noqa: BLE001
            rec("hdr/" + e, "2", "ERROR", "%s: bad answer %s" % (form, text_of(r)[:200]))
            continue
        a = h.get("authorization", {}).get("sha256")
        match = "no Authorization header" if a is None else ("exactly the Secret value" if a == sha(val) else
                                                             ("'Bearer ' + the Secret value" if a == sha("Bearer " + raw) else "something else"))
        ok = a in (sha(val), sha("Bearer " + raw))
        rec("hdr/" + e, "2", "PASS" if ok else "FAIL", "%s: backend received Authorization = %s" % (form, match))
    # discovery requests: did the backend see the header on initialize / tools/list too?
    lg = k("logs", "-n", NS, "deploy/mcpstub", "--tail=5000")
    for e in ("hdra", "hdrb", "hdrc"):
        lines = [x for x in lg.splitlines() if x.startswith("REQ path=/mcp/%s " % e)]
        by = {}
        for x in lines:
            rpc = x.split("rpc=")[1].split()[0]
            by.setdefault(rpc, set()).add("none" if "authz=none" in x else "set")
        rec("hdr/discovery/" + e, "2", "INFO", "backend log, Authorization by request kind: %s" % {a: sorted(b) for a, b in by.items()})
    # does the value show up anywhere it should not?
    sinks = {
        "MCPServerEntry objects": k("get", "mcpserverentries", "-n", NS, "-o", "yaml"),
        "MCPExternalAuthConfig objects": k("get", "mcpexternalauthconfigs", "-n", NS, "-o", "yaml"),
        "VirtualMCPServer objects": k("get", "virtualmcpservers", "-n", NS, "-o", "yaml"),
        "MCPGroup objects": k("get", "mcpgroups", "-n", NS, "-o", "yaml"),
        "ConfigMaps in the namespace": k("get", "configmaps", "-n", NS, "-o", "yaml"),
        "pod specs in the namespace": k("get", "pods", "-n", NS, "-o", "yaml"),
        "vMCP pod logs": "".join(logs_of(v) for v in ("diag", "sh-open", "sh-excl", "sh-deny", "sh-cedar", "sh-sep")),
        "operator log": k("logs", "-n", "toolhive-system", "deploy/toolhive-operator", "--tail=5000"),
    }
    # the Secret objects themselves hold it by design; only look elsewhere
    bad = [n for n, t in sinks.items() if raw in t]
    rec("hdr/no-leak", "2", "PASS" if not bad else "FAIL",
        "header value searched in: %s; found in: %s" % (", ".join(sinks), bad or "none"))
    # how does the vMCP get at the value? (names of references only, never values)
    refs = []
    try:
        for p in json.loads(k("get", "pods", "-n", NS, "-o", "json"))["items"]:
            if re.fullmatch(r"diag-[a-z0-9]+-[a-z0-9]{5}", p["metadata"]["name"]):
                for c2 in p["spec"]["containers"] + p["spec"].get("initContainers", []):
                    for ev in c2.get("env", []):
                        if "secretKeyRef" in (ev.get("valueFrom") or {}):
                            refs.append("env %s from secret %s" % (ev["name"], ev["valueFrom"]["secretKeyRef"]["name"]))
                    for ef in c2.get("envFrom", []):
                        if "secretRef" in ef:
                            refs.append("envFrom secret %s" % ef["secretRef"]["name"])
                    refs.append("container %s env names: %s" % (c2["name"], sorted(e["name"] for e in c2.get("env", []))))
                for v in p["spec"].get("volumes", []):
                    if "secret" in v:
                        refs.append("volume %s from secret %s" % (v["name"], v["secret"].get("secretName")))
    except Exception as ex:  # noqa: BLE001
        refs.append("error %s" % ex)
    rec("hdr/mechanism", "2", "INFO", "how the vMCP pod receives it: %s" % (refs or "no Secret reference in the pod spec"))
    # backends the vMCP dropped, from its own status
    try:
        st = json.loads(k("get", "virtualmcpserver", "diag", "-n", NS, "-o", "json"))["status"]
        bad = ["%s: %s" % (c["type"], c.get("message", "")) for c in st.get("conditions", []) if c.get("status") == "False" and c["type"] != "Ready"]
        rec("hdr/dropped", "2", "INFO", "backendCount=%s; conditions that are False: %s" % (st.get("backendCount"), bad or "none"))
    except Exception as ex:  # noqa: BLE001
        rec("hdr/dropped", "2", "ERROR", str(ex))


def identity():
    jwt = make_jwt(os.environ["SPIKE_KEY"], os.environ["SPIKE_KID"], os.environ["SPIKE_ISSUER"], os.environ["SPIKE_AUDIENCE"],
                   "spike-agent-1", {"atespace": "spike-ns"})
    # control: no token is refused
    n = Mcp("diag")
    r = n.rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "x", "version": "0"}})
    rec("id/no-token", "3", "PASS" if (r and "http_error" in r) else "FAIL", "control: the OIDC vMCP refuses a call without a token: %s" % json.dumps(r)[:120])
    c = Mcp("diag", token=jwt, headers={"X-Caller-Id": "caller-alice"})
    c.init()
    r = c.call("dg_whoami")
    try:
        h = json.loads(text_of(r))["headers"]
    except Exception:  # noqa: BLE001
        rec("id/whoami", "3", "ERROR", "bad answer: %s" % text_of(r)[:200])
        return
    names = sorted(h)
    tok_hit = [n for n, e in h.items() if e["sha256"] in (sha(jwt), sha("Bearer " + jwt))]
    plain = [n for n, e in h.items() if "value" in e and ("spike-agent-1" in e["value"] or "spike-ns" in e["value"])]
    rec("id/headers", "3", "INFO", "headers the backend received through the vMCP: %s" % names)
    rec("id/token", "3", "PASS" if not tok_hit else "FAIL",
        "caller's token forwarded to the backend: %s. Claim values (sub, atespace) in plain in a header: %s" % (tok_hit or "no", plain or "no"))
    pt = h.get("x-caller-id", {}).get("value")
    rec("id/passthrough", "3", "PASS" if pt == "caller-alice" else "FAIL",
        "vMCP spec.passthroughHeaders [X-Caller-Id]: the backend received X-Caller-Id = %s" % pt)
    c2 = Mcp("diag", token=jwt)
    c2.init()
    h2 = json.loads(text_of(c2.call("dg_whoami")))["headers"]
    rec("id/passthrough-absent", "3", "PASS" if "x-caller-id" not in h2 else "FAIL",
        "a call without the header does not carry one: x-caller-id present=%s" % ("x-caller-id" in h2))
    # the backend log: what did the discovery requests (no caller) look like?
    lg = k("logs", "-n", NS, "deploy/mcpstub", "--tail=5000")
    disc = sorted({x.split("headers=")[1].split(" ")[0] for x in lg.splitlines() if x.startswith("REQ path=/mcp/dg ") and "rpc=initialize" in x})
    rec("id/log", "3", "INFO", "header names the backend log shows on initialize requests to /mcp/dg: %s" % disc[:3])


def audit():
    tok = make_jwt(os.environ["SPIKE_KEY"], os.environ["SPIKE_KID"], os.environ["SPIKE_ISSUER"], os.environ["SPIKE_AUDIENCE"], "spike-agent-1")
    d = Mcp("diag", token=tok)
    d.init()
    rd = d.call("dg_pods_list", {"namespace": REQ_CANARY})
    o = anon("sh-open")
    ro = o.call(SHARED_DIAG, {"namespace": REQ_CANARY})
    time.sleep(6)
    rec("audit/calls", "4", "INFO", "calls returned the backend result: diag=%s sh-open=%s" % (CANARY in text_of(rd), CANARY in text_of(ro)))
    ld, lo = logs_of("diag"), logs_of("sh-open")
    ev_d = [x for x in ld.splitlines() if "audit" in x.lower() or "tools/call" in x or "tool_call" in x.lower()]
    ev_o = [x for x in lo.splitlines() if "audit" in x.lower() or "tools/call" in x or "tool_call" in x.lower()]
    rec("audit/events", "4", "INFO", "audit-like lines: diag=%d (capture off), sh-open=%d (capture on)" % (len(ev_d), len(ev_o)),
        {"diag_sample": [x[:500] for x in ev_d[:3]], "open_sample": [x[:500] for x in ev_o[:3]]})
    rec("audit/log-shape", "4", "INFO", "first log lines of the capture-on vMCP (shape only): %s" % [x[:160] for x in lo.splitlines()[:6]])
    pos_res, pos_req = CANARY in lo, REQ_CANARY in lo
    rec("audit/control", "4", "PASS" if pos_res else "INCONCLUSIVE",
        "control (includeResponseData true, includeRequestData true): result canary in the vMCP log=%s, request canary=%s" % (pos_res, pos_req))
    neg_res, neg_req = CANARY in ld, REQ_CANARY in ld
    v = "PASS" if (pos_res and not neg_res) else ("INCONCLUSIVE" if not pos_res else "FAIL")
    rec("audit/off", "4", v, "includeResponseData false, includeRequestData false: result canary in the vMCP log=%s, request canary=%s (valid only if the control found it)" % (neg_res, neg_req))
    rec("audit/backend-log", "4", "INFO", "the stand-in backend, not ToolHive, logs request metadata only; canary in its log: %s" % (CANARY in k("logs", "-n", NS, "deploy/mcpstub", "--tail=3000")))


# ---------------------------------------------------------------- stop rules
def stop_rules():
    def holds(form):
        return all(verdict_of(x) == "PASS" for x in ("hidden/sh-" + form, "call/sh-" + form, "script/sh-" + form))
    a_excl, a_deny = holds("excl"), holds("deny")
    a = a_excl or a_deny
    b = all(verdict_of(x) == "PASS" for x in ("call/sh-cedar", "script/sh-cedar"))
    controls = all(verdict_of(x) == "PASS" for x in ("ctl/direct-open", "hidden/sh-open"))
    c = verdict_of("sep/group") == "PASS"
    out = [
        ("(a) aggregation filter hides the backend (list, direct call, code mode)", a, "excludeAll form: %s; defaultToolVisibility deny form: %s" % (a_excl, a_deny)),
        ("(b) Cedar forbid refuses a direct call and a code mode call under permit-all", b, "list also hides them: %s" % (verdict_of("hidden/sh-cedar"))),
        ("separate MCPGroup the shared vMCP does not reference", c, ""),
        ("controls valid (unfiltered shared vMCP lists and serves the tools)", controls, ""),
    ]
    for i, (t, ok, d) in enumerate(out):
        rec("rule/part%d" % (i + 1), "rules", "PASS" if ok else "FAIL", "%s: %s %s" % (t, ok, d))
    sr1 = controls and (a or b)
    rec("rule/SR1", "rules", "PASS" if sr1 else "FAIL", "slice 2 stop rule 1, 'if neither (a) nor (b) holds, nothing is registered in the shared group': satisfied=%s" % sr1)
    sr2 = not (b and not a)
    rec("rule/SR2", "rules", "PASS" if sr2 else "FAIL", "slice 2 stop rule 2, 'if (b) holds and (a) does not, the forbid layer alone needs the reviewer's agreement': not triggered=%s" % sr2)
    sr6 = controls and a and b
    rec("rule/SEC6", "rules", "PASS" if sr6 else "FAIL", "section 6 stop rule, both layers shown (filter and forbid; list, direct call and code mode): %s" % sr6)


def main():
    out = os.environ.get("SPIKE_OUT", "spike-out")
    os.makedirs(out, exist_ok=True)
    try:
        for fn in (listing, direct_and_script, separate_group, listing_verdicts, headers, identity, audit):
            guarded(fn)
        guarded(stop_rules)
    finally:
        Fwd.stop()
        json.dump(R, open(os.path.join(out, "results.json"), "w"), indent=1)
        icon = {"PASS": "PASS", "FAIL": "FAIL", "INFO": "info", "INCONCLUSIVE": "inconclusive", "ERROR": "ERROR"}
        qn = {"1": "1 exclusion from the shared vMCP", "2": "2 header injection", "3": "3 caller identity", "4": "4 audit content", "5": "5 code mode", "rules": "stop rules"}
        md = ["| question | check | verdict | what was seen |", "|---|---|---|---|"]
        for x in sorted(R, key=lambda x: (x["q"], R.index(x))):
            md.append("| %s | `%s` | %s | %s |" % (qn.get(x["q"], x["q"]), x["id"], icon[x["verdict"]], x["detail"].replace("|", "/").replace("\n", " ")[:600]))
        open(os.path.join(out, "results.md"), "w").write("\n".join(md) + "\n")
    bad = [x for x in R if x["verdict"] == "ERROR"]
    return 1 if bad else 0


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "jwks":
        print(json.dumps(jwks(sys.argv[2], sys.argv[3])))
    elif len(sys.argv) >= 2 and sys.argv[1] == "run":
        sys.exit(main())
    else:
        print(__doc__)
        sys.exit(2)
