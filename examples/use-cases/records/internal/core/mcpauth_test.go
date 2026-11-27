package core

import (
	"bytes"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testHeader = "Bearer 0123456789abcdef0123456789abcdef0123456789ab"

func quietLog() (*slog.Logger, *bytes.Buffer) {
	var b bytes.Buffer
	return slog.New(slog.NewJSONHandler(&b, nil)), &b
}

func writeToken(t *testing.T, v string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "value")
	if err := os.WriteFile(p, []byte(v), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func guarded(t *testing.T, path string, log *slog.Logger) (http.Handler, *int) {
	t.Helper()
	hits := 0
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hits++; w.WriteHeader(200) })
	g, err := NewMCPBearer(path, log)
	if err != nil {
		t.Fatal(err)
	}
	return g.Wrap(next), &hits
}

func call(h http.Handler, method, path, auth string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader("{}"))
	r.RemoteAddr = "10.1.2.3:4444"
	if auth != "" {
		r.Header.Set("Authorization", auth)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func TestMCPBearerAcceptsOnlyTheExactValue(t *testing.T) {
	log, _ := quietLog()
	h, hits := guarded(t, writeToken(t, testHeader+"\n"), log)
	if w := call(h, "POST", "/mcp", testHeader); w.Code != 200 {
		t.Fatalf("the right value: %d", w.Code)
	}
	for name, auth := range map[string]string{
		"none":            "",
		"wrong":           "Bearer 0123456789abcdef0123456789abcdef0123456789ac",
		"prefix":          testHeader[:len(testHeader)-1],
		"longer":          testHeader + "0",
		"other scheme":    "Basic " + testHeader[7:],
		"lower case word": "bearer " + testHeader[7:],
		"extra space":     testHeader + " ",
		"token only":      testHeader[7:],
	} {
		before := *hits
		w := call(h, "POST", "/mcp", auth)
		if w.Code != 401 || *hits != before {
			t.Errorf("%s: want 401 and no call of the handler, got %d (hits %d -> %d)", name, w.Code, before, *hits)
		}
		if w.Code == 401 && !strings.HasPrefix(w.Header().Get("WWW-Authenticate"), "Bearer") {
			t.Errorf("%s: a 401 must say Bearer in WWW-Authenticate", name)
		}
	}
}

func TestMCPBearerLeavesOnlyTheHealthChecksOpen(t *testing.T) {
	log, _ := quietLog()
	h, _ := guarded(t, writeToken(t, testHeader), log)
	for _, p := range []string{"/healthz", "/readyz"} {
		if w := call(h, "GET", p, ""); w.Code != 200 {
			t.Errorf("GET %s with no header: %d, want 200", p, w.Code)
		}
	}
	for _, c := range [][2]string{{"POST", "/healthz"}, {"GET", "/healthz/x"}, {"GET", "/mcp"}, {"DELETE", "/mcp"}, {"GET", "/"}, {"POST", "/readyz"}} {
		if w := call(h, c[0], c[1], ""); w.Code != 401 {
			t.Errorf("%s %s with no header: %d, want 401", c[0], c[1], w.Code)
		}
	}
}

func TestMCPBearerReadsTheFileOnEveryRequest(t *testing.T) {
	p := writeToken(t, testHeader)
	log, _ := quietLog()
	h, _ := guarded(t, p, log)
	if w := call(h, "POST", "/mcp", testHeader); w.Code != 200 {
		t.Fatalf("before the change: %d", w.Code)
	}
	next := "Bearer ffffffffffffffffffffffffffffffffffffffffffff"
	if err := os.WriteFile(p, []byte(next), 0o600); err != nil {
		t.Fatal(err)
	}
	if w := call(h, "POST", "/mcp", testHeader); w.Code != 401 {
		t.Errorf("the old value after the file changed: %d, want 401", w.Code)
	}
	if w := call(h, "POST", "/mcp", next); w.Code != 200 {
		t.Errorf("the new value: %d, want 200", w.Code)
	}
}

func TestMCPBearerFailsClosedWhenTheFileGoesBadLater(t *testing.T) {
	p := writeToken(t, testHeader)
	log, _ := quietLog()
	h, hits := guarded(t, p, log)
	for name, content := range map[string]string{"empty": "", "blank": " \n", "no scheme": "0123456789abcdef0123456789abcdef0123456789ab", "short": "Bearer abc"} {
		if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		if w := call(h, "POST", "/mcp", testHeader); w.Code != 401 || *hits != 0 {
			t.Errorf("%s: %d (hits %d), want 401 and none", name, w.Code, *hits)
		}
		// a bad file must not let an empty header through
		if w := call(h, "POST", "/mcp", ""); w.Code != 401 {
			t.Errorf("%s: no header: %d, want 401", name, w.Code)
		}
	}
	if err := os.Remove(p); err != nil {
		t.Fatal(err)
	}
	if w := call(h, "POST", "/mcp", testHeader); w.Code != 401 {
		t.Errorf("file gone: %d, want 401", w.Code)
	}
}

func TestMCPBearerRefusesABadFileAtStart(t *testing.T) {
	log, _ := quietLog()
	for name, content := range map[string]string{"empty": "", "no scheme": "0123456789abcdef0123456789abcdef0123456789ab", "short token": "Bearer abc", "spaces inside": "Bearer 0123456789abcdef 0123456789abcdef0123456789abcdef"} {
		if _, err := NewMCPBearer(writeToken(t, content), log); err == nil {
			t.Errorf("%s: want an error", name)
		}
	}
	if _, err := NewMCPBearer("", log); err == nil {
		t.Error("an empty path: want an error")
	}
	if _, err := NewMCPBearer(filepath.Join(t.TempDir(), "missing"), log); err == nil {
		t.Error("a missing file: want an error")
	}
}

func TestMCPBearerValueIsInNoLogLineAndNoError(t *testing.T) {
	log, buf := quietLog()
	h, _ := guarded(t, writeToken(t, testHeader), log)
	wrong := "Bearer ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"
	call(h, "POST", "/mcp", wrong)
	call(h, "POST", "/mcp", testHeader)
	call(h, "POST", "/mcp", "")
	out := buf.String()
	if out == "" {
		t.Fatal("a refusal must be logged (without the value): the control is empty")
	}
	for _, secret := range []string{testHeader[7:], wrong[7:], "ZZZZ", "0123456789abcdef"} {
		if strings.Contains(out, secret) {
			t.Fatalf("a header value is in the log: %s", out)
		}
	}
	// a bad file at start: the error names the problem, not the content
	_, err := NewMCPBearer(writeToken(t, "Bearer short-secret-value"), log)
	if err == nil || strings.Contains(err.Error(), "short-secret-value") {
		t.Fatalf("the error must not repeat the file content: %v", err)
	}
}

func TestMCPBearerAnswerHasNoValue(t *testing.T) {
	log, _ := quietLog()
	h, _ := guarded(t, writeToken(t, testHeader), log)
	w := call(h, "POST", "/mcp", "Bearer wrong-wrong-wrong-wrong-wrong-wrong-wrong")
	if strings.Contains(w.Body.String(), "wrong-wrong") || strings.Contains(w.Body.String(), testHeader[7:]) {
		t.Fatalf("the body repeats a value: %s", w.Body.String())
	}
}
