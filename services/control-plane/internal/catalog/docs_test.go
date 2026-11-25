package catalog

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

// The reference pages under docs/diary/reference show JSON examples of the policy and the catalog. A block that follows the line
// "<!-- check:policy -->" or "<!-- check:catalog -->" must be accepted by the real loaders, so an example cannot rot.
var docBlockRE = regexp.MustCompile("(?s)<!-- check:(policy|catalog) -->\n```json\n(.*?)\n```")

func TestReferenceExamplesLoad(t *testing.T) {
	pages, err := filepath.Glob("../../../../docs/diary/reference/*.md")
	if err != nil || len(pages) == 0 {
		t.Fatalf("no reference pages found (%v)", err)
	}
	seen := map[string]int{}
	for _, page := range pages {
		b, err := os.ReadFile(page)
		if err != nil {
			t.Fatal(err)
		}
		for i, m := range docBlockRE.FindAllStringSubmatch(string(b), -1) {
			kind, body := m[1], m[2]
			f := filepath.Join(t.TempDir(), kind+".json")
			if err := os.WriteFile(f, []byte(body), 0o600); err != nil {
				t.Fatal(err)
			}
			seen[kind]++
			switch kind {
			case "policy":
				if _, err := LoadPolicy(f); err != nil {
					t.Errorf("%s: policy example %d is refused: %v", filepath.Base(page), i+1, err)
				}
			case "catalog":
				if _, err := LoadCatalog(f); err != nil {
					t.Errorf("%s: catalog example %d is refused: %v", filepath.Base(page), i+1, err)
				}
			}
		}
	}
	for _, kind := range []string{"policy", "catalog"} {
		if seen[kind] == 0 {
			t.Errorf("no %s example is marked with <!-- check:%s --> in the reference pages", kind, kind)
		}
	}
}
