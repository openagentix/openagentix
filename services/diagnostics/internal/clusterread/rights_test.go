package clusterread

import (
	"bytes"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"strings"
	"sync"
	"testing"

	authv1 "k8s.io/api/authorization/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes/fake"
	k8stesting "k8s.io/client-go/testing"
)

// grant is one right the fake API server allows: in a namespace, or cluster wide when ns is empty.
type grant struct {
	ns, group, resource, sub, verb string
	names                          []string
	url                            string // a non-resource URL
}

type authz struct {
	mu         sync.Mutex
	cfg        Config
	extra      []grant
	seen       []authv1.ResourceAttributes
	seenURLs   []string
	rulesNS    []string
	failAPI    bool
	empty      map[string]bool // namespaces whose rules review is empty
	incomplete map[string]bool // namespaces whose rules review says incomplete and shows nothing
}

func (a *authz) logNS(ns string) bool { return slices.Contains(a.cfg.LogNamespaces, ns) }
func (a *authz) listed(ns string) bool {
	return a.logNS(ns) || slices.Contains(a.cfg.StatusNamespaces, ns)
}

// intendedRules is what the three ClusterRoles of ADR 0025 give in a namespace, plus the
// rules every authenticated user gets from the API server's default roles.
func (a *authz) intendedRules(ns string) ([]authv1.ResourceRule, []authv1.NonResourceRule) {
	var rules []authv1.ResourceRule
	if a.listed(ns) {
		rules = append(rules,
			authv1.ResourceRule{Verbs: []string{"get", "list"}, APIGroups: []string{""}, Resources: []string{"pods", "events"}},
			authv1.ResourceRule{Verbs: []string{"get", "list"}, APIGroups: []string{"events.k8s.io"}, Resources: []string{"events"}},
			authv1.ResourceRule{Verbs: []string{"get", "list"}, APIGroups: []string{"apps"}, Resources: []string{"deployments", "replicasets", "statefulsets", "daemonsets"}})
		if a.logNS(ns) {
			rules = append(rules, authv1.ResourceRule{Verbs: []string{"get"}, APIGroups: []string{""}, Resources: []string{"pods/log"}})
		}
	}
	rules = append(rules,
		authv1.ResourceRule{Verbs: []string{"get", "list"}, APIGroups: []string{""}, Resources: []string{"nodes"}},
		authv1.ResourceRule{Verbs: []string{"create"}, APIGroups: []string{"authorization.k8s.io"}, Resources: []string{"selfsubjectaccessreviews", "selfsubjectrulesreviews"}},
		authv1.ResourceRule{Verbs: []string{"create"}, APIGroups: []string{"authentication.k8s.io"}, Resources: []string{"selfsubjectreviews"}})
	nonRes := []authv1.NonResourceRule{
		{Verbs: []string{"get"}, NonResourceURLs: []string{"/healthz", "/livez", "/readyz", "/healthz/*", "/livez/*", "/readyz/*", "/version", "/version/", "/api", "/api/*", "/apis", "/apis/*", "/openapi", "/openapi/*", "/.well-known/openid-configuration", "/openid/v1/jwks", "/.well-known/openid-configuration/", "/openid/v1/jwks/"}},
	}
	return rules, nonRes
}

func (a *authz) rulesFor(ns string) ([]authv1.ResourceRule, []authv1.NonResourceRule) {
	a.mu.Lock()
	defer a.mu.Unlock()
	rules, nonRes := a.intendedRules(ns)
	for _, g := range a.extra {
		if g.ns != "" && g.ns != ns {
			continue
		}
		if g.url != "" {
			nonRes = append(nonRes, authv1.NonResourceRule{Verbs: []string{g.verb}, NonResourceURLs: []string{g.url}})
			continue
		}
		res := g.resource
		if g.sub != "" {
			res += "/" + g.sub
		}
		rules = append(rules, authv1.ResourceRule{Verbs: []string{g.verb}, APIGroups: []string{g.group}, Resources: []string{res}, ResourceNames: g.names})
	}
	return rules, nonRes
}

// allowed answers a SelfSubjectAccessReview. Like the real API server, a request without a name is not
// matched by a rule that names objects.
func (a *authz) allowed(r *authv1.ResourceAttributes) bool {
	a.mu.Lock()
	a.seen = append(a.seen, *r)
	a.mu.Unlock()
	rules, _ := a.rulesFor(r.Namespace)
	res := r.Resource
	if r.Subresource != "" {
		res += "/" + r.Subresource
	}
	for _, rule := range rules {
		if len(rule.ResourceNames) > 0 {
			continue
		}
		if (slices.Contains(rule.Verbs, r.Verb) || slices.Contains(rule.Verbs, "*")) && (slices.Contains(rule.Resources, res) || slices.Contains(rule.Resources, "*")) {
			if r.Namespace == "" && !a.clusterWide(rule) {
				continue
			}
			return true
		}
	}
	return false
}

// clusterWide says whether a rule came from a cluster-wide grant (or from the cluster-scoped defaults).
func (a *authz) clusterWide(rule authv1.ResourceRule) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, g := range a.extra {
		res := g.resource
		if g.sub != "" {
			res += "/" + g.sub
		}
		if g.ns == "" && slices.Contains(rule.Resources, res) && slices.Contains(rule.Verbs, g.verb) {
			return true
		}
	}
	return slices.Contains(rule.Resources, "nodes")
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
	a := &authz{cfg: cfg, empty: map[string]bool{}, incomplete: map[string]bool{}}
	c := fake.NewSimpleClientset()
	c.PrependReactor("create", "selfsubjectaccessreviews", func(act k8stesting.Action) (bool, runtime.Object, error) {
		if a.failAPI {
			return true, nil, errors.New("api down")
		}
		in := act.(k8stesting.CreateAction).GetObject().(*authv1.SelfSubjectAccessReview).DeepCopy()
		if nr := in.Spec.NonResourceAttributes; nr != nil {
			a.mu.Lock()
			a.seenURLs = append(a.seenURLs, nr.Verb+" "+nr.Path)
			a.mu.Unlock()
			_, nrr := a.rulesFor("")
			for _, r := range nrr {
				for _, u := range r.NonResourceURLs {
					if (u == nr.Path || u == "*") && slices.Contains(r.Verbs, nr.Verb) {
						in.Status.Allowed = true
					}
				}
			}
			return true, in, nil
		}
		in.Status.Allowed = a.allowed(in.Spec.ResourceAttributes)
		return true, in, nil
	})
	c.PrependReactor("create", "selfsubjectrulesreviews", func(act k8stesting.Action) (bool, runtime.Object, error) {
		if a.failAPI {
			return true, nil, errors.New("api down")
		}
		in := act.(k8stesting.CreateAction).GetObject().(*authv1.SelfSubjectRulesReview).DeepCopy()
		ns := in.Spec.Namespace
		a.mu.Lock()
		a.rulesNS = append(a.rulesNS, ns)
		empty, inc := a.empty[ns], a.incomplete[ns]
		a.mu.Unlock()
		switch {
		case inc:
			// like a cluster with a webhook authorizer: the RBAC rules are there, and the list is incomplete
			in.Status.ResourceRules, in.Status.NonResourceRules = a.rulesFor(ns)
			in.Status.Incomplete = true
		case empty:
		default:
			in.Status.ResourceRules, in.Status.NonResourceRules = a.rulesFor(ns)
		}
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
		t.Fatalf("the intended role with the default rules must pass: %v", err)
	}
	if ok, why := ck.Ready(); !ok {
		t.Fatalf("not ready: %s", why)
	}
	for _, ns := range []string{"rca-demo", "openagentix-knowledge", "kagent", "kube-system", "openagentix-diagnostics"} {
		if !slices.Contains(a.rulesNS, ns) {
			t.Errorf("rules of %q not reviewed", ns)
		}
	}
	asked := map[string]bool{}
	for _, r := range a.seen {
		if r.Namespace != "" {
			t.Errorf("a namespaced access review was sent for %q although the rules review covers it", r.Namespace)
		}
		key := r.Resource
		if r.Subresource != "" {
			key += "/" + r.Subresource
		}
		asked[key+" "+r.Verb] = true
	}
	for _, want := range []string{
		"secrets get", "configmaps list", "serviceaccounts create", "serviceaccounts/token create",
		"pods/exec create", "pods/exec get", "pods/attach create", "pods/portforward create", "pods/proxy get", "services/proxy get",
		"nodes/proxy get", "nodes/stats get", "nodes/log get", "nodes/metrics get", "nodes/spec get", "nodes/configz get", "nodes/healthz get", "nodes/pods get", "nodes/checkpoint create",
		"pods/ephemeralcontainers patch", "users impersonate", "groups impersonate", "serviceaccounts impersonate", "clusterroles bind", "clusterroles escalate", "roles bind", "roles escalate",
		"pods watch", "events watch", "pods create", "pods delete", "pods deletecollection", "deployments patch", "deployments update", "nodes patch",
		"pods/log get", "* *", "networkpolicies create", "ingresses update", "pods/eviction create", "pods/binding create", "pods/status patch", "deployments/scale update",
		"controllerrevisions create", "customresourcedefinitions create", "validatingwebhookconfigurations create", "mutatingwebhookconfigurations patch",
		"validatingadmissionpolicies create", "certificatesigningrequests create", "tokenreviews create",
	} {
		if !asked[want] {
			t.Errorf("right %q not checked at cluster scope", want)
		}
	}
	for _, want := range []string{"get /metrics", "get /logs", "get /debug/pprof", "get /debug/pprof/profile"} {
		if !slices.Contains(a.seenURLs, want) {
			t.Errorf("non-resource URL %q not checked", want)
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
		{ns: "", resource: "nodes", sub: "log", verb: "get"},
		{ns: "rca-demo", resource: "pods", sub: "ephemeralcontainers", verb: "patch"},
		{ns: "", resource: "users", verb: "impersonate"},
		{ns: "", resource: "clusterroles", verb: "bind"},
		{ns: "", resource: "clusterroles", verb: "escalate"},
		{ns: "rca-demo", resource: "pods", verb: "watch"},
		{ns: "rca-demo", resource: "pods", verb: "delete"},
		{ns: "kube-system", resource: "deployments", verb: "patch"},
		{ns: "", resource: "pods", verb: "create"},
		{ns: "", resource: "*", verb: "*"},
		{ns: "kagent", resource: "*", verb: "get"},
		{ns: "kagent", resource: "pods", verb: "*"},
		// pod logs only in log namespaces
		{ns: "openagentix-knowledge", resource: "pods", sub: "log", verb: "get"},
		{ns: "kube-system", resource: "pods", sub: "log", verb: "get"},
		{ns: "", resource: "pods", sub: "log", verb: "get"},
		// a rule that names objects: an access review without a name does not see it
		{ns: "rca-demo", resource: "secrets", verb: "get", names: []string{"db-creds"}},
		{ns: "kagent", resource: "configmaps", verb: "get", names: []string{"x"}},
		// writes on resources that are on no list
		{ns: "kagent", resource: "networkpolicies", verb: "create"},
		{ns: "rca-demo", group: "agents.example", resource: "agents", verb: "update"},
		{ns: "", group: "apiextensions.k8s.io", resource: "customresourcedefinitions", verb: "delete"},
		{ns: "rca-demo", resource: "pods", sub: "eviction", verb: "create"},
		{ns: "kube-system", resource: "deployments", sub: "scale", verb: "update"},
		{ns: "", resource: "certificatesigningrequests", verb: "create"},
		{ns: "rca-demo", resource: "pods", sub: "status", verb: "patch"},
		// non-resource URLs
		{url: "/metrics", verb: "get"},
		{url: "/logs/*", verb: "get"},
		{url: "*", verb: "*"},
	}
	for _, g := range cases {
		name := fmt.Sprintf("%s/%s/%s %s %s", g.ns, g.resource, g.sub, g.verb, g.url)
		cfg := testConfig()
		c, a := newAuthzClient(cfg)
		ck := NewChecker(c, cfg)
		if err := ck.Run(ctx()); err != nil {
			t.Fatalf("%s: clean run failed: %v", name, err)
		}
		a.grant(g)
		if err := ck.Run(ctx()); err == nil {
			t.Errorf("%s: a forbidden right passed the check", name)
			continue
		}
		if ok, why := ck.Ready(); ok || why == "" {
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

func TestRightsCheckIncompleteReviewStillEvaluatesTheRules(t *testing.T) {
	cfg := testConfig()
	c, a := newAuthzClient(cfg)
	a.incomplete["kagent"] = true
	a.incomplete["rca-demo"] = true
	ck := NewChecker(c, cfg)
	if err := ck.Run(ctx()); err != nil {
		t.Fatalf("incomplete reviews with the intended role must pass: %v", err)
	}
	for _, g := range []grant{
		{ns: "kagent", resource: "secrets", verb: "get", names: []string{"db-creds"}},
		{ns: "rca-demo", resource: "pods", sub: "exec", verb: "create", names: []string{"web-1"}},
		{ns: "kagent", group: "openagentix.io", resource: "agentdefinitions", verb: "create"},
		{ns: "rca-demo", resource: "secrets", verb: "list"},
	} {
		a.revoke()
		a.grant(g)
		if err := ck.Run(ctx()); err == nil {
			t.Errorf("%+v: an incomplete review let a forbidden grant through", g)
		}
	}
}

func TestRightsCheckIncompleteReviewsAtManyNamespacesStayCheap(t *testing.T) {
	cfg := testConfig()
	for i := 0; i < 98; i++ {
		cfg.StatusNamespaces = append(cfg.StatusNamespaces, fmt.Sprintf("team-%02d", i))
	}
	c, a := newAuthzClient(cfg)
	for _, ns := range cfg.namespaces() {
		a.incomplete[ns] = true
	}
	ck := NewChecker(c, cfg)
	if err := ck.Run(ctx()); err != nil {
		t.Fatalf("100 incomplete namespaces: %v", err)
	}
	if total := len(a.seen) + len(a.seenURLs) + len(a.rulesNS); total > 1200 {
		t.Errorf("%d requests: the fallback must add a short fixed list per namespace", total)
	}
}

func TestDefaultDiscoveryRulesDoNotFailTheCheck(t *testing.T) {
	// system:basic-user, system:discovery, system:public-info-viewer and
	// system:service-account-issuer-discovery, bound to every authenticated identity
	nonRes := []authv1.NonResourceRule{{Verbs: []string{"get"}, NonResourceURLs: []string{
		"/.well-known/openid-configuration", "/.well-known/openid-configuration/", "/openid/v1/jwks", "/openid/v1/jwks/",
		"/api", "/api/*", "/apis", "/apis/*", "/healthz", "/livez", "/openapi", "/openapi/*", "/readyz", "/version", "/version/"}}}
	if bad := evalRules("rca-demo", true, nil, nonRes); len(bad) != 0 {
		t.Fatalf("default rules refused: %v", bad)
	}
	if bad := evalRules("rca-demo", true, nil, []authv1.NonResourceRule{{Verbs: []string{"get"}, NonResourceURLs: []string{"/metrics/"}}}); len(bad) == 0 {
		t.Fatal("/metrics/ passed")
	}
}

func TestRightsCheckNamespaceThatGrantsNothing(t *testing.T) {
	cfg := testConfig()
	c, a := newAuthzClient(cfg)
	a.empty["kagent"] = true
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

func TestRightsCheckScalesWithManyNamespaces(t *testing.T) {
	cfg := testConfig()
	for i := 0; i < 98; i++ {
		cfg.StatusNamespaces = append(cfg.StatusNamespaces, fmt.Sprintf("team-%02d", i))
	}
	c, a := newAuthzClient(cfg)
	ck := NewChecker(c, cfg)
	if err := ck.Run(ctx()); err != nil {
		t.Fatalf("100 namespaces: %v", err)
	}
	total := len(a.seen) + len(a.seenURLs) + len(a.rulesNS)
	if len(a.rulesNS) < 100 {
		t.Errorf("rules reviews: %d", len(a.rulesNS))
	}
	if total > 700 {
		t.Errorf("%d requests for 100 namespaces: the cost must not grow by hundreds of requests per namespace", total)
	}
}

func TestCheckerLogsTheReasonAndCallersDoNot(t *testing.T) {
	cfg := testConfig()
	c, a := newAuthzClient(cfg)
	var buf bytes.Buffer
	ck := NewChecker(c, cfg)
	ck.Logger = slog.New(slog.NewJSONHandler(&buf, nil))
	a.grant(grant{ns: "kube-system", resource: "secrets", verb: "get"})
	_ = ck.Run(ctx())
	if !strings.Contains(buf.String(), "secrets get is allowed in kube-system") {
		t.Errorf("the reason is not in the server log: %s", buf.String())
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
