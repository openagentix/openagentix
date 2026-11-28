package main

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"testing"
)

// A caller value equal to the admin token stops the start and names the caller, never the value (review L3).
func TestACallerValueEqualToTheAdminTokenStopsTheStart(t *testing.T) {
	env := writeAccess(t, `{"mode":"enforce","callers":[{"name":"a","collections":["x"]}]}`, map[string]string{"a": "Bearer shared-with-admin-77"})
	env["KB_ADMIN_TOKEN"] = "shared-with-admin-77"
	env["KB_ADDR"] = "127.0.0.1:0"
	err := run(context.Background(), envFn(env), slog.New(slog.NewJSONHandler(&bytes.Buffer{}, nil)), nil)
	if err == nil || !strings.Contains(err.Error(), `"a"`) || strings.Contains(err.Error(), "shared-with-admin-77") {
		t.Fatalf("err = %v", err)
	}
}
