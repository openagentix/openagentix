// Package equipment is the equipment-service domain of the records service: machines, fault codes, telematics,
// parts and stock across dealers, warranty terms, work orders, drafts of parts orders, warranty claims and customer
// notices, and technician slots, for the fictional Kestrel Valley Machinery dealer network. Everything in it is
// synthetic.
package equipment

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"regexp"
	"sort"
	"time"

	"github.com/openagentix/openagentix/examples/use-cases/records/internal/core"
)

// Approval kinds. The kind must follow the warranty decision the record makes, not the agent's opinion.
const (
	KindOrderWithClaim = "parts_order_with_claim"
	KindOrder          = "parts_order"
)

// ResponseWorkingDays is the dealer's service response window.
const ResponseWorkingDays = 5

// Fleet trend rules: a machine trends to failure when its coolant mean over the last 14 days is at least
// TrendThresholdC above its mean 30 to 60 days ago. Many isolated spikes mean a flapping sensor instead.
const (
	TrendThresholdC = 8.0
	SpikeThreshold  = 10
	spikeAboveC     = 25.0
)

var (
	serialRe = regexp.MustCompile(`^[A-Z]{2}[0-9]{2,4}-[0-9]{5}$`)
	partRe   = regexp.MustCompile(`^P-[0-9]{5}$`)
	dealerRe = regexp.MustCompile(`^D-[0-9]{3}$`)
	codeRe   = regexp.MustCompile(`^E-[0-9]{3}$`)
	slotRe   = regexp.MustCompile(`^SLT-[0-9]{4}$`)
	caseRe   = regexp.MustCompile(`^SVC-[0-9]{4}-[0-9]{4}$`)
)

func addWorkingDays(t time.Time, n int) time.Time {
	for n > 0 {
		t = t.AddDate(0, 0, 1)
		if wd := t.Weekday(); wd != time.Saturday && wd != time.Sunday {
			n--
		}
	}
	return t
}

func invalid(msg string) error  { return &core.Error{Kind: core.Invalid, Msg: msg} }
func conflict(msg string) error { return &core.Error{Kind: core.Conflict, Msg: msg} }
func notFound(msg string) error { return &core.Error{Kind: core.NotFound, Msg: msg} }

func validate(re *regexp.Regexp, field, s string) error {
	if !re.MatchString(s) {
		return invalid(field + " is not valid")
	}
	return nil
}

type querier interface {
	QueryRowContext(ctx context.Context, q string, args ...any) *sql.Row
	QueryContext(ctx context.Context, q string, args ...any) (*sql.Rows, error)
}

// CaseView is a service case as REST serves it.
type CaseView struct {
	ID             string `json:"id"`
	Serial         string `json:"serial"`
	DealerID       string `json:"dealer_id"`
	Kind           string `json:"kind"`
	FaultCode      string `json:"fault_code"`
	DealerNote     string `json:"dealer_note"`
	Status         string `json:"status"`
	DiagnosisCause string `json:"diagnosis_cause"`
	Diagnosis      string `json:"diagnosis"`
	WorkOrder      string `json:"work_order"`
	OpenedAt       string `json:"opened_at"`
	ResponseDue    string `json:"response_due"`
	Version        int64  `json:"version"`
	HumanDiagnosis string `json:"human_diagnosis,omitempty"` // replay ground truth: REST only, never in MCP views
}

const caseCols = `id,serial,dealer_id,kind,fault_code,dealer_note,status,diagnosis_cause,diagnosis,opened_at,response_due,version,human_diagnosis`

func scanCase(r interface{ Scan(...any) error }) (CaseView, error) {
	var c CaseView
	err := r.Scan(&c.ID, &c.Serial, &c.DealerID, &c.Kind, &c.FaultCode, &c.DealerNote, &c.Status, &c.DiagnosisCause, &c.Diagnosis, &c.OpenedAt, &c.ResponseDue, &c.Version, &c.HumanDiagnosis)
	return c, err
}

func loadCase(ctx context.Context, q querier, id string) (CaseView, error) {
	c, err := scanCase(q.QueryRowContext(ctx, `SELECT `+caseCols+` FROM service_cases WHERE id=?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return c, notFound("case not found")
	}
	if err != nil {
		return c, err
	}
	err = q.QueryRowContext(ctx, `SELECT summary FROM work_orders WHERE case_id=?`, id).Scan(&c.WorkOrder)
	if errors.Is(err, sql.ErrNoRows) {
		err = nil
	}
	return c, err
}

// Service holds the domain's operations. REST handlers and MCP tools both call it.
type Service struct {
	db        *sql.DB
	clock     core.Clock
	approvals *core.Approvals
	timers    *core.Timers
	outbox    *core.Outbox
}

// GetCase returns a case.
func (s *Service) GetCase(ctx context.Context, id string) (CaseView, error) {
	if err := validate(caseRe, "case id", id); err != nil {
		return CaseView{}, err
	}
	return loadCase(ctx, s.db, id)
}

// ListCases returns cases, soonest response deadline first. status "" means every case that is not resolved.
func (s *Service) ListCases(ctx context.Context, status string, dueWithinDays, limit int) ([]CaseView, error) {
	switch status {
	case "", "all", "open", "in_review", "needs_person", "pending_approval", "resolved":
	default:
		return nil, invalid("status is not valid")
	}
	if limit < 1 || limit > 200 {
		return nil, invalid("limit must be 1 to 200")
	}
	if dueWithinDays < 0 || dueWithinDays > 400 {
		return nil, invalid("due_within_days must be 0 to 400")
	}
	cutoff := "9999-12-31T00:00:00Z"
	if dueWithinDays > 0 {
		cutoff = core.FormatTime(s.clock().AddDate(0, 0, dueWithinDays))
	}
	rows, err := s.db.QueryContext(ctx, `SELECT `+caseCols+` FROM service_cases
		WHERE (?='all' OR (?='' AND status<>'resolved') OR status=?) AND response_due<=? ORDER BY response_due, id LIMIT ?`, status, status, status, cutoff, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []CaseView{}
	for rows.Next() {
		c, err := scanCase(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

type machineRow struct {
	Serial, ModelID, DealerID, CustomerRef, InService, Config, FittedParts string
	Hours, WarrantyMonths, WarrantyHours                                   int
}

func loadMachine(ctx context.Context, q querier, serial string) (machineRow, error) {
	if err := validate(serialRe, "serial", serial); err != nil {
		return machineRow{}, err
	}
	var m machineRow
	err := q.QueryRowContext(ctx, `SELECT m.serial,m.model_id,m.dealer_id,m.customer_ref,m.in_service,m.config,m.fitted_parts,m.hours,o.warranty_months,o.warranty_hours
		FROM machines m JOIN models o ON o.id=m.model_id WHERE m.serial=?`, serial).
		Scan(&m.Serial, &m.ModelID, &m.DealerID, &m.CustomerRef, &m.InService, &m.Config, &m.FittedParts, &m.Hours, &m.WarrantyMonths, &m.WarrantyHours)
	if errors.Is(err, sql.ErrNoRows) {
		return m, notFound("machine not found")
	}
	return m, err
}

// FaultCount is how often a fault code was seen on a machine in the last 90 days.
type FaultCount struct {
	Code  string `json:"code"`
	Count int    `json:"count"`
}

// MachineView is a machine with its recent faults.
type MachineView struct {
	Serial       string       `json:"serial"`
	ModelID      string       `json:"model_id"`
	DealerID     string       `json:"dealer_id"`
	CustomerRef  string       `json:"customer_ref"` // an opaque reference; contact data is never held here
	InServiceAt  string       `json:"in_service_at"`
	Hours        int          `json:"hours"`
	Config       string       `json:"config"`
	FittedParts  string       `json:"fitted_parts"`
	RecentFaults []FaultCount `json:"recent_faults"`
}

// GetMachine returns a machine and its fault counts over the last 90 days (a repeated fault shows a count above 1).
func (s *Service) GetMachine(ctx context.Context, serial string) (MachineView, error) {
	m, err := loadMachine(ctx, s.db, serial)
	if err != nil {
		return MachineView{}, err
	}
	v := MachineView{Serial: m.Serial, ModelID: m.ModelID, DealerID: m.DealerID, CustomerRef: m.CustomerRef, InServiceAt: m.InService, Hours: m.Hours,
		Config: m.Config, FittedParts: m.FittedParts, RecentFaults: []FaultCount{}}
	rows, err := s.db.QueryContext(ctx, `SELECT code, COUNT(*) FROM fault_events WHERE machine=? AND at>=? GROUP BY code ORDER BY code`,
		serial, core.FormatTime(s.clock().AddDate(0, 0, -90)))
	if err != nil {
		return v, err
	}
	defer rows.Close()
	for rows.Next() {
		var f FaultCount
		if err := rows.Scan(&f.Code, &f.Count); err != nil {
			return v, err
		}
		v.RecentFaults = append(v.RecentFaults, f)
	}
	return v, rows.Err()
}

// FaultCodeView is a row of the fault code table.
type FaultCodeView struct {
	Code           string `json:"code"`
	Description    string `json:"description"`
	FirstCause     string `json:"first_cause"`
	PartID         string `json:"part_id"`
	SafetyCritical bool   `json:"safety_critical"`
	Warrantable    bool   `json:"warrantable"`
}

// GetFaultCode returns one fault code.
func (s *Service) GetFaultCode(ctx context.Context, code string) (FaultCodeView, error) {
	return getFaultCode(ctx, s.db, code)
}

func getFaultCode(ctx context.Context, q querier, code string) (FaultCodeView, error) {
	if err := validate(codeRe, "fault code", code); err != nil {
		return FaultCodeView{}, err
	}
	var f FaultCodeView
	var sc, w int
	err := q.QueryRowContext(ctx, `SELECT code,description,first_cause,part_id,safety_critical,warrantable FROM fault_codes WHERE code=?`, code).
		Scan(&f.Code, &f.Description, &f.FirstCause, &f.PartID, &sc, &w)
	if errors.Is(err, sql.ErrNoRows) {
		return f, notFound("fault code not found")
	}
	f.SafetyCritical, f.Warrantable = sc == 1, w == 1
	return f, err
}

// Part is a part and what replaced it.
type Part struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	SupersededBy string `json:"superseded_by,omitempty"`
}

// GetPart returns a part. A part with superseded_by set must not be ordered: order its replacement.
func (s *Service) GetPart(ctx context.Context, id string) (Part, error) {
	return getPart(ctx, s.db, id)
}

func getPart(ctx context.Context, q querier, id string) (Part, error) {
	if err := validate(partRe, "part id", id); err != nil {
		return Part{}, err
	}
	var p Part
	err := q.QueryRowContext(ctx, `SELECT id,name,superseded_by FROM parts WHERE id=?`, id).Scan(&p.ID, &p.Name, &p.SupersededBy)
	if errors.Is(err, sql.ErrNoRows) {
		return p, notFound("part not found")
	}
	return p, err
}

// Warranty is the record's decision. A claim and a claim-bearing approval follow it, not the agent.
type Warranty struct {
	Covered bool   `json:"covered"`
	Reason  string `json:"reason"`
}

// CheckWarranty decides coverage from the model's terms, the machine's age and hours, and the fault code.
func (s *Service) CheckWarranty(ctx context.Context, serial, code string) (Warranty, error) {
	return checkWarranty(ctx, s.db, s.clock(), serial, code)
}

func checkWarranty(ctx context.Context, q querier, now time.Time, serial, code string) (Warranty, error) {
	m, err := loadMachine(ctx, q, serial)
	if err != nil {
		return Warranty{}, err
	}
	if code != "" {
		f, err := getFaultCode(ctx, q, code)
		if err != nil {
			return Warranty{}, err
		}
		if !f.Warrantable {
			return Warranty{Covered: false, Reason: "this fault code is not a warranty item"}, nil
		}
	}
	in, err := time.Parse(core.TimeFmt, m.InService)
	if err != nil {
		return Warranty{}, err
	}
	months := int(now.Sub(in).Hours() / 24 / 30)
	switch {
	case months > m.WarrantyMonths:
		return Warranty{Covered: false, Reason: fmt.Sprintf("outside the warranty period: %d months in service, limit %d", months, m.WarrantyMonths)}, nil
	case m.Hours > m.WarrantyHours:
		return Warranty{Covered: false, Reason: fmt.Sprintf("over the hours limit: %d hours, limit %d", m.Hours, m.WarrantyHours)}, nil
	}
	return Warranty{Covered: true, Reason: fmt.Sprintf("covered: %d of %d months, %d of %d hours", months, m.WarrantyMonths, m.Hours, m.WarrantyHours)}, nil
}

// StockRow is the stock of one part at one dealer and its distance from the case's dealer.
type StockRow struct {
	DealerID   string  `json:"dealer_id"`
	DealerName string  `json:"dealer_name"`
	Qty        int     `json:"qty"`
	DistanceKm float64 `json:"distance_km"`
}

// StockFor returns the stock of a part at every dealer, nearest to the case's dealer first.
func (s *Service) StockFor(ctx context.Context, caseID, partID string) ([]StockRow, error) {
	c, err := s.GetCase(ctx, caseID)
	if err != nil {
		return nil, err
	}
	return s.StockNear(ctx, c.DealerID, partID)
}

// StockNear is StockFor from a dealer.
func (s *Service) StockNear(ctx context.Context, dealerID, partID string) ([]StockRow, error) {
	if err := validate(dealerRe, "dealer id", dealerID); err != nil {
		return nil, err
	}
	if _, err := getPart(ctx, s.db, partID); err != nil {
		return nil, err
	}
	var x0, y0 int
	if err := s.db.QueryRowContext(ctx, `SELECT x,y FROM dealers WHERE id=?`, dealerID).Scan(&x0, &y0); errors.Is(err, sql.ErrNoRows) {
		return nil, notFound("dealer not found")
	} else if err != nil {
		return nil, err
	}
	rows, err := s.db.QueryContext(ctx, `SELECT d.id,d.name,d.x,d.y,COALESCE(s.qty,0) FROM dealers d LEFT JOIN stock s ON s.dealer_id=d.id AND s.part_id=?`, partID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []StockRow{}
	for rows.Next() {
		var r StockRow
		var x, y int
		if err := rows.Scan(&r.DealerID, &r.DealerName, &x, &y, &r.Qty); err != nil {
			return nil, err
		}
		r.DistanceKm = math.Round(math.Hypot(float64(x-x0), float64(y-y0))*10) / 10
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].DistanceKm < out[j].DistanceKm })
	return out, nil
}

// DayPoint is one day of telematics.
type DayPoint struct {
	Day              string  `json:"day"`
	CoolantMeanC     float64 `json:"coolant_mean_c"`
	CoolantMaxC      float64 `json:"coolant_max_c"`
	HydraulicMeanKpa float64 `json:"hydraulic_mean_kpa"`
}

// GetTelemetry returns daily figures for the last 1 to 30 days.
func (s *Service) GetTelemetry(ctx context.Context, serial string, days int) ([]DayPoint, error) {
	if err := validate(serialRe, "serial", serial); err != nil {
		return nil, err
	}
	if days < 1 || days > 30 {
		return nil, invalid("days must be 1 to 30")
	}
	var n int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM telemetry WHERE machine=?`, serial).Scan(&n); err != nil {
		return nil, err
	}
	if n == 0 {
		return nil, notFound("no telematics for this machine")
	}
	rows, err := s.db.QueryContext(ctx, `SELECT substr(ts,1,10), AVG(coolant_c), MAX(coolant_c), AVG(hydraulic_kpa) FROM telemetry WHERE machine=? AND ts>=?
		GROUP BY substr(ts,1,10) ORDER BY 1`, serial, core.FormatTime(s.clock().AddDate(0, 0, -days)))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []DayPoint{}
	for rows.Next() {
		var p DayPoint
		if err := rows.Scan(&p.Day, &p.CoolantMeanC, &p.CoolantMaxC, &p.HydraulicMeanKpa); err != nil {
			return nil, err
		}
		p.CoolantMeanC, p.CoolantMaxC, p.HydraulicMeanKpa = round1(p.CoolantMeanC), round1(p.CoolantMaxC), round1(p.HydraulicMeanKpa)
		out = append(out, p)
	}
	return out, rows.Err()
}

func round1(f float64) float64 { return math.Round(f*10) / 10 }

// Trend is the sweep's reading of one machine.
type Trend struct {
	Serial         string  `json:"serial"`
	TrendC         float64 `json:"trend_c"`
	SpikeCount     int     `json:"spike_count"`
	Classification string  `json:"classification"` // trending_to_failure, sensor_flapping or normal
}

func trendFor(ctx context.Context, q querier, now time.Time, serial string) (Trend, error) {
	t := Trend{Serial: serial, Classification: "normal"}
	var recent, base sql.NullFloat64
	if err := q.QueryRowContext(ctx, `SELECT
		(SELECT AVG(coolant_c) FROM telemetry WHERE machine=? AND ts>=?),
		(SELECT AVG(coolant_c) FROM telemetry WHERE machine=? AND ts>=? AND ts<?)`,
		serial, core.FormatTime(now.AddDate(0, 0, -14)), serial, core.FormatTime(now.AddDate(0, 0, -60)), core.FormatTime(now.AddDate(0, 0, -30))).Scan(&recent, &base); err != nil {
		return t, err
	}
	if !recent.Valid || !base.Valid {
		return t, nil
	}
	t.TrendC = round1(recent.Float64 - base.Float64)
	if err := q.QueryRowContext(ctx, `SELECT COUNT(*) FROM telemetry WHERE machine=? AND coolant_c>?`, serial, base.Float64+spikeAboveC).Scan(&t.SpikeCount); err != nil {
		return t, err
	}
	switch {
	case t.SpikeCount >= SpikeThreshold:
		t.Classification = "sensor_flapping"
	case t.TrendC >= TrendThresholdC:
		t.Classification = "trending_to_failure"
	}
	return t, nil
}

// FleetTrends reads every machine that reports telematics, worst trend first.
func (s *Service) FleetTrends(ctx context.Context) ([]Trend, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT DISTINCT machine FROM telemetry ORDER BY machine`)
	if err != nil {
		return nil, err
	}
	var serials []string
	for rows.Next() {
		var m string
		if err := rows.Scan(&m); err != nil {
			_ = rows.Close()
			return nil, err
		}
		serials = append(serials, m)
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	out := make([]Trend, 0, len(serials))
	for _, m := range serials {
		t, err := trendFor(ctx, s.db, s.clock(), m)
		if err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].TrendC > out[j].TrendC })
	return out, nil
}

// Slot is a technician slot.
type Slot struct {
	ID       string `json:"id"`
	DealerID string `json:"dealer_id"`
	Tech     string `json:"tech"`
	StartsAt string `json:"starts_at"`
	Status   string `json:"status"`
}

// FreeSlots lists the free technician slots at the case's dealer, soonest first.
func (s *Service) FreeSlots(ctx context.Context, caseID string, limit int) ([]Slot, error) {
	c, err := s.GetCase(ctx, caseID)
	if err != nil {
		return nil, err
	}
	return s.SlotsAt(ctx, c.DealerID, limit)
}

// SlotsAt lists the free slots at a dealer.
func (s *Service) SlotsAt(ctx context.Context, dealerID string, limit int) ([]Slot, error) {
	if err := validate(dealerRe, "dealer id", dealerID); err != nil {
		return nil, err
	}
	if limit < 1 || limit > 50 {
		return nil, invalid("limit must be 1 to 50")
	}
	rows, err := s.db.QueryContext(ctx, `SELECT id,dealer_id,tech,starts_at,status FROM slots WHERE dealer_id=? AND status='free' ORDER BY starts_at, id LIMIT ?`, dealerID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Slot{}
	for rows.Next() {
		var sl Slot
		if err := rows.Scan(&sl.ID, &sl.DealerID, &sl.Tech, &sl.StartsAt, &sl.Status); err != nil {
			return nil, err
		}
		out = append(out, sl)
	}
	return out, rows.Err()
}

func (s *Service) newCase(ctx context.Context, tx *sql.Tx, serial, dealer, kind, code, note string) (string, error) {
	var n int
	if err := tx.QueryRowContext(ctx, `SELECT COALESCE(MAX(n),0)+1 FROM service_cases`).Scan(&n); err != nil {
		return "", err
	}
	if n > 9999 {
		return "", conflict("case numbers are used up")
	}
	now := s.clock()
	id := fmt.Sprintf("SVC-%04d-%04d", now.Year(), n)
	_, err := tx.ExecContext(ctx, `INSERT INTO service_cases(id,n,serial,dealer_id,kind,fault_code,dealer_note,status,opened_at,response_due,version,pattern,human_diagnosis)
		VALUES(?,?,?,?,?,?,?,'open',?,?,1,'','')`, id, n, serial, dealer, kind, code, note, core.FormatTime(now), core.FormatTime(addWorkingDays(now, ResponseWorkingDays)))
	return id, err
}

// CreateFault records a telematics fault event and opens a case. An open case for the same fault code on the
// same machine is reused (the second return value is true), so a machine that repeats a fault does not flood the desk.
func (s *Service) CreateFault(ctx context.Context, serial, code string) (CaseView, bool, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return CaseView{}, false, err
	}
	defer func() { _ = tx.Rollback() }()
	m, err := loadMachine(ctx, tx, serial)
	if err != nil {
		return CaseView{}, false, err
	}
	if _, err := getFaultCode(ctx, tx, code); err != nil {
		return CaseView{}, false, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO fault_events(machine,code,at,source) VALUES(?,?,?, 'telematics')`, serial, code, core.FormatTime(s.clock())); err != nil {
		return CaseView{}, false, err
	}
	var id string
	err = tx.QueryRowContext(ctx, `SELECT id FROM service_cases WHERE serial=? AND fault_code=? AND kind='fault' AND status<>'resolved' ORDER BY id LIMIT 1`, serial, code).Scan(&id)
	dup := err == nil
	if errors.Is(err, sql.ErrNoRows) {
		if id, err = s.newCase(ctx, tx, serial, m.DealerID, "fault", code, ""); err != nil {
			return CaseView{}, false, err
		}
	} else if err != nil {
		return CaseView{}, false, err
	}
	if err := tx.Commit(); err != nil {
		return CaseView{}, false, err
	}
	c, err := s.GetCase(ctx, id)
	return c, dup, err
}

// CreateRequest opens a case from a dealer's service request. The note is the dealer's own words: untrusted text.
func (s *Service) CreateRequest(ctx context.Context, serial, note string) (CaseView, error) {
	note, err := core.CleanText("note", note, 500, true)
	if err != nil {
		return CaseView{}, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return CaseView{}, err
	}
	defer func() { _ = tx.Rollback() }()
	m, err := loadMachine(ctx, tx, serial)
	if err != nil {
		return CaseView{}, err
	}
	id, err := s.newCase(ctx, tx, serial, m.DealerID, "request", "", note)
	if err != nil {
		return CaseView{}, err
	}
	if err := tx.Commit(); err != nil {
		return CaseView{}, err
	}
	return s.GetCase(ctx, id)
}

// OpenProactiveCase opens a case for a machine the fleet sweep found trending to failure. A flapping sensor or a
// normal machine gets none. An open sweep case for the machine is returned instead of a second one.
func (s *Service) OpenProactiveCase(ctx context.Context, serial, reason string) (CaseView, error) {
	reason, err := core.CleanText("reason", reason, 500, true)
	if err != nil {
		return CaseView{}, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return CaseView{}, err
	}
	defer func() { _ = tx.Rollback() }()
	m, err := loadMachine(ctx, tx, serial)
	if err != nil {
		return CaseView{}, err
	}
	t, err := trendFor(ctx, tx, s.clock(), serial)
	if err != nil {
		return CaseView{}, err
	}
	if t.Classification != "trending_to_failure" {
		return CaseView{}, conflict("the sweep reads this machine as " + t.Classification + ", so no case is opened")
	}
	var id string
	err = tx.QueryRowContext(ctx, `SELECT id FROM service_cases WHERE serial=? AND kind='sweep' AND status<>'resolved' ORDER BY id LIMIT 1`, serial).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		id, err = s.newCase(ctx, tx, serial, m.DealerID, "sweep", "", reason)
	}
	if err != nil {
		return CaseView{}, err
	}
	if err := tx.Commit(); err != nil {
		return CaseView{}, err
	}
	return s.GetCase(ctx, id)
}

// mutate changes a case in one transaction. It refuses a resolved case, bumps the version, and marks a pending
// approval superseded (the approver saw something that no longer holds).
func (s *Service) mutate(ctx context.Context, id string, fn func(tx *sql.Tx, c CaseView) (status string, err error)) error {
	if err := validate(caseRe, "case id", id); err != nil {
		return err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	c, err := loadCase(ctx, tx, id)
	if err != nil {
		return err
	}
	if c.Status == "resolved" {
		return conflict("case is resolved")
	}
	status, err := fn(tx, c)
	if err != nil {
		return err
	}
	if c.Status == "pending_approval" {
		if err := core.SupersedePending(ctx, tx, id, s.clock()); err != nil {
			return err
		}
		if status == "" {
			status = "in_review"
		}
	}
	if status == "" && c.Status == "open" {
		status = "in_review"
	}
	if status == "" {
		status = c.Status
	}
	if _, err := tx.ExecContext(ctx, `UPDATE service_cases SET status=?, version=version+1 WHERE id=?`, status, id); err != nil {
		return err
	}
	return tx.Commit()
}

// SetDiagnosis records the likely cause and the reasoning.
func (s *Service) SetDiagnosis(ctx context.Context, id, cause, text string) (CaseView, error) {
	cause, err := core.CleanText("cause", cause, 200, true)
	if err != nil {
		return CaseView{}, err
	}
	text, err = core.CleanText("text", text, 1000, false)
	if err != nil {
		return CaseView{}, err
	}
	err = s.mutate(ctx, id, func(tx *sql.Tx, c CaseView) (string, error) {
		_, err := tx.ExecContext(ctx, `UPDATE service_cases SET diagnosis_cause=?, diagnosis=? WHERE id=?`, cause, text, id)
		return "", err
	})
	if err != nil {
		return CaseView{}, err
	}
	return s.GetCase(ctx, id)
}

// SetStatus moves a case between the states an agent may choose.
func (s *Service) SetStatus(ctx context.Context, id, status string) (CaseView, error) {
	if status != "in_review" && status != "needs_person" {
		return CaseView{}, invalid("status must be in_review or needs_person")
	}
	if err := s.mutate(ctx, id, func(*sql.Tx, CaseView) (string, error) { return status, nil }); err != nil {
		return CaseView{}, err
	}
	return s.GetCase(ctx, id)
}

// Escalate routes a case to a person (for example a safety-critical request). It cannot reach an approval after that.
func (s *Service) Escalate(ctx context.Context, id, reason string) (CaseView, error) {
	reason, err := core.CleanText("reason", reason, 500, true)
	if err != nil {
		return CaseView{}, err
	}
	err = s.mutate(ctx, id, func(tx *sql.Tx, c CaseView) (string, error) {
		_, err := tx.ExecContext(ctx, `UPDATE service_cases SET diagnosis_cause='needs a person', diagnosis=? WHERE id=?`, reason, id)
		return "needs_person", err
	})
	if err != nil {
		return CaseView{}, err
	}
	return s.GetCase(ctx, id)
}

// WorkOrder is the case's work order. Creating one needs no approval: it is internal and reversible.
type WorkOrder struct {
	ID      string `json:"id"`
	CaseID  string `json:"case_id"`
	Summary string `json:"summary"`
	Status  string `json:"status"`
}

// CreateWorkOrder creates or updates the case's work order.
func (s *Service) CreateWorkOrder(ctx context.Context, id, summary string) (WorkOrder, error) {
	summary, err := core.CleanText("summary", summary, 1000, true)
	if err != nil {
		return WorkOrder{}, err
	}
	err = s.mutate(ctx, id, func(tx *sql.Tx, c CaseView) (string, error) {
		_, err := tx.ExecContext(ctx, `INSERT INTO work_orders(case_id,summary,status,created_at) VALUES(?,?,'open',?)
			ON CONFLICT(case_id) DO UPDATE SET summary=excluded.summary`, id, summary, core.FormatTime(s.clock()))
		return "", err
	})
	if err != nil {
		return WorkOrder{}, err
	}
	var seq int64
	w := WorkOrder{CaseID: id, Summary: summary, Status: "open"}
	if err := s.db.QueryRowContext(ctx, `SELECT seq FROM work_orders WHERE case_id=?`, id).Scan(&seq); err != nil {
		return w, err
	}
	w.ID = core.FormatID("WO", seq)
	return w, nil
}

// DraftPartsOrder stores the order draft and the part, quantity and dealer it asks for. It refuses a superseded
// part, a quantity the dealer does not have, and any order for a machine whose sensor is flapping.
func (s *Service) DraftPartsOrder(ctx context.Context, id, partID string, qty int, fromDealer, body string) (core.OutboxItem, error) {
	if qty < 1 || qty > 20 {
		return core.OutboxItem{}, invalid("qty must be 1 to 20")
	}
	if err := validate(dealerRe, "from_dealer", fromDealer); err != nil {
		return core.OutboxItem{}, err
	}
	var out core.OutboxItem
	err := s.mutate(ctx, id, func(tx *sql.Tx, c CaseView) (string, error) {
		p, err := getPart(ctx, tx, partID)
		if err != nil {
			return "", err
		}
		if p.SupersededBy != "" {
			return "", conflict("this part is superseded; order " + p.SupersededBy + " instead")
		}
		var have int
		err = tx.QueryRowContext(ctx, `SELECT qty FROM stock WHERE dealer_id=? AND part_id=?`, fromDealer, partID).Scan(&have)
		if errors.Is(err, sql.ErrNoRows) {
			return "", notFound("dealer not found")
		}
		if err != nil {
			return "", err
		}
		if have < qty {
			return "", conflict("that dealer does not have the quantity in stock")
		}
		t, err := trendFor(ctx, tx, s.clock(), c.Serial)
		if err != nil {
			return "", err
		}
		if t.Classification == "sensor_flapping" {
			return "", conflict("telematics shows a flapping sensor on this machine, so no parts order is drafted")
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO case_parts(case_id,part_id,qty,from_dealer) VALUES(?,?,?,?)
			ON CONFLICT(case_id) DO UPDATE SET part_id=excluded.part_id, qty=excluded.qty, from_dealer=excluded.from_dealer`, id, partID, qty, fromDealer); err != nil {
			return "", err
		}
		out, err = s.outbox.Draft(ctx, tx, id, "parts_order", body, s.clock())
		return "", err
	})
	return out, err
}

// DraftWarrantyClaim stores the claim draft. The record must say the machine is covered.
func (s *Service) DraftWarrantyClaim(ctx context.Context, id, body string) (core.OutboxItem, error) {
	var out core.OutboxItem
	err := s.mutate(ctx, id, func(tx *sql.Tx, c CaseView) (string, error) {
		w, err := checkWarranty(ctx, tx, s.clock(), c.Serial, c.FaultCode)
		if err != nil {
			return "", err
		}
		if !w.Covered {
			return "", conflict("no claim: " + w.Reason)
		}
		out, err = s.outbox.Draft(ctx, tx, id, "warranty_claim", body, s.clock())
		return "", err
	})
	return out, err
}

// DraftCustomerNotice stores the notice to the customer. It never holds contact data: the customer is a reference.
func (s *Service) DraftCustomerNotice(ctx context.Context, id, body string) (core.OutboxItem, error) {
	var out core.OutboxItem
	err := s.mutate(ctx, id, func(tx *sql.Tx, c CaseView) (string, error) {
		var err error
		out, err = s.outbox.Draft(ctx, tx, id, "customer_notice", body, s.clock())
		return "", err
	})
	return out, err
}

// ProposeSlot holds a free slot at the case's dealer for the case. An earlier held slot of the case is freed. A
// person confirms the slot by approving.
func (s *Service) ProposeSlot(ctx context.Context, id, slotID string) (Slot, error) {
	if err := validate(slotRe, "slot id", slotID); err != nil {
		return Slot{}, err
	}
	var out Slot
	err := s.mutate(ctx, id, func(tx *sql.Tx, c CaseView) (string, error) {
		err := tx.QueryRowContext(ctx, `SELECT id,dealer_id,tech,starts_at,status FROM slots WHERE id=?`, slotID).Scan(&out.ID, &out.DealerID, &out.Tech, &out.StartsAt, &out.Status)
		if errors.Is(err, sql.ErrNoRows) {
			return "", notFound("slot not found")
		}
		if err != nil {
			return "", err
		}
		if out.DealerID != c.DealerID {
			return "", conflict("that slot belongs to another dealer")
		}
		if out.Status != "free" {
			return "", conflict("that slot is not free")
		}
		if _, err := tx.ExecContext(ctx, `UPDATE slots SET status='free', case_id='' WHERE case_id=? AND status='held'`, id); err != nil {
			return "", err
		}
		_, err = tx.ExecContext(ctx, `UPDATE slots SET status='held', case_id=? WHERE id=?`, id, slotID)
		out.Status = "held"
		return "", err
	})
	return out, err
}

// SetTimer adds a deadline timer to a case.
func (s *Service) SetTimer(ctx context.Context, id, name string, due time.Time) (core.Timer, error) {
	if err := validate(caseRe, "case id", id); err != nil {
		return core.Timer{}, err
	}
	if _, err := loadCase(ctx, s.db, id); err != nil {
		return core.Timer{}, err
	}
	return s.timers.Set(ctx, id, name, due)
}

// RequestApproval asks a dealer manager to decide the order (and the claim, when the machine is covered).
func (s *Service) RequestApproval(ctx context.Context, id, kind string) (core.Approval, error) {
	return s.RequestApprovalBy(ctx, id, kind, "agent")
}

// RequestApprovalBy is RequestApproval with the proposer's name. The case is marked pending_approval in the same
// transaction as the proposal.
func (s *Service) RequestApprovalBy(ctx context.Context, id, kind, by string) (core.Approval, error) {
	if err := validate(caseRe, "case id", id); err != nil {
		return core.Approval{}, err
	}
	return s.approvals.Propose(ctx, core.Proposal{Subject: id, Kind: kind, AmountCents: 0, ProposedBy: by})
}

// proposalPayload is exactly what the approver reads and what the hash covers.
type proposalPayload struct {
	CaseID         string   `json:"case_id"`
	Serial         string   `json:"serial"`
	DealerID       string   `json:"dealer_id"`
	FaultCode      string   `json:"fault_code"`
	Kind           string   `json:"kind"`
	Warranty       Warranty `json:"warranty"`
	Diagnosis      string   `json:"diagnosis"`
	DiagnosisCause string   `json:"diagnosis_cause"`
	WorkOrder      string   `json:"work_order"`
	PartID         string   `json:"part_id"`
	Qty            int      `json:"qty"`
	FromDealer     string   `json:"from_dealer"`
	StockAvailable int      `json:"stock_available"`
	Slot           Slot     `json:"slot"`
	Order          string   `json:"order"`
	Claim          string   `json:"claim,omitempty"` // present only when the machine is covered
	Notice         string   `json:"notice"`
	CaseVersion    int64    `json:"case_version"`
}

// Describe validates a proposal and returns the payload the approver is asked to approve.
func (s *Service) Describe(ctx context.Context, tx *sql.Tx, subject, kind string, amount int64) (string, int64, error) {
	c, err := loadCase(ctx, tx, subject)
	if err != nil {
		return "", 0, err
	}
	if c.Status == "resolved" {
		return "", 0, conflict("case is resolved")
	}
	if c.Status == "needs_person" {
		return "", 0, conflict("this case was routed to a person")
	}
	if c.FaultCode != "" {
		f, err := getFaultCode(ctx, tx, c.FaultCode)
		if err != nil {
			return "", 0, err
		}
		if f.SafetyCritical {
			return "", 0, conflict("a safety-critical request goes to a person, not to an approval")
		}
	}
	if amount != 0 {
		return "", 0, invalid("this approval carries no amount")
	}
	if c.DiagnosisCause == "" {
		return "", 0, conflict("a diagnosis is required")
	}
	if c.WorkOrder == "" {
		return "", 0, conflict("a work order is required")
	}
	w, err := checkWarranty(ctx, tx, s.clock(), c.Serial, c.FaultCode)
	if err != nil {
		return "", 0, err
	}
	want := KindOrder
	if w.Covered {
		want = KindOrderWithClaim
	}
	if kind != want {
		return "", 0, conflict("the approval kind must follow the warranty decision: " + want)
	}
	var cp struct {
		part, from string
		qty        int
	}
	err = tx.QueryRowContext(ctx, `SELECT part_id,qty,from_dealer FROM case_parts WHERE case_id=?`, subject).Scan(&cp.part, &cp.qty, &cp.from)
	if errors.Is(err, sql.ErrNoRows) {
		return "", 0, conflict("a parts order is required")
	}
	if err != nil {
		return "", 0, err
	}
	p, err := getPart(ctx, tx, cp.part)
	if err != nil {
		return "", 0, err
	}
	if p.SupersededBy != "" {
		return "", 0, conflict("the ordered part is superseded")
	}
	var have int
	if err := tx.QueryRowContext(ctx, `SELECT qty FROM stock WHERE dealer_id=? AND part_id=?`, cp.from, cp.part).Scan(&have); err != nil {
		return "", 0, err
	}
	if have < cp.qty {
		return "", 0, conflict("the dealer no longer has the quantity in stock")
	}
	order, ok, err := s.outbox.Current(ctx, tx, subject, "parts_order")
	if err != nil {
		return "", 0, err
	}
	if !ok || order.Status != "draft" {
		return "", 0, conflict("a parts order draft is required")
	}
	pl := proposalPayload{CaseID: c.ID, Serial: c.Serial, DealerID: c.DealerID, FaultCode: c.FaultCode, Kind: kind, Warranty: w, Diagnosis: c.Diagnosis,
		DiagnosisCause: c.DiagnosisCause, WorkOrder: c.WorkOrder, PartID: cp.part, Qty: cp.qty, FromDealer: cp.from, StockAvailable: have, Order: order.Body, CaseVersion: c.Version}
	if w.Covered {
		cl, ok, err := s.outbox.Current(ctx, tx, subject, "warranty_claim")
		if err != nil {
			return "", 0, err
		}
		if !ok || cl.Status != "draft" {
			return "", 0, conflict("a warranty claim draft is required")
		}
		pl.Claim = cl.Body
	}
	nt, ok, err := s.outbox.Current(ctx, tx, subject, "customer_notice")
	if err != nil {
		return "", 0, err
	}
	if !ok || nt.Status != "draft" {
		return "", 0, conflict("a customer notice draft is required")
	}
	pl.Notice = nt.Body
	err = tx.QueryRowContext(ctx, `SELECT id,dealer_id,tech,starts_at,status FROM slots WHERE case_id=? AND status='held'`, subject).Scan(&pl.Slot.ID, &pl.Slot.DealerID, &pl.Slot.Tech, &pl.Slot.StartsAt, &pl.Slot.Status)
	if errors.Is(err, sql.ErrNoRows) {
		return "", 0, conflict("a held technician slot is required")
	}
	if err != nil {
		return "", 0, err
	}
	b, err := json.Marshal(pl)
	if err != nil {
		return "", 0, err
	}
	return string(b), c.Version, nil
}

// Proposed marks the case as waiting for approval. It does not change the version.
func (s *Service) Proposed(ctx context.Context, tx *sql.Tx, a core.Approval) error {
	_, err := tx.ExecContext(ctx, `UPDATE service_cases SET status='pending_approval' WHERE id=? AND status<>'resolved'`, a.Subject)
	return err
}

// RoleFor says which role decides each kind.
func (s *Service) RoleFor(kind string) (string, bool) {
	switch kind {
	case KindOrder, KindOrderWithClaim:
		return "dealer-manager", true
	}
	return "", false
}

// Execute runs inside the approval's transaction. It is the only code that takes stock, queues an order, a claim
// or a notice, and confirms a slot. It releases only the kinds the approver was shown.
func (s *Service) Execute(ctx context.Context, tx *sql.Tx, a core.Approval) error {
	var part, from string
	var qty int
	if err := tx.QueryRowContext(ctx, `SELECT part_id,qty,from_dealer FROM case_parts WHERE case_id=?`, a.Subject).Scan(&part, &qty, &from); err != nil {
		return err
	}
	res, err := tx.ExecContext(ctx, `UPDATE stock SET qty=qty-? WHERE dealer_id=? AND part_id=? AND qty>=?`, qty, from, part, qty)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return conflict("the dealer no longer has the quantity in stock")
	}
	kinds := []string{"parts_order", "customer_notice"}
	if a.Kind == KindOrderWithClaim {
		kinds = append(kinds, "warranty_claim")
	}
	if _, err := s.outbox.QueueKinds(ctx, tx, a.Subject, a.ID, kinds, s.clock()); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE slots SET status='confirmed' WHERE case_id=? AND status='held'`, a.Subject); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE work_orders SET status='parts ordered' WHERE case_id=?`, a.Subject); err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `UPDATE service_cases SET status='resolved', version=version+1 WHERE id=?`, a.Subject)
	return err
}

// Reject sends the case back to a person, frees the slot and drops the drafts.
func (s *Service) Reject(ctx context.Context, tx *sql.Tx, a core.Approval) error {
	if err := s.outbox.DiscardDrafts(ctx, tx, a.Subject); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE slots SET status='free', case_id='' WHERE case_id=? AND status='held'`, a.Subject); err != nil {
		return err
	}
	_, err := tx.ExecContext(ctx, `UPDATE service_cases SET status='needs_person', version=version+1 WHERE id=?`, a.Subject)
	return err
}
