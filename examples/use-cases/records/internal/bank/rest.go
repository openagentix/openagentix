package bank

import (
	"net/http"
	"strconv"
	"time"

	"github.com/openagentix/openagentix/examples/use-cases/records/internal/core"
)

// handler is a REST handler that returns what to send and what to audit.
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
		return 0, &core.Error{Kind: core.Invalid, Msg: name + " must be a number"}
	}
	return n, nil
}

// requireApprover authenticates the caller. A refusal is audited with the actor "anonymous".
func (d *Domain) requireApprover(r *http.Request, action string) (core.Approver, error) {
	who, ok := d.approvers.Authenticate(r)
	if !ok {
		d.audit.Record(r.Context(), core.AuditEntry{Actor: "anonymous", Channel: "rest", Action: action, Outcome: "denied"})
		return core.Approver{}, &core.Error{Kind: core.Unauthorized, Msg: "a valid approver token is required"}
	}
	return who, nil
}

// Handler serves the REST API (port 8081). Reads and the agent's own steps need no login; the two decision
// routes and the audit log need an approver token.
func (d *Domain) Handler() http.Handler {
	mux := http.NewServeMux()
	s := d.svc
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

	// Core banking, shaped like a subset of a real core banking API.
	mux.HandleFunc("GET /clients/{id}", d.route("get_client", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		v, err := s.GetCustomer(r.Context(), r.PathValue("id"))
		return r.PathValue("id"), v, err
	}))
	mux.HandleFunc("GET /savingsaccounts/{id}", d.route("get_account", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		v, err := s.GetAccount(r.Context(), r.PathValue("id"))
		return r.PathValue("id"), v, err
	}))
	mux.HandleFunc("GET /savingsaccounts/{id}/transactions", d.route("list_transactions", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		limit, err := intParam(r, "limit", 50)
		if err != nil {
			return r.PathValue("id"), nil, err
		}
		v, err := s.ListTransactions(r.Context(), r.PathValue("id"), r.URL.Query().Get("from"), r.URL.Query().Get("to"), limit)
		return r.PathValue("id"), map[string]any{"transactions": v}, err
	}))
	mux.HandleFunc("GET /cards/{id}", d.route("get_card", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		v, err := s.GetCard(r.Context(), r.PathValue("id"))
		return r.PathValue("id"), v, err
	}))
	mux.HandleFunc("GET /merchants/{id}", d.route("get_merchant", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		v, err := s.GetMerchant(r.Context(), r.PathValue("id"))
		return r.PathValue("id"), v, err
	}))
	mux.HandleFunc("GET /merchants/{id}/history", d.route("merchant_history", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		v, err := s.GetMerchantHistory(r.Context(), r.PathValue("id"))
		return r.PathValue("id"), v, err
	}))

	// Cases.
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
	mux.HandleFunc("POST /cases", d.route("create_case", 201, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		var in NewCase
		if err := core.ReadJSON(w, r, &in); err != nil {
			return "", nil, err
		}
		v, err := s.CreateCase(r.Context(), in)
		return v.ID, v, err
	}))
	mux.HandleFunc("GET /cases/{id}", d.route("get_case", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		v, err := s.GetCase(r.Context(), r.PathValue("id"))
		return r.PathValue("id"), v, err
	}))
	mux.HandleFunc("GET /cases/{id}/linked", d.route("linked_cases", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		v, err := s.LinkedCases(r.Context(), r.PathValue("id"))
		return r.PathValue("id"), v, err
	}))
	mux.HandleFunc("POST /cases/{id}/evidence", d.route("attach_evidence", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		var in struct{ Kind, Ref, Note string }
		if err := core.ReadJSON(w, r, &in); err != nil {
			return r.PathValue("id"), nil, err
		}
		v, err := s.AttachEvidence(r.Context(), r.PathValue("id"), in.Kind, in.Ref, in.Note)
		return r.PathValue("id"), v, err
	}))
	mux.HandleFunc("POST /cases/{id}/route", d.route("set_route", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		var in struct{ Route, Reason string }
		if err := core.ReadJSON(w, r, &in); err != nil {
			return r.PathValue("id"), nil, err
		}
		v, err := s.SetRoute(r.Context(), r.PathValue("id"), in.Route, in.Reason)
		return r.PathValue("id"), v, err
	}))
	mux.HandleFunc("POST /cases/{id}/status", d.route("set_status", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		var in struct{ Status string }
		if err := core.ReadJSON(w, r, &in); err != nil {
			return r.PathValue("id"), nil, err
		}
		v, err := s.SetStatus(r.Context(), r.PathValue("id"), in.Status)
		return r.PathValue("id"), v, err
	}))
	mux.HandleFunc("POST /cases/{id}/letter", d.route("draft_letter", 201, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		var in struct{ Body string }
		if err := core.ReadJSON(w, r, &in); err != nil {
			return r.PathValue("id"), nil, err
		}
		v, err := s.DraftLetter(r.Context(), r.PathValue("id"), in.Body)
		return r.PathValue("id"), v, err
	}))
	mux.HandleFunc("POST /cases/{id}/chargeback", d.route("draft_chargeback", 201, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		var in struct{ Body string }
		if err := core.ReadJSON(w, r, &in); err != nil {
			return r.PathValue("id"), nil, err
		}
		v, err := s.DraftChargeback(r.Context(), r.PathValue("id"), in.Body)
		return r.PathValue("id"), v, err
	}))

	// Approvals. Proposing is open (the agent does it); deciding needs an approver token.
	mux.HandleFunc("GET /approvals", d.route("list_approvals", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		subject := r.URL.Query().Get("case_id")
		if subject != "" {
			if err := validCaseID(subject); err != nil {
				return "", nil, err
			}
		}
		v, err := d.approvals.List(r.Context(), r.URL.Query().Get("status"), subject)
		return "", map[string]any{"approvals": v}, err
	}))
	mux.HandleFunc("POST /approvals", d.route("request_approval", 201, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		var in struct {
			CaseID      string `json:"case_id"`
			Kind        string `json:"kind"`
			AmountCents int64  `json:"amount_cents"`
		}
		if err := core.ReadJSON(w, r, &in); err != nil {
			return "", nil, err
		}
		by := "rest"
		if who, ok := d.approvers.Authenticate(r); ok {
			by = who.ID // a proposal made with an approver token carries that name, so they cannot decide it
		}
		v, err := s.RequestApprovalBy(r.Context(), in.CaseID, in.Kind, in.AmountCents, by)
		return in.CaseID, v, err
	}))
	mux.HandleFunc("GET /approvals/{id}", d.route("get_approval", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		v, err := d.approvals.Get(r.Context(), r.PathValue("id"))
		return r.PathValue("id"), v, err
	}))
	mux.HandleFunc("POST /approvals/{id}/approve", func(w http.ResponseWriter, r *http.Request) {
		who, err := d.requireApprover(r, "approve")
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
		a, err := d.approvals.Approve(r.Context(), r.PathValue("id"), who, in.PayloadHash, in.Note)
		if err != nil {
			core.WriteError(w, err)
			return
		}
		core.WriteJSON(w, 200, a)
	})
	mux.HandleFunc("POST /approvals/{id}/reject", func(w http.ResponseWriter, r *http.Request) {
		who, err := d.requireApprover(r, "reject")
		if err != nil {
			core.WriteError(w, err)
			return
		}
		var in struct {
			Note string `json:"note"`
		}
		if err := core.ReadJSON(w, r, &in); err != nil {
			core.WriteError(w, err)
			return
		}
		a, err := d.approvals.Reject(r.Context(), r.PathValue("id"), who, in.Note)
		if err != nil {
			core.WriteError(w, err)
			return
		}
		core.WriteJSON(w, 200, a)
	})

	// Timers, outbox, ledger, audit.
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
			return in.CaseID, nil, &core.Error{Kind: core.Invalid, Msg: "due_at must be an RFC 3339 time"}
		}
		v, err := s.SetTimer(r.Context(), in.CaseID, in.Name, due)
		return in.CaseID, v, err
	}))
	mux.HandleFunc("GET /outbox", d.route("list_outbox", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		subject := r.URL.Query().Get("case_id")
		if subject != "" {
			if err := validCaseID(subject); err != nil {
				return "", nil, err
			}
		}
		v, err := d.outbox.List(r.Context(), subject)
		return subject, map[string]any{"outbox": v}, err
	}))
	mux.HandleFunc("GET /ledger", d.route("list_ledger", 200, func(w http.ResponseWriter, r *http.Request) (string, any, error) {
		v, err := s.Ledger(r.Context())
		return "", map[string]any{"ledger": v}, err
	}))
	mux.HandleFunc("GET /audit", func(w http.ResponseWriter, r *http.Request) {
		if _, err := d.requireApprover(r, "read_audit"); err != nil {
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
	return d.guard(mux)
}

// guard refuses cross-origin browser writes and rate limits writes per host.
func (d *Domain) guard(next http.Handler) http.Handler {
	limited := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead && !d.limiter.Allow(core.Host(r)) {
			core.WriteJSON(w, http.StatusTooManyRequests, map[string]string{"error": "too many writes from this host; try again in a minute"})
			return
		}
		next.ServeHTTP(w, r)
	})
	return http.NewCrossOriginProtection().Handler(limited)
}
