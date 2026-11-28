package harness

import (
	"context"
	"strings"
	"testing"
)

// A budget or provider refusal is not an agent failure. A task that ends FAILED with a model-call error and no tool call is NOT RUN: it is left out
// of the pass rate, and the cases after it are not sent (they would be refused too and burn the rest of the run).

const refusal = "agent run failed: OpenAI chat completion request failed: OpenAI API error: 429 Too Many Requests"

const threeCases = `
agent: dispute
cases:
  - {id: first, input: "review dispute D-1", expect: {answer_must: ["(?i)fraud"]}}
  - {id: second, input: "review dispute D-2", expect: {answer_must: ["(?i)fraud"]}}
  - {id: third, input: "review dispute D-2", expect: {answer_must: ["(?i)fraud"]}}
`

func TestARefusedModelCallIsNotRunAndStopsTheRest(t *testing.T) {
	f := newFake(t, func(agent, prompt string) ([]string, string, string) {
		if strings.Contains(prompt, "D-2") {
			return nil, refusal, "TASK_STATE_FAILED"
		}
		return []string{"kb_search"}, "A fraud claim.", ""
	})
	rep, err := Run(context.Background(), caseSet(t, threeCases), f.cfg())
	if err != nil {
		t.Fatal(err)
	}
	if rep.Total != 3 || rep.Passed != 1 || rep.Failed != 0 || rep.NotRun != 2 {
		t.Fatalf("want 3 cases, 1 passed, 0 failed, 2 not run: %+v", rep)
	}
	second := one(t, rep, "second")
	if !second.NotRun || second.Pass || !strings.Contains(second.NotRunReason, "429") {
		t.Fatalf("a 429 is not run, with the reason: %+v", second)
	}
	third := one(t, rep, "third")
	if !third.NotRun || !strings.Contains(third.NotRunReason, "not sent") {
		t.Fatalf("the case after a refusal is not sent: %+v", third)
	}
	if len(f.seen) != 2 {
		t.Fatalf("only two prompts may reach the agent (the third is not sent), got %d", len(f.seen))
	}
	var table strings.Builder
	rep.WriteTable(&table)
	if !strings.Contains(table.String(), "NOT RUN") || !strings.Contains(table.String(), "2 not run") {
		t.Fatalf("the table must show it:\n%s", table.String())
	}
}

func TestARefusalInTheMiddleOfACaseIsNotRunToo(t *testing.T) {
	// the budget runs out during a case: the agent made tool calls, then the model refused the next call
	f := newFake(t, func(agent, prompt string) ([]string, string, string) {
		return []string{"kb_search", "case_get"}, refusal, "TASK_STATE_FAILED"
	})
	rep, err := Run(context.Background(), caseSet(t, threeCases), f.cfg())
	if err != nil {
		t.Fatal(err)
	}
	if rep.NotRun != 3 || rep.Failed != 0 {
		t.Fatalf("a model refusal is not run whenever it comes: %+v", rep)
	}
	if first := one(t, rep, "first"); !strings.Contains(first.NotRunReason, "2 tool calls before it") {
		t.Fatalf("the reason says how many calls the case made: %q", first.NotRunReason)
	}
}

func TestAFailedTaskWithAnotherReasonIsAFailure(t *testing.T) {
	f := newFake(t, func(agent, prompt string) ([]string, string, string) {
		return nil, "agent run failed: the tool call was malformed", "TASK_STATE_FAILED"
	})
	rep, err := Run(context.Background(), caseSet(t, threeCases), f.cfg())
	if err != nil {
		t.Fatal(err)
	}
	if rep.NotRun != 0 || rep.Failed != 3 {
		t.Fatalf("only a model-call refusal is not run: %+v", rep)
	}
}

func TestRefusalWordsInACompletedAnswerAreNotARefusal(t *testing.T) {
	f := newFake(t, func(agent, prompt string) ([]string, string, string) {
		return nil, "The vendor API said 429 Too Many Requests, so this is inconclusive.", ""
	})
	rep, err := Run(context.Background(), caseSet(t, threeCases), f.cfg())
	if err != nil {
		t.Fatal(err)
	}
	if rep.NotRun != 0 {
		t.Fatalf("a completed task is never not run: %+v", rep)
	}
}

func TestOtherProviderRefusalsAreRecognised(t *testing.T) {
	for _, text := range []string{
		"agent run failed: OpenAI chat completion request failed: OpenAI API error: 401 Unauthorized",
		"agent run failed: OpenAI chat completion request failed: OpenAI API error: 503 Service Unavailable",
		"agent run failed: rate limit exceeded",
	} {
		if refusalReason(text) == "" {
			t.Errorf("%q must be read as a model-call error", text)
		}
	}
	if refusalReason("agent run failed: the tool call was malformed") != "" {
		t.Error("a malformed tool call is not a model-call error")
	}
}
