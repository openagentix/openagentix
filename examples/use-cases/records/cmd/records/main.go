// Command records is the system-of-record service for the reference use cases: one small binary, one domain per
// install. The bank domain is the first. It serves a REST API (default :8081), an MCP endpoint (default :8080)
// and health checks on both. It makes no outbound connection and reads no secret: approver tokens are checked
// against hashes in a file. One exception, off unless configured (ADR 0027): with RECORDS_EVENT_GATE_URL and
// RECORDS_EVENT_TOKEN_FILE it sends an event to the A2A gate for a case that an intake route opened, as its own
// ServiceAccount (a projected token read from the file for every request, never logged).
package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
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
	SetEvents(ev *core.Events)
	Unworked(ctx context.Context, olderThan time.Duration) ([]string, error)
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
	// The MCP port needs a credential. Without a token file the service refuses to start, unless the explicit
	// test flag says the port may be open (never set it on a cluster: anything that reaches the port can call every tool).
	tokenFile, insecure := getenv("RECORDS_MCP_TOKEN_FILE"), getenv("RECORDS_MCP_INSECURE_NO_AUTH")
	var guard *core.MCPBearer
	switch {
	case tokenFile != "" && insecure != "":
		return errors.New("RECORDS_MCP_TOKEN_FILE and RECORDS_MCP_INSECURE_NO_AUTH are both set: choose one")
	case tokenFile != "":
		g, err := core.NewMCPBearer(tokenFile, log)
		if err != nil {
			return err
		}
		guard = g
	case insecure == "true":
		log.Warn("RECORDS_MCP_INSECURE_NO_AUTH=true: the MCP port has NO credential. This is for tests only")
	default:
		return errors.New("the MCP port needs a credential: set RECORDS_MCP_TOKEN_FILE to a file that holds the whole header value (Bearer <token>); for a test only, RECORDS_MCP_INSECURE_NO_AUTH=true")
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
	sender, err := eventSender(getenv, d, db, log, clock)
	if err != nil {
		return err
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
	if sender != nil {
		tick, _ := time.ParseDuration(or(getenv("RECORDS_EVENT_TICK"), "2s"))
		go sender.Run(ctx, tick)
		log.Info("event sender on: an intake route sends an event to the gate", "attempts", sender.MaxAttempts())
	}
	errc := make(chan error, 2)
	sctx, cancel := context.WithCancel(ctx)
	defer cancel()
	mcpHandler := d.MCPHandler(version)
	if guard != nil {
		mcpHandler = guard.Wrap(mcpHandler)
	}
	go func() { errc <- serve(sctx, mcpHandler, mln) }()
	go func() { errc <- serve(sctx, d.Handler(), rln) }()
	err = <-errc
	cancel()
	<-errc
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

// eventSender returns the event sender, or nil when it is not configured. It is on only when both the gate URL and the token file are set; one
// without the other, or a value that is not valid, stops the service (fail closed). With it nil the store gets no events table.
func eventSender(getenv func(string) string, d served, db *sql.DB, log *slog.Logger, clock core.Clock) (*core.Sender, error) {
	url, tokenFile := getenv("RECORDS_EVENT_GATE_URL"), getenv("RECORDS_EVENT_TOKEN_FILE")
	if url == "" && tokenFile == "" {
		return nil, nil
	}
	cfg := core.SenderConfig{URL: url, TokenFile: tokenFile, Unworked: d.Unworked}
	if v := getenv("RECORDS_EVENT_UNWORKED_AFTER"); v != "" {
		dur, err := time.ParseDuration(v)
		if err != nil || dur < time.Minute || dur > 24*time.Hour {
			return nil, errors.New("RECORDS_EVENT_UNWORKED_AFTER must be a duration from 1m to 24h")
		}
		cfg.UnworkedAfter = dur
	}
	if v := getenv("RECORDS_EVENT_MAX_ATTEMPTS"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 10 {
			return nil, errors.New("RECORDS_EVENT_MAX_ATTEMPTS must be 1 to 10")
		}
		cfg.MaxAttempts = n
	}
	if v := getenv("RECORDS_EVENT_TICK"); v != "" {
		if dur, err := time.ParseDuration(v); err != nil || dur < 10*time.Millisecond || dur > time.Minute {
			return nil, errors.New("RECORDS_EVENT_TICK must be a duration from 10ms to 1m")
		}
	}
	ev, err := core.NewEvents(db, clock)
	if err != nil {
		return nil, fmt.Errorf("events: %w", err)
	}
	s, err := core.NewSender(ev, cfg, core.NewAudit(db, log, clock), log, clock)
	if err != nil {
		return nil, err
	}
	d.SetEvents(ev)
	return s, nil
}
