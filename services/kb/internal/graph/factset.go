package graph

import (
	"errors"
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/openagentix/openagentix/services/kb/internal/store"
)

// Bounds on one curated fact set.
const (
	MaxFactEntities  = 2000
	MaxFactRelations = 5000
	// MaxFactAliases is higher than MaxAliases of an extraction: an operator
	// writing a catalogue knows the names a thing goes by.
	MaxFactAliases = 10
)

// ErrFactSetTooLarge marks a fact set with more entities or relations than the
// bounds allow.
var ErrFactSetTooLarge = errors.New("fact set too large")

// FactSetError is a fact set that breaks a rule. Its text names the offending
// item by index and never repeats what the operator wrote.
type FactSetError struct{ Msg string }

func (e *FactSetError) Error() string { return e.Msg }

func bad(format string, a ...any) error { return &FactSetError{fmt.Sprintf(format, a...)} }

// ValidateFactSet checks an operator-written catalogue and returns it in the
// form the store keeps: names, descriptions and notes cleaned, types lower
// case, predicates snake_case, aliases unique, every relation endpoint rewritten
// to the declared name of its entity and repeated relations dropped.
//
// The rules are those of an extraction for the shape of things (the entity type
// list, 80 characters for a name, the predicate form) but not for what is
// believable: a curated entity needs no occurrence in a text and may be named
// "database" or be a person without a capital letter; the operator decides.
// A relation names its two ends by the name, an alias or the canonical name
// (see store.CanonicalForm) of an entity declared in the same fact set, which
// keeps a fact set self-contained and its meaning independent of what else is in
// the collection.
func ValidateFactSet(in store.FactSet) (store.FactSet, error) { return ValidateFactSetFor(in, false) }

// ValidateFactSetFor is ValidateFactSet for a collection that has (withSchema) or has not a graph schema. With a schema the entity types are the
// schema's, so only their form is checked here (lower case letters, digits and '_'); the schema itself is checked by the store, under the collection's lock.
func ValidateFactSetFor(in store.FactSet, withSchema bool) (store.FactSet, error) {
	if len(in.Entities) > MaxFactEntities {
		return store.FactSet{}, fmt.Errorf("%w: %d entities, the limit is %d", ErrFactSetTooLarge, len(in.Entities), MaxFactEntities)
	}
	if len(in.Relations) > MaxFactRelations {
		return store.FactSet{}, fmt.Errorf("%w: %d relations, the limit is %d", ErrFactSetTooLarge, len(in.Relations), MaxFactRelations)
	}
	out := store.FactSet{Collection: in.Collection, ID: in.ID, SourceURI: in.SourceURI,
		Entities: make([]store.FactEntity, 0, len(in.Entities)), Relations: make([]store.FactRelation, 0, len(in.Relations))}
	firstOf := map[string]int{} // merge key -> index of the entity that has it
	for i, e := range in.Entities {
		name, ok := cleanName(e.Name)
		if !ok {
			return store.FactSet{}, bad("entities[%d]: name must be valid text of 1 to %d characters without control characters", i, MaxNameRunes)
		}
		typ := strings.ToLower(strings.TrimSpace(e.Type))
		if withSchema {
			if !IsSchemaTypeName(typ) {
				return store.FactSet{}, bad("entities[%d]: type must be a type name of the schema (lower case letters, digits and '_')", i)
			}
		} else if !isEntityType(typ) {
			return store.FactSet{}, bad("entities[%d]: type must be one of %s", i, strings.Join(EntityTypes, ", "))
		}
		key := store.MergeKey(name, typ, "")
		if j, dup := firstOf[key]; dup {
			return store.FactSet{}, bad("entities[%d]: same entity as entities[%d] (names that differ only by a category word such as team or service are one entity)", i, j)
		}
		firstOf[key] = i
		desc := strings.Join(strings.Fields(e.Description), " ")
		if !validText(e.Description) || utf8.RuneCountInString(desc) > MaxDescriptionRunes {
			return store.FactSet{}, bad("entities[%d]: description must be valid text of at most %d characters", i, MaxDescriptionRunes)
		}
		if len(e.Aliases) > MaxFactAliases {
			return store.FactSet{}, bad("entities[%d]: aliases has %d items, the limit is %d", i, len(e.Aliases), MaxFactAliases)
		}
		var aliases []string
		for _, a := range e.Aliases {
			a, ok := cleanName(a)
			if !ok {
				return store.FactSet{}, bad("entities[%d]: alias must be valid text of 1 to %d characters without control characters", i, MaxNameRunes)
			}
			if !strings.EqualFold(a, name) {
				aliases = appendUnique(aliases, []string{a}, MaxFactAliases)
			}
		}
		out.Entities = append(out.Entities, store.FactEntity{Name: name, Type: typ, Description: desc, Aliases: aliases})
	}

	// How a relation may name an entity: its name, else an alias, else a
	// canonical form. A form two entities claim at the same level is ambiguous.
	levels := [3]map[string]int{{}, {}, {}}
	claim := func(m map[string]int, k string, i int) {
		if j, seen := m[k]; seen && j != i {
			m[k] = -1
		} else {
			m[k] = i
		}
	}
	for i, e := range out.Entities {
		claim(levels[0], store.NormalizeName(e.Name), i)
		for _, a := range e.Aliases {
			claim(levels[1], store.NormalizeName(a), i)
		}
		for _, n := range append([]string{e.Name}, e.Aliases...) {
			claim(levels[2], store.CanonicalForm(n), i)
		}
	}
	resolve := func(n string) (idx int, ambiguous bool) {
		forms := [3]string{store.NormalizeName(n), store.NormalizeName(n), store.CanonicalForm(n)}
		for l, m := range levels {
			if i, ok := m[forms[l]]; ok {
				return i, i < 0
			}
		}
		return -1, false
	}
	seen := map[[3]any]bool{}
	for j, r := range in.Relations {
		src, amb := resolve(r.Source)
		switch {
		case amb:
			return store.FactSet{}, bad("relations[%d]: source is ambiguous: more than one entity of the fact set has that name or alias", j)
		case src < 0:
			return store.FactSet{}, bad("relations[%d]: source is not an entity declared in this fact set", j)
		}
		dst, amb := resolve(r.Target)
		switch {
		case amb:
			return store.FactSet{}, bad("relations[%d]: target is ambiguous: more than one entity of the fact set has that name or alias", j)
		case dst < 0:
			return store.FactSet{}, bad("relations[%d]: target is not an entity declared in this fact set", j)
		case dst == src:
			return store.FactSet{}, bad("relations[%d]: source and target are the same entity", j)
		}
		pred := normalizePredicate(r.Predicate)
		if pred == "" {
			return store.FactSet{}, bad("relations[%d]: predicate must be 2 to %d printable ASCII characters starting with a letter, such as owns or depends_on", j, MaxPredicateRunes)
		}
		note := strings.Join(strings.Fields(r.Note), " ")
		if !validText(r.Note) || utf8.RuneCountInString(note) > MaxEvidenceRunes {
			return store.FactSet{}, bad("relations[%d]: note must be valid text of at most %d characters", j, MaxEvidenceRunes)
		}
		k := [3]any{src, pred, dst}
		if seen[k] {
			continue
		}
		seen[k] = true
		out.Relations = append(out.Relations, store.FactRelation{Source: out.Entities[src].Name, Predicate: pred, Target: out.Entities[dst].Name, Note: note})
	}
	return out, nil
}

// validText reports whether s is valid UTF-8 without control characters other
// than white space.
func validText(s string) bool {
	if !utf8.ValidString(s) {
		return false
	}
	for _, r := range s {
		if unicode.IsControl(r) && !unicode.IsSpace(r) {
			return false
		}
	}
	return true
}
