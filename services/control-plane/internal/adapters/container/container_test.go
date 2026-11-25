package container

import (
	"context"
	"encoding/json"
	"flag"
	"os"
	"slices"
	"strings"
	"testing"

	"github.com/openagentix/openagentix/services/control-plane/internal/api"
	"github.com/openagentix/openagentix/services/control-plane/internal/catalog"
	"github.com/openagentix/openagentix/services/control-plane/internal/kube"
	"github.com/openagentix/openagentix/services/control-plane/internal/plan"
)

var update = flag.Bool("update", false, "rewrite testdata/golden-container.json and testdata/container-objects.json")

const (
	goldenPath  = "../../../testdata/golden-container.json"
	objectsPath = "../../../testdata/container-objects.json"
	keyValue    = "vk-0123456789abcdef0123456789abcdef"
)

func cat() *catalog.Catalog {
	return &catalog.Catalog{
		GatewayBaseURL: "http://model-gateway.agentgateway-system.svc.cluster.local/v1",
		GateURL:        "http://a2a-gate.openagentix-gateway.svc.cluster.local:8080",
		Runtime: catalog.RuntimeSections{Container: &catalog.ContainerSettings{
			Namespace: "openagentix-agents", GatewayNamespace: "agentgateway-system", GatewayPodSelector: map[string]string{"app": "model-gateway"},
			GatewayPort: 8080, GateNamespace: "openagentix-gateway", GatePodSelector: map[string]string{"app": "a2a-gate"},
			DNSNamespace: "kube-system", WorkloadPort: 8080,
		}},
	}
}

func samplePlan() plan.Plan {
	return plan.Plan{
		Name: "echo-go", Namespace: "kagent", Model: "claude-haiku", GatewayBaseURL: cat().GatewayBaseURL,
		KeySecret: "echo-go-virtual-key-0a1b2c3d", KeyFingerprint: "abcdef012345", RuntimeType: api.RuntimeContainer,
		Container: &plan.ContainerSpec{
			Image: "ghcr.io/acme/agents/echo-go@sha256:" + strings.Repeat("a", 64), Port: 9000,
			Env:       []api.EnvVar{{Name: "A_FLAG", Value: "1"}, {Name: "LOG_LEVEL", Value: "info"}},
			Resources: api.Resources{Requests: api.ResourceList{CPU: "100m", Memory: "256Mi"}, Limits: api.ResourceList{CPU: "500m", Memory: "512Mi"}},
		},
	}
}

func render(t *testing.T, p plan.Plan, c *catalog.Catalog) []kube.Manifest {
	t.Helper()
	ms, err := New(c, nil).Desired(p)
	if err != nil {
		t.Fatal(err)
	}
	return ms
}

func objects(ms []kube.Manifest) []any {
	out := []any{}
	for _, m := range ms {
		out = append(out, m.Object)
	}
	return out
}

func pretty(v any) string { b, _ := json.MarshalIndent(v, "", "  "); return string(b) + "\n" }

func TestGoldenAndTheObjectsTheGuardIsFedWith(t *testing.T) {
	ms := render(t, samplePlan(), cat())
	for _, m := range ms {
		if m.Namespace != "openagentix-agents" || kube.Meta(m.Object).String("namespace") != "openagentix-agents" {
			t.Fatalf("every object goes to the workload namespace: %+v", m)
		}
	}
	if *update {
		if err := os.WriteFile(goldenPath, []byte(pretty(objects(ms))), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(objectsPath, []byte(pretty(map[string]any{"apiVersion": "v1", "kind": "List", "items": stamp(ms)})), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(goldenPath)
	if err != nil {
		t.Fatalf("%v (run: go test ./internal/adapters/container -update)", err)
	}
	if got := pretty(objects(ms)); got != string(want) {
		t.Fatalf("golden differs; run with -update and review the diff:\n%s", got)
	}
}

// stamp is what the guard sees: the adapter's objects with what the core stamps on them (labels, the UID annotation).
func stamp(ms []kube.Manifest) []any {
	var stamped []any
	for _, m := range ms {
		o := deepCopy(m.Object)
		md := kube.Meta(o)
		l, _ := md["labels"].(map[string]any)
		l[api.LabelManagedBy], l[api.LabelDefinition], l[api.LabelDefinitionNamespace] = api.ManagedByValue, "echo-go", "kagent"
		an, _ := md["annotations"].(map[string]any)
		if an == nil {
			an = map[string]any{}
		}
		an[api.AnnotationDefinitionUID] = "0a1b2c3d-1111-4222-8333-444444444444"
		md["annotations"] = an
		stamped = append(stamped, o)
	}
	return stamped
}

func deepCopy(o kube.Object) kube.Object {
	b, _ := json.Marshal(o)
	var c kube.Object
	_ = json.Unmarshal(b, &c)
	return c
}

func byKind(ms []kube.Manifest, kind string) kube.Object {
	for _, m := range ms {
		if m.Resource.Kind == kind {
			return deepCopy(m.Object)
		}
	}
	return nil
}

func dig(t *testing.T, o any, path ...string) any {
	t.Helper()
	for _, p := range path {
		m, ok := o.(map[string]any)
		if !ok {
			t.Fatalf("not a map at %q", p)
		}
		o = m[p]
	}
	return o
}

func TestKeyCanary(t *testing.T) {
	p := samplePlan()
	b, _ := json.Marshal(objects(render(t, p, cat())))
	if strings.Contains(string(b), keyValue) || strings.Contains(string(b), "vk-") {
		t.Fatal("a key value is in the manifests")
	}
	d := byKind(render(t, p, cat()), "Deployment")
	env := dig(t, d, "spec", "template", "spec", "containers").([]any)[0].(map[string]any)["env"].([]any)
	first := env[0].(map[string]any)
	ref := dig(t, first, "valueFrom", "secretKeyRef").(map[string]any)
	if first["name"] != "OPENAI_API_KEY" || ref["name"] != p.KeySecret || ref["key"] != "OPENAI_API_KEY" || first["value"] != nil {
		t.Fatalf("the manifest holds only the Secret's name: %v", first)
	}
	names := []string{}
	for _, e := range env {
		names = append(names, e.(map[string]any)["name"].(string))
	}
	if strings.Join(names, ",") != "OPENAI_API_KEY,OPENAI_BASE_URL,OPENAGENTIX_MODEL,A_FLAG,LOG_LEVEL" {
		t.Fatalf("env order: %v", names)
	}
}

func TestPodSecurity(t *testing.T) {
	d := byKind(render(t, samplePlan(), cat()), "Deployment")
	pod := dig(t, d, "spec", "template", "spec").(map[string]any)
	psc := pod["securityContext"].(map[string]any)
	if psc["runAsNonRoot"] != true || psc["runAsUser"] != float64(65532) || psc["runAsGroup"] != float64(65532) || dig(t, psc, "seccompProfile", "type") != "RuntimeDefault" {
		t.Fatalf("%v", psc)
	}
	if pod["automountServiceAccountToken"] != false || pod["enableServiceLinks"] != false || pod["serviceAccountName"] != "echo-go" {
		t.Fatalf("%v", pod)
	}
	for _, bad := range []string{"hostNetwork", "hostPID", "hostIPC", "runtimeClassName", "initContainers", "ephemeralContainers", "nodeName", "hostAliases"} {
		if _, ok := pod[bad]; ok {
			t.Errorf("pod must not set %s", bad)
		}
	}
	cs := pod["containers"].([]any)
	if len(cs) != 1 {
		t.Fatal("exactly one container")
	}
	c := cs[0].(map[string]any)
	sc := c["securityContext"].(map[string]any)
	if c["name"] != "agent" || sc["allowPrivilegeEscalation"] != false || sc["readOnlyRootFilesystem"] != true || sc["privileged"] != nil || dig(t, sc, "capabilities", "drop").([]any)[0] != "ALL" {
		t.Fatalf("%v", c)
	}
	if dig(t, c, "resources", "limits", "memory") != "512Mi" || dig(t, c, "resources", "requests", "cpu") != "100m" {
		t.Fatalf("%v", c["resources"])
	}
	vols := pod["volumes"].([]any)
	if len(vols) != 1 || dig(t, vols[0], "emptyDir", "sizeLimit") != "256Mi" || vols[0].(map[string]any)["name"] != "tmp" {
		t.Fatalf("only the /tmp emptyDir: %v", vols)
	}
	if dig(t, c, "readinessProbe", "httpGet", "path") != "/.well-known/agent-card.json" || dig(t, c, "readinessProbe", "periodSeconds") != float64(5) ||
		dig(t, c, "livenessProbe", "periodSeconds") != float64(30) || dig(t, c, "livenessProbe", "failureThreshold") != float64(3) {
		t.Fatalf("probes: %v %v", c["readinessProbe"], c["livenessProbe"])
	}
	if dig(t, byKind(render(t, samplePlan(), cat()), "ServiceAccount"), "automountServiceAccountToken") != false {
		t.Fatal("service account token")
	}
	if dig(t, d, "spec", "template", "metadata", "annotations", "openagentix.io/key-fingerprint") != "abcdef012345" {
		t.Fatal("the key fingerprint rolls the pod when the key is replaced")
	}
	if dig(t, d, "spec", "replicas") != float64(1) {
		t.Fatal("replicas")
	}
	// suspended: replicas 0; a RuntimeClass appears only when the catalog names one
	p := samplePlan()
	p.Suspended = true
	c2 := cat()
	c2.Runtime.Container.RuntimeClassName = "gvisor"
	d2 := byKind(render(t, p, c2), "Deployment")
	if dig(t, d2, "spec", "replicas") != float64(0) || dig(t, d2, "spec", "template", "spec", "runtimeClassName") != "gvisor" {
		t.Fatal("suspend and runtime class")
	}
	if got := New(c2, nil).Capabilities().Isolation; got != "sandboxed-pod" {
		t.Fatal(got)
	}
	if got := New(cat(), nil).Capabilities().Isolation; got != "container" {
		t.Fatal(got)
	}
}

// The documented key set: nothing the adapter writes is outside it. The chart's admission guard is built from the same set.
func TestNoKeyOutsideTheDocumentedSet(t *testing.T) {
	allowed := map[string][]string{
		"Deployment":     {"apiVersion", "kind", "metadata", "spec"},
		"Service":        {"apiVersion", "kind", "metadata", "spec"},
		"ServiceAccount": {"apiVersion", "kind", "metadata", "automountServiceAccountToken"},
		"NetworkPolicy":  {"apiVersion", "kind", "metadata", "spec"},
	}
	deploySpec := []string{"replicas", "selector", "template"}
	podSpec := []string{"serviceAccountName", "automountServiceAccountToken", "enableServiceLinks", "securityContext", "containers", "volumes", "runtimeClassName"}
	container := []string{"name", "image", "imagePullPolicy", "ports", "env", "resources", "securityContext", "volumeMounts", "readinessProbe", "livenessProbe"}
	in := func(k string, l []string) bool {
		for _, x := range l {
			if x == k {
				return true
			}
		}
		return false
	}
	c2 := cat()
	c2.Runtime.Container.RuntimeClassName = "gvisor"
	for _, m := range render(t, samplePlan(), c2) {
		for k := range m.Object {
			if !in(k, allowed[m.Resource.Kind]) {
				t.Errorf("%s: key %s is not in the documented set", m.Resource.Kind, k)
			}
		}
		for k := range kube.Meta(m.Object) {
			if !in(k, []string{"name", "namespace", "labels"}) {
				t.Errorf("%s: metadata.%s is not in the documented set", m.Resource.Kind, k)
			}
		}
		if m.Resource.Kind != "Deployment" {
			continue
		}
		spec := dig(t, m.Object, "spec").(map[string]any)
		for k := range spec {
			if !in(k, deploySpec) {
				t.Errorf("deployment spec.%s", k)
			}
		}
		pod := dig(t, spec, "template", "spec").(map[string]any)
		for k := range pod {
			if !in(k, podSpec) {
				t.Errorf("pod spec.%s", k)
			}
		}
		for k := range pod["containers"].([]any)[0].(map[string]any) {
			if !in(k, container) {
				t.Errorf("container.%s", k)
			}
		}
	}
}

func TestServiceAndNetworkPolicy(t *testing.T) {
	ms := render(t, samplePlan(), cat())
	svc := byKind(ms, "Service")
	ports := dig(t, svc, "spec", "ports").([]any)
	pt := ports[0].(map[string]any)
	if len(ports) != 1 || pt["name"] != "a2a" || pt["port"] != float64(8080) || pt["protocol"] != "TCP" || pt["targetPort"] != float64(9000) ||
		dig(t, svc, "spec", "type") != "ClusterIP" || dig(t, svc, "spec", "selector", "openagentix.io/agent") != "echo-go" {
		t.Fatalf("%v", svc)
	}
	np := byKind(ms, "NetworkPolicy")
	if dig(t, np, "spec", "podSelector", "matchLabels", "openagentix.io/agent") != "echo-go" {
		t.Fatal("podSelector")
	}
	if b, _ := json.Marshal(np); strings.Contains(string(b), "ipBlock") || strings.Contains(string(b), `{}`) {
		t.Fatalf("no ipBlock and no empty peer: %s", b)
	}
	in := dig(t, np, "spec", "ingress").([]any)
	if len(in) != 1 {
		t.Fatal("one ingress rule")
	}
	from := dig(t, in[0], "from").([]any)[0]
	if dig(t, from, "namespaceSelector", "matchLabels", "kubernetes.io/metadata.name") != "openagentix-gateway" || dig(t, from, "podSelector", "matchLabels", "app") != "a2a-gate" {
		t.Fatalf("%v", from)
	}
	if dig(t, in[0], "ports").([]any)[0].(map[string]any)["port"] != float64(9000) {
		t.Fatal("ingress on the container port")
	}
	eg := dig(t, np, "spec", "egress").([]any)
	if len(eg) != 2 {
		t.Fatalf("egress: DNS and the gateway only: %v", eg)
	}
	dns := eg[0].(map[string]any)
	if dig(t, dns["to"].([]any)[0], "namespaceSelector", "matchLabels", "kubernetes.io/metadata.name") != "kube-system" || dig(t, dns["to"].([]any)[0], "podSelector", "matchLabels", "k8s-app") != "kube-dns" || len(dns["ports"].([]any)) != 2 {
		t.Fatalf("%v", dns)
	}
	gw := eg[1].(map[string]any)
	if dig(t, gw["to"].([]any)[0], "namespaceSelector", "matchLabels", "kubernetes.io/metadata.name") != "agentgateway-system" || gw["ports"].([]any)[0].(map[string]any)["port"] != float64(8080) {
		t.Fatalf("%v", gw)
	}
	if pt := dig(t, np, "spec", "policyTypes").([]any); len(pt) != 2 || pt[0] != "Ingress" || pt[1] != "Egress" {
		t.Fatalf("%v", pt)
	}
}

func TestRefEndpointAndNames(t *testing.T) {
	a := New(cat(), nil)
	p := samplePlan()
	if r := a.Ref(p); r.APIVersion != "apps/v1" || r.Kind != "Deployment" || r.Name != "echo-go" {
		t.Fatalf("%+v", r)
	}
	if e := a.Endpoint(p); e == nil || e.Protocol != "a2a" || e.ProtocolVersion != "1.0" || e.URL != "http://a2a-gate.openagentix-gateway.svc.cluster.local:8080/agents/kagent/echo-go" {
		t.Fatalf("%+v", e)
	}
	c := cat()
	c.GateURL = ""
	if New(c, nil).Endpoint(p) != nil {
		t.Fatal("no gate, no endpoint")
	}
	if a.Name() != "container" || a.KeyDataKey() != "OPENAI_API_KEY" || a.WorkloadNamespace() != "openagentix-agents" {
		t.Fatal("identity")
	}
	var kinds []string
	for _, k := range a.OwnedKinds() {
		kinds = append(kinds, k.Plural)
	}
	if strings.Join(kinds, ",") != "deployments,services,serviceaccounts,networkpolicies" {
		t.Fatal(kinds)
	}
	caps := a.Capabilities()
	if caps.Approvals != api.Unknown || caps.DurableWaits != api.Unknown || caps.WorkspacePersistence != "none" || caps.MaxStepSeconds != 0 || caps.CancelStopsLoop != api.Unknown || caps.PerRunIdentity != "none" {
		t.Fatalf("%+v", caps)
	}
}

type fakeGet struct {
	o   kube.Object
	err error
}

func (f fakeGet) Get(context.Context, kube.Resource, string, string) (kube.Object, error) {
	return f.o, f.err
}

func deploy(gen, observed float64, avail float64, conds ...map[string]any) kube.Object {
	cs := []any{}
	for _, c := range conds {
		cs = append(cs, c)
	}
	return kube.Object{"metadata": map[string]any{"generation": gen}, "status": map[string]any{"observedGeneration": observed, "availableReplicas": avail, "conditions": cs}}
}

func cond(t, s, reason, msg string) map[string]any {
	return map[string]any{"type": t, "status": s, "reason": reason, "message": msg}
}

// toolsPlan is samplePlan with the tool profile lookup (ADR 0019).
func toolsPlan() plan.Plan {
	p := samplePlan()
	p.ToolAccess = &plan.ToolAccess{Profile: "lookup", URL: "http://vmcp-tools-lookup-workload.mcp-tools.svc.cluster.local:4483/mcp",
		Audience: "openagentix-vmcp-lookup-workload", Namespace: "mcp-tools",
		PodSelector: map[string]string{"app": "virtualmcpserver", "toolhive-name": "tools-lookup-workload"}, Port: 4483}
	return p
}

const (
	goldenToolsPath  = "../../../testdata/golden-container-tools.json"
	objectsToolsPath = "../../../testdata/container-objects-tools.json"
)

func TestGoldenWithAToolProfile(t *testing.T) {
	ms := render(t, toolsPlan(), cat())
	if *update {
		if err := os.WriteFile(goldenToolsPath, []byte(pretty(objects(ms))), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(objectsToolsPath, []byte(pretty(map[string]any{"apiVersion": "v1", "kind": "List", "items": stamp(ms)})), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(goldenToolsPath)
	if err != nil {
		t.Fatalf("%v (run: go test ./internal/adapters/container -update)", err)
	}
	if got := pretty(objects(ms)); got != string(want) {
		t.Fatalf("golden differs; run with -update and review the diff:\n%s", got)
	}
}

// With a profile the pod gets the URL, a token file the kubelet writes (no Secret), its profile label, and one more egress rule;
// nothing else changes. Without a profile nothing of this appears (TestGoldenAndTheObjectsTheGuardIsFedWith).
func TestToolAccess(t *testing.T) {
	ms := render(t, toolsPlan(), cat())
	d := byKind(ms, "Deployment")
	pod := dig(t, d, "spec", "template", "spec").(map[string]any)
	if pod["automountServiceAccountToken"] != false {
		t.Fatal("the pod still gets no token the Kubernetes API accepts")
	}
	if l := dig(t, d, "spec", "template", "metadata", "labels").(map[string]any); len(l) != 2 || l["openagentix.io/agent"] != "echo-go" || l["openagentix.io/tool-profile"] != "lookup" {
		t.Fatalf("pod labels: %v", l)
	}
	if sel := dig(t, d, "spec", "selector", "matchLabels").(map[string]any); len(sel) != 1 {
		t.Fatalf("the selector stays the agent label only: %v", sel)
	}
	c := pod["containers"].([]any)[0].(map[string]any)
	env := map[string]any{}
	var names []string
	for _, e := range c["env"].([]any) {
		e := e.(map[string]any)
		names = append(names, e["name"].(string))
		env[e["name"].(string)] = e["value"]
	}
	if strings.Join(names, ",") != "OPENAI_API_KEY,OPENAI_BASE_URL,OPENAGENTIX_MODEL,OPENAGENTIX_MCP_URL,OPENAGENTIX_MCP_TOKEN_FILE,A_FLAG,LOG_LEVEL" {
		t.Fatalf("env order: %v", names)
	}
	if env["OPENAGENTIX_MCP_URL"] != "http://vmcp-tools-lookup-workload.mcp-tools.svc.cluster.local:4483/mcp" || env["OPENAGENTIX_MCP_TOKEN_FILE"] != "/var/run/secrets/openagentix/mcp/token" {
		t.Fatalf("%v", env)
	}
	vols := pod["volumes"].([]any)
	if len(vols) != 2 || vols[0].(map[string]any)["name"] != "tmp" {
		t.Fatalf("%v", vols)
	}
	tok := vols[1].(map[string]any)
	srcs := dig(t, tok, "projected", "sources").([]any)
	if tok["name"] != "mcp-token" || len(srcs) != 1 || len(tok) != 2 {
		t.Fatalf("%v", tok)
	}
	sat := dig(t, srcs[0], "serviceAccountToken").(map[string]any)
	if len(srcs[0].(map[string]any)) != 1 || sat["audience"] != "openagentix-vmcp-lookup-workload" || sat["expirationSeconds"] != float64(3600) || sat["path"] != "token" || len(sat) != 3 {
		t.Fatalf("one ServiceAccount token, the profile's audience, one hour: %v", sat)
	}
	mounts := c["volumeMounts"].([]any)
	if len(mounts) != 2 || mounts[1].(map[string]any)["name"] != "mcp-token" || mounts[1].(map[string]any)["mountPath"] != "/var/run/secrets/openagentix/mcp" || mounts[1].(map[string]any)["readOnly"] != true {
		t.Fatalf("%v", mounts)
	}
	eg := dig(t, byKind(ms, "NetworkPolicy"), "spec", "egress").([]any)
	if len(eg) != 3 {
		t.Fatalf("DNS, the gateway and the profile's tool server: %v", eg)
	}
	to := eg[2].(map[string]any)["to"].([]any)
	if len(to) != 1 || dig(t, to[0], "namespaceSelector", "matchLabels", "kubernetes.io/metadata.name") != "mcp-tools" ||
		dig(t, to[0], "podSelector", "matchLabels", "toolhive-name") != "tools-lookup-workload" || eg[2].(map[string]any)["ports"].([]any)[0].(map[string]any)["port"] != float64(4483) {
		t.Fatalf("%v", eg[2])
	}
	// the other objects are those of an agent without tools
	plain := render(t, samplePlan(), cat())
	for _, k := range []string{"Service", "ServiceAccount"} {
		if pretty(byKind(ms, k)) != pretty(byKind(plain, k)) {
			t.Errorf("%s changed with a tool profile", k)
		}
	}
	b, _ := json.Marshal(objects(ms))
	if strings.Contains(string(b), "secretName") || strings.Contains(string(b), `"secret"`) {
		t.Fatal("the token comes from the kubelet, not from a Secret")
	}
}

func TestNoKeyOutsideTheDocumentedSetWithTools(t *testing.T) {
	podSpec := []string{"serviceAccountName", "automountServiceAccountToken", "enableServiceLinks", "securityContext", "containers", "volumes"}
	d := byKind(render(t, toolsPlan(), cat()), "Deployment")
	for k := range dig(t, d, "spec", "template", "spec").(map[string]any) {
		if !slices.Contains(podSpec, k) {
			t.Errorf("pod spec.%s", k)
		}
	}
}

func TestReadinessFromTheDeploymentStatusOnly(t *testing.T) {
	for name, c := range map[string]struct {
		get    fakeGet
		ready  bool
		reason string
		msg    string
	}{
		"not found": {fakeGet{err: &kube.Error{Code: 404}}, false, "RuntimeNotCreated", ""},
		"stale":     {fakeGet{o: deploy(3, 2, 1, cond("Available", "True", "", ""))}, false, "RuntimeStale", ""},
		"rejected":  {fakeGet{o: deploy(1, 1, 0, cond("ReplicaFailure", "True", "FailedCreate", "violates PodSecurity"))}, false, "RuntimeRejected", "violates PodSecurity"},
		"ready":     {fakeGet{o: deploy(1, 1, 1, cond("Available", "True", "", ""), cond("Progressing", "True", "", ""))}, true, "", ""},
		"deadline":  {fakeGet{o: deploy(1, 1, 0, cond("Available", "False", "", ""), cond("Progressing", "False", "ProgressDeadlineExceeded", "deadline exceeded"))}, false, "RuntimeNotReady", "readiness probe on the agent card failed or the image could not start (deadline exceeded)"},
		"pending":   {fakeGet{o: deploy(1, 1, 0, cond("Available", "False", "", ""), cond("Progressing", "True", "", ""))}, false, "RuntimePending", ""},
		"no conds":  {fakeGet{o: deploy(1, 1, 0)}, false, "RuntimePending", ""},
	} {
		t.Run(name, func(t *testing.T) {
			rd, err := New(cat(), c.get).Readiness(context.Background(), samplePlan())
			if err != nil {
				t.Fatal(err)
			}
			if rd.Ready != c.ready || rd.Reason != c.reason || (c.msg != "" && rd.Message != c.msg) {
				t.Fatalf("%+v", rd)
			}
			if rd.Reason != "" && !api.ValidReason(api.CondReady, rd.Reason) {
				t.Fatalf("%s is not in the documented table", rd.Reason)
			}
		})
	}
	if _, err := New(cat(), fakeGet{err: &kube.Error{Code: 500}}).Readiness(context.Background(), samplePlan()); err == nil {
		t.Fatal("a failed read is an error, not a verdict")
	}
}
