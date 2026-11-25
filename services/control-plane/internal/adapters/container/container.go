// Package container is the Runtime adapter for container agents (ADR 0015): it runs the user's digest-pinned image as a
// hardened Deployment in the workload namespace, with its own ServiceAccount, a Service and a deny-by-default NetworkPolicy.
// The agent's gateway key reaches the pod only as a secretKeyRef to the key Secret the core creates; no manifest holds a key.
// Labels (managed-by, definition, definition-namespace) and the definition UID annotation are stamped by the core; there are
// no owner references because the namespace differs from the definition's. The adapter reads its own catalog section
// (runtime.container) and, for readiness, the Deployment's status only (no Pod is read).
package container

import (
	"context"
	"fmt"
	"strings"

	"github.com/openagentix/openagentix/services/control-plane/internal/api"
	"github.com/openagentix/openagentix/services/control-plane/internal/catalog"
	"github.com/openagentix/openagentix/services/control-plane/internal/keys"
	"github.com/openagentix/openagentix/services/control-plane/internal/kube"
	"github.com/openagentix/openagentix/services/control-plane/internal/plan"
)

const (
	// AgentLabel is the one label every selector uses: the pod label, the Deployment and Service selectors, the NetworkPolicy podSelector.
	AgentLabel = "openagentix.io/agent"
	keyDataKey = "OPENAI_API_KEY"
	cardPath   = "/.well-known/agent-card.json"
	runAsID    = 65532
)

var (
	deployments     = kube.Resource{Group: "apps", Version: "v1", Plural: "deployments", Kind: "Deployment", Namespaced: true}
	services        = kube.Resource{Version: "v1", Plural: "services", Kind: "Service", Namespaced: true}
	serviceAccounts = kube.Resource{Version: "v1", Plural: "serviceaccounts", Kind: "ServiceAccount", Namespaced: true}
	networkPolicies = kube.Resource{Group: "networking.k8s.io", Version: "v1", Plural: "networkpolicies", Kind: "NetworkPolicy", Namespaced: true}
)

// Getter reads one object, for readiness.
type Getter interface {
	Get(ctx context.Context, r kube.Resource, ns, name string) (kube.Object, error)
}

type Adapter struct {
	cat *catalog.Catalog
	k   *catalog.ContainerSettings
	get Getter
}

// New builds the adapter. get may be nil when only Desired is used.
func New(c *catalog.Catalog, get Getter) *Adapter {
	a := &Adapter{cat: c, get: get, k: c.Runtime.Container}
	if a.k == nil {
		a.k = &catalog.ContainerSettings{}
	}
	return a
}

func (a *Adapter) Name() string              { return "container" }
func (a *Adapter) KeyDataKey() string        { return keyDataKey }
func (a *Adapter) WorkloadNamespace() string { return a.k.Namespace }
func (a *Adapter) OwnedKinds() []kube.Resource {
	return []kube.Resource{deployments, services, serviceAccounts, networkPolicies}
}

// Capabilities states plainly what a container agent does not have: the platform cannot pause its tool calls, a restart loses
// what the image keeps in memory, /tmp is an emptyDir, and every conversation shares one ServiceAccount.
func (a *Adapter) Capabilities() api.Capabilities {
	iso := "container"
	if a.k.RuntimeClassName != "" {
		iso = "sandboxed-pod"
	}
	return api.Capabilities{Approvals: api.Unknown, DurableWaits: api.Unknown, WorkspacePersistence: "none", MaxStepSeconds: 0,
		CancelStopsLoop: api.Unknown, PerRunIdentity: "none", Isolation: iso}
}

func (a *Adapter) Ref(p plan.Plan) api.ObjectRef {
	return api.ObjectRef{APIVersion: "apps/v1", Kind: "Deployment", Name: p.Name}
}

// Endpoint is the gate's A2A route for the agent, or nil when the gate is off. The pod's own Service address is never published.
func (a *Adapter) Endpoint(p plan.Plan) *api.Endpoint {
	if a.cat.GateURL == "" {
		return nil
	}
	return &api.Endpoint{Protocol: api.ProtocolA2A, ProtocolVersion: "1.0", URL: fmt.Sprintf("%s/agents/%s/%s", a.cat.GateURL, p.Namespace, p.Name)}
}

type m = map[string]any

func sel(l map[string]string) m {
	out := m{}
	for k, v := range l {
		out[k] = v
	}
	return out
}

func quantities(l api.ResourceList) m {
	out := m{}
	if l.CPU != "" {
		out["cpu"] = l.CPU
	}
	if l.Memory != "" {
		out["memory"] = l.Memory
	}
	return out
}

// Desired returns the four objects of a plan, in the workload namespace.
func (a *Adapter) Desired(p plan.Plan) ([]kube.Manifest, error) {
	c := p.Container
	if c == nil {
		return nil, fmt.Errorf("plan for %s has no container spec", p.Name)
	}
	k := a.k
	if k.Namespace == "" {
		return nil, fmt.Errorf("catalog runtime.container.namespace is empty")
	}
	agent := m{AgentLabel: p.Name}
	meta := func() m {
		return m{"name": p.Name, "namespace": k.Namespace, "labels": m{"app.kubernetes.io/name": p.Name, AgentLabel: p.Name}}
	}

	env := []any{
		m{"name": "OPENAI_API_KEY", "valueFrom": m{"secretKeyRef": m{"name": p.KeySecret, "key": keyDataKey}}},
		m{"name": "OPENAI_BASE_URL", "value": p.GatewayBaseURL},
		m{"name": "OPENAGENTIX_MODEL", "value": p.Model},
	}
	for _, e := range c.Env { // the plan sorted them by name
		env = append(env, m{"name": e.Name, "value": e.Value})
	}
	probe := func(period int, failures int) m {
		pr := m{"httpGet": m{"path": cardPath, "port": c.Port}, "periodSeconds": period}
		if failures > 0 {
			pr["failureThreshold"] = failures
		}
		return pr
	}
	replicas := 1
	if p.Suspended {
		replicas = 0
	}
	tmpl := m{
		"metadata": m{"labels": sel(map[string]string{AgentLabel: p.Name})},
		"spec": m{
			"serviceAccountName": p.Name, "automountServiceAccountToken": false, "enableServiceLinks": false,
			"securityContext": m{"runAsNonRoot": true, "runAsUser": runAsID, "runAsGroup": runAsID, "seccompProfile": m{"type": "RuntimeDefault"}},
			"containers": []any{m{
				"name": "agent", "image": c.Image,
				"ports":           []any{m{"name": "a2a", "containerPort": c.Port, "protocol": "TCP"}},
				"env":             env,
				"resources":       m{"requests": quantities(c.Resources.Requests), "limits": quantities(c.Resources.Limits)},
				"securityContext": m{"allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true, "capabilities": m{"drop": []any{"ALL"}}},
				"volumeMounts":    []any{m{"name": "tmp", "mountPath": "/tmp"}},
				"readinessProbe":  probe(5, 0),
				"livenessProbe":   probe(30, 3),
			}},
			"volumes": []any{m{"name": "tmp", "emptyDir": m{"sizeLimit": "256Mi"}}},
		},
	}
	if p.KeyFingerprint != "" {
		tmpl["metadata"].(m)["annotations"] = m{keys.AnnotationFingerprint: p.KeyFingerprint}
	}
	if k.RuntimeClassName != "" {
		tmpl["spec"].(m)["runtimeClassName"] = k.RuntimeClassName
	}
	deploy := m{"apiVersion": "apps/v1", "kind": "Deployment", "metadata": meta(),
		"spec": m{"replicas": replicas, "selector": m{"matchLabels": agent}, "template": tmpl}}

	sa := m{"apiVersion": "v1", "kind": "ServiceAccount", "metadata": meta(), "automountServiceAccountToken": false}
	svc := m{"apiVersion": "v1", "kind": "Service", "metadata": meta(), "spec": m{
		"type": "ClusterIP", "selector": agent,
		"ports": []any{m{"name": "a2a", "port": catalog.WorkloadServicePort, "protocol": "TCP", "targetPort": c.Port}},
	}}
	nsSel := func(ns string) m { return m{"matchLabels": m{"kubernetes.io/metadata.name": ns}} }
	dns := k.DNSNamespace
	if dns == "" {
		dns = "kube-system"
	}
	gwPort := k.GatewayPort
	if gwPort == 0 {
		gwPort = 8080
	}
	np := m{"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy", "metadata": meta(), "spec": m{
		"podSelector": m{"matchLabels": agent},
		"policyTypes": []any{"Ingress", "Egress"},
		"ingress": []any{m{
			"from":  []any{m{"namespaceSelector": nsSel(k.GateNamespace), "podSelector": m{"matchLabels": sel(k.GatePodSelector)}}},
			"ports": []any{m{"protocol": "TCP", "port": c.Port}},
		}},
		"egress": []any{
			m{"to": []any{m{"namespaceSelector": nsSel(dns), "podSelector": m{"matchLabels": m{"k8s-app": "kube-dns"}}}},
				"ports": []any{m{"protocol": "UDP", "port": 53}, m{"protocol": "TCP", "port": 53}}},
			m{"to": []any{m{"namespaceSelector": nsSel(k.GatewayNamespace), "podSelector": m{"matchLabels": sel(k.GatewayPodSelector)}}},
				"ports": []any{m{"protocol": "TCP", "port": gwPort}}},
		},
	}}
	ns := k.Namespace
	return []kube.Manifest{
		{Resource: serviceAccounts, Object: sa, Namespace: ns},
		{Resource: deployments, Object: deploy, Namespace: ns},
		{Resource: services, Object: svc, Namespace: ns},
		{Resource: networkPolicies, Object: np, Namespace: ns},
	}, nil
}

func num(v any) float64 { f, _ := v.(float64); return f }

// Readiness reads the Deployment's status and conditions, nothing else (no Pod is read, so the message says what a Deployment can say).
func (a *Adapter) Readiness(ctx context.Context, p plan.Plan) (plan.Readiness, error) {
	o, err := a.get.Get(ctx, deployments, a.k.Namespace, p.Name)
	if kube.IsNotFound(err) {
		return plan.Readiness{Reason: "RuntimeNotCreated", Message: "the runtime has not created the agent yet"}, nil
	}
	if err != nil {
		return plan.Readiness{}, err
	}
	st, _ := o["status"].(map[string]any)
	if num(st["observedGeneration"]) < num(kube.Meta(o)["generation"]) {
		return plan.Readiness{Reason: "RuntimeStale", Message: "the runtime has not caught up with the latest spec yet"}, nil
	}
	conds, _ := st["conditions"].([]any)
	find := func(t string) map[string]any {
		for _, c := range conds {
			if c, ok := c.(map[string]any); ok && c["type"] == t {
				return c
			}
		}
		return nil
	}
	text := func(c map[string]any) string { s, _ := c["message"].(string); return strings.TrimSpace(s) }
	if rf := find("ReplicaFailure"); rf != nil && rf["status"] == "True" {
		return plan.Readiness{Reason: "RuntimeRejected", Message: text(rf)}, nil
	}
	av, pr := find("Available"), find("Progressing")
	if num(st["availableReplicas"]) >= 1 && av != nil && av["status"] == "True" {
		return plan.Readiness{Ready: true}, nil
	}
	if pr != nil && (pr["status"] == "False" || pr["reason"] == "ProgressDeadlineExceeded") {
		return plan.Readiness{Reason: "RuntimeNotReady", Message: "readiness probe on the agent card failed or the image could not start (" + text(pr) + ")"}, nil
	}
	return plan.Readiness{Reason: "RuntimePending", Message: "the runtime reports no available replica yet"}, nil
}
