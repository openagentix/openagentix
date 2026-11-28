package harness

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
	"text/tabwriter"
)

// WriteTable prints the pass/fail table. It shows check names, never answers or values.
func (r *Report) WriteTable(w io.Writer) {
	tw := tabwriter.NewWriter(w, 0, 4, 2, ' ', 0)
	fmt.Fprintln(tw, "CASE\tRESULT\tTASK\tMS\tFAILED CHECKS")
	for _, c := range r.Cases {
		res := "PASS"
		if c.NotRun {
			res = "NOT RUN"
		} else if !c.Pass {
			res = "FAIL"
			if c.NoCause {
				res = "FAIL (cause not recorded)"
			}
		}
		var bad []string
		for _, k := range c.Checks {
			if !k.Pass {
				bad = append(bad, k.Name)
			}
		}
		if c.NotRun {
			bad = []string{c.NotRunReason}
		}
		fmt.Fprintf(tw, "%s\t%s\t%s\t%d\t%s\n", c.ID, res, strings.TrimPrefix(c.TaskState, "TASK_STATE_"), c.Millis, strings.Join(bad, ", "))
	}
	_ = tw.Flush()
	fmt.Fprintf(w, "\n%d cases: %d passed, %d failed", r.Total, r.Passed, r.Failed)
	if r.NoCause > 0 {
		fmt.Fprintf(w, " (%d of them ended as a failed task with no cause recorded: not a check failure, and not known to be the agent's fault)", r.NoCause)
	}
	if r.NotRun > 0 {
		fmt.Fprintf(w, ", %d not run (the model refused a call: a spent budget or a provider error; they are not counted as failures)", r.NotRun)
	}
	fmt.Fprintln(w)
	if a := r.Agreement; a != nil {
		fmt.Fprintf(w, "agreement with the people: agent %d of %d (%.0f%%)", a.Agent, a.Cases, a.AgentRate*100)
		if a.BaselineCases > 0 {
			fmt.Fprintf(w, ", rules-only baseline %d of %d (%.0f%%)", a.Baseline, a.BaselineCases, a.BaselineRate*100)
		}
		fmt.Fprintln(w)
	}
}

// Failures lists each failed check with its detail, for the lines under the table.
func (r *Report) Failures(w io.Writer) {
	for _, c := range r.Cases {
		for _, k := range c.Checks {
			if !k.Pass {
				if k.Detail != "" {
					fmt.Fprintf(w, "  %s: %s: %s\n", c.ID, k.Name, k.Detail)
				} else {
					fmt.Fprintf(w, "  %s: %s\n", c.ID, k.Name)
				}
			}
		}
	}
}

// WriteFile writes the JSON report.
func (r *Report) WriteFile(path string) error {
	b, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(b, '\n'), 0o644)
}

// LoadReport reads a report written by an earlier run.
func LoadReport(path string) (*Report, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var r Report
	if err := json.Unmarshal(b, &r); err != nil {
		return nil, fmt.Errorf("%s: not a report: %w", path, err)
	}
	if r.Version != 1 {
		return nil, fmt.Errorf("%s: report version %d is not supported", path, r.Version)
	}
	return &r, nil
}

func failedNames(c CaseResult) string {
	var n []string
	for _, k := range c.Checks {
		if !k.Pass {
			n = append(n, k.Name)
		}
	}
	return strings.Join(n, ",")
}

// Compare diffs a recorded report against a new run of the same set. A regression is a case that passed and now
// fails. A changed case passes or fails as before but its answer, its outcome or its failed checks are not the same.
// A drop of the agreement rate is flagged on its own.
func Compare(old, cur *Report) *Diff {
	d := &Diff{}
	prev := map[string]CaseResult{}
	for _, c := range old.Cases {
		prev[c.ID] = c
	}
	seen := map[string]bool{}
	for _, c := range cur.Cases {
		seen[c.ID] = true
		o, ok := prev[c.ID]
		switch {
		case c.NotRun:
			d.Changes = append(d.Changes, Change{ID: c.ID, Kind: "not_run", Detail: c.NotRunReason})
		case !ok:
			d.Changes = append(d.Changes, Change{ID: c.ID, Kind: "new"})
		case o.Pass && !c.Pass:
			d.Regressions++
			d.Changes = append(d.Changes, Change{ID: c.ID, Kind: "regression", Detail: "now failing: " + failedNames(c)})
		case !o.Pass && c.Pass:
			d.Changes = append(d.Changes, Change{ID: c.ID, Kind: "fixed"})
		default:
			var why []string
			if o.AnswerSHA != c.AnswerSHA {
				why = append(why, "answer differs")
			}
			if o.Outcome != c.Outcome {
				why = append(why, "outcome "+o.Outcome+" -> "+c.Outcome)
			}
			if failedNames(o) != failedNames(c) {
				why = append(why, "failed checks differ")
			}
			if len(why) == 0 {
				d.Changes = append(d.Changes, Change{ID: c.ID, Kind: "same"})
			} else {
				d.Changes = append(d.Changes, Change{ID: c.ID, Kind: "changed", Detail: strings.Join(why, "; ")})
			}
		}
	}
	for _, o := range old.Cases {
		if !seen[o.ID] {
			d.Changes = append(d.Changes, Change{ID: o.ID, Kind: "missing", Detail: "in the recorded report, not in this run"})
		}
	}
	if old.Agreement != nil && cur.Agreement != nil && cur.Agreement.AgentRate < old.Agreement.AgentRate {
		d.AgreementDrop = true
		d.AgreementNote = fmt.Sprintf("agreement fell from %.0f%% to %.0f%%", old.Agreement.AgentRate*100, cur.Agreement.AgentRate*100)
	}
	return d
}

// Write prints the diff, one line per case that is not the same, then a summary.
func (d *Diff) Write(w io.Writer) {
	same := 0
	for _, c := range d.Changes {
		if c.Kind == "same" {
			same++
			continue
		}
		fmt.Fprintf(w, "%-10s %s", strings.ToUpper(c.Kind), c.ID)
		if c.Detail != "" {
			fmt.Fprintf(w, "  (%s)", c.Detail)
		}
		fmt.Fprintln(w)
	}
	fmt.Fprintf(w, "%d unchanged, %d regressions\n", same, d.Regressions)
	if d.AgreementDrop {
		fmt.Fprintln(w, "AGREEMENT DROP: "+d.AgreementNote)
	}
}
