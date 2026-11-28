package kb

import (
	"context"
	"errors"
	"fmt"

	"github.com/openagentix/openagentix/services/kb/internal/graph"
	"github.com/openagentix/openagentix/services/kb/internal/store"
)

// ErrConflict marks a request that is valid but clashes with what is stored: a schema version that is not higher than the stored one.
var ErrConflict = errors.New("conflict")

// SchemasEnabled reports whether graph schemas are on (ADR 0030, section 5): the routes, the checks on load, and the tool kb_graph_schema.
func (s *Service) SchemasEnabled() bool { return s.Graph != nil && s.Graph.Schemas }

func (s *Service) schemaGuard() error {
	if err := s.graphGuard(); err != nil {
		return err
	}
	if !s.Graph.Schemas {
		return invalid("graph schemas are not enabled")
	}
	return nil
}

// SchemaResult is what PutGraphSchema reports.
type SchemaResult struct {
	Version       int
	SHA256        string
	Changed       bool
	EntityTypes   int
	RelationTypes int
}

// PutGraphSchema checks a schema body (graph.ParseSchema: at most 64 KiB, unknown fields refused) and stores it for a collection. The same body again
// changes nothing. Another body needs a higher version (ErrConflict). Facts that are already in the collection and break it refuse the change with a
// *store.SchemaViolationError of Kind "change".
func (s *Service) PutGraphSchema(ctx context.Context, collection string, body []byte) (SchemaResult, error) {
	if err := s.schemaGuard(); err != nil {
		return SchemaResult{}, err
	}
	if err := ValidateCollection(collection); err != nil {
		return SchemaResult{}, err
	}
	g, canon, sha, err := graph.ParseSchema(body)
	if err != nil {
		var se *graph.SchemaError
		if errors.As(err, &se) {
			return SchemaResult{}, invalid("%s", se.Msg)
		}
		return SchemaResult{}, err
	}
	changed, err := s.Store.PutGraphSchema(ctx, collection, g, canon, sha)
	if err != nil {
		if errors.Is(err, store.ErrSchemaVersion) {
			return SchemaResult{}, fmt.Errorf("%w: %v", ErrConflict, err)
		}
		return SchemaResult{}, err
	}
	return SchemaResult{Version: g.Version, SHA256: sha, Changed: changed, EntityTypes: len(g.EntityTypes), RelationTypes: len(g.RelationTypes)}, nil
}

// GetGraphSchema returns the stored schema of a collection, or store.ErrSchemaNotFound. This is the operator's read: it is not limited by a scope.
func (s *Service) GetGraphSchema(ctx context.Context, collection string) (store.StoredSchema, error) {
	if err := s.schemaGuard(); err != nil {
		return store.StoredSchema{}, err
	}
	if err := ValidateCollection(collection); err != nil {
		return store.StoredSchema{}, err
	}
	return s.Store.GetGraphSchema(ctx, collection)
}

// DeleteGraphSchema removes the schema of a collection and reports whether it had one. The facts stay.
func (s *Service) DeleteGraphSchema(ctx context.Context, collection string) (bool, error) {
	if err := s.schemaGuard(); err != nil {
		return false, err
	}
	if err := ValidateCollection(collection); err != nil {
		return false, err
	}
	return s.Store.DeleteGraphSchema(ctx, collection)
}

// ReadGraphSchemas is the read of the tool kb_graph_schema. With a collection it returns that collection's schema if the caller may read the collection
// and it has one, else nothing: a collection outside the caller's list answers as a collection with no schema (and as one that does not exist). With no
// collection it returns the schemas of every collection the caller may read.
func (s *Service) ReadGraphSchemas(ctx context.Context, collection string) ([]store.StoredSchema, error) {
	if err := s.schemaGuard(); err != nil {
		return nil, err
	}
	sc := ScopeFrom(ctx)
	if collection == "" {
		return s.Store.ListGraphSchemas(ctx, sc)
	}
	if err := ValidateCollection(collection); err != nil {
		return nil, err
	}
	if !sc.Allows(collection) {
		return nil, nil
	}
	x, err := s.Store.GetGraphSchema(ctx, collection)
	if errors.Is(err, store.ErrSchemaNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return []store.StoredSchema{x}, nil
}

// schemaSHAOf is the hash of the schema a collection has now, "" for none: what a fact set is shaped for.
func (s *Service) schemaSHAOf(ctx context.Context, collection string) (string, error) {
	if !s.SchemasEnabled() {
		return "", nil
	}
	x, err := s.Store.GetGraphSchema(ctx, collection)
	if errors.Is(err, store.ErrSchemaNotFound) {
		return "", nil
	}
	return x.SHA256, err
}

// hasSchema reports whether a collection has a graph schema (always false when schemas are off).
func (s *Service) hasSchema(ctx context.Context, collection string) (bool, error) {
	sha, err := s.schemaSHAOf(ctx, collection)
	return sha != "", err
}
