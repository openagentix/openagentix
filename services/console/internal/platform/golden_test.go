package platform

import (
	"encoding/json"
	"os"
	"testing"
)

// The golden files are the catalog and policy the control plane's own tests load (services/control-plane/testdata) and
// the chart renders (charts/openagentix/tests/run.sh compares the render to them). The console must read the real
// shape: a flat shape that only a fixture used left the builder with no tool profile at all.
func TestGoldenCatalogIsReadInItsRealShape(t *testing.T) {
	f := &Files{CatalogPath: "testdata/catalog.json", PolicyPath: "testdata/policy.json"}
	b, err := f.Get()
	if err != nil {
		t.Fatal(err)
	}
	s := Summarize(b, false)
	if len(s.Profiles) != 1 || s.Profiles[0].Name != "lookup" || s.Profiles[0].ToolServer != "toolhive-vmcp-lookup" || !s.Profiles[0].CodeMode || len(s.Profiles[0].Tools) != 4 {
		t.Fatalf("profiles: %+v", s.Profiles)
	}
	if !s.Knowledge.Available || len(s.Knowledge.Tools) == 0 || s.Knowledge.Prompt == "" {
		t.Fatalf("knowledge: %+v", s.Knowledge)
	}
	if !s.Notify.Available || len(s.Notify.Tools) == 0 {
		t.Fatalf("notify: %+v", s.Notify)
	}
	if !s.Memory.Available || !s.Memory.ExpiryEnabled || s.Memory.DefaultTTLDays != 15 || s.Memory.Prompt == "" {
		t.Fatalf("memory: %+v", s.Memory)
	}
	if len(s.Skills) != 1 || s.Skills[0].Name != "openagentix-canary" || s.Skills[0].Ref == "" {
		t.Fatalf("skills: %+v", s.Skills)
	}
	if s.Adapters.Runtime != "kagent" || s.Adapters.ModelGateway != "agentgateway" || s.Adapters.Tools != "toolhive" {
		t.Fatalf("adapters: %+v", s.Adapters)
	}
	if s.Namespaces.Agents != "kagent" || s.Namespaces.Tools != "mcp-tools" || s.Namespaces.Gateway == "" || s.GatewayBaseURL == "" || !s.GateEnabled {
		t.Fatalf("namespaces or gateway: %+v", s)
	}
	if len(s.Models) != 1 || len(s.ReservedNames) == 0 {
		t.Fatalf("models %v reserved %v", s.Models, s.ReservedNames)
	}
	if !s.Policy.RequireToolProfile || len(s.Policy.AllowedProfiles) != 1 {
		t.Fatalf("policy: %+v", s.Policy)
	}
}

// The controller reads the single entry "*" as "everything the catalog has" (values.yaml, controlPlane.policy). The
// console's prediction and builder must do the same, or a platform opened with "*" shows every choice as refused.
func TestPolicyWildcardAllowsEverything(t *testing.T) {
	p := Policy{AllowedModels: []string{"*"}, AllowedProfiles: []string{"*"}, AllowedSkills: []string{"*"}}
	if !p.ModelAllowed("m") || !p.ProfileAllowed("p") || !p.SkillAllowed("s") {
		t.Fatal("the entry * must allow any name")
	}
	if (Policy{}).ModelAllowed("m") || (Policy{AllowedModels: []string{"x"}}).ModelAllowed("m") {
		t.Fatal("an empty or other list allows nothing else")
	}
}

// Every top-level key of the golden catalog is either read by the console or named here as deliberately ignored, so a
// new key in the control plane's catalog cannot be dropped without a decision.
func TestGoldenCatalogKeysAreAllAccountedFor(t *testing.T) {
	raw, err := os.ReadFile("testdata/catalog.json")
	if err != nil {
		t.Fatal(err)
	}
	var top map[string]json.RawMessage
	if err := json.Unmarshal(raw, &top); err != nil {
		t.Fatal(err)
	}
	handled := map[string]bool{"adapters": true, "namespaces": true, "gatewayBaseUrl": true, "models": true, "tools": true,
		"knowledge": true, "notify": true, "memory": true, "skills": true, "gateUrl": true, "reservedNames": true,
		"runtime": true} // runtime is adapter-owned: the console deliberately does not copy it
	for k := range top {
		if !handled[k] {
			t.Errorf("catalog key %q is not handled by the console reader", k)
		}
	}
}
