package observe_test

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/openagentix/openagentix/services/console/internal/observe"
)

type fakeProm struct {
	mu      sync.Mutex
	queries []string
	paths   []string
	status  int
	body    func(q string) any
}

func (f *fakeProm) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	f.mu.Lock()
	f.queries = append(f.queries, r.Form.Get("query"))
	f.paths = append(f.paths, r.URL.Path)
	f.mu.Unlock()
	if f.status != 0 {
		w.WriteHeader(f.status)
		_, _ = w.Write([]byte("SECRET upstream text"))
		return
	}
	_ = json.NewEncoder(w).Encode(f.body(r.Form.Get("query")))
}

func vec(rows ...map[string]any) any {
	res := []any{}
	for _, r := range rows {
		res = append(res, map[string]any{"metric": r["m"], "value": []any{1.0, r["v"]}})
	}
	return map[string]any{"status": "success", "data": map[string]any{"resultType": "vector", "result": res}}
}

func standard(q string) any {
	switch {
	case strings.Contains(q, "client_cost_usd_total") && strings.Contains(q, "by (user_id)"):
		return vec(map[string]any{"m": map[string]string{"user_id": "assistant"}, "v": "0.30"}, map[string]any{"m": map[string]string{"user_id": "kb"}, "v": "0.05"})
	case strings.Contains(q, "client_cost_usd_total") && strings.HasPrefix(q, "sum(increase") && !strings.Contains(q, "[1h]"):
		return vec(map[string]any{"m": map[string]string{}, "v": "0.12"})
	case strings.Contains(q, "token_usage_sum"):
		return vec(
			map[string]any{"m": map[string]string{"user_id": "assistant", "gen_ai_token_type": "input"}, "v": "1000"},
			map[string]any{"m": map[string]string{"user_id": "assistant", "gen_ai_token_type": "output"}, "v": "100"},
			map[string]any{"m": map[string]string{"user_id": "assistant", "gen_ai_token_type": "cache_read"}, "v": "250"},
		)
	case strings.Contains(q, "agentgateway_requests_total"):
		return vec(map[string]any{"m": map[string]string{}, "v": "63"})
	default: // the hourly series, a range query
		vals := []any{}
		for i := 0; i < 24; i++ {
			vals = append(vals, []any{float64(i), "0.01"})
		}
		return map[string]any{"status": "success", "data": map[string]any{"resultType": "matrix", "result": []any{map[string]any{"metric": map[string]string{}, "values": vals}}}}
	}
}

func TestMetricsRunsOnlyFixedQueries(t *testing.T) {
	f := &fakeProm{body: standard}
	srv := httptest.NewServer(f)
	defer srv.Close()
	p := observe.NewProm(srv.URL, nil)
	p.Now = func() time.Time { return time.Date(2026, 11, 25, 6, 0, 0, 0, time.UTC) }
	m, err := p.Metrics(context.Background(), observe.Window24h)
	if err != nil {
		t.Fatal(err)
	}
	if m.SpendUSD < 0.349 || m.SpendUSD > 0.351 || m.SpendToday != 0.12 || m.Requests != 63 || len(m.ByUser) != 2 || m.ByUser[0].User != "assistant" {
		t.Fatalf("summary: %+v", m)
	}
	if m.TokensIn != 1000 || m.TokensOut != 100 || m.CacheReadShare == nil || *m.CacheReadShare != 0.2 {
		t.Fatalf("tokens: %+v", m)
	}
	if len(m.Series) != 24 {
		t.Fatalf("series has %d points", len(m.Series))
	}
	// "today" is the six hours since UTC midnight, computed here, never taken from the browser
	var sawToday bool
	for _, q := range f.queries {
		if strings.Contains(q, "[21600s]") {
			sawToday = true
		}
		if !strings.HasPrefix(q, "sum") {
			t.Errorf("unexpected query %q", q)
		}
	}
	if !sawToday {
		t.Errorf("no query for today: %v", f.queries)
	}
}

func TestUpstreamTextIsNeverReturned(t *testing.T) {
	f := &fakeProm{status: 500}
	srv := httptest.NewServer(f)
	defer srv.Close()
	_, err := observe.NewProm(srv.URL, nil).Metrics(context.Background(), observe.Window24h)
	if !errors.Is(err, observe.ErrUnavailable) || strings.Contains(err.Error(), "SECRET") {
		t.Fatalf("err = %v", err)
	}
}

func TestGarbageAndUnreachableAreUnavailable(t *testing.T) {
	g := &fakeProm{body: func(string) any { return map[string]any{"status": "error", "error": "SECRET"} }}
	srv := httptest.NewServer(g)
	_, err := observe.NewProm(srv.URL, nil).Metrics(context.Background(), observe.Window7d)
	srv.Close()
	if !errors.Is(err, observe.ErrUnavailable) || strings.Contains(err.Error(), "SECRET") {
		t.Fatalf("err = %v", err)
	}
	_, err = observe.NewProm("http://127.0.0.1:1", nil).Metrics(context.Background(), observe.Window24h)
	if !errors.Is(err, observe.ErrUnavailable) {
		t.Fatalf("unreachable: %v", err)
	}
}

func TestSlowStoreTimesOut(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-time.After(3 * time.Second):
		}
	}))
	defer srv.Close()
	p := observe.NewProm(srv.URL, nil)
	p.Timeout = 100 * time.Millisecond
	start := time.Now()
	_, err := p.Metrics(context.Background(), observe.Window24h)
	if !errors.Is(err, observe.ErrUnavailable) || time.Since(start) > 2*time.Second {
		t.Fatalf("err=%v after %v", err, time.Since(start))
	}
}

func TestResultsAreCapped(t *testing.T) {
	f := &fakeProm{body: func(q string) any {
		if strings.Contains(q, "by (user_id)") && strings.Contains(q, "cost") {
			rows := []map[string]any{}
			for i := 0; i < 500; i++ {
				rows = append(rows, map[string]any{"m": map[string]string{"user_id": "u" + string(rune('a'+i%26)) + string(rune('a'+i/26%26))}, "v": "1"})
			}
			return vec(rows...)
		}
		return standard(q)
	}}
	srv := httptest.NewServer(f)
	defer srv.Close()
	m, err := observe.NewProm(srv.URL, nil).Metrics(context.Background(), observe.Window24h)
	if err != nil || len(m.ByUser) > 20 {
		t.Fatalf("err=%v users=%d", err, len(m.ByUser))
	}
}

func TestParseWindow(t *testing.T) {
	for in, ok := range map[string]bool{"": true, "24h": true, "7d": true, "30d": false, "1h]) or vector(1": false} {
		if _, got := observe.ParseWindow(in); got != ok {
			t.Errorf("%q: %v", in, got)
		}
	}
}
