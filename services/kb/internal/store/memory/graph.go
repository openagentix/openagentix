package memory

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/openagentix/openagentix/services/kb/internal/store"
)

type ekey struct{ collection, key string }

type ent struct {
	store.Entity
	key     string // store.MergeKey
	match   string
	aliases []string // match form
	emb     []float32
}

type rkey struct {
	collection       string
	src, dst         int64
	predicate, docID string
	chunk            int
	factset          string
}

type mkey struct {
	entity int64
	docID  string
	chunk  int
}

type jobRec struct {
	store.Job
	seq          int64
	claimedUntil time.Time
	notBefore    time.Time
}

// graph is the knowledge-graph state; it is guarded by Store.mu.
type graph struct {
	nextEntity, nextRel, nextJob int64
	entities                     map[int64]*ent
	byKey                        map[ekey]int64
	relations                    map[int64]*store.Relation
	relKeys                      map[rkey]int64
	mentions                     map[mkey]string // value: collection
	jobs                         map[store.JobKey]*jobRec
	factsets                     map[fskey]*fsRec
	schemas                      map[string]*schemaRec
}

type fskey struct{ collection, id string }

// fsRec is a stored fact set: its normalised body and the entities it declares.
type fsRec struct {
	fs      store.FactSet
	hash    string
	updated time.Time
	members []int64
}

func newGraph() graph {
	return graph{
		entities: map[int64]*ent{}, byKey: map[ekey]int64{}, relations: map[int64]*store.Relation{},
		relKeys: map[rkey]int64{}, mentions: map[mkey]string{}, jobs: map[store.JobKey]*jobRec{},
		factsets: map[fskey]*fsRec{}, schemas: map[string]*schemaRec{},
	}
}

func (s *Store) DocumentChunks(_ context.Context, collection, id string) ([]string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	e, ok := s.m[key{collection, id}]
	if !ok {
		return nil, store.ErrNotFound
	}
	out := make([]string, len(e.chunks))
	for i, c := range e.chunks {
		out[i] = c.text
	}
	return out, nil
}

func (s *Store) checkEmbedding(v []float32) error {
	if len(v) > 0 && s.dim > 0 && len(v) != s.dim {
		return fmt.Errorf("name embedding has dimension %d, store expects %d", len(v), s.dim)
	}
	return nil
}

func (s *Store) UpsertEntity(_ context.Context, in store.EntityInput) (store.Entity, error) {
	if err := s.checkEmbedding(in.NameEmbedding); err != nil {
		return store.Entity{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	e, err := s.upsertEntityLocked(in)
	if err != nil {
		return store.Entity{}, err
	}
	return e.Entity, nil
}

func (s *Store) upsertEntityLocked(in store.EntityInput) (*ent, error) {
	name := strings.Join(strings.Fields(in.Name), " ")
	if in.Collection == "" || name == "" || in.Type == "" {
		return nil, errors.New("entity needs a collection, a name and a type")
	}
	g := &s.g
	mk := store.MergeKey(name, in.Type, in.DocumentID)
	k := ekey{in.Collection, mk}
	aliases := store.MatchAliases(name, in.Aliases)
	if id, ok := g.byKey[k]; ok {
		e := g.entities[id]
		// A curated entity taking over an extracted one: its name, type and
		// description win from now on (see store.EntityInput).
		takeManual := in.Origin == store.OriginManual && e.Origin != store.OriginManual
		if takeManual {
			if in.Type != e.Type {
				e.OtherTypes = unionSorted(e.OtherTypes, []string{e.Type})
				e.Type = in.Type
			}
			e.OtherTypes = slices.DeleteFunc(e.OtherTypes, func(t string) bool { return t == e.Type })
			if in.Description != "" {
				e.Description = in.Description
			}
			e.Origin = store.OriginManual
		}
		if e.Description == "" {
			e.Description = in.Description
		}
		oldMatch := e.match
		if takeManual || (e.Origin != store.OriginManual && store.BetterName(e.Name, name)) {
			e.Name, e.NormName, e.match = name, store.NormalizeName(name), store.MatchForm(name)
		}
		// every form seen is findable; the displayed one is not its own alias
		all := unionSorted(unionSorted(e.aliases, aliases), []string{store.MatchForm(name), oldMatch})
		e.aliases = slices.DeleteFunc(all, func(a string) bool { return a == "" || a == e.match })
		e.Aliases = slices.Clone(e.aliases)
		if in.Type != e.Type && !slices.Contains(e.OtherTypes, in.Type) {
			e.OtherTypes = unionSorted(e.OtherTypes, []string{in.Type})
		}
		if len(e.emb) == 0 && len(in.NameEmbedding) > 0 {
			e.emb = slices.Clone(in.NameEmbedding)
		}
		return e, nil
	}
	origin := in.Origin
	if origin == "" {
		origin = store.OriginExtracted
	}
	g.nextEntity++
	e := &ent{
		Entity: store.Entity{
			ID: g.nextEntity, Collection: in.Collection, Name: name, NormName: store.NormalizeName(name), Type: in.Type,
			Description: in.Description, Aliases: slices.Clone(aliases), Origin: origin,
		},
		key: mk, match: store.MatchForm(name), aliases: aliases, emb: slices.Clone(in.NameEmbedding),
	}
	g.entities[e.ID] = e
	g.byKey[k] = e.ID
	return e, nil
}

func unionSorted(a, b []string) []string {
	out := slices.Concat(a, b)
	sort.Strings(out)
	return slices.Compact(out)
}

func (s *Store) AddRelation(_ context.Context, r store.Relation) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.addRelationLocked(r)
}

func (s *Store) addRelationLocked(r store.Relation) (int64, error) {
	g := &s.g
	src, dst := g.entities[r.SrcID], g.entities[r.DstID]
	if src == nil || dst == nil || src.Collection != r.Collection || dst.Collection != r.Collection {
		return 0, fmt.Errorf("%w: relation endpoint is not an entity of collection %q", store.ErrNotFound, r.Collection)
	}
	if r.FactsetID != "" {
		return 0, errors.New("relations of a fact set are stored by ReplaceFactSet")
	}
	if _, ok := s.m[key{r.Collection, r.DocumentID}]; !ok {
		return 0, fmt.Errorf("%w: relation document %q", store.ErrNotFound, r.DocumentID)
	}
	if r.Predicate == "" {
		return 0, errors.New("relation needs a predicate")
	}
	k := rkey{r.Collection, r.SrcID, r.DstID, r.Predicate, r.DocumentID, r.ChunkIndex, r.FactsetID}
	if id, ok := g.relKeys[k]; ok {
		return id, nil
	}
	if r.Origin == "" {
		r.Origin = store.OriginExtracted
	}
	g.nextRel++
	r.ID = g.nextRel
	g.relations[r.ID] = &r
	g.relKeys[k] = r.ID
	return r.ID, nil
}

func (s *Store) LinkEntityChunk(_ context.Context, collection string, ec store.EntityChunk) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.linkLocked(collection, ec)
}

func (s *Store) linkLocked(collection string, ec store.EntityChunk) error {
	e := s.g.entities[ec.EntityID]
	if e == nil || e.Collection != collection {
		return fmt.Errorf("%w: entity %d in collection %q", store.ErrNotFound, ec.EntityID, collection)
	}
	if _, ok := s.m[key{collection, ec.DocumentID}]; !ok {
		return fmt.Errorf("%w: document %q", store.ErrNotFound, ec.DocumentID)
	}
	s.g.mentions[mkey{ec.EntityID, ec.DocumentID, ec.ChunkIndex}] = collection
	return nil
}

func (s *Store) DeleteDocumentGraph(_ context.Context, collection, documentID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.dropDocGraphLocked(collection, documentID)
	return nil
}

// dropDocGraphLocked removes a document's relations, mentions and jobs, then the
// extracted entities of the collection that nothing refers to.
func (s *Store) dropDocGraphLocked(collection, doc string) {
	g := &s.g
	for id, r := range g.relations {
		if r.Collection == collection && r.DocumentID == doc {
			delete(g.relKeys, rkey{r.Collection, r.SrcID, r.DstID, r.Predicate, r.DocumentID, r.ChunkIndex, r.FactsetID})
			delete(g.relations, id)
		}
	}
	for k, c := range g.mentions {
		if c == collection && k.docID == doc {
			delete(g.mentions, k)
		}
	}
	for k := range g.jobs {
		if k.Collection == collection && k.DocumentID == doc {
			delete(g.jobs, k)
		}
	}
	s.collectLocked(collection)
}

func (s *Store) collectLocked(collection string) {
	g := &s.g
	used := map[int64]bool{}
	for _, r := range g.relations {
		used[r.SrcID], used[r.DstID] = true, true
	}
	for k := range g.mentions {
		used[k.entity] = true
	}
	for id, e := range g.entities {
		if e.Collection == collection && e.Origin == store.OriginExtracted && !used[id] {
			delete(g.byKey, ekey{e.Collection, e.key})
			delete(g.entities, id)
		}
	}
}

func (s *Store) FindEntitiesByName(_ context.Context, collection, text string, limit int) ([]store.EntityHit, error) {
	q := store.MatchForm(text)
	s.mu.RLock()
	defer s.mu.RUnlock()
	var hits []store.EntityHit
	for _, e := range s.g.entities {
		if e.Collection != collection {
			continue
		}
		if sc := store.NameScore(q, e.match, e.aliases); sc > 0 {
			hits = append(hits, store.EntityHit{Entity: cloneEntity(e), Score: sc})
		}
	}
	return topHits(hits, limit), nil
}

func (s *Store) FindEntitiesByEmbedding(_ context.Context, collection string, emb []float32, limit int) ([]store.EntityHit, error) {
	if len(emb) == 0 {
		return nil, nil
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	var hits []store.EntityHit
	for _, e := range s.g.entities {
		if e.Collection != collection || len(e.emb) == 0 {
			continue
		}
		if c := cosine(emb, e.emb); c > 0 {
			hits = append(hits, store.EntityHit{Entity: cloneEntity(e), Score: c})
		}
	}
	return topHits(hits, limit), nil
}

func topHits(hits []store.EntityHit, limit int) []store.EntityHit {
	sort.Slice(hits, func(i, j int) bool {
		if hits[i].Score != hits[j].Score {
			return hits[i].Score > hits[j].Score
		}
		return hits[i].Entity.ID < hits[j].Entity.ID
	})
	if limit > 0 && len(hits) > limit {
		hits = hits[:limit]
	}
	return hits
}

func cloneEntity(e *ent) store.Entity {
	c := e.Entity
	c.Aliases = slices.Clone(e.aliases)
	c.OtherTypes = slices.Clone(e.OtherTypes)
	return c
}

type adj struct {
	rel     *store.Relation
	other   int64
	forward bool
}

// walk enumerates the simple paths of 1..hops edges from each seed. Edges are
// followed in both directions. stop, if set, ends a path at an entity.
func (s *Store) walk(collection string, seeds []int64, hops, fanOut int, stop int64) []store.Path {
	g := &s.g
	next := map[int64][]adj{}
	for _, r := range g.relations {
		if r.Collection != collection || r.SrcID == r.DstID {
			continue
		}
		next[r.SrcID] = append(next[r.SrcID], adj{r, r.DstID, true})
		next[r.DstID] = append(next[r.DstID], adj{r, r.SrcID, false})
	}
	for id, as := range next {
		slices.SortFunc(as, func(a, b adj) int { return int(a.rel.ID - b.rel.ID) })
		if len(as) > fanOut {
			next[id] = as[:fanOut]
		}
	}
	var out []store.Path
	var nodes []int64
	var steps []adj
	var rec func()
	rec = func() {
		last := nodes[len(nodes)-1]
		if len(steps) > 0 {
			out = append(out, s.buildPath(nodes, steps))
		}
		if len(steps) == hops || (stop != 0 && last == stop) {
			return
		}
		for _, a := range next[last] {
			if slices.Contains(nodes, a.other) {
				continue
			}
			nodes, steps = append(nodes, a.other), append(steps, a)
			rec()
			nodes, steps = nodes[:len(nodes)-1], steps[:len(steps)-1]
		}
	}
	seen := map[int64]bool{}
	for _, id := range seeds {
		if e := g.entities[id]; e == nil || e.Collection != collection || seen[id] {
			continue
		}
		seen[id] = true
		nodes, steps = []int64{id}, nil
		rec()
	}
	return out
}

func (s *Store) buildPath(nodes []int64, steps []adj) store.Path {
	p := store.Path{Entities: make([]store.Entity, len(nodes)), Steps: make([]store.Step, len(steps))}
	for i, id := range nodes {
		p.Entities[i] = cloneEntity(s.g.entities[id])
	}
	for i, a := range steps {
		r := *a.rel
		uri := ""
		if r.FactsetID != "" {
			if f := s.g.factsets[fskey{r.Collection, r.FactsetID}]; f != nil {
				uri = f.fs.SourceURI
			}
		} else if e := s.m[key{r.Collection, r.DocumentID}]; e != nil {
			uri = e.doc.SourceURI
		}
		p.Steps[i] = store.Step{Edge: r, Forward: a.forward, Cite: store.Citation{DocumentID: r.DocumentID, ChunkIndex: r.ChunkIndex, FactsetID: r.FactsetID, SourceURI: uri}}
	}
	return p
}

func (s *Store) Expand(_ context.Context, q store.ExpandQuery) ([]store.Path, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	ps := s.walk(q.Collection, q.SeedIDs, store.ClampHops(q.Hops), store.ClampFanOut(q.FanOut), 0)
	store.SortPaths(ps)
	if q.LongestFirst {
		slices.SortStableFunc(ps, func(a, b store.Path) int { return len(b.Steps) - len(a.Steps) })
	}
	if lim := store.ClampLimit(q.Limit); len(ps) > lim {
		ps = ps[:lim]
	}
	return ps, nil
}

func (s *Store) ShortestPaths(_ context.Context, q store.PathQuery) ([]store.Path, error) {
	if q.FromID == q.ToID {
		return nil, nil
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	var found []store.Path
	for _, p := range s.walk(q.Collection, []int64{q.FromID}, store.ClampHops(q.MaxHops), store.ClampFanOut(q.FanOut), q.ToID) {
		if p.Entities[len(p.Entities)-1].ID == q.ToID {
			found = append(found, p)
		}
	}
	store.SortPaths(found)
	if len(found) > 0 {
		n := len(found[0].Steps)
		found = found[:sort.Search(len(found), func(i int) bool { return len(found[i].Steps) > n })]
	}
	if lim := store.ClampLimit(q.Limit); len(found) > lim {
		found = found[:lim]
	}
	return found, nil
}

func (s *Store) GraphStats(_ context.Context, collection string) (store.GraphStats, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var st store.GraphStats
	for _, e := range s.g.entities {
		if e.Collection == collection {
			st.Entities++
			if e.Origin == store.OriginManual {
				st.ManualEntities++
			}
		}
	}
	for _, r := range s.g.relations {
		if r.Collection == collection {
			st.Relations++
			if r.Origin == store.OriginManual {
				st.ManualRelations++
			}
		}
	}
	for k := range s.g.factsets {
		if k.collection == collection {
			st.FactSets++
		}
	}
	for _, c := range s.g.mentions {
		if c == collection {
			st.Mentions++
		}
	}
	var lastErrAt time.Time
	for k, j := range s.g.jobs {
		if k.Collection != collection {
			continue
		}
		if j.State != store.JobDone && j.LastErrorCode != "" && !j.UpdatedAt.Before(lastErrAt) {
			st.LastErrorCode, lastErrAt = j.LastErrorCode, j.UpdatedAt
		}
		switch j.State {
		case store.JobPending:
			st.JobsPending++
		case store.JobDone:
			st.JobsDone++
		case store.JobFailed:
			st.JobsFailed++
		}
	}
	return st, nil
}

func (s *Store) SyncExtractionJobs(_ context.Context, collection, documentID, promptVersion string, specs []store.JobSpec) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.m[key{collection, documentID}]; !ok {
		return 0, fmt.Errorf("%w: document %q", store.ErrNotFound, documentID)
	}
	g := &s.g
	var existing []*jobRec
	for k, j := range g.jobs {
		if k.Collection == collection && k.DocumentID == documentID {
			existing = append(existing, j)
		}
	}
	sort.Slice(existing, func(i, j int) bool { return existing[i].WindowIdx < existing[j].WindowIdx })
	same := len(existing) == len(specs)
	for i := 0; same && i < len(specs); i++ {
		j, sp := existing[i], specs[i]
		same = j.WindowIdx == sp.WindowIdx && j.WindowHash == sp.WindowHash && j.FirstChunk == sp.FirstChunk &&
			j.ChunkCount == sp.ChunkCount && j.PromptVersion == promptVersion
	}
	if same {
		n := 0
		for _, j := range existing {
			if j.State == store.JobFailed { // identical content: retry what failed, keep what is done
				j.State, j.Attempts, j.LastErrorCode, j.notBefore, j.claimedUntil = store.JobPending, 0, "", time.Time{}, time.Time{}
				n++
			}
		}
		return n, nil
	}
	s.dropDocGraphLocked(collection, documentID)
	for _, sp := range specs {
		g.nextJob++
		k := store.JobKey{Collection: collection, DocumentID: documentID, WindowIdx: sp.WindowIdx}
		g.jobs[k] = &jobRec{seq: g.nextJob, Job: store.Job{
			JobKey: k, WindowHash: sp.WindowHash, FirstChunk: sp.FirstChunk, ChunkCount: sp.ChunkCount,
			PromptVersion: promptVersion, State: store.JobPending, UpdatedAt: time.Now().UTC(),
		}}
	}
	return len(specs), nil
}

func (s *Store) ClaimJob(_ context.Context, lease time.Duration) (store.Job, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	var best *jobRec
	for _, j := range s.g.jobs {
		if j.State != store.JobPending || now.Before(j.claimedUntil) || now.Before(j.notBefore) {
			continue
		}
		if s.g.schemas[j.Collection] != nil {
			continue // a collection with a graph schema has curated facts only: the job waits, and resumes if the schema is deleted
		}
		if best == nil || j.seq < best.seq {
			best = j
		}
	}
	if best == nil {
		return store.Job{}, false, nil
	}
	best.Attempts++
	best.claimedUntil = now.Add(lease)
	best.UpdatedAt = now.UTC()
	return best.Job, true, nil
}

func (s *Store) FailJob(_ context.Context, key store.JobKey, code string, retryIn time.Duration, final bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	j := s.g.jobs[key]
	if j == nil || j.State != store.JobPending {
		return store.ErrJobGone
	}
	j.LastErrorCode = code
	j.UpdatedAt = time.Now().UTC()
	if final {
		j.State = store.JobFailed
		return nil
	}
	j.claimedUntil = time.Time{}
	j.notBefore = time.Now().Add(retryIn)
	return nil
}

func (s *Store) ApplyExtraction(_ context.Context, res store.ExtractionResult) error {
	for i, e := range res.Entities {
		if err := s.checkEmbedding(e.NameEmbedding); err != nil {
			return fmt.Errorf("entity %d: %w", i, err)
		}
	}
	for i, r := range res.Relations {
		if r.Src < 0 || r.Src >= len(res.Entities) || r.Dst < 0 || r.Dst >= len(res.Entities) {
			return fmt.Errorf("relation %d refers to an entity outside the result", i)
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	j := s.g.jobs[res.Job]
	if j == nil || j.State != store.JobPending {
		return store.ErrJobGone
	}
	if _, ok := s.m[key{res.Job.Collection, res.Job.DocumentID}]; !ok {
		return store.ErrJobGone
	}
	if s.g.schemas[res.Job.Collection] != nil {
		return store.ErrJobGone // the schema appeared after the job was claimed: nothing is written
	}
	coll, doc := res.Job.Collection, res.Job.DocumentID
	ids := make([]int64, len(res.Entities))
	for i, x := range res.Entities {
		e, err := s.upsertEntityLocked(store.EntityInput{
			Collection: coll, Name: x.Name, Type: x.Type, Description: x.Description, Aliases: x.Aliases, NameEmbedding: x.NameEmbedding, DocumentID: doc,
		})
		if err != nil {
			return err
		}
		ids[i] = e.ID
		for _, c := range x.Chunks {
			if err := s.linkLocked(coll, store.EntityChunk{EntityID: e.ID, DocumentID: doc, ChunkIndex: c}); err != nil {
				return err
			}
		}
	}
	for _, r := range res.Relations {
		if _, err := s.addRelationLocked(store.Relation{
			Collection: coll, SrcID: ids[r.Src], DstID: ids[r.Dst], Predicate: r.Predicate, Evidence: r.Evidence,
			DocumentID: doc, ChunkIndex: r.ChunkIndex, PromptVersion: res.PromptVersion, Model: res.Model,
		}); err != nil {
			return err
		}
	}
	j.State = store.JobDone
	j.LastErrorCode = ""
	j.UpdatedAt = time.Now().UTC()
	return nil
}

// declared reports whether any fact set of the collection other than skip
// declares the entity.
func (s *Store) declaredLocked(collection string, id int64, skip fskey) bool {
	for k, f := range s.g.factsets {
		if k.collection == collection && k != skip && slices.Contains(f.members, id) {
			return true
		}
	}
	return false
}

// dropFactSetLocked removes a fact set, its relations and its mark on entities
// no other fact set declares. Entities are not collected.
func (s *Store) dropFactSetLocked(k fskey) {
	g := &s.g
	f := g.factsets[k]
	if f == nil {
		return
	}
	for id, r := range g.relations {
		if r.Collection == k.collection && r.FactsetID == k.id {
			delete(g.relKeys, rkey{r.Collection, r.SrcID, r.DstID, r.Predicate, r.DocumentID, r.ChunkIndex, r.FactsetID})
			delete(g.relations, id)
		}
	}
	for _, id := range f.members {
		if e := g.entities[id]; e != nil && !s.declaredLocked(k.collection, id, k) {
			e.Origin = store.OriginExtracted
		}
	}
	delete(g.factsets, k)
}

func (s *Store) ReplaceFactSet(_ context.Context, fs store.FactSet) (bool, error) {
	ends, err := fs.Resolve()
	if err != nil {
		return false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	g := &s.g
	if err := s.checkFactSetLocked(fs); err != nil {
		return false, err
	}
	k := fskey{fs.Collection, fs.ID}
	hash := fs.Hash()
	if old := g.factsets[k]; old != nil && old.hash == hash {
		return false, nil
	}
	s.dropFactSetLocked(k)
	ids := make([]int64, len(fs.Entities))
	var members []int64
	for i, x := range fs.Entities {
		e, err := s.upsertEntityLocked(store.EntityInput{
			Collection: fs.Collection, Name: x.Name, Type: x.Type, Description: x.Description, Aliases: x.Aliases, Origin: store.OriginManual,
		})
		if err != nil {
			return false, err
		}
		ids[i] = e.ID
		if !slices.Contains(members, e.ID) {
			members = append(members, e.ID)
		}
	}
	g.factsets[k] = &fsRec{fs: fs.Clone(), hash: hash, updated: time.Now().UTC(), members: members}
	for i, r := range fs.Relations {
		src, dst := ids[ends[i][0]], ids[ends[i][1]]
		rk := rkey{fs.Collection, src, dst, r.Predicate, "", 0, fs.ID}
		if _, dup := g.relKeys[rk]; dup {
			continue
		}
		g.nextRel++
		g.relations[g.nextRel] = &store.Relation{
			ID: g.nextRel, Collection: fs.Collection, SrcID: src, DstID: dst, Predicate: r.Predicate, Evidence: r.Note,
			FactsetID: fs.ID, Origin: store.OriginManual,
		}
		g.relKeys[rk] = g.nextRel
	}
	s.collectLocked(fs.Collection)
	return true, nil
}

func (s *Store) GetFactSet(_ context.Context, collection, id string) (store.FactSet, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	f := s.g.factsets[fskey{collection, id}]
	if f == nil {
		return store.FactSet{}, store.ErrFactSetNotFound
	}
	out := f.fs.Clone()
	out.Collection, out.ID = collection, id
	return out, nil
}

func (s *Store) ListFactSets(_ context.Context, collection string) ([]store.FactSetInfo, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var out []store.FactSetInfo
	for k, f := range s.g.factsets {
		if k.collection == collection {
			out = append(out, store.FactSetInfo{ID: k.id, SourceURI: f.fs.SourceURI, Entities: len(f.fs.Entities), Relations: len(f.fs.Relations), UpdatedAt: f.updated})
		}
	}
	slices.SortFunc(out, func(a, b store.FactSetInfo) int { return strings.Compare(a.ID, b.ID) })
	return out, nil
}

func (s *Store) DeleteFactSet(_ context.Context, collection, id string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	k := fskey{collection, id}
	if s.g.factsets[k] == nil {
		return false, nil
	}
	s.dropFactSetLocked(k)
	s.collectLocked(collection)
	return true, nil
}
