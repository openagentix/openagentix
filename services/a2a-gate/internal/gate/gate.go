// Package gate is the A2A gate: a reverse proxy in front of the kagent controller's port 8083 that
//   - authenticates the caller (see package auth),
//   - lets through only the A2A paths for the agents the caller's rule names,
//   - removes every credential and identity header the caller sent and sets X-User-Id itself,
//   - passes SSE through with an immediate flush,
//   - writes one JSON audit line per request, never with message text.
//
// gRPC and gRPC-Web (content type application/grpc*) and every other path are refused, so the controller's
// memory, session and REST APIs are not reachable through it.
package gate

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httputil"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/openagentix/openagentix/services/a2a-gate/internal/auth"
	"github.com/openagentix/openagentix/services/a2a-gate/internal/rules"
)

// Authenticator maps a bearer token to a caller rule (implemented by auth.Authenticator).
type Authenticator interface {
	Authenticate(ctx context.Context, token string) (*rules.Caller, error)
}

// Options configure the gate.
type Options struct {
	UpstreamURL string // the controller, e.g. http://kagent-controller.kagent.svc.cluster.local:8083
	Auth        Authenticator
	Audit       *slog.Logger // one record per request, message "audit"
	AuditUserID string       // "hash" (default) or "raw"
	Salt        []byte       // for the hash; random per process by default (set in main)
	SniffBytes  int          // how much of a request body is read to find the contextId (default 64 KiB)
	MaxBody     int64        // largest request body accepted (default 8 MiB)
	// MaxInFlight caps the requests handled at once (default 128); the next one gets 503. Health probes do not count.
	MaxInFlight int
	// SniffTimeout is how long the sniffed start of a body may take to arrive (default 10 s). It is cleared before
	// the request is proxied, so a long upload or a long stream is not cut by it.
	SniffTimeout time.Duration
	Transport    http.RoundTripper
	// WorkloadHeaderTimeout is how long a container agent may take to start its answer (default 300 s), streaming
	// calls included. Once the response headers are in, the body is not timed.
	WorkloadHeaderTimeout time.Duration
	// WorkloadMaxInFlight caps the requests one container agent handles at once (default 32); the next call for
	// that agent gets 503, for every caller. All container agents together also share one pool of half of
	// MaxInFlight (at least 1), so they can never take the slots the built-in agents need.
	WorkloadMaxInFlight int
	// Now is the clock of the event callers' rate buckets (default time.Now). Tests move it.
	Now func() time.Time

	// Bring your own A2A agent (routes.go). All off while RoutesFile is empty.
	RoutesFile        string          // the controller-written list of container agents
	WorkloadNamespace string          // where those agents run (DNS label), fixed at start
	WorkloadPort      int             // default 8080
	PublicURL         string          // how clients reach the gate: used in the agent cards of container agents
	RoutesPoll        time.Duration   // how often the file is checked (default 10 s)
	Ctx               context.Context // stops the poll (default: never)
	Log               *slog.Logger    // process log: route reloads (default discard)
}

const (
	defaultSniff       = 64 << 10
	defaultMaxBody     = 8 << 20
	defaultMaxInFlight = 128
	defaultSniffWait   = 10 * time.Second
	defaultWorkHeader  = 300 * time.Second
	defaultWorkInFlite = 32
	maxAuditUserBytes  = 128
)

// request-scoped values for the proxy's Rewrite
type ctxKey int

const (
	keyUser  ctxKey = 1
	keyEvent ctxKey = 3 // an *eventCall: the request is an accepted event call (event.go)
)

type userVal struct {
	id  string
	set bool
}

type handler struct {
	o      Options
	proxy  *httputil.ReverseProxy
	slots  chan struct{}
	routes atomic.Pointer[RouteSet]

	workPool   chan struct{} // all container agents together: half of MaxInFlight
	agentMu    sync.Mutex
	agentSlots map[string]chan struct{} // per container agent, created on first use

	evMu   sync.Mutex
	events map[string]*eventState // per event caller (ADR 0027): rate bucket and open calls, in this process
}

// New builds the gate handler.
func New(o Options) (http.Handler, error) {
	up, err := url.Parse(o.UpstreamURL)
	if err != nil || (up.Scheme != "http" && up.Scheme != "https") || up.Host == "" {
		return nil, errors.New("upstream must be an http or https URL")
	}
	if o.SniffBytes <= 0 {
		o.SniffBytes = defaultSniff
	}
	if o.MaxBody <= 0 {
		o.MaxBody = defaultMaxBody
	}
	if o.MaxInFlight <= 0 {
		o.MaxInFlight = defaultMaxInFlight
	}
	if o.SniffTimeout <= 0 {
		o.SniffTimeout = defaultSniffWait
	}
	if o.WorkloadHeaderTimeout <= 0 {
		o.WorkloadHeaderTimeout = defaultWorkHeader
	}
	if o.WorkloadMaxInFlight <= 0 {
		o.WorkloadMaxInFlight = defaultWorkInFlite
	}
	if o.Transport == nil {
		o.Transport = http.DefaultTransport
	}
	if o.Audit == nil {
		o.Audit = slog.New(slog.DiscardHandler)
	}
	if o.Log == nil {
		o.Log = slog.New(slog.DiscardHandler)
	}
	h := &handler{o: o, slots: make(chan struct{}, o.MaxInFlight), workPool: make(chan struct{}, max(1, o.MaxInFlight/2))}
	if err := h.initRoutes(); err != nil {
		return nil, err
	}
	h.proxy = &httputil.ReverseProxy{
		Rewrite:        h.rewrite(up),
		FlushInterval:  -1, // SSE: write every chunk through at once
		Transport:      headerTimeoutTransport{base: o.Transport, d: o.WorkloadHeaderTimeout},
		ModifyResponse: h.modifyResponse,
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			if rec, ok := w.(*recorder); ok {
				rec.reason = "upstream"
			}
			deny(w, http.StatusBadGateway, "bad gateway")
		},
	}
	return h, nil
}

// headers that carry or forge an identity, or credentials: never forwarded
var stripHeaders = []string{
	"Authorization", "Proxy-Authorization", "Cookie", "X-User-Id", "X-Agent-Name", "X-Share-Token",
	"X-Kagent-Insecure-Runtime-Identity", "Baggage", "Forwarded", "X-Real-Ip",
}

func (h *handler) rewrite(up *url.URL) func(*httputil.ProxyRequest) {
	return func(pr *httputil.ProxyRequest) {
		if ec, ok := pr.In.Context().Value(keyEvent).(*eventCall); ok {
			// an event call: the runtime gets the gate's own headers, never the caller's
			pr.SetURL(up)
			pr.Out.Header = eventRequestHeaders(ec)
		} else if t, ok := pr.In.Context().Value(keyTarget).(*target); ok {
			// a listed agent: scheme, host and path come from the fixed template and the route, never from the request
			pr.SetURL(&url.URL{Scheme: "http", Host: t.host})
			pr.Out.URL.Path, pr.Out.URL.RawPath = t.path, ""
			// foreign code gets an allowlist of request headers, not the caller's whole set
			keep := http.Header{}
			for _, n := range workloadRequestHeaders {
				if v := pr.In.Header.Values(n); len(v) > 0 {
					keep[http.CanonicalHeaderKey(n)] = append([]string(nil), v...)
				}
			}
			pr.Out.Header = keep
		} else {
			pr.SetURL(up)
		}
		pr.Out.URL.RawQuery = "" // kagent reads ?user_id= before X-User-Id: no query reaches it
		for _, n := range stripHeaders {
			pr.Out.Header.Del(n)
		}
		for k := range pr.Out.Header {
			if strings.HasPrefix(strings.ToLower(k), "x-forwarded-") {
				delete(pr.Out.Header, k)
			}
		}
		if u, ok := pr.In.Context().Value(keyUser).(userVal); ok && u.set {
			pr.Out.Header.Set("X-User-Id", u.id)
		}
	}
}

// recorder captures the status for the audit line and keeps Flush working.
type recorder struct {
	http.ResponseWriter
	status int
	wrote  bool
	reason string
}

func (r *recorder) WriteHeader(code int) {
	if !r.wrote {
		r.status, r.wrote = code, true
	}
	r.ResponseWriter.WriteHeader(code)
}

func (r *recorder) Write(b []byte) (int, error) {
	if !r.wrote {
		r.status, r.wrote = http.StatusOK, true
	}
	return r.ResponseWriter.Write(b)
}

func (r *recorder) Flush() {
	if !r.wrote {
		r.status, r.wrote = http.StatusOK, true
	}
	_ = http.NewResponseController(r.ResponseWriter).Flush()
}

func (r *recorder) Unwrap() http.ResponseWriter { return r.ResponseWriter }

func deny(w http.ResponseWriter, code int, text string) {
	if code == http.StatusUnauthorized {
		w.Header().Set("WWW-Authenticate", `Bearer realm="a2a-gate"`)
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(code)
	_, _ = io.WriteString(w, `{"error":"`+text+`"}`+"\n")
}

// fields of the audit line, filled in as the request goes
type auditRec struct {
	caller, agent, userID, contextID, traceID, reason, rpc string
	event                                                  bool   // the caller has an event block: the line gets event_id
	eventID                                                string // the caller's messageId once the shape check passed, else "invalid"
}

func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/healthz", "/readyz":
		if r.Method == http.MethodGet || r.Method == http.MethodHead {
			w.WriteHeader(http.StatusOK)
			_, _ = io.WriteString(w, "ok\n")
			return
		}
	}
	start := time.Now()
	rec := &recorder{ResponseWriter: w}
	a := &auditRec{traceID: traceID(r.Header.Get("Traceparent"))}
	defer func() {
		st := rec.status
		if st == 0 {
			st = http.StatusOK
		}
		if rec.reason != "" && a.reason == "" {
			a.reason = rec.reason
		}
		h.writeAudit(r, a, st, time.Since(start))
	}()
	select {
	case h.slots <- struct{}{}:
		defer func() { <-h.slots }()
	default:
		a.reason = "busy"
		rec.Header().Set("Retry-After", "1")
		deny(rec, http.StatusServiceUnavailable, "service unavailable")
		return
	}
	h.serve(rec, r, a)
}

func (h *handler) serve(w *recorder, r *http.Request, a *auditRec) {
	refuse := func(code int, reason, text string) {
		a.reason = reason
		deny(w, code, text)
	}
	claimed := r.Header.Values("X-User-Id")

	// 1. who is calling
	token, ok := bearer(r)
	if !ok {
		refuse(http.StatusUnauthorized, "no_token", "unauthorized")
		return
	}
	caller, err := h.o.Auth.Authenticate(r.Context(), token)
	switch {
	case errors.Is(err, auth.ErrUnauthenticated):
		refuse(http.StatusUnauthorized, "bad_token", "unauthorized")
		return
	case errors.Is(err, auth.ErrUnknownCaller):
		refuse(http.StatusForbidden, "unknown_caller", "forbidden")
		return
	case err != nil:
		refuse(http.StatusServiceUnavailable, "auth_unavailable", "service unavailable")
		return
	}
	a.caller = caller.Name
	var evState *eventState
	var evRateOK bool
	var evRetry int
	if caller.Event != nil {
		// every authenticated request of an event caller is charged, refusals included (ADR 0027, step 4)
		a.event, a.eventID = true, "invalid"
		// An answer that is sent before the body is read would otherwise wait for the rest of it (the server discards the unread
		// body first), and the request would hold its shared slot while a slow sender stalls. The connection of an event
		// caller is closed after every answer.
		w.Header().Set("Connection", "close")
		evState = h.eventState(caller)
		evRateOK, evRetry = evState.take(h.now(), caller.Event.Rate)
	}
	if len(claimed) > 0 {
		// Recorded only now, after authentication: an unauthenticated caller cannot put a chosen string in the log.
		// Hashed by default, and cut short in any case.
		a.userID = claimed[0][:min(len(claimed[0]), maxAuditUserBytes)]
	}

	// 2a. the MemoryService (ADR 0006, round 3): List and Delete for a caller whose rule says memory: true, nothing else
	if strings.HasPrefix(r.URL.Path, memoryService) {
		h.serveMemory(w, r, a, caller, claimed)
		return
	}

	// 2. what is it asking for: only A2A paths, never gRPC or gRPC-Web
	if ct := strings.ToLower(r.Header.Get("Content-Type")); strings.HasPrefix(ct, "application/grpc") {
		refuse(http.StatusForbidden, "grpc", "forbidden")
		return
	}
	if r.Header.Get("Upgrade") != "" {
		refuse(http.StatusForbidden, "path", "forbidden")
		return
	}
	ns, name, route, okPath := a2aPath(r)
	card := route == routeCard
	if !okPath {
		refuse(http.StatusForbidden, "path", "forbidden")
		return
	}
	a.agent = ns + "/" + name
	if !caller.AllowsAgent(ns, name) {
		refuse(http.StatusForbidden, "agent", "forbidden")
		return
	}

	// 3. which user: the rule decides; the agent card needs no user
	uv := userVal{}
	if card {
		if caller.UserID.Fixed != "" || caller.UserID.Exact != "" {
			uv.id, uv.set = caller.UserID.Fixed+caller.UserID.Exact, true
		}
	} else {
		id, ok := caller.ResolveUser(claimed)
		if !ok {
			refuse(http.StatusForbidden, "user_id", "forbidden")
			return
		}
		uv = userVal{id: id, set: true}
		a.userID = id
	}

	if caller.Event != nil {
		h.serveEvent(w, r, a, caller, evState, evRateOK, evRetry, ns, name, route, uv)
		return
	}

	// 4. the body. Only its start is read (SniffBytes, within SniffTimeout), to learn the JSON-RPC method and the
	// contextId; the rest streams through untouched. On the JSON-RPC route the whole body must fit in that start:
	// the method is then checked on exactly the bytes the agent will read, duplicate keys included.
	if r.Method == http.MethodPost {
		if r.ContentLength > h.o.MaxBody {
			refuse(http.StatusRequestEntityTooLarge, "body_too_large", "request too large")
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, h.o.MaxBody)
		head, over, err := h.sniff(w, r)
		var tooBig *http.MaxBytesError
		switch {
		case errors.As(err, &tooBig):
			refuse(http.StatusRequestEntityTooLarge, "body_too_large", "request too large")
			return
		case err != nil:
			// close the connection: the server would otherwise wait for the rest of the body before it answers
			w.Header().Set("Connection", "close")
			refuse(http.StatusRequestTimeout, "body_timeout", "request timeout")
			return
		}
		method := route
		if route == routeRPC {
			m, ctxID, ok := parseJSONRPC(head)
			if over || !ok {
				a.rpc = "unknown"
				refuse(http.StatusForbidden, "method", "forbidden") // fail closed: no method, no call
				return
			}
			method, a.contextID = m, ctxID
		} else {
			a.contextID = contextIDFromText(head)
		}
		a.rpc = auditMethod(method)
		if !caller.AllowsMethod(method) {
			refuse(http.StatusForbidden, "method", "forbidden")
			return
		}
	}
	ctx := context.WithValue(r.Context(), keyUser, uv)
	if t := h.workloadTarget(ns, name, route); t != nil {
		ctx = context.WithValue(ctx, keyTarget, t)
	}
	if _, ok := ctx.Value(keyTarget).(*target); ok {
		// container agents have a pool of their own (half of the shared slots) and each has a cap inside it: one
		// slow agent answers 503 alone, and the built-in agents keep their slots
		slot := h.agentSlot(ns, name)
		select {
		case h.workPool <- struct{}{}:
			defer func() { <-h.workPool }()
		default:
			a.reason = "workload_busy"
			w.Header().Set("Retry-After", "1")
			deny(w, http.StatusServiceUnavailable, "service unavailable")
			return
		}
		select {
		case slot <- struct{}{}:
			defer func() { <-slot }()
		default:
			a.reason = "agent_busy"
			w.Header().Set("Retry-After", "1")
			deny(w, http.StatusServiceUnavailable, "service unavailable")
			return
		}
	}
	h.proxy.ServeHTTP(w, r.WithContext(ctx))
}

func (h *handler) agentSlot(ns, name string) chan struct{} {
	h.agentMu.Lock()
	defer h.agentMu.Unlock()
	if h.agentSlots == nil {
		h.agentSlots = map[string]chan struct{}{}
	}
	k := ns + "/" + name
	c, ok := h.agentSlots[k]
	if !ok {
		c = make(chan struct{}, h.o.WorkloadMaxInFlight)
		h.agentSlots[k] = c
	}
	return c
}

// request headers a container agent may receive. Credentials, cookies, forwarding and browser headers never do. X-User-Id
// is set by the gate itself after this list is applied.
var workloadRequestHeaders = []string{"Content-Type", "Accept", "A2A-Version", "A2A-Extensions", "Traceparent", "Tracestate"}

// headerTimeoutTransport ends a request to a container agent that has not started its response in time. Once the
// response headers are in, the timer is gone: a slow body is not cut. Built-in agents are not timed here.
type headerTimeoutTransport struct {
	base http.RoundTripper
	d    time.Duration
}

func (t headerTimeoutTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	tg, _ := r.Context().Value(keyTarget).(*target)
	if tg == nil {
		return t.base.RoundTrip(r)
	}
	ctx, cancel := context.WithCancel(r.Context())
	timer := time.AfterFunc(t.d, cancel)
	resp, err := t.base.RoundTrip(r.WithContext(ctx))
	if !timer.Stop() && err == nil {
		// the timer fired just as the headers came: the body would be cut, so treat it as a timeout
		_ = resp.Body.Close()
		cancel()
		return nil, context.DeadlineExceeded
	}
	if err != nil {
		cancel()
		return nil, err
	}
	resp.Body = cancelOnClose{resp.Body, cancel}
	return resp, nil
}

type cancelOnClose struct {
	io.ReadCloser
	cancel context.CancelFunc
}

func (c cancelOnClose) Close() error { err := c.ReadCloser.Close(); c.cancel(); return err }

func bearer(r *http.Request) (string, bool) {
	v := r.Header.Values("Authorization")
	if len(v) != 1 {
		return "", false
	}
	scheme, tok, found := strings.Cut(v[0], " ")
	tok = strings.TrimSpace(tok)
	if !found || !strings.EqualFold(scheme, "Bearer") || tok == "" {
		return "", false
	}
	return tok, true
}

var k8sName = regexp.MustCompile(`^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$`)

// Routes of a2aPath. The REST routes name their method in the path; the JSON-RPC route carries it in the body.
const (
	routeCard = "card"
	routeRPC  = "rpc"
)

// a2aPath accepts the A2A routes of one agent and nothing else:
//
//	POST /agents/<ns>/<name>                (JSON-RPC; a trailing slash is fine)
//	POST /agents/<ns>/<name>/[v1/]message:send|message:stream   (method SendMessage | SendStreamingMessage)
//	GET  /agents/<ns>/<name>/.well-known/agent-card.json|agent.json
func a2aPath(r *http.Request) (ns, name, route string, ok bool) {
	p := r.URL.EscapedPath()
	if p != r.URL.Path || strings.Contains(p, "//") || strings.Contains(p, "%") || strings.Contains(p, "\\") {
		return
	}
	seg := strings.Split(strings.TrimPrefix(p, "/"), "/")
	if len(seg) < 3 || seg[0] != "agents" || !k8sName.MatchString(seg[1]) || !k8sName.MatchString(seg[2]) {
		return
	}
	rest := strings.Join(seg[3:], "/")
	switch r.Method {
	case http.MethodPost:
		switch rest {
		case "":
			return seg[1], seg[2], routeRPC, true
		case "message:send", "v1/message:send":
			return seg[1], seg[2], "SendMessage", true
		case "message:stream", "v1/message:stream":
			return seg[1], seg[2], "SendStreamingMessage", true
		}
	case http.MethodGet:
		switch rest {
		case ".well-known/agent-card.json", ".well-known/agent.json":
			return seg[1], seg[2], routeCard, true
		}
	}
	return
}

var contextIDRe = regexp.MustCompile(`"contextId"\s*:\s*"([^"\\]{0,1000})"`)
var contextIDOK = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)

// sniffSize is how many bytes of a body the gate keeps for a request with this Content-Length (-1: unknown).
func sniffSize(contentLength int64, window int) int {
	if contentLength >= 0 && contentLength < int64(window) {
		return int(contentLength)
	}
	return window
}

// sniff reads the start of the body (at most SniffBytes, and only as many bytes as Content-Length announces) within
// SniffTimeout, then puts the bytes back in front of the rest. over is true when the body is longer than the window.
// The read deadline is cleared before sniff returns. Only ids ever leave this function, never text.
func (h *handler) sniff(w http.ResponseWriter, r *http.Request) (head []byte, over bool, err error) {
	rc := http.NewResponseController(w)
	_ = rc.SetReadDeadline(time.Now().Add(h.o.SniffTimeout))
	defer func() { _ = rc.SetReadDeadline(time.Time{}) }()
	n := sniffSize(r.ContentLength, h.o.SniffBytes)
	var buf bytes.Buffer
	buf.Grow(n + 1)
	_, err = io.CopyN(&buf, r.Body, int64(n)+1) // one byte more than the window tells whether there is more
	if errors.Is(err, io.EOF) {
		err = nil
	}
	head = buf.Bytes()
	over = len(head) > n
	if over {
		head = head[:n]
	}
	if err != nil {
		return nil, false, err
	}
	orig := r.Body
	r.Body = struct {
		io.Reader
		io.Closer
	}{io.MultiReader(bytes.NewReader(buf.Bytes()), orig), orig}
	return head, over, nil
}

var methodNameOK = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_./:-]{0,63}$`)

// auditMethod is the method name for the audit line: the name when it looks like one, else "invalid".
func auditMethod(m string) string {
	if methodNameOK.MatchString(m) {
		return m
	}
	return "invalid"
}

// parseJSONRPC reads a complete JSON-RPC request body. ok is false when the body is not exactly one JSON object with
// exactly one string "method" member. Member names are compared the way Go's decoder (which the agent side uses)
// does, ignoring case, so {"method":..,"Method":..} is refused instead of read two ways. contextID is
// params.message.contextId, "" when absent and "invalid" when it is not a plain id.
func parseJSONRPC(b []byte) (method, contextID string, ok bool) {
	dec := json.NewDecoder(bytes.NewReader(b))
	if t, err := dec.Token(); err != nil || t != json.Delim('{') {
		return "", "", false
	}
	found := 0
	for dec.More() {
		kt, err := dec.Token()
		key, isStr := kt.(string)
		if err != nil || !isStr {
			return "", "", false
		}
		if strings.EqualFold(key, "method") {
			vt, err := dec.Token()
			v, isStr := vt.(string)
			if err != nil || !isStr || v == "" {
				return "", "", false
			}
			found++
			method = v
			continue
		}
		if !skipValue(dec) {
			return "", "", false
		}
	}
	if t, err := dec.Token(); err != nil || t != json.Delim('}') {
		return "", "", false
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) { // nothing may follow the object
		return "", "", false
	}
	if found != 1 {
		return "", "", false
	}
	var in struct {
		Params struct {
			Message struct {
				ContextID string `json:"contextId"`
			} `json:"message"`
		} `json:"params"`
	}
	_ = json.Unmarshal(b, &in) // a wrong type just leaves the id empty: the id is for the log only
	return method, checkContextID(in.Params.Message.ContextID), true
}

// skipValue reads one JSON value, whatever its depth.
func skipValue(dec *json.Decoder) bool {
	t, err := dec.Token()
	if err != nil {
		return false
	}
	d, isDelim := t.(json.Delim)
	if !isDelim || d == '}' || d == ']' {
		return !isDelim
	}
	depth := 1
	for depth > 0 {
		t, err := dec.Token()
		if err != nil {
			return false
		}
		if d, ok := t.(json.Delim); ok {
			if d == '{' || d == '[' {
				depth++
			} else {
				depth--
			}
		}
	}
	return true
}

func checkContextID(id string) string {
	switch {
	case id == "":
		return ""
	case contextIDOK.MatchString(id):
		return id
	}
	return "invalid"
}

// contextIDFromText finds the contextId in the start of a body that is not JSON-RPC (the REST routes), where it may be
// cut off: the first "contextId" member, if it is a plain id.
func contextIDFromText(buf []byte) string {
	m := contextIDRe.FindSubmatch(buf)
	if m == nil {
		return ""
	}
	return checkContextID(string(m[1]))
}

func traceID(tp string) string {
	p := strings.Split(strings.TrimSpace(tp), "-")
	if len(p) != 4 || len(p[1]) != 32 || p[1] == strings.Repeat("0", 32) {
		return ""
	}
	for _, c := range p[1] {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return ""
		}
	}
	return p[1]
}

func (h *handler) hashUser(id string) string {
	if id == "" {
		return ""
	}
	if h.o.AuditUserID == "raw" {
		return id
	}
	s := sha256.Sum256(append(append([]byte{}, h.o.Salt...), id...))
	return "h:" + hex.EncodeToString(s[:])[:8]
}

func (h *handler) writeAudit(r *http.Request, a *auditRec, status int, d time.Duration) {
	attrs := []any{
		"caller", a.caller, "agent", a.agent, "user_id", h.hashUser(a.userID), "context_id", a.contextID,
		"trace_id", a.traceID, "status", status, "duration_ms", d.Milliseconds(), "method", r.Method,
	}
	if a.rpc != "" {
		attrs = append(attrs, "rpc", a.rpc) // the JSON-RPC (A2A) method, e.g. SendMessage
	}
	if a.reason != "" {
		attrs = append(attrs, "reason", a.reason)
	}
	if a.event {
		attrs = append(attrs, "event_id", a.eventID) // the sender's messageId, never the text
	}
	h.o.Audit.Info("audit", attrs...)
}
