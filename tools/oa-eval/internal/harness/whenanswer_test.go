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

// The pending-answers fixtures, against the rule as the bank set for a real model carries it. File names say what the answer does:
//
//	claims-*  says the request is pending (the real answer of the first real-model defect, and other ways to word the same false claim). With no pending
//	          request in the record the rule must FAIL it, and it must be applied (not skipped).
//	true-*    says it is pending and a request is pending: the rule runs and passes.
//	denies-*  says the request is NOT pending (correct after a superseded request): the rule is not applied, so the case is not failed.
func TestWhenAnswerOnTheFixtures(t *testing.T) {
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
	srv := func(pending bool) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			body := `{"approvals":[]}`
			if pending {
				body = `{"approvals":[{"id":"APR-0001","status":"pending","kind":"decline"}]}`
			}
			_, _ = w.Write([]byte(body))
		}))
	}
	run := func(answer string, pending bool) Check {
		s := srv(pending)
		defer s.Close()
		return stateChecks(context.Background(), http.DefaultClient, e, s.URL, "", answer)[idx]
	}
	files, _ := filepath.Glob("testdata/pending-answers/*.txt")
	counts := map[string]int{}
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		name := filepath.Base(f)
		parts := strings.Split(strings.TrimSuffix(name, ".txt"), "__")
		kind := strings.SplitN(parts[len(parts)-1], "-", 2)[0]
		counts[kind]++
		switch kind {
		case "claims":
			if c := run(string(b), false); c.Pass || strings.Contains(c.Detail, "not applied") {
				t.Errorf("%s: the answer says a request is pending and none is: the rule must run and FAIL: %+v", name, c)
			}
		case "true":
			if c := run(string(b), true); !c.Pass || strings.Contains(c.Detail, "not applied") {
				t.Errorf("%s: the answer says pending and a request is pending: the rule runs and passes: %+v", name, c)
			}
		case "denies":
			if c := run(string(b), false); !c.Pass || !strings.Contains(c.Detail, "not applied") {
				t.Errorf("%s: the answer says no request is pending: the rule is not applied and the case is not failed: %+v", name, c)
			}
		default:
			t.Errorf("%s: the name must say claims, true or denies", name)
		}
	}
	if counts["claims"] < 8 || counts["denies"] < 5 || counts["true"] < 1 {
		t.Errorf("the fixtures are too few to mean anything: %v", counts)
	}
}
