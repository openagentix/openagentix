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

// The real catalog keeps its profiles under tools.toolhive.profiles, and a profile the operator opened to container agents
// has a workload block (a URL and an audience, which the summary must not carry). The summary says only whether it is open.
func TestSummaryReadsToolhiveProfilesAndContainerRuntime(t *testing.T) {
	dir := t.TempDir()
	f := &Files{
		CatalogPath: write(t, dir, "catalog.json", `{"adapters":{"runtime":"kagent","runtimes":{"builtin":"kagent","container":"container"}},"models":["m"],
			"tools":{"toolhive":{"profiles":[{"name":"open","toolServer":"s","tools":["a"],"workload":{"url":"http://tools.internal/mcp","audience":"aud-secret"}},{"name":"closed","toolServer":"s2","tools":["b"]}]}}}`),
		PolicyPath: write(t, dir, "policy.json", `{"maxAgents":2,"allowedRuntimes":["builtin","container"],"runtimes":{"container":{"images":["ghcr.io/acme/"],"maxAgents":1}}}`),
	}
	b, err := f.Get()
	if err != nil {
		t.Fatal(err)
	}
	s := Summarize(b, false)
	if len(s.Profiles) != 2 || !s.Profiles[0].ContainerAccess || s.Profiles[1].ContainerAccess {
		t.Fatalf("profiles: %+v", s.Profiles)
	}
	c := s.Container
	if !c.Available || !c.Allowed || len(c.Images) != 1 || c.Images[0] != "ghcr.io/acme/" || c.MaxAgents != 1 {
		t.Fatalf("container: %+v", c)
	}
	raw, _ := json.Marshal(s)
	if strings.Contains(string(raw), "aud-secret") || strings.Contains(string(raw), "tools.internal") || strings.Contains(string(raw), `"workload"`) {
		t.Fatalf("summary leaks the workload block: %s", raw)
	}
}

func TestSummaryContainerRuntimeIsOffByDefault(t *testing.T) {
	s := Summarize(Both{Catalog: Catalog{Adapters: Adapters{Runtime: "kagent"}}}, false)
	if s.Container.Available || s.Container.Allowed || s.Container.Images == nil || len(s.Container.Images) != 0 {
		t.Fatalf("%+v", s.Container)
	}
	// allowed by the policy but not installed: the two facts stay apart
	s = Summarize(Both{Policy: Policy{AllowedRuntimes: []string{"container"}}}, false)
	if s.Container.Available || !s.Container.Allowed {
		t.Fatalf("%+v", s.Container)
	}
}
