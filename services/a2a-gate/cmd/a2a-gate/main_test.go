package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
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
)

// syncBuf is a bytes.Buffer safe for a server goroutine to write while the test reads.
type syncBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuf) Write(p []byte) (int, error) { s.mu.Lock(); defer s.mu.Unlock(); return s.b.Write(p) }
func (s *syncBuf) String() string              { s.mu.Lock(); defer s.mu.Unlock(); return s.b.String() }

// waitFor polls until the buffer holds want. Audit lines are written when a handler returns, after the response is sent.
func (s *syncBuf) waitFor(t *testing.T, want string) string {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if got := s.String(); strings.Contains(got, want) {
			return got
		}
		time.Sleep(5 * time.Millisecond)
	}
	return s.String()
}

func TestRunServesAndStops(t *testing.T) {
	var gotUser string
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotUser = r.Header.Get("X-User-Id")
		io.WriteString(w, "{}")
	}))
	defer up.Close()
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "rules.json"), []byte(`{"callers":[{"name":"k","key":true,"agents":["kagent/assistant"],"userId":{"fixed":"kourier:k"}}]}`), 0o600)
	os.Mkdir(filepath.Join(dir, "keys"), 0o700)
	h := sha256.Sum256([]byte("the-key"))
	os.WriteFile(filepath.Join(dir, "keys", "k"), []byte(hex.EncodeToString(h[:])), 0o600)
	env := map[string]string{
		"A2A_GATE_UPSTREAM": up.URL, "A2A_GATE_RULES": filepath.Join(dir, "rules.json"), "A2A_GATE_KEYS_DIR": filepath.Join(dir, "keys"),
		"A2A_GATE_ADDR": "127.0.0.1:0",
	}
	var out, errb syncBuf
	ctx, cancel := context.WithCancel(context.Background())
	addr := make(chan string, 1)
	done := make(chan error, 1)
	go func() {
		done <- run(ctx, func(k string) string { return env[k] }, deps{Stdout: &out, Log: slog.New(slog.NewJSONHandler(&errb, nil)), OnListen: func(a string) { addr <- a }, Reviewer: noReviewer{}})
	}()
	var a string
	select {
	case a = <-addr:
	case <-time.After(3 * time.Second):
		t.Fatal("did not start")
	}
	req, _ := http.NewRequest("POST", "http://"+a+"/agents/kagent/assistant", strings.NewReader(`{"method":"SendMessage","params":{"message":{"contextId":"c1"}}}`))
	req.Header.Set("Authorization", "Bearer the-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil || resp.StatusCode != 200 {
		t.Fatalf("%v %v", resp, err)
	}
	resp.Body.Close()
	if gotUser != "kourier:k" {
		t.Errorf("upstream user %q", gotUser)
	}
	// a header block above 16 KiB is refused by the server before the gate sees it
	big, _ := http.NewRequest("GET", "http://"+a+"/healthz", nil)
	big.Header.Set("X-Pad", strings.Repeat("p", 20<<10))
	if resp, err := http.DefaultClient.Do(big); err != nil || resp.StatusCode != http.StatusRequestHeaderFieldsTooLarge {
		t.Errorf("20 KiB header: %v %v, want 431", resp, err)
	}
	small, _ := http.NewRequest("GET", "http://"+a+"/healthz", nil)
	small.Header.Set("X-Pad", strings.Repeat("p", 4<<10))
	if resp, err := http.DefaultClient.Do(small); err != nil || resp.StatusCode != http.StatusOK {
		t.Errorf("4 KiB header: %v %v, want 200", resp, err)
	}
	resp, _ = http.Get("http://" + a + "/agents/kagent/assistant")
	if resp.StatusCode != 401 {
		t.Errorf("no token: %d", resp.StatusCode)
	}
	resp.Body.Close()
	// the 401 is the last request, so its audit line is the last to land
	got := out.waitFor(t, `"msg":"audit"`)
	if !strings.Contains(got, `"msg":"audit"`) || strings.Contains(got, "the-key") {
		t.Errorf("audit output: %s", got)
	}
	cancel()
	select {
	case err := <-done:
		if err != nil && err != context.Canceled {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("did not stop")
	}
}

func TestRunRoutesBYOAgent(t *testing.T) {
	var gotHost, gotPath string
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "rules.json"), []byte(`{"callers":[{"name":"k","key":true,"agents":["kagent/echo-go"],"userId":{"fixed":"kourier:k"}}]}`), 0o600)
	os.Mkdir(filepath.Join(dir, "keys"), 0o700)
	h := sha256.Sum256([]byte("the-key"))
	os.WriteFile(filepath.Join(dir, "keys", "k"), []byte(hex.EncodeToString(h[:])), 0o600)
	os.WriteFile(filepath.Join(dir, "routes.json"), []byte(`{"container":["kagent/echo-go"]}`), 0o600)
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotHost, gotPath = "kagent", r.URL.Path
	}))
	defer up.Close()
	env := map[string]string{
		"A2A_GATE_UPSTREAM": up.URL, "A2A_GATE_RULES": filepath.Join(dir, "rules.json"), "A2A_GATE_KEYS_DIR": filepath.Join(dir, "keys"),
		"A2A_GATE_ADDR": "127.0.0.1:0", "A2A_GATE_ROUTES_FILE": filepath.Join(dir, "routes.json"),
		"A2A_GATE_WORKLOAD_NAMESPACE": "openagentix-agents", "A2A_GATE_PUBLIC_URL": "https://gate.example.com",
	}
	var errb syncBuf
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	addr := make(chan string, 1)
	done := make(chan error, 1)
	go func() {
		done <- run(ctx, func(k string) string { return env[k] }, deps{Stdout: io.Discard, Log: slog.New(slog.NewJSONHandler(&errb, nil)), OnListen: func(a string) { addr <- a }, Reviewer: noReviewer{}})
	}()
	a := <-addr
	req, _ := http.NewRequest("POST", "http://"+a+"/agents/kagent/echo-go", strings.NewReader(`{"method":"SendMessage"}`))
	req.Header.Set("Authorization", "Bearer the-key")
	// the workload service does not resolve in a test: a 502 shows the gate tried it and did not fall back to kagent
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadGateway || gotHost != "" || gotPath != "" {
		t.Errorf("listed agent: status %d, kagent saw %q %q", resp.StatusCode, gotHost, gotPath)
	}
	cancel()
	<-done
}

func TestRunRefusesRoutesWithoutNamespace(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "rules.json"), []byte(`{"callers":[{"name":"k","key":true,"agents":["kagent/a"],"userId":{"fixed":"k"}}]}`), 0o600)
	env := map[string]string{"A2A_GATE_UPSTREAM": "http://x:1", "A2A_GATE_RULES": filepath.Join(dir, "rules.json"), "A2A_GATE_ROUTES_FILE": "/nope"}
	err := run(context.Background(), func(k string) string { return env[k] }, deps{Stdout: io.Discard, Log: slog.New(slog.DiscardHandler), Reviewer: noReviewer{}})
	if err == nil || !strings.Contains(err.Error(), "A2A_GATE_WORKLOAD_NAMESPACE") {
		t.Fatalf("%v", err)
	}
}

type noReviewer struct{}

func (noReviewer) Review(context.Context, string, string) (string, error) {
	return "", errors.New("none")
}

func TestRunRefusesBadConfig(t *testing.T) {
	err := run(context.Background(), func(string) string { return "" }, deps{Stdout: io.Discard, Log: slog.New(slog.DiscardHandler), Reviewer: noReviewer{}})
	if err == nil {
		t.Fatal("expected an error")
	}
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "rules.json"), []byte(`{"callers":[{"name":"a"}]}`), 0o600)
	env := map[string]string{"A2A_GATE_UPSTREAM": "http://x:1", "A2A_GATE_RULES": filepath.Join(dir, "rules.json")}
	err = run(context.Background(), func(k string) string { return env[k] }, deps{Stdout: io.Discard, Log: slog.New(slog.DiscardHandler), Reviewer: noReviewer{}})
	if err == nil || !strings.Contains(err.Error(), "rules") {
		t.Fatalf("invalid rules must stop the gate: %v", err)
	}
}
