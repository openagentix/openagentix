// Command console is the OpenAgentix console: a small JSON API over the AgentDefinition resources, and the web app
// (built with Svelte, embedded in this binary). See README.md and ADR 0007 ("Console").
package main

import (
	"context"
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

	"github.com/openagentix/openagentix/services/console/ext"
	"github.com/openagentix/openagentix/services/console/internal/backend"
	"github.com/openagentix/openagentix/services/console/internal/builtin"
	"github.com/openagentix/openagentix/services/console/internal/config"
	"github.com/openagentix/openagentix/services/console/internal/fake"
	"github.com/openagentix/openagentix/services/console/internal/kube"
	"github.com/openagentix/openagentix/services/console/internal/observe"
	"github.com/openagentix/openagentix/services/console/internal/platform"
	"github.com/openagentix/openagentix/services/console/internal/server"
	"github.com/openagentix/openagentix/services/console/web"
)

// version is stamped at build time with -ldflags "-X main.version=...".
var version = "dev"

type deps struct {
	Stdout   io.Writer    // audit lines
	Log      *slog.Logger // process log
	OnListen func(string) // receives the bound address
}

func main() {
	level := slog.LevelInfo
	if v := os.Getenv("CONSOLE_LOG_LEVEL"); v != "" {
		_ = level.UnmarshalText([]byte(v))
	}
	log := slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: level}))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	if err := run(ctx, os.Getenv, deps{Stdout: os.Stdout, Log: log}); err != nil && !errors.Is(err, context.Canceled) {
		log.Error("console stopped", "err", err)
		os.Exit(1)
	}
	log.Info("console stopped")
}

func run(ctx context.Context, getenv func(string) string, d deps) error {
	cfg, err := config.Load(getenv)
	if err != nil {
		return fmt.Errorf("invalid configuration: %w", err)
	}
	var (
		be   backend.Backend
		plat platform.Source
		auth ext.Authenticator
		ns   = cfg.Namespace
	)
	if cfg.DevFake {
		plat = platform.Static{Value: fake.Platform()}
		be = fake.New(nil, cfg.DevFakeSettle)
		if cfg.TokenFile != "" {
			auth = &builtin.TokenAuth{Path: cfg.TokenFile}
		} else {
			auth = builtin.StaticAuth{Token: config.DemoToken}
			d.Log.Warn("DEMO MODE: fake in-memory data, no cluster is read or written. Sign in with the token below.", "token", config.DemoToken)
		}
	} else {
		files := &platform.Files{CatalogPath: cfg.CatalogFile, PolicyPath: cfg.PolicyFile}
		b, err := files.Get()
		if err != nil {
			return fmt.Errorf("platform files: %w", err)
		}
		plat = files
		if ns == "" {
			ns = b.Catalog.Namespaces.Agents
		}
		if ns == "" {
			return errors.New("CONSOLE_NAMESPACE is not set and the catalog names no agents namespace")
		}
		ta := &builtin.TokenAuth{Path: cfg.TokenFile, MinLen: config.MinTokenLen, Reject: []string{config.DemoToken}}
		st, err := os.Stat(cfg.TokenFile)
		if err != nil || st.Size() == 0 {
			return fmt.Errorf("CONSOLE_TOKEN_FILE %s is missing or empty: the installer creates the console token Secret", cfg.TokenFile)
		}
		if tok, err := os.ReadFile(cfg.TokenFile); err != nil {
			return fmt.Errorf("CONSOLE_TOKEN_FILE %s cannot be read: %w", cfg.TokenFile, err)
		} else if why := builtin.WeakToken(string(tok), config.MinTokenLen, ta.Reject); why != "" {
			return fmt.Errorf("the console token in %s is too weak (%s). Anyone who can reach the port can try tokens, so the console will not start with it; generate a long random one, for example: openssl rand -hex 32", cfg.TokenFile, why)
		}
		auth = ta
		kc, err := kube.New(cfg.KubeAPI, cfg.KubeTokenFile, cfg.KubeCAFile)
		if err != nil {
			return err
		}
		kb := backend.NewKube(kc, ns, cfg.KagentAPI, plat)
		kb.Cap = cfg.ListMax
		be = kb
	}
	var obs observe.Observability
	switch {
	case cfg.DevFake:
		obs = fake.Observe{}
	case cfg.MetricsURL != "":
		obs = observe.NewProm(cfg.MetricsURL, &http.Client{Timeout: 8 * time.Second})
	}
	h := server.New(server.Options{
		Observe: obs,
		Backend: be, Platform: plat, Authenticator: auth, Authorizer: builtin.RoleAuthz{Viewer: cfg.Viewer},
		Audit:  builtin.LogAudit{Log: slog.New(slog.NewJSONHandler(d.Stdout, nil))},
		Static: web.FS(), Log: d.Log, Demo: cfg.DevFake, Namespace: ns, Context: cfg.Context, Version: version, RequestTimeout: cfg.RequestTimeout,
		AllowedHosts: cfg.AllowedHosts, AuthFailLimit: cfg.AuthFailLimit, AuthFailLimitGlobal: cfg.AuthFailLimitGlobal, ValidatePerMinute: cfg.ValidatePerMinute, HSTS: cfg.HSTS,
	})
	ln, err := net.Listen("tcp", cfg.Addr)
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	d.Log.Info("console starting", "version", version, "listen", ln.Addr().String(), "namespace", ns, "demo", cfg.DevFake, "viewer", cfg.Viewer)
	if d.OnListen != nil {
		d.OnListen(ln.Addr().String())
	}
	srv := server.HTTPServer(h)
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ln) }()
	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
		sctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(sctx)
		return ctx.Err()
	}
}
