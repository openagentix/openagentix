package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fakeGate(t *testing.T, answer *string) string {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{"task": map[string]any{
			"status":    map[string]any{"state": "TASK_STATE_COMPLETED"},
			"artifacts": []any{map[string]any{"parts": []any{map[string]string{"text": *answer}}}},
		}}})
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

func write(t *testing.T, name, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

const cases = `
agent: a
cases:
  - id: c1
    input: hello
    expect: {answer_must: ["(?i)source"]}
`

func TestExitCodes(t *testing.T) {
	ans := "Answer with a source."
	gate := fakeGate(t, &ans)
	set := write(t, "cases.yaml", cases)
	rep := filepath.Join(t.TempDir(), "rep.json")
	var out, errb bytes.Buffer

	if rc := run([]string{"run", "--cases", set, "--gate-url", gate, "--out", rep}, &out, &errb); rc != 0 {
		t.Fatalf("pass: rc %d: %s %s", rc, out.String(), errb.String())
	}
	if !strings.Contains(out.String(), "PASS") {
		t.Fatalf("no table: %s", out.String())
	}
	if _, err := os.Stat(rep); err != nil {
		t.Fatalf("report not written: %v", err)
	}

	ans = "No citation here."
	out.Reset()
	if rc := run([]string{"run", "--cases", set, "--gate-url", gate}, &out, &errb); rc != 1 {
		t.Fatalf("failing case: rc %d", rc)
	}
	if !strings.Contains(out.String(), "FAIL") {
		t.Fatalf("table: %s", out.String())
	}

	// replay against the recorded passing report: the case now fails, so it is a regression
	out.Reset()
	if rc := run([]string{"replay", "--cases", set, "--gate-url", gate, "--baseline", rep}, &out, &errb); rc != 1 || !strings.Contains(out.String(), "REGRESSION") {
		t.Fatalf("replay: rc %d: %s", rc, out.String())
	}
	// replay when nothing changed
	ans = "Answer with a source."
	out.Reset()
	if rc := run([]string{"replay", "--cases", set, "--gate-url", gate, "--baseline", rep}, &out, &errb); rc != 0 {
		t.Fatalf("replay same: rc %d: %s", rc, out.String())
	}

	for _, bad := range [][]string{
		nil,
		{"nope"},
		{"run"},
		{"run", "--cases", set},
		{"run", "--cases", filepath.Join(t.TempDir(), "missing.yaml"), "--gate-url", gate},
		{"replay", "--cases", set, "--gate-url", gate},
	} {
		if rc := run(bad, &out, &errb); rc != 2 {
			t.Errorf("%v: rc %d, want 2", bad, rc)
		}
	}
}

// A budget refusal ends the run with exit 3: not a pass, and not a failure of the agent.
func TestExitCodeThreeWhenTheModelRefusedACase(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{"task": map[string]any{
			"status":    map[string]any{"state": "TASK_STATE_FAILED"},
			"artifacts": []any{map[string]any{"parts": []any{map[string]string{"text": "agent run failed: OpenAI API error: 429 Too Many Requests"}}}},
		}}})
	}))
	defer srv.Close()
	set := write(t, "cases.yaml", cases)
	audit := write(t, "audit.jsonl", "")
	var out, errb bytes.Buffer
	if rc := run([]string{"run", "--cases", set, "--gate-url", srv.URL, "--audit", audit, "--audit-settle", "1ms"}, &out, &errb); rc != 3 {
		t.Fatalf("want exit 3, got %d: %s %s", rc, out.String(), errb.String())
	}
	if !strings.Contains(out.String(), "NOT RUN") {
		t.Fatalf("table: %s", out.String())
	}
}

func TestTokenIsReadFromEnvFileOnly(t *testing.T) {
	// there is no --token flag: a token on the command line would show in the process list
	var out, errb bytes.Buffer
	if rc := run([]string{"run", "--token", "x"}, &out, &errb); rc != 2 {
		t.Fatalf("rc %d", rc)
	}
}
