package replay

import (
	"bytes"
	"encoding/base64"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

const ctlScript = "../../bank/ctl.sh"

// ctl runs ctl.sh against the REST handler of the records service. The fake kubectl only answers the two things ctl.sh asks of it:
// the port-forward (it reports the port of the test server) and the approver token Secret.
func ctl(t *testing.T, e *env, args ...string) (string, int) {
	t.Helper()
	for _, tool := range []string{"jq", "curl", "bash"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("%s is not installed", tool)
		}
	}
	srv := httptest.NewServer(e.rest)
	t.Cleanup(srv.Close)
	u, _ := url.Parse(srv.URL)
	dir := t.TempDir()
	fake := filepath.Join(dir, "kubectl")
	script := `#!/bin/sh
case "$*" in
  *port-forward*) echo "Forwarding from 127.0.0.1:` + u.Port() + ` -> 8081"; exec sleep 120 ;;
  *"get secret records-approver-token"*) printf %s "` + base64.StdEncoding.EncodeToString([]byte(leadToken)) + `" ;;
  *) echo "unexpected kubectl call: $*" >&2; exit 9 ;;
esac
`
	if err := os.WriteFile(fake, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	abs, _ := filepath.Abs(ctlScript)
	cmd := exec.Command("bash", append([]string{abs}, args...)...)
	cmd.Env = append(os.Environ(), "KUBECTL="+fake, "CLUSTER=test")
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
