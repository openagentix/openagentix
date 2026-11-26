# Model gateway (agentgateway) on kind-openagentix

Date: 2026-11-22. Agents -> agentgateway -> {mock-llm stub, Google Gemini}. Agents hold only a gateway virtual key; the Gemini key lives in one Secret in `agentgateway-system`.

## Versions

| Item | Version |
|---|---|
| agentgateway charts `agentgateway-crds`, `agentgateway` (`oci://cr.agentgateway.dev/charts`) | v1.7.0 (latest stable; GitHub also lists only rc/alpha newer-numbered pre-releases) |
| Proxy/controller image | `cr.agentgateway.dev/agentgateway:v1.7.0` (same image Substrate's `atenet-router` runs) |
| Gateway API CRDs (standard channel) | v1.6.3 (docs value) |
| Release/namespace | `agentgateway`, `agentgateway-crds` in `agentgateway-system` |

## Layout

- `install.sh` idempotent (re-run verified: all `unchanged`). Secrets from env only: `GOOGLE_API_KEY` via process substitution (not in argv, not on disk). Virtual keys are generated with `openssl` on first run, kept in Secrets, and only SHA-256 hashes go into ConfigMap `llm-api-keys`.
- `values.yaml` controller sizing + `agentgatewayModels.enabled`.
- `manifests/00-gateway.yaml` Gateway `model-gateway` (listener allows `AgentgatewayModel`). `10-models.yaml` models `stub`, `gemini`, `auto`. `20-policies.yaml` virtual-key auth + per-key token budget + retry (one policy). `30-observability.yaml` adds `user_id` to access log and metrics. `40-kagent.yaml` ModelConfigs `gateway-stub`, `gateway-gemini`, AgentTemplate + Agent `gateway-agent`.
- Endpoint: `http://model-gateway.agentgateway-system.svc.cluster.local/v1` (port 80; the Service is type ClusterIP since ADR 0023, see "The Service type" below. Before that agentgateway made it a LoadBalancer, `<pending>` on kind and a public IP on a cloud).

## The Service type (ADR 0023, issue #165)

Left alone, agentgateway makes the `model-gateway` Service a `LoadBalancer`. On a managed cloud that is a public IP, a firewall rule and a charge. The chart value `gateway.serviceType` (`ClusterIP` default, or `LoadBalancer`; anything else, an empty value included, fails the render) sets it:

- The chart always renders `AgentgatewayParameters` `<gateway.name>-parameters` (`agentgateway.dev/v1alpha1`, `spec.service.spec.type`, nothing else) and the Gateway gets `spec.infrastructure.parametersRef` to it. `manifests/00-gateway.yaml` (the standalone path) does the same with `ClusterIP`.
- Upgrade: the load balancer of an existing install is removed. If you reach the gateway from outside the cluster through it, set `gateway.serviceType: LoadBalancer` before you upgrade, or use `kubectl port-forward`.
- `install.sh` needs no value. After a remote install it warns about each `LoadBalancer` or `NodePort` Service.
- Clients use the DNS name and port 80 and need no change.

`ClusterIP` removes the public IP only. Any pod in the cluster can still connect; the virtual key is the control.

Field names were read from the agentgateway v1.7.0 CRD chart and its deployer test fixture. Not run on a cluster: that the Service becomes `ClusterIP` (also on a live type change, with the same cluster IP), and that the Gateway is `Accepted` and `Programmed` with the parameters.

## Collisions checked before install (none found)

- Before install the cluster had zero Gateway API CRDs, no GatewayClass, no `*.agentgateway.dev` CRDs (CRDs present: kagent `*.api.kagent.dev` and `*.ate.dev` only).
- Substrate's "agentgateway" is only the container image used by `ate-system/atenet-router` (`cr.agentgateway.dev/agentgateway:v1.7.0`). It is configured by Substrate, not by Gateway API objects, so nothing collides. Nothing in `ate-system`, `ax-system`, `openagentix-gateway`, `toolhive-system` or the existing agents was touched.
- Future risk: another Gateway API implementation or ToolHive bundling its own Gateway API CRDs would share these cluster-scoped CRDs. `install.sh` skips applying them if `gateways.gateway.networking.k8s.io` already exists (override `FORCE_GATEWAY_API=1`).

## Deviations from the docs

1. Docs' LLM guides use `AgentgatewayBackend` + `HTTPRoute`. v1.7.0 also ships a newer `AgentgatewayModel` API (enabled by default) that selects by the request body's `model` field. That is what makes `stub`/`gemini`/`auto` selectable by an unmodified OpenAI client, so I used it. No `AgentgatewayBackend`/`HTTPRoute` is needed. The listener must list `AgentgatewayModel` in `allowedRoutes.kinds`, otherwise `/v1/chat/completions` is not served.
2. `gemini` model: client name `gemini` is rewritten to `gemini-3.5-flash-lite` with a `policies.transformations` model expression (same model the kagent spike used). The Secret key must be named `Authorization`.
3. Failover needs two additions the failover page does not make obvious: (a) `policies.health.unhealthyCondition` including 402/429, because default eviction only reacts to 5xx/connect errors; (b) a retry policy, otherwise the request that discovers the dead primary is returned to the client as 402 and only later requests fail over (observed: first run returned 402 for `auto`, then 200 next call).
4. Docs warn that separate `AgentgatewayPolicy` objects on the same Gateway can overwrite each other. Auth, budget and retry are therefore one policy (all `spec.traffic`); the observability policy only sets `spec.frontend`. Not verified that two policies would actually clash.

## Evidence (all from a curl pod inside the cluster)

Direct, before virtual keys:
- `stub` -> 200 `{"model":"mock",...,"content":"MOCK-LLM reply (1 messages seen). 2+2 is 4."}`
- `gemini` -> HTTP 402 `{"error":{"type":"rate_limit_error","message":"Your prepayment credits are depleted...","code":"RESOURCE_EXHAUSTED"}}` (Google's body passed through; route + secret work)
- `auto` first request with gemini healthy: access log shows one request, `retry.attempt=2 ... gen_ai.request.model=stub agw.ai.original_model=auto duration=708ms` (gemini 402, retried to stub). Earlier, without the retry policy: log `07:13:34.153 ... gemini-3.5-flash-lite ... http.status=402 original_model=auto` then `07:13:34.173 ... stub ... 200`.

With virtual keys on:
- no key -> 401 `authentication failed`; wrong key -> 401; valid key: stub 200, gemini 402, auto 200.

## OSS vs enterprise (tried on v1.7.0 OSS, no license installed)

| Feature | Result | Evidence |
|---|---|---|
| Virtual keys (`apiKeyAuthentication`, hashed keys in ConfigMap, per-key `user_id` metadata) | Works, OSS | 401 without/with bad key; 200 with key; provider key never given to client |
| Per-key token budget (`rateLimit.local[].tokens`, `key: apiKey.user_id`) | Works, OSS | with `tokens: 40/Minutes`: ops-test got 200,200,200 then 429 `rate limit exceeded`; the `gateway-agent` key still got 200 (separate bucket). Reverted to 100000/Hours |
| Token metrics | Works | `agentgateway_gen_ai_client_token_usage{...}` on proxy `:15020/metrics` |
| Cost metrics (USD) | Works for models in the built-in catalog | request to model `gpt-4o-mini` (temporary model, pointed at the stub): log `agw.ai.usage.cost.total=0.00000675`, metric `agentgateway_gen_ai_client_cost_usd_total{...,gen_ai_request_model="gpt-4o-mini",user_id="ops-test"} 0.00000675`. `stub` is not in the catalog: `agentgateway_cost_catalog_lookups_total{status="Missing"}`, cost not computed. Gemini lookups are `Exact`, but cost is 0 because every call was a 402 |
| Per-user attribution in logs/metrics | Works via `frontend.accessLog/metrics.attributes.add` | log lines end `user_id="gateway-agent"` |
| Failover (priority groups) | Works, OSS | see above |
| Global (shared across replicas) rate limits | Needs an external rate-limit service you run; not tested | docs |
| USD spend caps | Not found. Budgets are token-based only; I found no USD-cap field in the CRDs | `kubectl explain` of rateLimit shows only `requests`/`tokens`; global descriptors accept `unit: Tokens|Requests` |
| Cost dashboard (built-in UI) | Documented as OSS but needs `AgentgatewayParameters.rawConfig` sqlite database; not tried | unverified |
| Enterprise-only | I hit no licence gate in anything above. The docs pages I read carry no "enterprise" label; I did not compare against the vendor's paid product, so "what is enterprise-only" is not established, only "all of the above ran on OSS" |

## Wiring to kagent

- `ModelConfig gateway-stub` (provider OpenAI, `openAI.baseUrl` = gateway FQDN `/v1`, model `stub`, `apiKeySecret: gateway-virtual-key` holds the virtual key) and `gateway-gemini` (model `gemini`, no agent). Both `Accepted/ResolvedRefs=True`.
- `Agent gateway-agent` reuses the existing Harness `my-first-harness` like `mock-agent` does (no new Harness, avoids another golden snapshot). Ready after ~1.5 min.
- A2A `SendMessage` to `http://kagent-controller.kagent.svc.cluster.local:8083/agents/kagent/gateway-agent` (from a pod in-cluster): `state=TASK_STATE_COMPLETED`, answer `"MOCK-LLM reply (2 messages seen). 2+2 is 4."`, usage 5/10/15.
- Gateway access log for the same call (source is the sandbox pod IP, key attributed to the agent):
  `... endpoint=mock-llm.kagent.svc.cluster.local:8000 src.addr=10.244.0.28:51408 ... http.status=200 protocol=llm gen_ai.request.model=stub agw.ai.original_model=stub gen_ai.usage.input_tokens=5 gen_ai.usage.output_tokens=10 duration=72ms user_id="gateway-agent"`
- Sandbox egress to the gateway FQDN worked without any EgressPolicy.

## Footprint

- Added pods: `agentgateway` (controller) + `model-gateway` (proxy) = 2 pods, 1 replica each.
- Working set (crictl, idle after ~10 requests): controller 36 MiB, proxy 18 MiB. Requests 100m CPU / 128Mi each (chart default, not tuned). No `kubectl top` (no metrics-server).
- Node: `docker stats` 3.14 GiB / 7.74 GiB after adding it (included other agents' work concurrently, so the delta is not isolated; the gateway itself is about 55 MiB).

## What a Helm umbrella chart must handle

- Gateway API CRDs are not in either agentgateway chart; they must be installed first (or by a shared prerequisite) and must not be re-applied if another component owns them. CRD ordering: Gateway API CRDs -> `agentgateway-crds` -> `agentgateway` -> Gateway -> models/policies (Gateway/AgentgatewayModel CRs cannot ship in the same release as their CRDs on first install).
- The data plane Deployment is created by the controller after the Gateway CR exists; wait for `Programmed` before dependants (kagent ModelConfig does not need it, but the first A2A call does).
- Secrets: Gemini key (`Authorization` key name), virtual-key ConfigMap built from hashes of keys held in Secrets (a pre-install/post-install Job or an external secret operator; Helm `lookup` for stable generated keys).
- kagent ModelConfig Secret lives in `kagent`; the hash ConfigMap in `agentgateway-system`; the same key material in two namespaces needs a sync mechanism.
- Retry + auth + budget must stay in a single `AgentgatewayPolicy` per Gateway.

## Unverified

- A successful Gemini completion through the gateway (key unfunded) and the Gemini auth header format beyond "Google accepted it" (402 is returned after auth, so the key was accepted or at least not rejected).
- Non-zero cost for Gemini; cost dashboard; global (multi-replica) rate limits; HTTPS; multiple proxy replicas.
- Whether the virtual key is forwarded to the `stub` upstream (mock-llm does not log headers; docs say it is replaced only where a provider secret is configured).
- Failover on streaming requests; failover timing with eviction `duration: 30s` under load.
- That two separate policies on one Gateway really overwrite each other (docs claim; I avoided it).
- Enterprise-only feature list (no comparison against the paid product).
- Cold install on a cluster with no `kagent` namespace (script has the branch, not exercised) and on a fresh cluster generally; only the idempotent re-run was run.

## Embeddings route (2026-11-22)
- `AgentgatewayModel` v1alpha1 in v1.7.0 serves `/v1/embeddings` for an OpenAI-compatible backend: `provider: OpenAI` + `baseURL: http://kb-embeddings.openagentix-knowledge.svc.cluster.local:8080/v1`, no `policies.auth`. The access log shows `gen_ai.operation.name=embeddings`, `agw.ai.original_model=embed-default` and `user_id="kb"`. Without a virtual key or with a wrong one: 401. (`provider: Custom` with `custom.backendRef` is the alternative, but it may only reference a Service in the model's own namespace.)
- A request sent before the upstream had finished loading its model returned 503 "Connection refused"; the embedding Pod's readiness probe now waits for the model.
