package gate

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/openagentix/openagentix/services/a2a-gate/internal/auth"
	"github.com/openagentix/openagentix/services/a2a-gate/internal/rules"
)

func TestParseRoutesAccepts(t *testing.T) {
	set, err := ParseRoutes([]byte(`{"container":["kagent/echo-go","kagent/a1","x/y"]}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(set) != 3 || !set.Has("kagent", "echo-go") || set.Has("kagent", "other") {
		t.Fatalf("%v", set)
	}
	if set, err = ParseRoutes([]byte(" {\"container\":[]}\n")); err != nil || len(set) != 0 {
		t.Fatalf("empty list: %v %v", set, err)
	}
}

func TestParseRoutesRejects(t *testing.T) {
	long := strings.Repeat("a", 64)
	many := make([]string, 1001)
	for i := range many {
		many[i] = fmt.Sprintf(`"kagent/a%d"`, i)
	}
	cases := map[string]string{
		"empty file":       ``,
		"not json":         `container`,
		"array":            `[]`,
		"no container key": `{}`,
		"unknown key":      `{"container":[],"url":"http://evil"}`,
		"only unknown":     `{"url":"http://evil"}`,
		"case variant key": `{"Container":[]}`,
		"duplicate key":    `{"container":[],"container":[]}`,
		"null":             `{"container":null}`,
		"string":           `{"container":"kagent/a"}`,
		"number entry":     `{"container":[1]}`,
		"null entry":       `{"container":[null]}`,
		"object entry":     `{"container":[{"url":"x"}]}`,
		"trailing data":    `{"container":[]} {"container":["kagent/a"]}`,
		"trailing junk":    `{"container":[]}x`,
		"duplicates":       `{"container":["kagent/a","kagent/a"]}`,
		"too many":         `{"container":[` + strings.Join(many, ",") + `]}`,
		"too big":          `{"container":[],"x":"` + strings.Repeat("a", 256<<10) + `"}`,
		"label too long":   `{"container":["kagent/` + long + `"]}`,
	}
	for name, in := range cases {
		if _, err := ParseRoutes([]byte(in)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

var hostileEntries = []string{
	"a.evil.com", "kagent/a.evil.com", "kagent/x/../y", "kagent/..", "kagent/a@b", "kagent/a:80", "kagent/a#b",
	"kagent/a?b", "kagent/a b", "kagent/a\\b", "kagent/a%2e", "http://evil.com", "kagent/http://evil.com", "//evil.com",
	"kagent//evil", "/kagent/a", "kagent/a/", "kagent/échoé", "kagent/日本", "kagent/Echo", "KAGENT/echo", "kagent/echo.",
	"kagent/-a", "kagent/a-", "kagent/_a", "kagent/", "/a", "kagent", "", "kagent/a/b", "kagent/a\nb", "kagent/a\x00b",
	"kagent/a,kagent/b", "kagent/*", "[::1]/a", "kagent/127.0.0.1.nip.io",
}

func TestParseRoutesHostileEntries(t *testing.T) {
	for _, e := range hostileEntries {
		b, _ := json.Marshal(map[string][]string{"container": {e}})
		if _, err := ParseRoutes(b); err == nil {
			t.Errorf("hostile entry %q accepted", e)
		}
	}
}

// ---- gate behaviour -------------------------------------------------------------------------------------------

const routedRules = `{"callers":[
 {"name":"bridge","serviceAccount":{"namespace":"gw","name":"bridge"},"agents":["kagent/assistant","kagent/echo-go","kagent/a.evil.com"],"userId":{"fixed":"bridge:u1"}},
 {"name":"schedule-x","serviceAccount":{"namespace":"sch","name":"schedule-x"},"agents":["kagent/assistant"],"userId":{"exact":"schedule:x"},"methods":["SendMessage"]}
]}`

// fakeNet answers requests for the workload namespace itself and sends every other host to the real test server.
type fakeNet struct {
	mu    sync.Mutex
	got   []*http.Request
	reply func(*http.Request) (int, string)
}

func (f *fakeNet) RoundTrip(r *http.Request) (*http.Response, error) {
	if !strings.HasSuffix(r.URL.Host, ".svc.cluster.local:8080") && !strings.HasSuffix(r.URL.Host, ".svc.cluster.local:9000") {
		return http.DefaultTransport.RoundTrip(r)
	}
	if r.Body != nil {
		_, _ = io.ReadAll(r.Body)
	}
	f.mu.Lock()
	f.got = append(f.got, r)
	f.mu.Unlock()
	code, body := 200, `{"jsonrpc":"2.0","id":"1","result":{}}`
	if f.reply != nil {
		code, body = f.reply(r)
	}
	return &http.Response{StatusCode: code, Header: http.Header{"Content-Type": {"application/json"}}, Body: io.NopCloser(strings.NewReader(body)), Request: r}, nil
}

func (f *fakeNet) requests() []*http.Request {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]*http.Request(nil), f.got...)
}

func routedRig(t *testing.T, routes string, fn *fakeNet, mut func(*Options)) (*rig, string) {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "routes.json")
	if routes != "" {
		if err := os.WriteFile(path, []byte(routes), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	rl, err := rules.Parse([]byte(routedRules))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	return newRig(t, func(o *Options) {
		o.Auth = auth.New(auth.Options{Rules: rl, Audience: "aud", Keys: fakeKeys{}, Reviewer: fakeReviewer{}})
		o.Transport = fn
		o.RoutesFile, o.WorkloadNamespace, o.WorkloadPort = path, "openagentix-agents", 8080
		o.PublicURL = "https://gate.example.com"
		o.RoutesPoll = 10 * time.Millisecond
		o.Ctx = ctx
		if mut != nil {
			mut(o)
		}
	}), path
}

func TestRoutedAgentGoesToWorkloadNamespace(t *testing.T) {
	fn := &fakeNet{}
	r, _ := routedRig(t, `{"container":["kagent/echo-go"]}`, fn, nil)
	// a client's own query and forwarded headers do not pass
	resp, _ := r.do("POST", "/agents/kagent/echo-go?user_id=evil", tokBridge, map[string]string{"X-User-Id": "telegram:42", "X-Forwarded-Host": "evil", "Cookie": "c=1"}, msg("c1"))
	if resp.StatusCode != 200 {
		t.Fatalf("status %d", resp.StatusCode)
	}
	got := fn.requests()
	if len(got) != 1 {
		t.Fatalf("workload got %d requests", len(got))
	}
	g := got[0]
	if g.Method != "POST" || g.URL.Host != "echo-go.openagentix-agents.svc.cluster.local:8080" || g.URL.Path != "/" || g.URL.RawQuery != "" || g.URL.Scheme != "http" {
		t.Errorf("outgoing %s %s", g.Method, g.URL)
	}
	if g.Header.Get("X-User-Id") != "bridge:u1" || g.Header.Get("Authorization") != "" || g.Header.Get("Cookie") != "" || g.Header.Get("X-Forwarded-Host") != "" {
		t.Errorf("headers %v", g.Header)
	}
	if len(r.upstreamCalls()) != 0 {
		t.Error("kagent upstream must not be called for a listed agent")
	}
}

func TestRoutedPathMapping(t *testing.T) {
	fn := &fakeNet{}
	r, _ := routedRig(t, `{"container":["kagent/echo-go"]}`, fn, func(o *Options) { o.WorkloadPort = 9000 })
	cases := []struct{ method, path, want string }{
		{"POST", "/agents/kagent/echo-go/", "/"},
		{"POST", "/agents/kagent/echo-go/message:send", "/message:send"},
		{"POST", "/agents/kagent/echo-go/v1/message:send", "/message:send"},
		{"POST", "/agents/kagent/echo-go/message:stream", "/message:stream"},
		{"POST", "/agents/kagent/echo-go/v1/message:stream", "/message:stream"},
		{"GET", "/agents/kagent/echo-go/.well-known/agent-card.json", "/.well-known/agent-card.json"},
		{"GET", "/agents/kagent/echo-go/.well-known/agent.json", "/.well-known/agent-card.json"},
	}
	for _, c := range cases {
		body := ""
		if c.method == "POST" {
			body = msg("c1")
			if strings.Contains(c.path, "message:") {
				body = `{"message":{"contextId":"c1"}}`
			}
		}
		r.do(c.method, c.path, tokBridge, nil, body)
		got := fn.requests()
		if len(got) == 0 {
			t.Fatalf("%s %s: nothing reached the workload", c.method, c.path)
		}
		g := got[len(got)-1]
		if g.Method != c.method || g.URL.Path != c.want || g.URL.Host != "echo-go.openagentix-agents.svc.cluster.local:9000" {
			t.Errorf("%s %s -> %s %s %s, want path %s", c.method, c.path, g.Method, g.URL.Host, g.URL.Path, c.want)
		}
	}
}

func TestUnlistedAgentUnchanged(t *testing.T) {
	fn := &fakeNet{}
	r, _ := routedRig(t, `{"container":["kagent/echo-go"]}`, fn, nil)
	r.do("POST", "/agents/kagent/assistant", tokBridge, nil, msg("c1"))
	r.do("POST", "/agents/kagent/assistant/v1/message:send", tokBridge, nil, `{"message":{"contextId":"c1"}}`)
	if len(fn.requests()) != 0 {
		t.Fatal("unlisted agent reached the workload namespace")
	}
	c := r.upstreamCalls()
	if len(c) != 2 || c[0].URL != "/agents/kagent/assistant" || c[1].URL != "/agents/kagent/assistant/v1/message:send" {
		t.Fatalf("%v", c)
	}
}

func TestRoutedCallerRulesStillApply(t *testing.T) {
	fn := &fakeNet{}
	r, _ := routedRig(t, `{"container":["kagent/echo-go"]}`, fn, nil)
	resp, _ := r.do("POST", "/agents/kagent/echo-go", tokSchedule, nil, msg("c1")) // schedule-x may only call assistant
	if resp.StatusCode != 403 {
		t.Fatalf("status %d", resp.StatusCode)
	}
	resp, _ = r.do("POST", "/agents/kagent/echo-go", "", nil, msg("c1"))
	if resp.StatusCode != 401 {
		t.Fatalf("no token: %d", resp.StatusCode)
	}
	if len(fn.requests()) != 0 || len(r.upstreamCalls()) != 0 {
		t.Fatal("a refused call reached an upstream")
	}
	// the user id the rule resolves is what the foreign agent gets
	r.do("POST", "/agents/kagent/echo-go", tokBridge, map[string]string{"X-User-Id": "telegram:7"}, msg("c1"))
	if g := fn.requests(); len(g) != 1 || g[0].Header.Get("X-User-Id") != "bridge:u1" {
		t.Fatalf("X-User-Id not injected: %v", g)
	}
}

func TestFailClosedAtStart(t *testing.T) {
	for name, content := range map[string]string{"missing": "", "malformed": `{"container":["kagent/echo-go"],"url":"http://evil"}`} {
		fn := &fakeNet{}
		r, _ := routedRig(t, content, fn, nil)
		r.do("POST", "/agents/kagent/echo-go", tokBridge, nil, msg("c1"))
		if len(fn.requests()) != 0 {
			t.Errorf("%s: routed with an unusable list", name)
		}
		if c := r.upstreamCalls(); len(c) != 1 || c[0].URL != "/agents/kagent/echo-go" {
			t.Errorf("%s: should go to the kagent upstream like an unlisted agent: %v", name, c)
		}
	}
}

func waitFor(t *testing.T, what string, ok func() bool) {
	t.Helper()
	for i := 0; i < 300; i++ {
		if ok() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out: %s", what)
}

func TestReloadAddsAndKeepsLastGood(t *testing.T) {
	fn := &fakeNet{}
	logs := &syncBuf{}
	r, path := routedRig(t, `{"container":[]}`, fn, func(o *Options) { o.Log = slog.New(slog.NewTextHandler(logs, nil)) })
	call := func() { r.do("POST", "/agents/kagent/echo-go", tokBridge, nil, msg("c1")) }
	call()
	if len(fn.requests()) != 0 {
		t.Fatal("routed before it was listed")
	}
	write := func(s string) {
		tmp := path + ".tmp"
		_ = os.WriteFile(tmp, []byte(s), 0o600)
		_ = os.Rename(tmp, path)
	}
	write(`{"container":["kagent/echo-go"]}`)
	waitFor(t, "route added", func() bool { call(); return len(fn.requests()) > 0 })
	// malformed update: last good set stays, one log line, no content in it
	write(`{"container":["kagent/echo-go","kagent/SECRET-evil.com"],"x":1}`)
	waitFor(t, "problem logged", func() bool { return strings.Contains(logs.String(), "routes") })
	n := len(fn.requests())
	call()
	if len(fn.requests()) != n+1 {
		t.Error("last good set was not kept after a malformed update")
	}
	if strings.Contains(logs.String(), "SECRET") {
		t.Error("file content in log")
	}
	// removal in a valid file stops the route
	write(`{"container":[]}`)
	waitFor(t, "route removed", func() bool {
		n := len(fn.requests())
		call()
		return len(fn.requests()) == n
	})
}

func TestHostileNamesNeverChangeHost(t *testing.T) {
	good := []string{"kagent/echo-go", "kagent/a", "team-1/x2", "a/b"}
	b, _ := json.Marshal(map[string][]string{"container": good})
	fn := &fakeNet{}
	r, _ := routedRig(t, string(b), fn, nil)
	// the caller may call only kagent/assistant, kagent/echo-go and kagent/a.evil.com: the other listed names are refused
	for _, g := range good {
		ns, name, _ := strings.Cut(g, "/")
		r.do("POST", "/agents/"+ns+"/"+name, tokBridge, nil, msg("c1"))
	}
	for _, p := range []string{"/agents/kagent/a.evil.com", "/agents/kagent/echo-go.evil.com", "/agents/kagent/ECHO-GO", "/agents/kagent/echo-go./", "/agents/kagent/x%2f..%2fy", "/agents/kagent/a@b"} {
		r.do("POST", p, tokBridge, nil, msg("c1"))
	}
	reqs := fn.requests()
	if len(reqs) != 1 { // only kagent/echo-go is both listed and allowed for the caller
		t.Fatalf("workload requests: %d", len(reqs))
	}
	for _, q := range reqs {
		if q.URL.Host != "echo-go.openagentix-agents.svc.cluster.local:8080" {
			t.Errorf("host %q is not the template", q.URL.Host)
		}
	}
}

// ---- agent card ------------------------------------------------------------------------------------------------

const upstreamCard = `{"name":"Echo","description":"d","version":"2","skills":[{"id":"s","name":"S"}],"capabilities":{"streaming":true},
"supportedInterfaces":[{"url":"http://echo-go.openagentix-agents.svc.cluster.local:8080","protocolBinding":"JSONRPC","protocolVersion":"0.3"}],
"securitySchemes":{"k":{"apiKeySecurityScheme":{"name":"X"}}},"securityRequirements":[{"schemes":{"k":{}}}],"security":[{"k":[]}],
"url":"http://echo-go:8080","preferredTransport":"JSONRPC","additionalInterfaces":[{"url":"http://x","transport":"GRPC"}],"defaultInputModes":["text/plain"]}`

func TestCardRewrite(t *testing.T) {
	fn := &fakeNet{reply: func(*http.Request) (int, string) { return 200, upstreamCard }}
	r, _ := routedRig(t, `{"container":["kagent/echo-go"]}`, fn, nil)
	resp, body := r.do("GET", "/agents/kagent/echo-go/.well-known/agent-card.json", tokBridge, nil, "")
	if resp.StatusCode != 200 {
		t.Fatalf("%d %s", resp.StatusCode, body)
	}
	var card map[string]any
	if err := json.Unmarshal([]byte(body), &card); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"securitySchemes", "securityRequirements", "security", "url", "preferredTransport", "additionalInterfaces"} {
		if _, ok := card[k]; ok {
			t.Errorf("%s not dropped", k)
		}
	}
	if card["name"] != "Echo" || card["version"] != "2" || card["description"] != "d" || card["skills"] == nil || card["capabilities"] == nil || card["defaultInputModes"] == nil {
		t.Errorf("unrelated fields lost: %v", card)
	}
	ifs, _ := card["supportedInterfaces"].([]any)
	if len(ifs) != 2 {
		t.Fatalf("interfaces: %v", card["supportedInterfaces"])
	}
	bindings := map[string]bool{}
	for _, i := range ifs {
		m := i.(map[string]any)
		if m["url"] != "https://gate.example.com/agents/kagent/echo-go" || m["protocolVersion"] != "1.0" {
			t.Errorf("interface %v", m)
		}
		bindings[m["protocolBinding"].(string)] = true
	}
	if !bindings["JSONRPC"] || !bindings["HTTP+JSON"] {
		t.Errorf("bindings %v", bindings)
	}
	if strings.Contains(body, "svc.cluster.local") {
		t.Error("pod address leaks in the card")
	}
}

func TestCardRefused(t *testing.T) {
	cases := map[string]string{
		"oversize":   `{"name":"` + strings.Repeat("a", 64<<10) + `"}`,
		"not json":   `<html>`,
		"array":      `[1]`,
		"string":     `"x"`,
		"null":       `null`,
		"trailing":   `{"name":"a"} {}`,
		"empty body": ``,
	}
	for name, up := range cases {
		fn := &fakeNet{reply: func(*http.Request) (int, string) { return 200, up }}
		r, _ := routedRig(t, `{"container":["kagent/echo-go"]}`, fn, nil)
		resp, body := r.do("GET", "/agents/kagent/echo-go/.well-known/agent-card.json", tokBridge, nil, "")
		if resp.StatusCode != 502 || !strings.Contains(body, "agent card") || strings.Contains(body, "svc.cluster.local") {
			t.Errorf("%s: %d %q", name, resp.StatusCode, body)
		}
	}
}

func TestCardNon200PassesThroughAndUnlistedCardUntouched(t *testing.T) {
	fn := &fakeNet{reply: func(*http.Request) (int, string) { return 404, `{"error":"nope"}` }}
	r, _ := routedRig(t, `{"container":["kagent/echo-go"]}`, fn, nil)
	resp, body := r.do("GET", "/agents/kagent/echo-go/.well-known/agent-card.json", tokBridge, nil, "")
	if resp.StatusCode != 404 || !strings.Contains(body, "nope") {
		t.Errorf("%d %s", resp.StatusCode, body)
	}
	r.handle = func(w http.ResponseWriter, _ *http.Request) { _, _ = io.WriteString(w, upstreamCard) }
	_, body = r.do("GET", "/agents/kagent/assistant/.well-known/agent-card.json", tokBridge, nil, "")
	if !bytes.Equal([]byte(body), []byte(upstreamCard)) {
		t.Error("an unlisted agent's card must pass through byte for byte")
	}
}
