package equipment

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"testing"

	"github.com/openagentix/openagentix/examples/use-cases/records/internal/core"
)

// One rule for a coolant rise, stated the same way everywhere and computable from what the agent can read. The first real-model run stopped before the order
// because the bulletin said "the last 14 days ... 8 degrees" while the telemetry the agent could read showed about 5.7, and the sweep compared the last 14 days with
// 30 to 60 days ago, which no tool serves (get_telemetry reaches back 30 days). The rule: the mean of the last R days minus the mean of days B1 to B2 ago, inside
// the 30 days of get_telemetry, at or above T degrees.
var riseRule = regexp.MustCompile(`mean\s+coolant\s+temperature\s+of\s+the\s+last\s+([0-9]+)\s+days\s+with\s+the\s+mean\s+of\s+days\s+([0-9]+)\s+to\s+([0-9]+)\s+ago\.\s+A\s+rise\s+of\s+([0-9]+)\s+degrees\s+or\s+more`)

func TestCoolantRiseRuleIsOneRuleAndTheSeedSatisfiesIt(t *testing.T) {
	d, _ := newDomain(t)
	root := filepath.Join("..", "..", "..", "equipment")
	var recent, b1, b2, thr int
	for i, f := range []string{"seed/kb/bulletin-sb-2026-011.md", "seed/kb/fault-code-handling.md", "values.yaml", "values-full-demo.yaml"} {
		raw, err := os.ReadFile(filepath.Join(root, f))
		if err != nil {
			t.Fatal(err)
		}
		m := riseRule.FindStringSubmatch(string(raw))
		if m == nil {
			t.Errorf("%s does not state the rise rule in the words of the rule (mean coolant temperature of the last R days with the mean of days B1 to B2 ago. A rise of T degrees or more)", f)
			continue
		}
		var got [4]int
		for k := 0; k < 4; k++ {
			got[k], _ = strconv.Atoi(m[k+1])
		}
		if i == 0 {
			recent, b1, b2, thr = got[0], got[1], got[2], got[3]
		} else if got != [4]int{recent, b1, b2, thr} {
			t.Errorf("%s states the rule as %v, the bulletin as %v", f, got, [4]int{recent, b1, b2, thr})
		}
	}
	if recent == 0 {
		t.Fatal("the bulletin states no rule")
	}
	if b2 > 30 {
		t.Errorf("the baseline reaches %d days back, but get_telemetry serves at most 30", b2)
	}
	if recent != RecentDays || b1 != BaselineFromDays || b2 != BaselineToDays || float64(thr) != TrendThresholdC {
		t.Errorf("the sweep rule in the code (%d days, days %d to %d, %.0f degrees) differs from the bulletin (%d, %d to %d, %d)", RecentDays, BaselineFromDays, BaselineToDays, TrendThresholdC, recent, b1, b2, thr)
	}
	rise := func(serial string) float64 {
		var r, b float64
		now := d.clock()
		if err := d.db.QueryRow(`SELECT (SELECT AVG(coolant_c) FROM telemetry WHERE machine=? AND ts>=?), (SELECT AVG(coolant_c) FROM telemetry WHERE machine=? AND ts>=? AND ts<?)`,
			serial, core.FormatTime(now.AddDate(0, 0, -recent)), serial, core.FormatTime(now.AddDate(0, 0, -b2)), core.FormatTime(now.AddDate(0, 0, -b1))).Scan(&r, &b); err != nil {
			t.Fatal(err)
		}
		return r - b
	}
	// the covered-fault machine clearly satisfies it, the flapping-sensor machine and an ordinary one clearly do not
	if r := rise("KH4120-00317"); r < float64(thr)+4 {
		t.Errorf("KH4120-00317 rises %.1f degrees by the bulletin's rule: not clearly (4 degrees) at or above %d", r, thr)
	}
	if r := rise("KH4120-00310"); r > float64(thr)-4 {
		t.Errorf("KH4120-00310 (the flapping sensor) rises %.1f degrees by the bulletin's rule: not clearly below %d", r, thr)
	}
	if r := rise("KH4120-00301"); r > float64(thr)-4 {
		t.Errorf("KH4120-00301 (an ordinary machine) rises %.1f degrees by the bulletin's rule", r)
	}
	// the sweep says the same
	trends, err := d.svc.FleetTrends(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, tr := range trends {
		want := rise(tr.Serial)
		if diff := tr.TrendC - want; diff > 0.06 || diff < -0.06 {
			t.Errorf("%s: the sweep reads a rise of %.1f, the bulletin's rule gives %.1f", tr.Serial, tr.TrendC, want)
		}
	}
}
