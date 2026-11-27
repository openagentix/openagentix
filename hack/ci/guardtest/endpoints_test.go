package guardtest

// ADR 0026, slice 2: mcp.endpoints[]. A profile that lists an endpoint tool is left out of the catalog, so the AgentTemplate guard (built from the
// catalog) refuses a template on its server for every tool, whatever controlPlane.policy.allowedProfiles says, "*" included. And an EgressPolicy that names
// the endpoint host in any form is refused. The policies are rendered by helm and executed with the Kubernetes CEL code.

import (
	"strings"
	"testing"
)

var endpointSets = []string{
	"controlPlane.apiServerCIDRs={172.18.0.0/24}",
	"controlPlane.policy.allowedProfiles={*}",
	"mcp.endpoints[0].name=records",
	"mcp.endpoints[0].url=http://records.fernvale-records.svc.cluster.local:8080/mcp",
	"mcp.endpoints[0].group=disputes",
	"mcp.endpoints[0].auth.header.name=Authorization",
	"mcp.endpoints[0].auth.header.secret.name=records-mcp-auth",
	"mcp.endpoints[0].auth.header.secret.key=value",
	"mcp.endpoints[0].ingress.podSelector.app=records",
	"mcp.endpoints[0].ingress.port=8080",
	"mcp.profiles[1].name=disputes",
	"mcp.profiles[1].codeMode=false",
	"mcp.profiles[1].tools.records={get_case,set_route}",
	"mcp.profiles[1].tools.knowledge={kb_search}",
}

func TestEndpointProfileIsOutsideTheAgentTemplateGuard(t *testing.T) {
	r := render(t, endpointSets...)
	e, err := newEngine(r.Policies)
	if err != nil {
		t.Fatal(err)
	}
	var lookup *struct {
		Name       string
		ToolServer string
		Tools      []string
	}
	for i, p := range r.Catalog.Tools.Toolhive.Profiles {
		if p.Name == "disputes" {
			t.Errorf("the catalog lists the profile disputes, which lists an endpoint tool (allowedProfiles is [*])")
		}
		if p.Name == "lookup" {
			lookup = &r.Catalog.Tools.Toolhive.Profiles[i]
		}
	}
	if lookup == nil {
		t.Fatal("the catalog has no profile lookup: the control below would be empty")
	}
	A := fromGolden(t, "golden-profile-demo.json", "profile-demo", "researcher", "gateway-profile-demo")
	b := &builder{t: t, r: r, cat: r.Catalog}
	tmpl := func(server string, tools []string) m {
		tp := find(A, "AgentTemplate")
		put(tp, "spec/tools", []any{m{"mcp": m{"server": m{"kind": "RemoteMCPServer", "name": server}, "tools": strs(tools)}}})
		return tp
	}
	b.kagent("allow a template on the server of lookup with one of its tools (the control: the guard is not closed to everything)", "CREATE", "AgentTemplate", tmpl(lookup.ToolServer, lookup.Tools[:1]), nil, allow)
	for _, tool := range []string{"records_get_case", "records_set_route", "knowledge-disputes_kb_search"} {
		b.kagent("deny a template on the server of disputes with the tool "+tool, "CREATE", "AgentTemplate", tmpl("toolhive-vmcp-disputes", []string{tool}), nil, deny)
		b.kagent("deny the same on UPDATE "+tool, "UPDATE", "AgentTemplate", tmpl("toolhive-vmcp-disputes", []string{tool}), tmpl(lookup.ToolServer, lookup.Tools[:1]), deny)
	}
	b.kagent("deny a template on the server of disputes with every tool (records_get_case, records_set_route, knowledge-disputes_kb_search)", "CREATE", "AgentTemplate",
		tmpl("toolhive-vmcp-disputes", []string{"records_get_case", "records_set_route", "knowledge-disputes_kb_search"}), nil, deny)
	b.kagent("deny a template on the server of disputes with no tool list entry at all", "CREATE", "AgentTemplate", tmpl("toolhive-vmcp-disputes", nil), nil, deny)
	b.kagent("deny a template on the shared server with an endpoint tool", "CREATE", "AgentTemplate", tmpl("toolhive-vmcp", []string{"records_get_case"}), nil, deny)
	var txt strings.Builder
	for _, p := range r.Policies {
		for _, v := range p.Spec.Variables {
			txt.WriteString(v.Expression + "\n")
		}
		for _, v := range p.Spec.Validations {
			txt.WriteString(v.Expression + "\n")
		}
	}
	if strings.Contains(txt.String(), "toolhive-vmcp-disputes") || strings.Contains(txt.String(), "records_get_case") {
		t.Errorf("the guard names the server or a tool of the profile disputes")
	}
	allowed, denied := runCases(t, e, b.out)
	t.Logf("endpoint profile cases: %d allowed, %d refused", allowed, denied)
	if allowed < 1 || denied < 9 {
		t.Errorf("the suite shrank: %d allowed and %d refused cases", allowed, denied)
	}
}

// An EgressPolicy that names the host of an endpoint is refused in every form (ADR 0026 A2): the short form <service>.<namespace>, the .svc form, the full
// cluster name, and a wildcard origin that covers it.
func TestEgressPolicyNamingAnEndpointHostIsRefusedInEveryForm(t *testing.T) {
	r := render(t, endpointSets...)
	e, err := newEngine(r.Policies)
	if err != nil {
		t.Fatal(err)
	}
	A := fromGolden(t, "golden-profile-demo.json", "profile-demo", "researcher", "gateway-profile-demo")
	b := &builder{t: t, r: r, cat: r.Catalog}
	pol := func(origin string) m {
		eg := find(A, "EgressPolicy")
		put(eg, "spec/destinations", []any{m{"origin": origin}})
		return eg
	}
	b.kagent("allow a public origin (the control: the egress guard is not closed to everything)", "CREATE", "EgressPolicy", pol("https://api.osv.dev"), nil, allow)
	for _, o := range []string{
		"https://records.fernvale-records", "http://records.fernvale-records:8080",
		"https://records.fernvale-records.svc", "http://records.fernvale-records.svc:8080",
		"https://records.fernvale-records.svc.cluster.local", "http://records.fernvale-records.svc.cluster.local:8080",
		"https://*.fernvale-records.svc", "https://*.fernvale-records.svc.cluster.local",
	} {
		b.kagent("deny an EgressPolicy naming the endpoint host as "+o, "CREATE", "EgressPolicy", pol(o), nil, deny)
		b.kagent("deny the same on UPDATE "+o, "UPDATE", "EgressPolicy", pol(o), pol("https://api.osv.dev"), deny)
	}
	allowed, denied := runCases(t, e, b.out)
	t.Logf("endpoint host cases: %d allowed, %d refused", allowed, denied)
	if allowed < 1 || denied < 16 {
		t.Errorf("the suite shrank: %d allowed and %d refused cases", allowed, denied)
	}
}

// The guard is the backstop against a compromised controller, and it does not read the chart's refusals. The catalog carries the namespaces of the endpoints, so
// the guard refuses an egress host in them in every form, whatever the shape of the namespace name: a namespace of letters only (billing) has the shape of a top level
// domain, which the shape rule cannot see (ADR 0026 review of slice 2).
func TestEgressPolicyNamingAnEndpointNamespaceIsRefusedWhateverItsShape(t *testing.T) {
	sets := append([]string{}, endpointSets...)
	for i, s := range sets {
		if strings.HasPrefix(s, "mcp.endpoints[0].url=") {
			sets[i] = "mcp.endpoints[0].url=http://records.billing.svc.cluster.local:8080/mcp"
		}
	}
	r := render(t, sets...)
	e, err := newEngine(r.Policies)
	if err != nil {
		t.Fatal(err)
	}
	A := fromGolden(t, "golden-profile-demo.json", "profile-demo", "researcher", "gateway-profile-demo")
	b := &builder{t: t, r: r, cat: r.Catalog}
	pol := func(origin string) m {
		eg := find(A, "EgressPolicy")
		put(eg, "spec/destinations", []any{m{"origin": origin}})
		return eg
	}
	b.kagent("allow a public origin (the control)", "CREATE", "EgressPolicy", pol("https://api.osv.dev"), nil, allow)
	b.kagent("allow a public name that merely contains the namespace as a label", "CREATE", "EgressPolicy", pol("https://docs.billing.dev"), nil, allow)
	for _, o := range []string{
		"https://records.billing", "http://records.billing:8080", "https://any.billing", "https://a.b.billing",
		"https://records.billing.svc", "https://any.billing.svc:8080", "https://records.billing.svc.cluster.local",
		"https://*.billing.svc", "https://*.billing.svc.cluster.local", "https://*.billing",
	} {
		b.kagent("deny an EgressPolicy naming the letters-only endpoint namespace as "+o, "CREATE", "EgressPolicy", pol(o), nil, deny)
	}
	allowed, denied := runCases(t, e, b.out)
	t.Logf("endpoint namespace cases: %d allowed, %d refused", allowed, denied)
	if allowed < 2 || denied < 10 {
		t.Errorf("the suite shrank: %d allowed and %d refused cases", allowed, denied)
	}
	// with the namespace not in the catalog, the same short form is allowed: the control that the new list is what refuses it
	r0 := render(t, "mcp.endpoints=null")
	e0, err := newEngine(r0.Policies)
	if err != nil {
		t.Fatal(err)
	}
	b0 := &builder{t: t, r: r0, cat: r0.Catalog}
	b0.kagent("allow records.billing when no endpoint is in that namespace (the known limit of the shape rule)", "CREATE", "EgressPolicy", pol("https://records.billing"), nil, allow)
	runCases(t, e0, b0.out)
}

func TestEgressPolicyNamingTheEndpointNamespaceAsWildcardIsRefused(t *testing.T) {
	r := render(t, endpointSets...)
	e, err := newEngine(r.Policies)
	if err != nil {
		t.Fatal(err)
	}
	A := fromGolden(t, "golden-profile-demo.json", "profile-demo", "researcher", "gateway-profile-demo")
	b := &builder{t: t, r: r, cat: r.Catalog}
	for _, o := range []string{"https://*.fernvale-records", "https://x.fernvale-records", "https://*.fernvale-records.svc"} {
		eg := find(A, "EgressPolicy")
		put(eg, "spec/destinations", []any{m{"origin": o}})
		b.kagent("deny an EgressPolicy naming the endpoint namespace as "+o, "CREATE", "EgressPolicy", eg, nil, deny)
	}
	runCases(t, e, b.out)
}
