// Package core holds what every domain of the records service shares: the SQLite store, the audit log, approver
// authentication, the approval queue, timers, the mock outbox and the small HTTP helpers. A domain (internal/bank)
// plugs in through Hooks and adds its own tables, REST routes and MCP tools.
//
// Rules this package enforces for every domain:
//   - Every statement uses bound parameters. No SQL is built from input.
//   - A proposed act executes only inside Approve, called with an authenticated approver identity.
//   - The audit log holds identifiers and outcomes, never message text or personal data.
package core

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	_ "modernc.org/sqlite" // pure Go SQLite driver (BSD-3-Clause), no cgo
)

// Clock returns the current time. Tests pass a fixed one.
type Clock func() time.Time

// TimeFmt is the one stored and served time format (UTC, seconds). It sorts as text.
const TimeFmt = "2006-01-02T15:04:05Z"

// FormatTime renders t in TimeFmt.
func FormatTime(t time.Time) string { return t.UTC().Format(TimeFmt) }

// ErrKind classifies an Error for the HTTP layer.
type ErrKind int

const (
	Invalid ErrKind = iota + 1
	Unauthorized
	Forbidden
	NotFound
	Conflict
	TooMany
)

// Error is a safe, user-facing error. Msg never holds input text or internal detail.
type Error struct {
	Kind ErrKind
	Msg  string
}

func (e *Error) Error() string { return e.Msg }

// IsKind reports whether err is an *Error of the given kind.
func IsKind(err error, k ErrKind) bool {
	var e *Error
	return errors.As(err, &e) && e.Kind == k
}

// Open opens (creating it if needed) the SQLite file at path. One connection serialises every write, which is
// plenty for a demo service and removes lock errors.
func Open(path string) (*sql.DB, error) {
	dsn := "file:" + (&url.URL{Path: path}).EscapedPath() +
		"?_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if err := db.Ping(); err != nil {
		_ = db.Close()
		return nil, err
	}
	return db, nil
}

const coreSchema = `
CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS audit(
  seq INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL, actor TEXT NOT NULL, channel TEXT NOT NULL,
  action TEXT NOT NULL, subject TEXT NOT NULL, outcome TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS approvals(
  seq INTEGER PRIMARY KEY AUTOINCREMENT, subject TEXT NOT NULL, kind TEXT NOT NULL, amount_cents INTEGER NOT NULL,
  payload_hash TEXT NOT NULL, payload TEXT NOT NULL, subject_version INTEGER NOT NULL, status TEXT NOT NULL
    CHECK (status IN ('pending','approved','rejected','superseded')),
  proposed_by TEXT NOT NULL, proposed_at TEXT NOT NULL, decided_by TEXT NOT NULL DEFAULT '', decided_at TEXT NOT NULL DEFAULT '',
  decision_note TEXT NOT NULL DEFAULT '');
CREATE UNIQUE INDEX IF NOT EXISTS approvals_one_pending ON approvals(subject) WHERE status='pending';
CREATE TABLE IF NOT EXISTS timers(
  seq INTEGER PRIMARY KEY AUTOINCREMENT, subject TEXT NOT NULL, name TEXT NOT NULL, due_at TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending','fired')), created_at TEXT NOT NULL, fired_at TEXT NOT NULL DEFAULT '');
CREATE INDEX IF NOT EXISTS timers_due ON timers(status, due_at);
CREATE TABLE IF NOT EXISTS outbox(
  seq INTEGER PRIMARY KEY AUTOINCREMENT, subject TEXT NOT NULL, kind TEXT NOT NULL, body TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('draft','queued','discarded')),
  approval_id TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, queued_at TEXT NOT NULL DEFAULT '');
CREATE INDEX IF NOT EXISTS outbox_subject ON outbox(subject);
`

// MigrateCore creates the shared tables.
func MigrateCore(ctx context.Context, db *sql.DB) error {
	_, err := db.ExecContext(ctx, coreSchema)
	return err
}

// FormatID renders the public id of row n, like APR-0007.
func FormatID(prefix string, n int64) string { return fmt.Sprintf("%s-%04d", prefix, n) }

var idPattern = regexp.MustCompile(`^[A-Z]{3}-([0-9]{1,9})$`)

// ParseID reads an id made by FormatID. It accepts nothing else.
func ParseID(prefix, s string) (int64, bool) {
	m := idPattern.FindStringSubmatch(s)
	if m == nil || !strings.HasPrefix(s, prefix+"-") {
		return 0, false
	}
	n, err := strconv.ParseInt(m[1], 10, 64)
	if err != nil || n <= 0 {
		return 0, false
	}
	return n, true
}

// CleanText trims s, refuses control characters other than newline and tab, and bounds its length in runes.
// field names the field in the error; the input itself is never echoed.
func CleanText(field, s string, max int, required bool) (string, error) {
	s = strings.TrimSpace(s)
	if s == "" && required {
		return "", &Error{Kind: Invalid, Msg: field + " is required"}
	}
	if n := len([]rune(s)); n > max {
		return "", &Error{Kind: Invalid, Msg: fmt.Sprintf("%s is longer than %d characters", field, max)}
	}
	for _, r := range s {
		if r < 0x20 && r != '\n' && r != '\t' || r == 0x7f {
			return "", &Error{Kind: Invalid, Msg: field + " has a control character"}
		}
	}
	return s, nil
}
