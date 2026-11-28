package harness

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// ADR 0028: a state check can carry when_answer, a regular expression over the answer. The check runs only when the answer matches it. So "when the
// answer says a request is pending, a pending request must exist" is one rule.

func TestWhenAnswerRunsTheCheckOnlyWhenTheAnswerMatches(t *testing.T) {
	f := newFake(t, func(agent, prompt string) ([]string, string, string) {
		if strings.Contains(prompt, "D-1") {
			return nil, "The request is pending approval.", ""
		}
		return nil, "No request is waiting.", ""
	})
	f.outbox = 0 // nothing is queued: a check that wants one fails when it runs
	set := `
agent: dispute
cases:
  - id: says-pending
    input: "review dispute D-1"
    expect:
      state_checks:
        - {url: /outbox, path: items, count: 1, when_answer: "(?i)is pending approval"}
  - id: says-nothing
    input: "review dispute D-2"
    expect:
      state_checks:
        - {url: /outbox, path: items, count: 1, when_answer: "(?i)is pending approval"}
`
	rep, err := Run(context.Background(), caseSet(t, set), f.cfg())
	if err != nil {
		t.Fatal(err)
	}
	a := one(t, rep, "says-pending")
	if a.Pass || !failed(a, "state_checks[0]") {
		t.Fatalf("the answer says pending and nothing is pending: the check must run and fail: %+v", a)
	}
	b := one(t, rep, "says-nothing")
	if !b.Pass {
		t.Fatalf("the answer does not say pending: the check does not run, so the case passes: %+v", b)
	}
	shown := false
	for _, k := range b.Checks {
		shown = shown || (k.Name == "state_checks[0]" && k.Pass && strings.Contains(k.Detail, "not applied"))
	}
	if !shown {
		t.Fatalf("a check that was not applied is shown as such, not left out: %+v", b.Checks)
	}
}

func TestWhenAnswerWithABadPatternIsRefusedAtLoad(t *testing.T) {
	p := filepath.Join(t.TempDir(), "c.yaml")
	doc := "cases:\n  - id: a\n    input: x\n    expect:\n      state_checks:\n        - {url: /x, path: s, equals: a, when_answer: '('}\n"
	if err := os.WriteFile(p, []byte(doc), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := LoadCases(p)
	if err == nil || !strings.Contains(err.Error(), "when_answer") {
		t.Fatalf("a bad pattern must be refused and name when_answer: %v", err)
	}
	// and the command exits 2 for it (a bad file is a bad setup)
}

// The real answers of the first real-model run of the bank, against the rule as the bank sets carry it. The defect: the agent retried a write after the
// request, the write superseded it, and the answer still said the request was pending. The record then has no pending request.
func TestWhenAnswerCatchesTheRealAnswerOfTheBankDefect(t *testing.T) {
	cs, err := LoadCases("../../../../examples/use-cases/bank/eval/cases-real.yaml")
	if err != nil {
		t.Fatal(err)
	}
	var e Expect
	for _, c := range cs.Cases {
		if c.ID == "out-of-time-declined" {
			e = c.Expect
		}
	}
	idx := -1
	for i, s := range e.StateChecks {
		if s.WhenAnswer != "" {
			idx = i
		}
	}
	if idx < 0 {
		t.Fatal("the bank set for a real model has no state check with when_answer on out-of-time-declined")
	}
	// the record the second case of the defect run left: the request is superseded, so the pending list is empty
	srv := func(pending bool) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			body := `{"approvals":[]}`
			if pending {
				body = `{"approvals":[{"id":"APR-0001","status":"pending","kind":"decline"}]}`
			}
			_, _ = w.Write([]byte(body))
		}))
	}
	read := func(name string) string {
		b, err := os.ReadFile(filepath.Join("testdata/pending-answers", name))
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	run := func(answer string, pending bool) Check {
		s := srv(pending)
		defer s.Close()
		got := stateChecks(context.Background(), http.DefaultClient, e, s.URL, "", answer)
		return got[idx]
	}
	if c := run(read("bank__out-of-time-declined__defect1-superseded.txt"), false); c.Pass {
		t.Errorf("the real answer of the defect (it says the request is pending, the record has none) must FAIL the rule: %+v", c)
	}
	if c := run(read("bank__out-of-time-declined__pending-and-true.txt"), true); !c.Pass || strings.Contains(c.Detail, "not applied") {
		t.Errorf("a real answer that says pending, with a request that is pending, passes the rule (it ran): %+v", c)
	}
	// an answer that says the request is NOT pending is not held to the rule, in any of its phrasings
	for _, f := range []string{"bank__out-of-time-declined__no-longer-pending.txt", "bank__out-of-time-declined__not-pending.txt"} {
		if c := run(read(f), false); !c.Pass || !strings.Contains(c.Detail, "not applied") {
			t.Errorf("%s: an answer that says the request is no longer or not pending is correct and must not fail: %+v", f, c)
		}
	}
}
