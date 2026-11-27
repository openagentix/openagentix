package clusterread

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/fields"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/client-go/kubernetes"

	"github.com/openagentix/openagentix/services/diagnostics/internal/audit"
	"github.com/openagentix/openagentix/services/diagnostics/internal/ratelimit"
	"github.com/openagentix/openagentix/services/diagnostics/internal/redact"
)

// Caps from ADR 0025, section 2.
const (
	maxPods          = 200
	maxEvents        = 100
	maxWorkloads     = 200
	defaultTail      = 100
	maxTail          = 200
	maxSinceSeconds  = 3600
	logLimitBytes    = 65536
	maxSelectorBytes = 256
	apiTimeout       = 5 * time.Second
	logTimeout       = 10 * time.Second
)

// RefusalError is a call refused before any API request.
type RefusalError struct{ Msg string }

func (e *RefusalError) Error() string { return e.Msg }

// CallError is a call that reached the API and failed. The text is fixed and never repeats API output.
type CallError struct{ Msg string }

func (e *CallError) Error() string { return e.Msg }

func refuse(format string, a ...any) error { return &RefusalError{Msg: fmt.Sprintf(format, a...)} }

// LogFunc opens a pod log stream.
type LogFunc func(ctx context.Context, ns, pod string, o *corev1.PodLogOptions) (io.ReadCloser, error)

// Gate says whether the server may serve.
type Gate interface{ Ready() (bool, string) }

// Options builds a Server.
type Options struct {
	Config Config
	Client kubernetes.Interface
	// Logs opens a pod log stream; nil reads from Client.
	Logs  LogFunc
	Audit *audit.Logger
	Now   func() time.Time
	// Gate, if set, must report ready before any tool is served.
	Gate Gate
	// CallsPerMinute and LogsPerMinute default to 60 and 20.
	CallsPerMinute, LogsPerMinute int
}

// Server serves the eight tools.
type Server struct {
	cfg    Config
	kube   kubernetes.Interface
	logs   LogFunc
	sc     *redact.Scanner
	au     *audit.Logger
	now    func() time.Time
	gate   Gate
	all    *ratelimit.Limiter
	logLim *ratelimit.Limiter
	calls  int
}

// NewServer checks the configuration and builds a Server.
func NewServer(o Options) (*Server, error) {
	if err := o.Config.Validate(); err != nil {
		return nil, err
	}
	if o.Client == nil {
		return nil, errors.New("no Kubernetes client")
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.CallsPerMinute <= 0 {
		o.CallsPerMinute = 60
	}
	if o.LogsPerMinute <= 0 {
		o.LogsPerMinute = 20
	}
	if o.Logs == nil {
		kube := o.Client
		o.Logs = func(ctx context.Context, ns, pod string, po *corev1.PodLogOptions) (io.ReadCloser, error) {
			return kube.CoreV1().Pods(ns).GetLogs(pod, po).Stream(ctx)
		}
	}
	return &Server{cfg: o.Config, kube: o.Client, logs: o.Logs, sc: redact.New(), au: o.Audit, now: o.Now, gate: o.Gate,
		calls: o.CallsPerMinute, all: ratelimit.New(o.CallsPerMinute, o.Now), logLim: ratelimit.New(o.LogsPerMinute, o.Now)}, nil
}

// ---- argument structs, with the schema text agents see ----

type PodsListArgs struct {
	Namespace     string `json:"namespace" jsonschema:"a namespace the operator listed"`
	LabelSelector string `json:"labelSelector,omitempty" jsonschema:"optional label selector, for example app=web"`
}
type PodsGetArgs struct {
	Namespace string `json:"namespace" jsonschema:"a namespace the operator listed"`
	Name      string `json:"name" jsonschema:"pod name"`
}
type PodsLogArgs struct {
	Namespace    string `json:"namespace" jsonschema:"a namespace that allows logs"`
	Pod          string `json:"pod" jsonschema:"pod name"`
	Container    string `json:"container,omitempty" jsonschema:"container name; optional when the pod has one container"`
	Previous     bool   `json:"previous,omitempty" jsonschema:"read the log of the previous container instance"`
	TailLines    int    `json:"tailLines,omitempty" jsonschema:"number of last lines, default 100, at most 200"`
	SinceSeconds int    `json:"sinceSeconds,omitempty" jsonschema:"only lines newer than this many seconds, at most 3600"`
}
type EventsListArgs struct {
	Namespace    string `json:"namespace" jsonschema:"a namespace the operator listed"`
	InvolvedKind string `json:"involvedKind,omitempty" jsonschema:"only events about this kind, for example Pod"`
	InvolvedName string `json:"involvedName,omitempty" jsonschema:"only events about this object name"`
}
type WorkloadsListArgs struct {
	Namespace string `json:"namespace" jsonschema:"a namespace the operator listed"`
	Kind      string `json:"kind" jsonschema:"deployment, statefulset, daemonset or replicaset"`
}
type WorkloadsGetArgs struct {
	Namespace string `json:"namespace" jsonschema:"a namespace the operator listed"`
	Kind      string `json:"kind" jsonschema:"deployment, statefulset, daemonset or replicaset"`
	Name      string `json:"name" jsonschema:"workload name"`
}
type NodesGetArgs struct {
	Name string `json:"name" jsonschema:"node name"`
}

// ---- the call wrapper ----

type info struct {
	target, object string
	lines, red     int
}

// do runs one call: validation, readiness, rate limit, timeout, error mapping and the audit line.
func (s *Server) do(ctx context.Context, tool, target, object string, isLog bool, validate func() error, run func(ctx context.Context, in *info) (Result, error)) (Result, error) {
	began := time.Now()
	in := &info{target: target, object: object}
	outcome, size := "ok", 0
	defer func() {
		if s.au != nil {
			s.au.Write(audit.Record{Tool: tool, Target: in.target, Object: in.object, Outcome: outcome, Duration: time.Since(began), Bytes: size, Lines: in.lines, Redactions: in.red})
		}
	}()
	if err := validate(); err != nil {
		outcome = "refused"
		return nil, err
	}
	if s.gate != nil {
		if ok, why := s.gate.Ready(); !ok {
			outcome = "not_ready"
			return nil, refuse("the server is not ready, so it serves no tool: %s", why)
		}
	}
	if !s.all.Allow() {
		outcome = "rate_limited"
		return nil, refuse("rate limit reached: at most %d calls a minute; wait and try again", s.calls)
	}
	if isLog && !s.logLim.Allow() {
		s.all.Refund()
		outcome = "rate_limited"
		return nil, refuse("rate limit reached for pods_log: wait a minute and try again")
	}
	timeout := apiTimeout
	if isLog {
		timeout = logTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	res, err := run(ctx, in)
	if err != nil {
		var ref *RefusalError
		switch {
		case errors.As(err, &ref):
			outcome = "refused"
			return nil, err
		case apierrors.IsNotFound(err):
			outcome = "not_found"
			return nil, &CallError{Msg: "not found: check the namespace, the name and the container"}
		case errors.Is(err, context.DeadlineExceeded):
			outcome = "timeout"
			return nil, &CallError{Msg: "the cluster API timed out; try again later"}
		case apierrors.IsForbidden(err):
			outcome = "error"
			return nil, &CallError{Msg: "the server's role does not allow this request"}
		}
		outcome = "error"
		return nil, &CallError{Msg: "the cluster API call failed; try again later"}
	}
	res["content"] = Marking
	if b, err := json.Marshal(res); err == nil {
		size = len(b)
	}
	return res, nil
}

func (s *Server) builder(ns string) *builder {
	return &builder{sc: s.sc, now: s.now(), status: s.cfg.kind(ns) != nsLog}
}

// ---- validation ----

func (s *Server) checkNS(ns string, needLogs bool) error {
	if strings.HasPrefix(ns, "-") || !dnsLabel.MatchString(ns) {
		return refuse("namespace is not a valid namespace name")
	}
	switch s.cfg.kind(ns) {
	case nsNone:
		return refuse("namespace is not on the list this server reads: ask the operator to add it to diagnostics.cluster.logNamespaces or statusNamespaces")
	case nsStatus:
		if needLogs {
			return refuse("logs are not available in this namespace: it is on the status-only list (pods, events and workloads)")
		}
	}
	return nil
}

func checkName(what, v string, re interface{ MatchString(string) bool }) error {
	if v == "" || strings.HasPrefix(v, "-") || !re.MatchString(v) {
		return refuse("%s is not a valid name (lower case letters, digits and -)", what)
	}
	return nil
}

func checkOptionalName(what, v string) error {
	if v == "" {
		return nil
	}
	return checkName(what, v, dnsLabel)
}

func firstErr(errs ...error) error {
	for _, e := range errs {
		if e != nil {
			return e
		}
	}
	return nil
}

func workloadKind(kind string) error {
	switch kind {
	case "deployment", "statefulset", "daemonset", "replicaset":
		return nil
	}
	return refuse("kind must be one of deployment, statefulset, daemonset, replicaset")
}

// ---- tools ----

// PodsList lists pods of a namespace.
func (s *Server) PodsList(ctx context.Context, a PodsListArgs) (Result, error) {
	return s.do(ctx, "pods_list_in_namespace", a.Namespace, "", false, func() error {
		if err := s.checkNS(a.Namespace, false); err != nil {
			return err
		}
		if a.LabelSelector != "" {
			if strings.HasPrefix(a.LabelSelector, "-") || len(a.LabelSelector) > maxSelectorBytes {
				return refuse("labelSelector is not valid")
			}
			if _, err := labels.Parse(a.LabelSelector); err != nil {
				return refuse("labelSelector is not valid")
			}
		}
		return nil
	}, func(ctx context.Context, in *info) (Result, error) {
		list, err := s.kube.CoreV1().Pods(a.Namespace).List(ctx, metav1.ListOptions{LabelSelector: a.LabelSelector, Limit: maxPods})
		if err != nil {
			return nil, err
		}
		b := s.builder(a.Namespace)
		items := list.Items
		sort.Slice(items, func(i, j int) bool { return items[i].Name < items[j].Name })
		truncated := list.Continue != "" || len(items) > maxPods
		if len(items) > maxPods {
			items = items[:maxPods]
		}
		rows := make([]map[string]any, 0, len(items))
		for i := range items {
			rows = append(rows, b.podRow(&items[i]))
		}
		in.lines, in.red = len(rows), b.red
		return Result{"namespace": a.Namespace, "pods": rows, "truncated": truncated}, nil
	})
}

// PodsGet returns one pod, built from the field allowlist.
func (s *Server) PodsGet(ctx context.Context, a PodsGetArgs) (Result, error) {
	return s.do(ctx, "pods_get", a.Namespace, a.Name, false, func() error {
		return firstErr(s.checkNS(a.Namespace, false), checkName("name", a.Name, dnsLabel))
	}, func(ctx context.Context, in *info) (Result, error) {
		p, err := s.kube.CoreV1().Pods(a.Namespace).Get(ctx, a.Name, metav1.GetOptions{})
		if err != nil {
			return nil, err
		}
		b := s.builder(a.Namespace)
		res := Result{"pod": b.pod(p)}
		in.red = b.red
		return res, nil
	})
}

// PodsLog returns capped, cleaned and redacted log lines.
func (s *Server) PodsLog(ctx context.Context, a PodsLogArgs) (Result, error) {
	return s.do(ctx, "pods_log", a.Namespace, a.Pod, true, func() error {
		if err := firstErr(s.checkNS(a.Namespace, true), checkName("pod", a.Pod, dnsLabel), checkOptionalName("container", a.Container)); err != nil {
			return err
		}
		switch {
		case a.TailLines < 0 || a.TailLines > maxTail:
			return refuse("tailLines must be between 1 and %d", maxTail)
		case a.SinceSeconds < 0 || a.SinceSeconds > maxSinceSeconds:
			return refuse("sinceSeconds must be between 1 and %d", maxSinceSeconds)
		}
		return nil
	}, func(ctx context.Context, in *info) (Result, error) {
		tail := int64(defaultTail)
		if a.TailLines > 0 {
			tail = int64(a.TailLines)
		}
		limit := int64(logLimitBytes)
		opts := &corev1.PodLogOptions{Container: a.Container, Previous: a.Previous, TailLines: &tail, LimitBytes: &limit}
		if a.SinceSeconds > 0 {
			since := int64(a.SinceSeconds)
			opts.SinceSeconds = &since
		}
		rc, err := s.logs(ctx, a.Namespace, a.Pod, opts)
		if err != nil {
			if apierrors.IsNotFound(err) {
				return nil, err
			}
			return nil, &CallError{Msg: "the log request was not accepted: check the pod, the container and previous"}
		}
		defer rc.Close()
		data, err := io.ReadAll(io.LimitReader(rc, logLimitBytes))
		if err != nil {
			return nil, &CallError{Msg: "the log could not be read; try again later"}
		}
		truncated := len(data) >= logLimitBytes
		if truncated && !bytes.HasSuffix(data, []byte("\n")) {
			// the byte limit cut the last line: a half-read secret would not be recognised
			if i := bytes.LastIndexByte(data, '\n'); i >= 0 {
				data = data[:i+1]
			} else {
				data = nil
			}
		}
		text := strings.TrimSuffix(string(data), "\n")
		b := s.builder(a.Namespace)
		lines := []string{}
		if text != "" || len(data) > 0 {
			for _, l := range strings.Split(text, "\n") {
				lines = append(lines, b.s(l, maxLine))
			}
		}
		in.lines, in.red = len(lines), b.red
		res := Result{"namespace": a.Namespace, "pod": a.Pod, "previous": a.Previous, "line_count": len(lines), "truncated": truncated,
			"redactions": b.red, "untrusted_text": map[string]any{"lines": lines}}
		if a.Container != "" {
			res["container"] = a.Container
		}
		return res, nil
	})
}

// EventsList returns the newest events, with container output reduced in status namespaces.
func (s *Server) EventsList(ctx context.Context, a EventsListArgs) (Result, error) {
	return s.do(ctx, "events_list", a.Namespace, "", false, func() error {
		if err := s.checkNS(a.Namespace, false); err != nil {
			return err
		}
		if a.InvolvedKind != "" && (strings.HasPrefix(a.InvolvedKind, "-") || !kindName.MatchString(a.InvolvedKind)) {
			return refuse("involvedKind is not a valid kind")
		}
		return checkOptionalName("involvedName", a.InvolvedName)
	}, func(ctx context.Context, in *info) (Result, error) {
		sel := fields.Set{}
		if a.InvolvedKind != "" {
			sel["involvedObject.kind"] = a.InvolvedKind
		}
		if a.InvolvedName != "" {
			sel["involvedObject.name"] = a.InvolvedName
		}
		list, err := s.kube.CoreV1().Events(a.Namespace).List(ctx, metav1.ListOptions{FieldSelector: sel.AsSelector().String(), Limit: 1000})
		if err != nil {
			return nil, err
		}
		var items []corev1.Event
		for _, e := range list.Items {
			if (a.InvolvedKind == "" || e.InvolvedObject.Kind == a.InvolvedKind) && (a.InvolvedName == "" || e.InvolvedObject.Name == a.InvolvedName) {
				items = append(items, e)
			}
		}
		sort.SliceStable(items, func(i, j int) bool {
			ti, tj := eventTime(&items[i]), eventTime(&items[j])
			if !ti.Equal(tj) {
				return ti.After(tj)
			}
			return items[i].Name < items[j].Name
		})
		truncated := list.Continue != "" || len(items) > maxEvents
		if len(items) > maxEvents {
			items = items[:maxEvents]
		}
		b := s.builder(a.Namespace)
		rows := make([]map[string]any, 0, len(items))
		for i := range items {
			rows = append(rows, b.event(&items[i]))
		}
		in.lines, in.red = len(rows), b.red
		return Result{"namespace": a.Namespace, "events": rows, "truncated": truncated}, nil
	})
}

func (s *Server) listWorkloads(ctx context.Context, ns, kind string) ([]workload, bool, error) {
	opts := metav1.ListOptions{Limit: maxWorkloads}
	var out []workload
	cont := ""
	switch kind {
	case "deployment":
		l, err := s.kube.AppsV1().Deployments(ns).List(ctx, opts)
		if err != nil {
			return nil, false, err
		}
		for i := range l.Items {
			out = append(out, fromDeployment(&l.Items[i]))
		}
		cont = l.Continue
	case "statefulset":
		l, err := s.kube.AppsV1().StatefulSets(ns).List(ctx, opts)
		if err != nil {
			return nil, false, err
		}
		for i := range l.Items {
			out = append(out, fromStatefulSet(&l.Items[i]))
		}
		cont = l.Continue
	case "daemonset":
		l, err := s.kube.AppsV1().DaemonSets(ns).List(ctx, opts)
		if err != nil {
			return nil, false, err
		}
		for i := range l.Items {
			out = append(out, fromDaemonSet(&l.Items[i]))
		}
		cont = l.Continue
	case "replicaset":
		l, err := s.kube.AppsV1().ReplicaSets(ns).List(ctx, opts)
		if err != nil {
			return nil, false, err
		}
		for i := range l.Items {
			out = append(out, fromReplicaSet(&l.Items[i]))
		}
		cont = l.Continue
	}
	sort.Slice(out, func(i, j int) bool { return out[i].meta.Name < out[j].meta.Name })
	truncated := cont != "" || len(out) > maxWorkloads
	if len(out) > maxWorkloads {
		out = out[:maxWorkloads]
	}
	return out, truncated, nil
}

func (s *Server) getWorkload(ctx context.Context, ns, kind, name string) (workload, error) {
	g := metav1.GetOptions{}
	switch kind {
	case "deployment":
		o, err := s.kube.AppsV1().Deployments(ns).Get(ctx, name, g)
		if err != nil {
			return workload{}, err
		}
		return fromDeployment(o), nil
	case "statefulset":
		o, err := s.kube.AppsV1().StatefulSets(ns).Get(ctx, name, g)
		if err != nil {
			return workload{}, err
		}
		return fromStatefulSet(o), nil
	case "daemonset":
		o, err := s.kube.AppsV1().DaemonSets(ns).Get(ctx, name, g)
		if err != nil {
			return workload{}, err
		}
		return fromDaemonSet(o), nil
	default:
		o, err := s.kube.AppsV1().ReplicaSets(ns).Get(ctx, name, g)
		if err != nil {
			return workload{}, err
		}
		return fromReplicaSet(o), nil
	}
}

// WorkloadsList lists workloads of one kind.
func (s *Server) WorkloadsList(ctx context.Context, a WorkloadsListArgs) (Result, error) {
	return s.do(ctx, "workloads_list", a.Namespace, "", false, func() error {
		return firstErr(s.checkNS(a.Namespace, false), workloadKind(a.Kind))
	}, func(ctx context.Context, in *info) (Result, error) {
		items, truncated, err := s.listWorkloads(ctx, a.Namespace, a.Kind)
		if err != nil {
			return nil, err
		}
		b := s.builder(a.Namespace)
		rows := make([]map[string]any, 0, len(items))
		for _, w := range items {
			rows = append(rows, b.workloadRow(w))
		}
		in.lines, in.red = len(rows), b.red
		return Result{"namespace": a.Namespace, "kind": a.Kind, "workloads": rows, "truncated": truncated}, nil
	})
}

// WorkloadsGet returns one workload, built from the field allowlist.
func (s *Server) WorkloadsGet(ctx context.Context, a WorkloadsGetArgs) (Result, error) {
	return s.do(ctx, "workloads_get", a.Namespace, a.Name, false, func() error {
		return firstErr(s.checkNS(a.Namespace, false), workloadKind(a.Kind), checkName("name", a.Name, dnsLabel))
	}, func(ctx context.Context, in *info) (Result, error) {
		w, err := s.getWorkload(ctx, a.Namespace, a.Kind, a.Name)
		if err != nil {
			return nil, err
		}
		b := s.builder(a.Namespace)
		res := Result{"workload": b.workload(w)}
		in.red = b.red
		return res, nil
	})
}

func (s *Server) nodesOn() error {
	if !s.cfg.Nodes {
		return refuse("node tools are switched off on this server")
	}
	return nil
}

// NodesList lists nodes.
func (s *Server) NodesList(ctx context.Context) (Result, error) {
	return s.do(ctx, "nodes_list", "", "", false, s.nodesOn, func(ctx context.Context, in *info) (Result, error) {
		list, err := s.kube.CoreV1().Nodes().List(ctx, metav1.ListOptions{Limit: maxWorkloads})
		if err != nil {
			return nil, err
		}
		b := &builder{sc: s.sc, now: s.now(), status: true}
		items := list.Items
		sort.Slice(items, func(i, j int) bool { return items[i].Name < items[j].Name })
		truncated := list.Continue != "" || len(items) > maxWorkloads
		if len(items) > maxWorkloads {
			items = items[:maxWorkloads]
		}
		rows := make([]map[string]any, 0, len(items))
		for i := range items {
			rows = append(rows, b.node(&items[i], false))
		}
		in.lines, in.red = len(rows), b.red
		return Result{"nodes": rows, "truncated": truncated}, nil
	})
}

// NodesGet returns one node with the messages of its conditions.
func (s *Server) NodesGet(ctx context.Context, a NodesGetArgs) (Result, error) {
	return s.do(ctx, "nodes_get", "", a.Name, false, func() error {
		return firstErr(s.nodesOn(), checkName("name", a.Name, dnsSubdomain))
	}, func(ctx context.Context, in *info) (Result, error) {
		n, err := s.kube.CoreV1().Nodes().Get(ctx, a.Name, metav1.GetOptions{})
		if err != nil {
			return nil, err
		}
		b := &builder{sc: s.sc, now: s.now(), status: true}
		res := Result{"node": b.node(n, true)}
		in.red = b.red
		return res, nil
	})
}
