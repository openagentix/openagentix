// Package access decides which caller an MCP request comes from and which
// collections that caller may read (ADR 0030).
//
// A caller is a tool group. Its bearer value is a file that the installer
// mounts; this package reads the file on every request, so a rotated value
// needs no restart. Values are compared as SHA-256 digests in constant time.
// A value never appears in a log line, an error or a metric.
package access

import (
	"bytes"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/openagentix/openagentix/services/kb/internal/kb"
)

// Mode is how the knowledge base treats a request.
type Mode string

const (
	// Report tags each request with its caller and refuses nothing.
	Report Mode = "report"
	// Enforce refuses a request without a known value and filters every read.
	Enforce Mode = "enforce"
)

const (
	maxCallers     = 64
	maxCollections = 256
	maxAccessBytes = 1 << 20
	bearerPrefix   = "Bearer "
	maxValueBytes  = 4096
)

var callerNameRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$`)

// Caller is one tool group and the collections it may read.
type Caller struct {
	Name        string   `json:"name"`
	Collections []string `json:"collections"`
}

// File is the shape of access.json. It never holds a value.
type File struct {
	Mode    Mode     `json:"mode"`
	Callers []Caller `json:"callers"`
}

// Identity is the answer of Identify.
type Identity struct {
	// Known is true when the header carried exactly one caller's value.
	Known bool
	// Name is the caller's group name when Known, else empty.
	Name string
	// Collections is the caller's list when Known.
	Collections []string
}

// Authorizer identifies callers. It is safe for concurrent use.
type Authorizer struct {
	mode    Mode
	callers []Caller
	dir     string
	log     *slog.Logger

	mu         sync.Mutex
	lastWarned map[string]time.Time

	// admin is the SHA-256 of the admin token, or nil. A value equal to it is never a caller (see RejectAdminToken).
	admin *[sha256.Size]byte
}

// Mode reports the configured mode.
func (a *Authorizer) Mode() Mode { return a.mode }

// Callers returns the configured callers (names and lists, never values).
func (a *Authorizer) Callers() []Caller { return a.callers }

// Load reads access.json and checks that every caller has a usable value file in
// dir. An empty accessFile means the feature is off: it returns nil and no
// error. Any problem returns an error that names the item and never a value.
func Load(accessFile, dir string, log *slog.Logger) (*Authorizer, error) {
	if accessFile == "" {
		return nil, nil
	}
	if log == nil {
		log = slog.New(slog.NewJSONHandler(io.Discard, nil))
	}
	f, err := os.Open(accessFile)
	if err != nil {
		return nil, fmt.Errorf("access config: %w", err)
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, maxAccessBytes+1))
	if err != nil {
		return nil, fmt.Errorf("access config: %w", err)
	}
	if len(data) > maxAccessBytes {
		return nil, errors.New("access config: file too large")
	}
	cfg, err := Parse(data)
	if err != nil {
		return nil, err
	}
	a := &Authorizer{mode: cfg.Mode, callers: cfg.Callers, dir: dir, log: log, lastWarned: map[string]time.Time{}}
	for _, c := range cfg.Callers {
		v, err := a.read(c.Name)
		if err != nil {
			return nil, fmt.Errorf("access config: the value file of caller %q is not usable: %w", c.Name, err)
		}
		if !validValue(v) {
			return nil, fmt.Errorf("access config: the value file of caller %q is empty or is not a bearer value", c.Name)
		}
	}
	return a, nil
}

// Parse checks the content of access.json.
func Parse(data []byte) (File, error) {
	var cfg File
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&cfg); err != nil {
		return File{}, fmt.Errorf("access config: %s", jsonProblem(err))
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return File{}, errors.New("access config: data after the JSON object")
	}
	if cfg.Mode != Report && cfg.Mode != Enforce {
		return File{}, errors.New(`access config: mode must be "report" or "enforce"`)
	}
	if len(cfg.Callers) == 0 || len(cfg.Callers) > maxCallers {
		return File{}, fmt.Errorf("access config: callers must hold 1 to %d entries", maxCallers)
	}
	seen := map[string]bool{}
	for _, c := range cfg.Callers {
		if !callerNameRe.MatchString(c.Name) {
			return File{}, fmt.Errorf("access config: caller name %q is not valid", c.Name)
		}
		if seen[c.Name] {
			return File{}, fmt.Errorf("access config: caller %q is listed twice", c.Name)
		}
		seen[c.Name] = true
		if len(c.Collections) > maxCollections {
			return File{}, fmt.Errorf("access config: caller %q lists more than %d collections", c.Name, maxCollections)
		}
		// An empty list is valid and fails closed: the caller is known and reads nothing. The chart renders one for a
		// tool group that holds a knowledge base entry but has no profile that lists the tools, so that its backend
		// stays ready; the chart refuses the case where a profile lists the tools and the list is empty.
		cs := map[string]bool{}
		for _, col := range c.Collections {
			if err := kb.ValidateCollection(col); err != nil {
				return File{}, fmt.Errorf("access config: caller %q lists a collection name that is not valid", c.Name)
			}
			if cs[col] {
				return File{}, fmt.Errorf("access config: caller %q lists a collection twice", c.Name)
			}
			cs[col] = true
		}
	}
	return cfg, nil
}

// jsonProblem describes a decode error without echoing any value.
func jsonProblem(err error) string {
	var ute *json.UnmarshalTypeError
	var se *json.SyntaxError
	switch {
	case errors.As(err, &ute):
		return "field " + ute.Field + " has the wrong type"
	case errors.As(err, &se):
		return "not valid JSON"
	}
	if s := err.Error(); strings.HasPrefix(s, "json: unknown field ") {
		return s // names the field, not a value
	}
	return "not valid JSON"
}

// read returns the content of a caller's value file without the trailing
// newline. The name was checked against callerNameRe, so it cannot leave dir.
func (a *Authorizer) read(name string) (string, error) {
	b, err := os.ReadFile(filepath.Join(a.dir, name))
	if err != nil {
		var pe *os.PathError
		if errors.As(err, &pe) {
			return "", pe.Err // drop the path, keep the cause
		}
		return "", errors.New("unreadable")
	}
	if len(b) > maxValueBytes {
		return "", errors.New("too large")
	}
	return strings.TrimRight(string(b), "\r\n"), nil
}

// validValue is true for "Bearer <token>" with a non-empty token.
func validValue(v string) bool {
	return strings.HasPrefix(v, bearerPrefix) && len(strings.TrimSpace(v[len(bearerPrefix):])) > 0
}

// RejectAdminToken records the admin token (as a digest) and checks that no caller's value is that token. Every tool server of a group holds the group's value, and the
// admin token writes any collection through /v1, so a caller value equal to it is a start error that names the caller and never the value. From then on Identify never
// accepts the admin token as a caller either, even if a value file is changed after the start. An empty token is ignored.
func (a *Authorizer) RejectAdminToken(token string) error {
	if a == nil || token == "" {
		return nil
	}
	sum := sha256.Sum256([]byte(token))
	a.admin = &sum
	for _, c := range a.callers {
		v, err := a.read(c.Name)
		if err != nil {
			continue
		}
		if a.isAdmin(v) {
			return fmt.Errorf("access config: the value of caller %q is the admin token of the knowledge base; a group's value must be its own", c.Name)
		}
	}
	return nil
}

// isAdmin reports whether a header value ("Bearer <token>") carries the admin token, comparing digests in constant time.
func (a *Authorizer) isAdmin(header string) bool {
	if a.admin == nil || !strings.HasPrefix(header, bearerPrefix) {
		return false
	}
	got := sha256.Sum256([]byte(strings.TrimSpace(header[len(bearerPrefix):])))
	return subtle.ConstantTimeCompare(got[:], a.admin[:]) == 1
}

// Identify maps the Authorization header of one request to a caller. It reads
// every value file, compares digests in constant time with no early exit, and
// answers Known only when exactly one caller matches. An unreadable or empty
// file never matches.
func (a *Authorizer) Identify(authorization string) Identity {
	got := sha256.Sum256([]byte(authorization))
	gotOK := validValue(authorization) && !a.isAdmin(authorization)
	matches, idx := 0, -1
	for i, c := range a.callers {
		want, err := a.read(c.Name)
		if err != nil {
			a.warnUnreadable(c.Name)
			want = ""
		}
		sum := sha256.Sum256([]byte(want))
		eq := subtle.ConstantTimeCompare(got[:], sum[:])
		if eq == 1 && gotOK && validValue(want) {
			matches++
			idx = i
		}
	}
	if matches != 1 {
		return Identity{}
	}
	c := a.callers[idx]
	return Identity{Known: true, Name: c.Name, Collections: append([]string(nil), c.Collections...)}
}

// warnUnreadable logs that a value file cannot be read, at most once a minute
// for each caller. It names the caller, never a value.
func (a *Authorizer) warnUnreadable(name string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if time.Since(a.lastWarned[name]) < time.Minute {
		return
	}
	a.lastWarned[name] = time.Now()
	a.log.Warn("caller value file is not readable; the caller is refused", "caller", name)
}
