package core

import (
	"errors"
	"testing"
	"time"

	"github.com/openagentix/openagentix/services/control-plane/internal/keys"
	"github.com/openagentix/openagentix/services/control-plane/internal/kubetest"
)

// ADR 0029, slice 4: the class the operator names for definitions reaches the gateway key entry, and status.budget.class says what was written.

func budgetClass(t *testing.T, e *env, name string) string {
	t.Helper()
	b := e.status(name).Budget
	if b == nil {
		return "<absent>"
	}
	return b.Class
}

func TestNoClassKeepsTheDefaultBudgetAndSaysSo(t *testing.T) {
	e, _ := newEnv(t)
	e.seed("researcher", nil)
	e.pass(t)
	if e.gw.classes["kagent.researcher"] != "" {
		t.Fatalf("the entry carries class %q with no class set", e.gw.classes["kagent.researcher"])
	}
	if got := budgetClass(t, e, "researcher"); got != "default" {
		t.Fatalf("status.budget.class = %q, want default", got)
	}
	calls := e.gw.regCalls
	e.pass(t)
	if e.gw.regCalls != calls {
		t.Fatalf("a steady pass wrote the entry again (%d -> %d)", calls, e.gw.regCalls)
	}
}

func TestTheClassOfDefinitionsIsWrittenToTheEntryAndReported(t *testing.T) {
	e, _ := newEnv(t)
	e.pol.BudgetClass = "bank-agents"
	e.seed("researcher", nil)
	e.pass(t)
	if e.gw.classes["kagent.researcher"] != "bank-agents" || e.gw.entries["kagent.researcher"] != keys.Hash(e.mint) {
		t.Fatalf("entry: class %q hash %q", e.gw.classes["kagent.researcher"], e.gw.entries["kagent.researcher"])
	}
	if got := budgetClass(t, e, "researcher"); got != "bank-agents" {
		t.Fatalf("status.budget.class = %q", got)
	}
	// the class is not part of the revision: a change of class must not roll the agent
	rev := e.status("researcher").Revision
	e.pol.BudgetClass = "other-class"
	e.pass(t)
	if e.status("researcher").Revision != rev {
		t.Fatal("a class change changed the revision")
	}
}

// An entry that is unchanged keeps its old class unless the controller rewrites it: it does, with the same hash and without a new key.
func TestAChangedClassRewritesEveryEntryWithTheSameKey(t *testing.T) {
	steps := []struct{ name, from, to string }{
		{"none to a class", "", "bank-agents"},
		{"a class to another", "case-agent", "bank-agents"},
		{"a class to none", "bank-agents", ""},
	}
	for _, s := range steps {
		t.Run(s.name, func(t *testing.T) {
			e, _ := newEnv(t)
			e.pol.BudgetClass = s.from
			e.seed("a", nil)
			e.seed("b", nil)
			e.pass(t)
			hashA, hashB := e.gw.entries["kagent.a"], e.gw.entries["kagent.b"]
			e.mint = "vk-ffffffffffffffffffffffffffffffff" // a new key would be visible
			e.pol.BudgetClass = s.to
			e.pass(t)
			want := s.to
			for _, n := range []string{"a", "b"} {
				if got := e.gw.classes["kagent."+n]; got != want {
					t.Errorf("entry of %s keeps class %q, want %q", n, got, want)
				}
				wantStatus := want
				if wantStatus == "" {
					wantStatus = "default"
				}
				if got := budgetClass(t, e, n); got != wantStatus {
					t.Errorf("status of %s: %q, want %q", n, got, wantStatus)
				}
			}
			if e.gw.entries["kagent.a"] != hashA || e.gw.entries["kagent.b"] != hashB {
				t.Fatal("the key changed with the class")
			}
			if len(e.srv.Matching("DELETE", "secrets")) != 0 {
				t.Fatal("a class change deleted a key Secret")
			}
		})
	}
}

func TestASuspendedDefinitionHasNoEntryAndTheClassIsUnknown(t *testing.T) {
	e, _ := newEnv(t)
	clk := e.useClock()
	e.pol.BudgetClass = "bank-agents"
	e.seed("researcher", nil)
	e.pass(t)
	clk.advance(10 * time.Minute)
	e.srv.Modify("agentdefinitions", "kagent", "researcher", func(o kubetest.Object) { o["spec"].(map[string]any)["suspend"] = true })
	e.pass(t)
	if _, ok := e.gw.entries["kagent.researcher"]; ok {
		t.Fatal("the entry is not cut")
	}
	if got := budgetClass(t, e, "researcher"); got != "unknown" {
		t.Fatalf("a cut entry has no class on the gateway: status.budget.class = %q, want unknown", got)
	}
	// resume: the held hash is registered again, with the class
	clk.advance(10 * time.Minute)
	e.srv.Modify("agentdefinitions", "kagent", "researcher", func(o kubetest.Object) { o["spec"].(map[string]any)["suspend"] = false })
	e.pass(t)
	if e.gw.classes["kagent.researcher"] != "bank-agents" || budgetClass(t, e, "researcher") != "bank-agents" {
		t.Fatalf("after resume: entry class %q, status %q", e.gw.classes["kagent.researcher"], budgetClass(t, e, "researcher"))
	}
}

func TestAFailedRegistrationLeavesTheClassUnknown(t *testing.T) {
	e, _ := newEnv(t)
	e.pol.BudgetClass = "bank-agents"
	e.gw.failReg = errors.New("boom")
	e.seed("researcher", nil)
	_ = e.c.ReconcileAll(t.Context())
	if got := budgetClass(t, e, "researcher"); got != "unknown" {
		t.Fatalf("status.budget.class = %q after a failed write, want unknown", got)
	}
}

// Review of PR 271: a refused edit whose previous generation keeps running must follow the operator's class too.
func TestARefusedEditKeepsTheEntryOnTheCurrentClass(t *testing.T) {
	e, _ := newEnv(t)
	e.pol.BudgetClass = "large"
	e.seed("researcher", nil)
	e.pass(t)
	hash := e.gw.entries["kagent.researcher"]
	e.srv.Modify("agentdefinitions", "kagent", "researcher", func(o kubetest.Object) { o["spec"].(map[string]any)["model"] = "not-in-the-catalog" })
	e.pass(t)
	wantCond(t, e.status("researcher"), "Applied", "True", "PreviousGenerationRunning")
	e.pol.BudgetClass = "small"
	e.pass(t)
	if got := e.gw.classes["kagent.researcher"]; got != "small" || e.gw.entries["kagent.researcher"] != hash {
		t.Fatalf("entry class %q (want small), hash kept: %v", got, e.gw.entries["kagent.researcher"] == hash)
	}
	if got := budgetClass(t, e, "researcher"); got != "small" {
		t.Fatalf("status.budget.class = %q, want small", got)
	}
	e.pol.BudgetClass = ""
	e.pass(t)
	if e.gw.classes["kagent.researcher"] != "" || budgetClass(t, e, "researcher") != "default" {
		t.Fatalf("class %q status %q", e.gw.classes["kagent.researcher"], budgetClass(t, e, "researcher"))
	}
}

func TestARefusedEditWithTheStopSwitchCutsTheEntryAndTheClassIsUnknown(t *testing.T) {
	e, _ := newEnv(t)
	clk := e.useClock()
	e.pol.BudgetClass = "large"
	e.seed("researcher", nil)
	e.pass(t)
	e.srv.Modify("agentdefinitions", "kagent", "researcher", func(o kubetest.Object) { o["spec"].(map[string]any)["model"] = "not-in-the-catalog" })
	e.pass(t)
	clk.advance(10 * time.Minute)
	e.pol.SuspendAll = true
	e.pass(t)
	if _, ok := e.gw.entries["kagent.researcher"]; ok {
		t.Fatal("the entry is not cut")
	}
	if got := budgetClass(t, e, "researcher"); got != "unknown" {
		t.Fatalf("status.budget.class = %q while the entry is cut, want unknown", got)
	}
	clk.advance(10 * time.Minute)
	e.pol.SuspendAll, e.pol.BudgetClass = false, "small"
	e.pass(t)
	if e.gw.classes["kagent.researcher"] != "small" || budgetClass(t, e, "researcher") != "small" {
		t.Fatalf("after the stop switch is off: entry %q status %q", e.gw.classes["kagent.researcher"], budgetClass(t, e, "researcher"))
	}
}

func TestADefinitionRefusedBeforeItEverRanHasNoBudgetStatus(t *testing.T) {
	e, _ := newEnv(t)
	e.pol.BudgetClass = "large"
	e.gw.failReg = errors.New("boom")
	e.seed("researcher", nil)
	_ = e.c.ReconcileAll(t.Context())
	if got := budgetClass(t, e, "researcher"); got != "unknown" {
		t.Fatalf("setup: %q", got)
	}
	e.gw.failReg = nil
	e.srv.Modify("agentdefinitions", "kagent", "researcher", func(o kubetest.Object) { o["spec"].(map[string]any)["model"] = "not-in-the-catalog" })
	e.pass(t)
	if got := budgetClass(t, e, "researcher"); got != "<absent>" {
		t.Fatalf("a definition that never ran and is refused shows status.budget.class = %q", got)
	}
}

func TestARefusedDefinitionReportsNoClass(t *testing.T) {
	e, _ := newEnv(t)
	e.pol.BudgetClass = "bank-agents"
	e.seed("bad", func(s map[string]any) { s["model"] = "not-in-the-catalog" })
	e.pass(t)
	if got := budgetClass(t, e, "bad"); got != "<absent>" {
		t.Fatalf("a refused definition has no key, so no class: %q", got)
	}
}
