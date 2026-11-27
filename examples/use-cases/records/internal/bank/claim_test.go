package bank

import (
	"context"
	"strings"
	"testing"
)

// The provisional credit rule: goods not received gets a chargeback with no credit. The record refuses what the rule forbids.
func TestProvisionalCreditOnGoodsNotReceivedIsRefused(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	var id string
	if err := d.db.QueryRow(`SELECT id FROM cases WHERE claim_type='goods_not_received' AND status='open' ORDER BY id LIMIT 1`).Scan(&id); err != nil {
		t.Fatal(err)
	}
	c, err := d.svc.GetCase(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.svc.SetRoute(ctx, id, RouteCreditThenChargeback, "r"); err != nil {
		t.Fatal(err)
	}
	if _, err := d.svc.DraftLetter(ctx, id, "l"); err != nil {
		t.Fatal(err)
	}
	if _, err := d.svc.DraftChargeback(ctx, id, "f"); err != nil {
		t.Fatal(err)
	}
	if _, err := d.svc.RequestApproval(ctx, id, RouteCreditThenChargeback, c.AmountCents); err == nil || !strings.Contains(err.Error(), "goods not received") {
		t.Fatalf("a provisional credit on goods not received must be refused, got %v", err)
	}
	// A chargeback with no credit stays possible.
	if _, err := d.svc.SetRoute(ctx, id, RouteChargeback, "r"); err != nil {
		t.Fatal(err)
	}
	if _, err := d.svc.DraftLetter(ctx, id, "l"); err != nil {
		t.Fatal(err)
	}
	if _, err := d.svc.DraftChargeback(ctx, id, "f"); err != nil {
		t.Fatal(err)
	}
	if _, err := d.svc.RequestApproval(ctx, id, RouteChargeback, c.AmountCents); err != nil {
		t.Fatalf("a chargeback on goods not received must be allowed: %v", err)
	}
}
