package replay

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/google/jsonschema-go/jsonschema"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// ADR 0028, section 1: the approval result convention (v1alpha1). The JSON Schema is in docs/diary/guide. These tests validate the REAL tool results of the bank
// and the equipment records services (request_approval, get_approval, and the result of a write that superseded a request) against it, in both forms a
// client may read: the structured content and the text content.

const approvalSchemaFile = "../../../../docs/diary/guide/approval-result-v1alpha1.schema.json"

// toolResult is one tool result as the agent loop saw it.
type toolResult struct {
	Name       string
	Text       string
	Structured any
}

func loadApprovalSchema(t *testing.T) *jsonschema.Resolved {
	t.Helper()
	raw, err := os.ReadFile(approvalSchemaFile)
	if err != nil {
		t.Fatal(err)
	}
	var s jsonschema.Schema
	if err := json.Unmarshal(raw, &s); err != nil {
		t.Fatalf("the schema is not a JSON Schema: %v", err)
	}
	rs, err := s.Resolve(nil)
	if err != nil {
		t.Fatalf("the schema does not resolve: %v", err)
	}
	return rs
}

// validate checks one result in both forms and returns it as a map.
func validateResult(t *testing.T, rs *jsonschema.Resolved, what string, r toolResult) map[string]any {
	t.Helper()
	var fromText map[string]any
	if err := json.Unmarshal([]byte(r.Text), &fromText); err != nil {
		t.Fatalf("%s: the text content is not a JSON object: %v: %s", what, err, r.Text)
	}
	if err := rs.Validate(fromText); err != nil {
		t.Errorf("%s: the text content breaks the convention: %v\n%s", what, err, r.Text)
	}
	if r.Structured != nil {
		if err := rs.Validate(r.Structured); err != nil {
			t.Errorf("%s: the structured content breaks the convention: %v", what, err)
		}
		b, _ := json.Marshal(r.Structured)
		var fromStruct map[string]any
		_ = json.Unmarshal(b, &fromStruct)
		if !reflect.DeepEqual(fromStruct, fromText) {
			t.Errorf("%s: the structured content and the text content differ:\n%s\n%s", what, b, r.Text)
		}
	}
	return fromText
}

func results(rs []toolResult, name string) []toolResult {
	var out []toolResult
	for _, r := range rs {
		if r.Name == name {
			out = append(out, r)
		}
	}
	return out
}

func approvalOf(t *testing.T, what string, m map[string]any) map[string]any {
	t.Helper()
	a, ok := m["approval"].(map[string]any)
	if !ok {
		t.Fatalf("%s: the result has no approval member: %v", what, m)
	}
	return a
}

func sha(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) }

func TestTheSchemaRejectsWhatTheConventionForbids(t *testing.T) {
	rs := loadApprovalSchema(t)
	good := func() map[string]any {
		return map[string]any{"approval": map[string]any{"id": "APR-0007", "status": "pending", "subject": "SVC-2026-0007", "kind": "parts_order_with_claim",
			"payload_hash": strings.Repeat("a1", 32), "proposed_by": "agent", "decided_by": "", "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736"},
			"superseded_approvals": []any{"APR-0006"}}
	}
	if err := rs.Validate(good()); err != nil {
		t.Fatalf("the example of ADR 0028 must pass: %v", err)
	}
	for _, st := range []string{"pending", "approved", "rejected", "superseded", "expired"} {
		m := good()
		m["approval"].(map[string]any)["status"] = st
		if err := rs.Validate(m); err != nil {
			t.Errorf("status %s must pass: %v", st, err)
		}
	}
	m := good()
	m["approval"].(map[string]any)["trace_id"] = "unknown"
	m["extra"] = "a tool may return more"
	m["approval"].(map[string]any)["untrusted_route_reason"] = "text"
	if err := rs.Validate(m); err != nil {
		t.Errorf("trace_id unknown and extra members must pass: %v", err)
	}
	for name, mut := range map[string]func(map[string]any){
		"a status that is not in the list":      func(a map[string]any) { a["status"] = "waiting" },
		"a hash of 63 characters":               func(a map[string]any) { a["payload_hash"] = strings.Repeat("a", 63) },
		"an upper case hash":                    func(a map[string]any) { a["payload_hash"] = strings.Repeat("A", 64) },
		"a trace id of 31 characters":           func(a map[string]any) { a["trace_id"] = strings.Repeat("a", 31) },
		"an id with a space":                    func(a map[string]any) { a["id"] = "APR 7" },
		"an id of 65 characters":                func(a map[string]any) { a["id"] = strings.Repeat("a", 65) },
		"a kind in upper case":                  func(a map[string]any) { a["kind"] = "Parts_Order" },
		"an empty proposer":                     func(a map[string]any) { a["proposed_by"] = "" },
		"no decided_by":                         func(a map[string]any) { delete(a, "decided_by") },
		"no trace_id":                           func(a map[string]any) { delete(a, "trace_id") },
		"no payload_hash (the old name hash)":   func(a map[string]any) { delete(a, "payload_hash"); a["hash"] = strings.Repeat("a", 64) },
		"a subject that is not in the alphabet": func(a map[string]any) { a["subject"] = "a/b" },
	} {
		m := good()
		mut(m["approval"].(map[string]any))
		if rs.Validate(m) == nil {
			t.Errorf("%s must be refused", name)
		}
	}
	m = good()
	m["superseded_approvals"] = []any{}
	if rs.Validate(m) == nil {
		t.Error("an empty superseded_approvals must be refused: the member is present only when a request was superseded")
	}
}

func TestBankApprovalResultsFollowTheConvention(t *testing.T) {
	rs := loadApprovalSchema(t)
	e := newEnv(t)
	e.run("Work case DSP-2026-0001")

	// request_approval: the result of the run's own call
	req := results(e.results, "request_approval")
	if len(req) != 1 {
		t.Fatalf("one request_approval in the run, got %d", len(req))
	}
	m := validateResult(t, rs, "request_approval", req[0])
	a := approvalOf(t, "request_approval", m)
	if a["status"] != "pending" || a["decided_by"] != "" || a["proposed_by"] != "agent" || a["subject"] != "DSP-2026-0001" || a["kind"] != "provisional_credit_then_chargeback" {
		t.Errorf("the members of a new request: %v", a)
	}
	if a["trace_id"] != "unknown" {
		t.Errorf("until the trace link is built (ADR 0028 slice 3) trace_id is unknown, got %v", a["trace_id"])
	}
	if _, has := m["superseded_approvals"]; has {
		t.Error("a request_approval result has no superseded_approvals")
	}
	id := a["id"].(string)

	// payload_hash is the SHA-256 of the exact payload text the approver reads (the REST view)
	_, full := e.do("GET", "/approvals/"+id, "", "")
	if sha(full["payload"].(string)) != a["payload_hash"] || full["payload_hash"] != a["payload_hash"] {
		t.Errorf("payload_hash must be the SHA-256 of the payload the approver reads: tool %v, REST %v, computed %s", a["payload_hash"], full["payload_hash"], sha(full["payload"].(string)))
	}

	// get_approval returns the same members, with the approval member
	get := func() map[string]any {
		return callTool(t, e.mcp, rs, "get_approval", map[string]any{"approval_id": id})
	}
	g := approvalOf(t, "get_approval", get())
	if g["status"] != "pending" || g["id"] != id || g["payload_hash"] != a["payload_hash"] {
		t.Errorf("get_approval after the request: %v", g)
	}

	// a write that cancels the request returns superseded_approvals, and the status is superseded
	sup := callTool(t, e.mcp, rs, "attach_evidence", map[string]any{"case_id": "DSP-2026-0001", "kind": "other", "ref": "retry-1", "note": "a retried write"})
	if !reflect.DeepEqual(sup["superseded_approvals"], []any{id}) {
		t.Errorf("a write that superseded %s must say so in superseded_approvals: %v", id, sup)
	}
	if st := approvalOf(t, "get_approval", get())["status"]; st != "superseded" {
		t.Errorf("status after the write: %v", st)
	}
	// a write that supersedes nothing has no such member
	if plain := callTool(t, e.mcp, rs, "attach_evidence", map[string]any{"case_id": "DSP-2026-0001", "kind": "other", "ref": "retry-2", "note": "nothing pending"}); plain["superseded_approvals"] != nil {
		t.Errorf("no request was pending, so there is no superseded_approvals: %v", plain)
	}

	// approved and rejected (the decisions are REST, not tools)
	e2 := newEnv(t)
	e2.run("Work case DSP-2026-0001")
	id2, full2 := e2.pendingApproval("DSP-2026-0001")
	e2.approve(id2, full2)
	ap := approvalOf(t, "get_approval", callTool(t, e2.mcp, rs, "get_approval", map[string]any{"approval_id": id2}))
	if ap["status"] != "approved" || ap["decided_by"] != "desk:lead-1" {
		t.Errorf("after approval: %v", ap)
	}
	e3 := newEnv(t)
	e3.run("Work case DSP-2026-0001")
	id3, _ := e3.pendingApproval("DSP-2026-0001")
	if code, m := e3.do("POST", "/approvals/"+id3+"/reject", leadToken, `{"note":"no"}`); code != 200 {
		t.Fatalf("reject: %d %v", code, m)
	}
	rj := approvalOf(t, "get_approval", callTool(t, e3.mcp, rs, "get_approval", map[string]any{"approval_id": id3}))
	if rj["status"] != "rejected" || rj["decided_by"] != "desk:lead-1" {
		t.Errorf("after rejection: %v", rj)
	}
}

func TestEquipmentApprovalResultsFollowTheConvention(t *testing.T) {
	rs := loadApprovalSchema(t)
	e := newEqEnv(t)
	e.run("Work case SVC-2026-0001")
	req := results(e.results, "request_approval")
	if len(req) != 1 {
		t.Fatalf("one request_approval in the run, got %d", len(req))
	}
	m := validateResult(t, rs, "request_approval", req[0])
	a := approvalOf(t, "request_approval", m)
	if a["status"] != "pending" || a["decided_by"] != "" || a["subject"] != "SVC-2026-0001" || a["kind"] != "parts_order_with_claim" || a["trace_id"] != "unknown" {
		t.Errorf("the members of a new request: %v", a)
	}
	id := a["id"].(string)
	_, full := e.do("GET", "/approvals/"+id, "", "")
	if sha(full["payload"].(string)) != a["payload_hash"] || full["payload_hash"] != a["payload_hash"] {
		t.Errorf("payload_hash must be the SHA-256 of the payload the approver reads")
	}
	// the run itself reads the request back with get_approval: its result follows the convention
	reads := results(e.results, "get_approval")
	if len(reads) != 1 {
		t.Fatalf("the scenario reads the request back once, got %d", len(reads))
	}
	g := approvalOf(t, "get_approval", validateResult(t, rs, "get_approval", reads[0]))
	if g["id"] != id || g["status"] != "pending" {
		t.Errorf("get_approval: %v", g)
	}
	// a write that cancels the request
	sup := callTool(t, e.mcp, rs, "set_diagnosis", map[string]any{"case_id": "SVC-2026-0001", "cause": "a retried write", "text": "written after the request"})
	if !reflect.DeepEqual(sup["superseded_approvals"], []any{id}) {
		t.Errorf("a write that superseded %s must say so in superseded_approvals: %v", id, sup)
	}
	if st := approvalOf(t, "get_approval", callTool(t, e.mcp, rs, "get_approval", map[string]any{"approval_id": id}))["status"]; st != "superseded" {
		t.Errorf("status after the write: %v", st)
	}
	if plain := callTool(t, e.mcp, rs, "set_diagnosis", map[string]any{"case_id": "SVC-2026-0001", "cause": "again", "text": "nothing pending now"}); plain["superseded_approvals"] != nil {
		t.Errorf("no request was pending: %v", plain)
	}
	// approved and rejected
	e2 := newEqEnv(t)
	e2.run("Work case SVC-2026-0001")
	id2, full2 := e2.pending("SVC-2026-0001")
	e2.approve(id2, full2)
	ap := approvalOf(t, "get_approval", callTool(t, e2.mcp, rs, "get_approval", map[string]any{"approval_id": id2}))
	if ap["status"] != "approved" || ap["decided_by"] == "" {
		t.Errorf("after approval: %v", ap)
	}
	e3 := newEqEnv(t)
	e3.run("Work case SVC-2026-0001")
	id3, _ := e3.pending("SVC-2026-0001")
	if code, m := e3.do("POST", "/approvals/"+id3+"/reject", leadToken, `{"note":"no"}`); code != 200 {
		t.Fatalf("reject: %d %v", code, m)
	}
	rj := approvalOf(t, "get_approval", callTool(t, e3.mcp, rs, "get_approval", map[string]any{"approval_id": id3}))
	if rj["status"] != "rejected" || rj["decided_by"] == "" {
		t.Errorf("after rejection: %v", rj)
	}
}

// callTool calls one tool and validates the result in both forms.
func callTool(t *testing.T, sess *mcp.ClientSession, rs *jsonschema.Resolved, name string, args map[string]any) map[string]any {
	t.Helper()
	res, err := sess.CallTool(context.Background(), &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		t.Fatal(err)
	}
	var sb strings.Builder
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			sb.WriteString(tc.Text)
		}
	}
	if res.IsError {
		t.Fatalf("tool %s failed: %s", name, sb.String())
	}
	return validateResult(t, rs, fmt.Sprintf("%s(%v)", name, args), toolResult{Name: name, Text: sb.String(), Structured: res.StructuredContent})
}
