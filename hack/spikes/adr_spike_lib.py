"""Shared helpers for the ADR 0027 and ADR 0029 spikes (issue #229, PRs #260 and #262). Standard library only; run with `python3 -I`.

Nothing here changes the repository's chart, CRDs or services. A spike only observes a throwaway kind cluster on a hosted runner. The
helpers refuse to run anywhere else (GITHUB_ACTIONS=true and a kind context are required).
"""
import json
import os
import socket
import subprocess
import sys
import threading
import time
import traceback
import urllib.error
import urllib.request

SPIKE_NS = "spike-adr"
CFG = None  # (out_dir, title, qnames, stem): set by a spike so that every record is written to disk at once
R = []  # every record: {q, id, verdict, request, seen, answer}
_T0 = time.time()


def require_ci():
    ctx = subprocess.run(["kubectl", "config", "current-context"], capture_output=True, text=True).stdout.strip()
    if os.environ.get("GITHUB_ACTIONS") != "true" or not ctx.startswith("kind-"):
        print("refusing to run: this spike changes the cluster it runs on and is for a throwaway kind cluster in GitHub Actions "
              "(GITHUB_ACTIONS=true and a kind context). Context: %r" % ctx, file=sys.stderr)
        sys.exit(2)
    return ctx


def say(msg):
    print("[%5.0fs] %s" % (time.time() - _T0, msg), flush=True)


def rec(q, cid, verdict, request, seen, answer=""):
    """verdict: YES, NO, PARTLY, INFO or ERROR. `request` is the exact request or manifest, `seen` what came back."""
    R.append({"q": q, "id": cid, "verdict": verdict, "request": request, "seen": seen, "answer": answer})
    if CFG:
        try:
            write_results(*CFG)
        except Exception:  # noqa: BLE001
            pass
    say("%s %s -> %s %s" % (q, cid, verdict, (answer or seen)[:160].replace("\n", " ")))


def guarded(fn, q):
    try:
        fn()
    except Exception:  # noqa: BLE001
        rec(q, fn.__name__, "ERROR", "", traceback.format_exc()[-1500:])


def k(*args, timeout=90, stdin=None):
    """kubectl: returns (returncode, stdout, stderr)."""
    try:
        r = subprocess.run(["kubectl", *args], capture_output=True, text=True, timeout=timeout, input=stdin)
        return r.returncode, r.stdout, r.stderr
    except Exception as e:  # noqa: BLE001
        return 99, "", "[kubectl error] %s" % e


def kjson(*args):
    rc, out, err = k(*args, "-o", "json")
    if rc:
        raise RuntimeError("kubectl %s: %s" % (" ".join(args), err.strip()[:300]))
    return json.loads(out)


def apply(manifest):
    rc, out, err = k("apply", "-f", "-", stdin=manifest if isinstance(manifest, str) else json.dumps(manifest))
    if rc:
        raise RuntimeError("apply failed: " + err.strip()[:500])
    return out


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class PF:
    """A kubectl port-forward on a free local port."""

    def __init__(self, ns, target, remote):
        self.port = free_port()
        self.p = subprocess.Popen(["kubectl", "port-forward", "-n", ns, target, "%d:%s" % (self.port, remote)],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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


def http(method, url, headers=None, body=None, timeout=30):
    """One HTTP call that never raises: {status, headers, body, elapsed, error}."""
    data = body.encode() if isinstance(body, str) else body
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    t0 = time.time()
    out = {"status": None, "headers": {}, "body": "", "elapsed": 0.0, "error": ""}
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            out["status"], out["headers"], out["body"] = r.status, dict(r.headers), r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        out["status"], out["headers"] = e.code, dict(e.headers)
        out["body"] = e.read().decode("utf-8", "replace")
    except Exception as e:  # noqa: BLE001
        out["error"] = "%s: %s" % (type(e).__name__, e)
    out["elapsed"] = round(time.time() - t0, 2)
    return out


def parallel(fns):
    """Run callables at the same time (all start behind one barrier); returns their results in order."""
    n = len(fns)
    barrier = threading.Barrier(n)
    res = [None] * n

    def run(i):
        try:
            barrier.wait(30)
            res[i] = fns[i]()
        except Exception as e:  # noqa: BLE001
            res[i] = {"status": None, "error": "%s: %s" % (type(e).__name__, e), "body": "", "headers": {}, "elapsed": 0}

    ts = [threading.Thread(target=run, args=(i,)) for i in range(n)]
    for t in ts:
        t.start()
    for t in ts:
        t.join(300)
    return res


def short(s, n=400):
    s = (s or "").replace("\n", " ")
    return s if len(s) <= n else s[:n] + "...[+%d]" % (len(s) - n)


def ensure_slow_proxy(here):
    """The stand-in in front of the stub model: records every model request and delays a request whose text holds SLOWRUN."""
    apply({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": SPIKE_NS}})
    src = open(os.path.join(here, "adr_slow_model.py")).read()
    apply({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "slow-model-src", "namespace": SPIKE_NS}, "data": {"slow_model.py": src}})
    apply({"apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": "slow-model", "namespace": SPIKE_NS},
           "spec": {"replicas": 1, "selector": {"matchLabels": {"app": "slow-model"}},
                    "template": {"metadata": {"labels": {"app": "slow-model"}},
                                 "spec": {"containers": [{"name": "m", "image": "python:3.12-alpine", "command": ["python", "-u", "/src/slow_model.py"],
                                                          "env": [{"name": "SLOW_SECONDS", "value": "25"}],
                                                          "ports": [{"containerPort": 8080}],
                                                          "readinessProbe": {"httpGet": {"path": "/healthz", "port": 8080}},
                                                          "volumeMounts": [{"name": "src", "mountPath": "/src"}]}],
                                          "volumes": [{"name": "src", "configMap": {"name": "slow-model-src"}}]}}}})
    apply({"apiVersion": "v1", "kind": "Service", "metadata": {"name": "slow-model", "namespace": SPIKE_NS},
           "spec": {"selector": {"app": "slow-model"}, "ports": [{"port": 8080, "targetPort": 8080}]}})
    # the stub model's own NetworkPolicy admits only the gateway pods: an extra, additive policy lets the stand-in reach it
    apply({"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": {"name": "spike-allow-stand-in", "namespace": "agentgateway-system"},
           "spec": {"podSelector": {"matchLabels": {"app": "stub-model"}}, "policyTypes": ["Ingress"],
                    "ingress": [{"ports": [{"protocol": "TCP", "port": 8080},],
                                 "from": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": SPIKE_NS}}, "podSelector": {"matchLabels": {"app": "slow-model"}}}]}]}})
    rc, out, err = k("rollout", "status", "deploy/slow-model", "-n", SPIKE_NS, "--timeout=240s", timeout=260)
    if rc:
        raise RuntimeError("slow-model not ready: " + (out + err)[-400:])
    # the quick start's model now answers through the stand-in; the stand-in forwards to the stub model unchanged
    rc, out, err = k("patch", "agentgatewaymodel", "quickstart-model", "-n", "agentgateway-system", "--type", "merge", "-p",
                     json.dumps({"spec": {"baseURL": "http://slow-model.%s.svc.cluster.local:8080/v1" % SPIKE_NS}}))
    if rc:
        raise RuntimeError("patch of the model failed: " + err.strip()[:400])
    say("quickstart-model now goes through the stand-in: " + out.strip())


def proxy_events():
    pf = PF(SPIKE_NS, "svc/slow-model", "8080")
    try:
        r = http("GET", "http://127.0.0.1:%d/events" % pf.port, timeout=20)
        return json.loads(r["body"]) if r["status"] == 200 else []
    finally:
        pf.stop()


def write_results(out_dir, title, qnames, stem="results"):
    os.makedirs(out_dir, exist_ok=True)
    json.dump(R, open(os.path.join(out_dir, stem + ".json"), "w"), indent=1)
    md = ["## " + title, ""]
    for q in qnames:
        md += ["### " + q, ""]
        for x in [x for x in R if x["q"] == q]:
            md += ["**%s** (%s)" % (x["id"], x["verdict"]), ""]
            if x["request"]:
                md += ["Request or manifest:", "", "```", x["request"].rstrip(), "```", ""]
            md += ["Seen:", "", "```", (x["seen"] or "").rstrip(), "```", ""]
            if x["answer"]:
                md += ["Answer: " + x["answer"], ""]
    open(os.path.join(out_dir, stem + ".md"), "w").write("\n".join(md))
    return sum(1 for x in R if x["verdict"] == "ERROR")
