package core

import (
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func guardFixture(t *testing.T) *RESTGuard {
	t.Helper()
	db := testDB(t)
	ap, err := LoadApprovers(writeApprovers(t, `[{"id":"desk:lead-1","role":"desk-lead","token_sha256":"`+sum("good-token")+`"}]`))
	if err != nil {
		t.Fatal(err)
	}
	return NewRESTGuard(ap, NewAudit(db, slog.New(slog.DiscardHandler), func() time.Time { return t0 }), func() time.Time { return t0 }, 5)
}

func req(remote, token string) *http.Request {
	r := httptest.NewRequest("POST", "/x", strings.NewReader(`{}`))
	r.RemoteAddr = remote
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	return r
}

func TestIsLoopback(t *testing.T) {
	for addr, want := range map[string]bool{"127.0.0.1:5000": true, "[::1]:5000": true, "10.1.2.3:5000": false, "192.0.2.1:1": false, "garbage": false} {
		if got := IsLoopback(req(addr, "")); got != want {
			t.Errorf("%s: %v", addr, got)
		}
	}
}

func TestProposerNeedsATokenUnlessLoopback(t *testing.T) {
	g := guardFixture(t)
	if who, err := g.Proposer(req("127.0.0.1:1", "")); err != nil || who != "rest" {
		t.Errorf("loopback without token: %q %v", who, err)
	}
	if _, err := g.Proposer(req("10.1.2.3:1", "")); !IsKind(err, Unauthorized) {
		t.Errorf("remote without token must be refused: %v", err)
	}
	if who, err := g.Proposer(req("10.1.2.3:1", "good-token")); err != nil || who != "desk:lead-1" {
		t.Errorf("remote with token: %q %v", who, err)
	}
	if _, err := g.Proposer(req("127.0.0.1:1", "wrong")); !IsKind(err, Unauthorized) {
		t.Errorf("a wrong token is never downgraded to anonymous: %v", err)
	}
}

func TestFailedLoginsAreCountedAndNeverLockOutAValidToken(t *testing.T) {
	g := guardFixture(t)
	var last error
	for i := 0; i < FailLimitPerMinute+5; i++ {
		_, last = g.RequireApprover(req("10.1.2.3:1", "wrong"), "approve")
	}
	if !IsKind(last, TooMany) {
		t.Fatalf("repeated failures must end in 429, got %v", last)
	}
	if _, err := g.RequireApprover(req("10.1.2.3:1", "good-token"), "approve"); err != nil {
		t.Fatalf("a valid token must still work: %v", err)
	}
}

func TestGuardWrapRefusesCrossOriginAndLimitsWrites(t *testing.T) {
	g := guardFixture(t)
	h := g.Wrap(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) }))
	r := req("10.1.2.3:1", "")
	r.Header.Set("Origin", "http://evil.example")
	r.Header.Set("Sec-Fetch-Site", "cross-site")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Errorf("cross-origin: %d", w.Code)
	}
	codes := map[int]int{}
	for i := 0; i < 8; i++ {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req("10.1.2.3:1", ""))
		codes[w.Code]++
	}
	if codes[200] != 5 || codes[429] != 3 {
		t.Errorf("write limit: %v", codes)
	}
	get := httptest.NewRequest("GET", "/x", nil)
	get.RemoteAddr = "10.1.2.3:1"
	w = httptest.NewRecorder()
	h.ServeHTTP(w, get)
	if w.Code != 200 {
		t.Errorf("reads are not limited: %d", w.Code)
	}
}
