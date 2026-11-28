package main

import (
	"bytes"
	"context"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeAccess(t *testing.T, body string, creds map[string]string) map[string]string {
	t.Helper()
	root := t.TempDir()
	dir := filepath.Join(root, "callers")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for n, v := range creds {
		if err := os.WriteFile(filepath.Join(dir, n), []byte(v), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "access.json"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return map[string]string{"KB_ACCESS_FILE": filepath.Join(root, "access.json"), "KB_ACCESS_CALLERS_DIR": dir}
}

func TestBadAccessConfigStopsTheStartAndNamesTheItem(t *testing.T) {
	quiet := slog.New(slog.NewJSONHandler(&bytes.Buffer{}, nil))
	for name, c := range map[string]struct {
		body  string
		creds map[string]string
		want  string
	}{
		"unknown key":        {`{"mode":"enforce","callers":[{"name":"a","collections":["x"],"oops":1}]}`, map[string]string{"a": "Bearer v1"}, "oops"},
		"bad collection":     {`{"mode":"enforce","callers":[{"name":"a","collections":["bad name"]}]}`, map[string]string{"a": "Bearer v1"}, `"a"`},
		"missing value file": {`{"mode":"enforce","callers":[{"name":"a","collections":["x"]},{"name":"b","collections":["y"]}]}`, map[string]string{"a": "Bearer v1"}, `"b"`},
	} {
		env := writeAccess(t, c.body, c.creds)
		env["KB_ADDR"] = "127.0.0.1:0"
		err := run(context.Background(), envFn(env), quiet, nil)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: err = %v, want it to name %s", name, err, c.want)
		}
	}
}

func TestEnforceModeServesMCPOnlyToKnownCallersAndLeavesTheRestAlone(t *testing.T) {
	env := writeAccess(t, `{"mode":"enforce","callers":[{"name":"a","collections":["x"]}]}`, map[string]string{"a": "Bearer canary-main-42"})
	env["KB_ADMIN_TOKEN"] = "adm"
	var logs bytes.Buffer
	base, stop := start(t, env, &logs)
	post := func(authz string) int {
		const initBody = `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"x","version":"0"}}}`
		req, _ := http.NewRequest("POST", base+"/mcp", strings.NewReader(initBody))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Accept", "application/json, text/event-stream")
		if authz != "" {
			req.Header.Set("Authorization", authz)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	if c := post(""); c != 401 {
		t.Errorf("no value: %d", c)
	}
	if c := post("Bearer canary-main-42"); c != 200 {
		t.Errorf("known value: %d", c)
	}
	put := func(authz string) int {
		req, _ := http.NewRequest("PUT", base+"/v1/collections/x/documents/d", strings.NewReader(`{"text":"hello"}`))
		req.Header.Set("Authorization", authz)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	if c := put("Bearer canary-main-42"); c != 401 {
		t.Errorf("a caller value must not write: %d", c)
	}
	if c := put("Bearer adm"); c != 200 {
		t.Errorf("admin write: %d", c)
	}
	if resp, err := http.Get(base + "/healthz"); err != nil || resp.StatusCode != 200 {
		t.Errorf("healthz: %v %v", err, resp)
	}
	if err := stop(); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(logs.String(), "canary-main-42") {
		t.Fatalf("log holds a value: %s", logs.String())
	}
	if !strings.Contains(logs.String(), `"access":"enforce"`) {
		t.Fatalf("the start log must say the mode: %s", logs.String())
	}
}
