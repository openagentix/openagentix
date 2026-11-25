package fake

import (
	"context"
	"time"

	"github.com/openagentix/openagentix/services/console/internal/observe"
)

// Observe is the demo mode's metrics: fixed, plainly invented numbers (the whole demo mode says "Demo data"). It exists so
// the console's metrics views can be seen and tested without a metrics store.
type Observe struct{}

func (Observe) Metrics(_ context.Context, w observe.Window) (observe.MetricsSummary, error) {
	k := 1.0
	if w == observe.Window7d {
		k = 6.4
	}
	share := 0.31
	series := make([]float64, 24)
	for i := range series {
		series[i] = k * (0.004 + 0.006*float64((i*7)%11)/10)
	}
	return observe.MetricsSummary{
		Window: string(w), SpendUSD: 0.191 * k, SpendToday: 0.074, TokensIn: 2.04e6 * k, TokensOut: 15100 * k, Requests: 151 * k,
		CacheReadShare: &share,
		ByUser: []observe.UserUse{
			{User: "assistant", CostUSD: 0.118 * k, TokensIn: 1.2e6 * k, TokensOut: 9000 * k, TokensCacheRead: 4e5 * k},
			{User: "researcher", CostUSD: 0.049 * k, TokensIn: 5e5 * k, TokensOut: 4000 * k, TokensCacheRead: 1e5 * k},
			{User: "kb-extract", CostUSD: 0.024 * k, TokensIn: 3.4e5 * k, TokensOut: 2100 * k},
		},
		Series: series, GeneratedAt: time.Now().UTC().Format(time.RFC3339),
	}, nil
}
