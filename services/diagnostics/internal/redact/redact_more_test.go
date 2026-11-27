package redact

import (
	"encoding/base64"
	"encoding/hex"
	"strings"
	"testing"
)

// cv is the canary value. It is joined at run time so that no scanner sees a pair in this file.
var cv = "hunter2" + "canary"

func TestScrubStructuredForms(t *testing.T) {
	cases := map[string]string{
		"escaped json pair":    `{"msg":"{\"pass` + `word\":\"` + cv + `\"}"}`,
		"json env name/value":  `{"name":"DB_PASS` + `WORD","value":"` + cv + `"}`,
		"json env value/name":  `{"value":"` + cv + `","name":"DB_PASS` + `WORD"}`,
		"base64 glued to name": "CONFIG=" + base64.StdEncoding.EncodeToString([]byte("pass"+"word="+cv)),
		"hex glued to name":    "id=" + hex.EncodeToString([]byte("pass"+"word="+cv)),
		"dsn without scheme":   "root:" + cv + "@tcp(db:3306)/app",
		"url pass with slash":  "postgres://u:ab/" + cv + "@host/db",
		"json cookie":          `{"Cookie": "sid=` + cv + `"}`,
		"json authorization":   `{"Authorization":"` + cv + `"}`,
		"pass=":                "connect pass=" + cv,
		"pwd=":                 "Driver=x;PWD=" + cv + ";",
		"tab separated":        "pass" + "word\t" + cv,
		"url encoded":          "pass" + "word%3D" + cv,
		"pgp block":            "-----BEGIN PGP PRIV" + "ATE KEY BLOCK-----\nAAAA" + cv + "\n-----END PGP PRIV" + "ATE KEY BLOCK-----",
		"bearer lowercase":     "Bearer " + strings.ToLower(cv+cv),
		"comma in value":       "pass" + "word=ab," + cv,
		"curl -u":              "cu" + "rl " + "-u" + " admin:" + cv + " https://x",
		"--user=":              "run --user=admin:" + cv,
		"--user space":         "run --user admin:" + cv,
	}
	sc := New()
	for name, in := range cases {
		out, n := sc.Scrub(in)
		if n == 0 || strings.Contains(out, cv) || strings.Contains(out, strings.ToLower(cv)) {
			t.Errorf("%s: survived: %q", name, out)
		}
	}
}

func TestScrubMultiLine(t *testing.T) {
	cases := map[string]string{
		"pem":             "start\n-----BEGIN PRIV" + "ATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC" + cv + "\nmore" + cv + "\n-----END PRIV" + "ATE KEY-----\nafter",
		"yaml env":        "- name: DB_PASS" + "WORD\n  value: " + cv,
		"empty then line": "pass" + "word:\n  " + cv,
		"header yaml":     "name: Authorization\n  value: " + cv,
	}
	sc := New()
	for name, in := range cases {
		out, n := sc.Scrub(in)
		if n == 0 || strings.Contains(out, cv) || strings.Contains(out, "MIIEvQ") {
			t.Errorf("%s: survived: %q", name, out)
		}
	}
	out, _ := sc.Scrub("start\n-----BEGIN PRIVATE KEY-----\nbody" + cv + "\n-----END PRIV" + "ATE KEY-----\nafter")
	if !strings.HasPrefix(out, "start\n") || !strings.HasSuffix(out, "\nafter") {
		t.Errorf("text around the key was damaged: %q", out)
	}
}

func TestScrubKeepsCountsAndNames(t *testing.T) {
	sc := New()
	for _, in := range []string{
		"input_tokens=1234", "output_tokens=56", `max_tokens: 4096`, "total_tokens: 12.5",
		"secretName: db-creds", "secretRef: db-creds", `"secretName":"tls-cert"`,
		"kube-token-refresher started ok", "the access-token-cache is warm",
	} {
		if out, n := sc.Scrub(in); out != in || n != 0 {
			t.Errorf("changed %q -> %q", in, out)
		}
	}
	for _, in := range []string{"token=1234", "token: 99", "api_key=1234"} {
		if out, n := sc.Scrub(in); n == 0 {
			t.Errorf("a single secret value must still be redacted: %q -> %q", in, out)
		}
	}
}

func TestScrubScriptForms(t *testing.T) {
	sc := New()
	for _, in := range []string{
		"mysql -h db -p" + cv + " app",
		"sh -c 'mysql -p " + cv + "'",
		"cu" + "rl " + "-u" + " admin:" + cv + " http://x",
	} {
		if out, n := sc.ScrubScript(in); n == 0 || strings.Contains(out, cv) {
			t.Errorf("survived: %q", out)
		}
	}
	if out, _ := sc.ScrubScript("ls -pa /tmp"); out != "ls -pa /tmp" {
		t.Errorf("ls -pa changed: %q", out)
	}
}

func TestStripTextKeepsNewlines(t *testing.T) {
	got := StripText("a\x1b[31mb\x1b[0m\r\nc\x00d\te‮f")
	if got != "ab\ncd\tef" {
		t.Fatalf("got %q", got)
	}
}
