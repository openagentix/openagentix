package postgres

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/openagentix/openagentix/services/kb/internal/store"
	"github.com/openagentix/openagentix/services/kb/internal/store/storetest"
)

const envURL = "KB_TEST_DATABASE_URL"

func testURL(t *testing.T) string {
	t.Helper()
	u := os.Getenv(envURL)
	if u == "" {
		t.Skipf("%s not set; skipping PostgreSQL integration test", envURL)
	}
	return u
}

func randomSchema() string {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	return "kbtest_" + hex.EncodeToString(b)
}

// open returns a store in a fresh schema that is dropped at test end.
func open(t *testing.T, dim int) (*Store, string) {
	t.Helper()
	return openAt(t, testURL(t), dim, false)
}

func openAt(t *testing.T, url string, dim int, graph bool) (*Store, string) {
	t.Helper()
	return openWith(t, url, dim, graph, false)
}

// openWith is openAt with graph schemas (ADR 0030) on or off.
func openWith(t *testing.T, url string, dim int, graph, schemas bool) (*Store, string) {
	t.Helper()
	schema := randomSchema()
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	s, err := Open(ctx, Options{URL: url, Schema: schema, VectorDim: dim, Graph: graph, GraphSchemas: schemas})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() {
		s.Close()
		pool, err := pgxpool.New(context.Background(), url)
		if err != nil {
			return
		}
		defer pool.Close()
		_, _ = pool.Exec(context.Background(), `DROP SCHEMA IF EXISTS "`+schema+`" CASCADE`)
	})
	return s, schema
}

func TestConformanceLexical(t *testing.T) {
	testURL(t)
	url := testURL(t)
	storetest.Run(t, storetest.Factory{New: func(t *testing.T) store.Store { s, _ := openWith(t, url, 0, true, true); return s }, Graph: true, Schemas: true})
}

func TestConformanceHybrid(t *testing.T) {
	testURL(t)
	url := testURL(t)
	storetest.Run(t, storetest.Factory{New: func(t *testing.T) store.Store { s, _ := openWith(t, url, 3, true, true); return s }, Vectors: true, Dim: 3, Graph: true, Schemas: true})
}

func TestMigrationsAreIdempotent(t *testing.T) {
	url := testURL(t)
	schema := randomSchema()
	ctx := context.Background()
	for i := 0; i < 3; i++ {
		s, err := Open(ctx, Options{URL: url, Schema: schema, VectorDim: 3})
		if err != nil {
			t.Fatalf("open #%d: %v", i, err)
		}
		if i == 0 {
			if err := s.UpsertDocument(ctx, store.Document{Collection: "c", ID: "a", Text: "t"}, []store.Chunk{{Text: "keepme"}}); err != nil {
				t.Fatalf("upsert: %v", err)
			}
		}
		s.Close()
	}
	s, err := Open(ctx, Options{URL: url, Schema: schema, VectorDim: 3})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		s.Close()
		p, _ := pgxpool.New(ctx, url)
		_, _ = p.Exec(ctx, `DROP SCHEMA "`+schema+`" CASCADE`)
		p.Close()
	}()
	hits, err := s.Search(ctx, store.Query{Text: "keepme", TopK: 3})
	if err != nil || len(hits) != 1 {
		t.Fatalf("data lost across re-open: %+v %v", hits, err)
	}
}

func TestConcurrentOpenSameSchema(t *testing.T) {
	url := testURL(t)
	schema := randomSchema()
	ctx := context.Background()
	errs := make(chan error, 4)
	for i := 0; i < 4; i++ {
		go func() {
			s, err := Open(ctx, Options{URL: url, Schema: schema, VectorDim: 3})
			if err == nil {
				s.Close()
			}
			errs <- err
		}()
	}
	for i := 0; i < 4; i++ {
		if err := <-errs; err != nil {
			t.Errorf("concurrent open: %v", err)
		}
	}
	p, _ := pgxpool.New(ctx, url)
	_, _ = p.Exec(ctx, `DROP SCHEMA IF EXISTS "`+schema+`" CASCADE`)
	p.Close()
}

func TestVectorDimensionMismatchFailsClearly(t *testing.T) {
	url := testURL(t)
	_, schema := open(t, 3)
	_, err := Open(context.Background(), Options{URL: url, Schema: schema, VectorDim: 5})
	if err == nil || !strings.Contains(err.Error(), "dimension") {
		t.Fatalf("err = %v", err)
	}
}

func TestLexicalOnlyOpenDoesNotRequireVectorExtension(t *testing.T) {
	url := testURL(t)
	schema := randomSchema()
	s, err := Open(context.Background(), Options{URL: url, Schema: schema})
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
	p, _ := pgxpool.New(context.Background(), url)
	defer p.Close()
	var n int
	_ = p.QueryRow(context.Background(), `SELECT count(*) FROM information_schema.columns WHERE table_schema=$1 AND column_name='embedding'`, schema).Scan(&n)
	if n != 0 {
		t.Fatal("embedding column created although vectors are disabled")
	}
	_, _ = p.Exec(context.Background(), `DROP SCHEMA "`+schema+`" CASCADE`)
}

func TestMissingVectorExtensionFailsStartupClearly(t *testing.T) {
	url := os.Getenv("KB_TEST_DATABASE_URL_NOVECTOR")
	if url == "" {
		t.Skip("KB_TEST_DATABASE_URL_NOVECTOR not set")
	}
	_, err := Open(context.Background(), Options{URL: url, Schema: randomSchema(), VectorDim: 3})
	if err == nil || !strings.Contains(err.Error(), "pgvector") {
		t.Fatalf("err = %v", err)
	}
}

func TestInvalidSchemaNameRejected(t *testing.T) {
	for _, s := range []string{"", "Bad-Name", `x"; drop schema public; --`, strings.Repeat("a", 64)} {
		if _, err := Open(context.Background(), Options{URL: "postgres://localhost:1/x", Schema: s}); err == nil || !strings.Contains(err.Error(), "schema") {
			t.Errorf("schema %q: err = %v", s, err)
		}
	}
}

func TestOpenUnreachableFails(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if _, err := Open(ctx, Options{URL: "postgres://u:p@127.0.0.1:1/x?connect_timeout=1", Schema: "kb"}); err == nil {
		t.Fatal("expected error")
	}
}

func TestWebSearchQuery(t *testing.T) {
	cases := map[string]string{
		"kubernetes ingress":   "kubernetes or ingress",
		"  spaced   out  ":     "spaced or out",
		"single":               "single",
		`"exact phrase" other`: `"exact phrase" other`,
		"alpha or beta":        "alpha or beta",
		"foo -bar":             "foo -bar",
		"":                     "",
	}
	for in, want := range cases {
		if got := webSearchQuery(in); got != want {
			t.Errorf("webSearchQuery(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestVectorLiteral(t *testing.T) {
	if got := vectorLiteral([]float32{1, 0.5, -2}); got != "[1,0.5,-2]" {
		t.Fatalf("got %q", got)
	}
}

func dropSchema(t *testing.T, url, schema string) {
	t.Helper()
	p, err := pgxpool.New(context.Background(), url)
	if err != nil {
		return
	}
	defer p.Close()
	_, _ = p.Exec(context.Background(), `DROP SCHEMA IF EXISTS "`+schema+`" CASCADE`)
}

func TestTwoSchemasShareOnePgvectorExtension(t *testing.T) {
	url := testURL(t)
	ctx := context.Background()
	a, b := randomSchema(), randomSchema()
	t.Cleanup(func() { dropSchema(t, url, a); dropSchema(t, url, b) })
	for _, schema := range []string{a, b} {
		s, err := Open(ctx, Options{URL: url, Schema: schema, VectorDim: 3})
		if err != nil {
			t.Fatalf("Open(%s): %v", schema, err)
		}
		doc := store.Document{Collection: "c", ID: "d", Text: "t"}
		if err := s.UpsertDocument(ctx, doc, []store.Chunk{{Text: "vec", Embedding: []float32{1, 0, 0}}}); err != nil {
			s.Close()
			t.Fatalf("upsert in %s: %v", schema, err)
		}
		hits, err := s.Search(ctx, store.Query{Embedding: []float32{1, 0, 0}, TopK: 3})
		s.Close()
		if err != nil || len(hits) != 1 {
			t.Fatalf("search in %s: %+v %v", schema, hits, err)
		}
	}
	// The extension must not live inside a KB schema (dropping that schema would take it away).
	p, _ := pgxpool.New(ctx, url)
	defer p.Close()
	var ns string
	if err := p.QueryRow(ctx, `SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'vector'`).Scan(&ns); err != nil {
		t.Fatal(err)
	}
	if ns == a || ns == b {
		t.Fatalf("vector extension installed inside KB schema %q", ns)
	}
}

// tempDatabase creates a scratch database (so extension placement can be
// manipulated without disturbing tests running in parallel) and returns its URL.
func tempDatabase(t *testing.T) string {
	t.Helper()
	base := testURL(t)
	ctx := context.Background()
	admin, err := pgxpool.New(ctx, base)
	if err != nil {
		t.Fatal(err)
	}
	name := "kbscratch_" + strings.TrimPrefix(randomSchema(), "kbtest_")
	if _, err := admin.Exec(ctx, `CREATE DATABASE "`+name+`"`); err != nil {
		admin.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = admin.Exec(ctx, `DROP DATABASE IF EXISTS "`+name+`" WITH (FORCE)`)
		admin.Close()
	})
	u, err := url.Parse(base)
	if err != nil {
		t.Fatal(err)
	}
	u.Path = "/" + name
	return u.String()
}

func TestUsesPgvectorAlreadyInstalledInAnotherSchema(t *testing.T) {
	dbURL := tempDatabase(t)
	ctx := context.Background()
	p, err := pgxpool.New(ctx, dbURL)
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	if _, err := p.Exec(ctx, `CREATE SCHEMA ext; CREATE EXTENSION vector WITH SCHEMA ext`); err != nil {
		t.Fatal(err)
	}
	s, err := Open(ctx, Options{URL: dbURL, Schema: "kb", VectorDim: 3})
	if err != nil {
		t.Fatalf("Open with the extension in schema ext: %v", err)
	}
	defer s.Close()
	if err := s.UpsertDocument(ctx, store.Document{Collection: "c", ID: "d", Text: "t"}, []store.Chunk{{Text: "x", Embedding: []float32{0, 1, 0}}}); err != nil {
		t.Fatal(err)
	}
	hits, err := s.Search(ctx, store.Query{Embedding: []float32{0, 1, 0}, TopK: 3})
	if err != nil || len(hits) != 1 {
		t.Fatalf("hits=%+v err=%v", hits, err)
	}
}

// seedFilterScenario fills a big collection whose vectors are all close to the
// query (angles 0..60 degrees from it) and a second one that is far from it
// (70..85 degrees) but still positively similar. Vectors are spread along an
// arc, which keeps the HNSW graph connected as real embeddings do. Both
// collections are large enough that the planner scans the HNSW index for a
// collection-filtered query, as it does in production.
func seedFilterScenario(t *testing.T, s *Store, bigChunks, smallChunks int) {
	t.Helper()
	ctx := context.Background()
	put := func(coll string, n int, from, to float64) {
		if _, err := s.pool.Exec(ctx, `INSERT INTO `+s.schema+`.documents (collection, id, text)
			SELECT $1::text, 'd' || (i / 200)::text, 't' FROM generate_series(0, $2::int - 1) i GROUP BY i / 200`, coll, n); err != nil {
			t.Fatal(err)
		}
		if _, err := s.pool.Exec(ctx, `INSERT INTO `+s.schema+`.chunks (collection, doc_id, idx, text, embedding)
			SELECT $1::text, 'd' || (i / 200)::text, i % 200, $1::text || ' chunk ' || i::text,
			       ('[' || cos(radians($3::float8 + ($4::float8 - $3::float8) * i / $2::float8)) || ',' || sin(radians($3::float8 + ($4::float8 - $3::float8) * i / $2::float8)) || ',' || ((i % 7) * 0.001)::text || ']')::`+s.vecSchema+`.vector
			FROM generate_series(0, $2::int - 1) i`, coll, n, from, to); err != nil {
			t.Fatal(err)
		}
	}
	put("big", bigChunks, 0, 60)
	put("small", smallChunks, 70, 85)
	if _, err := s.pool.Exec(ctx, `ANALYZE `+s.schema+`.chunks`); err != nil {
		t.Fatal(err)
	}
}

func TestFilteredVectorSearchNotUnderReturned(t *testing.T) {
	s, _ := open(t, 3)
	seedFilterScenario(t, s, 15000, 10000)
	ctx := context.Background()
	hits, err := s.Search(ctx, store.Query{Embedding: []float32{1, 0, 0}, Collection: "small", TopK: 5})
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 5 {
		t.Fatalf("got %d hits from the small collection, want 5: %+v", len(hits), hits)
	}
	for _, h := range hits {
		if h.Collection != "small" {
			t.Fatalf("hit from wrong collection: %+v", h)
		}
	}
}

func TestUnavailableSettingDoesNotPoisonTransaction(t *testing.T) {
	s, _ := open(t, 3)
	ctx := context.Background()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if trySet(ctx, tx, `SET LOCAL hnsw.no_such_setting = 1`) {
		t.Fatal("unknown setting reported as applied")
	}
	var one int
	if err := tx.QueryRow(ctx, `SELECT 1`).Scan(&one); err != nil || one != 1 {
		t.Fatalf("transaction unusable after a failed SET: %v", err)
	}
}

var graphTables = []string{"entities", "relations", "entity_chunks", "extraction_jobs", "graph_factsets", "graph_factset_entities"}

func tablesIn(t *testing.T, url, schema string) []string {
	t.Helper()
	pool, err := pgxpool.New(context.Background(), url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	rows, err := pool.Query(context.Background(), `SELECT table_name FROM information_schema.tables WHERE table_schema = $1 ORDER BY 1`, schema)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			t.Fatal(err)
		}
		out = append(out, n)
	}
	return out
}

func migrationsIn(t *testing.T, url, schema string) string {
	t.Helper()
	pool, err := pgxpool.New(context.Background(), url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	var v string
	if err := pool.QueryRow(context.Background(), `SELECT string_agg(version::text, ',' ORDER BY version) FROM "`+schema+`".schema_migrations`).Scan(&v); err != nil {
		t.Fatal(err)
	}
	return v
}

func TestGraphDisabledCreatesNoGraphTable(t *testing.T) {
	url := testURL(t)
	for _, dim := range []int{0, 3} {
		s, schema := openAt(t, url, dim, false)
		got := strings.Join(tablesIn(t, url, schema), ",")
		for _, tbl := range graphTables {
			if strings.Contains(got, tbl) {
				t.Fatalf("dim=%d: graph disabled but table %s exists (tables: %s)", dim, tbl, got)
			}
		}
		if want := map[int]string{0: "1", 3: "1,2"}[dim]; migrationsIn(t, url, schema) != want {
			t.Fatalf("dim=%d: migrations = %s, want %s", dim, migrationsIn(t, url, schema), want)
		}
		ctx := context.Background()
		if _, err := s.UpsertEntity(ctx, store.EntityInput{Collection: "c", Name: "x", Type: "concept"}); !errors.Is(err, store.ErrGraphDisabled) {
			t.Fatalf("UpsertEntity: %v", err)
		}
		if _, err := s.Expand(ctx, store.ExpandQuery{Collection: "c", SeedIDs: []int64{1}}); !errors.Is(err, store.ErrGraphDisabled) {
			t.Fatalf("Expand: %v", err)
		}
		if _, _, err := s.ClaimJob(ctx, time.Second); !errors.Is(err, store.ErrGraphDisabled) {
			t.Fatalf("ClaimJob: %v", err)
		}
		// Plain document operations are unchanged.
		if err := s.UpsertDocument(ctx, store.Document{Collection: "c", ID: "a", Text: "t"}, []store.Chunk{{Text: "hello"}}); err != nil {
			t.Fatal(err)
		}
		if chunks, err := s.DocumentChunks(ctx, "c", "a"); err != nil || len(chunks) != 1 {
			t.Fatalf("chunks=%v err=%v", chunks, err)
		}
		if ok, err := s.DeleteDocument(ctx, "c", "a"); err != nil || !ok {
			t.Fatalf("delete: %v %v", ok, err)
		}
	}
}

func TestGraphMigrationsApplyOnceAndAreIdempotent(t *testing.T) {
	url := testURL(t)
	for _, dim := range []int{0, 3} {
		schema := randomSchema()
		ctx := context.Background()
		for i := 0; i < 3; i++ {
			s, err := Open(ctx, Options{URL: url, Schema: schema, VectorDim: dim, Graph: true})
			if err != nil {
				t.Fatalf("dim=%d open #%d: %v", dim, i, err)
			}
			s.Close()
		}
		t.Cleanup(func() { dropSchema(t, url, schema) })
		got := strings.Join(tablesIn(t, url, schema), ",")
		for _, tbl := range graphTables {
			if !strings.Contains(got, tbl) {
				t.Fatalf("dim=%d: table %s missing (tables: %s)", dim, tbl, got)
			}
		}
		if want := map[int]string{0: "1,3,5,6", 3: "1,2,3,4,5,6"}[dim]; migrationsIn(t, url, schema) != want {
			t.Fatalf("dim=%d: migrations = %s, want %s", dim, migrationsIn(t, url, schema), want)
		}
	}
}

func TestNonGraphDocumentsStillCascadeGraphRows(t *testing.T) {
	// Deleting a document must not leave relations, mentions or jobs behind even
	// when they were written directly (the FKs cascade, not only the Go code).
	url := testURL(t)
	s, schema := openAt(t, url, 0, true)
	ctx := context.Background()
	if err := s.UpsertDocument(ctx, store.Document{Collection: "c", ID: "a", Text: "t"}, []store.Chunk{{Text: "hello"}}); err != nil {
		t.Fatal(err)
	}
	a, _ := s.UpsertEntity(ctx, store.EntityInput{Collection: "c", Name: "A", Type: "concept"})
	b, _ := s.UpsertEntity(ctx, store.EntityInput{Collection: "c", Name: "B", Type: "concept"})
	if _, err := s.AddRelation(ctx, store.Relation{Collection: "c", SrcID: a.ID, DstID: b.ID, Predicate: "x", Evidence: "e", DocumentID: "a"}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SyncExtractionJobs(ctx, "c", "a", "v1", []store.JobSpec{{WindowIdx: 0, WindowHash: "h", ChunkCount: 1}}); err != nil {
		t.Fatal(err)
	}
	pool, _ := pgxpool.New(ctx, url)
	defer pool.Close()
	if _, err := pool.Exec(ctx, `DELETE FROM "`+schema+`".documents`); err != nil {
		t.Fatal(err)
	}
	for _, tbl := range []string{"relations", "entity_chunks", "extraction_jobs"} {
		var n int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM "`+schema+`".`+tbl).Scan(&n); err != nil || n != 0 {
			t.Fatalf("%s: %d rows left (%v)", tbl, n, err)
		}
	}
}

// TestGraphMigration5UpgradesAnOldGraphSchema starts from the schema migrations
// 3 and 4 made (entities unique on type and name, no canon_name) holding what an
// old kb extracted, and checks what migration 5 does: extracted rows and jobs are
// cleared once, manual rows survive with a canonical name, the merge key becomes
// (collection, canon_name), and a second start changes nothing.
func TestGraphMigration5UpgradesAnOldGraphSchema(t *testing.T) {
	url := testURL(t)
	ctx := context.Background()
	s, schema := openAt(t, url, 0, true)
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := s.pool.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
	}
	q := `"` + schema + `".`
	// back to the schema of migration 3
	exec(`DROP INDEX ` + q + `entities_canon_name_key`)
	exec(`ALTER TABLE ` + q + `entities DROP COLUMN canon_name, DROP COLUMN other_types`)
	exec(`ALTER TABLE ` + q + `entities ADD CONSTRAINT entities_collection_type_norm_name_key UNIQUE (collection, type, norm_name)`)
	exec(`DELETE FROM ` + q + `schema_migrations WHERE version = 5`)
	exec(`INSERT INTO ` + q + `documents (collection, id, text) VALUES ('c', 'd1', 'x')`)
	ent := func(name, typ, origin string) {
		exec(`INSERT INTO `+q+`entities (collection, name, norm_name, match_name, type, origin) VALUES ('c', $1, lower($1), lower($1), $2, $3)`, name, typ, origin)
	}
	ent("Basalt", "team", "extracted")
	ent("Team Basalt", "team", "extracted")
	ent("Orion", "service", "extracted")
	ent("Team Manual", "team", "manual")
	ent("Kept Peer", "team", "extracted") // referenced by a manual relation below
	exec(`INSERT INTO ` + q + `relations (collection, src_id, dst_id, predicate, document_id, chunk_index, origin)
	      SELECT 'c', a.id, b.id, 'owns', 'd1', 0, 'extracted' FROM ` + q + `entities a, ` + q + `entities b WHERE a.name = 'Basalt' AND b.name = 'Orion'`)
	exec(`INSERT INTO ` + q + `relations (collection, src_id, dst_id, predicate, document_id, chunk_index, origin)
	      SELECT 'c', a.id, b.id, 'peer_of', 'd1', 0, 'manual' FROM ` + q + `entities a, ` + q + `entities b WHERE a.name = 'Team Manual' AND b.name = 'Kept Peer'`)
	exec(`INSERT INTO ` + q + `entity_chunks (entity_id, collection, document_id, chunk_index) SELECT id, 'c', 'd1', 0 FROM ` + q + `entities WHERE name = 'Orion'`)
	exec(`INSERT INTO ` + q + `extraction_jobs (collection, document_id, window_idx, window_hash, first_chunk, chunk_count, prompt_version, state)
	      VALUES ('c', 'd1', 0, 'h', 0, 1, 'v1', 'done')`)
	s.Close()

	for i := 0; i < 2; i++ { // the second start must not clear again
		s2, err := Open(ctx, Options{URL: url, Schema: schema, Graph: true})
		if err != nil {
			t.Fatalf("reopen #%d: %v", i, err)
		}
		st, err := s2.GraphStats(ctx, "c")
		if err != nil {
			t.Fatal(err)
		}
		if st.Entities != 2+i || st.Relations != 1 || st.Mentions != 0 || st.JobsDone+st.JobsPending+st.JobsFailed != 0 {
			t.Fatalf("start #%d: stats after the upgrade = %+v, want only the manual relation and its two entities (plus what was extracted since)", i, st)
		}
		if i == 0 { // new extractions after the upgrade survive the next start
			e, err := s2.UpsertEntity(ctx, store.EntityInput{Collection: "c", Name: "Team Basalt", Type: "team"})
			if err != nil {
				t.Fatal(err)
			}
			e2, _ := s2.UpsertEntity(ctx, store.EntityInput{Collection: "c", Name: "Basalt", Type: "service"})
			if e.ID != e2.ID || e2.Name != "Team Basalt" || len(e2.OtherTypes) != 1 {
				t.Fatalf("merge after the upgrade: %+v %+v", e, e2)
			}
			m, err := s2.UpsertEntity(ctx, store.EntityInput{Collection: "c", Name: "Manual", Type: "team"})
			if err != nil || m.Name != "Team Manual" || m.Origin != "manual" {
				t.Fatalf("manual entity canonical name backfilled: %+v %v", m, err)
			}
		}
		s2.Close()
	}
}

// TestGraphMigration6UpgradesASchemaOfMigration5 starts from the schema
// migration 5 left (relations always cite a document, no fact set tables) with
// extracted and manual rows, and checks that migration 6 keeps every row,
// allows relations that cite a fact set, refuses one that cites nothing, still
// cascades document relations, and that a second start changes nothing.
func TestGraphMigration6UpgradesASchemaOfMigration5(t *testing.T) {
	url := testURL(t)
	ctx := context.Background()
	s, schema := openAt(t, url, 0, true)
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := s.pool.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
	}
	q := `"` + schema + `".`
	// back to the schema of migration 5
	exec(`DROP TABLE ` + q + `graph_factset_entities`)
	exec(`ALTER TABLE ` + q + `relations DROP CONSTRAINT relations_factset_fk, DROP CONSTRAINT relations_one_source`)
	exec(`DROP INDEX ` + q + `relations_factset_key`)
	exec(`DROP INDEX ` + q + `relations_factset_idx`)
	exec(`ALTER TABLE ` + q + `relations DROP COLUMN factset_id`)
	exec(`ALTER TABLE ` + q + `relations ALTER COLUMN document_id SET NOT NULL, ALTER COLUMN chunk_index SET NOT NULL`)
	exec(`DROP TABLE ` + q + `graph_factsets`)
	exec(`DELETE FROM ` + q + `schema_migrations WHERE version = 6`)
	exec(`INSERT INTO ` + q + `documents (collection, id, text) VALUES ('c', 'd1', 'x')`)
	for _, n := range []string{"Basalt", "Orion", "Teal"} {
		exec(`INSERT INTO `+q+`entities (collection, name, norm_name, match_name, canon_name, type, origin) VALUES ('c', $1, lower($1), lower($1), lower($1), 'team', 'extracted')`, n)
	}
	exec(`INSERT INTO ` + q + `relations (collection, src_id, dst_id, predicate, document_id, chunk_index, origin)
	      SELECT 'c', a.id, b.id, 'owns', 'd1', 0, 'extracted' FROM ` + q + `entities a, ` + q + `entities b WHERE a.name = 'Basalt' AND b.name = 'Orion'`)
	exec(`INSERT INTO ` + q + `relations (collection, src_id, dst_id, predicate, document_id, chunk_index, origin)
	      SELECT 'c', a.id, b.id, 'peer_of', 'd1', 0, 'manual' FROM ` + q + `entities a, ` + q + `entities b WHERE a.name = 'Orion' AND b.name = 'Teal'`)
	s.Close()

	s2, err := Open(ctx, Options{URL: url, Schema: schema, Graph: true})
	if err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	st, err := s2.GraphStats(ctx, "c")
	if err != nil || st.Entities != 3 || st.Relations != 2 || st.ManualRelations != 1 || st.FactSets != 0 {
		t.Fatalf("after the upgrade: %+v %v", st, err)
	}
	fs := store.FactSet{Collection: "c", ID: "org", Entities: []store.FactEntity{{Name: "Teal", Type: "team"}, {Name: "Quartz", Type: "service"}},
		Relations: []store.FactRelation{{Source: "Teal", Predicate: "owns", Target: "Quartz"}}}
	if changed, err := s2.ReplaceFactSet(ctx, fs); err != nil || !changed {
		t.Fatalf("replace on the upgraded schema: %v %v", changed, err)
	}
	hits, _ := s2.FindEntitiesByName(ctx, "c", "Teal", 1)
	ps, err := s2.Expand(ctx, store.ExpandQuery{Collection: "c", SeedIDs: []int64{hits[0].Entity.ID}, Hops: 1})
	if err != nil || len(ps) != 2 {
		t.Fatalf("expand (old manual document relation and the curated one): %v %v", ps, err)
	}
	var lo, hi int64
	if err := s2.pool.QueryRow(ctx, `SELECT min(id), max(id) FROM `+q+`entities`).Scan(&lo, &hi); err != nil {
		t.Fatal(err)
	}
	if _, err := s2.pool.Exec(ctx, `INSERT INTO `+q+`relations (collection, src_id, dst_id, predicate) VALUES ('c', $1, $2, 'x')`, lo, hi); err == nil {
		t.Fatal("a relation that cites neither a document nor a fact set was accepted")
	}
	if _, err := s2.pool.Exec(ctx, `INSERT INTO `+q+`relations (collection, src_id, dst_id, predicate, document_id, chunk_index, factset_id) VALUES ('c', $1, $2, 'x', 'd1', 0, 'org')`, lo, hi); err == nil {
		t.Fatal("a relation that cites both was accepted")
	}
	if ok, err := s2.DeleteDocument(ctx, "c", "d1"); err != nil || !ok {
		t.Fatalf("delete document: %v %v", ok, err)
	}
	if st, _ := s2.GraphStats(ctx, "c"); st.Relations != 1 || st.ManualRelations != 1 || st.FactSets != 1 {
		t.Fatalf("document relations must cascade and the curated one stay: %+v", st)
	}
	s2.Close()

	s3, err := Open(ctx, Options{URL: url, Schema: schema, Graph: true})
	if err != nil {
		t.Fatalf("second start: %v", err)
	}
	defer s3.Close()
	if st, _ := s3.GraphStats(ctx, "c"); st.FactSets != 1 || st.ManualRelations != 1 || st.Relations != 1 {
		t.Fatalf("a restart changed the fact set: %+v", st)
	}
	if got := migrationsIn(t, url, schema); got != "1,3,5,6" {
		t.Fatalf("migrations = %s", got)
	}
}

// TestGraphSchemasAreOffUnlessAsked: without Options.GraphSchemas no table is made, migration 7 is not recorded, the schema methods say so, and a fact set
// load, a document load and an extraction behave as before.
func TestGraphSchemasAreOffUnlessAsked(t *testing.T) {
	url := testURL(t)
	ctx := context.Background()
	s, schema := openAt(t, url, 0, true)
	if _, err := s.GetGraphSchema(ctx, "c"); !errors.Is(err, store.ErrSchemasDisabled) {
		t.Fatalf("%v", err)
	}
	if _, err := s.PutGraphSchema(ctx, "c", store.GraphSchema{Version: 1}, []byte("{}"), "x"); !errors.Is(err, store.ErrSchemasDisabled) {
		t.Fatalf("%v", err)
	}
	var n int
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM information_schema.tables WHERE table_schema = $1 AND table_name = 'graph_schemas'`, schema).Scan(&n); err != nil || n != 0 {
		t.Fatalf("the table must not exist: n=%d err=%v", n, err)
	}
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM "`+schema+`".schema_migrations WHERE version = 7`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("migration 7 must not be recorded: n=%d err=%v", n, err)
	}
	fs := store.FactSet{Collection: "c", ID: "org", Entities: []store.FactEntity{{Name: "Basalt", Type: "team"}}}
	if _, err := s.ReplaceFactSet(ctx, fs); err != nil {
		t.Fatalf("a fact set loads as before: %v", err)
	}
	if _, _, err := s.ClaimJob(ctx, time.Minute); err != nil {
		t.Fatalf("%v", err)
	}
}

// TestGraphSchemasMigrationIsIdempotent: opening a store with schemas twice leaves one table and one row of migration 7, and keeps a stored schema.
func TestGraphSchemasMigrationIsIdempotent(t *testing.T) {
	url := testURL(t)
	ctx := context.Background()
	s, schema := openWith(t, url, 0, true, true)
	g := store.GraphSchema{Version: 1, EntityTypes: []store.SchemaEntityType{{Name: "team"}}}
	if _, err := s.PutGraphSchema(ctx, "c", g, []byte(`{"version":1}`), "sha1"); err != nil {
		t.Fatal(err)
	}
	s.Close()
	s2, err := Open(ctx, Options{URL: url, Schema: schema, Graph: true, GraphSchemas: true})
	if err != nil {
		t.Fatalf("second start: %v", err)
	}
	defer s2.Close()
	got, err := s2.GetGraphSchema(ctx, "c")
	if err != nil || got.SHA256 != "sha1" || got.Version != 1 {
		t.Fatalf("the stored schema must survive a restart: %+v %v", got, err)
	}
	var n int
	if err := s2.pool.QueryRow(ctx, `SELECT count(*) FROM "`+schema+`".schema_migrations WHERE version = 7`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("migration 7: n=%d err=%v", n, err)
	}
}
