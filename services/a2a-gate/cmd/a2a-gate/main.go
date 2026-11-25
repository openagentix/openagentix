// Command a2a-gate is the OpenAgentix A2A gate: an authenticating reverse proxy in front of the kagent
// controller's A2A port. See package gate for what it does and ADR 0006 for why.
package main

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/openagentix/openagentix/services/a2a-gate/internal/auth"
	"github.com/openagentix/openagentix/services/a2a-gate/internal/config"
	"github.com/openagentix/openagentix/services/a2a-gate/internal/gate"
	"github.com/openagentix/openagentix/services/a2a-gate/internal/rules"
)

// maxHeaderBytes is the largest request header block the server reads (the net/http default is 1 MiB).
const maxHeaderBytes = 16 << 10

// version is stamped at build time with -ldflags "-X main.version=...".
var version = "dev"

// deps are the parts a test replaces.
type deps struct {
	Stdout   io.Writer     // audit lines
	Log      *slog.Logger  // process log
	OnListen func(string)  // receives the bound address
	Reviewer auth.Reviewer // nil: the in-cluster TokenReview client
}

func main() {
	level := slog.LevelInfo
	if v := os.Getenv("A2A_GATE_LOG_LEVEL"); v != "" {
		_ = level.UnmarshalText([]byte(v))
	}
	log := slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: level}))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	if err := run(ctx, os.Getenv, deps{Stdout: os.Stdout, Log: log}); err != nil && !errors.Is(err, context.Canceled) {
		log.Error("a2a-gate stopped", "err", err)
		os.Exit(1)
	}
	log.Info("a2a-gate stopped")
}

func run(ctx context.Context, getenv func(string) string, d deps) error {
	cfg, err := config.Load(getenv)
	if err != nil {
		return fmt.Errorf("invalid configuration: %w", err)
	}
	rl, err := rules.Load(cfg.RulesPath)
	if err != nil {
		return fmt.Errorf("invalid rules: %w", err)
	}
	rv := d.Reviewer
	if rv == nil {
		c, err := auth.InClusterTokenReview()
		if err != nil {
			return fmt.Errorf("token review: %w", err)
		}
		rv = c
	}
	salt := make([]byte, 16)
	_, _ = rand.Read(salt) // per process, like the bridge's chat hash
	h, err := gate.New(gate.Options{
		UpstreamURL: cfg.Upstream,
		Auth: auth.New(auth.Options{
			Rules: rl, Audience: cfg.Audience, Reviewer: rv,
			Keys: &auth.DirKeys{Dir: cfg.KeysDir, TTL: 10 * time.Second, OnProblem: func(name, why string) {
				d.Log.Warn("key hash file unusable: that caller cannot authenticate with a key", "caller", name, "why", why)
			}},
		}),
		Audit:       slog.New(slog.NewJSONHandler(d.Stdout, nil)),
		AuditUserID: cfg.AuditUserID, Salt: salt, SniffBytes: cfg.SniffBytes, MaxBody: cfg.MaxBody, MaxInFlight: cfg.MaxInFlight,
		RoutesFile: cfg.RoutesFile, WorkloadNamespace: cfg.WorkloadNamespace, WorkloadPort: cfg.WorkloadPort,
		PublicURL: cfg.PublicURL, Ctx: ctx, Log: d.Log,
	})
	if err != nil {
		return err
	}
	ln, err := net.Listen("tcp", cfg.Addr)
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	callers := make([]string, 0, len(rl.Callers))
	for _, c := range rl.Callers {
		callers = append(callers, c.Name)
	}
	d.Log.Info("a2a-gate starting", "version", version, "listen", ln.Addr().String(), "upstream", cfg.Upstream,
		"audience", cfg.Audience, "audit_user_id", cfg.AuditUserID, "callers", callers,
		"container_agents", cfg.RoutesFile != "")
	if d.OnListen != nil {
		d.OnListen(ln.Addr().String())
	}
	// No write timeout: an A2A stream (SSE) can run for minutes. Slow headers are cut, and a header block above 16 KiB
	// is refused (431): the real callers send well under 4 KiB (a ServiceAccount token is about 1 KiB). The start of
	// a body has its own read deadline in the gate.
	srv := &http.Server{Handler: h, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 120 * time.Second, MaxHeaderBytes: maxHeaderBytes}
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ln) }()
	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
		sctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
		defer cancel()
		_ = srv.Shutdown(sctx)
		return ctx.Err()
	}
}
