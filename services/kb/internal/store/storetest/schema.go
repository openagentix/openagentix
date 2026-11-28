package storetest

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/openagentix/openagentix/services/kb/internal/store"
)

// A schema for the suite, built by hand: the real parser is in package graph, which imports store.
func suiteSchema(t *testing.T, version int, extra ...store.SchemaEntityType) (store.GraphSchema, []byte, string) {
	t.Helper()
	g := store.GraphSchema{
		Version: version,
		EntityTypes: append([]store.SchemaEntityType{
			{Name: "team", Key: "[A-Z][a-z]+"},
			{Name: "service", Key: "[A-Z][a-z]+"},
			{Name: "person"},
		}, extra...),
		RelationTypes: []store.SchemaRelationType{
			{Name: "owns", From: []string{"team"}, To: []string{"service"}},
			{Name: "manages", From: []string{"person"}, To: []string{"team"}},
		},
	}
	if err := g.Compile(); err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(g)
	if err != nil {
		t.Fatal(err)
	}
	return g, body, fmt.Sprintf("sha-%d-%d", version, len(extra))
}

func putSchema(t *testing.T, ctx context.Context, s store.Store, coll string, version int, extra ...store.SchemaEntityType) (bool, string, error) {
	t.Helper()
	g, body, sha := suiteSchema(t, version, extra...)
	changed, err := s.PutGraphSchema(ctx, coll, g, body, sha)
	return changed, sha, err
}

func runSchemas(t *testing.T, f Factory, run func(string, func(*testing.T, store.Store))) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	t.Cleanup(cancel)

	run("schema: put, get, list and delete", func(t *testing.T, s store.Store) {
		if _, err := s.GetGraphSchema(ctx, "g"); !errors.Is(err, store.ErrSchemaNotFound) {
			t.Fatalf("%v", err)
		}
		changed, sha, err := putSchema(t, ctx, s, "g", 1)
		if err != nil || !changed {
			t.Fatalf("changed=%v err=%v", changed, err)
		}
		got, err := s.GetGraphSchema(ctx, "g")
		if err != nil || got.Version != 1 || got.SHA256 != sha || got.Collection != "g" || len(got.Body) == 0 || got.UpdatedAt.IsZero() {
			t.Fatalf("%+v %v", got, err)
		}
		// the same body again changes nothing
		if changed, _, err = putSchema(t, ctx, s, "g", 1); err != nil || changed {
			t.Fatalf("same body: changed=%v err=%v", changed, err)
		}
		// a version that is not higher is refused, a higher one is taken
		if _, _, err = putSchema(t, ctx, s, "g", 1, store.SchemaEntityType{Name: "event"}); !errors.Is(err, store.ErrSchemaVersion) {
			t.Fatalf("same version, other body: %v", err)
		}
		if _, _, err = putSchema(t, ctx, s, "g", 0, store.SchemaEntityType{Name: "event"}); !errors.Is(err, store.ErrSchemaVersion) {
			t.Fatalf("lower version: %v", err)
		}
		if changed, _, err = putSchema(t, ctx, s, "g", 2, store.SchemaEntityType{Name: "event"}); err != nil || !changed {
			t.Fatalf("higher: changed=%v err=%v", changed, err)
		}
		if got, _ = s.GetGraphSchema(ctx, "g"); got.Version != 2 {
			t.Fatalf("%+v", got)
		}
		_, _, _ = putSchema(t, ctx, s, "h", 1)
		all, err := s.ListGraphSchemas(ctx, store.Scope{})
		if err != nil || len(all) != 2 || all[0].Collection != "g" || all[1].Collection != "h" {
			t.Fatalf("%+v %v", all, err)
		}
		limited, _ := s.ListGraphSchemas(ctx, store.Scope{Limited: true, Collections: []string{"h"}})
		if len(limited) != 1 || limited[0].Collection != "h" {
			t.Fatalf("scope: %+v", limited)
		}
		if none, _ := s.ListGraphSchemas(ctx, store.Scope{Limited: true}); len(none) != 0 {
			t.Fatalf("empty list: %+v", none)
		}
		if ok, err := s.DeleteGraphSchema(ctx, "g"); err != nil || !ok {
			t.Fatalf("%v %v", ok, err)
		}
		if ok, err := s.DeleteGraphSchema(ctx, "g"); err != nil || ok {
			t.Fatalf("second delete: %v %v", ok, err)
		}
		if _, err := s.GetGraphSchema(ctx, "g"); !errors.Is(err, store.ErrSchemaNotFound) {
			t.Fatalf("%v", err)
		}
	})

	goodSet := func(coll, id string, sha string) store.FactSet {
		fs := catalogue(coll, id)
		fs.Entities = []store.FactEntity{{Name: "Basalt", Type: "team"}, {Name: "Orion", Type: "service"}, {Name: "Nadia Rao", Type: "person"}}
		fs.SchemaSHA = sha
		return fs
	}

	run("schema: a fact set that fits is stored, one that breaks it is refused with nothing stored", func(t *testing.T, s store.Store) {
		_, sha, _ := putSchema(t, ctx, s, "g", 1)
		if _, err := s.ReplaceFactSet(ctx, goodSet("g", "ok", sha)); err != nil {
			t.Fatalf("a fitting set: %v", err)
		}
		bad := goodSet("g", "bad", sha)
		bad.Entities[0].Type = "gadget"      // type
		bad.Entities[1].Name = "orion lower" // key
		bad.Relations = []store.FactRelation{
			{Source: "Basalt", Predicate: "calls", Target: "orion lower"},      // predicate
			{Source: "orion lower", Predicate: "manages", Target: "Nadia Rao"}, // from (service) is not person, to (person) is not team
		}
		_, err := s.ReplaceFactSet(ctx, bad)
		var ve *store.SchemaViolationError
		if !errors.Is(err, store.ErrSchemaViolation) || !errors.As(err, &ve) || ve.Kind != "factset" {
			t.Fatalf("%v", err)
		}
		got := map[string]bool{}
		for _, v := range ve.Violations {
			got[v.At+" "+v.Rule] = true
		}
		for _, w := range []string{"entities[0] type", "entities[1] key", "relations[0] predicate", "relations[1] from", "relations[1] to"} {
			if !got[w] {
				t.Errorf("missing %q in %+v", w, ve.Violations)
			}
		}
		if _, err := s.GetFactSet(ctx, "g", "bad"); !errors.Is(err, store.ErrFactSetNotFound) {
			t.Fatalf("nothing of a refused set may be stored: %v", err)
		}
		if st, _ := s.GraphStats(ctx, "g"); st.FactSets != 1 || st.ManualEntities != 3 {
			t.Fatalf("stats = %+v", st)
		}
		// replacing a stored set by a bad one leaves the stored one as it was
		bad2 := goodSet("g", "ok", sha)
		bad2.Entities[0].Type = "gadget"
		if _, err := s.ReplaceFactSet(ctx, bad2); !errors.Is(err, store.ErrSchemaViolation) {
			t.Fatalf("%v", err)
		}
		if fs, err := s.GetFactSet(ctx, "g", "ok"); err != nil || fs.Entities[0].Type != "team" {
			t.Fatalf("%+v %v", fs, err)
		}
	})

	run("schema: twenty violations are named and the rest counted", func(t *testing.T, s store.Store) {
		_, sha, _ := putSchema(t, ctx, s, "g", 1)
		fs := store.FactSet{Collection: "g", ID: "many", SchemaSHA: sha}
		for i := 0; i < 30; i++ {
			fs.Entities = append(fs.Entities, store.FactEntity{Name: fmt.Sprintf("Thing%02d", i), Type: "gadget"})
		}
		_, err := s.ReplaceFactSet(ctx, fs)
		var ve *store.SchemaViolationError
		if !errors.As(err, &ve) || len(ve.Violations) != 20 || ve.More != 10 {
			t.Fatalf("%v", err)
		}
	})

	run("schema: a fact set shaped for another schema state is refused so the caller can shape it again", func(t *testing.T, s store.Store) {
		fs := goodSet("g", "ok", "")
		if _, err := s.ReplaceFactSet(ctx, fs); err != nil {
			t.Fatalf("no schema, none expected: %v", err)
		}
		_, sha, _ := putSchema(t, ctx, s, "g", 1)
		if _, err := s.ReplaceFactSet(ctx, goodSet("g", "two", "")); !errors.Is(err, store.ErrSchemaMoved) {
			t.Fatalf("a schema appeared after the set was shaped: %v", err)
		}
		if _, err := s.ReplaceFactSet(ctx, goodSet("g", "two", sha)); err != nil {
			t.Fatalf("%v", err)
		}
		if _, err := s.DeleteGraphSchema(ctx, "g"); err != nil {
			t.Fatal(err)
		}
		if _, err := s.ReplaceFactSet(ctx, goodSet("g", "three", sha)); !errors.Is(err, store.ErrSchemaMoved) {
			t.Fatalf("the schema went away after the set was shaped: %v", err)
		}
	})

	run("schema: a change that the facts already stored break is refused, with the violations, and stores nothing", func(t *testing.T, s store.Store) {
		if _, err := s.ReplaceFactSet(ctx, goodSet("g", "ok", "")); err != nil {
			t.Fatal(err)
		}
		// the new schema has no type "person": the fact set has one
		g := store.GraphSchema{Version: 1, EntityTypes: []store.SchemaEntityType{{Name: "team"}, {Name: "service"}},
			RelationTypes: []store.SchemaRelationType{{Name: "owns", From: []string{"team"}, To: []string{"service"}}}}
		_ = g.Compile()
		body, _ := json.Marshal(g)
		_, err := s.PutGraphSchema(ctx, "g", g, body, "shaX")
		var ve *store.SchemaViolationError
		if !errors.Is(err, store.ErrSchemaViolation) || !errors.As(err, &ve) || ve.Kind != "change" {
			t.Fatalf("%v", err)
		}
		got := map[string]bool{}
		for _, v := range ve.Violations {
			got[v.At+" "+v.Rule] = true
		}
		for _, w := range []string{"factsets/ok/entities[2] type", "factsets/ok/relations[1] predicate"} {
			if !got[w] {
				t.Errorf("missing %q in %+v", w, ve.Violations)
			}
		}
		if _, err := s.GetGraphSchema(ctx, "g"); !errors.Is(err, store.ErrSchemaNotFound) {
			t.Fatalf("a refused change must store nothing: %v", err)
		}
		// the steps of the ADR: add what is needed, reload, then remove the old
		if _, _, err := putSchema(t, ctx, s, "g", 1); err != nil {
			t.Fatalf("a schema the facts fit: %v", err)
		}
	})

	run("schema: extracted facts count against a new schema", func(t *testing.T, s store.Store) {
		g := graphFixture{t, ctx, s}
		g.doc("g", "d1", "c0")
		if _, err := s.SyncExtractionJobs(ctx, "g", "d1", "v1", []store.JobSpec{{WindowIdx: 0, WindowHash: "h", FirstChunk: 0, ChunkCount: 1}}); err != nil {
			t.Fatal(err)
		}
		j, ok, err := s.ClaimJob(ctx, time.Minute)
		if err != nil || !ok {
			t.Fatalf("%v %v", ok, err)
		}
		res := store.ExtractionResult{Job: j.JobKey, Model: "m", PromptVersion: "v1",
			Entities:  []store.ExtractedEntity{{Name: "Checkout", Type: "service", Chunks: []int{0}}, {Name: "Basalt", Type: "team", Chunks: []int{0}}},
			Relations: []store.ExtractedRelation{{Src: 1, Dst: 0, Predicate: "runs", Evidence: "e", ChunkIndex: 0}}}
		if err := s.ApplyExtraction(ctx, res); err != nil {
			t.Fatal(err)
		}
		_, _, err = putSchema(t, ctx, s, "g", 1)
		var ve *store.SchemaViolationError
		if !errors.As(err, &ve) || ve.Kind != "change" {
			t.Fatalf("an extracted predicate the schema does not declare must refuse the change: %v", err)
		}
		found := false
		for _, v := range ve.Violations {
			found = found || (v.At == "extracted/relations[0]" && v.Rule == "predicate")
		}
		if !found {
			t.Fatalf("%+v", ve.Violations)
		}
		// deleting the documents removes the extracted facts, and then the schema fits
		if _, err := s.DeleteDocument(ctx, "g", "d1"); err != nil {
			t.Fatal(err)
		}
		if _, _, err := putSchema(t, ctx, s, "g", 1); err != nil {
			t.Fatalf("after the documents are gone: %v", err)
		}
	})

	run("schema: delete keeps the facts and the built-in types apply again", func(t *testing.T, s store.Store) {
		_, sha, _ := putSchema(t, ctx, s, "g", 1)
		if _, err := s.ReplaceFactSet(ctx, goodSet("g", "ok", sha)); err != nil {
			t.Fatal(err)
		}
		if ok, err := s.DeleteGraphSchema(ctx, "g"); err != nil || !ok {
			t.Fatalf("%v %v", ok, err)
		}
		if st, _ := s.GraphStats(ctx, "g"); st.FactSets != 1 || st.ManualEntities != 3 {
			t.Fatalf("the facts stay: %+v", st)
		}
		if _, err := s.ReplaceFactSet(ctx, goodSet("g", "ok2", "")); err != nil {
			t.Fatalf("no schema now: %v", err)
		}
	})

	run("schema: extraction is not claimed or applied in a collection with a schema, and resumes after delete", func(t *testing.T, s store.Store) {
		g := graphFixture{t, ctx, s}
		g.doc("g", "d1", "c0")
		g.doc("other", "d2", "c0")
		for _, c := range [][2]string{{"g", "d1"}, {"other", "d2"}} {
			if _, err := s.SyncExtractionJobs(ctx, c[0], c[1], "v1", []store.JobSpec{{WindowIdx: 0, WindowHash: "h", FirstChunk: 0, ChunkCount: 1}}); err != nil {
				t.Fatal(err)
			}
		}
		// a job claimed before the schema appears
		first, ok, err := s.ClaimJob(ctx, time.Minute)
		if err != nil || !ok {
			t.Fatalf("%v %v", ok, err)
		}
		schemaColl := first.Collection
		otherColl := "other"
		if schemaColl == "other" {
			otherColl = "g"
		}
		if _, _, err := putSchema(t, ctx, s, schemaColl, 1); err != nil {
			t.Fatal(err)
		}
		if err := s.ApplyExtraction(ctx, store.ExtractionResult{Job: first.JobKey, Model: "m", PromptVersion: "v1",
			Entities: []store.ExtractedEntity{{Name: "Checkout", Type: "service", Chunks: []int{0}}}}); !errors.Is(err, store.ErrJobGone) {
			t.Fatalf("the write of an extraction checks the schema under the lock: %v", err)
		}
		if st, _ := s.GraphStats(ctx, schemaColl); st.Entities != 0 {
			t.Fatalf("nothing may be stored: %+v", st)
		}
		if err := s.FailJob(ctx, first.JobKey, "released", 0, false); err != nil { // give the lease back, as a worker that gave up would
			t.Fatal(err)
		}
		// the other collection's job is claimed, the schema collection's is not
		j, ok, err := s.ClaimJob(ctx, time.Minute)
		if err != nil || !ok || j.Collection != otherColl {
			t.Fatalf("claimed %+v ok=%v err=%v", j, ok, err)
		}
		if j2, ok2, _ := s.ClaimJob(ctx, time.Minute); ok2 {
			t.Fatalf("a job of a collection with a schema was claimed: %+v", j2)
		}
		if st, _ := s.GraphStats(ctx, schemaColl); st.JobsPending != 1 {
			t.Fatalf("the job stays pending: %+v", st)
		}
		if _, err := s.DeleteGraphSchema(ctx, schemaColl); err != nil {
			t.Fatal(err)
		}
		if j3, ok3, err := s.ClaimJob(ctx, time.Millisecond); err != nil || !ok3 || j3.Collection != schemaColl {
			t.Fatalf("after the schema is deleted the job resumes: %+v ok=%v err=%v", j3, ok3, err)
		}
	})

	run("schema: a schema change and fact set loads never leave a fact that breaks the stored schema", func(t *testing.T, s store.Store) {
		var wg sync.WaitGroup
		for i := 0; i < 8; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				fs := goodSet("g", fmt.Sprintf("s%d", i), "")
				if i%2 == 1 {
					fs.Entities[0].Type = "gadget"
				}
				for tries := 0; tries < 20; tries++ {
					cur, err := s.GetGraphSchema(ctx, "g")
					fs.SchemaSHA = ""
					if err == nil {
						fs.SchemaSHA = cur.SHA256
					}
					if _, err := s.ReplaceFactSet(ctx, fs); !errors.Is(err, store.ErrSchemaMoved) {
						return
					}
				}
			}(i)
		}
		wg.Add(1)
		go func() { defer wg.Done(); _, _, _ = putSchema(t, ctx, s, "g", 1) }()
		wg.Wait()
		cur, err := s.GetGraphSchema(ctx, "g")
		if errors.Is(err, store.ErrSchemaNotFound) {
			return // the change was refused because bad facts were stored first: the invariant holds trivially
		}
		if err != nil {
			t.Fatal(err)
		}
		var g store.GraphSchema
		if err := json.Unmarshal(cur.Body, &g); err != nil {
			t.Fatal(err)
		}
		_ = g.Compile()
		infos, _ := s.ListFactSets(ctx, "g")
		for _, in := range infos {
			fs, err := s.GetFactSet(ctx, "g", in.ID)
			if err != nil {
				t.Fatal(err)
			}
			if v := store.CheckFactSet(&g, fs); len(v) != 0 {
				t.Fatalf("the fact set %s breaks the stored schema: %+v", in.ID, v)
			}
		}
	})
}
