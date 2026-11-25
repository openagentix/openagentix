// Package plan turns an accepted definition into a Plan: the platform-level facts an agent needs (final prompt, tools,
// skills with digests, egress, memory), with no upstream vocabulary. Runtime adapters translate a Plan into their own
// objects and derive their own names. Validation happens before: Build assumes the definition passed package policy.
package plan

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"regexp"
	"slices"
	"strings"

	"github.com/openagentix/openagentix/services/control-plane/internal/api"
	"github.com/openagentix/openagentix/services/control-plane/internal/catalog"
)

var hex8 = regexp.MustCompile(`^[0-9a-f]{8}`)

// KeySecretName is "<name>-virtual-key-" and the first 8 hex characters of the definition's UID without dashes. A name
// that already exists therefore belongs to this very definition (a definition that is deleted and made again has a new
// UID), so the controller may replace it without reading it.
func KeySecretName(name, uid string) (string, error) {
	h := hex8.FindString(strings.ReplaceAll(strings.ToLower(uid), "-", ""))
	if h == "" {
		return "", fmt.Errorf("definition %s has no usable UID (need 8 hex characters), cannot name its key Secret", name)
	}
	return name + "-virtual-key-" + h, nil
}

type Skill struct{ Name, Ref string }

type Memory struct {
	TTLDays int // 0: the runtime's default
}

// Plan is the platform-level description of one agent. It names no upstream object: each adapter derives the names of its
// own objects from Name and Namespace, and the tools adapter's reference to what serves a profile is opaque (ToolBackend).
type Plan struct {
	Name           string
	Namespace      string // the definition's namespace
	Description    string
	Model          string
	GatewayBaseURL string
	// GatewayUserID is opaque to everyone but the gateway adapter: "<namespace>.<name>" today (ADR 0012, change 1).
	GatewayUserID string
	KeySecret     string
	// KeyFingerprint is a non-secret fingerprint of the registered key hash. A runtime adapter puts it on the objects that
	// must be recreated when the key is replaced. Empty until the key step has run.
	KeyFingerprint string
	Prompt         string
	ToolBackend    string // "" when the agent has no tools; opaque, resolved by the tools adapter from the profile
	Tools          []string
	Skills         []Skill
	Egress         []string
	Memory         *Memory
	// Suspended: the agent stays but takes no new work (spec.suspend, or the operator's policy suspendAll).
	Suspended bool
	// Labels holds the reserved labels team and project, copied from the definition (informational only).
	Labels map[string]string
	// Revision is a stable hash of what was applied (see Revision).
	Revision string
	// RuntimeType is the effective runtime type (api.RuntimeBuiltin or api.RuntimeContainer).
	RuntimeType string
	// Container is set for a container agent only. The workload namespace is not here: the runtime adapter owns it.
	Container *ContainerSpec
}

// ContainerSpec is the user's image as the plan carries it: copied from the spec, with the resources resolved against the
// policy (requests default to the policy defaults, limits are always set) and the env sorted by name.
type ContainerSpec struct {
	Image     string
	Port      int
	Env       []api.EnvVar
	Resources api.Resources
}

type containerHash struct {
	Image     string
	Port      int
	Env       []api.EnvVar
	Resources api.Resources
}

// GatewayUser is the opaque gateway user id of a definition: "<namespace>.<name>". A dot cannot occur in a namespace or
// in a name, so two definitions never share one, and the id never equals a chart agent's (a plain name).
func GatewayUser(namespace, name string) string { return namespace + "." + name }

// Build composes the plan. The prompt follows the chart: with no addition the instructions pass through unchanged,
// otherwise each part is trimmed and joined by a newline, in the order knowledge, notify, memory. pol may be nil.
func Build(d *api.AgentDefinition, c *catalog.Catalog, tr catalog.ToolResolver, pol *catalog.Policy) (Plan, error) {
	s := d.Spec
	if d.Metadata.Namespace == "" {
		return Plan{}, fmt.Errorf("definition %s has no namespace", d.Metadata.Name)
	}
	secret, err := KeySecretName(d.Metadata.Name, d.Metadata.UID)
	if err != nil {
		return Plan{}, err
	}
	if s.RuntimeType() == api.RuntimeContainer {
		return buildContainer(d, c, pol, secret)
	}
	p := Plan{
		RuntimeType: api.RuntimeBuiltin,
		Name:        d.Metadata.Name, Namespace: d.Metadata.Namespace, Description: s.Description, Model: s.Model,
		GatewayBaseURL: c.GatewayBaseURL, GatewayUserID: GatewayUser(d.Metadata.Namespace, d.Metadata.Name),
		KeySecret: secret,
		Prompt:    s.Instructions,
		Egress:    slices.Clone(s.Egress.Allow),
		Suspended: s.Suspend || (pol != nil && pol.SuspendAll),
	}
	for _, k := range []string{api.LabelTeam, api.LabelProject} {
		if v, ok := d.Metadata.Labels[k]; ok && v != "" {
			if p.Labels == nil {
				p.Labels = map[string]string{}
			}
			p.Labels[k] = v
		}
	}
	add := func(extra string) { p.Prompt = strings.TrimSpace(p.Prompt) + "\n" + strings.TrimSpace(extra) }
	tools := slices.Clone(s.Tools)
	extend := func(names []string) {
		for _, n := range names {
			if !slices.Contains(tools, n) {
				tools = append(tools, n)
			}
		}
	}
	if s.Knowledge.Enabled {
		add(c.Knowledge.Prompt)
		extend(c.Knowledge.Tools)
	}
	if s.Notify.Enabled {
		add(c.Notify.Prompt)
		extend(c.Notify.Tools)
	}
	if s.Memory.Enabled {
		add(c.Memory.Prompt)
		p.Memory = &Memory{TTLDays: s.Memory.TTLDays}
	}
	p.Tools = tools
	if len(tools) > 0 {
		if s.ToolProfile == "" {
			return Plan{}, fmt.Errorf("definition %s has tools but no toolProfile: the shared tool server is not an option", d.Metadata.Name)
		}
		prof, ok := tr.Profile(s.ToolProfile)
		if !ok {
			return Plan{}, fmt.Errorf("definition %s names toolProfile %q, which the tools adapter does not know", d.Metadata.Name, s.ToolProfile)
		}
		p.ToolBackend = prof.Backend
	}
	for _, sk := range s.Skills {
		p.Skills = append(p.Skills, Skill{Name: sk.Name, Ref: c.Skills[sk.Name]})
	}
	p.Revision = revision(s, p, c.Memory.DefaultTTLDays)
	return p, nil
}

// buildContainer is Build for a container agent: no prompt, no tools, no skills (the policy refused them), so nothing is resolved.
func buildContainer(d *api.AgentDefinition, c *catalog.Catalog, pol *catalog.Policy, secret string) (Plan, error) {
	s := d.Spec
	cr := s.Runtime.Container
	if cr == nil {
		return Plan{}, fmt.Errorf("definition %s has runtime type container but no runtime.container block", d.Metadata.Name)
	}
	if pol == nil {
		pol = &catalog.Policy{}
	}
	p := Plan{
		RuntimeType: api.RuntimeContainer,
		Name:        d.Metadata.Name, Namespace: d.Metadata.Namespace, Description: s.Description, Model: s.Model,
		GatewayBaseURL: c.GatewayBaseURL, GatewayUserID: GatewayUser(d.Metadata.Namespace, d.Metadata.Name),
		KeySecret: secret,
		Egress:    slices.Clone(s.Egress.Allow),
		Suspended: s.Suspend || pol.SuspendAll,
		Container: &ContainerSpec{Image: cr.Image, Port: cr.Port, Env: slices.Clone(cr.Env), Resources: pol.ResolveContainerResources(cr.Resources)},
	}
	slices.SortFunc(p.Container.Env, func(a, b api.EnvVar) int { return strings.Compare(a.Name, b.Name) })
	for _, k := range []string{api.LabelTeam, api.LabelProject} {
		if v, ok := d.Metadata.Labels[k]; ok && v != "" {
			if p.Labels == nil {
				p.Labels = map[string]string{}
			}
			p.Labels[k] = v
		}
	}
	p.Revision = revision(s, p, c.Memory.DefaultTTLDays)
	return p, nil
}

// revision is the first 12 hex characters of the SHA-256 of a canonical encoding of what was applied: the final prompt,
// the model, the tool profile and the effective tools, the skills with their digests, the knowledge, notify and memory
// settings, and the egress. Lists are sets, so they are sorted; the encoding is JSON of a fixed struct, never of a map.
// What it leaves out on purpose: description, labels, suspend, namespace and name (they are not behaviour), and the
// runtime adapter's own settings (image, worker pool), which the plan does not see.
func revision(s api.Spec, p Plan, defaultTTL int) string {
	sorted := func(l []string) []string {
		out := slices.Clone(l)
		if out == nil {
			out = []string{}
		}
		slices.Sort(out)
		return out
	}
	type skill struct{ Name, Ref string }
	in := struct {
		V           int
		Model       string
		ToolProfile string
		Prompt      string
		Tools       []string
		Skills      []skill
		Knowledge   struct {
			On          bool
			Collections []string
		}
		Notify struct {
			On           bool
			Destinations []string
		}
		MemoryOn  bool
		MemoryTTL int
		Egress    []string
		// Runtime and Container are in the hash for a container agent only (both omitted otherwise), so that a builtin
		// revision is the same as it was before the container runtime existed.
		Runtime   string         `json:",omitempty"`
		Container *containerHash `json:",omitempty"`
	}{V: 1, Model: p.Model, ToolProfile: s.ToolProfile, Prompt: p.Prompt, Tools: sorted(p.Tools), Egress: sorted(p.Egress), Skills: []skill{}}
	for _, sk := range p.Skills {
		in.Skills = append(in.Skills, skill{sk.Name, sk.Ref})
	}
	slices.SortFunc(in.Skills, func(a, b skill) int { return strings.Compare(a.Name, b.Name) })
	in.Knowledge.On, in.Knowledge.Collections = s.Knowledge.Enabled, sorted(s.Knowledge.Collections)
	in.Notify.On, in.Notify.Destinations = s.Notify.Enabled, sorted(s.Notify.Destinations)
	if s.Memory.Enabled {
		in.MemoryOn, in.MemoryTTL = true, s.Memory.TTLDays
		if in.MemoryTTL == 0 {
			in.MemoryTTL = defaultTTL
		}
	}
	if p.Container != nil {
		in.Runtime = p.RuntimeType
		env := slices.Clone(p.Container.Env)
		if env == nil {
			env = []api.EnvVar{}
		}
		in.Container = &containerHash{Image: p.Container.Image, Port: p.Container.Port, Env: env, Resources: p.Container.Resources}
	}
	b, _ := json.Marshal(in)
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])[:12]
}

// Readiness is what a runtime reports about a running agent.
type Readiness struct {
	Ready   bool
	Reason  string // one CamelCase word
	Message string // short, from the runtime's own status; no secret can be in it
}
