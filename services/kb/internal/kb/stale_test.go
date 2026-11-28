package kb

import (
	"context"
	"testing"
	"time"

	"github.com/openagentix/openagentix/services/kb/internal/store"
)

// Review L6: a document of a collection with a schema that is updated must lose the facts that were extracted from its old text; they predate the schema and describe text that is gone.
func TestUpdatingADocumentInASchemaCollectionDropsItsOldExtractedFacts(t *testing.T) {
	s := schemaSvc()
	ctx := context.Background()
	if _, err := s.Put(ctx, "kg", "d1", DocInput{Title: "t", Text: "Basalt owns Orion."}); err != nil {
		t.Fatal(err)
	}
	j, ok, err := s.Store.ClaimJob(ctx, time.Minute)
	if err != nil || !ok {
		t.Fatalf("%v %v", ok, err)
	}
	res := store.ExtractionResult{Job: j.JobKey, Model: "m", PromptVersion: "v1",
		Entities:  []store.ExtractedEntity{{Name: "Basalt", Type: "team", Chunks: []int{0}}, {Name: "Orion", Type: "service", Chunks: []int{0}}},
		Relations: []store.ExtractedRelation{{Src: 0, Dst: 1, Predicate: "owns", Evidence: "Basalt owns Orion", ChunkIndex: 0}}}
	if err := s.Store.ApplyExtraction(ctx, res); err != nil {
		t.Fatal(err)
	}
	// a schema that the extracted facts fit
	if _, err := s.PutGraphSchema(ctx, "kg", []byte(`{"version":1,"entityTypes":[{"name":"team"},{"name":"service"}],"relationTypes":[{"name":"owns","from":["team"],"to":["service"]}]}`)); err != nil {
		t.Fatal(err)
	}
	if st, _ := s.Store.GraphStats(ctx, "kg"); st.Entities != 2 || st.Relations != 1 {
		t.Fatalf("the facts are there before the update: %+v", st)
	}
	if _, err := s.Put(ctx, "kg", "d1", DocInput{Title: "t", Text: "Granite now owns Orion."}); err != nil {
		t.Fatal(err)
	}
	if st, _ := s.Store.GraphStats(ctx, "kg"); st.Entities != 0 || st.Relations != 0 {
		t.Fatalf("the facts of the old text must be gone, and nothing is extracted from the new one: %+v", st)
	}
	if st, _ := s.Store.GraphStats(ctx, "kg"); st.JobsPending != 0 {
		t.Fatalf("no job is queued: %+v", st)
	}
}
