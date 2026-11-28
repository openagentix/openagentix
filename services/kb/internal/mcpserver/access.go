package mcpserver

import (
	"context"
	"net/http"
	"slices"
	"sync"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/openagentix/openagentix/services/kb/internal/access"
	"github.com/openagentix/openagentix/services/kb/internal/kb"
	"github.com/openagentix/openagentix/services/kb/internal/store"
)

const (
	sessionHeader = "Mcp-Session-Id"
	// noCaller is the name logged for a request without a known value.
	noCaller = "none"
	// maxBoundSessions bounds the session table. When it is full the table is cleared: every request is still decided
	// from its own header, so a cleared table loses only the extra refusal of a reused session.
	maxBoundSessions = 10000
)

// guard refuses, in enforce mode, every request without a known caller value, before any MCP handling (initialize
// included), and refuses a session that is reused by another caller or by none. In report mode and with no
// authorizer it passes everything. Whatever the mode, a tool call decides its caller again from its own header.
func guard(az *access.Authorizer, next http.Handler) http.Handler {
	if az == nil || az.Mode() != access.Enforce {
		return next
	}
	sessions := &sessionTable{m: map[string]string{}}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := az.Identify(r.Header.Get("Authorization"))
		if !id.Known {
			refuse(w)
			return
		}
		sid := r.Header.Get(sessionHeader)
		if sid != "" && !sessions.owns(sid, id.Name) {
			refuse(w)
			return
		}
		if r.Method == http.MethodDelete && sid != "" {
			defer sessions.forget(sid)
		}
		next.ServeHTTP(&sessionBinder{ResponseWriter: w, table: sessions, caller: id.Name}, r)
	})
}

// refuse answers 401 and says nothing about collections, callers or values.
func refuse(w http.ResponseWriter) {
	w.Header().Set("WWW-Authenticate", `Bearer realm="kb"`)
	http.Error(w, "unauthorized", http.StatusUnauthorized)
}

// sessionTable remembers which caller opened a session.
type sessionTable struct {
	mu sync.Mutex
	m  map[string]string
}

// owns is true when the session is unknown to the table or was opened by caller.
func (t *sessionTable) owns(sid, caller string) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	owner, ok := t.m[sid]
	return !ok || owner == caller
}

func (t *sessionTable) bind(sid, caller string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if _, ok := t.m[sid]; !ok && len(t.m) >= maxBoundSessions {
		clear(t.m)
	}
	t.m[sid] = caller
}

func (t *sessionTable) forget(sid string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.m, sid)
}

// sessionBinder records the session id the SDK assigns in a response.
type sessionBinder struct {
	http.ResponseWriter
	table  *sessionTable
	caller string
	done   bool
}

func (b *sessionBinder) capture() {
	if b.done {
		return
	}
	b.done = true
	if sid := b.Header().Get(sessionHeader); sid != "" {
		b.table.bind(sid, b.caller)
	}
}

func (b *sessionBinder) WriteHeader(code int) { b.capture(); b.ResponseWriter.WriteHeader(code) }
func (b *sessionBinder) Write(p []byte) (int, error) {
	b.capture()
	return b.ResponseWriter.Write(p)
}
func (b *sessionBinder) Flush() {
	b.capture()
	if f, ok := b.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}
func (b *sessionBinder) Unwrap() http.ResponseWriter { return b.ResponseWriter }

// callInfo is what one tool call knows about its caller.
type callInfo struct {
	// logged is true when the log line carries the caller (an authorizer is configured).
	logged  bool
	caller  string
	list    []string
	report  bool
	outside bool
}

// begin decides the caller of one tool call from that request's own Authorization header, never from the MCP
// session, and in enforce mode puts the caller's scope on the context. With no authorizer it changes nothing.
func (h *handlers) begin(ctx context.Context, req *mcp.CallToolRequest) (context.Context, *callInfo) {
	if h.access == nil {
		return ctx, &callInfo{}
	}
	var authz string
	if req != nil && req.Extra != nil {
		authz = req.Extra.Header.Get("Authorization")
	}
	id := h.access.Identify(authz)
	c := &callInfo{logged: true, caller: id.Name, list: id.Collections, report: h.access.Mode() == access.Report}
	if !id.Known {
		c.caller = noCaller
	}
	if c.report {
		c.outside = !id.Known // enforce would have refused the request
		return ctx, c
	}
	// Enforce. An unknown caller cannot get here through the guard; if it did, it reads nothing.
	return kb.WithScope(ctx, store.Scope{Limited: true, Collections: id.Collections}), c
}

// arg notes, in report mode, a named collection that enforce would have treated as missing.
func (c *callInfo) arg(collection string) {
	if c.report && collection != "" && !slices.Contains(c.list, collection) {
		c.outside = true
	}
}

// saw notes, in report mode, a collection in a result that enforce would have filtered out.
func (c *callInfo) saw(collection string) {
	if c.report && !slices.Contains(c.list, collection) {
		c.outside = true
	}
}

// logAttrs are the extra attributes of the tool call log line: the caller's group name, and in report mode whether
// enforce would have refused or filtered the call. Never a value, an argument or a result.
func (c *callInfo) logAttrs() []any {
	if c == nil || !c.logged {
		return nil
	}
	a := []any{"caller", c.caller}
	if c.report && c.outside {
		a = append(a, "outside_list", true)
	}
	return a
}
