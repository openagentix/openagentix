package observe_test

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/openagentix/openagentix/services/console/internal/observe"
)

const tid = "0123456789abcdef0123456789abcdef"

func tag(k string, v any) map[string]any { return map[string]any{"key": k, "value": v} }

func traceJSON() map[string]any {
	return map[string]any{"data": []any{map[string]any{
		"traceID":   tid,
		"processes": map[string]any{"p1": map[string]any{"serviceName": "assistant"}, "p2": map[string]any{"serviceName": "model-gateway"}},
		"spans": []any{
			map[string]any{"spanID": "a1", "processID": "p1", "operationName": "a2a.request", "startTime": 1_000_000, "duration": 3_000_000,
				"tags": []any{tag("gen_ai.conversation.id", "ctx-1"), tag("gen_ai.agent.name", "assistant"), tag("a2a.task.state", "completed"),
					tag("gen_ai.prompt", "SECRET PROMPT"), tag("mcp.tool.arguments", "SECRET ARGS")}},
			map[string]any{"spanID": "b2", "processID": "p2", "operationName": "POST /v1/chat/completions", "startTime": 1_500_000, "duration": 1_600_000,
				"references": []any{map[string]any{"refType": "CHILD_OF", "spanID": "a1"}},
				"tags":       []any{tag("gen_ai.usage.input_tokens", 30782), tag("gen_ai.usage.output_tokens", 263), tag("gen_ai.request.model", "claude-haiku-5-5"), tag("http.request.header.authorization", "Bearer SECRET")}},
		},
	}}}
}

func otv(k string, v any) map[string]any {
	val := map[string]any{}
	switch x := v.(type) {
	case string:
		val["stringValue"] = x
	case int:
		val["intValue"] = strconv.Itoa(x) // OTLP JSON carries 64-bit integers as strings
	}
	return map[string]any{"key": k, "value": val}
}

// otlpTraces is traceJSON() in the shape Jaeger v2 returns from /api/v3/traces: one resource per service, ids in hex, times in nanoseconds.
func otlpTraces() map[string]any {
	res := func(svc string, spans ...any) map[string]any {
		return map[string]any{"resource": map[string]any{"attributes": []any{otv("service.name", svc)}}, "scopeSpans": []any{map[string]any{"spans": spans}}}
	}
	return map[string]any{"result": map[string]any{"resourceSpans": []any{
		res("assistant", map[string]any{"traceId": tid, "spanId": "a1", "name": "a2a.request", "startTimeUnixNano": "1000000000", "endTimeUnixNano": "4000000000",
			"attributes": []any{otv("gen_ai.conversation.id", "ctx-1"), otv("gen_ai.agent.name", "assistant"), otv("a2a.task.state", "completed"), otv("gen_ai.prompt", "SECRET PROMPT")}}),
		res("model-gateway", map[string]any{"traceId": tid, "spanId": "b2", "parentSpanId": "a1", "name": "POST /v1/chat/completions", "startTimeUnixNano": "1500000000", "endTimeUnixNano": "3100000000",
			"attributes": []any{otv("gen_ai.usage.input_tokens", 30782), otv("gen_ai.usage.output_tokens", 263)}}),
	}}}
}

type fakeJaeger struct {
	mu    sync.Mutex
	paths []string
}

func (f *fakeJaeger) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	f.paths = append(f.paths, r.URL.RequestURI())
	f.mu.Unlock()
	switch {
	case r.URL.Path == "/api/v3/services":
		_ = json.NewEncoder(w).Encode(map[string]any{"services": []string{"assistant", "model-gateway"}})
	// Jaeger v2 searches with /api/v3/traces (OTLP JSON) and answers 404 "No traces found" when nothing matches. It has no /api/traces search.
	case r.URL.Path == "/api/v3/traces" && r.URL.Query().Get("query.service_name") == "assistant":
		_ = json.NewEncoder(w).Encode(otlpTraces())
	case r.URL.Path == "/api/v3/traces":
		w.WriteHeader(404)
		_, _ = w.Write([]byte(`{"error":{"httpCode":404,"message":"No traces found"}}`))
	case r.URL.Path == "/api/traces/"+tid:
		_ = json.NewEncoder(w).Encode(traceJSON())
	default:
		w.WriteHeader(404)
	}
}

func TestRecentTurnsSummarizesWithoutContent(t *testing.T) {
	f := &fakeJaeger{}
	srv := httptest.NewServer(f)
	defer srv.Close()
	j := observe.NewJaeger(srv.URL, nil)
	j.Now = func() time.Time { return time.Unix(10, 0) }
	turns, err := j.Turns(context.Background())
	if err != nil || len(turns) != 1 {
		t.Fatalf("turns=%v err=%v", turns, err)
	}
	g := turns[0]
	if g.TraceID != tid || g.Agent != "assistant" || g.Outcome != "completed" || g.ModelCalls != 1 || g.DurationMs != 3000 || g.TokensIn != 30782 || g.ConversationID != "ctx-1" {
		t.Fatalf("turn: %+v", g)
	}
	for _, p := range f.paths {
		if strings.Contains(p, "SECRET") {
			t.Errorf("query carried browser text: %s", p)
		}
	}
}

func TestTraceDetailKeepsOnlyAllowedAttributes(t *testing.T) {
	srv := httptest.NewServer(&fakeJaeger{})
	defer srv.Close()
	d, err := observe.NewJaeger(srv.URL, nil).Trace(context.Background(), tid)
	if err != nil || len(d.Spans) != 2 {
		t.Fatalf("detail=%+v err=%v", d, err)
	}
	raw, _ := json.Marshal(d)
	for _, leak := range []string{"SECRET", "gen_ai.prompt", "mcp.tool.arguments", "authorization"} {
		if strings.Contains(string(raw), leak) {
			t.Fatalf("content or unlisted attribute leaked (%s): %s", leak, raw)
		}
	}
	var chat observe.Span
	for _, s := range d.Spans {
		if s.Name == "POST /v1/chat/completions" {
			chat = s
		}
	}
	if chat.Service != "model-gateway" || chat.OffsetMs != 500 || chat.DurationMs != 1600 || chat.ParentID != "a1" || chat.Attrs["gen_ai.request.model"] != "claude-haiku-5-5" {
		t.Fatalf("chat span: %+v", chat)
	}
}

func TestTraceIDMustBeHexAndNothingElseIsQueried(t *testing.T) {
	f := &fakeJaeger{}
	srv := httptest.NewServer(f)
	defer srv.Close()
	j := observe.NewJaeger(srv.URL, nil)
	for _, bad := range []string{"", "../../api/v3/services", tid + "0", strings.ToUpper(tid), "zz" + tid[2:], tid[:31]} {
		if _, err := j.Trace(context.Background(), bad); !errors.Is(err, observe.ErrBadTraceID) {
			t.Errorf("%q: %v", bad, err)
		}
	}
	if len(f.paths) != 0 {
		t.Errorf("a bad id reached the store: %v", f.paths)
	}
}

func TestJaegerErrorsAreUnavailable(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(500); _, _ = w.Write([]byte("SECRET")) }))
	defer srv.Close()
	j := observe.NewJaeger(srv.URL, nil)
	if _, err := j.Turns(context.Background()); !errors.Is(err, observe.ErrUnavailable) || strings.Contains(err.Error(), "SECRET") {
		t.Fatalf("turns: %v", err)
	}
	if _, err := j.Trace(context.Background(), tid); !errors.Is(err, observe.ErrUnavailable) {
		t.Fatalf("trace: %v", err)
	}
}
