package mcpserver

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/openagentix/openagentix/services/kb/internal/graph"
	"github.com/openagentix/openagentix/services/kb/internal/store"
)

// SchemaInput is the kb_graph_schema argument object.
type SchemaInput struct {
	Collection string `json:"collection,omitempty" jsonschema:"the collection whose schema to show (see kb_list_collections); omit to show every collection you may read that has a schema"`
}

// SchemaEntityTypeView is one entity type of a schema.
type SchemaEntityTypeView struct {
	Name        string `json:"name"`
	Key         string `json:"key,omitempty"`
	Description string `json:"description,omitempty"`
}

// SchemaRelationTypeView is one relation type of a schema.
type SchemaRelationTypeView struct {
	Name        string   `json:"name"`
	From        []string `json:"from"`
	To          []string `json:"to"`
	Description string   `json:"description,omitempty"`
}

// SchemaView is the schema of one collection.
type SchemaView struct {
	Collection    string                   `json:"collection"`
	Version       int                      `json:"version"`
	SHA256        string                   `json:"sha256"`
	EntityTypes   []SchemaEntityTypeView   `json:"entity_types"`
	RelationTypes []SchemaRelationTypeView `json:"relation_types"`
}

// SchemaOutput is the structured result of kb_graph_schema.
type SchemaOutput struct {
	Schemas []SchemaView `json:"schemas"`
}

func viewOf(x store.StoredSchema) (SchemaView, error) {
	var g store.GraphSchema
	if err := json.Unmarshal(x.Body, &g); err != nil {
		return SchemaView{}, err
	}
	v := SchemaView{Collection: x.Collection, Version: x.Version, SHA256: x.SHA256, EntityTypes: []SchemaEntityTypeView{}, RelationTypes: []SchemaRelationTypeView{}}
	for _, t := range g.EntityTypes {
		v.EntityTypes = append(v.EntityTypes, SchemaEntityTypeView{Name: t.Name, Key: t.Key, Description: t.Description})
	}
	for _, r := range g.RelationTypes {
		v.RelationTypes = append(v.RelationTypes, SchemaRelationTypeView{Name: r.Name, From: r.From, To: r.To, Description: r.Description})
	}
	return v, nil
}

func (h *handlers) graphSchema(ctx context.Context, req *mcp.CallToolRequest, in SchemaInput) (*mcp.CallToolResult, SchemaOutput, error) {
	ctx, c := h.begin(ctx, req)
	ctx, cancel := h.bound(ctx)
	defer cancel()
	start := time.Now()
	c.arg(in.Collection)
	list, err := h.svc.ReadGraphSchemas(ctx, in.Collection)
	if err != nil {
		return nil, SchemaOutput{}, h.done(c, "kb_graph_schema", start, 0, err)
	}
	out := SchemaOutput{Schemas: []SchemaView{}}
	b := newBudget()
	builtin := strings.Join(graph.EntityTypes, ", ")
	for _, x := range list {
		v, err := viewOf(x)
		if err != nil {
			return nil, SchemaOutput{}, h.done(c, "kb_graph_schema", start, 0, err)
		}
		c.saw(v.Collection)
		out.Schemas = append(out.Schemas, v)
		b.line("Graph schema of collection %s (version %d, sha256 %s):", v.Collection, v.Version, v.SHA256[:12])
		b.line("Entity types (a name must match its key, when there is one, in full):")
		for _, t := range v.EntityTypes {
			l := "- " + t.Name
			if t.Key != "" {
				l += " | key: " + t.Key
			}
			if t.Description != "" {
				l += " | " + t.Description
			}
			b.line("%s", l)
		}
		b.line("Relation types (from -> to):")
		for _, r := range v.RelationTypes {
			l := fmt.Sprintf("- %s: %s -> %s", r.Name, strings.Join(r.From, " or "), strings.Join(r.To, " or "))
			if r.Description != "" {
				l += " | " + r.Description
			}
			b.line("%s", l)
		}
		b.line("")
	}
	switch {
	case len(out.Schemas) == 0 && in.Collection != "":
		b.line("The collection %s has no graph schema; the built-in entity types apply: %s.", in.Collection, builtin)
	case len(out.Schemas) == 0:
		b.line("No collection you can read has a graph schema; the built-in entity types apply: %s.", builtin)
	}
	_ = h.done(c, "kb_graph_schema", start, len(out.Schemas), nil)
	return textResult(b.String()), out, nil
}
