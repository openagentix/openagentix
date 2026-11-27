// Package audit writes one line per tool call. A line holds the tool, the
// target and object names, the outcome and counts. It never holds content,
// event or status text, arguments or a credential.
package audit

import (
	"io"
	"log/slog"
	"regexp"
	"time"
)

// Record is one call. It has no field for content, arguments or errors.
type Record struct {
	Tool       string
	Target     string
	Object     string
	Outcome    string
	Duration   time.Duration
	Bytes      int
	Lines      int
	Redactions int
}

// Outcomes is the closed set of outcome values.
var Outcomes = map[string]bool{"ok": true, "refused": true, "rate_limited": true, "not_ready": true, "not_found": true, "timeout": true, "error": true}

var (
	toolRe = regexp.MustCompile(`^[a-z_]{1,40}$`)
	nameRe = regexp.MustCompile(`^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$`)
)

// Logger writes audit lines.
type Logger struct {
	log    *slog.Logger
	server string
}

// New returns a logger that writes JSON lines to w.
func New(w io.Writer, server string) *Logger {
	return &Logger{log: slog.New(slog.NewJSONHandler(w, nil)), server: server}
}

func safe(re *regexp.Regexp, s string) string {
	if s == "" || re.MatchString(s) {
		return s
	}
	return "[invalid]"
}

// Write logs one line. A tool, target or object that is not a plain name is
// replaced by "[invalid]", and an outcome outside the closed set by "error",
// so a hostile argument cannot reach the log. The tool name is checked
// against the name shape, the target and object against DNS names.
func (l *Logger) Write(r Record) {
	outcome := r.Outcome
	if !Outcomes[outcome] {
		outcome = "error"
	}
	l.log.Info("audit",
		"server", l.server,
		"tool", safe(toolRe, r.Tool),
		"target", safe(nameRe, r.Target),
		"object", safe(nameRe, r.Object),
		"outcome", outcome,
		"duration_ms", r.Duration.Milliseconds(),
		"output_bytes", r.Bytes,
		"lines", r.Lines,
		"redactions", r.Redactions,
	)
}
