// Package yamlout writes an AgentDefinition as YAML text for the read-only YAML view. It writes only what this API
// knows (a fixed set of fields), so it needs no general YAML library.
package yamlout

import (
	"bytes"
	"encoding/json"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/openagentix/openagentix/services/console/internal/model"
)

// Meta is the part of metadata that is shown.
type Meta struct {
	Name, Namespace, ResourceVersion, UID, CreationTimestamp string
	Generation                                               int64
}

var plain = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_./@-]*$`)
var reserved = map[string]bool{"true": true, "false": true, "null": true, "yes": true, "no": true, "on": true, "off": true, "y": true, "n": true, "~": true}

// Scalar renders a string value, quoted only when YAML would read it as something else.
func Scalar(s string) string {
	if s == "" {
		return `""`
	}
	if plain.MatchString(s) && !reserved[strings.ToLower(s)] {
		return s
	}
	// a JSON string is a valid YAML double-quoted scalar, and it escapes every character a plain or block scalar could not carry
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(s)
	return strings.TrimSuffix(buf.String(), "\n")
}

func flow(items []string) string {
	q := make([]string, len(items))
	for i, s := range items {
		q[i] = Scalar(s)
	}
	return "[" + strings.Join(q, ", ") + "]"
}

type w struct{ b strings.Builder }

func (w *w) line(indent int, f string, a ...any) {
	w.b.WriteString(strings.Repeat(" ", indent))
	if len(a) > 0 {
		w.b.WriteString(sprintf(f, a...))
	} else {
		w.b.WriteString(f)
	}
	w.b.WriteByte('\n')
}

func sprintf(f string, a ...any) string {
	var out strings.Builder
	i := 0
	for j := 0; j < len(f); j++ {
		if f[j] == '%' && j+1 < len(f) && f[j+1] == 's' && i < len(a) {
			out.WriteString(a[i].(string))
			i++
			j++
			continue
		}
		out.WriteByte(f[j])
	}
	return out.String()
}

func (w *w) list(indent int, key string, items []string) {
	if len(items) == 0 {
		return
	}
	w.line(indent, "%s:", key)
	for _, it := range items {
		w.line(indent+2, "- %s", Scalar(it))
	}
}

// blockSafe reports whether a text can be written as a block scalar and read back unchanged: more than one line, no
// control character (a block scalar cannot carry one), no carriage return or Unicode line break, no line of only
// whitespace and not only newlines. Anything else is written as a double-quoted scalar with escapes.
func blockSafe(text string) bool {
	if !strings.Contains(text, "\n") || strings.Trim(text, "\n") == "" {
		return false
	}
	for _, r := range text {
		if r == '\n' || r == '\t' {
			continue
		}
		if r < 0x20 || r == 0x7f || r == 0x85 || r == 0x2028 || r == 0x2029 || r == 0xFEFF || r == 0xFFFD {
			return false
		}
	}
	for _, l := range strings.Split(text, "\n") {
		if l != "" && strings.TrimSpace(l) == "" {
			return false
		}
	}
	return true
}

func (w *w) block(indent int, key, text string) {
	if !blockSafe(text) {
		w.line(indent, "%s: %s", key, Scalar(text))
		return
	}
	mark := "|"
	switch {
	case !strings.HasSuffix(text, "\n"):
		mark = "|-"
	case strings.HasSuffix(text, "\n\n"):
		mark = "|+"
	}
	if strings.HasPrefix(text, " ") || strings.HasPrefix(text, "\n") || strings.HasPrefix(text, "\t") {
		mark += "2" // the first line decides the indentation unless it is told
	}
	w.line(indent, "%s: %s", key, mark)
	for _, l := range strings.Split(strings.TrimSuffix(text, "\n"), "\n") {
		if l == "" {
			w.b.WriteByte('\n')
			continue
		}
		w.line(indent+2, "%s", l)
	}
}

func (w *w) feature(indent int, key, listKey string, f *model.Feature) {
	if f == nil {
		return
	}
	w.line(indent, "%s:", key)
	w.line(indent+2, "enabled: %s", strconv.FormatBool(f.Enabled))
	items := f.Collections
	if listKey == "destinations" {
		items = f.Destinations
	}
	w.list(indent+2, listKey, items)
}

// value writes a nested value of the generic part of the spec (runtime): maps with their keys in order, lists, and scalars.
func (w *w) value(indent int, key string, v any) {
	switch x := v.(type) {
	case map[string]any:
		if len(x) == 0 {
			w.line(indent, "%s: {}", key)
			return
		}
		w.line(indent, "%s:", key)
		w.mapBody(indent+2, x)
	case []any:
		if len(x) == 0 {
			w.line(indent, "%s: []", key)
			return
		}
		w.line(indent, "%s:", key)
		for _, it := range x {
			if m, ok := it.(map[string]any); ok && len(m) > 0 {
				w.itemMap(indent+2, m)
				continue
			}
			w.line(indent+2, "- %s", scalarOf(it))
		}
	default:
		w.line(indent, "%s: %s", key, scalarOf(v))
	}
}

func (w *w) mapBody(indent int, m map[string]any) {
	for _, k := range sortedKeys(m) {
		w.value(indent, Scalar(k), m[k])
	}
}

// itemMap writes one list item that is a map: the first key on the dash line, the rest under it.
func (o *w) itemMap(indent int, m map[string]any) {
	var sub w
	sub.mapBody(indent+2, m)
	text := sub.b.String()
	o.b.WriteString(strings.Repeat(" ", indent) + "- " + strings.TrimLeft(text, " "))
}

func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func scalarOf(v any) string {
	switch x := v.(type) {
	case string:
		return Scalar(x)
	case bool:
		return strconv.FormatBool(x)
	case float64:
		return strconv.FormatFloat(x, 'f', -1, 64)
	case nil:
		return "null"
	}
	b, _ := json.Marshal(v)
	return Scalar(string(b))
}

// Render writes the definition. status.controller (internal bookkeeping) is left out. status may be nil (a draft).
func Render(m Meta, spec model.Spec, st *model.Status) string {
	var o w
	o.line(0, "apiVersion: %s", model.APIVersion)
	o.line(0, "kind: %s", model.Kind)
	o.line(0, "metadata:")
	o.line(2, "name: %s", Scalar(m.Name))
	if m.Namespace != "" {
		o.line(2, "namespace: %s", Scalar(m.Namespace))
	}
	if m.Generation > 0 {
		o.line(2, "generation: %s", strconv.FormatInt(m.Generation, 10))
	}
	if m.ResourceVersion != "" {
		o.line(2, "resourceVersion: %s", Scalar(m.ResourceVersion))
	}
	if m.CreationTimestamp != "" {
		o.line(2, "creationTimestamp: %s", Scalar(m.CreationTimestamp))
	}
	o.line(0, "spec:")
	if spec.Description != "" {
		o.line(2, "description: %s", Scalar(spec.Description))
	}
	o.line(2, "model: %s", Scalar(spec.Model))
	if spec.Instructions != "" || spec.Runtime == nil {
		o.block(2, "instructions", spec.Instructions)
	}
	if spec.ToolProfile != "" {
		o.line(2, "toolProfile: %s", Scalar(spec.ToolProfile))
	}
	o.list(2, "tools", spec.Tools)
	o.feature(2, "knowledge", "collections", spec.Knowledge)
	o.feature(2, "notify", "destinations", spec.Notify)
	if spec.Memory != nil {
		o.line(2, "memory:")
		o.line(4, "enabled: %s", strconv.FormatBool(spec.Memory.Enabled))
		if spec.Memory.TTLDays > 0 {
			o.line(4, "ttlDays: %s", strconv.Itoa(spec.Memory.TTLDays))
		}
	}
	if len(spec.Skills) > 0 {
		o.line(2, "skills:")
		for _, sk := range spec.Skills {
			o.line(4, "- name: %s", Scalar(sk.Name))
			if sk.Version != "" {
				o.line(6, "version: %s", Scalar(sk.Version))
			}
		}
	}
	if spec.Egress != nil && len(spec.Egress.Allow) > 0 {
		o.line(2, "egress:")
		o.list(4, "allow", spec.Egress.Allow)
	}
	if spec.Suspend {
		o.line(2, "suspend: true")
	}
	if spec.Runtime != nil {
		o.value(2, "runtime", spec.Runtime)
	}
	if st != nil {
		o.line(0, "status:")
		o.line(2, "observedGeneration: %s", strconv.FormatInt(st.ObservedGeneration, 10))
		if len(st.Conditions) > 0 {
			o.line(2, "conditions:")
			for _, c := range st.Conditions {
				o.line(4, "- type: %s", Scalar(c.Type))
				o.line(6, "status: %s", Scalar(c.Status))
				o.line(6, "reason: %s", Scalar(c.Reason))
				if c.Message != "" {
					o.line(6, "message: %s", Scalar(c.Message))
				}
				if c.LastTransitionTime != "" {
					o.line(6, "lastTransitionTime: %s", Scalar(c.LastTransitionTime))
				}
			}
		}
		if st.AgentRef != nil {
			o.line(2, "agentRef:")
			o.line(4, "apiVersion: %s", Scalar(st.AgentRef.APIVersion))
			o.line(4, "kind: %s", Scalar(st.AgentRef.Kind))
			o.line(4, "name: %s", Scalar(st.AgentRef.Name))
		}
		if e := st.Endpoint; e != nil {
			o.line(2, "endpoint:")
			o.line(4, "protocol: %s", Scalar(e.Protocol))
			o.line(4, "url: %s", Scalar(e.URL))
			if e.ProtocolVersion != "" {
				o.line(4, "protocolVersion: %s", Scalar(e.ProtocolVersion))
			}
		}
		if st.Revision != "" {
			o.line(2, "revision: %s", Scalar(st.Revision))
		}
		o.list(2, "effectiveTools", st.EffectiveTools)
		o.list(2, "effectiveEgress", st.EffectiveEgress)
		o.list(2, "violations", st.Violations)
	}
	return o.b.String()
}
