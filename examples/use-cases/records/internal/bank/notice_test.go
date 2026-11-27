package bank

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

// The first real-model run (issue 229): the agent requested an approval, then retried an evidence write. The write superseded the request, and the agent
// still told the person that the request was pending. The record now says so in the result of the write, and the approval result says what supersedes it.

func askedForApproval(t *testing.T, d *Domain) (caseID, approvalID string) {
	t.Helper()
	s := mcpSession(t, d)
	c := firstOpenCase(t, d)
	for _, step := range []struct {
		tool string
		args map[string]any
	}{
		{"set_route", map[string]any{"case_id": c.ID, "route": RouteDecline, "reason": "out of time"}},
		{"draft_letter", map[string]any{"case_id": c.ID, "body": "Dear customer, the dispute is out of time."}},
	} {
		if out, isErr := call(t, s, step.tool, step.args); isErr {
			t.Fatalf("%s: %s", step.tool, out)
		}
	}
	out, isErr := call(t, s, "request_approval", map[string]any{"case_id": c.ID, "kind": RouteDecline, "amount_cents": 0})
	if isErr {
		t.Fatalf("request_approval: %s", out)
	}
	ps, err := d.approvals.List(context.Background(), "pending", c.ID)
	if err != nil || len(ps) != 1 {
		t.Fatalf("pending approvals: %v %v", ps, err)
	}
	return c.ID, ps[0].ID
}

func TestAWriteAfterTheRequestTellsTheAgentThatItSupersededTheRequest(t *testing.T) {
	writes := map[string]func(id string) (string, map[string]any){
		"attach_evidence": func(id string) (string, map[string]any) {
			return "attach_evidence", map[string]any{"case_id": id, "kind": "gap", "ref": id, "note": "a late note"}
		},
		"set_route": func(id string) (string, map[string]any) {
			return "set_route", map[string]any{"case_id": id, "route": RouteDecline, "reason": "again"}
		},
		"set_case_status": func(id string) (string, map[string]any) {
			return "set_case_status", map[string]any{"case_id": id, "status": "in_review"}
		},
		"draft_letter": func(id string) (string, map[string]any) {
			return "draft_letter", map[string]any{"case_id": id, "body": "A new letter."}
		},
	}
	for name, w := range writes {
		t.Run(name, func(t *testing.T) {
			d, _ := newDomain(t)
			caseID, apr := askedForApproval(t, d)
			s := mcpSession(t, d)
			tool, args := w(caseID)
			out, isErr := call(t, s, tool, args)
			if isErr {
				t.Fatalf("%s: %s", tool, out)
			}
			for _, want := range []string{"notice", apr, "superseded", "request_approval"} {
				if !strings.Contains(out, want) {
					t.Errorf("the result of %s must say %q: %s", tool, want, out)
				}
			}
			a, _ := d.approvals.Get(context.Background(), apr)
			if a.Status != "superseded" {
				t.Fatalf("the approval is %s, want superseded", a.Status)
			}
		})
	}
}

func TestAWriteWithNoPendingRequestHasNoNotice(t *testing.T) {
	d, _ := newDomain(t)
	s := mcpSession(t, d)
	c := firstOpenCase(t, d)
	out, isErr := call(t, s, "attach_evidence", map[string]any{"case_id": c.ID, "kind": "gap", "ref": c.ID, "note": "a note"})
	if isErr || strings.Contains(out, "notice") || strings.Contains(out, "superseded") {
		t.Fatalf("no request was pending, so there is no notice: %v %s", isErr, out)
	}
}

func TestTheApprovalResultSaysWhatSupersedesIt(t *testing.T) {
	d, _ := newDomain(t)
	s := mcpSession(t, d)
	c := firstOpenCase(t, d)
	call(t, s, "set_route", map[string]any{"case_id": c.ID, "route": RouteDecline, "reason": "out of time"})
	call(t, s, "draft_letter", map[string]any{"case_id": c.ID, "body": "Dear customer."})
	out, isErr := call(t, s, "request_approval", map[string]any{"case_id": c.ID, "kind": RouteDecline, "amount_cents": 0})
	if isErr {
		t.Fatal(out)
	}
	for _, want := range []string{"supersedes", "last", "get_approval"} {
		if !strings.Contains(out, want) {
			t.Errorf("the result of request_approval must say %q: %s", want, out)
		}
	}
}

// The limits and the allowed values are in the tool descriptions, so a model does not learn them from a refusal.
func TestToolDescriptionsStateTheLimitsAndTheAllowedValues(t *testing.T) {
	d, _ := newDomain(t)
	s := mcpSession(t, d)
	list, err := s.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	text := map[string]string{}
	for _, tl := range list.Tools {
		b, _ := tl.InputSchema.(map[string]any)
		text[tl.Name] = tl.Description + " " + toJSON(b)
	}
	want := map[string][]string{
		"set_route":        {"500 characters"},
		"attach_evidence":  {"transaction", "rule", "linked_case", "gap", "other", "64 characters", "1000 characters"},
		"draft_letter":     {"4000 characters"},
		"draft_chargeback": {"4000 characters"},
		"request_approval": {"supersedes"},
	}
	for tool, ws := range want {
		for _, w := range ws {
			if !strings.Contains(text[tool], w) {
				t.Errorf("the description or schema of %s must contain %q: %s", tool, w, text[tool])
			}
		}
	}
}

func toJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}
