package policy

import (
	"strings"
	"testing"

	"github.com/openagentix/openagentix/services/control-plane/internal/api"
	"github.com/openagentix/openagentix/services/control-plane/internal/catalog"
)

const goodImage = "ghcr.io/acme/agents/echo@sha256:0000000000000000000000000000000000000000000000000000000000000000"

// containerGood is a container agent the default test platform accepts once the catalog and the policy opt in.
func containerGood() *api.AgentDefinition {
	return &api.AgentDefinition{
		APIVersion: api.APIVersion, Kind: api.Kind,
		Metadata: api.ObjectMeta{Name: "echo", Namespace: "kagent"},
		Spec: api.Spec{
			Description: "echoes", Model: "claude-haiku",
			Runtime: api.Runtime{Type: api.RuntimeContainer, Container: &api.ContainerRuntime{
				Image: goodImage, Port: 8080, Env: []api.EnvVar{{Name: "LOG_LEVEL", Value: "info"}},
			}},
		},
	}
}

// optIn makes the platform offer and allow the container runtime.
func optIn(c *catalog.Catalog, p *catalog.Policy) {
	c.Adapters.Runtimes = map[string]string{"builtin": "kagent", "container": "container"}
	p.AllowedRuntimes = []string{"builtin", "container"}
	p.Runtimes.Container = catalog.PolicyContainerRuntime{Images: []string{"ghcr.io/acme/agents/"}, MaxAgents: 2}
}

func runC(t *testing.T, mutate func(*api.AgentDefinition, *catalog.Catalog, *catalog.Policy)) []string {
	t.Helper()
	c, p := load(t)
	optIn(c, p)
	d := containerGood()
	if mutate != nil {
		mutate(d, c, p)
	}
	return Validate(Input{Def: d, Catalog: c, Policy: p, Tools: fakeTools{c}})
}

func TestContainerAgentIsAccepted(t *testing.T) {
	if v := runC(t, nil); len(v) != 0 {
		t.Fatalf("%v", v)
	}
	// requireToolProfile does not apply to a container agent (it gets no profile in this release)
	if v := runC(t, func(d *api.AgentDefinition, c *catalog.Catalog, p *catalog.Policy) { p.RequireToolProfile = true }); len(v) != 0 {
		t.Fatalf("%v", v)
	}
}

func TestRuntimeRefusals(t *testing.T) {
	d := func(f func(*api.ContainerRuntime)) func(*api.AgentDefinition, *catalog.Catalog, *catalog.Policy) {
		return func(a *api.AgentDefinition, c *catalog.Catalog, p *catalog.Policy) { f(a.Spec.Runtime.Container) }
	}
	spec := func(f func(*api.Spec)) func(*api.AgentDefinition, *catalog.Catalog, *catalog.Policy) {
		return func(a *api.AgentDefinition, c *catalog.Catalog, p *catalog.Policy) { f(&a.Spec) }
	}
	long := strings.Repeat("v", 4097)
	many := make([]api.EnvVar, 33)
	for i := range many {
		many[i] = api.EnvVar{Name: "V" + strings.Repeat("A", i%5) + string(rune('A'+i%26)) + string(rune('A'+i/26)), Value: "x"}
	}
	for name, c := range map[string]struct {
		mutate func(*api.AgentDefinition, *catalog.Catalog, *catalog.Policy)
		want   string
	}{
		"unknown type":            {spec(func(s *api.Spec) { s.Runtime.Type = "vm" }), `runtime.type "vm" is not known`},
		"not allowed by policy":   {func(a *api.AgentDefinition, c *catalog.Catalog, p *catalog.Policy) { p.AllowedRuntimes = nil }, "runtime container is not allowed by the platform policy"},
		"not in the catalog":      {func(a *api.AgentDefinition, c *catalog.Catalog, p *catalog.Policy) { c.Adapters.Runtimes = nil }, "runtime container is not available on this platform"},
		"builtin with a block":    {spec(func(s *api.Spec) { s.Runtime.Type = "builtin"; s.Instructions = "hi" }), "runtime.container is set but runtime.type is builtin"},
		"container without block": {spec(func(s *api.Spec) { s.Runtime.Container = nil }), "runtime.container is missing"},
		"tag":                     {d(func(r *api.ContainerRuntime) { r.Image = "ghcr.io/acme/agents/echo:v1" }), "must be pinned by digest: registry/path@sha256:<64 hex>"},
		"tag next to digest": {d(func(r *api.ContainerRuntime) {
			r.Image = "ghcr.io/acme/agents/echo:v1" + strings.TrimPrefix(goodImage, "ghcr.io/acme/agents/echo")
		}), "must be pinned by digest"},
		"image outside prefixes": {d(func(r *api.ContainerRuntime) {
			r.Image = "docker.io/evil/agent" + strings.TrimPrefix(goodImage, "ghcr.io/acme/agents/echo")
		}), "not under a registry prefix"},
		"no prefixes at all": {func(a *api.AgentDefinition, c *catalog.Catalog, p *catalog.Policy) { p.Runtimes.Container.Images = nil }, "not under a registry prefix"},
		"port low":           {d(func(r *api.ContainerRuntime) { r.Port = 80 }), "port 80 must be between 1024 and 65535"},
		"port high":          {d(func(r *api.ContainerRuntime) { r.Port = 70000 }), "must be between 1024 and 65535"},
		"env name":           {d(func(r *api.ContainerRuntime) { r.Env = []api.EnvVar{{Name: "lower", Value: "x"}} }), `env name "lower" must match`},
		"env OPENAGENTIX_":   {d(func(r *api.ContainerRuntime) { r.Env = []api.EnvVar{{Name: "OPENAGENTIX_MODEL", Value: "x"}} }), "OPENAGENTIX_MODEL is reserved"},
		"env OPENAI_":        {d(func(r *api.ContainerRuntime) { r.Env = []api.EnvVar{{Name: "OPENAI_API_KEY", Value: "x"}} }), "OPENAI_API_KEY is reserved"},
		"env OTEL_":          {d(func(r *api.ContainerRuntime) { r.Env = []api.EnvVar{{Name: "OTEL_SDK_DISABLED", Value: "x"}} }), "is reserved"},
		"env KUBERNETES_":    {d(func(r *api.ContainerRuntime) { r.Env = []api.EnvVar{{Name: "KUBERNETES_SERVICE_HOST", Value: "x"}} }), "is reserved"},
		"env twice":          {d(func(r *api.ContainerRuntime) { r.Env = []api.EnvVar{{Name: "A", Value: "1"}, {Name: "A", Value: "2"}} }), "sets A twice"},
		"env too many":       {d(func(r *api.ContainerRuntime) { r.Env = many }), "has 33 entries; at most 32"},
		"env value too long": {d(func(r *api.ContainerRuntime) { r.Env = []api.EnvVar{{Name: "BIG", Value: long}} }), "BIG is 4097 bytes; at most 4096"},
		"env total": {d(func(r *api.ContainerRuntime) {
			for i := 0; i < 5; i++ {
				r.Env = append(r.Env, api.EnvVar{Name: "BIG" + string(rune('A'+i)), Value: strings.Repeat("v", 4000)})
			}
		}), "in all; at most 16384"},
		"env secret": {d(func(r *api.ContainerRuntime) {
			r.Env = []api.EnvVar{{Name: "TOKEN", Value: "ghp_" + strings.Repeat("a", 36)}}
		}), "TOKEN contains something shaped like a secret (github_token)"},
		"limits cpu above max":    {d(func(r *api.ContainerRuntime) { r.Resources = &api.Resources{Limits: api.ResourceList{CPU: "4"}} }), "limits.cpu 4 is above the platform maximum of 1"},
		"limits memory above max": {d(func(r *api.ContainerRuntime) { r.Resources = &api.Resources{Limits: api.ResourceList{Memory: "2Gi"}} }), "limits.memory 2Gi is above the platform maximum of 1Gi"},
		"requests above limits":   {d(func(r *api.ContainerRuntime) { r.Resources = &api.Resources{Requests: api.ResourceList{CPU: "900m"}} }), "requests are above the limits"},
		"bad quantity":            {d(func(r *api.ContainerRuntime) { r.Resources = &api.Resources{Limits: api.ResourceList{CPU: "lots"}} }), "resources.limits.cpu"},
		"instructions":            {spec(func(s *api.Spec) { s.Instructions = "be nice" }), "instructions do not apply to a container agent; configure the agent in its image"},
		"instructionsFrom": {spec(func(s *api.Spec) {
			s.InstructionsFrom = &api.InstructionsFrom{ConfigMap: &api.ConfigMapKeyRef{Name: "a", Key: "b"}}
		}), "instructionsFrom does not apply to a container agent"},
		"tools":       {spec(func(s *api.Spec) { s.Tools = []string{"x"} }), "a container agent gets every tool of its profile; make a narrower profile"},
		"toolProfile": {spec(func(s *api.Spec) { s.ToolProfile = "lookup" }), "toolProfile is not available yet for container agents"},
		"egress":      {spec(func(s *api.Spec) { s.Egress.Allow = []string{"https://api.osv.dev"} }), "egress.allow is not available yet for container agents"},
		"memory":      {spec(func(s *api.Spec) { s.Memory.Enabled = true }), "memory is not available for container agents"},
		"knowledge":   {spec(func(s *api.Spec) { s.Knowledge.Enabled = true }), "knowledge is not available for container agents"},
		"notify":      {spec(func(s *api.Spec) { s.Notify.Enabled = true }), "notify is not available for container agents"},
		"skills":      {spec(func(s *api.Spec) { s.Skills = []api.Skill{{Name: "openagentix-canary"}} }), "skills are not available for container agents"},
	} {
		t.Run(name, func(t *testing.T) {
			v := runC(t, c.mutate)
			if !has(v, c.want) {
				t.Fatalf("want a violation containing %q, got %v", c.want, v)
			}
		})
	}
}

func TestContainerAgentsHaveTheirOwnMaxAgents(t *testing.T) {
	c, p := load(t)
	optIn(c, p)
	v := Validate(Input{Def: containerGood(), Catalog: c, Policy: p, Tools: fakeTools{c}, Earlier: []string{"a", "b"}, EarlierContainers: 2})
	if !has(v, "at most 2 container agents") {
		t.Fatalf("%v", v)
	}
	// builtin agents do not count against it
	if v := Validate(Input{Def: containerGood(), Catalog: c, Policy: p, Tools: fakeTools{c}, Earlier: []string{"a", "b"}, EarlierContainers: 1}); len(v) != 0 {
		t.Fatalf("%v", v)
	}
}

// A builtin definition is judged exactly as before: the default policy allows builtin only, and the container block is refused on it.
func TestBuiltinIsUnaffectedAndContainerIsOffByDefault(t *testing.T) {
	if v := run(t, nil); len(v) != 0 {
		t.Fatalf("%v", v)
	}
	if v := run(t, func(d *api.AgentDefinition, c *catalog.Catalog, p *catalog.Policy) { d.Spec.Runtime.Type = "builtin" }); len(v) != 0 {
		t.Fatalf("explicit builtin: %v", v)
	}
	// the default platform (no opt-in) refuses a container agent with the one sentence
	c, p := load(t)
	v := Validate(Input{Def: containerGood(), Catalog: c, Policy: p, Tools: fakeTools{c}})
	if !has(v, "runtime container is not allowed by the platform policy") {
		t.Fatalf("%v", v)
	}
}
