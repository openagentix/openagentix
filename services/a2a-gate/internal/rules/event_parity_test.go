package rules

import (
	"bufio"
	"os"
	"strings"
	"testing"
)

func readPatterns(t *testing.T, name string) []string {
	t.Helper()
	f, err := os.Open("../../../../charts/openagentix/tests/" + name)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var out []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if strings.TrimSpace(line) == "" || strings.HasPrefix(line, "#") {
			continue
		}
		out = append(out, line)
	}
	return out
}

// The chart's tests render every pattern in event-patterns-accepted.txt and require every pattern in event-patterns-refused.txt to fail the
// render. The gate must agree on both lists: a pattern the chart renders must never stop the gate from starting, and a pattern in the refused
// list must be refused by the gate as well, so the two sides cannot drift apart without a test failing.
func TestEveryPatternTheChartAcceptsIsAcceptedByTheGate(t *testing.T) {
	ps := readPatterns(t, "event-patterns-accepted.txt")
	if len(ps) < 8 {
		t.Fatalf("only %d patterns read", len(ps))
	}
	for _, p := range ps {
		if _, err := CompileEventText(p); err != nil {
			t.Errorf("the chart accepts %q but the gate refuses it: %v", p, err)
		}
	}
}

func TestEveryPatternInTheSharedRefusedListIsRefusedByTheGate(t *testing.T) {
	ps := readPatterns(t, "event-patterns-refused.txt")
	if len(ps) < 50 {
		t.Fatalf("only %d patterns read", len(ps))
	}
	for _, p := range ps {
		if re, err := CompileEventText(p); err == nil {
			t.Errorf("the shared list says both sides refuse %q, but the gate accepts it (%v)", p, re)
		}
	}
}

func TestSpacesAndLetterSlotsAreCapped(t *testing.T) {
	ok := []string{"Work case SVC-[0-9]{4}-[0-9]{4}", "a b c d", "[A-Z]{2}-[A-Z]{2}", "[A-Za-z0-9_.:-]{1,64}", "Work case [0-9]{1,64}", "[a-z]{1,12} [a-z]{1,12}"}
	for _, p := range ok {
		if _, err := CompileEventText(p); err != nil {
			t.Errorf("%q: %v", p, err)
		}
	}
	bad := []string{"a b c d e", "[a-z]{1,12} [a-z]{1,12} [a-z]{1,12}", "[A-Z]{2}[a-z]{2}[A-Z]{2}", "([a-z]{1,3}){1,2}[A-Z]{2}[0-9a-f]{2}"}
	for _, p := range bad {
		if _, err := CompileEventText(p); err == nil {
			t.Errorf("%q was accepted", p)
		}
	}
}
