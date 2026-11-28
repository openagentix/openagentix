package config

import (
	"strings"
	"testing"
)

func TestGraphSchemasSetting(t *testing.T) {
	graphOn := map[string]string{"KB_GRAPH_ENABLED": "true", "KB_GRAPH_EXTRACT_MODEL": "m", "KB_GRAPH_GATEWAY_URL": "http://gw/v1"}
	with := func(extra map[string]string) map[string]string {
		m := map[string]string{}
		for k, v := range graphOn {
			m[k] = v
		}
		for k, v := range extra {
			m[k] = v
		}
		return m
	}
	c, err := Load(env(graphOn))
	if err != nil || c.Graph.Schemas {
		t.Fatalf("off by default: %+v %v", c.Graph, err)
	}
	if c, err = Load(env(with(map[string]string{"KB_GRAPH_SCHEMAS_ENABLED": "true"}))); err != nil || !c.Graph.Schemas {
		t.Fatalf("%+v %v", c.Graph, err)
	}
	if c, err = Load(env(with(map[string]string{"KB_GRAPH_SCHEMAS_ENABLED": "false"}))); err != nil || c.Graph.Schemas {
		t.Fatalf("%+v %v", c.Graph, err)
	}
	if _, err = Load(env(with(map[string]string{"KB_GRAPH_SCHEMAS_ENABLED": "maybe"}))); err == nil || !strings.Contains(err.Error(), "KB_GRAPH_SCHEMAS_ENABLED") {
		t.Fatalf("%v", err)
	}
	if _, err = Load(env(map[string]string{"KB_GRAPH_SCHEMAS_ENABLED": "true"})); err == nil || !strings.Contains(err.Error(), "KB_GRAPH_ENABLED") {
		t.Fatalf("schemas need the graph: %v", err)
	}
}
