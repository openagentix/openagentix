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
