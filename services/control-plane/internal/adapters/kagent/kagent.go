// Package kagent is the Runtime adapter for kagent 1.0.1 with Agent Substrate. It turns a Plan into the five objects
// that charts/openagentix/templates/kagent.yaml renders for a chart agent (ModelConfig, Harness, AgentTemplate, optional
// EgressPolicy, Agent), field for field; a golden test compares it with `helm template`. Labels and owner references are
// not set here: the core stamps them on every object. The adapter derives every object name from the definition's name
// (gateway-<name>, <name>-harness, <name>-template, <name>-egress, <name>) and reads its own section of the catalog
// (runtime.kagent). The platform plan names none of them.
package kagent

import (
	"context"
	"fmt"
	"unicode/utf8"

	"github.com/openagentix/openagentix/services/control-plane/internal/api"
	"github.com/openagentix/openagentix/services/control-plane/internal/catalog"
	"github.com/openagentix/openagentix/services/control-plane/internal/keys"
	"github.com/openagentix/openagentix/services/control-plane/internal/kube"
	"github.com/openagentix/openagentix/services/control-plane/internal/plan"
)

const apiVersion = "api.kagent.dev/v1alpha3"

// keyDataKey is the data key of the virtual-key Secret that the ModelConfig's apiKeySecretKey names (the chart's agent
// Secrets use the same one).
const keyDataKey = "OPENAI_API_KEY"

// ModelConfigName and the other names the adapter derives from a definition's name.
func ModelConfigName(name string) string { return "gateway-" + name }
func harnessName(name string) string     { return name + "-harness" }
func templateName(name string) string    { return name + "-template" }
func egressName(name string) string      { return name + "-egress" }

var (
	modelConfigs   = kube.Resource{Group: "api.kagent.dev", Version: "v1alpha3", Plural: "modelconfigs", Kind: "ModelConfig", Namespaced: true}
	harnesses      = kube.Resource{Group: "api.kagent.dev", Version: "v1alpha3", Plural: "harnesses", Kind: "Harness", Namespaced: true}
	agentTemplates = kube.Resource{Group: "api.kagent.dev", Version: "v1alpha3", Plural: "agenttemplates", Kind: "AgentTemplate", Namespaced: true}
	egressPolicies = kube.Resource{Group: "api.kagent.dev", Version: "v1alpha3", Plural: "egresspolicies", Kind: "EgressPolicy", Namespaced: true}
	agents         = kube.Resource{Group: "api.kagent.dev", Version: "v1alpha3", Plural: "agents", Kind: "Agent", Namespaced: true}
)

// Getter reads one object, for readiness.
type Getter interface {
	Get(ctx context.Context, r kube.Resource, ns, name string) (kube.Object, error)
}

type Adapter struct {
	cat *catalog.Catalog
	k   *catalog.KagentSettings // runtime.kagent
	get Getter
}

// KeyDataKey is the data key the core puts the key under in the key Secret.
func (a *Adapter) KeyDataKey() string { return keyDataKey }

// Capabilities reports what the runtime can do. Every value is from the kagent clone's documents and API types, read on
// 2026-11-25 (kagent commit 558e3d7), and anything not verified is "unknown":
//   - approvals yes: docs/architecture/human-in-the-loop.md (tool approval pauses an A2A task for a decision);
//     go/api/v1alpha3/agenttemplate_types.go (RequireApproval on a tool binding).
//   - durableWaits yes: docs/architecture/persistence-checkpoints-and-forks.md ("Input-required and auth-required tasks are
//     durably suspended with VOLUMES snapshots"); docs/architecture/human-in-the-loop.md (the Actor is quiesced at the
//     boundary). A turn that is running when the workload restarts is lost (ADR 0012, "Limits"); that is not a wait.
//   - workspacePersistence snapshot: docs/architecture/runtime-and-lifecycle.md ("Substrate v1.0.0 uses snapshot fidelity",
//     "Suspending an Actor preserves files, not running commands").
//   - maxStepSeconds 600: docs/architecture/runtime-and-lifecycle.md (bash: "60-second default timeout; timeout_seconds can
//     select up to 600 seconds").
//   - cancelStopsLoop unknown: docs/architecture/usage-extension.md and telemetry.md describe a canceled execution and
//     "the interrupted execution", but nothing states that a cancel ends the agent's loop in every harness, and it was not
//     tried on a cluster.
//   - perRunIdentity session: docs/architecture/agent-identity-lookup.md (a Substrate Actor JWT per Session); there is no
//     identity per run, and runs are not a runtime concept yet.
func (a *Adapter) Capabilities() api.Capabilities {
	return api.Capabilities{
		Approvals: api.Yes, DurableWaits: api.Yes, WorkspacePersistence: "snapshot",
		MaxStepSeconds: 600, CancelStopsLoop: api.Unknown, PerRunIdentity: "session",
		// every session runs in its own sandbox on Agent Substrate (gVisor)
		Isolation: "sandbox-per-session",
	}
}

// New builds the adapter. get may be nil when only Desired is used.
func New(c *catalog.Catalog, get Getter) *Adapter {
	a := &Adapter{cat: c, get: get, k: c.Runtime.Kagent}
	if a.k == nil {
		a.k = &catalog.KagentSettings{}
	}
	return a
}

func (a *Adapter) Name() string { return "kagent" }

// OwnedKinds are the endpoints the core lists (by label) to prune what is no longer wanted.
func (a *Adapter) OwnedKinds() []kube.Resource {
	return []kube.Resource{modelConfigs, harnesses, agentTemplates, egressPolicies, agents}
}

func obj(kind, ns, name string, spec kube.Object) kube.Object {
	return kube.Object{"apiVersion": apiVersion, "kind": kind, "metadata": kube.Object{"name": name, "namespace": ns}, "spec": spec}
}

func strs(l []string) []any {
	out := make([]any, len(l))
	for i, s := range l {
		out[i] = s
	}
	return out
}

// Desired returns the objects for a plan, in the chart's order. kagent's Agent and Harness have no suspend, pause or
// replicas field (go/api/v1alpha3/agent_types.go, harness_types.go; docs/architecture/runtime-and-lifecycle.md says session
// suspension is platform-managed and there are no public controls), so a suspended plan produces every object except the
// Agent: with no Agent there is nothing to call, and the key, the ModelConfig and the other objects stay for the resume. Cost, from
// docs/architecture/configuration-and-compilation.md ("Deleting an Agent retires its definition ... Recreating the same name creates a
// new identity"): a resume is a new Agent for new sessions. Not tried on a cluster.
func (a *Adapter) Desired(p plan.Plan) ([]kube.Manifest, error) {
	ns := p.Namespace
	var out []kube.Manifest

	mc := obj("ModelConfig", ns, ModelConfigName(p.Name), kube.Object{
		"provider":        "OpenAI",
		"model":           p.Model,
		"apiKeySecret":    p.KeySecret,
		"apiKeySecretKey": keyDataKey,
		"stream":          false,
		"openAI":          kube.Object{"baseUrl": p.GatewayBaseURL},
	})
	mc["metadata"].(kube.Object)["annotations"] = kube.Object{"openagentix.io/agent": p.Name}
	out = append(out, kube.Manifest{Resource: modelConfigs, Object: mc})

	hk := kube.Object{}
	if p.Memory != nil {
		// the shared embedding ModelConfig is rendered once, in the catalog's agents namespace
		mem := kube.Object{"modelConfigRef": kube.Object{"name": a.k.MemoryModelConfig, "namespace": a.cat.Namespaces.Agents}}
		if p.Memory.TTLDays > 0 {
			mem["ttlDays"] = p.Memory.TTLDays
		}
		hk["memory"] = mem
	}
	hspec := kube.Object{
		"kagent":    hk,
		"workload":  kube.Object{"image": a.k.HarnessImage},
		"substrate": kube.Object{"workerPoolRef": kube.Object{"name": a.k.WorkerPool}, "snapshotPolicy": kube.Object{"location": a.k.SnapshotLocation}},
	}
	if len(a.k.HarnessEnv) > 0 {
		var env []any
		for _, e := range a.k.HarnessEnv {
			env = append(env, kube.Object{"name": e.Name, "value": e.Value})
		}
		hspec["env"] = env
	}
	hobj := obj("Harness", ns, harnessName(p.Name), hspec)
	annotateKey(hobj, p)
	out = append(out, kube.Manifest{Resource: harnesses, Object: hobj})

	tspec := kube.Object{"modelConfig": kube.Object{"name": ModelConfigName(p.Name)}, "systemPrompt": p.Prompt}
	if p.Description != "" {
		tspec["description"] = p.Description
	}
	if len(p.Tools) > 0 {
		tspec["tools"] = []any{kube.Object{"mcp": kube.Object{
			"server": kube.Object{"kind": "RemoteMCPServer", "name": p.ToolBackend}, // no apiGroup: kagent's admission webhook rejects it
			"tools":  strs(p.Tools),
		}}}
	}
	if len(p.Skills) > 0 {
		var sk []any
		for _, s := range p.Skills {
			sk = append(sk, kube.Object{"name": s.Name, "source": kube.Object{"oci": s.Ref}})
		}
		tspec["skills"] = sk
	}
	out = append(out, kube.Manifest{Resource: agentTemplates, Object: obj("AgentTemplate", ns, templateName(p.Name), tspec)})

	aspec := kube.Object{"template": kube.Object{"ref": kube.Object{"name": templateName(p.Name)}}, "harnessRef": kube.Object{"name": harnessName(p.Name)}}
	if len(p.Egress) > 0 {
		var d []any
		for _, o := range p.Egress {
			d = append(d, kube.Object{"origin": o})
		}
		out = append(out, kube.Manifest{Resource: egressPolicies, Object: obj("EgressPolicy", ns, egressName(p.Name), kube.Object{"destinations": d})})
		aspec["egressPolicyRefs"] = []any{kube.Object{"name": egressName(p.Name)}}
	}
	if p.Suspended {
		return out, nil
	}
	aobj := obj("Agent", ns, p.Name, aspec)
	annotateKey(aobj, p)
	out = append(out, kube.Manifest{Resource: agents, Object: aobj})
	return out, nil
}

// annotateKey records the fingerprint of the registered key on an object, so that replacing the key changes the object.
// Whether kagent recreates the agent's pod on a changed annotation of the Harness or the Agent is not verified on a
// live cluster; a spec field (a harness env entry) would be the next thing to try.
func annotateKey(o kube.Object, p plan.Plan) {
	if p.KeyFingerprint == "" {
		return
	}
	o["metadata"].(kube.Object)["annotations"] = kube.Object{keys.AnnotationFingerprint: p.KeyFingerprint}
}

// Ref is the generic reference status carries.
func (a *Adapter) Ref(p plan.Plan) api.ObjectRef {
	return api.ObjectRef{APIVersion: apiVersion, Kind: "Agent", Name: p.Name}
}

// Endpoint is the gate's A2A route for the agent, or nil when the gate is off (then nobody but the platform's own callers
// may reach the agent, and the controller does not advertise a route). The gate forwards A2A-Version 1.0
// (services/a2a-gate); kagent serves A2A v1 (docs/architecture/a2a-transports.md).
func (a *Adapter) Endpoint(p plan.Plan) *api.Endpoint {
	if a.cat.GateURL == "" {
		return nil
	}
	return &api.Endpoint{Protocol: api.ProtocolA2A, ProtocolVersion: "1.0", URL: fmt.Sprintf("%s/agents/%s/%s", a.cat.GateURL, p.Namespace, p.Name)}
}

// Readiness reads the Agent's own conditions. The reasons it returns are the documented ones of the Ready condition
// (api.reasons); the runtime's own reason word is kept in the message.
func (a *Adapter) Readiness(ctx context.Context, p plan.Plan) (plan.Readiness, error) {
	o, err := a.get.Get(ctx, agents, p.Namespace, p.Name)
	if kube.IsNotFound(err) {
		return plan.Readiness{Reason: "RuntimeNotCreated", Message: "the runtime has not created the agent yet"}, nil
	}
	if err != nil {
		return plan.Readiness{}, err
	}
	st, _ := o["status"].(map[string]any)
	conds, _ := st["conditions"].([]any)
	find := func(t string) map[string]any {
		for _, c := range conds {
			if m, ok := c.(map[string]any); ok && m["type"] == t {
				return m
			}
		}
		return nil
	}
	word := func(m map[string]any, def string) string {
		if r, _ := m["reason"].(string); r != "" {
			return r
		}
		return def
	}
	msg := func(m map[string]any) string {
		s, _ := m["message"].(string)
		return truncateRunes(s, 200)
	}
	own := func(reason, message string) string {
		if message == "" {
			return reason
		}
		return truncateRunes(reason+": "+message, 200)
	}
	// A status the runtime wrote for an older spec says nothing about this one.
	gen, _ := metaGeneration(o)
	if og, ok := st["observedGeneration"].(float64); ok && gen > 0 && og < gen {
		return plan.Readiness{Reason: "RuntimeStale", Message: "the runtime has not observed the latest spec of the agent yet"}, nil
	}
	if r := find("Ready"); r != nil {
		if og, ok := r["observedGeneration"].(float64); ok && gen > 0 && og < gen {
			return plan.Readiness{Reason: "RuntimeStale", Message: "the runtime's Ready condition is for an older spec"}, nil
		}
		if r["status"] == "True" {
			return plan.Readiness{Ready: true, Reason: "Ready"}, nil
		}
		return plan.Readiness{Reason: "RuntimeNotReady", Message: own(word(r, "NotReady"), msg(r))}, nil
	}
	if ac := find("Accepted"); ac != nil && ac["status"] == "False" {
		return plan.Readiness{Reason: "RuntimeRejected", Message: own(word(ac, "NotAccepted"), msg(ac))}, nil
	}
	return plan.Readiness{Reason: "RuntimePending", Message: "the runtime reports no Ready condition yet"}, nil
}

func metaGeneration(o kube.Object) (float64, bool) {
	g, ok := kube.Meta(o)["generation"].(float64)
	return g, ok
}

// truncateRunes cuts s to at most n characters, never in the middle of one.
func truncateRunes(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
}
