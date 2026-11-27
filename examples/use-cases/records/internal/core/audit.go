package core

import (
	"context"
	"database/sql"
	"log/slog"
	"strings"
)

// AuditEntry is one line of the audit log. There is deliberately no field for message text, arguments or personal
// data: only who, through which door, which action, on which record, and the outcome.
type AuditEntry struct {
	At      string `json:"at"`
	Actor   string `json:"actor"`   // "agent", "rest", or an approver id
	Channel string `json:"channel"` // "mcp" or "rest"
	Action  string `json:"action"`  // tool name or route name
	Subject string `json:"subject"` // record id, or empty
	Outcome string `json:"outcome"` // ok, invalid, not_found, conflict, denied, error
}

// Audit writes entries to the log (stdout, as JSON) and to the audit table.
type Audit struct {
	db    *sql.DB
	log   *slog.Logger
	clock Clock
	// MaxRows bounds the audit table: older rows are deleted (the stdout log keeps every line).
	MaxRows int64
}

// DefaultAuditRows is the default bound of the audit table.
const DefaultAuditRows = 50000

// NewAudit returns an Audit.
func NewAudit(db *sql.DB, log *slog.Logger, clock Clock) *Audit {
	return &Audit{db: db, log: log, clock: clock, MaxRows: DefaultAuditRows}
}

// auditClean keeps a field to a safe alphabet and 64 characters, so a hostile value cannot forge a log line.
func auditClean(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '_', r == '-', r == '.', r == ':', r == '/':
			b.WriteRune(r)
		default:
			b.WriteByte('_')
		}
		if b.Len() >= 64 {
			break
		}
	}
	return b.String()
}

// Record stores one entry. It never fails the caller: a failed write is logged.
func (a *Audit) Record(ctx context.Context, e AuditEntry) {
	e.At = FormatTime(a.clock())
	e.Actor, e.Channel, e.Action = auditClean(e.Actor), auditClean(e.Channel), auditClean(e.Action)
	e.Subject, e.Outcome = auditClean(e.Subject), auditClean(e.Outcome)
	a.log.Info("AUDIT", "at", e.At, "actor", e.Actor, "channel", e.Channel, "action", e.Action, "subject", e.Subject, "outcome", e.Outcome)
	res, err := a.db.ExecContext(ctx, `INSERT INTO audit(at,actor,channel,action,subject,outcome) VALUES(?,?,?,?,?,?)`,
		e.At, e.Actor, e.Channel, e.Action, e.Subject, e.Outcome)
	if err != nil {
		a.log.Error("audit table write failed", "err", err)
		return
	}
	if last, err := res.LastInsertId(); err == nil && a.MaxRows > 0 && last > a.MaxRows {
		if _, err := a.db.ExecContext(ctx, `DELETE FROM audit WHERE seq<=?`, last-a.MaxRows); err != nil {
			a.log.Error("audit table trim failed", "err", err)
		}
	}
}

// List returns the newest entries first, at most limit (1 to 500).
func (a *Audit) List(ctx context.Context, limit int) ([]AuditEntry, error) {
	if limit < 1 || limit > 500 {
		limit = 100
	}
	rows, err := a.db.QueryContext(ctx, `SELECT at,actor,channel,action,subject,outcome FROM audit ORDER BY seq DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AuditEntry{}
	for rows.Next() {
		var e AuditEntry
		if err := rows.Scan(&e.At, &e.Actor, &e.Channel, &e.Action, &e.Subject, &e.Outcome); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}
