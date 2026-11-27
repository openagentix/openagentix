package main

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

const mcpHeader = "Bearer 0123456789abcdef0123456789abcdef0123456789ab"

// startRecords runs the service with env m and returns the two bound addresses, the log, and a stop function that returns run's error.
func startRecords(t *testing.T, m map[string]string) (mcpAddr, restAddr string, logs *syncBuf, stop func() error) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	addrs := make(chan [2]string, 1)
	done := make(chan error, 1)
	logs = &syncBuf{}
	m["RECORDS_DATA_DIR"] = t.TempDir()
	m["RECORDS_MCP_ADDR"] = "127.0.0.1:0"
	m["RECORDS_REST_ADDR"] = "127.0.0.1:0"
	go func() {
		done <- run(ctx, env(m), slog.New(slog.NewJSONHandler(logs, nil)), func(mcp, rest string) { addrs <- [2]string{mcp, rest} })
	}()
	select {
	case a := <-addrs:
		return a[0], a[1], logs, func() error { cancel(); return <-done }
	case err := <-done:
		cancel()
		t.Fatal(err)
	case <-time.After(20 * time.Second):
		cancel()
		t.Fatal("did not start")
	}
	return
}

// syncBuf is a log buffer that the service and the test may touch from two goroutines.
type syncBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuf) Write(p []byte) (int, error) { s.mu.Lock(); defer s.mu.Unlock(); return s.b.Write(p) }
func (s *syncBuf) String() string              { s.mu.Lock(); defer s.mu.Unlock(); return s.b.String() }

func TestRunRefusesToStartWithoutAMCPCredential(t *testing.T) {
	err := run(context.Background(), env(map[string]string{"RECORDS_DATA_DIR": t.TempDir(), "RECORDS_MCP_ADDR": "127.0.0.1:0", "RECORDS_REST_ADDR": "127.0.0.1:0"}),
		slog.New(slog.NewJSONHandler(io.Discard, nil)), nil)
	if err == nil || !strings.Contains(err.Error(), "RECORDS_MCP_TOKEN_FILE") {
		t.Fatalf("with no token file and no insecure flag the service must refuse to start and name RECORDS_MCP_TOKEN_FILE, got: %v", err)
	}
}

func TestRunRefusesAnAmbiguousOrBadMCPCredential(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "good")
	if err := os.WriteFile(good, []byte(mcpHeader), 0o600); err != nil {
		t.Fatal(err)
	}
	bad := filepath.Join(dir, "bad")
	if err := os.WriteFile(bad, []byte("Bearer x"), 0o600); err != nil {
		t.Fatal(err)
	}
	for name, m := range map[string]map[string]string{
		"token file and the insecure flag together": {"RECORDS_MCP_TOKEN_FILE": good, "RECORDS_MCP_INSECURE_NO_AUTH": "true"},
		"a token file that is too short":            {"RECORDS_MCP_TOKEN_FILE": bad},
		"a token file that does not exist":          {"RECORDS_MCP_TOKEN_FILE": filepath.Join(dir, "none")},
		"the insecure flag with another word":       {"RECORDS_MCP_INSECURE_NO_AUTH": "yes"},
	} {
		m["RECORDS_DATA_DIR"] = t.TempDir()
		if err := run(context.Background(), env(m), slog.New(slog.NewJSONHandler(io.Discard, nil)), nil); err == nil {
			t.Errorf("%s: want an error", name)
		}
	}
}

func TestMCPPortNeedsTheHeaderAndTheRESTPortDoesNot(t *testing.T) {
	tf := filepath.Join(t.TempDir(), "value")
	if err := os.WriteFile(tf, []byte(mcpHeader+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	mcpAddr, restAddr, logs, stop := startRecords(t, map[string]string{"RECORDS_MCP_TOKEN_FILE": tf})
	initBody := `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}`
	post := func(auth string) int {
		req, _ := http.NewRequest("POST", "http://"+mcpAddr+"/mcp", strings.NewReader(initBody))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Accept", "application/json, text/event-stream")
		if auth != "" {
			req.Header.Set("Authorization", auth)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		_, _ = io.Copy(io.Discard, resp.Body)
		return resp.StatusCode
	}
	if c := post(""); c != 401 {
		t.Errorf("no header: %d, want 401", c)
	}
	if c := post("Bearer 0123456789abcdef0123456789abcdef0123456789ac"); c != 401 {
		t.Errorf("wrong header: %d, want 401", c)
	}
	if c := post(mcpHeader); c != 200 {
		t.Errorf("right header: %d, want 200", c)
	}
	for _, u := range []string{"http://" + mcpAddr + "/healthz", "http://" + mcpAddr + "/readyz", "http://" + restAddr + "/readyz", "http://" + restAddr + "/cases/DSP-2026-0001"} {
		resp, err := http.Get(u)
		if err != nil || resp.StatusCode != 200 {
			t.Errorf("%s with no header: %v %v, want 200", u, resp, err)
		}
		if resp != nil {
			resp.Body.Close()
		}
	}
	if err := stop(); err != nil {
		t.Fatal(err)
	}
	out := logs.String()
	if !strings.Contains(out, "refused") {
		t.Errorf("a refusal must be logged (the control for the next check is not empty): %s", out)
	}
	if strings.Contains(out, mcpHeader[7:]) || strings.Contains(out, "0123456789abcdef") {
		t.Fatalf("the header value is in the log: %s", out)
	}
}

func TestInsecureFlagIsNamedInTheLog(t *testing.T) {
	_, _, logs, stop := startRecords(t, map[string]string{"RECORDS_MCP_INSECURE_NO_AUTH": "true"})
	if err := stop(); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(logs.String(), "RECORDS_MCP_INSECURE_NO_AUTH") {
		t.Fatalf("the insecure test mode must be said in the log: %s", logs.String())
	}
}
