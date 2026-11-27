package replay

import (
	"strings"
	"testing"
)

// CLUSTER and KUBE_CONTEXT that name different clusters are refused before any call.
func TestCtlRefusesAClusterAndAContextThatDisagree(t *testing.T) {
	e := newEnv(t)
	out, code := ctlWith(t, e.rest, []string{"CLUSTER=oa-bank", "KUBE_CONTEXT=kind-other"}, "approvals")
	if code != 1 || !strings.Contains(out, "different clusters") {
		t.Fatalf("want exit 1 and 'different clusters', got %d:\n%s", code, out)
	}
}

// ctl.sh has no default cluster: without CLUSTER or KUBE_CONTEXT it refuses before any kubectl call.
func TestCtlHasNoDefaultCluster(t *testing.T) {
	e := newEnv(t)
	out, code := ctlWith(t, e.rest, []string{"CLUSTER=", "KUBE_CONTEXT="}, "approvals")
	if code != 1 || !strings.Contains(out, "no default cluster") {
		t.Fatalf("want exit 1 and the sentence 'no default cluster', got %d:\n%s", code, out)
	}
	if strings.Contains(out, "kubectl") && strings.Contains(out, "--context") {
		t.Fatalf("a kubectl call was made:\n%s", out)
	}
}
