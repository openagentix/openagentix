package kb

import (
	"context"
	"errors"
	"reflect"
	"testing"

	"github.com/openagentix/openagentix/services/kb/internal/store"
)

func mineOnly(ctx context.Context) context.Context {
	return WithScope(ctx, store.Scope{Limited: true, Collections: []string{"mine"}})
}

// scopedSvc holds the same two facts and the same document id in two collections.
func scopedSvc(t *testing.T) *Service {
	t.Helper()
	s := graphSvc()
	ctx := context.Background()
	for _, coll := range []string{"mine", "theirs"} {
		if _, err := s.Put(ctx, coll, "doc", DocInput{Title: "T " + coll, Text: "pelican harbour notes of " + coll}); err != nil {
			t.Fatal(err)
		}
		fs := store.FactSet{
			SourceURI: "https://example.test/c",
			Entities:  []store.FactEntity{{Name: "Orion", Type: "service"}, {Name: "Basalt", Type: "team"}},
			Relations: []store.FactRelation{{Source: "Basalt", Predicate: "owns", Target: "Orion", Note: "Basalt owns Orion"}},
		}
		if _, err := s.PutFactSet(ctx, coll, "org", fs); err != nil {
			t.Fatal(err)
		}
	}
	return s
}

func TestScopeCollectionsAndSearch(t *testing.T) {
	s := scopedSvc(t)
	ctx := mineOnly(context.Background())
	cols, err := s.Collections(ctx)
	if err != nil || len(cols) != 1 || cols[0].Name != "mine" {
		t.Fatalf("%+v %v", cols, err)
	}
	hits, err := s.Search(ctx, "pelican", "", 10)
	if err != nil || len(hits) != 1 || hits[0].Collection != "mine" {
		t.Fatalf("no collection must search only the caller's: %+v %v", hits, err)
	}
	out, errOut := s.Search(ctx, "pelican", "theirs", 10)
	missing, errMissing := s.Search(ctx, "pelican", "absent", 10)
	if errOut != nil || errMissing != nil || !reflect.DeepEqual(out, missing) || len(out) != 0 {
		t.Fatalf("outside=%+v/%v missing=%+v/%v", out, errOut, missing, errMissing)
	}
	// Without a scope nothing changes.
	if all, _ := s.Search(context.Background(), "pelican", "", 10); len(all) != 2 {
		t.Fatalf("unscoped: %+v", all)
	}
}

func TestScopeGet(t *testing.T) {
	s := scopedSvc(t)
	ctx := mineOnly(context.Background())
	v, err := s.Get(ctx, "", "doc")
	if err != nil || v.Collection != "mine" {
		t.Fatalf("an id in two collections is not ambiguous when only one is allowed: %+v %v", v, err)
	}
	_, errOut := s.Get(ctx, "theirs", "doc")
	_, errMissing := s.Get(ctx, "absent", "doc")
	if !errors.Is(errOut, store.ErrNotFound) || errOut.Error() != errMissing.Error() {
		t.Fatalf("outside=%v missing=%v", errOut, errMissing)
	}
	if _, err := s.Get(context.Background(), "", "doc"); !errors.Is(err, store.ErrAmbiguous) {
		t.Fatalf("unscoped must stay ambiguous: %v", err)
	}
}

func TestScopeGraphToolsAnswerOutsideLikeMissing(t *testing.T) {
	s := scopedSvc(t)
	ctx := mineOnly(context.Background())

	e, err := s.GraphEntity(ctx, "Orion", "")
	if err != nil || !e.Found || e.Collection != "mine" || len(e.Candidates) != 0 {
		t.Fatalf("a name in two collections is unique in the caller's: %+v %v", e, err)
	}
	if all, _ := s.GraphEntity(context.Background(), "Orion", ""); all.Found || len(all.Candidates) != 2 {
		t.Fatalf("unscoped must list both candidates: %+v", all)
	}
	eOut, _ := s.GraphEntity(ctx, "Orion", "theirs")
	eMissing, _ := s.GraphEntity(ctx, "Orion", "absent")
	if !reflect.DeepEqual(eOut, eMissing) || eOut.Found {
		t.Fatalf("entity: outside=%+v missing=%+v", eOut, eMissing)
	}

	p, err := s.GraphPaths(ctx, "Basalt", "Orion", "", 2)
	if err != nil || len(p.Paths) != 1 || p.Paths[0].Collection != "mine" {
		t.Fatalf("%+v %v", p, err)
	}
	pOut, _ := s.GraphPaths(ctx, "Basalt", "Orion", "theirs", 2)
	pMissing, _ := s.GraphPaths(ctx, "Basalt", "Orion", "absent", 2)
	if !reflect.DeepEqual(pOut, pMissing) || len(pOut.Paths) != 0 {
		t.Fatalf("paths: outside=%+v missing=%+v", pOut, pMissing)
	}

	g, err := s.GraphSearch(ctx, "who owns Orion", "", 2, 5)
	if err != nil {
		t.Fatal(err)
	}
	for _, sd := range g.Seeds {
		if sd.Collection != "mine" {
			t.Fatalf("seed outside the list: %+v", sd)
		}
	}
	for _, pa := range g.Paths {
		if pa.Collection != "mine" {
			t.Fatalf("path outside the list: %+v", pa)
		}
	}
	gOut, _ := s.GraphSearch(ctx, "who owns Orion", "theirs", 2, 5)
	gMissing, _ := s.GraphSearch(ctx, "who owns Orion", "absent", 2, 5)
	if !reflect.DeepEqual(gOut, gMissing) || len(gOut.Seeds) != 0 {
		t.Fatalf("search: outside=%+v missing=%+v", gOut, gMissing)
	}
}

func TestScopeEmptyListReadsNothing(t *testing.T) {
	s := scopedSvc(t)
	ctx := WithScope(context.Background(), store.Scope{Limited: true})
	if cols, _ := s.Collections(ctx); len(cols) != 0 {
		t.Fatalf("%+v", cols)
	}
	if hits, _ := s.Search(ctx, "pelican", "", 10); len(hits) != 0 {
		t.Fatalf("%+v", hits)
	}
	if e, _ := s.GraphEntity(ctx, "Orion", ""); e.Found || len(e.Candidates) != 0 {
		t.Fatalf("%+v", e)
	}
}
