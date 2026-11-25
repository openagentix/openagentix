package stub

import (
	"bufio"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func post(t *testing.T, h http.Handler, body string) (*httptest.ResponseRecorder, map[string]any) {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("content-type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	var out map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	return rec, out
}

const osvTool = `{"type":"function","function":{"name":"osv_query_vulnerability","description":"x","parameters":{"type":"object","properties":{"package_name":{"type":"string"},"ecosystem":{"type":"string"},"version":{"type":"string"}},"required":["package_name","ecosystem"]}}}`

func choice(out map[string]any) map[string]any {
	return out["choices"].([]any)[0].(map[string]any)
}

func TestPlainAnswerSaysItIsAStub(t *testing.T) {
	rec, out := post(t, New(), `{"model":"quickstart-stub","messages":[{"role":"user","content":"hello"}]}`)
	if rec.Code != 200 {
		t.Fatalf("status %d", rec.Code)
	}
	msg := choice(out)["message"].(map[string]any)["content"].(string)
	if !strings.Contains(msg, "stub model") {
		t.Fatalf("answer must say it is a stub: %q", msg)
	}
	if choice(out)["finish_reason"] != "stop" {
		t.Fatalf("finish_reason %v", choice(out)["finish_reason"])
	}
	if out["model"] != "quickstart-stub" {
		t.Fatalf("model not echoed: %v", out["model"])
	}
}

func TestVulnerabilityPromptCallsTheOSVTool(t *testing.T) {
	_, out := post(t, New(), `{"model":"m","messages":[{"role":"user","content":"Look up known vulnerabilities of lodash 4.17.20 (npm)"}],"tools":[`+osvTool+`]}`)
	c := choice(out)
	if c["finish_reason"] != "tool_calls" {
		t.Fatalf("finish_reason %v", c["finish_reason"])
	}
	call := c["message"].(map[string]any)["tool_calls"].([]any)[0].(map[string]any)
	fn := call["function"].(map[string]any)
	if fn["name"] != "osv_query_vulnerability" {
		t.Fatalf("tool %v", fn["name"])
	}
	var args map[string]string
	if err := json.Unmarshal([]byte(fn["arguments"].(string)), &args); err != nil {
		t.Fatalf("arguments must be a JSON string: %v", err)
	}
	if args["package_name"] != "lodash" || args["ecosystem"] != "npm" || args["version"] != "4.17.20" {
		t.Fatalf("args %v", args)
	}
	if call["id"] == "" || call["type"] != "function" {
		t.Fatalf("call %v", call)
	}
}

func TestToolResultIsReportedAndLabelledAsStub(t *testing.T) {
	body := `{"model":"m","messages":[
	 {"role":"user","content":"vulnerabilities of lodash"},
	 {"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"osv_query_vulnerability","arguments":"{}"}}]},
	 {"role":"tool","tool_call_id":"call_1","content":"found 3 advisories"}],"tools":[` + osvTool + `]}`
	_, out := post(t, New(), body)
	msg := choice(out)["message"].(map[string]any)["content"].(string)
	for _, want := range []string{"osv_query_vulnerability", "found 3 advisories", "stub model"} {
		if !strings.Contains(msg, want) {
			t.Fatalf("answer lacks %q: %q", want, msg)
		}
	}
}

func TestToolResultIsTruncated(t *testing.T) {
	big := strings.Repeat("x", 5000)
	body := `{"model":"m","messages":[{"role":"user","content":"q"},{"role":"tool","tool_call_id":"c","name":"t","content":"` + big + `"}]}`
	_, out := post(t, New(), body)
	msg := choice(out)["message"].(map[string]any)["content"].(string)
	if len(msg) > 1500 {
		t.Fatalf("answer too long: %d", len(msg))
	}
}

func TestFetchPromptCallsFetchEvenWhenNotOffered(t *testing.T) {
	// the platform, not the model, decides what is allowed: the stub asks for a tool the profile does not offer
	_, out := post(t, New(), `{"model":"m","messages":[{"role":"user","content":"Fetch https://example.com/ for me"}],"tools":[`+osvTool+`]}`)
	call := choice(out)["message"].(map[string]any)["tool_calls"].([]any)[0].(map[string]any)["function"].(map[string]any)
	if call["name"] != "fetch_fetch" {
		t.Fatalf("tool %v", call["name"])
	}
	if !strings.Contains(call["arguments"].(string), "https://example.com/") {
		t.Fatalf("args %v", call["arguments"])
	}
}

func TestNoToolOfferedNoCall(t *testing.T) {
	_, out := post(t, New(), `{"model":"m","messages":[{"role":"user","content":"vulnerabilities of lodash"}]}`)
	if choice(out)["finish_reason"] != "stop" {
		t.Fatalf("expected a plain answer")
	}
}

func TestDeterministic(t *testing.T) {
	b := `{"model":"m","messages":[{"role":"user","content":"vulnerabilities of lodash 4.17.20"}],"tools":[` + osvTool + `]}`
	_, a := post(t, New(), b)
	_, c := post(t, New(), b)
	x, _ := json.Marshal(choice(a))
	y, _ := json.Marshal(choice(c))
	if string(x) != string(y) {
		t.Fatalf("not deterministic:\n%s\n%s", x, y)
	}
}

func TestStreaming(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"m","stream":true,"messages":[{"role":"user","content":"vulnerabilities of lodash"}],"tools":[`+osvTool+`]}`))
	rec := httptest.NewRecorder()
	New().ServeHTTP(rec, req)
	if ct := rec.Header().Get("content-type"); !strings.HasPrefix(ct, "text/event-stream") {
		t.Fatalf("content-type %q", ct)
	}
	sc := bufio.NewScanner(rec.Body)
	var datas []string
	for sc.Scan() {
		if l := sc.Text(); strings.HasPrefix(l, "data: ") {
			datas = append(datas, strings.TrimPrefix(l, "data: "))
		}
	}
	all := strings.Join(datas, "\n")
	if len(datas) < 2 || datas[len(datas)-1] != "[DONE]" {
		t.Fatalf("stream %v", datas)
	}
	if !strings.Contains(all, `"tool_calls"`) || !strings.Contains(all, `"finish_reason":"tool_calls"`) {
		t.Fatalf("stream lacks the tool call: %v", datas)
	}
}

func TestModelsAndHealth(t *testing.T) {
	h := New()
	for _, p := range []string{"/healthz", "/v1/models"} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, p, nil))
		if rec.Code != 200 {
			t.Fatalf("%s: %d", p, rec.Code)
		}
	}
}

func TestBadRequests(t *testing.T) {
	rec, _ := post(t, New(), `not json`)
	if rec.Code != 400 {
		t.Fatalf("status %d", rec.Code)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(strings.Repeat("a", 3<<20)))
	rec = httptest.NewRecorder()
	New().ServeHTTP(rec, req)
	if rec.Code != 400 {
		t.Fatalf("oversize body: %d", rec.Code)
	}
}

func TestContentArrayIsRead(t *testing.T) {
	_, out := post(t, New(), `{"model":"m","messages":[{"role":"user","content":[{"type":"text","text":"vulnerabilities of express 4.17.1"}]}],"tools":[`+osvTool+`]}`)
	if choice(out)["finish_reason"] != "tool_calls" {
		t.Fatalf("array content not read")
	}
}
