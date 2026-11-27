// Command records is the system-of-record service for the reference use cases: one small binary, one domain per
// install. The bank domain is the first. It serves a REST API (default :8081), an MCP endpoint (default :8080)
// and health checks on both. It makes no outbound connection and reads no secret: approver tokens are checked
// against hashes in a file.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/openagentix/openagentix/examples/use-cases/records/internal/bank"
	"github.com/openagentix/openagentix/examples/use-cases/records/internal/core"
	"github.com/openagentix/openagentix/examples/use-cases/records/internal/equipment"
)

// served is what every domain gives the binary.
type served interface {
	Seed(ctx context.Context) error
	Handler() http.Handler
	MCPHandler(version string) http.Handler
	FireDue(ctx context.Context) (int, error)
}

// version and defaultDomain are stamped at build time (-ldflags "-X main.version=... -X main.defaultDomain=bank").
// defaultRESTAddr keeps the REST port on the pod's loopback: only a person using kubectl port-forward reaches it.
// Agents use the MCP port. Set RECORDS_REST_ADDR=:8081 to listen on every interface.
const defaultRESTAddr = "127.0.0.1:8081"

var (
	version       = "dev"
	defaultDomain = "bank"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	if err := run(ctx, os.Getenv, log, nil); err != nil && !errors.Is(err, context.Canceled) {
		log.Error("records stopped", "err", err)
		os.Exit(1)
	}
}

func or(s, def string) string {
	if s == "" {
		return def
	}
	return s
}

func serve(ctx context.Context, h http.Handler, ln net.Listener) error {
	srv := &http.Server{Handler: h, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 << 10}
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ln) }()
	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
		sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(sctx)
		return nil
	}
}

// run wires the service and blocks until ctx ends. onListen, if set, receives the two bound addresses.
func run(ctx context.Context, getenv func(string) string, log *slog.Logger, onListen func(mcp, rest string)) error {
	domain := or(getenv("RECORDS_DOMAIN"), defaultDomain)
	if domain != "bank" && domain != "equipment" {
		return fmt.Errorf("unknown domain %q (this build has: bank, equipment)", domain)
	}
	approvers, err := core.LoadApprovers(getenv("RECORDS_APPROVERS_FILE"))
	if err != nil {
		return err
	}
	if !approvers.Enabled() {
		log.Warn("no approvers file: nobody can approve or reject, so nothing that needs approval will execute")
	}
	dir := or(getenv("RECORDS_DATA_DIR"), "/data")
	db, err := core.Open(filepath.Join(dir, "records.db"))
	if err != nil {
		return fmt.Errorf("open store: %w", err)
	}
	defer db.Close()
	clock := func() time.Time { return time.Now().UTC() }
	var d served
	switch domain {
	case "equipment":
		d, err = equipment.New(db, log, clock, approvers)
	default:
		d, err = bank.New(db, log, clock, approvers)
	}
	if err != nil {
		return fmt.Errorf("start %s: %w", domain, err)
	}
	if err := d.Seed(ctx); err != nil {
		return fmt.Errorf("seed: %w", err)
	}
	mln, err := net.Listen("tcp", or(getenv("RECORDS_MCP_ADDR"), ":8080"))
	if err != nil {
		return err
	}
	rln, err := net.Listen("tcp", or(getenv("RECORDS_REST_ADDR"), defaultRESTAddr))
	if err != nil {
		_ = mln.Close()
		return err
	}
	log.Info("records starting", "domain", domain, "version", version, "mcp", mln.Addr().String(), "rest", rln.Addr().String(), "approvers", approvers.Enabled())
	if onListen != nil {
		onListen(mln.Addr().String(), rln.Addr().String())
	}
	go func() {
		t := time.NewTicker(30 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				if _, err := d.FireDue(ctx); err != nil && ctx.Err() == nil {
					log.Error("timer sweep failed", "err", err)
				}
			}
		}
	}()
	errc := make(chan error, 2)
	sctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() { errc <- serve(sctx, d.MCPHandler(version), mln) }()
	go func() { errc <- serve(sctx, d.Handler(), rln) }()
	err = <-errc
	cancel()
	<-errc
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
