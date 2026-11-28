package mcpserver

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/openagentix/openagentix/services/kb/internal/kb"
)

// maxGraphTextChars bounds the text of one graph tool result.
const maxGraphTextChars = 12000

// GraphSearchInput is the kb_graph_search argument object.
type GraphSearchInput struct {
	Query      string `json:"query" jsonschema:"the question or the names of the things to look up, in natural language"`
	Collection string `json:"collection,omitempty" jsonschema:"restrict the search to one collection (see kb_list_collections); omit to search all"`
	Hops       int    `json:"hops,omitempty" jsonschema:"how many relations to follow from the matched entities, 1 to 3, default 2"`
	TopK       int    `json:"top_k,omitempty" jsonschema:"number of matched entities to start from, default 5, maximum 20"`
}

// GraphEntityInput is the kb_graph_entity argument object.
type GraphEntityInput struct {
	Name       string `json:"name" jsonschema:"the entity name, for example a service, team, person or place"`
	Collection string `json:"collection,omitempty" jsonschema:"restrict to one collection; omit to look in all"`
}

// GraphPathsInput is the kb_graph_paths argument object.
type GraphPathsInput struct {
	From       string `json:"from" jsonschema:"name of the entity to start from"`
	To         string `json:"to" jsonschema:"name of the entity to reach"`
	Collection string `json:"collection,omitempty" jsonschema:"restrict to one collection; omit to look in all"`
	MaxHops    int    `json:"max_hops,omitempty" jsonschema:"longest path to look for, 1 to 3, default 2"`
}

// The structured results are the kb service's own types.
type (
	GraphSearchOutput = kb.GraphSearchResult
	GraphEntityOutput = kb.GraphEntityResult
	GraphPathsOutput  = kb.GraphPathsResult
)

func (h *handlers) registerGraph(srv *mcp.Server, ro *mcp.ToolAnnotations) {
	if h.svc.SchemasEnabled() {
		mcp.AddTool(srv, &mcp.Tool{
			Name:        "kb_graph_schema",
			Description: "Show the graph schema of a collection: the entity types, each with the pattern its names must match, and the relation types, each with the entity types allowed at its two ends. Use it before you ask the graph tools about a collection, to know which names and relations to expect. A collection without a schema uses the built-in entity types. Omit the collection to see every collection you may read that has a schema.",
			Annotations: ro,
		}, h.graphSchema)
	}
	mcp.AddTool(srv, &mcp.Tool{
		Name:        "kb_graph_search",
		Description: "Search the knowledge graph of facts extracted from the documents, together with facts an operator curated by hand. Finds the entities your question names, then follows their relations up to 'hops' steps, and returns chains like 'Teal -runs_in-> Vane-3', each fact with the document_id, chunk and quote it came from (or, for a curated fact, the fact set and note), plus the supporting passages. Use it for questions that link several things (who owns, what depends on, where does it run). Open a document_id with kb_get_document.",
		Annotations: ro,
	}, h.graphSearch)
	mcp.AddTool(srv, &mcp.Tool{
		Name:        "kb_graph_entity",
		Description: "Describe one entity of the knowledge graph (service, team, person, place...): its type, description, other names and the facts that connect it directly to other entities, each with the document_id it came from. Use it to continue a chain from the end of a kb_graph_search path.",
		Annotations: ro,
	}, h.graphEntity)
	mcp.AddTool(srv, &mcp.Tool{
		Name:        "kb_graph_paths",
		Description: "Find the shortest chains of facts that connect two named entities in the knowledge graph, up to max_hops steps, each fact with its document_id and quote. Says so plainly if an entity is unknown or no path exists.",
		Annotations: ro,
	}, h.graphPaths)
}

// textBudget accumulates a bounded result text.
type textBudget struct {
	sb        strings.Builder
	left      int
	exhausted bool
}

func newBudget() *textBudget { return &textBudget{left: maxGraphTextChars} }

// line appends s and a newline if it fits and reports whether it did.
func (b *textBudget) line(format string, a ...any) bool {
	s := fmt.Sprintf(format, a...) + "\n"
	n := utf8.RuneCountInString(s)
	if b.exhausted || n > b.left {
		b.exhausted = true
		return false
	}
	b.left -= n
	b.sb.WriteString(s)
	return true
}

func (b *textBudget) String() string { return strings.TrimRight(b.sb.String(), "\n") }

func fact(e kb.GraphEdge) string {
	if e.Curated {
		// A curated fact cites a fact set, not a document: there is no passage to open.
		s := fmt.Sprintf("%s -%s-> %s | curated: factset=%s", e.Subject, e.Predicate, e.Object, e.FactsetID)
		if e.SourceURI != "" {
			s += " source=" + e.SourceURI
		}
		if e.Evidence != "" {
			s += fmt.Sprintf(" | %q", e.Evidence)
		}
		return s
	}
	s := fmt.Sprintf("%s -%s-> %s | document_id=%s chunk=%d", e.Subject, e.Predicate, e.Object, e.DocumentID, e.ChunkIndex)
	if e.SourceURI != "" {
		s += " | source " + e.SourceURI
	}
	if e.Evidence != "" {
		s += fmt.Sprintf(" | %q", e.Evidence)
	}
	return s
}

// chain renders a path in walking order: "A -p-> B", or "A <-p- B" for an edge
// walked against its direction.
func chain(p kb.GraphPath) string {
	var sb strings.Builder
	sb.WriteString(p.Entities[0])
	for i, e := range p.Edges {
		if e.Forward {
			fmt.Fprintf(&sb, " -%s-> %s", e.Predicate, p.Entities[i+1])
		} else {
			fmt.Fprintf(&sb, " <-%s- %s", e.Predicate, p.Entities[i+1])
		}
	}
	return sb.String()
}

// writePaths lists the chains, then each distinct fact once, then the
// supporting passages. It returns the number of paths that did not fit.
func writePaths(b *textBudget, paths []kb.GraphPath, chunks []kb.GraphChunk, withCollection bool) (omitted int) {
	for i, p := range paths {
		coll := ""
		if withCollection {
			coll = " (collection=" + p.Collection + ")"
		}
		if !b.line("[%d] %s%s", i+1, chain(p), coll) {
			omitted = len(paths) - i
			break
		}
	}
	b.line("\nFacts and where they come from:")
	for _, p := range paths {
		if slices.ContainsFunc(p.Edges, func(e kb.GraphEdge) bool { return e.Curated }) {
			b.line("(curated = written by an operator in a fact set, not extracted from a document; it has no passage to open)")
			break
		}
	}
	seen := map[string]bool{}
	for _, p := range paths {
		for _, e := range p.Edges {
			f := fact(e)
			if withCollection {
				f += " | collection=" + p.Collection
			}
			if seen[f] {
				continue
			}
			seen[f] = true
			if !b.line("- %s", f) {
				return omitted
			}
		}
	}
	if len(chunks) > 0 {
		b.line("\nSupporting passages:")
		for _, c := range chunks {
			if !b.line("[document_id=%s chunk=%d] %s", c.DocumentID, c.ChunkIndex, c.Text) {
				break
			}
		}
	}
	return omitted
}

func (h *handlers) graphSearch(ctx context.Context, req *mcp.CallToolRequest, in GraphSearchInput) (*mcp.CallToolResult, GraphSearchOutput, error) {
	ctx, c := h.begin(ctx, req)
	ctx, cancel := h.bound(ctx)
	defer cancel()
	start := time.Now()
	c.arg(in.Collection)
	res, err := h.svc.GraphSearch(ctx, in.Query, in.Collection, in.Hops, in.TopK)
	if err != nil {
		return nil, GraphSearchOutput{}, h.done(c, "kb_graph_search", start, 0, err)
	}
	for _, s := range res.Seeds {
		c.saw(s.Collection)
	}
	for _, p := range res.Paths {
		c.saw(p.Collection)
	}
	b := newBudget()
	if len(res.Seeds) == 0 {
		b.line("No entities in the knowledge graph match the query. Try the exact name of a service, team, person or place, or use kb_search for the document text.")
		_ = h.done(c, "kb_graph_search", start, 0, nil)
		return textResult(b.String()), res, nil
	}
	b.line("%s\n", UntrustedNotice)
	names := make([]string, len(res.Seeds))
	multi := false
	for i, s := range res.Seeds {
		names[i] = fmt.Sprintf("%s (%s)", s.Name, s.Type)
		multi = multi || s.Collection != res.Seeds[0].Collection
	}
	b.line("Matched entities: %s", strings.Join(names, ", "))
	if len(res.Paths) == 0 {
		b.line("They have no relations in the graph yet.")
		_ = h.done(c, "kb_graph_search", start, 0, nil)
		return textResult(b.String()), res, nil
	}
	b.line("Chains of facts around them, up to %s. 'A -p-> B' reads 'A p B'; 'A <-p- B' reads 'B p A'.\n", kb.HopsText(res.Hops))
	withCollection := multi || in.Collection == ""
	omitted := writePaths(b, res.Paths, res.Chunks, withCollection)
	if res.Truncated || omitted > 0 {
		b.line("\n(more paths exist than are shown; ask about a more specific entity with kb_graph_entity or kb_graph_paths)")
	}
	if res.HopLimited {
		b.line("\nSome chains end at the hop limit. To follow one further, call kb_graph_entity with the name of its last entity, or raise hops (maximum 3).")
	}
	_ = h.done(c, "kb_graph_search", start, len(res.Paths), nil)
	return textResult(b.String()), res, nil
}

func candidateLines(b *textBudget, cs []kb.GraphCandidate) {
	for _, c := range cs {
		l := fmt.Sprintf("- %s (%s, collection=%s)", c.Name, c.Type, c.Collection)
		if c.Description != "" {
			l += ": " + c.Description
		}
		b.line("%s", l)
	}
}

func (h *handlers) graphEntity(ctx context.Context, req *mcp.CallToolRequest, in GraphEntityInput) (*mcp.CallToolResult, GraphEntityOutput, error) {
	ctx, c := h.begin(ctx, req)
	ctx, cancel := h.bound(ctx)
	defer cancel()
	start := time.Now()
	c.arg(in.Collection)
	res, err := h.svc.GraphEntity(ctx, in.Name, in.Collection)
	if err != nil {
		return nil, GraphEntityOutput{}, h.done(c, "kb_graph_entity", start, 0, err)
	}
	if res.Found {
		c.saw(res.Collection)
	}
	for _, cd := range res.Candidates {
		c.saw(cd.Collection)
	}
	b := newBudget()
	switch {
	case !res.Found && len(res.Candidates) == 0:
		b.line("There is no entity named %q in the knowledge graph. Try kb_graph_search with a keyword, or kb_search for the document text.", res.Query)
	case !res.Found:
		b.line("%s\n", UntrustedNotice)
		b.line("More than one entity matches %q. Call kb_graph_entity again with the full name and the collection:", res.Query)
		candidateLines(b, res.Candidates)
	default:
		b.line("%s\n", UntrustedNotice)
		b.line("Entity: %s (%s) in collection=%s", res.Name, res.Type, res.Collection)
		if res.Description != "" {
			b.line("Description: %s", res.Description)
		}
		if len(res.Aliases) > 0 {
			b.line("Also known as: %s", strings.Join(res.Aliases, ", "))
		}
		if len(res.Neighbours) == 0 {
			b.line("It has no relations in the graph yet.")
		} else {
			b.line("\nDirect connections (%d). 'A -p-> B' reads 'A p B':", len(res.Neighbours))
			for _, e := range res.Neighbours {
				if !b.line("- %s", fact(e)) {
					break
				}
			}
			if res.Truncated {
				b.line("(more connections exist than are shown)")
			}
		}
	}
	_ = h.done(c, "kb_graph_entity", start, len(res.Neighbours), nil)
	return textResult(b.String()), res, nil
}

func (h *handlers) graphPaths(ctx context.Context, req *mcp.CallToolRequest, in GraphPathsInput) (*mcp.CallToolResult, GraphPathsOutput, error) {
	ctx, c := h.begin(ctx, req)
	ctx, cancel := h.bound(ctx)
	defer cancel()
	start := time.Now()
	c.arg(in.Collection)
	res, err := h.svc.GraphPaths(ctx, in.From, in.To, in.Collection, in.MaxHops)
	if err != nil {
		return nil, GraphPathsOutput{}, h.done(c, "kb_graph_paths", start, 0, err)
	}
	for _, p := range res.Paths {
		c.saw(p.Collection)
	}
	for _, cd := range res.Candidates {
		c.saw(cd.Collection)
	}
	b := newBudget()
	switch {
	case res.MissingEntity != "":
		b.line("There is no entity named %q in the knowledge graph. Try kb_graph_search with a keyword to find the exact name.", res.MissingEntity)
	case res.SameEntity:
		b.line("%q and %q are the same entity: there is nothing to connect.", res.From, res.To)
	case len(res.Candidates) > 0:
		b.line("%s\n", UntrustedNotice)
		b.line("A name matches more than one entity. Call kb_graph_paths again with the full name and the collection:")
		candidateLines(b, res.Candidates)
	case res.NoPath:
		b.line("There is no path within %s from %q to %q in the knowledge graph.", kb.HopsText(res.MaxHops), res.From, res.To)
	default:
		b.line("%s\n", UntrustedNotice)
		b.line("Shortest path(s) from %q to %q, %s. 'A -p-> B' reads 'A p B'; 'A <-p- B' reads 'B p A'.\n", res.From, res.To, kb.HopsText(len(res.Paths[0].Edges)))
		writePaths(b, res.Paths, res.Chunks, in.Collection == "")
	}
	_ = h.done(c, "kb_graph_paths", start, len(res.Paths), nil)
	return textResult(b.String()), res, nil
}
