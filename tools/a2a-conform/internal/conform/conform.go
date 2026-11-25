// Package conform checks, over HTTP, that an agent speaks the slice of A2A 1.0 that OpenAgentix needs
// from a container agent (docs/decisions/0015-bring-your-own-agent.md, "Conformance contract").
// It never sends a secret and needs no model key: SendMessage is answered by whatever model endpoint
// the agent was started with (see FakeModel for a local one).
package conform

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"
)

type Status string

const (
	Pass   Status = "PASS"
	Fail   Status = "FAIL"
	Warn   Status = "WARN"
	Skip   Status = "SKIP"
	Manual Status = "MANUAL"
)

// Result is one row of the report.
type Result struct {
	ID     string
	Title  string
	Status Status
	Detail string
	Fix    string
}

type Options struct {
	CardTimeout   time.Duration // default 2s, the contract limit
	CallTimeout   time.Duration // default 30s for each JSON-RPC call
	SkipPortCheck bool
}

const maxCard = 64 << 10

// Run checks the agent at base (for example http://localhost:8080). The first result is always "card".
func Run(ctx context.Context, base string, o Options) []Result {
	if o.CardTimeout == 0 {
		o.CardTimeout = 2 * time.Second
	}
	if o.CallTimeout == 0 {
		o.CallTimeout = 30 * time.Second
	}
	base = strings.TrimRight(base, "/")
	var out []Result
	add := func(r ...Result) { out = append(out, r...) }

	card, cr := fetchCard(ctx, base, o)
	add(cr)
	if !o.SkipPortCheck {
		add(checkPort(base))
	}
	if card == nil {
		add(ManualChecks()...)
		return out
	}
	add(checkFields(card), checkInterface(card))

	c := &rpc{base: base, timeout: o.CallTimeout}
	sm, tid := checkSend(ctx, c, o)
	add(sm)
	if tid != "" {
		add(checkGetTask(ctx, c, tid))
	} else {
		add(Result{ID: "get-task", Title: "GetTask works for a returned task id", Status: Skip, Detail: "SendMessage returned a message, not a task"})
	}
	add(checkStreaming(ctx, c, card))
	add(checkBadJSON(ctx, c), checkUnknown(ctx, c), checkBadParams(ctx, c))
	add(ManualChecks()...)
	return out
}

// Failed reports whether any check failed. Warnings and manual items do not fail the run.
func Failed(rs []Result) bool {
	for _, r := range rs {
		if r.Status == Fail {
			return true
		}
	}
	return false
}

func fetchCard(ctx context.Context, base string, o Options) (map[string]any, Result) {
	r := Result{ID: "card", Title: "Agent card at /.well-known/agent-card.json"}
	ctx, cancel := context.WithTimeout(ctx, o.CardTimeout)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, base+"/.well-known/agent-card.json", nil)
	start := time.Now()
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		r.Status = Fail
		r.Detail = shortErr(err)
		if ctx.Err() != nil {
			r.Fix = "The card must answer within 2 seconds. Serve it from memory and do not call a model or a database to build it."
		} else {
			r.Fix = "Could not connect. Check the agent is running, the URL and port are right, and the agent listens on 0.0.0.0 (not 127.0.0.1) inside a container."
		}
		return nil, r
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, maxCard+1))
	r.Detail = fmt.Sprintf("HTTP %d, %d bytes, %s", resp.StatusCode, len(body), time.Since(start).Round(time.Millisecond))
	switch {
	case resp.StatusCode != 200:
		r.Status, r.Fix = Fail, "Serve GET /.well-known/agent-card.json with HTTP 200. The platform probes this path for readiness."
	case len(body) > maxCard:
		r.Status, r.Fix = Fail, "The card must be at most 64 KiB. Shorten skill descriptions and examples."
	case time.Since(start) > o.CardTimeout:
		r.Status, r.Fix = Fail, "The card must answer within 2 seconds."
	default:
		var m map[string]any
		if err := json.Unmarshal(body, &m); err != nil {
			r.Status, r.Fix = Fail, "The card must be a JSON object. Set Content-Type: application/json and return JSON, not HTML."
			return nil, r
		}
		r.Status = Pass
		return m, r
	}
	return nil, r
}

func checkFields(card map[string]any) Result {
	r := Result{ID: "card-fields", Title: "Card has the required fields"}
	var missing []string
	for _, k := range []string{"name", "description", "version"} {
		if s, _ := card[k].(string); s == "" {
			missing = append(missing, k)
		}
	}
	if a, _ := card["supportedInterfaces"].([]any); len(a) == 0 {
		missing = append(missing, "supportedInterfaces")
	}
	if _, ok := card["capabilities"].(map[string]any); !ok {
		missing = append(missing, "capabilities")
	}
	for _, k := range []string{"defaultInputModes", "defaultOutputModes"} {
		if a, _ := card[k].([]any); len(a) == 0 {
			missing = append(missing, k)
		}
	}
	if _, ok := card["skills"].([]any); !ok {
		missing = append(missing, "skills")
	}
	if len(missing) > 0 {
		r.Status = Fail
		r.Detail = "missing or empty: " + strings.Join(missing, ", ")
		r.Fix = "Add the fields " + strings.Join(missing, ", ") + " to the card. Names follow A2A 1.0 (camelCase). skills may be an empty list, but the key must exist."
		return r
	}
	r.Status = Pass
	return r
}

func checkInterface(card map[string]any) Result {
	r := Result{ID: "interface", Title: "Card lists a JSONRPC interface, protocol version 1.0"}
	a, _ := card["supportedInterfaces"].([]any)
	var seen []string
	for _, e := range a {
		m, _ := e.(map[string]any)
		b, _ := m["protocolBinding"].(string)
		v, _ := m["protocolVersion"].(string)
		seen = append(seen, b+" "+v)
		if b == "JSONRPC" && v == "1.0" {
			r.Status = Pass
			return r
		}
	}
	r.Status = Fail
	r.Detail = "found: " + strings.Join(seen, ", ")
	r.Fix = `Add {"url": "...", "protocolBinding": "JSONRPC", "protocolVersion": "1.0"} to supportedInterfaces. The platform speaks A2A 1.0 JSON-RPC only and does not translate older versions (0.3 is not enough).`
	return r
}

// ---- JSON-RPC helpers

type rpc struct {
	base    string
	timeout time.Duration
}

type rpcReply struct {
	status int
	ctype  string
	raw    []byte
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
	valid bool // body parsed as a JSON-RPC object
}

func (c *rpc) post(ctx context.Context, body string, accept string) (*rpcReply, *http.Response, error) {
	ctx, cancel := context.WithTimeout(ctx, c.timeout)
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, c.base+"/", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	if accept != "" {
		req.Header.Set("Accept", accept)
	}
	req.Header.Set("A2A-Version", "1.0")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		cancel()
		return nil, nil, err
	}
	if accept == "text/event-stream" && strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
		// the caller reads the stream and calls resp.Body.Close; cancel when the body is closed
		resp.Body = &cancelBody{resp.Body, cancel}
		return &rpcReply{status: resp.StatusCode, ctype: resp.Header.Get("Content-Type")}, resp, nil
	}
	defer cancel()
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	rep := &rpcReply{status: resp.StatusCode, ctype: resp.Header.Get("Content-Type"), raw: raw}
	var probe map[string]json.RawMessage
	if json.Unmarshal(raw, &probe) == nil {
		_, hasRes := probe["result"]
		_, hasErr := probe["error"]
		rep.valid = hasRes || hasErr
		_ = json.Unmarshal(raw, rep)
	}
	return rep, resp, nil
}

type cancelBody struct {
	io.ReadCloser
	cancel context.CancelFunc
}

func (b *cancelBody) Close() error { b.cancel(); return b.ReadCloser.Close() }

func call(method, params string) string {
	if params == "" {
		params = "null"
	}
	return fmt.Sprintf(`{"jsonrpc":"2.0","id":"conform-1","method":%q,"params":%s}`, method, params)
}

const helloParams = `{"message":{"messageId":"conform-msg-1","role":"ROLE_USER","parts":[{"text":"Hello from the conformance checker. Reply in one short sentence."}]}}`

func normState(s string) string {
	s = strings.ToUpper(strings.TrimPrefix(strings.ToUpper(s), "TASK_STATE_"))
	return strings.ReplaceAll(s, "-", "_")
}

func isFinalOrWaiting(s string) bool {
	switch normState(s) {
	case "COMPLETED", "FAILED", "CANCELED", "CANCELLED", "REJECTED", "INPUT_REQUIRED", "AUTH_REQUIRED":
		return true
	}
	return false
}

func taskState(t map[string]any) string {
	st, _ := t["status"].(map[string]any)
	s, _ := st["state"].(string)
	return s
}

func checkSend(ctx context.Context, c *rpc, o Options) (Result, string) {
	r := Result{ID: "send-message", Title: "SendMessage returns a message or a task"}
	rep, _, err := c.post(ctx, call("SendMessage", helloParams), "application/json")
	if err != nil {
		r.Status, r.Detail, r.Fix = Fail, shortErr(err), "POST / did not answer. Serve JSON-RPC at the root path / (the platform calls POST on the base URL) and answer within the time limit."
		return r, ""
	}
	if !rep.valid {
		r.Status = Fail
		r.Detail = fmt.Sprintf("HTTP %d, not a JSON-RPC reply", rep.status)
		r.Fix = `Answer POST / with a JSON-RPC 2.0 object: {"jsonrpc":"2.0","id":<same id>,"result":{"message":{...}}}.`
		return r, ""
	}
	if rep.Error != nil {
		r.Status = Fail
		r.Detail = fmt.Sprintf("error %d: %s", rep.Error.Code, rep.Error.Message)
		r.Fix = "SendMessage returned an error for a plain text message. Start the agent with OPENAI_BASE_URL, OPENAI_API_KEY and OPENAGENTIX_MODEL set (for a test, point OPENAI_BASE_URL at the checker's --fake-model address), then run the checker again."
		return r, ""
	}
	var res map[string]json.RawMessage
	_ = json.Unmarshal(rep.Result, &res)
	_, hasMsg := res["message"]
	_, hasTask := res["task"]
	switch {
	case hasMsg && hasTask:
		r.Status, r.Fix = Fail, "The result must hold message or task, not both."
		return r, ""
	case !hasMsg && !hasTask:
		r.Status = Fail
		r.Detail = "result has neither message nor task"
		r.Fix = `In A2A 1.0 the result of SendMessage is {"message": {...}} or {"task": {...}}. Wrap the answer in one of them (a bare string or a "kind" field is the older 0.3 shape).`
		return r, ""
	case hasMsg:
		var m struct {
			Parts []json.RawMessage `json:"parts"`
			Role  string            `json:"role"`
		}
		_ = json.Unmarshal(res["message"], &m)
		if len(m.Parts) == 0 || m.Role == "" {
			r.Status, r.Detail = Fail, "message has no parts or no role"
			r.Fix = `Return a message with "role": "ROLE_AGENT", a "messageId" and at least one part, for example {"text": "..."}.`
			return r, ""
		}
		r.Status = Pass
		r.Detail = "message"
		return r, ""
	}
	var t map[string]any
	_ = json.Unmarshal(res["task"], &t)
	id, _ := t["id"].(string)
	st := taskState(t)
	if id == "" || st == "" {
		r.Status, r.Detail = Fail, "task has no id or no status.state"
		r.Fix = `A task needs "id" and "status": {"state": "TASK_STATE_COMPLETED"} (or another state).`
		return r, ""
	}
	r.Detail = "task " + id + " state " + st
	if !isFinalOrWaiting(st) {
		deadline := time.Now().Add(o.CallTimeout)
		for time.Now().Before(deadline) && !isFinalOrWaiting(st) {
			time.Sleep(200 * time.Millisecond)
			if s, ok := pollTask(ctx, c, id); ok {
				st = s
			}
		}
		if !isFinalOrWaiting(st) {
			r.Status = Fail
			r.Detail = "task stayed in state " + st
			r.Fix = "The task never reached a terminal or waiting state (completed, failed, canceled, rejected, input required, auth required). Move it on, or answer with a message."
			return r, ""
		}
	}
	r.Status = Pass
	return r, id
}

func pollTask(ctx context.Context, c *rpc, id string) (string, bool) {
	rep, _, err := c.post(ctx, call("GetTask", fmt.Sprintf(`{"id":%q}`, id)), "application/json")
	if err != nil || rep.Error != nil || !rep.valid {
		return "", false
	}
	var t map[string]any
	_ = json.Unmarshal(rep.Result, &t)
	if inner, ok := t["task"].(map[string]any); ok {
		t = inner
	}
	return taskState(t), taskState(t) != ""
}

func checkGetTask(ctx context.Context, c *rpc, id string) Result {
	r := Result{ID: "get-task", Title: "GetTask works for a returned task id"}
	if _, ok := pollTask(ctx, c, id); ok {
		r.Status = Pass
		return r
	}
	r.Status = Fail
	r.Detail = "GetTask for " + id + " did not return a task"
	r.Fix = "If you return tasks, implement GetTask with params {\"id\": ...}. If you do not need tasks, return a message from SendMessage instead."
	return r
}

func checkStreaming(ctx context.Context, c *rpc, card map[string]any) Result {
	r := Result{ID: "streaming", Title: "Streaming matches the card"}
	caps, _ := card["capabilities"].(map[string]any)
	claims, _ := caps["streaming"].(bool)
	rep, resp, err := c.post(ctx, call("SendStreamingMessage", helloParams), "text/event-stream")
	if err != nil {
		r.Status, r.Detail = Fail, shortErr(err)
		r.Fix = "SendStreamingMessage did not answer. Either implement it or set capabilities.streaming to false."
		return r
	}
	isSSE := resp != nil && strings.HasPrefix(rep.ctype, "text/event-stream")
	if !claims {
		if isSSE {
			resp.Body.Close()
		}
		if isSSE || (rep.valid && rep.Error == nil) {
			r.Status, r.Detail = Fail, "streaming works but the card says capabilities.streaming is false"
			r.Fix = "Set capabilities.streaming to true in the card, or answer SendStreamingMessage with error -32004 (unsupported operation)."
			return r
		}
		if !rep.valid || rep.Error == nil {
			r.Status, r.Detail = Fail, fmt.Sprintf("HTTP %d, no JSON-RPC error", rep.status)
			r.Fix = "When streaming is not supported, answer SendStreamingMessage with a JSON-RPC error, code -32004."
			return r
		}
		if rep.Error.Code != -32004 {
			r.Status, r.Detail = Warn, fmt.Sprintf("error code %d, expected -32004", rep.Error.Code)
			r.Fix = "Use code -32004 (unsupported operation) for SendStreamingMessage when streaming is not supported."
			return r
		}
		r.Status, r.Detail = Pass, "not claimed, refused with -32004"
		return r
	}
	if !isSSE {
		r.Status = Fail
		r.Detail = fmt.Sprintf("card says streaming, but the reply was %q, not text/event-stream", rep.ctype)
		r.Fix = "Answer SendStreamingMessage with Content-Type: text/event-stream and one `data: {json-rpc object}` line per event, or set capabilities.streaming to false."
		return r
	}
	defer resp.Body.Close()
	events, final := 0, false
	sc := bufio.NewScanner(resp.Body)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		line := sc.Text()
		d, ok := strings.CutPrefix(line, "data:")
		if !ok {
			continue
		}
		var ev struct {
			Result map[string]any `json:"result"`
			Error  any            `json:"error"`
		}
		if json.Unmarshal([]byte(strings.TrimSpace(d)), &ev) != nil || (ev.Result == nil && ev.Error == nil) {
			r.Status, r.Detail = Fail, "an event is not a JSON-RPC object: "+truncate(d, 80)
			r.Fix = "Each `data:` line must hold one JSON-RPC 2.0 response object with a result."
			return r
		}
		events++
		final = final || eventFinal(ev.Result)
	}
	if events == 0 || !final {
		r.Status = Fail
		r.Detail = fmt.Sprintf("%d events, none terminal", events)
		r.Fix = "The stream must end with a terminal event: a statusUpdate or task in a terminal or waiting state (for example TASK_STATE_COMPLETED), or a final message. Then close the stream."
		return r
	}
	r.Status, r.Detail = Pass, fmt.Sprintf("%d events, ends terminal", events)
	return r
}

func eventFinal(res map[string]any) bool {
	if res == nil {
		return false
	}
	if _, ok := res["message"]; ok {
		return true
	}
	for _, k := range []string{"task", "statusUpdate"} {
		if m, ok := res[k].(map[string]any); ok && isFinalOrWaiting(taskState(m)) {
			return true
		}
	}
	return false
}

func errCheck(ctx context.Context, c *rpc, id, title, body string, code int, fix string) Result {
	r := Result{ID: id, Title: title}
	rep, _, err := c.post(ctx, body, "application/json")
	if err != nil {
		r.Status, r.Detail, r.Fix = Fail, shortErr(err), fix
		return r
	}
	switch {
	case !rep.valid || rep.Error == nil:
		r.Status = Fail
		r.Detail = fmt.Sprintf("HTTP %d, no JSON-RPC error object: %s", rep.status, truncate(string(rep.raw), 80))
		r.Fix = fix
	case rep.Error.Code != code || rep.Error.Message == "":
		r.Status = Fail
		r.Detail = fmt.Sprintf("error code %d, message %q", rep.Error.Code, rep.Error.Message)
		r.Fix = fix
	default:
		r.Status = Pass
		r.Detail = fmt.Sprintf("error %d", code)
	}
	return r
}

func checkBadJSON(ctx context.Context, c *rpc) Result {
	return errCheck(ctx, c, "bad-json", "Invalid JSON gives error -32700", `{not json`, -32700,
		`Answer a body that is not valid JSON with {"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse error"}}. Do not crash and do not return an HTML error page.`)
}

func checkUnknown(ctx context.Context, c *rpc) Result {
	return errCheck(ctx, c, "unknown-method", "Unknown method gives error -32601", call("NoSuchMethod", ""), -32601,
		`Answer an unknown method with error code -32601 ("method not found") and a message.`)
}

func checkBadParams(ctx context.Context, c *rpc) Result {
	return errCheck(ctx, c, "bad-params", "SendMessage with no parts gives error -32602",
		call("SendMessage", `{"message":{"messageId":"conform-msg-2","role":"ROLE_USER","parts":[]}}`), -32602,
		`Validate params. A SendMessage whose message has no parts must get error code -32602 ("invalid params"), not a success and not a crash.`)
}

func checkPort(base string) Result {
	r := Result{ID: "port", Title: "Listens on a port of 1024 or higher"}
	u, err := url.Parse(base)
	if err != nil || u.Hostname() == "" {
		r.Status, r.Detail, r.Fix = Fail, "bad URL", "Pass a URL like http://localhost:8080."
		return r
	}
	ps := u.Port()
	if ps == "" {
		r.Status = Warn
		r.Detail = "no port in the URL"
		r.Fix = "The platform sets the port (spec.runtime.container.port, 1024 to 65535) and calls it. Test with the same port, for example http://localhost:8080."
		return r
	}
	p, _ := strconv.Atoi(ps)
	if p < 1024 || p > 65535 {
		r.Status, r.Detail = Fail, "port "+ps
		r.Fix = "A container agent runs as a non-root user, so it cannot bind below 1024. Listen on 8080 or another port from 1024 to 65535 and set that port in the AgentDefinition."
		return r
	}
	r.Status, r.Detail = Pass, "port "+ps
	return r
}

// ManualChecks are contract items no HTTP probe can prove. They are always listed, never pass or fail.
func ManualChecks() []Result {
	return []Result{
		{ID: "env", Title: "Reads its settings from the documented variables", Status: Manual,
			Detail: "OPENAI_BASE_URL, OPENAI_API_KEY, OPENAGENTIX_MODEL",
			Fix:    "Use only these three for the model (and LISTEN_ADDR or PORT only as your own optional override). Do not read a key from a file or the Kubernetes API."},
		{ID: "non-root", Title: "Runs as user 65532", Status: Manual,
			Detail: "docker run --user 65532:65532 ...",
			Fix:    "Set USER 65532:65532 in the Dockerfile and do not need root-owned paths. Run the checker against the container started with that user."},
		{ID: "read-only-root", Title: "Works with a read-only root file system", Status: Manual,
			Detail: "docker run --read-only --tmpfs /tmp ...",
			Fix:    "Write only under /tmp. Frameworks that write caches or .pyc files into the image need HOME=/tmp and PYTHONDONTWRITEBYTECODE=1 (Python) or similar. Run the checker against a container started with --read-only."},
		{ID: "network", Title: "Needs no network except the model gateway", Status: Manual,
			Detail: "docker run --network <only the model endpoint> ...",
			Fix:    "Do not download models, call telemetry or package indexes at run time. The platform allows DNS and the model gateway only. Run the container with no internet and check the checks above still pass."},
	}
}

// Render writes a table of results, then the fix text for every row that is not a pass.
func Render(w io.Writer, rs []Result) {
	tw := tabwriter.NewWriter(w, 0, 4, 2, ' ', 0)
	fmt.Fprintln(tw, "RESULT\tCHECK\tDETAIL")
	for _, r := range rs {
		fmt.Fprintf(tw, "%s\t%s\t%s\n", r.Status, r.Title, r.Detail)
	}
	_ = tw.Flush()
	var fixes []Result
	for _, r := range rs {
		if r.Status != Pass && r.Status != Skip && r.Fix != "" {
			fixes = append(fixes, r)
		}
	}
	sort.SliceStable(fixes, func(i, j int) bool { return rank(fixes[i].Status) < rank(fixes[j].Status) })
	if len(fixes) > 0 {
		fmt.Fprintln(w, "\nWhat to do:")
		for _, r := range fixes {
			fmt.Fprintf(w, "  [%s] %s\n      %s\n", r.Status, r.Title, r.Fix)
		}
	}
	n := map[Status]int{}
	for _, r := range rs {
		n[r.Status]++
	}
	fmt.Fprintf(w, "\n%d passed, %d failed, %d warnings, %d skipped, %d to check by hand\n", n[Pass], n[Fail], n[Warn], n[Skip], n[Manual])
}

func rank(s Status) int {
	switch s {
	case Fail:
		return 0
	case Warn:
		return 1
	}
	return 2
}

func shortErr(err error) string { return truncate(err.Error(), 140) }

func truncate(s string, n int) string {
	s = strings.TrimSpace(strings.ReplaceAll(s, "\n", " "))
	if len(s) > n {
		return s[:n] + "..."
	}
	return s
}

// FakeModel is a tiny OpenAI-compatible endpoint (chat completions only) for testing an agent without a paid key.
func FakeModel() http.Handler {
	h := func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, io.LimitReader(r.Body, 1<<20))
		var b bytes.Buffer
		_ = json.NewEncoder(&b).Encode(map[string]any{
			"id": "fake-1", "object": "chat.completion", "model": "fake-model",
			"choices": []map[string]any{{"index": 0, "finish_reason": "stop",
				"message": map[string]string{"role": "assistant", "content": "Hello from the fake model."}}},
		})
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(b.Bytes())
	}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /chat/completions", h)
	mux.HandleFunc("POST /v1/chat/completions", h)
	return mux
}
