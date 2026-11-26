package bridge

import (
	"context"
	"net/http/httptest"
	"testing"
	"time"
)

// Readiness (issue #200): /readyz is 503 until one getUpdates has succeeded, even
// though /healthz counts the start-up moment as fresh so a slow start is not killed.
func TestBridge_ReadyzWaitsForFirstSuccessfulPoll(t *testing.T) {
	f := newFakeTelegram(t)
	f.failNext = 1_000_000
	b := newBridge(f, okAgent(), NewMemoryStore())
	b.PollTimeout = 10

	get := func(path string) int {
		rec := httptest.NewRecorder()
		b.HealthHandler().ServeHTTP(rec, httptest.NewRequest("GET", path, nil))
		return rec.Code
	}
	if c := get("/readyz"); c != 503 {
		t.Fatalf("/readyz before Run = %d, want 503", c)
	}
	calls := func() int { f.mu.Lock(); defer f.mu.Unlock(); return f.getCalls }
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- b.Run(ctx) }()
	defer func() { cancel(); <-done }()

	deadline := time.Now().Add(3 * time.Second)
	for calls() < 2 {
		if time.Now().After(deadline) {
			t.Fatal("getUpdates was not called twice before timeout")
		}
		time.Sleep(time.Millisecond)
	}
	if c := get("/healthz"); c != 200 {
		t.Fatalf("/healthz while start-up polls fail = %d, want 200 (start-up counts as fresh)", c)
	}
	if c := get("/readyz"); c != 503 {
		t.Fatalf("/readyz while every poll fails = %d, want 503", c)
	}
	f.mu.Lock()
	f.failNext = 0
	f.mu.Unlock()
	for get("/readyz") != 200 {
		if time.Now().After(deadline.Add(3 * time.Second)) {
			t.Fatal("/readyz did not turn 200 after a successful poll")
		}
		time.Sleep(time.Millisecond)
	}
}
