package core

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/openagentix/openagentix/services/control-plane/internal/api"
	"github.com/openagentix/openagentix/services/control-plane/internal/catalog"
	"github.com/openagentix/openagentix/services/control-plane/internal/keys"
	"github.com/openagentix/openagentix/services/control-plane/internal/kube"
	"github.com/openagentix/openagentix/services/control-plane/internal/kubetest"
	"github.com/openagentix/openagentix/services/control-plane/internal/plan"
)

// ---- fakes of the two adapter interfaces: the core is tested without any real adapter ----

var (
	widgets = kube.Resource{Group: "example.dev", Version: "v1", Plural: "widgets", Kind: "Widget", Namespaced: true}
	gadgets = kube.Resource{Group: "example.dev", Version: "v1", Plural: "gadgets", Kind: "Gadget", Namespaced: true}
)

type fakeRuntime struct {
	ready     plan.Readiness
	readyErr  error
	inDesired atomic.Int32
	maxSeen   atomic.Int32
	delay     time.Duration
	// noEndpoint: the runtime offers no endpoint (the gate is off)
	noEndpoint bool
	// desiredPlans records the plans Desired was called with
	pmu   sync.Mutex
	plans []plan.Plan
}

func (f *fakeRuntime) Name() string                { return "fake" }
func (f *fakeRuntime) OwnedKinds() []kube.Resource { return []kube.Resource{widgets, gadgets} }
func (f *fakeRuntime) Ref(p plan.Plan) api.ObjectRef {
	return api.ObjectRef{APIVersion: "example.dev/v1", Kind: "Widget", Name: p.Name + "-w"}
}
func (f *fakeRuntime) KeyDataKey() string { return "KEY" }
func (f *fakeRuntime) Capabilities() api.Capabilities {
	return api.Capabilities{Approvals: api.Yes, DurableWaits: api.Unknown, WorkspacePersistence: "none", MaxStepSeconds: 60, CancelStopsLoop: api.No, PerRunIdentity: "none"}
}
func (f *fakeRuntime) Endpoint(p plan.Plan) *api.Endpoint {
	if f.noEndpoint {
		return nil
	}
	return &api.Endpoint{Protocol: "a2a", ProtocolVersion: "1.0", URL: "http://gate/agents/" + p.Namespace + "/" + p.Name}
}

func endpointURL(s api.Status) string {
	if s.Endpoint == nil {
		return ""
	}
	return s.Endpoint.URL
}
func (f *fakeRuntime) Readiness(context.Context, plan.Plan) (plan.Readiness, error) {
	return f.ready, f.readyErr
}
func (f *fakeRuntime) Desired(p plan.Plan) ([]kube.Manifest, error) {
	f.pmu.Lock()
	f.plans = append(f.plans, p)
	f.pmu.Unlock()
	n := f.inDesired.Add(1)
	for {
		m := f.maxSeen.Load()
		if n <= m || f.maxSeen.CompareAndSwap(m, n) {
			break
		}
	}
	time.Sleep(f.delay)
	f.inDesired.Add(-1)
	mk := func(kind, name string) kube.Object {
		return kube.Object{"apiVersion": "example.dev/v1", "kind": kind, "metadata": kube.Object{"name": name, "namespace": p.Namespace}, "spec": kube.Object{"model": p.Model, "prompt": p.Prompt, "key": p.KeySecret, "fp": p.KeyFingerprint, "gw": p.GatewayBaseURL}}
	}
	// like a real runtime adapter with no suspend field: a suspended plan has no "agent" object (the widget) but keeps the rest
	out := []kube.Manifest{{Resource: gadgets, Object: mk("Gadget", p.Name+"-g")}}
	if !p.Suspended {
		out = append([]kube.Manifest{{Resource: widgets, Object: mk("Widget", p.Name+"-w")}}, out...)
	}
	return out, nil
}

type fakeGateway struct {
	mu       sync.Mutex
	entries  map[string]string
	labels   map[string]map[string]string
	failReg  error
	regCalls int
}

func (g *fakeGateway) Name() string { return "fake" }
func (g *fakeGateway) Register(_ context.Context, user, hash string, labels map[string]string) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.regCalls++
	if g.failReg != nil {
		return g.failReg
	}
	g.entries[user] = hash
	if g.labels == nil {
		g.labels = map[string]map[string]string{}
	}
	g.labels[user] = labels
	return nil
}
func (g *fakeGateway) Unregister(_ context.Context, user string) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	delete(g.entries, user)
	return nil
}
func (g *fakeGateway) Registered(_ context.Context, user string) (bool, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	_, ok := g.entries[user]
	return ok, nil
}

func (g *fakeGateway) Entries(context.Context) (map[string]keys.Entry, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	out := map[string]keys.Entry{}
	for k, v := range g.entries {
		out[k] = keys.Entry{Hash: v, Labels: g.labels[k]}
	}
	return out, nil
}

type fakeTools struct{ c *catalog.Catalog }

func (f fakeTools) Profile(n string) (catalog.ToolProfile, bool) {
	p, ok := f.c.Tools.Toolhive.Profile(n)
	return catalog.ToolProfile{Name: p.Name, Backend: p.ToolServer, Tools: p.Tools, Workload: p.Workload}, ok
}
func (f fakeTools) Profiles() []string                                { return []string{"lookup"} }
func (f fakeTools) Missing(p catalog.ToolProfile, tool string) string { return "missing " + tool }

// ---- harness ----

type env struct {
	srv  *kubetest.Server
	c    *Controller
	rt   *fakeRuntime
	gw   *fakeGateway
	logs *bytes.Buffer
	cat  *catalog.Catalog
	pol  *catalog.Policy
	mint string
	ns   string
}

type syncBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuf) Write(p []byte) (int, error) { s.mu.Lock(); defer s.mu.Unlock(); return s.b.Write(p) }
func (s *syncBuf) String() string              { s.mu.Lock(); defer s.mu.Unlock(); return s.b.String() }

type logSink struct{ *syncBuf }

func newEnv(t *testing.T) (*env, *syncBuf) { return newEnvIn(t, "kagent") }

// newEnvIn builds an environment whose agents namespace (catalog and controller) is ns.
func newEnvIn(t *testing.T, ns string) (*env, *syncBuf) {
	t.Helper()
	cat, err := catalog.LoadCatalog("../../testdata/catalog.json")
	if err != nil {
		t.Fatal(err)
	}
	cat.Namespaces.Agents = ns
	pol, err := catalog.LoadPolicy("../../testdata/policy.json")
	if err != nil {
		t.Fatal(err)
	}
	srv := kubetest.New()
	t.Cleanup(srv.Close)
	cl := kube.New(srv.URL, srv.Client(), func() (string, error) { return "t", nil })
	buf := &syncBuf{}
	e := &env{srv: srv, rt: &fakeRuntime{ready: plan.Readiness{Ready: true, Reason: "Ready"}}, gw: &fakeGateway{entries: map[string]string{}}, cat: cat, pol: pol, mint: "vk-0123456789abcdef0123456789abcdef", ns: ns}
	e.c = New(Config{
		Namespace: ns, Catalog: cat, Policy: pol, Kube: cl, Secrets: &keys.KubeSecrets{C: cl},
		Runtime: e.rt, Gateway: e.gw, Tools: fakeTools{cat},
		Log:    slog.New(slog.NewJSONHandler(buf, &slog.HandlerOptions{Level: slog.LevelDebug})),
		Now:    func() time.Time { return time.Date(2026, 11, 25, 12, 0, 0, 0, time.UTC) },
		Mint:   func() (string, error) { return e.mint, nil },
		Resync: 50 * time.Millisecond, Backoff: 10 * time.Millisecond, MinInterval: 5 * time.Millisecond,
	})
	return e, buf
}

func defObj(name string, mut func(spec map[string]any)) kubetest.Object {
	return defObjIn("kagent", name, mut)
}

func defObjIn(ns, name string, mut func(spec map[string]any)) kubetest.Object {
	spec := map[string]any{
		"description": "d", "model": "claude-haiku", "instructions": "Be brief.\n",
		"toolProfile": "lookup", "tools": []any{"osv_query_vulnerability"},
	}
	if mut != nil {
		mut(spec)
	}
	return kubetest.Object{"apiVersion": "openagentix.io/v1alpha1", "kind": "AgentDefinition",
		"metadata": kubetest.Object{"name": name, "namespace": ns, "creationTimestamp": "2026-11-25T10:00:00Z"}, "spec": spec}
}

func (e *env) seed(name string, mut func(map[string]any)) {
	e.srv.Seed("agentdefinitions", defObjIn(e.ns, name, mut))
}

func (e *env) status(name string) api.Status {
	o, ok := e.srv.Get("agentdefinitions", e.ns, name)
	if !ok {
		e.c.cfg.Log.Error("missing")
		panic("definition " + name + " not found")
	}
	d, err := api.FromObject(o)
	if err != nil {
		panic(err)
	}
	return d.Status
}

func (e *env) pass(t *testing.T) {
	t.Helper()
	if err := e.c.ReconcileAll(context.Background()); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	e.checkReasons(t)
}

// checkReasons fails when any stored condition carries a reason that is not in the documented table (api.reasons).
func (e *env) checkReasons(t *testing.T) {
	t.Helper()
	for _, o := range e.srv.List("agentdefinitions", e.ns) {
		d, err := api.FromObject(o)
		if err != nil {
			continue
		}
		for _, c := range d.Status.Conditions {
			if !api.ValidReason(c.Type, c.Reason) {
				t.Errorf("%s: condition %s has reason %q, which is not in the documented table", d.Metadata.Name, c.Type, c.Reason)
			}
		}
	}
}

func cond(s api.Status, typ string) api.Condition { return s.Condition(typ) }

func wantCond(t *testing.T, s api.Status, typ, status, reason string) {
	t.Helper()
	c := s.Condition(typ)
	if c.Status != status || c.Reason != reason {
		t.Fatalf("%s: want %s/%s, got %s/%s (%s); all: %+v", typ, status, reason, c.Status, c.Reason, c.Message, s.Conditions)
	}
}

// ---- tests ----

func TestReconcileBuildsEverythingAndReportsReady(t *testing.T) {
	e, _ := newEnv(t)
	e.seed("researcher", nil)
	e.pass(t)

	raw, _ := e.srv.Get("agentdefinitions", "kagent", "researcher")
	if fin, _ := kube.Meta(raw)["finalizers"].([]any); len(fin) != 1 || fin[0] != api.FinalizerGatewayKey {
		t.Fatalf("finalizer: %v", fin)
	}
	st := e.status("researcher")
	for _, c := range api.ConditionTypes {
		wantCond(t, st, c, "True", map[string]string{"Accepted": "Accepted", "KeyReady": "KeyReady", "Applied": "Applied", "Ready": "Ready"}[c])
	}
	if st.ObservedGeneration != 1 || st.Controller.GatewayUserID != "kagent.researcher" || st.Controller.ToolServer != "toolhive-vmcp-lookup" ||
		endpointURL(st) != "http://gate/agents/kagent/researcher" || st.AgentRef == nil || st.AgentRef.Name != "researcher-w" ||
		len(st.EffectiveTools) != 1 || len(st.Violations) != 0 {
		t.Fatalf("status: %+v", st)
	}
	if got := cond(st, "Accepted").LastTransitionTime; got != "2026-11-25T12:00:00Z" {
		t.Fatalf("transition time %q", got)
	}

	// the key: one Secret, immutable, owned, and its hash registered
	sec, ok := e.srv.Get("secrets", "kagent", "researcher-virtual-key-"+uid8(e.raw("researcher")))
	if !ok || sec["immutable"] != true {
		t.Fatalf("secret: %v", sec)
	}
	if e.gw.entries["kagent.researcher"] != keys.Hash(e.mint) {
		t.Fatalf("registered %v", e.gw.entries)
	}

	// the two objects were sent with server-side apply, labelled and owned
	for _, n := range []string{"widgets/researcher-w", "gadgets/researcher-g"} {
		reqs := e.srv.Matching("PATCH", "/"+n)
		if len(reqs) != 1 || reqs[0].ContentType != "application/apply-patch+yaml" ||
			!strings.Contains(reqs[0].Query, "fieldManager=openagentix-control-plane") || !strings.Contains(reqs[0].Query, "force=true") {
			t.Fatalf("%s: %+v", n, reqs)
		}
		var body map[string]any
		_ = json.Unmarshal(reqs[0].Body, &body)
		m := body["metadata"].(map[string]any)
		l := m["labels"].(map[string]any)
		if l["app.kubernetes.io/managed-by"] != "openagentix-control-plane" || l["openagentix.io/agent-definition"] != "researcher" {
			t.Fatalf("%s labels: %v", n, l)
		}
		or := m["ownerReferences"].([]any)[0].(map[string]any)
		if or["apiVersion"] != "openagentix.io/v1alpha1" || or["kind"] != "AgentDefinition" || or["name"] != "researcher" || or["uid"] == "" || or["controller"] != true {
			t.Fatalf("%s owner: %v", n, or)
		}
	}
}

func TestSecondPassChangesNothingInStatusAndKeepsTheKey(t *testing.T) {
	e, _ := newEnv(t)
	e.seed("researcher", nil)
	e.pass(t)
	patches := len(e.srv.Matching("PATCH", "/agentdefinitions/researcher/status"))
	e.mint = "vk-ffffffffffffffffffffffffffffffff" // a second mint would be visible
	e.pass(t)
	if got := len(e.srv.Matching("PATCH", "/agentdefinitions/researcher/status")); got != patches {
		t.Fatalf("status patched again: %d -> %d", patches, got)
	}
	if len(e.srv.Matching("DELETE", "secrets")) != 0 {
		t.Fatal("a Secret was deleted in a steady state")
	}
	if e.gw.entries["kagent.researcher"] != keys.Hash("vk-0123456789abcdef0123456789abcdef") {
		t.Fatal("the registered hash changed")
	}
}

func TestNeverGetsOrListsSecrets(t *testing.T) {
	e, _ := newEnv(t)
	e.seed("researcher", nil)
	e.pass(t)
	e.pass(t)
	for _, r := range e.srv.Requests() {
		if strings.Contains(r.Path, "/secrets") && r.Method != "POST" && r.Method != "DELETE" {
			t.Fatalf("forbidden call on secrets: %s %s", r.Method, r.Path)
		}
	}
}

func TestRefusedDefinitionWritesNothingButStatus(t *testing.T) {
	e, _ := newEnv(t)
	e.seed("bad", func(s map[string]any) { s["model"] = "gpt-9"; s["tools"] = []any{"fetch_fetch"} })
	e.pass(t)
	st := e.status("bad")
	wantCond(t, st, "Accepted", "False", "PolicyViolation")
	wantCond(t, st, "Ready", "False", "NotAccepted")
	if len(st.Violations) != 2 {
		t.Fatalf("violations %q", st.Violations)
	}
	for _, r := range e.srv.Requests() {
		if r.Method == "POST" || (r.Method == "PATCH" && strings.Contains(r.Path, "example.dev")) {
			t.Fatalf("a refused definition caused a write: %s %s", r.Method, r.Path)
		}
	}
	if len(e.gw.entries) != 0 {
		t.Fatal("hash registered for a refused definition")
	}
}

func TestEditingARefusedDefinitionIntoAValidOneRecovers(t *testing.T) {
	e, _ := newEnv(t)
	e.seed("fix", func(s map[string]any) { s["model"] = "gpt-9" })
	e.pass(t)
	e.srv.Modify("agentdefinitions", "kagent", "fix", func(o kubetest.Object) { o["spec"].(map[string]any)["model"] = "claude-haiku" })
	e.pass(t)
	st := e.status("fix")
	wantCond(t, st, "Accepted", "True", "Accepted")
	wantCond(t, st, "Ready", "True", "Ready")
	if len(st.Violations) != 0 {
		t.Fatalf("violations must be cleared: %q", st.Violations)
	}
}

func TestNameConflictWritesNothing(t *testing.T) {
	for name, labels := range map[string]kubetest.Object{
		"foreign object":                    nil,
		"owned by another definition":       {"app.kubernetes.io/managed-by": "openagentix-control-plane", "openagentix.io/agent-definition": "other"},
		"our label but no definition label": {"app.kubernetes.io/managed-by": "openagentix-control-plane"},
		"both labels, no owner reference":   {"app.kubernetes.io/managed-by": "openagentix-control-plane", "openagentix.io/agent-definition": "researcher"},
	} {
		t.Run(name, func(t *testing.T) {
			e, _ := newEnv(t)
			m := kubetest.Object{"name": "researcher-g", "namespace": "kagent"}
			if labels != nil {
				m["labels"] = labels
			}
			e.srv.Seed("gadgets", kubetest.Object{"apiVersion": "example.dev/v1", "kind": "Gadget", "metadata": m, "spec": kubetest.Object{"mine": false}})
			e.seed("researcher", nil)
			e.pass(t)
			st := e.status("researcher")
			wantCond(t, st, "Applied", "False", "NameConflict")
			wantCond(t, st, "Ready", "False", "NotApplied")
			if !strings.Contains(cond(st, "Applied").Message, "Gadget researcher-g") {
				t.Fatalf("message: %q", cond(st, "Applied").Message)
			}
			for _, r := range e.srv.Requests() {
				if r.Method == "POST" || r.Method == "DELETE" || (r.Method == "PATCH" && strings.Contains(r.Path, "example.dev")) {
					t.Fatalf("name conflict, yet a write: %s %s", r.Method, r.Path)
				}
			}
			g, _ := e.srv.Get("gadgets", "kagent", "researcher-g")
			if g["spec"].(map[string]any)["mine"] != false {
				t.Fatal("the foreign object was changed")
			}
			if len(e.gw.entries) != 0 {
				t.Fatal("no key for a definition that cannot be applied")
			}
		})
	}
}

func TestPrunesOwnedObjectsNoLongerDesiredAndOnlyThose(t *testing.T) {
	e, _ := newEnv(t)
	def := e.srv.Seed("agentdefinitions", defObj("researcher", nil))
	uid := kube.Meta(def).String("uid")
	owned := kubetest.Object{"app.kubernetes.io/managed-by": "openagentix-control-plane", "openagentix.io/agent-definition": "researcher"}
	ownerRef := func(u string) []any {
		return []any{kubetest.Object{"apiVersion": "openagentix.io/v1alpha1", "kind": "AgentDefinition", "name": "researcher", "uid": u, "controller": true}}
	}
	seed := func(plural, kind, name string, labels kubetest.Object, refs []any) {
		m := kubetest.Object{"name": name, "namespace": "kagent"}
		if labels != nil {
			m["labels"] = labels
		}
		if refs != nil {
			m["ownerReferences"] = refs
		}
		e.srv.Seed(plural, kubetest.Object{"apiVersion": "example.dev/v1", "kind": kind, "metadata": m})
	}
	seed("gadgets", "Gadget", "researcher-old", owned, ownerRef(uid))
	seed("widgets", "Widget", "researcher-oldw", owned, ownerRef(uid))
	seed("gadgets", "Gadget", "stranger", nil, nil)
	seed("gadgets", "Gadget", "labels-only", owned, nil)                                            // our labels, no owner reference
	seed("gadgets", "Gadget", "other-uid", owned, ownerRef("00000000-1111-4222-8333-444444444444")) // owned by an earlier incarnation
	seed("gadgets", "Gadget", "other-g", kubetest.Object{"app.kubernetes.io/managed-by": "openagentix-control-plane", "openagentix.io/agent-definition": "other"}, nil)
	e.pass(t)
	for _, gone := range [][2]string{{"gadgets", "researcher-old"}, {"widgets", "researcher-oldw"}} {
		if _, ok := e.srv.Get(gone[0], "kagent", gone[1]); ok {
			t.Fatalf("%s/%s should be pruned", gone[0], gone[1])
		}
	}
	for _, kept := range [][2]string{{"gadgets", "researcher-g"}, {"widgets", "researcher-w"}, {"gadgets", "stranger"}, {"gadgets", "other-g"}, {"gadgets", "labels-only"}, {"gadgets", "other-uid"}} {
		if _, ok := e.srv.Get(kept[0], "kagent", kept[1]); !ok {
			t.Fatalf("%s/%s must stay (labels alone are not ownership)", kept[0], kept[1])
		}
	}
}

func TestDeleteUnregistersKeyRemovesOwnedObjectsAndFinalizer(t *testing.T) {
	e, _ := newEnv(t)
	e.seed("researcher", nil)
	e.pass(t)
	if _, ok := e.gw.entries["kagent.researcher"]; !ok {
		t.Fatal("setup: hash missing")
	}
	// the user deletes the definition: the API server sets deletionTimestamp because of the finalizer
	cl := kube.New(e.srv.URL, e.srv.Client(), func() (string, error) { return "t", nil })
	if err := cl.Delete(context.Background(), definitions, "kagent", "researcher"); err != nil {
		t.Fatal(err)
	}
	e.pass(t)
	if _, ok := e.gw.entries["kagent.researcher"]; ok {
		t.Fatal("hash must be unregistered")
	}
	for _, n := range [][2]string{{"widgets", "researcher-w"}, {"gadgets", "researcher-g"}} {
		if _, ok := e.srv.Get(n[0], "kagent", n[1]); ok {
			t.Fatalf("%s/%s must be deleted", n[0], n[1])
		}
	}
	if _, ok := e.srv.Get("agentdefinitions", "kagent", "researcher"); ok {
		t.Fatal("finalizer must be removed so the definition goes away")
	}
}

func TestDeleteKeepsTheFinalizerWhileUnregisterFails(t *testing.T) {
	e, _ := newEnv(t)
	e.seed("researcher", nil)
	e.pass(t)
	failing := &failingGateway{fakeGateway: e.gw}
	e.c.cfg.Gateway = failing
	cl := kube.New(e.srv.URL, e.srv.Client(), func() (string, error) { return "t", nil })
	_ = cl.Delete(context.Background(), definitions, "kagent", "researcher")
	if err := e.c.ReconcileAll(context.Background()); err == nil {
		t.Fatal("want the failure reported")
	}
	if _, ok := e.srv.Get("agentdefinitions", "kagent", "researcher"); !ok {
		t.Fatal("definition must stay until the hash is gone")
	}
	e.pass(t)
	if _, ok := e.srv.Get("agentdefinitions", "kagent", "researcher"); ok {
		t.Fatal("now it may go")
	}
}

type failingGateway struct {
	*fakeGateway
	fail bool
}

func (f *failingGateway) Unregister(ctx context.Context, user string) error {
	if !f.fail {
		f.fail = true // first call fails
		return errors.New("gateway unavailable")
	}
	return f.fakeGateway.Unregister(ctx, user)
}

func TestNotReadyRuntimeIsReportedNotHidden(t *testing.T) {
	e, _ := newEnv(t)
	e.rt.ready = plan.Readiness{Reason: "RuntimeNotReady", Message: "waiting for the sandbox"}
	e.seed("researcher", nil)
	e.pass(t)
	st := e.status("researcher")
	wantCond(t, st, "Applied", "True", "Applied")
	wantCond(t, st, "Ready", "False", "RuntimeNotReady")
	if cond(st, "Ready").Message != "waiting for the sandbox" {
		t.Fatalf("%+v", cond(st, "Ready"))
	}
}

func TestKeyFailureIsAConditionAndNothingIsApplied(t *testing.T) {
	e, _ := newEnv(t)
	e.gw.failReg = errors.New("boom")
	e.seed("researcher", nil)
	e.pass(t)
	st := e.status("researcher")
	wantCond(t, st, "Accepted", "True", "Accepted")
	wantCond(t, st, "KeyReady", "False", "KeyFailed")
	wantCond(t, st, "Applied", "False", "NotApplied")
	if len(e.srv.Matching("PATCH", "example.dev")) != 0 {
		t.Fatal("objects applied although the key is not ready")
	}
	// recovery
	e.gw.failReg = nil
	e.pass(t)
	wantCond(t, e.status("researcher"), "Ready", "True", "Ready")
}

func TestMaxAgentsRefusesTheNewest(t *testing.T) {
	e, _ := newEnv(t)
	e.pol.MaxAgents = 1
	old := defObj("old", nil)
	old["metadata"].(map[string]any)["creationTimestamp"] = "2026-11-25T09:00:00Z"
	e.srv.Seed("agentdefinitions", old)
	nw := defObj("new", nil)
	nw["metadata"].(map[string]any)["creationTimestamp"] = "2026-11-25T11:00:00Z"
	e.srv.Seed("agentdefinitions", nw)
	e.pass(t)
	wantCond(t, e.status("old"), "Ready", "True", "Ready")
	st := e.status("new")
	wantCond(t, st, "Accepted", "False", "PolicyViolation")
	if len(st.Violations) != 1 || !strings.Contains(st.Violations[0], "at most 1 agents") {
		t.Fatalf("%q", st.Violations)
	}
}

func TestDefinitionsInOtherNamespacesAreIgnored(t *testing.T) {
	e, _ := newEnv(t)
	o := defObj("elsewhere", nil)
	o["metadata"].(map[string]any)["namespace"] = "other"
	e.srv.Seed("agentdefinitions", o)
	e.pass(t)
	if len(e.srv.Matching("PATCH", "/namespaces/other/")) != 0 {
		t.Fatal("touched another namespace")
	}
}

func TestReconcilesAreSerialized(t *testing.T) {
	e, _ := newEnv(t)
	e.rt.delay = 20 * time.Millisecond
	e.seed("a", nil)
	e.seed("b", nil)
	var wg sync.WaitGroup
	for range 3 {
		wg.Add(1)
		go func() { defer wg.Done(); _ = e.c.ReconcileAll(context.Background()) }()
	}
	wg.Wait()
	if m := e.rt.maxSeen.Load(); m != 1 {
		t.Fatalf("reconciles overlapped: %d at once", m)
	}
}

// ---- the loop: list, watch, 410 ----

func TestRunReconcilesNewDefinitionsAndRelistsOnGone(t *testing.T) {
	for _, mode := range []string{"http", "event"} {
		t.Run(mode, func(t *testing.T) {
			e, _ := newEnv(t)
			e.c.cfg.Resync = time.Hour // only watch events and re-lists may drive the loop
			ctx, cancel := context.WithCancel(context.Background())
			done := make(chan error, 1)
			go func() { done <- e.c.Run(ctx) }()
			defer func() { cancel(); <-done }()

			e.seed("first", nil)
			waitFor(t, "first definition ready", func() bool {
				o, ok := e.srv.Get("agentdefinitions", "kagent", "first")
				if !ok {
					return false
				}
				d, _ := api.FromObject(o)
				return d.Status.Condition("Ready").Status == "True"
			})
			if !e.c.Ready() {
				t.Fatal("the controller must report ready after its first pass")
			}
			lists := len(e.srv.Matching("GET", "/agentdefinitions"))
			e.srv.GoneNextWatch("agentdefinitions", "kagent", mode)
			// the next watch (opened after the next event ends the current one) answers 410; a new definition must still be found
			e.seed("second", nil)
			waitFor(t, "second definition ready", func() bool {
				o, ok := e.srv.Get("agentdefinitions", "kagent", "second")
				if !ok {
					return false
				}
				d, _ := api.FromObject(o)
				return d.Status.Condition("Ready").Status == "True"
			})
			e.seed("third", nil)
			waitFor(t, "third definition ready", func() bool {
				o, ok := e.srv.Get("agentdefinitions", "kagent", "third")
				if !ok {
					return false
				}
				d, _ := api.FromObject(o)
				return d.Status.Condition("Ready").Status == "True"
			})
			if got := len(e.srv.Matching("GET", "/agentdefinitions")); got <= lists {
				t.Fatalf("no re-list happened (%d requests before and after)", got)
			}
		})
	}
}

func TestStatusAndFinalizerWritesDoNotRetriggerTheLoop(t *testing.T) {
	e, _ := newEnv(t)
	e.c.cfg.Resync = time.Hour
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- e.c.Run(ctx) }()
	defer func() { cancel(); <-done }()
	e.seed("one", nil)
	waitFor(t, "ready", func() bool { return e.status("one").Condition("Ready").Status == "True" })
	time.Sleep(150 * time.Millisecond)
	n := len(e.srv.Matching("PATCH", "/widgets/one-w"))
	time.Sleep(150 * time.Millisecond)
	if m := len(e.srv.Matching("PATCH", "/widgets/one-w")); m != n || n != 1 {
		t.Fatalf("the controller keeps reconciling its own writes: %d then %d applies", n, m)
	}
}

func waitFor(t *testing.T, what string, f func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if f() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// ---- the canary: a planted key value must appear nowhere it should not ----

func TestCanaryKeyAppearsOnlyInTheOneSecretCreate(t *testing.T) {
	const canary = "vk-CANARY1234567890canary1234567890"
	b64 := base64.StdEncoding.EncodeToString([]byte(canary))
	for name, setup := range map[string]func(e *env){
		"happy path": func(e *env) {},
		"gateway fails": func(e *env) {
			e.gw.failReg = errors.New("registry said no: " + "x") // an error that does not carry the key
		},
		"definition refused": func(e *env) {},
	} {
		t.Run(name, func(t *testing.T) {
			e, logs := newEnv(t)
			e.mint = canary
			setup(e)
			if name == "definition refused" {
				e.seed("c", func(s map[string]any) { s["model"] = "gpt-9" })
			} else {
				e.seed("c", nil)
			}
			var errText []string
			for range 4 { // several passes: a key that is minted and sent once must stay out of every later one
				if err := e.c.ReconcileAll(context.Background()); err != nil {
					errText = append(errText, err.Error())
				}
			}
			leak := func(where, s string) {
				if strings.Contains(s, canary) || strings.Contains(s, b64) {
					t.Fatalf("the key value is in %s", where)
				}
			}
			leak("the log", logs.String())
			for _, s := range errText {
				leak("an error string", s)
			}
			st, _ := json.Marshal(e.status("c"))
			leak("status", string(st))
			o, _ := e.srv.Get("agentdefinitions", "kagent", "c")
			raw, _ := json.Marshal(o)
			leak("the definition object (status, events, annotations)", string(raw))
			creates := 0
			for _, r := range e.srv.Requests() {
				if r.Method == "POST" && strings.HasSuffix(r.Path, "/secrets") {
					creates++
					continue
				}
				leak(fmt.Sprintf("the body of %s %s", r.Method, r.Path), string(r.Body))
				leak("the URL of "+r.Path, r.Query)
			}
			if name == "happy path" && creates != 1 {
				t.Fatalf("want exactly one Secret create, got %d", creates)
			}
			// the fake gateway holds only the hash
			for _, h := range e.gw.entries {
				leak("the registered entry", h)
			}
		})
	}
}

func TestLogsNameAgentAndOutcome(t *testing.T) {
	e, logs := newEnv(t)
	e.seed("researcher", nil)
	e.pass(t)
	var found bool
	for _, line := range strings.Split(strings.TrimSpace(logs.String()), "\n") {
		var m map[string]any
		if json.Unmarshal([]byte(line), &m) != nil {
			t.Fatalf("log line is not JSON: %q", line)
		}
		if m["agent"] == "researcher" && m["outcome"] != nil {
			found = true
		}
	}
	if !found {
		t.Fatalf("no log line with agent and outcome:\n%s", logs.String())
	}
}

func TestErrorBodiesOfTheAPIAreNotLogged(t *testing.T) {
	e, logs := newEnv(t)
	e.srv.Intercept = func(r kubetest.Request) (int, any, bool) {
		if r.Method == "PATCH" && strings.Contains(r.Path, "/widgets/") {
			return 500, map[string]any{"kind": "Status", "reason": "InternalError", "message": "SECRET-DETAIL-FROM-API"}, true
		}
		return 0, nil, false
	}
	e.seed("researcher", nil)
	_ = e.c.ReconcileAll(context.Background())
	if strings.Contains(logs.String(), "SECRET-DETAIL-FROM-API") {
		t.Fatal("an API error message reached the log")
	}
	st := e.status("researcher")
	wantCond(t, st, "Applied", "False", "ApplyFailed")
	if strings.Contains(cond(st, "Applied").Message, "SECRET-DETAIL") || !strings.Contains(cond(st, "Applied").Message, "500") {
		t.Fatalf("message %q", cond(st, "Applied").Message)
	}
}

func readiness(ready bool, reason, msg string) plan.Readiness {
	return plan.Readiness{Ready: ready, Reason: reason, Message: msg}
}

func sha(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

// The admission guard lets a key Secret carry exactly two labels (managed-by and agent-definition). A definition's own labels (team, project:
// informational, for cost and traces) go on the kagent objects and into the gateway entry, never on the Secret, or the API server refuses it (422).
func TestKeySecretCarriesOnlyTheTwoGuardedLabels(t *testing.T) {
	e, _ := newEnv(t)
	o := defObjIn(e.ns, "researcher", nil)
	o["metadata"].(kubetest.Object)["labels"] = map[string]any{"openagentix.io/team": "platform", "openagentix.io/project": "demo"}
	e.srv.Seed("agentdefinitions", o)
	e.pass(t)
	sec, ok := e.srv.Get("secrets", "kagent", "researcher-virtual-key-"+uid8(e.raw("researcher")))
	if !ok {
		t.Fatalf("no key secret")
	}
	l, _ := kube.Meta(sec)["labels"].(map[string]any)
	if len(l) != 2 || l["app.kubernetes.io/managed-by"] != "openagentix-control-plane" || l["openagentix.io/agent-definition"] != "researcher" {
		t.Fatalf("secret labels must be exactly managed-by and agent-definition: %v", l)
	}
}
