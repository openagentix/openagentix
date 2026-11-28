package kb

import (
	"context"
	"errors"
	"fmt"

	"github.com/openagentix/openagentix/services/kb/internal/graph"
	"github.com/openagentix/openagentix/services/kb/internal/store"
)

// FactSetResult is what PutFactSet reports: the size of the stored fact set
// and whether it differs from what was there (false for an identical upload).
type FactSetResult struct {
	Entities  int
	Relations int
	Changed   bool
}

func (s *Service) factSetGuard(collection, id string) error {
	if err := s.graphGuard(); err != nil {
		return err
	}
	if err := ValidateCollection(collection); err != nil {
		return err
	}
	if err := ValidateID(id); err != nil {
		return invalid("fact set id must match %s", idRe)
	}
	return nil
}

// PutFactSet validates a curated fact set and replaces the stored one of the
// same id atomically (see store.Store.ReplaceFactSet). No model is involved and
// nothing is queued: the facts are visible to the graph tools at once. Repeating
// the call with the same body changes nothing.
func (s *Service) PutFactSet(ctx context.Context, collection, id string, in store.FactSet) (FactSetResult, error) {
	if err := s.factSetGuard(collection, id); err != nil {
		return FactSetResult{}, err
	}
	if err := cleanText("source_uri", in.SourceURI, MaxSourceURIChars); err != nil {
		return FactSetResult{}, err
	}
	if err := validateSourceURI(in.SourceURI); err != nil {
		return FactSetResult{}, err
	}
	// With a graph schema the types are the schema's, and the store checks the fact set against it under the collection's lock (ADR 0030). The schema
	// may change between the read and the write: the store then says so (ErrSchemaMoved) and the fact set is shaped again.
	for attempt := 0; ; attempt++ {
		sha, err := s.schemaSHAOf(ctx, collection)
		if err != nil {
			return FactSetResult{}, err
		}
		res, err := s.putFactSet(ctx, collection, id, in, sha)
		if errors.Is(err, store.ErrSchemaMoved) && attempt < 3 {
			continue
		}
		return res, err
	}
}

func (s *Service) putFactSet(ctx context.Context, collection, id string, in store.FactSet, schemaSHA string) (FactSetResult, error) {
	fs, err := graph.ValidateFactSetFor(in, schemaSHA != "")
	if err != nil {
		var fe *graph.FactSetError
		switch {
		case errors.Is(err, graph.ErrFactSetTooLarge):
			return FactSetResult{}, fmt.Errorf("%w: %v", ErrTooLarge, err)
		case errors.As(err, &fe):
			return FactSetResult{}, invalid("%s", fe.Msg)
		}
		return FactSetResult{}, err
	}
	fs.Collection, fs.ID, fs.SchemaSHA = collection, id, schemaSHA
	changed, err := s.Store.ReplaceFactSet(ctx, fs)
	if err != nil {
		return FactSetResult{}, err
	}
	return FactSetResult{Entities: len(fs.Entities), Relations: len(fs.Relations), Changed: changed}, nil
}

// GetFactSet returns a stored fact set, or store.ErrFactSetNotFound.
func (s *Service) GetFactSet(ctx context.Context, collection, id string) (store.FactSet, error) {
	if err := s.factSetGuard(collection, id); err != nil {
		return store.FactSet{}, err
	}
	return s.Store.GetFactSet(ctx, collection, id)
}

// ListFactSets lists the fact sets of a collection.
func (s *Service) ListFactSets(ctx context.Context, collection string) ([]store.FactSetInfo, error) {
	if err := s.graphGuard(); err != nil {
		return nil, err
	}
	if err := ValidateCollection(collection); err != nil {
		return nil, err
	}
	return s.Store.ListFactSets(ctx, collection)
}

// DeleteFactSet removes a fact set and reports whether it existed.
func (s *Service) DeleteFactSet(ctx context.Context, collection, id string) (bool, error) {
	if err := s.factSetGuard(collection, id); err != nil {
		return false, err
	}
	return s.Store.DeleteFactSet(ctx, collection, id)
}
