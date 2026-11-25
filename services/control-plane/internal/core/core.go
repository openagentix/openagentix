// Package core is the level-triggered reconcile loop. It validates a definition against the catalog and the policy, mints
// and registers the agent's gateway key, asks the Runtime adapter for the objects, writes them, prunes what is no longer
// wanted and reports conditions. It knows the adapters only through the small interfaces below and never imports an
// adapter package (a test enforces it).
package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"reflect"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/openagentix/openagentix/services/control-plane/internal/api"
	"github.com/openagentix/openagentix/services/control-plane/internal/catalog"
	"github.com/openagentix/openagentix/services/control-plane/internal/keys"
	"github.com/openagentix/openagentix/services/control-plane/internal/kube"
	"github.com/openagentix/openagentix/services/control-plane/internal/plan"
	"github.com/openagentix/openagentix/services/control-plane/internal/policy"
)

// Runtime turns a plan into the objects of an agent runtime and reports on them.
type Runtime interface {
	Name() string
	// OwnedKinds lists the endpoints the core lists by label to prune what is no longer wanted.
	OwnedKinds() []kube.Resource
	// KeyDataKey is the data key under which the key Secret holds the key (the runtime reads it from there).
	KeyDataKey() string
	// Desired returns the objects of a plan. A suspended plan omits what makes the agent take work (it has no suspend
	// switch of its own to set, see the adapter).
	Desired(p plan.Plan) ([]kube.Manifest, error)
	Ref(p plan.Plan) api.ObjectRef
	// Endpoint says where the agent is callable; nil when the platform advertises no route.
	Endpoint(p plan.Plan) *api.Endpoint
	// Readiness reports on the running agent with one of the documented Ready reasons (api.ReasonsFor).
	Readiness(ctx context.Context, p plan.Plan) (plan.Readiness, error)
	// Capabilities is what the runtime can do; "unknown" where the adapter could not verify.
	Capabilities() api.Capabilities
}

// ModelGateway registers the hash of an agent's key under a gateway user.
type ModelGateway interface {
	Name() string
	keys.Registry
	// Entries returns what is registered for every user (an empty hash for an entry that is present but unusable).
	Entries(ctx context.Context) (map[string]keys.Entry, error)
	Unregister(ctx context.Context, user string) error
}

// Kube is the part of the REST client the core uses.
type Kube interface {
	Get(ctx context.Context, r kube.Resource, ns, name string) (kube.Object, error)
	List(ctx context.Context, r kube.Resource, ns, selector string) ([]kube.Object, string, error)
	Watch(ctx context.Context, r kube.Resource, ns, rv string) (*kube.Stream, error)
	Apply(ctx context.Context, r kube.Resource, ns, name string, obj kube.Object) error
	PatchMerge(ctx context.Context, r kube.Resource, ns, name, sub string, patch kube.Object) error
	Update(ctx context.Context, r kube.Resource, ns, name string, obj kube.Object) (kube.Object, error)
	Delete(ctx context.Context, r kube.Resource, ns, name string) error
}

var definitions = kube.Resource{Group: api.Group, Version: api.Version, Plural: api.Plural, Kind: api.Kind, Namespaced: true}

// Definitions is the endpoint of AgentDefinition, for callers that build a client.
func Definitions() kube.Resource { return definitions }

// The CRD's limits on status text (crd/agentdefinition.yaml).
const (
	maxReasonRunes  = 64
	maxMessageRunes = 1024
)

type Config struct {
	Namespace string // the namespace listed and watched; every rule and every object name is scoped to the definition's own
	Catalog   *catalog.Catalog
	Policy    *catalog.Policy
	Kube      Kube
	Secrets   keys.Secrets
	Runtime   Runtime
	Gateway   ModelGateway
	Tools     catalog.ToolResolver
	Log       *slog.Logger
	Now       func() time.Time
	Mint      func() (string, error)
	Resync    time.Duration // full pass at least this often (60 s)
	Backoff   time.Duration // first retry delay of a definition that failed or is not ready; doubles per failure up to 30 times this
	// MinInterval is the shortest time between the starts of two passes of Run (1 s), however many events arrive.
	MinInterval time.Duration
	// MinRecreateInterval is the shortest time between two creations of one definition's runtime agent (2 minutes): a suspend
	// and resume loop must not thrash the runtime's snapshots. A resume inside the interval waits (Ready=False, ResumeDelayed).
	MinRecreateInterval time.Duration
	// WatchOpenTimeout bounds opening the watch (30 s); the resync timer runs independently of it.
	WatchOpenTimeout time.Duration
}

type Controller struct {
	cfg  Config
	mu   sync.Mutex // one reconcile at a time; also guards ps
	ps   *passState
	smu  sync.Mutex // guards seen, seenLabels, last and fails
	seen map[string]int64
	// seenLabels is the team and project label of each definition at the last pass: a change of either starts a pass too
	// (they reach the gateway entry and the objects, but they do not change the generation)
	seenLabels map[string]string
	last       map[string]string
	fails      map[string]*failure
	ready      atomic.Bool
}

// failure is the retry state of one definition.
type failure struct {
	gen  int64
	n    int
	next time.Time
}

// passState is what one pass reads once: the gateway's key entries.
type passState struct {
	loaded  bool
	entries map[string]keys.Entry
	err     error
}

// New builds a controller; zero Config fields get defaults.
func New(cfg Config) *Controller {
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.Mint == nil {
		cfg.Mint = keys.Mint
	}
	if cfg.Resync <= 0 {
		cfg.Resync = 60 * time.Second
	}
	if cfg.Backoff <= 0 {
		cfg.Backoff = 10 * time.Second
	}
	if cfg.MinInterval <= 0 {
		cfg.MinInterval = time.Second
	}
	if cfg.MinRecreateInterval <= 0 {
		cfg.MinRecreateInterval = 2 * time.Minute
	}
	if cfg.WatchOpenTimeout <= 0 {
		cfg.WatchOpenTimeout = 30 * time.Second
	}
	if cfg.Log == nil {
		cfg.Log = slog.New(slog.NewJSONHandler(discard{}, nil))
	}
	return &Controller{cfg: cfg, seen: map[string]int64{}, seenLabels: map[string]string{}, last: map[string]string{}, fails: map[string]*failure{}}
}

type discard struct{}

func (discard) Write(p []byte) (int, error) { return len(p), nil }

// Ready reports whether the first full pass succeeded.
func (c *Controller) Ready() bool { return c.ready.Load() }

// ---- loop ----

// Run lists, reconciles, then watches; any change to a definition's spec, a new or a deleted definition, a 410 Gone, an
// error or the resync timer starts the next pass. Passes start at least MinInterval apart. It returns when ctx is done.
func (c *Controller) Run(ctx context.Context) error {
	var lastStart time.Time
	for ctx.Err() == nil {
		if !lastStart.IsZero() {
			if wait := c.cfg.MinInterval - time.Since(lastStart); wait > 0 {
				sleep(ctx, wait)
				continue
			}
		}
		lastStart = time.Now()
		rv, err := c.reconcile(ctx, true)
		if rv == "" {
			c.cfg.Log.Error("list failed", "outcome", "list_failed", "err", err)
			sleep(ctx, c.cfg.Backoff)
			continue
		}
		if err != nil {
			c.cfg.Log.Error("pass finished with errors", "outcome", "retry", "err", err)
		}
		c.ready.Store(true)
		wait := c.cfg.Resync
		if at, ok := c.nextRetry(); ok {
			wait = min(wait, max(time.Until(at), 0))
		}
		c.watch(ctx, rv, wait)
	}
	return ctx.Err()
}

func sleep(ctx context.Context, d time.Duration) {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
	case <-t.C:
	}
}

// watch waits for something worth a new pass. The resync timer and the open deadline both run while the watch is being
// opened, so a hung open ends in a new pass.
func (c *Controller) watch(ctx context.Context, rv string, wait time.Duration) {
	wctx, cancel := context.WithCancel(ctx)
	defer cancel()
	started := time.Now()
	timer := time.NewTimer(wait)
	defer timer.Stop()
	openTimer := time.NewTimer(c.cfg.WatchOpenTimeout)
	defer openTimer.Stop()

	type opened struct {
		st  *kube.Stream
		err error
	}
	oc := make(chan opened) // unbuffered: an open that finishes after we left closes its own stream
	go func() {
		st, err := c.cfg.Kube.Watch(wctx, definitions, c.cfg.Namespace, rv)
		select {
		case oc <- opened{st, err}:
		case <-wctx.Done():
			if st != nil {
				st.Close()
			}
		}
	}()
	var st *kube.Stream
	select {
	case <-ctx.Done():
		return
	case <-timer.C:
		return
	case <-openTimer.C:
		c.cfg.Log.Warn("watch open timed out", "outcome", "watch_failed")
		return
	case o := <-oc:
		if o.err != nil {
			if !errors.Is(o.err, kube.ErrGone) {
				c.cfg.Log.Warn("watch failed", "outcome", "watch_failed", "err", o.err)
				sleep(ctx, c.cfg.Backoff)
			}
			return
		}
		st = o.st
	}
	defer st.Close()
	evs := make(chan kube.Event)
	errc := make(chan error, 1)
	go func() {
		for {
			e, err := st.Next()
			if err != nil {
				errc <- err
				return
			}
			select {
			case evs <- e:
			case <-wctx.Done():
				return
			}
		}
	}()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			return
		case e := <-evs:
			if c.relevant(e) {
				return
			}
		case err := <-errc:
			if ctx.Err() == nil && !errors.Is(err, kube.ErrGone) {
				c.cfg.Log.Debug("watch ended", "err", err)
			}
			if time.Since(started) < c.cfg.Backoff {
				sleep(ctx, c.cfg.Backoff)
			}
			return
		}
	}
}

// relevant filters out the events of the controller's own writes (status, finalizer): only a new definition, a changed
// spec (generation), a changed team or project label or a requested deletion starts a pass.
func (c *Controller) relevant(e kube.Event) bool {
	if e.Type != "ADDED" && e.Type != "MODIFIED" {
		return false
	}
	m := kube.Meta(e.Object)
	if m.String("deletionTimestamp") != "" {
		return true
	}
	g, _ := m["generation"].(float64)
	c.smu.Lock()
	defer c.smu.Unlock()
	k := defKey(m.String("namespace"), m.String("name"))
	old, ok := c.seen[k]
	return !ok || old != int64(g) || c.seenLabels[k] != labelsKey(m)
}

// labelsKey is the team and project label of an object's metadata as one string, "" when it has neither.
func labelsKey(meta kube.Object) string {
	l, _ := meta["labels"].(map[string]any)
	team, _ := l[api.LabelTeam].(string)
	project, _ := l[api.LabelProject].(string)
	if team == "" && project == "" {
		return ""
	}
	return team + "\x00" + project
}

// defKey identifies a definition in the controller's own maps: names are only unique within a namespace.
func defKey(ns, name string) string { return ns + "/" + name }

// ---- per-definition retry ----

const maxBackoffFactor = 30

// noteFailure records a failed or unfinished definition. exponential: errors double the delay per failure up to
// maxBackoffFactor times the base; an unfinished rollout (not ready yet) retries at the base interval.
func (c *Controller) noteFailure(name string, gen int64, exponential bool) {
	c.smu.Lock()
	defer c.smu.Unlock()
	f := c.fails[name]
	if f == nil || f.gen != gen {
		f = &failure{gen: gen}
		c.fails[name] = f
	}
	f.n++
	d := c.cfg.Backoff
	if exponential {
		for i := 1; i < f.n && d < maxBackoffFactor*c.cfg.Backoff; i++ {
			d *= 2
		}
		d = min(d, maxBackoffFactor*c.cfg.Backoff)
	}
	f.next = time.Now().Add(d)
}

func (c *Controller) clearFailure(name string) {
	c.smu.Lock()
	delete(c.fails, name)
	c.smu.Unlock()
}

// backingOff reports whether the definition failed at this generation and its next attempt is not due.
func (c *Controller) backingOff(name string, gen int64) bool {
	c.smu.Lock()
	defer c.smu.Unlock()
	f := c.fails[name]
	return f != nil && f.gen == gen && time.Now().Before(f.next)
}

func (c *Controller) nextRetry() (time.Time, bool) {
	c.smu.Lock()
	defer c.smu.Unlock()
	var at time.Time
	for _, f := range c.fails {
		if at.IsZero() || f.next.Before(at) {
			at = f.next
		}
	}
	return at, !at.IsZero()
}

func (c *Controller) forget(name string) {
	c.smu.Lock()
	delete(c.last, name)
	delete(c.fails, name)
	delete(c.seen, name)
	delete(c.seenLabels, name)
	c.smu.Unlock()
}

// ---- one pass ----

// ReconcileAll lists the definitions and reconciles each, one at a time, without the per-definition backoff of Run. It
// returns an error only for failures that are not already reported in a definition's status (for example a finalizer
// that could not be removed).
func (c *Controller) ReconcileAll(ctx context.Context) error {
	_, err := c.reconcile(ctx, false)
	return err
}

type item struct {
	d           *api.AgentDefinition
	raw         kube.Object
	wasAccepted bool
	// running: objects of this definition exist (an applied spec is on record, or Applied is True). It holds a place under
	// maxAgents even when its latest edit is refused and only the previous generation runs.
	running bool
}

// runs reports whether the last status says objects of this definition run.
func runs(st api.Status) bool {
	return st.Controller.AppliedSpec != "" || st.Condition(api.CondApplied).Status == "True"
}

func (c *Controller) reconcile(ctx context.Context, honourBackoff bool) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.ps = &passState{}
	defer func() { c.ps = nil }()
	raws, rv, err := c.cfg.Kube.List(ctx, definitions, c.cfg.Namespace, "")
	if err != nil {
		return "", err
	}
	live := map[string]bool{}  // by defKey
	users := map[string]bool{} // gateway user ids of every listed definition
	seen := map[string]int64{}
	seenLabels := map[string]string{}
	var items []item
	for _, raw := range raws {
		name, ns := kube.Meta(raw).String("name"), kube.Meta(raw).String("namespace")
		live[defKey(ns, name)] = true
		users[plan.GatewayUser(ns, name)] = true
		g, _ := kube.Meta(raw)["generation"].(float64)
		seen[defKey(ns, name)] = int64(g)
		seenLabels[defKey(ns, name)] = labelsKey(kube.Meta(raw))
		d, err := api.FromObject(raw)
		if err != nil {
			c.cfg.Log.Warn("skipping an object that is not a valid AgentDefinition", "outcome", "undecodable", "agent", name, "err", err)
			continue
		}
		items = append(items, item{d: d, raw: raw, wasAccepted: d.Status.Condition(api.CondAccepted).Status == "True", running: runs(d.Status)})
	}
	// Order: definitions that run come first (a definition whose edit is refused but whose previous generation runs still holds
	// its place), then those that are accepted now, so a definition that is fixed later or created later never displaces one
	// that already holds a place under maxAgents; then oldest first, by name for equal times.
	slices.SortStableFunc(items, func(a, b item) int {
		if a.running != b.running {
			if a.running {
				return -1
			}
			return 1
		}
		if a.wasAccepted != b.wasAccepted {
			if a.wasAccepted {
				return -1
			}
			return 1
		}
		if x := strings.Compare(a.d.Metadata.CreationTimestamp, b.d.Metadata.CreationTimestamp); x != 0 {
			return x
		}
		if x := strings.Compare(a.d.Metadata.Namespace, b.d.Metadata.Namespace); x != 0 {
			return x
		}
		return strings.Compare(a.d.Metadata.Name, b.d.Metadata.Name)
	})
	c.smu.Lock()
	c.seen, c.seenLabels = seen, seenLabels
	for n := range c.last {
		if !live[n] {
			delete(c.last, n)
		}
	}
	for n := range c.fails {
		if !live[n] {
			delete(c.fails, n)
		}
	}
	c.smu.Unlock()

	var errs []error
	// the definitions that hold a place so far in this pass (accepted, or refused with the previous generation still running),
	// by namespace: they count against maxAgents, which is per namespace
	earlier := map[string][]string{}
	for _, it := range items {
		d := it.d
		ns, key := d.Metadata.Namespace, defKey(d.Metadata.Namespace, d.Metadata.Name)
		if honourBackoff && c.backingOff(key, d.Metadata.Generation) {
			if (it.wasAccepted || it.running) && !d.Deleting() {
				earlier[ns] = append(earlier[ns], d.Metadata.Name)
			}
			continue
		}
		holds, err := c.safeOne(ctx, it.raw, d, earlier[ns])
		if err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", key, err))
			c.noteFailure(key, d.Metadata.Generation, true)
		}
		if holds {
			earlier[ns] = append(earlier[ns], d.Metadata.Name)
		}
	}
	if err := c.sweep(ctx, users); err != nil {
		c.cfg.Log.Warn("gateway sweep failed", "outcome", "sweep_failed", "err", err)
	}
	return rv, errors.Join(errs...)
}

// safeOne keeps a panic in one definition's reconcile from stopping the others.
func (c *Controller) safeOne(ctx context.Context, raw kube.Object, d *api.AgentDefinition, earlier []string) (holds bool, err error) {
	defer func() {
		if r := recover(); r != nil {
			holds, err = false, fmt.Errorf("internal error: %v", r)
			c.cfg.Log.Error("reconcile panicked", "agent", d.Metadata.Name, "outcome", "panic", "err", fmt.Sprint(r))
		}
	}()
	return c.one(ctx, raw, d, earlier)
}

// gatewayEntries reads the gateway's key entries once per pass.
func (c *Controller) gatewayEntries(ctx context.Context) (map[string]keys.Entry, error) {
	if !c.ps.loaded {
		c.ps.entries, c.ps.err = c.cfg.Gateway.Entries(ctx)
		c.ps.loaded = true
	}
	return c.ps.entries, c.ps.err
}

// sweep removes the entries of the key ConfigMap that belong to no listed definition. live holds the gateway user id
// (<namespace>.<name>) of every definition the list returned (decodable or not, deleting or not), so a definition created
// in this pass is never swept; the list was complete, or reconcile would have returned before. An entry of the previous
// format (the plain name, no dot) is nobody's user and goes too. An entry with another namespace's prefix belongs to a
// controller of that namespace and is left alone: there is ONE controller per gateway key ConfigMap (README), and the sweep
// only ever removes what this controller could have written.
func (c *Controller) sweep(ctx context.Context, live map[string]bool) error {
	entries, err := c.gatewayEntries(ctx)
	if err != nil {
		return err
	}
	var errs []error
	own := c.cfg.Namespace + "."
	for user := range entries {
		if live[user] {
			continue
		}
		if strings.Contains(user, ".") && !strings.HasPrefix(user, own) {
			continue // another namespace's entry
		}
		if err := c.cfg.Gateway.Unregister(ctx, user); err != nil {
			errs = append(errs, err)
			continue
		}
		delete(entries, user)
		c.cfg.Log.Info("removed an orphaned key entry", "agent", user, "outcome", "swept")
	}
	return errors.Join(errs...)
}

func selector(name string) string {
	return api.LabelDefinition + "=" + name + "," + api.LabelManagedBy + "=" + api.ManagedByValue
}

func (c *Controller) logOutcome(ns, name, outcome string, kv ...any) {
	c.smu.Lock()
	changed := c.last[defKey(ns, name)] != outcome
	c.last[defKey(ns, name)] = outcome
	c.smu.Unlock()
	lvl := slog.LevelDebug
	if changed {
		lvl = slog.LevelInfo
	}
	c.cfg.Log.Log(context.Background(), lvl, "reconciled", append([]any{"agent", name, "namespace", ns, "outcome", outcome}, kv...)...)
}

// clip cuts s to n characters on a character boundary and drops invalid UTF-8.
func clip(s string, n int) string {
	s = strings.ToValidUTF8(s, "")
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
}

func specJSON(s api.Spec) string {
	b, _ := json.Marshal(s)
	return string(b)
}

// retry says how a pass ends.
type retry int

const (
	retryNone retry = iota // done: nothing to retry (ready, refused, name conflict until the spec changes)
	retryFlat              // unfinished, not failed (the runtime is not ready yet): base interval
	retryExp               // failed: exponential
)

// attempt is the state of one definition's pass.
type attempt struct {
	c       *Controller
	ctx     context.Context
	d       *api.AgentDefinition
	name    string
	ns      string
	key     string // defKey(ns, name)
	user    string // the gateway user id, <namespace>.<name>
	gen     int64
	now     string
	st      api.Status
	running bool // the last status says objects of this definition run
	// keptPrevious: the definition is refused and its previous generation keeps running (it holds a place under maxAgents)
	keptPrevious bool
	// delayedUntil is set when a resume falls inside MinRecreateInterval: the plan is then treated as suspended
	delayedUntil time.Time
	// starting: this pass creates the runtime agent (it was absent), recorded in status.controller.agentStartedAt
	starting bool
}

// recreateDelay says whether creating the runtime agent now would come too soon after its last creation: only when the agent is
// absent (a suspended or delayed definition), was created before (agentStartedAt) and the interval has not passed.
func (a *attempt) recreateDelay() (time.Time, bool) {
	started, err := time.Parse(time.RFC3339, a.st.Controller.AgentStartedAt)
	if err != nil || a.st.AgentRef != nil {
		return time.Time{}, false
	}
	until := started.Add(a.c.cfg.MinRecreateInterval)
	return until, a.c.cfg.Now().Before(until)
}

// setGen sets a condition. Every reason the code passes here is a literal of the documented table (api.reasons), checked by
// a test that reads this file; a reason that comes from outside goes through setReadyFromRuntime.
func (a *attempt) setGen(t, status, reason, msg string, g int64) {
	a.st.SetCondition(api.Condition{Type: t, Status: status, Reason: clip(reason, maxReasonRunes), Message: clip(msg, maxMessageRunes)}, a.now, g)
}

func (a *attempt) set(t, status, reason, msg string) { a.setGen(t, status, reason, msg, a.gen) }

// setReadyFromRuntime sets Ready=False from what the runtime adapter reported. The adapter is meant to use a documented
// reason; one that is not is mapped to RuntimeNotReady with its own word in the message, so the table stays closed.
func (a *attempt) setReadyFromRuntime(rd plan.Readiness, g int64) {
	reason, msg := rd.Reason, rd.Message
	if !api.ValidReason(api.CondReady, reason) || reason == "Ready" {
		msg = strings.TrimSuffix(reason+": "+msg, ": ")
		reason = "RuntimeNotReady"
	}
	a.setGen(api.CondReady, "False", reason, msg, g)
}

func (a *attempt) unknownIfAbsent(t, reason string) {
	if a.st.Condition(t).Type == "" {
		a.set(t, "Unknown", reason, "")
	}
}

func (a *attempt) finish(outcome string, r retry, kv ...any) error {
	a.c.logOutcome(a.ns, a.name, outcome, kv...)
	if err := a.c.patchStatus(a.ctx, a.d, a.st); err != nil {
		a.c.noteFailure(a.key, a.gen, true)
		return err
	}
	switch r {
	case retryNone:
		a.c.clearFailure(a.key)
	case retryFlat:
		a.c.noteFailure(a.key, a.gen, false)
	default:
		a.c.noteFailure(a.key, a.gen, true)
	}
	return nil
}

// transient reports a failed read. When something runs, the conditions keep their last known state and Synced says the
// pass could not complete; when nothing runs yet it returns false and the caller reports the failure as a condition.
func (a *attempt) transient(what string, err error) bool {
	if !a.running {
		return false
	}
	a.set(api.CondSynced, "False", "TransientError", what+": "+err.Error())
	return true
}

func (a *attempt) synced() {
	if a.st.Condition(api.CondSynced).Type != "" {
		a.set(api.CondSynced, "True", "Synced", "")
	}
}

func (c *Controller) one(ctx context.Context, raw kube.Object, d *api.AgentDefinition, earlier []string) (bool, error) {
	name, ns := d.Metadata.Name, d.Metadata.Namespace
	if d.Deleting() {
		return false, c.finalize(ctx, d)
	}
	if !d.HasFinalizer(api.FinalizerGatewayKey) {
		updated, err := c.addFinalizer(ctx, raw, ns, name)
		if err != nil {
			return false, fmt.Errorf("add finalizer: %w", err)
		}
		if nd, err := api.FromObject(updated); err == nil {
			d = nd
		}
	}
	a := &attempt{c: c, ctx: ctx, d: d, name: name, ns: ns, key: defKey(ns, name), user: plan.GatewayUser(ns, name),
		gen: d.Metadata.Generation, now: c.cfg.Now().UTC().Format(time.RFC3339), st: cloneStatus(d.Status)}
	a.st.ObservedGeneration = a.gen
	caps := c.cfg.Runtime.Capabilities()
	a.st.Capabilities = &caps
	a.running = runs(a.st)

	// 1. accept or refuse
	violations := policy.Validate(policy.Input{Def: d, Catalog: c.cfg.Catalog, Policy: c.cfg.Policy, Tools: c.cfg.Tools, Earlier: earlier})
	if len(violations) > 0 {
		err := a.refused(violations, earlier)
		return a.keptPrevious, err // the previous generation still runs: the definition keeps its place
	}
	a.st.Violations = nil
	a.set(api.CondAccepted, "True", "Accepted", "")
	return true, a.apply()
}

// objectError says which object a write failed on.
type objectError struct {
	step, kind, name string
	err              error
}

func (e *objectError) Error() string { return e.err.Error() }

// writeObjects renders the plan, writes every object with server-side apply and prunes what the definition owns and no
// longer wants. The plan carries the key fingerprint the objects must show.
func (c *Controller) writeObjects(ctx context.Context, d *api.AgentDefinition, p plan.Plan, labels map[string]string, owner keys.OwnerRef) ([]string, *objectError) {
	ms, err := c.cfg.Runtime.Desired(p)
	if err != nil {
		return nil, &objectError{step: "render", err: err}
	}
	for _, m := range ms {
		stamp(m.Object, labels, owner)
	}
	keep := map[string]bool{}
	var names []string
	for _, m := range ms {
		n := kube.Meta(m.Object).String("name")
		if err := c.cfg.Kube.Apply(ctx, m.Resource, p.Namespace, n, m.Object); err != nil {
			return names, &objectError{step: "apply", kind: m.Resource.Kind, name: n, err: err}
		}
		keep[m.Resource.Plural+"/"+n] = true
		names = append(names, m.Resource.Kind+"/"+n)
	}
	if _, err := c.prune(ctx, d, keep); err != nil {
		return names, &objectError{step: "prune", err: err}
	}
	return names, nil
}

func definitionLabels(name string, p plan.Plan) map[string]string {
	l := map[string]string{api.LabelManagedBy: api.ManagedByValue, api.LabelDefinition: name}
	for k, v := range p.Labels {
		l[k] = v
	}
	return l
}

// apply is the accepted path: render, check names, key, apply, prune, report.
func (a *attempt) apply() error {
	c, ctx, d, name := a.c, a.ctx, a.d, a.name
	p, err := plan.Build(d, c.cfg.Catalog, c.cfg.Tools, c.cfg.Policy)
	if err != nil {
		a.set(api.CondApplied, "False", "RenderFailed", err.Error())
		a.set(api.CondReady, "False", "NotApplied", "")
		return a.finish("render_failed", retryExp, "err", err)
	}
	owner := keys.OwnerRef{APIVersion: api.APIVersion, Kind: api.Kind, Name: name, UID: d.Metadata.UID}
	labels := definitionLabels(name, p)
	// the objects are rendered once without the key fingerprint, to see their names for the name check
	manifests, err := c.cfg.Runtime.Desired(p)
	if err != nil {
		a.set(api.CondApplied, "False", "RenderFailed", err.Error())
		a.set(api.CondReady, "False", "NotApplied", "")
		return a.finish("render_failed", retryExp, "err", err)
	}

	// 2. name conflicts: an object with a target name that this definition does not own stops everything, before any write
	if conflict, err := c.conflicts(ctx, d, manifests); err != nil {
		if a.transient("check names", err) {
			return a.finish("transient", retryExp, "err", err)
		}
		a.set(api.CondApplied, "False", "CheckFailed", err.Error())
		a.set(api.CondReady, "False", "NotApplied", "")
		return a.finish("check_failed", retryExp, "err", err)
	} else if conflict != "" {
		a.unknownIfAbsent(api.CondKeyReady, "NotApplied")
		a.set(api.CondApplied, "False", "NameConflict", conflict+" already exists and is not owned by this definition; nothing was written")
		a.set(api.CondReady, "False", "NotApplied", "")
		return a.finish("name_conflict", retryNone, "object", conflict)
	}

	// 3. the key
	entries, err := c.gatewayEntries(ctx)
	if err != nil {
		if a.transient("read key registrations", err) {
			return a.finish("transient", retryExp, "err", err)
		}
		a.set(api.CondKeyReady, "False", "KeyFailed", err.Error())
		a.set(api.CondApplied, "False", "NotApplied", "waiting for the gateway key")
		a.set(api.CondReady, "False", "NotApplied", "")
		return a.finish("key_failed", retryExp, "secret", p.KeySecret, "err", err)
	}
	// A resume inside the minimum time between two creations of the runtime agent waits: the plan is treated as suspended
	// (agent absent, key cut) until the interval has passed.
	if !p.Suspended {
		if until, delayed := a.recreateDelay(); delayed {
			a.delayedUntil, p.Suspended = until, true
		}
	}
	known := ""
	if a.st.Controller.KeySecret == p.KeySecret {
		known = a.st.Controller.KeyFingerprint
	}
	reg := entries[p.GatewayUserID]
	// The previous controller registered the key under the plain name. With no entry under the new user id, such an entry is this
	// definition's key from before the upgrade (the key Secret has the same name): keys.Ensure moves its hash to the new user when
	// the Secret exists, instead of replacing a key that is in order. The old entry is swept at the end of the pass.
	adopted := false
	if old := entries[p.Name]; reg.Hash == "" && old.Hash != "" {
		reg, adopted = old, true
	}
	held := a.st.Controller.HeldKeyHash
	if !p.Suspended && held != "" && reg.Hash == "" {
		// resume: the hash that was held is registered again, so the same key works and no key is made
		if err := c.cfg.Gateway.Register(ctx, p.GatewayUserID, held, p.Labels); err != nil {
			a.set(api.CondKeyReady, "False", "KeyFailed", err.Error())
			a.set(api.CondApplied, "False", "NotApplied", "waiting for the gateway key")
			a.set(api.CondReady, "False", "NotApplied", "")
			return a.finish("key_failed", retryExp, "secret", p.KeySecret, "err", err)
		}
		reg, adopted = keys.Entry{Hash: held, Labels: p.Labels}, false
		entries[p.GatewayUserID] = reg
		known = keys.Fingerprint(held)
	}
	var res keys.Result
	if p.Suspended && held != "" && reg.Hash == "" {
		// suspended and nothing registered: the key is the held one, nothing to make (a new key would replace a good one)
		res = keys.Result{Outcome: keys.Unchanged, Fingerprint: keys.Fingerprint(held), Hash: held}
	} else {
		res, err = keys.Ensure(ctx, keys.Params{
			Namespace: p.Namespace, SecretName: p.KeySecret, DataKey: c.cfg.Runtime.KeyDataKey(), User: p.GatewayUserID,
			Labels: map[string]string{api.LabelManagedBy: api.ManagedByValue, api.LabelDefinition: name}, Owner: owner, Registered: reg.Hash, Known: known,
			EntryLabels: p.Labels, RegisteredLabels: reg.Labels, Adopted: adopted, Hold: p.Suspended,
		}, c.cfg.Secrets, c.cfg.Gateway, c.cfg.Mint)
	}
	if err != nil {
		a.set(api.CondKeyReady, "False", "KeyFailed", err.Error())
		a.set(api.CondApplied, "False", "NotApplied", "waiting for the gateway key")
		a.set(api.CondReady, "False", "NotApplied", "")
		return a.finish("key_failed", retryExp, "secret", p.KeySecret, "err", err)
	}
	a.st.Controller.KeySecret, a.st.Controller.KeyFingerprint = p.KeySecret, res.Fingerprint
	if p.Suspended {
		// the hash is remembered first, the entry cut second: an interruption in between loses nothing
		if err := a.holdKey(p.GatewayUserID, res.Hash, entries); err != nil {
			a.set(api.CondKeyReady, "False", "KeyFailed", err.Error())
			a.set(api.CondApplied, "False", "NotApplied", "waiting for the gateway key")
			a.set(api.CondReady, "False", "NotApplied", "")
			return a.finish("key_failed", retryExp, "secret", p.KeySecret, "err", err)
		}
		a.set(api.CondKeyReady, "False", "KeySuspended", "Secret "+p.KeySecret+" exists; the gateway does not know its hash while the definition is suspended")
	} else {
		a.st.Controller.HeldKeyHash = ""
		entries[p.GatewayUserID] = keys.Entry{Hash: res.Hash, Labels: p.Labels}
		a.set(api.CondKeyReady, "True", "KeyReady", "Secret "+p.KeySecret)
	}
	// the objects carry the fingerprint (they must roll when the key is replaced), so they are rendered again with it
	a.starting = !p.Suspended && a.st.AgentRef == nil

	// 4. apply, then prune
	p.KeyFingerprint = res.Fingerprint
	names, oe := c.writeObjects(ctx, d, p, labels, owner)
	if oe != nil {
		switch oe.step {
		case "render":
			a.set(api.CondApplied, "False", "RenderFailed", oe.Error())
			a.set(api.CondReady, "False", "NotApplied", "")
			return a.finish("render_failed", retryExp, "err", oe.err)
		case "apply":
			a.set(api.CondApplied, "False", "ApplyFailed", fmt.Sprintf("%s %s: %v", oe.kind, oe.name, oe.err))
			a.set(api.CondReady, "False", "NotApplied", "")
			return a.finish("apply_failed", retryExp, "kind", oe.kind, "object", oe.name, "err", oe.err)
		default:
			a.set(api.CondApplied, "False", "PruneFailed", oe.Error())
			a.set(api.CondReady, "False", "NotApplied", "")
			return a.finish("prune_failed", retryExp, "err", oe.err)
		}
	}
	a.set(api.CondApplied, "True", "Applied", "")
	a.setFacts(p)

	// 5. suspended: the objects stay, the agent takes no work
	if p.Suspended {
		a.st.Endpoint, a.st.AgentRef = nil, nil
		if !a.delayedUntil.IsZero() {
			a.set(api.CondReady, "False", "ResumeDelayed", fmt.Sprintf("resume is delayed until %s: the runtime agent is created at most once per %s; the key stays cut until then",
				a.delayedUntil.UTC().Format(time.RFC3339), c.cfg.MinRecreateInterval))
			a.synced()
			return a.finish("resume_delayed", retryFlat, "until", a.delayedUntil.UTC().Format(time.RFC3339), "objects", names)
		}
		a.set(api.CondReady, "False", "Suspended", a.suspendedBy(p))
		a.synced()
		return a.finish("suspended", retryNone, "objects", names)
	}

	// 6. readiness
	rd, err := c.cfg.Runtime.Readiness(ctx, p)
	switch {
	case err != nil:
		if prev := a.st.Condition(api.CondReady); prev.Type != "" && a.running && prev.Reason != "NotApplied" && prev.Reason != "NotAccepted" && prev.Reason != "ReadinessUnknown" && prev.Reason != "Suspended" {
			a.transient("read readiness", err) // the last known Ready stays
			return a.finish("transient", retryExp, "objects", names, "err", err)
		}
		a.set(api.CondReady, "False", "ReadinessUnknown", err.Error())
		return a.finish("readiness_unknown", retryFlat, "objects", names, "err", err)
	case rd.Ready && a.st.Endpoint == nil:
		// Ready=True promises "callable at status.endpoint": with no endpoint the promise cannot be made
		a.set(api.CondReady, "False", "NoEndpoint", "the runtime reports the agent ready, but the platform advertises no endpoint (the A2A gate is off)")
		a.synced()
		return a.finish("no_endpoint", retryNone, "objects", names)
	case rd.Ready:
		a.set(api.CondReady, "True", "Ready", "")
		a.synced()
		return a.finish("ready", retryNone, "objects", names, "key", string(res.Outcome))
	default:
		a.setReadyFromRuntime(rd, a.gen)
		a.synced()
		return a.finish("not_ready", retryFlat, "reason", rd.Reason, "objects", names)
	}
}

// setFacts records what this plan applied: the public facts and the controller's own bookkeeping.
func (a *attempt) setFacts(p plan.Plan) {
	c := a.c
	ref := c.cfg.Runtime.Ref(p)
	a.st.AgentRef = &ref
	a.st.Endpoint = c.cfg.Runtime.Endpoint(p)
	a.st.Revision = p.Revision
	a.st.EffectiveTools = slices.Clone(p.Tools)
	a.st.EffectiveEgress = slices.Clone(p.Egress)
	a.st.Controller.GatewayUserID = p.GatewayUserID
	a.st.Controller.ToolServer = p.ToolBackend
	a.st.Controller.AppliedGeneration = a.gen
	a.st.Controller.AppliedSpec = specJSON(a.d.Spec)
	if a.starting {
		a.st.Controller.AgentStartedAt = a.now
	}
}

// holdKey remembers hash in status.controller.heldKeyHash (a minimal merge patch, before anything is cut) and removes the gateway
// entry of user when there is one, so that the key opens nothing while the definition is suspended.
func (a *attempt) holdKey(user, hash string, entries map[string]keys.Entry) error {
	c := a.c
	if hash != "" && a.st.Controller.HeldKeyHash != hash {
		patch := kube.Object{"status": kube.Object{"controller": kube.Object{"heldKeyHash": hash}}}
		if err := c.cfg.Kube.PatchMerge(a.ctx, definitions, a.ns, a.name, "status", patch); err != nil {
			return fmt.Errorf("remember the key hash: %w", err)
		}
		a.st.Controller.HeldKeyHash = hash
	}
	if _, ok := entries[user]; ok {
		if err := c.cfg.Gateway.Unregister(a.ctx, user); err != nil {
			return fmt.Errorf("remove the key entry: %w", err)
		}
		delete(entries, user)
	}
	return nil
}

func (a *attempt) suspendedBy(p plan.Plan) string {
	const what = "the runtime agent is removed (running conversations end) and the key is cut; resume starts fresh with the same definition and key"
	switch {
	case a.c.cfg.Policy.SuspendAll && a.d.Spec.Suspend:
		return "suspended: spec.suspend is true and the operator's stop switch (policy suspendAll) is on; " + what
	case a.c.cfg.Policy.SuspendAll:
		return "suspended by the operator's stop switch (policy suspendAll); " + what
	default:
		return "suspended: spec.suspend is true; " + what
	}
}

// refused handles a definition that fails validation. What runs depends on why:
//   - nothing ran: only the status changes;
//   - the author edited a previously accepted definition into something refused, and the previously applied spec still
//     passes the current catalog and policy: that version keeps running and status says so;
//   - the catalog or the policy changed (the spec is the one applied), or the previously applied spec no longer passes,
//     or what was applied is unknown: the agent's objects and key hash are removed, and status says so.
func (a *attempt) refused(violations []string, earlier []string) error {
	c := a.c
	a.st.Violations = violations
	a.set(api.CondAccepted, "False", "PolicyViolation", fmt.Sprintf("%d rule(s) refused; see status.violations", len(violations)))
	if !a.running {
		a.unknownIfAbsent(api.CondKeyReady, "NotAccepted")
		a.set(api.CondApplied, "False", "NotAccepted", "the definition is refused; nothing is running")
		a.set(api.CondReady, "False", "NotAccepted", "")
		return a.finish("refused", retryNone, "violations", len(violations))
	}

	var prev api.Spec
	havePrev := a.st.Controller.AppliedSpec != "" && json.Unmarshal([]byte(a.st.Controller.AppliedSpec), &prev) == nil
	if havePrev && a.st.Controller.AppliedSpec != specJSON(a.d.Spec) { // the refusal comes from the author's edit
		pd := *a.d
		pd.Spec = prev
		if len(policy.Validate(policy.Input{Def: &pd, Catalog: c.cfg.Catalog, Policy: c.cfg.Policy, Tools: c.cfg.Tools, Earlier: earlier})) == 0 {
			if pp, err := plan.Build(&pd, c.cfg.Catalog, c.cfg.Tools, c.cfg.Policy); err == nil {
				return a.keepPrevious(pp, violations)
			}
		}
	}
	return a.removeRunning(violations)
}

func (a *attempt) keepPrevious(pp plan.Plan, violations []string) error {
	c := a.c
	a.keptPrevious = true
	pg := a.st.Controller.AppliedGeneration
	a.setGen(api.CondApplied, "True", "PreviousGenerationRunning",
		fmt.Sprintf("generation %d keeps running; generation %d is refused (see status.violations)", pg, a.gen), pg)
	// The previous spec is rendered again against the current catalog and written, so what runs does not go stale (a new image,
	// a new skill digest, a moved gateway) while the author's edit stands refused. The key is the one that runs: its fingerprint
	// is the recorded one, so nothing rolls for nothing.
	pp.KeyFingerprint = a.st.Controller.KeyFingerprint
	if !pp.Suspended {
		if until, delayed := a.recreateDelay(); delayed {
			a.delayedUntil, pp.Suspended = until, true
		}
	}
	if err := a.keyForPrevious(pp); err != nil {
		a.transient("update the key registration of the previous generation", err)
		return a.finish("transient", retryExp, "err", err)
	}
	a.starting = !pp.Suspended && a.st.AgentRef == nil
	owner := keys.OwnerRef{APIVersion: api.APIVersion, Kind: api.Kind, Name: a.name, UID: a.d.Metadata.UID}
	if _, oe := c.writeObjects(a.ctx, a.d, pp, definitionLabels(a.name, pp), owner); oe != nil {
		a.transient("render the previous generation again", oe.err)
		return a.finish("transient", retryExp, "err", oe.err)
	}
	if pp.Suspended {
		// the operator's stop switch is on (or the previous spec was suspended): the previous generation is suspended too
		a.st.Endpoint, a.st.AgentRef = nil, nil
		if !a.delayedUntil.IsZero() {
			a.setGen(api.CondReady, "False", "ResumeDelayed", fmt.Sprintf("resume is delayed until %s: the runtime agent is created at most once per %s",
				a.delayedUntil.UTC().Format(time.RFC3339), c.cfg.MinRecreateInterval), pg)
			a.synced()
			return a.finish("refused_previous_resume_delayed", retryFlat, "violations", len(violations))
		}
		a.setGen(api.CondReady, "False", "Suspended", a.suspendedBy(pp), pg)
		a.synced()
		return a.finish("refused_previous_suspended", retryNone, "violations", len(violations))
	}
	ref := c.cfg.Runtime.Ref(pp)
	a.st.AgentRef, a.st.Endpoint = &ref, c.cfg.Runtime.Endpoint(pp)
	if a.starting {
		a.st.Controller.AgentStartedAt = a.now
	}
	rd, err := c.cfg.Runtime.Readiness(a.ctx, pp)
	if err != nil {
		a.transient("read readiness", err)
		return a.finish("transient", retryExp, "err", err)
	}
	if rd.Ready {
		a.setGen(api.CondReady, "True", "Ready", "", pg)
		a.synced()
		return a.finish("refused_previous_running", retryNone, "violations", len(violations))
	}
	a.setReadyFromRuntime(rd, pg)
	a.synced()
	return a.finish("refused_previous_not_ready", retryFlat, "reason", rd.Reason)
}

// keyForPrevious is the key's half of suspend and resume for a refused definition whose previous generation keeps running: a suspended
// generation has its gateway entry cut (the hash held), a generation that runs again has the held hash registered.
func (a *attempt) keyForPrevious(pp plan.Plan) error {
	entries, err := a.c.gatewayEntries(a.ctx)
	if err != nil {
		return err
	}
	if pp.Suspended {
		return a.holdKey(pp.GatewayUserID, entries[pp.GatewayUserID].Hash, entries)
	}
	if held := a.st.Controller.HeldKeyHash; held != "" {
		if entries[pp.GatewayUserID].Hash == "" {
			if err := a.c.cfg.Gateway.Register(a.ctx, pp.GatewayUserID, held, pp.Labels); err != nil {
				return err
			}
			entries[pp.GatewayUserID] = keys.Entry{Hash: held, Labels: pp.Labels}
		}
		a.st.Controller.HeldKeyHash = ""
	}
	return nil
}

func (a *attempt) removeRunning(violations []string) error {
	c := a.c
	if _, err := c.prune(a.ctx, a.d, nil); err != nil {
		a.set(api.CondApplied, "False", "RemoveFailed", err.Error())
		a.set(api.CondReady, "False", "NotAccepted", "")
		return a.finish("remove_failed", retryExp, "err", err)
	}
	if err := c.cfg.Gateway.Unregister(a.ctx, a.user); err != nil {
		a.set(api.CondApplied, "False", "RemoveFailed", "unregister key: "+err.Error())
		a.set(api.CondReady, "False", "NotAccepted", "")
		return a.finish("remove_failed", retryExp, "err", err)
	}
	if c.ps != nil && c.ps.entries != nil {
		delete(c.ps.entries, a.user)
	}
	a.st.AgentRef, a.st.Endpoint, a.st.Revision = nil, nil, ""
	a.st.EffectiveTools, a.st.EffectiveEgress = nil, nil
	a.st.Controller = api.ControllerState{}
	a.set(api.CondKeyReady, "Unknown", "NotAccepted", "")
	a.set(api.CondApplied, "False", "PolicyRemoved", "the definition is refused under the current catalog and policy; the agent's objects and key were removed")
	a.set(api.CondReady, "False", "NotAccepted", "")
	a.synced()
	return a.finish("removed", retryNone, "violations", len(violations))
}

func cloneStatus(s api.Status) api.Status {
	s.Conditions = slices.Clone(s.Conditions)
	s.EffectiveTools = slices.Clone(s.EffectiveTools)
	s.EffectiveEgress = slices.Clone(s.EffectiveEgress)
	s.Violations = slices.Clone(s.Violations)
	if s.AgentRef != nil {
		r := *s.AgentRef
		s.AgentRef = &r
	}
	if s.Endpoint != nil {
		e := *s.Endpoint
		s.Endpoint = &e
	}
	if s.Capabilities != nil {
		cp := *s.Capabilities
		s.Capabilities = &cp
	}
	return s
}

// patchStatus writes the status when it differs from what is stored. A 422 is logged and dropped: the same patch would be
// refused again, so retrying it only adds load.
func (c *Controller) patchStatus(ctx context.Context, d *api.AgentDefinition, st api.Status) error {
	if reflect.DeepEqual(jsonMap(d.Status.Patch()), jsonMap(st.Patch())) {
		return nil
	}
	if err := c.cfg.Kube.PatchMerge(ctx, definitions, d.Metadata.Namespace, d.Metadata.Name, "status", st.Patch()); err != nil {
		if kube.IsInvalid(err) {
			c.cfg.Log.Error("the API server refused the status as invalid; not retrying it", "agent", d.Metadata.Name, "outcome", "status_invalid", "err", err)
			return nil
		}
		return fmt.Errorf("patch status: %w", err)
	}
	return nil
}

func jsonMap(m map[string]any) map[string]any {
	b, _ := json.Marshal(m)
	var out map[string]any
	_ = json.Unmarshal(b, &out)
	return out
}

func stamp(o kube.Object, labels map[string]string, owner keys.OwnerRef) {
	m := kube.Meta(o)
	l, _ := m["labels"].(map[string]any)
	if l == nil {
		l = map[string]any{}
	}
	for k, v := range labels {
		l[k] = v
	}
	m["labels"] = l
	m["ownerReferences"] = []any{map[string]any{"apiVersion": owner.APIVersion, "kind": owner.Kind, "name": owner.Name, "uid": owner.UID, "controller": true}}
}

// owned reports whether obj belongs to d: both of our labels AND an owner reference to this very definition (kind, UID,
// controller). Labels are guessable and copyable; the UID is not.
func owned(obj kube.Object, d *api.AgentDefinition) bool {
	m := kube.Meta(obj)
	l, _ := m["labels"].(map[string]any)
	if l[api.LabelManagedBy] != api.ManagedByValue || l[api.LabelDefinition] != d.Metadata.Name || d.Metadata.UID == "" {
		return false
	}
	refs, _ := m["ownerReferences"].([]any)
	for _, r := range refs {
		ref, _ := r.(map[string]any)
		if ref["kind"] == api.Kind && ref["uid"] == d.Metadata.UID && ref["controller"] == true {
			return true
		}
	}
	return false
}

func (c *Controller) conflicts(ctx context.Context, d *api.AgentDefinition, ms []kube.Manifest) (string, error) {
	for _, m := range ms {
		n := kube.Meta(m.Object).String("name")
		cur, err := c.cfg.Kube.Get(ctx, m.Resource, d.Metadata.Namespace, n)
		if kube.IsNotFound(err) {
			continue
		}
		if err != nil {
			return "", fmt.Errorf("check %s %s: %w", m.Resource.Kind, n, err)
		}
		if !owned(cur, d) {
			return m.Resource.Kind + " " + n, nil
		}
	}
	return "", nil
}

// prune deletes the objects this definition owns (labels and owner reference) that are not in keep ("plural/name"), in the
// definition's namespace. A kind the cluster does not know (404 on the list: the CRD is not installed) has nothing to prune.
func (c *Controller) prune(ctx context.Context, d *api.AgentDefinition, keep map[string]bool) ([]string, error) {
	var deleted []string
	ns := d.Metadata.Namespace
	for _, kind := range c.cfg.Runtime.OwnedKinds() {
		items, _, err := c.cfg.Kube.List(ctx, kind, ns, selector(d.Metadata.Name))
		if kube.IsNotFound(err) {
			continue
		}
		if err != nil {
			return deleted, fmt.Errorf("list %s: %w", kind.Plural, err)
		}
		for _, it := range items {
			n := kube.Meta(it).String("name")
			if keep[kind.Plural+"/"+n] || !owned(it, d) {
				continue
			}
			if err := c.cfg.Kube.Delete(ctx, kind, ns, n); err != nil && !kube.IsNotFound(err) {
				return deleted, fmt.Errorf("delete %s %s: %w", kind.Kind, n, err)
			}
			deleted = append(deleted, kind.Kind+"/"+n)
			c.cfg.Log.Info("pruned", "agent", d.Metadata.Name, "namespace", ns, "kind", kind.Kind, "object", n, "outcome", "pruned")
		}
	}
	return deleted, nil
}

func (c *Controller) addFinalizer(ctx context.Context, raw kube.Object, ns, name string) (kube.Object, error) {
	m := kube.Meta(raw)
	fin, _ := m["finalizers"].([]any)
	m["finalizers"] = append(fin, api.FinalizerGatewayKey)
	return c.cfg.Kube.Update(ctx, definitions, ns, name, raw)
}

// finalize runs when deletion was requested: owned objects and the key hash go, then the finalizer. The key Secret is
// removed by the owner reference.
func (c *Controller) finalize(ctx context.Context, d *api.AgentDefinition) error {
	name, ns := d.Metadata.Name, d.Metadata.Namespace
	key, user := defKey(ns, name), plan.GatewayUser(ns, name)
	if !d.HasFinalizer(api.FinalizerGatewayKey) {
		c.forget(key)
		return nil
	}
	if _, err := c.prune(ctx, d, nil); err != nil {
		return fmt.Errorf("remove objects: %w", err)
	}
	if err := c.cfg.Gateway.Unregister(ctx, user); err != nil {
		return fmt.Errorf("unregister key: %w", err)
	}
	if c.ps != nil && c.ps.entries != nil {
		delete(c.ps.entries, user)
	}
	cur, err := c.cfg.Kube.Get(ctx, definitions, ns, name)
	if kube.IsNotFound(err) {
		c.forget(key)
		return nil
	}
	if err != nil {
		return fmt.Errorf("read before removing finalizer: %w", err)
	}
	m := kube.Meta(cur)
	fins, _ := m["finalizers"].([]any)
	var rest []any
	for _, f := range fins {
		if f != api.FinalizerGatewayKey {
			rest = append(rest, f)
		}
	}
	if len(rest) == len(fins) && len(fins) == 0 {
		// no finalizers at all on the fresh object: nothing of ours holds it any more
		c.forget(key)
		return nil
	}
	if rest == nil {
		delete(m, "finalizers")
	} else {
		m["finalizers"] = rest
	}
	if _, err := c.cfg.Kube.Update(ctx, definitions, ns, name, cur); err != nil && !kube.IsNotFound(err) {
		return fmt.Errorf("remove finalizer: %w", err)
	}
	c.logOutcome(ns, name, "deleted")
	c.forget(key)
	return nil
}
