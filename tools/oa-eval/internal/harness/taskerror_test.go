package harness

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A task that does not end COMPLETED carries a failure message in its status. The real run showed the gap: a case ended FAILED at the edge of the budget,
// its report held only the state, and the cause could not be told. The report now records the message, a refusal of the model call is read from the status
// message as well as from the answer text and whether or not tools were called before it, and a failed task with no recognisable cause is its own class.

type taskGate struct {
	t     *testing.T
	srv   *httptest.Server
	audit string
	// what the gate answers
	state    string
	artifact string // the text the agent streamed (its own narration)
	status   string // the failure message of the task status
	tools    int    // tool calls the agent made (written to the audit file)
}

func newTaskGate(t *testing.T, state, artifact, status string, tools int) *taskGate {
	t.Helper()
	g := &taskGate{t: t, state: state, artifact: artifact, status: status, tools: tools, audit: filepath.Join(t.TempDir(), "audit.jsonl")}
	if err := os.WriteFile(g.audit, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	g.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fh, _ := os.OpenFile(g.audit, os.O_APPEND|os.O_WRONLY, 0o600)
		for i := 0; i < g.tools; i++ {
			_, _ = fh.WriteString(`{"tool":"kb_search"}` + "\n")
		}
		_ = fh.Close()
		task := map[string]any{"status": map[string]any{"state": g.state}}
		if g.status != "" {
			task["status"].(map[string]any)["message"] = map[string]any{"parts": []any{map[string]string{"text": g.status}}}
		}
		if g.artifact != "" {
			task["artifacts"] = []any{map[string]any{"parts": []any{map[string]string{"text": g.artifact}}}}
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1, "result": map[string]any{"task": task}})
	}))
	t.Cleanup(g.srv.Close)
	return g
}

func (g *taskGate) run(t *testing.T) CaseResult {
	t.Helper()
	cs := caseSet(t, "agent: dispute\ncases:\n  - {id: c, input: hello, expect: {answer_must: [\"(?i)fraud\"]}}\n")
	rep, err := Run(context.Background(), cs, Config{GateURL: g.srv.URL, UserID: "eval:test", AuditSrc: g.audit, Timeout: 5 * time.Second, AuditSettle: time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	return rep.Cases[0]
}

const budgetMsg = "agent run failed: OpenAI chat completion request failed: OpenAI API error: 429 Too Many Requests"

func TestA429InTheStatusMessageIsNotRunEvenWhenTheAgentStreamedText(t *testing.T) {
	// the agent narrated, then the model call was refused: the artifact text is the narration, the refusal is only in the status message
	r := newTaskGate(t, "TASK_STATE_FAILED", "I can't skip the checks. I'm starting with the case record.", budgetMsg, 0).run(t)
	if !r.NotRun || !strings.Contains(r.NotRunReason, "429") {
		t.Fatalf("a refusal in the status message makes the case not run: %+v", r)
	}
	if !strings.Contains(r.TaskError, "429") {
		t.Fatalf("the failure message is recorded in the report: %+v", r)
	}
}

func TestA429AfterToolCallsIsNotRunAndSaysHowManyCalls(t *testing.T) {
	r := newTaskGate(t, "TASK_STATE_FAILED", "Reading the case.", budgetMsg, 3).run(t)
	if !r.NotRun || !strings.Contains(r.NotRunReason, "3 tool calls before it") {
		t.Fatalf("a refusal after tool calls is not run, with the number of calls: %+v", r)
	}
}

func TestAFailedTaskWithAnotherMessageIsAFailureWithItsCauseRecorded(t *testing.T) {
	r := newTaskGate(t, "TASK_STATE_FAILED", "Working.", "agent run failed: the tool call was malformed", 2).run(t)
	if r.NotRun || r.Pass || r.NoCause {
		t.Fatalf("a failure with a recorded cause that is not a refusal: %+v", r)
	}
	if r.TaskError != "agent run failed: the tool call was malformed" {
		t.Fatalf("the cause is recorded: %q", r.TaskError)
	}
}

func TestAFailedTaskWithNoMessageIsFailedCauseNotRecorded(t *testing.T) {
	g := newTaskGate(t, "TASK_STATE_FAILED", "I can't skip the checks. I'm starting with the case record.", "", 2)
	r := g.run(t)
	if r.NotRun || r.Pass || !r.NoCause || r.TaskError != "" {
		t.Fatalf("no recognisable cause: it is a failure of its own class, and not a refusal: %+v", r)
	}
	// the report and the table keep it apart from check failures
	cs := caseSet(t, "agent: dispute\ncases:\n  - {id: c, input: hello, expect: {answer_must: [\"(?i)fraud\"]}}\n")
	rep, _ := Run(context.Background(), cs, Config{GateURL: g.srv.URL, UserID: "eval:test", AuditSrc: g.audit, Timeout: 5 * time.Second, AuditSettle: time.Millisecond})
	if rep.Failed != 1 || rep.NoCause != 1 {
		t.Fatalf("it counts as a failure and is counted apart: %+v", rep)
	}
	var table strings.Builder
	rep.WriteTable(&table)
	if !strings.Contains(table.String(), "FAIL (cause not recorded)") || !strings.Contains(table.String(), "1 of them ended as a failed task with no cause recorded") {
		t.Fatalf("the table shows it apart:\n%s", table.String())
	}
}

func TestACompletedTaskRecordsNoTaskError(t *testing.T) {
	r := newTaskGate(t, "TASK_STATE_COMPLETED", "A fraud claim.", "", 1).run(t)
	if r.TaskError != "" || r.NoCause || r.NotRun || !r.Pass {
		t.Fatalf("a completed task has no failure message: %+v", r)
	}
}

func TestTheRecordedMessageIsShortAndHasNoQuestionOrAnswerText(t *testing.T) {
	long := "agent run failed: " + strings.Repeat("x", 2000)
	r := newTaskGate(t, "TASK_STATE_FAILED", "the narration of the agent that must not be in the message", long, 0).run(t)
	if len(r.TaskError) > 300 || strings.Contains(r.TaskError, "narration") {
		t.Fatalf("the failure message is truncated and is only the status message: %d %q", len(r.TaskError), r.TaskError[:40])
	}
	if strings.Contains(r.TaskError, "hello") {
		t.Fatal("the user's message must not be in the recorded failure")
	}
}

func TestOnlyAFailedTaskIsReadForARefusal(t *testing.T) {
	// a REJECTED or CANCELED task records its message but is not a model refusal
	r := newTaskGate(t, "TASK_STATE_CANCELED", "", budgetMsg, 0).run(t)
	if r.NotRun || r.TaskError == "" {
		t.Fatalf("a task that is not FAILED records its message and is not a refusal: %+v", r)
	}
}
