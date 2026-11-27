package harness

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
)

// readAudit returns the audit events so far: the tool name of each, in order. The source is a file of JSON lines or
// an http(s) URL that returns a JSON array or JSON lines. An event is an object with a "tool" (or "name") field.
func readAudit(ctx context.Context, hc *http.Client, src, tokenFile string) ([]string, error) {
	var raw []byte
	if strings.HasPrefix(src, "http://") || strings.HasPrefix(src, "https://") {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, src, nil)
		if err != nil {
			return nil, errors.New("bad audit URL")
		}
		if tok, err := readToken(tokenFile); err != nil {
			return nil, err
		} else if tok != "" {
			req.Header.Set("Authorization", "Bearer "+tok)
		}
		resp, err := hc.Do(req)
		if err != nil {
			return nil, errors.New("audit source unreachable")
		}
		defer resp.Body.Close()
		if resp.StatusCode != 200 {
			return nil, fmt.Errorf("audit source answered HTTP %d", resp.StatusCode)
		}
		if raw, err = io.ReadAll(io.LimitReader(resp.Body, maxBody)); err != nil {
			return nil, errors.New("audit source unreadable")
		}
	} else {
		b, err := os.ReadFile(src)
		if err != nil {
			return nil, errors.New("audit file unreadable")
		}
		raw = b
	}
	var objs []map[string]any
	if t := bytes.TrimSpace(raw); len(t) > 0 && t[0] == '[' {
		if err := json.Unmarshal(t, &objs); err != nil {
			return nil, errors.New("audit source is not a JSON array of objects")
		}
	} else {
		sc := bufio.NewScanner(bytes.NewReader(raw))
		sc.Buffer(make([]byte, 0, 64*1024), maxBody)
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if line == "" {
				continue
			}
			var o map[string]any
			if json.Unmarshal([]byte(line), &o) != nil {
				continue // a line that is not JSON (a log line) is not an event
			}
			objs = append(objs, o)
		}
	}
	var tools []string
	for _, o := range objs {
		for _, k := range []string{"tool", "name"} {
			if s, ok := o[k].(string); ok && s != "" {
				tools = append(tools, s)
				break
			}
		}
	}
	return tools, nil
}

// toolIs: the audit name is the expected name, or ends with "_" and the expected name (a tool profile prefixes names).
func toolIs(seen, want string) bool { return seen == want || strings.HasSuffix(seen, "_"+want) }

func firstIndex(seen []string, want string) int {
	for i, s := range seen {
		if toolIs(s, want) {
			return i
		}
	}
	return -1
}

// toolChecks tests the expectations about tool calls. seen is nil and auditErr set when no audit could be read: every
// tool check then fails, because a check that cannot be made must not pass.
func toolChecks(e Expect, seen []string, auditErr error) []Check {
	var out []Check
	add := func(name string, pass bool, detail string) {
		out = append(out, Check{Name: name, Pass: pass, Detail: detail})
	}
	need := len(e.ToolsCalled)+len(e.ToolsNot)+len(e.ToolOrder)+len(e.Requires) > 0 || e.MaxToolCalls > 0
	if !need {
		return nil
	}
	if auditErr != nil {
		add("audit", false, auditErr.Error())
		if e.MaxToolCalls > 0 {
			add("max_tool_calls", false, "no audit events to read")
		}
		for _, t := range e.ToolsCalled {
			add("tools_called["+t+"]", false, "no audit events to read")
		}
		for _, t := range e.ToolsNot {
			add("tools_not_called["+t+"]", false, "no audit events to read")
		}
		if len(e.ToolOrder) > 0 {
			add("tool_order", false, "no audit events to read")
		}
		for _, r := range e.Requires {
			add("requires["+r.Tool+"]", false, "no audit events to read")
		}
		return out
	}
	if e.MaxToolCalls > 0 {
		add("max_tool_calls", len(seen) <= e.MaxToolCalls, fmt.Sprintf("%d tool calls, limit %d", len(seen), e.MaxToolCalls))
	}
	for _, t := range e.ToolsCalled {
		add("tools_called["+t+"]", firstIndex(seen, t) >= 0, "")
	}
	for _, t := range e.ToolsNot {
		add("tools_not_called["+t+"]", firstIndex(seen, t) < 0, "")
	}
	if len(e.ToolOrder) > 0 {
		pos, ok := -1, true
		for _, t := range e.ToolOrder {
			found := -1
			for i := pos + 1; i < len(seen); i++ {
				if toolIs(seen[i], t) {
					found = i
					break
				}
			}
			if found < 0 {
				ok = false
				break
			}
			pos = found
		}
		add("tool_order", ok, "")
	}
	for _, r := range e.Requires {
		ti := firstIndex(seen, r.Tool)
		pass := ti < 0 || (firstIndex(seen, r.After) >= 0 && firstIndex(seen, r.After) < ti)
		d := ""
		if !pass {
			d = r.Tool + " was called without " + r.After + " before it"
		}
		add("requires["+r.Tool+"]", pass, d)
	}
	return out
}

// answerChecks tests properties of the answer text. The detail names the rule, never the answer.
func answerChecks(e Expect, ans string) []Check {
	var out []Check
	for i, expr := range e.AnswerMust {
		out = append(out, Check{Name: fmt.Sprintf("answer_must[%d]", i), Pass: regexp.MustCompile(expr).MatchString(ans), Detail: expr})
	}
	for i, expr := range e.AnswerMustNot {
		out = append(out, Check{Name: fmt.Sprintf("answer_must_not[%d]", i), Pass: !regexp.MustCompile(expr).MatchString(ans), Detail: expr})
	}
	low := strings.ToLower(ans)
	for i, c := range e.Cites {
		out = append(out, Check{Name: fmt.Sprintf("cites[%d]", i), Pass: strings.Contains(low, strings.ToLower(c)), Detail: c})
	}
	return out
}

// stateChecks reads the system of record after the run. The values are not copied into the detail (they may be
// personal data); the detail says what was wrong.
func stateChecks(ctx context.Context, hc *http.Client, e Expect, base, tokenFile string) []Check {
	var out []Check
	tok, tokErr := readToken(tokenFile)
	for i, s := range e.StateChecks {
		name := fmt.Sprintf("state_checks[%d]", i)
		if base == "" {
			out = append(out, Check{Name: name, Detail: "no state base URL given"})
			continue
		}
		if tokErr != nil {
			out = append(out, Check{Name: name, Detail: tokErr.Error()})
			continue
		}
		v, status, err := getJSON(ctx, hc, strings.TrimRight(base, "/")+s.URL, tok)
		if err != nil {
			out = append(out, Check{Name: name, Detail: s.URL + ": " + err.Error()})
			continue
		}
		_ = status
		got, found := walk(v, s.Path)
		pass, detail := false, ""
		switch {
		case s.Exists != nil:
			pass = found == *s.Exists
			if !pass {
				detail = fmt.Sprintf("%s %s: exists is %v, expected %v", s.URL, s.Path, found, *s.Exists)
			}
		case !found:
			detail = fmt.Sprintf("%s: path %q not found", s.URL, s.Path)
		case s.Count != nil:
			n := -1
			switch x := got.(type) {
			case []any:
				n = len(x)
			case map[string]any:
				n = len(x)
			}
			pass = n == *s.Count
			if !pass {
				detail = fmt.Sprintf("%s %s: count is %d, expected %d", s.URL, s.Path, n, *s.Count)
			}
		case s.Matches != "":
			pass = regexp.MustCompile(s.Matches).MatchString(scalarText(got))
			if !pass {
				detail = fmt.Sprintf("%s %s: value does not match %s", s.URL, s.Path, s.Matches)
			}
		default:
			a, _ := json.Marshal(got)
			b, _ := json.Marshal(s.Equals)
			pass = bytes.Equal(a, b)
			if !pass {
				detail = fmt.Sprintf("%s %s: value is not the expected one", s.URL, s.Path)
			}
		}
		out = append(out, Check{Name: name, Pass: pass, Detail: detail})
	}
	return out
}

func getJSON(ctx context.Context, hc *http.Client, url, token string) (any, int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, 0, errors.New("bad URL")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := hc.Do(req)
	if err != nil {
		return nil, 0, errors.New("request failed")
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, resp.StatusCode, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	var v any
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxBody)).Decode(&v); err != nil {
		return nil, resp.StatusCode, errors.New("not JSON")
	}
	return v, resp.StatusCode, nil
}

// walk follows a dot path through objects and arrays ("items.0.status"). An empty path is the whole value.
func walk(v any, path string) (any, bool) {
	if path == "" {
		return v, true
	}
	for _, p := range strings.Split(path, ".") {
		switch x := v.(type) {
		case map[string]any:
			n, ok := x[p]
			if !ok {
				return nil, false
			}
			v = n
		case []any:
			i, err := strconv.Atoi(p)
			if err != nil || i < 0 || i >= len(x) {
				return nil, false
			}
			v = x[i]
		default:
			return nil, false
		}
	}
	return v, true
}

func scalarText(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	b, _ := json.Marshal(v)
	return string(b)
}
