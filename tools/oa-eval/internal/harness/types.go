// Package harness runs an evaluation set against an agent through the A2A gate and checks the results with plain
// code, outside the model. A case says what to send and what must be true afterwards: the task state, the tools
// the agent called, the state of the system of record, and properties of the answer.
package harness

import (
	"net/http"
	"time"
)

// CaseSet is one evaluation set (a file).
type CaseSet struct {
	Version int    `yaml:"version"`
	Agent   string `yaml:"agent"` // default agent for the cases: "name" or "namespace/name" (with a gate URL)
	Cases   []Case `yaml:"cases"`
}

// Case is one input and what must hold after the run.
type Case struct {
	ID     string         `yaml:"id"`
	Agent  string         `yaml:"agent"`
	Caller string         `yaml:"caller"` // X-User-Id for this case; the run default when empty
	Input  string         `yaml:"input"`  // the prompt
	Event  map[string]any `yaml:"event"`  // or an input event, sent as JSON text
	Expect Expect         `yaml:"expect"`

	// Replay fields. HumanOutcome is what the people decided. Baseline is what a rules-only baseline predicts.
	// Outcome says how to read the agent's outcome from its answer.
	HumanOutcome string       `yaml:"human_outcome"`
	Baseline     string       `yaml:"baseline_outcome"`
	Outcome      *OutcomeRule `yaml:"outcome"`
}

// OutcomeRule reads a label from the answer: the first regular expression that matches gives its label.
type OutcomeRule struct {
	Labels []LabelRule `yaml:"labels"`
}

// LabelRule maps an answer pattern to a label.
type LabelRule struct {
	Label string `yaml:"label"`
	Match string `yaml:"match"`
}

// Expect lists the machine checks. An empty list or field means no check of that kind.
type Expect struct {
	State         string         `yaml:"state"`           // A2A task state; default TASK_STATE_COMPLETED; "any" skips the check
	AnswerMust    []string       `yaml:"answer_must"`     // regular expressions that must match the answer
	AnswerMustNot []string       `yaml:"answer_must_not"` // regular expressions that must not match
	Cites         []string       `yaml:"cites"`           // titles that must appear in the answer
	ToolsCalled   []string       `yaml:"tools_called"`    // tool names that must be in the audit events of this run
	ToolsNot      []string       `yaml:"tools_not_called"`
	ToolOrder     []string       `yaml:"tool_order"`   // these tools must appear in this order (others may sit between)
	Requires      []ApprovalRule `yaml:"requires"`     // a tool may be called only after another one was
	StateChecks   []StateCheck   `yaml:"state_checks"` // reads of the system of record after the run
	MaxMillis     int            `yaml:"max_ms"`
	MaxToolCalls  int            `yaml:"max_tool_calls"` // at most this many tool calls (audit events) in the run; needs an audit source
}

// ApprovalRule: Tool must not be called unless After was called earlier in the same run (After is the approval tool).
// If Tool is not called at all the rule holds.
type ApprovalRule struct {
	Tool  string `yaml:"tool"`
	After string `yaml:"after"`
}

// StateCheck reads one URL (relative to the state base) and tests one value. Exactly one test is given.
type StateCheck struct {
	URL     string `yaml:"url"`
	Path    string `yaml:"path"`    // dot path into the JSON answer, e.g. items.0.status; empty is the whole body
	Equals  any    `yaml:"equals"`  // the value must equal this
	Matches string `yaml:"matches"` // the value, as text, must match this regular expression
	Count   *int   `yaml:"count"`   // the value is an array or object with this many entries
	Exists  *bool  `yaml:"exists"`  // the path exists (true) or does not (false)
}

// Config says where and how to run.
type Config struct {
	GateURL        string // base URL of the A2A gate; the agent is GateURL/agents/<namespace>/<name>
	AgentURL       string // or one full agent URL
	DefaultNS      string // namespace when an agent is given as a bare name; default "kagent"
	UserID         string
	TokenFile      string
	AuditSrc       string        // a file of JSON lines, or an http(s) URL that returns a JSON array or JSON lines
	AuditTokenFile string        // bearer token for an audit URL
	AuditSettle    time.Duration // wait after a call before reading the audit (lines are written when a handler returns)
	StateBase      string
	StateTokenFile string
	Timeout        time.Duration
	IncludeAnswers bool
	Only           []string // run only these case ids
	HTTP           *http.Client
}

// Check is the result of one machine check.
type Check struct {
	Name   string `json:"name"`
	Pass   bool   `json:"pass"`
	Detail string `json:"detail,omitempty"`
}

// CaseResult is the outcome of one case.
type CaseResult struct {
	ID           string   `json:"id"`
	Pass         bool     `json:"pass"`
	TaskState    string   `json:"task_state,omitempty"`
	Millis       int64    `json:"ms"`
	Checks       []Check  `json:"checks"`
	Tools        []string `json:"tools_seen,omitempty"`
	AnswerSHA    string   `json:"answer_sha256,omitempty"`
	Answer       string   `json:"answer,omitempty"` // only with IncludeAnswers
	Outcome      string   `json:"outcome,omitempty"`
	HumanOutcome string   `json:"human_outcome,omitempty"`
	Baseline     string   `json:"baseline_outcome,omitempty"`
}

// Agreement compares the agent and a baseline with the human decisions over the replay cases.
type Agreement struct {
	Cases         int     `json:"cases"`
	Agent         int     `json:"agent_agrees"`
	BaselineCases int     `json:"baseline_cases"`
	Baseline      int     `json:"baseline_agrees"`
	AgentRate     float64 `json:"agent_rate"`
	BaselineRate  float64 `json:"baseline_rate"`
}

// Report is the JSON report of one run.
type Report struct {
	Version   int          `json:"version"`
	Mode      string       `json:"mode"` // "run" or "replay"
	Total     int          `json:"total"`
	Passed    int          `json:"passed"`
	Failed    int          `json:"failed"`
	Cases     []CaseResult `json:"cases"`
	Agreement *Agreement   `json:"agreement,omitempty"`
}

// Change is one line of a replay diff.
type Change struct {
	ID     string `json:"id"`
	Kind   string `json:"kind"` // same, regression, fixed, changed, new, missing
	Detail string `json:"detail,omitempty"`
}

// Diff is the replay result: what changed between a recorded report and a new run.
type Diff struct {
	Changes       []Change `json:"changes"`
	Regressions   int      `json:"regressions"`
	AgreementDrop bool     `json:"agreement_drop"`
	AgreementNote string   `json:"agreement_note,omitempty"`
}
