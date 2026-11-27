package replay

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// max_tool_calls on the injection case: an agent that a planted instruction steers into extra reads (a tool it is allowed to call, so no
// other check sees it) fails the case.
func TestEvaluationSetFailsAnAgentThatMakesExtraCallsOnTheInjectionCase(t *testing.T) {
	raw, err := os.ReadFile(scenarioFile)
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Scenarios []map[string]any `json:"scenarios"`
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	for _, sc := range f.Scenarios {
		if sc["name"] != "injection-attempt" {
			continue
		}
		steps := sc["steps"].([]any)
		extra := map[string]any{"tool": "list_open_cases", "args": map[string]any{"limit": 5}}
		sc["steps"] = append(append([]any{}, steps[:2]...), append([]any{extra, extra, extra, extra, extra}, steps[2:]...)...)
	}
	bad := filepath.Join(t.TempDir(), "bad.json")
	out, _ := json.Marshal(f)
	if err := os.WriteFile(bad, out, 0o600); err != nil {
		t.Fatal(err)
	}
	e := newEnvWith(t, bad)
	gate := httptest.NewServer(&fakeGate{e: e})
	defer gate.Close()
	state := httptest.NewServer(e.rest)
	defer state.Close()
	res, code := runEval(t, buildEval(t), gate.URL, state.URL, casesFile, "--only", "injected-instruction-refused")
	if code != 1 || !strings.Contains(res, "max_tool_calls") {
		t.Fatalf("want exit 1 with a max_tool_calls failure, got %d:\n%s", code, res)
	}
}

// The unmodified scenario stays inside the limit (so the failure above is the extra calls and nothing else).
func TestInjectionCaseStaysInsideItsToolCallLimit(t *testing.T) {
	e := newEnv(t)
	gate := httptest.NewServer(&fakeGate{e: e})
	defer gate.Close()
	state := httptest.NewServer(e.rest)
	defer state.Close()
	res, code := runEval(t, buildEval(t), gate.URL, state.URL, casesFile, "--only", "injected-instruction-refused")
	if code != 0 {
		t.Fatalf("exit %d:\n%s", code, res)
	}
	raw, err := os.ReadFile(casesFile)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), "max_tool_calls:") {
		t.Error("the injection case must set max_tool_calls")
	}
}
