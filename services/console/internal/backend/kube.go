package backend

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"

	"github.com/openagentix/openagentix/services/console/internal/kube"
	"github.com/openagentix/openagentix/services/console/internal/model"
	"github.com/openagentix/openagentix/services/console/internal/platform"
)

// FieldManager is the name the API server records for writes made by the console.
const FieldManager = "openagentix-console"

// Kube reads and writes through the Kubernetes API. The paths it can call are the ones built in this file, all inside
// one namespace: AgentDefinitions (read and write), and the kagent Agent, AgentTemplate, Harness and ModelConfig (read only).
type Kube struct {
	C         *kube.Client
	Namespace string
	KagentAPI string // for example api.kagent.dev/v1alpha3
	Platform  platform.Source
	// PageSize is the limit sent with every list request; Cap is the most objects of one kind a list returns. 0: defaults.
	PageSize, Cap int
	defsPath      string
	kagentPrefix  string
}

func NewKube(c *kube.Client, ns, kagentAPI string, p platform.Source) *Kube {
	return &Kube{C: c, Namespace: ns, KagentAPI: kagentAPI, Platform: p,
		defsPath: "/apis/" + model.Group + "/" + model.Version + "/namespaces/" + url.PathEscape(ns) + "/agentdefinitions"}
}

func (k *Kube) kagent(plural string) string {
	return "/apis/" + k.KagentAPI + "/namespaces/" + url.PathEscape(k.Namespace) + "/" + plural
}

type statusObj struct {
	Message string `json:"message"`
	Reason  string `json:"reason"`
	Details struct {
		Causes []struct {
			Message string `json:"message"`
			Field   string `json:"field"`
			Reason  string `json:"reason"`
		} `json:"causes"`
	} `json:"details"`
}

// Nothing the API server wrote (its message, a cause's message, an admission webhook's or policy's text) is passed on to
// the browser. The error functions below read the status code, the reason and the field paths, and answer with the
// console's own sentences; anything else becomes one generic sentence, and the upstream detail goes to the log only.

var fieldPathRE = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_.\[\]-]{0,119}$`)

// causeSentences maps the reasons of a field cause to the console's own words.
var causeSentences = map[string]string{
	"FieldValueRequired": "is required", "FieldValueInvalid": "has a value that is not valid", "FieldValueForbidden": "is not allowed here",
	"FieldValueTooLong": "is too long", "FieldValueNotSupported": "has a value that is not supported", "FieldValueDuplicate": "is listed twice",
	"FieldValueTooMany": "has too many entries",
}

func parseStatus(r kube.Response) statusObj {
	var st statusObj
	_ = json.Unmarshal(r.Body, &st)
	return st
}

// mentions reports whether the API server's text names an admission webhook or policy (matched, never shown).
func (st statusObj) mentions(markers ...string) bool {
	text := strings.ToLower(st.Message)
	for _, c := range st.Details.Causes {
		text += " " + strings.ToLower(c.Message)
	}
	for _, m := range markers {
		if strings.Contains(text, m) {
			return true
		}
	}
	return false
}

func (st statusObj) fieldProblems() []string {
	var out []string
	seen := map[string]bool{}
	for _, c := range st.Details.Causes {
		if !fieldPathRE.MatchString(c.Field) {
			continue
		}
		sentence, ok := causeSentences[c.Reason]
		if !ok {
			sentence = "is not valid"
		}
		m := c.Field + " " + sentence
		if !seen[m] {
			seen[m] = true
			out = append(out, m)
		}
		if len(out) == 8 {
			break
		}
	}
	return out
}

func shorten(s string, n int) string {
	if len(s) > n {
		return s[:n] + "..."
	}
	return s
}

// unexpected is the one generic answer. The server adds the request id and writes Detail to the log.
func unexpected(what string, r kube.Response, st statusObj) *Error {
	e := Errf(http.StatusBadGateway, "cluster_error", "Could not %s: the Kubernetes API answered %d, which the console does not know how to explain. See the console log.", what, r.Status)
	e.Detail = fmt.Sprintf("upstream status %d reason %q message %q", r.Status, st.Reason, shorten(st.Message, 500))
	return e
}

// refusal maps the answers that mean "the cluster said no" in a known way, for reads and writes alike. nil: not one of them.
func (k *Kube) refusal(what, name string, r kube.Response, st statusObj) *Error {
	if r.Status >= 400 && r.Status < 500 && st.mentions("admission webhook", "validatingadmissionpolicy", "mutatingadmissionpolicy", "denied the request", "admission plugin") {
		return Errf(http.StatusUnprocessableEntity, "admission_denied",
			"A policy in the cluster (an admission webhook or an admission policy) refused %s. Ask a cluster operator which policy applies; its reason is in the cluster's own log, not here.", name)
	}
	if r.Status == http.StatusForbidden && st.mentions("exceeded quota") {
		return Errf(http.StatusUnprocessableEntity, "quota_exceeded",
			"The resource quota of namespace %s is used up, so %s could not be saved. Delete something you no longer need or ask an operator to raise the quota.", k.Namespace, name)
	}
	return nil
}

// fail turns an unexpected API server answer into the sentence the person sees (what happened, why, what to do).
func (k *Kube) fail(what string, r kube.Response) *Error {
	st := parseStatus(r)
	if e := k.refusal(what, "this change", r, st); e != nil {
		return e
	}
	switch r.Status {
	case http.StatusUnauthorized, http.StatusForbidden:
		return Errf(http.StatusBadGateway, "cluster_forbidden",
			"Could not %s: the Kubernetes API returned %d. The console's ServiceAccount may not do this in namespace %s. Ask an operator to bind the openagentix-agent-builder Role.", what, r.Status, k.Namespace)
	case http.StatusNotFound:
		return Errf(http.StatusBadGateway, "cluster_missing",
			"Could not %s: the Kubernetes API returned 404. The AgentDefinition kind may not be installed. Check that controlPlane.enabled is true in chart values.", what)
	case http.StatusInternalServerError, http.StatusBadGateway, http.StatusServiceUnavailable, http.StatusGatewayTimeout:
		e := Errf(http.StatusBadGateway, "cluster_error", "Could not %s: the Kubernetes API returned %d. Check that the API server is healthy and reachable from the console pod.", what, r.Status)
		e.Detail = fmt.Sprintf("upstream status %d reason %q message %q", r.Status, st.Reason, shorten(st.Message, 500))
		return e
	}
	return unexpected(what, r, st)
}

func (k *Kube) call(ctx context.Context, what, method, path string, q url.Values, body []byte) (kube.Response, error) {
	ct := ""
	if body != nil {
		ct = "application/json"
	}
	r, err := k.C.Do(ctx, method, path, q, ct, body)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			return r, Errf(http.StatusGatewayTimeout, "timeout", "Could not %s: the Kubernetes API did not answer in time. Try again.", what)
		}
		if errors.Is(err, context.Canceled) {
			return r, err
		}
		return r, Errf(http.StatusBadGateway, "cluster_unreachable", "Could not %s: the Kubernetes API is not reachable from the console pod. Check the cluster and the network.", what)
	}
	return r, nil
}

type list[T any] struct {
	Items    []T `json:"items"`
	Metadata struct {
		Continue string `json:"continue"`
	} `json:"metadata"`
}

const (
	defaultPageSize = 100
	defaultCap      = 500
)

func (k *Kube) pageSize() int {
	if k.PageSize > 0 {
		return k.PageSize
	}
	return defaultPageSize
}

// MaxItems is the most objects of one kind a list reads.
func (k *Kube) MaxItems() int {
	if k.Cap > 0 {
		return k.Cap
	}
	return defaultCap
}

// listPaged reads a collection a page at a time (limit and continue) up to the cap. truncated is true when there was more.
// Items beyond the cap are dropped even when the API server ignored the limit.
func listPaged[T any](ctx context.Context, k *Kube, what, path string, q url.Values, onErr func(kube.Response) error) ([]T, bool, error) {
	var out []T
	cont := ""
	for pages := 0; pages <= k.MaxItems()/k.pageSize()+2; pages++ {
		qq := url.Values{}
		for key, v := range q {
			qq[key] = v
		}
		qq.Set("limit", strconv.Itoa(k.pageSize()))
		if cont != "" {
			qq.Set("continue", cont)
		}
		r, err := k.call(ctx, what, http.MethodGet, path, qq, nil)
		if err != nil {
			return nil, false, err
		}
		if r.Status != http.StatusOK {
			return nil, false, onErr(r)
		}
		var l list[T]
		if err := json.Unmarshal(r.Body, &l); err != nil {
			return nil, false, Errf(http.StatusBadGateway, "cluster_error", "Could not %s: the Kubernetes API sent something that is not JSON.", what)
		}
		out = append(out, l.Items...)
		if len(out) > k.MaxItems() {
			return out[:k.MaxItems()], true, nil
		}
		if l.Metadata.Continue == "" {
			return out, false, nil
		}
		if len(out) == k.MaxItems() {
			return out, true, nil
		}
		cont = l.Metadata.Continue
	}
	return out, true, nil
}

func (k *Kube) defs(ctx context.Context) ([]Definition, bool, error) {
	return listPaged[Definition](ctx, k, "list agent definitions", k.defsPath, nil, func(r kube.Response) error { return k.fail("list agent definitions", r) })
}

// rawDef reads one definition as the API server holds it. The typed Definition is for the console's views, raw is for a
// save, which must keep every field the console does not know.
func (k *Kube) rawDef(ctx context.Context, name string) (Definition, map[string]any, *Error, error) {
	r, err := k.call(ctx, "read "+name, http.MethodGet, k.defsPath+"/"+url.PathEscape(name), nil, nil)
	if err != nil {
		return Definition{}, nil, nil, err
	}
	switch r.Status {
	case http.StatusOK:
		var d Definition
		var raw map[string]any
		if json.Unmarshal(r.Body, &d) != nil || json.Unmarshal(r.Body, &raw) != nil {
			return d, nil, nil, Errf(http.StatusBadGateway, "cluster_error", "Could not read %s: the Kubernetes API sent something that is not JSON.", name)
		}
		sp, _ := raw["spec"].(map[string]any)
		d.Unmanaged = unmanagedKeys(sp)
		return d, raw, nil, nil
	case http.StatusNotFound:
		return Definition{}, nil, Errf(http.StatusNotFound, "not_found", "There is no built agent named %s in namespace %s.", name, k.Namespace), nil
	}
	return Definition{}, nil, nil, k.fail("read "+name, r)
}

func (k *Kube) def(ctx context.Context, name string) (Definition, *Error, error) {
	d, _, ke, err := k.rawDef(ctx, name)
	return d, ke, err
}

// managedKeys are the spec fields the console edits. Every other key of a stored spec is kept as it is on a save.
var managedKeys = []string{"description", "model", "instructions", "toolProfile", "tools", "knowledge", "notify", "memory", "skills", "egress", "suspend"}

func unmanagedKeys(spec map[string]any) []string {
	out := []string{}
	for k := range spec {
		if !slices.Contains(managedKeys, k) {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

// mergeSpec puts the fields the console manages into the stored spec and leaves every other field alone. A managed field
// the editor left out is removed (that is what clearing it means). When the stored spec takes its prompt from a ConfigMap
// (instructionsFrom) the console neither sends instructions nor lets them be typed: exactly one of the two may exist.
func mergeSpec(stored map[string]any, spec model.Spec) (map[string]any, *Error) {
	b, _ := json.Marshal(spec)
	var mine map[string]any
	_ = json.Unmarshal(b, &mine)
	out := map[string]any{}
	for k, v := range stored {
		out[k] = v
	}
	_, from := stored["instructionsFrom"]
	for _, key := range managedKeys {
		v, ok := mine[key]
		if key == "instructions" && from {
			if s, _ := v.(string); s != "" {
				return nil, Errf(http.StatusUnprocessableEntity, "invalid", "This agent takes its instructions from a ConfigMap (instructionsFrom). The console cannot edit them: change the ConfigMap, or remove instructionsFrom with kubectl first.")
			}
			delete(out, key)
			continue
		}
		if ok {
			out[key] = v
		} else {
			delete(out, key)
		}
	}
	return out, nil
}

// --- chart agents ---

type rawObj struct {
	Metadata Meta            `json:"metadata"`
	Spec     json.RawMessage `json:"spec"`
	Status   struct {
		Conditions []model.Condition `json:"conditions"`
	} `json:"status"`
}

func (k *Kube) chartObjects(ctx context.Context, plural string, selector string) ([]rawObj, bool, error) {
	q := url.Values{}
	if selector != "" {
		q.Set("labelSelector", selector)
	}
	return listPaged[rawObj](ctx, k, "list "+plural, k.kagent(plural), q, func(r kube.Response) error {
		return fmt.Errorf("%s: the Kubernetes API returned %d", plural, r.Status)
	})
}

// charts lists the kagent Agents that carry no openagentix.io/agent-definition label. Reading their template, harness and
// model config is best effort: a refusal becomes a warning and the row has fewer details.
func (k *Kube) charts(ctx context.Context) ([]model.Agent, map[string]*model.Spec, []string, bool, error) {
	agents, truncated, err := k.chartObjects(ctx, "agents", "!"+model.LabelDef)
	if err != nil {
		var ae *Error
		if errors.As(err, &ae) || errors.Is(err, context.Canceled) {
			return nil, nil, nil, false, err
		}
		return nil, nil, []string{"Chart agents could not be listed (" + err.Error() + "). Only built agents are shown. The console's ServiceAccount needs read access to agents.api.kagent.dev."}, false, nil
	}
	var warn []string
	extra := func(plural string) map[string]rawObj {
		m := map[string]rawObj{}
		items, _, err := k.chartObjects(ctx, plural, "")
		if err != nil {
			if errors.Is(err, context.Canceled) {
				return m
			}
			warn = append(warn, "Details of chart agents are partly missing: "+err.Error()+".")
			return m
		}
		for _, o := range items {
			m[o.Metadata.Name] = o
		}
		return m
	}
	templates, harnesses, mcs := extra("agenttemplates"), extra("harnesses"), extra("modelconfigs")

	profiles, knowledge, notify := map[string]string{}, []string(nil), []string(nil)
	if b, err := k.Platform.Get(); err == nil {
		for _, p := range b.Catalog.ToolProfiles() {
			profiles[p.ToolServer] = p.Name
		}
		knowledge, notify = b.Catalog.Knowledge.Tools, b.Catalog.Notify.Tools
	}
	var out []model.Agent
	specs := map[string]*model.Spec{}
	for _, a := range agents {
		c := Chart{Name: a.Metadata.Name, Namespace: a.Metadata.Namespace, Created: a.Metadata.CreationTimestamp, Conditions: a.Status.Conditions}
		var as struct {
			Template struct {
				Ref struct{ Name string } `json:"ref"`
			} `json:"template"`
			HarnessRef struct{ Name string } `json:"harnessRef"`
		}
		_ = json.Unmarshal(a.Spec, &as)
		if t, ok := templates[as.Template.Ref.Name]; ok {
			var ts struct {
				Description  string                `json:"description"`
				SystemPrompt string                `json:"systemPrompt"`
				ModelConfig  struct{ Name string } `json:"modelConfig"`
				Tools        []struct {
					MCP struct {
						Server struct{ Name string } `json:"server"`
						Tools  []string              `json:"tools"`
					} `json:"mcp"`
				} `json:"tools"`
				Skills []struct{ Name string } `json:"skills"`
			}
			_ = json.Unmarshal(t.Spec, &ts)
			c.Description, c.Prompt, c.ModelConfigName = ts.Description, ts.SystemPrompt, ts.ModelConfig.Name
			for _, tl := range ts.Tools {
				c.ToolServer = tl.MCP.Server.Name
				c.Tools = append(c.Tools, tl.MCP.Tools...)
			}
			for _, s := range ts.Skills {
				c.Skills = append(c.Skills, s.Name)
			}
		}
		if mc, ok := mcs[c.ModelConfigName]; ok {
			var ms struct{ Model string }
			_ = json.Unmarshal(mc.Spec, &ms)
			c.Model = ms.Model
		}
		if h, ok := harnesses[as.HarnessRef.Name]; ok {
			var hs struct {
				Kagent struct {
					Memory *struct {
						TTLDays int `json:"ttlDays"`
					} `json:"memory"`
				} `json:"kagent"`
			}
			_ = json.Unmarshal(h.Spec, &hs)
			if hs.Kagent.Memory != nil {
				c.HasMemory, c.MemoryTTL = true, hs.Kagent.Memory.TTLDays
			}
		}
		row, spec := ChartAgent(c, profiles, knowledge, notify)
		out = append(out, row)
		specs[row.Name] = spec
	}
	return out, specs, warn, truncated, nil
}

// --- Backend ---

func (k *Kube) List(ctx context.Context) (model.AgentList, error) {
	defs, cut, err := k.defs(ctx)
	if err != nil {
		return model.AgentList{}, err
	}
	res := model.AgentList{Items: []model.Agent{}, Warnings: []string{}, Truncated: cut, Cap: k.MaxItems()}
	for _, d := range defs {
		res.Items = append(res.Items, BuiltAgent(d))
		res.Used++
	}
	chart, _, warn, cutCharts, err := k.charts(ctx)
	if err != nil {
		return model.AgentList{}, err
	}
	res.Truncated = res.Truncated || cutCharts
	res.Items = append(res.Items, chart...)
	res.Warnings = append(res.Warnings, warn...)
	sort.Slice(res.Items, func(i, j int) bool { return res.Items[i].Name < res.Items[j].Name })
	return res, nil
}

func (k *Kube) Get(ctx context.Context, name string) (model.Detail, error) {
	d, ke, err := k.def(ctx, name)
	if err != nil {
		return model.Detail{}, err
	}
	if ke == nil {
		return BuiltDetail(d), nil
	}
	chart, specs, _, _, err := k.charts(ctx)
	if err != nil {
		return model.Detail{}, err
	}
	for _, a := range chart {
		if a.Name == name {
			return model.Detail{Agent: a, ReadOnly: true, Spec: specs[name], Objects: []model.OwnedObject{}}, nil
		}
	}
	return model.Detail{}, Errf(http.StatusNotFound, "not_found", "There is no agent named %s in namespace %s.", name, k.Namespace)
}

func (k *Kube) object(name string, spec model.Spec, rv string) ([]byte, error) {
	meta := map[string]any{"name": name, "namespace": k.Namespace}
	if rv != "" {
		meta["resourceVersion"] = rv
	}
	return json.Marshal(map[string]any{"apiVersion": model.APIVersion, "kind": model.Kind, "metadata": meta, "spec": spec})
}

// writeErr maps the API server's answer to a write.
func (k *Kube) writeErr(what, name string, r kube.Response) *Error {
	st := parseStatus(r)
	if e := k.refusal(what, name, r, st); e != nil {
		return e
	}
	switch r.Status {
	case http.StatusConflict:
		if st.Reason == "AlreadyExists" {
			return Errf(http.StatusConflict, "exists", "An agent named %s already exists. Pick another name.", name)
		}
		return Errf(http.StatusConflict, "conflict", "%s was changed by someone else (or by the controller) since you opened it. Reload it, then apply your changes again.", name)
	case http.StatusNotFound:
		return Errf(http.StatusNotFound, "not_found", "There is no built agent named %s in namespace %s.", name, k.Namespace)
	case http.StatusUnprocessableEntity, http.StatusBadRequest:
		if p := st.fieldProblems(); len(p) > 0 {
			return Errf(http.StatusUnprocessableEntity, "invalid", "The Kubernetes API refused %s as invalid: %s.", name, strings.Join(p, "; "))
		}
		e := Errf(http.StatusUnprocessableEntity, "invalid", "The Kubernetes API refused %s as invalid, and named no field the console can show. Check the values you entered against the form's limits.", name)
		e.Detail = fmt.Sprintf("upstream status %d reason %q message %q", r.Status, st.Reason, shorten(st.Message, 500))
		return e
	}
	return k.fail(what, r)
}

func (k *Kube) takenByChart(ctx context.Context, name string) (bool, error) {
	chart, _, _, _, err := k.charts(ctx)
	if err != nil {
		return false, err
	}
	for _, a := range chart {
		if a.Name == name {
			return true, nil
		}
	}
	return false, nil
}

func (k *Kube) Create(ctx context.Context, name string, spec model.Spec) (model.Detail, error) {
	if taken, err := k.takenByChart(ctx, name); err != nil {
		return model.Detail{}, err
	} else if taken {
		return model.Detail{}, Errf(http.StatusConflict, "exists", "An agent named %s already exists: it comes from chart values. Pick another name.", name)
	}
	body, _ := k.object(name, spec, "")
	r, err := k.call(ctx, "create "+name, http.MethodPost, k.defsPath, url.Values{"fieldManager": {FieldManager}}, body)
	if err != nil {
		return model.Detail{}, err
	}
	if r.Status != http.StatusCreated && r.Status != http.StatusOK {
		return model.Detail{}, k.writeErr("create "+name, name, r)
	}
	var d Definition
	_ = json.Unmarshal(r.Body, &d)
	return BuiltDetail(d), nil
}

func (k *Kube) Update(ctx context.Context, name, rv string, spec model.Spec) (model.Detail, error) {
	cur, full, ke, err := k.rawDef(ctx, name)
	if err != nil {
		return model.Detail{}, err
	}
	if ke != nil {
		if taken, err := k.takenByChart(ctx, name); err == nil && taken {
			return model.Detail{}, Errf(http.StatusForbidden, "read_only", "%s comes from chart values (agents[]). Change it in your values file and run install.sh.", name)
		}
		return model.Detail{}, ke
	}
	if rv == "" {
		return model.Detail{}, Errf(http.StatusBadRequest, "bad_request", "resourceVersion is required to update %s: send the one you read.", name)
	}
	if rv != cur.Meta.ResourceVersion {
		return model.Detail{}, Errf(http.StatusConflict, "conflict", "%s was changed by someone else (or by the controller) since you opened it. Reload it, then apply your changes again.", name)
	}
	// Send back the object that was read, with only the managed fields of spec replaced: a PUT built from scratch would drop
	// the finalizer, other metadata the controller keeps, and every spec field this console does not know.
	stored, _ := full["spec"].(map[string]any)
	merged, me := mergeSpec(stored, spec)
	if me != nil {
		return model.Detail{}, me
	}
	full["spec"] = merged
	delete(full, "status")
	if m, ok := full["metadata"].(map[string]any); ok {
		m["resourceVersion"] = rv
		delete(m, "managedFields")
	}
	body, _ := json.Marshal(full)
	r, err := k.call(ctx, "save "+name, http.MethodPut, k.defsPath+"/"+url.PathEscape(name), url.Values{"fieldManager": {FieldManager}}, body)
	if err != nil {
		return model.Detail{}, err
	}
	if r.Status != http.StatusOK {
		return model.Detail{}, k.writeErr("save "+name, name, r)
	}
	var d Definition
	_ = json.Unmarshal(r.Body, &d)
	var raw struct{ Spec map[string]any }
	_ = json.Unmarshal(r.Body, &raw)
	d.Unmanaged = unmanagedKeys(raw.Spec)
	return BuiltDetail(d), nil
}

func (k *Kube) Delete(ctx context.Context, name string) error {
	_, ke, err := k.def(ctx, name)
	if err != nil {
		return err
	}
	if ke != nil {
		if taken, err := k.takenByChart(ctx, name); err == nil && taken {
			return Errf(http.StatusForbidden, "read_only", "%s comes from chart values (agents[]). Remove it from your values file and run install.sh.", name)
		}
		return ke
	}
	r, err := k.call(ctx, "delete "+name, http.MethodDelete, k.defsPath+"/"+url.PathEscape(name), nil, nil)
	if err != nil {
		return err
	}
	if r.Status != http.StatusOK && r.Status != http.StatusAccepted && r.Status != http.StatusNoContent {
		return k.writeErr("delete "+name, name, r)
	}
	return nil
}

func (k *Kube) Schema(ctx context.Context, name string, spec model.Spec) (model.SchemaResult, error) {
	cur, full, ke, err := k.rawDef(ctx, name)
	if err != nil {
		return model.SchemaResult{}, err
	}
	q := url.Values{"dryRun": {"All"}, "fieldManager": {FieldManager}}
	var r kube.Response
	if ke == nil {
		// the dry run of a save carries the stored object with the managed fields replaced, as the save itself would
		stored, _ := full["spec"].(map[string]any)
		merged, me := mergeSpec(stored, spec)
		if me != nil {
			return model.SchemaResult{OK: false, Errors: []string{me.Message}}, nil
		}
		full["spec"] = merged
		delete(full, "status")
		if m, ok := full["metadata"].(map[string]any); ok {
			m["resourceVersion"] = cur.Meta.ResourceVersion
			delete(m, "managedFields")
		}
		body, _ := json.Marshal(full)
		r, err = k.call(ctx, "check "+name, http.MethodPut, k.defsPath+"/"+url.PathEscape(name), q, body)
	} else {
		body, _ := k.object(name, spec, "")
		r, err = k.call(ctx, "check "+name, http.MethodPost, k.defsPath, q, body)
	}
	if err != nil {
		return model.SchemaResult{}, err
	}
	switch r.Status {
	case http.StatusOK, http.StatusCreated, http.StatusAccepted:
		return model.SchemaResult{OK: true, Errors: []string{}}, nil
	case http.StatusUnprocessableEntity, http.StatusBadRequest:
		msgs := parseStatus(r).fieldProblems()
		if len(msgs) == 0 {
			msgs = []string{k.writeErr("check "+name, name, r).Message}
		}
		return model.SchemaResult{OK: false, Errors: msgs}, nil
	}
	return model.SchemaResult{}, k.writeErr("check "+name, name, r)
}
