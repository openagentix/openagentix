// Package memory is an in-process store.Store: BM25 lexical ranking, cosine
// similarity for vectors, reciprocal rank fusion when both are available. It is
// the zero-dependency dev mode and the reference implementation for tests.
package memory

import (
	"context"
	"fmt"
	"math"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/openagentix/openagentix/services/kb/internal/store"
)

const (
	bm25K1 = 1.2
	bm25B  = 0.75
	rrfK   = 60
)

type key struct{ collection, id string }

type storedChunk struct {
	text      string
	tokens    map[string]int
	length    int
	embedding []float32
}

type entry struct {
	doc    store.Document
	chunks []storedChunk
}

// Store is safe for concurrent use.
type Store struct {
	dim int
	mu  sync.RWMutex
	m   map[key]*entry
	g   graph
}

// New returns an empty store. dim > 0 makes it reject embeddings of any other
// length; dim == 0 accepts any length.
func New(dim int) *Store { return &Store{dim: dim, m: map[key]*entry{}, g: newGraph()} }

func tokenize(s string) []string {
	return strings.FieldsFunc(strings.ToLower(s), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	})
}

func (s *Store) UpsertDocument(_ context.Context, doc store.Document, chunks []store.Chunk) error {
	sc := make([]storedChunk, len(chunks))
	for i, c := range chunks {
		if c.Embedding != nil && s.dim > 0 && len(c.Embedding) != s.dim {
			return fmt.Errorf("chunk %d: embedding has dimension %d, store expects %d", i, len(c.Embedding), s.dim)
		}
		toks := tokenize(c.Text)
		tf := make(map[string]int, len(toks))
		for _, t := range toks {
			tf[t]++
		}
		sc[i] = storedChunk{text: c.Text, tokens: tf, length: len(toks), embedding: append([]float32(nil), c.Embedding...)}
	}
	doc.UpdatedAt = time.Now().UTC()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.m[key{doc.Collection, doc.ID}] = &entry{doc: doc, chunks: sc}
	return nil
}

func (s *Store) DeleteDocument(_ context.Context, collection, id string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	k := key{collection, id}
	_, ok := s.m[k]
	delete(s.m, k)
	if ok {
		s.dropDocGraphLocked(collection, id)
	}
	return ok, nil
}

func (s *Store) GetDocument(ctx context.Context, collection, id string) (store.Document, error) {
	return s.GetDocumentIn(ctx, store.Scope{}, collection, id)
}

func (s *Store) GetDocumentIn(_ context.Context, scope store.Scope, collection, id string) (store.Document, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if collection != "" {
		if !scope.Allows(collection) {
			return store.Document{}, store.ErrNotFound
		}
		e, ok := s.m[key{collection, id}]
		if !ok {
			return store.Document{}, store.ErrNotFound
		}
		return e.doc, nil
	}
	var found *entry
	for k, e := range s.m {
		if k.id != id || !scope.Allows(k.collection) {
			continue
		}
		if found != nil {
			return store.Document{}, store.ErrAmbiguous
		}
		found = e
	}
	if found == nil {
		return store.Document{}, store.ErrNotFound
	}
	return found.doc, nil
}

func (s *Store) ListCollections(ctx context.Context) ([]store.CollectionInfo, error) {
	return s.ListCollectionsIn(ctx, store.Scope{})
}

func (s *Store) ListCollectionsIn(_ context.Context, scope store.Scope) ([]store.CollectionInfo, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	counts := map[string]int{}
	for k := range s.m {
		if !scope.Allows(k.collection) {
			continue
		}
		counts[k.collection]++
	}
	out := make([]store.CollectionInfo, 0, len(counts))
	for n, c := range counts {
		out = append(out, store.CollectionInfo{Name: n, Documents: c})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

func (s *Store) Ping(context.Context) error { return nil }
func (s *Store) Close()                     {}

type cand struct {
	e   *entry
	idx int
}

func (s *Store) Search(_ context.Context, q store.Query) ([]store.Hit, error) {
	if q.TopK <= 0 {
		return nil, nil
	}
	s.mu.RLock()
	defer s.mu.RUnlock()

	var cands []cand
	for k, e := range s.m {
		if q.Collection != "" && k.collection != q.Collection || !q.Scope.Allows(k.collection) {
			continue
		}
		for i := range e.chunks {
			cands = append(cands, cand{e, i})
		}
	}
	// Deterministic order for tie-breaking.
	sort.Slice(cands, func(i, j int) bool {
		a, b := cands[i], cands[j]
		if a.e.doc.Collection != b.e.doc.Collection {
			return a.e.doc.Collection < b.e.doc.Collection
		}
		if a.e.doc.ID != b.e.doc.ID {
			return a.e.doc.ID < b.e.doc.ID
		}
		return a.idx < b.idx
	})

	pos, neg := parseQuery(q.Text)
	if len(neg) > 0 {
		kept := cands[:0]
		for _, c := range cands {
			if !hasAny(c.e.chunks[c.idx].tokens, neg) {
				kept = append(kept, c)
			}
		}
		cands = kept
	}
	lex := s.lexical(cands, pos)
	var vec []scored
	if len(q.Embedding) > 0 {
		vec = vector(cands, q.Embedding)
	}

	var ranked []scored
	switch {
	case len(vec) == 0:
		ranked = lex
	case len(lex) == 0:
		ranked = vec
	default:
		ranked = fuse(lex, vec)
	}
	if len(ranked) > q.TopK {
		ranked = ranked[:q.TopK]
	}
	hits := make([]store.Hit, len(ranked))
	for i, r := range ranked {
		c := cands[r.i]
		hits[i] = store.Hit{
			Collection: c.e.doc.Collection, DocumentID: c.e.doc.ID, Title: c.e.doc.Title,
			SourceURI: c.e.doc.SourceURI, ChunkIndex: c.idx, Text: c.e.chunks[c.idx].text, Score: r.score,
		}
	}
	return hits, nil
}

// parseQuery splits free text into positive terms and "-term" exclusions, in
// the spirit of the PostgreSQL websearch syntax. A bare "or" is an operator, not
// a term. A query with no positive term matches nothing lexically.
func parseQuery(text string) (pos, neg []string) {
	for _, w := range strings.Fields(text) {
		if strings.HasPrefix(w, "-") {
			neg = append(neg, tokenize(w)...)
		} else if !strings.EqualFold(w, "or") {
			pos = append(pos, tokenize(w)...)
		}
	}
	return pos, neg
}

func hasAny(tokens map[string]int, terms []string) bool {
	for _, t := range terms {
		if tokens[t] > 0 {
			return true
		}
	}
	return false
}

type scored struct {
	i     int // index into cands
	score float64
}

func sortScored(r []scored) {
	sort.SliceStable(r, func(a, b int) bool { return r[a].score > r[b].score })
}

func (s *Store) lexical(cands []cand, terms []string) []scored {
	if len(terms) == 0 || len(cands) == 0 {
		return nil
	}
	uniq := map[string]bool{}
	for _, t := range terms {
		uniq[t] = true
	}
	var totalLen int
	df := map[string]int{}
	for _, c := range cands {
		ch := c.e.chunks[c.idx]
		totalLen += ch.length
		for t := range uniq {
			if ch.tokens[t] > 0 {
				df[t]++
			}
		}
	}
	n := float64(len(cands))
	avg := float64(totalLen) / n
	if avg == 0 {
		avg = 1
	}
	var out []scored
	for i, c := range cands {
		ch := c.e.chunks[c.idx]
		var sum float64
		for t := range uniq {
			tf := float64(ch.tokens[t])
			if tf == 0 {
				continue
			}
			idf := math.Log(1 + (n-float64(df[t])+0.5)/(float64(df[t])+0.5))
			sum += idf * tf * (bm25K1 + 1) / (tf + bm25K1*(1-bm25B+bm25B*float64(ch.length)/avg))
		}
		if sum > 0 {
			out = append(out, scored{i, sum})
		}
	}
	sortScored(out)
	return out
}

func vector(cands []cand, q []float32) []scored {
	var out []scored
	for i, c := range cands {
		if cos := cosine(q, c.e.chunks[c.idx].embedding); cos > 0 {
			out = append(out, scored{i, cos})
		}
	}
	sortScored(out)
	return out
}

func cosine(a, b []float32) float64 {
	if len(a) == 0 || len(a) != len(b) {
		return 0
	}
	var dot, na, nb float64
	for i := range a {
		dot += float64(a[i]) * float64(b[i])
		na += float64(a[i]) * float64(a[i])
		nb += float64(b[i]) * float64(b[i])
	}
	if na == 0 || nb == 0 {
		return 0
	}
	return dot / (math.Sqrt(na) * math.Sqrt(nb))
}

// fuse merges two ranked lists by reciprocal rank fusion.
func fuse(lists ...[]scored) []scored {
	acc := map[int]float64{}
	for _, l := range lists {
		for rank, r := range l {
			acc[r.i] += 1.0 / float64(rrfK+rank+1)
		}
	}
	out := make([]scored, 0, len(acc))
	for i, sc := range acc {
		out = append(out, scored{i, sc})
	}
	sort.Slice(out, func(a, b int) bool {
		if out[a].score != out[b].score {
			return out[a].score > out[b].score
		}
		return out[a].i < out[b].i
	})
	return out
}
