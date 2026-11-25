// Package govern reads what governs an agent today, for two read-only pages: the schedules the chart defines (CronJobs)
// and the A2A gate's caller rules (a ConfigMap). It builds its own requests with the console's Kubernetes client, so no
// browser header reaches the API server. It never copies a user id value, a prompt, an environment value other than the
// ones named below, a key or a hash: what it returns is names, agents, methods and the kind of user id rule.
package govern

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strings"

	"github.com/openagentix/openagentix/services/console/internal/backend"
	"github.com/openagentix/openagentix/services/console/internal/kube"
)

// Error is the backend's error type, so the server answers it the same way (its own sentence, the detail in the log only).
type Error = backend.Error

// Schedule is one chart-defined schedule.
type Schedule struct {
	Name              string `json:"name"`
	Agent             string `json:"agent"`
	Cron              string `json:"cron"`
	TimeZone          string `json:"timeZone"`
	ConcurrencyPolicy string `json:"concurrencyPolicy"`
	Timeout           string `json:"timeout"`
	// State is active or suspended. A CronJob has no conditions; the console does not read Jobs, so the outcome of a run is not here.
	State         string `json:"state"`
	Active        int    `json:"active"`
	LastScheduled string `json:"lastScheduled"`
	LastSucceeded string `json:"lastSucceeded"`
	Created       string `json:"created"`
}

// ScheduleList is GET /api/v1/schedules. Configured is false when the console was not told where schedules live.
type ScheduleList struct {
	Configured bool       `json:"configured"`
	Namespace  string     `json:"namespace"`
	Items      []Schedule `json:"items"`
}

// Caller is one rule of the A2A gate. The user id value is never copied: UserIDRule says only whether it is an exact
// value, a prefix or a fixed value.
type Caller struct {
	Name           string   `json:"name"`
	Source         string   `json:"source"` // chart: derived from the bridge, a schedule or a channel binding; values: governance.a2a.callers
	ServiceAccount string   `json:"serviceAccount"`
	Key            bool     `json:"key"`
	Agents         []string `json:"agents"`
	UserIDRule     string   `json:"userIdRule"`
	Methods        []string `json:"methods"`
	Memory         bool     `json:"memory"`
}

// AccessList is GET /api/v1/access.
type AccessList struct {
	Configured bool     `json:"configured"`
	Namespace  string   `json:"namespace"`
	Items      []Caller `json:"items"`
}

// ScheduleSource and AccessSource are what the server needs. A nil source means "not configured".
type ScheduleSource interface {
	Schedules(ctx context.Context) (ScheduleList, error)
}
type AccessSource interface {
	Access(ctx context.Context) (AccessList, error)
}

// DefaultMethods are what the gate allows a caller without its own list (services/a2a-gate/internal/rules).
var DefaultMethods = []string{"SendMessage", "SendStreamingMessage"}

func unexpected(what string, status int, body []byte) *Error {
	var st struct {
		Message string `json:"message"`
		Reason  string `json:"reason"`
	}
	_ = json.Unmarshal(body, &st)
	msg := st.Message
	if len(msg) > 300 {
		msg = msg[:300] + "..."
	}
	e := backend.Errf(http.StatusBadGateway, "cluster_error", "Could not read %s: the Kubernetes API answered %d. Check that the console's Role allows this read.", what, status)
	e.Detail = fmt.Sprintf("upstream status %d reason %q message %q", status, st.Reason, msg)
	return e
}

// KubeSchedules lists the CronJobs the chart labels openagentix.io/schedule in one namespace. Namespace empty: not configured.
type KubeSchedules struct {
	C         *kube.Client
	Namespace string
}

type cronJobList struct {
	Items []struct {
		Metadata struct {
			Name              string `json:"name"`
			CreationTimestamp string `json:"creationTimestamp"`
		} `json:"metadata"`
		Spec struct {
			Schedule          string `json:"schedule"`
			TimeZone          string `json:"timeZone"`
			Suspend           bool   `json:"suspend"`
			ConcurrencyPolicy string `json:"concurrencyPolicy"`
			JobTemplate       struct {
				Spec struct {
					Template struct {
						Spec struct {
							Containers []struct {
								Env []struct {
									Name  string `json:"name"`
									Value string `json:"value"`
								} `json:"env"`
							} `json:"containers"`
						} `json:"spec"`
					} `json:"template"`
				} `json:"spec"`
			} `json:"jobTemplate"`
		} `json:"spec"`
		Status struct {
			Active             []json.RawMessage `json:"active"`
			LastScheduleTime   string            `json:"lastScheduleTime"`
			LastSuccessfulTime string            `json:"lastSuccessfulTime"`
		} `json:"status"`
	} `json:"items"`
}

// agentOf takes the agent name from the end of A2A_URL (.../agents/<namespace>/<agent>). Nothing else of the URL is kept.
func agentOf(u string) string {
	i := strings.LastIndex(u, "/agents/")
	if i < 0 {
		return ""
	}
	parts := strings.Split(strings.Trim(u[i+len("/agents/"):], "/"), "/")
	if len(parts) != 2 {
		return ""
	}
	return parts[1]
}

func (k KubeSchedules) Schedules(ctx context.Context) (ScheduleList, error) {
	out := ScheduleList{Items: []Schedule{}}
	if k.C == nil || k.Namespace == "" {
		return out, nil
	}
	out.Configured, out.Namespace = true, k.Namespace
	q := url.Values{"labelSelector": {"openagentix.io/schedule"}, "limit": {"500"}}
	r, err := k.C.Do(ctx, http.MethodGet, "/apis/batch/v1/namespaces/"+url.PathEscape(k.Namespace)+"/cronjobs", q, "", nil)
	if err != nil {
		return out, err
	}
	if r.Status != http.StatusOK {
		return out, unexpected("the schedules", r.Status, r.Body)
	}
	var l cronJobList
	if err := json.Unmarshal(r.Body, &l); err != nil {
		return out, backend.Errf(http.StatusBadGateway, "cluster_error", "Could not read the schedules: the Kubernetes API sent an answer the console cannot read.")
	}
	for _, c := range l.Items {
		s := Schedule{Name: c.Metadata.Name, Cron: c.Spec.Schedule, TimeZone: c.Spec.TimeZone, ConcurrencyPolicy: c.Spec.ConcurrencyPolicy,
			State: "active", Active: len(c.Status.Active), LastScheduled: c.Status.LastScheduleTime, LastSucceeded: c.Status.LastSuccessfulTime,
			Created: c.Metadata.CreationTimestamp}
		if c.Spec.Suspend {
			s.State = "suspended"
		}
		for _, ct := range c.Spec.JobTemplate.Spec.Template.Spec.Containers {
			for _, e := range ct.Env {
				switch e.Name {
				case "A2A_URL":
					s.Agent = agentOf(e.Value)
				case "A2A_TIMEOUT":
					s.Timeout = e.Value
				}
			}
		}
		out.Items = append(out.Items, s)
	}
	sort.Slice(out.Items, func(i, j int) bool { return out.Items[i].Name < out.Items[j].Name })
	return out, nil
}

// KubeAccess reads the gate's rules ConfigMap (a2a-gate-rules) in one namespace. Namespace empty: not configured.
type KubeAccess struct {
	C         *kube.Client
	Namespace string
}

type gateRules struct {
	Callers []struct {
		Name           string `json:"name"`
		ServiceAccount *struct {
			Namespace string `json:"namespace"`
			Name      string `json:"name"`
		} `json:"serviceAccount"`
		Key    bool     `json:"key"`
		Agents []string `json:"agents"`
		UserID struct {
			Exact  string `json:"exact"`
			Prefix string `json:"prefix"`
			Fixed  string `json:"fixed"`
		} `json:"userId"`
		Methods []string `json:"methods"`
		Memory  bool     `json:"memory"`
	} `json:"callers"`
}

func (k KubeAccess) Access(ctx context.Context) (AccessList, error) {
	out := AccessList{Items: []Caller{}}
	if k.C == nil || k.Namespace == "" {
		return out, nil
	}
	out.Configured, out.Namespace = true, k.Namespace
	r, err := k.C.Do(ctx, http.MethodGet, "/api/v1/namespaces/"+url.PathEscape(k.Namespace)+"/configmaps/a2a-gate-rules", nil, "", nil)
	if err != nil {
		return out, err
	}
	switch r.Status {
	case http.StatusOK:
	case http.StatusNotFound:
		return out, backend.Errf(http.StatusNotFound, "gate_rules_missing", "The gate's rules are not there: the ConfigMap a2a-gate-rules does not exist in namespace %s. Check that governance.a2a.enabled is true.", k.Namespace)
	default:
		return out, unexpected("the gate's access rules", r.Status, r.Body)
	}
	bad := backend.Errf(http.StatusBadGateway, "cluster_error", "Could not read the gate's access rules: the rules file in the ConfigMap is not valid JSON.")
	var cm struct {
		Data map[string]string `json:"data"`
	}
	if err := json.Unmarshal(r.Body, &cm); err != nil {
		return out, bad
	}
	var gr gateRules
	if err := json.Unmarshal([]byte(cm.Data["rules.json"]), &gr); err != nil {
		return out, bad
	}
	for _, c := range gr.Callers {
		x := Caller{Name: c.Name, Source: "values", Key: c.Key, Agents: append([]string{}, c.Agents...), Memory: c.Memory, Methods: append([]string{}, c.Methods...)}
		if c.Name == "bridge" || strings.HasPrefix(c.Name, "schedule-") || strings.HasPrefix(c.Name, "kourier-") {
			x.Source = "chart"
		}
		if c.ServiceAccount != nil {
			x.ServiceAccount = c.ServiceAccount.Namespace + "/" + c.ServiceAccount.Name
		}
		switch {
		case c.UserID.Exact != "":
			x.UserIDRule = "exact"
		case c.UserID.Prefix != "":
			x.UserIDRule = "prefix"
		case c.UserID.Fixed != "":
			x.UserIDRule = "fixed"
		}
		if len(x.Methods) == 0 {
			x.Methods = append([]string{}, DefaultMethods...)
		}
		out.Items = append(out.Items, x)
	}
	sort.Slice(out.Items, func(i, j int) bool { return out.Items[i].Name < out.Items[j].Name })
	return out, nil
}
