package core

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// url.URL.Query() drops a pair that holds a raw semicolon and drops its error, so a filter such as ?case_id=SVC-1;x would silently become "no filter" and
// a route would list every row. The guard refuses a query that does not parse, on every route of both domains.
func TestRESTGuardRefusesAQueryThatDoesNotParse(t *testing.T) {
	g := guardFixture(t)
	reached := 0
	h := g.Wrap(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { reached++; w.WriteHeader(200) }))
	for _, c := range []struct {
		target string
		want   int
	}{
		{"/approvals?case_id=SVC-2026-0005;x", 400},
		{"/approvals?status=pending&case_id=SVC-2026-0005;x", 400},
		{"/outbox?case_id=SVC-2026-0005%zz", 400},
		{"/approvals?case_id=SVC-2026-0005", 200},
		{"/approvals?case_id=SVC-2026-0005%3Bx", 200}, // an encoded semicolon is a value: the route validates it
		{"/approvals", 200},
	} {
		before := reached
		req := httptest.NewRequest("GET", c.target, nil)
		req.RemoteAddr = "127.0.0.1:1"
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != c.want {
			t.Errorf("%s: %d, want %d", c.target, rec.Code, c.want)
		}
		if c.want == 400 && reached != before {
			t.Errorf("%s: the handler behind the guard was reached", c.target)
		}
	}
}

// CleanText refuses the C0 controls and DEL already. A C1 control (U+009B is a one-character CSI that some terminals act on) and the bidi controls
// (they reorder what an approver reads, as in a part id or a quantity) pass a plain check, and jq -r prints them raw.
func TestCleanTextRefusesC1AndBidiControls(t *testing.T) {
	for name, r := range map[string]rune{
		"C1 CSI U+009B": 0x9b, "C1 NEL U+0085": 0x85, "C1 U+009F": 0x9f,
		"LRE U+202A": 0x202a, "RLO U+202E": 0x202e, "LRI U+2066": 0x2066, "PDI U+2069": 0x2069, "LRM U+200E": 0x200e, "RLM U+200F": 0x200f, "ALM U+061C": 0x61c,
	} {
		if _, err := CleanText("body", "order "+string(r)+"part", 100, true); err == nil {
			t.Errorf("%s was accepted", name)
		}
	}
	for _, ok := range []string{"a plain order", "tab\tand newline\nare allowed", "Zoë ordered ünits of the part", "日本語 text"} {
		if _, err := CleanText("body", ok, 100, true); err != nil {
			t.Errorf("%q was refused: %v", ok, err)
		}
	}
	if _, err := CleanText("body", strings.Repeat("x", 101), 100, true); err == nil {
		t.Error("the length limit still holds")
	}
}
