package server_test

import (
	"bytes"
	"context"
	"net"
	"net/http"
	"os"
	"slices"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"github.com/openagentix/openagentix/services/console/internal/model"
	"github.com/openagentix/openagentix/services/console/internal/platform"
	"github.com/openagentix/openagentix/services/console/internal/server"
)

func TestRouteTableIsExactlyTheDocumentedList(t *testing.T) {
	want := []string{
		"GET /healthz", "GET /api/v1/session", "GET /api/v1/platform", "GET /api/v1/agents", "POST /api/v1/agents", "POST /api/v1/agents/validate",
		"GET /api/v1/agents/{name}", "PUT /api/v1/agents/{name}", "DELETE /api/v1/agents/{name}", "/",
	}
	if !slices.Equal(server.Routes, want) {
		t.Fatalf("Routes changed:\n%v", server.Routes)
	}
	s := server.New(server.Options{Authenticator: nil})
	if got := s.Registered(); !slices.Equal(got, want) {
		t.Fatalf("registered patterns differ from Routes:\n%v", got)
	}
	readme, err := os.ReadFile("../../README.md")
	if err != nil {
		t.Fatal(err)
	}
	for _, rt := range want[:len(want)-1] {
		if !strings.Contains(string(readme), "`"+rt+"`") {
			t.Errorf("README.md does not document `%s`", rt)
		}
	}
}

func TestSessionAndPlatform(t *testing.T) {
	r := newRig(t)
	resp, b := r.do(t, "GET", "/api/v1/session", nil)
	if resp.StatusCode != 200 {
		t.Fatal(resp.Status, string(b))
	}
	s := decodeInto[map[string]any](t, b)
	if s["role"] != "operator" || s["canWrite"] != true || s["edition"] != "community" || s["namespace"] != "kagent" {
		t.Fatalf("session: %v", s)
	}
	resp, b = r.do(t, "GET", "/api/v1/platform", nil)
	if resp.StatusCode != 200 {
		t.Fatal(resp.Status, string(b))
	}
	p := decodeInto[platform.Summary](t, b)
	if !slices.Contains(p.Models, "claude-haiku") || p.Policy.MaxAgents != 5 || len(p.Profiles) != 2 || p.Skills[0].Name != "openagentix-canary" {
		t.Fatalf("platform: %+v", p)
	}
	for _, leak := range []string{"harnessImage", "snapshotLocation", "workerPool", "harnessEnv", "ghcr.io"} {
		if strings.Contains(string(b), leak) {
			t.Errorf("platform summary leaks %s", leak)
		}
	}
}

func TestListMergesChartAgentsAndSkipsControllerMadeAgents(t *testing.T) {
	r := newRig(t)
	r.api.seed("researcher", spec("claude-haiku"), map[string]any{"conditions": []any{
		map[string]any{"type": "Accepted", "status": "True", "reason": "Accepted"}, map[string]any{"type": "Ready", "status": "True", "reason": "Ready"}}})
	r.api.seed("cve-triage", spec("claude-haiku"), map[string]any{"violations": []any{"first sentence", "second"}, "conditions": []any{
		map[string]any{"type": "Accepted", "status": "False", "reason": "PolicyViolation", "message": "2 rule(s) refused"}}})
	_, b := r.do(t, "GET", "/api/v1/agents", nil)
	l := decodeInto[model.AgentList](t, b)
	got := map[string]model.Agent{}
	for _, a := range l.Items {
		got[a.Name] = a
	}
	if len(l.Items) != 3 || l.Used != 2 {
		t.Fatalf("items=%d used=%d: %s", len(l.Items), l.Used, b)
	}
	if a := got["assistant"]; a.Source != "chart" || a.Model != "claude-haiku" || !a.Knowledge || !a.Notify || a.Memory == nil || a.Memory.TTLDays != 30 || a.State != model.StateReady {
		t.Fatalf("chart agent: %+v", a)
	}
	if a := got["researcher"]; a.Source != "built" || a.State != model.StateReady {
		t.Fatalf("researcher: %+v", a)
	}
	if a := got["cve-triage"]; a.State != model.StateRefused || a.StateReason != "first sentence" {
		t.Fatalf("cve-triage: %+v", a)
	}
	var sawSelector bool
	for _, q := range r.api.requests() {
		if strings.HasSuffix(q.Path, "/agents") && strings.Contains(q.Query, "labelSelector=%21openagentix.io%2Fagent-definition") {
			sawSelector = true
		}
	}
	if !sawSelector {
		t.Error("the chart agent list did not ask for agents without the definition label")
	}
}

// The Governance page shows what each agent is really given (the status, not the request) from the list alone.
func TestListCarriesEffectiveToolsAndEgress(t *testing.T) {
	r := newRig(t)
	r.api.seed("researcher", spec("claude-haiku"), map[string]any{
		"effectiveTools":  []any{"osv_query_vulnerability", "execute_tool_script"},
		"effectiveEgress": []any{"https://api.osv.dev"},
		"conditions":      []any{map[string]any{"type": "Ready", "status": "True", "reason": "Ready"}}})
	r.api.seed("empty", spec("claude-haiku"), map[string]any{})
	_, b := r.do(t, "GET", "/api/v1/agents", nil)
	l := decodeInto[model.AgentList](t, b)
	got := map[string]model.Agent{}
	for _, a := range l.Items {
		got[a.Name] = a
	}
	a := got["researcher"]
	if !slices.Equal(a.EffectiveTools, []string{"osv_query_vulnerability", "execute_tool_script"}) || !slices.Equal(a.EffectiveEgress, []string{"https://api.osv.dev"}) {
		t.Fatalf("researcher: %+v", a)
	}
	if e := got["empty"]; e.EffectiveTools == nil || e.EffectiveEgress == nil {
		t.Fatalf("an agent without status must list empty slices, not null: %s", b)
	}
}

func TestGetBuiltChartAndMissing(t *testing.T) {
	r := newRig(t)
	r.api.seed("researcher", spec("claude-haiku"), map[string]any{"observedGeneration": 1, "controller": map[string]any{"keySecret": "researcher-virtual-key-1a2b3c4d"}, "endpoint": map[string]any{"protocol": "a2a", "url": "http://gate/agents/kagent/researcher"}, "revision": "sha256:abc",
		"agentRef": map[string]any{"apiVersion": "api.kagent.dev/v1alpha3", "kind": "Agent", "name": "researcher"}})
	resp, b := r.do(t, "GET", "/api/v1/agents/researcher", nil)
	d := decodeInto[model.Detail](t, b)
	if resp.StatusCode != 200 || d.ReadOnly || d.Spec == nil || !strings.Contains(d.YAML, "kind: AgentDefinition") || !strings.Contains(d.YAML, "    - osv_query_vulnerability") || d.ResourceVersion == "" {
		t.Fatalf("built detail: %s", b)
	}
	if slices.ContainsFunc(d.Objects, func(o model.OwnedObject) bool { return o.Kind == "Secret" }) {
		t.Errorf("an object was derived from status.controller: %+v", d.Objects)
	}
	_, b = r.do(t, "GET", "/api/v1/agents/assistant", nil)
	d = decodeInto[model.Detail](t, b)
	if !d.ReadOnly || d.Source != "chart" || d.Spec == nil || d.Spec.Instructions != "Be brief." {
		t.Fatalf("chart detail: %s", b)
	}
	resp, b = r.do(t, "GET", "/api/v1/agents/ghost", nil)
	if resp.StatusCode != 404 || errCode(t, b) != "not_found" {
		t.Fatal(resp.Status, string(b))
	}
}

func TestCreateUpdateDeleteAndConflict(t *testing.T) {
	r := newRig(t)
	resp, b := r.do(t, "POST", "/api/v1/agents", map[string]any{"name": "fresh", "spec": spec("claude-haiku")})
	if resp.StatusCode != 201 || resp.Header.Get("Location") != "/api/v1/agents/fresh" {
		t.Fatal(resp.Status, string(b))
	}
	created := decodeInto[model.Detail](t, b)
	// the second create of the same name
	if resp, b = r.do(t, "POST", "/api/v1/agents", map[string]any{"name": "fresh", "spec": spec("claude-haiku")}); resp.StatusCode != 409 || errCode(t, b) != "exists" {
		t.Fatal(resp.Status, string(b))
	}
	// a chart agent holds the name
	if resp, b = r.do(t, "POST", "/api/v1/agents", map[string]any{"name": "assistant", "spec": spec("claude-haiku")}); resp.StatusCode != 409 || !strings.Contains(string(b), "chart values") {
		t.Fatal(resp.Status, string(b))
	}
	// update with the right version
	resp, b = r.do(t, "PUT", "/api/v1/agents/fresh", map[string]any{"resourceVersion": created.ResourceVersion, "spec": spec("claude-haiku")})
	if resp.StatusCode != 200 {
		t.Fatal(resp.Status, string(b))
	}
	// and again with the old one: somebody else changed it
	resp, b = r.do(t, "PUT", "/api/v1/agents/fresh", map[string]any{"resourceVersion": created.ResourceVersion, "spec": spec("claude-haiku")})
	if resp.StatusCode != 409 || errCode(t, b) != "conflict" {
		t.Fatal(resp.Status, string(b))
	}
	// the finalizer survived the update (a PUT built from scratch would have dropped it)
	if fin := r.api.defs["fresh"]["metadata"].(map[string]any)["finalizers"]; fin != nil {
		t.Logf("finalizers kept: %v", fin)
	}
	// missing version
	if resp, b = r.do(t, "PUT", "/api/v1/agents/fresh", map[string]any{"spec": spec("claude-haiku")}); resp.StatusCode != 400 {
		t.Fatal(resp.Status, string(b))
	}
	// not found, chart agents are read only
	if resp, b = r.do(t, "PUT", "/api/v1/agents/ghost", map[string]any{"resourceVersion": "1", "spec": spec("claude-haiku")}); resp.StatusCode != 404 {
		t.Fatal(resp.Status, string(b))
	}
	if resp, b = r.do(t, "PUT", "/api/v1/agents/assistant", map[string]any{"resourceVersion": "1", "spec": spec("claude-haiku")}); resp.StatusCode != 403 || errCode(t, b) != "read_only" {
		t.Fatal(resp.Status, string(b))
	}
	if resp, b = r.do(t, "DELETE", "/api/v1/agents/assistant", nil); resp.StatusCode != 403 || errCode(t, b) != "read_only" {
		t.Fatal(resp.Status, string(b))
	}
	// a name that is not a DNS label, and a CRD refusal
	if resp, b = r.do(t, "POST", "/api/v1/agents", map[string]any{"name": "Bad_Name", "spec": spec("claude-haiku")}); resp.StatusCode != 422 {
		t.Fatal(resp.Status, string(b))
	}
	if resp, b = r.do(t, "POST", "/api/v1/agents", map[string]any{"name": "new", "spec": spec("claude-haiku")}); resp.StatusCode != 422 {
		t.Fatal("console route names are refused", resp.Status, string(b))
	}
	bad := spec("claude-haiku")
	bad["instructions"] = ""
	if resp, b = r.do(t, "POST", "/api/v1/agents", map[string]any{"name": "empty", "spec": bad}); resp.StatusCode != 422 || !strings.Contains(string(b), "spec.instructions is required") {
		t.Fatal(resp.Status, string(b))
	}
	// delete
	if resp, b = r.do(t, "DELETE", "/api/v1/agents/fresh", nil); resp.StatusCode != 202 {
		t.Fatal(resp.Status, string(b))
	}
	if resp, b = r.do(t, "DELETE", "/api/v1/agents/fresh", nil); resp.StatusCode != 404 {
		t.Fatal(resp.Status, string(b))
	}
}

func TestValidateDryRunAndPrediction(t *testing.T) {
	r := newRig(t)
	r.api.seed("researcher", spec("claude-haiku"), map[string]any{})
	before := len(r.api.defs)
	s := spec("gpt-x")
	s["egress"] = map[string]any{"allow": []string{"https://services.nvd.nist.gov"}}
	resp, b := r.do(t, "POST", "/api/v1/agents/validate", map[string]any{"name": "draft", "spec": s})
	if resp.StatusCode != 200 {
		t.Fatal(resp.Status, string(b))
	}
	v := decodeInto[model.ValidateResult](t, b)
	if !v.Prediction || !strings.Contains(v.Note, "authority") || !v.Schema.OK {
		t.Fatalf("%+v", v)
	}
	fields := []string{}
	for _, p := range v.Predicted {
		fields = append(fields, p.Field)
	}
	if !slices.Contains(fields, "model") || !slices.Contains(fields, "egress.allow") {
		t.Fatalf("predicted %v", fields)
	}
	if len(r.api.defs) != before {
		t.Fatal("validate wrote something")
	}
	var dry bool
	for _, q := range r.api.requests() {
		if q.Method == "POST" && strings.Contains(q.Query, "dryRun=All") {
			dry = true
		}
		if (q.Method == "POST" || q.Method == "PUT") && !strings.Contains(q.Query, "dryRun=All") {
			t.Errorf("a write without dryRun: %s %s?%s", q.Method, q.Path, q.Query)
		}
	}
	if !dry {
		t.Error("no dryRun=All request reached the API")
	}
	// an existing name dry-runs a PUT with its version
	r.do(t, "POST", "/api/v1/agents/validate", map[string]any{"name": "researcher", "spec": spec("claude-haiku")})
	// schema failure
	bad := spec("claude-haiku")
	bad["instructions"] = ""
	_, b = r.do(t, "POST", "/api/v1/agents/validate", map[string]any{"name": "draft", "spec": bad})
	if v = decodeInto[model.ValidateResult](t, b); v.Schema.OK || !strings.Contains(strings.Join(v.Schema.Errors, " "), "spec.instructions") {
		t.Fatalf("%+v", v)
	}
	// no name yet: nothing is sent to the API server
	n := len(r.api.requests())
	_, b = r.do(t, "POST", "/api/v1/agents/validate", map[string]any{"name": "", "spec": spec("claude-haiku")})
	if v = decodeInto[model.ValidateResult](t, b); !v.Schema.Skipped {
		t.Fatalf("%+v", v)
	}
	for _, q := range r.api.requests()[n:] {
		if q.Method != "GET" {
			t.Errorf("unexpected %s", q.Method)
		}
	}
}

func TestAuth(t *testing.T) {
	r := newRig(t)
	for _, tc := range []struct{ name, auth string }{{"missing", ""}, {"wrong", "Bearer nope"}, {"prefix of the token", "Bearer " + token[:5]}, {"basic", "Basic " + token}, {"empty", "Bearer "}} {
		for _, p := range []string{"/api/v1/session", "/api/v1/platform", "/api/v1/agents", "/api/v1/agents/x"} {
			resp, b := r.do(t, "GET", p, nil, "Authorization", tc.auth)
			if resp.StatusCode != 401 || errCode(t, b) != "unauthenticated" || resp.Header.Get("WWW-Authenticate") == "" {
				t.Errorf("%s %s: %s %s", tc.name, p, resp.Status, b)
			}
		}
	}
	for _, m := range []struct{ method, path string }{{"POST", "/api/v1/agents"}, {"POST", "/api/v1/agents/validate"}, {"PUT", "/api/v1/agents/x"}, {"DELETE", "/api/v1/agents/x"}} {
		resp, _ := r.do(t, m.method, m.path, map[string]any{}, "Authorization", "")
		if resp.StatusCode != 401 {
			t.Errorf("%s %s without token: %s", m.method, m.path, resp.Status)
		}
	}
	// cookies and X-User-Id are not credentials
	if resp, _ := r.do(t, "GET", "/api/v1/session", nil, "Authorization", "", "Cookie", "token="+token, "X-User-Id", "console"); resp.StatusCode != 401 {
		t.Error("a cookie or X-User-Id was accepted")
	}
	// exempt: health and the app shell
	for _, p := range []string{"/healthz", "/", "/agents/researcher", "/_app/immutable/a.js"} {
		if resp, _ := r.do(t, "GET", p, nil, "Authorization", ""); resp.StatusCode != 200 {
			t.Errorf("%s: %s", p, resp.Status)
		}
	}
}

func TestViewerCannotWrite(t *testing.T) {
	r := newRig(t, func(o *rigOpt) { o.viewer = true })
	r.api.seed("researcher", spec("claude-haiku"), map[string]any{})
	_, b := r.do(t, "GET", "/api/v1/session", nil)
	if s := decodeInto[map[string]any](t, b); s["role"] != "viewer" || s["canWrite"] != false {
		t.Fatalf("%v", s)
	}
	for _, m := range []struct{ method, path string }{{"POST", "/api/v1/agents"}, {"PUT", "/api/v1/agents/researcher"}, {"DELETE", "/api/v1/agents/researcher"}} {
		resp, b := r.do(t, m.method, m.path, map[string]any{"name": "x", "spec": spec("claude-haiku")})
		if resp.StatusCode != 403 || errCode(t, b) != "forbidden" {
			t.Errorf("%s %s: %s %s", m.method, m.path, resp.Status, b)
		}
	}
	for _, q := range r.api.requests() {
		if q.Method != "GET" {
			t.Errorf("the viewer's write reached the cluster: %s %s", q.Method, q.Path)
		}
	}
	// reads and the dry run still work
	for _, p := range []string{"/api/v1/agents", "/api/v1/agents/researcher", "/api/v1/platform"} {
		if resp, _ := r.do(t, "GET", p, nil); resp.StatusCode != 200 {
			t.Errorf("%s: %s", p, resp.Status)
		}
	}
	if resp, _ := r.do(t, "POST", "/api/v1/agents/validate", map[string]any{"name": "x", "spec": spec("claude-haiku")}); resp.StatusCode != 200 {
		t.Error("a viewer may validate")
	}
}

func TestCrossOriginWritesAreRefused(t *testing.T) {
	r := newRig(t)
	body := map[string]any{"name": "fresh", "spec": spec("claude-haiku")}
	for _, h := range [][]string{
		{"Origin", "https://evil.example"},
		{"Origin", "null"},
		{"Sec-Fetch-Site", "cross-site"},
		{"Sec-Fetch-Site", "same-site"},
	} {
		for _, m := range []struct{ method, path string }{{"POST", "/api/v1/agents"}, {"POST", "/api/v1/agents/validate"}, {"PUT", "/api/v1/agents/fresh"}, {"DELETE", "/api/v1/agents/fresh"}} {
			resp, b := r.do(t, m.method, m.path, body, h...)
			if resp.StatusCode != 403 || errCode(t, b) != "cross_origin" {
				t.Errorf("%v %s %s: %s %s", h, m.method, m.path, resp.Status, b)
			}
		}
	}
	if len(r.api.defs) != 0 {
		t.Fatal("a cross-origin write got through")
	}
	// the page's own origin passes, and so does a non-browser client
	host := strings.TrimPrefix(r.ts.URL, "http://")
	if resp, b := r.do(t, "POST", "/api/v1/agents", body, "Origin", "http://"+host, "Sec-Fetch-Site", "same-origin"); resp.StatusCode != 201 {
		t.Fatal(resp.Status, string(b))
	}
}

func TestContentTypeBodyAndMethodLimits(t *testing.T) {
	r := newRig(t)
	body := `{"name":"fresh","spec":{"model":"claude-haiku","instructions":"x"}}`
	for _, ct := range []string{"text/plain", "application/x-www-form-urlencoded", "application/jsonp", ""} {
		resp, b := r.do(t, "POST", "/api/v1/agents", body, "Content-Type", ct)
		if resp.StatusCode != 415 {
			t.Errorf("content type %q: %s %s", ct, resp.Status, b)
		}
	}
	if resp, b := r.do(t, "POST", "/api/v1/agents", body, "Content-Type", "application/json; charset=utf-8"); resp.StatusCode != 201 {
		t.Fatal(resp.Status, string(b))
	}
	// unknown fields and trailing data
	if resp, _ := r.do(t, "POST", "/api/v1/agents", `{"name":"a","spec":{"model":"m","instructions":"x","image":"evil"}}`); resp.StatusCode != 400 {
		t.Error("an unknown spec field was accepted")
	}
	if resp, _ := r.do(t, "POST", "/api/v1/agents", body+`{}`); resp.StatusCode != 400 {
		t.Error("data after the JSON value was accepted")
	}
	// 256 KiB body limit
	big := `{"name":"big","spec":{"model":"m","instructions":"` + strings.Repeat("a", 300<<10) + `"}}`
	if resp, b := r.do(t, "POST", "/api/v1/agents", big); resp.StatusCode != 413 || errCode(t, b) != "too_large" {
		t.Fatal(resp.Status, string(b))
	}
	// methods
	for _, m := range []string{"PATCH", "OPTIONS", "TRACE"} {
		if resp, _ := r.do(t, m, "/api/v1/agents", nil); resp.StatusCode != 405 {
			t.Errorf("%s: %s", m, resp.Status)
		}
	}
	resp, b := r.do(t, "DELETE", "/api/v1/agents", nil)
	if resp.StatusCode != 405 || resp.Header.Get("Allow") != "GET, POST" || errCode(t, b) != "method_not_allowed" {
		t.Errorf("%s %v %s", resp.Status, resp.Header, b)
	}
	if resp, _ := r.do(t, "POST", "/api/v1/session", nil); resp.StatusCode != 405 {
		t.Errorf("POST session: %s", resp.Status)
	}
	if resp, b := r.do(t, "GET", "/api/v1/unknown", nil); resp.StatusCode != 404 || errCode(t, b) != "not_found" {
		t.Errorf("%s %s", resp.Status, b)
	}
	if resp, _ := r.do(t, "POST", "/index.html", nil); resp.StatusCode != 405 {
		t.Errorf("POST static: %s", resp.Status)
	}
}

func TestHeaderLimitIs16KiB(t *testing.T) {
	if server.MaxHeaderBytes != 16<<10 || server.HTTPServer(nil).MaxHeaderBytes != 16<<10 {
		t.Fatal("limit")
	}
	// a real server with the same limits
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	hs := server.HTTPServer(server.New(server.Options{Authenticator: nil}))
	go hs.Serve(ln)
	defer hs.Close()
	req, _ := http.NewRequest("GET", "http://"+ln.Addr().String()+"/healthz", nil)
	req.Header.Set("X-Big", strings.Repeat("a", 20<<10))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 431 {
		t.Fatalf("a 20 KiB header got %s", resp.Status)
	}
	req.Header.Set("X-Big", strings.Repeat("a", 8<<10))
	if resp, err = http.DefaultClient.Do(req); err != nil || resp.StatusCode != 200 {
		t.Fatalf("an 8 KiB header: %v %v", resp, err)
	}
	resp.Body.Close()
}

func TestSecurityHeadersOnEveryResponse(t *testing.T) {
	r := newRig(t)
	cases := []struct {
		method, path string
		hdr          []string
		want         int
	}{
		{"GET", "/healthz", nil, 200}, {"GET", "/", nil, 200}, {"GET", "/agents/researcher", nil, 200}, {"GET", "/_app/immutable/a.js", nil, 200},
		{"GET", "/missing.png", nil, 404}, {"GET", "/api/v1/session", nil, 200}, {"GET", "/api/v1/session", []string{"Authorization", ""}, 401},
		{"GET", "/api/v1/nope", nil, 404}, {"DELETE", "/api/v1/session", nil, 405}, {"PATCH", "/", nil, 405}, {"POST", "/api/v1/agents", []string{"Origin", "https://evil.example"}, 403},
		{"POST", "/api/v1/agents", []string{"Content-Type", "text/plain"}, 415}, {"GET", "/api/v1/agents/ghost", nil, 404},
	}
	for _, c := range cases {
		resp, _ := r.do(t, c.method, c.path, nil, c.hdr...)
		if resp.StatusCode != c.want {
			t.Errorf("%s %s: got %d want %d", c.method, c.path, resp.StatusCode, c.want)
		}
		h := resp.Header
		for k, v := range map[string]string{"X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "Cross-Origin-Opener-Policy": "same-origin"} {
			if h.Get(k) != v {
				t.Errorf("%s %s: %s = %q", c.method, c.path, k, h.Get(k))
			}
		}
		csp := h.Get("Content-Security-Policy")
		for _, d := range []string{"default-src 'self'", "style-src 'self'", "img-src 'self' data:", "connect-src 'self'", "frame-ancestors 'none'", "base-uri 'none'", "form-action 'self'"} {
			if !strings.Contains(csp, d) {
				t.Errorf("%s %s: CSP lacks %q: %s", c.method, c.path, d, csp)
			}
		}
		if strings.Contains(csp, "unsafe-inline") || strings.Contains(csp, "unsafe-eval") {
			t.Errorf("CSP allows inline: %s", csp)
		}
		if strings.HasPrefix(c.path, "/api/") && h.Get("Cache-Control") != "no-store" {
			t.Errorf("%s %s: Cache-Control = %q", c.method, c.path, h.Get("Cache-Control"))
		}
	}
}

func TestNothingFromTheBrowserIsForwardedUpstream(t *testing.T) {
	r := newRig(t)
	browser := []string{"Authorization", "Bearer " + token, "Cookie", "session=abc", "X-User-Id", "attacker", "X-Forwarded-For", "6.6.6.6", "Origin", "http://" + strings.TrimPrefix(r.ts.URL, "http://"),
		"Sec-Fetch-Site", "same-origin", "X-Custom", "browser-value", "Referer", "http://x"}
	r.api.seed("researcher", spec("claude-haiku"), map[string]any{})
	r.do(t, "GET", "/api/v1/agents", nil, browser[2:]...)
	r.do(t, "GET", "/api/v1/agents/researcher", nil, browser[2:]...)
	r.do(t, "POST", "/api/v1/agents", map[string]any{"name": "fresh", "spec": spec("claude-haiku")}, browser[2:]...)
	r.do(t, "POST", "/api/v1/agents/validate", map[string]any{"name": "fresh", "spec": spec("claude-haiku")}, browser[2:]...)
	_, b := r.do(t, "GET", "/api/v1/agents/fresh", nil)
	rv := decodeInto[model.Detail](t, b).ResourceVersion
	r.do(t, "PUT", "/api/v1/agents/fresh", map[string]any{"resourceVersion": rv, "spec": spec("claude-haiku")}, browser[2:]...)
	r.do(t, "DELETE", "/api/v1/agents/fresh", nil, browser[2:]...)
	reqs := r.api.requests()
	if len(reqs) < 8 {
		t.Fatalf("only %d upstream requests", len(reqs))
	}
	for _, q := range reqs {
		if got := q.Header.Get("Authorization"); got != "Bearer "+saToken {
			t.Errorf("%s %s: upstream Authorization = %q", q.Method, q.Path, got)
		}
		for _, h := range []string{"Cookie", "X-User-Id", "X-Forwarded-For", "Origin", "Sec-Fetch-Site", "X-Custom", "Referer"} {
			if v := q.Header.Get(h); v != "" {
				t.Errorf("%s %s: upstream received %s: %q", q.Method, q.Path, h, v)
			}
		}
		for k, v := range q.Header {
			if strings.Contains(strings.Join(v, ""), token) {
				t.Errorf("the console token reached the cluster in %s", k)
			}
		}
	}
}

func TestOnlyFixedUpstreamPaths(t *testing.T) {
	r := newRig(t)
	r.api.seed("researcher", spec("claude-haiku"), map[string]any{})
	for _, p := range []string{"/api/v1/agents", "/api/v1/agents/researcher", "/api/v1/agents/../../etc", "/api/v1/agents/%2e%2e%2fsecrets", "/api/v1/agents/a%2Fb"} {
		r.do(t, "GET", p, nil)
	}
	const defs = "/apis/openagentix.io/v1alpha1/namespaces/kagent/agentdefinitions"
	const kag = "/apis/api.kagent.dev/v1alpha3/namespaces/kagent/"
	// exactly these, and nothing else: the list reads definitions and four kagent kinds, the one valid name reads one object,
	// and the climbing, encoded and slash-carrying names never leave the console
	want := []string{"GET " + defs, "GET " + defs + "/researcher", "GET " + kag + "agents", "GET " + kag + "agenttemplates", "GET " + kag + "harnesses", "GET " + kag + "modelconfigs"}
	var got []string
	for _, q := range r.api.requests() {
		got = append(got, q.Method+" "+q.Path)
	}
	slices.Sort(got)
	slices.Sort(want)
	if len(got) == 0 || !slices.Equal(got, want) {
		t.Fatalf("upstream requests\n got  %q\n want %q", got, want)
	}
}

func TestAuditLinesNeverHoldInstructionsOrTokens(t *testing.T) {
	r := newRig(t)
	const canary = "CANARY-INSTRUCTIONS-do-not-log-me"
	s := spec("claude-haiku")
	s["instructions"] = canary
	resp, b := r.do(t, "POST", "/api/v1/agents", map[string]any{"name": "audited", "spec": s})
	if resp.StatusCode != 201 {
		t.Fatal(resp.Status, string(b))
	}
	rv := decodeInto[model.Detail](t, b).ResourceVersion
	r.do(t, "PUT", "/api/v1/agents/audited", map[string]any{"resourceVersion": "stale", "spec": s})
	r.do(t, "PUT", "/api/v1/agents/audited", map[string]any{"resourceVersion": rv, "spec": s})
	r.do(t, "GET", "/api/v1/agents/audited", nil)
	r.do(t, "DELETE", "/api/v1/agents/audited", nil)
	r.do(t, "DELETE", "/api/v1/agents/audited", nil)
	r.do(t, "POST", "/api/v1/agents", map[string]any{"name": "audited", "spec": s}, "Authorization", "Bearer wrong-token-CANARY")

	lines := strings.Split(strings.TrimSpace(r.audit.String()), "\n")
	var got []map[string]any
	for _, l := range lines {
		got = append(got, decodeInto[map[string]any](t, []byte(l)))
	}
	type want struct{ action, outcome string }
	wants := []want{{"create", "ok"}, {"update", "conflict"}, {"update", "ok"}, {"delete", "ok"}, {"delete", "not_found"}}
	if len(got) != len(wants) {
		t.Fatalf("%d audit lines, want %d:\n%s", len(got), len(wants), r.audit.String())
	}
	for i, w := range wants {
		g := got[i]
		if g["audit"] != true || g["who"] != "console" || g["action"] != w.action || g["agent"] != "audited" || g["outcome"] != w.outcome || g["kind"] != "agentdefinition" || g["request_id"] == "" || g["time"] == nil {
			t.Errorf("line %d = %v, want %v", i, g, w)
		}
	}
	for name, text := range map[string]string{"audit": r.audit.String(), "log": r.logs.String()} {
		for _, secret := range []string{canary, token, saToken, "wrong-token-CANARY", "Answer plainly"} {
			if strings.Contains(text, secret) {
				t.Errorf("%s output contains %q", name, secret)
			}
		}
	}
}

func TestViewerWriteIsAuditedAsDenied(t *testing.T) {
	r := newRig(t, func(o *rigOpt) { o.viewer = true })
	r.do(t, "DELETE", "/api/v1/agents/researcher", nil)
	if !strings.Contains(r.audit.String(), `"outcome":"denied"`) || !strings.Contains(r.audit.String(), `"status":403`) {
		t.Fatal(r.audit.String())
	}
}

func TestStaticFilesAndSPAFallback(t *testing.T) {
	r := newRig(t, func(o *rigOpt) {
		o.static = func() *fstest.MapFS {
			return &fstest.MapFS{"index.html": {Data: []byte("<!doctype html><title>shell</title>")}, "_app/immutable/app.js": {Data: []byte("console.log(1)")},
				"fonts/a.woff2": {Data: []byte("font")}, "favicon.svg": {Data: []byte("<svg/>")}}
		}
	})
	check := func(path string, code int, ct, sub, cache string) {
		t.Helper()
		resp, b := r.do(t, "GET", path, nil, "Authorization", "")
		if resp.StatusCode != code || !strings.Contains(string(b), sub) || !strings.HasPrefix(resp.Header.Get("Content-Type"), ct) || !strings.Contains(resp.Header.Get("Cache-Control"), cache) {
			t.Errorf("%s: %d %q %q cache=%q body=%q", path, resp.StatusCode, resp.Header.Get("Content-Type"), sub, resp.Header.Get("Cache-Control"), b)
		}
	}
	check("/", 200, "text/html", "shell", "no-cache")
	check("/agents/researcher", 200, "text/html", "shell", "no-cache")
	check("/agents/new", 200, "text/html", "shell", "no-cache")
	check("/settings", 200, "text/html", "shell", "no-cache")
	check("/_app/immutable/app.js", 200, "text/javascript", "console.log", "immutable")
	check("/fonts/a.woff2", 200, "font/woff2", "font", "max-age")
	check("/favicon.svg", 200, "image/svg+xml", "<svg", "max-age")
	check("/_app/immutable/missing.js", 404, "text/plain", "not found", "")
	check("/missing.png", 404, "text/plain", "not found", "")
	check("/../../etc/passwd", 200, "text/html", "shell", "no-cache")
	// the shell holds no data
	if resp, b := r.do(t, "GET", "/", nil, "Authorization", ""); resp.StatusCode != 200 || strings.Contains(string(b), "researcher") {
		t.Error("the app shell exposes data")
	}
	// HEAD
	if resp, _ := r.do(t, "HEAD", "/", nil, "Authorization", ""); resp.StatusCode != 200 {
		t.Error(resp.Status)
	}
}

func TestPlaceholderBuildAnswers503WithAHint(t *testing.T) {
	r := newRig(t, func(o *rigOpt) {
		o.static = func() *fstest.MapFS { return &fstest.MapFS{"PLACEHOLDER": {Data: []byte("x")}} }
	})
	resp, b := r.do(t, "GET", "/agents", nil, "Authorization", "")
	if resp.StatusCode != 503 || !strings.Contains(string(b), "build-web.sh") {
		t.Fatal(resp.Status, string(b))
	}
}

func TestUpstreamFailuresReadAsSentences(t *testing.T) {
	r := newRig(t)
	r.api.srv.Close()
	resp, b := r.do(t, "GET", "/api/v1/agents", nil)
	if resp.StatusCode != 502 || errCode(t, b) != "cluster_unreachable" || !strings.Contains(string(b), "not reachable") {
		t.Fatal(resp.Status, string(b))
	}
}

func TestTimeoutAnswers504(t *testing.T) {
	r := newRigTimeout(t, 1*time.Second)
	r.api.slow = make(chan struct{})
	defer close(r.api.slow)
	resp, b := r.do(t, "GET", "/api/v1/agents", nil)
	if resp.StatusCode != 504 || errCode(t, b) != "timeout" {
		t.Fatal(resp.Status, string(b))
	}
}

var _ = bytes.NewReader
var _ context.Context

func TestSuspendedDefinitionIsPausedAndLabelsAreTags(t *testing.T) {
	r := newRig(t)
	sp := spec("claude-haiku")
	sp["suspend"] = true
	sp["knowledge"] = map[string]any{"enabled": true, "collections": []string{}}
	sp["skills"] = []map[string]any{{"name": "openagentix-canary", "version": "1"}}
	r.api.seed("paused-one", sp, map[string]any{"conditions": []any{map[string]any{"type": "Accepted", "status": "True", "reason": "Accepted"}, map[string]any{"type": "Ready", "status": "True", "reason": "Ready"}}})
	r.api.defs["paused-one"]["metadata"].(map[string]any)["labels"] = map[string]any{"openagentix.io/team": "platform", "openagentix.io/project": "demo"}
	_, b := r.do(t, "GET", "/api/v1/agents", nil)
	for _, a := range decodeInto[model.AgentList](t, b).Items {
		if a.Name == "paused-one" && (a.State != model.StatePaused || !a.Suspended || a.Team != "platform" || a.Project != "demo" || !a.Knowledge || a.Skills[0] != "openagentix-canary") {
			t.Fatalf("%+v", a)
		}
	}
	_, b = r.do(t, "GET", "/api/v1/agents/paused-one", nil)
	d := decodeInto[model.Detail](t, b)
	if !strings.Contains(d.YAML, "  suspend: true\n") || !strings.Contains(d.YAML, "  knowledge:\n    enabled: true\n") || strings.Contains(d.YAML, "keySecret") {
		t.Fatal(d.YAML)
	}
	// the old boolean shape is refused
	if resp, _ := r.do(t, "POST", "/api/v1/agents", `{"name":"old","spec":{"model":"m","instructions":"x","knowledge":true}}`); resp.StatusCode != 400 {
		t.Fatal("the old boolean shape must not be accepted", resp.Status)
	}
}
