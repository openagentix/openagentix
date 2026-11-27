package equipment

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/openagentix/openagentix/examples/use-cases/records/internal/core"
)

var now = time.Date(2026, 11, 27, 10, 0, 0, 0, time.UTC)

const (
	mgrToken   = "manager-token-for-tests"
	clerkToken = "clerk-token-for-tests"
)

var manager = core.Approver{ID: "dealer:svc-mgr-02", Role: "dealer-manager"}

func hash(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) }

func newUnseeded(t *testing.T) (*Domain, *bytes.Buffer) {
	t.Helper()
	db, err := core.Open(filepath.Join(t.TempDir(), "r.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	p := filepath.Join(t.TempDir(), "approvers.json")
	body := `[{"id":"dealer:svc-mgr-02","role":"dealer-manager","token_sha256":"` + hash(mgrToken) + `"},{"id":"dealer:clerk-01","role":"dealer-clerk","token_sha256":"` + hash(clerkToken) + `"}]`
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	ap, err := core.LoadApprovers(p)
	if err != nil {
		t.Fatal(err)
	}
	logs := &bytes.Buffer{}
	d, err := New(db, slog.New(slog.NewJSONHandler(logs, nil)), func() time.Time { return now }, ap)
	if err != nil {
		t.Fatal(err)
	}
	return d, logs
}

func newDomain(t *testing.T) (*Domain, *bytes.Buffer) {
	t.Helper()
	d, logs := newUnseeded(t)
	if err := d.Seed(context.Background()); err != nil {
		t.Fatal(err)
	}
	return d, logs
}

func count(t *testing.T, d *Domain, q string, args ...any) int {
	t.Helper()
	var n int
	if err := d.db.QueryRow(q, args...).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func caseOf(t *testing.T, d *Domain, pattern string) string {
	t.Helper()
	var id string
	if err := d.db.QueryRow(`SELECT id FROM service_cases WHERE pattern=? AND status<>'resolved' ORDER BY id LIMIT 1`, pattern).Scan(&id); err != nil {
		t.Fatalf("no open case with pattern %q: %v", pattern, err)
	}
	return id
}

// prepare fills in everything the approver needs for a case, from the fault code's part and the nearest dealer
// that has it. It returns the case id and the approval kind that matches the warranty.
func prepare(t *testing.T, d *Domain, id string) string {
	t.Helper()
	ctx := context.Background()
	c, err := d.svc.GetCase(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	fc, err := d.svc.GetFaultCode(ctx, c.FaultCode)
	if err != nil {
		t.Fatal(err)
	}
	part := fc.PartID
	if p, _ := d.svc.GetPart(ctx, part); p.SupersededBy != "" {
		part = p.SupersededBy
	}
	rows, err := d.svc.StockFor(ctx, id, part)
	if err != nil {
		t.Fatal(err)
	}
	from := ""
	for _, r := range rows {
		if r.Qty > 0 {
			from = r.DealerID
			break
		}
	}
	if _, err := d.svc.SetDiagnosis(ctx, id, fc.FirstCause, "Checked the fault code table."); err != nil {
		t.Fatal(err)
	}
	if _, err := d.svc.CreateWorkOrder(ctx, id, "Replace the part and test."); err != nil {
		t.Fatal(err)
	}
	if _, err := d.svc.DraftPartsOrder(ctx, id, part, 1, from, "Order one unit."); err != nil {
		t.Fatal(err)
	}
	w, err := d.svc.CheckWarranty(ctx, c.Serial, c.FaultCode)
	if err != nil {
		t.Fatal(err)
	}
	kind := KindOrder
	if w.Covered {
		kind = KindOrderWithClaim
		if _, err := d.svc.DraftWarrantyClaim(ctx, id, "Claim for a covered fault."); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := d.svc.DraftCustomerNotice(ctx, id, "Your service request is open."); err != nil {
		t.Fatal(err)
	}
	slots, err := d.svc.FreeSlots(ctx, id, 3)
	if err != nil || len(slots) == 0 {
		t.Fatalf("slots: %v %v", slots, err)
	}
	if _, err := d.svc.ProposeSlot(ctx, id, slots[0].ID); err != nil {
		t.Fatal(err)
	}
	return kind
}

func payloadOf(t *testing.T, a core.Approval) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal([]byte(a.Payload), &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestSeedShapeAndSyntheticData(t *testing.T) {
	d, _ := newDomain(t)
	for tbl, n := range map[string]int{"models": 3, "dealers": 4, "machines": 200, "parts": 400, "fault_codes": 60} {
		if got := count(t, d, `SELECT COUNT(*) FROM `+tbl); got != n {
			t.Errorf("%s: %d want %d", tbl, got, n)
		}
	}
	if n := count(t, d, `SELECT COUNT(DISTINCT machine) FROM telemetry`); n != 30 {
		t.Errorf("machines with telemetry: %d", n)
	}
	if n := count(t, d, `SELECT COUNT(*) FROM service_cases WHERE status<>'resolved'`); n != 15 {
		t.Errorf("open cases: %d", n)
	}
	if n := count(t, d, `SELECT COUNT(*) FROM service_cases WHERE human_diagnosis<>''`); n != 40 {
		t.Errorf("closed cases with a technician diagnosis: %d", n)
	}
	bad := regexp.MustCompile(`@|[0-9]{9,}|https?://`)
	for _, q := range []string{`SELECT name FROM dealers`, `SELECT customer_ref FROM machines`, `SELECT dealer_note FROM service_cases`, `SELECT name FROM parts`, `SELECT description FROM fault_codes`} {
		rows, err := d.db.Query(q)
		if err != nil {
			t.Fatal(err)
		}
		for rows.Next() {
			var s string
			_ = rows.Scan(&s)
			if bad.MatchString(s) {
				t.Errorf("%s: %q looks like real data", q, s)
			}
		}
		rows.Close()
	}
}

func TestSeedIsIdempotent(t *testing.T) {
	d, _ := newDomain(t)
	if err := d.Seed(context.Background()); err != nil {
		t.Fatal(err)
	}
	if n := count(t, d, `SELECT COUNT(*) FROM machines`); n != 200 {
		t.Fatalf("machines %d", n)
	}
}

func TestWarrantyIsDecidedByTheRecord(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	in, err := d.svc.CheckWarranty(ctx, "KH4120-00317", "E-317")
	if err != nil || !in.Covered {
		t.Fatalf("in warranty: %+v %v", in, err)
	}
	out, err := d.svc.CheckWarranty(ctx, "KH4120-00340", "E-318")
	if err != nil || out.Covered || out.Reason == "" {
		t.Fatalf("out of warranty: %+v %v", out, err)
	}
	if _, err := d.svc.CheckWarranty(ctx, "KH4120-99999", "E-317"); !core.IsKind(err, core.NotFound) {
		t.Fatalf("unknown machine: %v", err)
	}
	if _, err := d.svc.CheckWarranty(ctx, "bad serial", "E-317"); !core.IsKind(err, core.Invalid) {
		t.Fatalf("bad serial: %v", err)
	}
}

func TestSupersededPartCannotBeOrdered(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	id := caseOf(t, d, "demo")
	_, _ = d.svc.CreateWorkOrder(ctx, id, "w")
	if _, err := d.svc.DraftPartsOrder(ctx, id, "P-10006", 1, "D-403", "old part"); !core.IsKind(err, core.Conflict) {
		t.Fatalf("a superseded part: %v", err)
	}
	p, _ := d.svc.GetPart(ctx, "P-10006")
	if p.SupersededBy != "P-10361" {
		t.Fatalf("supersession: %+v", p)
	}
	if _, err := d.svc.DraftPartsOrder(ctx, id, p.SupersededBy, 1, "D-403", "replacement"); err != nil {
		t.Fatalf("the replacement: %v", err)
	}
}

func TestStockIsNearestFirstAndAnEmptyDealerCannotFill(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	id := caseOf(t, d, "demo")
	rows, err := d.svc.StockFor(ctx, id, "P-10361")
	if err != nil || len(rows) != 4 {
		t.Fatalf("%v %v", rows, err)
	}
	for i := 1; i < len(rows); i++ {
		if rows[i].DistanceKm < rows[i-1].DistanceKm {
			t.Fatalf("not nearest first: %+v", rows)
		}
	}
	if rows[0].Qty != 0 || rows[0].DealerID != "D-401" {
		t.Fatalf("the home dealer is empty: %+v", rows[0])
	}
	if _, err := d.svc.DraftPartsOrder(ctx, id, "P-10361", 1, rows[1].DealerID, "from the nearest"); !core.IsKind(err, core.Conflict) {
		t.Fatalf("the nearest dealer has none: %v", err)
	}
	if _, err := d.svc.DraftPartsOrder(ctx, id, "P-10361", 1, "D-403", "from the third"); err != nil {
		t.Fatal(err)
	}
}

func TestFullFlowStopsAtApprovalThenReleasesOnlyAfter(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	id := caseOf(t, d, "demo")
	kind := prepare(t, d, id)
	if kind != KindOrderWithClaim {
		t.Fatal(kind)
	}
	var before int
	_ = d.db.QueryRow(`SELECT qty FROM stock WHERE dealer_id='D-403' AND part_id='P-10361'`).Scan(&before)
	a, err := d.svc.RequestApproval(ctx, id, kind)
	if err != nil {
		t.Fatal(err)
	}
	if count(t, d, `SELECT COUNT(*) FROM outbox WHERE status='queued'`) != 0 {
		t.Fatal("something was released before approval")
	}
	var after int
	_ = d.db.QueryRow(`SELECT qty FROM stock WHERE dealer_id='D-403' AND part_id='P-10361'`).Scan(&after)
	if after != before {
		t.Fatal("stock moved before approval")
	}
	done, err := d.approvals.Approve(ctx, a.ID, manager, a.PayloadHash, "ok")
	if err != nil {
		t.Fatal(err)
	}
	if done.DecidedBy != "dealer:svc-mgr-02" {
		t.Fatalf("%+v", done)
	}
	if n := count(t, d, `SELECT COUNT(*) FROM outbox WHERE subject=? AND status='queued'`, id); n != 3 {
		t.Fatalf("order, claim and notice must be queued, got %d", n)
	}
	_ = d.db.QueryRow(`SELECT qty FROM stock WHERE dealer_id='D-403' AND part_id='P-10361'`).Scan(&after)
	if after != before-1 {
		t.Fatalf("stock %d -> %d", before, after)
	}
	if count(t, d, `SELECT COUNT(*) FROM slots WHERE case_id=? AND status='confirmed'`, id) != 1 {
		t.Fatal("the slot must be confirmed")
	}
	c, _ := d.svc.GetCase(ctx, id)
	if c.Status != "resolved" {
		t.Fatal(c.Status)
	}
}

func TestOutOfWarrantyOrdersWithoutAClaim(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	id := caseOf(t, d, "out_of_warranty")
	if _, err := d.svc.DraftWarrantyClaim(ctx, id, "claim"); !core.IsKind(err, core.Conflict) {
		t.Fatalf("a claim for a machine out of warranty: %v", err)
	}
	kind := prepare(t, d, id)
	if kind != KindOrder {
		t.Fatal(kind)
	}
	if _, err := d.svc.RequestApproval(ctx, id, KindOrderWithClaim); !core.IsKind(err, core.Conflict) {
		t.Fatalf("the kind must follow the warranty: %v", err)
	}
	a, err := d.svc.RequestApproval(ctx, id, KindOrder)
	if err != nil {
		t.Fatal(err)
	}
	if _, has := payloadOf(t, a)["claim"]; has {
		t.Error("no claim in the payload")
	}
	if _, err := d.approvals.Approve(ctx, a.ID, manager, a.PayloadHash, ""); err != nil {
		t.Fatal(err)
	}
	if n := count(t, d, `SELECT COUNT(*) FROM outbox WHERE kind='warranty_claim' AND status='queued'`); n != 0 {
		t.Fatal("a claim was released")
	}
}

func TestApprovalNeedsEveryPiece(t *testing.T) {
	steps := map[string]string{
		"diagnosis":   `UPDATE service_cases SET diagnosis_cause='' WHERE id=?`,
		"work order":  `DELETE FROM work_orders WHERE case_id=?`,
		"parts line":  `DELETE FROM case_parts WHERE case_id=?`,
		"order draft": `UPDATE outbox SET status='discarded' WHERE subject=? AND kind='parts_order'`,
		"claim draft": `UPDATE outbox SET status='discarded' WHERE subject=? AND kind='warranty_claim'`,
		"notice":      `UPDATE outbox SET status='discarded' WHERE subject=? AND kind='customer_notice'`,
		"slot":        `UPDATE slots SET status='free', case_id='' WHERE case_id=?`,
	}
	for name, q := range steps {
		t.Run(name, func(t *testing.T) {
			d, _ := newDomain(t)
			id := caseOf(t, d, "demo")
			kind := prepare(t, d, id)
			if _, err := d.db.Exec(q, id); err != nil {
				t.Fatal(err)
			}
			if _, err := d.svc.RequestApproval(context.Background(), id, kind); !core.IsKind(err, core.Conflict) {
				t.Fatalf("without %s: %v", name, err)
			}
		})
	}
}

func TestSafetyCriticalRequestIsRefusedAndRoutedToAPerson(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	id := caseOf(t, d, "safety")
	if _, err := d.svc.RequestApproval(ctx, id, KindOrder); err == nil {
		t.Fatal("a safety-critical case must not reach an approval")
	}
	c, err := d.svc.Escalate(ctx, id, "asks to bypass a safety interlock")
	if err != nil || c.Status != "needs_person" {
		t.Fatalf("%+v %v", c, err)
	}
	other := caseOf(t, d, "demo")
	_ = prepare(t, d, other)
	if _, err := d.svc.Escalate(ctx, other, "unsure"); err != nil {
		t.Fatal(err)
	}
	if _, err := d.svc.RequestApproval(ctx, other, KindOrderWithClaim); !core.IsKind(err, core.Conflict) {
		t.Fatalf("an escalated case: %v", err)
	}
}

func TestFleetSweepFindsTheTrendsAndNotTheFlappingSensor(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	trends, err := d.svc.FleetTrends(ctx)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	for _, tr := range trends {
		got[tr.Serial] = tr.Classification
	}
	for _, s := range []string{"KH4120-00317", "KH4120-00305", "KH4120-00322"} {
		if got[s] != "trending_to_failure" {
			t.Errorf("%s: %s", s, got[s])
		}
	}
	if got["KH4120-00310"] != "sensor_flapping" {
		t.Errorf("flapping sensor: %s", got["KH4120-00310"])
	}
	n := 0
	for _, c := range got {
		if c == "trending_to_failure" {
			n++
		}
	}
	if n != 3 {
		t.Errorf("trending machines: %d", n)
	}
	if _, err := d.svc.OpenProactiveCase(ctx, "KH4120-00310", "sweep"); !core.IsKind(err, core.Conflict) {
		t.Fatalf("no case for a flapping sensor: %v", err)
	}
	if _, err := d.svc.OpenProactiveCase(ctx, "KH4120-00330", "sweep"); !core.IsKind(err, core.Conflict) {
		t.Fatalf("no case for a normal machine: %v", err)
	}
	c, err := d.svc.OpenProactiveCase(ctx, "KH4120-00305", "coolant trend")
	if err != nil || c.Kind != "sweep" {
		t.Fatalf("%+v %v", c, err)
	}
	again, err := d.svc.OpenProactiveCase(ctx, "KH4120-00305", "coolant trend")
	if err != nil || again.ID != c.ID {
		t.Fatalf("one open sweep case per machine: %+v %v", again, err)
	}
}

func TestNoPartsOrderForAFlappingSensor(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	id := caseOf(t, d, "flapping_sensor")
	_, _ = d.svc.CreateWorkOrder(ctx, id, "check the sensor wiring")
	if _, err := d.svc.DraftPartsOrder(ctx, id, "P-10050", 1, "D-401", "order a sensor"); !core.IsKind(err, core.Conflict) {
		t.Fatalf("a parts order for a flapping sensor: %v", err)
	}
}

func TestFaultEventIsDeduplicatedPerMachine(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	c1, dup1, err := d.svc.CreateFault(ctx, "KT260-00130", "E-322")
	if err != nil || dup1 {
		t.Fatalf("%+v %v %v", c1, dup1, err)
	}
	c2, dup2, err := d.svc.CreateFault(ctx, "KT260-00130", "E-322")
	if err != nil || !dup2 || c2.ID != c1.ID {
		t.Fatalf("the same fault on the same machine opens one case: %+v %v %v", c2, dup2, err)
	}
	if n := count(t, d, `SELECT COUNT(*) FROM fault_events WHERE machine='KT260-00130'`); n != 2 {
		t.Fatalf("every event is recorded: %d", n)
	}
	if _, _, err := d.svc.CreateFault(ctx, "KT260-00130", "X-1'; DROP TABLE machines"); !core.IsKind(err, core.Invalid) {
		t.Fatalf("a bad code: %v", err)
	}
}

func TestRepeatedFaultsAreVisible(t *testing.T) {
	d, _ := newDomain(t)
	id := caseOf(t, d, "repeat_fault")
	c, _ := d.svc.GetCase(context.Background(), id)
	m, err := d.svc.GetMachine(context.Background(), c.Serial)
	if err != nil {
		t.Fatal(err)
	}
	found := 0
	for _, f := range m.RecentFaults {
		if f.Code == c.FaultCode {
			found = f.Count
		}
	}
	if found < 3 {
		t.Fatalf("the repeated fault must show a count of at least 3: %+v", m.RecentFaults)
	}
}

func TestAnyChangeAfterProposalSupersedesIt(t *testing.T) {
	ctx := context.Background()
	changes := map[string]func(d *Domain, id string) error{
		"diagnosis": func(d *Domain, id string) error {
			_, err := d.svc.SetDiagnosis(ctx, id, "another cause", "text")
			return err
		},
		"work order": func(d *Domain, id string) error { _, err := d.svc.CreateWorkOrder(ctx, id, "changed"); return err },
		"order": func(d *Domain, id string) error {
			_, err := d.svc.DraftPartsOrder(ctx, id, "P-10361", 2, "D-403", "two")
			return err
		},
		"claim": func(d *Domain, id string) error {
			_, err := d.svc.DraftWarrantyClaim(ctx, id, "changed claim")
			return err
		},
		"notice": func(d *Domain, id string) error {
			_, err := d.svc.DraftCustomerNotice(ctx, id, "changed notice")
			return err
		},
		"status": func(d *Domain, id string) error { _, err := d.svc.SetStatus(ctx, id, "in_review"); return err },
		"slot": func(d *Domain, id string) error {
			s, _ := d.svc.FreeSlots(ctx, id, 5)
			_, err := d.svc.ProposeSlot(ctx, id, s[len(s)-1].ID)
			return err
		},
	}
	for name, change := range changes {
		t.Run(name, func(t *testing.T) {
			d, _ := newDomain(t)
			id := caseOf(t, d, "demo")
			kind := prepare(t, d, id)
			a, err := d.svc.RequestApproval(ctx, id, kind)
			if err != nil {
				t.Fatal(err)
			}
			if err := change(d, id); err != nil {
				t.Fatal(err)
			}
			got, _ := d.approvals.Get(ctx, a.ID)
			if got.Status != "superseded" {
				t.Fatalf("status %s", got.Status)
			}
			if _, err := d.approvals.Approve(ctx, a.ID, manager, a.PayloadHash, ""); !core.IsKind(err, core.Conflict) {
				t.Fatalf("approving a superseded approval: %v", err)
			}
			if count(t, d, `SELECT COUNT(*) FROM outbox WHERE status='queued'`) != 0 {
				t.Fatal("released")
			}
		})
	}
}

func TestStockChangeAfterProposalRefusesApproval(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	id := caseOf(t, d, "demo")
	kind := prepare(t, d, id)
	a, _ := d.svc.RequestApproval(ctx, id, kind)
	if _, err := d.db.Exec(`UPDATE stock SET qty=0 WHERE dealer_id='D-403' AND part_id='P-10361'`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.approvals.Approve(ctx, a.ID, manager, a.PayloadHash, ""); !core.IsKind(err, core.Conflict) {
		t.Fatalf("the part ran out: %v", err)
	}
	if count(t, d, `SELECT COUNT(*) FROM outbox WHERE status='queued'`) != 0 {
		t.Fatal("released")
	}
}

func TestPayloadCarriesWhatTheApproverMustSee(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	id := caseOf(t, d, "demo")
	kind := prepare(t, d, id)
	a, _ := d.svc.RequestApproval(ctx, id, kind)
	m := payloadOf(t, a)
	for _, k := range []string{"case_id", "serial", "dealer_id", "fault_code", "kind", "warranty", "diagnosis", "work_order", "part_id", "qty", "from_dealer", "stock_available", "slot", "order", "claim", "notice", "case_version"} {
		if _, ok := m[k]; !ok {
			t.Errorf("payload lacks %s", k)
		}
	}
	if a.PayloadHash != core.HashPayload(a.Payload) {
		t.Error("hash")
	}
	if m["part_id"] != "P-10361" || m["from_dealer"] != "D-403" {
		t.Errorf("the superseded replacement from the dealer that has it: %v", m)
	}
}

func TestTwoApprovalsAtOnceExecuteOnce(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	id := caseOf(t, d, "demo")
	kind := prepare(t, d, id)
	a, _ := d.svc.RequestApproval(ctx, id, kind)
	errs := make(chan error, 2)
	for i := 0; i < 2; i++ {
		go func() { _, err := d.approvals.Approve(ctx, a.ID, manager, a.PayloadHash, ""); errs <- err }()
	}
	ok := 0
	for i := 0; i < 2; i++ {
		if err := <-errs; err == nil {
			ok++
		} else if !core.IsKind(err, core.Conflict) {
			t.Errorf("loser: %v", err)
		}
	}
	var qty int
	_ = d.db.QueryRow(`SELECT qty FROM stock WHERE dealer_id='D-403' AND part_id='P-10361'`).Scan(&qty)
	if ok != 1 || qty != 3 {
		t.Fatalf("approved %d times, stock %d", ok, qty)
	}
}

func TestRejectReleasesTheSlotAndDropsDrafts(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	id := caseOf(t, d, "demo")
	kind := prepare(t, d, id)
	a, _ := d.svc.RequestApproval(ctx, id, kind)
	if _, err := d.approvals.Reject(ctx, a.ID, manager, "wrong part"); err != nil {
		t.Fatal(err)
	}
	c, _ := d.svc.GetCase(ctx, id)
	if c.Status != "needs_person" {
		t.Fatal(c.Status)
	}
	if count(t, d, `SELECT COUNT(*) FROM slots WHERE case_id=?`, id) != 0 {
		t.Fatal("the slot must be free again")
	}
	if count(t, d, `SELECT COUNT(*) FROM outbox WHERE subject=? AND status IN ('draft','queued')`, id) != 0 {
		t.Fatal("drafts must be dropped")
	}
}

func TestSlotRules(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	id := caseOf(t, d, "demo")
	var other string
	_ = d.db.QueryRow(`SELECT id FROM slots WHERE dealer_id<>'D-401' AND status='free' LIMIT 1`).Scan(&other)
	if _, err := d.svc.ProposeSlot(ctx, id, other); !core.IsKind(err, core.Conflict) {
		t.Fatalf("a slot at another dealer: %v", err)
	}
	slots, _ := d.svc.FreeSlots(ctx, id, 2)
	first, _ := d.svc.ProposeSlot(ctx, id, slots[0].ID)
	if _, err := d.svc.ProposeSlot(ctx, id, slots[1].ID); err != nil {
		t.Fatal(err)
	}
	if count(t, d, `SELECT COUNT(*) FROM slots WHERE id=? AND status='free'`, first.ID) != 1 {
		t.Fatal("moving to another slot frees the first one")
	}
	if _, err := d.svc.ProposeSlot(ctx, id, "SLT-9999"); !core.IsKind(err, core.NotFound) {
		t.Fatal(err)
	}
}

func rest(t *testing.T, d *Domain, method, path, token, body string) *httptest.ResponseRecorder {
	t.Helper()
	return restFrom(t, d, "192.0.2.1:1234", method, path, token, body)
}

func restFrom(t *testing.T, d *Domain, remote, method, path, token, body string) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	r.RemoteAddr = remote
	if method == "POST" {
		r.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	d.Handler().ServeHTTP(w, r)
	return w
}

func TestRESTApprovalAuthentication(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	id := caseOf(t, d, "demo")
	kind := prepare(t, d, id)
	a, _ := d.svc.RequestApproval(ctx, id, kind)
	path := "/approvals/" + a.ID + "/approve"
	body := `{"payload_hash":"` + a.PayloadHash + `"}`
	if w := rest(t, d, "POST", path, "", body); w.Code != 401 {
		t.Errorf("no token: %d", w.Code)
	}
	if w := rest(t, d, "POST", path, clerkToken, body); w.Code != 403 {
		t.Errorf("wrong role: %d", w.Code)
	}
	if w := rest(t, d, "POST", "/approvals/"+a.ID+"/reject", clerkToken, `{}`); w.Code != 403 {
		t.Errorf("reject wrong role: %d", w.Code)
	}
	if w := rest(t, d, "POST", "/approvals/"+a.ID+"/reject", "", `{}`); w.Code != 401 {
		t.Errorf("reject no token: %d", w.Code)
	}
	if count(t, d, `SELECT COUNT(*) FROM outbox WHERE status='queued'`) != 0 {
		t.Fatal("a refused call released something")
	}
	if w := rest(t, d, "GET", "/approvals/"+a.ID, "", ""); w.Code != 200 || !strings.Contains(w.Body.String(), "payload_hash") {
		t.Errorf("view: %d", w.Code)
	}
	if w := rest(t, d, "POST", path, mgrToken, body); w.Code != 200 {
		t.Errorf("manager: %d %s", w.Code, w.Body)
	}
	if w := rest(t, d, "GET", "/audit", "", ""); w.Code != 401 {
		t.Errorf("audit: %d", w.Code)
	}
}

func TestRESTProposalNeedsATokenFromOutsideThePodAndOwnProposalsAreBlocked(t *testing.T) {
	d, _ := newDomain(t)
	id := caseOf(t, d, "demo")
	kind := prepare(t, d, id)
	body := `{"case_id":"` + id + `","kind":"` + kind + `"}`
	if w := restFrom(t, d, "10.4.5.6:1", "POST", "/approvals", "", body); w.Code != 401 {
		t.Fatalf("remote without token: %d", w.Code)
	}
	w := restFrom(t, d, "10.4.5.6:1", "POST", "/approvals", mgrToken, body)
	if w.Code != 201 {
		t.Fatalf("with token: %d %s", w.Code, w.Body)
	}
	var a core.Approval
	_ = json.Unmarshal(w.Body.Bytes(), &a)
	if a.ProposedBy != "dealer:svc-mgr-02" {
		t.Fatalf("proposer %q", a.ProposedBy)
	}
	if w := rest(t, d, "POST", "/approvals/"+a.ID+"/approve", mgrToken, `{"payload_hash":"`+a.PayloadHash+`"}`); w.Code != 403 {
		t.Fatalf("own proposal: %d", w.Code)
	}
}

func TestRESTFaultEventsValidationAndNoReleaseRoutes(t *testing.T) {
	d, _ := newDomain(t)
	if w := rest(t, d, "POST", "/faults", "", `{"serial":"KT260-00130","code":"E-322"}`); w.Code != 201 {
		t.Fatalf("fault: %d %s", w.Code, w.Body)
	}
	if w := rest(t, d, "POST", "/faults", "", `{"serial":"KT260-00130","code":"E-322"}`); w.Code != 200 {
		t.Fatalf("a duplicate fault answers 200 with the same case: %d", w.Code)
	}
	for path, want := range map[string]int{
		"/assets/KH4120-00317": 200, "/assets/nope": 400, "/assets/KH4120-99999": 404, "/parts/P-10006": 200, "/parts/x": 400,
		"/warranty/KH4120-00317?code=E-317": 200, "/warranty/KH4120-00317?code=zzz": 400, "/faultcodes/E-317": 200,
		"/fleet/trends": 200, "/cases/SVC-2026-0001": 200, "/cases/SVC-2026-0001'%20OR%201=1": 400, "/cases/SVC-2026-9999": 404,
		"/cases?status=bogus": 400, "/stock/P-10361?from_dealer=D-401": 200, "/stock/P-10361": 400, "/calendar/D-401": 200,
	} {
		if w := rest(t, d, "GET", path, "", ""); w.Code != want {
			t.Errorf("%s: %d want %d", path, w.Code, want)
		}
	}
	for _, c := range [][2]string{{"POST", "/orders"}, {"POST", "/outbox"}, {"POST", "/warranty/claims"}, {"POST", "/stock"}, {"PUT", "/stock/P-10361"}, {"DELETE", "/approvals/APR-0001"}} {
		if w := rest(t, d, c[0], c[1], "", `{}`); w.Code != 404 && w.Code != 405 {
			t.Errorf("%s %s: %d", c[0], c[1], w.Code)
		}
	}
	r := httptest.NewRequest("POST", "/faults", strings.NewReader(`{}`))
	r.Header.Set("Content-Type", "text/plain")
	w := httptest.NewRecorder()
	d.Handler().ServeHTTP(w, r)
	if w.Code != 400 {
		t.Errorf("content type: %d", w.Code)
	}
}

func TestReadyFailsOnAnUnseededStore(t *testing.T) {
	d, _ := newUnseeded(t)
	if w := rest(t, d, "GET", "/readyz", "", ""); w.Code != 503 {
		t.Fatalf("%d", w.Code)
	}
	if err := d.Seed(context.Background()); err != nil {
		t.Fatal(err)
	}
	if w := rest(t, d, "GET", "/readyz", "", ""); w.Code != 200 {
		t.Fatalf("%d", w.Code)
	}
}

func mcpSession(t *testing.T, d *Domain) *mcp.ClientSession {
	t.Helper()
	srv := httptest.NewServer(d.MCPHandler("test"))
	t.Cleanup(srv.Close)
	c := mcp.NewClient(&mcp.Implementation{Name: "t", Version: "1"}, nil)
	s, err := c.Connect(context.Background(), &mcp.StreamableClientTransport{Endpoint: srv.URL + "/mcp"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func call(t *testing.T, s *mcp.ClientSession, tool string, args map[string]any) (string, bool) {
	t.Helper()
	res, err := s.CallTool(context.Background(), &mcp.CallToolParams{Name: tool, Arguments: args})
	if err != nil {
		t.Fatal(err)
	}
	var sb strings.Builder
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			sb.WriteString(tc.Text)
		}
	}
	return sb.String(), res.IsError
}

func TestMCPToolsCannotReleaseAnything(t *testing.T) {
	d, _ := newDomain(t)
	s := mcpSession(t, d)
	list, err := s.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	have := map[string]bool{}
	for _, tl := range list.Tools {
		have[tl.Name] = true
		if regexp.MustCompile(`approve|reject|send|execute|release|decide|confirm|place|submit|post|stock_adjust`).MatchString(tl.Name) {
			t.Errorf("tool %q could release an order, a claim or a message", tl.Name)
		}
	}
	for _, want := range []string{"get_case", "list_open_cases", "get_machine", "get_telemetry", "check_warranty", "get_fault_code", "get_part", "get_stock",
		"list_free_slots", "list_fleet_trends", "open_proactive_case", "set_diagnosis", "create_work_order", "draft_parts_order", "draft_warranty_claim",
		"draft_customer_notice", "propose_slot", "set_timer", "escalate_to_person", "request_approval", "get_approval"} {
		if !have[want] {
			t.Errorf("missing tool %s", want)
		}
	}
}

func TestMCPFlowAuditHasNoTextAndLabelsAreUntrusted(t *testing.T) {
	d, logs := newDomain(t)
	s := mcpSession(t, d)
	id := caseOf(t, d, "demo")
	secret := "UNIQUE-ORDER-TEXT-8841"
	for _, step := range []struct {
		tool string
		args map[string]any
	}{
		{"set_diagnosis", map[string]any{"case_id": id, "cause": "coolant sensor", "text": "DIAG-TEXT-3302"}},
		{"create_work_order", map[string]any{"case_id": id, "summary": "WO-TEXT-3303"}},
		{"draft_parts_order", map[string]any{"case_id": id, "part_id": "P-10361", "qty": 1, "from_dealer": "D-403", "body": secret}},
		{"draft_warranty_claim", map[string]any{"case_id": id, "body": "CLAIM-TEXT-3304"}},
		{"draft_customer_notice", map[string]any{"case_id": id, "body": "NOTICE-TEXT-3305"}},
	} {
		if out, isErr := call(t, s, step.tool, step.args); isErr {
			t.Fatalf("%s: %s", step.tool, out)
		}
	}
	slots, _ := d.svc.FreeSlots(context.Background(), id, 1)
	if out, isErr := call(t, s, "propose_slot", map[string]any{"case_id": id, "slot_id": slots[0].ID}); isErr {
		t.Fatal(out)
	}
	out, isErr := call(t, s, "request_approval", map[string]any{"case_id": id, "kind": KindOrderWithClaim})
	if isErr || !strings.Contains(out, "pending") {
		t.Fatalf("%s", out)
	}
	if count(t, d, `SELECT COUNT(*) FROM outbox WHERE status='queued'`) != 0 {
		t.Fatal("the agent path released something")
	}
	apr := regexp.MustCompile(`APR-[0-9]{4}`).FindString(out)
	got, _ := call(t, s, "get_approval", map[string]any{"approval_id": apr})
	for _, text := range []string{out, got} {
		if strings.Contains(text, `"payload"`) || strings.Contains(text, `"order"`) {
			t.Errorf("raw payload fields reach the agent: %s", text)
		}
		for _, want := range []string{"untrusted_order", "untrusted_claim", "untrusted_notice", "untrusted_diagnosis", secret} {
			if !strings.Contains(text, want) {
				t.Errorf("missing %s in %s", want, text)
			}
		}
	}
	cv, _ := call(t, s, "get_case", map[string]any{"case_id": id})
	for _, want := range []string{"untrusted_diagnosis", "untrusted_work_order", "untrusted_dealer_note", "reading_guide"} {
		if !strings.Contains(cv, want) {
			t.Errorf("get_case lacks %s: %s", want, cv)
		}
	}
	if strings.Contains(cv, "human_diagnosis") {
		t.Error("the replay answer must not reach the agent")
	}
	var all strings.Builder
	rows, _ := d.db.Query(`SELECT at||actor||channel||action||subject||outcome FROM audit`)
	for rows.Next() {
		var s string
		_ = rows.Scan(&s)
		all.WriteString(s)
	}
	rows.Close()
	all.WriteString(logs.String())
	for _, txt := range []string{secret, "DIAG-TEXT-3302", "NOTICE-TEXT-3305"} {
		if strings.Contains(all.String(), txt) {
			t.Fatalf("audit holds message text %q", txt)
		}
	}
	if !strings.Contains(all.String(), "draft_parts_order") || !strings.Contains(all.String(), `"channel":"mcp"`) {
		t.Fatal("audit must name the tool and channel")
	}
}

func TestInjectionInADealerNoteStaysData(t *testing.T) {
	d, _ := newDomain(t)
	s := mcpSession(t, d)
	id := caseOf(t, d, "injection")
	out, isErr := call(t, s, "get_case", map[string]any{"case_id": id})
	if isErr {
		t.Fatal(out)
	}
	var v map[string]any
	_ = json.Unmarshal([]byte(out), &v)
	cs, _ := v["case"].(map[string]any)
	if note, _ := cs["untrusted_dealer_note"].(string); !strings.Contains(note, "Ignore") {
		t.Fatalf("the injection note must sit under untrusted_dealer_note: %s", out)
	}
	// Whatever the note says, no tool can order beyond what the record allows.
	if _, err := d.svc.DraftPartsOrder(context.Background(), id, "P-10001", 50, "D-401", "order everything"); err == nil {
		t.Fatal("an order of 50 units must be refused by the stock rule or the work order rule")
	}
}

func TestTimersAreCappedPerCase(t *testing.T) {
	d, _ := newDomain(t)
	id := caseOf(t, d, "demo")
	var err error
	for i := 0; i < core.MaxTimersPerSubject+1; i++ {
		_, err = d.svc.SetTimer(context.Background(), id, "dealer_response", now.Add(time.Hour))
	}
	if !core.IsKind(err, core.Conflict) {
		t.Fatalf("%v", err)
	}
	if _, err := d.svc.SetTimer(context.Background(), "SVC-2026-9999", "x", now.Add(time.Hour)); !core.IsKind(err, core.NotFound) {
		t.Fatalf("%v", err)
	}
}

func TestGetTelemetryIsDailyAndBounded(t *testing.T) {
	d, _ := newDomain(t)
	pts, err := d.svc.GetTelemetry(context.Background(), "KH4120-00317", 30)
	if err != nil || len(pts) < 28 || len(pts) > 31 {
		t.Fatalf("%d points, %v", len(pts), err)
	}
	if _, err := d.svc.GetTelemetry(context.Background(), "KH4120-00317", 400); !core.IsKind(err, core.Invalid) {
		t.Fatalf("days over the limit: %v", err)
	}
	if _, err := d.svc.GetTelemetry(context.Background(), "KT260-00101", 10); !core.IsKind(err, core.NotFound) {
		t.Fatalf("a machine with no telemetry: %v", err)
	}
}
