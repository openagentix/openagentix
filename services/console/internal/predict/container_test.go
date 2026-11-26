package predict

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/openagentix/openagentix/services/console/internal/model"
	"github.com/openagentix/openagentix/services/console/internal/platform"
)

const dgst = "@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func containerPlatform() platform.Both {
	var b platform.Both
	must := func(err error) {
		if err != nil {
			panic(err)
		}
	}
	must(json.Unmarshal([]byte(`{"adapters":{"runtime":"kagent","runtimes":{"builtin":"kagent","container":"container"}},
		"models":["m"],"profiles":[{"name":"open","tools":["a"],"workload":{"url":"http://x"}},{"name":"closed","tools":["b"]}]}`), &b.Catalog))
	must(json.Unmarshal([]byte(`{"maxAgents":5,"allowedModels":["m"],"allowedProfiles":["open","closed"],"requireToolProfile":true,
		"allowedRuntimes":["builtin","container"],"runtimes":{"container":{"images":["registry.example.com/agents/"],"maxAgents":2}}}`), &b.Policy))
	return b
}

func ctr(image string, port any, env ...map[string]any) model.Spec {
	c := map[string]any{"image": image, "port": port}
	if len(env) > 0 {
		e := make([]any, len(env))
		for i, x := range env {
			e[i] = x
		}
		c["env"] = e
	}
	return model.Spec{Model: "m", Runtime: map[string]any{"type": "container", "container": c}}
}

func run(s model.Spec, mut ...func(*Input)) []model.Prediction {
	in := Input{Name: "mine", Spec: s, P: containerPlatform()}
	for _, m := range mut {
		m(&in)
	}
	return Check(in)
}

func hasP(ps []model.Prediction, field, sub string) bool {
	for _, p := range ps {
		if p.Field == field && strings.Contains(p.Message, sub) {
			return true
		}
	}
	return false
}

const goodImg = "registry.example.com/agents/echo" + dgst

func TestContainerAgentThatFollowsTheRulesHasNoPrediction(t *testing.T) {
	// no instructions and no profile: a container agent needs neither, even with requireToolProfile on
	if got := run(ctr(goodImg, float64(8080))); len(got) != 0 {
		t.Fatalf("%v", got)
	}
	s := ctr(goodImg, 8080)
	s.ToolProfile = "open"
	if got := run(s); len(got) != 0 {
		t.Fatalf("%v", got)
	}
}

func TestContainerImageMustBeADigestUnderAnAllowedPrefix(t *testing.T) {
	if got := run(ctr("registry.example.com/agents/echo:1.0", 8080)); !hasP(got, "runtime.container.image", "must be pinned by digest") {
		t.Fatalf("tag: %v", got)
	}
	if got := run(ctr("registry.example.com/agents/echo:1.0"+dgst, 8080)); !hasP(got, "runtime.container.image", "must be pinned by digest") {
		t.Fatalf("tag next to digest: %v", got)
	}
	if got := run(ctr("", 8080)); !hasP(got, "runtime.container.image", "must be pinned by digest") {
		t.Fatalf("empty: %v", got)
	}
	if got := run(ctr("evil.example.com/x"+dgst, 8080)); !hasP(got, "runtime.container.image", "not under a registry prefix the platform policy allows") {
		t.Fatalf("prefix: %v", got)
	}
}

func TestContainerPortAndEnv(t *testing.T) {
	if got := run(ctr(goodImg, 80)); !hasP(got, "runtime.container.port", "between 1024 and 65535") {
		t.Fatalf("%v", got)
	}
	if got := run(ctr(goodImg, "x")); !hasP(got, "runtime.container.port", "between 1024 and 65535") {
		t.Fatalf("%v", got)
	}
	env := func(n, v string) map[string]any { return map[string]any{"name": n, "value": v} }
	cases := []struct {
		name, sub string
		env       []map[string]any
	}{
		{"lower", "must match", []map[string]any{env("log_level", "x")}},
		{"reserved", "is reserved", []map[string]any{env("OPENAI_BASE_URL", "x")}},
		{"twice", "sets LOG twice", []map[string]any{env("LOG", "a"), env("LOG", "b")}},
		{"secret", "shaped like a secret", []map[string]any{env("TOKEN", "sk-"+strings.Repeat("a", 40))}},
		{"long", "at most 4096", []map[string]any{env("BIG", strings.Repeat("a", 4097))}},
	}
	for _, c := range cases {
		if got := run(ctr(goodImg, 8080, c.env...)); !hasP(got, "runtime.container.env", c.sub) {
			t.Errorf("%s: %v", c.name, got)
		}
	}
	many := make([]map[string]any, 33)
	for i := range many {
		many[i] = env("V"+strings.Repeat("A", i+1), "x")
	}
	if got := run(ctr(goodImg, 8080, many...)); !hasP(got, "runtime.container.env", "at most 32") {
		t.Fatalf("%v", got)
	}
}

func TestContainerRuntimeMustBeAllowedAndAvailable(t *testing.T) {
	got := run(ctr(goodImg, 8080), func(in *Input) { in.P.Policy.AllowedRuntimes = nil })
	if !hasP(got, "runtime", "runtime container is not allowed by the platform policy") {
		t.Fatalf("%v", got)
	}
	got = run(ctr(goodImg, 8080), func(in *Input) { in.P.Catalog.Adapters.Runtimes = nil })
	if !hasP(got, "runtime", "runtime container is not available on this platform") {
		t.Fatalf("%v", got)
	}
	s := ctr(goodImg, 8080)
	s.Runtime["type"] = "sandbox"
	if got := run(s); !hasP(got, "runtime", `runtime.type "sandbox" is not known`) {
		t.Fatalf("%v", got)
	}
	s = model.Spec{Model: "m", Instructions: "x", ToolProfile: "open", Runtime: map[string]any{"type": "builtin", "container": map[string]any{"image": goodImg, "port": 8080}}}
	if got := run(s); !hasP(got, "runtime", "runtime.container is set but runtime.type is builtin") {
		t.Fatalf("%v", got)
	}
}

func TestContainerAgentRefusesBuiltinOnlyFeatures(t *testing.T) {
	s := ctr(goodImg, 8080)
	s.Instructions = "be nice"
	s.Tools = []string{"a"}
	s.Egress = &model.Egress{Allow: []string{"https://x.example"}}
	s.Memory = &model.Memory{Enabled: true}
	s.Knowledge = &model.Feature{Enabled: true}
	s.Notify = &model.Feature{Enabled: true}
	s.Skills = []model.Skill{{Name: "s"}}
	got := run(s)
	for f, sub := range map[string]string{
		"instructions": "do not apply to a container agent", "tools": "cannot be listed for a container agent", "egress.allow": "not available yet for container agents",
		"memory": "memory is not available for container agents", "knowledge": "knowledge is not available for container agents",
		"notify": "notify is not available for container agents", "skills": "skills are not available for container agents",
	} {
		if !hasP(got, f, sub) {
			t.Errorf("%s: %v", f, got)
		}
	}
}

func TestContainerToolProfile(t *testing.T) {
	s := ctr(goodImg, 8080)
	s.ToolProfile = "closed"
	if got := run(s); !hasP(got, "toolProfile", "is not open to container agents") {
		t.Fatalf("%v", got)
	}
	s.ToolProfile = "nope"
	if got := run(s); !hasP(got, "toolProfile", "is not defined") {
		t.Fatalf("%v", got)
	}
	s.ToolProfile = "open"
	if got := run(s, func(in *Input) { in.P.Policy.AllowedProfiles = []string{"closed"} }); !hasP(got, "toolProfile", "not allowed by the platform policy") {
		t.Fatalf("%v", got)
	}
}

func TestContainerModelAndCounts(t *testing.T) {
	s := ctr(goodImg, 8080)
	s.Model = "other"
	if got := run(s); !hasP(got, "model", "not in the platform catalog") {
		t.Fatalf("%v", got)
	}
	if got := run(ctr(goodImg, 8080), func(in *Input) { in.OthersContainer = 2 }); !hasP(got, "name", "at most 2 container agents") {
		t.Fatalf("%v", got)
	}
	if got := run(ctr(goodImg, 8080), func(in *Input) { in.Others = 5 }); !hasP(got, "name", "at most 5 agents") {
		t.Fatalf("%v", got)
	}
}
