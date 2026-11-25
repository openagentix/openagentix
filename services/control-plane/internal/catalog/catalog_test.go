package catalog

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/openagentix/openagentix/services/control-plane/internal/api"
)

func TestLoadExamples(t *testing.T) {
	c, err := LoadCatalog("../../testdata/catalog.json")
	if err != nil {
		t.Fatal(err)
	}
	if c.Adapters.Runtime != "kagent" || c.Namespaces.Tools != "mcp-tools" || c.Tools.Toolhive == nil || len(c.Tools.Toolhive.Profiles) != 1 {
		t.Fatalf("%+v", c)
	}
	p, ok := c.Tools.Toolhive.Profile("lookup")
	if !ok || p.ToolServer != "toolhive-vmcp-lookup" || !p.CodeMode {
		t.Fatalf("profile: %+v %v", p, ok)
	}
	k := c.Runtime.Kagent
	if k == nil || k.WorkerPool != "kagent-default" || k.MemoryModelConfig != "gateway-embed-memory" || k.HarnessEnv == nil {
		t.Fatalf("adapter-owned runtime section: %+v", k)
	}
	if !c.HasModel("claude-haiku") || c.HasModel("gpt") {
		t.Fatal("HasModel")
	}
	pol, err := LoadPolicy("../../testdata/policy.json")
	if err != nil {
		t.Fatal(err)
	}
	if pol.MaxAgents != 5 || !pol.Memory.Allowed || pol.Memory.MaxTTLDays != 30 {
		t.Fatalf("%+v", pol)
	}
}

func write(t *testing.T, s string) string {
	p := filepath.Join(t.TempDir(), "f.json")
	if err := os.WriteFile(p, []byte(s), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLoadCatalogRefusals(t *testing.T) {
	base, _ := os.ReadFile("../../testdata/catalog.json")
	cases := map[string]struct{ from, to, want string }{
		"unknown field":                     {`"models"`, `"modles": [], "models"`, "unknown field"},
		"skill not digest":                  {"@sha256:0000000000000000000000000000000000000000000000000000000000000000", "@latest", "digest-pinned"},
		"no runtime":                        {`"runtime": "kagent"`, `"runtime": ""`, "adapters.runtime"},
		"no harness image":                  {`"workerPool": "kagent-default"`, `"workerPool": ""`, "runtime.kagent.workerPool"},
		"no runtime section":                {`"runtime": {`, `"runtimeX": {`, "unknown field"},
		"no tools section":                  {`"toolhive": {`, `"toolhiveX": {`, "unknown field"},
		"codeMode and the tool disagree":    {`"codeMode": true`, `"codeMode": false`, "codeMode"},
		"top-level adapter fields are gone": {`"models"`, `"harnessImage": "x", "models"`, "unknown field"},
		"bad gateway url":                   {`"gatewayBaseUrl": "http`, `"gatewayBaseUrl": "ftp`, "gatewayBaseUrl"},
		"profile no server":                 {`"toolServer": "toolhive-vmcp-lookup"`, `"toolServer": ""`, "toolServer"},
		"memory no model config":            {`"memoryModelConfig": "gateway-embed-memory"`, `"memoryModelConfig": ""`, "runtime.kagent.memoryModelConfig"},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			s := strings.Replace(string(base), c.from, c.to, 1)
			if s == string(base) {
				t.Fatal("test input not changed")
			}
			_, err := LoadCatalog(write(t, s))
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("want error containing %q, got %v", c.want, err)
			}
		})
	}
	if _, err := LoadCatalog(filepath.Join(t.TempDir(), "missing.json")); err == nil {
		t.Fatal("missing file must fail")
	}
}

func TestLoadPolicyRefusals(t *testing.T) {
	for name, c := range map[string]struct{ in, want string }{
		"negative max":                       {`{"maxAgents": -1}`, "maxAgents"},
		"unknown field":                      {`{"maxAgents": 1, "allowAll": true}`, "unknown field"},
		"bad origin":                         {`{"maxAgents": 1, "egress": {"allowedOrigins": ["api.osv.dev"]}}`, "allowedOrigins"},
		"ttl negative":                       {`{"maxAgents": 1, "memory": {"allowed": true, "maxTtlDays": -3}}`, "maxTtlDays"},
		"memory allowed without a cap":       {`{"maxAgents": 1, "memory": {"allowed": true}}`, "maxTtlDays"},
		"trailing json":                      {`{"maxAgents": 1} {}`, "trailing"},
		"in-cluster entry without a port":    {`{"maxAgents": 1, "egress": {"inClusterDestinations": ["registry.ci.svc"]}}`, "inClusterDestinations"},
		"in-cluster entry with a scheme":     {`{"maxAgents": 1, "egress": {"inClusterDestinations": ["http://registry.ci.svc:5000"]}}`, "inClusterDestinations"},
		"in-cluster entry with a wildcard":   {`{"maxAgents": 1, "egress": {"inClusterDestinations": ["*.ci.svc:5000"]}}`, "inClusterDestinations"},
		"in-cluster entry that is an IP":     {`{"maxAgents": 1, "egress": {"inClusterDestinations": ["10.0.0.4:5000"]}}`, "inClusterDestinations"},
		"in-cluster entry, port 0":           {`{"maxAgents": 1, "egress": {"inClusterDestinations": ["registry.ci.svc:0"]}}`, "inClusterDestinations"},
		"in-cluster entry, port too big":     {`{"maxAgents": 1, "egress": {"inClusterDestinations": ["registry.ci.svc:65536"]}}`, "inClusterDestinations"},
		"in-cluster entry, not namespaced":   {`{"maxAgents": 1, "egress": {"inClusterDestinations": ["registry:5000"]}}`, "inClusterDestinations"},
		"in-cluster entry listed twice":      {`{"maxAgents": 1, "egress": {"inClusterDestinations": ["registry.ci.svc:5000", "registry.ci.svc:5000"]}}`, "twice"},
		"reserved name with a bad namespace": {`{"maxAgents": 1, "reservedNames": ["Bad/x"]}`, "reservedNames"},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := LoadPolicy(write(t, c.in))
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("want %q, got %v", c.want, err)
			}
		})
	}
}

const containerCatalogPatch = `"adapters": {"runtimes": {"builtin": "kagent", "container": "container"}, "runtime"`

const containerSection = `"runtime": {"container": {"namespace": "openagentix-agents", "gatewayNamespace": "agentgateway-system", "gatewayPodSelector": {"app": "gw"}, "gatewayPort": 8080, "gateNamespace": "openagentix-gateway", "gatePodSelector": {"app": "a2a-gate"}}, `

func containerCatalog(t *testing.T, edit func(string) string) (*Catalog, error) {
	t.Helper()
	base, _ := os.ReadFile("../../testdata/catalog.json")
	s := strings.Replace(string(base), `"adapters": {
    "runtime"`, containerCatalogPatch, 1)
	s = strings.Replace(s, `"runtime": {
    "kagent"`, containerSection+`"kagent"`, 1)
	if edit != nil {
		s = edit(s)
	}
	return LoadCatalog(write(t, s))
}

func TestContainerRuntimeInTheCatalog(t *testing.T) {
	c, err := containerCatalog(t, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !c.RuntimeAvailable("builtin") || !c.RuntimeAvailable("container") || c.RuntimeAvailable("sandbox") {
		t.Fatal("RuntimeAvailable")
	}
	k := c.Runtime.Container
	if k == nil || k.Namespace != "openagentix-agents" || k.DNSNamespace != "kube-system" || k.GatewayPort != 8080 || k.WorkloadPort != 8080 || k.ImagePullPolicy != "Always" {
		t.Fatalf("defaults: %+v", k)
	}
	if c.RuntimeAdapter("container") != "container" || c.RuntimeAdapter("builtin") != "kagent" || c.RuntimeAdapter("x") != "" {
		t.Fatal("RuntimeAdapter")
	}
	// an old catalog (no adapters.runtimes) offers builtin only
	old, err := LoadCatalog("../../testdata/catalog.json")
	if err != nil {
		t.Fatal(err)
	}
	if !old.RuntimeAvailable("builtin") || old.RuntimeAvailable("container") {
		t.Fatal("absent adapters.runtimes means {builtin: adapters.runtime}")
	}
}

func TestContainerRuntimeCatalogRefusals(t *testing.T) {
	for name, c := range map[string]struct{ from, to, want string }{
		"no section":            {`"container": {"namespace"`, `"containerX": {"namespace"`, "unknown field"},
		"no namespace":          {`"namespace": "openagentix-agents"`, `"namespace": ""`, "runtime.container.namespace"},
		"no gateway selector":   {`"gatewayPodSelector": {"app": "gw"}`, `"gatewayPodSelector": {}`, "runtime.container.gatewayPodSelector"},
		"no gateway namespace":  {`"gatewayNamespace": "agentgateway-system"`, `"gatewayNamespace": ""`, "runtime.container.gatewayNamespace"},
		"no gate namespace":     {`"gateNamespace": "openagentix-gateway"`, `"gateNamespace": ""`, "runtime.container.gateNamespace"},
		"no gate selector":      {`"gatePodSelector": {"app": "a2a-gate"}`, `"gatePodSelector": {}`, "runtime.container.gatePodSelector"},
		"bad pull policy":       {`"namespace": "openagentix-agents"`, `"namespace": "openagentix-agents", "imagePullPolicy": "Never"`, "imagePullPolicy"},
		"bad port":              {`"gatewayPort": 8080`, `"gatewayPort": 70000`, "gatewayPort"},
		"unknown runtime type":  {`"container": "container"}`, `"container": "container", "sandbox": "x"}`, "adapters.runtimes"},
		"builtin must agree":    {`"builtin": "kagent"`, `"builtin": "other"`, "adapters.runtimes.builtin"},
		"workload ns is agents": {`"namespace": "openagentix-agents"`, `"namespace": "kagent"`, "must not be the agents namespace"},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := containerCatalog(t, func(s string) string { return strings.Replace(s, c.from, c.to, 1) })
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("want %q, got %v", c.want, err)
			}
		})
	}
	// the section without the listing is harmless; the listing without the section is not
	_, err := containerCatalog(t, func(s string) string { return strings.Replace(s, `"container": {"namespace"`, `"x": {"namespace"`, 1) })
	if err == nil {
		t.Fatal("listing container without its section must fail")
	}
}

// workloadProfile adds a workload entry (ADR 0019) to the profile of testdata/catalog.json.
const workloadEntry = `"toolServer": "toolhive-vmcp-lookup", "workload": {"url": "http://vmcp-tools-lookup-workload.mcp-tools.svc.cluster.local:4483/mcp", "audience": "openagentix-vmcp-lookup-workload", "namespace": "mcp-tools", "podSelector": {"app": "virtualmcpserver", "toolhive-name": "tools-lookup-workload"}, "port": 4483}`

func withWorkload(t *testing.T, edit func(string) string) (*Catalog, error) {
	t.Helper()
	base, err := os.ReadFile("../../testdata/catalog.json")
	if err != nil {
		t.Fatal(err)
	}
	s := strings.Replace(string(base), `"toolServer": "toolhive-vmcp-lookup"`, workloadEntry, 1)
	if s == string(base) {
		t.Fatal("test input not changed")
	}
	if edit != nil {
		s = edit(s)
	}
	return LoadCatalog(write(t, s))
}

func TestWorkloadToolAccessInTheCatalog(t *testing.T) {
	c, err := withWorkload(t, nil)
	if err != nil {
		t.Fatal(err)
	}
	p, _ := c.Tools.Toolhive.Profile("lookup")
	w := p.Workload
	if w == nil || w.URL != "http://vmcp-tools-lookup-workload.mcp-tools.svc.cluster.local:4483/mcp" || w.Audience != "openagentix-vmcp-lookup-workload" ||
		w.Namespace != "mcp-tools" || w.Port != 4483 || w.PodSelector["toolhive-name"] != "tools-lookup-workload" {
		t.Fatalf("%+v", w)
	}
	// without the entry a profile is not open to container agents
	old, err := LoadCatalog("../../testdata/catalog.json")
	if err != nil {
		t.Fatal(err)
	}
	if p, _ := old.Tools.Toolhive.Profile("lookup"); p.Workload != nil {
		t.Fatal("no workload entry, no workload access")
	}
	for name, c := range map[string]struct{ from, to, want string }{
		"no url":                {`"url": "http://vmcp`, `"url": "", "x": "http://vmcp`, "unknown field"},
		"empty url":             {`"url": "http://vmcp-tools-lookup-workload.mcp-tools.svc.cluster.local:4483/mcp"`, `"url": ""`, "workload.url"},
		"ftp url":               {`"url": "http://`, `"url": "ftp://`, "workload.url"},
		"url with user":         {`"url": "http://`, `"url": "http://u:p@`, "workload.url"},
		"no audience":           {`"audience": "openagentix-vmcp-lookup-workload"`, `"audience": ""`, "workload.audience"},
		"audience with a space": {`"audience": "openagentix-vmcp-lookup-workload"`, `"audience": "a b"`, "workload.audience"},
		"other namespace":       {`"namespace": "mcp-tools", "podSelector"`, `"namespace": "kube-system", "podSelector"`, "workload.namespace"},
		"empty selector":        {`"podSelector": {"app": "virtualmcpserver", "toolhive-name": "tools-lookup-workload"}`, `"podSelector": {}`, "workload.podSelector"},
		"empty label value":     {`"toolhive-name": "tools-lookup-workload"`, `"toolhive-name": ""`, "workload.podSelector"},
		"bad port":              {`"port": 4483`, `"port": 0`, "workload.port"},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := withWorkload(t, func(s string) string {
				n := strings.Replace(s, c.from, c.to, 1)
				if n == s {
					t.Fatal("test input not changed")
				}
				return n
			})
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("want %q, got %v", c.want, err)
			}
		})
	}
}

func TestImageRE(t *testing.T) {
	d := "@sha256:" + strings.Repeat("a", 64)
	for in, ok := range map[string]bool{
		"ghcr.io/acme/echo" + d:           true,
		"ghcr.io/acme/agents/echo-go" + d: true,
		"registry.ci:5000/a/b" + d:        true,
		"ghcr.io/acme/echo:v1" + d:        false, // a tag next to the digest
		"ghcr.io/acme/echo":               false,
		"ghcr.io/acme/echo:latest":        false,
		"echo" + d:                        false, // no repository path
		"GHCR.io/acme/echo" + d:           false,
		"ghcr.io/acme/echo@sha256:abc":    false,
		"ghcr.io/acme/echo" + d + "x":     false,
		"ghcr.io/acme/echo" + d + "\n":    false,
		"https://ghcr.io/acme/echo" + d:   false,
	} {
		if ImageRE.MatchString(in) != ok {
			t.Errorf("%q: want %v", in, ok)
		}
	}
}

func TestQuantities(t *testing.T) {
	for in, want := range map[string]int64{"100m": 100, "1": 1000, "2": 2000, "1500m": 1500, "0": 0} {
		got, err := ParseCPU(in)
		if err != nil || got != want {
			t.Errorf("cpu %q: %d %v", in, got, err)
		}
	}
	for _, bad := range []string{"", "-1", "1.5", "1x", "m", "100M", "1e3"} {
		if _, err := ParseCPU(bad); err == nil {
			t.Errorf("cpu %q must fail", bad)
		}
	}
	for in, want := range map[string]int64{"256Mi": 256 << 20, "1Gi": 1 << 30, "64Ki": 64 << 10, "1M": 1000000, "2G": 2000000000, "5K": 5000, "1000": 1000} {
		got, err := ParseMemory(in)
		if err != nil || got != want {
			t.Errorf("memory %q: %d %v", in, got, err)
		}
	}
	for _, bad := range []string{"", "-1Mi", "1.5Gi", "Mi", "1Ti", "1mi", "1 Gi"} {
		if _, err := ParseMemory(bad); err == nil {
			t.Errorf("memory %q must fail", bad)
		}
	}
}

func TestPolicyRuntimes(t *testing.T) {
	p, err := LoadPolicy(write(t, `{"maxAgents": 1, "allowedRuntimes": ["builtin", "container"], "runtimes": {"container": {"images": ["ghcr.io/acme/agents/"], "defaultResources": {"requests": {"cpu": "100m", "memory": "256Mi"}, "limits": {"cpu": "500m", "memory": "512Mi"}}, "maxResources": {"cpu": "1", "memory": "1Gi"}, "maxAgents": 3}}}`))
	if err != nil {
		t.Fatal(err)
	}
	if !p.RuntimeAllowed("container") || !p.RuntimeAllowed("builtin") || p.RuntimeAllowed("sandbox") {
		t.Fatal("RuntimeAllowed")
	}
	if !p.ImageAllowed("ghcr.io/acme/agents/echo-go@sha256:"+strings.Repeat("0", 64)) || p.ImageAllowed("ghcr.io/acme/agentsx/echo@sha256:"+strings.Repeat("0", 64)) || p.ImageAllowed("ghcr.io/acme/agents/") == false {
		// the last is a prefix check only: shape is ImageRE's job
		t.Fatal("ImageAllowed")
	}
	// absent or empty means builtin only
	for _, in := range []string{`{"maxAgents": 1}`, `{"maxAgents": 1, "allowedRuntimes": []}`} {
		q, err := LoadPolicy(write(t, in))
		if err != nil {
			t.Fatal(err)
		}
		if !q.RuntimeAllowed("builtin") || q.RuntimeAllowed("container") || q.ImageAllowed("ghcr.io/x/y") {
			t.Fatalf("default policy must allow builtin only: %s", in)
		}
	}
	// resolution: user values win per field, requests default to the policy defaults, limits are always set
	r := p.ResolveContainerResources(nil)
	if r.Requests.CPU != "100m" || r.Requests.Memory != "256Mi" || r.Limits.CPU != "500m" || r.Limits.Memory != "512Mi" {
		t.Fatalf("%+v", r)
	}
	r = p.ResolveContainerResources(&api.Resources{Requests: api.ResourceList{CPU: "200m"}, Limits: api.ResourceList{Memory: "1Gi"}})
	if r.Requests.CPU != "200m" || r.Requests.Memory != "256Mi" || r.Limits.CPU != "500m" || r.Limits.Memory != "1Gi" {
		t.Fatalf("%+v", r)
	}
	// without any configuration there are still defaults and a ceiling
	var z Policy
	if r := z.ResolveContainerResources(nil); r.Limits.CPU == "" || r.Limits.Memory == "" || r.Requests.CPU == "" {
		t.Fatalf("%+v", r)
	}
	if m := z.ContainerMax(); m.CPU == "" || m.Memory == "" {
		t.Fatalf("%+v", m)
	}
}

func TestLoadPolicyRuntimeRefusals(t *testing.T) {
	for name, c := range map[string]struct{ in, want string }{
		"prefix without slash":   {`{"maxAgents": 1, "runtimes": {"container": {"images": ["ghcr.io/acme/agents"]}}}`, "runtimes.container.images"},
		"prefix with a tag":      {`{"maxAgents": 1, "runtimes": {"container": {"images": ["ghcr.io/acme/agents:v1/"]}}}`, "runtimes.container.images"},
		"prefix upper case":      {`{"maxAgents": 1, "runtimes": {"container": {"images": ["GHCR.io/acme/"]}}}`, "runtimes.container.images"},
		"prefix a bare host":     {`{"maxAgents": 1, "runtimes": {"container": {"images": ["ghcr.io/"]}}}`, "runtimes.container.images"},
		"prefix a star":          {`{"maxAgents": 1, "runtimes": {"container": {"images": ["*"]}}}`, "runtimes.container.images"},
		"prefix twice":           {`{"maxAgents": 1, "runtimes": {"container": {"images": ["a.io/b/", "a.io/b/"]}}}`, "twice"},
		"bad quantity":           {`{"maxAgents": 1, "runtimes": {"container": {"maxResources": {"cpu": "lots"}}}}`, "maxResources.cpu"},
		"defaults above max":     {`{"maxAgents": 1, "runtimes": {"container": {"defaultResources": {"limits": {"memory": "2Gi"}}, "maxResources": {"memory": "1Gi"}}}}`, "above"},
		"requests above limits":  {`{"maxAgents": 1, "runtimes": {"container": {"defaultResources": {"requests": {"cpu": "2"}, "limits": {"cpu": "1"}}}}}`, "requests"},
		"negative max agents":    {`{"maxAgents": 1, "runtimes": {"container": {"maxAgents": -1}}}`, "runtimes.container.maxAgents"},
		"unknown allowed type":   {`{"maxAgents": 1, "allowedRuntimes": ["vm"]}`, "allowedRuntimes"},
		"unknown runtimes field": {`{"maxAgents": 1, "runtimes": {"container": {"privileged": true}}}`, "unknown field"},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := LoadPolicy(write(t, c.in))
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("want %q, got %v", c.want, err)
			}
		})
	}
}

func TestPolicyAllows(t *testing.T) {
	p := Policy{AllowedModels: []string{"a"}, AllowedProfiles: []string{"*"}}
	if !p.ModelAllowed("a") || p.ModelAllowed("b") {
		t.Fatal("exact match")
	}
	if !p.ProfileAllowed("anything") {
		t.Fatal("star allows every catalog profile")
	}
	if (&Policy{}).SkillAllowed("x") {
		t.Fatal("empty list allows nothing")
	}
}

func TestPolicyInClusterDestinationsAndSuspendAll(t *testing.T) {
	p, err := LoadPolicy(write(t, `{"maxAgents": 1, "suspendAll": true, "egress": {"inClusterDestinations": ["registry.ci.svc:5000", "db.data.svc.cluster.local:5432", "x.ns:80"]}}`))
	if err != nil {
		t.Fatal(err)
	}
	if !p.SuspendAll || len(p.Egress.InClusterDestinations) != 3 {
		t.Fatalf("%+v", p)
	}
	if !p.InClusterAllowed("registry.ci.svc:5000") || p.InClusterAllowed("registry.ci.svc:5001") || p.InClusterAllowed("other.ci.svc:5000") {
		t.Fatal("exact host and port only")
	}
	if (&Policy{}).InClusterAllowed("registry.ci.svc:5000") {
		t.Fatal("the default is none")
	}
}

func TestPolicyAgainstCatalogRefusesInClusterDestinationInTheToolsNamespace(t *testing.T) {
	c, err := LoadCatalog("../../testdata/catalog.json")
	if err != nil {
		t.Fatal(err)
	}
	p := &Policy{Egress: PolicyEgress{InClusterDestinations: []string{"vmcp.mcp-tools.svc:4483"}}}
	if err := CheckPolicy(c, p); err == nil || !strings.Contains(err.Error(), "tools namespace") {
		t.Fatalf("got %v", err)
	}
	p.Egress.InClusterDestinations = []string{"registry.ci.svc:5000"}
	if err := CheckPolicy(c, p); err != nil {
		t.Fatal(err)
	}
}

func TestReservedInNamespace(t *testing.T) {
	c := &Catalog{Namespaces: Namespaces{Agents: "kagent"}, ReservedNames: []string{"assistant"}}
	p := &Policy{ReservedNames: []string{"x", "team-a/y"}}
	for _, tc := range []struct {
		ns, name string
		want     bool
	}{
		{"kagent", "assistant", true}, {"team-a", "assistant", false}, // the catalog's names are the chart's, in the agents namespace
		{"kagent", "x", true}, {"team-a", "x", true}, // a bare name is reserved in every namespace
		{"team-a", "y", true}, {"kagent", "y", false}, // ns/name is reserved in that namespace only
	} {
		if got := ReservedIn(c, p, tc.ns, tc.name); got != tc.want {
			t.Errorf("%s/%s: got %v want %v", tc.ns, tc.name, got, tc.want)
		}
	}
}

// An operator can list an in-cluster destination, but never one that reaches a platform service around its own controls: the
// tools namespace, the agents namespace, the gateway namespace, kube-system or the Kubernetes API service (ADR 0012, M5).
func TestPolicyRefusesPlatformNamespacesAndTheKubernetesAPIInClusterDestinations(t *testing.T) {
	c, _ := LoadCatalog("../../testdata/catalog.json")
	var tb struct{ ForbiddenInCluster []string }
	b, err := os.ReadFile("../../testdata/egress-hosts.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, &tb); err != nil {
		t.Fatal(err)
	}
	if len(tb.ForbiddenInCluster) < 6 {
		t.Fatalf("the table of forbidden destinations shrank: %v", tb.ForbiddenInCluster)
	}
	for _, d := range tb.ForbiddenInCluster {
		p := &Policy{Egress: PolicyEgress{InClusterDestinations: []string{d}}}
		if err := CheckPolicy(c, p); err == nil || !strings.Contains(err.Error(), "can never be listed") {
			t.Errorf("%s must be refused at start-up with 'can never be listed', got %v", d, err)
		}
	}
	for _, d := range []string{"registry.ci.svc:5000", "db.data.svc.cluster.local:5432", "docs.kagent.dev:443", "x.mcp-tools.dev:443"} {
		if err := CheckPolicy(c, &Policy{Egress: PolicyEgress{InClusterDestinations: []string{d}}}); err != nil {
			t.Errorf("%s is fine to list: %v", d, err)
		}
	}
}
