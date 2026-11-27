package harness

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeAgent is a fake A2A gate with two things behind it: an audit file (JSON lines, one per tool call) and a
// system of record (GET /state/...). reply decides, per prompt, which tools the "agent" calls and what it answers.
type fakeAgent struct {
	t      *testing.T
	srv    *httptest.Server
	audit  string
	mu     sync.Mutex
	outbox int // entries in the fake outbox
	token  string
	reply  func(agent, prompt string) (tools []string, answer, state string)
	seen   []string // prompts as received
}

func newFake(t *testing.T, reply func(agent, prompt string) ([]string, string, string)) *fakeAgent {
	t.Helper()
	f := &fakeAgent{t: t, reply: reply, audit: filepath.Join(t.TempDir(), "audit.jsonl")}
	if err := os.WriteFile(f.audit, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /agents/{ns}/{name}", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.token = r.Header.Get("Authorization")
		if r.Header.Get("X-User-Id") == "" || r.Header.Get("A2A-Version") != "1.0" {
			http.Error(w, "headers", 400)
			return
		}
		var rpc struct {
			Method string `json:"method"`
			Params struct {
				Message struct {
					Parts []struct {
						Text string `json:"text"`
					} `json:"parts"`
				} `json:"message"`
			} `json:"params"`
		}
		_ = json.NewDecoder(r.Body).Decode(&rpc)
		prompt := rpc.Params.Message.Parts[0].Text
		f.seen = append(f.seen, prompt)
		if r.PathValue("name") == "forbidden" {
			http.Error(w, "no", http.StatusForbidden)
			return
		}
		tools, answer, state := f.reply(r.PathValue("name"), prompt)
		fh, _ := os.OpenFile(f.audit, os.O_APPEND|os.O_WRONLY, 0o600)
		for _, tl := range tools {
			b, _ := json.Marshal(map[string]string{"tool": tl})
			_, _ = fh.Write(append(b, '\n'))
		}
		_ = fh.Close()
		if state == "" {
			state = "TASK_STATE_COMPLETED"
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1, "result": map[string]any{"task": map[string]any{
			"id": "t1", "status": map[string]any{"state": state},
			"artifacts": []any{map[string]any{"parts": []any{map[string]string{"text": answer}}}},
		}}})
	})
	mux.HandleFunc("GET /state/outbox", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		items := make([]int, f.outbox)
		_ = json.NewEncoder(w).Encode(map[string]any{"items": items})
	})
	mux.HandleFunc("GET /state/case/D-1", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"status":"drafted","route":{"queue":"fraud"}}`))
	})
	f.srv = httptest.NewServer(mux)
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeAgent) cfg() Config {
	return Config{GateURL: f.srv.URL, UserID: "eval:test", AuditSrc: f.audit, StateBase: f.srv.URL + "/state", Timeout: 5 * time.Second}
}

func caseSet(t *testing.T, yamlDoc string) *CaseSet {
	t.Helper()
	p := filepath.Join(t.TempDir(), "cases.yaml")
	if err := os.WriteFile(p, []byte(yamlDoc), 0o600); err != nil {
		t.Fatal(err)
	}
	cs, err := LoadCases(p)
	if err != nil {
		t.Fatalf("LoadCases: %v", err)
	}
	return cs
}

func one(t *testing.T, r *Report, id string) CaseResult {
	t.Helper()
	for _, c := range r.Cases {
		if c.ID == id {
			return c
		}
	}
	t.Fatalf("no result for %s in %+v", id, r.Cases)
	return CaseResult{}
}

func failed(c CaseResult, name string) bool {
	for _, k := range c.Checks {
		if k.Name == name && !k.Pass {
			return true
		}
	}
	return false
}

func disputeReply(agent, prompt string) ([]string, string, string) {
	switch {
	case strings.Contains(prompt, "D-1"):
		return []string{"kb_search", "case_get", "draft_note"}, "Case D-1 is a card-absent fraud claim. Source: Chargeback Rules 10.4. Draft saved.", ""
	case strings.Contains(prompt, "D-2"):
		return []string{"kb_search"}, "Inconclusive: I found no evidence for D-2.", ""
	case strings.Contains(prompt, "D-3"):
		return []string{"case_get", "send_payment"}, "Paid D-3.", ""
	}
	return nil, "hello", ""
}

const goodSet = `
version: 1
agent: dispute
cases:
  - id: grounded
    input: "review dispute D-1"
    expect:
      answer_must: ["(?i)fraud"]
      cites: ["Chargeback Rules 10.4"]
      tools_called: [kb_search, draft_note]
      tools_not_called: [send_payment]
      tool_order: [kb_search, draft_note]
      requires: [{tool: send_payment, after: approve}]
      state_checks:
        - {url: /outbox, path: items, count: 0}
        - {url: /case/D-1, path: status, equals: drafted}
        - {url: /case/D-1, path: route.queue, matches: "^fra"}
        - {url: /case/D-1, path: route.nope, exists: false}
      max_ms: 5000
  - id: inconclusive
    input: "review dispute D-2"
    expect:
      answer_must: ["(?i)inconclusive"]
      answer_must_not: ["(?i)approved"]
      tools_not_called: [draft_note]
`

func TestRunPassesAGoodSetAndIsolatesAuditPerCase(t *testing.T) {
	f := newFake(t, disputeReply)
	rep, err := Run(context.Background(), caseSet(t, goodSet), f.cfg())
	if err != nil {
		t.Fatal(err)
	}
	if rep.Total != 2 || rep.Passed != 2 || rep.Failed != 0 {
		b, _ := json.MarshalIndent(rep, "", " ")
		t.Fatalf("%s", b)
	}
	// the second case did not see the first case's draft_note: its "not called" check passed
	if got := one(t, rep, "inconclusive").Tools; len(got) != 1 || got[0] != "kb_search" {
		t.Fatalf("tools seen %v", got)
	}
}

func TestEachKindOfFailureIsReported(t *testing.T) {
	f := newFake(t, disputeReply)
	f.outbox = 1
	doc := `
cases:
  - id: bad
    agent: dispute
    input: "review dispute D-3"
    expect:
      answer_must: ["(?i)inconclusive"]
      answer_must_not: ["Paid"]
      cites: ["Chargeback Rules"]
      tools_called: [draft_note]
      tools_not_called: [send_payment]
      tool_order: [send_payment, case_get]
      requires: [{tool: send_payment, after: approve}]
      state_checks:
        - {url: /outbox, path: items, count: 0}
        - {url: /case/D-1, path: status, equals: sent}
      max_ms: 0
`
	rep, err := Run(context.Background(), caseSet(t, doc), f.cfg())
	if err != nil {
		t.Fatal(err)
	}
	c := one(t, rep, "bad")
	if c.Pass || rep.Failed != 1 {
		t.Fatalf("a bad case must fail: %+v", c)
	}
	for _, name := range []string{"answer_must[0]", "answer_must_not[0]", "cites[0]", "tools_called[draft_note]", "tools_not_called[send_payment]", "tool_order", "requires[send_payment]", "state_checks[0]", "state_checks[1]"} {
		if !failed(c, name) {
			t.Errorf("check %s should have failed: %+v", name, c.Checks)
		}
	}
}

func TestTaskStateAndGateRefusal(t *testing.T) {
	f := newFake(t, func(agent, prompt string) ([]string, string, string) {
		return nil, "x", "TASK_STATE_FAILED"
	})
	doc := `
cases:
  - {id: failed-task, agent: dispute, input: hi}
  - {id: tolerated, agent: dispute, input: hi, expect: {state: any}}
  - {id: refused, agent: forbidden, input: hi, expect: {state: any}}
`
	rep, err := Run(context.Background(), caseSet(t, doc), f.cfg())
	if err != nil {
		t.Fatalf("a refusal by the gate fails the case, not the run: %v", err)
	}
	if one(t, rep, "failed-task").Pass || !one(t, rep, "tolerated").Pass {
		t.Fatalf("state check: %+v", rep.Cases)
	}
	r := one(t, rep, "refused")
	if r.Pass || !failed(r, "request") || !strings.Contains(r.Checks[0].Detail, "403") {
		t.Fatalf("a gate refusal must show as a failed request with the status: %+v", r)
	}
}

func TestFailClosedWithoutAuditOrStateSource(t *testing.T) {
	f := newFake(t, disputeReply)
	cfg := f.cfg()
	cfg.AuditSrc, cfg.StateBase = "", ""
	doc := `
cases:
  - id: needs-audit
    agent: dispute
    input: "review dispute D-1"
    expect: {tools_called: [kb_search]}
  - id: needs-state
    agent: dispute
    input: "review dispute D-1"
    expect: {state_checks: [{url: /outbox, path: items, count: 0}]}
  - id: nothing-asked
    agent: dispute
    input: "review dispute D-1"
`
	rep, err := Run(context.Background(), caseSet(t, doc), cfg)
	if err != nil {
		t.Fatal(err)
	}
	if one(t, rep, "needs-audit").Pass || one(t, rep, "needs-state").Pass || !one(t, rep, "nothing-asked").Pass {
		t.Fatalf("a check that cannot be made must fail, not pass: %+v", rep.Cases)
	}
}

func TestEventIsSentAsJSONAndTokenStaysOutOfOutput(t *testing.T) {
	f := newFake(t, disputeReply)
	tok := filepath.Join(t.TempDir(), "tok")
	if err := os.WriteFile(tok, []byte("s3cret-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := f.cfg()
	cfg.TokenFile = tok
	doc := `
cases:
  - id: ev
    agent: dispute
    event: {type: dispute.opened, case: D-1}
    expect: {answer_must: ["fraud"]}
`
	rep, err := Run(context.Background(), caseSet(t, doc), cfg)
	if err != nil {
		t.Fatal(err)
	}
	if !one(t, rep, "ev").Pass {
		t.Fatalf("%+v", rep.Cases)
	}
	if f.token != "Bearer s3cret-token" {
		t.Fatalf("token header %q", f.token)
	}
	var sent map[string]any
	if err := json.Unmarshal([]byte(f.seen[0]), &sent); err != nil || sent["case"] != "D-1" {
		t.Fatalf("event not sent as JSON: %q", f.seen[0])
	}
	var out bytes.Buffer
	rep.WriteTable(&out)
	b, _ := json.Marshal(rep)
	if strings.Contains(out.String()+string(b), "s3cret") {
		t.Fatal("the token leaked into the output")
	}
	if strings.Contains(string(b), "fraud claim") {
		t.Fatal("the answer text must not be in the report unless asked for")
	}
	if one(t, rep, "ev").AnswerSHA == "" {
		t.Fatal("the answer hash is needed for replay")
	}
}

func TestOnlyFilterAndTable(t *testing.T) {
	f := newFake(t, disputeReply)
	cfg := f.cfg()
	cfg.Only = []string{"inconclusive"}
	rep, err := Run(context.Background(), caseSet(t, goodSet), cfg)
	if err != nil || rep.Total != 1 {
		t.Fatalf("%v %+v", err, rep)
	}
	var out bytes.Buffer
	rep.WriteTable(&out)
	if !strings.Contains(out.String(), "inconclusive") || !strings.Contains(out.String(), "PASS") {
		t.Fatalf("table: %s", out.String())
	}
	cfg.Only = []string{"no-such-case"}
	if _, err := Run(context.Background(), caseSet(t, goodSet), cfg); err == nil {
		t.Fatal("an unknown case id is a configuration error")
	}
}

func TestLoadCasesRejectsMistakes(t *testing.T) {
	bad := map[string]string{
		"unknown key":      "cases:\n  - {id: a, input: x, expect: {answer_mus: [a]}}\n",
		"duplicate id":     "cases:\n  - {id: a, input: x}\n  - {id: a, input: y}\n",
		"no id":            "cases:\n  - {input: x}\n",
		"no input":         "cases:\n  - {id: a}\n",
		"input and event":  "cases:\n  - {id: a, input: x, event: {a: 1}}\n",
		"bad regex":        "cases:\n  - {id: a, input: x, expect: {answer_must: ['(']}}\n",
		"two tests":        "cases:\n  - {id: a, input: x, expect: {state_checks: [{url: /a, equals: 1, count: 1}]}}\n",
		"no test":          "cases:\n  - {id: a, input: x, expect: {state_checks: [{url: /a}]}}\n",
		"empty set":        "cases: []\n",
		"bad outcome rule": "cases:\n  - {id: a, input: x, outcome: {labels: [{label: ok, match: '('}]}}\n",
		"bad id":           "cases:\n  - {id: 'a b', input: x}\n",
	}
	for name, doc := range bad {
		p := filepath.Join(t.TempDir(), "c.yaml")
		_ = os.WriteFile(p, []byte(doc), 0o600)
		if _, err := LoadCases(p); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
	if _, err := LoadCases(filepath.Join(t.TempDir(), "missing.yaml")); err == nil {
		t.Error("a missing file must be an error")
	}
}

func TestAuditFromURL(t *testing.T) {
	var mu sync.Mutex
	events := []map[string]string{{"tool": "old_call_before_the_run"}}
	audit := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		_ = json.NewEncoder(w).Encode(events)
	}))
	defer audit.Close()
	f := newFake(t, func(agent, prompt string) ([]string, string, string) {
		mu.Lock()
		events = append(events, map[string]string{"tool": "ops_kb_search"})
		mu.Unlock()
		return nil, "ok", ""
	})
	cfg := f.cfg()
	cfg.AuditSrc = audit.URL // the URL returns a JSON array; only events added during the case count
	doc := "cases:\n  - {id: a, agent: dispute, input: x, expect: {tools_called: [kb_search], tools_not_called: [old_call_before_the_run]}}\n"
	rep, err := Run(context.Background(), caseSet(t, doc), cfg)
	if err != nil || !one(t, rep, "a").Pass {
		t.Fatalf("%v %+v", err, rep)
	}
}

const replayDoc = `
cases:
  - id: r1
    agent: dispute
    input: "review dispute D-1"
    human_outcome: approve
    baseline_outcome: reject
    outcome: {labels: [{label: approve, match: "(?i)fraud"}, {label: reject, match: "(?i)inconclusive"}]}
  - id: r2
    agent: dispute
    input: "review dispute D-2"
    human_outcome: reject
    baseline_outcome: reject
    outcome: {labels: [{label: approve, match: "(?i)fraud"}, {label: reject, match: "(?i)inconclusive"}]}
`

func TestAgreementAgainstHumanAndBaseline(t *testing.T) {
	f := newFake(t, disputeReply)
	rep, err := Run(context.Background(), caseSet(t, replayDoc), f.cfg())
	if err != nil {
		t.Fatal(err)
	}
	a := rep.Agreement
	if a == nil || a.Cases != 2 || a.Agent != 2 || a.Baseline != 1 || a.AgentRate != 1 || a.BaselineRate != 0.5 {
		t.Fatalf("agreement %+v", a)
	}
	if one(t, rep, "r1").Outcome != "approve" || one(t, rep, "r2").Outcome != "reject" {
		t.Fatalf("outcomes %+v", rep.Cases)
	}
}

func TestReportRoundTripAndCompare(t *testing.T) {
	f := newFake(t, disputeReply)
	cs := caseSet(t, replayDoc)
	old, err := Run(context.Background(), cs, f.cfg())
	if err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(t.TempDir(), "rep.json")
	b, _ := json.Marshal(old)
	_ = os.WriteFile(p, b, 0o600)
	loaded, err := LoadReport(p)
	if err != nil || loaded.Total != 2 {
		t.Fatalf("%v %+v", err, loaded)
	}

	// same agent again: nothing changes
	again, _ := Run(context.Background(), cs, f.cfg())
	d := Compare(loaded, again)
	if d.Regressions != 0 || d.AgreementDrop {
		t.Fatalf("%+v", d)
	}
	for _, c := range d.Changes {
		if c.Kind != "same" {
			t.Fatalf("unexpected change %+v", c)
		}
	}

	// the agent now answers D-1 differently: the outcome flips, so agreement drops and the case regresses
	g := newFake(t, func(agent, prompt string) ([]string, string, string) {
		return []string{"kb_search"}, "Inconclusive.", ""
	})
	worse, _ := Run(context.Background(), cs, g.cfg())
	d = Compare(loaded, worse)
	if !d.AgreementDrop {
		t.Fatalf("agreement fell from 1 to 0.5, flag it: %+v", d)
	}
	kinds := map[string]string{}
	for _, c := range d.Changes {
		kinds[c.ID] = c.Kind
	}
	if kinds["r1"] != "changed" || kinds["r2"] != "changed" {
		// r2 answer text differs too ("Inconclusive." versus the longer one), so both are changed
		t.Fatalf("%+v", d.Changes)
	}
}

func TestCompareClassifiesPassFailAndMissing(t *testing.T) {
	mk := func(pass bool, sha string) CaseResult {
		return CaseResult{ID: "", Pass: pass, AnswerSHA: sha}
	}
	a, b, c, d := mk(true, "1"), mk(false, "1"), mk(true, "1"), mk(true, "1")
	a.ID, b.ID, c.ID, d.ID = "regress", "fix", "gone", "same"
	old := &Report{Cases: []CaseResult{a, b, c, d}}
	nw := mk(false, "1")
	nw.ID = "regress"
	fx := mk(true, "1")
	fx.ID = "fix"
	sm := mk(true, "1")
	sm.ID = "same"
	nu := mk(true, "9")
	nu.ID = "brand-new"
	cur := &Report{Cases: []CaseResult{nw, fx, sm, nu}}
	df := Compare(old, cur)
	kinds := map[string]string{}
	for _, ch := range df.Changes {
		kinds[ch.ID] = ch.Kind
	}
	want := map[string]string{"regress": "regression", "fix": "fixed", "gone": "missing", "same": "same", "brand-new": "new"}
	for id, k := range want {
		if kinds[id] != k {
			t.Errorf("%s: %q, want %q", id, kinds[id], k)
		}
	}
	if df.Regressions != 1 {
		t.Errorf("regressions %d", df.Regressions)
	}
}

// max_tool_calls: a run that makes more tool calls than the case allows fails, so a steered extra call is seen even when the tool is allowed.
func TestMaxToolCallsLimitsTheCallsOfOneRun(t *testing.T) {
	f := newFake(t, disputeReply)
	doc := `
cases:
  - id: enough
    agent: dispute
    input: "review dispute D-1"
    expect:
      max_tool_calls: 3
  - id: too-few
    agent: dispute
    input: "review dispute D-1"
    expect:
      max_tool_calls: 2
  - id: no-audit-needed-without-it
    agent: dispute
    input: "review dispute D-2"
    expect:
      answer_must: ["(?i)inconclusive"]
`
	rep, err := Run(context.Background(), caseSet(t, doc), f.cfg())
	if err != nil {
		t.Fatal(err)
	}
	if c := one(t, rep, "enough"); !c.Pass {
		t.Fatalf("three calls with a limit of three must pass: %+v", c.Checks)
	}
	if c := one(t, rep, "too-few"); c.Pass || !failed(c, "max_tool_calls") {
		t.Fatalf("three calls with a limit of two must fail max_tool_calls: %+v", c.Checks)
	}
	if c := one(t, rep, "no-audit-needed-without-it"); !c.Pass {
		t.Fatalf("a case without the field needs no audit: %+v", c.Checks)
	}
	cfg := f.cfg()
	cfg.AuditSrc = ""
	rep, _ = Run(context.Background(), caseSet(t, doc), cfg)
	if c := one(t, rep, "enough"); c.Pass || !failed(c, "audit") {
		t.Fatalf("with no audit source the limit cannot be checked, so the case fails: %+v", c.Checks)
	}
}
