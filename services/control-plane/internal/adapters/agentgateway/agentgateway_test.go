package agentgateway

import (
	"context"
	"encoding/json"
	"regexp"
	"testing"

	"github.com/openagentix/openagentix/services/control-plane/internal/keys"
	"github.com/openagentix/openagentix/services/control-plane/internal/kube"
	"github.com/openagentix/openagentix/services/control-plane/internal/kubetest"
)

func setup(t *testing.T) (*kubetest.Server, *Adapter) {
	s := kubetest.New()
	t.Cleanup(s.Close)
	s.Seed("configmaps", kubetest.Object{"apiVersion": "v1", "kind": "ConfigMap",
		"metadata": kubetest.Object{"name": ConfigMapName, "namespace": "agentgateway-system", "labels": kubetest.Object{"agentgateway.dev/apikey": "true"}}})
	c := kube.New(s.URL, s.Client(), func() (string, error) { return "t", nil })
	return s, New(c, "agentgateway-system")
}

var _ keys.Registry = (*Adapter)(nil)

func TestRegisterWritesTheInstallersEntryFormat(t *testing.T) {
	s, a := setup(t)
	if err := a.Register(context.Background(), "kagent.researcher", "sha256:abc", nil, ""); err != nil {
		t.Fatal(err)
	}
	cm, _ := s.Get("configmaps", "agentgateway-system", ConfigMapName)
	got := cm["data"].(map[string]any)["kagent.researcher"].(string)
	// install.sh: {"keyHash":"$h","metadata":{"user_id":"$agent"}}  (no spaces, this key order)
	want := `{"keyHash":"sha256:abc","metadata":{"user_id":"kagent.researcher"}}`
	if got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
	if !json.Valid([]byte(got)) {
		t.Fatal("not JSON")
	}
	r := s.Matching("PATCH", "/configmaps/"+ConfigMapName)
	if len(r) != 1 || r[0].ContentType != "application/merge-patch+json" {
		t.Fatalf("%+v", s.Requests())
	}
	if cm["metadata"].(map[string]any)["labels"].(map[string]any)["agentgateway.dev/apikey"] != "true" {
		t.Fatal("label must survive")
	}
}

func TestEntriesAndUnregister(t *testing.T) {
	_, a := setup(t)
	ctx := context.Background()
	if m, err := a.Entries(ctx); err != nil || len(m) != 0 {
		t.Fatalf("%v %v", m, err)
	}
	_ = a.Register(ctx, "ns.x", "sha256:1", nil, "")
	_ = a.Register(ctx, "ns.y", "sha256:2", nil, "")
	m, err := a.Entries(ctx)
	if err != nil || m["ns.x"].Hash != "sha256:1" || m["ns.y"].Hash != "sha256:2" || len(m) != 2 {
		t.Fatalf("%v %v", m, err)
	}
	if err := a.Unregister(ctx, "ns.x"); err != nil {
		t.Fatal(err)
	}
	m, _ = a.Entries(ctx)
	if _, ok := m["ns.x"]; ok {
		t.Fatal("x should be gone")
	}
	if m["ns.y"].Hash != "sha256:2" {
		t.Fatal("y must stay")
	}
}

func TestEntriesListsAnUnreadableEntryWithAnEmptyHash(t *testing.T) {
	s, a := setup(t)
	s.Modify("configmaps", "agentgateway-system", ConfigMapName, func(o kubetest.Object) {
		o["data"] = map[string]any{"junk": "not json", "empty": ""}
	})
	m, err := a.Entries(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if h, ok := m["junk"]; !ok || h.Hash != "" {
		t.Fatalf("an entry nobody can use must be listed (so it can be swept) with no hash: %v", m)
	}
}

func TestEntriesOfAMissingConfigMapIsAnError(t *testing.T) {
	s := kubetest.New()
	defer s.Close()
	a := New(kube.New(s.URL, s.Client(), func() (string, error) { return "t", nil }), "agentgateway-system")
	if _, err := a.Entries(context.Background()); err == nil {
		t.Fatal("want an error")
	}
}

func TestUnregisterOfMissingEntryIsFine(t *testing.T) {
	_, a := setup(t)
	if err := a.Unregister(context.Background(), "never"); err != nil {
		t.Fatal(err)
	}
}

func TestMissingConfigMapIsAnError(t *testing.T) {
	s := kubetest.New()
	defer s.Close()
	a := New(kube.New(s.URL, s.Client(), func() (string, error) { return "t", nil }), "agentgateway-system")
	if err := a.Register(context.Background(), "ns.x", "sha256:1", nil, ""); err == nil {
		t.Fatal("the chart creates the ConfigMap; a missing one is an error, not something to create")
	}
	if err := a.Unregister(context.Background(), "ns.x"); err != nil {
		t.Fatalf("nothing to unregister when the map is gone: %v", err)
	}
}

func TestUserNamesThatCouldBreakTheEntryAreRefused(t *testing.T) {
	_, a := setup(t)
	for _, bad := range []string{`x","y`, "researcher", "kagent.", ".x", "a.b.c", "KAGENT.x", "kagent.x y", "kagent.x\n"} {
		if err := a.Register(context.Background(), bad, "sha256:1", nil, ""); err == nil {
			t.Errorf("%q must be refused: a definition's user is <namespace>.<name>", bad)
		}
	}
}

func TestRegisterCarriesTeamAndProjectAsMetadataNextToTheUserID(t *testing.T) {
	s, a := setup(t)
	labels := map[string]string{"openagentix.io/team": "payments", "openagentix.io/project": "ledger", "openagentix.io/work-item": "wi-1", "other": "x"}
	if err := a.Register(context.Background(), "kagent.r", "sha256:abc", labels, ""); err != nil {
		t.Fatal(err)
	}
	cm, _ := s.Get("configmaps", "agentgateway-system", ConfigMapName)
	got := cm["data"].(map[string]any)["kagent.r"].(string)
	want := `{"keyHash":"sha256:abc","metadata":{"user_id":"kagent.r","team":"payments","project":"ledger"}}`
	if got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
	m, _ := a.Entries(context.Background())
	e := m["kagent.r"]
	if e.Hash != "sha256:abc" || e.Labels["openagentix.io/team"] != "payments" || e.Labels["openagentix.io/project"] != "ledger" || len(e.Labels) != 2 {
		t.Fatalf("%+v", e)
	}
}

func TestEntryKeyIsAValidConfigMapKeyAndUniquePerNamespaceAndName(t *testing.T) {
	// ConfigMap keys: alphanumerics, '-', '_' or '.', at most 253 characters. The gateway ignores the key's text (it reads
	// the entry's JSON), see agentgateway controller/pkg/agentgateway/plugins/traffic_plugin.go (processAPIKeyAuthenticationPolicy).
	key := regexp.MustCompile(`^[-._a-zA-Z0-9]+$`)
	seen := map[string]bool{}
	for _, c := range [][2]string{{"kagent", "researcher"}, {"team-a", "researcher"}, {"team-b", "researcher"}, {"a", "b-c"}, {"a-b", "c"}} {
		u := "" + c[0] + "." + c[1]
		if !userRE.MatchString(u) || !key.MatchString(u) || len(u) > 253 || seen[u] {
			t.Errorf("%q", u)
		}
		seen[u] = true
	}
}
