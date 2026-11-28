package mcpserver

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/openagentix/openagentix/services/kb/internal/access"
	"github.com/openagentix/openagentix/services/kb/internal/chunk"
	"github.com/openagentix/openagentix/services/kb/internal/embed"
	"github.com/openagentix/openagentix/services/kb/internal/kb"
	"github.com/openagentix/openagentix/services/kb/internal/store/memory"
)

// The MCP handler is served WITHOUT the guard, as if a request had got past it. A session is opened with A's value; then a call arrives in that session carrying B's header.
// The call must be decided from its own header: B's collections, not A's, and not "whatever the session has" (review L5).
func TestACallInASessionOfAIsDecidedFromItsOwnHeader(t *testing.T) {
	log := slog.New(slog.NewJSONHandler(&bytes.Buffer{}, nil))
	svc := &kb.Service{Store: memory.New(0), Embedder: embed.None{}, Chunk: chunk.Options{MaxChars: 400}, DocMaxChars: 5000, Log: log}
	ctx := context.Background()
	for _, c := range []string{"bank-coll", "equip-coll"} {
		if _, err := svc.Put(ctx, c, "d-"+c, kb.DocInput{Title: c, Text: "pelican " + c}); err != nil {
			t.Fatal(err)
		}
	}
	dir := t.TempDir()
	for n, v := range map[string]string{"bank": tokBank, "equip": tokEquip} {
		if err := os.WriteFile(filepath.Join(dir, n), []byte(v), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	cfg := filepath.Join(t.TempDir(), "access.json")
	body := `{"mode":"enforce","callers":[{"name":"bank","collections":["bank-coll"]},{"name":"equip","collections":["equip-coll"]}]}`
	if err := os.WriteFile(cfg, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	az, err := access.Load(cfg, dir, log)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(newInner(svc, log, Options{Stateless: false, Version: "t", Timeout: 5 * time.Second, Access: az}))
	t.Cleanup(srv.Close)

	post := func(authorization, session, payload string) (*http.Response, string) {
		req, _ := http.NewRequest(http.MethodPost, srv.URL, strings.NewReader(payload))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Accept", "application/json, text/event-stream")
		req.Header.Set("Authorization", authorization)
		if session != "" {
			req.Header.Set("Mcp-Session-Id", session)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp, string(b)
	}
	resp, _ := post(tokBank, "", initBody)
	sid := resp.Header.Get("Mcp-Session-Id")
	if sid == "" {
		t.Fatal("no session")
	}
	_, _ = post(tokBank, sid, `{"jsonrpc":"2.0","method":"notifications/initialized"}`)
	list := func(authorization string) string {
		_, b := post(authorization, sid, `{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"kb_list_collections","arguments":{}}}`)
		var text strings.Builder
		for _, line := range strings.Split(b, "\n") {
			line = strings.TrimPrefix(line, "data: ")
			var r struct {
				Result struct {
					Content []struct{ Text string }
				}
			}
			if json.Unmarshal([]byte(line), &r) == nil {
				for _, c := range r.Result.Content {
					text.WriteString(c.Text)
				}
			}
		}
		return text.String()
	}
	a := list(tokBank)
	if !strings.Contains(a, "bank-coll") || strings.Contains(a, "equip-coll") {
		t.Fatalf("A in A's session: %q", a)
	}
	b := list(tokEquip)
	if !strings.Contains(b, "equip-coll") || strings.Contains(b, "bank-coll") {
		t.Fatalf("B's header in A's session must give B's list, not A's: %q", b)
	}
	none := list("")
	if strings.Contains(none, "coll") && !strings.Contains(none, "No collections") {
		t.Fatalf("no header in A's session must read nothing: %q", none)
	}
}
