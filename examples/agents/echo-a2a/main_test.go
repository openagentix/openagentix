package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const testKey = "sk-test-secret-123"

type fakeModel struct {
	srv     *httptest.Server
	gotAuth string
	gotPath string
	gotBody map[string]any
	status  int
	reply   string
	model   string
}

func newFakeModel(t *testing.T) *fakeModel {
	f := &fakeModel{status: 200, reply: "hello back", model: "served-model"}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.gotAuth = r.Header.Get("Authorization")
		f.gotPath = r.URL.Path
		_ = json.NewDecoder(r.Body).Decode(&f.gotBody)
		w.WriteHeader(f.status)
		if f.status != 200 {
			_, _ = w.Write([]byte("upstream secret detail " + testKey))
			return
		}
		out := map[string]any{"model": f.model, "choices": []any{map[string]any{"message": map[string]any{"role": "assistant", "content": f.reply}}}}
		_ = json.NewEncoder(w).Encode(out)
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func envOf(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

func rpc(t *testing.T, h http.Handler, body string) (int, map[string]any, string) {
	t.Helper()
	req := httptest.NewRequest("POST", "/", strings.NewReader(body))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	var m map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &m)
	return rec.Code, m, rec.Body.String()
}

func sendBody(text string) string {
	b, _ := json.Marshal(text)
	return `{"jsonrpc":"2.0","id":1,"method":"SendMessage","params":{"message":{"messageId":"m1","role":"ROLE_USER","parts":[{"text":` + string(b) + `}]}}}`
}

func errCode(m map[string]any) float64 {
	e, _ := m["error"].(map[string]any)
	c, _ := e["code"].(float64)
	return c
}

func TestAgentCard(t *testing.T) {
	h := newServer(envOf(nil), nil, &bytes.Buffer{}).Handler()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "http://agent.example:8080/.well-known/agent-card.json", nil))
	if rec.Code != 200 || !strings.HasPrefix(rec.Header().Get("Content-Type"), "application/json") {
		t.Fatalf("code=%d ct=%q", rec.Code, rec.Header().Get("Content-Type"))
	}
	if rec.Body.Len() > 64<<10 {
		t.Fatal("card too large")
	}
	var c map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &c); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"name", "description", "version", "supportedInterfaces", "capabilities", "defaultInputModes", "defaultOutputModes", "skills"} {
		if c[k] == nil {
			t.Errorf("missing %s", k)
		}
	}
	i0 := c["supportedInterfaces"].([]any)[0].(map[string]any)
	if i0["protocolBinding"] != "JSONRPC" || i0["protocolVersion"] != "1.0" || i0["url"] == "" {
		t.Errorf("interface %v", i0)
	}
	if c["capabilities"].(map[string]any)["streaming"] != false {
		t.Error("streaming must be false")
	}
	sk := c["skills"].([]any)[0].(map[string]any)
	for _, k := range []string{"id", "name", "description", "tags"} {
		if sk[k] == nil {
			t.Errorf("skill missing %s", k)
		}
	}
}

func TestSendMessageHappyPath(t *testing.T) {
	f := newFakeModel(t)
	var logs bytes.Buffer
	env := map[string]string{"OPENAI_BASE_URL": f.srv.URL + "/v1/", "OPENAI_API_KEY": testKey, "OPENAGENTIX_MODEL": "asked-model"}
	h := newServer(envOf(env), nil, &logs).Handler()
	code, m, raw := rpc(t, h, sendBody("hi there"))
	if code != 200 || m["error"] != nil {
		t.Fatalf("code=%d body=%s", code, raw)
	}
	if f.gotPath != "/v1/chat/completions" {
		t.Errorf("path %q", f.gotPath)
	}
	if f.gotAuth != "Bearer "+testKey {
		t.Errorf("auth header wrong")
	}
	if f.gotBody["model"] != "asked-model" {
		t.Errorf("model %v", f.gotBody["model"])
	}
	msgs := f.gotBody["messages"].([]any)
	m0 := msgs[0].(map[string]any)
	if len(msgs) != 1 || m0["role"] != "user" || m0["content"] != "hi there" {
		t.Errorf("messages %v", msgs)
	}
	res := m["result"].(map[string]any)
	if res["messageId"] == "" || res["role"] != "ROLE_AGENT" {
		t.Errorf("result %v", res)
	}
	txt := res["parts"].([]any)[0].(map[string]any)["text"]
	if txt != "model served-model answered: hello back" {
		t.Errorf("text %q", txt)
	}
	if strings.Contains(raw, testKey) || strings.Contains(logs.String(), testKey) || strings.Contains(logs.String(), "hi there") {
		t.Error("leak in response or logs")
	}
}

func TestKindTextPartAndModelFallback(t *testing.T) {
	f := newFakeModel(t)
	f.model = ""
	env := map[string]string{"OPENAI_BASE_URL": f.srv.URL, "OPENAI_API_KEY": testKey, "OPENAGENTIX_MODEL": "asked-model"}
	h := newServer(envOf(env), nil, &bytes.Buffer{}).Handler()
	body := `{"jsonrpc":"2.0","id":"a","method":"SendMessage","params":{"message":{"parts":[{"kind":"text","text":"yo"}]}}}`
	_, m, raw := rpc(t, h, body)
	if m["error"] != nil {
		t.Fatal(raw)
	}
	txt := m["result"].(map[string]any)["parts"].([]any)[0].(map[string]any)["text"]
	if txt != "model asked-model answered: hello back" {
		t.Errorf("text %q", txt)
	}
	if f.gotPath != "/chat/completions" {
		t.Errorf("path %q", f.gotPath)
	}
}

func TestErrors(t *testing.T) {
	f := newFakeModel(t)
	env := map[string]string{"OPENAI_BASE_URL": f.srv.URL, "OPENAI_API_KEY": testKey, "OPENAGENTIX_MODEL": "m"}
	h := newServer(envOf(env), nil, &bytes.Buffer{}).Handler()

	if _, m, _ := rpc(t, h, `{"jsonrpc":"2.0","id":1,"method":"Nope"}`); errCode(m) != -32601 {
		t.Errorf("unknown method: %v", m)
	}
	if _, m, _ := rpc(t, h, `{not json`); errCode(m) != -32700 {
		t.Errorf("bad json: %v", m)
	}
	if _, m, _ := rpc(t, h, `{"jsonrpc":"2.0","id":1,"method":"SendMessage","params":{"message":{"parts":[]}}}`); errCode(m) != -32602 {
		t.Errorf("bad params: %v", m)
	}
	if _, m, _ := rpc(t, h, `{"jsonrpc":"2.0","id":1,"method":"SendStreamingMessage","params":{}}`); errCode(m) != -32004 {
		t.Errorf("streaming: %v", m)
	}
	f.status = 500
	_, m, raw := rpc(t, h, sendBody("x"))
	if errCode(m) != -32000 || strings.Contains(raw, "upstream secret") || strings.Contains(raw, testKey) {
		t.Errorf("model 500: %s", raw)
	}
}

func TestMissingEnv(t *testing.T) {
	for _, miss := range []string{"OPENAI_BASE_URL", "OPENAI_API_KEY", "OPENAGENTIX_MODEL"} {
		env := map[string]string{"OPENAI_BASE_URL": "http://x", "OPENAI_API_KEY": testKey, "OPENAGENTIX_MODEL": "m"}
		delete(env, miss)
		h := newServer(envOf(env), nil, &bytes.Buffer{}).Handler()
		_, m, raw := rpc(t, h, sendBody("x"))
		if errCode(m) != -32000 || !strings.Contains(raw, miss) || strings.Contains(raw, testKey) {
			t.Errorf("missing %s: %s", miss, raw)
		}
	}
}

func TestBodyLimit(t *testing.T) {
	f := newFakeModel(t)
	env := map[string]string{"OPENAI_BASE_URL": f.srv.URL, "OPENAI_API_KEY": testKey, "OPENAGENTIX_MODEL": "m"}
	h := newServer(envOf(env), nil, &bytes.Buffer{}).Handler()
	req := httptest.NewRequest("POST", "/", strings.NewReader(sendBody(strings.Repeat("a", 1<<20+10))))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("code %d", rec.Code)
	}
	if f.gotBody != nil {
		t.Error("model was called for oversized body")
	}
}
