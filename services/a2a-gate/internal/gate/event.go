package gate

// Event callers (ADR 0027): a caller whose rule has an `event` block sends one short text that matches the operator's
// pattern, and nothing else. The gate parses the message strictly, builds its own body and its own request headers
// (it never forwards the caller's bytes), asks the runtime to return at once, answers the sender with the task id and state
// only, and limits the caller's rate and open calls. The state is a few numbers per event caller, in this process.

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/openagentix/openagentix/services/a2a-gate/internal/rules"
)

const (
	maxEventAnswer = 1 << 20 // the runtime's answer to an event call: larger is 502
)

var (
	messageIDRe = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)
	jsonIntRe   = regexp.MustCompile(`^-?(0|[1-9][0-9]{0,18})$`)
	taskIDRe    = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)
	taskStateRe = regexp.MustCompile(`^TASK_STATE_[A-Z_]{1,32}$`)

	traceparentRe = regexp.MustCompile(`^00-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$`)
	tsKeyRe       = regexp.MustCompile(`^([a-z][a-z0-9_*/-]{0,255}|[a-z0-9][a-z0-9_*/-]{0,240}@[a-z][a-z0-9_*/-]{0,13})$`)
	tsValueRe     = regexp.MustCompile(`^[\x20-\x2b\x2d-\x3c\x3e-\x7e]{0,255}[\x21-\x2b\x2d-\x3c\x3e-\x7e]$`)
)

// eventCall is what one accepted event request carries from the handler to the proxy.
type eventCall struct {
	id                      json.RawMessage // the caller's JSON-RPC id, re-encoded
	traceparent, tracestate string
}

// eventState is the memory of one event caller in this process: a token bucket and the open calls.
type eventState struct {
	mu     sync.Mutex
	tokens float64
	last   time.Time
	open   int
}

func (h *handler) now() time.Time {
	if h.o.Now != nil {
		return h.o.Now()
	}
	return time.Now()
}

func (h *handler) eventState(c *rules.Caller) *eventState {
	h.evMu.Lock()
	defer h.evMu.Unlock()
	if h.events == nil {
		h.events = map[string]*eventState{}
	}
	s, ok := h.events[c.Name]
	if !ok {
		s = &eventState{tokens: float64(c.Event.Rate.Burst), last: h.now()}
		h.events[c.Name] = s
	}
	return s
}

// take charges one token for an authenticated request. ok is false when the bucket is empty (nothing is taken then);
// retry is then the whole seconds until a token is there.
func (s *eventState) take(now time.Time, r rules.EventRate) (ok bool, retry int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if el := now.Sub(s.last).Seconds(); el > 0 {
		s.tokens = math.Min(float64(r.Burst), s.tokens+el*float64(r.PerMinute)/60)
		s.last = now
	}
	if s.tokens >= 1 {
		s.tokens--
		return true, 0
	}
	wait := (1 - s.tokens) * 60 / float64(r.PerMinute)
	return false, max(1, int(math.Ceil(wait-1e-9)))
}

func (s *eventState) acquire(limit int) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.open >= limit {
		return false
	}
	s.open++
	return true
}

func (s *eventState) release() {
	s.mu.Lock()
	s.open--
	s.mu.Unlock()
}

// serveEvent handles an authenticated request of an event caller whose agent and user id are already decided. The
// rate token was charged when the request was authenticated: every authenticated request counts, refusals included.
func (h *handler) serveEvent(w *recorder, r *http.Request, a *auditRec, caller *rules.Caller, st *eventState, rateOK bool, retry int, ns, name, route string, uv userVal) {
	refuse := func(code int, reason, text string) {
		a.reason = reason
		deny(w, code, text)
	}
	shape := func() {
		a.rpc = "unknown"
		refuse(http.StatusForbidden, "message_shape", "forbidden")
	}
	// 1. route: the JSON-RPC route only, and never a container agent
	if route != routeRPC || r.Method != http.MethodPost {
		refuse(http.StatusForbidden, "path", "forbidden")
		return
	}
	if h.workloadTarget(ns, name, route) != nil {
		refuse(http.StatusForbidden, "agent", "forbidden")
		return
	}
	// 2. message shape
	if len(r.Header.Values("Content-Encoding")) > 0 {
		shape()
		return
	}
	if r.ContentLength > h.o.MaxBody {
		refuse(http.StatusRequestEntityTooLarge, "body_too_large", "request too large")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, h.o.MaxBody)
	head, over, err := h.sniff(w, r)
	var tooBig *http.MaxBytesError
	switch {
	case errors.As(err, &tooBig):
		refuse(http.StatusRequestEntityTooLarge, "body_too_large", "request too large")
		return
	case err != nil:
		w.Header().Set("Connection", "close")
		refuse(http.StatusRequestTimeout, "body_timeout", "request timeout")
		return
	case over:
		shape()
		return
	}
	m, ok := parseEventMessage(head, caller.Event)
	if !ok {
		shape()
		return
	}
	a.eventID, a.rpc = m.messageID, "SendMessage"
	// 3. rebuild: the body from the values parsed here, the headers from an allowlist
	out, err := buildEventBody(caller.Name, m)
	if err != nil {
		shape()
		return
	}
	call := &eventCall{id: m.id}
	if tp := r.Header.Values("Traceparent"); len(tp) == 1 && validTraceparent(tp[0]) {
		call.traceparent = tp[0]
		if ts := r.Header.Values("Tracestate"); len(ts) == 1 && validTracestate(ts[0]) {
			call.tracestate = ts[0]
		}
	}
	// 4. rate
	if !rateOK {
		w.Header().Set("Retry-After", strconv.Itoa(retry))
		refuse(http.StatusTooManyRequests, "rate", "too many requests")
		return
	}
	// 5. open calls
	if !st.acquire(caller.Event.MaxInFlight) {
		w.Header().Set("Retry-After", "1")
		refuse(http.StatusTooManyRequests, "caller_busy", "too many requests")
		return
	}
	defer st.release()

	r.Body = io.NopCloser(bytes.NewReader(out))
	r.ContentLength = int64(len(out))
	r.TransferEncoding, r.Trailer = nil, nil
	ctx := r.Context()
	ctx = context.WithValue(ctx, keyUser, uv)
	ctx = context.WithValue(ctx, keyEvent, call)
	h.proxy.ServeHTTP(w, r.WithContext(ctx))
}

type eventMessage struct {
	id        json.RawMessage
	messageID string
	text      string
}

// parseEventMessage reads one JSON-RPC SendMessage body strictly. Every key is compared exactly (a case variant is an
// unknown key), no key may repeat, only the allowed keys exist at every level, and the text must match the event
// pattern. Any deviation is a refusal.
func parseEventMessage(b []byte, ev *rules.Event) (m eventMessage, ok bool) {
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	var gotVersion, gotMethod, gotParams bool
	ok = readObject(dec, func(key string) bool {
		switch key {
		case "jsonrpc":
			v, isStr := readString(dec)
			gotVersion = isStr && v == "2.0"
			return gotVersion
		case "id":
			t, err := dec.Token()
			if err != nil {
				return false
			}
			switch v := t.(type) {
			case string:
				m.id, _ = json.Marshal(v)
			case json.Number:
				if !jsonIntRe.MatchString(v.String()) {
					return false
				}
				n, err := strconv.ParseInt(v.String(), 10, 64)
				if err != nil {
					return false
				}
				m.id = []byte(strconv.FormatInt(n, 10))
			default:
				return false
			}
			return m.id != nil
		case "method":
			v, isStr := readString(dec)
			gotMethod = isStr && v == "SendMessage"
			return gotMethod
		case "params":
			gotParams = readObject(dec, func(k string) bool {
				if k != "message" {
					return false
				}
				return readMessage(dec, &m, ev)
			})
			return gotParams
		}
		return false
	})
	if !ok || !gotVersion || !gotMethod || !gotParams || m.id == nil || m.messageID == "" {
		return eventMessage{}, false
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) { // nothing may follow the object
		return eventMessage{}, false
	}
	return m, true
}

func readMessage(dec *json.Decoder, m *eventMessage, ev *rules.Event) bool {
	var gotRole, gotParts bool
	ok := readObject(dec, func(key string) bool {
		switch key {
		case "messageId":
			v, isStr := readString(dec)
			if !isStr || !messageIDRe.MatchString(v) {
				return false
			}
			m.messageID = v
			return true
		case "role":
			v, isStr := readString(dec)
			gotRole = isStr && v == "ROLE_USER"
			return gotRole
		case "parts":
			gotParts = readParts(dec, m, ev)
			return gotParts
		}
		return false
	})
	return ok && gotRole && gotParts
}

// readParts reads an array of exactly one object with exactly one key, "text".
func readParts(dec *json.Decoder, m *eventMessage, ev *rules.Event) bool {
	if t, err := dec.Token(); err != nil || t != json.Delim('[') {
		return false
	}
	var got bool
	if !readObject(dec, func(key string) bool {
		if key != "text" {
			return false
		}
		v, isStr := readString(dec)
		if !isStr || !ev.Match(v) {
			return false
		}
		m.text, got = v, true
		return true
	}) || !got {
		return false
	}
	if dec.More() {
		return false
	}
	t, err := dec.Token()
	return err == nil && t == json.Delim(']')
}

func readString(dec *json.Decoder) (string, bool) {
	t, err := dec.Token()
	if err != nil {
		return "", false
	}
	s, ok := t.(string)
	return s, ok
}

// readObject reads one JSON object. For each key, in order, it calls field, which must read the key's value and say
// whether it was acceptable; a key that repeats is refused before field is called. field decides which keys exist.
func readObject(dec *json.Decoder, field func(key string) bool) bool {
	if t, err := dec.Token(); err != nil || t != json.Delim('{') {
		return false
	}
	seen := map[string]bool{}
	for dec.More() {
		kt, err := dec.Token()
		key, isStr := kt.(string)
		if err != nil || !isStr || seen[key] {
			return false
		}
		seen[key] = true
		if !field(key) {
			return false
		}
	}
	t, err := dec.Token()
	return err == nil && t == json.Delim('}')
}

type outMessage struct {
	MessageID string    `json:"messageId"`
	Role      string    `json:"role"`
	Parts     []outPart `json:"parts"`
}
type outPart struct {
	Text string `json:"text"`
}
type outConfig struct {
	ReturnImmediately bool `json:"returnImmediately"`
}
type outParams struct {
	Message       outMessage `json:"message"`
	Configuration outConfig  `json:"configuration"`
}
type outBody struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  outParams       `json:"params"`
}

// buildEventBody is the gate's own serialisation: the forwarded message id names the caller, the caller's id and a
// hash of the text, so two callers never share one and a repeated id with another text is a run of its own.
func buildEventBody(caller string, m eventMessage) ([]byte, error) {
	sum := sha256.Sum256([]byte(m.text))
	return json.Marshal(outBody{
		JSONRPC: "2.0", ID: m.id, Method: "SendMessage",
		Params: outParams{
			Message: outMessage{
				MessageID: caller + ":" + m.messageID + ":" + hex.EncodeToString(sum[:])[:16],
				Role:      "ROLE_USER",
				Parts:     []outPart{{Text: m.text}},
			},
			Configuration: outConfig{ReturnImmediately: true},
		},
	})
}

func validTraceparent(v string) bool {
	if !traceparentRe.MatchString(v) {
		return false
	}
	p := strings.Split(v, "-")
	return p[1] != strings.Repeat("0", 32) && p[2] != strings.Repeat("0", 16)
}

func validTracestate(v string) bool {
	if len(v) == 0 || len(v) > 512 {
		return false
	}
	members := strings.Split(v, ",")
	if len(members) > 32 {
		return false
	}
	for _, mem := range members {
		mem = strings.Trim(mem, " \t")
		k, val, ok := strings.Cut(mem, "=")
		if !ok || !tsKeyRe.MatchString(k) || !tsValueRe.MatchString(val) {
			return false
		}
	}
	return true
}

// eventRequestHeaders is the whole set of request headers the runtime gets for an event call (X-User-Id is added by
// the caller of this function's result in rewrite). The caller's own headers are not copied.
func eventRequestHeaders(c *eventCall) http.Header {
	h := http.Header{}
	h.Set("Content-Type", "application/json")
	h.Set("A2A-Version", "1.0")
	if c.traceparent != "" {
		h.Set("Traceparent", c.traceparent)
		if c.tracestate != "" {
			h.Set("Tracestate", c.tracestate)
		}
	}
	return h
}

var errEventAnswer = errors.New("event answer")

// rewriteEventResponse keeps of the runtime's answer the task id and state, or a JSON-RPC error code with the message
// "refused". No other byte of it, and none of its headers, reaches the sender. An answer it cannot read, or one over
// 1 MiB, is an error (502).
func (h *handler) rewriteEventResponse(resp *http.Response, c *eventCall) error {
	b, err := io.ReadAll(io.LimitReader(resp.Body, maxEventAnswer+1))
	_ = resp.Body.Close()
	if err != nil || len(b) > maxEventAnswer {
		return errEventAnswer
	}
	var in struct {
		Result *struct {
			Task *struct {
				ID     string `json:"id"`
				Status struct {
					State string `json:"state"`
				} `json:"status"`
			} `json:"task"`
			ID     string `json:"id"`
			Status struct {
				State string `json:"state"`
			} `json:"status"`
		} `json:"result"`
		Error *struct {
			Code *json.Number `json:"code"`
		} `json:"error"`
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	if err := dec.Decode(&in); err != nil {
		return errEventAnswer
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return errEventAnswer
	}
	var out []byte
	status := http.StatusOK
	switch {
	case in.Result != nil && in.Error == nil:
		id, state := in.Result.ID, in.Result.Status.State
		if t := in.Result.Task; t != nil {
			id, state = t.ID, t.Status.State
		}
		if resp.StatusCode < 200 || resp.StatusCode > 299 || !taskIDRe.MatchString(id) || !taskStateRe.MatchString(state) {
			return errEventAnswer
		}
		out, err = json.Marshal(struct {
			JSONRPC string          `json:"jsonrpc"`
			ID      json.RawMessage `json:"id"`
			Result  struct {
				ID     string `json:"id"`
				Status struct {
					State string `json:"state"`
				} `json:"status"`
			} `json:"result"`
		}{JSONRPC: "2.0", ID: c.id, Result: struct {
			ID     string `json:"id"`
			Status struct {
				State string `json:"state"`
			} `json:"status"`
		}{ID: id, Status: struct {
			State string `json:"state"`
		}{State: state}}})
	case in.Error != nil && in.Result == nil && in.Error.Code != nil:
		code, perr := strconv.ParseInt(in.Error.Code.String(), 10, 32)
		if perr != nil || resp.StatusCode < 200 || resp.StatusCode > 599 {
			return errEventAnswer
		}
		status = resp.StatusCode
		out, err = json.Marshal(struct {
			JSONRPC string          `json:"jsonrpc"`
			ID      json.RawMessage `json:"id"`
			Error   struct {
				Code    int64  `json:"code"`
				Message string `json:"message"`
			} `json:"error"`
		}{JSONRPC: "2.0", ID: c.id, Error: struct {
			Code    int64  `json:"code"`
			Message string `json:"message"`
		}{Code: code, Message: "refused"}})
	default:
		return errEventAnswer
	}
	if err != nil {
		return errEventAnswer
	}
	out = append(out, '\n')
	resp.Header = http.Header{
		"Content-Type":           {"application/json"},
		"X-Content-Type-Options": {"nosniff"},
		"Content-Length":         {strconv.Itoa(len(out))},
	}
	resp.StatusCode, resp.Status = status, strconv.Itoa(status)+" "+http.StatusText(status)
	resp.Body = io.NopCloser(bytes.NewReader(out))
	resp.ContentLength = int64(len(out))
	resp.TransferEncoding, resp.Trailer = nil, nil
	resp.Uncompressed = false
	return nil
}
