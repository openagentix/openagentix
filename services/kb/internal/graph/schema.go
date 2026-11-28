package graph

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/openagentix/openagentix/services/kb/internal/store"
)

// Bounds on a graph schema (ADR 0030, section 5).
const (
	MaxSchemaBytes        = 64 << 10
	MaxSchemaEntityTypes  = 50
	MaxSchemaRelations    = 100
	MaxSchemaEnds         = 10
	MaxSchemaKeyChars     = 200
	MaxSchemaDescription  = 200
	maxSchemaVersion      = 2147483647
	maxSchemaTypeNameLen  = 40
	schemaTypeNamePattern = `^[a-z][a-z0-9_]{1,39}$`
)

var schemaTypeNameRe = regexp.MustCompile(schemaTypeNamePattern)

// SchemaError is a schema that breaks a rule. Its text names the field by its place and never repeats what the operator wrote.
type SchemaError struct{ Msg string }

func (e *SchemaError) Error() string { return e.Msg }

func schemaBad(format string, a ...any) error { return &SchemaError{fmt.Sprintf(format, a...)} }

// IsSchemaTypeName reports whether a name has the form of a schema's entity type: lower case letters, digits and '_', 2 to 40 characters, starting with a letter.
func IsSchemaTypeName(s string) bool { return schemaTypeNameRe.MatchString(s) }

type rawSchema struct {
	Version       json.Number       `json:"version"`
	EntityTypes   []rawEntityType   `json:"entityTypes"`
	RelationTypes []rawRelationType `json:"relationTypes"`
}

type rawEntityType struct {
	Name        string `json:"name"`
	Key         string `json:"key"`
	Description string `json:"description"`
}

type rawRelationType struct {
	Name        string   `json:"name"`
	From        []string `json:"from"`
	To          []string `json:"to"`
	Description string   `json:"description"`
}

// ParseSchema checks a schema body and returns the schema with its key patterns compiled, the canonical body that a store keeps (the same content in
// another layout gives the same bytes) and the SHA-256 of that body. Unknown fields, at any depth, are refused, and so is a body over 64 KiB.
func ParseSchema(body []byte) (store.GraphSchema, []byte, string, error) {
	if len(body) > MaxSchemaBytes {
		return store.GraphSchema{}, nil, "", schemaBad("the schema is larger than 64 KiB")
	}
	var raw rawSchema
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	dec.UseNumber()
	if err := dec.Decode(&raw); err != nil {
		var ute *json.UnmarshalTypeError
		switch {
		case errors.As(err, &ute):
			return store.GraphSchema{}, nil, "", schemaBad("field %s has the wrong type", ute.Field)
		case strings.HasPrefix(err.Error(), "json: unknown field "):
			return store.GraphSchema{}, nil, "", schemaBad("%s", err.Error())
		}
		return store.GraphSchema{}, nil, "", schemaBad("the schema is not valid JSON")
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return store.GraphSchema{}, nil, "", schemaBad("the schema has data after the JSON object")
	}
	v, err := strconv.ParseInt(string(raw.Version), 10, 64)
	if err != nil || v < 1 || v > maxSchemaVersion {
		return store.GraphSchema{}, nil, "", schemaBad("version must be an integer from 1 to %d", maxSchemaVersion)
	}
	g := store.GraphSchema{Version: int(v)}
	if n := len(raw.EntityTypes); n < 1 || n > MaxSchemaEntityTypes {
		return store.GraphSchema{}, nil, "", schemaBad("entityTypes must hold 1 to %d types (at most %d)", MaxSchemaEntityTypes, MaxSchemaEntityTypes)
	}
	declared := map[string]bool{}
	for i, t := range raw.EntityTypes {
		if !schemaTypeNameRe.MatchString(t.Name) {
			return store.GraphSchema{}, nil, "", schemaBad("entityTypes[%d].name must match %s", i, schemaTypeNamePattern)
		}
		if declared[t.Name] {
			return store.GraphSchema{}, nil, "", schemaBad("entityTypes[%d]: the name is used twice", i)
		}
		declared[t.Name] = true
		if utf8.RuneCountInString(t.Key) > MaxSchemaKeyChars || !validText(t.Key) {
			return store.GraphSchema{}, nil, "", schemaBad("entityTypes[%d].key must be valid text of at most %d characters", i, MaxSchemaKeyChars)
		}
		if t.Key != "" {
			if _, err := store.CompileKey(t.Key); err != nil {
				return store.GraphSchema{}, nil, "", schemaBad("entityTypes[%d].key %s", i, err)
			}
		}
		if utf8.RuneCountInString(t.Description) > MaxSchemaDescription || !validText(t.Description) {
			return store.GraphSchema{}, nil, "", schemaBad("entityTypes[%d].description must be valid text of at most %d characters", i, MaxSchemaDescription)
		}
		g.EntityTypes = append(g.EntityTypes, store.SchemaEntityType{Name: t.Name, Key: t.Key, Description: strings.Join(strings.Fields(t.Description), " ")})
	}
	if len(raw.RelationTypes) > MaxSchemaRelations {
		return store.GraphSchema{}, nil, "", schemaBad("relationTypes: at most %d types", MaxSchemaRelations)
	}
	seen := map[string]bool{}
	g.RelationTypes = []store.SchemaRelationType{}
	for i, r := range raw.RelationTypes {
		if r.Name == "" || normalizePredicate(r.Name) != r.Name {
			return store.GraphSchema{}, nil, "", schemaBad("relationTypes[%d].name must be a predicate in the form fact sets use: lower case letters and digits joined by '_', 2 to %d characters, starting with a letter", i, MaxPredicateRunes)
		}
		if seen[r.Name] {
			return store.GraphSchema{}, nil, "", schemaBad("relationTypes[%d]: the name is used twice", i)
		}
		seen[r.Name] = true
		if utf8.RuneCountInString(r.Description) > MaxSchemaDescription || !validText(r.Description) {
			return store.GraphSchema{}, nil, "", schemaBad("relationTypes[%d].description must be valid text of at most %d characters", i, MaxSchemaDescription)
		}
		for _, end := range []struct {
			field string
			list  []string
		}{{"from", r.From}, {"to", r.To}} {
			if len(end.list) == 0 || len(end.list) > MaxSchemaEnds {
				return store.GraphSchema{}, nil, "", schemaBad("relationTypes[%d].%s must list 1 to %d entity types (at most %d)", i, end.field, MaxSchemaEnds, MaxSchemaEnds)
			}
			dup := map[string]bool{}
			for _, t := range end.list {
				if !declared[t] {
					return store.GraphSchema{}, nil, "", schemaBad("relationTypes[%d].%s names an entity type that entityTypes does not declare", i, end.field)
				}
				if dup[t] {
					return store.GraphSchema{}, nil, "", schemaBad("relationTypes[%d].%s lists a type twice", i, end.field)
				}
				dup[t] = true
			}
		}
		g.RelationTypes = append(g.RelationTypes, store.SchemaRelationType{
			Name: r.Name, From: append([]string(nil), r.From...), To: append([]string(nil), r.To...), Description: strings.Join(strings.Fields(r.Description), " "),
		})
	}
	canon, err := json.Marshal(g)
	if err != nil {
		return store.GraphSchema{}, nil, "", err
	}
	if err := g.Compile(); err != nil {
		return store.GraphSchema{}, nil, "", schemaBad("%s", err.Error())
	}
	sum := sha256.Sum256(canon)
	return g, canon, hex.EncodeToString(sum[:]), nil
}
