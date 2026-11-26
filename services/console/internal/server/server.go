// Package server is the console API: a fixed list of routes, each written out here. There is no proxy to the Kubernetes
// API or to any other service. The browser's Authorization header is read by the Authenticator and goes nowhere else;
// the Kubernetes client builds its own requests (package kube), so no browser header can be forwarded.
package server

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"mime"
	"net/http"
	"net/url"
	"path"
	"strconv"
	"strings"
	"time"

	"github.com/openagentix/openagentix/services/console/ext"
	"github.com/openagentix/openagentix/services/console/internal/backend"
	"github.com/openagentix/openagentix/services/console/internal/govern"
	"github.com/openagentix/openagentix/services/console/internal/model"
	"github.com/openagentix/openagentix/services/console/internal/observe"
	"github.com/openagentix/openagentix/services/console/internal/platform"
	"github.com/openagentix/openagentix/services/console/internal/predict"
)

// Limits that protect the console itself.
const (
	MaxBody        = 256 << 10
	MaxHeaderBytes = 16 << 10
)

// CSP is sent with every response. Nothing in the web app needs an inline script or style, an outside host or a frame.
const CSP = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; " +
	"object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"

// Routes is the whole list, in the order the README documents. The test compares it with what is registered.
var Routes = []string{
	"GET /healthz",
	"GET /api/v1/session",
	"GET /api/v1/platform",
	"GET /api/v1/agents",
	"GET /api/v1/metrics/summary",
	"GET /api/v1/schedules",
	"GET /api/v1/access",
	"GET /api/v1/traces",
	"GET /api/v1/traces/{traceId}",
	"POST /api/v1/agents",
	"POST /api/v1/agents/validate",
	"GET /api/v1/agents/{name}",
	"PUT /api/v1/agents/{name}",
	"DELETE /api/v1/agents/{name}",
	"/", // every other path and method: the web app for GET and HEAD, a JSON 404 or 405 otherwise
}

// consoleReserved are names the web app uses as routes (/agents/new, /agents/playground).
var consoleReserved = []string{"new", "playground"}

// Options is everything the server needs. Authenticator, Authorizer and AuditSink are the extension points of ADR 0010.
type Options struct {
	Backend        backend.Backend
	Platform       platform.Source
	Authenticator  ext.Authenticator
	Authorizer     ext.Authorizer
	Audit          ext.AuditSink
	Static         fs.FS // the built web app, rooted at its index.html; nil: no web app
	Log            *slog.Logger
	Demo           bool
	Namespace      string
	Context        string
	Version        string
	RequestTimeout time.Duration
	// Observe reads metrics; nil: not configured (GET /api/v1/metrics/summary answers 503 and /platform says so).
	Observe observe.Observability
	// Schedules and Access read the chart's schedules and the gate's caller rules; nil: not configured (the routes answer
	// an empty list with configured: false).
	Schedules govern.ScheduleSource
	Access    govern.AccessSource

	// AllowedHosts are host names (optionally with a port) accepted in the Host header besides localhost, 127.0.0.1 and
	// [::1]; a future Ingress name goes here. Any other Host is answered 421 before routing.
	AllowedHosts []string
	// AuthFailLimit is how many failed authentications one remote address may make per ThrottleWindow before it is
	// answered 429 for a growing back-off. 0: 10. Negative: no throttle (tests).
	AuthFailLimit int
	// AuthFailLimitGlobal is the same cap over all addresses together. 0: 10 times AuthFailLimit.
	AuthFailLimitGlobal int
	ThrottleWindow      time.Duration // 0: one minute
	// ValidatePerMinute caps POST /agents/validate per identity. 0: 60. Negative: no cap.
	ValidatePerMinute int
	// HSTS adds Strict-Transport-Security to every response. Turn it on when the console is served behind TLS.
	HSTS bool
	Now  func() time.Time // the clock of the throttles; nil: time.Now
}

// Server is the http.Handler.
type Server struct {
	o        Options
	mux      *http.ServeMux
	reg      []string
	hosts    *hostList
	throttle *throttle
	vrate    *rateLimiter
}

// New builds the handler.
func New(o Options) *Server {
	if o.RequestTimeout <= 0 {
		o.RequestTimeout = 15 * time.Second
	}
	if o.Log == nil {
		o.Log = slog.New(slog.NewJSONHandler(io.Discard, nil))
	}
	s := &Server{o: o, mux: http.NewServeMux(), hosts: newHostList(o.AllowedHosts)}
	s.throttle = newThrottle(o.AuthFailLimit, o.AuthFailLimitGlobal, o.ThrottleWindow, o.Now)
	if o.ValidatePerMinute == 0 {
		o.ValidatePerMinute = 60
	}
	s.vrate = newRateLimiter(o.ValidatePerMinute, time.Minute, o.Now)
	s.handle("GET /healthz", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, map[string]string{"status": "ok"}) })
	s.handle("GET /api/v1/session", s.api(ext.ActionRead, s.session))
	s.handle("GET /api/v1/platform", s.api(ext.ActionRead, s.platform))
	s.handle("GET /api/v1/agents", s.api(ext.ActionRead, s.list))
	s.handle("GET /api/v1/metrics/summary", s.api(ext.ActionRead, s.metricsSummary))
	s.handle("GET /api/v1/schedules", s.api(ext.ActionRead, s.schedules))
	s.handle("GET /api/v1/access", s.api(ext.ActionRead, s.access))
	s.handle("GET /api/v1/traces", s.api(ext.ActionRead, s.traces))
	s.handle("GET /api/v1/traces/{traceId}", s.api(ext.ActionRead, s.traceOne))
	s.handle("POST /api/v1/agents", s.api(ext.ActionCreate, s.create))
	s.handle("POST /api/v1/agents/validate", s.api(ext.ActionValidate, s.validate))
	s.handle("GET /api/v1/agents/{name}", s.api(ext.ActionRead, s.get))
	s.handle("PUT /api/v1/agents/{name}", s.api(ext.ActionUpdate, s.update))
	s.handle("DELETE /api/v1/agents/{name}", s.api(ext.ActionDelete, s.remove))
	s.handle("/", s.fallback)
	return s
}

// Registered returns the patterns in the mux, for the route table test.
func (s *Server) Registered() []string { return append([]string(nil), s.reg...) }

func (s *Server) handle(pattern string, h http.HandlerFunc) {
	s.reg = append(s.reg, pattern)
	s.mux.HandleFunc(pattern, h)
}

// ServeHTTP adds the headers every response carries and a request id, then routes.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("Content-Security-Policy", CSP)
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("Cross-Origin-Opener-Policy", "same-origin")
	h.Set("Cross-Origin-Resource-Policy", "same-origin")
	if s.o.HSTS {
		h.Set("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
	}
	h.Set("X-Frame-Options", "DENY")
	h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
	if strings.HasPrefix(r.URL.Path, "/api/") || r.URL.Path == "/healthz" {
		h.Set("Cache-Control", "no-store")
	}
	id := make([]byte, 8)
	_, _ = rand.Read(id)
	rid := hex.EncodeToString(id)
	h.Set("X-Request-Id", rid)
	// Before routing, before the token: a Host that is not on the list is answered with a bare 421 (nothing to learn from
	// it), and an Origin, on any method, must be the allowed host the request itself used.
	if !s.hosts.allows(r.Host) {
		w.WriteHeader(http.StatusMisdirectedRequest)
		return
	}
	for _, o := range r.Header.Values("Origin") {
		if !s.hosts.originOK(o, r.Host) {
			writeErr(w, http.StatusForbidden, "cross_origin", "This request came from another origin. The console answers only its own pages.")
			return
		}
	}
	switch r.Method {
	case http.MethodGet, http.MethodHead, http.MethodPost, http.MethodPut, http.MethodDelete:
	default:
		h.Set("Allow", "GET, HEAD, POST, PUT, DELETE")
		writeErr(w, http.StatusMethodNotAllowed, "method_not_allowed", "The console API answers GET, HEAD, POST, PUT and DELETE only.")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), s.o.RequestTimeout)
	defer cancel()
	r = r.WithContext(context.WithValue(ctx, ridKey{}, rid))
	sw := &statusWriter{ResponseWriter: w}
	s.mux.ServeHTTP(sw, r)
	s.o.Log.LogAttrs(r.Context(), slog.LevelDebug, "request", slog.String("method", r.Method), slog.String("path", r.URL.Path),
		slog.Int("status", sw.code), slog.String("request_id", rid))
}

type ridKey struct{}

type statusWriter struct {
	http.ResponseWriter
	code int
}

func (w *statusWriter) WriteHeader(c int) {
	if w.code == 0 {
		w.code = c
	}
	w.ResponseWriter.WriteHeader(c)
}
func (w *statusWriter) Write(b []byte) (int, error) {
	if w.code == 0 {
		w.code = 200
	}
	return w.ResponseWriter.Write(b)
}

// --- JSON helpers ---

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

type errBody struct {
	Error struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

func writeErr(w http.ResponseWriter, status int, code, msg string) {
	var b errBody
	b.Error.Code, b.Error.Message = code, msg
	writeJSON(w, status, b)
}

// backendErr answers with the backend's own sentence. An error the console could not classify (code cluster_error) gets
// one generic sentence plus the request id, and the detail goes to the log under that id: upstream text never reaches
// the browser.
func (s *Server) backendErr(w http.ResponseWriter, r *http.Request, err error) {
	var be *backend.Error
	rid, _ := r.Context().Value(ridKey{}).(string)
	switch {
	case errors.As(err, &be):
		msg := be.Message
		if be.Code == "cluster_error" {
			msg += " Request id: " + rid + "."
			s.o.Log.Error("backend", "request_id", rid, "detail", be.Detail)
		}
		writeErr(w, be.Status, be.Code, msg)
	case errors.Is(err, context.DeadlineExceeded):
		writeErr(w, http.StatusGatewayTimeout, "timeout", "The console did not get an answer in time. Try again.")
	case errors.Is(err, context.Canceled):
		writeErr(w, 499, "canceled", "The request was canceled.")
	default:
		s.o.Log.Error("backend", "request_id", rid, "err", err)
		writeErr(w, http.StatusInternalServerError, "internal", "The console failed to handle this request. Check the console log for the request id "+rid+".")
	}
}

// decode reads the JSON body: the right content type, at most MaxBody bytes, no unknown field, nothing after the value.
func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mt != "application/json" {
		writeErr(w, http.StatusUnsupportedMediaType, "unsupported_media_type", "Send the body as application/json.")
		return false
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, MaxBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			writeErr(w, http.StatusRequestEntityTooLarge, "too_large", "The request body is larger than 256 KiB.")
		} else {
			writeErr(w, http.StatusBadRequest, "bad_request", "The request body is not valid JSON for this route: "+err.Error()+".")
		}
		return false
	}
	if _, err := dec.Token(); err != io.EOF {
		writeErr(w, http.StatusBadRequest, "bad_request", "The request body has data after the JSON value.")
		return false
	}
	return true
}

// sameOrigin is the cross-site check for routes that change something. A request from a script of another site carries
// Sec-Fetch-Site: cross-site (or same-site) and an Origin that is not this host. A request with neither header (curl)
// is not a browser, and still needs the bearer token.
func sameOrigin(r *http.Request) bool {
	if sf := r.Header.Get("Sec-Fetch-Site"); sf != "" && sf != "same-origin" && sf != "none" {
		return false
	}
	if o := r.Header.Get("Origin"); o != "" {
		u, err := url.Parse(o)
		if err != nil || u.Host == "" || u.Host != r.Host {
			return false
		}
	}
	return true
}

type call struct {
	ID  ext.Identity
	RID string
	// Name is what the audit line names. A handler whose name comes from the body (create) sets it.
	Name   string
	action ext.Action
}

// api wraps a handler of the API: throttle, authentication, authorisation, and the audit line of a write.
func (s *Server) api(action ext.Action, h func(http.ResponseWriter, *http.Request, *call)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		rid, _ := r.Context().Value(ridKey{}).(string)
		if r.Method != http.MethodGet && r.Method != http.MethodHead && !sameOrigin(r) {
			writeErr(w, http.StatusForbidden, "cross_origin", "This request came from another origin. The console accepts changes only from its own pages.")
			return
		}
		addr := remoteAddr(r)
		if wait := s.throttle.wait(addr); wait > 0 {
			tooMany(w, "too_many_attempts", "Too many failed sign-in attempts. Wait before you try again.", wait)
			return
		}
		id, err := s.o.Authenticator.Authenticate(r)
		if err != nil {
			s.throttle.fail(addr)
			w.Header().Set("WWW-Authenticate", `Bearer realm="openagentix-console"`)
			writeErr(w, http.StatusUnauthorized, "unauthenticated", "Sign in with the console token.")
			return
		}
		res := ext.Resource{Kind: "agentdefinition", Name: r.PathValue("name")}
		sw := &statusWriter{ResponseWriter: w}
		c := &call{ID: id, RID: rid, Name: res.Name, action: action}
		audit := func(outcome string) {
			if !action.Writes() || s.o.Audit == nil {
				return
			}
			res.Name = c.Name
			if len(res.Name) > 64 {
				res.Name = res.Name[:64]
			}
			s.record(r.Context(), rid, ext.AuditEvent{Time: time.Now().UTC(), Subject: id.Subject, Action: action, Resource: res, Outcome: outcome, Status: sw.code, RequestID: rid})
		}
		if d := s.o.Authorizer.Authorize(r.Context(), id, action, res); !d.Allowed {
			writeErr(sw, http.StatusForbidden, "forbidden", d.Reason)
			audit("denied")
			return
		}
		if action == ext.ActionValidate {
			if ok, wait := s.vrate.allow(id.Subject); !ok {
				tooMany(sw, "rate_limited", "Too many checks in a minute. Wait a moment, then try again.", wait)
				return
			}
		}
		h(sw, r, c)
		audit(outcomeOf(sw.code))
	}
}

func tooMany(w http.ResponseWriter, code, msg string, wait time.Duration) {
	w.Header().Set("Retry-After", strconv.Itoa(int(wait/time.Second)+b2i(wait%time.Second > 0)))
	writeErr(w, http.StatusTooManyRequests, code, msg)
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

// record writes the audit line. It is best effort and never changes the response: a panic or an error of the sink is
// logged with the request id and nothing else happens.
func (s *Server) record(ctx context.Context, rid string, e ext.AuditEvent) {
	defer func() {
		if p := recover(); p != nil {
			s.o.Log.Error("audit sink panicked", "request_id", rid, "panic", fmt.Sprint(p))
		}
	}()
	if err := s.o.Audit.Record(ctx, e); err != nil {
		s.o.Log.Error("audit sink failed", "request_id", rid, "err", err.Error())
	}
}

// authorizeSpec is the second authorization of a create or an update: now the name and a summary of the spec are known.
func (s *Server) authorizeSpec(w http.ResponseWriter, r *http.Request, c *call, name string, sum *ext.SpecSummary) bool {
	d := s.o.Authorizer.Authorize(r.Context(), c.ID, c.action, ext.Resource{Kind: "agentdefinition", Name: name, Spec: sum})
	if !d.Allowed {
		writeErr(w, http.StatusForbidden, "forbidden", d.Reason)
		return false
	}
	return true
}

// preWrite gives a sink that implements ext.PreWriter the chance to refuse the write. It fails closed: an error that is
// not ext.ErrRefused, or a panic, is 503 and the cluster is not touched.
func (s *Server) preWrite(w http.ResponseWriter, r *http.Request, c *call) (ok bool) {
	pw, is := s.o.Audit.(ext.PreWriter)
	if !is || s.o.Audit == nil {
		return true
	}
	name := c.Name
	if len(name) > 64 {
		name = name[:64]
	}
	var err error
	func() {
		defer func() {
			if p := recover(); p != nil {
				err = fmt.Errorf("panic: %v", p)
			}
		}()
		err = pw.PreWrite(r.Context(), ext.AuditEvent{Time: time.Now().UTC(), Subject: c.ID.Subject, Action: c.action,
			Resource: ext.Resource{Kind: "agentdefinition", Name: name}, Outcome: "pending", RequestID: c.RID})
	}()
	switch {
	case err == nil:
		return true
	case errors.Is(err, ext.ErrRefused):
		s.o.Log.Warn("write refused by the audit sink", "request_id", c.RID)
		writeErr(w, http.StatusForbidden, "forbidden", "This change was refused by the console's audit policy.")
	default:
		s.o.Log.Error("audit sink unavailable before a write", "request_id", c.RID, "err", err.Error())
		writeErr(w, http.StatusServiceUnavailable, "audit_unavailable", "The console cannot record this change right now, so it did not make it. Try again later.")
	}
	return false
}

func outcomeOf(code int) string {
	switch {
	case code >= 200 && code < 300:
		return "ok"
	case code == http.StatusConflict:
		return "conflict"
	case code == http.StatusNotFound:
		return "not_found"
	case code == http.StatusBadRequest || code == http.StatusUnprocessableEntity || code == http.StatusRequestEntityTooLarge || code == http.StatusUnsupportedMediaType:
		return "invalid"
	case code == http.StatusForbidden:
		return "denied"
	}
	return "error"
}

// --- handlers ---

type sessionBody struct {
	Subject  string `json:"subject"`
	Role     string `json:"role"`
	CanWrite bool   `json:"canWrite"`
	// Capabilities is what the Authorizer allows for a bare resource, per action; canWrite is true only when create,
	// update and delete are all allowed.
	Capabilities map[string]bool `json:"capabilities"`
	Demo         bool            `json:"demo"`
	Version      string          `json:"version"`
	Edition      string          `json:"edition"`
	Namespace    string          `json:"namespace"`
	Context      string          `json:"context"`
}

func (s *Server) session(w http.ResponseWriter, r *http.Request, c *call) {
	res := ext.Resource{Kind: "agentdefinition"}
	caps := map[string]bool{}
	for _, a := range []ext.Action{ext.ActionCreate, ext.ActionUpdate, ext.ActionDelete, ext.ActionValidate} {
		caps[string(a)] = s.o.Authorizer.Authorize(r.Context(), c.ID, a, res).Allowed
	}
	// canWrite is what the UI shows its write controls for: it must not promise more than the Authorizer would allow.
	can := caps["create"] && caps["update"] && caps["delete"]
	role := "viewer"
	if can {
		role = "operator"
	}
	demo := s.o.Demo
	if b, err := s.o.Platform.Get(); err == nil && b.Catalog.Demo {
		demo = true
	}
	writeJSON(w, 200, sessionBody{Subject: c.ID.Subject, Role: role, CanWrite: can, Capabilities: caps, Demo: demo, Version: s.o.Version, Edition: "community",
		Namespace: s.o.Namespace, Context: s.o.Context})
}

func (s *Server) both(w http.ResponseWriter) (platform.Both, bool) {
	b, err := s.o.Platform.Get()
	if err != nil {
		s.o.Log.Error("platform files", "err", err)
		writeErr(w, http.StatusServiceUnavailable, "platform_unavailable",
			"Could not read the platform catalog and policy: the console cannot open its mounted files. Check that controlPlane.enabled is true and that the console mounts the control-plane ConfigMaps.")
		return b, false
	}
	return b, true
}

func (s *Server) platform(w http.ResponseWriter, r *http.Request, _ *call) {
	b, ok := s.both(w)
	if !ok {
		return
	}
	var caps observe.Caps
	if s.o.Observe != nil {
		caps = s.o.Observe.Has()
	}
	type metricsInfo struct {
		Available bool `json:"available"`
	}
	writeJSON(w, 200, struct {
		platform.Summary
		Metrics metricsInfo `json:"metrics"`
		Traces  metricsInfo `json:"traces"`
	}{Summary: platform.Summarize(b, s.o.Demo), Metrics: metricsInfo{Available: caps.Metrics}, Traces: metricsInfo{Available: caps.Traces}})
}

func (s *Server) list(w http.ResponseWriter, r *http.Request, _ *call) {
	l, err := s.o.Backend.List(r.Context())
	if err != nil {
		s.backendErr(w, r, err)
		return
	}
	writeJSON(w, 200, l)
}

// pathName returns the {name} of the route when it has the shape of a definition name. Anything else (a path climbing up,
// an encoded slash) is a 404 here and never becomes part of a Kubernetes API path.
func pathName(w http.ResponseWriter, r *http.Request) (string, bool) {
	n := r.PathValue("name")
	if len(n) > model.MaxName || !model.NameRE.MatchString(n) {
		writeErr(w, http.StatusNotFound, "not_found", "There is no agent with that name.")
		return "", false
	}
	return n, true
}

func (s *Server) get(w http.ResponseWriter, r *http.Request, _ *call) {
	name, ok := pathName(w, r)
	if !ok {
		return
	}
	d, err := s.o.Backend.Get(r.Context(), name)
	if err != nil {
		s.backendErr(w, r, err)
		return
	}
	writeJSON(w, 200, d)
}

func nameProblem(name string) string {
	switch {
	case name == "":
		return "name is required"
	case len(name) > model.MaxName:
		return "name must be at most 40 characters"
	case !model.NameRE.MatchString(name):
		return "name must be a DNS label: lower case letters, digits and dashes, starting with a letter"
	}
	for _, n := range consoleReserved {
		if name == n {
			return "name \"" + name + "\" is used by a page of the console; pick another"
		}
	}
	return ""
}

func (s *Server) create(w http.ResponseWriter, r *http.Request, c *call) {
	var req model.WriteRequest
	if !decode(w, r, &req) {
		return
	}
	c.Name = req.Name
	if p := nameProblem(req.Name); p != "" {
		writeErr(w, http.StatusUnprocessableEntity, "invalid", "The name is not valid: "+p+".")
		return
	}
	if !s.authorizeSpec(w, r, c, req.Name, summary(req.Spec, "", "")) {
		return
	}
	// A container agent is created only when the checks of the validate route pass: it runs a user's image, so the console
	// does not hand the cluster a definition it already knows the platform refuses. The controller still decides.
	if predict.IsContainer(req.Spec) || req.Spec.Runtime != nil {
		b, ok := s.both(w)
		if !ok {
			return
		}
		if ps := s.predictions(r.Context(), req.Name, req.Spec, b); len(ps) > 0 {
			msgs := make([]string, len(ps))
			for i, p := range ps {
				msgs[i] = p.Message
			}
			writeErr(w, http.StatusUnprocessableEntity, "invalid", "The platform would refuse this agent, so it was not created: "+strings.Join(msgs, "; ")+".")
			return
		}
	}
	if !s.preWrite(w, r, c) {
		return
	}
	d, err := s.o.Backend.Create(r.Context(), req.Name, req.Spec)
	if err != nil {
		s.backendErr(w, r, err)
		return
	}
	w.Header().Set("Location", "/api/v1/agents/"+url.PathEscape(req.Name))
	writeJSON(w, http.StatusCreated, d)
}

func summary(sp model.Spec, team, project string) *ext.SpecSummary {
	return &ext.SpecSummary{Model: sp.Model, ToolProfile: sp.ToolProfile, Team: team, Project: project}
}

func (s *Server) update(w http.ResponseWriter, r *http.Request, c *call) {
	var req model.WriteRequest
	if !decode(w, r, &req) {
		return
	}
	name, ok := pathName(w, r)
	if !ok {
		return
	}
	if req.Name != "" && req.Name != name {
		writeErr(w, http.StatusUnprocessableEntity, "invalid", "Names cannot change; create a new agent instead.")
		return
	}
	c.Name = name
	// the stored labels are part of the summary: read them (a missing object is answered by the update itself)
	var team, project string
	if cur, err := s.o.Backend.Get(r.Context(), name); err == nil {
		team, project = cur.Team, cur.Project
	}
	if !s.authorizeSpec(w, r, c, name, summary(req.Spec, team, project)) || !s.preWrite(w, r, c) {
		return
	}
	d, err := s.o.Backend.Update(r.Context(), name, req.ResourceVersion, req.Spec)
	if err != nil {
		s.backendErr(w, r, err)
		return
	}
	writeJSON(w, 200, d)
}

func (s *Server) remove(w http.ResponseWriter, r *http.Request, c *call) {
	name, ok := pathName(w, r)
	if !ok {
		return
	}
	if !s.preWrite(w, r, c) {
		return
	}
	if err := s.o.Backend.Delete(r.Context(), name); err != nil {
		s.backendErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]any{"name": name, "deleting": true})
}

func (s *Server) validate(w http.ResponseWriter, r *http.Request, c *call) {
	var req model.WriteRequest
	if !decode(w, r, &req) {
		return
	}
	b, ok := s.both(w)
	if !ok {
		return
	}
	res := model.ValidateResult{Predicted: []model.Prediction{}, Prediction: true, Note: model.PredictionNote}
	// A dry run is a write request to the API server. An identity that may not write gets the predictions only.
	canWrite := s.o.Authorizer.Authorize(r.Context(), c.ID, ext.ActionCreate, ext.Resource{Kind: "agentdefinition"}).Allowed &&
		s.o.Authorizer.Authorize(r.Context(), c.ID, ext.ActionUpdate, ext.Resource{Kind: "agentdefinition"}).Allowed
	if !canWrite {
		res.Schema = model.SchemaResult{OK: true, Skipped: true, Errors: []string{}}
	} else if req.Name == "" {
		res.Schema = model.SchemaResult{OK: true, Skipped: true, Errors: []string{}}
	} else if p := nameProblem(req.Name); p != "" {
		res.Schema = model.SchemaResult{Errors: []string{p}}
	} else {
		sr, err := s.o.Backend.Schema(r.Context(), req.Name, req.Spec)
		if err != nil {
			s.backendErr(w, r, err)
			return
		}
		res.Schema = sr
	}
	res.Predicted = append(res.Predicted, s.predictions(r.Context(), req.Name, req.Spec, b)...)
	writeJSON(w, 200, res)
}

// predictions runs the console's rules over a definition, with the counts of the other definitions that the limits need.
func (s *Server) predictions(ctx context.Context, name string, spec model.Spec, b platform.Both) []model.Prediction {
	others, otherContainers := 0, 0
	if l, err := s.o.Backend.List(ctx); err == nil {
		others = l.Used
		for _, a := range l.Items {
			if a.Source != "built" || a.Name == name {
				if a.Source == "built" {
					others--
				}
				continue
			}
			if a.RuntimeType == "container" {
				otherContainers++
			}
		}
	}
	return predict.Check(predict.Input{Name: name, Spec: spec, Others: others, OthersContainer: otherContainers, P: b})
}

// --- static files ---

// fallback serves the web app: a file when there is one, index.html for a path the single-page app routes itself, and a
// JSON 404 or 405 for anything under /api/.
func (s *Server) fallback(w http.ResponseWriter, r *http.Request) {
	p := r.URL.Path
	if strings.HasPrefix(p, "/api/") || p == "/api" {
		s.apiMiss(w, r)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeErr(w, http.StatusMethodNotAllowed, "method_not_allowed", "This route only answers GET.")
		return
	}
	if s.o.Static == nil {
		http.NotFound(w, r)
		return
	}
	clean := strings.TrimPrefix(path.Clean("/"+p), "/")
	if clean != "" {
		if f, err := s.o.Static.Open(clean); err == nil {
			st, serr := f.Stat()
			_ = f.Close()
			if serr == nil && !st.IsDir() {
				s.serveFile(w, r, clean)
				return
			}
		}
		if path.Ext(clean) != "" || strings.HasPrefix(clean, "_app/") {
			http.NotFound(w, r)
			return
		}
	}
	s.serveFile(w, r, "index.html")
}

func (s *Server) serveFile(w http.ResponseWriter, r *http.Request, name string) {
	b, err := fs.ReadFile(s.o.Static, name)
	if err != nil {
		if name == "index.html" {
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = io.WriteString(w, "The web app is not built into this binary. Run services/console/build-web.sh, then rebuild the console.\n")
			return
		}
		http.NotFound(w, r)
		return
	}
	switch {
	case name == "index.html":
		w.Header().Set("Cache-Control", "no-cache")
	case strings.HasPrefix(name, "_app/immutable/"):
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	default:
		w.Header().Set("Cache-Control", "public, max-age=3600")
	}
	if ct := mime.TypeByExtension(path.Ext(name)); ct != "" {
		w.Header().Set("Content-Type", ct)
	}
	http.ServeContent(w, r, name, time.Time{}, strings.NewReader(string(b)))
}

// apiMiss answers an /api/ path that no route took: 405 with Allow when the path exists for another method, else 404.
func (s *Server) apiMiss(w http.ResponseWriter, r *http.Request) {
	var allow []string
	for _, rt := range Routes {
		m, pat, ok := strings.Cut(rt, " ")
		if ok && strings.HasPrefix(pat, "/api/") && matchPath(pat, r.URL.Path) {
			allow = append(allow, m)
		}
	}
	if len(allow) > 0 {
		w.Header().Set("Allow", strings.Join(allow, ", "))
		writeErr(w, http.StatusMethodNotAllowed, "method_not_allowed", "This route does not answer "+r.Method+".")
		return
	}
	writeErr(w, http.StatusNotFound, "not_found", "There is no such route.")
}

func matchPath(pattern, p string) bool {
	a, b := strings.Split(pattern, "/"), strings.Split(p, "/")
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if strings.HasPrefix(a[i], "{") {
			if b[i] == "" {
				return false
			}
			continue
		}
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// HTTPServer wraps the handler in an http.Server with the limits of this service: headers at most 16 KiB (431 above),
// and read, write and idle timeouts. There is no streaming route, so a write timeout is safe.
func HTTPServer(h http.Handler) *http.Server {
	return &http.Server{Handler: h, MaxHeaderBytes: MaxHeaderBytes, ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 30 * time.Second,
		WriteTimeout: 60 * time.Second, IdleTimeout: 120 * time.Second}
}

// metricsSummary answers GET /api/v1/metrics/summary. The only input is `window`, from a fixed list; the queries are
// written in package observe. Whatever the store said or failed with stays in the log.
func (s *Server) metricsSummary(w http.ResponseWriter, r *http.Request, _ *call) {
	win, ok := observe.ParseWindow(r.URL.Query().Get("window"))
	if !ok {
		writeErr(w, http.StatusBadRequest, "invalid", "window must be 24h or 7d.")
		return
	}
	const unavailable = "Metrics are not available: the console cannot read the metrics store. Check that observability is on and that console.metrics.url is set in chart values."
	if s.o.Observe == nil || !s.o.Observe.Has().Metrics {
		writeErr(w, http.StatusServiceUnavailable, "metrics_unavailable", unavailable)
		return
	}
	m, err := s.o.Observe.Metrics(r.Context(), win)
	if err != nil {
		rid, _ := r.Context().Value(ridKey{}).(string)
		s.o.Log.Warn("metrics store", "request_id", rid, "err", err)
		writeErr(w, http.StatusServiceUnavailable, "metrics_unavailable", unavailable)
		return
	}
	writeJSON(w, 200, m)
}

const tracesUnavailable = "Traces are not available: the console cannot read the trace store. Check that observability is on and that console.traces.url is set in chart values."

// traces answers GET /api/v1/traces: the most recent turns. No input at all: the query is fixed in package observe.
func (s *Server) traces(w http.ResponseWriter, r *http.Request, _ *call) {
	if s.o.Observe == nil || !s.o.Observe.Has().Traces {
		writeErr(w, http.StatusServiceUnavailable, "traces_unavailable", tracesUnavailable)
		return
	}
	t, err := s.o.Observe.Turns(r.Context())
	if err != nil {
		rid, _ := r.Context().Value(ridKey{}).(string)
		s.o.Log.Warn("trace store", "request_id", rid, "err", err)
		writeErr(w, http.StatusServiceUnavailable, "traces_unavailable", tracesUnavailable)
		return
	}
	if t == nil {
		t = []observe.Turn{}
	}
	writeJSON(w, 200, map[string]any{"items": t})
}

// traceOne answers GET /api/v1/traces/{traceId}: the spans of one turn, allowed attributes only. The id is validated as hex.
func (s *Server) traceOne(w http.ResponseWriter, r *http.Request, _ *call) {
	if s.o.Observe == nil || !s.o.Observe.Has().Traces {
		writeErr(w, http.StatusServiceUnavailable, "traces_unavailable", tracesUnavailable)
		return
	}
	d, err := s.o.Observe.Trace(r.Context(), r.PathValue("traceId"))
	switch {
	case errors.Is(err, observe.ErrBadTraceID):
		writeErr(w, http.StatusBadRequest, "invalid", "A trace id is 32 lower-case hexadecimal characters.")
	case err != nil:
		rid, _ := r.Context().Value(ridKey{}).(string)
		s.o.Log.Warn("trace store", "request_id", rid, "err", err)
		writeErr(w, http.StatusServiceUnavailable, "traces_unavailable", tracesUnavailable)
	default:
		writeJSON(w, 200, d)
	}
}

// schedules answers GET /api/v1/schedules: the chart's CronJobs, without prompts, tokens or user ids.
func (s *Server) schedules(w http.ResponseWriter, r *http.Request, _ *call) {
	if s.o.Schedules == nil {
		writeJSON(w, 200, govern.ScheduleList{Items: []govern.Schedule{}})
		return
	}
	l, err := s.o.Schedules.Schedules(r.Context())
	if err != nil {
		s.backendErr(w, r, err)
		return
	}
	writeJSON(w, 200, l)
}

// access answers GET /api/v1/access: the gate's caller rules by name, agents and methods; never keys, hashes or user id values.
func (s *Server) access(w http.ResponseWriter, r *http.Request, _ *call) {
	if s.o.Access == nil {
		writeJSON(w, 200, govern.AccessList{Items: []govern.Caller{}})
		return
	}
	l, err := s.o.Access.Access(r.Context())
	if err != nil {
		s.backendErr(w, r, err)
		return
	}
	writeJSON(w, 200, l)
}
