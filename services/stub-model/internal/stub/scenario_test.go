package stub

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// disputeJSON is a three step scenario: look up a case, read the rule for its reason code, draft a note.
const disputeJSON = `{"scenarios":[{
  "name":"dispute",
  "match":{"system":"dispute analyst","user":"(?i)dispute (?P<id>D-\\d+)"},
  "steps":[
    {"tool":"get_case","args":{"case_id":"{{user.id}}"}},
    {"tool":"get_rule","args":{"code":"{{result.0.reason_code}}","amount":"{{result.0.amount}}"}},
    {"tool":"draft_note","args":{"case":"{{user.id}}","rule":"{{result.1.title}}"}}
  ],
  "answers":[
    {"when":{"result.1.title":"^$"},"text":"Inconclusive: no rule found for {{user.id}}."},
    {"text":"Case {{user.id}} has reason {{result.0.reason_code}}. Rule: {{result.1.title}}. Draft: {{result.2}}."}
  ]}]}`

const tools3 = `"tools":[{"type":"function","function":{"name":"ops_get_case"}},{"type":"function","function":{"name":"ops_get_rule"}},{"type":"function","function":{"name":"ops_draft_note"}}]`

func postRaw(h http.Handler, body string) string {
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec.Body.String()
}

func loadSet(t *testing.T, doc string) *Set {
	t.Helper()
	p := filepath.Join(t.TempDir(), "s.json")
	if err := os.WriteFile(p, []byte(doc), 0o600); err != nil {
		t.Fatal(err)
	}
	s, err := LoadScenarios(p)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	return s
}

func callOf(t *testing.T, out map[string]any) (name string, args map[string]any, id string) {
	t.Helper()
	c := choice(out)
	if c["finish_reason"] != "tool_calls" {
		t.Fatalf("expected a tool call, got %v", c)
	}
	tc := c["message"].(map[string]any)["tool_calls"].([]any)[0].(map[string]any)
	fn := tc["function"].(map[string]any)
	if err := json.Unmarshal([]byte(fn["arguments"].(string)), &args); err != nil {
		t.Fatalf("arguments: %v", err)
	}
	return fn["name"].(string), args, tc["id"].(string)
}

func answerOf(t *testing.T, out map[string]any) string {
	t.Helper()
	c := choice(out)
	if c["finish_reason"] != "stop" {
		t.Fatalf("expected an answer, got %v", c)
	}
	return c["message"].(map[string]any)["content"].(string)
}

func TestScenarioRunsThreeStepsAcrossTurns(t *testing.T) {
	h := NewWithScenarios(loadSet(t, disputeJSON))
	sys := `{"role":"system","content":"You are a dispute analyst."}`
	user := `{"role":"user","content":"Please review dispute D-42"}`
	a1 := `{"role":"assistant","content":null,"tool_calls":[{"id":"call_stub_1","type":"function","function":{"name":"ops_get_case","arguments":"{}"}}]}`
	r1 := `{"role":"tool","tool_call_id":"call_stub_1","content":"{\"reason_code\":\"10.4\",\"amount\":125.5}"}`
	a2 := `{"role":"assistant","content":null,"tool_calls":[{"id":"call_stub_2","type":"function","function":{"name":"ops_get_rule","arguments":"{}"}}]}`
	r2 := `{"role":"tool","tool_call_id":"call_stub_2","content":"{\"title\":\"Fraud, card absent\"}"}`
	a3 := `{"role":"assistant","content":null,"tool_calls":[{"id":"call_stub_3","type":"function","function":{"name":"ops_draft_note","arguments":"{}"}}]}`
	r3 := `{"role":"tool","tool_call_id":"call_stub_3","content":"draft saved"}`
	turn := func(msgs ...string) map[string]any {
		_, out := post(t, h, `{"model":"m","messages":[`+strings.Join(msgs, ",")+`],`+tools3+`}`)
		return out
	}

	name, args, id := callOf(t, turn(sys, user))
	if name != "ops_get_case" || args["case_id"] != "D-42" || id != "call_stub_1" {
		t.Fatalf("step 1: %s %v %s", name, args, id)
	}
	name, args, id = callOf(t, turn(sys, user, a1, r1))
	if name != "ops_get_rule" || args["code"] != "10.4" || id != "call_stub_2" {
		t.Fatalf("step 2: %s %v %s", name, args, id)
	}
	if args["amount"] != 125.5 { // a whole-value placeholder keeps the JSON type
		t.Fatalf("amount lost its type: %#v", args["amount"])
	}
	name, args, _ = callOf(t, turn(sys, user, a1, r1, a2, r2))
	if name != "ops_draft_note" || args["rule"] != "Fraud, card absent" || args["case"] != "D-42" {
		t.Fatalf("step 3: %s %v", name, args)
	}
	ans := answerOf(t, turn(sys, user, a1, r1, a2, r2, a3, r3))
	for _, want := range []string{"D-42", "10.4", "Fraud, card absent", "draft saved", "stub model"} {
		if !strings.Contains(ans, want) {
			t.Fatalf("answer lacks %q: %q", want, ans)
		}
	}
}

func TestScenarioAnswerBranchOnResult(t *testing.T) {
	h := NewWithScenarios(loadSet(t, disputeJSON))
	body := `{"model":"m","messages":[{"role":"system","content":"dispute analyst"},{"role":"user","content":"dispute D-7"},
	 {"role":"tool","tool_call_id":"c1","content":"{\"reason_code\":\"x\"}"},
	 {"role":"tool","tool_call_id":"c2","content":"{\"title\":\"\"}"},
	 {"role":"tool","tool_call_id":"c3","content":"ok"}],` + tools3 + `}`
	_, out := post(t, h, body)
	if a := answerOf(t, out); !strings.Contains(a, "Inconclusive: no rule found for D-7") {
		t.Fatalf("branch not taken: %q", a)
	}
}

func TestScenarioNeedsSystemMarkerAndUserPattern(t *testing.T) {
	h := NewWithScenarios(loadSet(t, disputeJSON))
	// the system marker is missing: the built-in plain answer is given
	_, out := post(t, h, `{"model":"m","messages":[{"role":"system","content":"You are a poet."},{"role":"user","content":"dispute D-1"}],`+tools3+`}`)
	if a := answerOf(t, out); !strings.Contains(a, "scripted stand-in") {
		t.Fatalf("expected the built-in answer: %q", a)
	}
	// the user pattern does not match
	_, out = post(t, h, `{"model":"m","messages":[{"role":"system","content":"dispute analyst"},{"role":"user","content":"hello"}],`+tools3+`}`)
	if a := answerOf(t, out); !strings.Contains(a, "scripted stand-in") {
		t.Fatalf("expected the built-in answer: %q", a)
	}
}

func TestScenarioMissingToolEndsTheChainNamingIt(t *testing.T) {
	h := NewWithScenarios(loadSet(t, disputeJSON))
	_, out := post(t, h, `{"model":"m","messages":[{"role":"system","content":"dispute analyst"},{"role":"user","content":"dispute D-9"}],"tools":[{"type":"function","function":{"name":"ops_other"}}]}`)
	a := answerOf(t, out)
	if !strings.Contains(a, "get_case") || !strings.Contains(a, "stub model") {
		t.Fatalf("answer must name the missing tool and say it is the stub: %q", a)
	}
}

func TestScenarioCountsOnlyToolResultsAfterTheLastUserMessage(t *testing.T) {
	h := NewWithScenarios(loadSet(t, disputeJSON))
	// an earlier turn already used tools; a new user message starts the chain again at step 1
	body := `{"model":"m","messages":[{"role":"system","content":"dispute analyst"},{"role":"user","content":"dispute D-1"},
	 {"role":"tool","tool_call_id":"a","content":"{}"},{"role":"assistant","content":"done"},
	 {"role":"user","content":"now dispute D-2"}],` + tools3 + `}`
	_, out := post(t, h, body)
	name, args, _ := callOf(t, out)
	if name != "ops_get_case" || args["case_id"] != "D-2" {
		t.Fatalf("%s %v", name, args)
	}
}

func TestScenarioMissingFieldIsVisible(t *testing.T) {
	h := NewWithScenarios(loadSet(t, disputeJSON))
	body := `{"model":"m","messages":[{"role":"system","content":"dispute analyst"},{"role":"user","content":"dispute D-3"},
	 {"role":"tool","tool_call_id":"c1","content":"not json at all"}],` + tools3 + `}`
	_, out := post(t, h, body)
	_, args, _ := callOf(t, out)
	if s, _ := args["code"].(string); !strings.Contains(s, "missing") {
		t.Fatalf("a missing field must be visible, not empty: %#v", args)
	}
}

func TestScenarioStreaming(t *testing.T) {
	h := NewWithScenarios(loadSet(t, disputeJSON))
	rec := postRaw(h, `{"model":"m","stream":true,"messages":[{"role":"system","content":"dispute analyst"},{"role":"user","content":"dispute D-5"}],`+tools3+`}`)
	if !strings.Contains(rec, `ops_get_case`) || !strings.Contains(rec, `D-5`) || !strings.Contains(rec, `"finish_reason":"tool_calls"`) {
		t.Fatalf("stream: %s", rec)
	}
}

func TestBuiltInRulesUnchangedWithNilOrUnrelatedSet(t *testing.T) {
	body := `{"model":"m","messages":[{"role":"user","content":"Look up known vulnerabilities of lodash 4.17.20 (npm)"}],"tools":[` + osvTool + `]}`
	_, base := post(t, New(), body)
	_, withNil := post(t, NewWithScenarios(nil), body)
	_, withOther := post(t, NewWithScenarios(loadSet(t, disputeJSON)), body)
	x, _ := json.Marshal(base)
	for _, o := range []map[string]any{withNil, withOther} {
		y, _ := json.Marshal(o)
		if string(x) != string(y) {
			t.Fatalf("built-in behaviour changed:\n%s\n%s", x, y)
		}
	}
}

func TestLoadFromDirectoryAndValidation(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "a.json"), []byte(disputeJSON), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadScenarios(dir); err != nil {
		t.Fatalf("directory: %v", err)
	}
	bad := map[string]string{
		"bad regex":      `{"scenarios":[{"name":"x","match":{"user":"("},"answers":[{"text":"a"}]}]}`,
		"no name":        `{"scenarios":[{"match":{"user":"a"},"answers":[{"text":"a"}]}]}`,
		"no match":       `{"scenarios":[{"name":"x","answers":[{"text":"a"}]}]}`,
		"no answer":      `{"scenarios":[{"name":"x","match":{"user":"a"}}]}`,
		"empty tool":     `{"scenarios":[{"name":"x","match":{"user":"a"},"steps":[{"tool":""}],"answers":[{"text":"a"}]}]}`,
		"unknown field":  `{"scenarios":[{"name":"x","match":{"user":"a"},"answers":[{"text":"a"}],"oops":1}]}`,
		"duplicate name": `{"scenarios":[{"name":"x","match":{"user":"a"},"answers":[{"text":"a"}]},{"name":"x","match":{"user":"b"},"answers":[{"text":"a"}]}]}`,
		"future result":  `{"scenarios":[{"name":"x","match":{"user":"a"},"steps":[{"tool":"t","args":{"a":"{{result.0.b}}"}}],"answers":[{"text":"a"}]}]}`,
		"not json":       `nope`,
	}
	for name, doc := range bad {
		p := filepath.Join(t.TempDir(), "s.json")
		_ = os.WriteFile(p, []byte(doc), 0o600)
		if _, err := LoadScenarios(p); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
	if _, err := LoadScenarios(filepath.Join(dir, "missing.json")); err == nil {
		t.Error("missing file: expected an error")
	}
}

// A ConfigMap volume holds each key as a symlink to ..data/<key>, and ..data is a symlink to a timestamped directory (ADR 0026, B).
// The stub must load that layout the same as plain files, and ignore the hidden entries.
func TestLoadScenariosConfigMapLayout(t *testing.T) {
	dir := t.TempDir()
	stamp := "..2026_11_27_10_00_00.123456789"
	if err := os.Mkdir(filepath.Join(dir, stamp), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, stamp, "bank.json"), []byte(disputeJSON), 0o600); err != nil {
		t.Fatal(err)
	}
	other := strings.Replace(disputeJSON, `"name":"dispute"`, `"name":"second"`, 1)
	if err := os.WriteFile(filepath.Join(dir, stamp, "a-second.json"), []byte(other), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(stamp, filepath.Join(dir, "..data")); err != nil {
		t.Fatal(err)
	}
	for _, n := range []string{"bank.json", "a-second.json"} {
		if err := os.Symlink(filepath.Join("..data", n), filepath.Join(dir, n)); err != nil {
			t.Fatal(err)
		}
	}
	s, err := LoadScenarios(dir)
	if err != nil {
		t.Fatalf("configmap layout: %v", err)
	}
	if got := len(s.list); got != 2 {
		t.Fatalf("scenarios loaded = %d, want 2", got)
	}
	if s.list[0].Name != "second" || s.list[1].Name != "dispute" {
		t.Errorf("order = %q, %q; want name order of the files (a-second.json, bank.json)", s.list[0].Name, s.list[1].Name)
	}
}
