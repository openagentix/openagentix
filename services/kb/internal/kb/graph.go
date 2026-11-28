package kb

import (
	"context"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/openagentix/openagentix/services/kb/internal/store"
)

// Graph query limits. Every graph answer is bounded in the number of paths,
// supporting passages and the text of each, so a hub entity cannot produce an
// answer a small model cannot read.
const (
	DefaultGraphHops    = 2
	MaxGraphPaths       = 10
	MaxGraphChunks      = 6
	MaxGraphChunkChars  = 600
	MaxGraphEvidence    = 200
	MaxGraphNeighbours  = 25
	MaxGraphNameChars   = 200
	maxCandidates       = 5
	graphSeedFetchLimit = 20
)

// GraphEdge is one fact: Subject -Predicate-> Object, with the chunk it was
// extracted from, or, when Curated, the fact set an operator wrote it in
// (FactsetID; DocumentID is then empty and Evidence is the operator's note).
// Forward is true when a path walked the edge from Subject to Object and false
// when it walked it backwards.
type GraphEdge struct {
	Subject    string `json:"subject"`
	Predicate  string `json:"predicate"`
	Object     string `json:"object"`
	Forward    bool   `json:"forward"`
	DocumentID string `json:"document_id"`
	ChunkIndex int    `json:"chunk_index"`
	Curated    bool   `json:"curated,omitempty"`
	FactsetID  string `json:"factset_id,omitempty"`
	SourceURI  string `json:"source_uri"`
	Evidence   string `json:"evidence"`
}

// GraphPath is a walk through the graph: len(Entities) == len(Edges)+1.
type GraphPath struct {
	Collection string      `json:"collection"`
	Entities   []string    `json:"entities"`
	Edges      []GraphEdge `json:"edges"`
}

// GraphChunk is a passage that supports an edge of a returned path.
type GraphChunk struct {
	Collection string `json:"collection"`
	DocumentID string `json:"document_id"`
	ChunkIndex int    `json:"chunk_index"`
	SourceURI  string `json:"source_uri"`
	Text       string `json:"text"`
}

// GraphSeed is an entity a search started from.
type GraphSeed struct {
	Collection string `json:"collection"`
	Name       string `json:"name"`
	Type       string `json:"type"`
}

// GraphCandidate describes an entity a name could refer to.
type GraphCandidate struct {
	Collection  string `json:"collection"`
	Name        string `json:"name"`
	Type        string `json:"type"`
	Description string `json:"description,omitempty"`
}

// GraphSearchResult is the answer of GraphSearch.
type GraphSearchResult struct {
	Hops      int          `json:"hops"`
	Seeds     []GraphSeed  `json:"seeds"`
	Paths     []GraphPath  `json:"paths"`
	Chunks    []GraphChunk `json:"chunks"`
	Truncated bool         `json:"truncated"`
	// HopLimited is true when a returned path is as long as the hop limit, so
	// the graph may continue past its last entity.
	HopLimited bool `json:"hop_limited"`
}

// GraphEntityResult is the answer of GraphEntity. When Found is false either
// Candidates lists several entities the name could mean, or none exists.
type GraphEntityResult struct {
	Query       string           `json:"query"`
	Found       bool             `json:"found"`
	Collection  string           `json:"collection,omitempty"`
	Name        string           `json:"name,omitempty"`
	Type        string           `json:"type,omitempty"`
	Description string           `json:"description,omitempty"`
	Aliases     []string         `json:"aliases"`
	Neighbours  []GraphEdge      `json:"neighbours"`
	Candidates  []GraphCandidate `json:"candidates"`
	Truncated   bool             `json:"truncated"`
}

// GraphPathsResult is the answer of GraphPaths. At most one of MissingEntity,
// SameEntity, Candidates and NoPath explains an empty Paths.
type GraphPathsResult struct {
	From          string           `json:"from"`
	To            string           `json:"to"`
	MaxHops       int              `json:"max_hops"`
	Paths         []GraphPath      `json:"paths"`
	Chunks        []GraphChunk     `json:"chunks"`
	MissingEntity string           `json:"missing_entity,omitempty"`
	SameEntity    bool             `json:"same_entity,omitempty"`
	Candidates    []GraphCandidate `json:"candidates"`
	NoPath        bool             `json:"no_path,omitempty"`
}

// GraphEnabled reports whether graph queries are available.
func (s *Service) GraphEnabled() bool { return s.Graph != nil }

func (s *Service) graphGuard() error {
	if s.Graph == nil {
		return invalid("the knowledge graph is not enabled")
	}
	return nil
}

func (s *Service) maxHops() int {
	if h := s.Graph.MaxHops; h > 0 {
		return min(h, store.MaxHops)
	}
	return store.MaxHops
}

// clampHops maps a requested hop count to 1..maxHops; zero selects the default.
func (s *Service) clampHops(h int) int {
	if h <= 0 {
		h = DefaultGraphHops
	}
	return max(1, min(h, s.maxHops()))
}

func validateName(field, v string) (string, error) {
	v = strings.TrimSpace(v)
	if v == "" {
		return "", invalid("%s must not be empty", field)
	}
	if !utf8.ValidString(v) || strings.ContainsRune(v, 0) || utf8.RuneCountInString(v) > MaxGraphNameChars {
		return "", invalid("%s must be valid text of at most %d characters", field, MaxGraphNameChars)
	}
	return v, nil
}

// graphCollections returns the collections to query: the named one, or all.
// Inside a limited scope a named collection outside the list yields no
// collection at all, which every graph tool answers as it answers a collection
// that does not exist, and "all" means the scope's existing collections.
func (s *Service) graphCollections(ctx context.Context, collection string) ([]string, error) {
	sc := ScopeFrom(ctx)
	if collection != "" {
		if err := ValidateCollection(collection); err != nil {
			return nil, err
		}
		if !sc.Allows(collection) {
			return nil, nil
		}
		return []string{collection}, nil
	}
	infos, err := s.Collections(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]string, len(infos))
	for i, c := range infos {
		out[i] = c.Name
	}
	return out, nil
}

func truncRunes(s string, n int) string {
	s = strings.Join(strings.Fields(s), " ")
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n]) + "…"
}

func toEdge(st store.Step, ents []store.Entity, i int) GraphEdge {
	subj, obj := ents[i], ents[i+1]
	if !st.Forward {
		subj, obj = obj, subj
	}
	return GraphEdge{
		Subject: subj.Name, Predicate: st.Edge.Predicate, Object: obj.Name, Forward: st.Forward,
		DocumentID: st.Cite.DocumentID, ChunkIndex: st.Cite.ChunkIndex, Curated: st.Cite.FactsetID != "", FactsetID: st.Cite.FactsetID,
		SourceURI: st.Cite.SourceURI, Evidence: truncRunes(st.Edge.Evidence, MaxGraphEvidence),
	}
}

func toPath(coll string, p store.Path) GraphPath {
	gp := GraphPath{Collection: coll, Entities: make([]string, len(p.Entities)), Edges: make([]GraphEdge, len(p.Steps))}
	for i, e := range p.Entities {
		gp.Entities[i] = e.Name
	}
	for i, st := range p.Steps {
		gp.Edges[i] = toEdge(st, p.Entities, i)
	}
	return gp
}

// supportingChunks returns the distinct chunks the edges of the paths cite, in
// the order of first use, bounded in number and size.
func (s *Service) supportingChunks(ctx context.Context, paths []GraphPath) ([]GraphChunk, error) {
	out := []GraphChunk{}
	type dk struct{ coll, doc string }
	type ck struct {
		dk
		idx int
	}
	seen := map[ck]bool{}
	docs := map[dk][]string{}
	for _, p := range paths {
		for _, e := range p.Edges {
			if e.Curated {
				continue // a curated fact has a note, not a passage
			}
			k := ck{dk{p.Collection, e.DocumentID}, e.ChunkIndex}
			if seen[k] || len(out) >= MaxGraphChunks {
				continue
			}
			seen[k] = true
			chunks, ok := docs[k.dk]
			if !ok {
				var err error
				if chunks, err = s.Store.DocumentChunks(ctx, p.Collection, e.DocumentID); err != nil {
					if ctx.Err() != nil {
						return nil, err
					}
					continue // the document is gone; its edge is simply unsupported
				}
				docs[k.dk] = chunks
			}
			if e.ChunkIndex < 0 || e.ChunkIndex >= len(chunks) {
				continue
			}
			out = append(out, GraphChunk{
				Collection: p.Collection, DocumentID: e.DocumentID, ChunkIndex: e.ChunkIndex,
				SourceURI: e.SourceURI, Text: truncRunes(chunks[e.ChunkIndex], MaxGraphChunkChars),
			})
		}
	}
	return out, nil
}

// Seed selection. A seed is an entity a search starts from.
//
// Names that occur in the question come first: they are what the asker meant.
// An embedding match is a guess about meaning and, for a short entity name
// against a whole question, a weak one: it turned "network outage" and "on-call
// engineer" into seeds for a question about a named region. So an embedding-only
// seed is added only
//   - when its similarity is at least SeedEmbeddingStrong, or
//   - while there are fewer than SeedLexicalTarget seeds and its similarity is at
//     least SeedEmbeddingFloor.
//
// The values are cosine similarities of the gateway's embeddings; tune them with
// the real model.
const (
	SeedLexicalTarget   = 3
	SeedEmbeddingFloor  = 0.5
	SeedEmbeddingStrong = 0.8
)

// seed is a chosen start entity with the score that chose it: the name score
// (0.45 to 1) for a name match, the cosine similarity for an embedding match.
type seed struct {
	Entity  store.Entity
	Score   float64
	Lexical bool
}

// selectSeeds applies the rule above to the name hits and the embedding hits of
// one collection and returns at most topK seeds, best first.
func selectSeeds(byName, byEmb []store.EntityHit, topK int) []seed {
	byScore := func(hs []store.EntityHit) []store.EntityHit {
		hs = slices.Clone(hs)
		slices.SortStableFunc(hs, func(a, b store.EntityHit) int {
			switch {
			case a.Score > b.Score:
				return -1
			case a.Score < b.Score:
				return 1
			}
			return int(a.Entity.ID - b.Entity.ID)
		})
		return hs
	}
	var out []seed
	seen := map[int64]bool{}
	for _, h := range byScore(byName) {
		// An entity that is only generic words and merely occurs inside the question ("database") says nothing about it.
		if seen[h.Entity.ID] || len(out) >= topK || (h.Score < 1 && store.IsGenericOnly(h.Entity.Name)) {
			continue
		}
		seen[h.Entity.ID] = true
		out = append(out, seed{h.Entity, h.Score, true})
	}
	for _, h := range byScore(byEmb) {
		if seen[h.Entity.ID] || len(out) >= topK {
			continue
		}
		if h.Score >= SeedEmbeddingStrong || (len(out) < SeedLexicalTarget && h.Score >= SeedEmbeddingFloor) {
			seen[h.Entity.ID] = true
			out = append(out, seed{h.Entity, h.Score, false})
		}
	}
	return out
}

// cand is a chain of facts that could be returned: a path that starts at a seed.
type cand struct {
	Coll      string
	Path      store.Path
	SeedScore float64
}

func (c cand) edgeIDs() []int64 {
	ids := make([]int64, len(c.Path.Steps))
	for i, st := range c.Path.Steps {
		ids[i] = st.Edge.ID
	}
	return ids
}

// documents is the number of distinct sources the chain draws on: a fact set
// counts as one, however many of its facts the chain uses.
func (c cand) documents() int {
	docs := map[string]bool{}
	for _, st := range c.Path.Steps {
		docs[st.Cite.Source()] = true
	}
	return len(docs)
}

func lessIDs(a, b []int64) bool {
	for i := 0; i < len(a) && i < len(b); i++ {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return len(a) < len(b)
}

// rankChains keeps the most useful chains, at most limit.
//
//  1. Maximal chains only: a chain that is a stretch of a longer candidate (from
//     either end, so also a prefix or the same walk read backwards) adds nothing.
//  2. Rank: chains that join facts from more distinct documents first, since a
//     multi-hop question is answered by facts no single document states; then
//     longer chains; then the score of the seed they start from; then, so that
//     the order never depends on how the store happened to list them, the
//     collection and the edge ids.
//  3. No seed takes more than its share of the slots (limit divided by the number
//     of seeds that have chains, rounded up); slots a seed leaves unused go to the
//     best chains left.
//
// The result is in rank order.
func rankChains(cands []cand, limit int) []cand {
	out, _ := rankAll(cands, limit)
	return out
}

// rankAll is rankChains that also reports how many maximal chains there were
// before the limit was applied.
func rankAll(cands []cand, limit int) ([]cand, int) {
	if len(cands) == 0 || limit <= 0 {
		return nil, 0
	}
	key := func(coll string, ids []int64) string { return coll + "|" + idKey(ids) }
	canon := func(coll string, ids []int64) string {
		rev := slices.Clone(ids)
		slices.Reverse(rev)
		return min(key(coll, ids), key(coll, rev))
	}
	inside := map[string]bool{} // every shorter stretch of every candidate, in either direction
	for _, c := range cands {
		ids := c.edgeIDs()
		for n := 1; n < len(ids); n++ {
			for i := 0; i+n <= len(ids); i++ {
				inside[canon(c.Coll, ids[i:i+n])] = true
			}
		}
	}
	// The same walk from two seeds (or read backwards) is kept once, from the better seed, whatever the input order.
	ordered := slices.Clone(cands)
	slices.SortStableFunc(ordered, func(a, b cand) int {
		switch {
		case a.SeedScore != b.SeedScore:
			if a.SeedScore > b.SeedScore {
				return -1
			}
			return 1
		case lessIDs(a.edgeIDs(), b.edgeIDs()):
			return -1
		case lessIDs(b.edgeIDs(), a.edgeIDs()):
			return 1
		}
		return 0
	})
	var keep []cand
	seen := map[string]bool{}
	for _, c := range ordered {
		k := canon(c.Coll, c.edgeIDs())
		if inside[k] || seen[k] {
			continue
		}
		seen[k] = true
		keep = append(keep, c)
	}
	slices.SortStableFunc(keep, func(a, b cand) int {
		switch {
		case a.documents() != b.documents():
			return b.documents() - a.documents()
		case len(a.Path.Steps) != len(b.Path.Steps):
			return len(b.Path.Steps) - len(a.Path.Steps)
		case a.SeedScore != b.SeedScore:
			if a.SeedScore > b.SeedScore {
				return -1
			}
			return 1
		case a.Coll != b.Coll:
			return strings.Compare(a.Coll, b.Coll)
		case lessIDs(a.edgeIDs(), b.edgeIDs()):
			return -1
		case lessIDs(b.edgeIDs(), a.edgeIDs()):
			return 1
		}
		return 0
	})
	type sk struct {
		coll string
		id   int64
	}
	seeds := map[sk]int{}
	for _, c := range keep {
		seeds[sk{c.Coll, c.Path.Entities[0].ID}]++
	}
	share := (limit + len(seeds) - 1) / len(seeds)
	taken := map[sk]int{}
	chosen := make([]bool, len(keep))
	n := 0
	for i, c := range keep {
		k := sk{c.Coll, c.Path.Entities[0].ID}
		if n < limit && taken[k] < share {
			chosen[i], taken[k], n = true, taken[k]+1, n+1
		}
	}
	for i := range keep {
		if n < limit && !chosen[i] {
			chosen[i], n = true, n+1
		}
	}
	var out []cand
	for i, c := range keep {
		if chosen[i] {
			out = append(out, c)
		}
	}
	return out, len(keep)
}

// GraphSearch finds the entities a question is about, by name and by the
// embedding of the question (see selectSeeds), and returns the best chains of up
// to hops edges around them (see rankChains) with their citations and the
// passages that support them.
func (s *Service) GraphSearch(ctx context.Context, query, collection string, hops, topK int) (GraphSearchResult, error) {
	if err := s.graphGuard(); err != nil {
		return GraphSearchResult{}, err
	}
	query = strings.TrimSpace(query)
	if query == "" {
		return GraphSearchResult{}, invalid("query must not be empty")
	}
	if utf8.RuneCountInString(query) > MaxQueryChars {
		return GraphSearchResult{}, invalid("query longer than %d characters", MaxQueryChars)
	}
	if topK <= 0 {
		topK = DefaultTopK
	}
	topK = min(topK, MaxTopK)
	colls, err := s.graphCollections(ctx, collection)
	if err != nil {
		return GraphSearchResult{}, err
	}
	res := GraphSearchResult{Hops: s.clampHops(hops), Seeds: []GraphSeed{}, Paths: []GraphPath{}, Chunks: []GraphChunk{}}
	var emb []float32
	if s.Embedder.Dimensions() > 0 {
		if v, err := s.embedQuery(ctx, query); err != nil {
			s.Log.Warn("query embedding failed; seeding the graph search by name only", "err", err)
		} else {
			emb = v
		}
	}
	var cands []cand
	for _, coll := range colls {
		seeds, err := s.graphSeeds(ctx, coll, query, emb, topK)
		if err != nil {
			return GraphSearchResult{}, err
		}
		for _, sd := range seeds {
			res.Seeds = append(res.Seeds, GraphSeed{Collection: coll, Name: sd.Entity.Name, Type: sd.Entity.Type})
			// One expansion per seed, so that the limit of one cannot use up the room of another.
			paths, err := s.Store.Expand(ctx, store.ExpandQuery{Collection: coll, SeedIDs: []int64{sd.Entity.ID}, Hops: res.Hops, Limit: store.MaxPathLimit, FanOut: s.Graph.FanOut, LongestFirst: true})
			if err != nil {
				return GraphSearchResult{}, err
			}
			for _, p := range paths {
				cands = append(cands, cand{Coll: coll, Path: p, SeedScore: sd.Score})
			}
		}
	}
	ranked, total := rankAll(cands, MaxGraphPaths)
	res.Truncated = total > len(ranked)
	for _, c := range ranked {
		res.Paths = append(res.Paths, toPath(c.Coll, c.Path))
	}
	for _, p := range res.Paths {
		res.HopLimited = res.HopLimited || len(p.Edges) >= res.Hops
	}
	if res.Chunks, err = s.supportingChunks(ctx, res.Paths); err != nil {
		return GraphSearchResult{}, err
	}
	return res, nil
}

// graphSeeds fetches the name and embedding matches of one collection and
// selects the seeds.
func (s *Service) graphSeeds(ctx context.Context, coll, query string, emb []float32, topK int) ([]seed, error) {
	byName, err := s.Store.FindEntitiesByName(ctx, coll, query, min(topK, graphSeedFetchLimit))
	if err != nil {
		return nil, err
	}
	var byEmb []store.EntityHit
	if len(emb) > 0 {
		if byEmb, err = s.Store.FindEntitiesByEmbedding(ctx, coll, emb, min(topK, graphSeedFetchLimit)); err != nil {
			return nil, err
		}
	}
	return selectSeeds(byName, byEmb, topK), nil
}

func idKey(ids []int64) string {
	parts := make([]string, len(ids))
	for i, id := range ids {
		parts[i] = strconv.FormatInt(id, 10)
	}
	return strings.Join(parts, ",")
}

// resolve returns the entities a name refers to in one collection: those whose
// match score is within 0.1 of the best (an exact name is far ahead of a partial
// match, two partial matches are about level). More than one means the name is
// ambiguous.
func (s *Service) resolve(ctx context.Context, coll, name string) ([]store.Entity, error) {
	hits, err := s.Store.FindEntitiesByName(ctx, coll, name, maxCandidates+1)
	if err != nil || len(hits) == 0 {
		return nil, err
	}
	var out []store.Entity
	for _, h := range hits {
		if h.Score >= hits[0].Score-0.1 {
			out = append(out, h.Entity)
		}
	}
	return out, nil
}

func candidates(es []store.Entity) []GraphCandidate {
	out := make([]GraphCandidate, 0, len(es))
	for _, e := range es {
		if len(out) < maxCandidates {
			out = append(out, GraphCandidate{Collection: e.Collection, Name: e.Name, Type: e.Type, Description: truncRunes(e.Description, MaxGraphEvidence)})
		}
	}
	return out
}

// GraphEntity describes the entity a name refers to and its direct neighbours.
func (s *Service) GraphEntity(ctx context.Context, name, collection string) (GraphEntityResult, error) {
	if err := s.graphGuard(); err != nil {
		return GraphEntityResult{}, err
	}
	name, err := validateName("name", name)
	if err != nil {
		return GraphEntityResult{}, err
	}
	colls, err := s.graphCollections(ctx, collection)
	if err != nil {
		return GraphEntityResult{}, err
	}
	res := GraphEntityResult{Query: name, Aliases: []string{}, Neighbours: []GraphEdge{}, Candidates: []GraphCandidate{}}
	var matches []store.Entity
	for _, coll := range colls {
		es, err := s.resolve(ctx, coll, name)
		if err != nil {
			return GraphEntityResult{}, err
		}
		matches = append(matches, es...)
	}
	switch {
	case len(matches) == 0:
		return res, nil
	case len(matches) > 1:
		res.Candidates = candidates(matches)
		return res, nil
	}
	e := matches[0]
	res.Found, res.Collection, res.Name, res.Type, res.Description = true, e.Collection, e.Name, e.Type, e.Description
	if e.Aliases != nil {
		res.Aliases = e.Aliases
	}
	paths, err := s.Store.Expand(ctx, store.ExpandQuery{Collection: e.Collection, SeedIDs: []int64{e.ID}, Hops: 1, Limit: MaxGraphNeighbours + 1, FanOut: s.Graph.FanOut})
	if err != nil {
		return GraphEntityResult{}, err
	}
	if len(paths) > MaxGraphNeighbours {
		paths, res.Truncated = paths[:MaxGraphNeighbours], true
	}
	for _, p := range paths {
		res.Neighbours = append(res.Neighbours, toEdge(p.Steps[0], p.Entities, 0))
	}
	return res, nil
}

// GraphPaths returns the shortest paths between two named entities.
func (s *Service) GraphPaths(ctx context.Context, from, to, collection string, maxHops int) (GraphPathsResult, error) {
	if err := s.graphGuard(); err != nil {
		return GraphPathsResult{}, err
	}
	from, err := validateName("from", from)
	if err != nil {
		return GraphPathsResult{}, err
	}
	if to, err = validateName("to", to); err != nil {
		return GraphPathsResult{}, err
	}
	colls, err := s.graphCollections(ctx, collection)
	if err != nil {
		return GraphPathsResult{}, err
	}
	res := GraphPathsResult{From: from, To: to, MaxHops: s.clampHops(maxHops), Paths: []GraphPath{}, Chunks: []GraphChunk{}, Candidates: []GraphCandidate{}}
	var foundFrom, foundTo, same bool
	var ambiguous []store.Entity
	for _, coll := range colls {
		fs, err := s.resolve(ctx, coll, from)
		if err != nil {
			return GraphPathsResult{}, err
		}
		ts, err := s.resolve(ctx, coll, to)
		if err != nil {
			return GraphPathsResult{}, err
		}
		foundFrom, foundTo = foundFrom || len(fs) > 0, foundTo || len(ts) > 0
		switch {
		case len(fs) == 0 || len(ts) == 0:
		case len(fs) > 1 || len(ts) > 1:
			if len(fs) > 1 {
				ambiguous = append(ambiguous, fs...)
			}
			if len(ts) > 1 {
				ambiguous = append(ambiguous, ts...)
			}
		case fs[0].ID == ts[0].ID:
			same = true
		default:
			paths, err := s.Store.ShortestPaths(ctx, store.PathQuery{Collection: coll, FromID: fs[0].ID, ToID: ts[0].ID, MaxHops: res.MaxHops, Limit: MaxGraphPaths, FanOut: s.Graph.FanOut})
			if err != nil {
				return GraphPathsResult{}, err
			}
			for _, p := range paths {
				res.Paths = append(res.Paths, toPath(coll, p))
			}
		}
	}
	if len(res.Paths) > MaxGraphPaths {
		res.Paths = res.Paths[:MaxGraphPaths]
	}
	switch {
	case len(res.Paths) > 0:
		if res.Chunks, err = s.supportingChunks(ctx, res.Paths); err != nil {
			return GraphPathsResult{}, err
		}
	case len(ambiguous) > 0:
		res.Candidates = candidates(ambiguous)
	case !foundFrom:
		res.MissingEntity = from
	case !foundTo:
		res.MissingEntity = to
	case same:
		res.SameEntity = true
	default:
		res.NoPath = true
	}
	return res, nil
}

// HopsText renders a hop count for messages: "1 hop", "3 hops".
func HopsText(n int) string {
	if n == 1 {
		return "1 hop"
	}
	return fmt.Sprintf("%d hops", n)
}

// GraphStats counts the graph rows and extraction jobs of a collection. It
// never returns document content.
func (s *Service) GraphStats(ctx context.Context, collection string) (store.GraphStats, error) {
	if err := s.graphGuard(); err != nil {
		return store.GraphStats{}, err
	}
	if err := ValidateCollection(collection); err != nil {
		return store.GraphStats{}, err
	}
	return s.Store.GraphStats(ctx, collection)
}
