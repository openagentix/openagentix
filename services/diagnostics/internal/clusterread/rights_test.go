package clusterread

import (
	"errors"
	"slices"
	"strings"
	"sync"
	"testing"

	authv1 "k8s.io/api/authorization/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes/fake"
	k8stesting "k8s.io/client-go/testing"
)

// grant is one right the fake API server allows.
type grant struct{ ns, group, resource, sub, verb string }

type authz struct {
	mu      sync.Mutex
	cfg     Config
	extra   []grant
	seen    []authv1.ResourceAttributes
	rules   map[string][]authv1.ResourceRule // namespace -> rules; nil entry means the intended role
	failAPI bool
}

// intended is the role of ADR 0025: get and list on pods, events and workloads
// in listed namespaces, pod logs in log namespaces, nodes at cluster scope.
func (a *authz) intended(r *authv1.ResourceAttributes) bool {
	listed := slices.Contains(a.cfg.LogNamespaces, r.Namespace) || slices.Contains(a.cfg.StatusNamespaces, r.Namespace)
	if r.Verb != "get" && r.Verb != "list" {
		return false
	}
	switch {
	case r.Resource == "pods" && r.Subresource == "log":
		return r.Verb == "get" && slices.Contains(a.cfg.LogNamespaces, r.Namespace)
	case r.Subresource != "":
		return false
	case r.Resource == "nodes":
		return r.Namespace == ""
	case slices.Contains([]string{"pods", "events", "deployments", "replicasets", "statefulsets", "daemonsets"}, r.Resource):
		return listed
	}
	return false
}

func (a *authz) allowed(r *authv1.ResourceAttributes) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.seen = append(a.seen, *r)
	for _, g := range a.extra {
		if g.ns == r.Namespace && g.resource == r.Resource && g.sub == r.Subresource && g.verb == r.Verb {
			return true
		}
	}
	return a.intended(r)
}

func (a *authz) grant(g grant) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.extra = append(a.extra, g)
}

func (a *authz) revoke() {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.extra = nil
}

func newAuthzClient(cfg Config) (*fake.Clientset, *authz) {
	a := &authz{cfg: cfg, rules: map[string][]authv1.ResourceRule{}}
	c := fake.NewSimpleClientset()
	c.PrependReactor("create", "selfsubjectaccessreviews", func(act k8stesting.Action) (bool, runtime.Object, error) {
		if a.failAPI {
			return true, nil, errors.New("api down")
		}
		in := act.(k8stesting.CreateAction).GetObject().(*authv1.SelfSubjectAccessReview).DeepCopy()
		in.Status.Allowed = a.allowed(in.Spec.ResourceAttributes)
		return true, in, nil
	})
	c.PrependReactor("create", "selfsubjectrulesreviews", func(act k8stesting.Action) (bool, runtime.Object, error) {
		in := act.(k8stesting.CreateAction).GetObject().(*authv1.SelfSubjectRulesReview).DeepCopy()
		ns := in.Spec.Namespace
		if r, ok := a.rules[ns]; ok {
			in.Status.ResourceRules = r
			return true, in, nil
		}
		in.Status.ResourceRules = []authv1.ResourceRule{{Verbs: []string{"get", "list"}, APIGroups: []string{""}, Resources: []string{"pods", "events"}}}
		return true, in, nil
	})
	return c, a
}

func TestCheckerNotReadyBeforeFirstRun(t *testing.T) {
	c, _ := newAuthzClient(testConfig())
	ck := NewChecker(c, testConfig())
	if ok, why := ck.Ready(); ok || why == "" {
		t.Fatalf("ready before any check: %v %q", ok, why)
	}
}

func TestRightsCheckPassesForTheIntendedRole(t *testing.T) {
	cfg := testConfig()
	c, a := newAuthzClient(cfg)
	ck := NewChecker(c, cfg)
	if err := ck.Run(ctx()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if ok, why := ck.Ready(); !ok {
		t.Fatalf("not ready: %s", why)
	}
	// the check asked about every scope and every forbidden right of the ADR
	scopes := map[string]bool{}
	asked := map[string]bool{}
	for _, r := range a.seen {
		scopes[r.Namespace] = true
		key := r.Resource
		if r.Subresource != "" {
			key += "/" + r.Subresource
		}
		asked[key+" "+r.Verb] = true
	}
	for _, ns := range []string{"rca-demo", "openagentix-knowledge", "kagent", "kube-system", "openagentix-diagnostics", ""} {
		if !scopes[ns] {
			t.Errorf("scope %q not checked", ns)
		}
	}
	for _, want := range []string{
		"secrets get", "configmaps list", "serviceaccounts create", "serviceaccounts/token create",
		"pods/exec create", "pods/exec get", "pods/attach create", "pods/portforward create", "pods/proxy get", "services/proxy get",
		"nodes/proxy get", "nodes/stats get", "pods/ephemeralcontainers patch",
		"users impersonate", "groups impersonate", "serviceaccounts impersonate", "clusterroles bind", "clusterroles escalate", "roles bind", "roles escalate",
		"pods watch", "events watch", "pods create", "pods delete", "pods deletecollection", "deployments patch", "deployments update", "nodes patch",
		"pods/log get", "* *",
	} {
		if !asked[want] {
			t.Errorf("right %q not checked", want)
		}
	}
}

func TestRightsCheckStopsOnAnyForbiddenRight(t *testing.T) {
	cases := []grant{
		{ns: "rca-demo", resource: "secrets", verb: "get"},
		{ns: "openagentix-knowledge", resource: "configmaps", verb: "list"},
		{ns: "kagent", resource: "secrets", verb: "watch"},
		{ns: "kube-system", resource: "secrets", verb: "get"},
		{ns: "", resource: "secrets", verb: "list"},
		{ns: "openagentix-diagnostics", resource: "secrets", verb: "get"},
		{ns: "rca-demo", resource: "serviceaccounts", sub: "token", verb: "create"},
		{ns: "rca-demo", resource: "pods", sub: "exec", verb: "create"},
		{ns: "rca-demo", resource: "pods", sub: "attach", verb: "create"},
		{ns: "kube-system", resource: "pods", sub: "portforward", verb: "create"},
		{ns: "", resource: "pods", sub: "proxy", verb: "get"},
		{ns: "rca-demo", resource: "services", sub: "proxy", verb: "get"},
		{ns: "", resource: "nodes", sub: "proxy", verb: "get"},
		{ns: "", resource: "nodes", sub: "stats", verb: "get"},
		{ns: "rca-demo", resource: "pods", sub: "ephemeralcontainers", verb: "patch"},
		{ns: "", resource: "users", verb: "impersonate"},
		{ns: "", resource: "clusterroles", verb: "bind"},
		{ns: "", resource: "clusterroles", verb: "escalate"},
		{ns: "rca-demo", resource: "pods", verb: "watch"},
		{ns: "rca-demo", resource: "pods", verb: "delete"},
		{ns: "kube-system", resource: "deployments", verb: "patch"},
		{ns: "", resource: "pods", verb: "create"},
		{ns: "", resource: "*", verb: "*"},
		// pod logs only in log namespaces
		{ns: "openagentix-knowledge", resource: "pods", sub: "log", verb: "get"},
		{ns: "kube-system", resource: "pods", sub: "log", verb: "get"},
		{ns: "", resource: "pods", sub: "log", verb: "get"},
	}
	for _, g := range cases {
		name := g.ns + "/" + g.resource + "/" + g.sub + " " + g.verb
		cfg := testConfig()
		c, a := newAuthzClient(cfg)
		ck := NewChecker(c, cfg)
		if err := ck.Run(ctx()); err != nil {
			t.Fatalf("%s: clean run failed: %v", name, err)
		}
		a.grant(g)
		err := ck.Run(ctx())
		if err == nil {
			t.Errorf("%s: a forbidden right passed the check", name)
			continue
		}
		ok, why := ck.Ready()
		if ok || !strings.Contains(why, g.resource) || !strings.Contains(why, g.verb) {
			t.Errorf("%s: ready %v, reason %q", name, ok, why)
		}
		// a later check that passes restores service
		a.revoke()
		if err := ck.Run(ctx()); err != nil {
			t.Errorf("%s: later check failed: %v", name, err)
		}
		if ok, why := ck.Ready(); !ok {
			t.Errorf("%s: still not ready: %s", name, why)
		}
	}
}

func TestRightsCheckNamespaceThatGrantsNothing(t *testing.T) {
	cfg := testConfig()
	c, a := newAuthzClient(cfg)
	a.rules["kagent"] = nil
	ck := NewChecker(c, cfg)
	err := ck.Run(ctx())
	if err == nil || !strings.Contains(err.Error(), "kagent") {
		t.Fatalf("err = %v", err)
	}
	if ok, why := ck.Ready(); ok || !strings.Contains(why, "grants nothing") {
		t.Fatalf("ready %v reason %q", ok, why)
	}
}

func TestRightsCheckFailsClosedWhenTheAPIFails(t *testing.T) {
	cfg := testConfig()
	c, a := newAuthzClient(cfg)
	ck := NewChecker(c, cfg)
	if err := ck.Run(ctx()); err != nil {
		t.Fatal(err)
	}
	a.failAPI = true
	if err := ck.Run(ctx()); err == nil {
		t.Fatal("an API failure passed the check")
	}
	if ok, _ := ck.Ready(); ok {
		t.Fatal("ready after the check could not run")
	}
}

func TestServerStopsServingWhenARightAppears(t *testing.T) {
	cfg := testConfig()
	c, a := newAuthzClient(cfg)
	ck := NewChecker(c, cfg)
	rg := newRig(t, func(o *Options) { o.Gate = ck }, pod("rca-demo", "p", "Running"))
	if _, err := rg.srv.PodsList(ctx(), PodsListArgs{Namespace: "rca-demo"}); err == nil || !strings.Contains(err.Error(), "not ready") {
		t.Fatalf("served before the first check: %v", err)
	}
	if err := ck.Run(ctx()); err != nil {
		t.Fatal(err)
	}
	if _, err := rg.srv.PodsList(ctx(), PodsListArgs{Namespace: "rca-demo"}); err != nil {
		t.Fatalf("not served after a passing check: %v", err)
	}
	a.grant(grant{ns: "kube-system", resource: "secrets", verb: "get"})
	_ = ck.Run(ctx())
	if _, err := rg.srv.PodsList(ctx(), PodsListArgs{Namespace: "rca-demo"}); err == nil {
		t.Fatal("served with a forbidden right in place")
	}
	a.revoke()
	_ = ck.Run(ctx())
	if _, err := rg.srv.PodsList(ctx(), PodsListArgs{Namespace: "rca-demo"}); err != nil {
		t.Fatalf("not served after recovery: %v", err)
	}
}
