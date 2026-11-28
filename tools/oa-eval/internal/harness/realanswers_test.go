package harness

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Real answers of a real model (claude-haiku, first measured run) against the answer checks of the sets for a real model. A file named
// <use case>__<case id>__ok-N.txt is a good answer: no answer check may fail it. <use case>__<case id>__bad-N.txt is an answer that does what the set
// forbids: some answer check must fail it. This keeps a check from failing a good answer, which a unit test of the matcher alone cannot show.

var realSets = map[string]string{
	"bank":         "../../../../examples/use-cases/bank/eval/cases-real.yaml",
	"equipment":    "../../../../examples/use-cases/equipment/eval/cases-real.yaml",
	"software-org": "../../../../examples/use-cases/software-org/eval/cases-real.yaml",
}

func TestRealAnswersAgainstTheAnswerChecksOfTheRealSets(t *testing.T) {
	files, err := filepath.Glob("testdata/real-answers/*.txt")
	if err != nil || len(files) == 0 {
		t.Fatalf("no answers in testdata/real-answers: %v", err)
	}
	for _, f := range files {
		parts := strings.Split(strings.TrimSuffix(filepath.Base(f), ".txt"), "__")
		if len(parts) != 3 {
			t.Fatalf("%s: want <use case>__<case id>__<ok|bad>-N.txt", f)
		}
		uc, id, kind := parts[0], parts[1], strings.SplitN(parts[2], "-", 2)[0]
		set, ok := realSets[uc]
		if !ok {
			t.Fatalf("%s: unknown use case %q", f, uc)
		}
		cs, err := LoadCases(set)
		if err != nil {
			t.Fatal(err)
		}
		var c *Case
		for i := range cs.Cases {
			if cs.Cases[i].ID == id {
				c = &cs.Cases[i]
			}
		}
		if c == nil {
			t.Fatalf("%s: the set has no case %q", f, id)
		}
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		var failed []string
		for _, k := range answerChecks(c.Expect, string(b)) {
			if !k.Pass {
				failed = append(failed, k.Name+": "+k.Detail)
			}
		}
		switch kind {
		case "ok":
			if len(failed) > 0 {
				t.Errorf("%s: a good answer fails the set: %v", filepath.Base(f), failed)
			}
		case "bad":
			if len(failed) == 0 {
				t.Errorf("%s: an answer that does what the set forbids passes every answer check", filepath.Base(f))
			}
		default:
			t.Errorf("%s: kind must be ok or bad", f)
		}
	}
}
