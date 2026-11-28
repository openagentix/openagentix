package kb

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/openagentix/openagentix/services/kb/internal/store"
)

func schemaSvc() *Service {
	s := graphSvc()
	s.Graph.Schemas = true
	return s
}

const teamSchema = `{"version":1,"entityTypes":[{"name":"team","key":"[A-Z][a-z]+"},{"name":"service","key":"[A-Z][a-z]+"},{"name":"person"}],
"relationTypes":[{"name":"owns","from":["team"],"to":["service"]},{"name":"escalates_to","from":["team"],"to":["person"]}]}`

func TestSchemaRoutesAreOffUnlessEnabled(t *testing.T) {
	s := graphSvc()
	if s.SchemasEnabled() {
		t.Fatal("schemas must be off by default")
	}
	if _, err := s.PutGraphSchema(context.Background(), "kg", []byte(teamSchema)); !errors.Is(err, ErrInvalid) || !strings.Contains(err.Error(), "not enabled") {
		t.Fatalf("%v", err)
	}
	if _, err := s.GetGraphSchema(context.Background(), "kg"); !errors.Is(err, ErrInvalid) {
		t.Fatalf("%v", err)
	}
}

func TestPutGraphSchemaChecksTheBodyAndTheVersion(t *testing.T) {
	s := schemaSvc()
	ctx := context.Background()
	if _, err := s.PutGraphSchema(ctx, "bad name", []byte(teamSchema)); !errors.Is(err, ErrInvalid) {
		t.Fatalf("collection: %v", err)
	}
	if _, err := s.PutGraphSchema(ctx, "kg", []byte(`{"version":1}`)); !errors.Is(err, ErrInvalid) {
		t.Fatalf("body: %v", err)
	}
	res, err := s.PutGraphSchema(ctx, "kg", []byte(teamSchema))
	if err != nil || !res.Changed || res.Version != 1 || len(res.SHA256) != 64 {
		t.Fatalf("%+v %v", res, err)
	}
	again, err := s.PutGraphSchema(ctx, "kg", []byte(strings.ReplaceAll(teamSchema, "\n", "")))
	if err != nil || again.Changed || again.SHA256 != res.SHA256 {
		t.Fatalf("the same body twice: %+v %v", again, err)
	}
	other := strings.Replace(teamSchema, `{"name":"person"}`, `{"name":"person"},{"name":"event"}`, 1)
	if _, err := s.PutGraphSchema(ctx, "kg", []byte(other)); !errors.Is(err, ErrConflict) {
		t.Fatalf("another body with the same version must conflict: %v", err)
	}
	other2 := strings.Replace(other, `"version":1`, `"version":2`, 1)
	if r, err := s.PutGraphSchema(ctx, "kg", []byte(other2)); err != nil || !r.Changed || r.Version != 2 {
		t.Fatalf("%+v %v", r, err)
	}
	got, err := s.GetGraphSchema(ctx, "kg")
	if err != nil || got.Version != 2 || !json.Valid(got.Body) {
		t.Fatalf("%+v %v", got, err)
	}
	if ok, err := s.DeleteGraphSchema(ctx, "kg"); err != nil || !ok {
		t.Fatalf("%v %v", ok, err)
	}
	if _, err := s.GetGraphSchema(ctx, "kg"); !errors.Is(err, store.ErrSchemaNotFound) {
		t.Fatalf("%v", err)
	}
}

func TestFactSetLoadIsCheckedAgainstTheSchema(t *testing.T) {
	s := schemaSvc()
	ctx := context.Background()
	if _, err := s.PutGraphSchema(ctx, "kg", []byte(teamSchema)); err != nil {
		t.Fatal(err)
	}
	ok := store.FactSet{Entities: []store.FactEntity{{Name: "Basalt", Type: "team"}, {Name: "Orion", Type: "service"}, {Name: "Nadia", Type: "person"}},
		Relations: []store.FactRelation{{Source: "Basalt", Predicate: "owns", Target: "Orion"}, {Source: "Basalt", Predicate: "escalates_to", Target: "Nadia"}}}
	if _, err := s.PutFactSet(ctx, "kg", "org", ok); err != nil {
		t.Fatalf("a fitting set, with types the built-in list does not have, must load: %v", err)
	}
	bad := ok
	bad.Entities = append([]store.FactEntity(nil), ok.Entities...)
	bad.Entities[1].Name = "orion lower"
	bad.Relations = []store.FactRelation{{Source: "Basalt", Predicate: "owns", Target: "orion lower"}}
	_, err := s.PutFactSet(ctx, "kg", "bad", bad)
	var ve *store.SchemaViolationError
	if !errors.As(err, &ve) || len(ve.Violations) != 1 || ve.Violations[0].At != "entities[1]" || ve.Violations[0].Rule != "key" {
		t.Fatalf("%v", err)
	}
	if _, err := s.GetFactSet(ctx, "kg", "bad"); !errors.Is(err, store.ErrFactSetNotFound) {
		t.Fatalf("nothing is stored: %v", err)
	}
	// a type that is neither declared nor of a valid form is refused by shape first
	worse := ok
	worse.Entities = append([]store.FactEntity(nil), ok.Entities...)
	worse.Entities[0].Type = "Bad Type!"
	if _, err := s.PutFactSet(ctx, "kg", "worse", worse); !errors.Is(err, ErrInvalid) {
		t.Fatalf("%v", err)
	}
	// another collection without a schema keeps the built-in list
	if _, err := s.PutFactSet(ctx, "other", "org", store.FactSet{Entities: []store.FactEntity{{Name: "Nadia", Type: "person"}}}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.PutFactSet(ctx, "other", "x", store.FactSet{Entities: []store.FactEntity{{Name: "Nadia", Type: "gadget"}}}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("without a schema the built-in list applies: %v", err)
	}
}

func TestAChangeThatTheStoredFactsBreakIsRefused(t *testing.T) {
	s := schemaSvc()
	ctx := context.Background()
	if _, err := s.PutFactSet(ctx, "kg", "org", store.FactSet{Entities: []store.FactEntity{{Name: "Basalt", Type: "team"}, {Name: "Orion", Type: "service"}},
		Relations: []store.FactRelation{{Source: "Basalt", Predicate: "owns", Target: "Orion"}}}); err != nil {
		t.Fatal(err)
	}
	noOwns := `{"version":1,"entityTypes":[{"name":"team"},{"name":"service"}],"relationTypes":[{"name":"runs","from":["team"],"to":["service"]}]}`
	_, err := s.PutGraphSchema(ctx, "kg", []byte(noOwns))
	var ve *store.SchemaViolationError
	if !errors.As(err, &ve) || ve.Kind != "change" || ve.Violations[0].At != "factsets/org/relations[0]" || ve.Violations[0].Rule != "predicate" {
		t.Fatalf("%v", err)
	}
}

func TestADocumentOfACollectionWithASchemaQueuesNoExtraction(t *testing.T) {
	s := schemaSvc()
	ctx := context.Background()
	if _, err := s.Put(ctx, "kg", "d0", DocInput{Title: "t", Text: "Orion is owned by Basalt."}); err != nil {
		t.Fatal(err)
	}
	if st := pendingJobs(t, s, "kg"); st.JobsPending == 0 {
		t.Fatalf("without a schema extraction is queued: %+v", st)
	}
	if _, err := s.PutGraphSchema(ctx, "kg2", []byte(teamSchema)); err != nil {
		t.Fatal(err)
	}
	n, err := s.Put(ctx, "kg2", "d1", DocInput{Title: "t", Text: "Orion is owned by Basalt."})
	if err != nil || n == 0 {
		t.Fatalf("the document is still chunked and stored: n=%d err=%v", n, err)
	}
	if st := pendingJobs(t, s, "kg2"); st.JobsPending != 0 {
		t.Fatalf("with a schema no extraction is queued: %+v", st)
	}
	hits, err := s.Search(ctx, "Orion", "kg2", 5)
	if err != nil || len(hits) == 0 {
		t.Fatalf("the document stays searchable: %v %v", hits, err)
	}
	// once the schema is deleted, a document loaded afterwards is extracted again
	if _, err := s.DeleteGraphSchema(ctx, "kg2"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Put(ctx, "kg2", "d2", DocInput{Title: "t", Text: "Orion is owned by Basalt."}); err != nil {
		t.Fatal(err)
	}
	if st := pendingJobs(t, s, "kg2"); st.JobsPending == 0 {
		t.Fatalf("extraction resumes: %+v", st)
	}
}

func TestSchemaReadsFollowTheScope(t *testing.T) {
	s := schemaSvc()
	ctx := context.Background()
	for _, c := range []string{"mine", "theirs"} {
		if _, err := s.PutGraphSchema(ctx, c, []byte(teamSchema)); err != nil {
			t.Fatal(err)
		}
	}
	sc := WithScope(ctx, store.Scope{Limited: true, Collections: []string{"mine"}})
	all, err := s.ReadGraphSchemas(sc, "")
	if err != nil || len(all) != 1 || all[0].Collection != "mine" {
		t.Fatalf("%+v %v", all, err)
	}
	one, err := s.ReadGraphSchemas(sc, "mine")
	if err != nil || len(one) != 1 {
		t.Fatalf("%+v %v", one, err)
	}
	outside, errOut := s.ReadGraphSchemas(sc, "theirs")
	missing, errMissing := s.ReadGraphSchemas(sc, "nowhere")
	if errOut != nil || errMissing != nil || len(outside) != 0 || len(missing) != 0 {
		t.Fatalf("an outside collection answers like a missing one: %+v %v / %+v %v", outside, errOut, missing, errMissing)
	}
	if every, _ := s.ReadGraphSchemas(ctx, ""); len(every) != 2 {
		t.Fatalf("unscoped: %+v", every)
	}
}
