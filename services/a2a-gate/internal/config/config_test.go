package config

import (
	"strings"
	"testing"
)

func env(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

func TestDefaults(t *testing.T) {
	c, err := Load(env(map[string]string{"A2A_GATE_UPSTREAM": "http://kagent-controller.kagent.svc.cluster.local:8083", "A2A_GATE_RULES": "/r.json"}))
	if err != nil {
		t.Fatal(err)
	}
	if c.Addr != ":8080" || c.Audience != "openagentix-a2a" || c.AuditUserID != "hash" || c.KeysDir != "/etc/a2a-gate/keys" || c.SniffBytes != 64<<10 || c.MaxBody != 8<<20 || c.MaxInFlight != 128 {
		t.Fatalf("%+v", c)
	}
}

func TestOverrides(t *testing.T) {
	c, err := Load(env(map[string]string{
		"A2A_GATE_UPSTREAM": "http://x:1", "A2A_GATE_RULES": "/r.json", "A2A_GATE_ADDR": ":9", "A2A_GATE_AUDIENCE": "aud",
		"A2A_GATE_AUDIT_USER_ID": "raw", "A2A_GATE_KEYS_DIR": "/k", "A2A_GATE_SNIFF_BYTES": "100", "A2A_GATE_MAX_BODY": "2000", "A2A_GATE_MAX_INFLIGHT": "7",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if c.Addr != ":9" || c.Audience != "aud" || c.AuditUserID != "raw" || c.KeysDir != "/k" || c.SniffBytes != 100 || c.MaxBody != 2000 || c.MaxInFlight != 7 {
		t.Fatalf("%+v", c)
	}
}

func TestRoutesConfig(t *testing.T) {
	base := func() map[string]string {
		return map[string]string{"A2A_GATE_UPSTREAM": "http://x:1", "A2A_GATE_RULES": "/r.json"}
	}
	c, err := Load(env(base()))
	if err != nil || c.RoutesFile != "" || c.WorkloadPort != 8080 {
		t.Fatalf("off by default: %+v %v", c, err)
	}
	m := base()
	m["A2A_GATE_ROUTES_FILE"], m["A2A_GATE_WORKLOAD_NAMESPACE"], m["A2A_GATE_PUBLIC_URL"] = "/routes/routes.json", "openagentix-agents", "https://gate.example.com/"
	c, err = Load(env(m))
	if err != nil || c.RoutesFile != "/routes/routes.json" || c.WorkloadNamespace != "openagentix-agents" || c.WorkloadPort != 8080 || c.PublicURL != "https://gate.example.com" {
		t.Fatalf("%+v %v", c, err)
	}
	m["A2A_GATE_WORKLOAD_PORT"] = "9000"
	if c, err = Load(env(m)); err != nil || c.WorkloadPort != 9000 {
		t.Fatalf("%+v %v", c, err)
	}
	bad := map[string]func(map[string]string){
		"no namespace":  func(m map[string]string) { delete(m, "A2A_GATE_WORKLOAD_NAMESPACE") },
		"bad namespace": func(m map[string]string) { m["A2A_GATE_WORKLOAD_NAMESPACE"] = "a.evil.com" },
		"upper ns":      func(m map[string]string) { m["A2A_GATE_WORKLOAD_NAMESPACE"] = "Agents" },
		"bad port":      func(m map[string]string) { m["A2A_GATE_WORKLOAD_PORT"] = "0" },
		"huge port":     func(m map[string]string) { m["A2A_GATE_WORKLOAD_PORT"] = "70000" },
		"text port":     func(m map[string]string) { m["A2A_GATE_WORKLOAD_PORT"] = "http" },
		"no public url": func(m map[string]string) { delete(m, "A2A_GATE_PUBLIC_URL") },
		"ftp url":       func(m map[string]string) { m["A2A_GATE_PUBLIC_URL"] = "ftp://x" },
		"url query":     func(m map[string]string) { m["A2A_GATE_PUBLIC_URL"] = "https://x?a=b" },
		"url userinfo":  func(m map[string]string) { m["A2A_GATE_PUBLIC_URL"] = "https://u:p@x" },
	}
	for name, mut := range bad {
		m := map[string]string{"A2A_GATE_UPSTREAM": "http://x:1", "A2A_GATE_RULES": "/r.json", "A2A_GATE_ROUTES_FILE": "/r", "A2A_GATE_WORKLOAD_NAMESPACE": "ns", "A2A_GATE_PUBLIC_URL": "https://g"}
		mut(m)
		if _, err := Load(env(m)); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
}

func TestErrors(t *testing.T) {
	base := func() map[string]string {
		return map[string]string{"A2A_GATE_UPSTREAM": "http://x:1", "A2A_GATE_RULES": "/r.json"}
	}
	cases := map[string]func(m map[string]string){
		"no upstream":     func(m map[string]string) { delete(m, "A2A_GATE_UPSTREAM") },
		"bad upstream":    func(m map[string]string) { m["A2A_GATE_UPSTREAM"] = "ftp://x" },
		"no rules":        func(m map[string]string) { delete(m, "A2A_GATE_RULES") },
		"bad audit mode":  func(m map[string]string) { m["A2A_GATE_AUDIT_USER_ID"] = "plain" },
		"bad sniff":       func(m map[string]string) { m["A2A_GATE_SNIFF_BYTES"] = "-1" },
		"sniff too large": func(m map[string]string) { m["A2A_GATE_SNIFF_BYTES"] = "99999999" },
		"bad in-flight":   func(m map[string]string) { m["A2A_GATE_MAX_INFLIGHT"] = "0" },
		"huge in-flight":  func(m map[string]string) { m["A2A_GATE_MAX_INFLIGHT"] = "100000" },
		"bad max body":    func(m map[string]string) { m["A2A_GATE_MAX_BODY"] = "abc" },
	}
	for name, mut := range cases {
		m := base()
		mut(m)
		if _, err := Load(env(m)); err == nil {
			t.Errorf("%s: expected an error", name)
		} else if strings.Contains(err.Error(), "\n") {
			t.Errorf("%s: multi-line error", name)
		}
	}
}
