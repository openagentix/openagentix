package access

import (
	"bytes"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const canaryA = "Bearer canary-value-AAAA-1111"
const canaryB = "Bearer canary-value-BBBB-2222"

// fixture writes access.json and one credential file per caller, and returns their paths.
func fixture(t *testing.T, accessJSON string, creds map[string]string) (accessFile, dir string) {
	t.Helper()
	root := t.TempDir()
	accessFile = filepath.Join(root, "access.json")
	dir = filepath.Join(root, "callers")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(accessFile, []byte(accessJSON), 0o644); err != nil {
		t.Fatal(err)
	}
	for n, v := range creds {
		if err := os.WriteFile(filepath.Join(dir, n), []byte(v), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return accessFile, dir
}

const twoCallers = `{"mode":"enforce","callers":[{"name":"bank","collections":["fernvale-disputes"]},{"name":"equip","collections":["kestrel-service","shared-x"]}]}`

func quiet() *slog.Logger { return slog.New(slog.NewJSONHandler(&bytes.Buffer{}, nil)) }

func load(t *testing.T, accessJSON string, creds map[string]string) (*Authorizer, error) {
	t.Helper()
	f, d := fixture(t, accessJSON, creds)
	return Load(f, d, quiet())
}

func TestLoadEmptyPathMeansOff(t *testing.T) {
	a, err := Load("", "", nil)
	if err != nil || a != nil {
		t.Fatalf("want nil authorizer and no error, got %v %v", a, err)
	}
}

func TestIdentify(t *testing.T) {
	a, err := load(t, twoCallers, map[string]string{"bank": canaryA + "\n", "equip": canaryB})
	if err != nil {
		t.Fatal(err)
	}
	if a.Mode() != Enforce {
		t.Fatalf("mode %q", a.Mode())
	}
	id := a.Identify(canaryA)
	if !id.Known || id.Name != "bank" || len(id.Collections) != 1 || id.Collections[0] != "fernvale-disputes" {
		t.Fatalf("bank: %+v", id)
	}
	id = a.Identify(canaryB)
	if !id.Known || id.Name != "equip" || len(id.Collections) != 2 {
		t.Fatalf("equip: %+v", id)
	}
	for _, bad := range []string{"", "Bearer ", "Bearer wrong", canaryA + "x", strings.TrimPrefix(canaryA, "Bearer "), "bearer canary-value-AAAA-1111"} {
		if id := a.Identify(bad); id.Known || id.Name != "" {
			t.Errorf("%q must be unknown, got %+v", bad, id)
		}
	}
}

func TestEmptyCredentialFileNeverMatchesEmptyHeader(t *testing.T) {
	// A start refuses an empty file, so write it after the start to model a rotation gone wrong.
	f, d := fixture(t, twoCallers, map[string]string{"bank": canaryA, "equip": canaryB})
	a, err := Load(f, d, quiet())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(d, "bank"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	for _, h := range []string{"", "Bearer ", "Bearer"} {
		if id := a.Identify(h); id.Known {
			t.Fatalf("%q matched an empty file: %+v", h, id)
		}
	}
	if id := a.Identify(canaryB); !id.Known || id.Name != "equip" {
		t.Fatalf("other caller must still work: %+v", id)
	}
}

func TestValueReadOnEveryRequest(t *testing.T) {
	f, d := fixture(t, twoCallers, map[string]string{"bank": canaryA, "equip": canaryB})
	a, err := Load(f, d, quiet())
	if err != nil {
		t.Fatal(err)
	}
	const rotated = "Bearer rotated-value-9999"
	if err := os.WriteFile(filepath.Join(d, "bank"), []byte(rotated), 0o600); err != nil {
		t.Fatal(err)
	}
	if id := a.Identify(canaryA); id.Known {
		t.Fatal("the old value must stop working at once")
	}
	if id := a.Identify(rotated); !id.Known || id.Name != "bank" {
		t.Fatalf("the new value must work with no restart: %+v", id)
	}
}

func TestUnreadableCredentialAtRequestTimeFailsClosed(t *testing.T) {
	f, d := fixture(t, twoCallers, map[string]string{"bank": canaryA, "equip": canaryB})
	logs := &bytes.Buffer{}
	a, err := Load(f, d, slog.New(slog.NewJSONHandler(logs, nil)))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(d, "bank")); err != nil {
		t.Fatal(err)
	}
	if id := a.Identify(canaryA); id.Known {
		t.Fatal("a caller whose file vanished must not be known")
	}
	if strings.Contains(logs.String(), "canary-value") {
		t.Fatal("log holds a value")
	}
}

func TestSameValueForTwoCallersIsKnownToNeither(t *testing.T) {
	a, err := load(t, twoCallers, map[string]string{"bank": canaryA, "equip": canaryA})
	if err != nil {
		t.Fatal(err)
	}
	if id := a.Identify(canaryA); id.Known {
		t.Fatalf("an ambiguous value must fail closed: %+v", id)
	}
}

func TestLoadRefusals(t *testing.T) {
	ok := map[string]string{"bank": canaryA, "equip": canaryB}
	cases := []struct {
		name, json string
		creds      map[string]string
		want       string
	}{
		{"unknown key", `{"mode":"enforce","callers":[],"extra":1}`, ok, "extra"},
		{"bad mode", `{"mode":"maybe","callers":[{"name":"bank","collections":["a"]}]}`, ok, "mode"},
		{"empty mode", `{"mode":"","callers":[{"name":"bank","collections":["a"]}]}`, ok, "mode"},
		{"no callers", `{"mode":"enforce","callers":[]}`, ok, "callers"},
		{"bad caller name", `{"mode":"enforce","callers":[{"name":"../bank","collections":["a"]}]}`, ok, "../bank"},
		{"duplicate caller", `{"mode":"enforce","callers":[{"name":"bank","collections":["a"]},{"name":"bank","collections":["b"]}]}`, ok, "bank"},
		{"bad collection", `{"mode":"enforce","callers":[{"name":"bank","collections":["bad name"]}]}`, ok, "bank"},
		{"duplicate collection", `{"mode":"enforce","callers":[{"name":"bank","collections":["a","a"]}]}`, ok, "bank"},
		{"missing file", `{"mode":"enforce","callers":[{"name":"bank","collections":["a"]},{"name":"zzz","collections":["b"]}]}`, ok, "zzz"},
		{"empty file", `{"mode":"report","callers":[{"name":"bank","collections":["a"]}]}`, map[string]string{"bank": "\n"}, "bank"},
		{"value without Bearer prefix", `{"mode":"report","callers":[{"name":"bank","collections":["a"]}]}`, map[string]string{"bank": "plain-token"}, "bank"},
		{"trailing data", `{"mode":"enforce","callers":[{"name":"bank","collections":["a"]}]} {}`, ok, "after"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := load(t, c.json, c.creds)
			if err == nil {
				t.Fatal("want a refusal")
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Fatalf("error %q must name %q", err, c.want)
			}
			if strings.Contains(err.Error(), "canary-value") || strings.Contains(err.Error(), "plain-token") {
				t.Fatalf("error holds a value: %v", err)
			}
		})
	}
}

func TestMissingAccessFileIsAnError(t *testing.T) {
	if _, err := Load(filepath.Join(t.TempDir(), "nope.json"), t.TempDir(), nil); err == nil {
		t.Fatal("a named but missing access.json must stop the start")
	}
}

func TestEmptyListInEnforceIsKnownAndReadsNothing(t *testing.T) {
	a, err := load(t, `{"mode":"enforce","callers":[{"name":"diag","collections":[]}]}`, map[string]string{"diag": canaryA})
	if err != nil {
		t.Fatal(err)
	}
	id := a.Identify(canaryA)
	if !id.Known || id.Name != "diag" || len(id.Collections) != 0 {
		t.Fatalf("%+v", id)
	}
}

func TestReportModeLoads(t *testing.T) {
	a, err := load(t, `{"mode":"report","callers":[{"name":"bank","collections":[]}]}`, map[string]string{"bank": canaryA})
	if err != nil {
		t.Fatal(err)
	}
	if a.Mode() != Report {
		t.Fatalf("mode %q", a.Mode())
	}
}
