package main

import (
	"bytes"
	"net/http"
	"strings"
	"testing"
)

func TestSchemaRoutesAreWiredOnlyWithTheFlag(t *testing.T) {
	graph := map[string]string{"KB_ADMIN_TOKEN": "adm", "KB_GRAPH_ENABLED": "true", "KB_GRAPH_EXTRACT_MODEL": "m", "KB_GRAPH_GATEWAY_URL": "http://127.0.0.1:1/v1"}
	put := func(base string) int {
		req, _ := http.NewRequest("PUT", base+"/v1/collections/c/graph/schema", strings.NewReader(`{"version":1,"entityTypes":[{"name":"team"}],"relationTypes":[]}`))
		req.Header.Set("Authorization", "Bearer adm")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	var logs bytes.Buffer
	base, stop := start(t, graph, &logs)
	if c := put(base); c != 404 && c != 405 {
		t.Errorf("schemas off: the route must not exist, got %d", c)
	}
	if err := stop(); err != nil {
		t.Fatal(err)
	}
	on := map[string]string{"KB_GRAPH_SCHEMAS_ENABLED": "true"}
	for k, v := range graph {
		on[k] = v
	}
	base, stop = start(t, on, &logs)
	if c := put(base); c != 200 {
		t.Errorf("schemas on: %d", c)
	}
	if err := stop(); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(logs.String(), `"graph_schemas":true`) {
		t.Errorf("the start log must say schemas are on: %s", logs.String())
	}
}
