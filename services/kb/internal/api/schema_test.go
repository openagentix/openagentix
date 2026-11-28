package api

import (
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"testing"

	"github.com/openagentix/openagentix/services/kb/internal/chunk"
	"github.com/openagentix/openagentix/services/kb/internal/embed"
	"github.com/openagentix/openagentix/services/kb/internal/kb"
	"github.com/openagentix/openagentix/services/kb/internal/store/memory"
)

const schemaPath = "/v1/collections/kg/graph/schema"

const apiSchema = `{"version":1,"entityTypes":[{"name":"team","key":"[A-Z][a-z]+"},{"name":"service","key":"[A-Z][a-z]+"},{"name":"person"}],
"relationTypes":[{"name":"owns","from":["team"],"to":["service"]},{"name":"escalates_to","from":["team"],"to":["person"]}]}`

func schemaHandler(t *testing.T, graphOn, schemasOn bool) http.Handler {
	t.Helper()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	svc := &kb.Service{Store: memory.New(0), Embedder: embed.None{}, Chunk: chunk.Options{MaxChars: 200}, Log: log}
	if graphOn {
		svc.Graph = &kb.GraphOptions{WindowChars: 2400, PromptVersion: "v1", Schemas: schemasOn}
	}
	return New(svc, Config{AdminToken: "tok"}, log)
}

func TestSchemaRoutesNeedTheTokenAndTheFlag(t *testing.T) {
	h := schemaHandler(t, true, true)
	for _, m := range []string{"PUT", "GET", "DELETE"} {
		if rec := do(h, m, schemaPath, "", apiSchema); rec.Code != 401 {
			t.Errorf("%s with no token: %d", m, rec.Code)
		}
		if rec := do(h, m, schemaPath, "wrong", apiSchema); rec.Code != 401 {
			t.Errorf("%s with a wrong token: %d", m, rec.Code)
		}
	}
	for name, h := range map[string]http.Handler{"graph off": schemaHandler(t, false, false), "schemas off": schemaHandler(t, true, false)} {
		for _, m := range []string{"PUT", "GET", "DELETE"} {
			if rec := do(h, m, schemaPath, "tok", apiSchema); rec.Code != 404 && rec.Code != 405 {
				t.Errorf("%s, %s: the route must not exist, got %d", name, m, rec.Code)
			}
		}
	}
}

func TestSchemaLifecycle(t *testing.T) {
	h := schemaHandler(t, true, true)
	rec := do(h, "PUT", schemaPath, "tok", apiSchema)
	var put struct {
		Collection    string
		Version       int
		SHA256        string
		Changed       bool
		EntityTypes   int `json:"entity_types"`
		RelationTypes int `json:"relation_types"`
	}
	if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &put) != nil || put.Collection != "kg" || put.Version != 1 || len(put.SHA256) != 64 || !put.Changed || put.EntityTypes != 3 || put.RelationTypes != 2 {
		t.Fatalf("put: %d %s", rec.Code, rec.Body)
	}
	if rec = do(h, "PUT", schemaPath, "tok", strings.ReplaceAll(apiSchema, "\n", "")); rec.Code != 200 || !strings.Contains(rec.Body.String(), `"changed":false`) {
		t.Fatalf("the same body again: %d %s", rec.Code, rec.Body)
	}
	rec = do(h, "GET", schemaPath, "tok", "")
	var got struct {
		Collection string
		Version    int
		SHA256     string
		Body       json.RawMessage
	}
	if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &got) != nil || got.Version != 1 || got.SHA256 != put.SHA256 || !json.Valid(got.Body) || !strings.Contains(string(got.Body), "escalates_to") {
		t.Fatalf("get: %d %s", rec.Code, rec.Body)
	}
	// a body that is not higher in version
	changed := strings.Replace(apiSchema, `{"name":"person"}`, `{"name":"person"},{"name":"event"}`, 1)
	if rec = do(h, "PUT", schemaPath, "tok", changed); rec.Code != 409 || !strings.Contains(rec.Body.String(), "version") {
		t.Fatalf("a version that is not higher: %d %s", rec.Code, rec.Body)
	}
	if rec = do(h, "PUT", schemaPath, "tok", strings.Replace(changed, `"version":1`, `"version":2`, 1)); rec.Code != 200 {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	if rec = do(h, "DELETE", schemaPath, "tok", ""); rec.Code != 204 {
		t.Fatalf("delete: %d %s", rec.Code, rec.Body)
	}
	if rec = do(h, "DELETE", schemaPath, "tok", ""); rec.Code != 404 {
		t.Fatalf("second delete: %d", rec.Code)
	}
	if rec = do(h, "GET", schemaPath, "tok", ""); rec.Code != 404 {
		t.Fatalf("get after delete: %d", rec.Code)
	}
}

func TestSchemaBodyRules(t *testing.T) {
	h := schemaHandler(t, true, true)
	if rec := do(h, "PUT", schemaPath, "tok", `{"version":1`); rec.Code != 400 {
		t.Errorf("not JSON: %d", rec.Code)
	}
	if rec := do(h, "PUT", schemaPath, "tok", strings.Replace(apiSchema, `"version":1`, `"version":1,"extra":1`, 1)); rec.Code != 400 || !strings.Contains(rec.Body.String(), "extra") {
		t.Errorf("unknown field: %d %s", rec.Code, rec.Body)
	}
	big := `{"version":1,"entityTypes":[{"name":"aa","description":"` + strings.Repeat("d", 70000) + `"}],"relationTypes":[]}`
	if rec := do(h, "PUT", schemaPath, "tok", big); rec.Code != 413 {
		t.Errorf("over 64 KiB: %d", rec.Code)
	}
	if rec := do(h, "PUT", "/v1/collections/bad%20name/graph/schema", "tok", apiSchema); rec.Code != 400 {
		t.Errorf("bad collection: %d", rec.Code)
	}
	rec := do(h, "PUT", schemaPath, "tok", strings.Replace(apiSchema, `"key":"[A-Z][a-z]+"`, `"key":"SECRET-KEY-TEXT("`, 1))
	if rec.Code != 400 || strings.Contains(rec.Body.String(), "SECRET-KEY-TEXT") {
		t.Errorf("a bad key: %d %s", rec.Code, rec.Body)
	}
}

func TestFactSetRefusedBySchemaNamesTheViolationsAndStoresNothing(t *testing.T) {
	h := schemaHandler(t, true, true)
	if rec := do(h, "PUT", schemaPath, "tok", apiSchema); rec.Code != 200 {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	good := `{"entities":[{"name":"Basalt","type":"team"},{"name":"Orion","type":"service"}],"relations":[{"source":"Basalt","predicate":"owns","target":"Orion"}]}`
	if rec := do(h, "PUT", "/v1/collections/kg/graph/factsets/ok", "tok", good); rec.Code != 200 {
		t.Fatalf("a fitting set: %d %s", rec.Code, rec.Body)
	}
	var ents []string
	for i := 0; i < 25; i++ {
		ents = append(ents, fmt.Sprintf(`{"name":"SECRETNAME%02d","type":"team"}`, i)) // the key refuses them: digits, upper case
	}
	bad := `{"entities":[` + strings.Join(ents, ",") + `],"relations":[]}`
	rec := do(h, "PUT", "/v1/collections/kg/graph/factsets/bad", "tok", bad)
	var body struct {
		Error      string
		Violations []struct{ At, Rule string }
		More       int
	}
	if rec.Code != 422 || json.Unmarshal(rec.Body.Bytes(), &body) != nil || len(body.Violations) != 20 || body.More != 5 {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	if body.Violations[0].At != "entities[0]" || body.Violations[0].Rule != "key" {
		t.Fatalf("%+v", body.Violations[0])
	}
	if strings.Contains(rec.Body.String(), "SECRETNAME") {
		t.Fatalf("the answer repeats what the operator wrote: %s", rec.Body)
	}
	if rec = do(h, "GET", "/v1/collections/kg/graph/factsets/bad", "tok", ""); rec.Code != 404 {
		t.Fatalf("nothing is stored: %d", rec.Code)
	}
}

func TestSchemaChangeThatTheFactsBreakIsA409WithTheSameList(t *testing.T) {
	h := schemaHandler(t, true, true)
	if rec := do(h, "PUT", "/v1/collections/kg/graph/factsets/org", "tok", `{"entities":[{"name":"Basalt","type":"team"},{"name":"Orion","type":"service"}],"relations":[{"source":"Basalt","predicate":"owns","target":"Orion"}]}`); rec.Code != 200 {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	noOwns := `{"version":1,"entityTypes":[{"name":"team"},{"name":"service"}],"relationTypes":[{"name":"runs","from":["team"],"to":["service"]}]}`
	rec := do(h, "PUT", schemaPath, "tok", noOwns)
	var body struct {
		Error      string
		Violations []struct{ At, Rule string }
		More       int
	}
	if rec.Code != 409 || json.Unmarshal(rec.Body.Bytes(), &body) != nil || len(body.Violations) != 1 || body.Violations[0].At != "factsets/org/relations[0]" || body.Violations[0].Rule != "predicate" {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	if rec = do(h, "GET", schemaPath, "tok", ""); rec.Code != 404 {
		t.Fatalf("a refused change stores nothing: %d", rec.Code)
	}
}
