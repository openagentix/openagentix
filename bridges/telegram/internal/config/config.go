// Package config loads bridge settings from environment variables.
package config

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	BotToken           string
	A2AURL             string
	A2AToken           string
	A2ATokenFile       string // A2A_TOKEN_FILE: a bearer token read again on every request (a projected ServiceAccount token)
	UserIDPrefix       string // A2A_USER_ID_PREFIX; the agent-side user id is this prefix + the Telegram chat id
	MemoryURL          string // MEMORY_GATE_URL: the A2A gate; with MEMORY_AGENT it turns on /memories and /forget (ADR 0006, round 3)
	MemoryAgent        string // MEMORY_AGENT: "namespace/name" of the agent whose memories those commands show and delete
	APIBase            string
	AgentTimeout       time.Duration
	AllowedChatIDs     map[int64]bool
	AllowAll           bool // explicit opt-in to accept every chat
	MaxConcurrentTurns int
	ShutdownGrace      time.Duration
	HealthAddr         string
	RetryOnWakeup      bool          // RETRY_ON_WAKEUP, default true: retry once when the agent answers -32004
	WakeupDelay        time.Duration // WAKEUP_RETRY_DELAY, default 20s: the wait before that retry
}

// Load reads configuration using getenv (e.g. os.Getenv).
func Load(getenv func(string) string) (Config, error) {
	c := Config{
		BotToken:           getenv("TELEGRAM_BOT_TOKEN"),
		A2AURL:             getenv("A2A_URL"),
		A2AToken:           getenv("A2A_TOKEN"),
		A2ATokenFile:       getenv("A2A_TOKEN_FILE"),
		APIBase:            getenv("TELEGRAM_API_BASE"),
		AgentTimeout:       120 * time.Second,
		AllowedChatIDs:     map[int64]bool{},
		MaxConcurrentTurns: 8,
		ShutdownGrace:      25 * time.Second,
		HealthAddr:         getenv("HEALTH_ADDR"),
		RetryOnWakeup:      true,
		WakeupDelay:        20 * time.Second,
	}
	c.UserIDPrefix = "telegram:"
	if v, set := lookup(getenv, "A2A_USER_ID_PREFIX"); set {
		if err := validPrefix(v); err != nil {
			return c, fmt.Errorf("A2A_USER_ID_PREFIX: %w", err)
		}
		c.UserIDPrefix = v
	}
	if c.BotToken == "" {
		return c, errors.New("TELEGRAM_BOT_TOKEN is required")
	}
	if c.A2AURL == "" {
		return c, errors.New("A2A_URL is required")
	}
	c.MemoryURL, c.MemoryAgent = getenv("MEMORY_GATE_URL"), getenv("MEMORY_AGENT")
	if (c.MemoryURL == "") != (c.MemoryAgent == "") {
		return c, errors.New("MEMORY_GATE_URL and MEMORY_AGENT must be set together (or both left out)")
	}
	if c.MemoryURL != "" {
		if !strings.HasPrefix(c.MemoryURL, "http://") && !strings.HasPrefix(c.MemoryURL, "https://") {
			return c, errors.New("MEMORY_GATE_URL: must be an http or https URL")
		}
		if ns, name, ok := strings.Cut(c.MemoryAgent, "/"); !ok || ns == "" || name == "" || strings.Contains(name, "/") {
			return c, errors.New("MEMORY_AGENT: must be namespace/name")
		}
		if c.A2ATokenFile == "" && c.A2AToken == "" {
			return c, errors.New("MEMORY_GATE_URL needs A2A_TOKEN_FILE (or A2A_TOKEN): the gate refuses a caller without a token")
		}
	}
	if c.HealthAddr == "" {
		c.HealthAddr = ":8080"
	}
	if c.APIBase == "" {
		c.APIBase = "https://api.telegram.org"
	}
	if v := getenv("AGENT_TIMEOUT"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil || d <= 0 {
			return c, fmt.Errorf("AGENT_TIMEOUT: invalid duration %q", v)
		}
		c.AgentTimeout = d
	}
	switch v := getenv("RETRY_ON_WAKEUP"); v {
	case "":
	case "true":
		c.RetryOnWakeup = true
	case "false":
		c.RetryOnWakeup = false
	default:
		return c, fmt.Errorf("RETRY_ON_WAKEUP: must be true or false, got %q", v)
	}
	if v := getenv("WAKEUP_RETRY_DELAY"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil || d < 0 {
			return c, fmt.Errorf("WAKEUP_RETRY_DELAY: invalid duration %q", v)
		}
		c.WakeupDelay = d
	}
	if v := getenv("MAX_CONCURRENT_TURNS"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			return c, fmt.Errorf("MAX_CONCURRENT_TURNS: invalid count %q", v)
		}
		c.MaxConcurrentTurns = n
	}
	if v := getenv("SHUTDOWN_GRACE"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil || d < 0 {
			return c, fmt.Errorf("SHUTDOWN_GRACE: invalid duration %q", v)
		}
		c.ShutdownGrace = d
	}
	if v := getenv("TELEGRAM_ALLOWED_CHAT_IDS"); strings.TrimSpace(v) != "" {
		for _, part := range strings.Split(v, ",") {
			id, err := strconv.ParseInt(strings.TrimSpace(part), 10, 64)
			if err != nil {
				return c, fmt.Errorf("TELEGRAM_ALLOWED_CHAT_IDS: invalid chat id %q", part)
			}
			c.AllowedChatIDs[id] = true
		}
	}
	switch v := getenv("TELEGRAM_ALLOW_ALL"); v {
	case "", "false":
	case "true":
		c.AllowAll = true
	default:
		return c, fmt.Errorf("TELEGRAM_ALLOW_ALL: must be true or false, got %q", v)
	}
	if len(c.AllowedChatIDs) == 0 && !c.AllowAll {
		return c, errors.New("access control: set TELEGRAM_ALLOWED_CHAT_IDS to a comma-separated list of chat ids, or TELEGRAM_ALLOW_ALL=true to accept every chat")
	}
	return c, nil
}

// lookup treats an empty value as unset (the chart passes an empty string when nothing is configured).
func lookup(getenv func(string) string, k string) (string, bool) { v := getenv(k); return v, v != "" }

// validPrefix keeps the prefix safe as an HTTP header value and a database key: printable ASCII without spaces, at most 64 bytes.
func validPrefix(v string) error {
	if len(v) > 64 {
		return errors.New("longer than 64 characters")
	}
	for _, r := range v {
		if r <= ' ' || r >= 0x7f {
			return fmt.Errorf("character %q not allowed (printable ASCII without spaces only)", r)
		}
	}
	return nil
}
