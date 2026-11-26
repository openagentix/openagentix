package predict

import (
	"regexp"
	"strings"

	"github.com/openagentix/openagentix/services/console/internal/model"
)

// The rules of a container agent (ADR 0015, ADR 0019), copied in the control plane's own sentences so the console and the
// controller say the same thing. The controller stays the authority; these are predictions. The numbers and patterns are
// the ones of services/control-plane/internal/policy/container.go and catalog.ImageRE.
const (
	MaxEnvVars       = 32
	MaxEnvValueLen   = 4096
	MaxEnvTotalBytes = 16 << 10
	MinPort          = 1024
	MaxPort          = 65535
)

var (
	imageRE   = regexp.MustCompile(`^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+@sha256:[0-9a-f]{64}$`)
	envNameRE = regexp.MustCompile(`^[A-Z_][A-Z0-9_]*$`)
	// ReservedEnvPrefixes belong to the platform.
	ReservedEnvPrefixes = []string{"OPENAGENTIX_", "OPENAI_", "OTEL_", "KUBERNETES_"}
)

// secretShapes are the patterns of the control plane's policy package (the ten of memory-expiry.sh and the platform's own key).
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
	{"platform_virtual_key", regexp.MustCompile(`\bvk-[0-9a-f]{32}\b`)},
}

// RuntimeType is spec.runtime.type, builtin when absent.
func RuntimeType(s model.Spec) string {
	if t, _ := s.Runtime["type"].(string); t != "" {
		return t
	}
	return "builtin"
}

// IsContainer says whether the spec asks for the container runtime.
func IsContainer(s model.Spec) bool { return RuntimeType(s) == "container" }

type envVar struct{ name, value string }

type containerBlock struct {
	present bool
	image   string
	port    int
	portOK  bool
	env     []envVar
}

func containerOf(s model.Spec) containerBlock {
	c, ok := s.Runtime["container"].(map[string]any)
	if !ok {
		return containerBlock{}
	}
	b := containerBlock{present: true}
	b.image, _ = c["image"].(string)
	switch n := c["port"].(type) {
	case float64:
		b.port, b.portOK = int(n), n == float64(int(n))
	case int:
		b.port, b.portOK = n, true
	case int64:
		b.port, b.portOK = int(n), true
	}
	if list, ok := c["env"].([]any); ok {
		for _, e := range list {
			m, _ := e.(map[string]any)
			n, _ := m["name"].(string)
			v, _ := m["value"].(string)
			b.env = append(b.env, envVar{n, v})
		}
	}
	return b
}

// runtimeRules checks spec.runtime. It returns whether the container rules apply (the type is container).
func runtimeRules(in Input, add func(field, f string, a ...any)) bool {
	c, p, s := in.P.Catalog, in.P.Policy, in.Spec
	rt := RuntimeType(s)
	container := rt == "container"
	switch {
	case rt != "builtin" && !container:
		add("runtime", "runtime.type %q is not known (use builtin or container)", rt)
	case !p.RuntimeAllowed(rt):
		add("runtime", "runtime %s is not allowed by the platform policy", rt)
	case !c.RuntimeAvailable(rt):
		add("runtime", "runtime %s is not available on this platform", rt)
	}
	if rt == "builtin" && containerOf(s).present {
		add("runtime", "runtime.container is set but runtime.type is builtin; set runtime.type to container or remove the block")
	}
	return container
}

// containerRules checks what a container agent may not set, its toolProfile, and the runtime.container block.
func containerRules(in Input, add func(field, f string, a ...any)) {
	s, p, c := in.Spec, in.P.Policy, in.P.Catalog
	if strings.TrimSpace(s.Instructions) != "" {
		add("instructions", "instructions do not apply to a container agent; configure the agent in its image")
	}
	if len(s.Tools) > 0 {
		add("tools", "tools cannot be listed for a container agent: a container agent gets every tool of its profile; make a narrower profile")
	}
	if s.Egress != nil && len(s.Egress.Allow) > 0 {
		add("egress.allow", "egress.allow is not available yet for container agents")
	}
	if s.Memory != nil && s.Memory.Enabled {
		add("memory", "memory is not available for container agents")
	}
	if s.Knowledge != nil && s.Knowledge.Enabled {
		add("knowledge", "knowledge is not available for container agents")
	}
	if s.Notify != nil && s.Notify.Enabled {
		add("notify", "notify is not available for container agents")
	}
	if len(s.Skills) > 0 {
		add("skills", "skills are not available for container agents")
	}
	if s.ToolProfile != "" {
		prof, ok := c.Profile(s.ToolProfile)
		names := make([]string, len(c.Profiles))
		for i, x := range c.Profiles {
			names[i] = x.Name
		}
		switch {
		case !ok:
			add("toolProfile", "toolProfile %q is not defined (defined: %s)", s.ToolProfile, strings.Join(names, ", "))
		case !p.ProfileAllowed(s.ToolProfile):
			add("toolProfile", "toolProfile %q is not allowed by the platform policy", s.ToolProfile)
		case len(prof.Workload) == 0 || string(prof.Workload) == "null":
			add("toolProfile", "toolProfile %q is not open to container agents (the operator lists such profiles in controlPlane.containerAgents.toolProfiles)", s.ToolProfile)
		}
	}

	cr := containerOf(s)
	if !cr.present {
		add("runtime.container", "runtime.type is container but runtime.container is missing: set image and port")
		return
	}
	switch {
	case !imageRE.MatchString(cr.image):
		add("runtime.container.image", "runtime.container.image %q must be pinned by digest: registry/path@sha256:<64 hex>, with no tag next to the digest", cr.image)
	case !p.ImageAllowed(cr.image):
		add("runtime.container.image", "runtime.container.image %q is not under a registry prefix the platform policy allows", cr.image)
	}
	if !cr.portOK || cr.port < MinPort || cr.port > MaxPort {
		add("runtime.container.port", "runtime.container.port %v must be between %d and %d (the container runs as a non-root user)", s.Runtime["container"].(map[string]any)["port"], MinPort, MaxPort)
	}
	if n := len(cr.env); n > MaxEnvVars {
		add("runtime.container.env", "runtime.container.env has %d entries; at most %d are allowed", n, MaxEnvVars)
	}
	seen := map[string]bool{}
	total := 0
	for _, e := range cr.env {
		total += len(e.name) + len(e.value)
		switch {
		case !envNameRE.MatchString(e.name):
			add("runtime.container.env", "runtime.container.env name %q must match ^[A-Z_][A-Z0-9_]*$", e.name)
			continue
		case seen[e.name]:
			add("runtime.container.env", "runtime.container.env sets %s twice", e.name)
			continue
		}
		seen[e.name] = true
		for _, pre := range ReservedEnvPrefixes {
			if strings.HasPrefix(e.name, pre) {
				add("runtime.container.env", "runtime.container.env name %s is reserved: names that start with %s belong to the platform", e.name, strings.Join(ReservedEnvPrefixes, ", "))
				break
			}
		}
		if len(e.value) > MaxEnvValueLen {
			add("runtime.container.env", "runtime.container.env %s is %d bytes; at most %d", e.name, len(e.value), MaxEnvValueLen)
		}
		for _, sh := range secretShapes {
			if sh.re.MatchString(e.value) {
				add("runtime.container.env", "runtime.container.env %s contains something shaped like a secret (%s); a plain value is not the place for one", e.name, sh.name)
			}
		}
	}
	if total > MaxEnvTotalBytes {
		add("runtime.container.env", "runtime.container.env is %d bytes in all; at most %d", total, MaxEnvTotalBytes)
	}
	if p.Runtimes != nil {
		if max := p.Runtimes.Container.MaxAgents; max > 0 && in.OthersContainer >= max {
			add("name", "the platform policy allows at most %d container agents and %d already exist", max, in.OthersContainer)
		}
	}
}
