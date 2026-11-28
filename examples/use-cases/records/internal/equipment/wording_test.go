package equipment

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The first measured real-model runs (two of three runs of the covered fault) wrote "P-10006 is superseded by P-10361, so I ordered the replacement" while they
// also said nothing is ordered yet. The agent drafts an order: only the manager's approval places it. The words that the agent reads (the tool descriptions, the
// text of a refusal, the knowledge base documents, the instructions) must not tell it to "order" something, because it repeats them in its answer.
var inviteOrder = regexp.MustCompile(`(?i)\b(always|never|please|then|and|should|must) order\b|\border (the replacement|its replacement|that part|that instead|from the nearest|from the dealer|one unit|what the repair|P-[0-9]{5}\b)`)

func TestWhatTheAgentReadsNeverTellsItToOrder(t *testing.T) {
	root := filepath.Join("..", "..", "..", "equipment")
	files := []string{"tools.go"}
	for _, f := range []string{"values.yaml", "values-full-demo.yaml"} {
		files = append(files, filepath.Join(root, f))
	}
	kb, err := filepath.Glob(filepath.Join(root, "seed", "kb", "*.md"))
	if err != nil || len(kb) == 0 {
		t.Fatalf("no documents: %v", err)
	}
	files = append(files, kb...)
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for i, line := range strings.Split(string(raw), "\n") {
			if strings.HasPrefix(strings.TrimSpace(line), "//") || strings.Contains(line, "Ignore your previous instructions") { // a comment, or the quoted attack text of the untrusted input rule
				continue
			}
			if m := inviteOrder.FindString(line); m != "" {
				t.Errorf("%s:%d tells the agent to %q: say draft the order, or propose it", filepath.Base(f), i+1, m)
			}
		}
	}
	// the refusal of a superseded part is a tool result: it names the replacement and says to draft the order for it
	d, _ := newDomain(t)
	id := caseOf(t, d, "demo")
	_, err = d.svc.DraftPartsOrder(context.Background(), id, "P-10006", 1, "D-403", "order")
	if err == nil {
		t.Fatal("a superseded part must be refused")
	}
	if inviteOrder.MatchString(err.Error()) || !strings.Contains(err.Error(), "P-10361") || !strings.Contains(err.Error(), "draft") {
		t.Errorf("the refusal reads %q: it must name P-10361 and say to draft the order for it", err.Error())
	}
	// a machine with no telematics: the guide and the instructions say what to do, with the field get_machine now gives
	for _, f := range []string{"seed/kb/fault-code-handling.md", "values.yaml", "values-full-demo.yaml"} {
		raw, _ := os.ReadFile(filepath.Join(root, f))
		if !strings.Contains(string(raw), "has_telemetry") {
			t.Errorf("%s does not say what to do when has_telemetry is false", f)
		}
	}
	// the instructions say how to word a draft
	for _, f := range []string{"values.yaml", "values-full-demo.yaml"} {
		raw, _ := os.ReadFile(filepath.Join(root, f))
		for _, w := range []string{"drafted", "proposed", "never ordered"} {
			if !strings.Contains(string(raw), w) {
				t.Errorf("%s: the instructions do not say %q about how to word what waits for approval", f, w)
			}
		}
	}
}
