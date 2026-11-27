package core

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var t0 = time.Date(2026, 3, 2, 9, 0, 0, 0, time.UTC)

func testDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := Open(filepath.Join(t.TempDir(), "r.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := MigrateCore(context.Background(), db); err != nil {
		t.Fatal(err)
	}
	return db
}

func sum(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) }

func writeApprovers(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "approvers.json")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestApproversDisabledWhenNoFile(t *testing.T) {
	a, err := LoadApprovers("")
	if err != nil || a.Enabled() {
		t.Fatalf("want disabled, got %v %v", a, err)
	}
	r := httptest.NewRequest("POST", "/x", nil)
	r.Header.Set("Authorization", "Bearer anything")
	if _, ok := a.Authenticate(r); ok {
		t.Fatal("a disabled store must authenticate nobody")
	}
}

func TestApproversAuthenticate(t *testing.T) {
	p := writeApprovers(t, `[{"id":"desk:lead-1","role":"desk-lead","token_sha256":"`+sum("good-token")+`"}]`)
	a, err := LoadApprovers(p)
	if err != nil || !a.Enabled() {
		t.Fatal(err)
	}
	cases := []struct {
		name, header string
		ok           bool
	}{
		{"good", "Bearer good-token", true},
		{"wrong", "Bearer bad-token", false},
		{"no header", "", false},
		{"basic scheme", "Basic good-token", false},
		{"empty token", "Bearer ", false},
	}
	for _, c := range cases {
		r := httptest.NewRequest("POST", "/x", nil)
		if c.header != "" {
			r.Header.Set("Authorization", c.header)
		}
		who, ok := a.Authenticate(r)
		if ok != c.ok {
			t.Errorf("%s: got %v want %v", c.name, ok, c.ok)
		}
		if ok && (who.ID != "desk:lead-1" || who.Role != "desk-lead") {
			t.Errorf("%s: wrong identity %+v", c.name, who)
		}
	}
}

func TestLoadApproversRejectsBadFiles(t *testing.T) {
	good := sum("t")
	for name, body := range map[string]string{
		"not json":       `nope`,
		"empty list":     `[]`,
		"bad hash":       `[{"id":"desk:a","role":"r","token_sha256":"zz"}]`,
		"duplicate id":   `[{"id":"desk:a","role":"r","token_sha256":"` + good + `"},{"id":"desk:a","role":"r","token_sha256":"` + good + `"}]`,
		"agent identity": `[{"id":"agent","role":"r","token_sha256":"` + good + `"}]`,
		"bad id":         `[{"id":"Desk Lead!","role":"r","token_sha256":"` + good + `"}]`,
		"unknown field":  `[{"id":"desk:a","role":"r","token_sha256":"` + good + `","x":1}]`,
	} {
		if _, err := LoadApprovers(writeApprovers(t, body)); err == nil {
			t.Errorf("%s: want error", name)
		}
	}
	if _, err := LoadApprovers(filepath.Join(t.TempDir(), "missing.json")); err == nil {
		t.Error("a configured but missing file must be an error, not silently disabled")
	}
}

// fakeHooks is a tiny domain: one subject with a text value; the hash covers the value.
type fakeHooks struct {
	executed int
	failExec bool
	rejected int
}

func (f *fakeHooks) Proposed(ctx context.Context, tx *sql.Tx, a Approval) error { return nil }
func (f *fakeHooks) Describe(ctx context.Context, tx *sql.Tx, subject, kind string, amount int64) (string, int64, error) {
	var v string
	if err := tx.QueryRowContext(ctx, `SELECT v FROM things WHERE id=?`, subject).Scan(&v); err != nil {
		return "", 0, &Error{Kind: NotFound, Msg: "subject not found"}
	}
	if kind != "pay" {
		return "", 0, &Error{Kind: Invalid, Msg: "unknown kind"}
	}
	return `{"subject":"` + subject + `","kind":"` + kind + `","v":"` + v + `"}`, 1, nil
}
func (f *fakeHooks) RoleFor(kind string) (string, bool) { return "lead", kind == "pay" }
func (f *fakeHooks) Execute(ctx context.Context, tx *sql.Tx, a Approval) error {
	if f.failExec {
		return errors.New("boom")
	}
	f.executed++
	_, err := tx.ExecContext(ctx, `UPDATE things SET done=1 WHERE id=?`, a.Subject)
	return err
}
func (f *fakeHooks) Reject(ctx context.Context, tx *sql.Tx, a Approval) error {
	f.rejected++
	return nil
}

func approvalsFixture(t *testing.T) (*Approvals, *fakeHooks, *sql.DB) {
	db := testDB(t)
	if _, err := db.Exec(`CREATE TABLE things(id TEXT PRIMARY KEY, v TEXT, done INT DEFAULT 0); INSERT INTO things(id,v) VALUES('T1','a')`); err != nil {
		t.Fatal(err)
	}
	h := &fakeHooks{}
	audit := NewAudit(db, slog.New(slog.DiscardHandler), func() time.Time { return t0 })
	return NewApprovals(db, h, audit, func() time.Time { return t0 }), h, db
}

var lead = Approver{ID: "desk:lead-1", Role: "lead"}

func TestApprovalNothingExecutesBeforeApproval(t *testing.T) {
	q, h, db := approvalsFixture(t)
	a, err := q.Propose(context.Background(), Proposal{Subject: "T1", Kind: "pay", AmountCents: 500, ProposedBy: "agent"})
	if err != nil {
		t.Fatal(err)
	}
	if a.Status != "pending" || a.ID != "APR-0001" || a.PayloadHash == "" {
		t.Fatalf("bad proposal %+v", a)
	}
	var done int
	_ = db.QueryRow(`SELECT done FROM things`).Scan(&done)
	if h.executed != 0 || done != 0 {
		t.Fatal("proposing must not execute anything")
	}
}

func TestApprovalHappyPathRecordsApproverAndVersion(t *testing.T) {
	q, h, db := approvalsFixture(t)
	a, _ := q.Propose(context.Background(), Proposal{Subject: "T1", Kind: "pay", AmountCents: 500, ProposedBy: "agent"})
	got, err := q.Approve(context.Background(), a.ID, lead, a.PayloadHash, "ok")
	if err != nil {
		t.Fatal(err)
	}
	if got.Status != "approved" || got.DecidedBy != "desk:lead-1" || got.DecidedAt == "" || got.PayloadHash != a.PayloadHash {
		t.Fatalf("bad decision %+v", got)
	}
	var done int
	_ = db.QueryRow(`SELECT done FROM things`).Scan(&done)
	if h.executed != 1 || done != 1 {
		t.Fatal("approval must execute exactly once")
	}
	if _, err := q.Approve(context.Background(), a.ID, lead, a.PayloadHash, ""); !IsKind(err, Conflict) {
		t.Fatalf("second approve must conflict, got %v", err)
	}
	if h.executed != 1 {
		t.Fatal("double approve executed twice")
	}
}

func TestApprovalGuards(t *testing.T) {
	ctx := context.Background()
	q, h, _ := approvalsFixture(t)
	a, _ := q.Propose(ctx, Proposal{Subject: "T1", Kind: "pay", AmountCents: 500, ProposedBy: "agent"})
	if _, err := q.Propose(ctx, Proposal{Subject: "T1", Kind: "pay", AmountCents: 500, ProposedBy: "agent"}); !IsKind(err, Conflict) {
		t.Errorf("a second pending approval for one subject must conflict, got %v", err)
	}
	if _, err := q.Approve(ctx, a.ID, Approver{ID: "desk:clerk-1", Role: "clerk"}, a.PayloadHash, ""); !IsKind(err, Forbidden) {
		t.Errorf("wrong role must be forbidden, got %v", err)
	}
	if _, err := q.Approve(ctx, a.ID, lead, "deadbeef", ""); !IsKind(err, Conflict) {
		t.Errorf("a hash the approver did not see must conflict, got %v", err)
	}
	if _, err := q.Approve(ctx, "../etc", lead, a.PayloadHash, ""); !IsKind(err, Invalid) {
		t.Errorf("a malformed id must be invalid, got %v", err)
	}
	if _, err := q.Approve(ctx, "APR-0099", lead, a.PayloadHash, ""); !IsKind(err, NotFound) {
		t.Errorf("unknown id must be not found, got %v", err)
	}
	if h.executed != 0 {
		t.Fatal("a refused approval executed")
	}
}

func TestApprovalStaleWhenSubjectChanged(t *testing.T) {
	ctx := context.Background()
	q, h, db := approvalsFixture(t)
	a, _ := q.Propose(ctx, Proposal{Subject: "T1", Kind: "pay", AmountCents: 500, ProposedBy: "agent"})
	if _, err := db.Exec(`UPDATE things SET v='changed'`); err != nil {
		t.Fatal(err)
	}
	if _, err := q.Approve(ctx, a.ID, lead, a.PayloadHash, ""); !IsKind(err, Conflict) {
		t.Fatalf("approving a changed subject must conflict, got %v", err)
	}
	if h.executed != 0 {
		t.Fatal("stale approval executed")
	}
}

func TestApprovalExecuteFailureRollsBack(t *testing.T) {
	ctx := context.Background()
	q, h, _ := approvalsFixture(t)
	a, _ := q.Propose(ctx, Proposal{Subject: "T1", Kind: "pay", AmountCents: 500, ProposedBy: "agent"})
	h.failExec = true
	if _, err := q.Approve(ctx, a.ID, lead, a.PayloadHash, ""); err == nil {
		t.Fatal("want error")
	}
	got, _ := q.Get(ctx, a.ID)
	if got.Status != "pending" {
		t.Fatalf("a failed execution must leave the approval pending, got %s", got.Status)
	}
}

func TestRejectAllowsNewProposal(t *testing.T) {
	ctx := context.Background()
	q, h, _ := approvalsFixture(t)
	a, _ := q.Propose(ctx, Proposal{Subject: "T1", Kind: "pay", AmountCents: 500, ProposedBy: "agent"})
	if _, err := q.Reject(ctx, a.ID, Approver{ID: "desk:clerk-1", Role: "clerk"}, "no"); !IsKind(err, Forbidden) {
		t.Errorf("wrong role must not reject, got %v", err)
	}
	got, err := q.Reject(ctx, a.ID, lead, "evidence missing")
	if err != nil || got.Status != "rejected" || got.DecisionNote != "evidence missing" || h.rejected != 1 || h.executed != 0 {
		t.Fatalf("bad rejection %+v %v", got, err)
	}
	if _, err := q.Propose(ctx, Proposal{Subject: "T1", Kind: "pay", AmountCents: 500, ProposedBy: "agent"}); err != nil {
		t.Fatalf("a rejected approval frees the subject: %v", err)
	}
}

func TestSupersedeMarksPendingStale(t *testing.T) {
	ctx := context.Background()
	q, _, db := approvalsFixture(t)
	a, _ := q.Propose(ctx, Proposal{Subject: "T1", Kind: "pay", AmountCents: 500, ProposedBy: "agent"})
	tx, _ := db.Begin()
	if err := SupersedePending(ctx, tx, "T1", t0); err != nil {
		t.Fatal(err)
	}
	_ = tx.Commit()
	got, _ := q.Get(ctx, a.ID)
	if got.Status != "superseded" {
		t.Fatalf("got %s", got.Status)
	}
	if _, err := q.Approve(ctx, a.ID, lead, a.PayloadHash, ""); !IsKind(err, Conflict) {
		t.Fatalf("approving a superseded approval must conflict, got %v", err)
	}
}

func TestTimersFireOnce(t *testing.T) {
	ctx := context.Background()
	db := testDB(t)
	tm := NewTimers(db, func() time.Time { return t0 })
	soon, err := tm.Set(ctx, "C1", "scheme_response", t0.Add(24*time.Hour))
	if err != nil || soon.ID != "TMR-0001" || soon.Status != "pending" {
		t.Fatalf("%+v %v", soon, err)
	}
	if _, err := tm.Set(ctx, "C1", "regulatory_final", t0.Add(72*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if fired, _ := tm.FireDue(ctx, t0); len(fired) != 0 {
		t.Fatal("nothing is due yet")
	}
	fired, err := tm.FireDue(ctx, t0.Add(48*time.Hour))
	if err != nil || len(fired) != 1 || fired[0].ID != soon.ID || fired[0].Status != "fired" {
		t.Fatalf("%+v %v", fired, err)
	}
	if again, _ := tm.FireDue(ctx, t0.Add(48*time.Hour)); len(again) != 0 {
		t.Fatal("a timer fires once")
	}
	if _, err := tm.Set(ctx, "C1", "x", t0.Add(-time.Hour)); !IsKind(err, Invalid) {
		t.Fatalf("a timer in the past is invalid, got %v", err)
	}
}

func TestOutboxDraftThenQueue(t *testing.T) {
	ctx := context.Background()
	db := testDB(t)
	ob := NewOutbox(db)
	tx, _ := db.Begin()
	d1, err := ob.Draft(ctx, tx, "C1", "letter", "first", t0)
	if err != nil {
		t.Fatal(err)
	}
	d2, _ := ob.Draft(ctx, tx, "C1", "letter", "second", t0)
	_ = tx.Commit()
	items, _ := ob.List(ctx, "C1")
	status := map[string]string{}
	for _, i := range items {
		status[i.ID] = i.Status
	}
	if status[d1.ID] != "discarded" || status[d2.ID] != "draft" {
		t.Fatalf("a new draft replaces the older one of the same kind: %v", status)
	}
	tx, _ = db.Begin()
	n, err := ob.QueueKinds(ctx, tx, "C1", "APR-0001", []string{"letter"}, t0)
	_ = tx.Commit()
	if err != nil || n != 1 {
		t.Fatalf("queued %d %v", n, err)
	}
	items, _ = ob.List(ctx, "C1")
	for _, i := range items {
		if i.ID == d2.ID && (i.Status != "queued" || i.ApprovalID != "APR-0001") {
			t.Fatalf("%+v", i)
		}
	}
}

func TestAuditHasNoFreeText(t *testing.T) {
	ctx := context.Background()
	db := testDB(t)
	var sb strings.Builder
	a := NewAudit(db, slog.New(slog.NewJSONHandler(&sb, nil)), func() time.Time { return t0 })
	a.Record(ctx, AuditEntry{Actor: "agent", Channel: "mcp", Action: "draft_letter", Subject: "DSP-2026-0001", Outcome: "ok"})
	out := sb.String()
	for _, want := range []string{`"action":"draft_letter"`, `"subject":"DSP-2026-0001"`, `"outcome":"ok"`, `"channel":"mcp"`} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %s in %s", want, out)
		}
	}
	list, err := a.List(ctx, 10)
	if err != nil || len(list) != 1 || list[0].Action != "draft_letter" {
		t.Fatalf("%+v %v", list, err)
	}
}

func TestAuditRejectsHostileFields(t *testing.T) {
	db := testDB(t)
	a := NewAudit(db, slog.New(slog.DiscardHandler), func() time.Time { return t0 })
	a.Record(context.Background(), AuditEntry{Actor: "agent", Channel: "mcp", Action: "x\nINJECT", Subject: strings.Repeat("A", 500), Outcome: "ok"})
	list, _ := a.List(context.Background(), 10)
	if len(list) != 1 || strings.ContainsAny(list[0].Action, "\n") || len(list[0].Subject) > 64 {
		t.Fatalf("fields must be sanitised and bounded: %+v", list)
	}
}

func TestWriteErrorMapsKinds(t *testing.T) {
	for kind, want := range map[ErrKind]int{Invalid: 400, Unauthorized: 401, Forbidden: 403, NotFound: 404, Conflict: 409} {
		w := httptest.NewRecorder()
		WriteError(w, &Error{Kind: kind, Msg: "m"})
		if w.Code != want {
			t.Errorf("%v: %d", kind, w.Code)
		}
	}
	w := httptest.NewRecorder()
	WriteError(w, errors.New("secret internal detail"))
	if w.Code != http.StatusInternalServerError || strings.Contains(w.Body.String(), "secret") {
		t.Errorf("internal errors must not leak: %d %s", w.Code, w.Body.String())
	}
}

func TestIDs(t *testing.T) {
	if FormatID("APR", 7) != "APR-0007" {
		t.Fatal("format")
	}
	if n, ok := ParseID("APR", "APR-0007"); !ok || n != 7 {
		t.Fatal("parse")
	}
	for _, bad := range []string{"", "APR-", "APR-0", "APR-x", "TMR-0001", "APR-0001'; DROP", "APR-99999999999999999999"} {
		if _, ok := ParseID("APR", bad); ok {
			t.Errorf("%q must not parse", bad)
		}
	}
}

func TestApprovalShowsFrozenPayloadAndHashMatches(t *testing.T) {
	ctx := context.Background()
	q, _, db := approvalsFixture(t)
	a, _ := q.Propose(ctx, Proposal{Subject: "T1", Kind: "pay", AmountCents: 500, ProposedBy: "agent"})
	if !strings.Contains(string(a.Payload), `"v":"a"`) || a.PayloadHash != sum(string(a.Payload)) {
		t.Fatalf("the approval must carry the exact payload it hashes: %+v", a)
	}
	_, _ = db.Exec(`UPDATE things SET v='changed'`)
	got, _ := q.Get(ctx, a.ID)
	if !strings.Contains(string(got.Payload), `"v":"a"`) {
		t.Fatal("the payload must stay the frozen proposal, not follow the record")
	}
}

func TestApproverCannotDecideOwnProposal(t *testing.T) {
	ctx := context.Background()
	q, h, _ := approvalsFixture(t)
	a, _ := q.Propose(ctx, Proposal{Subject: "T1", Kind: "pay", AmountCents: 500, ProposedBy: lead.ID})
	if _, err := q.Approve(ctx, a.ID, lead, a.PayloadHash, ""); !IsKind(err, Forbidden) {
		t.Fatalf("own proposal: %v", err)
	}
	if h.executed != 0 {
		t.Fatal("executed")
	}
}

func TestTimersPerSubjectCap(t *testing.T) {
	ctx := context.Background()
	db := testDB(t)
	tm := NewTimers(db, func() time.Time { return t0 })
	for i := 0; i < MaxTimersPerSubject; i++ {
		if _, err := tm.Set(ctx, "C1", "x", t0.Add(time.Hour)); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := tm.Set(ctx, "C1", "x", t0.Add(time.Hour)); !IsKind(err, Conflict) {
		t.Fatalf("over the cap: %v", err)
	}
	if _, err := tm.Set(ctx, "C2", "x", t0.Add(time.Hour)); err != nil {
		t.Fatalf("another subject is unaffected: %v", err)
	}
}

func TestOutboxKeepsFewDiscardedAndQueuesOnlyNamedKinds(t *testing.T) {
	ctx := context.Background()
	db := testDB(t)
	ob := NewOutbox(db)
	tx, _ := db.Begin()
	for i := 0; i < 20; i++ {
		if _, err := ob.Draft(ctx, tx, "C1", "letter", "v"+strings.Repeat("x", i), t0); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := ob.Draft(ctx, tx, "C1", "chargeback_filing", "unapproved filing", t0); err != nil {
		t.Fatal(err)
	}
	_ = tx.Commit()
	items, _ := ob.List(ctx, "C1")
	if len(items) > MaxKeptDiscarded+2 {
		t.Fatalf("discarded drafts must be bounded, have %d rows", len(items))
	}
	tx, _ = db.Begin()
	n, _ := ob.QueueKinds(ctx, tx, "C1", "APR-0001", []string{"letter"}, t0)
	_ = tx.Commit()
	if n != 1 {
		t.Fatalf("queued %d", n)
	}
	items, _ = ob.List(ctx, "C1")
	for _, i := range items {
		if i.Kind == "chargeback_filing" && i.Status != "discarded" {
			t.Fatalf("a draft that was not approved must be discarded, is %s", i.Status)
		}
	}
}

func TestAuditTableIsBounded(t *testing.T) {
	ctx := context.Background()
	db := testDB(t)
	a := NewAudit(db, slog.New(slog.DiscardHandler), func() time.Time { return t0 })
	a.MaxRows = 10
	for i := 0; i < 40; i++ {
		a.Record(ctx, AuditEntry{Actor: "rest", Channel: "rest", Action: "x", Outcome: "ok"})
	}
	list, _ := a.List(ctx, 500)
	if len(list) > 10 {
		t.Fatalf("audit rows %d", len(list))
	}
}

func TestReadJSONRequiresJSONContentType(t *testing.T) {
	for ct, ok := range map[string]bool{"application/json": true, "application/json; charset=utf-8": true, "text/plain": false, "": false, "application/x-www-form-urlencoded": false} {
		r := httptest.NewRequest("POST", "/x", strings.NewReader(`{"a":1}`))
		if ct != "" {
			r.Header.Set("Content-Type", ct)
		}
		var v struct{ A int }
		err := ReadJSON(httptest.NewRecorder(), r, &v)
		if (err == nil) != ok {
			t.Errorf("%q: err=%v", ct, err)
		}
	}
}

func TestRateLimiterBlocksBurstPerHost(t *testing.T) {
	l := NewLimiter(5, time.Minute, func() time.Time { return t0 })
	for i := 0; i < 5; i++ {
		if !l.Allow("1.2.3.4") {
			t.Fatal("under the limit")
		}
	}
	if l.Allow("1.2.3.4") || !l.Allow("5.6.7.8") {
		t.Fatal("limit is per host")
	}
}
