package config

import "testing"

func TestWorkloadLimits(t *testing.T) {
	base := map[string]string{
		"A2A_GATE_UPSTREAM": "http://x:1", "A2A_GATE_RULES": "/r.json",
		"A2A_GATE_ROUTES_FILE": "/routes.json", "A2A_GATE_WORKLOAD_NAMESPACE": "workloads", "A2A_GATE_PUBLIC_URL": "https://gate.example.com",
	}
	with := func(kv ...string) map[string]string {
		m := map[string]string{}
		for k, v := range base {
			m[k] = v
		}
		for i := 0; i < len(kv); i += 2 {
			m[kv[i]] = kv[i+1]
		}
		return m
	}
	c, err := Load(env(with()))
	if err != nil {
		t.Fatal(err)
	}
	if c.WorkloadHeaderTimeoutSeconds != 300 || c.WorkloadMaxInFlight != 32 {
		t.Errorf("defaults: %d s, %d", c.WorkloadHeaderTimeoutSeconds, c.WorkloadMaxInFlight)
	}
	c, err = Load(env(with("A2A_GATE_WORKLOAD_HEADER_TIMEOUT_SECONDS", "900", "A2A_GATE_WORKLOAD_MAX_INFLIGHT", "8")))
	if err != nil || c.WorkloadHeaderTimeoutSeconds != 900 || c.WorkloadMaxInFlight != 8 {
		t.Fatalf("set: %+v %v", c, err)
	}
	for name, kv := range map[string][]string{
		"timeout zero":     {"A2A_GATE_WORKLOAD_HEADER_TIMEOUT_SECONDS", "0"},
		"timeout text":     {"A2A_GATE_WORKLOAD_HEADER_TIMEOUT_SECONDS", "5m"},
		"timeout too long": {"A2A_GATE_WORKLOAD_HEADER_TIMEOUT_SECONDS", "100000"},
		"cap zero":         {"A2A_GATE_WORKLOAD_MAX_INFLIGHT", "0"},
		"cap text":         {"A2A_GATE_WORKLOAD_MAX_INFLIGHT", "many"},
	} {
		if _, err := Load(env(with(kv...))); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}
