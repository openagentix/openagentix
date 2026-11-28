package rules

import (
	"bufio"
	"os"
	"strings"
	"testing"
)

// The chart's tests list every pattern the chart renders in charts/openagentix/tests/event-patterns-accepted.txt (one per line). A
// pattern the chart renders must never stop the gate from starting, so each must be accepted by the gate's grammar.
func TestEveryPatternTheChartAcceptsIsAcceptedByTheGate(t *testing.T) {
	f, err := os.Open("../../../../charts/openagentix/tests/event-patterns-accepted.txt")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	n := 0
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if strings.TrimSpace(line) == "" || strings.HasPrefix(line, "#") {
			continue
		}
		n++
		if _, err := CompileEventText(line); err != nil {
			t.Errorf("the chart accepts %q but the gate refuses it: %v", line, err)
		}
	}
	if n < 8 {
		t.Fatalf("only %d patterns read", n)
	}
}
