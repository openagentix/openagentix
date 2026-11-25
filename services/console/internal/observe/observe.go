// Package observe is the console's one door to observability data: metrics (and, later, traces). Everything the browser
// can ask for is a fixed question with a bounded answer; no query string, label or time range from the browser reaches the
// store. A backend is anything that implements Observability (ADR 0009); the first one reads a Prometheus-compatible
// query API (the bundled VictoriaMetrics).
package observe

import (
	"context"
	"errors"
)

// ErrUnavailable means the store is not configured, did not answer or answered nonsense. The console maps it to one plain
// sentence and never repeats what the store said.
var ErrUnavailable = errors.New("metrics unavailable")

// Window is the only time range a caller may choose, from a fixed list.
type Window string

const (
	Window24h Window = "24h"
	Window7d  Window = "7d"
)

// ParseWindow accepts only the fixed names; an empty string is 24h.
func ParseWindow(s string) (Window, bool) {
	switch s {
	case "", "24h":
		return Window24h, true
	case "7d":
		return Window7d, true
	}
	return "", false
}

// UserUse is what one gateway user (an agent's virtual key) cost and used in the window.
type UserUse struct {
	User            string  `json:"user"`
	CostUSD         float64 `json:"costUsd"`
	TokensIn        float64 `json:"tokensIn"`
	TokensOut       float64 `json:"tokensOut"`
	TokensCacheRead float64 `json:"tokensCacheRead"`
}

// MetricsSummary is GET /api/v1/metrics/summary.
type MetricsSummary struct {
	Window     string  `json:"window"`
	SpendUSD   float64 `json:"spendUsd"`
	SpendToday float64 `json:"spendTodayUsd"`
	TokensIn   float64 `json:"tokensIn"`
	TokensOut  float64 `json:"tokensOut"`
	// Requests is the number of model requests the gateway counted in the window ("turns" are model calls here).
	Requests float64 `json:"requests"`
	// CacheReadShare is cache-read tokens over all input tokens; absent when the gateway reports no cache-read type.
	CacheReadShare *float64  `json:"cacheReadShare,omitempty"`
	ByUser         []UserUse `json:"byUser"`
	// Series is the spend per step over the window, 24 points, oldest first.
	Series      []float64 `json:"series"`
	GeneratedAt string    `json:"generatedAt"`
}

// Observability is what the console needs from a metrics backend.
type Observability interface {
	Metrics(ctx context.Context, w Window) (MetricsSummary, error)
}
