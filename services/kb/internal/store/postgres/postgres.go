// Package postgres is a store.Store backed by PostgreSQL: tsvector full-text
// search (websearch_to_tsquery + ts_rank_cd) and, optionally, pgvector cosine
// search fused with the lexical ranking by reciprocal rank fusion.
package postgres

import (
	"context"
	"embed"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/openagentix/openagentix/services/kb/internal/store"
)

//go:embed migrations/*.sql
var migrationFS embed.FS

var schemaRe = regexp.MustCompile(`^[a-z_][a-z0-9_]{0,62}$`)

const rrfK = 60

// Options configures Open.
type Options struct {
	URL       string
	Schema    string // PostgreSQL schema holding the tables; created if missing
	VectorDim int    // > 0 enables pgvector with this dimension
	// Graph creates the knowledge-graph tables (migrations 3 to 6) and enables
	// the graph methods. With false no graph table is created and those methods
	// return store.ErrGraphDisabled.
	Graph bool
}

// Store implements store.Store on PostgreSQL.
type Store struct {
	pool   *pgxpool.Pool
	schema string // quoted identifier
	dim    int
	graph  bool
	// vecSchema is the quoted schema holding the pgvector extension. All
	// vector types and operators are referenced qualified with it, so the
	// extension can live in any schema (by default "public", shared by every
	// KB schema in the database).
	vecSchema string
}

// Open connects, runs the embedded migrations and returns a ready store. With
// VectorDim > 0 it requires the pgvector extension and fails if unavailable.
func Open(ctx context.Context, o Options) (*Store, error) {
	if !schemaRe.MatchString(o.Schema) {
		return nil, fmt.Errorf("invalid schema name %q: want [a-z_][a-z0-9_]{0,62}", o.Schema)
	}
	cfg, err := pgxpool.ParseConfig(o.URL)
	if err != nil {
		return nil, errors.New("invalid database URL: " + redactParseErr(err))
	}
	quoted := pgx.Identifier{o.Schema}.Sanitize()
	cfg.ConnConfig.RuntimeParams["search_path"] = quoted + ", public"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("connecting to database: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("database unreachable: %w", err)
	}
	s := &Store{pool: pool, schema: quoted, dim: o.VectorDim, graph: o.Graph}
	if err := s.migrate(ctx, o.Schema); err != nil {
		pool.Close()
		return nil, err
	}
	return s, nil
}

// redactParseErr avoids echoing the URL (which may hold a password).
func redactParseErr(err error) string {
	msg := err.Error()
	if i := strings.Index(msg, "://"); i >= 0 {
		return "cannot parse connection string"
	}
	return msg
}

func (s *Store) render(sql string) string {
	sql = strings.ReplaceAll(sql, "{{schema}}", s.schema)
	sql = strings.ReplaceAll(sql, "{{vs}}", s.vecSchema)
	return strings.ReplaceAll(sql, "{{dim}}", strconv.Itoa(s.dim))
}

func (s *Store) migrate(ctx context.Context, rawSchema string) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	// Serialise concurrent replicas starting at the same time.
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, "kb-migrate:"+rawSchema); err != nil {
		return fmt.Errorf("migration lock: %w", err)
	}
	if _, err := tx.Exec(ctx, "CREATE SCHEMA IF NOT EXISTS "+s.schema); err != nil {
		return fmt.Errorf("creating schema: %w", err)
	}
	if _, err := tx.Exec(ctx, "CREATE TABLE IF NOT EXISTS "+s.schema+".schema_migrations (version integer PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())"); err != nil {
		return fmt.Errorf("migration table: %w", err)
	}
	steps := []struct {
		version int
		file    string
		enabled bool
		pre     func(context.Context, pgx.Tx) error
		post    func(context.Context, pgx.Tx) error
	}{
		{1, "migrations/0001_init.sql", true, nil, nil},
		{2, "migrations/0002_vector.sql", s.dim > 0, s.prepareVector, nil},
		{3, "migrations/0003_graph.sql", s.graph, nil, nil},
		{4, "migrations/0004_graph_vector.sql", s.graph && s.dim > 0, nil, nil},
		{5, "migrations/0005_graph_canonical.sql", s.graph, nil, s.backfillCanonNames},
		{6, "migrations/0006_graph_factsets.sql", s.graph, nil, nil},
	}
	for _, st := range steps {
		if !st.enabled {
			continue
		}
		if st.pre != nil {
			if err := st.pre(ctx, tx); err != nil {
				return err
			}
		}
		sql, err := migrationFS.ReadFile(st.file)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, s.render(string(sql))); err != nil {
			return fmt.Errorf("migration %s: %w", st.file, err)
		}
		if st.post != nil {
			if err := st.post(ctx, tx); err != nil {
				return fmt.Errorf("migration %s: %w", st.file, err)
			}
		}
		if _, err := tx.Exec(ctx, "INSERT INTO "+s.schema+".schema_migrations (version) VALUES ($1) ON CONFLICT DO NOTHING", st.version); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

// prepareVector ensures the pgvector extension exists and that any existing
// embedding column has the configured dimension.
func (s *Store) prepareVector(ctx context.Context, tx pgx.Tx) error {
	var available bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'vector')`).Scan(&available); err != nil {
		return err
	}
	if !available {
		return errors.New("pgvector extension is not available on this PostgreSQL server: install pgvector (e.g. use the pgvector/pgvector image) or unset KB_EMBEDDINGS_URL to run lexical-only")
	}
	// Serialise extension creation across KB schemas (the per-schema migration
	// lock does not cover two schemas starting at once).
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('kb-vector-extension'))`); err != nil {
		return fmt.Errorf("extension lock: %w", err)
	}
	var extSchema string
	err := tx.QueryRow(ctx, `SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'vector'`).Scan(&extSchema)
	switch {
	case err == nil:
		// Already installed (possibly by an older version inside the kb schema): use it where it is.
	case errors.Is(err, pgx.ErrNoRows):
		// Install it in public, not wherever search_path happens to point first, so
		// every KB schema in this database can reference the same type.
		if _, err := tx.Exec(ctx, `CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public`); err != nil {
			return fmt.Errorf("pgvector extension cannot be created (needs CREATE privilege or a superuser to pre-create it): %w", err)
		}
		extSchema = "public"
	default:
		return err
	}
	s.vecSchema = pgx.Identifier{extSchema}.Sanitize()
	var typmod *int32
	err = tx.QueryRow(ctx, `
		SELECT a.atttypmod FROM pg_attribute a
		JOIN pg_class c ON c.oid = a.attrelid
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE n.nspname = $1 AND c.relname = 'chunks' AND a.attname = 'embedding' AND NOT a.attisdropped`,
		strings.Trim(s.schema, `"`)).Scan(&typmod)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return nil
	case err != nil:
		return err
	case typmod != nil && int(*typmod) != s.dim:
		return fmt.Errorf("existing embedding column has dimension %d but KB_EMBEDDINGS_DIM is %d: use a new KB_DB_SCHEMA or migrate the column", *typmod, s.dim)
	}
	return nil
}

func (s *Store) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }
func (s *Store) Close()                         { s.pool.Close() }

func vectorLiteral(v []float32) string {
	parts := make([]string, len(v))
	for i, f := range v {
		parts[i] = strconv.FormatFloat(float64(f), 'g', -1, 32)
	}
	return "[" + strings.Join(parts, ",") + "]"
}

func (s *Store) UpsertDocument(ctx context.Context, doc store.Document, chunks []store.Chunk) error {
	if s.dim > 0 {
		for i, c := range chunks {
			if c.Embedding != nil && len(c.Embedding) != s.dim {
				return fmt.Errorf("chunk %d: embedding has dimension %d, store expects %d", i, len(c.Embedding), s.dim)
			}
		}
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(ctx, `
		INSERT INTO `+s.schema+`.documents (collection, id, title, source_uri, text, updated_at)
		VALUES ($1, $2, $3, $4, $5, now())
		ON CONFLICT (collection, id) DO UPDATE
		SET title = EXCLUDED.title, source_uri = EXCLUDED.source_uri, text = EXCLUDED.text, updated_at = now()`,
		doc.Collection, doc.ID, doc.Title, doc.SourceURI, doc.Text); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM `+s.schema+`.chunks WHERE collection = $1 AND doc_id = $2`, doc.Collection, doc.ID); err != nil {
		return err
	}
	batch := &pgx.Batch{}
	for i, c := range chunks {
		if s.dim > 0 {
			var emb *string
			if c.Embedding != nil {
				l := vectorLiteral(c.Embedding)
				emb = &l
			}
			batch.Queue(`INSERT INTO `+s.schema+`.chunks (collection, doc_id, idx, text, embedding) VALUES ($1, $2, $3, $4, $5::`+s.vecSchema+`.vector)`,
				doc.Collection, doc.ID, i, c.Text, emb)
		} else {
			batch.Queue(`INSERT INTO `+s.schema+`.chunks (collection, doc_id, idx, text) VALUES ($1, $2, $3, $4)`,
				doc.Collection, doc.ID, i, c.Text)
		}
	}
	br := tx.SendBatch(ctx, batch)
	for range chunks {
		if _, err := br.Exec(); err != nil {
			_ = br.Close()
			return err
		}
	}
	if err := br.Close(); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *Store) DeleteDocument(ctx context.Context, collection, id string) (bool, error) {
	if s.graph {
		return s.deleteDocumentWithGraph(ctx, collection, id)
	}
	tag, err := s.pool.Exec(ctx, `DELETE FROM `+s.schema+`.documents WHERE collection = $1 AND id = $2`, collection, id)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() > 0, nil
}

func (s *Store) GetDocument(ctx context.Context, collection, id string) (store.Document, error) {
	return s.GetDocumentIn(ctx, store.Scope{}, collection, id)
}

// scopeArgs gives the two query arguments of a scope: whether it limits, and the list.
func scopeArgs(sc store.Scope) (bool, []string) {
	list := sc.Collections
	if list == nil {
		list = []string{}
	}
	return sc.Limited, list
}

func (s *Store) GetDocumentIn(ctx context.Context, scope store.Scope, collection, id string) (store.Document, error) {
	limited, list := scopeArgs(scope)
	rows, err := s.pool.Query(ctx, `
		SELECT collection, id, title, source_uri, text, updated_at FROM `+s.schema+`.documents
		WHERE id = $1 AND ($2 = '' OR collection = $2) AND (NOT $3::bool OR collection = ANY($4::text[]))
		ORDER BY collection LIMIT 2`, id, collection, limited, list)
	if err != nil {
		return store.Document{}, err
	}
	defer rows.Close()
	var docs []store.Document
	for rows.Next() {
		var d store.Document
		if err := rows.Scan(&d.Collection, &d.ID, &d.Title, &d.SourceURI, &d.Text, &d.UpdatedAt); err != nil {
			return store.Document{}, err
		}
		docs = append(docs, d)
	}
	if err := rows.Err(); err != nil {
		return store.Document{}, err
	}
	switch len(docs) {
	case 0:
		return store.Document{}, store.ErrNotFound
	case 1:
		return docs[0], nil
	default:
		return store.Document{}, store.ErrAmbiguous
	}
}

func (s *Store) ListCollections(ctx context.Context) ([]store.CollectionInfo, error) {
	return s.ListCollectionsIn(ctx, store.Scope{})
}

func (s *Store) ListCollectionsIn(ctx context.Context, scope store.Scope) ([]store.CollectionInfo, error) {
	limited, list := scopeArgs(scope)
	rows, err := s.pool.Query(ctx, `SELECT collection, count(*) FROM `+s.schema+`.documents
		WHERE (NOT $1::bool OR collection = ANY($2::text[])) GROUP BY collection ORDER BY collection`, limited, list)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []store.CollectionInfo
	for rows.Next() {
		var c store.CollectionInfo
		if err := rows.Scan(&c.Name, &c.Documents); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// webSearchQuery turns free text into a websearch_to_tsquery string. Plain
// words are OR-ed (ts_rank_cd then ranks documents matching more terms higher);
// text that already uses quotes, "or" or "-" keeps its websearch semantics.
func webSearchQuery(q string) string {
	words := strings.Fields(q)
	if len(words) == 0 {
		return ""
	}
	for _, w := range words {
		if strings.Contains(w, `"`) || strings.EqualFold(w, "or") || strings.HasPrefix(w, "-") {
			return strings.Join(words, " ")
		}
	}
	return strings.Join(words, " or ")
}

const hitColumns = `c.collection, c.doc_id, d.title, d.source_uri, c.idx, c.text`

func scanHits(rows pgx.Rows) ([]store.Hit, error) {
	defer rows.Close()
	var out []store.Hit
	for rows.Next() {
		var h store.Hit
		if err := rows.Scan(&h.Collection, &h.DocumentID, &h.Title, &h.SourceURI, &h.ChunkIndex, &h.Text, &h.Score); err != nil {
			return nil, err
		}
		out = append(out, h)
	}
	return out, rows.Err()
}

// hasPositiveTerm reports whether a query has at least one term that is
// neither a "-negation" nor the "or" operator. websearch_to_tsquery turns a
// negation-only query into "NOT x", which matches every chunk lacking x.
func hasPositiveTerm(q string) bool {
	for _, w := range strings.Fields(q) {
		if strings.HasPrefix(w, "-") || strings.EqualFold(w, "or") {
			continue
		}
		if strings.IndexFunc(w, func(r rune) bool { return unicode.IsLetter(r) || unicode.IsDigit(r) }) >= 0 {
			return true
		}
	}
	return false
}

func (s *Store) lexical(ctx context.Context, q store.Query, limit int) ([]store.Hit, error) {
	text := webSearchQuery(q.Text)
	if text == "" || !hasPositiveTerm(q.Text) {
		return nil, nil
	}
	limited, list := scopeArgs(q.Scope)
	rows, err := s.pool.Query(ctx, `
		SELECT `+hitColumns+`, ts_rank_cd(c.tsv, tq.query)::float8 AS score
		FROM `+s.schema+`.chunks c
		JOIN `+s.schema+`.documents d ON d.collection = c.collection AND d.id = c.doc_id,
		     websearch_to_tsquery('english', $1) AS tq(query)
		WHERE c.tsv @@ tq.query AND ($2 = '' OR c.collection = $2) AND (NOT $4::bool OR c.collection = ANY($5::text[]))
		ORDER BY score DESC, c.collection, c.doc_id, c.idx
		LIMIT $3`, text, q.Collection, limit, limited, list)
	if err != nil {
		return nil, err
	}
	return scanHits(rows)
}

// vector runs the cosine search. An HNSW index scan filters after the index
// returns its candidates (hnsw.ef_search, default 40), so a collection filter
// can silently under-return. pgvector 0.8 added iterative scans that keep
// scanning until LIMIT rows pass the filter; we enable them for this query
// only. Older pgvector lacks the setting, in which case we widen ef_search
// instead (best effort) and carry on.
func (s *Store) vector(ctx context.Context, q store.Query, limit int) ([]store.Hit, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if q.Collection != "" || q.Scope.Limited {
		s.widenHNSWScan(ctx, tx)
	}
	limited, list := scopeArgs(q.Scope)
	// ORDER BY the distance alone so the planner can use the HNSW index; ties
	// are ordered deterministically in Go below.
	rows, err := tx.Query(ctx, `
		SELECT `+hitColumns+`, (1 - (c.embedding OPERATOR(`+s.vecSchema+`.<=>) $1::`+s.vecSchema+`.vector))::float8 AS score
		FROM `+s.schema+`.chunks c
		JOIN `+s.schema+`.documents d ON d.collection = c.collection AND d.id = c.doc_id
		WHERE c.embedding IS NOT NULL AND ($2 = '' OR c.collection = $2) AND (NOT $4::bool OR c.collection = ANY($5::text[]))
		ORDER BY c.embedding OPERATOR(`+s.vecSchema+`.<=>) $1::`+s.vecSchema+`.vector
		LIMIT $3`, vectorLiteral(q.Embedding), q.Collection, limit, limited, list)
	if err != nil {
		return nil, err
	}
	hits, err := scanHits(rows)
	if err != nil {
		return nil, err
	}
	sort.SliceStable(hits, func(i, j int) bool {
		a, b := hits[i], hits[j]
		if a.Score != b.Score {
			return a.Score > b.Score
		}
		if a.Collection != b.Collection {
			return a.Collection < b.Collection
		}
		if a.DocumentID != b.DocumentID {
			return a.DocumentID < b.DocumentID
		}
		return a.ChunkIndex < b.ChunkIndex
	})
	kept := hits[:0]
	for _, h := range hits {
		if h.Score > 0 {
			kept = append(kept, h)
		}
	}
	return kept, nil
}

// widenHNSWScan makes the HNSW index keep scanning until the filtered LIMIT is
// met. Each SET runs in a savepoint because an unknown setting aborts the
// transaction; failures are ignored (older pgvector, or a non-HNSW plan).
func (s *Store) widenHNSWScan(ctx context.Context, tx pgx.Tx) {
	if !trySet(ctx, tx, `SET LOCAL hnsw.iterative_scan = strict_order`) {
		trySet(ctx, tx, `SET LOCAL hnsw.ef_search = 1000`)
	}
}

// trySet runs a SET inside a savepoint so that a failure (unknown setting)
// leaves the surrounding transaction usable. It reports success.
func trySet(ctx context.Context, tx pgx.Tx, stmt string) bool {
	sp, err := tx.Begin(ctx)
	if err != nil {
		return false
	}
	if _, err := sp.Exec(ctx, stmt); err != nil {
		_ = sp.Rollback(ctx)
		return false
	}
	return sp.Commit(ctx) == nil
}

func (s *Store) Search(ctx context.Context, q store.Query) ([]store.Hit, error) {
	if q.TopK <= 0 {
		return nil, nil
	}
	useVec := s.dim > 0 && len(q.Embedding) > 0
	if useVec && len(q.Embedding) != s.dim {
		return nil, fmt.Errorf("query embedding has dimension %d, store expects %d", len(q.Embedding), s.dim)
	}
	pool := max(50, q.TopK*4)
	lex, err := s.lexical(ctx, q, pool)
	if err != nil {
		return nil, err
	}
	var vec []store.Hit
	if useVec {
		if vec, err = s.vector(ctx, q, pool); err != nil {
			return nil, err
		}
	}
	var out []store.Hit
	switch {
	case len(vec) == 0:
		out = lex
	case len(lex) == 0:
		out = vec
	default:
		out = fuse(lex, vec)
	}
	if len(out) > q.TopK {
		out = out[:q.TopK]
	}
	return out, nil
}

type chunkKey struct {
	collection, doc string
	idx             int
}

// fuse merges ranked lists by reciprocal rank fusion; the fused score replaces
// each hit's score.
func fuse(lists ...[]store.Hit) []store.Hit {
	scores := map[chunkKey]float64{}
	byKey := map[chunkKey]store.Hit{}
	for _, l := range lists {
		for rank, h := range l {
			k := chunkKey{h.Collection, h.DocumentID, h.ChunkIndex}
			scores[k] += 1.0 / float64(rrfK+rank+1)
			byKey[k] = h
		}
	}
	out := make([]store.Hit, 0, len(byKey))
	for k, h := range byKey {
		h.Score = scores[k]
		out = append(out, h)
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if a.Score != b.Score {
			return a.Score > b.Score
		}
		if a.Collection != b.Collection {
			return a.Collection < b.Collection
		}
		if a.DocumentID != b.DocumentID {
			return a.DocumentID < b.DocumentID
		}
		return a.ChunkIndex < b.ChunkIndex
	})
	return out
}
