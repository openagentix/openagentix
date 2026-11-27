package stub

// Scenarios: a scripted, multi-step agent run for tests. A scenario is picked by the system prompt and the last user
// message. Its steps are tool calls, one per model turn; the step is the number of tool results that came after the
// last user message. Arguments and the final answer are templates that may quote the user message and earlier results.
// Nothing here is loaded unless a scenario file or directory is given (STUB_MODEL_SCENARIOS), so the built-in
// behaviour of the quick start does not change.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Set is a loaded list of scenarios. A nil Set has none.
type Set struct{ list []*scenario }

type scenario struct {
	Name    string `json:"name"`
	Match   match  `json:"match"`
	Steps   []step `json:"steps"`
	Answers []answ `json:"answers"`

	system, user *regexp.Regexp
}

type match struct {
	System string `json:"system"` // regular expression on the system prompt (the agent marker); optional
	User   string `json:"user"`   // regular expression on the last user message; groups can be quoted as {{user.N}} or {{user.name}}
}

type step struct {
	Tool string         `json:"tool"` // matched by suffix among the tools the request offers
	Args map[string]any `json:"args"` // strings may hold {{...}} placeholders
}

type answ struct {
	When map[string]string `json:"when"` // result path -> regular expression; all must match. Empty means always.
	Text string            `json:"text"`

	when map[string]*regexp.Regexp
}

type file struct {
	Scenarios []*scenario `json:"scenarios"`
}

var rePlace = regexp.MustCompile(`\{\{\s*([^{}]+?)\s*\}\}`)

// LoadScenarios reads scenarios from one JSON file, or from every *.json file of a directory (in name order).
// It fails on a bad file, so a typo is found at start-up and not in the middle of a run.
func LoadScenarios(path string) (*Set, error) {
	st, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	files := []string{path}
	if st.IsDir() {
		files, err = filepath.Glob(filepath.Join(path, "*.json"))
		if err != nil {
			return nil, err
		}
		sort.Strings(files)
		if len(files) == 0 {
			return nil, fmt.Errorf("no *.json scenario files in %s", path)
		}
	}
	set := &Set{}
	seen := map[string]bool{}
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			return nil, err
		}
		var doc file
		dec := json.NewDecoder(bytes.NewReader(b))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&doc); err != nil {
			return nil, fmt.Errorf("%s: %w", filepath.Base(f), err)
		}
		for _, sc := range doc.Scenarios {
			if err := sc.compile(); err != nil {
				return nil, fmt.Errorf("%s: scenario %q: %w", filepath.Base(f), sc.Name, err)
			}
			if seen[sc.Name] {
				return nil, fmt.Errorf("%s: scenario name %q is used twice", filepath.Base(f), sc.Name)
			}
			seen[sc.Name] = true
			set.list = append(set.list, sc)
		}
	}
	return set, nil
}

func (sc *scenario) compile() (err error) {
	if strings.TrimSpace(sc.Name) == "" {
		return fmt.Errorf("name is empty")
	}
	if sc.Match.User == "" && sc.Match.System == "" {
		return fmt.Errorf("match needs a user or a system pattern")
	}
	if sc.Match.User != "" {
		if sc.user, err = regexp.Compile(sc.Match.User); err != nil {
			return fmt.Errorf("match.user: %w", err)
		}
	}
	if sc.Match.System != "" {
		if sc.system, err = regexp.Compile(sc.Match.System); err != nil {
			return fmt.Errorf("match.system: %w", err)
		}
	}
	if len(sc.Answers) == 0 {
		return fmt.Errorf("answers is empty: a scenario ends with an answer")
	}
	for i, s := range sc.Steps {
		if strings.TrimSpace(s.Tool) == "" {
			return fmt.Errorf("step %d: tool is empty", i)
		}
		if err := checkRefs(s.Args, i, sc.user); err != nil {
			return fmt.Errorf("step %d: %w", i, err)
		}
	}
	for i := range sc.Answers {
		a := &sc.Answers[i]
		a.when = map[string]*regexp.Regexp{}
		for path, expr := range a.When {
			if !strings.HasPrefix(path, "result.") {
				return fmt.Errorf("answer %d: when key %q must start with result.", i, path)
			}
			if a.when[path], err = regexp.Compile(expr); err != nil {
				return fmt.Errorf("answer %d: when %q: %w", i, path, err)
			}
		}
		if err := checkRefs(a.Text, len(sc.Steps), sc.user); err != nil {
			return fmt.Errorf("answer %d: %w", i, err)
		}
	}
	return nil
}

// checkRefs refuses a placeholder that reads a result that does not exist yet at that point (index >= limit).
func checkRefs(v any, limit int, user *regexp.Regexp) error {
	switch x := v.(type) {
	case string:
		for _, m := range rePlace.FindAllStringSubmatch(x, -1) {
			parts := strings.Split(m[1], ".")
			if parts[0] == "result" && len(parts) > 1 {
				if n, err := strconv.Atoi(parts[1]); err == nil && n >= limit {
					return fmt.Errorf("placeholder {{%s}} reads a result that does not exist yet", m[1])
				}
			}
			if parts[0] == "user" && user == nil {
				return fmt.Errorf("placeholder {{%s}} needs match.user", m[1])
			}
		}
	case map[string]any:
		for _, e := range x {
			if err := checkRefs(e, limit, user); err != nil {
				return err
			}
		}
	case []any:
		for _, e := range x {
			if err := checkRefs(e, limit, user); err != nil {
				return err
			}
		}
	}
	return nil
}

// decide returns handled=false when no scenario matches (or the set is nil): the caller then uses the built-in rules.
func (s *Set) decide(req request) (string, *toolCall, bool) {
	if s == nil || len(s.list) == 0 {
		return "", nil, false
	}
	system, user := "", ""
	lastUser := -1
	for i, m := range req.Messages {
		if m.Role == "system" && system == "" {
			system = text0(m.Content)
		}
		if m.Role == "user" {
			lastUser = i
			user = text0(m.Content)
		}
	}
	if lastUser < 0 {
		return "", nil, false
	}
	var results []any // parsed JSON when the tool result is JSON, else the text
	for _, m := range req.Messages[lastUser+1:] {
		if m.Role == "tool" {
			results = append(results, parseResult(text0(m.Content)))
		}
	}
	for _, sc := range s.list {
		if sc.system != nil && !sc.system.MatchString(system) {
			continue
		}
		var groups *ctx
		if sc.user != nil {
			sm := sc.user.FindStringSubmatch(user)
			if sm == nil {
				continue
			}
			groups = &ctx{names: sc.user.SubexpNames(), sub: sm}
		}
		c := &render{user: groups, results: results}
		if n := len(results); n < len(sc.Steps) {
			st := sc.Steps[n]
			t := find(req.Tools, st.Tool)
			if t == nil {
				return label + "Scenario " + sc.Name + " needs the tool " + st.Tool + " (step " + strconv.Itoa(n+1) + "), and it is not offered to this agent, so I stop here." + footer, nil, true
			}
			args, _ := json.Marshal(c.value(st.Args))
			return "", &toolCall{name: t.Function.Name, args: string(args), id: "call_stub_" + strconv.Itoa(n+1)}, true
		}
		for _, a := range sc.Answers {
			if a.holds(c) {
				return label + c.text(a.Text) + footer, nil, true
			}
		}
		return label + "Scenario " + sc.Name + " has no answer for these results." + footer, nil, true
	}
	return "", nil, false
}

func (a answ) holds(c *render) bool {
	for path, re := range a.when {
		v, ok := c.lookup(path)
		if !ok {
			return false
		}
		if !re.MatchString(scalar(v)) {
			return false
		}
	}
	return true
}

func parseResult(s string) any {
	s = strings.TrimSpace(s)
	var v any
	if json.Unmarshal([]byte(s), &v) == nil {
		return v
	}
	return s
}

type ctx struct {
	names []string
	sub   []string
}

type render struct {
	user    *ctx
	results []any
}

// lookup resolves user.<group>, result.<n> and result.<n>.<path with dots and array indexes>.
func (r *render) lookup(path string) (any, bool) {
	parts := strings.Split(path, ".")
	switch parts[0] {
	case "user":
		if r.user == nil || len(parts) != 2 {
			return nil, false
		}
		if n, err := strconv.Atoi(parts[1]); err == nil {
			if n < len(r.user.sub) {
				return r.user.sub[n], true
			}
			return nil, false
		}
		for i, name := range r.user.names {
			if name == parts[1] && i < len(r.user.sub) {
				return r.user.sub[i], true
			}
		}
	case "result":
		if len(parts) < 2 {
			return nil, false
		}
		n, err := strconv.Atoi(parts[1])
		if err != nil || n < 0 || n >= len(r.results) {
			return nil, false
		}
		cur := r.results[n]
		for _, p := range parts[2:] {
			switch x := cur.(type) {
			case map[string]any:
				v, ok := x[p]
				if !ok {
					return nil, false
				}
				cur = v
			case []any:
				i, err := strconv.Atoi(p)
				if err != nil || i < 0 || i >= len(x) {
					return nil, false
				}
				cur = x[i]
			default:
				return nil, false
			}
		}
		return cur, true
	}
	return nil, false
}

// scalar prints a value the way it is quoted in text: strings as they are, other values as JSON.
func scalar(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	b, _ := json.Marshal(v)
	return string(b)
}

// text fills the placeholders of a string. A placeholder with no value shows as <missing NAME>, never as an empty
// string, so a wrong path in a scenario shows in the tool arguments and in the answer.
func (r *render) text(s string) string {
	return rePlace.ReplaceAllStringFunc(s, func(m string) string {
		name := strings.TrimSpace(rePlace.FindStringSubmatch(m)[1])
		if v, ok := r.lookup(name); ok {
			return scalar(v)
		}
		return "<missing " + name + ">"
	})
}

// value fills the placeholders of an argument tree. A string that is exactly one placeholder keeps the JSON type of
// the value it points to (a number stays a number).
func (r *render) value(v any) any {
	switch x := v.(type) {
	case string:
		if m := rePlace.FindStringSubmatch(x); m != nil && m[0] == x {
			if val, ok := r.lookup(strings.TrimSpace(m[1])); ok {
				return val
			}
		}
		return r.text(x)
	case map[string]any:
		out := make(map[string]any, len(x))
		for k, e := range x {
			out[k] = r.value(e)
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, e := range x {
			out[i] = r.value(e)
		}
		return out
	}
	return v
}
