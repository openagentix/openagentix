package guardtest

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

// The guard of the container runtime (templates/control-plane-guard-workload.yaml): what the controller may write in the workload
// namespace. The allowed objects are the adapter's own golden output (services/control-plane/testdata/container-objects.json) with the
// names of this render; every denied case changes ONE thing in an allowed object.

const (
	wns       = "openagentix-workloads"
	cImage    = "registry.local/oa/echo@sha256:" + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	cKeySec   = "echo-go-virtual-key-1a2b3c4d"
	wlControl = controller
)

var containerSets = []string{
	"controlPlane.containerAgents.enabled=true",
	"controlPlane.policy.allowedRuntimes={builtin,container}",
	"controlPlane.policy.runtimes.container.images={registry.local/oa/}",
}

var gvr = map[string][2]string{
	"Deployment": {"apps", "deployments"}, "Service": {"", "services"},
	"ServiceAccount": {"", "serviceaccounts"}, "NetworkPolicy": {"networking.k8s.io", "networkpolicies"},
}

func containerObjects(t *testing.T, r *rendered) map[string]m {
	return containerObjectsFrom(t, r, "services/control-plane/testdata/container-objects.json")
}

func containerObjectsFrom(t *testing.T, r *rendered, path string) map[string]m {
	var list m
	readJSON(t, path, &list)
	ck := r.docsCatalogContainer(t)
	out := map[string]m{}
	for _, it := range list["items"].([]any) {
		b, _ := json.Marshal(it)
		s := string(b)
		s = strings.ReplaceAll(s, "ghcr.io/acme/agents/", "registry.local/oa/")
		s = strings.ReplaceAll(s, "openagentix-agents", wns)
		s = strings.ReplaceAll(s, "echo-go-virtual-key-0a1b2c3d", cKeySec)
		s = strings.ReplaceAll(s, `"app":"model-gateway"`, `"gateway.networking.k8s.io/gateway-name":"model-gateway"`)
		s = strings.ReplaceAll(s, `"openagentix-gateway"`, `"`+ck.GateNamespace+`"`)
		var o m
		_ = json.Unmarshal([]byte(s), &o)
		if o["kind"] == "NetworkPolicy" {
			o["spec"].(m)["egress"].([]any)[1].(m)["ports"].([]any)[0].(m)["port"] = float64(r.gatewayPort(t))
		}
		out[o["kind"].(string)] = deepCopy(o)
	}
	return out
}

type ckSettings struct{ GateNamespace string }

func (r *rendered) docsCatalogContainer(t *testing.T) ckSettings {
	for _, d := range r.docs {
		md, _ := d["metadata"].(m)
		if d["kind"] == "ConfigMap" && md["name"] == "openagentix-control-plane-catalog" {
			var c struct {
				Runtime struct {
					Container struct {
						GateNamespace string `json:"gateNamespace"`
					} `json:"container"`
				} `json:"runtime"`
			}
			s := d["data"].(m)["catalog.json"].(string)
			if err := json.Unmarshal([]byte(s), &c); err != nil {
				t.Fatal(err)
			}
			return ckSettings{c.Runtime.Container.GateNamespace}
		}
	}
	t.Fatal("no catalog")
	return ckSettings{}
}

func wl(name, kind, op string, obj, old m, allowed bool) expectation {
	g := gvr[kind]
	return expectation{allow: allowed, req: request{Name: name, User: wlControl, Op: op, Group: g[0], Resource: g[1], Namespace: wns, ObjName: "echo-go", Object: obj, Old: old}}
}

func TestContainerGuard(t *testing.T) {
	r := render(t, containerSets...)
	e, err := newEngine(r.Policies)
	if err != nil {
		t.Fatal(err)
	}
	objs := containerObjects(t, r)
	if len(objs) != 4 {
		t.Fatalf("golden has %d kinds", len(objs))
	}
	var cases []expectation
	for _, k := range []string{"Deployment", "Service", "ServiceAccount", "NetworkPolicy"} {
		o := objs[k]
		cases = append(cases,
			wl("allow "+k+" CREATE", k, "CREATE", deepCopy(o), nil, allow),
			wl("allow "+k+" UPDATE with what the server adds", k, "UPDATE", server2(o), server2(o), allow),
			wl("allow "+k+" DELETE", k, "DELETE", nil, server2(o), allow))
		// every kind: metadata and namespace
		cases = append(cases,
			mut("deny "+k+" in another namespace", k, objs, func(x m) { x["metadata"].(m)["namespace"] = "kagent" }, func(c *expectation) { c.req.Namespace = "kagent" }),
			mut("deny "+k+" with an owner reference", k, objs, func(x m) {
				x["metadata"].(m)["ownerReferences"] = []any{m{"apiVersion": "v1", "kind": "ConfigMap", "name": "x", "uid": "u"}}
			}),
			mut("deny "+k+" with an unknown top-level key", k, objs, func(x m) { x["data"] = m{"a": "b"} }),
			mut("deny "+k+" without its labels", k, objs, func(x m) { delete(x["metadata"].(m), "labels") }),
			mut("deny "+k+" with a foreign definition namespace", k, objs, func(x m) { setLabel(x, "openagentix.io/definition-namespace", "other") }),
			mut("deny "+k+" with an extra label", k, objs, func(x m) { setLabel(x, "evil", "1") }),
			mut("deny "+k+" with an extra annotation", k, objs, func(x m) { x["metadata"].(m)["annotations"].(m)["evil"] = "1" }),
			mut("deny "+k+" naming another agent in the label", k, objs, func(x m) { setLabel(x, "openagentix.io/agent-definition", "other") }),
		)
		cases = append(cases, wl("deny "+k+" DELETE without the labels", k, "DELETE", nil, func() m { n := server2(o); delLabel(n, "openagentix.io/agent-definition"); return n }(), deny))
	}
	dep := func(name string, f func(spec, pod, c m)) expectation {
		return mut(name, "Deployment", objs, func(x m) {
			spec := x["spec"].(m)
			pod := spec["template"].(m)["spec"].(m)
			f(spec, pod, pod["containers"].([]any)[0].(m))
		})
	}
	cases = append(cases,
		dep("deny Deployment hostNetwork", func(s, p, c m) { p["hostNetwork"] = true }),
		dep("deny Deployment hostPID", func(s, p, c m) { p["hostPID"] = true }),
		dep("deny Deployment hostIPC", func(s, p, c m) { p["hostIPC"] = true }),
		dep("deny Deployment privileged", func(s, p, c m) { c["securityContext"].(m)["privileged"] = true }),
		dep("deny Deployment added capability", func(s, p, c m) { c["securityContext"].(m)["capabilities"].(m)["add"] = []any{"NET_ADMIN"} }),
		dep("deny Deployment capabilities not dropped", func(s, p, c m) { c["securityContext"].(m)["capabilities"] = m{"drop": []any{"NET_RAW"}} }),
		dep("deny Deployment allowPrivilegeEscalation", func(s, p, c m) { c["securityContext"].(m)["allowPrivilegeEscalation"] = true }),
		dep("deny Deployment writable root filesystem", func(s, p, c m) { c["securityContext"].(m)["readOnlyRootFilesystem"] = false }),
		dep("deny Deployment runAsUser 0", func(s, p, c m) { p["securityContext"].(m)["runAsUser"] = int64(0) }),
		dep("deny Deployment runAsNonRoot false", func(s, p, c m) { p["securityContext"].(m)["runAsNonRoot"] = false }),
		dep("deny Deployment container runAsUser", func(s, p, c m) { c["securityContext"].(m)["runAsUser"] = int64(0) }),
		dep("deny Deployment seccomp Unconfined", func(s, p, c m) { p["securityContext"].(m)["seccompProfile"] = m{"type": "Unconfined"} }),
		dep("deny Deployment extra container", func(s, p, c m) { p["containers"] = append(p["containers"].([]any), deepCopy(c)) }),
		dep("deny Deployment initContainers", func(s, p, c m) { p["initContainers"] = []any{deepCopy(c)} }),
		dep("deny Deployment ephemeralContainers", func(s, p, c m) { p["ephemeralContainers"] = []any{deepCopy(c)} }),
		dep("deny Deployment hostPath volume", func(s, p, c m) {
			p["volumes"] = append(p["volumes"].([]any), m{"name": "h", "hostPath": m{"path": "/"}})
		}),
		dep("deny Deployment projected token volume", func(s, p, c m) {
			p["volumes"] = append(p["volumes"].([]any), m{"name": "t", "projected": m{"sources": []any{m{"serviceAccountToken": m{"path": "t"}}}}})
		}),
		dep("deny Deployment bigger emptyDir", func(s, p, c m) { p["volumes"].([]any)[0].(m)["emptyDir"].(m)["sizeLimit"] = "10Gi" }),
		dep("deny Deployment another ServiceAccount", func(s, p, c m) { p["serviceAccountName"] = "default" }),
		dep("deny Deployment token automount", func(s, p, c m) { p["automountServiceAccountToken"] = true }),
		dep("deny Deployment nodeName", func(s, p, c m) { p["nodeName"] = "node1" }),
		dep("deny Deployment tolerations", func(s, p, c m) { p["tolerations"] = []any{m{"operator": "Exists"}} }),
		dep("deny Deployment affinity", func(s, p, c m) { p["affinity"] = m{} }),
		dep("deny Deployment nodeSelector", func(s, p, c m) { p["nodeSelector"] = m{"a": "b"} }),
		dep("deny Deployment shareProcessNamespace", func(s, p, c m) { p["shareProcessNamespace"] = true }),
		dep("deny Deployment other runtimeClassName", func(s, p, c m) { p["runtimeClassName"] = "runc-host" }),
		dep("deny Deployment hostPort", func(s, p, c m) { c["ports"].([]any)[0].(m)["hostPort"] = int64(80) }),
		dep("deny Deployment privileged port", func(s, p, c m) { c["ports"].([]any)[0].(m)["containerPort"] = int64(80) }),
		dep("deny Deployment image by tag", func(s, p, c m) { c["image"] = "registry.local/oa/echo:v1" }),
		dep("deny Deployment image outside the registry prefixes", func(s, p, c m) {
			c["image"] = "docker.io/evil/echo@sha256:" + strings.Repeat("a", 64)
		}),
		dep("deny Deployment command", func(s, p, c m) { c["command"] = []any{"/bin/sh"} }),
		dep("deny Deployment args", func(s, p, c m) { c["args"] = []any{"-c", "x"} }),
		dep("deny Deployment envFrom", func(s, p, c m) { c["envFrom"] = []any{m{"secretRef": m{"name": "x"}}} }),
		dep("deny Deployment a key from another Secret", func(s, p, c m) {
			c["env"].([]any)[0].(m)["valueFrom"].(m)["secretKeyRef"].(m)["name"] = "kagent-db-credentials"
		}),
		dep("deny Deployment a key under another name", func(s, p, c m) { c["env"].([]any)[0].(m)["valueFrom"].(m)["secretKeyRef"].(m)["key"] = "password" }),
		dep("deny Deployment env reading a field", func(s, p, c m) {
			c["env"] = append(c["env"].([]any), m{"name": "X", "valueFrom": m{"fieldRef": m{"fieldPath": "metadata.name"}}})
		}),
		dep("deny Deployment reserved env OTEL_", func(s, p, c m) { c["env"] = append(c["env"].([]any), m{"name": "OTEL_SDK", "value": "1"}) }),
		dep("deny Deployment reserved env KUBERNETES_", func(s, p, c m) { c["env"] = append(c["env"].([]any), m{"name": "KUBERNETES_X", "value": "1"}) }),
		dep("deny Deployment another gateway URL", func(s, p, c m) { setEnv(c, "OPENAI_BASE_URL", "http://evil.example/v1") }),
		dep("deny Deployment a model outside the catalog", func(s, p, c m) { setEnv(c, "OPENAGENTIX_MODEL", "gpt-secret") }),
		dep("deny Deployment without limits", func(s, p, c m) { delete(c["resources"].(m), "limits") }),
		dep("deny Deployment CPU limit above the maximum", func(s, p, c m) { c["resources"].(m)["limits"].(m)["cpu"] = "8" }),
		dep("deny Deployment memory limit above the maximum", func(s, p, c m) { c["resources"].(m)["limits"].(m)["memory"] = "64Gi" }),
		dep("deny Deployment exec probe", func(s, p, c m) { c["livenessProbe"] = m{"exec": m{"command": []any{"sh"}}} }),
		dep("deny Deployment pull policy IfNotPresent (the render says Always)", func(s, p, c m) { c["imagePullPolicy"] = "IfNotPresent" }),
		dep("deny Deployment pull policy Never", func(s, p, c m) { c["imagePullPolicy"] = "Never" }),
		dep("deny Deployment without a pull policy", func(s, p, c m) { delete(c, "imagePullPolicy") }),
		dep("deny Deployment other scheduler", func(s, p, c m) { p["schedulerName"] = "evil-scheduler" }),
		dep("deny Deployment other termination message path", func(s, p, c m) { c["terminationMessagePath"] = "/tmp/x" }),
		dep("deny Deployment other termination message policy", func(s, p, c m) { c["terminationMessagePolicy"] = "FallbackToLogsOnError" }),
		dep("deny Deployment long termination grace period", func(s, p, c m) { p["terminationGracePeriodSeconds"] = int64(86400) }),
		dep("deny Deployment Recreate strategy", func(s, p, c m) { s["strategy"] = m{"type": "Recreate"} }),
		dep("deny Deployment rollout of everything at once", func(s, p, c m) {
			s["strategy"] = m{"type": "RollingUpdate", "rollingUpdate": m{"maxUnavailable": "100%", "maxSurge": "100%"}}
		}),
		dep("deny Deployment HTTPS probe", func(s, p, c m) { c["readinessProbe"].(m)["httpGet"].(m)["scheme"] = "HTTPS" }),
		dep("deny Deployment probe with a long timeout", func(s, p, c m) { c["livenessProbe"].(m)["timeoutSeconds"] = int64(60) }),
		dep("deny Deployment two replicas", func(s, p, c m) { s["replicas"] = int64(2) }),
		dep("deny Deployment selecting other pods", func(s, p, c m) { s["selector"] = m{"matchLabels": m{"app": "kagent"}} }),
		dep("deny Deployment extra volume mount", func(s, p, c m) {
			c["volumeMounts"] = append(c["volumeMounts"].([]any), m{"name": "tmp", "mountPath": "/etc"})
		}),
		dep("deny Deployment pod template label", func(s, p, c m) { s["template"].(m)["metadata"].(m)["labels"].(m)["extra"] = "x" }),
	)
	// the other kinds
	svc := func(name string, f func(spec m)) expectation {
		return mut(name, "Service", objs, func(x m) { f(x["spec"].(m)) })
	}
	cases = append(cases,
		svc("deny Service LoadBalancer", func(s m) { s["type"] = "LoadBalancer" }),
		svc("deny Service NodePort", func(s m) { s["type"] = "NodePort" }),
		svc("deny headless Service", func(s m) { s["clusterIP"] = "None"; s["clusterIPs"] = []any{"None"} }),
		svc("deny Service with session affinity", func(s m) { s["sessionAffinity"] = "ClientIP" }),
		svc("deny Service with local traffic policy", func(s m) { s["internalTrafficPolicy"] = "Local" }),
		svc("deny Service externalIPs", func(s m) { s["externalIPs"] = []any{"1.2.3.4"} }),
		svc("deny Service selecting other pods", func(s m) { s["selector"] = m{"app": "kagent"} }),
		svc("deny Service on another port", func(s m) { s["ports"].([]any)[0].(m)["port"] = int64(443) }),
		svc("deny Service to a privileged target port", func(s m) { s["ports"].([]any)[0].(m)["targetPort"] = int64(22) }),
	)
	sa := func(name string, f func(x m)) expectation { return mut(name, "ServiceAccount", objs, f) }
	cases = append(cases,
		sa("deny ServiceAccount token automount", func(x m) { x["automountServiceAccountToken"] = true }),
		sa("deny ServiceAccount image pull secrets", func(x m) { x["imagePullSecrets"] = []any{m{"name": "x"}} }),
		sa("deny ServiceAccount secrets", func(x m) { x["secrets"] = []any{m{"name": "x"}} }),
	)
	np := func(name string, f func(spec m)) expectation {
		return mut(name, "NetworkPolicy", objs, func(x m) { f(x["spec"].(m)) })
	}
	cases = append(cases,
		np("deny NetworkPolicy egress to everything", func(s m) { s["egress"] = append(s["egress"].([]any), m{}) }),
		np("deny NetworkPolicy egress to the internet", func(s m) {
			s["egress"].([]any)[1] = m{"to": []any{m{"ipBlock": m{"cidr": "0.0.0.0/0"}}}}
		}),
		np("deny NetworkPolicy ingress from everyone", func(s m) { s["ingress"] = []any{m{}} }),
		np("deny NetworkPolicy ingress from another namespace", func(s m) {
			s["ingress"].([]any)[0].(m)["from"].([]any)[0].(m)["namespaceSelector"] = m{"matchLabels": m{"kubernetes.io/metadata.name": "kagent"}}
		}),
		np("deny NetworkPolicy for all pods", func(s m) { s["podSelector"] = m{} }),
		np("deny NetworkPolicy without egress type", func(s m) { s["policyTypes"] = []any{"Ingress"} }),
	)
	// secrets of the workload namespace
	sec := secret("echo-go")
	sec["metadata"].(m)["namespace"] = wns
	sec["metadata"].(m)["name"] = cKeySec
	sec["metadata"].(m)["labels"] = m{lblManaged: "openagentix-control-plane", lblDef: "echo-go", "openagentix.io/definition-namespace": "kagent"}
	delete(sec["metadata"].(m), "ownerReferences")
	s := func(name, op string, o, old m, ok bool) expectation {
		return expectation{allow: ok, req: request{Name: name, User: wlControl, Op: op, Group: "", Resource: "secrets", Namespace: wns, ObjName: cKeySec, Object: o, Old: old}}
	}
	mod := func(f func(x m)) m { x := deepCopy(sec); f(x); return x }
	cases = append(cases,
		s("allow workload Secret CREATE", "CREATE", deepCopy(sec), nil, allow),
		s("allow workload Secret DELETE", "DELETE", nil, server2(sec), allow),
		s("deny workload Secret UPDATE", "UPDATE", deepCopy(sec), deepCopy(sec), deny),
		s("deny workload Secret with an owner reference", "CREATE", mod(func(x m) { x["metadata"].(m)["ownerReferences"] = []any{owner("echo-go")} }), nil, deny),
		s("deny workload Secret named for another agent", "CREATE", mod(func(x m) { setLabel(x, lblDef, "other") }), nil, deny),
		s("deny workload Secret with two keys", "CREATE", mod(func(x m) { x["data"].(m)["extra"] = "eA==" }), nil, deny),
		s("deny workload Secret of another type", "CREATE", mod(func(x m) { x["type"] = "kubernetes.io/service-account-token" }), nil, deny),
		s("deny workload Secret not immutable", "CREATE", mod(func(x m) { x["immutable"] = false }), nil, deny),
		s("deny workload Secret without the labels on DELETE", "DELETE", nil, mod(func(x m) { x["metadata"].(m)["labels"] = m{} }), deny),
	)
	// the agents-namespace guard no longer judges the workload namespace, and still refuses it for other kinds
	cases = append(cases, expectation{allow: deny, req: request{Name: "deny Secret in the agents namespace with the workload shape", User: wlControl, Op: "CREATE", Resource: "secrets", Namespace: "kagent", ObjName: cKeySec, Object: deepCopy(sec)}})
	cases = append(cases, expectation{allow: deny, req: request{Name: "deny Deployment in the agents namespace", User: wlControl, Op: "CREATE", Group: "apps", Resource: "deployments", Namespace: "kagent", ObjName: "echo-go", Object: deepCopy(objs["Deployment"])}})
	cases = append(cases, expectation{allow: deny, req: request{Name: "deny reading nothing: a Pod", User: wlControl, Op: "CREATE", Resource: "pods", Namespace: wns, ObjName: "x", Object: m{"apiVersion": "v1", "kind": "Pod", "metadata": m{"name": "x"}}}})
	// the route list
	rl := func(name string, data m, ok bool) expectation {
		cm := func(d m) m {
			return m{"apiVersion": "v1", "kind": "ConfigMap", "metadata": m{"name": "a2a-gate-routes", "namespace": r.docsCatalogContainer(t).GateNamespace, "labels": m{"app": "a2a-gate"}}, "data": d}
		}
		return expectation{allow: ok, req: request{Name: name, User: wlControl, Op: "UPDATE", Resource: "configmaps", Namespace: r.docsCatalogContainer(t).GateNamespace, ObjName: "a2a-gate-routes", Object: cm(data), Old: cm(m{"routes.json": `{"container":[]}`})}}
	}
	cases = append(cases,
		rl("allow route list with agents", m{"routes.json": `{"container":["kagent/echo-go","kagent/b"]}`}, allow),
		rl("allow empty route list", m{"routes.json": `{"container":[]}`}, allow),
		rl("deny route list with a URL", m{"routes.json": `{"container":["http://evil.example"]}`}, deny),
		rl("deny route list for another namespace", m{"routes.json": `{"container":["kube-system/x"]}`}, deny),
		rl("deny route list with another key", m{"routes.json": `{"container":[]}`, "other": "x"}, deny),
		rl("deny route list with extra json", m{"routes.json": `{"container":[],"upstream":"http://evil"}`}, deny),
	)
	allowedN, deniedN := runCases(t, e, cases)
	t.Logf("container guard: %d cases (%d allowed, %d refused)", len(cases), allowedN, deniedN)
	if deniedN < 70 {
		t.Errorf("the suite shrank: %d refused cases", deniedN)
	}
}

// With controlPlane.containerAgents.imagePullPolicy=IfNotPresent (the quick start) the guard pins that value, not Always.
func TestContainerGuardPullPolicyFollowsTheChart(t *testing.T) {
	r := render(t, append([]string{"controlPlane.containerAgents.imagePullPolicy=IfNotPresent"}, containerSets...)...)
	e, err := newEngine(r.Policies)
	if err != nil {
		t.Fatal(err)
	}
	objs := containerObjects(t, r)
	ok := mut("allow IfNotPresent when the chart says so", "Deployment", objs, func(x m) {
		x["spec"].(m)["template"].(m)["spec"].(m)["containers"].([]any)[0].(m)["imagePullPolicy"] = "IfNotPresent"
	})
	ok.allow = allow
	bad := mut("deny Always when the chart says IfNotPresent", "Deployment", objs, func(x m) {
		x["spec"].(m)["template"].(m)["spec"].(m)["containers"].([]any)[0].(m)["imagePullPolicy"] = "Always"
	})
	runCases(t, e, []expectation{ok, bad})
}

func setEnv(c m, name, v string) {
	for _, e := range c["env"].([]any) {
		if e.(m)["name"] == name {
			e.(m)["value"] = v
		}
	}
}

// server2 is server() for an object without a spec status shape: the fields the API server adds to metadata, the deployment revision
// annotation, and the defaults of a Deployment, a Service and a pod.
func server2(o m) m {
	n := server(o)
	md := n["metadata"].(m)
	md["finalizers"] = []any{}
	delete(md, "finalizers")
	delete(n, "status")
	switch n["kind"] {
	case "Deployment":
		md["annotations"].(m)["deployment.kubernetes.io/revision"] = "1"
		sp := n["spec"].(m)
		sp["strategy"] = m{"type": "RollingUpdate", "rollingUpdate": m{"maxUnavailable": "25%", "maxSurge": "25%"}}
		sp["revisionHistoryLimit"] = int64(10)
		sp["progressDeadlineSeconds"] = int64(600)
		pod := sp["template"].(m)["spec"].(m)
		pod["restartPolicy"], pod["dnsPolicy"], pod["schedulerName"], pod["terminationGracePeriodSeconds"] = "Always", "ClusterFirst", "default-scheduler", int64(30)
		c := pod["containers"].([]any)[0].(m)
		if c["imagePullPolicy"] == nil {
			c["imagePullPolicy"] = "IfNotPresent"
		}
		c["terminationMessagePath"], c["terminationMessagePolicy"] = "/dev/termination-log", "File"
		sp["template"].(m)["metadata"].(m)["creationTimestamp"] = nil
		for _, v := range pod["volumes"].([]any) { // a projected volume gets its default mode (0644)
			if pr, ok := v.(m)["projected"].(m); ok {
				pr["defaultMode"] = int64(420)
			}
		}
	case "Service":
		sp := n["spec"].(m)
		sp["clusterIP"], sp["clusterIPs"], sp["ipFamilies"] = "10.0.0.1", []any{"10.0.0.1"}, []any{"IPv4"}
		sp["ipFamilyPolicy"], sp["internalTrafficPolicy"], sp["sessionAffinity"] = "SingleStack", "Cluster", "None"
	}
	return n
}

// mut makes a case that changes one thing of the allowed object of a kind; the request is an UPDATE of the allowed object.
func mut(name, kind string, objs map[string]m, f func(x m), opts ...func(*expectation)) expectation {
	o := server2(objs[kind])
	old := server2(objs[kind])
	f(o)
	c := wl(name, kind, "UPDATE", o, old, deny)
	for _, op := range opts {
		op(&c)
	}
	_ = fmt.Sprint()
	return c
}

func (r *rendered) gatewayPort(t *testing.T) int {
	for _, d := range r.docs {
		md, _ := d["metadata"].(m)
		if d["kind"] == "ConfigMap" && md["name"] == "openagentix-control-plane-catalog" {
			var c struct {
				Runtime struct {
					Container struct {
						GatewayPort int `json:"gatewayPort"`
					} `json:"container"`
				} `json:"runtime"`
			}
			_ = json.Unmarshal([]byte(d["data"].(m)["catalog.json"].(string)), &c)
			return c.Runtime.Container.GatewayPort
		}
	}
	t.Fatal("no catalog")
	return 0
}
