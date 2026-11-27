package equipment

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// A model cannot know a limit that the tool description does not state; the first real-model run of the bank lost calls to undocumented limits. Every
// field with a limit says it in the description of the tool schema: a maximum length, a range, an id format or the allowed values.
func TestToolDescriptionsStateTheFieldLimits(t *testing.T) {
	d, _ := newDomain(t)
	srv := httptest.NewServer(d.MCPHandler("test"))
	defer srv.Close()
	c := mcp.NewClient(&mcp.Implementation{Name: "t", Version: "1"}, nil)
	sess, err := c.Connect(context.Background(), &mcp.StreamableClientTransport{Endpoint: srv.URL + "/mcp"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer sess.Close()
	list, err := sess.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string][]string{ // property name -> words its description must hold
		"case_id":         {"SVC-"},
		"serial":          {"five digits"},
		"code":            {"E-"},
		"fault_code":      {"E-"},
		"part_id":         {"P-"},
		"from_dealer":     {"D-"},
		"slot_id":         {"SLT-"},
		"approval_id":     {"APR-"},
		"qty":             {"1 to 20"},
		"days":            {"1 to 30"},
		"limit":           {"1 to 50"},
		"cause":           {"200"},
		"text":            {"1000"},
		"summary":         {"1000"},
		"body":            {"4000"},
		"reason":          {"500"},
		"name":            {"lowercase", "20"},
		"due_at":          {"RFC 3339", "400 days"},
		"kind":            {"parts_order_with_claim", "parts_order"},
		"due_within_days": {"400"},
	}
	seen := map[string]bool{}
	for _, tl := range list.Tools {
		raw, _ := json.Marshal(tl.InputSchema)
		var sch struct {
			Properties map[string]struct {
				Description string `json:"description"`
			} `json:"properties"`
		}
		if err := json.Unmarshal(raw, &sch); err != nil {
			t.Fatal(err)
		}
		for name, p := range sch.Properties {
			words, ok := want[name]
			if !ok {
				continue
			}
			seen[name] = true
			for _, w := range words {
				if !strings.Contains(p.Description, w) {
					t.Errorf("tool %s, field %s: the description %q does not say %q", tl.Name, name, p.Description, w)
				}
			}
		}
	}
	for name := range want {
		if !seen[name] {
			t.Errorf("no tool has the field %s (the test list is out of date)", name)
		}
	}
}
