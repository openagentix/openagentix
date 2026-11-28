package memory

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/openagentix/openagentix/services/kb/internal/store"
)

// schemaRec is a stored graph schema with its compiled form. It is guarded by Store.mu.
type schemaRec struct {
	stored   store.StoredSchema
	compiled *store.GraphSchema
}

func (s *Store) schemaOfLocked(collection string) *schemaRec { return s.g.schemas[collection] }

// checkFactSetLocked is the check of ReplaceFactSet: the schema state must be the one the fact set was shaped for, and the fact set must fit it.
func (s *Store) checkFactSetLocked(fs store.FactSet) error {
	rec := s.schemaOfLocked(fs.Collection)
	cur := ""
	if rec != nil {
		cur = rec.stored.SHA256
	}
	if cur != fs.SchemaSHA {
		return store.ErrSchemaMoved
	}
	if rec == nil {
		return nil
	}
	if v := store.CheckFactSet(rec.compiled, fs); len(v) > 0 {
		shown, more := store.CapViolations(v, store.MaxViolationsShown)
		return &store.SchemaViolationError{Kind: "factset", Violations: shown, More: more}
	}
	return nil
}

// existingFactsLocked gathers what a schema change is checked against.
func (s *Store) existingFactsLocked(collection string) store.ExistingFacts {
	var ex store.ExistingFacts
	var ids []string
	for k := range s.g.factsets {
		if k.collection == collection {
			ids = append(ids, k.id)
		}
	}
	sort.Strings(ids)
	for _, id := range ids {
		fs := s.g.factsets[fskey{collection, id}].fs.Clone()
		fs.Collection, fs.ID = collection, id
		ex.FactSets = append(ex.FactSets, fs)
	}
	var eids []int64
	for id, e := range s.g.entities {
		if e.Collection == collection && e.Origin == store.OriginExtracted {
			eids = append(eids, id)
		}
	}
	slices.Sort(eids)
	for n, id := range eids {
		e := s.g.entities[id]
		ex.ExtractedEntities = append(ex.ExtractedEntities, store.SchemaEntity{At: fmt.Sprintf("extracted/entities[%d]", n), Name: e.Name, Type: e.Type})
	}
	var rids []int64
	for id, r := range s.g.relations {
		if r.Collection == collection && r.Origin == store.OriginExtracted {
			rids = append(rids, id)
		}
	}
	slices.Sort(rids)
	for n, id := range rids {
		r := s.g.relations[id]
		src, dst := s.g.entities[r.SrcID], s.g.entities[r.DstID]
		if src == nil || dst == nil {
			continue
		}
		ex.ExtractedRelations = append(ex.ExtractedRelations, store.SchemaRelation{At: fmt.Sprintf("extracted/relations[%d]", n), Predicate: r.Predicate, FromType: src.Type, ToType: dst.Type})
	}
	return ex
}

func (s *Store) PutGraphSchema(_ context.Context, collection string, g store.GraphSchema, body []byte, sha string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	cur := s.schemaOfLocked(collection)
	if cur != nil && cur.stored.SHA256 == sha {
		return false, nil
	}
	if cur != nil && g.Version <= cur.stored.Version {
		return false, fmt.Errorf("%w: it is %d, the new one is %d", store.ErrSchemaVersion, cur.stored.Version, g.Version)
	}
	if err := g.Compile(); err != nil {
		return false, err
	}
	if v := store.CheckExisting(&g, s.existingFactsLocked(collection)); len(v) > 0 {
		shown, more := store.CapViolations(v, store.MaxViolationsShown)
		return false, &store.SchemaViolationError{Kind: "change", Violations: shown, More: more}
	}
	if s.g.schemas == nil {
		s.g.schemas = map[string]*schemaRec{}
	}
	s.g.schemas[collection] = &schemaRec{
		stored:   store.StoredSchema{Collection: collection, Version: g.Version, SHA256: sha, Body: append([]byte(nil), body...), UpdatedAt: time.Now().UTC()},
		compiled: &g,
	}
	return true, nil
}

func (s *Store) GetGraphSchema(_ context.Context, collection string) (store.StoredSchema, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rec := s.schemaOfLocked(collection)
	if rec == nil {
		return store.StoredSchema{}, store.ErrSchemaNotFound
	}
	out := rec.stored
	out.Body = append([]byte(nil), rec.stored.Body...)
	return out, nil
}

func (s *Store) DeleteGraphSchema(_ context.Context, collection string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.schemaOfLocked(collection) == nil {
		return false, nil
	}
	delete(s.g.schemas, collection)
	return true, nil
}

func (s *Store) ListGraphSchemas(_ context.Context, scope store.Scope) ([]store.StoredSchema, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var out []store.StoredSchema
	for c, rec := range s.g.schemas {
		if !scope.Allows(c) {
			continue
		}
		x := rec.stored
		x.Body = append([]byte(nil), rec.stored.Body...)
		out = append(out, x)
	}
	slices.SortFunc(out, func(a, b store.StoredSchema) int { return strings.Compare(a.Collection, b.Collection) })
	return out, nil
}

// schemaFromBody reads a stored body back into a compiled schema.
func schemaFromBody(body []byte) (*store.GraphSchema, error) {
	var g store.GraphSchema
	if err := json.Unmarshal(body, &g); err != nil {
		return nil, err
	}
	return &g, g.Compile()
}
