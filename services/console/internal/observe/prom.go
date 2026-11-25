package observe

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	maxBody    = 1 << 20 // bytes read from the store per answer
	maxSeries  = 100     // series kept from one instant query
	maxUsers   = 20      // gateway users returned
	seriesPts  = 24
	costMetric = "agentgateway_gen_ai_client_cost_usd_total"
	tokMetric  = "agentgateway_gen_ai_client_token_usage_sum"
	reqMetric  = "agentgateway_requests_total"
)

// Prom reads a Prometheus-compatible query API (VictoriaMetrics, Prometheus). Its queries are the proven ones of
// README "Observability" and hack/dashboard, written here as fixed text; only the window name (from a fixed list) and the
// number of seconds since midnight UTC are filled in.
type Prom struct {
	BaseURL string
	HTTP    *http.Client
	Timeout time.Duration    // for the whole summary
	Now     func() time.Time // the clock; nil: time.Now
}

// NewProm builds the client. A nil client gets a plain one; the Timeout bounds every call.
func NewProm(base string, c *http.Client) *Prom {
	if c == nil {
		c = &http.Client{}
	}
	return &Prom{BaseURL: strings.TrimRight(base, "/"), HTTP: c, Timeout: 8 * time.Second}
}

type promResp struct {
	Status string `json:"status"`
	Data   struct {
		Result []struct {
			Metric map[string]string `json:"metric"`
			Value  []any             `json:"value"`
			Values [][]any           `json:"values"`
		} `json:"result"`
	} `json:"data"`
}

func (p *Prom) call(ctx context.Context, path string, form url.Values) (*promResp, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.BaseURL+path, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, ErrUnavailable
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	resp, err := p.HTTP.Do(req)
	if err != nil {
		return nil, ErrUnavailable
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, ErrUnavailable
	}
	var out promResp
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxBody)).Decode(&out); err != nil || out.Status != "success" {
		return nil, ErrUnavailable
	}
	return &out, nil
}

func (p *Prom) instant(ctx context.Context, q string) (*promResp, error) {
	return p.call(ctx, "/api/v1/query", url.Values{"query": {q}})
}

func num(v []any) (float64, bool) {
	if len(v) != 2 {
		return 0, false
	}
	s, ok := v[1].(string)
	if !ok {
		return 0, false
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil || f != f || f > 1e15 || f < -1e15 {
		return 0, false
	}
	return f, true
}

// scalar is the value of a query that sums everything into one series; no series is zero.
func scalar(r *promResp) float64 {
	if len(r.Data.Result) == 0 {
		return 0
	}
	f, _ := num(r.Data.Result[0].Value)
	return f
}

// Metrics runs the fixed set of queries for the window.
func (p *Prom) Metrics(ctx context.Context, w Window) (MetricsSummary, error) {
	if w != Window24h && w != Window7d {
		return MetricsSummary{}, ErrUnavailable
	}
	ctx, cancel := context.WithTimeout(ctx, p.Timeout)
	defer cancel()
	now := time.Now
	if p.Now != nil {
		now = p.Now
	}
	t := now().UTC()
	sinceMidnight := int(t.Sub(time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.UTC)).Seconds())
	if sinceMidnight < 60 {
		sinceMidnight = 60
	}
	win := string(w)
	span, step := 24*time.Hour, "1h"
	if w == Window7d {
		span, step = 7*24*time.Hour, "7h"
	}

	out := MetricsSummary{Window: win, ByUser: []UserUse{}, Series: []float64{}, GeneratedAt: t.Format(time.RFC3339)}
	byUser := map[string]*UserUse{}
	use := func(u string) *UserUse {
		if byUser[u] == nil {
			byUser[u] = &UserUse{User: u}
		}
		return byUser[u]
	}

	cost, err := p.instant(ctx, fmt.Sprintf("sum by (user_id)(increase(%s[%s]))", costMetric, win))
	if err != nil {
		return MetricsSummary{}, err
	}
	for i, s := range cost.Data.Result {
		if i >= maxSeries {
			break
		}
		if f, ok := num(s.Value); ok && s.Metric["user_id"] != "" {
			use(s.Metric["user_id"]).CostUSD = f
			out.SpendUSD += f
		}
	}
	today, err := p.instant(ctx, fmt.Sprintf("sum(increase(%s[%ds]))", costMetric, sinceMidnight))
	if err != nil {
		return MetricsSummary{}, err
	}
	out.SpendToday = scalar(today)

	tok, err := p.instant(ctx, fmt.Sprintf("sum by (user_id, gen_ai_token_type)(increase(%s[%s]))", tokMetric, win))
	if err != nil {
		return MetricsSummary{}, err
	}
	var cacheRead float64
	for i, s := range tok.Data.Result {
		if i >= maxSeries {
			break
		}
		f, ok := num(s.Value)
		if !ok {
			continue
		}
		typ := s.Metric["gen_ai_token_type"]
		u := s.Metric["user_id"]
		switch {
		case typ == "input":
			out.TokensIn += f
			if u != "" {
				use(u).TokensIn += f
			}
		case typ == "output":
			out.TokensOut += f
			if u != "" {
				use(u).TokensOut += f
			}
		case strings.Contains(typ, "cache") && strings.Contains(typ, "read"):
			cacheRead += f
			if u != "" {
				use(u).TokensCacheRead += f
			}
		}
	}
	if cacheRead > 0 && out.TokensIn+cacheRead > 0 {
		share := cacheRead / (out.TokensIn + cacheRead)
		out.CacheReadShare = &share
	}

	req, err := p.instant(ctx, fmt.Sprintf("sum(increase(%s[%s]))", reqMetric, win))
	if err != nil {
		return MetricsSummary{}, err
	}
	out.Requests = scalar(req)

	end := t
	rng, err := p.call(ctx, "/api/v1/query_range", url.Values{
		"query": {fmt.Sprintf("sum(increase(%s[%s]))", costMetric, step)},
		"start": {strconv.FormatInt(end.Add(-span).Unix(), 10)},
		"end":   {strconv.FormatInt(end.Unix(), 10)},
		"step":  {strconv.FormatInt(int64(span/seriesPts/time.Second), 10)},
	})
	if err != nil {
		return MetricsSummary{}, err
	}
	if len(rng.Data.Result) > 0 {
		for _, v := range rng.Data.Result[0].Values {
			if f, ok := num(v); ok && len(out.Series) < 2*seriesPts {
				out.Series = append(out.Series, f)
			}
		}
		if len(out.Series) > seriesPts {
			out.Series = out.Series[len(out.Series)-seriesPts:]
		}
	}

	for _, u := range byUser {
		out.ByUser = append(out.ByUser, *u)
	}
	sort.Slice(out.ByUser, func(i, j int) bool {
		if out.ByUser[i].CostUSD != out.ByUser[j].CostUSD {
			return out.ByUser[i].CostUSD > out.ByUser[j].CostUSD
		}
		return out.ByUser[i].User < out.ByUser[j].User
	})
	if len(out.ByUser) > maxUsers {
		out.ByUser = out.ByUser[:maxUsers]
	}
	return out, nil
}
