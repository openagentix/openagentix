package equipment

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"testing"
)

// The evaluation set asks the REST port whether a case has an approval request (state_checks on /approvals?case_id=...). The route must
// filter by case: with the filter ignored, a case with no request would count the requests of every other case.
func TestApprovalsListFiltersByCaseID(t *testing.T) {
	d, _ := newDomain(t)
	first := caseOf(t, d, "demo")
	kind := prepare(t, d, first)
	if _, err := d.svc.RequestApproval(context.Background(), first, kind); err != nil {
		t.Fatal(err)
	}
	h := d.Handler()
	get := func(path string) (int, []map[string]any) {
		req := httptest.NewRequest("GET", path, nil)
		req.RemoteAddr = "127.0.0.1:1"
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		var out struct {
			Approvals []map[string]any `json:"approvals"`
		}
		_ = json.Unmarshal(rec.Body.Bytes(), &out)
		return rec.Code, out.Approvals
	}
	if code, all := get("/approvals"); code != 200 || len(all) != 1 {
		t.Fatalf("all approvals: %d %v", code, all)
	}
	if code, mine := get("/approvals?case_id=" + first); code != 200 || len(mine) != 1 {
		t.Fatalf("approvals of the case: %d %v", code, mine)
	}
	other := caseOf(t, d, "out_of_warranty")
	if code, none := get("/approvals?case_id=" + other); code != 200 || len(none) != 0 {
		t.Fatalf("a case with no request must list none, got %d %v", code, none)
	}
	if code, _ := get("/approvals?case_id=SVC-1%3Bdrop"); code == 200 {
		t.Fatal("a bad case id must be refused")
	}
}
