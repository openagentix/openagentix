package routes

import (
	"context"
	"strings"
	"testing"

	"github.com/openagentix/openagentix/services/control-plane/internal/kube"
	"github.com/openagentix/openagentix/services/control-plane/internal/kubetest"
)

func setup(t *testing.T, data string) (*Store, *kubetest.Server) {
	t.Helper()
	srv := kubetest.New()
	t.Cleanup(srv.Close)
	cm := kubetest.Object{"apiVersion": "v1", "kind": "ConfigMap", "metadata": kubetest.Object{"name": "a2a-gate-routes", "namespace": "gate"}}
	if data != "" {
		cm["data"] = map[string]any{"routes.json": data}
	}
	srv.Seed("configmaps", cm)
	cl := kube.New(srv.URL, srv.Client(), func() (string, error) { return "t", nil })
	return &Store{Kube: cl, Namespace: "gate"}, srv
}

func content(srv *kubetest.Server) string {
	o, _ := srv.Get("configmaps", "gate", "a2a-gate-routes")
	d, _ := o["data"].(map[string]any)
	s, _ := d["routes.json"].(string)
	return s
}

func patches(srv *kubetest.Server) int { return len(srv.Matching("PATCH", "/configmaps/")) }

func TestEnsureAddsSortedCompactAndOnlyThatShape(t *testing.T) {
	s, srv := setup(t, `{"container":[]}`)
	ctx := context.Background()
	for _, r := range []string{"kagent/b", "kagent/a"} {
		if err := s.Ensure(ctx, r); err != nil {
			t.Fatal(err)
		}
	}
	if got := content(srv); got != `{"container":["kagent/a","kagent/b"]}` {
		t.Fatal(got)
	}
	if o, _ := srv.Get("configmaps", "gate", "a2a-gate-routes"); len(o["data"].(map[string]any)) != 1 {
		t.Fatalf("only the one key: %v", o["data"])
	}
	n := patches(srv)
	if err := s.Ensure(ctx, "kagent/a"); err != nil || patches(srv) != n {
		t.Fatalf("no write when nothing changes: %v", err)
	}
}

func TestRemoveAndSync(t *testing.T) {
	s, srv := setup(t, `{"container":["kagent/a","kagent/b"]}`)
	ctx := context.Background()
	if err := s.Remove(ctx, "kagent/a"); err != nil || content(srv) != `{"container":["kagent/b"]}` {
		t.Fatalf("%v %s", err, content(srv))
	}
	if err := s.Remove(ctx, "kagent/zzz"); err != nil {
		t.Fatal(err)
	}
	if err := s.Sync(ctx, []string{"kagent/z", "kagent/c", "kagent/c"}); err != nil || content(srv) != `{"container":["kagent/c","kagent/z"]}` {
		t.Fatalf("%v %s", err, content(srv))
	}
	if err := s.Sync(ctx, nil); err != nil || content(srv) != `{"container":[]}` {
		t.Fatalf("%v %s", err, content(srv))
	}
}

func TestForeignOrMissingContentIsRewrittenToTheShape(t *testing.T) {
	for _, in := range []string{"", `{"container":["kagent/a"],"upstream":"http://evil"}`, `not json`, `{"container":"x"}`} {
		s, srv := setup(t, in)
		if err := s.Ensure(context.Background(), "kagent/a"); err != nil {
			t.Fatal(err)
		}
		if got := content(srv); got != `{"container":["kagent/a"]}` {
			t.Fatalf("%q -> %s", in, got)
		}
	}
}

func TestOnlyNamespaceSlashNameIsAccepted(t *testing.T) {
	s, srv := setup(t, `{"container":[]}`)
	for _, bad := range []string{"http://evil/x", "a", "a/b/c", "Kagent/a", "kagent/a b", `kagent/a"]}`, "kagent/", "/a", "kagent/-a"} {
		if err := s.Ensure(context.Background(), bad); err == nil {
			t.Errorf("%q must be refused", bad)
		}
	}
	if err := s.Sync(context.Background(), []string{"kagent/ok", "bad"}); err == nil || !strings.Contains(err.Error(), "bad") {
		t.Fatalf("%v", err)
	}
	if content(srv) != `{"container":[]}` {
		t.Fatal("nothing written for a refused ref")
	}
}

func TestMissingConfigMapIsAnError(t *testing.T) {
	srv := kubetest.New()
	t.Cleanup(srv.Close)
	cl := kube.New(srv.URL, srv.Client(), func() (string, error) { return "t", nil })
	if err := (&Store{Kube: cl, Namespace: "gate"}).Ensure(context.Background(), "kagent/a"); err == nil {
		t.Fatal("want an error")
	}
}
