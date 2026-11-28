package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/openagentix/openagentix/services/kb/internal/store"
)

// querier is what both *pgxpool.Pool and pgx.Tx offer.
type querier interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

func (s *Store) needGraph() error {
	if !s.graph {
		return store.ErrGraphDisabled
	}
	return nil
}

func isFKViolation(err error) bool {
	var pe *pgconn.PgError
	return errors.As(err, &pe) && pe.Code == "23503"
}

// lockCollection serialises graph writers of one collection for the rest of the
// transaction, so that collecting orphan entities cannot race with an
// extraction that is just about to attach relations to them.
func (s *Store) lockCollection(ctx context.Context, tx pgx.Tx, collection string) error {
	_, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, "kb-graph:"+s.schema+":"+collection)
	return err
}

func (s *Store) vecArg(v []float32) *string {
	if s.dim == 0 || len(v) == 0 {
		return nil
	}
	l := vectorLiteral(v)
	return &l
}

func (s *Store) checkEmbedding(v []float32) error {
	if s.dim > 0 && len(v) > 0 && len(v) != s.dim {
		return fmt.Errorf("name embedding has dimension %d, store expects %d", len(v), s.dim)
	}
	return nil
}

func (s *Store) q(sql string) string { return strings.ReplaceAll(sql, "{{schema}}", s.schema) }

const entityColumns = `id, collection, name, norm_name, type, other_types, description, aliases, origin`

func scanEntity(row pgx.Row) (store.Entity, error) {
	var e store.Entity
	err := row.Scan(&e.ID, &e.Collection, &e.Name, &e.NormName, &e.Type, &e.OtherTypes, &e.Description, &e.Aliases, &e.Origin)
	if e.Aliases == nil {
		e.Aliases = []string{}
	}
	if e.OtherTypes == nil {
		e.OtherTypes = []string{}
	}
	return e, err
}

func (s *Store) UpsertEntity(ctx context.Context, in store.EntityInput) (store.Entity, error) {
	if err := s.needGraph(); err != nil {
		return store.Entity{}, err
	}
	return s.upsertEntity(ctx, s.pool, in)
}

func (s *Store) upsertEntity(ctx context.Context, q querier, in store.EntityInput) (store.Entity, error) {
	name := strings.Join(strings.Fields(in.Name), " ")
	if in.Collection == "" || name == "" || in.Type == "" {
		return store.Entity{}, errors.New("entity needs a collection, a name and a type")
	}
	if err := s.checkEmbedding(in.NameEmbedding); err != nil {
		return store.Entity{}, err
	}
	origin := in.Origin
	if origin == "" {
		origin = store.OriginExtracted
	}
	aliases := store.MatchAliases(name, in.Aliases)
	if aliases == nil {
		aliases = []string{}
	}
	args := []any{in.Collection, name, store.NormalizeName(name), store.MatchForm(name), in.Type, in.Description, aliases, origin, store.MergeKey(name, in.Type, in.DocumentID)}
	cols, vals, setEmb := "", "", ""
	if s.dim > 0 {
		cols, vals = ", name_embedding", ", $10::"+s.vecSchema+".vector"
		setEmb = ", name_embedding = coalesce({{schema}}.entities.name_embedding, EXCLUDED.name_embedding)"
		args = append(args, s.vecArg(in.NameEmbedding))
	}
	// A merge keeps the existing type and origin, fills an empty description,
	// unites the aliases (every form seen stays findable, the displayed one is
	// not its own alias), records a different type and, unless the entity is
	// manual, displays the more specific name (store.BetterName, in SQL).
	// The exception is a curated entity (origin manual) merging into an extracted
	// one: it takes over the name, the type (the old one is recorded) and the
	// description, and the entity becomes manual (takeManual).
	const takeManual = `(EXCLUDED.origin = 'manual' AND {{schema}}.entities.origin <> 'manual')`
	const takeNew = `(` + takeManual + ` OR ({{schema}}.entities.origin <> 'manual' AND (
		  cardinality(string_to_array(EXCLUDED.match_name, ' ')) > cardinality(string_to_array({{schema}}.entities.match_name, ' '))
		  OR (cardinality(string_to_array(EXCLUDED.match_name, ' ')) = cardinality(string_to_array({{schema}}.entities.match_name, ' '))
		      AND EXCLUDED.name COLLATE "C" < {{schema}}.entities.name COLLATE "C"))))`
	const newType = `(CASE WHEN ` + takeManual + ` THEN EXCLUDED.type ELSE {{schema}}.entities.type END)`
	return scanEntity(q.QueryRow(ctx, s.q(`
		INSERT INTO {{schema}}.entities (collection, name, norm_name, match_name, type, description, aliases, origin, canon_name`+cols+`)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9`+vals+`)
		ON CONFLICT (collection, canon_name) DO UPDATE SET
		  description = CASE WHEN `+takeManual+` AND EXCLUDED.description <> '' THEN EXCLUDED.description
		                     WHEN {{schema}}.entities.description = '' THEN EXCLUDED.description ELSE {{schema}}.entities.description END,
		  aliases = (SELECT coalesce(array_agg(DISTINCT a COLLATE "C" ORDER BY a COLLATE "C"), '{}')
		             FROM unnest({{schema}}.entities.aliases || EXCLUDED.aliases || ARRAY[{{schema}}.entities.match_name, EXCLUDED.match_name]) AS a
		             WHERE a <> '' AND a <> CASE WHEN `+takeNew+` THEN EXCLUDED.match_name ELSE {{schema}}.entities.match_name END),
		  other_types = (SELECT coalesce(array_agg(DISTINCT t COLLATE "C" ORDER BY t COLLATE "C"), '{}')
		                 FROM unnest({{schema}}.entities.other_types || ARRAY[EXCLUDED.type, {{schema}}.entities.type]) AS t WHERE t <> `+newType+`),
		  type = `+newType+`,
		  origin = CASE WHEN `+takeManual+` THEN 'manual' ELSE {{schema}}.entities.origin END,
		  name = CASE WHEN `+takeNew+` THEN EXCLUDED.name ELSE {{schema}}.entities.name END,
		  norm_name = CASE WHEN `+takeNew+` THEN EXCLUDED.norm_name ELSE {{schema}}.entities.norm_name END,
		  match_name = CASE WHEN `+takeNew+` THEN EXCLUDED.match_name ELSE {{schema}}.entities.match_name END`+setEmb+`
		RETURNING `+entityColumns), args...))
}

// backfillCanonNames gives every entity row without a canonical name its
// canon_name and then makes the column mandatory and unique. It runs inside the
// migration transaction. Only rows that survived the one-time clearing of
// migration 5 (manual ones) can be without one. Should two of them share a
// canonical form, the later one keeps its own id in its key and is not merged.
func (s *Store) backfillCanonNames(ctx context.Context, tx pgx.Tx) error {
	rows, err := tx.Query(ctx, s.q(`SELECT id, collection, name, type FROM {{schema}}.entities WHERE canon_name IS NULL ORDER BY id`))
	if err != nil {
		return err
	}
	type row struct {
		id             int64
		coll, name, ty string
	}
	var todo []row
	for rows.Next() {
		var r row
		if err := rows.Scan(&r.id, &r.coll, &r.name, &r.ty); err != nil {
			rows.Close()
			return err
		}
		todo = append(todo, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	seen := map[[2]string]bool{}
	for _, r := range todo {
		k := store.MergeKey(r.name, r.ty, "")
		if seen[[2]string{r.coll, k}] {
			k += "\x1f#" + strconv.FormatInt(r.id, 10)
		}
		seen[[2]string{r.coll, k}] = true
		if _, err := tx.Exec(ctx, s.q(`UPDATE {{schema}}.entities SET canon_name = $2 WHERE id = $1`), r.id, k); err != nil {
			return err
		}
	}
	for _, stmt := range []string{
		`ALTER TABLE {{schema}}.entities ALTER COLUMN canon_name SET NOT NULL`,
		`CREATE UNIQUE INDEX IF NOT EXISTS entities_canon_name_key ON {{schema}}.entities (collection, canon_name)`,
	} {
		if _, err := tx.Exec(ctx, s.q(stmt)); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) AddRelation(ctx context.Context, r store.Relation) (int64, error) {
	if err := s.needGraph(); err != nil {
		return 0, err
	}
	return s.addRelation(ctx, s.pool, r)
}

func (s *Store) addRelation(ctx context.Context, q querier, r store.Relation) (int64, error) {
	if r.Predicate == "" {
		return 0, errors.New("relation needs a predicate")
	}
	if r.FactsetID != "" {
		return 0, errors.New("relations of a fact set are stored by ReplaceFactSet")
	}
	if r.Origin == "" {
		r.Origin = store.OriginExtracted
	}
	ends := 2
	if r.SrcID == r.DstID {
		ends = 1
	}
	var id int64
	// The WHERE clause admits the row only if every endpoint is an entity of the
	// relation's collection. ON CONFLICT turns a repeat into a read of the id.
	err := q.QueryRow(ctx, s.q(`
		INSERT INTO {{schema}}.relations (collection, src_id, dst_id, predicate, evidence, document_id, chunk_index, prompt_version, model, origin)
		SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, $10
		WHERE (SELECT count(*) FROM {{schema}}.entities WHERE collection = $1 AND id IN ($2, $3)) = $11
		ON CONFLICT (collection, src_id, dst_id, predicate, document_id, chunk_index) DO UPDATE SET origin = {{schema}}.relations.origin
		RETURNING id`),
		r.Collection, r.SrcID, r.DstID, r.Predicate, r.Evidence, r.DocumentID, r.ChunkIndex, r.PromptVersion, r.Model, r.Origin, ends).Scan(&id)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return 0, fmt.Errorf("%w: relation endpoint is not an entity of collection %q", store.ErrNotFound, r.Collection)
	case isFKViolation(err):
		return 0, fmt.Errorf("%w: relation document %q", store.ErrNotFound, r.DocumentID)
	case err != nil:
		return 0, err
	}
	return id, nil
}

func (s *Store) LinkEntityChunk(ctx context.Context, collection string, ec store.EntityChunk) error {
	if err := s.needGraph(); err != nil {
		return err
	}
	return s.link(ctx, s.pool, collection, ec)
}

func (s *Store) link(ctx context.Context, q querier, collection string, ec store.EntityChunk) error {
	tag, err := q.Exec(ctx, s.q(`
		INSERT INTO {{schema}}.entity_chunks (entity_id, collection, document_id, chunk_index)
		SELECT id, collection, $3, $4 FROM {{schema}}.entities WHERE id = $1 AND collection = $2
		ON CONFLICT DO NOTHING`), ec.EntityID, collection, ec.DocumentID, ec.ChunkIndex)
	switch {
	case isFKViolation(err):
		return fmt.Errorf("%w: document %q", store.ErrNotFound, ec.DocumentID)
	case err != nil:
		return err
	}
	if tag.RowsAffected() == 0 {
		var one int
		if err := q.QueryRow(ctx, s.q(`SELECT 1 FROM {{schema}}.entities WHERE id = $1 AND collection = $2`), ec.EntityID, collection).Scan(&one); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return fmt.Errorf("%w: entity %d in collection %q", store.ErrNotFound, ec.EntityID, collection)
			}
			return err
		}
	}
	return nil
}

// collectEntities removes the extracted entities of a collection that no
// relation and no chunk mention refers to.
func (s *Store) collectEntities(ctx context.Context, q querier, collection string) error {
	_, err := q.Exec(ctx, s.q(`
		DELETE FROM {{schema}}.entities e
		WHERE e.collection = $1 AND e.origin = 'extracted'
		  AND NOT EXISTS (SELECT 1 FROM {{schema}}.relations r WHERE r.src_id = e.id OR r.dst_id = e.id)
		  AND NOT EXISTS (SELECT 1 FROM {{schema}}.entity_chunks c WHERE c.entity_id = e.id)`), collection)
	return err
}

// dropDocGraph removes a document's relations, mentions and jobs and then
// collects orphan entities. The caller holds the collection lock.
func (s *Store) dropDocGraph(ctx context.Context, q querier, collection, doc string) error {
	for _, t := range []string{"relations", "entity_chunks", "extraction_jobs"} {
		if _, err := q.Exec(ctx, s.q(`DELETE FROM {{schema}}.`+t+` WHERE collection = $1 AND document_id = $2`), collection, doc); err != nil {
			return err
		}
	}
	return s.collectEntities(ctx, q, collection)
}

func (s *Store) DeleteDocumentGraph(ctx context.Context, collection, documentID string) error {
	if err := s.needGraph(); err != nil {
		return err
	}
	return s.inGraphTx(ctx, collection, func(tx pgx.Tx) error { return s.dropDocGraph(ctx, tx, collection, documentID) })
}

func (s *Store) inGraphTx(ctx context.Context, collection string, fn func(pgx.Tx) error) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if err := s.lockCollection(ctx, tx, collection); err != nil {
		return err
	}
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// deleteDocumentWithGraph deletes the document (its graph rows go with it by
// cascade) and collects the entities that were only known from it.
func (s *Store) deleteDocumentWithGraph(ctx context.Context, collection, id string) (bool, error) {
	var existed bool
	err := s.inGraphTx(ctx, collection, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM `+s.schema+`.documents WHERE collection = $1 AND id = $2`, collection, id)
		if err != nil {
			return err
		}
		existed = tag.RowsAffected() > 0
		if !existed {
			return nil
		}
		return s.collectEntities(ctx, tx, collection)
	})
	return existed, err
}

func (s *Store) DocumentChunks(ctx context.Context, collection, id string) ([]string, error) {
	rows, err := s.pool.Query(ctx, `SELECT text FROM `+s.schema+`.chunks WHERE collection = $1 AND doc_id = $2 ORDER BY idx`, collection, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var t string
		if err := rows.Scan(&t); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(out) == 0 {
		var one int
		if err := s.pool.QueryRow(ctx, `SELECT 1 FROM `+s.schema+`.documents WHERE collection = $1 AND id = $2`, collection, id).Scan(&one); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, store.ErrNotFound
			}
			return nil, err
		}
	}
	return out, nil
}

// The scores mirror store.NameScore. Names and aliases are stored in match form.
const nameScoreSQL = `
	GREATEST(
	  CASE WHEN e.match_name = $2 THEN 1.0::float8 ELSE 0 END,
	  CASE WHEN $2 = ANY(e.aliases) THEN 0.95::float8 ELSE 0 END,
	  CASE WHEN length(e.match_name) >= 2 AND position(' ' || e.match_name || ' ' IN ' ' || $2 || ' ') > 0
	       THEN 0.7 + 0.2 * length(e.match_name)::float8 / length($2) ELSE 0 END,
	  coalesce((SELECT max(0.65 + 0.2 * length(a)::float8 / length($2)) FROM unnest(e.aliases) AS a
	            WHERE length(a) >= 2 AND a <> $2 AND position(' ' || a || ' ' IN ' ' || $2 || ' ') > 0), 0),
	  CASE WHEN e.match_name <> $2 AND position(' ' || $2 || ' ' IN ' ' || e.match_name || ' ') > 0
	       THEN 0.5 + 0.1 * length($2)::float8 / length(e.match_name) ELSE 0 END,
	  coalesce((SELECT max(0.45 + 0.1 * length($2)::float8 / length(a)) FROM unnest(e.aliases) AS a
	            WHERE a <> $2 AND position(' ' || $2 || ' ' IN ' ' || a || ' ') > 0), 0)
	)`

func (s *Store) FindEntitiesByName(ctx context.Context, collection, text string, limit int) ([]store.EntityHit, error) {
	if err := s.needGraph(); err != nil {
		return nil, err
	}
	q := store.MatchForm(text)
	if len([]rune(q)) < 2 {
		return nil, nil
	}
	if limit <= 0 {
		limit = store.DefaultPathLimit
	}
	rows, err := s.pool.Query(ctx, s.q(`
		SELECT `+entityColumns+`, score FROM (
		  SELECT e.id, e.collection, e.name, e.norm_name, e.type, e.other_types, e.description, e.aliases, e.origin, `+nameScoreSQL+` AS score
		  FROM {{schema}}.entities e WHERE e.collection = $1
		) x WHERE score > 0 ORDER BY score DESC, id LIMIT $3`), collection, q, limit)
	if err != nil {
		return nil, err
	}
	return scanEntityHits(rows)
}

func scanEntityHits(rows pgx.Rows) ([]store.EntityHit, error) {
	defer rows.Close()
	var out []store.EntityHit
	for rows.Next() {
		var h store.EntityHit
		e := &h.Entity
		if err := rows.Scan(&e.ID, &e.Collection, &e.Name, &e.NormName, &e.Type, &e.OtherTypes, &e.Description, &e.Aliases, &e.Origin, &h.Score); err != nil {
			return nil, err
		}
		if e.Aliases == nil {
			e.Aliases = []string{}
		}
		if e.OtherTypes == nil {
			e.OtherTypes = []string{}
		}
		out = append(out, h)
	}
	return out, rows.Err()
}

func (s *Store) FindEntitiesByEmbedding(ctx context.Context, collection string, emb []float32, limit int) ([]store.EntityHit, error) {
	if err := s.needGraph(); err != nil {
		return nil, err
	}
	if s.dim == 0 || len(emb) == 0 {
		return nil, nil
	}
	if len(emb) != s.dim {
		return nil, fmt.Errorf("query embedding has dimension %d, store expects %d", len(emb), s.dim)
	}
	if limit <= 0 {
		limit = store.DefaultPathLimit
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	s.widenHNSWScan(ctx, tx)
	rows, err := tx.Query(ctx, s.q(`
		SELECT `+entityColumns+`, (1 - (name_embedding OPERATOR(`+s.vecSchema+`.<=>) $1::`+s.vecSchema+`.vector))::float8 AS score
		FROM {{schema}}.entities
		WHERE name_embedding IS NOT NULL AND collection = $2
		ORDER BY name_embedding OPERATOR(`+s.vecSchema+`.<=>) $1::`+s.vecSchema+`.vector
		LIMIT $3`), vectorLiteral(emb), collection, limit)
	if err != nil {
		return nil, err
	}
	hits, err := scanEntityHits(rows)
	if err != nil {
		return nil, err
	}
	slices.SortStableFunc(hits, func(a, b store.EntityHit) int {
		switch {
		case a.Score > b.Score:
			return -1
		case a.Score < b.Score:
			return 1
		}
		return int(a.Entity.ID - b.Entity.ID)
	})
	kept := hits[:0]
	for _, h := range hits {
		if h.Score > 0 {
			kept = append(kept, h)
		}
	}
	return kept, nil
}

// walkSQL enumerates simple paths over relations in both directions. $1
// collection, $2 seed ids, $3 max depth, $4 an entity id at which paths stop
// (0 for none). The final SELECT is appended by the caller.
const walkSQL = `
	WITH RECURSIVE walk (seed, node, depth, nodes, edges, fwds) AS (
	  SELECT e.id, e.id, 0, ARRAY[e.id], ARRAY[]::bigint[], ARRAY[]::boolean[]
	  FROM {{schema}}.entities e WHERE e.collection = $1 AND e.id = ANY($2::bigint[])
	  UNION ALL
	  SELECT w.seed, o.other, w.depth + 1, w.nodes || o.other, w.edges || r.id, w.fwds || (r.src_id = w.node)
	  FROM walk w
	  CROSS JOIN LATERAL (
	    SELECT r2.id, r2.src_id, r2.dst_id FROM {{schema}}.relations r2
	    WHERE r2.collection = $1 AND (r2.src_id = w.node OR r2.dst_id = w.node)
	    ORDER BY r2.id LIMIT $6
	  ) r
	  CROSS JOIN LATERAL (SELECT CASE WHEN r.src_id = w.node THEN r.dst_id ELSE r.src_id END AS other) o
	  WHERE w.depth < $3 AND w.node <> $4 AND NOT o.other = ANY(w.nodes)
	)`

type rawPath struct {
	nodes, edges []int64
	fwds         []bool
}

func (s *Store) collectPaths(ctx context.Context, collection string, raw []rawPath) ([]store.Path, error) {
	if len(raw) == 0 {
		return nil, nil
	}
	var eids, rids []int64
	for _, p := range raw {
		eids = append(eids, p.nodes...)
		rids = append(rids, p.edges...)
	}
	ents := map[int64]store.Entity{}
	rows, err := s.pool.Query(ctx, s.q(`SELECT `+entityColumns+` FROM {{schema}}.entities WHERE collection = $1 AND id = ANY($2)`), collection, eids)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		e, err := scanEntity(rows)
		if err != nil {
			rows.Close()
			return nil, err
		}
		ents[e.ID] = e
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	type edge struct {
		rel  store.Relation
		cite store.Citation
	}
	edges := map[int64]edge{}
	rows, err = s.pool.Query(ctx, s.q(`
		SELECT r.id, r.collection, r.src_id, r.dst_id, r.predicate, r.evidence, coalesce(r.document_id, ''), coalesce(r.chunk_index, 0),
		       coalesce(r.factset_id, ''), r.prompt_version, r.model, r.origin, coalesce(d.source_uri, f.source_uri, '')
		FROM {{schema}}.relations r
		LEFT JOIN {{schema}}.documents d ON d.collection = r.collection AND d.id = r.document_id
		LEFT JOIN {{schema}}.graph_factsets f ON f.collection = r.collection AND f.id = r.factset_id
		WHERE r.collection = $1 AND r.id = ANY($2) AND (d.id IS NOT NULL OR f.id IS NOT NULL)`), collection, rids)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var r store.Relation
		var uri string
		if err := rows.Scan(&r.ID, &r.Collection, &r.SrcID, &r.DstID, &r.Predicate, &r.Evidence, &r.DocumentID, &r.ChunkIndex, &r.FactsetID, &r.PromptVersion, &r.Model, &r.Origin, &uri); err != nil {
			rows.Close()
			return nil, err
		}
		edges[r.ID] = edge{r, store.Citation{DocumentID: r.DocumentID, ChunkIndex: r.ChunkIndex, FactsetID: r.FactsetID, SourceURI: uri}}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	out := make([]store.Path, 0, len(raw))
	for _, p := range raw {
		path := store.Path{Entities: make([]store.Entity, len(p.nodes)), Steps: make([]store.Step, len(p.edges))}
		ok := true
		for i, id := range p.nodes {
			e, found := ents[id]
			ok = ok && found
			path.Entities[i] = e
		}
		for i, id := range p.edges {
			e, found := edges[id]
			ok = ok && found
			path.Steps[i] = store.Step{Edge: e.rel, Cite: e.cite, Forward: p.fwds[i]}
		}
		if ok { // a row deleted between the two queries drops its path
			out = append(out, path)
		}
	}
	store.SortPaths(out)
	return out, nil
}

func scanRawPaths(rows pgx.Rows) ([]rawPath, error) {
	defer rows.Close()
	var out []rawPath
	for rows.Next() {
		var p rawPath
		if err := rows.Scan(&p.nodes, &p.edges, &p.fwds); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *Store) Expand(ctx context.Context, q store.ExpandQuery) ([]store.Path, error) {
	if err := s.needGraph(); err != nil {
		return nil, err
	}
	if len(q.SeedIDs) == 0 {
		return nil, nil
	}
	rows, err := s.pool.Query(ctx, s.q(walkSQL+`
		SELECT nodes, edges, fwds FROM walk WHERE depth > 0
		ORDER BY CASE WHEN $7 THEN -depth ELSE depth END, nodes, edges LIMIT $5`),
		q.Collection, q.SeedIDs, store.ClampHops(q.Hops), int64(0), store.ClampLimit(q.Limit), store.ClampFanOut(q.FanOut), q.LongestFirst)
	if err != nil {
		return nil, err
	}
	raw, err := scanRawPaths(rows)
	if err != nil {
		return nil, err
	}
	ps, err := s.collectPaths(ctx, q.Collection, raw)
	if q.LongestFirst {
		slices.SortStableFunc(ps, func(a, b store.Path) int { return len(b.Steps) - len(a.Steps) })
	}
	return ps, err
}

func (s *Store) ShortestPaths(ctx context.Context, q store.PathQuery) ([]store.Path, error) {
	if err := s.needGraph(); err != nil {
		return nil, err
	}
	if q.FromID == q.ToID {
		return nil, nil
	}
	rows, err := s.pool.Query(ctx, s.q(walkSQL+`
		SELECT nodes, edges, fwds FROM walk
		WHERE node = $5 AND depth > 0 AND depth = (SELECT min(depth) FROM walk WHERE node = $5 AND depth > 0)
		ORDER BY nodes, edges LIMIT $7`),
		q.Collection, []int64{q.FromID}, store.ClampHops(q.MaxHops), q.ToID, q.ToID, store.ClampFanOut(q.FanOut), store.ClampLimit(q.Limit))
	if err != nil {
		return nil, err
	}
	raw, err := scanRawPaths(rows)
	if err != nil {
		return nil, err
	}
	return s.collectPaths(ctx, q.Collection, raw)
}

func (s *Store) GraphStats(ctx context.Context, collection string) (store.GraphStats, error) {
	if err := s.needGraph(); err != nil {
		return store.GraphStats{}, err
	}
	var st store.GraphStats
	err := s.pool.QueryRow(ctx, s.q(`
		SELECT (SELECT count(*) FROM {{schema}}.entities WHERE collection = $1),
		       (SELECT count(*) FROM {{schema}}.relations WHERE collection = $1),
		       (SELECT count(*) FROM {{schema}}.entity_chunks WHERE collection = $1),
		       (SELECT count(*) FROM {{schema}}.extraction_jobs WHERE collection = $1 AND state = 'pending'),
		       (SELECT count(*) FROM {{schema}}.extraction_jobs WHERE collection = $1 AND state = 'done'),
		       (SELECT count(*) FROM {{schema}}.extraction_jobs WHERE collection = $1 AND state = 'failed'),
		       (SELECT count(*) FROM {{schema}}.graph_factsets WHERE collection = $1),
		       (SELECT count(*) FROM {{schema}}.entities WHERE collection = $1 AND origin = 'manual'),
		       (SELECT count(*) FROM {{schema}}.relations WHERE collection = $1 AND origin = 'manual')`), collection).
		Scan(&st.Entities, &st.Relations, &st.Mentions, &st.JobsPending, &st.JobsDone, &st.JobsFailed, &st.FactSets, &st.ManualEntities, &st.ManualRelations)
	if err != nil {
		return st, err
	}
	err = s.pool.QueryRow(ctx, s.q(`
		SELECT coalesce((SELECT last_error_code FROM {{schema}}.extraction_jobs
		                 WHERE collection = $1 AND state <> 'done' AND last_error_code <> ''
		                 ORDER BY updated_at DESC, created_seq DESC LIMIT 1), '')`), collection).Scan(&st.LastErrorCode)
	return st, err
}

func (s *Store) SyncExtractionJobs(ctx context.Context, collection, documentID, promptVersion string, specs []store.JobSpec) (int, error) {
	if err := s.needGraph(); err != nil {
		return 0, err
	}
	n := 0
	err := s.inGraphTx(ctx, collection, func(tx pgx.Tx) error {
		var one int
		// Block a concurrent delete of the document while its jobs are replaced.
		if err := tx.QueryRow(ctx, s.q(`SELECT 1 FROM {{schema}}.documents WHERE collection = $1 AND id = $2 FOR KEY SHARE`), collection, documentID).Scan(&one); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return fmt.Errorf("%w: document %q", store.ErrNotFound, documentID)
			}
			return err
		}
		rows, err := tx.Query(ctx, s.q(`
			SELECT window_idx, window_hash, first_chunk, chunk_count, prompt_version, state
			FROM {{schema}}.extraction_jobs WHERE collection = $1 AND document_id = $2 ORDER BY window_idx`), collection, documentID)
		if err != nil {
			return err
		}
		type have struct {
			spec    store.JobSpec
			version string
			state   string
		}
		var existing []have
		for rows.Next() {
			var h have
			if err := rows.Scan(&h.spec.WindowIdx, &h.spec.WindowHash, &h.spec.FirstChunk, &h.spec.ChunkCount, &h.version, &h.state); err != nil {
				rows.Close()
				return err
			}
			existing = append(existing, h)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		same := len(existing) == len(specs)
		for i := 0; same && i < len(specs); i++ {
			same = existing[i].spec == specs[i] && existing[i].version == promptVersion
		}
		if same {
			// Identical content: retry what failed, keep what is done.
			tag, err := tx.Exec(ctx, s.q(`
				UPDATE {{schema}}.extraction_jobs SET state = 'pending', attempts = 0, last_error_code = '', claimed_until = NULL, not_before = NULL, updated_at = now()
				WHERE collection = $1 AND document_id = $2 AND state = 'failed'`), collection, documentID)
			n = int(tag.RowsAffected())
			return err
		}
		if err := s.dropDocGraph(ctx, tx, collection, documentID); err != nil {
			return err
		}
		batch := &pgx.Batch{}
		for _, sp := range specs {
			batch.Queue(s.q(`
				INSERT INTO {{schema}}.extraction_jobs (collection, document_id, window_idx, window_hash, first_chunk, chunk_count, prompt_version)
				VALUES ($1, $2, $3, $4, $5, $6, $7)`), collection, documentID, sp.WindowIdx, sp.WindowHash, sp.FirstChunk, sp.ChunkCount, promptVersion)
		}
		br := tx.SendBatch(ctx, batch)
		for range specs {
			if _, err := br.Exec(); err != nil {
				_ = br.Close()
				return err
			}
		}
		if err := br.Close(); err != nil {
			return err
		}
		n = len(specs)
		return nil
	})
	return n, err
}

func (s *Store) ClaimJob(ctx context.Context, lease time.Duration) (store.Job, bool, error) {
	if err := s.needGraph(); err != nil {
		return store.Job{}, false, err
	}
	var j store.Job
	// a collection with a graph schema has curated facts only: its jobs wait, and resume if the schema is deleted
	skip := ""
	if s.schemas {
		skip = ` AND NOT EXISTS (SELECT 1 FROM {{schema}}.graph_schemas gs WHERE gs.collection = extraction_jobs.collection)`
	}
	err := s.pool.QueryRow(ctx, s.q(`
		UPDATE {{schema}}.extraction_jobs j
		SET attempts = attempts + 1, claimed_until = now() + make_interval(secs => $1), updated_at = now()
		WHERE (j.collection, j.document_id, j.window_idx) = (
		  SELECT collection, document_id, window_idx FROM {{schema}}.extraction_jobs
		  WHERE state = 'pending' AND (claimed_until IS NULL OR claimed_until <= now()) AND (not_before IS NULL OR not_before <= now())`+skip+`
		  ORDER BY created_seq LIMIT 1 FOR UPDATE SKIP LOCKED)
		RETURNING j.collection, j.document_id, j.window_idx, j.window_hash, j.first_chunk, j.chunk_count, j.prompt_version, j.state, j.attempts, j.last_error_code, j.updated_at`),
		lease.Seconds()).Scan(&j.Collection, &j.DocumentID, &j.WindowIdx, &j.WindowHash, &j.FirstChunk, &j.ChunkCount, &j.PromptVersion, &j.State, &j.Attempts, &j.LastErrorCode, &j.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return store.Job{}, false, nil
	}
	if err != nil {
		return store.Job{}, false, err
	}
	return j, true, nil
}

func (s *Store) FailJob(ctx context.Context, key store.JobKey, code string, retryIn time.Duration, final bool) error {
	if err := s.needGraph(); err != nil {
		return err
	}
	tag, err := s.pool.Exec(ctx, s.q(`
		UPDATE {{schema}}.extraction_jobs SET
		  last_error_code = $4, updated_at = now(),
		  state = CASE WHEN $5 THEN 'failed' ELSE state END,
		  claimed_until = CASE WHEN $5 THEN claimed_until ELSE NULL END,
		  not_before = CASE WHEN $5 THEN not_before ELSE now() + make_interval(secs => $6) END
		WHERE collection = $1 AND document_id = $2 AND window_idx = $3 AND state = 'pending'`),
		key.Collection, key.DocumentID, key.WindowIdx, code, final, retryIn.Seconds())
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return store.ErrJobGone
	}
	return nil
}

func (s *Store) ApplyExtraction(ctx context.Context, res store.ExtractionResult) error {
	if err := s.needGraph(); err != nil {
		return err
	}
	for i, e := range res.Entities {
		if err := s.checkEmbedding(e.NameEmbedding); err != nil {
			return fmt.Errorf("entity %d: %w", i, err)
		}
	}
	for i, r := range res.Relations {
		if r.Src < 0 || r.Src >= len(res.Entities) || r.Dst < 0 || r.Dst >= len(res.Entities) {
			return fmt.Errorf("relation %d refers to an entity outside the result", i)
		}
	}
	coll, doc := res.Job.Collection, res.Job.DocumentID
	return s.inGraphTx(ctx, coll, func(tx pgx.Tx) error {
		// the schema may have appeared after the job was claimed: under the lock, nothing is written to a collection that has one
		if has, err := s.hasSchema(ctx, tx, coll); err != nil {
			return err
		} else if has {
			return store.ErrJobGone
		}
		var state string
		err := tx.QueryRow(ctx, s.q(`
			SELECT state FROM {{schema}}.extraction_jobs WHERE collection = $1 AND document_id = $2 AND window_idx = $3 FOR UPDATE`),
			coll, doc, res.Job.WindowIdx).Scan(&state)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && state != store.JobPending) {
			return store.ErrJobGone
		}
		if err != nil {
			return err
		}
		ids := make([]int64, len(res.Entities))
		for i, x := range res.Entities {
			e, err := s.upsertEntity(ctx, tx, store.EntityInput{
				Collection: coll, Name: x.Name, Type: x.Type, Description: x.Description, Aliases: x.Aliases, NameEmbedding: x.NameEmbedding, DocumentID: doc,
			})
			if err != nil {
				return err
			}
			ids[i] = e.ID
			for _, c := range x.Chunks {
				if err := s.link(ctx, tx, coll, store.EntityChunk{EntityID: e.ID, DocumentID: doc, ChunkIndex: c}); err != nil {
					return err
				}
			}
		}
		for _, r := range res.Relations {
			if _, err := s.addRelation(ctx, tx, store.Relation{
				Collection: coll, SrcID: ids[r.Src], DstID: ids[r.Dst], Predicate: r.Predicate, Evidence: r.Evidence,
				DocumentID: doc, ChunkIndex: r.ChunkIndex, PromptVersion: res.PromptVersion, Model: res.Model,
			}); err != nil {
				return err
			}
		}
		_, err = tx.Exec(ctx, s.q(`
			UPDATE {{schema}}.extraction_jobs SET state = 'done', last_error_code = '', updated_at = now()
			WHERE collection = $1 AND document_id = $2 AND window_idx = $3`), coll, doc, res.Job.WindowIdx)
		return err
	})
}

// demoteUndeclared un-marks the given entities that no fact set declares any
// more. The caller then collects entities nothing refers to.
func (s *Store) demoteUndeclared(ctx context.Context, q querier, ids []int64) error {
	if len(ids) == 0 {
		return nil
	}
	_, err := q.Exec(ctx, s.q(`
		UPDATE {{schema}}.entities e SET origin = 'extracted'
		WHERE e.id = ANY($1) AND e.origin = 'manual'
		  AND NOT EXISTS (SELECT 1 FROM {{schema}}.graph_factset_entities m WHERE m.entity_id = e.id)`), ids)
	return err
}

// dropFactSet deletes a fact set row (its relations and declarations go with it
// by cascade) and un-marks the entities nobody declares any more. It reports
// whether the fact set existed. The caller holds the collection lock.
func (s *Store) dropFactSet(ctx context.Context, q querier, collection, id string) (bool, error) {
	rows, err := q.Query(ctx, s.q(`SELECT entity_id FROM {{schema}}.graph_factset_entities WHERE collection = $1 AND factset_id = $2`), collection, id)
	if err != nil {
		return false, err
	}
	var ids []int64
	for rows.Next() {
		var x int64
		if err := rows.Scan(&x); err != nil {
			rows.Close()
			return false, err
		}
		ids = append(ids, x)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return false, err
	}
	tag, err := q.Exec(ctx, s.q(`DELETE FROM {{schema}}.graph_factsets WHERE collection = $1 AND id = $2`), collection, id)
	if err != nil || tag.RowsAffected() == 0 {
		return false, err
	}
	return true, s.demoteUndeclared(ctx, q, ids)
}

func (s *Store) ReplaceFactSet(ctx context.Context, fs store.FactSet) (bool, error) {
	if err := s.needGraph(); err != nil {
		return false, err
	}
	ends, err := fs.Resolve()
	if err != nil {
		return false, err
	}
	body, err := json.Marshal(fs.Clone())
	if err != nil {
		return false, err
	}
	hash := fs.Hash()
	changed := false
	err = s.inGraphTx(ctx, fs.Collection, func(tx pgx.Tx) error {
		if err := s.checkFactSetUnderLock(ctx, tx, fs); err != nil {
			return err
		}
		var old string
		switch err := tx.QueryRow(ctx, s.q(`SELECT body_hash FROM {{schema}}.graph_factsets WHERE collection = $1 AND id = $2`), fs.Collection, fs.ID).Scan(&old); {
		case err == nil && old == hash:
			return nil
		case err != nil && !errors.Is(err, pgx.ErrNoRows):
			return err
		}
		changed = true
		if _, err := s.dropFactSet(ctx, tx, fs.Collection, fs.ID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, s.q(`
			INSERT INTO {{schema}}.graph_factsets (collection, id, source_uri, body_hash, body, entity_count, relation_count)
			VALUES ($1, $2, $3, $4, $5::jsonb, $6, $7)`), fs.Collection, fs.ID, fs.SourceURI, hash, string(body), len(fs.Entities), len(fs.Relations)); err != nil {
			return err
		}
		ids := make([]int64, len(fs.Entities))
		for i, x := range fs.Entities {
			e, err := s.upsertEntity(ctx, tx, store.EntityInput{
				Collection: fs.Collection, Name: x.Name, Type: x.Type, Description: x.Description, Aliases: x.Aliases, Origin: store.OriginManual,
			})
			if err != nil {
				return err
			}
			ids[i] = e.ID
			if _, err := tx.Exec(ctx, s.q(`
				INSERT INTO {{schema}}.graph_factset_entities (collection, factset_id, entity_id) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING`),
				fs.Collection, fs.ID, e.ID); err != nil {
				return err
			}
		}
		for i, r := range fs.Relations {
			if _, err := tx.Exec(ctx, s.q(`
				INSERT INTO {{schema}}.relations (collection, src_id, dst_id, predicate, evidence, factset_id, origin)
				VALUES ($1, $2, $3, $4, $5, $6, 'manual') ON CONFLICT DO NOTHING`),
				fs.Collection, ids[ends[i][0]], ids[ends[i][1]], r.Predicate, r.Note, fs.ID); err != nil {
				return err
			}
		}
		return s.collectEntities(ctx, tx, fs.Collection)
	})
	return changed, err
}

func (s *Store) GetFactSet(ctx context.Context, collection, id string) (store.FactSet, error) {
	if err := s.needGraph(); err != nil {
		return store.FactSet{}, err
	}
	var body []byte
	err := s.pool.QueryRow(ctx, s.q(`SELECT body FROM {{schema}}.graph_factsets WHERE collection = $1 AND id = $2`), collection, id).Scan(&body)
	if errors.Is(err, pgx.ErrNoRows) {
		return store.FactSet{}, store.ErrFactSetNotFound
	}
	if err != nil {
		return store.FactSet{}, err
	}
	fs := store.FactSet{Collection: collection, ID: id}
	if err := json.Unmarshal(body, &fs); err != nil {
		return store.FactSet{}, fmt.Errorf("stored fact set is unreadable: %w", err)
	}
	return fs, nil
}

func (s *Store) ListFactSets(ctx context.Context, collection string) ([]store.FactSetInfo, error) {
	if err := s.needGraph(); err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, s.q(`
		SELECT id, source_uri, entity_count, relation_count, updated_at FROM {{schema}}.graph_factsets
		WHERE collection = $1 ORDER BY id COLLATE "C"`), collection)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []store.FactSetInfo
	for rows.Next() {
		var i store.FactSetInfo
		if err := rows.Scan(&i.ID, &i.SourceURI, &i.Entities, &i.Relations, &i.UpdatedAt); err != nil {
			return nil, err
		}
		out = append(out, i)
	}
	return out, rows.Err()
}

func (s *Store) DeleteFactSet(ctx context.Context, collection, id string) (bool, error) {
	if err := s.needGraph(); err != nil {
		return false, err
	}
	existed := false
	err := s.inGraphTx(ctx, collection, func(tx pgx.Tx) error {
		var err error
		if existed, err = s.dropFactSet(ctx, tx, collection, id); err != nil || !existed {
			return err
		}
		return s.collectEntities(ctx, tx, collection)
	})
	return existed, err
}
