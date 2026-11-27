package core

import (
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net"
	"net/http"
	"sync"
	"time"
)

// Limiter is a fixed-window counter per host. It bounds writes and token guesses on the REST port.
type Limiter struct {
	mu     sync.Mutex
	max    int
	window time.Duration
	clock  Clock
	seen   map[string]*limitWindow
}

type limitWindow struct {
	start time.Time
	n     int
}

// NewLimiter allows max calls per host in each window.
func NewLimiter(max int, window time.Duration, clock Clock) *Limiter {
	return &Limiter{max: max, window: window, clock: clock, seen: map[string]*limitWindow{}}
}

// Allow counts one call from host and reports whether it is within the limit.
func (l *Limiter) Allow(host string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.clock()
	if len(l.seen) > 10000 {
		for k, w := range l.seen {
			if now.Sub(w.start) >= l.window {
				delete(l.seen, k)
			}
		}
	}
	w := l.seen[host]
	if w == nil || now.Sub(w.start) >= l.window {
		w = &limitWindow{start: now}
		l.seen[host] = w
	}
	w.n++
	return w.n <= l.max
}

// Host returns the client address of r without the port.
func Host(r *http.Request) string {
	h, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return h
}

// MaxBody bounds one request body.
const MaxBody = 64 << 10

// WriteJSON writes v as JSON with status code.
func WriteJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

// WriteError maps an *Error to its status. Any other error is a 500 with no detail.
func WriteError(w http.ResponseWriter, err error) {
	var e *Error
	if !errors.As(err, &e) {
		WriteJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}
	code := http.StatusInternalServerError
	switch e.Kind {
	case Invalid:
		code = http.StatusBadRequest
	case Unauthorized:
		code = http.StatusUnauthorized
		w.Header().Set("WWW-Authenticate", `Bearer realm="records"`)
	case Forbidden:
		code = http.StatusForbidden
	case NotFound:
		code = http.StatusNotFound
	case Conflict:
		code = http.StatusConflict
	}
	WriteJSON(w, code, map[string]string{"error": e.Msg})
}

// Outcome names an error for the audit log from a closed set.
func Outcome(err error) string {
	switch {
	case err == nil:
		return "ok"
	case IsKind(err, Invalid):
		return "invalid"
	case IsKind(err, NotFound):
		return "not_found"
	case IsKind(err, Conflict):
		return "conflict"
	case IsKind(err, Forbidden), IsKind(err, Unauthorized):
		return "denied"
	}
	return "error"
}

// ReadJSON decodes one JSON object from the body into v. Unknown fields, trailing data and bodies over MaxBody
// are refused.
func ReadJSON(w http.ResponseWriter, r *http.Request, v any) error {
	if mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err != nil || mt != "application/json" {
		return &Error{Kind: Invalid, Msg: "Content-Type must be application/json"}
	}
	r.Body = http.MaxBytesReader(w, r.Body, MaxBody)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return &Error{Kind: Invalid, Msg: "body is not valid JSON for this route"}
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return &Error{Kind: Invalid, Msg: "body has data after the JSON object"}
	}
	return nil
}
