package guardtest

import (
	"strings"
	"testing"
)

// ADR 0029, slice 3: the key ConfigMap rule of the guard accepts one more optional member at the end of the metadata, "budget_class",
// only when controlPlane.policy.budgetClasses.definitions names a class, and only that class, written out in the rule. With the value
// empty the rule is what it was.

func classEntry(user, hash, team, project, class string) string {
	meta := `"user_id":"` + user + `"`
	if team != "" {
		meta += `,"team":"` + team + `"`
	}
	if project != "" {
		meta += `,"project":"` + project + `"`
	}
	if class != "" {
		meta += `,"budget_class":"` + class + `"`
	}
	return `{"keyHash":"` + hash + `","metadata":{` + meta + `}}`
}

var budgetSets = []string{
	"gateway.policy.budgetClasses[0].name=bank-agents", "gateway.policy.budgetClasses[0].tokens=300000", "gateway.policy.budgetClasses[0].unit=Hours", "gateway.policy.budgetClasses[0].per=agent",
	"gateway.policy.budgetClasses[1].name=shared-pool", "gateway.policy.budgetClasses[1].tokens=500000", "gateway.policy.budgetClasses[1].unit=Hours", "gateway.policy.budgetClasses[1].per=class",
}

func keyUpdate(name string, newData m, oldData m) expectation {
	o := keyMap(newData)
	return expectation{req: request{Name: name, User: controller, Op: "UPDATE", Resource: "configmaps", Namespace: "agentgateway-system", ObjName: "llm-api-keys-control-plane", Object: o, Old: keyMap(oldData)}}
}

func runKeyCases(t *testing.T, e *engine, cases []expectation) {
	t.Helper()
	for _, c := range cases {
		c := c
		t.Run(c.req.Name, func(t *testing.T) {
			v := e.eval(c.req)
			if c.allow && !v.Allowed {
				t.Errorf("the guard REFUSED a write it must allow: %v", v.Why)
			}
			if !c.allow && v.Allowed {
				t.Errorf("the guard ALLOWED a write it must refuse (matched: %v)", v.Matched)
			}
			if !c.allow && !v.Allowed && !v.Rule {
				t.Errorf("refused only by an evaluation error, no rule said no: %v", v.Why)
			}
		})
	}
}

func TestBudgetClassGuard(t *testing.T) {
	const k = "kagent.researcher"
	old := m{k: entry(k, hash64, "", "")}
	mk := func(name string, allow bool, entryText string) expectation {
		x := keyUpdate(name, m{k: entryText}, old)
		x.allow = allow
		return x
	}

	t.Run("definitions empty: the member is refused, whatever the class", func(t *testing.T) {
		r := render(t, budgetSets...)
		e, err := newEngine(r.Policies)
		if err != nil {
			t.Fatal(err)
		}
		runKeyCases(t, e, []expectation{
			mk("empty: an entry with no class is allowed", true, classEntry(k, hash64, "", "", "")),
			mk("empty: an entry with team and project and no class is allowed", true, classEntry(k, hash64, "platform", "demo", "")),
			mk("empty: a class the operator defined is refused", false, classEntry(k, hash64, "", "", "bank-agents")),
			mk("empty: a class nobody defined is refused", false, classEntry(k, hash64, "", "", "anything")),
		})
	})

	t.Run("definitions empty with no class at all: the rule has no budget_class", func(t *testing.T) {
		r := render(t)
		for _, p := range r.Policies {
			for _, v := range p.Spec.Validations {
				if strings.Contains(v.Expression, "budget_class") {
					t.Errorf("policy %s mentions budget_class with the feature off", p.Name)
				}
			}
		}
	})

	t.Run("definitions=bank-agents", func(t *testing.T) {
		r := render(t, append(append([]string{}, budgetSets...), "controlPlane.policy.budgetClasses.definitions=bank-agents")...)
		e, err := newEngine(r.Policies)
		if err != nil {
			t.Fatal(err)
		}
		runKeyCases(t, e, []expectation{
			mk("set: the class of definitions is allowed", true, classEntry(k, hash64, "", "", "bank-agents")),
			mk("set: the class with team and project before it is allowed", true, classEntry(k, hash64, "platform", "demo", "bank-agents")),
			mk("set: an entry with no class is still allowed", true, classEntry(k, hash64, "", "", "")),
			mk("set: another class of the operator is refused (a shared one)", false, classEntry(k, hash64, "", "", "shared-pool")),
			mk("set: a class nobody defined is refused", false, classEntry(k, hash64, "", "", "other")),
			mk("set: a longer name that starts with the class is refused", false, classEntry(k, hash64, "", "", "bank-agents-big")),
			mk("set: a class that ends with the class name is refused", false, classEntry(k, hash64, "", "", "xbank-agents")),
			mk("set: an empty class is refused", false, strings.Replace(classEntry(k, hash64, "", "", "bank-agents"), `"bank-agents"`, `""`, 1)),
			mk("set: the class twice is refused", false, strings.Replace(classEntry(k, hash64, "", "", "bank-agents"), `}}`, `,"budget_class":"bank-agents"}}`, 1)),
			mk("set: the class before user_id is refused", false, strings.Replace(classEntry(k, hash64, "", "", "bank-agents"), `"user_id":"`+k+`"`, `"budget_class":"bank-agents","user_id":"`+k+`"`, 1)),
			mk("set: the class before team is refused", false, strings.Replace(classEntry(k, hash64, "platform", "", "bank-agents"), `,"team":"platform"`, `,"budget_class":"bank-agents","team":"platform"`, 1)),
			mk("set: the class as a number is refused", false, strings.Replace(classEntry(k, hash64, "", "", "bank-agents"), `"bank-agents"`, `1`, 1)),
			mk("set: a second member after the class is refused", false, strings.Replace(classEntry(k, hash64, "", "", "bank-agents"), `"}}`, `","admin":"1"}}`, 1)),
			mk("set: a quote that closes the class is refused", false, strings.Replace(classEntry(k, hash64, "", "", "bank-agents"), `"bank-agents"`, `"bank-agents\",\"admin\":\"1"`, 1)),
			mk("set: the class in the entry, outside the metadata, is refused", false, strings.Replace(classEntry(k, hash64, "", "", ""), `"metadata"`, `"budget_class":"bank-agents","metadata"`, 1)),
			mk("set: the class with whitespace is refused", false, strings.Replace(classEntry(k, hash64, "", "", "bank-agents"), `"budget_class":`, `"budget_class": `, 1)),
			mk("set: another user id with the class is still refused", false, classEntry("kagent.admin", hash64, "", "", "bank-agents")),
		})
	})
}

// The text the controller itself writes (the file is also what services/control-plane's adapter test compares its output with) is
// allowed by the guard when it names the class of definitions, and refused when it names any other class.
func TestTheControllersOwnEntriesPassTheGuard(t *testing.T) {
	var cases []struct {
		User, Hash, Team, Project, Class, Entry string
	}
	readJSON(t, "services/control-plane/testdata/key-entries.json", &cases)
	if len(cases) < 4 {
		t.Fatalf("%d cases", len(cases))
	}
	for _, definitions := range []string{"", "bank-agents", "other-class"} {
		sets := append([]string{}, budgetSets...)
		sets = append(sets, "gateway.policy.budgetClasses[2].name=other-class", "gateway.policy.budgetClasses[2].tokens=1000", "gateway.policy.budgetClasses[2].unit=Hours", "gateway.policy.budgetClasses[2].per=agent")
		if definitions != "" {
			sets = append(sets, "controlPlane.policy.budgetClasses.definitions="+definitions)
		}
		r := render(t, sets...)
		e, err := newEngine(r.Policies)
		if err != nil {
			t.Fatal(err)
		}
		var list []expectation
		for _, c := range cases {
			x := keyUpdate("definitions="+definitions+": "+c.User+" class="+c.Class, m{c.User: c.Entry}, m{c.User: entry(c.User, hash64, "", "")})
			x.allow = c.Class == "" || c.Class == definitions
			list = append(list, x)
		}
		runKeyCases(t, e, list)
	}
}
