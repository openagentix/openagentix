// Package toolhive is the Tools adapter. In this version it is catalog-backed: the chart renders the profiles and the
// names of the tool servers ToolHive serves into the adapter's own section of the catalog (tools.toolhive), and this
// adapter only looks them up. It writes nothing. Facts that are ToolHive's (the code-mode tool, the wording about what a
// profile's virtual MCP server offers) live here and not in the policy.
package toolhive

import (
	"fmt"
	"maps"
	"slices"
	"strings"

	"github.com/openagentix/openagentix/services/control-plane/internal/catalog"
)

type Adapter struct{ s *catalog.ToolhiveSettings }

// New returns the adapter over a loaded catalog.
func New(c *catalog.Catalog) *Adapter {
	if c.Tools.Toolhive == nil {
		return &Adapter{s: &catalog.ToolhiveSettings{}}
	}
	return &Adapter{s: c.Tools.Toolhive}
}

// Profile resolves a profile to the tool server that serves it (the opaque Backend) and the tool names it offers (a copy).
func (a *Adapter) Profile(name string) (catalog.ToolProfile, bool) {
	p, ok := a.s.Profile(name)
	if !ok {
		return catalog.ToolProfile{}, false
	}
	out := catalog.ToolProfile{Name: p.Name, Backend: p.ToolServer, Tools: slices.Clone(p.Tools)}
	if w := p.Workload; w != nil {
		out.Workload = &catalog.WorkloadAccess{URL: w.URL, Audience: w.Audience, Namespace: w.Namespace, PodSelector: maps.Clone(w.PodSelector), Port: w.Port}
	}
	return out, true
}

func (a *Adapter) Profiles() []string {
	var n []string
	for _, p := range a.s.Profiles {
		n = append(n, p.Name)
	}
	return n
}

// Missing says why the profile does not offer the tool: either the tool is not one of the profile's, or it is the
// code-mode tool and the profile has code mode off.
func (a *Adapter) Missing(p catalog.ToolProfile, tool string) string {
	if tool == a.s.CodeModeTool {
		return fmt.Sprintf("the definition lists tool %q but profile %q has codeMode off (set codeMode: true on the profile)", tool, p.Name)
	}
	return fmt.Sprintf("the definition lists tool %q which is not in profile %q (the profile offers: %s)", tool, p.Name, strings.Join(p.Tools, ", "))
}
