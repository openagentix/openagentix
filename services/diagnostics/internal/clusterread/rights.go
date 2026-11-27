package clusterread

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	authv1 "k8s.io/api/authorization/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

// right is one request for SelfSubjectAccessReview.
type right struct {
	scope                      string // namespace, or "" for cluster scope
	group, resource, sub, verb string
}

func (r right) name() string {
	n := r.resource
	if r.sub != "" {
		n += "/" + r.sub
	}
	return n + " " + r.verb
}

var (
	anyVerb    = []string{"get", "list", "watch", "create", "update", "patch", "delete", "deletecollection"}
	writeVerbs = []string{"create", "update", "patch", "delete", "deletecollection"}
)

type res struct{ group, resource, sub string }

// Resources whose every verb is forbidden in every scope (ADR 0025, "Forbidden rights").
var forbiddenEverywhere = []res{
	{"", "secrets", ""}, {"", "configmaps", ""}, {"", "serviceaccounts", ""}, {"", "serviceaccounts", "token"},
	{"", "pods", "exec"}, {"", "pods", "attach"}, {"", "pods", "portforward"}, {"", "pods", "proxy"},
	{"", "services", "proxy"}, {"", "pods", "ephemeralcontainers"},
}

// Forbidden at cluster scope only: these resources have no namespace. The kubelet subresources
// of a node reach container logs, metrics and the pod list of the node.
var forbiddenClusterOnly = []res{
	{"", "nodes", "proxy"}, {"", "nodes", "stats"}, {"", "nodes", "log"}, {"", "nodes", "metrics"}, {"", "nodes", "spec"},
	{"", "nodes", "configz"}, {"", "nodes", "healthz"}, {"", "nodes", "pods"}, {"", "nodes", "checkpoint"},
}

// The read role may get and list these; it may not watch or write them.
var readOnlyEverywhere = []res{
	{"", "pods", ""}, {"", "events", ""}, {"apps", "deployments", ""}, {"apps", "replicasets", ""}, {"apps", "statefulsets", ""}, {"apps", "daemonsets", ""},
}

// Other resources a read server never needs to write. The rules review finds every other write;
// these are asked about by name, at cluster scope, so that a failed rules review is not blind.
var writeForbiddenEverywhere = []res{
	{"", "pods", "log"}, {"", "pods", "eviction"}, {"", "pods", "binding"}, {"", "pods", "status"}, {"", "services", ""}, {"", "persistentvolumeclaims", ""},
	{"rbac.authorization.k8s.io", "roles", ""}, {"rbac.authorization.k8s.io", "rolebindings", ""},
	{"batch", "jobs", ""}, {"batch", "cronjobs", ""},
	{"networking.k8s.io", "networkpolicies", ""}, {"networking.k8s.io", "ingresses", ""},
	{"apps", "deployments", "scale"}, {"apps", "controllerrevisions", ""},
}

var writeForbiddenClusterOnly = []res{
	{"", "nodes", ""}, {"", "namespaces", ""}, {"rbac.authorization.k8s.io", "clusterroles", ""}, {"rbac.authorization.k8s.io", "clusterrolebindings", ""},
	{"apiextensions.k8s.io", "customresourcedefinitions", ""}, {"admissionregistration.k8s.io", "validatingwebhookconfigurations", ""},
	{"admissionregistration.k8s.io", "mutatingwebhookconfigurations", ""}, {"admissionregistration.k8s.io", "validatingadmissionpolicies", ""},
	{"certificates.k8s.io", "certificatesigningrequests", ""}, {"authentication.k8s.io", "tokenreviews", ""},
}

// Paths a read server never needs. The defaults every user has (discovery, health, version) are not listed.
var forbiddenURLs = []string{"/metrics", "/logs", "/debug/pprof", "/debug/pprof/profile"}

// forbiddenAt lists the rights that must be denied in one scope.
func (c Config) forbiddenAt(scope string) []right {
	var out []right
	add := func(group, resource, sub, verb string) { out = append(out, right{scope, group, resource, sub, verb}) }
	for _, r := range forbiddenEverywhere {
		for _, v := range anyVerb {
			add(r.group, r.resource, r.sub, v)
		}
	}
	for _, r := range readOnlyEverywhere {
		add(r.group, r.resource, r.sub, "watch")
		for _, v := range writeVerbs {
			add(r.group, r.resource, r.sub, v)
		}
	}
	for _, r := range writeForbiddenEverywhere {
		for _, v := range writeVerbs {
			add(r.group, r.resource, r.sub, v)
		}
	}
	add("", "serviceaccounts", "", "impersonate")
	add("rbac.authorization.k8s.io", "roles", "", "bind")
	add("rbac.authorization.k8s.io", "roles", "", "escalate")
	add("*", "*", "", "*")
	if scope == "" {
		for _, r := range forbiddenClusterOnly {
			for _, v := range anyVerb {
				add(r.group, r.resource, r.sub, v)
			}
		}
		for _, r := range writeForbiddenClusterOnly {
			for _, v := range writeVerbs {
				add(r.group, r.resource, r.sub, v)
			}
		}
		add("", "nodes", "", "watch")
		add("", "users", "", "impersonate")
		add("", "groups", "", "impersonate")
		add("authentication.k8s.io", "userextras", "", "impersonate")
		add("rbac.authorization.k8s.io", "clusterroles", "", "bind")
		add("rbac.authorization.k8s.io", "clusterroles", "", "escalate")
	}
	// pod logs only where the operator allows them
	if !slices.Contains(c.LogNamespaces, scope) {
		add("", "pods", "log", "get")
	}
	return out
}

// namespaces are the namespaces the check reviews: the listed ones, kube-system and our own.
func (c Config) namespaces() []string {
	out := slices.Clone(c.LogNamespaces)
	out = append(out, c.StatusNamespaces...)
	for _, ns := range []string{"kube-system", OwnNamespace} {
		if !slices.Contains(out, ns) {
			out = append(out, ns)
		}
	}
	return out
}

// ---- evaluating a rules review ----

// allowedVerbs are the verbs the read role holds on a (group, resource). A rule that holds any
// other verb, or any other resource, with resource names or not, is a forbidden grant.
func allowedVerbs(group, resource string, isLog bool) []string {
	switch group + "|" + resource {
	case "|pods", "|events", "events.k8s.io|events", "apps|deployments", "apps|replicasets", "apps|statefulsets", "apps|daemonsets", "|nodes":
		return []string{"get", "list"}
	case "|pods/log":
		if isLog {
			return []string{"get", "list"}
		}
	// every authenticated user may ask the API server about its own rights
	case "authorization.k8s.io|selfsubjectaccessreviews", "authorization.k8s.io|selfsubjectrulesreviews", "authentication.k8s.io|selfsubjectreviews":
		return []string{"create"}
	}
	return nil
}

// allowedURLs are the non-resource paths of the default roles every user gets.
var allowedURLs = []string{
	"/healthz", "/livez", "/readyz", "/healthz/*", "/livez/*", "/readyz/*", "/version", "/version/", "/api", "/api/*", "/apis", "/apis/*",
	"/openapi", "/openapi/*", "/.well-known/openid-configuration", "/openid/v1/jwks",
}

// evalRules returns the grants of a rules review that the read role does not hold.
func evalRules(ns string, isLog bool, rules []authv1.ResourceRule, nonRes []authv1.NonResourceRule) []string {
	var bad []string
	for _, r := range rules {
		for _, g := range r.APIGroups {
			for _, res := range r.Resources {
				ok := allowedVerbs(g, res, isLog)
				var extra []string
				for _, v := range r.Verbs {
					if !slices.Contains(ok, v) {
						extra = append(extra, v)
					}
				}
				if len(extra) > 0 {
					name := res
					if len(r.ResourceNames) > 0 {
						name += " (named objects)"
					}
					bad = append(bad, fmt.Sprintf("%s %s is allowed in %s", name, strings.Join(extra, ","), scopeName(ns)))
				}
			}
		}
	}
	for _, r := range nonRes {
		for _, u := range r.NonResourceURLs {
			for _, v := range r.Verbs {
				if v != "get" || !slices.Contains(allowedURLs, u) {
					bad = append(bad, fmt.Sprintf("%s %s is allowed in %s", u, v, scopeName(ns)))
				}
			}
		}
	}
	return bad
}

// Checker runs the rights check of ADR 0025: SelfSubjectAccessReview for every
// forbidden right and SelfSubjectRulesReview for every listed namespace.
type Checker struct {
	kube kubernetes.Interface
	cfg  Config

	// Logger, if set, gets the reason whenever the result changes. Callers never see the reason.
	Logger *slog.Logger

	mu  sync.Mutex
	ok  bool
	why string
}

// NewChecker builds a checker. It reports not ready until a check has passed.
func NewChecker(client kubernetes.Interface, cfg Config) *Checker {
	return &Checker{kube: client, cfg: cfg, why: "the rights check has not run yet"}
}

// Ready reports the result of the last check.
func (c *Checker) Ready() (bool, string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.ok, c.why
}

func (c *Checker) set(ok bool, why string) {
	c.mu.Lock()
	changed := c.ok != ok || c.why != why
	c.ok, c.why = ok, why
	c.mu.Unlock()
	if changed && c.Logger != nil {
		if ok {
			c.Logger.Info("rights check passed: serving")
		} else {
			c.Logger.Warn("rights check failed: serving nothing", "reason", why)
		}
	}
}

// Run performs one check and records the result. It returns an error when the
// server must not serve.
func (c *Checker) Run(ctx context.Context) error {
	reason, err := c.check(ctx)
	switch {
	case err != nil:
		reason = "the rights check could not run"
		c.set(false, reason)
		return fmt.Errorf("%s: %w", reason, err)
	case reason != "":
		c.set(false, reason)
		return errors.New(reason)
	}
	c.set(true, "")
	return nil
}

func scopeName(s string) string {
	if s == "" {
		return "cluster scope"
	}
	return s
}

// parallel runs fn for every item with a small, fixed number of workers.
func parallel[T any](ctx context.Context, items []T, workers int, fn func(T) error) error {
	var (
		mu       sync.Mutex
		firstErr error
		wg       sync.WaitGroup
	)
	jobs := make(chan T)
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for it := range jobs {
				if err := fn(it); err != nil {
					mu.Lock()
					if firstErr == nil {
						firstErr = err
						cancel()
					}
					mu.Unlock()
				}
			}
		}()
	}
feed:
	for _, it := range items {
		select {
		case jobs <- it:
		case <-ctx.Done():
			break feed
		}
	}
	close(jobs)
	wg.Wait()
	if firstErr != nil {
		return firstErr
	}
	return ctx.Err()
}

const checkWorkers = 4

func (c *Checker) accessReview(ctx context.Context, r right) (bool, error) {
	rv := &authv1.SelfSubjectAccessReview{Spec: authv1.SelfSubjectAccessReviewSpec{ResourceAttributes: &authv1.ResourceAttributes{
		Namespace: r.scope, Verb: r.verb, Group: r.group, Resource: r.resource, Subresource: r.sub}}}
	out, err := c.kube.AuthorizationV1().SelfSubjectAccessReviews().Create(ctx, rv, metav1.CreateOptions{})
	if err != nil {
		return false, err
	}
	return out.Status.Allowed, nil
}

// check reviews every namespace once with SelfSubjectRulesReview, which lists all rules the identity
// holds there, from Roles and ClusterRoles alike, and evaluates them here. It then asks about the
// cluster-scope rights one by one with SelfSubjectAccessReview. The cost is one request per
// namespace plus a fixed number, not hundreds per namespace.
func (c *Checker) check(ctx context.Context) (string, error) {
	nss := c.cfg.namespaces()
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute+time.Duration(len(nss))*time.Second)
	defer cancel()
	var (
		mu       sync.Mutex
		violated []string
		nothing  []string
	)
	note := func(v ...string) {
		mu.Lock()
		violated = append(violated, v...)
		mu.Unlock()
	}
	err := parallel(ctx, nss, checkWorkers, func(ns string) error {
		rr, err := c.kube.AuthorizationV1().SelfSubjectRulesReviews().Create(ctx, &authv1.SelfSubjectRulesReview{Spec: authv1.SelfSubjectRulesReviewSpec{Namespace: ns}}, metav1.CreateOptions{})
		if err != nil {
			return err
		}
		if rr.Status.Incomplete {
			// a webhook authorizer can make the list incomplete: ask about each right instead
			for _, r := range c.cfg.forbiddenAt(ns) {
				allowed, err := c.accessReview(ctx, r)
				if err != nil {
					return err
				}
				if allowed {
					note(fmt.Sprintf("%s is allowed in %s", r.name(), scopeName(ns)))
				}
			}
			return nil
		}
		note(evalRules(ns, slices.Contains(c.cfg.LogNamespaces, ns), rr.Status.ResourceRules, rr.Status.NonResourceRules)...)
		if c.cfg.kind(ns) != nsNone && !readsPods(rr.Status.ResourceRules) {
			mu.Lock()
			nothing = append(nothing, ns)
			mu.Unlock()
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	err = parallel(ctx, c.cfg.forbiddenAt(""), checkWorkers, func(r right) error {
		allowed, err := c.accessReview(ctx, r)
		if err != nil {
			return err
		}
		if allowed {
			note(fmt.Sprintf("%s is allowed in %s", r.name(), scopeName(r.scope)))
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	err = parallel(ctx, forbiddenURLs, checkWorkers, func(path string) error {
		rv := &authv1.SelfSubjectAccessReview{Spec: authv1.SelfSubjectAccessReviewSpec{NonResourceAttributes: &authv1.NonResourceAttributes{Path: path, Verb: "get"}}}
		out, err := c.kube.AuthorizationV1().SelfSubjectAccessReviews().Create(ctx, rv, metav1.CreateOptions{})
		if err != nil {
			return err
		}
		if out.Status.Allowed {
			note(fmt.Sprintf("%s get is allowed in cluster scope", path))
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	if len(violated) > 0 {
		violated = slices.Compact(sortedCopy(violated))
		more := ""
		if len(violated) > 5 {
			more = fmt.Sprintf(" (and %d more)", len(violated)-5)
			violated = violated[:5]
		}
		return "a forbidden right is granted: " + strings.Join(violated, "; ") + more, nil
	}
	if len(nothing) > 0 {
		sort.Strings(nothing)
		return fmt.Sprintf("namespace %s grants nothing: the role is not bound there", strings.Join(nothing, ", ")), nil
	}
	return "", nil
}

func sortedCopy(in []string) []string {
	out := slices.Clone(in)
	sort.Strings(out)
	return out
}

func readsPods(rules []authv1.ResourceRule) bool {
	for _, r := range rules {
		verbs := slices.Contains(r.Verbs, "get") || slices.Contains(r.Verbs, "list") || slices.Contains(r.Verbs, "*")
		res := slices.Contains(r.Resources, "pods") || slices.Contains(r.Resources, "*")
		if verbs && res {
			return true
		}
	}
	return false
}

// Loop runs a check every interval until ctx ends.
func (c *Checker) Loop(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			_ = c.Run(ctx)
		}
	}
}
