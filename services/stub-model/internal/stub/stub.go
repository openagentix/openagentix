// Package stub is a tiny OpenAI-compatible chat server that returns scripted, deterministic answers. It exists so
// that OpenAgentix can be tried without any model provider key. It is NOT a model: it understands two prompts
// (a vulnerability look-up and a fetch request), turns them into one tool call, and reports the tool's result.
package stub

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
)

const (
	maxBody   = 2 << 20
	maxResult = 400 // bytes of a tool result echoed back
	label     = "[stub model] "
	footer    = " (This answer comes from the built-in stub model, not a real LLM.)"
)

type message struct {
	Role       string          `json:"role"`
	Content    json.RawMessage `json:"content"`
	Name       string          `json:"name"`
	ToolCallID string          `json:"tool_call_id"`
	ToolCalls  []struct {
		ID       string `json:"id"`
		Function struct {
			Name string `json:"name"`
		} `json:"function"`
	} `json:"tool_calls"`
}

type tool struct {
	Function struct {
		Name       string `json:"name"`
		Parameters struct {
			Properties map[string]json.RawMessage `json:"properties"`
			Required   []string                   `json:"required"`
		} `json:"parameters"`
	} `json:"function"`
}

type request struct {
	Model    string    `json:"model"`
	Stream   bool      `json:"stream"`
	Messages []message `json:"messages"`
	Tools    []tool    `json:"tools"`
}

// New returns the HTTP handler.
func New() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = io.WriteString(w, "ok") })
	mux.HandleFunc("GET /v1/models", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, map[string]any{"object": "list", "data": []any{map[string]any{"id": "quickstart-stub", "object": "model", "owned_by": "openagentix-stub"}}})
	})
	mux.HandleFunc("POST /v1/chat/completions", chat)
	return mux
}

func writeJSON(w http.ResponseWriter, v any) {
	b, _ := json.Marshal(v)
	w.Header().Set("content-type", "application/json")
	_, _ = w.Write(b)
}

func chat(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBody+1))
	if err != nil || len(body) > maxBody {
		http.Error(w, `{"error":{"message":"request body too large or unreadable"}}`, http.StatusBadRequest)
		return
	}
	var req request
	if err := json.Unmarshal(body, &req); err != nil {
		http.Error(w, `{"error":{"message":"invalid JSON"}}`, http.StatusBadRequest)
		return
	}
	if req.Model == "" {
		req.Model = "quickstart-stub"
	}
	text, call := decide(req)
	prompt := 0
	for _, m := range req.Messages {
		prompt += len(text0(m.Content)) / 4
	}
	if req.Stream {
		stream(w, req.Model, text, call)
		return
	}
	msg := map[string]any{"role": "assistant", "content": text}
	finish := "stop"
	if call != nil {
		msg = map[string]any{"role": "assistant", "content": nil, "tool_calls": []any{call.json(0, false)}}
		finish = "tool_calls"
	}
	writeJSON(w, map[string]any{
		"id": "stub-1", "object": "chat.completion", "created": 1700000000, "model": req.Model,
		"choices": []any{map[string]any{"index": 0, "message": msg, "finish_reason": finish}},
		"usage":   map[string]any{"prompt_tokens": prompt + 1, "completion_tokens": len(text)/4 + 8, "total_tokens": prompt + len(text)/4 + 9},
	})
}

type toolCall struct{ name, args string }

func (c *toolCall) json(index int, withIndex bool) map[string]any {
	m := map[string]any{"id": "call_stub_1", "type": "function", "function": map[string]any{"name": c.name, "arguments": c.args}}
	if withIndex {
		m["index"] = index
	}
	return m
}

func stream(w http.ResponseWriter, model, text string, call *toolCall) {
	w.Header().Set("content-type", "text/event-stream")
	w.Header().Set("cache-control", "no-cache")
	chunk := func(delta map[string]any, finish any) {
		b, _ := json.Marshal(map[string]any{"id": "stub-1", "object": "chat.completion.chunk", "created": 1700000000, "model": model,
			"choices": []any{map[string]any{"index": 0, "delta": delta, "finish_reason": finish}}})
		fmt.Fprintf(w, "data: %s\n\n", b)
	}
	if call != nil {
		chunk(map[string]any{"role": "assistant", "content": nil, "tool_calls": []any{call.json(0, true)}}, nil)
		chunk(map[string]any{}, "tool_calls")
	} else {
		chunk(map[string]any{"role": "assistant", "content": text}, nil)
		chunk(map[string]any{}, "stop")
	}
	fmt.Fprint(w, "data: [DONE]\n\n")
}

// text0 returns the text of a message content, which is a string or an array of parts.
func text0(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var parts []struct {
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &parts) == nil {
		var b strings.Builder
		for _, p := range parts {
			b.WriteString(p.Text)
			b.WriteByte(' ')
		}
		return strings.TrimSpace(b.String())
	}
	return ""
}

var (
	reVersion = regexp.MustCompile(`\b(\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.]+)?)\b`)
	reURL     = regexp.MustCompile(`https?://[^\s"')>]+`)
	reAbout   = regexp.MustCompile(`(?i)\b(?:of|for|in)\s+([A-Za-z0-9@/_.-]+)`)
	reEco     = regexp.MustCompile(`(?i)\((npm|pypi|maven|go|crates\.io|rubygems|nuget)\)`)
)

func decide(req request) (string, *toolCall) {
	if n := len(req.Messages); n > 0 && req.Messages[n-1].Role == "tool" {
		last := req.Messages[n-1]
		name := last.Name
		for _, m := range req.Messages {
			for _, c := range m.ToolCalls {
				if c.ID == last.ToolCallID && name == "" {
					name = c.Function.Name
				}
			}
		}
		if name == "" {
			name = "the tool"
		}
		res := strings.TrimSpace(text0(last.Content))
		if len(res) > maxResult {
			res = res[:maxResult] + "..."
		}
		if res == "" {
			res = "(empty result)"
		}
		return label + "I used the tool " + name + ". It answered: " + res + footer, nil
	}
	prompt := ""
	for i := len(req.Messages) - 1; i >= 0; i-- {
		if req.Messages[i].Role == "user" {
			prompt = text0(req.Messages[i].Content)
			break
		}
	}
	low := strings.ToLower(prompt)
	switch {
	case strings.Contains(low, "vulnerab") || strings.Contains(low, "cve"):
		if t := find(req.Tools, "query_vulnerability"); t != nil {
			return "", &toolCall{t.Function.Name, argsFor(t, prompt)}
		}
	case strings.Contains(low, "fetch") || reURL.MatchString(prompt):
		// Asked on purpose even when the agent's profile does not offer it: the platform decides what is allowed.
		url := reURL.FindString(prompt)
		if url == "" {
			url = "https://example.com/"
		}
		name := "fetch_fetch"
		if t := find(req.Tools, "fetch"); t != nil {
			name = t.Function.Name
		}
		b, _ := json.Marshal(map[string]string{"url": url})
		return "", &toolCall{name, string(b)}
	}
	return label + "I am a scripted stand-in for a language model, so I cannot really answer. Try: \"Look up known vulnerabilities of lodash 4.17.20 (npm)\" and I will call a tool for it." + footer, nil
}

func find(tools []tool, suffix string) *tool {
	for i := range tools {
		if strings.HasSuffix(tools[i].Function.Name, suffix) {
			return &tools[i]
		}
	}
	return nil
}

// argsFor fills the tool's string parameters from the prompt: the package, its ecosystem and a version.
func argsFor(t *tool, prompt string) string {
	pkg := "lodash"
	for _, c := range reAbout.FindAllStringSubmatch(prompt, -1) {
		w := strings.Trim(c[1], ".,;:()")
		if w != "" && !strings.EqualFold(w, "known") && !strings.EqualFold(w, "the") {
			pkg = w
			break
		}
	}
	eco := "npm"
	if m := reEco.FindStringSubmatch(prompt); m != nil {
		eco = m[1]
		if strings.EqualFold(eco, "npm") {
			eco = "npm"
		}
	}
	version := reVersion.FindString(prompt)
	vals := map[string]string{}
	for p := range t.Function.Parameters.Properties {
		switch strings.ToLower(p) {
		case "package_name", "package", "name":
			vals[p] = pkg
		case "ecosystem":
			vals[p] = eco
		case "version":
			if version != "" {
				vals[p] = version
			}
		}
	}
	for _, p := range t.Function.Parameters.Required {
		if _, ok := vals[p]; !ok {
			vals[p] = "example"
		}
	}
	b, _ := json.Marshal(vals)
	return string(b)
}
