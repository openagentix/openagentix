package core

import (
	"bytes"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"regexp"
	"strings"
)

// Approver is a named person who may decide approvals of the kinds their role allows.
type Approver struct {
	ID   string `json:"id"`
	Role string `json:"role"`
}

type approverEntry struct {
	ID          string `json:"id"`
	Role        string `json:"role"`
	TokenSHA256 string `json:"token_sha256"`
}

// Approvers authenticates bearer tokens against SHA-256 hashes read from a file. The file holds hashes, never
// tokens, so a leaked file does not let anyone approve. With no file, nobody can approve (deny by default).
type Approvers struct {
	entries []approverEntry
	hashes  [][sha256.Size]byte
}

var (
	approverID   = regexp.MustCompile(`^[a-z0-9]+:[a-z0-9][a-z0-9-]{0,30}$`)
	approverRole = regexp.MustCompile(`^[a-z][a-z0-9-]{0,30}$`)
)

// LoadApprovers reads path (a JSON array of {id, role, token_sha256}). An empty path returns a disabled store.
// A configured path that cannot be read or is invalid is an error: the service must not start half open.
func LoadApprovers(path string) (*Approvers, error) {
	if path == "" {
		return &Approvers{}, nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read approvers file: %w", err)
	}
	var entries []approverEntry
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&entries); err != nil {
		return nil, fmt.Errorf("approvers file is not valid: %w", err)
	}
	if len(entries) == 0 {
		return nil, errors.New("approvers file has no entries")
	}
	a := &Approvers{}
	seen := map[string]bool{}
	for i, e := range entries {
		if !approverID.MatchString(e.ID) || e.ID == "agent" {
			return nil, fmt.Errorf("approver %d: id must look like desk:lead-1", i)
		}
		if !approverRole.MatchString(e.Role) {
			return nil, fmt.Errorf("approver %d: role is not valid", i)
		}
		if seen[e.ID] {
			return nil, fmt.Errorf("approver %d: duplicate id", i)
		}
		seen[e.ID] = true
		b, err := hex.DecodeString(e.TokenSHA256)
		if err != nil || len(b) != sha256.Size {
			return nil, fmt.Errorf("approver %d: token_sha256 must be 64 hex characters", i)
		}
		var h [sha256.Size]byte
		copy(h[:], b)
		a.entries = append(a.entries, e)
		a.hashes = append(a.hashes, h)
	}
	return a, nil
}

// Enabled reports whether any approver is configured.
func (a *Approvers) Enabled() bool { return a != nil && len(a.entries) > 0 }

// Authenticate reads "Authorization: Bearer <token>" and returns the matching approver. It compares against every
// entry in constant time, so the time taken does not show which entry was close.
func (a *Approvers) Authenticate(r *http.Request) (Approver, bool) {
	if !a.Enabled() {
		return Approver{}, false
	}
	h := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if len(h) <= len(prefix) || !strings.EqualFold(h[:len(prefix)], prefix) {
		return Approver{}, false
	}
	tok := strings.TrimSpace(h[len(prefix):])
	if tok == "" {
		return Approver{}, false
	}
	got := sha256.Sum256([]byte(tok))
	found := -1
	for i := range a.hashes {
		if subtle.ConstantTimeCompare(got[:], a.hashes[i][:]) == 1 {
			found = i
		}
	}
	if found < 0 {
		return Approver{}, false
	}
	return Approver{ID: a.entries[found].ID, Role: a.entries[found].Role}, true
}
