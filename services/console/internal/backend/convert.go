package backend

import (
	"slices"
	"strings"

	"github.com/openagentix/openagentix/services/console/internal/model"
	"github.com/openagentix/openagentix/services/console/internal/yamlout"
)

// Meta is the metadata the console reads from an object.
type Meta struct {
	Name              string            `json:"name"`
	Namespace         string            `json:"namespace"`
	UID               string            `json:"uid"`
	Generation        int64             `json:"generation"`
	ResourceVersion   string            `json:"resourceVersion"`
	CreationTimestamp string            `json:"creationTimestamp"`
	DeletionTimestamp string            `json:"deletionTimestamp"`
	Labels            map[string]string `json:"labels"`
}

// Definition is an AgentDefinition as the console holds it.
type Definition struct {
	Meta   Meta         `json:"metadata"`
	Spec   model.Spec   `json:"spec"`
	Status model.Status `json:"status"`
	// Unmanaged are the keys of the stored spec the console has no control for (see model.Detail.Unmanaged).
	Unmanaged []string `json:"-"`
}

func nz[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

func latest(d Definition) string {
	t := d.Meta.CreationTimestamp
	for _, c := range d.Status.Conditions {
		if c.LastTransitionTime > t {
			t = c.LastTransitionTime
		}
	}
	return t
}

// BuiltAgent is the registry row of a definition.
func BuiltAgent(d Definition) model.Agent {
	deleting := d.Meta.DeletionTimestamp != ""
	st, reason := model.StateOf(d.Status.Conditions, deleting, d.Spec.Suspend)
	if st == model.StateRefused && len(d.Status.Violations) > 0 {
		reason = d.Status.Violations[0]
	}
	s := d.Spec
	var mem *model.Memory
	if s.Memory != nil && s.Memory.Enabled {
		mem = s.Memory
	}
	n := 0
	if s.Egress != nil {
		n = len(s.Egress.Allow)
	}
	skills := []string{}
	for _, sk := range s.Skills {
		skills = append(skills, sk.Name)
	}
	rt, iso := "builtin", ""
	if r, _ := s.Runtime["type"].(string); r != "" {
		rt = r
	}
	if rt == "container" {
		iso, _ = d.Status.Capabilities["isolation"].(string)
	}
	return model.Agent{
		RuntimeType: rt, Isolation: iso,
		Name: d.Meta.Name, Namespace: d.Meta.Namespace, Source: "built", Description: s.Description, Model: s.Model,
		ToolProfile: s.ToolProfile, ToolsCount: len(s.Tools), Knowledge: s.Knowledge != nil && s.Knowledge.Enabled, Notify: s.Notify != nil && s.Notify.Enabled, Memory: mem,
		Suspended: s.Suspend, Team: d.Meta.Labels["openagentix.io/team"], Project: d.Meta.Labels["openagentix.io/project"],
		Skills: skills, EgressCount: n, EffectiveTools: nz(d.Status.EffectiveTools), EffectiveEgress: nz(d.Status.EffectiveEgress), State: st, StateReason: reason, Deleting: deleting,
		Conditions: nz(d.Status.Conditions), Generation: d.Meta.Generation, Updated: latest(d), ResourceVersion: d.Meta.ResourceVersion,
	}
}

// BuiltDetail is the full view of a definition: the row, spec, status and YAML.
func BuiltDetail(d Definition) model.Detail {
	st := d.Status
	st.Conditions, st.EffectiveTools, st.EffectiveEgress, st.Violations = nz(st.Conditions), nz(st.EffectiveTools), nz(st.EffectiveEgress), nz(st.Violations)
	spec := d.Spec
	det := model.Detail{
		Agent: BuiltAgent(d), Spec: &spec, Status: &st,
		YAML: yamlout.Render(yamlout.Meta{Name: d.Meta.Name, Namespace: d.Meta.Namespace, Generation: d.Meta.Generation,
			ResourceVersion: d.Meta.ResourceVersion, CreationTimestamp: d.Meta.CreationTimestamp}, d.Spec, &st),
		Objects: ownedObjects(d), Unmanaged: d.Unmanaged,
	}
	return det
}

// ownedObjects lists what the runtime adapter makes for a definition. Only the Agent is named by the public status
// (agentRef); the others are listed by kind, because the console does not read them (and so does not invent their names).
// Nothing here reads status.controller: that block is internal, shown opaque and relied on by nothing.
func ownedObjects(d Definition) []model.OwnedObject {
	var out []model.OwnedObject
	for _, k := range []string{"ModelConfig", "Harness", "AgentTemplate", "EgressPolicy"} {
		o := model.OwnedObject{Kind: k, Note: "made by the runtime adapter; not read by the console"}
		if k == "EgressPolicy" {
			o.Note = "only when the definition lists egress origins; not read by the console"
		}
		out = append(out, o)
	}
	if r := d.Status.AgentRef; r != nil {
		a := model.OwnedObject{Kind: r.Kind, Name: r.Name}
		for _, c := range d.Status.Conditions {
			if c.Type == "Ready" {
				a.State = map[string]string{"True": "ready", "False": "pending"}[c.Status]
				if a.State == "" {
					a.State = "pending"
				}
			}
		}
		out = append(out[:3:3], append([]model.OwnedObject{a}, out[3:]...)...)
	}
	return out
}

// Chart is what could be read about a chart-managed agent.
type Chart struct {
	Name, Namespace, Created string
	Conditions               []model.Condition
	TemplateName, HarnessRef string
	Description, Prompt      string
	ModelConfigName          string
	Model                    string
	ToolServer               string
	Tools                    []string
	Skills                   []string
	MemoryTTL                int
	HasMemory                bool
	Resource                 string
}

// ChartAgent derives the row for a chart-managed agent. The catalog tells which tool server is which profile and which
// tools belong to knowledge and notify; without it those fields stay empty.
func ChartAgent(c Chart, profiles map[string]string, knowledge, notify []string) (model.Agent, *model.Spec) {
	st, reason := model.StateOf(c.Conditions, false, false)
	prof := ""
	if c.ToolServer != "" {
		prof = profiles[c.ToolServer]
	}
	has := func(names []string) bool {
		return len(names) > 0 && slices.ContainsFunc(names, func(n string) bool { return slices.Contains(c.Tools, n) })
	}
	spec := &model.Spec{Description: c.Description, Model: c.Model, Instructions: c.Prompt, ToolProfile: prof, Tools: c.Tools}
	if has(knowledge) {
		spec.Knowledge = &model.Feature{Enabled: true}
	}
	if has(notify) {
		spec.Notify = &model.Feature{Enabled: true}
	}
	for _, n := range c.Skills {
		spec.Skills = append(spec.Skills, model.Skill{Name: n})
	}
	var mem *model.Memory
	if c.HasMemory {
		mem = &model.Memory{Enabled: true, TTLDays: c.MemoryTTL}
		spec.Memory = mem
	}
	upd := c.Created
	for _, cd := range c.Conditions {
		if cd.LastTransitionTime > upd {
			upd = cd.LastTransitionTime
		}
	}
	a := model.Agent{Name: c.Name, Namespace: c.Namespace, Source: "chart", Description: c.Description, Model: c.Model, ToolProfile: prof,
		ToolsCount: len(c.Tools), Knowledge: has(knowledge), Notify: has(notify), Memory: mem, Skills: nz(c.Skills), EffectiveTools: []string{}, EffectiveEgress: []string{}, State: st, StateReason: reason,
		Conditions: nz(c.Conditions), Updated: upd}
	if c.ToolServer != "" && prof == "" && strings.HasPrefix(c.ToolServer, "toolhive-vmcp") {
		a.ToolProfile = ""
	}
	return a, spec
}
