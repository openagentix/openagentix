package kagent

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/openagentix/openagentix/services/control-plane/internal/api"
	"github.com/openagentix/openagentix/services/control-plane/internal/catalog"
	"github.com/openagentix/openagentix/services/control-plane/internal/kube"
	"github.com/openagentix/openagentix/services/control-plane/internal/plan"
)

type tools struct{ c *catalog.Catalog }

func must(p plan.Plan, err error) plan.Plan {
	if err != nil {
		panic(err)
	}
	return p
}

func (f tools) Profile(n string) (catalog.ToolProfile, bool) {
	p, ok := f.c.Tools.Toolhive.Profile(n)
	return catalog.ToolProfile{Name: p.Name, Backend: p.ToolServer, Tools: p.Tools}, ok
}
func (f tools) Profiles() []string                                { return nil }
func (f tools) Missing(p catalog.ToolProfile, tool string) string { return tool }

func build(d *api.AgentDefinition, c *catalog.Catalog) (plan.Plan, error) {
	return plan.Build(d, c, tools{c}, &catalog.Policy{})
}

func loadCat(t *testing.T) *catalog.Catalog {
	t.Helper()
	c, err := catalog.LoadCatalog("../../../testdata/catalog.json")
	if err != nil {
		t.Fatal(err)
	}
	return c
}

// flatten turns an object into path -> JSON text of each leaf. Empty maps and lists are leaves, so that `kagent: {}` counts.
func flatten(prefix string, v any, out map[string]string) {
	switch x := v.(type) {
	case map[string]any:
		if len(x) == 0 {
			out[prefix] = "{}"
			return
		}
		for k, c := range x {
			flatten(prefix+"."+k, c, out)
		}
	case []any:
		if len(x) == 0 {
			out[prefix] = "[]"
			return
		}
		for i, c := range x {
			flatten(fmt.Sprintf("%s[%d]", prefix, i), c, out)
		}
	default:
		b, _ := json.Marshal(x)
		out[prefix] = string(b)
	}
}

// ignoredGolden lists every path of the Helm output that the control plane does not produce, and why. Nothing else may
// differ. (The labels and ownerReferences the control plane adds are stamped by the core, not by this adapter, so the
// adapter output has none of them.)
var ignoredGolden = map[string]string{
	".metadata.labels.app.kubernetes.io/part-of":    "Helm-only label",
	".metadata.labels.app.kubernetes.io/managed-by": "Helm-only label (the control plane's own value is stamped by the core)",
	".metadata.labels.app.kubernetes.io/instance":   "Helm-only label",
	".metadata.labels.helm.sh/chart":                "Helm-only label",
}

func compare(t *testing.T, golden string, got []kube.Manifest) {
	t.Helper()
	compareWith(t, golden, strings.NewReplacer(), got)
}

func compareWith(t *testing.T, golden string, rename *strings.Replacer, got []kube.Manifest) {
	t.Helper()
	raw, err := os.ReadFile(golden)
	if err != nil {
		t.Fatal(err)
	}
	var want []map[string]any
	if err := json.Unmarshal([]byte(rename.Replace(string(raw))), &want); err != nil {
		t.Fatal(err)
	}
	if len(want) != len(got) {
		t.Fatalf("object count: golden %d, adapter %d", len(want), len(got))
	}
	for i := range want {
		w := map[string]string{}
		flatten("", want[i], w)
		for k := range ignoredGolden {
			delete(w, k)
		}
		g := map[string]string{}
		flatten("", got[i].Object, g)
		name := fmt.Sprintf("%v/%v", want[i]["kind"], want[i]["metadata"].(map[string]any)["name"])
		var paths []string
		for k := range w {
			paths = append(paths, k)
		}
		for k := range g {
			if _, ok := w[k]; !ok {
				paths = append(paths, k)
			}
		}
		sort.Strings(paths)
		for _, p := range paths {
			if w[p] != g[p] {
				t.Errorf("%s %s:\n  helm:    %s\n  adapter: %s", name, p, orMissing(w, p), orMissing(g, p))
			}
		}
	}
}

func orMissing(m map[string]string, k string) string {
	if v, ok := m[k]; ok {
		return v
	}
	return "(absent)"
}

// definition equal to the chart agent profile-demo (components/governance/profiles-demo-values.yaml).
func profileDemo() *api.AgentDefinition {
	return &api.AgentDefinition{Metadata: api.ObjectMeta{Name: "profile-demo", Namespace: "kagent", UID: "0a1b2c3d-1111-4222-8333-444444444444"}, Spec: api.Spec{
		Description: `Narrow demo agent on the tool profile "lookup"`,
		Model:       "claude-haiku",
		Instructions: "You answer questions about software vulnerabilities and the platform's own documents. Keep answers to two sentences.\n" +
			"You have only the tools that are listed for you.\n",
		ToolProfile: "lookup",
		Tools:       []string{"execute_tool_script", "osv_query_vulnerability", "osv_get_vulnerability", "knowledge_kb_search"},
		Egress:      api.Egress{Allow: []string{"https://api.osv.dev"}},
	}}
}

func TestParityWithHelmProfileDemo(t *testing.T) {
	c := loadCat(t)
	p := must(build(profileDemo(), c))
	p.KeySecret = "profile-demo-virtual-key" // the chart's Secret name; the control plane's carries the UID (plan.KeySecretName)
	m, err := New(c, nil).Desired(p)
	if err != nil {
		t.Fatal(err)
	}
	compare(t, "../../../testdata/golden-profile-demo.json", m)
}

// The chart's default agent: no profile (shared tool server), knowledge with graph, notify, memory with a ttl, a skill.
// Its tool list and ModelConfig name are set by hand in values, so the plan is adjusted the same way.
func TestParityWithHelmAssistant(t *testing.T) {
	c := loadCat(t)
	d := &api.AgentDefinition{Metadata: api.ObjectMeta{Name: "assistant", Namespace: "kagent", UID: "0a1b2c3d-1111-4222-8333-444444444444"}, Spec: api.Spec{
		Description: "General assistant reachable from messaging channels",
		Model:       "claude-haiku",
		Instructions: "You are a concise, helpful assistant running on a Kubernetes-native agent\n" +
			"platform. Answers are read in a chat app, so keep them short and use plain text.\n" +
			"Use the available tools when they help; say when you used one.\n",
		Tools:     []string{"execute_tool_script", "fetch_fetch", "osv_get_vulnerability", "osv_query_vulnerabilities_batch", "osv_query_vulnerability"},
		Skills:    []api.Skill{{Name: "openagentix-canary"}},
		Knowledge: api.Knowledge{Enabled: true}, Notify: api.Notify{Enabled: true},
		Memory: api.Memory{Enabled: true, TTLDays: 30},
	}}
	// The chart's assistant has tools and no profile (the shared tool server); plan.Build refuses that, so the plan is built
	// with a profile and the server set by hand, like the ModelConfig name and the Secret name below.
	d.Spec.ToolProfile = "lookup"
	p := must(build(d, c))
	p.ToolBackend = "toolhive-vmcp"
	p.KeySecret = "assistant-virtual-key"
	m, err := New(c, nil).Desired(p)
	if err != nil {
		t.Fatal(err)
	}
	// The chart's assistant names its ModelConfig by hand in values (agents[].modelConfigName: gateway-claude-haiku); the
	// adapter derives gateway-<name> and does not offer an override, so the golden is read with that one name replaced.
	compareWith(t, "../../../testdata/golden-assistant.json", strings.NewReplacer("gateway-claude-haiku", "gateway-assistant"), m)
}

func TestOrderAndKinds(t *testing.T) {
	c := loadCat(t)
	m, _ := New(c, nil).Desired(must(build(profileDemo(), c)))
	var kinds []string
	for _, x := range m {
		kinds = append(kinds, x.Object["kind"].(string))
		if x.Object["apiVersion"] != "api.kagent.dev/v1alpha3" || x.Resource.APIVersion() != "api.kagent.dev/v1alpha3" {
			t.Fatalf("%v", x.Resource)
		}
	}
	if strings.Join(kinds, ",") != "ModelConfig,Harness,AgentTemplate,EgressPolicy,Agent" {
		t.Fatal(kinds)
	}
	if got := len(New(c, nil).OwnedKinds()); got != 5 {
		t.Fatalf("owned kinds %d", got)
	}
}

func TestNoEgressMeansNoPolicyAndNoRef(t *testing.T) {
	c := loadCat(t)
	d := profileDemo()
	d.Spec.Egress = api.Egress{}
	m, _ := New(c, nil).Desired(must(build(d, c)))
	if len(m) != 4 {
		t.Fatalf("%d objects", len(m))
	}
	spec := m[3].Object["spec"].(map[string]any)
	if _, ok := spec["egressPolicyRefs"]; ok {
		t.Fatal("egressPolicyRefs must be absent")
	}
}

func TestNoToolsMeansNoToolsKey(t *testing.T) {
	c := loadCat(t)
	d := profileDemo()
	d.Spec.Tools, d.Spec.ToolProfile = nil, ""
	m, _ := New(c, nil).Desired(must(build(d, c)))
	if _, ok := m[2].Object["spec"].(map[string]any)["tools"]; ok {
		t.Fatal("tools must be absent")
	}
}

func TestHarnessEnvFromCatalog(t *testing.T) {
	c := loadCat(t)
	c.Runtime.Kagent.HarnessEnv = []catalog.EnvVar{{Name: "OTEL_PROPAGATORS", Value: "tracecontext,baggage"}}
	m, _ := New(c, nil).Desired(must(build(profileDemo(), c)))
	env := m[1].Object["spec"].(map[string]any)["env"].([]any)
	e := env[0].(map[string]any)
	if e["name"] != "OTEL_PROPAGATORS" || e["value"] != "tracecontext,baggage" {
		t.Fatalf("%v", env)
	}
}

func TestEndpointAndRef(t *testing.T) {
	c := loadCat(t)
	p := must(build(profileDemo(), c))
	r := New(c, nil)
	want := api.Endpoint{Protocol: "a2a", URL: "http://a2a-gate.openagentix-gateway.svc.cluster.local:8080/agents/kagent/profile-demo", ProtocolVersion: "1.0"}
	if got := r.Endpoint(p); got == nil || *got != want {
		t.Fatalf("%+v", got)
	}
	c.GateURL = ""
	if got := New(c, nil).Endpoint(p); got != nil {
		t.Fatalf("no gate, no endpoint: %+v", got)
	}
	ref := r.Ref(p)
	if ref != (api.ObjectRef{APIVersion: "api.kagent.dev/v1alpha3", Kind: "Agent", Name: "profile-demo"}) {
		t.Fatalf("%+v", ref)
	}
}

type getter map[string]kube.Object

func (g getter) Get(_ context.Context, r kube.Resource, _, name string) (kube.Object, error) {
	if o, ok := g[r.Plural+"/"+name]; ok {
		return o, nil
	}
	return nil, &kube.Error{Op: "get", Code: 404, Reason: "NotFound"}
}

func TestReadiness(t *testing.T) {
	c := loadCat(t)
	p := must(build(profileDemo(), c))
	cond := func(typ, status, reason, msg string) kube.Object {
		return kube.Object{"status": kube.Object{"conditions": []any{kube.Object{"type": typ, "status": status, "reason": reason, "message": msg}}}}
	}
	for name, tc := range map[string]struct {
		g     getter
		ready bool
		why   string
	}{
		"missing":    {getter{}, false, "RuntimeNotCreated"},
		"no status":  {getter{"agents/profile-demo": kube.Object{}}, false, "RuntimePending"},
		"ready":      {getter{"agents/profile-demo": cond("Ready", "True", "Ready", "")}, true, "Ready"},
		"not ready":  {getter{"agents/profile-demo": cond("Ready", "False", "DeploymentNotReady", "waiting")}, false, "RuntimeNotReady"},
		"unaccepted": {getter{"agents/profile-demo": cond("Accepted", "False", "InvalidTemplate", "bad")}, false, "RuntimeRejected"},
	} {
		t.Run(name, func(t *testing.T) {
			r, err := New(c, tc.g).Readiness(context.Background(), p)
			if err != nil {
				t.Fatal(err)
			}
			if r.Ready != tc.ready || r.Reason != tc.why {
				t.Fatalf("%+v", r)
			}
			if !r.Ready && !api.ValidReason(api.CondReady, r.Reason) {
				t.Fatalf("the adapter reports a reason that is not in the condition table: %q", r.Reason)
			}
		})
	}
}

func TestKeyFingerprintIsAnnotatedOnHarnessAndAgent(t *testing.T) {
	c := loadCat(t)
	p := must(build(profileDemo(), c))
	p.KeyFingerprint = "0123456789abcdef"
	m, _ := New(c, nil).Desired(p)
	got := map[string]string{}
	for _, o := range m {
		a, _ := o.Object["metadata"].(kube.Object)["annotations"].(kube.Object)
		if v, ok := a["openagentix.io/key-fingerprint"].(string); ok {
			got[o.Resource.Kind] = v
		}
	}
	if len(got) != 2 || got["Harness"] != "0123456789abcdef" || got["Agent"] != "0123456789abcdef" {
		t.Fatalf("want the fingerprint on the Harness and the Agent, got %v", got)
	}
}

func TestReadinessRespectsTheRuntimesObservedGeneration(t *testing.T) {
	c := loadCat(t)
	p := must(build(profileDemo(), c))
	agent := func(gen, observed float64, condGen float64) kube.Object {
		cond := kube.Object{"type": "Ready", "status": "True", "reason": "Ready"}
		if condGen > 0 {
			cond["observedGeneration"] = condGen
		}
		st := kube.Object{"conditions": []any{cond}}
		if observed > 0 {
			st["observedGeneration"] = observed
		}
		return kube.Object{"metadata": kube.Object{"generation": gen}, "status": st}
	}
	for name, tc := range map[string]struct {
		o     kube.Object
		ready bool
	}{
		"caught up":                     {agent(3, 3, 3), true},
		"status behind the spec":        {agent(3, 2, 0), false},
		"condition behind the spec":     {agent(3, 0, 2), false},
		"no generation information":     {agent(0, 0, 0), true},
		"condition ahead is not behind": {agent(3, 3, 4), true},
	} {
		t.Run(name, func(t *testing.T) {
			r, err := New(c, getter{"agents/profile-demo": tc.o}).Readiness(context.Background(), p)
			if err != nil || r.Ready != tc.ready {
				t.Fatalf("%+v %v", r, err)
			}
			if !tc.ready && r.Reason != "RuntimeStale" {
				t.Fatalf("reason %q", r.Reason)
			}
		})
	}
}

func TestReadinessMessageIsCutOnARuneBoundary(t *testing.T) {
	c := loadCat(t)
	p := must(build(profileDemo(), c))
	long := strings.Repeat("€", 300) // 3 bytes each
	o := kube.Object{"status": kube.Object{"conditions": []any{kube.Object{"type": "Ready", "status": "False", "reason": "X", "message": long}}}}
	r, _ := New(c, getter{"agents/profile-demo": o}).Readiness(context.Background(), p)
	if !utf8.ValidString(r.Message) || len([]rune(r.Message)) > 200 || r.Message == "" {
		t.Fatalf("message must be valid UTF-8 and at most 200 characters: %d bytes, valid=%v", len(r.Message), utf8.ValidString(r.Message))
	}
}

// The runtime's own words are kept in the message, so that a person debugging sees them.
func TestRuntimeReasonWordsStayInTheMessage(t *testing.T) {
	c := loadCat(t)
	p := must(build(profileDemo(), c))
	o := kube.Object{"status": kube.Object{"conditions": []any{kube.Object{"type": "Ready", "status": "False", "reason": "DeploymentNotReady", "message": "waiting"}}}}
	r, _ := New(c, getter{"agents/profile-demo": o}).Readiness(context.Background(), p)
	if r.Message != "DeploymentNotReady: waiting" {
		t.Fatalf("%q", r.Message)
	}
}

func TestNamesAreDerivedFromTheNameAndTheCatalogSection(t *testing.T) {
	c := loadCat(t)
	d := profileDemo()
	d.Spec.Memory = api.Memory{Enabled: true, TTLDays: 7}
	d.Metadata.Namespace = "team-a"
	m, _ := New(c, nil).Desired(must(build(d, c)))
	got := map[string]string{}
	for _, o := range m {
		got[o.Resource.Kind] = o.Object["metadata"].(kube.Object)["name"].(string) + "@" + o.Object["metadata"].(kube.Object)["namespace"].(string)
	}
	for k, want := range map[string]string{"ModelConfig": "gateway-profile-demo@team-a", "Harness": "profile-demo-harness@team-a", "AgentTemplate": "profile-demo-template@team-a", "EgressPolicy": "profile-demo-egress@team-a", "Agent": "profile-demo@team-a"} {
		if got[k] != want {
			t.Errorf("%s: got %q want %q", k, got[k], want)
		}
	}
	// the memory model config is the catalog's, in the catalog's agents namespace (where it is rendered once)
	ref := m[1].Object["spec"].(kube.Object)["kagent"].(kube.Object)["memory"].(kube.Object)["modelConfigRef"].(kube.Object)
	if ref["name"] != "gateway-embed-memory" || ref["namespace"] != "kagent" {
		t.Fatalf("%v", ref)
	}
	if New(c, nil).KeyDataKey() != "OPENAI_API_KEY" {
		t.Fatal("the key Secret's data key is the adapter's")
	}
}

// Suspend: kagent's Agent and Harness have no suspend, pause or replicas field (checked in the kagent API types and docs), so
// a suspended plan produces every object but the Agent: the key, ModelConfig, Harness, AgentTemplate and EgressPolicy stay.
func TestSuspendedPlanOmitsOnlyTheAgent(t *testing.T) {
	c := loadCat(t)
	d := profileDemo()
	d.Spec.Suspend = true
	m, err := New(c, nil).Desired(must(build(d, c)))
	if err != nil {
		t.Fatal(err)
	}
	var kinds []string
	for _, x := range m {
		kinds = append(kinds, x.Resource.Kind)
	}
	if strings.Join(kinds, ",") != "ModelConfig,Harness,AgentTemplate,EgressPolicy" {
		t.Fatalf("%v", kinds)
	}
}

func TestCapabilitiesAreOnlyWhatTheKagentDocsAndSourceSay(t *testing.T) {
	got := New(loadCat(t), nil).Capabilities()
	want := api.Capabilities{Approvals: api.Yes, DurableWaits: api.Yes, WorkspacePersistence: "snapshot", MaxStepSeconds: 600, CancelStopsLoop: api.Unknown, PerRunIdentity: "session", Isolation: "sandbox-per-session"}
	if got != want {
		t.Fatalf("got %+v want %+v", got, want)
	}
}
