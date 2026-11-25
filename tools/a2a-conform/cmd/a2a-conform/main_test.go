package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestUsage(t *testing.T) {
	var out, errw strings.Builder
	if code := run(nil, &out, &errw); code != 2 {
		t.Fatalf("code %d", code)
	}
}

func TestExitCodeOneWhenAgentBroken(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	defer srv.Close()
	var out, errw strings.Builder
	if code := run([]string{srv.URL}, &out, &errw); code != 1 {
		t.Fatalf("code %d\n%s", code, out.String())
	}
	if !strings.Contains(out.String(), "FAIL") || !strings.Contains(out.String(), "What to do") {
		t.Fatalf("output:\n%s", out.String())
	}
}
