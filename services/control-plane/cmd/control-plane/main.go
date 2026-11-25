// Command control-plane is the OpenAgentix control plane: a controller that turns an AgentDefinition into a running
// agent, its gateway key and its registration, within the platform catalog and policy. See docs/decisions/0007 and the
// README of this service.
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

	"github.com/openagentix/openagentix/services/control-plane/internal/adapters/agentgateway"
	"github.com/openagentix/openagentix/services/control-plane/internal/adapters/container"
	"github.com/openagentix/openagentix/services/control-plane/internal/adapters/kagent"
	"github.com/openagentix/openagentix/services/control-plane/internal/adapters/toolhive"
	"github.com/openagentix/openagentix/services/control-plane/internal/api"
	"github.com/openagentix/openagentix/services/control-plane/internal/catalog"
	"github.com/openagentix/openagentix/services/control-plane/internal/config"
	"github.com/openagentix/openagentix/services/control-plane/internal/core"
	"github.com/openagentix/openagentix/services/control-plane/internal/keys"
	"github.com/openagentix/openagentix/services/control-plane/internal/kube"
	"github.com/openagentix/openagentix/services/control-plane/internal/routes"
)

// version is stamped at build time with -ldflags "-X main.version=...".
var version = "dev"

// deps are the parts a test replaces.
type deps struct {
	Log      *slog.Logger
	Kube     *kube.Client           // nil: the in-cluster client
	OnListen func(string)           // receives the bound health address
	Mint     func() (string, error) // nil: keys.Mint
}

func main() {
	level := slog.LevelInfo
	if v := os.Getenv("CONTROL_PLANE_LOG_LEVEL"); v != "" {
		_ = level.UnmarshalText([]byte(v))
	}
	log := slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: level}))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	if err := run(ctx, os.Getenv, deps{Log: log}); err != nil && !errors.Is(err, context.Canceled) {
		log.Error("control-plane stopped", "err", err)
		os.Exit(1)
	}
	log.Info("control-plane stopped")
}

func run(ctx context.Context, getenv func(string) string, d deps) error {
	cfg, err := config.Load(getenv)
	if err != nil {
		return fmt.Errorf("invalid configuration: %w", err)
	}
	cat, err := catalog.LoadCatalog(cfg.CatalogFile)
	if err != nil {
		return fmt.Errorf("catalog: %w", err)
	}
	pol, err := catalog.LoadPolicy(cfg.PolicyFile)
	if err != nil {
		return fmt.Errorf("policy: %w", err)
	}
	if err := catalog.CheckPolicy(cat, pol); err != nil {
		return fmt.Errorf("policy: %w", err)
	}
	for _, a := range []struct{ kind, got, want string }{
		{"runtime", cat.Adapters.Runtime, "kagent"},
		{"modelGateway", cat.Adapters.ModelGateway, "agentgateway"},
		{"tools", cat.Adapters.Tools, "toolhive"},
	} {
		if a.got != a.want {
			return fmt.Errorf("catalog names the %s adapter %q; this build has only %q", a.kind, a.got, a.want)
		}
	}
	if a := cat.Adapters.Runtimes[api.RuntimeContainer]; a != "" && a != "container" {
		return fmt.Errorf("catalog names the runtime adapter %q for container agents; this build has only %q", a, "container")
	}
	cl := d.Kube
	if cl == nil {
		if cl, err = kube.InCluster(); err != nil {
			return err
		}
	}
	runtimes := map[string]core.Runtime{api.RuntimeBuiltin: kagent.New(cat, cl)}
	var routeList core.Routes // nil: no container runtime, no route list
	if cat.RuntimeAvailable(api.RuntimeContainer) {
		runtimes[api.RuntimeContainer] = container.New(cat, cl)
		routeList = &routes.Store{Kube: cl, Namespace: cat.Runtime.Container.GateNamespace, Name: routes.DefaultName}
	}
	ctrl := core.New(core.Config{
		Namespace: cat.Namespaces.Agents, Catalog: cat, Policy: pol,
		Kube: cl, Secrets: &keys.KubeSecrets{C: cl},
		Runtime: runtimes[api.RuntimeBuiltin], Runtimes: runtimes, Routes: routeList, Gateway: agentgateway.New(cl, cat.Namespaces.Gateway), Tools: toolhive.New(cat),
		Log: d.Log, Mint: d.Mint, Resync: cfg.Resync, Backoff: cfg.Backoff, MinInterval: cfg.MinInterval, MinRecreateInterval: cfg.MinRecreateInterval,
	})

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = io.WriteString(w, "ok\n") })
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, _ *http.Request) {
		if !ctrl.Ready() {
			http.Error(w, "first pass not finished", http.StatusServiceUnavailable)
			return
		}
		_, _ = io.WriteString(w, "ok\n")
	})
	ln, err := net.Listen("tcp", cfg.HealthAddr)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", cfg.HealthAddr, err)
	}
	if d.OnListen != nil {
		d.OnListen(ln.Addr().String())
	}
	hs := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() { _ = hs.Serve(ln) }()
	d.Log.Info("control-plane started", "version", version, "namespace", cat.Namespaces.Agents, "health", ln.Addr().String(),
		"runtime", cat.Adapters.Runtime, "modelGateway", cat.Adapters.ModelGateway, "tools", cat.Adapters.Tools)

	err = ctrl.Run(ctx)
	sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = hs.Shutdown(sctx)
	return err
}
