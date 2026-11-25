package platform

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func write(t *testing.T, dir, name, body string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

// The policy's stop switch and the in-cluster exceptions are in the policy file, and the Governance and Overview pages
// show them: they must reach the summary, and the summary must still hold nothing the runtime adapter alone needs.
func TestSummaryCarriesSuspendAllAndInClusterDestinations(t *testing.T) {
	dir := t.TempDir()
	f := &Files{
		CatalogPath: write(t, dir, "catalog.json", `{"models":["m"],"gateUrl":"http://gate","harnessImage":"ghcr.io/x@sha256:0","skills":{"s":"r"}}`),
		PolicyPath:  write(t, dir, "policy.json", `{"maxAgents":2,"suspendAll":true,"egress":{"allowedOrigins":["https://a.example"],"inClusterDestinations":["registry.ci.svc:5000"]}}`),
	}
	b, err := f.Get()
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(Summarize(b, false))
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	pol := got["policy"].(map[string]any)
	if pol["suspendAll"] != true {
		t.Fatalf("policy.suspendAll missing: %s", raw)
	}
	if d := pol["egress"].(map[string]any)["inClusterDestinations"].([]any); len(d) != 1 || d[0] != "registry.ci.svc:5000" {
		t.Fatalf("inClusterDestinations: %v", d)
	}
	if got["gateEnabled"] != true {
		t.Fatalf("gateEnabled: %s", raw)
	}
	if strings.Contains(string(raw), "harnessImage") || strings.Contains(string(raw), "ghcr.io") || strings.Contains(string(raw), "gate.") {
		t.Fatalf("summary leaks catalog internals: %s", raw)
	}
}
