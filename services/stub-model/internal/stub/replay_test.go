package stub

import (
	"encoding/json"
	"net/http"
	"sort"
	"strings"
	"testing"
)

// agentLoop plays the part of an agent runtime: it asks the model, runs the tool the model names against fake
// tools, adds the result to the conversation, and repeats until the model answers. It returns the transcript.
func agentLoop(t *testing.T, h http.Handler, system, user string, fake map[string]string) []string {
	t.Helper()
	var names []string
	for n := range fake {
		names = append(names, n)
	}
	sort.Strings(names)
	offered := make([]string, 0, len(names))
	for _, n := range names {
		offered = append(offered, `{"type":"function","function":{"name":"ops_`+n+`"}}`)
	}
	toolsJSON := `"tools":[` + strings.Join(offered, ",") + `]`
	sj, _ := json.Marshal(system)
	uj, _ := json.Marshal(user)
	msgs := []string{`{"role":"system","content":` + string(sj) + `}`, `{"role":"user","content":` + string(uj) + `}`}
	var log []string
	for i := 0; i < 10; i++ {
		_, out := post(t, h, `{"model":"m","messages":[`+strings.Join(msgs, ",")+`],`+toolsJSON+`}`)
		c := choice(out)
		if c["finish_reason"] != "tool_calls" {
			return append(log, "ANSWER "+c["message"].(map[string]any)["content"].(string))
		}
		tc := c["message"].(map[string]any)["tool_calls"].([]any)[0].(map[string]any)
		fn := tc["function"].(map[string]any)
		name := strings.TrimPrefix(fn["name"].(string), "ops_")
		log = append(log, "CALL "+name+" "+fn["arguments"].(string))
		res, ok := fake[name]
		if !ok {
			t.Fatalf("model asked for a tool that does not exist: %s", name)
		}
		tcj, _ := json.Marshal(tc)
		rj, _ := json.Marshal(res)
		msgs = append(msgs, `{"role":"assistant","content":null,"tool_calls":[`+string(tcj)+`]}`,
			`{"role":"tool","tool_call_id":"`+tc["id"].(string)+`","content":`+string(rj)+`}`)
	}
	t.Fatal("the loop did not end")
	return nil
}

func TestExampleScenarioReplaysDeterministically(t *testing.T) {
	set, err := LoadScenarios("../../examples/dispute.json")
	if err != nil {
		t.Fatal(err)
	}
	fake := map[string]string{
		"get_case":   `{"reason_code":"10.4","amount":125.5}`,
		"get_rule":   `{"title":"Fraud, card absent"}`,
		"draft_note": `{"id":"draft-9"}`,
	}
	sys, usr := "You help with a card dispute queue.", "Please review dispute D-42"
	a := agentLoop(t, NewWithScenarios(set), sys, usr, fake)
	b := agentLoop(t, NewWithScenarios(set), sys, usr, fake)
	if strings.Join(a, "\n") != strings.Join(b, "\n") {
		t.Fatalf("two runs differ:\n%v\n%v", a, b)
	}
	want := []string{
		`CALL get_case {"case_id":"D-42"}`,
		`CALL get_rule {"reason_code":"10.4"}`,
		`CALL draft_note {"amount":125.5,"case_id":"D-42","rule":"Fraud, card absent"}`,
	}
	for i, w := range want {
		if a[i] != w {
			t.Fatalf("step %d: %s, want %s", i, a[i], w)
		}
	}
	if last := a[len(a)-1]; !strings.Contains(last, "draft-9") || !strings.Contains(last, "Fraud, card absent") {
		t.Fatalf("answer: %s", last)
	}
	fake["get_rule"] = `{"title":""}` // the evidence is missing: the scenario says so
	c := agentLoop(t, NewWithScenarios(set), sys, usr, fake)
	if last := c[len(c)-1]; !strings.Contains(last, "Inconclusive") {
		t.Fatalf("answer: %s", last)
	}
}
