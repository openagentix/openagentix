package clusterread

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"strings"
	"sync"
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/client-go/kubernetes/fake"

	"github.com/openagentix/openagentix/services/diagnostics/internal/audit"
)

// Canaries that must never leave the server, whatever field they are in.
// Each one sits in a field that the allowlist does not copy.
const (
	cEnv     = "zzcanary-env-value-0081"
	cHeader  = "zzcanary-probe-header-0082"
	cExec    = "zzcanary-exec-command-0083"
	cAnno    = "zzcanary-annotation-0084"
	cInit    = "zzcanary-init-env-0085"
	cEph     = "zzcanary-ephemeral-env-0086"
	cCSI     = "zzcanary-csi-attribute-0087"
	cTmpl    = "zzcanary-template-env-0088"
	cManaged = "zzcanary-managed-fields-0089"
	cLast    = "zzcanary-last-applied-0090"
	cHook    = "zzcanary-hook-command-0091"
	cHookHdr = "zzcanary-hook-header-0092"
	cHost    = "zzcanary-hostpath-0093"
	cTmplAnn = "zzcanary-template-annotation-0094"
	cAlias   = "zzcanary-host-alias-0095"
	cDNS     = "zzcanary-dns-nameserver-0096"
	cPull    = "zzcanary-pull-secret-0097"
	cSec     = "zzcanary-selinux-level-0098"
	cPHost   = "zzcanary-probe-host-0099"
	cGRPC    = "zzcanary-grpc-service-0100"
	cStatus  = "zzcanary-status-message-0101"
	cPodIP   = "zzcanary-pod-ip-0102"
	cNodeIP  = "zzcanary-node-address-0103"
	cCIDR    = "zzcanary-pod-cidr-0104"
	cProv    = "zzcanary-provider-id-0105"
	cOS      = "zzcanary-os-image-0106"
	cMachine = "zzcanary-machine-id-0107"
)

var droppedCanaries = []string{cEnv, cHeader, cExec, cAnno, cInit, cEph, cCSI, cTmpl, cManaged, cLast, cHook, cHookHdr, cHost, cTmplAnn, cAlias, cDNS, cPull, cSec, cPHost, cGRPC, cStatus, cPodIP, cNodeIP, cCIDR, cProv, cOS, cMachine}

// tok builds a token canary that the scanner knows. They sit in fields that
// the server keeps after redaction, so they must be redacted.
func tok(n int) string {
	return "ghp_" + strings.Repeat("Qx", 10) + strings.Repeat(string(rune('a'+n)), 16)
}

var tokenCanaries = func() []string {
	var out []string
	for i := 0; i < 12; i++ {
		out = append(out, tok(i))
	}
	return out
}()

func assertClean(t *testing.T, what, out string, extra ...string) {
	t.Helper()
	all := append(append(append([]string{}, droppedCanaries...), tokenCanaries...), extra...)
	for _, c := range all {
		for form, v := range map[string]string{
			"plain":  c,
			"base64": base64.StdEncoding.EncodeToString([]byte(c)),
			"hex":    hex.EncodeToString([]byte(c)),
		} {
			if strings.Contains(out, v) {
				t.Errorf("%s: canary %q leaked in %s form", what, c, form)
			}
		}
	}
}

func canarySpec(env string) corev1.PodSpec {
	probe := func(hdr string) *corev1.Probe {
		return &corev1.Probe{ProbeHandler: corev1.ProbeHandler{HTTPGet: &corev1.HTTPGetAction{
			Path: "/healthz", Port: intstr.FromInt32(8080), Host: cPHost,
			HTTPHeaders: []corev1.HTTPHeader{{Name: "Authorization", Value: hdr}},
		}}}
	}
	return corev1.PodSpec{
		NodeName:         "node-1",
		HostAliases:      []corev1.HostAlias{{IP: "10.9.9.9", Hostnames: []string{cAlias}}},
		DNSConfig:        &corev1.PodDNSConfig{Nameservers: []string{cDNS}},
		ImagePullSecrets: []corev1.LocalObjectReference{{Name: cPull}},
		SecurityContext:  &corev1.PodSecurityContext{SELinuxOptions: &corev1.SELinuxOptions{Level: cSec}},
		InitContainers: []corev1.Container{{
			Name: "init", Image: "busybox:1",
			Env: []corev1.EnvVar{{Name: "INIT_SECRET", Value: cInit}},
		}},
		Containers: []corev1.Container{{
			Name: "app", Image: "registry.example/app:1.2",
			Command: []string{"/app", "--password", tok(1)},
			Args:    []string{"--config=/etc/app", "--token", tok(2), "-p", tok(3), "--api-key=" + tok(4)},
			Ports:   []corev1.ContainerPort{{Name: "http", ContainerPort: 8080, Protocol: corev1.ProtocolTCP}},
			Env: []corev1.EnvVar{
				{Name: "PLAIN", Value: env},
				{Name: "FROM_SECRET", ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{LocalObjectReference: corev1.LocalObjectReference{Name: "db-creds"}, Key: "password"}}},
				{Name: "FROM_FIELD", ValueFrom: &corev1.EnvVarSource{FieldRef: &corev1.ObjectFieldSelector{FieldPath: "metadata.name"}}},
			},
			EnvFrom:        []corev1.EnvFromSource{{SecretRef: &corev1.SecretEnvSource{LocalObjectReference: corev1.LocalObjectReference{Name: "bulk-secret"}}}},
			LivenessProbe:  probe(cHeader),
			ReadinessProbe: &corev1.Probe{ProbeHandler: corev1.ProbeHandler{Exec: &corev1.ExecAction{Command: []string{"sh", "-c", "echo " + cExec}}}},
			Lifecycle: &corev1.Lifecycle{
				PostStart: &corev1.LifecycleHandler{Exec: &corev1.ExecAction{Command: []string{"sh", "-c", cHook}}},
				PreStop: &corev1.LifecycleHandler{HTTPGet: &corev1.HTTPGetAction{Path: "/stop", Port: intstr.FromInt32(8080),
					HTTPHeaders: []corev1.HTTPHeader{{Name: "X-Api-Key", Value: cHookHdr}}}},
			},
			Resources: corev1.ResourceRequirements{
				Requests: corev1.ResourceList{corev1.ResourceCPU: mustQty("100m")},
				Limits:   corev1.ResourceList{corev1.ResourceMemory: mustQty("128Mi")},
			},
		}},
		EphemeralContainers: []corev1.EphemeralContainer{{EphemeralContainerCommon: corev1.EphemeralContainerCommon{
			Name: "debugger", Image: "busybox:1", Env: []corev1.EnvVar{{Name: "EPH", Value: cEph}},
		}}},
		Volumes: []corev1.Volume{
			{Name: "csi", VolumeSource: corev1.VolumeSource{CSI: &corev1.CSIVolumeSource{Driver: "csi.example", VolumeAttributes: map[string]string{"secretKey": cCSI}}}},
			{Name: "tls", VolumeSource: corev1.VolumeSource{Secret: &corev1.SecretVolumeSource{SecretName: "tls-cert"}}},
			{Name: "host", VolumeSource: corev1.VolumeSource{HostPath: &corev1.HostPathVolumeSource{Path: "/" + cHost}}},
			{Name: "cfg", VolumeSource: corev1.VolumeSource{ConfigMap: &corev1.ConfigMapVolumeSource{LocalObjectReference: corev1.LocalObjectReference{Name: "app-config"}}}},
		},
	}
}

func canaryPod(ns, name string) *corev1.Pod {
	spec := canarySpec(cEnv)
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name: name, Namespace: ns, Labels: map[string]string{"app": "web"},
			Annotations: map[string]string{
				"note": cAnno,
				"kubectl.kubernetes.io/last-applied-configuration": `{"env":"` + cLast + `"}`,
			},
			ManagedFields:     []metav1.ManagedFieldsEntry{{Manager: cManaged}},
			OwnerReferences:   []metav1.OwnerReference{{Kind: "ReplicaSet", Name: "web-abc", Controller: ptr(true)}},
			CreationTimestamp: metav1.NewTime(testNow.Add(-2 * time.Hour)),
		},
		Spec: spec,
		Status: corev1.PodStatus{
			Phase: corev1.PodRunning, QOSClass: corev1.PodQOSBurstable, Message: cStatus, PodIP: cPodIP, HostIP: cNodeIP,
			StartTime:  &metav1.Time{Time: testNow.Add(-time.Hour)},
			Conditions: []corev1.PodCondition{{Type: corev1.PodReady, Status: corev1.ConditionFalse, Reason: "ContainersNotReady", Message: "containers with unready status: [app] " + tok(5)}},
			ContainerStatuses: []corev1.ContainerStatus{{
				Name: "app", Image: "registry.example/app:1.2", ImageID: "registry.example/app@sha256:" + strings.Repeat("ab", 32),
				RestartCount: 7, Ready: false, Started: ptr(false),
				State: corev1.ContainerState{Waiting: &corev1.ContainerStateWaiting{Reason: "CrashLoopBackOff", Message: "back-off 5m0s restarting failed container, last error: password=" + tok(6)}},
				LastTerminationState: corev1.ContainerState{Terminated: &corev1.ContainerStateTerminated{
					ExitCode: 137, Reason: "OOMKilled", Message: "last lines: token=" + tok(7), FinishedAt: metav1.NewTime(testNow.Add(-time.Minute)),
				}},
			}},
			InitContainerStatuses: []corev1.ContainerStatus{{
				Name: "init", Ready: true,
				State: corev1.ContainerState{Terminated: &corev1.ContainerStateTerminated{ExitCode: 0, Reason: "Completed", Message: "init said " + tok(8)}},
			}},
		},
	}
}

func canaryWorkloads(ns string) []runtime.Object {
	meta := func(name string) metav1.ObjectMeta {
		return metav1.ObjectMeta{Name: name, Namespace: ns, Labels: map[string]string{"app": name},
			Annotations:   map[string]string{"deployment.kubernetes.io/revision": "3", "note": cAnno, "kubectl.kubernetes.io/last-applied-configuration": cLast},
			ManagedFields: []metav1.ManagedFieldsEntry{{Manager: cManaged}}}
	}
	tmpl := corev1.PodTemplateSpec{
		ObjectMeta: metav1.ObjectMeta{Labels: map[string]string{"app": "x"}, Annotations: map[string]string{"t": cTmplAnn}},
		Spec:       canarySpec(cTmpl),
	}
	sel := &metav1.LabelSelector{MatchLabels: map[string]string{"app": "x"}}
	return []runtime.Object{
		&appsv1.Deployment{ObjectMeta: meta("dep"), Spec: appsv1.DeploymentSpec{Replicas: ptr(int32(3)), Selector: sel, Template: tmpl,
			Strategy: appsv1.DeploymentStrategy{Type: appsv1.RollingUpdateDeploymentStrategyType}},
			Status: appsv1.DeploymentStatus{Replicas: 3, ReadyReplicas: 1, UpdatedReplicas: 2, AvailableReplicas: 1,
				Conditions: []appsv1.DeploymentCondition{{Type: appsv1.DeploymentProgressing, Status: corev1.ConditionFalse, Reason: "ProgressDeadlineExceeded", Message: "stuck with token=" + tok(9)}}}},
		&appsv1.StatefulSet{ObjectMeta: meta("sts"), Spec: appsv1.StatefulSetSpec{Replicas: ptr(int32(2)), Selector: sel, Template: tmpl},
			Status: appsv1.StatefulSetStatus{Replicas: 2, ReadyReplicas: 2, UpdatedReplicas: 2, CurrentRevision: "sts-1"}},
		&appsv1.DaemonSet{ObjectMeta: meta("ds"), Spec: appsv1.DaemonSetSpec{Selector: sel, Template: tmpl},
			Status: appsv1.DaemonSetStatus{DesiredNumberScheduled: 1, NumberReady: 1, UpdatedNumberScheduled: 1, NumberAvailable: 1}},
		&appsv1.ReplicaSet{ObjectMeta: meta("rs"), Spec: appsv1.ReplicaSetSpec{Replicas: ptr(int32(1)), Selector: sel, Template: tmpl},
			Status: appsv1.ReplicaSetStatus{Replicas: 1, ReadyReplicas: 1, AvailableReplicas: 1}},
	}
}

var testNow = time.Date(2026, 11, 27, 12, 0, 0, 0, time.UTC)

func ptr[T any](v T) *T { return &v }

func mustQty(s string) resource.Quantity { return resource.MustParse(s) }

// logRecorder stands in for the pod log API and records the options it got.
type logRecorder struct {
	mu    sync.Mutex
	data  map[string]string // "ns/pod" -> text
	err   error
	calls []corev1.PodLogOptions
	where []string
}

func (l *logRecorder) open(_ context.Context, ns, pod string, o *corev1.PodLogOptions) (io.ReadCloser, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.calls = append(l.calls, *o)
	l.where = append(l.where, ns+"/"+pod)
	if l.err != nil {
		return nil, l.err
	}
	return io.NopCloser(strings.NewReader(l.data[ns+"/"+pod])), nil
}

type rig struct {
	t     *testing.T
	srv   *Server
	kube  *fake.Clientset
	logs  *logRecorder
	audit *bytes.Buffer
	now   *time.Time
}

func testConfig() Config {
	return Config{LogNamespaces: []string{"rca-demo"}, StatusNamespaces: []string{"openagentix-knowledge", "kagent"}, Nodes: true}
}

func newRig(t *testing.T, mod func(*Options), objs ...runtime.Object) *rig {
	t.Helper()
	kube := fake.NewSimpleClientset(objs...)
	r := &rig{t: t, kube: kube, logs: &logRecorder{data: map[string]string{}}, audit: &bytes.Buffer{}}
	now := testNow
	r.now = &now
	o := Options{
		Config: testConfig(), Client: kube, Logs: r.logs.open,
		Audit: audit.New(r.audit, "cluster-read"), Now: func() time.Time { return *r.now },
	}
	if mod != nil {
		mod(&o)
	}
	s, err := NewServer(o)
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	r.srv = s
	return r
}

func (r *rig) apiCalls() int { return len(r.kube.Actions()) }

func js(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}
