package backend

import (
	"encoding/json"
	"testing"

	"github.com/openagentix/openagentix/services/console/internal/model"
)

// A container agent (ADR 0015) shows its runtime type and isolation, read only; the spec keeps spec.runtime so an update through
// the console never drops it.
func TestBuiltAgentShowsTheRuntimeTypeAndIsolation(t *testing.T) {
	var d Definition
	raw := `{"metadata":{"name":"echo-go","namespace":"kagent"},"spec":{"model":"m","runtime":{"type":"container","container":{"image":"registry.local/oa/echo@sha256:` + "0000000000000000000000000000000000000000000000000000000000000000" + `","port":8080}}},"status":{"capabilities":{"isolation":"container"}}}`
	if err := json.Unmarshal([]byte(raw), &d); err != nil {
		t.Fatal(err)
	}
	a := BuiltAgent(d)
	if a.RuntimeType != "container" || a.Isolation != "container" {
		t.Fatalf("runtime %q isolation %q", a.RuntimeType, a.Isolation)
	}
	b, _ := json.Marshal(d.Spec)
	var back map[string]any
	_ = json.Unmarshal(b, &back)
	if rt, _ := back["runtime"].(map[string]any); rt["type"] != "container" {
		t.Fatalf("spec.runtime was dropped: %s", b)
	}
	var plain Definition
	_ = json.Unmarshal([]byte(`{"metadata":{"name":"a","namespace":"kagent"},"spec":{"model":"m","instructions":"x"}}`), &plain)
	if p := BuiltAgent(plain); p.RuntimeType != "builtin" || p.Isolation != "" {
		t.Fatalf("builtin: %q %q", p.RuntimeType, p.Isolation)
	}
	_ = model.Spec{}
}
