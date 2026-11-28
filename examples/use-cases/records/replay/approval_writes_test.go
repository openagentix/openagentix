package replay

import (
	"context"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// ADR 0028 and the review of PR 268: every write tool of both services is called while a request is pending, and the result must name the request exactly
// when the write superseded it. A future write tool that supersedes and forgets to report it fails here. A write tool that is not in a table below fails too:
// add it, with arguments that make it succeed (or be refused), so that it is exercised.

type writeSetup func(t *testing.T) (sess *mcp.ClientSession, pendingID string, statusOf func(id string) string)

func writeToolNames(t *testing.T, sess *mcp.ClientSession) []string {
	t.Helper()
	list, err := sess.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, tl := range list.Tools {
		if tl.Annotations == nil || !tl.Annotations.ReadOnlyHint {
			names = append(names, tl.Name)
		}
	}
	return names
}

func checkEveryWriteTool(t *testing.T, domain string, table map[string]map[string]any, setup writeSetup) {
	t.Helper()
	rs := loadApprovalSchema(t)
	sess0, _, _ := setup(t)
	for _, name := range writeToolNames(t, sess0) {
		if _, ok := table[name]; !ok {
			t.Errorf("%s: the write tool %s is not in the table of this test: add it with arguments that make it succeed, so that it is checked", domain, name)
		}
	}
	superseding := 0
	for name, args := range table {
		name, args := name, args
		t.Run(domain+"/"+name, func(t *testing.T) {
			sess, id, statusOf := setup(t)
			res, err := sess.CallTool(context.Background(), &mcp.CallToolParams{Name: name, Arguments: args})
			if err != nil {
				t.Fatal(err)
			}
			superseded := statusOf(id) == "superseded"
			if res.IsError {
				if superseded {
					t.Errorf("%s refused the call and still superseded %s", name, id)
				}
				return
			}
			var sb strings.Builder
			for _, c := range res.Content {
				if tc, ok := c.(*mcp.TextContent); ok {
					sb.WriteString(tc.Text)
				}
			}
			m := validateResult(t, rs, name, toolResult{Name: name, Text: sb.String(), Structured: res.StructuredContent})
			got, has := m["superseded_approvals"]
			if superseded {
				superseding++
				if !has || !reflect.DeepEqual(got, []any{id}) {
					t.Errorf("%s superseded %s and its result says %v", name, id, got)
				}
			} else if has {
				t.Errorf("%s did not supersede anything and its result says %v", name, got)
			}
		})
	}
	// the loop is not vacuous: several writes of each service really supersede (they run one after the other, so the count is complete here)
	if superseding < 4 {
		t.Errorf("%s: only %d write tools superseded the pending request in this test; the table or the setup does not exercise the writes", domain, superseding)
	}
}

func TestEveryWriteToolOfTheBankReportsWhatItSuperseded(t *testing.T) {
	future := time.Now().UTC().Add(48 * time.Hour).Format(time.RFC3339)
	table := map[string]map[string]any{
		"attach_evidence":  {"case_id": "DSP-2026-0001", "kind": "other", "ref": "w1", "note": "a write"},
		"set_route":        {"case_id": "DSP-2026-0001", "route": "provisional_credit_then_chargeback", "reason": "again"},
		"set_case_status":  {"case_id": "DSP-2026-0001", "status": "in_review"},
		"draft_letter":     {"case_id": "DSP-2026-0001", "body": "a new letter"},
		"draft_chargeback": {"case_id": "DSP-2026-0001", "body": "a new filing"},
		"set_timer":        {"case_id": "DSP-2026-0001", "name": "extra_timer", "due_at": future},
		"request_approval": {"case_id": "DSP-2026-0001", "kind": "provisional_credit_then_chargeback", "amount_cents": 4599},
	}
	checkEveryWriteTool(t, "bank", table, func(t *testing.T) (*mcp.ClientSession, string, func(string) string) {
		e := newEnv(t)
		e.run("Work case DSP-2026-0001")
		id, _ := e.pendingApproval("DSP-2026-0001")
		return e.mcp, id, func(id string) string {
			_, full := e.do("GET", "/approvals/"+id, "", "")
			s, _ := full["status"].(string)
			return s
		}
	})
}

func TestEveryWriteToolOfTheEquipmentServiceReportsWhatItSuperseded(t *testing.T) {
	future := time.Now().UTC().Add(48 * time.Hour).Format(time.RFC3339)
	table := map[string]map[string]any{
		"set_diagnosis":         {"case_id": "SVC-2026-0001", "cause": "another cause", "text": "a write"},
		"create_work_order":     {"case_id": "SVC-2026-0001", "summary": "another summary"},
		"draft_parts_order":     {"case_id": "SVC-2026-0001", "part_id": "P-10361", "qty": 1, "from_dealer": "D-403", "body": "a new order"},
		"draft_warranty_claim":  {"case_id": "SVC-2026-0001", "body": "a new claim"},
		"draft_customer_notice": {"case_id": "SVC-2026-0001", "body": "a new notice"},
		"propose_slot":          {"case_id": "SVC-2026-0001", "slot_id": "SLT-0002"},
		"set_timer":             {"case_id": "SVC-2026-0001", "name": "extra_timer", "due_at": future},
		"escalate_to_person":    {"case_id": "SVC-2026-0001", "reason": "a person must look"},
		"open_proactive_case":   {"serial": "KH4120-00305", "reason": "the sweep flags it"},
		"request_approval":      {"case_id": "SVC-2026-0001", "kind": "parts_order_with_claim"},
	}
	checkEveryWriteTool(t, "equipment", table, func(t *testing.T) (*mcp.ClientSession, string, func(string) string) {
		e := newEqEnv(t)
		e.run("Work case SVC-2026-0001")
		id, _ := e.pending("SVC-2026-0001")
		return e.mcp, id, func(id string) string {
			_, full := e.do("GET", "/approvals/"+id, "", "")
			s, _ := full["status"].(string)
			return s
		}
	})
}
