// Package bank is the bank domain of the records service: a small core banking and dispute case system for the
// fictional Fernvale Bank. Every name, id and amount in it is synthetic.
package bank

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"time"

	"github.com/openagentix/openagentix/examples/use-cases/records/internal/core"
)

// Routes a case can take. The first three are acts that need an approval; the last sends the case to a person.
const (
	RouteCreditThenChargeback = "provisional_credit_then_chargeback"
	RouteChargeback           = "chargeback"
	RouteDecline              = "decline"
	RouteInconclusive         = "inconclusive_needs_analyst"
)

// SchemeWindowDays is the fictional card scheme's time limit to dispute a transaction.
const SchemeWindowDays = 120

// ResponseWorkingDays is the fictional response window after a case opens.
const ResponseWorkingDays = 10

var (
	claimTypes   = map[string]bool{"not_recognised": true, "duplicate": true, "goods_not_received": true, "subscription_cancelled": true, "wrong_amount": true, "other": true}
	routes       = map[string]bool{RouteCreditThenChargeback: true, RouteChargeback: true, RouteDecline: true, RouteInconclusive: true}
	evidenceKind = map[string]bool{"transaction": true, "rule": true, "linked_case": true, "gap": true, "other": true}
	caseIDRe     = regexp.MustCompile(`^DSP-[0-9]{4}-[0-9]{4}$`)
	idRe         = regexp.MustCompile(`^[A-Z]{1,3}-[0-9]{3,6}$`)
	refRe        = regexp.MustCompile(`^[A-Za-z0-9_.:/ -]{0,64}$`)
)

// AddWorkingDays adds n Monday-to-Friday days to t. Public holidays are not modelled.
func AddWorkingDays(t time.Time, n int) time.Time {
	for n > 0 {
		t = t.AddDate(0, 0, 1)
		if wd := t.Weekday(); wd != time.Saturday && wd != time.Sunday {
			n--
		}
	}
	return t
}

func validID(field, s string) error {
	if !idRe.MatchString(s) {
		return &core.Error{Kind: core.Invalid, Msg: field + " is not a valid id"}
	}
	return nil
}

func validCaseID(s string) error {
	if !caseIDRe.MatchString(s) {
		return &core.Error{Kind: core.Invalid, Msg: "case id is not valid"}
	}
	return nil
}

type querier interface {
	QueryRowContext(ctx context.Context, q string, args ...any) *sql.Row
}

// Evidence is one item attached to a case.
type Evidence struct {
	Kind      string `json:"kind"`
	Ref       string `json:"ref"`
	Note      string `json:"note"`
	CreatedAt string `json:"created_at"`
}

// CaseView is a case as the REST API serves it.
type CaseView struct {
	ID                 string     `json:"id"`
	CustomerID         string     `json:"customer_id"`
	AccountID          string     `json:"account_id"`
	TransactionID      string     `json:"transaction_id"`
	MerchantID         string     `json:"merchant_id"`
	ClaimType          string     `json:"claim_type"`
	ClaimNote          string     `json:"claim_note"`
	Status             string     `json:"status"`
	Route              string     `json:"route"`
	RouteReason        string     `json:"route_reason"`
	AmountCents        int64      `json:"amount_cents"`
	OpenedAt           string     `json:"opened_at"`
	ResponseDue        string     `json:"response_due"`
	Version            int64      `json:"version"`
	TxnAgeDays         int        `json:"txn_age_days"`
	WithinSchemeWindow bool       `json:"within_scheme_window"`
	HumanDecision      string     `json:"human_decision,omitempty"` // replay ground truth: REST only, never in MCP views
	Evidence           []Evidence `json:"evidence"`
}

const caseCols = `id,customer_id,account_id,transaction_id,merchant_id,claim_type,claim_note,status,route,route_reason,amount_cents,opened_at,response_due,version,human_decision`

func scanCase(r interface{ Scan(...any) error }) (CaseView, error) {
	var c CaseView
	err := r.Scan(&c.ID, &c.CustomerID, &c.AccountID, &c.TransactionID, &c.MerchantID, &c.ClaimType, &c.ClaimNote, &c.Status, &c.Route,
		&c.RouteReason, &c.AmountCents, &c.OpenedAt, &c.ResponseDue, &c.Version, &c.HumanDecision)
	c.Evidence = []Evidence{}
	return c, err
}

// Service holds the bank's operations. REST handlers and MCP tools both call it, so they cannot drift apart.
type Service struct {
	db        *sql.DB
	clock     core.Clock
	approvals *core.Approvals
	timers    *core.Timers
	outbox    *core.Outbox
}

func loadCase(ctx context.Context, q querier, id string) (CaseView, error) {
	c, err := scanCase(q.QueryRowContext(ctx, `SELECT `+caseCols+` FROM cases WHERE id=?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return CaseView{}, &core.Error{Kind: core.NotFound, Msg: "case not found"}
	}
	return c, err
}

// GetCase returns a case with its evidence and the scheme-window facts.
func (s *Service) GetCase(ctx context.Context, id string) (CaseView, error) {
	if err := validCaseID(id); err != nil {
		return CaseView{}, err
	}
	c, err := loadCase(ctx, s.db, id)
	if err != nil {
		return c, err
	}
	rows, err := s.db.QueryContext(ctx, `SELECT kind,ref,note,created_at FROM evidence WHERE case_id=? ORDER BY seq`, id)
	if err != nil {
		return c, err
	}
	defer rows.Close()
	for rows.Next() {
		var e Evidence
		if err := rows.Scan(&e.Kind, &e.Ref, &e.Note, &e.CreatedAt); err != nil {
			return c, err
		}
		c.Evidence = append(c.Evidence, e)
	}
	if err := rows.Err(); err != nil {
		return c, err
	}
	c.TxnAgeDays, c.WithinSchemeWindow = schemeWindow(ctx, s.db, c)
	return c, nil
}

// schemeWindow reads the age of the disputed charge at the day the case was opened, and whether it is inside the scheme limit.
// When the facts cannot be read it says outside: a credit or a chargeback then needs facts that are there.
func schemeWindow(ctx context.Context, q querier, c CaseView) (int, bool) {
	var posted string
	if err := q.QueryRowContext(ctx, `SELECT posted_at FROM transactions WHERE id=?`, c.TransactionID).Scan(&posted); err != nil {
		return 0, false
	}
	p, err := time.Parse(core.TimeFmt, posted)
	if err != nil {
		return 0, false
	}
	opened, err := time.Parse(core.TimeFmt, c.OpenedAt)
	if err != nil {
		return 0, false
	}
	days := int(opened.Sub(p).Hours() / 24)
	return days, days <= SchemeWindowDays
}

// ListCases returns cases, soonest response deadline first. status "" means every case that is not resolved,
// "all" means every case.
func (s *Service) ListCases(ctx context.Context, status string, dueWithinDays, limit int) ([]CaseView, error) {
	switch status {
	case "", "all", "open", "in_review", "needs_analyst", "pending_approval", "resolved":
	default:
		return nil, &core.Error{Kind: core.Invalid, Msg: "status is not valid"}
	}
	if limit < 1 || limit > 200 {
		return nil, &core.Error{Kind: core.Invalid, Msg: "limit must be 1 to 200"}
	}
	if dueWithinDays < 0 || dueWithinDays > 400 {
		return nil, &core.Error{Kind: core.Invalid, Msg: "due_within_days must be 0 to 400"}
	}
	cutoff := "9999-12-31T00:00:00Z"
	if dueWithinDays > 0 {
		cutoff = core.FormatTime(s.clock().AddDate(0, 0, dueWithinDays))
	}
	rows, err := s.db.QueryContext(ctx, `SELECT `+caseCols+` FROM cases
		WHERE (?='all' OR (?='' AND status<>'resolved') OR status=?) AND response_due<=? ORDER BY response_due, id LIMIT ?`,
		status, status, status, cutoff, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []CaseView{}
	for rows.Next() {
		c, err := scanCase(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// NewCase is the intake of a dispute.
type NewCase struct {
	AccountID     string `json:"account_id"`
	TransactionID string `json:"transaction_id"`
	ClaimType     string `json:"claim_type"`
	ClaimNote     string `json:"claim_note"`
	AmountCents   int64  `json:"amount_cents"`
}

// CreateCase opens a case (the case.created event).
func (s *Service) CreateCase(ctx context.Context, in NewCase) (CaseView, error) {
	if err := validID("account_id", in.AccountID); err != nil {
		return CaseView{}, err
	}
	if err := validID("transaction_id", in.TransactionID); err != nil {
		return CaseView{}, err
	}
	if !claimTypes[in.ClaimType] {
		return CaseView{}, &core.Error{Kind: core.Invalid, Msg: "claim_type is not one of the known types"}
	}
	note, err := core.CleanText("claim_note", in.ClaimNote, 500, false)
	if err != nil {
		return CaseView{}, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return CaseView{}, err
	}
	defer func() { _ = tx.Rollback() }()
	var custID, merchID string
	var amount int64
	err = tx.QueryRowContext(ctx, `SELECT a.customer_id, t.merchant_id, t.amount_cents FROM transactions t JOIN accounts a ON a.id=t.account_id
		WHERE t.id=? AND t.account_id=?`, in.TransactionID, in.AccountID).Scan(&custID, &merchID, &amount)
	if errors.Is(err, sql.ErrNoRows) {
		return CaseView{}, &core.Error{Kind: core.NotFound, Msg: "transaction not found on this account"}
	}
	if err != nil {
		return CaseView{}, err
	}
	if amount <= 0 {
		return CaseView{}, &core.Error{Kind: core.Invalid, Msg: "only a debit can be disputed"}
	}
	if in.AmountCents != 0 {
		if in.AmountCents < 0 || in.AmountCents > amount {
			return CaseView{}, &core.Error{Kind: core.Invalid, Msg: "amount_cents must be between 1 and the transaction amount"}
		}
		amount = in.AmountCents
	}
	var open int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM cases WHERE transaction_id=? AND status<>'resolved'`, in.TransactionID).Scan(&open); err != nil {
		return CaseView{}, err
	}
	if open > 0 {
		return CaseView{}, &core.Error{Kind: core.Conflict, Msg: "an open case already exists for this transaction"}
	}
	now := s.clock()
	var n int
	if err := tx.QueryRowContext(ctx, `SELECT COALESCE(MAX(n),0)+1 FROM cases`).Scan(&n); err != nil {
		return CaseView{}, err
	}
	if n > 9999 {
		return CaseView{}, &core.Error{Kind: core.Conflict, Msg: "case numbers are used up"}
	}
	id := fmt.Sprintf("DSP-%04d-%04d", now.Year(), n)
	_, err = tx.ExecContext(ctx, `INSERT INTO cases(id,n,customer_id,account_id,transaction_id,merchant_id,claim_type,claim_note,status,route,route_reason,
		amount_cents,opened_at,response_due,version,pattern,human_decision) VALUES(?,?,?,?,?,?,?,?,'open','','',?,?,?,1,'','')`,
		id, n, custID, in.AccountID, in.TransactionID, merchID, in.ClaimType, note, amount, core.FormatTime(now), core.FormatTime(AddWorkingDays(now, ResponseWorkingDays)))
	if err != nil {
		return CaseView{}, err
	}
	if err := tx.Commit(); err != nil {
		return CaseView{}, err
	}
	return s.GetCase(ctx, id)
}

// mutate changes a case in one transaction. It refuses a resolved case, bumps the version, and if an approval was
// pending it marks that approval superseded (the approver saw something that no longer holds).
func (s *Service) mutate(ctx context.Context, id string, fn func(tx *sql.Tx, c CaseView) (status string, err error)) error {
	if err := validCaseID(id); err != nil {
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	c, err := loadCase(ctx, tx, id)
	if err != nil {
		return err
	}
	if c.Status == "resolved" {
		return &core.Error{Kind: core.Conflict, Msg: "case is resolved"}
	}
	status, err := fn(tx, c)
	if err != nil {
		return err
	}
	if c.Status == "pending_approval" {
		if err := core.SupersedePending(ctx, tx, id, s.clock()); err != nil {
			return err
		}
		if status == "" {
			status = "in_review"
		}
	}
	if status == "" && c.Status == "open" {
		status = "in_review"
	}
	if status == "" {
		status = c.Status
	}
	if _, err := tx.ExecContext(ctx, `UPDATE cases SET status=?, version=version+1 WHERE id=?`, status, id); err != nil {
		return err
	}
	return tx.Commit()
}

// SetRoute records the route and the reason. It never moves money.
func (s *Service) SetRoute(ctx context.Context, id, route, reason string) (CaseView, error) {
	if !routes[route] {
		return CaseView{}, &core.Error{Kind: core.Invalid, Msg: "route is not one of the known routes"}
	}
	reason, err := core.CleanText("reason", reason, 500, true)
	if err != nil {
		return CaseView{}, err
	}
	err = s.mutate(ctx, id, func(tx *sql.Tx, c CaseView) (string, error) {
		_, err := tx.ExecContext(ctx, `UPDATE cases SET route=?, route_reason=? WHERE id=?`, route, reason, id)
		if route == RouteInconclusive {
			return "needs_analyst", err
		}
		return "", err
	})
	if err != nil {
		return CaseView{}, err
	}
	return s.GetCase(ctx, id)
}

// SetStatus moves a case between the states an agent may choose.
func (s *Service) SetStatus(ctx context.Context, id, status string) (CaseView, error) {
	if status != "in_review" && status != "needs_analyst" {
		return CaseView{}, &core.Error{Kind: core.Invalid, Msg: "status must be in_review or needs_analyst"}
	}
	if err := s.mutate(ctx, id, func(*sql.Tx, CaseView) (string, error) { return status, nil }); err != nil {
		return CaseView{}, err
	}
	return s.GetCase(ctx, id)
}

// AttachEvidence adds one evidence item (at most 100 per case).
func (s *Service) AttachEvidence(ctx context.Context, id, kind, ref, note string) (CaseView, error) {
	if !evidenceKind[kind] {
		return CaseView{}, &core.Error{Kind: core.Invalid, Msg: "evidence kind is not known"}
	}
	if !refRe.MatchString(ref) {
		return CaseView{}, &core.Error{Kind: core.Invalid, Msg: "ref must be an id of up to 64 safe characters"}
	}
	note, err := core.CleanText("note", note, 1000, true)
	if err != nil {
		return CaseView{}, err
	}
	err = s.mutate(ctx, id, func(tx *sql.Tx, c CaseView) (string, error) {
		var n int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM evidence WHERE case_id=?`, id).Scan(&n); err != nil {
			return "", err
		}
		if n >= 100 {
			return "", &core.Error{Kind: core.Conflict, Msg: "a case holds at most 100 evidence items"}
		}
		_, err := tx.ExecContext(ctx, `INSERT INTO evidence(case_id,kind,ref,note,created_at) VALUES(?,?,?,?,?)`, id, kind, ref, note, core.FormatTime(s.clock()))
		return "", err
	})
	if err != nil {
		return CaseView{}, err
	}
	return s.GetCase(ctx, id)
}

func (s *Service) draft(ctx context.Context, id, kind, body string) (core.OutboxItem, error) {
	var out core.OutboxItem
	err := s.mutate(ctx, id, func(tx *sql.Tx, c CaseView) (string, error) {
		it, err := s.outbox.Draft(ctx, tx, id, kind, body, s.clock())
		out = it
		return "", err
	})
	return out, err
}

// DraftLetter stores the customer letter as a draft. It is sent only after an approval.
func (s *Service) DraftLetter(ctx context.Context, id, body string) (core.OutboxItem, error) {
	return s.draft(ctx, id, "letter", body)
}

// DraftChargeback stores the scheme filing as a draft. It is filed only after an approval.
func (s *Service) DraftChargeback(ctx context.Context, id, body string) (core.OutboxItem, error) {
	return s.draft(ctx, id, "chargeback_filing", body)
}

// SetTimer adds a deadline timer to a case.
func (s *Service) SetTimer(ctx context.Context, id, name string, due time.Time) (core.Timer, error) {
	if err := validCaseID(id); err != nil {
		return core.Timer{}, err
	}
	if _, err := loadCase(ctx, s.db, id); err != nil {
		return core.Timer{}, err
	}
	return s.timers.Set(ctx, id, name, due)
}

// RequestApproval queues the act for a named approver. It moves no money and sends nothing.
func (s *Service) RequestApproval(ctx context.Context, id, kind string, amountCents int64) (core.Approval, error) {
	return s.RequestApprovalBy(ctx, id, kind, amountCents, "agent")
}

// RequestApprovalBy is RequestApproval with the proposer's name. An approver cannot decide their own proposal.
// The case is marked pending_approval in the same transaction as the proposal.
func (s *Service) RequestApprovalBy(ctx context.Context, id, kind string, amountCents int64, by string) (core.Approval, error) {
	if err := validCaseID(id); err != nil {
		return core.Approval{}, err
	}
	return s.approvals.Propose(ctx, core.Proposal{Subject: id, Kind: kind, AmountCents: amountCents, ProposedBy: by})
}

// proposalPayload is exactly what the approver reads and what the hash covers.
type proposalPayload struct {
	CaseID             string `json:"case_id"`
	AccountID          string `json:"account_id"`
	TransactionID      string `json:"transaction_id"`
	ClaimType          string `json:"claim_type"`   // facts read from the record, not written by the agent
	TxnAgeDays         int    `json:"txn_age_days"` // age of the charge on the day the case opened
	WithinSchemeWindow bool   `json:"within_scheme_window"`
	SchemeWindowDays   int    `json:"scheme_window_days"`
	Kind               string `json:"kind"`
	AmountCents        int64  `json:"amount_cents"`
	DisputedCents      int64  `json:"disputed_cents"`
	PriorCreditCents   int64  `json:"prior_credit_cents"` // credits already posted on this transaction by earlier cases
	RouteReason        string `json:"route_reason"`
	Letter             string `json:"letter"`
	Filing             string `json:"filing,omitempty"` // present only for the chargeback routes
	CaseVersion        int64  `json:"case_version"`
}

// Hooks for the approval queue.

// Describe validates a proposed act and returns the payload the approver is asked to approve.
func (s *Service) Describe(ctx context.Context, tx *sql.Tx, subject, kind string, amount int64) (string, int64, error) {
	c, err := loadCase(ctx, tx, subject)
	if err != nil {
		return "", 0, err
	}
	if c.Status == "resolved" {
		return "", 0, &core.Error{Kind: core.Conflict, Msg: "case is resolved"}
	}
	if c.Route != kind {
		return "", 0, &core.Error{Kind: core.Conflict, Msg: "the approval kind must equal the route set on the case"}
	}
	letter, ok, err := s.outbox.Current(ctx, tx, subject, "letter")
	if err != nil {
		return "", 0, err
	}
	if !ok || letter.Status != "draft" {
		return "", 0, &core.Error{Kind: core.Conflict, Msg: "a letter draft is required"}
	}
	filing := core.OutboxItem{}
	if kind != RouteDecline {
		f, ok, err := s.outbox.Current(ctx, tx, subject, "chargeback_filing")
		if err != nil {
			return "", 0, err
		}
		if !ok || f.Status != "draft" {
			return "", 0, &core.Error{Kind: core.Conflict, Msg: "a chargeback filing draft is required"}
		}
		filing = f
	}
	if kind == RouteDecline {
		if amount != 0 {
			return "", 0, &core.Error{Kind: core.Invalid, Msg: "a decline moves no money: amount_cents must be 0"}
		}
	} else if amount <= 0 || amount > c.AmountCents {
		return "", 0, &core.Error{Kind: core.Invalid, Msg: "amount_cents must be above 0 and at most the disputed amount"}
	}
	var prior int64
	if err := tx.QueryRowContext(ctx, `SELECT COALESCE(SUM(amount_cents),0) FROM ledger WHERE transaction_id=?`, c.TransactionID).Scan(&prior); err != nil {
		return "", 0, err
	}
	if kind == RouteCreditThenChargeback {
		if c.ClaimType == "goods_not_received" {
			return "", 0, &core.Error{Kind: core.Conflict, Msg: "no provisional credit for goods not received: the route is a chargeback with no credit"}
		}
		if prior > 0 {
			return "", 0, &core.Error{Kind: core.Conflict, Msg: "this transaction was already credited by an earlier case"}
		}
		var status string
		if err := tx.QueryRowContext(ctx, `SELECT status FROM accounts WHERE id=?`, c.AccountID).Scan(&status); err != nil {
			return "", 0, err
		}
		if status != "active" {
			return "", 0, &core.Error{Kind: core.Conflict, Msg: "the account is not active, so it cannot be credited"}
		}
	}
	age, within := schemeWindow(ctx, tx, c)
	if kind != RouteDecline && !within {
		return "", 0, &core.Error{Kind: core.Conflict, Msg: "the charge is outside the scheme window: only a decline can be proposed"}
	}
	p := proposalPayload{CaseID: c.ID, AccountID: c.AccountID, TransactionID: c.TransactionID, ClaimType: c.ClaimType, TxnAgeDays: age,
		WithinSchemeWindow: within, SchemeWindowDays: SchemeWindowDays, Kind: kind, AmountCents: amount,
		DisputedCents: c.AmountCents, PriorCreditCents: prior, RouteReason: c.RouteReason, Letter: letter.Body, Filing: filing.Body, CaseVersion: c.Version}
	b, err := json.Marshal(p)
	if err != nil {
		return "", 0, err
	}
	return string(b), c.Version, nil
}

// Proposed marks the case as waiting for approval. It does not change the version.
func (s *Service) Proposed(ctx context.Context, tx *sql.Tx, a core.Approval) error {
	_, err := tx.ExecContext(ctx, `UPDATE cases SET status='pending_approval' WHERE id=? AND status<>'resolved'`, a.Subject)
	return err
}

// RoleFor says which role decides each approvable kind.
func (s *Service) RoleFor(kind string) (string, bool) {
	switch kind {
	case RouteCreditThenChargeback, RouteChargeback, RouteDecline:
		return "desk-lead", true
	}
	return "", false
}

// Execute runs inside the approval's transaction. It is the only code that posts a credit or queues a letter.
// It releases only the drafts the approver was shown for this route.
func (s *Service) Execute(ctx context.Context, tx *sql.Tx, a core.Approval) error {
	c, err := loadCase(ctx, tx, a.Subject)
	if err != nil {
		return err
	}
	now := s.clock()
	if a.Kind == RouteCreditThenChargeback {
		var status string
		if err := tx.QueryRowContext(ctx, `SELECT status FROM accounts WHERE id=?`, c.AccountID).Scan(&status); err != nil {
			return err
		}
		if status != "active" {
			return &core.Error{Kind: core.Conflict, Msg: "the account is not active, so it cannot be credited"}
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO ledger(case_id,transaction_id,account_id,kind,amount_cents,approval_id,posted_at) VALUES(?,?,?,?,?,?,?)`,
			c.ID, c.TransactionID, c.AccountID, "provisional_credit", a.AmountCents, a.ID, core.FormatTime(now)); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `UPDATE accounts SET balance_cents=balance_cents+? WHERE id=?`, a.AmountCents, c.AccountID); err != nil {
			return err
		}
	}
	kinds := []string{"letter"}
	if a.Kind != RouteDecline {
		kinds = append(kinds, "chargeback_filing")
	}
	if _, err := s.outbox.QueueKinds(ctx, tx, c.ID, a.ID, kinds, now); err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `UPDATE cases SET status='resolved', version=version+1 WHERE id=?`, c.ID)
	return err
}

// Reject sends the case back to an analyst and drops the drafts.
func (s *Service) Reject(ctx context.Context, tx *sql.Tx, a core.Approval) error {
	if err := s.outbox.DiscardDrafts(ctx, tx, a.Subject); err != nil {
		return err
	}
	_, err := tx.ExecContext(ctx, `UPDATE cases SET status='needs_analyst', route=?, route_reason='rejected by an approver, see the approval', version=version+1 WHERE id=?`,
		RouteInconclusive, a.Subject)
	return err
}

// Reads over the core banking tables.

// Transaction is one posted transaction.
type Transaction struct {
	ID          string `json:"id"`
	AccountID   string `json:"account_id"`
	CardID      string `json:"card_id"`
	MerchantID  string `json:"merchant_id"`
	PostedAt    string `json:"posted_at"`
	AmountCents int64  `json:"amount_cents"`
	Channel     string `json:"channel"`
	DeviceHash  string `json:"device_hash,omitempty"`
}

func parseDay(field, s string, endOfDay bool) (string, error) {
	if s == "" {
		return "", nil
	}
	t, err := time.Parse("2006-01-02", s)
	if err != nil {
		return "", &core.Error{Kind: core.Invalid, Msg: field + " must be a date like 2026-11-27"}
	}
	if endOfDay {
		t = t.Add(24*time.Hour - time.Second)
	}
	return core.FormatTime(t), nil
}

// ListTransactions returns an account's transactions, newest first. from and to are dates (inclusive).
func (s *Service) ListTransactions(ctx context.Context, account, from, to string, limit int) ([]Transaction, error) {
	if err := validID("account_id", account); err != nil {
		return nil, err
	}
	if limit < 1 || limit > 200 {
		return nil, &core.Error{Kind: core.Invalid, Msg: "limit must be 1 to 200"}
	}
	f, err := parseDay("from", from, false)
	if err != nil {
		return nil, err
	}
	t, err := parseDay("to", to, true)
	if err != nil {
		return nil, err
	}
	if t == "" {
		t = "9999-12-31T00:00:00Z"
	}
	rows, err := s.db.QueryContext(ctx, `SELECT id,account_id,card_id,merchant_id,posted_at,amount_cents,channel,device_hash FROM transactions
		WHERE account_id=? AND posted_at>=? AND posted_at<=? ORDER BY posted_at DESC, id DESC LIMIT ?`, account, f, t, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Transaction{}
	for rows.Next() {
		var x Transaction
		if err := rows.Scan(&x.ID, &x.AccountID, &x.CardID, &x.MerchantID, &x.PostedAt, &x.AmountCents, &x.Channel, &x.DeviceHash); err != nil {
			return nil, err
		}
		out = append(out, x)
	}
	return out, rows.Err()
}

// Card is a card's status. Only the last four digits exist.
type Card struct {
	ID        string `json:"id"`
	AccountID string `json:"account_id"`
	Last4     string `json:"last4"`
	Status    string `json:"status"`
	Network   string `json:"network"`
}

// GetCard returns a card.
func (s *Service) GetCard(ctx context.Context, id string) (Card, error) {
	if err := validID("card_id", id); err != nil {
		return Card{}, err
	}
	var c Card
	err := s.db.QueryRowContext(ctx, `SELECT id,account_id,last4,status,network FROM cards WHERE id=?`, id).Scan(&c.ID, &c.AccountID, &c.Last4, &c.Status, &c.Network)
	if errors.Is(err, sql.ErrNoRows) {
		return c, &core.Error{Kind: core.NotFound, Msg: "card not found"}
	}
	return c, err
}

// Merchant is a merchant record.
type Merchant struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	MCC     string `json:"mcc"`
	Country string `json:"country"`
}

// GetMerchant returns a merchant.
func (s *Service) GetMerchant(ctx context.Context, id string) (Merchant, error) {
	if err := validID("merchant_id", id); err != nil {
		return Merchant{}, err
	}
	var m Merchant
	err := s.db.QueryRowContext(ctx, `SELECT id,name,mcc,country FROM merchants WHERE id=?`, id).Scan(&m.ID, &m.Name, &m.MCC, &m.Country)
	if errors.Is(err, sql.ErrNoRows) {
		return m, &core.Error{Kind: core.NotFound, Msg: "merchant not found"}
	}
	return m, err
}

// MerchantHistory counts a merchant's transactions, refunds and disputes.
type MerchantHistory struct {
	MerchantID         string `json:"merchant_id"`
	TransactionCount   int    `json:"transaction_count"`
	RefundCount        int    `json:"refund_count"`
	DisputeCount       int    `json:"dispute_count"`
	OpenDisputeCount   int    `json:"open_dispute_count"`
	ChargebackRatioBps int    `json:"chargeback_ratio_bps"`
}

// GetMerchantHistory returns the counts. The ratio is disputes per 10,000 transactions.
func (s *Service) GetMerchantHistory(ctx context.Context, id string) (MerchantHistory, error) {
	if _, err := s.GetMerchant(ctx, id); err != nil {
		return MerchantHistory{}, err
	}
	h := MerchantHistory{MerchantID: id}
	err := s.db.QueryRowContext(ctx, `SELECT
		(SELECT COUNT(*) FROM transactions WHERE merchant_id=?),
		(SELECT COUNT(*) FROM transactions WHERE merchant_id=? AND amount_cents<0),
		(SELECT COUNT(*) FROM cases WHERE merchant_id=?),
		(SELECT COUNT(*) FROM cases WHERE merchant_id=? AND status<>'resolved')`, id, id, id, id).
		Scan(&h.TransactionCount, &h.RefundCount, &h.DisputeCount, &h.OpenDisputeCount)
	if err != nil {
		return h, err
	}
	if h.TransactionCount > 0 {
		h.ChargebackRatioBps = h.DisputeCount * 10000 / h.TransactionCount
	}
	return h, nil
}

// CaseRef is a short reference to a related case.
type CaseRef struct {
	ID          string `json:"id"`
	Status      string `json:"status"`
	ClaimType   string `json:"claim_type"`
	AmountCents int64  `json:"amount_cents"`
	OpenedAt    string `json:"opened_at"`
}

// Linked holds the cases related to one case.
type Linked struct {
	CaseID       string    `json:"case_id"`
	SameMerchant []CaseRef `json:"same_merchant"`
	SameDevice   []CaseRef `json:"same_device"`
}

func (s *Service) refs(ctx context.Context, q string, args ...any) ([]CaseRef, error) {
	rows, err := s.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []CaseRef{}
	for rows.Next() {
		var r CaseRef
		if err := rows.Scan(&r.ID, &r.Status, &r.ClaimType, &r.AmountCents, &r.OpenedAt); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// LinkedCases finds other cases on the same merchant, and other cases whose transaction came from the same device.
func (s *Service) LinkedCases(ctx context.Context, id string) (Linked, error) {
	c, err := s.GetCase(ctx, id)
	if err != nil {
		return Linked{}, err
	}
	l := Linked{CaseID: id}
	if l.SameMerchant, err = s.refs(ctx, `SELECT id,status,claim_type,amount_cents,opened_at FROM cases WHERE merchant_id=? AND id<>? ORDER BY opened_at DESC, id LIMIT 50`, c.MerchantID, id); err != nil {
		return l, err
	}
	l.SameDevice, err = s.refs(ctx, `SELECT c.id,c.status,c.claim_type,c.amount_cents,c.opened_at FROM cases c JOIN transactions t ON t.id=c.transaction_id
		WHERE t.device_hash<>'' AND t.device_hash=(SELECT device_hash FROM transactions WHERE id=?) AND c.id<>? ORDER BY c.opened_at DESC, c.id LIMIT 50`, c.TransactionID, id)
	return l, err
}

// Customer is a customer record. Names are synthetic.
type Customer struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// GetCustomer returns a customer.
func (s *Service) GetCustomer(ctx context.Context, id string) (Customer, error) {
	if err := validID("customer_id", id); err != nil {
		return Customer{}, err
	}
	var c Customer
	err := s.db.QueryRowContext(ctx, `SELECT id,name FROM customers WHERE id=?`, id).Scan(&c.ID, &c.Name)
	if errors.Is(err, sql.ErrNoRows) {
		return c, &core.Error{Kind: core.NotFound, Msg: "customer not found"}
	}
	return c, err
}

// Account is an account with its balance.
type Account struct {
	ID           string `json:"id"`
	CustomerID   string `json:"customer_id"`
	Status       string `json:"status"`
	Currency     string `json:"currency"`
	BalanceCents int64  `json:"balance_cents"`
}

// GetAccount returns an account.
func (s *Service) GetAccount(ctx context.Context, id string) (Account, error) {
	if err := validID("account_id", id); err != nil {
		return Account{}, err
	}
	var a Account
	err := s.db.QueryRowContext(ctx, `SELECT id,customer_id,status,currency,balance_cents FROM accounts WHERE id=?`, id).Scan(&a.ID, &a.CustomerID, &a.Status, &a.Currency, &a.BalanceCents)
	if errors.Is(err, sql.ErrNoRows) {
		return a, &core.Error{Kind: core.NotFound, Msg: "account not found"}
	}
	return a, err
}

// LedgerEntry is a posted provisional credit.
type LedgerEntry struct {
	CaseID      string `json:"case_id"`
	AccountID   string `json:"account_id"`
	Kind        string `json:"kind"`
	AmountCents int64  `json:"amount_cents"`
	ApprovalID  string `json:"approval_id"`
	PostedAt    string `json:"posted_at"`
}

// Ledger lists the entries posted by approvals.
func (s *Service) Ledger(ctx context.Context) ([]LedgerEntry, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT case_id,account_id,kind,amount_cents,approval_id,posted_at FROM ledger ORDER BY seq DESC LIMIT 200`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []LedgerEntry{}
	for rows.Next() {
		var e LedgerEntry
		if err := rows.Scan(&e.CaseID, &e.AccountID, &e.Kind, &e.AmountCents, &e.ApprovalID, &e.PostedAt); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}
