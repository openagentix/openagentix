package redact

import (
	"encoding/base64"
	"encoding/hex"
	"strings"
	"testing"
)

// Canaries are built from pieces so that no complete token sits in the source.
var (
	ghp    = "ghp_" + strings.Repeat("Ab3dE", 8)
	xoxb   = "xoxb-" + "1234567890-" + "abcdefghijKLMNOP"
	skAnt  = "sk-ant-" + "api03-" + strings.Repeat("Zq9", 8)
	skKey  = "sk-" + strings.Repeat("Qw7rT", 6)
	vkKey  = "vk-" + strings.Repeat("Mn4pL", 6)
	glpat  = "glpat-" + strings.Repeat("Xy2zK", 5)
	ghPAT  = "github_pat_" + strings.Repeat("B7c9D", 6)
	bot    = "123456789:" + "AAH" + strings.Repeat("kJ8_f", 6) + "xy"
	awsKey = "AKIA" + "ABCDEFGHIJKLMNOP"
	jwt    = "eyJhbGciOiJIUzI1NiJ9." + "eyJzdWIiOiJjYW5hcnkifQ." + "c2lnbmF0dXJlQ2FuYXJ5"
	pem    = "-----BEGIN RSA PRIVATE KEY-----\nMIIBOgIBAAJBAKcanarycanarycanary\n-----END RSA PRIVATE KEY-----"
)

func TestScrubPlainForms(t *testing.T) {
	cases := map[string]string{
		"pem":         "key follows " + pem + " done",
		"jwt":         "token is " + jwt + " end",
		"aws":         "found " + awsKey + " here",
		"ghp":         "pushed with " + ghp + " ok",
		"ghp pat":     "using " + ghPAT,
		"glpat":       "ci " + glpat,
		"xoxb":        "slack " + xoxb,
		"sk-ant":      "model key " + skAnt,
		"sk":          "key " + skKey,
		"vk":          "gateway " + vkKey,
		"bot token":   "bot " + bot + " failed",
		"password=":   "connect password=hunter2canary now",
		"passwd:":     "passwd: hunter2canary",
		"json pair":   `{"client_secret": "hunter2canary"}`,
		"yaml pair":   "api_key: hunter2canary",
		"env pair":    "DB_PASSWORD=hunter2canary",
		"flag eq":     "run --password=hunter2canary --other",
		"flag space":  "run --password hunter2canary --other",
		"url":         "dial postgres://app:hunter2canary@db:5432/x",
		"bearer":      "Authorization: Bearer abc123canaryvalue",
		"bearer bare": "sent Bearer abc123canaryvalue to api",
		"basic":       "Proxy-Authorization: Basic dXNlcjpoNHJkY2FuYXJ5",
		"cookie":      "Cookie: sid=hunter2canary; other=1",
		"set-cookie":  "Set-Cookie: sid=hunter2canary; Path=/",
		"x-api-key":   "X-API-Key: hunter2canary",
		"header pair": `{"name": "Authorization", "value": "hunter2canary"}`,
		"kubeconfig":  "client-key-" + "data: LS0tcanary" + "hunter2",
		"token:":      "    token: hunter2canary",
	}
	sc := New()
	for name, in := range cases {
		out, n := sc.Scrub(in)
		if n == 0 {
			t.Errorf("%s: no redaction in %q", name, out)
		}
		for _, bad := range []string{"hunter2canary", "abc123canaryvalue", "dXNlcjpoNHJkY2FuYXJ5", "LS0tcanaryhunter2", ghp, ghPAT, glpat, xoxb, skAnt, skKey, vkKey, bot, awsKey, jwt, "MIIBOgIBAAJB"} {
			if strings.Contains(out, bad) {
				t.Errorf("%s: %q survived in %q", name, bad, out)
			}
		}
		if !strings.Contains(out, "[redacted]") {
			t.Errorf("%s: no marker in %q", name, out)
		}
	}
}

func TestScrubEncodedForms(t *testing.T) {
	sc := New()
	secrets := []string{ghp, skKey, vkKey, awsKey, "password=hunter2canary", "Authorization: Bearer abc123canaryvalue", jwt}
	for _, s := range secrets {
		b64 := base64.StdEncoding.EncodeToString([]byte(s))
		b64url := base64.RawURLEncoding.EncodeToString([]byte(s))
		hx := hex.EncodeToString([]byte(s))
		upper := strings.ToUpper(hx)
		embedded := base64.StdEncoding.EncodeToString([]byte("x " + s + " tail"))
		for name, enc := range map[string]string{"b64": b64, "b64url": b64url, "hex": hx, "HEX": upper, "b64 offset": embedded} {
			line := "value " + enc + " end"
			out, n := sc.Scrub(line)
			if n == 0 || strings.Contains(out, enc) {
				t.Errorf("%s of %.12q... survived: %q", name, s, out)
			}
			if !strings.HasPrefix(out, "value ") || !strings.HasSuffix(out, " end") {
				t.Errorf("%s: surrounding text damaged: %q", name, out)
			}
		}
	}
}

func TestScrubLeavesOrdinaryText(t *testing.T) {
	sc := New()
	keep := []string{
		"node has disk-pressure condition",
		"task-runner started",
		"ask-me-later and risk-assessment",
		"sk-short",
		"sk-" + "tiny-word",
		"vk-test",
		"ghp_short",
		"basic configuration loaded",
		"the bearer capacity is high",
		"Liveness probe failed: HTTP probe failed with statuscode: 500",
		"image sha256:" + strings.Repeat("ab12", 16),
		"back-off restarting failed container",
		"pod uid " + "0d1b3a5c-1111-2222-3333-444455556666",
		"12345:short",
		"tokens per second 12",
		"OOMKilled",
	}
	for _, in := range keep {
		out, n := sc.Scrub(in)
		if out != in || n != 0 {
			t.Errorf("changed %q -> %q (%d)", in, out, n)
		}
	}
}

func TestScrubCountsAndIsIdempotent(t *testing.T) {
	sc := New()
	in := "a password=one b password=two " + ghp
	out, n := sc.Scrub(in)
	if n != 3 {
		t.Fatalf("count = %d, out %q", n, out)
	}
	out2, n2 := sc.Scrub(out)
	if out2 != out || n2 != 0 {
		t.Fatalf("second pass changed %q -> %q (%d)", out, out2, n2)
	}
}

func TestStripControl(t *testing.T) {
	in := "a\x1b[31mred\x1b[0m b\x1b]0;title\x07c\x00d\te\rf\ng\x7fh\u202eX\u200bY\u009bz"
	got := StripControl(in)
	if got != "ared bcd\tefghXYz" {
		t.Fatalf("got %q", got)
	}
	if StripControl("bad \xff\xfe bytes") != "bad \ufffd bytes" {
		t.Fatalf("invalid utf-8 not replaced: %q", StripControl("bad \xff\xfe bytes"))
	}
}

func TestCut(t *testing.T) {
	if got := Cut("short", 10); got != "short" {
		t.Fatal(got)
	}
	got := Cut(strings.Repeat("a", 100), 20)
	if len(got) != 20 || !strings.HasSuffix(got, CutMarker) {
		t.Fatalf("got %q (%d)", got, len(got))
	}
	// never splits a rune
	got = Cut(strings.Repeat("é", 50), 21)
	if len(got) > 21 || !strings.HasSuffix(got, CutMarker) {
		t.Fatalf("got %q (%d)", got, len(got))
	}
	for _, r := range got {
		if r == '�' {
			t.Fatalf("split rune in %q", got)
		}
	}
}
