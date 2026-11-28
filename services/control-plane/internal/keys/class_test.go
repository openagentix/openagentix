package keys

import (
	"context"
	"testing"
)

// ADR 0029, slice 4. The budget class of an entry follows the class the policy names for definitions. An entry that is already
// registered with the old class is rewritten with the same hash (no new key), and an entry that already has the class is not touched.

func TestANewEntryIsRegisteredWithTheClass(t *testing.T) {
	_, sec, reg := setup(t)
	p := params()
	p.EntryClass = "bank-agents"
	if _, err := Ensure(context.Background(), p, sec, reg, fixed("vk-one")); err != nil {
		t.Fatal(err)
	}
	if reg.classes["r"] != "bank-agents" {
		t.Fatalf("%v", reg.classes)
	}
}

func TestAChangedClassRewritesTheEntryWithTheSameHash(t *testing.T) {
	cases := []struct{ name, registered, entry string }{
		{"none to a class (definitions was set after the entry was written)", "", "bank-agents"},
		{"a class to another class", "case-agent", "bank-agents"},
		{"a class to none (definitions was emptied)", "bank-agents", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s, sec, reg := setup(t)
			p := params()
			p.EntryClass = c.registered
			res, err := Ensure(context.Background(), p, sec, reg, fixed("vk-one"))
			if err != nil {
				t.Fatal(err)
			}
			p.Registered, p.Known, p.RegisteredClass = res.Hash, res.Fingerprint, c.registered
			p.EntryClass = c.entry
			posts, calls := len(s.Matching("POST", "secrets")), reg.calls
			res2, err := Ensure(context.Background(), p, sec, reg, fixed("vk-two"))
			if err != nil || res2.Outcome != Relabeled || res2.Hash != res.Hash {
				t.Fatalf("%+v %v", res2, err)
			}
			if reg.calls != calls+1 || reg.classes["r"] != c.entry || reg.entries["r"] != res.Hash {
				t.Fatalf("calls %d->%d class %q entries %v", calls, reg.calls, reg.classes["r"], reg.entries)
			}
			if len(s.Matching("POST", "secrets")) != posts || len(s.Matching("DELETE", "secrets")) != 0 {
				t.Fatal("a class change must not touch the key Secret")
			}
		})
	}
}

func TestAnEntryThatHasTheClassIsNotTouched(t *testing.T) {
	_, sec, reg := setup(t)
	p := params()
	p.EntryClass = "bank-agents"
	res, err := Ensure(context.Background(), p, sec, reg, fixed("vk-one"))
	if err != nil {
		t.Fatal(err)
	}
	p.Registered, p.Known, p.RegisteredClass = res.Hash, res.Fingerprint, "bank-agents"
	calls := reg.calls
	if res2, err := Ensure(context.Background(), p, sec, reg, fixed("vk-two")); err != nil || res2.Outcome != Unchanged || reg.calls != calls {
		t.Fatalf("%+v %v calls %d->%d", res2, err, calls, reg.calls)
	}
}

func TestASuspendedDefinitionRegistersNothingWhateverTheClass(t *testing.T) {
	_, sec, reg := setup(t)
	p := params()
	p.EntryClass, p.Hold = "bank-agents", true
	if _, err := Ensure(context.Background(), p, sec, reg, fixed("vk-one")); err != nil {
		t.Fatal(err)
	}
	if reg.calls != 0 {
		t.Fatalf("a held key was registered %d time(s)", reg.calls)
	}
}
