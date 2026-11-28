package store

import (
	"errors"
	"strings"
	"testing"
)

func sampleSchema(t *testing.T) *GraphSchema {
	t.Helper()
	g := &GraphSchema{
		Version: 1,
		EntityTypes: []SchemaEntityType{
			{Name: "case", Key: "Case DSP-[0-9]{4}-[0-9]{4}"},
			{Name: "merchant", Key: "M-[0-9]{3} .+"},
			{Name: "rule"},
			{Name: "alt", Key: "a|b"}, // an alternation: must still match the whole name
		},
		RelationTypes: []SchemaRelationType{
			{Name: "disputes_charge_at", From: []string{"case"}, To: []string{"merchant"}},
			{Name: "applies_to", From: []string{"rule"}, To: []string{"case", "merchant"}},
		},
	}
	if err := g.Compile(); err != nil {
		t.Fatal(err)
	}
	return g
}

func TestCheckAcceptsAFittingFactSet(t *testing.T) {
	g := sampleSchema(t)
	v := g.Check(
		[]SchemaEntity{{At: "entities[0]", Name: "Case DSP-2025-0001", Type: "case"}, {At: "entities[1]", Name: "M-560 Corner Shop", Type: "merchant"}},
		[]SchemaRelation{{At: "relations[0]", Predicate: "disputes_charge_at", FromType: "case", ToType: "merchant"}},
	)
	if len(v) != 0 {
		t.Fatalf("%+v", v)
	}
}

func TestCheckNamesEveryViolationKindWithItsPlace(t *testing.T) {
	g := sampleSchema(t)
	v := g.Check(
		[]SchemaEntity{
			{At: "entities[0]", Name: "Case DSP-2025-0001", Type: "gadget"},        // type not declared
			{At: "entities[1]", Name: "Case dsp-2025-0001", Type: "case"},          // key: case-sensitive
			{At: "entities[2]", Name: "xCase DSP-2025-0001", Type: "case"},         // key: must match the whole name
			{At: "entities[3]", Name: "Case DSP-2025-0001 and more", Type: "case"}, // key: must match the whole name
			{At: "entities[4]", Name: "ab", Type: "alt"},                           // an alternation does not escape the anchors
			{At: "entities[5]", Name: "b", Type: "alt"},                            // fits
		},
		[]SchemaRelation{
			{At: "relations[0]", Predicate: "owns", FromType: "case", ToType: "merchant"},               // predicate
			{At: "relations[1]", Predicate: "disputes_charge_at", FromType: "rule", ToType: "merchant"}, // from
			{At: "relations[2]", Predicate: "disputes_charge_at", FromType: "case", ToType: "case"},     // to
			{At: "relations[3]", Predicate: "applies_to", FromType: "merchant", ToType: "rule"},         // from and to
		},
	)
	got := []string{}
	for _, x := range v {
		got = append(got, x.At+" "+x.Rule)
	}
	want := []string{
		"entities[0] type", "entities[1] key", "entities[2] key", "entities[3] key", "entities[4] key",
		"relations[0] predicate", "relations[1] from", "relations[2] to", "relations[3] from", "relations[3] to",
	}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("got  %v\nwant %v", got, want)
	}
}

func TestViolationsNeverRepeatWhatTheOperatorWrote(t *testing.T) {
	g := sampleSchema(t)
	v := g.Check([]SchemaEntity{{At: "entities[0]", Name: "SECRET-NAME-123", Type: "case"}}, nil)
	err := &SchemaViolationError{Kind: "factset", Violations: v}
	if strings.Contains(err.Error(), "SECRET-NAME-123") {
		t.Fatalf("the error repeats a name: %s", err)
	}
	for _, x := range v {
		if strings.Contains(x.At+x.Rule, "SECRET") {
			t.Fatalf("%+v", x)
		}
	}
}

func TestCapViolationsShowsTwentyAndCountsTheRest(t *testing.T) {
	var all []Violation
	for i := 0; i < 27; i++ {
		all = append(all, Violation{At: "entities[x]", Rule: "type"})
	}
	shown, more := CapViolations(all, MaxViolationsShown)
	if len(shown) != 20 || more != 7 {
		t.Fatalf("%d shown, %d more", len(shown), more)
	}
	shown, more = CapViolations(all[:20], MaxViolationsShown)
	if len(shown) != 20 || more != 0 {
		t.Fatalf("%d shown, %d more", len(shown), more)
	}
	if shown, more = CapViolations(nil, MaxViolationsShown); len(shown) != 0 || more != 0 {
		t.Fatalf("%d shown, %d more", len(shown), more)
	}
}

func TestViolationErrorsMatchTheirSentinel(t *testing.T) {
	e := &SchemaViolationError{Kind: "factset", Violations: []Violation{{At: "entities[0]", Rule: "type"}}, More: 2}
	if !errors.Is(e, ErrSchemaViolation) {
		t.Fatal("a violation error must match ErrSchemaViolation")
	}
	var got *SchemaViolationError
	if !errors.As(error(e), &got) || got.More != 2 {
		t.Fatal("errors.As")
	}
}

func TestCompileRefusesABadKey(t *testing.T) {
	g := &GraphSchema{Version: 1, EntityTypes: []SchemaEntityType{{Name: "case", Key: "("}}}
	if err := g.Compile(); err == nil || !strings.Contains(err.Error(), "case") {
		t.Fatalf("%v", err)
	}
}
