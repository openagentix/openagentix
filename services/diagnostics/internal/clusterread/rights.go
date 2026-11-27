package clusterread

import (
	"context"
	"errors"
	"fmt"
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

// Forbidden at cluster scope only: these resources have no namespace.
var forbiddenClusterOnly = []res{{"", "nodes", "proxy"}, {"", "nodes", "stats"}}

// The read role may get and list these; it may not watch or write them.
var readOnlyEverywhere = []res{
	{"", "pods", ""}, {"", "events", ""}, {"apps", "deployments", ""}, {"apps", "replicasets", ""}, {"apps", "statefulsets", ""}, {"apps", "daemonsets", ""},
}

// Other resources a read server never needs to write.
var writeForbiddenEverywhere = []res{
	{"", "pods", "log"}, {"", "services", ""}, {"rbac.authorization.k8s.io", "roles", ""}, {"rbac.authorization.k8s.io", "rolebindings", ""},
	{"batch", "jobs", ""}, {"batch", "cronjobs", ""}, {"", "persistentvolumeclaims", ""},
}

var writeForbiddenClusterOnly = []res{
	{"", "nodes", ""}, {"", "namespaces", ""}, {"rbac.authorization.k8s.io", "clusterroles", ""}, {"rbac.authorization.k8s.io", "clusterrolebindings", ""},
}

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

// scopes are the namespaces the check looks at, then cluster scope.
func (c Config) scopes() []string {
	out := slices.Clone(c.LogNamespaces)
	out = append(out, c.StatusNamespaces...)
	for _, ns := range []string{"kube-system", OwnNamespace} {
		if !slices.Contains(out, ns) {
			out = append(out, ns)
		}
	}
	return append(out, "")
}

// Checker runs the rights check of ADR 0025: SelfSubjectAccessReview for every
// forbidden right and SelfSubjectRulesReview for every listed namespace.
type Checker struct {
	kube kubernetes.Interface
	cfg  Config

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
	defer c.mu.Unlock()
	c.ok, c.why = ok, why
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

func (c *Checker) check(ctx context.Context) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	var all []right
	for _, sc := range c.cfg.scopes() {
		all = append(all, c.cfg.forbiddenAt(sc)...)
	}
	var (
		mu       sync.Mutex
		violated []string
		firstErr error
		wg       sync.WaitGroup
	)
	jobs := make(chan right)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for r := range jobs {
				rv := &authv1.SelfSubjectAccessReview{Spec: authv1.SelfSubjectAccessReviewSpec{ResourceAttributes: &authv1.ResourceAttributes{
					Namespace: r.scope, Verb: r.verb, Group: r.group, Resource: r.resource, Subresource: r.sub}}}
				out, err := c.kube.AuthorizationV1().SelfSubjectAccessReviews().Create(ctx, rv, metav1.CreateOptions{})
				mu.Lock()
				switch {
				case err != nil:
					if firstErr == nil {
						firstErr = err
						cancel()
					}
				case out.Status.Allowed:
					violated = append(violated, fmt.Sprintf("%s is allowed in %s", r.name(), scopeName(r.scope)))
				}
				mu.Unlock()
			}
		}()
	}
feed:
	for _, r := range all {
		select {
		case jobs <- r:
		case <-ctx.Done():
			break feed
		}
	}
	close(jobs)
	wg.Wait()
	if firstErr != nil {
		return "", firstErr
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if len(violated) > 0 {
		sort.Strings(violated)
		more := ""
		if len(violated) > 5 {
			more = fmt.Sprintf(" (and %d more)", len(violated)-5)
			violated = violated[:5]
		}
		return "a forbidden right is granted: " + strings.Join(violated, "; ") + more, nil
	}
	for _, ns := range append(slices.Clone(c.cfg.LogNamespaces), c.cfg.StatusNamespaces...) {
		rr, err := c.kube.AuthorizationV1().SelfSubjectRulesReviews().Create(ctx, &authv1.SelfSubjectRulesReview{Spec: authv1.SelfSubjectRulesReviewSpec{Namespace: ns}}, metav1.CreateOptions{})
		if err != nil {
			return "", err
		}
		if !readsPods(rr.Status.ResourceRules) {
			return fmt.Sprintf("namespace %s grants nothing: the role is not bound there", ns), nil
		}
	}
	return "", nil
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
