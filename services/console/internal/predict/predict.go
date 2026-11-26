// Package predict guesses, for the obvious cases only, what the controller's policy check would refuse. It is a small
// rule set written for the console, not the controller's validator: the validator lives in services/control-plane/internal
// (a Go internal package that another module cannot import), and sharing it as a public package is a follow-up. So the
// result is a prediction and is labelled as one everywhere. The controller's status.violations stay the authority, and
// the sentences below follow its wording where the rule is the same.
package predict

import (
	"fmt"
	"net/url"
	"slices"
	"strings"

	"github.com/openagentix/openagentix/services/console/internal/model"
	"github.com/openagentix/openagentix/services/console/internal/platform"
)

// Input is one draft. Others is the number of other built definitions that count against maxAgents.
type Input struct {
	Name   string
	Spec   model.Spec
	Others int
	// OthersContainer is how many of the other definitions use the container runtime.
	OthersContainer int
	P               platform.Both
}

// Check returns the predicted refusals in a fixed order. Empty means nothing obvious.
func Check(in Input) []model.Prediction {
	var out []model.Prediction
	add := func(field, f string, a ...any) {
		out = append(out, model.Prediction{Field: field, Message: fmt.Sprintf(f, a...)})
	}
	c, p, s := in.P.Catalog, in.P.Policy, in.Spec

	if slices.Contains(c.ReservedNames, in.Name) || slices.Contains(p.ReservedNames, in.Name) {
		add("name", "name %q is reserved (chart agents and platform services own it)", in.Name)
	}
	if p.MaxAgents > 0 && in.Others >= p.MaxAgents {
		add("name", "the platform policy allows at most %d agents and %d already exist", p.MaxAgents, in.Others)
	}

	switch {
	case !slices.Contains(c.Models, s.Model):
		add("model", "model %q is not in the platform catalog (%s)", s.Model, strings.Join(c.Models, ", "))
	case !p.ModelAllowed(s.Model):
		add("model", "model %q is not allowed by the platform policy", s.Model)
	}

	if runtimeRules(in, add) {
		containerRules(in, add)
		return out
	}

	prof, haveProf := platform.Profile{}, false
	if s.ToolProfile != "" {
		prof, haveProf = c.Profile(s.ToolProfile)
		names := make([]string, len(c.ToolProfiles()))
		for i, x := range c.ToolProfiles() {
			names[i] = x.Name
		}
		switch {
		case !haveProf:
			add("toolProfile", "toolProfile %q is not defined (defined: %s)", s.ToolProfile, strings.Join(names, ", "))
		case !p.ProfileAllowed(s.ToolProfile):
			add("toolProfile", "toolProfile %q is not allowed by the platform policy", s.ToolProfile)
		}
	} else {
		switch {
		case len(s.Tools) > 0:
			add("tools", "the definition lists tools but names no toolProfile: the shared tool server filters on the client side only")
		case p.RequireToolProfile:
			add("toolProfile", "the platform policy requires a toolProfile")
		}
	}
	seen := map[string]bool{}
	check := func(field, n string) {
		if haveProf && !slices.Contains(prof.Tools, n) {
			if n == "execute_tool_script" {
				add(field, "the definition lists tool %q but profile %q has codeMode off (set codeMode: true on the profile)", n, prof.Name)
			} else {
				add(field, "the definition lists tool %q which is not in profile %q (the profile offers: %s)", n, prof.Name, strings.Join(prof.Tools, ", "))
			}
		}
	}
	for _, t := range s.Tools {
		if seen[t] {
			add("tools", "the definition lists tool %q twice", t)
			continue
		}
		seen[t] = true
		check("tools", t)
	}

	feature := func(field, name string, on, allow bool, f platform.Feature) {
		if !on {
			return
		}
		switch {
		case !allow:
			add(field, "%s is not allowed by the platform policy", name)
			return
		case !f.Available:
			add(field, "%s is not available on this platform", name)
			return
		case s.ToolProfile == "":
			add(field, "%s adds tools, so it needs a toolProfile: the shared tool server filters on the client side only", name)
			return
		}
		if !haveProf {
			return
		}
		var missing []string
		for _, t := range f.Tools {
			if !slices.Contains(prof.Tools, t) {
				missing = append(missing, t)
			}
		}
		if len(missing) > 0 {
			add(field, "%s needs tools that profile %q does not offer: %s", name, prof.Name, strings.Join(missing, ", "))
		}
	}
	feature("knowledge", "knowledge", s.Knowledge != nil && s.Knowledge.Enabled, p.AllowKnowledge, c.Knowledge)
	feature("notify", "notify", s.Notify != nil && s.Notify.Enabled, p.AllowNotify, c.Notify)

	if s.Memory != nil && s.Memory.Enabled {
		switch {
		case !p.Memory.Allowed:
			add("memory", "memory is not allowed by the platform policy")
		case !c.Memory.Available:
			add("memory", "memory is not installed on this platform")
		default:
			if p.Memory.RequireExpiry && !c.Memory.ExpiryEnabled {
				add("memory", "the memory expiry job is off, so the time limit would not be enforced; memory is refused until an operator turns it on")
			}
			ttl := s.Memory.TTLDays
			if ttl == 0 {
				ttl = c.Memory.DefaultTTLDays
			}
			if ttl > p.Memory.MaxTTLDays {
				add("memory.ttlDays", "memory.ttlDays %d is above the platform maximum of %d", ttl, p.Memory.MaxTTLDays)
			}
		}
	}

	for _, sk := range s.Skills {
		n := sk.Name
		if _, ok := c.Skills[n]; !ok {
			add("skills", "skill %q is not in the platform catalog", n)
		} else if !p.SkillAllowed(n) {
			add("skills", "skill %q is not allowed by the platform policy", n)
		}
	}

	if s.Egress != nil {
		for _, o := range s.Egress.Allow {
			switch {
			case !platform.OriginRE.MatchString(o) || len(o) > 270:
				add("egress.allow", "egress.allow entry %q is not an origin: use https://host[:port], a lower case DNS name, no path, no query, no address", o)
			case !OriginAllowed(o, p.Egress.AllowedOrigins):
				add("egress.allow", "egress.allow entry %q is not matched by the platform policy", o)
			}
		}
	}
	return out
}

// OriginAllowed matches an origin against policy patterns. A pattern's host may start with one wildcard label, which
// stands for exactly one label.
func OriginAllowed(origin string, patterns []string) bool {
	if slices.Contains(patterns, origin) {
		return true
	}
	o, err := url.Parse(origin)
	if err != nil || strings.HasPrefix(o.Hostname(), "*.") {
		return false
	}
	for _, pat := range patterns {
		p, err := url.Parse(pat)
		if err != nil || !strings.HasPrefix(p.Hostname(), "*.") || p.Scheme != o.Scheme || p.Port() != o.Port() {
			continue
		}
		suffix := p.Hostname()[1:]
		host := o.Hostname()
		if strings.HasSuffix(host, suffix) && len(host) > len(suffix) && !strings.Contains(strings.TrimSuffix(host, suffix), ".") {
			return true
		}
	}
	return false
}
