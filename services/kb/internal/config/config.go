// Package config loads knowledge-base settings from environment variables.
package config

import (
	"fmt"
	"net"
	"net/url"
	"path/filepath"
	"regexp"
	"strconv"
	"time"
)

// Config holds all settings. Secret fields (AdminToken, DatabaseURL,
// EmbeddingsAPIKey) must never be logged; use LogAttrs.
type Config struct {
	Addr           string
	LogLevel       string
	RequestTimeout time.Duration
	ShutdownGrace  time.Duration

	AdminToken          string
	AdminAllowAnonymous bool
	MaxBodyBytes        int64

	Store       string // "memory" or "postgres"
	DatabaseURL string
	DBSchema    string

	ChunkMaxChars int
	ChunkOverlap  int
	DocMaxChars   int // kb_get_document truncation

	EmbeddingsURL     string
	EmbeddingsModel   string
	EmbeddingsAPIKey  string
	EmbeddingsDim     int
	EmbeddingsTimeout time.Duration

	MCPStateless bool // serve MCP without sessions (default true)

	QueryEmbedTimeout time.Duration // bound on the query-time embedding call
	IngestTimeout     time.Duration // request deadline of PUT /v1/.../documents/...
	MaxChunksPerDoc   int           // reject larger documents before embedding

	// MetricsAddr, when set, is the listen address of the separate Prometheus
	// listener (GET /metrics only, no authentication). Empty means no metrics.
	MetricsAddr string
	// MetricsCollectionLabels adds the operator-chosen collection name as a label
	// on the graph size gauges. Off by default: names are unbounded.
	MetricsCollectionLabels bool

	// AccessFile is the path of access.json (ADR 0030); empty means no caller check. AccessCallersDir holds one value
	// file per caller. Neither holds a value in the environment: the values are files.
	AccessFile       string
	AccessCallersDir string

	Graph GraphConfig
}

// Secret is a string that prints as "[redacted]" with every fmt verb that
// calls String, so it cannot reach a log line by accident.
type Secret string

func (Secret) String() string { return "[redacted]" }

// GraphConfig holds the knowledge-graph (entity and relation extraction)
// settings. The graph is off by default; the other fields only matter when
// Enabled is set. APIKey must never be logged.
type GraphConfig struct {
	Enabled               bool
	ExtractModel          string // model alias on the gateway
	GatewayURL            string // OpenAI-compatible base URL
	APIKey                Secret
	WindowChars           int // extraction window size
	MaxEntitiesPerChunk   int // entity cap per window is this times its chunks
	MaxRelationsPerWindow int
	TokensPerHour         int // budget for extraction calls, from the usage in responses
	MaxHops               int // longest traversal queries may ask for, 1..3
	PromptVersion         string
}

// Graph defaults.
const (
	DefaultGraphWindowChars           = 2400
	DefaultGraphMaxEntitiesPerChunk   = 12
	DefaultGraphMaxRelationsPerWindow = 30
	DefaultGraphTokensPerHour         = 300000
	DefaultGraphMaxHops               = 3
	DefaultGraphPromptVersion         = "v2"
)

// DefaultAccessCallersDir is where the chart mounts the caller value files.
const DefaultAccessCallersDir = "/var/run/secrets/openagentix/kb-callers"

var promptVersionRe = regexp.MustCompile(`^[A-Za-z0-9._-]{1,32}$`)

// EmbeddingsEnabled reports whether an embedder is configured.
func (c Config) EmbeddingsEnabled() bool { return c.EmbeddingsURL != "" }

const (
	// MaxChunkMaxChars caps KB_CHUNK_MAX_CHARS.
	MaxChunkMaxChars = 100000
	// MaxEmbeddingsDim is the largest dimension pgvector can index with HNSW
	// on the plain vector type.
	MaxEmbeddingsDim = 2000
)

var schemaRe = regexp.MustCompile(`^[a-z_][a-z0-9_]{0,62}$`)

// Load reads configuration using getenv (e.g. os.Getenv).
func Load(getenv func(string) string) (Config, error) {
	c := Config{
		Addr:              orDefault(getenv("KB_ADDR"), ":8080"),
		LogLevel:          orDefault(getenv("KB_LOG_LEVEL"), "info"),
		RequestTimeout:    30 * time.Second,
		ShutdownGrace:     25 * time.Second,
		AdminToken:        getenv("KB_ADMIN_TOKEN"),
		MaxBodyBytes:      4 << 20,
		Store:             orDefault(getenv("KB_STORE"), "memory"),
		DatabaseURL:       getenv("KB_DATABASE_URL"),
		DBSchema:          orDefault(getenv("KB_DB_SCHEMA"), "kb"),
		ChunkMaxChars:     1200,
		ChunkOverlap:      150,
		DocMaxChars:       50000,
		EmbeddingsURL:     getenv("KB_EMBEDDINGS_URL"),
		EmbeddingsModel:   getenv("KB_EMBEDDINGS_MODEL"),
		EmbeddingsAPIKey:  getenv("KB_EMBEDDINGS_API_KEY"),
		EmbeddingsTimeout: 30 * time.Second,
		MCPStateless:      true,
		QueryEmbedTimeout: 3 * time.Second,
		IngestTimeout:     120 * time.Second,
		MaxChunksPerDoc:   2000,
	}
	c.Graph = GraphConfig{
		ExtractModel: getenv("KB_GRAPH_EXTRACT_MODEL"), GatewayURL: getenv("KB_GRAPH_GATEWAY_URL"), APIKey: Secret(getenv("KB_GRAPH_API_KEY")),
		WindowChars: DefaultGraphWindowChars, MaxEntitiesPerChunk: DefaultGraphMaxEntitiesPerChunk,
		MaxRelationsPerWindow: DefaultGraphMaxRelationsPerWindow, TokensPerHour: DefaultGraphTokensPerHour,
		MaxHops: DefaultGraphMaxHops, PromptVersion: orDefault(getenv("KB_GRAPH_PROMPT_VERSION"), DefaultGraphPromptVersion),
	}
	var err error
	if c.RequestTimeout, err = duration(getenv, "KB_REQUEST_TIMEOUT", c.RequestTimeout, false); err != nil {
		return c, err
	}
	if c.ShutdownGrace, err = duration(getenv, "KB_SHUTDOWN_GRACE", c.ShutdownGrace, true); err != nil {
		return c, err
	}
	if c.EmbeddingsTimeout, err = duration(getenv, "KB_EMBEDDINGS_TIMEOUT", c.EmbeddingsTimeout, false); err != nil {
		return c, err
	}
	if c.QueryEmbedTimeout, err = duration(getenv, "KB_QUERY_EMBED_TIMEOUT", c.QueryEmbedTimeout, false); err != nil {
		return c, err
	}
	if c.IngestTimeout, err = duration(getenv, "KB_INGEST_TIMEOUT", c.IngestTimeout, false); err != nil {
		return c, err
	}
	if c.MaxChunksPerDoc, err = positiveInt(getenv, "KB_MAX_CHUNKS_PER_DOC", c.MaxChunksPerDoc); err != nil {
		return c, err
	}
	var mb int
	if mb, err = positiveInt(getenv, "KB_MAX_BODY_BYTES", int(c.MaxBodyBytes)); err != nil {
		return c, err
	}
	c.MaxBodyBytes = int64(mb)
	if c.ChunkMaxChars, err = positiveInt(getenv, "KB_CHUNK_MAX_CHARS", c.ChunkMaxChars); err != nil {
		return c, err
	}
	if c.ChunkMaxChars > MaxChunkMaxChars {
		return c, fmt.Errorf("KB_CHUNK_MAX_CHARS: %d exceeds the maximum of %d", c.ChunkMaxChars, MaxChunkMaxChars)
	}
	if c.DocMaxChars, err = positiveInt(getenv, "KB_DOC_MAX_CHARS", c.DocMaxChars); err != nil {
		return c, err
	}
	if v := getenv("KB_CHUNK_OVERLAP"); v != "" {
		n, perr := strconv.Atoi(v)
		if perr != nil || n < 0 {
			return c, fmt.Errorf("KB_CHUNK_OVERLAP: invalid value %q", v)
		}
		c.ChunkOverlap = n
	} else if c.ChunkOverlap >= c.ChunkMaxChars {
		c.ChunkOverlap = c.ChunkMaxChars / 8
	}
	if c.ChunkOverlap >= c.ChunkMaxChars {
		return c, fmt.Errorf("KB_CHUNK_OVERLAP: %d must be smaller than KB_CHUNK_MAX_CHARS (%d)", c.ChunkOverlap, c.ChunkMaxChars)
	}
	switch v := getenv("KB_ADMIN_ALLOW_ANONYMOUS"); v {
	case "", "false":
	case "true":
		c.AdminAllowAnonymous = true
	default:
		return c, fmt.Errorf("KB_ADMIN_ALLOW_ANONYMOUS: must be true or false, got %q", v)
	}
	switch v := getenv("KB_MCP_STATELESS"); v {
	case "", "true":
	case "false":
		c.MCPStateless = false
	default:
		return c, fmt.Errorf("KB_MCP_STATELESS: must be true or false, got %q", v)
	}
	if err := loadAccess(getenv, &c); err != nil {
		return c, err
	}
	if err := loadMetrics(getenv, &c); err != nil {
		return c, err
	}
	switch c.LogLevel {
	case "debug", "info", "warn", "error":
	default:
		return c, fmt.Errorf("KB_LOG_LEVEL: invalid level %q", c.LogLevel)
	}
	switch c.Store {
	case "memory":
	case "postgres":
		if c.DatabaseURL == "" {
			return c, fmt.Errorf("KB_DATABASE_URL is required when KB_STORE=postgres")
		}
	default:
		return c, fmt.Errorf("KB_STORE: unknown store %q (want memory or postgres)", c.Store)
	}
	if !schemaRe.MatchString(c.DBSchema) {
		return c, fmt.Errorf("KB_DB_SCHEMA: %q is not a valid schema name ([a-z_][a-z0-9_]*, max 63)", c.DBSchema)
	}
	if v := getenv("KB_EMBEDDINGS_DIM"); v != "" {
		n, perr := strconv.Atoi(v)
		if perr != nil || n <= 0 || n > MaxEmbeddingsDim {
			return c, fmt.Errorf("KB_EMBEDDINGS_DIM: invalid dimension %q (1..%d; pgvector's HNSW index supports at most %d dimensions)", v, MaxEmbeddingsDim, MaxEmbeddingsDim)
		}
		c.EmbeddingsDim = n
	}
	if c.EmbeddingsURL != "" {
		if c.EmbeddingsModel == "" {
			return c, fmt.Errorf("KB_EMBEDDINGS_MODEL is required when KB_EMBEDDINGS_URL is set")
		}
		if c.EmbeddingsDim == 0 {
			return c, fmt.Errorf("KB_EMBEDDINGS_DIM is required when KB_EMBEDDINGS_URL is set")
		}
	} else if c.EmbeddingsModel != "" || c.EmbeddingsDim != 0 || c.EmbeddingsAPIKey != "" {
		return c, fmt.Errorf("KB_EMBEDDINGS_URL is required when other KB_EMBEDDINGS_* settings are set")
	}
	if err := loadGraph(getenv, &c.Graph); err != nil {
		return c, err
	}
	return c, nil
}

func loadAccess(getenv func(string) string, c *Config) error {
	c.AccessFile = getenv("KB_ACCESS_FILE")
	c.AccessCallersDir = orDefault(getenv("KB_ACCESS_CALLERS_DIR"), DefaultAccessCallersDir)
	if c.AccessFile == "" {
		if getenv("KB_ACCESS_CALLERS_DIR") != "" {
			return fmt.Errorf("KB_ACCESS_FILE is required when KB_ACCESS_CALLERS_DIR is set")
		}
		return nil
	}
	if !filepath.IsAbs(c.AccessFile) || !filepath.IsAbs(c.AccessCallersDir) {
		return fmt.Errorf("KB_ACCESS_FILE and KB_ACCESS_CALLERS_DIR must be absolute paths")
	}
	return nil
}

func loadMetrics(getenv func(string) string, c *Config) error {
	c.MetricsAddr = getenv("KB_METRICS_ADDR")
	if c.MetricsAddr != "" {
		_, port, err := net.SplitHostPort(c.MetricsAddr)
		if err != nil || port == "" {
			return fmt.Errorf("KB_METRICS_ADDR: %q must be host:port or :port", c.MetricsAddr)
		}
		if c.MetricsAddr == c.Addr && port != "0" { // port 0 picks a free port each, so two of them never collide
			return fmt.Errorf("KB_METRICS_ADDR: %q must differ from KB_ADDR (metrics are served on their own listener)", c.MetricsAddr)
		}
	}
	switch v := getenv("KB_METRICS_COLLECTION_LABELS"); v {
	case "", "false":
	case "true":
		if c.MetricsAddr == "" {
			return fmt.Errorf("KB_METRICS_COLLECTION_LABELS=true requires KB_METRICS_ADDR")
		}
		c.MetricsCollectionLabels = true
	default:
		return fmt.Errorf("KB_METRICS_COLLECTION_LABELS: must be true or false, got %q", v)
	}
	return nil
}

func loadGraph(getenv func(string) string, g *GraphConfig) error {
	switch v := getenv("KB_GRAPH_ENABLED"); v {
	case "", "false":
	case "true":
		g.Enabled = true
	default:
		return fmt.Errorf("KB_GRAPH_ENABLED: must be true or false, got %q", v)
	}
	if !g.Enabled {
		if g.ExtractModel != "" || g.GatewayURL != "" || g.APIKey != "" {
			return fmt.Errorf("KB_GRAPH_ENABLED=true is required when other KB_GRAPH_* settings are set")
		}
		return nil
	}
	var err error
	if g.WindowChars, err = positiveInt(getenv, "KB_GRAPH_WINDOW_CHARS", g.WindowChars); err != nil {
		return err
	}
	if g.MaxEntitiesPerChunk, err = positiveInt(getenv, "KB_GRAPH_MAX_ENTITIES_PER_CHUNK", g.MaxEntitiesPerChunk); err != nil {
		return err
	}
	if g.MaxRelationsPerWindow, err = positiveInt(getenv, "KB_GRAPH_MAX_RELATIONS_PER_WINDOW", g.MaxRelationsPerWindow); err != nil {
		return err
	}
	if g.TokensPerHour, err = positiveInt(getenv, "KB_GRAPH_TOKENS_PER_HOUR", g.TokensPerHour); err != nil {
		return err
	}
	if g.MaxHops, err = positiveInt(getenv, "KB_GRAPH_MAX_HOPS", g.MaxHops); err != nil {
		return err
	}
	if g.MaxHops > 3 {
		return fmt.Errorf("KB_GRAPH_MAX_HOPS: %d exceeds the maximum of 3", g.MaxHops)
	}
	if !promptVersionRe.MatchString(g.PromptVersion) {
		return fmt.Errorf("KB_GRAPH_PROMPT_VERSION: %q must match %s", g.PromptVersion, promptVersionRe)
	}
	if g.ExtractModel == "" {
		return fmt.Errorf("KB_GRAPH_EXTRACT_MODEL is required when KB_GRAPH_ENABLED=true")
	}
	if u, perr := url.Parse(g.GatewayURL); perr != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return fmt.Errorf("KB_GRAPH_GATEWAY_URL: must be an http(s) URL when KB_GRAPH_ENABLED=true")
	}
	return nil
}

// LogAttrs returns slog key/value pairs describing the configuration with all
// secrets omitted.
func (c Config) LogAttrs() []any {
	return []any{
		"addr", c.Addr, "store", c.Store, "db_schema", c.DBSchema,
		"admin_api", c.adminMode(), "max_body_bytes", c.MaxBodyBytes,
		"chunk_max_chars", c.ChunkMaxChars, "chunk_overlap", c.ChunkOverlap,
		"max_chunks_per_doc", c.MaxChunksPerDoc, "ingest_timeout", c.IngestTimeout.String(),
		"query_embed_timeout", c.QueryEmbedTimeout.String(),
		"embeddings", c.EmbeddingsEnabled(), "embeddings_model", c.EmbeddingsModel, "embeddings_dim", c.EmbeddingsDim,
		"metrics_addr", c.MetricsAddr, "graph", c.Graph.Enabled, "graph_extract_model", c.Graph.ExtractModel, "graph_prompt_version", c.Graph.PromptVersion,
		"graph_window_chars", c.Graph.WindowChars, "graph_tokens_per_hour", c.Graph.TokensPerHour,
		"access_file", c.AccessFile,
	}
}

func (c Config) adminMode() string {
	switch {
	case c.AdminToken != "":
		return "token"
	case c.AdminAllowAnonymous:
		return "anonymous"
	default:
		return "disabled"
	}
}

func orDefault(v, d string) string {
	if v == "" {
		return d
	}
	return v
}

func positiveInt(getenv func(string) string, name string, def int) (int, error) {
	v := getenv(name)
	if v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		return 0, fmt.Errorf("%s: invalid value %q", name, v)
	}
	return n, nil
}

func duration(getenv func(string) string, name string, def time.Duration, allowZero bool) (time.Duration, error) {
	v := getenv(name)
	if v == "" {
		return def, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil || d < 0 || (d == 0 && !allowZero) {
		return 0, fmt.Errorf("%s: invalid duration %q", name, v)
	}
	return d, nil
}
