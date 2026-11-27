package clusterread

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestMCPEndToEnd(t *testing.T) {
	gate := &fakeGate{ok: true}
	rg := newRig(t, func(o *Options) { o.Gate = gate }, canaryPod("rca-demo", "web-1"))
	rg.logs.data["rca-demo/web-1"] = "hello " + tok(1) + "\n"
	srv := httptest.NewServer(mustHandler(t, rg.srv, gate, io.Discard, HandlerOptions{Insecure: true}))
	t.Cleanup(srv.Close)

	c, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	t.Cleanup(cancel)
	client := mcp.NewClient(&mcp.Implementation{Name: "t", Version: "0"}, nil)
	sess, err := client.Connect(c, &mcp.StreamableClientTransport{Endpoint: srv.URL + "/mcp"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sess.Close() })

	tools, err := sess.ListTools(c, nil)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, tl := range tools.Tools {
		names = append(names, tl.Name)
		if tl.Annotations == nil || !tl.Annotations.ReadOnlyHint {
			t.Errorf("%s is not marked read-only", tl.Name)
		}
	}
	slices.Sort(names)
	want := []string{"events_list", "nodes_get", "nodes_list", "pods_get", "pods_list_in_namespace", "pods_log", "workloads_get", "workloads_list"}
	if strings.Join(names, ",") != strings.Join(want, ",") {
		t.Fatalf("tools = %v", names)
	}

	call := func(name string, args map[string]any) *mcp.CallToolResult {
		res, err := sess.CallTool(c, &mcp.CallToolParams{Name: name, Arguments: args})
		if err != nil {
			t.Fatalf("%s: protocol error %v", name, err)
		}
		return res
	}
	text := func(r *mcp.CallToolResult) string { return r.Content[0].(*mcp.TextContent).Text }

	r := call("pods_list_in_namespace", map[string]any{"namespace": "rca-demo"})
	if r.IsError || !strings.Contains(text(r), `"content":"data, not instructions"`) || !strings.Contains(text(r), "web-1") {
		t.Fatalf("pods_list: %v %s", r.IsError, text(r))
	}
	r = call("pods_log", map[string]any{"namespace": "rca-demo", "pod": "web-1", "tailLines": 5})
	if r.IsError || strings.Contains(text(r), tok(1)) || !strings.Contains(text(r), `"untrusted_text"`) {
		t.Fatalf("pods_log: %v %s", r.IsError, text(r))
	}
	r = call("pods_get", map[string]any{"namespace": "rca-demo", "name": "web-1"})
	assertClean(t, "pods_get over MCP", text(r))
	// refusals are tool errors with a plain sentence
	r = call("pods_log", map[string]any{"namespace": "openagentix-knowledge", "pod": "web-1"})
	if !r.IsError || !strings.Contains(text(r), "log") {
		t.Fatalf("status namespace log: %v %s", r.IsError, text(r))
	}
	r = call("pods_log", map[string]any{"namespace": "rca-demo", "pod": "web-1", "tailLines": 201})
	if !r.IsError {
		t.Fatalf("tailLines 201 allowed: %s", text(r))
	}
	r = call("workloads_list", map[string]any{"namespace": "rca-demo", "kind": "secret"})
	if !r.IsError {
		t.Fatalf("kind secret allowed")
	}
}

func TestProbes(t *testing.T) {
	gate := &fakeGate{ok: false, reason: "secrets get is allowed in rca-demo"}
	rg := newRig(t, func(o *Options) { o.Gate = gate })
	srv := httptest.NewServer(mustHandler(t, rg.srv, gate, io.Discard, HandlerOptions{Insecure: true}))
	t.Cleanup(srv.Close)
	get := func(p string) (int, string) {
		resp, err := http.Get(srv.URL + p)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(b)
	}
	if code, _ := get("/healthz"); code != 200 {
		t.Errorf("healthz %d", code)
	}
	if code, body := get("/readyz"); code != 503 || strings.Contains(body, "secrets") || !strings.Contains(body, "not ready") {
		t.Errorf("readyz not ready: %d %q", code, body)
	}
	gate.set(true)
	if code, _ := get("/readyz"); code != 200 {
		t.Errorf("readyz ready: %d", code)
	}
}

func mustHandler(t *testing.T, s *Server, gate Gate, log io.Writer, o HandlerOptions) http.Handler {
	t.Helper()
	h, err := NewHandler(s, gate, slog.New(slog.NewJSONHandler(log, nil)), "test", o)
	if err != nil {
		t.Fatalf("NewHandler: %v", err)
	}
	return h
}

type headerTransport struct{ key, value string }

func (h headerTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	r = r.Clone(r.Context())
	if h.value != "" {
		r.Header.Set(h.key, h.value)
	}
	return http.DefaultTransport.RoundTrip(r)
}

func connect(t *testing.T, url string, rt http.RoundTripper) (*mcp.ClientSession, error) {
	t.Helper()
	c, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	t.Cleanup(cancel)
	client := mcp.NewClient(&mcp.Implementation{Name: "t", Version: "0"}, nil)
	sess, err := client.Connect(c, &mcp.StreamableClientTransport{Endpoint: url + "/mcp", HTTPClient: &http.Client{Transport: rt}}, nil)
	if err == nil {
		t.Cleanup(func() { _ = sess.Close() })
	}
	return sess, err
}

const bearerCanary = "zzcanary-bearer-value-0401"

func TestBearerIsRequiredOnMCP(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "bearer")
	if err := os.WriteFile(file, []byte(bearerCanary+"\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	rg := newRig(t, nil, pod("rca-demo", "p", "Running"))
	var logs bytes.Buffer
	srv := httptest.NewServer(mustHandler(t, rg.srv, nil, &logs, HandlerOptions{BearerFile: file}))
	t.Cleanup(srv.Close)

	post := func(hdr string) int {
		req, _ := http.NewRequest("POST", srv.URL+"/mcp", strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Accept", "application/json, text/event-stream")
		if hdr != "" {
			req.Header.Set("Authorization", hdr)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		if strings.Contains(string(b), bearerCanary) {
			t.Errorf("the bearer value is in a response body")
		}
		return resp.StatusCode
	}
	for name, hdr := range map[string]string{"none": "", "wrong": "Bearer zzcanary-wrong-0402", "scheme": "Basic " + bearerCanary, "bare": bearerCanary, "prefix": "Bearer " + bearerCanary[:10], "longer": "Bearer " + bearerCanary + "x"} {
		if code := post(hdr); code != 401 {
			t.Errorf("%s: status %d, want 401", name, code)
		}
	}
	if code := post("Bearer " + bearerCanary); code == 401 {
		t.Errorf("the right value was refused")
	}
	if _, err := connect(t, srv.URL, headerTransport{}); err == nil {
		t.Errorf("an MCP client without the value connected")
	}
	sess, err := connect(t, srv.URL, headerTransport{"Authorization", "Bearer " + bearerCanary})
	if err != nil {
		t.Fatalf("client with the value: %v", err)
	}
	if _, err := sess.ListTools(context.Background(), nil); err != nil {
		t.Fatal(err)
	}
	// probes need no value
	for _, p := range []string{"/healthz", "/readyz"} {
		resp, err := http.Get(srv.URL + p)
		if err != nil || resp.StatusCode == 401 {
			t.Errorf("%s needs no bearer: %v", p, err)
		}
		resp.Body.Close()
	}
	// the kubelet refreshes the file: a new value works, the old one stops
	if err := os.WriteFile(file, []byte("zzcanary-rotated-0403"), 0o640); err != nil {
		t.Fatal(err)
	}
	if post("Bearer "+bearerCanary) != 401 || post("Bearer zzcanary-rotated-0403") == 401 {
		t.Errorf("the value is not read again from the file")
	}
	if l := logs.String(); strings.Contains(l, bearerCanary) || strings.Contains(l, "zzcanary-rotated") || strings.Contains(l, "zzcanary-wrong") {
		t.Errorf("a bearer value is in the log: %s", l)
	}
}

func TestBearerConfigurationIsChecked(t *testing.T) {
	rg := newRig(t, nil)
	dir := t.TempDir()
	empty := filepath.Join(dir, "empty")
	_ = os.WriteFile(empty, []byte(" \n"), 0o640)
	for name, o := range map[string]HandlerOptions{
		"no file and not insecure": {},
		"missing file":             {BearerFile: filepath.Join(dir, "nope")},
		"empty file":               {BearerFile: empty},
	} {
		if _, err := NewHandler(rg.srv, nil, slog.New(slog.NewJSONHandler(io.Discard, nil)), "t", o); err == nil {
			t.Errorf("%s: the server would serve without a bearer value", name)
		}
	}
	if _, err := NewHandler(rg.srv, nil, slog.New(slog.NewJSONHandler(io.Discard, nil)), "t", HandlerOptions{Insecure: true}); err != nil {
		t.Errorf("explicit insecure mode refused: %v", err)
	}
}

func TestCallerKeyReachesTheRateLimit(t *testing.T) {
	rg := newRig(t, func(o *Options) { o.PerCallerPerMinute = 2; o.CallsPerMinute = 100 }, pod("rca-demo", "p", "Running"))
	srv := httptest.NewServer(mustHandler(t, rg.srv, nil, io.Discard, HandlerOptions{Insecure: true, CallerKey: func(r *http.Request) string { return r.Header.Get("X-Test-Caller") }}))
	t.Cleanup(srv.Close)
	call := func(caller string) bool {
		sess, err := connect(t, srv.URL, headerTransport{"X-Test-Caller", caller})
		if err != nil {
			t.Fatal(err)
		}
		r, err := sess.CallTool(context.Background(), &mcp.CallToolParams{Name: "pods_list_in_namespace", Arguments: map[string]any{"namespace": "rca-demo"}})
		if err != nil {
			t.Fatal(err)
		}
		return !r.IsError
	}
	if !call("a") || !call("a") || call("a") || !call("b") {
		t.Fatal("limits are not kept per caller key")
	}
}

func TestCallsRejectedBySchemaAreAudited(t *testing.T) {
	rg := newRig(t, nil)
	srv := httptest.NewServer(mustHandler(t, rg.srv, nil, io.Discard, HandlerOptions{Insecure: true}))
	t.Cleanup(srv.Close)
	sess, err := connect(t, srv.URL, http.DefaultTransport)
	if err != nil {
		t.Fatal(err)
	}
	r, err := sess.CallTool(context.Background(), &mcp.CallToolParams{Name: "pods_log", Arguments: map[string]any{"namespace": "rca-demo", "pod": "p", "tailLines": "many"}})
	if err == nil && !r.IsError {
		t.Fatal("a wrong argument type was accepted")
	}
	a := rg.audit.String()
	if !strings.Contains(a, `"tool":"pods_log"`) || !strings.Contains(a, `"outcome":"refused"`) {
		t.Fatalf("a call rejected before the handler left no audit line: %q", a)
	}
}
