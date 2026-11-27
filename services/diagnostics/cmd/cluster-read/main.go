// Command cluster-read serves the read-only cluster tools of ADR 0025 over MCP.
//
// The MCP endpoint is unauthenticated by design. The tool gateway in front of
// it and a NetworkPolicy decide who can reach it. The server serves nothing
// until its rights check has passed, and again only while it keeps passing.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"

	"github.com/openagentix/openagentix/services/diagnostics/internal/audit"
	"github.com/openagentix/openagentix/services/diagnostics/internal/clusterread"
)

// version is stamped at build time with -ldflags "-X main.version=...".
var version = "dev"

type flags struct {
	cfg        clusterread.Config
	addr       string
	kubeconfig string
	checkEvery time.Duration
}

func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func parseFlags(args []string) (flags, error) {
	var f flags
	var logNS, statusNS, deny string
	fs := flag.NewFlagSet("cluster-read", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&logNS, "log-namespaces", "", "comma list: namespaces with pods, events, workloads and pod logs")
	fs.StringVar(&statusNS, "status-namespaces", "", "comma list: namespaces with pods, events and workloads, never logs")
	fs.StringVar(&deny, "deny-log-namespaces", "", "comma list: namespaces that must never be log namespaces (the chart's own)")
	fs.BoolVar(&f.cfg.Nodes, "nodes", true, "serve nodes_list and nodes_get")
	fs.StringVar(&f.addr, "addr", ":8080", "listen address")
	fs.StringVar(&f.kubeconfig, "kubeconfig", "", "kubeconfig file for local runs; empty means in-cluster")
	fs.DurationVar(&f.checkEvery, "check-interval", 5*time.Minute, "how often the rights check runs")
	if err := fs.Parse(args); err != nil {
		return f, err
	}
	f.cfg.LogNamespaces, f.cfg.StatusNamespaces, f.cfg.DenyLogNamespaces = splitList(logNS), splitList(statusNS), splitList(deny)
	if f.checkEvery < 10*time.Second {
		return f, errors.New("check-interval must be at least 10s")
	}
	if err := f.cfg.Validate(); err != nil {
		return f, err
	}
	return f, nil
}

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stderr, nil))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	if err := run(ctx, os.Args[1:], log); err != nil && !errors.Is(err, context.Canceled) {
		log.Error("cluster-read stopped", "err", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string, log *slog.Logger) error {
	f, err := parseFlags(args)
	if err != nil {
		return fmt.Errorf("invalid flags: %w", err)
	}
	var rc *rest.Config
	if f.kubeconfig != "" {
		rc, err = clientcmd.BuildConfigFromFlags("", f.kubeconfig)
	} else {
		rc, err = rest.InClusterConfig()
	}
	if err != nil {
		return fmt.Errorf("kubernetes config: %w", err)
	}
	// the rights check sends a few hundred small requests at start
	rc.QPS, rc.Burst = 50, 100
	client, err := kubernetes.NewForConfig(rc)
	if err != nil {
		return fmt.Errorf("kubernetes client: %w", err)
	}
	checker := clusterread.NewChecker(client, f.cfg)
	srv, err := clusterread.NewServer(clusterread.Options{Config: f.cfg, Client: client, Audit: audit.New(os.Stdout, "cluster-read"), Gate: checker})
	if err != nil {
		return err
	}
	ln, err := net.Listen("tcp", f.addr)
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	log.Info("cluster-read starting", "version", version, "listen", ln.Addr().String(), "log_namespaces", f.cfg.LogNamespaces, "status_namespaces", f.cfg.StatusNamespaces, "nodes", f.cfg.Nodes)

	if err := checker.Run(ctx); err != nil {
		log.Warn("rights check failed: serving nothing until a later check passes", "reason", err.Error())
	}
	go checker.Loop(ctx, f.checkEvery)

	hs := &http.Server{
		Handler:           clusterread.NewHandler(srv, checker, log, version),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second,
	}
	errc := make(chan error, 1)
	go func() { errc <- hs.Serve(ln) }()
	select {
	case <-ctx.Done():
		sctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = hs.Shutdown(sctx)
		return ctx.Err()
	case err := <-errc:
		return err
	}
}
