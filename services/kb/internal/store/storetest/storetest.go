// Package storetest is a conformance suite every store.Store backend must pass.
package storetest

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/openagentix/openagentix/services/kb/internal/store"
)

// Factory builds a fresh, empty store for one test. Vectors reports whether the
// store accepts embeddings of dimension Dim.
type Factory struct {
	New     func(t *testing.T) store.Store
	Vectors bool
	Dim     int
	// Graph reports that the stores support the knowledge-graph methods.
	Graph bool
}

func ch(texts ...string) []store.Chunk {
	out := make([]store.Chunk, len(texts))
	for i, s := range texts {
		out[i] = store.Chunk{Text: s}
	}
	return out
}

func doc(coll, id, title string) store.Document {
	return store.Document{Collection: coll, ID: id, Title: title, SourceURI: "https://example.test/" + id, Text: "full text of " + id}
}

// Run executes the suite.
func Run(t *testing.T, f Factory) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	run := func(name string, fn func(t *testing.T, s store.Store)) {
		t.Run(name, func(t *testing.T) {
			s := f.New(t)
			t.Cleanup(s.Close)
			fn(t, s)
		})
	}

	run("ping", func(t *testing.T, s store.Store) {
		if err := s.Ping(ctx); err != nil {
			t.Fatal(err)
		}
	})

	run("upsert and get", func(t *testing.T, s store.Store) {
		d := doc("docs", "a", "Doc A")
		if err := s.UpsertDocument(ctx, d, ch("hello world")); err != nil {
			t.Fatal(err)
		}
		got, err := s.GetDocument(ctx, "docs", "a")
		if err != nil {
			t.Fatal(err)
		}
		if got.Title != "Doc A" || got.SourceURI != d.SourceURI || got.Text != d.Text || got.Collection != "docs" || got.ID != "a" {
			t.Fatalf("got %+v", got)
		}
		if got.UpdatedAt.IsZero() {
			t.Fatal("UpdatedAt not set")
		}
	})

	run("get missing", func(t *testing.T, s store.Store) {
		if _, err := s.GetDocument(ctx, "docs", "nope"); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("err = %v", err)
		}
	})

	run("get without collection", func(t *testing.T, s store.Store) {
		_ = s.UpsertDocument(ctx, doc("one", "solo", "Solo"), ch("x"))
		_ = s.UpsertDocument(ctx, doc("one", "dup", "Dup1"), ch("x"))
		_ = s.UpsertDocument(ctx, doc("two", "dup", "Dup2"), ch("x"))
		got, err := s.GetDocument(ctx, "", "solo")
		if err != nil || got.Collection != "one" {
			t.Fatalf("got %+v, %v", got, err)
		}
		if _, err := s.GetDocument(ctx, "", "dup"); !errors.Is(err, store.ErrAmbiguous) {
			t.Fatalf("err = %v, want ErrAmbiguous", err)
		}
		if _, err := s.GetDocument(ctx, "", "missing"); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("err = %v, want ErrNotFound", err)
		}
	})

	run("upsert replaces chunks idempotently", func(t *testing.T, s store.Store) {
		d := doc("docs", "a", "Old")
		_ = s.UpsertDocument(ctx, d, ch("zebra stripes"))
		d.Title = "New"
		for i := 0; i < 2; i++ {
			if err := s.UpsertDocument(ctx, d, ch("giraffe necks", "okapi forest")); err != nil {
				t.Fatal(err)
			}
		}
		hits, _ := s.Search(ctx, store.Query{Text: "zebra", TopK: 5})
		if len(hits) != 0 {
			t.Fatalf("old chunk still searchable: %+v", hits)
		}
		hits, _ = s.Search(ctx, store.Query{Text: "giraffe", TopK: 5})
		if len(hits) != 1 || hits[0].Title != "New" {
			t.Fatalf("hits = %+v", hits)
		}
		cols, _ := s.ListCollections(ctx)
		if len(cols) != 1 || cols[0].Documents != 1 {
			t.Fatalf("cols = %+v", cols)
		}
	})

	run("delete", func(t *testing.T, s store.Store) {
		_ = s.UpsertDocument(ctx, doc("docs", "a", "A"), ch("walrus tusks"))
		ok, err := s.DeleteDocument(ctx, "docs", "a")
		if err != nil || !ok {
			t.Fatalf("ok=%v err=%v", ok, err)
		}
		ok, err = s.DeleteDocument(ctx, "docs", "a")
		if err != nil || ok {
			t.Fatalf("second delete ok=%v err=%v", ok, err)
		}
		if hits, _ := s.Search(ctx, store.Query{Text: "walrus", TopK: 5}); len(hits) != 0 {
			t.Fatalf("deleted doc searchable: %+v", hits)
		}
		if cols, _ := s.ListCollections(ctx); len(cols) != 0 {
			t.Fatalf("empty collection listed: %+v", cols)
		}
	})

	run("list collections sorted with counts", func(t *testing.T, s store.Store) {
		_ = s.UpsertDocument(ctx, doc("zeta", "1", "t"), ch("a"))
		_ = s.UpsertDocument(ctx, doc("alpha", "1", "t"), ch("a"))
		_ = s.UpsertDocument(ctx, doc("alpha", "2", "t"), ch("a"))
		cols, err := s.ListCollections(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if len(cols) != 2 || cols[0] != (store.CollectionInfo{Name: "alpha", Documents: 2}) || cols[1] != (store.CollectionInfo{Name: "zeta", Documents: 1}) {
			t.Fatalf("cols = %+v", cols)
		}
	})

	// A Scope limits every read to a list of collections inside the query itself (ADR 0030).
	scoped := func(cs ...string) store.Scope { return store.Scope{Limited: true, Collections: cs} }
	seedScope := func(s store.Store) {
		_ = s.UpsertDocument(ctx, doc("mine", "m1", "Mine one"), ch("pelican harbour notes"))
		_ = s.UpsertDocument(ctx, doc("mine", "dup", "Mine dup"), ch("harbour dup text"))
		_ = s.UpsertDocument(ctx, doc("theirs", "t1", "Theirs one"), ch("pelican pelican pelican harbour"))
		_ = s.UpsertDocument(ctx, doc("theirs", "dup", "Theirs dup"), ch("harbour dup text"))
	}

	run("scope limits search inside the query", func(t *testing.T, s store.Store) {
		seedScope(s)
		// The other collection ranks better; top_k must still be filled from the allowed one.
		hits, err := s.Search(ctx, store.Query{Text: "pelican", TopK: 1, Scope: scoped("mine")})
		if err != nil || len(hits) != 1 || hits[0].Collection != "mine" {
			t.Fatalf("hits=%+v err=%v", hits, err)
		}
		hits, _ = s.Search(ctx, store.Query{Text: "harbour", TopK: 10, Scope: scoped("mine")})
		for _, h := range hits {
			if h.Collection != "mine" {
				t.Fatalf("leaked %+v", h)
			}
		}
		// A named collection outside the list answers like a missing one.
		out, _ := s.Search(ctx, store.Query{Text: "pelican", Collection: "theirs", TopK: 5, Scope: scoped("mine")})
		missing, _ := s.Search(ctx, store.Query{Text: "pelican", Collection: "nope", TopK: 5, Scope: scoped("mine")})
		if len(out) != 0 || len(missing) != 0 {
			t.Fatalf("outside=%+v missing=%+v", out, missing)
		}
		// Limited with an empty list reads nothing.
		if hits, _ := s.Search(ctx, store.Query{Text: "pelican", TopK: 5, Scope: scoped()}); len(hits) != 0 {
			t.Fatalf("empty list read %+v", hits)
		}
		// The zero scope is no limit.
		if hits, _ := s.Search(ctx, store.Query{Text: "pelican", TopK: 5}); len(hits) != 2 {
			t.Fatalf("unscoped hits=%+v", hits)
		}
	})

	run("scope limits list and get", func(t *testing.T, s store.Store) {
		seedScope(s)
		cols, err := s.ListCollectionsIn(ctx, scoped("mine", "absent"))
		if err != nil || len(cols) != 1 || cols[0] != (store.CollectionInfo{Name: "mine", Documents: 2}) {
			t.Fatalf("cols=%+v err=%v", cols, err)
		}
		if cols, _ := s.ListCollectionsIn(ctx, scoped()); len(cols) != 0 {
			t.Fatalf("empty list listed %+v", cols)
		}
		if _, err := s.GetDocumentIn(ctx, scoped("mine"), "theirs", "t1"); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("outside collection: %v", err)
		}
		if _, err := s.GetDocumentIn(ctx, scoped("mine"), "", "t1"); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("outside id, no collection: %v", err)
		}
		if _, err := s.GetDocumentIn(ctx, scoped("mine"), "nope", "t1"); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("missing collection: %v", err)
		}
		// "dup" is in two collections, but only one is allowed: it is not ambiguous.
		d, err := s.GetDocumentIn(ctx, scoped("mine"), "", "dup")
		if err != nil || d.Collection != "mine" {
			t.Fatalf("d=%+v err=%v", d, err)
		}
		if _, err := s.GetDocumentIn(ctx, scoped("mine", "theirs"), "", "dup"); !errors.Is(err, store.ErrAmbiguous) {
			t.Fatalf("both allowed: %v", err)
		}
		if d, err := s.GetDocumentIn(ctx, store.Scope{}, "theirs", "t1"); err != nil || d.ID != "t1" {
			t.Fatalf("zero scope: d=%+v err=%v", d, err)
		}
	})

	run("lexical ranking", func(t *testing.T, s store.Store) {
		_ = s.UpsertDocument(ctx, doc("docs", "both", "Both"), ch("kubernetes ingress controller routes traffic"))
		_ = s.UpsertDocument(ctx, doc("docs", "one", "One"), ch("kubernetes schedules pods onto nodes"))
		_ = s.UpsertDocument(ctx, doc("docs", "none", "None"), ch("bananas are yellow"))
		hits, err := s.Search(ctx, store.Query{Text: "kubernetes ingress", TopK: 10})
		if err != nil {
			t.Fatal(err)
		}
		if len(hits) != 2 || hits[0].DocumentID != "both" || hits[1].DocumentID != "one" {
			t.Fatalf("hits = %+v", hits)
		}
		if hits[0].Score <= hits[1].Score || hits[0].Score <= 0 {
			t.Fatalf("scores not descending/positive: %v %v", hits[0].Score, hits[1].Score)
		}
		h := hits[0]
		if h.Collection != "docs" || h.Title != "Both" || h.SourceURI == "" || h.Text == "" || h.ChunkIndex != 0 {
			t.Fatalf("hit fields: %+v", h)
		}
	})

	run("chunk index reported", func(t *testing.T, s store.Store) {
		_ = s.UpsertDocument(ctx, doc("docs", "a", "A"), ch("filler text", "needle in second chunk"))
		hits, _ := s.Search(ctx, store.Query{Text: "needle", TopK: 5})
		if len(hits) != 1 || hits[0].ChunkIndex != 1 {
			t.Fatalf("hits = %+v", hits)
		}
	})

	run("collection filter and topK", func(t *testing.T, s store.Store) {
		for _, id := range []string{"1", "2", "3"} {
			_ = s.UpsertDocument(ctx, doc("a", id, "t"), ch("shared term here"))
		}
		_ = s.UpsertDocument(ctx, doc("b", "1", "t"), ch("shared term here"))
		hits, _ := s.Search(ctx, store.Query{Text: "shared", Collection: "b", TopK: 10})
		if len(hits) != 1 || hits[0].Collection != "b" {
			t.Fatalf("filter: %+v", hits)
		}
		hits, _ = s.Search(ctx, store.Query{Text: "shared", TopK: 2})
		if len(hits) != 2 {
			t.Fatalf("topK: %+v", hits)
		}
	})

	run("empty and punctuation-only queries", func(t *testing.T, s store.Store) {
		_ = s.UpsertDocument(ctx, doc("docs", "a", "A"), ch("something"))
		for _, q := range []string{"", "   ", "!!! ???"} {
			hits, err := s.Search(ctx, store.Query{Text: q, TopK: 5})
			if err != nil || len(hits) != 0 {
				t.Fatalf("q=%q hits=%+v err=%v", q, hits, err)
			}
		}
	})

	run("negative-only queries return nothing", func(t *testing.T, s store.Store) {
		_ = s.UpsertDocument(ctx, doc("docs", "a", "A"), ch("foo apple"))
		_ = s.UpsertDocument(ctx, doc("docs", "b", "B"), ch("banana split"))
		for _, q := range []string{"-foo", "-foo -banana", "-foo or -banana"} {
			hits, err := s.Search(ctx, store.Query{Text: q, TopK: 5})
			if err != nil || len(hits) != 0 {
				t.Fatalf("q=%q hits=%+v err=%v", q, hits, err)
			}
		}
	})

	run("negated term excludes matching chunks", func(t *testing.T, s store.Store) {
		_ = s.UpsertDocument(ctx, doc("docs", "a", "A"), ch("apple pie recipe"))
		_ = s.UpsertDocument(ctx, doc("docs", "b", "B"), ch("apple tart with cinnamon"))
		hits, err := s.Search(ctx, store.Query{Text: "apple -cinnamon", TopK: 5})
		if err != nil || len(hits) != 1 || hits[0].DocumentID != "a" {
			t.Fatalf("hits=%+v err=%v", hits, err)
		}
	})

	run("hostile query text is safe", func(t *testing.T, s store.Store) {
		_ = s.UpsertDocument(ctx, doc("docs", "a", "A"), ch("something"))
		for _, q := range []string{"'; DROP TABLE x; --", "a & | ! ( ) :*", `"unterminated`} {
			if _, err := s.Search(ctx, store.Query{Text: q, TopK: 5}); err != nil {
				t.Fatalf("q=%q err=%v", q, err)
			}
		}
	})

	run("concurrent upserts of one document leave one consistent version", func(t *testing.T, s store.Store) {
		const writers = 12
		var wg sync.WaitGroup
		errs := make(chan error, writers)
		for v := 0; v < writers; v++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				chunks := make([]string, 2+v%4)
				for i := range chunks {
					chunks[i] = fmt.Sprintf("chunk ver%d part%d", v, i)
				}
				d := doc("docs", "same", fmt.Sprintf("ver%d", v))
				d.Text = fmt.Sprintf("text of ver%d", v)
				errs <- s.UpsertDocument(ctx, d, ch(chunks...))
			}()
		}
		wg.Wait()
		close(errs)
		for err := range errs {
			if err != nil {
				t.Fatalf("concurrent upsert failed: %v", err)
			}
		}
		got, err := s.GetDocument(ctx, "docs", "same")
		if err != nil {
			t.Fatal(err)
		}
		var v int
		if _, err := fmt.Sscanf(got.Title, "ver%d", &v); err != nil || got.Text != fmt.Sprintf("text of ver%d", v) {
			t.Fatalf("document fields from different versions: %+v", got)
		}
		hits, err := s.Search(ctx, store.Query{Text: "chunk", TopK: 20})
		if err != nil {
			t.Fatal(err)
		}
		if want := 2 + v%4; len(hits) != want {
			t.Fatalf("got %d chunks, want %d (mixed or leftover chunks): %+v", len(hits), want, hits)
		}
		for _, h := range hits {
			if !strings.HasPrefix(h.Text, fmt.Sprintf("chunk ver%d ", v)) {
				t.Fatalf("chunk from another version: %+v (document is ver%d)", h, v)
			}
		}
	})

	run("upsert racing delete leaves no orphan chunks", func(t *testing.T, s store.Store) {
		for round := 0; round < 20; round++ {
			var wg sync.WaitGroup
			errs := make(chan error, 4)
			for i := 0; i < 2; i++ {
				wg.Add(2)
				go func() {
					defer wg.Done()
					errs <- s.UpsertDocument(ctx, doc("docs", "racy", "R"), ch("orphan candidate one", "orphan candidate two"))
				}()
				go func() {
					defer wg.Done()
					_, err := s.DeleteDocument(ctx, "docs", "racy")
					errs <- err
				}()
			}
			wg.Wait()
			close(errs)
			for err := range errs {
				if err != nil {
					t.Fatalf("round %d: %v", round, err)
				}
			}
			_, getErr := s.GetDocument(ctx, "docs", "racy")
			hits, err := s.Search(ctx, store.Query{Text: "orphan", TopK: 20})
			if err != nil {
				t.Fatal(err)
			}
			switch {
			case errors.Is(getErr, store.ErrNotFound) && len(hits) != 0:
				t.Fatalf("round %d: document gone but %d chunks still searchable", round, len(hits))
			case getErr == nil && len(hits) != 2:
				t.Fatalf("round %d: document present with %d chunks, want 2", round, len(hits))
			case getErr != nil && !errors.Is(getErr, store.ErrNotFound):
				t.Fatal(getErr)
			}
			if _, err := s.DeleteDocument(ctx, "docs", "racy"); err != nil {
				t.Fatal(err)
			}
		}
	})

	if f.Graph {
		runGraph(t, f, run)
	}
	if !f.Vectors {
		return
	}
	vec := func(x, y, z float32) []float32 { return []float32{x, y, z} }
	if f.Dim != 3 {
		t.Fatalf("suite requires Dim == 3, got %d", f.Dim)
	}

	run("vector search ranks by similarity", func(t *testing.T, s store.Store) {
		_ = s.UpsertDocument(ctx, doc("docs", "x", "X"), []store.Chunk{{Text: "alpha", Embedding: vec(1, 0, 0)}})
		_ = s.UpsertDocument(ctx, doc("docs", "y", "Y"), []store.Chunk{{Text: "beta", Embedding: vec(0, 1, 0)}})
		hits, err := s.Search(ctx, store.Query{Text: "", Embedding: vec(0.1, 0.9, 0), TopK: 5})
		if err != nil {
			t.Fatal(err)
		}
		if len(hits) == 0 || hits[0].DocumentID != "y" {
			t.Fatalf("hits = %+v", hits)
		}
	})

	run("hybrid fuses lexical and vector", func(t *testing.T, s store.Store) {
		// "lex" matches the text only; "vec" matches the embedding only; "both" matches both.
		_ = s.UpsertDocument(ctx, doc("docs", "lex", "L"), []store.Chunk{{Text: "quasar pulsar", Embedding: vec(0, 0, 1)}})
		_ = s.UpsertDocument(ctx, doc("docs", "vec", "V"), []store.Chunk{{Text: "unrelated words", Embedding: vec(1, 0, 0)}})
		_ = s.UpsertDocument(ctx, doc("docs", "both", "B"), []store.Chunk{{Text: "quasar nebula", Embedding: vec(1, 0.1, 0)}})
		hits, err := s.Search(ctx, store.Query{Text: "quasar", Embedding: vec(1, 0, 0), TopK: 5})
		if err != nil {
			t.Fatal(err)
		}
		if len(hits) != 3 || hits[0].DocumentID != "both" {
			t.Fatalf("hits = %+v", hits)
		}
	})

	run("collection filter applies to vector and hybrid search", func(t *testing.T, s store.Store) {
		_ = s.UpsertDocument(ctx, doc("near", "n", "N"), []store.Chunk{{Text: "quasar close", Embedding: vec(1, 0, 0)}})
		_ = s.UpsertDocument(ctx, doc("far", "f", "F"), []store.Chunk{{Text: "quasar distant", Embedding: vec(0.5, 0.5, 0.5)}})
		q := vec(1, 0, 0)
		hits, err := s.Search(ctx, store.Query{Embedding: q, Collection: "far", TopK: 5})
		if err != nil || len(hits) != 1 || hits[0].Collection != "far" {
			t.Fatalf("vector-only: hits=%+v err=%v", hits, err)
		}
		hits, err = s.Search(ctx, store.Query{Text: "quasar", Embedding: q, Collection: "far", TopK: 5})
		if err != nil || len(hits) != 1 || hits[0].Collection != "far" {
			t.Fatalf("hybrid: hits=%+v err=%v", hits, err)
		}
		hits, err = s.Search(ctx, store.Query{Text: "quasar", Embedding: q, TopK: 5})
		if err != nil || len(hits) != 2 {
			t.Fatalf("unfiltered hybrid: hits=%+v err=%v", hits, err)
		}
	})

	run("scope applies to vector and hybrid search with top_k filled", func(t *testing.T, s store.Store) {
		// Twenty near chunks in the refused collection, one far chunk in the allowed one.
		for i := 0; i < 20; i++ {
			_ = s.UpsertDocument(ctx, doc("refused", fmt.Sprintf("r%d", i), "R"), []store.Chunk{{Text: "quasar close", Embedding: vec(1, 0, 0)}})
		}
		_ = s.UpsertDocument(ctx, doc("allowed", "a", "A"), []store.Chunk{{Text: "quasar distant", Embedding: vec(0.2, 0.9, 0.1)}})
		q := vec(1, 0, 0)
		sc := store.Scope{Limited: true, Collections: []string{"allowed"}}
		hits, err := s.Search(ctx, store.Query{Embedding: q, TopK: 1, Scope: sc})
		if err != nil || len(hits) != 1 || hits[0].Collection != "allowed" {
			t.Fatalf("vector: hits=%+v err=%v", hits, err)
		}
		hits, err = s.Search(ctx, store.Query{Text: "quasar", Embedding: q, TopK: 1, Scope: sc})
		if err != nil || len(hits) != 1 || hits[0].Collection != "allowed" {
			t.Fatalf("hybrid: hits=%+v err=%v", hits, err)
		}
	})

	run("wrong embedding dimension is rejected", func(t *testing.T, s store.Store) {
		err := s.UpsertDocument(ctx, doc("docs", "a", "A"), []store.Chunk{{Text: "x", Embedding: []float32{1, 2}}})
		if err == nil {
			t.Fatal("expected error for bad dimension")
		}
	})
}
