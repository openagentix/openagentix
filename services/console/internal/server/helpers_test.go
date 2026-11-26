package server_test

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"testing/fstest"
	"time"

	"github.com/openagentix/openagentix/services/console/internal/backend"
	"github.com/openagentix/openagentix/services/console/internal/builtin"
	"github.com/openagentix/openagentix/services/console/internal/fake"
	"github.com/openagentix/openagentix/services/console/internal/kube"
	"github.com/openagentix/openagentix/services/console/internal/platform"
	"github.com/openagentix/openagentix/services/console/internal/server"
)

const (
	token   = "console-token-CANARY-4f9a"
	saToken = "sa-token-for-the-cluster"
)

// seen is one request the fake Kubernetes API received.
type seen struct {
	Method, Path, Query string
	Header              http.Header
}

// fakeAPI is a small stateful Kubernetes API: AgentDefinitions with resourceVersion and dryRun, and the kagent kinds.
type fakeAPI struct {
	mu   sync.Mutex
	defs map[string]map[string]any
	rv   int
	reqs []seen
	srv  *httptest.Server
	slow chan struct{}
	// override, when set, may answer a request itself (return true) before the stateful fake looks at it.
	override func(w http.ResponseWriter, r *http.Request) bool
}

func newFakeAPI(t *testing.T) *fakeAPI {
	f := &fakeAPI{defs: map[string]map[string]any{}}
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeAPI) next() string { f.rv++; return strconv.Itoa(f.rv) }

func (f *fakeAPI) seed(name string, spec map[string]any, status map[string]any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.defs[name] = map[string]any{"apiVersion": "openagentix.io/v1alpha1", "kind": "AgentDefinition",
		"metadata": map[string]any{"name": name, "namespace": "kagent", "resourceVersion": f.next(), "generation": 1, "creationTimestamp": "2026-11-25T10:00:00Z",
			"finalizers": []any{"openagentix.io/gateway-key"}}, "spec": spec, "status": status}
}

func (f *fakeAPI) requests() []seen {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]seen(nil), f.reqs...)
}

func status(w http.ResponseWriter, code int, reason, msg string, causes ...map[string]string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	d := map[string]any{}
	if len(causes) > 0 {
		d["causes"] = causes
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"kind": "Status", "reason": reason, "message": msg, "details": d})
}

func send(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func (f *fakeAPI) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	f.reqs = append(f.reqs, seen{r.Method, r.URL.Path, r.URL.RawQuery, r.Header.Clone()})
	f.mu.Unlock()
	if f.override != nil && f.override(w, r) {
		return
	}
	if f.slow != nil {
		select {
		case <-f.slow:
		case <-r.Context().Done():
			return
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	const defs = "/apis/openagentix.io/v1alpha1/namespaces/kagent/agentdefinitions"
	const kag = "/apis/api.kagent.dev/v1alpha3/namespaces/kagent/"
	dry := r.URL.Query().Get("dryRun") == "All"
	switch {
	case r.URL.Path == defs && r.Method == http.MethodGet:
		names := []string{}
		for n := range f.defs {
			names = append(names, n)
		}
		sort.Strings(names)
		start, end := 0, len(names)
		if c := r.URL.Query().Get("continue"); c != "" {
			start, _ = strconv.Atoi(c)
		}
		meta := map[string]any{}
		if l, _ := strconv.Atoi(r.URL.Query().Get("limit")); l > 0 && start+l < end {
			end = start + l
			meta["continue"] = strconv.Itoa(end)
		}
		items := []any{}
		for _, n := range names[min(start, len(names)):end] {
			items = append(items, f.defs[n])
		}
		send(w, 200, map[string]any{"items": items, "metadata": meta})
	case r.URL.Path == defs && r.Method == http.MethodPost:
		var o map[string]any
		_ = json.NewDecoder(r.Body).Decode(&o)
		name := o["metadata"].(map[string]any)["name"].(string)
		if _, ok := f.defs[name]; ok {
			status(w, 409, "AlreadyExists", "exists")
			return
		}
		sp, _ := o["spec"].(map[string]any)
		rt, _ := sp["runtime"].(map[string]any)
		// the CRD's own rule: a container agent is configured in its image and needs no instructions
		if rt["type"] != "container" && (sp["instructions"] == "" || sp["instructions"] == nil) {
			status(w, 422, "Invalid", "invalid", map[string]string{"field": "spec.instructions", "message": "Required value", "reason": "FieldValueRequired"})
			return
		}
		o["metadata"].(map[string]any)["resourceVersion"] = f.next()
		o["metadata"].(map[string]any)["creationTimestamp"] = "2026-11-25T12:00:00Z"
		o["status"] = map[string]any{}
		if !dry {
			f.defs[name] = o
		}
		send(w, 201, o)
	case strings.HasPrefix(r.URL.Path, defs+"/"):
		name := strings.TrimPrefix(r.URL.Path, defs+"/")
		cur, ok := f.defs[name]
		if !ok {
			status(w, 404, "NotFound", "not found")
			return
		}
		switch r.Method {
		case http.MethodGet:
			send(w, 200, cur)
		case http.MethodPut:
			var o map[string]any
			_ = json.NewDecoder(r.Body).Decode(&o)
			if o["metadata"].(map[string]any)["resourceVersion"] != cur["metadata"].(map[string]any)["resourceVersion"] {
				status(w, 409, "Conflict", "the object has been modified")
				return
			}
			if sp, _ := o["spec"].(map[string]any); sp["model"] == "" || sp["model"] == nil {
				status(w, 422, "Invalid", "invalid", map[string]string{"field": "spec.model", "message": "Required value", "reason": "FieldValueRequired"})
				return
			}
			o["metadata"].(map[string]any)["resourceVersion"] = f.next()
			o["status"] = cur["status"]
			if !dry {
				f.defs[name] = o
			}
			send(w, 200, o)
		case http.MethodDelete:
			delete(f.defs, name)
			send(w, 200, map[string]any{"kind": "Status", "status": "Success"})
		}
	case r.URL.Path == kag+"agents":
		items := []any{
			map[string]any{"metadata": map[string]any{"name": "assistant", "namespace": "kagent", "creationTimestamp": "2026-11-23T10:00:00Z"},
				"spec":   map[string]any{"template": map[string]any{"ref": map[string]any{"name": "assistant-template"}}, "harnessRef": map[string]any{"name": "assistant-harness"}},
				"status": map[string]any{"conditions": []any{map[string]any{"type": "Ready", "status": "True", "reason": "Ready", "lastTransitionTime": "2026-11-23T10:05:00Z"}}}},
		}
		if !strings.Contains(r.URL.Query().Get("labelSelector"), "!openagentix.io/agent-definition") {
			items = append(items, map[string]any{"metadata": map[string]any{"name": "researcher", "labels": map[string]any{"openagentix.io/agent-definition": "researcher"}}})
		}
		send(w, 200, map[string]any{"items": items})
	case r.URL.Path == kag+"agenttemplates":
		send(w, 200, map[string]any{"items": []any{map[string]any{"metadata": map[string]any{"name": "assistant-template"},
			"spec": map[string]any{"description": "General assistant", "systemPrompt": "Be brief.", "modelConfig": map[string]any{"name": "gateway-claude-haiku"},
				"tools":  []any{map[string]any{"mcp": map[string]any{"server": map[string]any{"name": "toolhive-vmcp"}, "tools": []any{"osv_query_vulnerability", "knowledge_kb_search", "delivery_notify_send"}}}},
				"skills": []any{map[string]any{"name": "openagentix-canary"}}}}}})
	case r.URL.Path == kag+"harnesses":
		send(w, 200, map[string]any{"items": []any{map[string]any{"metadata": map[string]any{"name": "assistant-harness"},
			"spec": map[string]any{"kagent": map[string]any{"memory": map[string]any{"ttlDays": 30}}}}}})
	case r.URL.Path == kag+"modelconfigs":
		send(w, 200, map[string]any{"items": []any{map[string]any{"metadata": map[string]any{"name": "gateway-claude-haiku"}, "spec": map[string]any{"model": "claude-haiku"}}}})
	default:
		status(w, 404, "NotFound", "no route in the fake")
	}
}

// rig is a console wired to the fake API.
type rig struct {
	api   *fakeAPI
	ts    *httptest.Server
	audit *bytes.Buffer
	logs  *bytes.Buffer
}

type rigOpt struct {
	viewer  bool
	static  func() *fstest.MapFS
	timeout int
	fake    bool
	// noContainers: the policy does not list the container runtime.
	noContainers bool
	// mod changes the server options after the rig has filled them in; kube changes the backend.
	mod  func(*server.Options)
	kube func(*backend.Kube)
}

func newRig(t *testing.T, opts ...func(*rigOpt)) *rig {
	t.Helper()
	var o rigOpt
	for _, f := range opts {
		f(&o)
	}
	r := &rig{audit: &bytes.Buffer{}, logs: &bytes.Buffer{}}
	dir := t.TempDir()
	tokPath := filepath.Join(dir, "token")
	_ = os.WriteFile(tokPath, []byte(token+"\n"), 0o600)
	saPath := filepath.Join(dir, "satoken")
	_ = os.WriteFile(saPath, []byte(saToken), 0o600)

	var be backend.Backend
	pv := fake.Platform()
	if o.noContainers {
		pv.Policy.AllowedRuntimes = nil
	}
	plat := platform.Static{Value: pv}
	if o.fake {
		be = fake.New(nil, 0)
	} else {
		r.api = newFakeAPI(t)
		kc, err := kube.New(r.api.srv.URL, saPath, "")
		if err != nil {
			t.Fatal(err)
		}
		kb := backend.NewKube(kc, "kagent", "api.kagent.dev/v1alpha3", plat)
		if o.kube != nil {
			o.kube(kb)
		}
		be = kb
	}
	var static fstest.MapFS
	if o.static != nil {
		static = *o.static()
	} else {
		static = fstest.MapFS{"index.html": {Data: []byte("<!doctype html><title>app</title>")}, "_app/immutable/a.js": {Data: []byte("1")}}
	}
	sopts := server.Options{Backend: be, Platform: plat, Authenticator: &builtin.TokenAuth{Path: tokPath},
		Authorizer: builtin.RoleAuthz{Viewer: o.viewer}, Audit: builtin.LogAudit{Log: slog.New(slog.NewJSONHandler(r.audit, nil))},
		Static: static, Log: slog.New(slog.NewJSONHandler(r.logs, nil)), Namespace: "kagent", Version: "test",
		// the throttles are tested on their own; the many wrong-token cases of the other tests must not trip them
		AuthFailLimit: -1, ValidatePerMinute: -1}
	if o.mod != nil {
		o.mod(&sopts)
	}
	h := server.New(sopts)
	r.ts = httptest.NewServer(h)
	t.Cleanup(r.ts.Close)
	return r
}

// do sends a request with the console token unless hdr overrides it.
func (r *rig) do(t *testing.T, method, path string, body any, hdr ...string) (*http.Response, []byte) {
	t.Helper()
	var rd io.Reader
	if s, ok := body.(string); ok {
		rd = strings.NewReader(s)
	} else if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, r.ts.URL+path, rd)
	req.Header.Set("Authorization", "Bearer "+token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	for i := 0; i+1 < len(hdr); i += 2 {
		if hdr[i] == "Host" {
			req.Host = hdr[i+1]
		} else if hdr[i+1] == "" {
			req.Header.Del(hdr[i])
		} else {
			req.Header.Set(hdr[i], hdr[i+1])
		}
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	return resp, b
}

func decodeInto[T any](t *testing.T, b []byte) T {
	t.Helper()
	var v T
	if err := json.Unmarshal(b, &v); err != nil {
		t.Fatalf("not JSON: %v\n%s", err, b)
	}
	return v
}

func errCode(t *testing.T, b []byte) string {
	t.Helper()
	return decodeInto[struct {
		Error struct{ Code, Message string }
	}](t, b).Error.Code
}

func spec(model string) map[string]any {
	return map[string]any{"model": model, "instructions": "Answer plainly.", "toolProfile": "lookup", "tools": []string{"osv_query_vulnerability"}}
}

func newRigTimeout(t *testing.T, d time.Duration) *rig {
	t.Helper()
	r := &rig{audit: &bytes.Buffer{}, logs: &bytes.Buffer{}, api: newFakeAPI(t)}
	dir := t.TempDir()
	tokPath := filepath.Join(dir, "token")
	_ = os.WriteFile(tokPath, []byte(token), 0o600)
	saPath := filepath.Join(dir, "sa")
	_ = os.WriteFile(saPath, []byte(saToken), 0o600)
	kc, _ := kube.New(r.api.srv.URL, saPath, "")
	plat := platform.Static{Value: fake.Platform()}
	h := server.New(server.Options{Backend: backend.NewKube(kc, "kagent", "api.kagent.dev/v1alpha3", plat), Platform: plat, Authenticator: &builtin.TokenAuth{Path: tokPath},
		Authorizer: builtin.RoleAuthz{}, Static: fstest.MapFS{}, RequestTimeout: d})
	r.ts = httptest.NewServer(h)
	t.Cleanup(r.ts.Close)
	return r
}

// decodeBody reads a request body for an override and puts it back for the fake that follows.
func decodeBody(r *http.Request, v any) error {
	b, _ := io.ReadAll(r.Body)
	r.Body = io.NopCloser(bytes.NewReader(b))
	return json.Unmarshal(b, v)
}
