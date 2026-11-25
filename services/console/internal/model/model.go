// Package model holds the JSON shapes of the console API. The web app has the same shapes by hand in
// console/src/lib/types.ts; keep the two in step.
package model

import (
	"encoding/json"
	"regexp"
)

const (
	Group      = "openagentix.io"
	Version    = "v1alpha1"
	Kind       = "AgentDefinition"
	APIVersion = Group + "/" + Version
	LabelDef   = "openagentix.io/agent-definition"

	MaxName = 40
)

var NameRE = regexp.MustCompile(`^[a-z]([-a-z0-9]*[a-z0-9])?$`)

type Memory struct {
	Enabled bool `json:"enabled"`
	TTLDays int  `json:"ttlDays,omitempty"`
}

// Feature is knowledge and notify (ADR 0012): the lists are planned kinds and may be empty for now.
type Feature struct {
	Enabled      bool     `json:"enabled"`
	Collections  []string `json:"collections,omitempty"`
	Destinations []string `json:"destinations,omitempty"`
}

// Skill is a catalog skill by name, with an optional version.
type Skill struct {
	Name    string `json:"name"`
	Version string `json:"version,omitempty"`
}

type Egress struct {
	Allow []string `json:"allow,omitempty"`
}

// Spec is the builder surface of ADR 0007, as the CRD has it.
type Spec struct {
	Description  string   `json:"description,omitempty"`
	Model        string   `json:"model"`
	Instructions string   `json:"instructions"`
	ToolProfile  string   `json:"toolProfile,omitempty"`
	Tools        []string `json:"tools,omitempty"`
	Knowledge    *Feature `json:"knowledge,omitempty"`
	Notify       *Feature `json:"notify,omitempty"`
	Memory       *Memory  `json:"memory,omitempty"`
	Skills       []Skill  `json:"skills,omitempty"`
	Egress       *Egress  `json:"egress,omitempty"`
	Suspend      bool     `json:"suspend,omitempty"`
}

type Condition struct {
	Type               string `json:"type"`
	Status             string `json:"status"`
	Reason             string `json:"reason"`
	Message            string `json:"message,omitempty"`
	ObservedGeneration int64  `json:"observedGeneration,omitempty"`
	LastTransitionTime string `json:"lastTransitionTime,omitempty"`
}

type ObjectRef struct {
	APIVersion string `json:"apiVersion"`
	Kind       string `json:"kind"`
	Name       string `json:"name"`
}

// Endpoint is where a Ready agent can be called (status contract of ADR 0012).
type Endpoint struct {
	Protocol        string `json:"protocol,omitempty"`
	URL             string `json:"url,omitempty"`
	ProtocolVersion string `json:"protocolVersion,omitempty"`
}

// Status is the public status contract: conditions (Accepted and Ready are the contract; KeyReady, Applied and Synced are
// informational), observedGeneration, endpoint, revision, effectiveTools, effectiveEgress, violations, capabilities and
// agentRef. Everything else is under Controller, which is internal and may change without notice: the console shows it
// in a collapsed section and depends on none of it.
type Status struct {
	ObservedGeneration int64          `json:"observedGeneration"`
	Conditions         []Condition    `json:"conditions"`
	Endpoint           *Endpoint      `json:"endpoint,omitempty"`
	Revision           string         `json:"revision,omitempty"`
	EffectiveTools     []string       `json:"effectiveTools"`
	EffectiveEgress    []string       `json:"effectiveEgress"`
	Violations         []string       `json:"violations"`
	Capabilities       map[string]any `json:"capabilities,omitempty"`
	AgentRef           *ObjectRef     `json:"agentRef,omitempty"`
	Controller         map[string]any `json:"controller,omitempty"`
}

// State is the one word of the status badge (UI-SPEC section 7).
type State string

const (
	StateReady   State = "ready"
	StatePending State = "pending"
	StateRefused State = "refused"
	StateError   State = "error"
	StatePaused  State = "paused"
)

// Agent is one row of the registry and the head of the detail.
type Agent struct {
	Name        string   `json:"name"`
	Namespace   string   `json:"namespace"`
	Source      string   `json:"source"` // built | chart
	Description string   `json:"description"`
	Model       string   `json:"model"`
	ToolProfile string   `json:"toolProfile"`
	ToolsCount  int      `json:"toolsCount"`
	Knowledge   bool     `json:"knowledge"`
	Notify      bool     `json:"notify"`
	Memory      *Memory  `json:"memory,omitempty"`
	Suspended   bool     `json:"suspended"`
	Team        string   `json:"team,omitempty"`
	Project     string   `json:"project,omitempty"`
	Skills      []string `json:"skills"`
	EgressCount int      `json:"egressCount"`
	// EffectiveTools and EffectiveEgress are status.effectiveTools and status.effectiveEgress: what the controller
	// really gave the agent. Empty for a chart agent (the console reads no such status for it).
	EffectiveTools  []string    `json:"effectiveTools"`
	EffectiveEgress []string    `json:"effectiveEgress"`
	State           State       `json:"state"`
	StateReason     string      `json:"stateReason"`
	Deleting        bool        `json:"deleting"`
	Conditions      []Condition `json:"conditions"`
	Generation      int64       `json:"generation"`
	Updated         string      `json:"updated"`
	ResourceVersion string      `json:"resourceVersion,omitempty"`
}

type AgentList struct {
	Items    []Agent  `json:"items"`
	Used     int      `json:"used"` // built definitions, the count maxAgents applies to
	Warnings []string `json:"warnings"`
	// Truncated is true when the cluster holds more objects than the console reads; Cap is how many it read of each kind.
	Truncated bool `json:"truncated"`
	Cap       int  `json:"cap"`
}

// Detail is GET /agents/{name}.
type Detail struct {
	Agent
	ReadOnly bool            `json:"readOnly"`
	Spec     *Spec           `json:"spec,omitempty"` // built agents
	Status   *Status         `json:"status,omitempty"`
	YAML     string          `json:"yaml"`
	Chart    json.RawMessage `json:"chart,omitempty"` // chart agents: what could be read of their runtime objects
	Objects  []OwnedObject   `json:"objects"`
	// Unmanaged lists the spec fields the stored object has and the console has no control for (instructionsFrom, or a
	// field a later release added). A save keeps them as they are.
	Unmanaged []string `json:"unmanaged,omitempty"`
}

// OwnedObject is a line of the Deploy tab.
type OwnedObject struct {
	Kind  string `json:"kind"`
	Name  string `json:"name,omitempty"`
	State string `json:"state,omitempty"`
	Note  string `json:"note,omitempty"`
}

// WriteRequest is the body of create and update.
type WriteRequest struct {
	Name            string `json:"name"`
	ResourceVersion string `json:"resourceVersion,omitempty"`
	Spec            Spec   `json:"spec"`
}

type SchemaResult struct {
	OK      bool     `json:"ok"`
	Skipped bool     `json:"skipped"` // no name yet, so nothing was sent to the API server
	Errors  []string `json:"errors"`
}

type Prediction struct {
	Field   string `json:"field"`
	Message string `json:"message"`
}

type ValidateResult struct {
	Schema     SchemaResult `json:"schema"`
	Predicted  []Prediction `json:"predicted"`
	Prediction bool         `json:"prediction"`
	Note       string       `json:"note"`
}

const PredictionNote = "These are predictions from the console's small rule set. The controller's status.violations after saving are the authority."
