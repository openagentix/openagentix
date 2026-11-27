package core

import (
	"net"
	"net/http"
	"net/url"
	"time"
)

// FailLimitPerMinute is how many refused logins one host may make each minute before it gets 429.
const FailLimitPerMinute = 30

// RESTGuard holds what every domain's REST port shares: approver authentication, proposer naming, a write limit
// per host, a limit on failed logins, and the cross-origin check.
type RESTGuard struct {
	approvers *Approvers
	audit     *Audit
	writes    *Limiter
	fails     *Limiter
}

// NewRESTGuard returns a guard allowing writesPerMinute writes per host.
func NewRESTGuard(ap *Approvers, audit *Audit, clock Clock, writesPerMinute int) *RESTGuard {
	return &RESTGuard{approvers: ap, audit: audit, writes: NewLimiter(writesPerMinute, time.Minute, clock), fails: NewLimiter(FailLimitPerMinute, time.Minute, clock)}
}

// IsLoopback reports whether the request came from the pod's own loopback address. Through kubectl port-forward,
// a person reaches the service this way.
func IsLoopback(r *http.Request) bool {
	h, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return false
	}
	ip := net.ParseIP(h)
	return ip != nil && ip.IsLoopback()
}

// Wrap refuses cross-origin browser writes and rate limits every write per host.
func (g *RESTGuard) Wrap(next http.Handler) http.Handler {
	limited := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// url.URL.Query() drops a pair with a raw semicolon (or a bad escape) and its error, so a filter would silently become "no filter" and a route
		// would list every row. A query that does not parse is refused here, before any route sees it.
		if _, err := url.ParseQuery(r.URL.RawQuery); err != nil {
			WriteJSON(w, http.StatusBadRequest, map[string]string{"error": "the query string is not valid (a raw semicolon or a bad escape)"})
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead && !g.writes.Allow(Host(r)) {
			WriteJSON(w, http.StatusTooManyRequests, map[string]string{"error": "too many writes from this host; try again in a minute"})
			return
		}
		next.ServeHTTP(w, r)
	})
	return http.NewCrossOriginProtection().Handler(limited)
}

// RequireApprover authenticates the caller. A refusal is audited as "anonymous" and counted per host; a host
// that keeps failing gets 429 instead of 401. A valid token is never blocked by the count.
func (g *RESTGuard) RequireApprover(r *http.Request, action string) (Approver, error) {
	if who, ok := g.approvers.Authenticate(r); ok {
		return who, nil
	}
	g.audit.Record(r.Context(), AuditEntry{Actor: "anonymous", Channel: "rest", Action: action, Outcome: "denied"})
	if !g.fails.Allow(Host(r)) {
		return Approver{}, &Error{Kind: TooMany, Msg: "too many refused logins from this host; try again in a minute"}
	}
	return Approver{}, &Error{Kind: Unauthorized, Msg: "a valid approver token is required"}
}

// Proposer names who makes a proposal on REST. A valid approver token gives that approver's id, and that approver
// then cannot decide the proposal. With no token, only a caller on the pod's own loopback is accepted, named
// "rest". Any other caller needs a token, and a wrong token is never treated as no token.
func (g *RESTGuard) Proposer(r *http.Request) (string, error) {
	if r.Header.Get("Authorization") != "" {
		who, err := g.RequireApprover(r, "propose")
		return who.ID, err
	}
	if IsLoopback(r) {
		return "rest", nil
	}
	g.audit.Record(r.Context(), AuditEntry{Actor: "anonymous", Channel: "rest", Action: "propose", Outcome: "denied"})
	return "", &Error{Kind: Unauthorized, Msg: "a valid approver token is required to propose from outside the pod"}
}
