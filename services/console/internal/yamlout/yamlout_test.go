package yamlout

import (
	"gopkg.in/yaml.v3"
	"strings"
	"testing"

	"github.com/openagentix/openagentix/services/console/internal/model"
)

func TestScalarQuoting(t *testing.T) {
	for in, want := range map[string]string{
		"claude-haiku": "claude-haiku", "": `""`, "true": `"true"`, "a: b": `"a: b"`, "https://api.osv.dev": `"https://api.osv.dev"`, "3": `"3"`,
	} {
		if got := Scalar(in); got != want {
			t.Errorf("Scalar(%q)=%s want %s", in, got, want)
		}
	}
}

func TestRender(t *testing.T) {
	out := Render(Meta{Name: "researcher", Namespace: "kagent", Generation: 3},
		model.Spec{Model: "claude-haiku", Instructions: "line one\nline two\n", ToolProfile: "lookup", Tools: []string{"osv_query_vulnerability"},
			Memory: &model.Memory{Enabled: true, TTLDays: 15}, Egress: &model.Egress{Allow: []string{"https://api.osv.dev"}},
			Knowledge: &model.Feature{Enabled: true}, Skills: []model.Skill{{Name: "s", Version: "1"}}, Suspend: true},
		&model.Status{ObservedGeneration: 3, Conditions: []model.Condition{{Type: "Ready", Status: "True", Reason: "Ready"}}})
	for _, want := range []string{
		"apiVersion: openagentix.io/v1alpha1\n", "  name: researcher\n", "  generation: 3\n", "  instructions: |\n    line one\n    line two\n",
		"  tools:\n    - osv_query_vulnerability\n", "    ttlDays: 15\n", "  knowledge:\n    enabled: true\n", "  skills:\n    - name: s\n      version: \"1\"\n", "  suspend: true\n", "    allow:\n      - \"https://api.osv.dev\"\n", "    - type: Ready\n      status: \"True\"\n",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
}

// nasty are strings a YAML writer must get right: indicators, quotes, escapes, lookalikes of other types, and the
// whitespace a block scalar must keep.
var nasty = []string{
	"a: b", "#hash", "a #b", "- dash", "-", "? q", "key: value: more", "'single'", `"double"`, `say "hi"`, `back\slash`, `tab	inside`,
	"unicode é ü 日本語 🙂", "trailing space ", "  leading space", "line one\nline two", "line one \nline two  \n", "ends with newline\n", "\nstarts with newline",
	"two\n\nblank lines", "no\nfinal newline", "yes", "No", "off", "null", "~", "3", "3.14", "0x1F", "1e3", "2026-11-25", "12:30", "@at", "`tick", "!tag", "&anchor", "*alias",
	"%percent", "{flow}", "[seq]", "a, b", "|", ">", "=", "<<", "", " ", "\t", "colon:", ":colon", "http://x.example/a?b=c#d", "Ready", "NotReady: because",
	"\n", "\n\n", "  \n  ", "last line has spaces   ", "x\r\ny", "nul\x00byte", "bell\a",
}

func parse(t *testing.T, out string) map[string]any {
	t.Helper()
	var m map[string]any
	if err := yaml.Unmarshal([]byte(out), &m); err != nil {
		t.Fatalf("the output is not YAML: %v\n%s", err, out)
	}
	return m
}

func TestRenderedYAMLParsesBackToTheSameData(t *testing.T) {
	for _, s := range nasty {
		if strings.ContainsAny(s, "\x00\a") {
			continue // control characters other than tab and newline are not valid in a YAML stream; see TestControlCharactersAreEscaped
		}
		out := Render(Meta{Name: "agent", Namespace: "ns", ResourceVersion: s},
			model.Spec{Description: s, Model: s, Instructions: s, ToolProfile: s, Tools: []string{s, "b"}, Skills: []model.Skill{{Name: s, Version: s}},
				Egress: &model.Egress{Allow: []string{s}}, Knowledge: &model.Feature{Enabled: true, Collections: []string{s}}, Notify: &model.Feature{Enabled: true, Destinations: []string{s}}},
			&model.Status{Conditions: []model.Condition{{Type: s, Status: s, Reason: s, Message: s, LastTransitionTime: s}}, Revision: s,
				EffectiveTools: []string{s}, EffectiveEgress: []string{s}, Violations: []string{s}, AgentRef: &model.ObjectRef{APIVersion: s, Kind: s, Name: s},
				Endpoint: &model.Endpoint{Protocol: s, URL: s, ProtocolVersion: s}})
		m := parse(t, out)
		spec, _ := m["spec"].(map[string]any)
		st, _ := m["status"].(map[string]any)
		if spec == nil || st == nil {
			t.Fatalf("%q: no spec or status:\n%s", s, out)
		}
		check := func(what string, got any, want string) {
			t.Helper()
			if got == nil && want == "" {
				return // an empty optional field is left out
			}
			if g, ok := got.(string); !ok || g != want {
				t.Errorf("%q: %s = %#v\n%s", s, what, got, out)
			}
		}
		check("metadata.resourceVersion", m["metadata"].(map[string]any)["resourceVersion"], s)
		check("description", spec["description"], s)
		check("model", spec["model"], s)
		check("instructions", spec["instructions"], s)
		check("toolProfile", spec["toolProfile"], s)
		check("tools[0]", spec["tools"].([]any)[0], s)
		check("skill name", spec["skills"].([]any)[0].(map[string]any)["name"], s)
		check("skill version", spec["skills"].([]any)[0].(map[string]any)["version"], s)
		check("egress", spec["egress"].(map[string]any)["allow"].([]any)[0], s)
		check("collections", spec["knowledge"].(map[string]any)["collections"].([]any)[0], s)
		check("destinations", spec["notify"].(map[string]any)["destinations"].([]any)[0], s)
		c := st["conditions"].([]any)[0].(map[string]any)
		for _, k := range []string{"type", "status", "reason", "message", "lastTransitionTime"} {
			check("condition."+k, c[k], s)
		}
		check("revision", st["revision"], s)
		check("effectiveTools", st["effectiveTools"].([]any)[0], s)
		check("violations", st["violations"].([]any)[0], s)
		check("agentRef.name", st["agentRef"].(map[string]any)["name"], s)
		check("endpoint.url", st["endpoint"].(map[string]any)["url"], s)
	}
}

func TestControlCharactersAreEscapedNotDropped(t *testing.T) {
	out := Render(Meta{Name: "a"}, model.Spec{Model: "m", Instructions: "x\x00y\a"}, nil)
	m := parse(t, out)
	if got := m["spec"].(map[string]any)["instructions"]; got != "x\x00y\a" {
		t.Fatalf("%#v\n%s", got, out)
	}
}

func TestBlockScalarKeepsTrailingSpaces(t *testing.T) {
	out := Render(Meta{Name: "a"}, model.Spec{Model: "m", Instructions: "keep   \nthese  \n"}, nil)
	if !strings.Contains(out, "    keep   \n    these  \n") {
		t.Fatalf("trailing spaces were trimmed:\n%q", out)
	}
}

func TestRenderShowsTheRuntimeOfAContainerAgentAndNoEmptyInstructions(t *testing.T) {
	spec := model.Spec{Model: "m", Runtime: map[string]any{"type": "container", "container": map[string]any{
		"image": "registry.example.com/a/b@sha256:abc", "port": float64(8080),
		"env": []any{map[string]any{"name": "LOG_LEVEL", "value": "info"}, map[string]any{"name": "MODE", "value": "yes"}}}}}
	got := Render(Meta{Name: "echo"}, spec, nil)
	want := "spec:\n  model: m\n  runtime:\n    container:\n      env:\n        - name: LOG_LEVEL\n          value: info\n        - name: MODE\n          value: \"yes\"\n      image: \"registry.example.com/a/b@sha256:abc\"\n      port: 8080\n    type: container\n"
	if !strings.HasSuffix(got, want) {
		t.Fatalf("got:\n%s\nwant suffix:\n%s", got, want)
	}
}
