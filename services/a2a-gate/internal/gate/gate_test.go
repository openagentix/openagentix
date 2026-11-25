package gate

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/openagentix/openagentix/services/a2a-gate/internal/auth"
	"github.com/openagentix/openagentix/services/a2a-gate/internal/rules"
)

const rulesJSON = `{"callers":[
 {"name":"bridge","serviceAccount":{"namespace":"gw","name":"bridge"},"agents":["kagent/assistant"],"userId":{"prefix":"telegram:"}},
 {"name":"bridge-mem","serviceAccount":{"namespace":"gw","name":"bridge-mem"},"agents":["kagent/assistant"],"userId":{"prefix":"telegram:"},"memory":true,"methods":["SendMessage"]},
 {"name":"schedule-x","serviceAccount":{"namespace":"sch","name":"schedule-x"},"agents":["kagent/assistant"],"userId":{"exact":"schedule:x"},"methods":["SendMessage"]},
 {"name":"kourier-b","key":true,"agents":["kagent/assistant"],"userId":{"fixed":"kourier:b"},"methods":["SendMessage","SendStreamingMessage","GetTask","SubscribeToTask","CancelTask"]}
]}`

// jwt builds a JWT-shaped token that passes the gate's cheap pre-filter (audience "aud", issuer, expiry).
func jwt(who string, exp time.Time, aud string) string {
	b, _ := json.Marshal(map[string]any{"aud": []string{aud}, "iss": "https://kubernetes.default.svc", "exp": exp.Unix(), "sub": who})
	return "eyJhbGciOiJSUzI1NiJ9." + base64.RawURLEncoding.EncodeToString(b) + ".c2ln"
}

var (
	tokBridge    = jwt("bridge", time.Now().Add(time.Hour), "aud")
	tokSchedule  = jwt("schedule", time.Now().Add(time.Hour), "aud")
	tokBridgeMem = jwt("bridge-mem", time.Now().Add(time.Hour), "aud")
	tokExpired   = jwt("expired", time.Now().Add(-time.Hour), "aud")
	tokOtherAud  = jwt("other", time.Now().Add(time.Hour), "other")
)

const (
	keyKourier = "kourier-static-key-0123456789"
	canary     = "CANARY-MESSAGE-TEXT-7731"
)

type fakeKeys map[string]string

func (f fakeKeys) Hashes() map[string]string { return f }

type fakeReviewer struct{}

func (fakeReviewer) Review(_ context.Context, token, _ string) (string, error) {
	switch token {
	case tokBridge:
		return "system:serviceaccount:gw:bridge", nil
	case tokBridgeMem:
		return "system:serviceaccount:gw:bridge-mem", nil
	case tokSchedule:
		return "system:serviceaccount:sch:schedule-x", nil
	}
	return "", auth.ErrUnauthenticated
}

type seen struct {
	Method, URL string
	Header      http.Header
	Body        []byte
}

type rig struct {
	t      *testing.T
	up     *httptest.Server
	srv    *httptest.Server
	audit  *syncBuf
	mu     sync.Mutex
	seen   []seen
	handle http.HandlerFunc
	sent   atomic.Int64 // requests sent through do that write an audit line (everything but the probes)
}

type syncBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuf) Write(p []byte) (int, error) { s.mu.Lock(); defer s.mu.Unlock(); return s.b.Write(p) }
func (s *syncBuf) String() string              { s.mu.Lock(); defer s.mu.Unlock(); return s.b.String() }

func sum(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) }

func newRig(t *testing.T, mut func(*Options)) *rig {
	t.Helper()
	r := &rig{t: t, audit: &syncBuf{}}
	r.up = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		b, _ := io.ReadAll(req.Body)
		r.mu.Lock()
		r.seen = append(r.seen, seen{req.Method, req.URL.String(), req.Header.Clone(), b})
		r.mu.Unlock()
		if r.handle != nil {
			r.handle(w, req)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"jsonrpc":"2.0","id":"1","result":{}}`)
	}))
	t.Cleanup(r.up.Close)
	rl, err := rules.Parse([]byte(rulesJSON))
	if err != nil {
		t.Fatal(err)
	}
	o := Options{
		UpstreamURL: r.up.URL,
		Auth:        auth.New(auth.Options{Rules: rl, Audience: "aud", Keys: fakeKeys{"kourier-b": sum(keyKourier)}, Reviewer: fakeReviewer{}}),
		Audit:       slog.New(slog.NewJSONHandler(r.audit, nil)),
		AuditUserID: "hash",
		Salt:        []byte("test-salt"),
		SniffBytes:  1024,
		MaxBody:     1 << 20,
	}
	if mut != nil {
		mut(&o)
	}
	h, err := New(o)
	if err != nil {
		t.Fatal(err)
	}
	r.srv = httptest.NewServer(h)
	t.Cleanup(r.srv.Close)
	return r
}

func (r *rig) do(method, path, token string, hdr map[string]string, body string) (*http.Response, string) {
	r.t.Helper()
	if path != "/healthz" && path != "/readyz" {
		r.sent.Add(1)
	}
	req, _ := http.NewRequest(method, r.srv.URL+path, strings.NewReader(body))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		r.t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp, string(b)
}

func (r *rig) upstreamCalls() []seen {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]seen(nil), r.seen...)
}

// waitLines waits until n audit lines are written: the line is written when the handler returns, which can be
// just after the client has its response.
func (r *rig) waitLines(n int) {
	r.t.Helper()
	for i := 0; i < 200; i++ {
		if strings.Count(r.audit.String(), "\n") >= n {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	r.t.Fatalf("expected %d audit lines, have:\n%s", n, r.audit.String())
}

// auditLines returns the audit lines of every request sent through do. The line is written when the handler
// returns, which can be after the client has its response, so it first waits for one line per request sent.
func (r *rig) auditLines() []map[string]any {
	r.t.Helper()
	if n := int(r.sent.Load()); n > 0 {
		r.waitLines(n)
	}
	var out []map[string]any
	for _, l := range strings.Split(strings.TrimSpace(r.audit.String()), "\n") {
		if l == "" {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(l), &m); err != nil {
			r.t.Fatalf("audit line is not JSON: %q", l)
		}
		out = append(out, m)
	}
	return out
}

func msg(ctx string) string {
	return `{"jsonrpc":"2.0","id":"1","method":"SendMessage","params":{"message":{"messageId":"m1","contextId":"` + ctx + `","role":"ROLE_USER","parts":[{"text":"` + canary + `"}]}}}`
}

const agentPath = "/agents/kagent/assistant"

func TestUnauthenticated(t *testing.T) {
	r := newRig(t, nil)
	for name, tc := range map[string]struct{ token string }{
		"no token":       {""},
		"expired":        {tokExpired},
		"garbage":        {"nope"},
		"wrong audience": {tokOtherAud},
	} {
		resp, _ := r.do("POST", agentPath, tc.token, map[string]string{"X-User-Id": "telegram:1"}, msg("c1"))
		if resp.StatusCode != 401 {
			t.Errorf("%s: status %d, want 401", name, resp.StatusCode)
		}
	}
	resp, _ := r.do("POST", agentPath, "", map[string]string{"Authorization": "Basic Zm9vOmJhcg=="}, msg("c1"))
	if resp.StatusCode != 401 {
		t.Errorf("basic auth: status %d", resp.StatusCode)
	}
	if n := len(r.upstreamCalls()); n != 0 {
		t.Fatalf("upstream was called %d times", n)
	}
}

func TestIdentityHeadersAreRewritten(t *testing.T) {
	r := newRig(t, nil)
	resp, _ := r.do("POST", agentPath+"?user_id=admin@kagent.dev&x=1", tokBridge, map[string]string{
		"X-User-Id": "telegram:42", "A2A-Version": "1.0", "Traceparent": "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
		"X-Agent-Name": "x", "X-Share-Token": "y", "Cookie": "a=b", "Proxy-Authorization": "z", "Baggage": "user.id=evil",
		"X-Kagent-Insecure-Runtime-Identity": "z", "X-Forwarded-For": "6.6.6.6", "Content-Type": "application/json",
	}, msg("c1"))
	if resp.StatusCode != 200 {
		t.Fatalf("status %d", resp.StatusCode)
	}
	c := r.upstreamCalls()
	if len(c) != 1 {
		t.Fatalf("upstream calls = %d", len(c))
	}
	u := c[0]
	if u.URL != agentPath {
		t.Errorf("upstream URL %q: the query (and user_id with it) must be dropped", u.URL)
	}
	if got := u.Header.Values("X-User-Id"); len(got) != 1 || got[0] != "telegram:42" {
		t.Errorf("X-User-Id = %v", got)
	}
	for _, h := range []string{"Authorization", "X-Agent-Name", "X-Share-Token", "Cookie", "Proxy-Authorization", "Baggage", "X-Kagent-Insecure-Runtime-Identity"} {
		if v := u.Header.Values(h); len(v) != 0 {
			t.Errorf("%s was forwarded: %v", h, v)
		}
	}
	if u.Header.Get("A2A-Version") != "1.0" || !strings.HasPrefix(u.Header.Get("Traceparent"), "00-0af7651916cd43dd8448eb211c80319c-") {
		t.Errorf("A2A-Version and traceparent must be forwarded: %v", u.Header)
	}
	if strings.Contains(u.Header.Get("X-Forwarded-For"), "6.6.6.6") {
		t.Errorf("a forged X-Forwarded-For was forwarded")
	}
	if !strings.Contains(string(u.Body), canary) {
		t.Error("the body must reach the agent unchanged")
	}
}

func TestUserIDRules(t *testing.T) {
	r := newRig(t, nil)
	tests := []struct {
		name, token string
		hdr         map[string]string
		status      int
		upstreamID  string
	}{
		{"prefix ok", tokBridge, map[string]string{"X-User-Id": "telegram:7"}, 200, "telegram:7"},
		{"prefix wrong", tokBridge, map[string]string{"X-User-Id": "admin@kagent.dev"}, 403, ""},
		{"prefix missing", tokBridge, nil, 403, ""},
		{"exact ok", tokSchedule, map[string]string{"X-User-Id": "schedule:x"}, 200, "schedule:x"},
		{"exact for another schedule", tokSchedule, map[string]string{"X-User-Id": "schedule:y"}, 403, ""},
		{"bridge token claims a schedule id", tokBridge, map[string]string{"X-User-Id": "schedule:demo-brief"}, 403, ""},
		{"fixed overwrites", keyKourier, map[string]string{"X-User-Id": "someone-else"}, 200, "kourier:b"},
		{"fixed fills in", keyKourier, nil, 200, "kourier:b"},
	}
	for _, tc := range tests {
		before := len(r.upstreamCalls())
		resp, _ := r.do("POST", agentPath, tc.token, tc.hdr, msg("c"))
		if resp.StatusCode != tc.status {
			t.Errorf("%s: status %d want %d", tc.name, resp.StatusCode, tc.status)
			continue
		}
		calls := r.upstreamCalls()
		if tc.status == 200 {
			if got := calls[len(calls)-1].Header.Get("X-User-Id"); got != tc.upstreamID {
				t.Errorf("%s: upstream X-User-Id %q want %q", tc.name, got, tc.upstreamID)
			}
		} else if len(calls) != before {
			t.Errorf("%s: a refused request reached the upstream", tc.name)
		}
	}
}

func TestAgentRule(t *testing.T) {
	r := newRig(t, nil)
	for _, p := range []string{"/agents/kagent/other", "/agents/other/assistant", "/agents/kagent"} {
		resp, _ := r.do("POST", p, tokBridge, map[string]string{"X-User-Id": "telegram:1"}, msg("c"))
		if resp.StatusCode != 403 && resp.StatusCode != 404 {
			t.Errorf("%s: status %d", p, resp.StatusCode)
		}
	}
	if len(r.upstreamCalls()) != 0 {
		t.Fatal("upstream was reached")
	}
}

func TestOnlyA2APathsPass(t *testing.T) {
	r := newRig(t, nil)
	hdr := map[string]string{"X-User-Id": "telegram:1", "Content-Type": "application/json"}
	paths := []struct{ method, path, ctype string }{
		{"POST", "/kagent.runtime.v1.MemoryService/List", "application/grpc"},
		{"POST", "/kagent.runtime.v1.MemoryService/Delete", "application/grpc-web+proto"},
		{"POST", agentPath, "application/grpc"},
		{"POST", agentPath, "application/grpc-web-text"},
		{"POST", agentPath, "Application/GRPC+proto"},
		{"GET", "/api/sessions", ""},
		{"GET", "/api/memories", ""},
		{"POST", "/api/a2a/kagent/assistant", ""},
		{"GET", agentPath, ""},
		{"DELETE", agentPath, ""},
		{"PUT", agentPath, ""},
		{"POST", agentPath + "/admin", ""},
		{"POST", agentPath + "/../../api/sessions", ""},
		{"POST", "/agents/kagent/assistant%2f..%2f..%2fapi", ""},
		{"POST", "//agents/kagent/assistant", ""},
		{"GET", "/agents/kagent/assistant/.well-known/other.json", ""},
		{"POST", "/", ""},
		{"GET", "/metrics", ""},
	}
	for _, p := range paths {
		h := map[string]string{}
		for k, v := range hdr {
			h[k] = v
		}
		if p.ctype != "" {
			h["Content-Type"] = p.ctype
		}
		resp, _ := r.do(p.method, p.path, tokBridge, h, msg("c"))
		if resp.StatusCode != 403 && resp.StatusCode != 404 {
			t.Errorf("%s %s (%s): status %d, want 403", p.method, p.path, p.ctype, resp.StatusCode)
		}
	}
	// the same refusals hold for every kind of caller
	for _, tok := range []string{tokSchedule, keyKourier} {
		resp, _ := r.do("POST", "/kagent.runtime.v1.MemoryService/List", tok, map[string]string{"Content-Type": "application/grpc"}, "")
		if resp.StatusCode != 403 {
			t.Errorf("grpc as %s: status %d", tok, resp.StatusCode)
		}
	}
	if n := len(r.upstreamCalls()); n != 0 {
		t.Fatalf("refused requests reached the upstream %d times", n)
	}
}

func TestAgentCardAndRESTSubpaths(t *testing.T) {
	r := newRig(t, nil)
	for _, p := range []string{agentPath + "/.well-known/agent-card.json", agentPath + "/.well-known/agent.json"} {
		resp, _ := r.do("GET", p, tokBridge, map[string]string{"X-User-Id": "admin@kagent.dev"}, "")
		if resp.StatusCode != 200 {
			t.Errorf("GET %s: %d", p, resp.StatusCode)
		}
	}
	c := r.upstreamCalls()
	if len(c) != 2 {
		t.Fatalf("calls = %d", len(c))
	}
	for _, u := range c {
		if len(u.Header.Values("X-User-Id")) != 0 || len(u.Header.Values("Authorization")) != 0 {
			t.Errorf("card request carried identity headers: %v", u.Header)
		}
	}
	for _, p := range []string{agentPath + "/message:send", agentPath + "/message:stream", agentPath + "/v1/message:send", agentPath + "/"} {
		resp, _ := r.do("POST", p, tokBridge, map[string]string{"X-User-Id": "telegram:1"}, msg("c"))
		if resp.StatusCode != 200 {
			t.Errorf("POST %s: %d", p, resp.StatusCode)
		}
	}
	// an agent-card GET still respects the agent rule
	if resp, _ := r.do("GET", "/agents/kagent/other/.well-known/agent-card.json", tokBridge, nil, ""); resp.StatusCode != 403 {
		t.Errorf("card of another agent: %d", resp.StatusCode)
	}
}

func TestHealthNeedsNoToken(t *testing.T) {
	r := newRig(t, nil)
	for _, p := range []string{"/healthz", "/readyz"} {
		if resp, _ := r.do("GET", p, "", nil, ""); resp.StatusCode != 200 {
			t.Errorf("%s: %d", p, resp.StatusCode)
		}
	}
	if len(r.auditLines()) != 0 {
		t.Error("probes must not write audit lines")
	}
}

func TestSSEIsFlushedPerEvent(t *testing.T) {
	r := newRig(t, nil)
	release := make(chan struct{})
	r.handle = func(w http.ResponseWriter, req *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(200)
		io.WriteString(w, "data: {\"n\":1}\n\n")
		w.(http.Flusher).Flush()
		<-release
		io.WriteString(w, "data: {\"n\":2}\n\n")
		w.(http.Flusher).Flush()
	}
	req, _ := http.NewRequest("POST", r.srv.URL+agentPath, strings.NewReader(msg("c")))
	req.Header.Set("Authorization", "Bearer "+tokBridge)
	req.Header.Set("X-User-Id", "telegram:1")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	rd := bufio.NewReader(resp.Body)
	got := make(chan string, 1)
	go func() { l, _ := rd.ReadString('\n'); got <- l }()
	select {
	case l := <-got:
		if !strings.HasPrefix(l, "data:") {
			t.Fatalf("first line %q", l)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("first event not delivered before the stream ended: the proxy buffers")
	}
	close(release)
	io.Copy(io.Discard, rd)
}

func TestAuditLine(t *testing.T) {
	r := newRig(t, nil)
	r.do("POST", agentPath, tokBridge, map[string]string{
		"X-User-Id": "telegram:424242", "Traceparent": "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
	}, msg("ctx-abc_1"))
	r.do("POST", agentPath, "bad.token.x", map[string]string{"X-User-Id": "telegram:424242"}, msg("c"))
	r.do("POST", agentPath, tokBridge, map[string]string{"X-User-Id": "telegram:424242"}, `{"method":"SendMessage","params":{"message":{"contextId":"`+strings.Repeat("a", 500)+`"}}}`)
	r.waitLines(3)
	raw := r.audit.String()
	for _, secret := range []string{canary, tokBridge, "telegram:424242", "bad.token.x"} {
		if strings.Contains(raw, secret) {
			t.Fatalf("audit output contains %q:\n%s", secret, raw)
		}
	}
	lines := r.auditLines()
	if len(lines) != 3 {
		t.Fatalf("audit lines = %d:\n%s", len(lines), raw)
	}
	a := lines[0]
	want := map[string]any{"msg": "audit", "caller": "bridge", "agent": "kagent/assistant", "context_id": "ctx-abc_1", "trace_id": "0af7651916cd43dd8448eb211c80319c", "status": float64(200)}
	for k, v := range want {
		if a[k] != v {
			t.Errorf("%s = %v, want %v", k, a[k], v)
		}
	}
	h := sha256.Sum256(append([]byte("test-salt"), []byte("telegram:424242")...))
	if a["user_id"] != "h:"+hex.EncodeToString(h[:])[:8] {
		t.Errorf("user_id = %v", a["user_id"])
	}
	for _, k := range []string{"time", "duration_ms", "method"} {
		if _, ok := a[k]; !ok {
			t.Errorf("missing field %s", k)
		}
	}
	if lines[1]["user_id"] != "" {
		t.Errorf("a refused unauthenticated request must not record the claimed user id: %v", lines[1])
	}
	if lines[1]["status"] != float64(401) || lines[1]["caller"] != "" {
		t.Errorf("401 line: %v", lines[1])
	}
	if lines[2]["context_id"] != "invalid" {
		t.Errorf("an over-long contextId must be logged as invalid, got %v", lines[2]["context_id"])
	}
}

// gatedWriter holds every audit write until release is closed.
type gatedWriter struct {
	release chan struct{}
	sink    *syncBuf
}

func (g gatedWriter) Write(p []byte) (int, error) { <-g.release; return g.sink.Write(p) }

// The audit line is written when the handler returns, so a client can hold its response before the line exists
// (the gate cannot know the final status of a stream earlier, and Shutdown waits for the handler, so the line is
// not lost on a graceful stop). auditLines must therefore wait for it; without the wait it returns nothing here.
func TestAuditLinesWaitForTheHandlerToReturn(t *testing.T) {
	g := gatedWriter{release: make(chan struct{}), sink: &syncBuf{}}
	r := newRig(t, func(o *Options) { o.Audit = slog.New(slog.NewJSONHandler(g, nil)) })
	r.audit = g.sink
	r.handle = func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"jsonrpc":"2.0","id":"1","result":{}}`)
		w.(http.Flusher).Flush()
	}
	req, _ := http.NewRequest("POST", r.srv.URL+agentPath, strings.NewReader(msg("c")))
	req.Header.Set("Authorization", "Bearer "+tokBridge)
	req.Header.Set("X-User-Id", "telegram:1")
	r.sent.Add(1)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("status %d", resp.StatusCode)
	}
	if got := r.audit.String(); got != "" {
		t.Fatalf("the client has its response and the audit line is already written: %q", got)
	}
	time.AfterFunc(100*time.Millisecond, func() { close(g.release) })
	if l := r.auditLines(); len(l) != 1 {
		t.Fatalf("auditLines returned %d lines, want 1 (it must wait for the handler)", len(l))
	}
}

func TestAuditRawSwitch(t *testing.T) {
	r := newRig(t, func(o *Options) { o.AuditUserID = "raw" })
	r.do("POST", agentPath, tokBridge, map[string]string{"X-User-Id": "telegram:424242"}, msg("c"))
	r.waitLines(1)
	l := r.auditLines()
	if len(l) != 1 || l[0]["user_id"] != "telegram:424242" {
		t.Fatalf("raw audit: %v", l)
	}
}

func TestAuditNeverCarriesTheBody(t *testing.T) {
	r := newRig(t, nil)
	// the canary sits after the context id; and again beyond the sniff window
	big := `{"params":{"message":{"contextId":"c9","parts":[{"text":"` + canary + strings.Repeat("x", 5000) + canary + `"}]}}}`
	r.do("POST", agentPath+"/message:send", tokBridge, map[string]string{"X-User-Id": "telegram:1"}, big)
	r.waitLines(1)
	if strings.Contains(r.audit.String(), canary) {
		t.Fatal("message text reached the audit line")
	}
	c := r.upstreamCalls()
	if string(c[0].Body) != big {
		t.Fatalf("a body larger than the sniff window must reach the agent whole (got %d bytes, want %d)", len(c[0].Body), len(big))
	}
}

func TestContextIDBeyondSniffWindowIsNotRead(t *testing.T) {
	r := newRig(t, func(o *Options) { o.SniffBytes = 64 })
	body := `{"params":{"message":{"parts":[{"text":"` + strings.Repeat("y", 500) + `"}],"contextId":"late"}}}`
	r.do("POST", agentPath+"/message:send", tokBridge, map[string]string{"X-User-Id": "telegram:1"}, body)
	r.waitLines(1)
	if l := r.auditLines(); l[0]["context_id"] != "" {
		t.Fatalf("context_id = %v", l[0]["context_id"])
	}
	if got := r.upstreamCalls()[0].Body; string(got) != body {
		t.Fatal("body altered")
	}
}

func TestUserIDInAuditIsTruncated(t *testing.T) {
	r := newRig(t, func(o *Options) { o.AuditUserID = "raw" })
	r.do("POST", agentPath, tokBridge, map[string]string{"X-User-Id": "telegram:" + strings.Repeat("9", 400)}, msg("c"))
	r.waitLines(1)
	if got, _ := r.auditLines()[0]["user_id"].(string); len(got) > 128 {
		t.Fatalf("user_id in the audit line has %d bytes", len(got))
	}
}

func TestUpstreamDown(t *testing.T) {
	r := newRig(t, func(o *Options) { o.UpstreamURL = "http://127.0.0.1:1" })
	resp, body := r.do("POST", agentPath, tokBridge, map[string]string{"X-User-Id": "telegram:1"}, msg("c"))
	if resp.StatusCode != 502 {
		t.Fatalf("status %d", resp.StatusCode)
	}
	if strings.Contains(body, "127.0.0.1") {
		t.Errorf("the upstream address leaks into the response: %q", body)
	}
	r.waitLines(1)
	if l := r.auditLines(); l[0]["status"] != float64(502) {
		t.Errorf("audit: %v", l[0])
	}
}

func TestBodyTooLarge(t *testing.T) {
	r := newRig(t, func(o *Options) { o.MaxBody = 1000 })
	resp, _ := r.do("POST", agentPath, tokBridge, map[string]string{"X-User-Id": "telegram:1"}, strings.Repeat("a", 5000))
	if resp.StatusCode != 413 {
		t.Fatalf("status %d", resp.StatusCode)
	}
}

func TestAuthUnavailableFailsClosed(t *testing.T) {
	rl, _ := rules.Parse([]byte(rulesJSON))
	r := newRig(t, func(o *Options) {
		o.Auth = auth.New(auth.Options{Rules: rl, Audience: "aud", Reviewer: errReviewer{}})
	})
	resp, _ := r.do("POST", agentPath, tokBridge, map[string]string{"X-User-Id": "telegram:1"}, msg("c"))
	if resp.StatusCode != 503 {
		t.Fatalf("status %d", resp.StatusCode)
	}
}

type errReviewer struct{}

func (errReviewer) Review(context.Context, string, string) (string, error) {
	return "", io.ErrUnexpectedEOF
}

// ---- round 1 review: method allowlist -------------------------------------------------------------------------

func rpc(method string) string {
	return `{"id":"1","jsonrpc":"2.0","method":"` + method + `","params":{"message":{"messageId":"m","parts":[{"text":"x"}],"role":"ROLE_USER"}}}`
}

func TestMethodAllowlist(t *testing.T) {
	r := newRig(t, nil)
	h := map[string]string{"X-User-Id": "telegram:1"}
	tests := []struct {
		name, token, body string
		status            int
	}{
		{"bridge SendMessage (the default list)", tokBridge, rpc("SendMessage"), 200},
		{"bridge SendStreamingMessage (the default list)", tokBridge, rpc("SendStreamingMessage"), 200},
		{"bridge GetTask is not in the default list", tokBridge, rpc("GetTask"), 403},
		{"bridge CancelTask", tokBridge, rpc("CancelTask"), 403},
		{"bridge push notification config", tokBridge, rpc("CreateTaskPushNotificationConfig"), 403},
		{"bridge legacy name", tokBridge, rpc("message/send"), 403},
		{"schedule has its own list: SendMessage", tokSchedule, rpc("SendMessage"), 200},
		{"schedule has its own list: no streaming", tokSchedule, rpc("SendStreamingMessage"), 403},
		{"Kourier GetTask", keyKourier, rpc("GetTask"), 200},
		{"Kourier SubscribeToTask", keyKourier, rpc("SubscribeToTask"), 200},
		{"Kourier ListTasks is not listed", keyKourier, rpc("ListTasks"), 403},
		{"method is case-sensitive", tokBridge, rpc("sendmessage"), 403},
	}
	for _, tc := range tests {
		hh := h
		if tc.token == tokSchedule {
			hh = map[string]string{"X-User-Id": "schedule:x"}
		}
		before := len(r.upstreamCalls())
		resp, _ := r.do("POST", agentPath, tc.token, hh, tc.body)
		if resp.StatusCode != tc.status {
			t.Errorf("%s: status %d want %d", tc.name, resp.StatusCode, tc.status)
		}
		if tc.status == 403 && len(r.upstreamCalls()) != before {
			t.Errorf("%s: a refused method reached the agent", tc.name)
		}
	}
	r.waitLines(len(tests))
	var refused, withReason int
	for _, l := range r.auditLines() {
		if l["status"] == float64(403) {
			refused++
			if l["reason"] == "method" {
				withReason++
			}
		}
	}
	if refused == 0 || refused != withReason {
		t.Errorf("403 lines %d, with reason method %d", refused, withReason)
	}
}

func TestMethodCannotBeDeterminedFailsClosed(t *testing.T) {
	r := newRig(t, func(o *Options) { o.SniffBytes = 400 })
	h := map[string]string{"X-User-Id": "telegram:1"}
	long := strings.Repeat("z", 600)
	cases := map[string]string{
		"empty body":              ``,
		"not json":                `method=SendMessage`,
		"json array (batch)":      `[` + rpc("SendMessage") + `]`,
		"no method":               `{"jsonrpc":"2.0","id":"1","params":{}}`,
		"method is a number":      `{"method":1,"params":{}}`,
		"method is null":          `{"method":null}`,
		"method is an object":     `{"method":{"a":"SendMessage"}}`,
		"duplicate method":        `{"method":"SendMessage","method":"CancelTask"}`,
		"duplicate, other case":   `{"method":"SendMessage","Method":"CancelTask"}`,
		"escaped duplicate":       `{"method":"SendMessage","m\u0065thod":"CancelTask"}`,
		"method after the window": `{"params":{"message":{"parts":[{"text":"` + long + `"}]}},"method":"SendMessage"}`,
		"body larger than window": `{"method":"SendMessage","params":{"message":{"parts":[{"text":"` + long + `"}]}}}`,
		"trailing data":           rpc("SendMessage") + ` {"method":"CancelTask"}`,
		"truncated json":          `{"method":"SendMessage","params":{`,
	}
	for name, body := range cases {
		before := len(r.upstreamCalls())
		resp, _ := r.do("POST", agentPath, tokBridge, h, body)
		if resp.StatusCode != 403 {
			t.Errorf("%s: status %d, want 403", name, resp.StatusCode)
		}
		if len(r.upstreamCalls()) != before {
			t.Errorf("%s: reached the agent", name)
		}
	}
	r.waitLines(len(cases))
	for _, l := range r.auditLines() {
		if l["reason"] != "method" {
			t.Errorf("audit reason = %v, want method: %v", l["reason"], l)
		}
	}
}

func TestRESTRoutesUseTheMethodOfTheirPath(t *testing.T) {
	r := newRig(t, nil)
	sched := map[string]string{"X-User-Id": "schedule:x"}
	if resp, _ := r.do("POST", agentPath+"/message:send", tokSchedule, sched, `{"message":{"messageId":"m","parts":[{"text":"x"}]}}`); resp.StatusCode != 200 {
		t.Errorf("message:send for a SendMessage caller: %d", resp.StatusCode)
	}
	if resp, _ := r.do("POST", agentPath+"/v1/message:stream", tokSchedule, sched, `{"message":{}}`); resp.StatusCode != 403 {
		t.Errorf("message:stream for a caller without SendStreamingMessage: %d", resp.StatusCode)
	}
	if resp, _ := r.do("POST", agentPath+"/message:stream", tokBridge, map[string]string{"X-User-Id": "telegram:1"}, `{"message":{}}`); resp.StatusCode != 200 {
		t.Errorf("message:stream for the default list: %d", resp.StatusCode)
	}
	// a JSON-RPC body sent to a REST route does not change its method
	if resp, _ := r.do("POST", agentPath+"/message:send", tokSchedule, sched, rpc("CancelTask")); resp.StatusCode != 200 {
		t.Errorf("REST route with a method in the body: %d (the path decides)", resp.StatusCode)
	}
}

// ---- round 1 review: context id --------------------------------------------------------------------------------

// bridgeBody builds the body the Telegram bridge sends (bridges/telegram/internal/a2a/client.go Send): a map with
// jsonrpc, id, method and params.message, where the message struct has messageId, contextId (omitted when empty),
// role and parts. The text is a placeholder.
func bridgeBody(contextID string) string {
	type part struct {
		Text string `json:"text,omitempty"`
	}
	type message struct {
		MessageID string `json:"messageId"`
		ContextID string `json:"contextId,omitempty"`
		Role      string `json:"role"`
		Parts     []part `json:"parts"`
	}
	b, _ := json.Marshal(map[string]any{
		"jsonrpc": "2.0", "id": "1", "method": "SendMessage",
		"params": map[string]any{"message": message{MessageID: "01a20200-33e8-78eb-a4c2-45ac5ae7d989", ContextID: contextID, Role: "ROLE_USER", Parts: []part{{Text: "placeholder"}}}},
	})
	return string(b)
}

func TestContextIDFromTheRealBridgeShape(t *testing.T) {
	r := newRig(t, nil)
	h := map[string]string{"X-User-Id": "telegram:1"}
	r.do("POST", agentPath, tokBridge, h, bridgeBody(""))
	r.do("POST", agentPath, tokBridge, h, bridgeBody("01a20200-256c-7d2a-bf1d-43900dfbbbb2"))
	r.waitLines(2)
	l := r.auditLines()
	if l[0]["context_id"] != "" {
		t.Errorf("first message has no context id, got %v", l[0]["context_id"])
	}
	if l[1]["context_id"] != "01a20200-256c-7d2a-bf1d-43900dfbbbb2" {
		t.Errorf("follow-up context_id = %v", l[1]["context_id"])
	}
	if l[1]["rpc"] != "SendMessage" {
		t.Errorf("rpc = %v", l[1]["rpc"])
	}
}

func TestContextIDOnlyFromTheMessage(t *testing.T) {
	r := newRig(t, nil)
	// a contextId in metadata or in text must not be taken for the message's own
	body := `{"jsonrpc":"2.0","id":"1","method":"SendMessage","params":{"metadata":{"contextId":"decoy"},"message":{"messageId":"m","parts":[{"text":"\"contextId\":\"decoy2\""}]}}}`
	r.do("POST", agentPath, tokBridge, map[string]string{"X-User-Id": "telegram:1"}, body)
	r.waitLines(1)
	if got := r.auditLines()[0]["context_id"]; got != "" {
		t.Fatalf("context_id = %v", got)
	}
}

// ---- round 1 review: resource limits ---------------------------------------------------------------------------

func TestInFlightCap(t *testing.T) {
	release := make(chan struct{})
	r := newRig(t, func(o *Options) { o.MaxInFlight = 2 })
	r.handle = func(w http.ResponseWriter, req *http.Request) { <-release; io.WriteString(w, "{}") }
	done := make(chan int, 3)
	for i := 0; i < 2; i++ {
		go func() {
			resp, _ := r.do("POST", agentPath, tokBridge, map[string]string{"X-User-Id": "telegram:1"}, msg("c"))
			done <- resp.StatusCode
		}()
	}
	for i := 0; i < 200 && len(r.upstreamCalls()) < 2; i++ {
		time.Sleep(10 * time.Millisecond)
	}
	resp, _ := r.do("POST", agentPath, tokBridge, map[string]string{"X-User-Id": "telegram:1"}, msg("c"))
	if resp.StatusCode != 503 || resp.Header.Get("Retry-After") == "" {
		t.Fatalf("third request: status %d, want 503 with Retry-After", resp.StatusCode)
	}
	if resp, _ := r.do("GET", "/healthz", "", nil, ""); resp.StatusCode != 200 {
		t.Errorf("health probes must not count against the cap: %d", resp.StatusCode)
	}
	close(release)
	for i := 0; i < 2; i++ {
		if st := <-done; st != 200 {
			t.Errorf("held request ended with %d", st)
		}
	}
	if resp, _ := r.do("POST", agentPath, tokBridge, map[string]string{"X-User-Id": "telegram:1"}, msg("c")); resp.StatusCode != 200 {
		t.Errorf("after the others finished: %d", resp.StatusCode)
	}
	r.waitLines(4)
	var busy int
	for _, l := range r.auditLines() {
		if l["reason"] == "busy" {
			busy++
		}
	}
	if busy != 1 {
		t.Errorf("busy audit lines = %d, want 1", busy)
	}
}

func rawConn(t *testing.T, srvURL string) net.Conn {
	t.Helper()
	c, err := net.Dial("tcp", strings.TrimPrefix(srvURL, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

func TestSlowBodyIsCutDuringTheSniff(t *testing.T) {
	r := newRig(t, func(o *Options) { o.SniffTimeout = 200 * time.Millisecond })
	c := rawConn(t, r.srv.URL)
	// the headers promise 1000 bytes, then 10 arrive and the client goes quiet
	io.WriteString(c, "POST "+agentPath+" HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer "+tokBridge+"\r\nX-User-Id: telegram:1\r\nContent-Length: 1000\r\n\r\n0123456789")
	c.SetReadDeadline(time.Now().Add(3 * time.Second))
	line, err := bufio.NewReader(c).ReadString('\n')
	if err != nil {
		t.Fatalf("no answer within 3 s: %v", err)
	}
	if !strings.Contains(line, "408") {
		t.Fatalf("status line %q, want 408", line)
	}
	if len(r.upstreamCalls()) != 0 {
		t.Fatal("a half-sent body reached the agent")
	}
	r.waitLines(1)
	if l := r.auditLines()[0]; l["reason"] != "body_timeout" {
		t.Errorf("audit: %v", l)
	}
}

func TestLongBodyStreamsAfterTheSniff(t *testing.T) {
	// the read deadline covers the sniffed part only: once the proxy is running, a slow sender is not cut
	r := newRig(t, func(o *Options) { o.SniffBytes = 64; o.SniffTimeout = 200 * time.Millisecond })
	first, second := strings.Repeat("a", 200), strings.Repeat("b", 100)
	c := rawConn(t, r.srv.URL)
	io.WriteString(c, "POST "+agentPath+"/message:send HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer "+tokBridge+"\r\nX-User-Id: telegram:1\r\nContent-Length: 300\r\n\r\n"+first)
	time.Sleep(600 * time.Millisecond)
	io.WriteString(c, second)
	c.SetReadDeadline(time.Now().Add(3 * time.Second))
	line, err := bufio.NewReader(c).ReadString('\n')
	if err != nil || !strings.Contains(line, "200") {
		t.Fatalf("status line %q err %v", line, err)
	}
	if got := r.upstreamCalls()[0].Body; string(got) != first+second {
		t.Fatalf("upstream body has %d bytes, want 300", len(got))
	}
}

func TestSniffBufferFollowsContentLength(t *testing.T) {
	for _, tc := range []struct {
		cl     int64
		window int
		want   int
	}{{-1, 65536, 65536}, {0, 65536, 0}, {120, 65536, 120}, {70000, 65536, 65536}} {
		if got := sniffSize(tc.cl, tc.window); got != tc.want {
			t.Errorf("sniffSize(%d,%d) = %d, want %d", tc.cl, tc.window, got, tc.want)
		}
	}
}
