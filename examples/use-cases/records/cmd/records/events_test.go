package main

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/openagentix/openagentix/examples/use-cases/records/internal/core"
)

const tokenForTest = "MAIN-TOKEN-CANARY-5521"

func startEquipment(t *testing.T, extra map[string]string) (rest string, dir string, stop func()) {
	t.Helper()
	dir = t.TempDir()
	m := map[string]string{"RECORDS_DOMAIN": "equipment", "RECORDS_DATA_DIR": dir, "RECORDS_MCP_ADDR": "127.0.0.1:0", "RECORDS_REST_ADDR": "127.0.0.1:0", "RECORDS_MCP_INSECURE_NO_AUTH": "true"}
	for k, v := range extra {
		m[k] = v
	}
	ctx, cancel := context.WithCancel(context.Background())
	addrs := make(chan [2]string, 1)
	done := make(chan error, 1)
	logs := &syncBuf{}
	go func() {
		done <- run(ctx, env(m), slog.New(slog.NewJSONHandler(logs, nil)), func(mcp, rest string) { addrs <- [2]string{mcp, rest} })
	}()
	select {
	case a := <-addrs:
		rest = a[1]
	case err := <-done:
		t.Fatal(err)
	case <-time.After(30 * time.Second):
		t.Fatal("did not start")
	}
	return rest, dir, func() {
		cancel()
		if err := <-done; err != nil {
			t.Fatal(err)
		}
		if strings.Contains(logs.String(), tokenForTest) {
			t.Error("the token is in the log")
		}
	}
}

func postFault(t *testing.T, rest string) int {
	t.Helper()
	resp, err := http.Post("http://"+rest+"/faults", "application/json", strings.NewReader(`{"serial":"KT260-00130","code":"E-322"}`))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	return resp.StatusCode
}

func hasEventsTable(t *testing.T, dir string) bool {
	t.Helper()
	db, err := core.Open(filepath.Join(dir, "records.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE name='events'`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n == 1
}

func TestWithTheSenderOffNothingIsSentAndTheStoreHasNoEventsTable(t *testing.T) {
	var hits int
	var mu sync.Mutex
	gate := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { mu.Lock(); hits++; mu.Unlock() }))
	defer gate.Close()
	rest, dir, stop := startEquipment(t, nil)
	if c := postFault(t, rest); c != 201 {
		t.Fatalf("fault: %d", c)
	}
	time.Sleep(300 * time.Millisecond)
	stop()
	mu.Lock()
	defer mu.Unlock()
	if hits != 0 {
		t.Fatalf("the gate was called %d times with the sender off", hits)
	}
	if hasEventsTable(t, dir) {
		t.Fatal("the store has an events table with the sender off")
	}
}

func TestWithTheSenderOnAFaultStartsOneCallToTheGateAndARepeatNone(t *testing.T) {
	var mu sync.Mutex
	var bodies, auths []string
	gate := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		bodies, auths = append(bodies, string(b)), append(auths, r.Header.Get("Authorization"))
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"jsonrpc":"2.0","id":"x","result":{"id":"task-9","status":{"state":"TASK_STATE_SUBMITTED"}}}`)
	}))
	defer gate.Close()
	tok := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(tok, []byte(tokenForTest), 0o600); err != nil {
		t.Fatal(err)
	}
	rest, _, stop := startEquipment(t, map[string]string{
		"RECORDS_EVENT_GATE_URL": gate.URL + "/agents/kagent/service-agent", "RECORDS_EVENT_TOKEN_FILE": tok, "RECORDS_EVENT_TICK": "50ms"})
	if c := postFault(t, rest); c != 201 {
		t.Fatalf("fault: %d", c)
	}
	if c := postFault(t, rest); c != 200 { // the same fault again: the open case is reused
		t.Fatalf("repeat: %d", c)
	}
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		mu.Lock()
		n := len(bodies)
		mu.Unlock()
		if n > 0 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	time.Sleep(400 * time.Millisecond) // a second call would show now
	stop()
	mu.Lock()
	defer mu.Unlock()
	if len(bodies) != 1 {
		t.Fatalf("%d calls to the gate, want 1: %v", len(bodies), bodies)
	}
	if !strings.Contains(bodies[0], `"text":"Work case SVC-`) || auths[0] != "Bearer "+tokenForTest {
		t.Fatalf("call %s auth-ok=%v", bodies[0], auths[0] == "Bearer "+tokenForTest)
	}
}

func TestSenderConfigIsAllOrNothing(t *testing.T) {
	tok := filepath.Join(t.TempDir(), "token")
	_ = os.WriteFile(tok, []byte("x"), 0o600)
	for name, m := range map[string]map[string]string{
		"url without token":      {"RECORDS_EVENT_GATE_URL": "http://gate.example/agents/kagent/a"},
		"token without url":      {"RECORDS_EVENT_TOKEN_FILE": tok},
		"url that is not a gate": {"RECORDS_EVENT_GATE_URL": "http://gate.example/api/sessions", "RECORDS_EVENT_TOKEN_FILE": tok},
		"bad duration":           {"RECORDS_EVENT_GATE_URL": "http://gate.example/agents/kagent/a", "RECORDS_EVENT_TOKEN_FILE": tok, "RECORDS_EVENT_UNWORKED_AFTER": "soon"},
		"bad attempts":           {"RECORDS_EVENT_GATE_URL": "http://gate.example/agents/kagent/a", "RECORDS_EVENT_TOKEN_FILE": tok, "RECORDS_EVENT_MAX_ATTEMPTS": "0"},
	} {
		m["RECORDS_DATA_DIR"], m["RECORDS_MCP_INSECURE_NO_AUTH"] = t.TempDir(), "true"
		if err := run(context.Background(), env(m), slog.New(slog.NewJSONHandler(io.Discard, nil)), nil); err == nil {
			t.Errorf("%s: want an error", name)
		}
	}
}
