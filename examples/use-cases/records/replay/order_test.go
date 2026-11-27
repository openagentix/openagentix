package replay

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The first real-model run (issue 229): the agent requested an approval and then retried an evidence write. The write superseded the request. The record now
// says so in the result of the write, and the agent can read it. This test plays that order through the real stub model and the real service: a scenario
// that writes evidence AFTER the approval request and answers with what the record said.
func TestEvidenceAfterTheApprovalRequestIsReportedByTheRecord(t *testing.T) {
	doc := `{"scenarios":[{
	  "name":"late-evidence",
	  "match":{"system":"(?i)fernvale dispute desk agent","user":"(?i)\\bwork case (?P<id>DSP-\\d{4}-0005)\\b"},
	  "steps":[
	    {"tool":"get_case","args":{"case_id":"{{user.id}}"}},
	    {"tool":"set_route","args":{"case_id":"{{user.id}}","route":"decline","reason":"out of time"}},
	    {"tool":"draft_letter","args":{"case_id":"{{user.id}}","body":"Dear customer, the dispute is out of time."}},
	    {"tool":"request_approval","args":{"case_id":"{{user.id}}","kind":"decline","amount_cents":0}},
	    {"tool":"attach_evidence","args":{"case_id":"{{user.id}}","kind":"gap","ref":"{{user.id}}","note":"a late note"}}
	  ],
	  "answers":[{"text":"RECORD SAID: {{result.4.output.notice}} | NEXT WAS: {{result.3.output.next}}"}]}]}`
	f := filepath.Join(t.TempDir(), "late.json")
	if err := os.WriteFile(f, []byte(doc), 0o600); err != nil {
		t.Fatal(err)
	}
	e := newEnvWith(t, f)
	answer := e.run("Work case DSP-2026-0005")
	requireOrder(t, e.called, "records_request_approval", "records_attach_evidence")
	for _, want := range []string{"superseded the pending approval request APR-0001", "call request_approval again", "do not report the old request as pending", "must be your last write"} {
		if !strings.Contains(answer, want) {
			t.Errorf("the record must say %q: %s", want, answer)
		}
	}
	// the state is what the notice says: no request waits, the case is back in review
	if n := e.count("/approvals?case_id=DSP-2026-0005&status=pending", "approvals"); n != 0 {
		_, m := e.do("GET", "/approvals", "", "")
		t.Fatalf("a pending approval is left: %v", m)
	}
	_, c := e.do("GET", "/cases/DSP-2026-0005", "", "")
	if c["status"] != "in_review" {
		t.Fatalf("status %v, want in_review", c["status"])
	}
}
