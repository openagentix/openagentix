package server_test

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/openagentix/openagentix/services/console/internal/backend"
	"github.com/openagentix/openagentix/services/console/internal/govern"
	"github.com/openagentix/openagentix/services/console/internal/server"
)

type fakeSched struct {
	l   govern.ScheduleList
	err error
}

func (f fakeSched) Schedules(context.Context) (govern.ScheduleList, error) { return f.l, f.err }

type fakeAccess struct {
	l   govern.AccessList
	err error
}

func (f fakeAccess) Access(context.Context) (govern.AccessList, error) { return f.l, f.err }

func withGovern(s govern.ScheduleSource, a govern.AccessSource) func(*rigOpt) {
	return func(o *rigOpt) {
		prev := o.mod
		o.mod = func(so *server.Options) {
			if prev != nil {
				prev(so)
			}
			so.Schedules, so.Access = s, a
		}
	}
}

func TestSchedulesAndAccessRoutes(t *testing.T) {
	r := newRig(t, withGovern(
		fakeSched{l: govern.ScheduleList{Configured: true, Namespace: "s", Items: []govern.Schedule{{Name: "daily", Agent: "assistant", Cron: "0 7 * * *", State: "active"}}}},
		fakeAccess{l: govern.AccessList{Configured: true, Namespace: "g", Items: []govern.Caller{{Name: "bridge", Source: "chart", Agents: []string{"kagent/assistant"}, UserIDRule: "prefix", Methods: []string{"SendMessage"}}}}},
	))
	resp, b := r.do(t, "GET", "/api/v1/schedules", nil)
	if resp.StatusCode != 200 || !strings.Contains(string(b), `"name":"daily"`) || !strings.Contains(string(b), `"configured":true`) {
		t.Fatalf("%d %s", resp.StatusCode, b)
	}
	resp, b = r.do(t, "GET", "/api/v1/access", nil)
	if resp.StatusCode != 200 || !strings.Contains(string(b), `"userIdRule":"prefix"`) {
		t.Fatalf("%d %s", resp.StatusCode, b)
	}
	for _, p := range []string{"/api/v1/schedules", "/api/v1/access"} {
		if resp, _ = r.do(t, "GET", p, nil, "Authorization", ""); resp.StatusCode != 401 {
			t.Errorf("%s without a token: %d", p, resp.StatusCode)
		}
		if resp, _ = r.do(t, "POST", p, "{}"); resp.StatusCode == 200 || resp.StatusCode == 201 {
			t.Errorf("%s accepts POST: %d", p, resp.StatusCode)
		}
	}
}

func TestSchedulesAndAccessNotConfiguredAnswerEmptyLists(t *testing.T) {
	r := newRig(t)
	for _, p := range []string{"/api/v1/schedules", "/api/v1/access"} {
		resp, b := r.do(t, "GET", p, nil)
		if resp.StatusCode != 200 || !strings.Contains(string(b), `"configured":false`) || !strings.Contains(string(b), `"items":[]`) {
			t.Fatalf("%s: %d %s", p, resp.StatusCode, b)
		}
	}
}

func TestSchedulesAndAccessErrorsKeepUpstreamTextOut(t *testing.T) {
	be := backend.Errf(502, "cluster_error", "Could not read the schedules: the Kubernetes API answered 403.")
	be.Detail = "upstream says SECRET-DETAIL"
	r := newRig(t, withGovern(fakeSched{err: be}, fakeAccess{err: errors.New("dial tcp 10.0.0.1: SECRET-DIAL")}))
	resp, b := r.do(t, "GET", "/api/v1/schedules", nil)
	if resp.StatusCode != 502 || strings.Contains(string(b), "SECRET") || !strings.Contains(string(b), "Request id:") {
		t.Fatalf("%d %s", resp.StatusCode, b)
	}
	if !strings.Contains(r.logs.String(), "SECRET-DETAIL") {
		t.Errorf("the detail is not in the log: %s", r.logs.String())
	}
	resp, b = r.do(t, "GET", "/api/v1/access", nil)
	if resp.StatusCode != 500 || strings.Contains(string(b), "SECRET") {
		t.Fatalf("%d %s", resp.StatusCode, b)
	}
}
