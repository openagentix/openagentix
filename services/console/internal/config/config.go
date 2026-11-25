// Package config loads the console's settings from environment variables.
package config

import (
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var nsRE = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$`)

const (
	saDir         = "/var/run/secrets/kubernetes.io/serviceaccount"
	DemoToken     = "demo-token"
	defaultKagent = "api.kagent.dev/v1alpha3"
)

// Config holds all settings.
type Config struct {
	Addr           string
	TokenFile      string
	CatalogFile    string
	PolicyFile     string
	Namespace      string // empty: the catalog's agents namespace
	Viewer         bool
	KubeAPI        string
	KubeTokenFile  string
	KubeCAFile     string
	KagentAPI      string
	Context        string
	RequestTimeout time.Duration
	LogLevel       string

	DevFake       bool
	DevFakeSettle time.Duration

	// AllowedHosts are Host names accepted besides localhost, 127.0.0.1 and [::1] (CONSOLE_ALLOWED_HOSTS).
	AllowedHosts        []string
	AuthFailLimit       int    // failed sign-ins per address per minute before 429 (default 10)
	AuthFailLimitGlobal int    // the same over all addresses (default 100)
	ValidatePerMinute   int    // POST /agents/validate per identity per minute (default 60)
	HSTS                bool   // send Strict-Transport-Security
	MetricsURL          string // CONSOLE_METRICS_URL: base URL of a Prometheus-compatible query API; empty: no metrics
	TracesURL           string // CONSOLE_TRACES_URL: base URL of the Jaeger query API; empty: no traces
	SchedulesNamespace  string // CONSOLE_SCHEDULES_NAMESPACE: where the chart's schedule CronJobs are; empty: the Schedules page says so
	GateNamespace       string // CONSOLE_GATE_NAMESPACE: where the A2A gate's rules ConfigMap is; empty: the Access page says so
	ListMax             int    // most objects of one kind a list reads (default 500)
	AllowInsecureKube   bool   // dev only: accept an http:// Kubernetes API address
}

const (
	// MinTokenLen is the shortest console token the real mode starts with.
	MinTokenLen = 32
)

func intEnv(getenv func(string) string, key string, def, min, max int) (int, error) {
	v := getenv(key)
	if v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil || n < min || n > max {
		return 0, fmt.Errorf("%s must be a whole number between %d and %d", key, min, max)
	}
	return n, nil
}

func truthy(v string) bool {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "1", "true", "yes", "on":
		return true
	}
	return false
}

func or(v, d string) string {
	if v != "" {
		return v
	}
	return d
}

// Load reads configuration using getenv (for example os.Getenv).
func Load(getenv func(string) string) (Config, error) {
	c := Config{
		Addr: getenv("CONSOLE_ADDR"), TokenFile: getenv("CONSOLE_TOKEN_FILE"), CatalogFile: getenv("CONSOLE_CATALOG_FILE"),
		PolicyFile: getenv("CONSOLE_POLICY_FILE"), Namespace: getenv("CONSOLE_NAMESPACE"), Viewer: truthy(getenv("CONSOLE_VIEWER")),
		KubeAPI: getenv("CONSOLE_KUBE_API"), KubeTokenFile: or(getenv("CONSOLE_KUBE_TOKEN_FILE"), saDir+"/token"),
		KubeCAFile: getenv("CONSOLE_KUBE_CA_FILE"), KagentAPI: or(getenv("CONSOLE_KAGENT_API"), defaultKagent),
		Context: getenv("CONSOLE_CONTEXT"), RequestTimeout: 15 * time.Second, LogLevel: or(getenv("CONSOLE_LOG_LEVEL"), "info"),
		DevFake: truthy(getenv("CONSOLE_DEV_FAKE")), DevFakeSettle: 8 * time.Second,
	}
	var err error
	if c.AuthFailLimit, err = intEnv(getenv, "CONSOLE_AUTH_FAIL_LIMIT", 10, 1, 1000); err != nil {
		return c, err
	}
	if c.AuthFailLimitGlobal, err = intEnv(getenv, "CONSOLE_AUTH_FAIL_LIMIT_GLOBAL", 100, 1, 100000); err != nil {
		return c, err
	}
	if c.ValidatePerMinute, err = intEnv(getenv, "CONSOLE_VALIDATE_PER_MINUTE", 60, 1, 10000); err != nil {
		return c, err
	}
	if c.MetricsURL, err = urlEnv(getenv, "CONSOLE_METRICS_URL"); err != nil {
		return Config{}, err
	}
	if c.TracesURL, err = urlEnv(getenv, "CONSOLE_TRACES_URL"); err != nil {
		return Config{}, err
	}
	if c.ListMax, err = intEnv(getenv, "CONSOLE_LIST_MAX", 500, 1, 5000); err != nil {
		return c, err
	}
	for _, e := range []struct {
		dst  *string
		name string
	}{{&c.SchedulesNamespace, "CONSOLE_SCHEDULES_NAMESPACE"}, {&c.GateNamespace, "CONSOLE_GATE_NAMESPACE"}} {
		v := strings.TrimSpace(getenv(e.name))
		if v != "" && !nsRE.MatchString(v) {
			return c, fmt.Errorf("%s must be a namespace name (lower case letters, digits and '-')", e.name)
		}
		*e.dst = v
	}
	c.HSTS, c.AllowInsecureKube = truthy(getenv("CONSOLE_HSTS")), truthy(getenv("CONSOLE_ALLOW_INSECURE_KUBE_API"))
	for _, h := range strings.Split(getenv("CONSOLE_ALLOWED_HOSTS"), ",") {
		if h = strings.TrimSpace(h); h == "" {
			continue
		}
		if strings.ContainsAny(h, "/ \t@?#") {
			return c, errors.New("CONSOLE_ALLOWED_HOSTS is a comma-separated list of host names (with an optional :port), not URLs")
		}
		c.AllowedHosts = append(c.AllowedHosts, h)
	}
	if v := getenv("CONSOLE_REQUEST_TIMEOUT"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil || d < time.Second || d > 5*time.Minute {
			return c, errors.New("CONSOLE_REQUEST_TIMEOUT must be a duration between 1s and 5m")
		}
		c.RequestTimeout = d
	}
	if v := getenv("CONSOLE_DEV_FAKE_SETTLE"); v != "" {
		s, err := strconv.Atoi(v)
		if err != nil || s < 0 {
			return c, errors.New("CONSOLE_DEV_FAKE_SETTLE must be a number of seconds, 0 or more")
		}
		c.DevFakeSettle = time.Duration(s) * time.Second
	}

	if c.DevFake {
		// A demo console must never be one that could be pointed at a cluster by accident.
		var clash []string
		for _, k := range []string{"CONSOLE_KUBE_API", "CONSOLE_CATALOG_FILE", "CONSOLE_POLICY_FILE", "CONSOLE_KUBE_TOKEN_FILE", "CONSOLE_KUBE_CA_FILE", "KUBERNETES_SERVICE_HOST"} {
			if getenv(k) != "" {
				clash = append(clash, k)
			}
		}
		if len(clash) > 0 {
			return c, fmt.Errorf("CONSOLE_DEV_FAKE is set together with real cluster settings (%s); the demo mode refuses to start so that fake data is never shown for a real cluster", strings.Join(clash, ", "))
		}
		c.Addr = or(c.Addr, "127.0.0.1:8080")
		c.Namespace = or(c.Namespace, "kagent")
		c.Context = or(c.Context, "demo · kagent")
		return c, nil
	}

	c.Addr = or(c.Addr, ":8080")
	if c.TokenFile == "" {
		return c, errors.New("CONSOLE_TOKEN_FILE is required")
	}
	if c.CatalogFile == "" || c.PolicyFile == "" {
		return c, errors.New("CONSOLE_CATALOG_FILE and CONSOLE_POLICY_FILE are required")
	}
	if c.KubeAPI == "" {
		h, p := getenv("KUBERNETES_SERVICE_HOST"), or(getenv("KUBERNETES_SERVICE_PORT"), "443")
		if h == "" {
			return c, errors.New("CONSOLE_KUBE_API is required outside a cluster (KUBERNETES_SERVICE_HOST is not set)")
		}
		if strings.Contains(h, ":") {
			h = "[" + h + "]"
		}
		c.KubeAPI = "https://" + h + ":" + p
		c.KubeCAFile = or(c.KubeCAFile, saDir+"/ca.crt")
	}
	switch {
	case strings.HasPrefix(c.KubeAPI, "https://"):
	case strings.HasPrefix(c.KubeAPI, "http://") && c.AllowInsecureKube:
	case strings.HasPrefix(c.KubeAPI, "http://"):
		return c, errors.New("CONSOLE_KUBE_API must be an https URL: the ServiceAccount token is sent with every request and must not cross the network in clear text. For a local development API server only, set CONSOLE_ALLOW_INSECURE_KUBE_API=1")
	default:
		return c, errors.New("CONSOLE_KUBE_API must be an https URL")
	}
	return c, nil
}

// urlEnv reads an optional http or https base URL (no user info, no query).
func urlEnv(getenv func(string) string, name string) (string, error) {
	v := strings.TrimSpace(getenv(name))
	if v == "" {
		return "", nil
	}
	u, err := url.Parse(v)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", fmt.Errorf("%s must be an http or https URL without credentials or query", name)
	}
	return v, nil
}
