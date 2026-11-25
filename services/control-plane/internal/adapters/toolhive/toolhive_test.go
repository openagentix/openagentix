package toolhive

import (
	"strings"
	"testing"

	"github.com/openagentix/openagentix/services/control-plane/internal/catalog"
)

func load(t *testing.T) *catalog.Catalog {
	t.Helper()
	cat, err := catalog.LoadCatalog("../../../testdata/catalog.json")
	if err != nil {
		t.Fatal(err)
	}
	return cat
}

func TestResolvesProfilesFromCatalog(t *testing.T) {
	var r catalog.ToolResolver = New(load(t))
	p, ok := r.Profile("lookup")
	if !ok || p.Backend != "toolhive-vmcp-lookup" || len(p.Tools) != 4 || p.Name != "lookup" {
		t.Fatalf("%+v %v", p, ok)
	}
	if _, ok := r.Profile("nope"); ok {
		t.Fatal("unknown profile must not resolve")
	}
	if got := r.Profiles(); len(got) != 1 || got[0] != "lookup" {
		t.Fatal(got)
	}
}

func TestProfileIsACopy(t *testing.T) {
	cat := &catalog.Catalog{Tools: catalog.ToolSections{Toolhive: &catalog.ToolhiveSettings{Profiles: []catalog.ToolhiveProfile{{Name: "a", Tools: []string{"x"}}}}}}
	p, _ := New(cat).Profile("a")
	p.Tools[0] = "changed"
	if cat.Tools.Toolhive.Profiles[0].Tools[0] != "x" {
		t.Fatal("caller can change the catalog")
	}
}

// A profile the operator opened to container agents carries its workload access (ADR 0019), as a copy; others carry none.
func TestWorkloadAccessIsPassedOnAsACopy(t *testing.T) {
	w := &catalog.WorkloadAccess{URL: "http://vmcp-x.mcp-tools.svc.cluster.local:4483/mcp", Audience: "aud-x", Namespace: "mcp-tools", PodSelector: map[string]string{"a": "b"}, Port: 4483}
	cat := &catalog.Catalog{Tools: catalog.ToolSections{Toolhive: &catalog.ToolhiveSettings{Profiles: []catalog.ToolhiveProfile{
		{Name: "open", Tools: []string{"x"}, Workload: w}, {Name: "closed", Tools: []string{"x"}},
	}}}}
	r := New(cat)
	p, _ := r.Profile("open")
	if p.Workload == nil || p.Workload.URL != w.URL || p.Workload.Audience != "aud-x" || p.Workload.Port != 4483 {
		t.Fatalf("%+v", p.Workload)
	}
	p.Workload.PodSelector["a"] = "changed"
	p.Workload.URL = "changed"
	if w.PodSelector["a"] != "b" || w.URL == "changed" {
		t.Fatal("caller can change the catalog")
	}
	if q, _ := r.Profile("closed"); q.Workload != nil {
		t.Fatal("a profile not opened to container agents has no workload access")
	}
}

// The code-mode tool name and the wording about the aggregating server are this adapter's, not the policy's.
func TestMissingExplainsWhyAToolIsNotOffered(t *testing.T) {
	cat := load(t)
	r := New(cat)
	p, _ := r.Profile("lookup")
	got := r.Missing(p, "fetch_fetch")
	if !strings.Contains(got, `tool "fetch_fetch" which is not in profile "lookup"`) || !strings.Contains(got, "knowledge_kb_search") {
		t.Fatal(got)
	}
	// a profile without code mode that is asked for the code-mode tool gets the specific hint
	cat.Tools.Toolhive.Profiles[0].CodeMode = false
	cat.Tools.Toolhive.Profiles[0].Tools = cat.Tools.Toolhive.Profiles[0].Tools[:3]
	p, _ = New(cat).Profile("lookup")
	got = New(cat).Missing(p, "execute_tool_script")
	if !strings.Contains(got, `"execute_tool_script" but profile "lookup" has codeMode off`) {
		t.Fatal(got)
	}
	// the name comes from the catalog
	cat.Tools.Toolhive.CodeModeTool = "run_script"
	if !strings.Contains(New(cat).Missing(p, "run_script"), "codeMode off") || strings.Contains(New(cat).Missing(p, "execute_tool_script"), "codeMode off") {
		t.Fatal("the code-mode tool name is catalog data")
	}
}
