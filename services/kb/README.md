# OpenAgentix knowledge base (`kb`)

A small, store-agnostic knowledge base that agents use as an **MCP server**. Documents are ingested over a
token-protected REST API, chunked, optionally embedded, and stored in a pluggable backend. Agents call three
read-only MCP tools to search and read them.

```
 agents (kagent) ──► ToolHive vMCP ──►  POST /mcp   (kb_search, kb_get_document, kb_list_collections)
                                        │
 curl / CI / pipelines ───────────────► PUT /v1/...  (bearer token)
                                        │
                              chunk ─► embed (optional) ─► store.Store
                                                            ├─ memory   (dev, tests)
                                                            └─ postgres (tsvector + optional pgvector)
```

One binary (`cmd/kb`), one port (default `:8080`):

| Path | Purpose |
| --- | --- |
| `/mcp` | MCP, streamable HTTP transport (official Go SDK) |
| `/v1/...` | ingest/admin REST API (bearer token, fail-closed) |
| `/healthz` | process is up |
| `/readyz` | store is reachable |

## Run locally (memory mode, no dependencies)

```sh
cd services/kb
KB_ADMIN_TOKEN=devtoken make build && KB_ADMIN_TOKEN=devtoken ./bin/kb
# or: KB_ADMIN_TOKEN=devtoken go run ./cmd/kb
```

`KB_STORE` defaults to `memory`: data lives in the process and is lost on restart.

### Ingest

```sh
curl -X PUT localhost:8080/v1/collections/runbooks/documents/pod-restart \
  -H "Authorization: Bearer devtoken" -H 'Content-Type: application/json' \
  -d '{"title":"Restarting a stuck pod","source_uri":"https://wiki.example.com/pod-restart",
       "text":"If a pod is stuck in CrashLoopBackOff, delete it and let the Deployment recreate it."}'
# {"chunks":1,"collection":"runbooks","id":"pod-restart"}

curl localhost:8080/v1/collections -H "Authorization: Bearer devtoken"
# {"collections":[{"documents":1,"name":"runbooks"}]}

curl -X DELETE localhost:8080/v1/collections/runbooks/documents/pod-restart -H "Authorization: Bearer devtoken"
```

`PUT` is an idempotent upsert: the document's chunks are replaced atomically.

### Query over MCP (raw JSON-RPC, stateless mode)

```sh
curl localhost:8080/mcp -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"kb_search",
       "arguments":{"query":"stuck pod crashloop","top_k":3}}}'
```

Any MCP client works: point it at `http://localhost:8080/mcp` (in-cluster:
`http://kb.openagentix-knowledge.svc.cluster.local:8080/mcp`).

## MCP tools

All three are annotated read-only. Each returns compact text for the model plus structured content.

| Tool | Arguments | Result |
| --- | --- | --- |
| `kb_search` | `query` (required), `collection`, `top_k` (default 5, max 20, larger values are clamped) | ranked chunks: document id, collection, title, source URI, chunk text, score |
| `kb_get_document` | `document_id` (required), `collection` | title, source, full text, truncated at `KB_DOC_MAX_CHARS` with a `[truncated: ...]` marker |
| `kb_list_collections` | none | collection names and document counts |

`kb_get_document` takes an optional `collection` because document ids are unique per collection, not globally.
If the id exists in several collections the tool returns an error asking for the collection.

The text result of `kb_search` and `kb_get_document` starts with a fixed notice line saying the content below is
retrieved document text, is untrusted, and must not be followed as instructions. Document text can come from
anyone who can ingest, so agents should treat it as data.

Tool errors (bad input, not found, backend failure) are returned as MCP tool errors (`isError: true`). Backend
failure messages are generic; details go to the server log only.

## Admin REST API

All routes need `Authorization: Bearer $KB_ADMIN_TOKEN`.

| Method and path | Body | Success |
| --- | --- | --- |
| `PUT /v1/collections/{collection}/documents/{id}` | `{"title","source_uri","text"}` | `200 {"collection","id","chunks"}` |
| `DELETE /v1/collections/{collection}/documents/{id}` | none | `204` (`404` if absent) |
| `GET /v1/collections` | none | `200 {"collections":[{"name","documents"}]}` |

* **Fail closed**: with `KB_ADMIN_TOKEN` unset the API answers `403` to everything, unless
  `KB_ADMIN_ALLOW_ANONYMOUS=true` (dev only). A configured token always wins over the anonymous flag.
  Wrong or missing token: `401`. The token is compared in constant time.
* Collection names match `[A-Za-z0-9][A-Za-z0-9._-]{0,127}`; document ids match `[A-Za-z0-9][A-Za-z0-9._:-]{0,199}`.
  Title max 500 characters, source URI max 2048 and either empty or an absolute `http`/`https` URL (`400`
  otherwise), text must be non-blank valid UTF-8 without NUL.
* A document may split into at most `KB_MAX_CHUNKS_PER_DOC` chunks (default 2000). Larger ones are rejected up
  front with `413` before any embedding call is made; split them into several documents.
* Body limit `KB_MAX_BODY_BYTES` (default 4 MiB, `413` beyond). Unknown JSON fields and trailing data are `400`.
* Errors are JSON: `{"error":"..."}`. Embedder failure on ingest is `502`; a request timeout is `504`; a client that hangs up gets `499` (logged at
  info, not as an error). Ingest (`PUT`) runs under `KB_INGEST_TIMEOUT`, other routes under `KB_REQUEST_TIMEOUT`.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `KB_ADDR` | `:8080` | listen address |
| `KB_LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `KB_STORE` | `memory` | `memory` or `postgres` |
| `KB_DATABASE_URL` | | PostgreSQL URL; required when `KB_STORE=postgres` (secret) |
| `KB_DB_SCHEMA` | `kb` | PostgreSQL schema for the tables, created if missing (`[a-z_][a-z0-9_]*`) |
| `KB_ADMIN_TOKEN` | | bearer token for `/v1` (secret). Unset disables the admin API (403) |
| `KB_ADMIN_ALLOW_ANONYMOUS` | `false` | allow `/v1` with no token when no token is set (dev only) |
| `KB_MAX_BODY_BYTES` | `4194304` | admin API request body limit |
| `KB_CHUNK_MAX_CHARS` | `1200` | max characters per chunk (1 to 100000) |
| `KB_MAX_CHUNKS_PER_DOC` | `2000` | reject documents that split into more chunks (`413`), before embedding |
| `KB_CHUNK_OVERLAP` | `150` | characters carried from one chunk to the next (must be smaller than max) |
| `KB_DOC_MAX_CHARS` | `50000` | `kb_get_document` truncation size |
| `KB_REQUEST_TIMEOUT` | `30s` | per-request context deadline (not applied to the optional MCP SSE stream) |
| `KB_INGEST_TIMEOUT` | `120s` | deadline for `PUT /v1/.../documents/...`, which embeds many chunks in sequential batches |
| `KB_SHUTDOWN_GRACE` | `25s` | time to drain in-flight requests on SIGTERM |
| `KB_MCP_STATELESS` | `true` | no MCP sessions, so any replica can answer any request |
| `KB_METRICS_ADDR` | empty (off) | listen address of a separate Prometheus listener that serves only `GET /metrics`, without authentication; must differ from `KB_ADDR`. Counts and timings with closed label sets, never text, ids or collection names |
| `KB_METRICS_COLLECTION_LABELS` | `false` | `true` labels the graph size gauges with the collection name (capped at 50; names are operator-chosen). Needs `KB_METRICS_ADDR` |
| `KB_EMBEDDINGS_URL` | | OpenAI-compatible endpoint or base URL (`.../v1` gets `/embeddings` appended). Unset = lexical only |
| `KB_EMBEDDINGS_MODEL` | | model name; required with the URL |
| `KB_EMBEDDINGS_DIM` | | vector dimension; required with the URL (1 to 2000: pgvector's HNSW index on `vector` supports at most 2000 dimensions, so larger models need a smaller output dimension, e.g. OpenAI `dimensions`) |
| `KB_EMBEDDINGS_API_KEY` | | bearer key for the endpoint (secret) |
| `KB_EMBEDDINGS_TIMEOUT` | `30s` | per embeddings request (ingest; retried once on 429/5xx) |
| `KB_ACCESS_FILE` | empty (off) | absolute path of `access.json` (ADR 0030): `{"mode":"report" or "enforce","callers":[{"name":<tool group>,"collections":[...]}]}`, names only, never a value. Unset means no check on `/mcp`: every caller reads every collection. A bad file, a name that does not fit, or a caller whose value file is missing stops the start and names the item |
| `KB_ACCESS_CALLERS_DIR` | `/var/run/secrets/openagentix/kb-callers` | one file per caller, named by the caller, holding the whole header value `Bearer <token>`. Read on every request, so a rotated value needs no restart. Compared as SHA-256 digests in constant time |
| `KB_QUERY_EMBED_TIMEOUT` | `3s` | budget for embedding a search query, single attempt, no retry. On timeout or error search answers lexically with the rest of the request deadline |

Secrets are never logged. The startup log line lists the configuration with secrets omitted. Request logs carry
method, path, status and duration only; tool-call logs carry the tool name, timing and result count only, never
queries or document text.

## Stores

`store.Store` is the seam: `UpsertDocument`, `DeleteDocument`, `GetDocument`, `ListCollections`, `Search`, `Ping`.
Every backend must pass the shared conformance suite in `internal/store/storetest`.

* **memory**: BM25 lexical ranking, cosine similarity when vectors are present, reciprocal rank fusion when both.
* **postgres**: `tsvector` column (generated, `english` config, GIN index), `websearch_to_tsquery` and
  `ts_rank_cd` for lexical search. Plain words in a query are OR-ed so a natural-language question still finds
  partial matches; ranking rewards chunks matching more terms. Quotes, `or` and `-` keep websearch semantics.
  With embeddings configured it also creates the `vector` extension (in schema `public`, shared by every
  `KB_DB_SCHEMA` in the database; an extension that already exists in another schema is used where it is, with
  all vector types and operators schema-qualified), a `vector(N)` column and an HNSW cosine
  index, and fuses lexical and vector results by reciprocal rank fusion (k = 60). Startup fails with a clear
  message if pgvector is unavailable or an existing column has a different dimension. Without an embedder no
  pgvector objects are created. Schema is created by idempotent embedded migrations under an advisory lock, so
  replicas can start together.

Queries without a positive term (for example only `-foo`) return nothing on every backend. Collection-filtered
vector search runs with `hnsw.iterative_scan = strict_order` (pgvector 0.8 and later) so the index keeps scanning
until enough rows from the requested collection are found; on older pgvector it falls back to `hnsw.ef_search = 1000`,
which can still under-return for a collection that is large and far from the query.

If the query embedding fails or exceeds `KB_QUERY_EMBED_TIMEOUT` at search time the service logs a warning and answers with lexical results.
If chunk embedding fails at ingest time the write is rejected (`502`) and nothing is stored.

Turning embeddings on for an existing database does not backfill vectors: chunks ingested earlier stay without
vectors (lexical search only) until their documents are re-ingested. The same applies after changing the model.

Changing `KB_EMBEDDINGS_DIM` or the model on an existing database requires a new `KB_DB_SCHEMA` (or a manual
column migration) and re-ingest.

## Known limitations

* **English-only lexical search**: the PostgreSQL `tsvector` uses the `english` text search configuration (stemming,
  English stop words) and memory mode tokenises on letters and digits. Other languages work only as plain tokens.
* **Weak CJK support**: the chunker splits on paragraphs, sentences and spaces, so Chinese, Japanese and Korean
  text without spaces is cut at the size limit rather than at word boundaries, and the lexical tokenisers do not
  segment it. Use embeddings for such content.
* **Ingest memory is not limited**: concurrent large `PUT`s are each held in memory (body, chunks, vectors);
  there is no concurrency limit yet. Bound it with replicas, memory limits and `KB_MAX_BODY_BYTES`.
* **No per-collection authorization unless `KB_ACCESS_FILE` is set**: by default the admin token grants access to every
  collection and `/mcp` is open to whatever can reach it. With `KB_ACCESS_FILE` (ADR 0030), `/mcp` checks one bearer value per
  caller and, in `enforce`, filters every read by the caller's collections inside the store query; a collection outside the
  list answers like a missing one. It tells tool groups apart, not profiles or agents, and it does not stop a tool server that
  can read another group's value. The admin API keeps its own token and writes any collection.
* **HNSW graph connectivity**: filtered iterative scans cannot reach vectors that the index graph does not connect
  to the query's neighbourhood; this is a pgvector property.

## Develop

```sh
make test               # go test ./... -race -count=1 (no external services)
make cover              # per-package coverage
make test-integration   # starts throwaway pgvector + plain Postgres containers, runs the PostgreSQL tests, removes them
make docker             # distroless static, non-root image
```

PostgreSQL tests are skipped unless `KB_TEST_DATABASE_URL` is set (`KB_TEST_DATABASE_URL_NOVECTOR`, a server
without pgvector, enables one extra startup-failure test).

Package layout:

| Package | Role |
| --- | --- |
| `cmd/kb` | wiring, signals |
| `internal/config` | environment configuration and validation |
| `internal/chunk` | paragraph/sentence/word-boundary chunker with overlap (UTF-8 safe, deterministic) |
| `internal/embed` | `Embedder` interface; `None` and OpenAI-compatible client |
| `internal/store` | `Store` interface and types; `memory`, `postgres`, `storetest` (conformance suite) |
| `internal/kb` | service layer: validation, chunk, embed, store |
| `internal/api` | admin REST API |
| `internal/mcpserver` | MCP tools |
| `internal/server` | HTTP assembly, probes, timeouts, access log, graceful shutdown |

## Deploy

The OpenAgentix chart (`charts/openagentix`, block `knowledge`) deploys this service with PostgreSQL, a local embedding server, NetworkPolicies and the vMCP wiring; see the repository README, "Knowledge base". The manifests in `deploy/` are a standalone reference for use without the chart (memory store, no embeddings). Every tool call, like every request, is bounded by `KB_REQUEST_TIMEOUT`.

`deploy/` has a namespace and a Deployment plus Service (`openagentix-knowledge`). Secrets are created with
`kubectl create secret` as described at the top of `deploy/deployment.yaml`; nothing secret is in git.
The default manifest runs `KB_STORE=memory` with one replica; switch to `postgres` for durable, scalable use.
`KB_MCP_STATELESS=false` keeps MCP sessions in process memory and needs a single replica.

The `kb-admin` Secret reference is `optional`: without the Secret the pod starts with the admin API disabled
(`403`), as described above.

**Security**: `/mcp` is unauthenticated and must only be reachable from the tool gateway. `deploy/networkpolicy.yaml`
allows ingress to the pod only from namespace `mcp-tools` and from the pod's own namespace (ingest jobs). It only
takes effect if the cluster's CNI enforces NetworkPolicy. MCP and the admin API share one port, so the admin API
is protected by its bearer token, not by the policy alone. Do not expose the Service through an Ingress or
LoadBalancer.

Build the image: `docker build -t openagentix/kb:dev .` (build argument `VERSION` stamps the version).
