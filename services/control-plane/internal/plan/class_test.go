package plan

import (
	"testing"

	"github.com/openagentix/openagentix/services/control-plane/internal/api"
	"github.com/openagentix/openagentix/services/control-plane/internal/catalog"
)

// ADR 0029, slice 4: the class of every plan is the one class the policy names for definitions. A definition has no field that could change it.
func TestThePlanCarriesTheClassOfThePolicyAndNothingElseSetsIt(t *testing.T) {
	c := cat(t)
	for _, class := range []string{"", "bank-agents"} {
		p, err := Build(def(), c, tools{c}, &catalog.Policy{BudgetClass: class})
		if err != nil || p.BudgetClass != class {
			t.Fatalf("class %q: got %q, %v", class, p.BudgetClass, err)
		}
	}
	// a nil policy (a test without one) is the default budget
	if p, err := Build(def(), c, tools{c}, nil); err != nil || p.BudgetClass != "" {
		t.Fatalf("%q %v", p.BudgetClass, err)
	}
	// labels never choose a class
	d := def()
	d.Metadata.Labels = map[string]string{"openagentix.io/team": "x", "openagentix.io/budget-class": "wide", "budget_class": "wide"}
	if p, err := Build(d, c, tools{c}, &catalog.Policy{}); err != nil || p.BudgetClass != "" {
		t.Fatalf("a label chose class %q (%v)", p.BudgetClass, err)
	}
}

// A container agent has a key at the gateway too: its plan carries the class like a builtin one (review of PR 271).
func TestAContainerPlanCarriesTheClassOfThePolicy(t *testing.T) {
	c := cat(t)
	pl := &catalog.Policy{BudgetClass: "bank-agents", Runtimes: catalog.PolicyRuntimes{Container: catalog.PolicyContainerRuntime{
		DefaultResources: api.Resources{Requests: api.ResourceList{CPU: "50m", Memory: "64Mi"}, Limits: api.ResourceList{CPU: "400m", Memory: "300Mi"}}}}}
	p, err := Build(containerDef(), c, tools{c}, pl)
	if err != nil || p.RuntimeType != api.RuntimeContainer || p.BudgetClass != "bank-agents" {
		t.Fatalf("%+v %v", p, err)
	}
	pl.BudgetClass = ""
	if p, err := Build(containerDef(), c, tools{c}, pl); err != nil || p.BudgetClass != "" {
		t.Fatalf("%q %v", p.BudgetClass, err)
	}
}

func TestTheClassIsNotPartOfTheRevision(t *testing.T) {
	c := cat(t)
	a, _ := Build(def(), c, tools{c}, &catalog.Policy{})
	b, _ := Build(def(), c, tools{c}, &catalog.Policy{BudgetClass: "bank-agents"})
	if a.Revision != b.Revision {
		t.Fatal("a change of class would roll the agent")
	}
}
