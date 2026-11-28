package api

import (
	"encoding/json"
	"os"
	"regexp"
	"strings"
	"testing"
)

func TestDecodeDefinition(t *testing.T) {
	raw := `{"apiVersion":"openagentix.io/v1alpha1","kind":"AgentDefinition",
	"metadata":{"name":"researcher","namespace":"kagent","uid":"u1","generation":3,"resourceVersion":"9","finalizers":["x"],"creationTimestamp":"2026-11-25T10:00:00Z"},
	"spec":{"description":"d","model":"claude-haiku","instructions":"hi","toolProfile":"lookup","tools":["a"],
	"knowledge":{"enabled":true,"collections":["c"]},"notify":{"enabled":false,"destinations":["d"]},"suspend":true,
	"memory":{"enabled":true,"ttlDays":30},"skills":[{"name":"s","version":"sha256:00"}],"egress":{"allow":["https://api.osv.dev"]}}}`
	var m map[string]any
	if err := json.Unmarshal([]byte(raw), &m); err != nil {
		t.Fatal(err)
	}
	d, err := FromObject(m)
	if err != nil {
		t.Fatal(err)
	}
	if d.Metadata.Name != "researcher" || d.Metadata.Generation != 3 || d.Spec.Memory.TTLDays != 30 || !d.Spec.Knowledge.Enabled || d.Spec.Knowledge.Collections[0] != "c" || d.Spec.Notify.Destinations[0] != "d" || !d.Spec.Suspend || d.Spec.Skills[0].Name != "s" || d.Spec.Skills[0].Version != "sha256:00" || d.Spec.Egress.Allow[0] != "https://api.osv.dev" {
		t.Fatalf("decoded wrong: %+v", d)
	}
	if d.Deleting() {
		t.Fatal("not deleting")
	}
}

func TestDecodeRejectsWrongKind(t *testing.T) {
	if _, err := FromObject(map[string]any{"kind": "Agent", "apiVersion": "openagentix.io/v1alpha1"}); err == nil {
		t.Fatal("want error for wrong kind")
	}
}

func TestSetConditionKeepsTransitionTimeWhenStatusUnchanged(t *testing.T) {
	var s Status
	s.SetCondition(Condition{Type: "Ready", Status: "False", Reason: "A"}, "t1", 1)
	s.SetCondition(Condition{Type: "Ready", Status: "False", Reason: "B", Message: "m"}, "t2", 2)
	c := s.Condition("Ready")
	if c.LastTransitionTime != "t1" || c.Reason != "B" || c.ObservedGeneration != 2 {
		t.Fatalf("%+v", c)
	}
	s.SetCondition(Condition{Type: "Ready", Status: "True", Reason: "C"}, "t3", 2)
	if s.Condition("Ready").LastTransitionTime != "t3" {
		t.Fatal("transition time must move when status flips")
	}
}

func TestStatusPatchEmitsEmptyListsNotNull(t *testing.T) {
	p := (Status{}).Patch()
	st := p["status"].(map[string]any)
	for _, k := range []string{"conditions", "effectiveTools", "effectiveEgress", "violations"} {
		if v, ok := st[k].([]any); !ok || len(v) != 0 {
			t.Fatalf("%s should be an empty list, got %#v", k, st[k])
		}
	}
}

func TestStatusContractSplitsPublicFromController(t *testing.T) {
	st := Status{
		Revision:     "abc123abc123",
		Endpoint:     &Endpoint{Protocol: "a2a", URL: "http://gate/agents/kagent/x", ProtocolVersion: "1.0"},
		Capabilities: &Capabilities{Approvals: Yes},
		Budget:       &BudgetStatus{Class: "default"},
		AgentRef:     &ObjectRef{APIVersion: "v", Kind: "K", Name: "n"},
		Controller:   ControllerState{KeySecret: "s", KeyFingerprint: "f", AppliedGeneration: 2, AppliedSpec: "{}", GatewayUserID: "kagent.x", ToolServer: "ts"},
	}
	m := st.Patch()["status"].(map[string]any)
	for _, k := range PublicStatusFields {
		if _, ok := m[k]; !ok {
			t.Errorf("public field %q is not in the patch", k)
		}
	}
	// nothing but the public contract and the one controller block is written
	allowed := map[string]bool{"controller": true}
	for _, k := range PublicStatusFields {
		allowed[k] = true
	}
	for k := range m {
		if !allowed[k] {
			t.Errorf("status.%s is neither public nor under status.controller", k)
		}
	}
	for _, internal := range []string{"keySecret", "keyFingerprint", "appliedGeneration", "appliedSpec", "gatewayUserId", "toolServer", "a2aUrl"} {
		if _, ok := m[internal]; ok {
			t.Errorf("%s must not be a top-level status field", internal)
		}
	}
	c := m["controller"].(map[string]any)
	for _, k := range []string{"keySecret", "keyFingerprint", "appliedGeneration", "appliedSpec", "gatewayUserId", "toolServer"} {
		if _, ok := c[k]; !ok {
			t.Errorf("status.controller.%s is missing", k)
		}
	}
	e := m["endpoint"].(map[string]any)
	if e["protocol"] != "a2a" || e["url"] != "http://gate/agents/kagent/x" || e["protocolVersion"] != "1.0" {
		t.Fatalf("endpoint %v", e)
	}
}

func TestPatchClearsEndpointAgentRefAndCapabilitiesWithNull(t *testing.T) {
	m := (Status{}).Patch()["status"].(map[string]any)
	for _, k := range []string{"endpoint", "agentRef", "capabilities"} {
		v, ok := m[k]
		if !ok || v != nil {
			t.Errorf("%s must be present and null in a merge patch so that a cleared value is removed, got %#v (present %v)", k, v, ok)
		}
	}
}

func TestSpecJSONOmitsEmptyOptionalBlocks(t *testing.T) {
	b, _ := json.Marshal(Spec{Model: "m", Instructions: "i"})
	for _, k := range []string{"knowledge", "notify", "skills", "suspend", "instructionsFrom", "memory", "egress"} {
		if strings.Contains(string(b), `"`+k+`"`) {
			t.Errorf("%s should be omitted when empty: %s", k, b)
		}
	}
}

func TestReservedLabelKeys(t *testing.T) {
	if LabelTeam != "openagentix.io/team" || LabelProject != "openagentix.io/project" || LabelWorkItem != "openagentix.io/work-item" {
		t.Fatal("reserved label keys changed")
	}
}

func TestReasonTableHasEveryConditionAndNoDuplicates(t *testing.T) {
	for _, typ := range []string{CondAccepted, CondKeyReady, CondApplied, CondReady, CondSynced} {
		rs := ReasonsFor(typ)
		if len(rs) == 0 {
			t.Fatalf("no reasons documented for %s", typ)
		}
		seen := map[string]bool{}
		for _, r := range rs {
			if r.Reason == "" || r.Meaning == "" || seen[r.Reason] {
				t.Fatalf("%s: bad or duplicate row %+v", typ, r)
			}
			seen[r.Reason] = true
			if !ValidReason(typ, r.Reason) {
				t.Fatalf("ValidReason(%s, %s)", typ, r.Reason)
			}
		}
	}
	if ValidReason(CondReady, "Bogus") {
		t.Fatal("an undocumented reason must not be valid")
	}
}

// The README prints the reason table. A reason added to the code without a README row, or a row for a reason the code does not
// have, fails here.
func TestReadmeReasonTableMatchesTheCode(t *testing.T) {
	raw, err := os.ReadFile("../../README.md")
	if err != nil {
		t.Fatal(err)
	}
	readme := string(raw)
	total := 0
	for _, typ := range []string{CondAccepted, CondKeyReady, CondApplied, CondReady, CondSynced} {
		for _, r := range ReasonsFor(typ) {
			total++
			row := "| `" + typ + "` | `" + r.Reason + "` | " + r.Status + " | " + r.Meaning + " |"
			if !strings.Contains(readme, row) {
				t.Errorf("README has no row %q", row)
			}
		}
	}
	rows := 0
	for _, l := range strings.Split(readme, "\n") {
		if regexp.MustCompile("^\\| `(Accepted|KeyReady|Applied|Ready|Synced)` \\| `[A-Za-z]+` \\| (True|False|Unknown) \\|").MatchString(l) {
			rows++
		}
	}
	if rows != total {
		t.Errorf("README has %d reason rows, the code %d", rows, total)
	}
}
