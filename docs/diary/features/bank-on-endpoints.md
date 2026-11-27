---
title: Bank use case on mcp.endpoints
sidebar_position: 15.7
description: "The bank dispute agent moved onto the endpoint contract of ADR 0026 (slice 5): the records service in a tool group of its own with a header credential, a tool profile, and a live run in CI through real agent sessions. What it showed and what is not proven."
---

# The bank use case on `mcp.endpoints`

Issue [#229](https://github.com/openagentix/openagentix/issues/229), [ADR 0026](https://github.com/openagentix/openagentix/blob/main/docs/decisions/0026-use-case-wiring-contracts.md), slice 5. The code and the full README are in `examples/use-cases/bank`. The first version of this use case (PR 239) registered the records service with an `MCPServerEntry` that a script applied by hand, put its tools on the shared tool server, patched the stub model, and was limited to the quick start. This slice moves it onto the contracts of slices 2 to 4. No chart value was added.

## What changed

- **The records service has a login on its MCP port.** The whole `Authorization` header value is read on every request from a mounted Secret file, compared in constant time, and is in no log line, error or answer. `/healthz` and `/readyz` stay open. The service does not start without the file, unless `RECORDS_MCP_INSECURE_NO_AUTH=true` (tests only, logged). The REST port is unchanged: it listens on the pod's loopback.
- **The endpoint is a chart value.** `mcp.endpoints` has `records` in the tool group `disputes`, with the header from the Secret `records-mcp-auth`. The tool profile `disputes` lists the 15 records tools the agent uses and 6 knowledge tools, with no code mode. The agent `dispute-agent` is on that profile, so the model sees `records_get_case` and `knowledge-disputes_kb_search`. The shared tool server does not offer the records tools, and the chart forbids each of them there too. The hand-applied registration and the guard that limited the use case to the quick start are gone.
- **`install.sh` does the whole install, in the order the ADR needs.** The records service and four Secrets come before the platform values: the approver hash and token, and one header value `Bearer <token>` stored twice (the tool namespace for the tool gateway, the records namespace for the service). All of them are made through stdin and never printed. There is no default cluster. It refuses to run the quick start install on a release that has more than the quick start and this use case, because the platform installer replaces release values on every run. `--beside-full-demo` composes `values-full-demo.yaml` after your own files with `hack/compose-values.sh`, after a check that your files merge into one file that renders the same.
- **The evaluation set and scenarios use the profile's names** and read tool results the way the runtime hands them over. The injection case has `max_tool_calls: 8` (the stand-in makes 5). `tools/oa-eval` gained the check `max_tool_calls`, the same change as in the pod root-cause pull request.

## What the live run showed

The opt-in job `e2e (bank, mcp.endpoints)` (`gh workflow run e2e.yml -f bank=true --ref <branch>`, `hack/ci/bank-live.sh`) runs the use case on a kind cluster. The stub model played `examples/use-cases/bank/eval/scenario.json`, so **every agent run was scripted by the stub model** and shows the platform, not a model. The pull request names the run. 69 checks passed in the run on the final code:

- The tool server of the group listed both backends (`records` and `knowledge-disputes`) as ready, and no `DiscoveredAuthConfig-*` condition was False. The agent answered through the A2A gate, and the `AUDIT` lines of the group's tool server showed its calls with the session actor and no case text.
- `oa-eval` passed all five cases through the gate, with the audit lines as the audit source and the records REST state as the state source. The duplicate charge asked for an approval, the out-of-time claim was declined, the injected instruction asked for none. Every audited call was a tool of the profile, and the shared tool server saw none.
- The approver path: `ctl.sh approve` posted exactly one credit and queued the letter and the filing. A second approval was refused. A change to the other case superseded its request, and approving it was refused. Nothing more was posted.
- The records service answered 401 to a call with no header, a wrong header and the approver token, and 200 to the right value. The health checks need no header. No header value and no approver token was in any log, in any object, in the install log or in the report.
- Called directly with a token of the API server (the identity settings of the tool servers were changed for this part and restored): the group's tool server listed exactly the 21 tools, a tool outside the profile was refused, the shared tool server listed no records tool and refused a call (`call denied by authorization policy`), and so did the profile of the quick start agent.
- Callers: the quick start caller, a user id outside the desk prefix and a caller with no rule got 403, and the desk could not ask the quick start agent.
- `kubectl auth can-i get secret/records-mcp-auth -n mcp-tools` for the shared tool server's ServiceAccount answered **yes**. This is the remaining risk of ADR 0026 A3.

## Findings

- **The tool result shape.** The agent runtime hands the model `{"output":<the structured result>}` for a tool with structured content (the bank's tools and the knowledge base), and `{"output":{"text":"<JSON>"}}` for a tool with text only (`cluster-read`). The first live run showed placeholders that did not resolve; a read-only probe scenario (`show the raw results of <case>`) printed the shape. The scenarios and the replay test use it.
- **The knowledge base ranks as it ranks.** For the time limit query the live kb returned the dispute policy above the scheme rules (the policy points at the rules in one line), so the first live run cited the wrong document. The query is closer to the scheme text now, and the answer cites the rules when they are the first or second result and says "needs human review" when they are not in the results. This is a property of the data and the ranking, not of the stub.
- **kagent shows no tools for the profile's server** (`DiscoveryDisabled`, an empty list), as it does for the diagnostics profile: the agent resolves its tools at run time. The calls work.
- **The egress policy of the group worked on kind in CI.** A throwaway pod with the labels of the group's tool server could reach the records pod and could not reach a web server in `default` that a control pod (without the labels) reached. The agent sessions and the direct calls worked under the same policy, so the rule for the identity provider (the labels and port read from the Substrate manifests) and the other rules let the tool server do what it needs. One run, one cluster, an in-cluster target: nothing is shown about egress to the internet, which the old note says kindnet does not cut.
- **No scenario count in the stub's log.** ADR 0026 expects the stub's start log to name the number of scenarios. It names the directory (`scenarios loaded from /etc/stub-model/scenarios`). The live job checks that line after a second install run, which kept the Secrets and the scenarios.

## What is not proven

- A real model. The stub never exercises the prompt, so the rules against obeying the injected instruction and against claiming a credit are untested. The first real-model run has a checklist in the README.
- `install.sh --beside-full-demo` on a real full demo cluster, and the memory of the added pods on a 6 CPU / 8 GB node. The offline tests compose and render it.
- The suspended `deadline-sweep` CronJob run by hand (the sweep was asked through the gate only).
- A `-workload` variant, a definition or a container agent on the profile (refused by the chart in slice 2).
- Every tool server in the tool namespace can read every Secret there. The header is as safe as that namespace.
- One run on one cluster per claim. A second run, or another network plugin, may differ.
