// Package rules holds the per-caller rules of the A2A gate: which agents a caller may reach and which user ids
// it may assert. The file is rendered by the chart from its values and mounted as JSON. It holds no secret.
package rules

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"regexp"
	"slices"
	"strings"
	"unicode"
)

// MaxUserIDBytes bounds a user id (kagent keys sessions and memory by it).
const MaxUserIDBytes = 256

// ServiceAccount names the Kubernetes ServiceAccount a caller's projected token belongs to.
type ServiceAccount struct {
	Namespace string `json:"namespace"`
	Name      string `json:"name"`
}

// UserRule says which user id a caller may assert. Exactly one field is set.
//   - Exact: the caller must send this value (or none; the gate fills it in).
//   - Prefix: the caller must send a value that starts with this and has something after it.
//   - Fixed: the gate always sets this value; whatever the caller sends is ignored.
type UserRule struct {
	Exact  string `json:"exact,omitempty"`
	Prefix string `json:"prefix,omitempty"`
	Fixed  string `json:"fixed,omitempty"`
}

// Caller is one entry of the rules file.
type Caller struct {
	Name           string          `json:"name"`
	ServiceAccount *ServiceAccount `json:"serviceAccount,omitempty"`
	Key            bool            `json:"key,omitempty"` // authenticates with a static key (SHA-256 in the keys Secret, file named like the caller)
	Agents         []string        `json:"agents"`        // "namespace/name"
	UserID         UserRule        `json:"userId"`
	// Methods are the JSON-RPC methods the caller may use (A2A names such as SendMessage). Empty: DefaultMethods.
	Methods []string `json:"methods,omitempty"`
	// Memory lets the caller use two RPCs of kagent's MemoryService, List and Delete, for the user ids and agents its rule
	// allows (ADR 0006, round 3). Default false: every gRPC and gRPC-Web call is refused.
	Memory bool `json:"memory,omitempty"`
	// Event, when set, makes this an event caller (ADR 0027): the gate rebuilds its message and limits its rate. See event.go.
	Event *Event `json:"event,omitempty"`
}

// DefaultMethods are what a caller without its own list may use: send a message, and stream one. Reading, cancelling
// or listing tasks, and push notification settings, are not in it.
var DefaultMethods = []string{"SendMessage", "SendStreamingMessage"}

var methodRe = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_./:-]{0,63}$`)

// Rules is the parsed file.
type Rules struct {
	Callers []Caller `json:"callers"`
}

var nameRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$`)

// Load reads and parses a rules file.
func Load(path string) (*Rules, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read rules: %w", err)
	}
	return Parse(b)
}

// Parse parses and validates rules JSON. Unknown fields are an error, so a typo cannot loosen a rule silently.
func Parse(b []byte) (*Rules, error) {
	if len(bytes.TrimSpace(b)) == 0 {
		return nil, errors.New("rules file is empty")
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	var r Rules
	if err := dec.Decode(&r); err != nil {
		return nil, fmt.Errorf("parse rules: %w", err)
	}
	if dec.More() {
		return nil, errors.New("parse rules: trailing data")
	}
	// "event": null decodes like no block at all, and that would leave a free-text caller: refuse it
	var raw struct {
		Callers []map[string]json.RawMessage `json:"callers"`
	}
	if err := json.Unmarshal(b, &raw); err != nil {
		return nil, fmt.Errorf("parse rules: %w", err)
	}
	for i, m := range raw.Callers {
		if ev, ok := m["event"]; ok && string(bytes.TrimSpace(ev)) == "null" {
			return nil, fmt.Errorf("callers[%d]: event must be an object, not null", i)
		}
	}
	names := map[string]bool{}
	sas := map[ServiceAccount]bool{}
	for i := range r.Callers {
		c := &r.Callers[i]
		if !nameRe.MatchString(c.Name) {
			return nil, fmt.Errorf("callers[%d]: name %q must be letters, digits, '.', '_' or '-' (at most 63)", i, c.Name)
		}
		if names[c.Name] {
			return nil, fmt.Errorf("caller %q is listed twice", c.Name)
		}
		names[c.Name] = true
		if c.Key == (c.ServiceAccount != nil) {
			return nil, fmt.Errorf("caller %q: set exactly one of serviceAccount and key", c.Name)
		}
		if c.ServiceAccount != nil {
			if c.ServiceAccount.Namespace == "" || c.ServiceAccount.Name == "" {
				return nil, fmt.Errorf("caller %q: serviceAccount needs namespace and name", c.Name)
			}
			if sas[*c.ServiceAccount] {
				return nil, fmt.Errorf("caller %q: service account %s/%s belongs to another caller", c.Name, c.ServiceAccount.Namespace, c.ServiceAccount.Name)
			}
			sas[*c.ServiceAccount] = true
		}
		if len(c.Agents) == 0 {
			return nil, fmt.Errorf("caller %q: agents must not be empty", c.Name)
		}
		for _, a := range c.Agents {
			ns, name, ok := strings.Cut(a, "/")
			if !ok || ns == "" || name == "" || strings.Contains(name, "/") {
				return nil, fmt.Errorf("caller %q: agent %q must be namespace/name", c.Name, a)
			}
		}
		if c.Methods != nil {
			if len(c.Methods) == 0 {
				return nil, fmt.Errorf("caller %q: methods must not be empty (leave it out for the default list)", c.Name)
			}
			seen := map[string]bool{}
			for _, m := range c.Methods {
				if !methodRe.MatchString(m) || seen[m] {
					return nil, fmt.Errorf("caller %q: method %q is not a valid method name, or is listed twice", c.Name, m)
				}
				seen[m] = true
			}
		}
		if err := c.checkEvent(); err != nil {
			return nil, err
		}
		set := 0
		for _, v := range []string{c.UserID.Exact, c.UserID.Prefix, c.UserID.Fixed} {
			if v != "" {
				set++
				if !validUserID(v) {
					return nil, fmt.Errorf("caller %q: userId rule value is not a valid user id", c.Name)
				}
			}
		}
		if set != 1 {
			return nil, fmt.Errorf("caller %q: userId needs exactly one of exact, prefix and fixed", c.Name)
		}
	}
	if err := r.checkEventCallers(); err != nil {
		return nil, err
	}
	return &r, nil
}

// ByServiceAccount returns the caller bound to a ServiceAccount, or nil.
func (r *Rules) ByServiceAccount(ns, name string) *Caller {
	for i := range r.Callers {
		if sa := r.Callers[i].ServiceAccount; sa != nil && sa.Namespace == ns && sa.Name == name {
			return &r.Callers[i]
		}
	}
	return nil
}

// ByName returns the caller with this name, or nil.
func (r *Rules) ByName(name string) *Caller {
	for i := range r.Callers {
		if r.Callers[i].Name == name {
			return &r.Callers[i]
		}
	}
	return nil
}

// AllowsAgent reports whether the caller may reach the agent namespace/name.
func (c *Caller) AllowsAgent(ns, name string) bool {
	want := ns + "/" + name
	for _, a := range c.Agents {
		if a == want {
			return true
		}
	}
	return false
}

// ResolveUser applies the caller's user id rule to the X-User-Id values the request carried. It returns the
// value to send upstream, or false when the request must be refused.
// AllowsMethod reports whether the caller may use a JSON-RPC method.
func (c *Caller) AllowsMethod(m string) bool {
	list := c.Methods
	if len(list) == 0 {
		list = DefaultMethods
	}
	return slices.Contains(list, m)
}

func (c *Caller) ResolveUser(inbound []string) (string, bool) {
	switch {
	case c.UserID.Fixed != "":
		return c.UserID.Fixed, true // whatever was sent is ignored
	case len(inbound) > 1:
		return "", false // two values: ambiguous, refuse
	case c.UserID.Exact != "":
		if len(inbound) == 0 {
			return c.UserID.Exact, true
		}
		if inbound[0] == c.UserID.Exact {
			return inbound[0], true
		}
		return "", false
	default: // prefix
		if len(inbound) == 0 {
			return "", false
		}
		v := inbound[0]
		if !strings.HasPrefix(v, c.UserID.Prefix) || len(v) == len(c.UserID.Prefix) || !validUserID(v) {
			return "", false
		}
		return v, true
	}
}

func validUserID(v string) bool {
	if v == "" || len(v) > MaxUserIDBytes {
		return false
	}
	return !strings.ContainsFunc(v, func(r rune) bool { return unicode.IsControl(r) || r == unicode.ReplacementChar })
}
