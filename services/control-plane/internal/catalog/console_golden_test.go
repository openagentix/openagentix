package catalog

import (
	"bytes"
	"os"
	"testing"
)

// The console is its own Go module and must not import this one, so it keeps a copy of the catalog and policy this
// package loads (services/console/internal/platform/testdata) and reads them in its own tests. The chart tests compare
// the chart's render to testdata/catalog.json here, so the chain is: chart render == these files == the console's
// copies. A change to the catalog shape that is not carried over to the console copies fails this test, and a console
// that cannot read the copies fails its own.
func TestConsoleGoldenFilesAreCopiesOfTheControllerTestdata(t *testing.T) {
	for _, name := range []string{"catalog.json", "policy.json"} {
		mine, err := os.ReadFile("../../testdata/" + name)
		if err != nil {
			t.Fatal(err)
		}
		theirs, err := os.ReadFile("../../../console/internal/platform/testdata/" + name)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(mine, theirs) {
			t.Errorf("services/console/internal/platform/testdata/%s differs from services/control-plane/testdata/%s: copy it (cp services/control-plane/testdata/%s services/console/internal/platform/testdata/%s)", name, name, name, name)
		}
	}
}
