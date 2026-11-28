package mcpserver

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/openagentix/openagentix/services/kb/internal/obs"
)

const toolSchema = `{"version":2,"entityTypes":[{"name":"case","key":"Case DSP-[0-9]{4}","description":"A dispute case"},{"name":"merchant"},{"name":"team"},{"name":"service"}],
"relationTypes":[{"name":"disputes_charge_at","from":["case"],"to":["merchant"],"description":"the case is about a charge"},{"name":"owns","from":["team"],"to":["service"]}]}`

func TestSchemaToolExistsOnlyWhenSchemasAreOn(t *testing.T) {
	off := setupGraph(t, true, axisEmbedder{})
	res, err := off.session.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, tool := range res.Tools {
		if tool.Name == "kb_graph_schema" {
			t.Fatal("kb_graph_schema must not be registered while schemas are off")
		}
	}
	e := newAccessEnv(t, "enforce", true)
	s := e.connect(t, tokBank)
	res, err = s.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	var found *mcp.Tool
	for _, tool := range res.Tools {
		if tool.Name == "kb_graph_schema" {
			found = tool
		}
	}
	if found == nil || found.Annotations == nil || !found.Annotations.ReadOnlyHint || len(found.Description) < 40 {
		t.Fatalf("%+v", found)
	}
}

func TestSchemaToolFollowsTheCollectionFilterInEveryMode(t *testing.T) {
	e := newAccessEnv(t, "enforce", true)
	for _, c := range []string{"bank-coll", "equip-coll"} {
		if _, err := e.svc.PutGraphSchema(context.Background(), c, []byte(toolSchema)); err != nil {
			t.Fatal(err)
		}
	}
	s := e.connect(t, tokBank)
	own, isErr := call(t, s, "kb_graph_schema", map[string]any{"collection": "bank-coll"})
	if isErr || !strings.Contains(own, "Case DSP-[0-9]{4}") || !strings.Contains(own, "disputes_charge_at") || !strings.Contains(own, "version 2") {
		t.Fatalf("own: %q", own)
	}
	// outside the list: byte for byte the answer for a collection that has no schema or does not exist
	outside, outErr := call(t, s, "kb_graph_schema", map[string]any{"collection": "equip-coll"})
	missing, missErr := call(t, s, "kb_graph_schema", map[string]any{"collection": "absent-coll"})
	if outErr || missErr || strings.Contains(outside, "disputes_charge_at") {
		t.Fatalf("outside: %q", outside)
	}
	if strings.ReplaceAll(outside, "equip-coll", "X") != strings.ReplaceAll(missing, "absent-coll", "X") {
		t.Fatalf("outside %q differs from missing %q", outside, missing)
	}
	if !strings.Contains(outside, "no graph schema") || !strings.Contains(outside, "built-in") {
		t.Fatalf("%q", outside)
	}
	// with no collection: only the schemas of the caller's collections
	all, _ := call(t, s, "kb_graph_schema", nil)
	if !strings.Contains(all, "bank-coll") || strings.Contains(all, "equip-coll") {
		t.Fatalf("all: %q", all)
	}
	// a caller that may read nothing sees no schema
	empty := e.connect(t, tokEmpty)
	none, _ := call(t, empty, "kb_graph_schema", nil)
	if strings.Contains(none, "disputes_charge_at") || strings.Contains(none, "bank-coll") || strings.Contains(none, "equip-coll") {
		t.Fatalf("empty: %q", none)
	}
	// no document text or value in a log line
	if strings.Contains(e.logs.String(), "canary") || strings.Contains(e.logs.String(), "disputes_charge_at") {
		t.Fatalf("log: %s", e.logs.String())
	}
}

func TestSchemaToolInReportModeLogsWhatEnforceWouldChange(t *testing.T) {
	e := newAccessEnv(t, "report", true)
	for _, c := range []string{"bank-coll", "equip-coll"} {
		if _, err := e.svc.PutGraphSchema(context.Background(), c, []byte(toolSchema)); err != nil {
			t.Fatal(err)
		}
	}
	s := e.connect(t, tokBank)
	e.logs.Reset()
	txt, _ := call(t, s, "kb_graph_schema", map[string]any{"collection": "equip-coll"})
	if !strings.Contains(txt, "disputes_charge_at") {
		t.Fatalf("report must not filter: %q", txt)
	}
	if l := e.logs.String(); !strings.Contains(l, `"tool":"kb_graph_schema"`) || !strings.Contains(l, `"outside_list":true`) || !strings.Contains(l, `"caller":"bank"`) {
		t.Fatalf("%s", l)
	}
}

func TestSchemaToolIsInTheClosedMetricList(t *testing.T) {
	m := obs.New("test")
	m.ToolCall("kb_graph_schema", "ok", 0)
	rec := httptest.NewRecorder()
	m.Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/metrics", nil))
	if !strings.Contains(rec.Body.String(), `tool="kb_graph_schema"`) {
		t.Fatalf("the tool name must be a label value of its own, not 'other':\n%s", rec.Body.String())
	}
}
