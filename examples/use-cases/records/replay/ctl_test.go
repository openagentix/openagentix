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
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

const ctlScript = "../../bank/ctl.sh"

// lastCalls is what the fake kubectl was asked in the last ctl run.
var lastCalls string

// ctl runs ctl.sh against the REST handler of the records service. The fake kubectl only answers the two things ctl.sh asks of it:
// the port-forward (it reports the port of the test server) and the approver token Secret.
func ctl(t *testing.T, e *env, args ...string) (string, int) {
	t.Helper()
	return ctlWith(t, e.rest, nil, args...)
}

// ctlWith is ctl with another handler behind the port-forward and extra environment. After the script ends, the fake port-forward
// process must be gone: a forward that stays up keeps the REST routes that need no login open to every local process.
func ctlWith(t *testing.T, h http.Handler, extraEnv []string, args ...string) (string, int) {
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
  *port-forward*) echo $$ > "` + pidFile + `"; echo "Forwarding from 127.0.0.1:` + u.Port() + ` -> 8081"; exec sleep 120 ;;
  *"get secret records-approver-token"*) printf %s "` + base64.StdEncoding.EncodeToString([]byte(leadToken)) + `" ;;
  *) echo "unexpected kubectl call: $*" >&2; exit 9 ;;
esac
`
	if err := os.WriteFile(fake, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	abs, _ := filepath.Abs(ctlScript)
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
		pid, _ := strconv.Atoi(strings.TrimSpace(string(raw)))
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
			t.Fatalf("ctl.sh %v left its port-forward running (pid %d)", args, pid)
		}
	}
	if raw, err := os.ReadFile(callsFile); err == nil {
		lastCalls = string(raw)
	} else {
		lastCalls = ""
	}
	if strings.Contains(buf.String(), leadToken) {
		t.Fatalf("ctl.sh printed the approver token:\n%s", buf.String())
	}
	return buf.String(), code
}

func TestCtlShowsTheRequestAndApprovesWithTheHash(t *testing.T) {
	e := newEnv(t)
	e.run("Work case DSP-2026-0001")
	out, code := ctl(t, e, "approvals")
	if code != 0 || !strings.Contains(out, "APR-0001") || !strings.Contains(out, "pending") {
		t.Fatalf("approvals (%d): %s", code, out)
	}
	out, code = ctl(t, e, "show", "APR-0001")
	if code != 0 || !strings.Contains(out, "payload_hash:") || !strings.Contains(out, "DSP-2026-0001") {
		t.Fatalf("show (%d): %s", code, out)
	}
	if n := e.count("/ledger", "ledger"); n != 0 {
		t.Fatalf("ledger before approve: %d", n)
	}
	out, code = ctl(t, e, "approve", "APR-0001", "--yes", "checked the evidence")
	if code != 0 || !strings.Contains(out, "approved by desk:lead-1") {
		t.Fatalf("approve (%d): %s", code, out)
	}
	if n := e.count("/ledger", "ledger"); n != 1 {
		t.Fatalf("ledger after approve: %d", n)
	}
	for _, sub := range []string{"ledger", "outbox", "cases"} {
		if out, code := ctl(t, e, sub); code != 0 || strings.TrimSpace(out) == "" {
			t.Fatalf("%s (%d): %q", sub, code, out)
		}
	}
	if out, code := ctl(t, e, "approve", "APR-0001", "--yes"); code == 0 || !strings.Contains(out, "not pending") {
		t.Fatalf("a second approve must be refused (%d): %s", code, out)
	}
}

func TestCtlRejectSendsTheCaseBackToAnAnalyst(t *testing.T) {
	e := newEnv(t)
	e.run("Work case DSP-2026-0005")
	out, code := ctl(t, e, "reject", "APR-0001", "--yes", "wrong reason code")
	if code != 0 || !strings.Contains(out, "rejected by desk:lead-1") {
		t.Fatalf("reject (%d): %s", code, out)
	}
	_, c := e.do("GET", "/cases/DSP-2026-0005", "", "")
	if c["status"] != "needs_analyst" {
		t.Fatalf("status: %v", c["status"])
	}
	if n := e.count("/ledger", "ledger"); n != 0 || e.queued() != 0 {
		t.Fatal("a rejection moved something")
	}
}

func TestCtlRefusesBadIdsAndWithoutConfirmation(t *testing.T) {
	e := newEnv(t)
	e.run("Work case DSP-2026-0001")
	if _, code := ctl(t, e, "case", "DSP-1; rm -rf /"); code == 0 {
		t.Fatal("a bad case id must be refused")
	}
	if _, code := ctl(t, e, "approve", "../approvals", "--yes"); code == 0 {
		t.Fatal("a bad approval id must be refused")
	}
	// No terminal and no --yes: nothing is decided.
	if out, code := ctl(t, e, "approve", "APR-0001"); code == 0 {
		t.Fatalf("approve without --yes and without a terminal must stop: %s", out)
	}
	if n := e.count("/ledger", "ledger"); n != 0 {
		t.Fatalf("ledger: %d", n)
	}
}

func TestCtlRefusesAContextThatIsNotKindBeforeAnyCall(t *testing.T) {
	e := newEnv(t)
	out, code := ctlWith(t, e.rest, []string{"KUBE_CONTEXT=gke_example_project"}, "approvals")
	if code == 0 || !strings.Contains(out, "kind") {
		t.Fatalf("a context that is not kind must be refused (%d): %s", code, out)
	}
	if strings.TrimSpace(lastCalls) != "" {
		t.Fatalf("kubectl was called: %s", lastCalls)
	}
}

func TestCtlEveryCallNamesTheContext(t *testing.T) {
	e := newEnv(t)
	e.run("Work case DSP-2026-0001")
	if _, code := ctl(t, e, "approve", "APR-0001", "--yes"); code != 0 {
		t.Fatal("approve failed")
	}
	for _, l := range strings.Split(strings.TrimSpace(lastCalls), "\n") {
		if !strings.HasPrefix(l, "--context kind-test ") {
			t.Fatalf("a kubectl call without the context: %q", l)
		}
	}
}

// The approver decides what they read. If the hash the service sends does not cover the payload it sends, ctl.sh must refuse, because
// approving would sign something the person did not see.
func TestCtlRefusesAnApprovalWhoseHashDoesNotCoverThePayload(t *testing.T) {
	e := newEnv(t)
	e.run("Work case DSP-2026-0001")
	tamper := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/approvals/APR-0001" {
			rec := httptest.NewRecorder()
			e.rest.ServeHTTP(rec, r)
			var m map[string]any
			_ = json.Unmarshal(rec.Body.Bytes(), &m)
			m["payload"] = strings.Replace(m["payload"].(string), `"amount_cents":`, `"amount_cents":1`, 1)
			_ = json.NewEncoder(w).Encode(m)
			return
		}
		e.rest.ServeHTTP(w, r)
	})
	out, code := ctlWith(t, tamper, nil, "approve", "APR-0001", "--yes")
	if code == 0 || !strings.Contains(out, "does not match") {
		t.Fatalf("a payload that does not match its hash must be refused (%d): %s", code, out)
	}
	if n := e.count("/ledger", "ledger"); n != 0 {
		t.Fatalf("ledger: %d", n)
	}
}
