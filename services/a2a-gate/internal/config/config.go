// Package config loads the gate's settings from environment variables. The per-caller rules are not here: they are
// in the file named by A2A_GATE_RULES (package rules).
package config

import (
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

// Config holds all settings.
type Config struct {
	Addr        string
	Upstream    string
	Audience    string
	RulesPath   string
	KeysDir     string
	AuditUserID string // hash | raw
	SniffBytes  int
	MaxBody     int64
	MaxInFlight int // requests handled at once; the next gets 503
	LogLevel    string

	// Bring your own A2A agent: all empty/zero (feature off) unless RoutesFile is set.
	RoutesFile        string // A2A_GATE_ROUTES_FILE, written by the controller
	WorkloadNamespace string // A2A_GATE_WORKLOAD_NAMESPACE, a DNS label
	WorkloadPort      int    // A2A_GATE_WORKLOAD_PORT, default 8080
	PublicURL         string // A2A_GATE_PUBLIC_URL, the address clients use for the gate
}

var dnsLabel = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$`)

// MaxSniffBytes is the ceiling of A2A_GATE_SNIFF_BYTES: the gate must never buffer a large part of a request.
const MaxSniffBytes = 1 << 20

// Load reads configuration using getenv (e.g. os.Getenv).
func Load(getenv func(string) string) (Config, error) {
	c := Config{
		Addr:        or(getenv("A2A_GATE_ADDR"), ":8080"),
		Upstream:    getenv("A2A_GATE_UPSTREAM"),
		Audience:    or(getenv("A2A_GATE_AUDIENCE"), "openagentix-a2a"),
		RulesPath:   getenv("A2A_GATE_RULES"),
		KeysDir:     or(getenv("A2A_GATE_KEYS_DIR"), "/etc/a2a-gate/keys"),
		AuditUserID: or(getenv("A2A_GATE_AUDIT_USER_ID"), "hash"),
		SniffBytes:  64 << 10,
		MaxBody:     8 << 20,
		MaxInFlight: 128,
		LogLevel:    or(getenv("A2A_GATE_LOG_LEVEL"), "info"),

		RoutesFile:        getenv("A2A_GATE_ROUTES_FILE"),
		WorkloadNamespace: getenv("A2A_GATE_WORKLOAD_NAMESPACE"),
		WorkloadPort:      8080,
	}
	u, err := url.Parse(c.Upstream)
	if c.Upstream == "" || err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return c, errors.New("A2A_GATE_UPSTREAM must be an http or https URL")
	}
	if c.RulesPath == "" {
		return c, errors.New("A2A_GATE_RULES is required")
	}
	if c.AuditUserID != "hash" && c.AuditUserID != "raw" {
		return c, fmt.Errorf("A2A_GATE_AUDIT_USER_ID must be hash or raw, got %q", c.AuditUserID)
	}
	if v := getenv("A2A_GATE_SNIFF_BYTES"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 || n > MaxSniffBytes {
			return c, fmt.Errorf("A2A_GATE_SNIFF_BYTES must be 1..%d", MaxSniffBytes)
		}
		c.SniffBytes = n
	}
	if v := getenv("A2A_GATE_MAX_INFLIGHT"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 10000 {
			return c, errors.New("A2A_GATE_MAX_INFLIGHT must be 1..10000")
		}
		c.MaxInFlight = n
	}
	if v := getenv("A2A_GATE_MAX_BODY"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n <= 0 {
			return c, errors.New("A2A_GATE_MAX_BODY must be a positive number of bytes")
		}
		c.MaxBody = n
	}
	if c.RoutesFile != "" {
		if !dnsLabel.MatchString(c.WorkloadNamespace) {
			return c, errors.New("A2A_GATE_WORKLOAD_NAMESPACE must be a DNS label when A2A_GATE_ROUTES_FILE is set")
		}
		if v := getenv("A2A_GATE_WORKLOAD_PORT"); v != "" {
			n, err := strconv.Atoi(v)
			if err != nil || n < 1 || n > 65535 {
				return c, errors.New("A2A_GATE_WORKLOAD_PORT must be 1..65535")
			}
			c.WorkloadPort = n
		}
		pu, err := url.Parse(getenv("A2A_GATE_PUBLIC_URL"))
		if err != nil || (pu.Scheme != "http" && pu.Scheme != "https") || pu.Host == "" || pu.User != nil ||
			pu.RawQuery != "" || pu.ForceQuery || pu.Fragment != "" {
			return c, errors.New("A2A_GATE_PUBLIC_URL must be an http or https URL without credentials, query or fragment when A2A_GATE_ROUTES_FILE is set")
		}
		c.PublicURL = strings.TrimRight(pu.String(), "/")
	}
	return c, nil
}

func or(v, d string) string {
	if v != "" {
		return v
	}
	return d
}
