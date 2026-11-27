package core

import (
	"context"
	"database/sql"
	"errors"
	"regexp"
	"time"
)

// Timer is a deadline on a record. When it is due it is marked fired; a sweep (a scheduled agent run) picks up
// the fired timers. Nothing else happens automatically.
type Timer struct {
	ID        string `json:"id"`
	Subject   string `json:"subject"`
	Name      string `json:"name"`
	DueAt     string `json:"due_at"`
	Status    string `json:"status"`
	CreatedAt string `json:"created_at"`
	FiredAt   string `json:"fired_at,omitempty"`
}

// Timers stores timers.
type Timers struct {
	db    *sql.DB
	clock Clock
}

// NewTimers returns the timer store.
func NewTimers(db *sql.DB, clock Clock) *Timers { return &Timers{db: db, clock: clock} }

var timerName = regexp.MustCompile(`^[a-z][a-z_]{0,39}$`)

const timerCols = `seq,subject,name,due_at,status,created_at,fired_at`

func scanTimer(r rowScanner) (Timer, error) {
	var t Timer
	var seq int64
	err := r.Scan(&seq, &t.Subject, &t.Name, &t.DueAt, &t.Status, &t.CreatedAt, &t.FiredAt)
	t.ID = FormatID("TMR", seq)
	return t, err
}

// Set adds a timer. The due time must be in the future and within 400 days.
func (t *Timers) Set(ctx context.Context, subject, name string, due time.Time) (Timer, error) {
	now := t.clock()
	if !timerName.MatchString(name) {
		return Timer{}, &Error{Kind: Invalid, Msg: "timer name must be lowercase letters and underscores"}
	}
	if !due.After(now) || due.After(now.Add(400*24*time.Hour)) {
		return Timer{}, &Error{Kind: Invalid, Msg: "due time must be in the future and within 400 days"}
	}
	res, err := t.db.ExecContext(ctx, `INSERT INTO timers(subject,name,due_at,status,created_at) VALUES(?,?,?,'pending',?)`,
		subject, name, FormatTime(due), FormatTime(now))
	if err != nil {
		return Timer{}, err
	}
	seq, _ := res.LastInsertId()
	return scanTimer(t.db.QueryRowContext(ctx, `SELECT `+timerCols+` FROM timers WHERE seq=?`, seq))
}

// FireDue marks every pending timer due at or before now as fired and returns them.
func (t *Timers) FireDue(ctx context.Context, now time.Time) ([]Timer, error) {
	tx, err := t.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()
	rows, err := tx.QueryContext(ctx, `SELECT `+timerCols+` FROM timers WHERE status='pending' AND due_at<=? ORDER BY due_at, seq`, FormatTime(now))
	if err != nil {
		return nil, err
	}
	var fired []Timer
	for rows.Next() {
		tm, err := scanTimer(rows)
		if err != nil {
			_ = rows.Close()
			return nil, err
		}
		fired = append(fired, tm)
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	for i := range fired {
		n, _ := ParseID("TMR", fired[i].ID)
		if _, err := tx.ExecContext(ctx, `UPDATE timers SET status='fired', fired_at=? WHERE seq=?`, FormatTime(now), n); err != nil {
			return nil, err
		}
		fired[i].Status, fired[i].FiredAt = "fired", FormatTime(now)
	}
	return fired, tx.Commit()
}

// List returns timers, soonest first. status and subject are optional filters.
func (t *Timers) List(ctx context.Context, status, subject string) ([]Timer, error) {
	switch status {
	case "", "pending", "fired":
	default:
		return nil, &Error{Kind: Invalid, Msg: "status is not valid"}
	}
	rows, err := t.db.QueryContext(ctx, `SELECT `+timerCols+` FROM timers WHERE (?='' OR status=?) AND (?='' OR subject=?)
		ORDER BY due_at, seq LIMIT 200`, status, status, subject, subject)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Timer{}
	for rows.Next() {
		tm, err := scanTimer(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, tm)
	}
	return out, rows.Err()
}

// OutboxItem is a letter, filing or notice. Nothing leaves the cluster: "queued" means an approver released it
// and a real system would now send it.
type OutboxItem struct {
	ID         string `json:"id"`
	Subject    string `json:"subject"`
	Kind       string `json:"kind"`
	Body       string `json:"body"`
	Status     string `json:"status"` // draft, queued, discarded
	ApprovalID string `json:"approval_id,omitempty"`
	CreatedAt  string `json:"created_at"`
	QueuedAt   string `json:"queued_at,omitempty"`
}

// Outbox stores drafts and queued items.
type Outbox struct{ db *sql.DB }

// NewOutbox returns the outbox store.
func NewOutbox(db *sql.DB) *Outbox { return &Outbox{db: db} }

const outboxCols = `seq,subject,kind,body,status,approval_id,created_at,queued_at`

func scanOutbox(r rowScanner) (OutboxItem, error) {
	var o OutboxItem
	var seq int64
	err := r.Scan(&seq, &o.Subject, &o.Kind, &o.Body, &o.Status, &o.ApprovalID, &o.CreatedAt, &o.QueuedAt)
	o.ID = FormatID("OUT", seq)
	return o, err
}

// Draft stores a draft and discards the older draft of the same kind for the subject. It runs in the caller's
// transaction.
func (o *Outbox) Draft(ctx context.Context, tx *sql.Tx, subject, kind, body string, now time.Time) (OutboxItem, error) {
	if !timerName.MatchString(kind) {
		return OutboxItem{}, &Error{Kind: Invalid, Msg: "outbox kind must be lowercase letters and underscores"}
	}
	body, err := CleanText("body", body, 4000, true)
	if err != nil {
		return OutboxItem{}, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE outbox SET status='discarded' WHERE subject=? AND kind=? AND status='draft'`, subject, kind); err != nil {
		return OutboxItem{}, err
	}
	res, err := tx.ExecContext(ctx, `INSERT INTO outbox(subject,kind,body,status,created_at) VALUES(?,?,?,'draft',?)`, subject, kind, body, FormatTime(now))
	if err != nil {
		return OutboxItem{}, err
	}
	seq, _ := res.LastInsertId()
	return scanOutbox(tx.QueryRowContext(ctx, `SELECT `+outboxCols+` FROM outbox WHERE seq=?`, seq))
}

// QueueDrafts releases every draft of the subject. Only an approval's Execute hook calls it.
func (o *Outbox) QueueDrafts(ctx context.Context, tx *sql.Tx, subject, approvalID string, now time.Time) (int, error) {
	res, err := tx.ExecContext(ctx, `UPDATE outbox SET status='queued', approval_id=?, queued_at=? WHERE subject=? AND status='draft'`,
		approvalID, FormatTime(now), subject)
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	return int(n), nil
}

// DiscardDrafts drops every draft of the subject (after a rejection).
func (o *Outbox) DiscardDrafts(ctx context.Context, tx *sql.Tx, subject string) error {
	_, err := tx.ExecContext(ctx, `UPDATE outbox SET status='discarded' WHERE subject=? AND status='draft'`, subject)
	return err
}

// Get returns the current (draft or queued) item of a kind for a subject, if any, using the caller's transaction.
func (o *Outbox) Current(ctx context.Context, tx *sql.Tx, subject, kind string) (OutboxItem, bool, error) {
	it, err := scanOutbox(tx.QueryRowContext(ctx, `SELECT `+outboxCols+` FROM outbox WHERE subject=? AND kind=? AND status IN ('draft','queued') ORDER BY seq DESC LIMIT 1`, subject, kind))
	if errors.Is(err, sql.ErrNoRows) {
		return OutboxItem{}, false, nil
	}
	return it, err == nil, err
}

// List returns the items of a subject (or all when subject is empty), newest first.
func (o *Outbox) List(ctx context.Context, subject string) ([]OutboxItem, error) {
	rows, err := o.db.QueryContext(ctx, `SELECT `+outboxCols+` FROM outbox WHERE (?='' OR subject=?) ORDER BY seq DESC LIMIT 200`, subject, subject)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []OutboxItem{}
	for rows.Next() {
		it, err := scanOutbox(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, it)
	}
	return out, rows.Err()
}
