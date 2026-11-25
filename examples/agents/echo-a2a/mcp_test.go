package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// fakeMCP is a streamable-HTTP MCP server with one session: initialize (answered as SSE, like ToolHive's vMCP may do),
// notifications/initialized, tools/list. It records the bearer token of every request.
type fakeMCP struct {
	srv    *httptest.Server
	mu     sync.Mutex
	tokens []string
	calls  []string
	status int
}

func newFakeMCP(t *testing.T) *fakeMCP {
	f := &fakeMCP{status: 200}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
		}
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &req)
		f.mu.Lock()
		f.tokens = append(f.tokens, r.Header.Get("Authorization"))
		f.calls = append(f.calls, req.Method)
		f.mu.Unlock()
		if f.status != 200 {
			w.WriteHeader(f.status)
			return
		}
		switch req.Method {
		case "initialize":
			w.Header().Set("Mcp-Session-Id", "s-1")
			w.Header().Set("Content-Type", "text/event-stream")
			_, _ = io.WriteString(w, "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":"+string(req.ID)+",\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{}}}\n\n")
		case "notifications/initialized":
			if r.Header.Get("Mcp-Session-Id") != "s-1" {
				w.WriteHeader(400)
				return
			}
			w.WriteHeader(http.StatusAccepted)
		case "tools/list":
			if r.Header.Get("Mcp-Session-Id") != "s-1" {
				w.WriteHeader(400)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, `{"jsonrpc":"2.0","id":`+string(req.ID)+`,"result":{"tools":[{"name":"osv_query_vulnerability"},{"name":"osv_get_vulnerability"}]}}`)
		default:
			w.WriteHeader(400)
		}
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func tokenFile(t *testing.T, v string) string {
	p := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(p, []byte(v+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestToolsListsTheProfileTools(t *testing.T) {
	mcp := newFakeMCP(t)
	tf := tokenFile(t, "tok-1")
	env := map[string]string{"OPENAGENTIX_MCP_URL": mcp.srv.URL + "/mcp", "OPENAGENTIX_MCP_TOKEN_FILE": tf}
	h := newServer(envOf(env), nil, io.Discard).Handler()
	code, m, raw := rpc(t, h, sendBody("/tools"))
	if code != 200 || errCode(m) != 0 {
		t.Fatalf("%d %s", code, raw)
	}
	if got := replyText(m); got != "tools: osv_get_vulnerability, osv_query_vulnerability" {
		t.Fatalf("%q", got)
	}
	if strings.Join(mcp.calls, ",") != "initialize,notifications/initialized,tools/list" {
		t.Fatalf("calls: %v", mcp.calls)
	}
	for _, tk := range mcp.tokens {
		if tk != "Bearer tok-1" {
			t.Fatalf("token: %q", tk)
		}
	}
	// the token is read fresh for every call (the kubelet replaces the file)
	_ = os.WriteFile(tf, []byte("tok-2"), 0o600)
	rpc(t, h, sendBody("/tools"))
	if last := mcp.tokens[len(mcp.tokens)-1]; last != "Bearer tok-2" {
		t.Fatalf("token not reread: %q", last)
	}
}

func TestToolsWithoutAProfile(t *testing.T) {
	h := newServer(envOf(map[string]string{}), nil, io.Discard).Handler()
	_, m, _ := rpc(t, h, sendBody("/tools"))
	if got := replyText(m); got != "no tool profile: OPENAGENTIX_MCP_URL is not set" {
		t.Fatalf("%q", got)
	}
}

func TestToolsRefusedByTheServerSaysSoWithoutTheToken(t *testing.T) {
	mcp := newFakeMCP(t)
	mcp.status = 403
	env := map[string]string{"OPENAGENTIX_MCP_URL": mcp.srv.URL + "/mcp", "OPENAGENTIX_MCP_TOKEN_FILE": tokenFile(t, "secret-token")}
	_, m, raw := rpc(t, newServer(envOf(env), nil, io.Discard).Handler(), sendBody("/tools"))
	if errCode(m) != -32000 || !strings.Contains(raw, "tool server returned status 403") || strings.Contains(raw, "secret-token") {
		t.Fatalf("%s", raw)
	}
}

func replyText(m map[string]any) string {
	r, _ := m["result"].(map[string]any)
	msg, _ := r["message"].(map[string]any)
	parts, _ := msg["parts"].([]any)
	if len(parts) == 0 {
		return ""
	}
	p, _ := parts[0].(map[string]any)
	s, _ := p["text"].(string)
	return s
}
