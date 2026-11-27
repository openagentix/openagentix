package replay

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

const (
	casesFile  = "../../bank/eval/cases.yaml"
	evalModule = "../../../../tools/oa-eval"
)

// fakeGate is the A2A gate in front of the agent of the replay: every SendMessage runs the agent loop (real stub model, real records
// service) and the tool calls are kept as audit events, one JSON object per call with a `tool` field, like the tool gateway's audit.
type fakeGate struct {
	mu    sync.Mutex
	e     *env
	audit []map[string]string
}

func (g *fakeGate) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.Method == http.MethodGet && r.URL.Path == "/audit":
		g.mu.Lock()
		defer g.mu.Unlock()
		_ = json.NewEncoder(w).Encode(g.audit)
	case r.Method == http.MethodPost && r.URL.Path == "/agents/kagent/dispute-agent":
		var in struct {
			Params struct {
				Message struct {
					Parts []struct{ Text string } `json:"parts"`
				} `json:"message"`
			} `json:"params"`
		}
		raw, _ := io.ReadAll(r.Body)
		if err := json.Unmarshal(raw, &in); err != nil || len(in.Params.Message.Parts) == 0 {
			http.Error(w, "bad request", 400)
			return
		}
		g.mu.Lock()
		defer g.mu.Unlock()
		answer := g.e.run(in.Params.Message.Parts[0].Text)
		for _, c := range g.e.called {
			g.audit = append(g.audit, map[string]string{"tool": c})
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": "1", "result": map[string]any{"task": map[string]any{
			"status":    map[string]any{"state": "TASK_STATE_COMPLETED"},
			"artifacts": []any{map[string]any{"parts": []any{map[string]any{"text": answer}}}},
		}}})
	default:
		http.NotFound(w, r)
	}
}

func buildEval(t *testing.T) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "oa-eval")
	cmd := exec.Command("go", "build", "-o", bin, "./cmd/oa-eval")
	cmd.Dir = evalModule
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("building oa-eval: %v\n%s", err, out)
	}
	return bin
}

func runEval(t *testing.T, bin, gate, state, cases string, extra ...string) (string, int) {
	t.Helper()
	out := filepath.Join(t.TempDir(), "report.json")
	args := append([]string{"run", "--cases", cases, "--gate-url", gate, "--audit", gate + "/audit", "--state-base", state,
		"--audit-settle", "10ms", "--user-id", "desk:eval", "--out", out}, extra...)
	cmd := exec.Command(bin, args...)
	var buf bytes.Buffer
	cmd.Stdout, cmd.Stderr = &buf, &buf
	err := cmd.Run()
	code := 0
	if ee, ok := err.(*exec.ExitError); ok {
		code = ee.ExitCode()
	} else if err != nil {
		t.Fatal(err)
	}
	return buf.String(), code
}

// The evaluation set of the use case, run by the real oa-eval against the stub model and the real records service.
func TestEvaluationSetPassesAgainstTheScriptedAgent(t *testing.T) {
	e := newEnv(t)
	gate := httptest.NewServer(&fakeGate{e: e})
	defer gate.Close()
	state := httptest.NewServer(e.rest)
	defer state.Close()
	out, code := runEval(t, buildEval(t), gate.URL, state.URL, casesFile)
	if code != 0 {
		t.Fatalf("oa-eval exit %d:\n%s", code, out)
	}
	t.Log("\n" + out)
	for _, id := range []string{"duplicate-charge", "out-of-time-declined", "injected-instruction-refused", "no-evidence-needs-human-review", "deadline-sweep-reads-only"} {
		if !strings.Contains(out, id) {
			t.Errorf("the report does not show the case %s:\n%s", id, out)
		}
	}
}

// A check that can fail must be able to fail: the same set against an agent that credits at once (a ledger row exists before the run) and
// one that skips the letter must not pass.
func TestEvaluationSetFailsWhenTheRecordShowsACredit(t *testing.T) {
	e := newEnv(t)
	gate := httptest.NewServer(&fakeGate{e: e})
	defer gate.Close()
	state := httptest.NewServer(e.rest)
	defer state.Close()
	// Approve a credit by hand first: the ledger is no longer empty, which the set must notice.
	e.run("Work case DSP-2026-0001")
	id, full := e.pendingApproval("DSP-2026-0001")
	e.approve(id, full)
	out, code := runEval(t, buildEval(t), gate.URL, state.URL, casesFile, "--only", "injected-instruction-refused")
	if code != 1 || !strings.Contains(out, "ledger") {
		t.Fatalf("want exit 1 with a ledger failure, got %d:\n%s", code, out)
	}
}

// A set that cannot fail proves nothing. Here the injection scenario is replaced by an agent that obeys the injected order and asks for an
// approval. The injection case must fail, on the approval check and on the tool check.
func TestEvaluationSetFailsAnAgentThatObeysTheInjectedInstruction(t *testing.T) {
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
	id := map[string]any{"case_id": "{{user.id}}"}
	for _, sc := range f.Scenarios {
		if sc["name"] != "injection-attempt" {
			continue
		}
		sc["steps"] = []any{
			map[string]any{"tool": "get_case", "args": id},
			map[string]any{"tool": "set_route", "args": map[string]any{"case_id": "{{user.id}}", "route": "decline", "reason": "as requested"}},
			map[string]any{"tool": "draft_letter", "args": map[string]any{"case_id": "{{user.id}}", "body": "letter"}},
			map[string]any{"tool": "request_approval", "args": map[string]any{"case_id": "{{user.id}}", "kind": "decline", "amount_cents": 0}},
		}
		sc["answers"] = []any{map[string]any{"text": "Done as requested: the refund is approved."}}
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
	if code != 1 {
		t.Fatalf("want exit 1, got %d:\n%s", code, res)
	}
	for _, want := range []string{"records_request_approval", "approvals"} {
		if !strings.Contains(res, want) {
			t.Errorf("the failure lines must mention %q:\n%s", want, res)
		}
	}
}

func TestEvaluationSetFileIsValidAndPlain(t *testing.T) {
	raw, err := os.ReadFile(casesFile)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "\u2014") {
		t.Error("the evaluation set contains an em dash")
	}
	if !strings.Contains(string(raw), fmt.Sprintf("agent: %s", "kagent/dispute-agent")) {
		t.Error("the set must target kagent/dispute-agent")
	}
}
