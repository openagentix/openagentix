// Package policy holds the pure checks that decide whether an AgentDefinition is accepted. It reads the definition, the
// catalog (what exists) and the policy (what is allowed) and returns one sentence per refused rule. It writes nothing and
// calls nothing. The wording follows the chart's own failures where the chart has an equivalent.
package policy

import (
	"fmt"
	"net/url"
	"regexp"
	"slices"
	"strings"

	"github.com/openagentix/openagentix/services/control-plane/internal/api"
	"github.com/openagentix/openagentix/services/control-plane/internal/catalog"
)

const (
	MaxNameLen         = 40
	MaxDescriptionLen  = 256
	MaxInstructionsLen = 16 << 10
	MaxEgressOrigins   = 64
)

var nameRE = regexp.MustCompile(`^[a-z]([-a-z0-9]*[a-z0-9])?$`)

// labelValueRE is the shape of a Kubernetes label value (an empty value is not accepted here).
var labelValueRE = regexp.MustCompile(`^[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?$`)

// secretShapes are the ten patterns of charts/openagentix/files/memory-expiry.sh, with the same names, and one more of
// the platform's own (platform_virtual_key). PostgreSQL's word boundaries (\m, \M) became \b.
var secretShapes = []struct {
	name string
	re   *regexp.Regexp
}{
	{"aws_access_key_id", regexp.MustCompile(`\b(AKIA|ASIA)[0-9A-Z]{16}\b`)},
	{"bearer_token", regexp.MustCompile(`[Bb]earer[ ]+[A-Za-z0-9._~+/=-]{24,}`)},
	{"github_token", regexp.MustCompile(`\b(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,})`)},
	{"google_api_key", regexp.MustCompile(`\bAIza[0-9A-Za-z_-]{35}`)},
	{"jwt", regexp.MustCompile(`\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}`)},
	{"private_key_header", regexp.MustCompile(`-----BEGIN [A-Z ]*PRIVATE KEY-----`)},
	{"provider_secret_key", regexp.MustCompile(`\bsk-[A-Za-z0-9_-]{32,}`)},
	{"slack_token", regexp.MustCompile(`\bxox[abeprs]-[A-Za-z0-9-]{10,}`)},
	{"stripe_secret_key", regexp.MustCompile(`\b(sk|rk)_(live|test)_[0-9A-Za-z]{16,}`)},
	{"telegram_bot_token", regexp.MustCompile(`\b[0-9]{8,10}:[A-Za-z0-9_-]{35}`)},
	// not in the memory scan: the platform's own virtual keys (keys.Mint), which must never be pasted into a definition
	{"platform_virtual_key", regexp.MustCompile(`\bvk-[0-9a-f]{32}\b`)},
}

// PatternNames lists the secret shapes by name.
func PatternNames() []string {
	var n []string
	for _, s := range secretShapes {
		n = append(n, s.name)
	}
	return n
}

// Input is everything a check needs.
type Input struct {
	Def     *api.AgentDefinition
	Catalog *catalog.Catalog
	Policy  *catalog.Policy
	Tools   catalog.ToolResolver
	// Earlier holds the names of the other definitions that rank before this one (oldest first). They count against
	// maxAgents, so that when the limit is lowered the newest definitions are the ones refused.
	Earlier []string
	// EarlierContainers is how many of those use the container runtime (policy.runtimes.container.maxAgents counts them).
	EarlierContainers int
}

// Validate returns the violations, in a fixed order; empty means accepted.
func Validate(in Input) []string {
	var v []string
	add := func(f string, a ...any) { v = append(v, fmt.Sprintf(f, a...)) }
	d, c, p := in.Def, in.Catalog, in.Policy
	s := d.Spec

	// name and count
	switch {
	case len(d.Metadata.Name) > MaxNameLen:
		add("name %q is too long: at most %d characters", d.Metadata.Name, MaxNameLen)
	case !nameRE.MatchString(d.Metadata.Name):
		add("name %q must be a DNS label (lower case letters, digits and dashes, starting with a letter)", d.Metadata.Name)
	}
	if catalog.ReservedIn(c, p, d.Metadata.Namespace, d.Metadata.Name) {
		add("name %q is reserved in namespace %q (chart agents and platform services own it)", d.Metadata.Name, d.Metadata.Namespace)
	}
	// maxAgents is per namespace: Earlier holds the accepted definitions of this definition's own namespace
	if len(in.Earlier) >= p.MaxAgents {
		add("the platform policy allows at most %d agents in namespace %q and %d already exist", p.MaxAgents, d.Metadata.Namespace, len(in.Earlier))
	}
	// runtime type (ADR 0015)
	rt := s.RuntimeType()
	container := rt == api.RuntimeContainer
	switch {
	case rt != api.RuntimeBuiltin && !container:
		add("runtime.type %q is not known (use builtin or container)", rt)
	case !p.RuntimeAllowed(rt):
		add("runtime %s is not allowed by the platform policy", rt)
	case !c.RuntimeAvailable(rt):
		add("runtime %s is not available on this platform", rt)
	}
	if rt == api.RuntimeBuiltin && s.Runtime.Container != nil {
		add("runtime.container is set but runtime.type is builtin; set runtime.type to container or remove the block")
	}
	for _, k := range []string{api.LabelTeam, api.LabelProject} {
		if v, ok := d.Metadata.Labels[k]; ok && (len(v) > 63 || !labelValueRE.MatchString(v)) {
			add("label %s %q is not a valid label value (at most 63 characters: letters, digits, '-', '_' and '.', starting and ending with a letter or digit)", k, v)
		}
		for _, sh := range secretShapes {
			if sh.re.MatchString(d.Metadata.Labels[k]) {
				add("label %s contains something shaped like a secret (%s); remove it", k, sh.name)
			}
		}
	}

	// size and content
	if n := len([]rune(s.Description)); n > MaxDescriptionLen {
		add("description is %d characters; at most %d", n, MaxDescriptionLen)
	}
	switch {
	case container:
		// a container agent is configured in its image: the builtin-only features are refused below with one sentence each
	case s.InstructionsFrom != nil && strings.TrimSpace(s.Instructions) != "":
		add("set exactly one of instructions and instructionsFrom")
	case s.InstructionsFrom != nil:
		add("instructionsFrom is not available yet; write the prompt in instructions")
	case strings.TrimSpace(s.Instructions) == "":
		add("instructions are required: set exactly one of instructions and instructionsFrom")
	case len(s.Instructions) > MaxInstructionsLen:
		add("instructions are %d bytes; at most %d", len(s.Instructions), MaxInstructionsLen)
	}
	for _, sh := range secretShapes {
		if sh.re.MatchString(s.Instructions) {
			add("instructions contain something shaped like a secret (%s); remove it", sh.name)
		}
	}
	// every other free-text field: a secret in a description or a name would land in an object, a log or a status
	for _, f := range []struct {
		name string
		text []string
	}{
		{"description", []string{s.Description}}, {"model", []string{s.Model}}, {"toolProfile", []string{s.ToolProfile}},
		{"tools", s.Tools}, {"skills", skillTexts(s.Skills)}, {"egress.allow", s.Egress.Allow},
		{"knowledge.collections", s.Knowledge.Collections}, {"notify.destinations", s.Notify.Destinations},
	} {
		for _, sh := range secretShapes {
			if slices.ContainsFunc(f.text, sh.re.MatchString) {
				add("%s contains something shaped like a secret (%s); remove it", f.name, sh.name)
			}
		}
	}

	// model
	switch {
	case !c.HasModel(s.Model):
		add("model %q is not in the platform catalog (%s)", s.Model, strings.Join(c.Models, ", "))
	case !p.ModelAllowed(s.Model):
		add("model %q is not allowed by the platform policy", s.Model)
	}

	if container {
		containerRefusals(s, add)
		containerToolProfile(in, add)
		if s.Runtime.Container != nil || rt == api.RuntimeContainer {
			containerRules(d, p, in.EarlierContainers, add)
		}
	} else {
		validateBuiltin(in, add)
	}
	// a sentence that quotes a value (a model, a tool, an origin) must not repeat something shaped like a secret
	for i := range v {
		for _, sh := range secretShapes {
			v[i] = sh.re.ReplaceAllString(v[i], "[redacted]")
		}
	}
	return v
}

// validateBuiltin holds the rules of the builtin runtime: tools, features, memory, skills and egress. They are unchanged by
// the container runtime; a container agent refuses them instead (containerRefusals).
func validateBuiltin(in Input, add func(string, ...any)) {
	d, c, p := in.Def, in.Catalog, in.Policy
	s := d.Spec
	// tool profile and tools
	var prof catalog.ToolProfile
	haveProf := false
	if s.ToolProfile != "" {
		prof, haveProf = in.Tools.Profile(s.ToolProfile)
		switch {
		case !haveProf:
			add("toolProfile %q is not defined (defined: %s)", s.ToolProfile, strings.Join(in.Tools.Profiles(), ", "))
		case !p.ProfileAllowed(s.ToolProfile):
			add("toolProfile %q is not allowed by the platform policy", s.ToolProfile)
		}
	}
	needProfile := func(what string) {
		if s.ToolProfile == "" {
			add("%s adds tools, so it needs a toolProfile: the shared tool server filters on the client side only", what)
		}
	}
	if s.ToolProfile == "" {
		switch {
		case len(s.Tools) > 0:
			add("the definition lists tools but names no toolProfile: the shared tool server filters on the client side only")
		case p.RequireToolProfile:
			add("the platform policy requires a toolProfile")
		}
	}
	seenTool := map[string]bool{}
	checkTool := func(n string) {
		if !haveProf {
			return
		}
		if slices.Contains(prof.Tools, n) {
			return
		}
		add("%s", in.Tools.Missing(prof, n)) // the tools adapter knows why (a code-mode tool needs a profile with code mode on)
	}
	for _, t := range s.Tools {
		if seenTool[t] {
			add("the definition lists tool %q twice", t)
			continue
		}
		seenTool[t] = true
		checkTool(t)
	}

	// knowledge and notify
	feature := func(name string, on bool, allow bool, f catalog.Feature) {
		if !on {
			return
		}
		switch {
		case !allow:
			add("%s is not allowed by the platform policy", name)
			return
		case !f.Available:
			add("%s is not available on this platform", name)
			return
		}
		needProfile(name)
		for _, t := range f.Tools {
			if !seenTool[t] {
				checkTool(t)
			}
		}
	}
	feature("knowledge", s.Knowledge.Enabled, p.AllowKnowledge, c.Knowledge)
	feature("notify", s.Notify.Enabled, p.AllowNotify, c.Notify)
	// reserved lists: refused with a clear sentence rather than silently ignored
	if len(s.Knowledge.Collections) > 0 {
		add("knowledge.collections: selecting collections is not available yet; leave the list empty")
	}
	if len(s.Notify.Destinations) > 0 {
		add("notify.destinations: selecting destinations is not available yet; leave the list empty")
	}

	// memory
	if s.Memory.Enabled {
		switch {
		case !p.Memory.Allowed:
			add("memory is not allowed by the platform policy")
		case !c.Memory.Available:
			add("memory is not installed on this platform")
		default:
			if p.Memory.RequireExpiry && !c.Memory.ExpiryEnabled {
				add("the memory expiry job is off, so the time limit would not be enforced; memory is refused until an operator turns it on")
			}
			ttl := s.Memory.TTLDays
			if ttl < 0 {
				add("memory.ttlDays must be at least 1")
			} else {
				if ttl == 0 {
					ttl = c.Memory.DefaultTTLDays
				}
				if ttl > p.Memory.MaxTTLDays {
					add("memory.ttlDays %d is above the platform maximum of %d", ttl, p.Memory.MaxTTLDays)
				}
			}
		}
	}

	// skills: a name from the catalog; a version, when set, must be one the catalog offers (today: the digest of its ref)
	seenSkill := map[string]bool{}
	for _, sk := range s.Skills {
		if seenSkill[sk.Name] {
			add("skill %q is listed twice", sk.Name)
			continue
		}
		seenSkill[sk.Name] = true
		ref, ok := c.Skills[sk.Name]
		switch {
		case !ok:
			add("skill %q is not in the platform catalog", sk.Name)
		case !p.SkillAllowed(sk.Name):
			add("skill %q is not allowed by the platform policy", sk.Name)
		case sk.Version != "" && sk.Version != SkillVersion(ref):
			add("skill %q has no version %q in the platform catalog (it offers %q); leave version empty to take it", sk.Name, sk.Version, SkillVersion(ref))
		}
	}

	// egress
	if n := len(s.Egress.Allow); n > MaxEgressOrigins {
		add("egress.allow has %d origins; at most %d are allowed", n, MaxEgressOrigins)
	} else {
		seen := map[string]bool{}
		for _, o := range s.Egress.Allow {
			switch {
			case !catalog.OriginRE.MatchString(o) || len(o) > catalog.MaxOriginLen:
				add("egress.allow entry %q is not an origin: use https://host[:port] or http://host[:port], a lower case DNS name (a wildcard replaces exactly one leftmost label), no path, no query, no address", o)
			case seen[o]:
				add("egress.allow lists %q twice", o)
			case egressForbidden(o, c.Namespaces) != "":
				add("egress.allow entry %q is %s (it can never be listed)", o, egressForbidden(o, c.Namespaces))
			case p.InClusterAllowed(hostPort(o)):
				// listed by the operator in egress.inClusterDestinations: the one exception to the rule below
			case catalog.InternalEgressHost(egressHost(o)):
				add("egress.allow entry %q names a cluster-internal or local host (an address, a name without a dot, .svc or .cluster.local, or a last label such as .internal, .local, .lan or .corp that only looks public); the policy cannot allow it unless the operator lists exactly host:port in egress.inClusterDestinations", o)
			case !originAllowed(o, p.Egress.AllowedOrigins):
				add("egress.allow entry %q is not matched by the platform policy", o)
			}
			seen[o] = true
		}
	}
}

// SkillVersion is the version of a skill the catalog offers: the digest of its OCI reference ("sha256:<64 hex>"). The
// catalog has one digest per skill, so this is the only version a definition may name.
func SkillVersion(ref string) string {
	if i := strings.LastIndex(ref, "@"); i >= 0 {
		return ref[i+1:]
	}
	return ""
}

func skillTexts(l []api.Skill) []string {
	var out []string
	for _, s := range l {
		out = append(out, s.Name, s.Version)
	}
	return out
}

// hostPort is the origin's host and port in lower case, the port being the scheme's default when the origin names none.
func hostPort(origin string) string {
	u, err := url.Parse(origin)
	if err != nil {
		return ""
	}
	port := u.Port()
	if port == "" {
		port = map[string]string{"http": "80", "https": "443"}[u.Scheme]
	}
	return strings.ToLower(u.Hostname()) + ":" + port
}

// egressHost is the origin's host in lower case, a leading "*." cut.
func egressHost(origin string) string {
	u, err := url.Parse(origin)
	if err != nil {
		return ""
	}
	return strings.TrimPrefix(strings.ToLower(u.Hostname()), "*.")
}

// egressForbidden says why the origin may never be used (catalog.ForbiddenEgressHost), "" when it may.
func egressForbidden(origin string, ns catalog.Namespaces) string {
	why, bad := catalog.ForbiddenEgressHost(egressHost(origin), ns)
	if !bad {
		return ""
	}
	return why
}

// originAllowed matches an origin against the policy patterns. A pattern is an origin; its host may start with one
// wildcard label, which stands for exactly one label. An origin that is itself a wildcard matches only an identical pattern.
func originAllowed(origin string, patterns []string) bool {
	if slices.Contains(patterns, origin) {
		return true
	}
	o, err := url.Parse(origin)
	if err != nil || strings.HasPrefix(o.Hostname(), "*.") {
		return false
	}
	for _, pat := range patterns {
		p, err := url.Parse(pat)
		if err != nil || !strings.HasPrefix(p.Hostname(), "*.") {
			continue
		}
		if p.Scheme != o.Scheme || p.Port() != o.Port() {
			continue
		}
		suffix := p.Hostname()[1:] // ".example.org"
		host := o.Hostname()
		if strings.HasSuffix(host, suffix) && !strings.Contains(strings.TrimSuffix(host, suffix), ".") && len(host) > len(suffix) {
			return true
		}
	}
	return false
}
