package backend

import (
	"encoding/json"
	"strings"
	"testing"
)

// ADR 0029, slice 4: status.budget.class is shown read only, in the detail and in the YAML, and is never part of what the console writes back.
func TestDetailShowsTheBudgetClassOfTheStatus(t *testing.T) {
	for _, class := range []string{"bank-agents", "default", "unknown"} {
		var d Definition
		raw := `{"metadata":{"name":"a","namespace":"kagent"},"spec":{"model":"m","instructions":"x"},"status":{"budget":{"class":"` + class + `"}}}`
		if err := json.Unmarshal([]byte(raw), &d); err != nil {
			t.Fatal(err)
		}
		det := BuiltDetail(d)
		if det.Status == nil || det.Status.Budget == nil || det.Status.Budget.Class != class {
			t.Fatalf("%s: %+v", class, det.Status)
		}
		b, _ := json.Marshal(det.Status)
		if !strings.Contains(string(b), `"budget":{"class":"`+class+`"}`) {
			t.Fatalf("%s: %s", class, b)
		}
		if !strings.Contains(det.YAML, "budget:") || !strings.Contains(det.YAML, "class: "+class) {
			t.Fatalf("%s: not in the YAML view:\n%s", class, det.YAML)
		}
	}
	var none Definition
	_ = json.Unmarshal([]byte(`{"metadata":{"name":"a","namespace":"kagent"},"spec":{"model":"m","instructions":"x"}}`), &none)
	if det := BuiltDetail(none); det.Status.Budget != nil || strings.Contains(det.YAML, "budget:") {
		t.Fatal("a definition with no status.budget shows none")
	}
}
