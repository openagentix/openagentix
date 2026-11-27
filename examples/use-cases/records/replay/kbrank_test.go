package replay

import (
	"strings"
	"testing"
)

// The live knowledge base ranked the dispute policy above the scheme rules for the time limit query (the policy points at the rules in one line).
// The scenario must still cite the scheme rules when they are the second result, and must say "needs human review" when they are not in the results.
func kbWith(titles ...string) func(tool, args string) string {
	return func(tool, args string) string {
		if tool != "kb_search" {
			return `{"paths":[]}`
		}
		var rs []string
		for _, t := range titles {
			rs = append(rs, `{"document_id":"d","collection":"fernvale-disputes","title":"`+t+`","text":"fixed answer"}`)
		}
		return `{"results":[` + strings.Join(rs, ",") + `]}`
	}
}

func TestOutOfTimeCitesTheSchemeRulesWhenTheyAreTheSecondResult(t *testing.T) {
	e := newEnv(t)
	e.kb = kbWith("Fernvale Dispute Handling Policy", "Ficticard Scheme Dispute Rules")
	answer := e.run("Work case DSP-2026-0005")
	if !strings.Contains(answer, "I applied Ficticard Scheme Dispute Rules") {
		t.Fatalf("the answer must cite the scheme rules: %s", answer)
	}
}

func TestOutOfTimeSaysNeedsHumanReviewWhenTheSchemeRulesAreNotFound(t *testing.T) {
	e := newEnv(t)
	e.kb = kbWith("Fernvale Dispute Handling Policy", "Fernvale Provisional Credit Rule")
	answer := e.run("Work case DSP-2026-0005")
	if !strings.Contains(strings.ToLower(answer), "needs human review") || strings.Contains(answer, "I applied") {
		t.Fatalf("with no scheme rules in the results the answer must say needs human review and apply nothing: %s", answer)
	}
}
