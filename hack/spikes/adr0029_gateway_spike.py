"""Spike A for ADR 0029 (PR #262, issue #229): budget classes in the model gateway policy. Standard library only; run with `python3 -I`.

Run it on a cluster that `PROFILE=quickstart ./install.sh` set up (agentgateway as pinned by components/model-gateway/install.sh, the stub model
as the only backend, no paid call). It changes the cluster: it replaces `spec.traffic.rateLimit` of the one gateway policy, adds a ConfigMap of test
keys and puts a recording stand-in in front of the stub model. It refuses to run outside GitHub Actions on a kind cluster.

Questions (the numbers are those of the task):
  1 does a policy expression see a per-key metadata member (`budget_class`)?
  2 what does a key without the member get?
  3 does changing a key's class start a fresh full bucket?
  4 does a conditional rate limit work with API key authentication and with retry?
  5 with K parallel calls against a nearly empty bucket, how many are admitted?
  6 what happens to the counters when the gateway pod restarts, and with two replicas?
"""
import hashlib
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import adr_spike_lib as L  # noqa: E402
from adr_spike_lib import k, kjson, rec, say, short  # noqa: E402

GW_NS = "agentgateway-system"
CM = "spike-keys"
ALPHA, BETA, GAMMA, FALLBACK = 100, 250, 100, 400   # tokens per hour in the spike policy
OUT = os.environ.get("SPIKE_OUT", "spike-out")
Q = {1: "A1 can a policy expression see a per-key metadata member?",
     2: "A2 what does a key without that member get?",
     3: "A3 does changing a key's class start a fresh full bucket?",
     4: "A4 does a conditional rate limit work with API key authentication and with retry?",
     5: "A5 K parallel calls against a nearly empty bucket: how many are admitted?",
     6: "A6 gateway restart and two replicas"}
KEYS = {}      # name -> [secret, class or None]
STATE = {}


def body_for(label):
    return json.dumps({"model": "quickstart-model", "stream": False, "messages": [{"role": "user", "content": "spike ping %s" % label}]})


def chat(port, name, label=None, secret=None):
    key = secret if secret is not None else (KEYS[name][0] if name in KEYS else "")
    h = {"Content-Type": "application/json"}
    if key:
        h["Authorization"] = "Bearer " + key
    r = L.http("POST", "http://127.0.0.1:%d/v1/chat/completions" % port, h, body_for(label or name), 30)
    tokens = 0
    try:
        tokens = json.loads(r["body"])["usage"]["total_tokens"]
    except Exception:  # noqa: BLE001
        pass
    r["tokens"] = tokens
    return r


def entry(name):
    secret, cls = KEYS[name]
    meta = {"user_id": name}
    if cls is not None:
        meta["budget_class"] = cls
    return json.dumps({"keyHash": "sha256:" + hashlib.sha256(secret.encode()).hexdigest(), "metadata": meta}, separators=(",", ":"))


def publish_keys():
    L.apply({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": CM, "namespace": GW_NS, "labels": {"agentgateway.dev/apikey": "true"}},
             "data": {n: entry(n) for n in KEYS}})


def newkey(name, cls):
    KEYS[name] = ["vk-spike-" + os.urandom(12).hex(), cls]


def drain(port, name, limit=80, label=None):
    """Sequential calls until the first 429. Returns (statuses, admitted, tokens counted, per-call cost)."""
    st, tok = [], 0
    for i in range(limit):
        r = chat(port, name, "%s #%d" % (label or name, i))
        st.append(r["status"])
        if r["status"] == 429:
            break
        if len(st) >= 4 and all(x not in (200, 429) for x in st[-4:]):
            break   # the gateway is not answering: do not spend 30 s on every call
        if r["status"] == 200:
            tok += r["tokens"]
    adm = sum(1 for s in st if s == 200)
    return st, adm, tok, (round(tok / adm, 1) if adm else 0)


def compress(st):
    out, prev, n = [], None, 0
    for s in st + [object()]:
        if s == prev:
            n += 1
        else:
            if prev is not None:
                out.append("%sx%d" % (prev, n))
            prev, n = s, 1
    return " ".join(out)


def policy_name():
    items = kjson("get", "agentgatewaypolicy", "-n", GW_NS)["items"]
    for p in items:
        if "apiKeyAuthentication" in (p["spec"].get("traffic") or {}):
            return p["metadata"]["name"]
    raise RuntimeError("no gateway policy with apiKeyAuthentication in %s" % GW_NS)


def spike_rate_limit():
    def local(tokens, key=True):
        e = {"tokens": tokens, "unit": "Hours"}
        if key:
            e["key"] = "apiKey.user_id"
        return {"local": [e]}
    return {"conditional": [
        {"condition": 'apiKey.budget_class == "alpha"', "policy": local(ALPHA)},
        {"condition": 'apiKey.budget_class == "beta"', "policy": local(BETA)},
        {"condition": 'apiKey.budget_class == "gamma"', "policy": local(GAMMA, key=False)},   # per: class, no key: one shared bucket
        {"policy": local(FALLBACK)},
    ]}


def setup():
    L.ensure_slow_proxy(os.path.dirname(os.path.abspath(__file__)))
    imgs = k("get", "deploy", "-n", GW_NS, "-o", "jsonpath={range .items[*]}{.metadata.name}={.spec.template.spec.containers[*].image}{\"\\n\"}{end}")[1]
    helm = k("get", "pods", "-n", GW_NS, "-o", "jsonpath={range .items[*]}{.metadata.name} {.spec.containers[*].image}{\"\\n\"}{end}")[1]
    rec(Q[1], "version", "INFO", "kubectl get deploy,pods -n %s (images)" % GW_NS, imgs + helm)
    name = policy_name()
    STATE["policy"] = name
    orig = kjson("get", "agentgatewaypolicy", name, "-n", GW_NS)["spec"]["traffic"]
    STATE["orig_traffic"] = orig
    for n, c in (("kprobe", "alpha"), ("ka1", "alpha"), ("kb1", "beta"), ("kn1", None), ("kn2", None), ("kz1", "zeta"), ("kg1", "gamma"), ("kg2", "gamma"),
                 ("kc1", "alpha"), ("kretry", "alpha"), ("kr1", "alpha"), ("kr2", "alpha"), ("kr3", "alpha"), ("kr4", "alpha"),
                 ("ko0", "alpha"), ("ko1", "alpha"), ("ko2", "alpha"), ("ko3", "alpha"), ("ko4", "alpha"), ("kauth", "alpha")):
        newkey(n, c)
    publish_keys()
    patch = [{"op": "replace", "path": "/spec/traffic/rateLimit", "value": spike_rate_limit()}]
    rc, out, err = k("patch", "agentgatewaypolicy", name, "-n", GW_NS, "--type", "json", "-p", json.dumps(patch))
    rec(Q[1], "policy-patch", "INFO" if rc == 0 else "NO", "kubectl patch agentgatewaypolicy %s -n %s --type json -p '%s'" % (name, GW_NS, json.dumps(patch)),
        (out + err).strip(), "the API server accepted the conditional rate limit" if rc == 0 else "the API server refused the conditional rate limit")
    if rc:
        raise RuntimeError("policy patch refused")
    time.sleep(3)
    st = k("get", "agentgatewaypolicy", name, "-n", GW_NS, "-o", "jsonpath={.status}")[1]
    rec(Q[1], "policy-status", "INFO", "kubectl get agentgatewaypolicy %s -o jsonpath={.status}" % name, short(st, 1500))
    pf = L.PF(GW_NS, "svc/model-gateway", "80")
    STATE["pf"] = pf
    # wait until the new keys and the new policy are live: the probe key (alpha, 100 tokens) must reach 429
    t0 = time.time()
    seen = []
    while time.time() - t0 < 180:
        r = chat(pf.port, "kprobe")
        seen.append(r["status"])
        if r["status"] == 429:
            break
        time.sleep(2)
    rec(Q[1], "warmup", "INFO", "calls with key kprobe (class alpha) every 2 s until the first 429", "statuses: %s after %.0f s" % (compress(seen), time.time() - t0))


def q1():
    pf = STATE["pf"]
    sa, adm_a, tok_a, c_a = drain(pf.port, "ka1")
    sb, adm_b, tok_b, c_b = drain(pf.port, "kb1")
    ok = adm_a >= 1 and sa[-1] == 429 and sb[-1] == 429 and tok_a < FALLBACK and adm_b > adm_a
    rec(Q[1], "classes-differ", "YES" if ok else "NO",
        "POST /v1/chat/completions, key ka1 (metadata.budget_class=alpha, limit %d tokens/h), then key kb1 (beta, %d), one call at a time until 429" % (ALPHA, BETA),
        "ka1: statuses %s, admitted %d, tokens counted %d (about %s each); kb1: statuses %s, admitted %d, tokens counted %d" % (compress(sa), adm_a, tok_a, c_a, compress(sb), adm_b, tok_b),
        "yes: each class got its own limit" if ok else "no clear sign that the condition matched")
    # per class, no key: one shared bucket
    s1, a1, t1, _ = drain(pf.port, "kg1")
    s2 = [chat(pf.port, "kg2", "kg2 #%d" % i)["status"] for i in range(3)]
    rec(Q[1], "shared-class", "INFO", "keys kg1 and kg2 (both budget_class=gamma, policy entry with no `key`, %d tokens/h): drain kg1, then 3 calls with kg2" % GAMMA,
        "kg1: statuses %s (admitted %d, tokens %d); kg2 then: %s" % (compress(s1), a1, t1, compress(s2)),
        "one bucket for the class" if s2 and all(x == 429 for x in s2) else "kg2 had its own admission")


def q2():
    pf = STATE["pf"]
    s1, a1, t1, c1 = drain(pf.port, "kn1", limit=120)
    s2 = [chat(pf.port, "kn2", "kn2 #%d" % i)["status"] for i in range(2)]
    sz, az, tz, _ = drain(pf.port, "kz1", limit=120)
    first = s1[0]
    if first not in (200, 429):
        v, ans = "NO", "a key without the member got HTTP %s (an error or a deny)" % first
    elif t1 + c1 >= FALLBACK * 0.6 and s1[-1] == 429 and s2[0] == 200:
        v, ans = "YES", "fallback limit (%d): its own bucket per key, limit reached after %d tokens; a second key without the member was admitted" % (FALLBACK, t1)
    elif s2 and s2[0] == 429:
        v, ans = "PARTLY", "keys without the member shared one bucket (the second key got 429 at once)"
    else:
        v, ans = "PARTLY", "see the statuses"
    rec(Q[2], "no-member", v,
        "keys kn1, kn2: metadata has user_id only, no budget_class. Fallback entry %d tokens/h with key apiKey.user_id. kn1 one call at a time until 429, then 2 calls with kn2" % FALLBACK,
        "kn1: statuses %s (admitted %d, tokens counted %d); kn2 then: %s" % (compress(s1), a1, t1, compress(s2)), ans)
    rec(Q[2], "unknown-class", "INFO", "key kz1: budget_class=zeta (matches no condition), one call at a time until 429",
        "statuses %s (admitted %d, tokens counted %d)" % (compress(sz), az, tz),
        "same as a key without the member" if (sz[-1] == 429 and abs(tz - t1) <= 2 * max(c1, 1)) else "differs from a key without the member")


def q3():
    pf = STATE["pf"]
    sa, adm_a, tok_a, _ = drain(pf.port, "kc1")
    base = chat(pf.port, "kc1")["status"]
    t_switch = time.time()
    KEYS["kc1"][1] = "beta"
    publish_keys()
    t_first, polls = None, []
    while time.time() - t_switch < 150:
        r = chat(pf.port, "kc1", "kc1 poll")
        polls.append(r["status"])
        if r["status"] == 200 and t_first is None:
            t_first = round(time.time() - t_switch, 1)
            break
        time.sleep(2)
    admitted_beta = 1 if t_first is not None else 0
    if t_first is not None:
        s, a, t, _ = drain(pf.port, "kc1", label="kc1 beta")
        admitted_beta += a
    rec(Q[3], "alpha-to-beta", "YES" if t_first is not None else "NO",
        "key kc1 (alpha, 100 tokens/h): drain to 429, then edit its ConfigMap entry to budget_class=beta (kubectl apply of ConfigMap %s), then one call every 2 s" % CM,
        "alpha: %d calls admitted then 429; call before the edit: %s; first 200 after the edit: %s s; after that %d more calls admitted before 429 (a fresh beta bucket from kb1 admitted the number in A1)" % (
            adm_a, base, t_first, admitted_beta - 1 if t_first is not None else 0),
        "yes: the key got a new bucket after %s s" % t_first if t_first is not None else "no: still refused after 150 s")
    # and back to alpha
    sw = chat(pf.port, "kc1", "kc1 pre-back")["status"]
    KEYS["kc1"][1] = "alpha"
    publish_keys()
    t0 = time.time()
    first, back = None, []
    while time.time() - t0 < 150:
        r = chat(pf.port, "kc1", "kc1 back")
        back.append(r["status"])
        if r["status"] == 200:
            first = round(time.time() - t0, 1)
            break
        time.sleep(2)
    after = 0
    if first is not None:
        _, a, _, _ = drain(pf.port, "kc1", label="kc1 back")
        after = 1 + a
    rec(Q[3], "beta-to-alpha", "YES" if first is not None else "NO",
        "the same key kc1 after its beta bucket was used up: edit the entry back to budget_class=alpha, then one call every 2 s",
        "call before the edit: %s; first 200 after the edit: %s s; calls admitted in all: %d (the first alpha bucket of this key admitted %d)" % (sw, first, after, adm_a),
        "yes: moving back also gave a full bucket (%d calls vs %d)" % (after, adm_a) if first is not None and after >= max(1, adm_a - 1)
        else "the old alpha bucket was not full again" if first is not None else "no: still refused after 150 s")


def gw_log_lines(user):
    out = []
    for p in kjson("get", "pods", "-n", GW_NS)["items"]:
        if p["metadata"]["name"].startswith("model-gateway"):
            out += k("logs", "-n", GW_NS, p["metadata"]["name"], "--tail=4000")[1].splitlines()
    return [x for x in out if user in x]


def q4():
    pf = STATE["pf"]
    st = k("get", "agentgatewaypolicy", STATE["policy"], "-n", GW_NS, "-o", "json")[1]
    pol = json.loads(st)
    rec(Q[4], "one-policy", "INFO", "kubectl get agentgatewaypolicy %s -o json (spec.traffic keys and status)" % STATE["policy"],
        "spec.traffic keys: %s; retry: %s; status: %s" % (sorted(pol["spec"]["traffic"]), json.dumps(pol["spec"]["traffic"].get("retry")), short(json.dumps(pol.get("status")), 1200)),
        "apiKeyAuthentication, a conditional rateLimit and retry are in the one policy" if {"apiKeyAuthentication", "rateLimit", "retry"} <= set(pol["spec"]["traffic"]) else "")
    nokey = chat(pf.port, "x", secret="")
    bad = chat(pf.port, "x", secret="vk-not-a-key")
    ok = chat(pf.port, "kauth")
    rec(Q[4], "auth", "YES" if (nokey["status"] in (401, 403) and bad["status"] in (401, 403) and ok["status"] == 200) else "PARTLY",
        "POST /v1/chat/completions with no Authorization header; with a key that is not in any ConfigMap; with key kauth (alpha)",
        "no key: HTTP %s; unknown key: HTTP %s; kauth: HTTP %s" % (nokey["status"], bad["status"], ok["status"]),
        "authentication still runs first and the class limit applies to the key that passed" if ok["status"] == 200 else "")
    # retry: a call that the rate limit refuses; look at what the gateway logged and at what reached the stand-in
    drain(pf.port, "kretry")
    ev0 = len([e for e in L.proxy_events() if "kretry" in e["text"]])
    l0 = len(gw_log_lines("kretry"))
    time.sleep(1)
    r = chat(pf.port, "kretry", "kretry refused-probe")
    time.sleep(3)
    ev1 = len([e for e in L.proxy_events() if "kretry" in e["text"]])
    lines = gw_log_lines("kretry")
    hdr = {x: v for x, v in r["headers"].items() if x.lower() in ("retry-after", "x-ratelimit-limit", "x-ratelimit-remaining", "content-type")}
    rec(Q[4], "retry-on-gateway-429", "INFO",
        "key kretry (alpha) drained to 429, then ONE more call. The policy has retry attempts=2, codes [402,429,500,502,503,504]. Count the stand-in's requests and the gateway log lines for the key",
        "the call: HTTP %s in %ss, headers %s, body %s; model requests that reached the stand-in for this key: %d before, %d after (a refused call that was retried upstream would add some); "
        "gateway log lines for the key: %d before, %d after. Last lines: %s" % (r["status"], r["elapsed"], hdr, short(r["body"], 200), ev0, ev1, l0, len(lines), " || ".join(short(x, 380) for x in lines[-3:])),
        "a gateway 429 was not sent upstream, so it was not retried against the model" if ev1 == ev0 else "the refused call produced %d extra upstream request(s)" % (ev1 - ev0))


def q5():
    pf = STATE["pf"]
    _, n_seq, tok, cost = drain(pf.port, "ko0")
    res = []
    for kname, kk in (("ko1", 5), ("ko2", 10), ("ko3", 20), ("ko4", 20)):
        for i in range(max(0, n_seq - 1)):
            chat(pf.port, kname, "%s warm %d" % (kname, i))
        out = L.parallel([(lambda kn=kname, j=j: chat(pf.port, kn, "%s par %d" % (kn, j))) for j in range(kk)])
        adm = sum(1 for o in out if o["status"] == 200)
        r429 = sum(1 for o in out if o["status"] == 429)
        other = [o["status"] or o["error"] for o in out if o["status"] not in (200, 429)]
        res.append((kname, kk, adm, r429, other))
        rec(Q[5], "parallel-%d-%s" % (kk, kname), "YES" if adm > 1 else "NO",
            "key %s (alpha, %d tokens/h): %d sequential calls (a fresh bucket admits %d one at a time, about %s tokens each), so one more call fits; then %d calls at the same moment" % (kname, ALPHA, max(0, n_seq - 1), n_seq, cost, kk),
            "admitted %d, refused (429) %d, other %s" % (adm, r429, other),
            "%d of %d parallel calls admitted where a sequential caller gets 1" % (adm, kk))
    # control: after the bucket is refused, a parallel burst gets nothing
    out = L.parallel([(lambda j=j: chat(pf.port, "ko1", "ko1 after %d" % j)) for j in range(10)])
    rec(Q[5], "control-empty", "INFO", "key ko1 after its bucket was refused: 10 calls at the same moment",
        "statuses %s" % compress([o["status"] for o in out]), "")


def gw_pods():
    return [p["metadata"]["name"] for p in kjson("get", "pods", "-n", GW_NS)["items"]
            if p["metadata"]["name"].startswith("model-gateway") and p["status"].get("phase") == "Running"
            and all(c.get("ready") for c in p["status"].get("containerStatuses", []))]


def target_port():
    tp = k("get", "svc", "model-gateway", "-n", GW_NS, "-o", "jsonpath={.spec.ports[0].targetPort}")[1].strip()
    return tp if tp.isdigit() else "80"


def q6():
    pf = STATE["pf"]
    sd, adm, tok, _ = drain(pf.port, "kr1")
    before = chat(pf.port, "kr1", "kr1 before-restart")["status"]
    pods0 = gw_pods()
    pf.stop()
    for p in pods0:
        k("delete", "pod", p, "-n", GW_NS, "--wait=false")
    time.sleep(5)
    t0 = time.time()
    while time.time() - t0 < 180:
        n = gw_pods()
        if n and n != pods0 and not (set(n) & set(pods0)):
            break
        time.sleep(3)
    pf = L.PF(GW_NS, "svc/model-gateway", "80")
    STATE["pf"] = pf
    time.sleep(10)
    after = []
    t1 = time.time()
    while time.time() - t1 < 120:
        r = chat(pf.port, "kr1", "kr1 after-restart")
        after.append(r["status"])
        if r["status"] in (200, 429):
            break
        time.sleep(3)
    _, adm2, _, _ = drain(pf.port, "kr1", label="kr1 after2")
    rec(Q[6], "restart", "YES" if after and after[-1] == 200 else "NO",
        "key kr1 (alpha): drain to 429; delete the gateway proxy pod (%s); wait for the new pod; call with kr1 again" % ",".join(pods0),
        "before: admitted %d then 429 (one more call: %s); after the restart: first calls %s, then %d more admitted before 429 (first bucket admitted %d). The key ConfigMap and policy were not touched" % (
            adm, before, compress(after), adm2, adm),
        "the counters are gone: the key started with a full bucket" if after and after[-1] == 200 else "still refused after the restart")
    # two replicas
    dep = None
    for d in kjson("get", "deploy", "-n", GW_NS)["items"]:
        if d["metadata"]["name"].startswith("model-gateway"):
            dep = d["metadata"]["name"]
    k("scale", "deploy/%s" % dep, "-n", GW_NS, "--replicas=2")
    t0 = time.time()
    while time.time() - t0 < 150 and len(gw_pods()) < 2:
        time.sleep(3)
    time.sleep(25)   # does the controller put it back to 1?
    pods = gw_pods()
    reps = k("get", "deploy", dep, "-n", GW_NS, "-o", "jsonpath={.spec.replicas}")[1]
    if len(pods) < 2:
        rec(Q[6], "two-replicas", "NO", "kubectl scale deploy/%s -n %s --replicas=2" % (dep, GW_NS),
            "ready pods: %s, spec.replicas: %s (the controller may own the replica count; setting it through the gateway's own parameters object needs a values change, which this spike does not make)" % (pods, reps),
            "not tested: two replicas could not be held by a scale command")
        return
    tport = target_port()
    pa, pb = L.PF(GW_NS, "pod/%s" % pods[0], tport), L.PF(GW_NS, "pod/%s" % pods[1], tport)
    try:
        _, a_a, _, _ = drain(pa.port, "kr2")
        _, a_b, _, _ = drain(pb.port, "kr2", label="kr2 b")
        # through the Service (a new connection per call): how many calls does one key get in all?
        svc = L.PF(GW_NS, "svc/model-gateway", "80")
        try:
            st = []
            for i in range(40):
                st.append(chat(svc.port, "kr3", "kr3 svc %d" % i)["status"])
        finally:
            svc.stop()
        tot = sum(1 for s in st if s == 200)
        rec(Q[6], "two-replicas", "YES" if a_b >= 1 else "NO",
            "kubectl scale deploy/%s -n %s --replicas=2; port-forward to each pod; key kr2 drained on pod A then on pod B; key kr3: 40 sequential calls through the Service" % (dep, GW_NS),
            "pods %s; kr2 admitted %d on pod A, then %d on pod B (single replica: %d); kr3 through the Service: statuses %s, admitted %d" % (pods, a_a, a_b, adm, compress(st), tot),
            "each replica counts alone: the key got %d + %d admitted calls from two pods" % (a_a, a_b) if a_b >= 1 else "the second pod refused at once")
    finally:
        pa.stop()
        pb.stop()
        k("scale", "deploy/%s" % dep, "-n", GW_NS, "--replicas=1")


def main():
    L.require_ci()
    L.CFG = (OUT, "Spike A, ADR 0029: budget classes in the model gateway policy", [Q[i] for i in sorted(Q)], "results-adr0029")
    try:
        setup()
    except Exception as e:  # noqa: BLE001
        rec(Q[1], "setup", "ERROR", "", str(e))
        return finish()
    for fn, q in ((q1, 1), (q2, 2), (q3, 3), (q4, 4), (q5, 5), (q6, 6)):
        L.guarded(fn, Q[q])
    return finish()


def finish():
    try:
        if STATE.get("pf"):
            STATE["pf"].stop()
        if STATE.get("orig_traffic") is not None:
            rl = STATE["orig_traffic"].get("rateLimit")
            if rl is not None:
                k("patch", "agentgatewaypolicy", STATE["policy"], "-n", GW_NS, "--type", "json", "-p",
                  json.dumps([{"op": "replace", "path": "/spec/traffic/rateLimit", "value": rl}]))
        k("delete", "configmap", CM, "-n", GW_NS, "--ignore-not-found")
    finally:
        return L.write_results(*L.CFG)


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
