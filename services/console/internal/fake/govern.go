package fake

import (
	"context"
	"time"

	"github.com/openagentix/openagentix/services/console/internal/govern"
)

// Schedules is the demo mode's schedule list: invented, like the rest of the demo data.
type Schedules struct{}

func (Schedules) Schedules(context.Context) (govern.ScheduleList, error) {
	now := time.Now().UTC()
	return govern.ScheduleList{Configured: true, Namespace: "openagentix-schedules", Items: []govern.Schedule{
		{Name: "daily-digest", Agent: "assistant", Cron: "0 7 * * 1-5", TimeZone: "Europe/Berlin", ConcurrencyPolicy: "Forbid", Timeout: "5m",
			State: "active", LastScheduled: now.Add(-5 * time.Hour).Format(time.RFC3339), LastSucceeded: now.Add(-5 * time.Hour).Format(time.RFC3339),
			Created: now.Add(-72 * time.Hour).Format(time.RFC3339)},
		{Name: "weekly-review", Agent: "researcher", Cron: "0 9 * * 1", ConcurrencyPolicy: "Forbid", Timeout: "10m",
			State: "suspended", Created: now.Add(-72 * time.Hour).Format(time.RFC3339)},
	}}, nil
}

// Access is the demo mode's gate caller list.
type Access struct{}

func (Access) Access(context.Context) (govern.AccessList, error) {
	return govern.AccessList{Configured: true, Namespace: "openagentix-governance", Items: []govern.Caller{
		{Name: "bridge", Source: "chart", ServiceAccount: "openagentix-bridge/telegram-bridge", Agents: []string{"kagent/assistant"},
			UserIDRule: "prefix", Methods: []string{"SendMessage"}, Memory: true},
		{Name: "ci-checker", Source: "values", ServiceAccount: "ci/checker", Agents: []string{"kagent/researcher", "kagent/assistant"},
			UserIDRule: "exact", Methods: []string{"SendMessage", "SendStreamingMessage"}},
		{Name: "schedule-daily-digest", Source: "chart", ServiceAccount: "openagentix-schedules/schedule-daily-digest", Agents: []string{"kagent/assistant"},
			UserIDRule: "exact", Methods: []string{"SendMessage"}},
	}}, nil
}
