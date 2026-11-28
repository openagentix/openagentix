// Package obs holds the knowledge base's Prometheus metrics. Every method is
// safe on a nil *Metrics (metrics off) and takes only values from closed sets:
// anything else is folded into a fixed "other" value, so a bug or an attacker
// cannot create series from document text, queries, ids or collection names.
package obs

import (
	"net/http"
	"slices"
	"time"

	"github.com/openagentix/openagentix/services/kb/internal/metrics"
)

// Prefix of every metric this service defines.
const Prefix = "openagentix_kb"

var (
	methods      = []string{"GET", "HEAD", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"}
	tools        = []string{"kb_search", "kb_get_document", "kb_list_collections", "kb_graph_search", "kb_graph_entity", "kb_graph_paths", "kb_graph_schema"}
	toolOutcomes = []string{"ok", "invalid", "not_found", "ambiguous", "timeout", "error"}
	searchModes  = []string{"lexical", "vector", "hybrid"}
	searchOut    = []string{"ok", "invalid", "timeout", "canceled", "error"}
	embedOps     = []string{"batch", "query"}
	embedOut     = []string{"ok", "timeout", "canceled", "error"}
	ingestOut    = []string{"ok", "invalid", "too_large", "upstream_error", "timeout", "canceled", "error"}
	jobStates    = []string{"done", "failed", "retry", "discarded"}
	modelOut     = []string{"ok", "error"}
	modelCodes   = []string{"none", "transport", "http_429", "http_5xx", "http_4xx", "malformed_output", "empty_output", "stale_window", "store", "response_too_large"}
)

// pick returns v when it is in allowed, else fallback.
func pick(v string, fallback string, allowed []string) string {
	if slices.Contains(allowed, v) {
		return v
	}
	return fallback
}

// Metrics is the set of series. Create it with New.
type Metrics struct {
	reg *metrics.Registry

	httpReqs *metrics.CounterVec
	httpDur  *metrics.HistogramVec
	toolCall *metrics.CounterVec
	toolDur  *metrics.HistogramVec
	searches *metrics.CounterVec
	searchD  *metrics.HistogramVec
	embeds   *metrics.CounterVec
	embedD   *metrics.HistogramVec
	ingested *metrics.CounterVec

	jobs       *metrics.CounterVec
	modelCalls *metrics.CounterVec
	tokens     metrics.Counter
	paused     metrics.Counter

	entities, relations, pending, factsets *metrics.GaugeVec
}

// New registers every series and the process basics. version is the build
// version label of <prefix>_build_info.
func New(version string) *Metrics {
	r := metrics.NewRegistry()
	m := &Metrics{reg: r}
	m.httpReqs = r.Counter(Prefix+"_http_requests_total", "HTTP requests by route template, method and status class.", "route", "method", "status_class")
	m.httpDur = r.Histogram(Prefix+"_http_request_duration_seconds", "HTTP request duration by route template and method.", metrics.DefBuckets, "route", "method")
	m.toolCall = r.Counter(Prefix+"_mcp_tool_calls_total", "MCP tool calls by tool and outcome.", "tool", "outcome")
	m.toolDur = r.Histogram(Prefix+"_mcp_tool_call_duration_seconds", "MCP tool call duration by tool.", metrics.DefBuckets, "tool")
	m.searches = r.Counter(Prefix+"_search_requests_total", "Searches by mode (lexical, or hybrid when the query was embedded) and outcome.", "mode", "outcome")
	m.searchD = r.Histogram(Prefix+"_search_duration_seconds", "Search duration, including query embedding, by mode.", metrics.DefBuckets, "mode")
	m.embeds = r.Counter(Prefix+"_embedder_calls_total", "Embedder calls by operation (batch or query) and outcome.", "op", "outcome")
	m.embedD = r.Histogram(Prefix+"_embedder_call_duration_seconds", "Embedder call duration by operation.", metrics.DefBuckets, "op")
	m.ingested = r.Counter(Prefix+"_documents_ingested_total", "Document ingest requests by outcome.", "outcome")
	m.jobs = r.Counter(Prefix+"_graph_jobs_total", "Graph extraction job attempts by result: done, failed (final), retry, discarded (job or window gone).", "state")
	m.modelCalls = r.Counter(Prefix+"_graph_model_calls_total", "Graph extraction model calls by outcome and error code.", "outcome", "code")
	m.tokens = r.Counter(Prefix+"_graph_extraction_tokens_total", "Tokens used by graph extraction model calls.").With()
	m.paused = r.Counter(Prefix+"_graph_budget_paused_seconds_total", "Seconds the extraction worker waited for its hourly token budget.").With()
	m.entities = r.Gauge(Prefix+"_graph_entities", "Graph entities.", "collection")
	m.relations = r.Gauge(Prefix+"_graph_relations", "Graph relations.", "collection")
	m.pending = r.Gauge(Prefix+"_graph_jobs_pending", "Extraction jobs waiting for the worker.", "collection")
	m.factsets = r.Gauge(Prefix+"_graph_factsets", "Curated fact sets.", "collection")
	metrics.RegisterRuntime(r, Prefix, version)
	return m
}

// Handler serves GET /metrics (and nothing else).
func (m *Metrics) Handler() http.Handler { return m.reg.Handler() }

// OnScrape registers f to run before every exposition.
func (m *Metrics) OnScrape(f func()) {
	if m != nil {
		m.reg.OnScrape(f)
	}
}

func statusClass(code int) string {
	switch {
	case code >= 100 && code < 200:
		return "1xx"
	case code >= 200 && code < 300:
		return "2xx"
	case code >= 300 && code < 400:
		return "3xx"
	case code >= 400 && code < 500:
		return "4xx"
	case code >= 500 && code < 600:
		return "5xx"
	}
	return "other"
}

// HTTP records one request. route is the mux pattern without its method
// ("/v1/collections/{collection}/documents/{id}"); empty means unmatched.
func (m *Metrics) HTTP(route, method string, status int, d time.Duration) {
	if m == nil {
		return
	}
	if route == "" {
		route = "unmatched"
	}
	method = pick(method, "OTHER", methods)
	m.httpReqs.With(route, method, statusClass(status)).Inc()
	m.httpDur.With(route, method).Observe(d.Seconds())
}

// ToolCall records one MCP tool call.
func (m *Metrics) ToolCall(tool, outcome string, d time.Duration) {
	if m == nil {
		return
	}
	tool = pick(tool, "other", tools)
	m.toolCall.With(tool, pick(outcome, "error", toolOutcomes)).Inc()
	m.toolDur.With(tool).Observe(d.Seconds())
}

// Search records one search.
func (m *Metrics) Search(mode, outcome string, d time.Duration) {
	if m == nil {
		return
	}
	mode = pick(mode, "other", searchModes)
	m.searches.With(mode, pick(outcome, "error", searchOut)).Inc()
	m.searchD.With(mode).Observe(d.Seconds())
}

// EmbedCall records one embedder call; op is "batch" or "query".
func (m *Metrics) EmbedCall(op, outcome string, d time.Duration) {
	if m == nil {
		return
	}
	op = pick(op, "batch", embedOps)
	m.embeds.With(op, pick(outcome, "error", embedOut)).Inc()
	m.embedD.With(op).Observe(d.Seconds())
}

// Ingest records one document ingest.
func (m *Metrics) Ingest(outcome string) {
	if m != nil {
		m.ingested.With(pick(outcome, "error", ingestOut)).Inc()
	}
}

// GraphJob records the result of one extraction job attempt.
func (m *Metrics) GraphJob(state string) {
	if m != nil {
		m.jobs.With(pick(state, "other", append(jobStates, "other"))).Inc()
	}
}

// GraphModelCall records one extraction model call. code is the error code of
// a failed call (see graph.Code*) and is ignored when outcome is "ok".
func (m *Metrics) GraphModelCall(outcome, code string) {
	if m == nil {
		return
	}
	outcome = pick(outcome, "error", modelOut)
	if outcome == "ok" || code == "" {
		code = "none"
	}
	m.modelCalls.With(outcome, pick(code, "other", append(modelCodes, "other"))).Inc()
}

// GraphTokens adds tokens used by extraction model calls.
func (m *Metrics) GraphTokens(n int) {
	if m != nil && n > 0 {
		m.tokens.Add(float64(n))
	}
}

// GraphPaused adds time the worker spent waiting for its token budget.
func (m *Metrics) GraphPaused(d time.Duration) {
	if m != nil && d > 0 {
		m.paused.Add(d.Seconds())
	}
}

// ResetGraphSize forgets the sampled graph size series.
func (m *Metrics) ResetGraphSize() {
	if m == nil {
		return
	}
	m.entities.Reset()
	m.relations.Reset()
	m.pending.Reset()
	m.factsets.Reset()
}

// SetGraphSize sets the sampled graph size for one label value ("all", or a
// collection name when per-collection labels are switched on).
func (m *Metrics) SetGraphSize(collection string, entities, relations, pending, factsets int) {
	if m == nil {
		return
	}
	m.entities.With(collection).Set(float64(entities))
	m.relations.With(collection).Set(float64(relations))
	m.pending.With(collection).Set(float64(pending))
	m.factsets.With(collection).Set(float64(factsets))
}
