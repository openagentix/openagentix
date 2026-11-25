package policy

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/openagentix/openagentix/services/control-plane/internal/api"
	"github.com/openagentix/openagentix/services/control-plane/internal/catalog"
)

const (
	MaxEnvVars       = 32
	MaxEnvValueLen   = 4096
	MaxEnvTotalBytes = 16 << 10
	MinPort          = 1024
	MaxPort          = 65535
)

var envNameRE = regexp.MustCompile(`^[A-Z_][A-Z0-9_]*$`)

// ReservedEnvPrefixes belong to the platform: a definition may not set a variable that starts with one.
var ReservedEnvPrefixes = []string{"OPENAGENTIX_", "OPENAI_", "OTEL_", "KUBERNETES_"}

// containerRefusals are the builtin-only features a container agent may not set, one sentence each.
func containerRefusals(s api.Spec, add func(string, ...any)) {
	if strings.TrimSpace(s.Instructions) != "" {
		add("instructions do not apply to a container agent; configure the agent in its image")
	}
	if s.InstructionsFrom != nil {
		add("instructionsFrom does not apply to a container agent; configure the agent in its image")
	}
	if len(s.Tools) > 0 {
		add("tools cannot be listed for a container agent: a container agent gets every tool of its profile; make a narrower profile")
	}
	if s.ToolProfile != "" {
		add("toolProfile is not available yet for container agents")
	}
	if len(s.Egress.Allow) > 0 {
		add("egress.allow is not available yet for container agents")
	}
	if s.Memory.Enabled || s.Memory.TTLDays != 0 {
		add("memory is not available for container agents")
	}
	if s.Knowledge.Enabled || len(s.Knowledge.Collections) > 0 {
		add("knowledge is not available for container agents")
	}
	if s.Notify.Enabled || len(s.Notify.Destinations) > 0 {
		add("notify is not available for container agents")
	}
	if len(s.Skills) > 0 {
		add("skills are not available for container agents")
	}
}

// containerRules checks the runtime.container block against the policy. earlier is how many container agents already
// exist ahead of this one in the namespace.
func containerRules(d *api.AgentDefinition, p *catalog.Policy, earlier int, add func(string, ...any)) {
	cr := d.Spec.Runtime.Container
	if cr == nil {
		add("runtime.type is container but runtime.container is missing: set image and port")
		return
	}
	switch {
	case !catalog.ImageRE.MatchString(cr.Image):
		add("runtime.container.image %q must be pinned by digest: registry/path@sha256:<64 hex>, with no tag next to the digest", cr.Image)
	case !p.ImageAllowed(cr.Image):
		add("runtime.container.image %q is not under a registry prefix the platform policy allows", cr.Image)
	}
	if cr.Port < MinPort || cr.Port > MaxPort {
		add("runtime.container.port %d must be between %d and %d (the container runs as a non-root user)", cr.Port, MinPort, MaxPort)
	}
	if n := len(cr.Env); n > MaxEnvVars {
		add("runtime.container.env has %d entries; at most %d are allowed", n, MaxEnvVars)
	}
	seen := map[string]bool{}
	total := 0
	for _, e := range cr.Env {
		total += len(e.Name) + len(e.Value)
		switch {
		case !envNameRE.MatchString(e.Name):
			add("runtime.container.env name %q must match ^[A-Z_][A-Z0-9_]*$", e.Name)
			continue
		case seen[e.Name]:
			add("runtime.container.env sets %s twice", e.Name)
			continue
		}
		seen[e.Name] = true
		for _, pre := range ReservedEnvPrefixes {
			if strings.HasPrefix(e.Name, pre) {
				add("runtime.container.env name %s is reserved: names that start with %s belong to the platform", e.Name, strings.Join(ReservedEnvPrefixes, ", "))
				break
			}
		}
		if len(e.Value) > MaxEnvValueLen {
			add("runtime.container.env %s is %d bytes; at most %d", e.Name, len(e.Value), MaxEnvValueLen)
		}
		for _, sh := range secretShapes {
			if sh.re.MatchString(e.Value) {
				add("runtime.container.env %s contains something shaped like a secret (%s); a plain value is not the place for one", e.Name, sh.name)
			}
		}
	}
	if total > MaxEnvTotalBytes {
		add("runtime.container.env is %d bytes in all; at most %d", total, MaxEnvTotalBytes)
	}
	resourceRules(cr, p, add)
	if max := p.Runtimes.Container.MaxAgents; max > 0 && earlier >= max {
		add("the platform policy allows at most %d container agents in namespace %q and %d already exist", max, d.Metadata.Namespace, earlier)
	}
}

func resourceRules(cr *api.ContainerRuntime, p *catalog.Policy, add func(string, ...any)) {
	if cr.Resources != nil {
		bad := false
		for _, q := range []struct {
			n string
			l api.ResourceList
		}{{"requests", cr.Resources.Requests}, {"limits", cr.Resources.Limits}} {
			for _, err := range catalog.CheckQuantities("runtime.container.resources."+q.n, q.l) {
				add("%s", err.Error())
				bad = true
			}
		}
		if bad {
			return
		}
	}
	r := p.ResolveContainerResources(cr.Resources)
	max := p.ContainerMax()
	if cpu, mem := catalog.Above(r.Limits, max); cpu || mem {
		if cpu {
			add("runtime.container.resources.limits.cpu %s is above the platform maximum of %s", r.Limits.CPU, max.CPU)
		}
		if mem {
			add("runtime.container.resources.limits.memory %s is above the platform maximum of %s", r.Limits.Memory, max.Memory)
		}
	}
	if cpu, mem := catalog.Above(r.Requests, r.Limits); cpu || mem {
		add("%s", fmt.Sprintf("runtime.container.resources.requests are above the limits (requests cpu %s memory %s, limits cpu %s memory %s)", r.Requests.CPU, r.Requests.Memory, r.Limits.CPU, r.Limits.Memory))
	}
}
