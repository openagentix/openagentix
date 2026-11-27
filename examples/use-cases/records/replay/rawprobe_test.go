package replay

import (
	"strings"
	"testing"
)

// The live run shows the raw tool results as the agent runtime hands them to the model (a read-only probe): the scenario reads two tools and answers with
// both results as they came. It changes nothing.
func TestRawResultProbeShowsTheToolResultsAndChangesNothing(t *testing.T) {
	e := newEnv(t)
	answer := e.run("Show the raw results of DSP-2026-0002")
	requireOrder(t, e.called, "records_get_case", "knowledge-disputes_kb_search")
	if len(e.called) != 2 {
		t.Fatalf("the probe reads two tools and no more: %v", e.called)
	}
	for _, want := range []string{"RAW0 ", "DSP-2026-0002", "RAW1 ", "Fernvale Dispute Handling Policy"} {
		if !strings.Contains(answer, want) {
			t.Errorf("the answer must show the raw results (missing %q): %s", want, answer)
		}
	}
	if strings.Contains(answer, "<missing") {
		t.Errorf("a placeholder did not resolve: %s", answer)
	}
	if n := e.count("/ledger", "ledger"); n != 0 {
		t.Fatalf("ledger rows: %d", n)
	}
	if n := e.count("/approvals", "approvals"); n != 0 {
		t.Fatalf("approvals: %d", n)
	}
}
