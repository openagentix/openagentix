package graph

import (
	"strings"
	"testing"

	"github.com/openagentix/openagentix/services/kb/internal/store"
)

func schemaWithKey(key string) []byte {
	b := strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(key)
	return []byte(`{"version":1,"entityTypes":[{"name":"case","key":"` + b + `"}],"relationTypes":[]}`)
}

// Review M3: a key may not close the wrap ^(?:key)$ from inside and match every name.
func TestAKeyThatClosesTheWrapIsRefused(t *testing.T) {
	for _, key := range []string{
		`Case DSP-[0-9]{4})|(?:.*`, // the shown case: the second alternative matches any name
		`a)|(b`,
		`)`,
		`(`,
		`a)(`,
		`(?i)x`, // a flag that makes the key case insensitive: the record says case sensitive
		`(?i:x)`,
		`a\`,
		`[a-`,
	} {
		_, _, _, err := ParseSchema(schemaWithKey(key))
		if err == nil {
			t.Errorf("key %q was accepted", key)
			continue
		}
		if strings.Contains(err.Error(), key) {
			t.Errorf("the error repeats the key: %v", err)
		}
	}
}

func TestAnEmptyKeyIsNoKey(t *testing.T) {
	g, _, _, err := ParseSchema(schemaWithKey(``))
	if err != nil {
		t.Fatal(err)
	}
	if v := g.Check([]store.SchemaEntity{{At: "entities[0]", Name: "anything at all", Type: "case"}}, nil); len(v) != 0 {
		t.Fatalf("no key means no constraint: %+v", v)
	}
}

func TestKeysThatAreFineStillWorkAndAreAnchored(t *testing.T) {
	for key, cases := range map[string]map[string]bool{
		`Case DSP-[0-9]{4}`:          {"Case DSP-2025": true, "Case DSP-2025x": false, "xCase DSP-2025": false},
		`a|b`:                        {"a": true, "b": true, "ab": false},
		`(?:a|b)c`:                   {"ac": true, "bc": true, "c": false},
		`M-[0-9]{3} .+`:              {"M-560 Corner Shop": true, "M-560": false},
		`[A-Z][a-z]+( [A-Z][a-z]+)*`: {"Priya Venkat": true, "priya": false},
	} {
		g, _, _, err := ParseSchema(schemaWithKey(key))
		if err != nil {
			t.Fatalf("key %q refused: %v", key, err)
		}
		for name, want := range cases {
			v := g.Check([]store.SchemaEntity{{At: "entities[0]", Name: name, Type: "case"}}, nil)
			if (len(v) == 0) != want {
				t.Errorf("key %q name %q: fits=%v want %v", key, name, len(v) == 0, want)
			}
		}
	}
}

// The store compiles the key again when it reads a stored schema; the same rules hold there, so a stored body cannot bring back a key that the parser refuses.
func TestTheStoreRefusesWhatTheParserRefuses(t *testing.T) {
	g := store.GraphSchema{Version: 1, EntityTypes: []store.SchemaEntityType{{Name: "case", Key: `Case DSP-[0-9]{4})|(?:.*`}}}
	if err := g.Compile(); err == nil {
		t.Fatal("Compile accepted a key that closes the wrap")
	}
}
