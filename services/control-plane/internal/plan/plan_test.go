package plan

import (
	"slices"
	"strings"
	"testing"

	"github.com/openagentix/openagentix/services/control-plane/internal/api"
	"github.com/openagentix/openagentix/services/control-plane/internal/catalog"
)

// tools is a ToolResolver over the catalog's tools-adapter section, without importing the adapter.
type tools struct{ c *catalog.Catalog }

func must(p Plan, err error) Plan {
	if err != nil {
		panic(err)
	}
	return p
}

func (f tools) Profile(n string) (catalog.ToolProfile, bool) {
	p, ok := f.c.Tools.Toolhive.Profile(n)
	return catalog.ToolProfile{Name: p.Name, Backend: p.ToolServer, Tools: p.Tools, Workload: p.Workload}, ok
}
func (f tools) Profiles() []string {
	var n []string
	for _, p := range f.c.Tools.Toolhive.Profiles {
		n = append(n, p.Name)
	}
	return n
}
func (f tools) Missing(p catalog.ToolProfile, tool string) string { return "missing " + tool }

func pol() *catalog.Policy { return &catalog.Policy{} }

func build(d *api.AgentDefinition, c *catalog.Catalog) (Plan, error) {
	return Build(d, c, tools{c}, pol())
}

func cat(t *testing.T) *catalog.Catalog {
	c, err := catalog.LoadCatalog("../../testdata/catalog.json")
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func def() *api.AgentDefinition {
	return &api.AgentDefinition{Metadata: api.ObjectMeta{Name: "x", Namespace: "kagent", UID: "0a1b2c3d-1111-4222-8333-444444444444"}, Spec: api.Spec{
		Description: "d", Model: "claude-haiku", Instructions: "Be brief.\n", ToolProfile: "lookup",
		Tools: []string{"osv_query_vulnerability"},
	}}
}

func TestBuildBasics(t *testing.T) {
	c := cat(t)
	p := must(build(def(), c))
	if p.Name != "x" || p.KeySecret != "x-virtual-key-0a1b2c3d" || p.GatewayUserID != "kagent.x" {
		t.Fatalf("%+v", p)
	}
	if p.ToolBackend != "toolhive-vmcp-lookup" || !slices.Equal(p.Tools, []string{"osv_query_vulnerability"}) {
		t.Fatalf("%+v", p)
	}
	if p.Prompt != "Be brief.\n" {
		t.Fatalf("instructions without additions pass through unchanged, got %q", p.Prompt)
	}
	if p.GatewayBaseURL != c.GatewayBaseURL {
		t.Fatalf("%+v", p)
	}
}

func TestPromptAdditionsAreTrimmedAndOrdered(t *testing.T) {
	c := cat(t)
	d := def()
	d.Spec.Knowledge, d.Spec.Notify = api.Knowledge{Enabled: true}, api.Notify{Enabled: true}
	d.Spec.Memory = api.Memory{Enabled: true, TTLDays: 7}
	p := must(build(d, c))
	want := "Be brief.\n" + c.Knowledge.Prompt + "\n" + c.Notify.Prompt + "\n" + strings.TrimSpace(c.Memory.Prompt)
	want = strings.Replace(want, "Be brief.\n"+c.Knowledge.Prompt, "Be brief."+"\n"+strings.TrimSpace(c.Knowledge.Prompt), 1)
	if p.Prompt != want {
		t.Fatalf("got\n%q\nwant\n%q", p.Prompt, want)
	}
	if p.Memory == nil || p.Memory.TTLDays != 7 || false {
		t.Fatalf("%+v", p.Memory)
	}
}

func TestExtraToolsFollowTheListedOnesWithoutDuplicates(t *testing.T) {
	c := cat(t)
	d := def()
	d.Spec.Tools = []string{"knowledge_kb_search", "osv_query_vulnerability"}
	d.Spec.Knowledge = api.Knowledge{Enabled: true}
	p := must(build(d, c))
	want := []string{"knowledge_kb_search", "osv_query_vulnerability", "knowledge_kb_get_document", "knowledge_kb_list_collections", "knowledge_kb_graph_search", "knowledge_kb_graph_entity", "knowledge_kb_graph_paths"}
	if !slices.Equal(p.Tools, want) {
		t.Fatalf("got %v", p.Tools)
	}
}

func TestNoToolsNoServer(t *testing.T) {
	c := cat(t)
	d := def()
	d.Spec.ToolProfile, d.Spec.Tools = "", nil
	p := must(build(d, c))
	if p.ToolBackend != "" || len(p.Tools) != 0 {
		t.Fatalf("%+v", p)
	}
}

func TestSkillsResolveToCatalogRefsInListedOrder(t *testing.T) {
	c := cat(t)
	d := def()
	d.Spec.Skills = []api.Skill{{Name: "openagentix-canary"}}
	p := must(build(d, c))
	if len(p.Skills) != 1 || p.Skills[0].Name != "openagentix-canary" || p.Skills[0].Ref != c.Skills["openagentix-canary"] {
		t.Fatalf("%+v", p.Skills)
	}
}

func TestPlanDoesNotAliasTheDefinition(t *testing.T) {
	c := cat(t)
	d := def()
	d.Spec.Egress.Allow = []string{"https://api.osv.dev"}
	p := must(build(d, c))
	p.Egress[0] = "changed"
	p.Tools[0] = "changed"
	if d.Spec.Egress.Allow[0] != "https://api.osv.dev" || d.Spec.Tools[0] != "osv_query_vulnerability" {
		t.Fatal("plan shares memory with the definition")
	}
}

func TestGatewayUserIsNamespaceDotNameTakenFromTheDefinition(t *testing.T) {
	c := cat(t)
	d := def()
	d.Metadata.Namespace = "team-a"
	p := must(build(d, c))
	if p.GatewayUserID != "team-a.x" || p.Namespace != "team-a" {
		t.Fatalf("namespace comes from the definition, not from the catalog: %+v", p)
	}
	// two definitions of one name in two namespaces get two users
	d2 := def()
	d2.Metadata.Namespace = "team-b"
	if must(build(d2, c)).GatewayUserID == p.GatewayUserID {
		t.Fatal("user ids collide across namespaces")
	}
}

func TestSuspendedBySpecOrByPolicy(t *testing.T) {
	c := cat(t)
	d := def()
	if must(build(d, c)).Suspended {
		t.Fatal("not suspended by default")
	}
	d.Spec.Suspend = true
	if !must(build(d, c)).Suspended {
		t.Fatal("spec.suspend")
	}
	d.Spec.Suspend = false
	p, err := Build(d, c, tools{c}, &catalog.Policy{SuspendAll: true})
	if err != nil || !p.Suspended {
		t.Fatalf("policy suspendAll: %+v %v", p, err)
	}
}

func TestTeamAndProjectLabelsAreCopiedAndNothingElse(t *testing.T) {
	c := cat(t)
	d := def()
	d.Metadata.Labels = map[string]string{api.LabelTeam: "payments", api.LabelProject: "ledger", api.LabelWorkItem: "wi-1", "other": "x"}
	p := must(build(d, c))
	if len(p.Labels) != 2 || p.Labels[api.LabelTeam] != "payments" || p.Labels[api.LabelProject] != "ledger" {
		t.Fatalf("%v", p.Labels)
	}
	p.Labels[api.LabelTeam] = "changed"
	if d.Metadata.Labels[api.LabelTeam] != "payments" {
		t.Fatal("plan shares the label map with the definition")
	}
	if len(must(build(def(), c)).Labels) != 0 {
		t.Fatal("no labels, none copied")
	}
}

func TestRevisionIsStableAndSensitive(t *testing.T) {
	c := cat(t)
	base := func() *api.AgentDefinition {
		d := def()
		d.Spec.Tools = []string{"osv_query_vulnerability", "osv_get_vulnerability"}
		d.Spec.Egress.Allow = []string{"https://api.osv.dev", "https://x.example.org"}
		d.Spec.Skills = []api.Skill{{Name: "openagentix-canary"}}
		d.Spec.Memory = api.Memory{Enabled: true}
		return d
	}
	rev := func(d *api.AgentDefinition) string { return must(build(d, c)).Revision }
	r0 := rev(base())
	if len(r0) != 12 || strings.Trim(r0, "0123456789abcdef") != "" {
		t.Fatalf("revision %q must be 12 hex characters", r0)
	}
	for i := 0; i < 50; i++ {
		if rev(base()) != r0 {
			t.Fatal("same input, different revision")
		}
	}
	// order of lists does not matter: they are sets
	d := base()
	d.Spec.Tools = []string{"osv_get_vulnerability", "osv_query_vulnerability"}
	d.Spec.Egress.Allow = []string{"https://x.example.org", "https://api.osv.dev"}
	if rev(d) != r0 {
		t.Fatal("list order changed the revision")
	}
	// what does not change the revision: description, labels, metadata, suspend, the namespace, the generation
	for name, mut := range map[string]func(*api.AgentDefinition){
		"description": func(d *api.AgentDefinition) { d.Spec.Description = "something else entirely" },
		"labels":      func(d *api.AgentDefinition) { d.Metadata.Labels = map[string]string{api.LabelTeam: "t", "x": "y"} },
		"suspend":     func(d *api.AgentDefinition) { d.Spec.Suspend = true },
		"generation":  func(d *api.AgentDefinition) { d.Metadata.Generation = 9 },
		"namespace":   func(d *api.AgentDefinition) { d.Metadata.Namespace = "elsewhere" },
	} {
		d := base()
		mut(d)
		if rev(d) != r0 {
			t.Errorf("%s must not change the revision", name)
		}
	}
	// what does
	other := c.Tools.Toolhive.Profiles[0]
	other.Name = "other"
	c.Tools.Toolhive.Profiles = append(c.Tools.Toolhive.Profiles, other)
	for name, mut := range map[string]func(*api.AgentDefinition){
		"instructions": func(d *api.AgentDefinition) { d.Spec.Instructions += "x" },
		"model":        func(d *api.AgentDefinition) { d.Spec.Model = "other" },
		"tool profile": func(d *api.AgentDefinition) { d.Spec.ToolProfile = "other" },
		"a tool":       func(d *api.AgentDefinition) { d.Spec.Tools = d.Spec.Tools[:1] },
		"knowledge":    func(d *api.AgentDefinition) { d.Spec.Knowledge.Enabled = true },
		"notify":       func(d *api.AgentDefinition) { d.Spec.Notify.Enabled = true },
		"memory ttl":   func(d *api.AgentDefinition) { d.Spec.Memory.TTLDays = 7 },
		"memory off":   func(d *api.AgentDefinition) { d.Spec.Memory.Enabled = false },
		"skills":       func(d *api.AgentDefinition) { d.Spec.Skills = nil },
		"egress":       func(d *api.AgentDefinition) { d.Spec.Egress.Allow = d.Spec.Egress.Allow[:1] },
	} {
		d := base()
		mut(d)
		if rev(d) == r0 {
			t.Errorf("%s must change the revision", name)
		}
	}
	// a skill's digest in the catalog is part of what was applied
	c2 := cat(t)
	c2.Skills["openagentix-canary"] = strings.Replace(c2.Skills["openagentix-canary"], "0000", "1111", 1)
	if must(build(base(), c2)).Revision == r0 {
		t.Fatal("a new skill digest must change the revision")
	}
	// the catalog's prompt additions are part of the final prompt
	c3 := cat(t)
	c3.Memory.Prompt += " more"
	if must(build(base(), c3)).Revision == r0 {
		t.Fatal("a changed prompt addition must change the revision")
	}
}

// A builtin revision must never change because the container runtime exists: a revision is what products compare, and a change
// would roll every running agent. This value was computed before the runtime field existed.
func TestBuiltinRevisionIsIdenticalToBeforeTheContainerRuntime(t *testing.T) {
	c := cat(t)
	d := def()
	d.Spec.Knowledge = api.Knowledge{Enabled: true}
	d.Spec.Memory = api.Memory{Enabled: true, TTLDays: 7}
	d.Spec.Egress.Allow = []string{"https://api.osv.dev"}
	d.Spec.Skills = []api.Skill{{Name: "openagentix-canary"}}
	p := must(build(d, c))
	if p.Revision != "983c7e170779" {
		t.Fatalf("revision %s", p.Revision)
	}
	if p.RuntimeType != api.RuntimeBuiltin || p.Container != nil {
		t.Fatalf("%+v", p)
	}
	// an explicit builtin hashes like an absent runtime
	d.Spec.Runtime = api.Runtime{Type: api.RuntimeBuiltin}
	if q := must(build(d, c)); q.Revision != p.Revision {
		t.Fatal("explicit builtin must not change the revision")
	}
}

func containerDef() *api.AgentDefinition {
	return &api.AgentDefinition{Metadata: api.ObjectMeta{Name: "echo", Namespace: "kagent", UID: "0a1b2c3d-1111-4222-8333-444444444444"}, Spec: api.Spec{
		Description: "d", Model: "claude-haiku",
		Runtime: api.Runtime{Type: api.RuntimeContainer, Container: &api.ContainerRuntime{
			Image: "ghcr.io/acme/agents/echo@sha256:" + strings.Repeat("a", 64), Port: 8080,
			Env: []api.EnvVar{{Name: "B", Value: "2"}, {Name: "A", Value: "1"}},
		}},
	}}
}

func TestContainerPlanCarriesTheSpecAndResolvedResources(t *testing.T) {
	c := cat(t)
	pl := &catalog.Policy{Runtimes: catalog.PolicyRuntimes{Container: catalog.PolicyContainerRuntime{
		DefaultResources: api.Resources{Requests: api.ResourceList{CPU: "50m", Memory: "64Mi"}, Limits: api.ResourceList{CPU: "400m", Memory: "300Mi"}}}}}
	p, err := Build(containerDef(), c, tools{c}, pl)
	if err != nil {
		t.Fatal(err)
	}
	if p.RuntimeType != api.RuntimeContainer || p.Container == nil || p.Container.Port != 8080 || !strings.HasPrefix(p.Container.Image, "ghcr.io/acme/agents/echo@") {
		t.Fatalf("%+v", p)
	}
	if p.Container.Resources.Requests.CPU != "50m" || p.Container.Resources.Limits.Memory != "300Mi" {
		t.Fatalf("resources resolved from the policy defaults: %+v", p.Container.Resources)
	}
	if p.Prompt != "" || len(p.Tools) != 0 || p.ToolBackend != "" {
		t.Fatalf("a container plan resolves no tools and has no prompt: %+v", p)
	}
	// the plan does not alias the definition's env
	d := containerDef()
	p2 := must(Build(d, c, tools{c}, pl))
	p2.Container.Env[0].Value = "changed"
	if d.Spec.Runtime.Container.Env[0].Value != "2" {
		t.Fatal("plan aliases the definition")
	}
	if p.Container.Env[0].Name != "A" || p.Container.Env[1].Name != "B" {
		t.Fatalf("env sorted by name: %+v", p.Container.Env)
	}
}

func openLookup(c *catalog.Catalog) {
	c.Tools.Toolhive.Profiles[0].Workload = &catalog.WorkloadAccess{URL: "http://vmcp-tools-lookup-workload.mcp-tools.svc.cluster.local:4483/mcp",
		Audience: "openagentix-vmcp-lookup-workload", Namespace: "mcp-tools", PodSelector: map[string]string{"toolhive-name": "tools-lookup-workload"}, Port: 4483}
}

// ADR 0019: a container plan with a profile carries how the agent reaches that profile, and nothing about single tools.
func TestContainerPlanResolvesItsProfileToWorkloadAccess(t *testing.T) {
	c := cat(t)
	openLookup(c)
	d := containerDef()
	d.Spec.ToolProfile = "lookup"
	p, err := Build(d, c, tools{c}, pol())
	if err != nil {
		t.Fatal(err)
	}
	ta := p.ToolAccess
	if ta == nil || ta.Profile != "lookup" || ta.URL != "http://vmcp-tools-lookup-workload.mcp-tools.svc.cluster.local:4483/mcp" || ta.Audience != "openagentix-vmcp-lookup-workload" ||
		ta.Namespace != "mcp-tools" || ta.Port != 4483 || ta.PodSelector["toolhive-name"] != "tools-lookup-workload" {
		t.Fatalf("%+v", ta)
	}
	if len(p.Tools) != 0 || p.ToolBackend != "" || p.Prompt != "" {
		t.Fatalf("a container plan lists no tools and has no prompt: %+v", p)
	}
	// the plan does not alias the catalog
	ta.PodSelector["toolhive-name"] = "changed"
	if c.Tools.Toolhive.Profiles[0].Workload.PodSelector["toolhive-name"] != "tools-lookup-workload" {
		t.Fatal("plan aliases the catalog")
	}
	// no profile: no tool access
	if q := must(Build(containerDef(), c, tools{c}, pol())); q.ToolAccess != nil {
		t.Fatal("no profile, no tools")
	}
}

// Policy refuses these first; the build fails too instead of running an agent with less (or more) than it asked for.
func TestContainerBuildFailsForAProfileItCannotReach(t *testing.T) {
	c := cat(t)
	for name, prof := range map[string]string{"unknown": "nope", "not open to container agents": "lookup"} {
		d := containerDef()
		d.Spec.ToolProfile = prof
		if _, err := Build(d, c, tools{c}, pol()); err == nil {
			t.Errorf("%s: want an error", name)
		}
	}
}

func TestContainerRevisionIsSensitiveToImagePortEnvAndResources(t *testing.T) {
	c := cat(t)
	openLookup(c)
	rev := func(edit func(*api.AgentDefinition)) string {
		d := containerDef()
		if edit != nil {
			edit(d)
		}
		return must(build(d, c)).Revision
	}
	base := rev(nil)
	if base != rev(nil) {
		t.Fatal("stable")
	}
	seen := map[string]string{"base": base}
	for name, edit := range map[string]func(*api.AgentDefinition){
		"image": func(d *api.AgentDefinition) {
			d.Spec.Runtime.Container.Image = "ghcr.io/acme/agents/echo@sha256:" + strings.Repeat("b", 64)
		},
		"port": func(d *api.AgentDefinition) { d.Spec.Runtime.Container.Port = 9090 },
		"env":  func(d *api.AgentDefinition) { d.Spec.Runtime.Container.Env[0].Value = "3" },
		"envextra": func(d *api.AgentDefinition) {
			d.Spec.Runtime.Container.Env = append(d.Spec.Runtime.Container.Env, api.EnvVar{Name: "C", Value: "1"})
		},
		"resources": func(d *api.AgentDefinition) {
			d.Spec.Runtime.Container.Resources = &api.Resources{Limits: api.ResourceList{CPU: "700m"}}
		},
		"model":       func(d *api.AgentDefinition) { d.Spec.Model = "other" },
		"toolProfile": func(d *api.AgentDefinition) { d.Spec.ToolProfile = "lookup" },
	} {
		r := rev(edit)
		for k, v := range seen {
			if v == r {
				t.Errorf("%s has the same revision as %s", name, k)
			}
		}
		seen[name] = r
	}
	// env order is a set; the description is not behaviour
	if rev(func(d *api.AgentDefinition) {
		d.Spec.Runtime.Container.Env[0], d.Spec.Runtime.Container.Env[1] = d.Spec.Runtime.Container.Env[1], d.Spec.Runtime.Container.Env[0]
		d.Spec.Description = "other"
	}) != base {
		t.Fatal("env order and description must not change the revision")
	}
	// a container revision differs from a builtin one with the same model
	if rev(nil) == must(build(def(), c)).Revision {
		t.Fatal("runtime type is part of the revision")
	}
}

func TestKeySecretNameCarriesTheUID(t *testing.T) {
	c := cat(t)
	d := def()
	d.Metadata.UID = "0a1b2c3d-1111-4222-8333-444444444444"
	p, err := build(d, c)
	if err != nil {
		t.Fatal(err)
	}
	if p.KeySecret != "x-virtual-key-0a1b2c3d" {
		t.Fatalf("got %q", p.KeySecret)
	}
}

func TestBuildFailsWithoutAUsableUID(t *testing.T) {
	c := cat(t)
	for _, uid := range []string{"", "short", "zzzzzzzz-1111-4222-8333-444444444444"} {
		d := def()
		d.Metadata.UID = uid
		if _, err := build(d, c); err == nil {
			t.Fatalf("uid %q: want an error, the Secret name needs 8 hex characters of it", uid)
		}
	}
}

func TestBuildFailsInsteadOfFallingBackToTheSharedToolServer(t *testing.T) {
	c := cat(t)
	d := def()
	d.Metadata.UID = "0a1b2c3d-1111-4222-8333-444444444444"
	d.Spec.ToolProfile = "ghost"
	if p, err := build(d, c); err == nil {
		t.Fatalf("an unknown profile must be an error, got server %q", p.ToolBackend)
	}
	d.Spec.ToolProfile = ""
	if p, err := build(d, c); err == nil {
		t.Fatalf("tools without a profile must be an error, got server %q", p.ToolBackend)
	}
}
