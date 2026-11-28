package harness

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Checks that hold for a real model: a set of allowed tools, a floor on tool calls, one of several final states,
// and a claim check that ignores a claim the answer denies. Each test fails first against the tool as it was.

func checkNamed(cs []Check, name string) (Check, bool) {
	for _, c := range cs {
		if c.Name == name {
			return c, true
		}
	}
	return Check{}, false
}

func TestToolsOnlyAllowsAnySubsetAndNamesTheOffender(t *testing.T) {
	e := Expect{ToolsOnly: []string{"pods_get", "pods_list_in_namespace", "events_list"}}
	// any subset, any order, repeats: pass. A profile prefix is allowed.
	got := toolChecks(e, []string{"cluster-read_events_list", "pods_get", "pods_get"}, nil)
	if c, ok := checkNamed(got, "tools_only"); !ok || !c.Pass {
		t.Fatalf("a subset of the allowed tools must pass: %+v", got)
	}
	// no call at all passes this check (min_tool_calls is the check for "at least one")
	if c, ok := checkNamed(toolChecks(e, nil, nil), "tools_only"); !ok || !c.Pass {
		t.Fatalf("no calls must pass tools_only: %+v", c)
	}
	bad := toolChecks(e, []string{"pods_get", "pods_exec"}, nil)
	c, ok := checkNamed(bad, "tools_only")
	if !ok || c.Pass || !strings.Contains(c.Detail, "pods_exec") {
		t.Fatalf("a tool outside the list must fail and be named: %+v", bad)
	}
	// without an audit the check cannot be made, so it fails
	noAudit := toolChecks(e, nil, os.ErrNotExist)
	if c, ok := checkNamed(noAudit, "tools_only"); !ok || c.Pass {
		t.Fatalf("tools_only without an audit must fail: %+v", noAudit)
	}
}

func TestMinToolCalls(t *testing.T) {
	two := 2
	e := Expect{MinToolCalls: &two}
	if c, _ := checkNamed(toolChecks(e, []string{"a", "b", "c"}, nil), "min_tool_calls"); !c.Pass {
		t.Errorf("three calls must satisfy a floor of two: %+v", c)
	}
	c, ok := checkNamed(toolChecks(e, []string{"a"}, nil), "min_tool_calls")
	if !ok || c.Pass || !strings.Contains(c.Detail, "1 tool calls") {
		t.Errorf("one call must fail a floor of two and say how many: %+v", c)
	}
	if c, ok := checkNamed(toolChecks(e, nil, os.ErrNotExist), "min_tool_calls"); !ok || c.Pass {
		t.Errorf("without an audit the floor cannot be shown: %+v", c)
	}
	for name, v := range map[string]string{"zero": "0", "negative": "-1"} {
		p := filepath.Join(t.TempDir(), "c.yaml")
		doc := "cases:\n  - {id: a, input: x, expect: {min_tool_calls: " + v + "}}\n"
		if err := os.WriteFile(p, []byte(doc), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadCases(p); err == nil || !strings.Contains(err.Error(), "min_tool_calls") {
			t.Errorf("%s: want an error that names min_tool_calls, got %v", name, err)
		}
	}
}

func TestAnswerClaimsNotIgnoresADeniedClaim(t *testing.T) {
	claim := `(?i)\b(credit|refund)\b[^.]{0,30}\b(was|has been|is) (posted|issued|approved)`
	e := Expect{AnswerClaimsNot: []string{claim}}
	pass := []string{
		"No credit has been posted.",
		"The letter is a draft and no credit has been posted yet.",
		"I cannot say the refund is approved: a person decides.",
		"Nothing moved. The credit will be posted once the approver decides.",
		"The refund isn't approved, and the credit hasn't been posted.",
		"All clear.",
	}
	for _, a := range pass {
		if c := answerChecks(e, a); len(c) != 1 || !c[0].Pass {
			t.Errorf("a denied claim must pass: %q -> %+v", a, c)
		}
	}
	fail := []string{
		"The credit was posted to the account.",
		"Letter drafted. The refund is approved.",
		"No letter was sent, but the credit was posted.", // the denial belongs to another clause
		"CREDIT HAS BEEN POSTED",
	}
	for _, a := range fail {
		c := answerChecks(e, a)
		if len(c) != 1 || c[0].Pass {
			t.Errorf("a claim must fail: %q -> %+v", a, c)
		}
		if len(c) == 1 && c[0].Detail != claim {
			t.Errorf("the detail must name the rule, not echo the answer: %+v", c[0])
		}
	}
	// a bad expression is refused when the set is loaded
	p := filepath.Join(t.TempDir(), "c.yaml")
	if err := os.WriteFile(p, []byte("cases:\n  - {id: a, input: x, expect: {answer_claims_not: ['(']}}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadCases(p); err == nil || !strings.Contains(err.Error(), "regular expression") {
		t.Errorf("a bad expression must be refused at load: %v", err)
	}
}

func TestStateCheckOneOf(t *testing.T) {
	f := newFake(t, disputeReply)
	set := `
cases:
  - id: oneof
    agent: dispute
    input: "review dispute D-1"
    expect:
      state_checks:
        - {url: /case/D-1, path: status, one_of: [drafted, pending_approval]}
        - {url: /case/D-1, path: status, one_of: [open, closed]}
`
	rep, err := Run(context.Background(), caseSet(t, set), f.cfg())
	if err != nil {
		t.Fatal(err)
	}
	r := one(t, rep, "oneof")
	var first, second Check
	for _, k := range r.Checks {
		switch k.Name {
		case "state_checks[0]":
			first = k
		case "state_checks[1]":
			second = k
		}
	}
	if !first.Pass {
		t.Errorf("the value is one of the list: %+v", first)
	}
	if second.Pass || strings.Contains(second.Detail, "drafted") {
		t.Errorf("the value is not in the list, and the detail must not copy the value: %+v", second)
	}
	// exactly one test per state check: one_of together with equals is refused
	p := filepath.Join(t.TempDir(), "c.yaml")
	doc := "cases:\n  - id: a\n    input: x\n    expect:\n      state_checks:\n        - {url: /x, path: s, equals: a, one_of: [a, b]}\n"
	if err := os.WriteFile(p, []byte(doc), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadCases(p); err == nil || !strings.Contains(err.Error(), "exactly one") {
		t.Errorf("one_of with equals must be refused: %v", err)
	}
	// an empty list is refused too
	doc = "cases:\n  - id: a\n    input: x\n    expect:\n      state_checks:\n        - {url: /x, path: s, one_of: []}\n"
	if err := os.WriteFile(p, []byte(doc), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadCases(p); err == nil {
		t.Errorf("an empty one_of must be refused")
	}
}
