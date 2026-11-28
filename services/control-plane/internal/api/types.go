// Package api holds the AgentDefinition types of openagentix.io/v1alpha1 as ADR 0007 defines them, with the changes of
// ADR 0012. It has no upstream vocabulary: nothing here names a runtime, a gateway or a tool server product.
package api

import (
	"encoding/json"
	"fmt"
)

const (
	Group      = "openagentix.io"
	Version    = "v1alpha1"
	Kind       = "AgentDefinition"
	Plural     = "agentdefinitions"
	APIVersion = Group + "/" + Version

	// FinalizerGatewayKey keeps the definition until its key hash is removed from the gateway.
	FinalizerGatewayKey = "openagentix.io/gateway-key"

	LabelManagedBy  = "app.kubernetes.io/managed-by"
	ManagedByValue  = "openagentix-control-plane"
	LabelDefinition = "openagentix.io/agent-definition"
	// LabelDefinitionNamespace and AnnotationDefinitionUID are on the objects the container runtime writes in the workload
	// namespace. An owner reference cannot cross namespaces, so these (with LabelDefinition) are how the controller finds
	// and recognises what belongs to a definition there.
	LabelDefinitionNamespace = "openagentix.io/definition-namespace"
	AnnotationDefinitionUID  = "openagentix.io/definition-uid"

	// Runtime types (spec.runtime.type). Absent means builtin.
	RuntimeBuiltin   = "builtin"
	RuntimeContainer = "container"

	// Reserved label keys (ADR 0012, change 12). They are informational: anyone who can write the object can set them, so
	// no access, policy or billing decision may ever read them. The controller copies team and project onto the objects it
	// creates and into the gateway key entry's metadata, so that cost metrics can carry them later.
	LabelTeam     = "openagentix.io/team"
	LabelProject  = "openagentix.io/project"
	LabelWorkItem = "openagentix.io/work-item"

	// Endpoint protocol names.
	ProtocolA2A = "a2a"

	CondAccepted = "Accepted"
	CondKeyReady = "KeyReady"
	CondApplied  = "Applied"
	CondReady    = "Ready"
	// CondSynced is present only after a pass could not read something it needed (the API server hiccuped). False with
	// reason TransientError means: the other conditions are the last known state, not a new verdict.
	CondSynced = "Synced"
)

// Condition types in the order status shows them.
var ConditionTypes = []string{CondAccepted, CondKeyReady, CondApplied, CondReady}

// ObjectMeta is the part of metadata the controller reads.
type ObjectMeta struct {
	Name            string `json:"name"`
	Namespace       string `json:"namespace,omitempty"`
	UID             string `json:"uid,omitempty"`
	Generation      int64  `json:"generation,omitempty"`
	ResourceVersion string `json:"resourceVersion,omitempty"`
	// Labels: only the reserved keys (LabelTeam, LabelProject) are ever read, and never for an access decision.
	Labels            map[string]string `json:"labels,omitempty"`
	CreationTimestamp string            `json:"creationTimestamp,omitempty"`
	DeletionTimestamp string            `json:"deletionTimestamp,omitempty"`
	Finalizers        []string          `json:"finalizers,omitempty"`
}

type Memory struct {
	Enabled bool `json:"enabled"`
	TTLDays int  `json:"ttlDays,omitempty"`
}

type Egress struct {
	Allow []string `json:"allow,omitempty"`
}

// Knowledge is the knowledge-base feature. Collections is reserved: selecting collections is not available yet and a
// definition that lists some is refused.
type Knowledge struct {
	Enabled     bool     `json:"enabled"`
	Collections []string `json:"collections,omitempty"`
}

// Notify is the delivery feature. Destinations is reserved: selecting destinations is not available yet and a definition
// that lists some is refused.
type Notify struct {
	Enabled      bool     `json:"enabled"`
	Destinations []string `json:"destinations,omitempty"`
}

// Skill names a skill of the platform catalog. Version, when set, must be one the catalog offers.
type Skill struct {
	Name    string `json:"name"`
	Version string `json:"version,omitempty"`
}

// ConfigMapKeyRef points at one key of a ConfigMap in the definition's namespace.
type ConfigMapKeyRef struct {
	Name string `json:"name"`
	Key  string `json:"key"`
}

// InstructionsFrom is reserved: the field is in the schema so that its name and shape are fixed, but this release refuses
// a definition that sets it ("not available yet").
type InstructionsFrom struct {
	ConfigMap *ConfigMapKeyRef `json:"configMap,omitempty"`
}

// ResourceList is a CPU and a memory quantity ("100m", "1", "256Mi", "1Gi").
type ResourceList struct {
	CPU    string `json:"cpu,omitempty"`
	Memory string `json:"memory,omitempty"`
}

// Resources are the requests and limits of a container agent. The policy sets defaults and ceilings.
type Resources struct {
	Requests ResourceList `json:"requests,omitzero"`
	Limits   ResourceList `json:"limits,omitzero"`
}

// EnvVar is one plain environment variable of a container agent. There is no way to source one from a Secret or a field.
type EnvVar struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

// ContainerRuntime says which image runs as the agent (ADR 0015). It is the only place an image may be named in a spec.
type ContainerRuntime struct {
	Image     string     `json:"image"`
	Port      int        `json:"port"`
	Env       []EnvVar   `json:"env,omitempty"`
	Resources *Resources `json:"resources,omitempty"`
}

// Runtime says how the agent is made: builtin (the platform builds it from instructions) or container (the platform runs the
// user's digest-pinned image, which speaks A2A).
type Runtime struct {
	Type      string            `json:"type,omitempty"`
	Container *ContainerRuntime `json:"container,omitempty"`
}

// RuntimeType is the effective runtime type: builtin when none is set.
func (s Spec) RuntimeType() string {
	if s.Runtime.Type == "" {
		return RuntimeBuiltin
	}
	return s.Runtime.Type
}

// Spec is the whole builder surface. There is deliberately no field for a model config, image, tool server, egress
// policy reference, namespace, caller, gateway user or budget.
type Spec struct {
	Description      string            `json:"description,omitempty"`
	Model            string            `json:"model"`
	Instructions     string            `json:"instructions,omitempty"`
	InstructionsFrom *InstructionsFrom `json:"instructionsFrom,omitempty"`
	ToolProfile      string            `json:"toolProfile,omitempty"`
	Tools            []string          `json:"tools,omitempty"`
	Knowledge        Knowledge         `json:"knowledge,omitzero"`
	Notify           Notify            `json:"notify,omitzero"`
	Memory           Memory            `json:"memory,omitzero"`
	Skills           []Skill           `json:"skills,omitempty"`
	Egress           Egress            `json:"egress,omitzero"`
	// Suspend keeps the definition accepted and its objects in place, but the agent takes no new work.
	Suspend bool `json:"suspend,omitempty"`
	// Runtime is optional: absent means builtin. ADR 0015.
	Runtime Runtime `json:"runtime,omitzero"`
}

type Condition struct {
	Type               string `json:"type"`
	Status             string `json:"status"`
	Reason             string `json:"reason"`
	Message            string `json:"message,omitempty"`
	ObservedGeneration int64  `json:"observedGeneration,omitempty"`
	LastTransitionTime string `json:"lastTransitionTime,omitempty"`
}

// ObjectRef is the one generic reference to the upstream object, for people who debug.
type ObjectRef struct {
	APIVersion string `json:"apiVersion"`
	Kind       string `json:"kind"`
	Name       string `json:"name"`
}

// Tri is a three-valued fact an adapter reports about its runtime.
type Tri string

const (
	Yes     Tri = "yes"
	No      Tri = "no"
	Unknown Tri = "unknown"
)

// Capabilities is what the runtime adapter reports about the runtime (ADR 0012, "Runtime contract"). A value the adapter
// could not verify is "unknown" (MaxStepSeconds 0), never a guess.
type Capabilities struct {
	Approvals            Tri    `json:"approvals"`            // a tool call can wait for a person's decision
	DurableWaits         Tri    `json:"durableWaits"`         // a wait for input survives a restart of the runtime's workload
	WorkspacePersistence string `json:"workspacePersistence"` // none, snapshot, volume or unknown: what keeps files across a wait
	MaxStepSeconds       int    `json:"maxStepSeconds"`       // the longest single step (a shell command); 0 is unknown
	CancelStopsLoop      Tri    `json:"cancelStopsLoop"`      // a cancel really stops the agent's loop
	PerRunIdentity       string `json:"perRunIdentity"`       // none, session, run or unknown: the granularity of the agent's identity
	// Isolation is how the agent is separated from others: sandbox-per-session, sandboxed-pod or container. Empty is unknown.
	Isolation string `json:"isolation,omitempty"`
}

// Endpoint says where the agent is callable. Protocol and version are data, so that a second protocol needs no new field.
type Endpoint struct {
	Protocol        string `json:"protocol"`
	URL             string `json:"url"`
	ProtocolVersion string `json:"protocolVersion"`
}

// ControllerState is what the controller itself needs to remember between passes. It lives under status.controller, is
// not part of the contract and may change without notice. None of it is secret.
type ControllerState struct {
	KeySecret         string `json:"keySecret"`         // name of the key Secret in use
	KeyFingerprint    string `json:"keyFingerprint"`    // head of the registered key's hash (keys.Fingerprint)
	AppliedGeneration int64  `json:"appliedGeneration"` // generation of the spec whose objects exist (0: none)
	AppliedSpec       string `json:"appliedSpec"`       // that spec as JSON; a string so a merge patch replaces it whole
	GatewayUserID     string `json:"gatewayUserId"`     // opaque: "<namespace>.<name>" today
	ToolServer        string `json:"toolServer"`        // the tool backend the profile resolved to
	// HeldKeyHash is the registered hash of the agent's key while the definition is suspended and its gateway entry is removed
	// (so a leaked key is useless meanwhile); it is registered again on resume, so the same key comes back. A hash is not a
	// secret (it is what the gateway's ConfigMap holds), and the controller never reads Secrets, so status is where it can read it back.
	HeldKeyHash string `json:"heldKeyHash"`
	// AgentStartedAt is when the controller last (re)created the runtime agent, RFC 3339. It rate-limits a suspend and resume loop.
	AgentStartedAt string `json:"agentStartedAt"`
}

// Status is the status contract (ADR 0012, change 5): the public fields below are what products may read; everything
// else is under Controller.
type Status struct {
	ObservedGeneration int64         `json:"observedGeneration"`
	Conditions         []Condition   `json:"conditions"`
	Endpoint           *Endpoint     `json:"endpoint,omitempty"`
	Revision           string        `json:"revision"`
	EffectiveTools     []string      `json:"effectiveTools"`
	EffectiveEgress    []string      `json:"effectiveEgress"`
	Violations         []string      `json:"violations"`
	Capabilities       *Capabilities `json:"capabilities,omitempty"`
	AgentRef           *ObjectRef    `json:"agentRef,omitempty"`
	Budget             *BudgetStatus `json:"budget,omitempty"`

	Controller ControllerState `json:"controller"`
}

// BudgetStatus is what the controller wrote to the key entry of the agent (ADR 0029). Class is the budget class of the entry, "default" when the
// entry has none, or "unknown" when the controller cannot say what the gateway holds (the entry is cut while the definition is suspended, or
// the write failed). It says what was written, not that the gateway enforces it.
type BudgetStatus struct {
	Class string `json:"class"`
}

// Budget class values of BudgetStatus that are not a class name.
const (
	BudgetDefault = "default"
	BudgetUnknown = "unknown"
)

// PublicStatusFields lists the status fields that are part of the contract, besides status.controller.
var PublicStatusFields = []string{"conditions", "observedGeneration", "endpoint", "revision", "effectiveTools", "effectiveEgress", "violations", "capabilities", "agentRef", "budget"}

type AgentDefinition struct {
	APIVersion string     `json:"apiVersion"`
	Kind       string     `json:"kind"`
	Metadata   ObjectMeta `json:"metadata"`
	Spec       Spec       `json:"spec"`
	Status     Status     `json:"status"`
}

// FromObject decodes an unstructured object. Unknown fields are ignored here (the CRD schema prunes them); the
// controller only ever reads the fields above.
func FromObject(o map[string]any) (*AgentDefinition, error) {
	b, err := json.Marshal(o)
	if err != nil {
		return nil, err
	}
	var d AgentDefinition
	if err := json.Unmarshal(b, &d); err != nil {
		return nil, fmt.Errorf("decode AgentDefinition: %w", err)
	}
	if d.Kind != Kind || d.APIVersion != APIVersion {
		return nil, fmt.Errorf("object is %s %s, not %s %s", d.APIVersion, d.Kind, APIVersion, Kind)
	}
	return &d, nil
}

// Deleting reports whether deletion was requested.
func (d *AgentDefinition) Deleting() bool { return d.Metadata.DeletionTimestamp != "" }

// HasFinalizer reports whether f is set.
func (d *AgentDefinition) HasFinalizer(f string) bool {
	for _, x := range d.Metadata.Finalizers {
		if x == f {
			return true
		}
	}
	return false
}

// Condition returns the condition of type t (zero value when absent).
func (s Status) Condition(t string) Condition {
	for _, c := range s.Conditions {
		if c.Type == t {
			return c
		}
	}
	return Condition{}
}

// SetCondition sets c. LastTransitionTime moves only when the status value changes; now is the time to use then.
func (s *Status) SetCondition(c Condition, now string, generation int64) {
	c.ObservedGeneration = generation
	for i, old := range s.Conditions {
		if old.Type != c.Type {
			continue
		}
		if old.Status == c.Status && old.LastTransitionTime != "" {
			c.LastTransitionTime = old.LastTransitionTime
		} else {
			c.LastTransitionTime = now
		}
		s.Conditions[i] = c
		return
	}
	c.LastTransitionTime = now
	s.Conditions = append(s.Conditions, c)
}

// Patch returns the merge patch body for the status subresource. Lists are always present (empty, never null), so
// that a merge patch clears old values.
func (s Status) Patch() map[string]any {
	if s.Conditions == nil {
		s.Conditions = []Condition{}
	}
	if s.EffectiveTools == nil {
		s.EffectiveTools = []string{}
	}
	if s.EffectiveEgress == nil {
		s.EffectiveEgress = []string{}
	}
	if s.Violations == nil {
		s.Violations = []string{}
	}
	b, _ := json.Marshal(s)
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	for _, k := range []string{"endpoint", "agentRef", "capabilities", "budget"} {
		if _, ok := m[k]; !ok {
			m[k] = nil // merge patch: null removes the field
		}
	}
	return map[string]any{"status": m}
}
