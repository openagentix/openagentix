package catalog

import (
	"errors"
	"fmt"
	"math"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/openagentix/openagentix/services/control-plane/internal/api"
)

// PolicyContainerRuntime is the operator's policy for container agents (policy.runtimes.container, ADR 0015).
type PolicyContainerRuntime struct {
	// Images are registry/repository prefixes, each ending in "/" (for example "ghcr.io/acme/agents/"). Empty allows no image.
	Images           []string         `json:"images"`
	DefaultResources api.Resources    `json:"defaultResources"`
	MaxResources     api.ResourceList `json:"maxResources"`
	// MaxAgents is the most container agents in one namespace, inside the global maxAgents. 0 means no extra limit.
	MaxAgents int `json:"maxAgents"`
}

// PolicyRuntimes holds one section per runtime type that has policy of its own.
type PolicyRuntimes struct {
	Container PolicyContainerRuntime `json:"container"`
}

// The built-in values used where the operator's policy names none. A ceiling is never absent.
var (
	fallbackRequests = api.ResourceList{CPU: "100m", Memory: "256Mi"}
	fallbackLimits   = api.ResourceList{CPU: "500m", Memory: "512Mi"}
	fallbackMax      = api.ResourceList{CPU: "1", Memory: "1Gi"}
)

// Runtime types a catalog or a policy may name.
var knownRuntimes = []string{api.RuntimeBuiltin, api.RuntimeContainer}

// RuntimeAdapter is the adapter name for runtime type t ("" when none). Absent adapters.runtimes means {builtin: adapters.runtime}.
func (c *Catalog) RuntimeAdapter(t string) string {
	if t == "" {
		t = api.RuntimeBuiltin
	}
	if n := c.Adapters.Runtimes[t]; n != "" {
		return n
	}
	if t == api.RuntimeBuiltin {
		return c.Adapters.Runtime
	}
	return ""
}

// RuntimeAvailable reports whether the catalog offers runtime type t.
func (c *Catalog) RuntimeAvailable(t string) bool { return c.RuntimeAdapter(t) != "" }

func (c *Catalog) validateRuntimes() []error {
	var errs []error
	for k := range c.Adapters.Runtimes {
		if !slices.Contains(knownRuntimes, k) {
			errs = append(errs, fmt.Errorf("adapters.runtimes lists the unknown runtime type %q (known: %s)", k, strings.Join(knownRuntimes, ", ")))
		}
	}
	if b, ok := c.Adapters.Runtimes[api.RuntimeBuiltin]; ok && b != c.Adapters.Runtime {
		errs = append(errs, errors.New("adapters.runtimes.builtin must be the same adapter as adapters.runtime"))
	}
	if c.Adapters.Runtimes[api.RuntimeContainer] == "" {
		return errs
	}
	k := c.Runtime.Container
	if k == nil {
		return append(errs, errors.New("runtime.container is required when adapters.runtimes lists container"))
	}
	need := func(name, v string) {
		if strings.TrimSpace(v) == "" {
			errs = append(errs, fmt.Errorf("runtime.container.%s is required", name))
		}
	}
	need("namespace", k.Namespace)
	need("gatewayNamespace", k.GatewayNamespace)
	need("gateNamespace", k.GateNamespace)
	// an empty selector would select every pod: the NetworkPolicy would let the agent reach (or be reached by) everything
	for name, sel := range map[string]map[string]string{"gatewayPodSelector": k.GatewayPodSelector, "gatePodSelector": k.GatePodSelector} {
		if len(sel) == 0 {
			errs = append(errs, fmt.Errorf("runtime.container.%s is required and must name at least one label", name))
		}
		for key, v := range sel {
			if key == "" || v == "" {
				errs = append(errs, fmt.Errorf("runtime.container.%s must not have an empty key or value", name))
			}
		}
	}
	if k.GatewayPort == 0 {
		k.GatewayPort = 8080
	}
	if k.GatewayPort < 1 || k.GatewayPort > 65535 {
		errs = append(errs, errors.New("runtime.container.gatewayPort must be 1..65535"))
	}
	if k.DNSNamespace == "" {
		k.DNSNamespace = "kube-system"
	}
	if k.ImagePullPolicy == "" {
		k.ImagePullPolicy = "Always"
	}
	if k.ImagePullPolicy != "Always" && k.ImagePullPolicy != "IfNotPresent" {
		errs = append(errs, errors.New("runtime.container.imagePullPolicy must be Always or IfNotPresent"))
	}
	k.WorkloadPort = WorkloadServicePort
	// foreign code never shares a namespace with a platform component
	for _, n := range []struct{ what, name string }{{"agents", c.Namespaces.Agents}, {"gateway", c.Namespaces.Gateway}, {"tools", c.Namespaces.Tools}, {"gate", k.GateNamespace}, {"model gateway", k.GatewayNamespace}, {"DNS", k.DNSNamespace}} {
		if k.Namespace != "" && k.Namespace == n.name {
			errs = append(errs, fmt.Errorf("runtime.container.namespace %q must not be the %s namespace: foreign code needs a namespace of its own", k.Namespace, n.what))
		}
	}
	return errs
}

// RuntimeAllowed reports whether a definition may use runtime type t. An absent or empty allowedRuntimes allows builtin only.
func (p *Policy) RuntimeAllowed(t string) bool {
	if t == "" {
		t = api.RuntimeBuiltin
	}
	if len(p.AllowedRuntimes) == 0 {
		return t == api.RuntimeBuiltin
	}
	return allowed(p.AllowedRuntimes, t)
}

// ImageAllowed reports whether image starts with one of the operator's registry prefixes (policy.runtimes.container.images).
func (p *Policy) ImageAllowed(image string) bool {
	for _, pre := range p.Runtimes.Container.Images {
		if pre != "" && strings.HasPrefix(image, pre) {
			return true
		}
	}
	return false
}

func fill(v, fb api.ResourceList) api.ResourceList {
	if v.CPU == "" {
		v.CPU = fb.CPU
	}
	if v.Memory == "" {
		v.Memory = fb.Memory
	}
	return v
}

// ContainerMax is the ceiling per container agent: the operator's, or the built-in one where the operator named none.
func (p *Policy) ContainerMax() api.ResourceList {
	return fill(p.Runtimes.Container.MaxResources, fallbackMax)
}

// ResolveContainerResources gives a container agent its resources: what the definition sets, else the policy defaults, else
// the built-in ones. Requests and limits are always both set.
func (p *Policy) ResolveContainerResources(in *api.Resources) api.Resources {
	d := p.Runtimes.Container.DefaultResources
	def := api.Resources{Requests: fill(d.Requests, fallbackRequests), Limits: fill(d.Limits, fallbackLimits)}
	if in == nil {
		return def
	}
	return api.Resources{Requests: fill(in.Requests, def.Requests), Limits: fill(in.Limits, def.Limits)}
}

var (
	cpuRE = regexp.MustCompile(`^([0-9]{1,15})(m?)$`)
	memRE = regexp.MustCompile(`^([0-9]{1,15})(Ki|Mi|Gi|K|M|G)?$`)
)

// ParseCPU reads a CPU quantity ("100m", "1", "2") as millicores. Only these forms are accepted.
func ParseCPU(s string) (int64, error) {
	m := cpuRE.FindStringSubmatch(s)
	if m == nil {
		return 0, fmt.Errorf("%q is not a CPU quantity (use 100m or 1)", s)
	}
	n, _ := strconv.ParseInt(m[1], 10, 64)
	if m[2] == "" {
		n *= 1000
	}
	return n, nil
}

// ParseMemory reads a memory quantity ("256Mi", "1Gi", "500M", plain bytes) as bytes.
func ParseMemory(s string) (int64, error) {
	m := memRE.FindStringSubmatch(s)
	if m == nil {
		return 0, fmt.Errorf("%q is not a memory quantity (use 256Mi, 1Gi or bytes)", s)
	}
	n, _ := strconv.ParseInt(m[1], 10, 64)
	mult := map[string]int64{"": 1, "Ki": 1 << 10, "Mi": 1 << 20, "Gi": 1 << 30, "K": 1000, "M": 1000000, "G": 1000000000}[m[2]]
	if n > math.MaxInt64/mult {
		return 0, fmt.Errorf("%q is too large", s)
	}
	return n * mult, nil
}

// CheckQuantities checks that every set value of l is a quantity, naming the field as prefix.cpu or prefix.memory.
func CheckQuantities(prefix string, l api.ResourceList) []error {
	var errs []error
	if l.CPU != "" {
		if _, err := ParseCPU(l.CPU); err != nil {
			errs = append(errs, fmt.Errorf("%s.cpu: %w", prefix, err))
		}
	}
	if l.Memory != "" {
		if _, err := ParseMemory(l.Memory); err != nil {
			errs = append(errs, fmt.Errorf("%s.memory: %w", prefix, err))
		}
	}
	return errs
}

// Above reports, one sentence per resource, which values of a are above b (both already checked as quantities).
func Above(a, b api.ResourceList) (cpu, mem bool) {
	if x, err := ParseCPU(a.CPU); err == nil {
		if y, err := ParseCPU(b.CPU); err == nil && x > y {
			cpu = true
		}
	}
	if x, err := ParseMemory(a.Memory); err == nil {
		if y, err := ParseMemory(b.Memory); err == nil && x > y {
			mem = true
		}
	}
	return
}

func (p *Policy) validateRuntimes() []error {
	var errs []error
	for _, t := range p.AllowedRuntimes {
		if t != "*" && !slices.Contains(knownRuntimes, t) {
			errs = append(errs, fmt.Errorf("allowedRuntimes entry %q is not a runtime type (known: %s)", t, strings.Join(knownRuntimes, ", ")))
		}
	}
	c := p.Runtimes.Container
	if c.MaxAgents < 0 {
		errs = append(errs, errors.New("runtimes.container.maxAgents must not be negative"))
	}
	seen := map[string]bool{}
	for _, pre := range c.Images {
		if !imagePrefixRE.MatchString(pre) {
			errs = append(errs, fmt.Errorf("runtimes.container.images entry %q must be a registry prefix with a path and a trailing slash, for example ghcr.io/acme/agents/", pre))
		}
		if seen[pre] {
			errs = append(errs, fmt.Errorf("runtimes.container.images lists %q twice", pre))
		}
		seen[pre] = true
	}
	bad := false
	for _, q := range []struct {
		name string
		l    api.ResourceList
	}{{"defaultResources.requests", c.DefaultResources.Requests}, {"defaultResources.limits", c.DefaultResources.Limits}, {"maxResources", c.MaxResources}} {
		for _, e := range CheckQuantities("runtimes.container."+q.name, q.l) {
			errs = append(errs, e)
			bad = true
		}
	}
	if bad {
		return errs
	}
	def := p.ResolveContainerResources(nil)
	max := p.ContainerMax()
	if cpu, mem := Above(def.Limits, max); cpu || mem {
		errs = append(errs, errors.New("runtimes.container.defaultResources.limits are above runtimes.container.maxResources"))
	}
	if cpu, mem := Above(def.Requests, def.Limits); cpu || mem {
		errs = append(errs, errors.New("runtimes.container.defaultResources.requests are above the limits"))
	}
	return errs
}
