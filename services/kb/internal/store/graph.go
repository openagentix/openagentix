package store

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

var (
	// ErrGraphDisabled is returned by graph methods of a store opened without
	// graph support.
	ErrGraphDisabled = errors.New("knowledge graph is not enabled on this store")
	// ErrJobGone is returned when an extraction result is applied to a job that
	// no longer exists or is no longer pending (its document was replaced or
	// deleted, or another worker already completed it).
	ErrJobGone = errors.New("extraction job is gone or already finished")
	// ErrFactSetNotFound is returned when a fact set does not exist.
	ErrFactSetNotFound = errors.New("fact set not found")
)

// Graph limits.
const (
	// MaxHops is the longest traversal any graph query accepts.
	MaxHops = 3
	// DefaultPathLimit and MaxPathLimit bound the number of paths returned.
	DefaultPathLimit = 50
	MaxPathLimit     = 500
	// DefaultFanOut and MaxFanOut bound how many edges a traversal follows out
	// of one entity, so a hub cannot blow a query up.
	DefaultFanOut = 25
	MaxFanOut     = 100

	OriginExtracted = "extracted"
	OriginManual    = "manual"
)

// Job states.
const (
	JobPending = "pending"
	JobDone    = "done"
	JobFailed  = "failed"
)

// NormalizeName is the merge key of an entity name: lower case, surrounding
// space trimmed, inner whitespace runs collapsed to one space.
func NormalizeName(s string) string {
	return strings.ToLower(strings.Join(strings.Fields(s), " "))
}

// Entity is a node of the knowledge graph. Entities are never shared across
// collections. Aliases are stored in MatchForm. Type is the first type the
// entity was seen with; OtherTypes are the other types it was seen with (a model
// may call one thing a service in one document and a system in another).
type Entity struct {
	ID          int64
	Collection  string
	Name        string // the displayed name; see BetterName
	NormName    string // NormalizeName(Name)
	Type        string
	OtherTypes  []string
	Description string
	Aliases     []string
	Origin      string
}

// EntityInput creates or merges an entity. The merge key is
// (Collection, MergeKey(Name, Type, DocumentID)): the canonical form of the
// name, whatever the type. On merge the existing origin and type stay, the
// displayed name becomes the more specific of the two (BetterName; never for a
// manual entity), the other form becomes an alias, an empty description is
// filled, aliases and other types are united and a missing name embedding is
// set.
type EntityInput struct {
	Collection    string
	Name          string
	Type          string
	Description   string
	Aliases       []string
	Origin        string // default OriginExtracted
	NameEmbedding []float32
	// DocumentID is the document that mentions the entity. It only matters for an
	// event whose name has no digit, which is scoped to it (see MergeKey).
	DocumentID string
}

// Relation is a directed, typed edge with the evidence it was extracted from.
// It cites exactly one source: a document chunk (DocumentID, ChunkIndex) or a
// curated fact set (FactsetID, whose Evidence is the operator's note).
type Relation struct {
	ID            int64
	Collection    string
	SrcID, DstID  int64
	Predicate     string
	Evidence      string
	DocumentID    string
	ChunkIndex    int
	FactsetID     string
	PromptVersion string
	Model         string
	Origin        string // default OriginExtracted
}

// EntityChunk records that an entity is mentioned in one chunk.
type EntityChunk struct {
	EntityID   int64
	DocumentID string
	ChunkIndex int
}

// Citation points at the chunk an edge was derived from, or, for a curated
// edge, at its fact set (DocumentID is then empty).
type Citation struct {
	DocumentID string
	ChunkIndex int
	FactsetID  string
	SourceURI  string
}

// Source names what a citation points at, so that two edges can be told to come
// from the same document or the same fact set.
func (c Citation) Source() string {
	if c.FactsetID != "" {
		return "factset:" + c.FactsetID
	}
	return "document:" + c.DocumentID
}

// Step is one traversed edge. Forward is true when it was walked from Edge.SrcID
// to Edge.DstID, false when walked against its direction.
type Step struct {
	Edge    Relation
	Cite    Citation
	Forward bool
}

// Path is a walk without repeated entities: len(Entities) == len(Steps)+1.
type Path struct {
	Entities []Entity
	Steps    []Step
}

// ExpandQuery asks for every simple path of 1..Hops edges (edges are followed in
// both directions) that starts at one of SeedIDs.
type ExpandQuery struct {
	Collection string
	SeedIDs    []int64
	Hops       int // 1..MaxHops; larger values are clamped, <= 0 means 1
	Limit      int // max paths; <= 0 means DefaultPathLimit, clamped to MaxPathLimit
	FanOut     int // edges followed per entity, lowest edge ids first; <= 0 means DefaultFanOut, clamped to MaxFanOut
	// LongestFirst orders the paths by decreasing length instead of increasing
	// before Limit cuts them off. A search wants the longest chains and drops
	// the ones that are only the start of another; cutting the longest first
	// would lose exactly the multi-hop chains it looks for.
	LongestFirst bool
}

// PathQuery asks for the shortest paths between two entities.
type PathQuery struct {
	Collection string
	FromID     int64
	ToID       int64
	MaxHops    int // 1..MaxHops, as ExpandQuery.Hops
	Limit      int
	FanOut     int // as ExpandQuery.FanOut
}

// EntityHit is a seed candidate. Higher Score is better.
type EntityHit struct {
	Entity Entity
	Score  float64
}

// JobSpec is one planned extraction window of a document: chunks
// [FirstChunk, FirstChunk+ChunkCount) whose joined text hashes to WindowHash.
type JobSpec struct {
	WindowIdx  int
	WindowHash string
	FirstChunk int
	ChunkCount int
}

// JobKey identifies a job.
type JobKey struct {
	Collection string
	DocumentID string
	WindowIdx  int
}

// Job is an extraction job.
type Job struct {
	JobKey
	WindowHash    string
	FirstChunk    int
	ChunkCount    int
	PromptVersion string
	State         string
	Attempts      int
	LastErrorCode string
	UpdatedAt     time.Time
}

// ExtractedEntity is one validated entity of an extraction result. Chunks lists
// the chunk indexes that mention it.
type ExtractedEntity struct {
	Name          string
	Type          string
	Description   string
	Aliases       []string
	NameEmbedding []float32
	Chunks        []int
}

// ExtractedRelation refers to entities by index into ExtractionResult.Entities.
type ExtractedRelation struct {
	Src, Dst   int
	Predicate  string
	Evidence   string
	ChunkIndex int
}

// ExtractionResult is everything one successful job produced. ApplyExtraction
// stores it and completes the job in one transaction.
type ExtractionResult struct {
	Job           JobKey
	Model         string
	PromptVersion string
	Entities      []ExtractedEntity
	Relations     []ExtractedRelation
}

// GraphStats counts graph rows.
type GraphStats struct {
	Entities, Relations, Mentions     int
	JobsPending, JobsDone, JobsFailed int
	// FactSets, ManualEntities and ManualRelations count curated facts.
	FactSets, ManualEntities, ManualRelations int
	// LastErrorCode is the error code of the most recently updated job of the
	// collection that has one (never a message), or empty.
	LastErrorCode string
}

// ClampHops maps a requested hop count into 1..MaxHops.
func ClampHops(h int) int {
	switch {
	case h <= 0:
		return 1
	case h > MaxHops:
		return MaxHops
	}
	return h
}

// ClampFanOut maps a requested per-entity edge cap into 1..MaxFanOut.
func ClampFanOut(f int) int {
	switch {
	case f <= 0:
		return DefaultFanOut
	case f > MaxFanOut:
		return MaxFanOut
	}
	return f
}

// ClampLimit maps a requested path limit into 1..MaxPathLimit.
func ClampLimit(l int) int {
	switch {
	case l <= 0:
		return DefaultPathLimit
	case l > MaxPathLimit:
		return MaxPathLimit
	}
	return l
}

// MatchForm is the form names are compared in by FindEntitiesByName: lower
// case with every run of non-alphanumeric characters turned into one space.
func MatchForm(s string) string {
	var b strings.Builder
	space := true
	for _, r := range strings.ToLower(s) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
			space = false
		} else if !space {
			b.WriteByte(' ')
			space = true
		}
	}
	return strings.TrimSuffix(b.String(), " ")
}

// MatchAliases returns the aliases of an entity in match form: sorted, unique,
// without empty ones and without the entity's own match name.
func MatchAliases(name string, aliases []string) []string {
	own := MatchForm(name)
	seen := map[string]bool{own: true, "": true}
	var out []string
	for _, a := range aliases {
		m := MatchForm(a)
		if !seen[m] {
			seen[m] = true
			out = append(out, m)
		}
	}
	sort.Strings(out)
	return out
}

func containsWord(hay, needle string) bool {
	return strings.Contains(" "+hay+" ", " "+needle+" ")
}

// NameScore rates how well an entity (match-form name and aliases) fits a
// match-form query: 1 for an equal name, 0.95 an equal alias, then up to 0.9
// for an entity named inside the query, then up to 0.6 for a query that is part
// of a name; 0 for no match. Names shorter than two characters never match by
// containment. The Postgres store computes the same score in SQL.
func NameScore(q, name string, aliases []string) float64 {
	if len([]rune(q)) < 2 {
		return 0
	}
	best := 0.0
	rate := func(s string, equal, inQuery, queryIn float64) {
		n := float64(utf8.RuneCountInString(s))
		ql := float64(utf8.RuneCountInString(q))
		switch {
		case s == q:
			best = max(best, equal)
		case n >= 2 && containsWord(q, s):
			best = max(best, inQuery+0.2*n/ql)
		case containsWord(s, q):
			best = max(best, queryIn+0.1*ql/n)
		}
	}
	rate(name, 1, 0.7, 0.5)
	for _, a := range aliases {
		rate(a, 0.95, 0.65, 0.45)
	}
	return best
}

// SortPaths orders paths by length, then by entity ids, then by edge ids.
func SortPaths(ps []Path) {
	sort.SliceStable(ps, func(i, j int) bool {
		a, b := ps[i], ps[j]
		if len(a.Steps) != len(b.Steps) {
			return len(a.Steps) < len(b.Steps)
		}
		for k := range a.Entities {
			if a.Entities[k].ID != b.Entities[k].ID {
				return a.Entities[k].ID < b.Entities[k].ID
			}
		}
		for k := range a.Steps {
			if a.Steps[k].Edge.ID != b.Steps[k].Edge.ID {
				return a.Steps[k].Edge.ID < b.Steps[k].Edge.ID
			}
		}
		return false
	})
}

// FactEntity is one curated entity of a fact set.
type FactEntity struct {
	Name        string   `json:"name"`
	Type        string   `json:"type"`
	Description string   `json:"description,omitempty"`
	Aliases     []string `json:"aliases,omitempty"`
}

// FactRelation is one curated relation of a fact set. Source and Target are
// names of entities declared in the same fact set. Note is the evidence text.
type FactRelation struct {
	Source    string `json:"source"`
	Predicate string `json:"predicate"`
	Target    string `json:"target"`
	Note      string `json:"note,omitempty"`
}

// FactSet is a named, operator-written catalogue of entities and relations of
// one collection. ReplaceFactSet stores it as a whole. The JSON form is the
// request body of the REST API and what is stored to give it back.
type FactSet struct {
	Collection string         `json:"-"`
	ID         string         `json:"-"`
	SourceURI  string         `json:"source_uri,omitempty"`
	Entities   []FactEntity   `json:"entities"`
	Relations  []FactRelation `json:"relations"`
	// SchemaSHA is the hash of the graph schema this fact set was shaped for ("" when the collection had none). It is not stored.
	SchemaSHA string `json:"-"`
}

// Hash identifies the content of a fact set (not its collection or id): two
// sets with equal hashes are the same catalogue.
func (f FactSet) Hash() string {
	if f.Entities == nil {
		f.Entities = []FactEntity{}
	}
	if f.Relations == nil {
		f.Relations = []FactRelation{}
	}
	b, _ := json.Marshal(f)
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// FactSetInfo summarises a stored fact set.
type FactSetInfo struct {
	ID        string
	SourceURI string
	Entities  int
	Relations int
	UpdatedAt time.Time
}

// Clone returns a copy that shares no memory with f.
func (f FactSet) Clone() FactSet {
	c := f
	c.Entities = make([]FactEntity, len(f.Entities))
	for i, e := range f.Entities {
		e.Aliases = append([]string(nil), e.Aliases...)
		c.Entities[i] = e
	}
	c.Relations = append([]FactRelation{}, f.Relations...)
	return c
}

// Resolve checks that f can be stored and returns, for each relation, the
// indexes into Entities of its source and target. An entity is named by its
// NormalizeName form; every relation endpoint must be one of them.
func (f FactSet) Resolve() ([][2]int, error) {
	if f.Collection == "" || f.ID == "" {
		return nil, errors.New("fact set needs a collection and an id")
	}
	byName := map[string]int{}
	for i, e := range f.Entities {
		n := NormalizeName(e.Name)
		if n == "" || e.Type == "" {
			return nil, fmt.Errorf("fact set entity %d needs a name and a type", i)
		}
		if _, dup := byName[n]; !dup {
			byName[n] = i
		}
	}
	out := make([][2]int, len(f.Relations))
	for i, r := range f.Relations {
		src, ok1 := byName[NormalizeName(r.Source)]
		dst, ok2 := byName[NormalizeName(r.Target)]
		if !ok1 || !ok2 || r.Predicate == "" {
			return nil, fmt.Errorf("fact set relation %d needs a predicate and two entities declared in the same fact set", i)
		}
		out[i] = [2]int{src, dst}
	}
	return out, nil
}
