package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/openagentix/openagentix/services/kb/internal/store"
)

func (s *Store) needSchemas() error {
	if err := s.needGraph(); err != nil {
		return err
	}
	if !s.schemas {
		return store.ErrSchemasDisabled
	}
	return nil
}

// hasSchema reports whether the collection has a graph schema. Without schema support it is always false. The caller holds the collection lock.
func (s *Store) hasSchema(ctx context.Context, tx pgx.Tx, collection string) (bool, error) {
	if !s.schemas {
		return false, nil
	}
	var has bool
	err := tx.QueryRow(ctx, s.q(`SELECT EXISTS (SELECT 1 FROM {{schema}}.graph_schemas WHERE collection = $1)`), collection).Scan(&has)
	return has, err
}

// checkFactSetUnderLock is the check of ReplaceFactSet, made in the transaction that holds the collection lock: the schema must be the one the fact set was
// shaped for (else ErrSchemaMoved), and the fact set must fit it (else a *store.SchemaViolationError).
func (s *Store) checkFactSetUnderLock(ctx context.Context, tx pgx.Tx, fs store.FactSet) error {
	if !s.schemas {
		return nil
	}
	var sha, body string
	err := tx.QueryRow(ctx, s.q(`SELECT sha256, body FROM {{schema}}.graph_schemas WHERE collection = $1`), fs.Collection).Scan(&sha, &body)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		if fs.SchemaSHA != "" {
			return store.ErrSchemaMoved
		}
		return nil
	case err != nil:
		return err
	}
	if sha != fs.SchemaSHA {
		return store.ErrSchemaMoved
	}
	g, err := parseStoredSchema([]byte(body))
	if err != nil {
		return err
	}
	if v := store.CheckFactSet(g, fs); len(v) > 0 {
		shown, more := store.CapViolations(v, store.MaxViolationsShown)
		return &store.SchemaViolationError{Kind: "factset", Violations: shown, More: more}
	}
	return nil
}

func parseStoredSchema(body []byte) (*store.GraphSchema, error) {
	var g store.GraphSchema
	if err := json.Unmarshal(body, &g); err != nil {
		return nil, fmt.Errorf("stored graph schema is unreadable: %w", err)
	}
	if err := g.Compile(); err != nil {
		return nil, err
	}
	return &g, nil
}

// existingFacts gathers what a schema change is checked against: every stored fact set, then the extracted entities and relations.
func (s *Store) existingFacts(ctx context.Context, tx pgx.Tx, collection string) (store.ExistingFacts, error) {
	var ex store.ExistingFacts
	rows, err := tx.Query(ctx, s.q(`SELECT id, body FROM {{schema}}.graph_factsets WHERE collection = $1 ORDER BY id COLLATE "C"`), collection)
	if err != nil {
		return ex, err
	}
	for rows.Next() {
		var id string
		var body []byte
		if err := rows.Scan(&id, &body); err != nil {
			rows.Close()
			return ex, err
		}
		fs := store.FactSet{Collection: collection, ID: id}
		if err := json.Unmarshal(body, &fs); err != nil {
			rows.Close()
			return ex, fmt.Errorf("stored fact set is unreadable: %w", err)
		}
		ex.FactSets = append(ex.FactSets, fs)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return ex, err
	}
	erows, err := tx.Query(ctx, s.q(`SELECT name, type FROM {{schema}}.entities WHERE collection = $1 AND origin = 'extracted' ORDER BY id`), collection)
	if err != nil {
		return ex, err
	}
	for n := 0; erows.Next(); n++ {
		var e store.SchemaEntity
		if err := erows.Scan(&e.Name, &e.Type); err != nil {
			erows.Close()
			return ex, err
		}
		e.At = fmt.Sprintf("extracted/entities[%d]", n)
		ex.ExtractedEntities = append(ex.ExtractedEntities, e)
	}
	erows.Close()
	if err := erows.Err(); err != nil {
		return ex, err
	}
	rrows, err := tx.Query(ctx, s.q(`
		SELECT r.predicate, a.type, b.type
		FROM {{schema}}.relations r
		JOIN {{schema}}.entities a ON a.id = r.src_id
		JOIN {{schema}}.entities b ON b.id = r.dst_id
		WHERE r.collection = $1 AND r.origin = 'extracted' ORDER BY r.id`), collection)
	if err != nil {
		return ex, err
	}
	for n := 0; rrows.Next(); n++ {
		var r store.SchemaRelation
		if err := rrows.Scan(&r.Predicate, &r.FromType, &r.ToType); err != nil {
			rrows.Close()
			return ex, err
		}
		r.At = fmt.Sprintf("extracted/relations[%d]", n)
		ex.ExtractedRelations = append(ex.ExtractedRelations, r)
	}
	rrows.Close()
	return ex, rrows.Err()
}

func (s *Store) PutGraphSchema(ctx context.Context, collection string, g store.GraphSchema, body []byte, sha string) (bool, error) {
	if err := s.needSchemas(); err != nil {
		return false, err
	}
	if err := g.Compile(); err != nil {
		return false, err
	}
	changed := false
	err := s.inGraphTx(ctx, collection, func(tx pgx.Tx) error {
		var curVersion int
		var curSHA string
		err := tx.QueryRow(ctx, s.q(`SELECT version, sha256 FROM {{schema}}.graph_schemas WHERE collection = $1`), collection).Scan(&curVersion, &curSHA)
		has := err == nil
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if has && curSHA == sha {
			return nil
		}
		if has && g.Version <= curVersion {
			return fmt.Errorf("%w: it is %d, the new one is %d", store.ErrSchemaVersion, curVersion, g.Version)
		}
		ex, err := s.existingFacts(ctx, tx, collection)
		if err != nil {
			return err
		}
		if v := store.CheckExisting(&g, ex); len(v) > 0 {
			shown, more := store.CapViolations(v, store.MaxViolationsShown)
			return &store.SchemaViolationError{Kind: "change", Violations: shown, More: more}
		}
		if _, err := tx.Exec(ctx, s.q(`
			INSERT INTO {{schema}}.graph_schemas (collection, version, sha256, body) VALUES ($1, $2, $3, $4)
			ON CONFLICT (collection) DO UPDATE SET version = EXCLUDED.version, sha256 = EXCLUDED.sha256, body = EXCLUDED.body, updated_at = now()`),
			collection, g.Version, sha, string(body)); err != nil {
			return err
		}
		changed = true
		return nil
	})
	return changed, err
}

func (s *Store) GetGraphSchema(ctx context.Context, collection string) (store.StoredSchema, error) {
	if err := s.needSchemas(); err != nil {
		return store.StoredSchema{}, err
	}
	out := store.StoredSchema{Collection: collection}
	var body string
	err := s.pool.QueryRow(ctx, s.q(`SELECT version, sha256, body, updated_at FROM {{schema}}.graph_schemas WHERE collection = $1`), collection).
		Scan(&out.Version, &out.SHA256, &body, &out.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return store.StoredSchema{}, store.ErrSchemaNotFound
	}
	out.Body = []byte(body)
	return out, err
}

func (s *Store) DeleteGraphSchema(ctx context.Context, collection string) (bool, error) {
	if err := s.needSchemas(); err != nil {
		return false, err
	}
	existed := false
	err := s.inGraphTx(ctx, collection, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, s.q(`DELETE FROM {{schema}}.graph_schemas WHERE collection = $1`), collection)
		existed = err == nil && tag.RowsAffected() > 0
		return err
	})
	return existed, err
}

func (s *Store) ListGraphSchemas(ctx context.Context, scope store.Scope) ([]store.StoredSchema, error) {
	if err := s.needSchemas(); err != nil {
		return nil, err
	}
	limited, list := scopeArgs(scope)
	rows, err := s.pool.Query(ctx, s.q(`
		SELECT collection, version, sha256, body, updated_at FROM {{schema}}.graph_schemas
		WHERE (NOT $1::bool OR collection = ANY($2::text[])) ORDER BY collection COLLATE "C"`), limited, list)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []store.StoredSchema
	for rows.Next() {
		var x store.StoredSchema
		var body string
		if err := rows.Scan(&x.Collection, &x.Version, &x.SHA256, &body, &x.UpdatedAt); err != nil {
			return nil, err
		}
		x.Body = []byte(body)
		out = append(out, x)
	}
	return out, rows.Err()
}
