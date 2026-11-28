package kb

import (
	"context"
	"errors"
	"testing"

	"github.com/openagentix/openagentix/services/kb/internal/store"
)

// countingStore counts the reads that reach the store, so that a read of a collection outside the scope can be shown to stop before it.
type countingStore struct {
	store.Store
	searches, gets int
}

func (c *countingStore) Search(ctx context.Context, q store.Query) ([]store.Hit, error) {
	c.searches++
	return c.Store.Search(ctx, q)
}

func (c *countingStore) GetDocumentIn(ctx context.Context, sc store.Scope, coll, id string) (store.Document, error) {
	c.gets++
	return c.Store.GetDocumentIn(ctx, sc, coll, id)
}

// A read of a named collection outside the list stops before the store: its run time then says nothing about what the collection holds (review L1).
func TestNamedOutsideCollectionNeverReachesTheStore(t *testing.T) {
	s := scopedSvc(t)
	cs := &countingStore{Store: s.Store}
	s.Store = cs
	ctx := mineOnly(context.Background())
	if hits, err := s.Search(ctx, "pelican", "theirs", 10); err != nil || len(hits) != 0 {
		t.Fatalf("%v %v", hits, err)
	}
	if _, err := s.Get(ctx, "theirs", "doc"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("%v", err)
	}
	if cs.searches != 0 || cs.gets != 0 {
		t.Fatalf("the store was reached: %d searches, %d gets", cs.searches, cs.gets)
	}
	// an allowed collection does reach it
	if _, err := s.Search(ctx, "pelican", "mine", 10); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Get(ctx, "mine", "doc"); err != nil {
		t.Fatal(err)
	}
	if cs.searches != 1 || cs.gets != 1 {
		t.Fatalf("%d searches, %d gets", cs.searches, cs.gets)
	}
}
