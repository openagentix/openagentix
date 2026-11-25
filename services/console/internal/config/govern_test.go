package config

import (
	"strings"
	"testing"
)

func TestGovernNamespacesAreOptionalAndChecked(t *testing.T) {
	m := map[string]string{"CONSOLE_TOKEN_FILE": "/t", "CONSOLE_CATALOG_FILE": "/c", "CONSOLE_POLICY_FILE": "/p", "KUBERNETES_SERVICE_HOST": "10.0.0.1"}
	c, err := Load(env(m))
	if err != nil || c.SchedulesNamespace != "" || c.GateNamespace != "" {
		t.Fatalf("%+v %v", c, err)
	}
	m["CONSOLE_SCHEDULES_NAMESPACE"], m["CONSOLE_GATE_NAMESPACE"] = "openagentix-schedules", "openagentix-governance"
	c, err = Load(env(m))
	if err != nil || c.SchedulesNamespace != "openagentix-schedules" || c.GateNamespace != "openagentix-governance" {
		t.Fatalf("%+v %v", c, err)
	}
	for _, k := range []string{"CONSOLE_SCHEDULES_NAMESPACE", "CONSOLE_GATE_NAMESPACE"} {
		m[k] = "../x"
		if _, err := Load(env(m)); err == nil || !strings.Contains(err.Error(), k) {
			t.Errorf("%s: %v", k, err)
		}
		m[k] = "ok"
	}
}
