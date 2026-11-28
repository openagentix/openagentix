package store

import (
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strings"
	"time"
)

// A graph schema (ADR 0030, section 5) is a small optional list of the entity
// types of a collection, each with a key pattern its names must match, and the
// relation types, each with the entity types allowed at its two ends. No
// subtypes, no inference. The body is checked by graph.ParseSchema; a store only
// keeps it and, under the collection's graph lock, checks facts against it.

// MaxViolationsShown is how many violations an answer names.
const MaxViolationsShown = 20

var (
	// ErrSchemaNotFound is returned when a collection has no schema.
	ErrSchemaNotFound = errors.New("graph schema not found")
	// ErrSchemasDisabled is returned by a store that was opened without schema support.
	ErrSchemasDisabled = errors.New("graph schemas are not enabled")
	// ErrSchemaMoved is returned by ReplaceFactSet when the schema of the collection is not the one the fact set was shaped for
	// (FactSet.SchemaSHA): the caller reads the schema again and tries again.
	ErrSchemaMoved = errors.New("the graph schema of the collection changed")
	// ErrSchemaVersion is returned when a schema does not carry a higher version than the stored one.
	ErrSchemaVersion = errors.New("graph schema version is not higher than the stored one")
	// ErrSchemaViolation matches every *SchemaViolationError.
	ErrSchemaViolation = errors.New("graph schema violated")
)

// SchemaEntityType is one entity type of a schema. Key is an RE2 pattern that the whole entity name must match.
type SchemaEntityType struct {
	Name        string `json:"name"`
	Key         string `json:"key,omitempty"`
	Description string `json:"description,omitempty"`
}

// SchemaRelationType is one relation type: the entity types allowed at each end.
type SchemaRelationType struct {
	Name        string   `json:"name"`
	From        []string `json:"from"`
	To          []string `json:"to"`
	Description string   `json:"description,omitempty"`
}

// GraphSchema is the schema of one collection.
type GraphSchema struct {
	Version       int                  `json:"version"`
	EntityTypes   []SchemaEntityType   `json:"entityTypes"`
	RelationTypes []SchemaRelationType `json:"relationTypes"`

	keys map[string]*regexp.Regexp // entity type -> its key pattern, anchored; set by Compile
}

// StoredSchema is a schema as a store keeps it: the canonical body, its version and SHA-256, and when it was stored.
type StoredSchema struct {
	Collection string
	Version    int
	SHA256     string
	Body       []byte
	UpdatedAt  time.Time
}

// Compile prepares the key patterns. A key is wrapped as ^(?:<key>)$, so that an alternation in it cannot escape the anchors, and compiled with
// Go's regexp (RE2: linear time). It is case sensitive.
func (g *GraphSchema) Compile() error {
	g.keys = map[string]*regexp.Regexp{}
	for _, t := range g.EntityTypes {
		if t.Key == "" {
			continue
		}
		re, err := regexp.Compile("^(?:" + t.Key + ")$")
		if err != nil {
			return fmt.Errorf("entityTypes[%s].key is not a valid RE2 pattern", t.Name)
		}
		g.keys[t.Name] = re
	}
	return nil
}

// SchemaEntity is an entity to check; At says where it is, for the answer.
type SchemaEntity struct{ At, Name, Type string }

// SchemaRelation is a relation to check, with the types of its two ends.
type SchemaRelation struct{ At, Predicate, FromType, ToType string }

// Violation is one place where a fact breaks a schema. Rule is type, key, predicate, from or to. It never holds what the operator wrote.
type Violation struct {
	At   string `json:"at"`
	Rule string `json:"rule"`
}

// Check returns every violation, entities first, in the order given. It needs Compile.
func (g *GraphSchema) Check(ents []SchemaEntity, rels []SchemaRelation) []Violation {
	var out []Violation
	declared := map[string]bool{}
	for _, t := range g.EntityTypes {
		declared[t.Name] = true
	}
	for _, e := range ents {
		if !declared[e.Type] {
			out = append(out, Violation{At: e.At, Rule: "type"})
			continue
		}
		if re := g.keys[e.Type]; re != nil && !re.MatchString(e.Name) {
			out = append(out, Violation{At: e.At, Rule: "key"})
		}
	}
	byName := map[string]SchemaRelationType{}
	for _, r := range g.RelationTypes {
		byName[r.Name] = r
	}
	for _, r := range rels {
		rt, ok := byName[r.Predicate]
		if !ok {
			out = append(out, Violation{At: r.At, Rule: "predicate"})
			continue
		}
		if !slices.Contains(rt.From, r.FromType) {
			out = append(out, Violation{At: r.At, Rule: "from"})
		}
		if !slices.Contains(rt.To, r.ToType) {
			out = append(out, Violation{At: r.At, Rule: "to"})
		}
	}
	return out
}

// CapViolations keeps the first limit violations and counts the rest.
func CapViolations(v []Violation, limit int) (shown []Violation, more int) {
	if len(v) <= limit {
		return v, 0
	}
	return v[:limit], len(v) - limit
}

// SchemaViolationError is a fact set (Kind "factset") or a schema change (Kind "change") that breaks the schema. It names the first violations by place and
// rule, never by what was written, and counts the rest in More.
type SchemaViolationError struct {
	Kind       string
	Violations []Violation
	More       int
}

func (e *SchemaViolationError) Error() string {
	n := len(e.Violations) + e.More
	what := "the fact set does not fit the graph schema of the collection"
	if e.Kind == "change" {
		what = "facts that are already in the collection do not fit the new graph schema"
	}
	var sb strings.Builder
	fmt.Fprintf(&sb, "%s: %d violation(s)", what, n)
	for _, v := range e.Violations {
		fmt.Fprintf(&sb, "; %s: %s", v.At, v.Rule)
	}
	if e.More > 0 {
		fmt.Fprintf(&sb, "; and %d more", e.More)
	}
	return sb.String()
}

// Is makes errors.Is(err, ErrSchemaViolation) true.
func (e *SchemaViolationError) Is(target error) bool { return target == ErrSchemaViolation }

// CheckFactSet checks a fact set against a schema. The violations are placed at entities[i] and relations[j]. The fact set must be valid (Resolve works).
func CheckFactSet(g *GraphSchema, fs FactSet) []Violation {
	return g.Check(factSetFacts(fs, ""))
}

func factSetFacts(fs FactSet, prefix string) ([]SchemaEntity, []SchemaRelation) {
	ents := make([]SchemaEntity, len(fs.Entities))
	for i, e := range fs.Entities {
		ents[i] = SchemaEntity{At: fmt.Sprintf("%sentities[%d]", prefix, i), Name: e.Name, Type: e.Type}
	}
	ends, err := fs.Resolve()
	var rels []SchemaRelation
	if err == nil {
		rels = make([]SchemaRelation, len(fs.Relations))
		for j, r := range fs.Relations {
			rels[j] = SchemaRelation{At: fmt.Sprintf("%srelations[%d]", prefix, j), Predicate: r.Predicate, FromType: fs.Entities[ends[j][0]].Type, ToType: fs.Entities[ends[j][1]].Type}
		}
	}
	return ents, rels
}

// ExistingFacts is what a schema change is checked against: the stored fact sets (by id, in id order) and the extracted entities and relations of the
// collection, the latter already placed at extracted/entities[n] and extracted/relations[n].
type ExistingFacts struct {
	FactSets           []FactSet
	ExtractedEntities  []SchemaEntity
	ExtractedRelations []SchemaRelation
}

// CheckExisting checks everything that is already in a collection against a new schema and returns every violation.
func CheckExisting(g *GraphSchema, ex ExistingFacts) []Violation {
	var out []Violation
	for _, fs := range ex.FactSets {
		out = append(out, g.Check(factSetFacts(fs, "factsets/"+fs.ID+"/"))...)
	}
	return append(out, g.Check(ex.ExtractedEntities, ex.ExtractedRelations)...)
}
