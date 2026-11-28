package mcpserver

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/openagentix/openagentix/services/kb/internal/access"
	"github.com/openagentix/openagentix/services/kb/internal/chunk"
	"github.com/openagentix/openagentix/services/kb/internal/embed"
	"github.com/openagentix/openagentix/services/kb/internal/kb"
	"github.com/openagentix/openagentix/services/kb/internal/store"
	"github.com/openagentix/openagentix/services/kb/internal/store/memory"
)

const (
	tokBank  = "Bearer canary-bank-7f3a91c2"
	tokEquip = "Bearer canary-equip-55d0e8b4"
	tokEmpty = "Bearer canary-empty-0b6e2f19"
	// secretText is document content that must never reach a log line.
	secretText = "zebracrossing-document-body"
)

type headerRT struct{ authorization string }

func (r headerRT) RoundTrip(req *http.Request) (*http.Response, error) {
	req = req.Clone(req.Context())
	if r.authorization != "" {
		req.Header.Set("Authorization", r.authorization)
	}
	return http.DefaultTransport.RoundTrip(req)
}

type accessEnv struct {
	svc   *kb.Service
	srv   *httptest.Server
	logs  *bytes.Buffer
	dir   string
	state bool
}

// newAccessEnv serves a knowledge base with two collections, "bank-coll" and
// "equip-coll", each holding a document, a graph entity named Orion and a
// shared document id, in the given mode.
func newAccessEnv(t *testing.T, mode string, stateless bool) *accessEnv {
	t.Helper()
	logs := &bytes.Buffer{}
	log := slog.New(slog.NewJSONHandler(logs, nil))
	st := memory.New(0)
	svc := &kb.Service{Store: st, Embedder: embed.None{}, Chunk: chunk.Options{MaxChars: 400}, DocMaxChars: 5000, Log: log,
		Graph: &kb.GraphOptions{WindowChars: 2400, PromptVersion: "v1", MaxHops: 3, Schemas: true}}
	ctx := context.Background()
	for _, c := range []string{"bank-coll", "equip-coll"} {
		if _, err := svc.Put(ctx, c, "shared-id", kb.DocInput{Title: "Doc " + c, Text: "pelican harbour " + secretText + " " + c}); err != nil {
			t.Fatal(err)
		}
		if _, err := svc.Put(ctx, c, "only-"+c, kb.DocInput{Title: "Only " + c, Text: "pelican pelican pelican " + secretText}); err != nil {
			t.Fatal(err)
		}
		fs := store.FactSet{SourceURI: "https://example.test/c",
			Entities:  []store.FactEntity{{Name: "Orion", Type: "service"}, {Name: "Basalt", Type: "team"}},
			Relations: []store.FactRelation{{Source: "Basalt", Predicate: "owns", Target: "Orion", Note: "Basalt owns Orion"}}}
		if _, err := svc.PutFactSet(ctx, c, "org", fs); err != nil {
			t.Fatal(err)
		}
	}
	dir := t.TempDir()
	write := func(name, v string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(v), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write("bank", tokBank)
	write("equip", tokEquip)
	write("empty", tokEmpty)
	cfg := filepath.Join(t.TempDir(), "access.json")
	body := `{"mode":"` + mode + `","callers":[{"name":"bank","collections":["bank-coll"]},{"name":"equip","collections":["equip-coll"]},{"name":"empty","collections":[]}]}`
	if err := os.WriteFile(cfg, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	az, err := access.Load(cfg, dir, log)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.Handle("/mcp", New(svc, log, Options{Stateless: stateless, Version: "test", Timeout: 5 * time.Second, Access: az}))
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return &accessEnv{svc: svc, srv: srv, logs: logs, dir: dir, state: !stateless}
}

func (e *accessEnv) connect(t *testing.T, authorization string) *mcp.ClientSession {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	client := mcp.NewClient(&mcp.Implementation{Name: "t", Version: "0"}, nil)
	s, err := client.Connect(ctx, &mcp.StreamableClientTransport{Endpoint: e.srv.URL + "/mcp", HTTPClient: &http.Client{Transport: headerRT{authorization}}}, nil)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func call(t *testing.T, s *mcp.ClientSession, tool string, args map[string]any) (string, bool) {
	t.Helper()
	res, err := s.CallTool(context.Background(), &mcp.CallToolParams{Name: tool, Arguments: args})
	if err != nil {
		t.Fatalf("%s: %v", tool, err)
	}
	var sb strings.Builder
	for _, c := range res.Content {
		sb.WriteString(c.(*mcp.TextContent).Text)
	}
	return sb.String(), res.IsError
}

const initBody = `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"raw","version":"0"}}}`

func rawPost(t *testing.T, url, authorization, session, body string) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, url+"/mcp", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")
	if authorization != "" {
		req.Header.Set("Authorization", authorization)
	}
	if session != "" {
		req.Header.Set("Mcp-Session-Id", session)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = resp.Body.Close() })
	return resp
}

func TestEnforceRefusesUnknownValueBeforeMCP(t *testing.T) {
	e := newAccessEnv(t, "enforce", true)
	for name, tok := range map[string]string{"none": "", "wrong": "Bearer nope", "no prefix": strings.TrimPrefix(tokBank, "Bearer ")} {
		resp := rawPost(t, e.srv.URL, tok, "", initBody)
		b, _ := io.ReadAll(resp.Body)
		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("%s: status %d, want 401 (initialize included)", name, resp.StatusCode)
		}
		if strings.Contains(string(b), "bank-coll") || strings.Contains(string(b), "canary") {
			t.Errorf("%s: body leaks: %s", name, b)
		}
	}
	if resp := rawPost(t, e.srv.URL, tokBank, "", initBody); resp.StatusCode != http.StatusOK {
		t.Fatalf("known value: status %d", resp.StatusCode)
	}
}

func TestEnforceFiltersEveryTool(t *testing.T) {
	for _, stateless := range []bool{true, false} {
		e := newAccessEnv(t, "enforce", stateless)
		s := e.connect(t, tokBank)

		// kb_list_collections lists only the caller's collections.
		txt, _ := call(t, s, "kb_list_collections", nil)
		if !strings.Contains(txt, "bank-coll") || strings.Contains(txt, "equip-coll") {
			t.Fatalf("list: %q", txt)
		}
		// kb_search without a collection finds only the caller's documents, and top_k is filled from them.
		txt, _ = call(t, s, "kb_search", map[string]any{"query": "pelican", "top_k": 20})
		if !strings.Contains(txt, "collection=bank-coll") || strings.Contains(txt, "equip-coll") {
			t.Fatalf("search: %q", txt)
		}
		// Outside the list answers byte for byte like a missing collection, for every tool.
		for _, c := range []struct {
			tool string
			args func(coll string) map[string]any
		}{
			{"kb_search", func(c string) map[string]any { return map[string]any{"query": "pelican", "collection": c} }},
			{"kb_get_document", func(c string) map[string]any {
				return map[string]any{"document_id": "only-equip-coll", "collection": c}
			}},
			{"kb_graph_search", func(c string) map[string]any { return map[string]any{"query": "who owns Orion", "collection": c} }},
			{"kb_graph_entity", func(c string) map[string]any { return map[string]any{"name": "Orion", "collection": c} }},
			{"kb_graph_paths", func(c string) map[string]any { return map[string]any{"from": "Basalt", "to": "Orion", "collection": c} }},
		} {
			outside, outErr := call(t, s, c.tool, c.args("equip-coll"))
			missing, missErr := call(t, s, c.tool, c.args("absent-coll"))
			if outside != missing || outErr != missErr {
				t.Errorf("stateless=%v %s: outside %q (err %v) differs from missing %q (err %v)", stateless, c.tool, outside, outErr, missing, missErr)
			}
			if strings.Contains(outside, secretText) {
				t.Errorf("%s leaks: %q", c.tool, outside)
			}
		}
		// A document id that exists in both collections is not ambiguous for the caller.
		txt, isErr := call(t, s, "kb_get_document", map[string]any{"document_id": "shared-id"})
		if isErr || !strings.Contains(txt, "Collection: bank-coll") {
			t.Fatalf("get: %q err=%v", txt, isErr)
		}
		// A name in two collections is one entity for the caller, never a candidate list that names the other.
		txt, _ = call(t, s, "kb_graph_entity", map[string]any{"name": "Orion"})
		if !strings.Contains(txt, "collection=bank-coll") || strings.Contains(txt, "equip-coll") || strings.Contains(txt, "More than one") {
			t.Fatalf("entity: %q", txt)
		}
		txt, _ = call(t, s, "kb_graph_paths", map[string]any{"from": "Basalt", "to": "Orion"})
		if strings.Contains(txt, "equip-coll") {
			t.Fatalf("paths: %q", txt)
		}
		// The other caller sees the mirror image.
		s2 := e.connect(t, tokEquip)
		txt, _ = call(t, s2, "kb_list_collections", nil)
		if strings.Contains(txt, "bank-coll") || !strings.Contains(txt, "equip-coll") {
			t.Fatalf("equip list: %q", txt)
		}
	}
}

func TestSessionReusedWithAnotherValueOrNoneIsRefused(t *testing.T) {
	e := newAccessEnv(t, "enforce", false)
	resp := rawPost(t, e.srv.URL, tokBank, "", initBody)
	sid := resp.Header.Get("Mcp-Session-Id")
	if resp.StatusCode != http.StatusOK || sid == "" {
		t.Fatalf("stateful init: status %d session %q", resp.StatusCode, sid)
	}
	list := `{"jsonrpc":"2.0","id":2,"method":"tools/list"}`
	for name, tok := range map[string]string{"other caller's value": tokEquip, "no value": "", "unknown value": "Bearer nope"} {
		if r := rawPost(t, e.srv.URL, tok, sid, list); r.StatusCode != http.StatusUnauthorized {
			t.Errorf("%s: status %d, want 401", name, r.StatusCode)
		}
	}
	if r := rawPost(t, e.srv.URL, tokBank, sid, list); r.StatusCode == http.StatusUnauthorized {
		t.Errorf("the owner of the session must not be refused")
	}
}

func TestToolCallDecidesTheCallerFromItsOwnHeader(t *testing.T) {
	// Even if a request got past the guard, the scope of a tool call comes from that request's header.
	e := newAccessEnv(t, "enforce", true)
	s := e.connect(t, tokBank)
	txt, _ := call(t, s, "kb_list_collections", nil)
	if strings.Contains(txt, "equip-coll") {
		t.Fatal(txt)
	}
	s2 := e.connect(t, tokEquip)
	txt, _ = call(t, s2, "kb_list_collections", nil)
	if strings.Contains(txt, "bank-coll") {
		t.Fatal(txt)
	}
}

func TestCallerWithAnEmptyListIsKnownAndReadsNothing(t *testing.T) {
	e := newAccessEnv(t, "enforce", true)
	s := e.connect(t, tokEmpty)
	for tool, args := range map[string]map[string]any{
		"kb_list_collections": nil,
		"kb_search":           {"query": "pelican"},
		"kb_get_document":     {"document_id": "shared-id"},
		"kb_graph_entity":     {"name": "Orion"},
		"kb_graph_search":     {"query": "who owns Orion"},
		"kb_graph_paths":      {"from": "Basalt", "to": "Orion"},
	} {
		txt, _ := call(t, s, tool, args)
		if strings.Contains(txt, "bank-coll") || strings.Contains(txt, "equip-coll") || strings.Contains(txt, secretText) {
			t.Errorf("%s: %q", tool, txt)
		}
	}
	if txt, _ := call(t, s, "kb_list_collections", nil); !strings.Contains(txt, "No collections") {
		t.Errorf("an empty list sees an empty knowledge base: %q", txt)
	}
}

func TestRotatedValueNeedsNoRestart(t *testing.T) {
	e := newAccessEnv(t, "enforce", true)
	if r := rawPost(t, e.srv.URL, tokBank, "", initBody); r.StatusCode != http.StatusOK {
		t.Fatal(r.StatusCode)
	}
	if err := os.WriteFile(filepath.Join(e.dir, "bank"), []byte("Bearer rotated-0001"), 0o600); err != nil {
		t.Fatal(err)
	}
	if r := rawPost(t, e.srv.URL, tokBank, "", initBody); r.StatusCode != http.StatusUnauthorized {
		t.Fatalf("old value: %d", r.StatusCode)
	}
	if r := rawPost(t, e.srv.URL, "Bearer rotated-0001", "", initBody); r.StatusCode != http.StatusOK {
		t.Fatalf("new value: %d", r.StatusCode)
	}
}

func TestReportModeAllowsAndLogsWhatEnforceWouldChange(t *testing.T) {
	e := newAccessEnv(t, "report", true)

	// A caller with no value is allowed and tagged none.
	s := e.connect(t, "")
	txt, _ := call(t, s, "kb_list_collections", nil)
	if !strings.Contains(txt, "bank-coll") || !strings.Contains(txt, "equip-coll") {
		t.Fatalf("report must not filter: %q", txt)
	}
	// A known caller reading its own collection is not outside its list.
	sb := e.connect(t, tokBank)
	e.logs.Reset()
	txt, _ = call(t, sb, "kb_search", map[string]any{"query": "pelican", "collection": "bank-coll"})
	if !strings.Contains(txt, "bank-coll") {
		t.Fatal(txt)
	}
	own := e.logs.String()
	if !strings.Contains(own, `"caller":"bank"`) || strings.Contains(own, "outside_list") {
		t.Fatalf("own collection: %s", own)
	}
	// Reading another collection is allowed, and logged as outside the list.
	e.logs.Reset()
	txt, _ = call(t, sb, "kb_search", map[string]any{"query": "pelican", "collection": "equip-coll"})
	if !strings.Contains(txt, "equip-coll") {
		t.Fatalf("report must not filter: %q", txt)
	}
	if l := e.logs.String(); !strings.Contains(l, `"caller":"bank"`) || !strings.Contains(l, `"outside_list":true`) {
		t.Fatalf("outside: %s", l)
	}
	// Omitting the collection returns both: logged as outside.
	e.logs.Reset()
	call(t, sb, "kb_search", map[string]any{"query": "pelican"})
	if !strings.Contains(e.logs.String(), `"outside_list":true`) {
		t.Fatalf("omitted: %s", e.logs.String())
	}
	// The caller with no value is logged as none, outside.
	e.logs.Reset()
	call(t, s, "kb_list_collections", nil)
	if l := e.logs.String(); !strings.Contains(l, `"caller":"none"`) || !strings.Contains(l, `"outside_list":true`) {
		t.Fatalf("none: %s", l)
	}
	// Each graph tool and get_document reports too.
	for _, c := range []struct {
		tool string
		args map[string]any
	}{
		{"kb_get_document", map[string]any{"document_id": "only-equip-coll", "collection": "equip-coll"}},
		{"kb_graph_search", map[string]any{"query": "who owns Orion", "collection": "equip-coll"}},
		{"kb_graph_entity", map[string]any{"name": "Orion", "collection": "equip-coll"}},
		{"kb_graph_paths", map[string]any{"from": "Basalt", "to": "Orion", "collection": "equip-coll"}},
	} {
		e.logs.Reset()
		call(t, sb, c.tool, c.args)
		if !strings.Contains(e.logs.String(), `"outside_list":true`) {
			t.Errorf("%s: %s", c.tool, e.logs.String())
		}
	}
}

func TestNoValueOrDocumentTextInAnyLogLine(t *testing.T) {
	for _, mode := range []string{"report", "enforce"} {
		e := newAccessEnv(t, mode, true)
		s := e.connect(t, tokBank)
		call(t, s, "kb_search", map[string]any{"query": "pelican"})
		call(t, s, "kb_get_document", map[string]any{"document_id": "shared-id"})
		call(t, s, "kb_graph_entity", map[string]any{"name": "Orion"})
		rawPost(t, e.srv.URL, "Bearer canary-wrong-value", "", initBody)
		for _, bad := range []string{"canary", secretText, "pelican"} {
			if strings.Contains(e.logs.String(), bad) {
				t.Errorf("%s: log holds %q:\n%s", mode, bad, e.logs.String())
			}
		}
	}
}

func TestEveryToolIsReadOnly(t *testing.T) {
	e := newAccessEnv(t, "enforce", true)
	s := e.connect(t, tokBank)
	res, err := s.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Tools) < 6 {
		t.Fatalf("expected the knowledge and graph tools, got %d", len(res.Tools))
	}
	for _, tool := range res.Tools {
		if tool.Annotations == nil || !tool.Annotations.ReadOnlyHint {
			t.Errorf("tool %s is not read only; a write tool needs a new record (ADR 0030 section 4)", tool.Name)
		}
	}
}
