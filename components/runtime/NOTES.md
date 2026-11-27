# kagent 1.0.x spike on kind (macOS arm64, Docker Desktop 5 CPU / 8 GB)

Date: 2026-11-22. Cluster `kind-openagentix` is left running (single node `kindest/node:v1.37.0`).

## Verdict (short)

- kagent 1.0.1 + Agent Substrate 1.0.1 **run on this laptop** via the pure Helm path. All pods Ready; the node uses ~2.3 GiB of the 7.7 GiB Docker VM.
- gVisor **works** under Docker Desktop on arm64: the worker registered `sandbox_class=gvisor, architecture=arm64`, golden snapshots were taken, agent turns run inside sandboxes and resume from snapshots.
- A2A works end to end (card, `SendMessage`, `SendStreamingMessage`, follow-up turn on the same `contextId`).
- **Gemini answer NOT obtained**: the supplied `GOOGLE_API_KEY` belongs to a project with depleted prepaid credits. Google returns HTTP 402 `RESOURCE_EXHAUSTED` ("Your prepayment credits are depleted") for every model, including a direct `generateContent` call outside the cluster. The Gemini path inside kagent was proven up to the provider call (ModelConfig Accepted, secret resolved, sandbox reached Google, 402 relayed as a failed A2A task). The successful-response sample uses an in-cluster stub LLM (see "Stub LLM"). Needs a funded key to close.

## Versions

| Item | Version |
|---|---|
| kind / node image | 0.33.0 / `kindest/node:v1.37.0` (k8s v1.37.0) |
| kagent charts (`kagent-crds`, `kagent`) | 1.0.1 (docs say 1.0.0; 1.0.1 released 2026-11-12, used as latest patch) |
| Substrate charts (`substrate-crds`, `substrate-podcert`, `substrate-atelet`, `substrate`) | 1.0.1 (app v1.0.1) |
| Worker image | `ghcr.io/kagent-dev/substrate/ateworker-gvisor:v1.0.1` |
| Agent runtime (Harness) image | `ghcr.io/kagent-dev/kagent/golang-adk@sha256:d3b1151d...` (1.0.1 digest; docs show the 1.0.0 digest) |
| kubectl-ate | v1.0.1 darwin-arm64 from the substrate GitHub release (needed to mint pools) |
| Model | `gemini-3.5-flash-lite` (chart default for provider `gemini`; exists in the API model list) |
| gVisor release in SandboxConfig | `gvisor-default` v7 |

## What was installed (order matters) = six Helm releases + manual bootstrap

`up.sh` reproduces all of this. Helm releases, in order:

1. `kagent-crds` (ns `kagent`)
2. `substrate-crds` (ns `ate-system`)
3. `substrate-podcert` (ns `podcertificate-controller-system`) - after pools + auth secrets exist
4. `substrate-atelet` (ns `ate-system`) - release name must be exactly this
5. `substrate` (ns `ate-system`, `atelet.enabled=false`) - release name must be exactly this
6. `kagent` (ns `kagent`)

Non-Helm bootstrap (this is what an umbrella chart must absorb or replace):

- `kubectl ate admin make-ca-pool` x5 (service-dns, postgres, pod-identity in `podcertificate-controller-system`; actor-id and egress-mitm in `ate-system`) and `make-jwt-pool` x1. These mint private keys; a chart cannot do this declaratively without a pre-install Job (or Helm `genCA`, which is not the same pool format).
- Secret `actor-id-ca-certs` (root cert from `actor-id-ca-pool` `tls.crt`) and ConfigMap `ate-api-authentication` (key `authentication.yaml`, JWT provider with the cluster's OIDC issuer; for kind the issuer is `https://kubernetes.default.svc.cluster.local` plus the two `...File` lines).
- Substrate PostgreSQL: bundled mTLS dev Postgres from upstream `manifests/ate-install/postgres/postgres.yaml` (vendored in `manifests/substrate-postgres`, memory shrunk), then `psql` setup script, then two connection-string Secrets that reference podcert-issued client certs.
- Secret `kagent-rustfs-credentials` (rustfsadmin/rustfsadmin, dev only).
- kagent's own PostgreSQL: not bundled in the Helm chart. I ran a plain `pgvector/pgvector:pg17` StatefulSet with password auth (`sslmode=disable`), the kagent `setup.sql` role script, and two Secrets (`kagent-postgres-owner`, `kagent-postgres-readwrite`).
- `kubectl label ns kagent ate.dev/api-access=true` (NetworkPolicy gate for reaching ate-api).
- Provider key Secret `kagent-gemini` (from env, `--from-literal`; never written to disk).
- Node sysctl `net.ipv4.conf.all.proxy_arp=1` / `net.ipv6.conf.all.proxy_ndp=1` (upstream `hack/create-kind-cluster.sh` does it for gVisor pod networking; docs do not mention it; not proven necessary here because I applied it before anything ran). On kind and k3d the installer sets them with `docker exec` (`cluster_node_settings` in `hack/cluster.sh`). On `CLUSTER_TYPE=remote` there is no node shell, so they are skipped unless `NODE_SETTINGS=daemonset` applies `node-settings.yaml` (a privileged DaemonSet in its own namespace; issue #163; not run on any cluster).

Values files are in `values/`. Key kagent values: `controller.substrateClientCertificate.enabled=true`, `substrateWorkerPool.create=true` + `workerImage`, `harnesses.enabled=true`, `providers.default=gemini`. `kagent` creates `default-model-config` from `providers.*` (native `Gemini` provider exists, no OpenAI shim needed).

## Deviations from the docs

1. No kind feature gates / runtime-config needed: ClusterTrustBundle and PodCertificateRequest are served at `certificates.k8s.io/v1` on 1.37 (docs agree). Upstream charts' NOTES still print a warning about `certificates.k8s.io/v1beta1`; it is not enabled here and nothing broke. `kind-config.yaml` is therefore only a node image pin + name.
2. Docs omit `postgres.clientCertificates.enabled=true` for the `substrate` chart when using the bundled mTLS Postgres. Without it ate-api-server crash-loops: `Failed to set up persistence backend ... parsing PostgreSQL connection string: invalid value` (the connection string references cert files that are never projected). Fixed by setting it (in `values/substrate.yaml`). That first helm run had to be killed and the release uninstalled (it was left `pending-install`).
3. Docs' Helm path requires an external Postgres >= 15 with `verify-full`. I used the substrate dev Postgres for Substrate and a separate plain pgvector Postgres for kagent (docs: bundled CLI Postgres has no pgvector; `vectorEnabled=false` here).
4. Used 1.0.1 instead of 1.0.0; used the 1.0.1 harness digest.
5. `kubectl ate install` exists and does steps 3-7 automatically (Helm charts embedded). I did not use it, per the "pure Helm" preference, but it is the best reference for what an umbrella chart must reproduce.

## Failures and root causes

| Symptom | Cause | Fix |
|---|---|---|
| ate-api-server CrashLoopBackOff, "parsing PostgreSQL connection string: invalid value" | `postgres.clientCertificates.enabled` defaults false | set true |
| `kagent-controller` restarted twice at install: `substrate: dial ate-api "dns:///api.ate-system.svc:443": context deadline exceeded` (RESTARTS=2), then healthy | Root-caused in issue #178: kagent 1.0.1 `substrate.Dial` (go/core/internal/substrate/client.go) waits 10 s (fixed default; app.go sets no DialTimeout, the config has no field) and the controller exits when ate-api is not serving yet. ate-api waits for its servicedns pod certificate and for the Substrate PostgreSQL, so after a node restart it is often not serving for 1 to 3 minutes | `kagent-postrender.sh` (helm post-renderer in `kagent-helm.sh`) adds init container `wait-for-ate-api` (TCP connect to api.ate-system.svc:443) |
| Agent `my-first-agent` Ready=False "waiting for the ActorTemplate golden snapshot" for ~1 min | Normal: atelet pulls the harness image into the sandbox cache and checkpoints | wait |
| First turn: `agent run failed: Error 402 ... prepayment credits are depleted` | Google project of the supplied key has no credits (reproduced with direct curl on 4 models) | external; needs a funded key |
| Stub-LLM agent: `lookup mock-llm.kagent.svc on 169.254.17.1:53: no such host` | Sandbox DNS relay does not apply search domains; use FQDN `*.svc.cluster.local` | use FQDN |
| After editing a ModelConfig, the very next A2A call still used the old config | Agent revision rolls and re-snapshots (~15-20 s); calls in that window hit the old actor | wait for `Ready` |

## A2A (verified)

```
kubectl -n kagent port-forward svc/kagent-controller 8083:8083
GET  /agents/kagent/my-first-agent/.well-known/agent-card.json   (header A2A-Version: 1.0)
POST /agents/kagent/<agent>   Content-Type: application/json, A2A-Version: 1.0
{"jsonrpc":"2.0","id":"1","method":"SendMessage","params":{"message":{"messageId":"m-0002","role":"ROLE_USER","parts":[{"text":"..."}]}}}
```

Files: `a2a-agent-card.json`, `a2a-request-1.json`, `a2a-sample-response.json` (success, stub LLM), `a2a-request-2-followup.json` + `a2a-sample-response-followup.json` (same `contextId`, new task id), `a2a-sample-response-gemini-402-failure.json` (real Gemini path, failed), `a2a-request-3-stream.json` + `a2a-sample-stream.txt` (`SendStreamingMessage`, SSE).

Response-shape facts for the client author:
- Result is `result.task` (not a bare message). IDs are UUIDv7. `contextId` is server-assigned on the first turn; send it back in `params.message.contextId` to continue. Each turn creates a new `task.id`.
- Success: `task.status.state = TASK_STATE_COMPLETED`, **the answer is in `task.artifacts[0].parts[0].text`**, `status.message` is absent. `task.history` holds only the current user message (1 entry), not the conversation.
- Failure (including LLM provider errors): HTTP 200, JSON-RPC `result` (not `error`), `state = TASK_STATE_FAILED`, error text in `status.message.parts[0].text`. Clients must check `state`, not the HTTP code.
- Token usage: `artifacts[0].metadata["kagent.dev/a2a/usage"]` and `task.metadata["https://kagent.dev/extensions/usage/v1"]`.
- Latency: ~9 s for the first failed turn, 15 s for a follow-up turn (sandbox resume dominates; the stub LLM answers in ms).
- Follow-up retained conversation: the stub reports "4 messages seen" on turn 2 vs 2 on turn 1.
- Agent card: JSONRPC and gRPC interfaces, `streaming: true`, `pushNotifications: true`, extensions `hitl/v1` and `usage/v1`, `skills: []`. Interface URLs are in-cluster DNS names; a client outside the cluster must rewrite the host.

## Stub LLM

Because of the 402, `manifests/mock-llm.yaml` adds a ~40-line OpenAI-compatible stub (ConfigMap + python:alpine), a `ModelConfig` (`provider: OpenAI`, `stream: false`, baseUrl FQDN) and `mock-agent` on the same Harness. This proves the sandbox -> model-call -> A2A response path and gives the response shape. It does not prove Gemini success. `up.sh` does not apply it (apply `manifests/mock-llm.yaml` separately).

## Footprint (idle, after both agents ready; `footprint.txt` has the raw dump)

- `docker stats`: `openagentix-control-plane` 2.31 GiB / 7.74 GiB RAM, 40% CPU snapshot (of 5 CPUs; busy during the turns). Inside the node `free`: used ~3.0 GiB, buff/cache ~5.7 GiB, available ~4.9 GiB. (A separate unrelated container `hub-dev-pg` on this Docker VM uses ~270 MiB.)
- Largest consumers (crictl): kube-apiserver 402 MB, kube-controller-manager 112 MB, postgres (substrate) 82 MB, etcd 77 MB, rustfs 74 MB, atelet 70 MB, kagent controller ~63 MB, ate-api-server 2 replicas x ~33 MB. The gVisor worker shows 26 MB at pod level; sandbox memory lives in cgroups below it and was not itemised.
- 27 pods total, all Running/Completed; only restarts: `kagent-controller` x2 (see above). Chart defaults run 2 replicas of ate-api-server and ate-idp-server.
- `kubectl top` is unavailable (no metrics-server).
- Time: cluster create 20 s; podcert 14 s; substrate install ~20 s helm + ~2 min until all pods Ready (image pulls); kagent ~2.5 min to controller Ready (incl. 2 restarts); first agent golden snapshot ~1 min. Roughly 8-10 min from nothing to a Ready agent on a warm network, excluding debugging. Image pulls are the bulk.

## Verdicts

- **Does it fit 8 GB?** Yes, with room: ~2.3 GiB node RSS idle for the full kagent + substrate stack, ~5 GiB available inside the VM. The real limit will be sandboxes (each Harness defaults `config.runtimeDefaults` 1 CPU / 1 GiB limits; worker capacity advertised as the whole VM, 5 CPU / 8 GB). Running google/ax on the same cluster is plausible but only a few concurrent agent sandboxes will fit. Not measured under multi-agent load.
- **gVisor on Docker Desktop arm64?** Yes. runsc runs on arm64 in the kind node without KVM; checkpoint/restore (golden snapshot) worked. Worker logs warn "Kernel has no cgroup memory pressure (PSI), so ... an OOM kill in one [sandbox] can restart the worker" - a Docker Desktop VM kernel limitation to remember for load tests. micro-VM class (needs /dev/kvm) not tried.
- **Six releases -> one umbrella chart?** Plausible but not trivially. The Helm releases themselves have fixed names and ordering constraints (`substrate-atelet` before `substrate`; podcert before both; CRDs first; podcert needs the CA-pool Secrets to exist before install, and Postgres needs podcert-issued certs, i.e. a Postgres -> podcert -> app dependency chain). Umbrella subcharts install in a single release with no inter-chart ordering, no pre-install key minting, and the upstream "release name must be X" constraint conflicts with subchart naming. Practical options: (a) umbrella with Helm hooks (pre-install Job runs `kubectl-ate admin make-*-pool`, creates auth Secret/ConfigMap, DB setup Job) and `helm.sh/hook-weight` ordering for podcert; keep CRDs in a separate `crds/` or release; (b) a thin installer (like `kubectl ate install`, which already encodes this) that drives Helm. I would expect (a) to be fiddly (CRDs cannot be in the same release as CRs they define on first install; atelet/substrate naming) and recommend validating before committing.

## Unverified

- Any successful Gemini completion (key out of credits).
- kagent-controller start-up race: fixed by the wait in `kagent-postrender.sh` (issue #178); proven by 6 recovery runs in CI, not on a laptop VM.
- Behaviour under several concurrent agents, memory per sandbox, and resource limits.
- `up.sh` on a fresh machine: I re-ran it on the existing cluster: exit 0 in 51 s, every step a no-op or unchanged, agent still Ready (idempotency verified). I did not recreate the cluster from zero, so the cold path is only verified as the manual sequence it was derived from.
- kagent UI and other harnesses (claude/codex) not exercised.

## Long-term memory (kagent 1.0.1, golang-adk harness) - verified later

- It works, but only with: pgvector in kagent's PostgreSQL schema `extensions` (the `pgvector/pgvector:pg17` image already ships it; `pgvector.sh` runs `CREATE EXTENSION vector WITH SCHEMA extensions` and grants both roles USAGE: migrations do not do it), `config.database.vectorEnabled=true` (controller start-up then runs the vector migration: `kagent.memory`, `extensions.vector(768)`, HNSW), and a Harness `spec.kagent.memory.modelConfigRef`.
- The dimension is fixed at 768 (controller `validateVector`, harness `embedding.TargetDimension`; larger vectors are truncated and re-normalised, smaller ones are an error). bge-small (384) cannot be used; memory runs `bge-base-en-v1.5` (768) in its own llama.cpp server.
- Memory is written only by the `save_memory` tool the model calls (nothing in the Go ADK calls `AddSessionToMemory`); it is read by `preload_memory` (automatic, every turn, top 5, score >= 0.3) and by a `load_memory` tool. Scope is `(namespace/agent, session creator user id)`.
- kagent compiles one egress credential per destination origin; the agent's chat ModelConfig and the embedding ModelConfig pointing at the same gateway origin with different keys fail with "conflicting credentials". The embedding ModelConfig uses an `ExternalName` alias of the gateway Service (a different origin) with its own key. The harness env var is the same name (`OPENAI_API_KEY`) for both, but it only holds a placeholder: the real key is injected by origin at the egress proxy.
- `ttlDays` sets `expires_at`, but the controller never calls `PruneExpiredMemories` and search ignores `expires_at` (source), so nothing expires.
- Enabling it restarted the kagent controller and recompiled the agent revision (2 new `agent_revision` rows); sessions, tasks and tools were untouched.
