package agentgateway

import (
	"context"
	"encoding/json"
	"os"
	"testing"
)

// ADR 0029, slice 4: the class of definitions is the last member of the metadata, after team and project, which is the one place the
// admission guard accepts it.
func TestRegisterWritesTheBudgetClassLastAndEntriesReadsItBack(t *testing.T) {
	cases := []struct {
		name   string
		labels map[string]string
		class  string
		want   string
	}{
		{"no class: the entry is what it always was", nil, "", `{"keyHash":"sha256:abc","metadata":{"user_id":"kagent.r"}}`},
		{"a class", nil, "bank-agents", `{"keyHash":"sha256:abc","metadata":{"user_id":"kagent.r","budget_class":"bank-agents"}}`},
		{"team, project, then the class", map[string]string{"openagentix.io/team": "payments", "openagentix.io/project": "ledger"}, "bank-agents",
			`{"keyHash":"sha256:abc","metadata":{"user_id":"kagent.r","team":"payments","project":"ledger","budget_class":"bank-agents"}}`},
		{"a class of 40 characters", nil, "a23456789012345678901234567890123456789b", `{"keyHash":"sha256:abc","metadata":{"user_id":"kagent.r","budget_class":"a23456789012345678901234567890123456789b"}}`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s, a := setup(t)
			if err := a.Register(context.Background(), "kagent.r", "sha256:abc", c.labels, c.class); err != nil {
				t.Fatal(err)
			}
			cm, _ := s.Get("configmaps", "agentgateway-system", ConfigMapName)
			got := cm["data"].(map[string]any)["kagent.r"].(string)
			if got != c.want || !json.Valid([]byte(got)) {
				t.Fatalf("got  %s\nwant %s", got, c.want)
			}
			m, _ := a.Entries(context.Background())
			if m["kagent.r"].Class != c.class {
				t.Fatalf("Entries read class %q, wrote %q", m["kagent.r"].Class, c.class)
			}
		})
	}
}

func TestRegisterRefusesAClassThatIsNotADNSLabel(t *testing.T) {
	long := "a23456789012345678901234567890123456789bc"
	for _, bad := range []string{`a","admin":"1`, "Bank", "a_b", "-a", "a-", "default", long, "a\nb", `a"b`, "é", " a"} {
		s, a := setup(t)
		if err := a.Register(context.Background(), "kagent.r", "sha256:abc", nil, bad); err == nil {
			t.Errorf("class %q was accepted", bad)
		}
		if n := len(s.Matching("PATCH", "/configmaps/"+ConfigMapName)); n != 0 {
			t.Errorf("class %q: %d write(s) before the refusal", bad, n)
		}
	}
}

// The text this adapter writes is the text the admission guard is run against in hack/ci/guardtest (the same file).
func TestEntriesMatchTheSharedGoldenFile(t *testing.T) {
	b, err := os.ReadFile("../../../testdata/key-entries.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		User, Hash, Team, Project, Class, Entry string
	}
	if err := json.Unmarshal(b, &cases); err != nil || len(cases) < 4 {
		t.Fatalf("%v (%d cases)", err, len(cases))
	}
	for _, c := range cases {
		labels := map[string]string{}
		if c.Team != "" {
			labels["openagentix.io/team"] = c.Team
		}
		if c.Project != "" {
			labels["openagentix.io/project"] = c.Project
		}
		if got := entry(c.User, c.Hash, labels, c.Class); got != c.Entry {
			t.Errorf("%s\n got  %s\n want %s", c.User, got, c.Entry)
		}
	}
}
