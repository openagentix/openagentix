package server_test

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/openagentix/openagentix/services/console/internal/model"
	"github.com/openagentix/openagentix/services/console/internal/platform"
)

// The demo policy allows container agents from this registry prefix (services/console/internal/fake/testdata/policy.json).
const goodImage = "registry.example.com/agents/echo@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func containerSpec(image string) map[string]any {
	return map[string]any{
		"model":       "claude-haiku",
		"description": "My own agent",
		"runtime":     map[string]any{"type": "container", "container": map[string]any{"image": image, "port": 8080, "env": []any{map[string]any{"name": "LOG_LEVEL", "value": "info"}}}},
	}
}

func writes(r *rig) int {
	n := 0
	for _, q := range r.api.requests() {
		if (q.Method == "POST" || q.Method == "PUT") && !strings.Contains(q.Query, "dryRun=All") {
			n++
		}
	}
	return n
}

func TestCreateContainerAgentSendsRuntimeAndNoInstructions(t *testing.T) {
	r := newRig(t)
	resp, b := r.do(t, "POST", "/api/v1/agents", map[string]any{"name": "echo", "spec": containerSpec(goodImage)})
	if resp.StatusCode != 201 {
		t.Fatal(resp.Status, string(b))
	}
	d := decodeInto[model.Detail](t, b)
	if d.RuntimeType != "container" {
		t.Fatalf("runtimeType %q", d.RuntimeType)
	}
	stored := r.api.defs["echo"]["spec"].(map[string]any)
	if _, has := stored["instructions"]; has {
		t.Fatalf("a container agent must not carry an empty instructions field: %v", stored)
	}
	rt := stored["runtime"].(map[string]any)
	if rt["type"] != "container" || rt["container"].(map[string]any)["image"] != goodImage {
		t.Fatalf("runtime: %v", rt)
	}
	if !strings.Contains(d.YAML, "runtime:") || !strings.Contains(d.YAML, goodImage) || !strings.Contains(d.YAML, "LOG_LEVEL") {
		t.Fatalf("yaml does not show the runtime:\n%s", d.YAML)
	}
	if strings.Contains(d.YAML, "instructions") {
		t.Fatalf("yaml shows an empty instructions block:\n%s", d.YAML)
	}
}

// No create without the checks passing: the server runs the same rules as validate before it writes anything.
func TestCreateContainerAgentIsRefusedBeforeAnyWriteWhenTheRulesFail(t *testing.T) {
	cases := map[string]map[string]any{
		"a tag instead of a digest":    containerSpec("registry.example.com/agents/echo:1.0"),
		"an image of another registry": containerSpec("evil.example.com/x@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"),
	}
	badPort := containerSpec(goodImage)
	badPort["runtime"].(map[string]any)["container"].(map[string]any)["port"] = 80
	cases["a port below 1024"] = badPort
	withPrompt := containerSpec(goodImage)
	withPrompt["instructions"] = "be nice"
	cases["instructions"] = withPrompt
	for name, sp := range cases {
		r := newRig(t)
		resp, b := r.do(t, "POST", "/api/v1/agents", map[string]any{"name": "echo", "spec": sp})
		if resp.StatusCode != 422 || errCode(t, b) != "invalid" {
			t.Errorf("%s: %s %s", name, resp.Status, b)
		}
		if !strings.Contains(string(b), "container") {
			t.Errorf("%s: the message does not say what is wrong: %s", name, b)
		}
		if n := writes(r); n != 0 {
			t.Errorf("%s: %d write(s) reached the cluster", name, n)
		}
	}
}

func TestCreateContainerAgentIsRefusedWhenThePolicyDoesNotAllowTheRuntime(t *testing.T) {
	r := newRig(t, func(o *rigOpt) { o.noContainers = true })
	resp, b := r.do(t, "POST", "/api/v1/agents", map[string]any{"name": "echo", "spec": containerSpec(goodImage)})
	if resp.StatusCode != 422 || !strings.Contains(string(b), "runtime container is not allowed by the platform policy") {
		t.Fatal(resp.Status, string(b))
	}
	if writes(r) != 0 {
		t.Fatal("a write reached the cluster")
	}
}

func TestValidateContainerAgent(t *testing.T) {
	r := newRig(t)
	resp, b := r.do(t, "POST", "/api/v1/agents/validate", map[string]any{"name": "echo", "spec": containerSpec(goodImage)})
	if resp.StatusCode != 200 {
		t.Fatal(resp.Status, string(b))
	}
	v := decodeInto[model.ValidateResult](t, b)
	if !v.Schema.OK || len(v.Predicted) != 0 {
		t.Fatalf("%+v", v)
	}
	_, b = r.do(t, "POST", "/api/v1/agents/validate", map[string]any{"name": "echo", "spec": containerSpec("registry.example.com/agents/echo:1")})
	v = decodeInto[model.ValidateResult](t, b)
	if len(v.Predicted) != 1 || v.Predicted[0].Field != "runtime.container.image" || !strings.Contains(v.Predicted[0].Message, "must be pinned by digest") {
		t.Fatalf("%+v", v.Predicted)
	}
	if writes(r) != 0 {
		t.Fatal("validate wrote something")
	}
}

func TestPlatformTellsTheBuilderAboutContainerAgentsWithoutTheWorkloadBlock(t *testing.T) {
	r := newRig(t)
	_, b := r.do(t, "GET", "/api/v1/platform", nil)
	var got struct {
		Container platform.ContainerInfo `json:"container"`
		Profiles  []map[string]any       `json:"profiles"`
	}
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	if !got.Container.Available || !got.Container.Allowed || len(got.Container.Images) != 1 || got.Container.Images[0] != "registry.example.com/agents/" {
		t.Fatalf("%+v", got.Container)
	}
	open := 0
	for _, p := range got.Profiles {
		if p["containerAccess"] == true {
			open++
		}
		if _, leaked := p["workload"]; leaked {
			t.Fatalf("workload block leaked: %v", p)
		}
	}
	if open != 1 {
		t.Fatalf("profiles open to container agents: %d (%s)", open, b)
	}
}
