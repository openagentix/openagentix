package main

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"testing"
	"time"
)

func env(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

func TestRunServesBothPortsAndStops(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	addrs := make(chan [2]string, 1)
	done := make(chan error, 1)
	go func() {
		done <- run(ctx, env(map[string]string{"RECORDS_DATA_DIR": t.TempDir(), "RECORDS_MCP_ADDR": "127.0.0.1:0", "RECORDS_REST_ADDR": "127.0.0.1:0"}),
			slog.New(slog.NewJSONHandler(io.Discard, nil)), func(mcp, rest string) { addrs <- [2]string{mcp, rest} })
	}()
	var a [2]string
	select {
	case a = <-addrs:
	case err := <-done:
		t.Fatal(err)
	case <-time.After(20 * time.Second):
		t.Fatal("did not start")
	}
	for _, u := range []string{"http://" + a[0] + "/readyz", "http://" + a[1] + "/readyz", "http://" + a[1] + "/cases/DSP-2026-0001"} {
		resp, err := http.Get(u)
		if err != nil || resp.StatusCode != 200 {
			t.Fatalf("%s: %v %v", u, resp, err)
		}
		resp.Body.Close()
	}
	// With no approvers file, deciding is refused.
	resp, err := http.Post("http://"+a[1]+"/approvals/APR-0001/approve", "application/json", nil)
	if err != nil || resp.StatusCode != 401 {
		t.Fatalf("approve without approvers: %v %v", resp, err)
	}
	resp.Body.Close()
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("did not stop")
	}
}

func TestRunRefusesBadConfig(t *testing.T) {
	for name, m := range map[string]map[string]string{
		"unknown domain":    {"RECORDS_DOMAIN": "zoo", "RECORDS_DATA_DIR": t.TempDir()},
		"missing approvers": {"RECORDS_APPROVERS_FILE": "/nonexistent/approvers.json", "RECORDS_DATA_DIR": t.TempDir()},
	} {
		if err := run(context.Background(), env(m), slog.New(slog.NewJSONHandler(io.Discard, nil)), nil); err == nil {
			t.Errorf("%s: want error", name)
		}
	}
}
