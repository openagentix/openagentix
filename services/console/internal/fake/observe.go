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

func (Observe) Has() observe.Caps { return observe.Caps{Metrics: true, Traces: true} }

const demoTrace = "0af7651916cd43dd8448eb211c80319c"

func (Observe) Turns(context.Context) ([]observe.Turn, error) {
	now := time.Now().UTC()
	return []observe.Turn{
		{TraceID: demoTrace, ConversationID: "demo-ctx-1", Start: now.Add(-12 * time.Minute).Format(time.RFC3339), Agent: "researcher", Outcome: "completed", ModelCalls: 2, DurationMs: 3200, TokensIn: 30782, TokensOut: 263},
		{TraceID: "1bf7651916cd43dd8448eb211c80319d", Start: now.Add(-3 * time.Hour).Format(time.RFC3339), Agent: "assistant", Outcome: "failed", ModelCalls: 1, DurationMs: 900, TokensIn: 4100, TokensOut: 0},
	}, nil
}

func (Observe) Trace(_ context.Context, id string) (observe.TraceDetail, error) {
	if id != demoTrace && id != "1bf7651916cd43dd8448eb211c80319d" {
		return observe.TraceDetail{}, observe.ErrUnavailable
	}
	return observe.TraceDetail{TraceID: id, DurationMs: 3200, Spans: []observe.Span{
		{ID: "s1", Service: "researcher", Name: "a2a.request", OffsetMs: 0, DurationMs: 3200, Attrs: map[string]string{"gen_ai.agent.name": "researcher", "a2a.task.state": "completed"}},
		{ID: "s2", ParentID: "s1", Service: "model-gateway", Name: "POST /v1/chat/completions", OffsetMs: 100, DurationMs: 1600, Attrs: map[string]string{"gen_ai.request.model": "claude-haiku-5-5", "gen_ai.usage.input_tokens": "15391", "gen_ai.usage.output_tokens": "120"}},
		{ID: "s3", ParentID: "s1", Service: "researcher", Name: "execute_tool osv_query_vulnerability", OffsetMs: 1750, DurationMs: 900, Attrs: map[string]string{"gen_ai.tool.name": "osv_query_vulnerability"}},
		{ID: "s4", ParentID: "s1", Service: "model-gateway", Name: "POST /v1/chat/completions", OffsetMs: 2700, DurationMs: 480, Attrs: map[string]string{"gen_ai.request.model": "claude-haiku-5-5", "gen_ai.usage.input_tokens": "15391", "gen_ai.usage.output_tokens": "143"}},
	}}, nil
}
