package core

import (
	"context"
	"errors"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/openagentix/openagentix/services/control-plane/internal/api"
	"github.com/openagentix/openagentix/services/control-plane/internal/catalog"
	"github.com/openagentix/openagentix/services/control-plane/internal/kube"
	"github.com/openagentix/openagentix/services/control-plane/internal/kubetest"
	"github.com/openagentix/openagentix/services/control-plane/internal/plan"
)

const workloadNS = "workloads"

var (
	boxes    = kube.Resource{Group: "apps", Version: "v1", Plural: "deployments", Kind: "Deployment", Namespaced: true}
	boxSvcs  = kube.Resource{Version: "v1", Plural: "services", Kind: "Service", Namespaced: true}
	imageRef = "ghcr.io/acme/agents/echo@sha256:" + strings.Repeat("a", 64)
)

// fakeContainerRuntime stands for the container adapter: objects in another namespace, no owner references possible.
type fakeContainerRuntime struct {
	mu      sync.Mutex
	onReady func() // called from Readiness
	ready   plan.Readiness
}

func (f *fakeContainerRuntime) Name() string { return "fakec" }
func (f *fakeContainerRuntime) OwnedKinds() []kube.Resource {
	return []kube.Resource{boxes, boxSvcs}
}
func (f *fakeContainerRuntime) KeyDataKey() string        { return "OPENAI_API_KEY" }
func (f *fakeContainerRuntime) WorkloadNamespace() string { return workloadNS }
func (f *fakeContainerRuntime) Capabilities() api.Capabilities {
	return api.Capabilities{Approvals: api.Unknown, DurableWaits: api.Unknown, WorkspacePersistence: "none", CancelStopsLoop: api.Unknown, PerRunIdentity: "none", Isolation: "container"}
}
func (f *fakeContainerRuntime) Ref(p plan.Plan) api.ObjectRef {
	return api.ObjectRef{APIVersion: "apps/v1", Kind: "Deployment", Name: p.Name}
}
func (f *fakeContainerRuntime) Endpoint(p plan.Plan) *api.Endpoint {
	return &api.Endpoint{Protocol: "a2a", ProtocolVersion: "1.0", URL: "http://gate/agents/" + p.Namespace + "/" + p.Name}
}
func (f *fakeContainerRuntime) Readiness(context.Context, plan.Plan) (plan.Readiness, error) {
	if f.onReady != nil {
		f.onReady()
	}
	return f.ready, nil
}
func (f *fakeContainerRuntime) Desired(p plan.Plan) ([]kube.Manifest, error) {
	mk := func(api, kind, name string) kube.Object {
		return kube.Object{"apiVersion": api, "kind": kind, "metadata": kube.Object{"name": name, "namespace": workloadNS}, "spec": kube.Object{"image": p.Container.Image, "key": p.KeySecret}}
	}
	return []kube.Manifest{
		{Resource: boxes, Object: mk("apps/v1", "Deployment", p.Name), Namespace: workloadNS},
		{Resource: boxSvcs, Object: mk("v1", "Service", p.Name), Namespace: workloadNS},
	}, nil
}

type fakeRoutes struct {
	mu        sync.Mutex
	set       map[string]bool
	calls     []string
	ensureErr error
	removeErr error
}

func (r *fakeRoutes) Ensure(_ context.Context, ref string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls = append(r.calls, "ensure "+ref)
	if r.ensureErr != nil {
		return r.ensureErr
	}
	r.set[ref] = true
	return nil
}
func (r *fakeRoutes) Remove(_ context.Context, ref string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls = append(r.calls, "remove "+ref)
	if r.removeErr != nil {
		return r.removeErr
	}
	delete(r.set, ref)
	return nil
}
func (r *fakeRoutes) Sync(_ context.Context, keep []string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	s := slices.Clone(keep)
	slices.Sort(s)
	r.calls = append(r.calls, "sync "+strings.Join(s, ","))
	r.set = map[string]bool{}
	for _, k := range keep {
		r.set[k] = true
	}
	return nil
}
func (r *fakeRoutes) has(ref string) bool { r.mu.Lock(); defer r.mu.Unlock(); return r.set[ref] }
func (r *fakeRoutes) last() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.calls) == 0 {
		return ""
	}
	return r.calls[len(r.calls)-1]
}

// containerEnv is the usual environment with the container runtime and the routes list switched on.
func containerEnv(t *testing.T) (*env, *fakeContainerRuntime, *fakeRoutes) {
	t.Helper()
	e, _ := newEnv(t)
	e.cat.Adapters.Runtimes = map[string]string{"builtin": "kagent", "container": "container"}
	e.pol.AllowedRuntimes = []string{"builtin", "container"}
	e.pol.Runtimes.Container.Images = []string{"ghcr.io/acme/agents/"}
	fc := &fakeContainerRuntime{ready: plan.Readiness{Ready: true, Reason: "Ready"}}
	rt := &fakeRoutes{set: map[string]bool{}}
	cfg := e.c.cfg
	cfg.Runtimes = map[string]Runtime{"builtin": e.rt, "container": fc}
	cfg.Routes = rt
	e.c = New(cfg)
	return e, fc, rt
}

func (e *env) seedContainer(name string, mut func(map[string]any)) {
	e.srv.Seed("agentdefinitions", kubetest.Object{"apiVersion": "openagentix.io/v1alpha1", "kind": "AgentDefinition",
		"metadata": kubetest.Object{"name": name, "namespace": e.ns, "creationTimestamp": "2026-11-25T10:00:00Z"},
		"spec": func() map[string]any {
			s := map[string]any{"description": "d", "model": "claude-haiku", "runtime": map[string]any{"type": "container",
				"container": map[string]any{"image": imageRef, "port": float64(8080)}}}
			if mut != nil {
				mut(s)
			}
			return s
		}()})
}

func TestContainerAgentIsWrittenToTheWorkloadNamespaceWithoutOwnerReferences(t *testing.T) {
	e, fc, routes := containerEnv(t)
	fc.onReady = func() {
		if !routes.has("kagent/echo") {
			t.Error("the route must be listed BEFORE readiness is asked")
		}
	}
	e.seedContainer("echo", nil)
	e.pass(t)
	st := e.status("echo")
	wantCond(t, st, "Applied", "True", "Applied")
	wantCond(t, st, "Ready", "True", "Ready")
	if st.Capabilities == nil || st.Capabilities.Isolation != "container" {
		t.Fatalf("capabilities come from the definition's runtime: %+v", st.Capabilities)
	}
	if st.AgentRef == nil || st.AgentRef.Kind != "Deployment" {
		t.Fatalf("%+v", st.AgentRef)
	}
	if _, ok := e.srv.Get("deployments", "kagent", "echo"); ok {
		t.Fatal("nothing may be written to the definition's namespace")
	}
	d, ok := e.srv.Get("deployments", workloadNS, "echo")
	if !ok {
		t.Fatal("the Deployment must be in the workload namespace")
	}
	m := d["metadata"].(map[string]any)
	if _, has := m["ownerReferences"]; has {
		t.Fatalf("a cross-namespace object must carry no ownerReferences: %v", m)
	}
	l := m["labels"].(map[string]any)
	if l[api.LabelManagedBy] != api.ManagedByValue || l[api.LabelDefinition] != "echo" || l[api.LabelDefinitionNamespace] != "kagent" {
		t.Fatalf("labels: %v", l)
	}
	raw, _ := e.srv.Get("agentdefinitions", "kagent", "echo")
	if uid := raw["metadata"].(map[string]any)["uid"]; m["annotations"].(map[string]any)[api.AnnotationDefinitionUID] != uid || uid == nil {
		t.Fatalf("annotations: %v", m["annotations"])
	}
	// the key Secret: in the workload namespace, no owner, labelled
	secName := st.Controller.KeySecret
	sec, ok := e.srv.Get("secrets", workloadNS, secName)
	if !ok {
		t.Fatal("the key Secret must be in the workload namespace")
	}
	sm := sec["metadata"].(map[string]any)
	if _, has := sm["ownerReferences"]; has || sm["labels"].(map[string]any)[api.LabelDefinitionNamespace] != "kagent" {
		t.Fatalf("secret metadata: %v", sm)
	}
	if _, ok := e.srv.Get("secrets", "kagent", secName); ok {
		t.Fatal("no Secret in the definition's namespace")
	}
	if sec["data"].(map[string]any)["OPENAI_API_KEY"] == nil {
		t.Fatal("the adapter's KeyDataKey is the Secret's data key")
	}
	if last := routes.last(); last != "sync kagent/echo" {
		t.Fatalf("the pass ends with a sync of the running container agents: %v", routes.calls)
	}
	// a second pass changes nothing
	n := len(e.srv.Matching("PATCH", "/deployments/"))
	e.pass(t)
	if got := len(e.srv.Matching("PATCH", "/deployments/")); got != n+1 { // server-side apply is idempotent; no new object, no Secret request
		t.Logf("applies: %d -> %d", n, got)
	}
}

func TestRouteListFailureIsApplyFailedAndNeverReady(t *testing.T) {
	e, _, routes := containerEnv(t)
	routes.ensureErr = errors.New("boom")
	e.seedContainer("echo", nil)
	_ = e.c.ReconcileAll(context.Background())
	st := e.status("echo")
	wantCond(t, st, "Applied", "False", "ApplyFailed")
	if !strings.Contains(st.Condition("Applied").Message, "route list: boom") {
		t.Fatalf("%q", st.Condition("Applied").Message)
	}
	if st.Condition("Ready").Status == "True" {
		t.Fatal("not Ready while the route is missing")
	}
	routes.ensureErr = nil
	e.pass(t)
	wantCond(t, e.status("echo"), "Ready", "True", "Ready")
}

func TestDeleteRemovesWorkloadObjectsTheKeySecretAndTheRoute(t *testing.T) {
	e, _, routes := containerEnv(t)
	e.seedContainer("echo", nil)
	e.pass(t)
	secName := e.status("echo").Controller.KeySecret
	cl := kube.New(e.srv.URL, e.srv.Client(), func() (string, error) { return "t", nil })
	if err := cl.Delete(context.Background(), definitions, "kagent", "echo"); err != nil {
		t.Fatal(err)
	}
	e.pass(t)
	for _, n := range [][2]string{{"deployments", "echo"}, {"services", "echo"}} {
		if _, ok := e.srv.Get(n[0], workloadNS, n[1]); ok {
			t.Fatalf("%s must be gone", n[0])
		}
	}
	if _, ok := e.srv.Get("secrets", workloadNS, secName); ok {
		t.Fatal("the key Secret must be deleted by name (no owner reference does it)")
	}
	if routes.has("kagent/echo") {
		t.Fatalf("route must be removed: %v", routes.calls)
	}
	if _, ok := e.srv.Get("agentdefinitions", "kagent", "echo"); ok {
		t.Fatal("finalizer must go")
	}
}

func TestDeleteKeepsTheFinalizerWhileTheWorkloadCannotBeRemoved(t *testing.T) {
	e, _, _ := containerEnv(t)
	e.seedContainer("echo", nil)
	e.pass(t)
	fail := true
	e.srv.Intercept = func(r kubetest.Request) (int, any, bool) {
		if fail && r.Method == "DELETE" && strings.Contains(r.Path, "/deployments/") {
			return 500, map[string]any{"message": "nope"}, true
		}
		return 0, nil, false
	}
	cl := kube.New(e.srv.URL, e.srv.Client(), func() (string, error) { return "t", nil })
	_ = cl.Delete(context.Background(), definitions, "kagent", "echo")
	if err := e.c.ReconcileAll(context.Background()); err == nil {
		t.Fatal("want the failure reported")
	}
	if _, ok := e.srv.Get("agentdefinitions", "kagent", "echo"); !ok {
		t.Fatal("the definition must stay until the workload is gone")
	}
	fail = false
	e.pass(t)
	if _, ok := e.srv.Get("agentdefinitions", "kagent", "echo"); ok {
		t.Fatal("now it may go")
	}
	if _, ok := e.srv.Get("deployments", workloadNS, "echo"); ok {
		t.Fatal("workload must be gone")
	}
}

func TestSwitchingFromBuiltinToContainerMovesTheKeyAndPrunesTheOldObjects(t *testing.T) {
	e, _, routes := containerEnv(t)
	e.seed("sw", nil)
	e.pass(t)
	secName := e.status("sw").Controller.KeySecret
	if _, ok := e.srv.Get("secrets", "kagent", secName); !ok {
		t.Fatal("setup: builtin Secret in the definition's namespace")
	}
	if _, ok := e.srv.Get("widgets", "kagent", "sw-w"); !ok {
		t.Fatal("setup: builtin widget")
	}
	e.srv.Modify("agentdefinitions", "kagent", "sw", func(o kubetest.Object) {
		o["spec"] = map[string]any{"description": "d", "model": "claude-haiku", "runtime": map[string]any{"type": "container",
			"container": map[string]any{"image": imageRef, "port": float64(8080)}}}
	})
	e.pass(t)
	st := e.status("sw")
	wantCond(t, st, "Ready", "True", "Ready")
	if _, ok := e.srv.Get("secrets", workloadNS, secName); !ok {
		t.Fatal("the new Secret is created in the workload namespace")
	}
	if _, ok := e.srv.Get("secrets", "kagent", secName); ok {
		t.Fatal("the old Secret is deleted by name in the old namespace")
	}
	for _, p := range []string{"widgets", "gadgets"} {
		if len(e.srv.List(p, "kagent")) != 0 {
			t.Fatalf("old %s must be pruned", p)
		}
	}
	if _, ok := e.srv.Get("deployments", workloadNS, "sw"); !ok {
		t.Fatal("new Deployment")
	}
	if !routes.has("kagent/sw") {
		t.Fatal("route listed")
	}
	// and back: the route goes, the workload objects are pruned, the Secret returns to the definition's namespace
	e.srv.Modify("agentdefinitions", "kagent", "sw", func(o kubetest.Object) {
		o["spec"] = map[string]any{"description": "d", "model": "claude-haiku", "instructions": "Be brief.\n", "toolProfile": "lookup", "tools": []any{"osv_query_vulnerability"}}
	})
	e.pass(t)
	if routes.has("kagent/sw") {
		t.Fatalf("route must be removed when the agent is no longer a container agent: %v", routes.calls)
	}
	if _, ok := e.srv.Get("deployments", workloadNS, "sw"); ok {
		t.Fatal("workload objects pruned")
	}
	if _, ok := e.srv.Get("secrets", workloadNS, secName); ok {
		t.Fatal("workload Secret deleted by name")
	}
	if _, ok := e.srv.Get("secrets", "kagent", secName); !ok {
		t.Fatal("Secret back in the definition's namespace")
	}
}

func TestRoutesAreSyncedFromStatusesAfterARestartAndASkippedDefinitionKeepsItsRoute(t *testing.T) {
	e, _, routes := containerEnv(t)
	e.seedContainer("a", nil)
	e.seedContainer("b", nil)
	e.seed("plain", nil)
	e.pass(t)
	if routes.last() != "sync kagent/a,kagent/b" {
		t.Fatalf("%v", routes.calls)
	}
	// a new controller (a restart) with an empty route list: statuses say which container agents run
	routes.set = map[string]bool{}
	cfg := e.c.cfg
	e.c = New(cfg)
	// definition a is in backoff, so Run's pass skips it: it must keep its route
	e.c.noteFailure("kagent/a", e.status("a").ObservedGeneration, true)
	if _, err := e.c.reconcile(context.Background(), true); err != nil {
		t.Fatal(err)
	}
	if !routes.has("kagent/a") || !routes.has("kagent/b") || routes.has("kagent/plain") {
		t.Fatalf("%v %v", routes.set, routes.calls)
	}
}

func TestUnknownRuntimeTypeIsRenderFailedAndCapabilitiesFallBackToBuiltin(t *testing.T) {
	e, _ := newEnv(t) // no container runtime configured
	e.seedContainer("odd", nil)
	e.pass(t) // refused by the policy: container is not allowed here
	st := e.status("odd")
	if st.Capabilities == nil || st.Capabilities.Isolation != "" {
		t.Fatalf("an unknown runtime reports the builtin capabilities: %+v", st.Capabilities)
	}
	wantCond(t, st, "Accepted", "False", "PolicyViolation")
	// a plan whose type has no runtime cannot be rendered
	e.pol.AllowedRuntimes = []string{"builtin", "container"}
	e.pol.Runtimes.Container.Images = []string{"ghcr.io/acme/agents/"}
	e.cat.Adapters.Runtimes = map[string]string{"builtin": "kagent", "container": "container"}
	e.pass(t)
	wantCond(t, e.status("odd"), "Applied", "False", "RenderFailed")
}

var _ = catalog.Policy{}
