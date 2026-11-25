package conform

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// cfg describes a fake agent. good() with no modifiers is a fully conformant, non-streaming agent.
type cfg struct {
	card       func(m map[string]any)
	cardStatus int
	cardRaw    string
	cardDelay  time.Duration
	send       func(w http.ResponseWriter, id json.RawMessage)
	stream     func(w http.ResponseWriter, id json.RawMessage)
	badJSON    func(w http.ResponseWriter)
	unknown    func(w http.ResponseWriter, id json.RawMessage)
	noParams   func(w http.ResponseWriter, id json.RawMessage)
	getTask    func(w http.ResponseWriter, id json.RawMessage)
}

func rpcOut(w http.ResponseWriter, id json.RawMessage, result any, code int, msg string) {
	out := map[string]any{"jsonrpc": "2.0", "id": id}
	if code != 0 {
		out["error"] = map[string]any{"code": code, "message": msg}
	} else {
		out["result"] = result
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(out)
}

func good(mods ...func(*cfg)) http.Handler {
	c := &cfg{}
	for _, m := range mods {
		m(c)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /.well-known/agent-card.json", func(w http.ResponseWriter, r *http.Request) {
		if c.cardDelay > 0 {
			time.Sleep(c.cardDelay)
		}
		if c.cardStatus != 0 {
			w.WriteHeader(c.cardStatus)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if c.cardRaw != "" {
			fmt.Fprint(w, c.cardRaw)
			return
		}
		m := map[string]any{
			"name": "fake", "description": "d", "version": "1",
			"supportedInterfaces": []map[string]string{{"url": "http://" + r.Host + "/", "protocolBinding": "JSONRPC", "protocolVersion": "1.0"}},
			"capabilities":        map[string]any{"streaming": false},
			"defaultInputModes":   []string{"text/plain"}, "defaultOutputModes": []string{"text/plain"},
			"skills": []map[string]any{{"id": "s", "name": "s", "description": "d", "tags": []string{"t"}}},
		}
		if c.card != nil {
			c.card(m)
		}
		_ = json.NewEncoder(w).Encode(m)
	})
	mux.HandleFunc("POST /{$}", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			if c.badJSON != nil {
				c.badJSON(w)
				return
			}
			rpcOut(w, nil, nil, -32700, "parse error")
			return
		}
		switch req.Method {
		case "SendMessage":
			if strings.Contains(string(req.Params), `"parts":[]`) || !strings.Contains(string(req.Params), "parts") {
				if c.noParams != nil {
					c.noParams(w, req.ID)
					return
				}
				rpcOut(w, req.ID, nil, -32602, "invalid params")
				return
			}
			if c.send != nil {
				c.send(w, req.ID)
				return
			}
			rpcOut(w, req.ID, map[string]any{"message": map[string]any{"messageId": "m1", "role": "ROLE_AGENT", "parts": []map[string]string{{"text": "hi"}}}}, 0, "")
		case "SendStreamingMessage":
			if c.stream != nil {
				c.stream(w, req.ID)
				return
			}
			rpcOut(w, req.ID, nil, -32004, "streaming is not supported")
		case "GetTask":
			if c.getTask != nil {
				c.getTask(w, req.ID)
				return
			}
			rpcOut(w, req.ID, nil, -32001, "task not found")
		default:
			if c.unknown != nil {
				c.unknown(w, req.ID)
				return
			}
			rpcOut(w, req.ID, nil, -32601, "method not found")
		}
	})
	return mux
}

func run(t *testing.T, h http.Handler) map[string]Result {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	res := Run(context.Background(), srv.URL, Options{CardTimeout: 500 * time.Millisecond, CallTimeout: 2 * time.Second, SkipPortCheck: true})
	m := map[string]Result{}
	for _, r := range res {
		m[r.ID] = r
	}
	return m
}

func want(t *testing.T, m map[string]Result, id string, st Status, fixContains string) {
	t.Helper()
	r, ok := m[id]
	if !ok {
		t.Fatalf("no result %q", id)
	}
	if r.Status != st {
		t.Fatalf("%s: got %s (%s), want %s", id, r.Status, r.Detail, st)
	}
	if st == Fail && r.Fix == "" {
		t.Fatalf("%s: no fix text", id)
	}
	if st == Fail && !strings.Contains(r.Fix+r.Detail, fixContains) {
		t.Fatalf("%s: fix/detail %q does not contain %q", id, r.Fix+" | "+r.Detail, fixContains)
	}
}

func resultsOf(m map[string]Result) []Result {
	var r []Result
	for _, v := range m {
		r = append(r, v)
	}
	return r
}

func TestConformantAgentPasses(t *testing.T) {
	m := run(t, good())
	for _, id := range []string{"card", "card-fields", "interface", "send-message", "streaming", "bad-json", "unknown-method", "bad-params"} {
		want(t, m, id, Pass, "")
	}
	if Failed(resultsOf(m)) {
		t.Fatal("Failed() true for a conformant agent")
	}
}

func TestCardMissing(t *testing.T) {
	m := run(t, good(func(c *cfg) { c.cardStatus = 404 }))
	want(t, m, "card", Fail, "/.well-known/agent-card.json")
	if !Failed(resultsOf(m)) {
		t.Fatal("Failed() false")
	}
}

func TestCardNotJSON(t *testing.T) {
	m := run(t, good(func(c *cfg) { c.cardRaw = "<html>" }))
	want(t, m, "card", Fail, "JSON")
}

func TestCardSlow(t *testing.T) {
	m := run(t, good(func(c *cfg) { c.cardDelay = 900 * time.Millisecond }))
	want(t, m, "card", Fail, "2 seconds")
}

func TestCardMissingFields(t *testing.T) {
	m := run(t, good(func(c *cfg) { c.card = func(m map[string]any) { delete(m, "skills"); delete(m, "version") } }))
	want(t, m, "card-fields", Fail, "skills")
	if !strings.Contains(m["card-fields"].Detail, "version") {
		t.Fatalf("detail should name version: %s", m["card-fields"].Detail)
	}
}

func TestCardNoJSONRPC10Interface(t *testing.T) {
	m := run(t, good(func(c *cfg) {
		c.card = func(m map[string]any) {
			m["supportedInterfaces"] = []map[string]string{{"url": "http://x/", "protocolBinding": "HTTP+JSON", "protocolVersion": "1.0"}}
		}
	}))
	want(t, m, "interface", Fail, "JSONRPC")
	m = run(t, good(func(c *cfg) {
		c.card = func(m map[string]any) {
			m["supportedInterfaces"] = []map[string]string{{"url": "http://x/", "protocolBinding": "JSONRPC", "protocolVersion": "0.3"}}
		}
	}))
	want(t, m, "interface", Fail, "1.0")
}

func TestSendMessageResultShapes(t *testing.T) {
	m := run(t, good(func(c *cfg) {
		c.send = func(w http.ResponseWriter, id json.RawMessage) { rpcOut(w, id, map[string]any{"text": "plain"}, 0, "") }
	}))
	want(t, m, "send-message", Fail, "message")
	m = run(t, good(func(c *cfg) {
		c.send = func(w http.ResponseWriter, id json.RawMessage) { rpcOut(w, id, nil, -32000, "boom") }
	}))
	want(t, m, "send-message", Fail, "OPENAI_BASE_URL")
	m = run(t, good(func(c *cfg) {
		c.send = func(w http.ResponseWriter, id json.RawMessage) {
			rpcOut(w, id, map[string]any{"message": map[string]any{}, "task": map[string]any{}}, 0, "")
		}
	}))
	want(t, m, "send-message", Fail, "not both")
}

func TestSendMessageTask(t *testing.T) {
	task := func(state string) func(w http.ResponseWriter, id json.RawMessage) {
		return func(w http.ResponseWriter, id json.RawMessage) {
			rpcOut(w, id, map[string]any{"task": map[string]any{"id": "t1", "status": map[string]any{"state": state}}}, 0, "")
		}
	}
	m := run(t, good(func(c *cfg) {
		c.send = task("TASK_STATE_COMPLETED")
		c.getTask = func(w http.ResponseWriter, id json.RawMessage) {
			rpcOut(w, id, map[string]any{"id": "t1", "status": map[string]any{"state": "TASK_STATE_COMPLETED"}}, 0, "")
		}
	}))
	want(t, m, "send-message", Pass, "")
	want(t, m, "get-task", Pass, "")
	m = run(t, good(func(c *cfg) { c.send = task("TASK_STATE_COMPLETED") }))
	want(t, m, "get-task", Fail, "GetTask")
	m = run(t, good(func(c *cfg) {
		c.send = func(w http.ResponseWriter, id json.RawMessage) {
			rpcOut(w, id, map[string]any{"task": map[string]any{"id": "t1"}}, 0, "")
		}
	}))
	want(t, m, "send-message", Fail, "state")
}

func TestStreamingClaimedButSendsPlainJSON(t *testing.T) {
	m := run(t, good(func(c *cfg) {
		c.card = func(m map[string]any) { m["capabilities"] = map[string]any{"streaming": true} }
	}))
	want(t, m, "streaming", Fail, "text/event-stream")
}

func sse(events ...string) func(w http.ResponseWriter, id json.RawMessage) {
	return func(w http.ResponseWriter, id json.RawMessage) {
		w.Header().Set("Content-Type", "text/event-stream")
		for _, e := range events {
			fmt.Fprintf(w, "data: %s\n\n", e)
		}
	}
}

func TestStreamingGood(t *testing.T) {
	m := run(t, good(func(c *cfg) {
		c.card = func(m map[string]any) { m["capabilities"] = map[string]any{"streaming": true} }
		c.stream = sse(
			`{"jsonrpc":"2.0","id":"1","result":{"task":{"id":"t","status":{"state":"TASK_STATE_WORKING"}}}}`,
			`{"jsonrpc":"2.0","id":"1","result":{"statusUpdate":{"taskId":"t","status":{"state":"TASK_STATE_COMPLETED"}}}}`)
	}))
	want(t, m, "streaming", Pass, "")
}

func TestStreamingNeverTerminal(t *testing.T) {
	m := run(t, good(func(c *cfg) {
		c.card = func(m map[string]any) { m["capabilities"] = map[string]any{"streaming": true} }
		c.stream = sse(`{"jsonrpc":"2.0","id":"1","result":{"task":{"id":"t","status":{"state":"TASK_STATE_WORKING"}}}}`)
	}))
	want(t, m, "streaming", Fail, "terminal")
}

func TestStreamingNotClaimedButSucceeds(t *testing.T) {
	m := run(t, good(func(c *cfg) {
		c.stream = sse(`{"jsonrpc":"2.0","id":"1","result":{"message":{"messageId":"m","role":"ROLE_AGENT","parts":[{"text":"x"}]}}}`)
	}))
	want(t, m, "streaming", Fail, "-32004")
}

func TestErrorShapes(t *testing.T) {
	m := run(t, good(func(c *cfg) {
		c.badJSON = func(w http.ResponseWriter) {
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"ok":false}`)
		}
		c.unknown = func(w http.ResponseWriter, id json.RawMessage) { rpcOut(w, id, map[string]any{"ok": true}, 0, "") }
		c.noParams = func(w http.ResponseWriter, id json.RawMessage) {
			rpcOut(w, id, map[string]any{"message": map[string]any{}}, 0, "")
		}
	}))
	want(t, m, "bad-json", Fail, "-32700")
	want(t, m, "unknown-method", Fail, "-32601")
	want(t, m, "bad-params", Fail, "-32602")
	m = run(t, good(func(c *cfg) {
		c.unknown = func(w http.ResponseWriter, id json.RawMessage) { rpcOut(w, id, nil, -32000, "nope") }
	}))
	want(t, m, "unknown-method", Fail, "-32601")
}

func TestPortCheck(t *testing.T) {
	r := checkPort("http://localhost:80")
	if r.Status != Fail || !strings.Contains(r.Fix, "1024") {
		t.Fatalf("port 80: %+v", r)
	}
	if r := checkPort("http://localhost:8080"); r.Status != Pass {
		t.Fatalf("port 8080: %+v", r)
	}
	if r := checkPort("http://localhost"); r.Status != Warn {
		t.Fatalf("no port: %+v", r)
	}
}

func TestManualChecksListed(t *testing.T) {
	ids := map[string]bool{}
	for _, r := range ManualChecks() {
		ids[r.ID] = true
		if r.Status != Manual || r.Fix == "" {
			t.Fatalf("bad manual check %+v", r)
		}
	}
	for _, id := range []string{"non-root", "read-only-root", "env", "network"} {
		if !ids[id] {
			t.Fatalf("missing manual check %s", id)
		}
	}
}

func TestUnreachable(t *testing.T) {
	res := Run(context.Background(), "http://127.0.0.1:1", Options{CardTimeout: time.Second, CallTimeout: time.Second, SkipPortCheck: true})
	if res[0].ID != "card" || res[0].Status != Fail || !strings.Contains(res[0].Fix, "running") {
		t.Fatalf("%+v", res[0])
	}
}

func TestRenderTable(t *testing.T) {
	var b strings.Builder
	Render(&b, []Result{{ID: "a", Title: "A title", Status: Fail, Detail: "d", Fix: "do x"}, {ID: "b", Title: "B", Status: Pass}})
	out := b.String()
	for _, s := range []string{"FAIL", "PASS", "A title", "do x"} {
		if !strings.Contains(out, s) {
			t.Fatalf("missing %q in\n%s", s, out)
		}
	}
}
