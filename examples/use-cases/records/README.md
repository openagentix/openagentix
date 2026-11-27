# Records: a small system of record for the reference use cases

One Go binary. One domain per install. The first domain is `bank`, a dispute and fraud-claim desk for the
fictional Fernvale Bank. Every name, id and amount is synthetic. Fernvale Bank, its customers, merchants and card
scheme are invented and describe no real bank, scheme or regulation.

Status: the service core and the bank module are built and unit tested. They are not yet installed by the chart,
not yet used by an agent, and not yet run on a cluster. See "What is not proven".

## What it gives an agent

- A REST API on port 8081, shaped like a small subset of a core banking API (`/clients`, `/savingsaccounts/{id}/transactions`,
  `/cards`, `/merchants/{id}/history`) plus `/cases`, `/approvals`, `/timers`, `/outbox`, `/ledger`.
- An MCP endpoint on port 8080 at `/mcp` (streamable HTTP, stateless). Register it with the platform's tool mechanism.
- An approval queue. The agent proposes an act. A named approver decides it over an authenticated REST call. Only
  then does the act run.
- Deadline timers. A due timer is marked `fired`. A sweep (a scheduled agent run) picks it up.
- A mock outbox for letters and scheme filings. Nothing leaves the cluster.
- An audit log of every tool call and every decision: who, which door, which action, which record, which outcome.
  It never holds message text, arguments or personal data.
- `/healthz` and `/readyz` on both ports.

## The bank flow

1. `case.created`: a case is opened (`POST /cases`). The response deadline is 10 working days out.
2. The agent reads the case, the transactions, the card status, the merchant history and linked cases.
3. It attaches evidence, sets a route with a reason (`provisional_credit_then_chargeback`, `chargeback`, `decline`
   or `inconclusive_needs_analyst`), drafts the letter and the chargeback filing, and sets timers.
4. It calls `request_approval`. The kind must equal the route. The letter draft (and the filing draft for a
   chargeback) must exist. The amount cannot exceed the disputed amount.
5. A named approver with the role `desk-lead` calls `POST /approvals/{id}/approve` with a token and the
   `payload_hash` they read. In one transaction the service posts the provisional credit (only for the credit route),
   queues the drafts in the outbox, and resolves the case. A rejection sends the case back to an analyst and drops the drafts.

If the agent changes the route or a draft after it asked for approval, the request is marked `superseded` and the
approver is refused. A changed record also refuses the approval (the hash no longer matches).

## Safety design

| Rule | How |
|---|---|
| No tool moves money or sends a letter | The MCP tools are listed in `internal/bank/tools.go`. A test fails if a tool name contains approve, post, credit, send, execute, release or ledger |
| Deciding needs a named person | `POST /approvals/{id}/approve` and `/reject` need `Authorization: Bearer <token>`. Tokens are checked in constant time against SHA-256 hashes in a file. With no file, nobody can decide |
| The approver approves what they saw | The request carries `payload_hash`. It must equal the hash of route, amount, reason and both drafts now |
| Role per kind | The bank kinds need the role `desk-lead` |
| One decision, one execution | The status change is a conditional update in the same transaction as the act. A second approve gets 409 |
| No SQL from input | Every statement uses bound parameters. Ids are checked against a strict pattern first |
| Input limits | Bodies up to 64 KiB, unknown JSON fields refused, text length and control characters checked, enums closed, lists capped |
| No personal data to the agent | MCP views drop the replay answer and label the customer's words `untrusted_customer_text`. Customer names are never in a case view |
| Audit has no text | The audit entry has no field for text. Values are cut to a safe alphabet and 64 characters |
| Least privilege | No outbound network, no secret read, no Kubernetes API, non-root, read-only root file system apart from `/data` |

The MCP endpoint has no login of its own, like the notify service. The tool gateway in front of it authenticates
agents, and a network policy (a later slice) must keep everyone else out. The REST reads and the agent's own steps
(`/cases`, drafts, `POST /approvals`) have no login either, so whoever can reach port 8081 can act as the agent.
Only the decision routes and `/audit` need an approver token. Keep port 8081 off the network except for a person
using `kubectl port-forward`.

## Run it

```sh
make test                                   # go test ./... -race -count=1
make build && RECORDS_DATA_DIR=$(mktemp -d) bin/records
```

Settings (environment):

| Variable | Default | Meaning |
|---|---|---|
| `RECORDS_DOMAIN` | the build default, `bank` | The domain to serve. This build has only `bank` |
| `RECORDS_DATA_DIR` | `/data` | Where `records.db` lives |
| `RECORDS_MCP_ADDR` | `:8080` | MCP and health |
| `RECORDS_REST_ADDR` | `:8081` | REST and health |
| `RECORDS_APPROVERS_FILE` | none | JSON array of `{id, role, token_sha256}`. Without it nobody can approve |

Make an approvers file (the file holds hashes, never tokens):

```sh
TOKEN=$(openssl rand -hex 24)               # keep it; give it to the approver
printf '[{"id":"desk:lead-1","role":"desk-lead","token_sha256":"%s"}]\n' "$(printf %s "$TOKEN" | shasum -a 256 | cut -d' ' -f1)" > approvers.json
```

Approve:

```sh
curl -s localhost:8081/approvals/APR-0001
curl -s -X POST localhost:8081/approvals/APR-0001/approve -H "Authorization: Bearer $TOKEN" \
  -d '{"payload_hash":"<the payload_hash from the line above>","note":"checked"}'
```

## Storage

SQLite through `modernc.org/sqlite` (pure Go, no cgo, BSD-3-Clause). It is one file, adds no pod and no
credential, runs in CI with no service, and the distroless image stays small. One connection serialises writes,
which is enough for a demo service. The data is seeded once, on first start, from a fixed seed, relative to the
clock. A restart of the container keeps the file; deleting the pod (with an `emptyDir`) resets it. PostgreSQL
was rejected: it would need a credential and would mix demo data with platform data.

## Seed data

40 customers (`C-1001`...), 40 accounts and cards (only the last four digits), 60 fictional merchants, about 1,200
transactions over 90 days, and 60 cases: 30 open and 30 resolved with a recorded human decision (kept for replay,
shown only on REST). The open cases include a duplicate charge, a "not recognised" chip and PIN charge at a regular
merchant, a subscription after cancelling, goods not received with a refund already posted, a case past the scheme
window, a ring of 5 cases that share a device and a merchant, and a case whose customer text tries to give orders to
the agent. A test checks that the seed holds no e-mail address, link or long digit run.

## What is not proven

- Not installed by the chart, not run in a container, not registered with the tool gateway, no agent uses it yet.
  The Docker build is checked by CI only.
- Memory and CPU are not measured. The target is 10m and 32Mi requests, limits 100m and 96Mi.
- The AML alert queue and `aml-triage` agent are not built.
- There is no rate limit and no lockout on approver tokens. Use long random tokens.
- Working days skip weekends only. Public holidays are not modelled.
- The service has run only under `go test`, with the Go MCP SDK client over HTTP.

## Layout

```
cmd/records/       main: wiring, listeners, timer ticker
internal/core/     store, audit, approver auth, approval queue, timers, outbox, HTTP helpers (shared by every domain)
internal/bank/     schema, seed, service, REST routes, MCP tools
Dockerfile         ARG DOMAIN=bank; base images pinned by digest; non-root; data in /data
```
