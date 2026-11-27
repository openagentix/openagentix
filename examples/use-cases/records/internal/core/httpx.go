package core

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
)

// MaxBody bounds one request body.
const MaxBody = 64 << 10

// WriteJSON writes v as JSON with status code.
func WriteJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

// WriteError maps an *Error to its status. Any other error is a 500 with no detail.
func WriteError(w http.ResponseWriter, err error) {
	var e *Error
	if !errors.As(err, &e) {
		WriteJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}
	code := http.StatusInternalServerError
	switch e.Kind {
	case Invalid:
		code = http.StatusBadRequest
	case Unauthorized:
		code = http.StatusUnauthorized
		w.Header().Set("WWW-Authenticate", `Bearer realm="records"`)
	case Forbidden:
		code = http.StatusForbidden
	case NotFound:
		code = http.StatusNotFound
	case Conflict:
		code = http.StatusConflict
	}
	WriteJSON(w, code, map[string]string{"error": e.Msg})
}

// Outcome names an error for the audit log from a closed set.
func Outcome(err error) string {
	switch {
	case err == nil:
		return "ok"
	case IsKind(err, Invalid):
		return "invalid"
	case IsKind(err, NotFound):
		return "not_found"
	case IsKind(err, Conflict):
		return "conflict"
	case IsKind(err, Forbidden), IsKind(err, Unauthorized):
		return "denied"
	}
	return "error"
}

// ReadJSON decodes one JSON object from the body into v. Unknown fields, trailing data and bodies over MaxBody
// are refused.
func ReadJSON(w http.ResponseWriter, r *http.Request, v any) error {
	r.Body = http.MaxBytesReader(w, r.Body, MaxBody)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return &Error{Kind: Invalid, Msg: "body is not valid JSON for this route"}
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return &Error{Kind: Invalid, Msg: "body has data after the JSON object"}
	}
	return nil
}
