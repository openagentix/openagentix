package policy

import (
	"fmt"
	"slices"
	"strings"
	"testing"

	"github.com/openagentix/openagentix/services/control-plane/internal/api"
	"github.com/openagentix/openagentix/services/control-plane/internal/catalog"
)

// fakeTools is a ToolResolver that does not depend on the toolhive adapter.
type fakeTools struct{ c *catalog.Catalog }

func (f fakeTools) Profile(n string) (catalog.ToolProfile, bool) {
	p, ok := f.c.Tools.Toolhive.Profile(n)
	return catalog.ToolProfile{Name: p.Name, Backend: p.ToolServer, Tools: p.Tools, Workload: p.Workload}, ok
}
func (f fakeTools) Profiles() []string {
	var n []string
	for _, p := range f.c.Tools.Toolhive.Profiles {
		n = append(n, p.Name)
	}
	return n
}
func (f fakeTools) Missing(p catalog.ToolProfile, tool string) string {
	if tool == f.c.Tools.Toolhive.CodeModeTool {
		return fmt.Sprintf("the definition lists tool %q but profile %q has codeMode off", tool, p.Name)
	}
	return fmt.Sprintf("the definition lists tool %q which is not in profile %q (the profile offers: %s)", tool, p.Name, strings.Join(p.Tools, ", "))
}

func load(t *testing.T) (*catalog.Catalog, *catalog.Policy) {
	t.Helper()
	c, err := catalog.LoadCatalog("../../testdata/catalog.json")
	if err != nil {
		t.Fatal(err)
	}
	p, err := catalog.LoadPolicy("../../testdata/policy.json")
	if err != nil {
		t.Fatal(err)
	}
	return c, p
}

// good is the demo agent profile-demo as a definition.
func good() *api.AgentDefinition {
	return &api.AgentDefinition{
		APIVersion: api.APIVersion, Kind: api.Kind,
		Metadata: api.ObjectMeta{Name: "researcher", Namespace: "kagent"},
		Spec: api.Spec{
			Description:  "Looks things up",
			Model:        "claude-haiku",
			Instructions: "You answer questions about software vulnerabilities.",
			ToolProfile:  "lookup",
			Tools:        []string{"execute_tool_script", "osv_query_vulnerability", "osv_get_vulnerability", "knowledge_kb_search"},
			Egress:       api.Egress{Allow: []string{"https://api.osv.dev"}},
		},
	}
}

func run(t *testing.T, mutate func(*api.AgentDefinition, *catalog.Catalog, *catalog.Policy), earlier ...string) []string {
	t.Helper()
	c, p := load(t)
	d := good()
	if mutate != nil {
		mutate(d, c, p)
	}
	return Validate(Input{Def: d, Catalog: c, Policy: p, Tools: fakeTools{c}, Earlier: earlier})
}

func TestAccepted(t *testing.T) {
	cases := map[string]func(*api.AgentDefinition, *catalog.Catalog, *catalog.Policy){
		"the demo agent as a definition": nil,
		"no tools and no profile when the policy does not require one": func(d *api.AgentDefinition, _ *catalog.Catalog, p *catalog.Policy) {
			d.Spec.ToolProfile, d.Spec.Tools, d.Spec.Egress.Allow = "", nil, nil
			p.RequireToolProfile = false
		},
		"memory within the limit": func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
			d.Spec.Memory = api.Memory{Enabled: true, TTLDays: 30}
		},
		"memory without ttl uses the runtime default": func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
			d.Spec.Memory = api.Memory{Enabled: true}
		},
		"egress matched by a wildcard pattern": func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
			d.Spec.Egress.Allow = []string{"https://docs.example.org"}
		},
		"wildcard policy lists": func(d *api.AgentDefinition, _ *catalog.Catalog, p *catalog.Policy) {
			p.AllowedModels, p.AllowedProfiles, p.AllowedSkills = []string{"*"}, []string{"*"}, []string{"*"}
			d.Spec.Skills = []api.Skill{{Name: "openagentix-canary"}}
		},
		"knowledge and notify with a profile that offers their tools": func(d *api.AgentDefinition, c *catalog.Catalog, _ *catalog.Policy) {
			c.Tools.Toolhive.Profiles[0].Tools = append(c.Tools.Toolhive.Profiles[0].Tools, c.Knowledge.Tools...)
			c.Tools.Toolhive.Profiles[0].Tools = append(c.Tools.Toolhive.Profiles[0].Tools, c.Notify.Tools...)
			d.Spec.Knowledge.Enabled, d.Spec.Notify.Enabled = true, true
		},
		"a name at the length limit": func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
			d.Metadata.Name = strings.Repeat("a", 40)
		},
	}
	for name, m := range cases {
		t.Run(name, func(t *testing.T) {
			if v := run(t, m); len(v) != 0 {
				t.Fatalf("want accepted, got %q", v)
			}
		})
	}
}

type mut = func(*api.AgentDefinition, *catalog.Catalog, *catalog.Policy)

func TestRefusals(t *testing.T) {
	cases := []struct {
		name   string
		mutate mut
		want   string // substring of one violation
	}{
		// model, profile, skill: catalog and policy
		{"model not in catalog", func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) { d.Spec.Model = "gpt-9" }, `model "gpt-9" is not in the platform catalog (claude-haiku)`},
		{"model not allowed", func(d *api.AgentDefinition, c *catalog.Catalog, _ *catalog.Policy) {
			c.Models = append(c.Models, "big")
			d.Spec.Model = "big"
		}, `model "big" is not allowed by the platform policy`},
		{"profile not in catalog", func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) { d.Spec.ToolProfile = "ghost" }, `toolProfile "ghost" is not defined (defined: lookup)`},
		{"profile not allowed", func(_ *api.AgentDefinition, _ *catalog.Catalog, p *catalog.Policy) { p.AllowedProfiles = nil }, `toolProfile "lookup" is not allowed by the platform policy`},
		{"skill not in catalog", func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
			d.Spec.Skills = []api.Skill{{Name: "ghost"}}
		}, `skill "ghost" is not in the platform catalog`},
		{"skill not allowed", func(d *api.AgentDefinition, _ *catalog.Catalog, p *catalog.Policy) {
			d.Spec.Skills = []api.Skill{{Name: "openagentix-canary"}}
			p.AllowedSkills = nil
		}, `skill "openagentix-canary" is not allowed by the platform policy`},
		// tools
		{"tools without a profile", func(d *api.AgentDefinition, _ *catalog.Catalog, p *catalog.Policy) {
			d.Spec.ToolProfile = ""
			p.RequireToolProfile = false
		}, "lists tools but names no toolProfile"},
		{"policy requires a profile", func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
			d.Spec.ToolProfile, d.Spec.Tools = "", nil
		}, "the platform policy requires a toolProfile"},
		{"tool not offered by the profile", func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
			d.Spec.Tools = append(d.Spec.Tools, "fetch_fetch")
		}, `lists tool "fetch_fetch" which is not in profile "lookup" (the profile offers: knowledge_kb_search, osv_query_vulnerability, osv_get_vulnerability, execute_tool_script)`},
		{"code mode off", func(d *api.AgentDefinition, c *catalog.Catalog, _ *catalog.Policy) {
			c.Tools.Toolhive.Profiles[0].CodeMode = false
			c.Tools.Toolhive.Profiles[0].Tools = c.Tools.Toolhive.Profiles[0].Tools[:3]
		}, `lists tool "execute_tool_script" but profile "lookup" has codeMode off`},
		{"tool listed twice", func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
			d.Spec.Tools = append(d.Spec.Tools, "osv_query_vulnerability")
		}, `lists tool "osv_query_vulnerability" twice`},
		// knowledge and notify
		{"knowledge not allowed by policy", func(d *api.AgentDefinition, _ *catalog.Catalog, p *catalog.Policy) {
			d.Spec.Knowledge.Enabled = true
			p.AllowKnowledge = false
		}, "knowledge is not allowed by the platform policy"},
		{"knowledge service off", func(d *api.AgentDefinition, c *catalog.Catalog, _ *catalog.Policy) {
			d.Spec.Knowledge.Enabled = true
			c.Knowledge.Available = false
		}, "knowledge is not available on this platform"},
		{"knowledge tools not in the profile", func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) { d.Spec.Knowledge.Enabled = true }, `lists tool "knowledge_kb_get_document" which is not in profile "lookup"`},
		{"knowledge needs a profile", func(d *api.AgentDefinition, _ *catalog.Catalog, p *catalog.Policy) {
			d.Spec.Knowledge.Enabled, d.Spec.ToolProfile, d.Spec.Tools = true, "", nil
			p.RequireToolProfile = false
		}, "knowledge adds tools, so it needs a toolProfile"},
		{"notify not allowed by policy", func(d *api.AgentDefinition, _ *catalog.Catalog, p *catalog.Policy) {
			d.Spec.Notify.Enabled = true
			p.AllowNotify = false
		}, "notify is not allowed by the platform policy"},
		{"notify service off", func(d *api.AgentDefinition, c *catalog.Catalog, _ *catalog.Policy) {
			d.Spec.Notify.Enabled = true
			c.Notify.Available = false
		}, "notify is not available on this platform"},
		{"notify needs a profile", func(d *api.AgentDefinition, _ *catalog.Catalog, p *catalog.Policy) {
			d.Spec.Notify.Enabled, d.Spec.ToolProfile, d.Spec.Tools = true, "", nil
			p.RequireToolProfile = false
		}, "notify adds tools, so it needs a toolProfile"},
		// memory
		{"memory not allowed by policy", func(d *api.AgentDefinition, _ *catalog.Catalog, p *catalog.Policy) {
			d.Spec.Memory = api.Memory{Enabled: true}
			p.Memory.Allowed = false
		}, "memory is not allowed by the platform policy"},
		{"memory stack not installed", func(d *api.AgentDefinition, c *catalog.Catalog, _ *catalog.Policy) {
			d.Spec.Memory = api.Memory{Enabled: true}
			c.Memory.Available = false
		}, "memory is not installed on this platform"},
		{"memory expiry job off", func(d *api.AgentDefinition, c *catalog.Catalog, _ *catalog.Policy) {
			d.Spec.Memory = api.Memory{Enabled: true}
			c.Memory.ExpiryEnabled = false
		}, "the memory expiry job is off, so the time limit would not be enforced"},
		{"ttl above the maximum", func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
			d.Spec.Memory = api.Memory{Enabled: true, TTLDays: 31}
		}, "memory.ttlDays 31 is above the platform maximum of 30"},
		{"default ttl above the maximum", func(d *api.AgentDefinition, _ *catalog.Catalog, p *catalog.Policy) {
			d.Spec.Memory = api.Memory{Enabled: true}
			p.Memory.MaxTTLDays = 10
		}, "memory.ttlDays 15 is above the platform maximum of 10"},
		{"ttl negative", func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
			d.Spec.Memory = api.Memory{Enabled: true, TTLDays: -1}
		}, "memory.ttlDays must be at least 1"},
		// egress
		{"egress malformed", func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
			d.Spec.Egress.Allow = []string{"api.osv.dev/v1"}
		}, `egress.allow entry "api.osv.dev/v1" is not an origin`},
		{"egress inside the tools namespace", func(d *api.AgentDefinition, _ *catalog.Catalog, p *catalog.Policy) {
			d.Spec.Egress.Allow = []string{"http://vmcp-tools.mcp-tools.svc.cluster.local:4483"}
			p.Egress.AllowedOrigins = []string{"*"} // ignored: "*" is not a pattern
		}, `egress.allow entry "http://vmcp-tools.mcp-tools.svc.cluster.local:4483" is inside the tools namespace "mcp-tools"`},
		{"egress inside the tools namespace, short name", func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
			d.Spec.Egress.Allow = []string{"http://osv.mcp-tools"}
		}, "is inside the tools namespace"},
		{"egress not matched by the policy", func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
			d.Spec.Egress.Allow = []string{"https://api.github.com"}
		}, `egress.allow entry "https://api.github.com" is not matched by the platform policy`},
		{"egress wildcard broader than the policy", func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
			d.Spec.Egress.Allow = []string{"https://*.osv.dev"}
		}, "is not matched by the platform policy"},
		{"egress two labels under a one-label pattern", func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
			d.Spec.Egress.Allow = []string{"https://a.b.example.org"}
		}, "is not matched by the platform policy"},
		{"egress scheme differs", func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
			d.Spec.Egress.Allow = []string{"http://api.osv.dev"}
		}, "is not matched by the platform policy"},
		{"egress default is none", func(d *api.AgentDefinition, _ *catalog.Catalog, p *catalog.Policy) { p.Egress.AllowedOrigins = nil }, "is not matched by the platform policy"},
		{"egress twice", func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
			d.Spec.Egress.Allow = []string{"https://api.osv.dev", "https://api.osv.dev"}
		}, `lists "https://api.osv.dev" twice`},
		{"egress more than 64", func(d *api.AgentDefinition, _ *catalog.Catalog, p *catalog.Policy) {
			var l []string
			for i := range 65 {
				l = append(l, fmt.Sprintf("https://h%d.example.org", i))
			}
			d.Spec.Egress.Allow = l
		}, "egress.allow has 65 origins; at most 64 are allowed"},
		// names, size, count
		{"name reserved by the catalog", func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) { d.Metadata.Name = "assistant" }, `name "assistant" is reserved`},
		{"name kb reserved", func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) { d.Metadata.Name = "kb-extract" }, `name "kb-extract" is reserved`},
		{"name reserved by the policy", func(d *api.AgentDefinition, _ *catalog.Catalog, p *catalog.Policy) {
			p.ReservedNames = []string{"researcher"}
		}, `name "researcher" is reserved`},
		{"name too long", func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
			d.Metadata.Name = strings.Repeat("a", 41)
		}, "at most 40 characters"},
		{"name not a DNS label", func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) { d.Metadata.Name = "Bad_Name" }, "must be a DNS label"},
		{"too many definitions", func(d *api.AgentDefinition, _ *catalog.Catalog, p *catalog.Policy) { p.MaxAgents = 2 }, "the platform policy allows at most 2 agents in namespace \"kagent\""},
		{"description too long", func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
			d.Spec.Description = strings.Repeat("d", 257)
		}, "description is 257 characters; at most 256"},
		{"instructions empty", func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) { d.Spec.Instructions = "  \n" }, "instructions are required: set exactly one of instructions and instructionsFrom"},
		{"instructions too long", func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
			d.Spec.Instructions = strings.Repeat("i", 16385)
		}, "instructions are 16385 bytes; at most 16384"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			earlier := []string(nil)
			if tc.name == "too many definitions" {
				earlier = []string{"a", "b"}
			}
			v := run(t, tc.mutate, earlier...)
			if !slices.ContainsFunc(v, func(s string) bool { return strings.Contains(s, tc.want) }) {
				t.Fatalf("want a violation containing %q, got %q", tc.want, v)
			}
		})
	}
}

// secrets builds each of the ten shapes at run time, so the source holds no literal that looks like a credential.
func secrets() map[string]string {
	return map[string]string{
		"aws_access_key_id":   "AK" + "IA" + "ABCDEFGHIJKLMNOP",
		"bearer_token":        "Bearer " + strings.Repeat("a1", 14),
		"github_token":        "gh" + "p_" + strings.Repeat("A", 36),
		"google_api_key":      "AI" + "za" + strings.Repeat("b", 35),
		"jwt":                 "ey" + "J" + strings.Repeat("a", 12) + ".ey" + "J" + strings.Repeat("b", 12) + "." + strings.Repeat("c", 12),
		"private_key_header":  "-----BEGIN RSA " + "PRIVATE KEY-----",
		"provider_secret_key": "s" + "k-" + strings.Repeat("Z", 40),
		"slack_token":         "xo" + "xb-" + strings.Repeat("1", 12),
		"stripe_secret_key":   "s" + "k_live_" + strings.Repeat("9", 20),
		"telegram_bot_token":  "123456789:" + strings.Repeat("A", 35),
	}
}

func TestInstructionsWithSecretShapes(t *testing.T) {
	for name, s := range secrets() {
		t.Run(name, func(t *testing.T) {
			v := run(t, func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
				d.Spec.Instructions = "Use this when asked: " + s + " and nothing else."
			})
			want := "instructions contain something shaped like a secret (" + name + ")"
			if !slices.ContainsFunc(v, func(x string) bool { return strings.Contains(x, want) }) {
				t.Fatalf("want %q, got %q", want, v)
			}
			for _, x := range v {
				if strings.Contains(x, s) {
					t.Fatalf("a violation repeats the matched text: %q", x)
				}
			}
		})
	}
	// ordinary text, long words and a bare "Bearer" must pass
	for _, ok := range []string{"Send the bearer of this message a friendly answer.", "Use sk-short and AKIA alone.", strings.Repeat("word ", 500)} {
		if v := run(t, func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) { d.Spec.Instructions = ok }); len(v) != 0 {
			t.Fatalf("false positive on %q: %q", ok[:20], v)
		}
	}
}

func TestSecretPatternNamesAreTheTenOfTheMemoryScanAndThePlatformKey(t *testing.T) {
	want := []string{"aws_access_key_id", "bearer_token", "github_token", "google_api_key", "jwt", "private_key_header", "provider_secret_key", "slack_token", "stripe_secret_key", "telegram_bot_token", "platform_virtual_key"}
	got := PatternNames()
	if !slices.Equal(got, want) {
		t.Fatalf("got %v", got)
	}
}

func TestManyViolationsAreAllReportedInOrder(t *testing.T) {
	v := run(t, func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
		d.Spec.Model = "gpt-9"
		d.Spec.ToolProfile = "ghost"
		d.Spec.Skills = []api.Skill{{Name: "ghost"}}
	})
	if len(v) < 3 {
		t.Fatalf("want at least three, got %q", v)
	}
	if !strings.HasPrefix(v[0], "model ") {
		t.Fatalf("model comes first: %q", v)
	}
}

func has(v []string, sub string) bool {
	return slices.ContainsFunc(v, func(s string) bool { return strings.Contains(s, sub) })
}

func TestReservedNamesAreScopedToTheDefinitionsNamespace(t *testing.T) {
	// the catalog's names are the chart's, in the agents namespace; elsewhere the name is free
	v := run(t, func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
		d.Metadata.Name, d.Metadata.Namespace = "assistant", "team-a"
	})
	if has(v, "reserved") {
		t.Fatalf("assistant is only reserved in the agents namespace: %q", v)
	}
	v = run(t, func(d *api.AgentDefinition, c *catalog.Catalog, _ *catalog.Policy) {
		d.Metadata.Name, d.Metadata.Namespace = "assistant", c.Namespaces.Agents
	})
	if !has(v, `name "assistant" is reserved in namespace "kagent"`) {
		t.Fatalf("%q", v)
	}
	// the namespace comes from the catalog: rename it and the rule follows
	v = run(t, func(d *api.AgentDefinition, c *catalog.Catalog, _ *catalog.Policy) {
		c.Namespaces.Agents = "agents-2"
		d.Metadata.Name, d.Metadata.Namespace = "assistant", "agents-2"
	})
	if !has(v, "reserved") {
		t.Fatalf("nothing may assume the namespace is kagent: %q", v)
	}
	// a policy entry "ns/name" is one namespace only; a bare name is every namespace
	mut := func(ns, name string, res ...string) []string {
		return run(t, func(d *api.AgentDefinition, _ *catalog.Catalog, p *catalog.Policy) {
			d.Metadata.Name, d.Metadata.Namespace = name, ns
			p.ReservedNames = res
		})
	}
	if !has(mut("team-a", "ci", "team-a/ci"), "reserved") || has(mut("team-b", "ci", "team-a/ci"), "reserved") {
		t.Fatal("ns/name")
	}
	if !has(mut("team-b", "ci", "ci"), "reserved") {
		t.Fatal("bare name")
	}
}

func TestKnowledgeAndNotifyCollectionsAndDestinationsAreNotAvailableYet(t *testing.T) {
	v := run(t, func(d *api.AgentDefinition, c *catalog.Catalog, _ *catalog.Policy) {
		d.Spec.Knowledge = api.Knowledge{Collections: []string{"docs"}}
	})
	if !has(v, "knowledge.collections: selecting collections is not available yet") {
		t.Fatalf("%q", v)
	}
	v = run(t, func(d *api.AgentDefinition, c *catalog.Catalog, _ *catalog.Policy) {
		d.Spec.Notify = api.Notify{Destinations: []string{"chat-1"}}
	})
	if !has(v, "notify.destinations: selecting destinations is not available yet") {
		t.Fatalf("%q", v)
	}
	// enabled: false with an empty list is simply off
	if v := run(t, func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
		d.Spec.Knowledge, d.Spec.Notify = api.Knowledge{Enabled: false}, api.Notify{}
	}); len(v) != 0 {
		t.Fatalf("%q", v)
	}
}

func TestSkillVersionMustBeOneTheCatalogOffers(t *testing.T) {
	digest := func(c *catalog.Catalog) string { return "sha256:" + strings.Repeat("0", 64) }
	ok := func(version string) []string {
		return run(t, func(d *api.AgentDefinition, c *catalog.Catalog, _ *catalog.Policy) {
			d.Spec.Skills = []api.Skill{{Name: "openagentix-canary", Version: version}}
		})
	}
	if v := ok(""); len(v) != 0 {
		t.Fatalf("an absent version takes the catalog's: %q", v)
	}
	c, _ := load(t)
	if v := ok(digest(c)); len(v) != 0 {
		t.Fatalf("the catalog's own digest is a version it offers: %q", v)
	}
	v := ok("2.0")
	if !has(v, `skill "openagentix-canary" has no version "2.0" in the platform catalog`) || !has(v, digest(c)) {
		t.Fatalf("the sentence must say what the catalog offers: %q", v)
	}
}

func TestInstructionsFromIsReservedAndExactlyOneOfTheTwo(t *testing.T) {
	ref := &api.InstructionsFrom{ConfigMap: &api.ConfigMapKeyRef{Name: "prompts", Key: "a"}}
	v := run(t, func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
		d.Spec.Instructions, d.Spec.InstructionsFrom = "", ref
	})
	if !has(v, "instructionsFrom is not available yet") || has(v, "instructions are required") {
		t.Fatalf("%q", v)
	}
	v = run(t, func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) { d.Spec.InstructionsFrom = ref })
	if !has(v, "set exactly one of instructions and instructionsFrom") {
		t.Fatalf("both set: %q", v)
	}
	v = run(t, func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) { d.Spec.Instructions = "" })
	if !has(v, "instructions are required: set exactly one of instructions and instructionsFrom") {
		t.Fatalf("neither set: %q", v)
	}
}

func TestInClusterDestinationsAreTheOnlyExceptionAndOnlyExact(t *testing.T) {
	with := func(origin string, listed ...string) []string {
		return run(t, func(d *api.AgentDefinition, _ *catalog.Catalog, p *catalog.Policy) {
			d.Spec.Egress.Allow = []string{origin}
			p.Egress.InClusterDestinations = listed
		})
	}
	if v := with("http://registry.ci.svc:5000"); !has(v, "cluster-internal") {
		t.Fatalf("default: none allowed: %q", v)
	}
	if v := with("http://registry.ci.svc:5000", "registry.ci.svc:5000"); len(v) != 0 {
		t.Fatalf("listed exactly: %q", v)
	}
	if v := with("https://registry.ci.svc:5000", "registry.ci.svc:5000"); len(v) != 0 {
		t.Fatalf("the scheme is not part of the entry: %q", v)
	}
	for name, origin := range map[string]string{
		"another port":      "http://registry.ci.svc:5001",
		"the default port":  "http://registry.ci.svc",
		"another host":      "http://other.ci.svc:5000",
		"a subdomain":       "http://x.registry.ci.svc:5000",
		"a wildcard":        "http://*.ci.svc:5000",
		"the full name":     "http://registry.ci.svc.cluster.local:5000",
		"an address":        "http://10.0.0.4:5000",
		"the tools service": "http://vmcp.mcp-tools.svc:4483",
	} {
		if v := with(origin, "registry.ci.svc:5000"); len(v) == 0 {
			t.Errorf("%s (%s) must stay refused", name, origin)
		}
	}
	// the tools namespace can never be listed, whatever the operator wrote
	if v := with("http://vmcp.mcp-tools.svc:4483", "vmcp.mcp-tools.svc:4483"); !has(v, "inside the tools namespace") {
		t.Fatalf("%q", v)
	}
	// a default port is the scheme's
	if v := with("http://registry.ci.svc", "registry.ci.svc:80"); len(v) != 0 {
		t.Fatalf("port 80 is http's default: %q", v)
	}
	if v := with("https://registry.ci.svc", "registry.ci.svc:443"); len(v) != 0 {
		t.Fatalf("port 443 is https's default: %q", v)
	}
}

func TestReservedLabelsAreValidatedButNeverDecide(t *testing.T) {
	if v := run(t, func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
		d.Metadata.Labels = map[string]string{api.LabelTeam: strings.Repeat("a", 64)}
	}); !has(v, "label openagentix.io/team") {
		t.Fatalf("a label value over 63 characters: %q", v)
	}
	if v := run(t, func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
		d.Metadata.Labels = map[string]string{api.LabelProject: "bad value!"}
	}); !has(v, "label openagentix.io/project") {
		t.Fatalf("%q", v)
	}
	secret := "s" + "k-" + strings.Repeat("Z", 40)
	if v := run(t, func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
		d.Metadata.Labels = map[string]string{api.LabelTeam: secret}
	}); !has(v, "label openagentix.io/team") {
		t.Fatalf("a secret-shaped label value: %q", v)
	}
}

// Policy decisions ignore labels: for definitions that pass and definitions that do not, every combination of the reserved
// labels (also values that look like privileges) gives exactly the same verdict as no labels.
func TestPolicyDecisionsIgnoreLabels(t *testing.T) {
	variants := []map[string]string{
		nil,
		{api.LabelTeam: "platform"},
		{api.LabelTeam: "admin", api.LabelProject: "root", api.LabelWorkItem: "wi-1"},
		{api.LabelProject: "unlimited", "openagentix.io/allow-everything": "true", "app.kubernetes.io/managed-by": "openagentix-control-plane"},
	}
	defs := map[string]mut{
		"accepted": nil,
		"refused": func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) {
			d.Spec.Model = "gpt-9"
			d.Spec.Egress.Allow = []string{"https://api.github.com"}
		},
		"over the limit": func(d *api.AgentDefinition, _ *catalog.Catalog, p *catalog.Policy) { p.MaxAgents = 1 },
	}
	for name, m := range defs {
		want := run(t, m, "someone-else")
		for i, labels := range variants {
			got := run(t, func(d *api.AgentDefinition, c *catalog.Catalog, p *catalog.Policy) {
				if m != nil {
					m(d, c, p)
				}
				d.Metadata.Labels = labels
			}, "someone-else")
			if !slices.Equal(got, want) {
				t.Errorf("%s, labels variant %d changed the verdict:\n  without: %q\n  with:    %q", name, i, want, got)
			}
		}
	}
}

func TestSecretShapesInCollectionsDestinationsAndSkillVersions(t *testing.T) {
	secret := "s" + "k-" + strings.Repeat("Z", 40)
	for field, set := range map[string]func(d *api.AgentDefinition){
		"knowledge.collections": func(d *api.AgentDefinition) { d.Spec.Knowledge.Collections = []string{secret} },
		"notify.destinations":   func(d *api.AgentDefinition) { d.Spec.Notify.Destinations = []string{secret} },
		"skills":                func(d *api.AgentDefinition) { d.Spec.Skills = []api.Skill{{Name: "x", Version: secret}} },
	} {
		v := run(t, func(d *api.AgentDefinition, _ *catalog.Catalog, _ *catalog.Policy) { set(d) })
		if !has(v, field+" contains something shaped like a secret") {
			t.Errorf("%s: %q", field, v)
		}
		for _, x := range v {
			if strings.Contains(x, secret) {
				t.Errorf("%s: a violation repeats the secret: %q", field, x)
			}
		}
	}
}
