package core

import (
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"strings"
)

// MinMCPTokenLen is the shortest token the MCP port accepts as its credential.
const MinMCPTokenLen = 32

// MCPBearer guards the MCP port with one shared header value. The value is the whole Authorization header value
// ("Bearer <token>"), the same string that the tool gateway sends from its Secret. It is read from a file on every
// request, so a rotated Secret takes effect without a restart, and a file that goes bad later refuses every call
// (fail closed). The value is compared in constant time and appears in no log line, error or answer.
type MCPBearer struct {
	path string
	log  *slog.Logger
}

// NewMCPBearer checks the file once: a service must not start with a credential it cannot use.
func NewMCPBearer(path string, log *slog.Logger) (*MCPBearer, error) {
	if path == "" {
		return nil, errors.New("no MCP credential file given")
	}
	b := &MCPBearer{path: path, log: log}
	if _, err := b.read(); err != nil {
		return nil, err
	}
	return b, nil
}

// read returns the expected header value, or an error that says what is wrong with the file and never repeats it.
func (b *MCPBearer) read() (string, error) {
	raw, err := os.ReadFile(b.path)
	if err != nil {
		return "", fmt.Errorf("read MCP credential file: %w", err)
	}
	v := strings.TrimRight(string(raw), "\r\n")
	tok, ok := strings.CutPrefix(v, "Bearer ")
	if !ok {
		return "", errors.New("MCP credential file must hold the whole header value: the word Bearer, a space, then the token")
	}
	if len(tok) < MinMCPTokenLen {
		return "", fmt.Errorf("MCP credential token must have at least %d characters", MinMCPTokenLen)
	}
	for _, c := range tok {
		if c <= ' ' || c > '~' {
			return "", errors.New("MCP credential token must not hold spaces or control characters")
		}
	}
	return v, nil
}

func isHealthCheck(r *http.Request) bool {
	return (r.Method == http.MethodGet || r.Method == http.MethodHead) && (r.URL.Path == "/healthz" || r.URL.Path == "/readyz")
}

// Wrap refuses every request that does not carry the expected header value. Only GET /healthz and GET /readyz are open.
func (b *MCPBearer) Wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if isHealthCheck(r) {
			next.ServeHTTP(w, r)
			return
		}
		want, err := b.read()
		if err != nil {
			b.log.Error("mcp request refused: the credential file is not usable", "reason", err.Error(), "path", r.URL.Path)
			b.deny(w)
			return
		}
		got := r.Header.Get("Authorization")
		// Hash both sides so the comparison has one length whatever the caller sends.
		a, c := sha256.Sum256([]byte(got)), sha256.Sum256([]byte(want))
		if got == "" || subtle.ConstantTimeCompare(a[:], c[:]) != 1 {
			host, _, _ := net.SplitHostPort(r.RemoteAddr)
			b.log.Warn("mcp request refused: no or wrong credential", "path", r.URL.Path, "method", r.Method, "remote", host, "header_present", got != "")
			b.deny(w)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (b *MCPBearer) deny(w http.ResponseWriter) {
	w.Header().Set("WWW-Authenticate", `Bearer realm="records-mcp"`)
	WriteJSON(w, http.StatusUnauthorized, map[string]string{"error": "a valid credential is required"})
}
