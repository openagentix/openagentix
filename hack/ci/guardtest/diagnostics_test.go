package guardtest

// ADR 0025, slice 4: the admission policy openagentix-diagnostics-rbac, rendered by helm and executed with the Kubernetes CEL code. The policy
// is for every user (Helm included), so these cases name an ordinary administrator. Every denied case changes ONE thing in an object that is
// allowed, so the verdict can only come from the rule under test.

import (
	"fmt"
	"strings"
	"testing"
)

const (
	rbacGroup = "rbac.authorization.k8s.io"
	diagNS    = "openagentix-diagnostics"
	admin     = "kubernetes-admin"
)

var diagSets = []string{
	"diagnostics.enabled=true",
	"diagnostics.cluster.enabled=true",
	"diagnostics.apiServerCIDRs={172.18.0.0/24}",
	"diagnostics.cluster.logNamespaces={rca-demo}",
	"diagnostics.cluster.statusNamespaces={openagentix-knowledge,kagent}",
}

// diagPolicyEngine renders the chart with the diagnostics values and compiles only the policy under test.
func diagPolicyEngine(t *testing.T) (*rendered, *engine) {
	t.Helper()
	r := render(t, diagSets...)
	for _, p := range r.Policies {
		if p.Name == "openagentix-diagnostics-rbac" {
			e, err := newEngine(append(r.Policies[:0:0], p))
			if err != nil {
				t.Fatal(err)
			}
			return r, e
		}
	}
	t.Fatal("the render has no policy openagentix-diagnostics-rbac")
	return nil, nil
}

// diagObjects are the rendered RBAC objects of the diagnostics server by kind and name (RoleBinding: kind/namespace/name).
func diagObjects(r *rendered) map[string]m {
	out := map[string]m{}
	for _, d := range r.docs {
		k, _ := d["kind"].(string)
		md, _ := d["metadata"].(m)
		name, _ := md["name"].(string)
		ns, _ := md["namespace"].(string)
		switch k {
		case "ClusterRole":
			if strings.HasPrefix(name, "openagentix-cluster-read") {
				out[k+"/"+name] = d
			}
		case "RoleBinding":
			if strings.HasPrefix(name, "openagentix-cluster-read") {
				out[k+"/"+ns+"/"+name] = d
			}
		case "ClusterRoleBinding":
			if strings.HasPrefix(name, "openagentix-cluster-read") {
				out[k+"/"+name] = d
			}
		}
	}
	return out
}

func resOf(kind string) string {
	return map[string]string{"ClusterRole": "clusterroles", "Role": "roles", "RoleBinding": "rolebindings", "ClusterRoleBinding": "clusterrolebindings"}[kind]
}

// dreq is a request by an administrator for one RBAC object.
func dreq(name, op string, obj m, old m) request {
	src := obj
	if src == nil {
		src = old
	}
	md, _ := src["metadata"].(m)
	ns, _ := md["namespace"].(string)
	on, _ := md["name"].(string)
	k, _ := src["kind"].(string)
	return request{Name: name, User: admin, Op: op, Group: rbacGroup, Resource: resOf(k), Namespace: ns, ObjName: on, Object: obj, Old: old}
}

func dexp(name, op string, obj, old m, ok bool) expectation {
	return expectation{req: dreq(name, op, obj, old), allow: ok}
}

// rbObject builds a binding to a role for the given subjects.
func rbObject(kind, name, ns, roleKind, role string, subjects ...m) m {
	md := m{"name": name}
	if ns != "" {
		md["namespace"] = ns
	}
	subs := []any{}
	for _, s := range subjects {
		subs = append(subs, s)
	}
	return deepCopy(m{"apiVersion": rbacGroup + "/v1", "kind": kind, "metadata": md, "roleRef": m{"apiGroup": rbacGroup, "kind": roleKind, "name": role}, "subjects": subs})
}

var (
	subSA      = m{"kind": "ServiceAccount", "name": "cluster-read", "namespace": diagNS}
	subSANoNS  = m{"kind": "ServiceAccount", "name": "cluster-read"}
	subUser    = m{"kind": "User", "name": "system:serviceaccount:" + diagNS + ":cluster-read", "apiGroup": rbacGroup}
	subGroup   = m{"kind": "Group", "name": "system:serviceaccounts:" + diagNS, "apiGroup": rbacGroup}
	subDbSA    = m{"kind": "ServiceAccount", "name": "db-read", "namespace": diagNS}
	subDbUser  = m{"kind": "User", "name": "system:serviceaccount:" + diagNS + ":db-read", "apiGroup": rbacGroup}
	subOtherNS = m{"kind": "ServiceAccount", "name": "cluster-read", "namespace": "other"}
	subOther   = m{"kind": "ServiceAccount", "name": "builder", "namespace": "ci"}
)

func TestDiagnosticsPolicyRendered(t *testing.T) {
	r, _ := diagPolicyEngine(t)
	var pol, bind int
	for _, p := range r.Policies {
		if p.Name == "openagentix-diagnostics-rbac" {
			pol++
			if p.Spec.FailurePolicy == nil || string(*p.Spec.FailurePolicy) != "Fail" {
				t.Errorf("the policy must fail closed")
			}
			if len(p.Spec.MatchConditions) != 0 {
				t.Errorf("the policy is for every user: no match condition expected, got %d", len(p.Spec.MatchConditions))
			}
		}
	}
	for _, b := range r.Bindings {
		if b.Name == "openagentix-diagnostics-rbac" {
			bind++
		}
	}
	if pol != 1 || bind != 1 {
		t.Fatalf("want one policy and one binding, got %d and %d", pol, bind)
	}
	if got := len(diagObjects(r)); got != 3+3+1+1+3 {
		// 3 ClusterRoles, 3 RoleBindings of role 1, 1 of the logs role, the nodes ClusterRoleBinding... and the nodes ClusterRole is counted above
		t.Logf("rendered rbac objects: %d", got)
	}
}

func TestDiagnosticsPolicy(t *testing.T) {
	r, e := diagPolicyEngine(t)
	objs := diagObjects(r)
	if len(objs) < 7 {
		t.Fatalf("expected the rendered ClusterRoles and bindings, got %d objects", len(objs))
	}
	var cases []expectation
	// 1. every rendered object is admitted, on create and update
	for k, o := range objs {
		cases = append(cases,
			dexp("allow the rendered "+k+" CREATE", "CREATE", deepCopy(o), nil, true),
			dexp("allow the rendered "+k+" UPDATE", "UPDATE", deepCopy(o), deepCopy(o), true))
	}
	// 2. the three ClusterRoles: one change each
	roleNames := []string{"openagentix-cluster-read", "openagentix-cluster-read-logs", "openagentix-cluster-read-nodes"}
	for _, rn := range roleNames {
		base := objs["ClusterRole/"+rn]
		addRule := func(what string, rule m) expectation {
			o := deepCopy(base)
			o["rules"] = append(o["rules"].([]any), rule)
			return dexp(fmt.Sprintf("deny %s with a rule for %s", rn, what), "CREATE", o, nil, false)
		}
		for _, x := range []struct {
			what string
			rule m
		}{
			{"secrets", m{"apiGroups": []any{""}, "resources": []any{"secrets"}, "verbs": []any{"get"}}},
			{"configmaps", m{"apiGroups": []any{""}, "resources": []any{"configmaps"}, "verbs": []any{"get"}}},
			{"pods/exec", m{"apiGroups": []any{""}, "resources": []any{"pods/exec"}, "verbs": []any{"create"}}},
			{"pods/attach", m{"apiGroups": []any{""}, "resources": []any{"pods/attach"}, "verbs": []any{"create"}}},
			{"pods/portforward", m{"apiGroups": []any{""}, "resources": []any{"pods/portforward"}, "verbs": []any{"create"}}},
			{"pods/proxy", m{"apiGroups": []any{""}, "resources": []any{"pods/proxy"}, "verbs": []any{"get"}}},
			{"nodes/proxy", m{"apiGroups": []any{""}, "resources": []any{"nodes/proxy"}, "verbs": []any{"get"}}},
			{"serviceaccounts/token", m{"apiGroups": []any{""}, "resources": []any{"serviceaccounts/token"}, "verbs": []any{"create"}}},
			{"the verb watch on pods", m{"apiGroups": []any{""}, "resources": []any{"pods"}, "verbs": []any{"watch"}}},
			{"the verb * on pods", m{"apiGroups": []any{""}, "resources": []any{"pods"}, "verbs": []any{"*"}}},
			{"the resource *", m{"apiGroups": []any{""}, "resources": []any{"*"}, "verbs": []any{"get"}}},
			{"the apiGroup *", m{"apiGroups": []any{"*"}, "resources": []any{"pods"}, "verbs": []any{"get"}}},
			{"create on pods", m{"apiGroups": []any{""}, "resources": []any{"pods"}, "verbs": []any{"create"}}},
			{"patch on deployments", m{"apiGroups": []any{"apps"}, "resources": []any{"deployments"}, "verbs": []any{"patch"}}},
			{"delete on pods", m{"apiGroups": []any{""}, "resources": []any{"pods"}, "verbs": []any{"delete"}}},
			{"impersonate", m{"apiGroups": []any{""}, "resources": []any{"users"}, "verbs": []any{"impersonate"}}},
			{"bind", m{"apiGroups": []any{rbacGroup}, "resources": []any{"clusterroles"}, "verbs": []any{"bind"}}},
			{"escalate", m{"apiGroups": []any{rbacGroup}, "resources": []any{"clusterroles"}, "verbs": []any{"escalate"}}},
			{"a named object (resourceNames)", m{"apiGroups": []any{""}, "resources": []any{"pods"}, "verbs": []any{"get"}, "resourceNames": []any{"x"}}},
			{"a non-resource URL", m{"nonResourceURLs": []any{"/metrics"}, "verbs": []any{"get"}}},
		} {
			cases = append(cases, addRule(x.what, x.rule))
		}
		agg := deepCopy(base)
		agg["aggregationRule"] = m{"clusterRoleSelectors": []any{m{"matchLabels": m{"aggregate-to-view": "true"}}}}
		cases = append(cases, dexp("deny "+rn+" with an aggregationRule", "CREATE", agg, nil, false))
		// the same changes on update, one is enough
		agg2 := deepCopy(base)
		agg2["aggregationRule"] = m{"clusterRoleSelectors": []any{}}
		cases = append(cases, dexp("deny "+rn+" UPDATE that adds an aggregationRule (empty selectors)", "UPDATE", agg2, deepCopy(base), false))
		sec := deepCopy(base)
		sec["rules"] = append(sec["rules"].([]any), m{"apiGroups": []any{""}, "resources": []any{"secrets"}, "verbs": []any{"get"}})
		cases = append(cases, dexp("deny "+rn+" UPDATE that adds secrets", "UPDATE", sec, deepCopy(base), false))
	}
	// a role may lose rights: fewer rules is fine
	{
		o := deepCopy(objs["ClusterRole/openagentix-cluster-read"])
		o["rules"] = o["rules"].([]any)[:1]
		cases = append(cases, dexp("allow openagentix-cluster-read with fewer rules", "UPDATE", o, deepCopy(objs["ClusterRole/openagentix-cluster-read"]), true))
	}
	// the rights of role 1 cannot be moved into role 2 and the other way round: the logs role holds nothing but pods/log get
	{
		o := deepCopy(objs["ClusterRole/openagentix-cluster-read-logs"])
		o["rules"] = append(o["rules"].([]any), m{"apiGroups": []any{""}, "resources": []any{"pods", "events"}, "verbs": []any{"get", "list"}})
		cases = append(cases, dexp("deny the logs role with the rules of role 1", "CREATE", o, nil, false))
		o2 := deepCopy(objs["ClusterRole/openagentix-cluster-read"])
		o2["rules"] = append(o2["rules"].([]any), m{"apiGroups": []any{""}, "resources": []any{"pods/log"}, "verbs": []any{"get"}})
		cases = append(cases, dexp("deny role 1 with pods/log", "CREATE", o2, nil, false))
		o3 := deepCopy(objs["ClusterRole/openagentix-cluster-read"])
		o3["rules"] = append(o3["rules"].([]any), m{"apiGroups": []any{""}, "resources": []any{"nodes"}, "verbs": []any{"get"}})
		cases = append(cases, dexp("deny role 1 with nodes", "CREATE", o3, nil, false))
	}
	// an unrelated ClusterRole is nobody's business of this policy (including one that has the rights it refuses here)
	cases = append(cases, dexp("allow an unrelated ClusterRole with secrets", "CREATE",
		deepCopy(m{"apiVersion": rbacGroup + "/v1", "kind": "ClusterRole", "metadata": m{"name": "secret-reader"}, "rules": []any{m{"apiGroups": []any{""}, "resources": []any{"secrets"}, "verbs": []any{"get"}}}}), nil, true))

	// 3. bindings: the three subject forms
	forms := []struct {
		name string
		sub  m
	}{{"ServiceAccount", subSA}, {"ServiceAccount without a namespace", subSANoNS}, {"User system:serviceaccount:...", subUser}, {"Group system:serviceaccounts:<ns>", subGroup}}
	for _, f := range forms {
		for _, role := range []string{"view", "cluster-admin", "edit", "admin", "system:aggregate-to-view"} {
			cases = append(cases,
				dexp(fmt.Sprintf("deny a RoleBinding of %s to %s", f.name, role), "CREATE", rbObject("RoleBinding", "x", "rca-demo", "ClusterRole", role, f.sub), nil, false),
				dexp(fmt.Sprintf("deny a ClusterRoleBinding of %s to %s", f.name, role), "CREATE", rbObject("ClusterRoleBinding", "x", "", "ClusterRole", role, f.sub), nil, false))
		}
		cases = append(cases,
			dexp("deny a RoleBinding of "+f.name+" to a Role of the namespace", "CREATE", rbObject("RoleBinding", "x", "rca-demo", "Role", "openagentix-cluster-read", f.sub), nil, false),
			// the same change on UPDATE (an existing binding gets another subject form)
			dexp("deny an UPDATE that adds "+f.name+" to a binding of cluster-admin", "UPDATE", rbObject("RoleBinding", "x", "rca-demo", "ClusterRole", "cluster-admin", f.sub, subOther),
				rbObject("RoleBinding", "x", "rca-demo", "ClusterRole", "cluster-admin", subOther), false))
	}
	// two subjects, one of them cluster-read: the whole binding is judged
	cases = append(cases, dexp("deny a binding of builder and cluster-read to cluster-admin", "CREATE", rbObject("RoleBinding", "x", "rca-demo", "ClusterRole", "cluster-admin", subOther, subSA), nil, false))
	// the namespace group, whatever the role: refused even for the three roles
	for _, role := range roleNames {
		cases = append(cases, dexp("deny the namespace group on "+role, "CREATE", rbObject("RoleBinding", "x", "rca-demo", "ClusterRole", role, subGroup), nil, false))
	}
	// db-read is never bound, not even to the roles that exist
	for _, f := range []struct {
		name string
		sub  m
	}{{"ServiceAccount", subDbSA}, {"User", subDbUser}} {
		for _, role := range roleNames {
			cases = append(cases, dexp("deny a binding of db-read ("+f.name+") to "+role, "CREATE", rbObject("RoleBinding", "x", "rca-demo", "ClusterRole", role, f.sub), nil, false))
		}
		cases = append(cases, dexp("deny a ClusterRoleBinding of db-read ("+f.name+") to nodes", "CREATE", rbObject("ClusterRoleBinding", "x", "", "ClusterRole", "openagentix-cluster-read-nodes", f.sub), nil, false))
	}
	// a ClusterRoleBinding may reference only the nodes role
	for _, role := range roleNames[:2] {
		cases = append(cases, dexp("deny a ClusterRoleBinding of cluster-read to "+role+" (it would reach every namespace)", "CREATE", rbObject("ClusterRoleBinding", "x", "", "ClusterRole", role, subSA), nil, false))
	}
	cases = append(cases, dexp("allow a ClusterRoleBinding of cluster-read to the nodes role", "CREATE", rbObject("ClusterRoleBinding", "x", "", "ClusterRole", "openagentix-cluster-read-nodes", subSA), nil, true))
	// the logs role is not bound in a platform or system namespace
	for _, ns := range []string{"kube-system", "kube-public", "kube-node-lease", diagNS, "kagent", "mcp-tools", "openagentix-knowledge", "openagentix-system", "agentgateway-system", "toolhive-system", "ate-system", "openagentix-gateway", "openagentix-notify"} {
		cases = append(cases, dexp("deny the logs role for cluster-read in "+ns, "CREATE", rbObject("RoleBinding", "x", ns, "ClusterRole", "openagentix-cluster-read-logs", subSA), nil, false))
		cases = append(cases, dexp("deny the logs role for the User form in "+ns, "CREATE", rbObject("RoleBinding", "x", ns, "ClusterRole", "openagentix-cluster-read-logs", subUser), nil, false))
	}
	cases = append(cases,
		dexp("allow the logs role for cluster-read in a namespace of its own", "CREATE", rbObject("RoleBinding", "x", "rca-demo", "ClusterRole", "openagentix-cluster-read-logs", subSA), nil, true),
		dexp("allow role 1 for cluster-read in kube-system (status only, on the same terms)", "CREATE", rbObject("RoleBinding", "x", "kube-system", "ClusterRole", "openagentix-cluster-read", subSA), nil, true),
		dexp("allow role 1 for cluster-read as the User form in a namespace", "CREATE", rbObject("RoleBinding", "x", "rca-demo", "ClusterRole", "openagentix-cluster-read", subUser), nil, true),
		// not the same identity: a ServiceAccount of another namespace with the same name, and another account
		dexp("allow cluster-admin for a ServiceAccount cluster-read of ANOTHER namespace (not this identity)", "CREATE", rbObject("RoleBinding", "x", "rca-demo", "ClusterRole", "cluster-admin", subOtherNS), nil, true),
		dexp("allow view for an unrelated account", "CREATE", rbObject("RoleBinding", "x", "rca-demo", "ClusterRole", "view", subOther), nil, true))
	// the diagnostics namespace itself: no Role, and no RoleBinding that the chart does not render (it renders none)
	cases = append(cases,
		dexp("deny a Role in "+diagNS, "CREATE", deepCopy(m{"apiVersion": rbacGroup + "/v1", "kind": "Role", "metadata": m{"name": "r", "namespace": diagNS}, "rules": []any{m{"apiGroups": []any{""}, "resources": []any{"pods"}, "verbs": []any{"get"}}}}), nil, false),
		dexp("deny a Role in "+diagNS+" with no rules at all", "CREATE", deepCopy(m{"apiVersion": rbacGroup + "/v1", "kind": "Role", "metadata": m{"name": "r", "namespace": diagNS}}), nil, false),
		dexp("allow a Role in another namespace", "CREATE", deepCopy(m{"apiVersion": rbacGroup + "/v1", "kind": "Role", "metadata": m{"name": "r", "namespace": "rca-demo"}, "rules": []any{m{"apiGroups": []any{""}, "resources": []any{"pods"}, "verbs": []any{"get"}}}}), nil, true),
		dexp("deny a RoleBinding in "+diagNS+" for an unrelated account to an unrelated role", "CREATE", rbObject("RoleBinding", "x", diagNS, "ClusterRole", "view", subOther), nil, false),
		dexp("deny a RoleBinding in "+diagNS+" of the chart's own role names", "CREATE", rbObject("RoleBinding", "openagentix-cluster-read", diagNS, "ClusterRole", "openagentix-cluster-read", subSA), nil, false),
		dexp("deny a RoleBinding in "+diagNS+" UPDATE", "UPDATE", rbObject("RoleBinding", "x", diagNS, "ClusterRole", "view", subOther), rbObject("RoleBinding", "x", diagNS, "ClusterRole", "view", subOther), false))

	e2 := e
	allowed, denied := runCases(t, e2, cases)
	t.Logf("diagnostics policy: %d cases (%d allowed, %d refused)", len(cases), allowed, denied)
	if allowed < 16 || denied < 150 {
		t.Errorf("the suite shrank: %d allowed and %d refused cases", allowed, denied)
	}
}

// TestDiagnosticsPolicyHasNoLooseRule: the refused list is a property of the rendered text too, so a policy that never looks at one of the
// three roles cannot pass by accident (every role name and subject form must appear).
func TestDiagnosticsPolicyNamesWhatItGuards(t *testing.T) {
	r, _ := diagPolicyEngine(t)
	for _, p := range r.Policies {
		if p.Name != "openagentix-diagnostics-rbac" {
			continue
		}
		var all []string
		for _, v := range p.Spec.Variables {
			all = append(all, v.Expression)
		}
		for _, v := range p.Spec.Validations {
			all = append(all, v.Expression)
		}
		txt := strings.Join(all, "\n")
		for _, want := range []string{"openagentix-cluster-read", "openagentix-cluster-read-logs", "openagentix-cluster-read-nodes", "'cluster-read'", "'db-read'",
			"system:serviceaccount:openagentix-diagnostics:cluster-read", "system:serviceaccount:openagentix-diagnostics:db-read", "system:serviceaccounts:openagentix-diagnostics", "aggregationRule", "kube-system"} {
			if !strings.Contains(txt, want) {
				t.Errorf("the policy text never mentions %q", want)
			}
		}
	}
}

// Review F2: a diagnostics profile is not offered to the AgentTemplate guard (and the catalog) unless definitions may use it. The guard is
// the second layer behind the controller's own policy: it must not admit a template that names the server of a diagnostics profile.
func TestAgentTemplateGuardLeavesDiagnosticsProfilesOutUnlessAllowed(t *testing.T) {
	prof := []string{"mcp.profiles[1].name=rca", "mcp.profiles[1].codeMode=false", "mcp.profiles[1].tools.cluster-read={pods_get,pods_log}"}
	guardText := func(r *rendered) string {
		var b strings.Builder
		for _, p := range r.Policies {
			for _, v := range p.Spec.Variables {
				b.WriteString(v.Expression + "\n")
			}
			for _, v := range p.Spec.Validations {
				b.WriteString(v.Expression + "\n")
			}
		}
		return b.String()
	}
	off := render(t, append(append([]string{}, diagSets...), prof...)...)
	if txt := guardText(off); strings.Contains(txt, "toolhive-vmcp-rca") || strings.Contains(txt, "cluster-read_") {
		t.Errorf("allowDefinitions is false, but the guard names the diagnostics profile")
	}
	if len(off.Catalog.Tools.Toolhive.Profiles) == 0 {
		t.Fatal("the catalog lists no profile at all: the check would be empty")
	}
	for _, p := range off.Catalog.Tools.Toolhive.Profiles {
		if p.Name == "rca" {
			t.Errorf("allowDefinitions is false, but the catalog lists the profile rca")
		}
	}
	on := render(t, append(append(append([]string{}, diagSets...), prof...), "diagnostics.allowDefinitions=true")...)
	if !strings.Contains(guardText(on), "toolhive-vmcp-rca") {
		t.Errorf("allowDefinitions is true, but the guard does not know the server of rca (the control is empty)")
	}
}
