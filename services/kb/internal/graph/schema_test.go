package graph

import (
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/openagentix/openagentix/services/kb/internal/store"
)

func catalogue() store.FactSet {
	return store.FactSet{
		SourceURI: "https://example.test/catalogue",
		Entities:  []store.FactEntity{{Name: "Basalt", Type: "team"}, {Name: "Priya Venkat", Type: "person"}, {Name: "Orion", Type: "service"}},
		Relations: []store.FactRelation{{Source: "Basalt", Predicate: "escalates_to", Target: "Priya Venkat", Note: "n"}},
	}
}

func entsOf(name, typ string) []store.SchemaEntity {
	return []store.SchemaEntity{{At: "entities[0]", Name: name, Type: typ}}
}

const goodSchema = `{
  "version": 3,
  "entityTypes": [
    {"name": "case", "key": "Case DSP-[0-9]{4}-[0-9]{4}", "description": "A dispute case"},
    {"name": "merchant", "key": "M-[0-9]{3} .+"},
    {"name": "rule"}
  ],
  "relationTypes": [
    {"name": "disputes_charge_at", "from": ["case"], "to": ["merchant"]},
    {"name": "applies_to", "from": ["rule"], "to": ["case", "merchant"], "description": "x"}
  ]
}`

func TestParseSchemaAcceptsTheFormat(t *testing.T) {
	g, body, sha, err := ParseSchema([]byte(goodSchema))
	if err != nil {
		t.Fatal(err)
	}
	if g.Version != 3 || len(g.EntityTypes) != 3 || len(g.RelationTypes) != 2 {
		t.Fatalf("%+v", g)
	}
	if len(sha) != 64 || len(body) == 0 {
		t.Fatalf("sha %q body %q", sha, body)
	}
	// the same content in another layout has the same canonical body and hash
	_, body2, sha2, err := ParseSchema([]byte(strings.ReplaceAll(goodSchema, "\n", " ")))
	if err != nil || sha != sha2 || string(body) != string(body2) {
		t.Fatalf("the canonical form must not depend on layout: %v", err)
	}
	// the compiled key is anchored: a name that merely contains a match is refused
	if v := g.Check(nil, nil); v != nil {
		t.Fatal(v)
	}
}

func mutate(t *testing.T, from, to string) string {
	t.Helper()
	if !strings.Contains(goodSchema, from) {
		t.Fatalf("test bug: %q not in the schema", from)
	}
	return strings.Replace(goodSchema, from, to, 1)
}

func TestParseSchemaRefusals(t *testing.T) {
	long := strings.Repeat("a", 201)
	manyTypes := func(n int) string {
		var ts []string
		for i := 0; i < n; i++ {
			ts = append(ts, fmt.Sprintf(`{"name":"t%02d"}`, i))
		}
		return `{"version":1,"entityTypes":[` + strings.Join(ts, ",") + `],"relationTypes":[]}`
	}
	manyRels := func(n int) string {
		var rs []string
		for i := 0; i < n; i++ {
			rs = append(rs, fmt.Sprintf(`{"name":"rel_%03d","from":["a"],"to":["a"]}`, i))
		}
		return `{"version":1,"entityTypes":[{"name":"aa"}],"relationTypes":[` + strings.Join(rs, ",") + `]}`
	}
	manyEnds := `{"version":1,"entityTypes":[` + strings.TrimSuffix(strings.Repeat(`{"name":"ta"},`, 0), ",") + `{"name":"aa"}],"relationTypes":[{"name":"rel","from":["aa","aa","aa","aa","aa","aa","aa","aa","aa","aa","aa"],"to":["aa"]}]}`
	cases := map[string]struct{ body, want string }{
		"not json":                 {`{`, "not valid JSON"},
		"unknown field":            {mutate(t, `"version": 3,`, `"version": 3, "extra": 1,`), "extra"},
		"unknown field in a type":  {mutate(t, `{"name": "rule"}`, `{"name": "rule", "color": "red"}`), "color"},
		"trailing data":            {goodSchema + ` {}`, "after"},
		"version missing":          {mutate(t, `"version": 3,`, ``), "version"},
		"version zero":             {mutate(t, `"version": 3`, `"version": 0`), "version"},
		"version negative":         {mutate(t, `"version": 3`, `"version": -1`), "version"},
		"version too large":        {mutate(t, `"version": 3`, `"version": 2147483648`), "version"},
		"version not an integer":   {mutate(t, `"version": 3`, `"version": 1.5`), "version"},
		"type name upper case":     {mutate(t, `"name": "rule"`, `"name": "Rule"`), "entityTypes[2].name"},
		"type name too short":      {mutate(t, `"name": "rule"`, `"name": "r"`), "entityTypes[2].name"},
		"type name too long":       {mutate(t, `"name": "rule"`, `"name": "`+strings.Repeat("a", 41)+`"`), "entityTypes[2].name"},
		"type name with a dash":    {mutate(t, `"name": "rule"`, `"name": "a-b"`), "entityTypes[2].name"},
		"type declared twice":      {mutate(t, `"name": "rule"`, `"name": "case"`), "entityTypes[2]"},
		"key too long":             {mutate(t, `"key": "M-[0-9]{3} .+"`, `"key": "`+long+`"`), "entityTypes[1].key"},
		"key not RE2":              {mutate(t, `"key": "M-[0-9]{3} .+"`, `"key": "(?=x)"`), "entityTypes[1].key"},
		"key unbalanced":           {mutate(t, `"key": "M-[0-9]{3} .+"`, `"key": "("`), "entityTypes[1].key"},
		"description too long":     {mutate(t, `"description": "A dispute case"`, `"description": "`+strings.Repeat("d", 201)+`"`), "entityTypes[0].description"},
		"too many entity types":    {manyTypes(51), "at most 50"},
		"relation name not snake":  {mutate(t, `"name": "applies_to"`, `"name": "Applies To"`), "relationTypes[1].name"},
		"relation name too long":   {mutate(t, `"name": "applies_to"`, `"name": "`+strings.Repeat("a", 41)+`"`), "relationTypes[1].name"},
		"relation declared twice":  {mutate(t, `"name": "applies_to"`, `"name": "disputes_charge_at"`), "relationTypes[1]"},
		"too many relation types":  {manyRels(101), "at most 100"},
		"from empty":               {mutate(t, `"from": ["rule"]`, `"from": []`), "relationTypes[1].from"},
		"to missing":               {mutate(t, `"to": ["case", "merchant"]`, `"to": null`), "relationTypes[1].to"},
		"from names an undeclared": {mutate(t, `"from": ["rule"]`, `"from": ["gadget"]`), "relationTypes[1].from"},
		"to names an undeclared":   {mutate(t, `"to": ["case", "merchant"]`, `"to": ["case", "gadget"]`), "relationTypes[1].to"},
		"from has more than ten":   {manyEnds, "at most 10"},
		"no entity types":          {`{"version":1,"entityTypes":[],"relationTypes":[]}`, "entityTypes"},
		"body over 64 KiB":         {`{"version":1,"entityTypes":[{"name":"aa","description":"` + strings.Repeat("d", 70000) + `"}],"relationTypes":[]}`, "64 KiB"},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			_, _, _, err := ParseSchema([]byte(c.body))
			if err == nil {
				t.Fatal("want a refusal")
			}
			var se *SchemaError
			if !errors.As(err, &se) {
				t.Fatalf("want a *SchemaError, got %T %v", err, err)
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Fatalf("error %q must name %q", err, c.want)
			}
		})
	}
}

func TestParseSchemaErrorsDoNotEchoTheBody(t *testing.T) {
	_, _, _, err := ParseSchema([]byte(mutate(t, `"key": "M-[0-9]{3} .+"`, `"key": "SECRET-KEY-TEXT("`)))
	if err == nil || strings.Contains(err.Error(), "SECRET-KEY-TEXT") {
		t.Fatalf("%v", err)
	}
}

func TestKeyIsWrappedSoAnAlternationCannotEscape(t *testing.T) {
	body := `{"version":1,"entityTypes":[{"name":"alt","key":"aa|bb"}],"relationTypes":[]}`
	g, _, _, err := ParseSchema([]byte(body))
	if err != nil {
		t.Fatal(err)
	}
	for name, ok := range map[string]bool{"aa": true, "bb": true, "aab": false, "xaa": false, "aabb": false, "AA": false} {
		v := g.Check(entsOf(name, "alt"), nil)
		if (len(v) == 0) != ok {
			t.Errorf("%q: fits=%v, want %v", name, len(v) == 0, ok)
		}
	}
}

func TestValidateFactSetForASchemaTakesTheSchemasTypes(t *testing.T) {
	in := catalogue()
	in.Entities[1].Type = "gadget"
	if _, err := ValidateFactSet(in); err == nil {
		t.Fatal("the built-in list must still apply without a schema")
	}
	out, err := ValidateFactSetFor(in, true)
	if err != nil {
		t.Fatalf("with a schema the type is the schema's business: %v", err)
	}
	if out.Entities[1].Type != "gadget" {
		t.Fatalf("%+v", out.Entities)
	}
	bad := catalogue()
	bad.Entities[1].Type = "Bad Type!"
	if _, err := ValidateFactSetFor(bad, true); err == nil || !strings.Contains(err.Error(), "entities[1]: type") {
		t.Fatalf("a type of no valid form is refused even with a schema: %v", err)
	}
}
