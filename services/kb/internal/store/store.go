// Package store defines the storage interface the knowledge base is built on.
// Backends (in-memory, PostgreSQL, ...) implement Store and are interchangeable.
package store

import (
	"context"
	"errors"
	"time"
)

var (
	// ErrNotFound is returned when a document does not exist.
	ErrNotFound = errors.New("document not found")
	// ErrAmbiguous is returned when a document id without a collection matches
	// documents in more than one collection.
	ErrAmbiguous = errors.New("document id exists in more than one collection")
)

// Document is a stored document. Text is the full original text.
type Document struct {
	Collection string
	ID         string
	Title      string
	SourceURI  string
	Text       string
	UpdatedAt  time.Time
}

// Chunk is one retrievable piece of a document. Embedding is optional and, when
// present, must have the dimension the store was configured with.
type Chunk struct {
	Text      string
	Embedding []float32
}

// CollectionInfo summarises one collection.
type CollectionInfo struct {
	Name      string
	Documents int
}

// Scope limits a read to a list of collections. The zero value limits nothing.
// A limited scope with an empty list reads nothing. A store applies it inside
// its own query, so ranking, top_k and counts only ever see allowed rows.
type Scope struct {
	Limited     bool
	Collections []string
}

// Allows reports whether the scope lets a read reach the collection.
func (s Scope) Allows(collection string) bool {
	if !s.Limited {
		return true
	}
	for _, c := range s.Collections {
		if c == collection {
			return true
		}
	}
	return false
}

// Query is a search request. Embedding is optional: with it (and a store that
// supports vectors) results are hybrid-ranked, without it lexical only.
type Query struct {
	Text       string
	Embedding  []float32
	Collection string // empty = all collections
	TopK       int
	// Scope limits the search to allowed collections, on top of Collection.
	Scope Scope
}

// Hit is one ranked chunk. Higher Score is better; scores are only comparable
// within one result list.
type Hit struct {
	Collection string
	DocumentID string
	Title      string
	SourceURI  string
	ChunkIndex int
	Text       string
	Score      float64
}

// Store is the persistence and retrieval backend.
type Store interface {
	// UpsertDocument atomically replaces the document and all its chunks.
	UpsertDocument(ctx context.Context, doc Document, chunks []Chunk) error
	// DeleteDocument removes a document; it reports whether it existed.
	DeleteDocument(ctx context.Context, collection, id string) (bool, error)
	// GetDocument returns a document. An empty collection matches any collection
	// but yields ErrAmbiguous if the id is not unique.
	GetDocument(ctx context.Context, collection, id string) (Document, error)
	// ListCollections returns collections sorted by name.
	ListCollections(ctx context.Context) ([]CollectionInfo, error)
	// GetDocumentIn is GetDocument inside a scope: a document of a collection the
	// scope does not allow does not exist, and ErrAmbiguous counts only allowed ones.
	GetDocumentIn(ctx context.Context, scope Scope, collection, id string) (Document, error)
	// ListCollectionsIn is ListCollections inside a scope.
	ListCollectionsIn(ctx context.Context, scope Scope) ([]CollectionInfo, error)
	// Search returns at most q.TopK hits, best first.
	Search(ctx context.Context, q Query) ([]Hit, error)
	// DocumentChunks returns the chunk texts of a document in order, or
	// ErrNotFound.
	DocumentChunks(ctx context.Context, collection, id string) ([]string, error)

	// The knowledge-graph methods below return ErrGraphDisabled on a store that
	// was opened without graph support. All of them are scoped to one collection:
	// entities are never shared across collections.

	// UpsertEntity creates an entity or merges into the existing one with the
	// same collection, type and normalised name.
	UpsertEntity(ctx context.Context, in EntityInput) (Entity, error)
	// AddRelation stores an edge and returns its id. Both entities must belong to
	// r.Collection and the document must exist (else ErrNotFound). Adding the same
	// (src, dst, predicate, document, chunk) again returns the existing id.
	AddRelation(ctx context.Context, r Relation) (int64, error)
	// LinkEntityChunk records that an entity is mentioned in a chunk (idempotent).
	LinkEntityChunk(ctx context.Context, collection string, ec EntityChunk) error
	// DeleteDocumentGraph removes the relations, mentions and extraction jobs of
	// a document, and then the extracted entities nothing refers to any more.
	DeleteDocumentGraph(ctx context.Context, collection, documentID string) error
	// FindEntitiesByName finds seed entities whose name or alias equals the text,
	// is contained in it (an entity named in a question) or contains it.
	FindEntitiesByName(ctx context.Context, collection, text string, limit int) ([]EntityHit, error)
	// FindEntitiesByEmbedding finds seed entities by cosine similarity of their
	// name embedding. It returns nothing on a store without vectors.
	FindEntitiesByEmbedding(ctx context.Context, collection string, embedding []float32, limit int) ([]EntityHit, error)
	// Expand returns the simple paths of 1..Hops edges from the seeds, each edge
	// with its citation, ordered by length and then by entity and edge ids.
	Expand(ctx context.Context, q ExpandQuery) ([]Path, error)
	// ShortestPaths returns all shortest paths (up to Limit) between two entities
	// that are at most MaxHops edges long.
	ShortestPaths(ctx context.Context, q PathQuery) ([]Path, error)
	// GraphStats counts the graph rows of a collection.
	GraphStats(ctx context.Context, collection string) (GraphStats, error)

	// ReplaceFactSet atomically replaces the fact set of fs.Collection and fs.ID
	// (creating it if new) with the curated entities and relations of fs, which
	// must be valid: every relation names entities declared in fs. Entities are
	// merged with existing ones by canonical name; the curated name and type win
	// for display and the entity becomes manual. Facts the previous version had
	// and this one has not are removed; a manual entity that no other fact set
	// declares is un-marked, and removed if nothing else refers to it. Replacing
	// a fact set by an identical one changes nothing and returns changed=false.
	ReplaceFactSet(ctx context.Context, fs FactSet) (changed bool, err error)
	// GetFactSet returns a stored fact set, or ErrFactSetNotFound.
	GetFactSet(ctx context.Context, collection, id string) (FactSet, error)
	// ListFactSets returns the fact sets of a collection sorted by id.
	ListFactSets(ctx context.Context, collection string) ([]FactSetInfo, error)
	// DeleteFactSet removes a fact set and its relations; it reports whether it
	// existed. Its entities are un-marked and removed only if unused.
	DeleteFactSet(ctx context.Context, collection, id string) (bool, error)

	// SyncExtractionJobs makes the extraction jobs of a document match specs. If
	// the document already has exactly these jobs for promptVersion nothing
	// changes and it returns 0. Otherwise the document's graph rows and jobs are
	// replaced by new pending jobs and it returns their number.
	SyncExtractionJobs(ctx context.Context, collection, documentID, promptVersion string, specs []JobSpec) (int, error)
	// ClaimJob leases the oldest runnable pending job for the given duration. A
	// job whose lease expired (its worker died) is claimable again. ok is false
	// when nothing is runnable.
	ClaimJob(ctx context.Context, lease time.Duration) (job Job, ok bool, err error)
	// ApplyExtraction stores a result and marks its job done in one transaction.
	// It returns ErrJobGone if the job is not pending any more.
	ApplyExtraction(ctx context.Context, res ExtractionResult) error
	// FailJob records a failed attempt. With final, or when it is not final but
	// the caller decided so, the job becomes failed; otherwise it is retried
	// after retryIn.
	FailJob(ctx context.Context, key JobKey, code string, retryIn time.Duration, final bool) error

	// Ping checks that the backend is reachable.
	Ping(ctx context.Context) error
	// Close releases resources.
	Close()
}
