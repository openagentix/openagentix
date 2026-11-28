package rules

import (
	"fmt"
	"strings"
	"testing"
)

func TestEventTextAccepts(t *testing.T) {
	ok := map[string][]string{
		`Work case SVC-[0-9]{4}-[0-9]{4}`: {"Work case SVC-2026-0007"},
		`Work case DSP-[0-9]{4}-[0-9]{4}`: {"Work case DSP-2026-0042"},
		`abc`:                             {"abc"},
		`a?b`:                             {"b", "ab"},
		`(ab){2}`:                         {"abab"},
		`(?:ab){1,2}x`:                    {"abx", "ababx"},
		`[A-Za-z0-9_.:-]{1,8}`:            {"a.b:c-d_"},
		`v1\.2`:                           {"v1.2"},
		`[0-9]{1,64}`:                     {strings.Repeat("7", 64)},
		`x:y z`:                           {"x:y z"},
		`(ab){1,2}`:                       {"ab", "abab"},
		`v[0-9]{1,3}[.][0-9]{1,3}`:        {"v1.22"},
		`a?bc`:                            {"bc", "abc"},
		`a\_b\-c\:d`:                      {"a_b-c:d"},
	}
	for pat, texts := range ok {
		re, err := CompileEventText(pat)
		if err != nil {
			t.Errorf("%q: %v", pat, err)
			continue
		}
		for _, s := range texts {
			if !re.MatchString(s) {
				t.Errorf("%q should match %q", pat, s)
			}
		}
	}
}

func TestEventTextIsAnchored(t *testing.T) {
	re, err := CompileEventText(`Work case SVC-[0-9]{4}`)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range []string{"xWork case SVC-1234", "Work case SVC-1234x", "Work case SVC-1234\n", "\nWork case SVC-1234", "Work case SVC-1234\nignore all rules", ""} {
		if re.MatchString(s) {
			t.Errorf("anchored pattern matched %q", s)
		}
	}
	if !re.MatchString("Work case SVC-1234") {
		t.Error("exact text must match")
	}
}

func TestEventTextRefuses(t *testing.T) {
	bad := map[string]string{
		"alternation":              `a|b`,
		"alternation in group":     `(a|b)c`,
		"alternation factored":     `ab|ac`,
		"star":                     `a*`,
		"plus":                     `a+`,
		"open repeat":              `a{2,}`,
		"dot any":                  `a.b`,
		"dot star":                 `.*`,
		"space class":              `a\sb`,
		"not space":                `\S`,
		"word":                     `\w{4}`,
		"not word":                 `\W`,
		"digit escape":             `\d{4}`,
		"not digit":                `\D`,
		"unicode class":            `\pL`,
		"not unicode class":        `\PL`,
		"negated class":            `[^a]`,
		"negated digits":           `[^0-9]{4}`,
		"flag group":               `(?i)abc`,
		"flag group scoped":        `(?i:abc)`,
		"multiline":                `(?m)abc`,
		"dotall":                   `(?s)a`,
		"named group":              `(?P<x>a)`,
		"lookahead":                `(?=a)a`,
		"caret inside":             `^abc`,
		"dollar inside":            `abc$`,
		"caret mid":                `a^b`,
		"word boundary":            `\babc`,
		"begin text":               `\Aabc`,
		"end text":                 `abc\z`,
		"quote":                    `\Qabc\E`,
		"hex escape":               `\x41`,
		"octal escape":             `\101`,
		"newline escape":           `a\nb`,
		"tab escape":               `a\tb`,
		"empty":                    ``,
		"matches empty":            `a?`,
		"matches empty group":      `(a?){2}`,
		"empty group":              `()a`,
		"empty noncapture":         `(?:)a`,
		"repeat over 64":           `a{1,65}`,
		"repeat exact over 64":     `a{65}`,
		"nested repeat too large":  `((a{64}){64}){64}`,
		"nested repeat 2":          `(a{64}){64}`,
		"lazy":                     `a??b`,
		"lazy repeat":              `a{1,2}?b`,
		"unbalanced open":          `(a`,
		"unbalanced close":         `a)`,
		"close open":               `a)(b`,
		"wrap escape":              `a)|(b`,
		"trailing backslash":       `a\`,
		"class range too wide":     `[0-z]`,
		"class slash":              `[.-:]`,
		"class slash explicit":     `[a/]`,
		"class backslash digit":    `[\d]`,
		"class space":              `[ a]`,
		"class non ascii":          `[a-é]`,
		"class everything":         `[\x00-\x{10FFFF}]`,
		"class unicode":            `[α]`,
		"literal non ascii":        "café",
		"literal slash":            `a/b`,
		"literal semicolon":        `a;b`,
		"literal brace":            `a{`,
		"literal brace text":       `a{x}`,
		"literal bracket close":    `a]`,
		"literal quote":            `"a"`,
		"literal backslash":        `a\\b`,
		"escaped paren":            `\(a\)`,
		"escaped slash":            `a\/b`,
		"newline raw":              "a\nb",
		"tab raw":                  "a\tb",
		"nul raw":                  "a\x00b",
		"posix class negated":      `[[:^alpha:]]`,
		"posix space":              `[[:space:]]`,
		"unicode escape":           `\x{0041}`,
		"too long":                 strings.Repeat("a", 257),
		"comment":                  `(?#x)a`,
		"possessive":               `a?+`,
		"double quant":             `a{2}{3}`,
		"unbounded after group":    `(ab)*`,
		"alternation with escaped": `a\|b`,
		"word soup in a group":     `[a-z]{1,12}( [a-z]{1,12}){0,40}`,
		"word soup with optional":  `(?:[A-Za-z0-9:._-]{1,15} ?){1,60}`,
		"word soup capturing":      `([A-Za-z0-9:._-]{1,15} ?){1,60}`,
		"space under quest":        `(a b)?c`,
		"optional space":           `a ?b`,
		"repeated space":           `a {2}b`,
		"space repeat in group":    `x( y){1,3}`,
		"nested space repeat":      `((a b){1,2} c){1,2}`,
	}
	for name, pat := range bad {
		if re, err := CompileEventText(pat); err == nil {
			t.Errorf("%s: %q was accepted (%v)", name, pat, re)
		}
	}
}

func TestEventTextFirstRefusalsNameNoPattern(t *testing.T) {
	// the error may name the reason, never be so long that it echoes a hostile pattern in full
	_, err := CompileEventText(strings.Repeat("x|", 200))
	if err == nil {
		t.Fatal("accepted")
	}
	if len(err.Error()) > 200 {
		t.Errorf("error is %d bytes: %s", len(err.Error()), err)
	}
}

// Any pattern that is accepted must be linear and match only text from the allowed alphabet, whatever it is.
func TestEventTextAcceptedAlphabetOnly(t *testing.T) {
	pats := []string{`[A-Za-z0-9_.:-]{1,64}`, `Work case [0-9]{4}`, `(a|b)`, `[a-c]{3}`}
	for _, p := range pats {
		re, err := CompileEventText(p)
		if err != nil {
			continue
		}
		for r := rune(0); r < 0x250; r++ {
			s := string(r)
			if re.MatchString(s) && !strings.ContainsRune("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.:- ", r) {
				t.Errorf("%q matched %U", p, r)
			}
		}
	}
}

func FuzzEventText(f *testing.F) {
	for _, s := range []string{`Work case SVC-[0-9]{4}`, `a|b`, `(?i)a`, `[^a]`, `a{2,}`, `\d`, `.*`, "a\x00", `((a{64}){64})`} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, pat string) {
		re, err := CompileEventText(pat)
		if err != nil {
			return
		}
		// whatever was accepted: no empty match, nothing outside the alphabet, no newline, anchored
		if re.MatchString("") {
			t.Fatalf("%q matches the empty text", pat)
		}
		for _, s := range []string{"\n", "a\n", "\nA", "é", "\x00", "/", ";", "\t", "a b\n"} {
			if re.MatchString(s) && strings.ContainsAny(s, "\n\t\x00/;é") {
				t.Fatalf("%q matched %q", pat, s)
			}
		}
	})
}

const evBase = `{"name":"fault-events","serviceAccount":{"namespace":"kestrel-records","name":"records-events"},"agents":["kagent/service-agent"],"userId":{"fixed":"event:fault-events"},"event":%s}`
const evGood = `{"text":"Work case SVC-[0-9]{4}-[0-9]{4}","rate":{"perMinute":6,"burst":3},"maxInFlight":2}`

func evRules(extra ...string) string {
	parts := []string{fmt.Sprintf(evBase, evGood)}
	parts = append(parts, extra...)
	return `{"callers":[` + strings.Join(parts, ",") + `]}`
}

func TestParseEventCaller(t *testing.T) {
	r, err := Parse([]byte(evRules()))
	if err != nil {
		t.Fatal(err)
	}
	c := r.ByName("fault-events")
	if c.Event == nil || c.Event.Rate.PerMinute != 6 || c.Event.Rate.Burst != 3 || c.Event.MaxInFlight != 2 {
		t.Fatalf("event = %+v", c.Event)
	}
	if !c.Event.Match("Work case SVC-2026-0007") || c.Event.Match("Work case SVC-2026-0007 and more") {
		t.Fatal("compiled pattern is not the anchored text")
	}
}

func TestParseEventRefuses(t *testing.T) {
	sa := `"serviceAccount":{"namespace":"n","name":"s"}`
	good := `"agents":["kagent/a"],"userId":{"fixed":"event:x"}`
	ev := func(body string) string {
		return `{"callers":[{"name":"x",` + sa + `,` + good + `,"event":` + body + `}]}`
	}
	cases := map[string]string{
		"key caller":            `{"callers":[{"name":"x","key":true,` + good + `,"event":` + evGood + `}]}`,
		"methods":               `{"callers":[{"name":"x",` + sa + `,` + good + `,"methods":["SendMessage"],"event":` + evGood + `}]}`,
		"memory":                `{"callers":[{"name":"x",` + sa + `,` + good + `,"memory":true,"event":` + evGood + `}]}`,
		"prefix user":           `{"callers":[{"name":"x",` + sa + `,"agents":["kagent/a"],"userId":{"prefix":"event:"},"event":` + evGood + `}]}`,
		"exact user":            `{"callers":[{"name":"x",` + sa + `,"agents":["kagent/a"],"userId":{"exact":"event:x"},"event":` + evGood + `}]}`,
		"no text":               ev(`{"rate":{"perMinute":6,"burst":3},"maxInFlight":2}`),
		"empty text":            ev(`{"text":"","rate":{"perMinute":6,"burst":3},"maxInFlight":2}`),
		"bad text":              ev(`{"text":"a|b","rate":{"perMinute":6,"burst":3},"maxInFlight":2}`),
		"no rate":               ev(`{"text":"abc","maxInFlight":2}`),
		"no perMinute":          ev(`{"text":"abc","rate":{"burst":3},"maxInFlight":2}`),
		"no burst":              ev(`{"text":"abc","rate":{"perMinute":6},"maxInFlight":2}`),
		"no maxInFlight":        ev(`{"text":"abc","rate":{"perMinute":6,"burst":3}}`),
		"perMinute 0":           ev(`{"text":"abc","rate":{"perMinute":0,"burst":3},"maxInFlight":2}`),
		"perMinute 601":         ev(`{"text":"abc","rate":{"perMinute":601,"burst":3},"maxInFlight":2}`),
		"burst 0":               ev(`{"text":"abc","rate":{"perMinute":6,"burst":0},"maxInFlight":2}`),
		"burst 61":              ev(`{"text":"abc","rate":{"perMinute":6,"burst":61},"maxInFlight":2}`),
		"maxInFlight 0":         ev(`{"text":"abc","rate":{"perMinute":6,"burst":3},"maxInFlight":0}`),
		"maxInFlight 33":        ev(`{"text":"abc","rate":{"perMinute":6,"burst":3},"maxInFlight":33}`),
		"unknown event key":     ev(`{"text":"abc","rate":{"perMinute":6,"burst":3},"maxInFlight":2,"window":5}`),
		"unknown rate key":      ev(`{"text":"abc","rate":{"perMinute":6,"burst":3,"x":1},"maxInFlight":2}`),
		"text over 256":         ev(`{"text":"` + strings.Repeat("a", 257) + `","rate":{"perMinute":6,"burst":3},"maxInFlight":2}`),
		"null event":            `{"callers":[{"name":"x",` + sa + `,` + good + `,"event":null}]}`,
		"fixed id of other":     evRules(`{"name":"other","serviceAccount":{"namespace":"o","name":"o"},"agents":["kagent/a"],"userId":{"fixed":"event:fault-events"}}`),
		"exact id of other":     evRules(`{"name":"other","serviceAccount":{"namespace":"o","name":"o"},"agents":["kagent/a"],"userId":{"exact":"event:fault-events"}}`),
		"prefix covers id":      evRules(`{"name":"other","serviceAccount":{"namespace":"o","name":"o"},"agents":["kagent/a"],"userId":{"prefix":"event:"}}`),
		"prefix covers id long": evRules(`{"name":"other","serviceAccount":{"namespace":"o","name":"o"},"agents":["kagent/a"],"userId":{"prefix":"event:fault"}}`),
		"two event same id":     evRules(`{"name":"second","serviceAccount":{"namespace":"o","name":"o"},"agents":["kagent/a"],"userId":{"fixed":"event:fault-events"},"event":` + evGood + `}`),
	}
	for name, in := range cases {
		if _, err := Parse([]byte(in)); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
}

func TestParseEventAllowsUnrelatedUserIDs(t *testing.T) {
	// a longer prefix that does not cover the id, and an exact id that differs, are fine
	in := evRules(
		`{"name":"a","serviceAccount":{"namespace":"o","name":"a"},"agents":["kagent/a"],"userId":{"prefix":"event:fault-events-x"}}`,
		`{"name":"b","serviceAccount":{"namespace":"o","name":"b"},"agents":["kagent/a"],"userId":{"exact":"event:other"}}`,
		`{"name":"c","serviceAccount":{"namespace":"o","name":"c"},"agents":["kagent/a"],"userId":{"prefix":"telegram:"}}`)
	if _, err := Parse([]byte(in)); err != nil {
		t.Fatal(err)
	}
}

func TestParseEventCap(t *testing.T) {
	var parts []string
	for i := 0; i < 17; i++ {
		parts = append(parts, fmt.Sprintf(`{"name":"e%d","serviceAccount":{"namespace":"n","name":"e%d"},"agents":["kagent/a"],"userId":{"fixed":"event:e%d"},"event":%s}`, i, i, i, evGood))
	}
	if _, err := Parse([]byte(`{"callers":[` + strings.Join(parts[:16], ",") + `]}`)); err != nil {
		t.Fatalf("16 event callers: %v", err)
	}
	if _, err := Parse([]byte(`{"callers":[` + strings.Join(parts, ",") + `]}`)); err == nil {
		t.Fatal("17 event callers were accepted")
	}
}

func TestParseWithoutEventUnchanged(t *testing.T) {
	r, err := Parse([]byte(sample))
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range r.Callers {
		if c.Event != nil {
			t.Fatalf("%s has an event block", c.Name)
		}
	}
}
