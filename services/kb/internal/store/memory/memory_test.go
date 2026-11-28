package memory

import (
	"testing"

	"github.com/openagentix/openagentix/services/kb/internal/store"
	"github.com/openagentix/openagentix/services/kb/internal/store/storetest"
)

func TestConformance(t *testing.T) {
	storetest.Run(t, storetest.Factory{
		New:     func(t *testing.T) store.Store { return New(3) },
		Vectors: true,
		Dim:     3,
		Graph:   true,
		Schemas: true,
	})
}

func TestZeroDimAcceptsAnyEmbeddingLength(t *testing.T) {
	s := New(0)
	err := s.UpsertDocument(t.Context(), store.Document{Collection: "c", ID: "a"}, []store.Chunk{{Text: "x", Embedding: []float32{1, 2}}})
	if err != nil {
		t.Fatal(err)
	}
}
