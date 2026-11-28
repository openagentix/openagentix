package core

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Event triggers (ADR 0027, slices 5 and 6). A system of record starts one agent run for one of its records through the A2A gate, as an
// event caller: it sends the short text "Work case <id>" and nothing else, as its own ServiceAccount. This file is the system of record's
// half of that: an outbox of events written only by an INTAKE route, in the same transaction as the case, and a sender that delivers
// them at least once.
//
// Rules this file keeps:
//   - A row is written only by Events.Enqueue, called by an intake route's service method (a fault, a service request, a new dispute).
//     No MCP tool calls it, so an agent cannot start a run for itself.
//   - The text is built from the record id alone. Free text of a person (a dealer's note, a customer's words) never leaves the service.
//   - The projected token is read from a file for every request and is in no log, no audit line and no error.
//   - At least once, bounded: a failed call is retried with a backoff and then given up; a 429 waits for Retry-After and uses no try; a
//     2xx with a failed task is retried under a new attempt id; a case that is still unworked after a set time is asked again, up to a bound.

// EventRecordID is the shape of the record ids an event may name (SVC-2026-0007, DSP-2026-0042).
var eventRecordID = regexp.MustCompile(`^[A-Z]{3}-[0-9]{4}-[0-9]{4}$`)

// EventText is the whole message an event sends.
func EventText(subject string) string { return "Work case " + subject }

const eventSchema = `
CREATE TABLE IF NOT EXISTS events(
  seq INTEGER PRIMARY KEY AUTOINCREMENT, subject TEXT NOT NULL, attempt INTEGER NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending','done','dead')), tries INTEGER NOT NULL DEFAULT 0,
  next_at TEXT NOT NULL, created_at TEXT NOT NULL, sent_at TEXT NOT NULL DEFAULT '',
  task_id TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT '', UNIQUE(subject, attempt));
CREATE INDEX IF NOT EXISTS events_due ON events(status, next_at);
`

// Events is the event outbox. It exists only when the sender is configured: NewEvents makes the table, and nothing else does.
type Events struct {
	db    *sql.DB
	clock Clock
}

// EventRow is one event: attempt 1 is the first send of a record, later attempts are asked again.
type EventRow struct {
	Seq       int64
	Subject   string
	Attempt   int
	Status    string // pending, done, dead
	Tries     int    // failed calls of this attempt (a 429 is not a try)
	NextAt    string
	CreatedAt string
	SentAt    string
	TaskID    string
	State     string
}

// NewEvents makes the outbox table.
func NewEvents(db *sql.DB, clock Clock) (*Events, error) {
	if _, err := db.Exec(eventSchema); err != nil {
		return nil, err
	}
	return &Events{db: db, clock: clock}, nil
}

// Enqueue queues the first event of a record, in the caller's transaction. Only an intake route may call it. A record queues once.
func (e *Events) Enqueue(ctx context.Context, tx *sql.Tx, subject string) error {
	if !eventRecordID.MatchString(subject) {
		return errors.New("event: not a record id")
	}
	now := FormatTime(e.clock())
	_, err := tx.ExecContext(ctx, `INSERT OR IGNORE INTO events(subject,attempt,status,tries,next_at,created_at) VALUES(?,1,'pending',0,?,?)`, subject, now, now)
	return err
}

const eventCols = `seq,subject,attempt,status,tries,next_at,created_at,sent_at,task_id,state`

func scanEvent(r rowScanner) (EventRow, error) {
	var x EventRow
	err := r.Scan(&x.Seq, &x.Subject, &x.Attempt, &x.Status, &x.Tries, &x.NextAt, &x.CreatedAt, &x.SentAt, &x.TaskID, &x.State)
	return x, err
}

// List returns every event, oldest first (tests and the audit of a run).
func (e *Events) List(ctx context.Context) ([]EventRow, error) {
	rows, err := e.db.QueryContext(ctx, `SELECT `+eventCols+` FROM events ORDER BY seq`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []EventRow
	for rows.Next() {
		x, err := scanEvent(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, x)
	}
	return out, rows.Err()
}

// SenderConfig configures the sender. Without URL and TokenFile there is no sender.
type SenderConfig struct {
	URL           string        // the agent on the gate: https://gate.../agents/<namespace>/<name>
	TokenFile     string        // the projected ServiceAccount token (audience of the gate), read for every request
	UnworkedAfter time.Duration // ask again for a case that is still unworked after this long (default 30 minutes)
	MaxAttempts   int           // attempts per record, the first included (default 3)
	MaxTries      int           // failed calls of one attempt before it is given up (default 8)
	// Unworked returns the ids of the cases that are still unworked and were opened at least olderThan ago. Only a record that has an event is asked.
	Unworked   func(ctx context.Context, olderThan time.Duration) ([]string, error)
	HTTPClient *http.Client
}

// Sender delivers the events of an Events outbox to the gate.
type Sender struct {
	ev          *Events
	cfg         SenderConfig
	audit       *Audit
	log         *slog.Logger
	clock       Clock
	client      *http.Client
	pausedUntil time.Time
}

var gateAgentPath = regexp.MustCompile(`^/agents/[a-z0-9][a-z0-9.-]*/[a-z0-9][a-z0-9.-]*/?$`)

// NewSender checks the configuration. It fails closed: a half configured sender does not start.
func NewSender(ev *Events, cfg SenderConfig, audit *Audit, log *slog.Logger, clock Clock) (*Sender, error) {
	if cfg.URL == "" || cfg.TokenFile == "" {
		return nil, errors.New("the event sender needs a gate URL and a token file")
	}
	u, err := url.Parse(cfg.URL)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || u.User != nil || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" {
		return nil, errors.New("the event gate URL must be http or https with a host, and without credentials, query or fragment")
	}
	if !gateAgentPath.MatchString(u.Path) {
		return nil, errors.New("the event gate URL must name one agent: /agents/<namespace>/<name>")
	}
	if cfg.UnworkedAfter <= 0 {
		cfg.UnworkedAfter = 30 * time.Minute
	}
	if cfg.MaxAttempts <= 0 {
		cfg.MaxAttempts = 3
	}
	if cfg.MaxTries <= 0 {
		cfg.MaxTries = 8
	}
	c := cfg.HTTPClient
	if c == nil {
		// no proxy from the environment: the token goes to the gate and nowhere else
		c = &http.Client{Timeout: 20 * time.Second, Transport: &http.Transport{Proxy: nil, MaxIdleConns: 2, IdleConnTimeout: 30 * time.Second}}
	}
	cc := *c
	cc.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse } // a redirect would carry the token elsewhere
	return &Sender{ev: ev, cfg: cfg, audit: audit, log: log, clock: clock, client: &cc}, nil
}

// MaxAttempts is how many attempts one record gets, the first included.
func (s *Sender) MaxAttempts() int { return s.cfg.MaxAttempts }

// Run sweeps and sends until ctx ends.
func (s *Sender) Run(ctx context.Context, tick time.Duration) {
	if tick <= 0 {
		tick = 2 * time.Second
	}
	t := time.NewTicker(tick)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := s.Step(ctx); err != nil && ctx.Err() == nil {
				s.log.Error("event sender pass failed", "err", err)
			}
		}
	}
}

// Step is one pass: ask again for unworked cases, then send what is due (stopping at a 429 until Retry-After is over).
func (s *Sender) Step(ctx context.Context) error {
	now := s.clock()
	if err := s.sweep(ctx, now); err != nil {
		return err
	}
	if now.Before(s.pausedUntil) {
		return nil
	}
	rows, err := s.ev.db.QueryContext(ctx, `SELECT `+eventCols+` FROM events WHERE status='pending' AND next_at<=? ORDER BY seq LIMIT 50`, FormatTime(now))
	if err != nil {
		return err
	}
	var due []EventRow
	for rows.Next() {
		x, err := scanEvent(rows)
		if err != nil {
			_ = rows.Close()
			return err
		}
		due = append(due, x)
	}
	if err := rows.Close(); err != nil {
		return err
	}
	for _, x := range due {
		if ctx.Err() != nil {
			return nil
		}
		if s.deliver(ctx, x) { // true: the gate said "slow down"
			return nil
		}
	}
	return nil
}

// sweep queues a new attempt for a record that has an event, whose last attempt was sent (or given up) at least UnworkedAfter ago, and that is
// still unworked. It never queues while an attempt is pending, and never beyond MaxAttempts.
func (s *Sender) sweep(ctx context.Context, now time.Time) error {
	if s.cfg.Unworked == nil {
		return nil
	}
	ids, err := s.cfg.Unworked(ctx, s.cfg.UnworkedAfter)
	if err != nil {
		return err
	}
	for _, id := range ids {
		if !eventRecordID.MatchString(id) {
			continue
		}
		last, err := scanEvent(s.ev.db.QueryRowContext(ctx, `SELECT `+eventCols+` FROM events WHERE subject=? ORDER BY attempt DESC LIMIT 1`, id))
		if errors.Is(err, sql.ErrNoRows) {
			continue // no event ever: not opened through an intake route that sends events
		}
		if err != nil {
			return err
		}
		if last.Status == "pending" || last.Attempt >= s.cfg.MaxAttempts {
			continue
		}
		ref := last.SentAt
		if ref == "" {
			ref = last.NextAt
		}
		at, err := time.Parse(TimeFmt, ref)
		if err != nil || now.Sub(at) < s.cfg.UnworkedAfter {
			continue
		}
		if _, err := s.ev.db.ExecContext(ctx, `INSERT OR IGNORE INTO events(subject,attempt,status,tries,next_at,created_at) VALUES(?,?,'pending',0,?,?)`,
			id, last.Attempt+1, FormatTime(now), FormatTime(now)); err != nil {
			return err
		}
		s.record(ctx, "event_asked_again", id, "ok")
	}
	return nil
}

// MessageID is the id the gate gets: the record id for the first attempt, then -r2, -r3.
func messageID(x EventRow) string {
	if x.Attempt <= 1 {
		return "case-" + x.Subject
	}
	return "case-" + x.Subject + "-r" + strconv.Itoa(x.Attempt)
}

var (
	taskIDRe    = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)
	taskStateRe = regexp.MustCompile(`^TASK_STATE_[A-Z_]{1,32}$`)
)

func (s *Sender) record(ctx context.Context, action, subject, outcome string) {
	s.audit.Record(ctx, AuditEntry{Actor: "event_sender", Channel: "internal", Action: action, Subject: subject, Outcome: outcome})
}

// deliver sends one event and records the result. It returns true when the gate asked the sender to slow down.
func (s *Sender) deliver(ctx context.Context, x EventRow) (slowDown bool) {
	now := s.clock()
	mid := messageID(x)
	type part struct {
		Text string `json:"text"`
	}
	type message struct {
		MessageID string `json:"messageId"`
		Role      string `json:"role"`
		Parts     []part `json:"parts"`
	}
	body, _ := json.Marshal(struct {
		JSONRPC string `json:"jsonrpc"`
		ID      string `json:"id"`
		Method  string `json:"method"`
		Params  struct {
			Message message `json:"message"`
		} `json:"params"`
	}{"2.0", mid, "SendMessage", struct {
		Message message `json:"message"`
	}{message{mid, "ROLE_USER", []part{{EventText(x.Subject)}}}}})
	tok, err := os.ReadFile(s.cfg.TokenFile)
	if err != nil || strings.TrimSpace(string(tok)) == "" {
		s.fail(ctx, x, now, "no_token") // the path and the content are not logged
		return false
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.cfg.URL, strings.NewReader(string(body)))
	if err != nil {
		s.fail(ctx, x, now, "bad_request")
		return false
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(tok)))
	resp, err := s.client.Do(req)
	if err != nil {
		s.fail(ctx, x, now, "network") // the error text can hold the URL: not logged
		return false
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	switch {
	case resp.StatusCode == http.StatusTooManyRequests:
		wait := retryAfter(resp.Header.Get("Retry-After"), now)
		s.pausedUntil = now.Add(wait)
		s.record(ctx, "event_rate_limited", x.Subject, "denied")
		return true
	case resp.StatusCode >= 200 && resp.StatusCode <= 299:
		var out struct {
			Result *struct {
				ID     string `json:"id"`
				Status struct {
					State string `json:"state"`
				} `json:"status"`
			} `json:"result"`
		}
		if err := json.Unmarshal(b, &out); err != nil || out.Result == nil || !taskIDRe.MatchString(out.Result.ID) || !taskStateRe.MatchString(out.Result.Status.State) {
			s.fail(ctx, x, now, "bad_answer")
			return false
		}
		s.accepted(ctx, x, now, out.Result.ID, out.Result.Status.State)
		return false
	default:
		s.fail(ctx, x, now, "http_"+strconv.Itoa(resp.StatusCode))
		return false
	}
}

// accepted marks the attempt done. A task that already failed (a repeat of an id returns the first task) is asked again under a new attempt id.
func (s *Sender) accepted(ctx context.Context, x EventRow, now time.Time, task, state string) {
	failed := state == "TASK_STATE_FAILED" || state == "TASK_STATE_CANCELED" || state == "TASK_STATE_REJECTED"
	status := "done"
	if failed && x.Attempt >= s.cfg.MaxAttempts {
		status = "dead"
	}
	if _, err := s.ev.db.ExecContext(ctx, `UPDATE events SET status=?, sent_at=?, task_id=?, state=? WHERE seq=?`, status, FormatTime(now), task, state, x.Seq); err != nil {
		s.log.Error("event row not updated", "err", err)
		return
	}
	switch {
	case !failed:
		s.record(ctx, "event_sent", x.Subject, "ok")
	case status == "dead":
		s.record(ctx, "event_dead", x.Subject, "error")
	default:
		if _, err := s.ev.db.ExecContext(ctx, `INSERT OR IGNORE INTO events(subject,attempt,status,tries,next_at,created_at) VALUES(?,?,'pending',0,?,?)`,
			x.Subject, x.Attempt+1, FormatTime(now), FormatTime(now)); err != nil {
			s.log.Error("event retry not queued", "err", err)
		}
		s.record(ctx, "event_retry", x.Subject, "error")
	}
}

// fail counts one failed call, with a backoff of 2 s doubling to 5 minutes, and gives the attempt up after MaxTries.
func (s *Sender) fail(ctx context.Context, x EventRow, now time.Time, why string) {
	tries := x.Tries + 1
	if tries >= s.cfg.MaxTries {
		_, _ = s.ev.db.ExecContext(ctx, `UPDATE events SET status='dead', tries=? WHERE seq=?`, tries, x.Seq)
		s.record(ctx, "event_dead", x.Subject, "error")
		s.log.Warn("event given up", "subject", x.Subject, "attempt", x.Attempt, "why", why)
		return
	}
	wait := 2 * time.Second << (tries - 1)
	if wait > 5*time.Minute || wait <= 0 {
		wait = 5 * time.Minute
	}
	_, _ = s.ev.db.ExecContext(ctx, `UPDATE events SET tries=?, next_at=? WHERE seq=?`, tries, FormatTime(now.Add(wait)), x.Seq)
	s.record(ctx, "event_retry", x.Subject, "error")
	s.log.Warn("event not delivered, will retry", "subject", x.Subject, "attempt", x.Attempt, "tries", tries, "why", why)
}

// retryAfter reads Retry-After (seconds or an HTTP date) and bounds it to 1 second .. 5 minutes. Missing or unreadable: 5 seconds.
func retryAfter(v string, now time.Time) time.Duration {
	d := 5 * time.Second
	v = strings.TrimSpace(v)
	if n, err := strconv.ParseInt(v, 10, 64); err == nil {
		d = time.Duration(min(max(n, 1), 300)) * time.Second
	} else if t, err := http.ParseTime(v); err == nil {
		d = min(max(t.Sub(now), time.Second), 5*time.Minute)
	}
	return d
}
