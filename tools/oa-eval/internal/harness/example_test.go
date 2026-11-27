package harness

import "testing"

// The example set is shown in the docs, so it must load and pass the same checks as any other set.
func TestExampleSetLoads(t *testing.T) {
	cs, err := LoadCases("../../examples/cases.yaml")
	if err != nil {
		t.Fatal(err)
	}
	if len(cs.Cases) != 4 {
		t.Fatalf("cases: %d", len(cs.Cases))
	}
}
