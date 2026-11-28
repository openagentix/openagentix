// Package kb is the knowledge-base service layer shared by the REST admin API
// and the MCP tools: validation, chunking, embedding, and store orchestration.
package kb

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/openagentix/openagentix/services/kb/internal/chunk"
	"github.com/openagentix/openagentix/services/kb/internal/embed"
	"github.com/openagentix/openagentix/services/kb/internal/graph"
	"github.com/openagentix/openagentix/services/kb/internal/obs"
	"github.com/openagentix/openagentix/services/kb/internal/store"
)

var (
	// ErrInvalid marks caller errors (bad names, empty text, ...).
	ErrInvalid = errors.New("invalid input")
	// ErrTooLarge marks a document that would exceed the per-document chunk cap.
	ErrTooLarge = errors.New("document too large")
	// ErrUpstream marks failures of a dependency such as the embedder.
	ErrUpstream = errors.New("upstream failure")
)

// Limits and defaults.
const (
	DefaultTopK        = 5
	MaxTopK            = 20
	MaxQueryChars      = 2000
	MaxTitleChars      = 500
	MaxSourceURIChars  = 2048
	DefaultDocMaxChars = 50000

	DefaultQueryEmbedTimeout = 3 * time.Second
	DefaultMaxChunksPerDoc   = 2000
)

var (
	collectionRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)
	idRe         = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$`)
)

// Service implements the knowledge-base operations over a Store.
type Service struct {
	Store       store.Store
	Embedder    embed.Embedder
	Chunk       chunk.Options
	DocMaxChars int
	Log         *slog.Logger

	// QueryEmbedTimeout bounds the query-time embedding call so a slow
	// embedder cannot consume the request deadline needed by the lexical
	// fallback. Zero selects DefaultQueryEmbedTimeout.
	QueryEmbedTimeout time.Duration

	// Graph, when non-nil, makes Put queue entity and relation extraction for
	// the document. It never waits for it: a graph.Worker does the extraction.
	Graph *GraphOptions

	// MaxChunksPerDoc rejects documents that split into more chunks, before
	// any embedding call. Zero selects DefaultMaxChunksPerDoc.
	MaxChunksPerDoc int

	// Metrics, when non-nil, counts ingests and searches. It never receives
	// text, ids or collection names.
	Metrics *obs.Metrics
}

// GraphOptions configures how Put plans graph extraction.
type GraphOptions struct {
	WindowChars   int    // extraction window size in characters
	PromptVersion string // jobs of another version are redone
	MaxHops       int    // longest traversal graph queries accept, 1..store.MaxHops; zero means store.MaxHops
	FanOut        int    // edges followed out of one entity by graph queries; zero means store.DefaultFanOut
}

// DocInput is the writable part of a document.
type DocInput struct {
	Title     string
	SourceURI string
	Text      string
}

// DocView is a document prepared for returning to a caller.
type DocView struct {
	Collection string
	ID         string
	Title      string
	SourceURI  string
	Text       string // possibly truncated, with a marker
	Truncated  bool
	TotalChars int
}

func invalid(format string, a ...any) error {
	return fmt.Errorf("%w: %s", ErrInvalid, fmt.Sprintf(format, a...))
}

// ValidateCollection checks a collection name.
func ValidateCollection(c string) error {
	if !collectionRe.MatchString(c) {
		return invalid("collection must match %s", collectionRe)
	}
	return nil
}

// ValidateID checks a document id.
func ValidateID(id string) error {
	if !idRe.MatchString(id) {
		return invalid("document id must match %s", idRe)
	}
	return nil
}

func cleanText(field, s string, max int) error {
	if !utf8.ValidString(s) || strings.ContainsRune(s, 0) {
		return invalid("%s must be valid UTF-8 without NUL characters", field)
	}
	if utf8.RuneCountInString(s) > max {
		return invalid("%s longer than %d characters", field, max)
	}
	return nil
}

// validateSourceURI allows an empty source or an absolute http(s) URL. Other
// schemes (javascript:, data:, file:, ...) are rejected because the URI is
// echoed to models and UIs.
func validateSourceURI(raw string) error {
	if raw == "" {
		return nil
	}
	u, err := url.Parse(raw)
	if err != nil || (!strings.EqualFold(u.Scheme, "http") && !strings.EqualFold(u.Scheme, "https")) || u.Host == "" {
		return invalid("source_uri must be empty or an absolute http or https URL")
	}
	return nil
}

// Put validates, chunks, embeds and upserts a document. It returns the number
// of chunks stored. Repeating the call with the same input is idempotent.
func (s *Service) Put(ctx context.Context, collection, id string, in DocInput) (int, error) {
	n, err := s.put(ctx, collection, id, in)
	s.Metrics.Ingest(outcomeOf(err, ctx))
	return n, err
}

// outcomeOf names an error with a value from the closed set the metrics accept.
func outcomeOf(err error, ctx context.Context) string {
	switch {
	case err == nil:
		return "ok"
	case errors.Is(err, ErrInvalid):
		return "invalid"
	case errors.Is(err, ErrTooLarge):
		return "too_large"
	case errors.Is(err, ErrUpstream):
		return "upstream_error"
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	case errors.Is(err, context.Canceled) || ctx.Err() == context.Canceled:
		return "canceled"
	}
	return "error"
}

func (s *Service) put(ctx context.Context, collection, id string, in DocInput) (int, error) {
	if err := ValidateCollection(collection); err != nil {
		return 0, err
	}
	if err := ValidateID(id); err != nil {
		return 0, err
	}
	if strings.TrimSpace(in.Text) == "" {
		return 0, invalid("text must not be empty")
	}
	if !utf8.ValidString(in.Text) || strings.ContainsRune(in.Text, 0) {
		return 0, invalid("text must be valid UTF-8 without NUL characters")
	}
	if err := cleanText("title", in.Title, MaxTitleChars); err != nil {
		return 0, err
	}
	if err := cleanText("source_uri", in.SourceURI, MaxSourceURIChars); err != nil {
		return 0, err
	}
	if err := validateSourceURI(in.SourceURI); err != nil {
		return 0, err
	}
	pieces := chunk.Split(in.Text, s.Chunk)
	limit := s.MaxChunksPerDoc
	if limit <= 0 {
		limit = DefaultMaxChunksPerDoc
	}
	if len(pieces) > limit {
		return 0, fmt.Errorf("%w: document splits into %d chunks, more than the limit of %d (KB_MAX_CHUNKS_PER_DOC); split it into several documents", ErrTooLarge, len(pieces), limit)
	}
	chunks := make([]store.Chunk, len(pieces))
	for i, p := range pieces {
		chunks[i].Text = p
	}
	if s.Embedder.Dimensions() > 0 {
		vecs, err := s.Embedder.Embed(ctx, pieces)
		if err != nil {
			if ctx.Err() != nil {
				return 0, ctx.Err() // our own deadline or a client disconnect, not the embedder's fault
			}
			return 0, fmt.Errorf("%w: embedding document: %v", ErrUpstream, err)
		}
		if len(vecs) != len(chunks) {
			return 0, fmt.Errorf("%w: embedder returned %d vectors for %d chunks", ErrUpstream, len(vecs), len(chunks))
		}
		for i := range chunks {
			chunks[i].Embedding = vecs[i]
		}
	}
	doc := store.Document{Collection: collection, ID: id, Title: in.Title, SourceURI: in.SourceURI, Text: in.Text}
	if err := s.Store.UpsertDocument(ctx, doc, chunks); err != nil {
		return 0, err
	}
	if s.Graph != nil {
		if _, err := graph.Enqueue(ctx, s.Store, collection, id, pieces, s.Graph.WindowChars, s.Graph.PromptVersion); err != nil {
			return 0, fmt.Errorf("queueing graph extraction: %w", err)
		}
	}
	return len(chunks), nil
}

// Delete removes a document and reports whether it existed.
func (s *Service) Delete(ctx context.Context, collection, id string) (bool, error) {
	if err := ValidateCollection(collection); err != nil {
		return false, err
	}
	if err := ValidateID(id); err != nil {
		return false, err
	}
	return s.Store.DeleteDocument(ctx, collection, id)
}

// Collections lists collections with document counts.
func (s *Service) Collections(ctx context.Context) ([]store.CollectionInfo, error) {
	if sc := ScopeFrom(ctx); sc.Limited {
		return s.Store.ListCollectionsIn(ctx, sc)
	}
	return s.Store.ListCollections(ctx)
}

// Search returns ranked chunks. topK <= 0 selects DefaultTopK and values above
// MaxTopK are clamped. If the embedder fails, search falls back to lexical.
func (s *Service) Search(ctx context.Context, query, collection string, topK int) ([]store.Hit, error) {
	start := time.Now()
	hits, mode, err := s.search(ctx, query, collection, topK)
	s.Metrics.Search(mode, outcomeOf(err, ctx), time.Since(start))
	return hits, err
}

// search also reports the mode: "hybrid" when the query was embedded, else "lexical".
func (s *Service) search(ctx context.Context, query, collection string, topK int) ([]store.Hit, string, error) {
	mode := "lexical"
	query = strings.TrimSpace(query)
	if query == "" {
		return nil, mode, invalid("query must not be empty")
	}
	if utf8.RuneCountInString(query) > MaxQueryChars {
		return nil, mode, invalid("query longer than %d characters", MaxQueryChars)
	}
	if collection != "" {
		if err := ValidateCollection(collection); err != nil {
			return nil, mode, err
		}
	}
	// A named collection outside the caller's list: the answer is the one for a collection that has nothing, and nothing runs, so that the time of the answer says
	// nothing about what that collection holds (ADR 0030, review L1). Not even the query is embedded.
	if collection != "" && !ScopeFrom(ctx).Allows(collection) {
		return nil, mode, nil
	}
	if topK <= 0 {
		topK = DefaultTopK
	}
	if topK > MaxTopK {
		topK = MaxTopK
	}
	q := store.Query{Text: query, Collection: collection, TopK: topK, Scope: ScopeFrom(ctx)}
	if s.Embedder.Dimensions() > 0 {
		if v, err := s.embedQuery(ctx, query); err != nil {
			s.Log.Warn("query embedding failed; falling back to lexical search", "err", err)
		} else {
			q.Embedding = v
			mode = "hybrid"
		}
	}
	hits, err := s.Store.Search(ctx, q)
	return hits, mode, err
}

// Get returns a document, truncating its text at DocMaxChars characters.
func (s *Service) Get(ctx context.Context, collection, id string) (DocView, error) {
	if collection != "" {
		if err := ValidateCollection(collection); err != nil {
			return DocView{}, err
		}
	}
	if err := ValidateID(id); err != nil {
		return DocView{}, err
	}
	var d store.Document
	var err error
	if sc := ScopeFrom(ctx); sc.Limited {
		if collection != "" && !sc.Allows(collection) {
			return DocView{}, store.ErrNotFound // outside the list: as a missing document, and no query runs (review L1)
		}
		d, err = s.Store.GetDocumentIn(ctx, sc, collection, id)
	} else {
		d, err = s.Store.GetDocument(ctx, collection, id)
	}
	if err != nil {
		return DocView{}, err
	}
	limit := s.DocMaxChars
	if limit <= 0 {
		limit = DefaultDocMaxChars
	}
	v := DocView{Collection: d.Collection, ID: d.ID, Title: d.Title, SourceURI: d.SourceURI, Text: d.Text}
	v.TotalChars = utf8.RuneCountInString(d.Text)
	if v.TotalChars > limit {
		r := []rune(d.Text)
		v.Text = string(r[:limit]) + fmt.Sprintf("\n\n[truncated: showing the first %d of %d characters]", limit, v.TotalChars)
		v.Truncated = true
	}
	return v, nil
}

// embedQuery embeds a search query under its own short timeout (derived from
// ctx, so it never outlives the request) and without retries. A slow embedder
// then cannot starve the lexical fallback of its share of the deadline.
func (s *Service) embedQuery(ctx context.Context, query string) ([]float32, error) {
	timeout := s.QueryEmbedTimeout
	if timeout <= 0 {
		timeout = DefaultQueryEmbedTimeout
	}
	ectx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	if qe, ok := s.Embedder.(embed.QueryEmbedder); ok {
		return qe.EmbedQuery(ectx, query)
	}
	vecs, err := s.Embedder.Embed(ectx, []string{query})
	if err != nil {
		return nil, err
	}
	if len(vecs) != 1 {
		return nil, fmt.Errorf("embedder returned %d vectors for 1 query", len(vecs))
	}
	return vecs[0], nil
}
