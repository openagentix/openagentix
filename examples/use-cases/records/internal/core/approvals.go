package core

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// Hooks is what a domain provides to the approval queue.
type Hooks interface {
	// Describe validates the proposed act against the subject's current state and returns a hash of everything the
	// approver is being asked to approve (route, amount, drafts) and the subject's version. It is called when the
	// act is proposed and again when it is decided: a changed hash means the approver would approve something
	// they have not seen.
	Describe(ctx context.Context, tx *sql.Tx, subject, kind string, amountCents int64) (hash string, version int64, err error)
	// RoleFor returns the role an approver needs for this kind of act.
	RoleFor(kind string) (role string, ok bool)
	// Execute performs the act. It runs in the same transaction as the approval, so it all happens or none of it.
	Execute(ctx context.Context, tx *sql.Tx, a Approval) error
	// Reject undoes the proposal's effect on the subject (for example sends a case back to an analyst).
	Reject(ctx context.Context, tx *sql.Tx, a Approval) error
}

// Proposal asks for an act. It changes nothing but the queue.
type Proposal struct {
	Subject     string
	Kind        string
	AmountCents int64
	ProposedBy  string
}

// Approval is one queue entry.
type Approval struct {
	ID             string `json:"id"`
	Subject        string `json:"subject"`
	Kind           string `json:"kind"`
	AmountCents    int64  `json:"amount_cents"`
	PayloadHash    string `json:"payload_hash"`
	SubjectVersion int64  `json:"subject_version"`
	Status         string `json:"status"`
	ProposedBy     string `json:"proposed_by"`
	ProposedAt     string `json:"proposed_at"`
	DecidedBy      string `json:"decided_by,omitempty"`
	DecidedAt      string `json:"decided_at,omitempty"`
	DecisionNote   string `json:"decision_note,omitempty"`
}

// Approvals is the queue.
type Approvals struct {
	db    *sql.DB
	hooks Hooks
	audit *Audit
	clock Clock
}

// NewApprovals returns the queue for one domain.
func NewApprovals(db *sql.DB, hooks Hooks, audit *Audit, clock Clock) *Approvals {
	return &Approvals{db: db, hooks: hooks, audit: audit, clock: clock}
}

const approvalCols = `seq,subject,kind,amount_cents,payload_hash,subject_version,status,proposed_by,proposed_at,decided_by,decided_at,decision_note`

type rowScanner interface{ Scan(...any) error }

func scanApproval(r rowScanner) (Approval, error) {
	var a Approval
	var seq int64
	err := r.Scan(&seq, &a.Subject, &a.Kind, &a.AmountCents, &a.PayloadHash, &a.SubjectVersion, &a.Status, &a.ProposedBy, &a.ProposedAt, &a.DecidedBy, &a.DecidedAt, &a.DecisionNote)
	a.ID = FormatID("APR", seq)
	return a, err
}

func (q *Approvals) inTx(ctx context.Context, fn func(tx *sql.Tx) error) error {
	tx, err := q.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	if err := fn(tx); err != nil {
		_ = tx.Rollback()
		return err
	}
	return tx.Commit()
}

// Propose queues an act for approval. Nothing is executed.
func (q *Approvals) Propose(ctx context.Context, p Proposal) (Approval, error) {
	var out Approval
	err := q.inTx(ctx, func(tx *sql.Tx) error {
		if _, ok := q.hooks.RoleFor(p.Kind); !ok {
			return &Error{Kind: Invalid, Msg: "unknown approval kind"}
		}
		var n int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM approvals WHERE subject=? AND status='pending'`, p.Subject).Scan(&n); err != nil {
			return err
		}
		if n > 0 {
			return &Error{Kind: Conflict, Msg: "an approval is already pending for this record"}
		}
		hash, version, err := q.hooks.Describe(ctx, tx, p.Subject, p.Kind, p.AmountCents)
		if err != nil {
			return err
		}
		res, err := tx.ExecContext(ctx, `INSERT INTO approvals(subject,kind,amount_cents,payload_hash,subject_version,status,proposed_by,proposed_at)
			VALUES(?,?,?,?,?,'pending',?,?)`, p.Subject, p.Kind, p.AmountCents, hash, version, p.ProposedBy, FormatTime(q.clock()))
		if err != nil {
			return err
		}
		seq, _ := res.LastInsertId()
		out, err = scanApproval(tx.QueryRowContext(ctx, `SELECT `+approvalCols+` FROM approvals WHERE seq=?`, seq))
		return err
	})
	return out, err
}

// Get returns one approval.
func (q *Approvals) Get(ctx context.Context, id string) (Approval, error) {
	n, ok := ParseID("APR", id)
	if !ok {
		return Approval{}, &Error{Kind: Invalid, Msg: "approval id is not valid"}
	}
	a, err := scanApproval(q.db.QueryRowContext(ctx, `SELECT `+approvalCols+` FROM approvals WHERE seq=?`, n))
	if errors.Is(err, sql.ErrNoRows) {
		return Approval{}, &Error{Kind: NotFound, Msg: "approval not found"}
	}
	return a, err
}

// List returns approvals, newest first. status "" means all; otherwise it must be a known status.
func (q *Approvals) List(ctx context.Context, status, subject string) ([]Approval, error) {
	switch status {
	case "", "pending", "approved", "rejected", "superseded":
	default:
		return nil, &Error{Kind: Invalid, Msg: "status is not valid"}
	}
	rows, err := q.db.QueryContext(ctx, `SELECT `+approvalCols+` FROM approvals
		WHERE (?='' OR status=?) AND (?='' OR subject=?) ORDER BY seq DESC LIMIT 200`, status, status, subject, subject)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Approval{}
	for rows.Next() {
		a, err := scanApproval(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// Approve decides an approval in favour and executes the act. payloadHash is the hash the approver saw; it must
// still match what the record says now. The decision and the act are one transaction.
func (q *Approvals) Approve(ctx context.Context, id string, who Approver, payloadHash, note string) (Approval, error) {
	return q.decide(ctx, id, who, payloadHash, note, true)
}

// Reject decides an approval against. The domain's Reject hook runs in the same transaction.
func (q *Approvals) Reject(ctx context.Context, id string, who Approver, note string) (Approval, error) {
	return q.decide(ctx, id, who, "", note, false)
}

func (q *Approvals) decide(ctx context.Context, id string, who Approver, payloadHash, note string, approve bool) (Approval, error) {
	action := "approve"
	if !approve {
		action = "reject"
	}
	n, ok := ParseID("APR", id)
	if !ok {
		return Approval{}, &Error{Kind: Invalid, Msg: "approval id is not valid"}
	}
	note, err := CleanText("note", note, 500, false)
	if err != nil {
		return Approval{}, err
	}
	var out Approval
	err = q.inTx(ctx, func(tx *sql.Tx) error {
		a, err := scanApproval(tx.QueryRowContext(ctx, `SELECT `+approvalCols+` FROM approvals WHERE seq=?`, n))
		if errors.Is(err, sql.ErrNoRows) {
			return &Error{Kind: NotFound, Msg: "approval not found"}
		}
		if err != nil {
			return err
		}
		if a.Status != "pending" {
			return &Error{Kind: Conflict, Msg: "approval is not pending (it is " + a.Status + ")"}
		}
		if role, _ := q.hooks.RoleFor(a.Kind); role == "" || role != who.Role {
			return &Error{Kind: Forbidden, Msg: "your role may not decide this kind of approval"}
		}
		now := FormatTime(q.clock())
		status := "rejected"
		if approve {
			status = "approved"
			hash, _, err := q.hooks.Describe(ctx, tx, a.Subject, a.Kind, a.AmountCents)
			if err != nil {
				return err
			}
			if hash != a.PayloadHash {
				return &Error{Kind: Conflict, Msg: "the record changed after this was proposed; ask for a new proposal"}
			}
			if payloadHash != a.PayloadHash {
				return &Error{Kind: Conflict, Msg: "payload_hash does not match what was proposed; read the approval again"}
			}
		}
		res, err := tx.ExecContext(ctx, `UPDATE approvals SET status=?, decided_by=?, decided_at=?, decision_note=? WHERE seq=? AND status='pending'`,
			status, who.ID, now, note, n)
		if err != nil {
			return err
		}
		if c, _ := res.RowsAffected(); c != 1 {
			return &Error{Kind: Conflict, Msg: "approval is not pending"}
		}
		a.Status, a.DecidedBy, a.DecidedAt, a.DecisionNote = status, who.ID, now, note
		if approve {
			err = q.hooks.Execute(ctx, tx, a)
		} else {
			err = q.hooks.Reject(ctx, tx, a)
		}
		if err != nil {
			return err
		}
		out = a
		return nil
	})
	outcome := "ok"
	switch {
	case IsKind(err, Forbidden):
		outcome = "denied"
	case IsKind(err, Conflict):
		outcome = "conflict"
	case IsKind(err, NotFound):
		outcome = "not_found"
	case IsKind(err, Invalid):
		outcome = "invalid"
	case err != nil:
		outcome = "error"
	}
	q.audit.Record(ctx, AuditEntry{Actor: who.ID, Channel: "rest", Action: action, Subject: id, Outcome: outcome})
	return out, err
}

// SupersedePending marks the pending approval of a subject stale. A domain calls it, in its own transaction,
// whenever it changes something the approver was shown (a new draft, a new route).
func SupersedePending(ctx context.Context, tx *sql.Tx, subject string, now time.Time) error {
	_, err := tx.ExecContext(ctx, `UPDATE approvals SET status='superseded', decided_at=?, decision_note='changed after it was proposed'
		WHERE subject=? AND status='pending'`, FormatTime(now), subject)
	return err
}
