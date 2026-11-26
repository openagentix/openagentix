---
title: Use cases
sidebar_position: 3
description: Four things you can do with OpenAgentix today, with the resources, commands, what is proven and what is not. Then a short list of what is planned.
---

# Use cases

Each scenario below works today on a single-node kind cluster; the first one also in CI on k3s. Each one says who it is for, what you do, which resources are involved, what was proven and what was not. Read [what works](../what-works.md) for the full status.

## 1. Give a team an agent with a budget and one approved tool

**Who.** A platform team that wants to let a developer team run an agent without handing out a provider key or opening every tool.

**What.** The platform team sets a policy: which model alias, which tool profile, how many agents. The developer team writes a short `AgentDefinition`. The control plane builds the agent, gives it its own gateway key with a token budget, and refuses a definition that breaks the policy.

**Resources.** `AgentDefinition` (`openagentix.io/v1alpha1`); the platform policy in `controlPlane.policy`; a tool profile in `mcp.profiles`; a caller rule in `governance.a2a.callers`; the gateway's token budget in `gateway.policy.tokenBudget`.

**Commands.** The quick start sets all of this up with one agent, `quickstart`, which may use one tool (`osv_query_vulnerability`):

```sh
PROFILE=quickstart ./install.sh
hack/ask.sh quickstart "Look up known vulnerabilities of lodash 4.17.20 (npm)"
kubectl get oad -n kagent
```

The definition is `components/quickstart/agent.yaml`; the policy and the profile are in `components/quickstart/values.yaml`.

**Proven.** In CI on a hosted runner, with no key: the agent becomes Ready, answers through the A2A gate with a tool call, gets nothing back from a tool outside its profile, and a definition with a model the policy does not allow is refused and builds nothing ([Quick start](../features/quick-start.md)). On kind with a real model: definitions became Ready agents in 13 to 31 s, and the gateway recorded the call under the agent's own user ([Control plane](../features/control-plane.md)). A 429 when a budget ran out was seen live.

**Not proven or not built.** A second team agent needs its own caller rule at the gate before anyone can call it; the control plane does not write gate rules. Only one namespace was tested. Budgets are in tokens, not money.

## 2. Run a scheduled report agent

**Who.** A team that wants an agent to check something every morning and send the result to a chat.

**What.** A schedule calls the agent over A2A at fixed times. Each schedule has its own user id, so it has its own memory. With the notify service, the agent can post the result to a named destination, without seeing a chat id or a token.

**Resources.** The chart's `schedules` list (one Kubernetes CronJob per entry) and the `notify` block with destinations in a Secret.

**Values and commands.**

```yaml
schedules:
  - name: daily-brief
    agent: assistant
    schedule: "0 8 * * 1-5"
    timeZone: Europe/Berlin
    prompt: |
      Check the vulnerability database for lodash 4.17.20 and answer in two sentences.
```

```sh
export ANTHROPIC_API_KEY=sk-ant-... TELEGRAM_BOT_TOKEN=123456:ABC... TELEGRAM_ALLOWED_CHAT_IDS=<your chat id>
NOTIFY_TELEGRAM_CHAT_ID=<your chat id> \
VALUES_FILE="components/channels/demo-values.yaml components/schedules/demo-values.yaml components/notify/demo-values.yaml" ./install.sh
kubectl create job -n openagentix-schedules --from=cronjob/demo-brief demo-brief-manual-1
kubectl logs -n openagentix-schedules job/demo-brief-manual-1
```

**Proven.** A manual run, a pair of runs sharing memory, and a real cron firing completed. The demo schedule delivered its result to a real Telegram chat through notify ([Schedules](../features/schedules.md), [Notify](../features/notify.md)).

**Not proven or not built.** A failed run is not alerted; you watch the Jobs. Schedules work with chart agents (`agents[]`), not yet with agents built from an `AgentDefinition`. Slack and webhook destinations of notify are unit-tested only. This needs the full install, not the quick start, and a Telegram bot for the delivery shown here.

## 3. Answer questions from internal documents, with sources

**Who.** A team with a folder of Markdown documents (runbooks, design notes) that wants an agent to answer questions from them.

**What.** The knowledge base stores the documents with hybrid search (words and vectors). The embedding model runs in the cluster. An agent with `knowledge: true` gets three read-only search tools and is told to cite document titles. The optional knowledge graph connects facts across documents and cites the document, chunk and quoted text for each fact.

**Resources.** The chart's `knowledge` block (a `kb` service, PostgreSQL with pgvector, a CPU embedding server); `knowledge: true` on the agent; optionally `knowledge.kb.graph.enabled`.

**Commands.**

```sh
./install.sh                                            # full install (needs ANTHROPIC_API_KEY and the Telegram variables); the knowledge base is on by default
hack/kb-ingest.sh ./my-docs my-collection
VALUES_FILE=components/knowledge/graph-demo-values.yaml ./install.sh   # optional: the knowledge graph
```

**Proven.** Searches found the right passage for questions that share no word with it. With the graph on and a real model, the agent answered a question that needs five documents and cited each one ([Knowledge base](../features/knowledge-base.md), [Knowledge graph](../features/knowledge-graph.md)).

**Not proven or not built.** Citations without the graph come from the agent's instructions, not from a check. The graph was tested on one small fictional corpus, in English. With the graph on, the text of every document is sent to the extraction model. One replica, no backups, no access control per collection.

## 4. Receive a signed webhook and act on it

**Who.** A team that wants an event from another system (a failed order, a failed deploy) to start an agent.

**What.** Agent Kourier, an open-source broker, receives the webhook, checks its signature, and starts a turn of the agent named in a binding. Rate limits per binding drop excess events. With notify, the agent can post what it found.

**Resources.** The chart's `channels` block: a connection (how to check the signature and read the body) and a binding (which agent, which events, limits). Kourier renders them as `ChatConnection`, `Binding` and `AgentBackend` resources.

**Commands.** Enable the demo connection, then send a signed test event (the full commands are in the README, section "Channels and triggers"):

```sh
VALUES_FILE=components/channels/demo-values.yaml ./install.sh
kubectl port-forward -n agent-kourier svc/agent-kourier-chat 8081:8081
```

**Proven.** A signed webhook ran a turn that completed with the right answer; a wrong signature got 401; a webhook result was delivered to a real Telegram chat through notify ([Channels](../features/channels.md)).

**Not proven or not built.** A webhook has no reply route; the agent must act through its tools. The chart creates no public endpoint; you add an ingress yourself. Kourier is a young 0.x project. The Slack path exists in the chart but has never run against a real workspace.

## Planned

These are not built. They are in the [roadmap](https://github.com/openagentix/openagentix/blob/main/docs/roadmap.md) and [ADR 0013](https://github.com/openagentix/openagentix/blob/main/docs/decisions/0013-focus-and-runtime-neutrality.md).

- Bring your own agent beyond CI: on a long-running cluster, from a registry, with egress allowlists (slice 5). Slices 1 and 3 are proven in CI on kind ([Bring your own agent](./bring-your-own-agent.md)).
- Install on a managed cloud, and on OpenShift. Today the k3s install is proven in CI, and the remote-cluster installer and OpenShift manifests are tested offline only (0.3).
- Slack proven on a real workspace (0.4).
- Runs and human approval (`AgentRun`, `ApprovalRequest`), identity per agent with token exchange, console login with OpenID Connect (0.4).
- Workspaces, budgets per run, queueing and delegation (0.5).
