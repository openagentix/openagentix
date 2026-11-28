---
title: Model gateway spike for budget classes
sidebar_position: 15.9
description: What a throwaway-cluster spike showed about agentgateway v1.7.0 and a conditional token limit keyed on a per-key metadata member (ADR 0029, proposed).
---

# Model gateway spike for budget classes

Issue [#229](https://github.com/openagentix/openagentix/issues/229), ADR 0029 (proposed, PR #262), slice 2. This page is the record of one spike. It does not describe a feature of the product. Nothing in the chart, the CRDs or the services was changed.

## What was run

The job `e2e (adr spikes ...)` of `.github/workflows/e2e.yml` (start it by hand with the input `adr_spikes`; it never runs on a pull request and never gates a merge) installs the quick start (`PROFILE=quickstart ./install.sh`, no key, no chat token) on a kind cluster of a hosted runner. Then `hack/spikes/adr-spikes.sh` runs `hack/spikes/adr0029_gateway_spike.py`. The script refuses to run outside GitHub Actions or on a context that is not a kind context.

- agentgateway: controller and proxy `v1.7.0`, as pinned by `components/model-gateway/install.sh`.
- Backend: the stub model only. A small recording stand-in (`hack/spikes/adr_slow_model.py`) sits between the gateway and the stub, so the spike can count the requests that reach the model. The stub model's own network policy admits only the gateway pods, so the spike adds one extra allow policy for the stand-in. No paid call.
- The one gateway policy (`model-gateway-policy`) had `spec.traffic.rateLimit` replaced by the manifest below. `apiKeyAuthentication` (Strict) and `retry` (attempts 2, codes 402, 429, 500, 502, 503, 504) were left as the chart renders them. Test keys are in an extra ConfigMap with the label `agentgateway.dev/apikey: "true"`; each entry is `{"keyHash":"sha256:...","metadata":{"user_id":"<name>","budget_class":"<class>"}}` (a key without a class has no `budget_class`).
- A stub call counts about 74 tokens (the stub reports `usage.total_tokens`), so the limits are small: 100 (alpha), 250 (beta), 100 shared (gamma), 400 (fallback), all per hour.

```yaml
rateLimit:
  conditional:
    - condition: 'apiKey.budget_class == "alpha"'
      policy: {local: [{tokens: 100, unit: Hours, key: apiKey.user_id}]}
    - condition: 'apiKey.budget_class == "beta"'
      policy: {local: [{tokens: 250, unit: Hours, key: apiKey.user_id}]}
    - condition: 'apiKey.budget_class == "gamma"'
      policy: {local: [{tokens: 100, unit: Hours}]}          # no key: one bucket
    - policy: {local: [{tokens: 400, unit: Hours, key: apiKey.user_id}]}   # the fallback
```

Every call is `POST /v1/chat/completions` with `Authorization: Bearer <key>` and the body `{"model":"quickstart-model","stream":false,"messages":[{"role":"user","content":"spike ping <label>"}]}`, through a port-forward to the Service `model-gateway`.

Runs on the pull request (all on `ubuntu-24.04`, one kind node):

| Run | Result |
|---|---|
| [46090633081](https://github.com/openagentix/openagentix/actions/runs/46090633081) | Cancelled after 50 minutes. Every model call timed out: the stub model's network policy refused the stand-in, and the spike had no stop for a gateway that does not answer. |
| [46095550377](https://github.com/openagentix/openagentix/actions/runs/46095550377) | Spike A only, same cause. The spike now stops a drain after four calls that get no answer. |
| [46098251670](https://github.com/openagentix/openagentix/actions/runs/46098251670) | First complete run (after the extra allow policy). |
| [46099570137](https://github.com/openagentix/openagentix/actions/runs/46099570137) | Adds the second class move of A3. |

The tables come from runs 46098251670 and 46099570137. The full results (`results-adr0029.md`) are the artifact `adr-spikes` of each run.

## Answers

| # | Question | Answer |
|---|---|---|
| 1 | Can a policy expression see a per-key metadata member? | Yes. `apiKey.budget_class == "alpha"` matched the keys of that class. The policy was accepted (`Accepted` and `Attached` true). Key `ka1` (alpha, limit 100) was refused after 2 calls (148 tokens counted); `kb1` (beta, limit 250) after 4 calls (296 tokens). |
| 2 | What does a key without the member get? | The fallback entry. `kn1` (no `budget_class`) was admitted 6 times (444 tokens, fallback limit 400) and then refused; `kn2` had its own full bucket. A key with a class that matches no condition (`zeta`) behaved the same. No error, no deny, no shared bucket for keys that have `key: apiKey.user_id` in the fallback. |
| 3 | Does changing a key's class start a fresh full bucket? | Yes for a class the key has not used: after the edit of the ConfigMap entry from alpha to beta, the first call was admitted 2.2 s later and 3 more were admitted. No for a class the key used before: moved back to alpha, then to beta again, every call was refused (`429` x3 each time). The gateway keeps a bucket for each class and key pair, and a used one is not refilled by the move. |
| 4 | Does a conditional limit work with API key authentication and with retry? | Yes, as one policy. No key and an unknown key got 401; a valid key got 200 or, when its bucket was spent, 429 with `x-ratelimit-limit`, `x-ratelimit-remaining: 0` and `retry-after` (about 3600 s). A refused call produced one gateway log line and no request to the model (stand-in count 2 before and 2 after). So the policy's retry did not send a gateway 429 upstream. Retry of an upstream 429 was not tested (the stub never answers 429). |
| 5 | K parallel calls against a nearly empty bucket: how many are admitted? | All of them. With one call of headroom left (74 of 100 tokens used), 5 of 5, 10 of 10 and 20 of 20 parallel calls were admitted (twice for 20). A sequential caller gets 1. After the bucket was refused, 10 parallel calls got 10 times 429. The overshoot is the number of calls in flight times the cost of a call. The stub answers in milliseconds, so a slower model would overlap more. |
| 6 | Restart and two replicas? | Restart: the counters are gone. `kr1` was refused, the proxy pod was deleted, and the new pod admitted 2 calls again (a full bucket). Two replicas: yes, each pod counts alone. Straight to pod A, `kr2` was admitted 2 times; straight to pod B, 2 more times. The Service route was not tested: a port-forward to a Service keeps one pod, so 40 calls through it hit one pod (2 admitted). `kubectl scale` held 2 replicas for the test. |

## What was seen, in detail

- **Policy status.** `Accepted: True (Valid)` and `Attached: True` after the patch of `spec.traffic.rateLimit`. The CRD took a `conditional` list with a CEL `condition`, a per-entry `local` limit and a last entry without a condition.
- **Shared class.** Two keys of class `gamma` (the entry has no `key`): after `kg1` was refused, `kg2` got `429` x3. One bucket for the class.
- **Late counting.** The call that crosses the limit is admitted: 2 calls of 74 tokens passed a limit of 100.
- **Time to apply.** A new key and the policy were live within the 4 s of the first poll. A changed class applied within about 2 s.

## Limits of this spike

- One agentgateway version (v1.7.0), one single-node kind cluster, one run of each check. The class move was run twice (two dispatches); the other numbers once, and the values are small because the stub model counts few tokens.
- The stub model answers at once. The overshoot with a slow or streaming model is not measured.
- The number of buckets a replica keeps before it drops the least used ones was not tested.
- Two replicas through the Service (kube-proxy spread) were not tested; each pod was addressed directly.
- `kubectl scale` on the proxy Deployment was used for two replicas. Whether the chart or the gateway's parameters object should set the count is a design question for the ADR, not for this spike.
- The spike replaced the rate limit in the live policy by hand. It did not render the ADR's chart values, so the render and the admission guard are untested.
- Retry on an upstream 429 together with a conditional limit was not tested.

## What this means for the ADR

These are the facts, for the author of the ADR to use:

- The metadata approach works on v1.7.0: option C stands on this question, and the fallback to option D is not needed for the member lookup.
- A key without the member falls to the fallback entry, so the chart can leave the member off for agents that name no class.
- A class change gives a full bucket only the first time a key meets a class; moving back to a spent class does not refill it.
- The limit is per replica and is lost on restart, as the ADR says. Parallel calls can pass a limit by the number in flight.
