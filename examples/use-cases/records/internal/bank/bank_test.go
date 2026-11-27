package bank

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
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/openagentix/openagentix/examples/use-cases/records/internal/core"
)

var now = time.Date(2026, 11, 27, 10, 0, 0, 0, time.UTC) // a Friday

const leadToken = "lead-token-for-tests"
const clerkToken = "clerk-token-for-tests"

func hash(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) }

func newDomain(t *testing.T) (*Domain, *bytes.Buffer) {
	t.Helper()
	d, logs := newUnseeded(t)
	if err := d.Seed(context.Background()); err != nil {
		t.Fatal(err)
	}
	return d, logs
}

func newUnseeded(t *testing.T) (*Domain, *bytes.Buffer) {
	t.Helper()
	db, err := core.Open(filepath.Join(t.TempDir(), "r.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	p := filepath.Join(t.TempDir(), "approvers.json")
	body := `[{"id":"desk:lead-1","role":"desk-lead","token_sha256":"` + hash(leadToken) + `"},{"id":"desk:clerk-1","role":"desk-clerk","token_sha256":"` + hash(clerkToken) + `"}]`
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

func count(t *testing.T, d *Domain, q string, args ...any) int {
	t.Helper()
	var n int
	if err := d.db.QueryRow(q, args...).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestSeedShapeAndSyntheticData(t *testing.T) {
	d, _ := newDomain(t)
	want := map[string]int{"customers": 40, "merchants": 60}
	for tbl, n := range want {
		if got := count(t, d, `SELECT COUNT(*) FROM `+tbl); got != n {
			t.Errorf("%s: %d want %d", tbl, got, n)
		}
	}
	if n := count(t, d, `SELECT COUNT(*) FROM transactions`); n < 1100 || n > 1400 {
		t.Errorf("transactions: %d", n)
	}
	if n := count(t, d, `SELECT COUNT(*) FROM cases`); n != 60 {
		t.Errorf("cases: %d", n)
	}
	if n := count(t, d, `SELECT COUNT(*) FROM cases WHERE status<>'resolved'`); n != 30 {
		t.Errorf("open cases: %d", n)
	}
	if n := count(t, d, `SELECT COUNT(*) FROM cases WHERE human_decision<>''`); n != 30 {
		t.Errorf("closed cases with a human decision: %d", n)
	}
	// Nothing that looks like real personal data: no e-mail, no phone-like or card-number-like digit runs.
	bad := regexp.MustCompile(`@|[0-9]{9,}|https?://`)
	for _, q := range []string{`SELECT name FROM customers`, `SELECT name FROM merchants`, `SELECT claim_note FROM cases`, `SELECT last4 FROM cards`} {
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
	if n := count(t, d, `SELECT COUNT(*) FROM cards WHERE length(last4)<>4`); n != 0 {
		t.Error("cards must hold only the last four digits")
	}
}

func TestSeedIsIdempotent(t *testing.T) {
	d, _ := newDomain(t)
	if err := d.Seed(context.Background()); err != nil {
		t.Fatal(err)
	}
	if n := count(t, d, `SELECT COUNT(*) FROM customers`); n != 40 {
		t.Fatalf("a second seed must not add rows: %d", n)
	}
}

func TestLinkedFraudRing(t *testing.T) {
	d, _ := newDomain(t)
	var ring string
	if err := d.db.QueryRow(`SELECT id FROM cases WHERE pattern='fraud_ring' ORDER BY id LIMIT 1`).Scan(&ring); err != nil {
		t.Fatal(err)
	}
	l, err := d.svc.LinkedCases(context.Background(), ring)
	if err != nil {
		t.Fatal(err)
	}
	if len(l.SameDevice) != 4 || len(l.SameMerchant) < 4 {
		t.Fatalf("the ring has 5 cases sharing a device and merchant: %+v", l)
	}
}

func TestWorkingDays(t *testing.T) {
	fri := time.Date(2026, 11, 27, 10, 0, 0, 0, time.UTC)
	if got := AddWorkingDays(fri, 1); got.Weekday() != time.Monday || got.Day() != 30 {
		t.Errorf("one working day after Friday is Monday, got %v", got)
	}
	if got := AddWorkingDays(fri, 10); got.Day() != 11 || got.Month() != time.December {
		t.Errorf("ten working days after 27 Nov is 11 Dec, got %v", got)
	}
}

func firstOpenCase(t *testing.T, d *Domain) CaseView {
	t.Helper()
	var id string
	if err := d.db.QueryRow(`SELECT id FROM cases WHERE status='open' AND pattern='' ORDER BY id LIMIT 1`).Scan(&id); err != nil {
		t.Fatal(err)
	}
	c, err := d.svc.GetCase(context.Background(), id)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func prepare(t *testing.T, d *Domain, route string) CaseView {
	t.Helper()
	ctx := context.Background()
	c := firstOpenCase(t, d)
	if _, err := d.svc.SetRoute(ctx, c.ID, route, "rule applied"); err != nil {
		t.Fatal(err)
	}
	if _, err := d.svc.DraftLetter(ctx, c.ID, "Dear customer, your dispute was reviewed."); err != nil {
		t.Fatal(err)
	}
	if route != RouteDecline {
		if _, err := d.svc.DraftChargeback(ctx, c.ID, "Filing: reason code 4001, evidence attached."); err != nil {
			t.Fatal(err)
		}
	}
	return c
}

func TestNoMoneyOrLetterBeforeApproval(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	c := prepare(t, d, RouteCreditThenChargeback)
	a, err := d.svc.RequestApproval(ctx, c.ID, RouteCreditThenChargeback, c.AmountCents)
	if err != nil {
		t.Fatal(err)
	}
	if a.Status != "pending" {
		t.Fatal(a.Status)
	}
	if n := count(t, d, `SELECT COUNT(*) FROM ledger`); n != 0 {
		t.Fatal("credit posted before approval")
	}
	if n := count(t, d, `SELECT COUNT(*) FROM outbox WHERE status='queued'`); n != 0 {
		t.Fatal("something queued before approval")
	}
	got, _ := d.svc.GetCase(ctx, c.ID)
	if got.Status != "pending_approval" {
		t.Fatalf("status %s", got.Status)
	}
}

func TestApproveCreditPostsLedgerOnceAndQueuesOutbox(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	c := prepare(t, d, RouteCreditThenChargeback)
	var before int64
	_ = d.db.QueryRow(`SELECT balance_cents FROM accounts WHERE id=?`, c.AccountID).Scan(&before)
	a, _ := d.svc.RequestApproval(ctx, c.ID, RouteCreditThenChargeback, c.AmountCents)
	done, err := d.approvals.Approve(ctx, a.ID, core.Approver{ID: "desk:lead-1", Role: "desk-lead"}, a.PayloadHash, "ok")
	if err != nil {
		t.Fatal(err)
	}
	if done.DecidedBy != "desk:lead-1" || done.SubjectVersion == 0 {
		t.Fatalf("%+v", done)
	}
	var after int64
	_ = d.db.QueryRow(`SELECT balance_cents FROM accounts WHERE id=?`, c.AccountID).Scan(&after)
	if after-before != c.AmountCents || count(t, d, `SELECT COUNT(*) FROM ledger WHERE case_id=?`, c.ID) != 1 {
		t.Fatalf("balance %d -> %d", before, after)
	}
	if n := count(t, d, `SELECT COUNT(*) FROM outbox WHERE subject=? AND status='queued'`, c.ID); n != 2 {
		t.Fatalf("letter and filing must be queued, got %d", n)
	}
	got, _ := d.svc.GetCase(ctx, c.ID)
	if got.Status != "resolved" {
		t.Fatalf("status %s", got.Status)
	}
	if _, err := d.approvals.Approve(ctx, a.ID, core.Approver{ID: "desk:lead-1", Role: "desk-lead"}, a.PayloadHash, ""); err == nil {
		t.Fatal("second approval must fail")
	}
	if n := count(t, d, `SELECT COUNT(*) FROM ledger`); n != 1 {
		t.Fatal("credit posted twice")
	}
}

func TestChargebackWithoutCreditAndDecline(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	c := prepare(t, d, RouteChargeback)
	a, err := d.svc.RequestApproval(ctx, c.ID, RouteChargeback, c.AmountCents)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.approvals.Approve(ctx, a.ID, core.Approver{ID: "desk:lead-1", Role: "desk-lead"}, a.PayloadHash, ""); err != nil {
		t.Fatal(err)
	}
	if n := count(t, d, `SELECT COUNT(*) FROM ledger`); n != 0 {
		t.Fatal("a chargeback without credit must not touch the ledger")
	}
	d2, _ := newDomain(t)
	c2 := prepare(t, d2, RouteDecline)
	a2, err := d2.svc.RequestApproval(ctx, c2.ID, RouteDecline, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d2.approvals.Approve(ctx, a2.ID, core.Approver{ID: "desk:lead-1", Role: "desk-lead"}, a2.PayloadHash, ""); err != nil {
		t.Fatal(err)
	}
	if n := count(t, d2, `SELECT COUNT(*) FROM outbox WHERE status='queued'`); n != 1 {
		t.Fatalf("decline queues only the letter, got %d", n)
	}
}

func TestRejectReturnsCaseToAnalyst(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	c := prepare(t, d, RouteCreditThenChargeback)
	a, _ := d.svc.RequestApproval(ctx, c.ID, RouteCreditThenChargeback, c.AmountCents)
	if _, err := d.approvals.Reject(ctx, a.ID, core.Approver{ID: "desk:lead-1", Role: "desk-lead"}, "need the receipt"); err != nil {
		t.Fatal(err)
	}
	got, _ := d.svc.GetCase(ctx, c.ID)
	if got.Status != "needs_analyst" || got.Route != RouteInconclusive {
		t.Fatalf("%s %s", got.Status, got.Route)
	}
	if count(t, d, `SELECT COUNT(*) FROM ledger`) != 0 || count(t, d, `SELECT COUNT(*) FROM outbox WHERE status='queued'`) != 0 {
		t.Fatal("a rejection must release nothing")
	}
}

func TestRequestApprovalRefusals(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	c := firstOpenCase(t, d)
	if _, err := d.svc.RequestApproval(ctx, c.ID, RouteChargeback, c.AmountCents); !core.IsKind(err, core.Conflict) {
		t.Errorf("no route set: %v", err)
	}
	_, _ = d.svc.SetRoute(ctx, c.ID, RouteChargeback, "r")
	if _, err := d.svc.RequestApproval(ctx, c.ID, RouteChargeback, c.AmountCents); !core.IsKind(err, core.Conflict) {
		t.Errorf("no drafts: %v", err)
	}
	_, _ = d.svc.DraftLetter(ctx, c.ID, "letter")
	_, _ = d.svc.DraftChargeback(ctx, c.ID, "filing")
	if _, err := d.svc.RequestApproval(ctx, c.ID, RouteDecline, 0); !core.IsKind(err, core.Conflict) {
		t.Errorf("kind must equal the route: %v", err)
	}
	if _, err := d.svc.RequestApproval(ctx, c.ID, RouteChargeback, c.AmountCents+1); !core.IsKind(err, core.Invalid) {
		t.Errorf("amount over the disputed amount: %v", err)
	}
	if _, err := d.svc.RequestApproval(ctx, c.ID, RouteChargeback, 0); !core.IsKind(err, core.Invalid) {
		t.Errorf("a chargeback needs an amount: %v", err)
	}
	if _, err := d.svc.RequestApproval(ctx, c.ID, RouteInconclusive, 0); !core.IsKind(err, core.Invalid) {
		t.Errorf("inconclusive is not an approvable kind: %v", err)
	}
}

func TestRedraftAfterProposalInvalidatesApproval(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	c := prepare(t, d, RouteChargeback)
	a, _ := d.svc.RequestApproval(ctx, c.ID, RouteChargeback, c.AmountCents)
	if _, err := d.svc.DraftLetter(ctx, c.ID, "A different letter after the proposal."); err != nil {
		t.Fatal(err)
	}
	if _, err := d.approvals.Approve(ctx, a.ID, core.Approver{ID: "desk:lead-1", Role: "desk-lead"}, a.PayloadHash, ""); !core.IsKind(err, core.Conflict) {
		t.Fatalf("approving what changed must conflict, got %v", err)
	}
	if count(t, d, `SELECT COUNT(*) FROM outbox WHERE status='queued'`) != 0 {
		t.Fatal("stale approval released drafts")
	}
}

func TestCreateCaseValidation(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	var acc, txn string
	_ = d.db.QueryRow(`SELECT t.account_id, t.id FROM transactions t WHERE t.amount_cents>0 AND NOT EXISTS (SELECT 1 FROM cases c WHERE c.transaction_id=t.id) LIMIT 1`).Scan(&acc, &txn)
	c, err := d.svc.CreateCase(ctx, NewCase{AccountID: acc, TransactionID: txn, ClaimType: "not_recognised", ClaimNote: "I did not make this."})
	if err != nil || c.Status != "open" || !strings.HasPrefix(c.ID, "DSP-2026-") || c.ResponseDue == "" {
		t.Fatalf("%+v %v", c, err)
	}
	if _, err := d.svc.CreateCase(ctx, NewCase{AccountID: acc, TransactionID: txn, ClaimType: "not_recognised"}); !core.IsKind(err, core.Conflict) {
		t.Errorf("second open case on the same transaction: %v", err)
	}
	for name, in := range map[string]NewCase{
		"bad claim type": {AccountID: acc, TransactionID: txn, ClaimType: "because"},
		"bad account id": {AccountID: "x'; DROP TABLE cases;--", TransactionID: txn, ClaimType: "duplicate"},
		"unknown txn":    {AccountID: acc, TransactionID: "T-999999", ClaimType: "duplicate"},
		"long note":      {AccountID: acc, TransactionID: txn, ClaimType: "duplicate", ClaimNote: strings.Repeat("x", 600)},
	} {
		if _, err := d.svc.CreateCase(ctx, in); err == nil {
			t.Errorf("%s: want error", name)
		}
	}
	if count(t, d, `SELECT COUNT(*) FROM cases`) != 61 {
		t.Error("only the valid case may be stored")
	}
}

func TestTimersAndSweepView(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	c := firstOpenCase(t, d)
	tm, err := d.svc.SetTimer(ctx, c.ID, "scheme_response", now.Add(24*time.Hour))
	if err != nil || tm.Status != "pending" {
		t.Fatal(tm, err)
	}
	if _, err := d.svc.SetTimer(ctx, "DSP-2026-9999", "scheme_response", now.Add(time.Hour)); !core.IsKind(err, core.NotFound) {
		t.Errorf("timer on a missing case: %v", err)
	}
	fired, _ := d.timers.FireDue(ctx, now.Add(48*time.Hour))
	if len(fired) != 1 {
		t.Fatal(len(fired))
	}
}

func rest(t *testing.T, d *Domain, method, path, token, body string) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest(method, path, strings.NewReader(body))
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
	c := prepare(t, d, RouteChargeback)
	a, _ := d.svc.RequestApproval(ctx, c.ID, RouteChargeback, c.AmountCents)
	body := `{"payload_hash":"` + a.PayloadHash + `","note":"ok"}`
	path := "/approvals/" + a.ID + "/approve"
	if w := rest(t, d, "POST", path, "", body); w.Code != 401 {
		t.Errorf("no token: %d", w.Code)
	}
	if w := rest(t, d, "POST", path, "wrong", body); w.Code != 401 {
		t.Errorf("wrong token: %d", w.Code)
	}
	if w := rest(t, d, "POST", path, clerkToken, body); w.Code != 403 {
		t.Errorf("wrong role: %d", w.Code)
	}
	if w := rest(t, d, "POST", path, leadToken, `{"payload_hash":"nope"}`); w.Code != 409 {
		t.Errorf("stale hash: %d", w.Code)
	}
	if count(t, d, `SELECT COUNT(*) FROM outbox WHERE status='queued'`) != 0 {
		t.Fatal("a refused call released something")
	}
	w := rest(t, d, "POST", path, leadToken, body)
	if w.Code != 200 {
		t.Fatalf("lead: %d %s", w.Code, w.Body)
	}
	var got core.Approval
	_ = json.Unmarshal(w.Body.Bytes(), &got)
	if got.Status != "approved" || got.DecidedBy != "desk:lead-1" {
		t.Fatalf("%+v", got)
	}
	if w := rest(t, d, "GET", "/audit", "", ""); w.Code != 401 {
		t.Errorf("audit without a token: %d", w.Code)
	}
	if w := rest(t, d, "GET", "/audit", leadToken, ""); w.Code != 200 {
		t.Errorf("audit with a token: %d", w.Code)
	}
}

func TestRESTValidationAndHealth(t *testing.T) {
	d, _ := newDomain(t)
	for _, p := range []string{"/healthz", "/readyz"} {
		if w := rest(t, d, "GET", p, "", ""); w.Code != 200 {
			t.Errorf("%s: %d", p, w.Code)
		}
	}
	for path, want := range map[string]int{
		"/cases/DSP-2026-0001":                                  200,
		"/cases/nope":                                           400,
		"/cases/DSP-2026-0001'%20OR%201=1":                      400,
		"/cases/DSP-2026-9999":                                  404,
		"/clients/C-1001":                                       200,
		"/clients/C-1001;DROP":                                  400,
		"/savingsaccounts/ACC-2001/transactions":                200,
		"/savingsaccounts/ACC-2001/transactions?from=yesterday": 400,
		"/savingsaccounts/ACC-2001/transactions?limit=100000":   400,
		"/merchants/M-501/history":                              200,
		"/cases?status=bogus":                                   400,
		"/approvals?status=bogus":                               400,
	} {
		if w := rest(t, d, "GET", path, "", ""); w.Code != want {
			t.Errorf("%s: %d want %d", path, w.Code, want)
		}
	}
	if w := rest(t, d, "POST", "/cases", "", `{"unknown":1}`); w.Code != 400 {
		t.Errorf("unknown field: %d", w.Code)
	}
	if w := rest(t, d, "POST", "/cases", "", strings.Repeat("x", 70000)); w.Code != 400 {
		t.Errorf("oversize body: %d", w.Code)
	}
	if count(t, d, `SELECT COUNT(*) FROM cases`) != 60 {
		t.Error("bad requests changed data")
	}
}

func TestRESTHasNoUnauthenticatedMoneyRoute(t *testing.T) {
	d, _ := newDomain(t)
	for _, c := range [][2]string{
		{"POST", "/ledger"}, {"POST", "/outbox"}, {"POST", "/outbox/OUT-0001/send"},
		{"POST", "/cases/DSP-2026-0001/approve"}, {"POST", "/cases/DSP-2026-0001/credit"},
		{"PUT", "/ledger"}, {"DELETE", "/approvals/APR-0001"},
	} {
		if w := rest(t, d, c[0], c[1], "", `{}`); w.Code != 404 && w.Code != 405 {
			t.Errorf("%s %s: %d", c[0], c[1], w.Code)
		}
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

func TestMCPToolsHaveNoMoneyOrSendTool(t *testing.T) {
	d, _ := newDomain(t)
	s := mcpSession(t, d)
	list, err := s.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	have := map[string]bool{}
	for _, tl := range list.Tools {
		have[tl.Name] = true
		if regexp.MustCompile(`approve|reject|post|credit|send|execute|release|decide|ledger`).MatchString(tl.Name) {
			t.Errorf("tool %q could move money or release a letter", tl.Name)
		}
	}
	for _, want := range []string{"get_case", "list_open_cases", "list_transactions", "get_card_status", "get_merchant_history",
		"find_linked_cases", "attach_evidence", "set_route", "draft_letter", "draft_chargeback", "set_timer", "request_approval", "get_approval"} {
		if !have[want] {
			t.Errorf("missing tool %s", want)
		}
	}
}

func TestMCPFlowStopsAtApprovalAndAuditHasNoText(t *testing.T) {
	d, logs := newDomain(t)
	s := mcpSession(t, d)
	c := firstOpenCase(t, d)
	secret := "UNIQUE-LETTER-TEXT-7731"
	if out, isErr := call(t, s, "set_route", map[string]any{"case_id": c.ID, "route": RouteChargeback, "reason": "merchant error"}); isErr {
		t.Fatal(out)
	}
	if out, isErr := call(t, s, "draft_letter", map[string]any{"case_id": c.ID, "body": secret}); isErr {
		t.Fatal(out)
	}
	if out, isErr := call(t, s, "draft_chargeback", map[string]any{"case_id": c.ID, "body": "filing text"}); isErr {
		t.Fatal(out)
	}
	out, isErr := call(t, s, "request_approval", map[string]any{"case_id": c.ID, "kind": RouteChargeback, "amount_cents": c.AmountCents})
	if isErr || !strings.Contains(out, "pending") {
		t.Fatalf("%s", out)
	}
	if count(t, d, `SELECT COUNT(*) FROM ledger`) != 0 || count(t, d, `SELECT COUNT(*) FROM outbox WHERE status='queued'`) != 0 {
		t.Fatal("the agent path released something")
	}
	if out, isErr := call(t, s, "set_route", map[string]any{"case_id": "bad id", "route": RouteChargeback, "reason": "x"}); !isErr {
		t.Errorf("a bad id must be a tool error: %s", out)
	}
	// Audit: tool names and outcomes, no text, no customer name.
	var all strings.Builder
	rows, _ := d.db.Query(`SELECT at||actor||channel||action||subject||outcome FROM audit`)
	for rows.Next() {
		var s string
		_ = rows.Scan(&s)
		all.WriteString(s)
	}
	rows.Close()
	all.WriteString(logs.String())
	if strings.Contains(all.String(), secret) || strings.Contains(all.String(), "merchant error") {
		t.Fatal("audit holds message text")
	}
	if !strings.Contains(all.String(), "draft_letter") || !strings.Contains(all.String(), `"channel":"mcp"`) {
		t.Fatal("audit must name the tool and channel")
	}
}

func TestMCPViewsDropCustomerNameAndMarkUntrustedText(t *testing.T) {
	d, _ := newDomain(t)
	s := mcpSession(t, d)
	var id, name string
	_ = d.db.QueryRow(`SELECT c.id, cu.name FROM cases c JOIN accounts a ON a.id=c.account_id JOIN customers cu ON cu.id=a.customer_id WHERE c.pattern='injection'`).Scan(&id, &name)
	out, isErr := call(t, s, "get_case", map[string]any{"case_id": id})
	if isErr {
		t.Fatal(out)
	}
	if strings.Contains(out, name) {
		t.Error("the customer's name must not reach the agent")
	}
	if !strings.Contains(out, "untrusted_customer_text") || strings.Contains(out, "human_decision") {
		t.Errorf("claim text must be labelled, and the replay answer hidden: %s", out)
	}
}

// Review fixes (findings 1 to 8).

var leadApprover = core.Approver{ID: "desk:lead-1", Role: "desk-lead"}

func approvalPayload(t *testing.T, a core.Approval) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal([]byte(a.Payload), &m); err != nil {
		t.Fatalf("payload is not JSON: %v", err)
	}
	return m
}

func TestDeclineNeverQueuesAFiling(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	c := firstOpenCase(t, d)
	_, _ = d.svc.SetRoute(ctx, c.ID, RouteDecline, "outside the rules")
	_, _ = d.svc.DraftLetter(ctx, c.ID, "Decline letter.")
	_, _ = d.svc.DraftChargeback(ctx, c.ID, "filing nobody approved")
	a, err := d.svc.RequestApproval(ctx, c.ID, RouteDecline, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, has := approvalPayload(t, a)["filing"]; has {
		t.Error("a decline payload must not carry a filing")
	}
	if _, err := d.approvals.Approve(ctx, a.ID, leadApprover, a.PayloadHash, ""); err != nil {
		t.Fatal(err)
	}
	if n := count(t, d, `SELECT COUNT(*) FROM outbox WHERE kind='chargeback_filing' AND status='queued'`); n != 0 {
		t.Fatalf("an approved decline queued %d filings", n)
	}
	if n := count(t, d, `SELECT COUNT(*) FROM outbox WHERE kind='letter' AND status='queued'`); n != 1 {
		t.Fatalf("the letter must be queued, got %d", n)
	}
}

func TestApprovalViewCarriesWhatTheHashCovers(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	c := prepare(t, d, RouteCreditThenChargeback)
	a, _ := d.svc.RequestApproval(ctx, c.ID, RouteCreditThenChargeback, c.AmountCents)
	w := rest(t, d, "GET", "/approvals/"+a.ID, "", "")
	if w.Code != 200 {
		t.Fatal(w.Code)
	}
	var got core.Approval
	_ = json.Unmarshal(w.Body.Bytes(), &got)
	m := approvalPayload(t, got)
	for _, k := range []string{"case_id", "account_id", "transaction_id", "kind", "amount_cents", "route_reason", "letter", "filing", "case_version", "prior_credit_cents"} {
		if _, ok := m[k]; !ok {
			t.Errorf("payload lacks %s", k)
		}
	}
	if m["letter"] != "Dear customer, your dispute was reviewed." || m["filing"] != "Filing: reason code 4001, evidence attached." {
		t.Errorf("payload text: %v", m)
	}
	if got.PayloadHash != core.HashPayload(string(got.Payload)) {
		t.Error("the hash must be the hash of the payload shown")
	}
	// The record changes afterwards: the approval view keeps showing what was proposed.
	if _, err := d.svc.DraftLetter(ctx, c.ID, "A new letter."); err != nil {
		t.Fatal(err)
	}
	again, _ := d.approvals.Get(ctx, a.ID)
	if again.Status != "superseded" || approvalPayload(t, again)["letter"] != "Dear customer, your dispute was reviewed." {
		t.Errorf("frozen payload lost: %s %v", again.Status, approvalPayload(t, again)["letter"])
	}
}

func TestSecondCreditOnACreditedTransactionIsRefused(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	c := prepare(t, d, RouteCreditThenChargeback)
	a, _ := d.svc.RequestApproval(ctx, c.ID, RouteCreditThenChargeback, c.AmountCents)
	if _, err := d.approvals.Approve(ctx, a.ID, leadApprover, a.PayloadHash, ""); err != nil {
		t.Fatal(err)
	}
	b, err := d.svc.CreateCase(ctx, NewCase{AccountID: c.AccountID, TransactionID: c.TransactionID, ClaimType: "duplicate"})
	if err != nil {
		t.Fatal(err)
	}
	_, _ = d.svc.SetRoute(ctx, b.ID, RouteCreditThenChargeback, "again")
	_, _ = d.svc.DraftLetter(ctx, b.ID, "letter")
	_, _ = d.svc.DraftChargeback(ctx, b.ID, "filing")
	if _, err := d.svc.RequestApproval(ctx, b.ID, RouteCreditThenChargeback, b.AmountCents); !core.IsKind(err, core.Conflict) {
		t.Fatalf("a second credit on one transaction must be refused, got %v", err)
	}
	// A chargeback without credit is still possible, and the approver sees the earlier credit.
	_, _ = d.svc.SetRoute(ctx, b.ID, RouteChargeback, "no second credit")
	a2, err := d.svc.RequestApproval(ctx, b.ID, RouteChargeback, b.AmountCents)
	if err != nil {
		t.Fatal(err)
	}
	if got := approvalPayload(t, a2)["prior_credit_cents"]; got != float64(c.AmountCents) {
		t.Errorf("prior_credit_cents = %v, want %d", got, c.AmountCents)
	}
	if n := count(t, d, `SELECT COUNT(*) FROM ledger`); n != 1 {
		t.Fatalf("ledger rows %d", n)
	}
}

func TestClosedAccountGetsNoCredit(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	c := prepare(t, d, RouteCreditThenChargeback)
	if _, err := d.db.Exec(`UPDATE accounts SET status='closed' WHERE id=?`, c.AccountID); err != nil {
		t.Fatal(err)
	}
	if _, err := d.svc.RequestApproval(ctx, c.ID, RouteCreditThenChargeback, c.AmountCents); !core.IsKind(err, core.Conflict) {
		t.Fatalf("credit to a closed account: %v", err)
	}
}

func TestAnyChangeAfterProposalSupersedesIt(t *testing.T) {
	changes := map[string]func(d *Domain, id string) error{
		"evidence": func(d *Domain, id string) error {
			_, err := d.svc.AttachEvidence(context.Background(), id, "gap", "", "a late note")
			return err
		},
		"status": func(d *Domain, id string) error {
			_, err := d.svc.SetStatus(context.Background(), id, "in_review")
			return err
		},
		"letter": func(d *Domain, id string) error {
			_, err := d.svc.DraftLetter(context.Background(), id, "changed letter")
			return err
		},
		"filing": func(d *Domain, id string) error {
			_, err := d.svc.DraftChargeback(context.Background(), id, "changed filing")
			return err
		},
		"route": func(d *Domain, id string) error {
			_, err := d.svc.SetRoute(context.Background(), id, RouteDecline, "changed my mind")
			return err
		},
	}
	for name, change := range changes {
		t.Run(name, func(t *testing.T) {
			d, _ := newDomain(t)
			ctx := context.Background()
			c := prepare(t, d, RouteChargeback)
			a, _ := d.svc.RequestApproval(ctx, c.ID, RouteChargeback, c.AmountCents)
			if err := change(d, c.ID); err != nil {
				t.Fatal(err)
			}
			got, _ := d.approvals.Get(ctx, a.ID)
			if got.Status != "superseded" {
				t.Fatalf("status %s", got.Status)
			}
			if _, err := d.approvals.Approve(ctx, a.ID, leadApprover, a.PayloadHash, ""); !core.IsKind(err, core.Conflict) {
				t.Fatalf("approving a superseded approval: %v", err)
			}
			if count(t, d, `SELECT COUNT(*) FROM outbox WHERE status='queued'`) != 0 || count(t, d, `SELECT COUNT(*) FROM ledger`) != 0 {
				t.Fatal("a superseded approval released something")
			}
		})
	}
}

func TestProposalIsOneStep(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	c := prepare(t, d, RouteChargeback)
	a, _ := d.svc.RequestApproval(ctx, c.ID, RouteChargeback, c.AmountCents)
	got, _ := d.svc.GetCase(ctx, c.ID)
	if got.Status != "pending_approval" || got.Version != int64(approvalPayload(t, a)["case_version"].(float64)) {
		t.Fatalf("the proposal must set the status without bumping the version: %s v%d", got.Status, got.Version)
	}
}

func TestTwoApprovalsAtOnceExecuteOnce(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	c := prepare(t, d, RouteCreditThenChargeback)
	a, _ := d.svc.RequestApproval(ctx, c.ID, RouteCreditThenChargeback, c.AmountCents)
	errs := make(chan error, 2)
	for i := 0; i < 2; i++ {
		go func() {
			_, err := d.approvals.Approve(ctx, a.ID, leadApprover, a.PayloadHash, "")
			errs <- err
		}()
	}
	ok := 0
	for i := 0; i < 2; i++ {
		if err := <-errs; err == nil {
			ok++
		} else if !core.IsKind(err, core.Conflict) {
			t.Errorf("the loser must get a conflict: %v", err)
		}
	}
	if ok != 1 || count(t, d, `SELECT COUNT(*) FROM ledger`) != 1 {
		t.Fatalf("approved %d times, ledger rows %d", ok, count(t, d, `SELECT COUNT(*) FROM ledger`))
	}
}

func TestOldHashAfterReproposalFails(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	c := prepare(t, d, RouteChargeback)
	old, _ := d.svc.RequestApproval(ctx, c.ID, RouteChargeback, c.AmountCents)
	_, _ = d.svc.DraftLetter(ctx, c.ID, "second letter")
	fresh, err := d.svc.RequestApproval(ctx, c.ID, RouteChargeback, c.AmountCents)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.approvals.Approve(ctx, fresh.ID, leadApprover, old.PayloadHash, ""); !core.IsKind(err, core.Conflict) {
		t.Fatalf("the old hash on the new approval: %v", err)
	}
	if _, err := d.approvals.Approve(ctx, old.ID, leadApprover, old.PayloadHash, ""); !core.IsKind(err, core.Conflict) {
		t.Fatalf("the old approval: %v", err)
	}
}

func TestRESTRejectNeedsTokenAndRole(t *testing.T) {
	d, _ := newDomain(t)
	ctx := context.Background()
	c := prepare(t, d, RouteChargeback)
	a, _ := d.svc.RequestApproval(ctx, c.ID, RouteChargeback, c.AmountCents)
	path := "/approvals/" + a.ID + "/reject"
	if w := rest(t, d, "POST", path, "", `{"note":"x"}`); w.Code != 401 {
		t.Errorf("no token: %d", w.Code)
	}
	if w := rest(t, d, "POST", path, clerkToken, `{"note":"x"}`); w.Code != 403 {
		t.Errorf("wrong role: %d", w.Code)
	}
	got, _ := d.approvals.Get(ctx, a.ID)
	if got.Status != "pending" {
		t.Fatalf("a refused reject changed the approval: %s", got.Status)
	}
	if w := rest(t, d, "POST", path, leadToken, `{"note":"x"}`); w.Code != 200 {
		t.Errorf("lead: %d", w.Code)
	}
}

func TestApproverCannotApproveTheirOwnProposal(t *testing.T) {
	d, _ := newDomain(t)
	c := prepare(t, d, RouteChargeback)
	w := rest(t, d, "POST", "/approvals", leadToken, `{"case_id":"`+c.ID+`","kind":"chargeback","amount_cents":`+strconv.FormatInt(c.AmountCents, 10)+`}`)
	if w.Code != 201 {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	var a core.Approval
	_ = json.Unmarshal(w.Body.Bytes(), &a)
	if a.ProposedBy != "desk:lead-1" {
		t.Fatalf("proposed_by %q: a proposal made with an approver token carries that name", a.ProposedBy)
	}
	body := `{"payload_hash":"` + a.PayloadHash + `"}`
	if w := rest(t, d, "POST", "/approvals/"+a.ID+"/approve", leadToken, body); w.Code != 403 {
		t.Fatalf("own proposal: %d", w.Code)
	}
	if count(t, d, `SELECT COUNT(*) FROM outbox WHERE status='queued'`) != 0 {
		t.Fatal("released")
	}
}

func TestReadyFailsOnAnUnseededStore(t *testing.T) {
	d, _ := newUnseeded(t)
	if w := rest(t, d, "GET", "/readyz", "", ""); w.Code != 503 {
		t.Fatalf("readyz on an empty store: %d", w.Code)
	}
	if err := d.Seed(context.Background()); err != nil {
		t.Fatal(err)
	}
	if w := rest(t, d, "GET", "/readyz", "", ""); w.Code != 200 {
		t.Fatalf("readyz after seed: %d", w.Code)
	}
}

func TestRESTWritesNeedJSONAndRefuseCrossOrigin(t *testing.T) {
	d, _ := newDomain(t)
	r := httptest.NewRequest("POST", "/cases", strings.NewReader(`{}`))
	r.Header.Set("Content-Type", "text/plain")
	w := httptest.NewRecorder()
	d.Handler().ServeHTTP(w, r)
	if w.Code != 400 {
		t.Errorf("text/plain: %d", w.Code)
	}
	r = httptest.NewRequest("POST", "/cases", strings.NewReader(`{}`))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Origin", "http://evil.example")
	r.Header.Set("Sec-Fetch-Site", "cross-site")
	w = httptest.NewRecorder()
	d.Handler().ServeHTTP(w, r)
	if w.Code != 403 {
		t.Errorf("cross-origin write: %d", w.Code)
	}
	if count(t, d, `SELECT COUNT(*) FROM cases`) != 60 {
		t.Error("a refused write changed data")
	}
}

func TestRESTWritesAreRateLimitedPerHost(t *testing.T) {
	d, _ := newDomain(t)
	got429 := false
	for i := 0; i < WriteLimitPerMinute+20; i++ {
		if w := rest(t, d, "POST", "/approvals/APR-0001/approve", "wrong", `{}`); w.Code == 429 {
			got429 = true
			break
		}
	}
	if !got429 {
		t.Fatal("token guessing must be rate limited")
	}
}

func TestTimersPerCaseAreCapped(t *testing.T) {
	d, _ := newDomain(t)
	c := firstOpenCase(t, d)
	var err error
	for i := 0; i < core.MaxTimersPerSubject+1; i++ {
		_, err = d.svc.SetTimer(context.Background(), c.ID, "x_timer", now.Add(time.Hour))
	}
	if !core.IsKind(err, core.Conflict) {
		t.Fatalf("timer cap: %v", err)
	}
}

func TestAgentViewLabelsEverythingWrittenThroughREST(t *testing.T) {
	d, _ := newDomain(t)
	s := mcpSession(t, d)
	c := firstOpenCase(t, d)
	if _, err := d.svc.AttachEvidence(context.Background(), c.ID, "other", "", "EVIDENCE-NOTE-9917"); err != nil {
		t.Fatal(err)
	}
	if _, err := d.svc.SetRoute(context.Background(), c.ID, RouteChargeback, "REASON-TEXT-4402"); err != nil {
		t.Fatal(err)
	}
	out, isErr := call(t, s, "get_case", map[string]any{"case_id": c.ID})
	if isErr {
		t.Fatal(out)
	}
	if strings.Contains(out, `"route_reason"`) || strings.Contains(out, `"note"`) && !strings.Contains(out, "untrusted_note") {
		t.Errorf("free text must sit under untrusted_ field names: %s", out)
	}
	for _, want := range []string{"untrusted_route_reason", "untrusted_note", "REASON-TEXT-4402", "EVIDENCE-NOTE-9917"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %s in %s", want, out)
		}
	}
}

// Re-check follow-ups.

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

func TestRESTProposalNeedsATokenFromOutsideThePod(t *testing.T) {
	d, _ := newDomain(t)
	c := prepare(t, d, RouteChargeback)
	body := `{"case_id":"` + c.ID + `","kind":"chargeback","amount_cents":` + strconv.FormatInt(c.AmountCents, 10) + `}`
	if w := restFrom(t, d, "10.4.5.6:4000", "POST", "/approvals", "", body); w.Code != 401 {
		t.Fatalf("remote without a token: %d", w.Code)
	}
	if n := count(t, d, `SELECT COUNT(*) FROM approvals`); n != 0 {
		t.Fatal("a refused proposal was stored")
	}
	w := restFrom(t, d, "127.0.0.1:4000", "POST", "/approvals", "", body)
	if w.Code != 201 {
		t.Fatalf("loopback without a token: %d %s", w.Code, w.Body)
	}
	var a core.Approval
	_ = json.Unmarshal(w.Body.Bytes(), &a)
	if a.ProposedBy != "rest" {
		t.Fatalf("proposed_by %q", a.ProposedBy)
	}
}

func TestFailedLoginsGetTooManyRequests(t *testing.T) {
	d, _ := newDomain(t)
	last := 0
	for i := 0; i < core.FailLimitPerMinute+5; i++ {
		last = restFrom(t, d, "10.4.5.6:4000", "GET", "/audit", "wrong", "").Code
	}
	if last != 429 {
		t.Fatalf("repeated failed logins ended with %d", last)
	}
	if w := restFrom(t, d, "10.4.5.6:4000", "GET", "/audit", leadToken, ""); w.Code != 200 {
		t.Fatalf("a valid token must still work: %d", w.Code)
	}
}

func TestMCPApprovalResultLabelsAgentAndRESTText(t *testing.T) {
	d, _ := newDomain(t)
	s := mcpSession(t, d)
	c := firstOpenCase(t, d)
	_, _ = d.svc.SetRoute(context.Background(), c.ID, RouteChargeback, "ROUTE-TEXT-5521")
	_, _ = d.svc.DraftLetter(context.Background(), c.ID, "LETTER-TEXT-5522")
	_, _ = d.svc.DraftChargeback(context.Background(), c.ID, "FILING-TEXT-5523")
	out, isErr := call(t, s, "request_approval", map[string]any{"case_id": c.ID, "kind": RouteChargeback, "amount_cents": c.AmountCents})
	if isErr {
		t.Fatal(out)
	}
	id := regexp.MustCompile(`APR-[0-9]{4}`).FindString(out)
	got, isErr := call(t, s, "get_approval", map[string]any{"approval_id": id})
	if isErr {
		t.Fatal(got)
	}
	for _, text := range []string{out, got} {
		if strings.Contains(text, `"payload"`) || strings.Contains(text, `"route_reason"`) || strings.Contains(text, `"letter"`) {
			t.Errorf("raw payload fields reach the agent: %s", text)
		}
		for _, want := range []string{"untrusted_route_reason", "untrusted_letter", "untrusted_filing", "ROUTE-TEXT-5521", "LETTER-TEXT-5522"} {
			if !strings.Contains(text, want) {
				t.Errorf("missing %s in %s", want, text)
			}
		}
	}
}
