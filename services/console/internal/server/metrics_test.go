package server_test

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/openagentix/openagentix/services/console/internal/observe"
	"github.com/openagentix/openagentix/services/console/internal/server"
)

func withObs(o observe.Observability) func(*rigOpt) {
	return func(r *rigOpt) { r.mod = func(s *server.Options) { s.Observe = o } }
}

type fakeObs struct {
	err  error
	last observe.Window
	noTr bool
}

func (f *fakeObs) Has() observe.Caps { return observe.Caps{Metrics: true, Traces: !f.noTr} }
func (f *fakeObs) Turns(context.Context) ([]observe.Turn, error) {
	if f.err != nil {
		return nil, f.err
	}
	return []observe.Turn{{TraceID: strings.Repeat("a", 32), Agent: "assistant", Outcome: "completed"}}, nil
}
func (f *fakeObs) Trace(_ context.Context, id string) (observe.TraceDetail, error) {
	if f.err != nil {
		return observe.TraceDetail{}, f.err
	}
	if len(id) != 32 {
		return observe.TraceDetail{}, observe.ErrBadTraceID
	}
	return observe.TraceDetail{TraceID: id, Spans: []observe.Span{{ID: "a", Name: "a2a.request"}}}, nil
}

func (f *fakeObs) Metrics(_ context.Context, w observe.Window) (observe.MetricsSummary, error) {
	f.last = w
	if f.err != nil {
		return observe.MetricsSummary{}, f.err
	}
	return observe.MetricsSummary{Window: string(w), SpendUSD: 0.35, ByUser: []observe.UserUse{{User: "assistant", CostUSD: 0.3}}, Series: []float64{0.01}}, nil
}

func TestMetricsSummaryRoute(t *testing.T) {
	obs := &fakeObs{}
	r := newRig(t, withObs(obs))
	resp, b := r.do(t, "GET", "/api/v1/metrics/summary?window=7d", nil)
	if resp.StatusCode != 200 || !strings.Contains(string(b), `"spendUsd":0.35`) || obs.last != observe.Window7d {
		t.Fatalf("%d %s (window %q)", resp.StatusCode, b, obs.last)
	}
	// only the fixed window names are accepted: nothing from the browser reaches a query
	for _, bad := range []string{"30d", "1h])%20or%20vector(1", "24h%26query=up"} {
		resp, b = r.do(t, "GET", "/api/v1/metrics/summary?window="+bad, nil)
		if resp.StatusCode != 400 {
			t.Errorf("window %q: %d %s", bad, resp.StatusCode, b)
		}
	}
	resp, _ = r.do(t, "GET", "/api/v1/metrics/summary?query=up", nil)
	if resp.StatusCode != 200 || obs.last != observe.Window24h {
		t.Errorf("an unknown parameter must be ignored, window %q", obs.last)
	}
}

func TestMetricsUnavailableIsOneSentence(t *testing.T) {
	r := newRig(t, withObs(&fakeObs{err: observe.ErrUnavailable}))
	resp, b := r.do(t, "GET", "/api/v1/metrics/summary", nil)
	var e struct {
		Error struct{ Code, Message string }
	}
	_ = json.Unmarshal(b, &e)
	if resp.StatusCode != 503 || e.Error.Code != "metrics_unavailable" || !strings.Contains(e.Error.Message, "Metrics are not available") {
		t.Fatalf("%d %s", resp.StatusCode, b)
	}
	r = newRig(t, withObs(&fakeObs{err: errors.New("dial tcp 10.0.0.1: SECRET")}))
	_, b = r.do(t, "GET", "/api/v1/metrics/summary", nil)
	if strings.Contains(string(b), "SECRET") || strings.Contains(string(b), "10.0.0.1") {
		t.Fatalf("store text leaked: %s", b)
	}
}

func TestMetricsNotConfiguredAndPlatformSaysSo(t *testing.T) {
	r := newRig(t)
	resp, b := r.do(t, "GET", "/api/v1/metrics/summary", nil)
	if resp.StatusCode != 503 {
		t.Fatalf("%d %s", resp.StatusCode, b)
	}
	_, b = r.do(t, "GET", "/api/v1/platform", nil)
	if !strings.Contains(string(b), `"metrics":{"available":false}`) {
		t.Fatalf("platform: %s", b)
	}
	r = newRig(t, withObs(&fakeObs{}))
	_, b = r.do(t, "GET", "/api/v1/platform", nil)
	if !strings.Contains(string(b), `"metrics":{"available":true}`) {
		t.Fatalf("platform: %s", b)
	}
	if resp, _ = r.do(t, "GET", "/api/v1/metrics/summary", nil, "Authorization", ""); resp.StatusCode != 401 {
		t.Errorf("no token: %d", resp.StatusCode)
	}
}

func TestTracesRoutes(t *testing.T) {
	r := newRig(t, withObs(&fakeObs{}))
	resp, b := r.do(t, "GET", "/api/v1/traces", nil)
	if resp.StatusCode != 200 || !strings.Contains(string(b), `"agent":"assistant"`) {
		t.Fatalf("%d %s", resp.StatusCode, b)
	}
	resp, b = r.do(t, "GET", "/api/v1/traces/"+strings.Repeat("b", 32), nil)
	if resp.StatusCode != 200 || !strings.Contains(string(b), "a2a.request") {
		t.Fatalf("%d %s", resp.StatusCode, b)
	}
	if resp, _ = r.do(t, "GET", "/api/v1/traces/not-hex", nil); resp.StatusCode != 400 {
		t.Errorf("bad id: %d", resp.StatusCode)
	}
	_, b = r.do(t, "GET", "/api/v1/platform", nil)
	if !strings.Contains(string(b), `"traces":{"available":true}`) {
		t.Fatalf("platform: %s", b)
	}
}

func TestTracesUnavailableAndNotConfigured(t *testing.T) {
	r := newRig(t, withObs(&fakeObs{err: errors.New("dial tcp 10.0.0.9: SECRET")}))
	resp, b := r.do(t, "GET", "/api/v1/traces", nil)
	if resp.StatusCode != 503 || strings.Contains(string(b), "SECRET") || !strings.Contains(string(b), "traces_unavailable") {
		t.Fatalf("%d %s", resp.StatusCode, b)
	}
	r = newRig(t)
	if resp, _ = r.do(t, "GET", "/api/v1/traces", nil); resp.StatusCode != 503 {
		t.Fatalf("not configured: %d", resp.StatusCode)
	}
	r = newRig(t, withObs(&fakeObs{noTr: true}))
	if resp, _ = r.do(t, "GET", "/api/v1/traces/"+strings.Repeat("b", 32), nil); resp.StatusCode != 503 {
		t.Fatalf("metrics only: %d", resp.StatusCode)
	}
}
