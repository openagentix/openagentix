package replay

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// eqCtlWith runs the equipment ctl.sh against a REST handler. The fake kubectl only answers the two things ctl.sh asks of it: the port-forward (it
// reports the port of the test server) and the approver token Secret. After the script ends, every fake port-forward must be gone.
func eqCtlWith(t *testing.T, h http.Handler, extraEnv []string, args ...string) (string, int, string) {
	t.Helper()
	for _, tool := range []string{"jq", "curl", "bash"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("%s is not installed", tool)
		}
	}
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	u, _ := url.Parse(srv.URL)
	dir := t.TempDir()
	fake := filepath.Join(dir, "kubectl")
	pidFile := filepath.Join(dir, "pf.pid")
	callsFile := filepath.Join(dir, "calls")
	script := `#!/bin/sh
echo "$*" >> "` + callsFile + `"
case "$*" in
  *port-forward*) echo $$ >> "` + pidFile + `"; echo "Forwarding from 127.0.0.1:` + u.Port() + ` -> 8081"; exec sleep 120 ;;
  *"get secret records-approver-token"*) printf %s "` + base64.StdEncoding.EncodeToString([]byte(leadToken)) + `" ;;
  *) echo "unexpected kubectl call: $*" >&2; exit 9 ;;
esac
`
	if err := os.WriteFile(fake, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	abs, _ := filepath.Abs(eqCtlScript)
	cmd := exec.Command("bash", append([]string{abs}, args...)...)
	cmd.Env = append(append(os.Environ(), "KUBECTL="+fake, "CLUSTER=test"), extraEnv...)
	var buf bytes.Buffer
	cmd.Stdout, cmd.Stderr = &buf, &buf
	code := 0
	if err := cmd.Run(); err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatal(err)
		}
		code = ee.ExitCode()
	}
	if raw, err := os.ReadFile(pidFile); err == nil {
		for _, f := range strings.Fields(string(raw)) {
			pid, _ := strconv.Atoi(f)
			gone := false
			for i := 0; i < 40; i++ {
				if syscall.Kill(pid, 0) != nil {
					gone = true
					break
				}
				time.Sleep(50 * time.Millisecond)
			}
			if !gone {
				_ = syscall.Kill(pid, syscall.SIGKILL)
				t.Fatalf("ctl.sh %v left a port-forward running (pid %d)", args, pid)
			}
		}
	}
	calls := ""
	if raw, err := os.ReadFile(callsFile); err == nil {
		calls = string(raw)
	}
	if strings.Contains(buf.String(), leadToken) {
		t.Fatalf("ctl.sh printed the approver token:\n%s", buf.String())
	}
	return buf.String(), code, calls
}

func (e *eqEnv) ctl(t *testing.T, args ...string) (string, int) {
	t.Helper()
	out, code, _ := eqCtlWith(t, e.rest, nil, args...)
	return out, code
}

func TestEquipmentCtlShowsTheRequestAndApprovesWithTheHash(t *testing.T) {
	e := newEqEnv(t)
	e.run("Work case SVC-2026-0001")
	out, code := e.ctl(t, "approvals")
	if code != 0 || !strings.Contains(out, "APR-0001") || !strings.Contains(out, "parts_order_with_claim") || !strings.Contains(out, "pending") {
		t.Fatalf("approvals (%d): %s", code, out)
	}
	out, code = e.ctl(t, "show", "APR-0001")
	if code != 0 || !strings.Contains(out, "payload_hash:") || !strings.Contains(out, "SVC-2026-0001") || !strings.Contains(out, "P-10361") {
		t.Fatalf("show (%d): %s", code, out)
	}
	if n := e.queuedAnywhere(); n != 0 {
		t.Fatalf("queued before approve: %d", n)
	}
	out, code = e.ctl(t, "approve", "APR-0001", "--yes", "checked the diagnosis and the stock")
	if code != 0 || !strings.Contains(out, "approved by dealer:svc-mgr-02") {
		t.Fatalf("approve (%d): %s", code, out)
	}
	if n := e.queuedAnywhere(); n != 3 {
		t.Fatalf("queued after approve: %d", n)
	}
	for _, sub := range []string{"outbox", "cases"} {
		if out, code := e.ctl(t, sub); code != 0 || strings.TrimSpace(out) == "" {
			t.Fatalf("%s (%d): %q", sub, code, out)
		}
	}
	if out, code := e.ctl(t, "approve", "APR-0001", "--yes"); code == 0 || !strings.Contains(out, "not pending") {
		t.Fatalf("a second approve must be refused (%d): %s", code, out)
	}
	if n := e.queuedAnywhere(); n != 3 {
		t.Fatalf("a refused second approval changed the outbox: %d", n)
	}
}

func TestEquipmentCtlRejectSendsTheCaseToAPerson(t *testing.T) {
	e := newEqEnv(t)
	e.run("Work case SVC-2026-0002")
	out, code := e.ctl(t, "reject", "APR-0001", "--yes", "price not agreed")
	if code != 0 || !strings.Contains(out, "rejected by dealer:svc-mgr-02") {
		t.Fatalf("reject (%d): %s", code, out)
	}
	_, c := e.do("GET", "/cases/SVC-2026-0002", "", "")
	if c["status"] != "needs_person" {
		t.Fatalf("status: %v", c["status"])
	}
	if e.queuedAnywhere() != 0 {
		t.Fatal("a rejection queued something")
	}
}

func TestEquipmentCtlRefusesBadIdsAndWithoutConfirmation(t *testing.T) {
	e := newEqEnv(t)
	e.run("Work case SVC-2026-0001")
	if _, code := e.ctl(t, "case", "SVC-1; rm -rf /"); code == 0 {
		t.Fatal("a bad case id must be refused")
	}
	if _, code := e.ctl(t, "approve", "../approvals", "--yes"); code == 0 {
		t.Fatal("a bad approval id must be refused")
	}
	if out, code := e.ctl(t, "approve", "APR-0001"); code == 0 {
		t.Fatalf("approve without --yes and without a terminal must stop: %s", out)
	}
	if e.queuedAnywhere() != 0 {
		t.Fatal("something was queued without a decision")
	}
}

func TestEquipmentCtlHasNoDefaultClusterAndRefusesAContextThatIsNotKind(t *testing.T) {
	e := newEqEnv(t)
	out, code, calls := eqCtlWith(t, e.rest, []string{"CLUSTER=", "KUBE_CONTEXT="}, "approvals")
	if code != 1 || !strings.Contains(out, "no default cluster") || strings.TrimSpace(calls) != "" {
		t.Fatalf("want exit 1, 'no default cluster' and no kubectl call, got %d (calls %q):\n%s", code, calls, out)
	}
	out, code, calls = eqCtlWith(t, e.rest, []string{"KUBE_CONTEXT=gke_example_project"}, "approvals")
	if code == 0 || !strings.Contains(out, "kind") || strings.TrimSpace(calls) != "" {
		t.Fatalf("a context that is not kind must be refused before any call (%d, calls %q): %s", code, calls, out)
	}
}

// CLUSTER and KUBE_CONTEXT that name different clusters are refused before any call.
func TestEquipmentCtlRefusesAClusterAndAContextThatDisagree(t *testing.T) {
	e := newEqEnv(t)
	out, code, calls := eqCtlWith(t, e.rest, []string{"CLUSTER=oa-equipment", "KUBE_CONTEXT=kind-other"}, "approvals")
	if code != 1 || !strings.Contains(out, "different clusters") || strings.TrimSpace(calls) != "" {
		t.Fatalf("want exit 1, 'different clusters' and no kubectl call, got %d (calls %q):\n%s", code, calls, out)
	}
}

func TestEquipmentCtlEveryCallNamesTheContext(t *testing.T) {
	e := newEqEnv(t)
	e.run("Work case SVC-2026-0001")
	_, code, calls := eqCtlWith(t, e.rest, nil, "approve", "APR-0001", "--yes")
	if code != 0 {
		t.Fatal("approve failed")
	}
	for _, l := range strings.Split(strings.TrimSpace(calls), "\n") {
		if !strings.HasPrefix(l, "--context kind-test ") {
			t.Fatalf("a kubectl call without the context: %q", l)
		}
	}
}

// The approver decides what they read. If the hash the service sends does not cover the payload it sends, ctl.sh must refuse.
func TestEquipmentCtlRefusesAnApprovalWhoseHashDoesNotCoverThePayload(t *testing.T) {
	e := newEqEnv(t)
	e.run("Work case SVC-2026-0001")
	tamper := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/approvals/APR-0001" {
			rec := httptest.NewRecorder()
			e.rest.ServeHTTP(rec, r)
			var m map[string]any
			_ = json.Unmarshal(rec.Body.Bytes(), &m)
			m["payload"] = strings.Replace(m["payload"].(string), `"qty":1`, `"qty":20`, 1)
			_ = json.NewEncoder(w).Encode(m)
			return
		}
		e.rest.ServeHTTP(w, r)
	})
	out, code, _ := eqCtlWith(t, tamper, nil, "approve", "APR-0001", "--yes")
	if code == 0 || !strings.Contains(out, "does not match") {
		t.Fatalf("a payload that does not match its hash must be refused (%d): %s", code, out)
	}
	if e.queuedAnywhere() != 0 {
		t.Fatal("something was queued")
	}
}

// The event sender of the offline demo: a machine fault and a dealer's request become cases through the REST port of the records service.
func TestEquipmentCtlFaultAndRequestEvents(t *testing.T) {
	e := newEqEnv(t)
	re := regexp.MustCompile(`SVC-2026-[0-9]{4}`)
	out, code := e.ctl(t, "fault", "KH4120-00317", "E-317")
	if code != 0 || !strings.Contains(out, "SVC-2026-0001") || !strings.Contains(out, "deduplicated") {
		t.Fatalf("the same fault on the same machine must reuse the open case (%d): %s", code, out)
	}
	out, code = e.ctl(t, "fault", "KT260-00101", "E-322")
	id := re.FindString(out)
	if code != 0 || id == "" || strings.Contains(out, "deduplicated: true") {
		t.Fatalf("a new fault opens a case (%d): %s", code, out)
	}
	_, c := e.do("GET", "/cases/"+id, "", "")
	if c["serial"] != "KT260-00101" || c["fault_code"] != "E-322" || c["kind"] != "fault" {
		t.Fatalf("the case: %v", c)
	}
	out, code = e.ctl(t, "request", "KT260-00102", "The hydraulic lift is slow since this morning.")
	rid := re.FindString(out)
	if code != 0 || rid == "" {
		t.Fatalf("request (%d): %s", code, out)
	}
	_, c = e.do("GET", "/cases/"+rid, "", "")
	if c["kind"] != "request" || c["safety_flag"] != false {
		t.Fatalf("the request case: %v", c)
	}
	out, code = e.ctl(t, "request", "KT260-00103", "--safety", "Can the seat switch be bypassed for a test?")
	sid := re.FindString(out)
	if code != 0 || sid == "" {
		t.Fatalf("request --safety (%d): %s", code, out)
	}
	_, c = e.do("GET", "/cases/"+sid, "", "")
	if c["safety_flag"] != true {
		t.Fatalf("the dealer's safety flag must reach the record: %v", c)
	}
	for _, bad := range [][]string{{"fault", "KH4120-00317; id", "E-317"}, {"fault", "KH4120-00317", "317"}, {"request", "x", "note"}} {
		if _, code := e.ctl(t, bad...); code == 0 {
			t.Fatalf("%v must be refused", bad)
		}
	}
}
