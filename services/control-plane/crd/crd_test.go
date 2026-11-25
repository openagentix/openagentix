package crd

import (
	"encoding/json"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"testing"

	"github.com/openagentix/openagentix/services/control-plane/internal/api"
)

// The CRD is YAML and the module has no YAML parser, so the test converts it with yq (a dependency of the repo's other
// tests, charts/openagentix/tests/run.sh) and skips when yq is missing.
func load(t *testing.T) map[string]any {
	t.Helper()
	if _, err := exec.LookPath("yq"); err != nil {
		t.Skip("yq not installed")
	}
	out, err := exec.Command("yq", "-c", ".", "agentdefinition.yaml").Output()
	if err != nil {
		t.Fatalf("yq: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal(out, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func dig(t *testing.T, m any, path ...string) any {
	t.Helper()
	for _, p := range path {
		mm, ok := m.(map[string]any)
		if !ok {
			t.Fatalf("not a map at %q", p)
		}
		m, ok = mm[p]
		if !ok {
			t.Fatalf("missing %q in path %v", p, path)
		}
	}
	return m
}

func TestIdentityAndSubresource(t *testing.T) {
	c := load(t)
	spec := dig(t, c, "spec").(map[string]any)
	n := spec["names"].(map[string]any)
	if spec["group"] != "openagentix.io" || spec["scope"] != "Namespaced" || n["kind"] != "AgentDefinition" || n["plural"] != "agentdefinitions" || n["shortNames"].([]any)[0] != "oad" {
		t.Fatalf("%v", spec)
	}
	v := spec["versions"].([]any)[0].(map[string]any)
	if v["name"] != "v1alpha1" || v["served"] != true || v["storage"] != true {
		t.Fatal(v)
	}
	if _, ok := dig(t, v, "subresources").(map[string]any)["status"]; !ok {
		t.Fatal("status subresource")
	}
	var cols []string
	for _, c := range v["additionalPrinterColumns"].([]any) {
		cols = append(cols, c.(map[string]any)["name"].(string))
	}
	if strings.Join(cols, ",") != "Model,Profile,Accepted,Ready,Revision,Suspended,Age" {
		t.Fatalf("%v", cols)
	}
}

func TestLimitsOfTheADR(t *testing.T) {
	c := load(t)
	v := dig(t, c, "spec", "versions").([]any)[0]
	props := dig(t, v, "schema", "openAPIV3Schema", "properties", "spec", "properties")
	num := func(path ...string) float64 { return dig(t, props, path...).(float64) }
	if num("description", "maxLength") != 256 {
		t.Fatal("description")
	}
	if num("instructions", "maxLength") != 16384 || num("instructions", "minLength") != 1 {
		t.Fatal("instructions")
	}
	if num("memory", "properties", "ttlDays", "minimum") != 1 {
		t.Fatal("ttlDays")
	}
	if num("egress", "properties", "allow", "maxItems") != 64 {
		t.Fatal("egress.allow")
	}
	req := dig(t, v, "schema", "openAPIV3Schema", "properties", "spec", "required").([]any)
	if len(req) != 1 || req[0] != "model" {
		t.Fatalf("instructions is no longer required by the schema (exactly one of instructions and instructionsFrom is, by a rule): %v", req)
	}
	rules := dig(t, v, "schema", "openAPIV3Schema", "x-kubernetes-validations").([]any)
	if len(rules) != 2 {
		t.Fatal("name rules")
	}
}

func TestSpecHasNoBackdoorFields(t *testing.T) {
	c := load(t)
	v := dig(t, c, "spec", "versions").([]any)[0]
	props := dig(t, v, "schema", "openAPIV3Schema", "properties", "spec", "properties").(map[string]any)
	for _, f := range []string{"modelConfig", "modelConfigRef", "harness", "harnessImage", "image", "remoteMCPServer", "toolServer", "egressPolicyRef", "namespace", "callers", "gatewayUserId", "budget"} {
		if _, ok := props[f]; ok {
			t.Fatalf("spec must not have %q", f)
		}
	}
}

// Every field the controller writes to status must be in the schema: the API server prunes the rest, and the controller
// would then think it had written something it had not.
func TestEveryStatusFieldTheControllerWritesIsInTheSchema(t *testing.T) {
	c := load(t)
	v := dig(t, c, "spec", "versions").([]any)[0]
	props := dig(t, v, "schema", "openAPIV3Schema", "properties", "status", "properties").(map[string]any)
	written := api.Status{}.Patch()["status"].(map[string]any)
	for k := range written {
		if _, ok := props[k]; !ok {
			t.Errorf("status.%s is written by the controller but missing in the CRD", k)
		}
	}
	ctl := dig(t, props, "controller", "properties").(map[string]any)
	for k := range written["controller"].(map[string]any) {
		if _, ok := ctl[k]; !ok {
			t.Errorf("status.controller.%s is written by the controller but missing in the CRD", k)
		}
	}
	if dig(t, ctl, "appliedSpec", "type") != "string" || dig(t, ctl, "appliedGeneration", "type") != "integer" {
		t.Fatal("appliedSpec is a string (a merge patch replaces it whole), appliedGeneration an integer")
	}
}

func specProps(t *testing.T) map[string]any {
	t.Helper()
	v := dig(t, load(t), "spec", "versions").([]any)[0]
	return dig(t, v, "schema", "openAPIV3Schema", "properties", "spec", "properties").(map[string]any)
}

func TestNewSpecShapes(t *testing.T) {
	p := specProps(t)
	// knowledge and notify are objects that can grow
	for _, f := range [][2]string{{"knowledge", "collections"}, {"notify", "destinations"}} {
		if dig(t, p, f[0], "type") != "object" || dig(t, p, f[0], "properties", "enabled", "type") != "boolean" || dig(t, p, f[0], "properties", f[1], "type") != "array" {
			t.Errorf("%s must be {enabled: boolean, %s: [string]}", f[0], f[1])
		}
	}
	// skills are {name, version?}
	it := dig(t, p, "skills", "items")
	if dig(t, it, "type") != "object" || dig(t, it, "properties", "name", "type") != "string" || dig(t, it, "properties", "version", "type") != "string" {
		t.Fatalf("skills items: %v", it)
	}
	if req := dig(t, it, "required").([]any); len(req) != 1 || req[0] != "name" {
		t.Fatalf("a skill needs a name and no version: %v", req)
	}
	if dig(t, p, "suspend", "type") != "boolean" {
		t.Fatal("spec.suspend")
	}
	// instructionsFrom has a typed shape {configMap: {name, key}}, and is not an open object
	f := dig(t, p, "instructionsFrom")
	if _, open := f.(map[string]any)["x-kubernetes-preserve-unknown-fields"]; open {
		t.Fatal("instructionsFrom must be typed, not opaque")
	}
	cm := dig(t, f, "properties", "configMap")
	if dig(t, cm, "properties", "name", "type") != "string" || dig(t, cm, "properties", "key", "type") != "string" {
		t.Fatalf("%v", cm)
	}
	if req := dig(t, cm, "required").([]any); len(req) != 2 {
		t.Fatalf("name and key are required: %v", req)
	}
	if dig(t, f, "required").([]any)[0] != "configMap" {
		t.Fatal("configMap is required inside instructionsFrom")
	}
	if _, ok := p["instructions"].(map[string]any)["minLength"]; !ok {
		t.Fatal("instructions keeps its length limits")
	}
}

func TestExactlyOneOfInstructionsRule(t *testing.T) {
	v := dig(t, load(t), "spec", "versions").([]any)[0]
	rules := dig(t, v, "schema", "openAPIV3Schema", "properties", "spec", "x-kubernetes-validations").([]any)
	found := false
	for _, r := range rules {
		m := r.(map[string]any)
		if strings.Contains(m["rule"].(string), "has(self.instructions)") && strings.Contains(m["rule"].(string), "has(self.instructionsFrom)") &&
			strings.Contains(m["message"].(string), "exactly one of instructions and instructionsFrom") {
			found = true
		}
	}
	if !found {
		t.Fatalf("rules: %v", rules)
	}
}

// The status contract: public fields at the top, everything else under status.controller.
func TestStatusSchemaIsTheContractPlusTheControllerBlock(t *testing.T) {
	v := dig(t, load(t), "spec", "versions").([]any)[0]
	props := dig(t, v, "schema", "openAPIV3Schema", "properties", "status", "properties").(map[string]any)
	want := append(append([]string{}, api.PublicStatusFields...), "controller")
	if len(props) != len(want) {
		t.Fatalf("status has %d fields, the contract %d plus controller: %v", len(props), len(want)-1, props)
	}
	for _, k := range want {
		if _, ok := props[k]; !ok {
			t.Errorf("status.%s is not in the schema", k)
		}
	}
	for _, gone := range []string{"a2aUrl", "keySecret", "keyFingerprint", "appliedGeneration", "appliedSpec", "gatewayUserId", "toolServer"} {
		if _, ok := props[gone]; ok {
			t.Errorf("status.%s must not be a top-level field any more", gone)
		}
	}
	ctl := dig(t, props, "controller", "properties").(map[string]any)
	for _, k := range []string{"keySecret", "keyFingerprint", "appliedGeneration", "appliedSpec", "gatewayUserId", "toolServer"} {
		if _, ok := ctl[k]; !ok {
			t.Errorf("status.controller.%s is not in the schema", k)
		}
	}
	if dig(t, ctl, "appliedSpec", "type") != "string" || dig(t, ctl, "appliedGeneration", "type") != "integer" {
		t.Fatal("appliedSpec is a string (a merge patch replaces it whole), appliedGeneration an integer")
	}
	for _, f := range [][]string{{"endpoint", "properties", "protocol"}, {"endpoint", "properties", "url"}, {"endpoint", "properties", "protocolVersion"}} {
		dig(t, props, f...)
	}
	caps := dig(t, props, "capabilities", "properties").(map[string]any)
	for _, k := range []string{"approvals", "durableWaits", "workspacePersistence", "maxStepSeconds", "cancelStopsLoop", "perRunIdentity"} {
		if _, ok := caps[k]; !ok {
			t.Errorf("status.capabilities.%s is not in the schema", k)
		}
	}
}

// The condition contract is written in the CRD itself: the promise of Ready, and every reason of every condition.
func TestConditionContractIsInTheCRDDescriptions(t *testing.T) {
	v := dig(t, load(t), "spec", "versions").([]any)[0]
	desc := dig(t, v, "schema", "openAPIV3Schema", "properties", "status", "properties", "conditions", "description").(string)
	if !strings.Contains(desc, "Ready=True means") || !strings.Contains(desc, "status.endpoint") || !strings.Contains(desc, "status.revision") {
		t.Fatalf("the promise of Ready is not in the description: %s", desc)
	}
	for _, typ := range []string{api.CondAccepted, api.CondKeyReady, api.CondApplied, api.CondReady, api.CondSynced} {
		for _, r := range api.ReasonsFor(typ) {
			if !strings.Contains(desc, r.Reason) {
				t.Errorf("reason %s of %s is not in the conditions description", r.Reason, typ)
			}
		}
	}
	// and the reason field of a condition has no enum that could fall behind the table
	items := dig(t, v, "schema", "openAPIV3Schema", "properties", "status", "properties", "conditions", "items", "properties", "reason").(map[string]any)
	if _, ok := items["enum"]; ok {
		t.Fatal("reason is documented, not enumerated: an enum would refuse a status when the table grows")
	}
}

// "no upstream or product vocabulary in specs" (ADR 0012, change 13): the spec schema's field names and texts, and the public
// status fields' texts, name no upstream tool.
func TestSpecAndPublicStatusNameNoUpstreamProduct(t *testing.T) {
	v := dig(t, load(t), "spec", "versions").([]any)[0]
	schema := dig(t, v, "schema", "openAPIV3Schema", "properties").(map[string]any)
	banned := []string{"kagent", "toolhive", "vmcp", "agentgateway", "harness", "modelconfig", "substrate", "kourier"}
	var walk func(path string, n any)
	walk = func(path string, n any) {
		switch x := n.(type) {
		case map[string]any:
			for k, c := range x {
				for _, b := range banned {
					if strings.Contains(strings.ToLower(k), b) {
						t.Errorf("%s.%s: field name names an upstream product", path, k)
					}
				}
				if path == "status" && k == "controller" {
					continue // the controller's own bookkeeping is explicitly not the contract
				}
				walk(path+"."+k, c)
			}
		case string:
			for _, b := range banned {
				if strings.Contains(strings.ToLower(x), b) {
					t.Errorf("%s: text names an upstream product (%q): %s", path, b, x)
				}
			}
		case []any:
			for _, c := range x {
				walk(path, c)
			}
		}
	}
	walk("spec", schema["spec"])
	// status: everything except the controller block
	st := dig(t, schema, "status", "properties").(map[string]any)
	for k, c := range st {
		if k != "controller" {
			walk("status."+k, c)
		}
	}
}

// YAML 1.1 reads an unquoted yes or no as a boolean, and Helm reads the CRD as YAML 1.1: an enum written [yes, no] would reach
// the cluster as [true, false] and refuse every value. The capabilities enums must be quoted strings in the file.
func TestCapabilityEnumsAreStrings(t *testing.T) {
	raw, err := os.ReadFile("agentdefinition.yaml")
	if err != nil {
		t.Fatal(err)
	}
	for _, l := range strings.Split(string(raw), "\n") {
		if strings.Contains(l, "enum:") && regexp.MustCompile(`[\[ ,](yes|no|on|off|y|n)[,\]]`).MatchString(l) {
			t.Fatalf("unquoted yes or no in an enum: %s", l)
		}
	}
	p := dig(t, load(t), "spec", "versions").([]any)[0]
	e := dig(t, p, "schema", "openAPIV3Schema", "properties", "status", "properties", "capabilities", "properties", "approvals", "enum").([]any)
	for _, x := range e {
		if _, ok := x.(string); !ok {
			t.Fatalf("%v", e)
		}
	}
}

// The API server refuses a CRD whose metadata schema says more than `type: object` ("metadata must not have a description":
// Invalid value... only name and generateName may be specified). A chart that carries such a CRD fails to install, so the
// schema is pinned here.
func TestMetadataSchemaIsExactlyTypeObject(t *testing.T) {
	v := dig(t, load(t), "spec", "versions").([]any)[0]
	md := dig(t, v, "schema", "openAPIV3Schema", "properties", "metadata")
	got, _ := json.Marshal(md)
	if string(got) != `{"type":"object"}` {
		t.Fatalf("the metadata schema must be exactly {type: object}, got %s", got)
	}
}

// The instruction limit is one number, 16384, in bytes: the controller counts bytes, so the schema does too (a rule on the
// bytes of the text, on top of the cheap maxLength in characters, which is never looser than the byte limit).
func TestInstructionsLimitIsInBytesToo(t *testing.T) {
	p := specProps(t)
	ins := dig(t, p, "instructions").(map[string]any)
	rules, _ := ins["x-kubernetes-validations"].([]any)
	found := false
	for _, r := range rules {
		m := r.(map[string]any)
		if m["rule"] == "bytes(self).size() <= 16384" && strings.Contains(m["message"].(string), "16384 bytes") {
			found = true
		}
	}
	if !found {
		t.Fatalf("instructions needs the rule bytes(self).size() <= 16384: %v", rules)
	}
	if ins["maxLength"] != float64(16384) {
		t.Fatalf("maxLength stays 16384 characters: %v", ins["maxLength"])
	}
}

// ADR 0015: spec.runtime. The one place an image may be named in a spec; typed, bounded, and never a platform-component image.
func TestRuntimeBlockShape(t *testing.T) {
	p := specProps(t)
	rt := dig(t, p, "runtime")
	if dig(t, rt, "type") != "object" {
		t.Fatal("runtime is an object")
	}
	typ := dig(t, rt, "properties", "type").(map[string]any)
	var enum []string
	for _, e := range typ["enum"].([]any) {
		enum = append(enum, e.(string))
	}
	if strings.Join(enum, ",") != "builtin,container" {
		t.Fatalf("runtime.type enum: %v", enum)
	}
	c := dig(t, rt, "properties", "container")
	cp := dig(t, c, "properties")
	if dig(t, cp, "image", "maxLength") != float64(300) {
		t.Fatal("image maxLength 300")
	}
	if dig(t, cp, "port", "minimum") != float64(1024) || dig(t, cp, "port", "maximum") != float64(65535) {
		t.Fatal("port 1024..65535")
	}
	if req := dig(t, c, "required").([]any); len(req) != 2 {
		t.Fatalf("image and port are required: %v", req)
	}
	env := dig(t, cp, "env")
	if dig(t, env, "maxItems") != float64(32) {
		t.Fatal("env maxItems 32")
	}
	if dig(t, env, "items", "properties", "name", "pattern") != "^[A-Z_][A-Z0-9_]*$" {
		t.Fatal("env name pattern")
	}
	if dig(t, env, "items", "properties", "value", "maxLength") != float64(4096) {
		t.Fatal("env value maxLength")
	}
	for _, side := range []string{"requests", "limits"} {
		for _, k := range []string{"cpu", "memory"} {
			if dig(t, cp, "resources", "properties", side, "properties", k, "type") != "string" {
				t.Fatalf("resources.%s.%s", side, k)
			}
		}
	}
	// nothing that reaches around the platform
	for _, bad := range []string{"command", "args", "volumes", "securityContext", "serviceAccountName", "imagePullSecrets", "envFrom", "hostNetwork"} {
		if _, ok := cp.(map[string]any)[bad]; ok {
			t.Errorf("runtime.container must not have %q", bad)
		}
	}
}

// A container agent is configured in its image: neither instructions nor instructionsFrom is required. A builtin agent keeps
// "exactly one".
func TestContainerRuntimeNeedsNoInstructions(t *testing.T) {
	v := dig(t, load(t), "spec", "versions").([]any)[0]
	rules := dig(t, v, "schema", "openAPIV3Schema", "properties", "spec", "x-kubernetes-validations").([]any)
	for _, r := range rules {
		m := r.(map[string]any)
		rule := m["rule"].(string)
		if strings.Contains(rule, "has(self.instructionsFrom)") {
			if !strings.Contains(rule, "self.runtime.type == 'container'") || !strings.Contains(rule, "has(self.instructions) != has(self.instructionsFrom)") {
				t.Fatalf("the rule must exempt container agents and keep exactly-one for the rest: %s", rule)
			}
			return
		}
	}
	t.Fatal("no instructions rule")
}

func TestCapabilitiesHaveIsolation(t *testing.T) {
	v := dig(t, load(t), "spec", "versions").([]any)[0]
	caps := dig(t, v, "schema", "openAPIV3Schema", "properties", "status", "properties", "capabilities", "properties")
	if dig(t, caps, "isolation", "type") != "string" {
		t.Fatal("status.capabilities.isolation is a string")
	}
}

func TestChartCopyOfTheCRDIsIdentical(t *testing.T) {
	a, err := os.ReadFile("agentdefinition.yaml")
	if err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile("../../../charts/openagentix/files/agentdefinition-crd.yaml")
	if err != nil {
		t.Skip("chart not in this checkout")
	}
	if string(a) != string(b) {
		t.Fatal("charts/openagentix/files/agentdefinition-crd.yaml must be a byte copy of crd/agentdefinition.yaml")
	}
}
