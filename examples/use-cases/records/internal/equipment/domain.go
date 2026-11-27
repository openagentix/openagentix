package equipment

import (
	"context"
	"database/sql"
	"errors"
	"log/slog"

	"github.com/openagentix/openagentix/examples/use-cases/records/internal/core"
)

// WriteLimitPerMinute is how many writes one host may make on the REST port each minute.
const WriteLimitPerMinute = 120

// Domain is the equipment module: store, services, REST routes and MCP tools.
type Domain struct {
	db        *sql.DB
	log       *slog.Logger
	clock     core.Clock
	approvers *core.Approvers
	audit     *core.Audit
	approvals *core.Approvals
	timers    *core.Timers
	outbox    *core.Outbox
	svc       *Service
	guard     *core.RESTGuard
}

// New migrates the schema and wires the module. It does not seed.
func New(db *sql.DB, log *slog.Logger, clock core.Clock, approvers *core.Approvers) (*Domain, error) {
	ctx := context.Background()
	if err := core.MigrateCore(ctx, db); err != nil {
		return nil, err
	}
	if _, err := db.ExecContext(ctx, schema); err != nil {
		return nil, err
	}
	d := &Domain{db: db, log: log, clock: clock, approvers: approvers}
	d.audit = core.NewAudit(db, log, clock)
	d.guard = core.NewRESTGuard(approvers, d.audit, clock, WriteLimitPerMinute)
	d.timers = core.NewTimers(db, clock)
	d.outbox = core.NewOutbox(db)
	d.svc = &Service{db: db, clock: clock, timers: d.timers, outbox: d.outbox}
	d.approvals = core.NewApprovals(db, d.svc, d.audit, clock)
	d.svc.approvals = d.approvals
	return d, nil
}

// Name is the domain name.
func (d *Domain) Name() string { return "equipment" }

// FireDue marks due timers fired. The service calls it on a ticker.
func (d *Domain) FireDue(ctx context.Context) (int, error) {
	fired, err := d.timers.FireDue(ctx, d.clock())
	for _, t := range fired {
		d.audit.Record(ctx, core.AuditEntry{Actor: "timer", Channel: "internal", Action: "timer_fired", Subject: t.Subject, Outcome: "ok"})
	}
	return len(fired), err
}

// Ready reports whether the store answers and the data is loaded.
func (d *Domain) Ready(ctx context.Context) error {
	var n int
	if err := d.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM meta WHERE k='equipment_seeded'`).Scan(&n); err != nil {
		return err
	}
	if n == 0 {
		return errors.New("the store is not seeded")
	}
	return nil
}
