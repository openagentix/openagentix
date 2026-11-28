// Command kb serves the OpenAgentix knowledge base: an MCP endpoint for agents
// and an admin REST API for ingestion, over a pluggable store.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/openagentix/openagentix/services/kb/internal/access"
	"github.com/openagentix/openagentix/services/kb/internal/chunk"
	"github.com/openagentix/openagentix/services/kb/internal/config"
	"github.com/openagentix/openagentix/services/kb/internal/embed"
	"github.com/openagentix/openagentix/services/kb/internal/graph"
	"github.com/openagentix/openagentix/services/kb/internal/kb"
	"github.com/openagentix/openagentix/services/kb/internal/obs"
	"github.com/openagentix/openagentix/services/kb/internal/server"
	"github.com/openagentix/openagentix/services/kb/internal/store"
	"github.com/openagentix/openagentix/services/kb/internal/store/memory"
	"github.com/openagentix/openagentix/services/kb/internal/store/postgres"
)

// version is stamped at build time with -ldflags "-X main.version=...".
var version = "dev"

// onMetricsListen, if set (tests), receives the bound address of the metrics listener.
var onMetricsListen func(addr string)

func main() {
	level := slog.LevelInfo
	if v := os.Getenv("KB_LOG_LEVEL"); v != "" {
		_ = level.UnmarshalText([]byte(v))
	}
	log := slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: level}))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	if err := run(ctx, os.Getenv, log, nil); err != nil && !errors.Is(err, context.Canceled) {
		log.Error("kb stopped", "err", err)
		os.Exit(1)
	}
	log.Info("kb stopped")
}

// run wires everything and serves until ctx is cancelled. onListen, if set,
// receives the bound address once the listener is up.
func run(ctx context.Context, getenv func(string) string, log *slog.Logger, onListen func(addr string)) error {
	cfg, err := config.Load(getenv)
	if err != nil {
		return fmt.Errorf("invalid configuration: %w", err)
	}
	az, err := access.Load(cfg.AccessFile, cfg.AccessCallersDir, log)
	if err != nil {
		return err
	}
	var m *obs.Metrics // nil unless KB_METRICS_ADDR is set: every call on it is a no-op
	if cfg.MetricsAddr != "" {
		m = obs.New(version)
	}
	var embedder embed.Embedder = embed.None{}
	if cfg.EmbeddingsEnabled() {
		embedder, err = embed.NewOpenAI(embed.OpenAIConfig{
			URL: cfg.EmbeddingsURL, Model: cfg.EmbeddingsModel, APIKey: cfg.EmbeddingsAPIKey,
			Dim: cfg.EmbeddingsDim, Timeout: cfg.EmbeddingsTimeout,
		})
		if err != nil {
			return fmt.Errorf("embeddings: %w", err)
		}
		embedder = obs.WrapEmbedder(embedder, m)
	}
	var st store.Store
	switch cfg.Store {
	case "postgres":
		st, err = postgres.Open(ctx, postgres.Options{URL: cfg.DatabaseURL, Schema: cfg.DBSchema, VectorDim: embedder.Dimensions(), Graph: cfg.Graph.Enabled, GraphSchemas: cfg.Graph.Schemas})
		if err != nil {
			return fmt.Errorf("postgres store: %w", err)
		}
	default:
		st = memory.New(embedder.Dimensions())
	}
	defer st.Close()

	svc := &kb.Service{
		Store: st, Embedder: embedder,
		Chunk:       chunk.Options{MaxChars: cfg.ChunkMaxChars, Overlap: cfg.ChunkOverlap},
		DocMaxChars: cfg.DocMaxChars, Log: log,
		QueryEmbedTimeout: cfg.QueryEmbedTimeout, MaxChunksPerDoc: cfg.MaxChunksPerDoc,
		Metrics: m,
	}
	if cfg.Graph.Enabled {
		svc.Graph = &kb.GraphOptions{WindowChars: cfg.Graph.WindowChars, PromptVersion: cfg.Graph.PromptVersion, MaxHops: cfg.Graph.MaxHops, Schemas: cfg.Graph.Schemas}
		extractor, err := graph.NewGateway(graph.GatewayConfig{
			BaseURL: cfg.Graph.GatewayURL, Model: cfg.Graph.ExtractModel, APIKey: string(cfg.Graph.APIKey),
			Limits: graph.Limits{MaxEntities: cfg.Graph.MaxEntitiesPerChunk, MaxRelations: cfg.Graph.MaxRelationsPerWindow},
		})
		if err != nil {
			return fmt.Errorf("graph extraction: %w", err)
		}
		worker := graph.NewWorker(st, extractor, embedder, log, graph.Options{
			PromptVersion: cfg.Graph.PromptVersion, TokensPerHour: cfg.Graph.TokensPerHour, Metrics: m,
		})
		svc.RegisterGraphGauges(m, kb.GraphGaugeOptions{PerCollection: cfg.MetricsCollectionLabels})
		var wg sync.WaitGroup
		wg.Add(1)
		go func() { defer wg.Done(); _ = worker.Run(ctx) }()
		defer wg.Wait() // runs before st.Close: the worker never touches a closed store
	}
	ln, err := net.Listen("tcp", cfg.Addr)
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	log.Info("kb starting", append(cfg.LogAttrs(), "version", version, "listen", ln.Addr().String(), "access", accessMode(az))...)
	if cfg.AdminToken == "" && !cfg.AdminAllowAnonymous {
		log.Warn("admin API disabled: set KB_ADMIN_TOKEN to enable ingestion")
	}
	if onListen != nil {
		onListen(ln.Addr().String())
	}
	if m != nil {
		mln, err := net.Listen("tcp", cfg.MetricsAddr)
		if err != nil {
			_ = ln.Close()
			return fmt.Errorf("metrics listen: %w", err)
		}
		log.Info("metrics listening", "listen", mln.Addr().String())
		if onMetricsListen != nil {
			onMetricsListen(mln.Addr().String())
		}
		var mwg sync.WaitGroup
		mctx, mstop := context.WithCancel(ctx)
		mwg.Add(1)
		go func() {
			defer mwg.Done()
			if err := server.RunMetrics(mctx, m, mln, time.Second); err != nil {
				log.Error("metrics listener stopped", "err", err)
			}
		}()
		defer func() { mstop(); mwg.Wait() }()
	}
	return server.Run(ctx, server.Deps{Svc: svc, Cfg: cfg, Log: log, Version: version, Metrics: m, Access: az}, ln)
}

// accessMode names the caller check for the start log: "off", "report" or "enforce".
func accessMode(a *access.Authorizer) string {
	if a == nil {
		return "off"
	}
	return string(a.Mode())
}
