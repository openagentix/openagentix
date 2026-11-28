package access

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A group's value must never be the admin token: every tool server of the group holds the value, and the admin token writes any collection (review L3).
func TestACallerValueEqualToTheAdminTokenStopsTheStart(t *testing.T) {
	f, d := fixture(t, twoCallers, map[string]string{"bank": "Bearer the-admin-token-0001", "equip": canaryB})
	a, err := Load(f, d, quiet())
	if err != nil {
		t.Fatal(err)
	}
	err = a.RejectAdminToken("the-admin-token-0001")
	if err == nil || !strings.Contains(err.Error(), `"bank"`) {
		t.Fatalf("want a refusal that names the caller: %v", err)
	}
	if strings.Contains(err.Error(), "the-admin-token-0001") {
		t.Fatalf("the error holds the value: %v", err)
	}
}

func TestADifferentAdminTokenOrNoneIsFine(t *testing.T) {
	f, d := fixture(t, twoCallers, map[string]string{"bank": canaryA, "equip": canaryB})
	a, err := Load(f, d, quiet())
	if err != nil {
		t.Fatal(err)
	}
	if err := a.RejectAdminToken("another-token"); err != nil {
		t.Fatal(err)
	}
	if err := a.RejectAdminToken(""); err != nil {
		t.Fatalf("no admin token: nothing to compare: %v", err)
	}
}

func TestTheAdminTokenIsNeverACallerEvenIfAFileChangesAfterTheStart(t *testing.T) {
	f, d := fixture(t, twoCallers, map[string]string{"bank": canaryA, "equip": canaryB})
	a, err := Load(f, d, quiet())
	if err != nil {
		t.Fatal(err)
	}
	if err := a.RejectAdminToken("admin-token-xyz-99"); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(d, "bank"), []byte("Bearer admin-token-xyz-99"), 0o600); err != nil {
		t.Fatal(err)
	}
	if id := a.Identify("Bearer admin-token-xyz-99"); id.Known {
		t.Fatalf("the admin token must not identify a caller: %+v", id)
	}
}
