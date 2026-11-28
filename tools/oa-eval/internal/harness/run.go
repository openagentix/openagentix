package harness

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strings"
	"time"
)

// Run sends every case to its agent, one at a time (the audit trail names the caller, not the agent, so cases must
// not overlap), and checks the results. A case that cannot be run (the gate refused, the agent timed out) fails;
// only a bad setup is an error.
func Run(ctx context.Context, cs *CaseSet, cfg Config) (*Report, error) {
	if cfg.GateURL == "" && cfg.AgentURL == "" {
		return nil, errors.New("give a gate URL or an agent URL")
	}
	if cfg.UserID == "" {
		cfg.UserID = "eval:harness"
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = 120 * time.Second
	}
	if cfg.DefaultNS == "" {
		cfg.DefaultNS = "kagent"
	}
	hc := cfg.HTTP
	if hc == nil {
		hc = &http.Client{}
	}
	token, err := readToken(cfg.TokenFile)
	if err != nil {
		return nil, err
	}
	only := map[string]bool{}
	for _, id := range cfg.Only {
		only[id] = true
		found := false
		for _, c := range cs.Cases {
			found = found || c.ID == id
		}
		if !found {
			return nil, fmt.Errorf("no case with id %q in the set", id)
		}
	}
	// check the whole set before sending anything
	for _, c := range cs.Cases {
		if only != nil && len(only) > 0 && !only[c.ID] {
			continue
		}
		if _, err := agentURL(cfg, cs, c); err != nil {
			return nil, fmt.Errorf("case %s: %w", c.ID, err)
		}
	}

	rep := &Report{Version: 1, Mode: "run"}
	refused := false
	for _, c := range cs.Cases {
		if len(only) > 0 && !only[c.ID] {
			continue
		}
		if refused {
			// The model refused an earlier case (its budget is spent, or the provider is down): the rest would be refused too.
			rep.Cases = append(rep.Cases, CaseResult{ID: c.ID, NotRun: true, NotRunReason: "not sent: an earlier case was refused by the model"})
			continue
		}
		r := runCase(ctx, hc, cfg, cs, c, token)
		refused = r.NotRun
		rep.Cases = append(rep.Cases, r)
	}
	for _, r := range rep.Cases {
		rep.Total++
		switch {
		case r.NotRun:
			rep.NotRun++
		case r.Pass:
			rep.Passed++
		default:
			rep.Failed++
		}
	}
	rep.Agreement = agreement(rep.Cases)
	return rep, nil
}

func agentURL(cfg Config, cs *CaseSet, c Case) (string, error) {
	if cfg.AgentURL != "" {
		return cfg.AgentURL, nil
	}
	a := c.Agent
	if a == "" {
		a = cs.Agent
	}
	if a == "" {
		return "", errors.New("no agent: set agent on the case or the set, or give an agent URL")
	}
	ns := cfg.DefaultNS
	if i := strings.Index(a, "/"); i >= 0 {
		ns, a = a[:i], a[i+1:]
	}
	return strings.TrimRight(cfg.GateURL, "/") + "/agents/" + ns + "/" + a, nil
}

func prompt(c Case) string {
	if c.Input != "" {
		return c.Input
	}
	b, _ := json.Marshal(c.Event) // map keys are sorted, so the text is the same every time
	return string(b)
}

func runCase(ctx context.Context, hc *http.Client, cfg Config, cs *CaseSet, c Case, token string) CaseResult {
	res := CaseResult{ID: c.ID, HumanOutcome: c.HumanOutcome, Baseline: c.Baseline}
	url, _ := agentURL(cfg, cs, c)
	user := c.Caller
	if user == "" {
		user = cfg.UserID
	}

	var before []string
	var beforeErr error
	if cfg.AuditSrc != "" {
		before, beforeErr = readAudit(ctx, hc, cfg.AuditSrc, cfg.AuditTokenFile)
	}

	cctx, cancel := context.WithTimeout(ctx, cfg.Timeout)
	start := time.Now()
	ans, err := sendMessage(cctx, hc, url, user, token, prompt(c))
	cancel()
	res.Millis = time.Since(start).Milliseconds()
	if err != nil {
		res.Checks = []Check{{Name: "request", Detail: err.Error()}}
		return res
	}
	res.TaskState = ans.State
	if why := refusalReason(ans.Text); why != "" && ans.State == "TASK_STATE_FAILED" {
		// A model-call error is not the agent's doing, whether it came before the first tool call or in the middle of the case (a budget that runs
		// out during a run). The case is cut off: it is not a pass and not a failure, and the state it left is partial, so it says how many calls it made.
		if cfg.AuditSrc != "" && beforeErr == nil {
			if cfg.AuditSettle > 0 {
				time.Sleep(cfg.AuditSettle)
			}
			if after, aerr := readAudit(ctx, hc, cfg.AuditSrc, cfg.AuditTokenFile); aerr == nil && len(after) >= len(before) {
				why = fmt.Sprintf("%s (%d tool calls before it)", why, len(after)-len(before))
			}
		}
		res.NotRun, res.NotRunReason = true, why
		return res
	}
	sum := sha256.Sum256([]byte(ans.Text))
	res.AnswerSHA = hex.EncodeToString(sum[:])
	if cfg.IncludeAnswers {
		res.Answer = ans.Text
	}

	e := c.Expect
	want := strings.ToUpper(e.State)
	switch {
	case want == "ANY":
	default:
		if want == "" {
			want = "COMPLETED"
		}
		want = "TASK_STATE_" + strings.TrimPrefix(want, "TASK_STATE_")
		res.Checks = append(res.Checks, Check{Name: "state", Pass: ans.State == want, Detail: "expected " + want + ", got " + ans.State})
		if ans.State == want {
			res.Checks[0].Detail = ""
		}
	}
	if e.MaxMillis > 0 {
		res.Checks = append(res.Checks, Check{Name: "max_ms", Pass: res.Millis <= int64(e.MaxMillis), Detail: fmt.Sprintf("took %d ms, limit %d", res.Millis, e.MaxMillis)})
	}
	res.Checks = append(res.Checks, answerChecks(e, ans.Text)...)

	var seen []string
	var auditErr error
	if cfg.AuditSrc == "" {
		auditErr = errors.New("no audit source given (--audit)")
	} else {
		if cfg.AuditSettle > 0 {
			time.Sleep(cfg.AuditSettle) // audit lines are written when a handler returns
		}
		var after []string
		after, auditErr = readAudit(ctx, hc, cfg.AuditSrc, cfg.AuditTokenFile)
		if beforeErr != nil {
			auditErr = beforeErr
		}
		if auditErr == nil {
			if len(after) < len(before) {
				auditErr = errors.New("the audit source shrank during the run")
			} else {
				seen = after[len(before):]
			}
		}
	}
	res.Tools = seen
	res.Checks = append(res.Checks, toolChecks(e, seen, auditErr)...)
	res.Checks = append(res.Checks, stateChecks(ctx, hc, e, cfg.StateBase, cfg.StateTokenFile, ans.Text)...)

	if c.Outcome != nil {
		for _, l := range c.Outcome.Labels {
			if regexp.MustCompile(l.Match).MatchString(ans.Text) {
				res.Outcome = l.Label
				break
			}
		}
	}
	res.Pass = true
	for _, k := range res.Checks {
		res.Pass = res.Pass && k.Pass
	}
	return res
}

// agreement counts how often the agent's outcome equals the human one, next to the recorded baseline.
func agreement(cases []CaseResult) *Agreement {
	a := &Agreement{}
	for _, c := range cases {
		if c.HumanOutcome == "" {
			continue
		}
		a.Cases++
		if c.Outcome == c.HumanOutcome {
			a.Agent++
		}
		if c.Baseline != "" {
			a.BaselineCases++
			if c.Baseline == c.HumanOutcome {
				a.Baseline++
			}
		}
	}
	if a.Cases == 0 {
		return nil
	}
	a.AgentRate = float64(a.Agent) / float64(a.Cases)
	if a.BaselineCases > 0 {
		a.BaselineRate = float64(a.Baseline) / float64(a.BaselineCases)
	}
	return a
}

var reModelError = regexp.MustCompile(`(?i)(\b[45][0-9]{2}\b|too many requests|rate.?limit|quota|unauthori[sz]ed|unavailable|overloaded|chat completion request failed|API error)`)

// refusalReason says why a failed task is an error of the model call (a budget or a provider error), or "" when it is not. The text of a failed task is
// the error of the agent run, short; a long text is an answer, not an error.
func refusalReason(text string) string {
	t := strings.TrimSpace(text)
	if t == "" || len(t) > 400 || !strings.Contains(strings.ToLower(t), "agent run failed") {
		return ""
	}
	if !reModelError.MatchString(t) {
		return ""
	}
	return "the model call was refused: " + t
}
