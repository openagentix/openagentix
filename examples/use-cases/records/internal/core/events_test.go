package core

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const tokenCanary = "EVENT-TOKEN-CANARY-91357"

type fakeGate struct {
	t       *testing.T
	srv     *httptest.Server
	mu      sync.Mutex
	reqs    []gateReq
	handler func(n int, r gateReq, w http.ResponseWriter)
}

type gateReq struct {
	Path, Auth, Body, ContentType string
	Header                        http.Header
}

func newFakeGate(t *testing.T, h func(n int, r gateReq, w http.ResponseWriter)) *fakeGate {
	g := &fakeGate{t: t, handler: h}
	g.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		g.mu.Lock()
		g.reqs = append(g.reqs, gateReq{Path: r.URL.Path, Auth: r.Header.Get("Authorization"), Body: string(b), ContentType: r.Header.Get("Content-Type"), Header: r.Header.Clone()})
		n, req := len(g.reqs), g.reqs[len(g.reqs)-1]
		g.mu.Unlock()
		g.handler(n, req, w)
	}))
	t.Cleanup(g.srv.Close)
	return g
}

func (g *fakeGate) requests() []gateReq {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]gateReq(nil), g.reqs...)
}

func answer(w http.ResponseWriter, state string) {
	w.Header().Set("Content-Type", "application/json")
	_, _ = io.WriteString(w, `{"jsonrpc":"2.0","id":"x","result":{"id":"task-1","status":{"state":"`+state+`"}}}`)
}

type evRig struct {
	t      *testing.T
	db     *sql.DB
	ev     *Events
	s      *Sender
	gate   *fakeGate
	now    time.Time
	logs   *bytes.Buffer
	audit  *Audit
	unwork []string
}

func (r *evRig) clock() time.Time { return r.now }

func newEvRig(t *testing.T, h func(n int, r gateReq, w http.ResponseWriter), mut func(*SenderConfig)) *evRig {
	t.Helper()
	r := &evRig{t: t, now: t0, logs: &bytes.Buffer{}}
	r.db = testDB(t)
	log := slog.New(slog.NewJSONHandler(r.logs, nil))
	r.audit = NewAudit(r.db, log, r.clock)
	var err error
	if r.ev, err = NewEvents(r.db, r.clock); err != nil {
		t.Fatal(err)
	}
	r.gate = newFakeGate(t, h)
	tok := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(tok, []byte(tokenCanary+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := SenderConfig{URL: r.gate.srv.URL + "/agents/kagent/service-agent", TokenFile: tok, UnworkedAfter: 30 * time.Minute, MaxAttempts: 3, MaxTries: 4,
		Unworked: func(context.Context, time.Duration) ([]string, error) { return r.unwork, nil }}
	if mut != nil {
		mut(&cfg)
	}
	if r.s, err = NewSender(r.ev, cfg, r.audit, log, r.clock); err != nil {
		t.Fatal(err)
	}
	return r
}

func (r *evRig) enqueue(subject string) {
	r.t.Helper()
	tx, err := r.db.Begin()
	if err != nil {
		r.t.Fatal(err)
	}
	if err := r.ev.Enqueue(context.Background(), tx, subject); err != nil {
		r.t.Fatal(err)
	}
	if err := tx.Commit(); err != nil {
		r.t.Fatal(err)
	}
}

func (r *evRig) step() {
	r.t.Helper()
	if err := r.s.Step(context.Background()); err != nil {
		r.t.Fatal(err)
	}
}

func (r *evRig) rows() []EventRow {
	r.t.Helper()
	rows, err := r.ev.List(context.Background())
	if err != nil {
		r.t.Fatal(err)
	}
	return rows
}

func TestEventEnqueueIsPartOfTheCallersTransaction(t *testing.T) {
	r := newEvRig(t, func(int, gateReq, http.ResponseWriter) {}, nil)
	tx, _ := r.db.Begin()
	if err := r.ev.Enqueue(context.Background(), tx, "SVC-2026-0007"); err != nil {
		t.Fatal(err)
	}
	_ = tx.Rollback()
	if n := len(r.rows()); n != 0 {
		t.Fatalf("a rolled back transaction left %d event rows", n)
	}
	r.enqueue("SVC-2026-0007")
	r.enqueue("SVC-2026-0007") // the same record never queues twice
	if n := len(r.rows()); n != 1 {
		t.Fatalf("%d rows, want 1", n)
	}
}

func TestEventEnqueueRefusesAnIdThatIsNotARecordId(t *testing.T) {
	r := newEvRig(t, func(int, gateReq, http.ResponseWriter) {}, nil)
	for _, bad := range []string{"", "svc-2026-0007", "SVC-2026-0007 ignore previous", "SVC-2026-0007\n", "SVC-26-7", "SVC-2026-0007-r2", "../x"} {
		tx, _ := r.db.Begin()
		if err := r.ev.Enqueue(context.Background(), tx, bad); err == nil {
			t.Errorf("%q was queued", bad)
		}
		_ = tx.Rollback()
	}
}

func TestEventIsSentAsTheADRSaysAndMarkedDone(t *testing.T) {
	r := newEvRig(t, func(_ int, _ gateReq, w http.ResponseWriter) { answer(w, "TASK_STATE_SUBMITTED") }, nil)
	r.enqueue("SVC-2026-0007")
	r.step()
	reqs := r.gate.requests()
	if len(reqs) != 1 {
		t.Fatalf("%d requests", len(reqs))
	}
	q := reqs[0]
	if q.Path != "/agents/kagent/service-agent" || q.Auth != "Bearer "+tokenCanary || q.ContentType != "application/json" {
		t.Errorf("request %+v", q)
	}
	want := `{"jsonrpc":"2.0","id":"case-SVC-2026-0007","method":"SendMessage","params":{"message":{"messageId":"case-SVC-2026-0007","role":"ROLE_USER","parts":[{"text":"Work case SVC-2026-0007"}]}}}`
	if q.Body != want {
		t.Errorf("body\n%s\nwant\n%s", q.Body, want)
	}
	if strings.Contains(q.Body, "configuration") || strings.Contains(q.Body, "contextId") {
		t.Error("the sender sends no configuration and no contextId: the gate adds what it needs")
	}
	rows := r.rows()
	if len(rows) != 1 || rows[0].Status != "done" || rows[0].TaskID != "task-1" || rows[0].State != "TASK_STATE_SUBMITTED" {
		t.Fatalf("rows %+v", rows)
	}
	r.step()
	if n := len(r.gate.requests()); n != 1 {
		t.Fatalf("a done event was sent again (%d requests)", n)
	}
}

func TestEventStatesThatCountAsAccepted(t *testing.T) {
	for _, st := range []string{"TASK_STATE_SUBMITTED", "TASK_STATE_WORKING", "TASK_STATE_COMPLETED"} {
		r := newEvRig(t, func(_ int, _ gateReq, w http.ResponseWriter) { answer(w, st) }, nil)
		r.enqueue("SVC-2026-0007")
		r.step()
		if rows := r.rows(); len(rows) != 1 || rows[0].Status != "done" {
			t.Errorf("%s: rows %+v", st, rows)
		}
	}
}

func TestEventFailedTaskIsRetriedUnderANewAttemptId(t *testing.T) {
	for _, st := range []string{"TASK_STATE_FAILED", "TASK_STATE_CANCELED", "TASK_STATE_REJECTED"} {
		r := newEvRig(t, func(_ int, _ gateReq, w http.ResponseWriter) { answer(w, st) }, nil)
		r.enqueue("SVC-2026-0007")
		r.step()
		r.step()
		r.step()
		r.step() // attempts 1, 2, 3 are sent; there is no fourth
		var ids []string
		for _, q := range r.gate.requests() {
			var m struct {
				Params struct{ Message struct{ MessageID string } }
			}
			if err := json.Unmarshal([]byte(q.Body), &m); err != nil {
				t.Fatal(err)
			}
			ids = append(ids, m.Params.Message.MessageID)
		}
		want := []string{"case-SVC-2026-0007", "case-SVC-2026-0007-r2", "case-SVC-2026-0007-r3"}
		if fmt.Sprint(ids) != fmt.Sprint(want) {
			t.Errorf("%s: message ids %v, want %v", st, ids, want)
		}
		rows := r.rows()
		if len(rows) != 3 || rows[2].Status != "dead" {
			t.Errorf("%s: after the last attempt the row must be dead: %+v", st, rows)
		}
	}
}

func TestEventRateLimitIsHonouredAndConsumesNoTry(t *testing.T) {
	r := newEvRig(t, func(n int, _ gateReq, w http.ResponseWriter) {
		if n <= 2 {
			w.Header().Set("Retry-After", "30")
			w.WriteHeader(429)
			return
		}
		answer(w, "TASK_STATE_SUBMITTED")
	}, nil)
	r.enqueue("SVC-2026-0007")
	r.step() // 429
	r.step() // still paused: nothing is sent
	if n := len(r.gate.requests()); n != 1 {
		t.Fatalf("%d requests while paused", n)
	}
	r.now = r.now.Add(29 * time.Second)
	r.step()
	if n := len(r.gate.requests()); n != 1 {
		t.Fatalf("sent before Retry-After was over (%d requests)", n)
	}
	r.now = r.now.Add(2 * time.Second)
	r.step() // 429 again
	r.now = r.now.Add(31 * time.Second)
	r.step() // accepted
	rows := r.rows()
	if len(rows) != 1 || rows[0].Status != "done" || rows[0].Tries != 0 {
		t.Fatalf("rows %+v: a 429 must not use a try", rows)
	}
	for _, q := range r.gate.requests() {
		if !strings.Contains(q.Body, `"messageId":"case-SVC-2026-0007"`) {
			t.Errorf("a retry after 429 must keep the same message id: %s", q.Body)
		}
	}
}

func TestEventRetryAfterIsBounded(t *testing.T) {
	for _, ra := range []string{"", "x", "-5", "0", "99999999"} {
		r := newEvRig(t, func(_ int, _ gateReq, w http.ResponseWriter) {
			if ra != "" {
				w.Header().Set("Retry-After", ra)
			}
			w.WriteHeader(429)
		}, nil)
		r.enqueue("SVC-2026-0007")
		r.step()
		d := r.s.pausedUntil.Sub(r.now)
		if d < time.Second || d > 5*time.Minute {
			t.Errorf("Retry-After %q gave a pause of %v", ra, d)
		}
	}
}

func TestEventServerErrorsBackOffAndAreBounded(t *testing.T) {
	for name, h := range map[string]func(int, gateReq, http.ResponseWriter){
		"502":                       func(_ int, _ gateReq, w http.ResponseWriter) { w.WriteHeader(502) },
		"500":                       func(_ int, _ gateReq, w http.ResponseWriter) { w.WriteHeader(500) },
		"403":                       func(_ int, _ gateReq, w http.ResponseWriter) { w.WriteHeader(403) },
		"404":                       func(_ int, _ gateReq, w http.ResponseWriter) { w.WriteHeader(404) },
		"401":                       func(_ int, _ gateReq, w http.ResponseWriter) { w.WriteHeader(401) },
		"200 that is not an answer": func(_ int, _ gateReq, w http.ResponseWriter) { _, _ = io.WriteString(w, "<html>") },
		"200 with an error": func(_ int, _ gateReq, w http.ResponseWriter) {
			_, _ = io.WriteString(w, `{"jsonrpc":"2.0","id":"1","error":{"code":-32001,"message":"refused"}}`)
		},
		"redirect": func(_ int, _ gateReq, w http.ResponseWriter) {
			w.Header().Set("Location", "http://evil.invalid/steal")
			w.WriteHeader(307)
		},
	} {
		r := newEvRig(t, h, nil)
		r.enqueue("SVC-2026-0007")
		r.step()
		first := r.gate.requests()
		if len(first) != 1 || len(r.rows()) != 1 || r.rows()[0].Tries != 1 || r.rows()[0].Status != "pending" {
			t.Fatalf("%s: after one failure rows %+v, requests %d", name, r.rows(), len(first))
		}
		r.step() // too early: the backoff has not passed
		if n := len(r.gate.requests()); n != 1 {
			t.Fatalf("%s: retried at once (%d requests)", name, n)
		}
		for i := 0; i < 10; i++ {
			r.now = r.now.Add(10 * time.Minute)
			r.step()
		}
		rows := r.rows()
		if rows[0].Status != "dead" || rows[0].Tries != 4 {
			t.Errorf("%s: want dead after MaxTries 4, got %+v", name, rows[0])
		}
		if n := len(r.gate.requests()); n != 4 {
			t.Errorf("%s: %d requests, want 4", name, n)
		}
		for _, q := range r.gate.requests() {
			if !strings.Contains(q.Body, `"messageId":"case-SVC-2026-0007"`) {
				t.Errorf("%s: a retry of a failed call must keep the message id: %s", name, q.Body)
			}
		}
	}
}

func TestEventBackoffGrows(t *testing.T) {
	r := newEvRig(t, func(_ int, _ gateReq, w http.ResponseWriter) { w.WriteHeader(503) }, func(c *SenderConfig) { c.MaxTries = 8 })
	r.enqueue("SVC-2026-0007")
	var waits []time.Duration
	for i := 0; i < 5; i++ {
		before := r.now
		r.step()
		rows := r.rows()
		waits = append(waits, parseEvTime(t, rows[0].NextAt).Sub(before))
		r.now = parseEvTime(t, rows[0].NextAt)
	}
	for i := 1; i < len(waits); i++ {
		if waits[i] <= waits[i-1] && waits[i] < 5*time.Minute {
			t.Errorf("backoff does not grow: %v", waits)
		}
	}
	if waits[len(waits)-1] > 5*time.Minute {
		t.Errorf("backoff is not capped: %v", waits)
	}
}

func parseEvTime(t *testing.T, s string) time.Time {
	t.Helper()
	v, err := time.Parse(TimeFmt, s)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func TestEventTokenNeverReachesALogOrTheAudit(t *testing.T) {
	r := newEvRig(t, func(_ int, _ gateReq, w http.ResponseWriter) { w.WriteHeader(500) }, nil)
	r.enqueue("SVC-2026-0007")
	for i := 0; i < 6; i++ {
		r.step()
		r.now = r.now.Add(10 * time.Minute)
	}
	es, _ := r.audit.List(context.Background(), 100)
	all := r.logs.String()
	for _, e := range es {
		all += fmt.Sprint(e)
	}
	if strings.Contains(all, tokenCanary) {
		t.Fatal("the token is in a log or the audit")
	}
	if strings.Contains(all, "Work case") {
		t.Fatal("the message text is in a log or the audit")
	}
	if !strings.Contains(all, "event_retry") || !strings.Contains(all, "event_dead") {
		t.Errorf("the audit should say what happened: %s", all)
	}
}

func TestEventMissingTokenFileIsARetryNotACrash(t *testing.T) {
	r := newEvRig(t, func(_ int, _ gateReq, w http.ResponseWriter) { answer(w, "TASK_STATE_SUBMITTED") }, nil)
	if err := os.Remove(r.s.cfg.TokenFile); err != nil {
		t.Fatal(err)
	}
	r.enqueue("SVC-2026-0007")
	r.step()
	if n := len(r.gate.requests()); n != 0 {
		t.Fatalf("a request went out without a token: %d", n)
	}
	if rows := r.rows(); rows[0].Tries != 1 || rows[0].Status != "pending" {
		t.Fatalf("rows %+v", rows)
	}
	if strings.Contains(r.logs.String(), r.s.cfg.TokenFile) {
		t.Error("the path of the token file is in a log")
	}
}

func TestEventBurstIsHeldToTheGatesRateAndAllSentInTheEnd(t *testing.T) {
	// the gate lets three through per round, then answers 429 with Retry-After 20, like a bucket of burst 3
	var round, used atomic.Int64
	var last atomic.Int64
	last.Store(-1)
	r := newEvRig(t, func(_ int, _ gateReq, w http.ResponseWriter) {
		if cur := round.Load(); last.Swap(cur) != cur {
			used.Store(0)
		}
		if used.Add(1) > 3 {
			w.Header().Set("Retry-After", "20")
			w.WriteHeader(429)
			return
		}
		answer(w, "TASK_STATE_SUBMITTED")
	}, nil)
	for i := 1; i <= 10; i++ {
		r.enqueue(fmt.Sprintf("SVC-2026-%04d", i))
	}
	for i := 0; i < 20; i++ {
		round.Add(1)
		r.step()
		r.now = r.now.Add(21 * time.Second)
	}
	done := 0
	for _, row := range r.rows() {
		if row.Status == "done" {
			done++
		}
		if row.Tries != 0 {
			t.Errorf("%s used %d tries: a 429 must not use one", row.Subject, row.Tries)
		}
	}
	if done != 10 {
		t.Fatalf("%d of 10 events were sent", done)
	}
	accepted := map[string]int{}
	for _, row := range r.rows() {
		accepted[row.Subject]++
	}
	for s, n := range accepted {
		if n != 1 {
			t.Errorf("%s has %d rows", s, n)
		}
	}
}

func TestEventSweepAsksAgainForAnUnworkedCase(t *testing.T) {
	r := newEvRig(t, func(_ int, _ gateReq, w http.ResponseWriter) { answer(w, "TASK_STATE_SUBMITTED") }, nil)
	r.enqueue("SVC-2026-0007")
	r.enqueue("SVC-2026-0008")
	r.step()
	if n := len(r.gate.requests()); n != 2 {
		t.Fatalf("%d requests", n)
	}
	r.unwork = []string{"SVC-2026-0007", "SVC-2026-0099"} // 0099 never had an event: it is not asked
	r.now = r.now.Add(29 * time.Minute)
	r.step()
	if n := len(r.gate.requests()); n != 2 {
		t.Fatalf("asked again before the set time (%d requests)", n)
	}
	r.now = r.now.Add(2 * time.Minute)
	r.step()
	reqs := r.gate.requests()
	if len(reqs) != 3 || !strings.Contains(reqs[2].Body, `"messageId":"case-SVC-2026-0007-r2"`) {
		t.Fatalf("requests %d: %+v", len(reqs), reqs)
	}
	for _, q := range reqs {
		if strings.Contains(q.Body, "0099") {
			t.Error("a case that never had an event was asked")
		}
	}
	// the new ask is still within the set time: no third ask yet; then one more, then the bound
	r.step()
	if n := len(r.gate.requests()); n != 3 {
		t.Fatalf("asked twice at once (%d)", n)
	}
	r.now = r.now.Add(31 * time.Minute)
	r.step()
	r.step()
	r.now = r.now.Add(31 * time.Minute)
	r.step()
	r.step()
	reqs = r.gate.requests()
	if len(reqs) != 4 || !strings.Contains(reqs[3].Body, `-r3"`) {
		t.Fatalf("want a third attempt and no fourth, got %d requests", len(reqs))
	}
}

func TestEventSweepDoesNotAskWhileAnAttemptIsPending(t *testing.T) {
	r := newEvRig(t, func(_ int, _ gateReq, w http.ResponseWriter) { w.WriteHeader(502) }, nil)
	r.enqueue("SVC-2026-0007")
	r.unwork = []string{"SVC-2026-0007"}
	for i := 0; i < 3; i++ {
		r.now = r.now.Add(time.Hour)
		r.step()
	}
	for _, row := range r.rows() {
		if row.Attempt > 1 {
			t.Errorf("an attempt that was not finished was asked again: %+v", row)
		}
	}
}

func TestSenderConfigIsStrict(t *testing.T) {
	db := testDB(t)
	ev, _ := NewEvents(db, func() time.Time { return t0 })
	tok := filepath.Join(t.TempDir(), "t")
	_ = os.WriteFile(tok, []byte("x"), 0o600)
	log := slog.New(slog.NewJSONHandler(io.Discard, nil))
	au := NewAudit(db, log, func() time.Time { return t0 })
	for name, c := range map[string]SenderConfig{
		"no url":         {TokenFile: tok},
		"no token file":  {URL: "http://gate.example/agents/kagent/a"},
		"ftp":            {URL: "ftp://gate.example/x", TokenFile: tok},
		"credentials":    {URL: "http://user:pass@gate.example/x", TokenFile: tok},
		"query":          {URL: "http://gate.example/x?a=b", TokenFile: tok},
		"fragment":       {URL: "http://gate.example/x#f", TokenFile: tok},
		"no host":        {URL: "http:///x", TokenFile: tok},
		"not agent path": {URL: "http://gate.example/api/sessions", TokenFile: tok},
	} {
		if _, err := NewSender(ev, c, au, log, func() time.Time { return t0 }); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if _, err := NewSender(ev, SenderConfig{URL: "http://gate.example/agents/kagent/service-agent", TokenFile: tok}, au, log, func() time.Time { return t0 }); err != nil {
		t.Fatal(err)
	}
}

func TestEventsTableExistsOnlyWhenTheSenderIsOn(t *testing.T) {
	db := testDB(t) // the core schema only
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE name='events'`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("the core schema must not hold an events table (%d, %v)", n, err)
	}
	if _, err := NewEvents(db, func() time.Time { return t0 }); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE name='events'`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("NewEvents makes the table (%d, %v)", n, err)
	}
}
