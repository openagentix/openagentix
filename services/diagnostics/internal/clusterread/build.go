package clusterread

import (
	"reflect"
	"sort"
	"strconv"
	"strings"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/openagentix/openagentix/services/diagnostics/internal/redact"
)

// Result is a tool result: JSON-ready, built only from allowlisted fields.
type Result map[string]any

const (
	maxText  = 512
	maxName  = 253
	maxArg   = 512
	maxLine  = 2048
	preCut   = 4096
	maxShort = 128
)

// builder copies fields from API objects into results. Every string it copies
// goes through s, which strips control characters, redacts, and cuts.
type builder struct {
	sc     *redact.Scanner
	now    time.Time
	status bool // the namespace is status only
	red    int  // redactions so far
}

func (b *builder) s(v string, max int) string {
	v = redact.StripControl(v)
	if len(v) > preCut {
		v = v[:preCut]
	}
	out, n := b.sc.Scrub(v)
	b.red += n
	return redact.Cut(out, max)
}

func (b *builder) text(v string) string {
	return b.s(strings.NewReplacer("\r\n", " ", "\n", " ", "\r", " ").Replace(v), maxText)
}

func (b *builder) name(v string) string  { return b.s(v, maxName) }
func (b *builder) short(v string) string { return b.s(v, maxShort) }

func (b *builder) when(t metav1.Time) any {
	if t.IsZero() {
		return nil
	}
	return t.UTC().Format(time.RFC3339)
}

func (b *builder) age(t metav1.Time) any {
	if t.IsZero() {
		return nil
	}
	return int64(b.now.Sub(t.Time).Seconds())
}

func (b *builder) strMap(m map[string]string) map[string]string {
	if len(m) == 0 {
		return nil
	}
	out := make(map[string]string, len(m))
	for k, v := range m {
		out[b.s(k, maxShort)] = b.s(v, maxShort)
	}
	return out
}

// annotationNames lists annotation names, never values.
func (b *builder) annotationNames(m map[string]string) []string {
	if len(m) == 0 {
		return nil
	}
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, b.s(k, maxShort))
	}
	sort.Strings(out)
	return out
}

func (b *builder) owners(refs []metav1.OwnerReference) []map[string]any {
	var out []map[string]any
	for _, r := range refs {
		out = append(out, map[string]any{"kind": b.short(r.Kind), "name": b.name(r.Name), "controller": r.Controller != nil && *r.Controller})
	}
	return out
}

func ownerString(refs []metav1.OwnerReference, b *builder) string {
	for _, r := range refs {
		if r.Controller != nil && *r.Controller {
			return b.short(r.Kind) + "/" + b.name(r.Name)
		}
	}
	if len(refs) > 0 {
		return b.short(refs[0].Kind) + "/" + b.name(refs[0].Name)
	}
	return ""
}

// message is a condition or event text: kept after redaction, in the field named untrusted_text.
func (b *builder) withText(m map[string]any, msg string) map[string]any {
	if msg != "" {
		m["untrusted_text"] = b.text(msg)
	}
	return m
}

// ---- pods ----

func (b *builder) podConditions(cs []corev1.PodCondition) []map[string]any {
	var out []map[string]any
	for _, c := range cs {
		out = append(out, b.withText(map[string]any{"type": b.short(string(c.Type)), "status": b.short(string(c.Status)), "reason": b.short(c.Reason)}, c.Message))
	}
	return out
}

func (b *builder) podRow(p *corev1.Pod) map[string]any {
	ready := 0
	reason := ""
	for _, cs := range p.Status.ContainerStatuses {
		if cs.Ready {
			ready++
		}
		if reason == "" {
			switch {
			case cs.State.Waiting != nil:
				reason = cs.State.Waiting.Reason
			case cs.State.Terminated != nil && cs.State.Terminated.ExitCode != 0:
				reason = cs.State.Terminated.Reason
			}
		}
	}
	restarts := int32(0)
	for _, cs := range p.Status.ContainerStatuses {
		restarts += cs.RestartCount
	}
	row := map[string]any{
		"name": b.name(p.Name), "phase": b.short(string(p.Status.Phase)),
		"ready": strconv.Itoa(ready) + "/" + strconv.Itoa(len(p.Spec.Containers)), "restarts": restarts,
		"reason": b.short(reason), "node": b.name(p.Spec.NodeName), "age_seconds": b.age(p.CreationTimestamp), "owner": ownerString(p.OwnerReferences, b),
	}
	return row
}

func (b *builder) pod(p *corev1.Pod) map[string]any {
	out := map[string]any{
		"name": b.name(p.Name), "namespace": b.name(p.Namespace), "labels": b.strMap(p.Labels), "owner_references": b.owners(p.OwnerReferences),
		"node": b.name(p.Spec.NodeName), "phase": b.short(string(p.Status.Phase)), "qos_class": b.short(string(p.Status.QOSClass)),
		"start_time": b.startTime(p.Status.StartTime), "conditions": b.podConditions(p.Status.Conditions),
		"annotation_names": b.annotationNames(p.Annotations),
	}
	for k, v := range b.podSpec(&p.Spec, p.Status.InitContainerStatuses, p.Status.ContainerStatuses, p.Status.EphemeralContainerStatuses) {
		out[k] = v
	}
	return out
}

func (b *builder) startTime(t *metav1.Time) any {
	if t == nil {
		return nil
	}
	return b.when(*t)
}

// podSpec builds the containers and volumes of a pod or of a workload template.
func (b *builder) podSpec(spec *corev1.PodSpec, initSt, st, ephSt []corev1.ContainerStatus) map[string]any {
	out := map[string]any{}
	build := func(list []corev1.Container, statuses []corev1.ContainerStatus) []map[string]any {
		var res []map[string]any
		for i := range list {
			var cs *corev1.ContainerStatus
			for j := range statuses {
				if statuses[j].Name == list[i].Name {
					cs = &statuses[j]
				}
			}
			res = append(res, b.container(&list[i], cs))
		}
		return res
	}
	out["containers"] = build(spec.Containers, st)
	if len(spec.InitContainers) > 0 {
		out["init_containers"] = build(spec.InitContainers, initSt)
	}
	if len(spec.EphemeralContainers) > 0 {
		eph := make([]corev1.Container, len(spec.EphemeralContainers))
		for i, e := range spec.EphemeralContainers {
			eph[i] = corev1.Container(e.EphemeralContainerCommon)
		}
		out["ephemeral_containers"] = build(eph, ephSt)
	}
	var vols []map[string]any
	for _, v := range spec.Volumes {
		vols = append(vols, b.volume(v))
	}
	if vols != nil {
		out["volumes"] = vols
	}
	return out
}

func (b *builder) volume(v corev1.Volume) map[string]any {
	m := map[string]any{"name": b.name(v.Name), "type": "unknown"}
	rv := reflect.ValueOf(v.VolumeSource)
	for i := 0; i < rv.NumField(); i++ {
		if f := rv.Field(i); f.Kind() == reflect.Ptr && !f.IsNil() {
			m["type"] = b.short(strings.Split(rv.Type().Field(i).Tag.Get("json"), ",")[0])
			break
		}
	}
	switch {
	case v.Secret != nil:
		m["object"] = b.name(v.Secret.SecretName)
	case v.ConfigMap != nil:
		m["object"] = b.name(v.ConfigMap.Name)
	case v.PersistentVolumeClaim != nil:
		m["object"] = b.name(v.PersistentVolumeClaim.ClaimName)
	}
	return m
}

func (b *builder) container(c *corev1.Container, cs *corev1.ContainerStatus) map[string]any {
	m := map[string]any{"name": b.short(c.Name), "image": b.s(c.Image, maxText)}
	if len(c.Ports) > 0 {
		var ports []map[string]any
		for _, p := range c.Ports {
			ports = append(ports, map[string]any{"name": b.short(p.Name), "container_port": p.ContainerPort, "protocol": b.short(string(p.Protocol))})
		}
		m["ports"] = ports
	}
	if r := b.resources(c.Resources); r != nil {
		m["resources"] = r
	}
	probes := map[string]any{}
	for name, p := range map[string]*corev1.Probe{"liveness": c.LivenessProbe, "readiness": c.ReadinessProbe, "startup": c.StartupProbe} {
		if p != nil {
			probes[name] = b.handler(&p.ProbeHandler)
		}
	}
	if len(probes) > 0 {
		m["probes"] = probes
	}
	if c.Lifecycle != nil {
		lc := map[string]any{}
		if h := c.Lifecycle.PostStart; h != nil {
			lc["post_start"] = b.lifecycle(h)
		}
		if h := c.Lifecycle.PreStop; h != nil {
			lc["pre_stop"] = b.lifecycle(h)
		}
		m["lifecycle"] = lc
	}
	if env := b.env(c.Env); env != nil {
		m["env"] = env
	}
	var envFrom []map[string]any
	for _, e := range c.EnvFrom {
		switch {
		case e.SecretRef != nil:
			envFrom = append(envFrom, map[string]any{"type": "secret", "object": b.name(e.SecretRef.Name)})
		case e.ConfigMapRef != nil:
			envFrom = append(envFrom, map[string]any{"type": "config_map", "object": b.name(e.ConfigMapRef.Name)})
		}
	}
	if envFrom != nil {
		m["env_from"] = envFrom
	}
	untrusted := map[string]any{}
	if b.status {
		m["command_count"] = len(c.Command)
		m["args_count"] = len(c.Args)
	} else {
		if len(c.Command) > 0 {
			untrusted["command"] = b.argv(c.Command)
		}
		if len(c.Args) > 0 {
			untrusted["args"] = b.argv(c.Args)
		}
	}
	if len(untrusted) > 0 {
		m["untrusted_text"] = untrusted
	}
	if cs != nil {
		m["image_id"] = b.s(cs.ImageID, maxText)
		m["ready"] = cs.Ready
		if cs.Started != nil {
			m["started"] = *cs.Started
		}
		m["restart_count"] = cs.RestartCount
		if st := b.state(cs.State); st != nil {
			m["state"] = st
		}
		if st := b.state(cs.LastTerminationState); st != nil {
			m["last_state"] = st
		}
	}
	return m
}

func (b *builder) resources(r corev1.ResourceRequirements) map[string]any {
	conv := func(l corev1.ResourceList) map[string]string {
		if len(l) == 0 {
			return nil
		}
		o := map[string]string{}
		for k, v := range l {
			o[b.short(string(k))] = b.short(v.String())
		}
		return o
	}
	out := map[string]any{}
	if x := conv(r.Requests); x != nil {
		out["requests"] = x
	}
	if x := conv(r.Limits); x != nil {
		out["limits"] = x
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// handler describes a probe by type, port and path only: never headers, never an exec command.
func (b *builder) handler(h *corev1.ProbeHandler) map[string]any {
	switch {
	case h.HTTPGet != nil:
		return map[string]any{"type": "http_get", "port": b.short(h.HTTPGet.Port.String()), "path": b.s(h.HTTPGet.Path, maxArg)}
	case h.TCPSocket != nil:
		return map[string]any{"type": "tcp_socket", "port": b.short(h.TCPSocket.Port.String())}
	case h.GRPC != nil:
		return map[string]any{"type": "grpc", "port": h.GRPC.Port}
	case h.Exec != nil:
		return map[string]any{"type": "exec"}
	}
	return map[string]any{"type": "unknown"}
}

func (b *builder) lifecycle(h *corev1.LifecycleHandler) map[string]any {
	switch {
	case h.HTTPGet != nil:
		return map[string]any{"type": "http_get", "port": b.short(h.HTTPGet.Port.String()), "path": b.s(h.HTTPGet.Path, maxArg)}
	case h.TCPSocket != nil:
		return map[string]any{"type": "tcp_socket", "port": b.short(h.TCPSocket.Port.String())}
	case h.Exec != nil:
		return map[string]any{"type": "exec"}
	case h.Sleep != nil:
		return map[string]any{"type": "sleep"}
	}
	return map[string]any{"type": "unknown"}
}

// env lists variable names and, for references, the source kind, object and key. Never a value.
func (b *builder) env(vars []corev1.EnvVar) []map[string]any {
	var out []map[string]any
	for _, e := range vars {
		m := map[string]any{"name": b.short(e.Name)}
		if v := e.ValueFrom; v != nil {
			switch {
			case v.SecretKeyRef != nil:
				m["from"], m["object"], m["key"] = "secret_key_ref", b.name(v.SecretKeyRef.Name), b.short(v.SecretKeyRef.Key)
			case v.ConfigMapKeyRef != nil:
				m["from"], m["object"], m["key"] = "config_map_key_ref", b.name(v.ConfigMapKeyRef.Name), b.short(v.ConfigMapKeyRef.Key)
			case v.FieldRef != nil:
				m["from"] = "field_ref"
			case v.ResourceFieldRef != nil:
				m["from"] = "resource_field_ref"
			default:
				m["from"] = "other"
			}
		}
		out = append(out, m)
	}
	return out
}

// argv redacts a command line: each element after redaction and cut at 512
// bytes, with the element after a secret-like flag replaced.
func (b *builder) argv(in []string) []string {
	out := make([]string, 0, len(in))
	hide := false
	for _, a := range in {
		if hide {
			out = append(out, redact.Marker)
			b.red++
			hide = false
			continue
		}
		v := redact.StripControl(a)
		if len(v) > preCut {
			v = v[:preCut]
		}
		v, n := b.sc.ScrubScript(v)
		b.red += n
		out = append(out, redact.Cut(v, maxArg))
		hide = redact.SecretFlag(a)
	}
	return out
}

// state builds a container state. A terminated message is kept only outside
// status namespaces: with FallbackToLogsOnError the kubelet copies log lines there.
func (b *builder) state(s corev1.ContainerState) map[string]any {
	switch {
	case s.Running != nil:
		return map[string]any{"state": "running", "started_at": b.when(s.Running.StartedAt)}
	case s.Waiting != nil:
		return b.withText(map[string]any{"state": "waiting", "reason": b.short(s.Waiting.Reason)}, s.Waiting.Message)
	case s.Terminated != nil:
		t := s.Terminated
		m := map[string]any{"state": "terminated", "reason": b.short(t.Reason), "exit_code": t.ExitCode, "signal": t.Signal,
			"started_at": b.when(t.StartedAt), "finished_at": b.when(t.FinishedAt)}
		if !b.status {
			b.withText(m, t.Message)
		}
		return m
	}
	return nil
}

// ---- events ----

// containerOutputReasons are event reasons whose message the kubelet fills
// with output of a probe or a hook.
var containerOutputReasons = map[string]bool{"Unhealthy": true, "ProbeWarning": true, "FailedPostStartHook": true, "FailedPreStopHook": true}

func eventTime(e *corev1.Event) time.Time {
	switch {
	case !e.LastTimestamp.IsZero():
		return e.LastTimestamp.Time
	case e.Series != nil && !e.Series.LastObservedTime.IsZero():
		return e.Series.LastObservedTime.Time
	case !e.EventTime.IsZero():
		return e.EventTime.Time
	}
	return e.CreationTimestamp.Time
}

func (b *builder) event(e *corev1.Event) map[string]any {
	count := e.Count
	if e.Series != nil && e.Series.Count > count {
		count = e.Series.Count
	}
	m := map[string]any{
		"type": b.short(e.Type), "reason": b.short(e.Reason), "object": b.short(e.InvolvedObject.Kind) + "/" + b.name(e.InvolvedObject.Name),
		"count": count, "last_time": b.when(metav1.NewTime(eventTime(e))),
	}
	if !e.FirstTimestamp.IsZero() {
		m["first_time"] = b.when(e.FirstTimestamp)
	}
	if b.status && containerOutputReasons[e.Reason] {
		return m
	}
	return b.withText(m, e.Message)
}

// ---- workloads ----

type cond struct{ typ, status, reason, msg string }

type workload struct {
	kind                               string
	meta                               metav1.ObjectMeta
	desired, ready, updated, available int32
	revision                           string
	selector                           *metav1.LabelSelector
	strategy                           string
	conditions                         []cond
	template                           *corev1.PodTemplateSpec
}

// numberOnly returns v when it is a plain number, so that an annotation value never leaves as text.
func numberOnly(v string) string {
	if _, err := strconv.ParseInt(v, 10, 64); err != nil {
		return ""
	}
	return v
}

func replicas(p *int32) int32 {
	if p == nil {
		return 1
	}
	return *p
}

func fromDeployment(d *appsv1.Deployment) workload {
	w := workload{kind: "deployment", meta: d.ObjectMeta, desired: replicas(d.Spec.Replicas), ready: d.Status.ReadyReplicas, updated: d.Status.UpdatedReplicas,
		available: d.Status.AvailableReplicas, revision: numberOnly(d.Annotations["deployment.kubernetes.io/revision"]), selector: d.Spec.Selector, strategy: string(d.Spec.Strategy.Type), template: &d.Spec.Template}
	if ru := d.Spec.Strategy.RollingUpdate; ru != nil {
		if ru.MaxSurge != nil {
			w.strategy += " maxSurge=" + ru.MaxSurge.String()
		}
		if ru.MaxUnavailable != nil {
			w.strategy += " maxUnavailable=" + ru.MaxUnavailable.String()
		}
	}
	for _, c := range d.Status.Conditions {
		w.conditions = append(w.conditions, cond{string(c.Type), string(c.Status), c.Reason, c.Message})
	}
	return w
}

func fromStatefulSet(s *appsv1.StatefulSet) workload {
	w := workload{kind: "statefulset", meta: s.ObjectMeta, desired: replicas(s.Spec.Replicas), ready: s.Status.ReadyReplicas, updated: s.Status.UpdatedReplicas,
		available: s.Status.AvailableReplicas, revision: s.Status.CurrentRevision, selector: s.Spec.Selector, strategy: string(s.Spec.UpdateStrategy.Type), template: &s.Spec.Template}
	for _, c := range s.Status.Conditions {
		w.conditions = append(w.conditions, cond{string(c.Type), string(c.Status), c.Reason, c.Message})
	}
	return w
}

func fromDaemonSet(d *appsv1.DaemonSet) workload {
	w := workload{kind: "daemonset", meta: d.ObjectMeta, desired: d.Status.DesiredNumberScheduled, ready: d.Status.NumberReady, updated: d.Status.UpdatedNumberScheduled,
		available: d.Status.NumberAvailable, revision: numberOnly(d.Annotations["deprecated.daemonset.template.generation"]), selector: d.Spec.Selector, strategy: string(d.Spec.UpdateStrategy.Type), template: &d.Spec.Template}
	for _, c := range d.Status.Conditions {
		w.conditions = append(w.conditions, cond{string(c.Type), string(c.Status), c.Reason, c.Message})
	}
	return w
}

func fromReplicaSet(r *appsv1.ReplicaSet) workload {
	w := workload{kind: "replicaset", meta: r.ObjectMeta, desired: replicas(r.Spec.Replicas), ready: r.Status.ReadyReplicas, updated: r.Status.Replicas,
		available: r.Status.AvailableReplicas, revision: numberOnly(r.Annotations["deployment.kubernetes.io/revision"]), selector: r.Spec.Selector, template: &r.Spec.Template}
	for _, c := range r.Status.Conditions {
		w.conditions = append(w.conditions, cond{string(c.Type), string(c.Status), c.Reason, c.Message})
	}
	return w
}

func (b *builder) workloadRow(w workload) map[string]any {
	var conds []map[string]any
	for _, c := range w.conditions {
		conds = append(conds, b.withText(map[string]any{"type": b.short(c.typ), "status": b.short(c.status), "reason": b.short(c.reason)}, c.msg))
	}
	return map[string]any{
		"name": b.name(w.meta.Name), "kind": w.kind, "desired": w.desired, "ready": w.ready, "updated": w.updated, "available": w.available,
		"revision": b.short(w.revision), "conditions": conds,
	}
}

func (b *builder) workload(w workload) map[string]any {
	m := b.workloadRow(w)
	m["namespace"] = b.name(w.meta.Namespace)
	m["labels"] = b.strMap(w.meta.Labels)
	m["owner_references"] = b.owners(w.meta.OwnerReferences)
	m["annotation_names"] = b.annotationNames(w.meta.Annotations)
	if w.selector != nil {
		m["selector"] = b.s(metav1.FormatLabelSelector(w.selector), maxText)
	}
	if w.strategy != "" {
		m["strategy"] = b.short(w.strategy)
	}
	if w.template != nil {
		t := b.podSpec(&w.template.Spec, nil, nil, nil)
		t["labels"] = b.strMap(w.template.Labels)
		t["annotation_names"] = b.annotationNames(w.template.Annotations)
		m["template"] = t
	}
	return m
}

// ---- nodes ----

func (b *builder) quantities(l corev1.ResourceList) map[string]string {
	o := map[string]string{}
	for k, v := range l {
		o[b.short(string(k))] = b.short(v.String())
	}
	return o
}

func (b *builder) node(n *corev1.Node, full bool) map[string]any {
	pressure := map[string]bool{}
	ready := false
	var conds []map[string]any
	for _, c := range n.Status.Conditions {
		is := c.Status == corev1.ConditionTrue
		switch c.Type {
		case corev1.NodeReady:
			ready = is
		case corev1.NodeMemoryPressure:
			pressure["memory_pressure"] = is
		case corev1.NodeDiskPressure:
			pressure["disk_pressure"] = is
		case corev1.NodePIDPressure:
			pressure["pid_pressure"] = is
		case corev1.NodeNetworkUnavailable:
			pressure["network_unavailable"] = is
		}
		if full {
			conds = append(conds, b.withText(map[string]any{"type": b.short(string(c.Type)), "status": b.short(string(c.Status)), "reason": b.short(c.Reason)}, c.Message))
		}
	}
	var taints []map[string]any
	for _, t := range n.Spec.Taints {
		taints = append(taints, map[string]any{"key": b.short(t.Key), "value": b.short(t.Value), "effect": b.short(string(t.Effect))})
	}
	m := map[string]any{
		"name": b.name(n.Name), "ready": ready, "pressure": pressure, "capacity": b.quantities(n.Status.Capacity),
		"allocatable": b.quantities(n.Status.Allocatable), "taints": taints, "kubelet_version": b.short(n.Status.NodeInfo.KubeletVersion),
	}
	if full {
		m["conditions"] = conds
	}
	return m
}
