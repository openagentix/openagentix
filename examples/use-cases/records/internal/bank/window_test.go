package bank

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

func outOfTimeCase(t *testing.T, d *Domain) CaseView {
	t.Helper()
	var id string
	if err := d.db.QueryRow(`SELECT id FROM cases WHERE pattern='out_of_time'`).Scan(&id); err != nil {
		t.Fatal(err)
	}
	c, err := d.svc.GetCase(context.Background(), id)
	if err != nil {
		t.Fatal(err)
	}
	if c.WithinSchemeWindow {
		t.Fatal("the seed's out of time case is inside the window")
	}
	return c
}

func TestOutOfTimeChargeCannotBeCreditedOrChargedBack(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	c := outOfTimeCase(t, d)
	for _, route := range []string{RouteCreditThenChargeback, RouteChargeback} {
		if _, err := d.svc.SetRoute(ctx, c.ID, route, "a convincing reason"); err != nil {
			t.Fatal(err)
		}
		if _, err := d.svc.DraftLetter(ctx, c.ID, "letter"); err != nil {
			t.Fatal(err)
		}
		if _, err := d.svc.DraftChargeback(ctx, c.ID, "filing"); err != nil {
			t.Fatal(err)
		}
		_, err := d.svc.RequestApproval(ctx, c.ID, route, c.AmountCents)
		if err == nil || !strings.Contains(err.Error(), "scheme") {
			t.Fatalf("%s on an out of time charge must be refused with a scheme reason, got %v", route, err)
		}
	}
	if n := count(t, d, `SELECT COUNT(*) FROM approvals`); n != 0 {
		t.Fatalf("approvals created: %d", n)
	}
}

func TestOutOfTimeDeclineIsAllowedAndPayloadCarriesTheRecordFacts(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	c := outOfTimeCase(t, d)
	if _, err := d.svc.SetRoute(ctx, c.ID, RouteDecline, "out of time"); err != nil {
		t.Fatal(err)
	}
	if _, err := d.svc.DraftLetter(ctx, c.ID, "letter"); err != nil {
		t.Fatal(err)
	}
	a, err := d.svc.RequestApproval(ctx, c.ID, RouteDecline, 0)
	if err != nil {
		t.Fatal(err)
	}
	var p map[string]any
	if err := json.Unmarshal([]byte(a.Payload), &p); err != nil {
		t.Fatal(err)
	}
	if p["claim_type"] != c.ClaimType || p["within_scheme_window"] != false || p["txn_age_days"] == nil || p["scheme_window_days"] != float64(SchemeWindowDays) {
		t.Fatalf("the payload must carry the claim type and the scheme facts from the record: %s", a.Payload)
	}
	if a.PayloadHash != hash(a.Payload) {
		t.Fatal("the hash must cover the whole payload")
	}
}

func TestInWindowPayloadSaysSo(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	c := prepare(t, d, RouteChargeback)
	a, err := d.svc.RequestApproval(ctx, c.ID, RouteChargeback, c.AmountCents)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(a.Payload, `"within_scheme_window":true`) {
		t.Fatalf("payload: %s", a.Payload)
	}
}
