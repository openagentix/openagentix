// Command bridge relays Telegram messages to an A2A agent and back.
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
	"syscall"
	"time"

	"github.com/openagentix/openagentix/bridges/telegram/internal/a2a"
	"github.com/openagentix/openagentix/bridges/telegram/internal/bridge"
	"github.com/openagentix/openagentix/bridges/telegram/internal/config"
	"github.com/openagentix/openagentix/bridges/telegram/internal/memory"
	"github.com/openagentix/openagentix/bridges/telegram/internal/telegram"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stderr, nil))
	cfg, err := config.Load(os.Getenv)
	if err != nil {
		log.Error("invalid configuration", "err", err)
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	if err := run(ctx, cfg, log); err != nil && !errors.Is(err, context.Canceled) {
		log.Error("bridge stopped", "err", err)
		os.Exit(1)
	}
	log.Info("bridge stopped")
}

func run(ctx context.Context, cfg config.Config, log *slog.Logger) error {
	// Telegram long polls for up to 30s, so its client has no overall timeout;
	// per-call deadlines come from ctx. The agent client is bounded by AgentTimeout via ctx too.
	tg := telegram.NewClient(cfg.APIBase, cfg.BotToken, &http.Client{})
	agent := a2a.NewClient(cfg.A2AURL, cfg.A2AToken, &http.Client{})
	if cfg.A2ATokenFile != "" {
		agent = agent.WithTokenFile(cfg.A2ATokenFile)
	}
	var mem bridge.Memories
	if cfg.MemoryURL != "" {
		mc := memory.NewClient(cfg.MemoryURL, cfg.MemoryAgent, &http.Client{}).WithToken(cfg.A2AToken)
		if cfg.A2ATokenFile != "" {
			mc = mc.WithTokenFile(cfg.A2ATokenFile)
		}
		mem = mc
	}
	b := &bridge.Bridge{
		Memory:             mem,
		Telegram:           tg,
		Agent:              agent,
		Store:              bridge.NewMemoryStore(),
		Log:                log,
		AgentTimeout:       cfg.AgentTimeout,
		PollTimeout:        30,
		Backoff:            3 * time.Second,
		Allowed:            cfg.AllowedChatIDs,
		AllowAll:           cfg.AllowAll,
		UserIDPrefix:       cfg.UserIDPrefix,
		MaxConcurrentTurns: cfg.MaxConcurrentTurns,
		ShutdownGrace:      cfg.ShutdownGrace,
		RetryOnWakeup:      cfg.RetryOnWakeup,
		WakeupDelay:        cfg.WakeupDelay,
	}
	log.Info("bridge starting", "allowlist_size", len(cfg.AllowedChatIDs), "allow_all", cfg.AllowAll, "memory_commands", mem != nil)
	if cfg.HealthAddr != "" {
		ln, err := net.Listen("tcp", cfg.HealthAddr)
		if err != nil {
			return fmt.Errorf("health listener: %w", err)
		}
		srv := &http.Server{Handler: b.HealthHandler(), ReadHeaderTimeout: 5 * time.Second}
		go func() { _ = srv.Serve(ln) }()
		defer srv.Close()
		log.Info("health endpoint listening", "addr", ln.Addr().String())
	}
	return b.Run(ctx)
}
