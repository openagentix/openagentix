// Package fake is the demo backend (CONSOLE_DEV_FAKE=1): an in-memory stand-in for the cluster that holds the demo data
// of the design mockup. It lets the web app be developed and tested end to end with no cluster. It plays the controller
// in a very small way (see settle) and says so in the YAML it serves; the real controller's rules are not copied here.
package fake

import (
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/openagentix/openagentix/services/console/internal/backend"
	"github.com/openagentix/openagentix/services/console/internal/model"
	"github.com/openagentix/openagentix/services/console/internal/platform"
	"github.com/openagentix/openagentix/services/console/internal/predict"
)

//go:embed testdata/catalog.json
var catalogJSON []byte

//go:embed testdata/policy.json
var policyJSON []byte

// Platform returns the demo catalog and policy (the control plane's own test data).
func Platform() platform.Both {
	var b platform.Both
	if err := json.Unmarshal(catalogJSON, &b.Catalog); err != nil {
		panic(err)
	}
	if err := json.Unmarshal(policyJSON, &b.Policy); err != nil {
		panic(err)
	}
	b.Catalog.Demo = true
	return b
}

type entry struct {
	def     backend.Definition
	pending time.Time // when the fake controller looks at the newest generation; zero: never
	stuck   bool      // stays pending for ever (the demo's release-notes)
}

// Backend is the fake cluster.
type Backend struct {
	Now    func() time.Time
	Settle time.Duration // how long a new or changed definition stays unseen by the fake controller; 0 means for ever

	mu     sync.Mutex
	p      platform.Both
	defs   map[string]*entry
	charts map[string]model.Detail
	rv     int
}

const ns = "kagent"

func cond(t, status, reason, msg string, at time.Time) model.Condition {
	c := model.Condition{Type: t, Status: status, Reason: reason, Message: msg}
	if !at.IsZero() {
		c.LastTransitionTime = at.UTC().Format(time.RFC3339)
	}
	return c
}

// New builds the fake with the demo data of the mockup.
func New(now func() time.Time, settle time.Duration) *Backend {
	if now == nil {
		now = time.Now
	}
	b := &Backend{Now: now, Settle: settle, p: Platform(), defs: map[string]*entry{}, charts: map[string]model.Detail{}}
	t := now()
	b.seedCharts(t)

	mem := &model.Memory{Enabled: true, TTLDays: 15}
	b.put(&entry{def: backend.Definition{
		Meta: b.meta("researcher", t.Add(-26*time.Hour), 3),
		Spec: model.Spec{
			Description: "Looks things up and cites what it found", Model: "claude-haiku",
			Instructions: "You are a careful research assistant for the platform team.\nAnswer questions about open-source dependencies and their known vulnerabilities.\n\nWhen a question names a package and a version, look it up in the vulnerability\ndatabase before you answer. Give the number of known vulnerabilities, name the\nmost severe one by its identifier, and say which fixed version to move to.\n\nCite every source you used by its title or identifier. If a lookup returns\nnothing, say so plainly instead of guessing. Keep answers short and in plain text.\n",
			ToolProfile:  "lookup", Tools: []string{"osv_query_vulnerability", "osv_get_vulnerability", "knowledge_kb_search"},
			Memory: mem, Skills: []model.Skill{{Name: "openagentix-canary"}}, Egress: &model.Egress{Allow: []string{"https://api.osv.dev"}},
		}}})
	b.defs["researcher"].def.Status = b.ready(b.defs["researcher"].def, t.Add(-3*time.Hour))

	b.put(&entry{def: backend.Definition{
		Meta: b.meta("cve-triage", t.Add(-12*time.Minute), 1),
		Spec: model.Spec{
			Description: "Triages new CVEs against our dependency list", Model: "claude-haiku",
			Instructions: "You triage new CVEs for the platform team.\nCompare each CVE with the dependency list you are given and rank by exposure.\nCite the advisory you used.\n",
			ToolProfile:  "lookup", Tools: []string{"osv_query_vulnerability", "knowledge_kb_get_document"}, Knowledge: &model.Feature{Enabled: true},
			Egress: &model.Egress{Allow: []string{"https://api.osv.dev", "https://services.nvd.nist.gov"}},
		}}})
	cve := b.defs["cve-triage"]
	viol := []string{
		`the definition lists tool "knowledge_kb_get_document" which is not in profile "lookup" (the profile offers: knowledge_kb_search, osv_query_vulnerability, osv_get_vulnerability, execute_tool_script)`,
		`egress.allow entry "https://services.nvd.nist.gov" is not matched by the platform policy`,
	}
	cve.def.Status = refused(t.Add(-12*time.Minute), 1, viol)

	b.put(&entry{stuck: true, def: backend.Definition{
		Meta: b.meta("release-notes", t.Add(-40*time.Second), 1),
		Spec: model.Spec{
			Description: "Drafts release notes from merged changes", Model: "claude-haiku",
			Instructions: "Draft release notes from the list of merged changes you are given.\nGroup them by area and keep each line to one sentence.\n",
			ToolProfile:  "lookup", Notify: &model.Feature{Enabled: true},
		}}})
	rn := b.defs["release-notes"]
	rn.def.Status = model.Status{ObservedGeneration: 1, Conditions: []model.Condition{
		cond("Accepted", "True", "Accepted", "", t.Add(-40*time.Second)), cond("KeyReady", "True", "KeyReady", "Secret release-notes-virtual-key", t.Add(-40*time.Second)),
		cond("Applied", "True", "Applied", "5 objects applied; waiting for the runtime", t.Add(-40*time.Second)),
		cond("Ready", "False", "AgentPending", "the runtime reports no Ready condition yet", t.Add(-40*time.Second))},
		EffectiveTools: []string{}, EffectiveEgress: []string{}, Violations: []string{}, Controller: map[string]any{"gatewayUserId": "kagent.release-notes", "toolServer": "toolhive-vmcp-lookup"},
		AgentRef: &model.ObjectRef{APIVersion: "api.kagent.dev/v1alpha3", Kind: "Agent", Name: "release-notes"}}
	return b
}

func (b *Backend) meta(name string, created time.Time, gen int64) backend.Meta {
	b.rv++
	return backend.Meta{Name: name, Namespace: ns, UID: "00000000-demo-" + name, Generation: gen, ResourceVersion: strconv.Itoa(1000 + b.rv),
		CreationTimestamp: created.UTC().Format(time.RFC3339)}
}

func (b *Backend) put(e *entry) { b.defs[e.def.Meta.Name] = e }

func refused(at time.Time, gen int64, viol []string) model.Status {
	return model.Status{ObservedGeneration: gen, Violations: viol, EffectiveTools: []string{}, EffectiveEgress: []string{},
		Conditions: []model.Condition{
			cond("Accepted", "False", "PolicyViolation", strconv.Itoa(len(viol))+" rule(s) refused; see status.violations", at),
			cond("KeyReady", "Unknown", "NotAccepted", "not reached", time.Time{}),
			cond("Applied", "False", "NotAccepted", "the definition is refused; objects of an earlier version, if any, are left as they were", at),
			cond("Ready", "False", "NotAccepted", "", at)}}
}

func (b *Backend) ready(d backend.Definition, at time.Time) model.Status {
	tools := append([]string{}, d.Spec.Tools...)
	if d.Spec.Memory != nil && d.Spec.Memory.Enabled {
		tools = append(tools, "save_memory", "load_memory")
	}
	eg := []string{}
	if d.Spec.Egress != nil {
		eg = append(eg, d.Spec.Egress.Allow...)
	}
	srv := ""
	if p, ok := b.p.Catalog.Profile(d.Spec.ToolProfile); ok {
		srv = p.ToolServer
	}
	sum := sha256.Sum256([]byte(d.Meta.UID))
	secret := d.Meta.Name + "-virtual-key-" + hex.EncodeToString(sum[:])[:8]
	var ep *model.Endpoint
	if b.p.Catalog.GateURL != "" {
		ep = &model.Endpoint{Protocol: "a2a", URL: b.p.Catalog.GateURL + "/agents/" + ns + "/" + d.Meta.Name, ProtocolVersion: "1.0"}
	}
	rev := sha256.Sum256([]byte(d.Spec.Instructions + d.Spec.Model + strings.Join(d.Spec.Tools, ",")))
	return model.Status{ObservedGeneration: d.Meta.Generation, EffectiveTools: tools, EffectiveEgress: eg, Violations: []string{},
		Endpoint: ep, Revision: "sha256:" + hex.EncodeToString(rev[:])[:12],
		Controller: map[string]any{"gatewayUserId": ns + "." + d.Meta.Name, "toolServer": srv, "keySecret": secret},
		AgentRef:   &model.ObjectRef{APIVersion: "api.kagent.dev/v1alpha3", Kind: "Agent", Name: d.Meta.Name},
		Conditions: []model.Condition{cond("Accepted", "True", "Accepted", "", at), cond("KeyReady", "True", "KeyReady", "Secret "+secret, at),
			cond("Applied", "True", "Applied", "", at), cond("Ready", "True", "Ready", "", at)}}
}

func (b *Backend) seedCharts(t time.Time) {
	mk := func(name, desc, prof string, k, n bool, mem *model.Memory, tools []string) {
		a := model.Agent{Name: name, Namespace: ns, Source: "chart", Description: desc, Model: "claude-haiku", ToolProfile: prof, ToolsCount: len(tools),
			Knowledge: k, Notify: n, Memory: mem, Skills: []string{}, EffectiveTools: []string{}, EffectiveEgress: []string{}, State: model.StateReady, Conditions: []model.Condition{cond("Ready", "True", "Ready", "", t.Add(-48*time.Hour))},
			Updated: t.Add(-48 * time.Hour).UTC().Format(time.RFC3339)}
		sp := &model.Spec{Description: desc, Model: "claude-haiku", ToolProfile: prof, Tools: tools, Memory: mem,
			Instructions: "You are a concise, helpful assistant running on a Kubernetes-native agent\nplatform. Answers are read in a chat app, so keep them short and use plain text.\n"}
		if k {
			sp.Knowledge = &model.Feature{Enabled: true}
		}
		if n {
			sp.Notify = &model.Feature{Enabled: true}
		}
		b.charts[name] = model.Detail{Agent: a, ReadOnly: true, Spec: sp, Objects: []model.OwnedObject{}}
	}
	mk("assistant", "General assistant reachable from messaging channels", "", true, true, &model.Memory{Enabled: true, TTLDays: 30},
		append([]string{"execute_tool_script", "fetch_fetch", "osv_get_vulnerability", "osv_query_vulnerability"}, b.p.Catalog.Knowledge.Tools...))
	mk("profile-demo", "Looks up vulnerabilities through the lookup profile", "lookup", false, false, nil, []string{"osv_query_vulnerability", "osv_get_vulnerability"})
}

// settle plays the controller: once the pending time has passed, the newest generation gets a verdict.
func (b *Backend) settle(e *entry) {
	if e.stuck || e.pending.IsZero() || b.Now().Before(e.pending) {
		return
	}
	preds := predict.Check(predict.Input{Name: e.def.Meta.Name, Spec: e.def.Spec, Others: b.othersLocked(e.def.Meta.Name), P: b.p})
	if len(preds) > 0 {
		v := make([]string, len(preds))
		for i, p := range preds {
			v[i] = p.Message
		}
		e.def.Status = refused(b.Now(), e.def.Meta.Generation, v)
	} else {
		e.def.Status = b.ready(e.def, b.Now())
	}
	e.pending = time.Time{}
}

func (b *Backend) othersLocked(name string) int {
	n := 0
	for k := range b.defs {
		if k != name {
			n++
		}
	}
	return n
}

func (b *Backend) newStatus(d backend.Definition) model.Status {
	at := b.Now()
	return model.Status{ObservedGeneration: d.Meta.Generation, EffectiveTools: []string{}, EffectiveEgress: []string{}, Violations: []string{},
		Conditions: []model.Condition{cond("Accepted", "Unknown", "Pending", "waiting for the controller", at), cond("KeyReady", "Unknown", "Pending", "", at),
			cond("Applied", "Unknown", "Pending", "", at), cond("Ready", "Unknown", "Pending", "", at)}}
}

func (b *Backend) pendingTime() time.Time {
	if b.Settle <= 0 {
		return time.Time{}
	}
	return b.Now().Add(b.Settle)
}

func (b *Backend) List(context.Context) (model.AgentList, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	res := model.AgentList{Items: []model.Agent{}, Warnings: []string{}}
	for _, e := range b.defs {
		b.settle(e)
		res.Items = append(res.Items, backend.BuiltAgent(e.def))
		res.Used++
	}
	for _, c := range b.charts {
		res.Items = append(res.Items, c.Agent)
	}
	sort.Slice(res.Items, func(i, j int) bool { return res.Items[i].Name < res.Items[j].Name })
	return res, nil
}

func (b *Backend) Get(_ context.Context, name string) (model.Detail, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if e, ok := b.defs[name]; ok {
		b.settle(e)
		return backend.BuiltDetail(e.def), nil
	}
	if c, ok := b.charts[name]; ok {
		return c, nil
	}
	return model.Detail{}, backend.Errf(http.StatusNotFound, "not_found", "There is no agent named %s in namespace %s.", name, ns)
}

// crd plays the CRD schema and its two name rules.
func crd(name string, s model.Spec) []string {
	var m []string
	if len(name) > model.MaxName {
		m = append(m, "name must be at most 40 characters")
	}
	if !model.NameRE.MatchString(name) {
		m = append(m, "name must be a DNS label: lower case letters, digits and dashes, starting with a letter")
	}
	if len([]rune(s.Description)) > 256 {
		m = append(m, "spec.description: Too long: may not be more than 256")
	}
	if s.Model == "" {
		m = append(m, "spec.model: Required value")
	}
	if s.Instructions == "" {
		m = append(m, "spec.instructions: Required value")
	}
	if len([]rune(s.Instructions)) > 16384 {
		m = append(m, "spec.instructions: Too long: may not be more than 16384")
	}
	return m
}

func (b *Backend) Schema(_ context.Context, name string, s model.Spec) (model.SchemaResult, error) {
	m := crd(name, s)
	return model.SchemaResult{OK: len(m) == 0, Errors: append([]string{}, m...)}, nil
}

func (b *Backend) Create(_ context.Context, name string, s model.Spec) (model.Detail, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if _, ok := b.defs[name]; ok {
		return model.Detail{}, backend.Errf(http.StatusConflict, "exists", "An agent named %s already exists. Pick another name.", name)
	}
	if _, ok := b.charts[name]; ok {
		return model.Detail{}, backend.Errf(http.StatusConflict, "exists", "An agent named %s already exists: it comes from chart values. Pick another name.", name)
	}
	if m := crd(name, s); len(m) > 0 {
		return model.Detail{}, backend.Errf(http.StatusUnprocessableEntity, "invalid", "The Kubernetes API refused %s as invalid: %s", name, m[0])
	}
	e := &entry{def: backend.Definition{Meta: b.meta(name, b.Now(), 1), Spec: s}, pending: b.pendingTime()}
	e.def.Status = b.newStatus(e.def)
	if b.Settle <= 0 {
		e.pending = time.Time{}
		e.stuck = true
	}
	b.put(e)
	return backend.BuiltDetail(e.def), nil
}

func (b *Backend) Update(_ context.Context, name, rv string, s model.Spec) (model.Detail, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	e, ok := b.defs[name]
	if !ok {
		if _, c := b.charts[name]; c {
			return model.Detail{}, backend.Errf(http.StatusForbidden, "read_only", "%s comes from chart values (agents[]). Change it in your values file and run install.sh.", name)
		}
		return model.Detail{}, backend.Errf(http.StatusNotFound, "not_found", "There is no built agent named %s in namespace %s.", name, ns)
	}
	if rv == "" {
		return model.Detail{}, backend.Errf(http.StatusBadRequest, "bad_request", "resourceVersion is required to update %s: send the one you read.", name)
	}
	if rv != e.def.Meta.ResourceVersion {
		return model.Detail{}, backend.Errf(http.StatusConflict, "conflict", "%s was changed by someone else (or by the controller) since you opened it. Reload it, then apply your changes again.", name)
	}
	if m := crd(name, s); len(m) > 0 {
		return model.Detail{}, backend.Errf(http.StatusUnprocessableEntity, "invalid", "The Kubernetes API refused %s as invalid: %s", name, m[0])
	}
	e.def.Spec = s
	e.def.Meta.Generation++
	b.rv++
	e.def.Meta.ResourceVersion = strconv.Itoa(1000 + b.rv)
	e.stuck = false
	e.pending = b.pendingTime()
	if b.Settle <= 0 {
		e.stuck = true // the status keeps describing the older generation, for ever
	}
	return backend.BuiltDetail(e.def), nil
}

func (b *Backend) Delete(_ context.Context, name string) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if _, ok := b.defs[name]; ok {
		delete(b.defs, name)
		return nil
	}
	if _, c := b.charts[name]; c {
		return backend.Errf(http.StatusForbidden, "read_only", "%s comes from chart values (agents[]). Remove it from your values file and run install.sh.", name)
	}
	return backend.Errf(http.StatusNotFound, "not_found", "There is no built agent named %s in namespace %s.", name, ns)
}

// Touch simulates somebody else changing a definition (tests use it to cause a conflict).
func (b *Backend) Touch(name string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if e, ok := b.defs[name]; ok {
		b.rv++
		e.def.Meta.ResourceVersion = strconv.Itoa(1000 + b.rv)
	}
}
