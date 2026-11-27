package equipment

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The bank graph seed once named ids that the records seed did not have. Every machine, part, dealer and fault code that the knowledge base documents and
// the graph facts of examples/use-cases/equipment name must exist in the records seed, and the facts about them (the supersession, the dealer's name) must match.
func TestUseCaseSeedIdsExistInTheRecordsSeed(t *testing.T) {
	d, _ := newDomain(t)
	root := filepath.Join("..", "..", "..", "equipment", "seed")
	var files []string
	for _, pat := range []string{"kb/*.md", "graph/*.yaml"} {
		m, err := filepath.Glob(filepath.Join(root, pat))
		if err != nil || len(m) == 0 {
			t.Fatalf("no files for %s (%v)", pat, err)
		}
		files = append(files, m...)
	}
	checks := []struct {
		kind, query string
		re          *regexp.Regexp
	}{
		{"machine", `SELECT COUNT(*) FROM machines WHERE serial=?`, regexp.MustCompile(`\b(?:KT|KH|KB)[0-9]{2,4}-[0-9]{5}\b`)},
		{"part", `SELECT COUNT(*) FROM parts WHERE id=?`, regexp.MustCompile(`\bP-[0-9]{5}\b`)},
		{"dealer", `SELECT COUNT(*) FROM dealers WHERE id=?`, regexp.MustCompile(`\bD-[0-9]{3}\b`)},
		{"fault code", `SELECT COUNT(*) FROM fault_codes WHERE code=?`, regexp.MustCompile(`\bE-[0-9]{3}\b`)},
	}
	found := map[string]int{}
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for _, c := range checks {
			for _, id := range c.re.FindAllString(string(raw), -1) {
				found[c.kind]++
				if n := count(t, d, c.query, id); n != 1 {
					t.Errorf("%s names the %s %s, which is not in the records seed", filepath.Base(f), c.kind, id)
				}
			}
		}
	}
	for _, c := range checks {
		if found[c.kind] == 0 {
			t.Errorf("no %s id found in the seed files: the test checks nothing for it", c.kind)
		}
	}
	// The facts the scenarios and the documents state.
	if n := count(t, d, `SELECT COUNT(*) FROM parts WHERE id='P-10006' AND superseded_by='P-10361'`); n != 1 {
		t.Error("the seed documents say P-10006 is superseded by P-10361; the records seed does not")
	}
	var name string
	if err := d.db.QueryRow(`SELECT name FROM dealers WHERE id='D-403'`).Scan(&name); err != nil || name != "Copperton Machinery" {
		t.Errorf("the graph names D-403 as Copperton Machinery; the records seed says %q (%v)", name, err)
	}
	if n := count(t, d, `SELECT COUNT(*) FROM fault_codes WHERE code='E-901' AND safety_critical=1`); n != 1 {
		t.Error("the safety document relies on E-901 being safety critical")
	}
	raw, _ := os.ReadFile(filepath.Join(root, "kb", "out-of-warranty.md"))
	for _, code := range regexp.MustCompile(`E-3[0-9]{2}`).FindAllString(string(raw), -1) {
		if n := count(t, d, `SELECT COUNT(*) FROM fault_codes WHERE code=? AND warrantable=0`, code); n != 1 {
			t.Errorf("out-of-warranty.md lists %s as a wear item; the records seed has it as a warranty item", code)
		}
	}
	if !strings.Contains(string(raw), "E-345") {
		t.Error("out-of-warranty.md must name E-345, the flapping sensor code")
	}
}
