// Package redact holds the scanner that every string leaving the diagnostics
// servers goes through, and the helpers that clean and cut text first.
//
// Redaction reduces leaks; it does not prove there are none. A value split
// across lines or fields in a way the pair rules do not see, encoded twice, or
// in a format the scanner does not know passes (ADR 0025, section 2).
package redact

import (
	"encoding/base64"
	"encoding/hex"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Marker replaces every match.
const Marker = "[redacted]"

// CutMarker ends a string that Cut shortened.
const CutMarker = "[cut]"

const (
	pairWords = `password|passwd|passphrase|secret|token|api[_-]?key|access[_-]?key|account[_-]?key|private[_-]?key|client[_-]?secret|client-key-data|credential|auth[_-]?key`
	flagWords = `password|passwd|passphrase|secret|token|api-?key|access-?key|client-?secret|private-?key|credential`
	hdrNames  = `authorization|proxy-authorization|cookie|set-cookie|x-api-key|x-auth-token|x-amz-security-token|x-csrf-token`
	prefixes  = `ghp_|gho_|ghu_|ghs_|ghr_|github_pat_|glpat-|xox[abprs]-|xapp-|sk-ant-|sk-|vk-|npm_|pypi-|hf_|sk_live_|rk_live_|shpat_|dckr_pat_`
)

// rule replaces capture group `group` of every match with the marker.
type rule struct {
	re    *regexp.Regexp
	group int
	// keep, if set, decides from the matched text whether to leave it alone.
	keep func(string) bool
}

var plainRules = []rule{
	{re: regexp.MustCompile(`(?s)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)`), group: 0},
	{re: regexp.MustCompile(`\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*`), group: 0},
	{re: regexp.MustCompile(`\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA|AIPA)[A-Z0-9]{16}\b`), group: 0},
	{re: regexp.MustCompile(`\bAIza[0-9A-Za-z_-]{35}\b`), group: 0},
	// structured header pairs, JSON and YAML
	{re: regexp.MustCompile(`(?i)("name"\s*:\s*"(?:` + hdrNames + `)"\s*,\s*"value"\s*:\s*)("[^"]*")`), group: 2},
	{re: regexp.MustCompile(`(?i)(name:\s*"?(?:` + hdrNames + `)"?\s*\n\s*value:\s*)([^\n]+)`), group: 2},
	// header lines
	{re: regexp.MustCompile(`(?i)\b(` + hdrNames + `)(\s*:\s*)([^\r\n]+)`), group: 3},
	// Bearer and Basic credentials in free text
	{re: regexp.MustCompile(`(?i)\b(bearer|basic)(\s+)([A-Za-z0-9._~+/=-]{8,})`), group: 3, keep: func(v string) bool { return !looksSecret(v) }},
	// URL with a password in the user part
	{re: regexp.MustCompile(`([A-Za-z][A-Za-z0-9+.\-]*://[^\s:/@]*:)([^\s@/]+)(@)`), group: 2},
	// token prefixes, anchored at a word start and followed by 16 token characters
	{re: regexp.MustCompile(`(^|[^A-Za-z0-9])((?:` + prefixes + `)[A-Za-z0-9_-]{16,})`), group: 2},
	// chat bot tokens: digits, a colon and 35 or more token characters
	{re: regexp.MustCompile(`(^|[^0-9])(\d{6,12}:[A-Za-z0-9_-]{35,})`), group: 2},
	// secret flag and its value as the next word
	{re: regexp.MustCompile(`(?i)(--?[a-z0-9_-]*(?:` + flagWords + `)[a-z0-9_-]*\s+)([^\s-]\S*)`), group: 2},
	// key=value, key: value, JSON and YAML pairs
	{re: regexp.MustCompile(`(?i)(["']?[A-Za-z0-9_.\-]*(?:` + pairWords + `)[A-Za-z0-9_.\-]*["']?\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s,;&"'}\]]+)`), group: 2},
}

var (
	runRe    = regexp.MustCompile(`[A-Za-z0-9+/_=-]{16,}`)
	hexRe    = regexp.MustCompile(`^[0-9a-fA-F]+$`)
	ansiRe   = regexp.MustCompile("\x1b\\[[0-?]*[ -/]*[@-~]|\x1b\\][^\x07\x1b]*(?:\x07|\x1b\\\\)?|\x1b[@-Z\\\\-_]")
	pFlagRe  = regexp.MustCompile(`(^|\s)(-p\s+)\S+`)
	flagName = regexp.MustCompile(`(?i)^-{1,2}[a-z0-9_-]*(?:password|passwd|passphrase|pass|token|secret|key|credential)[a-z0-9_-]*$`)
)

// looksSecret says whether a word after "Bearer" or "Basic" looks like a
// credential and not an ordinary word.
func looksSecret(v string) bool {
	for i, r := range v {
		if unicode.IsDigit(r) || strings.ContainsRune("._~+/=-", r) || (i > 0 && unicode.IsUpper(r)) {
			return true
		}
	}
	return false
}

// Scanner finds secret-shaped text. Create it with New. It holds no state.
type Scanner struct{}

// New returns a scanner.
func New() *Scanner { return &Scanner{} }

// Scrub replaces secret-shaped text and returns the new string and the number of matches.
func (s *Scanner) Scrub(in string) (string, int) {
	out, n := plain(in)
	out, m := encoded(out)
	return out, n + m
}

func plain(in string) (string, int) {
	count := 0
	for _, r := range plainRules {
		in = replaceGroup(in, r, &count)
	}
	return in, count
}

func replaceGroup(in string, r rule, count *int) string {
	idx := r.re.FindAllStringSubmatchIndex(in, -1)
	if idx == nil {
		return in
	}
	var sb strings.Builder
	last := 0
	for _, m := range idx {
		start, end := m[2*r.group], m[2*r.group+1]
		if start < 0 {
			continue
		}
		val := in[start:end]
		if strings.HasPrefix(val, "[redacted") || val == `"`+Marker+`"` || (r.keep != nil && r.keep(val)) {
			continue
		}
		sb.WriteString(in[last:start])
		sb.WriteString(Marker)
		last = end
		*count++
	}
	sb.WriteString(in[last:])
	return sb.String()
}

// encoded finds base64 and hex runs that decode to something plain() would redact.
func encoded(in string) (string, int) {
	count := 0
	out := runRe.ReplaceAllStringFunc(in, func(run string) string {
		if decodesToSecret(run) {
			count++
			return Marker
		}
		return run
	})
	return out, count
}

func decodesToSecret(run string) bool {
	trim := strings.TrimRight(run, "=")
	// hex, upper or lower case, whole run or one character short
	for off := 0; off < 2 && off < len(trim); off++ {
		h := trim[off:]
		if len(h)%2 == 1 {
			h = h[:len(h)-1]
		}
		if len(h) >= 16 && hexRe.MatchString(h) {
			if b, err := hex.DecodeString(h); err == nil && hit(b) {
				return true
			}
		}
	}
	// base64, standard or URL alphabet, with or without padding, from four start offsets
	norm := strings.NewReplacer("-", "+", "_", "/").Replace(trim)
	for off := 0; off < 4 && off < len(norm); off++ {
		s := norm[off:]
		if len(s)%4 == 1 {
			s = s[:len(s)-1]
		}
		if len(s) < 12 {
			continue
		}
		if b, err := base64.RawStdEncoding.DecodeString(s); err == nil && hit(b) {
			return true
		}
	}
	return false
}

func hit(b []byte) bool {
	text := strings.ToValidUTF8(string(b), " ")
	_, n := plain(text)
	return n > 0
}

// StripControl removes ANSI escape sequences and control characters other than
// tab, and replaces invalid UTF-8.
func StripControl(in string) string {
	in = strings.ToValidUTF8(in, "\ufffd")
	in = ansiRe.ReplaceAllString(in, "")
	var sb strings.Builder
	sb.Grow(len(in))
	for _, r := range in {
		switch {
		case r == '\t':
			sb.WriteRune(r)
		case r < 0x20, r == 0x7f, r >= 0x80 && r <= 0x9f:
		case r >= 0x200b && r <= 0x200f, r >= 0x202a && r <= 0x202e, r >= 0x2066 && r <= 0x2069, r == 0xfeff:
		default:
			sb.WriteRune(r)
		}
	}
	return sb.String()
}

// Cut shortens s to at most n bytes, ending with CutMarker, never inside a rune.
func Cut(s string, n int) string {
	if len(s) <= n {
		return s
	}
	if n <= len(CutMarker) {
		return CutMarker[:max(n, 0)]
	}
	keep := n - len(CutMarker)
	for keep > 0 && !utf8.RuneStart(s[keep]) {
		keep--
	}
	return s[:keep] + CutMarker
}

// SecretFlag says whether an argument looks like a flag whose value is a
// secret (--password, --token, -p and similar).
func SecretFlag(arg string) bool {
	return arg == "-p" || flagName.MatchString(arg)
}

// ScrubScript redacts "-p value" inside a shell script argument, on top of Scrub.
func (s *Scanner) ScrubScript(in string) (string, int) {
	n := 0
	if strings.ContainsAny(in, " \t\n") {
		in = pFlagRe.ReplaceAllStringFunc(in, func(m string) string {
			n++
			sub := pFlagRe.FindStringSubmatch(m)
			return sub[1] + sub[2] + Marker
		})
	}
	out, k := s.Scrub(in)
	return out, n + k
}
