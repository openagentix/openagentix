// Package platform reads the two JSON files the controller reads (the platform catalog and the platform policy, mounted
// from ConfigMaps) and turns them into the summary the console shows. Nothing secret is in either file, and fields
// that only the runtime adapter needs (images, worker pool, harness environment) are not copied into the summary.
package platform

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
)

type Profile struct {
	Name       string   `json:"name"`
	ToolServer string   `json:"toolServer"`
	CodeMode   bool     `json:"codeMode"`
	Tools      []string `json:"tools"`
	// Workload is read from the catalog and never copied out: it holds a URL and a token audience. A profile has one when the
	// operator opened it to container agents (ADR 0019); the summary says only that, in ContainerAccess.
	Workload        json.RawMessage `json:"workload,omitempty"`
	ContainerAccess bool            `json:"containerAccess"`
}

type Feature struct {
	Available bool     `json:"available"`
	Tools     []string `json:"tools"`
	Prompt    string   `json:"prompt"`
}

type Memory struct {
	Available      bool   `json:"available"`
	ExpiryEnabled  bool   `json:"expiryEnabled"`
	DefaultTTLDays int    `json:"defaultTtlDays"`
	Prompt         string `json:"prompt"`
}

type Namespaces struct {
	Agents  string `json:"agents"`
	Gateway string `json:"gateway"`
	Tools   string `json:"tools"`
}

type Adapters struct {
	Runtime string `json:"runtime"`
	// Runtimes names the adapter per runtime type; "container" is there only when the operator turned container agents on.
	Runtimes     map[string]string `json:"runtimes,omitempty"`
	ModelGateway string            `json:"modelGateway"`
	Tools        string            `json:"tools"`
}

// ToolsSection is the tools adapter's own part of the catalog: the control plane writes the profiles there.
type ToolsSection struct {
	Toolhive struct {
		Profiles []Profile `json:"profiles"`
	} `json:"toolhive"`
}

// Catalog is what exists on the platform.
type Catalog struct {
	Demo           bool              `json:"demo"`
	Adapters       Adapters          `json:"adapters"`
	Namespaces     Namespaces        `json:"namespaces"`
	GatewayBaseURL string            `json:"gatewayBaseUrl"`
	Models         []string          `json:"models"`
	ToolServer     string            `json:"toolServer"`
	Profiles       []Profile         `json:"profiles"`
	Tools          ToolsSection      `json:"tools"`
	Knowledge      Feature           `json:"knowledge"`
	Notify         Feature           `json:"notify"`
	Memory         Memory            `json:"memory"`
	Skills         map[string]string `json:"skills"`
	GateURL        string            `json:"gateUrl"`
	ReservedNames  []string          `json:"reservedNames"`
}

type PolicyMemory struct {
	Allowed       bool `json:"allowed"`
	MaxTTLDays    int  `json:"maxTtlDays"`
	RequireExpiry bool `json:"requireExpiry"`
}

type PolicyEgress struct {
	AllowedOrigins        []string `json:"allowedOrigins"`
	InClusterDestinations []string `json:"inClusterDestinations"`
}

// Policy is what is allowed.
type Policy struct {
	MaxAgents          int          `json:"maxAgents"`
	AllowedModels      []string     `json:"allowedModels"`
	RequireToolProfile bool         `json:"requireToolProfile"`
	AllowedProfiles    []string     `json:"allowedProfiles"`
	AllowKnowledge     bool         `json:"allowKnowledge"`
	AllowNotify        bool         `json:"allowNotify"`
	AllowedSkills      []string     `json:"allowedSkills"`
	Memory             PolicyMemory `json:"memory"`
	Egress             PolicyEgress `json:"egress"`
	ReservedNames      []string     `json:"reservedNames"`
	// SuspendAll is the operator's stop switch: every definition is treated as suspended.
	SuspendAll bool `json:"suspendAll"`
	// AllowedRuntimes lists the runtime types a definition may use. Absent or empty means only builtin.
	AllowedRuntimes []string `json:"allowedRuntimes,omitempty"`
	// Runtimes is read for the container runtime's image prefixes and agent limit; the summary carries it as Container.
	Runtimes *PolicyRuntimes `json:"runtimes,omitempty"`
}

type PolicyRuntimes struct {
	Container struct {
		Images    []string `json:"images"`
		MaxAgents int      `json:"maxAgents"`
	} `json:"container"`
}

// RuntimeAllowed says whether the policy lets a definition use runtime type t (builtin when none is named).
func (p Policy) RuntimeAllowed(t string) bool {
	if t == "" {
		t = "builtin"
	}
	if len(p.AllowedRuntimes) == 0 {
		return t == "builtin"
	}
	return slices.Contains(p.AllowedRuntimes, t)
}

// ImageAllowed says whether image starts with one of the operator's registry prefixes.
func (p Policy) ImageAllowed(image string) bool {
	if p.Runtimes == nil {
		return false
	}
	for _, pre := range p.Runtimes.Container.Images {
		if pre != "" && strings.HasPrefix(image, pre) {
			return true
		}
	}
	return false
}

// RuntimeAvailable says whether the catalog has an adapter for runtime type t.
func (c Catalog) RuntimeAvailable(t string) bool {
	if a := c.Adapters.Runtimes[t]; a != "" {
		return true
	}
	return t == "builtin" && c.Adapters.Runtime != ""
}

// normalize copies the profiles of the tools adapter's section to Profiles when the catalog has no top-level list.
func (c *Catalog) normalize() {
	if len(c.Profiles) == 0 {
		c.Profiles = c.Tools.Toolhive.Profiles
	}
}

func (c Catalog) Profile(name string) (Profile, bool) {
	for _, p := range c.Profiles {
		if p.Name == name {
			return p, true
		}
	}
	return Profile{}, false
}

// Both is what one read returns.
type Both struct {
	Catalog Catalog
	Policy  Policy
}

// Source returns the current catalog and policy.
type Source interface{ Get() (Both, error) }

// Static is a fixed value (the demo mode and tests).
type Static struct{ Value Both }

func (s Static) Get() (Both, error) { return s.Value, nil }

// Files reads two files, again when either changed (size or modification time, checked on every call).
type Files struct {
	CatalogPath, PolicyPath string

	mu     sync.Mutex
	cached Both
	stamp  [2]stamp
	have   bool
}

type stamp struct {
	m time.Time
	s int64
}

func (f *Files) Get() (Both, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var now [2]stamp
	for i, p := range []string{f.CatalogPath, f.PolicyPath} {
		fi, err := os.Stat(p)
		if err != nil {
			return Both{}, fmt.Errorf("cannot read %s: %w", p, unwrapPath(err))
		}
		now[i] = stamp{fi.ModTime(), fi.Size()}
	}
	if f.have && now == f.stamp {
		return f.cached, nil
	}
	var b Both
	if err := readJSON(f.CatalogPath, &b.Catalog); err != nil {
		return Both{}, err
	}
	if err := readJSON(f.PolicyPath, &b.Policy); err != nil {
		return Both{}, err
	}
	b.Catalog.normalize()
	f.cached, f.stamp, f.have = b, now, true
	return b, nil
}

func unwrapPath(err error) error {
	if pe, ok := err.(*os.PathError); ok {
		return pe.Err
	}
	return err
}

func readJSON(path string, v any) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("cannot read %s: %w", path, unwrapPath(err))
	}
	if err := json.Unmarshal(raw, v); err != nil {
		return fmt.Errorf("%s is not valid JSON: %w", path, err)
	}
	return nil
}

// Summary is GET /api/v1/platform.
type Summary struct {
	Demo           bool       `json:"demo"`
	Adapters       Adapters   `json:"adapters"`
	Namespaces     Namespaces `json:"namespaces"`
	GatewayBaseURL string     `json:"gatewayBaseUrl"`
	GateEnabled    bool       `json:"gateEnabled"`
	Models         []string   `json:"models"`
	ToolServer     string     `json:"toolServer"`
	Profiles       []Profile  `json:"profiles"`
	Knowledge      Feature    `json:"knowledge"`
	Notify         Feature    `json:"notify"`
	Memory         Memory     `json:"memory"`
	Skills         []Skill    `json:"skills"`
	ReservedNames  []string   `json:"reservedNames"`
	Policy         Policy     `json:"policy"`
	// Container is what the builder needs to offer "bring your own agent": whether it is installed, whether the policy
	// allows it, the registry prefixes an image must start with, and the per-namespace limit (0: none).
	Container ContainerInfo `json:"container"`
}

type ContainerInfo struct {
	Available bool     `json:"available"`
	Allowed   bool     `json:"allowed"`
	Images    []string `json:"images"`
	MaxAgents int      `json:"maxAgents"`
}

type Skill struct {
	Name string `json:"name"`
	Ref  string `json:"ref"`
}

func nz[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

// Summarize copies what the console shows. A nil slice becomes an empty one, so the JSON has no nulls.
func Summarize(b Both, demo bool) Summary {
	c, p := b.Catalog, b.Policy
	names := make([]string, 0, len(c.Skills))
	for n := range c.Skills {
		names = append(names, n)
	}
	sort.Strings(names)
	skills := []Skill{}
	for _, n := range names {
		skills = append(skills, Skill{Name: n, Ref: c.Skills[n]})
	}
	c.Knowledge.Tools, c.Notify.Tools = nz(c.Knowledge.Tools), nz(c.Notify.Tools)
	c.normalize()
	profiles := make([]Profile, 0, len(c.Profiles))
	for _, pr := range c.Profiles {
		pr.Tools = nz(pr.Tools)
		pr.ContainerAccess = len(pr.Workload) > 0 && string(pr.Workload) != "null"
		pr.Workload = nil
		profiles = append(profiles, pr)
	}
	ci := ContainerInfo{Available: c.RuntimeAvailable("container"), Allowed: slices.Contains(p.AllowedRuntimes, "container"), Images: []string{}}
	if p.Runtimes != nil {
		ci.Images, ci.MaxAgents = nz(p.Runtimes.Container.Images), p.Runtimes.Container.MaxAgents
	}
	p.Runtimes = nil // carried in Container, not twice
	p.AllowedModels, p.AllowedProfiles, p.AllowedSkills = nz(p.AllowedModels), nz(p.AllowedProfiles), nz(p.AllowedSkills)
	p.Egress.AllowedOrigins, p.ReservedNames = nz(p.Egress.AllowedOrigins), nz(p.ReservedNames)
	p.Egress.InClusterDestinations = nz(p.Egress.InClusterDestinations)
	return Summary{
		Demo: demo || c.Demo, Adapters: c.Adapters, Namespaces: c.Namespaces, GatewayBaseURL: c.GatewayBaseURL,
		GateEnabled: c.GateURL != "", Models: nz(c.Models), ToolServer: c.ToolServer, Profiles: profiles,
		Knowledge: c.Knowledge, Notify: c.Notify, Memory: c.Memory, Skills: skills, ReservedNames: nz(c.ReservedNames), Policy: p, Container: ci,
	}
}

// Allowed helpers used by the prediction rules.
func (p Policy) ModelAllowed(m string) bool   { return slices.Contains(p.AllowedModels, m) }
func (p Policy) ProfileAllowed(n string) bool { return slices.Contains(p.AllowedProfiles, n) }
func (p Policy) SkillAllowed(n string) bool   { return slices.Contains(p.AllowedSkills, n) }

// OriginRE is the shape of an egress origin (the CRD allows up to 270 characters).
var OriginRE = regexp.MustCompile(`^https?://(\*\.)?[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*(:[0-9]{1,5})?$`)
