package bank

import (
	"context"
	"os"
	"regexp"
	"strings"
	"testing"
)

// The first real-model run (issue 229) found graph facts for "Case DSP-0001" and "Marrowgate Travel" that matched no record: the graph seed named cases
// without the year and merchants without their id. The graph seed (examples/use-cases/bank/seed/graph) must agree with the records seed: every case id,
// merchant id and device in it exists in the seeded records, and every case sits at the merchant the graph says.

const graphSeed = "../../../bank/seed/graph/dispute-facts.yaml"

var (
	entityLine   = regexp.MustCompile(`^\s*- \{name: ([^,}]+)`)
	aliasesIn    = regexp.MustCompile(`aliases: \[([^\]]*)\]`)
	relationLine = regexp.MustCompile(`^\s*- \{source: ([^,]+), predicate: ([^,]+), target: ([^}]+)\}`)
	caseID       = regexp.MustCompile(`^Case (DSP-\d{4}-\d{4})$`)
	merchantID   = regexp.MustCompile(`^M-\d{3}$`)
)

type graphEntity struct {
	name    string
	aliases []string
}

func readGraph(t *testing.T) (entities []graphEntity, relations [][3]string) {
	t.Helper()
	raw, err := os.ReadFile(graphSeed)
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(string(raw), "\n") {
		if m := entityLine.FindStringSubmatch(line); m != nil {
			e := graphEntity{name: strings.TrimSpace(m[1])}
			if a := aliasesIn.FindStringSubmatch(line); a != nil {
				for _, x := range strings.Split(a[1], ",") {
					e.aliases = append(e.aliases, strings.TrimSpace(x))
				}
			}
			entities = append(entities, e)
		}
		if m := relationLine.FindStringSubmatch(line); m != nil {
			relations = append(relations, [3]string{strings.TrimSpace(m[1]), strings.TrimSpace(m[2]), strings.TrimSpace(m[3])})
		}
	}
	return
}

func TestGraphSeedAgreesWithTheRecordsSeed(t *testing.T) {
	d, _ := newDomain(t) // the test clock is in 2026: the case ids carry the year of the day the records pod started
	ctx := context.Background()
	entities, relations := readGraph(t)
	cases, merchants := map[string]string{}, map[string]string{} // entity name -> id
	for _, e := range entities {
		if m := caseID.FindStringSubmatch(e.name); m != nil {
			cases[e.name] = m[1]
			if _, err := d.svc.GetCase(ctx, m[1]); err != nil {
				t.Errorf("the graph names %q, and the records seed has no case %s: %v", e.name, m[1], err)
			}
			continue
		}
		if strings.HasPrefix(e.name, "Case ") {
			t.Errorf("the graph entity %q is not a case id of the form Case DSP-YYYY-NNNN", e.name)
		}
		for _, a := range e.aliases {
			if !merchantID.MatchString(a) {
				continue
			}
			merchants[e.name] = a
			var dbName string
			if err := d.db.QueryRow(`SELECT name FROM merchants WHERE id=?`, a).Scan(&dbName); err != nil {
				t.Errorf("the graph names the merchant %s (%q): not in the records seed: %v", a, e.name, err)
				continue
			}
			if !strings.Contains(e.name, dbName) || !strings.Contains(e.name, a) {
				t.Errorf("the graph entity %q must carry both the merchant id %s and the name %q of the records seed, so that a search by either finds it", e.name, a, dbName)
			}
		}
		if strings.HasPrefix(e.name, "Device dev-") {
			dev := strings.TrimPrefix(e.name, "Device ")
			if n := count(t, d, `SELECT COUNT(*) FROM transactions WHERE device_hash=?`, dev); n == 0 {
				t.Errorf("the graph names the device %s: no transaction of the records seed has it", dev)
			}
		}
	}
	if len(cases) == 0 || len(merchants) == 0 {
		t.Fatalf("the control is empty: %d cases, %d merchants read from the graph seed", len(cases), len(merchants))
	}
	for _, r := range relations {
		id, ok := cases[r[0]]
		if !ok || r[1] != "disputes_charge_at" {
			continue
		}
		want, known := merchants[r[2]]
		if !known {
			t.Errorf("the relation %v targets a merchant entity with no merchant id alias", r)
			continue
		}
		var got string
		if err := d.db.QueryRow(`SELECT merchant_id FROM cases WHERE id=?`, id).Scan(&got); err != nil || got != want {
			t.Errorf("the graph says %s disputes a charge at %s (%s); the records seed says %s", id, r[2], want, got)
		}
	}
	// the fraud ring: five cases at the ring merchant on one device
	ring := 0
	for _, r := range relations {
		if r[1] == "seen_on_device" {
			ring++
			if _, ok := cases[r[0]]; !ok {
				t.Errorf("seen_on_device names %q, which is not a case entity", r[0])
			}
		}
	}
	if ring != 5 {
		t.Errorf("the graph holds %d seen_on_device relations, want the five of the ring", ring)
	}
}
