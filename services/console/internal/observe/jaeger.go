package observe

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// ErrBadTraceID is a trace id that is not 32 lower-case hex characters. It never reaches the store.
var ErrBadTraceID = errors.New("invalid trace id")

// errNotFound is a 404 from Jaeger; it still counts as ErrUnavailable unless a caller treats it as "no results".
var errNotFound = fmt.Errorf("%w: not found", ErrUnavailable)

var traceIDRE = regexp.MustCompile(`^[0-9a-f]{32}$`)

const (
	lookback    = 6 * time.Hour // how far back the list looks
	maxServices = 20
	perService  = 15
	maxTurns    = 30
	maxSpans    = 400
)

// attrAllow is the whole list of span attributes the console passes on. Prompts, answers, tool arguments and results,
// headers and everything else are dropped here, whatever the trace holds (content capture is off by default and must
// stay invisible). The names are the ones hack/trace-turn.sh reads.
var attrAllow = map[string]bool{
	"gen_ai.conversation.id": true, "gen_ai.agent.name": true, "gen_ai.operation.name": true, "gen_ai.request.model": true,
	"gen_ai.response.model": true, "gen_ai.usage.input_tokens": true, "gen_ai.usage.output_tokens": true, "gen_ai.tool.name": true,
	"a2a.task.state": true, "error.type": true, "http.response.status_code": true, "rpc.method": true, "mcp.method.name": true,
}

// Turn is one agent turn: a trace that holds an a2a.request span.
type Turn struct {
	TraceID        string `json:"traceId"`
	ConversationID string `json:"conversationId,omitempty"`
	Start          string `json:"start"`
	Agent          string `json:"agent"`
	Outcome        string `json:"outcome"`
	ModelCalls     int    `json:"modelCalls"`
	DurationMs     int64  `json:"durationMs"`
	TokensIn       int64  `json:"tokensIn"`
	TokensOut      int64  `json:"tokensOut"`
}

// Span is one span of the waterfall, with only allowed attributes.
type Span struct {
	ID         string            `json:"id"`
	ParentID   string            `json:"parentId,omitempty"`
	Service    string            `json:"service"`
	Name       string            `json:"name"`
	OffsetMs   int64             `json:"offsetMs"`
	DurationMs int64             `json:"durationMs"`
	Error      bool              `json:"error"`
	Attrs      map[string]string `json:"attrs"`
}

// TraceDetail is GET /api/v1/traces/{traceId}.
type TraceDetail struct {
	TraceID    string `json:"traceId"`
	DurationMs int64  `json:"durationMs"`
	Spans      []Span `json:"spans"`
}

// Jaeger reads the bundled Jaeger query API (v1-style /api/traces and /api/v3/services, as hack/trace-turn.sh does).
type Jaeger struct {
	BaseURL string
	HTTP    *http.Client
	Timeout time.Duration
	Now     func() time.Time
}

func NewJaeger(base string, c *http.Client) *Jaeger {
	if c == nil {
		c = &http.Client{}
	}
	return &Jaeger{BaseURL: strings.TrimRight(base, "/"), HTTP: c, Timeout: 8 * time.Second}
}

type jTag struct {
	Key   string `json:"key"`
	Value any    `json:"value"`
}
type jSpan struct {
	SpanID        string `json:"spanID"`
	ProcessID     string `json:"processID"`
	OperationName string `json:"operationName"`
	StartTime     int64  `json:"startTime"`
	Duration      int64  `json:"duration"`
	Tags          []jTag `json:"tags"`
	References    []struct {
		RefType string `json:"refType"`
		SpanID  string `json:"spanID"`
	} `json:"references"`
}
type jTrace struct {
	TraceID   string  `json:"traceID"`
	Spans     []jSpan `json:"spans"`
	Processes map[string]struct {
		ServiceName string `json:"serviceName"`
	} `json:"processes"`
}

func (j *Jaeger) get(ctx context.Context, path string, q url.Values, out any) error {
	ctx, cancel := context.WithTimeout(ctx, j.Timeout)
	defer cancel()
	u := j.BaseURL + path
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return ErrUnavailable
	}
	resp, err := j.HTTP.Do(req)
	if err != nil {
		return ErrUnavailable
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return errNotFound
	}
	if resp.StatusCode != http.StatusOK {
		return ErrUnavailable
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(out); err != nil {
		return ErrUnavailable
	}
	return nil
}

func tagStr(tags []jTag, k string) string {
	for _, t := range tags {
		if t.Key == k {
			switch v := t.Value.(type) {
			case string:
				return v
			case float64:
				return strconv.FormatFloat(v, 'f', -1, 64)
			case bool:
				return strconv.FormatBool(v)
			}
		}
	}
	return ""
}

func tagInt(tags []jTag, k string) int64 {
	n, _ := strconv.ParseInt(tagStr(tags, k), 10, 64)
	return n
}

func (j *Jaeger) now() time.Time {
	if j.Now != nil {
		return j.Now()
	}
	return time.Now()
}

func summarize(t jTrace) (Turn, bool) {
	svc := func(s jSpan) string { return t.Processes[s.ProcessID].ServiceName }
	var req *jSpan
	var first int64
	turn := Turn{TraceID: t.TraceID}
	for i := range t.Spans {
		s := &t.Spans[i]
		if s.OperationName == "a2a.request" && req == nil {
			req = s
		}
		if first == 0 || s.StartTime < first {
			first = s.StartTime
		}
		if svc(*s) == "model-gateway" && s.OperationName == "POST /v1/chat/completions" {
			turn.ModelCalls++
			turn.TokensIn += tagInt(s.Tags, "gen_ai.usage.input_tokens")
			turn.TokensOut += tagInt(s.Tags, "gen_ai.usage.output_tokens")
		}
	}
	if req == nil {
		return Turn{}, false
	}
	turn.Agent = tagStr(req.Tags, "gen_ai.agent.name")
	if turn.Agent == "" {
		turn.Agent = svc(*req)
	}
	turn.ConversationID = tagStr(req.Tags, "gen_ai.conversation.id")
	turn.Outcome = tagStr(req.Tags, "a2a.task.state")
	if turn.Outcome == "" {
		turn.Outcome = "unknown"
	}
	if tagStr(req.Tags, "error.type") != "" {
		turn.Outcome = "error"
	}
	turn.DurationMs = req.Duration / 1000
	turn.Start = time.UnixMicro(req.StartTime).UTC().Format(time.RFC3339)
	return turn, true
}

type otlpValue struct {
	Str    *string  `json:"stringValue"`
	Int    *string  `json:"intValue"`
	Double *float64 `json:"doubleValue"`
	Bool   *bool    `json:"boolValue"`
}
type otlpAttr struct {
	Key   string    `json:"key"`
	Value otlpValue `json:"value"`
}
type otlpResult struct {
	Result struct {
		ResourceSpans []struct {
			Resource struct {
				Attributes []otlpAttr `json:"attributes"`
			} `json:"resource"`
			ScopeSpans []struct {
				Spans []struct {
					TraceID      string     `json:"traceId"`
					SpanID       string     `json:"spanId"`
					ParentSpanID string     `json:"parentSpanId"`
					Name         string     `json:"name"`
					Start        string     `json:"startTimeUnixNano"`
					End          string     `json:"endTimeUnixNano"`
					Attributes   []otlpAttr `json:"attributes"`
				} `json:"spans"`
			} `json:"scopeSpans"`
		} `json:"resourceSpans"`
	} `json:"result"`
}

func otlpTag(a otlpAttr) jTag {
	switch {
	case a.Value.Str != nil:
		return jTag{Key: a.Key, Value: *a.Value.Str}
	case a.Value.Int != nil:
		if n, err := strconv.ParseFloat(*a.Value.Int, 64); err == nil {
			return jTag{Key: a.Key, Value: n}
		}
	case a.Value.Double != nil:
		return jTag{Key: a.Key, Value: *a.Value.Double}
	case a.Value.Bool != nil:
		return jTag{Key: a.Key, Value: *a.Value.Bool}
	}
	return jTag{Key: a.Key}
}

// searchTraces runs a /api/v3/traces search and converts the OTLP answer into the flat trace shape the rest of this file reads. Jaeger answers 404
// ("No traces found") for a search that matches nothing: that is an empty list, not an outage.
func (j *Jaeger) searchTraces(ctx context.Context, q url.Values) ([]jTrace, error) {
	var res otlpResult
	if err := j.get(ctx, "/api/v3/traces", q, &res); err != nil {
		if errors.Is(err, errNotFound) {
			return nil, nil
		}
		return nil, err
	}
	byID := map[string]*jTrace{}
	var order []string
	for _, rs := range res.Result.ResourceSpans {
		svc := ""
		for _, a := range rs.Resource.Attributes {
			if a.Key == "service.name" && a.Value.Str != nil {
				svc = *a.Value.Str
			}
		}
		for _, ss := range rs.ScopeSpans {
			for _, sp := range ss.Spans {
				t := byID[sp.TraceID]
				if t == nil {
					t = &jTrace{TraceID: sp.TraceID, Processes: map[string]struct {
						ServiceName string `json:"serviceName"`
					}{}}
					byID[sp.TraceID] = t
					order = append(order, sp.TraceID)
				}
				t.Processes[svc] = struct {
					ServiceName string `json:"serviceName"`
				}{svc}
				st, _ := strconv.ParseInt(sp.Start, 10, 64)
				en, _ := strconv.ParseInt(sp.End, 10, 64)
				js := jSpan{SpanID: sp.SpanID, ProcessID: svc, OperationName: sp.Name, StartTime: st / 1000, Duration: (en - st) / 1000}
				for _, a := range sp.Attributes {
					js.Tags = append(js.Tags, otlpTag(a))
				}
				if sp.ParentSpanID != "" {
					js.References = append(js.References, struct {
						RefType string `json:"refType"`
						SpanID  string `json:"spanID"`
					}{"CHILD_OF", sp.ParentSpanID})
				}
				t.Spans = append(t.Spans, js)
			}
		}
	}
	out := make([]jTrace, 0, len(order))
	for _, id := range order {
		out = append(out, *byID[id])
	}
	return out, nil
}

// Turns lists the most recent turns. The queries are fixed: the services Jaeger knows (at most 20), each asked for its
// a2a.request operation over a bounded look-back. Nothing comes from the browser.
func (j *Jaeger) Turns(ctx context.Context) ([]Turn, error) {
	var svcs struct {
		Services []string `json:"services"`
	}
	if err := j.get(ctx, "/api/v3/services", nil, &svcs); err != nil {
		return nil, err
	}
	end := j.now()
	out := []Turn{}
	seen := map[string]bool{}
	for i, s := range svcs.Services {
		if i >= maxServices {
			break
		}
		// Jaeger v2 has no /api/traces search: the search is /api/v3/traces (OTLP JSON), and it answers 404 when nothing matches.
		q := url.Values{"query.service_name": {s}, "query.operation_name": {"a2a.request"}, "query.num_traces": {strconv.Itoa(perService)},
			"query.start_time_min": {end.Add(-lookback).UTC().Format(time.RFC3339)}, "query.start_time_max": {end.Add(time.Hour).UTC().Format(time.RFC3339)}}
		traces, err := j.searchTraces(ctx, q)
		if err != nil {
			return nil, err
		}
		for _, t := range traces {
			if seen[t.TraceID] || !traceIDRE.MatchString(t.TraceID) {
				continue
			}
			if turn, ok := summarize(t); ok {
				seen[t.TraceID] = true
				out = append(out, turn)
			}
		}
	}
	sort.Slice(out, func(a, b int) bool { return out[a].Start > out[b].Start })
	if len(out) > maxTurns {
		out = out[:maxTurns]
	}
	return out, nil
}

// Trace returns the spans of one turn. The id must be 32 lower-case hex characters; only allowed attributes are kept.
func (j *Jaeger) Trace(ctx context.Context, id string) (TraceDetail, error) {
	if !traceIDRE.MatchString(id) {
		return TraceDetail{}, ErrBadTraceID
	}
	var res struct {
		Data []jTrace `json:"data"`
	}
	if err := j.get(ctx, "/api/traces/"+id, nil, &res); err != nil {
		return TraceDetail{}, err
	}
	if len(res.Data) == 0 || len(res.Data[0].Spans) == 0 {
		return TraceDetail{}, fmt.Errorf("%w: no such trace", ErrUnavailable)
	}
	t := res.Data[0]
	var first, last int64
	for i, s := range t.Spans {
		if i == 0 || s.StartTime < first {
			first = s.StartTime
		}
		if e := s.StartTime + s.Duration; e > last {
			last = e
		}
	}
	d := TraceDetail{TraceID: id, DurationMs: (last - first) / 1000, Spans: []Span{}}
	for i, s := range t.Spans {
		if i >= maxSpans {
			break
		}
		sp := Span{ID: s.SpanID, Service: t.Processes[s.ProcessID].ServiceName, Name: s.OperationName,
			OffsetMs: (s.StartTime - first) / 1000, DurationMs: s.Duration / 1000, Attrs: map[string]string{}}
		for _, r := range s.References {
			if r.RefType == "CHILD_OF" {
				sp.ParentID = r.SpanID
			}
		}
		for _, tg := range s.Tags {
			if attrAllow[tg.Key] {
				sp.Attrs[tg.Key] = tagStr([]jTag{tg}, tg.Key)
			}
		}
		sp.Error = sp.Attrs["error.type"] != ""
		d.Spans = append(d.Spans, sp)
	}
	sort.Slice(d.Spans, func(a, b int) bool { return d.Spans[a].OffsetMs < d.Spans[b].OffsetMs })
	return d, nil
}
