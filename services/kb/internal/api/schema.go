package api

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"time"

	"github.com/openagentix/openagentix/services/kb/internal/graph"
	"github.com/openagentix/openagentix/services/kb/internal/store"
)

// The routes of graph schemas (ADR 0030, section 5) exist only when schemas are on. They are admin routes: the same token as the others.

func (s *server) putSchema(w http.ResponseWriter, r *http.Request) {
	coll := r.PathValue("collection")
	r.Body = http.MaxBytesReader(w, r.Body, graph.MaxSchemaBytes+1)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		s.bodyError(w, err)
		return
	}
	if len(body) > graph.MaxSchemaBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "the schema is larger than 64 KiB")
		return
	}
	res, err := s.svc.PutGraphSchema(r.Context(), coll, body)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	// Counts only: the type names and key patterns are never logged.
	s.log.Info("graph schema stored", "collection", coll, "version", res.Version, "changed", res.Changed, "entity_types", res.EntityTypes, "relation_types", res.RelationTypes)
	writeJSON(w, http.StatusOK, map[string]any{
		"collection": coll, "version": res.Version, "sha256": res.SHA256, "changed": res.Changed,
		"entity_types": res.EntityTypes, "relation_types": res.RelationTypes,
	})
}

func (s *server) getSchema(w http.ResponseWriter, r *http.Request) {
	coll := r.PathValue("collection")
	x, err := s.svc.GetGraphSchema(r.Context(), coll)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"collection": coll, "version": x.Version, "sha256": x.SHA256, "updated_at": x.UpdatedAt.UTC().Format(time.RFC3339), "body": json.RawMessage(x.Body),
	})
}

func (s *server) deleteSchema(w http.ResponseWriter, r *http.Request) {
	coll := r.PathValue("collection")
	ok, err := s.svc.DeleteGraphSchema(r.Context(), coll)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if !ok {
		writeError(w, http.StatusNotFound, "graph schema not found")
		return
	}
	s.log.Info("graph schema deleted", "collection", coll)
	w.WriteHeader(http.StatusNoContent)
}

// failSchema answers the errors of graph schemas. It reports whether it handled err.
func (s *server) failSchema(w http.ResponseWriter, err error) bool {
	var ve *store.SchemaViolationError
	switch {
	case errors.As(err, &ve):
		// 422 for a fact set that does not fit, 409 for a schema change that the stored facts break. The places and rules only, never what was written.
		code := http.StatusUnprocessableEntity
		if ve.Kind == "change" {
			code = http.StatusConflict
		}
		v := ve.Violations
		if v == nil {
			v = []store.Violation{}
		}
		writeJSON(w, code, map[string]any{"error": ve.Error(), "violations": v, "more": ve.More})
	case errors.Is(err, store.ErrSchemaNotFound):
		writeError(w, http.StatusNotFound, "graph schema not found")
	case errors.Is(err, store.ErrSchemaMoved):
		writeError(w, http.StatusConflict, "the graph schema of the collection changed while the request was handled; send it again")
	default:
		return false
	}
	return true
}
