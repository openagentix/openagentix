package equipment

import (
	"net/http"
	"strconv"
	"time"

	"github.com/openagentix/openagentix/examples/use-cases/records/internal/core"
)

type handler func(w http.ResponseWriter, r *http.Request) (subject string, v any, err error)

func (d *Domain) route(action string, okCode int, fn handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		subject, v, err := fn(w, r)
		d.audit.Record(r.Context(), core.AuditEntry{Actor: "rest", Channel: "rest", Action: action, Subject: subject, Outcome: core.Outcome(err)})
		if err != nil {
			core.WriteError(w, err)
			return
		}
		core.WriteJSON(w, okCode, v)
	}
}

func intParam(r *http.Request, name string, def int) (int, error) {
	s := r.URL.Query().Get(name)
	if s == "" {
		return def, nil
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0, invalid(name + " must be a number")
	}
	return n, nil
}

// Handler serves the REST API (port 8081). Reads and the agent's own steps need no login but the port listens on
// loopback by default; the decision routes and /audit need an approver token. A proposal from outside the pod
// needs a token too.
func (d *Domain) Handler() http.Handler {
	mux := http.NewServeMux()
	s := d.svc
	id := func(r *http.Request) string { return r.PathValue("id") }
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		core.WriteJSON(w, 200, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		if err := d.Ready(r.Context()); err != nil {
			core.WriteJSON(w, 503, map[string]string{"status": "not ready"})
			return
		}
		core.WriteJSON(w, 200, map[string]string{"status": "ready"})
	})

	// Dealer management, shaped like a small subset of a maintenance or ERP system.
	mux.HandleFunc("GET /assets/{id}", d.route("get_machine", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		v, err := s.GetMachine(r.Context(), id(r))
		return id(r), v, err
	}))
	mux.HandleFunc("GET /assets/{id}/telemetry", d.route("get_telemetry", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		days, err := intParam(r, "days", 14)
		if err != nil {
			return id(r), nil, err
		}
		v, err := s.GetTelemetry(r.Context(), id(r), days)
		return id(r), map[string]any{"days": v}, err
	}))
	mux.HandleFunc("GET /parts/{id}", d.route("get_part", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		v, err := s.GetPart(r.Context(), id(r))
		return id(r), v, err
	}))
	mux.HandleFunc("GET /stock/{id}", d.route("get_stock", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		v, err := s.StockNear(r.Context(), r.URL.Query().Get("from_dealer"), id(r))
		return id(r), map[string]any{"stock": v}, err
	}))
	mux.HandleFunc("GET /warranty/{id}", d.route("check_warranty", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		v, err := s.CheckWarranty(r.Context(), id(r), r.URL.Query().Get("code"))
		return id(r), v, err
	}))
	mux.HandleFunc("GET /faultcodes/{id}", d.route("get_fault_code", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		v, err := s.GetFaultCode(r.Context(), id(r))
		return id(r), v, err
	}))
	mux.HandleFunc("GET /fleet/trends", d.route("fleet_trends", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		v, err := s.FleetTrends(r.Context())
		return "", map[string]any{"trends": v}, err
	}))
	mux.HandleFunc("POST /fleet/proactive", d.route("open_proactive_case", 201, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		var in struct{ Serial, Reason string }
		if err := core.ReadJSON(w, r, &in); err != nil {
			return "", nil, err
		}
		v, err := s.OpenProactiveCase(r.Context(), in.Serial, in.Reason)
		return v.ID, v, err
	}))
	mux.HandleFunc("GET /calendar/{id}", d.route("list_slots", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		limit, err := intParam(r, "limit", 20)
		if err != nil {
			return id(r), nil, err
		}
		v, err := s.SlotsAt(r.Context(), id(r), limit)
		return id(r), map[string]any{"slots": v}, err
	}))

	// Events and cases.
	mux.HandleFunc("POST /faults", func(w http.ResponseWriter, r *http.Request) {
		var in struct{ Serial, Code string }
		var c CaseView
		var dup bool
		err := core.ReadJSON(w, r, &in)
		if err == nil {
			c, dup, err = s.CreateFault(r.Context(), in.Serial, in.Code)
		}
		d.audit.Record(r.Context(), core.AuditEntry{Actor: "rest", Channel: "rest", Action: "fault_event", Subject: c.ID, Outcome: core.Outcome(err)})
		if err != nil {
			core.WriteError(w, err)
			return
		}
		code := 201
		if dup {
			code = 200
		}
		core.WriteJSON(w, code, map[string]any{"case": c, "deduplicated": dup})
	})
	mux.HandleFunc("POST /requests", d.route("service_request", 201, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		var in struct{ Serial, Note string }
		if err := core.ReadJSON(w, r, &in); err != nil {
			return "", nil, err
		}
		v, err := s.CreateRequest(r.Context(), in.Serial, in.Note)
		return v.ID, v, err
	}))
	mux.HandleFunc("GET /cases", d.route("list_cases", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		limit, err := intParam(r, "limit", 50)
		if err != nil {
			return "", nil, err
		}
		due, err := intParam(r, "due_within_days", 0)
		if err != nil {
			return "", nil, err
		}
		v, err := s.ListCases(r.Context(), r.URL.Query().Get("status"), due, limit)
		return "", map[string]any{"cases": v}, err
	}))
	mux.HandleFunc("GET /cases/{id}", d.route("get_case", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		v, err := s.GetCase(r.Context(), id(r))
		return id(r), v, err
	}))
	mux.HandleFunc("POST /cases/{id}/diagnosis", d.route("set_diagnosis", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		var in struct{ Cause, Text string }
		if err := core.ReadJSON(w, r, &in); err != nil {
			return id(r), nil, err
		}
		v, err := s.SetDiagnosis(r.Context(), id(r), in.Cause, in.Text)
		return id(r), v, err
	}))
	mux.HandleFunc("POST /cases/{id}/workorder", d.route("create_work_order", 201, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		var in struct{ Summary string }
		if err := core.ReadJSON(w, r, &in); err != nil {
			return id(r), nil, err
		}
		v, err := s.CreateWorkOrder(r.Context(), id(r), in.Summary)
		return id(r), v, err
	}))
	mux.HandleFunc("POST /cases/{id}/parts-order", d.route("draft_parts_order", 201, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		var in struct {
			PartID     string `json:"part_id"`
			Qty        int    `json:"qty"`
			FromDealer string `json:"from_dealer"`
			Body       string `json:"body"`
		}
		if err := core.ReadJSON(w, r, &in); err != nil {
			return id(r), nil, err
		}
		v, err := s.DraftPartsOrder(r.Context(), id(r), in.PartID, in.Qty, in.FromDealer, in.Body)
		return id(r), v, err
	}))
	mux.HandleFunc("POST /cases/{id}/warranty-claim", d.route("draft_warranty_claim", 201, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		var in struct{ Body string }
		if err := core.ReadJSON(w, r, &in); err != nil {
			return id(r), nil, err
		}
		v, err := s.DraftWarrantyClaim(r.Context(), id(r), in.Body)
		return id(r), v, err
	}))
	mux.HandleFunc("POST /cases/{id}/customer-notice", d.route("draft_customer_notice", 201, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		var in struct{ Body string }
		if err := core.ReadJSON(w, r, &in); err != nil {
			return id(r), nil, err
		}
		v, err := s.DraftCustomerNotice(r.Context(), id(r), in.Body)
		return id(r), v, err
	}))
	mux.HandleFunc("POST /cases/{id}/slot", d.route("propose_slot", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		var in struct {
			SlotID string `json:"slot_id"`
		}
		if err := core.ReadJSON(w, r, &in); err != nil {
			return id(r), nil, err
		}
		v, err := s.ProposeSlot(r.Context(), id(r), in.SlotID)
		return id(r), v, err
	}))
	mux.HandleFunc("POST /cases/{id}/status", d.route("set_status", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		var in struct{ Status string }
		if err := core.ReadJSON(w, r, &in); err != nil {
			return id(r), nil, err
		}
		v, err := s.SetStatus(r.Context(), id(r), in.Status)
		return id(r), v, err
	}))

	// Approvals. Proposing from outside the pod needs a token; deciding always does.
	mux.HandleFunc("GET /approvals", d.route("list_approvals", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		v, err := d.approvals.List(r.Context(), r.URL.Query().Get("status"), "")
		return "", map[string]any{"approvals": v}, err
	}))
	mux.HandleFunc("POST /approvals", d.route("request_approval", 201, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		var in struct {
			CaseID string `json:"case_id"`
			Kind   string `json:"kind"`
		}
		if err := core.ReadJSON(w, r, &in); err != nil {
			return "", nil, err
		}
		by, err := d.guard.Proposer(r)
		if err != nil {
			return in.CaseID, nil, err
		}
		v, err := s.RequestApprovalBy(r.Context(), in.CaseID, in.Kind, by)
		return in.CaseID, v, err
	}))
	mux.HandleFunc("GET /approvals/{id}", d.route("get_approval", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		v, err := d.approvals.Get(r.Context(), id(r))
		return id(r), v, err
	}))
	mux.HandleFunc("POST /approvals/{id}/approve", func(w http.ResponseWriter, r *http.Request) {
		who, err := d.guard.RequireApprover(r, "approve")
		if err != nil {
			core.WriteError(w, err)
			return
		}
		var in struct {
			PayloadHash string `json:"payload_hash"`
			Note        string `json:"note"`
		}
		if err := core.ReadJSON(w, r, &in); err != nil {
			core.WriteError(w, err)
			return
		}
		a, err := d.approvals.Approve(r.Context(), id(r), who, in.PayloadHash, in.Note)
		if err != nil {
			core.WriteError(w, err)
			return
		}
		core.WriteJSON(w, 200, a)
	})
	mux.HandleFunc("POST /approvals/{id}/reject", func(w http.ResponseWriter, r *http.Request) {
		who, err := d.guard.RequireApprover(r, "reject")
		if err != nil {
			core.WriteError(w, err)
			return
		}
		var in struct{ Note string }
		if err := core.ReadJSON(w, r, &in); err != nil {
			core.WriteError(w, err)
			return
		}
		a, err := d.approvals.Reject(r.Context(), id(r), who, in.Note)
		if err != nil {
			core.WriteError(w, err)
			return
		}
		core.WriteJSON(w, 200, a)
	})

	// Timers, outbox, audit.
	mux.HandleFunc("GET /timers", d.route("list_timers", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		v, err := d.timers.List(r.Context(), r.URL.Query().Get("status"), "")
		return "", map[string]any{"timers": v}, err
	}))
	mux.HandleFunc("POST /timers", d.route("set_timer", 201, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		var in struct {
			CaseID string `json:"case_id"`
			Name   string `json:"name"`
			DueAt  string `json:"due_at"`
		}
		if err := core.ReadJSON(w, r, &in); err != nil {
			return "", nil, err
		}
		due, err := time.Parse(time.RFC3339, in.DueAt)
		if err != nil {
			return in.CaseID, nil, invalid("due_at must be an RFC 3339 time")
		}
		v, err := s.SetTimer(r.Context(), in.CaseID, in.Name, due)
		return in.CaseID, v, err
	}))
	mux.HandleFunc("GET /outbox", d.route("list_outbox", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		subject := r.URL.Query().Get("case_id")
		if subject != "" {
			if err := validate(caseRe, "case_id", subject); err != nil {
				return "", nil, err
			}
		}
		v, err := d.outbox.List(r.Context(), subject)
		return subject, map[string]any{"outbox": v}, err
	}))
	mux.HandleFunc("GET /audit", func(w http.ResponseWriter, r *http.Request) {
		if _, err := d.guard.RequireApprover(r, "read_audit"); err != nil {
			core.WriteError(w, err)
			return
		}
		limit, err := intParam(r, "limit", 100)
		if err != nil {
			core.WriteError(w, err)
			return
		}
		v, err := d.audit.List(r.Context(), limit)
		if err != nil {
			core.WriteError(w, err)
			return
		}
		core.WriteJSON(w, 200, map[string]any{"audit": v})
	})
	return d.guard.Wrap(mux)
}
