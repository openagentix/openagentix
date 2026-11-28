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

// A class that holds exactly the two cases of one letter is parsed by Go into a case-folded literal. The gate accepts that, and nothing else
// that folds case, and the match is still only those two cases.
func TestCaseClassIsAccepted(t *testing.T) {
	re, err := CompileEventText(`Work case [Ww][0-9]{4}`)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range []string{"Work case W1234", "Work case w1234"} {
		if !re.MatchString(s) {
			t.Errorf("should match %q", s)
		}
	}
	for _, s := range []string{"Work case x1234", "work case W1234", "Work case W123", "Work case WW1234", "Work case \u212a1234"} {
		if re.MatchString(s) {
			t.Errorf("should not match %q", s)
		}
	}
	re2, err := CompileEventText(`[Aa]bc-[0-9]{2}`)
	if err != nil {
		t.Fatal(err)
	}
	for s, want := range map[string]bool{"Abc-12": true, "abc-12": true, "ABC-12": false, "aBc-12": false, "bbc-12": false} {
		if re2.MatchString(s) != want {
			t.Errorf("%q: match %v, want %v", s, !want, want)
		}
	}
	// the match used for a message text is ASCII only, so the Kelvin sign, which Go folds with k, never matches
	ev := &Event{Text: `[Kk]-[0-9]{2}`}
	k, err := CompileEventText(`[Kk]-[0-9]{2}`)
	if err != nil {
		t.Fatal(err)
	}
	ev.re = k
	if !ev.Match("K-12") || !ev.Match("k-12") || ev.Match("\u212a-12") {
		t.Error("Event.Match must accept both cases of k and refuse the Kelvin sign")
	}
	for _, p := range []string{`(?i)abc`, `(?i:abc)`, `(?i)[a-z]{3}`} {
		if _, err := CompileEventText(p); err == nil {
			t.Errorf("%q was accepted", p)
		}
	}
}

func TestEveryLetterClassCountsTowardsTheCap(t *testing.T) {
	p := strings.Repeat("[a-z_]", 40)
	if _, err := CompileEventText(p); err == nil {
		t.Error("40 single letter classes were accepted")
	}
	if _, err := CompileEventText("[a-z_][a-z_]"); err != nil {
		t.Errorf("two letter classes: %v", err)
	}
	if _, err := CompileEventText("[a-z_][a-z_][a-z_]"); err == nil {
		t.Error("three letter classes were accepted")
	}
}
