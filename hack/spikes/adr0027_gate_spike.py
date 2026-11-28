"""Spike B for ADR 0027 (PR #260, issue #229): what the runtime behind the A2A gate does. Standard library only; run with `python3 -I`.

Run it on a cluster that `PROFILE=quickstart ./install.sh` set up (kagent as pinned by components/runtime, the stub model, no paid call). It puts a
recording stand-in between the gateway and the stub model (so a run can be made slow, and each model request is counted). It refuses to run
outside GitHub Actions on a kind cluster. The calls go to the kagent controller's A2A port (the port the gate forwards to) and, for the first
question, also through the gate.

Questions:
  1 does the runtime honour a non-blocking send?
  2 what happens to a run when the client disconnects mid-call?
  3 the same messageId twice: one run or two?
  4 unknown keys and case variants of known keys in the message params
  5 memory of the gate pod under a burst, against its limit
"""
import json
import os
import re
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import adr_spike_lib as L  # noqa: E402
from adr_spike_lib import k, rec, say, short  # noqa: E402

OUT = os.environ.get("SPIKE_OUT", "spike-out")
Q = {1: "B1 non-blocking send",
     2: "B2 client disconnects mid-call",
     3: "B3 the same messageId twice",
     4: "B4 unknown keys and case variants in the message",
     5: "B5 memory of the gate pod under a burst"}
S = {}
SLOW = "SLOWRUN"          # the stand-in holds a model request with this word for 25 s
TERMINAL = ("completed", "failed", "canceled", "cancelled", "rejected")


def hdrs(target="direct"):
    h = {"Content-Type": "application/json", "A2A-Version": "1.0", "X-User-Id": "quickstart:ask"}
    if target == "gate":
        h["Authorization"] = "Bearer " + token()
    return h


def token():
    rc, out, err = k("create", "token", "quickstart-ask", "-n", "openagentix-system", "--audience", "openagentix-a2a", "--duration", "10m")
    if rc:
        k("create", "serviceaccount", "quickstart-ask", "-n", "openagentix-system")
        rc, out, err = k("create", "token", "quickstart-ask", "-n", "openagentix-system", "--audience", "openagentix-a2a", "--duration", "10m")
    return out.strip()


def url(target="direct"):
    return "http://127.0.0.1:%d/agents/kagent/quickstart" % S[target].port


def mid(tag):
    return "spike-%s-%s" % (tag, os.urandom(4).hex())


def msg(text, message_id, config=None, ctx=None, method="SendMessage"):
    m = {"messageId": message_id, "role": "ROLE_USER", "parts": [{"text": text}]}
    if ctx:
        m["contextId"] = ctx
    p = {"message": m}
    if config is not None:
        p["configuration"] = config
    return json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": p})


def call(body, target="direct", timeout=120):
    r = L.http("POST", url(target), hdrs(target), body, timeout)
    r["j"] = None
    try:
        r["j"] = json.loads(r["body"])
    except Exception:  # noqa: BLE001
        pass
    return r


def summ(r):
    """One line for a JSON-RPC answer."""
    if r["error"]:
        return "no answer: %s after %ss" % (r["error"], r["elapsed"])
    j = r.get("j")
    base = "HTTP %s in %ss; " % (r["status"], r["elapsed"])
    if not isinstance(j, dict):
        return base + "body: " + short(r["body"], 250)
    if j.get("error"):
        return base + "error " + short(json.dumps(j["error"]), 250)
    res = j.get("result") or {}
    t = res.get("task")
    if t:
        art = " ".join(p.get("text", "") for a in t.get("artifacts", []) for p in a.get("parts", []))
        return base + "task id=%s contextId=%s state=%s answer=%r" % (t.get("id"), t.get("contextId"), (t.get("status") or {}).get("state"), short(art, 90))
    if res.get("message"):
        return base + "message " + short(json.dumps(res["message"]), 200)
    if res.get("id"):
        return base + "task(flat) id=%s state=%s" % (res.get("id"), (res.get("status") or {}).get("state"))
    return base + "result " + short(json.dumps(res), 250)


def task_of(r):
    j = r.get("j") or {}
    res = j.get("result") or {}
    t = res.get("task") or (res if res.get("id") and res.get("status") else None) or {}
    return t.get("id"), (t.get("status") or {}).get("state"), t.get("contextId")


def get_task(tid, target="direct"):
    for method in ("GetTask", "tasks/get"):
        body = json.dumps({"jsonrpc": "2.0", "id": 2, "method": method, "params": {"id": tid}})
        r = call(body, target, 30)
        j = r.get("j") or {}
        if j.get("result"):
            res = j["result"]
            t = res.get("task") or res
            return (t.get("status") or {}).get("state"), method, r
        if not (j.get("error") and j["error"].get("code") in (-32601, -32001) and method == "GetTask"):
            return None, method, r
    return None, "GetTask", r


def events(marker):
    return [e for e in L.proxy_events() if marker in e["text"]]


def warmup():
    t0 = time.time()
    last = ""
    while time.time() - t0 < 420:
        r = call(msg("warm up hello", mid("warm")), timeout=120)
        last = summ(r)
        if r["status"] == 200 and (r.get("j") or {}).get("result"):
            break
        time.sleep(8)
    rec(Q[1], "warm-up", "INFO", "SendMessage to /agents/kagent/quickstart on the kagent controller port, until the agent answers", "%s (after %.0f s)" % (last, time.time() - t0))


def setup():
    L.require_ci()
    L.ensure_slow_proxy(os.path.dirname(os.path.abspath(__file__)))
    S["direct"] = L.PF("kagent", "svc/kagent-controller", "8083")
    S["gate"] = L.PF("openagentix-gateway", "svc/a2a-gate", "8080")
    img = k("get", "deploy", "-n", "kagent", "-o", "jsonpath={range .items[*]}{.metadata.name}={.spec.template.spec.containers[0].image}{\"\\n\"}{end}")[1]
    rec(Q[1], "versions", "INFO", "kubectl get deploy -n kagent (images)", img.strip())
    warmup()


def q1():
    def case(label, config, target="direct", poll=True):
        m = mid("b1")
        marker = "MARK-B1-%s-%s" % (label, os.urandom(3).hex())
        text = "%s %s" % (SLOW, marker)
        body = msg(text, m, config)
        t0 = time.time()
        r = call(body, target, 150)
        tid, state, ctx = task_of(r)
        line = "response after %ss: %s" % (r["elapsed"], summ(r))
        trail = []
        if poll and tid and not (state or "").lower().endswith(TERMINAL):
            t1 = time.time()
            last = None
            while time.time() - t1 < 100:
                st, meth, rr = get_task(tid, target)
                if st != last:
                    trail.append("+%.0fs %s" % (time.time() - t0, st))
                    last = st
                if st and st.lower().endswith(TERMINAL):
                    break
                time.sleep(2)
        ev = events(marker)
        evs = "; ".join("model request at +%.1fs, finished %s" % (e["t0"] - t0, ("+%.1fs" % (e["t1"] - t0)) if e["t1"] else "never") for e in ev)
        return r, line, trail, evs, tid, state

    ctl, line, trail, evs, tid, st = case("default", None)
    rec(Q[1], "control-default", "INFO", msg("%s MARK" % SLOW, "<id>", None), "no configuration. %s. task state trail: %s. %s" % (line, trail or "n/a", evs))
    out = {}
    for label, cfg in (("blocking-false", {"blocking": False}), ("return-immediately", {"returnImmediately": True}), ("blocking-true", {"blocking": True})):
        r, line, trail, evs, tid, st = case(label, cfg)
        out[label] = (r["elapsed"], st, trail)
        rec(Q[1], label, "INFO", msg("%s MARK" % SLOW, "<id>", cfg), "%s. state trail by GetTask: %s. %s" % (line, trail or "n/a", evs))
    r, line, trail, evs, tid, st = case("gate-blocking-false", {"blocking": False}, target="gate", poll=False)
    rec(Q[1], "through-the-gate", "INFO", "the same blocking:false request through the gate (POST /agents/kagent/quickstart on svc/a2a-gate, ServiceAccount token)", "%s. %s" % (line, evs))
    nb = out["blocking-false"]
    ri = out["return-immediately"]
    fast = lambda x: x[0] < 15   # noqa: E731
    honoured = [n for n, x in (("blocking:false", nb), ("returnImmediately:true", ri)) if fast(x)]
    final = [x[2][-1] if x[2] else None for x in (nb, ri)]
    rec(Q[1], "answer", "YES" if honoured else "NO", "", "control (no configuration): %ss; blocking:false: %ss, state in the answer %s; returnImmediately:true: %ss, state in the answer %s" % (
        ctl["elapsed"], nb[0], nb[1], ri[0], ri[1]),
        ("yes for %s: the call returned before the run ended (the run took about 25 s); see the task trail for whether it continued: %s" % (", ".join(honoured), final)) if honoured
        else "no: both forms waited for the run")


def find_tasks(ctx):
    """Tasks of one conversation: ListTasks, then the runtime's database."""
    info = []
    for method in ("ListTasks", "tasks/list"):
        r = call(json.dumps({"jsonrpc": "2.0", "id": 3, "method": method, "params": {"contextId": ctx}}), "direct", 30)
        j = r.get("j") or {}
        if j.get("result"):
            info.append("%s: %s" % (method, short(json.dumps(j["result"]), 500)))
            return info
        info.append("%s: HTTP %s %s" % (method, r["status"], short(json.dumps(j.get("error")) if j.get("error") else r["body"], 150)))
    rc, out, err = k("exec", "-n", "kagent", "kagent-pg-0", "--", "psql", "--no-psqlrc", "-U", "postgres", "-d", "kagent", "-tAc",
                     "select table_name||'.'||column_name from information_schema.columns where table_name ilike '%task%' order by 1")
    info.append("task tables and columns: " + short((out + err).replace("\n", ", "), 300))
    for tbl in ("task", "tasks"):
        rc, out, err = k("exec", "-n", "kagent", "kagent-pg-0", "--", "psql", "--no-psqlrc", "-U", "postgres", "-d", "kagent", "-tAc",
                         "select left(data::text, 400) from %s where data::text like '%%%s%%' limit 3" % (tbl, ctx))
        if rc == 0 and out.strip():
            info.append("database %s: %s" % (tbl, short(out, 800)))
            break
        info.append("database %s: %s" % (tbl, short((out + err), 150)))
    return info


def q2():
    ctx = "spike-disc-" + os.urandom(4).hex()
    marker = "MARK-B2-" + os.urandom(3).hex()
    body = msg("%s %s" % (SLOW, marker), mid("b2"), None, ctx)
    t0 = time.time()
    r = call(body, timeout=4)
    time.sleep(2)
    mid_ev = events(marker)
    time.sleep(45)
    ev = events(marker)
    tasks = find_tasks(ctx)
    rec(Q[2], "disconnect-blocking", "INFO",
        "blocking SendMessage (no configuration) with text '%s %s' and contextId %s; the client gives up after 4 s (the run takes about 25 s); then wait 45 s" % (SLOW, marker, ctx),
        "client side: %s. At +6s the stand-in had %d request(s) for the marker; at +51s: %s. Tasks of the conversation: %s" % (
            summ(r), len(mid_ev), "; ".join("started +%.1fs, finished %s status %s" % (e["t0"] - t0, ("+%.1fs" % (e["t1"] - t0)) if e["t1"] else "never", e["status"]) for e in ev) or "none", " | ".join(tasks)),
        "the run continued after the client left (the model request finished)" if ev and ev[0]["t1"] else "the model request did not finish after the client left")


def q3():
    # a: one after the other, both fast
    m = mid("b3a")
    marker = "MARK-B3A-" + os.urandom(3).hex()
    r1 = call(msg("hello " + marker, m))
    r2 = call(msg("hello " + marker, m))
    time.sleep(2)
    ev = events(marker)
    rec(Q[3], "sequential-same-id", "YES" if len(ev) == 1 else "NO", msg("hello " + marker, m) + "\n(sent twice, the second after the first answered)",
        "first: %s\nsecond: %s\nmodel requests for this text: %d" % (summ(r1), summ(r2), len(ev)),
        "one run, the second send did not start another" if len(ev) == 1 else "two runs: the same messageId started a second run (%d model requests; task ids %s / %s)" % (len(ev), task_of(r1)[0], task_of(r2)[0]))
    # b: the second arrives while the first still runs
    m = mid("b3b")
    marker = "MARK-B3B-" + os.urandom(3).hex()
    out = []
    th = threading.Thread(target=lambda: out.append(call(msg("%s %s" % (SLOW, marker), m), timeout=120)))
    th.start()
    time.sleep(5)
    r2 = call(msg("%s %s" % (SLOW, marker), m), timeout=120)
    th.join(150)
    ev = events(marker)
    rec(Q[3], "overlapping-same-id", "INFO", msg("%s %s" % (SLOW, marker), m) + "\n(the second copy sent 5 s after the first, while it ran)",
        "first: %s\nsecond: %s\nmodel requests for this text: %d" % (summ(out[0]) if out else "no answer", summ(r2), len(ev)),
        "one run" if len(ev) == 1 else "%d runs for one messageId" % len(ev))
    # c: same id, different text
    m = mid("b3c")
    ma, mb = "MARK-B3C1-" + os.urandom(3).hex(), "MARK-B3C2-" + os.urandom(3).hex()
    r1 = call(msg("hello " + ma, m))
    r2 = call(msg("hello " + mb, m))
    time.sleep(2)
    rec(Q[3], "same-id-other-text", "INFO", msg("hello <A>", m) + "\nthen the same messageId with text <B>",
        "first: %s\nsecond: %s\nmodel requests for A: %d, for B: %d" % (summ(r1), summ(r2), len(events(ma)), len(events(mb))), "")


def raw_body(extra_msg="", extra_params="", extra_top="", parts='"parts":[{"text":"%(t)s"}]', mid_key="messageId", params_key="params", t=""):
    m = '{"%s":"%s","role":"ROLE_USER",%s%s}' % (mid_key, mid("b4"), parts % {"t": t}, extra_msg)
    return '{"jsonrpc":"2.0","id":1,"method":"SendMessage","%s":{"message":%s%s}%s}' % (params_key, m, extra_params, extra_top)


def q4():
    def variant(label, build, markers):
        body = build(markers)
        r = call(body, timeout=60)
        time.sleep(2)
        seen = {m: len(events(m)) for m in markers}
        txt = [e["text"] for m in markers for e in events(m)]
        verdict = "accepted" if (r["status"] == 200 and not (r.get("j") or {}).get("error")) else "rejected"
        rec(Q[4], label, "INFO", body, "%s. Model requests per marker: %s. Text that reached the model: %s" % (summ(r), seen, short(" | ".join(txt), 300) or "none"),
            "%s; reached the model: %s" % (verdict, [m for m, n in seen.items() if n] or "nothing"))
        return r

    def mk(prefix):
        return "MARK-B4-%s-%s" % (prefix, os.urandom(3).hex())

    a = [mk("ctl")]
    variant("control", lambda m: raw_body(t="hello " + m[0]), a)
    a = [mk("unk-params")]
    variant("unknown-key-in-params", lambda m: raw_body(t="hello " + m[0], extra_params=',"unknownKey":"x"'), a)
    a = [mk("unk-msg")]
    variant("unknown-key-in-message", lambda m: raw_body(t="hello " + m[0], extra_msg=',"unknownKey":"x"'), a)
    a = [mk("unk-top")]
    variant("unknown-key-at-top", lambda m: raw_body(t="hello " + m[0], extra_top=',"unknownKey":"x"'), a)
    a = [mk("part-extra")]
    variant("unknown-key-in-part", lambda m: raw_body(t="hello " + m[0], parts='"parts":[{"text":"%(t)s","unknownKey":"x"}]'), a)
    a = [mk("Parts-only")]
    variant("case-variant-Parts-only", lambda m: raw_body(t="hello " + m[0], parts='"Parts":[{"text":"%(t)s"}]'), a)
    a = [mk("parts-real"), mk("Parts-var")]
    variant("both-parts-and-Parts", lambda m: raw_body(t="hello " + m[0], parts='"parts":[{"text":"%(t)s"}],"Parts":[{"text":"hello ' + m[1] + '"}]'), a)
    a = [mk("MessageId")]
    variant("case-variant-MessageId", lambda m: raw_body(t="hello " + m[0], mid_key="MessageId"), a)
    a = [mk("Params")]
    variant("case-variant-Params", lambda m: raw_body(t="hello " + m[0], params_key="Params"), a)
    a = [mk("dup-text-a"), mk("dup-text-b")]
    variant("duplicate-key-text", lambda m: raw_body(parts='"parts":[{"text":"hello ' + m[0] + '","text":"hello ' + m[1] + '"}]'), a)
    a = [mk("dup-parts-a"), mk("dup-parts-b")]
    variant("duplicate-key-parts", lambda m: raw_body(parts='"parts":[{"text":"hello ' + m[0] + '"}],"parts":[{"text":"hello ' + m[1] + '"}]'), a)
    a = [mk("Config")]
    r = variant("case-variant-Configuration-blocking-false", lambda m: raw_body(t=SLOW + " " + m[0], extra_params=',"Configuration":{"blocking":false}'), a)
    a = [mk("cfgunk")]
    variant("unknown-key-in-configuration", lambda m: raw_body(t="hello " + m[0], extra_params=',"configuration":{"blocking":true,"unknownKey":1}'), a)
    a = [mk("ctx")]
    variant("contextId-and-taskId-present", lambda m: raw_body(t="hello " + m[0], extra_msg=',"contextId":"spike-ctx-%s","taskId":"not-a-task"' % os.urandom(3).hex()), a)


# ---------------------------------------------------------------- B5
def node_container():
    out = L.subprocess.run(["docker", "ps", "--format", "{{.Names}}"], capture_output=True, text=True).stdout
    names = [n for n in out.split() if n.endswith("control-plane")]
    return names[0] if names else None


SH = ('for p in /proc/[0-9]*; do c=$(tr "\\0" " " < $p/cmdline 2>/dev/null); case "$c" in *a2a-gate*) '
      'pid=${p#/proc/}; echo pid=$pid; grep -E "^(VmRSS|VmHWM):" $p/status; cg=$(cut -d: -f3 $p/cgroup); '
      'for f in memory.current memory.peak memory.max; do echo "$f=$(cat /sys/fs/cgroup$cg/$f 2>/dev/null)"; done; break;; esac; done')


def gate_mem():
    node = S.get("node")
    if not node:
        return None
    r = L.subprocess.run(["docker", "exec", node, "sh", "-c", SH], capture_output=True, text=True, timeout=30)
    d = {}
    for line in r.stdout.splitlines():
        m = re.match(r"(VmRSS|VmHWM):\s+(\d+) kB", line)
        if m:
            d[m.group(1)] = int(m.group(2)) // 1024
        m = re.match(r"(memory\.\w+)=(\d+)", line)
        if m:
            d[m.group(1)] = int(m.group(2)) // (1024 * 1024)
    return d or None


def q5():
    S["node"] = node_container()
    pods = k("get", "pods", "-n", "openagentix-gateway", "-o", "wide")[1]
    lim = k("get", "deploy", "a2a-gate", "-n", "openagentix-gateway", "-o", "jsonpath={.spec.template.spec.containers[0].resources}")[1]
    top = k("top", "pod", "-n", "openagentix-gateway")
    rec(Q[5], "setup", "INFO", "kubectl get pods -n openagentix-gateway; kubectl top pod; container resources; the gate process read from the kind node (/proc/<pid>/status and its cgroup)",
        "%s\nresources: %s\nkubectl top: %s\nnode container: %s" % (pods.strip(), lim, short(top[1] + top[2], 200), S["node"]))
    base = gate_mem()
    rec(Q[5], "baseline", "INFO", "VmRSS and VmHWM of the gate process, and the cgroup's memory.current, memory.peak and memory.max (MiB)", json.dumps(base))
    if not base:
        return
    # burst 1: many distinct caller tokens and message ids, refused after authentication (an agent the caller may not ask)
    n_tok = 300
    toks = []
    lock = threading.Lock()

    def mint():
        while True:
            with lock:
                if len(toks) >= n_tok:
                    return
                toks.append(None)
            t = token()
            with lock:
                toks[toks.index(None)] = t
    ths = [threading.Thread(target=mint) for _ in range(8)]
    for t in ths:
        t.start()
    for t in ths:
        t.join(600)
    toks = [t for t in toks if t]
    res = []

    def hit(i):
        h = {"Content-Type": "application/json", "A2A-Version": "1.0", "X-User-Id": "quickstart:ask", "Authorization": "Bearer " + toks[i]}
        r = L.http("POST", "http://127.0.0.1:%d/agents/kagent/not-this-agent" % S["gate"].port, h, msg("hello", mid("b5")), 30)
        res.append(r["status"])
    sem = threading.Semaphore(16)

    def worker(i):
        with sem:
            hit(i)
    ws = [threading.Thread(target=worker, args=(i,)) for i in range(len(toks))]
    for w in ws:
        w.start()
    for w in ws:
        w.join(300)
    after1 = gate_mem()
    cnt = {}
    for s in res:
        cnt[s] = cnt.get(s, 0) + 1
    rec(Q[5], "burst-tokens", "INFO",
        "%d requests, each with a different projected ServiceAccount token (kubectl create token quickstart-ask) and a different messageId, 16 at a time, to /agents/kagent/not-this-agent (refused after authentication)" % len(toks),
        "statuses %s; memory after: %s (MiB; limit 64)" % (cnt, json.dumps(after1)))
    # burst 2: many open calls at the same time (each held by the stand-in for about 25 s)
    n_open = 48
    stop = threading.Event()
    samples = []

    def sampler():
        while not stop.is_set():
            m = gate_mem()
            if m:
                samples.append(m)
            time.sleep(2)
    sp = threading.Thread(target=sampler)
    sp.start()
    tk = [token() for _ in range(n_open)]
    out = L.parallel([(lambda i=i: L.http("POST", url("gate"), {"Content-Type": "application/json", "A2A-Version": "1.0", "X-User-Id": "quickstart:ask", "Authorization": "Bearer " + tk[i]},
                                         msg("%s MARK-B5-%d" % (SLOW, i), mid("b5o")), 150)) for i in range(n_open)])
    stop.set()
    sp.join(30)
    sc = {}
    for o in out:
        key = o["status"] if o["status"] else o["error"][:40]
        sc[key] = sc.get(key, 0) + 1
    peak = max((s.get("VmRSS", 0) for s in samples), default=0)
    after2 = gate_mem()
    rec(Q[5], "burst-open-calls", "INFO",
        "%d blocking SendMessage calls at the same moment through the gate, each with its own token and messageId; each run is held about 25 s by the stand-in (the gate keeps each call open)" % n_open,
        "statuses %s; highest VmRSS sampled every 2 s: %d MiB; final: %s (MiB; limit 64; %d samples)" % (sc, peak, json.dumps(after2), len(samples)))
    limit = (after2 or {}).get("memory.max")
    hwm = max([(after2 or {}).get("VmHWM", 0), (after1 or {}).get("VmHWM", 0)])
    rec(Q[5], "answer", "PARTLY",
        "", "baseline %s; peak resident set during the bursts %s MiB (VmHWM); cgroup limit %s MiB" % (json.dumps(base), hwm, limit),
        "measured for the gate as it is today: peak %s MiB of %s MiB. Not measured: the 16 callers x 4096 keys of the ADR (the gate has no such state yet, so it needs the code of slice 3 or 4), and distinct caller rules (a chart values change)" % (hwm, limit))


def main():
    try:
        setup()
    except Exception as e:  # noqa: BLE001
        rec(Q[1], "setup", "ERROR", "", str(e))
        return finish()
    for fn, q in ((q1, 1), (q2, 2), (q3, 3), (q4, 4), (q5, 5)):
        L.guarded(fn, Q[q])
    return finish()


def finish():
    for t in ("direct", "gate"):
        if S.get(t):
            S[t].stop()
    os.environ["SPIKE_STEM"] = "results-adr0027"
    return L.write_results(OUT, "Spike B, ADR 0027: the runtime behind the A2A gate", [Q[i] for i in sorted(Q)])


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
