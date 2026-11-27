package replay

import (
	"strings"
	"testing"
)

const untrustedBanner = "written by the agent from untrusted input"

// The approver reads text that the agent wrote, partly from a dealer's note or a customer's words. ctl.sh says so in one line before the payload, in show and in
// approve (which asks the person to decide on what it just printed).
func TestEquipmentCtlShowAndApprovePrintTheUntrustedBanner(t *testing.T) {
	e := newEqEnv(t)
	e.run("Work case SVC-2026-0001")
	out, code := e.ctl(t, "show", "APR-0001")
	if code != 0 || strings.Count(out, untrustedBanner) != 1 || strings.Index(out, untrustedBanner) > strings.Index(out, "payload:") {
		t.Fatalf("show must print the banner once, before the payload (%d): %s", code, out)
	}
	out, code = e.ctl(t, "approve", "APR-0001", "--yes")
	if code != 0 || strings.Count(out, untrustedBanner) != 1 || strings.Index(out, untrustedBanner) > strings.Index(out, "payload_hash:") {
		t.Fatalf("approve must print the banner once, before the payload (%d): %s", code, out)
	}
}

func TestBankCtlShowAndApprovePrintTheUntrustedBanner(t *testing.T) {
	e := newEnv(t)
	e.run("Work case DSP-2026-0001")
	out, code := ctl(t, e, "show", "APR-0001")
	if code != 0 || strings.Count(out, untrustedBanner) != 1 || strings.Index(out, untrustedBanner) > strings.Index(out, "payload:") {
		t.Fatalf("show must print the banner once, before the payload (%d): %s", code, out)
	}
	out, code = ctl(t, e, "approve", "APR-0001", "--yes")
	if code != 0 || strings.Count(out, untrustedBanner) != 1 || strings.Index(out, untrustedBanner) > strings.Index(out, "payload_hash:") {
		t.Fatalf("approve must print the banner once, before the payload (%d): %s", code, out)
	}
}
