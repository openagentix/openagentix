// Package api implements the ingest/admin REST API under /v1.
package api

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/openagentix/openagentix/services/kb/internal/kb"
	"github.com/openagentix/openagentix/services/kb/internal/store"
)

// statusClientClosedRequest is the nginx convention for a client that hung up.
const statusClientClosedRequest = 499

// DefaultMaxBodyBytes is the request body limit when Config.MaxBodyBytes is 0.
const DefaultMaxBodyBytes = 4 << 20

// Config controls the admin API's access policy.
type Config struct {
	// AdminToken is the required bearer token. Empty means the API is disabled
	// (403) unless AllowAnonymous is set.
	AdminToken     string
	AllowAnonymous bool
	MaxBodyBytes   int64
}

type server struct {
	svc *kb.Service
	cfg Config
	log *slog.Logger
	tok [sha256.Size]byte
}

// New returns a handler serving the /v1 routes.
func New(svc *kb.Service, cfg Config, log *slog.Logger) http.Handler {
	if cfg.MaxBodyBytes <= 0 {
		cfg.MaxBodyBytes = DefaultMaxBodyBytes
	}
	s := &server{svc: svc, cfg: cfg, log: log, tok: sha256.Sum256([]byte(cfg.AdminToken))}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/collections", s.auth(s.listCollections))
	mux.HandleFunc("PUT /v1/collections/{collection}/documents/{id}", s.auth(s.putDocument))
	mux.HandleFunc("DELETE /v1/collections/{collection}/documents/{id}", s.auth(s.deleteDocument))
	if svc.GraphEnabled() {
		mux.HandleFunc("GET /v1/collections/{collection}/graph/stats", s.auth(s.graphStats))
		mux.HandleFunc("GET /v1/graph/stats", s.auth(s.graphStatsAll))
		mux.HandleFunc("GET /v1/collections/{collection}/graph/factsets", s.auth(s.listFactSets))
		mux.HandleFunc("PUT /v1/collections/{collection}/graph/factsets/{id}", s.auth(s.putFactSet))
		mux.HandleFunc("GET /v1/collections/{collection}/graph/factsets/{id}", s.auth(s.getFactSet))
		mux.HandleFunc("DELETE /v1/collections/{collection}/graph/factsets/{id}", s.auth(s.deleteFactSet))
		if svc.SchemasEnabled() {
			mux.HandleFunc("PUT /v1/collections/{collection}/graph/schema", s.auth(s.putSchema))
			mux.HandleFunc("GET /v1/collections/{collection}/graph/schema", s.auth(s.getSchema))
			mux.HandleFunc("DELETE /v1/collections/{collection}/graph/schema", s.auth(s.deleteSchema))
		}
	}
	return mux
}

func (s *server) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		switch {
		case s.cfg.AdminToken == "" && !s.cfg.AllowAnonymous:
			writeError(w, http.StatusForbidden, "admin API is disabled: the server has no KB_ADMIN_TOKEN configured")
			return
		case s.cfg.AdminToken != "":
			got, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
			// Compare fixed-length digests so neither content nor length leaks.
			sum := sha256.Sum256([]byte(got))
			if !ok || subtle.ConstantTimeCompare(sum[:], s.tok[:]) != 1 {
				w.Header().Set("WWW-Authenticate", `Bearer realm="kb-admin"`)
				writeError(w, http.StatusUnauthorized, "missing or invalid bearer token")
				return
			}
		}
		next(w, r)
	}
}

type putRequest struct {
	Title     string `json:"title"`
	SourceURI string `json:"source_uri"`
	Text      string `json:"text"`
}

// decodeBody reads the request body as one JSON object into v, refusing unknown
// fields and trailing data. It writes the error response and reports false on
// failure.
func (s *server) decodeBody(w http.ResponseWriter, r *http.Request, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, s.cfg.MaxBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		s.bodyError(w, err)
		return false
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		if err == nil {
			writeError(w, http.StatusBadRequest, "request body must contain a single JSON object")
		} else {
			s.bodyError(w, err)
		}
		return false
	}
	return true
}

func (s *server) putDocument(w http.ResponseWriter, r *http.Request) {
	var req putRequest
	if !s.decodeBody(w, r, &req) {
		return
	}
	coll, id := r.PathValue("collection"), r.PathValue("id")
	n, err := s.svc.Put(r.Context(), coll, id, kb.DocInput{Title: req.Title, SourceURI: req.SourceURI, Text: req.Text})
	if err != nil {
		s.fail(w, r, err)
		return
	}
	s.log.Info("document upserted", "collection", coll, "id", id, "chunks", n)
	writeJSON(w, http.StatusOK, map[string]any{"collection": coll, "id": id, "chunks": n})
}

func (s *server) bodyError(w http.ResponseWriter, err error) {
	var mbe *http.MaxBytesError
	if errors.As(err, &mbe) {
		writeError(w, http.StatusRequestEntityTooLarge, "request body too large")
		return
	}
	writeError(w, http.StatusBadRequest, "invalid JSON body: "+jsonErrText(err))
}

// jsonErrText returns a short description that never echoes body content.
func jsonErrText(err error) string {
	var ute *json.UnmarshalTypeError
	switch {
	case errors.As(err, &ute):
		return "field " + ute.Field + " has the wrong type"
	case strings.HasPrefix(err.Error(), "json: unknown field"):
		return err.Error()
	case errors.Is(err, io.EOF), errors.Is(err, io.ErrUnexpectedEOF):
		return "unexpected end of input"
	default:
		return "malformed JSON"
	}
}

func (s *server) deleteDocument(w http.ResponseWriter, r *http.Request) {
	coll, id := r.PathValue("collection"), r.PathValue("id")
	ok, err := s.svc.Delete(r.Context(), coll, id)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if !ok {
		writeError(w, http.StatusNotFound, "document not found")
		return
	}
	s.log.Info("document deleted", "collection", coll, "id", id)
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) listCollections(w http.ResponseWriter, r *http.Request) {
	cols, err := s.svc.Collections(r.Context())
	if err != nil {
		s.fail(w, r, err)
		return
	}
	out := make([]map[string]any, 0, len(cols))
	for _, c := range cols {
		out = append(out, map[string]any{"name": c.Name, "documents": c.Documents})
	}
	writeJSON(w, http.StatusOK, map[string]any{"collections": out})
}

func graphStatsJSON(collection string, st store.GraphStats) map[string]any {
	return map[string]any{
		"collection": collection, "entities": st.Entities, "relations": st.Relations, "mentions": st.Mentions,
		"jobs":            map[string]int{"pending": st.JobsPending, "done": st.JobsDone, "failed": st.JobsFailed},
		"manual":          map[string]int{"entities": st.ManualEntities, "relations": st.ManualRelations, "factsets": st.FactSets},
		"last_error_code": st.LastErrorCode,
	}
}

func (s *server) graphStats(w http.ResponseWriter, r *http.Request) {
	coll := r.PathValue("collection")
	st, err := s.svc.GraphStats(r.Context(), coll)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, graphStatsJSON(coll, st))
}

func (s *server) graphStatsAll(w http.ResponseWriter, r *http.Request) {
	cols, err := s.svc.Collections(r.Context())
	if err != nil {
		s.fail(w, r, err)
		return
	}
	out := make([]map[string]any, 0, len(cols))
	for _, c := range cols {
		st, err := s.svc.GraphStats(r.Context(), c.Name)
		if err != nil {
			s.fail(w, r, err)
			return
		}
		out = append(out, graphStatsJSON(c.Name, st))
	}
	writeJSON(w, http.StatusOK, map[string]any{"collections": out})
}

func (s *server) fail(w http.ResponseWriter, r *http.Request, err error) {
	if s.failSchema(w, err) {
		return
	}
	switch {
	case errors.Is(err, kb.ErrInvalid):
		writeError(w, http.StatusBadRequest, strings.TrimPrefix(err.Error(), kb.ErrInvalid.Error()+": "))
	case errors.Is(err, kb.ErrConflict):
		writeError(w, http.StatusConflict, strings.TrimPrefix(err.Error(), kb.ErrConflict.Error()+": "))
	case errors.Is(err, kb.ErrTooLarge):
		writeError(w, http.StatusRequestEntityTooLarge, strings.TrimPrefix(err.Error(), kb.ErrTooLarge.Error()+": "))
	case errors.Is(err, kb.ErrUpstream):
		s.log.Error("upstream failure", "method", r.Method, "path", r.Pattern, "err", err)
		writeError(w, http.StatusBadGateway, "embedding service failed")
	case errors.Is(err, store.ErrFactSetNotFound):
		writeError(w, http.StatusNotFound, "fact set not found")
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "document not found")
	case errors.Is(err, context.DeadlineExceeded):
		writeError(w, http.StatusGatewayTimeout, "request timed out")
	case errors.Is(err, context.Canceled):
		// The client went away; nothing is listening, and it is not a server fault.
		s.log.Info("request canceled by client", "method", r.Method, "path", r.Pattern)
		writeError(w, statusClientClosedRequest, "request canceled")
	default:
		s.log.Error("request failed", "method", r.Method, "path", r.Pattern, "err", err)
		writeError(w, http.StatusInternalServerError, "internal error")
	}
}

func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func (s *server) putFactSet(w http.ResponseWriter, r *http.Request) {
	var req store.FactSet
	if !s.decodeBody(w, r, &req) {
		return
	}
	coll, id := r.PathValue("collection"), r.PathValue("id")
	res, err := s.svc.PutFactSet(r.Context(), coll, id, req)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	// Counts only: the catalogue's names and notes are never logged.
	s.log.Info("fact set replaced", "collection", coll, "id", id, "entities", res.Entities, "relations", res.Relations, "changed", res.Changed)
	writeJSON(w, http.StatusOK, map[string]any{"collection": coll, "id": id, "entities": res.Entities, "relations": res.Relations, "changed": res.Changed})
}

func (s *server) getFactSet(w http.ResponseWriter, r *http.Request) {
	fs, err := s.svc.GetFactSet(r.Context(), r.PathValue("collection"), r.PathValue("id"))
	if err != nil {
		s.fail(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, fs)
}

func (s *server) listFactSets(w http.ResponseWriter, r *http.Request) {
	coll := r.PathValue("collection")
	infos, err := s.svc.ListFactSets(r.Context(), coll)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	out := make([]map[string]any, 0, len(infos))
	for _, i := range infos {
		out = append(out, map[string]any{"id": i.ID, "source_uri": i.SourceURI, "entities": i.Entities, "relations": i.Relations, "updated_at": i.UpdatedAt.UTC().Format(time.RFC3339)})
	}
	writeJSON(w, http.StatusOK, map[string]any{"collection": coll, "factsets": out})
}

func (s *server) deleteFactSet(w http.ResponseWriter, r *http.Request) {
	coll, id := r.PathValue("collection"), r.PathValue("id")
	ok, err := s.svc.DeleteFactSet(r.Context(), coll, id)
	if err != nil {
		s.fail(w, r, err)
		return
	}
	if !ok {
		writeError(w, http.StatusNotFound, "fact set not found")
		return
	}
	s.log.Info("fact set deleted", "collection", coll, "id", id)
	w.WriteHeader(http.StatusNoContent)
}
