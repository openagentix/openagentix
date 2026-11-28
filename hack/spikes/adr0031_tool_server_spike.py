"""Spike for ADR 0031 (PR #276, issue #229): tool servers (ToolHive VirtualMCPServer) that cannot read Secrets. Standard library only; run with `python3 -I`.

Run it on a cluster made like the endpoints job of the e2e workflow (kind cluster, hack/ci/endpoints-ci-setup.sh, then `PROFILE=quickstart
VALUES_FILE=hack/ci/endpoints-ci-values.yaml ./install.sh`). The script changes that throwaway cluster: it writes ServiceAccounts, Roles and RoleBindings by
hand and sets `spec.serviceAccount` on the tool servers, and it makes the tool servers trust the API server's tokens (as hack/ci/endpoints-live.sh does) so that
it can call them. It changes no chart value, no CRD and no service code. It refuses to run outside GitHub Actions on a kind cluster.

The ten questions are those of the section "Spike" of ADR 0031, in its order (Q1 to Q10), plus facts the ADR asks to record (ToolHive version, the session secret).
"""
import json
import os
import re
import socket
import subprocess
import sys
import time
import traceback
import urllib.error
import urllib.request

OUT = os.environ.get("SPIKE_OUT", "spike-out")
MCPNS = "mcp-tools"
ENS = "endpoint-ci"
TH = "toolhive-system"
VMCPS = {"tools": "openagentix-vmcp", "tools-lookup": "openagentix-vmcp-lookup", "tools-disputes": "openagentix-vmcp-disputes", "tools-lookup-cm": "openagentix-vmcp-lookup-cm"}
R = []
T0 = time.time()
S = {}
Q = {1: "Q1 no operator objects, hand-written ones left alone", 2: "Q2 every backend ready without a Secret rule", 3: "Q3 tools/list, a call, and the header",
     4: "Q4 can-i for Secrets, and a pod as the account", 5: "Q5 forbidden lines in the tool server logs", 6: "Q6 the -workload variant and its tokens",
     7: "Q7 is the Role enough without ConfigMap rights", 8: "Q8 status with resourceNames", 9: "Q9 the operator's old objects", 10: "Q10 memory and restart time",
     11: "Q11 can the tool server accounts create workloads or exec", 12: "Q12 the accounts of the proxy runners of mcp.servers", 13: "Q13 the session secret and a restart",
     14: "Q14 helm upgrade and an operator restart", 15: "Q15 volumes and env sources, new account against the default one", "F": "Facts to record"}


def say(m):
    print("[%5.0fs] %s" % (time.time() - T0, m), flush=True)


def short(s, n=500):
    s = (s or "").replace("\n", " ")
    return s if len(s) <= n else s[:n] + "...[+%d]" % (len(s) - n)


def rec(q, cid, verdict, request, seen, answer=""):
    R.append({"q": q, "id": cid, "verdict": verdict, "request": request, "seen": seen, "answer": answer})
    write_results()
    say("%s %s -> %s %s" % (q, cid, verdict, (answer or seen)[:150].replace("\n", " ")))


def write_results():
    os.makedirs(OUT, exist_ok=True)
    json.dump(R, open(os.path.join(OUT, "results-adr0031.json"), "w"), indent=1)
    md = ["## Spike for ADR 0031: tool servers that cannot read Secrets", ""]
    for q in list(Q):
        rows = [x for x in R if x["q"] == q]
        if not rows:
            continue
        md += ["### " + Q[q], ""]
        for x in rows:
            md += ["**%s** (%s)" % (x["id"], x["verdict"]), ""]
            if x["request"]:
                md += ["Request or manifest:", "", "```", x["request"].rstrip(), "```", ""]
            md += ["Seen:", "", "```", (x["seen"] or "").rstrip(), "```", ""]
            if x["answer"]:
                md += ["Answer: " + x["answer"], ""]
    open(os.path.join(OUT, "results-adr0031.md"), "w").write("\n".join(md))


def k(*args, timeout=120, stdin=None):
    try:
        r = subprocess.run(["kubectl", *args], capture_output=True, text=True, timeout=timeout, input=stdin)
        return r.returncode, r.stdout, r.stderr
    except Exception as e:  # noqa: BLE001
        return 99, "", "[kubectl error] %s" % e


def kj(*args):
    rc, out, err = k(*args, "-o", "json")
    if rc:
        raise RuntimeError("kubectl %s: %s" % (" ".join(args), err.strip()[:300]))
    return json.loads(out)


def kjs(*args, default=None):
    try:
        return kj(*args)
    except Exception:  # noqa: BLE001
        return default


def apply(doc):
    text = doc if isinstance(doc, str) else json.dumps(doc)
    rc, out, err = k("apply", "-f", "-", stdin=text)
    if rc:
        raise RuntimeError("apply failed: " + err.strip()[:600])
    return out


def sh(*args, timeout=60):
    try:
        r = subprocess.run(list(args), capture_output=True, text=True, timeout=timeout)
        return r.stdout + (("\n[stderr] " + r.stderr) if r.returncode and r.stderr else "")
    except Exception as e:  # noqa: BLE001
        return "[error] %s" % e


def guard(fn, q):
    try:
        fn()
    except Exception:  # noqa: BLE001
        rec(q, fn.__name__, "ERROR", "", traceback.format_exc()[-1800:])


# ------------------------------------------------------------------ HTTP and MCP
def http(method, url, headers=None, body=None, timeout=30):
    data = body.encode() if isinstance(body, str) else body
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    out = {"status": None, "headers": {}, "body": "", "error": ""}
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            out["status"], out["headers"], out["body"] = r.status, {a.lower(): b for a, b in r.headers.items()}, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        out["status"], out["headers"] = e.code, {a.lower(): b for a, b in e.headers.items()}
        out["body"] = e.read().decode("utf-8", "replace")
    except Exception as e:  # noqa: BLE001
        out["error"] = "%s: %s" % (type(e).__name__, e)
    return out


class PF:
    def __init__(self, ns, target, remote):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        self.port = s.getsockname()[1]
        s.close()
        self.p = subprocess.Popen(["kubectl", "port-forward", "-n", ns, target, "%d:%s" % (self.port, remote)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", self.port), 0.5).close()
                return
            except OSError:
                time.sleep(0.2)
        self.stop()
        raise RuntimeError("port-forward to %s/%s did not start" % (ns, target))

    def stop(self):
        try:
            self.p.terminate()
            self.p.wait(5)
        except Exception:  # noqa: BLE001
            pass


def sse(body):
    if "data:" in body:
        lines = [x[5:].strip() for x in body.splitlines() if x.startswith("data:")]
        return lines[-1] if lines else ""
    return body


class Mcp:
    """A tiny MCP client for a vMCP behind a port-forward; the token goes in a header only."""

    def __init__(self, svc, token):
        self.pf = PF(MCPNS, "svc/vmcp-" + svc, "4483")
        self.token = token
        self.sid = None
        self.n = 1

    def post(self, body):
        h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if self.token:
            h["Authorization"] = "Bearer " + self.token
        if self.sid:
            h["Mcp-Session-Id"] = self.sid
        r = http("POST", "http://127.0.0.1:%d/mcp" % self.pf.port, h, json.dumps(body), 40)
        return r

    def open(self):
        r = self.post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "adr0031", "version": "0"}}})
        if r["status"] != 200:
            return r
        self.sid = r["headers"].get("mcp-session-id")
        self.post({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return r

    def call(self, method, params=None):
        self.n += 1
        r = self.post({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or {}})
        try:
            return r["status"], json.loads(sse(r["body"]) or "null")
        except Exception:  # noqa: BLE001
            return r["status"], {"raw": short(r["body"], 300), "error_text": r["error"]}

    def close(self):
        self.pf.stop()


def token(aud, ns=MCPNS, sa="default", extra=()):
    if not aud:
        return ""
    rc, out, err = k("create", "token", sa, "-n", ns, "--audience", aud, "--duration", "30m", *extra)
    return out.strip() if rc == 0 else ""


def mcp_try(svc, aud, tries=8):
    """Open a session, retrying while the pod starts."""
    last = None
    for _ in range(tries):
        c = Mcp(svc, token(aud))
        r = c.open()
        if c.sid:
            return c
        last = r
        c.close()
        time.sleep(5)
    return None


def podsrc(v):
    """Volumes and env sources of the running pod of a tool server, as plain lists."""
    ps = kj("get", "pods", "-n", MCPNS, "-l", "app=virtualmcpserver,toolhive-name=" + v)["items"]
    ps = [p for p in ps if not p["metadata"].get("deletionTimestamp")]
    if not ps:
        return None
    sp = ps[0]["spec"]
    vols = []
    for x in sp.get("volumes", []):
        kind = [kk for kk in x if kk != "name"]
        det = ""
        if "secret" in x:
            det = x["secret"].get("secretName", "")
        if "configMap" in x:
            det = x["configMap"].get("name", "")
        if "projected" in x:
            det = ",".join(sorted(list(src.keys())[0] + ":" + (src.get("serviceAccountToken", {}).get("audience", "") or src.get("configMap", {}).get("name", "")) for src in x["projected"].get("sources", [])))
        vols.append("%s(%s%s)" % (x["name"], ",".join(kind), (":" + det) if det else ""))
    env = []
    for c in sp.get("containers", []):
        for e in c.get("env", []):
            vf = e.get("valueFrom")
            if vf:
                kk = list(vf)[0]
                env.append("%s<-%s/%s" % (e["name"], kk, (vf[kk] or {}).get("name", (vf[kk] or {}).get("fieldPath", ""))))
            else:
                env.append("%s<-value" % e["name"])
        for e in c.get("envFrom", []):
            env.append("envFrom:%s" % json.dumps(e, sort_keys=True))
    return {"sa": sp.get("serviceAccountName"), "automount": sp.get("automountServiceAccountToken"), "volumes": sorted(vols), "env": sorted(env),
            "containers": [c["name"] for c in sp.get("containers", [])], "mounts": sorted("%s:%s" % (m["name"], m["mountPath"]) for c in sp.get("containers", []) for m in c.get("volumeMounts", []))}


def echo_seen():
    rc, out, _ = k("logs", "-n", ENS, "deploy/echo", "--tail=3000")
    return out.count('"presented": "self"')


def functional(svc, aud, tool_prefix="echo_", call=True):
    """tools/list, and one call that must reach echo with its header. Returns (tool names, call text, header seen delta, note)."""
    c = mcp_try(svc, aud)
    if not c:
        return None, None, None, "no session"
    try:
        st, lst = c.call("tools/list")
        names = sorted(t["name"] for t in ((lst or {}).get("result") or {}).get("tools", []))
        txt, delta = None, None
        if call and "echo_echo" in names:
            before = echo_seen()
            st2, res = c.call("tools/call", {"name": "echo_echo", "arguments": {"text": "adr0031 check"}})
            txt = " ".join(x.get("text", "") for x in ((res or {}).get("result") or {}).get("content", [])) or short(json.dumps(res), 200)
            time.sleep(1)
            delta = echo_seen() - before
        return names, txt, delta, "ok"
    finally:
        c.close()


# ------------------------------------------------------------------ cluster facts
def node():
    out = sh("docker", "ps", "--format", "{{.Names}}")
    n = [x for x in out.split() if x.endswith("control-plane")]
    return n[0] if n else None


def memory():
    free = sh("free", "-m").splitlines()
    used = free[1].split()[2] if len(free) > 1 else "?"
    dk = sh("docker", "stats", "--no-stream", "--format", "{{.MemUsage}}", node() or "none").strip()
    return "runner used %s MiB; kind node container %s" % (used, dk)


def vmcp_names():
    return [i["metadata"]["name"] for i in kj("get", "virtualmcpserver", "-n", MCPNS)["items"]]


def rbac_state(names):
    """uid, resourceVersion and rules of the ServiceAccount, Role and RoleBinding of each name."""
    out = {}
    for n in names:
        for kind in ("serviceaccount", "role", "rolebinding"):
            o = kjs("get", kind, n, "-n", MCPNS)
            out["%s/%s" % (kind, n)] = None if o is None else {"uid": o["metadata"]["uid"], "rv": o["metadata"]["resourceVersion"], "rules": o.get("rules"),
                                                                "subjects": o.get("subjects"), "owner": [r["kind"] + "/" + r["name"] for r in o["metadata"].get("ownerReferences", [])]}
    return out


def role_doc(name, vmcp, configmaps=True):
    rules = [{"apiGroups": ["toolhive.stacklok.dev"], "resources": ["mcpgroups", "mcpservers", "mcpremoteproxies", "mcpserverentries", "mcpexternalauthconfigs", "mcptoolconfigs"], "verbs": ["get", "list", "watch"]},
             {"apiGroups": ["toolhive.stacklok.dev"], "resources": ["virtualmcpservers"], "verbs": ["get"], "resourceNames": [vmcp]},
             {"apiGroups": ["toolhive.stacklok.dev"], "resources": ["virtualmcpservers/status"], "verbs": ["update", "patch"], "resourceNames": [vmcp]}]
    if configmaps:
        rules.append({"apiGroups": [""], "resources": ["configmaps"], "verbs": ["get", "list", "watch"]})
    return rules


def rbac_docs(vmcp, configmaps=True):
    n = "spike-" + vmcp
    return [{"apiVersion": "v1", "kind": "ServiceAccount", "metadata": {"name": n, "namespace": MCPNS}},
            {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "Role", "metadata": {"name": n, "namespace": MCPNS}, "rules": role_doc(n, vmcp, configmaps)},
            {"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "RoleBinding", "metadata": {"name": n, "namespace": MCPNS},
             "subjects": [{"kind": "ServiceAccount", "name": n, "namespace": MCPNS}], "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": n}}]


def apply_rbac(vmcp, configmaps=True):
    for d in rbac_docs(vmcp, configmaps):
        apply(d)


def backends(vmcp):
    o = kjs("get", "virtualmcpserver", vmcp, "-n", MCPNS, default={}) or {}
    st = o.get("status") or {}
    return {b["name"]: b.get("status") for b in st.get("discoveredBackends", [])}, st.get("phase"), [(c["type"], c["status"]) for c in st.get("conditions", []) if c["status"] != "True" and c["type"] != "SessionStorageWarning"]


def pods_of(vmcp):
    return [p["metadata"]["name"] for p in kj("get", "pods", "-n", MCPNS, "-l", "app=virtualmcpserver,toolhive-name=" + vmcp)["items"] if not p["metadata"].get("deletionTimestamp")]


ERR = re.compile(r"forbidden|cannot (get|list|watch|patch|update)|rbac|unauthorized|is not allowed", re.I)


def log_errors(vmcp, since="30m"):
    lines = []
    for p in pods_of(vmcp):
        rc, out, err = k("logs", "-n", MCPNS, p, "--all-containers", "--since=" + since, "--tail=5000")
        lines += [x for x in out.splitlines() if ERR.search(x)]
    return lines


def wait_rollout(vmcp, timeout=240):
    t0 = time.time()
    k("rollout", "status", "deploy/" + vmcp, "-n", MCPNS, "--timeout=%ds" % timeout, timeout=timeout + 20)
    return round(time.time() - t0, 1)


def wait_ready(vmcp, timeout=180):
    t0 = time.time()
    while time.time() - t0 < timeout:
        b, ph, bad = backends(vmcp)
        if b and all(v == "ready" for v in b.values()) and ph in ("Ready", "ready", None, ""):
            return True
        time.sleep(4)
    return False


# ------------------------------------------------------------------ setup and baseline
def setup():
    ctx = sh("kubectl", "config", "current-context").strip()
    if os.environ.get("GITHUB_ACTIONS") != "true" or not ctx.startswith("kind-"):
        print("refusing to run: GitHub Actions and a kind context are required (got %r)" % ctx, file=sys.stderr)
        sys.exit(2)
    S["node"] = node()
    # the tool servers trust the API server's tokens in this job, as hack/ci/endpoints-live.sh does
    cm = kj("get", "configmap", "kube-root-ca.crt", "-n", MCPNS)
    apply({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "ci-apiserver-ca", "namespace": MCPNS}, "data": {"ca.crt": cm["data"]["ca.crt"]}})
    k("create", "clusterrolebinding", "ci-jwks-anonymous", "--clusterrole=system:service-account-issuer-discovery", "--group=system:unauthenticated")
    for v in VMCPS:
        k("rollout", "restart", "deploy/" + v, "-n", MCPNS)
    for v in VMCPS:
        wait_rollout(v)
    for v in VMCPS:
        wait_ready(v)


def facts():
    ops = kj("get", "deploy", "-n", TH)
    imgs = ["%s=%s" % (d["metadata"]["name"], ",".join(c["image"] for c in d["spec"]["template"]["spec"]["containers"])) for d in ops["items"]]
    helm = sh("helm", "list", "-n", TH, "-o", "json")
    vm = kj("get", "deploy", "tools-disputes", "-n", MCPNS)
    vimg = ",".join(c["image"] for c in vm["spec"]["template"]["spec"]["containers"])
    crd = sh("kubectl", "get", "crd", "virtualmcpservers.toolhive.stacklok.dev", "-o", "jsonpath={.metadata.labels}{.metadata.annotations}")
    rec("F", "toolhive-version", "INFO", "kubectl get deploy -n %s; helm list -n %s -o json; the image of a tool server pod" % (TH, TH),
        "operator deployments and images: %s\nhelm releases: %s\ntool server (vMCP) pod image: %s\nCRD labels and annotations: %s" % ("; ".join(imgs), short(helm, 700), vimg, short(crd, 400)))


def baseline():
    S["mem_before"] = memory()
    rec(10, "memory-before", "INFO", "free -m on the runner and docker stats of the kind node, before the switch", S["mem_before"])
    old = {}
    for v in VMCPS:
        d = kj("get", "deploy", v, "-n", MCPNS)
        sa = d["spec"]["template"]["spec"].get("serviceAccountName", "")
        old[v] = sa
        can = sh("kubectl", "auth", "can-i", "get", "secrets", "-n", MCPNS, "--as=system:serviceaccount:%s:%s" % (MCPNS, sa)).strip()
        canl = sh("kubectl", "auth", "can-i", "list", "secrets", "-n", MCPNS, "--as=system:serviceaccount:%s:%s" % (MCPNS, sa)).strip()
        b, ph, bad = backends(v)
        rec(4, "before-" + v, "INFO", "kubectl auth can-i get secrets / list secrets -n %s --as=system:serviceaccount:%s:%s (the operator's account, before the switch)" % (MCPNS, MCPNS, sa),
            "get: %s; list: %s; backends: %s; phase %s" % (can, canl, b, ph))
    S["old_sa"] = old
    S["podsrc_before"] = {v: podsrc(v) for v in VMCPS}
    S["old_state"] = rbac_state(["%s-vmcp" % v for v in VMCPS])
    for v, aud in VMCPS.items():
        names, txt, delta, note = functional(v, aud)
        S.setdefault("base", {})[v] = (names, txt, delta)
        rec(3, "before-" + v, "INFO", "tools/list and, for a vMCP that lists echo_echo, tools/call echo_echo {text:'adr0031 check'} (token: the default ServiceAccount of %s, audience %s)" % (MCPNS, aud),
            "tools: %s; call: %s; echo saw its own header on %s new request(s); %s" % (names, txt, delta, note))


# ------------------------------------------------------------------ Q1: a fresh tool server with spec.serviceAccount
def allow_clones(names):
    """The endpoints' ingress policy and the group's egress policy name the tool servers of the group; an extra, additive pair names the probes."""
    apply({"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": {"name": "spike-probe-ingress", "namespace": ENS},
           "spec": {"podSelector": {"matchExpressions": [{"key": "app", "operator": "In", "values": ["echo", "other"]}]}, "policyTypes": ["Ingress"],
                    "ingress": [{"ports": [{"protocol": "TCP", "port": 8080}],
                                 "from": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": MCPNS}},
                                           "podSelector": {"matchExpressions": [{"key": "toolhive-name", "operator": "In", "values": names}]}}]}]}})
    eg = kjs("get", "networkpolicy", "openagentix-vmcp-egress-disputes", "-n", MCPNS)
    if eg:
        eg["metadata"] = {"name": "spike-probe-egress", "namespace": MCPNS}
        eg["spec"]["podSelector"] = {"matchExpressions": [{"key": "toolhive-name", "operator": "In", "values": names}]}
        apply(eg)


def q1():
    allow_clones(["probe-own", "tools-disputes-workload"])
    names = ["spike-probe-own"]
    apply_rbac("probe-own")
    vm = {"apiVersion": "toolhive.stacklok.dev/v1beta1", "kind": "VirtualMCPServer", "metadata": {"name": "probe-own", "namespace": MCPNS},
          "spec": {"groupRef": {"name": "disputes"}, "serviceAccount": "spike-probe-own",
                   "config": {"aggregation": {"conflictResolution": "prefix", "conflictResolutionConfig": {"prefixFormat": "{workload}_"}}},
                   "incomingAuth": {"type": "anonymous"}, "outgoingAuth": {"source": "discovered"}}}
    apply(vm)
    for _ in range(60):
        if kjs("get", "deploy", "probe-own", "-n", MCPNS):
            break
        time.sleep(3)
    wait_rollout("probe-own")
    time.sleep(20)
    after1 = rbac_state(["spike-probe-own"])
    op = rbac_state(["probe-own-vmcp"])
    made = [x for x, v in op.items() if v]
    sa_used = kj("get", "deploy", "probe-own", "-n", MCPNS)["spec"]["template"]["spec"].get("serviceAccountName")
    ok0 = not made and sa_used == "spike-probe-own"
    rec(1, "fresh-server", "YES" if ok0 else "NO", json.dumps(vm) + "\n(the ServiceAccount, Role and RoleBinding spike-probe-own were applied first)",
        "operator objects named probe-own-vmcp that exist: %s; the Deployment's serviceAccountName: %s; all ServiceAccounts in the namespace: %s" % (
            made or "none", sa_used, [s["metadata"]["name"] for s in kj("get", "serviceaccount", "-n", MCPNS)["items"]]),
        "no operator ServiceAccount, Role or RoleBinding was made for a tool server created with spec.serviceAccount" if ok0 else "the operator made objects or ignored the field")
    # a reconcile (an annotation event and the periodic requeue), a spec change, an operator restart
    steps = []

    def same(label):
        now = rbac_state(["spike-probe-own"])
        d = [x for x in after1 if (after1[x] or {}).get("uid") != (now[x] or {}).get("uid") or (after1[x] or {}).get("rv") != (now[x] or {}).get("rv") or (after1[x] or {}).get("rules") != (now[x] or {}).get("rules")]
        steps.append("%s: hand-written objects changed: %s; operator objects for probe-own-vmcp: %s" % (label, d or "none", [x for x, v in rbac_state(["probe-own-vmcp"]).items() if v] or "none"))
    k("annotate", "virtualmcpserver", "probe-own", "-n", MCPNS, "adr0031/touch=%d" % time.time(), "--overwrite")
    time.sleep(40)
    same("after an annotation event and 40 s")
    k("patch", "virtualmcpserver", "probe-own", "-n", MCPNS, "--type", "merge", "-p", json.dumps({"spec": {"config": {"aggregation": {"conflictResolution": "prefix", "conflictResolutionConfig": {"prefixFormat": "{workload}-"}}}}}))
    time.sleep(40)
    wait_rollout("probe-own")
    same("after a spec change (the tool prefix format) and 40 s")
    k("rollout", "restart", "deploy/toolhive-operator", "-n", TH)
    k("rollout", "status", "deploy/toolhive-operator", "-n", TH, "--timeout=180s", timeout=200)
    time.sleep(40)
    same("after a restart of the operator and 40 s")
    # the hand-written objects of the four existing servers are covered after the switch (q9 section); here the same on probe-own
    bad = [s for s in steps if "changed: none" not in s or "for probe-own-vmcp: none" not in s]
    rec(1, "left-alone", "YES" if not bad else "NO", "annotate (reconcile event), patch of spec.config.aggregation (spec change), kubectl rollout restart deploy/toolhive-operator -n %s; after each, compare uid, resourceVersion and rules of spike-probe-own" % TH,
        "\n".join(steps), "the hand-written objects were not touched and the operator made none of its own" if not bad else "see the lines")


# ------------------------------------------------------------------ the switch (Q9, Q10, Q2, Q3)
def switch():
    t_all = time.time()
    times = {}
    for v in VMCPS:
        apply_rbac(v)
    S["rb"] = rbac_state(["spike-" + v for v in VMCPS])
    for v in VMCPS:
        t0 = time.time()
        k("patch", "virtualmcpserver", v, "-n", MCPNS, "--type", "merge", "-p", json.dumps({"spec": {"serviceAccount": "spike-" + v}}))
        for _ in range(60):
            d = kjs("get", "deploy", v, "-n", MCPNS)
            if d and d["spec"]["template"]["spec"].get("serviceAccountName") == "spike-" + v:
                break
            time.sleep(2)
        t_seen = round(time.time() - t0, 1)
        wait_rollout(v)
        ready = wait_ready(v)
        times[v] = (t_seen, round(time.time() - t0, 1), ready)
    S["times"] = times
    S["mem_after"] = memory()
    rec(10, "restart-times", "INFO", "for each tool server: kubectl patch virtualmcpserver <name> --type merge -p '{\"spec\":{\"serviceAccount\":\"spike-<name>\"}}', one after the other; seconds until the operator changed the Deployment, and until the rollout is done and every backend is ready",
        "; ".join("%s: Deployment changed after %ss, ready after %ss (all backends ready: %s)" % (v, a, b, c) for v, (a, b, c) in times.items()) + "\nwhole switch of four tool servers: %.0f s" % (time.time() - t_all),
        "")
    rec(10, "memory-after", "INFO", "free -m and docker stats after the switch", "before: %s\nafter: %s" % (S["mem_before"], S["mem_after"]))


def q2_q3():
    for v, aud in VMCPS.items():
        b, ph, bad = backends(v)
        st = kj("get", "virtualmcpserver", v, "-n", MCPNS).get("status", {})
        ok = bool(b) and all(x == "ready" for x in b.values()) and not bad
        rec(2, "after-" + v, "YES" if ok else "NO", "kubectl get virtualmcpserver %s -n %s -o json (status.discoveredBackends, phase, conditions that are not True)" % (v, MCPNS),
            "serviceAccountName of the pod: %s; backends: %s; phase %s; conditions not True: %s" % (kj("get", "deploy", v, "-n", MCPNS)["spec"]["template"]["spec"].get("serviceAccountName"), b, ph, bad or "none"),
            "every backend ready" if ok else "a backend is not ready or a condition is False")
        names, txt, delta, note = functional(v, aud)
        base = S.get("base", {}).get(v)
        same = base and base[0] == names and (base[1] == txt) and ((base[2] or 0) > 0) == ((delta or 0) > 0)
        rec(3, "after-" + v, "YES" if (names and same) else "NO", "tools/list and tools/call echo_echo through %s (same request as before the switch)" % v,
            "tools: %s; call: %s; echo saw its own header on %s new request(s); %s\nbefore the switch: tools %s, call %s, header %s" % (names, txt, delta, note, base and base[0], base and base[1], base and base[2]),
            "same as before the switch" if same else "differs from before the switch")


def q4():
    for v in VMCPS:
        for verb in ("get", "list"):
            out = sh("kubectl", "auth", "can-i", verb, "secrets", "-n", MCPNS, "--as=system:serviceaccount:%s:spike-%s" % (MCPNS, v)).strip()
            rec(4, "can-i-%s-%s" % (verb, v), "YES" if out.startswith("no") else "NO", "kubectl auth can-i %s secrets -n %s --as=system:serviceaccount:%s:spike-%s" % (verb, MCPNS, MCPNS, v), out,
                "no, as expected" if out.startswith("no") else "the account can %s Secrets" % verb)
    # a pod that runs as the account reads through the API
    script = ('T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); C=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt; '
              'for p in secrets/echo-mcp-auth configmaps/kube-root-ca.crt; do '
              'echo "$p $(curl -s -m 10 -o /dev/null -w %{http_code} --cacert $C -H "Authorization: Bearer $T" https://kubernetes.default.svc/api/v1/namespaces/' + MCPNS + '/$p)"; done; '
              'echo "list-secrets $(curl -s -m 10 -o /dev/null -w %{http_code} --cacert $C -H "Authorization: Bearer $T" https://kubernetes.default.svc/api/v1/namespaces/' + MCPNS + '/secrets)"')
    for label, sa in [("spike-tools-disputes", "spike-tools-disputes"), ("spike-tools", "spike-tools"), ("control: the operator's old account", S["old_sa"].get("tools-disputes", "tools-disputes-vmcp"))]:
        name = "spike-reader-" + re.sub(r"[^a-z0-9]", "", label)[:20]
        k("delete", "pod", name, "-n", MCPNS, "--ignore-not-found", "--wait=true")
        rc, out, err = k("run", name, "-n", MCPNS, "--image=curlimages/curl:8.10.1", "--restart=Never", "--rm", "-i", "--quiet",
                         "--overrides", json.dumps({"spec": {"serviceAccountName": sa, "containers": [{"name": name, "image": "curlimages/curl:8.10.1", "command": ["sh", "-c", script],
                                                                                                          "securityContext": {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}, "runAsNonRoot": True, "runAsUser": 100, "seccompProfile": {"type": "RuntimeDefault"}}}]}}),
                         timeout=180)
        rec(4, "pod-as-" + re.sub(r"[^a-z0-9]", "", label), "INFO", "a pod in %s as ServiceAccount %s runs curl with its own token against the API: GET the Secret echo-mcp-auth, GET the ConfigMap kube-root-ca.crt, GET the list of Secrets" % (MCPNS, sa),
            "HTTP codes: %s %s" % (short(out.replace("\n", "; "), 300), short(err, 200)), "")


def q5():
    for v in VMCPS:
        lines = log_errors(v)
        rec(5, "logs-" + v, "YES" if not lines else "NO", "kubectl logs of every pod of %s since the switch, lines that match forbidden, cannot get/list/watch, rbac, unauthorized, not allowed" % v,
            "%d line(s). %s" % (len(lines), " || ".join(short(x, 300) for x in lines[:4])), "no refused read" if not lines else "refused reads are in the log")
    # an entry added while the tool servers run, and a backend restart
    ex = kjs("get", "mcpserverentry", "other", "-n", MCPNS)
    if ex:
        late = {"apiVersion": ex["apiVersion"], "kind": ex["kind"], "metadata": {"name": "late", "namespace": MCPNS}, "spec": ex["spec"]}
        apply(late)
    time.sleep(45)
    k("rollout", "restart", "deploy/echo", "-n", ENS)
    k("rollout", "status", "deploy/echo", "-n", ENS, "--timeout=120s", timeout=140)
    time.sleep(30)
    b, ph, bad = backends("tools-disputes")
    lines = log_errors("tools-disputes", "10m") + log_errors("tools", "10m")
    rec(5, "logs-entry-added-backend-restarted", "YES" if not lines else "NO",
        "an MCPServerEntry `late` (a copy of the entry `other`) added to the group disputes while the tool servers run; then kubectl rollout restart deploy/echo -n %s; logs of tools-disputes and tools after 75 s" % ENS,
        "backends of tools-disputes: %s; phase %s; matching log lines: %d %s" % (b, ph, len(lines), " || ".join(short(x, 250) for x in lines[:3])),
        "no refused read while an entry was added and a backend restarted" if not lines else "refused reads in the log")
    S["late_backends"] = b


# ------------------------------------------------------------------ Q6: the workload variant
def q6():
    ns = "spike-wl"
    apply({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": ns}})
    apply({"apiVersion": "v1", "kind": "ServiceAccount", "metadata": {"name": "agent", "namespace": ns}})
    apply({"apiVersion": "toolhive.stacklok.dev/v1beta1", "kind": "MCPOIDCConfig", "metadata": {"name": "spike-workload-sa", "namespace": MCPNS},
           "spec": {"type": "kubernetesServiceAccount", "kubernetesServiceAccount": {"issuer": "https://kubernetes.default.svc.cluster.local", "jwksUrl": "https://kubernetes.default.svc/openid/v1/jwks", "useClusterAuth": True}}})
    apply_rbac("tools-disputes-workload")
    base = kj("get", "virtualmcpserver", "tools-disputes", "-n", MCPNS)
    spec = base["spec"]
    when = ' when { context.claim_sub like "system:serviceaccount:%s:*" && context has "claim_kubernetes.io" && context["claim_kubernetes.io"] has pod }' % ns
    pol = ['permit(principal, action == Action::"call_tool", resource == Tool::"echo_echo")%s;' % when, 'permit(principal, action == Action::"call_tool", resource == Tool::"echo_list_notes")%s;' % when,
           'permit(principal, action == Action::"list_tools", resource)%s;' % when]
    spec["incomingAuth"] = {"type": "oidc", "oidcConfigRef": {"name": "spike-workload-sa", "audience": "openagentix-vmcp-disputes-workload"}, "authzConfig": {"type": "inline", "inline": {"policies": pol}}}
    spec["serviceAccount"] = "spike-tools-disputes-workload"
    doc = {"apiVersion": base["apiVersion"], "kind": base["kind"], "metadata": {"name": "tools-disputes-workload", "namespace": MCPNS}, "spec": spec}
    apply(doc)
    for _ in range(60):
        if kjs("get", "deploy", "tools-disputes-workload", "-n", MCPNS):
            break
        time.sleep(3)
    wait_rollout("tools-disputes-workload")
    ready = wait_ready("tools-disputes-workload")
    # a pod in the workload namespace, and its pod-bound token
    k("delete", "pod", "wl-pod", "-n", ns, "--ignore-not-found")
    apply({"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "wl-pod", "namespace": ns},
           "spec": {"serviceAccountName": "agent", "containers": [{"name": "p", "image": "curlimages/curl:8.10.1", "command": ["sleep", "3600"],
                                                                    "securityContext": {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}, "runAsNonRoot": True, "runAsUser": 100, "seccompProfile": {"type": "RuntimeDefault"}}}]}})
    k("wait", "pod/wl-pod", "-n", ns, "--for=condition=Ready", "--timeout=120s", timeout=140)
    aud = "openagentix-vmcp-disputes-workload"
    tk_pod = token(aud, ns, "agent", ("--bound-object-kind", "Pod", "--bound-object-name", "wl-pod"))
    tk_plain = token(aud, ns, "agent")
    tk_other = token("some-other-audience", ns, "agent", ("--bound-object-kind", "Pod", "--bound-object-name", "wl-pod"))
    res = []
    for label, tk in (("pod-bound token, right audience", tk_pod), ("pod-bound token, another audience", tk_other), ("token not bound to a pod, right audience", tk_plain)):
        c = Mcp("tools-disputes-workload", tk)
        try:
            r = c.open()
            if not c.sid:
                res.append("%s: initialize refused, HTTP %s %s" % (label, r["status"], short(r["body"], 120)))
                continue
            st, lst = c.call("tools/list")
            names = sorted(t["name"] for t in ((lst or {}).get("result") or {}).get("tools", []))
            before = echo_seen()
            st2, cr = c.call("tools/call", {"name": "echo_echo", "arguments": {"text": "adr0031 workload"}})
            txt = " ".join(x.get("text", "") for x in ((cr or {}).get("result") or {}).get("content", [])) or short(json.dumps(cr), 160)
            time.sleep(1)
            res.append("%s: session opened; tools/list %s; echo_echo -> %s; echo header seen on %d new request(s)" % (label, names, short(txt, 120), echo_seen() - before))
        finally:
            c.close()
    ok = ("session opened; tools/list ['echo_echo'" in res[0] or "echo_echo" in res[0]) and "refused" in res[1]
    rec(6, "workload-variant", "YES" if ok else "PARTLY", "a copy of tools-disputes named tools-disputes-workload with spec.serviceAccount spike-tools-disputes-workload, an MCPOIDCConfig of type kubernetesServiceAccount (issuer https://kubernetes.default.svc.cluster.local, useClusterAuth true), audience %s and a Cedar policy that allows echo_echo, echo_list_notes and list_tools only for subjects of the namespace %s with a pod claim; tokens from kubectl create token agent -n %s, with and without --bound-object-kind Pod" % (aud, ns, ns),
        "backends ready: %s\n" % ready + "\n".join(res), "accepts the pod-bound token and refuses the other audience" if ok else "see the lines")
    errs = log_errors("tools-disputes-workload")
    rec(5, "logs-workload", "YES" if not errs else "NO", "log lines of tools-disputes-workload that match forbidden or rbac", "%d line(s). %s" % (len(errs), " || ".join(short(x, 250) for x in errs[:3])))
    rec(2, "workload-backends", "YES" if ready else "NO", "status of tools-disputes-workload", "backends: %s" % (backends("tools-disputes-workload"),))


# ------------------------------------------------------------------ Q7, Q8, Q9
def q7():
    v = "tools-disputes"
    apply_rbac(v, configmaps=False)
    k("rollout", "restart", "deploy/" + v, "-n", MCPNS)
    wait_rollout(v)
    ready = wait_ready(v, 120)
    time.sleep(20)
    names, txt, delta, note = functional(v, VMCPS[v])
    errs = log_errors(v, "3m")
    b, ph, bad = backends(v)
    rec(7, "without-configmaps", "YES" if (ready and names and not errs) else "NO",
        "the Role spike-%s without the rule on configmaps (all else as before), then kubectl rollout restart deploy/%s" % (v, v),
        "rollout ok, backends: %s, phase %s, conditions not True: %s; tools: %s; call: %s; header seen on %s request(s); matching log lines: %d %s" % (b, ph, bad or "none", names, txt, delta, len(errs), " || ".join(short(x, 280) for x in errs[:3])),
        "enough without ConfigMap rights (on this install, which has no CA bundle on an entry)" if (ready and names and not errs) else "something breaks without ConfigMap rights: see the lines")
    apply_rbac(v, configmaps=True)
    time.sleep(75)


def q8():
    v = "tools-disputes"
    can = []
    for verb in ("update", "patch"):
        own = sh("kubectl", "auth", "can-i", verb, "virtualmcpservers.toolhive.stacklok.dev/" + v, "--subresource=status", "-n", MCPNS, "--as=system:serviceaccount:%s:spike-%s" % (MCPNS, v)).strip()
        oth = sh("kubectl", "auth", "can-i", verb, "virtualmcpservers.toolhive.stacklok.dev/tools", "--subresource=status", "-n", MCPNS, "--as=system:serviceaccount:%s:spike-%s" % (MCPNS, v)).strip()
        can.append("%s own status: %s; %s another tool server's status: %s" % (verb, own, verb, oth))
    o = kj("get", "virtualmcpserver", v, "-n", MCPNS, "--show-managed-fields")
    mf = [(m.get("manager"), m.get("operation"), m.get("subresource"), m.get("time")) for m in o["metadata"].get("managedFields", [])]
    st = o.get("status", {})
    # change something the status shows: add a backend and take it away again
    b0 = sorted(backends(v)[0])
    k("delete", "mcpserverentry", "late", "-n", MCPNS, "--ignore-not-found")
    time.sleep(40)
    b1 = sorted(backends(v)[0])
    o2 = kj("get", "virtualmcpserver", v, "-n", MCPNS, "--show-managed-fields")
    mf2 = [(m.get("manager"), m.get("operation"), m.get("subresource"), m.get("time")) for m in o2["metadata"].get("managedFields", [])]
    errs = log_errors(v, "100s")
    changed = b0 != b1
    rec(8, "status-resourcenames", "YES" if changed and not errs else "PARTLY",
        "kubectl auth can-i update and patch on virtualmcpservers/status for the own name and for the name `tools`, as spike-%s; then the entry `late` was deleted and the status read again" % v,
        "%s\nbackends before the delete: %s; 40 s after: %s\nmanagedFields before (manager, operation, subresource, time): %s\nafter: %s\nstatus conditions: %s\nmatching log lines in the tool server: %d" % (
            "\n".join(can), b0, b1, mf, mf2, [(c["type"], c["status"], c.get("lastTransitionTime")) for c in st.get("conditions", [])], len(errs)),
        "the status kept updating (the backend list changed) with the status right limited to the own object; see the managers for who wrote it" if changed and not errs else "see the lines")


def q9():
    names = ["%s-vmcp" % v for v in VMCPS]
    st = rbac_state(names)
    stays = {k_: bool(v) for k_, v in st.items()}
    same = {k_: (S["old_state"].get(k_) or {}).get("uid") == (v or {}).get("uid") for k_, v in st.items() if v}
    inuse = {v: kj("get", "deploy", v, "-n", MCPNS)["spec"]["template"]["spec"].get("serviceAccountName") for v in VMCPS}
    rec(9, "old-objects-stay", "YES" if all(stays.values()) else "NO", "after the switch of all four: get serviceaccount, role and rolebinding named <name>-vmcp",
        "present: %s\nowner references: %s\nuids unchanged: %s\naccounts now in use by the Deployments: %s" % (stays, {k_: (v or {}).get("owner") for k_, v in st.items()}, same, inuse),
        "the old objects stay after the switch" if all(stays.values()) else "some were removed by the operator")
    for n in names:
        k("delete", "rolebinding,role,serviceaccount", n, "-n", MCPNS, "--ignore-not-found")
    gone = [x for x, v in rbac_state(names).items() if v]
    for v in VMCPS:
        k("annotate", "virtualmcpserver", v, "-n", MCPNS, "adr0031/touch=%d" % time.time(), "--overwrite")
    k("patch", "virtualmcpserver", "tools-lookup", "-n", MCPNS, "--type", "merge", "-p", json.dumps({"spec": {"config": {"aggregation": {"conflictResolution": "prefix", "conflictResolutionConfig": {"prefixFormat": "{workload}_"}}}}}))
    time.sleep(60)
    k("rollout", "restart", "deploy/toolhive-operator", "-n", TH)
    k("rollout", "status", "deploy/toolhive-operator", "-n", TH, "--timeout=180s", timeout=200)
    time.sleep(90)
    again = [x for x, v in rbac_state(names).items() if v]
    okb = all(wait_ready(v, 60) for v in VMCPS)
    rec(9, "deleted-not-recreated", "YES" if not again else "NO",
        "deleted the old ServiceAccount, Role and RoleBinding of the four tool servers; then an annotation event on each, a spec change on tools-lookup, 60 s, a restart of the operator, 90 s; then listed them again",
        "still present right after the delete: %s; present after the events, the requeue time and the operator restart: %s; every tool server still has all backends ready: %s" % (gone or "none", again or "none", okb),
        "not created again" if not again else "the operator made them again")
    rec(9, "hand-written-intact", "INFO", "uid, resourceVersion and rules of spike-<name> compared with the state right after they were applied",
        "unchanged: %s" % {x: (S["rb"].get(x) or {}).get("uid") == (v or {}).get("uid") and (S["rb"].get(x) or {}).get("rules") == (v or {}).get("rules") for x, v in rbac_state(["spike-" + v for v in VMCPS]).items()})


def q11():
    items = [("create", "pods"), ("create", "statefulsets.apps"), ("create", "deployments.apps"), ("create", "pods/exec"), ("create", "pods/attach")]
    for v in VMCPS:
        ans = []
        for verb, res in items:
            ans.append("%s %s: %s" % (verb, res, sh("kubectl", "auth", "can-i", verb, res, "-n", MCPNS, "--as=system:serviceaccount:%s:spike-%s" % (MCPNS, v)).strip()))
        no = all(x.endswith(": no") for x in ans)
        rec(11, "can-i-" + v, "YES" if no else "NO", "kubectl auth can-i <verb> <resource> -n %s --as=system:serviceaccount:%s:spike-%s, for the five pairs below" % (MCPNS, MCPNS, v), "; ".join(ans),
            "no for all five" if no else "at least one answers yes")


def q12():
    out = []
    ms = kj("get", "mcpserver", "-n", MCPNS)["items"]
    for m in ms:
        n = m["metadata"]["name"]
        sas = set()
        for d in kj("get", "deploy,statefulset", "-n", MCPNS)["items"]:
            if d["metadata"]["name"] == n or d["metadata"]["name"].startswith(n):
                sas.add(d["spec"]["template"]["spec"].get("serviceAccountName") or "default")
        for sa in sorted(sas):
            a = sh("kubectl", "auth", "can-i", "create", "statefulsets.apps", "-n", MCPNS, "--as=system:serviceaccount:%s:%s" % (MCPNS, sa)).strip()
            b = sh("kubectl", "auth", "can-i", "create", "services", "-n", MCPNS, "--as=system:serviceaccount:%s:%s" % (MCPNS, sa)).strip()
            out.append("MCPServer %s, account %s: create statefulsets %s; create services %s" % (n, sa, a, b))
    rec(12, "proxy-runner-accounts", "INFO", "for each MCPServer in %s, the ServiceAccount of its workloads (from the Deployment or StatefulSet), then kubectl auth can-i create statefulsets.apps and create services -n %s --as=system:serviceaccount:%s:<account>" % (MCPNS, MCPNS, MCPNS),
        "\n".join(out) or "no MCPServer found")


def q13():
    v = "tools-disputes"
    secs = [s_["metadata"]["name"] for s_ in kj("get", "secret", "-n", MCPNS)["items"] if re.search(r"hmac|session|key", s_["metadata"]["name"])]
    mine = {x: [s_ for s_ in secs if s_.startswith(x)] for x in VMCPS}
    rec(13, "session-secret", "INFO", "kubectl get secret -n %s, names that hold hmac, session or key; which of them belong to which tool server" % MCPNS,
        "per tool server: %s\nall matching: %s" % (mine, secs), "the operator still made a session secret for each tool server" if all(mine.values()) else "no session secret is listed for some tool server")
    c = Mcp(v, token(VMCPS[v]))
    try:
        c.open()
        st0, l0 = c.call("tools/list")
        sid = c.sid
    finally:
        c.close()
    k("rollout", "restart", "deploy/" + v, "-n", MCPNS)
    wait_rollout(v)
    wait_ready(v, 120)
    time.sleep(10)
    c2 = Mcp(v, token(VMCPS[v]))
    try:
        c2.sid = sid
        c2.n = 10
        t0 = time.time()
        st1, l1 = c2.call("tools/list")
        old = "status %s in %.1f s: %s" % (st1, time.time() - t0, short(json.dumps(l1), 220))
        c2.sid = None
        c2.open()
        st2, l2 = c2.call("tools/list")
        new = "a new session: status %s, %d tools" % (st2, len(((l2 or {}).get("result") or {}).get("tools", [])))
    finally:
        c2.close()
    rec(13, "session-across-restart", "INFO", "open a session on tools-disputes (initialize, tools/list), kubectl rollout restart deploy/%s, then tools/list with the OLD Mcp-Session-Id, then a new initialize" % v,
        "before: status %s, %d tools\nold session after the restart: %s\n%s" % (st0, len(((l0 or {}).get("result") or {}).get("tools", [])), old, new))


def q14():
    names = ["spike-" + v for v in VMCPS]
    before = rbac_state(names)
    env = dict(os.environ, PROFILE="quickstart", VALUES_FILE="hack/ci/endpoints-ci-values.yaml", AGENT_WAIT="300s")
    t0 = time.time()
    try:
        r = subprocess.run(["./install.sh"], env=env, capture_output=True, text=True, timeout=1500)
        tail = (r.stdout + r.stderr)[-400:]
        rc = r.returncode
    except Exception as e:  # noqa: BLE001
        rc, tail = 99, str(e)
    mid = rbac_state(names)
    k("rollout", "restart", "deploy/toolhive-operator", "-n", TH)
    k("rollout", "status", "deploy/toolhive-operator", "-n", TH, "--timeout=180s", timeout=200)
    time.sleep(60)
    after = rbac_state(names)

    def diff(a, b):
        return [x for x in a if (a[x] or {}).get("uid") != (b[x] or {}).get("uid") or (a[x] or {}).get("rv") != (b[x] or {}).get("rv") or (a[x] or {}).get("rules") != (b[x] or {}).get("rules") or (a[x] or {}).get("subjects") != (b[x] or {}).get("subjects")]
    sa_now = {v: kj("get", "virtualmcpserver", v, "-n", MCPNS)["spec"].get("serviceAccount") for v in VMCPS}
    ok = not diff(before, mid) and not diff(mid, after)
    rec(14, "helm-upgrade-and-operator-restart", "YES" if ok else "NO",
        "PROFILE=quickstart VALUES_FILE=hack/ci/endpoints-ci-values.yaml ./install.sh again (a helm upgrade of the release, %.0f s, exit code %s), then kubectl rollout restart deploy/toolhive-operator and 60 s; compare uid, resourceVersion, rules and subjects of spike-<name> (ServiceAccount, Role, RoleBinding) before, after the upgrade, and after the restart" % (time.time() - t0, rc),
        "changed by the upgrade: %s\nchanged by the operator restart: %s\nspec.serviceAccount of each tool server after the upgrade and the restart: %s\nend of the installer output: %s" % (diff(before, mid) or "none", diff(mid, after) or "none", sa_now, short(tail, 300)),
        "the hand-written objects were left exactly as written" if ok else "see the lines")


def q15():
    out = []
    differ = False
    for v in VMCPS:
        b, a = S["podsrc_before"].get(v), podsrc(v)
        if not b or not a:
            out.append("%s: not read (before %s, after %s)" % (v, bool(b), bool(a)))
            continue
        bv, av = set(b["volumes"]), set(a["volumes"])
        be, ae = set(b["env"]), set(a["env"])
        bm, am = set(b["mounts"]), set(a["mounts"])
        d = {"account": (b["sa"], a["sa"]), "automount": (b["automount"], a["automount"]), "volumes new": sorted(av - bv), "volumes missing": sorted(bv - av), "env new": sorted(ae - be), "env missing": sorted(be - ae),
             "mounts new": sorted(am - bm), "mounts missing": sorted(bm - am)}
        differ = differ or any(d[x] for x in ("volumes new", "volumes missing", "env new", "env missing", "mounts new", "mounts missing"))
        out.append("%s: %s\n   volumes under the new account: %s\n   env sources under the new account: %s" % (v, json.dumps(d), a["volumes"], a["env"]))
    rec(15, "pod-sources", "NO" if differ else "YES", "the volumes, volume mounts and env sources of the running pod of each tool server, read before the switch (operator account) and after it (spike-<name>)", "\n".join(out),
        "something is new or missing under the new account: see the lines" if differ else "nothing new and nothing missing")


def facts2():
    secs = [s["metadata"]["name"] for s in kj("get", "secret", "-n", MCPNS)["items"]]
    out = []
    for v in VMCPS:
        d = kj("get", "deploy", v, "-n", MCPNS)
        c = d["spec"]["template"]["spec"]["containers"][0]
        envs = [(e["name"], (e.get("valueFrom") or {}).get("secretKeyRef", {}).get("name")) for e in c.get("env", []) if (e.get("valueFrom") or {}).get("secretKeyRef")]
        vols = [(x["name"], (x.get("secret") or {}).get("secretName")) for x in d["spec"]["template"]["spec"].get("volumes", []) if x.get("secret")]
        out.append("%s: secret env: %s; secret volumes: %s" % (v, envs, vols))
    rec("F", "session-secret", "INFO", "kubectl get secret -n %s (names); the env and volumes of each tool server Deployment that refer to a Secret" % MCPNS,
        "Secrets in the namespace: %s\n%s\nThe tool server accounts cannot read Secrets (Q4) and the tool servers run (Q2, Q3), so a Secret the pod needs is not read through the API." % (secs, "\n".join(out)))


def finish():
    write_results()
    for c in list(S.get("pf", [])):
        c.stop()


def main():
    setup()
    guard(facts, "F")
    guard(baseline, 4)
    guard(q1, 1)
    guard(switch, 10)
    guard(q2_q3, 2)
    guard(q4, 4)
    guard(q11, 11)
    guard(q12, 12)
    guard(q15, 15)
    guard(q5, 5)
    guard(q6, 6)
    guard(q7, 7)
    guard(q8, 8)
    guard(q9, 9)
    guard(facts2, "F")
    guard(q13, 13)
    guard(q14, 14)
    # the stop rule: if Q1 to Q4 did not hold, the same questions in inline mode
    failed = [x for x in R if x["q"] in (1, 2, 3, 4) and x["verdict"] in ("NO", "ERROR") and not x["id"].startswith("before")]
    rec("F", "stop-rule", "INFO", "Q1 to Q4 checked for a NO or an ERROR", "%d such record(s): %s" % (len(failed), [x["id"] for x in failed]),
        "all of Q1 to Q4 hold: the inline repeat was not needed" if not failed else "Q1 to Q4 did not all hold: see the inline pass")
    if failed:
        guard(inline_pass, "F")
    finish()
    return sum(1 for x in R if x["verdict"] == "ERROR")


def inline_pass():
    """A probe tool server with outgoingAuth.source inline and no serviceAccount: the operator's own account and Role, and the same checks."""
    apply({"apiVersion": "toolhive.stacklok.dev/v1beta1", "kind": "VirtualMCPServer", "metadata": {"name": "probe-inline", "namespace": MCPNS},
           "spec": {"groupRef": {"name": "disputes"}, "config": {"aggregation": {"conflictResolution": "prefix", "conflictResolutionConfig": {"prefixFormat": "{workload}_"}}},
                    "incomingAuth": {"type": "anonymous"}, "outgoingAuth": {"source": "inline"}}})
    for _ in range(60):
        if kjs("get", "deploy", "probe-inline", "-n", MCPNS):
            break
        time.sleep(3)
    wait_rollout("probe-inline")
    time.sleep(30)
    sa = kj("get", "deploy", "probe-inline", "-n", MCPNS)["spec"]["template"]["spec"].get("serviceAccountName")
    role = kjs("get", "role", "probe-inline-vmcp", "-n", MCPNS)
    cg = sh("kubectl", "auth", "can-i", "get", "secrets", "-n", MCPNS, "--as=system:serviceaccount:%s:%s" % (MCPNS, sa)).strip()
    cl = sh("kubectl", "auth", "can-i", "list", "secrets", "-n", MCPNS, "--as=system:serviceaccount:%s:%s" % (MCPNS, sa)).strip()
    b, ph, bad = backends("probe-inline")
    names, txt, delta, note = functional("probe-inline", "")
    rec("F", "inline-mode", "INFO", "a tool server probe-inline with outgoingAuth.source inline, no serviceAccount, in the group disputes",
        "account %s; its Role rules: %s\ncan-i get secrets: %s; list secrets: %s\nbackends: %s, phase %s, conditions not True: %s\ntools: %s; call: %s; header seen on %s request(s); %s" % (
            sa, short(json.dumps((role or {}).get("rules")), 700), cg, cl, b, ph, bad or "none", names, txt, delta, note))


if __name__ == "__main__":
    try:
        rc = main()
    except SystemExit:
        raise
    except Exception:  # noqa: BLE001
        rec("F", "fatal", "ERROR", "", traceback.format_exc()[-1800:])
        rc = 1
    sys.exit(1 if rc else 0)
