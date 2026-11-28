# ADR 0030: knowledge base isolation per tool group, and an optional graph schema per collection

Status: Proposed
Date: 2026-11-28
Issue: https://github.com/openagentix/openagentix/issues/272 (graph schema), reference use cases #229 (the shared knowledge base)
Replaces: none. Builds on ADR 0004 (knowledge graph), ADR 0006 (tool profiles), ADR 0025 section 4 (credentials as mounted files) and ADR 0026 (tool groups, mirror entries, header credentials). Depends on ADR 0031 (proposed) for one threat, named in "What this does not stop". See "Relation to other records".

Two per-collection settings for the knowledge base. First, **isolation**: the operator lists, per tool profile, the collections its agents may read; the knowledge base itself enforces the list, on a bearer value that each tool group's entry sends and that the knowledge base checks. `kb_search` without a collection searches only the caller's collections. Writes stay an operator path. Second, an optional **graph schema** per collection: entity types with a key pattern, relation types with the entity types allowed at each end. A graph load that does not fit is refused, and one read tool shows the schema to the agent. Both are off by default. With them off, the chart renders byte for byte what it renders today, and the knowledge base behaves as today, which means **no isolation**: every caller reads every collection. Nothing here is built. Everything is *unverified* until the slices below are done.

## Context

Read in this repository on 2026-11-28.

### Who can read what today

- **The MCP path has no login.** `services/kb/internal/server/server.go` mounts `/mcp` with no check. The only boundary is the network policy `kb-ingress` (`charts/openagentix/templates/knowledge.yaml`), which admits the shared tool server and every profile tool server by pod label. The chart's own comment says so: "/mcp has no authentication, so it must be reachable only from" the tool servers.
- **Every tool takes any collection.** In `services/kb/internal/mcpserver/mcpserver.go` and `graph.go`, `kb_search`, `kb_graph_search`, `kb_graph_entity` and `kb_graph_paths` take an optional `collection` ("omit to search all"); `kb_list_collections` lists every collection; `kb_get_document` finds a document id in any collection.
- **What the knowledge base learns about a caller: nothing.** Each tool group has one entry for the knowledge base: `knowledge` in the shared group, and a mirror `knowledge-<group>` in every group that a profile on it needs (ADR 0026 A3, `templates/endpoints.yaml`; `knowledge-diagnostics` for ADR 0025). Every one uses an `MCPExternalAuthConfig` of `type: unauthenticated` and no header. The tool server does not forward the caller's token or claims (ADR 0025 Amendment 1). So the request carries no name of an agent, a profile or a group.
- **The smallest unit that could ever be told apart is a tool group.** The entry is per group, not per profile. And every tool server pod of a group gets the header value of every entry of the group (ADR 0025 Amendment 1, ADR 0026 A3). A header per profile would sit in every pod of the group, so two profiles of one group cannot be told apart by a header.
- **The prompt is the only fence.** The bank profile `disputes` and the equipment profile `dealer` both list the six knowledge tools; each agent's prompt names its collection (`fernvale-disputes`, `kestrel-service`). `docs/diary/what-works.md` (equipment row): "each profile can read the other's collection". The knowledge base row: "no per-collection authorization".

### Who can write

- Writes go only through the admin API under `/v1` (`services/kb/internal/api/api.go`): documents and curated fact sets, for any collection, with one bearer value `KB_ADMIN_TOKEN` from the Secret `kb-admin`. The MCP tools are all read-only (`ReadOnlyHint`); there is no write tool.
- The use case installers write with `hack/kb-ingest.sh` and `hack/kb-graph-load.sh`, which read the admin token from the cluster as the operator.

### The graph today

- Entity types are a closed list of nine (`services/kb/internal/graph/validate.go`: service, team, person, system, location, organization, product, event, concept). Predicates are any snake_case word. A curated fact set is checked for shape only (`graph/factset.go`). The store's `type` column is free text (`internal/store/postgres/migrations/0003_graph.sql`).
- Issue #272 records what went wrong in the first real-model runs: the bank's graph used other case ids than the records; a part had two names; one rule was stated three ways. Each was fixed by a hand-written test per use case. The bank seed (`examples/use-cases/bank/seed/graph/dispute-facts.yaml`) names cases as `event` and merchants as `organization`; nothing checks that a case name has the records' form.

### Memory

Agent memories are kept by the runtime in its own database (the `memory` block, ADR 0006 round 3, `openagentix-kagent-pg` in ADR 0025 section 5), not in the knowledge base store. They are **out of scope** here.

## Options

### Where the list of collections is enforced

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. The prompt (today) | Nothing to build | A model can be told, by a document or a case text, to search another collection; nothing stops it | The two use case prompts |
| B. Hide tools per profile | Already built (profile filter) | A tool cannot be hidden per collection: `kb_search` takes any collection string | `mcpserver.go` |
| C. The knowledge base enforces a list per caller, on a bearer value per tool group that it checks; the list is a chart value rendered into the knowledge base's own configuration | The model cannot widen it; a pod without the value is refused; the operator writes the list | One more value per group in two Secrets; every kb entry gets a header; a header Secret in the tools namespace is readable by every tool server there until ADR 0031 | The header path was shown live (ADR 0026 slice 2); the rest is new code |
| D. A new resource kind now | One design for chart agents and definitions | A kind, a reconciler and a guard, before the chart path is shown | ADR 0007 |

### What identifies the caller

| Option | What it gives | What it costs |
|---|---|---|
| 1. Source address or pod labels | No secret | Labels can be copied by anyone who may create pods in the tools namespace (ADR 0026 A5); the knowledge base would have to read pods from the API |
| 2. A header the caller sets and the tool server passes on | Per agent | The caller chooses it. Refused, as ADR 0025 section 7 refused it |
| 3. One bearer value per tool group on the group's kb entry, checked by the knowledge base | Uses the header path already shown live; the knowledge base checks a value it holds as a file | Per group, not per profile or agent; static; readable through the API by every tool server in the tools namespace until ADR 0031 |
| 4. One value per profile | Looks finer | Every pod of the group holds every value of the group, so it is not finer |
| 5. The tool server's own ServiceAccount token with an audience, checked by the knowledge base | No shared value | ToolHive 0.67.1 has no outgoing auth type that sends it (read in ADR 0031) |

## Decision

Option C with identity 3. The list lives on the tool profile, is enforced per tool group by the knowledge base, and a later resource takes it over. The graph schema is stored by the knowledge base, set by the operator through the admin API, and enforced on every graph load.

### 1. Chart values

```yaml
knowledge:
  access:
    mode: ""                      # "" (default): as today, no check, every caller reads every collection
                                  # "report": a bearer value is checked when sent, nothing is refused, each would-be refusal is logged
                                  # "enforce": a call without a known value is refused, each caller reads only its collections
    sharedGroupCollections: []    # the collections the shared tool server and every profile on the shared group may read
  kb:
    graph:
      schemas:
        enabled: false            # true: the schema routes and the read tool kb_graph_schema exist (needs graph.enabled)

mcp:
  profiles:
    - name: disputes
      knowledgeCollections: [fernvale-disputes]   # only on a profile on a tool group of its own; read only when knowledge.access.mode is set
```

| Value | Rule (each refusal fails the render with a sentence that names the fix) |
|---|---|
| `knowledge.access.mode` | `""`, `report` or `enforce`, quoted. Set while `knowledge.enabled` is false: refused |
| `knowledge.access.sharedGroupCollections` | Collection names as the knowledge base accepts them (`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`), unique |
| `mcp.profiles[].knowledgeCollections` | Same name rule. Refused on a profile on the shared group (use `sharedGroupCollections`). Two profiles on one group with different lists: refused, because the knowledge base tells groups apart, not profiles. With `mode: enforce`, a profile that lists a knowledge tool while its group may read no collection: refused. Accepted while `mode` is `""`, with no effect, so a use case can ship its list before the operator turns the check on |
| `knowledge.kb.graph.schemas.enabled` | Needs `knowledge.kb.graph.enabled` |

No new field on a resource. Definitions use only profiles on the shared group (ADR 0026 decision 11), so they get `sharedGroupCollections`; a definition cannot choose a collection.

### 2. The binding: one caller per tool group

- **Callers.** One caller per tool group that holds a kb entry: the shared group (`mcp.groupName`), `diagnostics` when a diagnostics profile lists a knowledge tool, and each endpoint group with a mirror. The caller's name is the group's name. Its collections: `sharedGroupCollections` for the shared group, the `knowledgeCollections` of its profiles for the others.
- **Values.** With `mode` set, `install.sh` creates one random value per caller, never printed, kept on re-runs (the ADR 0025 section 4 rules): a Secret `kb-caller-<group>` (key `value`, the whole header value `Bearer <token>`) in `mcp.namespace`, and the same value as key `<group>` of one Secret `kb-callers` in `knowledge.namespace`. The chart renders references only. The control plane never reads, copies or names them.
- **Entries.** Every kb entry (`knowledge`, each `knowledge-<group>`) renders `headerForward.addHeadersFromSecret` with `Authorization` from `kb-caller-<group>`, next to its `unauthenticated` auth config, as ADR 0026 A4 does for endpoints. No tool server renders a pass-through of caller headers; a chart test pins it.
- **The knowledge base's configuration.** A ConfigMap `kb-access` in `knowledge.namespace` holds `access.json`: the mode and, per caller, its name and collections, never a value. It is mounted read-only, `kb-callers` is mounted as files under `/var/run/secrets/openagentix/kb-callers/`, and a checksum annotation of `access.json` rolls the pod on change. Both are rendered from chart values; nobody edits them by hand.
- **Install check.** After the apply, `install.sh` fails when a tool server of a group with a kb entry reports `DiscoveredAuthConfig-<entry>` False or the kb backend not `ready` (the ADR 0026 A4 check, extended to kb entries).

### 3. What the knowledge base does

- **No `access.json`** (mode `""`): exactly today's behaviour.
- **`report`:** a request with a known value is tagged with its caller; one without, or with an unknown value, is tagged `none`. Nothing is refused or filtered. Each tool call logs `caller` and `outside_list: true` when `enforce` would have refused or filtered it. This mode exists for the switch-over and the live proof.
- **`enforce`:** a request to `/mcp` without a known value gets 401 before any MCP handling, `initialize` included. Otherwise:
  - `kb_list_collections` lists only the caller's collections that exist.
  - `kb_search` and the graph tools without `collection` search only the caller's collections. With a collection outside the list, the answer is the one for a collection that does not exist (no results, or no such entity). Never "forbidden", so the name of another collection is not confirmed.
  - `kb_get_document` looks only in the caller's collections. "Not found" and "in more than one collection" count only those.
  - The filter is part of the store query, not applied after ranking, so `top_k` and the graph walk see only allowed rows.
- **Values** are compared as SHA-256 digests in constant time (as the admin API does), read from the files on each request, so a new value in the Secret needs no restart of the knowledge base (the tool servers' environment value still needs one, ADR 0026). No value appears in a log line, an error, a metric or a tool result. The log line of a tool call gains `caller`, the group name.
- **A bad `access.json`** (unknown key, bad name, a caller whose file is missing) stops the start with a message that names the item. The admin API is unchanged.

### 4. Writes

- Only the operator writes: the admin API with `kb-admin`, any collection, as today. That covers documents, fact sets and (section 5) schemas. The use case installers are operator steps and keep using it.
- No MCP write tool. A test pins that every tool the knowledge base registers is read-only; adding a write tool needs a new record.
- Not in this record: a writer value per collection, so that a team could load its own collection without the admin token (open question 4).

### 5. Graph schema per collection

**Format.** JSON over the admin API; a YAML file through a script. Small on purpose. The example is a part of what the bank could declare, not its full schema.

```yaml
version: 1
entityTypes:
  - name: case
    key: "Case DSP-[0-9]{4}-[0-9]{4}"      # optional; must match the whole entity name
    description: A dispute case of the records service
  - name: merchant
    key: "M-[0-9]{3} .+"
  - name: device
    key: "Device dev-[0-9a-f]{8}"
  - name: reason_code
  - name: rule
relationTypes:
  - {name: disputes_charge_at, from: [case], to: [merchant]}
  - {name: seen_on_device, from: [case], to: [device]}
  - {name: has_reason_code, from: [case], to: [reason_code]}
  - {name: applies_to, from: [rule], to: [reason_code]}
```

| Field | Rule |
|---|---|
| `version` | Integer, 1 to 2,147,483,647. A new schema must carry a higher version than the stored one; the same body again changes nothing |
| `entityTypes[].name` | `^[a-z][a-z0-9_]{1,39}$`, unique, at most 50 types |
| `entityTypes[].key` | Optional. RE2 syntax, at most 200 characters, matched against the whole entity name (the knowledge base anchors it), case-sensitive. Aliases are not checked against it |
| `relationTypes[].name` | The predicate form fact sets use (snake_case after normalising), unique, at most 100 types |
| `relationTypes[].from`, `.to` | Non-empty lists of declared entity type names, at most 10 each |
| `description` | Optional on both, at most 200 characters |
| body | Unknown fields refused, at most 64 KiB |

What it is not: no subtypes, no inverse or symmetric relations, no cardinality, no required relations, no inference, no OWL, RDF or SHACL. With a schema, the collection's entity types are exactly the schema's types; the built-in list of nine applies only to collections without one.

**Where it is stored.** In the knowledge base's database, one row per collection (a new table, created by a migration only when schemas are on): the body, the version, a SHA-256 of the body and the time. Routes, with the admin token:

- `PUT /v1/collections/{collection}/graph/schema`
- `GET /v1/collections/{collection}/graph/schema` (body, `version`, `sha256`)
- `DELETE /v1/collections/{collection}/graph/schema`

`hack/kb-graph-schema.sh <collection> <file>` sends a file, with the transport and the token handling of `hack/kb-graph-load.sh`.

**Enforced on graph load.** A fact set `PUT` into a collection with a schema is refused (422) when an entity's type is not declared or its name does not match the key, or a relation's predicate is not declared or its ends have types the relation does not allow. Nothing of it is stored. The answer lists the first 20 violations, each as `at` (`entities[3]`, `relations[7]`) and `rule` (`type`, `key`, `predicate`, `from`, `to`), plus `more` (the count not shown). Like today's fact set errors, it names items by index and never repeats what the operator wrote.

**Extraction from documents.** In a collection with a schema, no extraction job is queued for a new or changed document, and pending jobs of that collection are skipped. The documents are still chunked and searchable. So a collection with a schema has only curated facts. Extraction under a schema (the prompt lists the schema's types, the output is filtered by it) is a later record (open question 5).

**A schema change against existing facts.** A `PUT` checks every fact already in the collection (from every fact set, and any extracted fact) against the new schema, in the same transaction. Any violation refuses the change (409) with the same list. So a breaking change goes in steps: add the new type or relation (version n+1), reload the fact sets, remove the old one (version n+2). Extracted facts carry the built-in types; to put a schema on a collection that has them, delete its documents (their extracted facts go with them, `ON DELETE CASCADE` in `0003_graph.sql`), set the schema, and load the documents again. `DELETE` of a schema is always allowed; the facts stay, and extraction resumes for documents loaded afterwards.

**The read tool.** `kb_graph_schema`, read-only, registered only when schemas are on. Input `collection` (optional). With it: that collection's schema with its version and hash, or a line that it has none and the built-in types apply. Without it: every collection the caller may read that has a schema. It follows section 3 like every other tool. With the graph and schemas on, `knowledge: true` adds its name to the agent's tools (`oa.knowledgeTools`), and a profile lists it like the other knowledge tools.

### 6. Off by default, and the warning

- With `knowledge.access.mode: ""` and `knowledge.kb.graph.schemas.enabled: false` (the defaults), no ConfigMap, Secret reference, volume, env value or header renders, and the chart renders byte for byte what it renders today. The chart tests compare the default, the quick start and the full demo renders before and after each slice.
- **Unchanged behaviour is no isolation.** Every caller reads every collection, as today. The docs and `what-works.md` say so.
- **A team opts in** with `mode: report`, checks the log, then `mode: enforce`, in a values file passed on every run (Helm replaces values).
- **Warning, not refusal, for now.** `install.sh` prints a warning when the composed values leave `mode` empty while profiles on two or more tool groups list a knowledge tool, and names the groups. A render refusal would break the installs that run two use cases today; it can come with the record that turns the check on by default (open question 3).
- **No silent loss.** `install.sh` refuses an upgrade that changes `mode` from `enforce` on the live release to anything else, unless `ALLOW_KB_ACCESS_OFF=1`. This is how a forgotten values file would otherwise turn isolation off.

### 7. What this stops, and what it does not

| Threat | Stopped? |
|---|---|
| The model is told, by a document, a case text or a user, to search or open another collection | Yes, with `enforce`: the knowledge base answers as if the collection did not exist |
| An agent on another tool group reads this group's collection | Yes: its group's value maps to its group's list |
| A pod that is not a tool server calls `/mcp` | Yes: no value, 401 (the network policy stays as the first layer) |
| Two profiles or two agents on one tool group | No. One group, one caller, one list. Profiles that must not share collections need groups of their own |
| A tool server of another group reads this group's `kb-caller-<group>` Secret through the API and sends it | **No, until ADR 0031.** Every tool server ServiceAccount in `mcp.namespace` can read its Secrets today (ADR 0026 A3) |
| Anyone who can create pods or read Secrets in `mcp.namespace` or `knowledge.namespace` | No. That is operator trust |
| Collections at rest | No change: one database, one schema, one database role |

### 8. Status and claims

- No resource status changes. The controller cannot see what the knowledge base enforces, so nothing in a status says it. A later resource that holds the lists reports what it rendered, and `unknown` for enforcement.
- **What must not be claimed:** that the knowledge base isolates tenants against a compromised tool server before ADR 0031 is built; that profiles or agents of one group are separated; that writes are limited per collection; that collections are separated at rest; that the graph schema is an ontology or reasons over facts; that extracted facts follow a schema (a collection with a schema has no extracted facts); that a schema improves answers, until the use case evaluation sets are run with and without it (issue #272); anything in `report` mode beyond "would have been refused".

### 9. Migration: the three use cases beside a full demo

- **Software organisation.** Its profile `rca` lists no knowledge tool. Nothing changes.
- **Bank and equipment.** Their values gain `knowledgeCollections` on `disputes` (`fernvale-disputes`) and `dealer` (`kestrel-service`). With `mode` empty this changes no render, so the release-values guard of their installers and `ALSO_COMPOSE` work as today. `hack/compose-values.sh` merges profiles by name, so each list travels with its profile.
- **Turning it on.** A new file `components/knowledge/access-demo-values.yaml` sets `mode` and `sharedGroupCollections` (the full demo's `openagentix` and `graph-canary`). It goes into the full demo's `VALUES_FILE` list once, then on every run of every installer, the use case installers with `--beside-full-demo` included. `knowledge.access.*` joins the security keys of `hack/compose-values.sh` (a later file may not change it without `--later-wins`), and the use case installers' release-values guard accepts it when it is in `VALUES_FILE`. First `report`, one evaluation run of each use case, then `enforce`.
- **Schemas.** Each use case ships `seed/graph/schema.yaml`. On a new install the installer sets the schema before it loads documents. On an install that has the collection already, it deletes the use case's documents, sets the schema, loads the documents and the fact set again (synthetic seed data, loaded by the installer anyway).
- **Scripts that call `/mcp` directly** (`hack/kb-graph-canary.sh`, `hack/ci/upgrade-test.sh`) send the shared group's value when `mode` is set.

## Consequences

- Possible: two use cases on one knowledge base with collections the other cannot read through any tool; a refusal of graph facts whose ids do not fit the records' form, before an agent sees them; an agent that can ask which entity and relation types exist.
- Harder: one more value per tool group, two Secrets each, created by the installer; a list per profile that the operator keeps; profiles on one group must agree; a collection with a schema has no extracted facts.
- Ruled out for now: per-profile or per-agent collection rights; writer rights per collection; extraction under a schema; inference.
- Security impact: with `enforce`, the knowledge base refuses a caller without a known value and filters every read by the caller's list. New Secrets in two namespaces, made by the installer, mounted as files in the knowledge base pod and as environment values in the tool server pods (the upstream path). The knowledge base logs the caller's group name, never a value. Nothing new leaves the cluster. The control plane reads no Secret. Security-relevant: slices 2, 3 and 4 get an independent review.
- Compatibility: none with the defaults. Turning `mode` on rolls the knowledge base and every tool server with a kb entry, once.
- Proof needed: the tests and live checks of the slices below.

## Relation to other records

| Record | Relation |
|---|---|
| ADR 0004 | The graph and its fact sets stay; a schema adds a check on load and turns extraction off for that collection |
| ADR 0006 | A profile gains the list of collections its agents read |
| ADR 0025 | The values follow section 4 (installer-made, mounted as files in the knowledge base); the `diagnostics` group is one caller |
| ADR 0026 | The header path of A4 and the mirror entries of A3 carry the value; decision 11 (definitions only on shared-group profiles) is why definitions get the shared list |
| ADR 0031 (proposed) | Closes the reach of other tool servers to the `kb-caller-<group>` Secrets. Until it is built, row 5 of the table in section 7 stays open |
| ADR 0007 | A later resource holds the list per profile; the chart value maps to it one to one |

## Slices

Each slice is one pull request that `Refs #272`, tests first, off by default, with a changelog line when users can see it. Slices 2, 3 and 4 are security-relevant and get an independent review before merge. Live proof runs on a separately named throwaway kind cluster with its own kubeconfig and the stub model, never on the maintainer's cluster, unless a step says a real model.

1. **This record.** Docs build.
2. **The knowledge base: callers and filtering** (`services/kb`). `access.json`, the value files, the three modes, the filter in the store query (memory and PostgreSQL stores), `caller` in the log line. Tests: each tool with an allowed, a refused and an omitted collection, in each mode; 401 without and with a wrong value; `top_k` full when another collection has better matches; a document id in an allowed and a refused collection; a changed value file used on the next request; a canary value in no log line, error or metric; a bad `access.json` stops the start; `make -C services/kb test-integration` on PostgreSQL. Live: the image on kind with a hand-written `access.json` and two Secrets, called through a port-forward: each answer of the tests above, once.
3. **Chart and installer** (`knowledge.access.*`, `mcp.profiles[].knowledgeCollections`). Values, refusals, ConfigMap, mounts, checksum, `headerForward` on every kb entry, the installer's values, the install check, the warning, the refusal to turn `enforce` off, the compose security key. Chart tests: default, quick start and full demo renders byte-identical with `mode: ""`; one test per refusal; no pass-through header on any tool server; the values are in no rendered object. `make test-apiserver`: kb entries with `headerForward` pass a server-side dry run. Installer tests with fakes: Secrets created once and kept, never in an argument. Live: the full demo with the bank and equipment use cases (`--beside-full-demo`, `ALSO_COMPOSE`), first `report` (the log shows `caller` per call), then `enforce`: the dispute agent's `kb_list_collections` lists only `fernvale-disputes`, `kb_search` without a collection finds no equipment document, a search in `kestrel-service` returns nothing; the reverse for the equipment agent; the shared tool server sees only `openagentix` and `graph-canary`; a pod in `mcp-tools` without the value gets 401; every backend stays `ready`; record the answer of `kubectl auth can-i get secret/kb-caller-dealer -n mcp-tools` for the `disputes` tool server (expected yes until ADR 0031).
4. **Graph schema in the knowledge base.** The table, the three routes, validation, the check on fact set load, the check on a schema change, the extraction skip, `kb_graph_schema`. Tests: each rule of the format; each violation kind with its `at` and `rule`; 20 shown and `more` counted; a version not higher refused; the same body twice unchanged; a change refused against an existing fact set; extraction not queued in a collection with a schema; `DELETE` keeps the facts; the read tool under each access mode. Live: on kind, a schema set, a bad fact set refused with its first violations, a good one loaded, a breaking change refused, the read tool through a profile.
5. **Chart and script for schemas.** `knowledge.kb.graph.schemas.enabled`, the tool name in `oa.knowledgeTools`, `hack/kb-graph-schema.sh` with shell tests (dry run, YAML and JSON, the token never in an argument). Chart tests: default render byte-identical; refused without the graph. Live: the script against the kind install of slice 4.
6. **The use cases.** Bank and equipment ship a schema and the order of section 9; their hand-written seed agreement tests are cut to what the schema does not cover; their profiles list `kb_graph_schema`; `components/knowledge/access-demo-values.yaml`. Live: the migration of section 9 on a throwaway cluster with all three use cases beside a full demo; then, on a real model, each evaluation set run with and without the schema, with the counts in the diary. `what-works.md` rows, README sections and the diary, with the limits of section 7.

## Not checked / open points

- *Unverified*: everything above; that `headerForward` on a mirror entry of the knowledge base behaves as on an endpoint entry (ADR 0026 slice 2 showed it for endpoints only); that a tool server keeps the kb backend `ready` after the knowledge base starts refusing calls without a value (the order of the roll-out in one upgrade); the cost of the filter in the store query on a large collection; whether deleting a document removes every extracted fact of it in practice (read in the schema, not run).
- Read again before quoting: the ToolHive version pinned by `components/tools/install.sh` and its `headerForward` fields.

### Open questions, with recommended answers

1. **Where the list lives.** On the profile (`mcp.profiles[].knowledgeCollections`), with one list per group enforced, or one map keyed by group in the `knowledge` block? *Recommended:* on the profile. A use case owns its profile, the compose helper merges profiles by name, and a later resource holds rights per profile. The rule that profiles of one group must agree keeps the enforcement honest.
2. **Keep the `report` mode?** *Recommended:* yes. It lets a team turn the check on without an outage and gives the live proof a log of every call that would change.
3. **Refuse a render with a shared knowledge base and no list?** *Recommended:* not now. A warning in `install.sh` and the refusal to turn `enforce` off. A refusal comes with the record that makes `enforce` the default, after one release with the reference use cases on it.
4. **Writer rights per collection.** *Recommended:* not in this record. Writes stay with the operator's admin token. A team that needs to load its own collection gets a separate record with writer values per collection.
5. **Extraction in a collection with a schema.** *Recommended:* off in this record. Curated facts are what the use cases load, and extraction under a schema needs a new prompt version and its own measurements.
6. **Build order against ADR 0031.** *Recommended:* build slices 2 and 3 first. They close the path the use cases actually showed (the model reading the other collection). Claim isolation against a compromised tool server only after ADR 0031's chart slice is live.
