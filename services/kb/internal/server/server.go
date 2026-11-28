// Package server assembles the HTTP surface (MCP, admin API, probes) and runs
// it with timeouts and graceful shutdown.
package server

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/openagentix/openagentix/services/kb/internal/access"
	"github.com/openagentix/openagentix/services/kb/internal/api"
	"github.com/openagentix/openagentix/services/kb/internal/config"
	"github.com/openagentix/openagentix/services/kb/internal/kb"
	"github.com/openagentix/openagentix/services/kb/internal/mcpserver"
	"github.com/openagentix/openagentix/services/kb/internal/obs"
)

// Deps are everything the HTTP layer needs.
type Deps struct {
	Svc     *kb.Service
	Cfg     config.Config
	Log     *slog.Logger
	Version string
	// Metrics, when non-nil, counts requests and tool calls. It is exposed on its own listener (RunMetrics), never here.
	Metrics *obs.Metrics
	// Access, when non-nil, checks the caller of every /mcp request (ADR 0030).
	Access *access.Authorizer
}

// Handler builds the full handler: /mcp, /v1/*, /healthz, /readyz.
func Handler(d Deps) http.Handler {
	mux := http.NewServeMux()
	mux.Handle("/mcp", mcpserver.New(d.Svc, d.Log, mcpserver.Options{Stateless: d.Cfg.MCPStateless, Version: d.Version, Timeout: d.Cfg.RequestTimeout, Metrics: d.Metrics, Access: d.Access}))
	mux.Handle("/v1/", api.New(d.Svc, api.Config{
		AdminToken: d.Cfg.AdminToken, AllowAnonymous: d.Cfg.AdminAllowAnonymous, MaxBodyBytes: d.Cfg.MaxBodyBytes,
	}, d.Log))
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if err := d.Svc.Store.Ping(ctx); err != nil {
			d.Log.Warn("readiness check failed", "err", err)
			http.Error(w, "store unreachable", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ready\n"))
	})
	return recoverer(d.Log, accessLog(d.Log, requestTimeout(d.Cfg.RequestTimeout, d.Cfg.IngestTimeout, httpMetrics(d.Metrics, mux))))
}

// httpMetrics counts requests by the matched route template, never the raw
// path. It wraps the mux directly so the mux sets Request.Pattern on the very
// request value read here afterwards.
func httpMetrics(m *obs.Metrics, next http.Handler) http.Handler {
	if m == nil {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w}
		next.ServeHTTP(sw, r)
		status := sw.status
		if status == 0 {
			status = http.StatusOK
		}
		m.HTTP(routeOf(r.Pattern), r.Method, status, time.Since(start))
	})
}

// routeOf strips the method from a ServeMux pattern ("PUT /v1/x/{id}" -> "/v1/x/{id}").
// The catch-all "/v1/" pattern means no API route matched.
func routeOf(pattern string) string {
	if _, p, ok := strings.Cut(pattern, " "); ok {
		pattern = p
	}
	if pattern == "/v1/" {
		return ""
	}
	return pattern
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	if w.status == 0 {
		w.status = code
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *statusWriter) Write(b []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	return w.ResponseWriter.Write(b)
}

// Flush keeps streaming responses (SSE) working through the wrapper.
func (w *statusWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (w *statusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

// accessLog logs method, path, status and duration. It never logs headers,
// query strings or bodies.
func accessLog(log *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w}
		next.ServeHTTP(sw, r)
		if sw.status == 0 {
			sw.status = http.StatusOK
		}
		log.Info("request", "method", r.Method, "path", r.URL.Path, "status", sw.status, "duration_ms", time.Since(start).Milliseconds())
	})
}

func recoverer(log *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				log.Error("panic in handler", "method", r.Method, "path", r.URL.Path, "panic", v)
				http.Error(w, "internal error", http.StatusInternalServerError)
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// requestTimeout bounds request handling time via the context. A GET on /mcp
// is the long-lived SSE stream of stateful sessions and is exempt. Document
// ingest (PUT under /v1/) gets the longer ingest budget because embedding a
// large document takes many sequential batches.
func requestTimeout(d, ingest time.Duration, next http.Handler) http.Handler {
	if d <= 0 {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/mcp" {
			next.ServeHTTP(w, r)
			return
		}
		limit := d
		if ingest > d && r.Method == http.MethodPut && strings.HasPrefix(r.URL.Path, "/v1/") {
			limit = ingest
		}
		ctx, cancel := context.WithTimeout(r.Context(), limit)
		defer cancel()
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// Run serves on ln until ctx is cancelled, then drains in-flight requests for
// up to Cfg.ShutdownGrace.
func Run(ctx context.Context, d Deps, ln net.Listener) error {
	srv := &http.Server{
		Handler:           Handler(d),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       max(d.Cfg.RequestTimeout, d.Cfg.IngestTimeout),
		IdleTimeout:       120 * time.Second,
		BaseContext:       func(net.Listener) context.Context { return context.WithoutCancel(ctx) },
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ln) }()
	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	d.Log.Info("shutting down", "grace", d.Cfg.ShutdownGrace.String())
	sctx, cancel := context.WithTimeout(context.Background(), d.Cfg.ShutdownGrace)
	defer cancel()
	if err := srv.Shutdown(sctx); err != nil {
		_ = srv.Close()
		return err
	}
	if err := <-errc; err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

// RunMetrics serves GET /metrics on ln, and nothing else, until ctx is
// cancelled. It carries no authentication: bind it to a pod-local or cluster
// network port that a NetworkPolicy opens only to the scraper.
func RunMetrics(ctx context.Context, m *obs.Metrics, ln net.Listener, grace time.Duration) error {
	srv := &http.Server{
		Handler:           m.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ln) }()
	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	if grace <= 0 {
		grace = time.Second
	}
	sctx, cancel := context.WithTimeout(context.Background(), grace)
	defer cancel()
	if err := srv.Shutdown(sctx); err != nil {
		_ = srv.Close()
	}
	if err := <-errc; err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
