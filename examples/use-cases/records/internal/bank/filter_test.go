package bank

import (
	"context"
	"encoding/json"
	"testing"
)

func approvalsFor(t *testing.T, d *Domain, query string) (int, int) {
	t.Helper()
	w := rest(t, d, "GET", "/approvals"+query, "", "")
	var out struct {
		Approvals []map[string]any `json:"approvals"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &out)
	return w.Code, len(out.Approvals)
}

func TestApprovalListCanBeFilteredByCase(t *testing.T) {
	d, _ := newDomain(t)
	c := prepare(t, d, RouteChargeback)
	if _, err := d.svc.RequestApproval(context.Background(), c.ID, RouteChargeback, c.AmountCents); err != nil {
		t.Fatal(err)
	}
	if code, n := approvalsFor(t, d, "?case_id="+c.ID); code != 200 || n != 1 {
		t.Fatalf("the case with a request: %d %d", code, n)
	}
	if code, n := approvalsFor(t, d, "?case_id=DSP-2026-0011"); code != 200 || n != 0 {
		t.Fatalf("a case with no request: %d %d", code, n)
	}
	if code, _ := approvalsFor(t, d, "?case_id=not-an-id"); code != 400 {
		t.Fatalf("a bad id must be refused: %d", code)
	}
}
