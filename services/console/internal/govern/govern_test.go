package govern_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/openagentix/openagentix/services/console/internal/govern"
	"github.com/openagentix/openagentix/services/console/internal/kube"
)

const cronJobs = `{"items":[
 {"metadata":{"name":"daily-digest","creationTimestamp":"2026-11-20T08:00:00Z"},
  "spec":{"schedule":"0 7 * * 1-5","timeZone":"Europe/Berlin","suspend":false,"concurrencyPolicy":"Forbid",
   "jobTemplate":{"spec":{"template":{"spec":{"containers":[{"name":"a2a-call","env":[
     {"name":"A2A_URL","value":"http://a2a-gate.openagentix-governance.svc.cluster.local:8080/agents/kagent/assistant"},
     {"name":"A2A_USER_ID","value":"schedule:daily-digest"},
     {"name":"A2A_TIMEOUT","value":"300s"},
     {"name":"A2A_TOKEN","value":"SECRET-TOKEN-VALUE"}]}]}}}}},
  "status":{"lastScheduleTime":"2026-11-26T06:00:00Z","lastSuccessfulTime":"2026-11-26T06:00:09Z","active":[]}},
 {"metadata":{"name":"paused-one"},"spec":{"schedule":"*/5 * * * *","suspend":true,"concurrencyPolicy":"Allow"},"status":{"active":[{"name":"x"}]}}
]}`

func kubeAgainst(t *testing.T, h http.HandlerFunc) (*kube.Client, *[]string) {
	t.Helper()
	var paths []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.Method+" "+r.URL.Path+"?"+r.URL.RawQuery)
		h(w, r)
	}))
	t.Cleanup(srv.Close)
	tok := filepath.Join(t.TempDir(), "t")
	_ = os.WriteFile(tok, []byte("sa"), 0o600)
	c, err := kube.New(srv.URL, tok, "")
	if err != nil {
		t.Fatal(err)
	}
	return c, &paths
}

func asErr(err error, t **govern.Error) bool {
	e, ok := err.(*govern.Error)
	if ok {
		*t = e
	}
	return ok
}

func TestSchedulesAreReadFromCronJobsAndHoldNoSecretOrUserID(t *testing.T) {
	c, paths := kubeAgainst(t, func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte(cronJobs)) })
	l, err := govern.KubeSchedules{C: c, Namespace: "openagentix-schedules"}.Schedules(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !l.Configured || l.Namespace != "openagentix-schedules" || len(l.Items) != 2 {
		t.Fatalf("%+v", l)
	}
	d := l.Items[0]
	if d.Name != "daily-digest" || d.Agent != "assistant" || d.Cron != "0 7 * * 1-5" || d.TimeZone != "Europe/Berlin" ||
		d.State != "active" || d.Timeout != "300s" || d.LastScheduled != "2026-11-26T06:00:00Z" || d.LastSucceeded != "2026-11-26T06:00:09Z" {
		t.Fatalf("%+v", d)
	}
	p := l.Items[1]
	if p.State != "suspended" || p.Active != 1 || p.Agent != "" {
		t.Fatalf("%+v", p)
	}
	b, _ := json.Marshal(l)
	for _, bad := range []string{"SECRET-TOKEN-VALUE", "schedule:daily-digest", "A2A_TOKEN", "a2a-gate"} {
		if strings.Contains(string(b), bad) {
			t.Errorf("the answer holds %q: %s", bad, b)
		}
	}
	want := "GET /apis/batch/v1/namespaces/openagentix-schedules/cronjobs?"
	if len(*paths) != 1 || !strings.HasPrefix((*paths)[0], want) || !strings.Contains((*paths)[0], "labelSelector=openagentix.io") {
		t.Fatalf("requests: %v", *paths)
	}
}

func TestSchedulesNotConfiguredAndErrors(t *testing.T) {
	l, err := govern.KubeSchedules{}.Schedules(context.Background())
	if err != nil || l.Configured || l.Items == nil || len(l.Items) != 0 {
		t.Fatalf("%+v %v", l, err)
	}
	c, _ := kubeAgainst(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(403)
		_, _ = w.Write([]byte(`{"message":"cronjobs is forbidden: User system:serviceaccount:x"}`))
	})
	_, err = govern.KubeSchedules{C: c, Namespace: "s"}.Schedules(context.Background())
	if err == nil || strings.Contains(err.Error(), "system:serviceaccount") {
		t.Fatalf("%v", err)
	}
	var ge *govern.Error
	if !asErr(err, &ge) || ge.Status != 502 {
		t.Fatalf("%v", err)
	}
}

const rules = `{"callers":[
 {"name":"bridge","serviceAccount":{"namespace":"b","name":"telegram-bridge"},"agents":["kagent/assistant"],"userId":{"prefix":"telegram:"},"methods":["SendMessage"],"memory":true},
 {"name":"schedule-daily-digest","serviceAccount":{"namespace":"s","name":"schedule-daily-digest"},"agents":["kagent/assistant"],"userId":{"exact":"schedule:daily-digest"},"methods":["SendMessage"]},
 {"name":"kourier-hook","key":true,"agents":["kagent/assistant"],"userId":{"fixed":"kourier:hook-PERSONAL-1234"}},
 {"name":"mine","serviceAccount":{"namespace":"apps","name":"caller"},"agents":["kagent/a","kagent/b"],"userId":{"prefix":"app:"}}
]}`

func TestAccessRulesShowNamesAgentsAndMethodsNeverUserIDValues(t *testing.T) {
	c, paths := kubeAgainst(t, func(w http.ResponseWriter, r *http.Request) {
		b, _ := json.Marshal(map[string]any{"data": map[string]string{"rules.json": rules}})
		_, _ = w.Write(b)
	})
	l, err := govern.KubeAccess{C: c, Namespace: "openagentix-governance"}.Access(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !l.Configured || len(l.Items) != 4 {
		t.Fatalf("%+v", l)
	}
	by := map[string]govern.Caller{}
	for _, x := range l.Items {
		by[x.Name] = x
	}
	if b := by["bridge"]; b.Source != "chart" || b.UserIDRule != "prefix" || !b.Memory || b.ServiceAccount != "b/telegram-bridge" || b.Methods[0] != "SendMessage" {
		t.Fatalf("%+v", b)
	}
	if k := by["kourier-hook"]; k.Source != "chart" || !k.Key || k.UserIDRule != "fixed" || k.ServiceAccount != "" || len(k.Methods) != 2 {
		t.Fatalf("default methods expected: %+v", k)
	}
	if m := by["mine"]; m.Source != "values" || len(m.Agents) != 2 {
		t.Fatalf("%+v", m)
	}
	out, _ := json.Marshal(l)
	for _, bad := range []string{"PERSONAL-1234", "telegram:", "schedule:daily-digest", "app:"} {
		if strings.Contains(string(out), bad) {
			t.Errorf("the answer holds the user id value %q: %s", bad, out)
		}
	}
	if len(*paths) != 1 || (*paths)[0] != "GET /api/v1/namespaces/openagentix-governance/configmaps/a2a-gate-rules?" {
		t.Fatalf("requests: %v", *paths)
	}
}

func TestAccessNotConfiguredMissingAndBroken(t *testing.T) {
	l, err := govern.KubeAccess{}.Access(context.Background())
	if err != nil || l.Configured || len(l.Items) != 0 {
		t.Fatalf("%+v %v", l, err)
	}
	c, _ := kubeAgainst(t, func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(404) })
	var ge *govern.Error
	_, err = govern.KubeAccess{C: c, Namespace: "g"}.Access(context.Background())
	if !asErr(err, &ge) || ge.Status != 404 {
		t.Fatalf("%v", err)
	}
	c, _ = kubeAgainst(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"data":{"rules.json":"{not json"}}`))
	})
	_, err = govern.KubeAccess{C: c, Namespace: "g"}.Access(context.Background())
	if !asErr(err, &ge) || ge.Status != 502 {
		t.Fatalf("%v", err)
	}
}
