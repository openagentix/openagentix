# Records: a small system of record for the reference use cases

One Go binary. One domain per install. The domains are `bank` (below) and `equipment` (see "The equipment domain"). `bank` is a dispute and fraud-claim desk for the
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
   chargeback) must exist. The amount cannot exceed the disputed amount. The case becomes `pending_approval` in the
   same transaction as the proposal. A credit is refused when an earlier case already credited the transaction
   or when the account is not active.
5. A named approver with the role `desk-lead` reads `GET /approvals/{id}`. The reply holds the frozen `payload`
   (route, amount, reason, the letter text, the filing text, the case version, earlier credits) and
   `payload_hash`, which is the SHA-256 of that payload text. The approver calls `POST /approvals/{id}/approve`
   with a token and that `payload_hash`. In one transaction the service posts the provisional credit (only for the
   credit route), queues the letter (and the filing for the two chargeback routes only), discards any other draft,
   and resolves the case. A rejection sends the case back to an analyst and drops the drafts.

Any write to the case after the proposal (evidence, status, route, a draft) marks the approval `superseded` and
raises the case version. Approval is refused when the payload or the version no longer matches. An approver who
made the proposal (with their own token) cannot decide it.

## Safety design

| Rule | How |
|---|---|
| No tool moves money or sends a letter | The MCP tools are listed in `internal/bank/tools.go`. A test fails if a tool name contains approve, post, credit, send, execute, release or ledger |
| Deciding needs a named person | `POST /approvals/{id}/approve` and `/reject` need `Authorization: Bearer <token>`. Tokens are checked in constant time against SHA-256 hashes in a file. With no file, nobody can decide |
| The approver approves what they saw | `GET /approvals/{id}` returns the exact payload the hash covers, frozen at proposal. The approve call must send that hash, and the payload computed from the record now must still hash the same, with the same case version |
| Only approved drafts leave | Execute queues the kinds in the payload (letter; filing only on the chargeback routes) and discards the rest |
| No double credit | A credit is refused when the transaction already has a credit, so credits per transaction never exceed one case's disputed amount. A closed or blocked account gets no credit |
| No self-approval | A proposal made with an approver token carries that name, and that approver cannot decide it. A proposal on REST from outside the pod must carry an approver token. A proposal from the pod's own loopback address (a person using `kubectl port-forward`) may carry none and is named `rest`: **separation of duties is not enforced for those unauthenticated loopback proposals**, because an approver could propose that way and then decide it. MCP proposals are always named `agent`, and `agent` cannot be an approver id, so no approver can impersonate the agent |
| Role per kind | The bank kinds need the role `desk-lead` |
| One decision, one execution | The status change is a conditional update in the same transaction as the act. A second approve gets 409 |
| No SQL from input | Every statement uses bound parameters. Ids are checked against a strict pattern first |
| Input limits | Bodies up to 64 KiB, `Content-Type: application/json` required, unknown JSON fields refused, cross-origin browser writes refused, text length and control characters checked, enums closed, lists capped |
| Bounded growth | At most 20 timers and 100 evidence items per case, 5 discarded drafts kept per case, 50,000 audit rows kept (older rows go; the stdout log keeps every line), 120 writes per minute per host. Every POST counts, including an approve with a wrong token, and a host with more than 30 refused logins in a minute gets 429 instead of 401. A valid token is never blocked, and there is no lockout |
| No personal data to the agent | MCP views drop the replay answer and label the customer's words `untrusted_customer_text`. Customer names are never in a case view. Route reasons and evidence notes can be written through REST, so the agent sees them as `untrusted_route_reason` and `untrusted_note` |
| Audit has no text | The audit entry has no field for text. Values are cut to a safe alphabet and 64 characters |
| Least privilege | No outbound network, no secret read, no Kubernetes API, non-root, read-only root file system apart from `/data` |

The MCP endpoint has no login of its own, like the notify service. The tool gateway in front of it authenticates
agents, and a network policy (a later slice) must keep everyone else out.

The loopback rule looks only at the connection's source address. It never reads `X-Forwarded-For`, `Forwarded` or `X-Real-IP`, and a test sends them from a remote address to prove it. **Chart note:** a sidecar in the same pod that forwards traffic to `127.0.0.1:8081` (a mesh proxy, or a ToolHive proxy run as a sidecar) would make every remote caller look like loopback. Do not run one in front of port 8081, or move REST to a Unix socket. A test pins the limit that a manager can decide a proposal that came from loopback without a token.

The REST port listens on `127.0.0.1:8081` by default, so only a person using `kubectl port-forward` reaches it.
Agents never need it: their steps go through the MCP port, which is the one ToolHive proxies. This is the choice
that still works when the MCP path runs behind ToolHive (an agent token on REST would have to be passed through
the proxy, which `mcp.servers` cannot do today). The REST reads and the agent's own steps (`/cases`, drafts,
`POST /approvals`) have no login, so anyone who sets `RECORDS_REST_ADDR=:8081` and can reach the pod acts as the
agent. Only the decision routes and `/audit` need an approver token.

## Run it

```sh
make test                                   # go test ./... -race -count=1
make build && RECORDS_DATA_DIR=$(mktemp -d) bin/records
```

Settings (environment):

| Variable | Default | Meaning |
|---|---|---|
| `RECORDS_DOMAIN` | the build default, `bank` | `bank` or `equipment`. Build the image with `--build-arg DOMAIN=equipment` to change the default |
| `RECORDS_DATA_DIR` | `/data` | Where `records.db` lives |
| `RECORDS_MCP_ADDR` | `:8080` | MCP and health |
| `RECORDS_REST_ADDR` | `127.0.0.1:8081` | REST and health. Set `:8081` only if you also add a network policy |
| `RECORDS_APPROVERS_FILE` | none | JSON array of `{id, role, token_sha256}`. Without it nobody can approve |

Make an approvers file (the file holds hashes, never tokens):

```sh
TOKEN=$(openssl rand -hex 24)               # keep it; give it to the approver
printf '[{"id":"desk:lead-1","role":"desk-lead","token_sha256":"%s"}]\n' "$(printf %s "$TOKEN" | shasum -a 256 | cut -d' ' -f1)" > approvers.json
```

Approve:

```sh
# Read once: the payload is what you approve. payload_hash is the SHA-256 of the payload text.
curl -s localhost:8081/approvals/APR-0001 | tee /tmp/approval.json | jq -r .payload
HASH=$(jq -r .payload_hash /tmp/approval.json)
curl -s -X POST localhost:8081/approvals/APR-0001/approve -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d "{\"payload_hash\":\"$HASH\",\"note\":\"checked\"}"
```

## The equipment domain

`RECORDS_DOMAIN=equipment` serves a dealer network for the fictional Kestrel Valley Machinery: 3 models, 4 dealers,
200 machines, 400 parts with supersessions, stock per dealer, 60 fault codes, warranty terms per model, telematics
for 30 combines, technician slots, work orders, and drafts in the outbox. All names and data are synthetic and
describe no real company. Approvers need the role `dealer-manager`. Approver ids look like `dealer:svc-mgr-02`.

Flow of a service event:

1. `telemetry.fault` arrives as `POST /faults {serial, code}`. The same fault on the same machine reuses the open
   case (the event is still recorded). A dealer's request arrives as `POST /requests {serial, note}`.
2. The agent reads the case and the machine (`get_machine` shows repeated faults), the fault code, the warranty
   (`check_warranty`), the stock at every dealer nearest first (`get_stock`), and the telematics.
3. It sets a diagnosis, creates the work order (no approval needed), drafts the parts order, the warranty claim and
   the customer notice, and holds a technician slot.
4. It calls `request_approval`. A dealer manager reads `GET /approvals/{id}` and approves with the `payload_hash`.
   Only then are the order, the claim and the notice queued in the outbox, the stock taken from the dealer, and the
   slot confirmed.

Rules the record enforces, whatever the agent says:

| Rule | How |
|---|---|
| The warranty decision is the record's | A claim draft is refused unless the machine is covered. The approval kind must be `parts_order_with_claim` when covered and `parts_order` when not. A claim is never released for an uncovered machine |
| A superseded part is never ordered | The draft is refused with the replacement part named. The check runs again when the approval is decided |
| Stock is real | A draft is refused when the chosen dealer lacks the quantity, and the stock is checked again at approval. The approval takes the stock in the same transaction |
| No order for a flapping sensor | Telematics that spikes on and off without a trend is classified `sensor_flapping`. A parts order for that machine is refused, and so is a proactive case |
| Safety-critical requests go to a person | A fault code marked safety critical, a request the dealer flags with `"safety": true` on `POST /requests`, or a case sent to a person with `escalate_to_person`, cannot reach an approval. A case in `needs_person` (escalated, or rejected by a manager) cannot be moved back by the REST status route (the equipment tools have no status tool): it refuses it, and this build has no reopen route. **Screening of a request that has no fault code and no flag relies on the agent calling `escalate_to_person`**; the dealer manager reading the approval is the remaining guard |
| Fleet sweep | `list_fleet_trends` compares each machine's coolant over the last 14 days with 30 to 60 days ago. A rise of 8 degrees or more is `trending_to_failure`. `open_proactive_case` works only for those machines, once per machine |
| Only approved drafts leave | The approval queues exactly the kinds in its payload and discards the rest |
| Slots are not hoarded | A held slot is freed when the case is escalated, when a manager rejects, and when a change supersedes a pending approval (the agent holds one again). One dealer can have at most 10 slots on hold |
| Fault events are bounded | A fault that an open case already covers is stored at most 5 times per machine and code each day, then answered with the open case without a new row |
| Approvals do not go stale for no reason | The payload holds the warranty decision and a basis text with no month or hour counts, and `stock_sufficient` instead of the stock count, so a day passing or another case taking stock does not change the hash. Everything else the approver sees still does |
| Free text is data | The dealer's note, the diagnosis, the work order and the drafts reach the agent in fields named `untrusted_...` |

Hard cases in the seed: an out-of-warranty machine, a part that is empty at the nearest dealer (and a superseded part
that is empty at the two nearest), a fault repeated four times in 60 days on one machine, a dealer note that tries to
give orders to the agent, a safety interlock request, and a flapping sensor. Telematics is every 6 hours for 90 days
(the plan says hourly; this keeps the seed small).

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
- The equipment domain has the same status: unit tested only, not in the chart, not run on a cluster, no agent uses it. There is no graph or knowledge base seed yet, and no BigQuery or calendar import.
- There is a per-host write limit and a limit on refused logins, but no lockout on approver tokens, and tokens are unsalted SHA-256, which is fine only for long random tokens.
- The decision's audit row is written after the commit and is best effort (the stdout line is the record of truth).
- The REST agent-step routes have no login; the loopback default is the only guard until the chart adds a network policy.
- Working days skip weekends only. Public holidays are not modelled.
- The service has run only under `go test`, with the Go MCP SDK client over HTTP.

## Layout

```
cmd/records/       main: wiring, listeners, timer ticker
internal/core/     store, audit, approver auth, approval queue, timers, outbox, HTTP helpers (shared by every domain)
internal/bank/     schema, seed, service, REST routes, MCP tools
internal/equipment/ the same layers for the equipment domain
Dockerfile         ARG DOMAIN=bank; base images pinned by digest; non-root; data in /data
```
